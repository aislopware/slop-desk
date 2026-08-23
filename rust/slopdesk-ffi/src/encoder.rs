//! The HEVC encoder: a session, the rules that drive it, and the one door frames come back through.
//!
//! `Sources/SlopDeskVideoHost/VideoEncoder.swift` was 1500 lines, of which roughly 350 called
//! `VideoToolbox` and the rest were rules nothing could reach — the file's own header conceded it
//! was "COMPILED + code-reviewed but NEVER instantiated in a test", because
//! `VTCompressionSessionCreate` hangs without a window server and a Screen-Recording grant. Three
//! crates meet here, and this module is the join and nothing else:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::encoder_config`] | every knob, resolved and clamped |
//! | [`slopdesk_video::encoder_state`] | which properties to write, and when |
//! | `slopdesk-apple-vt` | the calls, and the read of what each encode produced |
//!
//! ## The THIRD convention, and why the encoder is what earned it
//! This crate's header says an answer either crosses as `(out, cap) -> needed` or lives behind a
//! handle, and that "adding a third convention is a design change, not a patch". This is that
//! design change, made deliberately and confined to this module.
//!
//! The encoder is the one wrapped thing whose answers are not asked for. A frame finishes when
//! `VideoToolbox` decides it has, on a thread `VideoToolbox` chose, and it must reach the wire
//! before the next one arrives sixteen milliseconds later. The two existing conventions both
//! require the caller to ASK, so either would mean a poll loop — which is latency added on purpose
//! to preserve a rule about shapes — or a Rust-side queue plus a wakeup, which is a callback with a
//! queue in front of it. So the door is a `@convention(c)` function pointer and an opaque context,
//! called on `VideoToolbox`'s thread, exactly where the Swift closure it replaces already ran.
//!
//! The convention's terms, so it stays one door and not a habit:
//!
//! * The callback is given `(ptr, len)` valid ONLY for the duration of the call. It must copy.
//! * It is called on a framework thread, never reentrantly into this handle.
//! * Registered once at [`slopdesk_video_encoder_new`] and never changed, so there is no window in
//!   which a frame could arrive for a callback that has been replaced.
//! * The context outlives the handle. The caller guarantees it, and the handle is freed first.
//!
//! ## Copies, and why there is usually none
//! The Swift paid one copy for a delta and two for a keyframe: `Data(bytes:count:)` over the block
//! buffer, then `params + avcc`, which allocates and copies again. Here a delta whose block buffer
//! is contiguous — which is the ordinary case — is handed to Swift where the encoder left it, so
//! the only copy in the system is the one Swift makes building its own `Data`. A keyframe still
//! costs one, because the parameter sets live in the format description rather than inline and must
//! be laid down in front of the slice; it is assembled in a scratch buffer this handle reuses, so
//! it does not allocate either.

use core::ffi::{c_uchar, c_void};
use core::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use slopdesk_apple_vt::{
    CVImageBuffer, CompressionSession, EncodedSample, FrameOptions, FrameSink, INVALID_SESSION, Key, NO_ERR,
    Spec, StringValue, Timestamp,
};
use slopdesk_video::encoder_config::{Config, frame_delay_candidates};
use slopdesk_video::encoder_state::{AckedTokens, Bracket, EncoderState, Restore, Writes};

/// What the caller is handed when a frame finishes.
///
/// `avcc`/`len` are borrowed for the call ONLY. `ltr_token` is meaningful only when `has_ltr_token`
/// is set — a token may legitimately be any `i64`, so there is no sentinel to reserve.
pub type SlopDeskEncodedFrameFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        avcc: *const c_uchar,
        len: usize,
        keyframe: bool,
        crisp: bool,
        ltr_token: i64,
        has_ltr_token: bool,
        acked_anchored: bool,
    ),
>;

