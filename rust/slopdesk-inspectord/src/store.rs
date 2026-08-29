//! The inspector's CLIENT-side store: the fold a read-only viewer applies to the events this
//! daemon sends it.
//!
//! ## Why the client's store lives in the daemon's crate
//!
//! Because the event does. [`crate::event`] declares the taxonomy and derives both halves of serde
//! on it, and a fold's input is that type — so a fold anywhere else needs either an edge to this
//! crate or a second declaration of the eight types, and the second declaration is the defect this
//! module was written to delete. It used to be a Swift mirror in `Sources/SlopDeskInspector`,
//! decoded a second time by `JSONDecoder`; the rules it applied lived in a THIRD place,
//! `slopdesk_workspace::inspector_store`, reached through a door per decision. See `docs/66`.
//!
//! The direction of the move is the point: the rules came to meet the type, not the other way
//! round. `slopdesk-workspace` is where every other client-surface rule lives, and putting the fold
//! there would have dragged a daemon — tailer, server, replay log — under the crate every client
//! surface imports and onto all three FFI slices. This crate depends on `serde` and `serde_json`
//! and nothing else, and `slopdesk-ffi` already links it for the frame splitter.
//!
//! ## The card's two renderings are computed HERE, from the decoded input
//!
//! `tool_render::render_event` used to take an event's RAW BYTES, and its doc said why: the Swift
//! decoder turned every JSON number into a `Double` on the way past, so an input that reached the
//! renderer through it had already lost any integer past `2^53`. That is a fact about `JSONDecoder`
//! and not about JSON. `serde_json::Value` holds a `Number` that remembers whether it was an `i64`,
//! a `u64` or an `f64`, so [`crate::tool_render::tool_input`] called with the DECODED input is
//! exact — and the raw-bytes door, with its second parse of every event, is gone rather than
//! reimplemented.
//!
//! ## What the store does NOT do
//!
//! It does not own the connection. Whether the feed is live, ended or failed is about the
//! `NWConnection`'s lifetime, which is the near side's; this module never learns that a feed
//! stopped. It also never decides that a frame was bad — [`InspectorStore::apply`] answers `false`
//! for a body it cannot read and folds nothing, and the caller's existing skip-and-continue is what
//! turns that into "one rogue event costs one event".

use std::collections::HashMap;

use crate::event::{
    InspectorEvent, MessageEvent, SessionInfo, SubagentNode, ThinkingMarker, TodoItem, ToolCard,
    ToolCardStatus, WorkflowState,
};
use crate::tool_render::{self, ToolInputRender};

/// The slot a root row reports as its parent.
pub const NO_PARENT: i32 = -1;

/// The store's five bounded collections.
///
/// Every one of them grows with the length of a session, and the daemon already bounds its own
/// analogues — the replay window, the builder's processed keys — so the client was the unbounded
/// end. Eviction is BATCHED (a ceiling and a lower retained mark, not one entry at a time) so it
/// stays amortized O(1) rather than paying a front-removal per arrival once at the cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ring {
    /// The main session's tool cards, in arrival order.
    ToolCards,
    /// One subagent's tool cards. The ceiling is per agent, not across them.
    SubagentCards,
    /// The user/assistant message timeline.
    Messages,
    /// The distinct-agent count itself — the OUTER dimension, whose eviction takes an agent's node,
    /// its cards and its index together so the tree can never reference an orphan. Drop-oldest, and
    /// deliberately not drop-terminal: a stopped agent is still rendered, so evicting by status
    /// would vanish a visible node.
    Agents,
    /// The most recent unrecognised transcript lines, kept so the bare count can be inspected
    /// rather than being a dead-end alarm.
    UnknownLines,
}

impl Ring {
    /// Every ring, for the test that walks them all.
    pub const ALL: [Self; 5] = [
        Self::ToolCards,
        Self::SubagentCards,
        Self::Messages,
        Self::Agents,
        Self::UnknownLines,
    ];

    /// The count above which the ring evicts.
    #[must_use]
    pub const fn ceiling(self) -> usize {
        match self {
            Self::ToolCards | Self::Messages => 20_000,
            Self::SubagentCards => 10_000,
            Self::Agents => 2_000,
            Self::UnknownLines => 50,
        }
    }

    /// What an eviction leaves behind.
    ///
    /// Below [`Ring::ceiling`] for the four large rings, which is what makes eviction batched: the
    /// next arrival is thousands short of the ceiling rather than one over it.
    /// [`Ring::UnknownLines`] retains its whole ceiling because it is fifty entries — a batch
    /// there would throw away most of a window somebody is reading.
    #[must_use]
    pub const fn retained(self) -> usize {
        match self {
            Self::ToolCards | Self::Messages => 15_000,
            Self::SubagentCards => 7_500,
            Self::Agents => 1_500,
            Self::UnknownLines => 50,
        }
    }

    /// How many oldest entries an arrival at `count` evicts. `0` until the ceiling is passed.
    #[must_use]
    pub const fn overflow(self, count: usize) -> usize {
        if count <= self.ceiling() {
            return 0;
        }
        let retained = self.retained();
        if retained >= count {
            // Unreachable while `retained <= ceiling < count`, and written down so the answer can
            // never name more entries than the caller has.
            return 0;
        }
        count - retained
    }
}

/// One tool card as a panel reads it: the decoded card, and what its input renders as.
///
/// The two strings are computed once, when the card is folded, rather than on every read — a
/// collapsed row is drawn far more often than a card arrives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredCard {
    /// The card itself, exactly as the daemon sent it.
    pub card: ToolCard,
    /// Its input, as the two strings a card renders.
    pub render: ToolInputRender,
}

