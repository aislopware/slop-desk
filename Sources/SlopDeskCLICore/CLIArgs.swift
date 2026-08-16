import CSlopDeskFFI
import Foundation
import SlopDeskArena

// SlopDeskCLICore — the Swift FACE of the `slopdesk` CLI's pure core, which is `rust/slopdesk-cli`.
//
// This is the CLI front-end (E20): one binary exposing a subcommand surface onto the existing
// slopdesk control plane. The flag grammar, the completion scripts, the config-file rules and the
// output tables all live in the crate; this module marshals them across the door and nothing else.
// The thin `Sources/slopdesk/main.swift` shell adds the socket I/O + GUI launch + the
// per-subcommand dispatch, and is the only place that calls `exit`.

// MARK: - Output format

/// Output format for the list/inspect subcommands. `--json` (or `--format json`) selects `.json`;
/// the default text path renders tables (honoring `--no-headers`).
public enum CLIOutputFormat: String, Sendable, Equatable {
    case text
    case json

    /// The code this format crosses as.
    var code: UInt32 { self == .json ? SLOPDESK_CLI_JSON : SLOPDESK_CLI_TEXT }

    /// The format a code names.
    static func of(_ code: UInt32) -> Self { code == SLOPDESK_CLI_JSON ? .json : .text }
}

// MARK: - Parsed invocation

/// A fully-parsed `slopdesk` invocation: the resolved subcommand, its residual arguments, and
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
    /// True when this invocation should launch the client GUI: a bare invocation (no subcommand, no
    /// `--help`) OR an `-e <cmd>` invocation (see ``execCommand``). xterm/alacritty/ghostty all launch the
    /// GUI for both, so slopdesk matches.
    public var launchGUI: Bool
    /// The command captured after `-e <cmd> [args…]` (xterm-compatible terminal-emulator flag), or `nil`.
    /// `-e` does NOT local-exec — an slopdesk pane is a remote PTY — so the command is forwarded to the
    /// first (focused) pane of the freshly-launched GUI. Per xterm semantics `-e` is terminal: every token
    /// after it (even leading-dash ones) is part of the command, captured verbatim.
    public var execCommand: [String]?

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
        execCommand: [String]? = nil,
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
        self.execCommand = execCommand
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
    /// Default IPC wait (`--timeout` default of 3000 ms), from the door so neither language writes
    /// the number down twice.
    public static let defaultTimeoutMs = Int(slopdesk_cli_default_timeout_ms())

    /// Parses the global flags + subcommand from `args` (including `args[0]`/program name, which is
    /// skipped). Pure — no I/O, no exit. Every rule (which flags take values, where `-e` is
    /// terminal, when `--` ends option parsing, which unknown flag is fatal) is `args.rs`'s.
    ///
    /// Two calls: the first reports how many token spans and how many bytes the answer needs, the
    /// second fills the buffers it named. The record itself is fixed-size and comes back on both.
    public static func parse(_ args: [String]) -> Result<CLIInvocation, CLIParseError> {
        var arena = Data()
        let spans = args.map { argument in intern(argument, into: &arena) }
        var record = SlopDeskCliInvocation()
        let (tokens, text) = spans.withUnsafeBufferPointer { input -> ([SlopDeskByteSpan], Data) in
            arena.withUnsafeBytes { pool -> ([SlopDeskByteSpan], Data) in
                let shape = slopdesk_cli_parse(
                    input.baseAddress, input.count, pool.baseAddress, pool.count,
                    &record, nil, 0, nil, 0,
                )
                let (room, bytes) = (shape.count, shape.arena_len)
                guard room > 0 || bytes > 0 else { return ([], Data()) }
                var out = [SlopDeskByteSpan](repeating: SlopDeskByteSpan(), count: shape.count)
                var built = Data(count: shape.arena_len)
                out.withUnsafeMutableBufferPointer { tokens in
                    built.withUnsafeMutableBytes { text in
                        _ = slopdesk_cli_parse(
                            input.baseAddress, input.count, pool.baseAddress, pool.count,
                            &record, tokens.baseAddress, tokens.count, text.baseAddress, text.count,
                        )
                    }
                }
                return (out, built)
            }
        }
        if let failure = failure(record, text) { return .failure(failure) }
        return .success(invocation(record, tokens: tokens, text: text))
    }

    /// The parse error a record carries, or `nil` when it parsed.
    private static func failure(_ record: SlopDeskCliInvocation, _ text: Data) -> CLIParseError? {
        let flag = string(record.error_flag, text)
        switch record.error {
        case SLOPDESK_CLI_UNKNOWN_FLAG: return .unknownFlag(flag)
        case SLOPDESK_CLI_MISSING_VALUE: return .missingValue(flag)
        case SLOPDESK_CLI_INVALID_VALUE:
            return .invalidValue(flag: flag, value: string(record.error_value, text))
        default: return nil
        }
    }

    /// The invocation a record and its two buffers describe.
    private static func invocation(
        _ record: SlopDeskCliInvocation,
        tokens: [SlopDeskByteSpan],
        text: Data,
    ) -> CLIInvocation {
        let rest = tokens.prefix(record.rest_count).map { span in string(span, text) }
        let exec = tokens.dropFirst(record.rest_count).prefix(record.exec_count)
            .map { span in string(span, text) }
        return CLIInvocation(
            subcommand: string(record.subcommand, text),
            rest: Array(rest),
            format: CLIOutputFormat.of(record.format),
            noHeaders: record.no_headers,
            socketPath: record.has_socket ? string(record.socket_path, text) : nil,
            configFile: record.has_config ? string(record.config_file, text) : nil,
            timeoutMs: Int(record.timeout_ms),
            assumeYes: record.assume_yes,
            wantsHelp: record.wants_help,
            launchGUI: record.launch_gui,
            execCommand: record.has_exec ? Array(exec) : nil,
        )
    }

    /// Appends one string's UTF-8 and answers the span naming it — ``ArenaText/intern(_:into:)``
    /// wearing this door's C struct, which is the only part of it that is about this door.
    private static func intern(_ value: String, into arena: inout Data) -> SlopDeskByteSpan {
        let span = ArenaText.intern(value, into: &arena)
        return SlopDeskByteSpan(offset: span.offset, length: span.length)
    }

    /// The text a span names, or "" when it names nothing — ``ArenaText/text(_:offset:length:)``
    /// wearing this door's C struct.
    private static func string(_ span: SlopDeskByteSpan, _ arena: Data) -> String {
        ArenaText.text(arena, offset: Int(span.offset), length: Int(span.length))
    }
}
