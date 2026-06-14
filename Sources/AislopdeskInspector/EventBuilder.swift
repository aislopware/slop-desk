import Foundation

/// Folds parsed ``TranscriptLine``s (and hook payloads) into ``InspectorEvent``s,
/// maintaining the cross-line state the events need: tool-card pairing, the latest
/// todo list, subagent nodes, and a dedup set.
///
/// Pure and synchronous — no I/O, no concurrency. The tailer / watcher / hook seam
/// feed lines in; this produces the typed events. Keeping it a value-free `struct`
/// of mutable state (driven from a single actor / task) makes it trivially testable
/// with fixtures and means the ordering is exactly the feed order.
///
/// Tool-card pairing rules (doc 16, "ghép qua tool_use_id"):
/// - a `tool_use` opens a `pending` card and emits it;
/// - a later `tool_result` with matching `tool_use_id` completes/errors it and
///   re-emits the card with the new status + output;
/// - **out-of-order**: a `tool_result` seen *before* its `tool_use` is held, then
///   applied when the `tool_use` arrives (the card is emitted once, already resolved);
/// - **missing result**: a card with no result stays `pending` forever (no crash);
/// - `is_error == true` ⇒ `.errored`.
public struct EventBuilder {
    /// Cap on the dedup ring (``processedKeys``). One line ≈ one entry; this covers any
    /// realistic Claude Code transcript so the truncation/rotation *full re-read* (the
    /// tailer resets its offset to 0 and re-feeds the whole file) still dedups, while
    /// bounding memory on a pathologically long/adversarial session. See the dedup note.
    static let processedKeyCap = 100_000

    /// Cap on each held-out-of-order ``pendingResults`` map. A `tool_result` whose
    /// `tool_use` never arrives (truncated/corrupt transcript, or an adversarial feed of
    /// orphan results) would otherwise be retained forever; we evict oldest past the cap.
    static let pendingResultCap = 4096

    /// Cap on the number of distinct SUBAGENT ids retained (R17 INSP-LEAK-1, the host analogue of the
    /// client's R13 #4 ``InspectorViewModel`` agent cap). The per-subagent maps below (`subagents`,
    /// `subagentOpenCards`, `subagentPendingResults`, `subagentPendingResultOrder`) are keyed by
    /// agentID and were never evicted on the agentID DIMENSION — so a long session (or an adversarial
    /// transcript declaring many distinct subagent ids) grew them for the host's whole lifetime. Once
    /// past ``maxAgents`` the oldest agents are dropped to ``agentRetainTarget`` in one batch, removing
    /// all of their per-agent state together.
    static let maxAgents = 2000
    static let agentRetainTarget = 1500

    /// Dedup keys already processed (doc 16 `processedMessageKeys`). Keyed by line
    /// uuid (main) or `sidechain:<agentID>:<uuid>` so a re-read tail never double-emits.
    ///
    /// Bounded as an **insertion-ordered ring**: ``processedKeyOrder`` records insertion
    /// order so the oldest key can be evicted once the set passes ``processedKeyCap``.
    /// The cap is large enough to span any real transcript, so the only re-read that
    /// matters (truncation → full re-read from offset 0) still dedups every line.
    private var processedKeys: Set<String> = []
    private var processedKeyOrder: [String] = []

    /// Open tool cards by id (main session). Used to apply a later `tool_result`.
    /// A card is **dropped** the moment it reaches a terminal status (`.completed` /
    /// `.errored`) — no later result can change it, so retaining it only leaks memory.
    private var openCards: [String: ToolCard] = [:]

    /// `tool_result`s that arrived before their `tool_use` (out-of-order), keyed by id.
    /// Bounded by ``pendingResultCap`` (insertion-ordered eviction) so an orphan result
    /// never accumulates without bound.
    private var pendingResults: [String: ToolResultBlock] = [:]
    private var pendingResultOrder: [String] = []

    /// Per-subagent open cards, keyed `agentID` → (cardID → card). Same terminal-drop as
    /// ``openCards``.
    private var subagentOpenCards: [String: [String: ToolCard]] = [:]
    private var subagentPendingResults: [String: [String: ToolResultBlock]] = [:]
    /// Insertion order of held subagent results, keyed by `agentID`, for the same cap.
    private var subagentPendingResultOrder: [String: [String]] = [:]

    /// Known subagent nodes by id (so a status change re-emits the same node).
    private var subagents: [String: SubagentNode] = [:]

    /// Distinct subagent ids seen, in first-sight order, for the drop-oldest agent cap (INSP-LEAK-1).
    private var seenAgents: Set<String> = []
    private var agentOrder: [String] = []

