import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskProtocol

/// W10 — the Claude-Code HOOK listener (docs/41 §4.2 signal 2, docs/42 W10). The RICHEST,
/// opt-in detection path (Decision #5: hooks are SECOND / opt-in — detection works WITHOUT
/// them via the foreground watcher). An installed Claude Code hook POSTs its stdin JSON to a
/// host-local Unix-domain socket; the host folds those events → a type-27
/// ``WireMessage/claudeStatus(state:kind:label:)`` on the owning pane's CONTROL channel.
///
/// **Pure handler / thin shim split (hang-safety).** Two pieces:
///
/// - ``AgentHookHandler`` — the PURE core. Given received BYTES + the originating session id,
///   it parses via the W8-extended ``SlopDeskInspector/HookParser``, maps the typed
///   ``SlopDeskInspector/HookPayload`` → an ``SlopDeskAgentDetect/ClaudeHookEvent``, folds
///   it through the embedded ``ClaudeStatusMachine``, and produces the type-27 message (with
///   dedupe). It NEVER binds a socket — it is fed bytes directly in
///   `AgentHookListenerTests` with real Claude hook JSON. Validate-then-drop: malformed /
///   short / non-JSON bytes yield `nil` (ignored, never trap).
///
/// - ``UnixSocketAcceptor`` — the THIN socket-accept shim (compiled + code-reviewed ONLY,
///   never bound in a test). It owns the `AF_UNIX` listener and hands each received datagram's
///   bytes to the handler.
///
/// **Wire mapping** (the host carries the raw bytes the client maps back, mirroring
/// `ClaudeStatus.urgency` / `ClaudeHookEvent.NotificationKind` — `SlopDeskProtocol` does not
/// depend on `SlopDeskAgentDetect`, so the bytes are the contract):
/// - `state` = `ClaudeStatus.urgency` (`0 none / 1 idle / 2 done / 3 working / 4 needsPermission`).
/// - `kind`  = `0 none / 1 permission / 2 waitingForInput / 3 other` (the last Notification class).
/// - `label` = the Stop `last_assistant_message` / Notification `message`, clamped on the wire.
public struct AgentHookHandler: Sendable {
    /// The embedded per-pane state machine (W7). One handler instance = one pane's hook feed.
    private var machine: ClaudeStatusMachine

    /// The last-emitted `(state, kind, label)` triple — dedupe anchor (see ``ForegroundProcessDetector``).
    private var lastEmittedStatus: ForegroundProcessDetector.StatusTriple?

    public init(doneToIdleTimeout: TimeInterval = 8) {
        machine = ClaudeStatusMachine(doneToIdleTimeout: doneToIdleTimeout)
        lastEmittedStatus = nil
    }

    /// Fold one received hook payload (raw POST body bytes) at absolute time `now`, returning
    /// the type-27 `claudeStatus` message to enqueue, or `nil` when:
    /// - the bytes do not parse as a known Claude hook event (validate-then-drop), OR
    /// - the resulting status `(state, kind, label)` triple is unchanged (dedupe).
    ///
    /// Pure + total: any byte sequence is tolerated. Never traps, never force-unwraps.
    public mutating func handle(bytes: Data, at now: TimeInterval) -> WireMessage? {
        guard let payload = HookParser.parse(bytes) else { return nil } // validate-then-drop
        let (event, kindByte) = Self.mapToHookEvent(payload)
        machine.reduce(.hook(event), at: now)
        return statusEmissionIfChanged(kindByte: kindByte)
    }

    /// A bare clock tick (drives the machine's `done → idle` decay) — emits type-27 iff the
    /// decay changed the status. No hook bytes; the Notification kind resets to `0`.
    public mutating func tick(at now: TimeInterval) -> WireMessage? {
        machine.reduce(.tick, at: now)
        return statusEmissionIfChanged(kindByte: 0)
    }

    /// The current rolled-up status (diagnostics / the live wiring's per-pane rollup).
    public var status: ClaudeStatus { machine.status }

