import Foundation

/// Typed Claude Code hook payloads (doc 14 §Hooks, doc 16 §Hooks).
///
/// Claude Code hooks (`SessionStart`, `PostToolUse`, `SubagentStop`) POST small JSON
/// payloads to a local listener. The actual HTTP / stdin wiring is host-app glue;
/// this type is the **seam**: the typed model + a parser. It is unit-tested against
/// fixture payloads.
///
/// This file is the DETECTION path (`docs/50`), not the inspector: a hook record is what
/// `AgentHookListener` folds into `ClaudeStatusMachine`. It never fed the inspector's event
/// stream, which is why it stayed in Swift when everything that DID move to
/// `rust/slopdesk-inspectord` (`docs/54`).
public enum HookPayload: Sendable, Equatable {
    /// `SessionStart` → `transcript_path` + `session_id` + `model` (doc 16). This is
    /// how the inspector discovers which JSONL file to tail — we do **not** reconstruct
    /// the path from `cwd` (doc 16 specifies taking the path from the `transcript_path` field).
    case sessionStart(SessionInfo)

    /// `PostToolUse` → full tool name + input + (optional) result, sub-second, before
    /// the JSONL flush (doc 16) → an immediate card. The result is optional because
    /// some hook configs fire pre-result.
    case postToolUse(ToolUseBlock, ToolResultBlock?)

    /// `SubagentStop` → the subagent node, crucially carrying `agent_transcript_path`
    /// (doc 16: the signal that links a `subagents/agent-<hash>.jsonl` file in) plus
    /// `agent_id` / `agent_type` / `last_assistant_message`.
    case subagentStop(SubagentNode)

    /// `UserPromptSubmit` → a user prompt was submitted (a turn began → *working*).
    /// Carries the session identity the detector needs plus the raw `prompt` text — the
    /// host's agent-session INTENT source (each titleable prompt re-titles the session,
    /// wire type 36). 1:1 → `ClaudeHookEvent.userPromptSubmit(sessionID:)` (W10; the status
    /// machine ignores the prompt — only the pane detector's intent fold reads it).
    case userPromptSubmit(SessionInfo, prompt: String?)

    /// `PreToolUse` → a tool is about to run (→ *working*, clears a resolved permission
    /// block). Carries the `tool_name`/`tool_input` so a label can be derived; no result
    /// exists yet (that is `PostToolUse`). 1:1 → `ClaudeHookEvent.preToolUse(sessionID:tool:)`
    /// — except `AskUserQuestion`, which the W10 adapter maps to the waiting-for-input block
    /// (the call blocks on the human answering; it is Claude ASKING, not working).
    case preToolUse(ToolUseBlock)

    /// `PermissionRequest` → a permission dialog is up for a tool call (→ *blocked*). Carries
    /// the gated call's `tool_name`/`tool_input`. The structured sibling of a
    /// `Notification(permission_prompt)` — the W10 adapter maps both to the same permission
    /// block, this one just cannot be missed by message-text heuristics.
    case permissionRequest(ToolUseBlock)

    /// `PostToolUseFailure` → a tool call ENDED badly (error, or an interrupt). Claude Code emits
    /// this INSTEAD of `PostToolUse`, carrying the same `tool_use_id` — so without it a failed
    /// call's ledger entry has nothing to resolve it, and a failed `AskUserQuestion` leaves a hand
    /// raised over a dialog that is no longer on screen for the rest of the turn.
    case postToolUseFailure(ToolUseBlock, isInterrupt: Bool)

    /// `Elicitation` → an MCP server is asking the human for structured input (→ *blocked*).
    /// Carries `mcp_server_name` + `message` + `elicitation_id`; ``ElicitationResult`` closes it
    /// with the same id. The STRUCTURED form of what we otherwise only catch by classifying a
    /// `Notification` message as `elicitation_dialog` — same class of block, announced instead of
    /// inferred, and with an id the ledger can pair.
    case elicitation(id: String?, server: String?, message: String?)

    /// `ElicitationResult` → the human answered (or dismissed) an ``elicitation``. Resolves that
    /// id's block; the turn goes on.
    case elicitationResult(id: String?, server: String?)

