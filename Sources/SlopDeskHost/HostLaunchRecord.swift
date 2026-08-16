import Foundation
import SlopDeskVideoProtocol

/// What a running `slopdesk-hostd` publishes about how it was started, so it can be restarted
/// **identically** without anyone having to remember.
///
/// ## Why this exists
/// `docs/51` made a hostd restart cheap: superd holds the panes, the child-facing sockets and the
/// panel backends, so stopping hostd costs a reconnect rather than the afternoon's work. What was
/// left was the ritual around it — find the process, hope `pkill` matched the right thing (and only
/// the right thing; `CLAUDE.md` lists "`pkill` can leave a host on the port" as a trap), wait long
/// enough, then retype the flags. A restart that is *technically* free but *manually* fiddly still
/// gets postponed, which is the behaviour this whole subsystem set out to change.
///
/// So hostd states its own launch, and `scripts/restart-hostd.sh` reads it. Nothing has to parse
/// `ps` output, guess a port, or infer flags.
///
/// ## Why the process writes it rather than the script
/// Two of the fields cannot be known from outside. ``port`` is the **bound** port, which under
/// `--port 0` is an OS-chosen ephemeral one that differs from what was asked for; and
/// ``environment`` is what this process actually resolved, which the shell that launched it may no
/// longer have. Anything reconstructed by a script would be a second, worse answer.
///
/// ## Not a pid path
/// The pid is *content* here, re-read on every use and never baked into a name a child remembers —
/// the distinction `docs/51` §1 turns on. The file's own name is fixed, one per container.
public struct HostLaunchRecord: Codable, Equatable, Sendable {
    /// The running daemon's pid. Content, deliberately — see the type's note.
    public var pid: Int32
    /// The port the listener actually **bound**, which `--port 0` makes different from the request.
    public var port: UInt16
    /// Absolute path to the binary that is running. A `.build/debug` and a `.build/release` hostd
    /// are different daemons and a restart must not silently swap one for the other.
    public var binary: String
    /// `argv` after `argv[0]`.
    public var arguments: [String]
    /// The daemon's cwd, because a relative `--transcript` resolves against it.
    public var workingDirectory: String
    /// The `SLOPDESK_*` variables this process resolved, and only those.
    ///
    /// Everything else is the launching shell's business and would be noise at best. The prefix
    /// filter is also what keeps this file safe to read: SlopDesk has **no app-layer credentials**
    /// (`CLAUDE.md` — security is the WireGuard mesh), so a `SLOPDESK_*` value is configuration.
    public var environment: [String: String]
    /// ``HostEnvironment/buildVersion`` at launch, so a restart can report what changed.
    public var version: String
    /// ISO-8601, UTC. A string rather than a `Date` so the file reads the same to a person and to
    /// `jq`, and so no decoding strategy has to be agreed with a shell script.
    public var startedAt: String

    public init(
        pid: Int32, port: UInt16, binary: String, arguments: [String], workingDirectory: String,
        environment: [String: String], version: String, startedAt: String,
    ) {
        self.pid = pid
        self.port = port
        self.binary = binary
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.version = version
        self.startedAt = startedAt
    }

    /// The file, `<Application Support>/SlopDesk/hostd-launch.json`.
    ///
    /// One per container, so `SLOPDESK_APP_SUPPORT_DIR` gives a test (or a second host on the same
    /// machine) its own without a second name having to be invented.
    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        SlopDeskAppSupport.directory(environment: environment, fileManager: fileManager)?
            .appendingPathComponent("hostd-launch.json", isDirectory: false)
    }

    /// The `SLOPDESK_*` subset of `environment`, in the shape ``environment`` wants.
    public static func configVariables(in environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("SLOPDESK_") }
    }

    /// Describes the CURRENT process, given the port it just bound.
    public static func current(
        boundPort: UInt16,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        version: String = HostEnvironment.buildVersion,
        now: Date = Date(),
    ) -> Self {
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        return Self(
            pid: ProcessInfo.processInfo.processIdentifier,
            port: boundPort,
            binary: runningExecutablePath(arguments: arguments, workingDirectory: workingDirectory),
            arguments: Array(arguments.dropFirst()),
            workingDirectory: workingDirectory,
            environment: configVariables(in: environment),
            version: version,
            startedAt: stamp.string(from: now),
        )
    }

    /// The absolute, symlink-free path of the binary this process is running.
    ///
    /// **Not `argv[0]`.** That is whatever the caller typed — `.build/release/slopdesk-hostd` is the
    /// usual spelling, and a bare name found on `PATH` is another — and a restart from a different
    /// directory would resolve it somewhere else or not at all. `_NSGetExecutablePath` is the kernel's
    /// answer to the same question and cannot be wrong.
    ///
    /// Symlinks are resolved because the identity check on the other side needs an exact match:
    /// `.build/release` is a symlink to `.build/arm64-apple-macosx/release`, and `lsof -d txt` — the
    /// only way to ask "what is pid N actually running" — reports the physical path. Two spellings of
    /// one file would read as two different daemons.
    ///
    /// `argv[0]` remains the fallback, for a platform (or a test) where the dyld call declines.
    static func runningExecutablePath(
        arguments: [String] = CommandLine.arguments,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
    ) -> String {
        var capacity = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(capacity) + 1)
        if _NSGetExecutablePath(&buffer, &capacity) == 0 {
            let reported = String(cString: buffer)
            if !reported.isEmpty {
                return URL(fileURLWithPath: reported).resolvingSymlinksInPath().path
            }
        }
        let launched = arguments.first ?? "slopdesk-hostd"
        let absolute = launched.hasPrefix("/")
            ? URL(fileURLWithPath: launched)
            : URL(fileURLWithPath: workingDirectory).appendingPathComponent(launched)
        return absolute.resolvingSymlinksInPath().path
    }

    /// Writes the record, creating the container if it is not there yet.
    ///
    /// Best-effort by design: a host that cannot write this file is a host that still serves every
    /// client. Losing it costs one convenience — the restart script falls back to asking.
    @discardableResult
    public func write(
        to url: URL? = Self.url(),
        fileManager: FileManager = .default,
    ) -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        // Sorted and pretty because a person reads this to answer "what flags is my host running?".
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        // Atomic: the restart script may read this at any moment, and half a JSON object is worse
        // than none — it reads as a corrupt record rather than as an absent one.
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Reads the record, or `nil` when it is absent or unreadable.
    public static func read(
        from url: URL? = Self.url(),
    ) -> Self? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Deletes the record. Called on the orderly shutdown, so an absent file means "no hostd", and
    /// a present one whose pid is gone means "hostd died badly" — two states worth telling apart.
    public static func remove(
        at url: URL? = Self.url(),
        fileManager: FileManager = .default,
    ) {
        guard let url else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Whether the recorded pid is still a live process this user may signal.
    ///
    /// `kill(pid, 0)` — the standard existence probe. `EPERM` counts as alive: the process is there,
    /// it just is not ours, and reporting it dead would have the restart script launch a second
    /// daemon onto a bound port.
    ///
    /// It does NOT prove the pid is still *hostd* — pids are recycled. The script confirms that
    /// separately by matching the executable, which is why ``binary`` is recorded absolute.
    public var isAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
