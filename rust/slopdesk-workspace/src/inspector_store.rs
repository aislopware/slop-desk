//! What the inspector's client-side STORE decides: which nesting the agents make, what counts as
//! something to render, and how much of a long session it is allowed to keep.
//!
//! `slopdesk-inspectord` is the daemon at the far end of the inspector channel and
//! `slopdesk-ffi`'s `inspector` module is its FRAME. This is neither: it is the fold the read-only
//! client applies to the events that arrive, which is a rule about a SURFACE and therefore lives
//! here with the rest of them.
//!
//! ## No identity crosses
//!
//! An agent is named by a string the host minted, and the near side holds a map keyed by it. Its
//! id does cross — but only as BYTES, and only because the levels of the tree are sorted by it, the
//! way `search_rank` takes the text it ranks. The PARENT link crosses as a position instead, so the
//! join stays the near side's own `String ==` over the map it already owns, and this module never
//! has to decide whether two ids are the same agent.
//!
//! ## The tree is walked, never recursed
//!
//! The rule it replaced was a recursive Swift closure carrying a `visited` set, guarding against a
//! self-parented or empty-id agent recursing forever. Two things make that guard unnecessary here
//! rather than merely re-spelled: an id crosses as a SPAN, so the empty id is a length rather than
//! a key that groups under the root, and a parent crosses as a POSITION, so each agent sits in
//! exactly one level. Single parenthood makes the part reachable from the roots a forest by
//! construction — a cycle is simply never entered — and the walk carries an explicit stack, so
//! neither the answer's size nor the process's stack depends on how deep the caller's data goes.
//! That matters more here than the ordinary tidiness argument: this crate is built with
//! `panic = "abort"`, so an overflowed stack is a dead process rather than a caught error.
//!
//! ## What did NOT move
//!
//! The upserts. Which slot of a card list an arriving card replaces, and the index rebuilt over the
//! survivors after an eviction, are dictionary bookkeeping over values the near side owns. What
//! crossed out of them is the only decision they contained: HOW MANY to drop, which is
//! [`ring_overflow`].

/// The parent of an agent that sits at the top level — no parent id at all, or an empty one.
pub const ROOT: i32 = -1;

/// The parent of an agent whose parent id names no agent in the list.
///
/// A distinct answer from [`ROOT`] on purpose. Such an agent is UNREACHABLE: it hangs under a key
/// nothing walks, so it renders nowhere. Collapsing it to a root would be the kinder-looking
/// answer and the wrong one — it would promote an agent whose stated parent is missing to the top
/// level, which is a claim about the transcript that nothing supports.
pub const DANGLING: i32 = -2;

/// The slot an answer's ROOT row reports as its parent.
pub const NO_PARENT: i32 = -1;

/// One agent, as the tree rule reads it.
///
/// The id is a span into a blob the caller lends alongside the list, rather than a string per
/// record: it is needed for exactly one thing — ordering a level — and a span keeps the ownership
/// question from arising at all.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AgentEntry {
    /// Where this agent's id starts in the id blob.
    pub id_offset: u32,
    /// How many bytes long it is. Zero — and any span that does not fit the blob — is the malformed
    /// EMPTY id, which renders nothing.
    pub id_length: u32,
    /// The POSITION of this agent's parent in the same list, or [`ROOT`] / [`DANGLING`].
    pub parent: i32,
}

/// One row of the answer: which agent it draws, and where its parent sits in the answer.
///
/// The rows are PRE-ORDER, so a parent always appears before its children. That is what lets the
/// near side rebuild the nesting in one reverse pass without a second lookup structure.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TreeSlot {
    /// Which entry of the caller's list this row draws.
    pub position: u32,
    /// The SLOT in this same answer that holds this row's parent, or [`NO_PARENT`] for a root.
    pub parent_slot: i32,
}

/// One frame of the explicit walk — the level being read, how far into it, and what to record as
/// the parent of everything it emits.
#[derive(Clone, Copy, Debug)]
struct Frame {
    /// Which level list this frame is reading. `0` is the roots; `p + 1` is entry `p`'s children.
    bucket: usize,
    /// How many of that level's rows have been emitted already.
    cursor: usize,
    /// The answer slot every row this frame emits reports as its parent.
    parent_slot: i32,
}

/// The empty id — what a zero-length or out-of-range span reads as.
const NO_ID: &[u8] = &[];

