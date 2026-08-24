//! The one register a pane drop is announced in — its wording and its mark.
//!
//! Two chips say what a release would do, and they are the same chip: the canvas overlay's ghost
//! chip pinned to the cursor inside the compositor, and the borderless panel that takes over the
//! moment the cursor leaves the content column's hosting view (which clips the overlay). Both were
//! documented as "the same capsule voice — one drop vocabulary", and both spelled that vocabulary
//! out for themselves. Two switches for one register is one place for the words to drift, and it
//! drifts SILENTLY — the two chips are never on screen at the same instant, so nobody can see them
//! disagree.
//!
//! ## It answers over BOTH vocabularies on purpose
//!
//! The cross-container [`Destination`] is the superset and the in-canvas [`Zone`] its half, and the
//! two chips genuinely ask different questions: over the canvas the answer names the ZONE ("swap
//! main", "split left"), and off it the answer names the CONTAINER the pane is going to ("move
//! beside api", "new window"). Folding those into one vocabulary would have been a translation
//! layer pretending to be a decision.
//!
//! ## The mark is SEMANTIC, never an `SFSymbol`
//!
//! The reading floor names no artwork, so the register answers with a [`Mark`] and each drawing
//! maps it to its own image type in exactly one place. The alternative was a dependency edge bought
//! to carry five glyph names.

use slopdesk_tree::split_tree::{PaneDropEdge, SplitAxis};

/// What a drop chip's glyph MEANS.
///
/// Named for the outcome rather than for any icon set's spelling of it, so a renderer maps it once
/// and neither half can grow an eighth mark on its own.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mark {
    /// Releasing here commits nothing.
    Cancel,
    /// The two panes exchange places.
    Swap,
    /// The drop forms COLUMNS — a horizontal split, panes side by side.
    SplitColumns,
    /// The drop forms ROWS — a vertical split, panes stacked.
    SplitRows,
    /// The pane lands beside another pane's row, in that row's tab.
    Beside,
    /// The pane becomes a tab of its own.
    NewTab,
    /// The pane becomes a window of its own.
    NewWindow,
}

impl Mark {
    /// The discriminant a renderer maps to its own image type.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Cancel => 0,
            Self::Swap => 1,
            Self::SplitColumns => 2,
            Self::SplitRows => 3,
            Self::Beside => 4,
            Self::NewTab => 5,
            Self::NewWindow => 6,
        }
    }
}

/// The name a chip falls back to when the dragged pane has no title worth printing.
///
/// A pane always has SOMETHING to be called, and "pane" reads better than an empty gap in the
/// middle of a verb phrase.
pub const ANONYMOUS_PANE_NAME: &str = "pane";

/// What a release inside ONE tab's canvas would commit.
///
/// The pane identities the near side's own vocabulary carries are not here: the chip says what
/// happens, and *which* pane it happens to arrives as the title beside it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Zone {
    /// A cancel — release commits nothing.
    None,
    /// The two panes exchange positions.
    Swap,
    /// The dragged pane becomes a new column/row beside the target.
    Resplit(PaneDropEdge),
    /// The dragged pane docks to that whole edge of the container.
    Dock(PaneDropEdge),
}

impl Zone {
    /// The zone a `(kind, edge)` pair names — the shape the near side's enum crosses as.
    ///
    /// `1` swap, `2` re-split, `3` dock; anything else is the cancel, because a zone byte nobody
    /// recognises must commit nothing rather than guess an op.
    #[must_use]
    pub const fn from_parts(kind: u8, edge: u8) -> Self {
        match kind {
            1 => Self::Swap,
            2 => Self::Resplit(PaneDropEdge::from_byte(edge)),
            3 => Self::Dock(PaneDropEdge::from_byte(edge)),
            _ => Self::None,
        }
    }

    /// The chip's mark.
    ///
    /// A re-split and a dock draw the same split silhouette — what differs between them is the SIZE
    /// of the preview underneath, not the shape of the outcome.
    #[must_use]
    pub const fn mark(self) -> Mark {
        match self {
            Self::None => Mark::Cancel,
            Self::Swap => Mark::Swap,
            Self::Resplit(edge) | Self::Dock(edge) => split_mark(edge),
        }
    }

