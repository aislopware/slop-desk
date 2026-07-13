import Darwin
import Foundation
import SlopDeskCtlCore

// slopdesk-ctl — the reference client for the agent-control Unix-domain socket.
//
// Usage (subcommands map to protocol verbs):
//   slopdesk-ctl [--socket PATH] list-panes [--json]
//   slopdesk-ctl [--socket PATH] read <paneId> [--ansi] [--full] [--lines N]
//   slopdesk-ctl [--socket PATH] last-output <paneId> [--n N] [--ansi] [--json]
//   slopdesk-ctl [--socket PATH] write <paneId> [--text "..."] [--key K[,K...]]
//   slopdesk-ctl [--socket PATH] run <paneId> --cmd "..." [--wait] [--timeout-ms N] [--json]
//   slopdesk-ctl [--socket PATH] wait <paneId> (--until "<regex>" | --state S) [--timeout-ms N]
//   slopdesk-ctl [--socket PATH] spawn [--cmd "..."] [--cwd "..."] [--env K=V] [--rows N] [--cols N]
//   slopdesk-ctl [--socket PATH] kill <paneId>
//   slopdesk-ctl [--socket PATH] subscribe <paneId> [--ansi]
//   slopdesk-ctl [--socket PATH] resize <paneId> --rows N --cols N
//
// Socket path resolved from (in priority order):
//   1. --socket flag
//   2. SLOPDESK_CONTROL_SOCKET env var (injected by the host into every spawned PTY)
//   3. Fatal error with a clear message.
//
// Exit codes: 0 on success, 1 on error, 1 on wait-timeout (with "timeout" to stderr).

// MARK: - Fatal helpers

let programName = CommandLine.arguments.first
    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "slopdesk-ctl"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
    exit(1)
}

func stdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// MARK: - Usage

func printUsage() {
    stdout("""
    usage: \(programName) [--socket PATH] <subcommand> [args...]

    Subcommands:
      list-panes [--json]
          List all live panes.  --json emits the raw NDJSON response line.

      read <paneId> [--ansi] [--full] [--lines N] [--unwrapped]
          Dump the pane's scrollback.  --ansi keeps ANSI escape codes (default: stripped).
          --full reads the complete scrollback ring (overrides --lines).
          --lines N limits output to the last N lines.
          --unwrapped (alias --recent) returns logical lines (joined chunks, ANSI-stripped,
          split on hard newlines, partial trailing line dropped) so a regex is robust to
          read-chunk boundaries.  Combine with --lines N for the last N logical lines.

      last-output <paneId> [--n N] [--ansi] [--json]
          The last N finished commands as OSC-133 blocks: command line, output, exit code,
          duration — no prompt scraping.  Default N=1.  A still-running command is noted.
          --ansi keeps escapes in output.  --json emits the raw NDJSON response.
          Requires shell integration marks (SLOPDESK_BLOCKS on, default).

      write <paneId> [--text "..."] [--key K[,K...]]
          Send raw text bytes and/or named keys to the pane's PTY (no implicit Enter).
          --key takes tmux send-keys names, comma-separated or repeated:
            Enter Tab Space Esc Backspace Delete Up Down Left Right Home End
            PageUp PageDown F1..F12 C-<x> (Ctrl, e.g. C-c) M-<x> (Alt/Meta)
          Text is sent before keys: --text "ls" --key Enter runs ls.

      run <paneId> --cmd "..." [--wait] [--timeout-ms N] [--ansi] [--json]
          Send text + Enter to the pane (execute a shell command).
          --wait blocks until the command's OSC-133 block closes, prints its output, and
          exits with the COMMAND's exit code (timeout → exit 124, "timeout" on stderr).
          A status line "exit <code> (<duration>ms)" goes to stderr.

      wait <paneId> (--until "<regex>" | --state S) [--timeout-ms N]
          Block until pane output matches <regex> (ANSI-stripped), or — with --state —
          until the pane's agent state is in S (comma-set of idle|working|done|blocked,
          e.g. --state done,blocked).
          Prints "matched (Nms)" (regex) / the matched state and exits 0.
          Prints "timeout after Nms" to stderr and exits 1 on timeout.
          Default timeout: 30000ms.

      spawn [--cmd "..."] [--cwd "..."] [--env K=V] [--rows N] [--cols N]
          Spawn a new standalone PTY pane.  Prints the new paneId to stdout.
          --cmd is passed as $SHELL -c "<cmd>".  Without --cmd, spawns the login shell.

      kill <paneId>
          Kill a pane by its UUID id.

      subscribe <paneId> [--ansi]
          Stream live PTY output as NDJSON event lines until the pane exits.
          Each line is one of:
            {"event":"output","text":"<plain-text chunk>"}
            {"event":"closed"}
          --ansi keeps ANSI escape codes in event text (default: stripped).
          Prints event lines to stdout.  Exits 0 when the pane closes.

      resize <paneId> --rows N --cols N
          Resize the pane's PTY to N rows × N cols (1–65535 each).

      report <paneId> --state idle|working|done|blocked [--message "..."] [--json]
          Self-declare this pane's agent supervision state (authoritative — beats the
          foreground heuristic).  Use from inside a spawned agent pane.  --message attaches a
          human label (the blocking question / last line).

      events [--json]
          Stream top-level supervision events: one NDJSON line per pane status transition
          across ALL panes, until disconnected.  Line shape:
            {"type":"agent_status_changed","paneId":"…","state":"…","title":"…","ts":…}
          COARSE-STATE ONLY: an event fires on a state change (idle/working/blocked/done);
          a same-state `report` that only updates the --message does NOT re-emit (no message
          field is carried).  Use `read --unwrapped` to fetch the latest blocking prompt text.

    Flags:
      --socket PATH   Override the control socket path.

    Socket resolution (in order):
      1. --socket flag
      2. SLOPDESK_CONTROL_SOCKET environment variable
      3. Fatal error — no socket known.

    """)
}

