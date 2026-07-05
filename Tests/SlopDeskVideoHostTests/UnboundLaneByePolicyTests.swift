import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// PURE unbound-lane bye policy (the reconnect-wedge fix): which dropped datagrams prove the
/// sender still believes a session exists (→ answer `bye`), and how the per-channel rate limiter
/// bounds the replies. No sockets — the decider takes `(channel, payload)`, the limiter takes `now`.
final class UnboundLaneByePolicyTests: XCTestCase {
    // MARK: Decider — what warrants a bye

    func testInputAndRecoveryDatagramsWarrantBye() {
        // Any client→host in-session lane implies a live-session belief — payload contents are
        // irrelevant (even a corrupt body proves the sender targets a session on this lane).
        XCTAssertTrue(UnboundLaneByeDecider.warrantsBye(channel: .input, payload: Data([0x01, 0xFF])))
        XCTAssertTrue(UnboundLaneByeDecider.warrantsBye(channel: .recovery, payload: Data([0x03])))
    }

    func testInSessionControlMessagesWarrantBye() {
        XCTAssertTrue(UnboundLaneByeDecider.warrantsBye(
            channel: .control, payload: VideoControlMessage.keepalive.encode(),
        ))
        XCTAssertTrue(UnboundLaneByeDecider.warrantsBye(
            channel: .control,
            payload: VideoControlMessage.resizeRequest(
                desired: VideoSize(width: 800, height: 600), epoch: 3,
            ).encode(),
        ))
        XCTAssertTrue(UnboundLaneByeDecider.warrantsBye(
            channel: .control, payload: VideoControlMessage.focusWindow.encode(),
        ))
    }

    func testBootstrapAndDiscoveryControlMessagesNeverWarrantBye() {
        // A hello mints (it never even reaches the drop path) — and must never be answered with a
        // bye even if it somehow did; the discovery lanes are session-LESS by design.
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(
            channel: .control,
            payload: VideoControlMessage.hello(
                protocolVersion: SlopDeskVideoProtocol.version,
                requestedWindowID: 42,
                viewport: VideoSize(width: 1, height: 1),
            ).encode(),
        ))
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(
            channel: .control, payload: VideoControlMessage.listWindows.encode(),
        ))
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(
            channel: .control, payload: VideoControlMessage.listSystemDialogs.encode(),
        ))
    }

    func testStrayByeGetsNoReply() {
        // Replying bye-to-bye could ping-pong with a confused peer — never reflect an ending.
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(
            channel: .control, payload: VideoControlMessage.bye.encode(),
        ))
    }

    func testCorruptControlAndHostToClientChannelsNeverWarrantBye() {
        // Validate-then-drop: an undecodable control body, or a host→client-only channel arriving
        // inbound, is corrupt/hostile — never reflect at garbage.
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(channel: .control, payload: Data([0xFF, 0x00])))
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(channel: .video, payload: Data([0x01])))
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(channel: .geometry, payload: Data([0x01])))
        XCTAssertFalse(UnboundLaneByeDecider.warrantsBye(channel: .cursor, payload: Data([0x01])))
    }

    // MARK: Rate limiter

    func testLimiterAdmitsThenBlocksWithinTheInterval() {
        var limiter = UnboundByeRateLimiter(minInterval: 1.0, capacity: 8)
        XCTAssertTrue(limiter.admit(channelID: 7, now: 100.0))
        XCTAssertFalse(limiter.admit(channelID: 7, now: 100.5), "same channel inside the interval")
        XCTAssertTrue(limiter.admit(channelID: 7, now: 101.0), "re-admits once the interval elapsed")
    }

    func testLimiterIsPerChannel() {
        var limiter = UnboundByeRateLimiter(minInterval: 1.0, capacity: 8)
        XCTAssertTrue(limiter.admit(channelID: 1, now: 100.0))
        XCTAssertTrue(limiter.admit(channelID: 2, now: 100.1), "a sibling channel is not throttled")
    }

    func testLimiterCapacityBoundsTheMapAndPrunesStaleEntries() {
        var limiter = UnboundByeRateLimiter(minInterval: 1.0, capacity: 2)
        XCTAssertTrue(limiter.admit(channelID: 1, now: 100.0))
        XCTAssertTrue(limiter.admit(channelID: 2, now: 100.0))
        // Full of FRESH entries: a new channel is denied (bounded, fail-quiet).
        XCTAssertFalse(limiter.admit(channelID: 3, now: 100.5))
        // Once the tracked entries go stale, the prune makes room and the new channel admits.
        XCTAssertTrue(limiter.admit(channelID: 3, now: 101.5))
    }
}
