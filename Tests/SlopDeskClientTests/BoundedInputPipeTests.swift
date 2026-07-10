import Foundation
import XCTest
@testable import SlopDeskClient

/// Pins the stdin→sendInput hand-off contract: the CLI's stdin reader thread must BLOCK when
/// the consumer stalls (mux credit exhausted on a half-open link) instead of buffering the
/// upstream pipe unboundedly, and no byte may be dropped or reordered.
final class BoundedInputPipeTests: XCTestCase {
    /// A producer thread pushing far more than the cap while the consumer is stalled must be
    /// held at the cap (blocking backpressure), then resume as the consumer drains, delivering
    /// every byte in order.
    func testProducerBlocksAtCapThenDrainsLosslessly() {
        let cap = 8 * 1024
        let chunk = 1024
        let totalChunks = 64 // 64 KiB total — 8× the cap
        let pipe = BoundedInputPipe(capacityBytes: cap)

        let produced = NSLock()
        var producedChunks = 0
        let producerDone = expectation(description: "producer finished")
        let producer = Thread {
            for i in 0..<totalChunks {
                var data = Data(repeating: UInt8(truncatingIfNeeded: i), count: chunk)
                data[0] = UInt8(i) // ordinal tag for order verification
                XCTAssertTrue(pipe.enqueue(data))
                produced.lock()
                producedChunks = i + 1
                produced.unlock()
            }
            producerDone.fulfill()
        }
        producer.name = "test.stdin-producer"
        producer.start()

        // Consumer stalled (nobody calls next()): the producer must park at the cap.
        // Poll until progress stops, then hold and re-check.
        var last = -1
        for _ in 0..<200 {
            produced.lock()
            let now = producedChunks
            produced.unlock()
            if now == last, now > 0 { break }
            last = now
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.1) // producer must still be parked, not trickling
        produced.lock()
        let stalledAt = producedChunks
        produced.unlock()
        XCTAssertLessThan(
            stalledAt, totalChunks,
            "producer ran to completion against a stalled consumer — no backpressure",
        )
        XCTAssertLessThanOrEqual(
            pipe.queuedByteCount, cap,
            "buffered bytes exceeded the cap while the consumer was stalled",
        )

        // Drain: the producer must resume and every chunk arrive in enqueue order.
        let drained = expectation(description: "consumer drained all chunks")
        Task.detached {
            var expected = 0
            while let data = await pipe.next() {
                XCTAssertEqual(data.count, chunk)
                XCTAssertEqual(data[0], UInt8(expected), "chunk order broken at \(expected)")
                expected += 1
                if expected == totalChunks { break }
            }
            XCTAssertEqual(expected, totalChunks, "byte loss: fewer chunks delivered than enqueued")
            drained.fulfill()
        }
        wait(for: [producerDone, drained], timeout: 10)
        XCTAssertEqual(pipe.queuedByteCount, 0)
    }

    /// finish() (shutdown / disconnect key / stdin EOF) must unblock a producer parked at the
    /// cap — its enqueue returns false — so the reader thread can exit during teardown.
    func testFinishUnblocksParkedProducer() {
        let pipe = BoundedInputPipe(capacityBytes: 1024)
        let parkedResult = NSLock()
        var rejectedAfterFinish: Bool?
        let producerDone = expectation(description: "parked producer returned")
        let producer = Thread {
            pipe.enqueue(Data(count: 1024)) // fills to cap
            let accepted = pipe.enqueue(Data(count: 1024)) // must PARK here
            parkedResult.lock()
            rejectedAfterFinish = !accepted
            parkedResult.unlock()
            producerDone.fulfill()
        }
        producer.start()

        Thread.sleep(forTimeInterval: 0.2) // let the producer reach the parked enqueue
        parkedResult.lock()
        let returnedEarly = rejectedAfterFinish != nil
        parkedResult.unlock()
        XCTAssertFalse(returnedEarly, "second enqueue did not park at the cap")

        pipe.finish()
        wait(for: [producerDone], timeout: 5)
        parkedResult.lock()
        XCTAssertEqual(rejectedAfterFinish, true, "parked enqueue must return false after finish()")
        parkedResult.unlock()
    }

    /// Chunks queued before finish() still drain in order, then next() returns nil — the
    /// disconnect-key path yields a final partial chunk and immediately finishes.
    func testFinishDeliversQueuedTailThenNil() async {
        let pipe = BoundedInputPipe(capacityBytes: 1 << 20)
        pipe.enqueue(Data([1]))
        pipe.enqueue(Data([2]))
        pipe.finish()
        let first = await pipe.next()
        let second = await pipe.next()
        let third = await pipe.next()
        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(second, Data([2]))
        XCTAssertNil(third)
        XCTAssertFalse(pipe.enqueue(Data([3])), "enqueue after finish must be rejected")
    }

    /// A consumer parked on an empty pipe is resumed by the next enqueue (interactive typing:
    /// one keystroke at a time, consumer usually waiting).
    func testParkedConsumerResumedByEnqueue() async {
        let pipe = BoundedInputPipe(capacityBytes: 1 << 20)
        let got = Task { await pipe.next() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        pipe.enqueue(Data([42]))
        let value = await got.value
        XCTAssertEqual(value, Data([42]))
    }

    /// Cancelling the consumer task (CLI teardown cancels inputSenderTask) resumes a parked
    /// next() with nil instead of leaking it.
    func testCancellationUnblocksParkedConsumer() async {
        let pipe = BoundedInputPipe(capacityBytes: 1 << 20)
        let consumer = Task { await pipe.next() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        let value = await consumer.value
        XCTAssertNil(value)
    }
}
