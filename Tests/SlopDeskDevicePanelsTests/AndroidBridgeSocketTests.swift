// AndroidBridgeSocketTests — the two GRAMMAR faces a bridge connection is built out of.
//
// The framing used to be here, and it is not: the ack/stream split, the reply ceiling and the
// "everything after the newline belongs to the stream" rule are `slopdesk_devicelink::bridge`'s, and
// its own tests drive them over a real socket rather than by calling a method with a buffer. What is
// left on this side is what stayed Swift — the request line and the reply verdict, each one door —
// so this file tests exactly the two things this file's target still decides nothing about but must
// still spell correctly.
//
// Hang-safety: nothing here calls `connect`, so no socket is ever opened.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

@MainActor
final class AndroidBridgeSocketTests: XCTestCase {
    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: The reply verdict

    func testTheSuccessCaseCarriesTheRawLine() {
        // Raw bytes rather than a decoded dictionary, so the one decoder that knows the wire shape
        // reads them directly instead of a second copy of its field rules picking through
        // `[String: Any]` — which is also not `Sendable` and could not cross the continuation's hop.
        let ack = line(["ok": true, "devices": []])
        guard case let .ok(payload) = AndroidBridgeReply.decode(ack) else {
            XCTFail("expected an ok reply")
            return
        }
        XCTAssertEqual(payload, ack)
    }

    func testTheHostsOwnComplaintIsSurfacedRatherThanSwallowed() {
        // A missing `adb`, an AVD that will not boot and a device that vanished mid-request all say
        // so here and nowhere else.
        XCTAssertEqual(
            AndroidBridgeReply.decode(line(["ok": false, "error": "no such avd"])),
            .failed("no such avd"),
        )
    }

    func testAReplyThatIsNotAnObjectFails() {
        guard case .failed = AndroidBridgeReply.decode(Data("this is not json".utf8)) else {
            XCTFail("expected a failure")
            return
        }
    }

    func testARefusalWithNoMessageStillReadsAsASentence() {
        // The door never answers an empty sentence, which is what makes its `0` sentinel sound.
        XCTAssertEqual(AndroidBridgeReply.decode(line(["ok": false])), .failed("The host refused."))
    }

    // MARK: The request line

    func testARequestMissingItsRequiredFieldBuildsNoLineAtAll() {
        // The one refusal left, and it is the daemon's own rule one hop earlier: `adb -s "" shell`
        // is a different command from the one that was meant, so an empty field is an absent field
        // and a request carrying one is never sent.
        XCTAssertNil(AndroidBridgeRequest.shutdown(serial: ""))
        XCTAssertNil(AndroidBridgeRequest.boot(avd: ""))
        XCTAssertNil(AndroidBridgeRequest.console("rotate", serial: ""))
        XCTAssertNotNil(AndroidBridgeRequest.list)
    }

    func testTheRequestLineArrivesTerminated() throws {
        // The framing is the door's: the crate writes one whole line and the socket writes it
        // verbatim, so nothing on this side appends a newline and nothing may strip one.
        let request = try XCTUnwrap(AndroidBridgeRequest.list)
        XCTAssertEqual(request.last, UInt8(ascii: "\n"))
    }
}
#endif
