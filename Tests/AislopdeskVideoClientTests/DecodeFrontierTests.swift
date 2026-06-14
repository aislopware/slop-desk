import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// Component 2: the client's decode frontier — wrap-aware monotonic max of successfully-decoded
/// frameIDs + the wire sentinel encoding every recovery request carries.
final class DecodeFrontierTests: XCTestCase {
    func testEmptyFrontierEncodesSentinel() {
        let frontier = DecodeFrontier()
        XCTAssertNil(frontier.lastDecodedFrameID)
        XCTAssertEqual(frontier.wireValue, RecoveryMessage.noFrameDecodedSentinel)
    }

    func testMonotonicKeepNewest() {
        var frontier = DecodeFrontier()
        frontier.noteDecoded(frameID: 0) // frameID 0 is REAL (ids start at 0)
        XCTAssertEqual(frontier.wireValue, 0)
        frontier.noteDecoded(frameID: 5)
        XCTAssertEqual(frontier.wireValue, 5)
        frontier.noteDecoded(frameID: 3) // late out-of-order decode — never regresses
        XCTAssertEqual(frontier.wireValue, 5)
        frontier.noteDecoded(frameID: 5) // duplicate — no-op
        XCTAssertEqual(frontier.wireValue, 5)
    }

    func testWrapAwareAdvance() {
        var frontier = DecodeFrontier()
        frontier.noteDecoded(frameID: .max - 1)
        frontier.noteDecoded(frameID: 2) // wrapped past UInt32.max — still "newer"
        XCTAssertEqual(frontier.wireValue, 2)
        frontier.noteDecoded(frameID: .max) // pre-wrap id arriving late — older, ignored
        XCTAssertEqual(frontier.wireValue, 2)
    }
}