    /// The latest todo list (replaced wholesale on each `TodoWrite`/`Task*`).
    private var latestTodos: [TodoItem] = []

    public init() {}

    // MARK: - Main-session lines

    /// Folds one main-session transcript line into zero or more events.
    public mutating func ingest(line: TranscriptLine) -> [InspectorEvent] {
        switch line {
        case let .user(user):
            ingestUser(user, agentID: nil)
        case let .assistant(assistant):
            ingestAssistant(assistant, agentID: nil)
        case let .meta(meta):
            ingestMeta(meta)
        case .ignored:
            []
        case let .unknown(raw):
            [.unknownLine(raw: raw)]
        }
    }

    /// Folds one **subagent** transcript line (from a `subagents/agent-<hash>.jsonl`
    /// file). `agentID` identifies the owning subagent node.
    public mutating func ingestSubagent(line: TranscriptLine, agentID: String) -> [InspectorEvent] {
        switch line {
        case let .user(user):
            ingestUser(user, agentID: agentID)
        case let .assistant(assistant):
            ingestAssistant(assistant, agentID: agentID)
        case .meta,
             .ignored:
            []
        case let .unknown(raw):
            [.unknownLine(raw: raw)]
        }
    }

    // MARK: - Hook folding (seam, doc 16)

    /// Folds a typed hook payload into the stream. Hooks are a *push* channel that
    /// complements the JSONL tail (SessionStart gives the path; PostToolUse gives a
    /// sub-second card; SubagentStop links a subagent file in).
    public mutating func ingest(hook: HookPayload) -> [InspectorEvent] {
        switch hook {
        case let .sessionStart(info):
            return [.sessionStarted(info)]

        case let .postToolUse(toolUse, result):
            // A PostToolUse hook can arrive before the JSONL flush (doc 16). Treat it
            // exactly like seeing the tool_use (+ optional result) so the card shows
            // immediately; the later JSONL line dedups on the same card id.
            var events = applyToolUse(toolUse, agentID: nil)
            if let result {
                events += applyToolResult(result, agentID: nil)
            }
            return events

        case let .subagentStop(node):
            // Mark the subagent stopped (creating the node if first seen). The file at
            // `agent_transcript_path` is tailed separately by the watcher.
            return updateSubagent(node)
        }
    }

    // MARK: - Subagent node lifecycle

    /// Records a (possibly new) agentID and, once past ``maxAgents``, evicts the OLDEST agents to
    /// ``agentRetainTarget`` — removing ALL of their per-agent state together so no per-agent map leaks
    /// the agentID dimension over a long session (INSP-LEAK-1). Idempotent for an already-seen id.
    private mutating func noteAgent(_ agentID: String) {
        guard seenAgents.insert(agentID).inserted else { return }
        agentOrder.append(agentID)
        guard agentOrder.count > Self.maxAgents else { return }
        let evictCount = agentOrder.count - Self.agentRetainTarget
        let evicted = agentOrder.prefix(evictCount)
        agentOrder.removeFirst(evictCount)
        for old in evicted {
            seenAgents.remove(old)
            subagents.removeValue(forKey: old)
            subagentOpenCards.removeValue(forKey: old)
            subagentPendingResults.removeValue(forKey: old)
            subagentPendingResultOrder.removeValue(forKey: old)
        }
    }

    /// Number of distinct subagent ids currently tracked (≤ ``maxAgents``). Test/diagnostics seam.
    var trackedAgentCount: Int { agentOrder.count }

    /// Records/updates a subagent node and emits the change (idempotent on no-change).
    public mutating func updateSubagent(_ node: SubagentNode) -> [InspectorEvent] {
        noteAgent(node.id)
        let existing = subagents[node.id]
        // Merge: a later update (e.g. SubagentStop) should not blank fields a meta file
        // already supplied.
        var merged = node
        if let existing {
            merged.parentID = node.parentID ?? existing.parentID
            merged.agentType = node.agentType ?? existing.agentType
            merged.description = node.description ?? existing.description
            merged.lastAssistantMessage = node.lastAssistantMessage ?? existing.lastAssistantMessage
        }
        if merged == existing { return [] }
        subagents[node.id] = merged
        return [.subagentUpdated(merged)]
    }

    // MARK: - User / assistant

