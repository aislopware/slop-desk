import AislopdeskProtocol
import Foundation

/// The host PTY-read backpressure GATE (TCP-mux S2): a ``AislopdeskProtocol/BoundedQueuePolicy`` plus the
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
    /// Second, INDEPENDENT pause source: the per-channel ``ReplayBuffer``'s 64 MiB cap / 4 MiB offline
    /// gate (deep-hunt R5 rank 2). The bounded queue (``policy``) bounds enqueued-not-yet-SENT bytes;
    /// the replay buffer bounds SENT-but-not-yet-ACKED retained bytes — a wire-consuming-but-not-acking
    /// client grows the latter unbounded while the former stays empty. The read loop must PAUSE if
    /// EITHER source asserts, and RESUME only when BOTH clear. The two are OR-composed here under the
    /// SAME lock so they can never fight (a lost-wakeup like FIX #3, but across the two sources).
    private var replayPause = false
    /// The last value handed to ``setPaused``; the action fires only on a CHANGE, so neither source can
    /// spuriously resume the loop while the other still wants it paused. Starts `false` (loop runs).
    private var applied = false
    /// Applies the pause (`true`) / resume (`false`) action. Called WHILE the gate lock is held — it
    /// must take its own lock and must NOT call back into this gate (no reentrancy / no inversion).
    private let setPaused: @Sendable (Bool) -> Void

    init(capacity: Int, setPaused: @escaping @Sendable (Bool) -> Void) {
        policy = BoundedQueuePolicy(capacity: capacity)
        self.setPaused = setPaused
    }

    /// Recomputes the combined pause state (`queue full` OR `replay over cap`) and applies it iff it
    /// changed. MUST be called with `lock` held — the apply runs under the lock by design (FIX #3), so
    /// the pause state is always a consistent function of BOTH sources' current accounting.
    private func applyLocked() {
        let want = policy.isFull || replayPause
        if want != applied { applied = want
            setPaused(want)
        }
    }

    /// Accounts `count` enqueued bytes and re-applies the combined pause state atomically under the lock
    /// so a concurrent ``dequeue(_:)`` / ``setReplayPause(_:)`` cannot interleave a stale resume.
    func enqueue(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        policy.enqueue(count)
        applyLocked()
    }

    /// Accounts `count` dequeued (sent) bytes and re-applies the combined pause state atomically.
    func dequeue(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        policy.dequeue(count)
        applyLocked()
    }

    /// Sets the REPLAY-buffer pause source (true = retained ≥ cap / offline gate) and re-applies the
    /// combined state atomically. The read loop resumes only once this clears AND the queue is below
    /// bound — so neither source can resume while the other still wants the loop paused.
    func setReplayPause(_ pause: Bool) {
        lock.lock()
        defer { lock.unlock() }
        replayPause = pause
        applyLocked()
    }

    /// The current outstanding (enqueued-not-yet-sent) byte count. Test/inspection seam.
    var outstanding: Int { lock.lock()
        defer { lock.unlock() }
        return policy.outstanding
    }
}
