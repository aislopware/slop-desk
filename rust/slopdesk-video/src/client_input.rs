//! What the client sends when the user touches the pane, and the two latches that keep it honest.
//!
//! Pointer positions leave normalised into the zero-to-one window space the host expects — the
//! client NEVER sends raw pixels, which removes the pixel-versus-point ambiguity entirely. The
//! normalisation is the EXACT inverse of the render transform, so a click lands on the host pixel
//! under the cursor on screen rather than near it.
//!
//! Beside it sit the modifier latch, which exists because a swallowed key-up sticks a modifier on
//! the host until the user happens to press that key again, and the cursor-shape tracker, which
//! exists because a lost shape bitmap would otherwise leave the only cursor the user can see wrong
//! for the whole session.

use std::collections::{BTreeMap, BTreeSet};

use crate::geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize, displayed_video_rect};
use crate::input_event::{
    InputEvent, InputModifiers, KeyEvent, MouseButton, MouseButtonEvent, ScrollEvent, modifier_keys,
};

/// How the renderer is mapping the texture onto the drawable right now.
///
/// The fit path is the classic one: aspect-fit into a centred sub-rect, then the zoom-and-pan crop.
/// The CROP path is the actual-size viewport, where a texture sub-rect maps onto the WHOLE drawable
/// with independent horizontal and vertical scales and no letterbox at all — so its inverse is a
/// plain per-axis affine, and cannot be expressed by the fit path's single scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PointerMapping {
    /// Aspect-fit, then the renderer's zoom-and-pan crop.
    Fit {
        /// The video's native size, which sets the aspect.
        video_native_size: VideoSize,
        /// The renderer's zoom; one leaves the crop term inert.
        zoom: f64,
        /// The renderer's pan.
        pan: VideoPoint,
        /// Contain or cover.
        mode: VideoContentMode,
    },
    /// A texture sub-rect mapped onto the whole drawable, in normalised texture coordinates.
    Crop(VideoRect),
}

impl PointerMapping {
    /// The plain one-to-one mapping: aspect-fit at no zoom.
    #[must_use]
    pub const fn fit(video_native_size: VideoSize) -> Self {
        Self::Fit {
            video_native_size,
            zoom: 1.0,
            pan: VideoPoint { x: 0.0, y: 0.0 },
            mode: VideoContentMode::Fit,
        }
    }
}

/// Maps a point in the layer's view space to the normalised window position the host expects.
///
/// The view space has its origin at the top left with y increasing downward, the same orientation
/// as the host's window space, so there is no flip anywhere in here. The result is clamped to the
/// window, so an out-of-bounds drag does not send coordinates the host would only reject.
///
/// For the fit mapping the inverse runs in two steps, matching the renderer forward for forward:
/// map the view point into the displayed rect's own zero-to-one span, which undoes the letterbox;
/// then apply the same zoom-and-pan crop the fragment shader applies, with the pan clamped by the
/// IDENTICAL rule, so the inverse can never diverge from the forward transform.
#[must_use]
pub fn normalize(view_point: VideoPoint, layer_size: VideoSize, mapping: PointerMapping) -> VideoPoint {
    match mapping {
        PointerMapping::Crop(crop) => {
            let u = if layer_size.width > 0.0 {
                view_point.x / layer_size.width
            } else {
                0.0
            };
            let v = if layer_size.height > 0.0 {
                view_point.y / layer_size.height
            } else {
                0.0
            };
            // keep mul+add separate — FMA breaks bit-exact parity
            let sx = crop.origin.x + u * crop.size.width;
            let sy = crop.origin.y + v * crop.size.height;
            VideoPoint {
                x: clamp_unit(sx),
                y: clamp_unit(sy),
            }
        },
        PointerMapping::Fit {
            video_native_size,
            zoom,
            pan,
            mode,
        } => {
            let rect = displayed_video_rect(layer_size, video_native_size, mode);
            let u = if rect.size.width > 0.0 {
                (view_point.x - rect.origin.x) / rect.size.width
            } else {
                0.0
            };
            let v = if rect.size.height > 0.0 {
                (view_point.y - rect.origin.y) / rect.size.height
            } else {
                0.0
            };
            let inv_zoom = 1.0 / 1.0_f64.max(zoom);
            let pan_limit = 0.5 * (1.0 - inv_zoom);
            let px = pan.x.max(-pan_limit).min(pan_limit);
            let py = pan.y.max(-pan_limit).min(pan_limit);
            // keep mul+add separate — FMA breaks bit-exact parity
            let sx = (u - 0.5) * inv_zoom + 0.5 + px;
            let sy = (v - 0.5) * inv_zoom + 0.5 + py;
            VideoPoint {
                x: clamp_unit(sx),
                y: clamp_unit(sy),
            }
        },
    }
}

