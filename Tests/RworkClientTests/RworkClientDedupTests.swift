import XCTest
import Foundation
import RworkProtocol
@testable import RworkClient

/// Focused unit test for the client-side dedup high-water mark
/// (`RworkClient.deliverOutput`'s `guard seq > highestSeqFed`).
///
/// The e2e/reconnect tests prove no-gap/no-dup/in-order, but the *no-dup* result there is
/// produced by the HOST replay keying (`seq > lastReceivedSeq`) — the replayed tail is
/// always strictly new, so the client dedup branch is never exercised end-to-end. This
/// test drives inbound `output` directly through the client's real handling path so the
/// dedup branch is actually hit: feed seq 1,2,3 then replay 2,3,4 and assert `output`
/// yields bytes for 1,2,3,4 exactly once (the replayed 2,3 are dropped).
final class RworkClientDedupTests: XCTestCase {

    func testDeliverOutputDropsAlreadyFedSeqs() async throws {
        let client = RworkClient()

        // Collect the surfaced output bytes.
        let sink = ByteSink()
        let pump = Task {
            for await chunk in client.output {
                sink.append(chunk)
            }
        }

        // Feed seq 1,2,3 (live), then a replayed tail 2,3,4 where 2,3 are duplicates of
        // what we already delivered and only 4 is new.
        let payloads: [Int64: Data] = [
            1: Data("a".utf8),
            2: Data("b".utf8),
            3: Data("c".utf8),
            4: Data("d".utf8),
        ]
        for seq in [1, 2, 3, 2, 3, 4] as [Int64] {
            await client._handleInboundForTesting(.output(seq: seq, bytes: payloads[seq]!))
        }

        // Let the unbounded output stream flush the yielded chunks to the pump.
        try await waitUntil(timeout: .seconds(5)) { sink.bytes == Data("abcd".utf8) }

        // The replayed 2,3 must have been dropped: exactly a,b,c,d once each, in order.
        XCTAssertEqual(sink.bytes, Data("abcd".utf8),
                       "dedup must drop the replayed seq 2,3 — each byte delivered exactly once, in order")

        // Contiguous + dedup high-water marks both at 4 (we accepted 1..4, dropped re-sends).
        let contiguous = await client.highestContiguousSeq
        XCTAssertEqual(contiguous, 4, "highestContiguousSeq should reflect the 4 accepted outputs")

        pump.cancel()
        await client.close()
    }

    // MARK: - Helpers

    private final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private func waitUntil(timeout: Duration, _ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { throw RworkDedupTestError.timedOut }
    }

    private enum RworkDedupTestError: Error { case timedOut }
}
