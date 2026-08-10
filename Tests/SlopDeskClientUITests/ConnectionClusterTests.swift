// ConnectionClusterTests — pins the connection cluster's visible-metric contract (BOTH mounts show
// the ping ALONE — fps/kbps are tooltip detail, since appending them truncated the hostname; the
// rail footer differs in speaking the status word while connected-but-unsampled, where the compact
// row stays silent, and in carrying the host-pulse SECOND line), the bitrate formatting, the
// network-health classifier behind the metric colour, and the model's kbps dirty-guard semantics (a
// ZERO is a real idle reading, kept — unlike fps, where zero is spurious and dropped).

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
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

    func testPulseLineIsAbsentUntilTheHostHasReported() {
        // No reading ⇒ NO second line (never "cpu —": an instrument showing dashes advertises breakage).
        XCTAssertNil(ConnectionCluster.pulseReadings(nil))
        XCTAssertNil(ConnectionCluster.pulseLabels(nil))
        XCTAssertEqual(ConnectionCluster.pulseTooltip(nil), "", "no reading, no tooltip trail either")
    }

    func testDrawnReadingsAreBareNumbers_theSymbolCarriesTheName() {
        // What line two actually draws: the mark names the metric, so the run is the number alone —
        // no "cpu"/"mem" word repeated beside a glyph that already says it.
        let readings = ConnectionCluster.pulseReadings(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760),
        )
        XCTAssertEqual(readings?.cpu, "34%", "leading rail: the machine's own load")
        XCTAssertEqual(readings?.memory, "61%", "the middle: the reading between right-now and next-week")
        XCTAssertEqual(readings?.disk, "240G", "trailing rail: the room left to work in")
        XCTAssertEqual(
            Set([ConnectionCluster.cpuSymbol, ConnectionCluster.diskSymbol, ConnectionCluster.memorySymbol]).count,
            3, "three metrics, three silhouettes — a repeated mark would name neither of its two",
        )
    }

    func testReadingsRunFastestMovingToSlowest() {
        // cpu, then memory, then free disk. The order is the tuple's own shape (the view draws it in
        // element order), and it is the ordering rule: cpu moves second to second, memory over
        // minutes, free disk over days — so the line reads from "right now" toward "next week", and
        // the two percents stay adjacent because they are the pair a glance compares.
        let pulse = HostPulse(
            cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        guard let readings = ConnectionCluster.pulseReadings(pulse) else {
            XCTFail("a reported pulse must draw")
            return
        }
        XCTAssertEqual([readings.cpu, readings.memory, readings.disk], ["34%", "61%", "240G"])
        // The prose surfaces speak the same order, so the tooltip is not a re-shuffle of the row.
        XCTAssertEqual(ConnectionCluster.pulseTooltip(pulse), " · cpu 34% · mem 61% · 240G free")
    }

    func testUnreadableDiskDropsItsOwnRunNotTheLine() {
        // The host could not stat the volume: the trailing run disappears and the two percents keep
        // reporting. A metric that cannot be read must not take the working ones down with it.
        let readings = ConnectionCluster.pulseReadings(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: nil),
        )
        XCTAssertNotNil(readings, "the line survives")
        XCTAssertNil(readings?.disk)
        XCTAssertEqual(ConnectionCluster.pulseTooltip(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal),
        ), " · cpu 34% · mem 61%", "and the tooltip simply omits it")
    }

    func testDiskLabelCoarsensWithScaleAndStaysFourCharacters() {
        // Two significant figures is the whole answer to "can I still work here", and a number that
        // only names round values cannot twitch between polls.
        XCTAssertNil(ConnectionCluster.diskLabel(freeMiB: nil))
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 0), "0M", "a genuinely full disk still reports")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 820), "820M")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 1024), "1.0G")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 6554), "6.4G")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 43008), "42G")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 245_760), "240G")
        XCTAssertEqual(ConnectionCluster.diskLabel(freeMiB: 2_202_010), "2.1T")
        for mib in [UInt32(0), 820, 1024, 6554, 43008, 245_760, 2_202_010] {
            XCTAssertLessThanOrEqual(
                ConnectionCluster.diskLabel(freeMiB: mib)?.count ?? 0, 4, "the trailing run has no room to grow",
            )
        }
    }

    func testDiskThresholdsAreAbsoluteBytesNotAPercent() {
        // There is no kernel verdict for disk, and a percent lies in both directions — so the ladder
        // is in bytes left, the only figure that answers the question.
        XCTAssertLessThan(ConnectionCluster.diskCriticalMiB, ConnectionCluster.diskWarnMiB)
        XCTAssertEqual(ConnectionCluster.diskWarnMiB, 15 * 1024, "a clean build's worth of room")
        XCTAssertEqual(ConnectionCluster.diskCriticalMiB, 5 * 1024, "below this the next save fails")
    }

    func testPulseLabelsKeepTheWordsForProseSurfaces() {
        // The tooltip and the accessibility label still spell the metrics out — a silhouette is
        // unreadable to VoiceOver and unlearned on first sight.
        let labels = ConnectionCluster.pulseLabels(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal),
        )
        XCTAssertEqual(labels?.cpu, "cpu 34%")
        XCTAssertEqual(labels?.memory, "mem 61%")
    }

    func testPulseTooltipCarriesThePressureVerdictTheLineOnlyHintsAt() {
        let normal = HostPulse(
            cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(ConnectionCluster.pulseTooltip(normal), " · cpu 34% · mem 61% · 240G free")
        let warn = HostPulse(cpuPercent: 34, memoryPercent: 88, memoryPressure: .warn)
        XCTAssertEqual(ConnectionCluster.pulseTooltip(warn), " · cpu 34% · mem 88% (memory pressure)")
        let critical = HostPulse(cpuPercent: 99, memoryPercent: 97, memoryPressure: .critical)
        XCTAssertEqual(
            ConnectionCluster.pulseTooltip(critical), " · cpu 99% · mem 97% (memory pressure critical)",
        )
    }

    // MARK: - The alarm ladder (one axis, no hue)

    /// The footer spends BRIGHTNESS and WEIGHT, never hue: `quiet` is the metadata grey every healthy
    /// reading rests in, `raised` steps up to the body-secondary ink at semibold, `loud` to the primary ink
    /// at bold. Three distinct rungs on both channels — a rung that only moved one of them would be
    /// invisible on a theme whose greys sit close, or on a line already full of medium-weight type.
    @MainActor
    func testAlarmLadderClimbsBrightnessAndWeightTogether() {
        XCTAssertEqual(ConnectionCluster.alarmInk(.quiet), Slate.Text.tertiary)
        XCTAssertEqual(ConnectionCluster.alarmInk(.raised), Slate.Text.secondary)
        XCTAssertEqual(ConnectionCluster.alarmInk(.loud), Slate.Text.primary)
        XCTAssertEqual(ConnectionCluster.alarmWeight(.quiet), .regular)
        XCTAssertEqual(ConnectionCluster.alarmWeight(.raised), .semibold)
        XCTAssertEqual(ConnectionCluster.alarmWeight(.loud), .bold)
        let inks = [ConnectionCluster.Alarm.quiet, .raised, .loud].map(ConnectionCluster.alarmInk)
        XCTAssertEqual(Set(inks).count, 3, "every rung is its own ink — no two states paint the same")
        for alarm in [ConnectionCluster.Alarm.quiet, .raised, .loud] {
            XCTAssertNotEqual(
                ConnectionCluster.alarmInk(alarm), Slate.StatusInk.warn,
                "the footer has no hue register — \(alarm) must not reach for a status colour",
            )
            XCTAssertNotEqual(ConnectionCluster.alarmInk(alarm), Slate.StatusInk.err)
        }
    }

    /// The LINK climbs with the round trip: slow is worth knowing, bad is worth acting on. Everything
    /// not-connected stays quiet — the status WORD in that slot already says so, and a footer with nothing
    /// to measure has nothing to shout about (a `dialing` retry campaign least of all).
    func testLinkAlarmClimbsOnlyWithADegradingLink() {
        XCTAssertEqual(ConnectionCluster.linkAlarm(.good), .quiet)
        XCTAssertEqual(ConnectionCluster.linkAlarm(.slow), .raised)
        XCTAssertEqual(ConnectionCluster.linkAlarm(.bad), .loud)
        XCTAssertEqual(ConnectionCluster.linkAlarm(.dialing), .quiet, "a dial in flight is not a fault")
        XCTAssertEqual(ConnectionCluster.linkAlarm(.dim), .quiet)
    }

    /// MEMORY takes the kernel's pressure verdict, not the percent (macOS fills the RAM it has, so a high
    /// percent is ordinary on a healthy Mac). DISK takes an absolute byte threshold, since there is no
    /// kernel verdict for it. An unreadable volume is quiet: no reading is not bad news.
    func testMemoryAndDiskAlarmsUseTheirOwnEvidence() {
        XCTAssertEqual(ConnectionCluster.memoryAlarm(.normal), .quiet)
        XCTAssertEqual(ConnectionCluster.memoryAlarm(.warn), .raised)
        XCTAssertEqual(ConnectionCluster.memoryAlarm(.critical), .loud)
        XCTAssertEqual(ConnectionCluster.memoryAlarm(nil), .quiet)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: 245_760), .quiet)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: ConnectionCluster.diskWarnMiB), .quiet)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: ConnectionCluster.diskWarnMiB - 1), .raised)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: ConnectionCluster.diskCriticalMiB), .raised)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: ConnectionCluster.diskCriticalMiB - 1), .loud)
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: 0), .loud, "a genuinely full disk is loud")
        XCTAssertEqual(ConnectionCluster.diskAlarm(freeMiB: nil), .quiet, "an unread volume is not a fault")
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
