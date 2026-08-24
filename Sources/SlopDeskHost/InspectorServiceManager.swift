import Foundation
import SlopDeskSupervisor

/// PATH 3's daemon, held by superd: `slopdesk-inspectord` on `terminalPort + 1`.
///
/// ## hostd was never in this byte path either
/// The inspector has always ridden its own TCP connection — the client dials `terminalPort + 1`
/// directly and nothing about it touches the terminal mux. What hostd contributed was the PROCESS:
/// a per-turn JSON fold, a growing replay window and a file tail, all on the daemon that owns every
/// keystroke, and all destroyed by `make host-restart`. Now the tail outlives the restart and the
/// fold happens somewhere else (`docs/54`).
///
/// ## Spawn-or-adopt under the SAME rule as dropd and the panel backends
/// The pane id is `service:inspectord` — stable, not derived from this hostd (`docs/51` §1). A
/// restart adopts the running daemon, so the replay window a client is about to ask for is still
/// there; only a deliberate stop ends it. The port is re-learned from the child's own announce line,
/// replayed from offset 0 of superd's ring, so there is no state file and nothing to go stale.
///
/// ## Why the port is VERIFIED after an adopt
/// Same reason as dropd, and by the same code: ``AnnouncedPortService`` owns the spawn, the bounded
/// wait for the announce line and the respawn on a mismatch, because this file and
/// ``FileDropServiceManager`` were that lifecycle written out twice, blank lines and all. What is
/// left here is what makes it the INSPECTOR: the socket's name, its announce marker, its argv and
/// the env var that overrides its binary.
///
/// Hang-safety: this spawns a real process. Unit tests drive the injected seams and never reach the
/// production spawner.
public final class InspectorServiceManager: @unchecked Sendable {
    /// The service name, and with it the pane id `service:inspectord`.
    static let serviceName = "inspectord"

    /// Spawns (or adopts) the daemon and streams each of its log lines to the parse callback.
    typealias Spawner = HostServiceProcess.Spawner

    /// Locates `slopdesk-inspectord`, or `nil` on a machine that has none.
    typealias BinaryLocator = HostServiceProcess.BinaryLocator

    private let service: AnnouncedPortService

    /// The production manager: superd spawns the daemon, ``RustServicePaths`` finds it.
    public convenience init() {
        self.init(spawner: Self.defaultSpawner)
    }

    /// - Parameters:
    ///   - spawner: production spawns through superd; a test injects a fake handle.
    ///   - binaryLocator: production walks ``RustServicePaths``; a test names a path or `nil`.
    ///   - announceTimeout: how long ``start(port:transcriptPath:)`` waits for the child's announce
    ///     line before giving up on verifying the port. Bounded, because this runs on the daemon's
    ///     startup path.
    init(
        spawner: @escaping Spawner = InspectorServiceManager.defaultSpawner,
        binaryLocator: @escaping BinaryLocator = InspectorServiceManager.defaultBinaryLocator,
        announceTimeout: Duration = .seconds(3),
    ) {
        service = AnnouncedPortService(
            spawner: spawner,
            binaryLocator: binaryLocator,
            parseAnnouncedPort: { Self.parseAnnouncedPort(fromLogLine: $0) },
            parseAnnouncedVersion: { Self.parseAnnouncedVersion(fromLogLine: $0) },
            announceTimeout: announceTimeout,
        )
    }

    /// Brings the daemon up on `port`, adopting a survivor when there is one.
    ///
    /// Returns the port actually being served, or `nil` when there is no binary, superd is
    /// unreachable, or the child never announced. A `nil` is NOT fatal to the daemon: hostd logs it
    /// and serves the other paths, exactly as a failed inspector bind used to.
    @discardableResult
    public func start(port: UInt16, transcriptPath: String?) async -> UInt16? {
        await service.start(
            port: port,
            arguments: Self.launchArguments(port: port, transcriptPath: transcriptPath),
        )
    }

    /// Lets the daemon GO: hostd stops listening to its log, superd keeps it — and with it the
    /// replay window and the running tail. What a daemon SHUTDOWN calls.
    public func relinquish() {
        service.relinquish()
    }

    /// Ends the daemon for good. Only a deliberate stop may call it.
    public func shutdown() {
        service.shutdown()
    }

    /// The port the running daemon announced, once it has.
    public var servedPort: UInt16? { service.servedPort }

    /// The crate version of the inspectord actually running, off its announce line. `nil` when it
    /// has not announced yet, or announced without one.
    public var runningVersion: String? { service.announcedVersion }

    // MARK: - What makes it the inspector

    /// The child's argv. The transcript path is passed rather than read from the environment on the
    /// far side, for dropd's reason: superd's child inherits hostd's environment, and a service
    /// whose SUBJECT depended on that inheritance would silently change meaning the day someone
    /// adopted it from a differently-configured daemon. Without a path the daemon still binds and
    /// serves an empty replay window — the honest state of an inspector with nothing to inspect.
    static func launchArguments(port: UInt16, transcriptPath: String?) -> [String] {
        var arguments = ["--port", String(port)]
        if let transcriptPath, !transcriptPath.isEmpty {
            arguments.append(contentsOf: ["--transcript", transcriptPath])
        }
        return arguments
    }

    /// The port out of `inspectord: listening on 0.0.0.0:<port> (transcript …)`, or `nil`.
    ///
    /// A build that changes the marker fails `rust/slopdesk-invariants`, which compares this
    /// string against `server.rs`.
    static func parseAnnouncedPort(fromLogLine line: String) -> UInt16? {
        AnnouncedPort.directlyAfter(announceMarker, in: line)
    }

    /// The announce prefix, spelled identically in `rust/slopdesk-inspectord/src/server.rs`.
    static let announceMarker = "inspectord: listening on 0.0.0.0:"

    /// The crate version out of the same line's `(v<version>, transcript …)`, or `nil`.
    ///
    /// `nil` from an inspectord that predates the field — a survivor adopted across an upgrade is
    /// exactly the case, and it must read `unknown` rather than `current`.
    static func parseAnnouncedVersion(fromLogLine line: String) -> String? {
        AnnouncedVersion.directlyAfter(announceMarker, in: line)
    }

    /// The production ``Spawner`` — superd forks it, superd keeps it.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            service: InspectorServiceManager.serviceName,
            binary: binary,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            onLogLine: onLogLine,
        )
    }

    /// The production ``BinaryLocator``.
    static let defaultBinaryLocator: BinaryLocator = {
        RustServicePaths.locate(
            "slopdesk-inspectord",
            crate: "slopdesk-inspectord",
            overrideVariable: binaryEnvKey,
        )
    }

    /// Names the `slopdesk-inspectord` to run. The E2E harness points it at its own build.
    static let binaryEnvKey = "SLOPDESK_INSPECTORD_BIN"
}
