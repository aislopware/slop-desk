import Foundation
import SlopDeskProtocol

/// Supervises the HOST's simulator server — the backend of the client's right-panel Simulators
/// surface (``MetadataVerb/ensureSimulatorServer``).
///
/// **Why a child process and not our own capture.** Apple's iOS Simulator is the one macOS surface
/// that publishes its framebuffer and accepts HID input through an API instead of the screen:
/// CoreSimulator hands out the device's `IOSurface` directly and takes touch/key events into the
/// simulated device. That is strictly better than pointing this app's own ScreenCaptureKit path at
/// the Simulator window — no screen-recording permission, no window geometry to track, no bezel or
/// shadow to crop out, no focus stolen on input, and it works while the window is closed. It is
/// also a PRIVATE-API path that Apple moves between Xcode majors (Xcode 27 relocated
/// `SimulatorKit.framework` and suppressed the legacy HID transport), so the risk lives in a
/// SEPARATE PROCESS the host supervises: when it breaks, the panel reports unavailable and hostd
/// keeps running.
///
/// **ONE shared instance, lazily.** Simulators are a machine resource, not a project one — a host
/// has one set of devices, and every pane, project and client sees the same set through the one
/// child. There is nothing to scope, so unlike ``CodeServerManager/ensure(projectRoot:)`` this
/// ensure takes no root.
///
/// **`ensure` never waits.** Same contract, same reason: the caller sits on the metadata queue
/// answering an RPC whose client-side timeout is 5 s, and the child's first boot enumerates
/// CoreSimulator device sets. It spawns with port `0` (the OS picks) and learns the real port from
/// the child's own listening line — no pre-bind allocation race. `ready` means a loopback connect
/// to the learned port succeeded, probed at most once per ``probeInterval``.
///
/// **Crash recovery is implicit**: a child that exited reads `isRunning == false` on the next
/// `ensure`, which drops the record and respawns fresh.
///
/// **No auth token.** The child binds `0.0.0.0` with no credential: security = the WireGuard mesh,
/// identical to every other port hostd opens (docs/DECISIONS — no app-layer crypto/auth).
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes' requests
/// race.
final class SimulatorServerManager: @unchecked Sendable {
    /// Finds the `baguette` executable, or `nil` when the host has none (→ `.unavailable`).
    typealias BinaryLocator = HostServiceProcess.BinaryLocator
    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port
    /// parse). Throws when the exec itself fails (missing/broken binary → `.unavailable`).
    typealias Spawner = HostServiceProcess.Spawner
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = HostServiceProcess.ReadinessProbe

    /// The spawn-learn-probe-latch lifecycle, shared with the code and Android panels. What is left
    /// in this file is what makes it the SIMULATOR server.
    private let service: ProbedPortService
    private let locateBinary: BinaryLocator
    private let spawn: Spawner

    init(
        binaryLocator: @escaping BinaryLocator = SimulatorServerManager.defaultBinaryLocator,
        spawner: @escaping Spawner = SimulatorServerManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = SimulatorServerManager.defaultReadinessProbe,
        probeInterval: Duration = .milliseconds(500),
    ) {
        locateBinary = binaryLocator
        spawn = spawner
        service = ProbedPortService(readinessProbe: readinessProbe, probeInterval: probeInterval)
    }

    /// Ensures the shared simulator server and reports where it stands RIGHT NOW (never waits).
    func ensure() -> MetadataCodec.ServiceEndpoint {
        service.ensure { generation in
            guard let binary = locateBinary() else { return .notYet(.unavailable) }
            let onLine = service.portSink(generation: generation) {
                Self.parseListeningPort(fromLogLine: $0)
            }
            // A present-but-unrunnable binary (a broken Homebrew link, a quarantined build) throws
            // out of the spawner, and reads the same as an absent one — the panel's install hint is
            // the right surface for both.
            guard let handle = try? spawn(binary, Self.launchArguments(), onLine) else {
                return .notYet(.unavailable)
            }
            return .spawned(handle)
        }
    }

    /// Ends the server for good. Booted DEVICES are deliberately left alone — they are the user's
    /// machine state, outlive any one hostd run, and `baguette` itself only shuts down what it was
    /// told to.
    ///
    /// ⚠️ **Not the daemon-shutdown path any more** — that is ``relinquish()``. See
    /// ``SupervisedServiceProcess``.
    func shutdown() {
        service.forget()?.terminate()
    }

    /// Lets the server GO: hostd stops listening and superd keeps it, so the next hostd adopts a
    /// simulator panel that is already up rather than paying the boot again.
    func relinquish() {
        service.forget()?.relinquish()
    }

    // MARK: - What makes it the simulator server

    /// The child's argument vector. Port `0` (learn the real one from its listening line, no
    /// pre-bind race) on `0.0.0.0` so mesh clients reach it — the client fronts it with a loopback
    /// relay anyway, and `baguette` trusts loopback `Host`/`Origin` values by default, which is
    /// exactly what the relay presents.
    static func launchArguments() -> [String] {
        ["serve", "--port", "0", "--host", "0.0.0.0"]
    }

    /// Extracts the bound port from the child's own announcement, e.g.
    /// `… info Hummingbird: [HummingbirdCore] Server started and listening on 0.0.0.0:54593`.
    /// `nil` for every other line.
    ///
    /// The server-framework line is the ONLY usable source: `baguette`'s own
    /// `[baguette] listening on http://0.0.0.0:0/simulators` banner echoes the port it was ASKED
    /// for, which under port `0` is literally `0`. The `port > 0` guard rejects that banner even if
    /// a future build reworded it into this shape.
    static func parseListeningPort(fromLogLine line: String) -> UInt16? {
        AnnouncedPort.afterLastColonFollowing("listening on ", in: line)
    }

    // MARK: - Production seams

    /// `SLOPDESK_SIMULATOR_SERVER_BIN` override, else the walk `locate_tool` in
    /// `rust/slopdesk-androidd/src/toolchain.rs` owns — the version pinned in
    /// `ThirdParty/tools/tools.lock` first, then `PATH` and the prefixes `PATH` misses when hostd is
    /// launched outside a login shell.
    static let defaultBinaryLocator: BinaryLocator = {
        HostServiceProcess.locate("baguette", overrideVariable: "SLOPDESK_SIMULATOR_SERVER_BIN")
    }

    /// The production ``Spawner``. The child inherits hostd's environment verbatim — it resolves
    /// Xcode through `xcode-select`, and an operator's `DEVELOPER_DIR` must reach it unchanged.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            service: "baguette", binary: binary, arguments: arguments,
            environment: ProcessInfo.processInfo.environment, onLogLine: onLogLine,
        )
    }

    /// The production ``ReadinessProbe``.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }
}
