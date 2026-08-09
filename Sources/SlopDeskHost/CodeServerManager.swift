import Foundation
import SlopDeskProtocol

/// Supervises the HOST's code-server (VS Code web workbench) — the backend of the client's
/// right-sidebar embedded editor (``MetadataVerb/ensureCodeServer``).
///
/// **ONE shared instance, prewarmed.** code-server serves every folder from a single process — the
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
/// **Crash recovery is implicit** (the cmux `VSCodeServeWebController` lesson): a child that
/// exited reads `isRunning == false` on the next `ensure`, which drops the record and respawns
/// fresh. There is deliberately NO `--idle-timeout-seconds`: the daemon calls ``prewarm()`` at
/// boot precisely so the workbench is always warm, and a reaper would undo that every quiet
/// stretch — the cold boot it forces onto the next panel expand costs more than the idle Node
/// runtime it frees (user-directed startup-latency pass, 2026-08-07).
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
    ) throws -> any HostServiceProcessHandle
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = @Sendable (_ port: UInt16) -> Bool
    /// Seeds the code-server user settings before the FIRST spawn (see ``seedUserSettings(at:)``).
    typealias SettingsSeeder = @Sendable () -> Void
    /// Runs the code-server CLI once to completion and reports its exit status (`nil` = the exec
    /// itself failed). Distinct from ``Spawner`` — the CLI is a short-lived command whose EXIT CODE
    /// is the answer, not a supervised child.
    typealias CLIRunner = @Sendable (_ binary: String, _ arguments: [String]) async -> Int32?
    /// Reads the profile registry (`extensions/extensions.json`) — the workbench's installed-set
    /// source of truth — for the bundled-extension check. `nil` = no registry yet (pristine host).
    typealias InstalledExtensionsRegistry = @Sendable () -> Data?

    private struct Instance {
        var handle: any HostServiceProcessHandle
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
    /// The one-shot marketplace install of ``bundledMarketplaceExtensions``, checked before the
    /// first spawn: `.installing` DEFERS the spawn (ensure keeps answering `.starting`; the client
    /// polls ~1 Hz) so the workbench's very first boot already scans the icon pack — install and
    /// boot writing `extensions.json` concurrently is also how registrations get lost. `.done` is
    /// latched even when an install FAILS (no network): the panel is never held hostage by a
    /// nicety, and the next hostd launch retries because the registry still misses the id.
    private enum BundledExtensionInstall { case unchecked, installing, done }
    private var bundledExtensionInstall: BundledExtensionInstall = .unchecked
    private let locateBinary: BinaryLocator
    private let spawn: Spawner
    private let probe: ReadinessProbe
    private let seedSettings: SettingsSeeder
    private let runCLI: CLIRunner
    private let installedExtensionsRegistry: InstalledExtensionsRegistry
    /// The bridge extension's host end — injectable so unit tests never bind a real `AF_UNIX`
    /// listener (hang-safety, same reason the spawner is faked).
    private let bridge: any CodeBridgeRouting
    /// Latched with ``settingsSeeded`` — the listener binds once, lazily, so a host whose user
    /// never opens the code panel never creates the socket at all.
    private var bridgeStarted = false
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
        installedExtensionsRegistry: @escaping InstalledExtensionsRegistry =
            CodeServerManager.defaultInstalledExtensionsRegistry,
        settingsFileURL: @escaping @Sendable () -> URL = { CodeServerManager.userSettingsURL() },
        bridge: any CodeBridgeRouting = CodeBridgeServer(),
        probeInterval: Duration = .milliseconds(500),
        openRetryDelay: Duration = .seconds(2),
    ) {
        self.bridge = bridge
        locateBinary = binaryLocator
        spawn = spawner
        probe = readinessProbe
        seedSettings = settingsSeeder
        runCLI = cliRunner
        self.installedExtensionsRegistry = installedExtensionsRegistry
        self.settingsFileURL = settingsFileURL
        self.probeInterval = probeInterval
        self.openRetryDelay = openRetryDelay
    }

    /// Boots the shared code-server WITHOUT a client request — `slopdesk-hostd` calls this once
    /// its listeners are up, so the first panel expand finds a live workbench instead of paying
    /// the seed + extension-install + Node-boot chain interactively. Identical to ``ensure`` minus
    /// the root validation (there is no root — the one child serves every folder). A host with no
    /// binary is a silent no-op: `unavailable` is verb 18's ANSWER, not a boot failure.
    ///
    /// Deliberately not called from ``HostServer/start()``: unit tests build and start servers
    /// freely and may never spawn a real Node child (hang-safety) — only the daemon executable
    /// (and the E2E harness, which points `SLOPDESK_CODE_SERVER_BIN` at a non-executable to keep
    /// its sandboxed hostd childless) reaches this.
    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        _ = bootLocked()
    }

    /// Ensures the shared code-server and reports where it stands RIGHT NOW (never waits). `nil`
    /// when `projectRoot` is not an absolute path to an existing host directory (→ `.notFound` on
    /// the wire — never hand out an endpoint for a path the host cannot see).
    func ensure(projectRoot: String) -> MetadataCodec.ServiceEndpoint? {
        guard Self.canonicalRoot(projectRoot) != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return bootLocked()
    }

    /// The one shared boot path (caller holds `lock`): observe a live child, or walk the one-time
    /// chain — settings seed, bridge bind, bundled-extension install — and spawn. Both ``ensure``
    /// (per verb-18 round) and ``prewarm``/``finishBundledExtensionInstall`` (once each) land here.
    private func bootLocked() -> MetadataCodec.ServiceEndpoint {
        if let existing = instance {
            if existing.handle.isRunning {
                return endpointLocked(for: existing)
            }
            instance = nil
        }

        guard let binary = locateBinary() else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
        }
        // Seed the workbench defaults before the FIRST child ever boots — after it has read an
        // absent settings file once, a seed would need a reload to take. One `stat` + at most one
        // tiny write under the lock, once per manager lifetime.
        if !settingsSeeded {
            settingsSeeded = true
            seedSettings()
        }
        // The bridge listener must exist BEFORE the child inherits its path, or the extension's
        // first connect races the bind and burns a 5 s reconnect delay on every cold start.
        if !bridgeStarted {
            bridgeStarted = true
            bridge.start(path: Self.bridgeSocketPath)
        }
        // Bundled marketplace extensions install before the FIRST spawn (see
        // ``BundledExtensionInstall`` / ``bundledMarketplaceExtensions``); while the one-shot CLI
        // runs, ensure keeps its never-wait contract by answering `.starting`.
        switch bundledExtensionInstall {
        case .unchecked:
            let missing = Self.missingBundledExtensions(inRegistry: installedExtensionsRegistry())
            if missing.isEmpty {
                bundledExtensionInstall = .done
            } else {
                bundledExtensionInstall = .installing
                installBundledExtensions(missing, binary: binary)
                return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
            }
        case .installing:
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        case .done:
            break
        }
        spawnGeneration += 1
        let generation = spawnGeneration
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            guard let port = Self.parseListeningPort(fromLogLine: line) else { return }
            self?.recordPort(port, spawnedAs: generation)
        }
        guard let handle = try? spawn(binary, Self.launchArguments(), onLine) else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
        }
        instance = Instance(handle: handle)
        return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
    }

    /// Opens `target` (a host file path, optionally `:line[:col]`-suffixed) in the running
    /// workbench. TWO routes, tried in that order:
    ///
    ///   1. the ``CodeBridgeServer`` socket — one line to the already-attached extension host of
    ///      the window whose folder contains the file, which opens it in the same tick;
    ///   2. `code-server -r <target>` — a fresh Node CLI process routed through the per-user
    ///      session socket to the most recently registered workbench (folder-prefix matches sort
    ///      first), the fallback for a window that has not attached (or a code-server whose
    ///      profile never got the seeded extension).
    ///
    /// Ensures the SERVER first (the
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
        let bridge = bridge
        return Task {
            for attempt in 0..<Self.openAttempts {
                // The bridge is tried FIRST on every attempt, not just the first: on a cold start
                // neither route exists yet, and whichever appears first should win the race. Once
                // a window is attached this returns on the opening attempt, so the CLI — a whole
                // Node process — never runs at all.
                if bridge.open(target: target) { return true }
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

    /// Installs what the editor's "run this in my terminal" menu items actuate. Wired by
    /// ``HostServer`` (the only object that owns terminal sessions) and held for the host's
    /// lifetime; until it is installed, and on a host with no sessions at all, the bridge refuses
    /// those requests with a sentence the editor shows. Safe to call before the bridge binds — the
    /// runner is stored on the bridge object, not on the socket.
    func installTerminalRunner(
        _ runner: @escaping @Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome,
    ) {
        bridge.setTerminalRunner(runner)
    }

    /// Terminates the child (host shutdown) — with no idle reaper, this is the ONLY thing that
    /// stops it; hostd going down must not strand a Node process.
    func shutdown() {
        lock.lock()
        let stranded = instance
        instance = nil
        bridgeStarted = false
        lock.unlock()
        stranded?.handle.terminate()
        bridge.stop()
    }

    // MARK: - Locked helpers

    /// Computes the endpoint for the LIVE instance, probing readiness at most once per
    /// ``probeInterval``. Caller holds `lock`.
    private func endpointLocked(for live: Instance) -> MetadataCodec.ServiceEndpoint {
        guard let port = live.port else {
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        if live.ready {
            return MetadataCodec.ServiceEndpoint(state: .ready, port: port)
        }
        var updated = live
        let now = clock.now
        let due = live.lastProbe.map { now - $0 >= probeInterval } ?? true
        if due {
            updated.lastProbe = now
            updated.ready = probe(port)
            instance = updated
        }
        return MetadataCodec.ServiceEndpoint(state: updated.ready ? .ready : .starting, port: port)
    }

    private func recordPort(_ port: UInt16, spawnedAs generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == spawnGeneration, var live = instance, live.port == nil else { return }
        live.port = port
        instance = live
    }

    /// Runs `code-server --install-extension <id>` for each missing bundled extension off the
    /// metadata queue, then flips ``bundledExtensionInstall`` to `.done` — unconditionally: a
    /// failed install (offline host, marketplace hiccup) logs and moves on; the next hostd launch
    /// retries because the registry still misses the id. Caller holds `lock` and has already set
    /// `.installing`, so a racing second ensure never double-spawns the task.
    private func installBundledExtensions(_ identifiers: [String], binary: String) {
        let run = runCLI
        Task { [weak self] in
            for identifier in identifiers {
                let status = await run(binary, ["--install-extension", identifier])
                if status != 0 {
                    FileHandle.standardError.write(Data(
                        "slopdesk-hostd: code-server --install-extension \(identifier) failed\n".utf8,
                    ))
                }
            }
            self?.finishBundledExtensionInstall()
        }
    }

    /// Synchronous `.done` flip for the install task (NSLock is unusable directly in async code),
    /// then the CONTINUATION of the boot that install deferred: the spawn happens right here, not
    /// on the next ensure round — a prewarmed host has no client polling to pick it up, and a
    /// polled one saves a round.
    private func finishBundledExtensionInstall() {
        lock.lock()
        defer { lock.unlock() }
        bundledExtensionInstall = .done
        _ = bootLocked()
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
            // NO --idle-timeout-seconds: the prewarmed child stays warm for the daemon's whole
            // life (see the class doc — a reaper here re-imposes the cold boot prewarm exists
            // to remove).
        ]
    }

    /// The user settings seeded on a pristine host — the workbench must come up in the app's own
    /// palette (`Alucard`, v26, user-directed 2026-08-09: the light half of the Dracula family the
    /// terminal glass already wears, and the theme the window's ground cream `#FFFBEB` was taken
    /// from in the first place, so the editor canvas and the ground agree by ORIGIN instead of by
    /// an override forcing them to. It is one row of the seeded extension below, which also carries
    /// all eight stock Monokai Pro variants for the ⌘K ⌘T picker. NO `autoDetectColorScheme`
    /// trio any more — the app has ONE appearance, always light, so the dark arm of that switch
    /// could never fire) and LEAN: menu bar hidden, the ACTIVITY-BAR icons
    /// folded into the sidebar TOP (`activityBar.location: "top"`, user-directed v12 — fully
    /// "hidden" left Search / Source Control / Extensions reachable by chord only). The "top"
    /// location FORCE-SHOWS the web title bar (re-confirmed on 4.131, the v6-era observation): it
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
    /// file we authored — the chat.* pair died with v7 for the same reason; the schema is what
    /// moved, not the intent, so `chat.disableAIFeatures` returns in v18 now that code-server
    /// 4.113+ bundles the Copilot chat extension and registers it again —
    /// `chat.commandCenter.enabled` is still absent and stays out).
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
    /// the retinted `statusBar.border`. NOTHING seeds `window.title` (v17 dropped the template v6
    /// introduced): the web title bar is clipped off client-side and the panel's strip no longer
    /// reads the document title, so the workbench's own default is as invisible as any shape we
    /// could pin. Auto-save on focus change: the
    /// terminal pane beside the editor is where builds/tests run, and switching to it IS the
    /// moment the file must be on disk. Markdown opens straight into the RENDERED preview
    /// (`workbench.editorAssociations` → the built-in `vscode.markdown.preview.editor`): in this
    /// panel markdown is read (README, docs, agent output), not authored — a reader who wants the
    /// source is one "Open Source" click away, the inverse default costs a chord per file. That
    /// preview renders mermaid fences as diagrams on Code 1.121+, where the built-in
    /// `mermaid-markdown-features` extension landed (code-server 4.121+ — docs/46 records the
    /// install); nothing is seeded for it, since its default theme already follows the workbench
    /// colours. Below that the fence stays a code block: the panel still works, it just reads the
    /// diagram as source.
    /// File icons are the Material Icon Theme (v15, user-directed 2026-08-03) — the
    /// ``bundledMarketplaceExtensions`` install that precedes the first spawn, so the id resolves
    /// on the very first boot.
    /// The reading aids come on (v16, user-directed 2026-08-04): indentation guides pinned
    /// explicitly (default-on today, but the named ask deserves a named key), the ACTIVE bracket
    /// pair's guide (`editor.guides.bracketPairs: "active"` — the full rainbow is noise at this
    /// panel width), sticky scroll (shipped default is OFF — verified in the 4.131 bundle), and
    /// trailing-whitespace rendering. The file tree matches: indent guides always visible (stock
    /// only shows them on hover) over a 16px indent — the default 8px barely steps a deep Swift
    /// tree.
    /// The workbench PAINTS ITSELF IN THE APP'S GROUND (ONE ISLAND, user-directed 2026-08-08): the
    /// code panel is a SUNKEN column beside the navigator, not an island, so a
    /// `workbench.colorCustomizations` block puts every workbench surface — editor, empty group,
    /// gutter, sticky scroll, widgets, breadcrumb, sidebar, activity bar, tab strip, panel,
    /// integrated terminal, status bar, title bar, quick input, menus — on the client's ground cream
    /// `#FFFBEB` and zeroes their borders (`#00000000`), so panel and ground read as one continuous
    /// field with no seam. The syntax theme is untouched: only chrome keys are overridden, so
    /// Alucard still colours the code itself. Most of that block is now a NO-OP for the editor
    /// proper — Alucard already paints it `#FFFBEB` — and it stays because the surfaces around the
    /// canvas (Alucard's own `#F3EFDF` sidebar, activity bar and status bar) are what would
    /// otherwise step the panel into a second tone.
    /// On that flat field SELECTION is the app's own COMPACT ISLAND (v25, user-directed 2026-08-09):
    /// the chosen tree row, editor tab, palette row, completion row and menu item are stamped out of
    /// the island's dark glass `#22212C` and carry its light ink `#F8F8F2` — the same chip
    /// `SlateCompactIsland` cuts for a selected sidebar row, in the same two tones, so the panel
    /// answers "which one" in the vocabulary the rest of the window already speaks instead of the
    /// theme's own wash. Hover stays a whisper of that same tone rather than a second dialect, and
    /// every selection OUTLINE is zeroed: the fill is the state, a ring around it restates it.
    /// ⚠️ `#22212C` / `#F8F8F2` are `SlateTheme.app`'s glass face and ink, the same duplication the
    /// ground cream already carries across this module boundary — if the profile moves, all three
    /// move together.
    /// NOTHING CASTS A SHADOW (v25, user-directed 2026-08-09): every `*.shadow` key the Monokai
    /// pair ships — widget, scrollbar, the three sticky-scroll casts, the list filter, the welcome
    /// tile, inline chat, the diff editor's unchanged region — goes fully transparent. Those casts
    /// exist to lift a widget off an editor of a DIFFERENT tone; here every surface is the one
    /// cream, so each one drew a grey smear across a field that is meant to read as continuous.
    /// Every key here is USER-scope-overridable in the workbench
    /// (user settings land in this same file and win on conflict-free keys the user later edits —
    /// see the pristine-upgrade rule in ``seedUserSettings(at:)``).
    static let seededUserSettings = """
    {
        "chat.disableAIFeatures": true,
        "workbench.colorTheme": "Alucard",
        "workbench.colorCustomizations": {
            "editor.background": "#FFFBEB",
            "editorGroup.emptyBackground": "#FFFBEB",
            "editorGroupHeader.noTabsBackground": "#FFFBEB",
            "welcomePage.background": "#FFFBEB",
            "editorGutter.background": "#FFFBEB",
            "editorStickyScroll.background": "#FFFBEB",
            "editorWidget.background": "#FFFBEB",
            "breadcrumb.background": "#FFFBEB",
            "sideBar.background": "#FFFBEB",
            "sideBar.border": "#00000000",
            "sideBarSectionHeader.background": "#FFFBEB",
            "sideBarSectionHeader.border": "#00000000",
            "activityBar.background": "#FFFBEB",
            "activityBar.border": "#00000000",
            "editorGroupHeader.tabsBackground": "#FFFBEB",
            "editorGroupHeader.tabsBorder": "#00000000",
            "editorGroupHeader.border": "#00000000",
            "editorGroup.border": "#00000000",
            "tab.inactiveBackground": "#FFFBEB",
            "tab.border": "#00000000",
            "tab.activeBackground": "#22212C",
            "tab.activeForeground": "#F8F8F2",
            "tab.hoverBackground": "#22212C14",
            "list.activeSelectionBackground": "#22212C",
            "list.activeSelectionForeground": "#F8F8F2",
            "list.activeSelectionIconForeground": "#F8F8F2",
            "list.inactiveSelectionBackground": "#22212C",
            "list.inactiveSelectionForeground": "#F8F8F2",
            "list.inactiveSelectionIconForeground": "#F8F8F2",
            "list.focusBackground": "#22212C",
            "list.focusForeground": "#F8F8F2",
            "list.inactiveFocusBackground": "#22212C",
            "list.hoverBackground": "#22212C14",
            "list.focusOutline": "#00000000",
            "list.inactiveFocusOutline": "#00000000",
            "quickInputList.focusBackground": "#22212C",
            "quickInputList.focusForeground": "#F8F8F2",
            "quickInputList.focusIconForeground": "#F8F8F2",
            "editorSuggestWidget.selectedBackground": "#22212C",
            "editorSuggestWidget.selectedForeground": "#F8F8F2",
            "editorSuggestWidget.selectedIconForeground": "#F8F8F2",
            "menu.selectionBackground": "#22212C",
            "menu.selectionForeground": "#F8F8F2",
            "menu.selectionBorder": "#00000000",
            "widget.shadow": "#00000000",
            "scrollbar.shadow": "#00000000",
            "editorStickyScroll.shadow": "#00000000",
            "sideBarStickyScroll.shadow": "#00000000",
            "panelStickyScroll.shadow": "#00000000",
            "listFilterWidget.shadow": "#00000000",
            "welcomePage.tileShadow": "#00000000",
            "inlineChat.shadow": "#00000000",
            "diffEditor.unchangedRegionShadow": "#00000000",
            "panel.background": "#FFFBEB",
            "panel.border": "#00000000",
            "terminal.background": "#FFFBEB",
            "statusBar.background": "#FFFBEB",
            "statusBar.noFolderBackground": "#FFFBEB",
            "statusBar.border": "#00000000",
            "titleBar.activeBackground": "#FFFBEB",
            "titleBar.inactiveBackground": "#FFFBEB",
            "titleBar.border": "#00000000",
            "quickInput.background": "#FFFBEB",
            "menu.background": "#FFFBEB"
        },
        "workbench.iconTheme": "material-icon-theme",
        "workbench.startupEditor": "none",
        "workbench.editorAssociations": {
            "*.md": "vscode.markdown.preview.editor"
        },
        "workbench.activityBar.location": "top",
        "workbench.sideBar.location": "right",
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "window.menuBarVisibility": "hidden",
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
        "editor.guides.indentation": true,
        "editor.guides.bracketPairs": "active",
        "editor.stickyScroll.enabled": true,
        "editor.renderWhitespace": "trailing",
        "workbench.tree.renderIndentGuides": "always",
        "workbench.tree.indent": 16,
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
        // v14 — the stock Monokai Pro pair with the status bar back, but file icons were still the
        // workbench's minimal default. v15 selects the Material Icon Theme that
        // ``bundledMarketplaceExtensions`` installs (user-directed 2026-08-03).
        """
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
        """,
        // v15 — Material Icon Theme, but the reading aids were still the workbench's quiet
        // defaults. v16 turns on the structure guides (indentation pinned, active bracket pair,
        // sticky scroll, always-on tree guides with a deeper tree indent) and trailing-whitespace
        // rendering (user-directed 2026-08-04).
        """
        {
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.iconTheme": "material-icon-theme",
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
        """,
        // v16 — carried a `window.title` template shaped for the panel strip's active-file readout.
        // The readout is gone (user-directed 2026-08-05: the workbench's own editor tab already
        // says which file is open), and with the web title bar clipped away client-side nothing
        // renders a title at all, so v17 drops the key back to the workbench's default.
        """
        {
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.iconTheme": "material-icon-theme",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v17 — the last seed written for a Code-OSS workbench with no chat in it. code-server
        // 4.113+ bundles the Copilot chat extension, which brings `chat.disableAIFeatures` back
        // into the schema (v7 had to drop it as unregistered), so v18 turns the AI surfaces off
        // again — the register this panel has always been seeded in.
        """
        {
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v20 — the pinned-dark seed: the split-tone Ember (dark glass beside light chrome)
        // dropped v19's `window.autoDetectColorScheme` trio so appearance-following could not
        // flip the glass light. The whole-app theme (user-directed 2026-08-07, polish round)
        // reversed that rationale — the client pins its WHOLE appearance to the theme polarity
        // and the webview inherits it — so v21 restored the trio, landing byte-identical to
        // v19. While v21 was the current seed, v19 could not sit in this list (the current seed
        // in the obsolete list would rewrite every font-synced host on each boot); now that the
        // current seed moved on, the v21 entry below covers pristine v19 files too.
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Foundry Ember",
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v21 — the whole-app-theme seed: restored the autoDetectColorScheme trio around the
        // Foundry Ember pair. v22 re-pointed the trio at the Dracula / Alucard pair (round-8
        // verdict, user-directed 2026-08-07); everything else is unchanged.
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Foundry Ember",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Foundry Ember",
            "workbench.preferredLightColorTheme": "Foundry Ember Light",
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v22 — the Dracula / Alucard trio (round-8 verdict). The current seed returns to the
        // v18 Monokai trio with the chrome revert (user-directed 2026-08-08), so the OLD v18
        // entry had to LEAVE this list — a seed byte-identical to the current one must never sit
        // here (the v19/v21 rule: the current seed in the obsolete list rewrites every
        // font-synced host on each boot).
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Dracula",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Dracula",
            "workbench.preferredLightColorTheme": "Alucard",
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v23 — the Monokai trio as it stood before the workbench was asked to paint itself in
        // the app's own ground: the panel still wore the theme's own backdrop, so it read as a
        // second surface beside the navigator instead of the same continuous field
        // (user-directed 2026-08-08).
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v24 — the flat-cream seed, before selection was cut from the island. Every workbench
        // surface already stood on the ground cream, but the chosen row, tab and palette entry
        // still wore the theme's own selection wash, and the pair's drop shadows still smeared
        // the widgets that float over it (user-directed 2026-08-09).
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.colorCustomizations": {
                "editor.background": "#FFFBEB",
                "editorGroup.emptyBackground": "#FFFBEB",
                "editorGroupHeader.noTabsBackground": "#FFFBEB",
                "welcomePage.background": "#FFFBEB",
                "editorGutter.background": "#FFFBEB",
                "editorStickyScroll.background": "#FFFBEB",
                "editorWidget.background": "#FFFBEB",
                "breadcrumb.background": "#FFFBEB",
                "sideBar.background": "#FFFBEB",
                "sideBar.border": "#00000000",
                "sideBarSectionHeader.background": "#FFFBEB",
                "sideBarSectionHeader.border": "#00000000",
                "activityBar.background": "#FFFBEB",
                "activityBar.border": "#00000000",
                "editorGroupHeader.tabsBackground": "#FFFBEB",
                "editorGroupHeader.tabsBorder": "#00000000",
                "editorGroupHeader.border": "#00000000",
                "editorGroup.border": "#00000000",
                "tab.activeBackground": "#FFFBEB",
                "tab.inactiveBackground": "#FFFBEB",
                "tab.border": "#00000000",
                "panel.background": "#FFFBEB",
                "panel.border": "#00000000",
                "terminal.background": "#FFFBEB",
                "statusBar.background": "#FFFBEB",
                "statusBar.noFolderBackground": "#FFFBEB",
                "statusBar.border": "#00000000",
                "titleBar.activeBackground": "#FFFBEB",
                "titleBar.inactiveBackground": "#FFFBEB",
                "titleBar.border": "#00000000",
                "quickInput.background": "#FFFBEB",
                "menu.background": "#FFFBEB"
            },
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v24 AS THE WORKBENCH LEFT IT — v24 with `chat.disableAIFeatures` REMOVED. Observed on
        // the live host: the running workbench rewrites this file on its own settings writes and
        // drops that key back out, the same class of machine mutation the v6-era entry above
        // records for `workbench.colorTheme`. Without this form a host that has ever had the
        // panel open reads as user-owned and can never be upgraded again, which is exactly how a
        // seed silently stops shipping.
        """
        {
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.colorCustomizations": {
                "editor.background": "#FFFBEB",
                "editorGroup.emptyBackground": "#FFFBEB",
                "editorGroupHeader.noTabsBackground": "#FFFBEB",
                "welcomePage.background": "#FFFBEB",
                "editorGutter.background": "#FFFBEB",
                "editorStickyScroll.background": "#FFFBEB",
                "editorWidget.background": "#FFFBEB",
                "breadcrumb.background": "#FFFBEB",
                "sideBar.background": "#FFFBEB",
                "sideBar.border": "#00000000",
                "sideBarSectionHeader.background": "#FFFBEB",
                "sideBarSectionHeader.border": "#00000000",
                "activityBar.background": "#FFFBEB",
                "activityBar.border": "#00000000",
                "editorGroupHeader.tabsBackground": "#FFFBEB",
                "editorGroupHeader.tabsBorder": "#00000000",
                "editorGroupHeader.border": "#00000000",
                "editorGroup.border": "#00000000",
                "tab.activeBackground": "#FFFBEB",
                "tab.inactiveBackground": "#FFFBEB",
                "tab.border": "#00000000",
                "panel.background": "#FFFBEB",
                "panel.border": "#00000000",
                "terminal.background": "#FFFBEB",
                "statusBar.background": "#FFFBEB",
                "statusBar.noFolderBackground": "#FFFBEB",
                "statusBar.border": "#00000000",
                "titleBar.activeBackground": "#FFFBEB",
                "titleBar.inactiveBackground": "#FFFBEB",
                "titleBar.border": "#00000000",
                "quickInput.background": "#FFFBEB",
                "menu.background": "#FFFBEB"
            },
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
            "files.autoSave": "onFocusChange"
        }
        """,
        // v25 — the flat-shadow, island-selection seed while the workbench still wore Monokai.
        // v26 hands the editor to Alucard, whose published `editor.background` IS the app's
        // ground, and drops the appearance-flip trio the two-polarity Monokai pair needed
        // (user-directed 2026-08-09).
        """
        {
            "chat.disableAIFeatures": true,
            "workbench.colorTheme": "Monokai Pro",
            "window.autoDetectColorScheme": true,
            "workbench.preferredDarkColorTheme": "Monokai Pro",
            "workbench.preferredLightColorTheme": "Monokai Pro Light",
            "workbench.colorCustomizations": {
                "editor.background": "#FFFBEB",
                "editorGroup.emptyBackground": "#FFFBEB",
                "editorGroupHeader.noTabsBackground": "#FFFBEB",
                "welcomePage.background": "#FFFBEB",
                "editorGutter.background": "#FFFBEB",
                "editorStickyScroll.background": "#FFFBEB",
                "editorWidget.background": "#FFFBEB",
                "breadcrumb.background": "#FFFBEB",
                "sideBar.background": "#FFFBEB",
                "sideBar.border": "#00000000",
                "sideBarSectionHeader.background": "#FFFBEB",
                "sideBarSectionHeader.border": "#00000000",
                "activityBar.background": "#FFFBEB",
                "activityBar.border": "#00000000",
                "editorGroupHeader.tabsBackground": "#FFFBEB",
                "editorGroupHeader.tabsBorder": "#00000000",
                "editorGroupHeader.border": "#00000000",
                "editorGroup.border": "#00000000",
                "tab.inactiveBackground": "#FFFBEB",
                "tab.border": "#00000000",
                "tab.activeBackground": "#22212C",
                "tab.activeForeground": "#F8F8F2",
                "tab.hoverBackground": "#22212C14",
                "list.activeSelectionBackground": "#22212C",
                "list.activeSelectionForeground": "#F8F8F2",
                "list.activeSelectionIconForeground": "#F8F8F2",
                "list.inactiveSelectionBackground": "#22212C",
                "list.inactiveSelectionForeground": "#F8F8F2",
                "list.inactiveSelectionIconForeground": "#F8F8F2",
                "list.focusBackground": "#22212C",
                "list.focusForeground": "#F8F8F2",
                "list.inactiveFocusBackground": "#22212C",
                "list.hoverBackground": "#22212C14",
                "list.focusOutline": "#00000000",
                "list.inactiveFocusOutline": "#00000000",
                "quickInputList.focusBackground": "#22212C",
                "quickInputList.focusForeground": "#F8F8F2",
                "quickInputList.focusIconForeground": "#F8F8F2",
                "editorSuggestWidget.selectedBackground": "#22212C",
                "editorSuggestWidget.selectedForeground": "#F8F8F2",
                "editorSuggestWidget.selectedIconForeground": "#F8F8F2",
                "menu.selectionBackground": "#22212C",
                "menu.selectionForeground": "#F8F8F2",
                "menu.selectionBorder": "#00000000",
                "widget.shadow": "#00000000",
                "scrollbar.shadow": "#00000000",
                "editorStickyScroll.shadow": "#00000000",
                "sideBarStickyScroll.shadow": "#00000000",
                "panelStickyScroll.shadow": "#00000000",
                "listFilterWidget.shadow": "#00000000",
                "welcomePage.tileShadow": "#00000000",
                "inlineChat.shadow": "#00000000",
                "diffEditor.unchangedRegionShadow": "#00000000",
                "panel.background": "#FFFBEB",
                "panel.border": "#00000000",
                "terminal.background": "#FFFBEB",
                "statusBar.background": "#FFFBEB",
                "statusBar.noFolderBackground": "#FFFBEB",
                "statusBar.border": "#00000000",
                "titleBar.activeBackground": "#FFFBEB",
                "titleBar.inactiveBackground": "#FFFBEB",
                "titleBar.border": "#00000000",
                "quickInput.background": "#FFFBEB",
                "menu.background": "#FFFBEB"
            },
            "workbench.iconTheme": "material-icon-theme",
            "workbench.startupEditor": "none",
            "workbench.editorAssociations": {
                "*.md": "vscode.markdown.preview.editor"
            },
            "workbench.activityBar.location": "top",
            "workbench.sideBar.location": "right",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "window.menuBarVisibility": "hidden",
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
            "editor.guides.indentation": true,
            "editor.guides.bracketPairs": "active",
            "editor.stickyScroll.enabled": true,
            "editor.renderWhitespace": "trailing",
            "workbench.tree.renderIndentGuides": "always",
            "workbench.tree.indent": 16,
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
    /// NOT `slopdesk-monokai` any more: the folder now carries the app's OWN theme beside the
    /// vendored family, and a folder named for one of its passengers ages into a lie. The old name
    /// is swept — see ``retiredExtensions``.
    static let themeExtensionName = "slopdesk-themes"
    static let themeExtensionVersion = "1.0.0"

    /// The seeded theme extension's folder name — `publisher.name-version`. A version bump here
    /// re-seeds changed theme bytes on the next hostd start (the writer overwrites on content
    /// drift) and re-registers the new folder.
    static let themeExtensionDirectoryName =
        "\(themeExtensionPublisher).\(themeExtensionName)-\(themeExtensionVersion)"

    /// EVERY theme this extension contributes — label (what the settings and the ⌘K ⌘T picker
    /// select by), dark/light, and the resource slug. This table is the single source of truth: the
    /// manifest below is generated from it and the seeder writes one file per row.
    ///
    /// ALUCARD LEADS, because it is the one the seed selects (user-directed 2026-08-09): the app's
    /// ground cream IS Alucard's published `editor.background`, so the editor canvas and the
    /// window's ground are the same colour by ORIGIN rather than by an override forcing them to
    /// agree. It is the app's own row — the eight below it are the vendored vsix's, and only THEY
    /// are mirrored by `scripts/monokai-sync.sh` (which fails loudly when the upstream set stops
    /// matching its own copy of the Monokai rows). All eight still ship (user-directed 2026-08-03):
    /// the picker offers the full family, the seed just no longer starts there.
    ///
    /// ``ownThemeResources`` marks which rows are ours, because the two kinds differ in shape as
    /// well as origin: a vendored theme names the workbench's whole key set (~600 colours), while
    /// ours names only what it means to change.
    static let ownThemeResources: Set<String> = ["alucard"]

    static let themeExtensionThemes: [(label: String, dark: Bool, resource: String)] = [
        ("Alucard", false, "alucard"),
        ("Monokai Pro", true, "monokai-pro"),
        ("Monokai Pro (Filter Octagon)", true, "monokai-pro-filter-octagon"),
        ("Monokai Pro (Filter Ristretto)", true, "monokai-pro-filter-ristretto"),
        ("Monokai Pro (Filter Spectrum)", true, "monokai-pro-filter-spectrum"),
        ("Monokai Pro (Filter Machine)", true, "monokai-pro-filter-machine"),
        ("Monokai Pro Light", false, "monokai-pro-light"),
        ("Monokai Pro Light (Filter Sun)", false, "monokai-pro-light-filter-sun"),
        ("Monokai Classic", true, "monokai-classic"),
    ]

    /// The theme extension's manifest — generated from ``themeExtensionThemes``.
    ///
    /// ALUCARD is the app's own row and the one the seed selects: the light half of the Dracula
    /// family, whose published `editor.background` is the very `#FFFBEB` the window's ground is
    /// made of. The two code surfaces beside each other — terminal glass and editor canvas — stop
    /// speaking different palettes, and the panel's background needs no override to match the app:
    /// it already IS the app's colour (user-directed 2026-08-09). The file is the theme verbatim,
    /// recovered from `1c8c294a^` where the pre-islands chrome revert had removed it.
    ///
    /// The other eight are STOCK Monokai Pro (all eight variants of vsix 2.0.13, monokai.pro — the pinned version
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
    /// panel keeps the workbench's stock file icons). Nothing here is redistributed: both families
    /// are seeded into the operator's own code-server profile for personal use.
    /// NO appearance FLIP any more (v26): the seed names Alucard outright and drops the
    /// `window.autoDetectColorScheme` trio the Monokai pair needed. The app has ONE appearance —
    /// law 4 makes the ground light, so the window's pinned `NSAppearance` is always light and the
    /// dark half of that switch could never fire. A pin is what the app actually is; a switch with
    /// one reachable arm is a mechanism pretending to have a choice.
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
            "name": "slopdesk-themes",
            "displayName": "SlopDesk Themes",
            "description": "Alucard (the app's ground palette) and stock Monokai Pro; seam borders carry the app's divider tint.",
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

    // MARK: - Bridge extension

    /// The seeded BRIDGE extension's identity — the app's own extension, the one piece of code
    /// (as opposed to theme data) SlopDesk runs inside the workbench. See
    /// `Resources/bridge/extension.js` for what it does and ``CodeBridgeServer`` for the host end.
    static let bridgeExtensionPublisher = "slopdesk"
    static let bridgeExtensionName = "slopdesk-bridge"
    /// Bumped whenever the manifest's CONTRIBUTIONS change, not merely its code: the seeder
    /// rewrites drifted bytes in place, but the workbench caches a scanned extension's
    /// `contributes` against its version, so new menu items on an unchanged version can go
    /// unnoticed until the profile is rebuilt. 1.1.0 = the terminal commands.
    static let bridgeExtensionVersion = "1.1.0"

    static let bridgeExtensionDirectoryName =
        "\(bridgeExtensionPublisher).\(bridgeExtensionName)-\(bridgeExtensionVersion)"

    /// Folders left behind by earlier versions. Unregistered the moment `extensions.json` points
    /// at the new one (the registry is the workbench's source of truth, not the folder listing),
    /// but swept anyway so a long-lived profile does not accumulate dead copies of our own code.
    static let legacyBridgeExtensionDirectoryNames = [
        "\(bridgeExtensionPublisher).\(bridgeExtensionName)-1.0.0",
    ]

    /// The bridge extension's manifest. `extensionKind: ["workspace"]` pins it to the REMOTE
    /// extension host — the one running on this machine, next to the socket and the files; the web
    /// worker host has neither. `onStartupFinished` keeps it off the workbench's critical path:
    /// the first open command cannot arrive before a window exists to receive it anyway.
    ///
    /// The two contributed commands are the editor's way BACK to the app: they type into a real
    /// SlopDesk pane rather than the workbench's own integrated terminal (see
    /// ``CodeBridgeTerminalRouter``). They sit in the editor context menu (`navigation` group, so
    /// they lead) and the explorer's, and are `enablement`-free on purpose — the host answers a
    /// request it cannot serve with a sentence, which is more use than a greyed-out item.
    static let bridgeExtensionManifest = """
    {
        "name": "\(bridgeExtensionName)",
        "displayName": "SlopDesk Bridge",
        "description": "Opens files sent by the SlopDesk host, and runs commands in its terminal panes.",
        "publisher": "\(bridgeExtensionPublisher)",
        "version": "\(bridgeExtensionVersion)",
        "engines": { "vscode": "^1.0.0" },
        "extensionKind": ["workspace"],
        "activationEvents": ["onStartupFinished"],
        "main": "./extension.js",
        "contributes": {
            "commands": [
                {
                    "command": "slopdesk.runSelectionInTerminal",
                    "title": "Run Selection in SlopDesk Terminal",
                    "category": "SlopDesk"
                },
                {
                    "command": "slopdesk.changeTerminalDirectory",
                    "title": "Change SlopDesk Terminal Directory Here",
                    "category": "SlopDesk"
                }
            ],
            "menus": {
                "editor/context": [
                    {
                        "command": "slopdesk.runSelectionInTerminal",
                        "when": "editorHasSelection",
                        "group": "navigation@1"
                    },
                    {
                        "command": "slopdesk.changeTerminalDirectory",
                        "when": "editorIsOpen",
                        "group": "navigation@2"
                    }
                ],
                "explorer/context": [
                    {
                        "command": "slopdesk.changeTerminalDirectory",
                        "group": "navigation@9"
                    }
                ]
            }
        }
    }
    """

    /// The bridge extension's entry point, carried as a target resource (real JS, kept in a `.js`
    /// file so it reads and lints as JavaScript rather than as a Swift string literal). `nil` only
    /// if the bundle is broken — then the seed is a no-op and opens fall back to the CLI.
    static func bridgeExtensionSource() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "Resources/bridge/extension", withExtension: "js",
        ) ?? Bundle.module.url(forResource: "extension", withExtension: "js")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes the bridge extension under `extensionsDir` and registers it, on the same terms as
    /// the theme seeder: the folder is namespaced `slopdesk.*`, so OUR files are overwritten
    /// whenever their bytes drift from the current source — that is how a hostd carrying a newer
    /// `extension.js` upgrades the deployed copy without a version bump.
    @discardableResult
    static func seedBridgeExtension(
        into extensionsDir: URL,
        source: () -> Data? = { bridgeExtensionSource() },
        fileManager: FileManager = .default,
    ) -> Bool {
        guard let js = source() else { return false }
        let root = extensionsDir.appendingPathComponent(bridgeExtensionDirectoryName)
        let files: [(URL, Data)] = [
            (root.appendingPathComponent("package.json"), Data(bridgeExtensionManifest.utf8)),
            (root.appendingPathComponent("extension.js"), js),
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
        for legacy in legacyBridgeExtensionDirectoryNames {
            let url = extensionsDir.appendingPathComponent(legacy)
            if fileManager.fileExists(atPath: url.path), (try? fileManager.removeItem(at: url)) != nil {
                wrote = true
            }
        }
        let registered = registerExtension(
            id: "\(bridgeExtensionPublisher).\(bridgeExtensionName)",
            version: bridgeExtensionVersion,
            directoryName: bridgeExtensionDirectoryName,
            in: extensionsDir,
        )
        return wrote || registered
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

    // MARK: - Retired built-in theme extension (removal)

    /// Every theme extension this manager has RETIRED, by registry id and by every folder name it
    /// ever shipped under. The ensure chain deletes each one before seeding the live extension, so
    /// a host that never saw them is a no-op and an upgraded host loses the leftovers the settings
    /// seed no longer selects.
    ///
    ///   • `slopdesk-foundry` — the app's own generated workbench themes (four Foundry seeds at
    ///     1.0.0, the Dracula / Alucard pair at 2.0.0), retired by the chrome revert
    ///     (user-directed 2026-08-08).
    ///   • `slopdesk-monokai` — the vendored family under its OLD folder name, before the theme
    ///     extension was renamed to carry the app's own Alucard alongside it (2026-08-09). Its
    ///     themes did not go anywhere; only the folder they live in did, and leaving the old one
    ///     behind would register the same eight labels twice in the picker.
    static let retiredExtensions: [(id: String, directoryNames: [String])] = [
        (
            "\(themeExtensionPublisher).slopdesk-foundry",
            [
                "\(themeExtensionPublisher).slopdesk-foundry-1.0.0",
                "\(themeExtensionPublisher).slopdesk-foundry-2.0.0",
            ],
        ),
        (
            "\(themeExtensionPublisher).slopdesk-monokai",
            ["\(themeExtensionPublisher).slopdesk-monokai-1.0.0"],
        ),
    ]

    /// Deletes every retired extension's folders and prunes its registry entry. Returns whether
    /// anything changed; failures are silent no-ops (the seeder convention).
    @discardableResult
    static func removeRetiredThemeExtensions(
        from extensionsDir: URL, fileManager: FileManager = .default,
    ) -> Bool {
        var changed = false
        for retired in retiredExtensions {
            for name in retired.directoryNames {
                let url = extensionsDir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path),
                   (try? fileManager.removeItem(at: url)) != nil
                {
                    changed = true
                }
            }
            if unregisterExtension(id: retired.id, in: extensionsDir) { changed = true }
        }
        return changed
    }

    /// Removes `id`'s entry from the profile registry (`extensions.json`) — the inverse of
    /// ``registerExtension(id:version:directoryName:in:)``, on the same terms: foreign entries
    /// are preserved, and a missing or unparseable registry is left alone (the workbench
    /// self-heals its own file).
    static func unregisterExtension(id: String, in extensionsDir: URL) -> Bool {
        let registryURL = extensionsDir.appendingPathComponent("extensions.json")
        guard let bytes = try? Data(contentsOf: registryURL),
              let entries = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
        else { return false }
        let kept = entries.filter {
            (($0["identifier"] as? [String: Any])?["id"] as? String) != id
        }
        guard kept.count != entries.count,
              let encoded = try? JSONSerialization.data(withJSONObject: kept)
        else { return false }
        do {
            try encoded.write(to: registryURL)
            return true
        } catch {
            return false
        }
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
        registerExtension(
            id: "\(themeExtensionPublisher).\(themeExtensionName)",
            version: themeExtensionVersion,
            directoryName: themeExtensionDirectoryName,
            in: extensionsDir,
        )
    }

    /// The registry write itself, shared by the theme and bridge seeders — see
    /// ``registerThemeExtension(in:fileManager:)`` for the contract this implements.
    static func registerExtension(
        id: String, version: String, directoryName: String, in extensionsDir: URL,
    ) -> Bool {
        let registryURL = extensionsDir.appendingPathComponent("extensions.json")
        var entries: [[String: Any]] = []
        if let bytes = try? Data(contentsOf: registryURL) {
            guard let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
            else { return false }
            entries = parsed
        }
        let ours: [String: Any] = [
            "identifier": ["id": id],
            "version": version,
            "location": [
                "$mid": 1,
                "path": extensionsDir.appendingPathComponent(directoryName).path,
                "scheme": "file",
            ],
            "relativeLocation": directoryName,
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

    // MARK: - Bundled marketplace extensions

    /// Marketplace extensions installed FOR REAL on first boot — unlike the vendored Monokai Pro
    /// theme data these run their own code, so only fully-free extensions (no license/purchase
    /// prompts in their activation path) qualify. Installed once via
    /// `code-server --install-extension` before the first spawn (user-directed 2026-08-03);
    /// updates ride the workbench's own extension updater from then on.
    ///
    /// - `pkief.material-icon-theme` — the Material Icon Theme file icons the seed's
    ///   `workbench.iconTheme` selects (MIT-licensed, data-driven, no nag).
    static let bundledMarketplaceExtensions = ["pkief.material-icon-theme"]

    /// The bundled ids absent from the profile registry (`extensions.json` — the workbench's
    /// installed-set source of truth; a folder scan lies once the file exists). `nil` or
    /// unparseable registry ⇒ ALL bundled ids are missing: a pristine host has no registry yet,
    /// and installing over a broken one lets the CLI rewrite it properly. Ids compare
    /// case-insensitively (the marketplace treats them so). Pure — unit-tested directly.
    static func missingBundledExtensions(inRegistry registry: Data?) -> [String] {
        guard let registry,
              let entries = try? JSONSerialization.jsonObject(with: registry) as? [[String: Any]]
        else { return bundledMarketplaceExtensions }
        let installed = Set(entries.compactMap {
            (($0["identifier"] as? [String: Any])?["id"] as? String)?.lowercased()
        })
        return bundledMarketplaceExtensions.filter { !installed.contains($0.lowercased()) }
    }

    /// The production ``InstalledExtensionsRegistry``: the profile registry beside the seeded
    /// theme extension, under the same data dir the children resolve.
    static let defaultInstalledExtensionsRegistry: InstalledExtensionsRegistry = {
        try? Data(contentsOf: dataDirURL().appendingPathComponent("extensions/extensions.json"))
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

    /// Where ``CodeBridgeServer`` listens: the user's temp dir, keyed by pid exactly like the
    /// agent hook and control sockets, so two hosts on one machine never share a socket file.
    static let bridgeSocketPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("slopdesk-code-bridge-\(getpid()).sock").path

    /// The environment every code-server child (server AND one-shot CLI) launches with: the
    /// parent's, plus ``marketplaceExtensionsGallery`` under `EXTENSIONS_GALLERY` — unless the
    /// operator exported their OWN gallery before hostd, which passes through untouched (the
    /// escape hatch IS the env var, not a new flag — docs/DECISIONS: important features ship
    /// unflagged) — plus ``bridgeSocketPath`` under `SLOPDESK_CODE_BRIDGE_SOCKET`, which the
    /// remote extension host inherits and the seeded bridge extension connects back to. A
    /// workbench started outside hostd sees no such var and the extension stays dormant.
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        bridgeSocket: String = bridgeSocketPath,
    ) -> [String: String] {
        var environment = base
        if (environment["EXTENSIONS_GALLERY"] ?? "").isEmpty {
            environment["EXTENSIONS_GALLERY"] = marketplaceExtensionsGallery
        }
        environment["SLOPDESK_CODE_BRIDGE_SOCKET"] = bridgeSocket
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
    /// plus the theme extension — ``seedThemeExtension(into:themeData:fileManager:)`` (the
    /// vendored Monokai Pro family the seeded settings select). The retired `slopdesk-foundry`
    /// generated-theme extension is swept here too
    /// (``removeRetiredThemeExtensions(from:fileManager:)``).
    static let defaultSettingsSeeder: SettingsSeeder = {
        seedUserSettings(at: userSettingsURL())
        let extensions = dataDirURL().appendingPathComponent("extensions")
        removeRetiredThemeExtensions(from: extensions)
        seedThemeExtension(into: extensions)
        seedBridgeExtension(into: extensions)
    }

    /// `SLOPDESK_CODE_SERVER_BIN` override, else the ``HostServiceProcess/searchDirectories`` walk —
    /// the version pinned in `ThirdParty/tools/tools.lock` first, then `PATH` and the homes `PATH`
    /// misses when hostd is launched outside a login shell. The pinned copy leading matters most
    /// here: everything this file seeds is keyed to a workbench version.
    static let defaultBinaryLocator: BinaryLocator = {
        HostServiceProcess.locate("code-server", overrideVariable: "SLOPDESK_CODE_SERVER_BIN")
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

    /// The production ``Spawner`` — ``HostServiceProcess/spawn(binary:arguments:environment:onLogLine:)``
    /// with the code-server child environment (marketplace gallery + the bridge socket path).
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            binary: binary, arguments: arguments, environment: childEnvironment(),
            onLogLine: onLogLine,
        )
    }

    /// The production ``ReadinessProbe``.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }
}
