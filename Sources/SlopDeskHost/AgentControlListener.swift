import Darwin
import Foundation
import SlopDeskTransport

/// Agent-control socket server — the herdr/zellij-style control surface for AI agents.
///
/// Binds an `AF_UNIX` stream socket at `$TMPDIR/slopdesk-ctl-<pid>.sock` (chmod 0600) and speaks
/// **NDJSON** per connection: one UTF-8 JSON object per line,
/// request `{"id":"…","method":"…","params":{…}}` → response `{"id":"…","ok":true,"result":{…}}`
/// or `{"id":"…","ok":false,"error":"…"}`.
///
/// ## Hang-safety
/// The accept loop and per-connection read loop run on dedicated background threads (never the
/// cooperative-concurrency pool), so a blocked `read(2)` or slow shell write never parks a Swift
/// concurrency thread. The `wait` verb (the only blocking verb) parks its connection thread on an
/// `NSCondition` until the PTY fires a chunk matching the regex or the timeout elapses.
///
/// ## Pure handler split (same pattern as ``AgentHookListener``)
/// - ``AgentControlHandler`` — PURE verb dispatcher: `(id, method, params)` + a ``HostServer`` ref
///   → executes the verb, returns the JSON response line. No socket I/O; unit-testable with a
///   fake `HostServer`.
/// - ``AgentControlAcceptor`` — THIN `AF_UNIX` shim: binds, accepts, reads NDJSON lines, routes
///   each to ``AgentControlHandler``, writes the response. Never instantiated in a test
///   (hang-safety: no real socket in a unit test).
///
/// **Validate-then-drop**: a request line that is not valid UTF-8, not valid JSON, exceeds
/// 64 KiB, or has an unknown method gets an error response — the server never traps.
public final class AgentControlListener: @unchecked Sendable {
    private let acceptor: AgentControlAcceptor
    /// The socket path exported to PTY envs and logged at startup.
    public let socketPath: String

    public var onLog: (@Sendable (String) -> Void)?

    public init(socketPath: String, server: HostServer) {
        self.socketPath = socketPath
        acceptor = AgentControlAcceptor(server: server)
    }

    /// Binds the socket and begins accepting. Throws on bind/listen failure.
    public func start() throws {
        acceptor.onLog = onLog
        try acceptor.start(path: socketPath)
    }

    /// Closes the listener and unlinks the socket file. Idempotent.
    public func stop() {
        acceptor.stop()
    }
}

// MARK: - Pure handler

/// The PURE verb dispatcher for the agent-control protocol.
///
/// Given `(id, method, params)` and the host server, executes the verb and returns a complete
/// NDJSON response line (UTF-8, newline-terminated).
///
/// **All methods are synchronous** except `wait`, which must be called on a background thread
/// (it blocks via `NSCondition`); its result is also returned as an NDJSON line.
///
/// Unit-tested with a fake host — no real socket, no real PTY.
public struct AgentControlHandler: Sendable {
    /// Max bytes accumulated in the `wait` regex buffer before the oldest half is trimmed.
    static let waitBufferCap = 4 * 1024 * 1024

    // MARK: E14/K13 IPC guards

    /// The MUTATING ("send keys" equivalent) verbs — write to a PTY, spawn, kill, or resize a pane.
    /// Gated behind ``IPCGuards/allowSendKeys``. The READ-ONLY verbs (`list-panes`/`read`/
    /// `screen`/`last-output`/`wait`/`report`) are NOT in this set and are always allowed. (`subscribe` is
    /// intercepted in the acceptor before `dispatch` and only STREAMS output, so it is read-only too.)
    static let mutatingVerbs: Set<String> = ["write", "run", "spawn", "kill", "resize"]

    /// Whether `method` mutates a pane (and so is gated by the send-keys / sensitive-session guards).
    static func isMutatingVerb(_ method: String) -> Bool { mutatingVerbs.contains(method) }

    /// Default foreground-name resolver for the sensitive-session gate: looks the pane up and probes
    /// its live PTY foreground basename via ``PTYForegroundProbe``. Returns `""` when the pane is
    /// unknown / the probe fails (→ not sensitive; the send-keys gate still applies). Tests inject a
    /// fake resolver into ``dispatch(id:method:params:server:guards:foregroundName:)`` instead.
    @usableFromInline static let probeForegroundName: @Sendable (HostServer, String) -> String = { server, paneId in
        guard let session = server.lookupPaneForControl(paneId: paneId) else { return "" }
        return PTYForegroundProbe.foregroundName(masterFD: session.pty.masterFD)
    }

    // MARK: Dispatch

    /// Dispatches one decoded request and returns a response line (UTF-8, newline-terminated).
    /// May block on the calling thread for the `wait` verb.
    ///
    /// **E14/K13 — IPC guards.** Before the verb runs, the MUTATING verbs
    /// (`write`/`run`/`spawn`/`kill`/`resize`) are gated behind ``IPCGuards/allowSendKeys``
    /// (default OFF); a mutating verb whose target pane runs a SENSITIVE foreground process
    /// (`ssh`/`sudo`/`login`/…) is additionally gated behind ``IPCGuards/allowSensitiveSessions``
    /// (default OFF). The READ-ONLY verbs (`list-panes`/`read`/`wait`/`report`) are ALWAYS allowed.
    /// No new socket, no tokens, no crypto — pure host-side guards on the existing NDJSON ctl socket
    /// (the WireGuard mesh is the security boundary). Both flags resolve from the host env at this
    /// dispatch site via ``IPCGuards/resolved()``; tests inject `guards` (and `foregroundName`) directly.
    ///
    /// - Parameters:
    ///   - guards: the resolved send-keys / sensitive-session permissions (default: from env).
    ///   - foregroundName: resolves a pane's current foreground-process BASENAME for the
    ///     sensitive-session gate (default: probes the live PTY; injected in tests).
    @preconcurrency
    public static func dispatch(
        id: String,
        method: String,
        params: [String: Any],
        server: HostServer,
        guards: IPCGuards = .resolved(),
        foregroundName: @Sendable (HostServer, String) -> String = Self.probeForegroundName,
    ) -> String {
        // E14/K13: gate mutating verbs. Fire BEFORE the verb acts (and before any pane lookup /
        // side effect) so a refused verb never touches the PTY.
        if isMutatingVerb(method) {
            guard guards.allowSendKeys else {
                return errorResponse(id: id, message: "ipc send-keys disabled")
            }
            // The sensitive-session gate only applies to a verb that NAMES a target pane (`spawn`
            // creates a fresh pane and has no target → only the send-keys gate covers it).
            if !guards.allowSensitiveSessions, let paneId = params["paneId"] as? String {
                let fg = foregroundName(server, paneId)
                if SensitiveSessionPolicy.isSensitive(processName: fg) {
                    return errorResponse(id: id, message: "ipc sensitive-session blocked: \(fg)")
                }
            }
        }

        return switch method {
        case "list-panes":
            listPanes(id: id, server: server)
        case "read":
            readPane(id: id, params: params, server: server)
        case "screen":
            screenPane(id: id, params: params, server: server)
        case "last-output":
            lastOutput(id: id, params: params, server: server)
        case "write":
            writePane(id: id, params: params, server: server)
        case "run":
            runPane(id: id, params: params, server: server)
        case "wait":
            waitPane(id: id, params: params, server: server)
        case "spawn":
            spawnPane(id: id, params: params, server: server)
        case "kill":
            killPane(id: id, params: params, server: server)
        case "resize":
            resizePane(id: id, params: params, server: server)
        case "report":
            reportAgent(id: id, params: params, server: server)
        default:
            errorResponse(id: id, message: "unknown method: \(method)")
        }
    }

