#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import XCTest
@testable import SlopDeskVideoClient

/// Byte-budget cap on the client's inbound datagram FIFO (wifi-flap hardening). The queue sits
/// between the UDP receive queue and the session actor's single consumer; if the consumer is
/// starved while datagrams keep arriving, the backlog must stop growing at the budget. Dropping
/// here is equivalent to wire loss (UDP media is loss-tolerant by design — FEC / NACK / the
/// decode gate's IDR recovery already handle a missing datagram), so tail-drop, never corrupt.
final class ClientInboundQueueTests: XCTestCase {
    private func payload(marker: UInt8, count: Int) -> Data {
        var data = Data(repeating: 0, count: count)
        data[0] = marker
        return data
    }

    /// With no drain (a starved consumer), appends past the byte budget must be shed — the
    /// backlog's payload bytes stay at/below the default budget and the SURVIVORS are the
    /// oldest items in arrival order (tail-drop: refusing the newest datagram is exactly a
    /// wire loss of that datagram).
    func testTailDropsPastDefaultByteBudgetKeepingOldest() {
        let queue = ClientInboundQueue()
        let itemSize = 1 << 20 // 1 MiB
        let appended = 20
        for i in 0..<appended {
            queue.append(.media(.video, payload(marker: UInt8(i), count: itemSize)))
        }
        let drained = queue.drainAll()
        let drainedBytes = drained.reduce(0) { total, item in
            switch item {
            case let .media(_, data): total + data.count
            case let .cursor(data): total + data.count
            }
        }
        // Default budget is 8 MiB — the backlog must never exceed it.
        XCTAssertLessThanOrEqual(drainedBytes, 8 << 20, "inbound backlog grew past the byte budget")
        XCTAssertLessThan(drained.count, appended, "no item was shed past the budget")
        // Survivors are the OLDEST items, still in arrival order (drop-newest = wire loss).
        for (index, item) in drained.enumerated() {
            guard case let .media(channel, data) = item else {
                XCTFail("unexpected item kind at \(index)")
                continue
            }
            XCTAssertEqual(channel, .video)
            XCTAssertEqual(data[0], UInt8(index), "survivor order broken at \(index)")
        }
        // The shed datagrams are counted for the debug surface.
        let drops = queue.droppedTotals()
        XCTAssertEqual(drops.items, appended - drained.count)
        XCTAssertEqual(drops.bytes, (appended - drained.count) * itemSize)
    }

    /// A drain frees the whole budget: the queue keeps admitting at steady state — the cap bites
    /// only while the consumer is genuinely starved.
    func testDrainRestoresBudget() {
        let queue = ClientInboundQueue(byteBudget: 2048)
        queue.append(.media(.video, payload(marker: 1, count: 1024)))
        queue.append(.media(.video, payload(marker: 2, count: 1024)))
        queue.append(.media(.video, payload(marker: 3, count: 1024))) // over budget → shed
        XCTAssertEqual(queue.drainAll().count, 2)
        queue.append(.media(.video, payload(marker: 4, count: 1024)))
        let second = queue.drainAll()
        XCTAssertEqual(second.count, 1, "post-drain appends must be admitted again")
        XCTAssertEqual(queue.droppedTotals().items, 1)
    }

    /// Cursor datagrams count against the same budget (both sockets feed the one queue).
    func testCursorItemsCountAgainstBudget() {
        let queue = ClientInboundQueue(byteBudget: 100)
        queue.append(.cursor(payload(marker: 1, count: 60)))
        queue.append(.cursor(payload(marker: 2, count: 60))) // 120 > 100 → shed
        XCTAssertEqual(queue.drainAll().count, 1)
        let drops = queue.droppedTotals()
        XCTAssertEqual(drops.items, 1)
        XCTAssertEqual(drops.bytes, 60)
    }
}
#endif
