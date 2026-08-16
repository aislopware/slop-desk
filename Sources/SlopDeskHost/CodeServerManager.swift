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
    typealias BinaryLocator = HostServiceProcess.BinaryLocator
    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port
    /// parse). Throws when the exec itself fails (missing/broken binary → `.unavailable`).
    typealias Spawner = HostServiceProcess.Spawner
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = HostServiceProcess.ReadinessProbe
    /// Seeds the workbench profile before the FIRST spawn — settings, extensions, the retired
    /// sweep. One fork of `slopdesk-codeseed`, which owns every one of those decisions.
    typealias SettingsSeeder = @Sendable () -> Void
    /// Runs the code-server CLI once to completion and reports its exit status (`nil` = the exec
    /// itself failed). Distinct from ``Spawner`` — the CLI is a short-lived command whose EXIT CODE
    /// is the answer, not a supervised child.
    typealias CLIRunner = @Sendable (_ binary: String, _ arguments: [String]) async -> Int32?
    /// The bundled marketplace extensions the profile registry does not carry yet — what the
    /// one-shot install pass before the first spawn has to fetch. Empty ⇒ spawn straight away.
    typealias MissingExtensions = @Sendable () -> [String]
    /// Folds a client's font spec into the live settings file; `true` when the file changed.
    typealias FontSync = @Sendable (MetadataCodec.CodeFontSpec) -> Bool
    /// Everything the seeder decides about a LAUNCH. `nil` ⇒ this host has no seeder, and the
    /// panel reports unavailable rather than spawning a workbench on guessed arguments.
    typealias ProfileReader = @Sendable () -> Profile?

    /// The seeder's launch answers, read once per manager.
    struct Profile: Sendable {
        /// The child's argv after the binary path.
        var arguments: [String]
        /// Where ``CodeBridgeServer`` binds and the seeded extension dials back — pid-free, so a
        /// workbench that outlived a hostd reconnects to the same name (`docs/51` §1).
        var bridgeSocket: String
    }

    /// The spawn-learn-probe-latch lifecycle, shared with the simulator and Android panels — and
    /// with it the ONE lock this manager has. The boot gates below are the workbench's own, and
    /// they are held under that same lock rather than a second one: they gate the same spawn.
    private let service: ProbedPortService
    /// Latched by the first spawn — the settings seed runs at most once per manager lifetime (the
    /// seeder itself is also a no-op when the file exists; this just skips the repeat file checks).
    private var settingsSeeded = false
    /// The one-shot marketplace install of ``missingExtensions``' answer, checked before the
    /// first spawn: `.installing` DEFERS the spawn (ensure keeps answering `.starting`; the client
    /// polls ~1 Hz) so the workbench's very first boot already scans the icon pack — install and
    /// boot writing `extensions.json` concurrently is also how registrations get lost. `.done` is
    /// latched even when an install FAILS (no network): the panel is never held hostage by a
    /// nicety, and the next hostd launch retries because the registry still misses the id.
    private enum BundledExtensionInstall { case unchecked, installing, done }
    private var bundledExtensionInstall: BundledExtensionInstall = .unchecked
    private let locateBinary: BinaryLocator
    private let spawn: Spawner
    private let seedSettings: SettingsSeeder
    private let runCLI: CLIRunner
    private let missingExtensions: MissingExtensions
    private let readProfile: ProfileReader
    /// The bridge extension's host end — injectable so unit tests never bind a real `AF_UNIX`
    /// listener (hang-safety, same reason the spawner is faked).
    private let bridge: any CodeBridgeRouting
    /// Latched with ``settingsSeeded`` — the listener binds once, lazily, so a host whose user
    /// never opens the code panel never creates the socket at all.
    private var bridgeStarted = false
    /// The instance-level font sync — injectable so unit tests NEVER reach (and patch) the
    /// developer's real `~/.local/share/code-server/User/settings.json` (the same trap
    /// `SLOPDESK_WORKSPACE_STATE_DIR` guards on the workspace store).
    private let syncFont: FontSync
    private let openRetryDelay: Duration

    init(
        binaryLocator: @escaping BinaryLocator = CodeServerManager.defaultBinaryLocator,
        spawner: @escaping Spawner = CodeServerManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = CodeServerManager.defaultReadinessProbe,
        settingsSeeder: @escaping SettingsSeeder = CodeServerManager.defaultSettingsSeeder,
        cliRunner: @escaping CLIRunner = CodeServerManager.defaultCLIRunner,
        missingExtensions: @escaping MissingExtensions = CodeServerManager.defaultMissingExtensions,
        fontSync: @escaping FontSync = CodeServerManager.defaultFontSync,
        profileReader: @escaping ProfileReader = CodeServerManager.defaultProfileReader,
        bridge: any CodeBridgeRouting = CodeBridgeServer(),
        probeInterval: Duration = .milliseconds(500),
        openRetryDelay: Duration = .seconds(2),
    ) {
        self.bridge = bridge
        locateBinary = binaryLocator
        spawn = spawner
        seedSettings = settingsSeeder
        runCLI = cliRunner
        self.missingExtensions = missingExtensions
        syncFont = fontSync
        readProfile = profileReader
        self.openRetryDelay = openRetryDelay
        service = ProbedPortService(readinessProbe: readinessProbe, probeInterval: probeInterval)
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
        service.locked { _ = bootLocked() }
    }

    /// Ensures the shared code-server and reports where it stands RIGHT NOW (never waits). `nil`
    /// when `projectRoot` is not an absolute path to an existing host directory (→ `.notFound` on
    /// the wire — never hand out an endpoint for a path the host cannot see).
    func ensure(projectRoot: String) -> MetadataCodec.ServiceEndpoint? {
        guard Self.canonicalRoot(projectRoot) != nil else { return nil }
        return service.locked { bootLocked() }
    }

    /// The one shared boot path (caller holds the service's lock): observe a live child, or walk
    /// the one-time chain — settings seed, bridge bind, bundled-extension install — and spawn. Both
    /// ``ensure`` (per verb-18 round) and ``prewarm``/``finishBundledExtensionInstall`` (once each)
    /// land here.
    ///
    /// The observe-or-drop head, the spawn generation and the probe are ``ProbedPortService``'s;
    /// the four gates between the binary and the spawn are what the WORKBENCH adds to that shape,
    /// and the reason this manager walks the pieces rather than taking ``ProbedPortService/ensure``.
    private func bootLocked() -> MetadataCodec.ServiceEndpoint {
        service.bootLocked { generation in
            guard let binary = locateBinary() else { return .notYet(.unavailable) }
            // A host with no `slopdesk-codeseed` has no argv and no bridge socket to give the child.
            // Reporting unavailable is the honest answer: a workbench launched on guessed arguments
            // (`--auth none` on a guessed port) is a different program, not a degraded panel.
            guard let profile = readProfile() else { return .notYet(.unavailable) }
            // Seed the workbench defaults before the FIRST child ever boots — after it has read an
            // absent settings file once, a seed would need a reload to take. One fork under the
            // lock, once per manager lifetime.
            if !settingsSeeded {
                settingsSeeded = true
                seedSettings()
            }
            // The bridge listener must exist BEFORE the child inherits its path, or the extension's
            // first connect races the bind and burns a 5 s reconnect delay on every cold start.
            if !bridgeStarted {
                bridgeStarted = true
                bridge.start(path: profile.bridgeSocket)
            }
            // Bundled marketplace extensions install before the FIRST spawn (see
            // ``BundledExtensionInstall``); while the one-shot CLI runs, ensure keeps its never-wait
            // contract by answering `.starting`.
            switch bundledExtensionInstall {
            case .unchecked:
                let missing = missingExtensions()
                if missing.isEmpty {
                    bundledExtensionInstall = .done
                } else {
                    bundledExtensionInstall = .installing
                    installBundledExtensions(missing, binary: binary)
                    return .notYet(.starting)
                }
            case .installing:
                return .notYet(.starting)
            case .done:
                break
            }
            let onLine = service.portSink(generation: generation) {
                Self.parseListeningPort(fromLogLine: $0)
            }
            guard let handle = try? spawn(binary, profile.arguments, onLine) else {
                return .notYet(.unavailable)
            }
            return .spawned(handle)
        }
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

    /// Ends the workbench for good. With no idle reaper this is the ONLY thing that stops it.
    ///
    /// ⚠️ **Not the daemon-shutdown path any more** — that is ``relinquish()``. Routing a hostd stop
    /// back through here restores exactly what `docs/51` exists to remove, one panel down: every
    /// host edit would again cost the user a Node boot before the editor came back.
    func shutdown() {
        let stranded = forget()
        stranded?.terminate()
    }

    /// Lets the workbench GO: hostd stops listening and superd keeps the Node process running, so
    /// the next hostd adopts it and the panel is warm the instant it comes back.
    ///
    /// The bridge listener DOES stop — that socket is hostd's, not superd's. The surviving
    /// extension host reconnects to the same pid-free path within one of its 5 s ticks
    /// (``CodeSeed/Paths/bridgeSocket``).
    func relinquish() {
        let released = forget()
        released?.relinquish()
    }

    /// Drops the record and stops the bridge, and decides nothing about the child. Returns the
    /// handle for the caller to end or release.
    private func forget() -> (any HostServiceProcessHandle)? {
        let stranded = service.forget { bridgeStarted = false }
        bridge.stop()
        return stranded
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
        service.locked {
            bundledExtensionInstall = .done
            _ = bootLocked()
        }
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

    /// Extracts the bound port from code-server's own announcement, e.g.
    /// `[…] info  HTTP server listening on http://0.0.0.0:62636/`. `nil` for every other line.
    static func parseListeningPort(fromLogLine line: String) -> UInt16? {
        AnnouncedPort.afterLastColonFollowing("HTTP server listening on http://", in: line)
    }

    // MARK: - Editor font sync (verb 20)

    /// Folds a client's ``MetadataCodec/CodeFontSpec`` into the live settings file — the instance
    /// entry point the performer calls, serialized under the manager lock like every other settings
    /// touch. The patch itself belongs to ``CodeSeed``: it is a decision about a JSON file the
    /// workbench also writes, which is the whole line stage 22 drew.
    @discardableResult
    func syncEditorFont(_ spec: MetadataCodec.CodeFontSpec) -> Bool {
        service.locked { syncFont(spec) }
    }

    // MARK: - Production seams

    /// The production ``SettingsSeeder`` — one fork of `slopdesk-codeseed`, which seeds the user
    /// settings, sweeps the retired extensions and writes the theme and bridge extensions.
    static let defaultSettingsSeeder: SettingsSeeder = {
        CodeSeed.seed()
    }

    /// The production ``MissingExtensions`` — the seeder reads the profile registry, because it is
    /// the same file it registers our own two extensions in.
    static let defaultMissingExtensions: MissingExtensions = {
        CodeSeed.missingBundledExtensions()
    }

    /// The production ``FontSync``.
    static let defaultFontSync: FontSync = { spec in
        CodeSeed.syncEditorFont(spec)
    }

    /// The production ``ProfileReader``. Both halves come from the seeder and both are cached
    /// there, so a manager that asks per boot still forks only once per hostd.
    static let defaultProfileReader: ProfileReader = {
        guard let arguments = CodeSeed.launchArguments, let paths = CodeSeed.paths else {
            return nil
        }
        return Profile(arguments: arguments, bridgeSocket: paths.bridgeSocket)
    }

    /// `SLOPDESK_CODE_SERVER_BIN` override, else the ``HostServiceProcess/searchDirectories`` walk —
    /// the version pinned in `ThirdParty/tools/tools.lock` first, then `PATH` and the homes `PATH`
    /// misses when hostd is launched outside a login shell. The pinned copy leading matters most
    /// here: everything the seeder writes is keyed to a workbench version.
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
            process.environment = CodeSeed.childEnvironment
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

    /// The production ``Spawner`` —
    /// ``HostServiceProcess/spawn(service:binary:arguments:environment:onLogLine:)`` with the
    /// code-server child environment (marketplace gallery + the bridge socket path).
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            service: "code-server", binary: binary, arguments: arguments,
            environment: CodeSeed.childEnvironment, onLogLine: onLogLine,
        )
    }

    /// The production ``ReadinessProbe``.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }
}
