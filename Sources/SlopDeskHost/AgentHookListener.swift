import Darwin
import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol

/// W10 — the Claude-Code HOOK listener (docs/41 §4.2 signal 2, docs/42 W10). The RICHEST
/// detection path. An installed Claude Code hook POSTs its stdin JSON to a host-local
/// Unix-domain socket; the host folds those events → a type-27
/// ``WireMessage/claudeStatus(state:kind:label:)`` on the owning pane's CONTROL channel.
///
/// Decision #5 ranks hooks SECOND — detection works without them, via the foreground watcher and
/// the screen engine. That is a statement about EVIDENCE, and it was long mistaken for one about
/// configuration: the socket used to bind only under `SLOPDESK_AGENT_HOOKS=1`. It binds always now.
/// Ranked second is not the same as switched off, and the difference was visible — only this path
/// produces ``ClaudeStatus/done``.
///
/// **Pure handler / thin shim split (hang-safety).** Two pieces:
///
/// - ``AgentHookHandler`` — the PURE core. It asks ``SlopDeskAgentDetect/ClaudeHookBody`` what the
///   received bytes SAY (one door over `rust/slopdesk-hookevent`: which event, which block class,
///   whose session), folds the answer through the embedded ``ClaudeStatusMachine``, and produces the
///   type-27 message with dedupe. It NEVER binds a socket — it is fed bytes directly in
///   `AgentHookListenerTests` with real Claude hook JSON. Validate-then-drop: malformed /
///   short / non-JSON bytes yield `nil` (ignored, never trap).
///
/// - ``AgentHookListener`` — the per-host coordinator. It does NOT bind anything: superd owns the
///   `AF_UNIX` listener, because that address is baked into every agent's environment and must
///   outlive hostd's pid. Each accepted connection arrives here as a descriptor over `SCM_RIGHTS`;
///   this class drains it and routes the record to the owning pane's handler.
///
/// **Wire mapping** (the host carries the raw bytes the client maps back, mirroring
/// `ClaudeStatus.urgency` / `ClaudeHookEvent.NotificationKind` — `SlopDeskProtocol` does not
/// depend on `SlopDeskAgentDetect`, so the bytes are the contract):
/// - `state` = `ClaudeStatus.urgency` (`0 none / 1 idle / 2 done / 3 working / 4 needsPermission`).
/// - `kind`  = `0 none / 1 permission / 2 waitingForInput / 3 other` (the last Notification class),
///   plus `4 quiet` — emitted by ``ClaudePaneDetector`` (not this handler) for a status change the
///   client must display but not announce. See `SlopDeskAgentDetect.AgentStatusKind`.
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
        // Validate-then-drop, and already ATTRIBUTED: the door reads the envelope's `session_id`
        // into every event that describes a call, which is exactly what a nested `claude -p` would
        // otherwise use to drive this pane.
        guard let read = ClaudeHookBody.read(bytes) else { return nil }
        // ⚠️ The machine drops a foreign session silently, but emitting on the way out would still
        // ship the DROPPED record's `kind` byte — a wire frame announcing a block class change that
        // never happened. Ask before folding, exactly as `ClaudePaneDetector` does.
        guard machine.accepts(read.event) else { return nil }
        machine.reduce(.hook(read.event), at: now)
        return statusEmissionIfChanged(kindByte: read.kindByte)
    }

    /// A bare clock tick (drives the machine's `done → idle` decay) — emits type-27 iff the
    /// decay changed the status. No hook bytes; the Notification kind resets to `0`.
    public mutating func tick(at now: TimeInterval) -> WireMessage? {
        machine.reduce(.tick, at: now)
        return statusEmissionIfChanged(kindByte: 0)
    }

    /// The current rolled-up status (diagnostics / the live wiring's per-pane rollup).
    public var status: ClaudeStatus { machine.status }

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

