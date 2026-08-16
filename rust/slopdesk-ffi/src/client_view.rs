//! What the client pane does with the size it was given.
//!
//! `rust/slopdesk-video`'s `client_view` owns six small rules that all key off the same two sizes:
//! whether zoomed content overflows the pane, how far the pan may go, what scale relates the layer
//! to the decoded frame, whether an empty frame is worth a keyframe, whether a decoded buffer is
//! the size the host just acked, and when a live drag has settled enough to ask for a resize.
//!
//! ## They cross as sizes, because that is all they read
//! Every one of them is a fold over two or three sizes and a scalar, so each is a plain by-value
//! entry point. The one accumulator among them — the resize debounce — is four fields the near side
//! reads all of, so §4b makes it a record that rides in and out rather than a handle: a Swift
//! `struct` copied by value cannot own an allocation without two copies aliasing it.
//!
//! ## An optional previous size crosses as a value and a flag
//! "No frame has arrived yet" and "the last frame was zero by zero" are different states, and only
//! one of them means adopt. A sentinel size cannot say which, so the presence rides beside the
//! value — the same shape the stall verdict's stamps already use.

use slopdesk_video::client_view::{
    FrameDecodability, ResizeDebounce, ResizeDecision, SNAP_EPSILON, inferred_capture_scale, is_navigable,
    max_pan_offset, should_adopt_resize, should_snap, snap_target_points, video_scale,
};

use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoSize};

/// Non-empty — submit it to the decoder.
pub const SLOPDESK_FRAME_DECODABLE: u32 = 0;
/// An empty DELTA — drop it without touching the decoder. One lost delta does not warrant a
/// re-anchor; the reassembler's loss recovery covers a genuine gap.
pub const SLOPDESK_FRAME_DROP_SILENTLY: u32 = 1;
/// An empty KEYFRAME — ask the host for a fresh one, without invalidating a healthy session.
pub const SLOPDESK_FRAME_REQUEST_KEYFRAME: u32 = 2;

/// Still mid-burst, or inside the jitter band: do nothing.
pub const SLOPDESK_RESIZE_HOLD: u32 = 0;
/// The size settled and differs enough: emit a resize request for it.
pub const SLOPDESK_RESIZE_REQUEST: u32 = 1;

/// The client-side resize debounce, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskResizeDebounce {
    /// The size of the last request actually emitted.
    pub last_requested: SlopDeskVideoSize,
    /// Whether one was ever emitted — a zero size is a size, not an absence.
    pub has_last_requested: bool,
    /// The epoch of that request. Zero means none has been emitted.
    pub last_epoch: u32,
    /// The per-axis jitter band, in points.
    pub min_delta: f64,
    /// How long the layer must be unchanged before a burst counts as settled, in seconds.
    pub settle_interval: f64,
}

/// Whether displayed content extends beyond the pane on some axis.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_client_is_navigable(
    window: SlopDeskVideoSize,
    pane: SlopDeskVideoSize,
    zoom: f64,
) -> bool {
    is_navigable(window.of(), pane.of(), zoom)
}

/// The maximum pan offset per axis, in display points on a top-left basis.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_client_max_pan_offset(
    window: SlopDeskVideoSize,
    pane: SlopDeskVideoSize,
    zoom: f64,
) -> SlopDeskVideoPoint {
    let offset = max_pan_offset(window.of(), pane.of(), zoom);
    SlopDeskVideoPoint {
        x: offset.x,
        y: offset.y,
    }
}

/// The single uniform scale relating the host window to the on-screen layer.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_client_video_scale(
    layer_size: SlopDeskVideoSize,
    decoded_size: SlopDeskVideoSize,
) -> f64 {
    video_scale(layer_size.of(), decoded_size.of())
}

