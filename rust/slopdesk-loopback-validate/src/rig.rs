//! The rig: a hardware encoder, a hardware decoder, and a synthetic frame to feed them.
//!
//! Everything here is a thin holder over the real product components. The encoder is
//! `slopdesk-videohostd`'s join over `VTCompressionSession` plus `slopdesk-video`'s rate-control
//! rules — literally the object the host drives, not a second one shaped like it. It moved there
//! from `slopdesk-ffi` when the Swift host was deleted and the C doors went with it (`docs/61` §2),
//! and this crate followed rather than keeping a copy: a harness that measured a different encoder
//! from the one that ships would answer the wrong question. The decoder is still the shim's, which
//! is right — the client half of the wire is Swift's caller, and its C door is live. Both are
//! reached through their Rust-native sinks rather than through a callback this crate would have to
//! hand-write, which is why it needs no `unsafe`. The frame is a `CVPixelBuffer` filled by
//! `slopdesk_video::loopback`'s formulas, whose analytic twin is what the picture check measures
//! against.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::sync::{Arc, Mutex};

use slopdesk_apple_vt::{PixelBuffer, Timestamp};
use slopdesk_ffi::decoder::{DecodeOutcome, DecodedFrameSink, SlopDeskVideoDecoder};
use slopdesk_video::loopback::{
    LumaView, Mad, PlaneMut, fill_chroma, fill_chroma_neutral, fill_luma, fill_luma_low_motion, fill_noise,
    noise_seed,
};
use slopdesk_videohostd::encode::{
    EncodeError, EncodedFrameSink, Encoder as HostEncoder, FinishedFrame, Shape,
};
use slopdesk_videohostd::env::Overlay;

/// The picture every scenario runs at — 720p60, the live path's own operating point.
pub(crate) const WIDTH: usize = 1280;
/// Rows, to match.
pub(crate) const HEIGHT: usize = 720;
/// Frames per second, which is also the presentation timescale.
pub(crate) const FPS: i64 = 60;

/// One frame the encoder finished with, copied out of the borrowed callback.
#[derive(Clone, Debug)]
pub(crate) struct Emitted {
    /// The AVCC-framed bytes.
    pub avcc: Vec<u8>,
    /// Whether the encoder made this an intra frame.
    pub keyframe: bool,
    /// The long-term-reference acknowledgement token, when the frame carries one.
    pub ltr: Option<i64>,
}

/// Collects what the encoder emits, so a scenario can read a whole drain at once.
///
/// The callback fires on `VideoToolbox`'s own thread; `complete_frames` drains every pending one
/// before a scenario reads. The mutex keeps that race-clean even though the harness is otherwise
/// single-threaded.
#[derive(Debug, Default)]
struct Collector {
    /// Frames finished since the last drain.
    items: Mutex<Vec<Emitted>>,
}

impl EncodedFrameSink for Collector {
    fn frame(&self, frame: &FinishedFrame<'_>) {
        if let Ok(mut items) = self.items.lock() {
            items.push(Emitted {
                avcc: frame.avcc.to_vec(),
                keyframe: frame.keyframe,
                ltr: frame.ltr_token,
            });
        }
    }
}

/// A live hardware encoder and the frames it has finished.
#[derive(Debug)]
pub(crate) struct Encoder {
    /// The session and the rules that drive it.
    inner: HostEncoder,
    /// Where its frames land.
    collector: Arc<Collector>,
}

impl Encoder {
    /// Creates a live session at the harness geometry.
    ///
    /// # Errors
    /// The framework's `OSStatus`, which on a machine without the Screen-Recording grant is how a
    /// refused create reports itself.
    pub(crate) fn create(full_range: bool, ltr_enabled: bool, bitrate: i64) -> Result<Self, i32> {
        let collector = Arc::new(Collector::default());
        let sink: Arc<dyn EncodedFrameSink> = collector.clone();
        // The harness IS run from a shell with the knobs exported — that is how an operator sweeps
        // an operating point — and the launch overlay reads the real environment FIRST, so this is
        // exactly the reader it wants and the sidecar is the fallback the host itself uses.
        let mut inner = HostEncoder::new(
            Shape {
                width: WIDTH,
                height: HEIGHT,
                bitrate,
                fps: FPS,
                full_range,
                ltr_enabled,
            },
            Some(sink),
            &Overlay::from_launch(),
        );
        inner.open().map_err(status)?;
        Ok(Self { inner, collector })
    }

    /// Encodes one live frame at presentation index `index`, answering the framework's status.
    ///
    /// A status rather than the driver's `Result` because a scenario COUNTS refusals and carries on
    /// — a harness that stopped at the first one would measure the encoder up to its first hiccup.
    pub(crate) fn encode_live(&self, source: &Source, index: usize, force_keyframe: bool) -> i32 {
        status_of(
            self.inner
                .encode_live(source.image(), stamp(index), force_keyframe, None),
        )
    }

