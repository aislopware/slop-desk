import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// ``CodeServerManager`` against FAKE seams — the hang-safety rule extends here: no test may spawn
/// a real code-server (a multi-second Node boot, a network listener, a Homebrew dependency). The
/// spawner/locator/probe are all injected fakes; only `canonicalRoot` touches the real filesystem
/// (temp directories).
final class CodeServerManagerTests: XCTestCase {
    private final class FakeHandle: CodeServerProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var terminated = false

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            running = false
            terminated = true
        }

        func exitSilently() {
            lock.lock()
            defer { lock.unlock() }
            running = false
        }
    }

    /// A recording spawner whose handles + log-line sinks the test drives by hand.
    private final class FakeSpawner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spawnCount = 0
        private(set) var lastArguments: [String] = []
        private(set) var handles: [FakeHandle] = []
        private(set) var lineSinks: [@Sendable (String) -> Void] = []

        func spawn(
            binary _: String, arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        ) -> FakeHandle {
            lock.lock()
            defer { lock.unlock() }
            spawnCount += 1
            lastArguments = arguments
            let handle = FakeHandle()
            handles.append(handle)
            lineSinks.append(onLine)
            return handle
        }

        func announcePort(_ port: UInt16, instance: Int = 0) {
            lineSinks[instance]("[2026-08-02T00:00:00.000Z] info  HTTP server listening on http://0.0.0.0:\(port)/")
        }
    }

    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "code-server-manager-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func makeManager(
        spawner: FakeSpawner,
        binary: String? = "/fake/code-server",
        probe: @escaping @Sendable (UInt16) -> Bool = { _ in true },
    ) -> CodeServerManager {
        CodeServerManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            probeInterval: .zero,
        )
    }

    // MARK: Lifecycle

    func testEnsureSpawnsOnceAndReportsStartingUntilPortKnown() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)

        let first = manager.ensure(projectRoot: root)
        XCTAssertEqual(first, MetadataCodec.CodeServerEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)

        // Still starting (port unknown) — and no second spawn for the same root.
        let second = manager.ensure(projectRoot: root)
        XCTAssertEqual(second?.state, .starting)
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testAnnouncedPortFlipsToReadyWhenProbeSucceeds() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)

        spawner.announcePort(62636)
        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.CodeServerEndpoint(state: .ready, port: 62636),
        )
    }

    func testFailedProbeStaysStartingWithPort() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, probe: { _ in false })
        _ = manager.ensure(projectRoot: root)
        spawner.announcePort(4444)

        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.CodeServerEndpoint(state: .starting, port: 4444),
        )
    }

    func testDeadInstanceRespawns() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        spawner.announcePort(5555)
        XCTAssertEqual(manager.ensure(projectRoot: root)?.state, .ready)

        // The child self-reaped (idle timeout) — the next ensure respawns fresh.
        spawner.handles[0].exitSilently()
        let respawned = manager.ensure(projectRoot: root)
        XCTAssertEqual(respawned, MetadataCodec.CodeServerEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    func testDistinctRootsGetDistinctInstances() throws {
        let other = root + "-b"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: other) }

        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        _ = manager.ensure(projectRoot: other)
        XCTAssertEqual(spawner.spawnCount, 2)

        spawner.announcePort(1111, instance: 0)
        spawner.announcePort(2222, instance: 1)
        XCTAssertEqual(manager.ensure(projectRoot: root)?.port, 1111)
        XCTAssertEqual(manager.ensure(projectRoot: other)?.port, 2222)
    }

    func testTrailingSlashJoinsTheSameInstance() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        _ = manager.ensure(projectRoot: root + "/")
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testMissingBinaryIsUnavailableAndSpawnsNothing() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, binary: nil)
        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.CodeServerEndpoint(state: .unavailable, port: 0),
        )
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testInvalidRootsAreNil() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        XCTAssertNil(manager.ensure(projectRoot: "relative/path"))
        XCTAssertNil(manager.ensure(projectRoot: ""))
        XCTAssertNil(manager.ensure(projectRoot: root + "/does-not-exist"))
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testShutdownTerminatesEveryChild() throws {
        let other = root + "-b"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: other) }

        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        _ = manager.ensure(projectRoot: other)

        manager.shutdown()
        XCTAssertTrue(spawner.handles.allSatisfy(\.terminated))

        // A post-shutdown ensure starts over (no zombie record).
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(spawner.spawnCount, 3)
    }

    // MARK: Pure helpers

    func testLaunchArgumentsShape() {
        let arguments = CodeServerManager.launchArguments(projectRoot: "/tmp/proj")
        XCTAssertEqual(arguments.first, "--auth")
        XCTAssertTrue(arguments.contains("--bind-addr"))
        XCTAssertTrue(arguments.contains("0.0.0.0:0"))
        XCTAssertTrue(arguments.contains("--disable-workspace-trust"))
        XCTAssertEqual(arguments.last, "/tmp/proj")
    }

    func testParseListeningPort() {
        XCTAssertEqual(
            CodeServerManager.parseListeningPort(
                fromLogLine: "[2026-08-02T12:06:27.722Z] info  HTTP server listening on http://127.0.0.1:62636/",
            ),
            62636,
        )
        XCTAssertEqual(
            CodeServerManager.parseListeningPort(
                fromLogLine: "info  HTTP server listening on http://0.0.0.0:8080/",
            ),
            8080,
        )
        XCTAssertNil(CodeServerManager.parseListeningPort(fromLogLine: "info  Authentication is disabled"))
        XCTAssertNil(CodeServerManager.parseListeningPort(fromLogLine: "HTTP server listening on http://0.0.0.0:0/"))
        XCTAssertNil(CodeServerManager.parseListeningPort(fromLogLine: ""))
    }

    func testCanonicalRootNormalization() {
        XCTAssertEqual(CodeServerManager.canonicalRoot(root + "///"), root)
        XCTAssertEqual(CodeServerManager.canonicalRoot(root), root)
        XCTAssertNil(CodeServerManager.canonicalRoot("not-absolute"))
    }
}

