import SlopDeskCLICore
import SlopDeskTTY
import SlopDeskWorkspaceCore
#if os(macOS)
import CoreText
#endif
import Darwin
import Foundation

// slopdesk — the user-facing CLI. One binary, a superset of `slopdesk-ctl`:
//
//   slopdesk                     launch the client GUI (like bare xterm/alacritty/ghostty)
//   slopdesk -e <cmd> [args...]  launch the GUI + run <cmd> in the first pane (xterm `-e`)
//   slopdesk version             print version + build hash + protocol summary  (local, no socket)
//   slopdesk completions <shell> print a shell completion script                 (local, no socket)
//   slopdesk -h | --help         usage
//
// All socket I/O / GUI launch lives here (the compiled-only shell); the pure parse/version/
// completion logic lives in `SlopDeskCLICore` and is exhaustively unit-tested (hang-safety rule).
//
// WHICH subcommands exist, which of them run, and what each does is NOT written down here. It is
// one table in `rust/slopdesk-cli`'s `vocabulary`, and this file only dispatches it. The switch at
// the bottom must cover exactly `CLICompletions.subcommands` — the verbs the shells offer — and
// `slopdesk-invariants` holds the two to each other. Before that table, the vocabulary was spelled
// four times with nothing tying the copies together, and the drift reached users: `open`, `import`,
// `export`, `features`, `state:claude` and `ipc` tab-completed in all five shells and then exited 2
// with "not available yet". A completion is a promise the verb exists; those six are planned, so
// they are no longer offered, and typing one now says so.

// MARK: - Fatal / output helpers

let programName = CommandLine.arguments.first
    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "slopdesk"

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
    exit(code)
}

func stdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// MARK: - Usage

/// Print `--help`.
///
/// The text is `rust/slopdesk-cli`'s, rendered from the SAME table the completions and this file's
/// dispatch switch derive from. It used to be seventy lines of literal prose here, which is how the
/// help came to document verbs the shells offered and the dispatcher rejected: three copies of one
/// list, each edited on its own occasion.
func printUsage() {
    stdout(CLIUsage.text(programName: programName))
}

// MARK: - GUI launch passthrough

/// Bundle identifier of the macOS client app (`Apps/ClientApp-macOS/project.yml`).
let clientBundleIdentifier = "com.slopdesk.client.macos"

#if os(macOS)
/// Launches the client GUI via LaunchServices (`open -b <bundle-id>`). Compiled-only — never exercised
/// by a unit test (it spawns a process).
///
/// `forward` is the xterm/ghostty `-e <cmd>` command: after the window is up, it is sent to the first
/// (focused) pane over the control socket (VERBATIM UTF-8 + a keycode Enter). Best-effort — the GUI has
/// already launched (the xterm-compat guarantee); a forward that times out just leaves the command untyped.
func launchClientGUI(forward: [String]? = nil) -> Never {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-b", clientBundleIdentifier]
    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { exit(1) }
    } catch {
        die("failed to launch the SlopDesk app: \(error.localizedDescription)")
    }
    if let forward, !forward.isEmpty { forwardExecCommand(forward) }
    exit(0)
}

/// Best-effort `-e <cmd>` forward: poll the client control socket until the freshly-launched app publishes
/// it (bounded ~5s), then deliver the joined command to the focused (first) pane as VERBATIM text + a
/// keycode Enter (``ClientControlProtocol/Method/paneSendKeys``). Fire-and-forget + NEVER fatal — the GUI is
/// already visible (the xterm-compat guarantee); a connect that never succeeds just leaves the command
/// untyped (every `die()` path is replaced by a silent return here).
func forwardExecCommand(_ command: [String]) {
    let socketPath = resolveClientSocketPath()
    let text = command.joined(separator: " ")
    guard let line = ClientControlProtocol.encodeRequestLine(
        id: "1",
        method: ClientControlProtocol.Method.paneSendKeys,
        params: ClientControlProtocol.paneSendKeysParams(paneId: nil, text: text, keys: ["Enter"]),
    ) else { return }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if forwardSend(socketPath: socketPath, requestLine: line) { return }
        usleep(150_000) // 150ms between attempts while the workspace initialises
    }
}

/// One non-fatal connect+write of `requestLine` to the AF_UNIX control socket; returns `true` once the bytes
/// are delivered (response ignored — a forward is fire-and-forget). Every failure returns `false` instead of
/// `die()`ing, so the `-e` launch path can retry the launch race and never abort with a transport error.
func forwardSend(socketPath: String, requestLine: String) -> Bool {
    let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard socketPath.utf8.count <= maxPath else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, maxPath)
        }
    }
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return false }
    var line = requestLine
    if !line.hasSuffix("\n") { line += "\n" }
    let sendData = Data(line.utf8)
    return FileDescriptorWrite.all(fd: fd, sendData) == .complete
}
#else
func launchClientGUI(forward _: [String]? = nil) -> Never {
    die("launching the GUI is only supported on macOS")
}
#endif

// MARK: - Local subcommands

func runCompletions(_ rest: [String]) -> Never {
    guard let shellArg = rest.first else {
        die("completions requires a shell: bash | zsh | fish | elvish | powershell")
    }
    guard let shell = CLICompletions.Shell(argument: shellArg) else {
        die("unsupported shell '\(shellArg)': expected bash | zsh | fish | elvish | powershell")
    }
    stdout(CLICompletions.completionScript(for: shell))
    exit(0)
}

