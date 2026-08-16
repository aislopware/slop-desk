import XCTest
@testable import SlopDeskVideoProtocol

/// Send-path viability for the shared client UDP flow (wifi-flap hardening): while the media
/// connection reports `.waiting` (dead path — Network.framework would buffer every datagram
/// in-process indefinitely) or is dead, the periodic senders (20 Hz NetworkStats, 5 s
/// keepalive) must skip their fire. Pure mapping — no socket.
final class UDPSendPathPolicyTests: XCTestCase {
    func testWaitingRevokesViability() {
        XCTAssertEqual(
            UDPSendPathPolicy.viability(after: .waiting), false,
            ".waiting is the dead-path state — periodic sends must stop buffering in-process",
        )
    }

    func testFailedAndCancelledRevokeViability() {
        XCTAssertEqual(UDPSendPathPolicy.viability(after: .failed), false)
        XCTAssertEqual(UDPSendPathPolicy.viability(after: .cancelled), false)
    }

    func testReadyRestoresViability() {
        XCTAssertEqual(
            UDPSendPathPolicy.viability(after: .ready), true,
            "path recovery must resume the periodic senders",
        )
    }

    func testBringUpStatesLeaveViabilityUnchanged() {
        // setup/preparing carry no path verdict: initial bring-up keeps the optimistic
        // default, and a waiting→preparing→ready recovery stays non-viable until .ready.
        XCTAssertNil(UDPSendPathPolicy.viability(after: .setup))
        XCTAssertNil(UDPSendPathPolicy.viability(after: .preparing))
    }
}