impl StoredCard {
    /// Renders `card`'s input and stores both together.
    #[must_use]
    fn new(card: ToolCard) -> Self {
        let render = tool_render::tool_input(&card.name, &card.input);
        Self { card, render }
    }
}

/// One row of the subagent tree: which agent it draws, and where its parent sits in the same
/// answer.
///
/// PRE-ORDER, so a parent always appears before its children — which is what lets a renderer
/// rebuild the nesting in one pass without a second lookup structure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeRow {
    /// The agent this row draws.
    pub id: String,
    /// The SLOT in this same answer that holds this row's parent, or [`NO_PARENT`] for a root.
    pub parent_slot: i32,
}

/// The empty level — what an agent with no children descends into.
const NO_CHILDREN: &[&str] = &[];

/// Everything the read-only inspector knows about one pane's agent session.
#[derive(Debug, Default)]
pub struct InspectorStore {
    tool_cards: Vec<StoredCard>,
    tool_card_index: HashMap<String, usize>,
    evicted_tool_cards: u64,
    todos: Vec<TodoItem>,
    agents: HashMap<String, SubagentNode>,
    agent_cards: HashMap<String, Vec<StoredCard>>,
    agent_card_index: HashMap<String, HashMap<String, usize>>,
    agent_order: Vec<String>,
    messages: Vec<MessageEvent>,
    last_thinking: Option<ThinkingMarker>,
    thinking_count: u64,
    session: Option<SessionInfo>,
    workflow: WorkflowState,
    unknown_line_count: u64,
    recent_unknown_lines: Vec<String>,
    dropped_replay_events: i64,
    revision: u64,
}

impl InspectorStore {
    /// An empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds one event's JSON body in. `false` means the body did not decode and nothing changed.
    ///
    /// The body is the frame's payload verbatim. Answering `false` rather than refusing is the
    /// whole resilience contract of this wire: a future or corrupt event costs that event and
    /// not the session's feed.
    pub fn apply(&mut self, body: &[u8]) -> bool {
        let Ok(event) = serde_json::from_slice::<InspectorEvent>(body) else {
            return false;
        };
        self.fold(event);
        // A `u64` bumped once per arriving event needs longer than the age of the universe to reach
        // its ceiling, so the wrap is a formality; it is written as a wrap rather than a saturate
        // because a revision that STOPS moving would read as "nothing changed" forever, while one
        // that wrapped would read as changed — which is the safe direction for a differ.
        self.revision = self.revision.wrapping_add(1);
        true
    }

    /// What a re-subscribe from sequence zero must undo, and nothing else.
    ///
    /// An iOS resume reuses the same store and asks the host to replay its ENTIRE history, so every
    /// event arrives a second time. Cards, agents, todos, the session and the workflow marker all
    /// self-dedupe — an id upserts, the rest are latest-wins — but the MONOTONIC accumulators do
    /// not, and without this a resume doubles "N thinking steps" and re-appends the whole message
    /// timeline.
    ///
    /// It is deliberately NOT a clear. Clearing the cards would make a re-subscribe on a live
    /// connection blank a panel that is about to be told the same things again, and the
    /// re-subscribe-after-a-flap path keeps the events it folded before the flap.
    ///
    /// The revision moves only if something did. A subscribe is the ONE call a caller makes without
    /// being told anything, so a reset that bumped unconditionally would report a change on every
    /// reconnect of an idle pane — and a differ that is told to redraw for nothing learns to be
    /// told.
    pub fn reset(&mut self) {
        let carried = self.thinking_count != 0
            || self.last_thinking.is_some()
            || self.unknown_line_count != 0
            || !self.recent_unknown_lines.is_empty()
            || !self.messages.is_empty()
            || self.evicted_tool_cards != 0
            || self.dropped_replay_events != 0;
        if !carried {
            return;
        }
        self.thinking_count = 0;
        self.last_thinking = None;
        self.unknown_line_count = 0;
        self.recent_unknown_lines.clear();
        self.messages.clear();
        self.evicted_tool_cards = 0;
        self.dropped_replay_events = 0;
        self.revision = self.revision.wrapping_add(1);
    }

