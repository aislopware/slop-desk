import XCTest
@testable import AislopdeskVideoClient

/// PURE adaptive jitter-buffer depth controller. Deterministic (the caller folds each
/// decoded-frame's smoothed jitter — no clock inside), so the grow-fast / shrink-slow /
/// hysteresis / clamp behaviour is fully unit-testable in isolation.
final class AdaptiveJitterControllerTests: XCTestCase {

    func testStableLowJitterSettlesToFloor() {
        // initialDepth 3, but a perfectly clean link (jitter 0) ⇒ recommendation = minDepth(1).
        // Shrink is slow: one step per shrinkCooldownFrames, so it takes 2 cooldown windows to
        // walk 3 → 2 → 1 and then it holds at the floor.
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: 60, initialDepth: 3, shrinkCooldownFrames: 4)
        // First 3 low-jitter frames: under cooldown (4), no shrink yet.
        for _ in 0 ..< 3 { XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 3) }
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 2, "4th consecutive low frame ⇒ one-step shrink")
        for _ in 0 ..< 3 { XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 2, "next window not yet elapsed") }
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 1, "another cooldown ⇒ shrink to floor")
        // Settles: at the floor the recommendation == targetDepth, so it never drops below 1.
        for _ in 0 ..< 20 { XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 1, "holds at the floor") }
    }

    func testJitterRiseGrowsImmediately() {
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: 60, initialDepth: 1, shrinkCooldownFrames: 180)
        // 20 ms jitter at 60fps × 2.5 safety ⇒ ceil(0.02·60·2.5)=ceil(3)=3 ⇒ depth 1+3 = 4, in ONE step.
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0.02), 4, "a jitter spike grows the depth in a single frame")
        XCTAssertEqual(c.targetDepth, 4)
    }

    func testSustainedLowAfterGrowShrinksSlowlyOneStepAtATime() {
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: 60, initialDepth: 1, shrinkCooldownFrames: 3)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0.02), 4, "grow to 4")
        // Now feed clean frames: depth must HOLD for shrinkCooldownFrames-1, then drop by exactly 1.
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 3, "3 consecutive low frames ⇒ exactly one step down")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 3)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 3)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 2, "another window ⇒ one more step")
    }

    func testGrowResetsShrinkCooldownNoThrash() {
        // Hysteresis: a low frame that bumps the shrink counter must be reset by an intervening
        // grow, so a near-boundary link cannot oscillate down on the very next clean frame.
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: 60, initialDepth: 4, shrinkCooldownFrames: 3)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4, "low: shrinkRun 1")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4, "low: shrinkRun 2")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0.02), 4, "a spike re-arms cooldown (already at 4, resets shrinkRun)")
        // The next low frame is shrinkRun 1 again, not 3 ⇒ no shrink.
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4, "cooldown restarted ⇒ no immediate shrink")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 3, "only now (3 clean in a row) does it step down")
    }

    func testUnderrunBumpsImmediatelyAndCapsAtMaxDepth() {
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 3, fps: 60, initialDepth: 1, shrinkCooldownFrames: 180)
        XCTAssertEqual(c.noteUnderrun(), 2, "underrun grows by one immediately")
        XCTAssertEqual(c.noteUnderrun(), 3)
        XCTAssertEqual(c.noteUnderrun(), 3, "clamped at maxDepth")
        XCTAssertEqual(c.targetDepth, 3)
    }

    func testUnderrunResetsShrinkCooldown() {
        // An underrun-driven +1 must not be undone by the very next low-jitter frame.
        var c = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: 60, initialDepth: 4, shrinkCooldownFrames: 2)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4, "shrinkRun 1")
        XCTAssertEqual(c.noteUnderrun(), 5, "grow + reset cooldown")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 5, "shrinkRun 1 (reset), no shrink")
        XCTAssertEqual(c.noteFrame(jitterSeconds: 0), 4, "now 2 consecutive low ⇒ one step")
    }

    func testClampsToMinAndMaxDepth() {
        // A huge jitter cannot exceed maxDepth; a zero jitter cannot drop below minDepth.
        var c = AdaptiveJitterController(minDepth: 2, maxDepth: 5, fps: 60, initialDepth: 2, shrinkCooldownFrames: 1)
        XCTAssertEqual(c.noteFrame(jitterSeconds: 10.0), 5, "absurd jitter clamps to maxDepth")
        // shrinkCooldownFrames 1 ⇒ each low frame steps down, but never below minDepth(2).
        for _ in 0 ..< 10 { _ = c.noteFrame(jitterSeconds: 0) }
        XCTAssertEqual(c.targetDepth, 2, "never shrinks below minDepth")
    }

    func testInitClampsInitialDepthIntoRange() {
        let lo = AdaptiveJitterController(minDepth: 2, maxDepth: 6, fps: 60, initialDepth: 0)
        XCTAssertEqual(lo.targetDepth, 2, "initialDepth below floor clamps up")
        let hi = AdaptiveJitterController(minDepth: 1, maxDepth: 4, fps: 60, initialDepth: 99)
        XCTAssertEqual(hi.targetDepth, 4, "initialDepth above ceiling clamps down")
    }
}
