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
    func testPinnedStaticShape() {
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
#endif
