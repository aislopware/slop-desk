import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// ``AndroidServiceManager`` against FAKE seams — the Swift side of PATH 22 after the bridge itself
/// moved to `rust/slopdesk-androidd`.
///
/// What is left here is exactly the lifecycle: spawn-or-adopt once, learn the port from the daemon's
/// own announce line, probe, latch, respawn a daemon that died, and let go rather than kill on a host
/// restart. Everything the bridge DOES — the `adb` orchestration, the catalogue, the scrcpy handshake
/// and the byte pump — is tested in the Rust crate, which is the only place it exists.
///
/// Hang-safety is the whole shape of this suite: the real manager execs a daemon that dials `adb` and
/// connects sockets to devices. None of that may happen in a unit test, so the locator, spawner and
/// readiness probe are injected on every construction.
final class AndroidServiceManagerTests: XCTestCase {
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

        /// Letting go leaves `running` alone on purpose: superd still holds the daemon, so a fake
        /// that flipped it would hide the very difference this seam exists to make.
        func relinquish() {
            lock.lock()
            defer { lock.unlock() }
            relinquished = true
        }

        /// The daemon died on its own — no `adb` on the host, a crash, an operator's kill. No
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

        /// The line the real daemon prints once its listener is bound — including the tail naming
        /// the toolchain, which the parser has to step over.
        func announcePort(_ port: UInt16, instance: Int = 0) {
            lineSinks[instance](
                "androidd: listening on 0.0.0.0:\(port) (adb /usr/bin/adb, emulator missing, "
                    + "scrcpy-server /repo/ThirdParty/tools/vendor/scrcpy-server)",
            )
        }
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

