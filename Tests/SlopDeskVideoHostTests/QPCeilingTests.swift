#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
import XCTest
@testable import SlopDeskVideoHost

/// The budget-adaptive `MaxAllowedFrameQP` ceiling
/// (``VideoEncoder/qpCeiling(forTargetBps:pixelWidth:pixelHeight:fps:sharp:coarse:sharpBpp:coarseBpp:)``).
/// Pins the sharp↔coarse mapping HW-calibrated on 2026-07-21: a pinned QP-38 under a thin ABR target
/// produced 97 VT `frameDropped` in one 18s scroll (target 6–16 Mbps @1080p60, bpp 0.05–0.13), while
/// QP-38 under a 31 Mbps ceiling (bpp ≥0.14) dropped zero — so the ceiling must be sharp exactly when
/// the density affords it and relax to the coarsen-don't-drop bound when it doesn't.
final class QPCeilingTests: XCTestCase {
    private func ceiling(_ targetBps: Int, w: Int = 1920, h: Int = 1080, fps: Int = 60) -> Int {
        VideoEncoder.qpCeiling(
            forTargetBps: targetBps,
            pixelWidth: w,
            pixelHeight: h,
            fps: fps,
            sharp: 38,
            coarse: 51,
            sharpBpp: 0.14,
            coarseBpp: 0.07,
        )
    }

    // Healthy budget (bpp ≥ 0.14) ⇒ sharp 38. 31.1 Mbps @1080p60 = bpp 0.25 (the shipped
    // LiveBitratePolicy ceiling); 17.4 Mbps = bpp 0.14 exactly (boundary is sharp).
    func testHealthyBudgetIsSharp() {
        XCTAssertEqual(ceiling(31_104_000), 38)
        XCTAssertEqual(ceiling(17_418_240), 38) // 1920·1080·60·0.14 exactly
    }

    // Thin budget (bpp ≤ 0.07) ⇒ fully relaxed 51 (coarsen-don't-drop). 6.5 Mbps @1080p60 = bpp
    // 0.052 — the measured drop-storm regime.
    func testThinBudgetFullyRelaxes() {
        XCTAssertEqual(ceiling(6_500_000), 51)
        XCTAssertEqual(ceiling(8_709_120), 51) // 1920·1080·60·0.07 exactly (boundary is coarse)
        XCTAssertEqual(ceiling(1_000_000), 51)
    }

    // Between the knees the ceiling interpolates linearly (round half-away): bpp 0.12 ⇒
    // t = 0.02/0.07 ⇒ 38 + 13·0.2857… = 41.7 ⇒ 42; bpp 0.10 ⇒ 38 + 13·0.5714… = 45.4 ⇒ 45.
    func testInterpolatesBetweenKnees() {
        XCTAssertEqual(ceiling(14_929_920), 42) // 1920·1080·60·0.12
        XCTAssertEqual(ceiling(12_441_600), 45) // 1920·1080·60·0.10
        // Monotone: a thinner budget never yields a SHARPER (lower) ceiling.
        let samples = [17_418_240, 14_929_920, 12_441_600, 11_000_000, 8_709_120]
        let qps = samples.map { ceiling($0) }
        XCTAssertEqual(qps, qps.sorted())
    }

    // Degenerate inputs (zero/negative dims, fps, target; inverted knees) ⇒ coarse — never risk a
    // drop on a malformed config.
    func testDegenerateInputsRelax() {
        XCTAssertEqual(ceiling(12_000_000, w: 0), 51)
        XCTAssertEqual(ceiling(12_000_000, h: -1), 51)
        XCTAssertEqual(ceiling(12_000_000, fps: 0), 51)
        XCTAssertEqual(ceiling(0), 51)
        XCTAssertEqual(
            VideoEncoder.qpCeiling(
                forTargetBps: 12_000_000,
                pixelWidth: 1920,
                pixelHeight: 1080,
                fps: 60,
                sharp: 38,
                coarse: 51,
                sharpBpp: 0.07,
                coarseBpp: 0.14, // inverted knees
            ),
            51,
        )
    }

