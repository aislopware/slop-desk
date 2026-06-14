#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// WF-5 (#5) PURE VBV-window math. The encoder it feeds is HW-gated and never instantiated here; this
/// covers the arithmetic that builds `DataRateLimits = [maxBytes, seconds]` so every set-site stays
/// consistent and the default path (T=1.0) is byte-identical to before the tunable window landed.
final class VBVWindowTests: XCTestCase {
    // MARK: resolveVBVWindow (env parse + clamp)

    func testDefaultWhenEnvMissing() {
        XCTAssertEqual(VideoEncoder.resolveVBVWindow(nil), 1.0)
    }

    func testParsesValidWindow() {
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("0.5"), 0.5)
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("2.0"), 2.0)
    }

    func testClampsBadValueToDefault() {
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("0"), 1.0) // below 0.01 lower bound
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("-1"), 1.0) // negative → default
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("99"), 1.0) // above 4.0 upper bound
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("garbage"), 1.0) // unparseable → default
        XCTAssertEqual(VideoEncoder.resolveVBVWindow(""), 1.0)
    }

    func testBoundaryValuesAccepted() {
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("0.01"), 0.01)
        XCTAssertEqual(VideoEncoder.resolveVBVWindow("4.0"), 4.0)
    }

    // MARK: vbvComponents (budget scaling — preserves the AVERAGE rate)

    // T=1.0 IDENTITY: the default path must return exactly (bytesPerSecond, 1.0).
    func testIdentityAtUnitWindow() {
        let c = VideoEncoder.vbvComponents(bytesPerSecond: 1_500_000, seconds: 1.0)
        XCTAssertEqual(c.maxBytes, 1_500_000)
        XCTAssertEqual(c.seconds, 1.0)
    }

    // A TIGHTER window scales the budget DOWN proportionally → average rate unchanged.
    func testTightWindowScalesBudget() {
        let c = VideoEncoder.vbvComponents(bytesPerSecond: 1_500_000, seconds: 0.5)
        XCTAssertEqual(c.maxBytes, 750_000) // 1.5MB/s * 0.5s = 0.75MB cap, still 12 Mbps average
        XCTAssertEqual(c.seconds, 0.5)
    }

    // A WIDER window scales the budget UP proportionally → average rate still unchanged.
    func testWideWindowScalesBudget() {
        let c = VideoEncoder.vbvComponents(bytesPerSecond: 1_500_000, seconds: 2.0)
        XCTAssertEqual(c.maxBytes, 3_000_000)
        XCTAssertEqual(c.seconds, 2.0)
    }

    // The crisp one-shot budget (64 Mbit ≡ 8 MB/s) scales by T just like the live budget.
    func testCrispBudgetScales() {
        let c = VideoEncoder.vbvComponents(bytesPerSecond: VideoEncoder.crispDataRateMaxBytes, seconds: 0.25)
        XCTAssertEqual(c.maxBytes, 2_000_000) // 8MB/s * 0.25s
        XCTAssertEqual(c.seconds, 0.25)
    }

    // Average rate (maxBytes / seconds) is INVARIANT across windows — the property that matters.
    func testAverageRateInvariantAcrossWindows() {
        let budget = 5_000_000
        for t in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0] {
            let c = VideoEncoder.vbvComponents(bytesPerSecond: budget, seconds: t)
            XCTAssertEqual(
                Double(c.maxBytes) / c.seconds,
                Double(budget),
                accuracy: 1.0,
                "average rate must stay \(budget) B/s at window \(t)",
            )
        }
    }

    // MARK: dataRateLimits CFArray bridge (default-path byte identity)

    // 2026-06-11 defaults consolidation: PURE VBR is the default (`AISLOPDESK_PURE_VBR` unset ⇒ the
    // hard cap never binds — VT's DataRateLimits enforcement silently DROPS frames over the
    // window budget, the R7-HW-measured khựng factory). The bridged CFArray keeps the exact
    // [bytes (Int), seconds (Double)] shape; the byte element is the unbound sentinel regardless
    // of the requested rate (AverageBitRate alone steers — the Parsec rate-control model).
    func testDataRateLimitsDefaultIsPureVBRUnbound() {
        XCTAssertEqual(VideoEncoder.vbvWindowSeconds, 1.0, "test env must not set AISLOPDESK_VBV_WINDOW")
        guard let arr = VideoEncoder.dataRateLimits(bytesPerSecond: 1_500_000) as? [Any] else {
            XCTFail("dataRateLimits must bridge to an array")
            return
        }
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0] as? Int, 1_000_000_000, "default = pure VBR: the hard cap must never bind")
        XCTAssertEqual(arr[1] as? Double, 1.0)
    }
}
#endif