/// The ordered clamp into the unit interval, which sends a NaN to zero rather than through.
///
/// It is deliberately NOT `clamp`, which returns NaN for a NaN input and would put that NaN on the
/// wire; the chained max-then-min carries the Swift's IEEE-754 semantics, where the bound wins.
const fn clamp_unit(value: f64) -> f64 {
    value.max(0.0).min(1.0)
}

/// Builds the client-to-host input events, stamping each with the self-inject filter tag.
///
/// The host writes the tag onto the injected event so its own cursor sampler and geometry watcher
/// can drop what this client injected rather than echoing it back. The tag is monotonic per event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputEventEncoder {
    next_tag: u32,
}

impl Default for InputEventEncoder {
    fn default() -> Self {
        Self::new(1)
    }
}

impl InputEventEncoder {
    /// An encoder starting at the given tag.
    #[must_use]
    pub const fn new(initial_tag: u32) -> Self {
        Self {
            next_tag: initial_tag,
        }
    }

    /// The tag the next emitted event will carry.
    #[must_use]
    pub const fn peek_next_tag(&self) -> u32 {
        self.next_tag
    }

    /// A pure hover move.
    pub fn mouse_move(
        &mut self,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
    ) -> InputEvent {
        InputEvent::MouseMove {
            normalized: normalize(view_point, layer_size, mapping),
            tag: self.take_tag(),
        }
    }

    /// A button press.
    pub fn mouse_down(
        &mut self,
        button: MouseButton,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
        click_count: u8,
        modifiers: InputModifiers,
    ) -> InputEvent {
        let event = Self::button_event(button, view_point, layer_size, mapping, click_count, modifiers);
        InputEvent::MouseDown(event, self.take_tag())
    }

    /// A button release.
    pub fn mouse_up(
        &mut self,
        button: MouseButton,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
        click_count: u8,
        modifiers: InputModifiers,
    ) -> InputEvent {
        let event = Self::button_event(button, view_point, layer_size, mapping, click_count, modifiers);
        InputEvent::MouseUp(event, self.take_tag())
    }

    /// A move with a button HELD, said explicitly so the host can post a drag statelessly.
    pub fn mouse_drag(
        &mut self,
        button: MouseButton,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
        click_count: u8,
        modifiers: InputModifiers,
    ) -> InputEvent {
        let event = Self::button_event(button, view_point, layer_size, mapping, click_count, modifiers);
        InputEvent::MouseDrag(event, self.take_tag())
    }

    /// A scroll or trackpad gesture, carrying the phases verbatim.
    #[expect(
        clippy::too_many_arguments,
        reason = "the wire event's own shape: two deltas, a position, two phases and a precision flag, none \
                  of which the host can infer from the others"
    )]
    pub fn scroll(
        &mut self,
        dx: f64,
        dy: f64,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
    ) -> InputEvent {
        let event = ScrollEvent {
            dx,
            dy,
            normalized: normalize(view_point, layer_size, mapping),
            scroll_phase,
            momentum_phase,
            continuous,
        };
        InputEvent::Scroll(event, self.take_tag())
    }

    /// A key edge by host virtual keycode.
    pub const fn key(&mut self, key_code: u16, down: bool, modifiers: InputModifiers) -> InputEvent {
        InputEvent::Key(
            KeyEvent {
                key_code,
                down,
                modifiers,
            },
            self.take_tag(),
        )
    }

    /// A layout-independent text insertion.
    pub fn text(&mut self, string: impl Into<String>) -> InputEvent {
        InputEvent::Text(string.into(), self.take_tag())
    }

    fn button_event(
        button: MouseButton,
        view_point: VideoPoint,
        layer_size: VideoSize,
        mapping: PointerMapping,
        click_count: u8,
        modifiers: InputModifiers,
    ) -> MouseButtonEvent {
        MouseButtonEvent {
            button,
            normalized: normalize(view_point, layer_size, mapping),
            click_count,
            modifiers,
        }
    }

    const fn take_tag(&mut self) -> u32 {
        let tag = self.next_tag;
        self.next_tag = self.next_tag.wrapping_add(1);
        tag
    }
}