/// `sidecars [--record] [--json] [--manifest PATH] [--previous PATH]`
///
/// What the last upgrade changed, tool by tool, and what each change means. Reads two files and
/// touches no process: `brew upgrade` runs while every daemon is still serving the OLD binaries, so
/// asking a live daemon at that moment reports all ten as stale whether one changed or ten.
///
/// It NEVER ends a daemon. hostd owns the lifetime of the three it spawned and restarts the stale
/// ones at its next start (`SidecarVersionAuditor`); screend retires itself; superd is the user's
/// call because ending it ends every live pane. So the useful actions here are to SAY what changed
/// and to `--record` the baseline the next upgrade is diffed against — which is what a formula's
/// `post_install` runs, and the only reason the next diff can be about one tool rather than ten.
func cmdSidecars(_ rest: [String]) -> Never {
    var record = false
    var manifestOverride: String?
    var previousOverride: String?
    var index = 0
    while index < rest.count {
        let argument = rest[index]
        switch argument {
        case "--record": record = true
        case "--manifest":
            index += 1
            guard index < rest.count else { die("'--manifest' requires a path", code: 2) }
            manifestOverride = rest[index]
        case "--previous":
            index += 1
            guard index < rest.count else { die("'--previous' requires a path", code: 2) }
            previousOverride = rest[index]
        default:
            die("unknown flag '\(argument)' for sidecars (run with --help)", code: 2)
        }
        index += 1
    }

    let installed = manifestOverride.map(URL.init(fileURLWithPath:))
        ?? CLISidecars.installedManifestURL()
    guard let installed, let currentText = try? String(contentsOf: installed, encoding: .utf8) else {
        // Not a failure of the mechanism: a developer tree has no MANIFEST.json, because nothing
        // packaged it. Saying which file was looked for beats "no manifest".
        die("no MANIFEST.json — set \(CLISidecars.manifestEnvKey), or run this from an install", code: 4)
    }
    let recorded = previousOverride.map(URL.init(fileURLWithPath:)) ?? CLISidecars.recordedManifestURL()
    let previousText = recorded.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    let planJSON = CLISidecars.plan(previous: previousText, current: currentText)
    guard let data = planJSON.data(using: .utf8),
          let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let steps = plan["tools"] as? [[String: Any]]
    else { die("\(installed.path) is not a readable manifest", code: 4) }

    if invocation.format == .json {
        stdout(planJSON + "\n")
    } else {
        stdout(CLIFormatting.renderTable(
            headers: ["TOOL", "WAS", "NOW", "CHANGE", "NEXT"],
            rows: steps.map { step in
                [
                    step["tool"] as? String ?? "",
                    step["previous"] as? String ?? "—",
                    step["current"] as? String ?? "—",
                    step["change"] as? String ?? "",
                    step["note"] as? String ?? "",
                ]
            },
            noHeaders: invocation.noHeaders,
        ) + "\n")
    }

    if record {
        guard let recorded else { die("cannot resolve the Application Support container", code: 4) }
        do {
            try CLISidecars.record(currentText, to: recorded)
        } catch {
            // A record that could not be written costs one upgrade's worth of detail and nothing
            // else — the plan just above is still correct. Worth an exit code, not a lost report.
            die("recorded nothing to \(recorded.path): \(error.localizedDescription)", code: 5)
        }
    }
    exit(0)
}

// MARK: - Client control socket (AF_UNIX, NDJSON)

// The env var the running app exports + the CLI reads (kept in step with `ClientControlServer`).
let clientSocketEnvVar = "SLOPDESK_CLIENT_SOCKET"

/// Resolve the client control socket path: `--socket` > ``clientSocketEnvVar`` env > the Application
/// Support default. Mirrors `ClientControlServer.resolveSocketPath` so a separately-launched CLI and the
/// app agree without coordination.
func resolveClientSocketPath() -> String {
    if let explicit = invocation.socketPath, !explicit.isEmpty { return explicit }
    if let env = ProcessInfo.processInfo.environment[clientSocketEnvVar], !env.isEmpty { return env }
    let fileManager = FileManager.default
    let base = (try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false,
    )) ?? fileManager.temporaryDirectory
    return base
        .appendingPathComponent("SlopDesk", isDirectory: true)
        .appendingPathComponent("cli-control.sock", isDirectory: false)
        .path
}

/// Open an AF_UNIX connection, send `requestLine` + LF, read one response line (LF-terminated), and
/// return it (trailing LF stripped). Honors `--timeout` (recv/send). Compiled-only — never unit-tested
/// (no real socket in a unit test, hang-safety rule). Connect failure ⇒ "requires a running app" (exit 3).
func clientSendRequest(socketPath: String, requestLine: String) -> String {
    let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard socketPath.utf8.count <= maxPath else { die("socket path too long: \(socketPath)") }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket(2) failed: \(String(cString: strerror(errno)))") }
    defer { close(fd) }

    // Apply the IPC timeout to both directions.
    var timeout = timeval(
        tv_sec: invocation.timeoutMs / 1000,
        tv_usec: Int32((invocation.timeoutMs % 1000) * 1000),
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, maxPath)
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        die(
            "requires a running SlopDesk app (no control socket at \(socketPath): "
                + "\(String(cString: strerror(errno))))",
            code: 3,
        )
    }

    var line = requestLine
    if !line.hasSuffix("\n") { line += "\n" }
    let sendData = Data(line.utf8)
    // This one REPORTS: the CLI has nothing to fall back to, so a half-written request exits.
    switch FileDescriptorWrite.all(fd: fd, sendData) {
    case .complete: break
    case .peerClosed: die("write to control socket failed: the SlopDesk app closed the socket", code: 3)
    case let .failed(errno, _):
        die("write to control socket failed: \(String(cString: strerror(errno)))", code: 3)
    }

    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let maxBytes = 64 * 1024 * 64 // generous: a pane capture can be large
    outer: while response.count < maxBytes {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            die("timed out after \(invocation.timeoutMs)ms waiting for the SlopDesk app", code: 3)
        }
        if n <= 0 { break }
        for i in 0..<n {
            response.append(chunk[i])
            if chunk[i] == 0x0A { break outer }
        }
    }
    if response.last == 0x0A { response.removeLast() }
    guard let str = String(bytes: response, encoding: .utf8) else {
        die("response from the SlopDesk app is not valid UTF-8", code: 3)
    }
    return str
}

