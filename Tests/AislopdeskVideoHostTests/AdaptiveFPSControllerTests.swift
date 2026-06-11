import XCTest
@testable import AislopdeskVideoHost

/// CONTENT-ADAPTIVE FPS (2026-06-09): verifies the pure skip decision that drops fps under heavy motion
/// so a full-screen scroll fits the ~12Mbps link. budget = link/8/fps (per-frame budget at full fps).
final class AdaptiveFPSControllerTests: XCTestCase {
    private let budget = 25_000   // ≈ 12Mbps / 8 / 60fps

    func testUnderBudgetNeverSkips() {
        // Light motion / static (frame ≤ budget) ⇒ full fps, never skip.
        XCTAssertFalse(AdaptiveFPSController.decide(enabled: true, isForcedFrame: false,
            lastEncodedBytes: 5_000, budgetBytes: budget, skippedPrevious: false))
        XCTAssertFalse(AdaptiveFPSController.decide(enabled: true, isForcedFrame: false,
            lastEncodedBytes: budget, budgetBytes: budget, skippedPrevious: false))
    }

    func testOverBudgetSkipsNext() {
        // Heavy motion (frame > budget) and we didn't just skip ⇒ skip this capture.
        XCTAssertTrue(AdaptiveFPSController.decide(enabled: true, isForcedFrame: false,
            lastEncodedBytes: 137_000, budgetBytes: budget, skippedPrevious: false))
    }

    func testNeverSkipsTwoInARow() {
        // One-in-a-row cap ⇒ rate floors at fps/2 (≈30fps), not lower — even under sustained heavy motion.
        XCTAssertFalse(AdaptiveFPSController.decide(enabled: true, isForcedFrame: false,
            lastEncodedBytes: 137_000, budgetBytes: budget, skippedPrevious: true))
    }

    func testForcedFrameNeverSkips() {
        // Keyframe / crisp / compact / LTR-refresh must always ship (recovery/heartbeat), even when huge.
        XCTAssertFalse(AdaptiveFPSController.decide(enabled: true, isForcedFrame: true,
            lastEncodedBytes: 200_000, budgetBytes: budget, skippedPrevious: false))
    }

    func testDisabledNeverSkips() {
        // AISLOPDESK_ADAPTIVE_FPS=0 ⇒ byte-identical to full fps.
        XCTAssertFalse(AdaptiveFPSController.decide(enabled: false, isForcedFrame: false,
            lastEncodedBytes: 200_000, budgetBytes: budget, skippedPrevious: false))
    }

    func testInstanceAlternatesUnderSustainedMotion() {
        // End-to-end through the instance: sustained big frames ⇒ skip, encode, skip, encode = ~30fps.
        let c = AdaptiveFPSController(budgetBytes: budget, enabled: true)
        c.noteEncoded(bytes: 137_000)
        XCTAssertTrue(c.shouldSkip(isForcedFrame: false), "big frame ⇒ skip next")
        XCTAssertFalse(c.shouldSkip(isForcedFrame: false), "just skipped ⇒ encode (no 2-in-a-row)")
        c.noteEncoded(bytes: 137_000)
        XCTAssertTrue(c.shouldSkip(isForcedFrame: false), "still heavy ⇒ skip again")
        // Motion stops: small frame ⇒ back to full fps.
        c.noteEncoded(bytes: 4_000)
        XCTAssertFalse(c.shouldSkip(isForcedFrame: false), "light ⇒ full fps")
    }
}