// MARK: - Socket path resolution

func resolveSocketPath(_ explicit: String) -> String {
    if !explicit.isEmpty { return explicit }
    if let env = ProcessInfo.processInfo.environment["SLOPDESK_CONTROL_SOCKET"], !env.isEmpty {
        return env
    }
    die(
        "no control socket path: set SLOPDESK_CONTROL_SOCKET or pass --socket PATH\n"
            + "\(programName): hint: run from inside a pane spawned by slopdesk-hostd "
            + "with SLOPDESK_AGENT_CONTROL=1",
    )
}

// MARK: - Unix socket I/O

/// Opens an AF_UNIX connection to `socketPath`, sends `requestLine` + LF, reads one
/// response line, and returns it (trailing LF stripped).
/// Any I/O error calls `die()`.
func sendRequest(socketPath: String, requestLine: String) -> String {
    // Guard path length before syscall (same cap as the server).
    let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard socketPath.utf8.count <= maxPath else {
        die("socket path too long: \(socketPath)")
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket(2) failed: \(String(cString: strerror(errno)))") }
    defer { close(fd) }

    // Connect.
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            strncpy(
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                cstr,
                maxPath,
            )
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        die("connect '\(socketPath)': \(String(cString: strerror(errno)))")
    }

    // Send the request line (ensure trailing LF).
    var line = requestLine
    if !line.hasSuffix("\n") { line += "\n" }
    let sendData = Data(line.utf8)
    sendData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        let total = raw.count
        while offset < total {
            let n = write(fd, base + offset, total - offset)
            if n > 0 { offset += n }
            else if n < 0, errno == EINTR { continue }
            else { die("write to socket failed: \(String(cString: strerror(errno)))") }
        }
    }

    // Read one response line (NDJSON: terminated by LF).
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let maxBytes = 64 * 1024 * 64 // generous: scrollback can be large
    outer: while response.count < maxBytes {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { break }
        for i in 0..<n {
            response.append(chunk[i])
            if chunk[i] == 0x0A { break outer }
        }
    }

    if response.last == 0x0A { response.removeLast() }
    guard let str = String(bytes: response, encoding: .utf8) else {
        die("response from host is not valid UTF-8")
    }
    return str
}

// MARK: - Dispatch helpers

func requireOK(_ obj: [String: Any], context: String = "") {
    if let ok = obj["ok"] as? Bool, ok { return }
    let errMsg = obj["error"] as? String ?? "(no error message)"
    die(context.isEmpty ? "server error: \(errMsg)" : "\(context): \(errMsg)")
}

