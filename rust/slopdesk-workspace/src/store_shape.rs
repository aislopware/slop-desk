//! The workspace store's SHAPE rules: what one gesture moved, and what one launch asks for.
//!
//! Everything here is a question the store asks BETWEEN two things it already holds — two snapshots
//! of the same tree, a set of launch variables and the workspace they describe, a connection target
//! and the port beside it. None of them mutates anything: the answer is a position, an index or a
//! small record, and the caller does the writing.
//!
//! ## No identity crosses
//!
//! A split, a pane, a tab and a session are all UUIDs on the near side, and none of them appears
//! here. The rules take a caller-minted `u32` TOKEN per distinct identity — one table spanning both
//! snapshots, so "the same split" and "the same pane" are decidable — and answer POSITIONS into the
//! list they were handed. The near side maps those back. This is [`crate::pane_facts`]'s convention
//! applied to a correlation rather than to a queue.
//!
//! ## A split's children arrive as a RUN
//!
//! [`WeightSlot`] carries no child index. The slots arrive in the tree's own pre-order, and one
//! split's children are the maximal RUN of slots sharing its token — which is exactly the shape
//! `children.map { … }` produced on the near side, and the reason two rules that both read weights
//! can disagree about a repeated token without either of them being wrong (see
//! [`leading_weight`] and [`changed_divider_weight`]).

use std::collections::BTreeMap;

use slopdesk_ids::{PaneId, SessionId, TabId};
use slopdesk_tree::{Session, SplitNode, Tab, TreeWorkspace, tree_ops};

// ---------------------------------------------------------------------------------------------- //
// Divider weights
// ---------------------------------------------------------------------------------------------- //

/// One CHILD slot of one split, flattened out of a tab's tree in pre-order.
///
/// `weight` means nothing unless `is_flex`: a FIXED child has a size in points rather than a share,
/// and no divider drag can move it. The two are carried apart rather than as a sentinel weight
/// because a fixed child and a zero-weight flex child are different answers to "did this move".
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeightSlot {
    /// The child's flex share of its parent's axis.
    pub weight: f64,
    /// The caller's token for the ENCLOSING split's identity.
    pub split: u32,
    /// Whether the child is flex at all.
    pub is_flex: bool,
}

impl WeightSlot {
    /// A flex child at a share.
    #[must_use]
    pub const fn flex(split: u32, weight: f64) -> Self {
        Self {
            weight,
            split,
            is_flex: true,
        }
    }

    /// A fixed child, which has no share to move.
    #[must_use]
    pub const fn fixed(split: u32) -> Self {
        Self {
            weight: 0.0,
            split,
            is_flex: false,
        }
    }

    /// The share as the near side wrote it: `None` for a fixed child.
    ///
    /// The comparison the change rule makes is on THIS value, so a child that stopped being flex
    /// reads as changed, and two NaN shares read as changed as well — which is what the near side's
    /// `Double?` comparison did, and is left alone deliberately.
    #[must_use]
    const fn share(self) -> Option<f64> {
        if self.is_flex { Some(self.weight) } else { None }
    }
}

/// One split's children within a flattened tree: its token, where its run starts, how long it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Group {
    split: u32,
    start: usize,
    len: usize,
}

/// The runs `slots` falls into: one per split, in the order the near side emitted them.
fn groups(slots: &[WeightSlot]) -> Vec<Group> {
    let mut out: Vec<Group> = Vec::new();
    for (index, slot) in slots.iter().enumerate() {
        match out.last_mut() {
            Some(group) if group.split == slot.split => group.len += 1,
            _ => {
                out.push(Group {
                    split: slot.split,
                    start: index,
                    len: 1,
                });
            },
        }
    }
    out
}

/// The FLEX share of `split`'s child at `index`, or `None` when that seam is absent or fixed.
///
/// What the divider ops read back after the pure op has clamped. The answer is the FIRST run
/// carrying `split` that has a flex child at `index`: a run that carries the token but is too
/// short, or whose child at `index` is fixed, does not end the search — the near side's recursion
/// kept walking past it into the subtree, and so does this.
#[must_use]
pub fn leading_weight(slots: &[WeightSlot], split: u32, index: usize) -> Option<f64> {
    groups(slots)
        .into_iter()
        .filter(|group| group.split == split && index < group.len)
        .find_map(|group| {
            let slot = slots.get(group.start.checked_add(index)?)?;
            slot.is_flex.then_some(slot.weight)
        })
}