    // MARK: - HookPayload → ClaudeHookEvent (the W10 adapter)

    /// Maps the inspector's typed ``HookPayload`` → the detection target's ``ClaudeHookEvent``
    /// (1:1 per the doc-comments on both enums) AND the wire `kind` byte for the type-27 frame.
    /// The two vocabularies were kept structurally identical on purpose so this is a trivial,
    /// total map (no default-trap branch).
    static func mapToHookEvent(_ payload: HookPayload) -> (ClaudeHookEvent, UInt8) {
        switch payload {
        case let .sessionStart(info):
            return (.sessionStart(sessionID: info.sessionID), 0)

        case let .userPromptSubmit(info):
            return (.userPromptSubmit(sessionID: info.sessionID), 0)

        case let .preToolUse(use):
            return (.preToolUse(sessionID: nil, tool: use.name), 0)

        case let .postToolUse(use, _):
            return (.postToolUse(sessionID: nil, tool: use.name), 0)

        case let .notification(info):
            let kind = mapNotificationKind(info.kind)
            return (.notification(kind: kind, label: info.message), notificationKindByte(kind))

        case let .stop(info):
            return (.stop(sessionID: info.sessionID, label: info.lastAssistantMessage), 0)

        case let .subagentStop(node):
            return (.subagentStop(agentID: node.id), 0)

        case let .sessionEnd(info):
            return (.sessionEnd(sessionID: info.sessionID), 0)
        }
    }

    /// `SlopDeskInspector.NotificationKind` → `SlopDeskAgentDetect.ClaudeHookEvent.NotificationKind`
    /// (the two are intentionally the same three cases — see the inspector enum's doc-comment).
    static func mapNotificationKind(_ kind: NotificationKind) -> ClaudeHookEvent.NotificationKind {
        switch kind {
        case .permission: .permission
        case .waitingForInput: .waitingForInput
        case .other: .other
        }
    }

    /// The wire `kind` byte for a notification class (`1 permission / 2 waitingForInput / 3 other`).
    static func notificationKindByte(_ kind: ClaudeHookEvent.NotificationKind) -> UInt8 {
        switch kind {
        case .permission: 1
        case .waitingForInput: 2
        case .other: 3
        }
    }

    // MARK: - Status dedupe

    private mutating func statusEmissionIfChanged(kindByte: UInt8) -> WireMessage? {
        let triple = ForegroundProcessDetector.StatusTriple(
            state: UInt8(truncatingIfNeeded: machine.status.urgency),
            kind: kindByte,
            label: machine.displayLabel ?? "",
        )
        if triple == lastEmittedStatus { return nil }
        lastEmittedStatus = triple
        return .claudeStatus(state: triple.state, kind: triple.kind, label: triple.label)
    }
}

/// W10 — the THIN `AF_UNIX` socket-accept shim that feeds the pure ``AgentHookHandler``.
/// **Compiled + code-reviewed ONLY** — never bound in a unit test (the hang-safety rule).
///
/// The framing matches the Muxy/Herdr convention the installed hook script POSTs (docs/41
/// §2.1): a single connection carries one newline-terminated record. The shim reads the bytes,
/// strips the trailing newline, and hands the raw JSON to the handler — the handler does ALL
/// parsing/validation (validate-then-drop), so a malformed datagram is dropped here without a
/// trap. The PANE the bytes belong to is carried out-of-band (the per-pane socket path / the
/// `SLOPDESK_PANE_ID` the hook script forwards), resolved by the owner before constructing
/// the handler — this shim is pane-agnostic.
public final class UnixSocketAcceptor: @unchecked Sendable {
    /// The bound socket fd (`-1` until ``start(path:)`` / after ``stop()``).
    private var listenFD: Int32 = -1
    private let lock = NSLock()

    /// The filesystem path of the bound socket (so ``stop()`` can `unlink` it).
    private var boundPath: String?