    // MARK: Verb implementations

    /// `list-panes` → `{panes: [{paneId, title, pid, isAlive, state, command, rows, cols,
    /// cwd?, lastExitCode?, stateMessage?}]}`. Optional fields are OMITTED when unknown
    /// (JSON has no distinct "unset" and an agent should never see a fabricated `""`/`0` truth).
    static func listPanes(id: String, server: HostServer) -> String {
        let panes = server.listPanesForControl()
        let items = panes.map { p -> [String: Any] in
            var item: [String: Any] = [
                "paneId": p.paneId,
                "title": p.title,
                "pid": Int(p.pid),
                "isAlive": p.isAlive,
                "state": p.state,
                "command": p.command,
                "rows": p.rows,
                "cols": p.cols,
            ]
            if let cwd = p.cwd { item["cwd"] = cwd }
            if let exit = p.lastExitCode { item["lastExitCode"] = Int(exit) }
            if let message = p.stateMessage { item["stateMessage"] = message }
            return item
        }
        return successResponse(id: id, result: ["panes": items])
    }

    /// Lossy UTF-8 decode shared by the block-output paths (same idiom as
    /// ``MuxChannelSession/scrollbackTextForControl(ansiStrip:)``: invalid bytes → `?`).
    static func decodeLossyUTF8(_ bytes: [UInt8]) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes.map { $0 < 0x80 ? $0 : UInt8(0x3F) }.map { Character(UnicodeScalar($0)) })
    }

    /// Excises zsh's PROMPT_SP end-of-line mark (`%` + width fill) from a block's output tail.
    ///
    /// On the live wire the cluster always abuts the closing `133;D` (zsh's preprompt runs right
    /// before precmd), which is exactly what ``PromptEOLMarkStripper`` anchors on — but the
    /// segmenter strips the OSC marks out of the captured span, leaving the cluster bare at the
    /// buffer tail. Re-appending a synthetic `D` anchor restores the adjacency the stripper keys
    /// on (honest: the real `D` DID follow these bytes), reusing its two-sided-SGR false-positive
    /// guard instead of duplicating the machine. A command whose real output ends in `%` + spaces
    /// stays untouched (no SGR wrapping → deliberate miss).
    static func stripPromptEOLTail(_ bytes: [UInt8]) -> [UInt8] {
        let anchor: [UInt8] = Array("\u{1B}]133;D\u{07}".utf8)
        let stripped = [UInt8](PromptEOLMarkStripper.strip(Data(bytes + anchor)))
        guard stripped.suffix(anchor.count).elementsEqual(anchor) else { return stripped }
        return Array(stripped.dropLast(anchor.count))
    }

    /// `last-output` — the OSC-133 block-aware read: the last N CLOSED command blocks
    /// (command text + output + exit code + duration), newest LAST, plus the still-running
    /// block's metadata when one is executing.
    ///
    /// Response: `{blocks: [{index, command, output, complete, exitCode?, durationMs?}],
    /// running?: {command, outputLen}}`. Output is ANSI-stripped unless `ansiStrip: false`.
    /// Errors when blocks tracking is off (`SLOPDESK_BLOCKS=0`) — the caller falls back to `read`.
    static func lastOutput(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let n = max(1, (params["n"] as? Int) ?? 1)
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true
        guard let blocks = session.recentBlocksForControl(limit: n) else {
            return errorResponse(id: id, message: "blocks tracking disabled on host (SLOPDESK_BLOCKS=0)")
        }
        let items = blocks.map { b -> [String: Any] in
            let raw = decodeLossyUTF8(stripPromptEOLTail(b.output))
            var item: [String: Any] = [
                "index": Int(b.index),
                "command": b.commandText,
                "output": ansiStrip ? ANSIStripper.strip(raw) : raw,
                "complete": b.complete,
            ]
            if let exit = b.exitCode { item["exitCode"] = Int(exit) }
            if let duration = b.durationMS { item["durationMs"] = Int(duration) }
            return item
        }
        var result: [String: Any] = ["blocks": items]
        if let open = session.openBlockForControl() {
            result["running"] = ["command": open.commandText, "outputLen": open.output.count]
        }
        return successResponse(id: id, result: result)
    }

    /// `read` → `{text: "…"}` — scrollback snapshot for a pane (ANSI stripped by default).
    ///
    /// When `source == "unwrapped"` (P1), returns `{text, lines: [...]}` where `lines` is the array
    /// of LOGICAL lines (joined chunks, ANSI-stripped, split on hard `\n`; only the empty artifact of
    /// a terminating newline is dropped — an UNTERMINATED final line is KEPT, since it is typically the
    /// live prompt / awaiting-input cue an orchestrator scrapes), and `text` is those lines re-joined —
    /// so an agent regex is robust to read-CHUNK boundaries. Optional `lines` limits to the last N.
    /// (True reverse-of-terminal-width unwrapping is impossible host-side — the host keeps no screen buffer.)
    static func readPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        // `source: "unwrapped"` (a.k.a. recent) switches to the logical-line view.
        if let source = params["source"] as? String, source == "unwrapped" || source == "recent" {
            // Optional positive `lines` cap; any non-positive / non-Int value → no cap (unbounded).
            let limit: Int? = {
                if let n = params["lines"] as? Int, n > 0 { return n }
                return nil
            }()
            let rows = session.recentUnwrappedTextForControl(lines: limit)
            return successResponse(id: id, result: ["lines": rows, "text": rows.joined(separator: "\n")])
        }
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true
        let text = session.scrollbackTextForControl(ansiStrip: ansiStrip)
        return successResponse(id: id, result: ["text": text])
    }

    /// `screen` — the RENDERED-screen dump: replays the scrollback ring's raw bytes through
    /// ``TerminalScreenModel`` at the pane's live PTY size and returns the resulting grid, so a
    /// TUI pane (vim, htop, claude) reads as what a human sees instead of raw byte soup.
    ///
    /// Response: `{rows, cols, cursorRow, cursorCol, cursorVisible, altScreen, lines: [String],
    /// text}` — `lines` has exactly `rows` entries (trailing whitespace trimmed), `text` is the
    /// join with trailing blank lines dropped; cursor coordinates are 0-based. Optional
    /// `rows`/`cols` params (1…512 / 1…1024, the model's clamp) override the grid size — the
    /// default is the live `TIOCGWINSZ` size, falling back to 24×80 when the PTY is gone.
    static func screenPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let live = session.pty.currentWindowSize()
        var rows = Int(live?.rows ?? 24)
        var cols = Int(live?.cols ?? 80)
        if let r = params["rows"] as? Int {
            guard r >= 1, r <= 512 else { return errorResponse(id: id, message: "rows must be 1..512") }
            rows = r
        }
        if let c = params["cols"] as? Int {
            guard c >= 1, c <= 1024 else { return errorResponse(id: id, message: "cols must be 1..1024") }
            cols = c
        }
        var model = TerminalScreenModel(rows: rows, cols: cols)
        model.feed(session.scrollbackRawForControl())
        let snap = model.snapshot()
        var trimmed = snap.lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return successResponse(id: id, result: [
            "rows": snap.rows,
            "cols": snap.cols,
            "cursorRow": snap.cursorRow,
            "cursorCol": snap.cursorCol,
            "cursorVisible": snap.cursorVisible,
            "altScreen": snap.altScreen,
            "lines": snap.lines,
            "text": trimmed.joined(separator: "\n"),
        ])
    }

    /// `report` — an agent self-declares its state `{state, message?}` (P1 supervision API).
    ///
    /// Authoritative (precedence-2 hook fold), beating the foreground-process heuristic floor.
    /// Validate-then-drop: a missing `paneId`, an unknown pane, or a `state` outside the closed
    /// supervision set (``AgentControlState/allStates``) → error response, never a trap.
    static func reportAgent(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let state = params["state"] as? String else {
            return errorResponse(id: id, message: "missing params.state")
        }
        guard AgentControlState.isValid(state) else {
            return errorResponse(
                id: id,
                message: "invalid state '\(state)' (want one of: \(AgentControlState.allStates.joined(separator: ", ")))",
            )
        }
        // Optional human label — bounded by the detector's machine cap downstream; here we only
        // accept a String (any other JSON type is ignored, not an error).
        let message = params["message"] as? String
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        session.reportAgentStatusForControl(state: state, message: message)
        return successResponse(id: id, result: ["state": state])
    }

    /// `write` — injects raw text and/or NAMED KEYS into the PTY (no implicit Enter).
    ///
    /// `params.text` (optional) is sent first, then each token in `params.keys` (optional
    /// `[String]`, tmux `send-keys` vocabulary — `C-c`, `Enter`, `Up`, `M-x`, `F5`, …) resolved
    /// via ``ControlKeyMap``. At least one of the two must be present; an unknown key token
    /// rejects the WHOLE request (validate-then-drop — never send a partial key sequence).
    static func writePane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        let text = params["text"] as? String
        let keyTokens = params["keys"] as? [String]
        guard text != nil || !(keyTokens ?? []).isEmpty else {
            return errorResponse(id: id, message: "missing params.text or params.keys")
        }
        var bytes = Data()
        if let text { bytes.append(contentsOf: text.utf8) }
        if let keyTokens {
            let resolved = ControlKeyMap.bytes(forTokens: keyTokens)
            if let unknown = resolved.unknown {
                return errorResponse(id: id, message: "unknown key: \(unknown)")
            }
            bytes.append(contentsOf: resolved.bytes)
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        session.writeRawForControl(bytes)
        return successResponse(id: id, result: [:])
    }

    /// `run` — injects `text + "\r"` atomically (Enter key).
    ///
    /// With `params.wait == true`, BLOCKS (connection thread, like `wait`) until the command's
    /// OSC-133 block CLOSES, then answers `{matched: true, exitCode?, durationMs?, output,
    /// blockIndex, elapsed}` — the herdr-style "run and give me the result" primitive. The
    /// command is identified by block INDEX: the segmenter's next-command index is snapshotted
    /// BEFORE the write, and the first closed block at-or-past it is the answer (an interleaved
    /// concurrent driver could race a command in between — the answer is then that command's;
    /// single-driver-per-pane is the supported shape). A closed-but-interrupted block (Ctrl-C,
    /// re-prompt without `D`) also resolves the wait, with `exitCode` absent. Timeout →
    /// `{matched: false, elapsed}`. Requires blocks tracking (`SLOPDESK_BLOCKS` on).
    static func runPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let text = params["text"] as? String else {
            return errorResponse(id: id, message: "missing params.text")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let bytes = Data((text + "\r").utf8)
        guard (params["wait"] as? Bool) == true else {
            session.writeRawForControl(bytes)
            return successResponse(id: id, result: [:])
        }

        // --wait: baseline the expected block index BEFORE the write so the observer can
        // discriminate our command's block from an already-running one.
        guard let baseline = session.expectedNextBlockIndexForControl() else {
            return errorResponse(id: id, message: "blocks tracking disabled on host (SLOPDESK_BLOCKS=0)")
        }
        let timeoutMs = (params["timeoutMs"] as? Double) ?? 30000
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true

        final class RunWaitState: @unchecked Sendable {
            let condition = NSCondition()
            var closed: MuxChannelSession.CommandBlockUpdate?
        }
        let state = RunWaitState()
        let observerID = UUID()
        session.registerBlockObserver(id: observerID) { update in
            // A CLOSED block carries `complete == true` (D-closed) or a non-nil duration
            // (interrupted close); a RUNNING open-block emission has neither — ignore it.
            guard update.index >= baseline, update.complete || update.durationMS != nil else { return }
            state.condition.lock()
            if state.closed == nil {
                state.closed = update
                state.condition.signal()
            }
            state.condition.unlock()
        }

        session.writeRawForControl(bytes)

        let startNanos = DispatchTime.now().uptimeNanoseconds
        state.condition.lock()
        let deadline = Date(timeIntervalSinceNow: timeoutMs / 1000.0)
        while state.closed == nil {
            if !state.condition.wait(until: deadline) { break }
        }
        let closed = state.closed
        state.condition.unlock()
        session.removeBlockObserver(id: observerID)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        guard let closed else {
            return successResponse(id: id, result: ["matched": false, "elapsed": elapsedMs])
        }
        let outputBytes = session.blockOutputBytesForControl(index: closed.index) ?? []
        let raw = decodeLossyUTF8(stripPromptEOLTail(outputBytes))
        var result: [String: Any] = [
            "matched": true,
            "elapsed": elapsedMs,
            "blockIndex": Int(closed.index),
            "output": ansiStrip ? ANSIStripper.strip(raw) : raw,
        ]
        if let exit = closed.exitCode { result["exitCode"] = Int(exit) }
        if let duration = closed.durationMS { result["durationMs"] = Int(duration) }
        return successResponse(id: id, result: result)
    }

    /// `wait` — blocks until pane output matches `until` regex or `timeoutMs` elapses.
    ///
    /// **Blocking** — must be called on a background thread (not the cooperative pool).
    /// Uses `NSCondition` to park; the output observer signals it from the PTY read-loop
    /// thread. The accumulated buffer is capped at ``waitBufferCap`` (oldest half trimmed).
    ///
    /// Response: `{matched: Bool, elapsed: <ms>}`.
    static func waitPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        // `state` is the AGENT-STATE wait ("block until the pane is idle/done/blocked") — an
        // alternative to the output-regex `until`. Exactly one of the two must be present.
        if let stateSpec = params["state"] as? String {
            return waitForAgentState(id: id, paneId: paneId, stateSpec: stateSpec, params: params, server: server)
        }
        guard let untilPattern = params["until"] as? String else {
            return errorResponse(id: id, message: "missing params.until or params.state")
        }
        let timeoutMs = (params["timeoutMs"] as? Double) ?? 30000
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }

        // Compile the regex once (validate-then-drop: a bad pattern is an error, not a crash).
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: untilPattern)
        } catch {
            return errorResponse(id: id, message: "invalid regex: \(error.localizedDescription)")
        }

        // Box the mutable scanner + matched flag in a class so the @Sendable observer closure
        // (PTY read-loop thread) and the NSCondition wait (connection thread) share state without
        // capturing `var`s across concurrency boundaries — Swift 6 strict sendability.
        final class WaitState: @unchecked Sendable {
            let condition = NSCondition()
            var matched = false
            var scanner: WaitUntilScanner
            init(regex: NSRegularExpression) { scanner = WaitUntilScanner(regex: regex) }
        }
        let state = WaitState(regex: regex)

        let observerID = UUID()
        // Register the observer; it runs on the PTY read-loop thread — so the per-chunk work MUST
        // stay bounded (the scanner strips/decodes/matches incrementally; re-processing the whole
        // accumulated buffer here was O(n²) over a chatty command and visibly lagged the pane).
        session.registerOutputObserver(id: observerID) { chunk in
            state.condition.lock()
            if !state.matched, state.scanner.ingest(chunk) {
                state.matched = true
                state.condition.signal()
            }
            state.condition.unlock()
        }

        let startNanos = DispatchTime.now().uptimeNanoseconds
        state.condition.lock()
        let deadline = Date(timeIntervalSinceNow: timeoutMs / 1000.0)
        while !state.matched {
            // `wait(until:)` returns false on timeout.
            if !state.condition.wait(until: deadline) { break }
        }
        let didMatch = state.matched
        state.condition.unlock()

        session.removeOutputObserver(id: observerID)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        return successResponse(id: id, result: ["matched": didMatch, "elapsed": elapsedMs])
    }

    /// The `wait --state` arm: blocks until the pane's supervision state is IN `stateSpec` (one
    /// state, or a comma-set — `"idle,done"`) or `timeoutMs` elapses.
    ///
    /// **Blocking** — connection thread only, like the regex arm. The transition source is the
    /// server-level `agent_status_changed` fan-out (the same stream `events` serves), plus an
    /// immediate current-state check BEFORE and AFTER observer registration so a transition in
    /// the registration gap can never be missed. Response: `{matched, state?, elapsed}`.
    static func waitForAgentState(
        id: String,
        paneId: String,
        stateSpec: String,
        params: [String: Any],
        server: HostServer,
    ) -> String {
        let targets = Set(
            stateSpec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
        )
        guard !targets.isEmpty, targets.allSatisfy(AgentControlState.isValid) else {
            return errorResponse(
                id: id,
                message: "invalid state '\(stateSpec)' (want a comma-set of: \(AgentControlState.allStates.joined(separator: ", ")))",
            )
        }
        let timeoutMs = (params["timeoutMs"] as? Double) ?? 30000
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }

        final class StateWait: @unchecked Sendable {
            let condition = NSCondition()
            var matched: String?
        }
        let state = StateWait()
        let observerID = UUID()
        server.registerAgentStatusObserver(id: observerID) { pane, stateStr, _, _ in
            guard pane == paneId, targets.contains(stateStr) else { return }
            state.condition.lock()
            if state.matched == nil {
                state.matched = stateStr
                state.condition.signal()
            }
            state.condition.unlock()
        }
        // Current-state check AFTER registering: a pane already in a target state answers
        // immediately, and a transition that landed between lookup and registration is caught
        // here rather than lost (the observer only sees FUTURE transitions).
        let current = AgentControlState.string(from: session.agentStatusForControl)
        if targets.contains(current) {
            state.condition.lock()
            if state.matched == nil { state.matched = current }
            state.condition.unlock()
        }

        let startNanos = DispatchTime.now().uptimeNanoseconds
        state.condition.lock()
        let deadline = Date(timeIntervalSinceNow: timeoutMs / 1000.0)
        while state.matched == nil {
            if !state.condition.wait(until: deadline) { break }
        }
        let matched = state.matched
        state.condition.unlock()
        server.removeAgentStatusObserver(id: observerID)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        guard let matched else {
            return successResponse(id: id, result: ["matched": false, "elapsed": elapsedMs])
        }
        return successResponse(id: id, result: ["matched": true, "state": matched, "elapsed": elapsedMs])
    }

    /// `spawn` — forks a new standalone pane. Returns `{paneId: "…"}`.
    ///
    /// `rows`/`cols` default to 24×80 when absent, but a PRESENT value is validated into
    /// `1…65535` first (validate-then-drop, same as `resize`): pre-fix the bare
    /// `UInt16(_:)` conversion TRAPPED on a negative or >65535 value from the socket,
    /// aborting the entire hostd (every session, every client) on one bad NDJSON line.
    static func spawnPane(id: String, params: [String: Any], server: HostServer) -> String {
        let cmd = params["cmd"] as? [String]
        let cwd = params["cwd"] as? String
        let env = params["env"] as? [String: String]
        let rowsRaw = (params["rows"] as? Int) ?? 24
        guard rowsRaw >= 1, rowsRaw <= 65535 else {
            return errorResponse(id: id, message: "rows must be 1..65535")
        }
        let colsRaw = (params["cols"] as? Int) ?? 80
        guard colsRaw >= 1, colsRaw <= 65535 else {
            return errorResponse(id: id, message: "cols must be 1..65535")
        }
        let rows = UInt16(rowsRaw)
        let cols = UInt16(colsRaw)

        let paneId: String
        do {
            paneId = try await_spawnStandalonePane(
                server: server, cmd: cmd, cwd: cwd, env: env, rows: rows, cols: cols,
            )
        } catch {
            return errorResponse(id: id, message: "spawn failed: \(error)")
        }
        return successResponse(id: id, result: ["paneId": paneId])
    }

    /// Bridges the `async` ``HostServer/spawnStandalonePane`` into the synchronous dispatch.
    /// Uses a `DispatchSemaphore` and an `@unchecked Sendable` box to pass the result across
    /// the Task→thread boundary without capturing `var`s (Swift 6 strict sendability).
    private static func await_spawnStandalonePane(
        server: HostServer,
        cmd: [String]?,
        cwd: String?,
        env: [String: String]?,
        rows: UInt16,
        cols: UInt16,
    ) throws -> String {
        final class SpawnResult: @unchecked Sendable {
            var value: Result<String, Error>?
        }
        let box = SpawnResult()
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let paneId = try await server.spawnStandalonePane(
                    cmd: cmd, cwd: cwd, env: env, rows: rows, cols: cols,
                )
                box.value = .success(paneId)
            } catch {
                box.value = .failure(error)
            }
            sema.signal()
        }
        sema.wait()
        guard let result = box.value else {
            throw ControlSpawnError.noResult
        }
        return try result.get()
    }

    private enum ControlSpawnError: Error { case noResult }

    /// `kill` — kills a pane by paneId. Returns `{}` on success.
    static func killPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        let found = server.killPaneForControl(paneId: paneId)
        if found {
            return successResponse(id: id, result: [:])
        }
        return errorResponse(id: id, message: "pane not found: \(paneId)")
    }

    /// `resize` — sets the PTY window size via `TIOCSWINSZ`. Returns `{}` on success.
    ///
    /// Validates `rows` and `cols` are in `1…65535` (validate-then-drop on out-of-range).
    /// The kernel delivers `SIGWINCH` to the foreground process group automatically.
    static func resizePane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let rowsRaw = params["rows"] as? Int, rowsRaw >= 1, rowsRaw <= 65535 else {
            return errorResponse(id: id, message: "rows must be 1..65535")
        }
        guard let colsRaw = params["cols"] as? Int, colsRaw >= 1, colsRaw <= 65535 else {
            return errorResponse(id: id, message: "cols must be 1..65535")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        session.resizeForControl(rows: UInt16(rowsRaw), cols: UInt16(colsRaw))
        return successResponse(id: id, result: [:])
    }

    // MARK: JSON helpers (pure, no Foundation JSONEncoder/Decoder — avoids cyclic-import risk)

    /// Encodes a success response as a NDJSON line.
    static func successResponse(id: String, result: [String: Any]) -> String {
        var obj: [String: Any] = ["id": id, "ok": true]
        if !result.isEmpty { obj["result"] = result }
        return encodeJSON(obj) + "\n"
    }

    /// Encodes an error response as a NDJSON line.
    static func errorResponse(id: String, message: String) -> String {
        let obj: [String: Any] = ["id": id, "ok": false, "error": message]
        return encodeJSON(obj) + "\n"
    }

    /// Minimal JSON encoder — handles the fixed types the verb results produce.
    /// `JSONSerialization` fits here: Foundation is already imported everywhere, no `Codable`
    /// ceremony for a simple string→Any dict.
    static func encodeJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"ok":false,"error":"json encode failure"}"#
        }
        return String(bytes: data, encoding: .utf8) ?? #"{"ok":false,"error":"utf8 encode failure"}"#
    }

    /// Parses one NDJSON request line. Returns `nil` on validate-then-drop (malformed or
    /// oversized lines already filtered by the socket layer).
    public static func parseRequest(_ line: String)
        -> (id: String, method: String, params: [String: Any])?
    {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String
        else { return nil }
        let params = obj["params"] as? [String: Any] ?? [:]
        return (id, method, params)
    }
}

