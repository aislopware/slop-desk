//! What the cursor sampler DECIDES, with the framework reads taken out.
//!
//! The deleted `CursorSampler.swift` (docs/61 §1) used to be a 389-line Swift class in which four
//! separate rules were tangled with two `AppKit` reads and a `dlsym`: when to go to the main thread
//! for a fresh shape, where the pointer is in the captured window's space, which id a shape gets,
//! and what pixel size to render it at. None of the four needs a framework — they are functions
//! over numbers and bytes — and none of them was tested, because the file that held them could only
//! run under an `AppKit` run loop.
//!
//! They are here instead, in a crate that `forbid`s `unsafe` and runs headless. The reads they used
//! to be tangled with live in `slopdesk-apple-cursor` (the shape) and
//! `slopdesk_posix::dynsym::cursor_seed` (the window server's change counter), and
//! `slopdesk-ffi`'s `cursor_sampler` is the handle that drives all three from one place.
//!
//! ## The one rule that is NOT here
//! Reading `NSEvent.mouseLocation` at 120 Hz off the main thread. That is the hot path's whole
//! reason to exist — a main-thread window raise must not be able to freeze the pointer — and it
//! stays a window-server query in the sampler's face. What crosses into [`window_position`] is the
//! two numbers it answered.

use std::collections::HashMap;

use crate::cursor::CursorShapeMessage;
use crate::fragment::MAX_DATAGRAM_SIZE;
use crate::geometry::{VideoPoint, VideoRect};

/// The single-datagram budget for a cursor shape's PNG.
///
/// A shape bigger than this would be IP-fragmented, and losing ANY fragment loses the whole shape —
/// which costs a round trip through the client's re-request path. So a bitmap that misses this is
/// rendered smaller until it fits, rather than sent and hoped for.
pub const MAX_SHAPE_BITMAP_BYTES: usize = MAX_DATAGRAM_SIZE - CursorShapeMessage::HEADER_SIZE;

/// Should this tick hop to the main thread for a fresh cursor shape?
///
/// Two cadences, picked by whether the window server's cursor SEED is readable:
///
/// - **Seed readable.** Refresh the same tick it changes — detection within one 120 Hz tick, so the
///   shape never visibly lags the pointer — plus a slow safety refresh while it is stable, because
///   the screen height the position math needs is read on the same trip and nothing bumps the seed
///   when a display changes.
/// - **Seed absent.** An unconditional every-Nth-tick cadence. Worst-case detection becomes the
///   cadence plus the main queue's delay, which is the price of the private symbol being gone.
///
/// The FIRST readable seed always refreshes: `last_seed` starts as `None`, which differs from every
/// seed. That first refresh is what primes the cached shape and screen height, and the position
/// path stays silent until it lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShapeRefreshPolicy {
    last_seed: Option<i32>,
    fallback_divisor: u64,
    safety_divisor: u64,
}

impl ShapeRefreshPolicy {
    /// Every 4th tick — ~30 Hz against a 120 Hz sampler.
    pub const DEFAULT_FALLBACK_DIVISOR: u64 = 4;
    /// Every 120th tick — ~1 Hz against a 120 Hz sampler.
    pub const DEFAULT_SAFETY_DIVISOR: u64 = 120;

    /// The policy the video host runs.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_seed: None,
            fallback_divisor: Self::DEFAULT_FALLBACK_DIVISOR,
            safety_divisor: Self::DEFAULT_SAFETY_DIVISOR,
        }
    }

    /// A policy with explicit cadences, for a test that does not want to count to 120.
    ///
    /// A zero divisor is raised to 1 — "every tick" — because the alternative is a remainder by
    /// zero, and there is no cadence a caller could mean by zero that is not that one.
    #[must_use]
    pub const fn with_divisors(fallback_divisor: u64, safety_divisor: u64) -> Self {
        Self {
            last_seed: None,
            fallback_divisor: if fallback_divisor == 0 {
                1
            } else {
                fallback_divisor
            },
            safety_divisor: if safety_divisor == 0 { 1 } else { safety_divisor },
        }
    }

    /// The seed this policy last acted on, or `None` before the first readable one.
    #[must_use]
    pub const fn last_seed(&self) -> Option<i32> {
        self.last_seed
    }

    /// The decision for one tick.
    pub fn should_refresh(&mut self, seed: Option<i32>, tick: u64) -> bool {
        let Some(seed) = seed else {
            return tick.is_multiple_of(self.fallback_divisor);
        };
        if self.last_seed != Some(seed) {
            self.last_seed = Some(seed);
            return true;
        }
        tick.is_multiple_of(self.safety_divisor)
    }
}

