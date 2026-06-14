import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE per-datagram mux routing: admit / retire / route decisions with the
/// reconnect-generation drop. Mirrors `InputDatagramRouterTests`'s style (a pure
/// router, a closed Decision enum, no socket / no SCStream).
final class VideoMuxRouterTests: XCTestCase {
    func testRouteAdmittedChannelID() {
        var router = VideoMuxRouter()
        router.admit(11)
        XCTAssertEqual(router.route(channelID: 11, channel: .video, bytesCount: 1200), .route(channelID: 11))
        XCTAssertTrue(router.isAdmitted(11))
    }

    func testUnadmittedChannelIDIsRejected() {
        let router = VideoMuxRouter()
        XCTAssertEqual(router.route(channelID: 99, channel: .control, bytesCount: 4), .rejectUnadmitted)
        XCTAssertFalse(router.isAdmitted(99))
    }

    func testRetiredChannelIDIsDropped() {
        // Reconnect-generation case: a channelID admitted then retired must DROP its
        // in-flight datagrams (not reject, not route) so the previous generation's
        // bytes never reach a new session.
        var router = VideoMuxRouter()
        router.admit(7)
        router.retire(7)
        XCTAssertEqual(router.route(channelID: 7, channel: .video, bytesCount: 1200), .dropRetired)
        XCTAssertFalse(router.isAdmitted(7))
    }

    func testReconnectAdmitsNewChannelIDWhileOldStaysRetired() {
        // A reconnecting client is admitted under a NEW id; the OLD id stays retired so
        // its still-in-flight datagrams are dropped, while the new lane routes.
        var router = VideoMuxRouter()
        router.admit(7)
        router.retire(7)
        router.admit(9) // fresh generation
        XCTAssertEqual(router.route(channelID: 9, channel: .video, bytesCount: 1200), .route(channelID: 9))
        XCTAssertEqual(router.route(channelID: 7, channel: .video, bytesCount: 1200), .dropRetired)
    }

    func testTwoChannelIDsRouteIndependently() {
        var router = VideoMuxRouter()
        router.admit(11)
        router.admit(13)
        XCTAssertEqual(router.route(channelID: 11, channel: .video, bytesCount: 800), .route(channelID: 11))
        XCTAssertEqual(router.route(channelID: 13, channel: .cursor, bytesCount: 36), .route(channelID: 13))
        // Retiring one leaves the other admitted.
        router.retire(11)
        XCTAssertEqual(router.route(channelID: 11, channel: .video, bytesCount: 800), .dropRetired)
        XCTAssertEqual(router.route(channelID: 13, channel: .cursor, bytesCount: 36), .route(channelID: 13))
    }

    func testReadmittingRetiredChannelIDClearsRetiredMark() {
        // Admitting an id that was previously retired (legitimate reuse of an id by a
        // fresh generation) clears the retired mark so it routes again.
        var router = VideoMuxRouter()
        router.admit(5)
        router.retire(5)
        XCTAssertEqual(router.route(channelID: 5, channel: .video, bytesCount: 100), .dropRetired)
        router.admit(5)
        XCTAssertEqual(router.route(channelID: 5, channel: .video, bytesCount: 100), .route(channelID: 5))
    }

    func testEmptyDatagramIsDropped() {
        var router = VideoMuxRouter()
        router.admit(3)
        guard case .drop = router.route(channelID: 3, channel: .video, bytesCount: 0) else {
            XCTFail("expected drop for an empty datagram")
            return
        }
    }
}
