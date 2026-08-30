//! Folds parsed [`TranscriptLine`]s into [`InspectorEvent`]s, holding the cross-line state the
//! events need: tool-card pairing, the latest todo list, subagent nodes, and a dedup set.
//!
//! Pure and synchronous — no I/O, no threads. The tailer and the subagent watcher feed lines in and
//! this produces the typed events, so the emitted order is exactly the feed order.
//!
//! ## Tool-card pairing
//! - a `tool_use` opens a `Pending` card and emits it;
//! - a later `tool_result` with a matching `tool_use_id` completes/errors it and RE-emits the card;
//! - **out of order**: a result seen BEFORE its use is held, then applied when the use arrives (the
//!   card is emitted once, already resolved);
//! - **missing result**: a card with no result stays pending forever — never an error;
//! - `is_error == true` ⇒ `Errored`.
//!
//! ## Every map here is BOUNDED
//! This state lives for the daemon's whole life, fed by an untrusted append-only file. Each map has
//! a cap and an eviction rule, documented at its constant. A terminal card is DROPPED rather than
//! retained, because no later result can change it and the dedup set guarantees its lines are never
//! re-applied.
//!
//! ## The hook seam is gone, deliberately
//! Swift's `EventBuilder` also folded `HookPayload`s. Production never fed it any: the hook relay's
//! records go to the DETECTION path (`docs/50`), which is a different consumer with a different
//! state machine, and hostd's inspector wiring passed hooks nowhere. A separate daemon cannot
//! receive them at all, so the fold was dropped rather than ported as a limb nothing reaches.
//! `SlopDeskInspector`'s `HookIngest` stays in Swift for the detection path it actually
//! serves.

use std::collections::{HashMap, HashSet, VecDeque};

use serde_json::Value;

use crate::event::{
    InspectorEvent, MessageEvent, MessageRole, SessionInfo, SubagentNode, ThinkingMarker, TodoItem,
    TodoStatus, ToolCard, ToolCardStatus,
};
use crate::json::string_at;
use crate::line::{
    AssistantLine, LineIdentity, MetaLine, ToolResultBlock, ToolUseBlock, TranscriptLine, UserLine,
};

/// Cap on the dedup ring. One line ≈ one entry; this spans any realistic Claude Code transcript, so
/// the only re-read that matters — a truncation, where the tailer restarts at offset 0 and re-feeds
/// the whole file — still dedups every live line, while a pathologically long session stays
/// bounded.
const PROCESSED_KEY_CAP: usize = 100_000;

/// Cap on each held out-of-order result map. A `tool_result` whose `tool_use` never arrives (a
/// truncated transcript, or a feed of orphan results) would otherwise be retained forever.
const PENDING_RESULT_CAP: usize = 4096;

/// Cap on the number of distinct SUBAGENT ids retained. Every per-subagent map is keyed by agent
/// id; without a cap on that dimension a long session — or a transcript declaring many distinct ids
/// — grows them for the daemon's whole life.
const MAX_AGENTS: usize = 2000;

/// How far the agent maps are cut back when [`MAX_AGENTS`] is passed, so the eviction is one batch
/// rather than one-per-insert.
const AGENT_RETAIN_TARGET: usize = 1500;

/// The tool names whose payload is accumulated TODO state rather than a card.
const TODO_TOOLS: [&str; 3] = ["TodoWrite", "TaskCreate", "TaskUpdate"];

/// Per-agent card + held-result state. Grouped in one struct so an agent eviction removes all of it
/// together — the Swift original kept four parallel dictionaries and had to remember to evict from
/// each, which is exactly the shape a leak hides in.
#[derive(Debug, Default)]
struct AgentState {
    /// Open (non-terminal) cards by card id.
    open_cards: HashMap<String, ToolCard>,
    /// Results that arrived before their `tool_use`.
    pending_results: HashMap<String, ToolResultBlock>,
    /// Insertion order of `pending_results`, for the cap.
    pending_order: VecDeque<String>,
}

/// The cross-line fold.
#[derive(Debug, Default)]
pub struct EventBuilder {
    /// Dedup keys already processed, keyed by line uuid (main) or `sidechain:<agent>:<uuid>`.
    processed_keys: HashSet<String>,
    /// Insertion order of `processed_keys`, so the oldest can be evicted past the cap.
    processed_key_order: VecDeque<String>,