/// Pre-decode triage for a reassembled frame: one of the `SLOPDESK_FRAME_*` verdicts.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_frame_decodability(keyframe: bool, byte_count: usize) -> u32 {
    match FrameDecodability::classify(keyframe, byte_count) {
        FrameDecodability::Decodable => SLOPDESK_FRAME_DECODABLE,
        FrameDecodability::DropSilently => SLOPDESK_FRAME_DROP_SILENTLY,
        FrameDecodability::RequestKeyframe => SLOPDESK_FRAME_REQUEST_KEYFRAME,
    }
}

/// Whether the just-decoded buffer is the genuinely new size, rather than an in-flight old one.
///
/// `has_previous` is false for the first frame, which is not the same as a previous frame of zero
/// by zero.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_resize_should_adopt(
    pending: SlopDeskVideoSize,
    decoded: SlopDeskVideoSize,
    previous_decoded: SlopDeskVideoSize,
    has_previous: bool,
) -> bool {
    should_adopt_resize(
        pending.of(),
        decoded.of(),
        has_previous.then(|| previous_decoded.of()),
    )
}

/// The debounce the client uses when nothing was configured — the crate's own band and interval.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_resize_debounce_default() -> SlopDeskResizeDebounce {
    debounce_record(&ResizeDebounce::default())
}

/// A debounce with the given jitter band and settle interval.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_resize_debounce_new(
    min_delta: f64,
    settle_interval: f64,
) -> SlopDeskResizeDebounce {
    debounce_record(&ResizeDebounce::new(min_delta, settle_interval))
}

/// The decision for one layer-size sample: `SLOPDESK_RESIZE_HOLD` or `SLOPDESK_RESIZE_REQUEST`.
///
/// A pure query — the debounce does not move. Acting on a request means calling
/// [`slopdesk_resize_debounce_note_requested`] afterwards.
///
/// # Safety
/// `out` must be null, or point to one writable size for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_debounce_decide(
    debounce: SlopDeskResizeDebounce,
    layer_size: SlopDeskVideoSize,
    elapsed_since_last_change: f64,
    out: *mut SlopDeskVideoSize,
) -> u32 {
    let decision = debounce_of(debounce).decide(layer_size.of(), elapsed_since_last_change);
    let ResizeDecision::Request(size) = decision else {
        return SLOPDESK_RESIZE_HOLD;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one size.
        unsafe {
            std::ptr::write(out, SlopDeskVideoSize {
                width: size.width,
                height: size.height,
            });
        }
    }
    SLOPDESK_RESIZE_REQUEST
}

/// Records that a request went out, and answers the epoch it must carry.
///
/// # Safety
/// `debounce` must point to one live, writable record for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_debounce_note_requested(
    debounce: *mut SlopDeskResizeDebounce,
    size: SlopDeskVideoSize,
) -> u32 {
    // SAFETY: the caller's obligation above.
    unsafe { note(debounce, |working| working.note_requested(size.of())) }
}

/// Rebases the jitter baseline on a size the client adopted by itself, WITHOUT minting an epoch.
///
/// # Safety
/// As [`slopdesk_resize_debounce_note_requested`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_debounce_note_adopted(
    debounce: *mut SlopDeskResizeDebounce,
    size: SlopDeskVideoSize,
) {
    // SAFETY: as above.
    unsafe {
        note(debounce, |working| {
            working.note_adopted(size.of());
            working.last_epoch()
        });
    }
}

/// The layer point size at which the decoded stream renders one to one.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_snap_target_points(
    pixel_size: SlopDeskVideoSize,
    capture_scale: f64,
) -> SlopDeskVideoSize {
    let target = snap_target_points(pixel_size.of(), capture_scale);
    SlopDeskVideoSize {
        width: target.width,
        height: target.height,
    }
}

/// The HOST capture scale, inferred from the first decoded frame against the negotiated points.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_snap_inferred_capture_scale(
    decoded_pixels: SlopDeskVideoSize,
    window_points: SlopDeskVideoSize,
) -> f64 {
    inferred_capture_scale(decoded_pixels.of(), window_points.of())
}