    private func makeManager(
        spawner: FakeSpawner,
        binary: String? = "/fake/slopdesk-androidd",
        probe: @escaping @Sendable (UInt16) -> Bool = { _ in true },
    ) -> AndroidServiceManager {
        AndroidServiceManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in
                try spawner.spawn(binary: bin, arguments: args, onLine: onLine)
            },
            readinessProbe: probe,
            probeInterval: .zero,
        )
    }

    // MARK: - Lifecycle

    func testEnsureSpawnsOnceAndReportsStartingUntilPortKnown() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)

        // A second pane's request rides the SAME daemon — one host has one `adb` server and one set
        // of AVDs, so there is nothing to scope.
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testAnnouncedPortFlipsToReadyWhenProbeSucceeds() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()

        spawner.announcePort(51234)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 51234))
        XCTAssertEqual(manager.servedPort, 51234)
    }

    func testFailedProbeStaysStartingWithPort() {
        // The learned port rides along even while starting — it is the honest answer to "where will
        // it be", and the client gates on the STATE.
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, probe: { _ in false })
        _ = manager.ensure()
        spawner.announcePort(4444)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 4444))
    }

    func testReadinessLatches() {
        // A listening bridge is never re-probed: once ready, a probe that starts failing (a transient
        // connect refusal while a mirror saturates the daemon) must not flap the panel to a spinner.
        let spawner = FakeSpawner()
        let probeAnswer = LockedFlag(true)
        let manager = makeManager(spawner: spawner, probe: { _ in probeAnswer.value })
        _ = manager.ensure()
        spawner.announcePort(6000)
        XCTAssertEqual(manager.ensure().state, MetadataCodec.ServiceState.ready)

        probeAnswer.value = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 6000))
    }

    /// A host with no `adb` exits the daemon at startup. That reads here as a child that stopped
    /// running, and the next `ensure` respawns — cheap, and self-healing the moment an SDK appears.
    func testDeadDaemonRespawnsAndTheStalePortIsDropped() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        spawner.announcePort(7000)
        XCTAssertEqual(manager.ensure().port, 7000)

        spawner.handles[0].exitSilently()
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 2)
        XCTAssertNil(manager.servedPort)

        spawner.announcePort(7001, instance: 1)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 7001))
    }

    /// A dying daemon's last line must not be written onto the record of the one that replaced it —
    /// the panel would advertise a port nothing is listening on, and the mirror would fail with no
    /// log line saying why.
    func testAStaleAnnounceCannotPoisonTheFreshDaemon() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        spawner.handles[0].exitSilently()
        _ = manager.ensure()

        spawner.announcePort(8000, instance: 0)
        XCTAssertNil(manager.servedPort)

        spawner.announcePort(8001, instance: 1)
        XCTAssertEqual(manager.servedPort, 8001)
    }

    func testMissingBinaryIsUnavailableAndAFailedSpawnIsNot() {
        // `unavailable` means there is no `slopdesk-androidd` on this machine — the one case the
        // panel renders an install hint for.
        let spawner = FakeSpawner()
        let absent = makeManager(spawner: spawner, binary: nil)
        XCTAssertEqual(absent.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))
        XCTAssertEqual(spawner.spawnCount, 0)

        // A spawn that THREW is transient (superd unreachable, a thread limit), so it reports
        // `starting` and the client's poll retries. Reporting `unavailable` would render the
        // install-a-missing-tool hint for a host where nothing is missing.
        spawner.throwsOnSpawn = true
        let broken = makeManager(spawner: spawner)
        XCTAssertEqual(broken.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
    }

    // MARK: - Letting go versus ending

    /// The line that used to be a `shutdown()` and is the reason a host edit killed every mirror.
    func testRelinquishKeepsTheDaemonAndShutdownEndsIt() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        manager.relinquish()

        XCTAssertTrue(spawner.handles[0].relinquished)
        XCTAssertFalse(spawner.handles[0].terminated)
        XCTAssertNil(manager.servedPort)

        let deliberate = makeManager(spawner: spawner)
        _ = deliberate.ensure()
        deliberate.shutdown()
        XCTAssertTrue(spawner.handles[1].terminated)
    }

    // MARK: - argv and the announce line

    func testLaunchArgumentsPassTheVendoredPathsRatherThanLettingTheDaemonWalkForThem() {
        // `VendoredTools` owns the repo-root walk, in one language. Passing its answer down also
        // means a daemon adopted from a differently-configured hostd cannot silently resolve to
        // different tools.
        XCTAssertEqual(
            AndroidServiceManager.launchArguments(
                vendoredBinDirectory: "/repo/ThirdParty/tools/.prefix/bin",
                scrcpyServerJar: "/repo/ThirdParty/tools/vendor/scrcpy-server",
            ),
            [
                "--port", "0",
                "--vendored-bin", "/repo/ThirdParty/tools/.prefix/bin",
                "--vendored-jar", "/repo/ThirdParty/tools/vendor/scrcpy-server",
            ],
        )
        // Outside a checkout there is nothing to pass, and the daemon still runs — it just searches
        // `PATH` and the SDK roots alone.
        XCTAssertEqual(
            AndroidServiceManager.launchArguments(vendoredBinDirectory: nil, scrcpyServerJar: nil),
            ["--port", "0"],
        )
    }

    /// `--port 0` is deliberate: unlike dropd's `terminalPort + 2`, the bridge port is whatever the
    /// OS gave the daemon, so there is no wanted port for an adopted survivor to disagree with.
    func testTheDaemonIsSpawnedOnAnEphemeralPort() {
        let spawner = FakeSpawner()
        _ = makeManager(spawner: spawner).ensure()
        XCTAssertEqual(Array(spawner.lastArguments.prefix(2)), ["--port", "0"])
    }

    func testAnnounceParsingTakesTheDigitRunAndRejectsEverythingElse() {
        // A future build may add words after the port; changing the MARKER instead fails
        // `scripts/check-supervisor.sh`, which compares this string against `server.rs`.
        XCTAssertEqual(
            AndroidServiceManager.parseAnnouncedPort(
                fromLogLine: "androidd: listening on 0.0.0.0:51234 (adb /usr/bin/adb, emulator missing)",
            ),
            51234,
        )
        XCTAssertNil(AndroidServiceManager.parseAnnouncedPort(fromLogLine: "androidd: starting"))
        // dropd's line is the same shape with a different marker, and must not be read as this one.
        XCTAssertNil(
            AndroidServiceManager.parseAnnouncedPort(fromLogLine: "dropd: listening on 0.0.0.0:9000"),
        )
        // A port of zero is the daemon echoing what it was ASKED for, not what it bound.
        XCTAssertNil(
            AndroidServiceManager.parseAnnouncedPort(fromLogLine: "androidd: listening on 0.0.0.0:0"),
        )
        XCTAssertNil(
            AndroidServiceManager.parseAnnouncedPort(fromLogLine: "androidd: listening on 0.0.0.0:x"),
        )
    }
}