    /// The main session's cards and held results.
    main: AgentState,
    /// Per-subagent cards and held results.
    agents: HashMap<String, AgentState>,
    /// Known subagent nodes, so a status change re-emits the same merged node.
    subagents: HashMap<String, SubagentNode>,
    /// Distinct subagent ids in first-sight order, for the drop-oldest cap.
    agent_order: VecDeque<String>,
    /// The same ids as a set, so "have I seen this agent?" is O(1) rather than a scan of
    /// `agent_order` on every sidechain line.
    seen_agents: HashSet<String>,

    /// The latest todo list, replaced wholesale.
    latest_todos: Vec<TodoItem>,
}

impl EventBuilder {
    /// A fresh builder with nothing seen.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The current todo snapshot.
    #[must_use]
    pub fn todos(&self) -> &[TodoItem] {
        &self.latest_todos
    }

    /// Distinct subagent ids currently tracked (≤ [`MAX_AGENTS`]).
    #[must_use]
    pub fn tracked_agent_count(&self) -> usize {
        self.agent_order.len()
    }

    /// Folds one MAIN-session line into zero or more events.
    pub fn ingest(&mut self, line: &TranscriptLine) -> Vec<InspectorEvent> {
        match line {
            TranscriptLine::User(user) => self.ingest_user(user, None),
            TranscriptLine::Assistant(assistant) => self.ingest_assistant(assistant, None),
            TranscriptLine::Meta(meta) => self.ingest_meta(meta),
            TranscriptLine::Ignored { .. } => Vec::new(),
            TranscriptLine::Unknown { raw } => vec![InspectorEvent::UnknownLine { raw: raw.clone() }],
        }
    }

    /// Folds one SUBAGENT line (from a `subagents/agent-<hash>.jsonl` file).
    ///
    /// The node is asserted first: a sidechain line can arrive long before any signal that names
    /// the subagent, and a card with no node to hang under would render nowhere.
    pub fn ingest_subagent(&mut self, line: &TranscriptLine, agent_id: &str) -> Vec<InspectorEvent> {
        let mut events = self.update_subagent(SubagentNode::running(agent_id.to_owned()));
        events.extend(match line {
            TranscriptLine::User(user) => self.ingest_user(user, Some(agent_id)),
            TranscriptLine::Assistant(assistant) => self.ingest_assistant(assistant, Some(agent_id)),
            TranscriptLine::Meta(_) | TranscriptLine::Ignored { .. } => Vec::new(),
            TranscriptLine::Unknown { raw } => {
                vec![InspectorEvent::UnknownLine { raw: raw.clone() }]
            },
        });
        events
    }

    /// Records or updates a subagent node and emits the change; emits nothing when nothing changed.
    ///
    /// The merge matters: a later update must not BLANK a field an earlier one supplied — a node
    /// re-asserted as merely "running, id only" on every sidechain line would otherwise erase the
    /// type and description as fast as they arrived.
    pub fn update_subagent(&mut self, node: SubagentNode) -> Vec<InspectorEvent> {
        self.note_agent(&node.id);
        let existing = self.subagents.get(&node.id);
        let mut merged = node;
        if let Some(existing) = existing {
            merged.parent_id = merged.parent_id.or_else(|| existing.parent_id.clone());
            merged.agent_type = merged.agent_type.or_else(|| existing.agent_type.clone());
            merged.description = merged.description.or_else(|| existing.description.clone());
            merged.last_assistant_message = merged
                .last_assistant_message
                .or_else(|| existing.last_assistant_message.clone());
        }
        if existing == Some(&merged) {
            return Vec::new();
        }
        self.subagents.insert(merged.id.clone(), merged.clone());
        vec![InspectorEvent::SubagentUpdated { node: merged }]
    }

    // MARK: line folds