/// Encode + send one control request, returning the decoded response object. Dies on encode / transport /
/// decode failure.
func callClient(method: String, params: [String: Any]) -> [String: Any] {
    guard let line = ClientControlProtocol.encodeRequestLine(id: "1", method: method, params: params)
    else {
        die("failed to encode \(method) request as JSON")
    }
    let response = clientSendRequest(socketPath: resolveClientSocketPath(), requestLine: line)
    guard let obj = ClientControlProtocol.decodeResponseLine(response) else {
        die("malformed response from the SlopDesk app: \(response)", code: 3)
    }
    return obj
}

/// Require an `ok:true` response, returning its `result` object; dies with the server error otherwise.
@discardableResult
func requireResult(_ obj: [String: Any]) -> [String: Any] {
    if let ok = obj["ok"] as? Bool, ok { return obj["result"] as? [String: Any] ?? [:] }
    let message = obj["error"] as? String ?? "(no error message)"
    die("app error: \(message)")
}

/// Call a list method and render its `result[key]` rows via `render` (table by default, JSON under
/// `--json`), honoring `--no-headers`.
func emitList(
    method: String,
    params: [String: Any],
    key: String,
    render: ([[String: Any]], CLIOutputFormat, Bool) -> String,
) -> Never {
    let result = requireResult(callClient(method: method, params: params))
    let rows = result[key] as? [[String: Any]] ?? []
    stdout(render(rows, invocation.format, invocation.noHeaders) + "\n")
    exit(0)
}

// MARK: - window / tab / pane

func cmdWindowList(_ rest: [String]) -> Never {
    if let extra = rest.first { die("windows: unexpected argument '\(extra)'", code: 2) }
    emitList(
        method: ClientControlProtocol.Method.windows,
        params: ClientControlProtocol.windowsParams(),
        key: "windows",
        render: CLIFormatting.windows,
    )
}

func cmdWindow(_ rest: [String]) -> Never {
    switch rest.first {
    case nil,
         "list": cmdWindowList(Array(rest.dropFirst()))
    default: die("window: only 'list' is available (new/close land in later work items)", code: 2)
    }
}

func cmdTabList(_ rest: [String]) -> Never {
    var windowId: String?
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--window":
            guard idx + 1 < rest.count else { die("tab list: --window requires a value", code: 2) }
            idx += 1
            windowId = rest[idx]
        default: die("tab list: unknown argument '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    emitList(
        method: ClientControlProtocol.Method.tabs,
        params: ClientControlProtocol.tabsParams(windowId: windowId),
        key: "tabs",
        render: CLIFormatting.tabs,
    )
}

func cmdTabBadge(_ rest: [String]) -> Never {
    var kind: String?
    var tabId: String?
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--kind":
            guard idx + 1 < rest.count else { die("tab badge: --kind requires a value", code: 2) }
            idx += 1
            kind = rest[idx]
        case "--tab":
            guard idx + 1 < rest.count else { die("tab badge: --tab requires a value", code: 2) }
            idx += 1
            tabId = rest[idx]
        default: die("tab badge: unknown flag '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    guard let kind else {
        die("tab badge: requires --kind <running|completed|finished|unread|error|awaiting-input>", code: 2)
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.tabBadge,
        params: ClientControlProtocol.tabBadgeParams(kind: kind, tabId: tabId),
    ))
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else {
        stdout("badge: \(result["kind"] as? String ?? kind)\n")
    }
    exit(0)
}

func cmdTab(_ rest: [String]) -> Never {
    switch rest.first {
    case nil,
         "list": cmdTabList(Array(rest.dropFirst()))
    case "badge": cmdTabBadge(Array(rest.dropFirst()))
    default: die("tab: expected 'list' or 'badge'", code: 2)
    }
}

func cmdPaneList(_ rest: [String]) -> Never {
    var tabId: String?
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--tab":
            guard idx + 1 < rest.count else { die("pane list: --tab requires a value", code: 2) }
            idx += 1
            tabId = rest[idx]
        default: die("pane list: unknown argument '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    emitList(
        method: ClientControlProtocol.Method.panes,
        params: ClientControlProtocol.panesParams(tabId: tabId),
        key: "panes",
        render: CLIFormatting.panes,
    )
}

func cmdPaneCapture(_ rest: [String]) -> Never {
    var paneId: String?
    var lines = 100
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--pane":
            guard idx + 1 < rest.count else { die("pane capture: --pane requires a value", code: 2) }
            idx += 1
            paneId = rest[idx]
        case "--lines":
            guard idx + 1 < rest.count else { die("pane capture: --lines requires a value", code: 2) }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else {
                die("pane capture: --lines must be a positive integer", code: 2)
            }
            lines = n
        default: die("pane capture: unknown flag '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.paneCapture,
        params: ClientControlProtocol.paneCaptureParams(paneId: paneId, lines: lines),
    ))
    let captured = result["lines"] as? [String] ?? []
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(captured) + "\n")
    } else if !captured.isEmpty {
        stdout(captured.joined(separator: "\n") + "\n")
    }
    exit(0)
}

