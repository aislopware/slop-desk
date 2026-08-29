//! The typed event taxonomy the inspector emits and the client renders.
//!
//! ## This shape is a CONTRACT, not a choice
//! The names below are not this crate's to pick. They were authored by Swift's SYNTHESIZED
//! `Codable` on a mirror of this taxonomy, which `docs/66` deleted — but the wire outlived it,
//! because a client ships independently of this daemon and the two must still agree across a
//! version skew. So the JSON these types produce is still exactly what that synthesis produced:
//!
//! - an enum is externally tagged by its case name — `{"toolCard": {…}}`;
//! - a case with ONE unlabeled associated value nests it under the key `_0`;
//! - a case with LABELS uses the labels — `{"subagentToolCard": {"agentID": …, "card": …}}`;
//! - a struct's keys are its PROPERTY NAMES verbatim, so `parentID` and `agentID` keep Swift's
//!   capitalisation and do not get `camelCase`d into `parentId`;
//! - a `nil` optional is OMITTED (`encodeIfPresent`), not written as `null`;
//! - a `String`-raw-value enum encodes as that raw string.
//!
//! `tests::the_wire_shape_matches_swifts_synthesized_codable` pins every one of those against
//! literal JSON, and `tests/golden_events.rs` pins the same shapes against the corpus. Changing a
//! name here silently breaks a shipped client; those two are what make it fail loudly instead.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One inspector event. The single output type of the whole pipeline: the transcript tail, the
/// subagent watch and (historically) the hook seam all fold into a stream of these.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InspectorEvent {
    /// A tool card, emitted on the `tool_use` (pending) and again when its `tool_result` arrives
    /// (completed/errored). The client keys by `card.id`.
    ToolCard {
        /// Swift: `case toolCard(ToolCard)` — one unlabeled value, hence `_0`.
        #[serde(rename = "_0")]
        card: ToolCard,
    },

    /// The latest todo/task list state, replacing the prior list wholesale.
    TodosUpdated {
        /// Swift: `case todosUpdated([TodoItem])`.
        #[serde(rename = "_0")]
        todos: Vec<TodoItem>,
    },

    /// A subagent node appeared or changed status. The tree is reconstructed client-side.
    SubagentUpdated {
        /// Swift: `case subagentUpdated(SubagentNode)`.
        #[serde(rename = "_0")]
        node: SubagentNode,
    },

    /// A tool card belonging to a subagent, so the client attaches it under that node rather than
    /// the main timeline. Swift labels both values, so there is no `_0` here.
    SubagentToolCard {
        /// The owning subagent's id.
        #[serde(rename = "agentID")]
        agent_id: String,
        /// The card itself.
        card: ToolCard,
    },

    /// A thinking-block PLACEHOLDER marker — presence and signature, never fabricated content.
    Thinking {
        /// Swift: `case thinking(ThinkingMarker)`.
        #[serde(rename = "_0")]
        marker: ThinkingMarker,
    },

    /// A user/assistant message for the timeline.
    Message {
        /// Swift: `case message(MessageEvent)`.
        #[serde(rename = "_0")]
        message: MessageEvent,
    },

    /// Session metadata (model / cwd / id).
    SessionStarted {
        /// Swift: `case sessionStarted(SessionInfo)`.
        #[serde(rename = "_0")]
        info: SessionInfo,
    },

    /// The workflow panel's minimal running/idle signal.
    Workflow {
        /// Swift: `case workflow(WorkflowMarker)`.
        #[serde(rename = "_0")]
        marker: WorkflowMarker,
    },

    /// A transcript line that could not be classified. SURFACED, not dropped, so the UI can show
    /// "N unrecognised lines" rather than silently losing data when the schema evolves.
    UnknownLine {
        /// The raw line, verbatim.
        raw: String,
    },

    /// The replay window dropped `droppedCount` events BEFORE the prefix this subscriber asked for.
    /// Emitted FIRST on such a replay, so the client renders "N earlier steps dropped" instead of
    /// starting mid-transcript while believing it holds the complete history.
    HistoryTruncated {
        /// How many absolute sequence numbers are missing ahead of the oldest retained event.
        #[serde(rename = "droppedCount")]
        dropped_count: i64,
    },
}

/// A tool-call card: a `tool_use` paired with its later `tool_result`.
///
/// Born `Pending` from the `tool_use`; becomes `Completed`/`Errored` when the matching result
/// arrives. Out-of-order and missing results are both handled — a card with no result stays
/// pending.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolCard {
    /// The `tool_use.id` — the pairing key.
    pub id: String,
    /// The tool name.
    pub name: String,
    /// The full tool input, rendered in the card.
    pub input: Value,
    /// The tool output, once the result arrives.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Where the card is in its lifecycle.
    pub status: ToolCardStatus,
}

