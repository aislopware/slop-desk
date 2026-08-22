import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// The Swift face of `rust/slopdesk-video`'s `window_feed_host` Phase-2 push state (docs/45 §6): the
// subscriber table (TTL-reaped, renewal-refreshed) and the tick/coalesce/burst policy. No clock
// (callers pass `now`), no sockets — the "decider beside the actor" discipline.

/// Who is subscribed to the window feed: channelID → last renewal stamp. A subscriber lives
/// ``ttl`` past its last `windowFeedSubscribe` (3 missed 2 s renewals); expiry hands the caller the
/// ids to `retire` at the mux. Bounded — a hostile spray of distinct channelIDs is capped, newest
/// refused (fail-quiet, the `UnboundByeRateLimiter` shape).
///
/// A handle for the map it holds; the feed glue drives it from one queue, which is what makes
/// `@unchecked Sendable` sound.
public final class WindowFeedSubscriberTable: @unchecked Sendable {
    /// The far-side table, which owns the renewal stamps.
    private let handle: OpaquePointer?
    public let ttl: TimeInterval
    public let capacity: Int

    public init(ttl: TimeInterval = 6.0, capacity: Int = 32) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
        handle = slopdesk_feed_subscribers_new(ttl, self.capacity)
    }

    deinit { slopdesk_feed_subscribers_free(handle) }

    public var isEmpty: Bool { count == 0 }
    public var count: Int { slopdesk_feed_subscribers_count(handle) }

    /// Records a renewal. Returns `false` when the table is full of FRESH subscribers and this id is
    /// new (refused — bounded map); an existing id always refreshes.
    @discardableResult
    public func renew(_ channelID: UInt32, now: TimeInterval) -> Bool {
        slopdesk_feed_subscribers_renew(handle, channelID, now)
    }

    /// Drops every subscriber whose renewal is ≥ ttl old and returns their ids (the caller retires
    /// those lanes at the mux). Lent at the table's own size in one call: a reap CONSUMES what it
    /// reports, so a first sizing call would empty it before the second could read it.
    public func reapExpired(now: TimeInterval) -> [UInt32] {
        ids(room: count) { out, room in slopdesk_feed_subscribers_reap(handle, now, out, room) }
    }

    /// The live subscriber ids (push targets).
    public func subscribers(now: TimeInterval) -> [UInt32] {
        ids(room: count) { out, room in slopdesk_feed_subscribers_live(handle, now, out, room) }
    }

    /// One lend of `room` ids, as many as the door wrote.
    private func ids(room: Int, _ fill: (UnsafeMutablePointer<UInt32>?, Int) -> Int) -> [UInt32] {
        guard room > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: room) { buffer, written in
            written = fill(buffer.baseAddress, room)
        }
    }
}

/// The differ's tick + fold policy (docs/45 §6): 1 Hz idle, 4 Hz for 3 s after a STRUCTURAL change
/// (window add/remove/visibility/size); title-only folds coalesce at ≥ 2 s, focus/order-only at
/// ≥ 1 s — churn never enters burst mode and never floods generations. All of it the crate's.
///
/// A FOLD, and therefore still a value type: two optional timestamps, read whole every tick.
public struct WindowFeedPushPolicy: Sendable {
    /// What changed between the cached records and a freshly built set.
    public enum Change: Equatable, Sendable {
        case none
        /// Window set / visibility / size changed — fold NOW + burst.
        case structural
        /// Only titles / focus bits / z-order / display ordinals moved — fold on the coalesce gate.
        case volatileOnly(titleChanged: Bool)

        /// The code this change crosses as.
        var code: UInt32 {
            switch self {
            case .none: SLOPDESK_FEED_CHANGE_NONE
            case .structural: SLOPDESK_FEED_CHANGE_STRUCTURAL
            case let .volatileOnly(titleChanged):
                titleChanged ? SLOPDESK_FEED_CHANGE_VOLATILE_TITLE : SLOPDESK_FEED_CHANGE_VOLATILE
            }
        }

        /// The change a code names.
        static func of(_ code: UInt32) -> Self {
            switch code {
            case SLOPDESK_FEED_CHANGE_STRUCTURAL: .structural
            case SLOPDESK_FEED_CHANGE_VOLATILE: .volatileOnly(titleChanged: false)
            case SLOPDESK_FEED_CHANGE_VOLATILE_TITLE: .volatileOnly(titleChanged: true)
            default: .none
            }
        }
    }

    /// The policy's fixed cadences, from the door, so neither language writes them down twice.
    private static let law = slopdesk_feed_constants()
    public static var idleTick: TimeInterval { law.idle_tick }
    public static var burstTick: TimeInterval { law.burst_tick }

    /// The two stamps the policy carries.
    private var record = slopdesk_feed_policy_new()

    public init() {}

    /// Classifies the diff. Structural = the id SET, any window's visibility bits
    /// (onScreen/minimized/appHidden), or any window's size changed. Everything else the client
    /// renders volatile (title, focus bits, order, display) is `volatileOnly`.
    public static func classify(old: [HostWindowRecord], new: [HostWindowRecord]) -> Change {
        let (oldRows, oldArena) = HostWindowRecord.rows(old)
        let (newRows, newArena) = HostWindowRecord.rows(new)
        let code = oldRows.withUnsafeBufferPointer { before in
            oldArena.withUnsafeBytes { beforePool in
                newRows.withUnsafeBufferPointer { after in
                    newArena.withUnsafeBytes { afterPool in
                        slopdesk_feed_classify(
                            before.baseAddress, before.count, beforePool.baseAddress, beforePool.count,
                            after.baseAddress, after.count, afterPool.baseAddress, afterPool.count,
                        )
                    }
                }
            }
        }
        return Change.of(code)
    }

    /// Whether this change may fold into the cache NOW (bumping the generation → a push). A
    /// structural change always folds and opens the burst window; a volatile-only change folds only
    /// once its coalesce gate (2 s titles / 1 s focus-order) has elapsed since the last volatile fold.
    public mutating func shouldFold(_ change: Change, now: TimeInterval) -> Bool {
        slopdesk_feed_should_fold(&record, change.code, now)
    }

    /// The differ's next tick interval — 4 Hz inside the structural burst window, 1 Hz otherwise.
    /// (Push pacing ≥ 250 ms is implied: at most one fold per tick.)
    public func tickInterval(now: TimeInterval) -> TimeInterval {
        slopdesk_feed_tick_interval(record, now)
    }
}
