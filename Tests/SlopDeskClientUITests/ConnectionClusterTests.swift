// ConnectionClusterTests — pins the connection cluster's visible-metric contract (the COMPACT
// mounts show the ping ALONE — fps/kbps are tooltip detail there, since appending them truncated
// the hostname; the RAIL footer's own detail line carries the full readout: ping · stream numbers ·
// uptime), the bitrate formatting, the network-health classifier behind the metric colour, and the
// model's kbps dirty-guard semantics (a ZERO is a real idle reading, kept — unlike fps, where zero
// is spurious and dropped).

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

    func testFooterExtrasStreamNumbersOrUptimeConnectedOnly() {
        // A live stream owns the trail — the uptime yields (both together truncate the line).
        XCTAssertEqual(
            ConnectionCluster.footerExtras(status: .connected, fps: 60, kbps: 12400, uptime: "up 2h 14m"),
            " · 60 fps · 12.4 Mbps",
        )
        XCTAssertEqual(
            ConnectionCluster.footerExtras(status: .connected, fps: nil, kbps: 850, uptime: "up 5m"),
            " · 850 kbps",
        )
        // Terminal-only session: the uptime rides alone.
        XCTAssertEqual(
            ConnectionCluster.footerExtras(status: .connected, fps: nil, kbps: nil, uptime: "up 5m"),
            " · up 5m",
        )
        // Nothing to say: nil, so the detail line stays the bare ping.
        XCTAssertNil(ConnectionCluster.footerExtras(status: .connected, fps: nil, kbps: nil, uptime: nil))
        // A dead link has no telemetry — stale numbers must never trail the status word.
        XCTAssertNil(
            ConnectionCluster.footerExtras(status: .disconnected, fps: 60, kbps: 12400, uptime: "up 2h 14m"),
        )
        XCTAssertNil(
            ConnectionCluster.footerExtras(
                status: .reconnecting(attempt: 3, nextRetry: nil), fps: nil, kbps: nil, uptime: "up 1m",
            ),
        )
    }

    func testUptimeLabelMinuteGranularLadder() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func label(_ seconds: TimeInterval) -> String? {
            ConnectionCluster.uptimeLabel(since: now.addingTimeInterval(-seconds), now: now)
        }
        // The first minute is silent — a seconds counter would tick every render.
        XCTAssertNil(label(0))
        XCTAssertNil(label(59))
        XCTAssertNil(ConnectionCluster.uptimeLabel(since: nil, now: now))
        // Minutes, then hours carrying minutes, then days carrying hours.
        XCTAssertEqual(label(60), "up 1m")
        XCTAssertEqual(label(59 * 60), "up 59m")
        XCTAssertEqual(label(60 * 60), "up 1h 0m")
        XCTAssertEqual(label(2 * 3600 + 14 * 60), "up 2h 14m")
        XCTAssertEqual(label(24 * 3600), "up 1d 0h")
        XCTAssertEqual(label(3 * 24 * 3600 + 5 * 3600), "up 3d 5h")
        // Clock skew (host clock behind): silent, never a negative readout.
        XCTAssertNil(label(-30))
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