// MARK: - Incremental `wait --until` scanner

/// Incremental matcher for the `wait --until` output scan: decodes UTF-8 + strips ANSI
/// CHUNK-BY-CHUNK and regex-matches only a bounded window, so per-chunk work on the PTY
/// read-loop thread stays O(chunk) instead of O(accumulated) — the old whole-buffer
/// re-decode/re-strip/re-regex was O(n²) over a chatty command's output and lagged the pane's
/// live echo for the duration of the run.
///
/// - A small RAW CARRY (≤ ``maxCarryBytes``) holds back a trailing incomplete UTF-8 sequence or
///   an unterminated ANSI escape so sequences split across chunk boundaries decode/strip exactly
///   as if they had arrived whole. A "sequence" that does not terminate within the carry budget is
///   force-flushed through the stripper — hostile/garbage bytes (or a giant inline-image OSC) must
///   not buffer raw output indefinitely; their body may then surface as plain text, the bounded
///   trade this scanner makes.
/// - The regex runs over the newly stripped text plus the last ``overlapWindow`` characters of
///   what came before (cross-chunk marker matches). A marker longer than the overlap window is not
///   guaranteed to match across a chunk boundary; `^` anchors match the window, not the whole run.
/// - ``stripped`` keeps the full stripped accumulation under the same ``AgentControlHandler/waitBufferCap``
///   cap + trim-oldest-half semantics the raw accumulator had.
struct WaitUntilScanner {
    /// Raw-byte budget for the held-back tail (an escape/UTF-8 sequence still awaiting its
    /// terminator/continuation). Real terminal escapes are far shorter; past this the tail is
    /// force-flushed.
    static let maxCarryBytes = 128

