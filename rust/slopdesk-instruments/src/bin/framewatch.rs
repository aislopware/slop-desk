//! `slopdesk-framewatch` — how often does a window's capture actually deliver a NEW frame?
//!
//! `ScreenCaptureKit` delivers a frame only when the window's content changes, so the ARRIVAL
//! cadence of a `desktopIndependentWindow` capture IS the window's presentation cadence — and it
//! stays honest on a BACKGROUND or occluded window, which a full-screen `screencapture -v` cannot.
//! No video is written: each frame is reduced to an arrival timestamp plus a cheap luma checksum,
//! which is enough to tell a new frame from an identical re-delivery.
//!
//! The report is an inter-frame-interval histogram plus stall bins, directly comparable across
//! `SlopDesk` and Parsec windows on the same machine. LATENCY MODE watches TWO windows at once: the
//! source is expected to FLASH between dark and light (a flasher HTML page), each window's mean
//! luma runs through a hysteresis state machine, and every source flip is paired with the nearest
//! same-polarity client flip within ±450 ms — per-flash glass-to-glass latency, p50/p90/min/max.
//!
//! Runtime needs a GUI session and a Screen-Recording grant. Exit `1` on setup failure, with a
//! reason on stderr.
//!
//! ```text
//! slopdesk-framewatch --list
//! slopdesk-framewatch --title <substring> [--seconds 20] [--fps 120]
//! slopdesk-framewatch --title-a <source> --title-b <client> [--seconds 20] [--fps 120]
//! slopdesk-framewatch --latency --title-a <source> --title-b <client> [--seconds 20] [--fps 120]
//! ```
//!
//! The middle form is the PAIRED cadence: one enumeration, two streams over the same span, and the
//! two histograms side by side with a `[A]` / `[B]` tag on every line. Two framewatch processes
//! cannot do it — a second `SCShareableContent` enumeration beside a live stream answers "nothing
//! shareable" or refuses the stream with status `-1` (HW-observed 2026-09-02), and two separate
//! spans are not the same span.
//!
//! A `@display` suffix on either latency title watches the DISPLAY the window sits on, cropped to
//! the window's rect, instead of the per-window composite — the filter-kind A/B this instrument
//! exists to settle.
//!
//! ## Why it is no longer Swift
//! Nothing here was ever UI. The Swift original hand-rolled the whole capture — its own
//! `SCStreamConfiguration`, its own `CVPixelBuffer` base-address walk, its own filter choice — so
//! it measured a SECOND spelling of the configuration the host ships, and a divergence between the
//! two would have read as a cadence result. Here the stream is
//! [`slopdesk_apple_sck::CaptureStream`], the same door `slopdesk-videohostd` opens, and the
//! pixels arrive as a `&[u8]` from `slopdesk_apple_vt`'s locked plane view — which is why this
//! workspace can stay `forbid(unsafe_code)` while walking a luma plane.
//!
//! ## The two places the port is not byte-identical, and why
//! 1. **Output buffer size.** The Swift version asked for a HALF-size buffer of the whole window.
//!    `CaptureStream` derives the crop from the buffer (`pinned_source_rect` clamps the
//!    point-to-pixel scale at `1.0`), so a half-size buffer would ask for the window's top-left
//!    QUARTER. Full-size pixels with a scale of `1.0` is the shape that keeps the CROP right, and
//!    the crop is what the luma detector and the checksum both read. The cost is a bigger surface;
//!    the checksum walks one row in sixteen, so it is not a measurable one.
//! 2. **The `@display` fallback.** Swift fell back to the first display when the window intersected
//!    none; `CaptureStream` falls back to the per-window compositor. Reaching either needs a window
//!    that is on no display at all.
//!
//! Everything the shared configuration adds — shadows and the global clip ignored, mouse clicks
//! off, the sRGB colour space named — moves this instrument TOWARDS the path it measures.

// Off macOS the capture half does not exist and `main` is one line, so every reduction below is
// reachable only from the tests. They are still the port, and deleting them under a `cfg` would be
// two spellings of the instrument rather than one.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
// Every setup refusal is a sentence on stderr for the operator, on both halves of the `cfg`; the
// reports themselves are stdout, and only the capture half has any.
#![expect(
    clippy::print_stderr,
    reason = "stderr is this instrument's refusal; the report is stdout"
)]

/// FNV-1a's 64-bit offset basis. Also the checksum of a frame whose plane could not be read, which
/// is the Swift original's behaviour: the arrival still counts, the content just says nothing.
const CHECKSUM_OFFSET: u64 = 0xCBF2_9CE4_8422_2325;

/// FNV-1a's 64-bit prime.
const CHECKSUM_PRIME: u64 = 0x100_0000_01B3;

/// The widest row prefix either walk samples. A checksum over the first kilobyte of a row
/// distinguishes new content from a re-delivery; walking the whole row would not distinguish it any
/// better and would cost with the window's width.
const SAMPLE_WIDTH_CAP: usize = 1024;

/// Above this fraction of full scale the sampled region reads LIGHT.
const LIGHT_THRESHOLD: f64 = 0.62;

/// Below this fraction of full scale it reads DARK. The band between the two is the hysteresis:
/// HEVC ringing and quantiser noise on the streamed copy must not double-trigger a flip.
const DARK_THRESHOLD: f64 = 0.38;

/// The widest |Δt| that may pair a source flip with a client flip, in milliseconds. Half the
/// flasher's period, so a pairing cannot reach past the next flash.
const PAIR_WINDOW_MS: f64 = 450.0;

/// The fewest pairs a latency report is willing to draw a percentile from.
const MIN_PAIRS: usize = 5;

/// How long to watch, when `--seconds` says nothing usable.
const DEFAULT_SECONDS: f64 = 20.0;

/// The delivery ceiling, when `--fps` says nothing usable. Deliberately far above any content rate:
/// the ceiling must not be the thing the histogram measures.
const DEFAULT_FPS: i32 = 120;