impl Default for ShapeRefreshPolicy {
    fn default() -> Self {
        Self::new()
    }
}

/// Where the pointer sits inside the captured window, and whether it is over it at all.
///
/// Two coordinate spaces meet here and the conversion is the whole function. The mouse arrives in
/// global **Cocoa** points — origin bottom-left, +Y up — because that is the space the off-main
/// window-server query answers in. The captured window's bounds are tracked in **CG** points —
/// origin top-left, +Y down — because that is the space the capture and every geometry watcher use.
/// Flipping the mouse's y through the primary display's height puts both in CG, and subtracting the
/// window's origin makes the result window-relative, which is what the client composites against.
///
/// The flip uses the PRIMARY display's height whatever screen the pointer is on: CG's global space
/// is anchored to that one display's top-left, so a second monitor's own height is not part of the
/// conversion. Getting this wrong shows up only on a multi-display host, and only as a constant
/// vertical offset.
///
/// `visible` is INCLUSIVE at both edges — a pointer exactly on the window's right or bottom edge is
/// over the window. The client draws nothing when this is false, so the alternative would blink the
/// pointer out for the row of points a person drags along an edge.
#[must_use]
pub fn window_position(
    mouse_cocoa: VideoPoint,
    primary_height: f64,
    bounds: VideoRect,
) -> (VideoPoint, bool) {
    let cg_y = primary_height - mouse_cocoa.y;
    let x = mouse_cocoa.x - bounds.origin.x;
    let y = cg_y - bounds.origin.y;
    let visible = x >= 0.0 && y >= 0.0 && x <= bounds.size.width && y <= bounds.size.height;
    (VideoPoint::new(x, y), visible)
}

/// A shape's CONTENT, as the thing two reads of the same cursor compare equal on.
///
/// Keyed on the bitmap bytes rather than any framework object's identity, because the system-wide
/// cursor read hands back a freshly built object every time: identity would mint a new id on every
/// refresh, and each new id ships a bitmap. The hotspot joins the key because two cursors can share
/// an image and click in different places.
///
/// The hotspot's `f64`s enter the key as their BIT patterns, so `-0.0` and `0.0` would be different
/// shapes. Harmless — a hotspot is a small non-negative integer in practice — and the alternative,
/// normalising, would be inventing an equivalence the framework never claimed.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ShapeKey {
    bitmap: Vec<u8>,
    hotspot_x: u64,
    hotspot_y: u64,
}

/// The mapping from a cursor's content to the small integer the wire carries for it.
///
/// Bounded by the OS's cursor repertoire — arrow, I-beam, hand, the resize variants, a handful of
/// app-specific ones — so a few dozen entries over a session, and it holds each shape's bytes so
/// that the comparison is exact rather than a hash that could collide two cursors into one for the
/// session's life.
#[derive(Clone, Debug, Default)]
pub struct ShapeTable {
    ids: HashMap<ShapeKey, u16>,
    next: u16,
}

impl ShapeTable {
    /// An empty table.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// How many distinct shapes have been seen.
    #[must_use]
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    /// Whether nothing has been seen yet.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// The id for this shape, and whether this call is the one that MINTED it.
    ///
    /// The flag is what makes the bitmap cross the wire exactly once: the caller renders and ships
    /// only on a mint, and every later sighting of the same cursor costs the two bytes of an id.
    ///
    /// Ids wrap rather than saturate. Wrapping needs 65 536 distinct shapes in one session to
    /// reach, which no cursor repertoire approaches; saturating would instead make every shape
    /// past the last one share an id, which is the failure that shows a stale pointer forever.
    pub fn intern(&mut self, bitmap: &[u8], hotspot: VideoPoint) -> (u16, bool) {
        let key = ShapeKey {
            bitmap: bitmap.to_vec(),
            hotspot_x: hotspot.x.to_bits(),
            hotspot_y: hotspot.y.to_bits(),
        };
        if let Some(&id) = self.ids.get(&key) {
            return (id, false);
        }
        let id = self.next;
        self.next = self.next.wrapping_add(1);
        self.ids.insert(key, id);
        (id, true)
    }
}

