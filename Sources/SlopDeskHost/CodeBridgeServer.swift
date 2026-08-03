import Foundation

/// The host end of the embedded editor's command channel — see
/// `Sources/SlopDeskHost/Resources/bridge/extension.js` for the other end and the message set.
///
/// The seam ``CodeServerManager`` opens files through. Production is ``CodeBridgeServer``; unit
/// tests inject a fake, because binding an `AF_UNIX` listener is exactly the kind of real socket
/// hang-safety keeps out of the test suite.
protocol CodeBridgeRouting: AnyObject, Sendable {
    /// Binds the listener at `path` (idempotent — a second call on a bound server is a no-op).
    /// Failures are silent: the bridge is an ACCELERATOR, and a host that cannot bind still opens
    /// files through the `code-server -r` CLI.
    func start(path: String)
    /// Asks the workbench window that owns `target` to open it. `false` = no connected window
    /// claims the path (nothing booted yet, or the file lives outside every open folder), which is
    /// the caller's signal to fall back to the CLI.
    func open(target: String) -> Bool
    /// Installs what happens when the editor asks to type into a terminal pane. `nil` (the default)
    /// refuses every such request — the bridge is wired by ``HostServer``, and a manager standing
    /// alone in a test has no sessions to type into.
    func setTerminalRunner(_ runner: (@Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome)?)
    /// Closes the listener, drops every connection, unlinks the socket file. Idempotent.
    func stop()
}

/// The editor asking for a command line to be typed into one of this project's terminal panes.
struct CodeBridgeRunRequest: Sendable, Equatable {
    /// The workbench window's workspace folder — the project the command belongs to.
    let root: String
    /// The acting file's directory, when the request came from one. Ranking only (see
    /// ``CodeBridgeTerminalRouter/choose(among:root:near:)``).
    let directory: String?
    /// The command line itself, exactly as it will be typed.
    let text: String
}

/// What became of it. `paneTitle` names where it landed so the editor can say so; `message` is the
/// sentence shown when it did not.
struct CodeBridgeRunOutcome: Sendable, Equatable {
    let ok: Bool
    let paneTitle: String?
    let message: String?

    static func landed(in paneTitle: String) -> Self {
        Self(ok: true, paneTitle: paneTitle, message: nil)
    }

    static func refused(_ message: String) -> Self {
        Self(ok: false, paneTitle: nil, message: message)
    }
}

/// Accepts the bridge extension's connections and routes open-commands to the right one.
///
/// **Both directions, and they do not share a shape.** The host COMMANDS (`open`) with no reply
/// expected — those writes originate on whatever thread `CodeServerManager.openInWorkbench` runs
/// on. The extension REQUESTS (`run`/`cd`, carrying a correlation id) and is answered on the same
/// connection, from the per-connection read thread — which is also where the installed terminal
/// runner executes, so it must be quick and thread-safe (it is: a session snapshot under
/// `HostServer`'s lock, then one PTY write).
///
/// **One connection per workbench window.** code-server runs a remote extension host per window,
/// each activating this extension, so the connection set is "the windows currently open" and the
/// `root` each one announces is its workspace folder. That is what makes routing possible at all:
/// the CLI's `-r` picks the most recently registered session, whereas ``route(target:among:)``
/// picks the window whose folder actually contains the file.
///
/// **Compiled + code-reviewed only** — never bound in a unit test. The pure routing and encoding
/// halves below are tested directly.
final class CodeBridgeServer: CodeBridgeRouting, @unchecked Sendable {
    /// One connected workbench window.
    private struct Connection {
        let fd: Int32
        var root: String
    }

    /// Max bytes per line the extension may send (validate-then-drop beyond it). The largest
    /// inbound message is a `run` carrying an editor selection, capped far below this by
    /// ``maxRunTextBytes``.
    static let maxLineBytes = 64 * 1024

    /// Max bytes of command text a single `run` may carry. An editor selection is the source, and
    /// a selection large enough to exceed this was not meant to be typed at a shell prompt.
    static let maxRunTextBytes = 8 * 1024

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPath: String?
    private var connections: [Int32: Connection] = [:]
    private var terminalRunner: (@Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome)?

    var onLog: (@Sendable (String) -> Void)?

