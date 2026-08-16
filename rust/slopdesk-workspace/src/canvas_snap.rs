//! Magnetic snapping for a drag: what a pane aligns to, and what stops it oscillating.
//!
//! The solver is a total function of the RAW proposed frame — the persisted frame plus the raw live
//! translation, never a previously snapped one. That is what makes breaking away land exactly under
//! the pointer instead of drifting: the snap is recomputed from scratch every frame, and the only
//! thing carried between frames is the hysteresis token.
//!
//! ## What it snaps to, strongest first
//! GUTTER — an edge butting a neighbour with the standard gap, so a hand-tiled row looks exactly
//! like the tidy command's output. EDGE — any min or max against any min or max, which includes
//! sitting flush. CENTRE — mid against mid. VIEWPORT — the inset visible edges and the centreline.
//! The GRID is a fallback ONLY, considered on an axis where nothing else engaged, because objects
//! beat the lattice.
//!
//! ## Why the hold is asymmetric
//! A candidate ENGAGES within one threshold and, once held, persists until the raw position drifts
//! past a LARGER one. Equal thresholds would let a pane sitting exactly on a guide oscillate across
//! it every frame. The hold also survives a nearer candidate appearing mid-drag — no re-targeting
//! mid-hold — which is what makes the feel deterministic rather than twitchy.

use std::collections::BTreeMap;

use crate::canvas_geometry::ResizeAnchor;
use crate::geometry::{MIN_ITEM_SIZE, Rect, Size, sanitize_preserving_size};

/// How close two coordinates must be to count as the same one.
///
/// It does double duty: near-ties within it break by class priority rather than by a hair of
/// distance, and a guide is drawn only for a candidate this close to the committed frame.
pub const COINCIDENCE_EPSILON: f64 = 0.5;

/// The solver's tuning, all in canvas points — which are screen points, because the camera is a
/// pure translate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SnapConfig {
    /// Magnetic range for pane and viewport candidates.
    pub engage: f64,
    /// Once held, the distance the raw position must drift past to break away. Strictly larger than
    /// `engage`, which is what stops the oscillation.
    pub release: f64,
    /// The standard gap gutter-adjacency uses — the same one the tidy command and the group box
    /// use, so a hand-snapped row is indistinguishable from a tidied one.
    pub gutter: f64,
    /// The grid quantum. The dot grid draws at twice this, so every dot is an honest snap site.
    pub grid_spacing: f64,
    /// The grid's own engage range, deliberately tighter: it is the weakest magnet.
    pub grid_engage: f64,
    /// The grid's own release range.
    pub grid_release: f64,
    /// Master switch for pane and viewport candidates.
    pub snaps_to_panes: bool,
    /// Master switch for the grid fallback.
    pub snaps_to_grid: bool,
}

impl Default for SnapConfig {
    fn default() -> Self {
        Self {
            engage: 8.0,
            release: 12.0,
            gutter: 16.0,
            grid_spacing: 16.0,
            grid_engage: 6.0,
            grid_release: 9.0,
            snaps_to_panes: true,
            snaps_to_grid: true,
        }
    }
}

impl SnapConfig {
    /// Everything off — the escape hatch behind "hold a modifier to drag freely".
    #[must_use]
    pub fn disabled() -> Self {
        Self {
            snaps_to_panes: false,
            snaps_to_grid: false,
            ..Self::default()
        }
    }
}

/// The candidate class that produced a guide.
///
/// The order IS the priority — lower is stronger — and it is also the view's style cue, since
/// centres draw dashed where alignments draw solid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum GuideKind {
    /// An edge butting a neighbour with the standard gap.
    Gutter,
    /// An edge landing on a neighbour's edge, flush included.
    Edge,
    /// A centre landing on a centre.
    Center,
    /// An edge or centre landing on the viewport's.
    ViewportEdge,
}

/// Which way a guide line runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum GuideOrientation {
    /// A vertical line — an x-axis snap — spanning a range of y.
    Vertical,
    /// A horizontal line — a y-axis snap — spanning a range of x.
    Horizontal,
}