    /// The counter a reader diffs against to learn that anything at all changed.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    fn fold(&mut self, event: InspectorEvent) {
        match event {
            InspectorEvent::ToolCard { card } => self.upsert_main_card(card),
            InspectorEvent::TodosUpdated { todos } => self.todos = todos,
            InspectorEvent::SubagentUpdated { node } => {
                if !self.agents.contains_key(&node.id) {
                    self.register_agent(node.id.clone());
                }
                self.agents.insert(node.id.clone(), node);
            },
            InspectorEvent::SubagentToolCard { agent_id, card } => self.upsert_subagent_card(&agent_id, card),
            InspectorEvent::Thinking { marker } => {
                self.last_thinking = Some(marker);
                self.thinking_count = self.thinking_count.saturating_add(1);
            },
            InspectorEvent::Message { message } => {
                self.messages.push(message);
                evict(&mut self.messages, Ring::Messages);
            },
            InspectorEvent::SessionStarted { info } => self.session = Some(info),
            InspectorEvent::Workflow { marker } => self.workflow = marker.state,
            InspectorEvent::UnknownLine { raw } => {
                self.unknown_line_count = self.unknown_line_count.saturating_add(1);
                self.recent_unknown_lines.push(raw);
                evict(&mut self.recent_unknown_lines, Ring::UnknownLines);
            },
            // Latest-wins: a re-replay re-sends the CURRENT drop count, so accumulating it would
            // claim a growing hole that is not there.
            InspectorEvent::HistoryTruncated { dropped_count } => self.dropped_replay_events = dropped_count,
        }
    }

    /// Replaces the card with this id, or appends it and evicts if that put the ring over.
    fn upsert_main_card(&mut self, card: ToolCard) {
        let stored = StoredCard::new(card);
        if let Some(&at) = self.tool_card_index.get(&stored.card.id)
            && let Some(slot) = self.tool_cards.get_mut(at)
        {
            *slot = stored;
            return;
        }
        self.tool_card_index
            .insert(stored.card.id.clone(), self.tool_cards.len());
        self.tool_cards.push(stored);
        let dropped = evict(&mut self.tool_cards, Ring::ToolCards);
        if dropped > 0 {
            self.evicted_tool_cards = self
                .evicted_tool_cards
                .saturating_add(u64::try_from(dropped).unwrap_or(u64::MAX));
            // Every survivor's position shifted down by `dropped`, so the lookup is rebuilt over the
            // surviving slice. Without this a later upsert of a RETAINED id resolves to the wrong
            // slot — or past the end — and appends a duplicate instead of updating in place.
            self.tool_card_index = index_of(&self.tool_cards);
        }
    }

    /// Records a newly-seen agent in arrival order and, past the ceiling, drops the oldest agents'
    /// node, cards and index TOGETHER so the tree can never reference an orphan.
    fn register_agent(&mut self, id: String) {
        self.agent_order.push(id);
        let drop = Ring::Agents.overflow(self.agent_order.len());
        if drop == 0 {
            return;
        }
        for evicted in self.agent_order.drain(..drop) {
            self.agents.remove(&evicted);
            self.agent_cards.remove(&evicted);
            self.agent_card_index.remove(&evicted);
        }
    }

    /// The same upsert, per agent — and the node is created if the card outran its hook.
    fn upsert_subagent_card(&mut self, agent_id: &str, card: ToolCard) {
        if !self.agents.contains_key(agent_id) {
            self.register_agent(agent_id.to_owned());
            self.agents
                .insert(agent_id.to_owned(), SubagentNode::running(agent_id.to_owned()));
        }
        let stored = StoredCard::new(card);
        let cards = self.agent_cards.entry(agent_id.to_owned()).or_default();
        let index = self.agent_card_index.entry(agent_id.to_owned()).or_default();
        if let Some(&at) = index.get(&stored.card.id)
            && let Some(slot) = cards.get_mut(at)
        {
            *slot = stored;
            return;
        }
        index.insert(stored.card.id.clone(), cards.len());
        cards.push(stored);
        if evict(cards, Ring::SubagentCards) > 0 {
            *index = index_of(cards);
        }
    }

    // MARK: what a surface reads

    /// The newest card still waiting on its result — the pending-tool line's subject.
    #[must_use]
    pub fn pending_card(&self) -> Option<&StoredCard> {
        self.tool_cards
            .iter()
            .rev()
            .find(|stored| stored.card.status == ToolCardStatus::Pending)
    }

    /// The `i/n · activeForm` line for the todos in flight, or `None` when nothing is.
    #[must_use]
    pub fn todo_scent(&self) -> Option<String> {
        tool_render::todo_scent(&self.todos)
    }

    /// Whether anything USER-VISIBLE has been folded in yet — the gate on the empty-state
    /// placeholder.
    ///
    /// The subagent test is the TREE's emptiness, never the raw agent map's: the tree drops
    /// empty-id and unreachable agents, so a single malformed record would otherwise suppress
    /// the placeholder while rendering nothing — the blank void this gate exists to prevent.
    ///
    /// Messages are excluded on purpose. They are stored and not rendered today, and counting them
    /// would reintroduce the same blank panel from the other direction.
    #[must_use]
    pub fn has_renderable_activity(&self) -> bool {
        !self.tool_cards.is_empty()
            || !self.todos.is_empty()
            || self.last_thinking.is_some()
            || self.unknown_line_count > 0
            || !self.subagent_tree().is_empty()
    }

    /// The agent tree as a PRE-ORDER list of rows, roots first, each level ordered by id.
    ///
    /// Sorted WITHIN a level rather than globally, which is `docs/16`'s rule: subagent arrival is
    /// asynchronous, so a global order would reshuffle siblings under unrelated parents every time
    /// a late one landed.
    ///
    /// Three kinds of record render nothing, and each is a real shape in tolerant input rather than
    /// a defensive nicety: an agent with an empty id (a phantom the transcript named without naming
    /// it), one whose stated parent is not an agent this store holds, and one reachable only
    /// through a cycle. None of them is an error — the answer simply does not carry them, which
    /// is what makes "the tree is empty" a verdict the empty-state placeholder can trust.
    ///
    /// The walk carries an explicit stack rather than recursing. This crate is built with
    /// `panic = "abort"`, so an overflowed stack is a dead process rather than a caught error, and
    /// the depth here is the caller's data.
    #[must_use]
    pub fn subagent_tree(&self) -> Vec<TreeRow> {
        let mut roots: Vec<&str> = Vec::new();
        let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
        for (id, node) in &self.agents {
            if id.is_empty() {
                continue;
            }
            match node.parent_id.as_deref() {
                // Only an ABSENT parent is a root. An empty one is a stated parent that names no
                // agent, which is the dangling case below and not the same claim.
                None => roots.push(id),
                // A parent this store does not hold is UNREACHABLE, not a root. Promoting it would
                // be the kinder-looking answer and the wrong one: it claims a top-level agent the
                // transcript never named.
                Some(parent) => {
                    if self.agents.contains_key(parent) {
                        children.entry(parent).or_default().push(id);
                    }
                },
            }
        }
        roots.sort_unstable();
        for level in children.values_mut() {
            level.sort_unstable();
        }

        let mut answer: Vec<TreeRow> = Vec::new();
        let mut stack: Vec<(&[&str], usize, i32)> = vec![(&roots, 0, NO_PARENT)];
        while let Some(top) = stack.len().checked_sub(1) {
            // Every agent is emitted at most once — each sits in exactly one level, so the part
            // reachable from the roots is a forest and a cycle is never entered. The bound is
            // written down anyway: it is what makes the walk terminate for EVERY input rather than
            // for every input that satisfies an argument.
            if answer.len() >= self.agents.len() {
                break;
            }
            let Some(&(level, cursor, parent_slot)) = stack.get(top) else {
                break;
            };
            let Some(&id) = level.get(cursor) else {
                stack.pop();
                continue;
            };
            if let Some(frame) = stack.get_mut(top) {
                frame.1 = frame.1.saturating_add(1);
            }
            let slot = i32::try_from(answer.len()).unwrap_or(NO_PARENT);
            answer.push(TreeRow {
                id: id.to_owned(),
                parent_slot,
            });
            stack.push((children.get(id).map_or(NO_CHILDREN, Vec::as_slice), 0, slot));
        }
        answer
    }

    // MARK: readings with no door, kept because the panel they belong to is a shipped decision

    /// The main timeline, in arrival order.
    #[must_use]
    pub fn tool_cards(&self) -> &[StoredCard] {
        &self.tool_cards
    }

    /// How many oldest main cards the drop-oldest cap has evicted.
    #[must_use]
    pub const fn evicted_tool_cards(&self) -> u64 {
        self.evicted_tool_cards
    }

    /// The latest todo list.
    #[must_use]
    pub fn todos(&self) -> &[TodoItem] {
        &self.todos
    }

    /// The agent this store holds under `id`, if any.
    #[must_use]
    pub fn agent(&self, id: &str) -> Option<&SubagentNode> {
        self.agents.get(id)
    }

    /// How many distinct agents are held.
    #[must_use]
    pub fn agent_count(&self) -> usize {
        self.agents.len()
    }

    /// One agent's cards, in arrival order. Empty for an agent this store does not hold.
    #[must_use]
    pub fn agent_cards(&self, id: &str) -> &[StoredCard] {
        self.agent_cards.get(id).map_or(&[], Vec::as_slice)
    }

    /// The message timeline.
    #[must_use]
    pub fn messages(&self) -> &[MessageEvent] {
        &self.messages
    }

    /// The most recent thinking marker.
    #[must_use]
    pub const fn last_thinking(&self) -> Option<&ThinkingMarker> {
        self.last_thinking.as_ref()
    }

    /// How many thinking blocks have been observed.
    #[must_use]
    pub const fn thinking_count(&self) -> u64 {
        self.thinking_count
    }

    /// The session metadata, once a producer names it.
    #[must_use]
    pub const fn session(&self) -> Option<&SessionInfo> {
        self.session.as_ref()
    }

    /// The workflow panel's coarse state.
    #[must_use]
    pub const fn workflow(&self) -> WorkflowState {
        self.workflow
    }

    /// The true monotonic total of unrecognised lines.
    #[must_use]
    pub const fn unknown_line_count(&self) -> u64 {
        self.unknown_line_count
    }

    /// The bounded window of recent unrecognised lines, newest last.
    #[must_use]
    pub fn recent_unknown_lines(&self) -> &[String] {
        &self.recent_unknown_lines
    }

    /// How many events the HOST's replay log dropped before the prefix this client subscribed from.
    #[must_use]
    pub const fn dropped_replay_events(&self) -> i64 {
        self.dropped_replay_events
    }
}

