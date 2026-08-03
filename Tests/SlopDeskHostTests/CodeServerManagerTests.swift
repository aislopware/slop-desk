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
        // The seeder, CLI runner AND settings-file URL are ALWAYS injected — the default seams
        // write the real user's `~/.local/share/code-server` settings / exec a real binary, which
        // no test may touch.
        let settingsURL = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
        return CodeServerManager(
            binaryLocator: { binary },
            spawner: { bin, args, onLine in spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            settingsSeeder: settingsSeeder,
            cliRunner: cliRunner,
            settingsFileURL: { settingsURL },
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
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "SlopDesk Monokai")
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
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "SlopDesk Monokai")
        XCTAssertEqual(settings["workbench.startupEditor"] as? String, "none")
        // The lean pass: title-bar strips gone, editor chrome minimal.
        XCTAssertEqual(settings["window.commandCenter"] as? Bool, false)
        XCTAssertEqual(settings["workbench.layoutControl.enabled"] as? Bool, false)
        XCTAssertEqual(settings["editor.minimap.enabled"] as? Bool, false)
        // The chrome-less recipe: activity bar "hidden" + menu bar hidden + the strips off — that
        // combination alone hides the web title bar ("top"/"bottom" force-shows it).
        // v12: the activity-bar icons fold into the sidebar TOP (user-directed) — Search / Source
        // Control / Extensions are clickable again; fully "hidden" left them chord-only.
        XCTAssertEqual(settings["workbench.activityBar.location"] as? String, "top")
        XCTAssertEqual(settings["window.menuBarVisibility"] as? String, "hidden")
        XCTAssertEqual(settings["workbench.statusBar.visible"] as? Bool, false)
        // Every seeded key must be REGISTERED in the shipped web workbench — the settings editor
        // flags unknown keys as warnings in a file we authored. These three were v6's offenders
        // (desktop-only / Code-OSS-absent): they must never come back.
        XCTAssertNil(settings["window.customTitleBarVisibility"])
        XCTAssertNil(settings["chat.disableAIFeatures"])
        XCTAssertNil(settings["chat.commandCenter.enabled"])
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
        // Any surface that ever renders the title says the project, never "code-server".
        XCTAssertEqual(
            settings["window.title"] as? String,
            "${dirty}${activeEditorShort}${separator}${rootName}",
        )
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
        XCTAssertEqual(themes.count, 2)
        // The settings seed selects the themes BY LABEL — a drift here is a silent stock-theme
        // boot. Dark is the base `workbench.colorTheme` AND the preferred-dark; light is the
        // preferred-light the seeded `window.autoDetectColorScheme` flips to on a light client.
        XCTAssertEqual(themes[0]["label"] as? String, "SlopDesk Monokai")
        XCTAssertEqual(themes[0]["uiTheme"] as? String, "vs-dark")
        XCTAssertEqual(themes[1]["label"] as? String, "SlopDesk Monokai Light")
        XCTAssertEqual(themes[1]["uiTheme"] as? String, "vs")
        let seeded = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(CodeServerManager.seededUserSettings.utf8),
            ) as? [String: Any],
        )
        XCTAssertEqual(seeded["workbench.colorTheme"] as? String, themes[0]["label"] as? String)
        XCTAssertEqual(seeded["window.autoDetectColorScheme"] as? Bool, true)
        XCTAssertEqual(
            seeded["workbench.preferredDarkColorTheme"] as? String, themes[0]["label"] as? String,
        )
        XCTAssertEqual(
            seeded["workbench.preferredLightColorTheme"] as? String, themes[1]["label"] as? String,
        )
        // The folder name pins the manifest identity (publisher.name-version).
        let identity = "\(manifest["publisher"] as? String ?? "").\(manifest["name"] as? String ?? "")"
            + "-\(manifest["version"] as? String ?? "")"
        XCTAssertEqual(identity, CodeServerManager.themeExtensionDirectoryName)
        // The theme paths in the manifest match the files the seeder writes.
        XCTAssertEqual(themes[0]["path"] as? String, "./themes/slopdesk-monokai-color-theme.json")
        XCTAssertEqual(
            themes[1]["path"] as? String, "./themes/slopdesk-monokai-light-color-theme.json",
        )
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
        // The Slate PLATE model: stock Monokai Pro flattens strip/active/inactive to one surface
        // and leans on the (neutralized, then CSS-hidden) underline — the active tab instead takes
        // the app's own active-tab card tone (`elevated`, ≡ foreground @9% over the strip = Slate
        // `selected`), hover the Slate hover tint; inactive stays flush with the strip.
        XCTAssertEqual(colors["tab.activeBackground"] as? String, "#403e41")
        XCTAssertEqual(colors["tab.hoverBackground"] as? String, "#fcfcfa0d")
        XCTAssertEqual(colors["tab.inactiveBackground"] as? String, "#2d2a2e")
        // Semantic yellows stay Monokai (git-modified — the app's own git ramp uses yellow there).
        XCTAssertEqual(colors["gitDecoration.modifiedResourceForeground"] as? String, "#ffd866")
        // The settings editor's checkbox mark follows the plain checkbox — the ONE chrome key the
        // neutralization pass originally missed (it sat accent-yellow beside a neutral twin).
        XCTAssertEqual(
            colors["settings.checkboxForeground"] as? String, colors["checkbox.foreground"] as? String,
        )
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

    func testLightThemeResourceIsValidLightThemeWithNeutralizedChrome() throws {
        let data = try XCTUnwrap(
            CodeServerManager.themeExtensionThemeData(resource: "slopdesk-monokai-light-color-theme"),
            "the bundled light theme resource must resolve",
        )
        let theme = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(theme["name"] as? String, "SlopDesk Monokai Light")
        XCTAssertEqual(theme["type"] as? String, "light")
        let colors = try XCTUnwrap(theme["colors"] as? [String: Any])
        // Monokai Pro Light surfaces = the app's own light Slate seed (monokaiProClassicLight).
        XCTAssertEqual(colors["editor.background"] as? String, "#faf4f2")
        XCTAssertEqual(colors["editor.foreground"] as? String, "#29242a")
        // The SlopDesk fit, mirrored: the light filter's chrome accent is PINK (#e14775) — the
        // same 17 keys the dark transform moved go accent-neutral here; links take the light cyan.
        XCTAssertEqual(colors["tab.activeForeground"] as? String, "#29242a")
        XCTAssertEqual(colors["tab.activeBorder"] as? String, "#918c8e")
        XCTAssertEqual(colors["list.activeSelectionForeground"] as? String, "#29242a")
        XCTAssertEqual(colors["textLink.foreground"] as? String, "#1c8ca8")
        // The Slate plate model, mirrored (light `elevated` = white; hover = Slate's light tint).
        XCTAssertEqual(colors["tab.activeBackground"] as? String, "#ffffff")
        XCTAssertEqual(colors["tab.hoverBackground"] as? String, "#0000000b")
        XCTAssertEqual(colors["tab.inactiveBackground"] as? String, "#faf4f2")
        // Semantic pinks stay Monokai — only the CHROME keys moved (deleted-file decoration
        // keeps the filter's pink, exactly as the dark theme keeps its semantic yellows).
        XCTAssertEqual(colors["gitDecoration.deletedResourceForeground"] as? String, "#e14775")
        // Mirrored settings-checkbox neutralization + no invalid values (see the dark test).
        XCTAssertEqual(
            colors["settings.checkboxForeground"] as? String, colors["checkbox.foreground"] as? String,
        )
        try assertEveryColorValueIsValidHex(colors)
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

    func testSeedThemeExtensionRegistersInTheProfileRegistry() throws {
        // The registry (`extensions.json`) — not the directory scan — is the workbench's source of
        // truth once the file exists: code-server writes an empty `[]` on first boot, and a
        // folder-dropped extension is then INVISIBLE (observed: the seeded theme fell back to the
        // stock dark). The seeder therefore registers what it drops.
        let dir = URL(fileURLWithPath: root).appendingPathComponent("extensions")
        let registry = dir.appendingPathComponent("extensions.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: registry)

        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
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
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))

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
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
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
        XCTAssertFalse(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
        XCTAssertEqual(try Data(contentsOf: registry), Data("not json".utf8))

        // A MISSING registry file is created carrying our entry (fresh install: the seed runs
        // before code-server's first boot; that boot keeps existing entries).
        try FileManager.default.removeItem(at: registry)
        XCTAssertTrue(CodeServerManager.seedThemeExtension(into: dir, themeData: Data("{}".utf8)))
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
    ) -> CodeServerManager {
        // settingsSeeder / cliRunner / settingsFileURL injected as fakes — the default seams touch
        // the real user's settings file / exec a real binary.
        let settingsURL = settingsFileURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("performer-tests-absent-\(UUID().uuidString).json")
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
            settingsFileURL: { settingsURL },
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
