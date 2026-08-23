//! One `VTCompressionSession`: created, configured, fed, drained, torn down.
//!
//! Every method here is a CALL. Which properties to set, at what values, in what order, and when to
//! put them back is `slopdesk_video::encoder_state`'s, which `forbid`s `unsafe` — see `docs/57` §2.
//! The only judgement this module makes is the one the framework forces: a create that fails with
//! the XPC race code is retried once, because a session that does not exist has no caller to report
//! to and the retry is part of the call rather than a policy over it.

use core::ptr::NonNull;
use std::sync::Arc;

use objc2_core_foundation::{CFArray, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_media::{CMSampleBuffer, CMTime, CMTimeFlags};
use objc2_core_video::CVImageBuffer;
use objc2_video_toolbox::{VTCompressionSession, VTEncodeInfoFlags, VTSessionSetProperty};

use crate::keys::{Key, QP_MODULATION_DISABLE, StringValue};
use crate::owned::{borrowed, created};
use crate::sample::EncodedSample;
use crate::status::{INVALID_SESSION, NO_ERR};

/// `kVTCouldNotFindVideoEncoderErr`-adjacent XPC create race, retried once by
/// [`CompressionSession::create`].
///
/// Not an error the caller can act on: the encoder service was mid-restart and the same call
/// succeeds a moment later. Named so the retry reads as the specific thing it is.
pub const XPC_CREATE_RACE: i32 = -12905;

/// HEVC, as the four-character code `CMVideoCodecType` wants.
///
/// Spelled from the bytes rather than as a decimal literal so it is legible: `hvc1`.
const HEVC: u32 = u32::from_be_bytes(*b"hvc1");

/// The `CoreMedia` sentinel for "no timestamp" — an all-zero `CMTime`, whose `Valid` flag is
/// therefore clear.
///
/// Built rather than read from `kCMTimeInvalid` because it is a plain value with public fields, so
/// constructing it costs no `unsafe` where reading the `extern` static would.
const fn invalid_time() -> CMTime {
    CMTime {
        value: 0,
        timescale: 0,
        flags: CMTimeFlags(0),
        epoch: 0,
    }
}

/// A presentation timestamp, as the rational the framework wants it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Timestamp {
    /// Numerator: `value / timescale` is the time in seconds.
    pub value: i64,
    /// Denominator, in ticks per second.
    pub timescale: i32,
}

impl Timestamp {
    /// The framework's `CMTime`, flagged valid.
    pub(crate) const fn cm(self) -> CMTime {
        CMTime {
            value: self.value,
            timescale: self.timescale,
            // `kCMTimeFlags_Valid` is bit zero. A timestamp built here is always a real one; the
            // "no timestamp" case is [`invalid_time`], which is a different value entirely.
            flags: CMTimeFlags(1),
            epoch: 0,
        }
    }
}

/// What a finished encode produced, handed to the caller's sink on `VideoToolbox`'s own thread.
///
/// A trait rather than a closure because the two outcomes are genuinely different events with
/// different consumers: a frame goes to the wire, a drop goes to the rate-control feedback loop.
/// Collapsing them into one callback with a nullable argument is what the Swift original did, and
/// it is why the drop path was easy to swallow silently.
pub trait FrameSink: Send + Sync + 'static {
    /// A frame finished and carries bytes.
    fn encoded(&self, sample: &EncodedSample);
    /// A frame was DROPPED by rate control, or the encode failed.
    ///
    /// `status` is the framework's, and `frame_dropped` reports its `kVTEncodeInfo_FrameDropped`
    /// bit. The pair matters: a drop at `noErr` is rate control declining to fit the frame under
    /// the budget, which is a signal to coarsen; a non-`noErr` status is a real failure.
    fn dropped(&self, status: i32, frame_dropped: bool);
}

/// The per-frame options dictionary, as a value rather than a built `CFDictionary`.
#[derive(Clone, Copy, Debug)]
pub struct FrameOptions<'a> {
    /// Force this frame to be an IDR.
    pub force_keyframe: bool,
    /// Ask the encoder to re-anchor against an acknowledged long-term reference.
    pub force_ltr_refresh: bool,
    /// The long-term-reference tokens the client has acknowledged decoding.
    pub acknowledged_ltr_tokens: &'a [i64],
}