    /// Encodes a refresh anchored on an acknowledged long-term reference.
    pub(crate) fn encode_ltr_refresh(&self, source: &Source, index: usize) -> i32 {
        status_of(self.inner.encode_ltr_refresh(source.image(), stamp(index)))
    }

    /// Actuates the live target bitrate. Answers whether it changed.
    pub(crate) fn set_live_bitrate(&self, target: i64) -> bool {
        self.inner.set_live_bitrate(target)
    }

    /// Hints the rate-control window at a new frame rate.
    pub(crate) fn set_expected_frame_rate(&self, fps: i64) {
        self.inner.set_expected_frame_rate(fps);
    }

    /// Stages a token the client acknowledged, for the next encode to drain.
    pub(crate) fn stage_acked_token(&self, token: i64) {
        self.inner.stage_acked_token(token);
    }

    /// Blocks until every frame presented so far has reached the collector.
    pub(crate) fn complete_frames(&self) {
        self.inner.complete_frames();
    }

    /// Takes everything finished since the last call, oldest first.
    pub(crate) fn drain(&self) -> Vec<Emitted> {
        self.collector
            .items
            .lock()
            .map(|mut items| core::mem::take(&mut *items))
            .unwrap_or_default()
    }
}

/// What a decoded frame is measured against, and how many arrived.
///
/// The decode is synchronous, so this is written just before the submit and read just after —
/// there is no real concurrency, and the mutex is discipline rather than necessity.
#[derive(Debug, Default)]
struct Screen {
    /// Everything the picture check accumulates, plus the frame it is checking against.
    inner: Mutex<ScreenState>,
}

/// The picture check's whole state.
#[derive(Debug, Default)]
struct ScreenState {
    /// How many frames reached the sink.
    decoded: u64,
    /// The source index the next decode should look like.
    source_index: usize,
    /// Whether a whole-frame wire loss happened within the last few frames.
    drop_recent: bool,
    /// Whether to measure against the low-motion formula instead.
    low_motion: bool,
    /// Whether to measure at all. A scenario that only counts frames pays nothing.
    measuring: bool,
    /// The accumulated mean absolute difference.
    mad: Mad,
}

impl DecodedFrameSink for Screen {
    fn frame(&self, image: PixelBuffer) {
        let Ok(mut state) = self.inner.lock() else {
            return;
        };
        state.decoded = state.decoded.saturating_add(1);
        if !state.measuring {
            return;
        }
        let Some(locked) = image.lock_read_only() else {
            return;
        };
        let Some(plane) = locked.plane_view(0) else {
            return;
        };
        let (index, low_motion, drop_recent) = (state.source_index, state.low_motion, state.drop_recent);
        state.mad.measure(
            &LumaView {
                bytes: plane.bytes,
                stride: plane.stride,
                width: plane.width,
                height: plane.height,
            },
            index,
            low_motion,
            drop_recent,
        );
    }
}

/// A live hardware decoder and the picture check behind it.
#[derive(Debug)]
pub(crate) struct Decoder {
    /// The session and the rules that drive it.
    inner: SlopDeskVideoDecoder,
    /// The sink, kept so a scenario can read the counters back.
    screen: Arc<Screen>,
}

impl Decoder {
    /// Creates a decoder. It has no session until the first keyframe gives it one.
    #[must_use]
    pub(crate) fn create(full_range: bool) -> Self {
        let screen = Arc::new(Screen::default());
        let sink: Arc<dyn DecodedFrameSink> = Arc::<Screen>::clone(&screen);
        let inner = SlopDeskVideoDecoder::create(Some(sink));
        inner.set_full_range(full_range);
        Self { inner, screen }
    }

    /// Turns the picture check on, against the full-motion or low-motion formula.
    pub(crate) fn measure_against(&self, low_motion: bool) {
        if let Ok(mut state) = self.screen.inner.lock() {
            state.measuring = true;
            state.low_motion = low_motion;
        }
    }

    /// Says which source frame the next decode should look like, and whether a loss is recent.
    pub(crate) fn expect(&self, source_index: usize, drop_recent: bool) {
        if let Ok(mut state) = self.screen.inner.lock() {
            state.source_index = source_index;
            state.drop_recent = drop_recent;
        }
    }

    /// Decodes one reassembled frame.
    pub(crate) fn decode(&self, avcc: &[u8], keyframe: bool) -> DecodeOutcome {
        self.inner.decode_frame(avcc, keyframe)
    }

    /// How many frames reached the sink.
    #[must_use]
    pub(crate) fn decoded(&self) -> u64 {
        self.screen.inner.lock().map_or(0, |state| state.decoded)
    }