/// The caller's opaque context pointer, carried to a framework thread.
///
/// A newtype because a bare `*mut c_void` is neither `Send` nor `Sync`, and the promise that makes
/// it both is the CALLER's — stated at [`slopdesk_video_encoder_new`] and nowhere else.
#[derive(Clone, Copy, Debug)]
struct CallerContext(*mut c_void);

// SAFETY: the caller of `slopdesk_video_encoder_new` promises this pointer is valid for the whole
// life of the handle and safe to use from any thread. That promise is the door's documented term;
// it cannot be checked here, and it is the same one every `refcon`-shaped C API asks for.
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

/// Everything the sink needs that does not change per frame.
#[derive(Debug)]
struct Delivery {
    context: CallerContext,
    deliver: SlopDeskEncodedFrameFn,
    /// Frames the framework declined to fit under the budget since the last encode. Read and
    /// cleared on the encode thread and folded into the drop-relief integrator there, so the
    /// framework's thread never touches the rate-control state.
    drops: AtomicI64,
    /// Reused across keyframes so assembling parameter sets in front of a slice does not allocate.
    scratch: Mutex<Vec<u8>>,
}

/// One frame's sink: the shared delivery plus the two facts that are per-encode.
#[derive(Debug)]
struct FrameDelivery {
    shared: Arc<Delivery>,
    /// Whether this was the near-lossless static refresh, which the wire tags differently.
    crisp: bool,
    /// Whether this encode asked for a long-term-reference refresh, so the frame that comes back is
    /// anchored on a reference the client acknowledged rather than on an intra frame.
    acked_anchored: bool,
}

/// Big-endian length prefix width for an AVCC-framed NAL unit.
const AVCC_LENGTH_BYTES: usize = 4;

impl FrameDelivery {
    /// Hands one run of bytes to the caller.
    ///
    /// # Safety
    /// `bytes` must point at `len` initialised bytes that stay valid for this call. Both call sites
    /// satisfy it: one is the framework's own buffer, held by a live [`EncodedSample`]; the other
    /// is a `Vec` this module owns and is borrowing.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn hand_over(&self, sample: &EncodedSample, bytes: *const c_uchar, len: usize) {
        let Some(deliver) = self.shared.deliver else {
            return;
        };
        let token = sample.ltr_token();
        // SAFETY: the pointer is live for this call by the caller's obligation above, and the
        // context is live by the door's documented term.
        unsafe {
            deliver(
                self.shared.context.0,
                bytes,
                len,
                sample.is_keyframe(),
                self.crisp,
                token.unwrap_or_default(),
                token.is_some(),
                self.acked_anchored,
            );
        }
    }
}

impl FrameSink for FrameDelivery {
    /// Assembles the frame if it needs assembling, and hands it over.
    ///
    /// # Safety
    /// The parameter sets arrive as `(pointer, length)` VALUES because `docs/57` §2 bars
    /// `slopdesk-apple-vt` from making a slice of framework memory. Making it here is this crate's
    /// entire remit, and the lifetime half is answered by `sample`, which owns the format
    /// description the bytes belong to and is borrowed for the whole of this function.
    #[expect(
        unsafe_code,
        reason = "turning the framework's (ptr, len) into a slice is this crate's remit"
    )]
    fn encoded(&self, sample: &EncodedSample) {
        let sets = sample.parameter_sets();
        if sets.is_empty() {
            // The ordinary path — a delta frame, or a keyframe whose format description published
            // nothing, which the Swift shipped exactly the same way. If the framework left the
            // bytes in one run there is nothing to build.
            if let Some(run) = sample.contiguous_payload() {
                self.hand_over(sample, run.bytes.as_ptr().cast_const(), run.len);
                return;
            }
        }
        let Ok(mut scratch) = self.shared.scratch.lock() else {
            // A poisoned scratch buffer means a previous frame panicked mid-assembly. Dropping this
            // frame is right: the alternative is shipping whatever half-frame was left behind.
            return;
        };
        scratch.clear();
        let prefix: usize = sets.iter().map(|set| AVCC_LENGTH_BYTES + set.len).sum();
        scratch.reserve(prefix + sample.payload_len());
        for set in &sets {
            let Ok(len) = u32::try_from(set.len) else {
                // A parameter set that cannot carry a 32-bit AVCC length is not one; shipping a
                // truncated prefix would give the client a decoder it cannot build.
                return;
            };
            scratch.extend_from_slice(&len.to_be_bytes());
            // SAFETY: framework memory, above — `set` came from `sample`'s format description,
            // which `sample` holds for the whole of this call.
            scratch.extend_from_slice(unsafe { core::slice::from_raw_parts(set.bytes.as_ptr(), set.len) });
        }
        if !sample.copy_payload_into(&mut scratch) {
            return;
        }
        self.hand_over(sample, scratch.as_ptr(), scratch.len());
    }

    /// Counts a frame the framework declined to fit under the budget.
    ///
    /// Nothing is reported to the caller. A drop is not a failure the host acts on directly — it is
    /// the input to the drop-relief integrator, which lifts the quantiser ceiling so the NEXT
    /// frames coarsen instead of dropping too, and that fold happens on the encode thread.
    fn dropped(&self, _status: i32, _frame_dropped: bool) {
        self.shared.drops.fetch_add(1, Ordering::Relaxed);
    }
}

