import Foundation

/// Typed Claude Code hook payloads (doc 14 §Hooks, doc 16 §Hooks).
///
/// Claude Code hooks (`SessionStart`, `PostToolUse`, `SubagentStop`) POST small JSON
/// payloads to a local listener. The actual HTTP / stdin wiring is host-app glue;
/// this type is the **seam**: the typed model + a parser + the fold-into-stream logic
/// (`EventBuilder.ingest(hook:)`). It is unit-tested against fixture payloads.
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
}

/// The semantic class of a `Notification` hook (doc 14 §Hooks, docs/41 §2.6 matcher
/// field). Mirrors `SlopDeskAgentDetect.ClaudeHookEvent.NotificationKind` 1:1 so the
/// W10 adapter is a trivial map — `SlopDeskInspector` does NOT depend on the detection
/// target (it depends only on `SlopDeskProtocol`), so the vocabulary is duplicated by
/// design and kept structurally identical (same three cases, same meaning).
public enum NotificationKind: String, Sendable, Equatable, Codable {
    /// Claude needs explicit approval to proceed (`permission_prompt`). → blocked.
    case permission
    /// Claude is idle-waiting on the human to type the next thing. → blocked.
    case waitingForInput
    /// `auth_success` / `elicitation_complete` / anything else — informational only.
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
/// (the turn's human-readable result, used as the W10 `label`).
public struct StopInfo: Sendable, Equatable, Codable {
    public var sessionID: String?
    public var lastAssistantMessage: String?

    public init(sessionID: String? = nil, lastAssistantMessage: String? = nil) {
        self.sessionID = sessionID
        self.lastAssistantMessage = lastAssistantMessage
    }
}

/// Parses raw hook JSON (the POST body) into a typed ``HookPayload``.
///
/// Tolerant, like the transcript parser: an unrecognised hook event or a malformed
/// body yields `nil` (the host glue logs + drops it) rather than throwing.
public enum HookParser {
    /// The `agent_transcript_path` a `SubagentStop` payload referenced, if any —
    /// surfaced separately so the host can hand the path to the `SubagentWatcher`.
    public static func subagentTranscriptPath(_ data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return root["agent_transcript_path"]?.stringValue
            ?? root["agentTranscriptPath"]?.stringValue
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
            let id = obj["tool_use_id"]?.stringValue
                ?? obj["toolUseId"]?.stringValue
                ?? UUID().uuidString
            let input = obj["tool_input"] ?? obj["toolInput"] ?? .object([:])
            let use = ToolUseBlock(id: id, name: name, input: input)

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
        let id = obj["tool_use_id"]?.stringValue
            ?? obj["toolUseId"]?.stringValue
            ?? UUID().uuidString
        let input = obj["tool_input"] ?? obj["toolInput"] ?? .object([:])
        return ToolUseBlock(id: id, name: name, input: input)
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
    ///    `idle_prompt` / `agent_needs_input` / `elicitation_dialog` → `.waitingForInput`;
    ///    the known informational types → `.other`. An UNKNOWN type falls through (a future
    ///    blocking class must not be silently demoted to `.other` when its text still matches);
    /// 2. an explicit matcher token (`permission_prompt` → `.permission`) when present;
    /// 3. else the message text: an approval/permission request → `.permission`; an
    ///    idle "waiting for your input" prompt → `.waitingForInput`;
    /// 4. else (anything unknown, or a missing message) → `.other`. Conservative: only a
    ///    positive match promotes to a blocking kind, mirroring the manifest matcher's
    ///    "blocked only on a known match" rule.
    static func classifyNotification(
        message: String?, matcher: String?, notificationType: String? = nil,
    ) -> NotificationKind {
        switch notificationType?.lowercased() {
        case "permission_prompt":
            return .permission
        case "idle_prompt",
             "agent_needs_input",
             "elicitation_dialog":
            return .waitingForInput
        case "auth_success",
             "elicitation_complete",
             "elicitation_response",
             "agent_completed":
            return .other
        default:
            break // no/unknown type → the matcher + text heuristics below decide
        }
        if let matcher = matcher?.lowercased() {
            if matcher.contains("permission") { return .permission }
            if matcher.contains("idle") || matcher.contains("waiting") { return .waitingForInput }
        }
        guard let text = message?.lowercased() else { return .other }
        // Permission/approval request — the blocked-on-approval signal.
        if text.contains("permission") || text.contains("approval")
            || text.contains("needs your approval") || text.contains("wants to")
            || text.contains("would like to")
        {
            return .permission
        }
        // Idle, waiting on the human to type the next thing.
        if text.contains("waiting for your input") || text.contains("is waiting for")
            || text.contains("waiting for input")
        {
            return .waitingForInput
        }
        return .other
    }

    /// Derives a stable subagent id from an `agent-<hash>.jsonl` path when the payload
    /// omits an explicit id (the filename hash *is* the agent id in doc 16's scheme).
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
