// ConnectionReadingTests — pins the CROSSING behind the connection island, below either UI.
//
// The thresholds, the ladder's evidence, the run order, the disk figure's coarsening and every word
// the island speaks are `slopdesk_workspace::connection`'s, tested there. Restating them here would
// be the cross-language mirror fixture `CLAUDE.md` forbids: a Swift copy of a Rust table can stay
// green for a release after the rule underneath it moved.
//
// What only THIS side can get wrong is what is pinned below:
//
//   • OPTIONALITY. A `nil` ping, a `nil` pulse and an unreadable volume are absences the C boundary
//     spells as presence FLAGS. `diskFreeMiB: 0` and `diskFreeMiB: nil` are the same four bytes with
//     a different flag, and a face that dropped the flag would report a full disk as a missing one.
//   • The CODES. Five LED rungs, four health readings, three alarms, three metric roles and six
//     statuses each have to leave and come back as themselves.
//   • The BLOB. The drawn runs cross as one delivery with a role, a rung and a length-prefixed figure
//     per run — three fields that a cursor off by one would hand to each other's neighbours.
//   • What stays SWIFT: the host name in the help line, which never makes the trip.
//
// These moved down with the island: the Mac draws it in AppKit and the phone in SwiftUI, so a pin
// living in either view target would only cover one of them.

