import Foundation

/// Tolerant parser from one raw JSONL line to a typed ``TranscriptLine``.
///
/// Strategy (doc 16 "Sync/dedup"): the schema is stable only as a discriminated
/// union on `type`; everything else is `.passthrough()`. We decode the *envelope*
/// loosely, branch on `type`, pull the fields we know, and fall back to
/// ``TranscriptLine/unknown(raw:)`` for anything we don't — *never throwing*. A line
/// that fails JSON parsing entirely (e.g. a half-written last line) is also returned
/// as `.unknown` so the caller can decide to wait for more bytes; the tailer only
/// hands us complete (newline-terminated) lines, so this is purely defensive.
public enum TranscriptParser {
    /// Internal type tags we recognise but deliberately drop (doc 16 "skip internal
    /// types"). They are bookkeeping, not conversation.
    static let ignoredTypes: Set<String> = [
        "file-history-snapshot",
        "queue-operation",
        "rate_limit_event",
    ]

    /// Parses one line. Whitespace-only input yields `nil` (nothing to emit).
    /// Anything else yields a ``TranscriptLine`` — including `.unknown` for
    /// unrecognised / unparseable input. **Never throws.**
    public static func parse(line: String) -> TranscriptLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(obj) = root
        else {
            return .unknown(raw: trimmed)
        }

        let type = obj["type"]?.stringValue ?? ""
        let identity = decodeIdentity(obj)

        switch type {
        case "user":
            return .user(decodeUser(obj, identity: identity))
        case "assistant":
            return .assistant(decodeAssistant(obj, identity: identity))
        case "system", "summary", "init", "session", "result":
            return .meta(decodeMeta(obj, identity: identity, rawType: type))
        case _ where ignoredTypes.contains(type):
            return .ignored(type: type)
        default:
            return .unknown(raw: trimmed)
        }
    }

    // MARK: - Field extraction

    private static func decodeIdentity(_ obj: [String: JSONValue]) -> LineIdentity {
        let isSidechain: Bool = {
            if case let .bool(value) = obj["isSidechain"] ?? .null { return value }
            return false
        }()
        return LineIdentity(
            uuid: obj["uuid"]?.stringValue,
            parentUUID: obj["parentUuid"]?.stringValue ?? obj["parentUUID"]?.stringValue,
            isSidechain: isSidechain,
            agentID: obj["agentId"]?.stringValue ?? obj["agentID"]?.stringValue,
            timestamp: obj["timestamp"]?.stringValue
        )
    }

    /// Returns the `message.content` array, handling both the object-with-content
    /// shape and a direct string `message` (which becomes a single text fragment).
    private static func messageContent(_ obj: [String: JSONValue]) -> (text: String?, blocks: [JSONValue]) {
        guard let message = obj["message"] else { return (nil, []) }
        switch message {
        case let .string(text):
            return (text, [])
        case let .object(msgObj):
            switch msgObj["content"] {
            case let .string(text):
                return (text, [])
            case let .array(blocks):
                return (nil, blocks)
            default:
                return (nil, [])
            }
        default:
            return (nil, [])
        }
    }

    private static func decodeUser(_ obj: [String: JSONValue], identity: LineIdentity) -> UserLine {
        let (directText, blocks) = messageContent(obj)
        var text = directText
        var results: [ToolResultBlock] = []
        for block in blocks {
            guard case let .object(b) = block else { continue }
            switch b["type"]?.stringValue {
            case "text":
                let value = b["text"]?.stringValue
                text = [text, value].compactMap { $0 }.joined(separator: "\n").nonEmpty
            case "tool_result":
                results.append(decodeToolResult(b))
            default:
                break
            }
        }
        return UserLine(identity: identity, text: text, toolResults: results)
    }

    private static func decodeToolResult(_ b: [String: JSONValue]) -> ToolResultBlock {
        let id = b["tool_use_id"]?.stringValue ?? ""
        let isError: Bool = {
            if case let .bool(value) = b["is_error"] ?? .null { return value }
            return false
        }()
        let content = flattenContent(b["content"])
        return ToolResultBlock(toolUseID: id, content: content, isError: isError)
    }

    private static func decodeAssistant(_ obj: [String: JSONValue], identity: LineIdentity) -> AssistantLine {
        let (directText, blocks) = messageContent(obj)
        var text = directText
        var uses: [ToolUseBlock] = []
        var thinking: [ThinkingBlock] = []
        for block in blocks {
            guard case let .object(b) = block else { continue }
            switch b["type"]?.stringValue {
            case "text":
                let value = b["text"]?.stringValue
                text = [text, value].compactMap { $0 }.joined(separator: "\n").nonEmpty
            case "tool_use":
                if let id = b["id"]?.stringValue, let name = b["name"]?.stringValue {
                    uses.append(ToolUseBlock(id: id, name: name, input: b["input"] ?? .object([:])))
                }
            case "thinking":
                // PLACEHOLDER ONLY. `thinking` is empty on Claude 4; keep signature +
                // any text the transcript happens to carry, never invent.
                let rawText = b["thinking"]?.stringValue
                thinking.append(ThinkingBlock(
                    signature: b["signature"]?.stringValue,
                    text: (rawText?.isEmpty == true) ? nil : rawText
                ))
            default:
                break
            }
        }
        return AssistantLine(identity: identity, text: text, toolUses: uses, thinkingBlocks: thinking)
    }

    private static func decodeMeta(_ obj: [String: JSONValue], identity: LineIdentity, rawType: String) -> MetaLine {
        // `model` may live at top level or inside `message`.
        let model = obj["model"]?.stringValue ?? obj["message"]?["model"]?.stringValue
        return MetaLine(
            identity: identity,
            rawType: rawType,
            sessionID: obj["sessionId"]?.stringValue ?? obj["session_id"]?.stringValue,
            model: model,
            cwd: obj["cwd"]?.stringValue
        )
    }

    /// Flattens a `tool_result.content` value (string, or array of `{type:text,text}`
    /// / `{type:..,..}` blocks) into one display string.
    private static func flattenContent(_ value: JSONValue?) -> String {
        switch value {
        case let .some(.string(text)):
            return text
        case let .some(.array(blocks)):
            return blocks.compactMap { block -> String? in
                if case let .object(b) = block {
                    return b["text"]?.stringValue ?? b.values.first?.displayString
                }
                return block.displayString
            }.joined(separator: "\n")
        case let .some(other):
            return other.displayString
        case .none:
            return ""
        }
    }
}

extension String {
    /// `nil` when the string is empty — folds "" back to absence so optional text
    /// stays absent rather than becoming an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}