    func setTerminalRunner(_ runner: (@Sendable (CodeBridgeRunRequest) -> CodeBridgeRunOutcome)?) {
        lock.lock()
        terminalRunner = runner
        lock.unlock()
    }

    // MARK: Lifecycle

    func start(path: String) {
        lock.lock()
        let alreadyBound = listenFD >= 0
        lock.unlock()
        guard !alreadyBound else { return }

        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxPath else { return }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, maxPath,
                )
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        // Same-uid only, like every other socket hostd binds.
        Darwin.chmod(path, 0o600)

        lock.lock()
        listenFD = fd
        boundPath = path
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd) }
        onLog?("code-bridge socket listening at \(path)")
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        let path = boundPath
        let open = connections.keys
        listenFD = -1
        boundPath = nil
        connections.removeAll()
        lock.unlock()
        for connection in open { close(connection) }
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    // MARK: Commanding

    func open(target: String) -> Bool {
        lock.lock()
        let candidates = connections.values.map { (fd: $0.fd, root: $0.root) }
        lock.unlock()

        let (path, _) = HostCodeServerPerformer.splitLineColSuffix(target)
        guard let fd = Self.route(target: path, among: candidates),
              let command = Self.openCommand(target: target)
        else { return false }
        return write(command, to: fd)
    }

    /// The window that should own `target`: the connection whose workspace folder CONTAINS it,
    /// deepest folder first (nested checkouts open as separate windows, and the inner one is the
    /// better home for a file inside it). `nil` when no open folder contains the path — the caller
    /// falls back to the CLI rather than dropping a file into an unrelated project's window.
    /// Ties break on the lower fd, so the routing is deterministic for a given connection set.
    static func route(target: String, among candidates: [(fd: Int32, root: String)]) -> Int32? {
        let owning = candidates.filter { contains(root: $0.root, path: target) }
        guard var best = owning.first else { return nil }
        for candidate in owning.dropFirst() {
            let deeper = candidate.root.count > best.root.count
            let tie = candidate.root.count == best.root.count && candidate.fd < best.fd
            if deeper || tie { best = candidate }
        }
        return best.fd
    }

    /// Whether `path` lives under `root` — a path-component containment test, so `/a/bee` is not
    /// treated as a child of `/a/b`. An empty root (a window with no folder open) contains nothing.
    static func contains(root: String, path: String) -> Bool {
        guard !root.isEmpty, path.hasPrefix(root) else { return false }
        if root == path { return true }
        return root.hasSuffix("/") || path.dropFirst(root.count).hasPrefix("/")
    }

    /// The `open` line for `target` (`path[:line[:col]]`), or `nil` when the path will not encode.
    /// JSON is built through `JSONSerialization` — host paths carry quotes and backslashes, and a
    /// hand-rolled string would hand the extension a line it silently drops.
    static func openCommand(target: String) -> String? {
        let (path, suffix) = HostCodeServerPerformer.splitLineColSuffix(target)
        var message: [String: Any] = ["t": "open", "path": path]
        let numbers = suffix.split(separator: ":").compactMap { Int($0) }
        if let line = numbers.first { message["line"] = line }
        if numbers.count > 1 { message["col"] = numbers[1] }
        guard let encoded = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: encoded, encoding: .utf8)
        else { return nil }
        return line + "\n"
    }

    // MARK: Accept loop

    private func acceptLoop(fd listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { return } // listener closed by stop() → exit
            // The host writes to this fd from the metadata queue long after the peer may have gone;
            // without SO_NOSIGPIPE that write raises SIGPIPE and takes hostd down with it.
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            connections[conn] = Connection(fd: conn, root: "")
            lock.unlock()
            Thread.detachNewThread { [weak self] in
                self?.readLoop(fd: conn)
                self?.drop(fd: conn)
            }
        }
    }

    /// Reads the peer's NDJSON until EOF. The only message that means anything is the opening
    /// `hello`, whose `root` makes the connection routable.
    private func readLoop(fd: Int32) {
        var buffer = Data()
        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read <= 0 { return } // EOF or error
            buffer.append(contentsOf: chunk[0..<read])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard line.count <= Self.maxLineBytes else { continue }
                switch Self.inbound(in: line) {
                case let .hello(root):
                    note(root: root, fd: fd)
                case let .run(id, request):
                    perform(runID: id, request: request, from: fd)
                case nil:
                    continue
                }
            }
            // A peer that never sends a newline must not grow the buffer without bound.
            if buffer.count > Self.maxLineBytes { buffer.removeAll() }
        }
    }

    /// A line the extension sent, once it has been believed. `nil` for everything else
    /// (validate-then-drop: malformed JSON, an unknown verb, a relative path, oversized text).
    enum Inbound: Equatable {
        /// The opening announcement — the window's workspace folder, which is what makes it
        /// routable.
        case hello(root: String)
        /// A command line to type into one of this project's terminal panes. `id` is the
        /// extension's correlation token, echoed back in the result.
        case run(id: String, request: CodeBridgeRunRequest)
    }

    static func inbound(in line: Data) -> Inbound? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let verb = object["t"] as? String
        else { return nil }
        switch verb {
        case "hello":
            guard let root = object["root"] as? String, root.hasPrefix("/") else { return nil }
            return .hello(root: root)
        case "run":
            return runInbound(object)
        case "cd":
            // The editor names a directory; the host builds the command line, so the shell
            // quoting has ONE tested home rather than a second copy written in JavaScript.
            guard let path = object["path"] as? String, path.hasPrefix("/") else { return nil }
            return runInbound(object, text: CodeBridgeTerminalRouter.changeDirectoryCommandLine(path))
        default:
            return nil
        }
    }

    /// The shared `run`/`cd` shape: correlation id, project root, optional acting directory, and
    /// the text (carried by a `run`, built by the host for a `cd`).
    private static func runInbound(_ object: [String: Any], text built: String? = nil) -> Inbound? {
        guard let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 64,
              let root = object["root"] as? String, root.hasPrefix("/"),
              let text = built ?? object["text"] as? String,
              isTypeable(text)
        else { return nil }
        let directory = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        return .run(
            id: id, request: CodeBridgeRunRequest(root: root, directory: directory, text: text),
        )
    }

    /// Whether `text` may be typed at a live shell prompt. Non-empty, within
    /// ``maxRunTextBytes``, and free of C0 control characters other than tab and newline — an
    /// embedded ESC in a selection is not text to a shell's line editor, it is a keybinding
    /// (`vi` mode makes that vivid), and NUL truncates. A selection carrying one is refused
    /// rather than reinterpreted.
    static func isTypeable(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxRunTextBytes else { return false }
        return !text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\n" && scalar != "\t") || scalar.value == 0x7F
        }
    }

    /// The result line for a finished `run`, or `nil` when it will not encode.
    static func resultLine(id: String, outcome: CodeBridgeRunOutcome) -> String? {
        var message: [String: Any] = ["t": "result", "id": id, "ok": outcome.ok]
        if let paneTitle = outcome.paneTitle { message["pane"] = paneTitle }
        if let text = outcome.message { message["message"] = text }
        guard let encoded = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: encoded, encoding: .utf8)
        else { return nil }
        return line + "\n"
    }

    /// Runs one request through the installed runner and answers the window that asked. No runner
    /// installed (a manager standing alone) reads as a refusal, never as silence — the editor is
    /// waiting on this line to tell the user something.
    private func perform(runID: String, request: CodeBridgeRunRequest, from fd: Int32) {
        lock.lock()
        let runner = terminalRunner
        lock.unlock()
        let outcome = runner?(request)
            ?? .refused("SlopDesk: this host cannot reach a terminal pane right now.")
        if let line = Self.resultLine(id: runID, outcome: outcome) { _ = write(line, to: fd) }
    }

    private func note(root: String, fd: Int32) {
        lock.lock()
        connections[fd]?.root = root
        lock.unlock()
        onLog?("code-bridge: workbench window attached for \(root)")
    }

    private func drop(fd: Int32) {
        lock.lock()
        let known = connections.removeValue(forKey: fd) != nil
        lock.unlock()
        if known { close(fd) }
    }

    /// Writes one command line, handling EINTR and partial writes. A failed write drops the
    /// connection: the peer is gone, and a half-written line would desynchronise its parser.
    private func write(_ line: String, to fd: Int32) -> Bool {
        let data = Data(line.utf8)
        let wrote = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !wrote { drop(fd: fd) }
        return wrote
    }
}
