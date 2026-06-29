import AislopdeskCLICore
import AislopdeskCtlCore
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
#if os(macOS)
import CoreText
#endif
import Darwin
import Foundation

// aislopdesk — the user-facing CLI (otty-clone E20). One binary, a superset of `aislopdesk-ctl`:
//
//   aislopdesk                     launch the client GUI (like bare xterm/alacritty/ghostty)
//   aislopdesk -e <cmd> [args...]  launch the GUI + run <cmd> in the first pane (xterm `-e`)
//   aislopdesk version             print version + build hash + protocol summary  (local, no socket)
//   aislopdesk completions <shell> print a shell completion script                 (local, no socket)
//   aislopdesk -h | --help         usage
//
// App-driving subcommands (window/tab/pane/jump/view/edit/config/theme/font/keybind/watch/…) and
// the legacy agent ops (ipc/state:claude) are added by later E20 work items; this WI-1 scaffold
// lands the router + the local/GUI-launch ops. Unimplemented subcommands exit non-zero with a
// clear message rather than silently doing nothing.
//
// All socket I/O / GUI launch lives here (the compiled-only shell); the pure parse/version/
// completion logic lives in `AislopdeskCLICore` and is exhaustively unit-tested (hang-safety rule).

// MARK: - Fatal / output helpers

let programName = CommandLine.arguments.first
    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "aislopdesk"

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
    exit(code)
}

func stdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// MARK: - Usage

func printUsage() {
    stdout("""
    usage: \(programName) [global flags] <subcommand> [args...]
           \(programName)                 launch the client GUI
           \(programName) -e <cmd> [args...]   launch the GUI and run <cmd> in the first pane (xterm-style)

    Local subcommands (no running app required):
      version                 Print version, build hash, and a protocol/feature summary.
      completions <shell>     Print a completion script (bash, zsh, fish, elvish, powershell).
      config path             Print the resolved keybind config-file path.
      config edit             Open the keybind config file in $EDITOR.
      config validate         Check the keybind config file's syntax.

    App-driving subcommands (require a running Aislopdesk app):
      windows | window list                List windows.
      tabs    | tab list [--window <id>]   List tabs.
      panes   | pane list [--tab <id>]     List panes.
      tab badge --kind <kind> [--tab <id>] Set a tab status badge.
      pane capture [--pane <id>] [--lines N]   Capture the last N lines of a pane.
      pane send-keys [--pane <id>] -- "text" key:Enter   Send literal text + named keys.
      config get <key>                     Read a config key (running app).
      config set <key> <value> [--reload]  Write a config key (live + persisted).
      config unset <key>                   Remove a config key (-y to confirm).
      config show | config reload          Dump / broadcast-reload the running config.
      font list [--monospace] [--family <s>] [--system|--user]   List fonts.
      font apply "<name>"                  Set the terminal font family (running app).
      font import <path> [--apply]         Install a font into ~/Library/Fonts (optionally apply).
      theme list [--color <dark|light|all>]    List themes.
      theme import <path> [--activate] [--overwrite]   Import a theme file.
      keybind list [--action <s>]          List keybindings.
      jump [query] [--no-cd]               cd the focused pane to a frecency-ranked dir.
      learn [path]                         Record a directory visit (no path = focused pane cwd).
      ignore <path>                        Remove a directory from the frecency database.
      watch:claude <id> [--block-timeout <ms>]   Block until the Claude session <id> reaches
                                           idle/closed (blocks indefinitely by default; --block-timeout
                                           bounds it). --timeout is the per-poll IPC wait, NOT the block.
                                           Exit 0 (idle/closed) · 4 (id never seen) · 9 (block timed out).
      open <recipe>                        Open a .ottyrecipe (path or saved-library name).
      view <path|url> [placement]          Read-only shim (less <path> / open <url>) in a new pane.
      edit <path|url> [placement]          Editor shim ($EDITOR <path>) in a new pane.
                                           placement: --new-tab (default) | --new-window |
                                                      --left | --right | --top | --bottom

    In-pane subcommands (run inside a pane; no client socket required):
      watch [-q] <cmd> [args...]           Run <cmd> showing a spinner→success/error badge, then
                                           notify on finish (unless -q/--quiet). Put a bare `--`
                                           before <cmd> if it contains --json/--socket/etc.

    More app-driving subcommands (ipc, state:claude) are
    added by later work items.

    config: get/set/unset/show/reload target the LIVE running-app store (app keys like
    font-size/theme, over the socket). path/edit/validate target the on-disk KEYBIND config
    file: the app reads only its `keybind = <chord>:<action>` lines at launch — other keys in
    that file are ignored, and `config validate` flags them rather than calling them valid.

    Global flags:
      --json / --format json   Emit structured JSON for list/inspect output.
      --no-headers             Strip table header rows from text output.
      --socket PATH            Override the client control socket path.
      --config-file PATH       Override the config file location.
      --timeout MS             Per-request IPC wait for the running app (default \(CLIArgs.defaultTimeoutMs)).
                               Bounds each socket recv/send — NOT the watch:claude block (see --block-timeout).
      -y / --yes               Skip destructive-action confirmation prompts.
      -h / --help              Show this help.

    """)
}