/// Drops the oldest entries `ring` says are over, and answers how many went.
fn evict<T>(items: &mut Vec<T>, ring: Ring) -> usize {
    let drop = ring.overflow(items.len());
    if drop > 0 {
        items.drain(..drop);
    }
    drop
}

/// The id-to-position lookup for a card list.
fn index_of(cards: &[StoredCard]) -> HashMap<String, usize> {
    cards
        .iter()
        .enumerate()
        .map(|(at, stored)| (stored.card.id.clone(), at))
        .collect()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::json;

    use super::{InspectorStore, NO_PARENT, Ring, TreeRow};
    use crate::event::{
        InspectorEvent, MessageEvent, MessageRole, SubagentNode, SubagentStatus, ThinkingMarker, TodoItem,
        TodoStatus, ToolCard, ToolCardStatus, WorkflowState,
    };

    /// Folds one event, through the JSON the daemon would actually have sent.
    ///
    /// Deliberately NOT a direct call to the private fold: every test here goes through the same
    /// serialise/deserialise round trip a live feed does, so a `#[serde]` attribute that stops
    /// matching is a failure here rather than only in production.
    fn apply(store: &mut InspectorStore, event: &InspectorEvent) {
        let body = serde_json::to_vec(event).expect("an InspectorEvent always serializes");
        assert!(store.apply(&body), "the store rejected its own crate's JSON");
    }

    fn card(id: &str, status: ToolCardStatus) -> ToolCard {
        ToolCard {
            id: id.to_owned(),
            name: "Read".to_owned(),
            input: json!({"file_path": format!("/tmp/{id}")}),
            output: None,
            status,
        }
    }

    fn tool_card(id: &str, status: ToolCardStatus) -> InspectorEvent {
        InspectorEvent::ToolCard {
            card: card(id, status),
        }
    }

    fn agent(id: &str, parent: Option<&str>) -> InspectorEvent {
        InspectorEvent::SubagentUpdated {
            node: SubagentNode {
                id: id.to_owned(),
                parent_id: parent.map(ToOwned::to_owned),
                agent_type: None,
                description: None,
                status: SubagentStatus::Running,
                last_assistant_message: None,
            },
        }
    }

    /// The tree as `(id, parent_slot)` pairs, which is what a reading eye wants.
    fn shape(rows: &[TreeRow]) -> Vec<(&str, i32)> {
        rows.iter()
            .map(|row| (row.id.as_str(), row.parent_slot))
            .collect()
    }

    // MARK: apply

    #[test]
    fn a_body_that_is_not_an_event_folds_nothing_and_says_so() {
        let mut store = InspectorStore::new();
        assert!(!store.apply(b"{not json"));
        assert!(!store.apply(b"{\"noSuchCase\":{}}"));
        assert_eq!(store.revision(), 0, "a rejected body did not move the revision");
        assert!(!store.has_renderable_activity());
    }

    #[test]
    fn every_accepted_event_moves_the_revision() {
        let mut store = InspectorStore::new();
        apply(&mut store, &tool_card("t1", ToolCardStatus::Pending));
        assert_eq!(store.revision(), 1);
        apply(&mut store, &tool_card("t1", ToolCardStatus::Completed));
        assert_eq!(store.revision(), 2, "an UPSERT is still a change");
    }

    // MARK: the empty-state gate

    #[test]
    fn a_fresh_store_renders_nothing_and_one_agent_changes_that() {
        let mut store = InspectorStore::new();
        assert!(!store.has_renderable_activity());
        apply(&mut store, &agent("a", None));
        assert!(store.has_renderable_activity());
    }

    #[test]
    fn a_stored_message_alone_does_not_open_the_gate() {
        let mut store = InspectorStore::new();
        apply(&mut store, &InspectorEvent::Message {
            message: MessageEvent {
                role: MessageRole::Assistant,
                text: "hi".to_owned(),
                agent_id: None,
            },
        });
        assert_eq!(store.messages().len(), 1);
        assert!(
            !store.has_renderable_activity(),
            "a stored-but-unrendered message keeps the timeline empty",
        );
    }

    #[test]
    fn a_malformed_agent_renders_nothing_and_so_does_not_suppress_the_placeholder() {
        let mut empty_id = InspectorStore::new();
        apply(&mut empty_id, &agent("", None));
        assert!(empty_id.subagent_tree().is_empty());
        assert!(!empty_id.has_renderable_activity());

        let mut self_parent = InspectorStore::new();
        apply(&mut self_parent, &agent("x", Some("x")));
        assert!(self_parent.subagent_tree().is_empty());
        assert!(!self_parent.has_renderable_activity());
    }

    // MARK: the tree

    #[test]
    fn roots_come_out_sorted_by_id_rather_than_by_arrival() {
        let mut store = InspectorStore::new();
        for id in ["c", "a", "b"] {
            apply(&mut store, &agent(id, None));
        }
        assert_eq!(shape(&store.subagent_tree()), [("a", -1), ("b", -1), ("c", -1)]);
    }

    #[test]
    fn a_child_follows_its_parent_and_names_its_parents_slot() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("a", None));
        apply(&mut store, &agent("b", Some("a")));
        apply(&mut store, &agent("c", None));
        assert_eq!(
            shape(&store.subagent_tree()),
            [("a", -1), ("b", 0), ("c", -1)],
            "pre-order: a, then a's child, then the next root",
        );
    }

    #[test]
    fn siblings_are_ordered_inside_their_own_level_only() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("r1", None));
        apply(&mut store, &agent("r2", None));
        apply(&mut store, &agent("zz", Some("r1")));
        apply(&mut store, &agent("aa", Some("r1")));
        apply(&mut store, &agent("bb", Some("r2")));
        assert_eq!(
            shape(&store.subagent_tree()),
            [("r1", -1), ("aa", 0), ("zz", 0), ("r2", -1), ("bb", 3)],
            "aa before zz under r1; r2's own child is untouched by that ordering",
        );
    }

    #[test]
    fn depth_is_carried_by_the_parent_slot_rather_than_by_nesting() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("a", None));
        apply(&mut store, &agent("b", Some("a")));
        apply(&mut store, &agent("c", Some("b")));
        apply(&mut store, &agent("d", Some("c")));
        assert_eq!(shape(&store.subagent_tree()), [
            ("a", -1),
            ("b", 0),
            ("c", 1),
            ("d", 2)
        ]);
    }

    #[test]
    fn an_empty_id_renders_nowhere_and_takes_its_children_with_it() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("", None));
        apply(&mut store, &agent("child", Some("")));
        assert!(
            store.subagent_tree().is_empty(),
            "the phantom is dropped, and the child that named it hangs off nothing walked",
        );
    }

    /// An empty parent id is a STATED parent that names no agent, never "no parent".
    ///
    /// The distinction is the difference between an agent that renders nowhere and one promoted to
    /// the top level, which is a claim about the transcript that nothing supports.
    #[test]
    fn an_empty_parent_id_is_dangling_rather_than_absent() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("stated", Some("")));
        apply(&mut store, &agent("absent", None));
        assert_eq!(shape(&store.subagent_tree()), [("absent", -1)]);
    }

    #[test]
    fn a_parent_this_store_does_not_hold_is_unreachable_rather_than_promoted() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("orphan", Some("ghost")));
        apply(&mut store, &agent("root", None));
        assert_eq!(
            shape(&store.subagent_tree()),
            [("root", -1)],
            "an agent whose stated parent is missing does not become a top-level agent",
        );
    }

    #[test]
    fn a_two_agent_cycle_renders_nothing_and_still_terminates() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("a", Some("b")));
        apply(&mut store, &agent("b", Some("a")));
        assert!(store.subagent_tree().is_empty());
    }

    #[test]
    fn a_long_cycle_off_a_real_root_still_terminates() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("root", None));
        for step in 1..64_u32 {
            let previous = if step == 1 { 63 } else { step - 1 };
            apply(
                &mut store,
                &agent(&format!("n{step:03}"), Some(&format!("n{previous:03}"))),
            );
        }
        assert_eq!(
            shape(&store.subagent_tree()),
            [("root", -1)],
            "the ring hangs off nothing reachable, so only the real root renders",
        );
    }

    #[test]
    fn every_reachable_agent_appears_exactly_once_and_after_its_parent() {
        let mut store = InspectorStore::new();
        apply(&mut store, &agent("m", None));
        apply(&mut store, &agent("z", Some("m")));
        apply(&mut store, &agent("a", Some("m")));
        apply(&mut store, &agent("q", Some("a")));
        apply(&mut store, &agent("b", None));
        apply(&mut store, &agent("p", Some("b")));
        let rows = store.subagent_tree();

        let mut seen: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
        seen.sort_unstable();
        assert_eq!(seen, ["a", "b", "m", "p", "q", "z"]);

        for (slot, row) in rows.iter().enumerate() {
            if row.parent_slot == NO_PARENT {
                continue;
            }
            let parent = usize::try_from(row.parent_slot).unwrap_or(usize::MAX);
            assert!(parent < slot, "pre-order: slot {slot}'s parent sits at {parent}");
        }
    }

    #[test]
    fn the_answer_does_not_depend_on_the_order_the_agents_arrived_in() {
        let mut forward = InspectorStore::new();
        for id in ["a", "b", "c"] {
            apply(&mut forward, &agent(id, None));
        }
        let mut reversed = InspectorStore::new();
        for id in ["c", "b", "a"] {
            apply(&mut reversed, &agent(id, None));
        }
        assert_eq!(shape(&forward.subagent_tree()), shape(&reversed.subagent_tree()));
    }

    // MARK: the bounded rings

    #[test]
    fn every_ring_evicts_only_past_its_ceiling_and_lands_on_its_retained_mark() {
        for ring in Ring::ALL {
            let ceiling = ring.ceiling();
            assert!(ceiling > 0, "zero is not a ceiling any ring has");
            assert!(
                ring.retained() <= ceiling,
                "a ring cannot retain more than it holds"
            );
            assert_eq!(ring.overflow(0), 0);
            assert_eq!(ring.overflow(ceiling), 0, "at the ceiling is not over it");
            let over = ceiling.saturating_add(1);
            assert_eq!(
                over - ring.overflow(over),
                ring.retained(),
                "one over lands on retained"
            );
            let flood = ceiling.saturating_mul(3);
            assert_eq!(flood - ring.overflow(flood), ring.retained(), "so does a flood");
        }
    }

    #[test]
    fn tool_cards_are_bounded_and_the_index_survives_an_eviction() {
        let mut store = InspectorStore::new();
        let total = Ring::ToolCards.ceiling() + 100;
        for at in 0..total {
            apply(&mut store, &tool_card(&format!("t{at}"), ToolCardStatus::Pending));
        }
        assert!(store.tool_cards().len() <= Ring::ToolCards.ceiling());
        assert_eq!(
            store.tool_cards().last().map(|stored| stored.card.id.as_str()),
            Some(format!("t{}", total - 1)).as_deref(),
            "newest card retained",
        );
        assert!(!store.tool_cards().iter().any(|stored| stored.card.id == "t0"));
        assert_eq!(
            store.evicted_tool_cards(),
            u64::try_from(total - store.tool_cards().len()).expect("a count fits a u64"),
            "the truncation banner's number is what actually went",
        );

        // The part that breaks when the index is left pointing at pre-eviction offsets: an upsert of
        // a SURVIVING id must land in place rather than appending a duplicate.
        let survivor = format!("t{}", total - 1);
        let before = store.tool_cards().len();
        let mut updated = card(&survivor, ToolCardStatus::Completed);
        updated.output = Some("done".to_owned());
        apply(&mut store, &InspectorEvent::ToolCard { card: updated });
        assert_eq!(store.tool_cards().len(), before, "no duplicate append");
        assert_eq!(
            store
                .tool_cards()
                .iter()
                .filter(|stored| stored.card.id == survivor)
                .count(),
            1,
        );
        assert_eq!(
            store
                .tool_cards()
                .iter()
                .find(|stored| stored.card.id == survivor)
                .and_then(|stored| stored.card.output.as_deref()),
            Some("done"),
            "updated in place",
        );
    }

    #[test]
    fn subagent_cards_are_bounded_per_agent_and_keep_their_own_index() {
        let mut store = InspectorStore::new();
        let total = Ring::SubagentCards.ceiling() + 100;
        for at in 0..total {
            apply(&mut store, &InspectorEvent::SubagentToolCard {
                agent_id: "agent".to_owned(),
                card: card(&format!("s{at}"), ToolCardStatus::Pending),
            });
        }
        assert!(store.agent_cards("agent").len() <= Ring::SubagentCards.ceiling());
        let survivor = format!("s{}", total - 1);
        assert_eq!(
            store
                .agent_cards("agent")
                .last()
                .map(|stored| stored.card.id.as_str()),
            Some(survivor.as_str()),
        );

        let mut updated = card(&survivor, ToolCardStatus::Completed);
        updated.output = Some("done".to_owned());
        apply(&mut store, &InspectorEvent::SubagentToolCard {
            agent_id: "agent".to_owned(),
            card: updated,
        });
        let cards = store.agent_cards("agent");
        assert_eq!(
            cards.iter().filter(|stored| stored.card.id == survivor).count(),
            1
        );
        assert_eq!(
            cards
                .iter()
                .find(|stored| stored.card.id == survivor)
                .and_then(|stored| stored.card.output.as_deref()),
            Some("done"),
        );
    }

    #[test]
    fn messages_are_bounded() {
        let mut store = InspectorStore::new();
        let total = Ring::Messages.ceiling() + 50;
        for at in 0..total {
            apply(&mut store, &InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::Assistant,
                    text: format!("m{at}"),
                    agent_id: None,
                },
            });
        }
        assert!(store.messages().len() <= Ring::Messages.ceiling());
        assert_eq!(
            store.messages().last().map(|message| message.text.as_str()),
            Some(format!("m{}", total - 1)).as_deref(),
        );
    }

    #[test]
    fn unknown_lines_are_bounded_but_the_count_is_the_true_total() {
        let mut store = InspectorStore::new();
        for at in 0..60 {
            apply(&mut store, &InspectorEvent::UnknownLine {
                raw: format!("line {at}"),
            });
        }
        assert_eq!(
            store.unknown_line_count(),
            60,
            "count is the true monotonic total"
        );
        assert_eq!(store.recent_unknown_lines().len(), Ring::UnknownLines.ceiling());
        assert_eq!(
            store.recent_unknown_lines().last().map(String::as_str),
            Some("line 59"),
            "newest retained",
        );
        assert_eq!(
            store.recent_unknown_lines().first().map(String::as_str),
            Some("line 10"),
            "oldest dropped",
        );
        assert!(store.has_renderable_activity());
    }

    #[test]
    fn distinct_agents_are_bounded_and_an_eviction_leaves_no_orphan() {
        let mut store = InspectorStore::new();
        let total = Ring::Agents.ceiling() + 100;
        for at in 0..total {
            apply(&mut store, &InspectorEvent::SubagentToolCard {
                agent_id: format!("agent{at}"),
                card: card(&format!("c{at}"), ToolCardStatus::Pending),
            });
        }
        assert!(store.agent_count() <= Ring::Agents.ceiling());
        assert!(
            store.agent(&format!("agent{}", total - 1)).is_some(),
            "newest retained"
        );
        assert!(store.agent("agent0").is_none(), "oldest evicted");
        assert!(
            store.agent_cards("agent0").is_empty(),
            "the evicted agent's cards went with it",
        );
        for row in store.subagent_tree() {
            assert!(
                store.agent(&row.id).is_some(),
                "every rendered row names an agent the store still holds",
            );
        }
    }

    // MARK: reset

    #[test]
    fn a_full_replay_rebuilds_the_accumulators_rather_than_doubling_them() {
        let replay = [
            InspectorEvent::Thinking {
                marker: ThinkingMarker {
                    is_placeholder: true,
                    signature: None,
                    text: None,
                },
            },
            InspectorEvent::UnknownLine { raw: "a".to_owned() },
            InspectorEvent::UnknownLine { raw: "b".to_owned() },
            InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::Assistant,
                    text: "hi".to_owned(),
                    agent_id: None,
                },
            },
            tool_card("t1", ToolCardStatus::Pending),
        ];

        let mut store = InspectorStore::new();
        for _ in 0..2 {
            store.reset();
            for event in &replay {
                apply(&mut store, event);
            }
            assert_eq!(store.thinking_count(), 1);
            assert_eq!(store.unknown_line_count(), 2);
            assert_eq!(store.recent_unknown_lines(), ["a".to_owned(), "b".to_owned()]);
            assert_eq!(store.messages().len(), 1);
            assert_eq!(store.tool_cards().len(), 1, "cards dedupe by id across replays");
        }
    }

    #[test]
    fn a_reset_keeps_what_a_re_subscribe_is_about_to_be_told_again() {
        let mut store = InspectorStore::new();
        apply(&mut store, &tool_card("old", ToolCardStatus::Completed));
        apply(&mut store, &agent("a1", None));
        apply(&mut store, &InspectorEvent::TodosUpdated {
            todos: vec![TodoItem {
                content: "keep me".to_owned(),
                status: TodoStatus::InProgress,
                active_form: None,
            }],
        });

        store.reset();
        assert_eq!(store.tool_cards().len(), 1, "a reset is not a clear");
        assert!(store.agent("a1").is_some());
        assert_eq!(store.todos().len(), 1);
        assert_eq!(store.messages().len(), 0, "but the accumulators did go");
    }

    #[test]
    fn a_reset_with_nothing_to_undo_does_not_report_a_change() {
        let mut store = InspectorStore::new();
        store.reset();
        assert_eq!(store.revision(), 0, "a fresh store's subscribe is not news");

        // Cards, agents and todos are none of reset's business, so a store holding only those still
        // has nothing for it to undo.
        apply(&mut store, &tool_card("t1", ToolCardStatus::Pending));
        let settled = store.revision();
        store.reset();
        assert_eq!(
            store.revision(),
            settled,
            "and neither is a re-subscribe that changed nothing"
        );

        // One accumulator is enough to make it news again.
        apply(&mut store, &InspectorEvent::Message {
            message: MessageEvent {
                role: MessageRole::Assistant,
                text: "hi".to_owned(),
                agent_id: None,
            },
        });
        let before = store.revision();
        store.reset();
        assert_eq!(store.revision(), before + 1, "clearing the timeline IS a change");
    }

    // MARK: what the two overlays read

    #[test]
    fn the_pending_card_is_the_newest_one_still_waiting() {
        let mut store = InspectorStore::new();
        assert!(
            store.pending_card().is_none(),
            "nothing is in flight on a fresh store"
        );
        apply(&mut store, &tool_card("first", ToolCardStatus::Pending));
        apply(&mut store, &tool_card("second", ToolCardStatus::Pending));
        apply(&mut store, &tool_card("done", ToolCardStatus::Completed));
        assert_eq!(
            store.pending_card().map(|stored| stored.card.id.as_str()),
            Some("second"),
            "the newest PENDING one, not the newest card",
        );

        apply(&mut store, &tool_card("second", ToolCardStatus::Completed));
        assert_eq!(
            store.pending_card().map(|stored| stored.card.id.as_str()),
            Some("first"),
            "completing it falls back to the one still open",
        );
    }

    #[test]
    fn a_pending_card_carries_the_two_strings_its_row_renders() {
        let mut store = InspectorStore::new();
        apply(&mut store, &InspectorEvent::ToolCard {
            card: ToolCard {
                id: "b1".to_owned(),
                name: "Bash".to_owned(),
                input: json!({"command": "ls -la"}),
                output: None,
                status: ToolCardStatus::Pending,
            },
        });
        let pending = store.pending_card().expect("a pending card was just folded");
        assert_eq!(pending.card.name, "Bash", "the label the row renders secondary");
        assert_eq!(
            pending.render.summary, "ls -la",
            "Bash collapses to the exact text that runs"
        );
    }

    /// The reason the rendering moved off the raw bytes: `serde_json` keeps an integer an integer,
    /// so the flattening no longer has to be handed the payload a second time to stay exact.
    #[test]
    fn an_integer_past_two_to_the_fifty_third_renders_exactly() {
        let mut store = InspectorStore::new();
        apply(&mut store, &InspectorEvent::ToolCard {
            card: ToolCard {
                id: "big".to_owned(),
                name: "Whatever".to_owned(),
                input: json!({"n": 9_007_199_254_740_993_i64}),
                output: None,
                status: ToolCardStatus::Pending,
            },
        });
        let pending = store.pending_card().expect("a pending card was just folded");
        assert!(
            pending.render.display.contains("9007199254740993"),
            "the odd integer past 2^53 survived, rather than rounding to …92: {}",
            pending.render.display,
        );
    }

    #[test]
    fn the_todo_scent_reads_off_the_list_the_store_holds() {
        let mut store = InspectorStore::new();
        assert!(store.todo_scent().is_none(), "nothing is in flight");
        apply(&mut store, &InspectorEvent::TodosUpdated {
            todos: vec![
                TodoItem {
                    content: "first".to_owned(),
                    status: TodoStatus::Completed,
                    active_form: None,
                },
                TodoItem {
                    content: "second".to_owned(),
                    status: TodoStatus::InProgress,
                    active_form: Some("doing the second".to_owned()),
                },
            ],
        });
        assert_eq!(store.todo_scent().as_deref(), Some("2/2 · doing the second"));
    }

    #[test]
    fn the_latest_todo_list_replaces_the_previous_one_wholesale() {
        let mut store = InspectorStore::new();
        for content in ["one", "two"] {
            apply(&mut store, &InspectorEvent::TodosUpdated {
                todos: vec![TodoItem {
                    content: content.to_owned(),
                    status: TodoStatus::Pending,
                    active_form: None,
                }],
            });
        }
        assert_eq!(store.todos().len(), 1);
        assert_eq!(
            store.todos().first().map(|item| item.content.as_str()),
            Some("two")
        );
    }

    // MARK: the latest-wins readings

    #[test]
    fn a_re_replay_re_states_the_dropped_count_rather_than_accumulating_it() {
        let mut store = InspectorStore::new();
        apply(&mut store, &InspectorEvent::HistoryTruncated { dropped_count: 7 });
        assert_eq!(store.dropped_replay_events(), 7);
        apply(&mut store, &InspectorEvent::HistoryTruncated { dropped_count: 9 });
        assert_eq!(store.dropped_replay_events(), 9, "latest-wins, not a sum");
    }

    #[test]
    fn the_session_and_the_workflow_marker_are_latest_wins_too() {
        let mut store = InspectorStore::new();
        assert!(store.session().is_none());
        assert_eq!(store.workflow(), WorkflowState::Idle, "idle until told otherwise");
        apply(&mut store, &InspectorEvent::Workflow {
            marker: crate::event::WorkflowMarker {
                state: WorkflowState::Running,
            },
        });
        assert_eq!(store.workflow(), WorkflowState::Running);
    }

    #[test]
    fn an_agent_node_arriving_after_its_card_replaces_the_placeholder() {
        let mut store = InspectorStore::new();
        apply(&mut store, &InspectorEvent::SubagentToolCard {
            agent_id: "a1".to_owned(),
            card: card("s1", ToolCardStatus::Pending),
        });
        assert_eq!(
            store.agent("a1").map(|node| node.status),
            Some(SubagentStatus::Running),
            "a card outrunning its hook creates the node",
        );
        assert!(
            store.tool_cards().is_empty(),
            "and it does not leak into the main timeline"
        );

        apply(&mut store, &InspectorEvent::SubagentUpdated {
            node: SubagentNode {
                id: "a1".to_owned(),
                parent_id: None,
                agent_type: Some("Ariadne".to_owned()),
                description: None,
                status: SubagentStatus::Stopped,
                last_assistant_message: None,
            },
        });
        let node = store.agent("a1").expect("the node is still there");
        assert_eq!(node.status, SubagentStatus::Stopped);
        assert_eq!(node.agent_type.as_deref(), Some("Ariadne"));
        assert_eq!(
            store.agent_cards("a1").len(),
            1,
            "the placeholder's cards survived"
        );
    }
}
