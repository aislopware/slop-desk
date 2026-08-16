//! What the client sends when the user touches the pane.
//!
//! Two things live here. The pointer normalisation, which is the EXACT inverse of the render
//! transform and therefore the one piece of client math a second copy can get subtly wrong — a
//! click that lands near the pixel under the cursor rather than on it is not a crash, it is a
//! remote machine that feels broken. And the modifier latch, which exists because a swallowed
//! key-up leaves a modifier stuck on the host's shared event source, turning every later plain
//! scroll into a ⌘-scroll.
//!
//! ## The mapping crosses flat, with a flag for the branch
//! `PointerMapping` is a two-variant enum and C has no such thing, so it crosses as one record
//! carrying both arms plus `has_crop`. Not a sentinel rect: an all-zero crop is a degenerate
//! viewport, which is a different answer from "there is no crop", and only one of them takes the
//! aspect-fit path the golden vectors pin.
//!
//! ## The latch crosses as its bitmask
//! Nine keycodes, all of them 54 through 63, so the whole tracker is a `u64` — no allocation, no
//! handle, and nothing for two copies of a Swift `struct` to alias (docs/55 §4b).

use std::ffi::c_uchar;

use slopdesk_video::client_input::{
    CURSOR_SHAPE_RE_REQUEST_INTERVAL, CursorShapeRequestTracker, ModifierLatchTracker, PointerMapping,
    motion_interval, normalize,
};
use slopdesk_video::geometry::VideoPoint;
use slopdesk_video::input_event::modifier_keys;

use crate::borrow;
use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize, content_mode};

/// How the renderer is mapping the texture onto the drawable, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskPointerMapping {
    /// The video's native size, which sets the aspect the fit path letterboxes against.
    pub video_native_size: SlopDeskVideoSize,
    /// The renderer's zoom. One leaves the crop term inert.
    pub zoom: f64,
    /// The renderer's pan, clamped here by the rule the renderer clamps by.
    pub pan: SlopDeskVideoPoint,
    /// [`crate::video_policy::SLOPDESK_CONTENT_MODE_FIT`] or `_FILL`.
    pub mode: u32,
    /// The actual-size viewport's texture sub-rect, in normalised texture coordinates.
    pub crop: SlopDeskVideoRect,
    /// Whether `crop` is an answer. A zero rect is a degenerate viewport, not an absence.
    pub has_crop: bool,
}

impl SlopDeskPointerMapping {
    /// The crate's mapping.
    const fn of(self) -> PointerMapping {
        if self.has_crop {
            PointerMapping::Crop(self.crop.of())
        } else {
            PointerMapping::Fit {
                video_native_size: self.video_native_size.of(),
                zoom: self.zoom,
                pan: VideoPoint {
                    x: self.pan.x,
                    y: self.pan.y,
                },
                mode: content_mode(self.mode),
            }
        }
    }
}

/// Maps a point in the layer's view space to the normalised window position the host expects.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_input_normalize(
    view_point: SlopDeskVideoPoint,
    layer_size: SlopDeskVideoSize,
    mapping: SlopDeskPointerMapping,
) -> SlopDeskVideoPoint {
    let normalized = normalize(
        VideoPoint {
            x: view_point.x,
            y: view_point.y,
        },
        layer_size.of(),
        mapping.of(),
    );
    SlopDeskVideoPoint {
        x: normalized.x,
        y: normalized.y,
    }
}

/// The tag after `tag` — the self-inject filter value the next event will carry.
///
/// Wrapping is the whole content of this entry point, and it is the reason it exists rather than
/// being a `+ 1` at the call site: the tag is a `u32` the host compares for equality, so it has to
/// come back around rather than trap or saturate.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_input_next_tag(tag: u32) -> u32 {
    tag.wrapping_add(1)
}

