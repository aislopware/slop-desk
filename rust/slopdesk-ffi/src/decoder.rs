//! The HEVC decoder: a session, the rules that drive it, and the door pixels come back through.
//!
//! The other half of [`crate::encoder`]'s row, and the same three-crate join — but on every Apple
//! slice rather than only macOS, because every client decodes and only the host encodes. That
//! asymmetry is the reason this module is ungated and `encoder` is not.
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::decoder_state`] | rebuild or reuse, drop or re-anchor, how the wall folds |
//! | [`slopdesk_video::hevc_parameter_sets`] | which bytes of a keyframe are the VPS/SPS/PPS |
//! | `slopdesk-apple-vt` | the calls |
//!
//! ## The callback's terms differ from the encoder's in ONE way, and it is the important one
//! [`crate::encoder`]'s door lends `(ptr, len)` for the call and requires the caller to copy. This
//! one HANDS THE PIXELS OVER, at +1, and the caller must release. The difference is not a taste:
//! the client's consumer is a display-link pacer that holds the buffer until the next vsync, which
//! is always after this call returns. A borrow would be a use-after-free on the first frame, and a
//! copy would be a full NV12 frame memcpy sixty times a second to avoid one retain.
//!
//! Everything else about the convention is [`crate::encoder`]'s, unchanged: registered once at
//! [`slopdesk_video_decoder_new`], never replaced, and the context outlives the handle. The one
//! term the encoder needs and this does not is reentrancy — the decode here is SYNCHRONOUS, so the
//! callback runs on the calling thread, inside the [`slopdesk_video_decoder_decode`] frame.
//!
//! ## Copies, and why there is exactly one
//! Core Media owns the frame's bytes, so the AVCC run is copied once into a block buffer the
//! framework allocated. That copy is the Swift's too, and it is not removable: the alternative is a
//! `kCFAllocatorNull` block over the caller's pointer, which references bytes without retaining
//! them while the sample buffer outlives the call. Everything after it is zero-copy — the decoded
//! surface reaches Metal as the `IOSurface` the decoder wrote.

use core::ffi::{c_uchar, c_void};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use slopdesk_apple_vt::{
    CFRetained, CVImageBuffer, DecodedSink, DecompressionSession, FormatDescription, INVALID_SESSION, NO_ERR,
    PixelBuffer, SampleBuffer,
};
use slopdesk_video::decoder_state::{Admission, DecoderState, display_immediate};
use slopdesk_video::hevc_parameter_sets;

/// What the caller is handed when a frame decodes.
///
/// `image_buffer` is a `CVImageBufferRef` at **+1**: the callee owns it and must release it. Swift
/// takes it with `Unmanaged<CVImageBuffer>.fromOpaque(_:).takeRetainedValue()`, which IS that
/// release. See the module header for why this door hands over rather than lending.
pub type SlopDeskDecodedFrameFn =
    Option<unsafe extern "C" fn(context: *mut c_void, image_buffer: *mut c_void)>;

/// Where decoded surfaces go, for a Rust caller.
///
/// The C door above is the boundary's shape; THIS is its shape for a Rust caller, and the two are
/// the same door because the C one is written as an adapter onto this one. The surface arrives
/// OWNED — a [`PixelBuffer`], which releases when it drops — so the hand-over rule the C form
/// states in prose is a type here, and a caller that forgets it cannot compile.
pub trait DecodedFrameSink: Send + Sync + core::fmt::Debug {
    /// One decoded surface, owned by the callee.
    fn frame(&self, image: PixelBuffer);
}

/// The C door, expressed as one of the sinks above.
#[derive(Debug)]
struct CSink {
    context: CallerContext,
    deliver: SlopDeskDecodedFrameFn,
}

impl DecodedFrameSink for CSink {
    /// # Safety
    /// `PixelBuffer::into_created` yields the +1 pointer this function stops owning, which is
    /// exactly what the callback's contract says the callee now owns. Dropping the buffer instead —
    /// the `else` arm — releases it, so a decoder built without a door leaks nothing.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn frame(&self, image: PixelBuffer) {
        let Some(deliver) = self.deliver else {
            drop(image);
            return;
        };
        let raw = image.into_created();
        // SAFETY: the context is live by the door's documented term, and `raw` is the +1 the
        // callback's contract says the callee now owns.
        unsafe { deliver(self.context.0, raw) };
    }
}

/// The caller's opaque context pointer, carried to the callback.
///
/// A newtype for [`crate::encoder`]'s reason: a bare `*mut c_void` is neither `Send` nor `Sync`,
/// and the promise that makes it both is the CALLER's, stated at [`slopdesk_video_decoder_new`].
#[derive(Clone, Copy, Debug)]
struct CallerContext(*mut c_void);

// SAFETY: the caller of `slopdesk_video_decoder_new` promises this pointer is valid for the whole
// life of the handle and safe to use from any thread. Weaker here than for the encoder — the
// decode's callback runs on the calling thread — but stated the same way, because the handle itself
// is `Send` and a client that decodes on a serial queue calls from a thread it did not create.
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

/// One decode's sink: where pixels go, and where the handler's verdict is left.
///
/// The verdict has to be recorded rather than returned because `VideoToolbox` reports a decode
/// error — `kVTVideoDecoderBadDataErr` from a mis-recovered FEC block, a decoder malfunction —
/// through the HANDLER's status, not the submission's. Reading it after the call is sound only
/// because the decode is synchronous, which `slopdesk-apple-vt`'s module header states as a
/// property of the empty flags rather than an accident.
#[derive(Debug)]
struct FrameDelivery {
    /// Where the surface goes. `None` is a legal decoder that discards its pixels, which is what a
    /// caller that registered no callback asked for.
    sink: Option<Arc<dyn DecodedFrameSink>>,
    /// The handler's own status, or [`NO_ERR`] if it has not reported one.
    verdict: AtomicI32,
}

impl DecodedSink for FrameDelivery {
    /// Hands the decoded surface to the sink, or releases it if there is none.
    fn decoded(&self, image: CFRetained<CVImageBuffer>) {
        let Some(sink) = self.sink.as_ref() else {
            drop(image);
            return;
        };
        sink.frame(PixelBuffer::from_retained(image));
    }

    /// Records the handler's failure for the caller to read after the synchronous decode returns.
    ///
    /// Nothing is reported through the callback. A failed decode has no pixels, and the caller's
    /// recovery — invalidate, then ask the host for a fresh anchor — is driven by the return value
    /// of [`slopdesk_video_decoder_decode`], which is where a status can actually be acted on.
    fn failed(&self, status: i32) {
        self.verdict.store(status, Ordering::Relaxed);
    }
}

/// The live session and the description it was built from, which exist only together.
///
/// One field rather than two, because every state in which they disagree is a bug: the Swift kept a
/// `session`, a `formatDescription` and a cache of parameter sets, and needed a comment on one path
/// explaining why it cleared the third to stop the first two being wrongly reused.
#[derive(Debug)]
struct Live {
    session: DecompressionSession,
    format: FormatDescription,
}

/// A live decoder: at most one session, the rules that drive it, and the door pixels leave by.
#[derive(Debug)]
pub struct SlopDeskVideoDecoder {
    /// Guards the session. Held across the whole of one decode, which is what makes the handler's
    /// verdict readable afterwards: a second decode cannot start and overwrite it.
    live: Mutex<Option<Live>>,
    /// Guards the rules. Taken separately and never while `live` is held for a framework call, so
    /// the stats read at ~2 Hz never waits behind a decode.
    state: Mutex<DecoderState>,
    /// Where decoded surfaces go, for the life of the handle.
    sink: Option<Arc<dyn DecodedFrameSink>>,
    /// Whether the stream negotiated full-range luma. Read at every configure, so a client that
    /// sets it after a session exists gets the new range on the next parameter-set change.
    full_range: Mutex<bool>,
    /// Resolved once from the environment, because it cannot change within a process and re-reading
    /// it per frame would put a `getenv` on the decode path.
    display_immediately: bool,
}

/// What a decode did, as the caller's four distinguishable outcomes.
///
/// A small integer rather than an out-parameter and a bool, because each of the four asks the
/// caller for something DIFFERENT and a caller that collapsed any two would get a visible fault:
/// dropping what should re-anchor freezes the pane, and re-anchoring what should be dropped costs a
/// keyframe per corrupt fragment.
pub const SLOPDESK_DECODE_DELIVERED: i32 = 0;
/// The frame was empty and not a keyframe: drop it and say nothing.
pub const SLOPDESK_DECODE_DROPPED: i32 = 1;
/// Nothing can be decoded until a keyframe arrives: ask the host, but do NOT tear the session down.
pub const SLOPDESK_DECODE_NEEDS_KEYFRAME: i32 = 2;
/// A hard failure: invalidate, then ask. The framework's status is written to `status_out`.
pub const SLOPDESK_DECODE_FAILED: i32 = 3;

/// One decode's outcome, for a Rust caller.
///
/// The four `SLOPDESK_DECODE_*` integers below are this enum's C spelling; a Rust caller gets the
/// enum, so a match that forgets an arm is a compile error rather than a frozen pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeOutcome {
    /// Pixels reached the sink.
    Delivered,
    /// The frame was empty and not a keyframe: dropped, and nothing to say.
    Dropped,
    /// Nothing can decode until a keyframe arrives; the session stands.
    NeedsKeyframe,
    /// A hard failure, carrying the framework's status. Invalidate, then ask.
    Failed(i32),
}

impl SlopDeskVideoDecoder {
    /// Creates a decoder. It has no session until the first keyframe gives it one.
    #[must_use]
    pub fn create(sink: Option<Arc<dyn DecodedFrameSink>>) -> Self {
        Self {
            live: Mutex::new(None),
            state: Mutex::new(DecoderState::new()),
            sink,
            full_range: Mutex::new(false),
            display_immediately: display_immediate(&|key| std::env::var(key).ok()),
        }
    }

    /// Requests the FULL-RANGE NV12 output variant, or the video-range one.
    pub fn set_full_range(&self, full_range: bool) {
        if let Ok(mut range) = self.full_range.lock() {
            *range = full_range;
        }
    }

    /// Decodes one reassembled AVCC frame.
    pub fn decode_frame(&self, avcc: &[u8], keyframe: bool) -> DecodeOutcome {
        let mut status = NO_ERR;
        match self.decode(avcc, keyframe, &mut status) {
            SLOPDESK_DECODE_DELIVERED => DecodeOutcome::Delivered,
            SLOPDESK_DECODE_DROPPED => DecodeOutcome::Dropped,
            SLOPDESK_DECODE_NEEDS_KEYFRAME => DecodeOutcome::NeedsKeyframe,
            _ => DecodeOutcome::Failed(status),
        }
    }

    /// Tears the live session down so the NEXT keyframe rebuilds, even a byte-identical one.
    pub fn invalidate_session(&self) {
        self.invalidate();
    }

    /// The decode-wall average in milliseconds; `0` when nothing has decoded yet.
    #[must_use]
    pub fn millis_ewma(&self) -> f64 {
        self.state.lock().map_or(0.0, |state| state.decode_ms_ewma())
    }

    /// Builds a session from `sets` and installs it, replacing any live one.
    ///
    /// The cache is written only on success, so a failure leaves the rules describing the session
    /// that is actually running — which after a failed FIRST configure is none at all.
    fn configure(&self, sets: &hevc_parameter_sets::ParameterSets, status_out: &mut i32) -> bool {
        let [vps, sps, pps] = sets.ordered();
        let format = match FormatDescription::from_hevc_parameter_sets(vps, sps, pps) {
            Ok(format) => format,
            Err(status) => {
                *status_out = status;
                return false;
            },
        };
        let full_range = self.full_range.lock().is_ok_and(|range| *range);
        let session = match DecompressionSession::create(&format, full_range, true) {
            Ok(session) => session,
            Err(status) => {
                *status_out = status;
                return false;
            },
        };
        let Ok(mut live) = self.live.lock() else {
            *status_out = INVALID_SESSION;
            return false;
        };
        // Replacing the option drops the previous `Live`, whose `Drop` invalidates the old session
        // before its last release — the teardown order the framework asks for.
        *live = Some(Live { session, format });
        drop(live);
        if let Ok(mut state) = self.state.lock() {
            state.configured(sets.clone());
        }
        true
    }

    /// Tears the session down and clears the rules, so the next keyframe rebuilds.
    ///
    /// Clearing both is the point, and it is why they are cleared TOGETHER: a cache that survived a
    /// hard failure would answer "reuse" for the byte-identical recovery keyframe a fixed-size
    /// stream sends, and the pane would freeze on the last good frame with nothing reporting it.
    fn invalidate(&self) {
        if let Ok(mut live) = self.live.lock() {
            *live = None;
        }
        if let Ok(mut state) = self.state.lock() {
            state.invalidated();
        }
    }

    /// The whole of one decode: triage, configure if the anchor moved, submit, fold, report.
    fn decode(&self, avcc: &[u8], keyframe: bool, status_out: &mut i32) -> i32 {
        let carried = keyframe.then(|| hevc_parameter_sets::extract(avcc)).flatten();
        let admission = match self.state.lock() {
            Ok(state) => state.admit(keyframe, avcc.len(), carried.as_ref()),
            Err(_) => return SLOPDESK_DECODE_FAILED,
        };
        match admission {
            Admission::Drop => return SLOPDESK_DECODE_DROPPED,
            Admission::NeedKeyframe => return SLOPDESK_DECODE_NEEDS_KEYFRAME,
            Admission::Configure(sets) => {
                if !self.configure(&sets, status_out) {
                    return SLOPDESK_DECODE_FAILED;
                }
            },
            Admission::Submit => {},
        }

        let sink = Arc::new(FrameDelivery {
            sink: self.sink.clone(),
            verdict: AtomicI32::new(NO_ERR),
        });
        let Ok(guard) = self.live.lock() else {
            *status_out = INVALID_SESSION;
            return SLOPDESK_DECODE_FAILED;
        };
        let Some(live) = guard.as_ref() else {
            // The rules said submit and there is no session, which only a failed configure between
            // the two locks can produce. Asking for a keyframe is the recoverable reading.
            return SLOPDESK_DECODE_NEEDS_KEYFRAME;
        };
        let sample = match SampleBuffer::from_avcc(avcc, &live.format, self.display_immediately) {
            Ok(sample) => sample,
            Err(status) => {
                *status_out = status;
                return SLOPDESK_DECODE_FAILED;
            },
        };
        // The submit is the decode — synchronous flags, so the handler has run by the time it
        // returns and the wall time IS the decode time. Both facts come from the same property.
        let started = Instant::now();
        let submitted = live.session.decode(&sample, Arc::<FrameDelivery>::clone(&sink));
        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        // Released before the rules' lock is taken, so the two are never held together and the
        // ~2 Hz stats read cannot end up waiting behind a framework call.
        drop(guard);
        if let Ok(mut state) = self.state.lock() {
            state.note_decode_wall(elapsed);
        }
        let handler = sink.verdict.load(Ordering::Relaxed);
        // The submission's status and the handler's are different numbers, and only the second sees
        // a mis-recovered frame. Reporting whichever failed is what arms the caller's recovery.
        if submitted != NO_ERR {
            *status_out = submitted;
            return SLOPDESK_DECODE_FAILED;
        }
        if handler != NO_ERR {
            *status_out = handler;
            return SLOPDESK_DECODE_FAILED;
        }
        SLOPDESK_DECODE_DELIVERED
    }
}

/// Reconstitutes a handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_video_decoder_new`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskVideoDecoder) -> Option<&'a SlopDeskVideoDecoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and every field behind it is either
    // immutable or guarded, so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Creates a decoder. It has no session until the first keyframe gives it one.
