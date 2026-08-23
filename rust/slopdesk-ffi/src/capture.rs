//! The capture stream: what to point it at, what comes back, and the rules behind both.
//!
//! `Sources/SlopDeskVideoHost/WindowCapturer.swift` carried two unrelated jobs in one 2 300-line
//! file: the `ScreenCaptureKit` calls, and the frame-decision pipeline the delivered frames feed
//! (the backlog pacer, the adaptive-QP measurement, the scroll reprojection, the static-IDR timer).
//! Only the first is here. Three crates meet at this door and it is the join and nothing else:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::capture_config`] | every clamp, every default, which filter a window wants |
//! | `slopdesk-apple-sck` | the framework calls, and the read of what each sample buffer IS |
//! | this module | the pointers, the queues, and the three callbacks |
//!
//! ## The callback convention, which is the encoder's
//! [`crate::encoder`] documents why a wrapped thing whose answers are not ASKED for gets a
//! `@convention(c)` function pointer rather than an `(out, cap)` answer, and a capture stream is
//! the same shape for the same reason: a frame arrives when the window server decides it has, on a
//! queue the caller named, and it must reach the encoder before the next one. The terms are that
//! module's, verbatim:
//!
//! * Each callback is given borrowed pointers valid ONLY for the duration of the call.
//! * They are called on the queues passed to [`slopdesk_capture_start`], never reentrantly.
//! * Registered once at start and never changed.
//! * The context outlives the handle, which the caller guarantees and frees second.
//!
//! ## The queues are the caller's, and that is load-bearing
//! The frame queue is the same serial queue the host's static-IDR timer runs on, and that sharing
//! IS the discipline that lets the capture callback and the timer touch one cached frame with no
//! lock. A queue made on this side would silently break it. The audio queue is a second one so a
//! slow synchronous encode cannot delay a 10 ms audio buffer.
//!
//! ## Why the target is an ID rather than a pointer
//! An `SCWindow` never crosses this door. The Swift it replaces already re-resolved the window by
//! `CGWindowID` at the top of its own start path, because the mint flow moves the window onto the
//! virtual display AFTER the object the caller enumerated was made — so that object's frame is the
//! pre-move one and the display-local crop computed from it would be wrong. Naming the window by
//! id makes that re-resolution the only path rather than a correction inside one.

use core::ffi::c_void;
use std::sync::{Arc, Mutex};

use slopdesk_apple_sck::{
    CMSampleBuffer, CMTime, CVImageBuffer, CaptureRegion, CaptureSink, CaptureStream, CaptureTarget,
    DispatchQueue, NO_TARGET, StartRequest, TIMED_OUT,
};
use slopdesk_video::capture_config::{
    CaptureMode, can_resize_in_place, mode_for_region, resolve_capture_hz, resolve_capture_mode,
    resolve_heartbeat, resolve_idr_poll_tick, resolve_queue_depth, resolve_quiet_window,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect};

use crate::borrow;

/// The mode integer for the per-window compositor, as the header spells it.
pub const SLOPDESK_CAPTURE_MODE_WINDOW: i32 = 0;

/// The mode integer for the display filter that excludes nothing.
pub const SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING: i32 = 1;

/// The mode integer for the display filter that composites only the target window.
pub const SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING: i32 = 2;

/// A frame carrying NEW pixels.
///
/// `image_buffer` is a `CVImageBufferRef` borrowed for the call ONLY — the surface behind it goes
/// back to the framework's pool when the callback returns, so anything kept must be copied or
/// retained. The presentation time is split into its two `CMTime` fields rather than passed as a
/// struct, because a `CMTime` also carries flags and an epoch that no caller of this reads.
pub type SlopDeskCaptureFrameFn = Option<
    unsafe extern "C" fn(context: *mut c_void, image_buffer: *const c_void, value: i64, timescale: i32),
>;

/// An audio buffer, as a `CMSampleBufferRef` borrowed for the call only.
pub type SlopDeskCaptureAudioFn =
    Option<unsafe extern "C" fn(context: *mut c_void, sample_buffer: *const c_void)>;