/// The pixel sizes to try rendering a shape at, largest first.
///
/// ## Why a ladder rather than a size
/// The budget is a byte count and the input is a picture, so the only way to know whether a size
/// fits is to encode it. This answers the sequence of sizes to encode, in order, and the caller
/// stops at the first PNG within [`MAX_SHAPE_BITMAP_BYTES`] — which keeps the decision here, where
/// it can be tested, and leaves the encoder with nothing to decide.
///
/// ## Why it does not start at the native size
/// Some system cursors hand back an enormous native bitmap — measured at 583 KB on one host with a
/// large-pointer setting — and halving down from there to reach the budget lands on a tiny, blurry
/// cursor after about nine renders. The ladder starts at the LOGICAL size doubled, which is what a
/// 2× display actually shows, capped to the native size so nothing is ever upscaled. From there it
/// shrinks about 20% a step rather than halving, so a dense cursor gives up a little sharpness
/// instead of most of it.
///
/// ## The shape of the sequence
/// At most [`LADDER_STEPS`] entries; it stops early once it has offered the floor. Aspect is
/// preserved by fixing the LONG side to the step's target and scaling the other by integer
/// division — the truncation is the wire's, kept exactly as the Swift computed it, so a cursor that
/// rendered 24×23 before renders 24×23 now.
///
/// Both dimensions are at least 1: a zero-pixel bitmap is not a smaller cursor, it is a failed
/// render that the encoder would report as success.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "the truncation IS the size the wire has always carried; rounding would move rendered cursors"
)]
pub fn render_ladder(
    logical_long_side: f64,
    native_width: usize,
    native_height: usize,
) -> Vec<(usize, usize)> {
    let native_width = native_width.max(1);
    let native_height = native_height.max(1);
    let long_side = native_width.max(native_height);
    // NOT a `clamp`: the floor is applied BEFORE the native ceiling, so a cursor whose native
    // bitmap is smaller than the floor renders at its native size rather than being upscaled to
    // eight pixels — and `clamp` would panic outright on that pair.
    let mut target = retina_target(logical_long_side)
        .max(MIN_TARGET)
        .min(long_side)
        .max(1);

    let mut steps = Vec::with_capacity(LADDER_STEPS);
    for _ in 0..LADDER_STEPS {
        steps.push((
            (native_width * target / long_side).max(1),
            (native_height * target / long_side).max(1),
        ));
        if target <= MIN_TARGET {
            break;
        }
        target = shrunk(target).max(MIN_TARGET);
    }
    steps
}

/// How many sizes the ladder will ever offer.
///
/// A bound rather than a computed length: the shrink is multiplicative, so a big enough native
/// bitmap would take dozens of steps to reach the floor, and every step is a render. Sixteen is
/// where the Swift stopped, and past it the caller ships the smallest thing it managed to encode
/// even though it misses the budget — a shape that may fragment beats no pointer at all.
pub const LADDER_STEPS: usize = 16;

/// The smallest edge the ladder will render at. Below this a cursor is not a cursor.
const MIN_TARGET: usize = 8;

/// The logical long side at 2×, rounded up — what a Retina display actually shows.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "a float-to-int `as` saturates, which is the clamp this wants for a non-finite or absurd size"
)]
fn retina_target(logical_long_side: f64) -> usize {
    // A non-finite or negative size answers 0 through the saturating cast, and the caller's clamp
    // raises it to the floor — so a garbage size renders a small cursor rather than trapping.
    (logical_long_side * 2.0).ceil() as usize
}

/// One step down the ladder: about 20% smaller, truncated toward zero.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss,
    reason = "the ladder's steps are the Swift's, arithmetic included, so the sizes do not move"
)]
fn shrunk(target: usize) -> usize {
    (target as f64 * 0.8) as usize
}

#[cfg(test)]
mod tests {
    use super::{
        LADDER_STEPS, MAX_SHAPE_BITMAP_BYTES, ShapeRefreshPolicy, ShapeTable, render_ladder, window_position,
    };
    use crate::geometry::{VideoPoint, VideoRect};

    // ------------------------------------------------------------------ policy

    /// The first readable seed refreshes whatever the tick is. That refresh is the PRIME — until it
    /// lands the position path emits nothing — so a policy that waited for the safety cadence would
    /// start the session with up to a second of no pointer.
    #[test]
    fn the_very_first_readable_seed_refreshes() {
        let mut policy = ShapeRefreshPolicy::new();
        assert!(policy.should_refresh(Some(6001), 1));
        assert_eq!(policy.last_seed(), Some(6001));
    }