    /// Characters of already-stripped text re-included ahead of each new chunk's match window so a
    /// marker spanning a chunk boundary still matches.
    static let overlapWindow = 4096

    private let regex: NSRegularExpression
    private let bufferCap: Int

    /// Raw bytes held back from the previous chunk (see ``maxCarryBytes``).
    private var carry = Data()

    /// The last ``overlapWindow`` characters of stripped text — the cross-chunk match prefix.
    private var recent = ""

    /// The full stripped accumulation (UTF-8 bytes; storage only — matching is windowed), capped
    /// at `bufferCap` with the oldest half trimmed past the cap.
    private(set) var stripped = Data()

    init(regex: NSRegularExpression, bufferCap: Int = AgentControlHandler.waitBufferCap) {
        self.regex = regex
        self.bufferCap = bufferCap
    }

    /// Feeds one raw PTY chunk. Returns `true` when the pattern matched in the window this chunk
    /// completed (a match is latched by the caller; ingest never needs to re-report it).
    mutating func ingest(_ chunk: Data) -> Bool {
        var pending = [UInt8](carry)
        pending.append(contentsOf: chunk)
        carry.removeAll(keepingCapacity: true)

        var cut = Self.holdbackStart(in: pending)
        // Bound the carry: a sequence that will not terminate within the budget is not a real
        // escape worth waiting for — flush it through the stripper (whose skip helpers handle a
        // runaway body safely) rather than buffering raw bytes without bound.
        if pending.count - cut > Self.maxCarryBytes { cut = pending.count }
        if cut < pending.count { carry = Data(pending[cut...]) }
        guard cut > 0 else { return false }

        let text = ANSIStripper.strip(AgentControlHandler.decodeLossyUTF8(Array(pending[..<cut])))
        guard !text.isEmpty else { return false }

        // Storage accumulator: same cap + trim-oldest-half semantics as the raw buffer had.
        stripped.append(contentsOf: text.utf8)
        if stripped.count > bufferCap {
            stripped = Data(stripped.suffix(bufferCap / 2))
        }

        // Windowed match: the new text plus the trailing overlap of everything before it.
        let searchText = recent + text
        recent = String(searchText.suffix(Self.overlapWindow))
        let range = NSRange(searchText.startIndex..., in: searchText)
        return regex.firstMatch(in: searchText, range: range) != nil
    }

