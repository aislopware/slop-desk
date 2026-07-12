import Foundation
import SlopDeskProtocol

/// The shared physical mux connection for one host: ONE CONTROL ``MuxByteLink`` + ONE DATA
/// ``MuxByteLink``, each carrying many panes' logical channels multiplexed by `channelID`.
///
/// The IO layer for the pure ``MuxRouter`` / ``HostChannelRouter``: owns one ``MuxFrameDecoder``
/// per link, runs a receive loop on each, and dispatches every decoded ``MuxFrame`` through the
/// router into the right per-channel ``MuxSubChannel``. So interleaved frames from many panes on
/// one socket land on the correct per-pane inbound stream — the headline TCP-mux property.
///
/// ### Why two links (CONTROL + DATA)
/// A data/control split: a burst of PTY `output` (`.channelData` on the DATA link) cannot delay a
/// `resize`/`ack`/`bye` on the CONTROL link — for EVERY pane, not just one. Each pane gets a pair
/// of ``MuxSubChannel``s sharing one `channelID`: a data sub-channel on the DATA link and a
/// control sub-channel on the CONTROL link. ``MuxClientTransport`` pairs them back into the
/// data/control surface ``SlopDeskClient`` expects.
///
/// ### Lifecycle
/// - `openChannel()` (client/initiator) allocates an odd `channelID`, registers the per-link
///   sub-channels, sends `channelOpen` on the DATA link, and returns the pair WITHOUT waiting for
///   an ack — the host opens lazily on first `channelOpen` (the ack is advisory; a refusal closes
///   the channel via the router, dropping its data, so an unacked-but-refused channel never
///   delivers).
/// - `acceptChannel(_:)` (host/responder) registers a peer-initiated `channelID`.
/// - `closeChannel(_:)` sends `channelClose` on both links and finishes the sub-channels' inbound.
///
/// All mutable state (decoders, routers, dispatch tables) lives inside this `actor`.
public actor MuxNWConnection {
    /// Whether this end allocates channel ids (client/odd) or only registers peer ids (host).
    public enum Role: Sendable { case client, host }

    /// Stable per-connection identity (the wire `connectionID` that paired the CONTROL+DATA
    /// sockets — see ``HostTransport/associateMux``). The host namespaces its per-channel sessions
    /// by `(connectionID, channelID)` so two DISTINCT client connections — each allocating
    /// `channelID` 1 for their first pane — never collide in a channelID-only map (which let one
    /// connection's close-hook resolve a DIFFERENT connection's session, overwriting/orphaning it
    /// on the second's open). Defaults to a fresh UUID on the client / any caller not pairing on a
    /// wire connectionID.
    public nonisolated let connectionID: UUID

    private let role: Role
    private let controlLink: any MuxByteLink
    private let dataLink: any MuxByteLink

    /// When `true`, a whole-link DROP on the DATA link routes to detach (``linkDownHandler``)
    /// instead of killing each channel's shell individually. Set by the host wiring
    /// (``HostServer.handleNewMuxConnection``) to `detachEnabled`:
    ///   - `true`  → DATA-link end (clean FIN **or** hard error) fires ``linkDownHandler`` ONCE and
    ///              skips the per-channel `hostCloseHandler` kill — ``HostServer.handleLinkDown``
    ///              detaches every session, keeping shells alive for a reconnecting client.
    ///   - `false` → per-channel `hostCloseHandler` kills each shell directly;
    ///              ``linkDownHandler`` fires ONLY on a hard error (error ≠ nil).
    ///
    /// The EXPLICIT per-channel channelClose path (`.lifecycle(.closed)` in ``route``) is
    /// unaffected: a peer channelClose (one pane ⌘W) always kills that pane's shell.
    public var detachShellsOnLinkDrop: Bool = false

    /// One decoder + router per link (the pure demux core). Distinct decoders because each link is
    /// an independent byte stream; the per-link channel table tracks a channel's open/close
    /// lifecycle independently of the other link.
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
    /// ``finishLink(_:error:)``. Distinct from `closed` (clean last-channel teardown via ``close()``):
    /// a link-failed connection is dead but never `close()`d, so without this flag it would linger in
    /// the ``ConnectionRegistry`` pool and a reconnecting pane would re-acquire the corpse.
    private var linkFailed = false

    /// Whether this connection is unusable — cleanly closed OR hard-link-failed. The registry reads
    /// it (``ConnectionRegistry/sharedConnection(...)``) to evict a dead pooled connection instead of
    /// handing it to a reconnecting pane; ``openChannel(...)`` rejects an open on it.
    public var isDead: Bool { closed || linkFailed }

    public init(
        role: Role,
        controlLink: any MuxByteLink,
        dataLink: any MuxByteLink,
        connectionID: UUID = UUID(),
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
    /// data + control sub-channel pair for ``MuxClientTransport`` to wire into ``SlopDeskClient``.
    ///
    /// `openChannel` does NOT block on `channelOpenAck`: the host opens on first `channelOpen`, and a
    /// refusal (`accepted: false`) closes the channel in the router so its data is dropped — an
    /// unacked channel never silently delivers to a refused session.
    public func openChannel(
        sessionID: UUID,
        lastReceivedSeq: Int64,
        channelClass: UInt8 = 0,
        initialCwd: String? = nil,
    ) async throws -> (data: MuxSubChannel, control: MuxSubChannel) {
        guard role == .client else {
            throw SlopDeskTransportError.invalidState("openChannel on a host mux connection")
        }
        // Reject an open on a dead connection — closed (clean teardown) OR link-failed (hard drop).
        // A reconnecting pane must never open a channel on a corpse pooled by the registry.
        guard !isDead else { throw SlopDeskTransportError.notConnected("mux connection closed") }
        let id = allocator.allocate()
        let pair = registerChannels(id: id)
        dataTable.open(id)
        controlTable.open(id)
        // Announce the open on the DATA link (the host registers the peer-initiated channel there).
        let openFrame = MuxEnvelopeCodec.encode(.channelOpen(
            channelID: id,
            sessionID: sessionID,
            lastReceivedSeq: lastReceivedSeq,
            channelClass: channelClass,
            initialCwd: initialCwd,
        ))
        do {
            try await dataLink.send(openFrame)
        } catch {
            // A failed send means the shared link is dead → UNDO this open's partial registration so
            // it leaves no GHOST channel. registerChannels() already inserted dataChannels[id] /
            // controlChannels[id] / dataReceiveWindows[id] and the tables opened `id`.
            // ConnectionRegistry's catch tears the WHOLE connection down only when this was the LAST
            // channel; with a surviving sibling the connection is kept and this orphan would leak
            // forever (keeping `hasLiveChannels` true after every real channel closes). Clean up + rethrow.
            await pair.data.finish()
            await pair.control.finish()
            dataChannels.removeValue(forKey: id)
            controlChannels.removeValue(forKey: id)
            dataReceiveWindows.removeValue(forKey: id)
            dataTable.localClose(id)
            controlTable.localClose(id)
            throw error
        }
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
        // Best-effort + pipelined: NWConnection FIFO guarantees the close follows any prior
        // data; a failed write means the shared link is already gone, so the failure is left to
        // surface via the link-down path rather than thrown here.
        dataLink.sendPipelined(close)
        controlLink.sendPipelined(close)
        dataTable.localClose(id)
        controlTable.localClose(id)
        // Drop the channel's receive-window accounting and finish the sub-channels. `finish()` wakes
        // any sender parked on an exhausted send window (it throws), so a close while the window is
        // full never leaks a suspended task or half-open credit state.
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

    /// Test-only: id-entry count the DATA router table retains — asserts a hostile channelOpen storm
    /// cannot grow the router table past the channel cap.
    var dataTableStateCountForTesting: Int { dataTable.stateCount }

    /// Test-only: id-entry count the CONTROL router table retains — asserts a hostile `channelOpen`
    /// storm on the CONTROL link (never a legitimate frame there) cannot grow the control table at
    /// all; the frame is dropped before `MuxRoutingCore.route` would `open(id)` a phantom entry.
    var controlTableStateCountForTesting: Int { controlTable.stateCount }

    /// Tears down the whole shared connection (both links + all receive loops). Called by the
    /// registry only when the LAST channel closes. Finishes every remaining sub-channel's inbound.
    public func close() async {
        guard !closed else { return }
        closed = true
        // `close()` can be reached via the link-down reap (`setLinkDownHandler` →
        // `HostServer.removeMuxConnection` → here) when the CONTROL link fails FIRST. That path cancels
        // the DATA receive loop below before its `finishLink(.data, …)` fires `hostCloseHandler` to reap
        // the per-channel PTYs — so without reaping HERE, every live pane's PTY + master fd + child +
        // reaper thread leaks on a control-first drop. Reap every still-registered channel through
        // `hostCloseHandler` NOW, while the maps are intact, before cancelling the loops / clearing the
        // maps / nil-ing the handler. Idempotent with `HostServer.removeMuxSession`'s map guard and the
        // `onExit` path, so a normal `channelClose` that already reaped (or a `stop()` that already
        // drained) is a harmless no-op. Host-only; the client never installs `hostCloseHandler`.
        if role == .host, let reap = hostCloseHandler {
            let liveIDs = Set(dataChannels.keys).union(controlChannels.keys).union(pendingHostCloses)
            for id in liveIDs { reap(id) }
        }
        for task in receiveTasks { task.cancel() }
        receiveTasks.removeAll()
        await controlLink.close()
        await dataLink.close()
        for ch in dataChannels.values { await ch.finish() }
        for ch in controlChannels.values { await ch.finish() }
        dataChannels.removeAll()
        controlChannels.removeAll()
        dataReceiveWindows.removeAll()
        // Release the host's stored handler closures. They capture host state (a strong capture would
        // form a connection → handler → connection retain cycle); nil-ing them on close guarantees a
        // closed connection is no longer kept alive by its own handlers. Idempotent (close() guarded
        // by `closed`). Host installs them; the client never sets them.
        hostOpenHandler = nil
        hostCloseHandler = nil
        linkDownHandler = nil
        linkDownFired = true
        pendingHostOpens.removeAll()
        pendingHostCloses.removeAll()
    }

    // MARK: - Internals

    private enum Link { case control, data }

    /// Builds the data + control sub-channels for `id`, each with a `muxSend` that wraps this
    /// channel's framed bytes in a `.channelData` envelope and writes them on the matching link.
    private func registerChannels(id: UInt32) -> (data: MuxSubChannel, control: MuxSubChannel) {
        let dataLink = dataLink
        let controlLink = controlLink
        // DATA sub-channel ALWAYS carries the per-channel SEND window; CONTROL is ALWAYS infinite
        // (sendWindowBytes: nil) so resize/ack/bye/keepalive never block behind a full data window
        // (foot-gun #1/#3).
        // DATA = hot path (PTY output / input / exit): PIPELINED — enqueue in call order with no
        // per-frame dispatch round trip; in-flight bytes bounded by the credit window (debited before
        // the send inside MuxSubChannel), and every data caller already `try?`s. CONTROL stays AWAITED:
        // its send throws are load-bearing (SlopDeskClient.flushAckIfPending re-arms ackPending on a
        // throw) and it is low-rate, so the round trip costs nothing.
        // The DATA sub-channel's consumedSink routes the consumer's "processed N wire bytes" signal
        // back here (credit-at-CONSUMPTION — see recordConsumed).
        let dataCh = MuxSubChannel(channelID: id, channel: .data, consumedSink: { [weak self] bytes in
            await self?.recordConsumed(id, bytes: bytes)
        }) { channelID, inner in
            dataLink.sendPipelined(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        let controlCh = MuxSubChannel(channelID: id, channel: .control, sendWindowBytes: nil) { channelID, inner in
            try await controlLink.send(MuxEnvelopeCodec.encode(.channelData(channelID: channelID, payload: inner)))
        }
        dataChannels[id] = dataCh
        controlChannels[id] = controlCh
        dataReceiveWindows[id] = ReceiveWindowAccountant(initialWindow: MuxFlowControl.initialWindowBytes)
        return (dataCh, controlCh)
    }

    /// Credit-at-CONSUMPTION receiver emit: accounts `bytes` the channel's REAL consumer reports
    /// (client render drain ingested a batch / host PTY writer wrote an input frame) and, once the
    /// accountant's threshold is crossed, grants the accumulated credit back to the sender. The grant
    /// rides the CONTROL link (never starved behind a flooded DATA link) and is PIPELINED (must never
    /// suspend — callable from any consumer context). A closed channel's accountant is already removed
    /// (closeChannel/finishLink) → no-op.
    private func recordConsumed(_ id: UInt32, bytes: Int) {
        guard let grant = dataReceiveWindows[id]?.consume(bytes), grant > 0 else { return }
        let adjust = MuxEnvelopeCodec.encode(.windowAdjust(channelID: id, bytesToAdd: UInt32(grant)))
        controlLink.sendPipelined(adjust)
    }

    private func makeReceiveLoop(for link: Link) -> Task<Void, Never> {
        let chunks = (link == .control ? controlLink : dataLink).receiveChunks
        return Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in chunks {
                    await ingest(chunk, on: link)
                }
                await finishLink(link, error: nil)
            } catch {
                await finishLink(link, error: error)
            }
        }
    }

    /// Feeds a raw chunk into the link's decoder, then routes every complete mux frame through the
    /// pure router into the right per-channel sub-channel.
    ///
    /// ⚠️ Ordering: `async`, and `route` `await`s each `deliver`/`finish` INLINE on this actor (NOT
    /// a `Task`-per-frame). Each link's single receive loop `await`s `ingest` before reading the next
    /// chunk, so frames on one link reach their sub-channels in strict wire order. A `Task` per frame
    /// (the prior shape) does NOT preserve order — Swift gives no FIFO guarantee across separately
    /// created Tasks targeting one actor — so two consecutive `.channelData` frames for one channel
    /// could scramble its byte stream.
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
        // Enforce the per-connection channel cap BEFORE the router records the new id in
        // `dataTable.states`. Checking AFTER `MuxRoutingCore.route` advances the table would let a
        // hostile peer spamming distinct over-cap `channelOpen` ids still grow the router table
        // without bound (a cheap memory-DoS; the EXPENSIVE PTY/fork is already bounded). Refuse a NEW
        // over-cap open here and RETURN without advancing the table or registering.
        if role == .host, link == .data, case let .channelOpen(id, _, _, _, _) = frame,
           dataChannels[id] == nil, dataChannels.count >= MuxFlowControl.maxChannelsPerConnection
        {
            // Pipelined: emitted from the receive loop — must never suspend it (same
            // rationale as the windowAdjust grant below).
            let refusal = MuxEnvelopeCodec.encode(.channelOpenAck(channelID: id, accepted: false))
            dataLink.sendPipelined(refusal)
            return
        }
        // A `channelOpen` is NEVER legitimate on the CONTROL link — the client always opens on the
        // DATA link (`openChannel` → `dataLink.send`). The cap above is `link == .data`, so a hostile
        // peer could otherwise spam channelOpen on the CONTROL link and grow `controlTable` without
        // bound. Drop it before `MuxRoutingCore.route` (which would `open(id)` a phantom controlTable
        // entry).
        if link == .control, case .channelOpen = frame { return }
        // The CLIENT never legitimately receives `channelOpen` either — the host is a pure responder
        // (every open originates in the client's `openChannel`). Routing one would `open(id)` a
        // phantom entry in the client's dataTable that is never closed and therefore never
        // ring-evicted (the terminal ring only bounds half-closed/closed ids): unbounded state growth
        // from a buggy/compromised host — the client-side mirror of the CONTROL-link drop above and of
        // the host's over-cap refusal, which are both host/control-only.
        if role == .client, case .channelOpen = frame { return }
        // A `channelOpen` for an id that already reached a TERMINAL state on this connection is a
        // stale/hostile REOPEN — ids are monotonic and never reused by a well-behaved client. The
        // dispatch entry was removed at close, so the registration block's `dataChannels[id] == nil`
        // gate alone would re-register the id and re-invoke `hostOpenHandler`: one fresh PTY fork per
        // open→close cycle on a SINGLE reused id, unbounded — the live-channel cap never trips (count
        // stays ~1 during churn) and the ChannelTable ring only bounds table MEMORY, not spawns.
        // Refuse before the router.
        if role == .host, link == .data, case let .channelOpen(id, _, _, _, _) = frame,
           let priorState = dataTable.state(of: id), priorState == .closed || priorState == .halfClosed
        {
            let refusal = MuxEnvelopeCodec.encode(.channelOpenAck(channelID: id, accepted: false))
            dataLink.sendPipelined(refusal)
            return
        }

        let decision: MuxRoutingDecision =
            if link == .control {
                MuxRoutingCore.route(frame, in: &controlTable)
            } else {
                MuxRoutingCore.route(frame, in: &dataTable)
            }

        // windowAdjust RECEIPT: a peer grant replenishes THIS channel's DATA send window (matched by
        // channelID regardless of arrival link — grants ride CONTROL so they're never starved behind a
        // flooded DATA link) and wakes any sender parked on an exhausted window. A grant is NEVER a
        // lifecycle event, so RETURN before the decision switch: MuxRoutingCore reports a windowAdjust
        // as `.lifecycle(state ?? .closed)` PURELY informationally (no table mutation), and on the
        // CONTROL link a grant for a channel not `.open` in the control table would otherwise be
        // mis-read as a peer close and destructively finish the sub-channel.
        if case let .windowAdjust(id, bytesToAdd) = frame {
            if let dataCh = dataChannels[id] {
                await dataCh.grantCredit(Int(bytesToAdd))
            }
            return
        }

        // The HOST is the responder: a peer-initiated `channelOpen` on the DATA link registers the
        // channel pair so subsequent data routes. (The router already advanced the table; we mirror
        // it into the dispatch tables here, allocating the sub-channels.)
        if role == .host,
           case let .channelOpen(id, sessionID, lastReceivedSeq, channelClass, initialCwd) = frame,
           link == .data
        {
            // Fire the relay open hook ONLY for a NEWLY-registered channel. A DUPLICATE/retransmitted
            // `channelOpen` for an already-live `id` must NOT re-invoke `hostOpenHandler` — that spawns
            // a SECOND PTY and overwrites/orphans the first session (master-fd + child-process +
            // reaper-thread leak, split input stream). The `id` is already registered, so its
            // data/control still route; just suppress the redundant open. Over-cap NEW opens are
            // already refused at the top of route(), so any channelOpen here is within cap.
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
                    initialCwd: initialCwd,
                    data: dataCh,
                    control: controlCh,
                )
                if let handler = hostOpenHandler {
                    handler(open)
                } else {
                    // OPEN-BEFORE-HANDLER RACE: the host receive loops start in
                    // `HostTransport.associateMux` (`await mux.start()`) and the connection is yielded
                    // to its relay owner, which installs `hostOpenHandler` only afterwards
                    // (`HostServer.handleNewMuxConnection`). The client sends `channelOpen` during
                    // `connect` WITHOUT waiting for an ack (see `openChannel`), so that frame is
                    // routinely already TCP-buffered when the loop starts — otherwise read against a nil
                    // handler and dropped (channel registered, but NO PTY spawn and NO ack → the pane
                    // silently never comes up; the client hangs waiting on output). Queue it and replay
                    // the instant the handler attaches. Actor isolation serializes this block against
                    // `setHostOpenHandler`, so no ordering loses or duplicates the open.
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
                //
                // NO credit granted here (credit-at-CONSUMPTION): granting at demux time would let an
                // output flood buffer WITHOUT BOUND in the client (the demux always keeps up with the
                // wire, so the host's PTY-pause backpressure would never engage against a slow renderer
                // — megabytes queued between demux and the main thread, and Ctrl-C would have to chew
                // through all of it). The grant fires from `recordConsumed` when the REAL consumer
                // reports consumption via `MuxSubChannel.noteConsumed`, bounding un-consumed bytes to
                // ~one window.
                await target.deliver(payload: payload)
            }
        case let .lifecycle(channelID, newState):
            if newState == .closed || newState == .halfClosed {
                // Peer closed this channel on this link — finish its inbound so the consumer ends.
                // Await inline so a close never overtakes an earlier deliver (dropping the tail).
                let target = (link == .control) ? controlChannels.removeValue(forKey: channelID)
                    : dataChannels.removeValue(forKey: channelID)
                if link == .data { dataReceiveWindows.removeValue(forKey: channelID) } // drop credit state
                if let target { await target.finish() }
                // Drive host relay shutdown for a PEER channelClose. Without a per-channel
                // reconnect/resume mechanism, a cleanly-closed channel's shell must NOT be kept alive —
                // otherwise the PTY + master fd leak on every clean close. Keyed off the DATA link
                // (symmetric to the DATA-link `hostOpenHandler` above) so it fires exactly ONCE per
                // channel, AFTER this link's sub-channel is finished. Host wiring maps it to
                // `removeMuxSession(channelID)` → `MuxChannelSession.shutdown()`. No-op on the client.
                // If the handler is not installed YET (close raced ahead of `setHostCloseHandler`),
                // BUFFER it so the shell is reaped once the handler attaches — never dropped (PTY +
                // master fd leak).
                if role == .host, link == .data {
                    // Symmetric to the channelOpen mirror (registerChannels + `controlTable.open` at
                    // open): a peer close on the DATA link tears down the WHOLE channel, so also drop the
                    // CONTROL sub-channel and advance the control table to terminal. A well-behaved client
                    // ALSO sends channelClose on the control link (closeChannel sends both) → harmless
                    // no-op there — but a peer closing on DATA ONLY would otherwise leak controlChannels[id]
                    // + a zombie `.open` controlTable[id] forever, unbounded sub-channel + router-table
                    // growth the live-count cap never catches under open/close churn. The terminal
                    // control-table entry is then bounded by ChannelTable's eviction ring.
                    if let controlCh = controlChannels.removeValue(forKey: channelID) { await controlCh.finish() }
                    controlTable.remoteClose(channelID)
                    if let hostCloseHandler { hostCloseHandler(channelID) } else { pendingHostCloses.append(channelID) }
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
    @preconcurrency
    public func setHostOpenHandler(_ handler: @escaping @Sendable (MuxChannelOpen) -> Void) {
        hostOpenHandler = handler
        guard !pendingHostOpens.isEmpty else { return }
        let queued = pendingHostOpens
        pendingHostOpens.removeAll()
        for open in queued { handler(open) }
    }

    /// Optional host hook: called when a PEER `channelClose` is routed on the DATA link,
    /// AFTER the channel's sub-channels are finished, so the host relay can shut its per-channel
    /// session (close the PTY + master fd). Set by the host wiring; unused on the client. Fires
    /// exactly once per channel because the DATA-link entry is removed before this returns.
    private var hostCloseHandler: (@Sendable (UInt32) -> Void)?

    /// Channel closes (peer `channelClose` / link drop) routed on the DATA link BEFORE the relay owner
    /// installed `hostCloseHandler`. SYMMETRIC to `pendingHostOpens`: the host installs the open handler
    /// first, then the close handler (`HostServer.handleNewMuxConnection`), so a `channelClose` racing
    /// into the gap — a client that opens then immediately closes a pane, or a link drop right after
    /// accept — would otherwise hit a nil `hostCloseHandler` and be DROPPED, leaking that pane's PTY +
    /// master fd forever (the open spawned a shell nothing ever reaps). Drained in order by
    /// `setHostCloseHandler`, AFTER the open handler replayed `pendingHostOpens` — so spawn always
    /// precedes shutdown.
    private var pendingHostCloses: [UInt32] = []

    /// Installs the host's per-channel-close handler (shut session + free PTY/fd). Host-only. Replays
    /// any closes that raced ahead of the install (queued in `pendingHostCloses`) in arrival order, so a
    /// `channelClose` buffered before the owner wired up is never lost (no leaked shell).
    @preconcurrency
    public func setHostCloseHandler(_ handler: @escaping @Sendable (UInt32) -> Void) {
        hostCloseHandler = handler
        guard !pendingHostCloses.isEmpty else { return }
        let queued = pendingHostCloses
        pendingHostCloses.removeAll()
        for channelID in queued { handler(channelID) }
    }

    /// Optional host hook: fired EXACTLY ONCE when the physical connection dies via a HARD link
    /// failure (TCP RST / NetBird flap / decode fault), so the host can drop it from its retention
    /// map + ``close()`` it — freeing the 2 sockets + 2 receive tasks and breaking the handler retain
    /// cycle. A clean per-channel FIN (`error == nil` in ``finishLink``) is NOT a connection death and
    /// does NOT fire it. Host-only; the handler must capture the connectionID, never the connection.
    private var linkDownHandler: (@Sendable () -> Void)?
    /// Guards ``linkDownHandler`` to fire at most once (both links typically fail together on a drop).
    private var linkDownFired = false

    /// Installs the host's connection-death hook (see ``linkDownHandler``). If the link ALREADY failed
    /// before the install, fires immediately so a connection that died during accept is still reaped.
    @preconcurrency
    public func setLinkDownHandler(_ handler: @escaping @Sendable () -> Void) {
        if linkFailed, !linkDownFired {
            linkDownFired = true
            handler()
            return
        }
        linkDownHandler = handler
    }

    /// Sets ``detachShellsOnLinkDrop`` on the actor. Called by the host wiring before the receive
    /// loops start (``HostServer.handleNewMuxConnection``). Actor-isolated so the flag is visible to
    /// ``finishLink`` with the same isolation guarantee as the other host handlers.
    public func setDetachShellsOnLinkDrop(_ enabled: Bool) {
        detachShellsOnLinkDrop = enabled
    }

    /// Sends a `channelOpenAck` for `id` on the DATA link (host → client). Host-only.
    public func sendOpenAck(_ id: UInt32, accepted: Bool) {
        let frame = MuxEnvelopeCodec.encode(.channelOpenAck(channelID: id, accepted: accepted))
        dataLink.sendPipelined(frame)
    }

    /// Test seam: emits a `windowAdjust` for `channelID` on the CONTROL link — matching the
    /// production emit path (the grant rides CONTROL so it is never starved behind a flooded DATA
    /// link). Lets a test inject an explicit grant without driving a full echo loop; the receipt side
    /// applies it to the DATA send window regardless of arrival link. No-op (still byte-safe) when
    /// flow control is OFF, but only called by flow-on tests.
    func grantWindowForTest(channelID: UInt32, bytesToAdd: UInt32) {
        let frame = MuxEnvelopeCodec.encode(.windowAdjust(channelID: channelID, bytesToAdd: bytesToAdd))
        controlLink.sendPipelined(frame)
    }

    private func finishLink(_ link: Link, error: Error?) async {
        // A non-nil error is a HARD link failure (TCP RST / NetBird flap / decode fault) — the whole
        // physical connection is dead, distinct from a clean per-channel FIN (`error == nil`). Mark it
        // so a reconnecting pane never re-acquires this corpse from the pool (`ConnectionRegistry`
        // evicts a `isDead` entry; `openChannel` rejects reuse). See `linkFailed` / `isDead`.
        if error != nil { linkFailed = true }
        let channels = (link == .control) ? controlChannels : dataChannels
        for ch in channels.values {
            // Await inline so the link's FIN/error finishes each sub-channel AFTER its last
            // delivered frame, never racing ahead of in-flight data (which would drop the tail).
            if let error { await ch.finish(throwing: error) } else { await ch.finish() }
        }
        // DATA-link end: choose the kill path or the detach path based on `detachShellsOnLinkDrop`.
        //
        // Detach path (detachShellsOnLinkDrop == true):
        //   Skip the per-channel hostCloseHandler kill loop below. Fire linkDownHandler ONCE for the
        //   DATA-link end, whether error is nil (clean ⌘Q FIN) or non-nil (hard TCP RST).
        //   HostServer.handleLinkDown then detaches every session into DetachedSessionStore, keeping
        //   shells alive.
        //
        // Kill path (detachShellsOnLinkDrop == false, the default):
        //   When the shared DATA link drops WITHOUT a per-channel `channelClose` (peer crash / TCP
        //   reset), every channel riding it is dead and — with no per-channel reconnect/resume on this
        //   path — its shell must be reaped. Drive the host close hook per channel here, keyed off the
        //   DATA link (mirrors the open + per-channel close above) so it fires once per channel;
        //   `removeMuxSession` is idempotent so any overlap with an `onExit` is harmless. If the
        //   handler is not installed yet, buffer (symmetric to the per-channel close path).
        if role == .host, link == .data {
            if detachShellsOnLinkDrop {
                // Delegate to linkDownHandler (fires for BOTH clean FIN and hard error).
                // `linkDownFired` guards the one-shot: both links may drop together but we want a
                // single detach call. If the handler isn't installed yet, `linkFailed` (set above when
                // error != nil) lets setLinkDownHandler fire immediately on install (died-during-accept
                // race). For a clean FIN (error == nil) linkFailed is NOT set, so we must fire here if
                // the handler is already installed.
                if !linkDownFired, let handler = linkDownHandler {
                    linkDownFired = true
                    linkDownHandler = nil
                    handler()
                } else if !linkDownFired, error == nil {
                    // Clean FIN, no handler yet: make the next setLinkDownHandler fire immediately. We
                    // reuse `linkFailed` = "link is dead / connection no longer usable" (true for a clean
                    // FIN too), and `setLinkDownHandler` already fires immediately when `linkFailed` is set.
                    linkFailed = true
                }
                // Do NOT run the per-channel hostCloseHandler kill loop on this path.
            } else {
                // Per-channel kill loop.
                if let hostCloseHandler {
                    for id in channels.keys { hostCloseHandler(id) }
                } else {
                    pendingHostCloses.append(contentsOf: channels.keys)
                }
            }
        }
        // The whole DATA link is gone — drop every channel's receive-window accounting. (The send
        // windows are torn down via each sub-channel's `finish()` above, which also wakes any parked
        // sender so the link drop never leaks a suspended task.)
        if link == .data { dataReceiveWindows.removeAll() }
        // A HARD link failure means the whole physical connection is dead. Fire the host's
        // connection-death hook ONCE (first failing link wins) so the host reaps the connection from
        // its retention map + closes it. On the detach path the DATA-link-end handler already fired
        // (above); the CONTROL-link end falls through here, guarded by `linkDownFired` so it doesn't
        // double-fire. `linkDownFired` is consumed ONLY when a handler actually fires — if none is
        // installed yet, the already-set `linkFailed` lets a LATER `setLinkDownHandler` fire
        // immediately (died-during-accept race), so don't pre-burn the one-shot.
        if role == .host, error != nil, !linkDownFired, let handler = linkDownHandler {
            linkDownFired = true
            linkDownHandler = nil
            handler()
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
    public let initialCwd: String?
    public let data: MuxSubChannel
    public let control: MuxSubChannel
}
