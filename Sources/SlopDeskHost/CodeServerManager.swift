import Foundation
import SlopDeskProtocol

/// One live (or launching) code-server child, held by ``CodeServerManager``. A protocol seam so unit
/// tests drive the manager with a fake — the hang-safety rule extends here: a unit test must NEVER
/// spawn a real code-server (a multi-second Node boot, a network listener, a Homebrew dependency).
protocol CodeServerProcessHandle: AnyObject, Sendable {
    /// Whether the child is still alive. `false` (crash, idle-timeout self-exit) makes the next
    /// ``CodeServerManager/ensure(projectRoot:)`` respawn.
    var isRunning: Bool { get }
    /// Asks the child to exit (SIGTERM). Idempotent.
    func terminate()
}

/// Supervises the HOST's code-server (VS Code web workbench) — the backend of the client's
/// right-sidebar embedded editor (``MetadataVerb/ensureCodeServer``).
///
/// **ONE shared instance, lazily.** code-server serves every folder from a single process — the
/// workbench resolves its folder from the client's `?folder=` query, so per-project children were
/// pure overhead (a Node runtime + extension host each) AND fought over the session socket
/// (`code-server-ipc.sock` is per user-data-dir; only the first child owns it, and the CLI's
/// open-in-running-session routing needs exactly one owner). The requested root is still validated
/// (never report an endpoint for a path the host cannot see → `.notFound` on the wire), but every
/// root shares the one child; each project keeps its own workbench state keyed by folder.
///
/// **`ensure` never waits.** It spawns (or observes) and returns the CURRENT state immediately: the
/// caller sits on the metadata queue answering an RPC whose client-side timeout is 5 s, and a
/// code-server cold start can exceed that. The child is spawned with port `0` (the OS picks) and
/// the real port is learned from the child's own `HTTP server listening on http://…` log line — no
/// pre-bind allocation race. `ready` means a TCP connect to the learned port succeeded, probed
/// at most once per ``probeInterval`` (the client polls ~1 Hz; a dead-port connect costs a syscall,
/// not a hang — the probe's timeout is bounded).
///
/// **Crash/idle recovery is implicit** (the cmux `VSCodeServeWebController` lesson): a child that
/// exited — including by its own `--idle-timeout-seconds` reaper — reads `isRunning == false` on
/// the next `ensure`, which drops the record and respawns fresh.
///
/// **No auth token.** The child runs `--auth none` on `0.0.0.0`: security = the WireGuard mesh,
/// identical to every other port hostd opens (docs/DECISIONS — no app-layer crypto/auth).
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes' requests race.
final class CodeServerManager: @unchecked Sendable {
    /// Finds the code-server executable, or `nil` when the host has none (→ `.unavailable`).
    typealias BinaryLocator = @Sendable () -> String?
    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port
    /// parse). Throws when the exec itself fails (missing/broken binary → `.unavailable`).
    typealias Spawner = @Sendable (
        _ binary: String, _ arguments: [String], _ onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any CodeServerProcessHandle
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = @Sendable (_ port: UInt16) -> Bool
    /// Seeds the code-server user settings before the FIRST spawn (see ``seedUserSettings(at:)``).
    typealias SettingsSeeder = @Sendable () -> Void
    /// Runs the code-server CLI once to completion and reports its exit status (`nil` = the exec
    /// itself failed). Distinct from ``Spawner`` — the CLI is a short-lived command whose EXIT CODE
    /// is the answer, not a supervised child.
    typealias CLIRunner = @Sendable (_ binary: String, _ arguments: [String]) async -> Int32?

    /// Idle self-shutdown handed to the child (`--idle-timeout-seconds`): a workbench nobody has
    /// open for 2 h reaps itself instead of holding a Node runtime forever; the next sidebar expand
    /// transparently respawns it.
    static let idleTimeoutSeconds = 7200

    private struct Instance {
        var handle: any CodeServerProcessHandle
        /// Learned from the child's log line; `nil` until it prints one.
        var port: UInt16?
        /// Latched on the first successful probe — a listening server is never un-probed.
        var ready = false
        var lastProbe: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var instance: Instance?
    /// Bumped per spawn; a stale child's log sink (a respawn raced its last line) must not write
    /// its old port onto the fresh instance record.
    private var spawnGeneration = 0
    /// Latched by the first spawn — the settings seed runs at most once per manager lifetime (the
    /// seeder itself is also a no-op when the file exists; this just skips the repeat file checks).
    private var settingsSeeded = false
    private let locateBinary: BinaryLocator
    private let spawn: Spawner
    private let probe: ReadinessProbe
    private let seedSettings: SettingsSeeder
    private let runCLI: CLIRunner
    private let probeInterval: Duration
    private let openRetryDelay: Duration
    private let clock = ContinuousClock()

    init(
        binaryLocator: @escaping BinaryLocator = CodeServerManager.defaultBinaryLocator,
        spawner: @escaping Spawner = CodeServerManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = CodeServerManager.defaultReadinessProbe,
        settingsSeeder: @escaping SettingsSeeder = CodeServerManager.defaultSettingsSeeder,
        cliRunner: @escaping CLIRunner = CodeServerManager.defaultCLIRunner,
        probeInterval: Duration = .milliseconds(500),
        openRetryDelay: Duration = .seconds(2),
    ) {
        locateBinary = binaryLocator
        spawn = spawner
        probe = readinessProbe
        seedSettings = settingsSeeder
        runCLI = cliRunner
        self.probeInterval = probeInterval
        self.openRetryDelay = openRetryDelay
    }

    /// Ensures the shared code-server and reports where it stands RIGHT NOW (never waits). `nil`
    /// when `projectRoot` is not an absolute path to an existing host directory (→ `.notFound` on
    /// the wire — never hand out an endpoint for a path the host cannot see).
    func ensure(projectRoot: String) -> MetadataCodec.CodeServerEndpoint? {
        guard Self.canonicalRoot(projectRoot) != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }

        if let existing = instance {
            if existing.handle.isRunning {
                return endpointLocked(for: existing)
            }
            instance = nil
        }

        guard let binary = locateBinary() else {
            return MetadataCodec.CodeServerEndpoint(state: .unavailable, port: 0)
        }
        // Seed the workbench defaults before the FIRST child ever boots — after it has read an
        // absent settings file once, a seed would need a reload to take. One `stat` + at most one
        // tiny write under the lock, once per manager lifetime.
        if !settingsSeeded {
            settingsSeeded = true
            seedSettings()
        }
        spawnGeneration += 1
        let generation = spawnGeneration
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            guard let port = Self.parseListeningPort(fromLogLine: line) else { return }
            self?.recordPort(port, spawnedAs: generation)
        }
        guard let handle = try? spawn(binary, Self.launchArguments(), onLine) else {
            return MetadataCodec.CodeServerEndpoint(state: .unavailable, port: 0)
        }
        instance = Instance(handle: handle)
        return MetadataCodec.CodeServerEndpoint(state: .starting, port: 0)
    }