/// The longest a single run may watch. A `--seconds inf` is an argument mistake, not a request, and
/// `Duration::from_secs_f64` would panic on it.
const MAX_SECONDS: f64 = 86_400.0;

/// The suffix that turns a latency title into a whole-display watch.
const DISPLAY_SUFFIX: &str = "@display";

/// The smallest output buffer edge. A window narrower than this still needs a capture.
const MIN_EXTENT: i32 = 64;

/// How many surfaces the framework may hold. Deep enough that a slow sink cannot stall capture,
/// shallow enough that a stall is still visible as one.
const QUEUE_DEPTH: i32 = 8;

// ---------------------------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------------------------

/// What the caller asked for.
#[derive(Clone, Debug, PartialEq)]
struct Options {
    /// The cadence mode's window query.
    title: Option<String>,
    /// How long to watch.
    seconds: f64,
    /// The delivery ceiling in Hz.
    fps: i32,
    /// Print every shareable window and stop.
    list: bool,
    /// Watch two windows and correlate their flashes.
    latency: bool,
    /// The latency mode's SOURCE window query.
    title_a: Option<String>,
    /// The latency mode's CLIENT window query.
    title_b: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            title: None,
            seconds: DEFAULT_SECONDS,
            fps: DEFAULT_FPS,
            list: false,
            latency: false,
            title_a: None,
            title_b: None,
        }
    }
}

/// Reads the command line.
///
/// A value that will not parse falls back to the default AND consumes its token, which is the Swift
/// original's `args.next().flatMap(Double.init) ?? 20.0` exactly — an instrument that silently
/// watched for 20 s is a re-runnable mistake, one that refused to start after a window was already
/// arranged is not.
fn parse_options(arguments: &[String]) -> Result<Options, String> {
    let mut options = Options::default();
    let mut index = 0usize;
    while let Some(argument) = arguments.get(index) {
        index = index.saturating_add(1);
        match argument.as_str() {
            "--title" => {
                options.title = arguments.get(index).cloned();
                index = index.saturating_add(1);
            },
            "--seconds" => {
                options.seconds = value_after(arguments, index).unwrap_or(DEFAULT_SECONDS);
                index = index.saturating_add(1);
            },
            "--fps" => {
                options.fps = value_after(arguments, index).unwrap_or(DEFAULT_FPS);
                index = index.saturating_add(1);
            },
            "--list" => options.list = true,
            "--latency" => options.latency = true,
            "--title-a" => {
                options.title_a = arguments.get(index).cloned();
                index = index.saturating_add(1);
            },
            "--title-b" => {
                options.title_b = arguments.get(index).cloned();
                index = index.saturating_add(1);
            },
            other => return Err(format!("unknown arg: {other}")),
        }
    }
    Ok(options)
}

/// The parsed token at `index`, or `None` when it is absent or will not parse.
fn value_after<T: std::str::FromStr>(arguments: &[String], index: usize) -> Option<T> {
    arguments.get(index).and_then(|value| value.parse().ok())
}

/// Splits a latency title into its query and whether it asks for the whole-display filter.
fn split_display_suffix(query: &str) -> (&str, bool) {
    query
        .strip_suffix(DISPLAY_SUFFIX)
        .map_or((query, false), |stripped| (stripped, true))
}

/// How long one run watches, refusing what `Duration` cannot hold.
fn dwell(seconds: f64) -> std::time::Duration {
    if seconds.is_nan() || seconds <= 0.0 {
        return std::time::Duration::ZERO;
    }
    std::time::Duration::from_secs_f64(if seconds >= MAX_SECONDS {
        MAX_SECONDS
    } else {
        seconds
    })
}

// ---------------------------------------------------------------------------------------------
// The pure reductions — everything a headless test can settle
// ---------------------------------------------------------------------------------------------

/// A cheap content checksum: FNV-1a over one row in sixteen of a luma plane, one byte in eight.
///
/// Not a hash of the picture and not meant to be — it answers ONE question, "is this the same
/// content the last frame carried", at a cost of a few microseconds on a 4K plane.
fn content_checksum(bytes: &[u8], stride: usize, height: usize) -> u64 {
    let mut hash = CHECKSUM_OFFSET;
    let width = stride.min(SAMPLE_WIDTH_CAP);
    let mut row = 0usize;
    while row < height {
        let base = row.saturating_mul(stride);
        let mut column = 0usize;
        while column < width {
            if let Some(&byte) = bytes.get(base.saturating_add(column)) {
                hash = (hash ^ u64::from(byte)).wrapping_mul(CHECKSUM_PRIME);
            }
            column = column.saturating_add(8);
        }
        row = row.saturating_add(16);
    }
    hash
}

/// The mean luma of the CENTRAL HALF of a plane, as a fraction of full scale.
///
/// The central half and not the whole plane, because the window's chrome and the pane's borders do
/// not flash and would drag every reading towards the middle of the hysteresis band.
///
/// `None` when the geometry named no samples, which is the reading that must not become a flip.
#[expect(
    clippy::cast_precision_loss,
    reason = "the mean of at most a few thousand bytes; the Swift original divided the same two integers as \
              Doubles and the report must stay comparable"
)]
#[expect(
    clippy::integer_division,
    reason = "the quarter marks that bound the central half are floors, as the Swift original cut them"
)]
fn mean_luma(bytes: &[u8], stride: usize, height: usize) -> Option<f64> {
    let width = stride.min(SAMPLE_WIDTH_CAP);
    let mut sum = 0u64;
    let mut count = 0u64;
    let mut row = height / 4;
    while row < height.saturating_mul(3) / 4 {
        let base = row.saturating_mul(stride);
        let mut column = width / 4;
        while column < width.saturating_mul(3) / 4 {
            if let Some(&byte) = bytes.get(base.saturating_add(column)) {
                sum = sum.saturating_add(u64::from(byte));
                count = count.saturating_add(1);
            }
            column = column.saturating_add(8);
        }
        row = row.saturating_add(8);
    }
    (count > 0).then(|| sum as f64 / count as f64 / 255.0)
}

