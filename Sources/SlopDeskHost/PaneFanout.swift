import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-muxsession`'s `fanout`, reached through the `pane_fanout` door.
///
/// One pane's subscriber set, as NUMBERS: who is in it and in what order, how far each member has
/// acked and how far its sender has shipped, how far retention may be released, which member has
/// fallen too far behind to keep. The members themselves — a sub-channel pair, four relay tasks, two
/// outbound queues and their wakes — stay on this side, keyed by the same `MuxSubscriberID`.
///
/// **The set is not a mirror.** ``MuxChannelSession`` keeps a dictionary of `Subscriber` OBJECTS
/// under the same ids, and every scalar about a member lives here and only here. The one flag that
/// stays over there is `retired`, because it is about that object's tasks being cancelled and it
/// deliberately outlives membership: `shutdown()` cancels a member's relays without retiring the
/// set, and a task builder that lost a race must find the flag on the object it was building for.
///
/// Not `Sendable` and deliberately unlocked: ``MuxChannelSession`` holds every call under its
/// `subscribersLock`, exactly as it did when this state was stored properties on `Subscriber`.
final class PaneFanout {
    /// One member's ack cursor, for the eviction ladder's replay query.
    struct Cursor {
        var id: MuxSubscriberID
        var acked: Int64
    }

    /// The far side, which owns the roster, the cursors and both folds.
    private let handle: OpaquePointer?

    /// An empty set for a fresh pane session.
    init() { handle = slopdesk_pane_fanout_new() }

    deinit { slopdesk_pane_fanout_free(handle) }

    /// How far behind one member may fall before it is evicted rather than buffered for, for the
    /// one caller that has to NAME the number: the eviction log line. The rule itself never crosses.
    static var lagBytes: UInt64 { slopdesk_pane_fanout_lag_bytes() }

    /// RESERVES the id a pending JOIN will enter under, before the member exists.
    func reserveID() -> MuxSubscriberID { slopdesk_pane_fanout_reserve_id(handle) }

    /// Enters a member under `id`, seeding its ack cursor. REPLACES any member already there, which
    /// is what a returning client is: a subscriber IS its channel pair.
    func join(_ id: MuxSubscriberID, acked: Int64) {
        slopdesk_pane_fanout_join(handle, id, acked)
    }

    /// Drops a member and answers whether the set is now EMPTY.
    @discardableResult
    func leave(_ id: MuxSubscriberID) -> Bool { slopdesk_pane_fanout_leave(handle, id) }

    /// How many members hold this pane right now.
    var count: Int { slopdesk_pane_fanout_count(handle) }

    /// Whether nobody holds this pane — the same question ``leave(_:)`` answers, for the one caller
    /// that has to ask it without a departure to hang it on.
    var isEmpty: Bool { slopdesk_pane_fanout_count(handle) == 0 }

    /// Every member in ascending id order — the deterministic broadcast order.
    ///
    /// Asked for its length first, then read whole: the door writes nothing into a buffer the list
    /// does not fit, which is the same retry convention every table door here uses.
    var ids: [MuxSubscriberID] {
        let count = slopdesk_pane_fanout_ids(handle, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [MuxSubscriberID](repeating: 0, count: count)
        let written = buffer.withUnsafeMutableBufferPointer { raw in
            slopdesk_pane_fanout_ids(handle, raw.baseAddress, raw.count)
        }
        guard written == count else { return [] }
        return buffer
    }

    /// Records `id`'s confirmation of `seq` and answers the retention floor over the members that
    /// REMAIN. `nil` for an empty set — the ack test seam on a session with no members.
    func acknowledge(_ id: MuxSubscriberID, upTo seq: Int64) -> Int64? {
        var floor: Int64 = 0
        guard slopdesk_pane_fanout_acknowledge(handle, id, seq, &floor) else { return nil }
        return floor
    }

    /// The lowest ack cursor in the set — how far retention may be released. `nil` when empty.
    var retentionFloor: Int64? {
        var floor: Int64 = 0
        guard slopdesk_pane_fanout_retention_floor(handle, &floor) else { return nil }
        return floor
    }

    /// Marks `id` delivered from an OUTBOX, seeding its frontier at `head`, and answers whether THIS
    /// call started it — so the caller builds the sender task exactly once.
    func startSender(_ id: MuxSubscriberID, seedingFrontierAt head: Int64) -> Bool {
        slopdesk_pane_fanout_start_sender(handle, id, head)
    }

    /// Drops `id` back off the producer bound, for a member whose sender has been cancelled.
    func clearSender(_ id: MuxSubscriberID) { slopdesk_pane_fanout_clear_sender(handle, id) }

    /// Records that `id`'s sender put `seq` on the wire (or died trying).
    func noteSent(_ id: MuxSubscriberID, seq: Int64) {
        slopdesk_pane_fanout_note_sent(handle, id, seq)
    }

    /// The delivery frontier: the highest seq the FASTEST outbox-delivered member has shipped.
    /// `nil` on the inline path, where nobody is delivered from an outbox.
    var frontier: Int64? {
        var frontier: Int64 = 0
        guard slopdesk_pane_fanout_frontier(handle, &frontier) else { return nil }
        return frontier
    }

    /// Marks `id`'s `.exit` frame delivered.
    func markExitDelivered(_ id: MuxSubscriberID) {
        slopdesk_pane_fanout_mark_exit_delivered(handle, id)
    }

    /// Whether `id` is still owed its `.exit`. A member that has LEFT is owed nothing.
    func isExitPending(_ id: MuxSubscriberID) -> Bool {
        slopdesk_pane_fanout_exit_pending(handle, id)
    }

    /// Every member BEHIND the healthiest ack cursor — the eviction ladder's first half.
    ///
    /// Empty for a set of one and for a disabled threshold, so an empty answer means the caller
    /// pays no replay query at all.
    var laggingCursors: [Cursor] {
        let count = slopdesk_pane_fanout_lagging(handle, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [SlopDeskFanoutCursor](repeating: SlopDeskFanoutCursor(), count: count)
        let written = buffer.withUnsafeMutableBufferPointer { raw in
            slopdesk_pane_fanout_lagging(handle, raw.baseAddress, raw.count)
        }
        guard written == count else { return [] }
        return buffer.map { Cursor(id: $0.id, acked: $0.acked) }
    }

    /// Applies the threshold to what the caller PRICED and claims the eviction latch, answering the
    /// ids whose close this call must fire.
    ///
    /// One-shot per member: a concurrent producer and ack path cannot both claim the same one, and
    /// every subsequent frame finds it already latched.
    func evict(priced: [(id: MuxSubscriberID, retainedBytes: Int)]) -> [MuxSubscriberID] {
        guard !priced.isEmpty else { return [] }
        let entries = priced.map {
            SlopDeskFanoutPriced(id: $0.id, retained_bytes: UInt64(Swift.max(0, $0.retainedBytes)))
        }
        var doomed = [MuxSubscriberID](repeating: 0, count: entries.count)
        let claimed = entries.withUnsafeBufferPointer { asked in
            doomed.withUnsafeMutableBufferPointer { out in
                slopdesk_pane_fanout_evict(
                    handle, asked.baseAddress, asked.count, out.baseAddress, out.count,
                )
            }
        }
        return Array(doomed.prefix(claimed))
    }
}