    /// Opens `target` (a host file path, optionally `:line[:col]`-suffixed) in the running
    /// workbench: `code-server -r <target>` routed through the session socket to the most recently
    /// registered open workbench (folder-prefix matches sort first). Ensures the SERVER first (the
    /// panel may have been collapsed, its child never spawned), then retries the CLI asynchronously —
    /// the workbench SESSION registers only once a client's webview has booted the page, and the
    /// client typically expands the panel in the same breath as this call, so the first attempts can
    /// legitimately race a multi-second boot. Returns the retry task (`nil` when there is no
    /// code-server binary — the caller falls back to a default-app open); the caller does NOT await
    /// it (accepted-not-completed, mirroring `ensure`'s never-wait contract).
    @discardableResult
    func openInWorkbench(target: String, projectRoot: String) -> Task<Bool, Never>? {
        guard let binary = locateBinary() else { return nil }
        _ = ensure(projectRoot: projectRoot)
        let run = runCLI
        let delay = openRetryDelay
        return Task {
            for attempt in 0..<Self.openAttempts {
                if await run(binary, ["-r", target]) == 0 { return true }
                guard attempt + 1 < Self.openAttempts else { break }
                try? await Task.sleep(for: delay)
            }
            FileHandle.standardError.write(Data(
                "slopdesk-hostd: code-server -r \(target) never landed (no workbench session?)\n".utf8,
            ))
            return false
        }
    }

