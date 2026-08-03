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
    /// Where the instance-level font sync writes — injectable so unit tests NEVER resolve (and
    /// patch) the developer's real `~/.local/share/code-server/User/settings.json` (the same trap
    /// `SLOPDESK_WORKSPACE_STATE_DIR` guards on the workspace store).
    private let settingsFileURL: @Sendable () -> URL
    private let probeInterval: Duration
    private let openRetryDelay: Duration
    private let clock = ContinuousClock()

    init(
        binaryLocator: @escaping BinaryLocator = CodeServerManager.defaultBinaryLocator,
        spawner: @escaping Spawner = CodeServerManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = CodeServerManager.defaultReadinessProbe,
        settingsSeeder: @escaping SettingsSeeder = CodeServerManager.defaultSettingsSeeder,
        cliRunner: @escaping CLIRunner = CodeServerManager.defaultCLIRunner,
        settingsFileURL: @escaping @Sendable () -> URL = { CodeServerManager.userSettingsURL() },
        probeInterval: Duration = .milliseconds(500),
        openRetryDelay: Duration = .seconds(2),
    ) {
        locateBinary = binaryLocator
        spawn = spawner
        probe = readinessProbe
        seedSettings = settingsSeeder
        runCLI = cliRunner
        self.settingsFileURL = settingsFileURL
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

    /// The user settings seeded on a pristine host — the workbench must come up in the app's
    /// theme (`Monokai Pro` / `Monokai Pro Light` from the seeded extension below, which ships
    /// ALL EIGHT stock Monokai Pro variants with only the seam borders retinted; the seeded pair
    /// is the two filters the client chrome itself runs on;
    /// `window.autoDetectColorScheme` flips between them with each CLIENT's own appearance — the
    /// webview's `prefers-color-scheme` follows the window's Slate-pinned `NSAppearance`, so a
    /// light client gets a light editor while a dark client on the same host stays dark, from the
    /// one shared settings file) and LEAN: menu bar hidden, the ACTIVITY-BAR icons
    /// folded into the sidebar TOP (`activityBar.location: "top"`, user-directed v12 — fully
    /// "hidden" left Search / Source Control / Extensions reachable by chord only). The "top"
    /// location FORCE-SHOWS the web title bar (re-confirmed on 4.112, the v6-era observation): it
    /// must host the relocated global actions (accounts + manage). No seedable key hides it
    /// (`window.customTitleBarVisibility` stays desktop-only/UNREGISTERED — v7 dropped it,
    /// pixel-verified equal), so the CLIENT clips the band off instead — the macOS webview mount
    /// overhangs its container by the title-bar height (`CodeSidebarWebView.clippedTitleBarHeight`,
    /// user-directed v13 era). Command-center/layout/navigation stay off regardless: any other
    /// client (iOS later) sees the quiet band, not the stripped-out extras. v13 also slims the
    /// editor GUTTER — the panel is a READING surface beside a terminal, where a five-char
    /// line-number reserve plus breakpoint glyph margin plus folding arrows spent ~½ of a code
    /// column's leading edge on emptiness (user-directed): `lineNumbersMinChars` 3,
    /// `glyphMargin` off (no debugger here), `folding` off (the arrows column; ⌘⇧P still folds
    /// by command for the rare need). Every key seeded must be REGISTERED in the shipped web
    /// workbench's configuration schema (the settings editor flags unknown keys as warnings in a
    /// file we authored — the chat.* pair died with v6 for the same reason).
    /// View switching is keyboard-first (⌘⇧E / ⌘⇧F / ⌃⇧G, ⌘, — chords the client webview
    /// deliberately passes through), matching the app's zero-chrome register. The sidebar sits on
    /// the RIGHT (the panel hangs off the window's right edge, so the file tree hugs that edge
    /// and the editor faces the terminal). The editor face IS the terminal's: JetBrains Mono —
    /// the face libghostty embeds and renders when the preference's "SF Mono" does not resolve
    /// (neither dev machine installs it; CoreText verified) — at the terminal's default 13pt,
    /// with `editor.lineHeight: 1.32` = JetBrains Mono's own vertical metric
    /// ((1020 ascent + 300 descent) / 1000 upm), the exact ratio ghostty rounds into its cell
    /// height, so editor lines and terminal rows share a rhythm. The client injects the face as
    /// @font-face data URIs (`CodeSidebarPageDressing` — the family names here and there must
    /// agree), with "Symbols Nerd Font" behind it for private-use glyphs.
    /// The status bar STAYS (v14, user-directed 2026-08-03 — v6..v13 hid it): it is the
    /// workbench's own footing (branch, problems, cursor position) and its seam border rides
    /// the retinted `statusBar.border`. `window.title` drops the `${appName}` suffix so any surface that
    /// ever renders it says the project, not "code-server". Auto-save on focus change: the
    /// terminal pane beside the editor is where builds/tests run, and switching to it IS the
    /// moment the file must be on disk. Markdown opens straight into the RENDERED preview
    /// (`workbench.editorAssociations` → the built-in `vscode.markdown.preview.editor`): in this
    /// panel markdown is read (README, docs, agent output), not authored — a reader who wants the
    /// source is one "Open Source" click away, the inverse default costs a chord per file.
    /// Every key here is USER-scope-overridable in the workbench
    /// (user settings land in this same file and win on conflict-free keys the user later edits —
    /// see the pristine-upgrade rule in ``seedUserSettings(at:)``).
    static let seededUserSettings = """
    {
        "workbench.colorTheme": "Monokai Pro",
        "window.autoDetectColorScheme": true,
        "workbench.preferredDarkColorTheme": "Monokai Pro",
        "workbench.preferredLightColorTheme": "Monokai Pro Light",
        "workbench.startupEditor": "none",
        "workbench.editorAssociations": {
            "*.md": "vscode.markdown.preview.editor"
        },
        "workbench.activityBar.location": "top",
        "workbench.sideBar.location": "right",
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "window.menuBarVisibility": "hidden",
        "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
        "workbench.editor.empty.hint": "hidden",
        "workbench.editor.decorations.badges": false,
        "window.commandCenter": false,
        "workbench.layoutControl.enabled": false,
        "workbench.navigationControl.enabled": false,
        "workbench.tips.enabled": false,
        "extensions.ignoreRecommendations": true,
        "editor.minimap.enabled": false,
        "breadcrumbs.enabled": false,
        "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
        "editor.fontSize": 13,
        "editor.lineHeight": 1.32,
        "editor.overviewRulerBorder": false,
        "editor.hideCursorInOverviewRuler": true,
        "editor.lineNumbersMinChars": 3,
        "editor.glyphMargin": false,
        "editor.folding": false,
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
        // v6 — the first chrome-less seed. Carried three keys the web workbench does not
        // REGISTER (chat.* — Code-OSS ships no chat; customTitleBarVisibility — desktop-only):
        // the settings editor flagged them as unknown in a file we authored.
        """
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
        """,
        // v6 as the WORKBENCH mutated it in the wild: with the theme extension invisible (the
        // empty-registry bug below), resolving the unknown theme dropped exactly the
        // `workbench.colorTheme` line — deterministic, observed byte-for-byte, so it is still
        // OUR file, not the user's.
        """
        {
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
        """,
        // v7 — registered-keys-only, but the editor face was still `ui-monospace` (SF Mono in
        // WebKit) while the terminal actually renders libghostty's embedded JetBrains Mono —
        // "SF Mono" resolves on NEITHER machine, so the two monos never matched.
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "hidden",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "window.density.editorTabHeight": "compact",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
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
        """,
        // v8 — JetBrains Mono + lineHeight 1.32 + per-client light/dark, but still the COMPACT tab
        // density: 22px tabs that the Slate plate recut (height − 8) squeezed to squat 14px
        // plates. v9 drops the density line (default 35px → 27px plates).
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "hidden",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "window.density.editorTabHeight": "compact",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v9 — full-height tab plates, but markdown still opened as raw source; v10 adds the
        // preview-first editor association.
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.activityBar.location": "hidden",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v10 — markdown preview-first, but editor tabs still wore the git-decoration letter
        // badge — the sub-baseline Added/Modified letter that reads as a stray character beside
        // the label; v11 turns tab badges off (the explorer keeps its own).
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "hidden",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v11 — tab badges off, but the activity bar was still fully HIDDEN: reaching Search /
        // Source Control / Extensions needed chords only. v12 folds the activity-bar icons into
        // the sidebar TOP instead (user-directed 2026-08-03).
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "hidden",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "workbench.editor.decorations.badges": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v12 — the activity bar folded into the sidebar top, but the editor gutter still spent a
        // five-char line-number reserve + glyph margin + folding arrows on emptiness. v13 slims
        // all three (user-directed 2026-08-03).
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "workbench.editor.decorations.badges": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v13 — the gutter slimmed, but the themes were still the "SlopDesk Monokai" derivations
        // (17 chrome-accent keys neutralized, plate tab fills). v14 ships the stock Monokai Pro
        // pair under their own names, seam borders retinted only (user-directed 2026-08-03).
        """
        {
            "workbench.colorTheme": "SlopDesk Monokai",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "SlopDesk Monokai",
            "workbench.preferredLightColorTheme": "SlopDesk Monokai Light",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
            "window.title": "${dirty}${activeEditorShort}${separator}${rootName}",
            "workbench.statusBar.visible": false,
            "workbench.editor.empty.hint": "hidden",
            "workbench.editor.decorations.badges": false,
            "window.commandCenter": false,
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.tips.enabled": false,
            "extensions.ignoreRecommendations": true,
            "editor.minimap.enabled": false,
            "breadcrumbs.enabled": false,
            "editor.fontFamily": "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace",
            "editor.fontSize": 13,
            "editor.lineHeight": 1.32,
            "editor.overviewRulerBorder": false,
            "editor.hideCursorInOverviewRuler": true,
            "editor.lineNumbersMinChars": 3,
            "editor.glyphMargin": false,
            "editor.folding": false,
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
                let existing = try Data(contentsOf: fileURL)
                guard isPristineFormerSeed(existing) else { return false }
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

    /// Whether `existing` is a former seed this manager may upgrade. Byte-identical to one is the
    /// fast path; otherwise the comparison goes FORMAT-BLIND and FONT-BLIND: canonical JSON with
    /// the client-synced font keys (verb 20 — ``syncedFontKeys``) dropped from both sides. A file
    /// whose only divergence from a former seed is the synced font trio is still OURS (the sync
    /// wrote it, and re-lands right after the upgrade's next ensure round); any other divergence is
    /// the user's and stays untouchable. Unparseable (JSONC comments etc.) ⇒ the user's.
    static func isPristineFormerSeed(_ existing: Data) -> Bool {
        if let string = String(data: existing, encoding: .utf8), obsoleteSeeds.contains(string) {
            return true
        }
        guard let canonical = canonicalDroppingFontKeys(existing) else { return false }
        return obsoleteSeeds.contains { canonicalDroppingFontKeys(Data($0.utf8)) == canonical }
    }

    /// Sorted-keys canonical JSON bytes with the ``syncedFontKeys`` removed — the font-blind
    /// comparator behind ``isPristineFormerSeed(_:)``. `nil` when `data` is not a JSON object.
    private static func canonicalDroppingFontKeys(_ data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        for key in syncedFontKeys { object.removeValue(forKey: key) }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Editor font sync (verb 20)

    /// The three settings keys the CLIENT owns via ``MetadataVerb/syncCodeFont``: the seed lays
    /// terminal-parity DEFAULTS, then a connected client overwrites them with its live terminal
    /// prefs (family/size/effective line-height ratio). One shared file ⇒ the last client to sync
    /// wins — the workspace document's last-writer-wins, applied to chrome.
    static let syncedFontKeys: Set<String> = [
        "editor.fontFamily", "editor.fontSize", "editor.lineHeight",
    ]

    /// The editor `fontFamily` stack for a synced terminal family: the family FIRST (single-quoted;
    /// quote characters stripped defensively — they cannot survive into a CSS family list), then
    /// the seeded fallback stack (the injected JetBrains Mono faces, the system mono, the nerd
    /// symbols). A family already heading the stack is not repeated.
    static func editorFontFamilyStack(for family: String) -> String {
        let cleaned = family
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
        let fallback = "'JetBrains Mono', ui-monospace, 'Symbols Nerd Font', monospace"
        guard !cleaned.isEmpty, cleaned != "JetBrains Mono" else { return fallback }
        return "'\(cleaned)', \(fallback)"
    }

    /// Folds a client's ``MetadataCodec/CodeFontSpec`` into the live settings file (the instance
    /// entry point the performer calls — serialized under the manager lock like every other
    /// settings touch).
    @discardableResult
    func syncEditorFont(_ spec: MetadataCodec.CodeFontSpec) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.syncEditorFont(spec, at: settingsFileURL())
    }

    /// The pure worker: parse → patch the three ``syncedFontKeys`` → write back canonical
    /// (sorted-keys pretty JSON — the workbench's settings watcher applies the change live).
    /// Returns whether the file changed; an already-in-sync file is deliberately NOT rewritten
    /// (every ensure round syncs — a no-change write would churn the workbench's file watcher).
    /// A missing or unparseable file is a no-op: the sync is a nicety layered over the seed,
    /// never a file creator, and a JSONC-commented file is the user's, not ours to rewrite.
    @discardableResult
    static func syncEditorFont(_ spec: MetadataCodec.CodeFontSpec, at fileURL: URL) -> Bool {
        guard let existing = try? Data(contentsOf: fileURL),
              var settings = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any]
        else { return false }
        settings["editor.fontFamily"] = editorFontFamilyStack(for: spec.family)
        settings["editor.fontSize"] = decimalNumber(spec.size)
        settings["editor.lineHeight"] = decimalNumber(spec.lineHeight)
        let options: JSONSerialization.WritingOptions = [
            .sortedKeys, .prettyPrinted, .withoutEscapingSlashes,
        ]
        guard let updated = try? JSONSerialization.data(withJSONObject: settings, options: options),
              !isAlreadyInSync(existing: existing, updated: updated)
        else { return false }
        return (try? updated.write(to: fileURL)) != nil
    }

    /// A number that SERIALIZES the way a human wrote it. `JSONSerialization` prints a raw `Double`
    /// with round-trip noise (`1.58` → `1.5800000000000001`) — in a settings file the user opens
    /// (and screenshotted). Swift's `String(Double)` is the shortest round-trip form; parsing that
    /// into a `Decimal` (bridged to `NSDecimalNumber` inside the JSON object) makes the file read
    /// `1.58` / `14`. POSIX locale pins the `.` separator.
    private static func decimalNumber(_ value: Double) -> Decimal {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    /// Format-blind "nothing to do" check: both sides canonicalized WITH the font keys included.
    private static func isAlreadyInSync(existing: Data, updated: Data) -> Bool {
        func canonical(_ data: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        guard let a = canonical(existing), let b = canonical(updated) else { return false }
        return a == b
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

    /// The seeded theme extension's identity — mirrored in ``themeExtensionManifest`` (pinned by
    /// the manifest-agreement test) and composed into the folder name + registry entry below.
    static let themeExtensionPublisher = "slopdesk"
    static let themeExtensionName = "slopdesk-monokai"
    static let themeExtensionVersion = "1.0.0"

    /// The seeded theme extension's folder name — `publisher.name-version`. A version bump here
    /// re-seeds changed theme bytes on the next hostd start (the writer overwrites on content
    /// drift) and re-registers the new folder.
    static let themeExtensionDirectoryName =
        "\(themeExtensionPublisher).\(themeExtensionName)-\(themeExtensionVersion)"

    /// EVERY theme variant the vendored vsix contributes — label (what the settings and the ⌘K ⌘T
    /// picker select by), dark/light, and the resource slug the sync script writes. This table is
    /// the single source of truth: the manifest below is generated from it, the seeder writes one
    /// file per row, and `scripts/monokai-sync.sh` fails loudly when the upstream vsix's theme set
    /// stops matching it (its own mirror table). All EIGHT variants ship (user-directed
    /// 2026-08-03) — the workbench's theme picker offers the full family, not just the pair the
    /// app chrome seeds from.
    static let themeExtensionThemes: [(label: String, dark: Bool, resource: String)] = [
        ("Monokai Pro", true, "monokai-pro"),
        ("Monokai Pro (Filter Octagon)", true, "monokai-pro-filter-octagon"),
        ("Monokai Pro (Filter Ristretto)", true, "monokai-pro-filter-ristretto"),
        ("Monokai Pro (Filter Spectrum)", true, "monokai-pro-filter-spectrum"),
        ("Monokai Pro (Filter Machine)", true, "monokai-pro-filter-machine"),
        ("Monokai Pro Light", false, "monokai-pro-light"),
        ("Monokai Pro Light (Filter Sun)", false, "monokai-pro-light-filter-sun"),
        ("Monokai Classic", true, "monokai-classic"),
    ]

    /// The theme extension's manifest — generated from ``themeExtensionThemes``. The themes are
    /// STOCK Monokai Pro (all eight variants of vsix 2.0.13, monokai.pro — the pinned version
    /// lives in `scripts/monokai.pin`; `scripts/monokai-sync.sh` regenerates the resources from a
    /// newer upstream). Only the theme DATA is vendored — none of the upstream extension's
    /// activation code (that code carries the license prompt; a data-only seed never nags, which
    /// is why the marketplace extension is not installed directly). Exactly two departures from
    /// stock, both invisible-or-intentional (user-directed 2026-08-03; the earlier 17-key
    /// chrome-accent neutralization is REVERTED — the stock accents are the point):
    ///   • the seven structural seam borders (`sideBar`/`panel`/`activityBar`/`statusBar`(+
    ///     `noFolder`)/`titleBar`/`editorGroup` `.border` — near-black `#19181a` in the dark
    ///     filters) carry the app's Slate `divider` tint instead, in the token's own alpha form
    ///     (dark = foreground @ 0.10 `#fcfcfa1a`, light = black @ 0.08 `#00000014`), so the
    ///     workbench's seams match the split dividers around it;
    ///   • the vsix's five EMPTY-string colour values (`diffEditor.move.border` etc., rejected
    ///     per-key by the workbench) are dropped.
    /// Only the color themes ship — the vsix's icon themes are deliberately left behind (the
    /// panel keeps the workbench's stock file icons). The workbench picks between the seeded
    /// dark/light pair via `window.autoDetectColorScheme` — the webview's `prefers-color-scheme`
    /// follows the window's pinned `NSAppearance`, which the client pins to the active Slate
    /// theme — so the editor flips light/dark WITH the app, per client, no shared-settings
    /// conflict. Monokai Pro by Monokai (monokai.pro) — personal-use seed into the user's own
    /// code-server, never redistributed.
    static let themeExtensionManifest: String = {
        let themes = themeExtensionThemes.map { theme in
            """
                        {
                            "label": "\(theme.label)",
                            "uiTheme": "\(theme.dark ? "vs-dark" : "vs")",
                            "path": "./themes/\(theme.resource).json"
                        }
            """
        }.joined(separator: ",\n")
        return """
        {
            "name": "slopdesk-monokai",
            "displayName": "Monokai Pro (SlopDesk)",
            "description": "Stock Monokai Pro by Monokai (monokai.pro); workbench seam borders carry the app's divider tint.",
            "publisher": "slopdesk",
            "version": "1.0.0",
            "engines": { "vscode": "^1.0.0" },
            "categories": ["Themes"],
            "contributes": {
                "themes": [
        \(themes)
                ]
            }
        }
        """
    }()

    /// A theme JSON carried as a target resource (~600 colour keys each — too large for source
    /// literals). `nil` only if the bundle is broken (then the seed is a no-op and the workbench
    /// falls back to its stock theme — a nicety, never a failure).
    static func themeExtensionThemeData(resource: String) -> Data? {
        guard let url = Bundle.module.url(
            forResource: "Resources/\(resource)", withExtension: "json",
        ) ?? Bundle.module.url(forResource: resource, withExtension: "json")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Theme files the two-variant era wrote into the extension folder — swept by the seeder so
    /// the deployed folder carries exactly the current manifest's files, nothing stale.
    static let legacyThemeFileNames = [
        "themes/slopdesk-monokai-color-theme.json",
        "themes/slopdesk-monokai-light-color-theme.json",
    ]

    /// Writes the theme extension under `extensionsDir` (creating directories) — the manifest plus
    /// one theme file per ``themeExtensionThemes`` row — overwriting OUR files when their bytes
    /// drifted from the current seed: the folder is namespaced `slopdesk.*`, so unlike the
    /// settings file it is ours to keep current, never the user's. Files from retired manifest
    /// generations (``legacyThemeFileNames``) are swept. Returns whether anything was written;
    /// failures are silent no-ops (see the settings seeder).
    @discardableResult
    static func seedThemeExtension(
        into extensionsDir: URL,
        themeData: (String) -> Data? = { themeExtensionThemeData(resource: $0) },
        fileManager: FileManager = .default,
    ) -> Bool {
        let root = extensionsDir.appendingPathComponent(themeExtensionDirectoryName)
        var files: [(URL, Data)] = [
            (root.appendingPathComponent("package.json"), Data(themeExtensionManifest.utf8)),
        ]
        for theme in themeExtensionThemes {
            guard let data = themeData(theme.resource) else { return false }
            files.append((root.appendingPathComponent("themes/\(theme.resource).json"), data))
        }
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
        for legacy in legacyThemeFileNames {
            let url = root.appendingPathComponent(legacy)
            if fileManager.fileExists(atPath: url.path), (try? fileManager.removeItem(at: url)) != nil {
                wrote = true
            }
        }
        if registerThemeExtension(in: extensionsDir) { wrote = true }
        return wrote
    }

    /// Registers the seeded theme folder in the profile registry (`extensions.json`) beside it.
    /// The registry — not the directory scan — is the workbench's source of truth once the file
    /// exists: code-server writes an EMPTY `[]` on first boot, and from then on a folder-dropped
    /// extension is invisible (observed: the theme fell back to stock dark). Entry shape per the
    /// server's own validator: `identifier`/`version`/`location {path, scheme}`/
    /// `relativeLocation`. Foreign entries are preserved; ours is replaced only when it drifted.
    /// A missing registry file is created — the boot that follows keeps our entry. Unparseable
    /// registry = someone else's problem state; leave it (the workbench self-heals its own file).
    static func registerThemeExtension(
        in extensionsDir: URL, fileManager _: FileManager = .default,
    ) -> Bool {
        let registryURL = extensionsDir.appendingPathComponent("extensions.json")
        var entries: [[String: Any]] = []
        if let bytes = try? Data(contentsOf: registryURL) {
            guard let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
            else { return false }
            entries = parsed
        }
        let id = "\(themeExtensionPublisher).\(themeExtensionName)"
        let ours: [String: Any] = [
            "identifier": ["id": id],
            "version": themeExtensionVersion,
            "location": [
                "$mid": 1,
                "path": extensionsDir.appendingPathComponent(themeExtensionDirectoryName).path,
                "scheme": "file",
            ],
            "relativeLocation": themeExtensionDirectoryName,
            "metadata": ["installedTimestamp": 0, "pinned": true, "source": "resource"],
        ]
        let existing = entries.firstIndex {
            (($0["identifier"] as? [String: Any])?["id"] as? String) == id
        }
        if let existing {
            // Drift check via canonical (sorted-keys) JSON — value-typed, no NSDictionary bridge.
            let canonical = { (dict: [String: Any]) in
                try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            }
            if canonical(entries[existing]) == canonical(ours) { return false }
            entries[existing] = ours
        } else {
            entries.append(ours)
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: entries) else { return false }
        do {
            try encoded.write(to: registryURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Extensions gallery

    /// The OFFICIAL VS Code Marketplace, handed to every child through `EXTENSIONS_GALLERY` —
    /// code-server's supported gallery override (its `server-main.js` parses the env var as JSON
    /// and REPLACES the built-in Open VSX default wholesale, so the full URL set ships here,
    /// mirroring VS Code stable's own `product.json`). Open VSX carries only the slice of the
    /// catalog whose publishers opted in — most first-party `ms-*` tooling (Pylance, C/C++, …)
    /// never did, and the embedded workbench should install from the official catalog
    /// (user-directed 2026-08-03). No proxy is needed: the marketplace API answers CORS-open
    /// (vscode.dev consumes it straight from a browser), so the webview workbench reaches it
    /// directly. NOTE Microsoft's marketplace ToS scopes the API to VS Code products — this is
    /// the operator's own personal setup, the same trade every code-server/VSCodium user makes.
    static let marketplaceExtensionsGallery = """
    {"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery",\
    "itemUrl":"https://marketplace.visualstudio.com/items",\
    "publisherUrl":"https://marketplace.visualstudio.com/publishers",\
    "resourceUrlTemplate":"https://{publisher}.vscode-unpkg.net/{publisher}/{name}/{version}/{path}",\
    "controlUrl":"https://main.vscode-cdn.net/extensions/marketplace.json",\
    "nlsBaseUrl":"https://www.vscode-unpkg.net/_lp/"}
    """

    /// The environment every code-server child (server AND one-shot CLI) launches with: the
    /// parent's, plus ``marketplaceExtensionsGallery`` under `EXTENSIONS_GALLERY` — unless the
    /// operator exported their OWN gallery before hostd, which passes through untouched (the
    /// escape hatch IS the env var, not a new flag — docs/DECISIONS: important features ship
    /// unflagged).
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String: String] {
        var environment = base
        if (environment["EXTENSIONS_GALLERY"] ?? "").isEmpty {
            environment["EXTENSIONS_GALLERY"] = marketplaceExtensionsGallery
        }
        return environment
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
            process.environment = childEnvironment()
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
        process.environment = childEnvironment()
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
