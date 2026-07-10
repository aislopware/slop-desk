import Foundation

/// Pure flow + reply-stamp bookkeeping for ``NWVideoMuxDatagramTransport`` — generic over the flow
/// handle (`NWConnection` live; a bare class in tests) so every DECISION about which flow to keep,
/// which reply stamp is live, and what the reaper tick must tear down is unit-testable without a
/// socket ("decider beside the actor", like ``IdleReapDecider`` / ``VideoMuxRouter``). The
/// transport owns the mux lock; every call here happens under it, so the struct needs no locking.
///
/// ## What it tracks
/// - **Accepted flows** (`mediaFlows`/`cursorFlows`): every UDP "connection" the listener pins per
///   source endpoint, keyed by object identity so a failed flow removes only itself.
/// - **Reply stamps** (`mediaReply`/`cursorReply`): channelID → the flow that last carried (media)
///   or primed (cursor) the lane, so host→client datagrams reply on the flow the client opened.
/// - **Per-flow last-inbound time**: refreshed on every decoded inbound datagram; monotonic host
///   seconds stamped by the caller (never wall-clock — see the transport's `nowSeconds()`).
/// - **Never-admitted stamp times**: reply stamps made while the lane was NOT admitted (the cursor
///   prime racing ahead of the media hello, or a hello/list bootstrap whose mint never completed).
///
/// ## Why a reap exists (UDP has no FIN)
/// A peer that silently vanishes (wifi switch, client rebuild) never drives the host-side flow to
/// `.failed` — without a reap, one media + one cursor flow (fd + armed receive callback) leaks per
/// client flow rebuild, forever (fd exhaustion on the long-lived daemon). ``reap(now:isAdmitted:)``
/// closes both holes; see its doc for the exact rules.
public struct MuxFlowTable<Flow: AnyObject> {
    private var mediaFlows: [ObjectIdentifier: Flow] = [:]
    private var cursorFlows: [ObjectIdentifier: Flow] = [:]
    private var mediaReply: [UInt32: Flow] = [:]
    private var cursorReply: [UInt32: Flow] = [:]
    private var flowLastInbound: [ObjectIdentifier: TimeInterval] = [:]
    private var unadmittedStampAt: [UInt32: TimeInterval] = [:]