/// The one `splitNode/weight` a structural resize moved.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeightChange {
    /// Its new flex share.
    pub weight: f64,
    /// The caller's token for the split that holds it.
    pub split: u32,
    /// Which of that split's children moved.
    pub index: usize,
}

/// The one weight that differs between two flattenings of the same trees, or `None` when nothing
/// moved.
///
/// Three refusals, each the near side's own. A split whose child COUNT changed is skipped whole —
/// that is a structural edit, not a drag, and pairing its children by position would be inventing a
/// correspondence. A split present only in `after` is skipped for the same reason. And a child that
/// stopped being flex counts as different but is not an answer, so the scan carries on to the later
/// indices of the same split.
///
/// One divergence from the Swift this replaced, and it is the point of porting it: that version
/// walked a `Dictionary`, so a resize that moved two weights answered an ARBITRARY one of them.
/// This answers the first in emission order. The only caller moves exactly one split per gesture,
/// so no shipped behaviour changes — but the answer is now the same twice.
///
/// A repeated split token resolves to its LAST run, because the near side keyed a dictionary by it
/// and the later write won. [`leading_weight`] resolves the same collision to the FIRST run,
/// because the near side searched rather than indexed. Both are faithful; a tree with a repeated
/// split id is corrupt either way.
#[must_use]
pub fn changed_divider_weight(before: &[WeightSlot], after: &[WeightSlot]) -> Option<WeightChange> {
    let previous = groups(before);
    let next = groups(after);
    for (position, group) in next.iter().enumerate() {
        if next
            .iter()
            .skip(position.saturating_add(1))
            .any(|later| later.split == group.split)
        {
            continue;
        }
        let Some(was) = previous.iter().rev().find(|old| old.split == group.split) else {
            continue;
        };
        if was.len != group.len {
            continue;
        }
        for index in 0..group.len {
            let (Some(old), Some(new)) = (
                index.checked_add(was.start).and_then(|at| before.get(at)),
                index.checked_add(group.start).and_then(|at| after.get(at)),
            ) else {
                continue;
            };
            if old.share() == new.share() || !new.is_flex {
                continue;
            }
            return Some(WeightChange {
                weight: new.weight,
                split: group.split,
                index,
            });
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------- //
// The swap partner
// ---------------------------------------------------------------------------------------------- //

/// Which pane traded places with `active`, as a POSITION into `after`.
///
/// A directional move is a SWAP, so whoever now stands where `active` stood is the partner — and
/// every other outcome is refused rather than guessed at. `before` and `after` are one tab's leaves
/// in pre-order, tokenised against one table; the near side has already established that they are
/// the same tab, which is an identity comparison and stays where the identities are.
///
/// The refusals, in order: `active` must be in both orders, it must actually have moved, its old
/// position must still exist, the pane now standing there must not be `active` itself, the leaf
/// count must be unchanged, and the pane `active` displaced must be the same one. Anything else
/// means the op did something other than a swap.
#[must_use]
pub fn swap_partner(before: &[u32], after: &[u32], active: u32) -> Option<usize> {
    let from = before.iter().position(|pane| *pane == active)?;
    let to = after.iter().position(|pane| *pane == active)?;
    if from == to {
        return None;
    }
    let partner = *after.get(from)?;
    if partner == active || before.len() != after.len() || *before.get(to)? != partner {
        return None;
    }
    Some(from)
}

// ---------------------------------------------------------------------------------------------- //
// The launch bootstrap
// ---------------------------------------------------------------------------------------------- //

/// The prefix a launch argument must carry to stand in for an environment variable.
pub const AUTOMATION_PREFIX: &str = "SLOPDESK_";

/// Where the `=` falls in a launch argument that overrides an environment variable, or `None`.
///
/// A GUI-session launch cannot always inject env — `open --args …` over SSH has no way to set the
/// child's environment without root — so the same `SLOPDESK_…=value` tokens are accepted as launch
/// arguments. The offset is in BYTES and always lands on a `=`, so both halves either side of it
/// are whole UTF-8.
///
/// An argument with the prefix and no `=` is not an override, and neither is one that only starts
/// with `SLOPDESK_` after some other text. An argument spelled exactly `SLOPDESK_=value` IS one,
/// with an empty-tailed key — the near side stored it under that key before and still does, because
/// a rule that quietly dropped it would be a launch flag that does nothing and says nothing.
#[must_use]
pub fn automation_override(argument: &str) -> Option<usize> {
    if !argument.starts_with(AUTOMATION_PREFIX) {
        return None;
    }
    argument.find('=')
}

/// The port a `SLOPDESK_*_PORT` variable names, or `None` when it names none.
///
/// Total over hostile input by construction: anything that is not a bare decimal in `0..=65535` is
/// refused rather than clamped, because a launch flag that meant to say 70000 and got 4464 is worse
/// than one that did nothing.
#[must_use]
pub fn parse_port(text: &str) -> Option<u16> {
    text.parse::<u16>().ok()
}

/// Whether the terminal autoconnect variables describe a target, and which port it is.
///
/// Both halves are required and the host must be non-empty: a host variable set to nothing is
/// somebody's shell expanding an unset variable, not a request to dial the empty string.
#[must_use]
pub fn terminal_target(host: &str, port: &str) -> Option<u16> {
    if host.is_empty() {
        return None;
    }
    parse_port(port)
}

/// Which shape a launch asks the store to mount.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapKind {
    /// Neither autoconnect set: the plain default single-terminal workspace.
    Default,
    /// The terminal autoconnect: one terminal named for the host, riding the app connection.
    Terminal,
    /// The video autoconnect: the same lone terminal, plus a DETACHED desktop pane that never
    /// enters the tree.
    Video,
}

impl BootstrapKind {
    /// Every kind, in discriminant order.
    pub const ALL: [Self; 3] = [Self::Default, Self::Terminal, Self::Video];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Default => 0,
            Self::Terminal => 1,
            Self::Video => 2,
        }
    }

    /// The kind a set of automation inputs describes.
    ///
    /// Video takes precedence, and it is the whole rule: the video automation serves ONE host
    /// window and sets the terminal variables too, so reading them in the other order would
    /// mount a terminal for a launch that asked for a desktop.
    #[must_use]
    pub const fn resolve(has_video: bool, has_terminal: bool) -> Self {
        if has_video {
            Self::Video
        } else if has_terminal {
            Self::Terminal
        } else {
            Self::Default
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// The inspector's port
// ---------------------------------------------------------------------------------------------- //

/// How far above the terminal port the inspector listens.
///
/// One spelling, on this side of the boundary, because the offset and the arithmetic that applies
/// it are the same decision: a near side that held the constant and asked for the sum would be the
/// two-languages drift written across one line.
const INSPECTOR_PORT_OFFSET: u16 = 1;

/// The inspector port beside a terminal port, or `None` when there is no room above it.
///
/// A terminal on the top port has no inspector rather than an inspector on port 0 — the wrap is the
/// one case where the convention cannot be honoured, so it refuses instead of answering somewhere
/// else.
#[must_use]
pub const fn inspector_port(terminal: u16) -> Option<u16> {
    terminal.checked_add(INSPECTOR_PORT_OFFSET)
}

// ---------------------------------------------------------------------------------------------- //
// The named viewport scrolls
// ---------------------------------------------------------------------------------------------- //

/// The four viewport scrolls the named scroll keys bind to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollAction {
    /// ⇧`PageUp` — one page toward OLDER scrollback.
    PageUp,
    /// ⇧`PageDown` — one page toward NEWER output.
    PageDown,
    /// ⇧Home — the very top of the scrollback.
    Top,
    /// ⇧End — the very bottom, the newest output.
    Bottom,
}

impl ScrollAction {
    /// Every action, in discriminant order.
    pub const ALL: [Self; 4] = [Self::PageUp, Self::PageDown, Self::Top, Self::Bottom];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::PageUp => 0,
            Self::PageDown => 1,
            Self::Top => 2,
            Self::Bottom => 3,
        }
    }

    /// The action a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::PageUp),
            1 => Some(Self::PageDown),
            2 => Some(Self::Top),
            3 => Some(Self::Bottom),
            _ => None,
        }
    }

    /// The libghostty named binding action this scroll fires.
    ///
    /// Two conventions live in these four strings and neither is negotiable. The SIGN is
    /// libghostty's: negative is up, toward older scrollback. The FRACTION is a page minus a sliver
    /// of overlap, so a reader keeps a line of context across the jump — deliberately not copy
    /// mode's half page, which is a different gesture with a different key.
    #[must_use]
    pub const fn libghostty_action(self) -> &'static str {
        match self {
            Self::PageUp => "scroll_page_fractional:-0.9",
            Self::PageDown => "scroll_page_fractional:0.9",
            Self::Top => "scroll_to_top",
            Self::Bottom => "scroll_to_bottom",
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// The device-focus overlay
// ---------------------------------------------------------------------------------------------- //

/// One tab of the projection, as the device-focus overlay needs to see it.
///
/// Four facts and no identities. `session` is the caller's token for the owning session, and the
/// tabs arrive in session order, so one session's tabs are a maximal RUN — the same shape
/// [`WeightSlot`] uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FocusTab {
    /// The caller's token for the session this tab belongs to.
    pub session: u32,
    /// Whether the focused pane is a leaf of this tab.
    pub holds_pane: bool,
    /// Whether this is the tab the overlay names.
    pub is_focus_tab: bool,
    /// Whether this tab's zoom is showing the focused pane itself.
    pub zoom_is_target: bool,
}

