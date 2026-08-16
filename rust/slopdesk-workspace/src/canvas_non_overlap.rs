//! Non-overlap for a canvas drag: the dragged body slides flush along its neighbours instead of
//! landing on top of them, and on an insert-intent drop the neighbours part to make room.
//!
//! This runs STRICTLY AFTER [`crate::canvas_snap`], consuming the snapped frame as the dragged
//! body's target, and shares its gutter — so a box the snapper already put one gutter off a
//! neighbour is ALREADY at the non-overlap separation and the slide is a no-op there. The two
//! solvers reinforce; they never fight.
//!
//! ## Two modes, two mass models
//!
//! The two behaviours want OPPOSITE masses, so they are separate entry points.
//!
//! **Slide** — the live-drag default, every frame. The dragged body YIELDS: a swept AABB carries it
//! from its persisted origin to the snapped target against the gutter-inflated neighbours, and on
//! the earliest contact the into-face component is cancelled and the tangential remainder
//! re-swept — which is what glides the box flush along a neighbour and tucks it into an inside
//! corner. Only the dragged body moves.
//!
//! **Make-space** — commit only, the single drop. The NEIGHBOURS yield: the dragged body is pinned
//! at the target and a minimal-movement relaxation flows everything else apart to admit it. On an
//! infinite plane there is always room, so it converges; the iteration cap makes termination a
//! guarantee rather than an argument.
//!
//! ## Why the whole sweep is replayed every frame
//!
//! The sweep runs from the PERSISTED origin to the target, not from the last frame's result. That
//! makes the answer a pure function of the raw translation instead of an accumulation of it, which
//! is the only way the live preview and the committed frame can be the same rect — the drop
//! recomputes from the same two inputs the preview did.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::canvas_geometry::ResizeAnchor;
use crate::geometry::{Point, Rect, Size, sanitize, sanitize_preserving_size};

/// Which canvas object a collision body stands for.
///
/// A group body is the group's bounding box treated as one rigid box; its solved shift is
/// distributed to its members by the caller, which is how group-vs-group and pane-vs-group
/// non-overlap falls out of feeding group boxes into the SAME solver.
///
/// The derived order is the canonical processing order — panes before groups, then by id — and it
/// is what makes the solver independent of the order the bodies arrived in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum BodyId<Pane, Group> {
    /// An ungrouped pane.
    Pane(Pane),
    /// A group's bounding box.
    Group(Group),
}

/// One collision body: an ungrouped pane's frame, or a group's bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Body<Id> {
    /// Its identity, which is also its place in the canonical order.
    pub id: Id,
    /// Its current frame.
    pub rect: Rect,
}

impl<Id> Body<Id> {
    /// A body at a frame.
    pub const fn new(id: Id, rect: Rect) -> Self {
        Self { id, rect }
    }
}

/// Tuning, all in canvas points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NonOverlapConfig {
    /// The non-overlap gap. Derived from the snapper's gutter by the caller so the two cannot
    /// drift.
    pub gutter: f64,
    /// Swept back-off along the contact normal, so a box resting against a surface is not
    /// re-detected as a zero-distance hit on the next pass. Without it a slide catches on its own
    /// seam.
    pub skin: f64,
    /// Re-sweep cap. Each pass removes one contact axis and an inside corner needs two, so this is
    /// generous — but it is a hard bound, not a hope.
    pub max_slide_passes: u32,
    /// Iteration cap for the make-space relaxation. Same reasoning.
    pub max_relax_iterations: u32,
    /// How much of the target a drop must cover before the neighbours part. Below it the box merely
    /// rests flush, which is the slide's job.
    pub insert_coverage: f64,
    /// Master switch. Off, every entry point is the identity — the modifier-held escape hatch.
    pub enabled: bool,
}

impl Default for NonOverlapConfig {
    fn default() -> Self {
        Self {
            gutter: 16.0,
            skin: 0.1,
            max_slide_passes: 4,
            max_relax_iterations: 32,
            insert_coverage: 0.5,
            enabled: true,
        }
    }
}

