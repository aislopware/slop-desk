import Foundation

/// Parsed command-line configuration for the `aislopdesk-hostd` daemon.
///
/// This lives in the library (not in the executable's `main.swift`) so the arg-parse →
/// ``HostServer/LaunchMode`` mapping is unit-testable without spawning a process: a test
/// parses an argv slice and asserts on the resulting `launchMode` / `port` / `shell`.
///
/// ## Flags
/// - `--port N` / `-p N`: TCP port to bind (default `7420`; `0` = OS-assigned).
/// - `--shell PATH` / `-s PATH`: shell to spawn (default: the user's login shell).
/// - `--claude`: launch `claude` under the curated ``ClaudeCodeProfile`` instead of a
///   plain login shell — selects ``HostServer/LaunchMode/claudeCode(_:)``.
/// - `--xterm256`: with `--claude`, advertise `TERM=xterm-256color`
///   (``ClaudeCodeProfile/Term/xterm256``, the #54700 fallback) instead of the default
///   `xterm-ghostty`. Ignored without `--claude`.
/// - `--inspector`: enable the read-only structured inspector server on `port + 1`
///   (NWConnection #2). **Auto-enabled by `--claude`** (the inspector observes a `claude`
///   session) but can be requested explicitly; harmless without `--claude` (the replay
///   log just stays empty until PIECE C feeds it).
/// - `--transcript PATH`: inject the Claude Code JSONL transcript path the inspector
///   tails (PIECE C's live discovery is deferred; until then the path is supplied here).
///   Implies `--inspector`.
/// - `--help` / `-h`: returns `nil` (caller prints usage + exits non-zero).
public struct HostdArguments: Sendable, Equatable {
    public let port: UInt16
    public let shell: String?
    public let launchMode: HostServer.LaunchMode
    /// Whether to start the inspector server (auto-true under `--claude` or
    /// `--transcript`). Bound to `port + 1`.
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
        "usage: \(programName) [--port N] [--shell /path/to/shell] [--claude [--xterm256]] [--inspector] [--transcript PATH]"
    }

    /// Parses a full argv (including `argv[0]`, which is dropped). Returns `nil` for
    /// `--help`/`-h`, a missing flag value, or an unknown flag — the caller then prints
    /// ``usage(programName:)`` and exits non-zero.
    public static func parse(_ args: [String]) -> Self? {
        var port: UInt16 = 7420
        var shell: String?
        var claude = false
        var xterm256 = false
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
            case "--claude":
                claude = true
            case "--xterm256":
                xterm256 = true
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

        let launchMode: HostServer.LaunchMode
        if claude {
            let term: ClaudeCodeProfile.Term = xterm256 ? .xterm256 : .ghostty
            launchMode = .claudeCode(ClaudeCodeProfile(term: term))
        } else {
            // `--xterm256` without `--claude` is a no-op: the plain-shell TERM is fixed
            // to the libghostty default here (the daemon does not expose a TERM override
            // for the plain shell — that would be a separate flag if ever needed).
            launchMode = .shell
        }

        // The inspector is enabled explicitly, OR implied by `--claude` (it observes a
        // `claude` session), OR implied by `--transcript` (a path to tail).
        let inspectorEnabled = inspector || claude || (transcript != nil)

        return Self(
            port: port,
            shell: shell,
            launchMode: launchMode,
            inspectorEnabled: inspectorEnabled,
            transcriptPath: transcript,
        )
    }
}