    /// CLI open retries: 10 × the 2 s ``openRetryDelay`` ≈ an 18 s window — covers a cold server
    /// boot + the client's poll + the webview's workbench boot before the session socket exists.
    static let openAttempts = 10

    /// Terminates the child (host shutdown). It also self-reaps on idle, but hostd going down must
    /// not strand a Node process.
    func shutdown() {
        lock.lock()
        let stranded = instance
        instance = nil
        lock.unlock()
        stranded?.handle.terminate()
    }

    // MARK: - Locked helpers

    /// Computes the endpoint for the LIVE instance, probing readiness at most once per
    /// ``probeInterval``. Caller holds `lock`.
    private func endpointLocked(for live: Instance) -> MetadataCodec.CodeServerEndpoint {
        guard let port = live.port else {
            return MetadataCodec.CodeServerEndpoint(state: .starting, port: 0)
        }
        if live.ready {
            return MetadataCodec.CodeServerEndpoint(state: .ready, port: port)
        }
        var updated = live
        let now = clock.now
        let due = live.lastProbe.map { now - $0 >= probeInterval } ?? true
        if due {
            updated.lastProbe = now
            updated.ready = probe(port)
            instance = updated
        }
        return MetadataCodec.CodeServerEndpoint(state: updated.ready ? .ready : .starting, port: port)
    }

    private func recordPort(_ port: UInt16, spawnedAs generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == spawnGeneration, var live = instance, live.port == nil else { return }
        live.port = port
        instance = live
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// Normalizes a request root: absolute, trailing-`/` trimmed (matching `projectKey`'s own
    /// normalization so one project cannot spawn twins), and an EXISTING directory. `nil` otherwise.
    static func canonicalRoot(
        _ path: String, fileManager: FileManager = .default,
    ) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var root = path
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return root
    }

    /// The child's argv (after the binary path). No folder argument — a positional path is only a
    /// DEFAULT; every client names its folder in the workbench URL's `?folder=` query, and one
    /// process serves them all. Port `0` = the OS picks; the real port comes back through
    /// ``parseListeningPort(fromLogLine:)``. `0.0.0.0` so mesh clients can reach it — the same
    /// exposure as every hostd listener.
    static func launchArguments() -> [String] {
        [
            "--auth", "none",
            "--bind-addr", "0.0.0.0:0",
            // The workbench titles itself "{{app}}" in a handful of strings (title bar, PWA name);
            // this is the embedded editor of SlopDesk, not a standalone code-server deployment.
            "--app-name", "SlopDesk",
            "--disable-telemetry",
            "--disable-update-check",
            "--disable-workspace-trust",
            "--disable-getting-started-override",
            "--idle-timeout-seconds", String(idleTimeoutSeconds),
        ]
    }