impl NonOverlapConfig {
    /// Everything off.
    #[must_use]
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            ..Self::default()
        }
    }
}

/// The minimal translation that pushes one rect away from another.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Separation {
    /// The x component.
    pub dx: f64,
    /// The y component.
    pub dy: f64,
}

/// The minimal translation separating `a` from `b` by `gutter`, along whichever axis is cheaper, or
/// `None` when they are already that far apart.
///
/// The vector moves `a` AWAY from `b`; the relaxation splits it between the pair by inverse mass.
/// Two rects that merely touch — raw overlap zero — still get a full-gutter push, because touching
/// is not separation.
#[must_use]
pub fn separation(a: Rect, b: Rect, gutter: f64) -> Option<Separation> {
    let overlap_x = (a.max_x().min(b.max_x()) - a.min_x().max(b.min_x())) + gutter;
    let overlap_y = (a.max_y().min(b.max_y()) - a.min_y().max(b.min_y())) + gutter;
    if !(overlap_x > 0.0 && overlap_y > 0.0) {
        return None;
    }
    // The cheaper axis wins; on an exact tie the bigger centre offset decides, so a box dropped on a
    // perfect diagonal still leaves along one axis rather than jittering between them.
    let along_x = match overlap_x.partial_cmp(&overlap_y) {
        Some(Ordering::Less) => true,
        Some(Ordering::Equal) => (a.mid_x() - b.mid_x()).abs() >= (a.mid_y() - b.mid_y()).abs(),
        _ => false,
    };
    if along_x {
        Some(Separation {
            dx: if a.mid_x() <= b.mid_x() {
                -overlap_x
            } else {
                overlap_x
            },
            dy: 0.0,
        })
    } else {
        Some(Separation {
            dx: 0.0,
            dy: if a.mid_y() <= b.mid_y() {
                -overlap_y
            } else {
                overlap_y
            },
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ContactAxis {
    X,
    Y,
}

/// A displacement on the plane. The geometry module has no vector type on purpose — a point and a
/// translation are not the same thing, and only this solver needs the second one.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Vector {
    dx: f64,
    dy: f64,
}

impl Vector {
    fn length(self) -> f64 {
        self.dx.hypot(self.dy)
    }

    fn scaled(self, factor: f64) -> Self {
        Self {
            dx: self.dx * factor,
            dy: self.dy * factor,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Contact {
    time: f64,
    axis: ContactAxis,
    normal: Vector,
}

/// Swept point-versus-AABB by the slab method.
///
/// Returns the earliest time in `[0, 1)` at which a point moving by the velocity enters the box,
/// with the contact axis and the outward normal — or `None` when the path never enters it.
fn swept_center(center: Point, velocity: Vector, box_rect: Rect) -> Option<Contact> {
    // A zero-velocity axis is inside its slab for all time only if the point already lies STRICTLY
    // within it. Inclusive membership here froze a horizontal drag against a neighbour exactly one
    // gutter above — which is the steady state of every tidied grid, whose row pitch is exactly
    // height plus gutter. A centre sitting on the inflated boundary is one gutter clear on that
    // axis, so it must not block motion along the other one.
    let slab = |p: f64, v: f64, lo: f64, hi: f64| -> Option<(f64, f64)> {
        if v == 0.0 {
            return (p > lo && p < hi).then_some((f64::NEG_INFINITY, f64::INFINITY));
        }
        let t1 = (lo - p) / v;
        let t2 = (hi - p) / v;
        Some((t1.min(t2), t1.max(t2)))
    };
    let (x_entry, x_exit) = slab(center.x, velocity.dx, box_rect.min_x(), box_rect.max_x())?;
    let (y_entry, y_exit) = slab(center.y, velocity.dy, box_rect.min_y(), box_rect.max_y())?;
    let entry = x_entry.max(y_entry);
    let exit = x_exit.min(y_exit);
    // The slabs must overlap in time, the contact must start before the move ends, and the box must
    // still be ahead rather than already behind.
    if !(entry <= exit && entry < 1.0 && exit > 0.0) {
        return None;
    }
    let time = entry.max(0.0);
    if x_entry > y_entry {
        Some(Contact {
            time,
            axis: ContactAxis::X,
            normal: Vector {
                dx: if velocity.dx > 0.0 { -1.0 } else { 1.0 },
                dy: 0.0,
            },
        })
    } else {
        Some(Contact {
            time,
            axis: ContactAxis::Y,
            normal: Vector {
                dx: 0.0,
                dy: if velocity.dy > 0.0 { -1.0 } else { 1.0 },
            },
        })
    }
}

/// The earliest contact of the swept box against any body, each inflated by the box's half-extents
/// plus the gutter so the sweep reduces to a point against a Minkowski sum.
///
/// `bodies` must already be in canonical order: a tie in entry time keeps the body that came first,
/// which is what makes the choice deterministic rather than a function of the caller's array.
fn earliest_hit<Id>(
    origin: Point,
    size: Size,
    velocity: Vector,
    bodies: &[&Body<Id>],
    config: &NonOverlapConfig,
) -> Option<Contact> {
    let center = Point::new(origin.x + size.width / 2.0, origin.y + size.height / 2.0);
    let mut best: Option<Contact> = None;
    for body in bodies {
        let expanded = body.rect.outset_by(
            size.width / 2.0 + config.gutter,
            size.height / 2.0 + config.gutter,
        );
        let Some(hit) = swept_center(center, velocity, expanded) else {
            continue;
        };
        if best.is_none_or(|current| hit.time < current.time - 1e-9) {
            best = Some(hit);
        }
    }
    best
}

/// Pops a box gutter-clear of every body, a few passes so one wedged among several is fully freed.
fn depenetrate<Id>(origin: Point, size: Size, bodies: &[&Body<Id>], config: &NonOverlapConfig) -> Point {
    let mut here = origin;
    for _ in 0..config.max_slide_passes {
        let mut moved = false;
        for body in bodies {
            let boxed = Rect::xywh(here.x, here.y, size.width, size.height);
            if let Some(sep) = separation(boxed, body.rect, config.gutter) {
                here = Point::new(here.x + sep.dx, here.y + sep.dy);
                moved = true;
            }
        }
        if !moved {
            break;
        }
    }
    here
}

/// Slides the dragged body to `snapped` without overlapping anything, gliding it flush one gutter
/// off each neighbour.
///
/// `from` is the body's PERSISTED origin — the fixed gesture start — so the whole sweep is replayed
/// from there every frame and the result never depends on the path taken to get here. Identity when
/// disabled, when there is nothing to hit, or when the box is degenerate.
#[must_use]
pub fn slide<Id: Ord>(snapped: Rect, from: Point, bodies: &[Body<Id>], config: &NonOverlapConfig) -> Rect {
    let size = snapped.size;
    if !config.enabled || bodies.is_empty() || !(size.width > 0.0 && size.height > 0.0) {
        return snapped;
    }
    let mut sorted: Vec<&Body<Id>> = bodies.iter().collect();
    sorted.sort_by(|a, b| a.id.cmp(&b.id));

    // The START is depenetrated first: if the persisted origin already overlaps something — the
    // feature was just switched on, or a neighbour arrived from a peer — the box is popped clear
    // before the sweep. In the steady state every committed frame is already non-overlapping and
    // this does nothing.
    let mut here = depenetrate(from, size, &sorted, config);

    let mut remaining = Vector {
        dx: snapped.min_x() - here.x,
        dy: snapped.min_y() - here.y,
    };
    for _ in 0..config.max_slide_passes {
        if remaining.length() <= config.skin {
            break;
        }
        let Some(hit) = earliest_hit(here, size, remaining, &sorted, config) else {
            here = Point::new(here.x + remaining.dx, here.y + remaining.dy);
            break;
        };
        // Advance to the contact, then back off along the outward normal so the same surface is not
        // re-detected next pass.
        here = Point::new(
            here.x + remaining.dx * hit.time + hit.normal.dx * config.skin,
            here.y + remaining.dy * hit.time + hit.normal.dy * config.skin,
        );
        // Cancel the into-face component and keep the tangential remainder. That remainder IS the
        // slide.
        let leftover = remaining.scaled(1.0 - hit.time);
        remaining = match hit.axis {
            ContactAxis::X => Vector { dx: 0.0, ..leftover },
            ContactAxis::Y => Vector { dy: 0.0, ..leftover },
        };
    }
    // The safety net: any residual penetration — the pass cap reached inside a dense pocket — is
    // cleared, so the OUTPUT never overlaps whatever happened in between. A no-op for a clean slide.
    let settled = depenetrate(here, size, &sorted, config);
    sanitize_preserving_size(Rect::xywh(settled.x, settled.y, size.width, size.height))
}

/// One body mid-relaxation. The pinned flag is the mass model: a pinned body has infinite mass and
/// takes none of the push.
struct Working<Id> {
    id: Id,
    rect: Rect,
    pinned: bool,
}

/// Pins one body and flows every other apart until nothing overlaps.
///
/// Gate-free on purpose: [`make_space`] uses it behind the insert-intent gate, but a resize push —
/// a grown pane must shove whatever it grew into, with no intent to read — and a within-group
/// reflow use it directly. Returns the pinned body plus every body that actually moved, keyed for
/// one atomic write.
#[must_use]
pub fn separate<Id: Ord + Clone>(
    pinned_id: &Id,
    pinned_rect: Rect,
    bodies: &[Body<Id>],
    config: &NonOverlapConfig,
) -> BTreeMap<Id, Rect> {
    let mut frames = BTreeMap::new();
    if !config.enabled {
        frames.insert(pinned_id.clone(), pinned_rect);
        return frames;
    }
    // Any stale free copy of the pinned body is dropped: it exists once, at the target, immovable.
    let mut working: Vec<Working<Id>> = bodies
        .iter()
        .filter(|body| body.id != *pinned_id)
        .map(|body| {
            Working {
                id: body.id.clone(),
                rect: body.rect,
                pinned: false,
            }
        })
        .collect();
    working.push(Working {
        id: pinned_id.clone(),
        rect: pinned_rect,
        pinned: true,
    });
    working.sort_by(|a, b| a.id.cmp(&b.id));

    for _ in 0..config.max_relax_iterations {
        let mut separated_any = false;
        let mut index = 0;
        while let Some((head, tail)) = working.split_at_mut_checked(index + 1) {
            let Some(first) = head.last_mut() else { break };
            for second in &mut *tail {
                let Some(sep) = separation(first.rect, second.rect, config.gutter) else {
                    continue;
                };
                let weight_first = f64::from(u8::from(!first.pinned));
                let weight_second = f64::from(u8::from(!second.pinned));
                let total = weight_first + weight_second;
                if total <= 0.0 {
                    // Two pinned bodies cannot be separated. Only one is ever pinned, so this is
                    // unreachable in practice and merely refuses to divide by zero.
                    continue;
                }
                separated_any = true;
                let share_first = weight_first / total;
                let share_second = weight_second / total;
                first.rect = first.rect.offset_by(sep.dx * share_first, sep.dy * share_first);
                second.rect = second
                    .rect
                    .offset_by(-sep.dx * share_second, -sep.dy * share_second);
            }
            index += 1;
        }
        if !separated_any {
            break;
        }
    }

    let prior: BTreeMap<&Id, Rect> = bodies.iter().map(|body| (&body.id, body.rect)).collect();
    frames.insert(pinned_id.clone(), sanitize_preserving_size(pinned_rect));
    for entry in working.iter().filter(|entry| !entry.pinned) {
        if prior
            .get(&entry.id)
            .is_some_and(|before| !approx_equal(*before, entry.rect))
        {
            frames.insert(entry.id.clone(), sanitize_preserving_size(entry.rect));
        }
    }
    frames
}

/// If a drop at `target` reads as an insert, pins the dragged body there and parts the neighbours
/// to admit it.
///
/// `None` means intent did NOT fire — the box is merely resting against a boundary — and the caller
/// then commits the slid frame with nothing else moved. Always `None` when disabled.
#[must_use]
pub fn make_space<Id: Ord + Clone>(
    target: Rect,
    dragged_id: &Id,
    bodies: &[Body<Id>],
    config: &NonOverlapConfig,
) -> Option<BTreeMap<Id, Rect>> {
    if !config.enabled {
        return None;
    }
    // Only bodies the target genuinely overlaps count. A within-gutter brush is resting flush, which
    // is the slide's job, not an insert.
    let overlappers: Vec<&Body<Id>> = bodies
        .iter()
        .filter(|body| intersection_area(target, body.rect) > 0.0)
        .collect();
    if overlappers.is_empty() || !intent_armed(target, &overlappers, config) {
        return None;
    }
    Some(separate(dragged_id, target, bodies, config))
}

/// Whether a drop reads as "insert me between these" rather than "rest me against one".
///
/// Armed only when coverage clears the threshold AND the target is either centred over a neighbour
/// or wedged between neighbours on two OPPOSING sides. Coverage alone would fire on a box merely
/// dropped onto a much larger one, which reads as landing on it, not as parting it.
fn intent_armed<Id>(target: Rect, overlappers: &[&Body<Id>], config: &NonOverlapConfig) -> bool {
    let coverage = overlappers
        .iter()
        .map(|body| coverage_fraction(target, body.rect))
        .fold(0.0_f64, f64::max);
    if coverage < config.insert_coverage {
        return false;
    }
    let center_inside = overlappers.iter().any(|body| body.rect.contains(target.center()));
    let left = overlappers
        .iter()
        .any(|body| body.rect.mid_x() < target.mid_x() && vertical_spans_overlap(body.rect, target));
    let right = overlappers
        .iter()
        .any(|body| body.rect.mid_x() > target.mid_x() && vertical_spans_overlap(body.rect, target));
    let above = overlappers
        .iter()
        .any(|body| body.rect.mid_y() < target.mid_y() && horizontal_spans_overlap(body.rect, target));
    let below = overlappers
        .iter()
        .any(|body| body.rect.mid_y() > target.mid_y() && horizontal_spans_overlap(body.rect, target));
    center_inside || (left && right) || (above && below)
}

/// Clamps a resized frame so its MOVING edges never cross into a body.
///
/// Each growing edge stops one gutter short of the nearest body it shares a perpendicular span
/// with, floored so the frame never drops below `min_size` — and the pinned edge never moves,
/// because only the moving ones are touched. The slide's analogue for a resize: the box yields
/// rather than overlapping. Order-independent, since each edge takes a min or max over every body.
/// SHRINKING is never constrained: a receding edge moves away from its neighbours.
#[must_use]
pub fn clamp_resize<Id>(
    frame: Rect,
    anchor: ResizeAnchor,
    bodies: &[Body<Id>],
    min_size: Size,
    config: &NonOverlapConfig,
) -> Rect {
    if !config.enabled || bodies.is_empty() {
        return frame;
    }
    let gutter = config.gutter;
    let mut left = frame.min_x();
    let mut right = frame.max_x();
    let mut top = frame.min_y();
    let mut bottom = frame.max_y();
    for body in bodies {
        let other = body.rect;
        // Sharing a span is STRICT: two boxes that merely touch along an axis do not collide on the
        // perpendicular one.
        let shares_vertical = frame.min_y() < other.max_y() && other.min_y() < frame.max_y();
        let shares_horizontal = frame.min_x() < other.max_x() && other.min_x() < frame.max_x();
        if anchor.moves_right() && shares_vertical && other.min_x() > left && other.min_x() - gutter < right {
            right = (left + min_size.width).max(right.min(other.min_x() - gutter));
        }
        if anchor.moves_left() && shares_vertical && other.max_x() < right && other.max_x() + gutter > left {
            left = (right - min_size.width).min(left.max(other.max_x() + gutter));
        }
        if anchor.moves_bottom()
            && shares_horizontal
            && other.min_y() > top
            && other.min_y() - gutter < bottom
        {
            bottom = (top + min_size.height).max(bottom.min(other.min_y() - gutter));
        }
        if anchor.moves_top() && shares_horizontal && other.max_y() < bottom && other.max_y() + gutter > top {
            top = (bottom - min_size.height).min(top.max(other.max_y() + gutter));
        }
    }
    sanitize(Rect::xywh(left, top, right - left, bottom - top))
}

fn intersection_area(a: Rect, b: Rect) -> f64 {
    a.intersection(b).map_or(0.0, Rect::area)
}

/// Overlap area over the SMALLER of the two rects' dimensions, so a small box fully inside a large
/// one still reads as complete coverage rather than as a rounding error.
fn coverage_fraction(target: Rect, other: Rect) -> f64 {
    let denominator = target.size.width.min(other.size.width) * target.size.height.min(other.size.height);
    if denominator > 0.0 {
        intersection_area(target, other) / denominator
    } else {
        0.0
    }
}

const fn vertical_spans_overlap(a: Rect, b: Rect) -> bool {
    a.min_y() < b.max_y() && b.min_y() < a.max_y()
}

const fn horizontal_spans_overlap(a: Rect, b: Rect) -> bool {
    a.min_x() < b.max_x() && b.min_x() < a.max_x()
}

fn approx_equal(a: Rect, b: Rect) -> bool {
    (a.min_x() - b.min_x()).abs() < 0.01
        && (a.min_y() - b.min_y()).abs() < 0.01
        && (a.size.width - b.size.width).abs() < 0.01
        && (a.size.height - b.size.height).abs() < 0.01
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the fixtures are exact multiples of the config's own gutter, and a missing frame is a \
                  test failure with nothing to return"
    )]

    use super::{Body, BodyId, NonOverlapConfig, clamp_resize, make_space, separate, separation, slide};
    use crate::canvas_geometry::ResizeAnchor;
    use crate::geometry::{Point, Rect, Size};

    fn config() -> NonOverlapConfig {
        NonOverlapConfig::default()
    }

    fn body(id: u32, x: f64, y: f64) -> Body<u32> {
        Body::new(id, Rect::xywh(x, y, 400.0, 300.0))
    }

    #[test]
    fn a_box_dragged_into_a_neighbour_stops_one_gutter_short_of_it() {
        let obstacle = body(1, 500.0, 0.0);
        // Aimed straight through the obstacle from its left.
        let target = Rect::xywh(600.0, 0.0, 400.0, 300.0);
        let slid = slide(target, Point::ZERO, &[obstacle], &config());
        assert!(
            slid.max_x() <= 500.0 - config().gutter + 0.2,
            "it stopped at {} rather than one gutter short of 500",
            slid.max_x(),
        );
    }

    #[test]
    fn a_blocked_drag_keeps_its_tangential_motion_and_glides_flush() {
        let obstacle = body(1, 500.0, 0.0);
        // Into the obstacle horizontally, but also well downward: the into-face part is cancelled,
        // the tangential part survives.
        let target = Rect::xywh(600.0, 250.0, 400.0, 300.0);
        let slid = slide(target, Point::ZERO, &[obstacle], &config());
        assert!(
            slid.max_x() <= 500.0 - config().gutter + 0.2,
            "still blocked on x"
        );
        assert!(
            slid.min_y() > 200.0,
            "but it kept sliding down, reaching {}",
            slid.min_y()
        );
    }

    #[test]
    fn an_unobstructed_drag_lands_exactly_on_its_target() {
        let obstacle = body(1, 5000.0, 5000.0);
        let target = Rect::xywh(600.0, 0.0, 400.0, 300.0);
        assert_eq!(slide(target, Point::ZERO, &[obstacle], &config()), target);
    }

    #[test]
    fn a_box_that_starts_already_overlapping_is_popped_clear_before_it_moves() {
        let obstacle = body(1, 0.0, 0.0);
        // The persisted origin sits right on top of the obstacle, and the target barely moves.
        let target = Rect::xywh(10.0, 0.0, 400.0, 300.0);
        let slid = slide(target, Point::ZERO, &[obstacle], &config());
        assert!(
            separation(slid, obstacle.rect, config().gutter).is_none(),
            "the output overlapped at {slid:?}",
        );
    }

    #[test]
    fn the_output_never_overlaps_however_dense_the_pocket() {
        let bodies = [
            body(1, 500.0, 0.0),
            body(2, 500.0, 400.0),
            body(3, -500.0, 0.0),
            body(4, 0.0, 400.0),
        ];
        let slid = slide(
            Rect::xywh(450.0, 350.0, 400.0, 300.0),
            Point::ZERO,
            &bodies,
            &config(),
        );
        for obstacle in &bodies {
            assert!(
                separation(slid, obstacle.rect, config().gutter).is_none(),
                "the slid frame {slid:?} still overlaps {:?}",
                obstacle.rect,
            );
        }
    }

    #[test]
    fn the_slide_does_not_depend_on_the_order_the_bodies_arrive_in() {
        let a = body(1, 500.0, 0.0);
        let b = body(2, 500.0, 400.0);
        let c = body(3, -500.0, 0.0);
        let target = Rect::xywh(450.0, 350.0, 400.0, 300.0);
        let forward = slide(target, Point::ZERO, &[a, b, c], &config());
        let backward = slide(target, Point::ZERO, &[c, b, a], &config());
        assert_eq!(forward, backward);
    }

    #[test]
    fn a_disabled_config_is_the_identity() {
        let obstacle = body(1, 500.0, 0.0);
        let target = Rect::xywh(600.0, 0.0, 400.0, 300.0);
        let disabled = NonOverlapConfig::disabled();
        assert_eq!(slide(target, Point::ZERO, &[obstacle], &disabled), target);
        assert!(make_space(target, &9, &[obstacle], &disabled).is_none());
        assert_eq!(
            clamp_resize(
                target,
                ResizeAnchor::Right,
                &[obstacle],
                Size::new(160.0, 120.0),
                &disabled
            ),
            target,
        );
    }

    #[test]
    fn a_touching_pair_is_still_pushed_a_full_gutter_apart() {
        let a = Rect::xywh(0.0, 0.0, 400.0, 300.0);
        let b = Rect::xywh(400.0, 0.0, 400.0, 300.0);
        let Some(sep) = separation(a, b, 16.0) else {
            panic!("touching is not separated");
        };
        assert_eq!(sep.dx, -16.0);
        assert_eq!(sep.dy, 0.0);
    }

    #[test]
    fn boxes_a_full_gutter_apart_are_left_alone() {
        let a = Rect::xywh(0.0, 0.0, 400.0, 300.0);
        let b = Rect::xywh(416.0, 0.0, 400.0, 300.0);
        assert!(separation(a, b, 16.0).is_none());
    }

    #[test]
    fn resting_flush_against_one_neighbour_is_not_an_insert() {
        let obstacle = body(1, 0.0, 0.0);
        let target = Rect::xywh(416.0, 0.0, 400.0, 300.0);
        assert!(make_space(target, &9, &[obstacle], &config()).is_none());
    }

    #[test]
    fn a_drop_centred_on_a_neighbour_parts_it() {
        let obstacle = body(1, 0.0, 0.0);
        let target = Rect::xywh(20.0, 20.0, 400.0, 300.0);
        let Some(frames) = make_space(target, &9, &[obstacle], &config()) else {
            panic!("a centred drop is the canonical insert");
        };
        assert_eq!(
            frames.get(&9),
            Some(&target),
            "the dragged body is pinned where it was dropped"
        );
        let Some(moved) = frames.get(&1) else {
            panic!("the neighbour must have been displaced");
        };
        assert!(
            separation(target, *moved, config().gutter).is_none(),
            "the neighbour moved to {moved:?}, which still overlaps",
        );
    }

    #[test]
    fn a_wedge_between_two_opposing_neighbours_parts_them_both() {
        let bodies = [body(1, 0.0, 0.0), body(2, 300.0, 0.0)];
        let target = Rect::xywh(150.0, 0.0, 400.0, 300.0);
        let Some(frames) = make_space(target, &9, &bodies, &config()) else {
            panic!("a wedge between opposing neighbours is the board-reflow trigger");
        };
        for obstacle in &bodies {
            let Some(moved) = frames.get(&obstacle.id) else {
                panic!("body {} was not displaced", obstacle.id);
            };
            assert!(separation(target, *moved, config().gutter).is_none());
        }
    }

    #[test]
    fn the_relaxation_leaves_untouched_bodies_out_of_the_commit() {
        let bodies = [body(1, 0.0, 0.0), body(2, 5000.0, 5000.0)];
        let target = Rect::xywh(20.0, 20.0, 400.0, 300.0);
        let Some(frames) = make_space(target, &9, &bodies, &config()) else {
            panic!("a centred drop is an insert");
        };
        assert!(frames.contains_key(&1));
        assert!(!frames.contains_key(&2), "a body that never moved is not a write");
    }

    #[test]
    fn a_gate_free_separation_pushes_a_grown_pane_out_of_its_neighbour() {
        let bodies = [body(1, 0.0, 0.0)];
        // Barely overlapping: too little coverage for the insert gate, but the resize push does not
        // consult the gate at all.
        let grown = Rect::xywh(390.0, 0.0, 400.0, 300.0);
        assert!(make_space(grown, &9, &bodies, &config()).is_none());
        let frames = separate(&9, grown, &bodies, &config());
        let Some(moved) = frames.get(&1) else {
            panic!("the separation is unconditional");
        };
        assert!(separation(grown, *moved, config().gutter).is_none());
    }

    #[test]
    fn a_growing_edge_stops_flush_and_the_pinned_edge_never_moves() {
        let obstacle = body(1, 500.0, 0.0);
        let frame = Rect::xywh(0.0, 0.0, 600.0, 300.0);
        let clamped = clamp_resize(
            frame,
            ResizeAnchor::Right,
            &[obstacle],
            Size::new(160.0, 120.0),
            &config(),
        );
        assert_eq!(clamped.max_x(), 484.0, "one gutter short of the neighbour");
        assert_eq!(clamped.min_x(), 0.0, "the pinned edge is untouched");
    }

    #[test]
    fn a_shrinking_edge_is_never_constrained() {
        let obstacle = body(1, 500.0, 0.0);
        let frame = Rect::xywh(0.0, 0.0, 200.0, 300.0);
        let clamped = clamp_resize(
            frame,
            ResizeAnchor::Right,
            &[obstacle],
            Size::new(160.0, 120.0),
            &config(),
        );
        assert_eq!(clamped, frame);
    }

    #[test]
    fn a_neighbour_sharing_no_perpendicular_span_does_not_block_the_edge() {
        // Directly to the right, but far below: the vertical spans do not meet.
        let obstacle = body(1, 500.0, 5000.0);
        let frame = Rect::xywh(0.0, 0.0, 600.0, 300.0);
        let clamped = clamp_resize(
            frame,
            ResizeAnchor::Right,
            &[obstacle],
            Size::new(160.0, 120.0),
            &config(),
        );
        assert_eq!(clamped, frame);
    }

    #[test]
    fn the_clamp_never_pushes_a_pane_below_its_floor() {
        let obstacle = body(1, 100.0, 0.0);
        let frame = Rect::xywh(0.0, 0.0, 600.0, 300.0);
        let floor = Size::new(160.0, 120.0);
        let clamped = clamp_resize(frame, ResizeAnchor::Right, &[obstacle], floor, &config());
        assert_eq!(clamped.size.width, 160.0, "the floor wins over the neighbour");
    }

    #[test]
    fn panes_sort_before_groups_so_the_processing_order_is_canonical() {
        let mut ids = [
            BodyId::<u32, u32>::Group(0),
            BodyId::Pane(7),
            BodyId::Group(9),
            BodyId::Pane(1),
        ];
        ids.sort_unstable();
        assert_eq!(ids, [
            BodyId::Pane(1),
            BodyId::Pane(7),
            BodyId::Group(0),
            BodyId::Group(9)
        ],);
    }
}
