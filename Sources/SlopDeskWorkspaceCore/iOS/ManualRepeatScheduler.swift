import Foundation
import Synchronization

/// A deterministic, virtual-time ``RepeatScheduler`` for tests (and previews).
///
/// It never touches the wall clock. Scheduled work is queued against a synthetic clock
/// (``now``, in attoseconds-precision `Duration`) that only advances when the test calls
/// ``advance(by:)``. This is what makes the ``KeyRepeater`` cadence assertable to the exact
/// millisecond — fire-immediately, then +350ms, then +50ms, +50ms … — with zero flakiness
/// and zero real sleeping.
///
/// Repeating timers are modelled as "re-arm after each fire": ``advance(by:)`` fires every
/// elapsed deadline in order, re-scheduling a repeating item one interval past the deadline
/// it just fired, so a single large advance fans out the right number of repeats.
///
/// Single-threaded by contract (drive it from one test thread); the `Mutex` is what satisfies
/// the `Sendable` checker when a `KeyRepeater` closure calls back in.
public final class ManualRepeatScheduler: RepeatScheduler, Sendable {
    /// A scheduled item, addressed by `id` rather than by reference.
    ///
    /// The identity is the whole reason this is a struct: a handle must be able to cancel an item
    /// without holding it, because holding it would mean sharing the lock that guards it — and a
    /// `Mutex` cannot be shared, only the state inside it can. An id crosses; a reference cannot.
    private struct Item {
        let id: Int
        var deadline: Duration
        let interval: Duration? // nil = one-shot
        let work: @Sendable () -> Void
    }

    private struct Queue {
        var items: [Item] = []
        var clock: Duration = .zero
        var nextID = 0

        mutating func insert(deadline: Duration, interval: Duration?, work: @escaping @Sendable () -> Void) -> Int {
            defer { nextID += 1 }
            items.append(Item(id: nextID, deadline: deadline, interval: interval, work: work))
            return nextID
        }
    }

    private let queue = Mutex(Queue())

    public init() {}

    /// The current synthetic time (sum of all ``advance(by:)`` calls).
    public var now: Duration { queue.withLock { $0.clock } }

    @preconcurrency
    public func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        let id = queue.withLock { q in
            q.insert(deadline: q.clock + delay, interval: nil, work: work)
        }
        return Handle(id: id, scheduler: self)
    }

    @preconcurrency
    public func scheduleRepeating(
        every interval: Duration,
        _ work: @escaping @Sendable () -> Void,
    ) -> RepeatSchedulerHandle {
        let id = queue.withLock { q in
            q.insert(deadline: q.clock + interval, interval: interval, work: work)
        }
        return Handle(id: id, scheduler: self)
    }

    /// Advances the synthetic clock by `delta`, firing every item whose deadline falls in
    /// the elapsed window, **in deadline order**. A repeating item that fires re-arms one
    /// interval later (so it can fire multiple times in a single large advance). Work runs
    /// with the lock released so a `KeyRepeater` callback can re-enter (`stop`, re-`keyDown`).
    public func advance(by delta: Duration) {
        let target = queue.withLock { q -> Duration in
            q.clock += delta
            return q.clock
        }

        // Fire in strict deadline order until no item is due at/under `target`. Re-arm or remove
        // BEFORE running the work, so a re-entrant schedule from the work itself is ordered after
        // this fire — which is why the take and the re-arm are ONE hold rather than two.
        while true {
            let due = queue.withLock { q -> (@Sendable () -> Void)? in
                var soonest: Int?
                for index in q.items.indices where q.items[index].deadline <= target {
                    if let best = soonest, q.items[best].deadline <= q.items[index].deadline { continue }
                    soonest = index
                }
                guard let index = soonest else { return nil }
                let item = q.items[index]
                if let interval = item.interval {
                    q.items[index].deadline += interval
                } else {
                    q.items.remove(at: index)
                }
                return item.work
            }
            guard let due else { break }
            due()
        }
    }

    /// Number of live scheduled items (diagnostics / tests).
    public var pendingCount: Int { queue.withLock { $0.items.count } }

    /// Cancels one item.
    ///
    /// A cancel is a REMOVAL rather than a flag the sweep filters on: with the item addressed by
    /// id there is nothing for a stale reference to point at, so "cancelled but still in the array"
    /// stopped being a state that can exist — and `pendingCount` needs no predicate.
    private func cancel(id: Int) {
        queue.withLock { $0.items.removeAll { $0.id == id } }
    }

    /// The cancellable handle a caller keeps.
    ///
    /// It reaches the queue through the SCHEDULER rather than holding the `Mutex`: a `Mutex` is
    /// `~Copyable`, so it has exactly one owner and cannot be handed to a second object — the
    /// scheduler is what both sides can name. `weak`, so a cancel after the scheduler has been
    /// dropped is a no-op rather than a resurrection.
    private final class Handle: RepeatSchedulerHandle, @unchecked Sendable {
        private let id: Int
        private weak var scheduler: ManualRepeatScheduler?

        init(id: Int, scheduler: ManualRepeatScheduler) {
            self.id = id
            self.scheduler = scheduler
        }

        func cancel() { scheduler?.cancel(id: id) }
    }
}
