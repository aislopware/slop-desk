import Foundation
import XCTest
@testable import SlopDeskHost

/// The manager that holds `slopdesk-inspectord` under superd. Everything here runs through the
/// injected spawner — hang-safety: a unit test never forks the real daemon.
final class InspectorServiceManagerTests: XCTestCase {
    func testTheChildIsToldItsPortAndItsTranscriptOnArgv() {
        XCTAssertEqual(
            InspectorServiceManager.launchArguments(port: 9001, transcriptPath: "/tmp/session.jsonl"),
            ["--port", "9001", "--transcript", "/tmp/session.jsonl"],
        )
    }

    /// Without a transcript the daemon is still started — it binds, serves, and its replay window
    /// stays empty. That is the honest state of an inspector with nothing to inspect, and it is what
    /// lets a client connect before a `claude` has written its first line.
    func testNoTranscriptStillLaunchesTheDaemonWithJustAPort() {
        XCTAssertEqual(
            InspectorServiceManager.launchArguments(port: 9001, transcriptPath: nil),
            ["--port", "9001"],
        )
        XCTAssertEqual(
            InspectorServiceManager.launchArguments(port: 9001, transcriptPath: ""),
            ["--port", "9001"],
            "an empty path is an absent one, not a file called nothing",
        )
    }

    /// The marker is the one `rust/slopdesk-inspectord/src/server.rs` prints, and the port is a
    /// digit run — so a build that appends words after it keeps parsing.
    func testTheAnnouncedPortIsParsedOutOfTheChildsOwnLine() {
        XCTAssertEqual(
            InspectorServiceManager.parseAnnouncedPort(
                fromLogLine: "inspectord: listening on 0.0.0.0:9001 (transcript /tmp/session.jsonl)",
            ),
            9001,
        )
        XCTAssertEqual(
            InspectorServiceManager.parseAnnouncedPort(
                fromLogLine: "inspectord: listening on 0.0.0.0:9001 (no transcript)",
            ),
            9001,
        )
        XCTAssertNil(InspectorServiceManager.parseAnnouncedPort(fromLogLine: "inspectord: accept failed"))
        XCTAssertNil(InspectorServiceManager.parseAnnouncedPort(fromLogLine: "inspectord: listening on 0.0.0.0:x"))
    }

    func testAMachineWithNoBinaryReportsNoPortRatherThanSpawning() async {
        let spawns = Counter()
        let manager = InspectorServiceManager(
            spawner: { _, _, onLine in
                spawns.increment()
                return FakeHandle(onLine: onLine)
            },
            binaryLocator: { nil },
            announceTimeout: .milliseconds(100),
        )
        let served = await manager.start(port: 9001, transcriptPath: nil)
        XCTAssertNil(served)
        XCTAssertEqual(spawns.value, 0)
    }

    func testTheAnnouncedPortIsWhatStartReports() async {
        let manager = InspectorServiceManager(
            spawner: { _, _, onLine in
                onLine("inspectord: listening on 0.0.0.0:9001 (no transcript)")
                return FakeHandle(onLine: onLine)
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .seconds(1),
        )
        let served = await manager.start(port: 9001, transcriptPath: nil)
        XCTAssertEqual(served, 9001)
        XCTAssertEqual(manager.servedPort, 9001)
    }

    /// The adopt case that matters: superd still holds an inspectord from a hostd that ran on a
    /// different terminal port. Keeping it would leave this hostd advertising a port nothing listens
    /// on, so it is ended and a fresh one is started on the port this daemon actually serves.
    func testASurvivorOnTheWrongPortIsEndedAndRespawned() async {
        let handles = HandleLog()
        let spawns = Counter()
        let manager = InspectorServiceManager(
            spawner: { _, _, onLine in
                let attempt = spawns.increment()
                // The first spawn is the adopted survivor, announcing the OLD port.
                onLine("inspectord: listening on 0.0.0.0:\(attempt == 1 ? 7001 : 9001) (no transcript)")
                let handle = FakeHandle(onLine: onLine)
                handles.record(handle)
                return handle
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .milliseconds(300),
        )
        let served = await manager.start(port: 9001, transcriptPath: nil)
        XCTAssertEqual(served, 9001)
        XCTAssertEqual(spawns.value, 2, "the wrong-port survivor must be replaced, not kept")
        XCTAssertEqual(handles.first?.terminations, 1, "and it must be ENDED, not left on the old port")
    }

    /// A child that never says anything is not a service — it is refused rather than reported as
    /// serving a port that may not be bound.
    func testAChildThatNeverAnnouncesIsRefused() async {
        let manager = InspectorServiceManager(
            spawner: { _, _, onLine in FakeHandle(onLine: onLine) },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .milliseconds(120),
        )
        let served = await manager.start(port: 9001, transcriptPath: nil)
        XCTAssertNil(served)
    }

    /// A daemon shutdown RELINQUISHES: superd keeps inspectord, so the transcript tail and the
    /// session's replay window survive `make host-restart` — which is the whole reason the service
    /// moved. Only a deliberate stop terminates.
    func testRelinquishLetsTheDaemonLiveAndShutdownEndsIt() async {
        let handles = HandleLog()
        let manager = InspectorServiceManager(
            spawner: { _, _, onLine in
                onLine("inspectord: listening on 0.0.0.0:9001 (no transcript)")
                let handle = FakeHandle(onLine: onLine)
                handles.record(handle)
                return handle
            },
            binaryLocator: { "/usr/bin/true" },
            announceTimeout: .seconds(1),
        )
        _ = await manager.start(port: 9001, transcriptPath: nil)
        manager.relinquish()
        XCTAssertEqual(handles.first?.relinquishes, 1)
        XCTAssertEqual(handles.first?.terminations, 0)
        XCTAssertNil(manager.servedPort, "a relinquished daemon is no longer this hostd's to report")

        _ = await manager.start(port: 9001, transcriptPath: nil)
        manager.shutdown()
        XCTAssertEqual(handles.last?.terminations, 1)
    }
}

/// A stand-in for a supervised child: it counts what was done to it and forks nothing.
private final class FakeHandle: HostServiceProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = 0
    private var relinquished = 0

    init(onLine _: @Sendable (String) -> Void) {}

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