    /// The user settings seeded on a pristine host — the workbench must come up in the app's OWN
    /// theme (`SlopDesk Monokai`, the seeded extension below — the Monokai Pro filter the whole
    /// client chrome derives from, chrome accents neutralized) and CHROME-LESS, the panel's top
    /// edge being the EXPLORER header itself: title bar, activity bar, menu bar, and status bar
    /// all hidden. Ordering matters to the workbench, not just taste — `activityBar.location`
    /// "top"/"bottom" (the old v3–v5 fold) FORCES the title bar visible and even rewrites a
    /// `customTitleBarVisibility: "never"` back to `"auto"`; only "hidden" (plus command
    /// center / layout / navigation controls off and the menu bar hidden) lets "never" stick.
    /// View switching is keyboard-first (⌘⇧E / ⌘⇧F / ⌃⇧G, ⌘, — chords the client webview
    /// deliberately passes through), matching the app's zero-chrome register. The sidebar sits on
    /// the RIGHT (the panel hangs off the window's right edge, so the file tree hugs that edge
    /// and the editor faces the terminal). The editor face matches the terminal's: `ui-monospace`
    /// resolves to SF Mono in WebKit — the terminal's default family — at the terminal's default
    /// 13pt, falling back to "Symbols Nerd Font" for the private-use glyphs SF Mono lacks (the
    /// client injects that face as an @font-face data URI — `CodeSidebarPageDressing`; the name
    /// here and the name there must agree). Status-bar duties are already covered app-side (the project git readout) or by
    /// chords (⌘⇧M problems); `window.title` drops the `${appName}` suffix so any surface that
    /// ever renders it says the project, not "code-server". Auto-save on focus change: the
    /// terminal pane beside the editor is where builds/tests run, and switching to it IS the
    /// moment the file must be on disk. Every key here is USER-scope-overridable in the workbench
    /// (user settings land in this same file and win on conflict-free keys the user later edits —
    /// see the pristine-upgrade rule in ``seedUserSettings(at:)``).
    static let seededUserSettings = """
    {
        "workbench.colorTheme": "SlopDesk Monokai",
        "workbench.startupEditor": "none",
        "workbench.activityBar.location": "hidden",
        "workbench.sideBar.location": "right",
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "window.customTitleBarVisibility": "never",
        "window.menuBarVisibility": "hidden",
        "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
        "window.density.editorTabHeight": "compact",
        "workbench.statusBar.visible": false,
        "workbench.editor.empty.hint": "hidden",
        "chat.disableAIFeatures": true,
        "chat.commandCenter.enabled": false,
        "window.commandCenter": false,
        "workbench.layoutControl.enabled": false,
        "workbench.navigationControl.enabled": false,
        "workbench.tips.enabled": false,
        "extensions.ignoreRecommendations": true,
        "editor.minimap.enabled": false,
        "breadcrumbs.enabled": false,
        "editor.fontFamily": "ui-monospace, Menlo, 'Symbols Nerd Font', monospace",
        "editor.fontSize": 13,
        "editor.overviewRulerBorder": false,
        "editor.hideCursorInOverviewRuler": true,
        "files.autoSave": "onFocusChange"
    }
    """

    /// Every seed this manager EVER shipped before the current one. A settings file byte-identical
    /// to a former seed is still PRISTINE — the user never touched it (the workbench rewrites the
    /// file on any settings edit) — so it may be upgraded to the current seed. Anything else is the
    /// user's and stays untouchable.
    static let obsoleteSeeds: [String] = [
        // v1 — theme + no welcome tab.
        """
        {
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.startupEditor": "none"
        }
        """,
        // v2 — the lean pass (AI off, title-bar strips off), activity bar still its own column.
        """
        {
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.startupEditor": "none",
            "chat.disableAIFeatures": true,
            "chat.commandCenter.enabled": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false
        }
        """,
        // v3 — activity bar folded into the sidebar top, auxiliary sidebar pinned hidden.
        """
        {
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "top",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.customTitleBarVisibility": "never",
            "chat.disableAIFeatures": true,
            "chat.commandCenter.enabled": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false
        }
        """,
        // v4 — auto-save on focus change; still the stock dark theme, sidebar still left.
        """
        {
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "top",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.customTitleBarVisibility": "never",
            "chat.disableAIFeatures": true,
            "chat.commandCenter.enabled": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v5 — the SlopDesk Monokai theme + sidebar right; activity bar still folded into the
        // sidebar top, which force-showed the workbench title bar.
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.customTitleBarVisibility": "never",
            "chat.disableAIFeatures": true,
            "chat.commandCenter.enabled": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "files.autoSave": "onFocusChange"
        }
        """,
    ]

