import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + wire-tolerance for the `keepalive` control message (type 6) added for the
/// CONCURRENCY-HOST-1 crash-without-bye reaper. The keepalive is additive and MUST be
/// wire-safe in both directions: a peer that does not recognise type 6 hits the decoder's
/// `default` arm, which THROWS `.malformed` — both consumers catch-and-drop it, never crash.
final class KeepaliveCodecTests: XCTestCase {

    /// encode → decode → .keepalive, and it is a single type byte (value 6, no body — like `bye`).
    func testKeepaliveRoundTrip() throws {
        let ka = VideoControlMessage.keepalive
        let bytes = ka.encode()
        XCTAssertEqual(bytes, Data([6]), "keepalive is a single type byte (value 6, zero body)")
        XCTAssertEqual(bytes.count, 1)
        XCTAssertEqual(ka.messageType, 6)
        XCTAssertEqual(try VideoControlMessage.decode(bytes), .keepalive)
    }

    /// Type 6 is the NEXT free byte after resizeAck (5) and does not collide with the existing set.
    func testKeepaliveTypeByteIsNextFree() {
        XCTAssertEqual(VideoControlMessage.keepalive.messageType, 6)
        XCTAssertEqual(VideoControlMessage.resizeAck(captureWidth: 1, captureHeight: 1, epoch: 0).messageType, 5)
        XCTAssertEqual(VideoControlMessage.bye.messageType, 3)
    }

    /// WIRE-TOLERANCE contract: an "old decoder" (one that lacks a case) — simulated by any
    /// decoder fed a type byte it does not implement, here type 10 (past the highest defined type 9
    /// focusWindow) — THROWS `.malformed`, it does NOT crash. This is exactly the behaviour an old peer
    /// exhibits when it receives a newer control type: it drops it cleanly (the host's `handleControl` /
    /// the client's `ReceivedDatagramRouter` both catch-and-drop).
    func testUnknownTypeThrowsNotCrash() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([10]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("an unknown type byte must throw .malformed, got \(error)")
            }
        }
    }

    /// The existing trio + resize pair still encode byte-identically (adding case 6 perturbs nothing).
    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.bye.encode(), Data([3]))
        XCTAssertEqual(try VideoControlMessage.decode(Data([3])), .bye)
        let rr = VideoControlMessage.resizeRequest(desired: VideoSize(width: 100, height: 50), epoch: 7)
        XCTAssertEqual(try VideoControlMessage.decode(rr.encode()), rr)
    }
}