/// A live encoder: one session, the state that drives it, and the door frames leave by.
#[derive(Debug)]
pub struct SlopDeskVideoEncoder {
    session: CompressionSession,
    /// Guards the rate-control state. Held for arithmetic and for the property writes that follow
    /// it, so a frame and an actuator cannot interleave halfway through a bracket.
    state: Mutex<EncoderState>,
    /// Guarded separately: acknowledgements arrive from the host's recovery arm on a different
    /// cadence, and sharing the lock would put one behind a frame's quantiser decision.
    tokens: Mutex<AckedTokens>,
    shared: Arc<Delivery>,
    /// Whether the session was created with long-term references on. Gates both the per-frame token
    /// drain and the attachment read, so the off path pays for neither.
    ltr_enabled: bool,
}

impl SlopDeskVideoEncoder {
    /// Issues a plan's property writes. Best-effort throughout, which is the Swift's own reading:
    /// a rejected mid-session quantiser change ships a normal frame rather than aborting a stream.
    fn apply(&self, writes: Writes) {
        if let Some(qp) = writes.max_qp {
            let _ = self.session.set_int(Key::MaxAllowedFrameQP, i64::from(qp));
        }
        if let Some(qp) = writes.min_qp {
            let _ = self.session.set_int(Key::MinAllowedFrameQP, i64::from(qp));
        }
        if let Some(rate) = writes.average_bitrate {
            let _ = self.session.set_int(Key::AverageBitRate, rate);
        }
        if let Some((bytes, seconds)) = writes.data_rate {
            let _ = self.session.set_data_rate_limits(bytes, seconds);
        }
    }