    /// Writes ``seededUserSettings`` to `fileURL` when no file exists there — or when the existing
    /// file is byte-identical to a FORMER seed (pristine, never user-edited ⇒ safe to upgrade). An
    /// operator's own settings are never touched. Returns whether it wrote; any failure is a
    /// silent no-op (a seed is a nicety — the workbench works unthemed).
    @discardableResult
    static func seedUserSettings(at fileURL: URL, fileManager: FileManager = .default) -> Bool {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let existing = try String(contentsOf: fileURL, encoding: .utf8)
                guard obsoleteSeeds.contains(existing) else { return false }
                try Data(seededUserSettings.utf8).write(to: fileURL)
                return true
            }
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data(seededUserSettings.utf8).write(to: fileURL, options: [.withoutOverwriting])
            return true
        } catch {
            return false
        }
    }

    /// Where THIS process's code-server children read user settings: `--user-data-dir` is not
    /// passed, so code-server resolves `$XDG_DATA_HOME/code-server` (absolute values only), else
    /// `~/.local/share/code-server`, then `User/settings.json` inside it. "Home" must be what
    /// Node's `os.homedir()` answers IN THE CHILD — `$HOME` first — never `NSHomeDirectory()`/
    /// `homeDirectoryForCurrentUser` (both resolve through directory services, blind to a `HOME`
    /// override: a gate-sandboxed hostd seeded the REAL user's file while its children read the
    /// sandbox's).
    static func userSettingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL {
        dataDirURL(environment: environment).appendingPathComponent("User/settings.json")
    }

    /// The code-server data dir the child resolves (same `$XDG_DATA_HOME` → `$HOME` walk as
    /// ``userSettingsURL(environment:)``) — settings live under `User/`, seeded extensions under
    /// `extensions/`.
    static func dataDirURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL {
        let dataHome: URL =
            if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
                URL(fileURLWithPath: xdg)
            } else if let home = environment["HOME"], home.hasPrefix("/") {
                URL(fileURLWithPath: home).appendingPathComponent(".local/share")
            } else {
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            }
        return dataHome.appendingPathComponent("code-server")
    }

    // MARK: - Theme extension seed

    /// The seeded theme extension's folder name — `publisher.name-version`, the layout code-server's
    /// extension scanner reads without any registry entry. A version bump here re-seeds changed
    /// theme bytes on the next hostd start (the writer overwrites on content drift).
    static let themeExtensionDirectoryName = "slopdesk.slopdesk-monokai-1.0.0"

    /// The theme extension's manifest. The theme itself (`SlopDesk Monokai`) is the Monokai Pro
    /// filter the whole client chrome derives from (`SlateDesign`'s seeds), with the CHROME accent
    /// yellows neutralized to the app's accent-neutral register (selection/active state = brightness,
    /// not hue; links take the filter cyan). Derived from Monokai Pro by Monokai (monokai.pro) —
    /// personal-use derivation seeded into the user's own code-server, never redistributed.
    static let themeExtensionManifest = """
    {
        "name": "slopdesk-monokai",
        "displayName": "SlopDesk Monokai",
        "description": "SlopDesk's workbench theme, derived from Monokai Pro by Monokai (monokai.pro).",
        "publisher": "slopdesk",
        "version": "1.0.0",
        "engines": { "vscode": "^1.0.0" },
        "categories": ["Themes"],
        "contributes": {
            "themes": [
                {
                    "label": "SlopDesk Monokai",
                    "uiTheme": "vs-dark",
                    "path": "./themes/slopdesk-monokai-color-theme.json"
                }
            ]
        }
    }
    """

    /// The theme JSON carried as a target resource (596 colour keys — too large for a literal).
    /// `nil` only if the bundle is broken (then the seed is a no-op and the workbench falls back
    /// to its stock dark theme — a nicety, never a failure).
    static func themeExtensionThemeData() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "Resources/slopdesk-monokai-color-theme", withExtension: "json",
        ) ?? Bundle.module.url(forResource: "slopdesk-monokai-color-theme", withExtension: "json")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes the theme extension under `extensionsDir` (creating directories), overwriting OUR
    /// files when their bytes drifted from the current seed — the folder is namespaced
    /// `slopdesk.*`, so unlike the settings file it is ours to keep current, never the user's.
    /// Returns whether anything was written; failures are silent no-ops (see the settings seeder).
    @discardableResult
    static func seedThemeExtension(
        into extensionsDir: URL, themeData: Data? = themeExtensionThemeData(),
        fileManager: FileManager = .default,
    ) -> Bool {
        guard let themeData else { return false }
        let root = extensionsDir.appendingPathComponent(themeExtensionDirectoryName)
        let files: [(URL, Data)] = [
            (root.appendingPathComponent("package.json"), Data(themeExtensionManifest.utf8)),
            (root.appendingPathComponent("themes/slopdesk-monokai-color-theme.json"), themeData),
        ]
        var wrote = false
        for (url, data) in files where (try? Data(contentsOf: url)) != data {
            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                )
                try data.write(to: url)
                wrote = true
            } catch {
                return wrote
            }
        }
        return wrote
    }

    /// Extracts the bound port from code-server's own announcement, e.g.
    /// `[…] info  HTTP server listening on http://0.0.0.0:62636/`. `nil` for every other line.
    static func parseListeningPort(fromLogLine line: String) -> UInt16? {
        guard let markerRange = line.range(of: "HTTP server listening on http://") else { return nil }
        let rest = line[markerRange.upperBound...]
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let digits = rest[rest.index(after: colon)...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let port = UInt16(digits), port > 0 else { return nil }
        return port
    }

    // MARK: - Production seams

    /// The production ``SettingsSeeder``: ``seedUserSettings(at:)`` on the resolved settings path,
    /// plus the ``seedThemeExtension(into:themeData:fileManager:)`` the seeded theme name refers to.
    static let defaultSettingsSeeder: SettingsSeeder = {
        seedUserSettings(at: userSettingsURL())
        seedThemeExtension(into: dataDirURL().appendingPathComponent("extensions"))
    }

    /// `SLOPDESK_CODE_SERVER_BIN` override, else a `PATH` walk plus the Homebrew/npm homes `PATH`
    /// misses when hostd is launched outside a login shell.
    static let defaultBinaryLocator: BinaryLocator = {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SLOPDESK_CODE_SERVER_BIN"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        var directories = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        for directory in directories {
            let candidate = directory + "/code-server"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The production ``CLIRunner``: run to completion, answer the exit status. Output is discarded
    /// (the exit code is the whole answer; code-server's "No opened code-server instances found"
    /// complaint arrives as a non-zero exit).
    static let defaultCLIRunner: CLIRunner = { binary, arguments in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // Never ran ⇒ the termination handler will never fire — resume here instead.
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }

    /// Foundation `Process` + a line-splitting pipe drain on a utility queue. stdout and stderr are
    /// MERGED into one pipe — code-server logs the listening line to stdout, but merging means a
    /// future build moving it cannot silently break the port parse.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(chunk) {
                onLogLine(line)
            }
        }
        try process.run()
        return ProcessHandleAdapter(process: process)
    }

    /// Accumulates pipe chunks and yields complete lines (lock-guarded — the readability handler
    /// runs on a FileHandle-owned queue, and Sendable closures may not mutate captured vars).
    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            var complete: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(bytes: lineBytes, encoding: .utf8) {
                    complete.append(line)
                }
            }
            return complete
        }
    }

    /// Bounded TCP connect to `127.0.0.1:port` (~250 ms): listening ⇒ `true`. Non-blocking socket +
    /// `poll(2)` — a filtered/blackholed port times out instead of hanging the metadata queue.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, 250) == 1 else { return false }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else { return false }
        return soError == 0
    }

    /// The production ``CodeServerProcessHandle``.
    private final class ProcessHandleAdapter: CodeServerProcessHandle, @unchecked Sendable {
        private let process: Process

        init(process: Process) {
            self.process = process
        }

        var isRunning: Bool { process.isRunning }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
        }
    }
}