/// A tool card's lifecycle position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolCardStatus {
    /// The `tool_use` was seen; no result yet.
    Pending,
    /// A result arrived with `is_error` false.
    Completed,
    /// A result arrived with `is_error` true.
    Errored,
}

/// One todo/task item parsed from a `TodoWrite` / `TaskCreate` / `TaskUpdate` payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TodoItem {
    /// The item text.
    pub content: String,
    /// Its state.
    pub status: TodoStatus,
    /// The imperative "activeForm" Claude Code emits for in-progress items, if present.
    #[serde(rename = "activeForm", skip_serializing_if = "Option::is_none")]
    pub active_form: Option<String>,
}

/// A todo item's state. `InProgress` spells itself `in_progress` on the wire, which is the raw
/// value the Swift enum declares and therefore what the client decodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TodoStatus {
    /// Not started.
    #[serde(rename = "pending")]
    Pending,
    /// Being worked on.
    #[serde(rename = "in_progress")]
    InProgress,
    /// Finished.
    #[serde(rename = "completed")]
    Completed,
}

impl TodoStatus {
    /// Parses the transcript's raw status string, defaulting to [`TodoStatus::Pending`] for an
    /// unrecognised value — the same tolerance the rest of the parser applies.
    #[must_use]
    pub fn parse(raw: &str) -> Self {
        match raw {
            "in_progress" => Self::InProgress,
            "completed" => Self::Completed,
            _ => Self::Pending,
        }
    }
}

/// A node in the subagent tree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubagentNode {
    /// The subagent id (`agentId` on its sidechain lines, or the filename hash).
    pub id: String,
    /// Parent; `None` = attached directly under the main session.
    ///
    /// **Unsourced today** — no documented Claude Code signal carries a cross-file parent link, so
    /// in practice the tree is flat. The field is kept for when a real linkage source lands.
    #[serde(rename = "parentID", skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// e.g. `"Ariadne"`, `"general-purpose"`.
    #[serde(rename = "agentType", skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
    /// The task description, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Running or stopped.
    pub status: SubagentStatus,
    /// The last assistant message, from a `SubagentStop` hook.
    #[serde(rename = "lastAssistantMessage", skip_serializing_if = "Option::is_none")]
    pub last_assistant_message: Option<String>,
}

impl SubagentNode {
    /// A freshly-sighted, still-running node with nothing known but its id — what a sidechain line
    /// arriving before any hook can assert.
    #[must_use]
    pub const fn running(id: String) -> Self {
        Self {
            id,
            parent_id: None,
            agent_type: None,
            description: None,
            status: SubagentStatus::Running,
            last_assistant_message: None,
        }
    }
}

/// Whether a subagent is still working.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SubagentStatus {
    /// Still working.
    Running,
    /// Finished (a `SubagentStop` was seen).
    Stopped,
}

/// A thinking-block placeholder marker. Presence ONLY: on Claude 4 the transcript's `thinking`
/// field is empty, and content is never invented to fill it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThinkingMarker {
    /// `true` when structure was present but no readable text — the "Thinking (not persisted)"
    /// case.
    #[serde(rename = "isPlaceholder")]
    pub is_placeholder: bool,
    /// The signature fingerprint, when present (proof a block existed).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    /// Text *iff* the transcript actually carried it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// A message for the timeline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageEvent {
    /// Who said it.
    pub role: MessageRole,
    /// What they said.
    pub text: String,
    /// `None` for the main session; set when the message belongs to a subagent.
    #[serde(rename = "agentID", skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

/// A message's speaker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    /// The human (or a tool harness posting on their behalf).
    User,
    /// Claude.
    Assistant,
}

/// Session metadata, learned from a meta transcript line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    /// The session uuid.
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The model name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The session's working directory.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// The transcript file, when a producer names it.
    #[serde(rename = "transcriptPath", skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
}

/// The workflow panel's marker. Workflows emit no JSONL event of their own; running-ness is
/// inferred indirectly from subagent activity. Minimal by design.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowMarker {
    /// Running or idle.
    pub state: WorkflowState,
}

