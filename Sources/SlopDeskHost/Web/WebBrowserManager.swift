import Foundation
import SlopDeskProtocol
import SlopDeskVideoProtocol

/// Supervises the HOST's browser — the backend of the client's right-panel Web surface
/// (``MetadataVerb/ensureWebBrowser``).
///
/// **Why the browser runs on the HOST and not in the client's own web view.** The client already
/// embeds WebKit, so rendering the page locally was the cheaper build. It was rejected on two
/// counts that a preview pane cannot buy back. First, the page under development is served by the
/// host: a dev server bound to the host's `localhost`, with the host's hosts-file, certificates and
/// cookies. A browser sitting ON the host reaches it by typing `localhost:5173` — nothing to map,
/// nothing to rewrite, and an absolute link the app emits to its own origin still resolves.
/// Second, inspection: WebKit exposes no supported way to open its Web Inspector from an embedding
/// app (the private `_inspector` path exists, is macOS-only, and can crash inside `platformAttach`),
/// while Chrome serves its ENTIRE DevTools frontend from this debugging port — measured 2026-08-05
/// rendering and driving a page correctly inside WKWebView on macOS AND iPadOS, with no private
/// API on either. One surface, one behaviour, every client.
///
/// **ONE shared instance, lazily** — verb 21's rationale: a host has one browser, and every pane,
/// project and client drives the same one. So `ensure` takes no root.
///
/// **`ensure` never waits**, the same contract as verbs 18/21/22: it spawns as a side effect and
/// answers with the CURRENT state, because a cold Chrome start outruns the client registry's 5 s
/// timeout. Port `0` on the command line, real port learned from Chrome's own announce line — the
/// no-pre-bind-race pattern ``SimulatorServerManager`` uses.
///
/// **The reported port is the RELAY's** (``WebDebugRelay``), never Chrome's: Chrome's debugging
/// socket is loopback-only and cannot be moved off it. The relay outlives any one child so its port
/// — and therefore the client's loopback origin, and therefore the DevTools frontend's stored panel
/// layout — survives a respawn.
///
/// **The child is terminated on shutdown**, unlike verb 21's booted simulators and verb 22's
/// emulators. Those are the user's own machine state; this is a headless browser on a profile
/// nothing else uses, invisible on the host's screen, so leaving it running would strand a process
/// no one can see.
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes race.
final class WebBrowserManager: @unchecked Sendable {
    /// Finds the Chrome-family executable, or `nil` when the host has none (→ `.unavailable`).
    typealias BinaryLocator = @Sendable () -> String?
    /// The `--user-data-dir` to run on, or `nil` when it cannot be resolved (→ `.unavailable`).
    typealias ProfileLocator = @Sendable () -> String?
    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port parse).
    typealias Spawner = @Sendable (
        _ binary: String, _ arguments: [String], _ onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any HostServiceProcessHandle
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = @Sendable (_ port: UInt16) -> Bool
    /// Builds the mesh-facing relay in front of Chrome's loopback port.
    typealias RelayFactory = @Sendable (_ browserPort: UInt16) -> (any WebDebugRelayHandle)?

    private struct Instance {
        var handle: any HostServiceProcessHandle
        /// Learned from Chrome's announce line; `nil` until it prints one.
        var port: UInt16?
        /// Latched on the first successful probe — a listening browser is never un-probed.
        var ready = false
        var lastProbe: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var instance: Instance?
    /// Outlives the child (see the type doc): built on the first ready browser, retargeted after.
    private var relay: (any WebDebugRelayHandle)?
    /// What ``relay`` currently points at — retarget only on a real move, not once per poll.
    private var relayTargetPort: UInt16?
    /// Bumped per spawn; a dying child's last line must not write its port onto the fresh record.
    private var spawnGeneration = 0
    private let locateBinary: BinaryLocator
    private let locateProfile: ProfileLocator
    private let spawn: Spawner
    private let probe: ReadinessProbe
    private let makeRelay: RelayFactory
    private let probeInterval: Duration
    private let clock = ContinuousClock()

    init(
        binaryLocator: @escaping BinaryLocator = WebBrowserManager.defaultBinaryLocator,
        profileLocator: @escaping ProfileLocator = WebBrowserManager.defaultProfileLocator,
        spawner: @escaping Spawner = WebBrowserManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = WebBrowserManager.defaultReadinessProbe,
        relayFactory: @escaping RelayFactory = WebBrowserManager.defaultRelayFactory,
        probeInterval: Duration = .milliseconds(500),
    ) {
        locateBinary = binaryLocator
        locateProfile = profileLocator
        spawn = spawner
        probe = readinessProbe
        makeRelay = relayFactory
        self.probeInterval = probeInterval
    }

    /// Ensures the shared browser and reports where it stands RIGHT NOW (never waits).
    func ensure() -> MetadataCodec.ServiceEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let existing = instance {
            if existing.handle.isRunning {
                return endpointLocked(for: existing)
            }
            instance = nil
        }

        guard let binary = locateBinary(), let profile = locateProfile() else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
        }
        spawnGeneration += 1
        let generation = spawnGeneration
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            guard let port = Self.parseDevToolsPort(fromLogLine: line) else { return }
            self?.recordPort(port, spawnedAs: generation)
        }
        guard let handle = try? spawn(binary, Self.launchArguments(profileDirectory: profile), onLine) else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
        }
        instance = Instance(handle: handle)
        return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
    }

    /// Terminates the child and drops the relay (hostd shutdown) — see the type doc for why this
    /// one does kill its process while the device-panel managers do not.
    func shutdown() {
        lock.lock()
        let stranded = instance
        let strandedRelay = relay
        instance = nil
        relay = nil
        relayTargetPort = nil
        lock.unlock()
        stranded?.handle.terminate()
        strandedRelay?.stop()
    }

    /// The endpoint for a LIVE child, probing at most once per ``probeInterval``. Mutates the
    /// record (latched `ready`, probe stamp, relay) — callers hold the lock.
    private func endpointLocked(for live: Instance) -> MetadataCodec.ServiceEndpoint {
        guard let browserPort = live.port else {
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        var updated = live
        if !updated.ready {
            let now = clock.now
            let due = live.lastProbe.map { now - $0 >= probeInterval } ?? true
            if due {
                updated.lastProbe = now
                updated.ready = probe(browserPort)
            }
        }
        instance = updated
        guard updated.ready else {
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        // The relay is built on the first ready browser rather than at spawn: a listener fronting a
        // port nothing answers on would accept a client's connection and drop it, which reads as a
        // dead browser instead of a booting one.
        if relay == nil {
            relay = makeRelay(browserPort)
            relayTargetPort = browserPort
        } else if relayTargetPort != browserPort {
            relay?.retarget(toLoopbackPort: browserPort)
            relayTargetPort = browserPort
        }
        guard let relayPort = relay?.port, relayPort > 0 else {
            // Bound-but-not-ready listener, or one that failed to bind at all: keep saying
            // `starting`. The client polls, and a listener that never comes up never lies ready.
            return MetadataCodec.ServiceEndpoint(state: .starting, port: 0)
        }
        return MetadataCodec.ServiceEndpoint(state: .ready, port: relayPort)
    }

    /// Records the port Chrome announced — ignored when a respawn already superseded the generation
    /// that produced the line.
    private func recordPort(_ port: UInt16, spawnedAs generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == spawnGeneration, var live = instance, live.port == nil else { return }
        live.port = port
        instance = live
    }

    /// The child's argument vector. Every flag here is load-bearing:
    ///
    /// - `--headless=new` — the browser must not put a window on the host's screen; the user is
    ///   looking at the client. Measured: the new headless mode screencasts at 75 fps, and
    ///   `--use-angle=metal --enable-gpu` changes nothing (unlike the Android emulator, whose
    ///   software renderer cost 10× — there is no equivalent trap here).
    /// - `--remote-debugging-port=0` — learn the real port from the announce line.
    /// - `--remote-allow-origins=*` — REQUIRED since Chrome 111. The DevTools frontend is loaded
    ///   from the client's loopback origin, so its websocket upgrade carries an `Origin` header,
    ///   and Chrome closes any such connection that is not allow-listed. Measured symptom without
    ///   it: the frontend renders in full and then shows "Debugging connection was closed".
    ///   The allow-list is not the security boundary — reaching the port at all already means
    ///   crossing the mesh.
    /// - `--user-data-dir=` — a profile of our own is mandatory, not tidy: Chrome 136+ REFUSES
    ///   remote debugging on the OS-default profile directory, and a Chrome the user is running
    ///   holds that directory's singleton lock anyway. Persistent, so logins survive a respawn.
    /// - `--no-first-run` / `--no-default-browser-check` — first-run state and a default-browser
    ///   prompt would dirty a profile nothing ever looks at.
    /// - `about:blank` — start with a page target, so the client always has something to attach to
    ///   without minting one first.
    static func launchArguments(profileDirectory: String) -> [String] {
        [
            "--headless=new",
            "--remote-debugging-port=0",
            "--remote-allow-origins=*",
            "--user-data-dir=" + profileDirectory,
            "--no-first-run",
            "--no-default-browser-check",
            "--window-size=1440,900",
            "about:blank",
        ]
    }

    /// Extracts the port from Chrome's own announcement, e.g.
    /// `DevTools listening on ws://127.0.0.1:59123/devtools/browser/6c1f…`. `nil` for every other
    /// line — including a line that names the port it was ASKED for, which under port `0` is `0`
    /// (the `port > 0` guard, kept for ``SimulatorServerManager/parseListeningPort(fromLogLine:)``'s
    /// reason).
    static func parseDevToolsPort(fromLogLine line: String) -> UInt16? {
        guard let markerRange = line.range(of: "DevTools listening on ws://") else { return nil }
        // The authority ends at the websocket path; the port is the digit run after its last colon
        // (an IPv6 literal carries several).
        let authority = line[markerRange.upperBound...].prefix { $0 != "/" }
        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let digits = authority[authority.index(after: colon)...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let port = UInt16(digits), port > 0 else { return nil }
        return port
    }

    /// Where the browser's profile lives: `SLOPDESK_WEB_PROFILE_DIR` wins, else `web-profile`
    /// inside the app-support container (which ``SlopDeskAppSupport/directoryEnvKey`` can move).
    static func profileDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        if let override = environment[profileDirectoryEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return SlopDeskAppSupport.directory(environment: environment, fileManager: fileManager)?
            .appendingPathComponent("web-profile", isDirectory: true)
    }

    static let profileDirectoryEnvKey = "SLOPDESK_WEB_PROFILE_DIR"

    // MARK: - Production seams

    static let defaultBinaryLocator: BinaryLocator = { WebBrowserToolchain.locate() }

    static let defaultProfileLocator: ProfileLocator = { profileDirectory()?.path }

    /// The production ``Spawner``. The child inherits hostd's environment verbatim — a proxy or
    /// `HOME` an operator set must reach it unchanged.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            binary: binary, arguments: arguments,
            environment: ProcessInfo.processInfo.environment, onLogLine: onLogLine,
        )
    }

    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }

    static let defaultRelayFactory: RelayFactory = { browserPort in
        WebDebugRelay.start(targetLoopbackPort: browserPort)
    }
}