/// The motion-pump interval the two environment knobs ask for, in seconds.
///
/// Each knob crosses as its raw bytes, EMPTY meaning unset: the precedence between them and both
/// clamps are one rule, and a near side that pre-filtered the values would be applying half of it.
///
/// # Safety
/// Each pointer is either null, or points to its stated length in readable bytes for the whole
/// call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_input_motion_interval(
    hz: *const c_uchar,
    hz_len: usize,
    milliseconds: *const c_uchar,
    milliseconds_len: usize,
) -> f64 {
    // SAFETY: the caller's obligation above, discharged at the call site by a scoped buffer access.
    let rate = unsafe { borrow(hz, hz_len) };
    // SAFETY: as above.
    let span = unsafe { borrow(milliseconds, milliseconds_len) };
    motion_interval(knob(rate), knob(span))
}

/// A borrowed knob as a string, where EMPTY means UNSET rather than the empty string — the two are
/// the same answer here (neither applies), but only one of them is worth spelling.
const fn knob(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() {
        return None;
    }
    match core::str::from_utf8(bytes) {
        Ok(text) => Some(text),
        Err(_) => None,
    }
}

/// A latch with nothing held.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_modifier_latch_new() -> u64 {
    ModifierLatchTracker::new().mask()
}

/// Whether nothing is latched down.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_modifier_latch_is_empty(latched: u64) -> bool {
    ModifierLatchTracker::restored(latched).is_empty()
}

/// Whether one keycode is latched down.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_modifier_latch_is_down(latched: u64, key_code: u16) -> bool {
    ModifierLatchTracker::restored(latched).is_down(key_code)
}

/// Records one modifier edge and answers the latch that results.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_modifier_latch_note(latched: u64, key_code: u16, down: bool) -> u64 {
    let mut tracker = ModifierLatchTracker::restored(latched);
    tracker.note(key_code, down);
    tracker.mask()
}

/// How many keycodes [`slopdesk_modifier_latch_drain`] can ever answer.
///
/// The vocabulary, not a buffer size somebody picked: a caller that lends this many slots cannot be
/// told to try again with more, so the drain has no measure-then-fill pass and no partial answer.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_modifier_latch_capacity() -> usize {
    modifier_keys::HELD_MODIFIER_KEY_CODES.len()
}

/// Writes every latched keycode in ascending order and answers how many there were.
///
/// The caller's latch is left CLEARED — it passes the mask by pointer for that reason. Nothing is
/// written and nothing is cleared when the buffer is too small or either pointer is null, so a
/// caller that got the capacity wrong loses no releases; it simply does not get an answer.
///
/// # Safety
/// `latched` points to one writable `u64`, and `out` to `capacity` writable `u16`s.
#[expect(
    unsafe_code,
    reason = "the lent buffer is the caller's, and the (ptr, len) pair is checked here before a byte moves"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_modifier_latch_drain(
    latched: *mut u64,
    out: *mut u16,
    capacity: usize,
) -> usize {
    if latched.is_null() || out.is_null() {
        return 0;
    }
    let mut tracker = ModifierLatchTracker::restored(unsafe { std::ptr::read(latched) });
    let released = tracker.drain_for_release();
    if released.len() > capacity {
        return 0;
    }
    // SAFETY: `out` is the caller's, valid for `capacity` `u16`s, and `released` is no longer than
    // that by the check above. The two regions cannot overlap — `released` is a local `Vec`.
    unsafe { std::ptr::copy_nonoverlapping(released.as_ptr(), out, released.len()) };
    unsafe { std::ptr::write(latched, tracker.mask()) };
    released.len()
}

/// What one cursor-shape decision needs, and whether it fits.
///
/// Two counts and an answer, because the tracker's state is two lists of unbounded length: the ids
/// whose bitmap has arrived, and the requests still outstanding with the time each was sent. The
/// counts are what the caller must lend for the write to happen; `send` is only an answer when it
/// did. A call that did not fit is not a decision — nothing was written, nothing was recorded, and
/// asking again with bigger buffers asks the same question rather than a later one.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskCursorShapeAnswer {
    /// Slots the cached-id list needs.
    pub known: usize,
    /// Slots the outstanding-request lists need — ids and stamps are the same length.
    pub pending: usize,
    /// Whether to send a request now. Meaningless unless both counts fit.
    pub send: bool,
}

