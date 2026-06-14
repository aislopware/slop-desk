#if canImport(VideoToolbox) && canImport(ScreenCaptureKit)
import XCTest
@testable import AislopdeskVideoHost

/// RC-2 (2026-06-09): the rate-proportional send-pacing gap. The fixed 0.5ms gap drained a chunk
/// ~13× faster than a 12Mbps link → self-inflicted burst loss. This verifies the pure gap math:
/// gap = chunkBytes×8 / targetBps, clamped — so a chunk drains at ≈ the live link rate.
final class AdaptivePaceGapTests: XCTestCase {
    // 8 fragments × 1200 bytes = 9600 bytes = 76,800 bits per chunk.
    private let chunkFragments = 8
    private let datagramSize = 1200
    private let floor: UInt64 = 200_000 // 0.2ms
    private let ceil: UInt64 = 40_000_000 // 40ms

    private func gap(_ bps: Int) -> UInt64 {
        AislopdeskVideoHostSession.adaptivePaceGapNanos(
            targetBps: bps, fallbackBps: 12_000_000,
            chunkFragments: chunkFragments, datagramSize: datagramSize,
            floorNanos: floor, ceilNanos: ceil,
        )
    }

    func testTwelveMbpsGivesAboutSixPointFourMs() {
        // 76,800 bits / 12,000,000 bps = 6.4ms — the correct link-rate gap (vs the old 0.5ms burst).
        XCTAssertEqual(Double(gap(12_000_000)) / 1_000_000.0, 6.4, accuracy: 0.1)
    }

    func testHigherBitrateShrinksTheGap() {
        // 48Mbps → 1.6ms; still well above the 0.2ms floor and far below the old fixed gap's burst risk.
        XCTAssertEqual(Double(gap(48_000_000)) / 1_000_000.0, 1.6, accuracy: 0.1)
        // Monotonic: more bandwidth ⇒ shorter gap ⇒ faster (safe) send.
        XCTAssertLessThan(gap(48_000_000), gap(12_000_000))
        XCTAssertLessThan(gap(12_000_000), gap(3_000_000))
    }

    func testCollapsedFloorIsClampedNotUnbounded() {
        // 3Mbps → 25.6ms; under the 40ms ceiling (a frame still serializes in bounded time).
        XCTAssertEqual(Double(gap(3_000_000)) / 1_000_000.0, 25.6, accuracy: 0.2)
        // A pathologically tiny target must not stall a frame for seconds — clamp at the ceiling.
        XCTAssertEqual(gap(1), ceil)
    }

    func testZeroOrNegativeTargetUsesFallback() {
        // ABR off / pre-warmup (targetBps == 0) ⇒ the 12Mbps fallback, NOT a divide-by-zero / huge gap.
        XCTAssertEqual(gap(0), gap(12_000_000))
        XCTAssertEqual(gap(-5), gap(12_000_000))
    }

    func testFloorClampOnVeryHighBitrate() {
        // 1Gbps → 0.0768ms < 0.2ms floor ⇒ clamped to the floor (never pace absurdly fast).
        XCTAssertEqual(gap(1_000_000_000), floor)
    }

    // MARK: Rate multiplier (2026-06-10 — pace at k× the live rate, not exact rate)

    private func gapX(_ bps: Int, _ k: Double) -> UInt64 {
        AislopdeskVideoHostSession.adaptivePaceGapNanos(
            targetBps: bps, fallbackBps: 12_000_000,
            chunkFragments: chunkFragments, datagramSize: datagramSize,
            floorNanos: floor, ceilNanos: ceil, rateMultiplier: k,
        )
    }

    func testMultiplierScalesTheGapDown() {
        // k=2.5 at 40Mbps: 76,800 bits / 100Mbps = 0.768ms — a 133KB frame (14 chunks) drains in
        // ~10ms instead of ~27ms at k=1, while the burst stays 2.5× sustained (Wi-Fi-gentle).
        XCTAssertEqual(Double(gapX(40_000_000, 2.5)) / 1_000_000.0, 0.768, accuracy: 0.01)
        // Default-parameter call (k omitted) == k=1 — the pre-existing tests above stay valid.
        XCTAssertEqual(gap(40_000_000), gapX(40_000_000, 1.0))
    }

    func testMultiplierNeverSpeedsBelowOneAndSurvivesJunk() {
        // k<1 is clamped to 1 (the multiplier only relaxes serialization, never slows the send
        // below the link rate), and non-finite k degrades to 1 rather than corrupting the gap.
        XCTAssertEqual(gapX(12_000_000, 0.5), gap(12_000_000))
        XCTAssertEqual(gapX(12_000_000, .nan), gap(12_000_000))
        XCTAssertEqual(gapX(12_000_000, .infinity), gap(12_000_000))
    }
}
#endif
