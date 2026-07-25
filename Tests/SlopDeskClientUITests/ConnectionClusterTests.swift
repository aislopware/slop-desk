// ConnectionClusterTests — pins the connection cluster's visible-metric contract (BOTH mounts show
// the ping ALONE — fps/kbps are tooltip detail, since appending them truncated the hostname; the
// rail footer differs only in speaking the status word while connected-but-unsampled, where the
// compact row stays silent), the bitrate formatting, the network-health classifier behind the metric
// colour, and the model's kbps dirty-guard semantics (a ZERO is a real idle reading, kept — unlike
// fps, where zero is spurious and dropped).

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

final class ConnectionClusterTests: XCTestCase {
    func testVisibleMetricIsThePingAlone() {
        // The row's one metric: rounded ping, nothing appended; nil until the first sample.
        XCTAssertEqual(ConnectionCluster.pingLabel(11.4), "11 ms")
        XCTAssertEqual(ConnectionCluster.pingLabel(11.5), "12 ms")
        XCTAssertNil(ConnectionCluster.pingLabel(nil))
    }

    func testStreamNumbersLiveInTheTooltipDetail() {
        XCTAssertEqual(
            ConnectionCluster.tooltipDetail(fps: 60, kbps: 12400), " · 60 fps · 12.4 Mbps",
        )
        XCTAssertEqual(ConnectionCluster.tooltipDetail(fps: nil, kbps: 850), " · 850 kbps")
        XCTAssertEqual(ConnectionCluster.tooltipDetail(fps: 30, kbps: nil), " · 30 fps")
        XCTAssertEqual(ConnectionCluster.tooltipDetail(fps: nil, kbps: nil), "", "no detail, no separator")
    }

    func testBitrateLabelMegabitsWithOneDecimal() {
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 12400), "12.4 Mbps")
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 1000), "1.0 Mbps")
    }

    func testBitrateLabelKilobitsBelowOneMegabit() {
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 850), "850 kbps")
        XCTAssertEqual(ConnectionCluster.bitrateLabel(kbps: 0), "0 kbps")
    }

    func testNetworkHealthClassifierThresholds() {
        // Offline wins regardless of any stale ping value.
        XCTAssertEqual(ConnectionCluster.health(isConnected: false, pingMS: 5), .offline)
        XCTAssertEqual(ConnectionCluster.health(isConnected: false, pingMS: nil), .offline)
        // Connected with no sample yet reads good (the EWMA lands within a beat).
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: nil), .good)
        // The pinned thresholds: ≤80 good, ≤180 slow, beyond bad (boundary-inclusive).
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 80), .good)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 80.1), .slow)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 180), .slow)
        XCTAssertEqual(ConnectionCluster.health(isConnected: true, pingMS: 180.1), .bad)
    }

    func testFooterLedStateMapsStatusAndPing() {
        // Connected rides the ping classifier: good / slow / bad share the health thresholds.
        XCTAssertEqual(ConnectionCluster.ledState(status: .connected, pingMS: nil), .good)
        XCTAssertEqual(ConnectionCluster.ledState(status: .connected, pingMS: 50), .good)
        XCTAssertEqual(ConnectionCluster.ledState(status: .connected, pingMS: 120), .slow)
        XCTAssertEqual(ConnectionCluster.ledState(status: .connected, pingMS: 300), .bad)
        // A dial in flight (first connect or a supervised retry) is its own LED state — amber
        // "working on it", neither dead nor healthy.
        XCTAssertEqual(ConnectionCluster.ledState(status: .connecting, pingMS: nil), .dialing)
        XCTAssertEqual(
            ConnectionCluster.ledState(status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: nil),
            .dialing,
        )
        // The settled not-connected states dim the LED; a stale ping value must not resurrect it.
        XCTAssertEqual(ConnectionCluster.ledState(status: .disconnected, pingMS: 12), .dim)
        XCTAssertEqual(ConnectionCluster.ledState(status: .unreachable, pingMS: nil), .dim)
        XCTAssertEqual(ConnectionCluster.ledState(status: .failed("refused"), pingMS: nil), .dim)
    }

    func testFooterDetailLinePingWhenConnectedElseStatusWord() {
        // Connected with a sample: the mono ping metric.
        let ping = ConnectionCluster.footerDetail(status: .connected, pingMS: 11.4)
        XCTAssertEqual(ping?.text, "11 ms")
        XCTAssertEqual(ping?.isMetric, true)
        // Connected before the first sample: the status word, not a blank line.
        let fresh = ConnectionCluster.footerDetail(status: .connected, pingMS: nil)
        XCTAssertEqual(fresh?.text, "connected")
        XCTAssertEqual(fresh?.isMetric, false)
        // Not connected: the short status word (campaign progress included), never a stale ping.
        let retry = ConnectionCluster.footerDetail(
            status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: 12,
        )
        XCTAssertEqual(retry?.text, "reconnecting 3/20")
        XCTAssertEqual(retry?.isMetric, false)
    }

    @MainActor
    func testNoteStreamKbpsKeepsZeroAndDropsNegative() {
        let model = RemoteWindowModel()
        XCTAssertNil(model.streamKbps)
        model.noteStreamKbps(2400)
        XCTAssertEqual(model.streamKbps, 2400)
        // Idle-skip: a real 0 reading REPLACES the last value (the instrument shows the stream breathing).
        model.noteStreamKbps(0)
        XCTAssertEqual(model.streamKbps, 0)
        // Nonsense negative is dropped — the last reading stands.
        model.noteStreamKbps(-5)
        XCTAssertEqual(model.streamKbps, 0)
    }
}
