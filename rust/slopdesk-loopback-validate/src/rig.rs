//! The rig: a hardware encoder, a hardware decoder, and a synthetic frame to feed them.
//!
//! Everything here is a thin holder over the real product components. The encoder is
//! `slopdesk-ffi`'s join over `VTCompressionSession` plus `slopdesk-video`'s rate-control rules —
//! the same object the host drives — reached through its Rust-native sink rather than its C door,
//! so this crate hand-writes no callback and needs no `unsafe`. The decoder is the same arrangement
//! on the client's side. The frame is a `CVPixelBuffer` filled by `slopdesk_video::loopback`'s
//! formulas, whose analytic twin is what the picture check measures against.

use std::sync::{Arc, Mutex};

use slopdesk_apple_vt::{PixelBuffer, Timestamp};
use slopdesk_ffi::decoder::{DecodeOutcome, DecodedFrameSink, SlopDeskVideoDecoder};
use slopdesk_ffi::encoder::{EncodedFrame, EncodedFrameSink, EncoderSpec, SlopDeskVideoEncoder};
use slopdesk_ffi::pixel_plane::{plane_mut, plane_view};
use slopdesk_video::loopback::{
    LumaView, Mad, PlaneMut, fill_chroma, fill_chroma_neutral, fill_luma, fill_luma_low_motion, fill_noise,
    noise_seed,
};

/// The picture every scenario runs at — 720p60, the live path's own operating point.
pub const WIDTH: usize = 1280;
/// Rows, to match.
pub const HEIGHT: usize = 720;
/// Frames per second, which is also the presentation timescale.
pub const FPS: i64 = 60;

