import CSlopDeskFFI
import Foundation

/// The host PTY-read backpressure GATE (TCP-mux S2): the three pause sources folded into one
/// decision, plus the pause/resume ACTION, fused so the decision and the action are ATOMIC under
/// one lock.
///
/// A face over `slopdesk-wire`'s `mux::flow::PausableQueueGate`, which owns the fold — the queue's
/// high-water mark, the replay buffer's retained-bytes cap, the fan-out backlog, and the memory of
/// what was last applied. What stays here is the two things Rust must not hold: the `NSLock` this
/// host already owns, and the `setPaused` sink.
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
/// gate again → the reader never resumes → the pane's output silently freezes forever.
///
/// The fix is to apply the `setPaused` action WHILE STILL HOLDING the lock, so the pause state is
/// always a consistent function of the accounting. The `setPaused` sink
/// (``PaneOutputStream/setPaused(_:)`` in production) takes its OWN lock, so nesting is fine — the
/// lock order is gate-lock → sink-lock, used identically by every entry point, so there is no
/// inversion.
///
/// `@unchecked Sendable`: `gate` is touched only under `lock`; `setPaused` is `@Sendable`.
final class PausableQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    /// The fold, by value. Five scalars and no allocation, so it lives inside the region `lock`
    /// already covers — a handle would put the state behind a pointer the lock says nothing about.
    private var gate: SlopDeskPausableGate
    /// Applies the pause (`true`) / resume (`false`) action. Called WHILE the gate lock is held —
    /// it must take its own lock and must NOT call back into this gate (no reentrancy).
    private let setPaused: @Sendable (Bool) -> Void

    init(capacity: Int, setPaused: @escaping @Sendable (Bool) -> Void) {
        gate = slopdesk_pausable_gate_new(Int64(capacity))
        self.setPaused = setPaused
    }

    /// Runs one mutation under the lock and applies the action iff the fold said the state changed.
    ///
    /// The `changed` flag is the whole point: a clear on one source cannot spuriously resume a loop
    /// another source still wants paused, and a threshold that was already crossed does not fire
    /// the sink again.
    private func apply(_ mutate: (UnsafeMutablePointer<SlopDeskPausableGate>) -> SlopDeskPauseVerdict) {
        lock.lock()
        defer { lock.unlock() }
        let verdict = mutate(&gate)
        if verdict.changed { setPaused(verdict.paused) }
    }

    /// Accounts `count` enqueued bytes and re-applies the combined pause state atomically.
    func enqueue(_ count: Int) {
        apply { slopdesk_pausable_gate_enqueue($0, Int64(count)) }
    }

    /// Accounts `count` dequeued (sent) bytes and re-applies the combined pause state atomically.
    func dequeue(_ count: Int) {
        apply { slopdesk_pausable_gate_dequeue($0, Int64(count)) }
    }

    /// Sets the REPLAY-buffer pause source — the per-channel buffer's 256 MiB cap / 64 MiB offline
    /// gate, which bounds SENT-but-not-yet-ACKED bytes the queue can never see.
    func setReplayPause(_ pause: Bool) {
        apply { slopdesk_pausable_gate_set_replay_pause($0, pause) }
    }

    /// Sets the FAN-OUT pause source: bytes sequenced that the fastest member has not shipped. `0`
    /// (an inline drain, or an empty subscriber set) makes this source inert, so a pane that never
    /// fanned out is accounted exactly as it always was.
    func setFanoutBacklog(_ bytes: Int) {
        apply { slopdesk_pausable_gate_set_fanout_backlog($0, Int64(bytes)) }
    }

    /// Re-sizes the queue bound and re-applies the pause state atomically — `detach()` raises it to
    /// ``SlopDeskProtocol/MuxFlowControl/detachedHostQueueCapacityBytes`` (no client → latency is
    /// meaningless; the bound becomes "output while away" capacity so the pane's agent keeps
    /// running), and ``MuxChannelSession/rebindRelay(data:control:onExit:)`` restores the attached
    /// latency bound. The fan-out source is compared against the SAME number, so one re-size moves
    /// both.
    func setCapacity(_ newCapacity: Int) {
        apply { slopdesk_pausable_gate_set_capacity($0, Int64(newCapacity)) }
    }

    /// The current outstanding (enqueued-not-yet-sent) byte count. Test/inspection seam.
    var outstanding: Int { lock.lock()
        defer { lock.unlock() }
        return Int(gate.outstanding)
    }
}