/// The stream stopped ITSELF.
///
/// The shared window closed, the display was unplugged, the Screen-Recording grant was revoked, the
/// window server reset. Never called for a deliberate [`slopdesk_capture_stop`].
pub type SlopDeskCaptureStoppedFn = Option<unsafe extern "C" fn(context: *mut c_void)>;

/// Everything [`slopdesk_capture_start`] needs, as one record.
///
/// A struct rather than fifteen arguments: the fields are read together, several are meaningless
/// without their neighbour (`region_*` without `has_region`, `display_id` without a zero
/// `window_id`), and a mis-ordered argument list of same-typed scalars is the failure this shape
/// cannot have.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskCaptureDesc {
    /// Window points × this = the output buffer's pixels.
    pub capture_scale: f64,
    /// The region's origin x in its display's local points. Read only when `has_region`.
    pub region_x: f64,
    /// The region's origin y in its display's local points. Read only when `has_region`.
    pub region_y: f64,
    /// The region's width in points. Read only when `has_region`.
    pub region_width: f64,
    /// The region's height in points. Read only when `has_region`.
    pub region_height: f64,
    /// The `CGWindowID` to capture, or `0` to capture the whole display named below.
    pub window_id: u32,
    /// The `CGDirectDisplayID` to capture when `window_id` is `0`, and the region's display when
    /// `has_region` is set. Ignored otherwise — a window's display is resolved from its centre.
    pub display_id: u32,
    /// Which filter to build: one of the three `SLOPDESK_CAPTURE_MODE_*` constants. A region
    /// overrides it, per [`mode_for_region`].
    pub mode: i32,
    /// Output buffer width in pixels.
    pub pixel_width: i32,
    /// Output buffer height in pixels.
    pub pixel_height: i32,
    /// The encode rate. The delivery ceiling is resolved FROM it, by the same rule
    /// [`slopdesk_capture_hz`] answers, so the two cannot disagree.
    pub fps: i32,
    /// The audio tap's sample rate, or `0` for no tap at all.
    pub audio_sample_rate: i32,
    /// The audio tap's channel count. Read only when the sample rate is non-zero.
    pub audio_channel_count: i32,
    /// Capture the full-range NV12 variant rather than the video-range one.
    pub full_range: bool,
    /// Whether the four `region_*` fields and `display_id` name an explicit crop.
    pub has_region: bool,
}

/// The caller's opaque context pointer, carried to a framework queue.
///
/// A newtype for the reason [`crate::encoder`]'s is: a bare `*mut c_void` is neither `Send` nor
/// `Sync`, and the promise that makes it both is the CALLER's — stated at
/// [`slopdesk_capture_start`] and nowhere else.
#[derive(Clone, Copy, Debug)]
struct CallerContext(*mut c_void);

// SAFETY: the caller of `slopdesk_capture_start` promises this pointer is valid for the whole life
// of the handle and safe to use from any thread. That promise is the door's documented term; it
// cannot be checked here, and it is the same one every `refcon`-shaped C API asks for.
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Send for CallerContext {}
// SAFETY: as above.
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Sync for CallerContext {}

/// The three doors a delivery goes out through.
#[derive(Debug)]
struct Doors {
    context: CallerContext,
    frame: SlopDeskCaptureFrameFn,
    audio: SlopDeskCaptureAudioFn,
    stopped: SlopDeskCaptureStoppedFn,
}

impl CaptureSink for Doors {
    fn frame(&self, image: &CVImageBuffer, presentation: CMTime) {
        let Some(deliver) = self.frame else { return };
        let buffer: *const CVImageBuffer = image;
        // SAFETY: the caller's function pointer, called with a borrowed reference reinterpreted as
        // the `CVImageBufferRef` it already is — a Core Video object is its own address. The
        // pointer is documented as valid for the duration of this call and no longer, which is
        // exactly the lifetime of the `&CVImageBuffer` it came from.
        #[expect(
            unsafe_code,
            reason = "calling the caller's function pointer is the door's whole purpose"
        )]
        unsafe {
            deliver(
                self.context.0,
                buffer.cast::<c_void>(),
                presentation.value,
                presentation.timescale,
            );
        }
    }

    fn audio(&self, sample: &CMSampleBuffer) {
        let Some(deliver) = self.audio else { return };
        let buffer: *const CMSampleBuffer = sample;
        // SAFETY: as `frame`'s, with a `CMSampleBufferRef` instead.
        #[expect(
            unsafe_code,
            reason = "calling the caller's function pointer is the door's whole purpose"
        )]
        unsafe {
            deliver(self.context.0, buffer.cast::<c_void>());
        }
    }

    fn stopped(&self) {
        let Some(deliver) = self.stopped else { return };
        // SAFETY: as above, with no borrowed argument at all.
        #[expect(
            unsafe_code,
            reason = "calling the caller's function pointer is the door's whole purpose"
        )]
        unsafe {
            deliver(self.context.0);
        }
    }
}