/// Tracks which modifier keys were forwarded as down but whose release the view may never see.
///
/// Focus can move away mid-chord — a command-tab, a pane blur, a resigned first responder — and the
/// release edge never arrives. The host injects modifiers through a shared event source that
/// LATCHES flag state, so a swallowed key-up leaves the modifier stuck, and later scroll or move
/// events, which carry no explicit flags, INHERIT it: a plain two-finger scroll becomes a
/// command-scroll and the remote page zooms. This lets the view synthesise the missing releases.
///
/// Caps Lock is never latched. It is a TOGGLE rather than a held key, so a synthesised release on
/// it would FLIP the host's state — focusing and blurring a pane with local Caps on toggled remote
/// Caps every single time. Its genuine edges still forward one to one; they just bypass the latch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ModifierLatchTracker {
    /// One bit per virtual keycode, and every keycode this type accepts fits: the whole macOS
    /// held-modifier vocabulary is [`modifier_keys::HELD_MODIFIER_KEY_CODES`], which is 54 through
    /// 63. A set would carry an allocation per pane to hold at most nine small integers, and — the
    /// part that matters — would accept keycodes that are not modifiers at all, latch them, and
    /// synthesise a key-up for them on the next focus loss.
    latched: u64,
}

impl ModifierLatchTracker {
    /// A tracker with nothing latched.
    #[must_use]
    pub const fn new() -> Self {
        Self { latched: 0 }
    }

    /// The raw bitmask, for a caller that has to carry the tracker across a boundary by value.
    #[must_use]
    pub const fn mask(self) -> u64 {
        self.latched
    }

    /// A tracker restored from a mask [`Self::mask`] produced.
    #[must_use]
    pub const fn restored(latched: u64) -> Self {
        Self { latched }
    }

    /// Whether nothing is latched down.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.latched == 0
    }

    /// Whether one keycode is latched down.
    #[must_use]
    pub const fn is_down(self, key_code: u16) -> bool {
        match Self::bit(key_code) {
            Some(bit) => self.latched & bit != 0,
            None => false,
        }
    }

    /// Records one modifier edge. A repeated same-direction edge is absorbed.
    ///
    /// Only a HELD modifier is latched, which is one rule where there used to be a special case.
    /// Caps Lock is not in the vocabulary because it is a TOGGLE rather than a held key, and a
    /// synthesised release on it would FLIP the host's state — focusing and blurring a pane with
    /// local Caps on toggled remote Caps every single time. Its genuine edges still forward one to
    /// one; they just bypass the latch. An ordinary keycode is refused for the same reason and by
    /// the same test: nothing that was never held can be owed a release.
    pub const fn note(&mut self, key_code: u16, down: bool) {
        if !modifier_keys::is_held_modifier(key_code) {
            return;
        }
        let Some(bit) = Self::bit(key_code) else {
            return;
        };
        if down {
            self.latched |= bit;
        } else {
            self.latched &= !bit;
        }
    }

    /// Returns every latched keycode in ascending order and CLEARS the tracker, so the caller can
    /// synthesise one host key-up each and leave nothing latched after focus loss.
    pub fn drain_for_release(&mut self) -> Vec<u16> {
        let all = (0..u64::BITS)
            .filter(|shift| self.latched & (1_u64 << shift) != 0)
            .filter_map(|shift| u16::try_from(shift).ok())
            .collect();
        self.latched = 0;
        all
    }

    /// The bit for a keycode, or `None` for one outside the mask's reach.
    ///
    /// Unreachable for anything [`modifier_keys::is_held_modifier`] accepts — the vocabulary tops
    /// out at 63 — and spelled as an `Option` rather than an assertion so a future keycode added
    /// above the mask fails by not latching rather than by shifting out of range.
    const fn bit(key_code: u16) -> Option<u64> {
        if key_code as u32 >= u64::BITS {
            return None;
        }
        Some(1_u64 << key_code)
    }
}

