import Foundation

// AislopdeskCLICore — the PURE, testable core of the user-facing `aislopdesk` CLI.
//
// This is the otty-clone superset front-end (E20): one binary that maps otty's subcommand
// surface onto the existing aislopdesk control plane. `CLIArgs` is the global-flag parser; it is
// a pure value transform (no I/O, no `exit`) so the whole arg surface is exhaustively
// unit-testable without ever opening a socket or launching the GUI (hang-safety rule).
//
// Mirrors the split already used by `AislopdeskCtlCore` (`GlobalArgs`/`parseGlobal`): the thin
// `Sources/aislopdesk/main.swift` shell imports this, adds the socket I/O + GUI launch + the
// per-subcommand dispatch, and is the only place that calls `exit`.

// MARK: - Output format

/// Output format for the list/inspect subcommands. `--json` (or `--format json`) selects `.json`;
/// the default text path renders tables (honoring `--no-headers`).
public enum CLIOutputFormat: String, Sendable, Equatable {
    case text
    case json
}

// MARK: - Parsed invocation

/// A fully-parsed `aislopdesk` invocation: the resolved subcommand, its residual arguments, and
/// every recognised global flag. PURE value type — ``CLIArgs/parse(_:)`` performs no I/O and never
/// exits, so every flag combination is unit-testable.
public struct CLIInvocation: Sendable, Equatable {
    /// The first non-flag token = the subcommand name. Empty ⇒ no subcommand (bare invocation,
    /// which launches the GUI like bare `xterm`/`alacritty`/`ghostty`).
    public var subcommand: String
    /// Tokens after the subcommand that are NOT recognised global flags — the subcommand-specific
    /// arguments/flags, passed through verbatim for the per-subcommand parser.
    public var rest: [String]
    /// Output format (`--json` / `--format json` ⇒ `.json`).
    public var format: CLIOutputFormat
    /// `--no-headers`: strip table header rows from text output (for piping).
    public var noHeaders: Bool
    /// `--socket PATH` override for the client control socket (`nil` ⇒ auto-detect).
    public var socketPath: String?
    /// `--config-file PATH` override (`nil` ⇒ auto-detect).
    public var configFile: String?
    /// `--timeout <ms>`: how long the CLI waits for an IPC response from the running app.
    public var timeoutMs: Int
    /// `-y` / `--yes`: skip destructive-action confirmation prompts.
    public var assumeYes: Bool
    /// `-h` / `--help`: show usage instead of dispatching.
    public var wantsHelp: Bool
    /// True when this invocation should launch the client GUI: a bare invocation (no subcommand,
    /// no `--help`). (An aislopdesk pane is a REMOTE PTY with no local shell to exec into, so otty's
    /// `-e <cmd>` has no faithful mapping here — it is not a flag; passing `-e` is an unknown-flag error.)
    public var launchGUI: Bool

    public init(
        subcommand: String = "",
        rest: [String] = [],
        format: CLIOutputFormat = .text,
        noHeaders: Bool = false,
        socketPath: String? = nil,
        configFile: String? = nil,
        timeoutMs: Int = CLIArgs.defaultTimeoutMs,
        assumeYes: Bool = false,
        wantsHelp: Bool = false,
        launchGUI: Bool = false,
    ) {
        self.subcommand = subcommand
        self.rest = rest
        self.format = format
        self.noHeaders = noHeaders
        self.socketPath = socketPath
        self.configFile = configFile
        self.timeoutMs = timeoutMs
        self.assumeYes = assumeYes
        self.wantsHelp = wantsHelp
        self.launchGUI = launchGUI
    }
}

// MARK: - Parse errors

/// Errors returned by ``CLIArgs/parse(_:)`` — returned (never thrown to `exit`) so unit tests can
/// inspect them. `main.swift` maps these to a `die()` + non-zero exit.
public enum CLIParseError: Error, Equatable, Sendable {
    case unknownFlag(String)
    case missingValue(String)
    case invalidValue(flag: String, value: String)
}

// MARK: - Parser

public enum CLIArgs {
    /// Default IPC wait (matches otty's `--timeout` default of 3000 ms).
    public static let defaultTimeoutMs = 3000

    /// Parses the global flags + subcommand from `args` (including `args[0]`/program name, which is
    /// skipped). Pure — no I/O, no exit.
    ///
    /// Rules:
    /// - The first non-flag token is the subcommand; subsequent non-flag tokens go to `rest`.
    /// - Recognised global flags are consumed wherever they appear (before OR after the subcommand).
    /// - An UNRECOGNISED flag BEFORE the subcommand is an error; AFTER the subcommand it is a
    ///   subcommand-specific flag and passes through to `rest`. (There is no `-e`: a pane is a remote
    ///   PTY, so `-e <cmd>` has no faithful local-exec mapping — it falls through as an unknown flag.)
    /// - A bare `--` (only valid after a subcommand) ends option parsing: it and everything after it
    ///   pass through to `rest` verbatim (POSIX end-of-options; protects literal `send-keys` text).
    public static func parse(_ args: [String]) -> Result<CLIInvocation, CLIParseError> {
        var inv = CLIInvocation()
        var endOfOptions = false
        var idx = 1 // skip argv[0]
        while idx < args.count {
            let arg = args[idx]

            // After a bare `--`, everything is a literal operand.
            if endOfOptions {
                inv.rest.append(arg)
                idx += 1
                continue
            }

            switch arg {
            case "--json":
                inv.format = .json
            case "--format":
                guard idx + 1 < args.count else { return .failure(.missingValue("--format")) }
                idx += 1
                switch args[idx] {
                case "json": inv.format = .json
                case "text",
                     "plain": inv.format = .text
                default: return .failure(.invalidValue(flag: "--format", value: args[idx]))
                }
            case "--no-headers":
                inv.noHeaders = true
            case "--socket":
                guard idx + 1 < args.count else { return .failure(.missingValue("--socket")) }
                idx += 1
                inv.socketPath = args[idx]
            case "--config-file":
                guard idx + 1 < args.count else { return .failure(.missingValue("--config-file")) }
                idx += 1
                inv.configFile = args[idx]
            case "--timeout":
                guard idx + 1 < args.count else { return .failure(.missingValue("--timeout")) }
                idx += 1
                guard let ms = Int(args[idx]), ms > 0 else {
                    return .failure(.invalidValue(flag: "--timeout", value: args[idx]))
                }
                inv.timeoutMs = ms
            case "-y",
                 "--yes":
                inv.assumeYes = true
            case "-h",
                 "--help":
                inv.wantsHelp = true
            case "--":
                // End-of-options is only meaningful once a subcommand is known (it separates the
                // subcommand's own flags from its literal operands).
                guard !inv.subcommand.isEmpty else { return .failure(.unknownFlag("--")) }
                inv.rest.append(arg)
                endOfOptions = true
            default:
                if arg.hasPrefix("-") {
                    // Unrecognised flag: hard error before the subcommand, pass-through after it.
                    guard !inv.subcommand.isEmpty else { return .failure(.unknownFlag(arg)) }
                    inv.rest.append(arg)
                } else if inv.subcommand.isEmpty {
                    inv.subcommand = arg
                } else {
                    inv.rest.append(arg)
                }
            }
            idx += 1
        }

        // A bare invocation (no subcommand, not `--help`) routes to the GUI, like bare `xterm`/`ghostty`.
        inv.launchGUI = inv.subcommand.isEmpty && !inv.wantsHelp
        return .success(inv)
    }
}
