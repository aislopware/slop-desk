import Foundation

/// Parsed command-line configuration for the `slopdesk-hostd` daemon.
///
/// This lives in the library (not in the executable's `main.swift`) so the arg-parse →
/// ``HostServer/LaunchMode`` mapping is unit-testable without spawning a process: a test
/// parses an argv slice and asserts on the resulting `launchMode` / `port` / `shell`.
///
/// ## Flags
/// - `--port N` / `-p N`: TCP port to bind (default `7420`; `0` = OS-assigned).
/// - `--shell PATH` / `-s PATH`: shell to spawn (default: the user's login shell).
/// - `--inspector`: enable the read-only structured inspector server on `port + 1`
///   (NWConnection #2). The dynamic, client-driven inspector gating (only stand the
///   second channel up once a `claude` session is detected) lives client-side now (W11
///   Decision #6); the daemon still honors this explicit opt-in. Harmless on its own —
///   the replay log stays empty until a hook/transcript feeds it.
/// - `--transcript PATH`: inject the Claude Code JSONL transcript path the inspector
///   tails (PIECE C's live discovery is deferred; until then the path is supplied here).
///   Implies `--inspector`.
/// - `--help` / `-h`: returns `nil` (caller prints usage + exits non-zero).
///
/// The curated `claude` launch (formerly `--claude [--xterm256]`) is RETIRED as a daemon
/// mode (W11 Decision #9): a Claude session is now just a `.terminal` pane that runs
/// `claude`, auto-detected by the host process-watch + hook listener and offered to the
/// user as a client-side launch preset. New channels always spawn a plain login shell.
public struct HostdArguments: Sendable, Equatable {
    public let port: UInt16
    public let shell: String?
    public let launchMode: HostServer.LaunchMode
    /// Whether to start the inspector server (auto-true under `--transcript`, else explicit
    /// `--inspector`). Bound to `port + 1`.
    public let inspectorEnabled: Bool
    /// Injected transcript path for the inspector's (deferred) live tailer, if supplied.
    public let transcriptPath: String?

    public init(
        port: UInt16,
        shell: String?,
        launchMode: HostServer.LaunchMode,
        inspectorEnabled: Bool = false,
        transcriptPath: String? = nil,
    ) {
        self.port = port
        self.shell = shell
        self.launchMode = launchMode
        self.inspectorEnabled = inspectorEnabled
        self.transcriptPath = transcriptPath
    }

    /// The usage string printed on `--help` or a parse error.
    public static func usage(programName: String) -> String {
        "usage: \(programName) [--port N] [--shell /path/to/shell] [--inspector] [--transcript PATH]"
    }

    /// Parses a full argv (including `argv[0]`, which is dropped). Returns `nil` for
    /// `--help`/`-h`, a missing flag value, or an unknown flag — the caller then prints
    /// ``usage(programName:)`` and exits non-zero.
    public static func parse(_ args: [String]) -> Self? {
        var port: UInt16 = 7420
        var shell: String?
        var inspector = false
        var transcript: String?

        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--port",
                 "-p":
                guard let value = iterator.next(), let p = UInt16(value) else { return nil }
                port = p
            case "--shell",
                 "-s":
                guard let value = iterator.next() else { return nil }
                shell = value
            case "--inspector":
                inspector = true
            case "--transcript":
                guard let value = iterator.next() else { return nil }
                transcript = value
            case "--help",
                 "-h":
                return nil
            default:
                return nil
            }
        }

        // New channels always spawn a plain login shell. The curated `claude` launch is no
        // longer a daemon mode (W11 Decision #9) — the plain-shell TERM is fixed to the
        // libghostty default (resolved against the host terminfo DB at spawn time).
        let launchMode: HostServer.LaunchMode = .shell

        // The inspector is enabled explicitly, OR implied by `--transcript` (a path to tail).
        let inspectorEnabled = inspector || (transcript != nil)

        return Self(
            port: port,
            shell: shell,
            launchMode: launchMode,
            inspectorEnabled: inspectorEnabled,
            transcriptPath: transcript,
        )
    }
}