/// The bytes one entry's id span names, or empty when the span does not fit the blob.
///
/// A span that overruns is the same answer as a zero-length one BY DESIGN: both are "this record
/// carries no id", and an agent with no id renders nowhere. The alternative — refusing the whole
/// call — would let one malformed record blank a panel that has fifty good ones in it.
fn id_of<'a>(ids: &'a [u8], entry: &AgentEntry) -> &'a [u8] {
    let start = usize::try_from(entry.id_offset).unwrap_or(usize::MAX);
    let length = usize::try_from(entry.id_length).unwrap_or(usize::MAX);
    start
        .checked_add(length)
        .and_then(|end| ids.get(start..end))
        .unwrap_or(NO_ID)
}

/// The id of the entry at `position`, or empty when there is no such entry.
fn id_at<'a>(ids: &'a [u8], entries: &[AgentEntry], position: usize) -> &'a [u8] {
    entries.get(position).map_or(NO_ID, |entry| id_of(ids, entry))
}

/// The agent tree as a PRE-ORDER list of rows, roots first, each level ordered by id.
///
/// Sorted WITHIN a level rather than globally, which is `docs/16`'s rule: subagent arrival is
/// asynchronous, so a global order would reshuffle siblings under unrelated parents every time a
/// late one landed. Ordering is over the id's BYTES, which is what an id is here.
///
/// Three kinds of record render nothing, and each is a real shape in tolerant input rather than a
/// defensive nicety: an agent with an empty id (a phantom the transcript named without naming), one
/// whose parent is [`DANGLING`], and one whose parent position is outside the list. None of them is
/// an error — the answer simply does not carry them, which is what makes "the tree is empty" a
/// verdict the empty-state placeholder can trust.
#[must_use]
pub fn subagent_tree(ids: &[u8], entries: &[AgentEntry]) -> Vec<TreeSlot> {
    let count = entries.len();
    // One bucket per entry, plus bucket `0` for the roots. Every entry lands in exactly ONE of them
    // — which is the single-parenthood the module header's forest argument rests on.
    let mut levels: Vec<Vec<usize>> = vec![Vec::new(); count.saturating_add(1)];
    for (position, entry) in entries.iter().enumerate() {
        if id_of(ids, entry).is_empty() {
            continue;
        }
        let bucket = if entry.parent == ROOT {
            0
        } else {
            match usize::try_from(entry.parent) {
                Ok(parent) if parent < count => parent.saturating_add(1),
                // DANGLING, any other negative, and a position past the end: unreachable, so it is
                // filed nowhere rather than promoted to the top level.
                _ => continue,
            }
        };
        if let Some(level) = levels.get_mut(bucket) {
            level.push(position);
        }
    }
    for level in &mut levels {
        level.sort_by(|left, right| {
            id_at(ids, entries, *left)
                .cmp(id_at(ids, entries, *right))
                // Ids are unique in every caller this has (they key the near side's own map), so
                // the tiebreak is unreachable in practice. It is here because a comparator that
                // reported two DIFFERENT rows equal would leave their order down to the sort's
                // internals, which is the one way this answer could stop being a function of its
                // inputs.
                .then(left.cmp(right))
        });
    }

    let mut answer: Vec<TreeSlot> = Vec::new();
    let mut stack = vec![Frame {
        bucket: 0,
        cursor: 0,
        parent_slot: NO_PARENT,
    }];
    while let Some(top) = stack.len().checked_sub(1) {
        // Every entry can be emitted at most once — see the forest argument in the module header —
        // so this bound is unreachable. It is written down anyway: it is what makes the walk
        // terminate for EVERY input rather than for every input that satisfies an argument.
        if answer.len() >= count {
            break;
        }
        let Some(frame) = stack.get(top).copied() else {
            break;
        };
        let Some(&position) = levels.get(frame.bucket).and_then(|level| level.get(frame.cursor)) else {
            stack.pop();
            continue;
        };
        if let Some(reading) = stack.get_mut(top) {
            reading.cursor = reading.cursor.saturating_add(1);
        }
        let slot = i32::try_from(answer.len()).unwrap_or(NO_PARENT);
        answer.push(TreeSlot {
            position: u32::try_from(position).unwrap_or(u32::MAX),
            parent_slot: frame.parent_slot,
        });
        stack.push(Frame {
            bucket: position.saturating_add(1),
            cursor: 0,
            parent_slot: slot,
        });
    }
    answer
}

