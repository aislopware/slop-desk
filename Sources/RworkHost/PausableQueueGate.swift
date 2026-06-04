import Foundation
import RworkProtocol

/// The host PTY-read backpressure GATE (TCP-mux S2): a ``RworkProtocol/BoundedQueuePolicy`` plus the
/// pause/resume ACTION, fused so the decision and the action are ATOMIC under one lock.
///
/// ### FIX #3 — lost-wakeup that froze a pane forever
/// The bug was a non-atomic split: `enqueueOutput` computed `full` under the queue lock, UNLOCKED,
/// then called `setPaused(true)`; `dequeueOutput` mirrored it with `setPaused(false)` on another
/// thread. Interleaving could leave the loop PAUSED while the queue was UNDER capacity:
///
/// 1. `enqueue` decides `full == true`, unlocks (has NOT yet called `setPaused`).
/// 2. `dequeue` runs fully: drains below the bound, unlocks, calls `setPaused(false)`.
/// 3. `enqueue` resumes and calls its stale `setPaused(true)`.
///
/// Final state: PAUSED, but `outstanding < capacity` — so no future enqueue/dequeue ever fires the
/// gate again → the `PTYReadLoop` never resumes → the pane's output silently freezes forever.
///
/// The fix is to apply the `setPaused` action WHILE STILL HOLDING the queue lock, so the pause state
/// is always a consistent function of the accounting (last writer under the lock wins, and the winner
/// is the one whose accounting is current). The `setPaused` sink (``PTYReadLoop/setPaused(_:)`` in
/// production) takes its OWN lock, so nesting is fine — the lock order is gate-lock → sink-lock, used
/// identically by enqueue and dequeue, so there is no inversion.
///
/// `@unchecked Sendable`: `policy` is touched only under `lock`; `setPaused` is `@Sendable`.
final class PausableQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: BoundedQueuePolicy
    /// Applies the pause (`true`) / resume (`false`) action. Called WHILE the gate lock is held — it
    /// must take its own lock and must NOT call back into this gate (no reentrancy / no inversion).
    private let setPaused: @Sendable (Bool) -> Void

    init(capacity: Int, setPaused: @escaping @Sendable (Bool) -> Void) {
        self.policy = BoundedQueuePolicy(capacity: capacity)
        self.setPaused = setPaused
    }

    /// Accounts `count` enqueued bytes and, IF the queue crossed the bound, PAUSES — atomically under
    /// the lock so a concurrent ``dequeue(_:)`` cannot interleave a stale resume after this pause
    /// (FIX #3). The action runs under the lock by design (see the type doc).
    func enqueue(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        if policy.enqueue(count) { setPaused(true) }
    }

    /// Accounts `count` dequeued (sent) bytes and, IF the queue drained below the bound, RESUMES —
    /// atomically under the lock (FIX #3), same gate-lock → sink-lock order as ``enqueue(_:)``.
    func dequeue(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        if policy.dequeue(count) { setPaused(false) }
    }

    /// The current outstanding (enqueued-not-yet-sent) byte count. Test/inspection seam.
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return policy.outstanding }
}
