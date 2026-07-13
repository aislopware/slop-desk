import Foundation

// SlopDeskCtlCore — the PURE, testable core of slopdesk-ctl.
//
// Contains:
//  - GlobalArgs / parseGlobal: arg-parsing (no I/O, no exit — pure transform).
//  - encodeRequest / decodeResponse: NDJSON request/response helpers.
//
// The thin `main.swift` shell in `slopdesk-ctl` imports this and adds:
//  - Socket I/O (sendRequest).
//  - Subcommand dispatch + final exit calls.
//
// Both are kept separate so the pure logic is unit-testable without a real socket
// (hang-safety rule: no AF_UNIX in unit tests).

// MARK: - Arg parsing

/// Parsed global flags + subcommand.
public struct GlobalArgs: Sendable {
    /// Explicit `--socket PATH` override; empty if not provided.
    public var socketPath: String = ""
    /// The first non-flag positional argument (the subcommand name).
    public var subcommand: String = ""
    /// Arguments after the subcommand.
    public var rest: [String] = []

    public init() {}
}

/// Errors thrown by ``parseGlobal(_:)`` — returned instead of calling `exit` so unit tests can
/// inspect them. The CLI's `main.swift` maps these to `die()` + `exit`.
public enum ParseError: Error, Equatable, Sendable {
    case unknownFlag(String)
    case missingValue(String)
}

/// Parses the global flags and subcommand from `args` (including `args[0]` / program name,
/// which is skipped). Pure — no I/O, no exit. Returns a `ParseError` for unknown flags or
/// missing flag values.
///
/// Accepted global flags (before or after the subcommand):
/// - `--socket PATH`
/// - `--help` / `-h`  (sets `subcommand = "help"` so the caller can gate on it)
public func parseGlobal(_ args: [String]) -> Result<GlobalArgs, ParseError> {
    var result = GlobalArgs()
    var idx = 1 // skip argv[0]
    while idx < args.count {
        let arg = args[idx]
        switch arg {
        case "--socket":
            guard idx + 1 < args.count else {
                return .failure(.missingValue("--socket"))
            }
            idx += 1
            result.socketPath = args[idx]
        case "--help",
             "-h":
            result.subcommand = "help"
        default:
            if arg.hasPrefix("-"), result.subcommand.isEmpty {
                return .failure(.unknownFlag(arg))
            }
            if result.subcommand.isEmpty {
                result.subcommand = arg
            } else {
                result.rest.append(arg)
            }
        }
        idx += 1
    }
    return .success(result)
}

// MARK: - Request encoding

/// Encodes a JSON request object into a NDJSON line (WITHOUT trailing LF — the caller appends it).
/// Returns `nil` only on the extremely unlikely JSON-serialisation failure (all inputs are known types).
public func encodeRequestLine(id: String, method: String, params: [String: Any]) -> String? {
    let dict: [String: Any] = ["id": id, "method": method, "params": params]
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
          let str = String(bytes: data, encoding: .utf8)
    else { return nil }
    return str
}