impl FrameOptions<'_> {
    /// Whether this frame needs a dictionary at all.
    ///
    /// The common case is that it does not, and passing `None` rather than an empty dictionary is
    /// what keeps the steady-state delta path free of a per-frame `CoreFoundation` allocation.
    pub(crate) const fn is_empty(&self) -> bool {
        !self.force_keyframe && !self.force_ltr_refresh && self.acknowledged_ltr_tokens.is_empty()
    }

    /// The dictionary the framework wants, or `None` when there is nothing to say.
    pub(crate) fn cf(&self) -> Option<CFRetained<CFDictionary<CFString, CFType>>> {
        if self.is_empty() {
            return None;
        }
        let mut keys: Vec<&CFString> = Vec::with_capacity(3);
        let mut values: Vec<&CFType> = Vec::with_capacity(3);
        // Held so the borrows above outlive the build; `CFDictionary::from_slices` retains what it
        // is given, but not before it is given it.
        let truth = CFBoolean::new(true);
        let tokens: Option<CFRetained<CFArray<CFType>>> =
            (!self.acknowledged_ltr_tokens.is_empty()).then(|| {
                let numbers: Vec<CFRetained<CFNumber>> = self
                    .acknowledged_ltr_tokens
                    .iter()
                    .map(|token| CFNumber::new_i64(*token))
                    .collect();
                let borrowed: Vec<&CFType> = numbers.iter().map(|number| &***number).collect();
                CFArray::from_objects(&borrowed)
            });
        if self.force_keyframe {
            keys.push(Key::ForceKeyFrame.cf());
            values.push(&**truth);
        }
        if self.force_ltr_refresh {
            // `kCFBooleanTrue`, despite the header declaring the value type as `CFNumberRef`. The
            // capability probe that shipped before this port resolved the contradiction on real
            // hardware: the Boolean form is the one the encoder accepts.
            keys.push(Key::ForceLtrRefresh.cf());
            values.push(&**truth);
        }
        if let Some(tokens) = tokens.as_deref() {
            keys.push(Key::AcknowledgedLtrTokens.cf());
            values.push(&**tokens);
        }
        Some(CFDictionary::from_slices(&keys, &values))
    }
}

/// How the session is created — the keys that may only go in the CREATE dictionary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Spec {
    /// `EnableLowLatencyRateControl`. The measured difference between a 7.5 ms and a 24 ms encode.
    pub low_latency: bool,
    /// `RequireHardwareAcceleratedVideoEncoder`. Gating hardware HERE is deliberate: querying
    /// `UsingHardwareAcceleratedVideoEncoder` afterwards is rejected while low latency is on.
    pub require_hardware: bool,
}

/// A live compression session.
///
/// `Send`/`Sync` by the framework's own contract: `VTCompressionSessionEncodeFrame` and
/// `VTSessionSetProperty` are documented as callable from any thread, and the output handler is
/// invoked on a thread the framework chooses. The host relies on exactly that — the capture queue
/// encodes while the session actor actuates rate control.
#[derive(Debug)]
pub struct CompressionSession {
    session: CFRetained<VTCompressionSession>,
}

// SAFETY: framework rule — see the type's doc comment. A `VTCompressionSession` is a CF object with
// no thread affinity; VideoToolbox serialises its own state. The `CFRetained` inside is not `Send`
// on its own because CoreFoundation makes no blanket promise for every CF type, which is exactly
// the per-type judgement this impl is.
#[expect(
    unsafe_code,
    reason = "the framework documents the session as thread-safe; Rust cannot see that"
)]
#[expect(
    clippy::non_send_fields_in_send_ty,
    reason = "the field is the session; the promise is the framework's"
)]
unsafe impl Send for CompressionSession {}
// SAFETY: as above.
#[expect(
    unsafe_code,
    reason = "the framework documents the session as thread-safe; Rust cannot see that"
)]
unsafe impl Sync for CompressionSession {}