    /// Returns the index from which the tail of `bytes` must be HELD BACK into the next chunk: the
    /// start of a trailing escape sequence that has not terminated yet, or of a trailing truncated
    /// UTF-8 multi-byte codepoint — either can only be stripped/decoded once its continuation
    /// arrives. Mirrors ``ANSIStripper``'s grammar exactly (a forward scan, so a `0x9B`/`0x9D`
    /// UTF-8 continuation byte is never misread as a C1 introducer). `bytes.count` = nothing held.
    static func holdbackStart(in bytes: [UInt8]) -> Int {
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            // Multi-byte UTF-8 lead: hold the whole codepoint back if its continuations are missing.
            if b >= 0xC2, b <= 0xF7 {
                let tail = b >= 0xF0 ? 3 : (b >= 0xE0 ? 2 : 1)
                if i + tail >= n { return i }
                i += tail + 1
                continue
            }
            if b == 0x1B { // ESC
                guard i + 1 < n else { return i } // lone trailing ESC — introducer unknown yet
                switch bytes[i + 1] {
                case 0x5B: // CSI
                    guard let end = csiEnd(bytes, from: i + 2) else { return i }
                    i = end
                case 0x5D, // OSC
                     0x50, // DCS
                     0x58, // SOS
                     0x5E, // PM
                     0x5F: // APC
                    guard let end = stringCommandEnd(bytes, from: i + 2) else { return i }
                    i = end
                case 0x28, // charset designator: ESC + introducer + one designator byte
                     0x29,
                     0x2A,
                     0x2B:
                    guard i + 2 < n else { return i }
                    i += 3
                default:
                    i += 2 // two-byte ESC sequence — complete as-is
                }
                continue
            }
            if b == 0x9B { // raw C1 CSI (never a continuation here — those are consumed above)
                guard let end = csiEnd(bytes, from: i + 1) else { return i }
                i = end
            } else if b == 0x9D { // raw C1 OSC
                guard let end = stringCommandEnd(bytes, from: i + 1) else { return i }
                i = end
            } else {
                i += 1
            }
        }
        return n
    }

    /// The index just past a CSI body starting at `start` (params + intermediates + one final
    /// byte), or `nil` when the body runs off the end of `bytes` (final byte not yet arrived).
    /// A non-final, non-body byte ends the sequence malformed-but-complete, matching
    /// `ANSIStripper.skipCSI`.
    private static func csiEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x3F { i += 1 } // parameter bytes
        while i < bytes.count, bytes[i] >= 0x20, bytes[i] <= 0x2F { i += 1 } // intermediate bytes
        guard i < bytes.count else { return nil }
        return (bytes[i] >= 0x40 && bytes[i] <= 0x7E) ? i + 1 : i // final byte (or malformed stop)
    }

    /// The index just past an OSC/DCS/SOS/PM/APC body starting at `start` (terminated by BEL, C1
    /// ST, or `ESC \` — a bare ESC counts as a malformed terminator, matching
    /// `ANSIStripper.skipStringCommand`), or `nil` when no terminator has arrived yet (a trailing
    /// lone ESC is undecidable — it may be the first byte of ST).
    private static func stringCommandEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x07 || b == 0x9C { return i + 1 }
            if b == 0x1B {
                guard i + 1 < bytes.count else { return nil }
                return bytes[i + 1] == 0x5C ? i + 2 : i + 1
            }
            i += 1
        }
        return nil
    }
}

