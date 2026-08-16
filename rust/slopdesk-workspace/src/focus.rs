//! Moving focus by what is on screen, not by where a pane sits in the tree.
//!
//! Every answer here is resolved against the same [`SolvedLayout`] the renderer draws, so "move
//! focus left" lands on the pane visually to the left even in a deeply and unevenly nested tree.
//! Resolving against tree position instead is what makes navigation feel wrong in a nested layout:
//! the sibling order stops matching what the eye sees.
//!
//! ## Why overlap beats distance
//!
//! A directional move prefers the candidate whose CROSS-AXIS span overlaps the source most, and
//! only then the nearest one along the movement axis. Ranking by centroid distance alone sends you
//! into the pane that happens to be closest rather than the one you were pointing at — with uneven
//! neighbours those are routinely different panes. A candidate sharing no cross-axis span at all is
//! not a neighbour in that direction and is skipped entirely, so moving right from a top pane never
//! jumps to a bottom-right one.
//!
//! ## Determinism
//!
//! Candidates are visited in id order and a tie keeps the FIRST one, so two equally good candidates
//! always resolve the same way. In Swift this needed an explicit sort, because a dictionary's
//! iteration order is randomized per process and the same layout could navigate differently between
//! launches; here the ordered map gives it for free, which is one fewer thing to remember.

use crate::geometry::Rect;
use crate::identity::PaneId;
use crate::split_layout::SolvedLayout;

/// How close two coordinates must be to count as the same one.
const EPSILON: f64 = 0.5;

/// A focus-movement intent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FocusDirection {
    /// The nearest pane to the left, as seen.
    Left,
    /// The nearest pane to the right.
    Right,
    /// The nearest pane above.
    Up,
    /// The nearest pane below.
    Down,
    /// Cycle forward through the panes, wrapping past the end.
    Next,
    /// Cycle backward, wrapping past the start.
    Previous,
}

impl FocusDirection {
    /// Every direction, in the order whose POSITION is the byte that crosses the ABI.
    ///
    /// Stated once, here, for the reason [`crate::canvas::AlignEdge::ALL`] gives: the shim used to
    /// restate this order as a hand-written `match`, and `check-supervisor` only counts the cases
    /// on each side. A count cannot see a seventh direction added everywhere except that
    /// decoder — and this decoder's fallback was `Next`, so the new direction would not have
    /// failed, it would have CYCLED.
    pub const ALL: [Self; 6] = [
        Self::Left,
        Self::Right,
        Self::Up,
        Self::Down,
        Self::Next,
        Self::Previous,
    ];

    /// The byte for this direction.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Up => 2,
            Self::Down => 3,
            Self::Next => 4,
            Self::Previous => 5,
        }
    }

    /// The direction a byte names, or `None` when it names none.
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.get(usize::from(index)).copied()
    }

    /// Whether this is a cardinal move rather than a cycle.
    #[must_use]
    pub const fn is_directional(self) -> bool {
        matches!(self, Self::Left | Self::Right | Self::Up | Self::Down)
    }
}

/// The pane adjacent to one in a direction, or `None` at an edge.
///
/// `Next` and `Previous` cycle the solved frames in READING order — top to bottom, then left to
/// right — which is a convenience for callers that only hold a layout. A caller that wants the
/// tree's pre-order cycle should pass the tree's own pane list to [`cycle`] instead; frame order
/// and tree order are different questions and the layout cannot answer the second one.
#[must_use]
pub fn neighbor(pane: PaneId, direction: FocusDirection, solved: &SolvedLayout) -> Option<PaneId> {
    let source = solved.frame_of(pane)?;
    if direction.is_directional() {
        return directional_neighbor(pane, source, direction, solved);
    }
    let mut ordered: Vec<(PaneId, Rect)> = solved.frames.iter().map(|(id, rect)| (*id, *rect)).collect();
    ordered.sort_by(|(left_id, left), (right_id, right)| {
        if (left.min_y() - right.min_y()).abs() > EPSILON {
            return left.min_y().total_cmp(&right.min_y());
        }
        if (left.min_x() - right.min_x()).abs() > EPSILON {
            return left.min_x().total_cmp(&right.min_x());
        }
        // Coincident panes — stacked by an overlap bypass, or aligned by a distribute op — would
        // otherwise compare equal, and the cycle would depend on whatever order the map happened to
        // yield. The id breaks it, so the cycle visits them the same way every launch.
        left_id.cmp(right_id)
    });
    let ids: Vec<PaneId> = ordered.into_iter().map(|(id, _)| id).collect();
    cycle(&ids, pane, direction == FocusDirection::Next)
}

