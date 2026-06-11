import Foundation

/// A single decoded line of a Claude Code JSONL transcript.
///
/// Claude Code writes its transcript as **append-only JSONL** (one JSON object per
/// line) at `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` (doc 16). The
/// schema is only stable at the level of a discriminated union on `type`; individual
/// fields come and go between versions. We therefore decode **tolerantly**: a line
/// whose `type` (or shape) we do not recognise becomes ``unknown(raw:)`` and the
/// parser keeps going. *Unknown lines must never crash the inspector* — the spec is
/// explicit that the transcript schema evolves.
///
/// This type is pure (Foundation only): no `Network`, no `Darwin`. It is fully
/// fixture-testable in isolation.
public enum TranscriptLine: Sendable, Equatable {
    /// A `user` line. May carry plain text and/or `tool_result` content blocks.
    case user(UserLine)
    /// An `assistant` line. May carry text, `tool_use`, and `thinking` content blocks.
    case assistant(AssistantLine)
    /// A `system` / `summary` / session-meta line (model, session id, cwd, ...).
    case meta(MetaLine)
    /// A line whose `type` we recognise but deliberately ignore: internal bookkeeping
    /// such as `file-history-snapshot`, `queue-operation`, `rate_limit_event` (doc 16
    /// "skip internal types"). Kept as a distinct case (not `.unknown`) so tests can
    /// assert we classified — rather than failed to parse — it.
    case ignored(type: String)
    /// A line we could not classify (unknown `type`, or unparseable JSON). The raw
    /// text is preserved verbatim so nothing is silently dropped. This is the
    /// schema-evolution safety valve.
    case unknown(raw: String)
}

// MARK: - Line payloads

/// Common identity fields shared by transcript lines (all optional — tolerant).
public struct LineIdentity: Sendable, Equatable {
    /// The transcript line's own uuid (dedup key for the main session).
    public var uuid: String?
    /// Parent line uuid, when present.
    public var parentUUID: String?
    /// `true` on lines that belong to a subagent (sidechain) transcript.
    public var isSidechain: Bool
    /// The subagent id, present on sidechain lines.
    public var agentID: String?
    /// ISO-8601 timestamp string, when present (used only for in-level sort hints).
    public var timestamp: String?

    public init(
        uuid: String? = nil,
        parentUUID: String? = nil,
        isSidechain: Bool = false,
        agentID: String? = nil,
        timestamp: String? = nil
    ) {
        self.uuid = uuid
        self.parentUUID = parentUUID
        self.isSidechain = isSidechain
        self.agentID = agentID
        self.timestamp = timestamp
    }
}

/// A decoded `user` transcript line.
public struct UserLine: Sendable, Equatable {
    public var identity: LineIdentity
    /// Plain text the user (or a tool harness) sent, if any.
    public var text: String?
    /// `tool_result` blocks carried in `message.content[]` (doc 16).
    public var toolResults: [ToolResultBlock]

    public init(identity: LineIdentity, text: String? = nil, toolResults: [ToolResultBlock] = []) {
        self.identity = identity
        self.text = text
        self.toolResults = toolResults
    }
}

/// A decoded `assistant` transcript line.
public struct AssistantLine: Sendable, Equatable {
    public var identity: LineIdentity
    /// Plain assistant text, if any.
    public var text: String?
    /// `tool_use` blocks carried in `message.content[]`.
    public var toolUses: [ToolUseBlock]
    /// `thinking` blocks — PLACEHOLDER ONLY (doc 16: Opus 4.x thinking text is empty).
    public var thinkingBlocks: [ThinkingBlock]

    public init(
        identity: LineIdentity,
        text: String? = nil,
        toolUses: [ToolUseBlock] = [],
        thinkingBlocks: [ThinkingBlock] = []
    ) {
        self.identity = identity
        self.text = text
        self.toolUses = toolUses
        self.thinkingBlocks = thinkingBlocks
    }
}

/// A session-metadata line (model, session id, cwd, ...).
public struct MetaLine: Sendable, Equatable {
    public var identity: LineIdentity
    /// The originating `type` (`system`, `summary`, ...), preserved for the UI.
    public var rawType: String
    public var sessionID: String?
    public var model: String?
    public var cwd: String?

    public init(
        identity: LineIdentity,
        rawType: String,
        sessionID: String? = nil,
        model: String? = nil,
        cwd: String? = nil
    ) {
        self.identity = identity
        self.rawType = rawType
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
    }
}

// MARK: - Content blocks

/// An assistant `{type:tool_use, id, name, input}` content block.
public struct ToolUseBlock: Sendable, Equatable {
    public var id: String
    public var name: String
    /// The tool input as a JSON object, preserved as decoded values (so a tool card
    /// can render the full input; `TodoWrite`/`TaskCreate` payloads are parsed from it).
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// A user `{type:tool_result, tool_use_id, content, is_error}` content block.
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

/// A `{type:thinking, thinking:"", signature}` content block — PLACEHOLDER ONLY.
///
/// Doc 16 (load-bearing decision): on Claude 4 (Opus 4.5/4.7/4.8) the `thinking`
/// field is empty by default; we never chase the undocumented
/// `--thinking-display summarized` flag. We model only *presence* + a token-ish hint,
/// never invented content. If Anthropic later persists thinking text, ``text`` will
/// be non-nil and the UI renders it naturally.
public struct ThinkingBlock: Sendable, Equatable {
    /// The signature fingerprint, when present (proves a thinking block existed).
    public var signature: String?
    /// Thinking text *iff* the transcript actually carries it (empty/absent on
    /// Claude 4). We never fabricate this.
    public var text: String?

    public init(signature: String? = nil, text: String? = nil) {
        self.signature = signature
        self.text = text
    }

    /// True when the transcript carried thinking structure but no readable text — the
    /// "Thinking (not persisted)" placeholder case.
    public var isPlaceholder: Bool {
        (text == nil || text?.isEmpty == true)
    }
}
