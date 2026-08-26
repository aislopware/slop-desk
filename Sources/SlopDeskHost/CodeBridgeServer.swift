import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskTTY

/// The host end of the embedded editor's command channel — see
/// `rust/slopdesk-codeseed/resources/bridge/extension.js` for the other end and the message set.
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
    /// ``maxRunTextBytes``. The number is `slopdesk-muxsession`'s — this side only enforces it,
    /// because this side is the one holding the buffer.
    static let maxLineBytes = slopdesk_code_bridge_max_line_bytes()

    /// Max bytes of command text a single `run` may carry. An editor selection is the source, and
    /// a selection large enough to exceed this was not meant to be typed at a shell prompt.
    static let maxRunTextBytes = slopdesk_code_bridge_max_run_text_bytes()

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPath: String?
    /// `(st_dev, st_ino)` of the socket file this server created, captured right after `bind`. The
    /// path is pid-free and shared with every other hostd on the machine
    /// (``CodeSeed/Paths/bridgeSocket``), so
    /// "is this still my socket file?" is the only question ``stop`` may act on — see there.
    private var boundIdentity: (dev: dev_t, ino: ino_t)?
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
        boundIdentity = Self.identity(ofFileAt: path)
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd) }
        onLog?("code-bridge socket listening at \(path)")
    }

    /// Stops listening and drops every window connection.
    ///
    /// The socket file is removed only if it is still the one this server created. The name is
    /// pid-free by design (``CodeSeed/Paths/bridgeSocket``), so between this server's `bind`
    /// and this `stop` a SECOND hostd may have unlinked it and bound its own — and an unconditional
    /// `unlink(path)` here would delete that live host's name out from under it. Nothing would put
    /// it back: the victim's ``start(path:)`` returns early while it is bound, so its extension
    /// hosts would reconnect for five minutes to a name nobody holds, and open-file and
    /// run-in-terminal would stop working with no error anywhere. Comparing `(st_dev, st_ino)`
    /// against what we recorded at bind time is exact: a rebind is a new inode, always.
    func stop() {
        lock.lock()
        let fd = listenFD
        let path = boundPath
        let identity = boundIdentity
        let open = connections.keys
        listenFD = -1
        boundPath = nil
        boundIdentity = nil
        connections.removeAll()
        lock.unlock()
        for connection in open { close(connection) }
        if fd >= 0 { close(fd) }
        if let path, let identity, let onDisk = Self.identity(ofFileAt: path), onDisk == identity {
            unlink(path)
        }
    }

    /// `(st_dev, st_ino)` of the file at `path`, or `nil` when it is gone. Deliberately `stat` on
    /// the PATH and not `fstat` on the listening fd: a bound `AF_UNIX` socket's fd reports the
    /// socket object, not the directory entry, so only the path can answer who owns the name now.
    private static func identity(ofFileAt path: String) -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (dev: info.st_dev, ino: info.st_ino)
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
    ///
    /// The rule, its tie-break and its argument are `slopdesk_muxsession::bridge_router::route`'s;
    /// this is the marshalling. The window list crosses as records into one text blob, the same
    /// shape ``CodeBridgeTerminalRouter`` hands the pane list across in and for the same reason.
    static func route(target: String, among candidates: [(fd: Int32, root: String)]) -> Int32? {
        var blob: [UInt8] = []
        var records: [SlopDeskBridgeWindowRecord] = []
        records.reserveCapacity(candidates.count)
        for candidate in candidates {
            let root = span(of: candidate.root, into: &blob)
            records.append(
                SlopDeskBridgeWindowRecord(
                    fd: candidate.fd, root_offset: root.offset, root_len: root.length,
                ),
            )
        }
        let chosen = records.withUnsafeBufferPointer { table in
            blob.withUnsafeBufferPointer { text in
                ffiLend(target) { path in
                    slopdesk_code_bridge_route(
                        table.baseAddress, table.count,
                        text.baseAddress, text.count,
                        path.baseAddress, path.count,
                    )
                }
            }
        }
        return chosen == SLOPDESK_CODE_BRIDGE_NO_WINDOW ? nil : chosen
    }

    /// Appends `value`'s UTF-8 to `blob` and answers where it landed.
    private static func span(of value: String, into blob: inout [UInt8]) -> (offset: Int, length: Int) {
        let offset = blob.count
        blob.append(contentsOf: value.utf8)
        return (offset, blob.count - offset)
    }

    /// Whether `path` lives at or under `root` — the host's ONE containment rule, which is
    /// ``PathConfinement/isWithin(root:path:)``, which is Rust's.
    ///
    /// **What used to be here, and why it had to go.** This was a string `hasPrefix` with a
    /// separator guard bolted on. The guard was right about the case it was written for — `/a/bee`
    /// is not a child of `/a/b` — and the function did no `..` handling whatsoever, so
    /// `contains(root: "/a", path: "/a/../../etc/passwd")` answered TRUE. Nothing here was stopping
    /// that; what was stopping it was a `standardizingPath` in ``HostCodeServerPerformer`` two files
    /// away, plus the fact that a `false` from here falls back to `code-server -r`, which opens the
    /// path anyway. A containment rule whose safety rests on where its callers happen to be is not
    /// one, and the next caller would not have known to bring a normalizer.
    ///
    /// Two answers changed with the unification, both toward refusing. A root of `/` now contains
    /// NOTHING — a predicate that says "inside" for every path on the machine has stopped being
    /// one, and a workbench window rooted at `/` simply falls back to the CLI, which is where an
    /// unrouted open goes anyway. And a `..` anywhere in either argument refuses instead of being
    /// ignored.
    static func contains(root: String, path: String) -> Bool {
        PathConfinement.isWithin(root: root, path: path)
    }

    /// The `open` line for `target` (`path[:line[:col]]`), or `nil` when the path will not encode.
    ///
    /// The suffix is split off HERE, through ``HostCodeServerPerformer/splitLineColSuffix(_:)``,
    /// because that rule belongs to `slopdesk-terminal` — the same splitter the client's own link
    /// detector uses. What crosses is the path and the suffix already apart, so the line builder
    /// never has to know what a detected link's tail looks like.
    static func openCommand(target: String) -> String? {
        let (path, suffix) = HostCodeServerPerformer.splitLineColSuffix(target)
        let line = ffiLend(path) { pathBytes in
            ffiLend(suffix) { suffixBytes in
                ffiAnswerText(capacity: pathBytes.count + 64) { out, cap in
                    slopdesk_code_bridge_open_line(
                        pathBytes.baseAddress, pathBytes.count,
                        suffixBytes.baseAddress, suffixBytes.count,
                        out, cap,
                    )
                }
            }
        }
        return line.isEmpty ? nil : line
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

    /// The verb table is `slopdesk_muxsession::bridge_router::inbound`'s, including the `/`-prefix
    /// requirement, the id bound and the `cd` line the host builds rather than the editor. A
    /// believed line comes back as its verb byte followed by that verb's length-prefixed runs; a
    /// dropped one comes back empty, which is the same silence this used to answer with `nil`.
    static func inbound(in line: Data) -> Inbound? {
        let blob = line.withUnsafeBytes { raw -> [UInt8] in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return ffiAnswerBytes(capacity: raw.count + 32) { out, cap in
                slopdesk_code_bridge_inbound(base, raw.count, out, cap)
            }
        }
        guard let verb = blob.first else { return nil }
        // The run COUNT is a property of the verb, so a short delivery is a marshalling bug rather
        // than a shorter message — hence the exact-count guards below rather than optional reads.
        switch verb {
        case UInt8(SLOPDESK_CODE_BRIDGE_INBOUND_HELLO):
            let runs = ffiRuns(Array(blob.dropFirst()), count: 1)
            guard runs.count == 1 else { return nil }
            return .hello(root: runs[0])
        case UInt8(SLOPDESK_CODE_BRIDGE_INBOUND_RUN):
            let runs = ffiRuns(Array(blob.dropFirst()), count: 4)
            guard runs.count == 4 else { return nil }
            return .run(
                id: runs[0],
                request: CodeBridgeRunRequest(
                    root: runs[1], directory: runs[2].isEmpty ? nil : runs[2], text: runs[3],
                ),
            )
        default:
            return nil
        }
    }

    /// Whether `text` may be typed at a live shell prompt. Non-empty, within
    /// ``maxRunTextBytes``, and free of C0 control characters other than tab and newline — an
    /// embedded ESC in a selection is not text to a shell's line editor, it is a keybinding
    /// (`vi` mode makes that vivid), and NUL truncates. A selection carrying one is refused
    /// rather than reinterpreted.
    static func isTypeable(_ text: String) -> Bool {
        ffiLend(text) { bytes in
            slopdesk_code_bridge_typeable(bytes.baseAddress, bytes.count)
        }
    }

    /// The result line for a finished `run`, or `nil` when it will not encode.
    ///
    /// `paneTitle` and `message` cross with a presence flag rather than as an empty string: the
    /// extension tells an absent field from an empty one, and an empty `pane` would have it
    /// announce a pane with no name.
    static func resultLine(id: String, outcome: CodeBridgeRunOutcome) -> String? {
        let line = ffiLend(id) { idBytes in
            ffiLend(outcome.paneTitle ?? "") { paneBytes in
                ffiLend(outcome.message ?? "") { messageBytes in
                    ffiAnswerText(capacity: 256) { out, cap in
                        slopdesk_code_bridge_result_line(
                            idBytes.baseAddress, idBytes.count,
                            outcome.ok,
                            paneBytes.baseAddress, paneBytes.count, outcome.paneTitle != nil,
                            messageBytes.baseAddress, messageBytes.count, outcome.message != nil,
                            out, cap,
                        )
                    }
                }
            }
        }
        return line.isEmpty ? nil : line
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
        // A bridge client that cannot be written to is gone; the reaction is the drop below, and
        // the loop is ``FileDescriptorWrite``.
        let wrote = FileDescriptorWrite.all(fd: fd, data) == .complete
        if !wrote { drop(fd: fd) }
        return wrote
    }
}