/// One luma transition.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Flip {
    /// Seconds since the run's own time origin. Both watchers in a latency run share one.
    at: f64,
    /// `true` when the sampled region went LIGHT.
    to_light: bool,
}

/// One window's luma polarity, with hysteresis.
///
/// A reading inside the band classifies as nothing at all and leaves the state alone — that is the
/// hysteresis, and it is why a streamed copy's ringing cannot manufacture flips the source never
/// made. The FIRST classification records no flip: there is no polarity to have left.
#[derive(Clone, Debug, Default)]
struct FlipDetector {
    /// The last classified polarity, or `None` before the first one.
    lit: Option<bool>,
    /// Every transition, in arrival order.
    flips: Vec<Flip>,
}

impl FlipDetector {
    /// Folds one frame's mean luma into the state machine.
    fn observe(&mut self, at: f64, mean: f64) {
        let lit = if mean > LIGHT_THRESHOLD {
            true
        } else if mean < DARK_THRESHOLD {
            false
        } else {
            return;
        };
        if self.lit.is_some_and(|previous| previous != lit) {
            self.flips.push(Flip { at, to_light: lit });
        }
        self.lit = Some(lit);
    }
}

/// Pairs every source flip with the NEAREST same-polarity client flip within [`PAIR_WINDOW_MS`].
///
/// The delta is SIGNED on purpose: an inverted hypothesis — the client flipping before the source —
/// reads as a negative latency rather than as zero pairs, which is the difference between "the A/B
/// is the wrong way round" and "nothing was streaming".
fn pair_deltas(source: &[Flip], client: &[Flip]) -> Vec<f64> {
    let mut deltas = Vec::new();
    for flip in source {
        let mut best: Option<f64> = None;
        for candidate in client.iter().filter(|other| other.to_light == flip.to_light) {
            let delta = (candidate.at - flip.at) * 1000.0;
            if delta.abs() < PAIR_WINDOW_MS && delta.abs() < best.map_or(f64::INFINITY, f64::abs) {
                best = Some(delta);
            }
        }
        if let Some(best) = best {
            deltas.push(best);
        }
    }
    deltas
}

/// The index Swift's `Int(Double(count) * fraction)` names.
///
/// Spelled with the same two floating-point steps rather than as integer arithmetic, because the
/// two disagree: at `count = 100` and `fraction = 0.99` the double nearest `0.99` is below it, and
/// whether the product lands on `99` is a rounding question. The recorded findings this instrument
/// already produced were read off the float spelling.
#[expect(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "reproducing Swift's Int(Double(count) * fraction) exactly; see the note above"
)]
fn percentile_index(count: usize, fraction: f64) -> usize {
    (count as f64 * fraction) as usize
}

/// How many deltas fall in `(low, high]` — low exclusive, high inclusive, as the Swift original's
/// closure had it. A delta of exactly zero therefore belongs to no bin.
fn bin_count(deltas: &[f64], low: f64, high: f64) -> usize {
    deltas
        .iter()
        .filter(|delta| **delta > low && **delta <= high)
        .count()
}

/// The cadence report, one line per element, in the Swift original's exact wording.
#[expect(
    clippy::cast_precision_loss,
    reason = "a frame count as a divisor; the Swift original cast the same count to Double"
)]
fn cadence_lines(arrivals: &[f64], checksums: &[u64]) -> Vec<String> {
    if arrivals.len() < 2 {
        return vec!["framewatch: <2 frames captured — window idle or capture failed".to_owned()];
    }
    let deltas: Vec<f64> = arrivals
        .iter()
        .zip(arrivals.iter().skip(1))
        .map(|(previous, current)| (current - previous) * 1000.0)
        .collect();
    let mut sorted = deltas.clone();
    sorted.sort_by(f64::total_cmp);
    let count = deltas.len();
    let total: f64 = deltas.iter().sum();
    let span = arrivals.last().copied().unwrap_or(0.0) - arrivals.first().copied().unwrap_or(0.0);
    let effective = count as f64 / (total / 1000.0);
    let at = |fraction: f64| {
        sorted
            .get(percentile_index(count, fraction))
            .copied()
            .unwrap_or(0.0)
    };
    let p99 = sorted
        .get(count.saturating_sub(1).min(percentile_index(count, 0.99)))
        .copied()
        .unwrap_or(0.0);
    let max = sorted.last().copied().unwrap_or(0.0);
    let repeats = checksums
        .iter()
        .zip(checksums.iter().skip(1))
        .filter(|(previous, current)| previous == current)
        .count();
    vec![
        format!(
            "framewatch: frames={} span={span:.1}s eff_fps={effective:.1}",
            arrivals.len()
        ),
        format!(
            "framewatch: dt p50={:.1}ms p90={:.1}ms p99={p99:.1}ms max={max:.1}ms",
            at(0.5),
            at(0.9)
        ),
        format!(
            "framewatch: bins ≤20ms={} 20-28ms={} 28-42ms(1-slot)={} 42-60ms(2-slot)={} >60ms={}",
            bin_count(&deltas, 0.0, 20.0),
            bin_count(&deltas, 20.0, 28.0),
            bin_count(&deltas, 28.0, 42.0),
            bin_count(&deltas, 42.0, 60.0),
            bin_count(&deltas, 60.0, f64::INFINITY)
        ),
        format!("framewatch: identical-content re-deliveries={repeats}"),
    ]
}

/// The paired cadence's tag: `framewatch:` becomes `framewatch[A]:` on every line of one window's
/// report, so two reports in one stream stay two reports.
fn tagged(lines: &[String], tag: &str) -> Vec<String> {
    lines
        .iter()
        .map(|line| {
            line.strip_prefix("framewatch:")
                .map_or_else(|| line.clone(), |rest| format!("framewatch[{tag}]:{rest}"))
        })
        .collect()
}