// MARK: - GUI launch passthrough

/// Bundle identifier of the macOS client app (`Apps/ClientApp-macOS/project.yml`).
let clientBundleIdentifier = "com.aislopdesk.client.macos"

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
        die("failed to launch the Aislopdesk app: \(error.localizedDescription)")
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
    guard let line = encodeRequestLine(
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
    return sendData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        var offset = 0
        let total = raw.count
        while offset < total {
            let n = write(fd, base + offset, total - offset)
            if n > 0 { offset += n }
            else if n < 0, errno == EINTR { continue }
            else { return false }
        }
        return true
    }
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

// MARK: - Client control socket (AF_UNIX, NDJSON)

// The env var the running app exports + the CLI reads (kept in step with `ClientControlServer`).
let clientSocketEnvVar = "AISLOPDESK_CLIENT_SOCKET"

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
        .appendingPathComponent("Aislopdesk", isDirectory: true)
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
            "requires a running Aislopdesk app (no control socket at \(socketPath): "
                + "\(String(cString: strerror(errno))))",
            code: 3,
        )
    }

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
            else { die("write to control socket failed: \(String(cString: strerror(errno)))", code: 3) }
        }
    }

    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let maxBytes = 64 * 1024 * 64 // generous: a pane capture can be large
    outer: while response.count < maxBytes {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            die("timed out after \(invocation.timeoutMs)ms waiting for the Aislopdesk app", code: 3)
        }
        if n <= 0 { break }
        for i in 0..<n {
            response.append(chunk[i])
            if chunk[i] == 0x0A { break outer }
        }
    }
    if response.last == 0x0A { response.removeLast() }
    guard let str = String(bytes: response, encoding: .utf8) else {
        die("response from the Aislopdesk app is not valid UTF-8", code: 3)
    }
    return str
}

/// Encode + send one control request, returning the decoded response object. Dies on encode / transport /
/// decode failure.
func callClient(method: String, params: [String: Any]) -> [String: Any] {
    guard let line = encodeRequestLine(id: "1", method: method, params: params) else {
        die("failed to encode \(method) request as JSON")
    }
    let response = clientSendRequest(socketPath: resolveClientSocketPath(), requestLine: line)
    guard let obj = decodeResponseLine(response) else {
        die("malformed response from the Aislopdesk app: \(response)", code: 3)
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
        die("config: requires get | set | unset | show | reload | path | edit | validate", code: 2)
    }
    let args = Array(rest.dropFirst())
    switch sub {
    case "get": cmdConfigGet(args)
    case "set": cmdConfigSet(args)
    case "unset": cmdConfigUnset(args)
    case "show": cmdConfigShow(args)
    case "reload": cmdConfigReload(args)
    case "path": cmdConfigPath(args)
    case "edit": cmdConfigEdit(args)
    case "validate": cmdConfigValidate(args)
    default: die("config: unknown subcommand '\(sub)'", code: 2)
    }
}

func cmdConfigGet(_ args: [String]) -> Never {
    guard let key = args.first, !key.hasPrefix("-") else { die("config get: requires <key>", code: 2) }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.configGet,
        params: ClientControlProtocol.configGetParams(key: key),
    ))
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else if let value = result["value"] as? String {
        stdout(value + "\n")
    }
    exit(0)
}