func callVerb(socketPath: String, method: String, params: [String: Any]) -> [String: Any] {
    guard let line = encodeRequestLine(id: "1", method: method, params: params) else {
        die("failed to encode \(method) request as JSON")
    }
    let resp = sendRequest(socketPath: socketPath, requestLine: line)
    guard let obj = decodeResponseLine(resp) else {
        die("malformed response from host: \(resp)")
    }
    return obj
}

// MARK: - Subcommand implementations

func cmdListPanes(socketPath: String, rest: [String]) {
    let jsonMode = rest.contains("--json")
    let obj = callVerb(socketPath: socketPath, method: "list-panes", params: listPanesParams())
    requireOK(obj, context: "list-panes")

    if jsonMode {
        // Re-encode sorted so it is stable and greppable.
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8)
        else { die("failed to re-encode JSON response") }
        stdout(line + "\n")
        return
    }

    let result = obj["result"] as? [String: Any] ?? [:]
    let panes = result["panes"] as? [[String: Any]] ?? []
    if panes.isEmpty {
        stdout("(no live panes)\n")
        return
    }
    // NOTE: build rows with manual left-padding — NEVER `String(format: "%s", swiftString)`.
    // `%s` reads its argument as a C `char *`, so passing a Swift `String` segfaults the CLI.
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    stdout(
        "\(pad("PANE-ID", 36))  \(pad("PID", 6))  \(pad("STATUS", 6))  \(pad("AGENT", 8))  "
            + "\(pad("EXIT", 4))  \(pad("CMD", 10))  \(pad("CWD", 28))  TITLE\n",
    )
    for pane in panes {
        let paneId = pane["paneId"] as? String ?? "-"
        let pid = pane["pid"] as? Int ?? -1
        let title = pane["title"] as? String ?? ""
        let isAlive = (pane["isAlive"] as? Bool) ?? false
        let status = isAlive ? "alive" : "dead"
        // P1 supervision state (idle/working/done/blocked). Older hosts omit it → "-".
        let agent = pane["state"] as? String ?? "-"
        let exit = (pane["lastExitCode"] as? Int).map(String.init) ?? "-"
        let command = pane["command"] as? String ?? "-"
        // Home-shorten the cwd like a prompt does; a pane with no observed cwd shows "-".
        let cwd: String = {
            guard let raw = pane["cwd"] as? String else { return "-" }
            let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
            if !home.isEmpty, raw.hasPrefix(home) { return "~" + raw.dropFirst(home.count) }
            return raw
        }()
        stdout(
            "\(pad(paneId, 36))  \(pad(String(pid), 6))  \(pad(status, 6))  \(pad(agent, 8))  "
                + "\(pad(exit, 4))  \(pad(command.isEmpty ? "-" : command, 10))  \(pad(cwd, 28))  \(title)\n",
        )
        // A blocked pane's question rides list-panes directly (no scrollback scrape needed).
        if let message = pane["stateMessage"] as? String, !message.isEmpty {
            stdout("\(pad("", 36))  └ \(message)\n")
        }
    }
}

func cmdLastOutput(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("last-output requires <paneId>") }
    let paneId = rest[0]
    var n = 1
    var keepAnsi = false
    var jsonMode = false
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--n":
            guard idx + 1 < rest.count else { die("--n requires a value") }
            idx += 1
            guard let value = Int(rest[idx]), value > 0 else { die("--n requires a positive integer") }
            n = value
        case "--ansi":
            keepAnsi = true
        case "--json":
            jsonMode = true
        default:
            die("unknown flag for last-output: \(rest[idx])")
        }
        idx += 1
    }
    let obj = callVerb(
        socketPath: socketPath, method: "last-output",
        params: lastOutputParams(paneId: paneId, n: n, ansiStrip: !keepAnsi),
    )
    requireOK(obj, context: "last-output")
    if jsonMode {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8)
        else { die("failed to re-encode JSON response") }
        stdout(line + "\n")
        return
    }
    let result = obj["result"] as? [String: Any] ?? [:]
    let blocks = result["blocks"] as? [[String: Any]] ?? []
    if blocks.isEmpty {
        stdout("(no finished commands)\n")
    }
    for block in blocks {
        let command = block["command"] as? String ?? ""
        let exit = (block["exitCode"] as? Int).map { "exit \($0)" } ?? "no exit code"
        let duration = (block["durationMs"] as? Int).map { ", \($0)ms" } ?? ""
        let complete = (block["complete"] as? Bool) ?? true
        let marker = complete ? "" : " [interrupted]"
        stdout("$ \(command)  (\(exit)\(duration))\(marker)\n")
        let output = block["output"] as? String ?? ""
        stdout(output)
        if !output.hasSuffix("\n") { stdout("\n") }
    }
    if let running = result["running"] as? [String: Any] {
        let command = running["command"] as? String ?? ""
        let outputLen = running["outputLen"] as? Int ?? 0
        stdout("… running: $ \(command)  (\(outputLen) output bytes so far)\n")
    }
}

