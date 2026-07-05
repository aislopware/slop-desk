import XCTest
@testable import SlopDeskWorkspaceCore

/// C7 improvement 1 — the pure link-health formatting + threshold model behind the remote-GUI footer's
/// RTT/loss indicator. Headless (no view / session).
final class LinkHealthTests: XCTestCase {
    private func sample(rtt: Double = 20, loss: Double = 0, recovered: Int = 0) -> LinkHealth.Sample {
        LinkHealth.Sample(rttMillis: rtt, lossPct: loss, recovered: recovered)
    }

    func testGradeGoodWhenLowRttNoLoss() {
        XCTAssertEqual(LinkHealth.grade(sample(rtt: 20, loss: 0)), .good)
    }

    func testGradeDegradedByLossThenBadByLoss() {
        XCTAssertEqual(LinkHealth.grade(sample(loss: LinkHealth.degradedLossPct)), .degraded)
        XCTAssertEqual(LinkHealth.grade(sample(loss: LinkHealth.badLossPct)), .bad)
    }

    func testGradeDegradedByRttThenBadByRtt() {
        XCTAssertEqual(LinkHealth.grade(sample(rtt: LinkHealth.degradedRttMillis, loss: 0)), .degraded)
        XCTAssertEqual(LinkHealth.grade(sample(rtt: LinkHealth.badRttMillis, loss: 0)), .bad)
    }

    /// The WORSE axis wins: low RTT but heavy loss is still bad.
    func testGradeTakesTheWorseAxis() {
        XCTAssertEqual(LinkHealth.grade(sample(rtt: 5, loss: 12)), .bad)
        XCTAssertEqual(LinkHealth.grade(sample(rtt: 300, loss: 0)), .bad)
    }

    /// A NaN / negative reading is treated as 0 (good), never a mis-grade.
    func testGradeSanitizesGarbageToGood() {
        XCTAssertEqual(LinkHealth.grade(sample(rtt: .nan, loss: -5)), .good)
    }

    func testRttLabelRoundsAndFormats() {
        XCTAssertEqual(LinkHealth.rttLabel(23.4), "23ms")
        XCTAssertEqual(LinkHealth.rttLabel(22.6), "23ms")
        XCTAssertEqual(LinkHealth.rttLabel(1500), "1.5s")
        XCTAssertEqual(LinkHealth.rttLabel(0), "—")
        XCTAssertEqual(LinkHealth.rttLabel(-1), "—")
        XCTAssertEqual(LinkHealth.rttLabel(.nan), "—")
    }

    func testTooltipCarriesRttLossAndRecovered() {
        let tip = LinkHealth.tooltip(sample(rtt: 23, loss: 1.44, recovered: 12))
        XCTAssertEqual(tip, "RTT 23ms · loss 1.4% · recovered 12")
    }

    func testTooltipClampsNegativeRecovered() {
        let tip = LinkHealth.tooltip(sample(rtt: 20, loss: 0, recovered: -3))
        XCTAssertTrue(tip.hasSuffix("recovered 0"))
    }
}
