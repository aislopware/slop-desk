import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// ``SimulatorServerManager`` against FAKE seams. The hang-safety rule is the whole shape of this
/// suite: the real manager execs `baguette` (which dlopens CoreSimulator and enumerates the host's
/// device sets) and connects a socket to it. Neither may happen in a unit test, so the locator,
/// spawner and readiness probe are injected on every construction.
final class SimulatorServerManagerTests: XCTestCase {
    private final class FakeHandle: HostServiceProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var terminated = false
        private(set) var relinquished = false

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

        /// Letting go leaves `running` alone on purpose: superd still holds the child, so a fake
        /// that flipped it would hide the very difference this seam exists to make.
        func relinquish() {
            lock.lock()
            defer { lock.unlock() }
            relinquished = true
        }

        /// The child died on its own (crash, Xcode mismatch, killed by the operator) — no
        /// `terminate` call, so `isRunning` flips without the manager being told.
        func exitSilently() {
            lock.lock()
            defer { lock.unlock() }
            running = false
        }
    }

    private final class FakeSpawner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spawnCount = 0
        private(set) var lastArguments: [String] = []
        private(set) var handles: [FakeHandle] = []
        private(set) var lineSinks: [@Sendable (String) -> Void] = []
        /// When true, the exec itself fails (a binary that is present but unrunnable).
        var throwsOnSpawn = false

        func spawn(
            binary _: String, arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        ) throws -> any HostServiceProcessHandle {
            lock.lock()
            defer { lock.unlock() }
            if throwsOnSpawn { throw CocoaError(.fileNoSuchFile) }
            spawnCount += 1
            lastArguments = arguments
            let handle = FakeHandle()
            handles.append(handle)
            lineSinks.append(onLine)
            return handle
        }

        /// The Hummingbird line the real child prints once its listener is bound.
        func announcePort(_ port: UInt16, instance: Int = 0) {
            lineSinks[instance](
                "info Hummingbird : [HummingbirdCore] Server started and listening on 0.0.0.0:\(port)",
            )
        }
    }

    private func makeManager(
        spawner: FakeSpawner,
        binary: String? = "/fake/baguette",
        probe: @escaping @Sendable (UInt16) -> Bool = { _ in true },
    ) -> SimulatorServerManager {
        SimulatorServerManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in try spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            probeInterval: .zero,
        )
    }

    // MARK: Lifecycle

    func testEnsureSpawnsOnceAndReportsStartingUntilPortKnown() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)

        // A second pane's request rides the SAME child — simulators are a machine resource.
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testAnnouncedPortFlipsToReadyWhenProbeSucceeds() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()

        spawner.announcePort(54593)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 54593))
    }

    func testFailedProbeStaysStartingWithPort() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, probe: { _ in false })
        _ = manager.ensure()
        spawner.announcePort(4444)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 4444))
    }

    func testReadinessLatches() {
        // A listening server is never re-probed: once ready, a probe that starts failing (a
        // transient connect refusal under load) must not flap the panel back to a spinner.
        let spawner = FakeSpawner()
        let probeAnswer = LockedFlag(true)
        let manager = makeManager(spawner: spawner, probe: { _ in probeAnswer.value })
        _ = manager.ensure()
        spawner.announcePort(6000)
        XCTAssertEqual(manager.ensure().state, .ready)

        probeAnswer.value = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 6000))
    }

    func testDeadChildRespawns() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        spawner.announcePort(5555)
        XCTAssertEqual(manager.ensure().state, .ready)

        spawner.handles[0].exitSilently()
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    func testStaleSpawnLogLineCannotPoisonTheRespawn() {
        // The dead child's pipe can flush its old listening line AFTER the respawn; the fresh
        // instance must learn ITS OWN port. Loading the stale one would point the panel's relay at
        // a closed port with no way back except another respawn.
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        spawner.handles[0].exitSilently()
        _ = manager.ensure()
        XCTAssertEqual(spawner.spawnCount, 2)

        spawner.announcePort(1111, instance: 0)
        XCTAssertEqual(manager.ensure().port, 0, "stale line ignored")
        spawner.announcePort(2222, instance: 1)
        XCTAssertEqual(manager.ensure().port, 2222)
    }

    func testMissingBinaryIsUnavailableAndSpawnsNothing() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, binary: nil)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testFailedExecIsUnavailableAndRetriesLater() {
        // A present-but-unrunnable binary (a broken Homebrew link, a quarantined build) throws out
        // of the spawner. That must read `unavailable` — same surface as "not installed" — and must
        // NOT record a phantom instance, so a later ensure tries again.
        let spawner = FakeSpawner()
        spawner.throwsOnSpawn = true
        let manager = makeManager(spawner: spawner)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))

        spawner.throwsOnSpawn = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testShutdownTerminatesAndAllowsAFreshStart() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        manager.shutdown()
        XCTAssertTrue(spawner.handles[0].terminated)

        _ = manager.ensure()
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    func testShutdownWithoutAnInstanceIsHarmless() {
        let spawner = FakeSpawner()
        makeManager(spawner: spawner).shutdown()
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    // MARK: Launch arguments

    func testLaunchArgumentsAskForAnOSChosenPortOnAllInterfaces() {
        // Port 0 is what makes the log-line parse necessary AND removes the pre-bind race; the
        // `0.0.0.0` bind is what lets a mesh client reach it at all.
        XCTAssertEqual(SimulatorServerManager.launchArguments(), ["serve", "--port", "0", "--host", "0.0.0.0"])
    }

    // MARK: Port parsing

    func testParsesTheHummingbirdLine() {
        XCTAssertEqual(
            SimulatorServerManager.parseListeningPort(
                fromLogLine:
                "2026-08-04T09:00:00+0000 info Hummingbird : [HummingbirdCore] Server started and listening on 0.0.0.0:54593",
            ),
            54593,
        )
    }

    func testRejectsTheServersOwnPortZeroBanner() {
        // `baguette` echoes the port it was ASKED for, which under `--port 0` is literally `0`.
        // Accepting it would latch the instance on a port that can never be probed.
        XCTAssertNil(
            SimulatorServerManager.parseListeningPort(
                fromLogLine: "[baguette] listening on http://0.0.0.0:0/simulators",
            ),
        )
    }

    func testParsesBracketedIPv6AndURLForms() {
        XCTAssertEqual(
            SimulatorServerManager.parseListeningPort(fromLogLine: "listening on [::1]:8080"), 8080,
        )
        XCTAssertEqual(
            SimulatorServerManager.parseListeningPort(
                fromLogLine: "listening on http://0.0.0.0:7001/simulators",
            ),
            7001,
        )
    }

    func testIgnoresUnrelatedLines() {
        for line in [
            "",
            "listening on",
            "listening on 0.0.0.0:",
            "listening on 0.0.0.0:notaport",
            "Booted device 0.0.0.0:1234",
            "warning: could not connect to 127.0.0.1:9999",
        ] {
            XCTAssertNil(
                SimulatorServerManager.parseListeningPort(fromLogLine: line), "unexpected match: \(line)",
            )
        }
    }

    func testRejectsAPortAboveTheSixteenBitRange() {
        XCTAssertNil(SimulatorServerManager.parseListeningPort(fromLogLine: "listening on 0.0.0.0:70000"))
    }

    /// A `Sendable` box for a probe answer the test flips mid-run.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
}