/// A live capture stream, behind the lock that makes a resize and a re-anchor one at a time.
///
/// The lock is not defence against the framework — `SCStream` serialises itself. It is what makes
/// the RUST state consistent: a resize rewrites the stored configuration and spec, and a re-anchor
/// reads the same configuration to compute a delta from it, so two of them at once could compute
/// an origin against a size that no longer applies.
#[derive(Debug)]
pub struct SlopDeskCapture {
    stream: Mutex<CaptureStream>,
}

/// Reconstitutes a handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_capture_start`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskCapture) -> Option<&'a SlopDeskCapture> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and the one field behind it is a
    // `Mutex`, so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Reconstitutes a caller's dispatch queue for the duration of a call.
///
/// # Safety
/// `queue` must be null, or a live `dispatch_queue_t` the caller holds for the whole call. The
/// stream RETAINS it, so it need not outlive the call itself — but it must be alive AT it.
#[expect(
    unsafe_code,
    reason = "the queue is a foreign pointer; asking whether it is live is this crate's remit"
)]
const unsafe fn queue<'a>(queue: *const c_void) -> Option<&'a DispatchQueue> {
    if queue.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, a live `dispatch_queue_t` — which is what
    // `DispatchQueue` is a `repr(C)` opaque view of.
    Some(unsafe { &*queue.cast::<DispatchQueue>() })
}

/// The mode a raw integer names, defaulting to the per-window compositor.
const fn mode_of(raw: i32) -> CaptureMode {
    match raw {
        SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING => CaptureMode::DisplayExcluding,
        SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING => CaptureMode::DisplayIncluding,
        _ => CaptureMode::Window,
    }
}

/// The integer a mode is spelled as.
const fn code_of(mode: CaptureMode) -> i32 {
    match mode {
        CaptureMode::Window => SLOPDESK_CAPTURE_MODE_WINDOW,
        CaptureMode::DisplayExcluding => SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING,
        CaptureMode::DisplayIncluding => SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING,
    }
}

/// The environment as [`slopdesk_video::capture_config`] wants it.
fn env(key: &str) -> Option<String> {
    std::env::var(key).ok()
}

/// Turns a description into the request the capture crate takes.
fn request_of(desc: &SlopDeskCaptureDesc) -> StartRequest {
    let target = if desc.window_id == 0 {
        CaptureTarget::Display {
            display_id: desc.display_id,
        }
    } else {
        CaptureTarget::Window {
            window_id: desc.window_id,
            mode: mode_for_region(mode_of(desc.mode), desc.has_region),
            region: desc.has_region.then(|| {
                CaptureRegion {
                    display_id: desc.display_id,
                    display_local: VideoRect::xywh(
                        desc.region_x,
                        desc.region_y,
                        desc.region_width,
                        desc.region_height,
                    ),
                }
            }),
        }
    };
    StartRequest {
        target,
        pixel_width: desc.pixel_width,
        pixel_height: desc.pixel_height,
        capture_scale: desc.capture_scale,
        capture_hz: resolve_capture_hz(env("SLOPDESK_CAPTURE_HZ").as_deref(), desc.fps),
        queue_depth: resolve_queue_depth(env("SLOPDESK_CAPTURE_QUEUE_DEPTH").as_deref()),
        full_range: desc.full_range,
        audio_sample_rate: desc.audio_sample_rate,
        audio_channel_count: desc.audio_channel_count,
    }
}