func cmdRead(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("read requires <paneId>") }
    let paneId = rest[0]
    var keepAnsi = false
    var limitLines: Int?
    var fullRing = false
    var unwrapped = false
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--ansi":
            keepAnsi = true
        case "--full":
            // Explicit "full ring" — overrides any --lines limit and reads the complete scrollback.
            fullRing = true
        case "--unwrapped",
             "--recent":
            // Logical-line view: the host returns a `lines` array (joined chunks, ANSI-stripped,
            // split on hard \n, partial trailing line dropped) so a regex is chunk-boundary robust.
            unwrapped = true
        case "--lines":
            guard idx + 1 < rest.count else { die("--lines requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--lines requires a positive integer") }
            limitLines = n
        default:
            die("unknown flag for read: \(rest[idx])")
        }
        idx += 1
    }
    // --full takes precedence over --lines.
    if fullRing { limitLines = nil }

    let params = readParams(
        paneId: paneId, ansiStrip: !keepAnsi, unwrapped: unwrapped,
        lines: unwrapped ? limitLines : nil,
    )
    let obj = callVerb(socketPath: socketPath, method: "read", params: params)
    requireOK(obj, context: "read")

    let result = obj["result"] as? [String: Any] ?? [:]
    var text = result["text"] as? String ?? ""

    // For the non-unwrapped path, the host returns the whole snapshot; apply the last-N trim
    // client-side. For --unwrapped, the host already applied the cap (and built `text` from the
    // logical `lines`), so no further trim is needed.
    if !unwrapped, let limit = limitLines {
        let lines = text.components(separatedBy: "\n")
        text = lines.suffix(limit).joined(separator: "\n")
    }

    stdout(text)
    if !text.hasSuffix("\n") { stdout("\n") }
}

func cmdWrite(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("write requires <paneId>") }
    let paneId = rest[0]
    var text: String?
    var keys: [String] = []
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--text":
            guard idx + 1 < rest.count else { die("--text requires a value") }
            idx += 1
            text = rest[idx]
        case "--key":
            guard idx + 1 < rest.count else { die("--key requires a value") }
            idx += 1
            // Comma-separated and/or repeated: --key C-c,Enter == --key C-c --key Enter.
            keys.append(contentsOf: rest[idx].split(separator: ",").map(String.init))
        default:
            die("unknown flag for write: \(rest[idx])")
        }
        idx += 1
    }
    guard text != nil || !keys.isEmpty else { die("write requires --text \"...\" and/or --key K") }
    let obj = callVerb(
        socketPath: socketPath, method: "write",
        params: writeParams(paneId: paneId, text: text, keys: keys),
    )
    requireOK(obj, context: "write")
}