    /// The chip's label — verb first, then what the verb acts on.
    ///
    /// `title` is the DRAGGED pane's, and an absent or blank one falls back to
    /// [`ANONYMOUS_PANE_NAME`].
    #[must_use]
    pub fn label(self, title: Option<&str>) -> String {
        match self {
            Self::None => String::from("cancel"),
            Self::Swap => format!("swap {}", name(title)),
            Self::Resplit(edge) => format!("split {}", edge_word(edge)),
            Self::Dock(edge) => format!("dock {}", edge_word(edge)),
        }
    }
}

/// Where a live pane drag STARTED.
///
/// Decides the commit family (move vs reattach) and, at the chip, which of two words the sentence
/// uses.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Origin {
    /// A tiled tree leaf, grabbed by its in-canvas handle.
    Tree,
    /// A detached satellite window, grabbed by its strip.
    Detached,
}

/// What releasing the drag at the current cursor would commit, across containers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Destination {
    /// Somewhere inside a canvas — the in-canvas chip is the affordance there.
    Canvas,
    /// Onto a sidebar row, beside the pane that row names.
    SidebarRow,
    /// Into a tab of its own.
    NewTab,
    /// Into a window of its own.
    TearOff,
    /// Nowhere — release commits nothing.
    None,
}

impl Destination {
    /// The destination `kind` names; an unrecognised byte is the cancel.
    #[must_use]
    pub const fn from_byte(kind: u8) -> Self {
        match kind {
            0 => Self::Canvas,
            1 => Self::SidebarRow,
            2 => Self::NewTab,
            3 => Self::TearOff,
            _ => Self::None,
        }
    }

    /// The floating chip's mark.
    ///
    /// [`Canvas`](Self::Canvas) answers [`Mark::Swap`] and is never drawn — the chip is hidden over
    /// the canvas — so the case exists to keep the match total rather than to pick a glyph.
    #[must_use]
    pub const fn mark(self) -> Mark {
        match self {
            Self::Canvas => Mark::Swap,
            Self::SidebarRow => Mark::Beside,
            Self::NewTab => Mark::NewTab,
            Self::TearOff => Mark::NewWindow,
            Self::None => Mark::Cancel,
        }
    }

    /// The floating chip's label.
    ///
    /// `target_title` is the pane the cursor is OVER (a sidebar row's), not the dragged pane — off
    /// the canvas the sentence is about where the pane is GOING. [`Canvas`](Self::Canvas) answers
    /// the empty string because the chip hides there: the in-canvas overlay is the affordance, and
    /// a floating twin over it would double the same words.
    #[must_use]
    pub fn label(self, target_title: Option<&str>, origin: Origin) -> String {
        match self {
            Self::Canvas => String::new(),
            // A satellite MERGES back into the tree; a tiled pane MOVES within it. Same op, and the
            // two words are the only thing that tells the user which one they are doing.
            Self::SidebarRow => {
                let verb = match origin {
                    Origin::Detached => "merge beside",
                    Origin::Tree => "move beside",
                };
                format!("{verb} {}", name(target_title))
            },
            Self::NewTab => String::from("new tab"),
            Self::TearOff => String::from("new window"),
            Self::None => String::from("cancel"),
        }
    }
}

/// The word an edge goes by in a chip's sentence.
#[must_use]
pub const fn edge_word(edge: PaneDropEdge) -> &'static str {
    match edge {
        PaneDropEdge::Left => "left",
        PaneDropEdge::Right => "right",
        PaneDropEdge::Top => "top",
        PaneDropEdge::Bottom => "bottom",
    }
}

/// Left and right partition WIDTH and make columns; top and bottom partition HEIGHT and make rows.
///
/// Read off the edge's own axis rather than by re-listing the four cases, so the mark cannot
/// disagree with the tree op the same edge drives.
#[must_use]
const fn split_mark(edge: PaneDropEdge) -> Mark {
    match edge.axis() {
        SplitAxis::Horizontal => Mark::SplitColumns,
        SplitAxis::Vertical => Mark::SplitRows,
    }
}