    /// `PermissionDenied` → the human said no to a gated call (`tool_use_id` + `reason`). The
    /// dialog is gone and the turn continues, so this RESOLVES the block. Without it the denial is
    /// only INFERRED — from the next `PreToolUse`, on the reasoning that a permission dialog is
    /// modal — which is true but is an inference where an announcement exists.
    case permissionDenied(ToolUseBlock)

    /// `StopFailure` → the turn terminated on an API error (→ *done*, the error text as the
    /// label). Without it a mid-turn API death leaves the pane stuck *working* until presence
    /// absence finally wins. `StopInfo.lastAssistantMessage` carries the `error_message`.
    case stopFailure(StopInfo)

    /// `Notification` → an async notification with its classified `kind` (permission /
    /// waiting-for-input / other) + the raw `message`. The blocked/idle-waiting signal.
    /// 1:1 → `ClaudeHookEvent.notification(kind:label:)` (W10 maps `kind` straight across
    /// and uses `message` as the `label`).
    case notification(NotificationInfo)

    /// `Stop` → the turn ended (→ *done*, then *idle* after a timeout). Carries the
    /// session identity + the `last_assistant_message` (the human-readable label).
    /// 1:1 → `ClaudeHookEvent.stop(sessionID:label:)` (`label` = `lastAssistantMessage`).
    case stop(StopInfo)

    /// `SessionEnd` → the session ended (claude is gone → *none*). Carries the session
    /// identity. 1:1 → `ClaudeHookEvent.sessionEnd(sessionID:)` (W10).
    case sessionEnd(SessionInfo)

    /// `PreCompact` → the transcript is about to be compacted (manual `/compact` or the automatic
    /// mid-turn compaction). Not a status of its own — it is the MARKER that whatever `Stop` comes
    /// next may be the compaction's own end rather than a finished task. 1:1 →
    /// `ClaudeHookEvent.preCompact(sessionID:)`; see that case for how the marker is spent.
    case preCompact(SessionInfo)
}

/// The semantic class of a `Notification` hook (doc 14 §Hooks, docs/41 §2.6 matcher
/// field). Mirrors `SlopDeskAgentDetect.ClaudeHookEvent.NotificationKind` 1:1 so the
/// W10 adapter is a trivial map — `SlopDeskInspector` does NOT depend on the detection
/// target (it depends only on `SlopDeskProtocol`), so the vocabulary is duplicated by
/// design and kept structurally identical (same three cases, same meaning).
public enum NotificationKind: String, Sendable, Equatable, Codable {
    /// Claude needs explicit approval to proceed (`permission_prompt`). → blocked.
    case permission
    /// Claude is genuinely BLOCKED on the human answering (`agent_needs_input` /
    /// `elicitation_dialog`; the W10 adapter also routes `AskUserQuestion` here). → blocked.
    /// The idle "waiting for your input" nudge is NOT this — it classifies `.other`.
    case waitingForInput
    /// `idle_prompt` / `auth_success` / `elicitation_complete` / anything else — informational only.
    case other
}

/// The payload of a `Notification` hook: the classified ``NotificationKind`` + the raw
/// `message` text (the human-readable label) + the session identity.
public struct NotificationInfo: Sendable, Equatable, Codable {
    public var kind: NotificationKind
    /// The raw `message` field as Claude Code sent it (used as the W10 `label`); `nil`
    /// when the producer omitted it (still classifies as `.other`, never traps).
    public var message: String?
    public var sessionID: String?

    public init(kind: NotificationKind, message: String? = nil, sessionID: String? = nil) {
        self.kind = kind
        self.message = message
        self.sessionID = sessionID
    }
}

/// The payload of a `Stop` hook: the session identity + the last assistant message
/// (the turn's human-readable result, used as the W10 `label`) + how much of the turn's work
/// OUTLIVES it.
public struct StopInfo: Sendable, Equatable, Codable {
    public var sessionID: String?
    public var lastAssistantMessage: String?