/// `pane send-keys [--pane <id>] -- "text..." key:Enter` — literal text + named keys (VERBATIM text; the
/// app maps named keys via the keycode path, never `SendKeysParser`). Tokens after `--` are operands:
/// `key:<Name>` is a named key, everything else is literal text (joined by a space).
func cmdPaneSendKeys(_ rest: [String]) -> Never {
    var paneId: String?
    var operands: [String] = []
    var afterSeparator = false
    var idx = 0
    while idx < rest.count {
        let token = rest[idx]
        if afterSeparator {
            operands.append(token)
        } else if token == "--pane" {
            guard idx + 1 < rest.count else { die("pane send-keys: --pane requires a value", code: 2) }
            idx += 1
            paneId = rest[idx]
        } else if token == "--" {
            afterSeparator = true
        } else {
            operands.append(token) // lenient: accept operands even without an explicit `--`
        }
        idx += 1
    }
    var textParts: [String] = []
    var keys: [String] = []
    for operand in operands {
        if operand.hasPrefix("key:") {
            let name = String(operand.dropFirst(4))
            if !name.isEmpty { keys.append(name) }
        } else {
            textParts.append(operand)
        }
    }
    let text = textParts.joined(separator: " ")
    guard !text.isEmpty || !keys.isEmpty else { die("pane send-keys: nothing to send", code: 2) }
    requireResult(callClient(
        method: ClientControlProtocol.Method.paneSendKeys,
        params: ClientControlProtocol.paneSendKeysParams(paneId: paneId, text: text, keys: keys),
    ))
    exit(0) // silent on success
}

func cmdPane(_ rest: [String]) -> Never {
    switch rest.first {
    case nil,
         "list": cmdPaneList(Array(rest.dropFirst()))
    case "capture": cmdPaneCapture(Array(rest.dropFirst()))
    case "send-keys": cmdPaneSendKeys(Array(rest.dropFirst()))
    default: die("pane: expected 'list', 'capture', or 'send-keys'", code: 2)
    }
}

// MARK: - config

func cmdConfig(_ rest: [String]) -> Never {
    guard let sub = rest.first else {
        die("config: requires path | edit | validate | schema | show | get", code: 2)
    }
    let args = Array(rest.dropFirst())
    switch sub {
    case "path": cmdConfigPath(args)
    case "edit": cmdConfigEdit(args)
    case "validate": cmdConfigValidate(args)
    case "schema": cmdConfigSchema(args)
    case "show": cmdConfigShow(args)
    case "get": cmdConfigGet(args)
    // The two that are GONE, named so the error says why rather than "unknown subcommand". The file
    // is the truth: a program that writes it makes a setting the user cannot see in their own file.
    case "set",
         "unset":
        die("config \(sub): removed — edit \(CLIConfig.path(override: invocation.configFile)) instead", code: 2)
    case "reload":
        die("config reload: removed — the app re-reads the file on its own", code: 2)
    default: die("config: unknown subcommand '\(sub)'", code: 2)
    }
}

/// One resolved value, bare, so a shell can capture it. A key the table does not declare exits 2; a
/// key it declares WITHOUT a default that the file never set exits 1 with "unset" — the two are
/// different questions and a script wants to tell them apart.
func cmdConfigGet(_ args: [String]) -> Never {
    guard let key = args.first, !key.hasPrefix("-") else { die("config get: requires <key>", code: 2) }
    if let extra = args.dropFirst().first { die("config get: unexpected argument '\(extra)'", code: 2) }
    let config = CLIConfig.loaded(override: invocation.configFile)
    guard config.declaredPaths.contains(key) else { die("config get: no such key '\(key)'", code: 2) }
    guard let value = CLIConfig.value(of: key, in: config) else {
        die("config get: '\(key)' is unset (the daemon's own default applies)", code: 1)
    }
    stdout(value + "\n")
    exit(0)
}

/// The whole resolved configuration as re-pasteable TOML.
func cmdConfigShow(_ args: [String]) -> Never {
    if let extra = args.first { die("config show: unexpected argument '\(extra)'", code: 2) }
    stdout(CLIConfig.show(CLIConfig.loaded(override: invocation.configFile)) + "\n")
    exit(0)
}

/// The JSON Schema every key is described by — the same text `docs/config.schema.json` holds.
func cmdConfigSchema(_ args: [String]) -> Never {
    if let extra = args.first { die("config schema: unexpected argument '\(extra)'", code: 2) }
    stdout(CLIConfig.schema + "\n")
    exit(0)
}

func cmdConfigPath(_ args: [String]) -> Never {
    if let extra = args.first { die("config path: unexpected argument '\(extra)'", code: 2) }
    stdout(CLIConfig.path(override: invocation.configFile) + "\n")
    exit(0)
}

/// Open the config file in `$EDITOR` (compiled-only — spawns a process). Creates the parent dir + an empty
/// file first so the editor opens cleanly.
func cmdConfigEdit(_ args: [String]) -> Never {
    if let extra = args.first { die("config edit: unexpected argument '\(extra)'", code: 2) }
    let path = CLIConfig.path(override: invocation.configFile)
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
    )
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    // `sh -c 'exec EDITOR "$0"' <path>` — passes the path as $0 so an $EDITOR with args (e.g. "code -w")
    // still works, with the path safely quoted.
    task.arguments = ["-c", "exec \(editor) \"$0\"", path]
    do {
        try task.run()
        task.waitUntilExit()
        exit(task.terminationStatus)
    } catch {
        die("failed to launch $EDITOR (\(editor)): \(error.localizedDescription)")
    }
}