/// Cycles through a pane list, wrapping at both ends.
///
/// `None` when the list is empty or does not hold the starting pane. A single-pane list yields that
/// pane, because cycling within one pane is a no-op rather than a failure.
#[must_use]
pub fn cycle(panes: &[PaneId], from: PaneId, forward: bool) -> Option<PaneId> {
    let index = panes.iter().position(|id| *id == from)?;
    let count = panes.len();
    let next = if forward {
        (index + 1) % count
    } else {
        (index + count - 1) % count
    };
    panes.get(next).copied()
}

fn directional_neighbor(
    pane: PaneId,
    source: Rect,
    direction: FocusDirection,
    solved: &SolvedLayout,
) -> Option<PaneId> {
    let mut best: Option<(PaneId, f64, f64)> = None;
    for (id, rect) in &solved.frames {
        if *id == pane || !is_on_requested_side(*rect, source, direction) {
            continue;
        }
        let overlap = cross_axis_overlap(*rect, source, direction);
        if overlap <= 0.0 {
            continue;
        }
        let distance = axial_distance(*rect, source, direction);
        let better = best.is_none_or(|(_, best_overlap, best_distance)| {
            overlap > best_overlap + EPSILON
                || ((overlap - best_overlap).abs() <= EPSILON && distance < best_distance)
        });
        if better {
            best = Some((*id, overlap, distance));
        }
    }
    best.map(|(id, ..)| id)
}

/// Whether a candidate lies on the requested side.
///
/// Compared against the source's leading edge in that direction, so a pane that abuts exactly still
/// counts — tiled panes share an edge by construction, and a strict test would make every seam
/// impassable.
fn is_on_requested_side(candidate: Rect, source: Rect, direction: FocusDirection) -> bool {
    match direction {
        FocusDirection::Left => candidate.mid_x() < source.min_x() + EPSILON,
        FocusDirection::Right => candidate.mid_x() > source.max_x() - EPSILON,
        FocusDirection::Up => candidate.mid_y() < source.min_y() + EPSILON,
        FocusDirection::Down => candidate.mid_y() > source.max_y() - EPSILON,
        FocusDirection::Next | FocusDirection::Previous => false,
    }
}

/// How much the two rects overlap along the axis PERPENDICULAR to the movement.
fn cross_axis_overlap(candidate: Rect, source: Rect, direction: FocusDirection) -> f64 {
    match direction {
        FocusDirection::Left | FocusDirection::Right => {
            (candidate.max_y().min(source.max_y()) - candidate.min_y().max(source.min_y())).max(0.0)
        },
        FocusDirection::Up | FocusDirection::Down => {
            (candidate.max_x().min(source.max_x()) - candidate.min_x().max(source.min_x())).max(0.0)
        },
        FocusDirection::Next | FocusDirection::Previous => 0.0,
    }
}

/// The gap between the facing edges along the movement axis, zero for abutting or overlapping
/// rects.
fn axial_distance(candidate: Rect, source: Rect, direction: FocusDirection) -> f64 {
    match direction {
        FocusDirection::Left => (source.min_x() - candidate.max_x()).max(0.0),
        FocusDirection::Right => (candidate.min_x() - source.max_x()).max(0.0),
        FocusDirection::Up => (source.min_y() - candidate.max_y()).max(0.0),
        FocusDirection::Down => (candidate.min_y() - source.max_y()).max(0.0),
        FocusDirection::Next | FocusDirection::Previous => f64::INFINITY,
    }
}

#[cfg(test)]
mod tests {
    use super::{FocusDirection, cycle, neighbor};
    use crate::geometry::Rect;
    use crate::identity::PaneId;
    use crate::split_layout::SolvedLayout;

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn layout(frames: &[(u8, Rect)]) -> SolvedLayout {
        let mut solved = SolvedLayout::empty();
        for (id, rect) in frames {
            solved.frames.insert(pane(*id), *rect);
        }
        solved
    }

    /// Two columns, the right one split into a tall top and a short bottom.
    fn uneven() -> SolvedLayout {
        layout(&[
            (1, Rect::xywh(0.0, 0.0, 500.0, 600.0)),
            (2, Rect::xywh(500.0, 0.0, 500.0, 400.0)),
            (3, Rect::xywh(500.0, 400.0, 500.0, 200.0)),
        ])
    }