/// Parses a NDJSON response line into a decoded object.
/// Returns `nil` on malformed / non-UTF-8 input (validate-then-drop).
public func decodeResponseLine(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

// MARK: - Verb parameter builders

/// Builds the params dict for the `list-panes` verb.
public func listPanesParams() -> [String: Any] { [:] }

/// Builds the params dict for the `read` verb.
/// - Parameters:
///   - paneId: the target pane UUID string.
///   - ansiStrip: when `true` (default), the host strips ANSI escape sequences before returning.
///   - unwrapped: when `true`, requests the logical-line view (`source: "unwrapped"`) — the host
///     returns a `lines` array (joined chunks, ANSI-stripped, split on hard `\n`, partial trailing
///     line dropped) so an agent regex is robust to read-chunk boundaries. `ansiStrip` is implied.
///   - lines: optional last-N logical-line cap (only meaningful with `unwrapped`).
public func readParams(
    paneId: String,
    ansiStrip: Bool = true,
    unwrapped: Bool = false,
    lines: Int? = nil,
) -> [String: Any] {
    var params: [String: Any] = ["paneId": paneId, "ansiStrip": ansiStrip]
    if unwrapped {
        params["source"] = "unwrapped"
        if let lines, lines > 0 { params["lines"] = lines }
    }
    return params
}

/// Builds the params dict for the `screen` verb — the RENDERED-screen dump (the host replays
/// the scrollback ring through its VT screen model at the pane's live size and returns the
/// visible grid, so TUI panes read as what a human sees). `rows`/`cols` override the grid size;
/// `nil` (default) uses the live PTY winsize.
public func screenParams(paneId: String, rows: Int? = nil, cols: Int? = nil) -> [String: Any] {
    var params: [String: Any] = ["paneId": paneId]
    if let rows { params["rows"] = rows }
    if let cols { params["cols"] = cols }
    return params
}

/// Builds the params dict for the `write` verb. `text` is sent first, then each named-key token
/// in `keys` (tmux `send-keys` vocabulary — `C-c`, `Enter`, `Up`, … — resolved host-side; an
/// unknown token errors the whole request). At least one of the two must be non-empty.
public func writeParams(paneId: String, text: String? = nil, keys: [String] = []) -> [String: Any] {
    var params: [String: Any] = ["paneId": paneId]
    if let text { params["text"] = text }
    if !keys.isEmpty { params["keys"] = keys }
    return params
}

/// Builds the params dict for the `run` verb (text + implicit Enter sent as one atomic write).
/// With `wait: true` the host blocks until the command's OSC-133 block closes and answers
/// `{matched, exitCode?, durationMs?, output, blockIndex}` (`timeoutMs` bounds the block-wait;
/// `ansiStrip: false` keeps escapes in the returned output).
public func runParams(
    paneId: String,
    cmd: String,
    wait: Bool = false,
    timeoutMs: Double = 30000,
    ansiStrip: Bool = true,
) -> [String: Any] {
    var params: [String: Any] = ["paneId": paneId, "text": cmd]
    if wait {
        params["wait"] = true
        params["timeoutMs"] = timeoutMs
        params["ansiStrip"] = ansiStrip
    }
    return params
}

/// Builds the params dict for the `wait` verb (output-regex arm).
public func waitParams(paneId: String, until: String, timeoutMs: Double = 30000) -> [String: Any] {
    ["paneId": paneId, "until": until, "timeoutMs": timeoutMs]
}

/// Builds the params dict for the `wait` verb's AGENT-STATE arm: block until the pane's
/// supervision state is in `states` (comma-set of `idle`/`working`/`done`/`blocked`).
public func waitStateParams(paneId: String, states: String, timeoutMs: Double = 30000) -> [String: Any] {
    ["paneId": paneId, "state": states, "timeoutMs": timeoutMs]
}

/// Builds the params dict for the `last-output` verb: the last `n` closed OSC-133 command
/// blocks (command + output + exit code), newest last.
public func lastOutputParams(paneId: String, n: Int = 1, ansiStrip: Bool = true) -> [String: Any] {
    ["paneId": paneId, "n": n, "ansiStrip": ansiStrip]
}

/// Builds the params dict for the `spawn` verb.
/// - Parameters:
///   - cmd: optional shell command string; when non-nil, run as `$SHELL -c <cmd>`.
///   - cwd: optional working directory.
///   - env: optional extra env vars (K=V dict).
///   - rows: PTY rows (default 24).
///   - cols: PTY columns (default 80).
///   - shellPath: the shell to use for `$SHELL -c` expansion (default `/bin/zsh`).
public func spawnParams(
    cmd: String?,
    cwd: String?,
    env: [String: String],
    rows: Int,
    cols: Int,
    shellPath: String = "/bin/zsh",
) -> [String: Any] {
    var params: [String: Any] = ["rows": rows, "cols": cols]
    if let cmd { params["cmd"] = [shellPath, "-c", cmd] }
    if let cwd { params["cwd"] = cwd }
    if !env.isEmpty { params["env"] = env }
    return params
}

/// Builds the params dict for the `kill` verb.
public func killParams(paneId: String) -> [String: Any] {
    ["paneId": paneId]
}

/// Builds the params dict for the `subscribe` verb.
/// - Parameters:
///   - paneId: the target pane UUID string.
///   - ansiStrip: when `true` (default), the host strips ANSI escape sequences from each
///     output chunk before emitting the event line. Pass `false` to receive raw PTY bytes
///     (useful when the caller needs to parse colour codes or cursor sequences itself).
public func subscribeParams(paneId: String, ansiStrip: Bool = true) -> [String: Any] {
    ["paneId": paneId, "ansiStrip": ansiStrip]
}

/// Builds the params dict for the `report` verb (agent self-declares its supervision state).
/// - Parameters:
///   - paneId: the target pane UUID string.
///   - state: one of `idle` / `working` / `done` / `blocked` (validated host-side).
///   - message: optional human label (e.g. the blocking question / last assistant line).
public func reportParams(paneId: String, state: String, message: String?) -> [String: Any] {
    var params: [String: Any] = ["paneId": paneId, "state": state]
    if let message { params["message"] = message }
    return params
}

/// Builds the params dict for the `resize` verb.
/// - Parameters:
///   - paneId: the target pane UUID string.
///   - rows: new PTY row count (1–65535).
///   - cols: new PTY column count (1–65535).
public func resizeParams(paneId: String, rows: Int, cols: Int) -> [String: Any] {
    ["paneId": paneId, "rows": rows, "cols": cols]
}

/// Builds the params dict for the TOP-LEVEL `subscribe` (the `events` stream): NO `paneId`,
/// which the host treats as "fan `agent_status_changed` across all panes". An empty dict is the
/// whole contract — the absence of `paneId` is the signal (a present-but-missing paneId is the
/// per-pane mode).
public func subscribeAllParams() -> [String: Any] { [:] }