/// Report every key the file gets wrong.
///
/// The verdict is the RESOLVER's, not a second grammar written here: the file is loaded exactly the
/// way the app loads it and the diagnostics it produced are printed. So a key this prints nothing
/// about is a key the app honours, and the two can never drift — the failure mode a hand-written
/// line checker had, where `font-size = 14` validated and was then ignored.
func cmdConfigValidate(_ args: [String]) -> Never {
    if let extra = args.first { die("config validate: unexpected argument '\(extra)'", code: 2) }
    let path = CLIConfig.path(override: invocation.configFile)
    guard FileManager.default.fileExists(atPath: path) else {
        stdout("valid (no config file at \(path) — the defaults are the whole configuration)\n")
        exit(0)
    }
    let problems = CLIConfig.diagnostics(override: invocation.configFile)
    guard problems.isEmpty else {
        for problem in problems {
            FileHandle.standardError.write(Data("\(programName): \(path): \(problem)\n".utf8))
        }
        exit(1)
    }
    stdout("valid: \(path)\n")
    exit(0)
}

// MARK: - font / keybind

func cmdFontList(_ rest: [String]) -> Never {
    var monospace = false
    var family: String?
    var scope: ClientControlProtocol.FontScope?
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--monospace": monospace = true
        case "--family":
            guard idx + 1 < rest.count else { die("font list: --family requires a value", code: 2) }
            idx += 1
            family = rest[idx]
        case "--system": scope = .system
        case "--user": scope = .user
        default: die("font list: unknown flag '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    emitList(
        method: ClientControlProtocol.Method.fontList,
        params: ClientControlProtocol.fontListParams(monospace: monospace, family: family, scope: scope),
        key: "fonts",
        render: CLIFormatting.fonts,
    )
}

/// `font import <path>` — install a `.ttf`/`.otf`/`.ttc`/`.dfont` into `~/Library/Fonts` (the user-domain
/// font dir macOS auto-activates) and print the family name Core Text reads out of it.
///
/// It does NOT apply the font. `--apply` used to write `font-family` into the running app, and there is no
/// writer any more — the config file is the only place a font is chosen. Printing the family name is the
/// half a program can do for you: the name is the awkward part (it is not the filename), and pasting it
/// under `[terminal]` is the part that belongs to the reader. Local filesystem op, no control socket.
func cmdFontImport(_ rest: [String]) -> Never {
    var path: String?
    for arg in rest {
        if arg == "--apply" {
            die(
                "font import: --apply is removed — put the printed family name under [terminal] in "
                    + CLIConfig.path(override: invocation.configFile),
                code: 2,
            )
        }
        if arg.hasPrefix("-") { die("font import: unknown flag '\(arg)'", code: 2) }
        if path == nil { path = arg } else { die("font import: unexpected argument '\(arg)'", code: 2) }
    }
    guard let path, !path.isEmpty else { die("font import: requires a <path>", code: 2) }
    #if os(macOS)
    // swiftlint:disable:next legacy_objc_type
    let srcURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: srcURL.path) else {
        die("font import: no such file '\(srcURL.path)'", code: 2)
    }
    let validExts: Set = ["ttf", "otf", "ttc", "dfont"]
    guard validExts.contains(srcURL.pathExtension.lowercased()) else {
        die("font import: '\(srcURL.lastPathComponent)' is not a font file (expected .ttf/.otf/.ttc/.dfont)", code: 2)
    }
    let fontsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts", isDirectory: true)
    try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
    let destURL = fontsDir.appendingPathComponent(srcURL.lastPathComponent)
    do {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: srcURL, to: destURL)
    } catch {
        die("font import: failed to install into ~/Library/Fonts: \(error.localizedDescription)")
    }
    let family = fontFamilyName(ofFileAt: destURL)
    if invocation.format == .json {
        var payload: [String: Any] = ["installed": destURL.path]
        if let family { payload["family"] = family }
        stdout(CLIFormatting.renderJSON(payload) + "\n")
    } else {
        stdout("imported font: \(destURL.lastPathComponent)\n")
        if let family {
            stdout("  [terminal]\n  font-family = \"\(family)\"\n")
        }
    }
    exit(0)
    #else
    die("font import is only supported on macOS")
    #endif
}

#if os(macOS)
/// The family name of the font file at `url` (the first descriptor's `kCTFontFamilyNameAttribute`), or `nil`
/// when Core Text cannot read it — the name `font import` prints for the reader to paste.
func fontFamilyName(ofFileAt url: URL) -> String? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          let first = descriptors.first else { return nil }
    return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
}
#endif

func cmdFont(_ rest: [String]) -> Never {
    switch rest.first {
    case "list": cmdFontList(Array(rest.dropFirst()))
    case "import": cmdFontImport(Array(rest.dropFirst()))
    case "apply":
        die(
            "font apply: removed — set font-family under [terminal] in "
                + CLIConfig.path(override: invocation.configFile),
            code: 2,
        )
    default: die("font: expected 'list', 'apply', or 'import'", code: 2)
    }
}