    /// The whole of one encode: settle, decide, write, feed.
    ///
    /// Every entry point funnels through here so the ORDER is stated once — a deferred compact
    /// bracket is settled before anything else touches the session, the frame's own quantiser is
    /// decided against the settled state, and only then is the frame presented.
    fn encode(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
        force_keyframe: bool,
        force_ltr_refresh: bool,
        per_frame_max_qp: Option<i32>,
        crisp: bool,
    ) -> i32 {
        let drops = self.shared.drops.swap(0, Ordering::Relaxed);
        let (settle, writes) = {
            let Ok(mut state) = self.state.lock() else {
                return INVALID_SESSION;
            };
            let settle = state.settle_pending_compact();
            (settle, state.frame_writes(per_frame_max_qp, drops))
        };
        if let Some(settle) = settle {
            self.apply(settle);
        }
        self.apply(writes);
        let acknowledged = if self.ltr_enabled {
            self.tokens
                .lock()
                .map(|mut tokens| tokens.drain())
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let sink = Arc::new(FrameDelivery {
            shared: Arc::clone(&self.shared),
            crisp,
            acked_anchored: force_ltr_refresh,
        });
        self.session.encode(
            image,
            presentation,
            FrameOptions {
                force_keyframe,
                force_ltr_refresh: self.ltr_enabled && force_ltr_refresh,
                acknowledged_ltr_tokens: &acknowledged,
            },
            sink,
        )
    }

    /// Opens a bracket, encodes its one intra frame under the relaxed configuration, and puts the
    /// configuration back — draining on both sides when the bracket asked for it.
    fn bracketed(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
        bracket: Bracket,
        crisp: bool,
    ) -> i32 {
        if let Some(settle) = bracket.settle {
            self.apply(settle);
        }
        if bracket.drain {
            // Prior frames must finish under the LIVE configuration, not the relaxed one.
            let _ = self.session.complete_frames();
        }
        self.apply(bracket.relax);
        let status = self.encode(image, presentation, true, false, None, crisp);
        if bracket.restore == Restore::Deferred {
            return status;
        }
        // This frame must finish under the RELAXED configuration before it goes back. Restoring
        // first is what silently produced a soft "crisp" refresh, encoded at the live ceiling.
        let _ = self.session.complete_frames();
        if let Ok(mut state) = self.state.lock() {
            let restore = state.end_bracket();
            drop(state);
            self.apply(restore);
        }
        status
    }
}

/// Reconstitutes a handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_video_encoder_new`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskVideoEncoder) -> Option<&'a SlopDeskVideoEncoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and every field behind it is either
    // immutable or guarded, so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Reconstitutes the caller's pixel buffer for the duration of a call.
///
/// # Safety
/// `pixel_buffer` must be null, or a live `CVPixelBufferRef` the caller holds for the whole call.
/// The framework retains what it needs of it during `encode`, so it need not outlive the call.
#[expect(
    unsafe_code,
    reason = "the pixel buffer is a foreign pointer; asking whether it is live is this crate's remit"
)]
const unsafe fn image<'a>(pixel_buffer: *const c_void) -> Option<&'a CVImageBuffer> {
    if pixel_buffer.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, a live `CVPixelBufferRef` — which IS a
    // `CVImageBufferRef`, the same opaque Core Video type under a different name.
    Some(unsafe { &*pixel_buffer.cast::<CVImageBuffer>() })
}