/// Where a device-focus overlay lands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FocusLanding {
    /// Which tab of the list handed in, as a position.
    pub tab: usize,
    /// Whether the overlay also names the tab's active pane. `false` for a plain tab switch, which
    /// leaves the tab's host-owned active pane showing.
    pub focuses_pane: bool,
    /// Whether the landing tab's zoom collapses. Only ever `true` alongside `focuses_pane`.
    pub clears_zoom: bool,
}

/// A synthetic id in a namespace of its own, so a skeleton's ids cannot collide across kinds.
const fn synthetic(tag: u8, index: u32) -> [u8; 16] {
    let mut bytes = [0_u8; 16];
    bytes[0] = tag;
    let raw = index.to_le_bytes();
    bytes[1] = raw[0];
    bytes[2] = raw[1];
    bytes[3] = raw[2];
    bytes[4] = raw[3];
    bytes
}

/// The pane the overlay is looking for, inside the skeleton.
const fn target_pane() -> PaneId {
    PaneId::from_bytes(synthetic(1, 0))
}

/// A SKELETON of the projection: one leaf per tab, carrying only what focus reads.
///
/// The tree SHAPE is irrelevant to focus semantics — [`tree_ops::focus_pane`] reads which tab holds
/// the pane, that tab's zoom and nothing else — so the skeleton is the smallest tree that can carry
/// those facts, and the real rule runs on it. The alternative is a second spelling of the zoom-exit
/// rule on this side of the boundary, which is exactly what the port exists to remove.
fn skeleton(tabs: &[FocusTab]) -> TreeWorkspace {
    let mut sessions: Vec<Session> = Vec::new();
    for (index, row) in tabs.iter().enumerate() {
        let pane = if row.holds_pane {
            target_pane()
        } else {
            PaneId::from_bytes(synthetic(2, u32::try_from(index).unwrap_or(u32::MAX)))
        };
        let mut tab = Tab::new(
            TabId::from_bytes(synthetic(3, u32::try_from(index).unwrap_or(u32::MAX))),
            SplitNode::Leaf(pane),
        );
        if row.zoom_is_target {
            tab.zoomed_pane = Some(target_pane());
        }
        match sessions.last_mut() {
            Some(session) if session.id == SessionId::from_bytes(synthetic(4, row.session)) => {
                session.tabs.push(tab);
            },
            _ => {
                sessions.push(Session {
                    id: SessionId::from_bytes(synthetic(4, row.session)),
                    name: String::new(),
                    tabs: vec![tab],
                    active_tab_index: 0,
                    specs: BTreeMap::new(),
                    detached: Vec::new(),
                });
            },
        }
    }
    TreeWorkspace::new(sessions, None)
}