/// One alignment line the view draws while a pane-derived snap is active.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Guide {
    /// Which way it runs.
    pub orientation: GuideOrientation,
    /// Its position on the snapped axis.
    pub position: f64,
    /// Where the line starts on the other axis.
    pub start: f64,
    /// Where it ends.
    pub end: f64,
    /// The strongest class that contributed to it.
    pub kind: GuideKind,
}

/// Which value of the dragged frame a snap binds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum OwnEdge {
    /// The leading edge — left or top.
    Min,
    /// The centre.
    Mid,
    /// The trailing edge — right or bottom.
    Max,
}

/// One axis's held snap: which dragged value is bound to what coordinate.
///
/// Fed back into the next solve so the hold survives until the release threshold, which is the
/// whole reason the drag preview and the commit agree even inside the hysteresis band.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stick {
    /// The dragged value that landed on the target.
    pub own_edge: OwnEdge,
    /// The coordinate it landed on.
    pub target: f64,
    /// Whether this is a grid hold, which uses the tighter release and draws no guide.
    pub is_grid: bool,
}

/// The solver's answer.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolution {
    /// The snapped frame. Equal to the proposal when nothing engaged.
    pub frame: Rect,
    /// The lines to draw, in a deterministic order.
    pub guides: Vec<Guide>,
    /// The x-axis hold to feed back.
    pub stick_x: Option<Stick>,
    /// The y-axis hold to feed back.
    pub stick_y: Option<Stick>,
}