func cmdRun(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("run requires <paneId>") }
    let paneId = rest[0]
    var cmd: String?
    var wait = false
    var timeoutMs: Double = 30000
    var keepAnsi = false
    var jsonMode = false
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--cmd":
            guard idx + 1 < rest.count else { die("--cmd requires a value") }
            idx += 1
            cmd = rest[idx]
        case "--wait":
            wait = true
        case "--timeout-ms":
            guard idx + 1 < rest.count else { die("--timeout-ms requires a value") }
            idx += 1
            guard let ms = Double(rest[idx]), ms > 0 else { die("--timeout-ms requires a positive number") }
            timeoutMs = ms
        case "--ansi":
            keepAnsi = true
        case "--json":
            jsonMode = true
        default:
            die("unknown flag for run: \(rest[idx])")
        }
        idx += 1
    }
    guard let cmdValue = cmd else { die("run requires --cmd \"...\"") }
    let obj = callVerb(
        socketPath: socketPath, method: "run",
        params: runParams(paneId: paneId, cmd: cmdValue, wait: wait, timeoutMs: timeoutMs, ansiStrip: !keepAnsi),
    )
    requireOK(obj, context: "run")
    guard wait else { return }

    if jsonMode {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8)
        else { die("failed to re-encode JSON response") }
        stdout(line + "\n")
        return
    }
    let result = obj["result"] as? [String: Any] ?? [:]
    let matched = (result["matched"] as? Bool) ?? false
    guard matched else {
        FileHandle.standardError.write(Data("\(programName): timeout after \(Int(timeoutMs))ms\n".utf8))
        exit(124) // timeout(1) convention, distinct from a command's own exit 1
    }
    let output = result["output"] as? String ?? ""
    stdout(output)
    if !output.isEmpty, !output.hasSuffix("\n") { stdout("\n") }
    let exitCode = result["exitCode"] as? Int
    let duration = (result["durationMs"] as? Int).map { " (\($0)ms)" } ?? ""
    FileHandle.standardError.write(
        Data("\(programName): exit \(exitCode.map(String.init) ?? "?")\(duration)\n".utf8),
    )
    // Propagate the COMMAND's exit code (ssh-style) so `slopdesk-ctl run --wait` composes into
    // scripts. An unknown/interrupted exit maps to 1; codes clamp into the shell's 0–255 range.
    exit(Int32(min(max(exitCode ?? 1, 0), 255)))
}

func cmdWait(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("wait requires <paneId>") }
    let paneId = rest[0]
    var until: String?
    var states: String?
    var timeoutMs: Double = 30000
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--until":
            guard idx + 1 < rest.count else { die("--until requires a value") }
            idx += 1
            until = rest[idx]
        case "--state":
            guard idx + 1 < rest.count else { die("--state requires a value") }
            idx += 1
            states = rest[idx]
        case "--timeout-ms":
            guard idx + 1 < rest.count else { die("--timeout-ms requires a value") }
            idx += 1
            guard let ms = Double(rest[idx]), ms > 0 else { die("--timeout-ms requires a positive number") }
            timeoutMs = ms
        default:
            die("unknown flag for wait: \(rest[idx])")
        }
        idx += 1
    }
    let params: [String: Any]
    switch (until, states) {
    case let (pattern?, nil):
        params = waitParams(paneId: paneId, until: pattern, timeoutMs: timeoutMs)
    case let (nil, stateSet?):
        params = waitStateParams(paneId: paneId, states: stateSet, timeoutMs: timeoutMs)
    case (nil, nil):
        die("wait requires --until \"<regex>\" or --state S")
    case (.some, .some):
        die("wait takes --until OR --state, not both")
    }

    let obj = callVerb(socketPath: socketPath, method: "wait", params: params)
    requireOK(obj, context: "wait")

    let result = obj["result"] as? [String: Any] ?? [:]
    let matched = (result["matched"] as? Bool) ?? false
    let elapsed = result["elapsed"] as? Double ?? 0
    if matched {
        if let state = result["state"] as? String {
            stdout(String(format: "\(state) (%.0fms)\n", elapsed))
        } else {
            stdout(String(format: "matched (%.0fms)\n", elapsed))
        }
        exit(0)
    } else {
        FileHandle.standardError.write(Data("\(programName): timeout after \(Int(elapsed))ms\n".utf8))
        exit(1)
    }
}