impl CompressionSession {
    /// Creates an HEVC session of `width`×`height`, retrying once on the XPC create race.
    ///
    /// # Errors
    /// The framework's `OSStatus`, verbatim, so the caller can report WHICH failure it was — there
    /// is exactly one recovery here and it is the framework's own, not a policy. The two a caller
    /// acts on differently are [`XPC_CREATE_RACE`], which has already been retried by the time it
    /// is returned, and `kVTVideoEncoderNotAvailableNowErr`, which means the hardware encoder is
    /// busy elsewhere.
    ///
    /// # Safety
    /// `VTCompressionSessionCreate` stores a **Create-rule** reference — one this caller owns and
    /// must release — through a caller-supplied slot. The slot is a live local of the declared type
    /// for the whole call, initialised to null, and the ownership is taken by
    /// [`crate::owned::created`], which is this crate's ONE Create-rule site under `docs/57` §2
    /// and the only thing that needs checking here: the callee's name contains `Create`.
    ///
    /// The output-callback parameter is passed NULL, with a null refcon, which the header requires
    /// of any session that will be fed through
    /// `VTCompressionSessionEncodeFrameWithOutputHandler` — and that is the only encode entry point
    /// [`Self::encode`] uses. Passing a function pointer here instead would mean carrying a
    /// `*mut c_void` refcon across every frame, which §2 bars this family from reconstituting.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    pub fn create(width: i32, height: i32, spec: Spec) -> Result<Self, i32> {
        let specification = spec.cf();
        let mut status = NO_ERR;
        // Two attempts, not a loop with a bound to read: the framework's documented recovery for
        // -12905 is one retry, and a second failure is a real one.
        for attempt in 0..2 {
            if attempt == 1 {
                if status != XPC_CREATE_RACE {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(75));
            }
            let mut slot: *mut VTCompressionSession = core::ptr::null_mut();
            // SAFETY: framework rule, above — the out-parameter's slot is live and correctly typed,
            // and the callback pair is the NULL the output-handler form requires.
            status = unsafe {
                VTCompressionSession::create(
                    None,
                    width,
                    height,
                    HEVC,
                    specification.as_deref().map(CFDictionary::as_opaque),
                    None,
                    None,
                    None,
                    core::ptr::null_mut(),
                    NonNull::from(&mut slot),
                )
            };
            if status != NO_ERR {
                continue;
            }
            let Some(session) = created(slot) else {
                // `noErr` with a null slot is not a shape the framework documents; treat it as the
                // invalid-session failure rather than trusting the status over the pointer.
                status = INVALID_SESSION;
                continue;
            };
            return Ok(Self { session });
        }
        Err(status)
    }

    /// Sets a boolean property; answers the framework's status.
    ///
    /// # Safety
    /// `VTSessionSetProperty` requires the value to be of the class the key expects. Every key this
    /// method is called with — `RealTime`, `AllowFrameReordering`, `MaximizePowerEfficiency`,
    /// `PrioritizeEncodingSpeedOverQuality`, `EnableLTR` — is documented as taking a `CFBoolean`.
    /// A key that does not answers `kVTPropertyNotSupportedErr`, which is a value here, not a
    /// fault.
    #[expect(
        unsafe_code,
        reason = "the binding cannot check a value's class against a property key"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn set_bool(&self, key: Key, value: bool) -> i32 {
        // SAFETY: framework rule, above — key and class are paired at every call site.
        unsafe { VTSessionSetProperty(&self.session, key.cf(), Some(CFBoolean::new(value))) }
    }

    /// Sets an integer property; answers the framework's status.
    ///
    /// # Safety
    /// [`Self::set_bool`]'s, for the keys documented as taking a `CFNumber`:
    /// `ExpectedFrameRate`, `MaxFrameDelayCount`, `MaxKeyFrameInterval`, `AverageBitRate`,
    /// `SpatialAdaptiveQPLevel`, `MaxAllowedFrameQP`, `MinAllowedFrameQP`.
    #[expect(
        unsafe_code,
        reason = "the binding cannot check a value's class against a property key"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn set_int(&self, key: Key, value: i64) -> i32 {
        let number = CFNumber::new_i64(value);
        // SAFETY: framework rule, above.
        unsafe { VTSessionSetProperty(&self.session, key.cf(), Some(&number)) }
    }

    /// Sets a `CFString`-valued property; answers the framework's status.
    ///
    /// # Safety
    /// [`Self::set_bool`]'s, for the three BT.709 colour tags, each documented as taking one of
    /// `CoreVideo`'s own attachment `CFString`s — which is exactly what [`StringValue`] resolves.
    #[expect(
        unsafe_code,
        reason = "the binding cannot check a value's class against a property key"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn set_string(&self, key: Key, value: StringValue) -> i32 {
        // SAFETY: framework rule, above.
        unsafe { VTSessionSetProperty(&self.session, key.cf(), Some(value.cf())) }
    }

    /// Sets `SpatialAdaptiveQPLevel` to the framework's "disable" level.
    ///
    /// A method rather than a caller-supplied number because the level is an enumeration whose
    /// values are not derivable from their names — `kVTQPModulationLevel_Disable` is `0`, and a
    /// caller guessing `-1` would be asking for something else entirely.
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn disable_spatial_adaptive_qp(&self) -> i32 {
        self.set_int(Key::SpatialAdaptiveQPLevel, QP_MODULATION_DISABLE)
    }

    /// Sets `DataRateLimits` — the framework's `[maxBytes, seconds]` pair; answers its status.
    ///
    /// # Safety
    /// [`Self::set_bool`]'s. `DataRateLimits` is documented as taking a `CFArray` of exactly two
    /// `CFNumber`s, a byte count and a duration in seconds, in that order — which is what is built.
    #[expect(
        unsafe_code,
        reason = "the binding cannot check a value's class against a property key"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn set_data_rate_limits(&self, max_bytes: i64, seconds: f64) -> i32 {
        let bytes = CFNumber::new_i64(max_bytes);
        let window = CFNumber::new_f64(seconds);
        let limits: CFRetained<CFArray<CFType>> = CFArray::from_objects(&[&**bytes, &**window]);
        // SAFETY: framework rule, above.
        unsafe { VTSessionSetProperty(&self.session, Key::DataRateLimits.cf(), Some(&limits)) }
    }

    /// Tells the encoder that frames are about to arrive.
    ///
    /// # Safety
    /// `VTCompressionSessionPrepareToEncodeFrames` takes only the session and is documented as an
    /// optional optimisation — allocating the encoder's resources up front rather than on the first
    /// frame. There is nothing to get wrong and nothing to report.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn prepare(&self) -> i32 {
        // SAFETY: framework rule, above — no arguments, no ownership.
        unsafe { self.session.prepare_to_encode_frames() }
    }

    /// Presents one frame; answers the framework's status.
    ///
    /// The sink is called on `VideoToolbox`'s own thread, possibly after this returns. The session
    /// is created with `AllowFrameReordering` false and `RealTime` true, so the calls arrive in
    /// encode order — which is what lets the caller keep an ordered queue without a reorder
    /// buffer.
    ///
    /// # Safety
    /// `VTCompressionSessionEncodeFrameWithOutputHandler` requires a session created with a NULL
    /// output callback, which [`Self::create`] guarantees, and it COPIES the block it is given, so
    /// the block need not outlive this call — but its captures must outlive the ENCODE, which is
    /// why the sink is an `Arc` moved into a heap-allocated `RcBlock` rather than a stack one. The
    /// source-frame refcon is NULL because nothing per-frame is carried through it; everything the
    /// sink needs is captured. `info_flags_out` is NULL, which the header permits, because the same
    /// flags arrive in the handler.
    ///
    /// The handler's `sampleBuffer` is a **Get-rule** borrowed pointer, valid for the call.
    /// [`crate::owned::borrowed`] — this crate's ONE Get-rule site under `docs/57` §2 — takes a
    /// reference of this crate's own for the duration of the sink. Null is the documented signal
    /// for a dropped frame, and the helper answering `None` is what routes it to
    /// [`FrameSink::dropped`] rather than retaining nothing.
    #[expect(
        unsafe_code,
        reason = "the encode is a bare VideoToolbox entry point taking a block"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn encode(
        &self,
        image: &CVImageBuffer,
        presentation: Timestamp,
        options: FrameOptions<'_>,
        sink: Arc<dyn FrameSink>,
    ) -> i32 {
        let properties = options.cf();
        let want_ltr_token = options.force_ltr_refresh || !options.acknowledged_ltr_tokens.is_empty();
        let block = block2::RcBlock::new(
            move |status: i32, flags: VTEncodeInfoFlags, buffer: *mut CMSampleBuffer| {
                let held = (status == NO_ERR).then(|| borrowed(buffer)).flatten();
                let Some(buffer) = held else {
                    sink.dropped(status, flags.contains(VTEncodeInfoFlags::FrameDropped));
                    return;
                };
                match EncodedSample::read(&buffer, want_ltr_token) {
                    Some(sample) => sink.encoded(&sample),
                    // A sample with no data buffer is not a frame; it is the same non-event a drop
                    // is, and the rate-control loop is the only thing that would want to know.
                    None => sink.dropped(status, flags.contains(VTEncodeInfoFlags::FrameDropped)),
                }
            },
        );
        // SAFETY: framework rule, above — NULL callback at create, NULL refcon, NULL flags-out, and
        // a heap block whose captures outlive the encode.
        unsafe {
            self.session.encode_frame_with_output_handler(
                image,
                presentation.cm(),
                invalid_time(),
                properties.as_deref().map(CFDictionary::as_opaque),
                core::ptr::null_mut(),
                block2::RcBlock::as_ptr(&block),
            )
        }
    }

    /// Blocks until every frame presented so far has been handed to the sink.
    ///
    /// # Safety
    /// `VTCompressionSessionCompleteFrames` with a NON-numeric timestamp is the documented sentinel
    /// for "complete all pending frames", and [`invalid_time`] is exactly that value. The call is
    /// synchronous and owns nothing.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    #[must_use = "the framework answers a status; a caller that drops it cannot tell best-effort from \
                  critical"]
    pub fn complete_frames(&self) -> i32 {
        // SAFETY: framework rule, above — the invalid timestamp is the drain-everything sentinel.
        unsafe { self.session.complete_frames(invalid_time()) }
    }

    /// Tears the session down deterministically.
    ///
    /// # Safety
    /// `VTCompressionSessionInvalidate` takes only the session. The header asks for it BEFORE the
    /// last release so teardown is ordered rather than whenever the retain count happens to fall,
    /// which is why [`Drop`] calls it rather than relying on the `CFRetained` alone.
    #[expect(
        unsafe_code,
        reason = "objc2 generates the bare VideoToolbox entry points unsafe"
    )]
    fn invalidate(&self) {
        // SAFETY: framework rule, above — no arguments, no ownership.
        unsafe { self.session.invalidate() }
    }
}