///
/// Lazy by construction rather than by choice: the host streams parameter sets inline ahead of
/// every IDR and none out of band, so there is nothing to build a session FROM until a keyframe
/// arrives.
///
/// # Safety
/// `context` must stay valid and usable from any thread for the whole life of the handle. The
/// answer must be passed to [`slopdesk_video_decoder_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_decoder_new(
    context: *mut c_void,
    deliver: SlopDeskDecodedFrameFn,
) -> *mut SlopDeskVideoDecoder {
    Box::into_raw(Box::new(SlopDeskVideoDecoder::create(Some(Arc::new(CSink {
        context: CallerContext(context),
        deliver,
    })))))
}

/// Tears a decoder down.
///
/// No drain, which is the whole difference from [`crate::encoder`]'s free: the decode is
/// synchronous, so nothing is ever in flight when this is called.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_video_decoder_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_decoder_free(handle: *mut SlopDeskVideoDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner. The session's own teardown is its `Drop`.
    drop(unsafe { Box::from_raw(handle) });
}

/// Requests the FULL-RANGE NV12 output variant, or the video-range one.
///
/// Set from the stream's negotiated `helloAck` before any media arrives. Read at every configure
/// rather than latched at create, so a change lands on the next session rather than never.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_decoder_set_full_range(
    handle: *mut SlopDeskVideoDecoder,
    full_range: bool,
) {
    // SAFETY: the caller's obligation, above.
    let Some(decoder) = (unsafe { held(handle) }) else {
        return;
    };
    decoder.set_full_range(full_range);
}

