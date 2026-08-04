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
    typealias BinaryLocator = @Sendable () -> String?
    /// Spawns the child; `onLogLine` receives each line of its merged stdout/stderr (the port
    /// parse). Throws when the exec itself fails (missing/broken binary → `.unavailable`).
    typealias Spawner = @Sendable (
        _ binary: String, _ arguments: [String], _ onLogLine: @escaping @Sendable (String) -> Void,
    ) throws -> any HostServiceProcessHandle
    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = @Sendable (_ port: UInt16) -> Bool

    private struct Instance {
        var handle: any HostServiceProcessHandle
        /// Learned from the child's listening line; `nil` until it prints one.
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
    private let locateBinary: BinaryLocator
    private let spawn: Spawner
    private let probe: ReadinessProbe
    private let probeInterval: Duration
    private let clock = ContinuousClock()

    init(
        binaryLocator: @escaping BinaryLocator = SimulatorServerManager.defaultBinaryLocator,
        spawner: @escaping Spawner = SimulatorServerManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = SimulatorServerManager.defaultReadinessProbe,
        probeInterval: Duration = .milliseconds(500),
    ) {
        locateBinary = binaryLocator
        spawn = spawner
        probe = readinessProbe
        self.probeInterval = probeInterval
    }

    /// Ensures the shared simulator server and reports where it stands RIGHT NOW (never waits).
    func ensure() -> MetadataCodec.ServiceEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let existing = instance {
            if existing.handle.isRunning {
                return endpointLocked(for: existing)
            }
            instance = nil
        }

        guard let binary = locateBinary() else {
            return MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0)
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

    /// Terminates the child (hostd shutdown). Booted DEVICES are deliberately left alone — they are
    /// the user's machine state, outlive any one hostd run, and `baguette` itself only shuts down
    /// what it was told to.
    func shutdown() {
        lock.lock()
        let stranded = instance
        instance = nil
        lock.unlock()
        stranded?.handle.terminate()
    }

    /// The endpoint for a LIVE instance, probing readiness at most once per ``probeInterval``.
    /// Mutates the record (latched `ready`, probe stamp) — callers hold the lock.
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
        }
        instance = updated
        // The learned port rides along even while starting, as ``CodeServerManager`` does: it is
        // the honest answer to "where will it be", and the client gates on the STATE.
        return MetadataCodec.ServiceEndpoint(state: updated.ready ? .ready : .starting, port: port)
    }

    /// Records the port the child announced — ignored when a respawn has already superseded the
    /// generation that produced the line (a dying child's last line must not poison the new record).
    private func recordPort(_ port: UInt16, spawnedAs generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == spawnGeneration, var live = instance, live.port == nil else { return }
        live.port = port
        instance = live
    }

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
        guard let markerRange = line.range(of: "listening on ") else { return nil }
        let rest = line[markerRange.upperBound...]
        // The address may be bracketed IPv6, a bare IPv4, or a URL — the port is the trailing
        // digit run after the LAST colon either way.
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let digits = rest[rest.index(after: colon)...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let port = UInt16(digits), port > 0 else { return nil }
        return port
    }

    // MARK: - Production seams

    /// `SLOPDESK_SIMULATOR_SERVER_BIN` override, else a `PATH` walk plus the Homebrew prefixes
    /// `PATH` misses when hostd is launched outside a login shell.
    static let defaultBinaryLocator: BinaryLocator = {
        HostServiceProcess.locate("baguette", overrideVariable: "SLOPDESK_SIMULATOR_SERVER_BIN")
    }

    /// The production ``Spawner``. The child inherits hostd's environment verbatim — it resolves
    /// Xcode through `xcode-select`, and an operator's `DEVELOPER_DIR` must reach it unchanged.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            binary: binary, arguments: arguments,
            environment: ProcessInfo.processInfo.environment, onLogLine: onLogLine,
        )
    }

    /// The production ``ReadinessProbe``.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }
}