    // A pinned static ceiling (sharp == coarse, the SLOPDESK_MAX_QP path shape) is honoured verbatim
    // at every density.
    func testPinnedStaticShapeHonoured() {
        for target in [1_000_000, 13_063_680, 31_104_000] {
            XCTAssertEqual(
                VideoEncoder.qpCeiling(
                    forTargetBps: target,
                    pixelWidth: 1920,
                    pixelHeight: 1080,
                    fps: 60,
                    sharp: 40,
                    coarse: 40,
                    sharpBpp: 0.14,
                    coarseBpp: 0.07,
                ),
                40,
            )
        }
    }
}

/// Drop-feedback relief (``VideoEncoder/QPDropRelief``) — the content-complexity escape valve for
/// the budget-adaptive ceiling. Pins the HW-calibrated failure it exists for: a rich budget (bpp
/// 0.21–0.24 ⇒ sharp 38) on mandelbrot-class content (offered ≈95–119 Mbps vs a 30 Mbps target)
/// produced 209 VT drops in 25s because QP-38 physically cannot fit noise into the budget — the
/// relief must attack toward 51 within a few dropped frames and only re-sharpen gradually.
final class QPDropReliefTests: XCTestCase {
    // One drop attacks +attackStep immediately; a 4-drop storm saturates within ~4 frames.
    func testDropAttacksImmediately() {
        var r = VideoEncoder.QPDropRelief()
        XCTAssertEqual(r.fold(drops: 1), VideoEncoder.QPDropRelief.attackStep)
        XCTAssertEqual(r.fold(drops: 1), VideoEncoder.QPDropRelief.attackStep * 2)
        var storm = VideoEncoder.QPDropRelief()
        for _ in 0..<4 { _ = storm.fold(drops: 1) }
        XCTAssertGreaterThanOrEqual(storm.relief, 13, "a storm must reach the full 38→51 span fast")
    }

    // Relief is capped — a pathological drop flood can't overflow past the composition clamp's input.
    func testReliefSaturates() {
        var r = VideoEncoder.QPDropRelief()
        for _ in 0..<100 { _ = r.fold(drops: 10) }
        XCTAssertEqual(r.relief, 51)
    }

    // No decay during the hold window: relief is sticky while the regime may still be bursty.
    func testNoDecayBeforeHold() {
        var r = VideoEncoder.QPDropRelief()
        _ = r.fold(drops: 1)
        for _ in 0..<VideoEncoder.QPDropRelief.holdFrames { _ = r.fold(drops: 0) }
        XCTAssertEqual(r.relief, VideoEncoder.QPDropRelief.attackStep, "hold window must not decay")
    }

    // After the hold, relief decays 1 QP per decayEvery clean frames — gradual re-sharpen, no pop.
    func testDecaysGraduallyAfterHold() {
        var r = VideoEncoder.QPDropRelief()
        _ = r.fold(drops: 1) // relief = 4
        let framesToFullDecay = VideoEncoder.QPDropRelief.holdFrames
            + VideoEncoder.QPDropRelief.attackStep * VideoEncoder.QPDropRelief.decayEvery
        for _ in 0..<framesToFullDecay { _ = r.fold(drops: 0) }
        XCTAssertEqual(r.relief, 0, "relief fully decays after hold + span·decayEvery clean frames")
    }

    // A drop mid-decay re-arms: attack from the current level and the hold restarts.
    func testDropMidDecayReArms() {
        var r = VideoEncoder.QPDropRelief()
        _ = r.fold(drops: 1)
        for _ in 0..<(VideoEncoder.QPDropRelief.holdFrames + VideoEncoder.QPDropRelief.decayEvery) {
            _ = r.fold(drops: 0)
        }
        XCTAssertEqual(r.relief, VideoEncoder.QPDropRelief.attackStep - 1, "one decay step landed")
        _ = r.fold(drops: 1)
        XCTAssertEqual(r.relief, VideoEncoder.QPDropRelief.attackStep * 2 - 1)
        XCTAssertEqual(r.cleanFrames, 0, "hold restarts on a new drop")
    }
}
#endif
