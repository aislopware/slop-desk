import XCTest
@testable import AislopdeskProtocol

/// Pure admit / pause / resume decision tests for `BoundedQueuePolicy`. No IO, no queue storage.
/// This is the decider behind the host PTY-read backpressure (S2 scope #4): pause the producer
/// when outstanding bytes cross the high-water mark, resume when the queue drains below it.
final class BoundedQueuePolicyTests: XCTestCase {
    func testEnqueueBelowCapacityDoesNotPause() {
        var q = BoundedQueuePolicy(capacity: 1000)
        XCTAssertFalse(q.enqueue(300), "300 < 1000 → not full, producer keeps running")
        XCTAssertFalse(q.enqueue(699), "999 < 1000 → still not full")
        XCTAssertEqual(q.outstanding, 999)
        XCTAssertFalse(q.isFull)
    }

    func testEnqueueAtOrOverCapacityPauses() {
        var q = BoundedQueuePolicy(capacity: 1000)
        XCTAssertFalse(q.enqueue(900))
        XCTAssertTrue(q.enqueue(100), "reaching capacity exactly → pause")
        XCTAssertTrue(q.isFull)
        // A further enqueue while already full stays full (and re-asserts pause).
        XCTAssertTrue(q.enqueue(500))
        XCTAssertEqual(q.outstanding, 1500)
    }

    func testDequeueResumesOnlyWhenCrossingBackUnderCapacity() {
        var q = BoundedQueuePolicy(capacity: 1000)
        XCTAssertTrue(q.enqueue(1200), "over capacity → full")
        // Draining but STILL at/over capacity must NOT resume.
        XCTAssertFalse(q.dequeue(100), "1100 still ≥ 1000 → stay paused")
        XCTAssertTrue(q.isFull)
        // Draining below capacity resumes exactly once on the crossing.
        XCTAssertTrue(q.dequeue(200), "900 < 1000 → resume on the crossing")
        XCTAssertFalse(q.isFull)
        // A further dequeue while already below capacity does NOT re-trigger resume.
        XCTAssertFalse(q.dequeue(100))
    }

    func testDequeueWhileNotFullNeverResumes() {
        var q = BoundedQueuePolicy(capacity: 1000)
        q.enqueue(500)
        XCTAssertFalse(q.dequeue(200), "was never full → no resume edge")
        XCTAssertEqual(q.outstanding, 300)
    }

    func testDequeueClampsAtZero() {
        var q = BoundedQueuePolicy(capacity: 1000)
        q.enqueue(100)
        q.dequeue(500) // over-dequeue
        XCTAssertEqual(q.outstanding, 0, "outstanding never goes negative")
        XCTAssertFalse(q.isFull)
    }

    func testZeroAndNegativeAmountsAdmitNothing() {
        var q = BoundedQueuePolicy(capacity: 1000)
        XCTAssertFalse(q.enqueue(0))
        XCTAssertFalse(q.enqueue(-50))
        XCTAssertEqual(q.outstanding, 0)
    }

    func testNegativeCapacityClampsToZeroAndIsAlwaysFull() {
        let q = BoundedQueuePolicy(capacity: -100)
        XCTAssertEqual(q.capacity, 0)
        XCTAssertTrue(q.isFull, "a zero-capacity queue is full from the start (pause immediately)")
    }
}
