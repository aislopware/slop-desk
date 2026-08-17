import Foundation
import SlopDeskProtocol
import SlopDeskSupervisor

/// The Android panel's daemon, held by superd: `slopdesk-androidd` on a port it announces.
///
/// ## hostd was never on this wire, and now it is not the process either
/// The client has always dialled the bridge port DIRECTLY — it learns it from
/// ``MetadataVerb/ensureAndroidBridge`` (= 22) and opens its own connection per mirror, per logcat,
/// per list poll. What it did not have was its own process: the listener lived inside hostd, so an
/// H.264 stream at a few megabits was pumped by the daemon that owns every keystroke, on threads
/// competing with the terminal wire — and `make host-restart` took every live mirror down with it.
/// Now the same port is served by a separate binary and hostd never sees a frame.
///
/// Nothing about the wire changed. That is the point: the panel's client code, the stream
/// reassembler and the control encoder are all untouched, because the bridge they talk to answers
/// exactly as it did.
///
/// ## Spawn-or-adopt under the SAME rule as the other backends
/// The pane id is `service:androidd` — stable, not derived from this hostd (`docs/51` §1). A restart
/// adopts the running daemon, so a mirror open across a host rebuild simply continues; only a
/// deliberate stop ends it. The port is re-learned from the child's own announce line, replayed from
/// offset 0 of superd's ring, so there is no state file and nothing to go stale.
///
/// ## Why the port is NOT verified against a wanted one
/// Unlike ``FileDropServiceManager``, whose port is `terminalPort + 2` and therefore an opinion this
/// hostd holds, the bridge port is ephemeral: the daemon is spawned with `--port 0` and announces
/// what the OS gave it. A hostd that adopts a survivor simply advertises the port that survivor is
/// on, which is by construction a port something is listening on. One host has one `adb` server and
/// one set of AVDs, so there is nothing per-hostd to disagree about.
///
/// ## `ensure` never waits
/// Same contract as ``SimulatorServerManager``, for the same reason: it runs on a metadata queue
/// answering an RPC whose client-side timeout is 5 s, and the daemon's first act is to locate an SDK.
/// It reports `starting` until the announce line lands and a loopback probe succeeds, and the client
/// polls — which it already does, because the simulator panel taught it to.
///
/// **`unavailable` means there is no `slopdesk-androidd` on this machine.** A missing `adb`, a
/// missing `emulator` binary or a missing `scrcpy-server` jar deliberately does NOT land here: the
/// daemon reports those per-operation, where the panel can name the missing piece against the action
/// that wanted it. (A host with no `adb` at all exits at startup, which reads here as a child that
/// stopped running, and the next `ensure` retries — cheap, and self-healing the moment an SDK
/// appears.)
///
/// **No auth token.** The daemon binds `0.0.0.0` with no credential: security is the WireGuard mesh
/// (`docs/DECISIONS.md`), identical to every other port this project opens.
///
/// Thread-safe (`NSLock`): `ensure` runs on per-session metadata queues, so two panes race.
final class AndroidServiceManager: @unchecked Sendable {
    /// The service name, and with it the pane id `service:androidd`.
    static let serviceName = "androidd"

    /// Spawns (or adopts) the daemon and streams each of its log lines to the parse callback.
    typealias Spawner = HostServiceProcess.Spawner

    /// Locates `slopdesk-androidd`, or `nil` on a machine that has none.
    typealias BinaryLocator = HostServiceProcess.BinaryLocator

    /// Whether a TCP connect to `127.0.0.1:port` succeeds (bounded, never hangs).
    typealias ReadinessProbe = HostServiceProcess.ReadinessProbe

    /// The spawn-learn-probe-latch lifecycle, shared with the code and simulator panels. What is
    /// left in this file is what makes it the BRIDGE.
    private let service: ProbedPortService
    private let locateBinary: BinaryLocator
    private let spawn: Spawner

    init(
        binaryLocator: @escaping BinaryLocator = AndroidServiceManager.defaultBinaryLocator,
        spawner: @escaping Spawner = AndroidServiceManager.defaultSpawner,
        readinessProbe: @escaping ReadinessProbe = AndroidServiceManager.defaultReadinessProbe,
        probeInterval: Duration = .milliseconds(500),
    ) {
        locateBinary = binaryLocator
        spawn = spawner
        service = ProbedPortService(readinessProbe: readinessProbe, probeInterval: probeInterval)
    }