    /// The picture check's three numbers: average, worst, and worst within a few frames of a loss.
    #[must_use]
    pub(crate) fn picture(&self) -> (f64, f64, f64) {
        self.screen.inner.lock().map_or((0.0, 0.0, 0.0), |state| {
            (state.mad.average(), state.mad.max(), state.mad.post_drop_max())
        })
    }
}

/// The synthetic frame source: one pixel buffer, refilled per frame.
#[derive(Debug)]
pub(crate) struct Source {
    /// The buffer the encoder is handed.
    buffer: PixelBuffer,
}

impl Source {
    /// Creates the harness's one buffer.
    ///
    /// # Errors
    /// Core Video's own status, when it refuses the geometry.
    pub(crate) fn create(full_range: bool) -> Result<Self, i32> {
        Ok(Self {
            buffer: PixelBuffer::nv12(WIDTH, HEIGHT, full_range)?,
        })
    }

    /// The buffer, as the encoder's surface takes it.
    #[must_use]
    pub(crate) fn image(&self) -> &slopdesk_apple_vt::CVImageBuffer {
        self.buffer.image()
    }

    /// Paints frame `index`: a checkerboard, a moving gradient, and a moving block.
    ///
    /// `low_motion` freezes the background so only the block moves — the desktop's own shape, and
    /// the discriminator between a genuine P-frame and a stream that is secretly all intra.
    pub(crate) fn paint(&self, index: usize, low_motion: bool) {
        let Some(mut locked) = self.buffer.lock() else {
            return;
        };
        if let Some(mut luma) = locked.plane_mut(0) {
            let mut plane = as_plane(&mut luma);
            if low_motion {
                fill_luma_low_motion(&mut plane, index);
            } else {
                fill_luma(&mut plane, index);
            }
        }
        if let Some(mut chroma) = locked.plane_mut(1) {
            let mut plane = as_chroma_plane(&mut chroma);
            if low_motion {
                fill_chroma_neutral(&mut plane);
            } else {
                fill_chroma(&mut plane, index);
            }
        }
    }

    /// Paints incompressible noise — the picture that pins the encoder against its rate cap, which
    /// is what the bottleneck and governor scenarios need and a checkerboard cannot produce.
    pub(crate) fn paint_noise(&self, index: usize) {
        let Some(mut locked) = self.buffer.lock() else {
            return;
        };
        let mut state = noise_seed(index);
        if let Some(mut luma) = locked.plane_mut(0) {
            fill_noise(&mut as_plane(&mut luma), &mut state);
        }
        if let Some(mut chroma) = locked.plane_mut(1) {
            fill_noise(&mut as_chroma_plane(&mut chroma), &mut state);
        }
    }
}

/// The harness's LUMA plane, as the fill formulas take it — one byte per sample, so the sample
/// width Core Video reports IS the byte width.
const fn as_plane<'a>(plane: &'a mut slopdesk_apple_vt::PlaneBytes<'_>) -> PlaneMut<'a> {
    PlaneMut {
        bytes: plane.bytes,
        stride: plane.stride,
        width: plane.width,
        height: plane.height,
    }
}

/// The harness's CHROMA plane, whose row is TWO bytes per sample.
///
/// Core Video reports a subsampled plane's width in SAMPLES, and NV12 interleaves Cb and Cr, so a
/// row spans twice as many bytes as it does samples. Every fill here walks BYTES — the patterns are
/// defined on the byte index — so the visible span has to be the byte one, or the right half of
/// every chroma row keeps whatever the allocator left in it and the encoder sees a different
/// picture than the one the harness thinks it painted.
const fn as_chroma_plane<'a>(plane: &'a mut slopdesk_apple_vt::PlaneBytes<'_>) -> PlaneMut<'a> {
    let doubled = plane.width.saturating_mul(2);
    PlaneMut {
        bytes: plane.bytes,
        stride: plane.stride,
        width: if doubled < plane.stride {
            doubled
        } else {
            plane.stride
        },
        height: plane.height,
    }
}

/// The presentation stamp for frame `index` at the harness frame rate.
fn stamp(index: usize) -> Timestamp {
    Timestamp {
        value: i64::try_from(index).unwrap_or(i64::MAX),
        timescale: i32::try_from(FPS).unwrap_or(60),
    }
}

/// The framework status inside a driver error.
///
/// The driver's two arms are "the session could not be made" and "the frame was refused", and both
/// carry the `OSStatus` the framework gave — which is the only thing a harness scenario reports, so
/// flattening here keeps every call site reading as it did when the door answered a bare status.
const fn status(error: EncodeError) -> i32 {
    match error {
        EncodeError::SessionCreate(code) | EncodeError::Encode(code) => code,
    }
}

/// The same, for a call that may have succeeded. Success is the framework's own zero.
fn status_of(result: Result<(), EncodeError>) -> i32 {
    result.map_or_else(status, |()| 0)
}
