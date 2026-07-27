import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

/// "How far behind is this subscriber?" as an O(log n) subtraction rather than a copy.
///
/// The existing "bytes above S" primitives — `messages(after:)` and `snapshotSource(after:)` —
/// MATERIALISE every payload, up to the 256 MiB retained ceiling, and the fan-out's laggard check
/// runs on both the producer and the ack path under the owner's replay lock. Copying the whole
/// retained tail per ack is not a thing that check can do, so ``ReplayBuffer/retainedBytes(above:)``
/// answers from running totals instead.
final class ReplayBufferLagMetricTests: XCTestCase {
    private func chunk(_ size: Int, _ byte: UInt8 = 0x41) -> Data {
        Data(repeating: byte, count: size)
    }

    // MARK: - The answer is exact

    func testRetainedBytesAboveCountsExactlyTheEntriesAboveTheCursor() {
        var buffer = ReplayBuffer(scrollbackBytes: 0)
        let s1 = buffer.append(bytes: chunk(10))
        let s2 = buffer.append(bytes: chunk(20))
        let s3 = buffer.append(bytes: chunk(30))

        XCTAssertEqual(buffer.retainedBytes(above: 0), 60, "a cursor at 0 is behind everything")
        XCTAssertEqual(buffer.retainedBytes(above: s1), 50)
        XCTAssertEqual(buffer.retainedBytes(above: s2), 30)
        XCTAssertEqual(buffer.retainedBytes(above: s3), 0, "a cursor at the head is not behind at all")
        XCTAssertEqual(
            buffer.retainedBytes(above: s3 + 1000), 0,
            "a cursor past the head — an over-eager or corrupt ack — is still not behind",
        )
    }

    /// The load-bearing case: `ack(upTo:)` drops the released prefix out of `entries`, and the
    /// cumulative labels the metric subtracts must stay meaningful across that drop. A metric that
    /// reset its base on every ack would over-report the tail and evict a healthy subscriber.
    func testRetainedBytesAboveIsExactAfterAnAckDropsThePrefix() {
        var buffer = ReplayBuffer(scrollbackBytes: 0)
        for _ in 0..<10 { buffer.append(bytes: chunk(100)) }
        XCTAssertEqual(buffer.retainedBytes, 1000)

        // The fast member acked through seq 4; the buffer releases that prefix.
        buffer.ack(upTo: 4)
        XCTAssertEqual(buffer.retainedBytes, 600, "precondition: 6 entries of 100 bytes remain")

        XCTAssertEqual(
            buffer.retainedBytes(above: 4), 600,
            "the acked prefix is gone, so the fast member's cursor is behind exactly the live tail",
        )
        XCTAssertEqual(buffer.retainedBytes(above: 7), 300)
        XCTAssertEqual(buffer.retainedBytes(above: 10), 0)
        XCTAssertEqual(
            buffer.retainedBytes(above: 1), 600,
            "a cursor BELOW the retained window answers the whole tail — the prefix it names is "
                + "released, and released bytes are not lag",
        )
    }

    /// Appending after an ack keeps the answer exact: the running total is monotone, the labels
    /// keep ascending, and a fresh binary search still lands on the right entry.
    func testRetainedBytesAboveStaysExactAcrossInterleavedAppendsAndAcks() {
        var buffer = ReplayBuffer(scrollbackBytes: 0)
        var expectedAboveZero = 0
        for round in 1...20 {
            buffer.append(bytes: chunk(round))
            expectedAboveZero += round
            if round.isMultiple(of: 3) {
                let released = buffer.retainedBytes(above: Int64(round))
                buffer.ack(upTo: Int64(round))
                expectedAboveZero = released
                XCTAssertEqual(
                    buffer.retainedBytes, released,
                    "round \(round): the metric predicted exactly what survived the ack",
                )
            }
            XCTAssertEqual(
                buffer.retainedBytes(above: 0), expectedAboveZero,
                "round \(round): the whole retained tail",
            )
            XCTAssertEqual(
                buffer.retainedBytes(above: buffer.highestSeq), 0,
                "round \(round): a current member is never behind",
            )
        }
    }

    /// `adoptSnapshotReplay` REPLACES the tail wholesale (the state-transfer reattach). The metric
    /// has to be re-derived there or it reads a stale base — which, being an under-count, would
    /// silently stop evicting.
    func testRetainedBytesAboveIsRederivedAfterASnapshotAdoption() {
        var buffer = ReplayBuffer(scrollbackBytes: 0)
        for _ in 0..<5 { buffer.append(bytes: chunk(100)) }
        buffer.ack(upTo: 2)

        // The rendered stream as `composeSnapshotReplay` would adopt it: the same seq range,
        // different (smaller) bytes.
        let adopted: [WireMessage] = [
            .output(seq: 3, bytes: chunk(10, 0x42)),
            .output(seq: 4, bytes: chunk(10, 0x42)),
            .output(seq: 5, bytes: chunk(10, 0x42)),
        ]
        buffer.adoptSnapshotReplay(adopted)

        XCTAssertEqual(buffer.retainedBytes, 30, "precondition: the adopted tail is what is retained")
        XCTAssertEqual(buffer.retainedBytes(above: 2), 30)
        XCTAssertEqual(buffer.retainedBytes(above: 4), 10)
        XCTAssertEqual(buffer.retainedBytes(above: 5), 0)

        // …and it keeps working for what the drain appends afterwards.
        buffer.append(bytes: chunk(7, 0x43))
        XCTAssertEqual(buffer.retainedBytes(above: 5), 7)
        XCTAssertEqual(buffer.retainedBytes(above: 2), 37)
    }

    /// The metric reads the LIVE tail only. Acked history lives in the scrollback ring, which is
    /// not something anybody is waiting for — counting it would evict every member of a pane with
    /// a large scrollback.
    func testRetainedBytesAboveIgnoresTheAckedScrollbackRing() {
        var buffer = ReplayBuffer(scrollbackBytes: 1024 * 1024)
        for _ in 0..<5 { buffer.append(bytes: chunk(100)) }
        buffer.ack(upTo: 5)
        XCTAssertGreaterThan(buffer.scrollbackRingBytesForTesting, 0, "precondition: the ring holds history")
        XCTAssertEqual(
            buffer.retainedBytes(above: 0), 0,
            "everything is acked — nobody is behind, however much history the ring keeps",
        )
    }

    /// An empty buffer answers 0 rather than trapping on the binary search bounds.
    func testRetainedBytesAboveOnAnEmptyBufferIsZero() {
        let buffer = ReplayBuffer(scrollbackBytes: 0)
        XCTAssertEqual(buffer.retainedBytes(above: 0), 0)
        XCTAssertEqual(buffer.retainedBytes(above: Int64.max), 0)
        XCTAssertEqual(buffer.retainedBytes(above: -1), 0)
    }
}