func cmdConfigSet(_ args: [String]) -> Never {
    var positionals: [String] = []
    var transient = false
    var reload = false
    for arg in args {
        switch arg {
        case "--transient": transient = true
        case "--reload": reload = true
        default:
            if arg.hasPrefix("-") { die("config set: unknown flag '\(arg)'", code: 2) }
            positionals.append(arg)
        }
    }
    guard positionals.count >= 2 else { die("config set: requires <key> <value>", code: 2) }
    let key = positionals[0]
    let value = positionals[1...].joined(separator: " ")
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.configSet,
        params: ClientControlProtocol.configSetParams(key: key, value: value, transient: transient),
    ))
    if reload {
        requireResult(callClient(
            method: ClientControlProtocol.Method.configReload,
            params: ClientControlProtocol.configReloadParams(),
        ))
    }
    if invocation.format == .json { stdout(CLIFormatting.renderJSON(result) + "\n") }
    exit(0)
}

func cmdConfigUnset(_ args: [String]) -> Never {
    var key: String?
    var transient = false
    var reload = false
    for arg in args {
        switch arg {
        case "--transient": transient = true
        case "--reload": reload = true
        default:
            if arg.hasPrefix("-") { die("config unset: unknown flag '\(arg)'", code: 2) }
            if key == nil { key = arg } else { die("config unset: unexpected argument '\(arg)'", code: 2) }
        }
    }
    guard let key else { die("config unset: requires <key>", code: 2) }
    // Destructive op: gate behind -y/--yes (otty parity).
    guard invocation.assumeYes else {
        die("unset '\(key)' is destructive — pass -y/--yes to confirm", code: 1)
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.configUnset,
        params: ClientControlProtocol.configUnsetParams(key: key, transient: transient),
    ))
    if reload {
        requireResult(callClient(
            method: ClientControlProtocol.Method.configReload,
            params: ClientControlProtocol.configReloadParams(),
        ))
    }
    if invocation.format == .json { stdout(CLIFormatting.renderJSON(result) + "\n") }
    exit(0)
}

func cmdConfigShow(_ args: [String]) -> Never {
    if let extra = args.first { die("config show: unexpected argument '\(extra)'", code: 2) }
    emitList(
        method: ClientControlProtocol.Method.configShow,
        params: ClientControlProtocol.configShowParams(),
        key: "config",
        render: CLIFormatting.config,
    )
}

func cmdConfigReload(_ args: [String]) -> Never {
    if let extra = args.first { die("config reload: unexpected argument '\(extra)'", code: 2) }
    requireResult(callClient(
        method: ClientControlProtocol.Method.configReload,
        params: ClientControlProtocol.configReloadParams(),
    ))
    exit(0)
}

func cmdConfigPath(_ args: [String]) -> Never {
    if let extra = args.first { die("config path: unexpected argument '\(extra)'", code: 2) }
    stdout(CLIConfig.resolvePath(override: invocation.configFile) + "\n")
    exit(0)
}