import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class ConnectionReadingTests: XCTestCase {
    // MARK: - Absence is this side's word

    func testAnAbsentReadingIsAbsenceAndNeverAZero() {
        XCTAssertNil(ConnectionReading.pingLabel(nil), "no sample yet is not a ping of zero")
        XCTAssertNil(ConnectionReading.diskLabel(freeMiB: nil))
        XCTAssertEqual(ConnectionReading.metricRuns(nil), [], "no reading ⇒ no runs, never a row of dashes")
        XCTAssertEqual(ConnectionReading.promotedRuns(nil), [])
        XCTAssertEqual(ConnectionReading.pulseTooltip(nil), "", "no reading, no tooltip trail either")
        XCTAssertEqual(ConnectionReading.pulseSpoken(nil), "")
        XCTAssertEqual(ConnectionReading.tooltipDetail(fps: nil, kbps: nil), "", "no detail, no separator")
    }

    /// The presence FLAG, which is the one place the port could quietly lose a fact: a genuinely full
    /// volume and an unreadable one are the same `0` on the wire and opposite answers on screen.
    func testAFullVolumeIsNotAnUnreadableOne() {
        let full = HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 0)
        let unread = HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: nil)
        XCTAssertEqual(ConnectionReading.metricRuns(full).map(\.metric), [.cpu, .memory, .disk])
        XCTAssertEqual(ConnectionReading.metricRuns(unread).map(\.metric), [.cpu, .memory])
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: 0), .loud, "a genuinely full disk is loud")
        XCTAssertEqual(ConnectionReading.diskAlarm(freeMiB: nil), .quiet, "an unread volume is not a fault")
        XCTAssertEqual(ConnectionReading.diskLabel(freeMiB: 0), "0M", "and it still reports")
    }

    /// The ping's presence flag reaches the door too — a stale figure behind a `nil` must never be
    /// read, at either of the two doors that take one.
    func testTheAbsentPingIsNeverReadAtEitherDoor() {
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: nil), .good)
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: nil), .good)
        XCTAssertEqual(ConnectionReading.health(isConnected: true, pingMS: 300), .bad)
        XCTAssertEqual(ConnectionReading.ledState(status: .connected, pingMS: 300), .bad)
    }

    // MARK: - The codes

    func testEveryLedRungCrossesAsItselfAndComesBackAsItself() {
        // `linkAlarm` is the only door that takes an LED code, so a rung that came back as its
        // neighbour would land the whole ladder one step out.
        XCTAssertEqual(
            ConnectionLed.allCases.map { ConnectionReading.linkAlarm($0) },
            [.quiet, .quiet, .quiet, .raised, .loud],
            "dim, dialing, good, slow, bad — in the enum's own order",
        )
        XCTAssertEqual(Set(ConnectionLed.allCases).count, 5)
    }

    func testEachHealthAndAlarmCodeBindsToItsOwnCase() {
        XCTAssertEqual(
            [
                ConnectionReading.health(isConnected: false, pingMS: nil),
                ConnectionReading.health(isConnected: true, pingMS: 10),
                ConnectionReading.health(isConnected: true, pingMS: 120),
                ConnectionReading.health(isConnected: true, pingMS: 300),
            ],
            [.offline, .good, .slow, .bad],
            "four readings, four codes",
        )
        XCTAssertEqual(
            [
                ConnectionReading.memoryAlarm(.normal),
                ConnectionReading.memoryAlarm(.warn),
                ConnectionReading.memoryAlarm(.critical),
                ConnectionReading.memoryAlarm(nil),
            ],
            [.quiet, .raised, .loud, .quiet],
            "and the kernel's byte reaches the classifier as itself",
        )
    }

    func testEachMetricRoleNamesItsOwnSymbol() {
        XCTAssertEqual(
            Set(ConnectionMetric.allCases.map(\.symbolName)).count, 3,
            "three metrics, three silhouettes — a repeated mark would name neither of its two",
        )
        XCTAssertFalse(
            ConnectionMetric.allCases.map(\.symbolName).contains(where: \.isEmpty),
            "an empty name is a code that reached no role",
        )
    }

    // MARK: - The blob

    /// The drawn runs cross as `[count]` then a role, a rung and a length-prefixed figure per run.
    /// Three fields side by side is exactly where a cursor off by one hands each to its neighbour, so
    /// this asserts all three land together on a pulse where no two runs share a value.
    func testEachRunKeepsItsOwnRoleRungAndFigure() {
        let runs = ConnectionReading.metricRuns(
            HostPulse(cpuPercent: 34, memoryPercent: 88, memoryPressure: .warn, diskFreeMiB: 3072),
        )
        XCTAssertEqual(runs.map(\.metric), [.cpu, .memory, .disk])
        XCTAssertEqual(runs.map(\.alarm), [.quiet, .raised, .loud])
        XCTAssertEqual(runs.map(\.value), ["34%", "88%", "3.0G"])
    }

    /// The one-line gate is the door's own flag, not a filter on this side — so a promoted run is a
    /// run the full line would have drawn, in the same order, carrying the same rung.
    func testPromotionOnlyEverDropsRunsFromTheDrawnLine() {
        for pressure in [MetadataCodec.MemoryPressure.normal, .warn, .critical] {
            for disk in [nil, UInt32(0), 3072, 15360, 245_760] {
                let pulse = HostPulse(
                    cpuPercent: 42, memoryPercent: 77, memoryPressure: pressure, diskFreeMiB: disk,
                )
                XCTAssertEqual(
                    ConnectionReading.promotedRuns(pulse),
                    ConnectionReading.metricRuns(pulse).filter { $0.alarm != .quiet },
                    "the one line is a subsequence of the two, never a second reading",
                )
            }
        }
    }

    /// The two prose registers ride one delivery, and they are not the same string — a reader that
    /// took run 0 for both would leave the tooltip speaking the accessibility label.
    func testTheTwoProseRegistersLandInTheirOwnPlaces() {
        let pulse = HostPulse(
            cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(ConnectionReading.pulseSpoken(pulse), "cpu 34%, mem 61%, 240G free")
        XCTAssertEqual(ConnectionReading.pulseTooltip(pulse), " · cpu 34% · mem 61% · 240G free")
    }

    // MARK: - The trailing slot

    /// The door answers a SOURCE, and this side supplies the payload each source wants. The failure
    /// this catches is a face that answered the slot correctly and then reached for the wrong string.
    func testEachSlotIsFilledFromItsOwnSource() {
        let ping = ConnectionReading.trailingDetail(status: .connected, pingMS: 11.4, mount: .bedded)
        XCTAssertEqual(ping?.text, "11 ms")
        XCTAssertEqual(ping?.isMetric, true)

        let word = ConnectionReading.trailingDetail(
            status: .reconnecting(attempt: 3, nextRetry: nil), pingMS: 12, mount: .bedded,
        )
        XCTAssertEqual(word?.text, ConnectionPresenter.shortLabel(for: .reconnecting(attempt: 3, nextRetry: nil)))
        XCTAssertEqual(word?.isMetric, false, "never a stale ping")
    }

    /// The ONE branch the mount decides, and the only one — everything else about the slot is the same
    /// answer at both mounts, which is what makes it an argument rather than a second function.
    func testOnlyTheUnsampledSlotDependsOnTheMount() {
        XCTAssertEqual(
            ConnectionReading.trailingDetail(status: .connected, pingMS: nil, mount: .bedded)?.text,
            "connected",
        )
        XCTAssertNil(ConnectionReading.trailingDetail(status: .connected, pingMS: nil, mount: .compact))
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

    /// `detailAlarm` takes the slot the caller ended up DRAWING, so the three shapes this side can be
    /// holding — a metric, a word, nothing — each have to reach the door as their own code.
    func testTheSlotThisSideDrewIsTheSlotTheDoorClassifies() {
        XCTAssertEqual(ConnectionReading.detailAlarm(detail: ("300 ms", true), led: .bad), .loud)
        XCTAssertEqual(
            ConnectionReading.detailAlarm(detail: ("failed", false), led: .bad), .quiet,
            "a status WORD is prose, not an instrument",
        )
        XCTAssertEqual(ConnectionReading.detailAlarm(detail: nil, led: .bad), .quiet)
    }

    func testRetryIsOfferedOnlyOnceTheSupervisorHasGivenUp() {
        // The status code reaches the gate: six states, and only the two give-up ones answer true.
        XCTAssertTrue(ConnectionReading.showsRetry(.failed("refused")))
        XCTAssertTrue(ConnectionReading.showsRetry(.unreachable))
        XCTAssertFalse(ConnectionReading.showsRetry(.connected))
        XCTAssertFalse(ConnectionReading.showsRetry(.connecting))
        XCTAssertFalse(ConnectionReading.showsRetry(.reconnecting(attempt: 3, nextRetry: nil)))
        XCTAssertFalse(ConnectionReading.showsRetry(.disconnected))
    }

    // MARK: - What stays Swift

    /// The island's hover text: identity + the actionable headline, plus the stream numbers the
    /// visible row deliberately drops — and those only WHILE CONNECTED, since a dead link's fps is
    /// the last frame it managed rather than a reading.
    ///
    /// The HOST NAME is the part that never crosses. It is an identity this side is already holding,
    /// and a door that took it would be interpolating a string Swift interpolates for free.
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
            "a dead link's stream numbers are the last frame it managed, not a reading",
        )
    }
}
