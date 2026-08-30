//! The HEVC encoder: one session, the rules that drive it, and the door frames come back through.
//!
//! The Swift host's video encoder was 1500 lines, of which roughly 350 called `VideoToolbox` and
//! the rest were rules nothing could reach — its own header conceded it was "COMPILED +
//! code-reviewed but NEVER instantiated in a test", because `VTCompressionSessionCreate` hangs
//! without a window server and a Screen-Recording grant.
//!
//! ## What is here, and what emphatically is not
//! Nothing in this module DECIDES anything. Three crates meet here and this file is the join:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::encoder_config`] | every knob, resolved and clamped |
//! | [`slopdesk_video::encoder_state`] | which properties to write, and when |
//! | `slopdesk-apple-vt` | the calls, and the read of what each encode produced |
//!
//! What this file adds is ORDER and LIFETIME: the session is opened lazily and at most once, a
//! deferred bracket settles before anything else touches the session, a frame's own quantiser is
//! decided against the settled state, and only then is the frame presented.
//!
//! ## Why this is `forbid(unsafe_code)` when it drives a framework
//! Because `slopdesk-apple-vt` answers only COPIES. It used to publish HEVC parameter sets as
//! `(pointer, length)` values — the SDK has no copy-out variant for them — and the single
//! `slice::from_raw_parts` that laid them in front of a slice had to be made by a crate allowed to
//! write one, which is why this driver lived in `slopdesk-ffi` until the Swift was deleted.
//! `EncodedSample::copy_parameter_sets_into` moved that read to the framework's own side under
//! `docs/57` §2's sample-memory amendment, so no framework pointer reaches this file and the daemon
//! that owns the encoder is the crate that holds it. `docs/61` §2 is the ledger for that move.
//!
//! ## The callback, and why it is a trait rather than a queue
//! A frame finishes when `VideoToolbox` decides it has, on a thread `VideoToolbox` chose, and it
//! must reach the wire before the next one arrives sixteen milliseconds later. Asking — a poll loop
//! — is latency added on purpose; a queue plus a wakeup is a callback with a queue in front of it.
//! So [`EncodedFrameSink`] is called on the framework's thread, exactly where the Swift closure it
//! replaces already ran, and its one term is that the bytes are borrowed for the call.
//!
//! ⚠️ GUI + TCC ONLY. `VTCompressionSessionCreate` hangs without a window server, so nothing below
//! [`Encoder::open`] can be reached by a test.

use core::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use slopdesk_apple_vt::{
    CVImageBuffer, CompressionSession, EncodedSample, FrameOptions, FrameSink, INVALID_SESSION, Key, NO_ERR,
    Spec, StringValue, Timestamp,
};
use slopdesk_video::encoder_config::{Config, DEFAULT_BITRATE, frame_delay_candidates};
use slopdesk_video::encoder_state::{AckedTokens, Bracket, EncoderState, Restore, Writes};

use crate::env::Overlay;

/// One finished frame, borrowed for the duration of the call.
///
/// A struct rather than seven parameters, because a sink implementation reading `true, false, true`
/// at its own signature would be guessing. The bytes are `&[u8]` and NOT owned: this is called on
/// `VideoToolbox`'s thread out of a buffer the encoder reuses, and a sink that needs them later
/// copies them, which is the one term the door states.
#[derive(Debug)]
pub struct FinishedFrame<'a> {
    /// The AVCC-framed access unit, parameter sets already prepended on a keyframe.
    pub avcc: &'a [u8],
    /// Whether the encoder made this an intra frame.
    pub keyframe: bool,
    /// Whether this was the near-lossless static refresh, which the wire tags differently.
    pub crisp: bool,
    /// The long-term-reference acknowledgement token, when the frame carries one.
    pub ltr_token: Option<i64>,
    /// Whether this encode asked to anchor on a reference the client acknowledged.
    ///
    /// The client's non-keyframe re-anchor admission: it is what lets a decoder accept a P-frame as
    /// a recovery point without waiting for an IDR.
    pub acked_anchored: bool,
}