impl Drop for CompressionSession {
    /// Invalidate, then let the `CFRetained` release.
    ///
    /// The order is the header's: a session may be retained by more than one party, so waiting for
    /// the retain count to reach zero makes teardown unpredictable. Invalidating first makes it a
    /// point in time. Any frame still in flight has already been drained by the caller — the host
    /// completes frames before dropping an encoder, because a session invalidated with frames
    /// queued silently discards output that was already encoded.
    fn drop(&mut self) {
        self.invalidate();
    }
}

impl Spec {
    /// The create dictionary, or `None` when neither key is asked for.
    pub(crate) fn cf(self) -> Option<CFRetained<CFDictionary<CFString, CFType>>> {
        if !self.low_latency && !self.require_hardware {
            return None;
        }
        let mut keys: Vec<&CFString> = Vec::with_capacity(2);
        let mut values: Vec<&CFType> = Vec::with_capacity(2);
        let truth = CFBoolean::new(true);
        if self.low_latency {
            keys.push(Key::EnableLowLatencyRateControl.cf());
            values.push(&**truth);
        }
        if self.require_hardware {
            keys.push(Key::RequireHardwareAcceleratedVideoEncoder.cf());
            values.push(&**truth);
        }
        Some(CFDictionary::from_slices(&keys, &values))
    }
}