// MARK: - E14/K13 IPC guards (host-side, no crypto)

/// The resolved send-keys / sensitive-session permissions for the agent-control ctl socket (E14/K13).
///
/// Pure value the dispatcher consults BEFORE running a mutating verb. The flags resolve from the host
/// env (``HostEnvironment/ipcAllowSendKeys(environment:)`` / ``ipcAllowSensitiveSessions(environment:)``)
/// at the dispatch site via ``resolved()`` — DEFAULT-OFF (only an explicit `"1"` enables), same idiom as
/// ``HostEnvironment/agentControlEnabled(environment:)``. **No new socket, no tokens, no crypto:** host-side
/// guards on the existing NDJSON ctl socket; the WireGuard mesh is the security boundary.
public struct IPCGuards: Sendable {
    /// Whether the MUTATING verbs (`write`/`run`/`spawn`/`kill`/`resize`) may run at all.
    public let allowSendKeys: Bool
    /// Whether a mutating verb may target a pane running a SENSITIVE foreground process
    /// (`ssh`/`sudo`/`login`/…).
    public let allowSensitiveSessions: Bool

    public init(allowSendKeys: Bool, allowSensitiveSessions: Bool) {
        self.allowSendKeys = allowSendKeys
        self.allowSensitiveSessions = allowSensitiveSessions
    }

    /// Resolves both guards from the host env at the dispatch site (default-OFF). The client toggles map
    /// onto these via the env bridge (set identically host+client, like `SLOPDESK_FEC_M`); a live client
    /// edit applies on the NEXT host launch. Evaluated at the call site (the `dispatch` default argument).
    public static func resolved() -> Self {
        Self(
            allowSendKeys: HostEnvironment.ipcAllowSendKeys(),
            allowSensitiveSessions: HostEnvironment.ipcAllowSensitiveSessions(),
        )
    }
}

/// Decides whether a pane's foreground-process BASENAME is a "sensitive" command — a mutating ctl verb
/// driven into a live `sudo`/`ssh`/`login` password prompt is exactly the threat K13 closes when
/// ``IPCGuards/allowSensitiveSessions`` is OFF. The host has no broader sensitive-session detector, so
/// this is the small, BOUNDED basename list the plan calls for (no env, no allocation beyond the
/// basename split — a pure decision unit-pinned by `IPCGuardTests`).
public enum SensitiveSessionPolicy {
    /// The bounded set of sensitive foreground-command basenames (credential / remote-shell entry points).
    /// Matched CASE-SENSITIVELY against the basename, like the foreground-process basenames the host
    /// already resolves (``ForegroundProcessDetector/basename(of:)``).
    public static let sensitiveBasenames: Set<String> = [
        "ssh",
        "sshpass",
        "ssh-agent",
        "ssh-add",
        "sudo",
        "doas",
        "su",
        "login",
        "passwd",
        "gpg",
        "security",
    ]

    /// Whether `processName` (a foreground-process basename, or a full path that is reduced to its last
    /// component) is a sensitive command. An EMPTY / unknown name is NOT sensitive — the host could not
    /// prove a sensitive session, and the send-keys gate already guards the mutating path, so the benign
    /// default is to allow rather than fail-closed on an unresolved probe.
    public static func isSensitive(processName: String) -> Bool {
        guard !processName.isEmpty else { return false }
        // Reuse the host's basename reducer so a full path and a bare basename match identically.
        let base = ForegroundProcessDetector.basename(of: processName)
        return sensitiveBasenames.contains(base)
    }
}

// MARK: - Thin socket shim

