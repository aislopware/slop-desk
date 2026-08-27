//! The HEVC encoder, as this daemon holds it: a session that is opened once and the four ways a
//! frame can be handed to it.
//!
//! ## What is here, and what emphatically is not
//! Nothing in this module decides anything. The session, every property write, every knob resolved
//! and clamped, the crisp and compact brackets, the three quantiser regimes, the drop-relief
//! integrator and the deferred restore are all `slopdesk_ffi::encoder`'s, over `slopdesk-apple-vt`
//! and `slopdesk_video::encoder_config`/`encoder_state`. What this file adds is the four things
//! `VideoEncoder.swift` added on top of exactly the same calls, and which are the daemon's rather
//! than the encoder's:
//!
//! * the session is opened LAZILY and at most once, so a bring-up that runs twice costs nothing;
//! * the caller's `usize`-ish dimensions are clamped into the `i32` the framework takes;
//! * a non-zero `OSStatus` becomes a typed error instead of a number a caller must remember to
//!   compare against zero;
//! * the environment the knobs resolve through is the daemon's, not the process's.
//!
//! ## Why the encoder lives behind `slopdesk_ffi` and this crate reaches into it
//! Because that is where its ONE `unsafe` obligation is legal. HEVC parameter sets have no
//! copy-out variant in the SDK at all, so `slopdesk-apple-vt` answers them as `(NonNull<u8>,
//! usize)` VALUES and the single `slice::from_raw_parts` that turns them into a prefix is made in
//! `slopdesk-ffi`, whose entire `unsafe` remit `docs/57` §2 states is that question. Lifting the
//! driver into a crate of its own would make a FOURTH hand-written-`unsafe` crate, which
//! `CLAUDE.md` admits only for a MEASURED perf conflict — and this is code organisation. So the
//! daemon takes the dependency, and drives [`SlopDeskVideoEncoder`] through the values-form face
//! that module already documents as "its shape for a Rust caller". When the C doors die with the
//! Swift, the driver moves and this note goes with it.
//!
//! ⚠️ GUI + TCC ONLY. `VTCompressionSessionCreate` hangs without a window server, so nothing below
//! [`Encoder::open`] can be reached by a test.

use std::sync::Arc;

use slopdesk_apple_vt::{CVImageBuffer, Timestamp};
use slopdesk_ffi::encoder::{EncodedFrameSink, EncoderSpec, SlopDeskVideoEncoder};
use slopdesk_video::encoder_config::{Config, DEFAULT_BITRATE};

use crate::env::Overlay;

/// The status the Swift raised when an encode was asked of an encoder with no session.
///
/// `kVTInvalidSessionErr`. Named rather than spelled at the one site, because a reader who does not
/// recognise `-12903` cannot tell it from a framework refusal, and the two mean opposite things
/// about whose fault it is.
const NO_SESSION: i32 = -12903;

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
/// clamped into the framework's `i32` at [`Encoder::new`] — the same `Int32(clamping:)` the Swift
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

/// A live encoder, or one that has not been opened yet.
///
/// Not `Clone` and not copied: the session is the thing, and two handles onto one session would be
/// two callers racing the same rate-control state through a lock that was sized for one.
#[derive(Debug)]
pub struct Encoder {
    shape: Shape,
    sink: Arc<dyn EncodedFrameSink>,
    /// `None` until [`Self::open`] succeeds. The Swift kept the same shape and for the same reason:
    /// an encoder is constructed where its dimensions are known and opened where the window server
    /// is, and those are not the same moment.
    session: Option<SlopDeskVideoEncoder>,
}