/// Where a device's own focus overlay lands on the projection, or `None` when it no longer
/// resolves.
///
/// The pane branch is [`tree_ops::focus_pane`]'s, run on a skeleton of the tabs handed in, so an
/// unfollowing device sees precisely what a following one would have — including the rule that
/// focus never lands on a pane the zoom is hiding. The tab branch is a plain lookup and
/// deliberately does NOT go through it: naming a tab leaves that tab's own active pane and zoom
/// alone.
///
/// Resolution is against the list every time. A tab or pane another client closed simply stops
/// resolving and host truth shows through, which is what keeps a device off a blank view.
#[must_use]
pub fn device_focus_landing(tabs: &[FocusTab], has_pane: bool) -> Option<FocusLanding> {
    if has_pane && tabs.iter().any(|row| row.holds_pane) {
        let next = tree_ops::focus_pane(&skeleton(tabs), target_pane());
        let active = next.active_session_id?;
        let mut flat = 0_usize;
        for session in &next.sessions {
            if session.id == active {
                let tab = session.tabs.get(session.active_tab_index)?;
                return Some(FocusLanding {
                    tab: flat.checked_add(session.active_tab_index)?,
                    focuses_pane: true,
                    clears_zoom: tab.zoomed_pane.is_none(),
                });
            }
            flat = flat.checked_add(session.tabs.len())?;
        }
        return None;
    }
    Some(FocusLanding {
        tab: tabs.iter().position(|row| row.is_focus_tab)?,
        focuses_pane: false,
        clears_zoom: false,
    })
}