/// The THIN `AF_UNIX` stream socket shim for the agent-control protocol.
///
/// One accepted connection gets one background thread that reads NDJSON lines (bounded to
/// ``maxRequestBytes`` per line), dispatches each to ``AgentControlHandler``, and writes the
/// response. Connections are long-lived (agents pipeline requests).
///
/// **Compiled + code-reviewed only** — never bound in a unit test (hang-safety: no real socket
/// in tests; the pure ``AgentControlHandler`` is tested separately).
public final class AgentControlAcceptor: @unchecked Sendable {
    private let server: HostServer
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPath: String?

    public var onLog: (@Sendable (String) -> Void)?

    /// Max bytes per request line (validate-then-drop beyond this).
    static let maxRequestBytes = 64 * 1024

    public init(server: HostServer) {
        self.server = server
    }

    /// Binds the socket at `path`, chmods it 0600, and begins accepting.
    public func start(path: String) throws {
        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxPath else {
            throw AgentSocketError.pathTooLong(path)
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
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
            throw AgentSocketError.bindFailed(e)
        }

        // Restrict to the running user (agents on the same machine, same uid only).
        Darwin.chmod(path, 0o600)

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
        onLog?("agent-control socket listening at \(path)")
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

    // MARK: Accept loop

    private func acceptLoop(fd listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { return } // listen fd closed by stop() → exit
            // Each connection gets its own background thread for the blocking read loop.
            let server = server
            let log = onLog
            Thread.detachNewThread {
                Self.serveConnection(fd: conn, server: server, log: log)
                close(conn)
            }
        }
    }

    // MARK: Per-connection NDJSON loop