impl Resolution {
    /// A resolution that snapped to nothing.
    #[must_use]
    pub const fn unsnapped(frame: Rect) -> Self {
        Self {
            frame,
            guides: Vec::new(),
            stick_x: None,
            stick_y: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Axis {
    X,
    Y,
}

#[derive(Debug, Clone, Copy)]
struct AxisValues {
    min: f64,
    mid: f64,
    max: f64,
}

impl AxisValues {
    const fn of(frame: Rect, axis: Axis) -> Self {
        match axis {
            Axis::X => {
                Self {
                    min: frame.min_x(),
                    mid: frame.mid_x(),
                    max: frame.max_x(),
                }
            },
            Axis::Y => {
                Self {
                    min: frame.min_y(),
                    mid: frame.mid_y(),
                    max: frame.max_y(),
                }
            },
        }
    }

    const fn value(self, edge: OwnEdge) -> f64 {
        match edge {
            OwnEdge::Min => self.min,
            OwnEdge::Mid => self.mid,
            OwnEdge::Max => self.max,
        }
    }
}

/// One snap opportunity: a dragged value that may land on a coordinate, plus the source's
/// perpendicular extent, which the guide's span is built from.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Candidate {
    own_edge: OwnEdge,
    target: f64,
    kind: GuideKind,
    span_start: f64,
    span_end: f64,
}

const fn perpendicular_span(rect: Rect, axis: Axis) -> (f64, f64) {
    match axis {
        Axis::X => (rect.min_y(), rect.max_y()),
        Axis::Y => (rect.min_x(), rect.max_x()),
    }
}

fn viewport_candidates(
    axis: Axis,
    viewport: Rect,
    config: &SnapConfig,
    include_center: bool,
) -> Vec<Candidate> {
    let inset = viewport.outset_by(-config.gutter, -config.gutter);
    let values = AxisValues::of(inset, axis);
    let (span_start, span_end) = perpendicular_span(viewport, axis);
    let mut result = vec![
        Candidate {
            own_edge: OwnEdge::Min,
            target: values.min,
            kind: GuideKind::ViewportEdge,
            span_start,
            span_end,
        },
        Candidate {
            own_edge: OwnEdge::Max,
            target: values.max,
            kind: GuideKind::ViewportEdge,
            span_start,
            span_end,
        },
    ];
    if include_center {
        result.push(Candidate {
            own_edge: OwnEdge::Mid,
            target: values.mid,
            kind: GuideKind::ViewportEdge,
            span_start,
            span_end,
        });
    }
    result
}

fn move_candidates(
    axis: Axis,
    others: &[Rect],
    viewport: Option<Rect>,
    config: &SnapConfig,
) -> Vec<Candidate> {
    if !config.snaps_to_panes {
        return Vec::new();
    }
    let mut result = Vec::new();
    for other in others {
        let values = AxisValues::of(*other, axis);
        let (span_start, span_end) = perpendicular_span(*other, axis);
        let mut push = |own_edge, target, kind| {
            result.push(Candidate {
                own_edge,
                target,
                kind,
                span_start,
                span_end,
            });
        };
        // Gutter adjacency: tile next to the neighbour with the standard gap.
        push(OwnEdge::Min, values.max + config.gutter, GuideKind::Gutter);
        push(OwnEdge::Max, values.min - config.gutter, GuideKind::Gutter);
        // Edge alignment, any to any, which is also how flush butting happens.
        for target in [values.min, values.max] {
            push(OwnEdge::Min, target, GuideKind::Edge);
            push(OwnEdge::Max, target, GuideKind::Edge);
        }
        push(OwnEdge::Mid, values.mid, GuideKind::Center);
    }
    if let Some(viewport) = viewport {
        result.extend(viewport_candidates(axis, viewport, config, true));
    }
    result
}

fn resize_candidates(
    axis: Axis,
    own_edge: OwnEdge,
    others: &[Rect],
    viewport: Option<Rect>,
    config: &SnapConfig,
) -> Vec<Candidate> {
    if !config.snaps_to_panes {
        return Vec::new();
    }
    let mut result = Vec::new();
    for other in others {
        let values = AxisValues::of(*other, axis);
        let (span_start, span_end) = perpendicular_span(*other, axis);
        // An edge growing toward a neighbour butts BEFORE its near edge or AFTER its far one.
        let gutter_target = if own_edge == OwnEdge::Min {
            values.max + config.gutter
        } else {
            values.min - config.gutter
        };
        result.push(Candidate {
            own_edge,
            target: gutter_target,
            kind: GuideKind::Gutter,
            span_start,
            span_end,
        });
        for target in [values.min, values.max] {
            result.push(Candidate {
                own_edge,
                target,
                kind: GuideKind::Edge,
                span_start,
                span_end,
            });
        }
    }
    if let Some(viewport) = viewport {
        result.extend(
            viewport_candidates(axis, viewport, config, false)
                .into_iter()
                .filter(|candidate| candidate.own_edge == own_edge),
        );
    }
    result
}

/// Whether a held non-grid stick is still justified by a live candidate.
///
/// Without this, a pane whose neighbour was closed or dragged away mid-drag would stay magnetized
/// to a coordinate nothing supports any more, with no guide drawable for it — and "a snap is
/// active" must imply "a guide is drawable" in both directions. Grid sticks skip the check: the
/// lattice is always there.
fn is_justified(stick: Stick, candidates: &[Candidate]) -> bool {
    stick.is_grid
        || candidates.iter().any(|candidate| {
            candidate.own_edge == stick.own_edge
                && (candidate.target - stick.target).abs() <= COINCIDENCE_EPSILON
        })
}

/// Order-independent best-candidate selection.
///
/// Two passes on purpose. The first finds the smallest in-range distance; the second picks, among
/// everything within an epsilon of it, the strongest class, breaking any remaining tie by distance
/// and then by coordinate. A single pairwise comparator is NOT transitive under a near-tie rule, so
/// it would let the winner depend on the order the neighbours happened to arrive in.
fn select_best(
    candidates: &[Candidate],
    own: impl Fn(OwnEdge) -> f64,
    engage: f64,
) -> Option<(Candidate, f64)> {
    let mut min_abs = f64::INFINITY;
    for candidate in candidates {
        let delta = candidate.target - own(candidate.own_edge);
        if delta.is_finite() && delta.abs() <= engage {
            min_abs = min_abs.min(delta.abs());
        }
    }
    if !min_abs.is_finite() {
        return None;
    }
    let mut best: Option<(Candidate, f64)> = None;
    for candidate in candidates {
        let delta = candidate.target - own(candidate.own_edge);
        if !delta.is_finite() || delta.abs() > engage || delta.abs() > min_abs + COINCIDENCE_EPSILON {
            continue;
        }
        if let Some((current, current_delta)) = best {
            // A TOTAL order, class first: `total_cmp` rather than `<` so an exact distance tie falls
            // through to the coordinate deterministically instead of comparing floats for equality.
            let better = candidate
                .kind
                .cmp(&current.kind)
                .then_with(|| delta.abs().total_cmp(&current_delta.abs()))
                .then_with(|| candidate.target.total_cmp(&current.target))
                .is_lt();
            if !better {
                continue;
            }
        }
        best = Some((*candidate, delta));
    }
    best
}

#[derive(Debug, Clone, Copy)]
struct AxisResolution {
    delta: f64,
    stick: Option<Stick>,
}

const NO_SNAP: AxisResolution = AxisResolution {
    delta: 0.0,
    stick: None,
};

/// The hold-then-engage-then-grid ladder, shared by both drags.
fn resolve_value(
    own: f64,
    own_for: impl Fn(OwnEdge) -> f64,
    grid_edge: OwnEdge,
    candidates: &[Candidate],
    previous: Option<Stick>,
    config: &SnapConfig,
    grid_valid: impl Fn(f64) -> bool,
) -> AxisResolution {
    // A held stick persists while the RAW position is inside its release threshold, even if a nearer
    // candidate has appeared — but only while something still supports it.
    if let Some(previous) = previous {
        let held_own = own_for(previous.own_edge);
        let release = if previous.is_grid {
            config.grid_release
        } else {
            config.release
        };
        let enabled = if previous.is_grid {
            config.snaps_to_grid
        } else {
            config.snaps_to_panes
        };
        if enabled && is_justified(previous, candidates) && (previous.target - held_own).abs() < release {
            return AxisResolution {
                delta: previous.target - held_own,
                stick: Some(previous),
            };
        }
    }
    if config.snaps_to_panes
        && let Some((candidate, delta)) = select_best(candidates, &own_for, config.engage)
    {
        return AxisResolution {
            delta,
            stick: Some(Stick {
                own_edge: candidate.own_edge,
                target: candidate.target,
                is_grid: false,
            }),
        };
    }
    // The grid is a FALLBACK: it never competes with an engaged pane or viewport candidate.
    if config.snaps_to_grid && config.grid_spacing > 0.0 {
        let quantized = (own / config.grid_spacing).round() * config.grid_spacing;
        let delta = quantized - own;
        if delta.abs() <= config.grid_engage && grid_valid(quantized) {
            return AxisResolution {
                delta,
                stick: Some(Stick {
                    own_edge: grid_edge,
                    target: quantized,
                    is_grid: true,
                }),
            };
        }
    }
    NO_SNAP
}

/// Snaps a MOVE drag. The size never changes; each axis resolves independently.
#[must_use]
pub fn snap_move(
    proposed: Rect,
    others: &[Rect],
    viewport: Option<Rect>,
    config: &SnapConfig,
    previous: Option<&Resolution>,
) -> Resolution {
    let x_candidates = move_candidates(Axis::X, others, viewport, config);
    let y_candidates = move_candidates(Axis::Y, others, viewport, config);
    let x_values = AxisValues::of(proposed, Axis::X);
    let y_values = AxisValues::of(proposed, Axis::Y);

    let x = resolve_value(
        x_values.min,
        |edge| x_values.value(edge),
        OwnEdge::Min,
        &x_candidates,
        previous.and_then(|resolution| resolution.stick_x),
        config,
        |_| true,
    );
    let y = resolve_value(
        y_values.min,
        |edge| y_values.value(edge),
        OwnEdge::Min,
        &y_candidates,
        previous.and_then(|resolution| resolution.stick_y),
        config,
        |_| true,
    );

    let snapped = sanitize_preserving_size(proposed.offset_by(x.delta, y.delta));
    Resolution {
        frame: snapped,
        guides: guides(
            snapped,
            &x_candidates,
            &y_candidates,
            x.stick.is_some_and(|stick| !stick.is_grid),
            y.stick.is_some_and(|stick| !stick.is_grid),
        ),
        stick_x: x.stick,
        stick_y: y.stick,
    }
}

/// Snaps a RESIZE drag.
///
/// Only the edges the anchor MOVES are magnetic, and centres are skipped entirely: a resize aligns
/// edges, not centres. A candidate that would push the pane below its floor is DISCARDED rather
/// than clamped, so every guide the view draws is a true statement and the pinned edge never
/// shifts.
#[must_use]
pub fn snap_resize(
    proposed: Rect,
    anchor: ResizeAnchor,
    others: &[Rect],
    viewport: Option<Rect>,
    min_size: Size,
    config: &SnapConfig,
    previous: Option<&Resolution>,
) -> Resolution {
    let mut left = proposed.min_x();
    let mut right = proposed.max_x();
    let mut top = proposed.min_y();
    let mut bottom = proposed.max_y();

    let mut stick_x = None;
    let mut stick_y = None;
    let mut x_candidates = Vec::new();
    let mut y_candidates = Vec::new();

    if anchor.moves_left() || anchor.moves_right() {
        let moves_left = anchor.moves_left();
        let own_edge = if moves_left { OwnEdge::Min } else { OwnEdge::Max };
        let (pinned_right, pinned_left) = (right, left);
        let valid = move |target: f64| {
            if moves_left {
                pinned_right - target >= min_size.width
            } else {
                target - pinned_left >= min_size.width
            }
        };
        x_candidates = resize_candidates(Axis::X, own_edge, others, viewport, config)
            .into_iter()
            .filter(|candidate| valid(candidate.target))
            .collect();
        let own = if moves_left { left } else { right };
        let resolved = resolve_value(
            own,
            |_| own,
            own_edge,
            &x_candidates,
            previous
                .and_then(|resolution| resolution.stick_x)
                .filter(|stick| stick.own_edge == own_edge),
            config,
            valid,
        );
        if moves_left {
            left += resolved.delta;
        } else {
            right += resolved.delta;
        }
        stick_x = resolved.stick;
    }
    if anchor.moves_top() || anchor.moves_bottom() {
        let moves_top = anchor.moves_top();
        let own_edge = if moves_top { OwnEdge::Min } else { OwnEdge::Max };
        let (pinned_bottom, pinned_top) = (bottom, top);
        let valid = move |target: f64| {
            if moves_top {
                pinned_bottom - target >= min_size.height
            } else {
                target - pinned_top >= min_size.height
            }
        };
        y_candidates = resize_candidates(Axis::Y, own_edge, others, viewport, config)
            .into_iter()
            .filter(|candidate| valid(candidate.target))
            .collect();
        let own = if moves_top { top } else { bottom };
        let resolved = resolve_value(
            own,
            |_| own,
            own_edge,
            &y_candidates,
            previous
                .and_then(|resolution| resolution.stick_y)
                .filter(|stick| stick.own_edge == own_edge),
            config,
            valid,
        );
        if moves_top {
            top += resolved.delta;
        } else {
            bottom += resolved.delta;
        }
        stick_y = resolved.stick;
    }

    let snapped = sanitize_preserving_size(Rect::xywh(left, top, right - left, bottom - top));
    Resolution {
        frame: snapped,
        guides: guides(
            snapped,
            &x_candidates,
            &y_candidates,
            stick_x.is_some_and(|stick: Stick| !stick.is_grid),
            stick_y.is_some_and(|stick: Stick| !stick.is_grid),
        ),
        stick_x,
        stick_y,
    }
}

/// The same resize at the standard pane floor.
#[must_use]
pub fn snap_resize_default(
    proposed: Rect,
    anchor: ResizeAnchor,
    others: &[Rect],
    viewport: Option<Rect>,
    config: &SnapConfig,
    previous: Option<&Resolution>,
) -> Resolution {
    snap_resize(
        proposed,
        anchor,
        others,
        viewport,
        MIN_ITEM_SIZE,
        config,
        previous,
    )
}

/// Every candidate that COINCIDES with the committed frame becomes a guide.
///
/// Drawing from the committed frame rather than from the winning candidate's target is what makes
/// the line pixel-true: the target may sit up to an epsilon away, and a line that is nearly right
/// is worse than no line. Sources that agree extend the span, the strongest class among them picks
/// the style, and a grid snap draws nothing at all — the dot grid is its own affordance.
fn guides(
    snapped: Rect,
    x_candidates: &[Candidate],
    y_candidates: &[Candidate],
    x_snapped: bool,
    y_snapped: bool,
) -> Vec<Guide> {
    if !x_snapped && !y_snapped {
        return Vec::new();
    }
    let mut result = Vec::new();
    if x_snapped {
        result.extend(axis_guides(
            snapped,
            Axis::X,
            x_candidates,
            GuideOrientation::Vertical,
        ));
    }
    if y_snapped {
        result.extend(axis_guides(
            snapped,
            Axis::Y,
            y_candidates,
            GuideOrientation::Horizontal,
        ));
    }
    // A deterministic order, for the view's iteration and for the assertions.
    result.sort_by(|a, b| {
        a.orientation
            .cmp(&b.orientation)
            .then_with(|| a.position.total_cmp(&b.position))
    });
    result
}

fn axis_guides(
    snapped: Rect,
    axis: Axis,
    candidates: &[Candidate],
    orientation: GuideOrientation,
) -> Vec<Guide> {
    let values = AxisValues::of(snapped, axis);
    let (own_start, own_end) = perpendicular_span(snapped, axis);
    // Grouped by the dragged edge each binds: distinct edges cannot fall within an epsilon of each
    // other above the minimum pane size, so the grouping is unambiguous.
    let mut by_edge: BTreeMap<OwnEdge, (f64, f64, GuideKind)> = BTreeMap::new();
    for candidate in candidates {
        if (candidate.target - values.value(candidate.own_edge)).abs() > COINCIDENCE_EPSILON {
            continue;
        }
        by_edge
            .entry(candidate.own_edge)
            .and_modify(|entry| {
                entry.0 = entry.0.min(candidate.span_start);
                entry.1 = entry.1.max(candidate.span_end);
                entry.2 = entry.2.min(candidate.kind);
            })
            .or_insert((candidate.span_start, candidate.span_end, candidate.kind));
    }
    by_edge
        .into_iter()
        .map(|(edge, (start, end, kind))| {
            Guide {
                orientation,
                position: values.value(edge),
                start: start.min(own_start),
                end: end.max(own_end),
                kind,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the fixtures are exact integers of the config's own thresholds, and a missing guide is a \
                  test failure with nothing to return"
    )]

    use super::{
        GuideKind, GuideOrientation, OwnEdge, Resolution, SnapConfig, Stick, snap_move, snap_resize,
        snap_resize_default,
    };
    use crate::canvas_geometry::ResizeAnchor;
    use crate::geometry::{Rect, Size};

    fn neighbour() -> Rect {
        Rect::xywh(0.0, 0.0, 400.0, 300.0)
    }

    fn dragged(x: f64, y: f64) -> Rect {
        Rect::xywh(x, y, 400.0, 300.0)
    }

    #[test]
    fn a_pane_dragged_near_a_neighbours_edge_lands_on_it() {
        let config = SnapConfig::default();
        let resolution = snap_move(dragged(3.0, 500.0), &[neighbour()], None, &config, None);
        assert_eq!(resolution.frame.min_x(), 0.0);
        assert_eq!(
            resolution.frame.size,
            dragged(0.0, 0.0).size,
            "a move never resizes"
        );
    }

    #[test]
    fn the_gutter_beats_a_bare_edge_at_the_same_distance() {
        let config = SnapConfig::default();
        // Both an edge candidate at 400 and a gutter candidate at 416 are in range from 408.
        let resolution = snap_move(dragged(408.0, 0.0), &[neighbour()], None, &config, None);
        assert_eq!(
            resolution.frame.min_x(),
            416.0,
            "tiling with the standard gap wins the tie"
        );
        let Some(guide) = resolution.guides.first() else {
            panic!("an engaged snap must be drawable");
        };
        assert_eq!(guide.kind, GuideKind::Gutter);
    }

    #[test]
    fn nothing_moves_when_nothing_is_in_range() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let proposed = dragged(900.0, 900.0);
        let resolution = snap_move(proposed, &[neighbour()], None, &config, None);
        assert_eq!(resolution.frame, proposed);
        assert!(resolution.guides.is_empty());
        assert!(resolution.stick_x.is_none() && resolution.stick_y.is_none());
    }

    #[test]
    fn a_held_snap_survives_past_the_engage_range_but_not_past_the_release_range() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let held = Resolution {
            frame: dragged(0.0, 500.0),
            guides: Vec::new(),
            stick_x: Some(Stick {
                own_edge: OwnEdge::Min,
                target: 0.0,
                is_grid: false,
            }),
            stick_y: None,
        };
        // 10 is past engage (8) but inside release (12): the hold stands.
        let inside = snap_move(dragged(10.0, 500.0), &[neighbour()], None, &config, Some(&held));
        assert_eq!(
            inside.frame.min_x(),
            0.0,
            "equal thresholds would let it oscillate here"
        );
        // 13 is past release: it breaks away and lands exactly under the pointer.
        let outside = snap_move(dragged(13.0, 500.0), &[neighbour()], None, &config, Some(&held));
        assert_eq!(outside.frame.min_x(), 13.0, "breakaway is zero-drift");
    }

    #[test]
    fn a_hold_is_dropped_when_the_neighbour_it_pointed_at_is_gone() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let held = Resolution {
            frame: dragged(0.0, 500.0),
            guides: Vec::new(),
            stick_x: Some(Stick {
                own_edge: OwnEdge::Min,
                target: 0.0,
                is_grid: false,
            }),
            stick_y: None,
        };
        let orphaned = snap_move(dragged(5.0, 500.0), &[], None, &config, Some(&held));
        assert_eq!(
            orphaned.frame.min_x(),
            5.0,
            "a snap with no drawable guide is a snap to a coordinate nothing supports",
        );
    }

