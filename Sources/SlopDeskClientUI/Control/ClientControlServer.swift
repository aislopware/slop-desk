// E20 WI-3 — Client control socket server (AF_UNIX, NDJSON).
//
// The CLIENT-side runtime control surface the new `slopdesk` CLI talks to (windows/tabs/panes, badges,
// jump/view/edit, config, theme/font/keybind dumps, pane capture/send-keys, agent status). It MIRRORS the
// host's `AgentControlAcceptor` (`SlopDeskHost/AgentControlListener.swift`): an `AF_UNIX` stream socket
// bound at a stable path, one background thread per accepted connection reading NDJSON request lines
// (`{"id":…,"method":…,"params":{…}}`), each dispatched to the PURE ``ClientControlDispatcher`` (WI-2) and
// answered with a response line. It reuses the SAME line protocol the host socket / `SlopDeskCtlCore`
// speak — only the verb set differs (GUI ops vs host PTY ops).
//
// ## Hang-safety (compiled-only, never unit-tested)
// Exactly like `AgentControlAcceptor`, the accept loop + each connection's blocking `read(2)` loop run on
// **dedicated background threads** (never the Swift cooperative pool), so a blocked socket read never parks
// a concurrency thread. The dispatcher it calls is `@MainActor` (it touches the live GUI stores), so each
// request hops to the main actor for the dispatch decision and writes the reply back off-main. This server
// is **compiled + code-reviewed only** — it is NEVER instantiated in a test (no real socket in a unit test,
// the same rule that excludes `AgentControlAcceptor`); the pure dispatcher is tested separately with a fake
// backend (WI-2).
//
// ## Validate-then-drop
// A request line that is non-UTF-8, over ``maxRequestBytes``, blank, or structurally malformed receives an
// error response (id `"?"`) — the server never traps on hostile input. The trust boundary is the same
// same-uid AF_UNIX socket the host uses (chmod 0600); no app-layer crypto/tokens (CLAUDE.md #8).

#if canImport(SwiftUI)
import Darwin
import Foundation
import SlopDeskWorkspaceCore // ClientControlDispatcher + ClientControlBackend

/// The thin `AF_UNIX` NDJSON server for the client control plane. Binds a stable socket, accepts
/// connections, and routes each request line through the PURE ``ClientControlDispatcher`` over a
/// ``ClientControlBackend``. `@unchecked Sendable`: the listen fd + bound path are guarded by an `NSLock`
/// and the backend is reached only through a main-actor hop (see ``BackendBox``).
final class ClientControlServer: @unchecked Sendable {
    /// The resolved socket path this server binds (env override or the Application Support default).
    let socketPath: String
    /// Optional diagnostics sink (stderr / os_log), set by the app before ``start()``.
    var onLog: (@Sendable (String) -> Void)?

    private let backendBox: BackendBox
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPath: String?

    /// Max bytes per request line (validate-then-drop beyond this) — matches the host ctl socket + the
    /// dispatcher's own `maxRequestBytes`.
    static let maxRequestBytes = 64 * 1024

    /// The env var the running app exports + the CLI reads to find the socket (the `--socket` flag overrides
    /// it on the CLI side; this server only resolves env > default).
    static let socketEnvVar = "SLOPDESK_CLIENT_SOCKET"

    /// Carries the `@MainActor` backend across the connection-thread boundary. `@unchecked Sendable`: the
    /// reference is only ever DEREFERENCED inside a `Task { @MainActor in … }` hop (``dispatchOnMain(line:box:)``),
    /// so no main-actor state is touched off-main.
    private final class BackendBox: @unchecked Sendable {
        let backend: any ClientControlBackend
        init(_ backend: any ClientControlBackend) { self.backend = backend }
    }

    /// - Parameters:
    ///   - backend: the live-store adapter the dispatcher drives.
    ///   - socketPath: where to bind. Defaults to ``resolveSocketPath(environment:)`` (env > Application
    ///     Support default).
    @MainActor
    init(backend: any ClientControlBackend, socketPath: String = ClientControlServer.resolveSocketPath()) {
        backendBox = BackendBox(backend)
        self.socketPath = socketPath
    }

    // MARK: - Socket path resolution