/// ``HostSimulatorPerformer`` routing: verb 21 → the manager; every other verb → `nil` (fall
/// through to the read-only builder).
final class HostSimulatorPerformerTests: XCTestCase {
    private final class NeverExitingHandle: HostServiceProcessHandle, @unchecked Sendable {
        var isRunning: Bool { true }
        func terminate() {}
        func relinquish() {}
    }

    private func makeManager(binary: String? = "/fake/baguette") -> SimulatorServerManager {
        SimulatorServerManager(
            binaryLocator: { binary },
            spawner: { _, _, _ in NeverExitingHandle() },
            readinessProbe: { _ in false },
            probeInterval: .zero,
        )
    }

    // (WHICH verbs reach this performer is `metadata_admission::performer`'s answer and is pinned
    // in Rust — `the_side_effecting_verbs_never_reach_the_read_only_builder`. A Swift copy of that
    // set here was the second implementation of it.)

    func testEnsureAnswersTheEncodedEndpoint() throws {
        let response = HostSimulatorPerformer.response(
            requestID: 42, verb: MetadataVerb.ensureSimulatorServer.rawValue, payload: Data(),
            manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload) = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 42)
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        try XCTAssertEqual(
            MetadataCodec.decodeServiceEndpoint(payload),
            MetadataCodec.ServiceEndpoint(state: .starting, port: 0),
        )
    }

    func testUnavailableHostStillAnswersOK() throws {
        // No binary is a normal answer, not a failure: the panel renders the install hint. An
        // `error` status would make the client show "offline" and keep retrying blind.
        let response = HostSimulatorPerformer.response(
            requestID: 5, verb: MetadataVerb.ensureSimulatorServer.rawValue, payload: Data(),
            manager: makeManager(binary: nil),
        )
        guard case let .metadataResponse(_, status, payload) = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        try XCTAssertEqual(MetadataCodec.decodeServiceEndpoint(payload).state, .unavailable)
    }

    func testNonEmptyPayloadIsError() {
        // The request is defined as empty. Silently ignoring trailing bytes would let a future
        // client add a field that this host drops without either side noticing.
        let response = HostSimulatorPerformer.response(
            requestID: 9, verb: MetadataVerb.ensureSimulatorServer.rawValue,
            payload: Data([0x00]), manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload) = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 9)
        XCTAssertEqual(status, MetadataStatus.error.rawValue)
        XCTAssertTrue(payload.isEmpty)
    }
}
