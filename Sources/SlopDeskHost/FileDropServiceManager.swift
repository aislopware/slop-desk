import Foundation
import SlopDeskSupervisor

/// PATH 4's daemon, held by superd: `slopdesk-dropd` on `terminalPort + 2`.
///
/// ## hostd is not in this byte path, and now not in the process either
/// A dropped file has always ridden its own TCP connection — never the terminal mux (a bulk body
/// sharing the PTY data channel stalls keystrokes) and never the lossy video path. What it did NOT
/// have was its own process: the listener lived in hostd, so a multi-GiB upload streamed through the
/// daemon that owns every keystroke, and `make host-restart` took the upload with it. Now the client
/// dials a separate binary directly and hostd never sees a body byte.
///
/// ## Spawn-or-adopt under the SAME rule as the panel backends
/// The pane id is `service:dropd` — stable, not derived from this hostd (`docs/51` §1). A restart
/// adopts the running daemon, so an upload in flight across a host rebuild simply continues; only a
/// deliberate stop ends it. The port is re-learned from the child's own announce line, replayed from
/// offset 0 of superd's ring, so there is no state file and nothing to go stale.
///
/// ## Why the port is VERIFIED after an adopt
/// The pane id is stable but the port is not: a hostd started on a different `--port` wants a
/// different upload port, and the surviving dropd is on the old one. That rule, the spawn and the
/// bounded wait for the announce line all live in ``AnnouncedPortService`` — this file and
/// ``InspectorServiceManager`` were the same lifecycle written out twice. What is left here is what
/// makes it DROPD: the socket's name, its announce marker, its argv and the env var that overrides
/// its binary.
///
/// Hang-safety: this spawns a real process. Unit tests drive the injected seams and never reach the
/// production spawner.
public final class FileDropServiceManager: @unchecked Sendable {
    /// The service name, and with it the pane id `service:dropd`.
    static let serviceName = "dropd"

    /// Spawns (or adopts) the daemon and streams each of its log lines to the parse callback.
    typealias Spawner = HostServiceProcess.Spawner

    /// Locates `slopdesk-dropd`, or `nil` on a machine that has none.
    typealias BinaryLocator = HostServiceProcess.BinaryLocator

    private let service: AnnouncedPortService

    /// The production manager: superd spawns the daemon, ``RustServicePaths`` finds it.
    public convenience init() {
        self.init(spawner: Self.defaultSpawner)
    }

    /// - Parameters:
    ///   - spawner: production spawns through superd; a test injects a fake handle.
    ///   - binaryLocator: production walks ``RustServicePaths``; a test names a path or `nil`.
    ///   - announceTimeout: how long ``start(port:dropDirectory:)`` waits for the child's announce
    ///     line before giving up on verifying the port. Bounded, because this runs on the daemon's
    ///     startup path.
    init(
        spawner: @escaping Spawner = FileDropServiceManager.defaultSpawner,
        binaryLocator: @escaping BinaryLocator = FileDropServiceManager.defaultBinaryLocator,
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
    /// and serves the other three paths, exactly as a failed bind used to.
    @discardableResult
    public func start(port: UInt16, dropDirectory: URL) async -> UInt16? {
        await service.start(
            port: port,
            arguments: Self.launchArguments(port: port, dropDirectory: dropDirectory),
        )
    }

    /// Lets the daemon GO: hostd stops listening to its log, superd keeps it — and with it every
    /// upload in flight. What a daemon SHUTDOWN calls.
    public func relinquish() {
        service.relinquish()
    }

    /// Ends the daemon for good. Only a deliberate stop may call it.
    public func shutdown() {
        service.shutdown()
    }

    /// The port the running daemon announced, once it has.
    public var servedPort: UInt16? { service.servedPort }

    /// The crate version of the dropd actually running, off its announce line. `nil` when it has
    /// not announced yet, or announced without one.
    public var runningVersion: String? { service.announcedVersion }

    // MARK: - What makes it dropd

    /// The child's argv. The drop directory is passed rather than read from the environment on the
    /// far side: superd's child inherits hostd's environment, and a service whose destination
    /// depended on that inheritance would silently change meaning the day someone adopted it from a
    /// differently-configured daemon.
    static func launchArguments(port: UInt16, dropDirectory: URL) -> [String] {
        ["--port", String(port), "--drop-dir", dropDirectory.path]
    }

    /// The port out of `dropd: listening on 0.0.0.0:<port> (drop dir …)`, or `nil`.
    ///
    /// A build that changes the marker fails `scripts/check-supervisor.sh`, which compares this
    /// string against `server.rs`.
    static func parseAnnouncedPort(fromLogLine line: String) -> UInt16? {
        AnnouncedPort.directlyAfter(announceMarker, in: line)
    }

    /// The announce prefix, spelled identically in `rust/slopdesk-dropd/src/server.rs`.
    static let announceMarker = "dropd: listening on 0.0.0.0:"

    /// The crate version out of the same line's `(v<version>, drop dir …)`, or `nil`.
    ///
    /// `nil` from a dropd that predates the field — a survivor adopted across an upgrade is exactly
    /// the case, and it must read `unknown` rather than `current`.
    static func parseAnnouncedVersion(fromLogLine line: String) -> String? {
        AnnouncedVersion.directlyAfter(announceMarker, in: line)
    }

    /// The production ``Spawner`` — superd forks it, superd keeps it.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            service: FileDropServiceManager.serviceName,
            binary: binary,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            onLogLine: onLogLine,
        )
    }

    /// The production ``BinaryLocator``.
    static let defaultBinaryLocator: BinaryLocator = {
        RustServicePaths.locate(
            "slopdesk-dropd",
            crate: "slopdesk-dropd",
            overrideVariable: binaryEnvKey,
        )
    }

    /// Names the `slopdesk-dropd` to run. The E2E harness points it at its own build.
    static let binaryEnvKey = "SLOPDESK_DROPD_BIN"
}
