import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// A bridge that binds nothing and answers whatever the test says — the real one opens an
/// `AF_UNIX` listener, which no unit test may do. File-scoped: both suites below inject it.
private final class FakeBridge: CodeBridgeRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var attached = false
    private(set) var startedPaths: [String] = []
    private(set) var opened: [String] = []
    private(set) var stopCount = 0

    /// Makes ``open(target:)`` answer `true`, as if a workbench window were attached.
    func attach() {
        lock.lock()
        attached = true
        lock.unlock()
    }

    func start(path: String) {
        lock.lock()
        startedPaths.append(path)
        lock.unlock()
    }

    func open(target: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        opened.append(target)
        return attached
    }

    /// The installed terminal runner, so a test can assert the manager forwarded it (the bridge is
    /// where it lives — the socket only looks it up when a `run` line arrives).
    private(set) var runner: (@Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome)?

    func setTerminalRunner(_ runner: (@Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome)?) {
        lock.lock()
        self.runner = runner
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}

/// ``CodeServerManager`` against FAKE seams — the hang-safety rule extends here: no test may spawn
/// a real code-server (a multi-second Node boot, a network listener, a Homebrew dependency). The
/// spawner/locator/probe are all injected fakes; only `canonicalRoot` touches the real filesystem
/// (temp directories).
final class CodeServerManagerTests: XCTestCase {
    private final class FakeHandle: HostServiceProcessHandle, @unchecked Sendable {
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

    /// A registry that already carries every bundled marketplace extension — the helper's default,
    /// so lifecycle tests exercise the post-install steady state (spawn on the first ensure).
    private static func satisfiedRegistry() -> Data? {
        let entries = CodeServerManager.bundledMarketplaceExtensions.map { ["identifier": ["id": $0]] }
        return try? JSONSerialization.data(withJSONObject: entries)
    }

    private func makeManager(
        spawner: FakeSpawner,
        binary: String? = "/fake/code-server",
        probe: @escaping @Sendable (UInt16) -> Bool = { _ in true },
        settingsSeeder: @escaping @Sendable () -> Void = {},
        cliRunner: @escaping CodeServerManager.CLIRunner = { _, _ in nil },
        installedExtensionsRegistry: @escaping CodeServerManager.InstalledExtensionsRegistry =
            CodeServerManagerTests.satisfiedRegistry,
        bridge: FakeBridge = FakeBridge(),
    ) -> CodeServerManager {
        // The seeder, CLI runner, registry reader, settings-file URL AND bridge are ALWAYS
        // injected — the default seams read/write the real user's `~/.local/share/code-server`,
        // exec a real binary or bind a real socket, none of which a test may touch.
        let settingsURL = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
        return CodeServerManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            settingsSeeder: settingsSeeder,
            cliRunner: cliRunner,
            installedExtensionsRegistry: installedExtensionsRegistry,
            settingsFileURL: { settingsURL },
            bridge: bridge,
            probeInterval: .zero,
            openRetryDelay: .zero,
        )
    }

    // MARK: Lifecycle