func cmdKeybindList(_ rest: [String]) -> Never {
    var action: String?
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--action":
            guard idx + 1 < rest.count else { die("keybind list: --action requires a value", code: 2) }
            idx += 1
            action = rest[idx]
        default: die("keybind list: unknown flag '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    emitList(
        method: ClientControlProtocol.Method.keybindList,
        params: ClientControlProtocol.keybindListParams(action: action),
        key: "keybinds",
        render: CLIFormatting.keybinds,
    )
}

func cmdKeybind(_ rest: [String]) -> Never {
    switch rest.first {
    case "list": cmdKeybindList(Array(rest.dropFirst()))
    default: die("keybind: only 'list' is available", code: 2)
    }
}

// MARK: - jump / learn / ignore (frecency)

/// `jump [query] [--no-cd]` — resolve a frecency-ranked directory and (unless `--no-cd`) send `cd <path>`
/// to the focused pane. No query toggles between `$HOME` and the last jump source. The app does the
/// resolution (the frecency DB is client-side); `--no-cd` just prints the resolved path.
func cmdJump(_ rest: [String]) -> Never {
    var query: String?
    var noCd = false
    for arg in rest {
        switch arg {
        case "--no-cd": noCd = true
        default:
            if arg.hasPrefix("-") { die("jump: unknown flag '\(arg)'", code: 2) }
            if query == nil { query = arg } else { die("jump: unexpected argument '\(arg)'", code: 2) }
        }
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.jump,
        params: ClientControlProtocol.jumpParams(query: query, noCd: noCd),
    ))
    let path = result["path"] as? String ?? ""
    let changed = (result["changed"] as? Bool) ?? false
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else if !changed {
        // `--no-cd` (or no focused pane to cd) → print the resolved path; a committed `cd` is silent.
        stdout(path + "\n")
    }
    exit(0)
}

/// `learn [path]` — record a directory visit in the frecency DB. No path records the focused pane's
/// cached cwd (the app reads the host cwd via OSC 7).
func cmdLearn(_ rest: [String]) -> Never {
    var path: String?
    for arg in rest {
        if arg.hasPrefix("-") { die("learn: unknown flag '\(arg)'", code: 2) }
        if path == nil { path = arg } else { die("learn: unexpected argument '\(arg)'", code: 2) }
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.learn,
        params: ClientControlProtocol.learnParams(path: path),
    ))
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else if let learned = result["path"] as? String {
        stdout("learned: \(learned)\n")
    }
    exit(0)
}

/// `ignore <path>` — remove a directory from the frecency DB.
func cmdIgnore(_ rest: [String]) -> Never {
    var path: String?
    for arg in rest {
        if arg.hasPrefix("-") { die("ignore: unknown flag '\(arg)'", code: 2) }
        if path == nil { path = arg } else { die("ignore: unexpected argument '\(arg)'", code: 2) }
    }
    guard let path else { die("ignore: requires a <path>", code: 2) }
    requireResult(callClient(
        method: ClientControlProtocol.Method.ignore,
        params: ClientControlProtocol.ignoreParams(path: path),
    ))
    exit(0) // silent on success
}

// MARK: - view / edit

/// Parse a `view`/`edit` invocation into `(target, placement)`: one positional `<path|url>` plus an optional
/// placement flag (`--new-tab` default / `--new-window` / `--left` / `--right` / `--top` / `--bottom`). Dies
/// (exit 2) on an unknown flag, a missing target, or a duplicate positional.
func parseShimArgs(_ verb: String, _ rest: [String]) -> (target: String, placement: ClientControlProtocol.Placement) {
    var target: String?
    var placement: ClientControlProtocol.Placement = .newTab
    for arg in rest {
        switch arg {
        case "--new-tab": placement = .newTab
        case "--new-window": placement = .newWindow
        case "--left": placement = .left
        case "--right": placement = .right
        case "--top": placement = .top
        case "--bottom": placement = .bottom
        default:
            if arg.hasPrefix("-") { die("\(verb): unknown flag '\(arg)'", code: 2) }
            if target == nil { target = arg } else { die("\(verb): unexpected argument '\(arg)'", code: 2) }
        }
    }
    guard let target, !target.isEmpty else { die("\(verb): requires a <path|url>", code: 2) }
    return (target, placement)
}

/// `view <path|url> [placement]` — open a READ-ONLY shim (`less <path>` / `open <url>`) in a new pane. NOT a
/// native local renderer — an slopdesk pane is a remote PTY; the shim types the command into a fresh split.
func cmdView(_ rest: [String]) -> Never {
    let (target, placement) = parseShimArgs("view", rest)
    requireResult(callClient(
        method: ClientControlProtocol.Method.view,
        params: ClientControlProtocol.viewParams(target: target, placement: placement),
    ))
    exit(0) // silent on success
}

/// `edit <path|url> [placement]` — open an EDITOR shim (`$EDITOR <path>`) in a new pane (see `cmdView`).
func cmdEdit(_ rest: [String]) -> Never {
    let (target, placement) = parseShimArgs("edit", rest)
    requireResult(callClient(
        method: ClientControlProtocol.Method.edit,
        params: ClientControlProtocol.editParams(target: target, placement: placement),
    ))
    exit(0) // silent on success
}

// MARK: - watch

/// Write raw bytes to this process's stdout (the controlling terminal / host PTY, where the host's
/// OSC sniffer reads them). Compiled-only — `watch` is never unit-tested (it spawns a subprocess).
func writeRaw(_ bytes: [UInt8]) {
    FileHandle.standardOutput.write(Data(bytes))
}