/// The latency report, in the Swift original's exact wording.
///
/// Fewer than [`MIN_PAIRS`] pairs is a SETUP answer, not a measurement — the caller turns it into
/// exit `1`.
fn latency_lines(source_flips: usize, client_flips: usize, deltas: &[f64]) -> Vec<String> {
    let mut lines = vec![format!(
        "framewatch[latency]: sourceFlips={source_flips} clientFlips={client_flips} paired={}",
        deltas.len()
    )];
    if deltas.len() < MIN_PAIRS {
        lines.push(
            "framewatch[latency]: not enough pairs — is the flasher running and the pane streaming it?"
                .to_owned(),
        );
        return lines;
    }
    let mut sorted = deltas.to_vec();
    sorted.sort_by(f64::total_cmp);
    let count = sorted.len();
    #[expect(clippy::integer_division, reason = "the floor is the rank being read")]
    let p50 = sorted.get(count / 2).copied().unwrap_or(0.0);
    #[expect(clippy::integer_division, reason = "the floor is the rank being read")]
    let p90 = sorted.get(count.saturating_mul(9) / 10).copied().unwrap_or(0.0);
    let low = sorted.first().copied().unwrap_or(0.0);
    let high = sorted.last().copied().unwrap_or(0.0);
    lines.push(format!(
        "framewatch[latency]: glass-to-glass p50={p50:.1}ms p90={p90:.1}ms min={low:.1}ms max={high:.1}ms \
         n={count}"
    ));
    lines
}

// ---------------------------------------------------------------------------------------------
// The capture half
// ---------------------------------------------------------------------------------------------