/// Brings a capture stream up against the window or display the description names.
///
/// Answers null when it could not start, with `status_out` — when non-null — carrying either a
/// `ScreenCaptureKit` error code or one of the capture crate's own sentinels, so the caller can log
/// WHICH failure it was. ⚠️ BLOCKS on the framework, and requires a window server plus a
/// Screen-Recording grant.
///
/// # Safety
/// `desc` must point to a readable [`SlopDeskCaptureDesc`]. Both queues must be live
/// `dispatch_queue_t`s for the call. `context` must stay valid and usable from any thread for the
/// whole life of the handle — the callbacks run on those queues. `status_out` must be null or
/// writable. The answer must be passed to [`slopdesk_capture_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_start(
    desc: *const SlopDeskCaptureDesc,
    context: *mut c_void,
    frame: SlopDeskCaptureFrameFn,
    audio: SlopDeskCaptureAudioFn,
    stopped: SlopDeskCaptureStoppedFn,
    frame_queue: *const c_void,
    audio_queue: *const c_void,
    status_out: *mut i32,
) -> *mut SlopDeskCapture {
    let report = |status: i32| {
        if !status_out.is_null() {
            // SAFETY: non-null and, by the caller's obligation, writable.
            unsafe { *status_out = status };
        }
    };
    if desc.is_null() {
        report(NO_TARGET);
        return core::ptr::null_mut();
    }
    // SAFETY: non-null and, by the caller's obligation, readable for the length of the struct.
    let desc = unsafe { *desc };
    // SAFETY: the caller's obligation, above.
    let (Some(frames), Some(audios)) = (unsafe { queue(frame_queue) }, unsafe { queue(audio_queue) }) else {
        report(NO_TARGET);
        return core::ptr::null_mut();
    };
    let sink = Arc::new(Doors {
        context: CallerContext(context),
        frame,
        audio,
        stopped,
    });
    match CaptureStream::start(request_of(&desc), sink, frames, audios) {
        Ok(stream) => {
            report(0);
            Box::into_raw(Box::new(SlopDeskCapture {
                stream: Mutex::new(stream),
            }))
        },
        Err(status) => {
            report(status);
            core::ptr::null_mut()
        },
    }
}

/// Stops the capture and waits for the framework to confirm. Answers zero on success.
///
/// Separate from [`slopdesk_capture_free`] because the caller stops on its own actor's teardown
/// path and frees when the last reference goes, and those are not the same moment.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_stop(handle: *mut SlopDeskCapture) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(capture) = (unsafe { held(handle) }) else {
        return NO_TARGET;
    };
    capture.stream.lock().map_or(TIMED_OUT, |stream| stream.stop())
}

/// Releases a capture handle. Does NOT stop the stream — call [`slopdesk_capture_stop`] first.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_capture_start`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_capture_free(handle: *mut SlopDeskCapture) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `start` with no call in
    // flight — so this reconstitutes the unique owner.
    drop(unsafe { Box::from_raw(handle) });
}

/// Re-origins a display-anchored crop after the window moved, in GLOBAL points.
///
/// Answers `1` when the move was too small to be worth a reconfigure, `0` when the live stream took
/// the new crop, and a negative code otherwise. The caller forces a keyframe after a `0`: the crop
/// jump lands mid-GOP as a whole-frame delta, and an anchor right after it is what keeps a
/// late-joining client from decoding half of each.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_reanchor(handle: *mut SlopDeskCapture, x: f64, y: f64) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(capture) = (unsafe { held(handle) }) else {
        return NO_TARGET;
    };
    capture
        .stream
        .lock()
        .map_or(TIMED_OUT, |stream| stream.reanchor(VideoPoint::new(x, y)))
}

/// Resizes a display-anchored capture in place, keeping the crop's origin. Answers zero on success.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_resize(
    handle: *mut SlopDeskCapture,
    pixel_width: i32,
    pixel_height: i32,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(capture) = (unsafe { held(handle) }) else {
        return NO_TARGET;
    };
    capture
        .stream
        .lock()
        .map_or(TIMED_OUT, |mut stream| stream.resize(pixel_width, pixel_height))
}