    #[test]
    fn a_held_snap_does_not_re_target_when_something_nearer_appears() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let held = Resolution {
            frame: dragged(0.0, 500.0),
            guides: Vec::new(),
            stick_x: Some(Stick {
                own_edge: OwnEdge::Min,
                target: 0.0,
                is_grid: false,
            }),
            stick_y: None,
        };
        // A second neighbour whose edge sits at 6, nearer than the held 0 — the hold still wins.
        let nearer = Rect::xywh(6.0, 900.0, 400.0, 300.0);
        let resolution = snap_move(
            dragged(7.0, 500.0),
            &[neighbour(), nearer],
            None,
            &config,
            Some(&held),
        );
        assert_eq!(
            resolution.frame.min_x(),
            0.0,
            "no mid-hold re-targeting; the feel stays deterministic"
        );
    }

    #[test]
    fn the_result_does_not_depend_on_the_order_the_neighbours_arrive_in() {
        let config = SnapConfig::default();
        let a = neighbour();
        let b = Rect::xywh(0.0, 900.0, 600.0, 300.0);
        let c = Rect::xywh(0.0, 1800.0, 200.0, 300.0);
        let forward = snap_move(dragged(3.0, 500.0), &[a, b, c], None, &config, None);
        let backward = snap_move(dragged(3.0, 500.0), &[c, b, a], None, &config, None);
        assert_eq!(forward.frame, backward.frame);
        assert_eq!(forward.guides.len(), backward.guides.len());
    }

    #[test]
    fn the_grid_is_a_fallback_and_never_competes_with_a_pane() {
        let config = SnapConfig::default();
        // 3 is within the grid's engage of 0 AND within the pane engage of the neighbour's edge.
        let with_pane = snap_move(dragged(3.0, 500.0), &[neighbour()], None, &config, None);
        assert_eq!(with_pane.stick_x.map(|stick| stick.is_grid), Some(false));
        // With no pane in range the lattice takes over.
        let alone = snap_move(dragged(3.0, 500.0), &[], None, &config, None);
        assert_eq!(alone.frame.min_x(), 0.0);
        assert_eq!(alone.stick_x.map(|stick| stick.is_grid), Some(true));
    }

    #[test]
    fn a_grid_snap_draws_no_guide() {
        let config = SnapConfig::default();
        let resolution = snap_move(dragged(3.0, 3.0), &[], None, &config, None);
        assert!(resolution.stick_x.is_some());
        assert!(resolution.guides.is_empty(), "the dot grid is its own affordance");
    }

    #[test]
    fn the_disabled_config_moves_nothing_at_all() {
        let proposed = dragged(3.0, 3.0);
        let free = snap_move(proposed, &[neighbour()], None, &SnapConfig::disabled(), None);
        assert_eq!(free.frame, proposed);
        assert!(free.stick_x.is_none() && free.stick_y.is_none());
    }

    #[test]
    fn the_viewport_offers_its_inset_edges_and_its_centreline() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let viewport = Rect::xywh(0.0, 0.0, 1600.0, 1000.0);
        // The inset left edge sits at the gutter, 16.
        let resolution = snap_move(dragged(19.0, 500.0), &[], Some(viewport), &config, None);
        assert_eq!(resolution.frame.min_x(), 16.0);
        let Some(guide) = resolution.guides.first() else {
            panic!("a viewport snap is drawable too");
        };
        assert_eq!(guide.kind, GuideKind::ViewportEdge);
        assert_eq!(guide.orientation, GuideOrientation::Vertical);
    }

    #[test]
    fn a_resize_moves_only_the_dragged_edge_and_leaves_the_pinned_one_alone() {
        let config = SnapConfig::default();
        let proposed = Rect::xywh(403.0, 500.0, 400.0, 300.0);
        let resolution =
            snap_resize_default(proposed, ResizeAnchor::Left, &[neighbour()], None, &config, None);
        assert_eq!(
            resolution.frame.max_x(),
            803.0,
            "the pinned right edge does not move"
        );
        assert_eq!(
            resolution.frame.min_x(),
            400.0,
            "and the dragged one lands on the neighbour"
        );
    }

    #[test]
    fn a_resize_candidate_that_would_squash_the_pane_is_discarded_rather_than_clamped() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        // The dragged left edge is three points from the neighbour's far edge at 400, but landing
        // there would leave a pane under this floor — so nothing engages at all.
        let proposed = Rect::xywh(403.0, 500.0, 170.0, 300.0);
        let floor = Size::new(200.0, 120.0);
        let resolution = snap_resize(
            proposed,
            ResizeAnchor::Left,
            &[neighbour()],
            None,
            floor,
            &config,
            None,
        );
        assert_eq!(
            resolution.frame, proposed,
            "a drawn guide must always be a true statement, so an impossible one is never offered",
        );
    }

    #[test]
    fn a_resize_ignores_centres_because_a_resize_aligns_edges() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        // The neighbour's centre is at 200; the dragged left edge sits 2 points from it.
        let proposed = Rect::xywh(202.0, 500.0, 400.0, 300.0);
        let resolution =
            snap_resize_default(proposed, ResizeAnchor::Left, &[neighbour()], None, &config, None);
        assert_eq!(resolution.frame.min_x(), 202.0);
    }

    #[test]
    fn a_guide_is_drawn_on_the_committed_coordinate_and_spans_every_agreeing_source() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let far_below = Rect::xywh(0.0, 2000.0, 400.0, 300.0);
        let resolution = snap_move(
            dragged(3.0, 500.0),
            &[neighbour(), far_below],
            None,
            &config,
            None,
        );
        let Some(guide) = resolution.guides.first() else {
            panic!("an engaged snap must be drawable");
        };
        assert_eq!(
            guide.position,
            resolution.frame.min_x(),
            "pixel-true on the committed frame"
        );
        assert_eq!(guide.start, 0.0, "the span reaches the topmost agreeing source");
        assert_eq!(guide.end, 2300.0, "and the bottommost");
    }

    #[test]
    fn both_axes_resolve_independently() {
        let config = SnapConfig {
            snaps_to_grid: false,
            ..SnapConfig::default()
        };
        let resolution = snap_move(dragged(3.0, 297.0), &[neighbour()], None, &config, None);
        assert_eq!(resolution.frame.min_x(), 0.0);
        assert_eq!(
            resolution.frame.min_y(),
            300.0,
            "the y axis found its own candidate"
        );
        // The dragged pane is the neighbour's size, so aligning its left edge aligns its centre and
        // its right edge too — three true statements on x, one on y. Every one of them is drawn,
        // because the grouping is by dragged edge and all three are distinct edges.
        let vertical = resolution
            .guides
            .iter()
            .filter(|guide| guide.orientation == GuideOrientation::Vertical)
            .count();
        assert_eq!(vertical, 3);
        assert_eq!(resolution.guides.len() - vertical, 1);
    }
}