    /// A seed that has not moved does not refresh, except on the slow safety tick. This is the
    /// common case by far — the cursor keeps its shape for seconds at a time — and every refresh it
    /// skips is a main-thread hop the window raise does not have to compete with.
    #[test]
    fn a_stable_seed_refreshes_only_on_the_safety_tick() {
        let mut policy = ShapeRefreshPolicy::with_divisors(4, 10);
        assert!(policy.should_refresh(Some(7), 1));
        for tick in 2..10 {
            assert!(!policy.should_refresh(Some(7), tick), "tick {tick} refreshed");
        }
        assert!(policy.should_refresh(Some(7), 10));
        assert!(policy.should_refresh(Some(7), 20));
    }

    /// A seed CHANGE refreshes on that very tick, not on the next cadence boundary — the whole
    /// reason the seed is read at all.
    #[test]
    fn a_changed_seed_refreshes_on_that_tick() {
        let mut policy = ShapeRefreshPolicy::with_divisors(4, 1_000);
        assert!(policy.should_refresh(Some(1), 1));
        assert!(!policy.should_refresh(Some(1), 2));
        assert!(policy.should_refresh(Some(2), 3));
        assert!(!policy.should_refresh(Some(2), 4));
        assert!(
            policy.should_refresh(Some(1), 5),
            "back to a seen seed is still a CHANGE"
        );
    }

    /// With no seed the cadence is unconditional, and the last seed is never recorded — so the tick
    /// the symbol comes back (it cannot, but the type allows it) still counts as a change.
    #[test]
    fn an_absent_seed_falls_back_to_a_fixed_cadence() {
        let mut policy = ShapeRefreshPolicy::with_divisors(4, 120);
        for tick in 1..=12 {
            assert_eq!(policy.should_refresh(None, tick), tick % 4 == 0, "tick {tick}");
        }
        assert_eq!(policy.last_seed(), None);
    }

    /// A zero divisor means every tick rather than a remainder by zero.
    #[test]
    fn a_zero_divisor_is_every_tick() {
        let mut policy = ShapeRefreshPolicy::with_divisors(0, 0);
        assert!(policy.should_refresh(None, 1));
        assert!(policy.should_refresh(None, 2));
    }

    // ---------------------------------------------------------------- position