/// `watch [-q] <cmd> [args...]` — wrap a command so the tab shows an indeterminate spinner while it
/// runs and a success/error badge on exit, then post a "Notify on Watch Finish" desktop notification
/// unless `-q`/`--quiet`. The OSC 9;4 progress + OSC 9 notification BYTES are built by the pure,
/// tested `WatchProgress`; this shell only spawns the subprocess and writes those bytes.
///
/// Flag parsing stops at the first operand: a leading `-q`/`--quiet` is consumed, an optional bare
/// `--` ends option parsing, and everything from the first non-flag token onward is the wrapped
/// command + its args VERBATIM (so flags meant for the command are never re-interpreted here).
func cmdWatch(_ rest: [String]) -> Never {
    var quiet = false
    var command: [String] = []
    var collecting = false // once true, every remaining token is part of the wrapped command
    for token in rest {
        if collecting {
            command.append(token)
            continue
        }
        switch token {
        case "-q",
             "--quiet": quiet = true
        case "--": collecting = true // explicit end-of-options; the command starts after this
        default:
            // First operand: this and everything after it is the command, captured verbatim.
            command.append(token)
            collecting = true
        }
    }
    guard !command.isEmpty else { die("watch: requires a <command>", code: 2) }
    runWatch(command: command, quiet: quiet)
}

/// Spawn the wrapped command (PATH-resolved via `/usr/bin/env`, argv VERBATIM — no shell re-split),
/// bracketing it with the spinner + finish-badge OSC bytes and propagating its exit code. Compiled-
/// only (spawns a process); never instantiated in a unit test (hang-safety rule).
func runWatch(command: [String], quiet: Bool) -> Never {
    // Spinner up first so the badge is live the instant the command starts.
    writeRaw(WatchProgress.spinnerBytes)

    let task = Process()
    // `/usr/bin/env <cmd> <args…>` execs the command directly (PATH lookup, no shell), passing argv
    // unchanged. Shell features (pipes, &&) require an explicit `watch sh -c "…"`, by design.
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = command
    // Inherit stdin/stdout/stderr (the pane's PTY) so the command runs in-place and its OSC bytes —
    // and ours — flow through the same terminal the host sniffs.

    func finish(exitCode: Int32) -> Never {
        writeRaw(WatchProgress.finishBytes(exitCode: exitCode))
        if !quiet {
            // Emit the watch-finish-SPECIFIC notification form (OSC 777 carrying the WatchNotificationMarker
            // sentinel) so the host/client route it to NotificationEvent.watchFinish — gated by the dedicated
            // "Notify on Watch Finish" toggle, NOT the master switch. `-q`/`--quiet` is the LOCAL suppression.
            writeRaw(WatchProgress.watchFinishNotificationBytes(
                message: WatchProgress.finishMessage(command: command, exitCode: exitCode),
            ))
        }
        exit(exitCode)
    }

    do {
        try task.run()
    } catch {
        // Could not launch (e.g. command not found): show the error badge + notify, exit 127.
        FileHandle.standardError.write(
            Data("\(programName): watch: failed to run '\(command[0])': \(error.localizedDescription)\n".utf8),
        )
        finish(exitCode: 127)
    }
    task.waitUntilExit()
    // A signal-terminated child has no meaningful exit status; surface it as 128 + signo (non-zero →
    // error badge), the shell convention, so the badge + propagated code both reflect the failure.
    let raw = task.terminationStatus
    let exitCode: Int32 = task.terminationReason == .uncaughtSignal ? 128 &+ raw : raw
    finish(exitCode: exitCode)
}

// MARK: - watch:claude

/// `slopdesk watch:claude <id> [--block-timeout <ms>]` — block until the Claude session `<id>` reaches
/// an at-rest state (idle / done / closed), then exit. Polls the running app's `agent-status` method and
/// feeds each reply to the PURE, tested `WatchClaudeOutcome` state machine, which decides the exit code:
/// `0` = idle or session closed, `4` = the id was never seen, `9` = the BLOCK deadline elapsed while the
/// session was still active.
///
/// The block is UNBOUNDED by default (the spec's "block until idle"); the global `--timeout` bounds each
/// poll's IPC recv/send ONLY, never the block (a normal Claude turn far outlasts the 3 s IPC default).
/// `--block-timeout <ms>` opts into a bounded block (yielding exit `9`). Claude-only by design —
/// there is no `watch:codex`/`watch:opencode`. Requires a running SlopDesk app.
func cmdWatchClaude(_ rest: [String]) -> Never {
    var sessionId: String?
    var blockTimeoutMs: Int?
    var idx = 0
    while idx < rest.count {
        let arg = rest[idx]
        switch arg {
        case "--block-timeout":
            guard idx + 1 < rest.count else {
                die("watch:claude: --block-timeout requires a value (ms)", code: 2)
            }
            idx += 1
            guard let ms = Int(rest[idx]), ms > 0 else {
                die("watch:claude: --block-timeout must be a positive integer (ms)", code: 2)
            }
            blockTimeoutMs = ms
        default:
            if arg.hasPrefix("-") { die("watch:claude: unknown flag '\(arg)'", code: 2) }
            if sessionId == nil { sessionId = arg } else {
                die("watch:claude: unexpected argument '\(arg)'", code: 2)
            }
        }
        idx += 1
    }
    guard let sessionId, !sessionId.isEmpty else {
        die("watch:claude: requires a session <id>", code: 2)
    }
    runWatchClaude(id: sessionId, blockTimeoutMs: blockTimeoutMs)
}