/// Whether the crop is anchored to a display rather than to the window's own backing store.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_is_display_anchored(handle: *const SlopDeskCapture) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(capture) = (unsafe { held(handle) }) else {
        return false;
    };
    capture
        .stream
        .lock()
        .is_ok_and(|stream| stream.is_display_anchored())
}

/// Whether the crop is a poller-owned union region — an in-place resize must not touch one.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_is_union_anchored(handle: *const SlopDeskCapture) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(capture) = (unsafe { held(handle) }) else {
        return false;
    };
    capture
        .stream
        .lock()
        .is_ok_and(|stream| stream.is_union_anchored())
}

/// The delivery ceiling in Hz for an encode rate — the same resolution [`slopdesk_capture_start`]
/// applies, exposed because the caller's cadence gate takes its tolerance from it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_capture_hz(fps: i32) -> i32 {
    resolve_capture_hz(env("SLOPDESK_CAPTURE_HZ").as_deref(), fps)
}

/// The heartbeat IDR cadence, in seconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_capture_heartbeat_seconds() -> f64 {
    resolve_heartbeat(env("SLOPDESK_HEARTBEAT_S").as_deref())
}

/// The crisp quiet window, in seconds, for a given heartbeat — which ceilings it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_capture_quiet_window(heartbeat: f64) -> f64 {
    resolve_quiet_window(env("SLOPDESK_QUIET_MS").as_deref(), heartbeat)
}

/// The static-IDR poll interval, in seconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_capture_idr_tick() -> f64 {
    resolve_idr_poll_tick(env("SLOPDESK_IDR_TICK_MS").as_deref())
}

/// Which filter to build: one of the three `SLOPDESK_CAPTURE_MODE_*` constants.
///
/// The request arrives as text from the caller rather than being read here, because the caller
/// resolves it through a settings overlay in front of the environment — a GUI setting can force the
/// capture filter, and an empty overlay reads exactly like a bare environment lookup.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_capture_mode(
    raw: *const u8,
    len: usize,
    prefer_display_anchored: bool,
) -> i32 {
    // SAFETY: the caller's obligation, above — `borrow` is this crate's one reader of a
    // `(ptr, len)` pair and states the same one.
    let bytes = unsafe { borrow(raw, len) };
    let requested = core::str::from_utf8(bytes).ok().filter(|text| !text.is_empty());
    code_of(resolve_capture_mode(requested, prefer_display_anchored))
}