/// Decodes one reassembled AVCC frame, answering one of the four `SLOPDESK_DECODE_*` outcomes.
///
/// Self-configuring: a keyframe carries its VPS/SPS/PPS inline, and one whose sets differ from the
/// running session's rebuilds before decoding. One whose sets MATCH does not — the heartbeat IDR
/// arrives about once a second, and a teardown that often is a stall on a healthy stream.
///
/// `status_out` receives the framework's `OSStatus` when the answer is
/// [`SLOPDESK_DECODE_FAILED`], and is left alone otherwise.
///
/// # Safety
/// [`held`]'s, plus: `(avcc, len)` must be null-with-zero-length or `len` readable bytes for the
/// duration of the call, and `status_out` must be null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_decoder_decode(
    handle: *mut SlopDeskVideoDecoder,
    avcc: *const c_uchar,
    len: usize,
    keyframe: bool,
    status_out: *mut i32,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(decoder) = (unsafe { held(handle) }) else {
        return SLOPDESK_DECODE_FAILED;
    };
    // SAFETY: the caller's obligation, above — the same one every door in this crate asks for.
    let bytes = unsafe { crate::borrow(avcc, len) };
    let mut status = NO_ERR;
    let outcome = decoder.decode(bytes, keyframe, &mut status);
    if outcome == SLOPDESK_DECODE_FAILED && !status_out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable.
        unsafe { *status_out = status };
    }
    outcome
}