    /// The two halves of the ABI byte agree, and the mapping is total both ways.
    ///
    /// `ALL` and `index` are separately written — one an array, one a match — so this is what ties
    /// them together. A case added to the array but not the match will not compile; a case added to
    /// both in DIFFERENT positions compiles fine and fails here, and nothing else would notice: the
    /// byte would cross the boundary naming another direction.
    #[test]
    fn every_focus_direction_round_trips_through_its_abi_byte() {
        for (position, direction) in FocusDirection::ALL.iter().enumerate() {
            assert_eq!(
                usize::from(direction.index()),
                position,
                "{direction:?} is at position {position}"
            );
            assert_eq!(FocusDirection::from_index(direction.index()), Some(*direction));
        }
        let past_the_end = FocusDirection::ALL
            .last()
            .map_or(0, |direction| direction.index().saturating_add(1));
        assert_eq!(
            FocusDirection::from_index(past_the_end),
            None,
            "a byte naming no case must read as none, not as the last one"
        );
        assert_eq!(FocusDirection::from_index(u8::MAX), None);
    }

    #[test]
    fn moving_across_a_shared_seam_works_even_though_the_rects_abut_exactly() {
        assert_eq!(neighbor(pane(1), FocusDirection::Right, &uneven()), Some(pane(2)));
        assert_eq!(neighbor(pane(2), FocusDirection::Left, &uneven()), Some(pane(1)));
    }

    #[test]
    fn the_pane_you_are_pointing_at_wins_over_the_merely_nearest_one() {
        // From the tall top-right pane, moving left has only one candidate; from the SHORT
        // bottom-right pane, the left neighbour still spans it, so the move lands there.
        assert_eq!(neighbor(pane(3), FocusDirection::Left, &uneven()), Some(pane(1)));
    }

    #[test]
    fn a_candidate_sharing_no_cross_axis_span_is_not_a_neighbour() {
        // A pane far to the right but entirely below the source's rows.
        let solved = layout(&[
            (1, Rect::xywh(0.0, 0.0, 500.0, 200.0)),
            (2, Rect::xywh(500.0, 400.0, 500.0, 200.0)),
        ]);
        assert!(
            neighbor(pane(1), FocusDirection::Right, &solved).is_none(),
            "moving right must not jump to a pane that is merely further right",
        );
    }

    #[test]
    fn moving_off_an_edge_finds_nothing() {
        assert!(neighbor(pane(1), FocusDirection::Left, &uneven()).is_none());
        assert!(neighbor(pane(1), FocusDirection::Up, &uneven()).is_none());
    }

    #[test]
    fn an_unsolved_pane_has_no_neighbours() {
        assert!(neighbor(pane(9), FocusDirection::Right, &uneven()).is_none());
    }

    #[test]
    fn vertical_moves_read_the_other_axis() {
        assert_eq!(neighbor(pane(2), FocusDirection::Down, &uneven()), Some(pane(3)));
        assert_eq!(neighbor(pane(3), FocusDirection::Up, &uneven()), Some(pane(2)));
    }

    #[test]
    fn the_cycle_wraps_at_both_ends() {
        let panes = [pane(1), pane(2), pane(3)];
        assert_eq!(cycle(&panes, pane(3), true), Some(pane(1)));
        assert_eq!(cycle(&panes, pane(1), false), Some(pane(3)));
    }

    #[test]
    fn cycling_within_one_pane_stays_put() {
        assert_eq!(cycle(&[pane(1)], pane(1), true), Some(pane(1)));
    }

    #[test]
    fn cycling_from_a_pane_that_is_not_in_the_list_finds_nothing() {
        assert!(cycle(&[pane(1), pane(2)], pane(9), true).is_none());
        assert!(cycle(&[], pane(1), true).is_none());
    }

    #[test]
    fn the_layouts_cycle_reads_top_to_bottom_then_left_to_right() {
        let solved = uneven();
        assert_eq!(neighbor(pane(1), FocusDirection::Next, &solved), Some(pane(2)));
        assert_eq!(neighbor(pane(2), FocusDirection::Next, &solved), Some(pane(3)));
        assert_eq!(neighbor(pane(3), FocusDirection::Next, &solved), Some(pane(1)));
        assert_eq!(
            neighbor(pane(1), FocusDirection::Previous, &solved),
            Some(pane(3))
        );
    }

    #[test]
    fn coincident_panes_cycle_the_same_way_every_time() {
        let stacked = layout(&[
            (7, Rect::xywh(0.0, 0.0, 500.0, 600.0)),
            (3, Rect::xywh(0.0, 0.0, 500.0, 600.0)),
        ]);
        assert_eq!(
            neighbor(pane(3), FocusDirection::Next, &stacked),
            Some(pane(7)),
            "the id breaks the tie, so the order cannot vary between launches",
        );
    }
}