/// A workflow's coarse state.
///
/// `Idle` is the DEFAULT because it is what a store that has been told nothing is in: a panel that
/// has seen no workflow marker must not claim one is running.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WorkflowState {
    /// At least one subagent is active.
    Running,
    /// Nothing running.
    #[default]
    Idle,
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::{Value, json};

    use super::{
        InspectorEvent, MessageEvent, MessageRole, SessionInfo, SubagentNode, SubagentStatus, ThinkingMarker,
        TodoItem, TodoStatus, ToolCard, ToolCardStatus,
    };

    fn encoded(event: &InspectorEvent) -> Value {
        serde_json::to_value(event).expect("an InspectorEvent always serializes")
    }

    /// The pin. Every literal here is what `JSONEncoder().encode(event)` produces on the Swift side
    /// for the same value; a shipped client decodes exactly this.
    #[test]
    fn the_wire_shape_matches_swifts_synthesized_codable() {
        let card = ToolCard {
            id: "toolu_1".to_owned(),
            name: "Read".to_owned(),
            input: json!({"file_path": "/tmp/a"}),
            output: None,
            status: ToolCardStatus::Pending,
        };

        // A single unlabeled associated value nests under `_0`, and a nil optional is OMITTED.
        assert_eq!(
            encoded(&InspectorEvent::ToolCard { card: card.clone() }),
            json!({"toolCard": {"_0": {
                "id": "toolu_1", "name": "Read",
                "input": {"file_path": "/tmp/a"}, "status": "pending",
            }}})
        );

        // LABELLED values use the labels — no `_0` — and keep Swift's capitalisation (`agentID`).
        assert_eq!(
            encoded(&InspectorEvent::SubagentToolCard {
                agent_id: "a1".to_owned(),
                card,
            }),
            json!({"subagentToolCard": {
                "agentID": "a1",
                "card": {
                    "id": "toolu_1", "name": "Read",
                    "input": {"file_path": "/tmp/a"}, "status": "pending",
                },
            }})
        );

        // A String-raw-value enum encodes as its raw value — `in_progress`, not `inProgress`.
        assert_eq!(
            encoded(&InspectorEvent::TodosUpdated {
                todos: vec![TodoItem {
                    content: "port it".to_owned(),
                    status: TodoStatus::InProgress,
                    active_form: Some("porting it".to_owned()),
                }],
            }),
            json!({"todosUpdated": {"_0": [
                {"content": "port it", "status": "in_progress", "activeForm": "porting it"},
            ]}})
        );

        assert_eq!(
            encoded(&InspectorEvent::SubagentUpdated {
                node: SubagentNode {
                    id: "a1".to_owned(),
                    parent_id: None,
                    agent_type: Some("Ariadne".to_owned()),
                    description: None,
                    status: SubagentStatus::Stopped,
                    last_assistant_message: Some("done".to_owned()),
                },
            }),
            json!({"subagentUpdated": {"_0": {
                "id": "a1", "agentType": "Ariadne",
                "status": "stopped", "lastAssistantMessage": "done",
            }}})
        );

        assert_eq!(
            encoded(&InspectorEvent::Thinking {
                marker: ThinkingMarker {
                    is_placeholder: true,
                    signature: Some("sig".to_owned()),
                    text: None,
                },
            }),
            json!({"thinking": {"_0": {"isPlaceholder": true, "signature": "sig"}}})
        );

        assert_eq!(
            encoded(&InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::Assistant,
                    text: "hi".to_owned(),
                    agent_id: None,
                },
            }),
            json!({"message": {"_0": {"role": "assistant", "text": "hi"}}})
        );

        assert_eq!(
            encoded(&InspectorEvent::SessionStarted {
                info: SessionInfo {
                    session_id: Some("s1".to_owned()),
                    model: Some("opus".to_owned()),
                    cwd: None,
                    transcript_path: None,
                },
            }),
            json!({"sessionStarted": {"_0": {"sessionID": "s1", "model": "opus"}}})
        );

        // A labelled SINGLE value still uses its label, not `_0`.
        assert_eq!(
            encoded(&InspectorEvent::UnknownLine {
                raw: "{not json".to_owned(),
            }),
            json!({"unknownLine": {"raw": "{not json"}})
        );
        assert_eq!(
            encoded(&InspectorEvent::HistoryTruncated { dropped_count: 7 }),
            json!({"historyTruncated": {"droppedCount": 7}})
        );
    }

    #[test]
    fn every_event_round_trips_through_its_own_json() {
        let events = vec![
            InspectorEvent::ToolCard {
                card: ToolCard {
                    id: "t".to_owned(),
                    name: "Bash".to_owned(),
                    input: json!({"command": "ls"}),
                    output: Some("a\nb".to_owned()),
                    status: ToolCardStatus::Errored,
                },
            },
            InspectorEvent::UnknownLine { raw: "x".to_owned() },
            InspectorEvent::HistoryTruncated {
                dropped_count: i64::MAX,
            },
        ];
        for event in events {
            let text = serde_json::to_string(&event).expect("serializes");
            let back: InspectorEvent = serde_json::from_str(&text).expect("round-trips");
            assert_eq!(back, event);
        }
    }
}
