import Foundation

/// The typed event taxonomy the read-only inspector emits and the client renders.
///
/// This is the single output type of the whole inspector pipeline (transcript +
/// subagent + hook sources fold into a stream of these). It is `Codable` so it can be
/// serialised over the second channel verbatim, and `Equatable` so transport
/// round-trips can be asserted byte-for-byte in tests.
///
/// Mapping to doc 16's surfaces:
/// - `toolCard`     → tool-call card (input + output + isError, paired by id)
/// - `todosUpdated` → todos/tasks panel (latest state)
/// - `subagent*`    → subagent tree (separate `subagents/agent-<hash>.jsonl` files)
/// - `thinking`     → thinking placeholder indicator (empty-aware; never content)
/// - `message`      → message timeline (user/assistant text)
/// - `sessionStarted` → session metadata (model / cwd), from a SessionStart hook
/// - `workflow`     → workflow panel — DEFER/PREVIEW per doc 16 (minimal, don't over-build)
/// - `unknownLine`  → schema-evolution safety valve (raw, surfaced not dropped)
public enum InspectorEvent: Sendable, Equatable, Codable {
    /// A tool card, emitted on the `tool_use` (pending) and again when its
    /// `tool_result` arrives (completed/errored). The client keys by `card.id`.
    case toolCard(ToolCard)

    /// The latest todo/task list state (replaces the prior list — doc 16: accumulate
    /// the latest from the `TodoWrite`/`Task*` tool-call chain).
    case todosUpdated([TodoItem])

    /// A subagent node appeared or changed status (running → stopped). The tree is
    /// reconstructed client-side from these by `parentID`.
    case subagentUpdated(SubagentNode)

    /// A tool card that belongs to a subagent (so the client attaches it under the
    /// right subagent node rather than the main timeline).
    case subagentToolCard(agentID: String, card: ToolCard)

    /// A thinking placeholder marker (doc 16: present/absent + optional signature;
    /// never fabricated content).
    case thinking(ThinkingMarker)

    /// A user/assistant message text for the timeline.
    case message(MessageEvent)

    /// Session metadata learned from a SessionStart hook (or a meta transcript line).
    case sessionStarted(SessionInfo)

    /// Workflow panel (DEFER/PREVIEW, doc 16): a minimal "workflow running/idle"
    /// signal inferred indirectly from subagent activity. Intentionally not built out.
    case workflow(WorkflowMarker)

    /// A transcript line we could not classify. Surfaced (not dropped) so the UI can
    /// show "N unrecognised lines" rather than silently losing data when the schema
    /// evolves.
    case unknownLine(raw: String)

    /// The replay log dropped `droppedCount` oldest events (its retention window overflowed) BEFORE
    /// the prefix this subscriber asked for (R17 INSP-WIRE-1). Emitted FIRST on such a replay so the
    /// client renders "N earlier steps dropped" instead of silently starting mid-transcript and
    /// believing it has the complete history.
    case historyTruncated(droppedCount: Int)
}

// MARK: - Tool cards

/// A tool-call card: a `tool_use` paired with its later `tool_result`.
///
/// Created `pending` from the `tool_use`; transitions to `completed` or `errored`
/// when the matching `tool_result` arrives (by `id == tool_use_id`). Handles
/// out-of-order and missing results — a card with no result stays `pending`.
public struct ToolCard: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case pending
        case completed
        case errored
    }

    /// The `tool_use.id` — the pairing key.
    public var id: String
    public var name: String
    /// The full tool input (rendered in the card).
    public var input: JSONValue
    /// The tool output, once the result arrives.
    public var output: String?
    public var status: Status

    public init(id: String, name: String, input: JSONValue, output: String? = nil, status: Status = .pending) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.status = status
    }
}

// MARK: - Todos

/// One todo/task item parsed from a `TodoWrite`/`TaskCreate` payload.
public struct TodoItem: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var status: Status
    /// The imperative "activeForm" Claude Code emits for in-progress items, if present.
    public var activeForm: String?

    public init(content: String, status: Status, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

// MARK: - Subagents

/// A node in the subagent tree (doc 16: subagents live in separate files, linked to
/// the main session via the SubagentStop hook's `agent_transcript_path`).
public struct SubagentNode: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case running
        case stopped
    }

    /// The subagent id (`agentId` on its sidechain lines, or hook `agent_id`).
    public var id: String
    /// Parent: `nil` = attached directly under the main session.
    ///
    /// **Unsourced today.** No documented Claude Code signal in the doc-16 corpus
    /// carries a cross-file parent link (the `SubagentStop` hook has no
    /// `parent_agent_id`; sidechain lines carry only intra-file `parentUuid`). So in
    /// practice this stays `nil` and the tree is flat. The field is kept for when a real
    /// linkage source lands (e.g. correlating the parent session's `Task` `tool_use` id);
    /// see ``InspectorViewModel/subagentTree``.
    public var parentID: String?
    /// e.g. "Ariadne", "general-purpose" — from the `.meta.json` / hook `agent_type`.
    public var agentType: String?
    /// The task description, when known.
    public var description: String?
    public var status: Status
    /// The last assistant message, from a SubagentStop hook (doc 16).
    public var lastAssistantMessage: String?

    public init(
        id: String,
        parentID: String? = nil,
        agentType: String? = nil,
        description: String? = nil,
        status: Status = .running,
        lastAssistantMessage: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.agentType = agentType
        self.description = description
        self.status = status
        self.lastAssistantMessage = lastAssistantMessage
    }
}

// MARK: - Thinking

/// A thinking-block placeholder marker. Doc 16: placeholder ONLY.
public struct ThinkingMarker: Sendable, Equatable, Codable {
    /// `true` when structure was present but no readable text (the "Thinking (not
    /// persisted)" case — the norm on Claude 4).
    public var isPlaceholder: Bool
    /// The signature fingerprint, when present (proves a block existed).
    public var signature: String?
    /// Text *iff* the transcript actually carried it. Never fabricated.
    public var text: String?

    public init(isPlaceholder: Bool, signature: String? = nil, text: String? = nil) {
        self.isPlaceholder = isPlaceholder
        self.signature = signature
        self.text = text
    }
}

// MARK: - Messages / session / workflow

public struct MessageEvent: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Equatable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    /// `nil` for the main session; set when the message belongs to a subagent.
    public var agentID: String?

    public init(role: Role, text: String, agentID: String? = nil) {
        self.role = role
        self.text = text
        self.agentID = agentID
    }
}

public struct SessionInfo: Sendable, Equatable, Codable {
    public var sessionID: String?
    public var model: String?
    public var cwd: String?
    public var transcriptPath: String?

    public init(sessionID: String? = nil, model: String? = nil, cwd: String? = nil, transcriptPath: String? = nil) {
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

/// Workflow panel marker — DEFER/PREVIEW (doc 16). Workflows emit no JSONL event of
/// their own; we infer "running" indirectly from subagent activity. Minimal by design.
public struct WorkflowMarker: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Equatable, Codable {
        case running
        case idle
    }

    public var state: State

    public init(state: State) {
        self.state = state
    }
}