/// Where finished frames go.
///
/// `Send + Sync` because the framework calls it on a thread of its own choosing — the same
/// obligation a C `refcon` API asks for informally, except that here the compiler holds the caller
/// to it.
pub trait EncodedFrameSink: Send + Sync + core::fmt::Debug {
    /// One finished frame. The bytes are valid for the duration of this call and must be copied.
    fn frame(&self, frame: &FinishedFrame<'_>);
}

/// What can go wrong, which is two things and was four.
///
/// The pair the Swift settled on: a create that could not produce a usable session, whatever the
/// reason, and an encode the framework refused. No caller ever matched on more than that — every
/// catch site logged the whole value — and a distinction nothing reads is not one to carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncodeError {
    /// The session could not be created, or a latency-critical property was rejected.
    SessionCreate(i32),
    /// The framework refused this frame.
    Encode(i32),
}

impl core::fmt::Display for EncodeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::SessionCreate(status) => write!(f, "the encoder session was refused (OSStatus {status})"),
            Self::Encode(status) => write!(f, "the encoder refused this frame (OSStatus {status})"),
        }
    }
}

impl std::error::Error for EncodeError {}

/// What a caller chooses about an encoder before it exists, in the units the caller has them.
///
/// Dimensions arrive as `usize` because everything upstream measures pixels that way, and are
/// clamped into the framework's `i32` at [`Encoder::open`] — the same `Int32(clamping:)` the Swift
/// wrote, and the same reason: a dimension that does not fit is a bug somewhere above, and
/// saturating turns it into a session that fails loudly rather than one built from a wrapped
/// negative.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Shape {
    /// Frame width in pixels.
    pub width: usize,
    /// Frame height in pixels.
    pub height: usize,
    /// The starting target, in bits per second.
    pub bitrate: i64,
    /// The nominal frame rate the rate-control window is sized for. Floored at one.
    pub fps: i64,
    /// Whether the source carries full-range luma.
    pub full_range: bool,
    /// Whether to negotiate long-term references.
    pub ltr_enabled: bool,
}

impl Default for Shape {
    /// The defaults the Swift's `init` spelled: the resolved bitrate, 60 fps, video range, no LTR.
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            bitrate: DEFAULT_BITRATE,
            fps: 60,
            full_range: false,
            ltr_enabled: false,
        }
    }
}