/// Everything that touches `ScreenCaptureKit`, which is everything that cannot be tested
/// headlessly.
#[cfg(target_os = "macos")]
mod capture {
    // `run` is reachable only from `main`, and `pub(super)` is its only accurate visibility — this
    // nursery lint asks for `pub` while rustc's denied `unreachable_pub` refuses exactly that.
    // Clippy's own documentation records the conflict; the stricter of the two wins, as it does in
    // every `slopdesk-apple-*` module.
    #![expect(
        clippy::redundant_pub_crate,
        reason = "conflicts with the denied `unreachable_pub`"
    )]
    #![expect(
        clippy::print_stdout,
        reason = "the window list and the histogram ARE this instrument's output"
    )]

    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Instant;

    use slopdesk_apple_sck::{
        CMSampleBuffer, CMTime, CVImageBuffer, CaptureSink, CaptureStream, CaptureTarget, DispatchQueue,
        ShareableContent, StartRequest, Window,
    };
    use slopdesk_apple_vt::{CFRetained, PixelBuffer, PlaneView};
    use slopdesk_video::capture_config::CaptureMode;

    use super::{
        CHECKSUM_OFFSET, Flip, FlipDetector, MIN_EXTENT, MIN_PAIRS, Options, QUEUE_DEPTH, cadence_lines,
        content_checksum, dwell, latency_lines, mean_luma, pair_deltas, split_display_suffix, tagged,
    };

    /// The arrival timeline and the content timeline, which are always the same length.
    #[derive(Debug, Default)]
    struct Samples {
        /// Seconds since the collector's time origin, one per complete frame.
        arrivals: Vec<f64>,
        /// One content checksum per arrival.
        checksums: Vec<u64>,
    }

    /// The cadence mode's sink.
    #[derive(Debug)]
    struct Collector {
        /// The run's time origin.
        started: Instant,
        /// What the frames said, behind the lock the report reads it through.
        samples: Mutex<Samples>,
    }

    impl Collector {
        /// A collector whose clock starts now.
        fn new(started: Instant) -> Self {
            Self {
                started,
                samples: Mutex::new(Samples::default()),
            }
        }

        /// The finished report.
        fn report(&self) -> Vec<String> {
            let (arrivals, checksums) = self.samples.lock().map_or_else(
                |_| (Vec::new(), Vec::new()),
                |samples| (samples.arrivals.clone(), samples.checksums.clone()),
            );
            cadence_lines(&arrivals, &checksums)
        }
    }

    impl CaptureSink for Collector {
        fn frame(&self, image: &CVImageBuffer, _presentation: CMTime) {
            let at = self.started.elapsed().as_secs_f64();
            let checksum = with_luma_plane(image, |plane| {
                content_checksum(plane.bytes, plane.stride, plane.height)
            })
            .unwrap_or(CHECKSUM_OFFSET);
            if let Ok(mut samples) = self.samples.lock() {
                samples.arrivals.push(at);
                samples.checksums.push(checksum);
            }
        }

        fn audio(&self, _sample: &CMSampleBuffer) {}

        fn stopped(&self) {}
    }

    /// The latency mode's sink — one per watched window.
    #[derive(Debug)]
    struct Watcher {
        /// The run's time origin, SHARED with the other watcher: the pairing subtracts their
        /// timestamps, so two origins would be two clocks and the delta would be the offset.
        started: Instant,
        /// The hysteresis state machine and its flips.
        detector: Mutex<FlipDetector>,
    }

    impl Watcher {
        /// A watcher on the given shared clock.
        fn new(started: Instant) -> Self {
            Self {
                started,
                detector: Mutex::new(FlipDetector::default()),
            }
        }

        /// Every flip seen so far.
        fn flips(&self) -> Vec<Flip> {
            self.detector
                .lock()
                .map_or_else(|_| Vec::new(), |detector| detector.flips.clone())
        }
    }

    impl CaptureSink for Watcher {
        fn frame(&self, image: &CVImageBuffer, _presentation: CMTime) {
            let at = self.started.elapsed().as_secs_f64();
            let Some(Some(mean)) =
                with_luma_plane(image, |plane| mean_luma(plane.bytes, plane.stride, plane.height))
            else {
                return;
            };
            if let Ok(mut detector) = self.detector.lock() {
                detector.observe(at, mean);
            }
        }

        fn audio(&self, _sample: &CMSampleBuffer) {}

        fn stopped(&self) {}
    }

    /// Reads the luma plane of a lent image buffer, for as long as the read takes.
    ///
    /// The whole reason this workspace can walk pixels while staying `forbid(unsafe_code)`:
    /// `slopdesk-apple-vt` carries the sample-memory obligation, and hands back a `&[u8]` plus the
    /// geometry to walk it. `None` when Core Video refused the lock or described no plane.
    fn with_luma_plane<T>(image: &CVImageBuffer, read: impl FnOnce(&PlaneView<'_>) -> T) -> Option<T> {
        let buffer = PixelBuffer::from_retained(CFRetained::from(image));
        let locked = buffer.lock_read_only()?;
        let plane = locked.plane_view(0)?;
        Some(read(&plane))
    }

    /// One edge of the output buffer, in pixels.
    ///
    /// Full-size rather than the Swift original's half, for the reason in the module head: the crop
    /// is derived from the buffer, so halving the buffer would quarter the picture.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a window edge in points; Swift's Int() truncated the same value, and Rust's cast \
                  saturates where Swift's trapped"
    )]
    fn pixel_extent(points: f64) -> i32 {
        (points as i32).max(MIN_EXTENT)
    }

    /// A window edge as the report prints it.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "reproducing Swift's Int() in the report line"
    )]
    const fn whole(points: f64) -> i64 {
        points as i64
    }

    /// The owning application's name, or the placeholder the Swift original printed.
    fn app_name(window: &Window) -> String {
        window.app_name().unwrap_or_else(|| "?".to_owned())
    }

    /// The window's title, or the empty string.
    fn title(window: &Window) -> String {
        window.title().unwrap_or_default()
    }

    /// The window's area in square points — the tiebreak between several title matches.
    fn area(window: &Window) -> f64 {
        let size = window.frame().size;
        size.width * size.height
    }

    /// The LARGEST window whose title or owning application contains `query`, case-folded.
    ///
    /// Largest because a title substring reaches a toolbar or a status sliver as readily as the
    /// content window, and the content window is what anyone measuring cadence means. The Swift
    /// original spelled this twice — a descending sort in cadence mode, a `max(by:)` in latency
    /// mode — and the two agreed on everything but the order of equal-area matches, which was
    /// unspecified in the sort. One spelling, and it is the specified one.
    fn find_window(content: &ShareableContent, query: &str) -> Option<Window> {
        let needle = query.to_lowercase();
        content
            .windows()
            .into_iter()
            .filter(|window| {
                window
                    .title()
                    .is_some_and(|title| title.to_lowercase().contains(&needle))
                    || window
                        .app_name()
                        .is_some_and(|name| name.to_lowercase().contains(&needle))
            })
            .max_by(|left, right| area(left).total_cmp(&area(right)))
    }

    /// Brings up one capture stream on a window.
    ///
    /// `as_display` picks the DISPLAY-anchored filter cropped to the window's rect instead of the
    /// per-window compositor — `CaptureStream` computes that crop itself from the window's frame
    /// and the display's bounds, which is the same rectangle the Swift original wrote by hand.
    fn start_stream(
        window: &Window,
        fps: i32,
        as_display: bool,
        sink: Arc<dyn CaptureSink>,
        frames: &DispatchQueue,
        audio: &DispatchQueue,
    ) -> Result<CaptureStream, i32> {
        let size = window.frame().size;
        let request = StartRequest {
            target: CaptureTarget::Window {
                window_id: window.id(),
                mode: if as_display {
                    CaptureMode::DisplayExcluding
                } else {
                    CaptureMode::Window
                },
                region: None,
            },
            pixel_width: pixel_extent(size.width),
            pixel_height: pixel_extent(size.height),
            capture_scale: 1.0,
            capture_hz: fps,
            queue_depth: QUEUE_DEPTH,
            full_range: false,
            audio_sample_rate: 0,
            audio_channel_count: 0,
        };
        CaptureStream::start(request, sink, frames, audio)
    }

    /// The one stderr line every capture failure ends on. `ScreenCaptureKit` reports a status and
    /// not a sentence, and the two readings worth naming are the two that are not the status.
    fn refuse(status: i32) -> i32 {
        eprintln!("framewatch failed: ScreenCaptureKit status {status} (Screen Recording TCC? GUI session?)");
        1
    }

    /// `--list`: every window worth naming, tab-separated.
    fn list(content: &ShareableContent) {
        for window in content.windows() {
            let size = window.frame().size;
            if window.is_on_screen() || size.width > 100.0 {
                println!(
                    "id={}\t{}\t{}\t[{}x{}]",
                    window.id(),
                    app_name(&window),
                    title(&window),
                    whole(size.width),
                    whole(size.height)
                );
            }
        }
    }

    /// Cadence mode: one window, one histogram.
    fn watch_cadence(options: &Options, content: &ShareableContent, query: &str) -> i32 {
        let Some(window) = find_window(content, query) else {
            eprintln!("no window matching \"{query}\" — try --list");
            return 1;
        };
        let size = window.frame().size;
        println!(
            "framewatch: watching id={} {} \"{}\" [{}x{}] for {}s @{}Hz",
            window.id(),
            app_name(&window),
            title(&window),
            whole(size.width),
            whole(size.height),
            whole(options.seconds),
            options.fps
        );

        let frames = DispatchQueue::new("framewatch.frames", None);
        let audio = DispatchQueue::new("framewatch.audio", None);
        let collector = Arc::new(Collector::new(Instant::now()));
        let stream = match start_stream(
            &window,
            options.fps,
            false,
            Arc::<Collector>::clone(&collector),
            &frames,
            &audio,
        ) {
            Ok(stream) => stream,
            Err(status) => return refuse(status),
        };
        thread::sleep(dwell(options.seconds));
        let _stopped = stream.stop();
        for line in collector.report() {
            println!("{line}");
        }
        0
    }

    /// Paired cadence: two windows, one enumeration, two histograms over the same span.
    fn watch_pair(options: &Options, content: &ShareableContent, query_a: &str, query_b: &str) -> i32 {
        let Some(window_a) = find_window(content, query_a) else {
            eprintln!("no window matching \"{query_a}\" — try --list");
            return 1;
        };
        let Some(window_b) = find_window(content, query_b) else {
            eprintln!("no window matching \"{query_b}\" — try --list");
            return 1;
        };
        for (tag, window) in [("A", &window_a), ("B", &window_b)] {
            let size = window.frame().size;
            println!(
                "framewatch[{tag}]: watching id={} {} \"{}\" [{}x{}] for {}s @{}Hz",
                window.id(),
                app_name(window),
                title(window),
                whole(size.width),
                whole(size.height),
                whole(options.seconds),
                options.fps
            );
        }

        let started = Instant::now();
        let collector_a = Arc::new(Collector::new(started));
        let collector_b = Arc::new(Collector::new(started));
        let frames_a = DispatchQueue::new("framewatch.frames.a", None);
        let frames_b = DispatchQueue::new("framewatch.frames.b", None);
        let audio = DispatchQueue::new("framewatch.audio", None);
        let stream_a = match start_stream(
            &window_a,
            options.fps,
            false,
            Arc::<Collector>::clone(&collector_a),
            &frames_a,
            &audio,
        ) {
            Ok(stream) => stream,
            Err(status) => return refuse(status),
        };
        let stream_b = match start_stream(
            &window_b,
            options.fps,
            false,
            Arc::<Collector>::clone(&collector_b),
            &frames_b,
            &audio,
        ) {
            Ok(stream) => stream,
            Err(status) => {
                let _stopped = stream_a.stop();
                return refuse(status);
            },
        };
        thread::sleep(dwell(options.seconds));
        let _stopped_a = stream_a.stop();
        let _stopped_b = stream_b.stop();
        for line in tagged(&collector_a.report(), "A") {
            println!("{line}");
        }
        for line in tagged(&collector_b.report(), "B") {
            println!("{line}");
        }
        0
    }

    /// Latency mode: two windows, one clock, one paired distribution.
    fn measure_latency(options: &Options, content: &ShareableContent) -> i32 {
        let (Some(query_a), Some(query_b)) = (options.title_a.as_deref(), options.title_b.as_deref()) else {
            eprintln!("--latency needs --title-a and --title-b");
            return 1;
        };
        let (needle_a, a_as_display) = split_display_suffix(query_a);
        let (needle_b, b_as_display) = split_display_suffix(query_b);
        let Some(window_a) = find_window(content, needle_a) else {
            eprintln!("no window matching \"{query_a}\"");
            return 1;
        };
        let Some(window_b) = find_window(content, needle_b) else {
            eprintln!("no window matching \"{query_b}\"");
            return 1;
        };
        println!(
            "framewatch[latency]: A={} {} \"{}\"  B={} {} \"{}\"  {}s",
            window_a.id(),
            app_name(&window_a),
            title(&window_a),
            window_b.id(),
            app_name(&window_b),
            title(&window_b),
            whole(options.seconds)
        );

        let started = Instant::now();
        let watcher_a = Arc::new(Watcher::new(started));
        let watcher_b = Arc::new(Watcher::new(started));
        let frames_a = DispatchQueue::new("framewatch.frames.a", None);
        let frames_b = DispatchQueue::new("framewatch.frames.b", None);
        let audio = DispatchQueue::new("framewatch.audio", None);
        let stream_a = match start_stream(
            &window_a,
            options.fps,
            a_as_display,
            Arc::<Watcher>::clone(&watcher_a),
            &frames_a,
            &audio,
        ) {
            Ok(stream) => stream,
            Err(status) => return refuse(status),
        };
        let stream_b = match start_stream(
            &window_b,
            options.fps,
            b_as_display,
            Arc::<Watcher>::clone(&watcher_b),
            &frames_b,
            &audio,
        ) {
            Ok(stream) => stream,
            Err(status) => {
                let _stopped = stream_a.stop();
                return refuse(status);
            },
        };

        thread::sleep(dwell(options.seconds));
        let _stopped_a = stream_a.stop();
        let _stopped_b = stream_b.stop();

        let source = watcher_a.flips();
        let client = watcher_b.flips();
        let deltas = pair_deltas(&source, &client);
        let enough = deltas.len() >= MIN_PAIRS;
        for line in latency_lines(source.len(), client.len(), &deltas) {
            println!("{line}");
        }
        i32::from(!enough)
    }

    /// The whole run, off the main thread, answering the process's exit code.
    pub(super) fn run(options: &Options) -> i32 {
        let Some(content) = ShareableContent::current(false, false) else {
            eprintln!("framewatch failed: nothing shareable (Screen Recording TCC? GUI session?)");
            return 1;
        };
        if options.list {
            list(&content);
            return 0;
        }
        if options.latency {
            return measure_latency(options, &content);
        }
        if let (Some(query_a), Some(query_b)) = (options.title_a.as_deref(), options.title_b.as_deref()) {
            return watch_pair(options, &content, query_a, query_b);
        }
        let Some(query) = options.title.as_deref() else {
            eprintln!("need --title <substring> (or --list)");
            return 1;
        };
        watch_cadence(options, &content, query)
    }

    /// The two pure conversions this half adds. Everything else here needs a window server.
    #[cfg(test)]
    mod tests {
        use super::{pixel_extent, whole};

        /// The buffer never goes below the floor, and truncates towards zero above it.
        #[test]
        fn a_window_edge_becomes_a_buffer_edge() {
            assert_eq!(pixel_extent(10.0), 64);
            assert_eq!(pixel_extent(1440.7), 1440);
            assert_eq!(whole(1440.7), 1440);
            assert_eq!(whole(20.0), 20);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------------------------

/// `ScreenCaptureKit` delivers several of its completions through the MAIN run loop, so the run
/// happens on a worker and `main` parks in the loop — the Swift original's `RunLoop.main.run()`,
/// and for the reason its own comment gave: a wait on the main thread deadlocks the very
/// completion it is waiting for.
///
/// `become_accessory` first, and on the main thread, because `SCStream::startCapture` aborts with
/// `CGS_REQUIRE_INIT` without a window-server connection. A refusal is reported and not fatal: the
/// failure that follows is the framework's own, and it says more.
///
/// The command line is parsed first, and an unparsable one ends the process with the Swift
/// original's message before any of that.
#[cfg(target_os = "macos")]
fn main() -> ! {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let options = match parse_options(&arguments) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1)
        },
    };
    if !slopdesk_apple_nsapp::become_accessory() {
        eprintln!("framewatch: no window-server connection — capture will probably refuse to start");
    }
    let worker = std::thread::spawn(move || std::process::exit(capture::run(&options)));
    drop(worker);
    slopdesk_apple_nsapp::drain_main_queue()
}