    /// How many BACKGROUND tasks were still live when the turn ended (`0` when the field is absent).
    ///
    /// Claude Code ships a `background_tasks` array on `Stop`, already filtered producer-side to
    /// tasks that are `running`/`pending` AND backgrounded — so a non-zero count means the turn is
    /// over but its work is not. Undocumented in the hooks reference; read straight off the shipped
    /// payload shape (`{ id, type, status, description, … }`) and parsed tolerantly, so a producer
    /// that drops or renames it simply reports `0`.
    public var backgroundTaskCount: Int

    public init(
        sessionID: String? = nil,
        lastAssistantMessage: String? = nil,
        backgroundTaskCount: Int = 0,
    ) {
        self.sessionID = sessionID
        self.lastAssistantMessage = lastAssistantMessage
        self.backgroundTaskCount = backgroundTaskCount
    }
}

/// Parses raw hook JSON (the POST body) into a typed ``HookPayload``.
///
/// Tolerant, like the transcript parser: an unrecognised hook event or a malformed
/// body yields `nil` (the host glue logs + drops it) rather than throwing.
public enum HookParser {
    /// The `agent_transcript_path` a `SubagentStop` payload referenced, if any —
    /// surfaced separately because it is the only field that names a subagent's own file.
    /// (Nothing in hostd tails it: `slopdesk-inspectord` discovers the same file by watching
    /// the `subagents/` directory. Kept because the path is also how a payload WITHOUT an
    /// explicit `agent_id` gets one — see ``agentHash(_:)``.)
    public static func subagentTranscriptPath(_ data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return root["agent_transcript_path"]?.stringValue
            ?? root["agentTranscriptPath"]?.stringValue
    }

    /// The `session_id` on ANY hook body, independent of which payload case it parses as.
    ///
    /// Claude Code stamps it on every event, but only some of them carry it into ``HookPayload``
    /// (a `ToolUseBlock` / `NotificationInfo` models the CALL, not the session). The host needs it
    /// on all of them to tell its own pane agent apart from a nested `claude -p` that inherited
    /// `SLOPDESK_PANE_ID` — see `ClaudeStatusMachine.ownerSessionID`. Tolerant like everything
    /// here: an unparseable body, or one without the field, yields `nil`.
    public static func sessionID(_ data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return root["session_id"]?.stringValue ?? root["sessionId"]?.stringValue
    }

    public static func parse(_ data: Data) -> HookPayload? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(obj) = root
        else {
            return nil
        }

        // Claude Code uses `hook_event_name`; tolerate `event` too.
        let event = obj["hook_event_name"]?.stringValue
            ?? obj["event"]?.stringValue
            ?? obj["type"]?.stringValue
            ?? ""

