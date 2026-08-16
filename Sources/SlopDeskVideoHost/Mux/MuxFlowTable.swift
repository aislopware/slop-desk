import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-video`'s `mux_flow` table, reached through the `mux_host` door.
///
/// Flow + reply-stamp bookkeeping for ``NWVideoMuxDatagramTransport`` — generic over the flow
/// handle (`NWConnection` live; a bare class in tests) so every DECISION about which flow to keep,
/// which reply stamp is live, and what the reaper tick must tear down is unit-testable without a
/// socket ("decider beside the actor", like ``IdleReapDecider`` / ``VideoMuxRouter``). The
/// transport owns the mux lock; every call here happens under it, so the class needs no locking.
///
/// ## What the far side tracks
/// - **Accepted flows**: every UDP "connection" the listener pins per source endpoint, so a failed
///   flow removes only itself.
/// - **Reply stamps**: channelID → the flow that last carried (media) or primed (cursor) the lane,
///   so host→client datagrams reply on the flow the client opened.
/// - **Per-flow last-inbound time**: refreshed on every decoded inbound datagram; monotonic host
///   seconds stamped by the caller (never wall-clock — see the transport's `nowSeconds()`).
/// - **Never-admitted stamp times**: reply stamps made while the lane was NOT admitted (the cursor
///   prime racing ahead of the media hello, or a hello/list bootstrap whose mint never completed).
///
/// ## What stays on THIS side: the objects
/// The crate holds flow IDENTITIES, not flows — a `UInt64` per pinned connection. That is the only
/// shape a Rust table can hold an `NWConnection` in, and it is the right one: every rule here is
/// stated in terms of ids already. So this face keeps the id → object registry, hands the door ids,
/// and turns the ids it gets back into the connections the caller must `cancel()`. The registry is
/// pruned by asking the door whether an id is still tracked — never by a second copy of the
/// membership rule.
///
/// ## Why a reap exists (UDP has no FIN)
/// A peer that silently vanishes (wifi switch, client rebuild) never drives the host-side flow to
/// `.failed` — without a reap, one media + one cursor flow (fd + armed receive callback) leaks per
/// client flow rebuild, forever (fd exhaustion on the long-lived daemon). ``reap(now:isAdmitted:)``
/// closes both holes; see `mux_flow.rs` for the exact rules.
public final class MuxFlowTable<Flow: AnyObject> {
    /// The far-side table, which holds ids and no objects.
    private let handle: OpaquePointer?
    /// Which object each id names. The far side cannot hold this and does not try to.
    private var objects: [UInt64: Flow] = [:]

    /// Idle threshold in seconds before an unreferenced silent flow (or a never-admitted reply
    /// stamp) is reaped — ``KeepaliveTiming/idleTimeout``, the SAME contract the per-lane
    /// ``IdleReapDecider`` uses, so flow and lane lifetimes cannot silently drift apart.
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval) {
        self.idleTimeout = idleTimeout
        handle = slopdesk_mux_flows_new(idleTimeout)
    }

    deinit { slopdesk_mux_flows_free(handle) }

    /// A live object's identity, which is what the far side works in.
    private static func identity(_ flow: Flow) -> UInt64 {
        UInt64(UInt(bitPattern: ObjectIdentifier(flow)))
    }

    /// Track a listener-accepted flow. `now` doubles as its first inbound stamp (the listener pins
    /// a flow only because a datagram arrived on it).
    public func accept(_ flow: Flow, isMedia: Bool, now: TimeInterval) {
        let id = Self.identity(flow)
        objects[id] = flow
        slopdesk_mux_flows_accept(handle, id, isMedia, now)
    }

    /// Refresh a tracked flow's last-inbound time (any decoded datagram proves the 5-tuple is
    /// alive). A no-op for an untracked flow so a datagram racing a reset/reap cannot resurrect a
    /// dropped record.
    public func noteInbound(_ flow: Flow, now: TimeInterval) {
        slopdesk_mux_flows_note_inbound(handle, Self.identity(flow), now)
    }

    /// Stamp the media reply flow for an ADMITTED (routed) lane. Re-stamped on every routed
    /// datagram so a client whose source port changes mid-session (NAT rebind) re-points the lane
    /// to its new flow — the displaced flow then ages out via ``reap(now:isAdmitted:)``.
    public func stampMediaReply(channelID: UInt32, flow: Flow) {
        slopdesk_mux_flows_stamp_media_reply(handle, channelID, Self.identity(flow))
    }

    /// Stamp the media reply flow for a NOT-yet-admitted bootstrap (hello / window-list request —
    /// see `VideoMuxRouter.bootstrapAction`). Tracked with a stamp time so a bootstrap whose mint
    /// or list-answer never completes (lost on a lossy link) cannot leak the entry forever.
    public func stampMediaBootstrap(channelID: UInt32, flow: Flow, now: TimeInterval) {
        slopdesk_mux_flows_stamp_media_bootstrap(handle, channelID, Self.identity(flow), now)
    }

    /// Stamp the cursor reply flow for a lane (the inbound cursor prime). The prime legitimately
    /// races AHEAD of the media hello, so an unadmitted stamp is accepted — but tracked with a
    /// stamp time (`isAdmitted == false`) so a never-admitted id (a discovery poll whose media
    /// request was lost) is swept by ``reap(now:isAdmitted:)`` instead of leaking forever.
    public func stampCursorReply(channelID: UInt32, flow: Flow, now: TimeInterval, isAdmitted: Bool) {
        slopdesk_mux_flows_stamp_cursor_reply(handle, channelID, Self.identity(flow), now, isAdmitted)
    }

    /// Drop a lane's reply stamps (clean `bye`, reaper-driven retire, or the transport's
    /// `retire(_:)`). The flows themselves stay tracked — they may carry sibling lanes.
    public func retireLane(_ channelID: UInt32) {
        slopdesk_mux_flows_retire_lane(handle, channelID)
    }

    /// Forget a flow whose `NWConnection` reached `.failed`/`.cancelled` — drop it from the flow
    /// table, drop every reply stamp pointing at it, and drop its last-inbound record so a later
    /// reap never reports it again. Idempotent (a reaper-cancelled flow re-enters here harmlessly).
    public func flowDidReset(_ flow: Flow, isMedia: Bool) {
        let id = Self.identity(flow)
        slopdesk_mux_flows_did_reset(handle, id, isMedia)
        // The door owns which side still holds the id; this side only releases what it says is gone.
        if !slopdesk_mux_flows_tracks(handle, id) { objects.removeValue(forKey: id) }
    }

    /// One reaper-tick decision (call under the mux lock; `cancel()` the returned flows OUTSIDE
    /// it). The rules — sweep the never-admitted stamps first, then reap the idle flows no stamp
    /// references — are `mux_flow.rs`'s; `isAdmitted` is the question it asks back, because the
    /// answer lives in the router the transport holds separately.
    ///
    /// A reap CONSUMES what it reports, so the buffer is lent at full size in one call rather than
    /// sized by a first one: the tracked-flow count is an exact upper bound on what a tick can
    /// close, and a second call would find the ids already gone.
    public func reap(now: TimeInterval, isAdmitted: (UInt32) -> Bool) -> [Flow] {
        let room = flowCount
        guard room > 0 else { return [] }
        var reaped: [UInt64] = []
        withoutActuallyEscaping(isAdmitted) { asking in
            var probe = asking
            withUnsafeMutablePointer(to: &probe) { context in
                let ask: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool = { channelID, context in
                    guard let context else { return false }
                    return context.assumingMemoryBound(to: ((UInt32) -> Bool).self).pointee(channelID)
                }
                reaped = [UInt64](unsafeUninitializedCapacity: room) { buffer, count in
                    count = slopdesk_mux_flows_reap(
                        handle, now, ask, UnsafeMutableRawPointer(context), buffer.baseAddress, room,
                    )
                }
            }
        }
        return released(reaped)
    }

    /// The flow host→client media datagrams for `channelID` must ride, if known.
    public func mediaReplyFlow(for channelID: UInt32) -> Flow? {
        var id = UInt64(0)
        guard slopdesk_mux_flows_media_reply(handle, channelID, &id) else { return nil }
        return objects[id]
    }

    /// The flow host→client cursor datagrams for `channelID` must ride, if known.
    public func cursorReplyFlow(for channelID: UInt32) -> Flow? {
        var id = UInt64(0)
        guard slopdesk_mux_flows_cursor_reply(handle, channelID, &id) else { return nil }
        return objects[id]
    }

    /// Daemon shutdown: drop everything and return every tracked flow exactly once for `cancel()`.
    /// Lent at full size in one call for the same reason the reap is: it consumes what it reports.
    public func removeAll() -> [Flow] {
        let room = flowCount
        guard room > 0 else { return [] }
        let ids = [UInt64](unsafeUninitializedCapacity: room) { buffer, count in
            count = slopdesk_mux_flows_remove_all(handle, buffer.baseAddress, room)
        }
        return released(ids)
    }

    /// Test / introspection: how many accepted flows are tracked (media + cursor).
    public var flowCount: Int { slopdesk_mux_flows_count(handle) }

    /// The objects the door just let go of, released from the registry as they are handed over.
    private func released(_ ids: [UInt64]) -> [Flow] {
        ids.compactMap { id in
            let flow = objects[id]
            if !slopdesk_mux_flows_tracks(handle, id) { objects.removeValue(forKey: id) }
            return flow
        }
    }
}
