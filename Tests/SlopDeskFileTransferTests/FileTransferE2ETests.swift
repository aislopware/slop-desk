import XCTest
@testable import SlopDeskFileTransfer

/// An in-memory sink capturing received bytes per transfer — the fake the server serve loop writes
/// to (hang-safety: no real disk in the serve path). Optionally fails a chosen phase to prove the
/// server's per-transfer failure handling.
private final class FakeSink: FileDropSink, @unchecked Sendable {
    let lock = NSLock()
    var open: [UInt32: String] = [:]
    var buffers: [UInt32: Data] = [:]
    var finalized: [UInt32: Data] = [:]
    var aborted: Set<UInt32> = []
    var failFinalize = false

    func open(transferId: UInt32, name: String, size _: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        open[transferId] = name
        buffers[transferId] = Data()
    }

    func write(transferId: UInt32, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard buffers[transferId] != nil else { throw FileDropSinkError.notOpen }
        buffers[transferId, default: Data()].append(data)
    }

    func finalize(transferId: UInt32) throws {
        if failFinalize { throw FileDropSinkError.ioFailed("boom") }
        lock.lock()
        defer { lock.unlock() }
        finalized[transferId] = buffers[transferId]
    }

    func abort(transferId: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        aborted.insert(transferId)
    }
}

private actor EventLog {
    private(set) var events: [FileUploadEvent] = []
    func add(_ event: FileUploadEvent) { events.append(event) }
}

final class FileTransferE2ETests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopdesk-ft-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A real `try` (not `try?`) so SwiftFormat keeps `throws` — an @objc override of the throwing
        // XCTest method must stay throwing. `dir` is always created in setUp, so the remove succeeds.
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: url)
        return url
    }

    /// Runs a server serve loop and a client upload against a wired loopback pair, returning the
    /// events the client emitted once both sides settle.
    private func runUpload(files: [URL], sink: FakeSink) async -> [FileUploadEvent] {
        let (serverChannel, clientChannel) = LoopbackFileTransferChannel.pair()
        let server = FileTransferServer(port: 0, makeSink: { sink })
        let log = EventLog()

        async let serving: Void = server.serve(channel: serverChannel, sink: sink)
        let client = FileTransferClient()
        await client.run(files: files, over: clientChannel) { event in
            Task { await log.add(event) }
        }
        await serving
        // Let the trailing event Tasks drain.
        try? await Task.sleep(nanoseconds: 50_000_000)
        return await log.events
    }

    func testSingleFileRoundTrip() async throws {
        let url = try makeFile("payload.bin", bytes: 700 * 1024) // spans multiple 256 KiB chunks
        let expected = try Data(contentsOf: url)
        let sink = FakeSink()

        let events = await runUpload(files: [url], sink: sink)

        XCTAssertEqual(sink.finalized[0], expected)
        XCTAssertEqual(sink.open[0], "payload.bin")
        XCTAssertTrue(events.contains(.started(id: 0, name: "payload.bin", totalBytes: UInt64(expected.count))))
        XCTAssertTrue(events.contains(.completed(id: 0)))
    }

    func testZeroByteFile() async throws {
        let url = try makeFile("empty.txt", bytes: 0)
        let sink = FakeSink()
        let events = await runUpload(files: [url], sink: sink)
        XCTAssertEqual(sink.finalized[0], Data())
        XCTAssertTrue(events.contains(.completed(id: 0)))
    }

    func testMultipleFiles() async throws {
        let a = try makeFile("a.txt", bytes: 10)
        let b = try makeFile("b.txt", bytes: 300 * 1024)
        let expectedA = try Data(contentsOf: a)
        let expectedB = try Data(contentsOf: b)
        let sink = FakeSink()

        let events = await runUpload(files: [a, b], sink: sink)

        XCTAssertEqual(sink.finalized[0], expectedA)
        XCTAssertEqual(sink.finalized[1], expectedB)
        XCTAssertTrue(events.contains(.completed(id: 0)))
        XCTAssertTrue(events.contains(.completed(id: 1)))
    }

    func testProgressReachesTotal() async throws {
        let url = try makeFile("p.bin", bytes: 600 * 1024)
        let total = UInt64(600 * 1024)
        let sink = FakeSink()

        let events = await runUpload(files: [url], sink: sink)

        let progresses = events.compactMap { event -> UInt64? in
            if case let .progress(_, sentBytes, totalBytes) = event {
                XCTAssertEqual(totalBytes, total)
                return sentBytes
            }
            return nil
        }
        XCTAssertFalse(progresses.isEmpty)
        XCTAssertEqual(progresses.last, total)
        // Monotonic non-decreasing.
        XCTAssertEqual(progresses, progresses.sorted())
    }

    func testFinalizeFailureSurfacesAsFailed() async throws {
        let url = try makeFile("x.bin", bytes: 1024)
        let sink = FakeSink()
        sink.failFinalize = true

        let events = await runUpload(files: [url], sink: sink)

        XCTAssertNil(sink.finalized[0])
        XCTAssertTrue(sink.aborted.contains(0))
        XCTAssertFalse(events.contains(.completed(id: 0)))
        XCTAssertTrue(events.contains { if case .failed(0, _) = $0 { true } else { false } })
    }
}