func cmdSpawn(socketPath: String, rest: [String]) {
    var cmd: String?
    var cwd: String?
    var extraEnv: [String: String] = [:]
    var rows = 24
    var cols = 80
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--cmd":
            guard idx + 1 < rest.count else { die("--cmd requires a value") }
            idx += 1
            cmd = rest[idx]
        case "--cwd":
            guard idx + 1 < rest.count else { die("--cwd requires a value") }
            idx += 1
            cwd = rest[idx]
        case "--env":
            guard idx + 1 < rest.count else { die("--env requires a K=V value") }
            idx += 1
            let pair = rest[idx]
            guard let eq = pair.firstIndex(of: "=") else { die("--env requires K=V format, got '\(pair)'") }
            let key = String(pair[pair.startIndex..<eq])
            let val = String(pair[pair.index(after: eq)...])
            extraEnv[key] = val
        case "--rows":
            guard idx + 1 < rest.count else { die("--rows requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--rows requires a positive integer") }
            rows = n
        case "--cols":
            guard idx + 1 < rest.count else { die("--cols requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--cols requires a positive integer") }
            cols = n
        default:
            die("unknown flag for spawn: \(rest[idx])")
        }
        idx += 1
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let params = spawnParams(cmd: cmd, cwd: cwd, env: extraEnv, rows: rows, cols: cols, shellPath: shell)
    let obj = callVerb(socketPath: socketPath, method: "spawn", params: params)
    requireOK(obj, context: "spawn")

    let result = obj["result"] as? [String: Any] ?? [:]
    let paneId = result["paneId"] as? String ?? ""
    stdout(paneId + "\n")
}

func cmdKill(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("kill requires <paneId>") }
    let paneId = rest[0]
    let obj = callVerb(socketPath: socketPath, method: "kill", params: killParams(paneId: paneId))
    requireOK(obj, context: "kill")
    stdout("killed \(paneId)\n")
}

func cmdSubscribe(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("subscribe requires <paneId>") }
    let paneId = rest[0]
    // --ansi: keep ANSI escape codes in event text (default: stripped for clean agent output).
    var keepAnsi = false
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--ansi":
            keepAnsi = true
        default:
            die("unknown flag for subscribe: \(rest[idx])")
        }
        idx += 1
    }
    streamSubscribe(socketPath: socketPath, params: subscribeParams(paneId: paneId, ansiStrip: !keepAnsi))
}

/// Opens the control socket, sends a `subscribe` request with `params`, and streams every
/// NDJSON event line to stdout until the connection closes. Used by BOTH the per-pane
/// `subscribe` verb (params carry a `paneId`) and the top-level `events` stream (no `paneId`
/// → the host fans `agent_status_changed` across ALL panes). Exits 0 on a clean close.
func streamSubscribe(socketPath: String, params: [String: Any]) {
    // `subscribe` keeps the connection open and streams NDJSON event lines.
    // We can't use `sendRequest` (reads one line then closes). Open the socket directly,
    // send the request, then read lines until the connection closes (pane exited or error).
    let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard socketPath.utf8.count <= maxPath else { die("socket path too long: \(socketPath)") }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket(2) failed: \(String(cString: strerror(errno)))") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            strncpy(
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                cstr,
                maxPath,
            )
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        die("connect '\(socketPath)': \(String(cString: strerror(errno)))")
    }

    // Send the subscribe request.
    guard let reqLine = encodeRequestLine(
        id: "1",
        method: "subscribe",
        params: params,
    ) else {
        die("failed to encode subscribe request")
    }
    let sendData = Data((reqLine + "\n").utf8)
    sendData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        let total = raw.count
        while offset < total {
            let n = write(fd, base + offset, total - offset)
            if n > 0 { offset += n }
            else if n < 0, errno == EINTR { continue }
            else { die("write to socket failed: \(String(cString: strerror(errno)))") }
        }
    }

    // Stream NDJSON event lines until the server closes the connection.
    // The server never reads from the fd again after accept, so we just read.
    var lineBuffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { break } // server closed (pane exited) or error
        lineBuffer.append(contentsOf: chunk[0..<n])
        while let nlIdx = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<nlIdx]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: nlIdx)...])
            guard let line = String(bytes: lineData, encoding: .utf8), !line.isEmpty else { continue }
            // Print the raw NDJSON event line (let the caller parse if needed).
            stdout(line + "\n")
            // On {"event":"closed"} we can exit cleanly.
            if let obj = decodeResponseLine(line),
               let event = obj["event"] as? String, event == "closed"
            {
                exit(0)
            }
            // If the server sent an error response (pane not found etc.), surface it and exit.
            if let obj = decodeResponseLine(line), let ok = obj["ok"] as? Bool, !ok {
                let errMsg = obj["error"] as? String ?? "(no error)"
                die("subscribe: \(errMsg)")
            }
        }
    }
    // Server closed connection without a "closed" event (e.g. host restarted).
    exit(0)
}