    func testEnsureSpawnsOnceAndReportsStartingUntilPortKnown() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)

        let first = manager.ensure(projectRoot: root)
        XCTAssertEqual(first, MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
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
            MetadataCodec.ServiceEndpoint(state: .ready, port: 62636),
        )
    }

    func testFailedProbeStaysStartingWithPort() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, probe: { _ in false })
        _ = manager.ensure(projectRoot: root)
        spawner.announcePort(4444)

        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.ServiceEndpoint(state: .starting, port: 4444),
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
        XCTAssertEqual(respawned, MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    func testDistinctRootsShareTheOneInstance() throws {
        // code-server serves every folder from one process (the client names its folder in the
        // `?folder=` query) — a second project must NOT spawn a second Node runtime, and both roots
        // read the same endpoint.
        let other = root + "-b"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: other) }

        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        _ = manager.ensure(projectRoot: other)
        XCTAssertEqual(spawner.spawnCount, 1)

        spawner.announcePort(1111)
        XCTAssertEqual(manager.ensure(projectRoot: root)?.port, 1111)
        XCTAssertEqual(manager.ensure(projectRoot: other)?.port, 1111)
    }

    func testStaleSpawnLogLineCannotPoisonTheRespawn() {
        // The dead child's pipe can flush its old listening line AFTER the respawn — the fresh
        // instance must learn ITS OWN port, never the stale one.
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)
        spawner.handles[0].exitSilently()
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(spawner.spawnCount, 2)

        spawner.announcePort(1111, instance: 0)
        XCTAssertEqual(manager.ensure(projectRoot: root)?.port, 0, "stale line ignored")
        spawner.announcePort(2222, instance: 1)
        XCTAssertEqual(manager.ensure(projectRoot: root)?.port, 2222)
    }

    func testMissingBinaryIsUnavailableAndSpawnsNothing() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, binary: nil)
        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0),
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

    // MARK: Workbench file-open (verb 19's CLI arm)

    /// A recording CLI runner: canned exit codes per attempt (the last one repeats), thread-safe.
    private final class FakeCLI: @unchecked Sendable {
        private let lock = NSLock()
        private let exitCodes: [Int32?]
        private(set) var calls: [[String]] = []

        init(_ exitCodes: [Int32?]) {
            self.exitCodes = exitCodes
        }

        func run(binary _: String, arguments: [String]) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            calls.append(arguments)
            return exitCodes[min(calls.count - 1, exitCodes.count - 1)]
        }
    }

    func testOpenInWorkbenchRetriesUntilTheCLILands() async {
        // The workbench session registers only once a client webview boots — the first `-r`
        // attempts legitimately fail. Two failures then success ⇒ exactly three calls, and the
        // SERVER was ensured first (the panel may never have spawned it).
        let spawner = FakeSpawner()
        let cli = FakeCLI([1, 1, 0])
        let manager = makeManager(spawner: spawner, cliRunner: { cli.run(binary: $0, arguments: $1) })

        let task = manager.openInWorkbench(target: root + "/main.py:12:3", projectRoot: root)
        let landed = await task?.value

        XCTAssertEqual(landed, true)
        XCTAssertEqual(cli.calls.count, 3, "stops retrying the moment an attempt lands")
        XCTAssertEqual(cli.calls.first, ["-r", root + "/main.py:12:3"], "the :line:col suffix rides through")
        XCTAssertEqual(spawner.spawnCount, 1, "the open ensures the server first")
    }

    func testOpenInWorkbenchGivesUpAfterTheAttemptBudget() async {
        let cli = FakeCLI([1])
        let manager = makeManager(spawner: FakeSpawner(), cliRunner: { cli.run(binary: $0, arguments: $1) })

        let landed = await manager.openInWorkbench(target: "/x/y.txt", projectRoot: root)?.value

        XCTAssertEqual(landed, false)
        XCTAssertEqual(cli.calls.count, CodeServerManager.openAttempts, "bounded — never an infinite retry loop")
    }

    func testOpenInWorkbenchWithoutBinaryIsNil() {
        let cli = FakeCLI([0])
        let manager = makeManager(
            spawner: FakeSpawner(), binary: nil, cliRunner: { cli.run(binary: $0, arguments: $1) },
        )
        XCTAssertNil(
            manager.openInWorkbench(target: "/x/y.txt", projectRoot: root),
            "no code-server ⇒ nil — the performer falls back to the default-app open",
        )
        XCTAssertTrue(cli.calls.isEmpty)
    }

    func testShutdownTerminatesTheChild() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure(projectRoot: root)

        manager.shutdown()
        XCTAssertTrue(spawner.handles.allSatisfy(\.terminated))

        // A post-shutdown ensure starts over (no zombie record).
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    // MARK: Workbench file-open (verb 19's bridge arm)

    /// With a workbench window attached to the bridge the file opens over the socket and the CLI —
    /// a whole Node process, plus the retry window that pays for its session registration — never
    /// runs at all.
    func testOpenInWorkbenchPrefersTheBridge() async {
        let cli = FakeCLI([0])
        let bridge = FakeBridge()
        bridge.attach()
        let manager = makeManager(
            spawner: FakeSpawner(), cliRunner: { cli.run(binary: $0, arguments: $1) }, bridge: bridge,
        )

        let landed = await manager.openInWorkbench(target: root + "/main.py:12:3", projectRoot: root)?.value

        XCTAssertEqual(landed, true)
        XCTAssertTrue(cli.calls.isEmpty, "the bridge landed it — no CLI process is spawned")
        XCTAssertEqual(
            bridge.opened, [root + "/main.py:12:3"], "the :line:col suffix rides through unsplit",
        )
    }

    /// No window attached (nothing booted, or the file lives outside every open folder) ⇒ the CLI
    /// arm still carries the open, and the bridge is re-offered on EVERY attempt so whichever route
    /// comes up first during a cold start wins.
    func testOpenInWorkbenchFallsBackToTheCLIWithoutAnAttachedWindow() async {
        let cli = FakeCLI([1, 0])
        let bridge = FakeBridge()
        let manager = makeManager(
            spawner: FakeSpawner(), cliRunner: { cli.run(binary: $0, arguments: $1) }, bridge: bridge,
        )

        let landed = await manager.openInWorkbench(target: "/x/y.txt", projectRoot: root)?.value

        XCTAssertEqual(landed, true)
        XCTAssertEqual(cli.calls.count, 2)
        XCTAssertEqual(bridge.opened.count, 2, "offered once per attempt, not only on the first")
    }

    /// The listener binds lazily — once, before the first child can inherit its path — so a host
    /// whose user never opens the code panel never creates the socket.
    func testBridgeBindsOnceBeforeTheFirstSpawn() {
        let bridge = FakeBridge()
        let manager = makeManager(spawner: FakeSpawner(), bridge: bridge)

        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(bridge.startedPaths, [CodeServerManager.bridgeSocketPath])

        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(bridge.startedPaths.count, 1, "latched — the second ensure re-binds nothing")
    }

    func testShutdownReleasesTheBridge() {
        let bridge = FakeBridge()
        let manager = makeManager(spawner: FakeSpawner(), bridge: bridge)
        _ = manager.ensure(projectRoot: root)

        manager.shutdown()

        XCTAssertEqual(bridge.stopCount, 1, "hostd going down must not strand the socket file")
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(bridge.startedPaths.count, 2, "a post-shutdown ensure binds a fresh listener")
    }

    /// The path the extension connects back to reaches it the only way it can: the environment
    /// every code-server child inherits.
    func testChildEnvironmentHandsDownTheBridgeSocket() {
        let environment = CodeServerManager.childEnvironment(base: [:], bridgeSocket: "/tmp/b.sock")

        XCTAssertEqual(environment["SLOPDESK_CODE_BRIDGE_SOCKET"], "/tmp/b.sock")
    }

    // MARK: Bridge extension seed

    func testBridgeSeedWritesTheManifestAndSourceThenRegisters() throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let source = { Data("module.exports = {};".utf8) }

        XCTAssertTrue(CodeServerManager.seedBridgeExtension(into: dir, source: source))

        let folder = dir.appendingPathComponent(CodeServerManager.bridgeExtensionDirectoryName)
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("extension.js")), source(),
        )
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("package.json")),
        ) as? [String: Any]
        XCTAssertEqual(manifest?["main"] as? String, "./extension.js")

        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("extensions.json")),
        ) as? [[String: Any]]
        let ids = registry?.compactMap { ($0["identifier"] as? [String: Any])?["id"] as? String }
        XCTAssertEqual(ids, ["slopdesk.slopdesk-bridge"], "a folder drop alone is invisible to the workbench")
    }

    /// Re-seeding an unchanged folder writes nothing (the second call reports no work), and a
    /// DRIFTED `extension.js` — a hostd carrying a newer bridge — is overwritten in place.
    func testBridgeSeedIsIdempotentButUpgradesDriftedSource() throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let old = { Data("// v1".utf8) }
        let new = { Data("// v2".utf8) }

        XCTAssertTrue(CodeServerManager.seedBridgeExtension(into: dir, source: old))
        XCTAssertFalse(CodeServerManager.seedBridgeExtension(into: dir, source: old))
        XCTAssertTrue(CodeServerManager.seedBridgeExtension(into: dir, source: new))

        let js = dir.appendingPathComponent(CodeServerManager.bridgeExtensionDirectoryName)
            .appendingPathComponent("extension.js")
        XCTAssertEqual(try Data(contentsOf: js), new())
    }

    /// A broken bundle is a no-op, never a half-written extension folder the workbench would then
    /// try to activate.
    func testBridgeSeedWithoutSourceWritesNothing() {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")

        XCTAssertFalse(CodeServerManager.seedBridgeExtension(into: dir, source: { nil }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// The manifest, the folder name and the registry entry all have to agree on ONE identity —
    /// they are written from the same three constants, and this is what keeps them there.
    func testBridgeManifestAgreesWithTheSeededIdentity() throws {
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CodeServerManager.bridgeExtensionManifest.utf8),
        ) as? [String: Any])

        XCTAssertEqual(manifest["name"] as? String, CodeServerManager.bridgeExtensionName)
        XCTAssertEqual(manifest["publisher"] as? String, CodeServerManager.bridgeExtensionPublisher)
        XCTAssertEqual(manifest["version"] as? String, CodeServerManager.bridgeExtensionVersion)
        XCTAssertEqual(
            CodeServerManager.bridgeExtensionDirectoryName, "slopdesk.slopdesk-bridge-1.1.0",
        )
        XCTAssertEqual(
            manifest["extensionKind"] as? [String], ["workspace"],
            "the socket and the files live on the HOST — the web worker host has neither",
        )
    }

    /// The manifest's commands and the extension's `registerCommand` calls have to name the same
    /// ids: a menu item pointing at an unregistered command is an error dialog, and a registered
    /// command with no menu item is unreachable.
    func testBridgeManifestAndSourceAgreeOnTheCommandIDs() throws {
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CodeServerManager.bridgeExtensionManifest.utf8),
        ) as? [String: Any])
        let contributes = try XCTUnwrap(manifest["contributes"] as? [String: Any])
        let commands = try XCTUnwrap(contributes["commands"] as? [[String: Any]])
        let ids = commands.compactMap { $0["command"] as? String }
        XCTAssertEqual(
            ids, ["slopdesk.runSelectionInTerminal", "slopdesk.changeTerminalDirectory"],
        )

        let menus = try XCTUnwrap(contributes["menus"] as? [String: [[String: Any]]])
        for (menu, items) in menus {
            for item in items {
                let command = try XCTUnwrap(item["command"] as? String)
                XCTAssertTrue(ids.contains(command), "\(menu) points at an undeclared \(command)")
            }
        }

        let sourceData = try XCTUnwrap(CodeServerManager.bridgeExtensionSource())
        let source = try XCTUnwrap(String(data: sourceData, encoding: .utf8))
        for id in ids {
            XCTAssertTrue(
                source.contains("registerCommand(\"\(id)\""), "\(id) is contributed but never registered",
            )
        }
    }

    /// The version bump that carries the new contributions also has to retire the folder the old
    /// one wrote — the registry stops pointing at it, but our own dead code should not sit in the
    /// user's profile forever.
    func testBridgeSeedSweepsTheRetiredVersionsFolder() throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let legacy = try XCTUnwrap(CodeServerManager.legacyBridgeExtensionDirectoryNames.first)
        let stale = dir.appendingPathComponent(legacy).appendingPathComponent("extension.js")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("// v1".utf8).write(to: stale)

        XCTAssertTrue(CodeServerManager.seedBridgeExtension(into: dir, source: { Data("// v2".utf8) }))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.deletingLastPathComponent().path))
    }

    /// The runner reaches the BRIDGE (where a `run` line looks it up), not a copy on the manager.
    func testTerminalRunnerIsForwardedToTheBridge() throws {
        let bridge = FakeBridge()
        let manager = CodeServerManager(bridge: bridge)

        manager.installTerminalRunner { _ in .landed(in: "zsh — alpha") }

        let runner = try XCTUnwrap(bridge.runner)
        XCTAssertEqual(
            runner(CodeBridgeRunRequest(root: "/work", directory: nil, text: "ls")),
            .landed(in: "zsh — alpha"),
        )
    }

    /// The shipped `extension.js` is a real resource in the target bundle (a broken `.copy` rule
    /// would silently degrade every open back to the CLI) and it reads the env var hostd sets.
    func testBridgeSourceShipsInTheBundle() throws {
        let source = try XCTUnwrap(
            CodeServerManager.bridgeExtensionSource(), "Resources/bridge/extension.js is missing",
        )
        let text = try XCTUnwrap(String(data: source, encoding: .utf8))

        XCTAssertTrue(text.contains("SLOPDESK_CODE_BRIDGE_SOCKET"))
        XCTAssertTrue(text.contains("module.exports"))
    }

    // MARK: Settings seed

    func testSettingsSeederRunsOnceBeforeTheFirstSpawnOnly() throws {
        let other = root + "-b"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: other) }

        let seeds = Counter()
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, settingsSeeder: { seeds.increment() })

        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(seeds.value, 1, "seeded before the first child boots")
        _ = manager.ensure(projectRoot: root)
        _ = manager.ensure(projectRoot: other)
        XCTAssertEqual(seeds.value, 1, "once per manager lifetime — not per ensure, not per root")
    }

    func testMissingBinaryNeverSeeds() {
        // No child will ever read the settings — a binary-less host must stay untouched.
        let seeds = Counter()
        let manager = makeManager(spawner: FakeSpawner(), binary: nil, settingsSeeder: { seeds.increment() })
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(seeds.value, 0)
    }

    // MARK: Bundled marketplace extensions

    func testMissingBundledExtensionsTruthTable() throws {
        // No registry yet (pristine host) / unparseable registry ⇒ everything is missing — the
        // install CLI rewrites a broken registry properly anyway.
        XCTAssertEqual(
            CodeServerManager.missingBundledExtensions(inRegistry: nil),
            CodeServerManager.bundledMarketplaceExtensions,
        )
        XCTAssertEqual(
            CodeServerManager.missingBundledExtensions(inRegistry: Data("not json".utf8)),
            CodeServerManager.bundledMarketplaceExtensions,
        )
        // Ids compare case-insensitively; foreign entries (the seeded theme) don't satisfy.
        let satisfied = try JSONSerialization.data(
            withJSONObject: CodeServerManager.bundledMarketplaceExtensions.map {
                ["identifier": ["id": $0.uppercased()]]
            },
        )
        XCTAssertEqual(CodeServerManager.missingBundledExtensions(inRegistry: satisfied), [])
        let foreign = try JSONSerialization.data(
            withJSONObject: [["identifier": ["id": "slopdesk.slopdesk-monokai"]]],
        )
        XCTAssertEqual(
            CodeServerManager.missingBundledExtensions(inRegistry: foreign),
            CodeServerManager.bundledMarketplaceExtensions,
        )
    }

    func testFirstEnsureInstallsBundledExtensionsBeforeTheFirstSpawn() async throws {
        let spawner = FakeSpawner()
        let cli = FakeCLI([0])
        let manager = makeManager(
            spawner: spawner,
            cliRunner: { cli.run(binary: $0, arguments: $1) },
            installedExtensionsRegistry: { nil },
        )

        // The install defers the spawn — the very first boot must already scan the icon pack, and
        // install + boot writing `extensions.json` concurrently loses registrations. ensure keeps
        // its never-wait contract via `.starting`.
        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.ServiceEndpoint(state: .starting, port: 0),
        )
        XCTAssertEqual(spawner.spawnCount, 0, "no child boots while the install CLI runs")

        // The client's ~1 Hz poll picks the spawn up once the one-shot install task lands.
        try await pollUntilSpawn(manager: manager, spawner: spawner)
        XCTAssertEqual(
            cli.calls,
            CodeServerManager.bundledMarketplaceExtensions.map { ["--install-extension", $0] },
        )
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testFailedBundledInstallStillSpawns() async throws {
        // Offline host / marketplace hiccup: the icon pack is a nicety — the panel is never held
        // hostage. `.done` latches anyway; the next hostd launch retries (registry still missing).
        let spawner = FakeSpawner()
        let cli = FakeCLI([nil])
        let manager = makeManager(
            spawner: spawner,
            cliRunner: { cli.run(binary: $0, arguments: $1) },
            installedExtensionsRegistry: { nil },
        )
        _ = manager.ensure(projectRoot: root)
        try await pollUntilSpawn(manager: manager, spawner: spawner)
        XCTAssertEqual(
            cli.calls.count, CodeServerManager.bundledMarketplaceExtensions.count,
            "one attempt per id — no retry loop inside a manager lifetime",
        )
    }

    func testSatisfiedRegistryNeverRunsTheInstallCLI() {
        let spawner = FakeSpawner()
        let cli = FakeCLI([0])
        let manager = makeManager(spawner: spawner, cliRunner: { cli.run(binary: $0, arguments: $1) })
        _ = manager.ensure(projectRoot: root)
        XCTAssertEqual(spawner.spawnCount, 1, "already installed ⇒ the first ensure spawns straight away")
        XCTAssertTrue(cli.calls.isEmpty)
    }

    // MARK: Prewarm (daemon-boot spawn, no client)

    func testPrewarmSpawnsWithoutAnyEnsureAndEnsureAdoptsTheChild() {
        let spawner = FakeSpawner()
        let bridge = FakeBridge()
        let seeds = Counter()
        let manager = makeManager(spawner: spawner, settingsSeeder: { seeds.increment() }, bridge: bridge)

        manager.prewarm()
        XCTAssertEqual(spawner.spawnCount, 1, "prewarm boots the child with no verb-18 round")
        XCTAssertEqual(seeds.value, 1, "the settings seed runs on the prewarm, not the first ensure")
        XCTAssertEqual(bridge.startedPaths.count, 1, "the bridge listener binds before the child spawns")

        // The first client round observes the prewarmed child — same instance, no second spawn.
        spawner.announcePort(6060)
        XCTAssertEqual(
            manager.ensure(projectRoot: root),
            MetadataCodec.ServiceEndpoint(state: .ready, port: 6060),
        )
        XCTAssertEqual(spawner.spawnCount, 1)
        XCTAssertEqual(seeds.value, 1)
    }

    func testPrewarmWithoutBinaryIsASilentNoOp() {
        let spawner = FakeSpawner()
        let bridge = FakeBridge()
        let manager = makeManager(spawner: spawner, binary: nil, bridge: bridge)
        manager.prewarm()
        XCTAssertEqual(spawner.spawnCount, 0)
        XCTAssertTrue(bridge.startedPaths.isEmpty, "no binary ⇒ nothing binds either")
    }

    func testPrewarmWithMissingExtensionsSpawnsWhenTheInstallLands() async throws {
        // The install task's completion CONTINUES the boot — on a prewarmed host there is no
        // client poll to pick the spawn up, so waiting for the next ensure would strand the
        // child unspawned until the panel opens (exactly the cold start prewarm removes).
        let spawner = FakeSpawner()
        let cli = FakeCLI([0])
        let manager = makeManager(
            spawner: spawner,
            cliRunner: { cli.run(binary: $0, arguments: $1) },
            installedExtensionsRegistry: { nil },
        )
        manager.prewarm()
        XCTAssertEqual(spawner.spawnCount, 0, "no child boots while the install CLI runs")
        for _ in 0..<500 {
            if spawner.spawnCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(spawner.spawnCount, 1, "the install completion spawns — no ensure needed")
        XCTAssertEqual(
            cli.calls,
            CodeServerManager.bundledMarketplaceExtensions.map { ["--install-extension", $0] },
        )
    }

    /// Drives the client's poll until the deferred first spawn happens (bounded — an install task
    /// that never releases the spawn fails the test instead of hanging it).
    private func pollUntilSpawn(manager: CodeServerManager, spawner: FakeSpawner) async throws {
        for _ in 0..<500 {
            _ = manager.ensure(projectRoot: root)
            if spawner.spawnCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the install task never released the spawn")
    }

    func testSeedUserSettingsWritesOnlyWhenAbsent() throws {
        let fileURL = URL(fileURLWithPath: root)
            .appendingPathComponent("data/code-server/User/settings.json")

        // Absent (intermediate directories included) → written with the canned defaults.
        XCTAssertTrue(CodeServerManager.seedUserSettings(at: fileURL))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8), CodeServerManager.seededUserSettings,
        )

        // Present with the user's OWN content → NEVER overwritten, whatever it holds.
        try Data("{\"workbench.colorTheme\": \"Mine\"}".utf8).write(to: fileURL)
        XCTAssertFalse(CodeServerManager.seedUserSettings(at: fileURL))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8), "{\"workbench.colorTheme\": \"Mine\"}",
        )
    }

    func testSeededChromeIsFlatAndSelectionWearsTheIslandChip() throws {
        // The two rules the colour block exists to hold, pinned because a seed bump is a wall of
        // JSON and either is easy to drop silently.
        let seed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(CodeServerManager.seededUserSettings.utf8))
                as? [String: Any],
        )
        let colors = try XCTUnwrap(seed["workbench.colorCustomizations"] as? [String: String])

        // 1. NOTHING CASTS. Every shadow key the theme pair ships is fully transparent here — on a
        // field where every surface is the one cream, a cast is a smear rather than a lift.
        let shadows = colors.filter { $0.key.lowercased().contains("shadow") }
        XCTAssertFalse(shadows.isEmpty)
        for (key, value) in shadows {
            XCTAssertEqual(value, "#00000000", "\(key) still casts")
        }

        // 2. SELECTION IS THE COMPACT ISLAND — the island's glass face carrying its light ink,
        // in every list the panel puts a chosen row in.
        for key in [
            "list.activeSelectionBackground", "list.inactiveSelectionBackground",
            "list.focusBackground", "quickInputList.focusBackground",
            "editorSuggestWidget.selectedBackground", "menu.selectionBackground",
            "tab.activeBackground",
        ] {
            XCTAssertEqual(colors[key], "#22212C", "\(key) is not the island chip")
        }
        for key in [
            "list.activeSelectionForeground", "list.inactiveSelectionForeground",
            "list.focusForeground", "quickInputList.focusForeground",
            "editorSuggestWidget.selectedForeground", "menu.selectionForeground",
            "tab.activeForeground",
        ] {
            XCTAssertEqual(colors[key], "#F8F8F2", "\(key) is not the island's ink")
        }
    }

    func testSeedUpgradesEveryPristineFormerSeed() throws {
        // A file byte-identical to ANY seed this manager once shipped was never user-edited (the
        // workbench rewrites the file on any settings change) — each upgrades to the current seed.
        let fileURL = URL(fileURLWithPath: root)
            .appendingPathComponent("data/code-server/User/settings.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        XCTAssertFalse(CodeServerManager.obsoleteSeeds.isEmpty)
        for former in CodeServerManager.obsoleteSeeds {
            try Data(former.utf8).write(to: fileURL)
            XCTAssertTrue(CodeServerManager.seedUserSettings(at: fileURL))
            XCTAssertEqual(
                try String(contentsOf: fileURL, encoding: .utf8), CodeServerManager.seededUserSettings,
            )
        }
    }

    func testFontSyncedFormerSeedStillUpgrades() throws {
        // A former seed whose ONLY divergence is the verb-20 font trio (sync rewrote the file,
        // re-serializing it wholesale) is still OURS — the format-blind + font-blind comparator
        // must upgrade it, or every font-synced host is stranded on its old seed forever.
        let fileURL = URL(fileURLWithPath: root)
            .appendingPathComponent("data/code-server/User/settings.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        for former in CodeServerManager.obsoleteSeeds {
            try Data(former.utf8).write(to: fileURL)
            CodeServerManager.syncEditorFont(
                MetadataCodec.CodeFontSpec(family: "Iosevka", size: 15, lineHeight: 1.44),
                at: fileURL,
            )
            XCTAssertNotEqual(try Data(contentsOf: fileURL), Data(former.utf8))
            XCTAssertTrue(CodeServerManager.seedUserSettings(at: fileURL))
            XCTAssertEqual(
                try String(contentsOf: fileURL, encoding: .utf8), CodeServerManager.seededUserSettings,
            )
        }
    }

    func testFontSyncedCurrentSeedIsLeftAlone() throws {
        // The CURRENT seed with synced fonts is up to date — a rewrite would clobber the client's
        // sync on every manager lifetime (the seed lays defaults; the sync overrides them).
        let fileURL = URL(fileURLWithPath: root)
            .appendingPathComponent("data/code-server/User/settings.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(CodeServerManager.seededUserSettings.utf8).write(to: fileURL)
        CodeServerManager.syncEditorFont(
            MetadataCodec.CodeFontSpec(family: "Iosevka", size: 15, lineHeight: 1.44), at: fileURL,
        )
        let synced = try Data(contentsOf: fileURL)
        XCTAssertFalse(CodeServerManager.seedUserSettings(at: fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), synced)
    }

    func testUserEditedFormerSeedNeverUpgradesEvenWithFontDrift() throws {
        // A REAL user edit beyond the font trio (here: wordWrap) makes the file theirs — no
        // upgrade, no matter how seed-like the rest looks.
        let fileURL = URL(fileURLWithPath: root)
            .appendingPathComponent("data/code-server/User/settings.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let former = try XCTUnwrap(CodeServerManager.obsoleteSeeds.last)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(former.utf8)) as? [String: Any],
        )
        object["editor.wordWrap"] = "on"
        object["editor.fontSize"] = 15
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: fileURL)
        let edited = try Data(contentsOf: fileURL)
        XCTAssertFalse(CodeServerManager.seedUserSettings(at: fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), edited)
    }

    // MARK: Editor font sync (verb 20)

    func testSyncEditorFontPatchesTheTrioAndKeepsEveryOtherKey() throws {
        let fileURL = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
        try Data(CodeServerManager.seededUserSettings.utf8).write(to: fileURL)
        XCTAssertTrue(CodeServerManager.syncEditorFont(
            MetadataCodec.CodeFontSpec(family: "Iosevka", size: 14, lineHeight: 1.58), at: fileURL,
        ))
        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any],
        )
        XCTAssertEqual(
            settings["editor.fontFamily"] as? String,
            "'Iosevka', 'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
        )
        XCTAssertEqual(try XCTUnwrap(settings["editor.fontSize"] as? Double), 14)
        XCTAssertEqual(try XCTUnwrap(settings["editor.lineHeight"] as? Double), 1.58)
        // Every non-font key rides through untouched.
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "Monokai Pro")
        XCTAssertEqual(settings["files.autoSave"] as? String, "onFocusChange")
        // The file reads the way a human wrote it: a raw Double serializes with round-trip noise
        // ("1.5800000000000001") in a settings file the user opens — the decimal route must keep
        // it "1.58" / "14" on the BYTES, not just the parsed value.
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"editor.lineHeight\" : 1.58"), text)
        XCTAssertTrue(text.contains("\"editor.fontSize\" : 14"), text)
        XCTAssertFalse(text.contains("1.5800000"))
    }

    func testSyncEditorFontIsChurnFreeWhenAlreadyInSync() throws {
        // Every ensure round re-syncs — the second identical spec must NOT rewrite the file (the
        // workbench's settings watcher would reload for nothing).
        let fileURL = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
        try Data(CodeServerManager.seededUserSettings.utf8).write(to: fileURL)
        let spec = MetadataCodec.CodeFontSpec(family: "JetBrains Mono", size: 14, lineHeight: 1.58)
        XCTAssertTrue(CodeServerManager.syncEditorFont(spec, at: fileURL))
        let once = try Data(contentsOf: fileURL)
        XCTAssertFalse(CodeServerManager.syncEditorFont(spec, at: fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), once)
    }

    func testSyncEditorFontNeverCreatesAndNeverRewritesJSONC() throws {
        let spec = MetadataCodec.CodeFontSpec(family: "Iosevka", size: 15, lineHeight: 1.44)
        // Missing file → no-op, still missing (the sync is layered over the seed, never a creator).
        let missing = URL(fileURLWithPath: root).appendingPathComponent("absent.json")
        XCTAssertFalse(CodeServerManager.syncEditorFont(spec, at: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        // JSONC (comments — JSONSerialization rejects it) → the USER's file, byte-untouched.
        let jsonc = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
        let contents = "// mine\n{\"editor.fontSize\": 11}\n"
        try Data(contents.utf8).write(to: jsonc)
        XCTAssertFalse(CodeServerManager.syncEditorFont(spec, at: jsonc))
        XCTAssertEqual(try String(contentsOf: jsonc, encoding: .utf8), contents)
    }

    func testEditorFontFamilyStack() {
        let fallback = "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace"
        // The embedded default and degenerate families collapse to the seeded stack (no repeat).
        XCTAssertEqual(CodeServerManager.editorFontFamilyStack(for: "JetBrains Mono"), fallback)
        XCTAssertEqual(CodeServerManager.editorFontFamilyStack(for: "  "), fallback)
        XCTAssertEqual(CodeServerManager.editorFontFamilyStack(for: "'\"'"), fallback)
        // A real family heads the stack, quote-stripped and single-quoted.
        XCTAssertEqual(
            CodeServerManager.editorFontFamilyStack(for: " 'SF Mono' "), "'SF Mono', \(fallback)",
        )
    }

    func testCurrentSeedIsNotListedObsolete() {
        // The upgrade rule keys on obsoleteSeeds — the CURRENT seed in that list would make every
        // pristine host rewrite (and log a seed) on every manager lifetime.
        XCTAssertFalse(CodeServerManager.obsoleteSeeds.contains(CodeServerManager.seededUserSettings))
    }

    func testSeededSettingsAreValidJSONWithThemeAndLeanChrome() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(CodeServerManager.seededUserSettings.utf8),
        )
        let settings = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "Monokai Pro")
        XCTAssertEqual(settings["workbench.startupEditor"] as? String, "none")
        // The lean pass: title-bar strips gone, editor chrome minimal.
        XCTAssertEqual(settings["window.commandCenter"] as? Bool, false)
        XCTAssertEqual(settings["workbench.layoutControl.enabled"] as? Bool, false)
        XCTAssertEqual(settings["editor.minimap.enabled"] as? Bool, false)
        // v12: the activity-bar icons fold into the sidebar TOP (user-directed) — Search / Source
        // Control / Extensions are clickable again; fully "hidden" left them chord-only. "top"
        // force-shows the web title bar; the CLIENT clips that band off
        // (`CodeSidebarWebView.clippedTitleBarHeight`).
        XCTAssertEqual(settings["workbench.activityBar.location"] as? String, "top")
        XCTAssertEqual(settings["window.menuBarVisibility"] as? String, "hidden")
        // v14: the status bar RETURNS (user-directed 2026-08-03) — no visibility key at all, the
        // workbench keeps its stock footing (branch, problems, cursor) under the retinted seam.
        XCTAssertNil(settings["workbench.statusBar.visible"])
        // v13: the gutter slims — the panel reads code, it does not debug it (user-directed):
        // three-char line numbers, no breakpoint glyph margin, no folding-arrow column.
        XCTAssertEqual(settings["editor.lineNumbersMinChars"] as? Int, 3)
        XCTAssertEqual(settings["editor.glyphMargin"] as? Bool, false)
        XCTAssertEqual(settings["editor.folding"] as? Bool, false)
        // v16: the reading aids (user-directed 2026-08-04) — structure guides in the editor AND
        // the file tree. Sticky scroll and always-on tree guides are genuine non-defaults
        // (verified in the shipped 4.131 bundle: `stickyScroll={enabled:!1`, tree guides
        // default "onHover"); the indentation-guide pin is the ask by its own name.
        XCTAssertEqual(settings["editor.guides.indentation"] as? Bool, true)
        XCTAssertEqual(settings["editor.guides.bracketPairs"] as? String, "active")
        XCTAssertEqual(settings["editor.stickyScroll.enabled"] as? Bool, true)
        XCTAssertEqual(settings["editor.renderWhitespace"] as? String, "trailing")
        XCTAssertEqual(settings["workbench.tree.renderIndentGuides"] as? String, "always")
        XCTAssertEqual(settings["workbench.tree.indent"] as? Int, 16)
        // Every seeded key must be REGISTERED in the shipped web workbench — the settings editor
        // flags unknown keys as warnings in a file we authored. These two are still unregistered
        // (desktop-only / absent from the shipped workbench) and must never come back.
        XCTAssertNil(settings["window.customTitleBarVisibility"])
        XCTAssertNil(settings["chat.commandCenter.enabled"])
        // v18: `chat.disableAIFeatures` RETURNS — v7 dropped it because Code-OSS had no chat to
        // disable, and code-server 4.113+ bundles the Copilot chat extension that registers it
        // again (verified in the 4.131 bundle). The intent never changed: this panel is seeded
        // with the AI surfaces off.
        XCTAssertEqual(settings["chat.disableAIFeatures"] as? Bool, true)
        // The file tree hugs the window's right edge — the panel hangs off it.
        XCTAssertEqual(settings["workbench.sideBar.location"] as? String, "right")
        // The editor face IS the terminal's: JetBrains Mono (what libghostty actually renders —
        // its embedded default; "SF Mono" resolves on neither machine) at the terminal's 13pt,
        // with the bundled nerd face behind it for private-use glyphs. The client injects both
        // @font-faces; the family NAMES here must match `CodeSidebarPageDressing`'s
        // `monoFontFamilyName` / `nerdFontFamilyName`.
        let fontFamily = try XCTUnwrap(settings["editor.fontFamily"] as? String)
        XCTAssertTrue(fontFamily.hasPrefix("'JetBrains Mono'"))
        XCTAssertTrue(fontFamily.contains("ui-monospace"))
        XCTAssertTrue(fontFamily.contains("'Symbols Nerd Font'"))
        XCTAssertEqual(settings["editor.fontSize"] as? Int, 13)
        // Line rhythm parity: 1.32 is JetBrains Mono's own vertical metric ((1020 + 300) / 1000)
        // — the exact ratio ghostty rounds into its cell height.
        XCTAssertEqual(try XCTUnwrap(settings["editor.lineHeight"] as? Double), 1.32)
        // v17: NO `window.title` template. The web title bar is clipped off client-side and the
        // panel's strip stopped reading the document title (the workbench's own editor tab already
        // names the open file), so there is no surface left for a shape here to reach.
        XCTAssertNil(settings["window.title"])
        // Auto-save on focus change — leaving the editor for the terminal puts the file on disk.
        XCTAssertEqual(settings["files.autoSave"] as? String, "onFocusChange")
        // v9: NO compact tab density. The 22px compact row minus the Slate plate recut (height −
        // 8px) left 14px plates — too squat next to the app's own tab plates. Absent ⇒ the stock
        // 35px row ⇒ 27px plates, ≈ the app's control height.
        XCTAssertNil(settings["window.density.editorTabHeight"])
        // v10: markdown opens straight into the RENDERED preview — in this panel markdown is
        // read, not authored. The value is the built-in markdown extension's custom-editor id.
        let associations = try XCTUnwrap(settings["workbench.editorAssociations"] as? [String: Any])
        XCTAssertEqual(associations["*.md"] as? String, "vscode.markdown.preview.editor")
        // v11: no git-decoration letter badge on editor TABS — the sub-baseline "A"/"M" reads as
        // a stray character beside the label. The explorer keeps its own badges.
        XCTAssertEqual(settings["workbench.editor.decorations.badges"] as? Bool, false)
        // v15: Material Icon Theme file icons — the id the bundled marketplace install provides
        // (`bundledMarketplaceExtensions`), so it resolves on the very first boot.
        XCTAssertEqual(settings["workbench.iconTheme"] as? String, "material-icon-theme")
    }

    // MARK: Theme extension seed

    func testThemeExtensionManifestCarriesEveryVariantAndAgreesWithTheSeed() throws {
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(CodeServerManager.themeExtensionManifest.utf8),
            ) as? [String: Any],
        )
        let contributes = try XCTUnwrap(manifest["contributes"] as? [String: Any])
        let themes = try XCTUnwrap(contributes["themes"] as? [[String: Any]])
        // ALL EIGHT stock variants ship (user-directed 2026-08-03) — the generated manifest must
        // mirror the source-of-truth table row for row.
        XCTAssertEqual(themes.count, CodeServerManager.themeExtensionThemes.count)
        XCTAssertEqual(themes.count, 8)
        for (entry, expected) in zip(themes, CodeServerManager.themeExtensionThemes) {
            XCTAssertEqual(entry["label"] as? String, expected.label)
            XCTAssertEqual(entry["uiTheme"] as? String, expected.dark ? "vs-dark" : "vs")
            XCTAssertEqual(entry["path"] as? String, "./themes/\(expected.resource).json")
        }
        // The folder name pins the manifest identity (publisher.name-version).
        let identity = "\(manifest["publisher"] as? String ?? "").\(manifest["name"] as? String ?? "")"
            + "-\(manifest["version"] as? String ?? "")"
        XCTAssertEqual(identity, CodeServerManager.themeExtensionDirectoryName)
    }

    // MARK: Retired Foundry theme extension removal

    func testRemoveFoundryThemeExtensionSweepsFoldersAndRegistryEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-foundry-removal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in CodeServerManager.foundryExtensionDirectoryNames {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("\(name)/themes"), withIntermediateDirectories: true,
            )
        }
        // A registry carrying OUR retired entry beside a foreign one.
        let registry = dir.appendingPathComponent("extensions.json")
        let entries: [[String: Any]] = [
            ["identifier": ["id": CodeServerManager.foundryExtensionID], "version": "2.0.0"],
            ["identifier": ["id": "someone.else"], "version": "1.2.3"],
        ]
        try JSONSerialization.data(withJSONObject: entries).write(to: registry)

        XCTAssertTrue(CodeServerManager.removeFoundryThemeExtension(from: dir))
        for name in CodeServerManager.foundryExtensionDirectoryNames {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
            )
        }
        let kept = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]],
        )
        // The foreign entry rides through untouched; ours is gone.
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual((kept[0]["identifier"] as? [String: Any])?["id"] as? String, "someone.else")

        // Idempotent: a second sweep finds nothing to do.
        XCTAssertFalse(CodeServerManager.removeFoundryThemeExtension(from: dir))
    }

    func testUnregisterExtensionLeavesMissingOrForeignRegistriesAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-unregister-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No registry file at all: nothing to prune, nothing created.
        XCTAssertFalse(CodeServerManager.unregisterExtension(id: "slopdesk.x", in: dir))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("extensions.json").path),
        )
        // An unparseable registry is someone else's problem state: left byte-identical.
        let registry = dir.appendingPathComponent("extensions.json")
        try Data("not json".utf8).write(to: registry)
        XCTAssertFalse(CodeServerManager.unregisterExtension(id: "slopdesk.x", in: dir))
        XCTAssertEqual(try Data(contentsOf: registry), Data("not json".utf8))
    }

    /// The seven structural part borders — the workbench's own seams. These are the ONLY colour
    /// departure from the stock vsix: they carry the app's Slate `divider` tint so the
    /// workbench's seams match the split dividers around the panel (user-directed 2026-08-03).
    private static let seamBorderKeys = [
        "activityBar.border", "editorGroup.border", "panel.border", "sideBar.border",
        "statusBar.border", "statusBar.noFolderBorder", "titleBar.border",
    ]

    func testEveryThemeResourceParsesWithSeamTintAndValidColors() throws {
        // One resource per manifest row, every one loadable from the bundle, every one carrying
        // the two (and only two) departures from stock: retinted seam borders per dark/light,
        // no invalid colour values (the vsix's empty strings dropped by the sync script).
        for theme in CodeServerManager.themeExtensionThemes {
            let data = try XCTUnwrap(
                CodeServerManager.themeExtensionThemeData(resource: theme.resource),
                "\(theme.resource).json must resolve from the bundle",
            )
            let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(parsed["name"] as? String, theme.label)
            XCTAssertEqual(parsed["type"] as? String, theme.dark ? "dark" : "light")
            let colors = try XCTUnwrap(parsed["colors"] as? [String: Any])
            XCTAssertGreaterThan(colors.count, 500, theme.label)
            for key in Self.seamBorderKeys {
                XCTAssertEqual(
                    colors[key] as? String, theme.dark ? "#fcfcfa1a" : "#00000014",
                    "\(theme.label) \(key)",
                )
            }
            try assertEveryColorValueIsValidHex(colors)
            XCTAssertFalse(
                try XCTUnwrap(parsed["tokenColors"] as? [Any]).isEmpty,
                "syntax rules ride along — the Monokai identity (\(theme.label))",
            )
        }
    }

    func testThemeResourceIsStockMonokaiProWithSlateSeamBorders() throws {
        let data = try XCTUnwrap(
            CodeServerManager.themeExtensionThemeData(resource: "monokai-pro"),
            "the bundled theme resource must resolve",
        )
        let theme = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(theme["name"] as? String, "Monokai Pro")
        XCTAssertEqual(theme["type"] as? String, "dark")
        let colors = try XCTUnwrap(theme["colors"] as? [String: Any])
        // Stock Monokai Pro surfaces (they double as the app's own Slate seeds).
        XCTAssertEqual(colors["editor.background"] as? String, "#2d2a2e")
        XCTAssertEqual(colors["sideBar.background"] as? String, "#221f22")
        // STOCK survives (user-directed 2026-08-03, reverting the earlier 17-key chrome-accent
        // neutralization): the filter's yellow accent stays on tabs, lists and links.
        XCTAssertEqual(colors["tab.activeForeground"] as? String, "#ffd866")
        XCTAssertEqual(colors["tab.activeBorder"] as? String, "#ffd866")
        XCTAssertEqual(colors["list.activeSelectionForeground"] as? String, "#ffd866")
        XCTAssertEqual(colors["textLink.foreground"] as? String, "#ffd866")
        XCTAssertEqual(colors["tab.activeBackground"] as? String, "#2d2a2e")
        XCTAssertEqual(colors["gitDecoration.modifiedResourceForeground"] as? String, "#ffd866")
        // The one colour departure: every structural seam border rides the Slate divider token —
        // the dark filter's foreground `#fcfcfa` at the token's 0.10, in alpha form so it
        // composites over whichever surface it separates (stock painted these near-black).
        for key in Self.seamBorderKeys {
            XCTAssertEqual(colors[key] as? String, "#fcfcfa1a", key)
        }
        try assertEveryColorValueIsValidHex(colors)
        XCTAssertFalse(
            try XCTUnwrap(theme["tokenColors"] as? [Any]).isEmpty,
            "syntax rules ride along — the Monokai identity",
        )
    }

    /// Every workbench colour must be `#rrggbb`/`#rrggbbaa` — the vsix conversion once carried
    /// five EMPTY-string values (`diffEditor.move.border` etc.), which the workbench rejects
    /// per-key; a file we author carries no invalid values.
    private func assertEveryColorValueIsValidHex(_ colors: [String: Any]) throws {
        for (key, value) in colors {
            let hex = try XCTUnwrap(value as? String, "\(key) must be a string colour")
            XCTAssertTrue(
                hex.wholeMatch(of: /#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?/) != nil,
                "\(key) carries an invalid colour value '\(hex)'",
            )
        }
    }

    func testLightThemeResourceIsStockMonokaiProLightWithSlateSeamBorders() throws {
        let data = try XCTUnwrap(
            CodeServerManager.themeExtensionThemeData(resource: "monokai-pro-light"),
            "the bundled light theme resource must resolve",
        )
        let theme = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(theme["name"] as? String, "Monokai Pro Light")
        XCTAssertEqual(theme["type"] as? String, "light")
        let colors = try XCTUnwrap(theme["colors"] as? [String: Any])
        // Stock Monokai Pro Light surfaces (they double as the app's own light Slate seed).
        XCTAssertEqual(colors["editor.background"] as? String, "#faf4f2")
        XCTAssertEqual(colors["editor.foreground"] as? String, "#29242a")
        // STOCK survives, mirrored: the light filter's pink accent stays on tabs, lists and links.
        XCTAssertEqual(colors["tab.activeForeground"] as? String, "#e14775")
        XCTAssertEqual(colors["tab.activeBorder"] as? String, "#e14775")
        XCTAssertEqual(colors["list.activeSelectionForeground"] as? String, "#e14775")
        XCTAssertEqual(colors["textLink.foreground"] as? String, "#e14775")
        XCTAssertEqual(colors["tab.activeBackground"] as? String, "#faf4f2")
        XCTAssertEqual(colors["gitDecoration.deletedResourceForeground"] as? String, "#e14775")
        // The mirrored seam-border departure: the light divider token is black at 0.08.
        for key in Self.seamBorderKeys {
            XCTAssertEqual(colors[key] as? String, "#00000014", key)
        }
        try assertEveryColorValueIsValidHex(colors)
        XCTAssertFalse(
            try XCTUnwrap(theme["tokenColors"] as? [Any]).isEmpty,
            "syntax rules ride along — the Monokai identity",
        )
    }

    func testSeedThemeExtensionWritesOnceThenRepairsDrift() throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let fakeThemes: (String) -> Data? = { Data("{\"is\": \"\($0)\"}".utf8) }
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: fakeThemes))
        let extensionRoot = dir.appendingPathComponent(CodeServerManager.themeExtensionDirectoryName)
        // One theme file per manifest row, each carrying its OWN resource's bytes.
        for theme in CodeServerManager.themeExtensionThemes {
            XCTAssertEqual(
                try Data(contentsOf: extensionRoot.appendingPathComponent("themes/\(theme.resource).json")),
                fakeThemes(theme.resource),
            )
        }

        // Byte-identical ⇒ idempotent no-op.
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: fakeThemes))

        // OUR file drifted (a newer seed, a truncated write) ⇒ repaired — unlike the user's
        // settings file, the namespaced extension folder is ours to keep current.
        let themeFile = extensionRoot.appendingPathComponent("themes/monokai-pro.json")
        try Data("stale".utf8).write(to: themeFile)
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: fakeThemes))
        XCTAssertEqual(try Data(contentsOf: themeFile), fakeThemes("monokai-pro"))

        // No resource (broken bundle) ⇒ silent no-op, nothing half-written.
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in nil }))
    }

    func testSeedThemeExtensionSweepsTheTwoVariantEraFileNames() throws {
        // The pre-variant era wrote two differently named theme files; a deployed folder from
        // that era must not keep them as orphans beside the eight the manifest now references.
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let extensionRoot = dir.appendingPathComponent(CodeServerManager.themeExtensionDirectoryName)
        try FileManager.default.createDirectory(
            at: extensionRoot.appendingPathComponent("themes"), withIntermediateDirectories: true,
        )
        for legacy in CodeServerManager.legacyThemeFileNames {
            try Data("old".utf8).write(to: extensionRoot.appendingPathComponent(legacy))
        }
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))
        for legacy in CodeServerManager.legacyThemeFileNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: extensionRoot.appendingPathComponent(legacy).path,
                ),
                legacy,
            )
        }
    }

    func testSeedThemeExtensionRegistersInTheProfileRegistry() throws {
        // The registry (`extensions.json`) — not the directory scan — is the workbench's source of
        // truth once the file exists: code-server writes an empty `[]` on first boot, and a
        // folder-dropped extension is then INVISIBLE (observed: the seeded theme fell back to the
        // stock dark). The seeder therefore registers what it drops.
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let registry = dir.appendingPathComponent("extensions.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: registry)

        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))
        let entries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]],
        )
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(
            (entry["identifier"] as? [String: Any])?["id"] as? String, "slopdesk.slopdesk-monokai",
        )
        XCTAssertEqual(entry["version"] as? String, CodeServerManager.themeExtensionVersion)
        XCTAssertEqual(
            entry["relativeLocation"] as? String, CodeServerManager.themeExtensionDirectoryName,
        )
        // The location must be URI-shaped (path + scheme) or the server scanner drops the entry.
        let location = try XCTUnwrap(entry["location"] as? [String: Any])
        XCTAssertEqual(location["scheme"] as? String, "file")
        XCTAssertEqual(
            location["path"] as? String,
            dir.appendingPathComponent(CodeServerManager.themeExtensionDirectoryName).path,
        )

        // Registered and byte-current ⇒ the whole seed is an idempotent no-op.
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))

        // Foreign entries survive; a drifted OURS is replaced, not duplicated.
        let foreign: [[String: Any]] = [
            [
                "identifier": ["id": "someone.else"],
                "version": "9",
                "location": ["path": "/x", "scheme": "file"],
                "relativeLocation": "someone.else-9",
            ],
            [
                "identifier": ["id": "slopdesk.slopdesk-monokai"],
                "version": "0.0.1",
                "location": ["path": "/stale", "scheme": "file"],
                "relativeLocation": "stale",
            ],
        ]
        try JSONSerialization.data(withJSONObject: foreign).write(to: registry)
        // The folder is already current, but the registry repair IS a write.
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))
        let repaired = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]],
        )
        XCTAssertEqual(repaired.count, 2)
        XCTAssertEqual(
            (repaired[0]["identifier"] as? [String: Any])?["id"] as? String, "someone.else",
        )
        XCTAssertEqual(repaired[1]["version"] as? String, CodeServerManager.themeExtensionVersion)

        // An unparseable registry is someone else's problem state — left alone.
        try Data("not json".utf8).write(to: registry)
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))
        XCTAssertEqual(try Data(contentsOf: registry), Data("not json".utf8))

        // A MISSING registry file is created carrying our entry (fresh install: the seed runs
        // before code-server's first boot; that boot keeps existing entries).
        try FileManager.default.removeItem(at: registry)
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: { _ in Data("{}".utf8) }))
        let fresh = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]],
        )
        XCTAssertEqual(fresh.count, 1)
    }

    func testEveryObsoleteSeedIsValidJSON() throws {
        for seed in CodeServerManager.obsoleteSeeds {
            _ = try JSONSerialization.jsonObject(with: Data(seed.utf8))
        }
    }

    func testUserSettingsURLResolution() {
        // `$HOME` — what Node's `os.homedir()` answers in the child — is the base, NOT directory
        // services (a gate-sandboxed hostd overrides HOME; the seed must follow it).
        XCTAssertEqual(
            CodeServerManager.userSettingsURL(environment: ["HOME": "/Users/x"]).path,
            "/Users/x/.local/share/code-server/User/settings.json",
        )
        // An ABSOLUTE XDG_DATA_HOME wins (code-server's own resolution order)…
        XCTAssertEqual(
            CodeServerManager.userSettingsURL(
                environment: ["XDG_DATA_HOME": "/xdg", "HOME": "/Users/x"],
            ).path,
            "/xdg/code-server/User/settings.json",
        )
        // …but relative XDG/HOME values are ignored, per the XDG spec (fall through to the next).
        XCTAssertEqual(
            CodeServerManager.userSettingsURL(
                environment: ["XDG_DATA_HOME": "rel", "HOME": "/Users/x"],
            ).path,
            "/Users/x/.local/share/code-server/User/settings.json",
        )
        // No usable env at all → directory services' home (the interactive-launch default).
        XCTAssertEqual(
            CodeServerManager.userSettingsURL(environment: [:]).path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/code-server/User/settings.json").path,
        )
    }

    /// Thread-safe call counter for the `@Sendable` seeder seam.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    // MARK: Pure helpers

    func testLaunchArgumentsShape() {
        let arguments = CodeServerManager.launchArguments()
        XCTAssertEqual(arguments.first, "--auth")
        XCTAssertTrue(arguments.contains("--bind-addr"))
        XCTAssertTrue(arguments.contains("0.0.0.0:0"))
        XCTAssertTrue(arguments.contains("--disable-workspace-trust"))
        // The workbench brands itself with the embedding app's name, not "code-server".
        XCTAssertTrue(arguments.contains("--app-name"))
        XCTAssertTrue(arguments.contains("SlopDesk"))
        // NO positional folder — one shared instance serves every project; each client names its
        // folder in the workbench URL's `?folder=` query.
        XCTAssertFalse(arguments.contains { $0.hasPrefix("/") })
        // NO idle reaper — the daemon prewarms at boot so the workbench is always warm; a
        // self-reaping child re-imposes the cold start prewarm exists to remove. Never
        // reintroduce without revisiting `prewarm()`.
        XCTAssertFalse(arguments.contains("--idle-timeout-seconds"))
    }

    func testChildEnvironmentInjectsTheOfficialMarketplaceGallery() throws {
        // Every child (server + one-shot CLI) launches with `EXTENSIONS_GALLERY` pointing at the
        // official VS Code Marketplace — code-server parses the env var as JSON and replaces its
        // Open VSX default wholesale, so the value must be one valid JSON object carrying the
        // full URL set (a partial set would silently drop e.g. the asset download template).
        let environment = CodeServerManager.childEnvironment(base: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        let gallery = try XCTUnwrap(environment["EXTENSIONS_GALLERY"])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(gallery.utf8)) as? [String: String],
        )
        XCTAssertEqual(
            parsed["serviceUrl"], "https://marketplace.visualstudio.com/_apis/public/gallery",
        )
        XCTAssertEqual(parsed["itemUrl"], "https://marketplace.visualstudio.com/items")
        XCTAssertNotNil(parsed["resourceUrlTemplate"])
        XCTAssertNotNil(parsed["controlUrl"])
        XCTAssertNotNil(parsed["nlsBaseUrl"])
        XCTAssertNotNil(parsed["publisherUrl"])
    }

    func testChildEnvironmentKeepsAnOperatorsOwnGallery() {
        // The escape hatch is the env var itself: an operator who exported EXTENSIONS_GALLERY
        // before hostd keeps their gallery verbatim; only an EMPTY export is treated as unset.
        let own = "{\"serviceUrl\":\"https://example.test/gallery\"}"
        XCTAssertEqual(
            CodeServerManager.childEnvironment(base: ["EXTENSIONS_GALLERY": own])["EXTENSIONS_GALLERY"],
            own,
        )
        XCTAssertEqual(
            CodeServerManager.childEnvironment(base: ["EXTENSIONS_GALLERY": ""])["EXTENSIONS_GALLERY"],
            CodeServerManager.marketplaceExtensionsGallery,
        )
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

/// ``HostCodeServerPerformer`` routing: verbs 18/19 → the manager; every other verb → `nil`
/// (fall through to the read-only builder); malformed payloads → `.error`; a vanished path →
/// `.notFound`. The verb-19 fallback opener is ALWAYS injected (the default touches `NSWorkspace` —
/// hang-safety).
final class HostCodeServerPerformerTests: XCTestCase {
    private final class RunnerRecord: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[String]] = []
        var onRecord: (@Sendable () -> Void)?
        func record(_ arguments: [String]) {
            lock.lock()
            calls.append(arguments)
            let notify = onRecord
            lock.unlock()
            notify?()
        }
    }

    private func makeManager(
        binary: String? = "/fake/code-server",
        spawned: @escaping @Sendable () -> Void = {},
        cli: RunnerRecord = RunnerRecord(),
        settingsFileURL: URL? = nil,
        bridge: FakeBridge = FakeBridge(),
    ) -> CodeServerManager {
        // settingsSeeder / cliRunner / registry reader / settingsFileURL / bridge injected as
        // fakes — the default seams touch the real user's settings file and extension registry,
        // exec a real binary or bind a real socket. The registry answers SATISFIED so an open
        // never records a bundled `--install-extension` alongside the `-r` under test (the
        // production seam would, on any dev machine missing one of the bundled ids).
        let settingsURL = settingsFileURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("performer-tests-absent-\(UUID().uuidString).json")
        let satisfiedRegistry = try? JSONSerialization.data(
            withJSONObject: CodeServerManager.bundledMarketplaceExtensions.map {
                ["identifier": ["id": $0]]
            },
        )
        return CodeServerManager(
            binaryLocator: { binary },
            spawner: { _, _, _ in
                spawned()
                return NeverExitingHandle()
            },
            readinessProbe: { _ in false },
            settingsSeeder: {},
            cliRunner: { _, arguments in
                cli.record(arguments)
                return 0
            },
            installedExtensionsRegistry: { satisfiedRegistry },
            settingsFileURL: { settingsURL },
            bridge: bridge,
            probeInterval: .zero,
            openRetryDelay: .zero,
        )
    }

    /// A fallback opener that records and answers `.ok` — never `NSWorkspace`.
    private func recordingFallback(
        into recorded: RunnerRecord,
    ) -> HostCodeServerPerformer.FallbackOpener {
        { path in
            recorded.record([path])
            return .ok
        }
    }

    private final class NeverExitingHandle: HostServiceProcessHandle, @unchecked Sendable {
        var isRunning: Bool { true }
        func terminate() {}
    }

    func testOtherVerbsFallThrough() {
        let embedded: Set<MetadataVerb> = [.ensureCodeServer, .openInCodeServer, .syncCodeFont]
        for verb in MetadataVerb.allCases where !embedded.contains(verb) {
            XCTAssertNil(
                HostCodeServerPerformer.response(
                    requestID: 1, verb: verb.rawValue, payload: Data(), manager: makeManager(),
                    fallbackOpen: { _ in .ok },
                ),
                "verb \(verb) must fall through to the read-only builder",
            )
        }
        XCTAssertNil(
            HostCodeServerPerformer.response(
                requestID: 1, verb: 250, payload: Data(), manager: makeManager(),
                fallbackOpen: { _ in .ok },
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

    func testSyncFontMalformedPayloadIsError() {
        for payload in [Data(), Data([0x00])] {
            let response = HostCodeServerPerformer.response(
                requestID: 11, verb: MetadataVerb.syncCodeFont.rawValue,
                payload: payload, manager: makeManager(),
            )
            guard case let .metadataResponse(requestID, status, body)? = response else {
                XCTFail("expected a metadataResponse")
                return
            }
            XCTAssertEqual(requestID, 11)
            XCTAssertEqual(status, MetadataStatus.error.rawValue)
            XCTAssertTrue(body.isEmpty)
        }
    }

    func testSyncFontValidSpecAnswersOkAndPatchesTheFile() throws {
        let dir = NSTemporaryDirectory() + "performer-font-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        try Data(CodeServerManager.seededUserSettings.utf8).write(to: fileURL)

        let spec = MetadataCodec.CodeFontSpec(family: "JetBrains Mono", size: 14, lineHeight: 1.58)
        let response = HostCodeServerPerformer.response(
            requestID: 12, verb: MetadataVerb.syncCodeFont.rawValue,
            payload: MetadataCodec.encodeCodeFontSpec(spec),
            manager: makeManager(settingsFileURL: fileURL),
        )
        guard case let .metadataResponse(requestID, status, body)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 12)
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        XCTAssertTrue(body.isEmpty)
        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any],
        )
        XCTAssertEqual(try XCTUnwrap(settings["editor.fontSize"] as? Double), 14)
        XCTAssertEqual(try XCTUnwrap(settings["editor.lineHeight"] as? Double), 1.58)
    }

    func testSyncFontMissingSettingsFileStillAnswersOk() {
        // No settings file on the host is a no-op, not a failure — the spec decoded fine, and
        // "nothing to patch" must not surface an error toast client-side.
        let spec = MetadataCodec.CodeFontSpec(family: "JetBrains Mono", size: 14, lineHeight: 1.58)
        let response = HostCodeServerPerformer.response(
            requestID: 13, verb: MetadataVerb.syncCodeFont.rawValue,
            payload: MetadataCodec.encodeCodeFontSpec(spec), manager: makeManager(),
        )
        guard case let .metadataResponse(_, status, _)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
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
        let endpoint = try MetadataCodec.decodeServiceEndpoint(payload)
        XCTAssertEqual(endpoint.state, .starting)
    }

    // MARK: Verb 19 — openInCodeServer

    private func openResponse(
        payload: Data, manager: CodeServerManager, fallback: RunnerRecord = RunnerRecord(),
        fallbackStatus: MetadataStatus = .ok,
    ) -> (status: UInt8, payload: Data, fallbackCalls: [[String]])? {
        let response = HostCodeServerPerformer.response(
            requestID: 21, verb: MetadataVerb.openInCodeServer.rawValue, payload: payload,
            manager: manager,
            fallbackOpen: { path in
                fallback.record([path])
                return fallbackStatus
            },
        )
        guard case let .metadataResponse(requestID, status, payload)? = response else { return nil }
        XCTAssertEqual(requestID, 21)
        return (status, payload, fallback.calls)
    }

    func testOpenMalformedPayloadsAreError() {
        for bad in [Data(), Data("relative/path.txt".utf8), Data([0xFF, 0xFE])] {
            guard let reply = openResponse(payload: bad, manager: makeManager()) else {
                XCTFail("expected a metadataResponse")
                continue
            }
            XCTAssertEqual(reply.status, MetadataStatus.error.rawValue)
            XCTAssertTrue(reply.payload.isEmpty)
            XCTAssertTrue(reply.fallbackCalls.isEmpty, "a malformed target never opens anything")
        }
    }

    func testOpenMissingPathIsNotFoundEvenWithASuffix() {
        // The exists check runs on the BARE path — the :12:3 suffix must not defeat it.
        for target in ["/definitely/not/a/real/file.py", "/definitely/not/a/real/file.py:12:3"] {
            guard let reply = openResponse(payload: Data(target.utf8), manager: makeManager()) else {
                XCTFail("expected a metadataResponse")
                continue
            }
            XCTAssertEqual(reply.status, MetadataStatus.notFound.rawValue)
            XCTAssertTrue(reply.fallbackCalls.isEmpty)
        }
    }

    func testOpenDirectoryFallsBackToTheDefaultApp() throws {
        let root = NSTemporaryDirectory() + "open-dir-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cli = RunnerRecord()
        guard let reply = openResponse(
            payload: Data(root.utf8), manager: makeManager(cli: cli), fallbackStatus: .notFound,
        )
        else {
            XCTFail("expected a metadataResponse")
            return
        }
        // swiftlint:disable:next legacy_objc_type
        XCTAssertEqual(reply.fallbackCalls, [[(root as NSString).standardizingPath]])
        XCTAssertEqual(
            reply.status, MetadataStatus.notFound.rawValue,
            "the fallback's own status is the reply status",
        )
        XCTAssertEqual(Array(reply.payload), [1], "hostDefault — the client must NOT reveal the panel")
        XCTAssertTrue(cli.calls.isEmpty, "a directory never reaches the workbench CLI")
    }

    func testOpenFileWithoutBinaryFallsBackToTheDefaultApp() throws {
        let root = NSTemporaryDirectory() + "open-nobin-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/main.py"
        try Data().write(to: URL(fileURLWithPath: file))

        guard let reply = openResponse(
            payload: Data((file + ":12:3").utf8), manager: makeManager(binary: nil),
        )
        else {
            XCTFail("expected a metadataResponse")
            return
        }
        let canonicalFile = (file as NSString).standardizingPath // swiftlint:disable:this legacy_objc_type
        XCTAssertEqual(
            reply.fallbackCalls, [[canonicalFile]],
            "the fallback gets the BARE path — Finder/default apps cannot parse :line:col",
        )
        XCTAssertEqual(reply.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(Array(reply.payload), [1])
    }

    func testOpenFileWithBinaryGoesToTheWorkbench() async throws {
        let root = NSTemporaryDirectory() + "open-file-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/main.py"
        try Data().write(to: URL(fileURLWithPath: file))

        let cli = RunnerRecord()
        let landed = expectation(description: "the async CLI arm ran")
        cli.onRecord = { landed.fulfill() }
        // swiftlint:disable:next legacy_objc_type
        let canonicalFile = (file as NSString).standardizingPath
        guard let reply = openResponse(payload: Data((file + ":12:3").utf8), manager: makeManager(cli: cli))
        else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(reply.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(Array(reply.payload), [0], "workbench — the client reveals the code panel")
        XCTAssertTrue(reply.fallbackCalls.isEmpty, "the workbench path never touches the fallback")

        await fulfillment(of: [landed], timeout: 5)
        XCTAssertEqual(
            cli.calls, [["-r", canonicalFile + ":12:3"]],
            "the CLI target keeps the :line:col suffix the exists check stripped",
        )
    }

    func testSplitLineColSuffix() {
        let split = HostCodeServerPerformer.splitLineColSuffix
        XCTAssertTrue(split("/a/b.py:12:3") == ("/a/b.py", ":12:3"))
        XCTAssertTrue(split("/a/b.py:12") == ("/a/b.py", ":12"))
        XCTAssertTrue(split("/a/b.py") == ("/a/b.py", ""))
        XCTAssertTrue(split("/a/v1:2/f.txt") == ("/a/v1:2/f.txt", ""), "a mid-path colon is not a suffix")
        XCTAssertTrue(split(":42") == ("", ":42"), "a bare suffix leaves an empty path → the absolute guard rejects it")
        XCTAssertTrue(split("/a/b:1:2:3") == ("/a/b:1", ":2:3"), "at most two runs strip")
    }
}
