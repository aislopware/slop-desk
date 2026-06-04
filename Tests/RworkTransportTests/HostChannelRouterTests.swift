import XCTest
import RworkProtocol
@testable import RworkTransport

/// PURE host-side demux tests for `HostChannelRouter`. The host is the responder: it
/// registers peer-initiated channels from `channelOpen`, then services their data.
/// Same Decision contract as the client `MuxRouter`. No socket, no per-channel decoder.
final class HostChannelRouterTests: XCTestCase {

    /// Registers a peer-initiated channel via channelOpen and asserts it opened.
    private func peerOpen(_ id: UInt32, in router: inout HostChannelRouter, file: StaticString = #filePath, line: UInt = #line) {
        let decision = router.route(.channelOpen(channelID: id, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0))
        guard case .lifecycle(id, .open) = decision else {
            return XCTFail("expected peer-open lifecycle for \(id), got \(decision)", file: file, line: line)
        }
    }

    func testRegistersPeerInitiatedChannelOnOpen() {
        var router = HostChannelRouter()
        // The host did NOT allocate id 1; the client did. channelOpen registers it.
        XCTAssertFalse(router.isOpen(1))
        peerOpen(1, in: &router)
        XCTAssertTrue(router.isOpen(1))
        XCTAssertEqual(router.liveChannelIDs, [1])
    }

    func testDemuxesTwoInterleavedChannelsIntoIndependentOutputs() {
        var router = HostChannelRouter()
        peerOpen(1, in: &router)
        peerOpen(3, in: &router)

        let a = Data("client->host A".utf8)
        let b = Data("client->host B".utf8)
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: a)),
                       .deliverData(channelID: 1, payload: a))
        XCTAssertEqual(router.route(.channelData(channelID: 3, payload: b)),
                       .deliverData(channelID: 3, payload: b))
        // And interleave back to A.
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: a)),
                       .deliverData(channelID: 1, payload: a))
    }

    func testUnknownChannelDataIsDroppedNotCrashed() {
        var router = HostChannelRouter()
        peerOpen(1, in: &router)
        let decision = router.route(.channelData(channelID: 7, payload: Data("never-opened".utf8)))
        guard case .dropUnknownChannel(7, _) = decision else {
            return XCTFail("expected dropUnknownChannel, got \(decision)")
        }
        // Known channel still routes.
        XCTAssertEqual(router.route(.channelData(channelID: 1, payload: Data("ok".utf8))),
                       .deliverData(channelID: 1, payload: Data("ok".utf8)))
    }

    func testCloseOnChannelALeavesChannelBRoutable() {
        var router = HostChannelRouter()
        peerOpen(1, in: &router) // A
        peerOpen(3, in: &router) // B

        let closeDecision = router.route(.channelClose(channelID: 1))
        guard case .lifecycle(1, .halfClosed) = closeDecision else {
            return XCTFail("expected A to half-close, got \(closeDecision)")
        }
        guard case .dropUnknownChannel(1, _) = router.route(.channelData(channelID: 1, payload: Data())) else {
            return XCTFail("A must not deliver after close")
        }
        XCTAssertEqual(router.route(.channelData(channelID: 3, payload: Data("B-live".utf8))),
                       .deliverData(channelID: 3, payload: Data("B-live".utf8)))
        XCTAssertFalse(router.isOpen(1))
        XCTAssertTrue(router.isOpen(3))
    }

    func testDataPayloadCarriedOpaque() {
        var router = HostChannelRouter()
        peerOpen(1, in: &router)
        let inner = WireMessage.input(Data("ls -la\n".utf8)).encode()
        guard case let .deliverData(1, payload) = router.route(.channelData(channelID: 1, payload: inner)) else {
            return XCTFail("expected deliverData")
        }
        XCTAssertEqual(payload, inner, "host router must not parse the channelData body")
    }
}
