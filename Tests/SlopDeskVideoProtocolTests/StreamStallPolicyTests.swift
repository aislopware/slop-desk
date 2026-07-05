import XCTest
@testable import SlopDeskVideoProtocol

/// C7 improvement 2 — the pure frozen-stream detector. The load-bearing case is the IDLE-SKIP trap: a
/// healthy idle window (frames suppressed by design, heartbeat still flowing) must NOT be declared stalled.
final class StreamStallPolicyTests: XCTestCase {
    private let policy = StreamStallPolicy(threshold: 3.0)

    private func inputs(
        now: TimeInterval = 100,
        frame: TimeInterval? = nil,
        heartbeat: TimeInterval? = nil,
        connected: Bool = true,
        idleSkip: Bool = false,
    ) -> StreamStallPolicy.Inputs {
        .init(now: now, lastFrameAt: frame, lastHeartbeatAt: heartbeat, connected: connected, idleSkipActive: idleSkip)
    }

    func testLiveWhenRecentFrame() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, frame: 99.5, heartbeat: 98)), .live)
        XCTAssertFalse(policy.isStalled(inputs(now: 100, frame: 99.5)))
    }

    func testStalledWhenNoSignalPastThreshold() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, frame: 96, heartbeat: 96)), .stalled)
        XCTAssertTrue(policy.isStalled(inputs(now: 100, frame: 96, heartbeat: 96)))
    }

    /// Exactly at the threshold counts as stalled (`>=`).
    func testStalledExactlyAtThreshold() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, heartbeat: 97)), .stalled)
    }

    /// THE regression: during idle-skip the last FRAME is arbitrarily old (frames suppressed) but the
    /// heartbeat is fresh — the stream is healthy, NOT stalled. Off the pre-design "no frames = stalled".
    func testIdleSkipWithFreshHeartbeatIsLiveDespiteStaleFrame() {
        let i = inputs(now: 100, frame: 80 /* 20s stale */, heartbeat: 99.8, idleSkip: true)
        XCTAssertEqual(policy.evaluate(i), .live, "idle-skip keeps the heartbeat flowing — not a stall")
    }

    /// But if idle-skip is active AND even the heartbeat has gone silent past the threshold, the host is
    /// genuinely frozen — stalled.
    func testIdleSkipWithSilentHeartbeatIsStalled() {
        let i = inputs(now: 100, frame: 80, heartbeat: 90, idleSkip: true)
        XCTAssertEqual(policy.evaluate(i), .stalled)
    }

    /// When NOT idle-skipping, a fresh frame keeps the stream live even if the heartbeat lagged.
    func testActiveStreamUsesNewestOfFrameOrHeartbeat() {
        let i = inputs(now: 100, frame: 99.9, heartbeat: 90, idleSkip: false)
        XCTAssertEqual(policy.evaluate(i), .live)
    }

    func testNotConnectedIsNeverStalled() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, frame: 10, heartbeat: 10, connected: false)), .notConnected)
        XCTAssertFalse(policy.isStalled(inputs(now: 100, frame: 10, heartbeat: 10, connected: false)))
    }

    /// A just-opened stream with no signal yet is UNKNOWN — no premature scrim.
    func testNoSignalYetIsUnknown() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, frame: nil, heartbeat: nil)), .unknown)
        XCTAssertFalse(policy.isStalled(inputs(now: 100)))
    }

    /// During idle-skip with no heartbeat yet (just entered idle-skip) → unknown, not a false stall.
    func testIdleSkipWithNoHeartbeatYetIsUnknown() {
        XCTAssertEqual(policy.evaluate(inputs(now: 100, frame: 99, heartbeat: nil, idleSkip: true)), .unknown)
    }
}