/// Open the config file in `$EDITOR` (compiled-only — spawns a process). Creates the parent dir + an empty
/// file first so the editor opens cleanly.
func cmdConfigEdit(_ args: [String]) -> Never {
    if let extra = args.first { die("config edit: unexpected argument '\(extra)'", code: 2) }
    let path = CLIConfig.resolvePath(override: invocation.configFile)
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

func cmdConfigValidate(_ args: [String]) -> Never {
    if let extra = args.first { die("config validate: unexpected argument '\(extra)'", code: 2) }
    let path = CLIConfig.resolvePath(override: invocation.configFile)
    guard FileManager.default.fileExists(atPath: path) else {
        stdout("valid (no config file at \(path))\n")
        exit(0)
    }
    guard let data = FileManager.default.contents(atPath: path),
          let contents = String(data: data, encoding: .utf8)
    else { die("config validate: cannot read \(path)") }
    let errors = CLIConfig.validate(contents, isValidKeybindValue: { KeybindGrammar.parseLine($0) != nil })
    guard errors.isEmpty else {
        for error in errors {
            FileHandle.standardError.write(Data("\(programName): \(path):\(error.line): \(error.message)\n".utf8))
        }
        exit(1)
    }
    stdout("valid: \(path)\n")
    exit(0)
}

// MARK: - font / theme / keybind

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

/// `font apply "<name>"` — set the live terminal font family. Routes through the SAME running-app config path
/// as `config set font-family <name>` (the otty-documented mapping), so an unknown/empty name is an honest
/// `config set rejected` rather than a silent no-op.
func cmdFontApply(_ rest: [String]) -> Never {
    var name: String?
    for arg in rest {
        if arg.hasPrefix("-") { die("font apply: unknown flag '\(arg)'", code: 2) }
        if name == nil { name = arg } else { die("font apply: unexpected argument '\(arg)'", code: 2) }
    }
    guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        die("font apply: requires a font family <name>", code: 2)
    }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.configSet,
        params: ClientControlProtocol.configSetParams(key: "font-family", value: name, transient: false),
    ))
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else {
        stdout("applied font: \(name)\n")
    }
    exit(0)
}

/// `font import <path> [--apply]` — install a `.ttf`/`.otf`/`.ttc`/`.dfont` into `~/Library/Fonts` (the
/// user-domain font dir macOS auto-activates), then, with `--apply`, resolve the file's family name via Core
/// Text and route it through the `config set font-family` path. Local filesystem op (like `config edit`):
/// the copy needs no running app; only `--apply` opens the control socket. Compiled-only (spawns FS I/O).
func cmdFontImport(_ rest: [String]) -> Never {
    var path: String?
    var apply = false
    for arg in rest {
        switch arg {
        case "--apply": apply = true
        default:
            if arg.hasPrefix("-") { die("font import: unknown flag '\(arg)'", code: 2) }
            if path == nil { path = arg } else { die("font import: unexpected argument '\(arg)'", code: 2) }
        }
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
    if apply {
        guard let family else {
            die(
                "font import: installed '\(destURL.lastPathComponent)' but could not read its family name to --apply",
                code: 1,
            )
        }
        requireResult(callClient(
            method: ClientControlProtocol.Method.configSet,
            params: ClientControlProtocol.configSetParams(key: "font-family", value: family, transient: false),
        ))
    }
    if invocation.format == .json {
        var payload: [String: Any] = ["installed": destURL.path, "applied": apply]
        if let family { payload["family"] = family }
        stdout(CLIFormatting.renderJSON(payload) + "\n")
    } else {
        let famNote = family.map { " (\($0))" } ?? ""
        stdout("imported font: \(destURL.lastPathComponent)\(famNote)\(apply ? " — applied" : "")\n")
    }
    exit(0)
    #else
    die("font import is only supported on macOS")
    #endif
}

#if os(macOS)
/// The family name of the font file at `url` (the first descriptor's `kCTFontFamilyNameAttribute`), or `nil`
/// when Core Text cannot read it — used to drive `--apply` from an installed file.
func fontFamilyName(ofFileAt url: URL) -> String? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          let first = descriptors.first else { return nil }
    return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
}
#endif

func cmdFont(_ rest: [String]) -> Never {
    switch rest.first {
    case "list": cmdFontList(Array(rest.dropFirst()))
    case "apply": cmdFontApply(Array(rest.dropFirst()))
    case "import": cmdFontImport(Array(rest.dropFirst()))
    default: die("font: expected 'list', 'apply', or 'import'", code: 2)
    }
}

func cmdThemeList(_ rest: [String]) -> Never {
    var color: ClientControlProtocol.ThemeColorFilter = .all
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--color":
            guard idx + 1 < rest.count else { die("theme list: --color requires dark|light|all", code: 2) }
            idx += 1
            guard let parsed = ClientControlProtocol.themeColorFilter(forToken: rest[idx]) else {
                die("theme list: invalid --color '\(rest[idx])' (dark|light|all)", code: 2)
            }
            color = parsed
        default: die("theme list: unknown flag '\(rest[idx])'", code: 2)
        }
        idx += 1
    }
    emitList(
        method: ClientControlProtocol.Method.themeList,
        params: ClientControlProtocol.themeListParams(color: color),
        key: "themes",
        render: CLIFormatting.themes,
    )
}

