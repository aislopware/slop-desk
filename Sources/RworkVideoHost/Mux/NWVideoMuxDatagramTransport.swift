#if os(macOS)
import Foundation
import Network
import OSLog
import RworkVideoProtocol

/// The MUX (Stage S3) sibling of ``NWVideoDatagramTransport``: ONE physical UDP flow
/// (media + cursor sockets) shared across N client video channels, demultiplexed by a
/// `UInt32` channelID prefix (``VideoMuxHeaderCodec``) instead of the single-slot
/// client pin.
///
/// ⚠️ **GATED + WIRE-INCOMPATIBLE.** This type is used ONLY when `RWORK_VIDEO_MUX` is
/// ON (both ends must agree, ``VideoMuxGate``). The wire here is the 4-byte channelID
/// prefix in FRONT of the existing 1-byte channel tag + payload:
/// ```
///   [UInt32 BE channelID][UInt8 channelTag][payload...]   (media socket)
///   [UInt32 BE channelID][payload...]                     (cursor socket)
/// ```
/// A client that did NOT enable the gate writes the OFF framing (`[tag][payload]`),
/// which this transport parses as a stray channelID and routes through
/// ``VideoMuxRouter`` — which rejects the unadmitted lane (a clean DROP, never a crash
/// or a corrupt inject). That is the mixed-version "fail cleanly" contract.
///
/// ## Per-channel loss isolation (RTP semantics)
/// A lost datagram, or one channel's `retire`, only affects THAT channelID — sibling
/// lanes keep routing (``VideoMuxRouter/dropRetired`` keeps a retired lane's in-flight
/// bytes out of survivors). The router never tears the shared flow down for a single
/// bad/late datagram.
///
/// ## HANG / SOCKET SAFETY
/// Opens real `NWListener`/`NWConnection` `.udp` flows — COMPILED + code-reviewed,
/// NEVER instantiated in a test (like ``NWVideoDatagramTransport``). The pure routing
/// it drives (``VideoMuxRouter``) and the per-channel framing (``VideoMuxHeaderCodec``)
/// ARE unit-tested in isolation; an in-memory routing harness covers the dispatch.
public final class NWVideoMuxDatagramTransport: @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool { channel != .cursor }

    private let log = Logger(subsystem: "rwork.video.host", category: "NWVideoMuxDatagramTransport")
    private let mediaPort: NWEndpoint.Port
    private let cursorPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "rwork.video.transport.mux", qos: .userInteractive)

    private var mediaListener: NWListener?
    private var cursorListener: NWListener?

    /// All accepted client flows (UDP "connections" the listener pins per source endpoint).
    /// Under mux MANY clients legitimately share the listener, so — unlike the single-slot
    /// `NWVideoDatagramTransport` — every accepted flow is kept; demux happens per-datagram by
    /// channelID. Keyed by an opaque token so a failed flow removes only itself.
    private let lock = NSLock()
    private var mediaConns: [ObjectIdentifier: NWConnection] = [:]
    private var cursorConns: [ObjectIdentifier: NWConnection] = [:]
    /// channelID → the cursor flow that primed it, so a per-channel cursor datagram is sent back
    /// on the SAME flow the client opened (the host learns a cursor endpoint only from an inbound
    /// prime, exactly as in the OFF path). Media replies pick the flow that last carried the lane.
    private var channelMediaConn: [UInt32: NWConnection] = [:]
    private var channelCursorConn: [UInt32: NWConnection] = [:]
    /// The reconnect-generation-safe admit/retire/route table (PURE; unit-tested).
    private var muxRouter = VideoMuxRouter()
    private var stopped = false

    /// CONCURRENCY-HOST-1 mux analogue (always on): the per-lane idle-timeout reaper. Keyed by
    /// channelID (each lane its own record), so a crashed lane is reaped independently of its
    /// siblings — the per-channel loss-isolation posture. Guarded by `lock`.
    private var idleReaper = IdleReapDecider<UInt32>(idleTimeout: KeepaliveTiming.idleTimeout)
    /// The coarse reaper scan timer (``KeepaliveTiming/reaperTick``), on `queue`; cancelled under
    /// `lock` in ``stop()``.
    private var reaperTimer: DispatchSourceTimer?
    /// Called per reaped lane (the symmetric of a `bye`'s lane retire + capture teardown — the gap
    /// the residual at the `installResetHandler` comment described). Set by the daemon to
    /// `registry.retireAndStop(channelID)` so the minted session's SCStream/encoder actually stops,
    /// not just the sink forgotten. The ONLY new async work; nil (uncalled) on the OFF path.
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
        self.mediaPort = NWEndpoint.Port(rawValue: mediaPort)!
        self.cursorPort = NWEndpoint.Port(rawValue: cursorPort)!
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
            channelMediaConn.removeValue(forKey: channelID)
            channelCursorConn.removeValue(forKey: channelID)
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
    public func start(onReceive: @escaping @Sendable (_ channelID: UInt32, _ channel: VideoChannel, _ data: Data) -> Void) async throws {
        let params = NWParameters.udp
        params.includePeerToPeer = false

        let media = try NWListener(using: params, on: mediaPort)
        media.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }
            self.mediaConns[ObjectIdentifier(conn)] = conn
            self.lock.unlock()
            let live = Liveness()
            self.installResetHandler(on: conn, isMedia: true, live: live)
            conn.start(queue: self.queue)
            self.receiveMedia(on: conn, live: live, onReceive: onReceive)
        }
        media.start(queue: queue)
        self.mediaListener = media

        let cursor = try NWListener(using: params, on: cursorPort)
        cursor.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }
            self.cursorConns[ObjectIdentifier(conn)] = conn
            self.lock.unlock()
            let live = Liveness()
            self.installResetHandler(on: conn, isMedia: false, live: live)
            conn.start(queue: self.queue)
            self.receiveCursor(on: conn, live: live, onReceive: onReceive)
        }
        cursor.start(queue: queue)
        self.cursorListener = cursor

        // CONCURRENCY-HOST-1 mux analogue: arm the per-lane idle-timeout reaper. On `queue` (serial
        // receive queue).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + KeepaliveTiming.reaperTick, repeating: KeepaliveTiming.reaperTick)
        timer.setEventHandler { [weak self] in self?.runReaperTick() }
        lock.withLock { reaperTimer = timer }
        timer.resume()

        log.info("NWVideoMuxDatagramTransport listening media=\(self.mediaPort.rawValue) cursor=\(self.cursorPort.rawValue) (shared mux flow)")
    }

    /// One reaper scan (on `queue`): for each dead lane the decider reports, hold the lane in a
    /// DRAINING state, STOP its session, then free the lane LAST — mirroring the single-pin
    /// "hold the slot pinned through teardown" discipline (audit FIX #4b). The earlier code retired
    /// the router lane SYNCHRONOUSLY first and stopped the session in a deferred Task, so a reconnect
    /// hello racing that window routed `.dropRetired` → re-admit-bootstrap → was delivered to the OLD,
    /// still-registered sink → a false accepted-ack from a dying session (client stuck on a dead
    /// stream). Now: `beginDrain` synchronously (a reconnect during teardown drops via `.dropDraining`
    /// — NOT delivered to the old sink, NOT prematurely re-minted); `forget` the reaper record so the
    /// next tick does not re-schedule; then in the deferred Task stop the session (`onReapLane` →
    /// `registry.retireAndStop` — unregister sink + SCStream/encoder teardown) and only AFTER that
    /// `endDrain` (draining → retired, where a fresh hello may now cleanly re-admit) + drop the
    /// conn-table. The session stop is the only async hop; it carries no datagram so it cannot reorder
    /// input.
    private func runReaperTick() {
        let due: [UInt32] = lock.withLock { idleReaper.reap(now: Self.nowSeconds()) }
        guard !due.isEmpty else { return }
        lock.withLock {
            for channelID in due {
                muxRouter.beginDrain(channelID)   // hold the lane — a racing reconnect now `.dropDraining`s
                idleReaper.forget(id: channelID)  // no re-schedule on the next tick
            }
        }
        for channelID in due {
            Task { [weak self] in
                await self?.onReapLane?(channelID)   // registry.retireAndStop — unregister sink + stop session
                guard let self else { return }
                self.lock.withLock {
                    self.muxRouter.endDrain(channelID)             // draining → retired (a hello may now re-admit)
                    self.channelMediaConn.removeValue(forKey: channelID)
                    self.channelCursorConn.removeValue(forKey: channelID)
                }
            }
        }
    }

    // CONCURRENCY-HOST-1 mux analogue: a client that vanishes WITHOUT a bye (crash, or last-lane
    // close racing the fire-and-forget bye egress) leaves its host session minted + its SCStream
    // capture/encode RUNNING (bye → stopCapture never fires). This `.failed`/`.cancelled` handler
    // only forgets the flow's socket bookkeeping — it does NOT retire the channelIDs nor stop their
    // sessions (UDP has no FIN, so a vanished peer rarely fails the flow at all). The idle-timeout
    // reaper closes that gap: a lane that proves keepalive then goes silent for `idleTimeout` is
    // `retire`d + its session stopped via `onReapLane` (registry.retireAndStop). The reaper's
    // timing/socket glue is [MS-confirm] on the Mac Studio, not headless.
    private func installResetHandler(on conn: NWConnection, isMedia: Bool, live: Liveness) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                live.markDead()
                self.lock.lock()
                if isMedia {
                    self.mediaConns.removeValue(forKey: ObjectIdentifier(conn))
                    self.channelMediaConn = self.channelMediaConn.filter { $0.value !== conn }
                } else {
                    self.cursorConns.removeValue(forKey: ObjectIdentifier(conn))
                    self.channelCursorConn = self.channelCursorConn.filter { $0.value !== conn }
                }
                self.lock.unlock()
            default:
                break
            }
        }
    }

    private func receiveMedia(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.routeMedia(data, on: conn, onReceive: onReceive)
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("mux media receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveMedia(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                }
            } else {
                self.receiveMedia(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    /// Parses `[channelID][tag][payload]`, routes by channelID (per-channel loss isolation), and on
    /// a routed datagram remembers the flow for the lane so host→client media for it can reply.
    ///
    /// **Bootstrap exception (the first hello).** A lane is only `admit`ted once the daemon's session
    /// registry mints its session — but the very FIRST hello for a never-seen channelID arrives BEFORE
    /// that, so it is not yet admitted. A HELLO `.control` datagram for an UNADMITTED lane is therefore
    /// still delivered to `onReceive` so the registry can mint on the hello.
    ///
    /// **FIX #2 (cross-process channelID reuse).** A retired channelID can collide with a restarted
    /// client's fresh channelID (the client allocator resets to 1 per process). A retired lane is
    /// hard-dropped for everything EXCEPT a real `hello` `.control` datagram, which RE-ADMITS it
    /// (delivered to the registry, which mints + `admit`s → clears the retired mark). Safe because the
    /// dead old process has no in-flight old-gen datagrams left; only an explicit hello re-admits, so
    /// stale old-gen video/input still drops (reconnect-generation safety preserved).
    ///
    /// **FIX #6 (stray-control leak).** The reply flow (`channelMediaConn`) is remembered ONLY for a
    /// channelID whose first unadmitted/retired control datagram actually decodes as a `hello` — a
    /// non-hello stray/adversarial control datagram drops WITHOUT touching `channelMediaConn` (which
    /// would otherwise grow unboundedly for never-helloed ids). The hello-peek is done ONCE here and
    /// fed to the PURE ``VideoMuxRouter/bootstrapAction(for:channel:payloadIsHello:)`` decider.
    private func routeMedia(_ data: Data, on conn: NWConnection, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        guard let (channelID, rest) = try? VideoMuxHeaderCodec.decode(data), rest.count >= 1 else { return }
        let tag = rest[rest.startIndex]
        guard let channel = VideoChannel(rawValue: tag) else { return }
        let payload = Data(rest[(rest.startIndex + 1)...])
        let deliver: Bool = lock.withLock {
            let decision = muxRouter.route(channelID: channelID, channel: channel, bytesCount: data.count)
            switch decision {
            case .route:
                channelMediaConn[channelID] = conn
                // Stamp liveness for the ADMITTED lane only (inline, no actor hop, under the route
                // lock). The keepalive peek (a keepalive is a control datagram whose type byte == 6;
                // `rest` is [tag][type][...], so the type byte is at startIndex+1) — symmetric with
                // the single-pin transport's stamp.
                let isKA = channel == .control && rest.count >= 2 && rest[rest.startIndex + 1] == 6
                idleReaper.noteInbound(id: channelID, now: Self.nowSeconds(), isKeepalive: isKA)
                return true
            case .rejectUnadmitted, .dropRetired:
                // Bootstrap (FIX #2 + #6): peek-decode the payload ONCE and only re-admit/deliver +
                // remember the reply flow for an actual hello on the control channel. A non-hello
                // (stray, or a stale old-gen datagram for a retired id) drops WITHOUT a stamp.
                // Deliberately do NOT stamp the reaper here: an un-minted lane has no session to
                // reap, and stamping a never-admitted channelID would grow the decider's flow map
                // for stray/adversarial ids. A lane takes its first liveness stamp on its first
                // ADMITTED datagram (the `.route` arm).
                let isHello = Self.payloadIsHello(channel: channel, payload: payload)
                switch VideoMuxRouter.bootstrapAction(for: decision, channel: channel, payloadIsHello: isHello) {
                case .bootstrapDeliver:
                    channelMediaConn[channelID] = conn
                    return true
                case .dropNoStamp:
                    return false
                }
            case .dropDraining, .drop:
                // Draining: the lane is mid-teardown (reaper stopping its session) — drop EVEN a hello
                // until `endDrain` (no false accept to the dying sink, no premature re-mint). `.drop`:
                // an empty datagram. Both benign — never fatal, never a sibling teardown.
                return false
            }
        }
        guard deliver else { return }
        onReceive(channelID, channel, payload)
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

    private func receiveCursor(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // The cursor flow's leading prime + any client→host bytes are channelID-prefixed so
                // the host can bind the lane's reply flow. The host does not deliver inbound cursor
                // payloads to the session (host→client only), but it MUST learn the lane's flow.
                // Remember it unconditionally — the prime can race AHEAD of the media hello, so the
                // lane may not be admitted yet; the first cursor SEND after admission uses this flow.
                if let (channelID, _) = try? VideoMuxHeaderCodec.decode(data) {
                    self.lock.withLock {
                        self.channelCursorConn[channelID] = conn
                        // Deliberately NOT stamped for the reaper: keepalives ride the MEDIA socket's
                        // control channel (every `keepaliveInterval`), so the media `.route` stamp is
                        // the sole authoritative liveness. The cursor prime races ahead of the media
                        // hello for not-yet-admitted lanes, so stamping here would grow the decider's
                        // flow map for never-admitted channelIDs (reviewer finding) — and is redundant
                        // for a live client, whose media keepalives always refresh `lastInbound`.
                    }
                }
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("mux cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveCursor(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                }
            } else {
                self.receiveCursor(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    // MARK: - Send (host → client, per channelID)

    /// Sends one datagram for `channelID` on `channel`, stamping `[channelID][tag][payload]` (media)
    /// or `[channelID][payload]` (cursor). Fire-and-forget (UDP). A lane with no known flow yet
    /// drops (the client has not opened it) — never blocks, never errors out the shared flow.
    public func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {
        let isMedia = Self.mediaSocket(for: channel)
        let conn: NWConnection? = lock.withLock { isMedia ? channelMediaConn[channelID] : channelCursorConn[channelID] }
        guard let conn else { return }
        let framed: Data
        if isMedia {
            var inner = Data(capacity: datagram.count + 1)
            inner.append(channel.rawValue)
            inner.append(datagram)
            framed = VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner)
        } else {
            framed = VideoMuxHeaderCodec.encode(channelID: channelID, payload: datagram)
        }
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("mux udp send failed channel=\(channel.rawValue) chan=\(channelID): \(String(describing: error))") }
        })
    }

    public func stop() async {
        mediaListener?.cancel(); mediaListener = nil
        cursorListener?.cancel(); cursorListener = nil
        lock.withLock {
            stopped = true
            // Cancel the reaper timer BEFORE tearing down flows so a tick cannot fire mid-teardown.
            reaperTimer?.cancel(); reaperTimer = nil
            for conn in mediaConns.values { conn.cancel() }
            for conn in cursorConns.values { conn.cancel() }
            mediaConns.removeAll()
            cursorConns.removeAll()
            channelMediaConn.removeAll()
            channelCursorConn.removeAll()
        }
    }
}
#endif