/// Everything the frame callback needs that does not change per frame.
#[derive(Debug)]
struct Delivery {
    /// Where finished frames go. `None` is a legal encoder that discards its output, which is what
    /// a caller that registered no sink asked for.
    sink: Option<Arc<dyn EncodedFrameSink>>,
    /// Frames the framework declined to fit under the budget since the last encode.
    ///
    /// Read and cleared on the ENCODE thread and folded into the drop-relief integrator there, so
    /// the framework's thread never touches the rate-control state.
    drops: AtomicI64,
    /// Reused across frames so assembling one does not allocate after the first few.
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

impl FrameSink for FrameDelivery {
    /// Assembles the frame and hands it over.
    ///
    /// ONE shape rather than a fast path and a fallback. The Swift had two and they drifted; the
    /// version of this that lived in `slopdesk-ffi` had two and the second could not see the
    /// first's keyframe flag. There is nothing to choose between here now: the frame crosses to
    /// the packetize lane on another thread, so it becomes owned bytes whatever this function
    /// answers, and the "zero-copy" branch only ever deferred that copy to its caller.
    fn encoded(&self, sample: &EncodedSample) {
        let Some(sink) = self.shared.sink.as_ref() else {
            return;
        };
        let Ok(mut scratch) = self.shared.scratch.lock() else {
            // A poisoned scratch buffer means a previous frame panicked mid-assembly. Dropping this
            // frame is right: the alternative is shipping whatever half-frame was left behind.
            return;
        };
        scratch.clear();
        scratch.reserve(sample.payload_len());
        // `false` is the ORDINARY answer — a delta frame carries no parameter sets and needs none.
        // It is also what a keyframe whose format description publishes nothing readable answers,
        // and that frame ships bare, exactly as the Swift shipped it: a client that already holds a
        // format description decodes it, and one that does not was not going to be helped by half a
        // prefix.
        let _unprefixed = sample.copy_parameter_sets_into(&mut scratch);
        if !sample.copy_payload_into(&mut scratch) {
            return;
        }
        sink.frame(&FinishedFrame {
            avcc: &scratch,
            keyframe: sample.is_keyframe(),
            crisp: self.crisp,
            ltr_token: sample.ltr_token(),
            acked_anchored: self.acked_anchored,
        });
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

/// A live encoder, or one that has not been opened yet.
///
/// Not `Clone` and not copied: the session is the thing, and two handles onto one session would be
/// two callers racing the same rate-control state through a lock that was sized for one.
#[derive(Debug)]
pub struct Encoder {
    shape: Shape,
    /// Every knob, resolved and clamped ONCE at construction.
    ///
    /// Resolved here rather than at [`Self::open`] because the knobs are the daemon's settings and
    /// those do not change while a session lives — `docs/58` says the restart IS the reload — and
    /// because a resolve inside `open` would re-read the overlay on a path that already hangs
    /// without a window server.
    config: Config,
    /// The pipeline-delay ladder to probe, in order. See [`Self::open`].
    frame_delays: Vec<i64>,
    /// Guards the rate-control state. Held for arithmetic AND for the property writes that follow
    /// it, so a frame and an actuator cannot interleave halfway through a bracket.
    state: Mutex<EncoderState>,
    /// Guarded separately: acknowledgements arrive from the host's recovery arm on a different
    /// cadence, and sharing the lock would put one behind a frame's quantiser decision.
    tokens: Mutex<AckedTokens>,
    shared: Arc<Delivery>,
    /// `None` until [`Self::open`] succeeds. The Swift kept the same shape and for the same reason:
    /// an encoder is constructed where its dimensions are known and opened where the window server
    /// is, and those are not the same moment.
    session: Option<CompressionSession>,
}

impl Encoder {
    /// Holds everything an encoder needs without touching the framework.
    ///
    /// Infallible on purpose. Nothing here can fail, and a constructor that returned a `Result` no
    /// caller could trigger would put a `?` in front of the one call that genuinely cannot hang.
    #[must_use]
    pub fn new(shape: Shape, sink: Option<Arc<dyn EncodedFrameSink>>, overlay: &Overlay) -> Self {
        let read = reader(overlay);
        let config = Config::resolve(&read, Some(qp_decouple(overlay)));
        let frame_delays = frame_delay_candidates(read("SLOPDESK_MAX_FRAME_DELAY").as_deref());
        let state = EncoderState::new(
            config,
            shape.bitrate,
            i64::try_from(shape.width).unwrap_or_else(|_| i64::from(i32::MAX)),
            i64::try_from(shape.height).unwrap_or_else(|_| i64::from(i32::MAX)),
            shape.fps.max(1),
        );
        Self {
            shape,
            config,
            frame_delays,
            state: Mutex::new(state),
            tokens: Mutex::new(AckedTokens::new()),
            shared: Arc::new(Delivery {
                sink,
                drops: AtomicI64::new(0),
                scratch: Mutex::new(Vec::new()),
            }),
            session: None,
        }
    }

    /// The dimensions and rate this encoder was built for, unchanged by opening.
    #[must_use]
    pub const fn shape(&self) -> Shape {
        self.shape
    }

    /// Whether a session exists behind this encoder.
    #[must_use]
    pub const fn is_open(&self) -> bool {
        self.session.is_some()
    }

    /// Creates the hardware session and applies the whole low-latency configuration.
    ///
    /// Idempotent: a second call on an open encoder is a no-op rather than a second session, which
    /// is what the Swift's `guard handle == nil else { return }` bought and what makes a bring-up
    /// that retries safe to write.
    ///
    /// Answers the framework's status on failure and leaves NO session behind — there is nothing
    /// partial to hand back, because a half-configured session encodes at a latency nobody chose
    /// and reports no fault. Only `RealTime` and `AllowFrameReordering` can refuse a create,
    /// because those two are the latency contract and their silent failure would leave a
    /// session that looks configured and encodes like the default one. Everything below them is
    /// best-effort: each is rejected outright on some HEVC encoders, and aborting on one would
    /// leave the host with a stream of zero frames rather than a soft one.
    ///
    /// ⚠️ HANGS without a window server and a Screen-Recording grant.
    ///
    /// # Errors
    /// [`EncodeError::SessionCreate`] with the framework's status.
    pub fn open(&mut self) -> Result<(), EncodeError> {
        if self.session.is_some() {
            return Ok(());
        }
        let session =
            CompressionSession::create(clamped(self.shape.width), clamped(self.shape.height), Spec {
                low_latency: true,
                require_hardware: true,
            })
            .map_err(EncodeError::SessionCreate)?;

        for key in [Key::RealTime, Key::AllowFrameReordering] {
            let status = session.set_bool(key, key == Key::RealTime);
            if status != NO_ERR {
                return Err(EncodeError::SessionCreate(status));
            }
        }
        let fps = self.shape.fps.max(1);
        let _ = session.set_int(Key::ExpectedFrameRate, fps);
        let _ = session.set_bool(
            Key::PrioritizeEncodingSpeedOverQuality,
            self.config.speed_over_quality,
        );
        // Smallest pipeline delay the encoder will accept, probed in order. A rejection is EXPECTED
        // — some encoders floor at one or two — and none accepted leaves the key unset, which is
        // the framework's own unlimited default.
        for delay in &self.frame_delays {
            if session.set_int(Key::MaxFrameDelayCount, *delay) == NO_ERR {
                break;
            }
        }
        // Opt OUT of the efficiency clock policy: it trades encode latency for watts, and this
        // trade goes the other way every time.
        let _ = session.set_bool(Key::MaximizePowerEfficiency, false);
        let _ = session.set_int(Key::MaxKeyFrameInterval, i64::from(i32::MAX));

        let creation = {
            let Ok(state) = self.state.lock() else {
                return Err(EncodeError::SessionCreate(INVALID_SESSION));
            };
            state.creation_writes()
        };
        if let Some(rate) = creation.average_bitrate {
            let status = session.set_int(Key::AverageBitRate, rate);
            if status != NO_ERR {
                return Err(EncodeError::SessionCreate(status));
            }
        }
        if let Some((bytes, seconds)) = creation.data_rate {
            let status = session.set_data_rate_limits(bytes, seconds);
            if status != NO_ERR {
                return Err(EncodeError::SessionCreate(status));
            }
        }
        let _ = session.disable_spatial_adaptive_qp();
        if let Some(qp) = creation.max_qp {
            let _ = session.set_int(Key::MaxAllowedFrameQP, i64::from(qp));
        }
        if self.shape.full_range {
            // Gated, because an unconditional set changes the parameter-set bytes and costs the
            // client a decoder rebuild on the first keyframe to say what the stream already said.
            // The luma RANGE is not set here at all — it rides the source pixel buffer's variant.
            let _ = session.set_string(Key::ColorPrimaries, StringValue::Primaries709);
            let _ = session.set_string(Key::TransferFunction, StringValue::Transfer709);
            let _ = session.set_string(Key::YCbCrMatrix, StringValue::Matrix709);
        }
        if self.shape.ltr_enabled {
            let _ = session.set_bool(Key::EnableLtr, true);
        }
        let _ = session.prepare();
        self.session = Some(session);
        Ok(())
    }

    /// Encodes one live frame from the capturer's NV12 buffer.
    ///
    /// # Errors
    /// [`EncodeError::Encode`], or [`EncodeError::SessionCreate`] with `kVTInvalidSessionErr` when
    /// there is no session to encode into.
    pub fn encode_live(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
        force_keyframe: bool,
        per_frame_max_qp: Option<i32>,
    ) -> Result<(), EncodeError> {
        Self::status(self.encode(
            image,
            presentation,
            force_keyframe,
            false,
            per_frame_max_qp,
            false,
        ))
    }

    /// Encodes a cheap refresh anchored on a reference the client acknowledged decoding.
    ///
    /// Deliberately UNBRACKETED: the crisp and compact brackets exist to shape an intra frame, and
    /// this is the alternative to one — a small delta that costs the client no decoder flush.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_ltr_refresh(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
    ) -> Result<(), EncodeError> {
        Self::status(self.encode(image, presentation, false, true, None, false))
    }

    /// Encodes the near-lossless static refresh: bracketed, drained on both sides, sharp.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_crisp(&self, image: &CVImageBuffer, presentation: Timestamp) -> Result<(), EncodeError> {
        let Ok(mut state) = self.state.lock() else {
            return Err(EncodeError::SessionCreate(INVALID_SESSION));
        };
        let bracket = state.begin_crisp();
        drop(state);
        Self::status(self.bracketed(image, presentation, bracket, true))
    }