func cmdThemeImport(_ rest: [String]) -> Never {
    var path: String?
    var activate = false
    var overwrite = false
    for token in rest {
        switch token {
        case "--activate": activate = true
        case "--overwrite": overwrite = true
        default:
            if token.hasPrefix("-") { die("theme import: unknown flag '\(token)'", code: 2) }
            if path == nil { path = token } else { die("theme import: unexpected argument '\(token)'", code: 2) }
        }
    }
    guard let path else { die("theme import: requires a <path>", code: 2) }
    let result = requireResult(callClient(
        method: ClientControlProtocol.Method.themeImport,
        params: ClientControlProtocol.themeImportParams(path: path, activate: activate, overwrite: overwrite),
    ))
    if invocation.format == .json {
        stdout(CLIFormatting.renderJSON(result) + "\n")
    } else {
        let slug = result["slug"] as? String ?? path
        stdout("imported theme: \(slug)\(activate ? " (activated)" : "")\n")
    }
    exit(0)
}

func cmdTheme(_ rest: [String]) -> Never {
    switch rest.first {
    case "list": cmdThemeList(Array(rest.dropFirst()))
    case "import": cmdThemeImport(Array(rest.dropFirst()))
    default: die("theme: expected 'list' or 'import'", code: 2)
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

// MARK: - open / view / edit (E20 WI-6)

/// `open <recipe>` — open a `.ottyrecipe` by path or a saved-library recipe by name. The running app parses
/// the file (`RecipeTOMLCodec`, validate-then-drop) or resolves the name from its saved library, then restores
/// it via `WorkspaceStore.openRecipe` — the SAME op File ▸ Open Recipe… drives (the E16 GUI open-recipe path;
/// only this CLI subcommand was deferred to E20). Silent on success.
func cmdOpen(_ rest: [String]) -> Never {
    var reference: String?
    for arg in rest {
        if arg.hasPrefix("-") { die("open: unknown flag '\(arg)'", code: 2) }
        if reference == nil { reference = arg } else { die("open: unexpected argument '\(arg)'", code: 2) }
    }
    guard let reference, !reference.isEmpty else {
        die("open: requires a <recipe> (a .ottyrecipe path or a saved-library name)", code: 2)
    }
    requireResult(callClient(
        method: ClientControlProtocol.Method.openRecipe,
        params: ClientControlProtocol.openRecipeParams(reference: reference),
    ))
    exit(0) // silent on success
}

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
/// native local renderer — an aislopdesk pane is a remote PTY; the shim types the command into a fresh split.
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

// MARK: - watch (E20 WI-7)

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

// MARK: - watch:claude (E20 WI-8)

/// `aislopdesk watch:claude <id> [--block-timeout <ms>]` — block until the Claude session `<id>` reaches
/// an at-rest state (idle / done / closed), then exit. Polls the running app's `agent-status` method and
/// feeds each reply to the PURE, tested `WatchClaudeOutcome` state machine, which decides the exit code:
/// `0` = idle or session closed, `4` = the id was never seen, `9` = the BLOCK deadline elapsed while the
/// session was still active.
///
/// The block is UNBOUNDED by default (the spec's "block until idle"); the global `--timeout` bounds each
/// poll's IPC recv/send ONLY, never the block (a normal Claude turn far outlasts the 3 s IPC default).
/// `--block-timeout <ms>` opts into a bounded block (yielding exit `9`). Claude-only — there is no
/// `watch:codex`/`watch:opencode` (E20 exclusion §4). Requires a running Aislopdesk app.
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
case "theme":
    cmdTheme(invocation.rest)
case "keybind":
    cmdKeybind(invocation.rest)
case "jump":
    cmdJump(invocation.rest)
case "learn":
    cmdLearn(invocation.rest)
case "ignore":
    cmdIgnore(invocation.rest)
case "open":
    cmdOpen(invocation.rest)
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
default:
    // ipc/state:claude land in later E20 work items.
    die("subcommand '\(invocation.subcommand)' is not available yet (run with --help)", code: 2)
}