    /// Reads NDJSON lines from `fd`, dispatches each to ``AgentControlHandler``, writes the
    /// response, and loops until EOF or an I/O error.
    private static func serveConnection(
        fd: Int32,
        server: HostServer,
        log: (@Sendable (String) -> Void)?,
    ) {
        var lineBuffer = Data()

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // EOF or error — connection closed

            lineBuffer.append(contentsOf: chunk[0..<n])

            // Process all complete lines (delimited by '\n') in the buffer.
            while let nlIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[lineBuffer.startIndex..<nlIndex]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: nlIndex)...])

                // Validate-then-drop: oversized or non-UTF-8 request lines.
                guard lineData.count <= maxRequestBytes else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "request too large")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }
                guard let line = String(bytes: lineData, encoding: .utf8) else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "invalid UTF-8")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                // Parse and dispatch (validate-then-drop bad JSON / missing fields).
                guard let (reqID, method, params) = AgentControlHandler.parseRequest(trimmed) else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "malformed request")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }

                // `subscribe` hijacks the connection: it streams NDJSON event lines and never
                // returns to the request-dispatch loop. The server does NOT emit an initial
                // {id,ok,result} handshake line — it immediately begins streaming events.
                if method == "subscribe" {
                    // A `subscribe` with NO paneId is the TOP-LEVEL supervision stream: fan
                    // `agent_status_changed` across ALL panes. A present paneId is the per-pane
                    // output stream. (A missing paneId is a VALID all-mode — not an error.)
                    if params["paneId"] is String {
                        serveSubscribe(fd: fd, id: reqID, params: params, server: server, log: log)
                    } else {
                        serveSubscribeAll(fd: fd, id: reqID, server: server, log: log)
                    }
                    return // connection consumed; caller closes fd
                }

                // Dispatch (may block for `wait`).
                let response = AgentControlHandler.dispatch(
                    id: reqID, method: method, params: params, server: server,
                )
                writeAll(fd: fd, data: Data(response.utf8))
            }

            // Drop an oversized partial line (validate-then-drop).
            if lineBuffer.count > maxRequestBytes {
                log?("agent-control: oversized partial line (\(lineBuffer.count) bytes) — discarding")
                lineBuffer.removeAll(keepingCapacity: false)
            }
        }
    }

    // MARK: subscribe — streaming event pump

    /// Implements the `subscribe` verb: streams NDJSON event lines to `fd` until the pane exits
    /// or the client disconnects (EPIPE). No initial handshake line — streaming begins immediately.
    /// The connection fd is consumed (this method owns it until return).
    ///
    /// Event shapes (one UTF-8 NDJSON line per event, newline-terminated):
    /// - `{"event":"output","text":"<plain-text chunk>"}` — zero or more per PTY read chunk
    ///   (ANSI-stripped for clean agent consumption).
    /// - `{"event":"closed"}` — exactly one, after the PTY read loop has fully drained to EOF
    ///   (guaranteed after all `output` events for the session).
    ///
    /// Cleanup: both observers are removed on any disconnect or pane exit. The pump runs on the
    /// connection thread already detached by the acceptor — no new thread needed.
    private static func serveSubscribe(
        fd: Int32,
        id: String,
        params: [String: Any],
        server: HostServer,
        log _: (@Sendable (String) -> Void)?,
    ) {
        guard let paneId = params["paneId"] as? String else {
            let resp = AgentControlHandler.errorResponse(id: id, message: "missing params.paneId")
            writeAll(fd: fd, data: Data(resp.utf8))
            return
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            let resp = AgentControlHandler.errorResponse(id: id, message: "pane not found: \(paneId)")
            writeAll(fd: fd, data: Data(resp.utf8))
            return
        }

        // `ansiStrip` — default ON (strip ANSI for clean agent text). The client may pass
        // `ansiStrip: false` to receive raw PTY bytes (e.g. to parse colour codes itself).
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true

        // Box shared state under NSCondition so the output observer (PTY read-loop thread) and
        // close observer (exit task thread) deliver events to the pump thread safely. Swift 6
        // strict sendability: mutable state lives in an @unchecked Sendable class; the NSCondition
        // serialises all accesses — no captured `var`s across concurrency boundaries.
        final class SubscribeState: @unchecked Sendable {
            let condition = NSCondition()
            var lines: [Data] = [] // pending NDJSON event lines buffered by observers
            var closed = false // set by the close observer when the PTY exits
        }
        let state = SubscribeState()
        let observerID = UUID()

        // Output observer — runs on the PTY read-loop thread for every raw chunk.
        session.registerOutputObserver(id: observerID) { chunk in
            // Optionally strip ANSI for clean agent text (PUA glyphs and charset designators
            // removed). When ansiStrip is false the raw PTY bytes are passed through.
            let rawStr: String =
                if let utf8 = String(bytes: chunk, encoding: .utf8) {
                    utf8
                } else {
                    String(chunk.map { $0 < 0x80 ? $0 : UInt8(0x3F) }
                        .map { Character(UnicodeScalar($0)) })
                }
            let text = ansiStrip ? ANSIStripper.strip(rawStr) : rawStr
            guard !text.isEmpty else { return }
            let eventObj: [String: Any] = ["event": "output", "text": text]
            guard let eventData = try? JSONSerialization.data(withJSONObject: eventObj, options: [.sortedKeys]),
                  var lineData = Optional(eventData)
            else { return }
            lineData.append(0x0A)
            state.condition.lock()
            if !state.closed {
                state.lines.append(lineData)
                state.condition.signal()
            }
            state.condition.unlock()
        }

        // Close observer — runs from the exit task after awaitEOFOrTimeout (all output
        // observer calls for this pane have completed before this fires).
        session.registerCloseObserver(id: observerID) {
            state.condition.lock()
            state.closed = true
            state.condition.signal()
            state.condition.unlock()
        }

        // Pump loop: park on the condition, drain the pending batch, write to fd.
        // Detect client disconnect via write(2) failure (EPIPE / -1).
        var clientDisconnected = false
        while !clientDisconnected {
            state.condition.lock()
            while state.lines.isEmpty, !state.closed {
                state.condition.wait()
            }
            let batch = state.lines
            let isClosed = state.closed
            state.lines.removeAll(keepingCapacity: true)
            state.condition.unlock()

            for line in batch {
                var ok = true
                line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { ok = false
                        return
                    }
                    var offset = 0
                    let total = raw.count
                    while offset < total {
                        let n = write(fd, base + offset, total - offset)
                        if n > 0 { offset += n }
                        else if n < 0, errno == EINTR { continue }
                        else { ok = false
                            return
                        } // EPIPE or other error → client gone
                    }
                }
                if !ok {
                    clientDisconnected = true
                    break
                }
            }
            if isClosed { break } // pane exited; emit closed event below and return
        }

        // Deregister both observers before touching the fd again.
        session.removeOutputObserver(id: observerID)
        session.removeCloseObserver(id: observerID)

        // Emit {"event":"closed"} only on a clean pane-exit (not on client disconnect so we
        // do not write to a broken pipe). `state.closed` is set exclusively by the close
        // observer and is only true when the PTY exit task fired — not on write failure.
        if !clientDisconnected {
            let closedObj: [String: Any] = ["event": "closed"]
            if var closedData = try? JSONSerialization.data(withJSONObject: closedObj, options: [.sortedKeys]) {
                closedData.append(0x0A)
                writeAll(fd: fd, data: closedData)
            }
        }
    }

    // MARK: subscribe --all — cross-pane agent_status_changed pump

    /// Implements the TOP-LEVEL `subscribe` (no paneId): streams one NDJSON line per pane
    /// status transition across ALL panes until the client disconnects. No initial handshake.
    ///
    /// Event shape (one UTF-8 NDJSON line, newline-terminated):
    ///   `{"type":"agent_status_changed","paneId":"<uuid>","state":"<idle|working|done|blocked>","title":"<osc title>","ts":<unix-seconds>}`
    ///
    /// Reuses the SAME ``SubscribeState``/`NSCondition`/`writeAll` pattern as ``serveSubscribe``.
    /// A server-level observer (``HostServer/registerAgentStatusObserver(id:_:)``) pushes lines
    /// into the condition-guarded buffer; the pump drains them to `fd`. Consecutive identical
    /// `(paneId, state)` pairs are deduped at the fan-out (the detector already dedupes type-27,
    /// but a belt-and-braces per-pane dedupe defends against any double-notify). The observer is
    /// deregistered on disconnect; the fd is consumed (this method owns it).
    private static func serveSubscribeAll(
        fd: Int32,
        id _: String,
        server: HostServer,
        log _: (@Sendable (String) -> Void)?,
    ) {
        // Mutable cross-thread state guarded by an NSCondition (Swift 6 strict sendability).
        // `closed` is the disconnect-wakeup the per-pane `serveSubscribe` gets from its close
        // observer: here a dedicated reader thread sets it on client EOF/error so an IDLE-then-
        // disconnected `events` subscriber (the common case — no pane has transitioned, so the
        // pump would otherwise park in `wait()` forever, leaking the observer + fd + thread) is
        // reaped. Without this, a trusted-mesh peer could open N idle `events` subscriptions and
        // drop them to exhaust the host's thread/fd budget — which the never-DoS posture forbids.
        final class AllState: @unchecked Sendable {
            let condition = NSCondition()
            var lines: [Data] = []
            var lastByPane: [String: String] = [:] // paneId → last emitted state (dedupe)
            var closed = false // set by the reader thread on client disconnect
        }
        let state = AllState()
        let observerID = UUID()

        server.registerAgentStatusObserver(id: observerID) { paneId, stateStr, title, ts in
            state.condition.lock()
            // Drop late events once the client is gone (the reader already woke the pump).
            if state.closed {
                state.condition.unlock()
                return
            }
            // Dedupe consecutive identical (paneId, state) — a redundant transition is dropped.
            if state.lastByPane[paneId] == stateStr {
                state.condition.unlock()
                return
            }
            state.lastByPane[paneId] = stateStr
            let eventObj: [String: Any] = [
                "type": "agent_status_changed",
                "paneId": paneId,
                "state": stateStr,
                "title": title,
                "ts": ts,
            ]
            guard var lineData = try? JSONSerialization.data(withJSONObject: eventObj, options: [.sortedKeys]) else {
                state.condition.unlock()
                return
            }
            lineData.append(0x0A)
            state.lines.append(lineData)
            state.condition.signal()
            state.condition.unlock()
        }

        // Disconnect reader: the `events` client never sends after the subscribe request, so a
        // `read(2)` returning 0 (EOF) or -1 (error, non-EINTR) means it disconnected — even while
        // the host is idle. Set `closed` + signal the pump so it returns and the observer is
        // deregistered. This mirrors `serveSubscribe`'s `registerCloseObserver` wakeup.
        Thread.detachNewThread {
            var scratch = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(fd, &scratch, scratch.count)
                if n > 0 { continue } // unexpected client chatter — ignore, keep watching
                if n < 0, errno == EINTR { continue }
                break // 0 == EOF, or a real error → client gone
            }
            state.condition.lock()
            state.closed = true
            state.condition.signal()
            state.condition.unlock()
        }

        // Pump: park on the condition until a line is ready OR the client disconnected, drain
        // pending lines, write to fd. A write failure (EPIPE / -1) also flags disconnect.
        var clientDisconnected = false
        while !clientDisconnected {
            state.condition.lock()
            while state.lines.isEmpty, !state.closed {
                state.condition.wait()
            }
            if state.closed {
                state.condition.unlock()
                break
            }
            let batch = state.lines
            state.lines.removeAll(keepingCapacity: true)
            state.condition.unlock()

            for line in batch {
                var ok = true
                line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { ok = false
                        return
                    }
                    var offset = 0
                    let total = raw.count
                    while offset < total {
                        let n = write(fd, base + offset, total - offset)
                        if n > 0 { offset += n }
                        else if n < 0, errno == EINTR { continue }
                        else { ok = false
                            return
                        }
                    }
                }
                if !ok {
                    clientDisconnected = true
                    break
                }
            }
        }

        server.removeAgentStatusObserver(id: observerID)
        // The reader thread is parked in `read(fd)`. The caller (`serveConnection`/`acceptLoop`)
        // `close(fd)`s right after this returns, which makes the blocked `read` return and the
        // reader thread exits — no leak.
    }

    // MARK: writeAll helper (handles EINTR + partial writes)

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 { offset += n }
                else if n < 0 { if errno == EINTR { continue }
                    return
                } else { return }
            }
        }
    }
}