    /// Encodes a recovery or heartbeat intra frame small enough to survive a burst, bracketed.
    ///
    /// Tagged `.live` on the wire, not crisp: it is an ordinary keyframe, just a smaller one.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_compact(&self, image: &CVImageBuffer, presentation: Timestamp) -> Result<(), EncodeError> {
        let Ok(mut state) = self.state.lock() else {
            return Err(EncodeError::SessionCreate(INVALID_SESSION));
        };
        let bracket = state.begin_compact();
        drop(state);
        Self::status(self.bracketed(image, presentation, bracket, false))
    }

    /// Actuates the live target bitrate. Answers whether it changed.
    pub fn set_live_bitrate(&self, target: i64) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        let (changed, writes) = state.set_live_bitrate(target);
        drop(state);
        self.apply(writes);
        changed
    }

    /// Sets the link controller's constant quantiser. Answers whether it changed.
    pub fn set_const_qp(&self, quantiser: i32) -> bool {
        self.state
            .lock()
            .is_ok_and(|mut state| state.set_const_qp(quantiser))
    }

    /// Records the congestion controller's verdict. Answers whether it changed.
    pub fn set_link_congested(&self, congested: bool) -> bool {
        self.state
            .lock()
            .is_ok_and(|mut state| state.set_link_congested(congested))
    }

    /// Hints the rate-control window at a new frame rate.
    ///
    /// Deliberately unbracketed and deliberately NOT paired with a bitrate change: fewer frames
    /// sharing the same budget is bigger, sharper frames, which is the whole point of stepping the
    /// cadence down.
    pub fn set_expected_frame_rate(&self, fps: i64) {
        if let Some(session) = self.session.as_ref() {
            let _ = session.set_int(Key::ExpectedFrameRate, fps.max(1));
        }
    }

    /// Stages a long-term-reference token the client acknowledged decoding.
    pub fn stage_acked_token(&self, token: i64) {
        if let Ok(mut tokens) = self.tokens.lock() {
            let _ = tokens.stage(token);
        }
    }

    /// Drops every staged token, because a keyframe just shipped and flushed the client's picture
    /// buffer, long-term references included.
    pub fn clear_staged_tokens(&self) {
        if let Ok(mut tokens) = self.tokens.lock() {
            tokens.clear();
        }
    }

    /// Blocks until every frame presented so far has reached the sink.
    ///
    /// Call before dropping this encoder on a resize swap: a session torn down with frames still
    /// queued discards output that was already encoded, and nothing anywhere reports it.
    pub fn complete_frames(&self) {
        if let Some(session) = self.session.as_ref() {
            let _ignored = session.complete_frames();
        }
    }

    /// Issues a plan's property writes.
    ///
    /// Best-effort throughout, which is the Swift's own reading: a rejected mid-session quantiser
    /// change ships a normal frame rather than aborting a stream.
    fn apply(&self, writes: Writes) {
        let Some(session) = self.session.as_ref() else {
            return;
        };
        if let Some(qp) = writes.max_qp {
            let _ = session.set_int(Key::MaxAllowedFrameQP, i64::from(qp));
        }
        if let Some(qp) = writes.min_qp {
            let _ = session.set_int(Key::MinAllowedFrameQP, i64::from(qp));
        }
        if let Some(rate) = writes.average_bitrate {
            let _ = session.set_int(Key::AverageBitRate, rate);
        }
        if let Some((bytes, seconds)) = writes.data_rate {
            let _ = session.set_data_rate_limits(bytes, seconds);
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
        let Some(session) = self.session.as_ref() else {
            return INVALID_SESSION;
        };
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
        let ltr_enabled = self.shape.ltr_enabled;
        let acknowledged = if ltr_enabled {
            self.tokens
                .lock()
                .map(|mut tokens| tokens.drain())
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        session.encode(
            image,
            presentation,
            FrameOptions {
                force_keyframe,
                force_ltr_refresh: ltr_enabled && force_ltr_refresh,
                acknowledged_ltr_tokens: &acknowledged,
            },
            Arc::new(FrameDelivery {
                shared: Arc::clone(&self.shared),
                crisp,
                acked_anchored: force_ltr_refresh,
            }),
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
            self.complete_frames();
        }
        self.apply(bracket.relax);
        let status = self.encode(image, presentation, true, false, None, crisp);
        if bracket.restore == Restore::Deferred {
            return status;
        }
        // This frame must finish under the RELAXED configuration before it goes back. Restoring
        // first is what silently produced a soft "crisp" refresh, encoded at the live ceiling.
        self.complete_frames();
        if let Ok(mut state) = self.state.lock() {
            let restore = state.end_bracket();
            drop(state);
            self.apply(restore);
        }
        status
    }

    /// Turns a framework status into the one error an encode can raise.
    ///
    /// `kVTInvalidSessionErr` is reported as a CREATE failure rather than an encode one, because
    /// that is whose fault it is: the frame was fine and there was nothing to give it to.
    const fn status(status: i32) -> Result<(), EncodeError> {
        match status {
            NO_ERR => Ok(()),
            INVALID_SESSION => Err(EncodeError::SessionCreate(INVALID_SESSION)),
            other => Err(EncodeError::Encode(other)),
        }
    }
}

impl Drop for Encoder {
    /// Drains before the session goes.
    ///
    /// Not optional and not the caller's to remember: a session invalidated with frames still
    /// queued silently discards output that was already encoded, so completing first is part of
    /// what dropping one MEANS here. [`Encoder::complete_frames`] is public as well, because a
    /// resize swap wants the drain to happen at a moment it chooses rather than whenever the
    /// old encoder's last reference goes.
    fn drop(&mut self) {
        self.complete_frames();
    }
}

/// The default target bitrate, in bits per second, before any knob.
#[must_use]
pub const fn default_bitrate() -> i64 {
    DEFAULT_BITRATE
}

/// The worst-case quantiser ceiling this daemon resolved, which is also what an absent per-frame
/// knob falls back to.
#[must_use]
pub fn max_allowed_frame_qp(overlay: &Overlay) -> i32 {
    Config::resolve(&reader(overlay), None).max_allowed_frame_qp
}

/// The const-QP seed, or `None` when the mode is off.
///
/// PRESENCE is what engages the mode, which is why this is asked rather than read: a knob whose
/// text is not a number in `[1, 51]` leaves the mode off, and only the resolver knows that.
#[must_use]
pub fn const_qp(overlay: &Overlay) -> Option<i32> {
    Config::resolve(&reader(overlay), None).const_qp
}

/// How this daemon reads a knob: the real environment FIRST, then the settings overlay.
///
/// That order is `docs/58`'s precedence, and it is the whole reason the encoder resolves through a
/// reader rather than calling `std::env` itself. Swift got here by folding `video-prefs.json` into
/// the process environment with `setenv` before launch; a Rust daemon cannot, because
/// `std::env::set_var` is `unsafe` and this crate — like every crate outside the two `CLAUDE.md`
/// families — forbids it. Composing the two lookups is the same precedence with none of the
/// mutation.
fn reader(overlay: &Overlay) -> impl Fn(&str) -> Option<String> + '_ {
    |key| std::env::var(key).ok().or_else(|| overlay.get(key))
}