    /// The Y-flip: a pointer at the BOTTOM of a full-height window is at the bottom in CG too, and
    /// a pointer at the top is at 0. An unflipped conversion passes both of these at the midpoint
    /// and fails at the edges, which is why the assertions are edges.
    #[test]
    fn cocoa_bottom_left_becomes_window_relative_top_left() {
        let bounds = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);
        let (top, _) = window_position(VideoPoint::new(10.0, 600.0), 600.0, bounds);
        assert_eq!(top, VideoPoint::new(10.0, 0.0));
        let (bottom, _) = window_position(VideoPoint::new(10.0, 0.0), 600.0, bounds);
        assert_eq!(bottom, VideoPoint::new(10.0, 600.0));
    }

    /// The window's origin is subtracted in CG space, so a window down and to the right of the
    /// display's corner reports the pointer relative to ITSELF.
    #[test]
    fn the_windows_origin_is_subtracted_in_cg_space() {
        let bounds = VideoRect::xywh(100.0, 50.0, 800.0, 600.0);
        let (point, visible) = window_position(VideoPoint::new(150.0, 900.0), 1000.0, bounds);
        assert_eq!(point, VideoPoint::new(50.0, 50.0));
        assert!(visible);
    }

    /// Outside on any side is invisible, and the edges themselves are INSIDE. The edge case is the
    /// one a person actually produces, by dragging along a window border.
    #[test]
    fn the_edges_are_inside_and_anything_past_them_is_not() {
        let bounds = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);
        let visible = |x: f64, y: f64| window_position(VideoPoint::new(x, 1000.0 - y), 1000.0, bounds).1;
        assert!(visible(0.0, 0.0), "top-left corner");
        assert!(visible(800.0, 600.0), "bottom-right corner");
        assert!(!visible(-0.001, 300.0), "left of the window");
        assert!(!visible(800.001, 300.0), "right of the window");
        assert!(!visible(400.0, -0.001), "above the window");
        assert!(!visible(400.0, 600.001), "below the window");
    }

    // ------------------------------------------------------------------- table

    /// The same bytes answer the same id and mint only once — the property the whole side channel
    /// rests on, because a mint is a bitmap on the wire.
    #[test]
    fn the_same_content_keeps_one_id_and_mints_once() {
        let mut table = ShapeTable::new();
        let hotspot = VideoPoint::new(1.0, 1.0);
        assert_eq!(table.intern(b"arrow", hotspot), (0, true));
        assert_eq!(table.intern(b"arrow", hotspot), (0, false));
        assert_eq!(table.intern(b"arrow", hotspot), (0, false));
        assert_eq!(table.len(), 1);
    }

    /// Different bitmaps, and the same bitmap with a different hotspot, are different shapes.
    #[test]
    fn content_and_hotspot_both_distinguish_a_shape() {
        let mut table = ShapeTable::new();
        assert_eq!(table.intern(b"arrow", VideoPoint::new(1.0, 1.0)), (0, true));
        assert_eq!(table.intern(b"ibeam", VideoPoint::new(1.0, 1.0)), (1, true));
        assert_eq!(table.intern(b"arrow", VideoPoint::new(4.0, 8.0)), (2, true));
        assert_eq!(table.intern(b"arrow", VideoPoint::new(1.0, 1.0)), (0, false));
        assert_eq!(table.len(), 3);
    }

    /// A fresh table is empty and starts at zero, so the first id on the wire is 0 rather than 1 —
    /// which is what the client's cache expects to be told about before any update references it.
    #[test]
    fn a_fresh_table_is_empty() {
        let table = ShapeTable::new();
        assert!(table.is_empty());
        assert_eq!(table.len(), 0);
    }

    // ------------------------------------------------------------------ ladder

    /// A normal cursor: 24 logical points off a 96-pixel native bitmap. The first step is the
    /// Retina size (48), not the native one — the point of the whole ladder.
    #[test]
    fn a_normal_cursor_starts_at_the_retina_size_not_the_native_one() {
        let ladder = render_ladder(24.0, 96, 96);
        assert_eq!(ladder.first(), Some(&(48, 48)));
        assert!(ladder.len() > 1);
    }

    /// A huge native bitmap is never the starting point, and is never exceeded either: the ladder
    /// caps at the native size so nothing is upscaled into blur.
    #[test]
    fn the_native_size_is_a_ceiling_never_a_starting_point() {
        let ladder = render_ladder(200.0, 32, 32);
        assert_eq!(
            ladder.first(),
            Some(&(32, 32)),
            "the logical size wanted 400, native is 32"
        );
        for &(w, h) in &ladder {
            assert!(w <= 32 && h <= 32);
        }
    }

    /// Aspect is preserved: a 2:1 native bitmap stays about 2:1 at every step, with the LONG side
    /// carrying the target.
    #[test]
    fn aspect_survives_every_step() {
        for &(w, h) in &render_ladder(64.0, 128, 64) {
            assert!(w >= h, "the long side must stay long");
            assert!(w.abs_diff(h * 2) <= 2, "{w}x{h} drifted from 2:1");
        }
    }

    /// It shrinks monotonically, bottoms out at the floor, and stops — no step is ever zero and no
    /// step repeats forever.
    #[test]
    fn the_ladder_descends_to_the_floor_and_stops() {
        let ladder = render_ladder(64.0, 128, 128);
        assert!(ladder.len() <= LADDER_STEPS);
        for pair in ladder.windows(2) {
            if let [(previous, _), (next, _)] = *pair {
                assert!(next <= previous, "{next} is not below {previous}");
            }
        }
        for &(w, h) in &ladder {
            assert!(w >= 1 && h >= 1);
        }
        assert_eq!(ladder.last(), Some(&(8, 8)));
    }

    /// A cursor already at or below the floor offers exactly one size and gives up immediately —
    /// there is nothing to shrink, and a second render would be the same bytes again.
    #[test]
    fn a_tiny_cursor_offers_one_size() {
        assert_eq!(render_ladder(2.0, 4, 4), vec![(4, 4)]);
        assert_eq!(render_ladder(4.0, 8, 8), vec![(8, 8)]);
    }

    /// A degenerate input — zero, negative or non-finite — answers a floor-sized ladder rather than
    /// an empty one or a panic. The caller is on a 120 Hz path with a framework's numbers in hand,
    /// and "no sizes to try" would silently stop shipping shapes.
    #[test]
    fn a_degenerate_size_still_answers_something_renderable() {
        for size in [0.0, -50.0, f64::NAN, f64::INFINITY] {
            let ladder = render_ladder(size, 0, 0);
            assert_eq!(ladder, vec![(1, 1)], "size {size} answered {ladder:?}");
        }
        assert_eq!(render_ladder(f64::NAN, 64, 64), vec![(8, 8)]);
    }

    /// The budget is the datagram minus the shape header, and it is big enough to be worth the
    /// ladder — a constant that drifted to near zero would make every cursor render at the floor.
    #[test]
    fn the_budget_is_one_datagram_minus_the_header() {
        assert_eq!(MAX_SHAPE_BITMAP_BYTES, 1200 - 27);
    }
}