    /// Called with each received record's raw bytes (newline already stripped). The owner
    /// routes them into the per-pane ``AgentHookHandler`` and enqueues the resulting type-27.
    public var onRecord: (@Sendable (Data) -> Void)?

    public var onLog: (@Sendable (String) -> Void)?

    public init() {}

    /// Binds an `AF_UNIX` stream socket at `path` (replacing any stale socket file) and begins
    /// accepting. Throws on bind/listen failure. The accept loop runs on a dedicated background
    /// thread; each accepted connection is drained to EOF, its bytes (sans trailing `\n`)
    /// handed to ``onRecord``.
    ///
    /// SAFETY: `sockaddr_un.sun_path` is bounded — a too-long path is rejected (validate-then-
    /// drop) rather than overflowing the fixed C array.
    public func start(path: String) throws {
        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxPath else {
            throw AgentSocketError.pathTooLong(path)
        }
        unlink(path) // clear a stale socket file from a prior run (idempotent)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, maxPath)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw AgentSocketError.bindFailed(e)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw AgentSocketError.listenFailed(e)
        }

        lock.lock()
        listenFD = fd
        boundPath = path
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd) }
        onLog?("agent-hook socket listening at \(path)")
    }

    /// Closes the listener and unlinks the socket file. Idempotent.
    public func stop() {
        lock.lock()
        let fd = listenFD
        let path = boundPath
        listenFD = -1
        boundPath = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    /// TRUE while the socket is bound + accepting (between a successful ``start(path:)`` and
    /// ``stop()``). The LIVE truth the `agentHookStatus` metadata verb reports so the Settings card
    /// can show installed-but-inactive instead of a false green.
    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD >= 0
    }

    /// SAFETY: a blocking `accept`/`read` loop over the owned listen fd; each connection is
    /// read into a bounded growing buffer until EOF, the trailing newline stripped, and the
    /// record handed to `onRecord` (which validate-then-drops). A read error / EOF closes the
    /// connection fd and loops. The loop ends when `accept` fails (the fd was closed by stop()).
    private func acceptLoop(fd listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { return } // listen fd closed by stop() → exit the thread
            var record = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(conn, &chunk, chunk.count)
                if n <= 0 { break } // EOF or error
                record.append(contentsOf: chunk[0..<n])
                // Bound a hostile sender: a single hook record is tiny (< 64 KiB); past the
                // cap, stop reading and drop (the handler caps the label anyway).
                if record.count > Self.maxRecordBytes { break }
            }
            close(conn)
            // Strip a single trailing newline (the `printf '…\n'` framing).
            if record.last == 0x0A { record.removeLast() }
            if !record.isEmpty { onRecord?(record) }
        }
    }

    /// Hard cap on one hook record (validate-then-drop a runaway sender).
    static let maxRecordBytes = 64 * 1024
}