/// Whether the quantiser dials are decoupled: the ONE knob a graphical setting may override.
///
/// Default-ON, and only the exact text `0` turns it off — `EnvConfig.boolDefaultOn`'s rule, and the
/// same one `SLOPDESK_QP_CEILING_ADAPT` is read by inside `encoder_config`.
fn qp_decouple(overlay: &Overlay) -> bool {
    reader(overlay)("SLOPDESK_QP_DECOUPLE").as_deref() != Some("0")
}

/// A pixel count as the framework's `i32`, saturating rather than wrapping.
fn clamped(pixels: usize) -> i32 {
    i32::try_from(pixels).unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::{EncodeError, Shape, clamped, const_qp, default_bitrate, max_allowed_frame_qp, qp_decouple};
    use crate::env::Overlay;

    /// Every knob below is read through the overlay, so the tests build one from text rather than
    /// touching the process environment — which is shared, and which `std::env::set_var` could not
    /// reach from this crate anyway.
    fn overlay(raw: &str) -> Overlay {
        Overlay::from_text(raw)
    }

    #[test]
    fn a_dimension_that_cannot_fit_saturates_rather_than_wrapping_negative() {
        assert_eq!(clamped(1920), 1920);
        assert_eq!(
            clamped(usize::MAX),
            i32::MAX,
            "a wrapped negative would build a session"
        );
    }

    #[test]
    fn the_default_bitrate_is_the_one_the_rules_crate_names() {
        assert_eq!(default_bitrate(), slopdesk_video::encoder_config::DEFAULT_BITRATE);
    }

    #[test]
    fn a_shape_defaults_to_the_swift_inits_own_arguments() {
        let shape = Shape::default();
        assert_eq!(shape.bitrate, default_bitrate());
        assert_eq!(shape.fps, 60);
        assert!(!shape.full_range, "video range, not full");
        assert!(!shape.ltr_enabled, "long-term references are opted into");
    }

    #[test]
    fn qp_decouple_is_on_unless_the_overlay_says_exactly_zero() {
        assert!(qp_decouple(&overlay("{}")), "absent means on");
        assert!(
            !qp_decouple(&overlay(r#"{"video":{"qpDecouple":false}}"#)),
            "the settings toggle is the only thing that turns it off"
        );
        assert!(qp_decouple(&overlay(r#"{"video":{"qpDecouple":true}}"#)));
    }

    #[test]
    fn the_quantiser_ceiling_comes_from_the_overlay_when_the_environment_is_silent() {
        let pinned = overlay(r#"{"rawOverrides":{"SLOPDESK_MAX_QP":"40"}}"#);
        assert_eq!(max_allowed_frame_qp(&pinned), 40);
    }

    #[test]
    fn const_qp_is_absent_unless_a_knob_names_a_quantiser_in_range() {
        assert_eq!(const_qp(&overlay("{}")), None);
        assert_eq!(
            const_qp(&overlay(r#"{"rawOverrides":{"SLOPDESK_CONST_QP":"nonsense"}}"#)),
            None,
            "text that is not a number leaves the mode OFF rather than seeding it"
        );
        assert_eq!(
            const_qp(&overlay(r#"{"rawOverrides":{"SLOPDESK_CONST_QP":"28"}}"#)),
            Some(28)
        );
    }

    #[test]
    fn an_encode_error_says_which_half_refused_and_names_the_status() {
        assert!(EncodeError::SessionCreate(-12903).to_string().contains("-12903"));
        assert!(EncodeError::Encode(-1).to_string().contains("refused this frame"));
    }

    /// The pipeline-delay ladder is resolved through the OVERLAY, not `std::env`. The version of
    /// this driver that lived in `slopdesk-ffi` read the process environment for this one knob
    /// while every other knob went through the reader, which was correct there — Swift had
    /// folded the settings in with `setenv` — and silently wrong the moment a Rust daemon owned
    /// the encoder.
    #[test]
    fn the_frame_delay_ladder_is_read_through_the_overlay() {
        let pinned = overlay(r#"{"rawOverrides":{"SLOPDESK_MAX_FRAME_DELAY":"3"}}"#);
        let candidates = slopdesk_video::encoder_config::frame_delay_candidates(
            super::reader(&pinned)("SLOPDESK_MAX_FRAME_DELAY").as_deref(),
        );
        assert_eq!(
            candidates.first().copied(),
            Some(3),
            "a pinned delay must be probed first"
        );
    }
}
