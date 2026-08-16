//! One decoded line of a Claude Code JSONL transcript.
//!
//! The schema is stable only at the level of a discriminated union on `type`; individual fields
//! come and go between versions. So decoding is TOLERANT: a line whose type or shape is
//! unrecognised becomes [`TranscriptLine::Unknown`] carrying its raw text, and the parser keeps
//! going. An unknown line must never take the inspector down, and must never be silently dropped
//! either — it is surfaced as an event so the UI can say "N unrecognised lines".

use serde_json::Value;

/// A parsed transcript line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptLine {
    /// A `user` line. May carry plain text and/or `tool_result` blocks.
    User(UserLine),
    /// An `assistant` line. May carry text, `tool_use` and `thinking` blocks.
    Assistant(AssistantLine),
    /// A `system` / `summary` / session-meta line.
    Meta(MetaLine),
    /// A line whose type is recognised and deliberately dropped: internal bookkeeping, not
    /// conversation. A distinct case rather than [`TranscriptLine::Unknown`] so a test can assert
    /// the line was CLASSIFIED rather than merely unparsed.
    Ignored {
        /// The `type` that was ignored.
        line_type: String,
    },
    /// A line that could not be classified — unknown `type`, or unparseable JSON. The raw text is
    /// preserved verbatim: the schema-evolution safety valve.
    Unknown {
        /// The line, verbatim (trimmed).
        raw: String,
    },
}

/// Identity fields shared by transcript lines. All optional — a producer may omit any of them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LineIdentity {
    /// The line's own uuid — the dedup key for the main session.
    pub uuid: Option<String>,
    /// Parent line uuid, when present.
    pub parent_uuid: Option<String>,
    /// `true` on lines belonging to a subagent (sidechain) transcript.
    pub is_sidechain: bool,
    /// The subagent id, present on sidechain lines.
    pub agent_id: Option<String>,
    /// ISO-8601 timestamp, when present.
    pub timestamp: Option<String>,
}

/// A decoded `user` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserLine {
    /// Who/what this line is.
    pub identity: LineIdentity,
    /// Plain text the user (or a tool harness) sent, if any.
    pub text: Option<String>,
    /// `tool_result` blocks carried in `message.content[]`.
    pub tool_results: Vec<ToolResultBlock>,
}

/// A decoded `assistant` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssistantLine {
    /// Who/what this line is.
    pub identity: LineIdentity,
    /// Plain assistant text, if any.
    pub text: Option<String>,
    /// `tool_use` blocks carried in `message.content[]`.
    pub tool_uses: Vec<ToolUseBlock>,
    /// `thinking` blocks — placeholder only.
    pub thinking: Vec<ThinkingBlock>,
}

/// A session-metadata line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetaLine {
    /// Who/what this line is.
    pub identity: LineIdentity,
    /// The originating `type` (`system`, `summary`, …), preserved.
    pub raw_type: String,
    /// The session uuid, when carried.
    pub session_id: Option<String>,
    /// The model name, when carried.
    pub model: Option<String>,
    /// The working directory, when carried.
    pub cwd: Option<String>,
}

impl MetaLine {
    /// Whether this line actually DEFINES the session — the only meta lines worth an event. A meta
    /// line carrying none of the three is bookkeeping with no UI value.
    #[must_use]
    pub const fn defines_session(&self) -> bool {
        self.session_id.is_some() || self.model.is_some() || self.cwd.is_some()
    }
}

/// An assistant `{type: tool_use, id, name, input}` block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolUseBlock {
    /// The `tool_use.id`.
    pub id: String,
    /// The tool name.
    pub name: String,
    /// The tool input, preserved whole so the card can render it and `TodoWrite`-shaped payloads
    /// can be read out of it by key.
    pub input: Value,
}

/// A user `{type: tool_result, tool_use_id, content, is_error}` block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolResultBlock {
    /// The id of the `tool_use` this answers.
    pub tool_use_id: String,
    /// The output, flattened to one string (a producer sends either a string or an array of
    /// blocks).
    pub content: String,
    /// Whether the call failed.
    pub is_error: bool,
}

/// A `{type: thinking, thinking: "", signature}` block — PLACEHOLDER ONLY.
///
/// On Claude 4 the `thinking` field is empty by default, and the undocumented display flag that
/// would populate it is deliberately not chased. Presence and signature are modelled; content never
/// is. If the transcript later carries real text, [`ThinkingBlock::text`] is `Some` and the UI
/// renders it with no further change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThinkingBlock {
    /// The signature fingerprint, when present.
    pub signature: Option<String>,
    /// Thinking text *iff* the transcript actually carried it.
    pub text: Option<String>,
}

impl ThinkingBlock {
    /// True when the transcript carried thinking structure but no readable text.
    #[must_use]
    pub fn is_placeholder(&self) -> bool {
        self.text.as_ref().is_none_or(String::is_empty)
    }
}
