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
    /// the path from `cwd` (doc 16: "Lấy path từ field `transcript_path`").
    case sessionStart(SessionInfo)

    /// `PostToolUse` → full tool name + input + (optional) result, sub-second, before
    /// the JSONL flush (doc 16) → an immediate card. The result is optional because
    /// some hook configs fire pre-result.
    case postToolUse(ToolUseBlock, ToolResultBlock?)

    /// `SubagentStop` → the subagent node, crucially carrying `agent_transcript_path`
    /// (doc 16: the signal that links a `subagents/agent-<hash>.jsonl` file in) plus
    /// `agent_id` / `agent_type` / `last_assistant_message`.
    case subagentStop(SubagentNode)
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
                transcriptPath: obj["transcript_path"]?.stringValue ?? obj["transcriptPath"]?.stringValue
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
                    ?? obj["lastAssistantMessage"]?.stringValue
            )
            return .subagentStop(node)

        default:
            return nil
        }
    }

    /// Derives a stable subagent id from an `agent-<hash>.jsonl` path when the payload
    /// omits an explicit id (the filename hash *is* the agent id in doc 16's scheme).
    static func agentHash(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        // agent-<hash>.jsonl  →  <hash>
        var name = file
        if name.hasSuffix(".jsonl") { name = String(name.dropLast(6)) }
        if name.hasPrefix("agent-") { name = String(name.dropFirst(6)) }
        return name.isEmpty ? path : name
    }
}