/// Creates a hardware HEVC session and applies the whole low-latency configuration.
///
/// Answers null when the session could not be created or a latency-critical property was rejected —
/// there is nothing partial to hand back, because a half-configured session encodes at a latency
/// nobody chose and reports no fault. `status_out` receives the framework's `OSStatus` when it is
/// non-null, so the caller can log WHICH failure it was.
///
/// `qp_decouple` is the one knob a graphical setting may override; every other knob is resolved
/// from the environment on this side. `context` is carried, unread, to every frame callback.
///
/// # Safety
/// `context` must stay valid and usable from any thread for the whole life of the handle — the
/// callback runs on a framework thread. `status_out` must be null or writable. The answer must be
/// passed to [`slopdesk_video_encoder_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_new(
    width: i32,
    height: i32,
    bitrate: i64,
    fps: i64,
    full_range: bool,
    ltr_enabled: bool,
    qp_decouple: bool,
    context: *mut c_void,
    deliver: SlopDeskEncodedFrameFn,
    status_out: *mut i32,
) -> *mut SlopDeskVideoEncoder {
    let report = |status: i32| {
        if !status_out.is_null() {
            // SAFETY: non-null and, by the caller's obligation, writable.
            unsafe { *status_out = status };
        }
    };
    let config = Config::resolve(&|key| std::env::var(key).ok(), Some(qp_decouple));
    let state = EncoderState::new(config, bitrate, i64::from(width), i64::from(height), fps.max(1));
    let session = match CompressionSession::create(width, height, Spec {
        low_latency: true,
        require_hardware: true,
    }) {
        Ok(session) => session,
        Err(status) => {
            report(status);
            return core::ptr::null_mut();
        },
    };

    // The latency contract. `RealTime` and `AllowFrameReordering` are the two properties whose
    // silent failure would leave a session that looks configured and encodes like the default one,
    // so they are the only ones that can refuse a create.
    for key in [Key::RealTime, Key::AllowFrameReordering] {
        let status = session.set_bool(key, key == Key::RealTime);
        if status != NO_ERR {
            report(status);
            return core::ptr::null_mut();
        }
    }
    let _ = session.set_int(Key::ExpectedFrameRate, fps.max(1));
    let _ = session.set_bool(Key::PrioritizeEncodingSpeedOverQuality, config.speed_over_quality);
    // Smallest pipeline delay the encoder will accept, probed in order. A rejection is EXPECTED —
    // some encoders floor at one or two — and none accepted leaves the key unset, which is the
    // framework's own unlimited default.
    for delay in frame_delay_candidates(std::env::var("SLOPDESK_MAX_FRAME_DELAY").ok().as_deref()) {
        if session.set_int(Key::MaxFrameDelayCount, delay) == NO_ERR {
            break;
        }
    }
    // Opt OUT of the efficiency clock policy: it trades encode latency for watts, and this trade
    // goes the other way every time.
    let _ = session.set_bool(Key::MaximizePowerEfficiency, false);
    let _ = session.set_int(Key::MaxKeyFrameInterval, i64::from(i32::MAX));
    let creation = state.creation_writes();
    if let Some(rate) = creation.average_bitrate {
        let status = session.set_int(Key::AverageBitRate, rate);
        if status != NO_ERR {
            report(status);
            return core::ptr::null_mut();
        }
    }
    if let Some((bytes, seconds)) = creation.data_rate {
        let status = session.set_data_rate_limits(bytes, seconds);
        if status != NO_ERR {
            report(status);
            return core::ptr::null_mut();
        }
    }
    // Best-effort from here down. Each of these is rejected outright on some HEVC encoders, and
    // aborting on one would leave the host with a stream of zero frames rather than a soft one.
    let _ = session.disable_spatial_adaptive_qp();
    if let Some(qp) = creation.max_qp {
        let _ = session.set_int(Key::MaxAllowedFrameQP, i64::from(qp));
    }
    if full_range {
        // Gated, because an unconditional set changes the parameter-set bytes and costs the client
        // a decoder rebuild on the first keyframe to say what the stream already said. The luma
        // RANGE is not set here at all — it rides the source pixel buffer's own variant.
        let _ = session.set_string(Key::ColorPrimaries, StringValue::Primaries709);
        let _ = session.set_string(Key::TransferFunction, StringValue::Transfer709);
        let _ = session.set_string(Key::YCbCrMatrix, StringValue::Matrix709);
    }
    if ltr_enabled {
        let _ = session.set_bool(Key::EnableLtr, true);
    }
    let _ = session.prepare();
    report(NO_ERR);
    Box::into_raw(Box::new(SlopDeskVideoEncoder {
        session,
        state: Mutex::new(state),
        tokens: Mutex::new(AckedTokens::new()),
        shared: Arc::new(Delivery {
            context: CallerContext(context),
            deliver,
            drops: AtomicI64::new(0),
            scratch: Mutex::new(Vec::new()),
        }),
        ltr_enabled,
    }))
}

/// Drains and tears down an encoder.
///
/// The drain is not optional and not the caller's to remember: a session invalidated with frames
/// still queued silently discards output that was already encoded, so completing first is part of
/// what freeing MEANS here.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_video_encoder_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_free(handle: *mut SlopDeskVideoEncoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner.
    let encoder = unsafe { Box::from_raw(handle) };
    let _ = encoder.session.complete_frames();
    drop(encoder);
}

