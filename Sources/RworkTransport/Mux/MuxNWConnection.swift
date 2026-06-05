import Foundation
import RworkProtocol

/// The shared physical mux connection for one host: ONE CONTROL ``MuxByteLink`` + ONE DATA
/// ``MuxByteLink``, each carrying many panes' logical channels multiplexed by `channelID`.
///
/// This is the IO layer the pure ``MuxRouter`` / ``HostChannelRouter`` were built for: it owns
/// one ``MuxFrameDecoder`` per link, runs a receive loop on each, and dispatches every decoded
/// ``MuxFrame`` through the router into the right per-channel ``MuxSubChannel`` continuation. So
/// interleaved frames from many panes on one socket land on the correct per-pane inbound stream
/// — the headline TCP-mux property.
///
/// ### Why two links (CONTROL + DATA)
/// The shared connection keeps a data/control split: a burst of
/// PTY `output` carried as `.channelData` on the shared DATA link cannot delay a `resize`/`ack`/
/// `bye` carried on the shared CONTROL link — for EVERY pane, not just one. Each pane gets a pair
/// of ``MuxSubChannel``s sharing one `channelID`: a data sub-channel on the DATA link and a
/// control sub-channel on the CONTROL link. ``MuxClientTransport`` pairs them back into the
/// data/control surface ``RworkClient`` expects.
///
/// ### Lifecycle
/// - `openChannel()` (client/initiator) allocates an odd `channelID`, registers the per-link
///   sub-channels, sends `channelOpen` on the DATA link, and (S1) returns the pair WITHOUT waiting
///   for an ack — the host opens lazily on first `channelOpen` (the ack is advisory at S1; a
///   refusal closes the channel via the router, dropping its data, so an unacked-but-refused
///   channel never delivers).
/// - `acceptChannel(_:)` (host/responder) registers a peer-initiated `channelID`.
/// - `closeChannel(_:)` sends `channelClose` on both links and finishes the sub-channels' inbound.
///
/// All mutable state (decoders, routers, dispatch tables) lives inside this `actor`.
public actor MuxNWConnection {
    /// Whether this end allocates channel ids (client/odd) or only registers peer ids (host).
    public enum Role: Sendable { case client, host }

    /// Stable per-connection identity (the wire `connectionID` that paired the CONTROL+DATA
    /// sockets — see ``HostTransport/associateMux``). The host owner namespaces its per-channel
    /// sessions by `(connectionID, channelID)` so that two DISTINCT client connections — which
    /// each allocate `channelID` 1 for their first pane — never collide in one channelID-only map
    /// (which made one connection's close-hook resolve a DIFFERENT connection's live session, and
    /// silently overwrote/orphaned the first connection's session on the second's open). Defaults
    /// to a fresh UUID for the client side / any caller that does not pair on a wire connectionID.
    public nonisolated let connectionID: UUID

    private let role: Role
    private let controlLink: any MuxByteLink
    private let dataLink: any MuxByteLink

    /// One decoder + router per link (the pure demux core). Distinct decoders because each link is
    /// an independent byte stream; the router's channel table is shared per link so a channel's
    /// open/close lifecycle on a link is tracked independently of the other link.
    private var controlDecoder = MuxFrameDecoder()
    private var dataDecoder = MuxFrameDecoder()
    private var controlTable = ChannelTable()
    private var dataTable = ChannelTable()
    /// Allocator (client only): one shared odd-id counter so a pane's data + control sub-channels
    /// get the SAME id. The host registers ids it sees instead.
    private var allocator = ChannelTable()

    /// Per-link dispatch: `channelID → the sub-channel whose inbound to feed`.
    private var controlChannels: [UInt32: MuxSubChannel] = [:]
    private var dataChannels: [UInt32: MuxSubChannel] = [:]

    /// Per-channel RECEIVE accounting on the DATA link: tracks bytes delivered upward and decides
    /// when to emit a `windowAdjust` back to the sender (half-window threshold). Only the DATA link
    /// is flow-controlled; the CONTROL link carries small frames and is never gated.
    private var dataReceiveWindows: [UInt32: ReceiveWindowAccountant] = [:]

    private var receiveTasks: [Task<Void, Never>] = []
    private var closed = false
    /// Set once a link dropped with a HARD error (TCP RST / NetBird flap / decode fault) in
    /// ``finishLink(_:error:)``. Distinct from `closed` (the clean last-channel teardown via ``close()``):
    /// a link-failed connection is dead but was never `close()`d, so without this flag it would linger in
    /// the ``ConnectionRegistry`` pool and a reconnecting pane would re-acquire the corpse ([5]).
    private var linkFailed = false

    /// Whether this connection is unusable — either cleanly closed OR hard-link-failed. The registry
    /// reads it (``ConnectionRegistry/sharedConnection(...)``) to evict a dead pooled connection instead
    /// of handing it to a reconnecting pane, and ``openChannel(...)`` rejects an open on it.
    public var isDead: Bool { closed || linkFailed }

    public init(
        role: Role,
        controlLink: any MuxByteLink,
        dataLink: any MuxByteLink,
        connectionID: UUID = UUID()
    ) {
        self.role = role
        self.controlLink = controlLink
        self.dataLink = dataLink
        self.connectionID = connectionID
    }

    /// Starts the receive loops on both links. Idempotent-safe to call once.
    public func start() {
        guard receiveTasks.isEmpty else { return }
        receiveTasks.append(makeReceiveLoop(for: .control))
        receiveTasks.append(makeReceiveLoop(for: .data))
    }

    // MARK: - Channel open / accept / close

    /// Opens a new logical channel (client/initiator). Allocates an odd `channelID`, registers the
    /// per-link data + control sub-channels, and sends `channelOpen` on the DATA link carrying the
    /// resume hint + class so the host can mint/resume the per-channel session. Returns the
    /// data + control sub-channel pair for ``MuxClientTransport`` to wire into ``RworkClient``.
    ///
    /// S1 does NOT block on `channelOpenAck`: the host opens the channel on first `channelOpen`,
    /// and a refusal (`accepted: false`) closes the channel in the router so its data is dropped —
    /// so an unacked channel never silently delivers to a refused session.
    public func openChannel(
        sessionID: UUID,
        lastReceivedSeq: Int64,
        channelClass: UInt8 = 0
    ) async throws -> (data: MuxSubChannel, control: MuxSubChannel) {
        guard role == .client else {
            throw RworkTransportError.invalidState("openChannel on a host mux connection")
        }
        // Reject an open on a dead connection — closed (clean teardown) OR link-failed (hard drop, [5]).
        // A reconnecting pane must never open a channel on a corpse pooled by the registry.
        guard !isDead else { throw RworkTransportError.notConnected("mux connection closed") }
        let id = allocator.allocate()
        let pair = registerChannels(id: id)
        dataTable.open(id)
        controlTable.open(id)
        // Announce the open on the DATA link (the host registers the peer-initiated channel there).
        let openFrame = MuxEnvelopeCodec.encode(.channelOpen(
            channelID: id,
            sessionID: sessionID,
            lastReceivedSeq: lastReceivedSeq,
            channelClass: channelClass
        ))
        try await dataLink.send(openFrame)
        return pair
    }

    /// Registers a peer-initiated channel (host/responder) and returns its sub-channel pair.
    @discardableResult
    public func acceptChannel(_ id: UInt32) -> (data: MuxSubChannel, control: MuxSubChannel) {
        dataTable.open(id)
        controlTable.open(id)
        return registerChannels(id: id)
    }

    /// Closes `channelID`: sends `channelClose` on both links and finishes its sub-channels'
    /// inbound streams. Other channels on the shared connection are untouched.
    public func closeChannel(_ id: UInt32) async {
        let close = MuxEnvelopeCodec.encode(.channelClose(channelID: id))
        // Best-effort: a failed close write means the shared link is already gone.
        try? await dataLink.send(close)
        try? await controlLink.send(close)
        dataTable.localClose(id)
        controlTable.localClose(id)
        // S2 CLEANUP (foot-gun #2): drop the channel's receive-window accounting and finish the
        // sub-channels. `finish()` wakes any sender parked on an exhausted send window (it throws),
        // so a close while the window is full never leaks a suspended task or half-open credit state.
        dataReceiveWindows.removeValue(forKey: id)
        if let ch = dataChannels.removeValue(forKey: id) { await ch.finish() }
        if let ch = controlChannels.removeValue(forKey: id) { await ch.finish() }
    }

    /// Whether any logical channel is still live on the shared connection. The owner
    /// (``ConnectionRegistry``) tears the shared transport down only when this is empty — so a
    /// single pane closing never drops the connection other panes ride.
    public var hasLiveChannels: Bool {
        !dataChannels.isEmpty || !controlChannels.isEmpty
    }

    /// Tears down the whole shared connection (both links + all receive loops). Called by the
    /// registry only when the LAST channel closes. Finishes every remaining sub-channel's inbound.
    public func close() async {
        guard !closed else { return }
        closed = true
        for task in receiveTasks { task.cancel() }
        receiveTasks.removeAll()
        await controlLink.close()
        await dataLink.close()
        for ch in dataChannels.values { await ch.finish() }
        for ch in controlChannels.values { await ch.finish() }
        dataChannels.removeAll()
        controlChannels.removeAll()
        dataReceiveWindows.removeAll()
    }

    // MARK: - Internals

    private enum Link { case control, data }

    /// Builds the data + control sub-channels for `id`, each with a `muxSend` that wraps this
    /// channel's framed bytes in a `.channelData` envelope and writes them on the matching link.
    private func registerChannels(id: UInt32) -> (data: MuxSubChannel, control: MuxSubChannel) {
        let dataLink = self.dataLink
        let controlLink = self.controlLink
        // DATA sub-channel ALWAYS carries the per-channel SEND window; the CONTROL sub-channel is
        // ALWAYS infinite (sendWindowBytes: nil) so resize/ack/bye/keepalive never block behind a
        // full data window (foot-gun #1/#3).
        let dataCh = MuxSubChannel(channelID: id, channel: .data) { channelID, inner in
            try await dataLink.send(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        let controlCh = MuxSubChannel(channelID: id, channel: .control, sendWindowBytes: nil) { channelID, inner in
            try await controlLink.send(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        dataChannels[id] = dataCh
        controlChannels[id] = controlCh
        dataReceiveWindows[id] = ReceiveWindowAccountant(initialWindow: MuxFlowControl.initialWindowBytes)
        return (dataCh, controlCh)
    }

    private func makeReceiveLoop(for link: Link) -> Task<Void, Never> {
        let chunks = (link == .control ? controlLink : dataLink).receiveChunks
        return Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in chunks {
                    await self.ingest(chunk, on: link)
                }
                await self.finishLink(link, error: nil)
            } catch {
                await self.finishLink(link, error: error)
            }
        }
    }

    /// Feeds a raw chunk into the link's decoder, then routes every complete mux frame through the
    /// pure router into the right per-channel sub-channel.
    ///
    /// ⚠️ Ordering: this is `async` and `route` `await`s each `deliver`/`finish` INLINE on this
    /// actor (NOT a `Task`-per-frame). Each link has a single receive loop that `await`s `ingest`
    /// before reading the next chunk, so frames on one link are delivered to their sub-channels in
    /// strict wire order. Spawning a `Task` per frame (the prior shape) does NOT preserve order —
    /// Swift gives no FIFO guarantee across separately-created Tasks targeting the same actor — so
    /// two consecutive `.channelData` frames for one channel could scramble its byte stream.
    private func ingest(_ chunk: Data, on link: Link) async {
        if link == .control { controlDecoder.append(chunk) } else { dataDecoder.append(chunk) }
        do {
            while let frame = try nextFrame(on: link) {
                await route(frame, on: link)
            }
        } catch {
            // A decode fault loses the byte boundary for the whole link — fatal for the link.
            await finishLink(link, error: error)
        }
    }

    private func nextFrame(on link: Link) throws -> MuxFrame? {
        if link == .control { return try controlDecoder.nextFrame() }
        return try dataDecoder.nextFrame()
    }

    /// Applies the pure ``MuxRoutingCore`` decision for one frame on one link. `async` so it can
    /// `await` per-channel delivery inline (preserving per-link frame order — see ``ingest``).
    private func route(_ frame: MuxFrame, on link: Link) async {
        let decision: MuxRoutingDecision
        if link == .control {
            decision = MuxRoutingCore.route(frame, in: &controlTable)
        } else {
            decision = MuxRoutingCore.route(frame, in: &dataTable)
        }

        // windowAdjust RECEIPT (FIX #2): a peer grant replenishes THIS channel's DATA send window
        // (matched by channelID regardless of which link it arrived on — FIX #2 routes grants via the
        // CONTROL link so they are never starved behind a flooded DATA link) and wakes any sender
        // parked on an exhausted window. A credit grant is NEVER a lifecycle event, so RETURN before
        // the decision switch: MuxRoutingCore reports a windowAdjust as `.lifecycle(state ?? .closed)`
        // PURELY informationally (it does NOT mutate the table), and on the CONTROL link a grant for a
        // channel not (yet/any longer) `.open` in the control table would otherwise be mis-read as a
        // peer close and destructively finish the sub-channel.
        if case let .windowAdjust(id, bytesToAdd) = frame {
            if let dataCh = dataChannels[id] {
                await dataCh.grantCredit(Int(bytesToAdd))
            }
            return
        }

        // The HOST is the responder: a peer-initiated `channelOpen` on the DATA link registers the
        // channel pair so subsequent data routes. (The router already advanced the table; we mirror
        // it into the dispatch tables here, allocating the sub-channels.)
        if role == .host, case let .channelOpen(id, sessionID, lastReceivedSeq, channelClass) = frame, link == .data {
            // Fire the relay open hook ONLY for a NEWLY-registered channel. A DUPLICATE/retransmitted
            // `channelOpen` for an already-live `id` must NOT re-invoke `hostOpenHandler` — that spawns
            // a SECOND PTY and overwrites/orphans the first session in the owner's map (master-fd +
            // child-process + reaper-thread leak, and a split input stream). The `id` is already
            // registered, so its data/control still route; we just suppress the redundant open.
            let isNewChannel = dataChannels[id] == nil
            if isNewChannel { _ = registerChannels(id: id) }
            // Mirror the open into the control table too so control-link data for this id routes.
            controlTable.open(id)
            if isNewChannel, let dataCh = dataChannels[id], let controlCh = controlChannels[id] {
                let open = MuxChannelOpen(
                    channelID: id,
                    sessionID: sessionID,
                    lastReceivedSeq: lastReceivedSeq,
                    channelClass: channelClass,
                    data: dataCh,
                    control: controlCh
                )
                if let handler = hostOpenHandler {
                    handler(open)
                } else {
                    // OPEN-BEFORE-HANDLER RACE: the host receive loops are started in
                    // `HostTransport.associateMux` (`await mux.start()`) and the connection is yielded
                    // to its relay owner, which installs `hostOpenHandler` only afterwards
                    // (`HostServer.handleNewMuxConnection`). The client, meanwhile, sends `channelOpen`
                    // during `connect` WITHOUT waiting for an ack (see `openChannel`), so that frame is
                    // routinely already TCP-buffered when the loop starts — it would otherwise be read
                    // against a nil handler and dropped (channel registered, but NO PTY spawn and NO
                    // ack → the pane silently never comes up; the client then hangs waiting on output).
                    // Queue it and replay the instant the handler attaches. Actor isolation serializes
                    // this block against `setHostOpenHandler`, so neither ordering loses or duplicates
                    // the open.
                    pendingHostOpens.append(open)
                }
            }
        }

        switch decision {
        case let .deliverData(channelID, payload):
            let target = (link == .control) ? controlChannels[channelID] : dataChannels[channelID]
            if let target {
                // Await INLINE (no Task) so this frame is fully delivered before the next frame on
                // this link is routed — per-channel order = wire order.
                let consumed = await target.deliver(payload: payload)
                // RECEIVER emit (FIX #2): account the consumed DATA bytes; once the half-window
                // threshold is crossed, grant the accumulated credit back to the sender via a
                // windowAdjust. The grant is written on the CONTROL link, NOT the DATA link it just
                // drained: under a sustained BIDIRECTIONAL flood the DATA link is full in both
                // directions, so emitting the grant INLINE on the DATA receive loop would block the
                // ONLY task draining inbound DATA on a write that cannot complete until the peer
                // drains — and the peer is symmetrically stuck → classic credit deadlock. The
                // CONTROL sub-channel is infinite-window / small-frame / fast-draining (its whole
                // reason for existing — the data/control split), so the grant always gets out. The
                // receipt side applies a windowAdjust to channel X regardless of which link it
                // arrived on (it matches on channelID, see the receipt block above), so routing it
                // via CONTROL is transparent. Still INLINE on this actor so the grant decision cannot
                // be reordered against the delivery that triggered it.
                if link == .data, let grant = dataReceiveWindows[channelID]?.consume(consumed), grant > 0 {
                    let adjust = MuxEnvelopeCodec.encode(.windowAdjust(channelID: channelID, bytesToAdd: UInt32(grant)))
                    try? await controlLink.send(adjust)
                }
            }
        case let .lifecycle(channelID, newState):
            if newState == .closed || newState == .halfClosed {
                // Peer closed this channel on this link — finish its inbound so the consumer ends.
                // Await inline so a close never overtakes an earlier deliver (dropping the tail).
                let target = (link == .control) ? controlChannels.removeValue(forKey: channelID)
                                                 : dataChannels.removeValue(forKey: channelID)
                if link == .data { dataReceiveWindows.removeValue(forKey: channelID) } // S2: drop credit state
                if let target { await target.finish() }
                // FIX #2: drive the host relay shutdown for a PEER channelClose. S1 has NO
                // per-channel reconnect/resume, so a cleanly-closed channel's shell must NOT
                // be kept alive — otherwise the PTY + master fd leak on every clean close.
                // Keyed off the DATA link (symmetric to the DATA-link `hostOpenHandler` above) so
                // it fires exactly ONCE per channel, AFTER both this link's sub-channel is
                // finished. The host wiring maps this to `removeMuxSession(channelID)` →
                // `MuxChannelSession.shutdown()`. No-op on the client (handler unset).
                // If the handler is not installed YET (this close raced ahead of
                // `setHostCloseHandler`), BUFFER it so the shell is reaped once the handler attaches —
                // never dropped (which would leak the PTY + master fd).
                if role == .host, link == .data {
                    if let hostCloseHandler { hostCloseHandler(channelID) }
                    else { pendingHostCloses.append(channelID) }
                }
            }
        case .dropUnknownChannel:
            break // stale / hostile frame — dropped, never a crash (router contract).
        }
    }

    /// Optional host hook: called when a peer-initiated `channelOpen` is registered on the DATA
    /// link, so the host relay can mint a per-channel session/PTY + send `channelOpenAck`. Set by
    /// the host wiring; unused on the client. The sub-channel pair is already registered when this
    /// fires, so the relay can drive it immediately.
    private var hostOpenHandler: (@Sendable (MuxChannelOpen) -> Void)?

    /// Channel opens that arrived on the DATA link BEFORE the relay owner installed `hostOpenHandler`
    /// (see the OPEN-BEFORE-HANDLER RACE note in `route`). Drained in order by `setHostOpenHandler`.
    private var pendingHostOpens: [MuxChannelOpen] = []

    /// Installs the host's per-channel-open handler (mint session + ack). Host-only. Replays any
    /// opens that raced ahead of the install (queued in `pendingHostOpens`) in arrival order, so a
    /// `channelOpen` buffered before the owner wired up is never lost.
    public func setHostOpenHandler(_ handler: @escaping @Sendable (MuxChannelOpen) -> Void) {
        hostOpenHandler = handler
        guard !pendingHostOpens.isEmpty else { return }
        let queued = pendingHostOpens
        pendingHostOpens.removeAll()
        for open in queued { handler(open) }
    }

    /// Optional host hook (FIX #2): called when a PEER `channelClose` is routed on the DATA link,
    /// AFTER the channel's sub-channels are finished, so the host relay can shut its per-channel
    /// session (close the PTY + master fd). Set by the host wiring; unused on the client. Fires
    /// exactly once per channel because the DATA-link entry is removed before this returns.
    private var hostCloseHandler: (@Sendable (UInt32) -> Void)?

    /// Channel closes (peer `channelClose` / link drop) routed on the DATA link BEFORE the relay owner
    /// installed `hostCloseHandler`. SYMMETRIC to `pendingHostOpens`: the host installs the open handler
    /// first, then the close handler (`HostServer.handleNewMuxConnection`), so a `channelClose` that
    /// races into the gap — a client that opens then immediately closes a pane, or a link drop right
    /// after accept — would otherwise hit a nil `hostCloseHandler` and be DROPPED, leaking that pane's
    /// PTY + master fd forever (the open spawned a shell that nothing ever reaps). Drained in order by
    /// `setHostCloseHandler`, AFTER the open handler has already replayed `pendingHostOpens` — so the
    /// spawn always precedes its shutdown.
    private var pendingHostCloses: [UInt32] = []

    /// Installs the host's per-channel-close handler (shut session + free PTY/fd). Host-only. Replays
    /// any closes that raced ahead of the install (queued in `pendingHostCloses`) in arrival order, so a
    /// `channelClose` buffered before the owner wired up is never lost (no leaked shell).
    public func setHostCloseHandler(_ handler: @escaping @Sendable (UInt32) -> Void) {
        hostCloseHandler = handler
        guard !pendingHostCloses.isEmpty else { return }
        let queued = pendingHostCloses
        pendingHostCloses.removeAll()
        for channelID in queued { handler(channelID) }
    }

    /// Sends a `channelOpenAck` for `id` on the DATA link (host → client). Host-only.
    public func sendOpenAck(_ id: UInt32, accepted: Bool) async {
        let frame = MuxEnvelopeCodec.encode(.channelOpenAck(channelID: id, accepted: accepted))
        try? await dataLink.send(frame)
    }

    /// Test seam: emits a `windowAdjust` for `channelID` on the CONTROL link — matching the FIX #2
    /// production emit path (the grant rides CONTROL so it is never starved behind a flooded DATA
    /// link). The receiver-emit path (``route``) sends these organically as it consumes data; this
    /// lets a test inject an explicit grant without driving a full echo loop. The receipt side
    /// applies the grant to the DATA send window regardless of arrival link (FIX #2). No-op (still
    /// byte-safe) when flow control is OFF, but only called by flow-on tests.
    func grantWindowForTest(channelID: UInt32, bytesToAdd: UInt32) async {
        let frame = MuxEnvelopeCodec.encode(.windowAdjust(channelID: channelID, bytesToAdd: bytesToAdd))
        try? await controlLink.send(frame)
    }

    private func finishLink(_ link: Link, error: Error?) async {
        // A non-nil error is a HARD link failure (TCP RST / NetBird flap / decode fault) — the whole
        // physical connection is dead, distinct from a clean per-channel FIN (`error == nil`). Mark it
        // so a reconnecting pane never re-acquires this corpse from the pool (`ConnectionRegistry`
        // evicts a `isDead` entry; `openChannel` rejects reuse). See `linkFailed` / `isDead`. ([5])
        if error != nil { linkFailed = true }
        let channels = (link == .control) ? controlChannels : dataChannels
        for ch in channels.values {
            // Await inline so the link's FIN/error finishes each sub-channel AFTER its last
            // delivered frame, never racing ahead of in-flight data (which would drop the tail).
            if let error { await ch.finish(throwing: error) }
            else { await ch.finish() }
        }
        // FIX #2 (SECONDARY — crash/link-drop leak, the TCP-mux analogue of CONCURRENCY-HOST-1):
        // when the whole shared DATA link drops WITHOUT a per-channel `channelClose` (peer crash /
        // TCP reset), every channel riding it is dead and — since S1 has no per-channel
        // reconnect/resume — its shell must be reaped. Drive the host close hook per channel here.
        // Keyed off the DATA link (mirrors the open + the per-channel close above) so it fires once
        // per channel; `removeMuxSession` is idempotent so any overlap with an `onExit` is harmless.
        // If the handler is not installed yet, buffer (symmetric to the per-channel close path).
        if role == .host, link == .data {
            if let hostCloseHandler {
                for id in channels.keys { hostCloseHandler(id) }
            } else {
                pendingHostCloses.append(contentsOf: channels.keys)
            }
        }
        // S2: the whole DATA link is gone — drop every channel's receive-window accounting. (The
        // send windows are torn down via each sub-channel's `finish()` above, which also wakes any
        // parked sender so the link drop never leaks a suspended task.)
        if link == .data { dataReceiveWindows.removeAll() }
    }
}

/// A peer-initiated channel-open delivered to the host relay: the channelID + the resume hint the
/// client sent, plus the already-registered data + control sub-channels so the relay can drive the
/// per-channel PTY immediately. A value type so it crosses into the relay's actor cleanly.
public struct MuxChannelOpen: Sendable {
    public let channelID: UInt32
    public let sessionID: UUID
    public let lastReceivedSeq: Int64
    public let channelClass: UInt8
    public let data: MuxSubChannel
    public let control: MuxSubChannel
}