    fn ingest_user(&mut self, user: &UserLine, agent_id: Option<&str>) -> Vec<InspectorEvent> {
        if !self.mark_processed(&user.identity, agent_id) {
            return Vec::new();
        }
        let mut events = Vec::new();
        if let Some(text) = user.text.as_ref().filter(|text| !text.is_empty()) {
            events.push(InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::User,
                    text: text.clone(),
                    agent_id: agent_id.map(str::to_owned),
                },
            });
        }
        for result in &user.tool_results {
            events.extend(self.apply_tool_result(result, agent_id));
        }
        events
    }

    fn ingest_assistant(&mut self, assistant: &AssistantLine, agent_id: Option<&str>) -> Vec<InspectorEvent> {
        if !self.mark_processed(&assistant.identity, agent_id) {
            return Vec::new();
        }
        let mut events = Vec::new();
        for thinking in &assistant.thinking {
            events.push(InspectorEvent::Thinking {
                marker: ThinkingMarker {
                    is_placeholder: thinking.is_placeholder(),
                    signature: thinking.signature.clone(),
                    text: thinking.text.clone(),
                },
            });
        }
        if let Some(text) = assistant.text.as_ref().filter(|text| !text.is_empty()) {
            events.push(InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::Assistant,
                    text: text.clone(),
                    agent_id: agent_id.map(str::to_owned),
                },
            });
        }
        for use_block in &assistant.tool_uses {
            // Todos/tasks are accumulated STATE, not a card.
            if let Some(todo_event) = self.todos_event(use_block) {
                events.push(todo_event);
            } else {
                events.extend(self.apply_tool_use(use_block, agent_id));
            }
        }
        events
    }

    fn ingest_meta(&mut self, meta: &MetaLine) -> Vec<InspectorEvent> {
        if !self.mark_processed(&meta.identity, None) {
            return Vec::new();
        }
        if !meta.defines_session() {
            return Vec::new();
        }
        vec![InspectorEvent::SessionStarted {
            info: SessionInfo {
                session_id: meta.session_id.clone(),
                model: meta.model.clone(),
                cwd: meta.cwd.clone(),
                transcript_path: None,
            },
        }]
    }

    // MARK: tool-card pairing

    fn apply_tool_use(&mut self, use_block: &ToolUseBlock, agent_id: Option<&str>) -> Vec<InspectorEvent> {
        // A result that already arrived out of order resolves the card immediately. It is born
        // TERMINAL, so it is not kept open — no further result can change it.
        if let Some(pending) = self.take_pending_result(&use_block.id, agent_id) {
            let card = ToolCard {
                id: use_block.id.clone(),
                name: use_block.name.clone(),
                input: use_block.input.clone(),
                output: Some(pending.content),
                status: if pending.is_error {
                    ToolCardStatus::Errored
                } else {
                    ToolCardStatus::Completed
                },
            };
            return Self::card_event(card, agent_id);
        }
        let card = ToolCard {
            id: use_block.id.clone(),
            name: use_block.name.clone(),
            input: use_block.input.clone(),
            output: None,
            status: ToolCardStatus::Pending,
        };
        self.state_mut(agent_id)
            .open_cards
            .insert(card.id.clone(), card.clone());
        Self::card_event(card, agent_id)
    }

    fn apply_tool_result(&mut self, result: &ToolResultBlock, agent_id: Option<&str>) -> Vec<InspectorEvent> {
        // Terminal now, so the card is REMOVED rather than updated in place: the open-card map must
        // not grow over a long session, and the uuid dedup guarantees neither this line nor its
        // `tool_use` line is ever re-applied, so a later lookup can never need the entry again.
        let Some(mut card) = self.state_mut(agent_id).open_cards.remove(&result.tool_use_id) else {
            // Out of order: the result arrived before its use. Hold it.
            self.set_pending_result(result, agent_id);
            return Vec::new();
        };
        card.output = Some(result.content.clone());
        card.status = if result.is_error {
            ToolCardStatus::Errored
        } else {
            ToolCardStatus::Completed
        };
        Self::card_event(card, agent_id)
    }

    fn card_event(card: ToolCard, agent_id: Option<&str>) -> Vec<InspectorEvent> {
        match agent_id {
            None => vec![InspectorEvent::ToolCard { card }],
            Some(agent_id) => {
                vec![InspectorEvent::SubagentToolCard {
                    agent_id: agent_id.to_owned(),
                    card,
                }]
            },
        }
    }

    // MARK: todos

    /// Parses a `TodoWrite`/`Task*` payload into the latest todo list, or `None` when `use_block`
    /// is not one of those tools.
    ///
    /// "No array supplied" and "an explicitly empty array" are DIFFERENT: a payload carrying
    /// neither key (a partial single-task update) must not blank the whole panel, while a
    /// present `todos: []` is a legitimate clear.
    fn todos_event(&mut self, use_block: &ToolUseBlock) -> Option<InspectorEvent> {
        if !TODO_TOOLS.contains(&use_block.name.as_str()) {
            return None;
        }
        let array = use_block
            .input
            .get("todos")
            .or_else(|| use_block.input.get("tasks"))
            .and_then(Value::as_array)?;
        let items: Vec<TodoItem> = array
            .iter()
            .filter(|entry| entry.is_object())
            .filter_map(|entry| {
                let content = string_at(entry, "content")
                    .or_else(|| string_at(entry, "description"))
                    .or_else(|| string_at(entry, "text"))?;
                Some(TodoItem {
                    content: content.to_owned(),
                    status: TodoStatus::parse(string_at(entry, "status").unwrap_or("pending")),
                    active_form: string_at(entry, "activeForm").map(str::to_owned),
                })
            })
            .collect();
        self.latest_todos.clone_from(&items);
        Some(InspectorEvent::TodosUpdated { todos: items })
    }

    // MARK: dedup

    /// Marks a line processed; `false` when it was already seen, so the caller emits nothing.
    ///
    /// A line WITHOUT a uuid is always processed — it cannot be deduped, and the tailer guarantees
    /// each physical line is fed once.
    fn mark_processed(&mut self, identity: &LineIdentity, agent_id: Option<&str>) -> bool {
        let Some(uuid) = identity.uuid.as_deref() else {
            return true;
        };
        let key = agent_id.map_or_else(
            || uuid.to_owned(),
            |agent_id| format!("sidechain:{agent_id}:{uuid}"),
        );
        if !self.processed_keys.insert(key.clone()) {
            return false;
        }
        self.processed_key_order.push_back(key);
        if self.processed_key_order.len() > PROCESSED_KEY_CAP
            && let Some(oldest) = self.processed_key_order.pop_front()
        {
            self.processed_keys.remove(&oldest);
        }
        true
    }

    // MARK: per-agent storage

    /// The card/result state for `agent_id` (or the main session), creating it on first sight and
    /// registering the agent against the cap.
    fn state_mut(&mut self, agent_id: Option<&str>) -> &mut AgentState {
        match agent_id {
            None => &mut self.main,
            Some(agent_id) => {
                self.note_agent(agent_id);
                self.agents.entry(agent_id.to_owned()).or_default()
            },
        }
    }

    /// Records a (possibly new) agent id and, past [`MAX_AGENTS`], evicts the OLDEST agents down to
    /// [`AGENT_RETAIN_TARGET`] — removing all of an evicted agent's state together. Idempotent.
    fn note_agent(&mut self, agent_id: &str) {
        if !self.seen_agents.insert(agent_id.to_owned()) {
            return;
        }
        self.agent_order.push_back(agent_id.to_owned());
        if self.agent_order.len() <= MAX_AGENTS {
            return;
        }
        let evict_count = self.agent_order.len() - AGENT_RETAIN_TARGET;
        for _ in 0..evict_count {
            let Some(old) = self.agent_order.pop_front() else {
                break;
            };
            self.seen_agents.remove(&old);
            self.subagents.remove(&old);
            self.agents.remove(&old);
        }
    }

    fn set_pending_result(&mut self, result: &ToolResultBlock, agent_id: Option<&str>) {
        let state = self.state_mut(agent_id);
        // An overwrite keeps the same order slot (an idempotent re-feed must not re-queue), so only
        // a genuinely new id is tracked — and only that can push the map past the cap.
        let is_new = state
            .pending_results
            .insert(result.tool_use_id.clone(), result.clone())
            .is_none();
        if !is_new {
            return;
        }
        state.pending_order.push_back(result.tool_use_id.clone());
        while state.pending_order.len() > PENDING_RESULT_CAP {
            // Dropping the oldest orphan is correct: had its `tool_use` ever existed, the card
            // would have been emitted long ago.
            let Some(oldest) = state.pending_order.pop_front() else {
                break;
            };
            state.pending_results.remove(&oldest);
        }
    }

    fn take_pending_result(&mut self, id: &str, agent_id: Option<&str>) -> Option<ToolResultBlock> {
        let state = match agent_id {
            None => &mut self.main,
            Some(agent_id) => self.agents.get_mut(agent_id)?,
        };
        let taken = state.pending_results.remove(id)?;
        if let Some(index) = state.pending_order.iter().position(|held| held == id) {
            state.pending_order.remove(index);
        }
        Some(taken)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::json;

    use super::{AGENT_RETAIN_TARGET, EventBuilder, MAX_AGENTS, PENDING_RESULT_CAP};
    use crate::event::{InspectorEvent, SubagentNode, SubagentStatus, ToolCardStatus};
    use crate::line::{AssistantLine, LineIdentity, ToolResultBlock, ToolUseBlock, TranscriptLine, UserLine};

    fn identity(uuid: &str) -> LineIdentity {
        LineIdentity {
            uuid: Some(uuid.to_owned()),
            ..LineIdentity::default()
        }
    }

    fn tool_use(uuid: &str, id: &str, name: &str) -> TranscriptLine {
        TranscriptLine::Assistant(AssistantLine {
            identity: identity(uuid),
            text: None,
            tool_uses: vec![ToolUseBlock {
                id: id.to_owned(),
                name: name.to_owned(),
                input: json!({}),
            }],
            thinking: Vec::new(),
        })
    }

    fn tool_result(uuid: &str, id: &str, output: &str, is_error: bool) -> TranscriptLine {
        TranscriptLine::User(UserLine {
            identity: identity(uuid),
            text: None,
            tool_results: vec![ToolResultBlock {
                tool_use_id: id.to_owned(),
                content: output.to_owned(),
                is_error,
            }],
        })
    }

    fn card_of(event: &InspectorEvent) -> &crate::event::ToolCard {
        match event {
            InspectorEvent::ToolCard { card } | InspectorEvent::SubagentToolCard { card, .. } => card,
            other => panic!("expected a tool card, got {other:?}"),
        }
    }

    #[test]
    fn a_use_then_its_result_emits_pending_then_completed() {
        let mut builder = EventBuilder::new();
        let opened = builder.ingest(&tool_use("u1", "t1", "Read"));
        assert_eq!(opened.len(), 1);
        assert_eq!(card_of(&opened[0]).status, ToolCardStatus::Pending);
        assert!(card_of(&opened[0]).output.is_none());

        let closed = builder.ingest(&tool_result("u2", "t1", "contents", false));
        assert_eq!(closed.len(), 1);
        assert_eq!(card_of(&closed[0]).status, ToolCardStatus::Completed);
        assert_eq!(card_of(&closed[0]).output.as_deref(), Some("contents"));
    }

    #[test]
    fn an_errored_result_errors_the_card() {
        let mut builder = EventBuilder::new();
        drop(builder.ingest(&tool_use("u1", "t1", "Bash")));
        let closed = builder.ingest(&tool_result("u2", "t1", "boom", true));
        assert_eq!(card_of(&closed[0]).status, ToolCardStatus::Errored);
    }

    #[test]
    fn a_result_arriving_first_is_held_and_the_card_is_born_resolved() {
        let mut builder = EventBuilder::new();
        assert!(
            builder
                .ingest(&tool_result("u1", "t1", "early", false))
                .is_empty(),
            "an orphan result emits nothing yet"
        );
        let opened = builder.ingest(&tool_use("u2", "t1", "Read"));
        assert_eq!(opened.len(), 1, "the card is emitted ONCE, already resolved");
        assert_eq!(card_of(&opened[0]).status, ToolCardStatus::Completed);
        assert_eq!(card_of(&opened[0]).output.as_deref(), Some("early"));
    }

    #[test]
    fn a_card_whose_result_never_comes_stays_pending_and_nothing_breaks() {
        let mut builder = EventBuilder::new();
        drop(builder.ingest(&tool_use("u1", "t1", "Read")));
        // A result for a DIFFERENT id must not touch it, and must not error.
        assert!(builder.ingest(&tool_result("u2", "other", "x", false)).is_empty());
    }

    #[test]
    fn a_terminal_card_is_dropped_so_a_second_result_cannot_resurrect_it() {
        let mut builder = EventBuilder::new();
        drop(builder.ingest(&tool_use("u1", "t1", "Read")));
        drop(builder.ingest(&tool_result("u2", "t1", "first", false)));
        // A second result for the same id has no open card, so it is HELD as an orphan and emits
        // nothing — it can never re-emit an already-terminal card.
        assert!(
            builder
                .ingest(&tool_result("u3", "t1", "second", true))
                .is_empty()
        );
    }

    #[test]
    fn a_replayed_line_is_deduped_by_uuid() {
        let mut builder = EventBuilder::new();
        assert_eq!(builder.ingest(&tool_use("u1", "t1", "Read")).len(), 1);
        assert!(
            builder.ingest(&tool_use("u1", "t1", "Read")).is_empty(),
            "the same uuid must not double-emit after a truncation re-read"
        );
    }

    #[test]
    fn a_line_without_a_uuid_is_always_processed() {
        let mut builder = EventBuilder::new();
        let line = TranscriptLine::User(UserLine {
            identity: LineIdentity::default(),
            text: Some("hello".to_owned()),
            tool_results: Vec::new(),
        });
        assert_eq!(builder.ingest(&line).len(), 1);
        assert_eq!(builder.ingest(&line).len(), 1);
    }

    #[test]
    fn the_same_uuid_on_a_sidechain_is_a_different_key() {
        let mut builder = EventBuilder::new();
        assert_eq!(builder.ingest(&tool_use("u1", "t1", "Read")).len(), 1);
        // The node assertion plus the card — the main-session uuid did not swallow it.
        let events = builder.ingest_subagent(&tool_use("u1", "t2", "Read"), "a1");
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], InspectorEvent::SubagentUpdated { .. }));
        assert!(matches!(events[1], InspectorEvent::SubagentToolCard { .. }));
    }

    #[test]
    fn an_unknown_line_is_surfaced_not_dropped() {
        let mut builder = EventBuilder::new();
        let events = builder.ingest(&TranscriptLine::Unknown { raw: "?".to_owned() });
        assert!(matches!(events.as_slice(), [InspectorEvent::UnknownLine { raw }] if raw == "?"));
    }

    #[test]
    fn an_ignored_line_emits_nothing() {
        let mut builder = EventBuilder::new();
        assert!(
            builder
                .ingest(&TranscriptLine::Ignored {
                    line_type: "queue-operation".to_owned()
                })
                .is_empty()
        );
    }

    #[test]
    fn todo_payloads_replace_the_list_and_are_never_cards() {
        let mut builder = EventBuilder::new();
        let line = TranscriptLine::Assistant(AssistantLine {
            identity: identity("u1"),
            text: None,
            tool_uses: vec![ToolUseBlock {
                id: "t1".to_owned(),
                name: "TodoWrite".to_owned(),
                input: json!({"todos": [
                    {"content": "a", "status": "completed"},
                    {"content": "b", "status": "in_progress", "activeForm": "doing b"},
                    {"status": "pending"},
                ]}),
            }],
            thinking: Vec::new(),
        });
        let events = builder.ingest(&line);
        let [InspectorEvent::TodosUpdated { todos }] = events.as_slice() else {
            panic!("expected exactly one todosUpdated, got {events:?}");
        };
        // The content-less entry is dropped, not rendered as a blank row.
        assert_eq!(todos.len(), 2);
        assert_eq!(todos[1].active_form.as_deref(), Some("doing b"));
        assert_eq!(builder.todos().len(), 2);
    }

    #[test]
    fn a_task_payload_carrying_neither_key_leaves_the_panel_alone() {
        let mut builder = EventBuilder::new();
        let line = TranscriptLine::Assistant(AssistantLine {
            identity: identity("u1"),
            text: None,
            tool_uses: vec![ToolUseBlock {
                id: "t1".to_owned(),
                name: "TaskUpdate".to_owned(),
                input: json!({"id": "x", "status": "completed"}),
            }],
            thinking: Vec::new(),
        });
        // It becomes an ordinary card — which is the point: the todo PANEL is untouched, rather
        // than being cleared by a payload that said nothing about the list.
        let events = builder.ingest(&line);
        assert!(matches!(events.as_slice(), [InspectorEvent::ToolCard { .. }]));
        assert!(builder.todos().is_empty());
    }

    #[test]
    fn an_explicitly_empty_todo_array_does_clear_the_list() {
        let mut builder = EventBuilder::new();
        let line = TranscriptLine::Assistant(AssistantLine {
            identity: identity("u1"),
            text: None,
            tool_uses: vec![ToolUseBlock {
                id: "t1".to_owned(),
                name: "TodoWrite".to_owned(),
                input: json!({"todos": []}),
            }],
            thinking: Vec::new(),
        });
        let events = builder.ingest(&line);
        assert!(matches!(events.as_slice(), [InspectorEvent::TodosUpdated { todos }] if todos.is_empty()));
    }

    #[test]
    fn a_subagent_update_merges_rather_than_blanking_what_is_known() {
        let mut builder = EventBuilder::new();
        let rich = SubagentNode {
            id: "a1".to_owned(),
            parent_id: None,
            agent_type: Some("Ariadne".to_owned()),
            description: Some("map it".to_owned()),
            status: SubagentStatus::Running,
            last_assistant_message: None,
        };
        assert_eq!(builder.update_subagent(rich).len(), 1);

        let stop = SubagentNode {
            status: SubagentStatus::Stopped,
            last_assistant_message: Some("done".to_owned()),
            ..SubagentNode::running("a1".to_owned())
        };
        let events = builder.update_subagent(stop);
        let [InspectorEvent::SubagentUpdated { node }] = events.as_slice() else {
            panic!("expected one subagentUpdated, got {events:?}");
        };
        assert_eq!(node.status, SubagentStatus::Stopped);
        assert_eq!(
            node.agent_type.as_deref(),
            Some("Ariadne"),
            "the type survives the stop"
        );
        assert_eq!(node.description.as_deref(), Some("map it"));
        assert_eq!(node.last_assistant_message.as_deref(), Some("done"));
    }

    #[test]
    fn re_asserting_an_unchanged_node_emits_nothing() {
        let mut builder = EventBuilder::new();
        assert_eq!(
            builder
                .update_subagent(SubagentNode::running("a1".to_owned()))
                .len(),
            1
        );
        assert!(
            builder
                .update_subagent(SubagentNode::running("a1".to_owned()))
                .is_empty()
        );
    }

    #[test]
    fn the_dedup_and_orphan_maps_stay_bounded_under_an_adversarial_feed() {
        let mut builder = EventBuilder::new();
        for index in 0..(PENDING_RESULT_CAP + 500) {
            drop(builder.ingest(&tool_result(
                &format!("u{index}"),
                &format!("orphan{index}"),
                "x",
                false,
            )));
        }
        // The oldest orphans were evicted, so their late `tool_use` opens a PENDING card rather
        // than resolving — which is the documented cost of the cap.
        let opened = builder.ingest(&tool_use("late", "orphan0", "Read"));
        assert_eq!(card_of(&opened[0]).status, ToolCardStatus::Pending);
        // The newest orphan is still held, and still resolves.
        let id = format!("orphan{}", PENDING_RESULT_CAP + 499);
        let resolved = builder.ingest(&tool_use("late2", &id, "Read"));
        assert_eq!(card_of(&resolved[0]).status, ToolCardStatus::Completed);
    }

    #[test]
    fn the_agent_dimension_is_capped_and_evicts_the_oldest_in_one_batch() {
        let mut builder = EventBuilder::new();
        for index in 0..=MAX_AGENTS {
            drop(builder.update_subagent(SubagentNode::running(format!("a{index}"))));
        }
        assert_eq!(builder.tracked_agent_count(), AGENT_RETAIN_TARGET);
        // The oldest agent is gone entirely, so re-asserting it is a genuinely NEW sighting.
        assert_eq!(
            builder
                .update_subagent(SubagentNode::running("a0".to_owned()))
                .len(),
            1
        );
    }

    #[test]
    fn thinking_blocks_emit_placeholder_markers_before_the_text() {
        let mut builder = EventBuilder::new();
        let line = TranscriptLine::Assistant(AssistantLine {
            identity: identity("u1"),
            text: Some("answer".to_owned()),
            tool_uses: Vec::new(),
            thinking: vec![crate::line::ThinkingBlock {
                signature: Some("sig".to_owned()),
                text: None,
            }],
        });
        let events = builder.ingest(&line);
        assert!(matches!(events[0], InspectorEvent::Thinking { ref marker } if marker.is_placeholder));
        assert!(matches!(events[1], InspectorEvent::Message { .. }));
    }
}