// ---------------------------------------------------------------------------------------------- //
// Tests
// ---------------------------------------------------------------------------------------------- //

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::*;

    // -- leading_weight -------------------------------------------------------------------------

    #[test]
    fn a_leading_weight_reads_the_child_at_the_index() {
        let slots = [WeightSlot::flex(7, 0.25), WeightSlot::flex(7, 0.75)];
        assert_eq!(leading_weight(&slots, 7, 0), Some(0.25));
        assert_eq!(leading_weight(&slots, 7, 1), Some(0.75));
    }

    #[test]
    fn an_absent_split_has_no_leading_weight() {
        let slots = [WeightSlot::flex(7, 0.5), WeightSlot::flex(7, 0.5)];
        assert_eq!(leading_weight(&slots, 8, 0), None);
    }

    #[test]
    fn an_index_past_the_children_has_no_leading_weight() {
        let slots = [WeightSlot::flex(7, 0.5), WeightSlot::flex(7, 0.5)];
        assert_eq!(leading_weight(&slots, 7, 2), None);
    }

    #[test]
    fn a_fixed_child_has_no_leading_weight() {
        let slots = [WeightSlot::fixed(7), WeightSlot::flex(7, 0.5)];
        assert_eq!(leading_weight(&slots, 7, 0), None);
        assert_eq!(leading_weight(&slots, 7, 1), Some(0.5));
    }

    #[test]
    fn a_short_run_does_not_end_the_search_for_a_repeated_split() {
        // The near side recursed past a matching id whose index was out of range; so does this.
        let slots = [
            WeightSlot::flex(7, 0.1),
            WeightSlot::flex(9, 0.9),
            WeightSlot::flex(7, 0.2),
            WeightSlot::flex(7, 0.3),
        ];
        assert_eq!(leading_weight(&slots, 7, 1), Some(0.3));
    }

    #[test]
    fn leading_weight_over_nothing_is_none() {
        assert_eq!(leading_weight(&[], 0, 0), None);
    }

    // -- changed_divider_weight -----------------------------------------------------------------

    #[test]
    fn b_the_one_moved_weight_is_the_answer() {
        let before = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        let after = [WeightSlot::flex(4, 0.3), WeightSlot::flex(4, 0.7)];
        let change = changed_divider_weight(&before, &after).expect("a weight moved");
        assert_eq!(change.split, 4);
        assert_eq!(change.index, 0);
        assert!((change.weight - 0.3).abs() < f64::EPSILON);
    }

    #[test]
    fn an_unmoved_tree_answers_nothing() {
        let slots = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        assert_eq!(changed_divider_weight(&slots, &slots), None);
    }

    #[test]
    fn a_split_whose_child_count_changed_is_skipped_whole() {
        let before = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        let after = [
            WeightSlot::flex(4, 0.3),
            WeightSlot::flex(4, 0.3),
            WeightSlot::flex(4, 0.4),
        ];
        assert_eq!(changed_divider_weight(&before, &after), None);
    }

    #[test]
    fn a_split_only_in_after_is_skipped() {
        let before = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        let after = [WeightSlot::flex(5, 0.3), WeightSlot::flex(5, 0.7)];
        assert_eq!(changed_divider_weight(&before, &after), None);
    }

    #[test]
    fn a_child_that_stopped_being_flex_is_not_an_answer_and_does_not_stop_the_scan() {
        let before = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        let after = [WeightSlot::fixed(4), WeightSlot::flex(4, 0.8)];
        let change = changed_divider_weight(&before, &after).expect("index 1 still moved");
        assert_eq!(change.index, 1);
        assert!((change.weight - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn a_child_that_became_flex_is_the_answer() {
        let before = [WeightSlot::fixed(4), WeightSlot::flex(4, 0.5)];
        let after = [WeightSlot::flex(4, 0.5), WeightSlot::flex(4, 0.5)];
        let change = changed_divider_weight(&before, &after).expect("index 0 became flex");
        assert_eq!(change.index, 0);
    }

    #[test]
    fn two_moved_weights_answer_the_first_in_emission_order() {
        let before = [
            WeightSlot::flex(1, 0.5),
            WeightSlot::flex(1, 0.5),
            WeightSlot::flex(2, 0.5),
            WeightSlot::flex(2, 0.5),
        ];
        let after = [
            WeightSlot::flex(1, 0.4),
            WeightSlot::flex(1, 0.6),
            WeightSlot::flex(2, 0.2),
            WeightSlot::flex(2, 0.8),
        ];
        let change = changed_divider_weight(&before, &after).expect("something moved");
        assert_eq!(change.split, 1);
        assert_eq!(change.index, 0);
    }

    #[test]
    fn a_nan_share_reads_as_moved_on_both_sides() {
        let before = [WeightSlot::flex(4, f64::NAN), WeightSlot::flex(4, 0.5)];
        let after = [WeightSlot::flex(4, f64::NAN), WeightSlot::flex(4, 0.5)];
        let change = changed_divider_weight(&before, &after).expect("NaN never equals itself");
        assert_eq!(change.index, 0);
        assert!(change.weight.is_nan());
    }

    #[test]
    fn a_repeated_split_token_resolves_to_its_last_run() {
        // The near side keyed a dictionary, so the later write won. The FIRST run moved and the
        // LAST did not: the dictionary never saw the first, and neither does this.
        let before = [
            WeightSlot::flex(4, 0.5),
            WeightSlot::flex(4, 0.5),
            WeightSlot::flex(9, 1.0),
            WeightSlot::flex(4, 0.25),
            WeightSlot::flex(4, 0.75),
        ];
        let after = [
            WeightSlot::flex(4, 0.1),
            WeightSlot::flex(4, 0.9),
            WeightSlot::flex(9, 1.0),
            WeightSlot::flex(4, 0.25),
            WeightSlot::flex(4, 0.75),
        ];
        assert_eq!(changed_divider_weight(&before, &after), None);
    }

    #[test]
    fn changed_divider_weight_over_nothing_is_none() {
        assert_eq!(changed_divider_weight(&[], &[]), None);
    }

    // -- swap_partner ---------------------------------------------------------------------------

    #[test]
    fn c_a_swap_answers_the_pane_that_took_the_old_place() {
        assert_eq!(swap_partner(&[10, 20, 30], &[20, 10, 30], 10), Some(0));
        assert_eq!(swap_partner(&[10, 20, 30], &[30, 20, 10], 10), Some(0));
    }

    #[test]
    fn an_unmoved_pane_has_no_partner() {
        assert_eq!(swap_partner(&[10, 20], &[10, 20], 10), None);
    }

    #[test]
    fn a_pane_missing_from_either_order_has_no_partner() {
        assert_eq!(swap_partner(&[20, 30], &[30, 20], 10), None);
        assert_eq!(swap_partner(&[10, 20], &[20, 30], 10), None);
    }

    #[test]
    fn a_rotation_is_not_a_swap() {
        // 10 moved from 0 to 2, but the pane now at 0 did not come from 2.
        assert_eq!(swap_partner(&[10, 20, 30], &[20, 30, 10], 10), None);
    }

    #[test]
    fn a_changed_leaf_count_is_not_a_swap() {
        assert_eq!(swap_partner(&[10, 20, 30], &[20, 10], 10), None);
    }

    #[test]
    fn a_pane_that_moved_past_the_end_has_no_partner() {
        assert_eq!(swap_partner(&[10, 20, 30], &[20], 10), None);
    }

    #[test]
    fn swap_partner_over_nothing_is_none() {
        assert_eq!(swap_partner(&[], &[], 0), None);
    }

    // -- the launch bootstrap -------------------------------------------------------------------

    #[test]
    fn d_an_override_argument_splits_at_its_first_equals() {
        assert_eq!(
            automation_override("SLOPDESK_AUTOCONNECT_HOST=10.0.0.2"),
            Some(25)
        );
        assert_eq!(automation_override("SLOPDESK_A=b=c"), Some(10));
    }

    #[test]
    fn an_argument_without_the_prefix_is_not_an_override() {
        assert_eq!(automation_override("PATH=/usr/bin"), None);
        assert_eq!(automation_override("-SLOPDESK_A=b"), None);
    }

    #[test]
    fn an_argument_without_an_equals_is_not_an_override() {
        assert_eq!(automation_override("SLOPDESK_AUTOCONNECT_HOST"), None);
        assert_eq!(automation_override(""), None);
    }

    #[test]
    fn an_empty_key_is_still_an_override() {
        assert_eq!(automation_override("SLOPDESK_=value"), Some(9));
    }

    #[test]
    fn an_override_offset_lands_on_a_character_boundary() {
        let argument = "SLOPDESK_TITLE=café";
        let at = automation_override(argument).expect("an override");
        assert!(argument.is_char_boundary(at));
        assert_eq!(argument.get(at.saturating_add(1)..), Some("café"));
    }

    #[test]
    fn a_port_is_a_bare_decimal_in_range() {
        assert_eq!(parse_port("7420"), Some(7420));
        assert_eq!(parse_port("0"), Some(0));
        assert_eq!(parse_port("65535"), Some(65535));
    }

    #[test]
    fn a_port_out_of_range_or_out_of_shape_is_refused() {
        assert_eq!(parse_port("65536"), None);
        assert_eq!(parse_port("-1"), None);
        assert_eq!(parse_port(""), None);
        assert_eq!(parse_port(" 7420"), None);
        assert_eq!(parse_port("7420 "), None);
        assert_eq!(parse_port("74a20"), None);
    }

    #[test]
    fn a_terminal_target_needs_a_host_and_a_port() {
        assert_eq!(terminal_target("10.0.0.2", "7420"), Some(7420));
        assert_eq!(terminal_target("", "7420"), None);
        assert_eq!(terminal_target("10.0.0.2", ""), None);
        assert_eq!(terminal_target("10.0.0.2", "nope"), None);
    }

    #[test]
    fn video_takes_precedence_over_the_terminal_autoconnect() {
        assert_eq!(BootstrapKind::resolve(true, true), BootstrapKind::Video);
        assert_eq!(BootstrapKind::resolve(true, false), BootstrapKind::Video);
        assert_eq!(BootstrapKind::resolve(false, true), BootstrapKind::Terminal);
        assert_eq!(BootstrapKind::resolve(false, false), BootstrapKind::Default);
    }

    #[test]
    fn every_bootstrap_kind_has_its_own_code() {
        let codes: Vec<u8> = BootstrapKind::ALL.iter().map(|kind| kind.code()).collect();
        assert_eq!(codes, vec![0, 1, 2]);
    }

    // -- the inspector's port -------------------------------------------------------------------

    #[test]
    fn e_the_inspector_listens_one_above_the_terminal() {
        assert_eq!(inspector_port(7420), Some(7421));
        assert_eq!(inspector_port(0), Some(1));
    }

    #[test]
    fn a_terminal_on_the_top_port_has_no_inspector() {
        assert_eq!(inspector_port(u16::MAX), None);
    }

    // -- the named scrolls ----------------------------------------------------------------------

    #[test]
    fn f_every_scroll_action_names_its_libghostty_binding() {
        assert_eq!(
            ScrollAction::PageUp.libghostty_action(),
            "scroll_page_fractional:-0.9"
        );
        assert_eq!(
            ScrollAction::PageDown.libghostty_action(),
            "scroll_page_fractional:0.9"
        );
        assert_eq!(ScrollAction::Top.libghostty_action(), "scroll_to_top");
        assert_eq!(ScrollAction::Bottom.libghostty_action(), "scroll_to_bottom");
    }

    #[test]
    fn the_page_scrolls_are_a_signed_pair_of_the_same_fraction() {
        // Negative is UP, and the two directions must move the same distance.
        let up = ScrollAction::PageUp.libghostty_action();
        let down = ScrollAction::PageDown.libghostty_action();
        assert_eq!(up.replace(":-", ":"), down);
    }

    #[test]
    fn every_scroll_action_round_trips_through_its_code() {
        for action in ScrollAction::ALL {
            assert_eq!(ScrollAction::from_code(action.code()), Some(action));
        }
        let codes: Vec<u8> = ScrollAction::ALL.iter().map(|action| action.code()).collect();
        assert_eq!(codes, vec![0, 1, 2, 3]);
    }

    #[test]
    fn a_code_this_build_does_not_know_names_no_scroll() {
        assert_eq!(ScrollAction::from_code(4), None);
        assert_eq!(ScrollAction::from_code(u8::MAX), None);
    }

    // -- the device-focus overlay ---------------------------------------------------------------

    const fn tab(session: u32, holds_pane: bool, is_focus_tab: bool, zoom_is_target: bool) -> FocusTab {
        FocusTab {
            session,
            holds_pane,
            is_focus_tab,
            zoom_is_target,
        }
    }

    #[test]
    fn g_a_pane_focus_lands_on_the_tab_that_holds_it() {
        let tabs = [tab(0, false, false, false), tab(1, true, false, false)];
        let landing = device_focus_landing(&tabs, true).expect("the pane resolves");
        assert_eq!(landing.tab, 1);
        assert!(landing.focuses_pane);
        assert!(landing.clears_zoom);
    }

    #[test]
    fn a_zoom_showing_the_focused_pane_survives() {
        let tabs = [tab(0, true, false, true)];
        let landing = device_focus_landing(&tabs, true).expect("the pane resolves");
        assert_eq!(landing.tab, 0);
        assert!(landing.focuses_pane);
        assert!(!landing.clears_zoom);
    }

    #[test]
    fn a_zoom_showing_another_pane_collapses() {
        let tabs = [tab(0, true, false, false)];
        let landing = device_focus_landing(&tabs, true).expect("the pane resolves");
        assert!(landing.clears_zoom);
    }

    #[test]
    fn a_pane_that_no_longer_exists_falls_back_to_the_tab() {
        let tabs = [tab(0, false, false, false), tab(0, false, true, false)];
        let landing = device_focus_landing(&tabs, true).expect("the tab resolves");
        assert_eq!(landing.tab, 1);
        assert!(!landing.focuses_pane);
        assert!(!landing.clears_zoom);
    }

    #[test]
    fn a_tab_focus_never_names_a_pane() {
        let tabs = [tab(0, true, false, false), tab(0, false, true, false)];
        let landing = device_focus_landing(&tabs, false).expect("the tab resolves");
        assert_eq!(landing.tab, 1);
        assert!(!landing.focuses_pane);
    }

    #[test]
    fn a_focus_that_resolves_to_nothing_is_refused() {
        let tabs = [tab(0, false, false, false)];
        assert_eq!(device_focus_landing(&tabs, true), None);
        assert_eq!(device_focus_landing(&tabs, false), None);
        assert_eq!(device_focus_landing(&[], true), None);
    }

    #[test]
    fn a_landing_position_counts_across_sessions() {
        let tabs = [
            tab(0, false, false, false),
            tab(0, false, false, false),
            tab(1, false, false, false),
            tab(1, true, false, false),
        ];
        let landing = device_focus_landing(&tabs, true).expect("the pane resolves");
        assert_eq!(landing.tab, 3);
    }

    #[test]
    fn the_first_tab_holding_the_pane_wins() {
        let tabs = [tab(0, true, false, false), tab(1, true, false, false)];
        let landing = device_focus_landing(&tabs, true).expect("the pane resolves");
        assert_eq!(landing.tab, 0);
    }
}