/// Whether the pane should snap: the target differs from the current size by at least `epsilon`.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_snap_should_snap(
    target: SlopDeskVideoSize,
    current: SlopDeskVideoSize,
    epsilon: f64,
) -> bool {
    should_snap(target.of(), current.of(), epsilon)
}

/// The slack below which a snap is layout noise rather than a real difference.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_snap_epsilon() -> f64 {
    SNAP_EPSILON
}

/// Runs one mutation over the caller's debounce and writes it back.
///
/// # Safety
/// `debounce` must be null, or point to one live, writable record for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's debounce IS the boundary this module documents"
)]
unsafe fn note(
    debounce: *mut SlopDeskResizeDebounce,
    mutate: impl FnOnce(&mut ResizeDebounce) -> u32,
) -> u32 {
    if debounce.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let mut working = debounce_of(unsafe { std::ptr::read(debounce) });
    let epoch = mutate(&mut working);
    // SAFETY: as above; writable for one record.
    unsafe { std::ptr::write(debounce, debounce_record(&working)) };
    epoch
}

/// The crate's debounce, rebuilt from the record that crossed.
const fn debounce_of(record: SlopDeskResizeDebounce) -> ResizeDebounce {
    let last = if record.has_last_requested {
        Some(record.last_requested.of())
    } else {
        None
    };
    ResizeDebounce::restored(last, record.last_epoch, record.min_delta, record.settle_interval)
}

/// The record for a debounce that has just moved.
fn debounce_record(working: &ResizeDebounce) -> SlopDeskResizeDebounce {
    let last = working.last_requested();
    SlopDeskResizeDebounce {
        last_requested: last.map_or(
            SlopDeskVideoSize {
                width: 0.0,
                height: 0.0,
            },
            |size| {
                SlopDeskVideoSize {
                    width: size.width,
                    height: size.height,
                }
            },
        ),
        has_last_requested: last.is_some(),
        last_epoch: working.last_epoch(),
        min_delta: working.min_delta(),
        settle_interval: working.settle_interval(),
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    reason = "the tests call the C entry points, and the sizes here are exact small integers"
)]
mod tests {
    use super::{
        SLOPDESK_FRAME_DECODABLE, SLOPDESK_FRAME_DROP_SILENTLY, SLOPDESK_FRAME_REQUEST_KEYFRAME,
        SLOPDESK_RESIZE_HOLD, SLOPDESK_RESIZE_REQUEST, slopdesk_client_is_navigable,
        slopdesk_client_max_pan_offset, slopdesk_client_video_scale, slopdesk_frame_decodability,
        slopdesk_resize_debounce_decide, slopdesk_resize_debounce_default,
        slopdesk_resize_debounce_note_adopted, slopdesk_resize_debounce_note_requested,
        slopdesk_resize_should_adopt, slopdesk_snap_epsilon, slopdesk_snap_inferred_capture_scale,
        slopdesk_snap_should_snap, slopdesk_snap_target_points,
    };
    use crate::video_policy::SlopDeskVideoSize;

    fn of(width: f64, height: f64) -> SlopDeskVideoSize {
        SlopDeskVideoSize { width, height }
    }

    #[test]
    fn the_pan_gate_and_the_clamp_key_off_the_zoomed_size() {
        let window = of(800.0, 600.0);
        let pane = of(1000.0, 800.0);
        assert!(!slopdesk_client_is_navigable(window, pane, 1.0));
        assert!(slopdesk_client_is_navigable(window, pane, 2.0));
        let offset = slopdesk_client_max_pan_offset(window, pane, 2.0);
        assert_eq!(offset.x, 600.0);
        assert_eq!(offset.y, 400.0);
    }