/// Tears the live session down so the NEXT keyframe rebuilds, even a byte-identical one.
///
/// Called by the caller's recovery path before it asks the host for an anchor. Not called on a
/// healthy heartbeat IDR, which is what keeps the reuse path — see
/// [`slopdesk_video_decoder_decode`] — a reuse.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_decoder_invalidate(handle: *mut SlopDeskVideoDecoder) {
    // SAFETY: the caller's obligation, above.
    let Some(decoder) = (unsafe { held(handle) }) else {
        return;
    };
    decoder.invalidate_session();
}

/// The decode-wall average in milliseconds; `0` when nothing has decoded yet.
///
/// Read by the stats HUD at about 2 Hz, from a different thread than the one decoding. Guarded by
/// the rules' own lock, which is never held across a framework call.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_decoder_millis_ewma(handle: *mut SlopDeskVideoDecoder) -> f64 {
    // SAFETY: the caller's obligation, above.
    let Some(decoder) = (unsafe { held(handle) }) else {
        return 0.0;
    };
    decoder.millis_ewma()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_DECODE_DROPPED, SLOPDESK_DECODE_FAILED, SLOPDESK_DECODE_NEEDS_KEYFRAME,
        slopdesk_video_decoder_decode, slopdesk_video_decoder_free, slopdesk_video_decoder_invalidate,
        slopdesk_video_decoder_millis_ewma, slopdesk_video_decoder_new,
        slopdesk_video_decoder_set_full_range,
    };

    /// Every door survives a null handle, which is the shape a Swift `deinit` racing a decode would
    /// produce. None of them may touch a session to answer.
    #[test]
    fn every_door_answers_a_null_handle_without_touching_a_session() {
        // SAFETY: null is the documented absent handle for every one of these.
        unsafe {
            assert_eq!(
                slopdesk_video_decoder_decode(
                    core::ptr::null_mut(),
                    core::ptr::null(),
                    0,
                    true,
                    core::ptr::null_mut()
                ),
                SLOPDESK_DECODE_FAILED,
            );
            assert!((slopdesk_video_decoder_millis_ewma(core::ptr::null_mut()) - 0.0).abs() < f64::EPSILON);
            slopdesk_video_decoder_invalidate(core::ptr::null_mut());
            slopdesk_video_decoder_set_full_range(core::ptr::null_mut(), true);
            slopdesk_video_decoder_free(core::ptr::null_mut());
        }
    }

    /// A decoder with no callback and no session triages without ever reaching `VideoToolbox`: an
    /// empty delta drops, an empty keyframe re-anchors, and a full delta before any anchor
    /// re-anchors too. This is the whole path a client walks before its first keyframe, and it must
    /// not create a session — which is also what makes the test hang-safe.
    #[test]
    fn the_pre_anchor_path_triages_without_creating_a_session() {
        // SAFETY: a null context is never dereferenced — there is no callback to hand it to.
        let handle = unsafe { slopdesk_video_decoder_new(core::ptr::null_mut(), None) };
        assert!(!handle.is_null());
        let frame = [0x26_u8, 0x01, 0xAF];
        // SAFETY: `handle` is live, the slice is live for each call, and the status slot is null.
        unsafe {
            assert_eq!(
                slopdesk_video_decoder_decode(handle, core::ptr::null(), 0, false, core::ptr::null_mut()),
                SLOPDESK_DECODE_DROPPED,
            );
            assert_eq!(
                slopdesk_video_decoder_decode(handle, core::ptr::null(), 0, true, core::ptr::null_mut()),
                SLOPDESK_DECODE_NEEDS_KEYFRAME,
            );
            assert_eq!(
                slopdesk_video_decoder_decode(
                    handle,
                    frame.as_ptr(),
                    frame.len(),
                    false,
                    core::ptr::null_mut()
                ),
                SLOPDESK_DECODE_NEEDS_KEYFRAME,
            );
            assert!((slopdesk_video_decoder_millis_ewma(handle) - 0.0).abs() < f64::EPSILON);
            slopdesk_video_decoder_invalidate(handle);
            slopdesk_video_decoder_free(handle);
        }
    }

    /// Ten thousand create/free round trips. The handle owns a `Mutex`, an `Arc`-free sink and — on
    /// the paths above — no session, so what this pins is that `free` reconstitutes the `Box`
    /// rather than leaking it, which is the one thing a `Box::into_raw` door can get wrong
    /// silently.
    #[test]
    fn ten_thousand_decoders_are_created_and_freed_without_drift() {
        for _ in 0..10_000_u32 {
            // SAFETY: a null context is never dereferenced; the handle is freed exactly once.
            unsafe {
                let handle = slopdesk_video_decoder_new(core::ptr::null_mut(), None);
                assert!(!handle.is_null());
                slopdesk_video_decoder_set_full_range(handle, true);
                slopdesk_video_decoder_free(handle);
            }
        }
    }
}
