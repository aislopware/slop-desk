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
/// ### Why two links (CONTROL + DATA), mirroring ``RworkConnection``
/// The shared connection keeps the same data/control split a single session has today: a burst of
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

    private var receiveTasks: [Task<Void, Never>] = []
    private var closed = false

    public init(role: Role, controlLink: any MuxByteLink, dataLink: any MuxByteLink) {
        self.role = role
        self.controlLink = controlLink
        self.dataLink = dataLink
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
        guard !closed else { throw RworkTransportError.notConnected("mux connection closed") }
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
    }

    // MARK: - Internals

    private enum Link { case control, data }

    /// Builds the data + control sub-channels for `id`, each with a `muxSend` that wraps this
    /// channel's framed bytes in a `.channelData` envelope and writes them on the matching link.
    private func registerChannels(id: UInt32) -> (data: MuxSubChannel, control: MuxSubChannel) {
        let dataLink = self.dataLink
        let controlLink = self.controlLink
        let dataCh = MuxSubChannel(channelID: id, channel: .data) { channelID, inner in
            try await dataLink.send(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        let controlCh = MuxSubChannel(channelID: id, channel: .control) { channelID, inner in
            try await controlLink.send(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        dataChannels[id] = dataCh
        controlChannels[id] = controlCh
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

        // The HOST is the responder: a peer-initiated `channelOpen` on the DATA link registers the
        // channel pair so subsequent data routes. (The router already advanced the table; we mirror
        // it into the dispatch tables here, allocating the sub-channels.)
        if role == .host, case let .channelOpen(id, sessionID, lastReceivedSeq, channelClass) = frame, link == .data {
            if dataChannels[id] == nil { _ = registerChannels(id: id) }
            // Mirror the open into the control table too so control-link data for this id routes.
            controlTable.open(id)
            if let dataCh = dataChannels[id], let controlCh = controlChannels[id] {
                hostOpenHandler?(MuxChannelOpen(
                    channelID: id,
                    sessionID: sessionID,
                    lastReceivedSeq: lastReceivedSeq,
                    channelClass: channelClass,
                    data: dataCh,
                    control: controlCh
                ))
            }
        }

        switch decision {
        case let .deliverData(channelID, payload):
            let target = (link == .control) ? controlChannels[channelID] : dataChannels[channelID]
            if let target {
                // Await INLINE (no Task) so this frame is fully delivered before the next frame on
                // this link is routed — per-channel order = wire order.
                await target.deliver(payload: payload)
            }
        case let .lifecycle(channelID, newState):
            if newState == .closed || newState == .halfClosed {
                // Peer closed this channel on this link — finish its inbound so the consumer ends.
                // Await inline so a close never overtakes an earlier deliver (dropping the tail).
                let target = (link == .control) ? controlChannels.removeValue(forKey: channelID)
                                                 : dataChannels.removeValue(forKey: channelID)
                if let target { await target.finish() }
                // FIX #2: drive the host relay shutdown for a PEER channelClose. S1 has NO
                // per-channel reconnect/resume, so a cleanly-closed channel's shell must NOT
                // be kept alive — otherwise the PTY + master fd leak on every clean close.
                // Keyed off the DATA link (symmetric to the DATA-link `hostOpenHandler` above) so
                // it fires exactly ONCE per channel, AFTER both this link's sub-channel is
                // finished. The host wiring maps this to `removeMuxSession(channelID)` →
                // `MuxChannelSession.shutdown()`. No-op on the client (handler unset).
                if role == .host, link == .data { hostCloseHandler?(channelID) }
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

    /// Installs the host's per-channel-open handler (mint session + ack). Host-only.
    public func setHostOpenHandler(_ handler: @escaping @Sendable (MuxChannelOpen) -> Void) {
        hostOpenHandler = handler
    }

    /// Optional host hook (FIX #2): called when a PEER `channelClose` is routed on the DATA link,
    /// AFTER the channel's sub-channels are finished, so the host relay can shut its per-channel
    /// session (close the PTY + master fd). Set by the host wiring; unused on the client. Fires
    /// exactly once per channel because the DATA-link entry is removed before this returns.
    private var hostCloseHandler: (@Sendable (UInt32) -> Void)?

    /// Installs the host's per-channel-close handler (shut session + free PTY/fd). Host-only.
    public func setHostCloseHandler(_ handler: @escaping @Sendable (UInt32) -> Void) {
        hostCloseHandler = handler
    }

    /// Sends a `channelOpenAck` for `id` on the DATA link (host → client). Host-only.
    public func sendOpenAck(_ id: UInt32, accepted: Bool) async {
        let frame = MuxEnvelopeCodec.encode(.channelOpenAck(channelID: id, accepted: accepted))
        try? await dataLink.send(frame)
    }

    private func finishLink(_ link: Link, error: Error?) async {
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
        if role == .host, link == .data, let hostCloseHandler {
            for id in channels.keys { hostCloseHandler(id) }
        }
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