    /// `SLOPDESK_CLIENT_SOCKET` env override, else the stable Application Support default. (The CLI's
    /// `--socket` flag is a front-end concern resolved on the CLI side before it connects.)
    static func resolveSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[socketEnvVar],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return override
        }
        return defaultSocketPath()
    }

    /// `<Application Support>/SlopDesk/cli-control.sock` (sibling of `workspace.json` /
    /// `folders-frecency.json`), falling back to a temp dir if Application Support cannot be resolved.
    static func defaultSocketPath(using fileManager: FileManager = .default) -> String {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("cli-control.sock", isDirectory: false)
            .path
    }

    // MARK: - Lifecycle

    /// Binds the socket at ``socketPath`` (chmod 0600), publishes the path into the process env so spawned
    /// children can reach it, and begins accepting. Throws on a path that is too long for `sun_path` or a
    /// bind/listen failure. Idempotent-ish: a stale socket file is unlinked first (single-user tool — the
    /// newest app owns the stable path, mirroring the host's unlink-then-bind).
    func start() throws {
        // Idempotent: a scene `.task` can re-fire (e.g. a second window) — never double-bind the socket.
        lock.lock()
        let alreadyBound = listenFD >= 0
        lock.unlock()
        if alreadyBound { return }

        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard socketPath.utf8.count <= maxPath else {
            throw ClientControlSocketError.pathTooLong(socketPath)
        }

        // Best-effort parent-dir creation (Application Support/SlopDesk) — a missing dir would fail bind.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientControlSocketError.socketFailed(errno) }

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
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw ClientControlSocketError.bindFailed(e)
        }

        // Restrict to the running user (same uid only — the same posture as the host ctl socket).
        Darwin.chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw ClientControlSocketError.listenFailed(e)
        }

        lock.lock()
        listenFD = fd
        boundPath = socketPath
        lock.unlock()

        // Publish the resolved path so a child process the app spawns inherits it (the CLI front-end reads
        // `SLOPDESK_CLIENT_SOCKET`). Best-effort; a separately-launched CLI computes the same default.
        setenv(Self.socketEnvVar, socketPath, 1)

        let box = backendBox
        let log = onLog
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd, box: box, log: log) }
        onLog?("client-control socket listening at \(socketPath)")
    }

    /// Closes the listener and unlinks the socket file. Idempotent.
    func stop() {
        lock.lock()
        let fd = listenFD
        let path = boundPath
        listenFD = -1
        boundPath = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    // MARK: - Accept loop

    private func acceptLoop(fd listenFD: Int32, box: BackendBox, log: (@Sendable (String) -> Void)?) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { return } // listen fd closed by stop() → exit
            Thread.detachNewThread {
                Self.serveConnection(fd: conn, box: box, log: log)
                close(conn)
            }
        }
    }

    // MARK: - Per-connection NDJSON loop

    /// Reads NDJSON lines from `fd`, dispatches each to the `@MainActor` ``ClientControlDispatcher`` (via a
    /// main-actor hop), writes the response, and loops until EOF or an I/O error. Connections are long-lived
    /// (the CLI may pipeline requests).
    private static func serveConnection(fd: Int32, box: BackendBox, log: (@Sendable (String) -> Void)?) {
        var lineBuffer = Data()

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // EOF or error — connection closed

            lineBuffer.append(contentsOf: chunk[0..<n])

            // Process every complete '\n'-delimited line in the buffer.
            while let nlIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[lineBuffer.startIndex..<nlIndex]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: nlIndex)...])

                // Validate-then-drop: oversized or non-UTF-8 request lines.
                guard lineData.count <= maxRequestBytes else {
                    writeAll(fd: fd, data: Data(Self.errorLine(message: "request too large").utf8))
                    continue
                }
                guard let line = String(bytes: lineData, encoding: .utf8) else {
                    writeAll(fd: fd, data: Data(Self.errorLine(message: "invalid UTF-8").utf8))
                    continue
                }

                // Dispatch on the main actor (the backend touches @MainActor stores) and write the reply.
                if let response = dispatchOnMain(line: line, box: box) {
                    writeAll(fd: fd, data: Data(response.utf8))
                }
            }

            // Drop an oversized partial line (validate-then-drop) so a hostile, newline-less stream can't
            // grow the buffer without bound.
            if lineBuffer.count > maxRequestBytes {
                log?("client-control: oversized partial line (\(lineBuffer.count) bytes) — discarding")
                lineBuffer.removeAll(keepingCapacity: false)
            }
        }
    }

    /// Run the `@MainActor` ``ClientControlDispatcher`` for one request line and return the response line,
    /// hopping to the main actor synchronously. The connection thread blocks on a semaphore — it is OFF the
    /// cooperative pool, and the main actor is NEVER blocked waiting on it (so there is no deadlock). Mirrors
    /// the host's `AgentControlHandler.await_spawnStandalonePane` Task+semaphore bridge, kept Swift-6-clean
    /// (no `DispatchQueue.main.sync`, which the codebase avoids — `SerialFeedGate`).
    private static func dispatchOnMain(line: String, box: BackendBox) -> String? {
        final class ResultBox: @unchecked Sendable { var value: String? }
        let result = ResultBox()
        let sema = DispatchSemaphore(value: 0)
        Task { @MainActor in
            result.value = ClientControlDispatcher(backend: box.backend).handleLine(line)
            sema.signal()
        }
        sema.wait()
        return result.value
    }

    /// A minimal NDJSON error line for the socket-layer drops (the dispatcher owns the in-band errors).
    private static func errorLine(message: String) -> String {
        let obj: [String: Any] = ["id": "?", "ok": false, "error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(bytes: data, encoding: .utf8)
        else { return #"{"id":"?","ok":false,"error":"encode failure"}"# + "\n" }
        return str + "\n"
    }

    // MARK: - writeAll (handles EINTR + partial writes)

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    return
                } else {
                    return
                }
            }
        }
    }
}

/// Bind-time failures for the client control socket (mirrors the host's `AgentSocketError`).
enum ClientControlSocketError: Error {
    case pathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
#endif