/// W10 — the per-HOST hook-listener coordinator: drains each connection superd hands over and
/// routes the record to the registered per-pane sink by its `pane=` header id.
///
/// The host registers a sink (`{ paneID → ingest(jsonBytes) }`) when a channel opens and drops it on
/// close. This stays pane-agnostic at the socket layer (one socket, many panes — the Muxy model)
/// while keeping the per-pane state (the ``AgentHookHandler``) on the owning ``MuxChannelSession``.
///
/// ## hostd does not bind this socket, and that is the point
/// superd does (`rust/slopdesk-superd/src/listeners.rs`), because the address is baked into every
/// spawned agent's environment at `execve` and can never be corrected — so it has to outlive hostd's
/// pid. superd accepts and passes the connection over `SCM_RIGHTS`; it reads none of it. Everything
/// that makes a hook record *mean* something — the Claude state machine, the tool-use ledger, the
/// dissent watchdog — stays here, in the process that is allowed to be rebuilt.
///
/// The framing matches the Muxy/Herdr convention the installed hook POSTs (docs/41 §2.1): one
/// connection carries one newline-terminated record. This class reads the bytes, strips the trailing
/// newline, and hands the raw JSON to the pane's sink — the handler does ALL parsing and validation
/// (validate-then-drop), so a malformed record is dropped without a trap.
///
/// ## Two serial queues, and neither may be merged with the other
/// - `drainQueue` runs the bounded read of one accepted connection. Serial, so connections are
///   drained in the order superd accepted them, which is the order the agent produced them.
/// - `deliveryQueue` runs the routing. Serial for the same reason and a stronger one: hook events
///   are a state machine per pane (UserPromptSubmit → PreToolUse → Stop), and arrival order is the
///   only thing keeping ``AgentHookHandler`` honest.
///
/// Separate, because a slow SINK must not stall the next connection's drain — that is the shape the
/// old accept loop had, and the reason it had it has not changed.
public final class AgentHookListener: @unchecked Sendable {
    private let lock = NSLock()
    /// `paneID → record sink` (the owning channel's `ingestAgentHookRecord`). Guarded by `lock`.
    private var sinks: [String: @Sendable (Data) -> Void] = [:]
    /// Whether superd confirmed this hostd serves the hook listener. Guarded by `lock`.
    private var serving = false

    /// Where one accepted connection is read. See the type docs for why this is not `deliveryQueue`.
    private let drainQueue = DispatchQueue(label: "com.slopdesk.agent-hook.drain")
    /// Where the routing runs, off the drain, in arrival order.
    private let deliveryQueue = DispatchQueue(label: "com.slopdesk.agent-hook.delivery")

    public var onLog: (@Sendable (String) -> Void)?

    public init() {}

    /// Records that superd accepted this hostd's claim on the hook listener.
    ///
    /// Called after the `listen` verb succeeds. It only sets the flag ``isListening`` reports —
    /// nothing is bound here, so there is nothing to fail.
    public func markServing(_ serving: Bool) {
        lock.lock()
        self.serving = serving
        lock.unlock()
    }

    /// Takes ownership of one connection superd accepted, and drains it.
    ///
    /// Returns immediately: the read happens on ``drainQueue``. That matters because the caller is
    /// the supervisor client's single read-loop thread, which also carries every pane's output —
    /// blocking it here for the two seconds a wedged peer is allowed would stall every terminal in
    /// the host.
    ///
    /// The descriptor is closed on every path out, including the ones that read nothing.
    public func serve(connection descriptor: Int32) {
        drainQueue.async { [weak self] in
            guard let self else {
                close(descriptor)
                return
            }
            drain(descriptor)
        }
    }

    /// Closes every sink. There is no socket to close — superd owns it.
    public func stop() {
        lock.lock()
        sinks.removeAll()
        serving = false
        lock.unlock()
    }

    /// TRUE while superd is accepting hook connections on this hostd's behalf — the REAL
    /// hook-listener state the `agentHookStatus` verb (13) reports, so "hooks installed" and "hooks
    /// actually flowing" can't be conflated on the Settings card. `false` means superd is absent,
    /// too old to know the `listen` verb, or could not bind the socket.
    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serving
    }

    /// Reads one connection to EOF and hands the record on. Runs on ``drainQueue``.
    ///
    /// ⚠️ This is the whole host's hook path, and it must never park on anything a peer controls:
    /// the peer is Claude Code's hook binary, which BLOCKS its agent until the record is taken. A
    /// wedged client — connected, wrote nothing, never closed — would park the drain forever, so
    /// `SO_RCVTIMEO` bounds each read and the connection is dropped instead.
    private func drain(_ descriptor: Int32) {
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: Self.readTimeoutSeconds, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size),
        )
        var record = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(descriptor, &chunk, chunk.count)
            if n <= 0 { break } // EOF, error, or the read timeout expired
            record.append(contentsOf: chunk[0..<n])
            // Bound a hostile sender: a single hook record is tiny (< 64 KiB); past the cap, stop
            // reading and drop (the handler caps the label anyway).
            if record.count > Self.maxRecordBytes { break }
        }
        // Strip a single trailing newline (the `printf '…\n'` framing).
        if record.last == 0x0A { record.removeLast() }
        guard !record.isEmpty else { return }
        let delivered = record
        deliveryQueue.async { [weak self] in self?.route(delivered) }
    }

    /// Hard cap on one hook record (validate-then-drop a runaway sender).
    static let maxRecordBytes = 64 * 1024

    /// How long one connection may go without producing bytes before it is dropped. A hook record
    /// is one small write from a local process, so seconds is already generous; the point is that
    /// the ceiling EXISTS.
    static let readTimeoutSeconds = 2

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

    /// Drives the REAL record router without a socket (testing only — hang-safety: no unit test
    /// opens one, and there is nothing here to bind in any case).
    func routeRecordForTesting(_ record: Data) { route(record) }
}
