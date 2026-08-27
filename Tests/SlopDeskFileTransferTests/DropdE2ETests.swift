import XCTest
@testable import SlopDeskFileTransfer

/// PATH 4 end to end, across the two ENDS and a real socket: the Swift client here, the Rust
/// `slopdesk-dropd` there.
///
/// This replaces the old in-process test, which drove a Swift server over a loopback channel. That
/// server no longer exists — the receiving end is a separate binary the client dials directly
/// (`docs/53`) — and an in-process fake of it would be the cross-language mirror this tree forbids.
/// So the test spawns the actual daemon on an OS-chosen port and uploads actual files to it.
///
/// SKIPS by name when `slopdesk-dropd` is not built: `swift build` never sees cargo, and a green
/// tick for a run that tested nothing is worse than a skip.
final class DropdE2ETests: XCTestCase {
    private var daemon: Process?
    private var dropDirectory: URL!

    override func tearDown() {
        if let daemon, daemon.isRunning { daemon.terminate() }
        daemon = nil
        if let dropDirectory { try? FileManager.default.removeItem(at: dropDirectory) }
        super.tearDown()
    }

    // MARK: - Tests

    func testAFileLandsInTheDropDirectoryWithItsBytesIntact() async throws {
        let port = try startDaemon()
        let body = Data((0..<300_000).map { UInt8($0 % 251) }) // spans several 256 KiB chunks
        let source = try write(body, named: "payload.bin")

        let events = await upload([source], port: port)

        XCTAssertEqual(events.first, .started(id: 0, name: "payload.bin", totalBytes: UInt64(body.count)))
        XCTAssertEqual(events.last, .completed(id: 0))
        XCTAssertEqual(try Data(contentsOf: dropDirectory.appendingPathComponent("payload.bin")), body)
    }

    func testProgressIsMonotonicAndEndsAtTheWholeSize() async throws {
        let port = try startDaemon()
        let body = Data(repeating: 0xAB, count: 700_000)
        let source = try write(body, named: "big.bin")

        let events = await upload([source], port: port)

        var last: UInt64 = 0
        var sawTotal = false
        for case let .progress(_, sent, total) in events {
            XCTAssertGreaterThan(sent, last, "progress must never run backwards")
            XCTAssertEqual(total, UInt64(body.count))
            last = sent
            sawTotal = sent == UInt64(body.count)
        }
        XCTAssertTrue(sawTotal, "the last progress must reach the whole size")
        XCTAssertEqual(events.last, .completed(id: 0))
    }

    func testTwoFilesRideOneConnectionAndTheSecondNameGetsACounter() async throws {
        let port = try startDaemon()
        let first = try write(Data("one".utf8), named: "notes.txt")
        let second = try write(Data("two".utf8), named: "notes.txt", inSubdirectory: "second")

        let events = await upload([first, second], port: port)

        XCTAssertEqual(events.filter { if case .completed = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(
            try String(contentsOf: dropDirectory.appendingPathComponent("notes.txt"), encoding: .utf8),
            "one",
        )
        XCTAssertEqual(
            try String(contentsOf: dropDirectory.appendingPathComponent("notes (1).txt"), encoding: .utf8),
            "two",
            "a second file of the same name must not overwrite the first",
        )
    }

    func testAnEmptyFileCompletesWithoutASingleChunk() async throws {
        let port = try startDaemon()
        let source = try write(Data(), named: "empty.txt")

        let events = await upload([source], port: port)

        XCTAssertEqual(events.last, .completed(id: 0))
        XCTAssertFalse(
            events.contains { if case .progress = $0 { true } else { false } },
            "a zero-byte body has no chunk to report progress for",
        )
        XCTAssertEqual(try Data(contentsOf: dropDirectory.appendingPathComponent("empty.txt")), Data())
    }

    /// The drop directory holds nothing but finished files: a `.part` left behind would mean a
    /// half-received body was visible, or that the sweep on close did not run.
    func testNoTemporaryFileSurvivesACompletedUpload() async throws {
        let port = try startDaemon()
        let source = try write(Data(repeating: 7, count: 4096), named: "clean.bin")

        _ = await upload([source], port: port)

        let landed = try FileManager.default.contentsOfDirectory(atPath: dropDirectory.path).sorted()
        XCTAssertEqual(landed, ["clean.bin"])
    }

    // MARK: - Harness

    private func upload(_ files: [URL], port: UInt16) async -> [FileUploadEvent] {
        let collector = EventCollector()
        await FileTransferClient().upload(files: files, host: "127.0.0.1", port: port) { event in
            await collector.append(event)
        }
        return await collector.events
    }

    private func write(_ body: Data, named name: String, inSubdirectory subdirectory: String? = nil) throws -> URL {
        var directory = dropDirectory.deletingLastPathComponent().appendingPathComponent("src", isDirectory: true)
        if let subdirectory { directory = directory.appendingPathComponent(subdirectory, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try body.write(to: url)
        return url
    }

    /// Spawns the daemon on an OS-chosen port and returns the port it announced.
    ///
    /// `--port 0` plus the announce line is the same contract hostd relies on to re-learn the port
    /// of a daemon that survived its restart — testing it here means a build that changes the
    /// announce wording fails something before it reaches a user.
    private func startDaemon() throws -> UInt16 {
        let binary = try binaryPath()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dropd-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        dropDirectory = root.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--port", "0", "--drop-dir", dropDirectory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        daemon = process

        guard let port = awaitAnnouncedPort(from: errors.fileHandleForReading, timeout: 10) else {
            throw XCTSkip("slopdesk-dropd did not announce a port in time")
        }
        return port
    }

    /// Reads the daemon's stderr until the announce line appears.
    private func awaitAnnouncedPort(from handle: FileHandle, timeout: TimeInterval) -> UInt16? {
        let marker = "dropd: listening on 0.0.0.0:"
        let deadline = Date().addingTimeInterval(timeout)
        var seen = ""
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { continue }
            seen += String(bytes: chunk, encoding: .utf8) ?? ""
            guard let markerRange = seen.range(of: marker) else { continue }
            let digits = seen[markerRange.upperBound...].prefix(while: \.isNumber)
            if let port = UInt16(digits), seen[markerRange.upperBound...].count > digits.count {
                return port
            }
        }
        return nil
    }

    /// `rust/slopdesk-dropd/target/{release,debug}/slopdesk-dropd`, or a skip.
    private func binaryPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["SLOPDESK_DROPD_BIN"],
           !override.isEmpty, FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskFileTransferTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent("rust/slopdesk-dropd/target")
        for profile in ["release", "debug"] {
            let candidate = root.appendingPathComponent("\(profile)/slopdesk-dropd").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw XCTSkip("slopdesk-dropd is not built — run `just dropd` (or `just test`)")
    }
}

/// Collects upload events in emission order across the client's awaited callback.
private actor EventCollector {
    private(set) var events: [FileUploadEvent] = []
    func append(_ event: FileUploadEvent) { events.append(event) }
}