/// ``HostCodeServerPerformer`` routing: verb 18 → the manager; every other verb → `nil`
/// (fall through to the read-only builder); malformed payloads → `.error`; a vanished root →
/// `.notFound`.
final class HostCodeServerPerformerTests: XCTestCase {
    private func makeManager(spawned: @escaping @Sendable () -> Void = {}) -> CodeServerManager {
        CodeServerManager(
            binaryLocator: { "/fake/code-server" },
            spawner: { _, _, _ in
                spawned()
                return NeverExitingHandle()
            },
            readinessProbe: { _ in false },
            probeInterval: .zero,
        )
    }

    private final class NeverExitingHandle: CodeServerProcessHandle, @unchecked Sendable {
        var isRunning: Bool { true }
        func terminate() {}
    }

    func testOtherVerbsFallThrough() {
        for verb in MetadataVerb.allCases where verb != .ensureCodeServer {
            XCTAssertNil(
                HostCodeServerPerformer.response(
                    requestID: 1, verb: verb.rawValue, payload: Data(), manager: makeManager(),
                ),
                "verb \(verb) must fall through to the read-only builder",
            )
        }
        XCTAssertNil(
            HostCodeServerPerformer.response(
                requestID: 1, verb: 250, payload: Data(), manager: makeManager(),
            ),
            "an unknown future verb must fall through (the builder answers unsupportedVerb)",
        )
    }

    func testMalformedPayloadIsError() {
        let relative = HostCodeServerPerformer.response(
            requestID: 7, verb: MetadataVerb.ensureCodeServer.rawValue,
            payload: Data("relative/path".utf8), manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload)? = relative else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 7)
        XCTAssertEqual(status, MetadataStatus.error.rawValue)
        XCTAssertTrue(payload.isEmpty)
    }

    func testMissingRootIsNotFound() {
        let response = HostCodeServerPerformer.response(
            requestID: 9, verb: MetadataVerb.ensureCodeServer.rawValue,
            payload: Data("/definitely/not/a/real/dir".utf8), manager: makeManager(),
        )
        guard case let .metadataResponse(_, status, _)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(status, MetadataStatus.notFound.rawValue)
    }

    func testValidRootAnswersOkWithEndpoint() throws {
        let root = NSTemporaryDirectory() + "performer-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let response = HostCodeServerPerformer.response(
            requestID: 3, verb: MetadataVerb.ensureCodeServer.rawValue,
            payload: Data(root.utf8), manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 3)
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        let endpoint = try MetadataCodec.decodeCodeServerEndpoint(payload)
        XCTAssertEqual(endpoint.state, .starting)
    }
}