/// How often the motion pump flushes the freshest deferred pointer move, absent a knob.
///
/// 1/120 s, deliberately decoupled from the video frame cap: the host re-coalesces whatever
/// arrives, so a tighter cadence than the picture costs nothing but wire.
pub const DEFAULT_MOTION_INTERVAL: f64 = 1.0 / 120.0;

/// The motion-pump interval the two knobs ask for, in seconds.
///
/// `SLOPDESK_INPUT_HZ` (1..=1000 Hz) wins over `SLOPDESK_INPUT_INTERVAL_MS` (1..=1000 ms); a
/// missing, unparseable or out-of-range value falls through to the next and finally to
/// [`DEFAULT_MOTION_INTERVAL`]. Both clamps are the point: above a kilohertz the pump is wire spam,
/// and at a value near zero it is a busy loop that starves the actor it runs on. A typo can
/// therefore do neither — it simply does not apply.
#[must_use]
pub fn motion_interval(hz: Option<&str>, milliseconds: Option<&str>) -> f64 {
    if let Some(rate) = hz.and_then(|raw| raw.parse::<f64>().ok())
        && (1.0..=1000.0).contains(&rate)
    {
        return 1.0 / rate;
    }
    if let Some(span) = milliseconds.and_then(|raw| raw.parse::<f64>().ok())
        && (1.0..=1000.0).contains(&span)
    {
        return span / 1000.0;
    }
    DEFAULT_MOTION_INTERVAL
}

/// The default spacing between re-requests of the same missing cursor shape, in seconds.
pub const CURSOR_SHAPE_RE_REQUEST_INTERVAL: f64 = 0.25;

/// Decides when to re-ask for a cursor shape bitmap the client never received.
///
/// A shape ships over the cursor socket ONCE per id. The host strips the real cursor, so this
/// overlay is the only cursor the user sees, and a shape lost to the wire — or to a lost IP
/// fragment on an over-sized datagram — would otherwise leave the pointer wrong or invisible for
/// the entire session. When a POSITION update references an id the client has not cached, the
/// client re-asks on the existing recovery channel, mirroring how it asks for a keyframe.
///
/// The rate limit is the point of the type: a steady stream of position updates referencing a
/// still-missing id, whose re-ship may itself be lost, must not flood the recovery channel. A few
/// round-trips of spacing is long enough for one re-ship to arrive and short enough to heal
/// promptly.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CursorShapeRequestTracker {
    known_shape_ids: BTreeSet<u16>,
    last_requested: BTreeMap<u16, f64>,
    re_request_interval: f64,
}

impl CursorShapeRequestTracker {
    /// A tracker with the given re-request spacing.
    #[must_use]
    pub const fn new(re_request_interval: f64) -> Self {
        Self {
            known_shape_ids: BTreeSet::new(),
            last_requested: BTreeMap::new(),
            re_request_interval,
        }
    }

    /// A tracker restored from what [`Self::known_ids`] and [`Self::pending`] answered.
    ///
    /// How a tracker that has to cross a boundary by value gets back in. Not `new` plus a replay of
    /// the arrivals: the pending stamps are not derivable from the ids, and replaying them through
    /// `should_request` would move every one of them to the caller's idea of now.
    pub fn restored(
        known: impl IntoIterator<Item = u16>,
        pending: impl IntoIterator<Item = (u16, f64)>,
        re_request_interval: f64,
    ) -> Self {
        Self {
            known_shape_ids: known.into_iter().collect(),
            last_requested: pending.into_iter().collect(),
            re_request_interval,
        }
    }

