// ConnectionReadingTests — pins the connection island's whole CONTENT, below either UI.
//
// The visible-metric contract (every mount shows the ping ALONE — fps/kbps are tooltip detail, since
// appending them truncated the hostname out of its own row), the bitrate formatting, the
// network-health classifier behind the ink, the machine's three runs and the alarm ladder's evidence.
//
// These moved down with the island: the Mac draws it in AppKit and the phone in SwiftUI, so a pin
// living in either view target would only cover one of them.

import SlopDeskProtocol
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class ConnectionReadingTests: XCTestCase {
    func testVisibleMetricIsThePingAlone() {
        // The island's one metric: rounded ping, nothing appended; nil until the first sample.
        XCTAssertEqual(ConnectionReading.pingLabel(11.4), "11 ms")
        XCTAssertEqual(ConnectionReading.pingLabel(11.5), "12 ms")
        XCTAssertNil(ConnectionReading.pingLabel(nil))
    }

    func testStreamNumbersLiveInTheTooltipDetail() {
        XCTAssertEqual(
            ConnectionReading.tooltipDetail(fps: 60, kbps: 12400), " · 60 fps · 12.4 Mbps",
        )
        XCTAssertEqual(ConnectionReading.tooltipDetail(fps: nil, kbps: 850), " · 850 kbps")
        XCTAssertEqual(ConnectionReading.tooltipDetail(fps: 30, kbps: nil), " · 30 fps")
        XCTAssertEqual(ConnectionReading.tooltipDetail(fps: nil, kbps: nil), "", "no detail, no separator")
    }

    func testBitrateLabelMegabitsWithOneDecimal() {
        XCTAssertEqual(ConnectionReading.bitrateLabel(kbps: 12400), "12.4 Mbps")
        XCTAssertEqual(ConnectionReading.bitrateLabel(kbps: 1000), "1.0 Mbps")
    }

    func testBitrateLabelKilobitsBelowOneMegabit() {
        XCTAssertEqual(ConnectionReading.bitrateLabel(kbps: 850), "850 kbps")
        XCTAssertEqual(ConnectionReading.bitrateLabel(kbps: 0), "0 kbps")
    }

    func testNetworkHealthClassifierThresholds() {
        // Offline wins regardless of any stale ping value.
        XCTAssertEqual(ConnectionReading.health(isConnected: false, pingMS: 5), .offline)
        XCTAssertEqual(ConnectionReading.health(isConnected: false, pingMS: nil), .offline)
        // Connected with no sample yet reads good (the EWMA lands within a beat).
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: nil), .good)
        // The pinned thresholds: ≤80 good, ≤180 slow, beyond bad (boundary-inclusive).
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: 80), .good)
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: 80.1), .slow)
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: 180), .slow)
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: 180.1), .bad)
    }

    func testLedStateMapsStatusAndPing() {
        // Connected rides the ping classifier: good / slow / bad share the health thresholds.
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: nil), .good)
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: 50), .good)
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: 120), .slow)
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: 300), .bad)
        // A dial in flight (first connect or a supervised retry) is its own state — "working on it",
        // neither dead nor healthy.
        XCTAssertEqual(ConnectionReading.ledState(status: .connecting, pingMS: nil), .dialing)
        XCTAssertEqual(
            ConnectionReading.ledState(status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: nil),
            .dialing,
        )
        // The settled not-connected states dim it; a stale ping value must not resurrect them.
        XCTAssertEqual(ConnectionReading.ledState(status: .disconnected, pingMS: 12), .dim)
        XCTAssertEqual(ConnectionReading.ledState(status: .unreachable, pingMS: nil), .dim)
        XCTAssertEqual(ConnectionReading.ledState(status: .failed("refused"), pingMS: nil), .dim)
    }

    func testTrailingDetailLinePingWhenConnectedElseStatusWord() {
        // Connected with a sample: the mono ping metric.
        let ping = ConnectionReading.trailingDetail(status: .connected, pingMS: 11.4, mount: .bedded)
        XCTAssertEqual(ping?.text, "11 ms")
        XCTAssertEqual(ping?.isMetric, true)
        // Connected before the first sample: the status word, not a blank slot.
        let fresh = ConnectionReading.trailingDetail(status: .connected, pingMS: nil, mount: .bedded)
        XCTAssertEqual(fresh?.text, "connected")
        XCTAssertEqual(fresh?.isMetric, false)
        // Not connected: the short status word (campaign progress included), never a stale ping.
        let retry = ConnectionReading.trailingDetail(
            status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: 12, mount: .bedded,
        )
        XCTAssertEqual(retry?.text, "reconnecting 3/20")
        XCTAssertEqual(retry?.isMetric, false)
    }

    /// The ONE branch the mount decides, and the only one — everything else about the slot is the same
    /// answer at both mounts, which is what makes this a parameter rather than a second function.
    func testOnlyTheUnsampledSlotDependsOnTheMount() {
        // Connected, no sample yet: the bed speaks, the bedless pill stays silent.
        XCTAssertEqual(
            ConnectionReading.trailingDetail(status: .connected, pingMS: nil, mount: .bedded)?.text,
            "connected",
        )
        XCTAssertNil(ConnectionReading.trailingDetail(status: .connected, pingMS: nil, mount: .compact))
        // Every other reading is mount-independent.
        for mount in [ConnectionReading.ConnectionMount.bedded, .compact] {
            XCTAssertEqual(
                ConnectionReading.trailingDetail(status: .connected, pingMS: 11.4, mount: mount)?.text,
                "11 ms",
            )
            XCTAssertEqual(
                ConnectionReading.trailingDetail(status: .disconnected, pingMS: 11.4, mount: mount)?.text,
                "disconnected",
            )
        }
    }

    /// The trailing slot climbs only when it holds DIGITS. Prose that has already said "disconnected"
    /// gains nothing from being shouted, so a status word stays quiet whatever the link is doing.
    func testOnlyTheMetricSlotClimbs() {
        XCTAssertEqual(
            ConnectionReading.detailAlarm(detail: ("300 ms", true), led: .bad), .loud,
        )
        XCTAssertEqual(
            ConnectionReading.detailAlarm(detail: ("failed", false), led: .bad), .quiet,
            "a status WORD is prose, not an instrument",
        )
        XCTAssertEqual(ConnectionReading.detailAlarm(detail: nil, led: .bad), .quiet)
    }

    /// Whether a manual Retry applies — the GIVE-UP states only. A campaign still in flight has a
    /// retry already running, and offering a second one races it.
    func testRetryIsOfferedOnlyOnceTheSupervisorHasGivenUp() {
        XCTAssertTrue(ConnectionReading.showsRetry(.failed("refused")))
        XCTAssertTrue(ConnectionReading.showsRetry(.unreachable))
        XCTAssertFalse(ConnectionReading.showsRetry(.connected))
        XCTAssertFalse(ConnectionReading.showsRetry(.connecting))
        XCTAssertFalse(ConnectionReading.showsRetry(.reconnecting(attempt: 3, nextRetry: nil)))
        XCTAssertFalse(ConnectionReading.showsRetry(.disconnected))
    }

    func testPulseIsAbsentUntilTheHostHasReported() {
        // No reading ⇒ NO runs at all (never "cpu —": an instrument showing dashes advertises
        // breakage, while an island that grows a second line on connect just reports).
        XCTAssertEqual(ConnectionReading.metricRuns(nil), [])
        XCTAssertNil(ConnectionReading.pulseLabels(nil))
        XCTAssertEqual(ConnectionReading.pulseTooltip(nil), "", "no reading, no tooltip trail either")
        XCTAssertEqual(ConnectionReading.pulseSpoken(nil), "")
    }

    func testDrawnRunsAreBareNumbers_theSymbolCarriesTheName() {
        // What the pulse actually draws: the mark names the metric, so the run is the number alone —
        // no "cpu"/"mem" word repeated beside a glyph that already says it.
        let runs = ConnectionReading.metricRuns(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760),
        )
        XCTAssertEqual(runs.map(\.value), ["34%", "61%", "240G"])
        XCTAssertEqual(
            Set(ConnectionMetric.allCases.map(\.symbolName)).count, 3,
            "three metrics, three silhouettes — a repeated mark would name neither of its two",
        )
    }

    func testRunsGoFastestMovingToSlowest() {
        // cpu, then memory, then free disk: cpu moves second to second, memory over minutes, free
        // disk over days — so the line reads from "right now" toward "next week", and the two
        // percents stay adjacent because they are the pair a glance compares.
        let pulse = HostPulse(
            cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(ConnectionReading.metricRuns(pulse).map(\.metric), [.cpu, .memory, .disk])
        // The prose surfaces speak the same order, so the tooltip is not a re-shuffle of the row.
        XCTAssertEqual(ConnectionReading.pulseTooltip(pulse), " · cpu 34% · mem 61% · 240G free")
        XCTAssertEqual(ConnectionReading.pulseSpoken(pulse), "cpu 34%, mem 61%, 240G free")
    }

    func testUnreadableDiskDropsItsOwnRunNotTheLine() {
        // The host could not stat the volume: the trailing run disappears and the two percents keep
        // reporting. A metric that cannot be read must not take the working ones down with it.
        let runs = ConnectionReading.metricRuns(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: nil),
        )
        XCTAssertEqual(runs.map(\.metric), [.cpu, .memory], "the line survives")
        XCTAssertEqual(ConnectionReading.pulseTooltip(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal),
        ), " · cpu 34% · mem 61%", "and the tooltip simply omits it")
    }

    /// CPU is NEVER raised, whatever it reads. A build pegging the host is what the machine is FOR,
    /// and a readout that shouts every compile teaches the eye to ignore it.
    func testCPUNeverClimbs() {
        for percent in [0, 34, 99, 100] {
            let runs = ConnectionReading.metricRuns(
                HostPulse(cpuPercent: percent, memoryPercent: 97, memoryPressure: .critical),
            )
            XCTAssertEqual(runs.first?.metric, .cpu)
            XCTAssertEqual(runs.first?.alarm, .quiet, "cpu at \(percent)% is still just work")
        }
    }

    /// The ONE-LINE gate: a mount with a single row promotes exactly the runs that are not `quiet`.
    /// The predicate is the ladder read as a yes/no, so there is no second threshold to keep in step.
    func testPromotionIsTheAlarmLadderReadAsAGate() {
        XCTAssertFalse(ConnectionReading.promotes(.quiet))
        XCTAssertTrue(ConnectionReading.promotes(.raised))
        XCTAssertTrue(ConnectionReading.promotes(.loud))
    }

    /// A CALM host adds nothing to a one-line mount — that half of the phone pill's old argument
    /// stands: the ambient "how hard is the host working" is the desktop's question, and it has a
    /// second line to answer it on.
    func testACalmHostPromotesNothing() {
        XCTAssertEqual(ConnectionReading.promotedRuns(nil), [], "no reading, nothing to promote")
        XCTAssertEqual(
            ConnectionReading.promotedRuns(
                HostPulse(
                    cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
                ),
            ),
            [],
            "three healthy readings are three readings the row does not owe",
        )
    }

    /// …and the half that did not: what the bedded island ESCALATES, a one-line mount must still be
    /// able to say. A `critical` memory verdict and a volume with nothing left on it both promote,
    /// carrying their own rung with them.
    func testTheAlarmedRunsPromoteThemselvesCarryingTheirRung() {
        let warned = ConnectionReading.promotedRuns(
            HostPulse(cpuPercent: 34, memoryPercent: 88, memoryPressure: .warn, diskFreeMiB: 245_760),
        )
        XCTAssertEqual(warned.map(\.metric), [.memory])
        XCTAssertEqual(warned.map(\.alarm), [.raised])
        XCTAssertEqual(warned.map(\.value), ["88%"], "the promoted run is the drawn run, not a retelling")

        let both = ConnectionReading.promotedRuns(
            HostPulse(
                cpuPercent: 99, memoryPercent: 97, memoryPressure: .critical, diskFreeMiB: 3072,
            ),
        )
        XCTAssertEqual(both.map(\.metric), [.memory, .disk], "and in the island's own order")
        XCTAssertEqual(both.map(\.alarm), [.loud, .loud])
    }

    /// CPU can never reach the row, and that is a CONSEQUENCE rather than a second rule: it is the one
    /// metric whose alarm is pinned quiet, so the gate drops it without ever naming it. A phone that
    /// lit up for every compile would teach its owner to stop looking.
    func testCPUCanNeverPromoteHoweverHardTheHostIsWorking() {
        for percent in [0, 34, 99, 100] {
            XCTAssertFalse(
                ConnectionReading.promotedRuns(
                    HostPulse(cpuPercent: percent, memoryPercent: 61, memoryPressure: .normal),
                ).contains { $0.metric == .cpu },
                "cpu at \(percent)% is still just work",
            )
        }
    }

    /// A promoted run is a run the full line would have drawn — same order, same value, same rung. The
    /// gate may only DROP; if it could ever produce a reading of its own the two mounts would be free
    /// to disagree about what the host is doing.
    func testPromotionOnlyEverDropsRunsFromTheDrawnLine() {
        for pressure in [MetadataCodec.MemoryPressure.normal, .warn, .critical] {
            for disk in [nil, UInt32(0), 3072, 15360, 245_760] {
                let pulse = HostPulse(
                    cpuPercent: 42, memoryPercent: 77, memoryPressure: pressure, diskFreeMiB: disk,
                )
                let full = ConnectionReading.metricRuns(pulse)
                let promoted = ConnectionReading.promotedRuns(pulse)
                XCTAssertEqual(
                    promoted, full.filter { $0.alarm != .quiet },
                    "the one line is a subsequence of the two, never a second reading",
                )
            }
        }
    }

    func testDiskLabelCoarsensWithScaleAndStaysFourCharacters() {
        // Two significant figures is the whole answer to "can I still work here", and a number that
        // only names round values cannot twitch between polls.
        XCTAssertNil(ConnectionReading.diskLabel(freeMiB: nil))
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 0), "0M", "a genuinely full disk still reports")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 820), "820M")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 1024), "1.0G")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 6554), "6.4G")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 43008), "42G")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 245_760), "240G")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 2_202_010), "2.1T")
        for mib in [UInt32(0), 820, 1024, 6554, 43008, 245_760, 2_202_010] {
            XCTAssertLessThanOrEqual(
                ConnectionReading.diskLabel(freeMiB: mib)?.count ?? 0, 4,
                "the trailing run has no room to grow",
            )
        }
    }

    func testDiskThresholdsAreAbsoluteBytesNotAPercent() {
        // There is no kernel verdict for disk, and a percent lies in both directions — so the ladder
        // is in bytes left, the only figure that answers the question.
        XCTAssertLessThan(ConnectionReading.diskCriticalMiB, ConnectionReading.diskWarnMiB)
        XCTAssertEqual(ConnectionReading.diskWarnMiB, 15 * 1024, "a clean build's worth of room")
        XCTAssertEqual(ConnectionReading.diskCriticalMiB, 5 * 1024, "below this the next save fails")
    }

    func testPulseLabelsKeepTheWordsForProseSurfaces() {
        // The tooltip and the accessibility label still spell the metrics out — a silhouette is
        // unreadable to VoiceOver and unlearned on first sight.
        let labels = ConnectionReading.pulseLabels(
            HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal),
        )
        XCTAssertEqual(labels?.cpu, "cpu 34%")
        XCTAssertEqual(labels?.memory, "mem 61%")
    }

    func testPulseTooltipCarriesThePressureVerdictTheLineOnlyHintsAt() {
        let normal = HostPulse(
            cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(ConnectionReading.pulseTooltip(normal), " · cpu 34% · mem 61% · 240G free")
        let warn = HostPulse(cpuPercent: 34, memoryPercent: 88, memoryPressure: .warn)
        XCTAssertEqual(ConnectionReading.pulseTooltip(warn), " · cpu 34% · mem 88% (memory pressure)")
        let critical = HostPulse(cpuPercent: 99, memoryPercent: 97, memoryPressure: .critical)
        XCTAssertEqual(
            ConnectionReading.pulseTooltip(critical), " · cpu 99% · mem 97% (memory pressure critical)",
        )
    }

    /// The island's hover text: identity + the actionable headline, plus the stream numbers the
    /// visible row deliberately drops — and those only WHILE CONNECTED, since a dead link's fps is
    /// the last frame it managed rather than a reading.
    func testHelpTextIsTheOnDemandHomeOfEverythingTheRowDrops() {
        XCTAssertEqual(
            ConnectionReading.help(
                host: "mac-studio", status: .connected, fps: 60, kbps: 12400,
                pulse: HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal),
            ),
            "Connection: mac-studio — Connected · 60 fps · 12.4 Mbps · cpu 34% · mem 61%",
        )
        XCTAssertEqual(
            ConnectionReading.help(
                host: "mac-studio", status: .disconnected, fps: 60, kbps: 12400, pulse: nil,
            ),
            "Connection: mac-studio — Disconnected",
        )
    }

    /// The LINK climbs with the round trip: slow is worth knowing, bad is worth acting on. Everything
    /// not-connected stays quiet — the status WORD in that slot already says so, and an instrument
    /// with nothing to measure has nothing to shout about (a `dialing` campaign least of all).
    func testLinkAlarmClimbsOnlyWithADegradingLink() {
        XCTAssertEqual(ConnectionReading.linkAlarm(.good), .quiet)
        XCTAssertEqual(ConnectionReading.linkAlarm(.slow), .raised)
        XCTAssertEqual(ConnectionReading.linkAlarm(.bad), .loud)
        XCTAssertEqual(ConnectionReading.linkAlarm(.dialing), .quiet, "a dial in flight is not a fault")
        XCTAssertEqual(ConnectionReading.linkAlarm(.dim), .quiet)
    }

    /// MEMORY takes the kernel's pressure verdict, not the percent (macOS fills the RAM it has, so a
    /// high percent is ordinary on a healthy Mac). DISK takes an absolute byte threshold, since there
    /// is no kernel verdict for it. An unreadable volume is quiet: no reading is not bad news.
    func testMemoryAndDiskAlarmsUseTheirOwnEvidence() {
        XCTAssertEqual(ConnectionReading.memoryAlarm(.normal), .quiet)
        XCTAssertEqual(ConnectionReading.memoryAlarm(.warn), .raised)
        XCTAssertEqual(ConnectionReading.memoryAlarm(.critical), .loud)
        XCTAssertEqual(ConnectionReading.memoryAlarm(nil), .quiet)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: 245_760), .quiet)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: ConnectionReading.diskWarnMiB), .quiet)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: ConnectionReading.diskWarnMiB - 1), .raised)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: ConnectionReading.diskCriticalMiB), .raised)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: ConnectionReading.diskCriticalMiB - 1), .loud)
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: 0), .loud, "a genuinely full disk is loud")
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: nil), .quiet, "an unread volume is not a fault")
    }
}