/// The default spacing between re-requests of the same missing shape, in seconds.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_cursor_shape_default_interval() -> f64 {
    CURSOR_SHAPE_RE_REQUEST_INTERVAL
}

/// The tracker a caller's two lists spell, or `None` if either pair is unreadable.
///
/// # Safety
/// Each pointer is either null with a zero length, or valid for its stated length.
#[expect(
    unsafe_code,
    reason = "the lists are the caller's; each (ptr, len) pair is turned into a slice once, here"
)]
unsafe fn tracker_of(
    known: *const u16,
    known_len: usize,
    pending_ids: *const u16,
    pending_at: *const f64,
    pending_len: usize,
    re_request_interval: f64,
) -> Option<CursorShapeRequestTracker> {
    let cached: &[u16] = if known_len == 0 {
        &[]
    } else if known.is_null() {
        return None;
    } else {
        unsafe { std::slice::from_raw_parts(known, known_len) }
    };
    let (ids, stamps): (&[u16], &[f64]) = if pending_len == 0 {
        (&[], &[])
    } else if pending_ids.is_null() || pending_at.is_null() {
        return None;
    } else {
        unsafe {
            (
                std::slice::from_raw_parts(pending_ids, pending_len),
                std::slice::from_raw_parts(pending_at, pending_len),
            )
        }
    };
    Some(CursorShapeRequestTracker::restored(
        cached.iter().copied(),
        ids.iter().copied().zip(stamps.iter().copied()),
        re_request_interval,
    ))
}

/// Writes a stepped tracker back through the caller's buffers, or reports what it would have
/// needed.
///
/// # Safety
/// Each out pointer is either null with a zero capacity, or valid for its stated capacity.
#[expect(
    unsafe_code,
    reason = "the lent buffers are the caller's, and every (ptr, len) pair is checked before a byte moves"
)]
unsafe fn commit(
    tracker: &CursorShapeRequestTracker,
    send: bool,
    out_known: *mut u16,
    out_known_cap: usize,
    out_pending_ids: *mut u16,
    out_pending_at: *mut f64,
    out_pending_cap: usize,
) -> SlopDeskCursorShapeAnswer {
    let cached: Vec<u16> = tracker.known_ids().collect();
    let pending: Vec<(u16, f64)> = tracker.pending().collect();
    let shape = SlopDeskCursorShapeAnswer {
        known: cached.len(),
        pending: pending.len(),
        send: false,
    };
    if cached.len() > out_known_cap || pending.len() > out_pending_cap {
        return shape;
    }
    if (!cached.is_empty() && out_known.is_null())
        || (!pending.is_empty() && (out_pending_ids.is_null() || out_pending_at.is_null()))
    {
        return shape;
    }
    // SAFETY: both lists are no longer than the capacities checked above, and neither can overlap a
    // local `Vec`.
    unsafe { std::ptr::copy_nonoverlapping(cached.as_ptr(), out_known, cached.len()) };
    for (index, (id, at)) in pending.into_iter().enumerate() {
        unsafe {
            std::ptr::write(out_pending_ids.add(index), id);
            std::ptr::write(out_pending_at.add(index), at);
        }
    }
    SlopDeskCursorShapeAnswer { send, ..shape }
}

/// Whether the bitmap for an id is already cached.
///
/// # Safety
/// `known` is either null with a zero length, or valid for `known_len` `u16`s.
#[expect(
    unsafe_code,
    reason = "the list is the caller's, and the (ptr, len) pair is checked before it is read"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cursor_shape_is_known(
    known: *const u16,
    known_len: usize,
    shape_id: u16,
) -> bool {
    unsafe { tracker_of(known, known_len, std::ptr::null(), std::ptr::null(), 0, 0.0) }
        .is_some_and(|tracker| tracker.is_known(shape_id))
}