    /// Idle threshold in seconds before an unreferenced silent flow (or a never-admitted reply
    /// stamp) is reaped — ``KeepaliveTiming/idleTimeout``, the SAME contract the per-lane
    /// ``IdleReapDecider`` uses, so flow and lane lifetimes cannot silently drift apart.
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval) { self.idleTimeout = idleTimeout }

    /// Track a listener-accepted flow. `now` doubles as its first inbound stamp (the listener pins
    /// a flow only because a datagram arrived on it).
    public mutating func accept(_ flow: Flow, isMedia: Bool, now: TimeInterval) {
        let id = ObjectIdentifier(flow)
        if isMedia { mediaFlows[id] = flow } else { cursorFlows[id] = flow }
        flowLastInbound[id] = now
    }

    /// Refresh a tracked flow's last-inbound time (any decoded datagram proves the 5-tuple is
    /// alive). A no-op for an untracked flow so a datagram racing a reset/reap cannot resurrect a
    /// dropped record.
    public mutating func noteInbound(_ flow: Flow, now: TimeInterval) {
        let id = ObjectIdentifier(flow)
        guard flowLastInbound[id] != nil else { return }
        flowLastInbound[id] = now
    }

    /// Stamp the media reply flow for an ADMITTED (routed) lane. Re-stamped on every routed
    /// datagram so a client whose source port changes mid-session (NAT rebind) re-points the lane
    /// to its new flow — the displaced flow then ages out via ``reap(now:isAdmitted:)``.
    public mutating func stampMediaReply(channelID: UInt32, flow: Flow) {
        mediaReply[channelID] = flow
    }

    /// Stamp the media reply flow for a NOT-yet-admitted bootstrap (hello / window-list request —
    /// see `VideoMuxRouter.bootstrapAction`). Tracked with a stamp time so a bootstrap whose mint
    /// or list-answer never completes (lost on a lossy link) cannot leak the entry forever.
    public mutating func stampMediaBootstrap(channelID: UInt32, flow: Flow, now: TimeInterval) {
        mediaReply[channelID] = flow
        // Only the FIRST unadmitted stamp starts the TTL clock — a hello retransmit burst must not
        // keep pushing a never-minting lane's expiry forward.
        if unadmittedStampAt[channelID] == nil { unadmittedStampAt[channelID] = now }
    }

    /// Stamp the cursor reply flow for a lane (the inbound cursor prime). The prime legitimately
    /// races AHEAD of the media hello, so an unadmitted stamp is accepted — but tracked with a
    /// stamp time (`isAdmitted == false`) so a never-admitted id (a discovery poll whose media
    /// request was lost) is swept by ``reap(now:isAdmitted:)`` instead of leaking forever.
    public mutating func stampCursorReply(channelID: UInt32, flow: Flow, now: TimeInterval, isAdmitted: Bool) {
        cursorReply[channelID] = flow
        if isAdmitted {
            unadmittedStampAt.removeValue(forKey: channelID)
        } else if unadmittedStampAt[channelID] == nil {
            unadmittedStampAt[channelID] = now // first unadmitted stamp starts the TTL clock
        }
    }

    /// Drop a lane's reply stamps (clean `bye`, reaper-driven retire, or the transport's
    /// `retire(_:)`). The flows themselves stay tracked — they may carry sibling lanes.
    public mutating func retireLane(_ channelID: UInt32) {
        mediaReply.removeValue(forKey: channelID)
        cursorReply.removeValue(forKey: channelID)
        unadmittedStampAt.removeValue(forKey: channelID)
    }

    /// Forget a flow whose `NWConnection` reached `.failed`/`.cancelled` — drop it from the flow
    /// table, drop every reply stamp pointing at it, and drop its last-inbound record so a later
    /// reap never reports it again. Idempotent (a reaper-cancelled flow re-enters here harmlessly).
    public mutating func flowDidReset(_ flow: Flow, isMedia: Bool) {
        let id = ObjectIdentifier(flow)
        if isMedia {
            mediaFlows.removeValue(forKey: id)
            mediaReply = mediaReply.filter { $0.value !== flow }
        } else {
            cursorFlows.removeValue(forKey: id)
            cursorReply = cursorReply.filter { $0.value !== flow }
        }
        flowLastInbound.removeValue(forKey: id)
    }

    /// One reaper-tick decision (call under the mux lock; `cancel()` the returned flows OUTSIDE
    /// it). Two rules, in order:
    ///
    /// 1. **Never-admitted stamp sweep.** A reply stamp made while its lane was unadmitted, whose
    ///    lane is STILL not admitted `idleTimeout` later, is dropped (both maps) — the discovery /
    ///    lost-mint leak. A lane that got admitted in the window keeps its stamps (the prime-races-
    ///    ahead-of-hello case); only its TTL record is discarded.
    /// 2. **Idle unreferenced flow reap.** A flow silent ≥ `idleTimeout` that is NOT the current
    ///    value of ANY reply stamp is removed and returned for `cancel()`. A referenced flow is
    ///    NEVER reaped — a live lane's cursor flow receives nothing after its one prime, so
    ///    inbound-idleness alone must not kill it; it becomes reapable only once its lane's stamps
    ///    are gone (lane retire/reap, or a rebuild re-pointing the stamps at a new flow).
    ///
    /// Rule 1 runs first so a stale stamp cannot keep protecting its orphaned flow.
    public mutating func reap(now: TimeInterval, isAdmitted: (UInt32) -> Bool) -> [Flow] {
        // Rule 1: never-admitted stamp sweep (must precede the reference snapshot below).
        for (channelID, stampedAt) in unadmittedStampAt where now - stampedAt >= idleTimeout {
            unadmittedStampAt.removeValue(forKey: channelID)
            // Graduated to admitted inside the window (the prime-races-ahead case): the stamps are
            // live — drop only the TTL record. `retireLane` owns their eventual removal.
            guard !isAdmitted(channelID) else { continue }
            mediaReply.removeValue(forKey: channelID)
            cursorReply.removeValue(forKey: channelID)
        }
        // Rule 2: reap idle flows no reply stamp references.
        var referenced = Set<ObjectIdentifier>(minimumCapacity: mediaReply.count + cursorReply.count)
        for flow in mediaReply.values { referenced.insert(ObjectIdentifier(flow)) }
        for flow in cursorReply.values { referenced.insert(ObjectIdentifier(flow)) }
        var reaped: [Flow] = []
        for (id, lastInbound) in flowLastInbound
            where now - lastInbound >= idleTimeout && !referenced.contains(id)
        {
            flowLastInbound.removeValue(forKey: id)
            if let flow = mediaFlows.removeValue(forKey: id) { reaped.append(flow) }
            if let flow = cursorFlows.removeValue(forKey: id) { reaped.append(flow) }
        }
        return reaped
    }

    /// The flow host→client media datagrams for `channelID` must ride, if known.
    public func mediaReplyFlow(for channelID: UInt32) -> Flow? { mediaReply[channelID] }

    /// The flow host→client cursor datagrams for `channelID` must ride, if known.
    public func cursorReplyFlow(for channelID: UInt32) -> Flow? { cursorReply[channelID] }

    /// Daemon shutdown: drop everything and return every tracked flow exactly once for `cancel()`.
    public mutating func removeAll() -> [Flow] {
        let flows = Array(mediaFlows.values) + Array(cursorFlows.values)
        mediaFlows.removeAll()
        cursorFlows.removeAll()
        mediaReply.removeAll()
        cursorReply.removeAll()
        flowLastInbound.removeAll()
        unadmittedStampAt.removeAll()
        return flows
    }

    /// Test / introspection: how many accepted flows are tracked (media + cursor).
    public var flowCount: Int { mediaFlows.count + cursorFlows.count }
}
