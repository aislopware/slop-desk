import XCTest
import RworkProtocol
@testable import RworkTransport

/// PURE client-side demux tests for `MuxRouter`. No socket, no per-channel decoder —
/// the router only returns (channelID, opaque bytes) decisions + advances the table.
/// Mirrors `InputDatagramRouterTests` (Decision-enum assertions).
final class MuxRouterTests: XCTestCase {

    /// Opens `id` in the router via a channelOpen frame and asserts it became open.
    private func open(_ id: UInt32, in router: inout MuxRouter, file: StaticString = #filePath, line: UInt = #line) {
        let decision = router.route(.channelOpen(channelID: id, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0))
        guard case .lifecycle(id, .open) = decision else {
            return XCTFail("expected open lifecycle for \(id), got \(decision)", file: file, line: line)
        }
    }

    func testDemuxesTwoInterleavedChannelsIntoIndependentOutputs() {
        var router = MuxRouter()
        open(1, in: &router)
        open(3, in: &router)

        let payloadA1 = Data("A1".utf8)
        let payloadB1 = Data("B1".utf8)
        let payloadA2 = Data("A2".utf8)

        // Interleaved A,B,A on the single mux stream must demux to the right channels.
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: payloadA1)),
                       .deliverData(channelID: 1, payload: payloadA1))
        XCTAssertEqual(router.route(.channelData(channelID: 3, payload: payloadB1)),
                       .deliverData(channelID: 3, payload: payloadB1))
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: payloadA2)),
                       .deliverData(channelID: 1, payload: payloadA2))
    }

    func testDataPayloadIsCarriedOpaqueByteIdentically() {
        var router = MuxRouter()
        open(1, in: &router)
        // A real inner WireMessage frame: must pass through untouched.
        let inner = WireMessage.output(seq: 5, bytes: Data("vt ✅".utf8)).encode()
        let decision = router.route(.channelData(channelID: 1, payload: inner))
        guard case let .deliverData(1, payload) = decision else {
            return XCTFail("expected deliverData, got \(decision)")
        }
        XCTAssertEqual(payload, inner, "the router must not parse or mutate the channelData body")
    }

    func testUnknownChannelDataIsDroppedNotCrashed() {
        var router = MuxRouter()
        open(1, in: &router)
        // Channel 99 was never opened: DATA for it must be dropped, never crash.
        let decision = router.route(.channelData(channelID: 99, payload: Data("orphan".utf8)))
        guard case .dropUnknownChannel(99, _) = decision else {
            return XCTFail("expected dropUnknownChannel, got \(decision)")
        }
        // The known channel still routes afterwards.
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: Data("ok".utf8))),
                       .deliverData(channelID: 1, payload: Data("ok".utf8)))
    }

    func testDataOnNonOpenChannelIsDropped() {
        var router = MuxRouter()
        open(1, in: &router)
        // Half-close channel 1, then send data: a non-open channel drops (known) data.
        _ = router.route(.channelClose(channelID: 1))
        let decision = router.route(.channelData(channelID: 1, payload: Data("late".utf8)))
        guard case .dropUnknownChannel(1, _) = decision else {
            return XCTFail("expected drop for non-open channel, got \(decision)")
        }
    }

    func testCloseOnChannelALeavesChannelBRoutable() {
        var router = MuxRouter()
        open(1, in: &router) // A
        open(3, in: &router) // B

        // Close A.
        let closeDecision = router.route(.channelClose(channelID: 1))
        guard case .lifecycle(1, .halfClosed) = closeDecision else {
            return XCTFail("expected A to half-close, got \(closeDecision)")
        }
        // A no longer delivers data...
        guard case .dropUnknownChannel(1, _) = router.route(.channelData(channelID: 1, payload: Data())) else {
            return XCTFail("A must not deliver after close")
        }
        // ...but B is untouched and still routes.
        XCTAssertEqual(router.route(.channelData(channelID: 3, payload: Data("B-still-live".utf8))),
                       .deliverData(channelID: 3, payload: Data("B-still-live".utf8)))
        XCTAssertTrue(router.isOpen(3))
        XCTAssertFalse(router.isOpen(1))
    }

    func testOpenAckMarksChannelOpen() {
        var router = MuxRouter()
        // Client allocated id 1 and is awaiting the host's ack.
        let id = router.allocateChannel()
        XCTAssertEqual(id, 1)
        let decision = router.route(.channelOpenAck(channelID: id, accepted: true))
        guard case .lifecycle(1, .open) = decision else {
            return XCTFail("openAck should mark the channel open, got \(decision)")
        }
        XCTAssertTrue(router.isOpen(1))
    }

    func testOpenAckRejectedDoesNotOpenChannel() {
        var router = MuxRouter()
        // Client allocated id 1 and is awaiting the host's ack; the host REFUSES it.
        let id = router.allocateChannel()
        XCTAssertEqual(id, 1)
        let decision = router.route(.channelOpenAck(channelID: id, accepted: false))
        // A refusal must mark the channel dead (.closed), NOT open it (the bug).
        guard case .lifecycle(1, .closed) = decision else {
            return XCTFail("a refused openAck must close the channel, got \(decision)")
        }
        XCTAssertFalse(router.isOpen(1), "a refused channel must never be open")
        // ...and data for the refused channel is dropped, never delivered.
        guard case .dropUnknownChannel(1, _) = router.route(.channelData(channelID: 1, payload: Data("refused".utf8))) else {
            return XCTFail("data for a refused channel must be dropped")
        }
        // The id is retained (monotonic allocator never reuses it): the next allocation is 3.
        XCTAssertEqual(router.allocateChannel(), 3)
    }

    func testWindowAdjustReportsLifecycleWithoutChangingOpenState() {
        var router = MuxRouter()
        open(1, in: &router)
        let decision = router.route(.windowAdjust(channelID: 1, bytesToAdd: 4096))
        guard case .lifecycle(1, .open) = decision else {
            return XCTFail("windowAdjust on an open channel reports .open, got \(decision)")
        }
        XCTAssertTrue(router.isOpen(1), "windowAdjust must not change channel open state")
    }

    func testAllocateProducesOddMonotonicIDs() {
        var router = MuxRouter()
        XCTAssertEqual([router.allocateChannel(), router.allocateChannel(), router.allocateChannel()], [1, 3, 5])
    }
}