/// Whether a live resize may reconfigure the running stream instead of restarting it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const extern "C" fn slopdesk_capture_can_resize_in_place(
    enabled: bool,
    display_anchored: bool,
    union_owned: bool,
) -> bool {
    can_resize_in_place(enabled, display_anchored, union_owned)
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "reaching a pointer entry from a test is what the entry is for"
    )]
    #![expect(
        clippy::panic,
        reason = "an unreachable match arm in a test is a test failure"
    )]
    #![expect(clippy::expect_used, reason = "an absent value in a test is a test failure")]

    use slopdesk_apple_sck::CaptureTarget;
    use slopdesk_video::capture_config::CaptureMode;

    use super::{
        SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING, SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING,
        SLOPDESK_CAPTURE_MODE_WINDOW, SlopDeskCaptureDesc, code_of, mode_of, request_of,
        slopdesk_capture_can_resize_in_place, slopdesk_capture_hz, slopdesk_capture_mode,
    };

    /// A description naming a window with no region, which every test below varies.
    const fn window_desc() -> SlopDeskCaptureDesc {
        SlopDeskCaptureDesc {
            capture_scale: 2.0,
            region_x: 0.0,
            region_y: 0.0,
            region_width: 0.0,
            region_height: 0.0,
            window_id: 41,
            display_id: 0,
            mode: SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING,
            pixel_width: 1920,
            pixel_height: 1080,
            fps: 30,
            audio_sample_rate: 48_000,
            audio_channel_count: 2,
            full_range: true,
            has_region: false,
        }
    }

    /// The mode integers round-trip, and an integer the header does not name is the per-window
    /// compositor rather than a panic — a caller from another language cannot be trusted to have
    /// used the constants.
    #[test]
    fn every_mode_integer_round_trips_and_an_unknown_one_is_the_safe_default() {
        for mode in [
            CaptureMode::Window,
            CaptureMode::DisplayExcluding,
            CaptureMode::DisplayIncluding,
        ] {
            assert_eq!(mode_of(code_of(mode)), mode);
        }
        assert_eq!(mode_of(99), CaptureMode::Window);
        assert_eq!(mode_of(-1), CaptureMode::Window);
        assert_eq!(code_of(CaptureMode::Window), SLOPDESK_CAPTURE_MODE_WINDOW);
    }

    /// A zero window id is what names a DISPLAY target, so the two cannot both be asked for.
    #[test]
    fn a_zero_window_id_is_what_selects_the_whole_display() {
        let desc = SlopDeskCaptureDesc {
            window_id: 0,
            display_id: 7,
            ..window_desc()
        };
        assert_eq!(request_of(&desc).target, CaptureTarget::Display { display_id: 7 });
    }

    /// The description's scalars reach the request unchanged — the one thing a mis-laid `repr(C)`
    /// or a transposed field would break, and nothing downstream would notice.
    #[test]
    fn every_scalar_reaches_the_request_it_belongs_to() {
        let request = request_of(&window_desc());
        assert_eq!(request.pixel_width, 1920);
        assert_eq!(request.pixel_height, 1080);
        assert!((request.capture_scale - 2.0).abs() < f64::EPSILON);
        assert!(request.full_range);
        assert_eq!(request.audio_sample_rate, 48_000);
        assert_eq!(request.audio_channel_count, 2);
        assert_eq!(request.target, CaptureTarget::Window {
            window_id: 41,
            mode: CaptureMode::DisplayExcluding,
            region: None,
        });
    }

    /// A region overrides the mode asked for and carries its own display — the dialog-expand shape.
    #[test]
    fn a_region_overrides_the_mode_and_names_its_own_display() {
        let desc = SlopDeskCaptureDesc {
            mode: SLOPDESK_CAPTURE_MODE_WINDOW,
            has_region: true,
            display_id: 3,
            region_x: 12.0,
            region_y: 34.0,
            region_width: 560.0,
            region_height: 780.0,
            ..window_desc()
        };
        let CaptureTarget::Window { mode, region, .. } = request_of(&desc).target else {
            panic!("a non-zero window id names a window target");
        };
        assert_eq!(mode, CaptureMode::DisplayIncluding);
        let region = region.expect("a described region reaches the request");
        assert_eq!(region.display_id, 3);
        assert!((region.display_local.origin.x - 12.0).abs() < f64::EPSILON);
        assert!((region.display_local.size.height - 780.0).abs() < f64::EPSILON);
    }

    /// The text door answers the same integers the description takes, so a caller can hand the
    /// answer of one straight to the other.
    #[test]
    fn the_mode_door_answers_integers_the_description_accepts() {
        let ask = |text: &str, prefer: bool| {
            // SAFETY: a live slice for the call.
            unsafe { slopdesk_capture_mode(text.as_ptr(), text.len(), prefer) }
        };
        assert_eq!(ask("window", true), SLOPDESK_CAPTURE_MODE_WINDOW);
        assert_eq!(ask("display", false), SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING);
        assert_eq!(ask("include", false), SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING);
        assert_eq!(ask("", true), SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING);
        // SAFETY: a null pointer with a zero length is the documented "absent" spelling.
        let absent = unsafe { slopdesk_capture_mode(core::ptr::null(), 0, false) };
        assert_eq!(absent, SLOPDESK_CAPTURE_MODE_WINDOW);
    }

    /// The pure doors answer what the crate behind them does. Not a re-test of the rules — a test
    /// that the door is wired to the right one, which is the only thing this layer can get wrong.
    #[test]
    fn the_pure_doors_answer_the_rule_behind_them() {
        if std::env::var_os("SLOPDESK_CAPTURE_HZ").is_none() {
            assert_eq!(slopdesk_capture_hz(30), 60);
        }
        assert!(slopdesk_capture_can_resize_in_place(true, true, false));
        assert!(!slopdesk_capture_can_resize_in_place(true, true, true));
        assert!(!slopdesk_capture_can_resize_in_place(false, true, false));
    }
}
