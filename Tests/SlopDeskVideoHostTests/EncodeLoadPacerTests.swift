import XCTest
@testable import SlopDeskVideoHost

/// ENCODE-LOAD PACER: the compute-axis twin of the FPS governor. Pure value type — reuses the
/// governor's clean-divisor ladder, folds encode wall-time into an EWMA, and steps the effective
/// fps down/up so the schedule-anchored `EncodeCadenceGate` decimates METRONOME-REGULARLY when the
/// HW encoder (not the link) is the bottleneck. All tests assume the default constants
/// (alpha 0.25, downFraction 0.85, upFraction 0.90, downTicks 3, upTicks 45, warmup 8).
///
/// Thresholds used below (budgetMs = 1000/fps):
///   • at 60 fps: budget 16.67 ms, step-down when EWMA > 14.17 ms (× 0.85)
///   • at 30 fps: budget 33.33 ms, step-down when EWMA > 28.33 ms
///   • step-up 30→60: EWMA < budget(60) × 0.90 = 15.0 ms
final class EncodeLoadPacerTests: XCTestCase {
    /// The pacer shares the governor's exact divisor ladder — so both controllers actuate on the
    /// same metronome-regular rungs (2/3/4-slot multiples of the 16.7 ms grid).
    func testLadderReusesGovernorDivisors() {
        XCTAssertEqual(EncodeLoadPacer(baseFps: 60).ladder, [60, 30, 20, 15])
        XCTAssertEqual(EncodeLoadPacer(baseFps: 30).ladder, [30, 15])
        XCTAssertEqual(EncodeLoadPacer(baseFps: 60).currentFps, 60, "starts at the top rung")
    }

    /// No step inside the warmup window even when every sample is over budget (cold-start guard).
    func testNoStepDuringWarmup() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<(EncodeLoadPacer.warmupTicks - 1) {
            XCTAssertEqual(pacer.note(encodeMs: 30, isAnchor: false), 60)
        }
        XCTAssertEqual(pacer.currentFps, 60, "warmup blocks action even with clear over-run evidence")
    }

    /// The core FIX behaviour: a sustained encode over-run (20 ms > 14.17 ms budget-fraction at
    /// 60 fps) steps the paced fps down ONE clean divisor — so the cadence gate decimates to a
    /// metronome-regular 30 fps instead of the ragged backlog drop.
    func testSustainedOverRunStepsDown60to30() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        // 8 warmup ticks + 3 over-budget ticks (downTicks) ⇒ step on the 11th sample.
        for _ in 0..<10 { _ = pacer.note(encodeMs: 20, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 30, "sustained 20 ms encodes over-run the 16.7 ms budget ⇒ pace to 30")
    }

    /// A stream the encoder KEEPS UP with is never touched — 9 ms encodes stay well under the
    /// 14.17 ms step-down fraction, so the pacer holds the base rate (no gratuitous fps loss).
    func testLightLoadNeverStepsDown() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<50 { _ = pacer.note(encodeMs: 9, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 60, "encoder comfortably under budget ⇒ untouched 60 fps")
        XCTAssertEqual(pacer.overRun, 0)
    }

    /// ANCHOR frames (keyframe/crisp) are episodic 5–10× encode-time outliers — excluded from the
    /// EWMA and the tick count, so a recovery IDR can never fake a step-down.
    func testAnchorFramesExcluded() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<20 { _ = pacer.note(encodeMs: 200, isAnchor: true) } // huge IDRs, all ignored
        XCTAssertEqual(pacer.currentFps, 60, "anchors never step the pacer")
        XCTAssertEqual(pacer.encodeMsEWMA, 0, "anchors never seed the EWMA")
        XCTAssertEqual(pacer.ticks, 0, "anchors do not advance the folded-frame clock")
    }

    /// Once motion lightens (encodes fit the higher rung's budget with margin) the pacer steps back
    /// UP — but slowly (a cadence change is visible), gated on `upTicks` sustained headroom.
    func testHeadroomStepsBackUp30to60() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<10 { _ = pacer.note(encodeMs: 20, isAnchor: false) } // pace down to 30 first
        XCTAssertEqual(pacer.currentFps, 30)
        // 12 ms < 15 ms (budget(60) × 0.90): sustained headroom for the tighter 60 fps budget.
        for _ in 0..<60 { _ = pacer.note(encodeMs: 12, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 60, "sustained headroom restores the base rate")
    }

    /// Headroom that is NOT quite enough for the higher rung keeps the pacer down (biased-safe):
    /// 16 ms > 15 ms step-up fraction, so 30 fps holds rather than flapping back to an over-run 60.
    func testBorderlineHeadroomHoldsRung() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<10 { _ = pacer.note(encodeMs: 20, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 30)
        for _ in 0..<80 { _ = pacer.note(encodeMs: 16, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 30, "16 ms does not fit the 60 fps budget-fraction ⇒ stay at 30")
    }

    /// Extreme sustained load cascades down multiple rungs but never below the ladder floor (15).
    func testExtremeLoadCascadesToFloor() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<80 { _ = pacer.note(encodeMs: 100, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 15, "100 ms encodes cascade 60→30→20→15 and stop at the floor")
    }

    /// A mid-load level settles at the rung whose budget it fits: 40 ms over-runs 60 and 30 but
    /// fits 20 (budget 50 ms), so the pacer parks at 20 without oscillating to 15.
    func testMidLoadSettlesAtFittingRung() {
        var pacer = EncodeLoadPacer(baseFps: 60)
        for _ in 0..<40 { _ = pacer.note(encodeMs: 40, isAnchor: false) }
        XCTAssertEqual(pacer.currentFps, 20, "40 ms fits the 20 fps budget (50 ms) ⇒ settle there")
    }
}