/// A shape bitmap arrived: mark it cached and stop re-requesting it.
///
/// # Safety
/// Every pointer is either null with a zero length, or valid for its stated length.
#[expect(
    unsafe_code,
    reason = "the lists and the lent buffers are the caller's, and each pair is checked here"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cursor_shape_note_arrived(
    known: *const u16,
    known_len: usize,
    pending_ids: *const u16,
    pending_at: *const f64,
    pending_len: usize,
    shape_id: u16,
    out_known: *mut u16,
    out_known_cap: usize,
    out_pending_ids: *mut u16,
    out_pending_at: *mut f64,
    out_pending_cap: usize,
) -> SlopDeskCursorShapeAnswer {
    let Some(mut tracker) =
        (unsafe { tracker_of(known, known_len, pending_ids, pending_at, pending_len, 0.0) })
    else {
        return SlopDeskCursorShapeAnswer::default();
    };
    tracker.note_shape_arrived(shape_id);
    unsafe {
        commit(
            &tracker,
            false,
            out_known,
            out_known_cap,
            out_pending_ids,
            out_pending_at,
            out_pending_cap,
        )
    }
}

/// A position update referenced a shape: answer whether to ask for it now, and record the ask.
///
/// # Safety
/// Every pointer is either null with a zero length, or valid for its stated length.
#[expect(
    unsafe_code,
    reason = "the lists and the lent buffers are the caller's, and each pair is checked here"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_cursor_shape_should_request(
    known: *const u16,
    known_len: usize,
    pending_ids: *const u16,
    pending_at: *const f64,
    pending_len: usize,
    shape_id: u16,
    now: f64,
    re_request_interval: f64,
    out_known: *mut u16,
    out_known_cap: usize,
    out_pending_ids: *mut u16,
    out_pending_at: *mut f64,
    out_pending_cap: usize,
) -> SlopDeskCursorShapeAnswer {
    let Some(mut tracker) = (unsafe {
        tracker_of(
            known,
            known_len,
            pending_ids,
            pending_at,
            pending_len,
            re_request_interval,
        )
    }) else {
        return SlopDeskCursorShapeAnswer::default();
    };
    let send = tracker.should_request(shape_id, now);
    unsafe {
        commit(
            &tracker,
            send,
            out_known,
            out_known_cap,
            out_pending_ids,
            out_pending_at,
            out_pending_cap,
        )
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        clippy::float_cmp,
        clippy::indexing_slicing,
        reason = "the tests call the C entry points, and the normalised positions are exact halves of the \
                  fixture sizes"
    )]

    use super::{
        SlopDeskCursorShapeAnswer, SlopDeskPointerMapping, slopdesk_cursor_shape_default_interval,
        slopdesk_cursor_shape_is_known, slopdesk_cursor_shape_note_arrived,
        slopdesk_cursor_shape_should_request, slopdesk_input_motion_interval, slopdesk_input_next_tag,
        slopdesk_input_normalize, slopdesk_modifier_latch_capacity, slopdesk_modifier_latch_drain,
        slopdesk_modifier_latch_is_down, slopdesk_modifier_latch_is_empty, slopdesk_modifier_latch_new,
        slopdesk_modifier_latch_note,
    };
    use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

    fn point(x: f64, y: f64) -> SlopDeskVideoPoint {
        SlopDeskVideoPoint { x, y }
    }

    fn fit(width: f64, height: f64) -> SlopDeskPointerMapping {
        SlopDeskPointerMapping {
            video_native_size: SlopDeskVideoSize { width, height },
            zoom: 1.0,
            ..SlopDeskPointerMapping::default()
        }
    }

    #[test]
    fn the_letterbox_is_undone_rather_than_the_whole_layer() {
        let layer = SlopDeskVideoSize {
            width: 1000.0,
            height: 500.0,
        };
        let square = fit(500.0, 500.0);
        assert_eq!(
            slopdesk_input_normalize(point(500.0, 250.0), layer, square).x,
            0.5
        );
        assert_eq!(
            slopdesk_input_normalize(point(250.0, 0.0), layer, square).x,
            0.0,
            "the video's left edge, not the layer's",
        );
        assert_eq!(
            slopdesk_input_normalize(point(10.0, 250.0), layer, square).x,
            0.0,
            "a click in the bar clamps rather than leaving the window",
        );
    }

    #[test]
    fn a_crop_takes_the_per_axis_path_even_when_it_is_all_zero() {
        let layer = SlopDeskVideoSize {
            width: 800.0,
            height: 400.0,
        };
        let cropped = SlopDeskPointerMapping {
            crop: SlopDeskVideoRect {
                x: 0.25,
                y: 0.5,
                width: 0.5,
                height: 0.25,
            },
            has_crop: true,
            ..fit(800.0, 400.0)
        };
        let middle = slopdesk_input_normalize(point(400.0, 200.0), layer, cropped);
        assert_eq!(middle.x, 0.5);
        assert_eq!(middle.y, 0.625);

        // The flag, not the value, picks the branch: a zero crop is a degenerate viewport and every
        // point in it maps to the crop's origin, which the fit path would never answer.
        let degenerate = SlopDeskPointerMapping {
            crop: SlopDeskVideoRect::default(),
            has_crop: true,
            ..fit(800.0, 400.0)
        };
        assert_eq!(
            slopdesk_input_normalize(point(400.0, 200.0), layer, degenerate),
            point(0.0, 0.0)
        );
    }

    #[test]
    fn the_tag_wraps_rather_than_overflowing() {
        assert_eq!(slopdesk_input_next_tag(1), 2);
        assert_eq!(slopdesk_input_next_tag(u32::MAX), 0);
    }

    #[test]
    fn a_motion_knob_crosses_as_its_raw_bytes_with_empty_meaning_unset() {
        let none = unsafe { slopdesk_input_motion_interval(std::ptr::null(), 0, std::ptr::null(), 0) };
        assert_eq!(none, 1.0 / 120.0);
        let hz = b"240";
        assert_eq!(
            unsafe { slopdesk_input_motion_interval(hz.as_ptr(), hz.len(), std::ptr::null(), 0) },
            1.0 / 240.0,
        );
        let empty = b"";
        let ms = b"5";
        assert_eq!(
            unsafe { slopdesk_input_motion_interval(empty.as_ptr(), 0, ms.as_ptr(), ms.len()) },
            0.005,
            "an unset knob is skipped rather than parsed as a zero",
        );
    }

    #[test]
    fn the_latch_releases_everything_held_and_refuses_what_was_never_held() {
        let mut latched = slopdesk_modifier_latch_new();
        assert!(slopdesk_modifier_latch_is_empty(latched));

        latched = slopdesk_modifier_latch_note(latched, 55, true);
        latched = slopdesk_modifier_latch_note(latched, 55, true);
        latched = slopdesk_modifier_latch_note(latched, 58, true);
        latched = slopdesk_modifier_latch_note(latched, 57, true); // caps lock — a toggle
        latched = slopdesk_modifier_latch_note(latched, 0, true); // 'a' — never held
        assert!(slopdesk_modifier_latch_is_down(latched, 55));
        assert!(!slopdesk_modifier_latch_is_down(latched, 57));

        let mut out = [0_u16; 16];
        assert!(slopdesk_modifier_latch_capacity() <= out.len());
        let count = unsafe { slopdesk_modifier_latch_drain(&raw mut latched, out.as_mut_ptr(), out.len()) };
        assert_eq!(&out[..count], &[55, 58], "ascending, so the emit is stable");
        assert!(slopdesk_modifier_latch_is_empty(latched));
    }

    /// The tracker's two lists, as a caller would hold them.
    #[derive(Default)]
    struct Tracked {
        known: Vec<u16>,
        ids: Vec<u16>,
        at: Vec<f64>,
    }

    impl Tracked {
        /// Steps the tracker with room for one more of each, which is the most any call can add.
        fn step(
            &mut self,
            step: impl Fn(&Self, *mut u16, usize, *mut u16, *mut f64, usize) -> SlopDeskCursorShapeAnswer,
        ) -> bool {
            let mut known = vec![0_u16; self.known.len() + 1];
            let mut ids = vec![0_u16; self.ids.len() + 1];
            let mut at = vec![0.0_f64; self.at.len() + 1];
            let answer = step(
                self,
                known.as_mut_ptr(),
                known.len(),
                ids.as_mut_ptr(),
                at.as_mut_ptr(),
                ids.len(),
            );
            known.truncate(answer.known);
            ids.truncate(answer.pending);
            at.truncate(answer.pending);
            self.known = known;
            self.ids = ids;
            self.at = at;
            answer.send
        }

        fn arrived(&mut self, shape_id: u16) {
            let _ignored = self.step(
                |held, out_known, known_cap, out_ids, out_at, pending_cap| unsafe {
                    slopdesk_cursor_shape_note_arrived(
                        held.known.as_ptr(),
                        held.known.len(),
                        held.ids.as_ptr(),
                        held.at.as_ptr(),
                        held.ids.len(),
                        shape_id,
                        out_known,
                        known_cap,
                        out_ids,
                        out_at,
                        pending_cap,
                    )
                },
            );
        }

        fn should_request(&mut self, shape_id: u16, now: f64) -> bool {
            self.step(
                |held, out_known, known_cap, out_ids, out_at, pending_cap| unsafe {
                    slopdesk_cursor_shape_should_request(
                        held.known.as_ptr(),
                        held.known.len(),
                        held.ids.as_ptr(),
                        held.at.as_ptr(),
                        held.ids.len(),
                        shape_id,
                        now,
                        slopdesk_cursor_shape_default_interval(),
                        out_known,
                        known_cap,
                        out_ids,
                        out_at,
                        pending_cap,
                    )
                },
            )
        }
    }

    #[test]
    fn a_missing_shape_is_asked_for_once_per_interval_and_never_once_cached() {
        let mut tracked = Tracked::default();
        assert!(tracked.should_request(7, 0.0));
        assert!(
            !tracked.should_request(7, 0.1),
            "a 120 Hz update stream must not flood"
        );
        assert!(
            tracked.should_request(7, 0.3),
            "but the re-ship may itself be lost"
        );
        assert!(
            tracked.should_request(9, 0.3),
            "a different shape has its own budget"
        );

        tracked.arrived(7);
        assert!(unsafe { slopdesk_cursor_shape_is_known(tracked.known.as_ptr(), tracked.known.len(), 7) });
        assert!(!tracked.should_request(7, 10.0));
        assert_eq!(
            tracked.ids,
            vec![9],
            "an arrival drops the outstanding ask with it"
        );
    }

    #[test]
    fn a_step_that_does_not_fit_records_nothing_and_says_what_it_needed() {
        let known = [1_u16, 2];
        let answer = unsafe {
            slopdesk_cursor_shape_should_request(
                known.as_ptr(),
                known.len(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                7,
                0.0,
                slopdesk_cursor_shape_default_interval(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(answer.known, 2);
        assert_eq!(answer.pending, 1);
        assert!(
            !answer.send,
            "a call that could not write is not a decision — acting on it would send an ask the tracker has \
             no record of",
        );
    }

    #[test]
    fn a_drain_that_does_not_fit_loses_nothing() {
        let mut latched = slopdesk_modifier_latch_note(slopdesk_modifier_latch_new(), 55, true);
        let mut out = [0_u16; 0];
        let count = unsafe { slopdesk_modifier_latch_drain(&raw mut latched, out.as_mut_ptr(), 0) };
        assert_eq!(count, 0);
        assert!(
            slopdesk_modifier_latch_is_down(latched, 55),
            "a drain that could not answer must not have cleared the latch",
        );
    }
}
