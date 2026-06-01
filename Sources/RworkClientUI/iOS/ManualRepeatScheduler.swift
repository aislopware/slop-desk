import Foundation

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
/// Single-threaded by contract (drive it from one test thread); guarded by a lock so the
/// `Sendable` checker is satisfied when a `KeyRepeater` closure calls back in.
public final class ManualRepeatScheduler: RepeatScheduler, @unchecked Sendable {
    private final class Item {
        var deadline: Duration
        let interval: Duration?     // nil = one-shot
        let work: @Sendable () -> Void
        var cancelled = false
        init(deadline: Duration, interval: Duration?, work: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.interval = interval
            self.work = work
        }
    }

    private final class Handle: RepeatSchedulerHandle, @unchecked Sendable {
        weak var item: Item?
        let lock: NSLock
        init(item: Item, lock: NSLock) { self.item = item; self.lock = lock }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            item?.cancelled = true
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var clock: Duration = .zero

    public init() {}

    /// The current synthetic time (sum of all ``advance(by:)`` calls).
    public var now: Duration {
        lock.lock(); defer { lock.unlock() }
        return clock
    }

    public func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        lock.lock(); defer { lock.unlock() }
        let item = Item(deadline: clock + delay, interval: nil, work: work)
        items.append(item)
        return Handle(item: item, lock: lock)
    }

    public func scheduleRepeating(every interval: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        lock.lock(); defer { lock.unlock() }
        let item = Item(deadline: clock + interval, interval: interval, work: work)
        items.append(item)
        return Handle(item: item, lock: lock)
    }

    /// Advances the synthetic clock by `delta`, firing every item whose deadline falls in
    /// the elapsed window, **in deadline order**. A repeating item that fires re-arms one
    /// interval later (so it can fire multiple times in a single large advance). Work runs
    /// with the lock released so a `KeyRepeater` callback can re-enter (`stop`, re-`keyDown`).
    public func advance(by delta: Duration) {
        let target: Duration = {
            lock.lock(); defer { lock.unlock() }
            clock = clock + delta
            return clock
        }()

        // Fire in strict deadline order until no item is due at/under `target`.
        while true {
            let due: Item? = {
                lock.lock(); defer { lock.unlock() }
                items.removeAll { $0.cancelled }
                return items
                    .filter { !$0.cancelled && $0.deadline <= target }
                    .min { $0.deadline < $1.deadline }
            }()
            guard let item = due else { break }

            // Re-arm or remove BEFORE running the work, so a re-entrant schedule from the
            // work itself is ordered after this fire.
            lock.lock()
            if let interval = item.interval {
                item.deadline = item.deadline + interval
            } else {
                items.removeAll { $0 === item }
            }
            let cancelled = item.cancelled
            lock.unlock()

            if !cancelled { item.work() }
        }
    }

    /// Number of live (non-cancelled) scheduled items (diagnostics / tests).
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.filter { !$0.cancelled }.count
    }
}
