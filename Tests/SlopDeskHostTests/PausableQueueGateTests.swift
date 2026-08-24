import XCTest
@testable import SlopDeskHost

/// FIX #3 tests for ``PausableQueueGate`` — the host PTY-read backpressure gate that fuses the
/// three pause sources with the read-loop pause/resume ACTION atomically under one lock.
///
/// What is left here is the half that is Swift's. The FOLD — the queue bound, the replay source,
/// the fan-out source, their OR, the "only fire the sink on a CHANGE" rule and the re-size — is
/// `slopdesk-wire`'s `mux::flow::PausableQueueGate` and is tested there; eight cases that spelled
/// its truth table a second time in Swift were deleted with the port. What no Rust test can see is
/// the thing FIX #3 was actually about: that the ACTION runs while this side still holds the lock,
/// so a stale pause cannot land after a concurrent resume and freeze the pane forever. That is a
/// property of the `NSLock` and the sink, and it is what the three cases below hammer.
///
/// No PTY, no HostServer, no socket: the `setPaused` sink is a plain recording closure.
final class PausableQueueGateTests: XCTestCase {
    /// Thread-safe recorder for the pause/resume sink + a count of transitions.
    private final class PauseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var current = false
        private(set) var transitions = 0
        func apply(_ paused: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if paused != current { transitions += 1 }
            current = paused
        }

        var isPaused: Bool { lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    /// FIX #3 STRESS: many concurrent enqueue/dequeue pairs under a drained queue. Because the pause
    /// action is applied ATOMICALLY with the accounting (under the gate lock), the final state MUST
    /// be NOT-paused (outstanding == 0 < capacity). The OLD non-atomic split (decide-then-unlock-
    /// then-act) could let a stale `setPaused(true)` from an enqueue win the race AFTER a concurrent
    /// dequeue's resume, leaving the gate PAUSED while empty → the PTY read loop frozen forever.
    ///
    /// ### Why the totals are DRAINED rather than assumed to balance
    /// The fold CLAMPS outstanding at zero, so a dequeue that runs while the queue is empty does not
    /// go negative — it discards its own bytes. Equal enqueue and dequeue totals therefore net to
    /// zero only while no consumer ever outpaces the producers, and nothing here can enforce that:
    /// the stagger below is a scheduling hint, and under a loaded machine a consumer wins, its chunk
    /// is clamped away, and the run ends with a permanent positive residue. Past `capacity` that
    /// residue means the gate is PAUSED — CORRECTLY, since the queue really is full — and the
    /// assertion fires on a gate that did exactly what it promised. So the interleaved load stays,
    /// and the queue is DRAINED explicitly afterwards; what is asserted is the property the fix is
    /// about, on a queue that is empty because it was emptied.
    func testConcurrentEnqueueDequeueNeverLeavesPausedWhileBelowCapacity() async {
        let rec = PauseRecorder()
        let capacity = 1024
        let gate = PausableQueueGate(capacity: capacity) { rec.apply($0) }
        let pairs = 5000
        let chunk = 256 // 4 enqueues to cross the 1024 bound, so the pause path is hit constantly

        // Producers enqueue; consumers dequeue the SAME total, concurrently, so the net is zero.
        await withTaskGroup(of: Void.self) { group in
            // 4 producer tasks.
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<(pairs / 4) { gate.enqueue(chunk) }
                }
            }
            // 4 consumer tasks (drain after a tiny stagger so enqueues get ahead and cross the bound).
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<(pairs / 4) {
                        // Spin a touch so consumers trail producers, maximising the pause/resume churn.
                        for _ in 0..<8 { _ = gate.outstanding }
                        gate.dequeue(chunk)
                    }
                }
            }
        }

        // Whatever the clamp swallowed, drain the rest — each pass takes the whole current
        // outstanding, so this terminates with nothing enqueued behind it.
        while gate.outstanding > 0 { gate.dequeue(gate.outstanding) }
        XCTAssertEqual(gate.outstanding, 0, "a fully drained queue holds nothing")
        // The load-bearing FIX #3 assertion: empty queue ⇒ the gate is NOT paused. A lost-wakeup
        // (stale pause winning a race) would leave it stuck paused here.
        XCTAssertFalse(
            rec.isPaused,
            "empty queue (outstanding 0 < capacity) must NOT be left PAUSED (FIX #3 lost-wakeup)",
        )
        XCTAssertGreaterThan(rec.transitions, 0, "the pause/resume path was actually exercised under load")
    }

    /// FIX #3 DETERMINISTIC race: forces the exact lost-wakeup interleaving. The pause sink is SLOW
    /// (it sleeps inside `setPaused(true)`), widening the window. One task enqueues past the bound
    /// (its slow pause is in flight); concurrently another task dequeues below the bound and resumes.
    ///
    /// - ATOMIC (fixed): the enqueue holds the gate lock for the WHOLE slow pause, so the concurrent
    ///   dequeue BLOCKS on the lock until the pause finishes, then drains + resumes LAST → final state
    ///   NOT paused (correct).
    /// - NON-ATOMIC (bug): the enqueue decides full, unlocks, THEN runs the slow pause; the dequeue
    ///   meanwhile drains + resumes; the stale slow `setPaused(true)` lands AFTER the resume → final
    ///   state PAUSED while the queue is EMPTY → frozen forever.
    ///
    /// We assert the final state is NOT paused. With the atomic gate this is deterministic.
    func testSlowPauseRaceDoesNotStrandPausedWhileEmpty() async {
        let rec = PauseRecorder()
        let capacity = 100
        let gate = PausableQueueGate(capacity: capacity) { paused in
            if paused {
                // Slow the pause action to widen the lost-wakeup window. Atomic gate: this runs under
                // the lock, so a concurrent dequeue must wait — no inconsistency.
                Thread.sleep(forTimeInterval: 0.05)
            }
            rec.apply(paused)
        }
        // Seed below the bound.
        gate.enqueue(60) // outstanding 60

        await withTaskGroup(of: Void.self) { group in
            group.addTask { gate.enqueue(60) } // → 120 ≥ 100 → slow pause
            group.addTask {
                // Let the enqueue cross the bound + begin its (slow) pause, then drain below it.
                try? await Task.sleep(for: .milliseconds(10))
                gate.dequeue(80) // → 40 < 100 → resume (must end up applied LAST under the atomic gate)
            }
        }

        XCTAssertEqual(gate.outstanding, 40, "net accounting is correct")
        XCTAssertFalse(
            rec.isPaused,
            "below capacity after the race ⇒ must NOT be left paused (FIX #3: pause action atomic with accounting)",
        )
    }

    /// Concurrency: hammer BOTH sources from many tasks, ending with both cleared. The atomic OR must
    /// leave the gate NOT paused (no cross-source lost-wakeup).
    func testConcurrentBothSourcesEndUnpausedWhenBothClear() async {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 512) { rec.apply($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { for _ in 0..<2000 { gate.enqueue(256)
                    gate.dequeue(256)
                } }
            }
            for _ in 0..<4 {
                group.addTask { for _ in 0..<2000 { gate.setReplayPause(true)
                    gate.setReplayPause(false)
                } }
            }
        }
        XCTAssertEqual(gate.outstanding, 0, "balanced enqueue/dequeue nets to zero")
        XCTAssertFalse(
            rec.isPaused,
            "both sources cleared ⇒ gate must NOT be left paused (no cross-source lost-wakeup)",
        )
    }
}