/// Encodes one live frame. Answers the framework's status; zero is success.
///
/// `per_frame_max_qp` is read only when `has_per_frame_max_qp` is set, which is the content-driven
/// ceiling being absent rather than being zero.
///
/// # Safety
/// [`held`]'s and [`image`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_encode_live(
    handle: *mut SlopDeskVideoEncoder,
    pixel_buffer: *const c_void,
    presentation_value: i64,
    presentation_timescale: i32,
    force_keyframe: bool,
    per_frame_max_qp: i32,
    has_per_frame_max_qp: bool,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let (Some(encoder), Some(image)) = (unsafe { held(handle) }, unsafe { image(pixel_buffer) }) else {
        return INVALID_SESSION;
    };
    encoder.encode(
        image,
        Timestamp {
            value: presentation_value,
            timescale: presentation_timescale,
        },
        force_keyframe,
        false,
        has_per_frame_max_qp.then_some(per_frame_max_qp),
        false,
    )
}

/// Encodes a cheap refresh anchored on an acknowledged long-term reference.
///
/// Deliberately unbracketed: the crisp and compact brackets exist to shape an intra frame, and this
/// is the alternative to one — a small delta that costs the client no decoder flush.
///
/// # Safety
/// [`held`]'s and [`image`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_encode_ltr_refresh(
    handle: *mut SlopDeskVideoEncoder,
    pixel_buffer: *const c_void,
    presentation_value: i64,
    presentation_timescale: i32,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let (Some(encoder), Some(image)) = (unsafe { held(handle) }, unsafe { image(pixel_buffer) }) else {
        return INVALID_SESSION;
    };
    encoder.encode(
        image,
        Timestamp {
            value: presentation_value,
            timescale: presentation_timescale,
        },
        false,
        true,
        None,
        false,
    )
}

/// Encodes the near-lossless static refresh, bracketed.
///
/// # Safety
/// [`held`]'s and [`image`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_encode_crisp(
    handle: *mut SlopDeskVideoEncoder,
    pixel_buffer: *const c_void,
    presentation_value: i64,
    presentation_timescale: i32,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let (Some(encoder), Some(image)) = (unsafe { held(handle) }, unsafe { image(pixel_buffer) }) else {
        return INVALID_SESSION;
    };
    let Ok(mut state) = encoder.state.lock() else {
        return INVALID_SESSION;
    };
    let bracket = state.begin_crisp();
    drop(state);
    encoder.bracketed(
        image,
        Timestamp {
            value: presentation_value,
            timescale: presentation_timescale,
        },
        bracket,
        true,
    )
}

/// Encodes a recovery or heartbeat intra frame small enough to survive a burst, bracketed.
///
/// Tagged `.live` on the wire, not crisp: it is an ordinary keyframe, just a smaller one.
///
/// # Safety
/// [`held`]'s and [`image`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_encode_compact(
    handle: *mut SlopDeskVideoEncoder,
    pixel_buffer: *const c_void,
    presentation_value: i64,
    presentation_timescale: i32,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let (Some(encoder), Some(image)) = (unsafe { held(handle) }, unsafe { image(pixel_buffer) }) else {
        return INVALID_SESSION;
    };
    let Ok(mut state) = encoder.state.lock() else {
        return INVALID_SESSION;
    };
    let bracket = state.begin_compact();
    drop(state);
    encoder.bracketed(
        image,
        Timestamp {
            value: presentation_value,
            timescale: presentation_timescale,
        },
        bracket,
        false,
    )
}

/// Actuates the live target bitrate. Answers whether it changed.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_set_live_bitrate(
    handle: *mut SlopDeskVideoEncoder,
    target: i64,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return false;
    };
    let Ok(mut state) = encoder.state.lock() else {
        return false;
    };
    let (changed, writes) = state.set_live_bitrate(target);
    drop(state);
    encoder.apply(writes);
    changed
}