/// A pane's printable name, with the anonymous fallback folded in.
const fn name(title: Option<&str>) -> &str {
    match title {
        Some(title) if !title.is_empty() => title,
        _ => ANONYMOUS_PANE_NAME,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_tree::split_tree::PaneDropEdge;

    use super::{Destination, Mark, Origin, Zone};

    /// The mark follows the edge's AXIS, which is the tree op's own answer — the easy place to
    /// invert it.
    #[test]
    fn a_split_mark_agrees_with_the_axis_the_same_edge_drives() {
        for edge in [PaneDropEdge::Left, PaneDropEdge::Right] {
            assert_eq!(Zone::Resplit(edge).mark(), Mark::SplitColumns);
            assert_eq!(Zone::Dock(edge).mark(), Mark::SplitColumns);
        }
        for edge in [PaneDropEdge::Top, PaneDropEdge::Bottom] {
            assert_eq!(Zone::Resplit(edge).mark(), Mark::SplitRows);
            assert_eq!(Zone::Dock(edge).mark(), Mark::SplitRows);
        }
    }

    #[test]
    fn the_in_canvas_chip_says_the_verb_then_what_it_acts_on() {
        assert_eq!(Zone::None.label(Some("api")), "cancel");
        assert_eq!(Zone::Swap.label(Some("api")), "swap api");
        assert_eq!(Zone::Resplit(PaneDropEdge::Top).label(None), "split top");
        assert_eq!(Zone::Dock(PaneDropEdge::Right).label(None), "dock right");
    }

    /// A pane with no title, and one whose title is blank, are the same anonymous pane.
    #[test]
    fn a_nameless_pane_is_still_called_something() {
        assert_eq!(Zone::Swap.label(None), "swap pane");
        assert_eq!(Zone::Swap.label(Some("")), "swap pane");
    }

    /// The two words that tell a merge from a move are the only difference between the two origins.
    #[test]
    fn a_satellite_merges_where_a_tiled_pane_moves() {
        assert_eq!(
            Destination::SidebarRow.label(Some("api"), Origin::Detached),
            "merge beside api",
        );
        assert_eq!(
            Destination::SidebarRow.label(Some("api"), Origin::Tree),
            "move beside api",
        );
    }

    #[test]
    fn the_floating_chip_is_silent_over_the_canvas() {
        assert_eq!(Destination::Canvas.label(Some("api"), Origin::Tree), "");
        assert_eq!(Destination::NewTab.label(None, Origin::Tree), "new tab");
        assert_eq!(Destination::TearOff.label(None, Origin::Tree), "new window");
        assert_eq!(Destination::None.label(None, Origin::Tree), "cancel");
    }

    /// A byte neither side recognises commits NOTHING rather than guessing an op.
    #[test]
    fn an_unknown_byte_reads_as_the_cancel() {
        assert_eq!(Zone::from_parts(9, 0), Zone::None);
        assert_eq!(Destination::from_byte(9), Destination::None);
        assert_eq!(Zone::from_parts(9, 0).mark(), Mark::Cancel);
        assert_eq!(Destination::from_byte(9).mark(), Mark::Cancel);
    }

    #[test]
    fn the_zone_parts_rebuild_every_case_the_near_side_has() {
        assert_eq!(Zone::from_parts(1, 0), Zone::Swap);
        assert_eq!(Zone::from_parts(2, 2), Zone::Resplit(PaneDropEdge::Top));
        assert_eq!(Zone::from_parts(3, 3), Zone::Dock(PaneDropEdge::Bottom));
    }

    /// Seven marks, seven codes, no two alike — a renderer maps them by number.
    #[test]
    fn every_mark_has_its_own_code() {
        let marks = [
            Mark::Cancel,
            Mark::Swap,
            Mark::SplitColumns,
            Mark::SplitRows,
            Mark::Beside,
            Mark::NewTab,
            Mark::NewWindow,
        ];
        let mut codes: Vec<u8> = marks.into_iter().map(Mark::code).collect();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), marks.len());
    }
}