    /// Ensures the bridge and reports where it stands RIGHT NOW (never waits).
    ///
    /// A daemon that exited (no `adb`, a crash, a kill) is dropped and respawned by the round that
    /// finds it gone — which is also how a host that gains an SDK starts working without a restart.
    func ensure() -> MetadataCodec.ServiceEndpoint {
        service.ensure { generation in
            guard let binary = locateBinary() else { return .notYet(.unavailable) }
            let onLine = service.portSink(
                generation: generation,
                parseVersion: { Self.parseAnnouncedVersion(fromLogLine: $0) },
            ) {
                Self.parseAnnouncedPort(fromLogLine: $0)
            }
            // A spawn that THREW is transient here, unlike the panel backends: superd unreachable
            // or a thread limit says nothing about whether this host has a bridge. `unavailable`
            // would render the panel's install hint over a daemon that is merely late.
            guard let handle = try? spawn(binary, Self.launchArguments(), onLine) else {
                return .notYet(.starting)
            }
            return .spawned(handle)
        }
    }

    /// Lets the daemon GO: hostd stops listening to its log, superd keeps it — and with it every
    /// mirror in flight. What a daemon SHUTDOWN calls.
    func relinquish() {
        service.forget()?.relinquish()
    }

    /// Ends the daemon for good. Only a deliberate stop may call it.
    ///
    /// Booted DEVICES are deliberately left running: an emulator the user started is their machine's
    /// state and outlives any one hostd run.
    func shutdown() {
        service.forget()?.terminate()
    }

    /// The port the running daemon announced, once it has.
    var servedPort: UInt16? { service.servedPort }

    /// The crate version of the androidd actually running, off its announce line. `nil` when it has
    /// not announced yet, or announced without one.
    var runningVersion: String? { service.announcedVersion }

    // MARK: - What makes it the bridge

    /// The daemon's argv.
    ///
    /// The two vendored paths are passed rather than left to the far side to find: ``VendoredTools``
    /// already walks up from the running binary for `ThirdParty/tools/tools.lock`, and it serves the
    /// code and simulator panels too. Re-walking it in Rust would be the same capability in a second
    /// language, which the one-implementation rule forbids. It also means a daemon adopted from a
    /// differently-configured hostd cannot silently resolve to different tools.
    static func launchArguments(
        vendoredBinDirectory: String? = VendoredTools.binDirectory,
        scrcpyServerJar: String? = VendoredTools.scrcpyServerJar,
    ) -> [String] {
        var arguments = ["--port", "0"]
        if let vendoredBinDirectory { arguments += ["--vendored-bin", vendoredBinDirectory] }
        if let scrcpyServerJar { arguments += ["--vendored-jar", scrcpyServerJar] }
        return arguments
    }

    /// The port out of `androidd: listening on 0.0.0.0:<port> (adb …)`, or `nil`.
    ///
    /// A build that changes the marker fails `scripts/check-supervisor.sh`, which compares this
    /// string against `server.rs`.
    static func parseAnnouncedPort(fromLogLine line: String) -> UInt16? {
        AnnouncedPort.directlyAfter(announceMarker, in: line)
    }

    /// The announce prefix, spelled identically in `rust/slopdesk-androidd/src/server.rs`.
    static let announceMarker = "androidd: listening on 0.0.0.0:"

    /// The crate version out of the same line's `(v<version>, adb …)`, or `nil`.
    ///
    /// `nil` from an androidd that predates the field — a survivor adopted across an upgrade is
    /// exactly the case, and it must read `unknown` rather than `current`.
    static func parseAnnouncedVersion(fromLogLine line: String) -> String? {
        AnnouncedVersion.directlyAfter(announceMarker, in: line)
    }

    // MARK: - Production seams

    /// The production ``Spawner`` — superd forks it, superd keeps it.
    ///
    /// The daemon inherits hostd's environment verbatim: `ANDROID_HOME`, `PATH` and the
    /// `SLOPDESK_ANDROID_*` overrides all reach its locator unchanged, which is what lets an operator
    /// point the panel at a specific `adb` without this file knowing the variable's name.
    static let defaultSpawner: Spawner = { binary, arguments, onLogLine in
        try HostServiceProcess.spawn(
            service: AndroidServiceManager.serviceName,
            binary: binary,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            onLogLine: onLogLine,
        )
    }

    /// The production ``BinaryLocator``.
    static let defaultBinaryLocator: BinaryLocator = {
        RustServicePaths.locate(
            "slopdesk-androidd",
            crate: "slopdesk-androidd",
            overrideVariable: binaryEnvKey,
        )
    }

    /// Names the `slopdesk-androidd` to run. The hardware gate points it at its own build.
    static let binaryEnvKey = "SLOPDESK_ANDROIDD_BIN"

    /// The production ``ReadinessProbe``.
    static let defaultReadinessProbe: ReadinessProbe = { port in
        HostServiceProcess.isListening(onLoopbackPort: port)
    }
}
