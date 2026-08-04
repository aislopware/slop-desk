// AndroidBridgeSocketTests — the ack/stream split, which is the one subtle thing every bridge
// connection does.
//
// The hazard is that the reply line and the first bytes of the stream arrive in the SAME receive:
// `logcat` starts printing and the encoder starts emitting the moment the host acks. A
// read-until-newline that throws away its remainder loses the head of the stream — for `open` that is
// the codec id and the parameter sets, and the panel shows a permanently black rectangle with no
// error to explain it.
//
// Hang-safety: nothing here calls `connect`, so no `NWConnection` is ever constructed. `consume` is a
// plain method over a buffer, which is exactly why the framing was put there rather than in the
// receive handler.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class AndroidBridgeSocketTests: XCTestCase {
    private final class Capture {
        var replies: [AndroidBridgeReply] = []
        var bytes = Data()
        var ends: [String?] = []
    }

    private func socket(_ capture: Capture) throws -> AndroidBridgeSocket {
        try XCTUnwrap(AndroidBridgeSocket(
            request: ["op": "list"],
            onReply: { capture.replies.append($0) },
            onBytes: { capture.bytes.append($0) },
            onEnd: { capture.ends.append($0) },
        ))
    }

    private func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: The split

    func testTheStreamsFirstBytesInTheAcksOwnChunkAreKept() throws {
        // THE assertion in this file. Losing this tail costs `open` its codec id and parameter sets.
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(line(["ok": true]) + Data("h264".utf8))
        XCTAssertEqual(capture.replies.count, 1)
        XCTAssertEqual(capture.bytes, Data("h264".utf8))
    }

    func testAnAckSplitAcrossReceivesIsHeldUntilItsNewline() throws {
        let capture = Capture()
        let connection = try socket(capture)
        let ack = line(["ok": true, "port": 7421])
        connection.consume(ack.prefix(4))
        XCTAssertTrue(capture.replies.isEmpty)
        connection.consume(ack.dropFirst(4))
        XCTAssertEqual(capture.replies.count, 1)
        XCTAssertTrue(capture.bytes.isEmpty)
    }

    func testEverythingAfterTheAckIsStreamBytesAndNothingElseIsParsed() throws {
        // A payload that happens to contain a newline must not be mistaken for a second reply.
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(line(["ok": true]))
        connection.consume(Data([0x00, 0x0A, 0xFF]))
        XCTAssertEqual(capture.replies.count, 1)
        XCTAssertEqual(capture.bytes, Data([0x00, 0x0A, 0xFF]))
    }

    // MARK: The reply itself

    func testTheSuccessCaseCarriesTheRawLine() throws {
        // Raw bytes rather than a decoded dictionary, so the one decoder that knows the wire shape
        // reads them directly instead of a second copy of its field rules picking through
        // `[String: Any]` — which is also not `Sendable` and could not cross the continuation's hop.
        let capture = Capture()
        let connection = try socket(capture)
        let ack = line(["ok": true, "devices": []])
        connection.consume(ack)
        guard case let .ok(payload) = capture.replies.first else {
            XCTFail("expected an ok reply")
            return
        }
        XCTAssertEqual(payload, ack.dropLast()) // the newline is not part of the object
    }

    func testTheHostsOwnComplaintIsSurfacedRatherThanSwallowed() throws {
        // A missing `adb`, an AVD that will not boot and a device that vanished mid-request all say
        // so here and nowhere else.
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(line(["ok": false, "error": "no such avd"]))
        XCTAssertEqual(capture.replies.first, .failed("no such avd"))
    }

    func testAReplyThatIsNotAnObjectFails() throws {
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(Data("this is not json\n".utf8))
        guard case .failed = capture.replies.first else {
            XCTFail("expected a failure")
            return
        }
    }

    func testARefusalWithNoMessageStillReadsAsASentence() throws {
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(line(["ok": false]))
        XCTAssertEqual(capture.replies.first, .failed("The host refused."))
    }

    // MARK: Bounds

    func testAPeerThatNeverSendsANewlineIsABoundedMistake() throws {
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(Data(repeating: UInt8(ascii: "x"), count: AndroidBridgeSocket.replyLimit + 1))
        guard case .failed = capture.replies.first else {
            XCTFail("expected the reply to be abandoned")
            return
        }
        XCTAssertEqual(capture.ends.count, 1)
    }

    func testTheReplyIsDeliveredAtMostOnce() throws {
        let capture = Capture()
        let connection = try socket(capture)
        connection.consume(line(["ok": true]))
        connection.consume(line(["ok": true]))
        XCTAssertEqual(capture.replies.count, 1)
    }

    func testAnUnencodableRequestBuildsNoSocketAtAll() {
        XCTAssertNil(AndroidBridgeSocket(
            request: ["op": Date()], onReply: { _ in },
        ))
    }
}
#endif