/// Errors the ``UnixSocketAcceptor`` shim throws on bind/listen failure (the pure handler never
/// throws — it validate-then-drops). Carried as a typed error so the daemon can log + continue.
public enum AgentSocketError: Error, Equatable, Sendable {
    case pathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// W10 — the PURE record framing the installed hook POSTs (a `pane=<id>` header line + the raw
/// hook JSON). Split here so the routing is unit-testable without a socket; the socket shim
/// only moves bytes. Validate-then-drop: a record with no `pane=` header yields a `nil` pane id
/// (the JSON is still returned, but the router has no pane to deliver it to → dropped).
public enum AgentHookRecord {
    /// Splits a received record into `(paneID, jsonBytes)`. The first line, if it begins with
    /// `pane=`, supplies the pane id (empty → `nil`); the remainder is the hook JSON. Without a
    /// `pane=` header the whole record is treated as the JSON (paneID `nil`).
    public static func split(_ record: Data) -> (paneID: String?, json: Data) {
        // Find the first newline.
        guard let nl = record.firstIndex(of: 0x0A) else {
            return (nil, record) // single line — no header
        }
        let firstLine = record[record.startIndex..<nl]
        let prefix = Data("pane=".utf8)
        guard firstLine.starts(with: prefix) else {
            return (nil, record) // first line is not our header — whole record is JSON
        }
        let idBytes = firstLine.dropFirst(prefix.count)
        let id = String(bytes: idBytes, encoding: .utf8).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let json = Data(record[record.index(after: nl)...])
        return (id?.isEmpty == true ? nil : id, json)
    }
}

/// W10 — the per-HOST hook-listener coordinator: owns ONE ``UnixSocketAcceptor`` and routes each
/// received record to the registered per-pane sink by its `pane=` header id. The host registers a
/// sink (`{ paneID → ingest(jsonBytes) }`) when a channel opens and drops it on close. This stays
/// pane-agnostic at the socket layer (one socket, many panes — the Muxy model) while keeping the
/// per-pane state (the ``AgentHookHandler``) on the owning ``MuxChannelSession``. Compiled +
/// code-reviewed (it owns the socket shim); the routing split it depends on is unit-tested via
/// ``AgentHookRecord``.
public final class AgentHookListener: @unchecked Sendable {
    private let acceptor = UnixSocketAcceptor()
    private let lock = NSLock()
    /// `paneID → record sink` (the owning channel's `ingestAgentHookRecord`). Guarded by `lock`.
    private var sinks: [String: @Sendable (Data) -> Void] = [:]

    /// A stderr logging hook (forwarded to the socket shim at ``start(path:)``).
    public var onLog: (@Sendable (String) -> Void)?

    public init() {
        acceptor.onRecord = { [weak self] record in self?.route(record) }
    }

    /// Binds the socket at `path` (the value the host exports as `SLOPDESK_SOCKET_PATH`).
    public func start(path: String) throws {
        acceptor.onLog = onLog
        try acceptor.start(path: path)
    }

    /// Closes the socket + clears all sinks.
    public func stop() {
        acceptor.stop()
        lock.lock()
        sinks.removeAll()
        lock.unlock()
    }

    /// TRUE while the underlying socket is bound + accepting — the REAL hook-listener state the
    /// `agentHookStatus` verb (13) reports, so "hooks installed" and "hooks actually flowing" can't
    /// be conflated on the Settings card. `false` when hostd was launched without
    /// `SLOPDESK_AGENT_HOOKS=1` (the listener is never constructed) OR the bind failed.
    public var isListening: Bool { acceptor.isListening }

    /// Registers a per-pane sink for `paneID`. Replaces any prior sink for that id (idempotent).
    /// Internal — only ``HostServer`` (same module) registers channels; not a public API.
    func register(paneID: String, sink: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        sinks[paneID] = sink
        lock.unlock()
    }

    /// Drops a pane's sink (on channel close). Idempotent. Internal (see ``register``).
    func unregister(paneID: String) {
        lock.lock()
        sinks[paneID] = nil
        lock.unlock()
    }

    /// Routes one received record to its pane's sink (validate-then-drop: an unknown / missing
    /// pane id is dropped — no trap).
    private func route(_ record: Data) {
        let (paneID, json) = AgentHookRecord.split(record)
        guard let paneID else { return } // no pane header → nothing to deliver to
        lock.lock()
        let sink = sinks[paneID]
        lock.unlock()
        sink?(json)
    }

    // MARK: Test seams (hook-sink lifetime — never used in production)

    /// Number of registered pane sinks (testing only — the leak pin for the stable-key
    /// contract: one sink per live session, across any number of detach/reattach cycles).
    var sinkCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return sinks.count
    }

    /// The registered pane ids (testing only).
    var sinkPaneIDsForTesting: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sinks.keys)
    }

    /// Drives the REAL record router without binding the socket (testing only — hang-safety:
    /// the `UnixSocketAcceptor` is never bound in a unit test).
    func routeRecordForTesting(_ record: Data) { route(record) }
}