/// Whether anything USER-VISIBLE has been folded in yet — the gate on the empty-state placeholder.
///
/// `has_subagent_tree` is the TREE's emptiness, never the raw agent map's: [`subagent_tree`] drops
/// empty-id and unreachable agents, so a single malformed record would otherwise suppress the
/// placeholder while rendering nothing — the blank void this gate exists to prevent.
///
/// Messages are excluded on purpose. They are stored and not rendered today, and counting them
/// would reintroduce the same blank panel from the other direction.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four flags ARE the rule: each is an independent reason to draw something, and folding \
              them into a struct would hide that any ONE is enough"
)]
pub const fn has_renderable_activity(
    has_tool_cards: bool,
    has_todos: bool,
    has_subagent_tree: bool,
    has_thinking: bool,
    unknown_line_count: u64,
) -> bool {
    has_tool_cards || has_todos || has_subagent_tree || has_thinking || unknown_line_count > 0
}

/// The store's five bounded collections.
///
/// Every one of them grows with the length of a session, and the daemon already bounds its own
/// analogues — the replay window, the builder's processed keys — so the client was the unbounded
/// end. Eviction is BATCHED (a ceiling and a lower retained mark, not one entry at a time) so it
/// stays amortized O(1) rather than paying a front-removal per arrival at the cap.
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
    /// Every ring, in crossing order. The order IS the contract with the C byte below.
    pub const ALL: [Self; 5] = [
        Self::ToolCards,
        Self::SubagentCards,
        Self::Messages,
        Self::Agents,
        Self::UnknownLines,
    ];

    /// The byte this ring crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::ToolCards => 0,
            Self::SubagentCards => 1,
            Self::Messages => 2,
            Self::Agents => 3,
            Self::UnknownLines => 4,
        }
    }

    /// The ring a byte names, or `None` for one no build wrote.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::ToolCards),
            1 => Some(Self::SubagentCards),
            2 => Some(Self::Messages),
            3 => Some(Self::Agents),
            4 => Some(Self::UnknownLines),
            _ => None,
        }
    }

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
    /// next arrival is 5,000 short of the ceiling rather than one over it. [`Ring::UnknownLines`]
    /// retains its whole ceiling because it is fifty entries — a batch there would throw away most
    /// of a window somebody is reading.
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

/// The ceiling of the ring `code` names, or `0` for a code this build cannot name.
///
/// Zero is the refusal rather than a member: no ring here has a ceiling of zero, so a caller
/// reading `0` has been told "this build has no such ring", never "keep nothing".
#[must_use]
pub const fn ring_ceiling(code: u8) -> usize {
    match Ring::from_code(code) {
        Some(ring) => ring.ceiling(),
        None => 0,
    }
}

