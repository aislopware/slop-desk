import Foundation
import XCTest
@testable import SlopDeskHost

/// The manager that holds `slopdesk-dropd` under superd. Everything here runs through the injected
/// spawner — hang-safety: a unit test never forks the real daemon (the E2E in
/// `SlopDeskFileTransferTests` does, on a port the OS picks).
final class FileDropServiceManagerTests: XCTestCase {
    private let dropDirectory = URL(fileURLWithPath: "/tmp/slopdesk-drop-tests")

    func testTheChildIsToldItsPortAndItsDirectoryOnArgv() {
        let arguments = FileDropServiceManager.launchArguments(port: 9002, dropDirectory: dropDirectory)
        XCTAssertEqual(arguments, ["--port", "9002", "--drop-dir", "/tmp/slopdesk-drop-tests"])
    }

    /// The marker is the one `rust/slopdesk-dropd/src/server.rs` prints, and the port is a digit
    /// run — so a build that appends words after it keeps parsing.
    func testTheAnnouncedPortIsParsedOutOfTheChildsOwnLine() {
        XCTAssertEqual(
            FileDropServiceManager.parseAnnouncedPort(
                fromLogLine: "dropd: listening on 0.0.0.0:9002 (drop dir /Users/x/Downloads)",
            ),
            9002,
        )
        XCTAssertNil(FileDropServiceManager.parseAnnouncedPort(fromLogLine: "dropd: read failed: broken pipe"))
        XCTAssertNil(FileDropServiceManager.parseAnnouncedPort(fromLogLine: "dropd: listening on 0.0.0.0:x"))
    }

    func testAMachineWithNoBinaryReportsNoPortRatherThanSpawning() async {
        let spawns = Counter()
        let manager = FileDropServiceManager(
            spawner: { _, _, onLine in
                spawns.increment()
                return FakeHandle(announce: nil, onLine: onLine)
            },
            binaryLocator: { nil },
            announceTimeout: .milliseconds(100),
        )
        let served = await manager.start(port: 9002, dropDirectory: dropDirectory)
        XCTAssertNil(served)
        XCTAssertEqual(spawns.value, 0)
    }

    func testTheAnnouncedPortIsWhatStartReports() async {
        let manager = FileDropServiceManager(
            spawner: { _, _, onLine in
                onLine("dropd: listening on 0.0.0.0:9002 (drop dir /tmp)")
                return FakeHandle(announce: nil, onLine: onLine)
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .seconds(1),
        )
        let served = await manager.start(port: 9002, dropDirectory: dropDirectory)
        XCTAssertEqual(served, 9002)
        XCTAssertEqual(manager.servedPort, 9002)
    }

    /// The adopt case that matters: superd still holds a dropd from a hostd that ran on a different
    /// terminal port. Keeping it would leave this hostd advertising a port nothing listens on, so it
    /// is ended and a fresh one is started on the port this daemon actually serves.
    func testASurvivorOnTheWrongPortIsEndedAndRespawned() async {
        let handles = HandleLog()
        let spawns = Counter()
        let manager = FileDropServiceManager(
            spawner: { _, _, onLine in
                let attempt = spawns.increment()
                // The first spawn is the adopted survivor, announcing the OLD port.
                onLine("dropd: listening on 0.0.0.0:\(attempt == 1 ? 7002 : 9002) (drop dir /tmp)")
                let handle = FakeHandle(announce: nil, onLine: onLine)
                handles.record(handle)
                return handle
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .milliseconds(300),
        )
        let served = await manager.start(port: 9002, dropDirectory: dropDirectory)
        XCTAssertEqual(served, 9002)
        XCTAssertEqual(spawns.value, 2, "the wrong-port survivor must be replaced, not kept")
        let first = handles.first
        XCTAssertEqual(first?.terminations, 1, "and it must be ENDED, not left running on the old port")
    }

    /// A child that never says anything is not a service — it is refused rather than reported as
    /// serving a port that may not be bound.
    func testAChildThatNeverAnnouncesIsRefused() async {
        let manager = FileDropServiceManager(
            spawner: { _, _, onLine in FakeHandle(announce: nil, onLine: onLine) },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .milliseconds(120),
        )
        let served = await manager.start(port: 9002, dropDirectory: dropDirectory)
        XCTAssertNil(served)
    }

    /// A daemon shutdown RELINQUISHES: superd keeps dropd and the upload in flight survives the
    /// restart. Only a deliberate stop terminates. The distinction is the whole reason the service
    /// moved under superd, so it is pinned rather than assumed.
    func testRelinquishLetsTheDaemonLiveAndShutdownEndsIt() async {
        let handles = HandleLog()
        let manager = FileDropServiceManager(
            spawner: { _, _, onLine in
                onLine("dropd: listening on 0.0.0.0:9002 (drop dir /tmp)")
                let handle = FakeHandle(announce: nil, onLine: onLine)
                handles.record(handle)
                return handle
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .seconds(1),
        )
        _ = await manager.start(port: 9002, dropDirectory: dropDirectory)
        manager.relinquish()
        var handle = handles.first
        XCTAssertEqual(handle?.relinquishes, 1)
        XCTAssertEqual(handle?.terminations, 0)

        _ = await manager.start(port: 9002, dropDirectory: dropDirectory)
        manager.shutdown()
        handle = handles.last
        XCTAssertEqual(handle?.terminations, 1)
    }
}

/// A stand-in for a supervised child: it counts what was done to it and forks nothing.
private final class FakeHandle: HostServiceProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = 0
    private var relinquished = 0

    init(announce: String?, onLine: @Sendable (String) -> Void) {
        if let announce { onLine(announce) }
    }

    var isRunning: Bool { true }

    var terminations: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    var relinquishes: Int {
        lock.lock()
        defer { lock.unlock() }
        return relinquished
    }

    func terminate() {
        lock.lock()
        terminated += 1
        lock.unlock()
    }

    func relinquish() {
        lock.lock()
        relinquished += 1
        lock.unlock()
    }
}

/// Records the handles the spawner handed out. A lock rather than an actor: the spawner is a
/// synchronous callback, so an actor would need an unstructured `Task` and the test would then
/// assert against a log that may not have been written yet.
private final class HandleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FakeHandle] = []

    func record(_ handle: FakeHandle) {
        lock.lock()
        handles.append(handle)
        lock.unlock()
    }

    var first: FakeHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handles.first
    }

    var last: FakeHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handles.last
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Bumps the counter and returns the new value (which spawn attempt this is).
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