        switch event {
        case "SessionStart":
            return .sessionStart(SessionInfo(
                sessionID: obj["session_id"]?.stringValue ?? obj["sessionId"]?.stringValue,
                model: obj["model"]?.stringValue,
                cwd: obj["cwd"]?.stringValue,
                transcriptPath: obj["transcript_path"]?.stringValue ?? obj["transcriptPath"]?.stringValue,
            ))

        case "PostToolUse":
            guard let name = obj["tool_name"]?.stringValue ?? obj["toolName"]?.stringValue else {
                return nil
            }
            let payloadID = obj["tool_use_id"]?.stringValue ?? obj["toolUseId"]?.stringValue
            let id = payloadID ?? UUID().uuidString
            let input = obj["tool_input"] ?? obj["toolInput"] ?? .object([:])
            let use = ToolUseBlock(
                id: id, name: name, input: input, idIsFromPayload: payloadID != nil,
            )

            var result: ToolResultBlock?
            if let rawResult = obj["tool_result"] ?? obj["toolResult"] {
                let isError: Bool = {
                    if case let .bool(value) = obj["is_error"] ?? obj["isError"] ?? .null { return value }
                    return false
                }()
                result = ToolResultBlock(toolUseID: id, content: rawResult.displayString, isError: isError)
            }
            return .postToolUse(use, result)

        case "SubagentStop":
            let id = obj["agent_id"]?.stringValue
                ?? obj["agentId"]?.stringValue
                ?? obj["agent_transcript_path"]?.stringValue.map(Self.agentHash) // fall back to path hash
                ?? UUID().uuidString
            let node = SubagentNode(
                // No documented `SubagentStop` field links to a parent agent (doc 16):
                // the corpus payload carries agent_id / agent_type / agent_transcript_path
                // / last_assistant_message only. We *tolerate* a parent_agent_id if a
                // future/non-native producer sends one, but in practice this is `nil` and
                // the tree is flat — see `SubagentNode.parentID` / `subagentTree`.
                id: id,
                parentID: obj["parent_agent_id"]?.stringValue ?? obj["parentAgentId"]?.stringValue,
                agentType: obj["agent_type"]?.stringValue ?? obj["agentType"]?.stringValue,
                description: obj["description"]?.stringValue,
                status: .stopped,
                lastAssistantMessage: obj["last_assistant_message"]?.stringValue
                    ?? obj["lastAssistantMessage"]?.stringValue,
            )
            return .subagentStop(node)

        case "UserPromptSubmit":
            return .userPromptSubmit(sessionInfo(from: obj), prompt: obj["prompt"]?.stringValue)

        case "PreToolUse":
            // A tool is *about* to run — no result yet. Like PostToolUse we require a tool
            // name (a PreToolUse without one is malformed → drop).
            guard let use = toolUseBlock(from: obj) else { return nil }
            return .preToolUse(use)

        case "Elicitation":
            return .elicitation(
                id: obj["elicitation_id"]?.stringValue ?? obj["elicitationId"]?.stringValue,
                server: obj["mcp_server_name"]?.stringValue ?? obj["mcpServerName"]?.stringValue,
                message: obj["message"]?.stringValue,
            )

        case "ElicitationResult":
            return .elicitationResult(
                id: obj["elicitation_id"]?.stringValue ?? obj["elicitationId"]?.stringValue,
                server: obj["mcp_server_name"]?.stringValue ?? obj["mcpServerName"]?.stringValue,
            )

        case "PostToolUseFailure":
            // Same shape as PostToolUse plus `error`/`is_interrupt`. `is_interrupt` is NOT a
            // detail: Claude Code emits no `Stop` when the human interrupts, so this flag is the
            // only announcement that the turn is over.
            guard let use = toolUseBlock(from: obj) else { return nil }
            let interrupt = obj["is_interrupt"]?.boolValue ?? obj["isInterrupt"]?.boolValue ?? false
            return .postToolUseFailure(use, isInterrupt: interrupt)

        case "PermissionDenied":
            guard let use = toolUseBlock(from: obj) else { return nil }
            return .permissionDenied(use)

        case "PermissionRequest":
            // A permission dialog is up for this tool call — the structured blocked signal.
            // Same malformed-drop rule as Pre/PostToolUse (the parallel Notification
            // permission_prompt still covers a producer that omits the name).
            guard let use = toolUseBlock(from: obj) else { return nil }
            return .permissionRequest(use)

        case "Notification":
            let message = obj["message"]?.stringValue ?? obj["body"]?.stringValue
            return .notification(NotificationInfo(
                kind: classifyNotification(
                    message: message,
                    matcher: obj["matcher"]?.stringValue,
                    notificationType: obj["notification_type"]?.stringValue
                        ?? obj["notificationType"]?.stringValue,
                ),
                message: message,
                sessionID: obj["session_id"]?.stringValue ?? obj["sessionId"]?.stringValue,
            ))

        case "Stop":
            return .stop(StopInfo(
                sessionID: obj["session_id"]?.stringValue ?? obj["sessionId"]?.stringValue,
                lastAssistantMessage: obj["last_assistant_message"]?.stringValue
                    ?? obj["lastAssistantMessage"]?.stringValue,
                backgroundTaskCount: liveTaskCount(obj["background_tasks"] ?? obj["backgroundTasks"]),
            ))

        case "StopFailure":
            // API-error turn termination: the error text rides the Stop label seat.
            return .stopFailure(StopInfo(
                sessionID: obj["session_id"]?.stringValue ?? obj["sessionId"]?.stringValue,
                lastAssistantMessage: obj["error_message"]?.stringValue
                    ?? obj["errorMessage"]?.stringValue
                    ?? obj["error_type"]?.stringValue,
            ))

        case "SessionEnd":
            return .sessionEnd(sessionInfo(from: obj))

        case "PreCompact":
            // Carries `trigger` (`manual`/`auto`) + `custom_instructions`; the detector needs
            // neither — only that a compaction is starting in THIS session.
            return .preCompact(sessionInfo(from: obj))

        default:
            return nil
        }
    }

    /// Builds a ``ToolUseBlock`` from the common `{ tool_name, tool_use_id, tool_input }` fields
    /// (tolerant of camelCase); `nil` without a tool name (malformed → drop). Shared by
    /// PreToolUse / PermissionRequest.
    private static func toolUseBlock(from obj: [String: JSONValue]) -> ToolUseBlock? {
        guard let name = obj["tool_name"]?.stringValue ?? obj["toolName"]?.stringValue else {
            return nil
        }
        let payloadID = obj["tool_use_id"]?.stringValue ?? obj["toolUseId"]?.stringValue
        let input = obj["tool_input"] ?? obj["toolInput"] ?? .object([:])
        return ToolUseBlock(
            id: payloadID ?? UUID().uuidString,
            name: name,
            input: input,
            idIsFromPayload: payloadID != nil,
        )
    }

    /// Counts the entries of a `background_tasks`-shaped value. Anything that is not an array —
    /// absent, null, an object, a hostile scalar — counts `0`: this is a nice-to-have field on an
    /// undocumented seam, so it never decides anything by failing.
    private static func liveTaskCount(_ value: JSONValue?) -> Int {
        guard case let .array(items)? = value else { return 0 }
        return items.count
    }

    /// Builds a ``SessionInfo`` from the common `{ session_id, model, cwd, transcript_path }`
    /// fields (tolerant of camelCase). Shared by SessionStart / UserPromptSubmit / SessionEnd.
    private static func sessionInfo(from obj: [String: JSONValue]) -> SessionInfo {
        SessionInfo(
            sessionID: obj["session_id"]?.stringValue ?? obj["sessionId"]?.stringValue,
            model: obj["model"]?.stringValue,
            cwd: obj["cwd"]?.stringValue,
            transcriptPath: obj["transcript_path"]?.stringValue ?? obj["transcriptPath"]?.stringValue,
        )
    }

    /// Classifies a `Notification` hook into a ``NotificationKind``.
    ///
    /// Priority order:
    /// 1. the structured `notification_type` field (current Claude Code sends one) decides
    ///    outright for the classes we know — `permission_prompt` → `.permission`;
    ///    `agent_needs_input` / `elicitation_dialog` → `.waitingForInput`; `idle_prompt` and the
    ///    known informational types → `.other`. An UNKNOWN type falls through (a future
    ///    blocking class must not be silently demoted to `.other` when its text still matches);
    /// 2. an explicit matcher token (`permission_prompt` → `.permission`) when present;
    /// 3. else the message text: an approval/permission request → `.permission`;
    /// 4. else (anything unknown, or a missing message) → `.other`. Conservative: only a
    ///    positive match promotes to a blocking kind, mirroring the manifest matcher's
    ///    "blocked only on a known match" rule.
    ///
    /// `idle_prompt` — Claude Code's "waiting for your input" nudge, fired ~60 s after a turn
    /// ends with the agent simply RESTING at its prompt — is deliberately NOT a blocking kind:
    /// it re-raised the act-now hand on every pane the user had already read, minutes after the
    /// done marker cleared. An agent genuinely blocked on the human still classifies blocked
    /// through its own signals (`PermissionRequest`, `permission_prompt`, `AskUserQuestion` via
    /// the W10 adapter, `agent_needs_input` / `elicitation_dialog`); an idle prompt is presence,
    /// nothing more. The old idle/waiting matcher + message-text promotions described exactly this
    /// nudge, so they demote with it.
    static func classifyNotification(
        message: String?, matcher: String?, notificationType: String? = nil,
    ) -> NotificationKind {
        switch notificationType?.lowercased() {
        case "permission_prompt":
            return .permission
        case "agent_needs_input",
             "elicitation_dialog":
            return .waitingForInput
        case "idle_prompt",
             "auth_success",
             "elicitation_complete",
             "elicitation_response",
             "agent_completed":
            return .other
        default:
            break // no/unknown type → the matcher + text heuristics below decide
        }
        if let matcher = matcher?.lowercased() {
            if matcher.contains("permission") { return .permission }
        }
        guard let text = message?.lowercased() else { return .other }
        // Permission/approval request — the blocked-on-approval signal.
        if text.contains("permission") || text.contains("approval")
            || text.contains("needs your approval") || text.contains("wants to")
            || text.contains("would like to")
        {
            return .permission
        }
        return .other
    }

    /// Derives a stable subagent id from an `agent-<hash>.jsonl` path when the payload
    /// omits an explicit id (the filename hash *is* the agent id in doc 16's scheme).
    ///
    /// The inspector daemon derives the SAME id from the SAME filename
    /// (`slopdesk_inspectord::subagents::agent_hash`), which is what makes a node linked by a
    /// hook and one discovered by the directory watcher the same node. That is a shared naming
    /// SCHEME, not a shared implementation — neither side calls the other, and each reads a
    /// filename it was handed by a different producer.
    static func agentHash(_ path: String) -> String {
        // `URL.lastPathComponent` mirrors `NSString.lastPathComponent` for every real agent path;
        // guard the empty string (URL would resolve "" to the cwd, NSString yields "").
        let file = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        // agent-<hash>.jsonl  →  <hash>
        var name = file
        if name.hasSuffix(".jsonl") { name = String(name.dropLast(6)) }
        if name.hasPrefix("agent-") { name = String(name.dropFirst(6)) }
        return name.isEmpty ? path : name
    }
}