impl Encoder {
    /// Holds everything an encoder needs without touching the framework.
    ///
    /// Infallible on purpose. Nothing here can fail, and a constructor that returned a `Result` no
    /// caller could trigger would put a `?` in front of the one call that genuinely cannot hang.
    #[must_use]
    pub fn new(shape: Shape, sink: Arc<dyn EncodedFrameSink>) -> Self {
        Self {
            shape,
            sink,
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
    /// ⚠️ HANGS without a window server and a Screen-Recording grant.
    ///
    /// # Errors
    /// [`EncodeError::SessionCreate`] with the framework's status, when the session could not be
    /// created or a latency-critical property was rejected.
    pub fn open(&mut self, overlay: &Overlay) -> Result<(), EncodeError> {
        if self.session.is_some() {
            return Ok(());
        }
        let spec = EncoderSpec {
            width: clamped(self.shape.width),
            height: clamped(self.shape.height),
            bitrate: self.shape.bitrate,
            fps: self.shape.fps.max(1),
            full_range: self.shape.full_range,
            ltr_enabled: self.shape.ltr_enabled,
            qp_decouple: qp_decouple(overlay),
        };
        let session = SlopDeskVideoEncoder::create(spec, &reader(overlay), Some(Arc::clone(&self.sink)))
            .map_err(EncodeError::SessionCreate)?;
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
        self.run(|session| session.encode_live(image, presentation, force_keyframe, per_frame_max_qp))
    }

    /// Encodes the near-lossless static refresh: bracketed, drained on both sides, sharp.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_crisp(&self, image: &CVImageBuffer, presentation: Timestamp) -> Result<(), EncodeError> {
        self.run(|session| session.encode_crisp(image, presentation))
    }

    /// Encodes a recovery or heartbeat intra frame small enough to survive a burst.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_compact(&self, image: &CVImageBuffer, presentation: Timestamp) -> Result<(), EncodeError> {
        self.run(|session| session.encode_compact(image, presentation))
    }

    /// Encodes a cheap refresh anchored on a reference the client acknowledged decoding.
    ///
    /// # Errors
    /// As [`Self::encode_live`].
    pub fn encode_ltr_refresh(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
    ) -> Result<(), EncodeError> {
        self.run(|session| session.encode_ltr_refresh(image, presentation))
    }

    /// Actuates the live target bitrate. Answers whether it changed.
    pub fn set_live_bitrate(&self, target: i64) -> bool {
        self.session
            .as_ref()
            .is_some_and(|session| session.set_live_bitrate(target))
    }

    /// Sets the link controller's constant quantiser. Answers whether it changed.
    pub fn set_const_qp(&self, quantiser: i32) -> bool {
        self.session
            .as_ref()
            .is_some_and(|session| session.set_const_qp(quantiser))
    }

    /// Records the congestion controller's verdict. Answers whether it changed.
    pub fn set_link_congested(&self, congested: bool) -> bool {
        self.session
            .as_ref()
            .is_some_and(|session| session.set_link_congested(congested))
    }

    /// Hints the rate-control window at a new frame rate.
    pub fn set_expected_frame_rate(&self, fps: i64) {
        if let Some(session) = self.session.as_ref() {
            session.set_expected_frame_rate(fps.max(1));
        }
    }

    /// Stages a long-term-reference token the client acknowledged decoding.
    pub fn stage_acked_token(&self, token: i64) {
        if let Some(session) = self.session.as_ref() {
            session.stage_acked_token(token);
        }
    }

    /// Drops every staged token, because a keyframe just shipped and flushed the client's picture
    /// buffer, long-term references included.
    pub fn clear_staged_tokens(&self) {
        if let Some(session) = self.session.as_ref() {
            session.clear_staged_tokens();
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

    /// Runs one framework call and turns a non-zero status into the one error an encode can raise.
    fn run(&self, body: impl FnOnce(&SlopDeskVideoEncoder) -> i32) -> Result<(), EncodeError> {
        let Some(session) = self.session.as_ref() else {
            return Err(EncodeError::SessionCreate(NO_SESSION));
        };
        match body(session) {
            0 => Ok(()),
            status => Err(EncodeError::Encode(status)),
        }
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
/// That order is `docs/58`'s precedence, and it is the whole reason the encoder takes a reader
/// rather than calling `std::env` itself. Swift got here by folding `video-prefs.json` into the
/// process environment with `setenv` before launch; a Rust daemon cannot, because
/// `std::env::set_var` is `unsafe` and this crate — like every crate outside the three `CLAUDE.md`
/// names — forbids it. Composing the two lookups is the same precedence with none of the mutation.
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
}
