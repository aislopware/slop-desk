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
        settingsSeeder: @escaping @Sendable () -> Void = {},
        cliRunner: @escaping CodeServerManager.CLIRunner = { _, _ in nil },
    ) -> CodeServerManager {
        // The seeder and CLI runner are ALWAYS injected — the default seams write the real user's
        // `~/.local/share/code-server` settings / exec a real binary, which no test may touch.
        CodeServerManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            settingsSeeder: settingsSeeder,
            cliRunner: cliRunner,
            probeInterval: .zero,
            openRetryDelay: .zero,
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
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "SlopDesk Monokai")
        XCTAssertEqual(settings["workbench.startupEditor"] as? String, "none")
        // The lean pass: AI/chat fully off, title-bar strips gone, editor chrome minimal, and the
        // activity bar folded into the top of the sidebar (one column in a narrow panel).
        XCTAssertEqual(settings["chat.disableAIFeatures"] as? Bool, true)
        XCTAssertEqual(settings["window.commandCenter"] as? Bool, false)
        XCTAssertEqual(settings["workbench.layoutControl.enabled"] as? Bool, false)
        XCTAssertEqual(settings["editor.minimap.enabled"] as? Bool, false)
        XCTAssertEqual(settings["workbench.activityBar.location"] as? String, "top")
        // The file tree hugs the window's right edge — the panel hangs off it.
        XCTAssertEqual(settings["workbench.sideBar.location"] as? String, "right")
        // Auto-save on focus change — leaving the editor for the terminal puts the file on disk.
        XCTAssertEqual(settings["files.autoSave"] as? String, "onFocusChange")
    }

    // MARK: Theme extension seed

    func testThemeExtensionManifestAndThemeAreValidAndAgreeOnTheLabel() throws {
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(CodeServerManager.themeExtensionManifest.utf8),
            ) as? [String: Any],
        )
        let contributes = try XCTUnwrap(manifest["contributes"] as? [String: Any])
        let themes = try XCTUnwrap(contributes["themes"] as? [[String: Any]])
        XCTAssertEqual(themes.count, 1)
        // The settings seed selects the theme BY LABEL — a drift here is a silent stock-theme boot.
        XCTAssertEqual(themes.first?["label"] as? String, "SlopDesk Monokai")
        let seeded = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(CodeServerManager.seededUserSettings.utf8),
            ) as? [String: Any],
        )
        XCTAssertEqual(seeded["workbench.colorTheme"] as? String, themes.first?["label"] as? String)
        // The folder name pins the manifest identity (publisher.name-version).
        let identity = "\(manifest["publisher"] as? String ?? "").\(manifest["name"] as? String ?? "")"
            + "-\(manifest["version"] as? String ?? "")"
        XCTAssertEqual(identity, CodeServerManager.themeExtensionDirectoryName)
        // The theme path in the manifest matches the file the seeder writes.
        XCTAssertEqual(themes.first?["path"] as? String, "./themes/slopdesk-monokai-color-theme.json")
    }

    func testThemeResourceIsValidDarkThemeWithNeutralizedChrome() throws {
        let data = try XCTUnwrap(
            CodeServerManager.themeExtensionThemeData(), "the bundled theme resource must resolve",
        )
        let theme = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(theme["name"] as? String, "SlopDesk Monokai")
        XCTAssertEqual(theme["type"] as? String, "dark")
        let colors = try XCTUnwrap(theme["colors"] as? [String: Any])
        // Monokai Pro surfaces = the app's own Slate seeds (SlateDesign monokaiProClassic).
        XCTAssertEqual(colors["editor.background"] as? String, "#2d2a2e")
        XCTAssertEqual(colors["sideBar.background"] as? String, "#221f22")
        // The SlopDesk fit: the CHROME accent is neutral (brightness, not hue) — the stock theme's
        // yellow active-tab/list accents must not survive; links take the filter cyan.
        XCTAssertEqual(colors["tab.activeForeground"] as? String, "#fcfcfa")
        XCTAssertEqual(colors["list.activeSelectionForeground"] as? String, "#fcfcfa")
        XCTAssertEqual(colors["textLink.foreground"] as? String, "#78dce8")
        // Semantic yellows stay Monokai (git-modified — the app's own git ramp uses yellow there).
        XCTAssertEqual(colors["gitDecoration.modifiedResourceForeground"] as? String, "#ffd866")
        XCTAssertFalse(
            try XCTUnwrap(theme["tokenColors"] as? [Any]).isEmpty,
            "syntax rules ride along — the Monokai identity",
        )
    }

    func testSeedThemeExtensionWritesOnceThenRepairsDrift() throws {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
        let themeFile = dir
            .appendingPathComponent(CodeServerManager.themeExtensionDirectoryName)
            .appendingPathComponent("themes/slopdesk-monokai-color-theme.json")
        XCTAssertEqual(try Data(contentsOf: themeFile), Data("{}".utf8))

        // Byte-identical ⇒ idempotent no-op.
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))

        // OUR file drifted (a newer seed, a truncated write) ⇒ repaired — unlike the user's
        // settings file, the namespaced extension folder is ours to keep current.
        try Data("stale".utf8).write(to: themeFile)
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
        XCTAssertEqual(try Data(contentsOf: themeFile), Data("{}".utf8))

        // No resource (broken bundle) ⇒ silent no-op, nothing half-written.
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: nil))
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
    ) -> CodeServerManager {
        // settingsSeeder / cliRunner injected as fakes — the default seams touch the real user's
        // settings file / exec a real binary.
        CodeServerManager(
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

    private final class NeverExitingHandle: CodeServerProcessHandle, @unchecked Sendable {
        var isRunning: Bool { true }
        func terminate() {}
    }

    func testOtherVerbsFallThrough() {
        let embedded: Set<MetadataVerb> = [.ensureCodeServer, .openInCodeServer]
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