// MARK: - Hook content blocks

/// A tool call as a HOOK announced it: `{ tool_name, tool_use_id, tool_input }`.
///
/// Named for the assistant `{type:tool_use, …}` transcript block it mirrors, because that is the
/// shape Claude Code reuses across both surfaces — but this is the HOOK's model and its only
/// consumers are on the detection path (``HookPayload``, `AgentHookListener.questionLabel`). The
/// transcript-line half of the family moved to `slopdesk-inspectord` and was deleted here; these
/// two stayed with the parser that builds them.
public struct ToolUseBlock: Sendable, Equatable {
    public var id: String
    public var name: String
    /// The tool input as a JSON object, preserved as decoded values (so a label can be derived
    /// from whichever field the tool happens to carry one in).
    public var input: JSONValue

    /// TRUE when ``id`` came from the payload's `tool_use_id` and therefore MATCHES across the
    /// `PreToolUse` / `PostToolUse` pair; FALSE when the producer omitted it and ``HookParser``
    /// minted a fresh UUID so a consumer still has a key.
    ///
    /// ⚠️ Load-bearing for the status machine's BLOCK LEDGER: a synthesised id is a DIFFERENT
    /// string on the pre and the post hook, so treating it as real would leave a question's ledger
    /// entry unresolvable — a raised hand nothing could lower. Consumers that need identity across
    /// two events must read this and fall back to id-less handling; consumers that just need a
    /// dictionary key can ignore it.
    public var idIsFromPayload: Bool

    public init(id: String, name: String, input: JSONValue, idIsFromPayload: Bool = true) {
        self.id = id
        self.name = name
        self.input = input
        self.idIsFromPayload = idIsFromPayload
    }

    /// The id to key cross-event identity by — ``id`` when the payload supplied it, else `nil`.
    public var stableID: String? { idIsFromPayload ? id : nil }
}

/// A tool call's outcome as a HOOK announced it: `{ tool_use_id, tool_result, is_error }`.
///
/// The sibling of ``ToolUseBlock``; see that type for why the transcript-shaped name survives a
/// hook-only life.
public struct ToolResultBlock: Sendable, Equatable {
    public var toolUseID: String
    /// The tool output, flattened to a string (Claude Code emits either a string or
    /// an array of `{type:text,text}` blocks; both flatten here).
    public var content: String
    public var isError: Bool

    public init(toolUseID: String, content: String, isError: Bool) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }
}
