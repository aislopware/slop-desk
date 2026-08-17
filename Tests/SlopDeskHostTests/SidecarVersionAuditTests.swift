import Foundation
import XCTest
@testable import SlopDeskHost

/// The announce line's version field, and the decode of the audit door (`docs/49`).
///
/// The COMPARISON, the policy table and the banner parse are `rust/slopdesk-sidecars` and are tested
/// there. Asserting them again from Swift would be the cross-language mirror fixture `CLAUDE.md`
/// bans, and it would be worse than redundant: two suites agreeing is exactly what makes a policy
/// change look safe when only one of the two implementations moved. What is tested here is what is
/// Swift — parsing the line hostd reads off superd's ring, and what this side does with an answer
/// the door did or did not give.
final class SidecarVersionAuditTests: XCTestCase {
    // MARK: - The announce line's version

    /// The contract the three announcing daemons print: the version is FIRST in the parenthetical
    /// and `v`-prefixed, so its position holds however the rest of that text grows.
    func testTheVersionIsReadOutOfEachDaemonsRealAnnounceLine() {
        XCTAssertEqual(
            FileDropServiceManager.parseAnnouncedVersion(
                fromLogLine: "dropd: listening on 0.0.0.0:9002 (v0.1.0, drop dir /Users/x/Downloads)",
            ),
            "0.1.0",
        )
        XCTAssertEqual(
            InspectorServiceManager.parseAnnouncedVersion(
                fromLogLine: "inspectord: listening on 0.0.0.0:9001 (v0.1.0, no transcript)",
            ),
            "0.1.0",
        )
        XCTAssertEqual(
            AndroidServiceManager.parseAnnouncedVersion(
                fromLogLine: "androidd: listening on 0.0.0.0:54321 (v0.1.0, adb /opt/adb, "
                    + "emulator missing, scrcpy-server missing)",
            ),
            "0.1.0",
        )
    }

    /// A daemon that predates the field is the ADOPT case — a survivor of the hostd that ran before
    /// the upgrade — so it must read as absent rather than as anything.
    func testADaemonThatAnnouncesNoVersionReadsAsAbsent() {
        XCTAssertNil(
            FileDropServiceManager.parseAnnouncedVersion(
                fromLogLine: "dropd: listening on 0.0.0.0:9002 (drop dir /Users/x/Downloads)",
            ),
        )
        XCTAssertNil(FileDropServiceManager.parseAnnouncedVersion(fromLogLine: "dropd: accept failed: EMFILE"))
    }

    /// The marker is searched from the END of the port marker, so a `(v` earlier in the line — a
    /// path, a program name — cannot win. And an empty one is not a version.
    func testTheSearchStartsAfterThePortAndAnEmptyVersionIsNotOne() {
        XCTAssertEqual(
            AnnouncedVersion.directlyAfter(
                "dropd: listening on 0.0.0.0:",
                in: "/opt/(vendor)/bin/dropd: listening on 0.0.0.0:9002 (v2.0.0, drop dir /tmp)",
            ),
            "2.0.0",
        )
        XCTAssertNil(
            AnnouncedVersion.directlyAfter(
                "dropd: listening on 0.0.0.0:",
                in: "dropd: listening on 0.0.0.0:9002 (v, drop dir /tmp)",
            ),
        )
    }

    /// The port parse must survive the version's arrival — `AnnouncedPort` takes the digits as a
    /// run directly after the marker, and the version sits past them.
    func testTheAddedVersionDoesNotDisturbThePortParse() {
        XCTAssertEqual(
            FileDropServiceManager.parseAnnouncedPort(
                fromLogLine: "dropd: listening on 0.0.0.0:9002 (v0.1.0, drop dir /tmp)",
            ),
            9002,
        )
    }

    // MARK: - The decode

    /// One case per `state` the door answers, because each one decodes a DIFFERENT set of keys —
    /// and a decode that silently dropped a number would report a stale daemon with no numbers in
    /// its line, which reads as noise and gets ignored.
    func testEachVerdictTheDoorAnswersDecodesWithItsNumbers() {
        XCTAssertEqual(
            SidecarVersionReport(tool: "slopdesk-dropd", running: "0.1.0", onDisk: "0.1.0").verdict,
            .current("0.1.0"),
        )
        XCTAssertEqual(
            SidecarVersionReport(tool: "slopdesk-dropd", running: "0.1.0", onDisk: "0.2.0").verdict,
            .stale(running: "0.1.0", onDisk: "0.2.0"),
        )
        guard case .unknown = SidecarVersionReport(
            tool: "slopdesk-dropd", running: nil, onDisk: "0.2.0",
        ).verdict else {
            XCTFail("a daemon that reports no version is unknown, not current")
            return
        }
    }

    /// `restartable` and `policy` come across as decided rather than re-derived, so this asserts the
    /// CROSSING — that the flag and the name survive the door — not the rule behind them.
    func testThePolicyAndTheRestartFlagArriveFromTheDoor() {
        let dropd = SidecarVersionReport(tool: "slopdesk-dropd", running: "0.1.0", onDisk: "0.2.0")
        XCTAssertEqual(dropd.policy, .automatic)
        XCTAssertTrue(dropd.restartable)

        let superd = SidecarVersionReport(tool: "slopdesk-superd", running: "0.1.0", onDisk: "0.2.0")
        XCTAssertEqual(superd.policy, .operatorChoice)
        XCTAssertFalse(superd.restartable)
        XCTAssertFalse(superd.summary.isEmpty, "the log line is worded by the crate, not here")
    }

    /// The door refuses an empty tool, and the report it cannot get must be `unknown` and NOT
    /// restartable — the two failure modes this type must never have are "reported as current" and
    /// "restarted on a guess".
    func testAnAnswerTheDoorRefusesIsUnknownAndNeverRestartable() {
        let report = SidecarVersionReport(tool: "", running: "0.1.0", onDisk: "0.2.0")
        guard case .unknown = report.verdict else {
            XCTFail("a door that did not answer is unknown")
            return
        }
        XCTAssertFalse(report.restartable)
        XCTAssertEqual(report.policy, .operatorChoice)
    }

    // MARK: - The `--version` spawn

    /// The spawn is the Swift half: a real binary, run, its banner read. `/bin/echo` is not a
    /// slopdesk tool, which is the point — the contract is positional, so any program that prints
    /// two fields exercises the same path hostd uses on `slopdesk-dropd`.
    func testTheInstalledVersionComesFromRunningTheBinary() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-version-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'slopdesk-dropd 9.9.9 (protocol 1)'\n".write(
            to: script, atomically: true, encoding: .utf8,
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        XCTAssertEqual(SidecarVersionAudit.installedVersion(ofBinaryAt: script.path), "9.9.9")
        XCTAssertNil(
            SidecarVersionAudit.installedVersion(ofBinaryAt: script.path + ".gone"),
            "a binary that is not there reports no version rather than trapping",
        )
    }
}