/// Poll `agent-status` for `id` until `WatchClaudeOutcome` returns a terminal step, then exit with its
/// code. The BLOCK deadline is decoupled from the per-IPC `--timeout` (which only bounds each poll's
/// socket recv/send via `callClient`): `blockTimeoutMs == nil` ⇒ block indefinitely until the session
/// settles / closes / is never-seen; a positive `--block-timeout` bounds the block (exit `9`). Compiled-
/// only — it sleeps + does socket I/O, so it is never instantiated in a unit test (the exit-code DECISIONS
/// and the block-deadline policy live in the pure, tested `WatchClaudeOutcome`).
func runWatchClaude(id: String, blockTimeoutMs: Int?) -> Never {
    let pollIntervalNs: UInt64 = 250 * 1_000_000 // 250 ms between polls
    let startNs = DispatchTime.now().uptimeNanoseconds
    let deadlineNs = WatchClaudeOutcome.blockDeadlineNanos(startNanos: startNs, blockTimeoutMs: blockTimeoutMs)
    var hasEverBeenSeen = false

    while true {
        // One poll of the running app's rolled-up agent status (dies code 3 if the app isn't running).
        let result = requireResult(callClient(
            method: ClientControlProtocol.Method.agentStatus,
            params: ClientControlProtocol.agentStatusParams(id: id),
        ))
        let observation = WatchClaudeOutcome.observation(
            seen: result["seen"] as? Bool ?? false,
            statusToken: result["status"] as? String,
        )
        // A pane that resolves — whether or not its agent has reported a status yet — counts as "seen",
        // so a later disappearance reads as "closed" (exit 0), not "never seen" (exit 4).
        switch observation {
        case .status,
             .seenNoStatus: hasEverBeenSeen = true
        case .notSeen: break
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        // No deadline ⇒ never deadline-driven; with one, expired iff now ≥ it.
        let deadlineExceeded = deadlineNs.map { nowNs >= $0 } ?? false
        let step = WatchClaudeOutcome.decide(
            observation: observation,
            hasEverBeenSeen: hasEverBeenSeen,
            deadlineExceeded: deadlineExceeded,
        )
        switch step {
        case let .finished(outcome):
            exit(outcome.rawValue)
        case .keepPolling:
            // Sleep up to one poll interval; with a bounded block, never sleep past the deadline.
            var sleepNs = pollIntervalNs
            if let deadlineNs, deadlineNs > nowNs { sleepNs = min(pollIntervalNs, deadlineNs &- nowNs) }
            var ts = timespec(tv_sec: 0, tv_nsec: Int(sleepNs))
            _ = nanosleep(&ts, nil)
        }
    }
}

// MARK: - Entry point

let invocation: CLIInvocation
switch CLIArgs.parse(CommandLine.arguments) {
case let .success(inv):
    invocation = inv
case let .failure(err):
    switch err {
    case let .unknownFlag(flag): die("unknown flag '\(flag)' (run with --help)", code: 2)
    case let .missingValue(flag): die("'\(flag)' requires a value", code: 2)
    case let .invalidValue(flag, value): die("invalid value '\(value)' for \(flag)", code: 2)
    }
}

// Help wins over everything.
if invocation.wantsHelp || invocation.subcommand == "help" {
    printUsage()
    exit(0)
}

// Bare invocation (or `-e <cmd>`) → launch the GUI, forwarding any `-e` command to the first pane.
if invocation.launchGUI {
    launchClientGUI(forward: invocation.execCommand)
}

switch invocation.subcommand {
// Local ops (no running app).
case "version":
    stdout(CLIVersion.versionSummary() + "\n")
    exit(0)
case "completions":
    runCompletions(invocation.rest)
// App-driving list shortcuts (plural ≡ `<noun> list`).
case "windows":
    cmdWindowList(invocation.rest)
case "tabs":
    cmdTabList(invocation.rest)
case "panes":
    cmdPaneList(invocation.rest)
// App-driving nouns.
case "window":
    cmdWindow(invocation.rest)
case "tab":
    cmdTab(invocation.rest)
case "pane":
    cmdPane(invocation.rest)
case "config":
    cmdConfig(invocation.rest)
case "font":
    cmdFont(invocation.rest)
case "keybind":
    cmdKeybind(invocation.rest)
case "jump":
    cmdJump(invocation.rest)
case "learn":
    cmdLearn(invocation.rest)
case "ignore":
    cmdIgnore(invocation.rest)
case "view":
    cmdView(invocation.rest)
case "edit":
    cmdEdit(invocation.rest)
// In-pane op (no client socket): wrap a command with a spinner→badge + watch-finish notification.
case "watch":
    cmdWatch(invocation.rest)
// App-driving: block until a Claude session reaches idle/closed (exit 0/4/9).
case "watch:claude":
    cmdWatchClaude(invocation.rest)
// Local op (no running app, no daemon dialled): what the last upgrade changed, from two manifests.
case "sidecars":
    cmdSidecars(invocation.rest)
default:
    // Two different failures, and conflating them is what made the drift invisible. A verb the
    // vocabulary lists as PLANNED is real, designed and not built; a verb it does not list at all is
    // a typo. Neither is offered for completion, so neither can be reached by pressing Tab.
    if CLIUsage.planned.contains(invocation.subcommand) {
        die(
            "subcommand '\(invocation.subcommand)' is designed but not implemented yet "
                + "(run with --help — it is listed there under \"NOT yet implemented\")",
            code: 2,
        )
    }
    die("unknown subcommand '\(invocation.subcommand)' (run with --help)", code: 2)
}
