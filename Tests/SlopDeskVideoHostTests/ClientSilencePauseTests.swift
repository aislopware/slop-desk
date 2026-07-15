#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
import XCTest
@testable import SlopDeskVideoHost

/// The PURE client-silence video-pause decision
/// (``SlopDeskVideoHostSession/shouldPauseForClientSilence(now:lastInbound:sawFeedback:thresholdSeconds:)``).
/// Pins the safety contract: DISABLED (threshold ≤ 0) never pauses (the default-OFF, byte-identical
/// path), an UNPROVEN client (never sent feedback) never pauses (mirrors the idle-reaper's
/// never-reap-without-keepalive rule), and a proven client pauses only once its last inbound is at
/// least `thresholdSeconds` old — so the host stops blasting to a peer that is not listening without
/// tripping on a normal keepalive-only gap.
final class ClientSilencePauseTests: XCTestCase {
    private func pause(
        silentFor: Double, sawFeedback: Bool = true, threshold: Double = 12,
    ) -> Bool {
        SlopDeskVideoHostSession.shouldPauseForClientSilence(
            now: 1000, lastInbound: 1000 - silentFor, sawFeedback: sawFeedback, thresholdSeconds: threshold,
        )
    }

    // DISABLED (threshold 0 = the default/OFF): never pauses no matter how long the client is silent —
    // the byte-identical contract (the capturer is never told to pause).
    func testDisabledNeverPauses() {
        for silent in [0.0, 5.0, 12.0, 60.0, 3600.0] {
            XCTAssertFalse(pause(silentFor: silent, threshold: 0), "threshold 0 must never pause (silent \(silent)s)")
            XCTAssertFalse(pause(silentFor: silent, threshold: -5), "negative threshold must never pause")
        }
    }

    // UNPROVEN client (never sent feedback): never pauses even long past the threshold — a legacy
    // client that never reports must not be paused (the reaper's safety rule).
    func testUnprovenClientNeverPauses() {
        XCTAssertFalse(pause(silentFor: 100, sawFeedback: false), "an unproven client must never pause")
    }

    // Below the threshold: a proven client that reported recently keeps streaming.
    func testBelowThresholdKeepsStreaming() {
        XCTAssertFalse(pause(silentFor: 0))
        XCTAssertFalse(pause(silentFor: 11.9, threshold: 12))
    }

    // At / above the threshold: a proven, silent client pauses (>= boundary — exactly at threshold
    // pauses, the fail-toward-stop-wasting edge).
    func testAtOrAboveThresholdPauses() {
        XCTAssertTrue(pause(silentFor: 12.0, threshold: 12), "exactly at threshold must pause")
        XCTAssertTrue(pause(silentFor: 30.0, threshold: 12))
    }

    // The whole point: identical (silent, proven) input flips ONLY on the threshold — proving the
    // decision is the silence-vs-threshold comparison and nothing else.
    func testThresholdIsTheOnlyLever() {
        XCTAssertFalse(pause(silentFor: 8, threshold: 10), "8s silent under a 10s threshold keeps streaming")
        XCTAssertTrue(pause(silentFor: 8, threshold: 6), "8s silent past a 6s threshold pauses")
    }
}
#endif
