import Foundation
import XCTest
@testable import AislopdeskTerminal

/// Pins `SerialFeedGate` (the off-main GhosttySurface feed mechanism, docs/31 #5):
/// FIFO ordering, the close barrier's wait-for-in-flight + no-work-after-return
/// guarantees, post-close no-ops, and the high/low-water backpressure seam. The real
/// C-boundary behavior (write_output vs free) can only be exercised on the GUI rig;
/// this is the logic that makes that boundary safe.
final class SerialFeedGateTests: XCTestCase {
    /// Lock-guarded recorder shared between test threads and the gate's queue.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// Lock-guarded bool with SYNCHRONOUS accessors (NSLock's lock()/unlock() are
    /// unavailable directly inside async test bodies).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: Ordering

    func testEnqueuedWorkRunsInFIFOOrder() {
        let gate = SerialFeedGate(label: "test.fifo")
        let recorder = Recorder()
        for i in 0..<200 {
            gate.enqueue(byteCount: 1) { recorder.append(i) }
        }
        gate.closeBarrier()
        XCTAssertEqual(recorder.snapshot, Array(0..<200), "serial FIFO order preserved")
    }

    // MARK: Close barrier

    func testCloseBarrierWaitsForInFlightWork() {
        let gate = SerialFeedGate(label: "test.barrier")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let workFinished = Flag()

        gate.enqueue(byteCount: 1) {
            started.signal()
            release.wait() // stall the queue mid-work
            workFinished.set()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success, "work started")

        // Release the stalled work shortly after the barrier begins waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { release.signal() }
        gate.closeBarrier()

        XCTAssertTrue(workFinished.isSet, "closeBarrier returned only after the in-flight work completed")
        XCTAssertTrue(gate.isClosed)
        XCTAssertEqual(gate.pendingFeedBytes, 0)
    }