    private mutating func ingestUser(_ user: UserLine, agentID: String?) -> [InspectorEvent] {
        guard markProcessed(user.identity, agentID: agentID) else { return [] }
        var events: [InspectorEvent] = []
        if let text = user.text, !text.isEmpty {
            events.append(.message(MessageEvent(role: .user, text: text, agentID: agentID)))
        }
        for result in user.toolResults {
            events += applyToolResult(result, agentID: agentID)
        }
        return events
    }

    private mutating func ingestAssistant(_ assistant: AssistantLine, agentID: String?) -> [InspectorEvent] {
        guard markProcessed(assistant.identity, agentID: agentID) else { return [] }
        var events: [InspectorEvent] = []
        for thinking in assistant.thinkingBlocks {
            events.append(.thinking(ThinkingMarker(
                isPlaceholder: thinking.isPlaceholder,
                signature: thinking.signature,
                text: thinking.text,
            )))
        }
        if let text = assistant.text, !text.isEmpty {
            events.append(.message(MessageEvent(role: .assistant, text: text, agentID: agentID)))
        }
        for use in assistant.toolUses {
            // Todos/tasks are accumulated state, not a card (doc 16).
            if let todoEvent = todosEvent(from: use) {
                events.append(todoEvent)
            } else {
                events += applyToolUse(use, agentID: agentID)
            }
        }
        return events
    }

    private mutating func ingestMeta(_ meta: MetaLine) -> [InspectorEvent] {
        guard markProcessed(meta.identity, agentID: nil) else { return [] }
        // Only surface session-defining metadata (model / cwd / id). Other meta lines
        // carry no UI value.
        if meta.sessionID != nil || meta.model != nil || meta.cwd != nil {
            return [.sessionStarted(SessionInfo(sessionID: meta.sessionID, model: meta.model, cwd: meta.cwd))]
        }
        return []
    }

    // MARK: - Tool-card pairing

    private mutating func applyToolUse(_ use: ToolUseBlock, agentID: String?) -> [InspectorEvent] {
        // If a result already arrived out-of-order, resolve immediately. The card is
        // born terminal, so we do NOT keep it open — no further result can change it.
        if let pending = takePendingResult(id: use.id, agentID: agentID) {
            let card = ToolCard(
                id: use.id, name: use.name, input: use.input,
                output: pending.content,
                status: pending.isError ? .errored : .completed,
            )
            return cardEvent(card, agentID: agentID)
        }
        let card = ToolCard(id: use.id, name: use.name, input: use.input, status: .pending)
        setOpenCard(card, agentID: agentID)
        return cardEvent(card, agentID: agentID)
    }

    private mutating func applyToolResult(_ result: ToolResultBlock, agentID: String?) -> [InspectorEvent] {
        guard var card = openCard(id: result.toolUseID, agentID: agentID) else {
            // Out-of-order: result before tool_use. Hold it.
            setPendingResult(result, agentID: agentID)
            return []
        }
        card.output = result.content
        card.status = result.isError ? .errored : .completed
        // Terminal now: drop the open card so the map cannot grow unbounded over a long
        // session. The line-uuid dedup (``processedKeys``) guarantees neither this
        // `tool_result` line nor its `tool_use` line is re-applied, so a later lookup
        // can never need this entry again.
        clearOpenCard(id: card.id, agentID: agentID)
        return cardEvent(card, agentID: agentID)
    }

    private func cardEvent(_ card: ToolCard, agentID: String?) -> [InspectorEvent] {
        if let agentID {
            return [.subagentToolCard(agentID: agentID, card: card)]
        }
        return [.toolCard(card)]
    }

    // MARK: - Todos

    /// Parses a `TodoWrite` / `TaskCreate`-style payload into the latest todo list.
    /// Returns the `todosUpdated` event, or `nil` if `use` is not a todo/task tool.
    private mutating func todosEvent(from use: ToolUseBlock) -> InspectorEvent? {
        guard use.name == "TodoWrite" || use.name == "TaskCreate" || use.name == "TaskUpdate" else {
            return nil
        }
        // Both shapes carry a `todos` (TodoWrite) or `tasks` array of objects. Distinguish "no array
        // supplied" from "an explicitly empty array": a payload carrying NEITHER key (e.g. a partial
        // single-task update) must NOT blank the whole panel — return nil (no event, list untouched).
        // A present array (even empty) DOES replace the list — an empty `todos: []` is a legitimate clear.
        guard let array = use.input["todos"]?.arrayValue ?? use.input["tasks"]?.arrayValue else {
            return nil
        }
        let items: [TodoItem] = array.compactMap { entry in
            guard case let .object(obj) = entry else { return nil }
            let content = obj["content"]?.stringValue
                ?? obj["description"]?.stringValue
                ?? obj["text"]?.stringValue
            guard let content else { return nil }
            let statusRaw = obj["status"]?.stringValue ?? "pending"
            let status = TodoItem.Status(rawValue: statusRaw) ?? .pending
            return TodoItem(content: content, status: status, activeForm: obj["activeForm"]?.stringValue)
        }
        latestTodos = items
        return .todosUpdated(items)
    }

