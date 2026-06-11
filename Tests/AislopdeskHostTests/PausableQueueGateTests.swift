import XCTest
import AislopdeskProtocol
@testable import AislopdeskHost

/// FIX #3 tests for ``PausableQueueGate`` — the host PTY-read backpressure gate that fuses the
/// ``BoundedQueuePolicy`` accounting with the read-loop pause/resume action ATOMICALLY under one lock.
///
/// No PTY, no HostServer, no socket: the gate's `setPaused` sink is a plain recording closure, so
/// these are pure concurrency unit tests of the lost-wakeup fix (the action being atomic with the
/// accounting), in the spirit of the pure decider tests for `BoundedQueuePolicy`.
final class PausableQueueGateTests: XCTestCase {

    /// Thread-safe recorder for the pause/resume sink + a count of transitions.
    private final class PauseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var current = false
        private(set) var transitions = 0
        func apply(_ paused: Bool) {
            lock.lock(); defer { lock.unlock() }
            if paused != current { transitions += 1 }
            current = paused
        }
        var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return current }
    }

    /// Basic behaviour: crossing the bound pauses; draining below it resumes.
    func testPausesAtBoundAndResumesBelow() {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 100) { rec.apply($0) }

        gate.enqueue(60)
        XCTAssertFalse(rec.isPaused, "under capacity → not paused")
        gate.enqueue(60) // outstanding 120 ≥ 100 → pause
        XCTAssertTrue(rec.isPaused, "at/over capacity → paused")
        gate.dequeue(60) // outstanding 60 < 100 → resume
        XCTAssertFalse(rec.isPaused, "drained below capacity → resumed")
        XCTAssertEqual(gate.outstanding, 60)
    }

    /// FIX #3 STRESS: many concurrent enqueue/dequeue pairs that net to ZERO outstanding. Because the
    /// pause action is applied ATOMICALLY with the accounting (under the gate lock), the final state
    /// MUST be NOT-paused (outstanding == 0 < capacity). The OLD non-atomic split (decide-then-unlock-
    /// then-act) could let a stale `setPaused(true)` from an enqueue win the race AFTER a concurrent
    /// dequeue's resume, leaving the gate PAUSED while empty → the PTY read loop frozen forever. We
    /// run a large interleaved load and assert the gate ends un-paused with outstanding 0.
    func testConcurrentEnqueueDequeueNeverLeavesPausedWhileBelowCapacity() async {
        let rec = PauseRecorder()
        let capacity = 1024
        let gate = PausableQueueGate(capacity: capacity) { rec.apply($0) }
        let pairs = 5_000
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

        // After equal enqueue/dequeue totals the queue is empty.
        XCTAssertEqual(gate.outstanding, 0, "balanced enqueue/dequeue must net to zero outstanding")
        // The load-bearing FIX #3 assertion: empty queue ⇒ the gate is NOT paused. A lost-wakeup
        // (stale pause winning a race) would leave it stuck paused here.
        XCTAssertFalse(rec.isPaused, "empty queue (outstanding 0 < capacity) must NOT be left PAUSED (FIX #3 lost-wakeup)")
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
            group.addTask { gate.enqueue(60) }   // → 120 ≥ 100 → slow pause
            group.addTask {
                // Let the enqueue cross the bound + begin its (slow) pause, then drain below it.
                try? await Task.sleep(for: .milliseconds(10))
                gate.dequeue(80) // → 40 < 100 → resume (must end up applied LAST under the atomic gate)
            }
        }

        XCTAssertEqual(gate.outstanding, 40, "net accounting is correct")
        XCTAssertFalse(rec.isPaused,
                       "below capacity after the race ⇒ must NOT be left paused (FIX #3: pause action atomic with accounting)")
    }

    /// OFF-path parity: a gate is only built when flow control is ON (the session leaves `outputGate`
    /// nil OFF). This pins that the gate itself never pauses on a sub-bound enqueue — so even if it
    /// were consulted OFF (it is not), it would not spuriously backpressure a small write.
    func testSubBoundEnqueueNeverPauses() {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 64 * 1024) { rec.apply($0) }
        for _ in 0..<100 { gate.enqueue(8) } // 800 bytes ≪ 64 KiB
        XCTAssertFalse(rec.isPaused, "a small enqueue under the bound never pauses")
        XCTAssertEqual(rec.transitions, 0, "no pause/resume churn for sub-bound writes (interactive path)")
    }

    // MARK: - Replay-buffer second pause source (R5 rank 2 — OR composition)

    /// The ReplayBuffer source pauses the loop INDEPENDENT of the queue bound (the unbounded-retention
    /// case: queue empty because the client consumes the wire, but retained-unacked bytes over the cap).
    func testReplayPauseSourceAlonePausesAndResumes() {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 1000) { rec.apply($0) }
        gate.enqueue(10) // well under the queue bound
        XCTAssertFalse(rec.isPaused)
        gate.setReplayPause(true)   // retained-byte cap crossed even though the queue is near-empty
        XCTAssertTrue(rec.isPaused, "the replay source pauses the read loop independent of the queue bound")
        gate.setReplayPause(false)
        XCTAssertFalse(rec.isPaused, "clearing the replay source resumes (queue is below bound)")
    }

    /// Resume happens ONLY when BOTH sources clear — draining the queue while replay still wants pause
    /// must NOT resume (the cross-source analogue of the FIX #3 lost-wakeup).
    func testResumesOnlyWhenBothSourcesClear() {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 100) { rec.apply($0) }
        gate.enqueue(120)            // queue full → pause
        gate.setReplayPause(true)    // replay also wants pause
        XCTAssertTrue(rec.isPaused)
        gate.dequeue(120)            // queue drains below bound, but replay still over cap
        XCTAssertTrue(rec.isPaused, "queue cleared but replay still over cap → must remain paused")
        gate.setReplayPause(false)   // now both clear
        XCTAssertFalse(rec.isPaused, "both sources clear → resume")
        XCTAssertEqual(gate.outstanding, 0)
    }

    /// Symmetric: replay clears first but the queue is still full → stay paused until the queue drains.
    func testQueueKeepsLoopPausedAfterReplayClears() {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 100) { rec.apply($0) }
        gate.setReplayPause(true)
        gate.enqueue(120)
        XCTAssertTrue(rec.isPaused)
        gate.setReplayPause(false)   // replay clears, queue still full
        XCTAssertTrue(rec.isPaused, "replay cleared but queue still full → remain paused")
        gate.dequeue(120)
        XCTAssertFalse(rec.isPaused, "both clear → resume")
    }

    /// Concurrency: hammer BOTH sources from many tasks, ending with both cleared. The atomic OR must
    /// leave the gate NOT paused (no cross-source lost-wakeup).
    func testConcurrentBothSourcesEndUnpausedWhenBothClear() async {
        let rec = PauseRecorder()
        let gate = PausableQueueGate(capacity: 512) { rec.apply($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { for _ in 0..<2000 { gate.enqueue(256); gate.dequeue(256) } }
            }
            for _ in 0..<4 {
                group.addTask { for _ in 0..<2000 { gate.setReplayPause(true); gate.setReplayPause(false) } }
            }
        }
        XCTAssertEqual(gate.outstanding, 0, "balanced enqueue/dequeue nets to zero")
        XCTAssertFalse(rec.isPaused,
                       "both sources cleared ⇒ gate must NOT be left paused (no cross-source lost-wakeup)")
    }
}