    func testWorkEnqueuedAfterCloseNeverRuns() {
        let gate = SerialFeedGate(label: "test.postclose")
        gate.closeBarrier()
        let recorder = Recorder()
        gate.enqueue(byteCount: 64) { recorder.append(1) }
        // Drain anything that might have been (wrongly) scheduled.
        let drained = expectation(description: "drain window elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(recorder.snapshot, [], "post-close enqueue is a no-op")
        XCTAssertEqual(gate.pendingFeedBytes, 0, "post-close enqueue counted nothing")
    }

    func testCloseBarrierIsIdempotent() {
        let gate = SerialFeedGate(label: "test.idempotent")
        gate.enqueue(byteCount: 1) {}
        gate.closeBarrier()
        gate.closeBarrier() // second close: returns immediately, no deadlock, no crash
        XCTAssertTrue(gate.isClosed)
    }

    /// The production shape: close runs on the MAIN thread while a queue block hops
    /// main.ASYNC — must not deadlock (the async block simply lands after the barrier).
    @MainActor
    func testCloseBarrierFromMainDoesNotDeadlockWithMainAsyncHops() {
        let gate = SerialFeedGate(label: "test.mainhop")
        let recorder = Recorder()
        for i in 0..<50 {
            gate.enqueue(byteCount: 1) {
                DispatchQueue.main.async { recorder.append(i) }
            }
        }
        gate.closeBarrier() // on the main thread, like GhosttySurface.close()
        XCTAssertTrue(gate.isClosed, "barrier returned — no deadlock")
    }

    // MARK: Backpressure

    func testWaitReturnsImmediatelyBelowHighWater() async {
        let gate = SerialFeedGate(label: "test.bp.fast", highWaterBytes: 100, lowWaterBytes: 50)
        gate.enqueue(byteCount: 10) {}
        await gate.waitUntilBelowHighWater() // must not hang
        gate.closeBarrier()
    }

    func testWaitParksAtHighWaterAndResumesAtLowWater() async {
        let gate = SerialFeedGate(label: "test.bp.park", highWaterBytes: 100, lowWaterBytes: 40)
        let release = DispatchSemaphore(value: 0)
        // 4 × 30 B = 120 B ≥ high water; each block stalls until released.
        for _ in 0..<4 {
            gate.enqueue(byteCount: 30) { release.wait() }
        }
        XCTAssertEqual(gate.pendingFeedBytes, 120)

        let resumed = Flag()
        let waiter = Task {
            await gate.waitUntilBelowHighWater()
            resumed.set()
        }
        // Give the waiter time to park; it must NOT resume while backlog ≥ high water.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(resumed.isSet, "waiter parked while backlog above high water")

        // Release two blocks → 60 B (between low 40 and high 100): still parked
        // (hysteresis resumes at LOW water, not high).
        release.signal()
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(resumed.isSet, "hysteresis: still parked between low and high water")

        // Release one more → 30 B ≤ low water → resume.
        release.signal()
        await waiter.value
        release.signal() // let the last block finish
        gate.closeBarrier()
    }

    func testCloseResumesParkedWaiter() async {
        let gate = SerialFeedGate(label: "test.bp.close", highWaterBytes: 100, lowWaterBytes: 40)
        let release = DispatchSemaphore(value: 0)
        gate.enqueue(byteCount: 200) { release.wait() }

        let waiter = Task { await gate.waitUntilBelowHighWater() }
        try? await Task.sleep(for: .milliseconds(50))

        // Close from a background thread (the queue is stalled; the barrier waits for
        // the block, which we release just after).
        let closer = Task.detached {
            release.signal()
            gate.closeBarrier()
        }
        await waiter.value // must resolve — either via drain or the close flush
        await closer.value
        XCTAssertTrue(gate.isClosed)
    }

    func testWaitReturnsImmediatelyWhenClosed() async {
        let gate = SerialFeedGate(label: "test.bp.closed", highWaterBytes: 10, lowWaterBytes: 5)
        gate.closeBarrier()
        await gate.waitUntilBelowHighWater() // must not hang
    }

    // MARK: Accounting

    func testPendingBytesDrainToZero() {
        let gate = SerialFeedGate(label: "test.accounting")
        for _ in 0..<100 {
            gate.enqueue(byteCount: 1024) {}
        }
        gate.closeBarrier()
        XCTAssertEqual(gate.pendingFeedBytes, 0, "all accepted work drained")
    }

    // MARK: Non-blocking close (the production teardown — review-round deadlock fix)

    func testAsyncCloseRunsCompletionAfterInFlightWork() {
        let gate = SerialFeedGate(label: "test.aclose")
        let release = DispatchSemaphore(value: 0)
        let workFinished = Flag()
        let order = Recorder()

        gate.enqueue(byteCount: 1) {
            release.wait() // stall — close() must NOT block on this
            workFinished.set()
            order.append(1)
        }
        let completion = expectation(description: "onDrained ran")
        gate.close {
            order.append(2)
            completion.fulfill()
        }
        // close() returned while the block is still stalled — non-blocking proven.
        XCTAssertFalse(workFinished.isSet, "close(onDrained:) did not wait for the in-flight block")
        XCTAssertTrue(gate.isClosed)

        release.signal()
        wait(for: [completion], timeout: 5)
        XCTAssertEqual(order.snapshot, [1, 2], "onDrained ran strictly AFTER the in-flight block")
        XCTAssertEqual(gate.pendingFeedBytes, 0)
    }

    func testAsyncCloseResumesParkedWaiterImmediately() async {
        let gate = SerialFeedGate(label: "test.aclose.waiter", highWaterBytes: 100, lowWaterBytes: 40)
        let release = DispatchSemaphore(value: 0)
        gate.enqueue(byteCount: 200) { release.wait() } // park the queue above high water

        let waiter = Task { await gate.waitUntilBelowHighWater() }
        try? await Task.sleep(for: .milliseconds(50))

        // Close while the block is STILL stalled: the waiter must resume NOW (not when
        // the queue eventually drains) — a closed gate has nothing to wait for.
        gate.close {}
        await waiter.value // must not hang even though the queue is still parked
        release.signal() // let the block (and the deferred onDrained) finish
        XCTAssertTrue(gate.isClosed)
    }

    func testAsyncClosePostCloseEnqueueNeverRuns() {
        let gate = SerialFeedGate(label: "test.aclose.postclose")
        let drained = expectation(description: "drained")
        gate.close { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        let recorder = Recorder()
        gate.enqueue(byteCount: 64) { recorder.append(1) }
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(recorder.snapshot, [], "post-close enqueue is a no-op")
    }
}
