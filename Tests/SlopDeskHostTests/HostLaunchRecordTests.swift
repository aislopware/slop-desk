import Foundation
import XCTest
@testable import SlopDeskHost

/// ``HostLaunchRecord`` — what a running hostd says about how it was started, so
/// `slopdesk-ops restart-hostd` can start it again identically.
///
/// The record is the last piece of `docs/51`: superd made a restart cheap, and this makes it
/// *easy*, which is the half that decides whether it actually gets done. Every assertion here is
/// something the script depends on being true.
///
/// Hang-safe by construction — this is a struct and a JSON file, no process and no socket.
final class HostLaunchRecordTests: XCTestCase {
    private var container: URL!

    override func setUp() {
        container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launch-record-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: container)
    }

    private var recordURL: URL { container.appendingPathComponent("hostd-launch.json") }

    private func sample(port: UInt16 = 7420, pid: Int32 = 4242) -> HostLaunchRecord {
        HostLaunchRecord(
            pid: pid, port: port, binary: "/opt/slopdesk/slopdesk-hostd",
            arguments: ["--port", "7420", "--inspector"],
            workingDirectory: "/Volumes/work/slop-desk",
            environment: ["SLOPDESK_BLOCKS": "1"],
            version: "0.3.0", startedAt: "2026-08-11T19:16:18Z",
        )
    }

    func testItRoundTripsThroughTheFile() {
        let original = sample()
        XCTAssertTrue(original.write(to: recordURL))
        XCTAssertEqual(HostLaunchRecord.read(from: recordURL), original)
    }

    /// The restart script reads this by hand when something has gone wrong, so it is pretty-printed
    /// and key-sorted rather than a single line.
    func testTheFileIsReadableByAPerson() throws {
        XCTAssertTrue(sample().write(to: recordURL))
        let text = try String(contentsOf: recordURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "the record must be pretty-printed, not one line")
        let pidIndex = try XCTUnwrap(text.range(of: "\"pid\""))
        let portIndex = try XCTUnwrap(text.range(of: "\"port\""))
        XCTAssertLessThan(pidIndex.lowerBound, portIndex.lowerBound, "keys must be sorted")
    }

    /// Writing must not depend on somebody having made the container first — hostd may be the very
    /// first SlopDesk process on a fresh machine.
    func testWritingCreatesTheContainer() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertTrue(sample().write(to: recordURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
    }

    /// Absence means "no hostd"; a record naming a dead pid means "one died badly". The script
    /// reports those differently, so removal has to actually remove.
    func testRemovingLeavesNothingBehind() {
        XCTAssertTrue(sample().write(to: recordURL))
        HostLaunchRecord.remove(at: recordURL)
        XCTAssertNil(HostLaunchRecord.read(from: recordURL))
    }

    func testReadingAnAbsentOrCorruptRecordIsNilRatherThanAThrow() throws {
        XCTAssertNil(HostLaunchRecord.read(from: recordURL))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: recordURL)
        XCTAssertNil(HostLaunchRecord.read(from: recordURL))
    }

    /// Only `SLOPDESK_*`. Everything else is the launching shell's business, and a blanket copy of
    /// the environment into a world-readable file is a habit worth not having.
    func testOnlyTheProjectsOwnVariablesAreRecorded() {
        let captured = HostLaunchRecord.configVariables(in: [
            "SLOPDESK_BLOCKS": "1",
            "SLOPDESK_AGENT_CONTROL": "1",
            "PATH": "/usr/bin",
            "AWS_SECRET_ACCESS_KEY": "not-going-in-a-file",
            "SLOPDESKISH": "prefix must be exact",
        ])
        XCTAssertEqual(captured, ["SLOPDESK_BLOCKS": "1", "SLOPDESK_AGENT_CONTROL": "1"])
    }

    /// `--port 0` mints an OS-chosen port that differs from the request, so the record must carry
    /// the port that was BOUND — the one thing the restart script cannot work out for itself.
    func testItRecordsTheBoundPortNotTheRequestedOne() {
        let record = HostLaunchRecord.current(
            boundPort: 51234,
            arguments: ["/opt/slopdesk/slopdesk-hostd", "--port", "0"],
            environment: [:],
            workingDirectory: "/tmp",
        )
        XCTAssertEqual(record.port, 51234)
        XCTAssertEqual(record.arguments, ["--port", "0"], "argv is preserved verbatim, port and all")
    }

    /// The binary is the one the KERNEL is running, absolute and symlink-free. `argv[0]` is usually
    /// the relative `.build/release/slopdesk-hostd`, and the script's identity check compares
    /// against `lsof -d txt`, which reports the physical path — two spellings of one file would read
    /// as two different daemons and the record would look stale.
    func testTheBinaryIsTheRunningExecutableNotArgv0() {
        let record = HostLaunchRecord.current(
            boundPort: 1, arguments: [".build/release/slopdesk-hostd"], environment: [:],
            workingDirectory: "/tmp",
        )
        XCTAssertTrue(record.binary.hasPrefix("/"), "must be absolute: \(record.binary)")
        XCTAssertFalse(record.binary.contains("/.build/release/"), "argv[0] was used verbatim")
        XCTAssertEqual(
            record.binary, URL(fileURLWithPath: record.binary).resolvingSymlinksInPath().path,
            "symlinks must already be resolved",
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: record.binary),
            "the recorded path must name a real executable — this test process's own",
        )
    }

    /// A pid is content here, never a path component (`docs/51` §1) — and it has to be the real one,
    /// because the script signals it.
    func testItRecordsThisProcess() {
        let record = HostLaunchRecord.current(boundPort: 1, environment: [:])
        XCTAssertEqual(record.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(record.isAlive)
    }

    func testAPidThatCannotExistIsNotAlive() {
        var record = sample()
        // Every process is < 2^31; this one is unallocatable, so `kill(2)` answers ESRCH.
        record.pid = Int32.max
        XCTAssertFalse(record.isAlive)
    }

    func testTheStartTimestampIsISO8601UTC() {
        let record = HostLaunchRecord.current(
            boundPort: 1, environment: [:], now: Date(timeIntervalSince1970: 1_770_000_000),
        )
        XCTAssertEqual(record.startedAt, "2026-02-02T02:40:00Z")
    }

    /// The container override moves this file with everything else, which is what lets a test (or a
    /// second host on one machine) have its own without a second name being invented.
    func testTheContainerOverrideMovesTheRecord() throws {
        let url = try XCTUnwrap(
            HostLaunchRecord.url(environment: ["SLOPDESK_APP_SUPPORT_DIR": container.path]),
        )
        XCTAssertEqual(url.deletingLastPathComponent().path, container.path)
        XCTAssertEqual(url.lastPathComponent, "hostd-launch.json")
    }
}