func cmdResize(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("resize requires <paneId>") }
    let paneId = rest[0]
    var rows: Int?
    var cols: Int?
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--rows":
            guard idx + 1 < rest.count else { die("--rows requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n >= 1, n <= 65535 else { die("--rows must be 1..65535") }
            rows = n
        case "--cols":
            guard idx + 1 < rest.count else { die("--cols requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n >= 1, n <= 65535 else { die("--cols must be 1..65535") }
            cols = n
        default:
            die("unknown flag for resize: \(rest[idx])")
        }
        idx += 1
    }
    guard let r = rows else { die("resize requires --rows N") }
    guard let c = cols else { die("resize requires --cols N") }
    let obj = callVerb(socketPath: socketPath, method: "resize", params: resizeParams(paneId: paneId, rows: r, cols: c))
    requireOK(obj, context: "resize")
    stdout("resized \(paneId) to \(r)x\(c)\n")
}

func cmdReport(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("report requires <paneId>") }
    let paneId = rest[0]
    var state: String?
    var message: String?
    var jsonMode = false
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--state":
            guard idx + 1 < rest.count else { die("--state requires a value") }
            idx += 1
            state = rest[idx]
        case "--message":
            guard idx + 1 < rest.count else { die("--message requires a value") }
            idx += 1
            message = rest[idx]
        case "--json":
            jsonMode = true
        default:
            die("unknown flag for report: \(rest[idx])")
        }
        idx += 1
    }
    guard let stateValue = state else {
        die("report requires --state idle|working|done|blocked")
    }
    let obj = callVerb(
        socketPath: socketPath, method: "report",
        params: reportParams(paneId: paneId, state: stateValue, message: message),
    )
    requireOK(obj, context: "report")
    if jsonMode {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8)
        else { die("failed to re-encode JSON response") }
        stdout(line + "\n")
    } else {
        stdout("reported \(paneId) as \(stateValue)\n")
    }
}

/// `events` — top-level supervision stream: subscribe with NO paneId and print every
/// `agent_status_changed` NDJSON line across ALL panes until the connection drops.
func cmdEvents(socketPath: String, rest: [String]) {
    for arg in rest where arg != "--json" {
        die("unknown flag for events: \(arg)")
    }
    streamSubscribe(socketPath: socketPath, params: subscribeAllParams())
}

// MARK: - Entry point

let args = CommandLine.arguments

let parseResult = parseGlobal(args)
let global: GlobalArgs
switch parseResult {
case let .success(g): global = g
case let .failure(err):
    switch err {
    case let .unknownFlag(flag): die("unknown flag '\(flag)' (run with --help)")
    case let .missingValue(flag): die("'\(flag)' requires a value")
    }
}

if global.subcommand.isEmpty || global.subcommand == "help" {
    printUsage()
    exit(global.subcommand == "help" ? 0 : 2)
}

let socketPath = resolveSocketPath(global.socketPath)

switch global.subcommand {
case "list-panes":
    cmdListPanes(socketPath: socketPath, rest: global.rest)
case "read":
    cmdRead(socketPath: socketPath, rest: global.rest)
case "last-output":
    cmdLastOutput(socketPath: socketPath, rest: global.rest)
case "write":
    cmdWrite(socketPath: socketPath, rest: global.rest)
case "run":
    cmdRun(socketPath: socketPath, rest: global.rest)
case "wait":
    cmdWait(socketPath: socketPath, rest: global.rest)
case "spawn":
    cmdSpawn(socketPath: socketPath, rest: global.rest)
case "kill":
    cmdKill(socketPath: socketPath, rest: global.rest)
case "subscribe":
    cmdSubscribe(socketPath: socketPath, rest: global.rest)
case "events":
    cmdEvents(socketPath: socketPath, rest: global.rest)
case "report":
    cmdReport(socketPath: socketPath, rest: global.rest)
case "resize":
    cmdResize(socketPath: socketPath, rest: global.rest)
default:
    die("unknown subcommand '\(global.subcommand)' (run with --help)")
}