/// Actuates the link controller's constant quantiser. Answers whether it changed.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_set_const_qp(
    handle: *mut SlopDeskVideoEncoder,
    q: i32,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return false;
    };
    encoder.state.lock().is_ok_and(|mut state| state.set_const_qp(q))
}

/// Records the controller's congestion verdict. Answers whether it changed.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_set_link_congested(
    handle: *mut SlopDeskVideoEncoder,
    congested: bool,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return false;
    };
    encoder
        .state
        .lock()
        .is_ok_and(|mut state| state.set_link_congested(congested))
}

/// Hints the encoder's rate-control window at a new frame rate.
///
/// Deliberately unbracketed and deliberately NOT paired with a bitrate change: fewer frames sharing
/// the same budget is bigger, sharper frames, which is the whole point of stepping the rate down.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_set_expected_frame_rate(
    handle: *mut SlopDeskVideoEncoder,
    fps: i64,
) {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return;
    };
    let _ = encoder.session.set_int(Key::ExpectedFrameRate, fps.max(1));
}

/// Stages a long-term-reference token the client acknowledged decoding.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_stage_acked_token(
    handle: *mut SlopDeskVideoEncoder,
    token: i64,
) {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return;
    };
    if let Ok(mut tokens) = encoder.tokens.lock() {
        let _ = tokens.stage(token);
    }
}

/// Drops every staged token, because an intra frame just shipped and flushed the client's
/// reference buffer.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_encoder_clear_staged_tokens(handle: *mut SlopDeskVideoEncoder) {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return;
    };
    if let Ok(mut tokens) = encoder.tokens.lock() {
        tokens.clear();
    }
}

/// Blocks until every frame presented so far has reached the callback.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_complete_frames(handle: *mut SlopDeskVideoEncoder) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(encoder) = (unsafe { held(handle) }) else {
        return INVALID_SESSION;
    };
    encoder.session.complete_frames()
}

// ---- The three knobs the CAPTURER and the session builder need before an encoder exists ----
//
// These are the PURE convention's shape reduced to its smallest case: no buffer, because the answer
// is one number. Zero is "absent" throughout, and it is not a reserved value dressed up as one —
// the HEVC quantiser range starts at 1, so zero cannot be a real answer to any of them.

/// The default target bitrate, in bits per second.
///
/// Read by the host's session builder as a parameter default, before any encoder is created.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const extern "C" fn slopdesk_video_encoder_default_bitrate() -> i64 {
    slopdesk_video::encoder_config::DEFAULT_BITRATE
}

/// The worst-case quantiser ceiling this process resolved, which is also what an absent per-frame
/// knob falls back to.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_video_encoder_max_allowed_frame_qp() -> i32 {
    Config::resolve(&|key| std::env::var(key).ok(), None).max_allowed_frame_qp
}

/// The const-QP seed this process resolved, or 0 when const-QP mode is off.
///
/// PRESENCE is what engages the mode, so the caller asks this rather than reading the variable: a
/// knob whose text is not a number leaves the mode off, and only this door knows that.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_video_encoder_const_qp() -> i32 {
    Config::resolve(&|key| std::env::var(key).ok(), None)
        .const_qp
        .unwrap_or(0)
}

/// One `[1, 51]` quantiser knob from its raw text, clamped; 0 when it is absent or not a number.
///
/// # Safety
/// `(raw, len)` must be null-with-zero-length, or `len` readable bytes for the duration of the
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_video_encoder_qp_knob(
    raw: *const c_uchar,
    len: usize,
    fallback: i32,
) -> i32 {
    // SAFETY: the caller's obligation, above — the same one every door in this crate asks for.
    let bytes = unsafe { crate::borrow(raw, len) };
    slopdesk_video::encoder_config::qp_knob(core::str::from_utf8(bytes).ok(), fallback).unwrap_or(0)
}