    #[test]
    fn the_video_scale_keys_on_the_stable_axis_and_survives_a_degenerate_frame() {
        assert_eq!(
            slopdesk_client_video_scale(of(600.0, 400.0), of(1200.0, 800.0)),
            0.5
        );
        assert_eq!(slopdesk_client_video_scale(of(600.0, 400.0), of(0.0, 0.0)), 1.0);
    }

    #[test]
    fn an_empty_frame_asks_for_a_keyframe_only_when_it_was_one() {
        assert_eq!(slopdesk_frame_decodability(true, 900), SLOPDESK_FRAME_DECODABLE);
        assert_eq!(
            slopdesk_frame_decodability(true, 0),
            SLOPDESK_FRAME_REQUEST_KEYFRAME
        );
        assert_eq!(
            slopdesk_frame_decodability(false, 0),
            SLOPDESK_FRAME_DROP_SILENTLY
        );
    }

    #[test]
    fn an_absent_previous_frame_is_not_a_previous_frame_of_zero() {
        // No previous frame: the magnitude gate cannot reject, so the aspect gate decides.
        assert!(slopdesk_resize_should_adopt(
            of(800.0, 600.0),
            of(800.0, 600.0),
            of(0.0, 0.0),
            false
        ));
        // The same size as before is an in-flight old frame, whatever its aspect.
        assert!(!slopdesk_resize_should_adopt(
            of(800.0, 600.0),
            of(800.0, 600.0),
            of(800.0, 600.0),
            true
        ));
    }

    #[test]
    fn a_burst_holds_until_it_settles_and_then_mints_one_epoch() {
        let mut debounce = slopdesk_resize_debounce_default();
        let mut settled = of(0.0, 0.0);
        assert_eq!(
            unsafe { slopdesk_resize_debounce_decide(debounce, of(900.0, 700.0), 0.05, &raw mut settled) },
            SLOPDESK_RESIZE_HOLD,
            "still mid-drag"
        );
        assert_eq!(
            unsafe { slopdesk_resize_debounce_decide(debounce, of(900.0, 700.0), 0.5, &raw mut settled) },
            SLOPDESK_RESIZE_REQUEST
        );
        assert_eq!(settled.width, 900.0);
        let epoch = unsafe { slopdesk_resize_debounce_note_requested(&raw mut debounce, settled) };
        assert_eq!(epoch, 1);
        assert!(debounce.has_last_requested);
        assert_eq!(
            unsafe { slopdesk_resize_debounce_decide(debounce, of(902.0, 701.0), 0.5, &raw mut settled) },
            SLOPDESK_RESIZE_HOLD,
            "inside the jitter band"
        );
    }

    #[test]
    fn a_client_side_snap_rebases_the_baseline_without_minting_an_epoch() {
        let mut debounce = slopdesk_resize_debounce_default();
        unsafe { slopdesk_resize_debounce_note_adopted(&raw mut debounce, of(640.0, 480.0)) };
        assert_eq!(debounce.last_epoch, 0, "a snap never echoes a request back");
        assert!(debounce.has_last_requested);
        let mut settled = of(0.0, 0.0);
        assert_eq!(
            unsafe { slopdesk_resize_debounce_decide(debounce, of(640.0, 480.0), 1.0, &raw mut settled) },
            SLOPDESK_RESIZE_HOLD
        );
    }

    #[test]
    fn the_snap_target_is_the_host_windows_own_points() {
        assert_eq!(
            slopdesk_snap_inferred_capture_scale(of(2560.0, 1440.0), of(1280.0, 720.0)),
            2.0
        );
        let target = slopdesk_snap_target_points(of(2560.0, 1440.0), 2.0);
        assert_eq!(target.width, 1280.0);
        assert!(!slopdesk_snap_should_snap(
            target,
            of(1280.0, 720.0),
            slopdesk_snap_epsilon()
        ));
        assert!(slopdesk_snap_should_snap(
            target,
            of(1200.0, 720.0),
            slopdesk_snap_epsilon()
        ));
    }
}
