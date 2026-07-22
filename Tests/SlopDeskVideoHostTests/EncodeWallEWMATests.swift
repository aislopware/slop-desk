#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// PURE encode-wall EWMA fold (``WindowCapturer/foldEncodeEWMA(current:sampleMs:)``) — the stats
/// HUD's host encode axis (wire type 27 `hostStats`). No ScreenCaptureKit / VideoToolbox — just
/// the fold arithmetic, so it is headless-safe. First sample seeds the average whole (no zero-drag
/// warmup); later samples fold at the ``EncodeLoadPacer/alpha`` weight.
final class EncodeWallEWMATests: XCTestCase {
    func testFirstSampleSeedsWhole() {
        XCTAssertEqual(WindowCapturer.foldEncodeEWMA(current: 0, sampleMs: 3.5), 3.5)
    }

    func testFoldsAtPacerAlpha() {
        let alpha = EncodeLoadPacer.alpha
        let folded = WindowCapturer.foldEncodeEWMA(current: 8.0, sampleMs: 4.0)
        XCTAssertEqual(folded, 8.0 * (1 - alpha) + 4.0 * alpha, "EWMA at the pacer alpha")
        XCTAssertLessThan(folded, 8.0, "moves toward the sample")
        XCTAssertGreaterThan(folded, 4.0, "but keeps memory")
    }

    /// An IDR spike decays instead of latching — the HUD reports a spiky-but-recovering encode as
    /// recovering (fold three steady samples after one 30 ms spike and the EWMA is back near steady).
    func testSpikeDecays() {
        var ewma = WindowCapturer.foldEncodeEWMA(current: 4.0, sampleMs: 30.0)
        XCTAssertGreaterThan(ewma, 4.0)
        for _ in 0..<6 { ewma = WindowCapturer.foldEncodeEWMA(current: ewma, sampleMs: 4.0) }
        XCTAssertLessThan(ewma, 6.0, "six steady folds pull a 30 ms spike back under 6 ms")
    }
}
#endif
