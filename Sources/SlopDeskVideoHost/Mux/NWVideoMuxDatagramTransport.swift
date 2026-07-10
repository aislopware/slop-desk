#if os(macOS)
import Foundation
import Network
import OSLog
import SlopDeskVideoProtocol

/// The host UDP video transport: ONE physical UDP flow (media + cursor sockets) shared
/// across N client video channels, demultiplexed by a `UInt32` channelID prefix
/// (``VideoMuxHeaderCodec``). The only video wire — one flow per host, N panes.
///
/// Wire: the 4-byte channelID prefix in FRONT of the 1-byte channel tag + payload:
/// ```
///   [UInt32 BE channelID][UInt8 channelTag][payload...]   (media socket)
///   [UInt32 BE channelID][payload...]                     (cursor socket)
/// ```
/// An unrecognized lane routes through ``VideoMuxRouter``, which rejects the unadmitted
/// lane (a clean DROP, never a crash or a corrupt inject).
///
/// ## Per-channel loss isolation (RTP semantics)
/// A lost datagram, or one channel's `retire`, affects ONLY that channelID — sibling
/// lanes keep routing (``VideoMuxRouter/dropRetired`` keeps a retired lane's in-flight
/// bytes out of survivors). The router never tears the shared flow down for one bad/late
/// datagram.
///
/// ## HANG / SOCKET SAFETY
/// Opens real `NWListener`/`NWConnection` `.udp` flows — COMPILED + code-reviewed, NEVER
/// instantiated in a test. The pure routing (``VideoMuxRouter``) and per-channel framing
/// (``VideoMuxHeaderCodec``) ARE unit-tested in isolation; an in-memory harness covers dispatch.
public final class NWVideoMuxDatagramTransport: @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool { channel != .cursor }

    private let log = Logger(subsystem: "slopdesk.video.host", category: "NWVideoMuxDatagramTransport")
    private let mediaPort: NWEndpoint.Port
    private let cursorPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "slopdesk.video.transport.mux", qos: .userInteractive)

    private var mediaListener: NWListener?
    private var cursorListener: NWListener?

    /// All accepted client flows + the per-channel reply stamps, in ONE pure, unit-tested table
    /// (``MuxFlowTable``): MANY clients share the listener, so every accepted flow is kept; demux
    /// is per-datagram by channelID; a cursor datagram replies on the SAME flow the client primed,
    /// media replies pick the flow that last carried the lane. The table also owns the idle-flow /
    /// stale-stamp reap decisions (UDP has no FIN — a silently-vanished peer never fails its
    /// host-side flow, so without the reap every client flow rebuild leaked a media + cursor
    /// NWConnection forever). Guarded by `lock`.
    private let lock = NSLock()
    private var flows = MuxFlowTable<NWConnection>(idleTimeout: KeepaliveTiming.idleTimeout)
    /// The reconnect-generation-safe admit/retire/route table (PURE; unit-tested).
    private var muxRouter = VideoMuxRouter()
    /// Rate-limits the unbound-lane `bye` replies (reconnect-wedge fix; PURE, unit-tested).
    /// Guarded by `lock` (mutated inside the routeMedia lock scope).
    private var unboundByeLimiter = UnboundByeRateLimiter()
    private var stopped = false

    /// CONCURRENCY-HOST-1 mux analogue (always on): the per-lane idle-timeout reaper. Keyed by
    /// channelID so a crashed lane is reaped independently of its siblings (per-channel loss
    /// isolation). Guarded by `lock`.
    private var idleReaper = IdleReapDecider<UInt32>(idleTimeout: KeepaliveTiming.idleTimeout)
    /// The coarse reaper scan timer (``KeepaliveTiming/reaperTick``), on `queue`; cancelled under
    /// `lock` in ``stop()``.
    private var reaperTimer: DispatchSourceTimer?
    /// Called per reaped lane (symmetric to a `bye`'s lane retire + capture teardown). Set by the
    /// daemon to `registry.retireAndStop(channelID)` so the minted session's SCStream/encoder
    /// actually stops, not just the sink forgotten. nil (uncalled) until the daemon sets it.
    public var onReapLane: (@Sendable (UInt32) async -> Void)?

    /// Monotonic host time (seconds) for the reaper — ``DispatchTime`` uptime so an NTP step /
    /// sleep-wake never spuriously reaps (NOT wall-clock). Injected into the pure decider.
    private static func nowSeconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        var isAlive: Bool { lock.withLock { alive } }
        func markDead() { lock.withLock { alive = false } }
    }

    public init(mediaPort: UInt16, cursorPort: UInt16) {
        guard let media = NWEndpoint.Port(rawValue: mediaPort),
              let cursor = NWEndpoint.Port(rawValue: cursorPort)
        else { preconditionFailure("NWEndpoint.Port(rawValue:) is total over UInt16 (the full valid port range)") }
        self.mediaPort = media
        self.cursorPort = cursor
    }

    // MARK: - Admission (driven by the daemon's session registry on hello / bye)

    /// Admit a channelID as a live lane (the daemon minted/looked-up a session for it). Idempotent.
    public func admit(_ channelID: UInt32) {
        lock.withLock { muxRouter.admit(channelID) }
    }

    /// Retire a channelID (the daemon saw its `bye` or tore the session down). Its still-in-flight
    /// datagrams are dropped; SIBLING lanes are untouched — the bye retires ONLY the closing lane.
    public func retire(_ channelID: UInt32) {
        lock.withLock {
            muxRouter.retire(channelID)
            flows.retireLane(channelID)
            // Forget the reaper record too (clean bye OR reaper-driven) so a reconnect under the
            // same channelID starts a FRESH record.
            idleReaper.forget(id: channelID)
        }
    }

    // MARK: - Lifecycle

    /// Binds the shared media + cursor sockets and routes each inbound datagram, by its leading
    /// channelID, to `onReceive(channelID, channel, payload)`. The daemon dispatches that to the
    /// per-channel session. A datagram for an unadmitted/retired channelID is dropped (per-channel
    /// loss isolation), never delivered, never fatal.
    @preconcurrency
    public func start(onReceive: @escaping @Sendable (_ channelID: UInt32, _ channel: VideoChannel, _ data: Data)
        -> Void) throws
    {
        let params = NWParameters.udp
        params.includePeerToPeer = false

        let media = try NWListener(using: params, on: mediaPort)
        // R15 #10: surface a POST-bind listener failure. `NWListener(using:on:)` throws synchronously
        // only for an immediately-invalid config; a runtime bind `.failed` (e.g. EADDRINUSE: the media
        // UDP port already held) is delivered ASYNCHRONOUSLY here. With no handler it was silently
        // dropped — `start()` returned success, the daemon logged "listening…", yet the socket never
        // bound and no video flowed, zero error surfaced. Log it loudly so the operator sees the real
        // cause. (Gating `start()` on `.ready` via a checked continuation — mirroring HostTransport — is
        // the fuller fix, deferred as the real-socket path is hardware-only-verifiable.)
        media.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.log
                    .error(
                        "media listener failed: \(String(describing: error)) — video will not flow on the media port",
                    )
            }
        }
        media.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            lock.lock()
            if stopped { lock.unlock()
                conn.cancel()
                return
            }
            flows.accept(conn, isMedia: true, now: Self.nowSeconds())
            lock.unlock()
            let live = Liveness()
            installResetHandler(on: conn, isMedia: true, live: live)
            conn.start(queue: queue)
            receiveMedia(on: conn, live: live, onReceive: onReceive)
        }
        media.start(queue: queue)

        let cursor = try NWListener(using: params, on: cursorPort)
        // R15 #10: same post-bind failure surfacing for the cursor listener (see media above).
        cursor.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.log
                    .error(
                        "cursor listener failed: \(String(describing: error)) — cursor updates will not flow on the cursor port",
                    )
            }
        }
        cursor.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            lock.lock()
            if stopped { lock.unlock()
                conn.cancel()
                return
            }
            flows.accept(conn, isMedia: false, now: Self.nowSeconds())
            lock.unlock()
            let live = Liveness()
            installResetHandler(on: conn, isMedia: false, live: live)
            conn.start(queue: queue)
            receiveCursor(on: conn, live: live, onReceive: onReceive)
        }
        cursor.start(queue: queue)

        // CONCURRENCY-HOST-1 mux analogue: arm the per-lane idle-timeout reaper. On `queue` (serial
        // receive queue).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + KeepaliveTiming.reaperTick, repeating: KeepaliveTiming.reaperTick)
        timer.setEventHandler { [weak self] in self?.runReaperTick() }
        // R14 lock-domain fix: store the listener refs UNDER the lock alongside reaperTimer (every other
        // mutable field on this @unchecked Sendable class is lock-guarded; these two were the lone lock-
        // free exception → a torn read / ARC race if stop() ever overlapped an in-flight start()). The
        // listeners are already started above; only the field stores move under the lock.
        lock.withLock { mediaListener = media
            cursorListener = cursor
            reaperTimer = timer
        }
        timer.resume()

        // Bind locals so the os_log interpolation captures no `self` (see NWVideoMuxClientFlow).
        let mediaPortValue = mediaPort.rawValue
        let cursorPortValue = cursorPort.rawValue
        log
            .info(
                "NWVideoMuxDatagramTransport listening media=\(mediaPortValue) cursor=\(cursorPortValue) (shared mux flow)",
            )
    }

    /// One reaper scan (on `queue`): for each dead lane, hold it DRAINING, STOP its session, then free
    /// the lane LAST — mirroring the single-pin "hold the slot pinned through teardown" discipline
    /// (audit FIX #4b). The earlier code retired the router lane SYNCHRONOUSLY first and stopped the
    /// session in a deferred Task, so a reconnect hello racing that window routed `.dropRetired` →
    /// re-admit-bootstrap → delivered to the OLD, still-registered sink → a false accepted-ack from a
    /// dying session (client stuck on a dead stream). Now: `beginDrain` synchronously (a reconnect
    /// during teardown drops via `.dropDraining` — NOT to the old sink, NOT prematurely re-minted);
    /// `forget` the reaper record so the next tick won't re-schedule; then in the deferred Task stop
    /// the session (`onReapLane` → `registry.retireAndStop` — unregister sink + SCStream/encoder
    /// teardown), and only AFTER that `endDrain` (draining → retired, where a fresh hello may cleanly
    /// re-admit) + drop the conn-table. The session stop is the only async hop; it carries no datagram
    /// so it cannot reorder input.
    private func runReaperTick() {
        let now = Self.nowSeconds()
        let due: [UInt32] = lock.withLock { idleReaper.reap(now: now) }
        if !due.isEmpty {
            lock.withLock {
                for channelID in due {
                    muxRouter.beginDrain(channelID) // hold the lane — a racing reconnect now `.dropDraining`s
                    idleReaper.forget(id: channelID) // no re-schedule on the next tick
                }
            }
            for channelID in due {
                Task { [weak self] in
                    await self?.onReapLane?(channelID) // registry.retireAndStop — unregister sink + stop session
                    guard let self else { return }
                    lock.withLock {
                        self.muxRouter.endDrain(channelID) // draining → retired (a hello may now re-admit)
                        self.flows.retireLane(channelID)
                    }
                }
            }
        }
        // FLOW reap (audit B-videohost-flow-reap): sweep never-admitted reply stamps, then cancel
        // idle UNREFERENCED flows (a vanished/rebuilt UDP peer never fails its host-side flow — the
        // lane reaper above frees the session, but the pinned NWConnection pair leaked forever).
        // The decisions are pure (``MuxFlowTable/reap(now:isAdmitted:)``); cancel() runs outside
        // the lock, and each cancel re-enters `flowDidReset` via `.cancelled` idempotently.
        let dead: [NWConnection] = lock.withLock { flows.reap(now: now) { muxRouter.isAdmitted($0) } }
        for conn in dead { conn.cancel() }
    }

    // CONCURRENCY-HOST-1 mux analogue: a client that vanishes WITHOUT a bye (crash, or last-lane close
    // racing the fire-and-forget bye egress) leaves its host session minted + its SCStream capture/
    // encode RUNNING (bye → stopCapture never fires). This `.failed`/`.cancelled` handler only forgets
    // the flow's socket bookkeeping — it does NOT retire the channelIDs nor stop their sessions (UDP has
    // no FIN, so a vanished peer rarely fails the flow at all). The idle-timeout reaper closes that gap:
    // a lane that proved keepalive then goes silent for `idleTimeout` is `retire`d + its session stopped
    // via `onReapLane` (registry.retireAndStop). The reaper timing/socket glue is [MS-confirm] on the
    // Mac Studio, not headless.
    private func installResetHandler(on conn: NWConnection, isMedia: Bool, live: Liveness) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed,
                 .cancelled:
                live.markDead()
                lock.withLock { flows.flowDidReset(conn, isMedia: isMedia) }
            default:
                break
            }
        }
    }

    private func receiveMedia(
        on conn: NWConnection,
        live: Liveness,
        consecutiveErrors: Int = 0,
        onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void,
    ) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                routeMedia(data, on: conn, onReceive: onReceive)
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                log
                    .error(
                        "mux media receive error (transient, backing off + re-arming if alive): \(String(describing: error))",
                    )
                let next = consecutiveErrors + 1
                queue
                    .asyncAfter(deadline: .now() + UDPReceiveLoopPolicy
                        .nextBackoff(consecutiveErrors: next))
                    { [weak self] in
                        guard let self, live.isAlive else { return }
                        receiveMedia(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                    }
            } else {
                receiveMedia(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    /// Parses `[channelID][tag][payload]`, routes by channelID (per-channel loss isolation), and on a
    /// routed datagram remembers the flow for the lane so host→client media can reply.
    ///
    /// **Bootstrap exception (the first hello).** A lane is `admit`ted only once the daemon's registry
    /// mints its session — but the very FIRST hello for a never-seen channelID arrives BEFORE that, so
    /// it is not yet admitted. A HELLO `.control` datagram for an UNADMITTED lane is therefore still
    /// delivered to `onReceive` so the registry can mint on it.
    ///
    /// **FIX #2 (cross-process channelID reuse).** A retired channelID can collide with a restarted
    /// client's fresh channelID (the client allocator resets to 1 per process). A retired lane is
    /// hard-dropped for everything EXCEPT a real `hello` `.control` datagram, which RE-ADMITS it (the
    /// registry mints + `admit`s → clears the retired mark). Safe because the dead old process has no
    /// in-flight old-gen datagrams left; only an explicit hello re-admits, so stale old-gen video/input
    /// still drops (reconnect-generation safety preserved).
    ///
    /// **FIX #6 (stray-control leak).** The reply flow (`channelMediaConn`) is remembered ONLY for a
    /// channelID whose first unadmitted/retired control datagram actually decodes as a `hello` — a
    /// non-hello stray/adversarial datagram drops WITHOUT touching `channelMediaConn` (which would else
    /// grow unboundedly for never-helloed ids). The hello-peek is done ONCE here and fed to the PURE
    /// ``VideoMuxRouter/bootstrapAction(for:channel:payloadIsHello:)`` decider.
    /// What ``routeMedia`` decided under the lock: deliver, drop silently, or drop AND answer a `bye`
    /// on the arrival flow (the reconnect-wedge fix — see ``UnboundLaneByeDecider``). The send happens
    /// OUTSIDE the lock.
    private enum MediaRouteOutcome {
        case deliver
        case drop
        case dropAndBye
    }

    private func routeMedia(
        _ data: Data,
        on conn: NWConnection,
        onReceive: @Sendable (UInt32, VideoChannel, Data) -> Void,
    ) {
        guard let (channelID, rest) = try? VideoMuxHeaderCodec.decode(data), rest.count >= 1 else { return }
        let tag = rest[rest.startIndex]
        guard let channel = VideoChannel(rawValue: tag) else { return }
        // Tag-stripped SLICE, not a copy (copy-elimination, 2026-07-10): every consumer decodes
        // startIndex-relative (`VideoByteReader`) and copies durable bytes via `readBytes`, so the
        // slice never outlives the dispatch — nothing pins the parent datagram buffer.
        let payload = rest[(rest.startIndex + 1)...]
        let outcome: MediaRouteOutcome = lock.withLock {
            let now = Self.nowSeconds()
            // Any decoded inbound datagram proves the 5-tuple is alive — refresh the FLOW's
            // last-inbound stamp regardless of the routing decision (a wedged-but-talking client's
            // flow must not be reaped out from under the `bye` replies that un-wedge it).
            flows.noteInbound(conn, now: now)
            let decision = muxRouter.route(channelID: channelID, channel: channel, bytesCount: data.count)
            switch decision {
            case .route:
                flows.stampMediaReply(channelID: channelID, flow: conn)
                // Stamp liveness for the ADMITTED lane only (inline, no actor hop, under the route lock).
                // Keepalive peek: a keepalive is a control datagram whose type byte == 6; `rest` is
                // [tag][type][...], so the type byte is at startIndex+1. Symmetric with the single-pin
                // transport's stamp.
                let isKA = channel == .control && rest.count >= 2 && rest[rest.startIndex + 1] == 6
                idleReaper.noteInbound(id: channelID, now: now, isKeepalive: isKA)
                return .deliver
            case .rejectUnadmitted,
                 .dropRetired:
                // Bootstrap (FIX #2 + #6): peek-decode the payload ONCE; only re-admit/deliver + remember
                // the reply flow for an actual hello on the control channel. A non-hello (stray, or a
                // stale old-gen datagram for a retired id) drops WITHOUT a stamp. Deliberately do NOT
                // stamp the reaper here: an un-minted lane has no session to reap, and stamping a never-
                // admitted channelID would grow the decider's flow map for stray/adversarial ids. A lane
                // takes its first liveness stamp on its first ADMITTED datagram (the `.route` arm).
                let isHello = Self.payloadIsHello(channel: channel, payload: payload)
                // A window-LIST request also bootstraps (deliver + stamp the reply flow) so the daemon
                // can answer it WITHOUT minting a session (docs/31 remote-window picker).
                let isList = Self.payloadIsListRequest(channel: channel, payload: payload)
                switch VideoMuxRouter.bootstrapAction(
                    for: decision,
                    channel: channel,
                    payloadIsHello: isHello,
                    payloadIsListRequest: isList,
                ) {
                case .bootstrapDeliver:
                    flows.stampMediaBootstrap(channelID: channelID, flow: conn, now: now)
                    return .deliver
                case .dropNoStamp:
                    // RECONNECT-WEDGE FIX (2026-07-03): a dropped datagram proving the sender still
                    // believes a session exists (in-session control / input / recovery — typically a
                    // client that survived a videohostd restart) gets a `bye` back on the arrival flow
                    // (rate-limited per channelID), so the wedged client tears down + re-hellos instead
                    // of freezing forever. NO flow bookkeeping is stamped — the reply rides `conn`
                    // directly, so FIX #6's no-leak property holds.
                    if UnboundLaneByeDecider.warrantsBye(channel: channel, payload: payload),
                       unboundByeLimiter.admit(channelID: channelID, now: now)
                    {
                        return .dropAndBye
                    }
                    return .drop
                }
            case .dropDraining,
                 .drop:
                // Draining: the lane is mid-teardown (reaper stopping its session) — drop EVEN a hello
                // until `endDrain` (no false accept to the dying sink, no premature re-mint). `.drop`:
                // an empty datagram. Both benign — never fatal, never a sibling teardown.
                return .drop
            }
        }
        switch outcome {
        case .deliver:
            onReceive(channelID, channel, payload)
        case .dropAndBye:
            sendUnboundBye(channelID, on: conn)
        case .drop:
            break
        }
    }

    /// Answers an unbound lane's in-session datagram with a `bye` on the SAME flow it arrived on
    /// (no `channelMediaConn` stamp — the lane stays forgotten). Fire-and-forget UDP; the client's
    /// keepalive re-triggers it (rate-limited) if this one is lost.
    private func sendUnboundBye(_ channelID: UInt32, on conn: NWConnection) {
        let framed = VideoMuxHeaderCodec.encodeMedia(
            channelID: channelID,
            tag: VideoChannel.control.rawValue,
            payload: VideoControlMessage.bye.encode(),
        )
        log.info("unbound lane chan=\(channelID) still talking (host restarted?) — answering bye")
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.error("unbound-lane bye send failed chan=\(channelID): \(String(describing: error))")
            }
        })
    }

    /// One-shot peek: does a control-channel payload decode as a `hello`? Only the control channel is
    /// ever a hello, so non-control payloads short-circuit without a decode. Shared by FIX #2 (retired
    /// re-admit) and FIX #6 (stray-control leak) so the decode happens at most once per datagram.
    private static func payloadIsHello(channel: VideoChannel, payload: Data) -> Bool {
        guard channel == .control,
              let msg = try? VideoControlMessage.decode(payload),
              case .hello = msg else { return false }
        return true
    }

    /// One-shot peek: does a control-channel payload decode as a session-LESS discovery request — either
    /// `listWindows` (docs/31 picker) or `listSystemDialogs` (the system-popup-pane feature)? Like the
    /// hello peek, only the control channel can carry these. Lets such a request bootstrap its reply flow
    /// so the daemon can answer it without minting a capture session.
    private static func payloadIsListRequest(channel: VideoChannel, payload: Data) -> Bool {
        guard channel == .control, let msg = try? VideoControlMessage.decode(payload) else { return false }
        switch msg {
        case .listWindows,
             .listSystemDialogs: return true
        default: return false
        }
    }

    private func receiveCursor(
        on conn: NWConnection,
        live: Liveness,
        consecutiveErrors: Int = 0,
        onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void,
    ) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // The cursor flow's leading prime + any client→host bytes are channelID-prefixed so the
                // host can bind the lane's reply flow. Inbound cursor payloads aren't delivered to the
                // session (host→client only), but the host MUST learn the lane's flow. Remember it even
                // for a not-yet-admitted lane — the prime can race AHEAD of the media hello; the first
                // cursor SEND after admission uses this flow. The `isAdmitted` bit makes an unadmitted
                // stamp TTL-tracked so a NEVER-admitted id (a discovery poll whose media-socket request
                // was lost on a lossy link) is swept by the reaper instead of leaking forever — the
                // cursor-side mirror of routeMedia's FIX #6 admission gate.
                // Deliberately NOT stamped for the per-LANE reaper (`idleReaper`): keepalives ride the
                // MEDIA socket's control channel, so the media `.route` stamp is the sole authoritative
                // lane liveness; stamping never-admitted ids there would grow its flow map unboundedly.
                if let (channelID, _) = try? VideoMuxHeaderCodec.decode(data) {
                    lock.withLock {
                        let now = Self.nowSeconds()
                        self.flows.noteInbound(conn, now: now)
                        self.flows.stampCursorReply(
                            channelID: channelID,
                            flow: conn,
                            now: now,
                            isAdmitted: self.muxRouter.isAdmitted(channelID),
                        )
                    }
                }
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                log
                    .error(
                        "mux cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))",
                    )
                let next = consecutiveErrors + 1
                queue
                    .asyncAfter(deadline: .now() + UDPReceiveLoopPolicy
                        .nextBackoff(consecutiveErrors: next))
                    { [weak self] in
                        guard let self, live.isAlive else { return }
                        receiveCursor(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                    }
            } else {
                receiveCursor(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    // MARK: - Send (host → client, per channelID)

    /// Sends one datagram for `channelID` on `channel`, stamping `[channelID][tag][payload]` (media)
    /// or `[channelID][payload]` (cursor). Fire-and-forget (UDP). A lane with no known flow yet
    /// drops (the client has not opened it) — never blocks, never errors out the shared flow.
    public func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {
        let isMedia = Self.mediaSocket(for: channel)
        let conn: NWConnection? = lock.withLock {
            isMedia ? flows.mediaReplyFlow(for: channelID) : flows.cursorReplyFlow(for: channelID)
        }
        guard let conn else { return }
        // Single-allocation framing (copy-elimination, 2026-07-10): the payload bytes are appended
        // exactly once — byte-identical to the old inner `[tag][payload]` + prefix-encode two-step
        // (pinned in `VideoMuxHeaderCodecTests.testMediaSendShapePinsManualWireBytes`).
        let framed: Data =
            if isMedia {
                VideoMuxHeaderCodec.encodeMedia(channelID: channelID, tag: channel.rawValue, payload: datagram)
            } else {
                VideoMuxHeaderCodec.encode(channelID: channelID, payload: datagram)
            }
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log
                    .error(
                        "mux udp send failed channel=\(channel.rawValue) chan=\(channelID): \(String(describing: error))",
                    )
            }
        })
    }

    public func stop() {
        // R14 lock-domain fix: read+nil the listener refs UNDER the lock (their write moved under the lock
        // in start()), then cancel OUTSIDE the lock. cancel() is idempotent and the refs are read nowhere
        // else, so this is behavior-preserving — it just closes the lock-free read/nil hole.
        let (media, cursor, conns): (NWListener?, NWListener?, [NWConnection]) = lock.withLock {
            let m = mediaListener, c = cursorListener
            mediaListener = nil
            cursorListener = nil
            stopped = true
            // Cancel the reaper timer BEFORE tearing down flows so a tick cannot fire mid-teardown.
            reaperTimer?.cancel()
            reaperTimer = nil
            return (m, c, flows.removeAll())
        }
        for conn in conns { conn.cancel() }
        media?.cancel()
        cursor?.cancel()
    }
}
#endif
