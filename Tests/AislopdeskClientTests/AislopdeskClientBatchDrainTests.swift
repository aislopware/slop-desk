import AislopdeskProtocol
import AislopdeskTransport
import Foundation
import XCTest
@testable import AislopdeskClient

/// Pins the inbox + wake batch-drain contract that replaced the per-chunk `output`
/// AsyncStream: (1) ack/seq bookkeeping is wire-time and does NOT depend on the consumer
/// draining, (2) a backlog crosses as ONE batch in FIFO order via one wake, (3) a tail
/// appended just before the wake stream finishes (exit) is still drainable (the
/// final-drain contract), (4) `takeOutputBatch` empties the inbox atomically.
final class AislopdeskClientBatchDrainTests: XCTestCase {
    func testAckAdvancesWithoutAnyConsumption() async throws {
        let transport = RecordingTransport()
        let client = AislopdeskClient(makeTransport: { transport })
        try await client.connect(host: "h", port: 1)

        // Deliver 1..5 with NO takeOutputBatch — ack semantics must be wire-time.
        for seq in 1...5 {
            await client.handleInboundForTesting(.output(seq: Int64(seq), bytes: Data("x".utf8)))
        }
        let contiguous = await client.highestContiguousSeq
        XCTAssertEqual(contiguous, 5, "contiguous high-water tracks wire delivery, not consumption")

        await client.flushAck()
        let acked = await transport.ackedSeqs
        XCTAssertEqual(acked.last, 5, "ack flush sends the wire-time high-water with an undrained inbox")

        await client.close()
    }

    func testBacklogCrossesAsOneBatchInFIFOOrder() async {
        let client = AislopdeskClient(makeTransport: { RecordingTransport() })

        // Park no consumer; push a burst, then drain once.
        let chunks = (1...20).map { Data("chunk-\($0);".utf8) }
        for (i, chunk) in chunks.enumerated() {
            await client.handleInboundForTesting(.output(seq: Int64(i + 1), bytes: chunk))
        }
        let batch = await client.takeOutputBatch()
        XCTAssertEqual(batch, chunks, "whole backlog in one batch, FIFO order")

        let second = await client.takeOutputBatch()
        XCTAssertTrue(second.isEmpty, "take is atomic — second take sees an empty inbox")

        await client.close()
    }

    func testWakeCoalescesBurstIntoSingleSignal() async {
        let client = AislopdeskClient(makeTransport: { RecordingTransport() })

        // Push a burst BEFORE any consumer exists: bufferingNewest(1) retains exactly one wake.
        for seq in 1...10 {
            await client.handleInboundForTesting(.output(seq: Int64(seq), bytes: Data([UInt8(seq)])))
        }

        var wakes = 0
        var drained: [Data] = []
        for await _ in client.outputWakeups {
            wakes += 1
            drained += await client.takeOutputBatch()
            if wakes == 1 { break } // one wake must have carried the whole burst
        }
        XCTAssertEqual(drained.count, 10, "one coalesced wake announces the whole burst")

        await client.close()
    }

    func testExitTailIsDrainedByFinalTake() async throws {
        let client = AislopdeskClient(makeTransport: { RecordingTransport() })

        // Consumer mirrors the production contract: wake loop + unconditional final drain.
        let sink = ByteSink()
        let pump = Task {
            for await _ in client.outputWakeups {
                for chunk in await client.takeOutputBatch() { sink.append(chunk) }
            }
            for chunk in await client.takeOutputBatch() { sink.append(chunk) }
        }

        // Tail chunks immediately followed by exit — the wake stream finishes right after
        // the appends; the final drain must still deliver every byte.
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("tail-".utf8)))
        await client.handleInboundForTesting(.output(seq: 2, bytes: Data("bytes".utf8)))
        await client.handleInboundForTesting(.exit(code: 0))

        try await waitUntil(timeout: .seconds(5)) { sink.bytes == Data("tail-bytes".utf8) }
        XCTAssertEqual(sink.bytes, Data("tail-bytes".utf8), "no tail loss across the finish")

        // The pump LOOP must also have ended (wake stream finished on exit).
        _ = await pump.value

        await client.close()
    }

    /// Night-review regression: a (re)connect must DROP the dead session's undrained inbox
    /// — stale entries would render after the fresh-session wipe AND credit their wire
    /// bytes to the NEW transport (a phantom windowAdjust over-grant on the new channel).
    func testReconnectClearsUndrainedInbox() async throws {
        let client = AislopdeskClient(makeTransport: { RecordingTransport() })
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("dead-session".utf8)))

        // Reconnect WITHOUT draining: the stale entry must be gone afterwards.
        try await client.connect(host: "h", port: 1)
        let batch = await client.takeOutputBatch()
        XCTAssertTrue(batch.isEmpty, "the dead session's undrained entries never cross a reconnect")

        // And the fresh session's first output still flows normally.
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("fresh".utf8)))
        let fresh = await client.takeOutputBatch()
        XCTAssertEqual(fresh, [Data("fresh".utf8)])
        await client.close()
    }

    // MARK: - Helpers

    private actor RecordingTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        private(set) var ackedSeqs: [Int64] = []

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume _: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = UUID()
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq: Int64) { ackedSeqs.append(seq) }
        func sendBye() {}
        func close() { continuation.finish() }
    }

    private final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock()
            data.append(d)
            lock.unlock()
        }

        var bytes: Data { lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private func waitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { throw BatchDrainTestError.timedOut }
    }

    private enum BatchDrainTestError: Error { case timedOut }
}