/// One frame the encoder finished with, copied out of the borrowed callback.
#[derive(Clone, Debug)]
pub struct Emitted {
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
    fn frame(&self, frame: &EncodedFrame<'_>) {
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
pub struct Encoder {
    /// The session and the rules that drive it.
    inner: SlopDeskVideoEncoder,
    /// Where its frames land.
    collector: Arc<Collector>,
}

impl Encoder {
    /// Creates a live session at the harness geometry.
    ///
    /// # Errors
    /// The framework's `OSStatus`, which on a machine without the Screen-Recording grant is how a
    /// refused create reports itself.
    pub fn create(full_range: bool, ltr_enabled: bool, bitrate: i64) -> Result<Self, i32> {
        let collector = Arc::new(Collector::default());
        let sink: Arc<dyn EncodedFrameSink> = Arc::clone(&collector) as Arc<dyn EncodedFrameSink>;
        let inner = SlopDeskVideoEncoder::create(
            EncoderSpec {
                width: i32::try_from(WIDTH).unwrap_or(1280),
                height: i32::try_from(HEIGHT).unwrap_or(720),
                bitrate,
                fps: FPS,
                full_range,
                ltr_enabled,
                qp_decouple: false,
            },
            Some(sink),
        )?;
        Ok(Self { inner, collector })
    }

    /// Encodes one live frame at presentation index `index`.
    pub fn encode_live(&self, source: &Source, index: usize, force_keyframe: bool) -> i32 {
        self.inner
            .encode_live(source.image(), stamp(index), force_keyframe, None)
    }

    /// Encodes a refresh anchored on an acknowledged long-term reference.
    pub fn encode_ltr_refresh(&self, source: &Source, index: usize) -> i32 {
        self.inner.encode_ltr_refresh(source.image(), stamp(index))
    }

    /// Actuates the live target bitrate. Answers whether it changed.
    pub fn set_live_bitrate(&self, target: i64) -> bool {
        self.inner.set_live_bitrate(target)
    }

    /// Hints the rate-control window at a new frame rate.
    pub fn set_expected_frame_rate(&self, fps: i64) {
        self.inner.set_expected_frame_rate(fps);
    }

    /// Stages a token the client acknowledged, for the next encode to drain.
    pub fn stage_acked_token(&self, token: i64) {
        self.inner.stage_acked_token(token);
    }

    /// Blocks until every frame presented so far has reached the collector.
    pub fn complete_frames(&self) {
        let _ = self.inner.complete_frames();
    }

    /// Takes everything finished since the last call, oldest first.
    pub fn drain(&self) -> Vec<Emitted> {
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
        let Some(plane) = plane_view(&locked, 0) else {
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
pub struct Decoder {
    /// The session and the rules that drive it.
    inner: SlopDeskVideoDecoder,
    /// The sink, kept so a scenario can read the counters back.
    screen: Arc<Screen>,
}

impl Decoder {
    /// Creates a decoder. It has no session until the first keyframe gives it one.
    #[must_use]
    pub fn create(full_range: bool) -> Self {
        let screen = Arc::new(Screen::default());
        let sink: Arc<dyn DecodedFrameSink> = Arc::clone(&screen) as Arc<dyn DecodedFrameSink>;
        let inner = SlopDeskVideoDecoder::create(Some(sink));
        inner.set_full_range(full_range);
        Self { inner, screen }
    }

    /// Turns the picture check on, against the full-motion or low-motion formula.
    pub fn measure_against(&self, low_motion: bool) {
        if let Ok(mut state) = self.screen.inner.lock() {
            state.measuring = true;
            state.low_motion = low_motion;
        }
    }

    /// Says which source frame the next decode should look like, and whether a loss is recent.
    pub fn expect(&self, source_index: usize, drop_recent: bool) {
        if let Ok(mut state) = self.screen.inner.lock() {
            state.source_index = source_index;
            state.drop_recent = drop_recent;
        }
    }

    /// Decodes one reassembled frame.
    pub fn decode(&self, avcc: &[u8], keyframe: bool) -> DecodeOutcome {
        self.inner.decode_frame(avcc, keyframe)
    }

    /// How many frames reached the sink.
    #[must_use]
    pub fn decoded(&self) -> u64 {
        self.screen.inner.lock().map_or(0, |state| state.decoded)
    }

    /// The picture check's three numbers: average, worst, and worst within a few frames of a loss.
    #[must_use]
    pub fn picture(&self) -> (f64, f64, f64) {
        self.screen.inner.lock().map_or((0.0, 0.0, 0.0), |state| {
            (state.mad.average(), state.mad.max(), state.mad.post_drop_max())
        })
    }
}

/// The synthetic frame source: one pixel buffer, refilled per frame.
#[derive(Debug)]
pub struct Source {
    /// The buffer the encoder is handed.
    buffer: PixelBuffer,
}

impl Source {
    /// Creates the harness's one buffer.
    ///
    /// # Errors
    /// Core Video's own status, when it refuses the geometry.
    pub fn create(full_range: bool) -> Result<Self, i32> {
        Ok(Self {
            buffer: PixelBuffer::nv12(WIDTH, HEIGHT, full_range)?,
        })
    }

    /// The buffer, as the encoder's surface takes it.
    #[must_use]
    pub fn image(&self) -> &slopdesk_apple_vt::CVImageBuffer {
        self.buffer.image()
    }

    /// Paints frame `index`: a checkerboard, a moving gradient, and a moving block.
    ///
    /// `low_motion` freezes the background so only the block moves — the desktop's own shape, and
    /// the discriminator between a genuine P-frame and a stream that is secretly all intra.
    pub fn paint(&self, index: usize, low_motion: bool) {
        let Some(mut locked) = self.buffer.lock() else {
            return;
        };
        if let Some(mut luma) = plane_mut(&mut locked, 0) {
            let mut plane = as_plane(&mut luma);
            if low_motion {
                fill_luma_low_motion(&mut plane, index);
            } else {
                fill_luma(&mut plane, index);
            }
        }
        if let Some(mut chroma) = plane_mut(&mut locked, 1) {
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
    pub fn paint_noise(&self, index: usize) {
        let Some(mut locked) = self.buffer.lock() else {
            return;
        };
        let mut state = noise_seed(index);
        if let Some(mut luma) = plane_mut(&mut locked, 0) {
            fill_noise(&mut as_plane(&mut luma), &mut state);
        }
        if let Some(mut chroma) = plane_mut(&mut locked, 1) {
            fill_noise(&mut as_chroma_plane(&mut chroma), &mut state);
        }
    }
}

/// The harness's LUMA plane, as the fill formulas take it — one byte per sample, so the sample
/// width Core Video reports IS the byte width.
const fn as_plane<'a>(plane: &'a mut slopdesk_ffi::pixel_plane::PlaneBytes<'_>) -> PlaneMut<'a> {
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
const fn as_chroma_plane<'a>(plane: &'a mut slopdesk_ffi::pixel_plane::PlaneBytes<'_>) -> PlaneMut<'a> {
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