/// How many oldest entries the ring `code` names evicts at `count`, or `0` for an unnamed ring —
/// which is the answer that cannot lose anything.
#[must_use]
pub const fn ring_overflow(code: u8, count: usize) -> usize {
    match Ring::from_code(code) {
        Some(ring) => ring.overflow(count),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AgentEntry, DANGLING, NO_PARENT, ROOT, Ring, TreeSlot, has_renderable_activity, ring_ceiling,
        ring_overflow, subagent_tree,
    };

    /// A blob of ids and the entries naming them, from `(id, parent)` pairs.
    fn corpus(rows: &[(&str, i32)]) -> (Vec<u8>, Vec<AgentEntry>) {
        let mut ids: Vec<u8> = Vec::new();
        let mut entries: Vec<AgentEntry> = Vec::new();
        for (id, parent) in rows {
            let offset = u32::try_from(ids.len()).unwrap_or(u32::MAX);
            ids.extend_from_slice(id.as_bytes());
            entries.push(AgentEntry {
                id_offset: offset,
                id_length: u32::try_from(id.len()).unwrap_or(u32::MAX),
                parent: *parent,
            });
        }
        (ids, entries)
    }

    /// The answer as `(position, parent_slot)` pairs, which is what a reading eye wants.
    fn shape(answer: &[TreeSlot]) -> Vec<(u32, i32)> {
        answer
            .iter()
            .map(|slot| (slot.position, slot.parent_slot))
            .collect()
    }

    #[test]
    fn an_empty_list_makes_an_empty_tree() {
        assert!(subagent_tree(&[], &[]).is_empty());
        let (ids, entries) = corpus(&[]);
        assert!(subagent_tree(&ids, &entries).is_empty());
    }

    #[test]
    fn roots_come_out_sorted_by_id_rather_than_by_arrival() {
        let (ids, entries) = corpus(&[("c", ROOT), ("a", ROOT), ("b", ROOT)]);
        assert_eq!(shape(&subagent_tree(&ids, &entries)), [(1, -1), (2, -1), (0, -1)]);
    }

    #[test]
    fn a_child_follows_its_parent_and_names_its_parents_slot() {
        // b is a's child; c is a root that sorts after a.
        let (ids, entries) = corpus(&[("a", ROOT), ("b", 0), ("c", ROOT)]);
        assert_eq!(
            shape(&subagent_tree(&ids, &entries)),
            [(0, -1), (1, 0), (2, -1)],
            "pre-order: a, then a's child, then the next root",
        );
    }

    #[test]
    fn siblings_are_ordered_inside_their_own_level_only() {
        // Two roots, each with two children whose ids sort the opposite way to arrival.
        let (ids, entries) = corpus(&[("r1", ROOT), ("r2", ROOT), ("zz", 0), ("aa", 0), ("bb", 1)]);
        assert_eq!(
            shape(&subagent_tree(&ids, &entries)),
            [(0, -1), (3, 0), (2, 0), (1, -1), (4, 3)],
            "aa before zz under r1; r2's own child is untouched by that ordering",
        );
    }

    #[test]
    fn depth_is_carried_by_the_parent_slot_rather_than_by_nesting() {
        let (ids, entries) = corpus(&[("a", ROOT), ("b", 0), ("c", 1), ("d", 2)]);
        assert_eq!(shape(&subagent_tree(&ids, &entries)), [
            (0, -1),
            (1, 0),
            (2, 1),
            (3, 2)
        ]);
    }

    #[test]
    fn an_empty_id_renders_nowhere_and_takes_its_children_with_it() {
        let (ids, entries) = corpus(&[("", ROOT), ("child", 0)]);
        assert!(
            subagent_tree(&ids, &entries).is_empty(),
            "the phantom is dropped, and nothing hangs off a row that is not there",
        );
    }

    #[test]
    fn a_span_that_overruns_the_blob_reads_as_the_empty_id() {
        let entries = [AgentEntry {
            id_offset: 0,
            id_length: 9,
            parent: ROOT,
        }];
        assert!(subagent_tree(b"short", &entries).is_empty());
        let far = [AgentEntry {
            id_offset: u32::MAX,
            id_length: 1,
            parent: ROOT,
        }];
        assert!(subagent_tree(b"short", &far).is_empty());
    }

    #[test]
    fn a_dangling_parent_is_unreachable_rather_than_promoted() {
        let (ids, entries) = corpus(&[("orphan", DANGLING), ("root", ROOT)]);
        assert_eq!(
            shape(&subagent_tree(&ids, &entries)),
            [(1, -1)],
            "an agent whose stated parent is missing does not become a top-level agent",
        );
    }

    #[test]
    fn a_parent_position_past_the_end_is_the_same_non_answer() {
        let (ids, entries) = corpus(&[("a", 7), ("b", ROOT)]);
        assert_eq!(shape(&subagent_tree(&ids, &entries)), [(1, -1)]);
    }

    #[test]
    fn a_self_parented_agent_is_never_entered() {
        let (ids, entries) = corpus(&[("loop", 0), ("root", ROOT)]);
        assert_eq!(shape(&subagent_tree(&ids, &entries)), [(1, -1)]);
    }

    #[test]
    fn a_two_agent_cycle_renders_nothing_and_still_terminates() {
        let (ids, entries) = corpus(&[("a", 1), ("b", 0)]);
        assert!(subagent_tree(&ids, &entries).is_empty());
    }

    #[test]
    fn a_long_cycle_off_a_real_root_still_terminates() {
        let mut rows: Vec<(String, i32)> = vec![("root".to_owned(), ROOT)];
        for step in 1..64_i32 {
            let previous = if step == 1 { 63 } else { step - 1 };
            rows.push((format!("n{step:03}"), previous));
        }
        let borrowed: Vec<(&str, i32)> = rows.iter().map(|(id, parent)| (id.as_str(), *parent)).collect();
        let (ids, entries) = corpus(&borrowed);
        assert_eq!(
            shape(&subagent_tree(&ids, &entries)),
            [(0, -1)],
            "the ring hangs off nothing reachable, so only the real root renders",
        );
    }

    #[test]
    fn every_reachable_agent_appears_exactly_once() {
        let (ids, entries) = corpus(&[("a", ROOT), ("b", 0), ("c", 0), ("d", 1), ("e", 2), ("f", ROOT)]);
        let answer = subagent_tree(&ids, &entries);
        let mut seen: Vec<u32> = answer.iter().map(|slot| slot.position).collect();
        seen.sort_unstable();
        assert_eq!(seen, [0, 1, 2, 3, 4, 5]);
    }

    #[test]
    fn a_parent_always_precedes_its_children_in_the_answer() {
        let (ids, entries) = corpus(&[("m", ROOT), ("z", 0), ("a", 0), ("q", 2), ("b", ROOT), ("p", 4)]);
        let answer = subagent_tree(&ids, &entries);
        for (slot, row) in answer.iter().enumerate() {
            if row.parent_slot == NO_PARENT {
                continue;
            }
            let parent = usize::try_from(row.parent_slot).unwrap_or(usize::MAX);
            assert!(parent < slot, "pre-order: slot {slot}'s parent sits at {parent}");
        }
    }

    #[test]
    fn the_answer_does_not_depend_on_the_order_the_agents_arrived_in() {
        // The same three roots, listed two ways. The ANSWER differs (positions follow the list),
        // but the ids it puts them in do not — which is the property `subagents.values` needs,
        // since a Swift dictionary hands them over in no particular order.
        let forward = corpus(&[("a", ROOT), ("b", ROOT), ("c", ROOT)]);
        let reversed = corpus(&[("c", ROOT), ("b", ROOT), ("a", ROOT)]);
        assert_eq!(shape(&subagent_tree(&forward.0, &forward.1)), [
            (0, -1),
            (1, -1),
            (2, -1)
        ]);
        assert_eq!(shape(&subagent_tree(&reversed.0, &reversed.1)), [
            (2, -1),
            (1, -1),
            (0, -1)
        ]);
    }

    #[test]
    fn the_empty_state_gate_opens_on_any_one_of_its_five_reasons() {
        assert!(!has_renderable_activity(false, false, false, false, 0));
        assert!(has_renderable_activity(true, false, false, false, 0));
        assert!(has_renderable_activity(false, true, false, false, 0));
        assert!(has_renderable_activity(false, false, true, false, 0));
        assert!(has_renderable_activity(false, false, false, true, 0));
        assert!(has_renderable_activity(false, false, false, false, 1));
    }

    #[test]
    fn a_stored_message_alone_does_not_open_the_gate() {
        // Messages have no argument here AT ALL, which is the point: the gate cannot be opened by
        // something the panel does not draw.
        assert!(!has_renderable_activity(false, false, false, false, 0));
    }

    #[test]
    fn every_ring_evicts_only_past_its_ceiling_and_lands_on_its_retained_mark() {
        for ring in Ring::ALL {
            let ceiling = ring.ceiling();
            assert!(ceiling > 0, "zero is the refusal, never a member");
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
    fn every_ring_byte_round_trips_and_no_other_byte_names_one() {
        for ring in Ring::ALL {
            assert_eq!(Ring::from_code(ring.code()), Some(ring));
            assert_eq!(ring_ceiling(ring.code()), ring.ceiling());
            assert_eq!(
                ring_overflow(ring.code(), ring.ceiling() + 1),
                ring.overflow(ring.ceiling() + 1)
            );
        }
        for code in 0..=u8::MAX {
            let named = Ring::from_code(code).is_some();
            assert_eq!(named, usize::from(code) < Ring::ALL.len(), "byte {code}");
        }
    }

    #[test]
    fn an_unnamed_ring_refuses_rather_than_evicting() {
        let unnamed = u8::try_from(Ring::ALL.len()).unwrap_or(u8::MAX);
        assert_eq!(ring_ceiling(unnamed), 0);
        assert_eq!(
            ring_overflow(unnamed, 1_000_000),
            0,
            "an unnamed ring cannot lose an entry"
        );
        assert_eq!(ring_ceiling(u8::MAX), 0);
        assert_eq!(ring_overflow(u8::MAX, usize::MAX), 0);
    }
}