    /// The current todo snapshot (used by tests + replay-from-scratch).
    public var todos: [TodoItem] { latestTodos }

    // MARK: - Dedup

    /// Marks a line processed; returns `false` if it was already seen (so the caller
    /// emits nothing). A line without a uuid is always processed (can't dedup it, but
    /// the tailer guarantees each physical line is fed once).
    private mutating func markProcessed(_ identity: LineIdentity, agentID: String?) -> Bool {
        guard let uuid = identity.uuid else { return true }
        let key = agentID.map { "sidechain:\($0):\(uuid)" } ?? uuid
        guard processedKeys.insert(key).inserted else { return false }
        processedKeyOrder.append(key)
        // Insertion-ordered ring: once past the cap, evict the oldest key so the dedup
        // set stays bounded over a very long session. The cap spans any realistic
        // transcript, so the truncation full re-read still dedups every live line.
        if processedKeyOrder.count > Self.processedKeyCap {
            let oldest = processedKeyOrder.removeFirst()
            processedKeys.remove(oldest)
        }
        return true
    }

    // MARK: - Open-card / pending-result storage (main vs subagent)

    private func openCard(id: String, agentID: String?) -> ToolCard? {
        if let agentID { return subagentOpenCards[agentID]?[id] }
        return openCards[id]
    }

    private mutating func setOpenCard(_ card: ToolCard, agentID: String?) {
        if let agentID {
            noteAgent(agentID)
            subagentOpenCards[agentID, default: [:]][card.id] = card
        } else {
            openCards[card.id] = card
        }
    }

    /// Drops a (now-terminal) open card so the open-card map cannot grow unbounded.
    private mutating func clearOpenCard(id: String, agentID: String?) {
        if let agentID {
            subagentOpenCards[agentID]?.removeValue(forKey: id)
        } else {
            openCards.removeValue(forKey: id)
        }
    }

    private mutating func setPendingResult(_ result: ToolResultBlock, agentID: String?) {
        if let agentID {
            noteAgent(agentID)
            // Overwrite of an existing id keeps the same order slot (idempotent re-feed),
            // so only track order on a genuinely new id.
            let isNew = subagentPendingResults[agentID]?[result.toolUseID] == nil
            subagentPendingResults[agentID, default: [:]][result.toolUseID] = result
            if isNew {
                subagentPendingResultOrder[agentID, default: []].append(result.toolUseID)
                evictSubagentPendingIfNeeded(agentID: agentID)
            }
        } else {
            let isNew = pendingResults[result.toolUseID] == nil
            pendingResults[result.toolUseID] = result
            if isNew {
                pendingResultOrder.append(result.toolUseID)
                evictPendingIfNeeded()
            }
        }
    }

    private mutating func takePendingResult(id: String, agentID: String?) -> ToolResultBlock? {
        if let agentID {
            let taken = subagentPendingResults[agentID]?.removeValue(forKey: id)
            if taken != nil, let idx = subagentPendingResultOrder[agentID]?.firstIndex(of: id) {
                subagentPendingResultOrder[agentID]?.remove(at: idx)
            }
            return taken
        }
        let taken = pendingResults.removeValue(forKey: id)
        if taken != nil, let idx = pendingResultOrder.firstIndex(of: id) {
            pendingResultOrder.remove(at: idx)
        }
        return taken
    }

    /// Evicts the oldest held main-session result(s) once the cap is exceeded. An orphan
    /// result (no matching `tool_use` ever) is the only thing that lingers; dropping the
    /// oldest is correct (its card would have been emitted long ago if the use existed).
    private mutating func evictPendingIfNeeded() {
        while pendingResultOrder.count > Self.pendingResultCap {
            let oldest = pendingResultOrder.removeFirst()
            pendingResults.removeValue(forKey: oldest)
        }
    }

    private mutating func evictSubagentPendingIfNeeded(agentID: String) {
        while (subagentPendingResultOrder[agentID]?.count ?? 0) > Self.pendingResultCap {
            guard let oldest = subagentPendingResultOrder[agentID]?.removeFirst() else { break }
            subagentPendingResults[agentID]?.removeValue(forKey: oldest)
        }
    }
}