    /// Every cached shape id, ascending.
    #[must_use]
    pub fn known_ids(&self) -> impl ExactSizeIterator<Item = u16> + '_ {
        self.known_shape_ids.iter().copied()
    }

    /// Every outstanding request, ascending by id, with the time it was sent.
    #[must_use]
    pub fn pending(&self) -> impl ExactSizeIterator<Item = (u16, f64)> + '_ {
        self.last_requested.iter().map(|(&id, &at)| (id, at))
    }

    /// A shape bitmap arrived: mark it cached, idempotently, and stop re-requesting it.
    pub fn note_shape_arrived(&mut self, shape_id: u16) {
        self.known_shape_ids.insert(shape_id);
        self.last_requested.remove(&shape_id);
    }

    /// Whether the bitmap for an id is already cached.
    #[must_use]
    pub fn is_known(&self, shape_id: u16) -> bool {
        self.known_shape_ids.contains(&shape_id)
    }

    /// A position update referenced a shape. Answers whether to send a request right now, and
    /// records the send when it does, so the next update for the same missing id does not re-fire
    /// immediately.
    pub fn should_request(&mut self, shape_id: u16, now: f64) -> bool {
        if self.known_shape_ids.contains(&shape_id) {
            return false;
        }
        if let Some(&last) = self.last_requested.get(&shape_id)
            && now - last < self.re_request_interval
        {
            return false;
        }
        self.last_requested.insert(shape_id, now);
        true
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the normalised positions are exact halves and quarters of the fixture sizes, and a wrong \
                  event variant is a test failure with nothing to return"
    )]

    use super::{
        CURSOR_SHAPE_RE_REQUEST_INTERVAL, CursorShapeRequestTracker, DEFAULT_MOTION_INTERVAL,
        InputEventEncoder, ModifierLatchTracker, PointerMapping, motion_interval, normalize,
    };
    use crate::geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize};
    use crate::input_event::{InputEvent, InputModifiers, MouseButton, modifier_keys};

    fn point(x: f64, y: f64) -> VideoPoint {
        VideoPoint { x, y }
    }

    /// A square video inside a wide layer, so there are pillarbox bars to invert.
    fn pillarboxed() -> (VideoSize, PointerMapping) {
        (
            VideoSize::new(1000.0, 500.0),
            PointerMapping::fit(VideoSize::new(500.0, 500.0)),
        )
    }

    #[test]
    fn the_centre_of_the_pane_is_the_centre_of_the_window() {
        let (layer, mapping) = pillarboxed();
        let normalized = normalize(point(500.0, 250.0), layer, mapping);
        assert_eq!(normalized.x, 0.5);
        assert_eq!(normalized.y, 0.5);
    }

    #[test]
    fn a_click_in_the_letterbox_bar_clamps_instead_of_leaving_the_window() {
        let (layer, mapping) = pillarboxed();
        let left_bar = normalize(point(10.0, 250.0), layer, mapping);
        assert_eq!(
            left_bar.x, 0.0,
            "the bar is outside the video, not a negative coordinate"
        );
        let right_bar = normalize(point(990.0, 250.0), layer, mapping);
        assert_eq!(right_bar.x, 1.0);
    }

    #[test]
    fn the_inverse_undoes_the_letterbox_rather_than_the_whole_layer() {
        let (layer, mapping) = pillarboxed();
        // The video occupies the middle 500 points, so its left edge sits at view x = 250.
        assert_eq!(normalize(point(250.0, 0.0), layer, mapping).x, 0.0);
        assert_eq!(normalize(point(750.0, 0.0), layer, mapping).x, 1.0);
        assert_eq!(normalize(point(375.0, 0.0), layer, mapping).x, 0.25);
    }

    #[test]
    fn the_zoom_and_pan_crop_is_applied_the_way_the_shader_applies_it() {
        let layer = VideoSize::new(1000.0, 500.0);
        let zoomed = PointerMapping::Fit {
            video_native_size: VideoSize::new(1000.0, 500.0),
            zoom: 2.0,
            pan: VideoPoint { x: 0.0, y: 0.0 },
            mode: VideoContentMode::Fit,
        };
        assert_eq!(
            normalize(point(500.0, 250.0), layer, zoomed).x,
            0.5,
            "the centre holds"
        );
        assert_eq!(
            normalize(point(0.0, 250.0), layer, zoomed).x,
            0.25,
            "at twice the zoom the pane spans half the source",
        );
    }

    #[test]
    fn the_pan_is_clamped_by_the_same_rule_the_renderer_uses() {
        let layer = VideoSize::new(1000.0, 500.0);
        let panned = PointerMapping::Fit {
            video_native_size: VideoSize::new(1000.0, 500.0),
            zoom: 2.0,
            pan: VideoPoint { x: 5.0, y: 0.0 },
            mode: VideoContentMode::Fit,
        };
        // The limit at twice the zoom is a quarter, so the centre lands three quarters along.
        assert_eq!(normalize(point(500.0, 250.0), layer, panned).x, 0.75);
    }

    #[test]
    fn the_actual_size_viewport_inverts_as_a_plain_per_axis_affine() {
        let layer = VideoSize::new(800.0, 400.0);
        let crop = PointerMapping::Crop(VideoRect::xywh(0.25, 0.5, 0.5, 0.25));
        assert_eq!(normalize(point(0.0, 0.0), layer, crop), point(0.25, 0.5));
        assert_eq!(normalize(point(800.0, 400.0), layer, crop), point(0.75, 0.75));
        assert_eq!(
            normalize(point(400.0, 200.0), layer, crop),
            point(0.5, 0.625),
            "independent horizontal and vertical scales, which one uniform scale cannot express",
        );
    }

    #[test]
    fn a_degenerate_layer_maps_to_the_origin_rather_than_a_nan() {
        let zero = VideoSize::new(0.0, 0.0);
        let crop = PointerMapping::Crop(VideoRect::xywh(0.0, 0.0, 1.0, 1.0));
        assert_eq!(normalize(point(10.0, 10.0), zero, crop), point(0.0, 0.0));
        assert_eq!(
            normalize(point(10.0, 10.0), zero, PointerMapping::fit(zero)),
            point(0.0, 0.0),
        );
    }

    #[test]
    fn every_emitted_event_carries_the_next_tag() {
        let (layer, mapping) = pillarboxed();
        let mut encoder = InputEventEncoder::default();
        assert_eq!(encoder.peek_next_tag(), 1);
        let moved = encoder.mouse_move(point(500.0, 250.0), layer, mapping);
        assert_eq!(moved.tag(), 1);
        let down = encoder.mouse_down(
            MouseButton::Left,
            point(500.0, 250.0),
            layer,
            mapping,
            1,
            InputModifiers::default(),
        );
        assert_eq!(down.tag(), 2);
        let up = encoder.mouse_up(
            MouseButton::Left,
            point(500.0, 250.0),
            layer,
            mapping,
            1,
            InputModifiers::default(),
        );
        assert_eq!(up.tag(), 3);
        assert_eq!(encoder.key(55, true, InputModifiers::default()).tag(), 4);
        assert_eq!(encoder.text("hi").tag(), 5);
        assert_eq!(encoder.peek_next_tag(), 6);
    }

    #[test]
    fn a_drag_says_so_explicitly_rather_than_looking_like_a_hover() {
        let (layer, mapping) = pillarboxed();
        let mut encoder = InputEventEncoder::default();
        let drag = encoder.mouse_drag(
            MouseButton::Right,
            point(500.0, 250.0),
            layer,
            mapping,
            2,
            InputModifiers::SHIFT,
        );
        match drag {
            InputEvent::MouseDrag(event, _) => {
                assert_eq!(event.button, MouseButton::Right);
                assert_eq!(event.click_count, 2);
                assert_eq!(event.modifiers, InputModifiers::SHIFT);
                assert_eq!(event.normalized.x, 0.5);
            },
            other => panic!("expected a drag, got {other:?}"),
        }
    }

    #[test]
    fn a_scroll_carries_its_phases_verbatim() {
        let (layer, mapping) = pillarboxed();
        let mut encoder = InputEventEncoder::default();
        let scrolled = encoder.scroll(-3.0, 12.0, point(500.0, 250.0), layer, mapping, 2, 0, true);
        match scrolled {
            InputEvent::Scroll(event, tag) => {
                assert_eq!(tag, 1);
                assert_eq!(event.dx, -3.0);
                assert_eq!(event.dy, 12.0);
                assert_eq!(event.scroll_phase, 2);
                assert_eq!(event.momentum_phase, 0);
                assert!(event.continuous);
            },
            other => panic!("expected a scroll, got {other:?}"),
        }
    }

    #[test]
    fn the_tag_wraps_rather_than_overflowing() {
        let mut encoder = InputEventEncoder::new(u32::MAX);
        assert_eq!(encoder.key(55, true, InputModifiers::default()).tag(), u32::MAX);
        assert_eq!(encoder.peek_next_tag(), 0);
    }

    #[test]
    fn the_latch_releases_everything_that_was_held_when_focus_left() {
        let mut latch = ModifierLatchTracker::new();
        assert!(latch.is_empty());
        latch.note(59, true);
        latch.note(55, true);
        latch.note(55, true);
        assert!(latch.is_down(55));
        latch.note(59, false);
        assert!(!latch.is_down(59));
        latch.note(56, true);
        assert_eq!(
            latch.drain_for_release(),
            vec![55, 56],
            "ascending, so the emit is stable"
        );
        assert!(latch.is_empty(), "and nothing stays latched afterward");
    }

    #[test]
    fn caps_lock_is_never_latched_because_a_synthesized_release_would_flip_it() {
        let mut latch = ModifierLatchTracker::new();
        latch.note(modifier_keys::CAPS_LOCK_KEY_CODE, true);
        assert!(!latch.is_down(modifier_keys::CAPS_LOCK_KEY_CODE));
        assert!(latch.drain_for_release().is_empty());
    }

    #[test]
    fn a_motion_knob_out_of_range_does_not_apply_rather_than_applying_badly() {
        assert_eq!(motion_interval(None, None), DEFAULT_MOTION_INTERVAL);
        assert_eq!(motion_interval(Some("240"), None), 1.0 / 240.0);
        assert_eq!(motion_interval(Some("240"), Some("5")), 1.0 / 240.0, "hz wins");
        assert_eq!(motion_interval(None, Some("5")), 0.005);
        assert_eq!(
            motion_interval(Some("0"), Some("5")),
            0.005,
            "a rate below the floor falls THROUGH to the next knob, it does not win with a clamp",
        );
        assert_eq!(motion_interval(Some("100000"), None), DEFAULT_MOTION_INTERVAL);
        assert_eq!(motion_interval(Some("fast"), Some("0")), DEFAULT_MOTION_INTERVAL);
    }

    #[test]
    fn an_ordinary_key_is_never_latched_because_nothing_unheld_is_owed_a_release() {
        let mut latch = ModifierLatchTracker::new();
        latch.note(0, true); // 'a'
        latch.note(4095, true); // nothing at all
        assert!(
            latch.is_empty(),
            "only a HELD modifier can be owed a synthesised release"
        );
        assert!(!latch.is_down(0));
        assert!(latch.drain_for_release().is_empty());
    }

    #[test]
    fn the_mask_round_trips_so_the_latch_can_cross_a_boundary_by_value() {
        let mut latch = ModifierLatchTracker::new();
        latch.note(55, true);
        latch.note(63, true);
        let carried = ModifierLatchTracker::restored(latch.mask());
        assert_eq!(carried, latch);
        assert!(carried.is_down(55) && carried.is_down(63));
    }

    #[test]
    fn a_missing_shape_is_re_requested_at_most_once_per_interval() {
        let mut tracker = CursorShapeRequestTracker::new(CURSOR_SHAPE_RE_REQUEST_INTERVAL);
        assert!(tracker.should_request(7, 0.0));
        assert!(
            !tracker.should_request(7, 0.1),
            "a 120 Hz update stream must not flood"
        );
        assert!(
            tracker.should_request(7, 0.3),
            "but the re-ship may itself be lost"
        );
        assert!(
            tracker.should_request(9, 0.3),
            "a different shape has its own budget"
        );
    }

    #[test]
    fn a_cached_shape_never_asks_again() {
        let mut tracker = CursorShapeRequestTracker::new(CURSOR_SHAPE_RE_REQUEST_INTERVAL);
        assert!(tracker.should_request(7, 0.0));
        tracker.note_shape_arrived(7);
        assert!(tracker.is_known(7));
        assert!(!tracker.should_request(7, 10.0));
        tracker.note_shape_arrived(7);
        assert!(tracker.is_known(7), "the re-mark is idempotent");
    }

    #[test]
    fn a_shape_that_arrived_before_any_position_update_is_still_known() {
        let mut tracker = CursorShapeRequestTracker::new(CURSOR_SHAPE_RE_REQUEST_INTERVAL);
        tracker.note_shape_arrived(3);
        assert!(!tracker.should_request(3, 0.0));
    }
}