/// There is no window server to ask.
#[cfg(not(target_os = "macos"))]
fn main() -> std::process::ExitCode {
    eprintln!("slopdesk-framewatch is macOS-only");
    std::process::ExitCode::from(1)
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unreachable, reason = "a let-else in a test has nowhere else to go")]

    use super::{
        CHECKSUM_OFFSET, DEFAULT_FPS, DEFAULT_SECONDS, Flip, FlipDetector, MAX_SECONDS, Options, bin_count,
        cadence_lines, content_checksum, dwell, latency_lines, mean_luma, pair_deltas, parse_options,
        percentile_index, split_display_suffix,
    };

    /// The paired cadence tags every report line and leaves a line without the prefix alone, so
    /// the two reports in one stream stay two reports.
    #[test]
    fn a_tag_lands_on_every_report_line_and_nowhere_else() {
        let lines = vec![
            "framewatch: frames=3 span=1.0s eff_fps=3.0".to_owned(),
            "something else".to_owned(),
        ];
        assert_eq!(super::tagged(&lines, "B"), vec![
            "framewatch[B]: frames=3 span=1.0s eff_fps=3.0".to_owned(),
            "something else".to_owned(),
        ]);
    }

    /// Builds an argument vector the way the shell hands one over.
    fn argv(arguments: &[&str]) -> Vec<String> {
        arguments.iter().map(|argument| (*argument).to_owned()).collect()
    }

    /// A light flip at `at`.
    const fn light(at: f64) -> Flip {
        Flip { at, to_light: true }
    }

    /// A dark flip at `at`.
    const fn dark(at: f64) -> Flip {
        Flip { at, to_light: false }
    }

    /// Nothing on the command line is every default.
    #[test]
    fn an_empty_command_line_is_the_defaults() {
        let options = parse_options(&argv(&[])).unwrap_or_default();
        assert_eq!(options, Options::default());
        assert!((options.seconds - DEFAULT_SECONDS).abs() < f64::EPSILON);
        assert_eq!(options.fps, DEFAULT_FPS);
    }

    /// Every flag the Swift original took, still taken.
    #[test]
    fn every_flag_lands_where_it_did() {
        let Ok(options) = parse_options(&argv(&[
            "--latency",
            "--title-a",
            "FLASHER@display",
            "--title-b",
            "SlopDesk",
            "--seconds",
            "30",
            "--fps",
            "60",
            "--list",
            "--title",
            "Safari",
        ])) else {
            unreachable!("the flags above are the ones the parser takes")
        };
        assert!(options.latency);
        assert!(options.list);
        assert_eq!(options.title.as_deref(), Some("Safari"));
        assert_eq!(options.title_a.as_deref(), Some("FLASHER@display"));
        assert_eq!(options.title_b.as_deref(), Some("SlopDesk"));
        assert!((options.seconds - 30.0).abs() < f64::EPSILON);
        assert_eq!(options.fps, 60);
    }

    /// An unparsable value falls back AND consumes its token, as Swift's `flatMap(Double.init)`
    /// did.
    #[test]
    fn an_unparsable_value_falls_back_without_stranding_its_token() {
        let Ok(options) = parse_options(&argv(&["--seconds", "soon", "--fps", "fast", "--list"])) else {
            unreachable!("a bad value is a fallback, never an error")
        };
        assert!((options.seconds - DEFAULT_SECONDS).abs() < f64::EPSILON);
        assert_eq!(options.fps, DEFAULT_FPS);
        assert!(options.list);
    }

    /// An unknown flag is the one argument failure.
    #[test]
    fn an_unknown_flag_is_refused_by_name() {
        assert_eq!(
            parse_options(&argv(&["--nope"])),
            Err("unknown arg: --nope".to_owned())
        );
    }

    /// The display suffix is stripped from the query it decorates.
    #[test]
    fn the_display_suffix_is_a_filter_choice_not_a_title() {
        assert_eq!(split_display_suffix("FLASHER@display"), ("FLASHER", true));
        assert_eq!(split_display_suffix("FLASHER"), ("FLASHER", false));
        assert_eq!(split_display_suffix("@display"), ("", true));
    }

    /// A dwell is clamped rather than trusted: `Duration::from_secs_f64` panics on both extremes.
    #[test]
    fn a_dwell_refuses_what_duration_cannot_hold() {
        assert_eq!(dwell(f64::NAN), std::time::Duration::ZERO);
        assert_eq!(dwell(-1.0), std::time::Duration::ZERO);
        assert_eq!(
            dwell(f64::INFINITY),
            std::time::Duration::from_secs_f64(MAX_SECONDS)
        );
        assert_eq!(dwell(2.5), std::time::Duration::from_millis(2500));
    }

    /// An unreadable plane is the offset basis, and an empty walk never advances the hash.
    #[test]
    fn a_walk_over_no_rows_is_the_offset_basis() {
        assert_eq!(content_checksum(&[], 0, 0), CHECKSUM_OFFSET);
        assert_eq!(content_checksum(&[7; 64], 8, 0), CHECKSUM_OFFSET);
    }

    /// The checksum reads one row in sixteen and one byte in eight — a byte between two samples is
    /// invisible to it, which is the whole reason it is cheap.
    #[test]
    fn the_checksum_samples_a_lattice_and_not_the_picture() {
        let mut bytes = vec![0u8; 8 * 32];
        let base = content_checksum(&bytes, 8, 32);
        if let Some(byte) = bytes.get_mut(1) {
            *byte = 255;
        }
        assert_eq!(
            content_checksum(&bytes, 8, 32),
            base,
            "a byte between two samples must not move the checksum"
        );
        if let Some(byte) = bytes.get_mut(0) {
            *byte = 255;
        }
        assert_ne!(
            content_checksum(&bytes, 8, 32),
            base,
            "a sampled byte must move the checksum"
        );
        let mut later = vec![0u8; 8 * 32];
        if let Some(byte) = later.get_mut(16 * 8) {
            *byte = 255;
        }
        assert_ne!(content_checksum(&later, 8, 32), base, "row 16 is sampled");
    }

    /// The luma walk reads the CENTRAL half and nothing else.
    #[test]
    fn the_luma_walk_reads_the_central_half() {
        let mut bytes = vec![0u8; 32 * 32];
        for row in [8usize, 16] {
            for column in [8usize, 16] {
                if let Some(byte) = bytes.get_mut(row * 32 + column) {
                    *byte = 255;
                }
            }
        }
        let Some(mean) = mean_luma(&bytes, 32, 32) else {
            unreachable!("a 32x32 plane names four samples")
        };
        assert!((mean - 1.0).abs() < f64::EPSILON, "mean was {mean}");
        assert_eq!(mean_luma(&[], 0, 0), None, "no samples is no reading");
    }

    /// The hysteresis band classifies as nothing, and the first classification is not a flip.
    #[test]
    fn the_band_between_the_thresholds_is_not_a_flip() {
        let mut detector = FlipDetector::default();
        detector.observe(0.0, 0.5);
        assert!(detector.flips.is_empty(), "a band reading classifies nothing");
        detector.observe(1.0, 0.9);
        assert!(
            detector.flips.is_empty(),
            "the first polarity has nothing to leave"
        );
        detector.observe(2.0, 0.62);
        detector.observe(2.5, 0.38);
        assert!(
            detector.flips.is_empty(),
            "the thresholds themselves are inside the band"
        );
        detector.observe(3.0, 0.1);
        detector.observe(4.0, 0.9);
        detector.observe(5.0, 0.65);
        assert_eq!(detector.flips, vec![dark(3.0), light(4.0)]);
    }

    /// The nearest same-polarity flip wins, opposite polarity never pairs, and the window is hard.
    #[test]
    fn pairing_takes_the_nearest_same_polarity_flip_inside_the_window() {
        assert_eq!(
            pair_deltas(&[light(1.0)], &[light(1.25), light(1.125)]),
            vec![125.0],
            "the nearer of two candidates wins"
        );
        assert_eq!(
            pair_deltas(&[light(1.0)], &[light(0.75)]),
            vec![-250.0],
            "an inverted hypothesis is a negative latency, not a missing pair"
        );
        assert_eq!(
            pair_deltas(&[light(1.0)], &[dark(1.125)]),
            Vec::<f64>::new(),
            "opposite polarity never pairs"
        );
        assert_eq!(
            pair_deltas(&[light(1.0)], &[light(1.5)]),
            Vec::<f64>::new(),
            "500 ms is outside the +-450 ms window"
        );
        assert_eq!(
            pair_deltas(&[light(1.0), dark(2.0)], &[light(1.125), dark(2.25)]),
            vec![125.0, 250.0]
        );
    }

    /// Low exclusive, high inclusive — a delta on a bin edge belongs to the lower bin.
    #[test]
    fn a_bin_edge_belongs_to_the_lower_bin() {
        let deltas = [0.0, 20.0, 20.5, 28.0, 61.0];
        assert_eq!(bin_count(&deltas, 0.0, 20.0), 1, "zero belongs to no bin");
        assert_eq!(bin_count(&deltas, 20.0, 28.0), 2);
        assert_eq!(bin_count(&deltas, 60.0, f64::INFINITY), 1);
    }

    /// The percentile index is Swift's, floor and all.
    #[test]
    fn the_percentile_index_floors() {
        assert_eq!(percentile_index(10, 0.5), 5);
        assert_eq!(percentile_index(10, 0.9), 9);
        assert_eq!(percentile_index(3, 0.5), 1);
        assert_eq!(percentile_index(1, 0.99), 0);
    }

    /// Under two frames there is no cadence, and the line says so rather than reporting zeroes.
    #[test]
    fn one_frame_is_not_a_cadence() {
        assert_eq!(cadence_lines(&[1.0], &[7]), vec![
            "framewatch: <2 frames captured — window idle or capture failed".to_owned()
        ]);
        assert_eq!(cadence_lines(&[], &[]).len(), 1);
    }

    /// The cadence report, pinned character for character against the Swift original's format.
    #[test]
    fn the_cadence_report_is_the_swift_one() {
        assert_eq!(cadence_lines(&[0.0, 1.0, 2.0, 3.0], &[1, 1, 2, 2]), vec![
            "framewatch: frames=4 span=3.0s eff_fps=1.0".to_owned(),
            "framewatch: dt p50=1000.0ms p90=1000.0ms p99=1000.0ms max=1000.0ms".to_owned(),
            "framewatch: bins ≤20ms=0 20-28ms=0 28-42ms(1-slot)=0 42-60ms(2-slot)=0 >60ms=3".to_owned(),
            "framewatch: identical-content re-deliveries=2".to_owned(),
        ]);
    }

    /// The latency report, both arms, pinned the same way.
    #[test]
    fn the_latency_report_is_the_swift_one() {
        assert_eq!(latency_lines(2, 1, &[10.0]), vec![
            "framewatch[latency]: sourceFlips=2 clientFlips=1 paired=1".to_owned(),
            "framewatch[latency]: not enough pairs — is the flasher running and the pane streaming it?"
                .to_owned(),
        ]);
        assert_eq!(latency_lines(6, 7, &[10.0, -5.0, 20.0, 15.0, 30.0]), vec![
            "framewatch[latency]: sourceFlips=6 clientFlips=7 paired=5".to_owned(),
            "framewatch[latency]: glass-to-glass p50=15.0ms p90=30.0ms min=-5.0ms max=30.0ms n=5".to_owned(),
        ]);
    }
}
