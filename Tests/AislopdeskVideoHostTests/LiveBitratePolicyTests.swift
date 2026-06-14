#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// PURE resolution-aware live-bitrate math (2026-06-08 scroll-smoothness fix). The encoder it feeds
/// is HW-gated and never instantiated in a test; this covers the arithmetic that decides the live
/// `AverageBitRate`/`DataRateLimits` so the 2× HiDPI window is provisioned proportionally (a flat
/// 1080p-tuned cap starved scroll frames → drops → stutter).
final class LiveBitratePolicyTests: XCTestCase {
    // 1080p60: resolution-derived budget (1920·1080·60·0.15) wins over the 12 Mbps floor.
    func testStandard1080pScalesAboveFloor() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 1920, pixelHeight: 1080, fps: 60, floor: 12_000_000)
        XCTAssertEqual(b, 18_662_400)
    }

    // 2× HiDPI window (2816×1778 = a 1408×889-pt window at captureScale 2): ~45 Mbps, NOT starved.
    func testTwoXHiDPIWindowGetsFullBudget() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 2816, pixelHeight: 1778, fps: 60, floor: 12_000_000)
        XCTAssertEqual(b, 45_061_632)
    }

    // The whole point of the fix: doubling captureScale (→ 4× the pixels) QUADRUPLES the budget,
    // so the 2× stream is no longer starved at the 1×-tuned cap.
    func testQuadruplesWithTwoXScale() {
        let oneX = LiveBitratePolicy.targetBitrate(pixelWidth: 1408, pixelHeight: 889, fps: 60, floor: 0)
        let twoX = LiveBitratePolicy.targetBitrate(pixelWidth: 2816, pixelHeight: 1778, fps: 60, floor: 0)
        XCTAssertEqual(twoX, oneX * 4)
    }

    // A tiny window must not starve below the configured floor.
    func testFloorHonouredForSmallWindow() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 320, pixelHeight: 240, fps: 60, floor: 12_000_000)
        XCTAssertEqual(b, 12_000_000)
    }

    // An explicit HIGHER --bitrate is honoured even when the resolution formula asks for less.
    func testExplicitHigherFloorWins() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 1920, pixelHeight: 1080, fps: 60, floor: 60_000_000)
        XCTAssertEqual(b, 60_000_000)
    }

    // With no floor, a tiny window still clamps up to the 1 Mbps sanity minimum (never 0).
    func testMinimumBitrateFloor() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 64, pixelHeight: 64, fps: 60, floor: 0)
        XCTAssertEqual(b, LiveBitratePolicy.minimumBitrate)
    }

    // Degenerate dimensions/fps are clamped to 1 — never a crash or a zero/negative budget.
    func testDegenerateInputsClampSafely() {
        let b = LiveBitratePolicy.targetBitrate(pixelWidth: 0, pixelHeight: -10, fps: 0, floor: 0)
        XCTAssertEqual(b, LiveBitratePolicy.minimumBitrate)
    }

    // fps participates linearly (a 30fps cap halves the budget vs 60).
    func testFpsScalesLinearly() {
        let at60 = LiveBitratePolicy.targetBitrate(pixelWidth: 3840, pixelHeight: 2160, fps: 60, floor: 0)
        let at30 = LiveBitratePolicy.targetBitrate(pixelWidth: 3840, pixelHeight: 2160, fps: 30, floor: 0)
        XCTAssertEqual(at60, at30 * 2)
    }
}
#endif
