//! The `SCStream` this daemon owns: one window (or one display) turned into a cadence of NV12
//! frames, each carrying the plan the encoder must honour for it.
//!
//! ## What it replaces
//! The Swift host's window capturer — 1976 lines, the largest file in that tree — together with
//! the four decider faces beside it: `CaptureRegionRecovery.swift`,
//! `StaticFrameSuppressionDecider.swift`, `StillnessCrispDecider.swift` and
//! `IdleReapDecider.swift`. All four were already thin faces over `slopdesk_video`, so two of them
//! are CONSUMED here ([`should_suppress_static_frame`] and [`StillnessCrispDecider`]) and two are
//! not consumed here at all: `slopdesk_video::capture_recovery::capture_failure_action` and
//! `slopdesk_video::idle_reap` are the SESSION's asks — one routes a capture death, the other reaps
//! a UDP flow — and the capturer never consulted either, even in Swift. The session calls those
//! modules directly rather than reaching through a capturer that would only forward.
//!
//! ## What is here, and what emphatically is not
//! Nothing in this module decides anything about a frame. The whole ladder — the heartbeat IDR, the
//! recovery-IDR storm collapse, the compact bracket, the LTR refresh, the self-heal cadence, the
//! adaptive-QP smoothing law, the idle skip, the static suppression, the stillness crisp, the
//! scroll-fps Bresenham decimator, the encode backlog policy, the synthetic-PTS counter and its
//! high-water clamp — is [`slopdesk_video::capture_gates`], [`slopdesk_video::frame_gate`],
//! [`slopdesk_video::fps_governor`] and [`slopdesk_video::recovery_routing`], each golden-pinned
//! and tested where no window server exists. `slopdesk-apple-sck` owns the stream, the filter and
//! the crop. What is HERE is the three things Swift genuinely contributed: the ORDER those verdicts
//! are asked in, the THREADING that makes the order safe, and the pixel arithmetic — one plane
//! read, one plane write and three measurements — that turns a framework surface into the numbers a
//! rule takes.
//!
//! ## The order in [`Inner::deliver_frame`] is load-bearing
//! Every step is where it is because a different position is a visible bug, and the Swift carried a
//! paragraph for each. In order: measure the scroll shift and the change magnitude against the
//! PREVIOUS frame (so both reads happen while the cache still holds it); replace the cache; compute
//! the shared full-NV12 hash AT MOST ONCE for the three gates that want it; decide the idle skip;
//! anchor [`StaticIdrDecider`] only when the frame was NOT skipped, because leaving the
//! quiet-window clock stale is exactly what lets the crisp re-anchor fire once the screen settles;
//! feed the stillness decider; then return, decimate or suppress; stamp the PTS through the
//! monotonic clamp; disarm any pending gated-tail flush; honour the client-silence pause; consult
//! the governor's cadence gate; and only then resolve the below-gate plan. The cache, the decider
//! anchor and the PTS all advance for frames that are later dropped — a skipped frame that had not
//! updated the cache would let the static timer re-ship stale pixels for ever, and would let the
//! decider believe the live path quiet mid-motion.
//!
//! ## Why the cache is BYTES and not a `CVPixelBuffer`
//! The Swift kept its cached frame as a second `CVPixelBuffer` and promised it was shareable. Rust
//! cannot make that promise and this tree does not accept one: a `CVImageBuffer` reaches Rust as a
//! `CFRetained`, which `objc2` declares neither `Send` nor `Sync`, and the capture sink must be
//! `Send + Sync` because [`slopdesk_apple_sck::CaptureStream`] takes it as an `Arc<dyn
//! CaptureSink>`.
//!
//! So no framework buffer EVER lives in a field here. What the delivery does on the capture queue
//! is the minimum that must happen there — [`read_frame`], one plane read into a [`FrameBytes`] —
//! and every later consumer rebuilds a `CVPixelBuffer` from those bytes as a LOCAL, uses it, and
//! drops it. This is the discipline `crate::audio` writes down for its `AudioConverter`, applied to
//! the same problem: the delivery queue reads the framework's memory into something that can cross
//! a thread, and nothing else crosses.
//!
//! The cost is nothing on either path the Swift had. A live frame handed straight to the encoder is
//! still the framework's own surface, zero-copy; a live frame going to the decoupled backlog rides
//! an `Arc` clone of the bytes that were cached anyway, so the two copies are the same two the
//! Swift made (cache, then backlog). Only the static re-anchor pays a rebuild the Swift did not, at
//! most a dozen times a second and only while the screen is not changing.
//!
//! A rebuilt buffer carries no colour attachments, and that is safe HERE for a reason that is worth
//! writing down: the encoder session pins `ColorPrimaries`, `TransferFunction` and `YCbCrMatrix` to
//! BT.709 itself (`slopdesk-ffi/src/encoder.rs`, the three `set_string` calls), so the bitstream's
//! colour metadata comes from the session and never from the input buffer's attachments. The
//! Swift's `CVBufferCopyAttachments` guarded a tone shift that this daemon's session already
//! answers.
//!
//! ## Threading: the frame queue is the serializer, and it comes from here
//! One serial `DispatchQueue` carries both the `SCStream` screen output AND the static-IDR timer,
//! which is what let the Swift touch one cached frame from two producers with no lock. That
//! discipline is preserved literally: the timer is a Rust thread that does nothing but wake on a
//! [`Condvar`] and run its body through [`DispatchQueue::exec_sync`] onto the frame queue, so a
//! tick and a delivery can never interleave. Audio has its own queue for the reason it always did —
//! a ~10 ms buffer must not queue behind a synchronous video encode. Both queues are created HERE
//! because `slopdesk-apple-sck` takes its delivery queues from the caller on purpose: the sharing
//! IS the design, and a crate that made its own could not be told to share one.
//!
//! Rust cannot SEE that discipline, so the queue-confined state still lives behind a [`Mutex`].
//! That mutex is uncontended by construction; it is how Rust is told what the queue already
//! guarantees, and it is deliberately NOT one big lock. The latches the session writes
//! ([`Capturer::request_keyframe`] and friends) sit behind their own small mutex, because a session
//! thread must never block behind a frame's encode to arm a recovery keyframe — the same split
//! `keyframeLock` / `pacerLock` / `audioLock` / `encodePendingLock` / `anchorLock` made in Swift.
//!
//! The one lock ORDER, and the only nesting anywhere: `live` may be held while `latches` or
//! `counters` is taken, never the reverse. Every other pair is sequential — the governed rate reads
//! the latches, releases, then reads the pacer, which is the Swift's own "sequential locks, never
//! nested" note carried across.
//!
//! Teardown is a JOIN, never a cancel-and-run-on. [`Capturer::stop`] latches `capture_stopped`
//! INSIDE the frame queue first — so a tick already queued becomes inert rather than racing — then
//! stops the stream, then wakes and joins the timer thread, then discards the encode backlog and
//! joins the encode thread. Discarding the pending deltas is stronger than the Swift, whose GCD
//! tail could still fire after `stop()` returned; the session drains the encoder immediately after,
//! so a delta encoded into a session that is going away has no reader.
//!
//! ⚠️ Every blocking method here — [`Capturer::start_window`], [`Capturer::start_display`],
//! [`Capturer::stop`], [`Capturer::reanchor`], [`Capturer::resize`] — enters the frame queue or
//! blocks on the framework. NONE of them may be called from the frame queue, which in practice
//! means never from inside a [`CaptureEvents`] callback. Swift got that structurally, because those
//! methods were `async` on an actor and the callbacks were not; Rust does not, so it is stated.
//!
//! ## Clocks
//! One [`Instant`] epoch per capturer, and every anchor, decider and gate sees `f64` seconds from
//! it. The Swift used `CLOCK_UPTIME_RAW`, whose origin is the boot; only INTERVALS are ever
//! compared, so the origin is free. Presentation timestamps are a different clock entirely: the
//! framework's own, converted to the 90 kHz timescale the whole wire uses and passed through
//! [`monotonic_pts`].
//!
//! ## Gates
//! Resolved ONCE per capturer, at construction, through the daemon's environment precedence — the
//! real environment first, then the settings overlay, `docs/58`'s order. Swift resolved them into
//! process statics; per-capturer is behaviourally identical because there is no live config reload
//! (`just host-restart` IS the reload), and it is what makes the resolution testable.
//!
//! ## What is tested, and what cannot be
//! ⚠️ GUI + TCC ONLY below [`Capturer::start_window`]: `SCStream` needs a window server and a
//! Screen-Recording grant, so nothing that touches a live stream is reachable from a test. What IS
//! tested is this module's own plumbing, which is the part the Swift could not reach at all —
//! `CVPixelBufferCreate` is headless, so the plane read, the rebuild and their round trip run
//! against REAL buffers — plus the 90 kHz conversion, the confidence scaling and the re-anchor
//! coalescer's single-driver/latest-wins contract.

use core::fmt;
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use slopdesk_apple_sck::{
    CMSampleBuffer, CMTime, CaptureRegion, CaptureSink, CaptureStream, CaptureTarget, DispatchQueue,
    DispatchRetained, NO_ERROR, StartRequest,
};
use slopdesk_apple_vt::{CFRetained, CVImageBuffer, Locked, PixelBuffer, PlaneBytes, Timestamp};
use slopdesk_video::adaptive_qp::{QpCurve, compute_nv12};
use slopdesk_video::capture_config::{
    resolve_capture_hz, resolve_capture_mode, resolve_heartbeat, resolve_idr_poll_tick, resolve_queue_depth,
    resolve_quiet_window,
};
use slopdesk_video::capture_gates::{
    BacklogDecision, CaptureGateContext, CaptureGates, EncodeAnchors, EncodeFrame, KEYS as CAPTURE_KEYS,
    fold_encode_ewma, idle_skip_eligible, monotonic_pts, synthetic_pts,
};
use slopdesk_video::fps_governor::{
    EncodeCadenceGate, EncodeLoadPacer, EncodeLoadPacerConfig, FpsGovernorConfig, KEYS as GOVERNOR_KEYS,
    budget_millis, self_heal_effective_every,
};
use slopdesk_video::frame_gate::{FrameObligations, StillnessCrispDecider, should_suppress_static_frame};
use slopdesk_video::frame_hash::{LumaPlane, SENTINEL, hash_nv12};
use slopdesk_video::geometry::VideoPoint;
use slopdesk_video::recovery_routing::StaticIdrDecider;
use slopdesk_video::scroll_reproject::ScrollHint;
use slopdesk_video::scroll_shift::estimate_nv12;

use crate::env::Overlay;

/// The timescale every presentation timestamp on this path is expressed in.
///
/// 90 kHz, the one the wire, the encoder and the synthetic counter all agree on. Named once here
/// because it is the only Core Media FACT in this module — everything else about a PTS is a rule.
pub const PTS_TIMESCALE: i32 = 90_000;

/// The label of the serial queue the stream's screen output and the static-IDR timer share.
const FRAME_QUEUE_LABEL: &str = "slopdesk.video.capture";

/// The label of the serial queue the stream's audio output is delivered on.
const AUDIO_QUEUE_LABEL: &str = "slopdesk.video.capture.audio";

/// A delivery gap past this many seconds is what the debug trace reports.
///
/// 28 ms — past one 30 fps slot, so continuous motion that hits it means `ScreenCaptureKit` itself
/// stalled. An idle page gaps legitimately and constantly, which is why the trace is gated.
const GAP_TRACE_SECONDS: f64 = 0.028;

/// The scroll estimator's search radius, as a fraction of the frame height.
///
/// A quarter of the frame, floored at [`SCROLL_SEARCH_FLOOR`] rows: past that a "scroll" is a cut,
/// and the estimator's own confidence collapses anyway.
const SCROLL_SEARCH_DIVISOR: usize = 4;

/// The floor under that radius, in rows.
const SCROLL_SEARCH_FLOOR: usize = 8;

/// The two planes an NV12 buffer has: luma, then interleaved chroma.
const LUMA_PLANE: usize = 0;
const CHROMA_PLANE: usize = 1;

/// What the encoder must do with one frame.
///
/// Every field is an ANSWER from [`slopdesk_video::capture_gates`], never a decision taken here.
/// `crisp` is the one that can only come from the static timer: a live motion frame is never crisp,
/// because motion must stay low-latency and a near-lossless intra frame is not.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a frame's plan IS four independent instructions to the encoder; folding them into an enum \
              would name states no caller would mention twice"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FramePlan {
    /// Encode as an IDR.
    pub force_keyframe: bool,
    /// Encode with the near-lossless static bracket. Only ever set by the static-IDR timer.
    pub crisp: bool,
    /// Encode small and coarse enough to survive a burst.
    pub compact: bool,
    /// Encode as a cheap `ForceLTRRefresh` P-frame.
    pub ltr_refresh: bool,
    /// The per-frame quantiser ceiling the adaptive-QP measurement staged, or `None` when the gate
    /// is off or this frame owns its own bracket.
    pub per_frame_max_qp: Option<i32>,
}

/// Where a capture's findings go.
///
/// A trait rather than a bag of closures for the reason `slopdesk-apple-vt`'s `FrameSink` gives:
/// the events are genuinely different, with different consumers and different queues, and
/// collapsing them into one nullable callback is what made the Swift's drop paths easy to swallow.
///
/// ⚠️ [`Self::frame`] and [`Self::capture_failed`] arrive ON the frame queue — or on the encode
/// thread when the decoupled backlog is enabled — and [`Self::audio`] arrives on the audio queue.
/// [`Self::scroll`] and [`Self::delivery_gap`] arrive on the frame queue WHILE the capturer holds
/// its frame-state lock. No implementation may re-enter the capturer from any of them: the blocking
/// methods would deadlock the queue, and the two lock-held callbacks would deadlock the mutex.
pub trait CaptureEvents: Send + Sync + fmt::Debug {
    /// One frame, with the plan the encoder must honour for it.
    ///
    /// The buffer is borrowed for the call. On the live path it is the FRAMEWORK's own surface,
    /// which goes back to its pool the moment this returns; on the synthetic and decoupled paths it
    /// is a buffer rebuilt from the cache and dropped just after. Either way, whatever outlives the
    /// call is the implementation's to copy.
    fn frame(&self, image: &CVImageBuffer, presentation: Timestamp, plan: FramePlan);

    /// One audio buffer, borrowed for the call, on the audio queue.
    fn audio(&self, sample: &CMSampleBuffer);

    /// The measured content scroll between the previous frame and this one.
    ///
    /// Sent only on a confident non-zero shift, plus exactly one [`ScrollHint::NONE`] when
    /// scrolling stops — the decay arm, so the client stops warping.
    fn scroll(&self, hint: ScrollHint);

    /// The stream stopped ITSELF: the window closed, the display was unplugged, the grant was
    /// revoked, the window server reset. Never called for a deliberate [`Capturer::stop`].
    fn capture_failed(&self);

    /// A delivery gap worth reporting, in seconds, under `SLOPDESK_VIDEO_DEBUG` only.
    ///
    /// Defaulted to nothing because it is a diagnostic and this crate may not print: `print_stderr`
    /// is denied here, and where a daemon's diagnostics GO is the daemon's question, not the
    /// capturer's. The Swift wrote these to standard error from inside the capture callback.
    fn delivery_gap(&self, _seconds: f64) {}
}

/// What a caller chooses about a capture before the stream exists.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Shape {
    /// The capture frame-rate cap. Floored at one; drives `minimumFrameInterval`.
    pub fps: i32,
    /// Window points × this = the output buffer's pixels. Floored at one, as the Swift floored it.
    pub capture_scale: f64,
    /// Capture the FULL-RANGE NV12 variant rather than the video-range one.
    ///
    /// Also the format every rebuilt buffer is allocated in, which is why it is one field and not
    /// two: a cache rebuilt in the other variant would encode with the wrong luma range.
    pub full_range: bool,
    /// Prefer the display-anchored filter when no environment override says otherwise.
    ///
    /// The live session passes `true`: display-anchored is a whole 60 Hz slot lower glass-to-glass
    /// AND occlusion-proof. The default stays `false` so a bare capture check keeps the per-window
    /// path, which is exactly where the Swift's `init` default sat.
    pub prefer_display_anchored: bool,
    /// The audio tap's sample rate. Zeroed by the bring-up when the audio gate is off.
    ///
    /// Asked for rather than read: the number belongs to the audio encoder, and a capturer that
    /// spelled it would be a second place it lives.
    pub audio_sample_rate: i32,
    /// The audio tap's channel count, on the same terms.
    pub audio_channel_count: i32,
}

impl Default for Shape {
    /// The daemon's own defaults: 60 fps, unscaled, video range, per-window, no audio.
    fn default() -> Self {
        Self {
            fps: 60,
            capture_scale: 1.0,
            full_range: false,
            prefer_display_anchored: false,
            audio_sample_rate: 0,
            audio_channel_count: 0,
        }
    }
}

/// The stream would not come up.
///
/// The status is `ScreenCaptureKit`'s own, or one of `slopdesk-apple-sck`'s sentinels:
/// [`slopdesk_apple_sck::TIMED_OUT`] for no answer inside the wait limit,
/// [`slopdesk_apple_sck::NO_CONTENT`] for nothing shareable — no grant, no window server — and
/// [`slopdesk_apple_sck::NO_TARGET`] for nothing matching the id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureRefused(pub i32);

impl fmt::Display for CaptureRefused {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "the capture stream was refused (status {})", self.0)
    }
}

impl std::error::Error for CaptureRefused {}

/// Why an in-place resize could not be done, so the caller can restart-fallback instead.
///
/// Four variants because the Swift raised four and the difference is what a caller acts on: the
/// first three mean "rebuild the stream", the fourth means the live stream is still running at the
/// OLD size — a refused reconfigure never kills a capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CannotResizeInPlace {
    /// Nothing is capturing.
    NoStream,
    /// The crop follows the window's own backing store, so there is no configuration to rewrite.
    NotDisplayAnchored,
    /// The crop is a poller-owned dialog union; the poller re-targets rather than resizing.
    UnionOwned,
    /// The live stream refused the new configuration and kept the old one.
    Refused(i32),
}

impl fmt::Display for CannotResizeInPlace {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::NoStream => formatter.write_str("there is no capture stream to resize"),
            Self::NotDisplayAnchored => {
                formatter.write_str("a per-window capture cannot be resized in place")
            },
            Self::UnionOwned => formatter.write_str("a poller-owned union crop cannot be resized in place"),
            Self::Refused(status) => {
                write!(
                    formatter,
                    "the live stream refused the new size (status {status}) and kept the old one"
                )
            },
        }
    }
}

impl std::error::Error for CannotResizeInPlace {}

/// The four things a capture drops, counted.
///
/// Every one of them was a `log.notice` every 600th event in Swift. The COUNT is kept here — it is
/// frame-path bookkeeping — and the logging is the owner's, for the reason
/// [`CaptureEvents::delivery_gap`] gives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    /// Frames dropped as byte-identical and obligation-free.
    pub idle_skipped: u64,
    /// Fast-scroll frames evenly decimated by the scroll-fps cap.
    pub scroll_decimated: u64,
    /// Complete-but-duplicate re-deliveries suppressed.
    pub duplicates_suppressed: u64,
    /// Deltas dropped or coalesced out because the encode backlog was full.
    pub backlog_dropped: u64,
}

/// A live capture, or one that has not been started yet.
///
/// EVERY method takes `&self`, [`Capturer::stop`] and the two starts included. That is not a
/// convenience: the session holds its capture behind an `Arc` and swaps it under a resize, so a
/// `&mut` receiver anywhere would force the session to own the only handle at exactly the moment
/// two threads need one, and `Arc::try_unwrap` at teardown is a race rather than a fix. The
/// interior state — the stream, the two join handles, the frame-queue state — is this type's own
/// business, behind the locks [`Inner`] already holds.
///
/// Not `Clone`: an `Arc` is how a caller shares one, and a second independent handle onto the same
/// stream would be two owners of one teardown.
#[derive(Debug)]
pub struct Capturer {
    inner: Arc<Inner>,
}

impl Capturer {
    /// Holds everything a capture needs, and resolves its gates, without touching the framework.
    ///
    /// Infallible: nothing here can fail, and the two dispatch queues are created eagerly because
    /// they are what the frame-queue discipline is ABOUT — a queue created lazily on first delivery
    /// would be created on a framework thread, by whichever producer got there first.
    #[must_use]
    pub fn new(shape: Shape, events: Arc<dyn CaptureEvents>, overlay: &Overlay) -> Self {
        let fps = shape.fps.max(1);
        let read = reader(overlay);
        let capture_texts: Vec<Option<String>> = CAPTURE_KEYS.iter().map(|key| read(key)).collect();
        let capture_values: Vec<Option<&str>> = capture_texts.iter().map(|slot| slot.as_deref()).collect();
        let gates = CaptureGates::from_env(&capture_values, CaptureGateContext {
            max_allowed_frame_qp: crate::encode::max_allowed_frame_qp(overlay),
            encode_ewma_alpha: EncodeLoadPacerConfig::default().alpha,
        });
        // The pacer's FLOOR is the network governor's, deliberately: the two axes cap the same
        // rate, and a compute-side floor below the network-side one would let an
        // over-running encoder steer past a rate the governor had already declared the
        // minimum acceptable.
        let governor_texts: [Option<String>; GOVERNOR_KEYS.len()] =
            core::array::from_fn(|index| GOVERNOR_KEYS.get(index).copied().and_then(&read));
        let governor_values: [Option<&str>; GOVERNOR_KEYS.len()] =
            core::array::from_fn(|index| governor_texts.get(index).and_then(|slot| slot.as_deref()));
        let min_fps = FpsGovernorConfig::from_env(&governor_values).min_fps;
        let heartbeat = resolve_heartbeat(read("SLOPDESK_HEARTBEAT_S").as_deref());
        let quiet = resolve_quiet_window(read("SLOPDESK_QUIET_MS").as_deref(), heartbeat);
        let inner = Inner {
            shape: Shape {
                fps,
                capture_scale: shape.capture_scale.max(1.0),
                ..shape
            },
            gates,
            heartbeat,
            capture_hz: resolve_capture_hz(read("SLOPDESK_CAPTURE_HZ").as_deref(), fps).max(1),
            queue_depth: resolve_queue_depth(read("SLOPDESK_CAPTURE_QUEUE_DEPTH").as_deref()),
            idr_tick: resolve_idr_poll_tick(read("SLOPDESK_IDR_TICK_MS").as_deref()),
            capture_mode: read("SLOPDESK_DISPLAY_CAPTURE"),
            events,
            epoch: Instant::now(),
            frame_queue: DispatchQueue::new(FRAME_QUEUE_LABEL, None),
            audio_queue: DispatchQueue::new(AUDIO_QUEUE_LABEL, None),
            stream: Mutex::new(None),
            live: Mutex::new(Live::new(heartbeat, quiet)),
            latches: Mutex::new(Latches::new(fps)),
            audio_forwarding: Mutex::new(false),
            pacer: Mutex::new(PacerState::new(fps, min_fps)),
            anchor: Mutex::new(AnchorDrive::default()),
            backlog: Mutex::new(Backlog::default()),
            backlog_ready: Condvar::new(),
            timer_wake: Condvar::new(),
            timer_stop: Mutex::new(false),
            counters: Mutex::new(Counters::default()),
            threads: Mutex::new(Threads::default()),
        };
        Self {
            inner: Arc::new(inner),
        }
    }

    /// The resolved capture operating point, for a session that needs one of the same knobs.
    ///
    /// Answered rather than re-resolved by the caller, so the daemon has exactly one resolution of
    /// the table per capture: the session's audio decision, its heartbeat and its debug switch all
    /// come from this value.
    #[must_use]
    pub fn gates(&self) -> CaptureGates {
        self.inner.gates
    }

    /// The resolved delivery ceiling in Hz — the same rule the stream itself is configured with, so
    /// a caller that sizes a timeout against it cannot disagree with the stream.
    #[must_use]
    pub fn capture_hz(&self) -> i32 {
        self.inner.capture_hz
    }

    /// Starts capturing one window at an explicit PIXEL size.
    ///
    /// The window is named by ID, never by an enumerated object: the mint flow moves the window
    /// onto the virtual display AFTER whatever the caller enumerated was made, so that object's
    /// frame is the PRE-move one and a display-local crop computed from it would be wrong. The
    /// far side re-resolves by id, which makes that the only path rather than a correction
    /// inside one.
    ///
    /// `region` is the dialog-expand crop: when present the display-anchored crop is pinned to that
    /// explicit union rect (window ∪ dialog) instead of the live window frame, and
    /// `pixel_width`/`pixel_height` must already match its size times the capture scale.
    ///
    /// ⚠️ BLOCKS, and requires a window server plus a Screen-Recording grant. Never call from the
    /// frame queue.
    ///
    /// # Errors
    /// [`CaptureRefused`] with the framework's status or one of the crate's sentinels.
    pub fn start_window(
        &self,
        window_id: u32,
        pixel_width: i32,
        pixel_height: i32,
        region: Option<CaptureRegion>,
    ) -> Result<(), CaptureRefused> {
        let mode = resolve_capture_mode(
            self.inner.capture_mode.as_deref(),
            self.inner.shape.prefer_display_anchored,
        );
        self.bring_up(
            CaptureTarget::Window {
                window_id,
                mode,
                region,
            },
            pixel_width,
            pixel_height,
        )
    }

    /// Starts capturing a WHOLE display — the full-desktop pane — at an explicit PIXEL size.
    ///
    /// Everything on the display is captured, dock and desktop included, and the source-rect pin IS
    /// the full display, so no crop or anchor state is kept: a display never moves and the window
    /// path's re-anchor machinery stays inert.
    ///
    /// ⚠️ Same window-server and grant requirements as [`Self::start_window`].
    ///
    /// # Errors
    /// [`CaptureRefused`], as above.
    pub fn start_display(
        &self,
        display_id: u32,
        pixel_width: i32,
        pixel_height: i32,
    ) -> Result<(), CaptureRefused> {
        self.bring_up(CaptureTarget::Display { display_id }, pixel_width, pixel_height)
    }

    /// Stops the capture and JOINS both threads.
    ///
    /// `&self`, like everything else here: the session holds its capture behind an `Arc` and a
    /// reap, a client `bye`, a resize rollback and [`Drop`] can all reach this, sometimes from
    /// different threads. IDEMPOTENT on every one of those paths, and every step is a TAKE —
    /// the stream out of its slot, the two join handles out of theirs — so the framework
    /// teardown happens exactly once no matter how many callers arrive. Doing it twice would be
    /// a use-after-free.
    ///
    /// Safe on a capturer that never started or has already died: the `capture_stopped` latch is
    /// taken INSIDE the frame queue before anything else, so a capture-death callback racing a
    /// deliberate stop cannot fire [`CaptureEvents::capture_failed`] afterwards — whichever side
    /// runs first wins and the other no-ops.
    ///
    /// ⚠️ Never call from the frame queue, and never from a [`CaptureEvents`] callback: this enters
    /// the frame queue and joins the two threads that deliver those callbacks.
    pub fn stop(&self) {
        let inner = &self.inner;
        // 1. Quiesce, on the queue every tick and every delivery runs on, so a tick already in
        //    flight finishes and any later one is inert before a thread is asked to end.
        inner.frame_queue.exec_sync(|| {
            let mut live = inner.lock_live();
            live.capture_stopped = true;
            live.gated_flush_due = None;
            live.cached = None;
        });
        // 2. The framework, TAKEN out of its slot so a second caller finds nothing to stop. A
        //    stream that already died answers an error, which is nothing to act on: the teardown is
        //    identical either way and the death callback has already fired.
        let stopped = inner.lock_stream().take();
        if let Some(stream) = stopped {
            let _status = stream.stop();
        }
        // 3. The timer thread, woken so a stop never waits out a poll tick.
        {
            let mut stopping = inner.timer_stop.lock().unwrap_or_else(PoisonError::into_inner);
            *stopping = true;
        }
        inner.timer_wake.notify_all();
        // 4. The encode drain. The pending deltas are DISCARDED rather than flushed — a deliberate
        //    delta from the Swift, whose GCD tail could still encode after `stop()` returned. The
        //    session drains the encoder right after this returns, so a delta encoded into a session
        //    that is going away has no reader.
        {
            let mut backlog = inner.lock_backlog();
            backlog.pending.clear();
            backlog.stopping = true;
        }
        inner.backlog_ready.notify_all();
        // 5. Both threads, TAKEN and then joined with the handle lock RELEASED — a join under it
        //    would hold it for the whole shutdown, and `arm_threads` on another thread would block
        //    behind a teardown it is not part of. Every wake above is already published, so a
        //    thread that has not noticed yet is about to. The take is what makes the join happen
        //    once.
        let (timer, encoder) = {
            let mut threads = inner.lock_threads();
            (threads.timer.take(), threads.encoder.take())
        };
        if let Some(handle) = timer {
            let _joined = handle.join();
        }
        if let Some(handle) = encoder {
            let _joined = handle.join();
        }
    }

    /// Whether this capture crops a DISPLAY — i.e. it owns a live configuration an in-place size
    /// change can drive. Per-window mode answers `false`.
    #[must_use]
    pub fn is_display_anchored(&self) -> bool {
        let stream = self.inner.lock_stream();
        stream.as_ref().is_some_and(CaptureStream::is_display_anchored)
    }

    /// Whether the crop is a dialog-expand union region the geometry poller owns.
    #[must_use]
    pub fn is_union_anchored(&self) -> bool {
        let stream = self.inner.lock_stream();
        stream.as_ref().is_some_and(CaptureStream::is_union_anchored)
    }

    /// Re-origins a display-anchored crop after the window MOVED.
    ///
    /// `window_origin` is the window's frame origin in GLOBAL CG points; the display-local
    /// conversion is `slopdesk-apple-sck`'s, against the display the crop was anchored to. A no-op
    /// in per-window mode, on a union crop, and for sub-half-point deltas — the far side decides
    /// which. Rare and user-driven (a title-bar drag), never per-frame.
    ///
    /// COALESCED and SINGLE-DRIVER: overlapping callers record the latest origin and return; only
    /// the first becomes the driver, and it loops until nothing newer is pending. That is what
    /// keeps a drag from issuing one reconfigure per poll for positions the window has already
    /// left. A successful re-anchor arms a keyframe: the crop jump lands mid-GOP as a
    /// whole-frame delta, and an anchor right after it is what keeps a late-joining client from
    /// decoding half of each.
    ///
    /// ⚠️ BLOCKS on the framework while it is the driver. Never call from the frame queue.
    pub fn reanchor(&self, window_origin: VideoPoint) {
        if !self.inner.claim_anchor_drive(window_origin) {
            return;
        }
        while let Some(origin) = self.inner.next_anchor() {
            let status = {
                let stream = self.inner.lock_stream();
                stream.as_ref().map_or(NO_ERROR, |stream| stream.reanchor(origin))
            };
            if status == NO_ERROR {
                self.request_keyframe();
            }
        }
    }

    /// Reconfigures the LIVE stream to a new pixel size, with NO restart.
    ///
    /// The framework's ~120 ms spin-up is what this avoids. The far side rebuilds the configuration
    /// at the new size and preserves the display-anchored crop ORIGIN at the new point size; the
    /// filter is untouched, so only the size and the crop move.
    ///
    /// The single-driver anchor gate is CLAIMED for the duration, so a concurrent window-move
    /// re-anchor records its origin and defers instead of issuing a second reconfigure mid-resize,
    /// and any move recorded meanwhile is dropped at the end — the crop this resize just wrote is
    /// newer than the position that move described.
    ///
    /// ⚠️ BLOCKS on the framework. Never call from the frame queue.
    ///
    /// # Errors
    /// [`CannotResizeInPlace`], whose first three variants mean "rebuild the stream" and whose
    /// fourth means the live stream is still running at the OLD size.
    pub fn resize(&self, pixel_width: i32, pixel_height: i32) -> Result<(), CannotResizeInPlace> {
        self.inner.hold_anchor_drive();
        let outcome = self.inner.resize_held(pixel_width, pixel_height);
        self.inner.release_anchor_drive();
        outcome
    }

    /// Arms a forced IDR for the next encoded frame — a client's loss-recovery request, or a join.
    ///
    /// A LATCH, not a request: it survives until a frame actually drains it, which is what lets the
    /// static-IDR timer service it on a window where nothing is being delivered at all.
    pub fn request_keyframe(&self) {
        self.inner.lock_latches().keyframe = true;
    }

    /// Arms a cheap LTR refresh — the recovery alternative to a forced IDR when the client's
    /// acknowledged reference is still good.
    pub fn request_ltr_refresh(&self) {
        self.inner.lock_latches().ltr_refresh = true;
    }

    /// Records whether client LTR acks are flowing, which is what arms the self-heal cadence.
    pub fn set_self_heal_eligible(&self, eligible: bool) {
        self.inner.lock_latches().self_heal_eligible = eligible;
    }

    /// Pushes the freshly-folded loss EWMA the self-heal loss gate consults.
    pub fn set_self_heal_loss_rate(&self, rate: f64) {
        self.inner.lock_latches().self_heal_loss_rate = rate;
    }

    /// Sets the network governor's frame rate, clamped into `1..=fps`.
    ///
    /// Composed with the encode-load pacer at the cadence gate: the effective rate is the MORE
    /// restrictive of the two, so a congested link and an over-running encoder each cap the rate
    /// without fighting.
    pub fn set_governed_fps(&self, fps: i32) {
        let clamped = fps.max(1).min(self.inner.shape.fps);
        self.inner.lock_latches().governed_fps = clamped;
    }

    /// Pauses encode and send while the client's feedback has gone silent.
    ///
    /// The cache, the decider and the PTS still advance, so a crisp refresh on resume carries the
    /// latest content; only the hand-off is skipped, so the encoder's reference chain does NOT
    /// advance and the client's next delta decodes against its last received frame with no
    /// keyframe. A pending recovery latch is exempt, for a clean resume.
    pub fn set_client_silence_paused(&self, paused: bool) {
        self.inner.lock_latches().client_silence_paused = paused;
    }

    /// Turns the audio tap's forwarding on or off.
    ///
    /// One lock read per ~10 ms buffer covers the gate and the sink together, and a disabled
    /// session drops the buffer BEFORE any extract or encode work.
    pub fn set_audio_forwarding_enabled(&self, enabled: bool) {
        let mut forwarding = self
            .inner
            .audio_forwarding
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        *forwarding = enabled;
    }

    /// The current encode-wall EWMA in milliseconds; `0.0` when nothing has been encoded yet.
    ///
    /// Only ever non-zero under the decoupled encode queue, which is where the measurement is taken
    /// — the in-line hand-off does not time itself, exactly as the Swift's did not.
    #[must_use]
    pub fn encode_millis_ewma(&self) -> f64 {
        self.inner.lock_pacer().encode_millis_ewma
    }

    /// The four drop counts, for an owner that logs them.
    #[must_use]
    pub fn counters(&self) -> Counters {
        *self.inner.counters.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The shared bring-up: start the framework stream, then arm both threads.
    ///
    /// The teardown latches are cleared first, so a capturer that was stopped can be started again
    /// rather than coming up with two inert threads — the Swift's session always built a fresh
    /// capturer, and this makes that a choice rather than a requirement.
    ///
    /// The threads are armed AFTER the stream so a timer tick cannot precede the first delivery,
    /// and the encode drain exists only when the gate admits one: an in-line hand-off has no
    /// backlog and wants no thread.
    fn bring_up(
        &self,
        target: CaptureTarget,
        pixel_width: i32,
        pixel_height: i32,
    ) -> Result<(), CaptureRefused> {
        self.inner.rearm();
        let request = StartRequest {
            target,
            pixel_width,
            pixel_height,
            capture_scale: self.inner.shape.capture_scale,
            capture_hz: self.inner.capture_hz,
            queue_depth: self.inner.queue_depth,
            full_range: self.inner.shape.full_range,
            audio_sample_rate: if self.inner.gates.audio_capture {
                self.inner.shape.audio_sample_rate
            } else {
                0
            },
            audio_channel_count: self.inner.shape.audio_channel_count,
        };
        let sink: Arc<dyn CaptureSink> = Arc::new(Tap {
            inner: Arc::clone(&self.inner),
        });
        let stream = CaptureStream::start(request, sink, &self.inner.frame_queue, &self.inner.audio_queue)
            .map_err(CaptureRefused)?;
        *self.inner.lock_stream() = Some(stream);
        self.arm_threads();
        Ok(())
    }

    /// Arms the static-IDR timer and, when the gate admits one, the decoupled encode drain.
    ///
    /// The handle lock is held ACROSS the spawns, which is what makes two concurrent starts arm one
    /// pair of threads rather than two: the second caller finds both slots full. A spawn that fails
    /// leaves its slot empty and the capture runs without that thread — the timer's absence costs
    /// the static re-anchor, not the stream.
    fn arm_threads(&self) {
        let mut threads = self.inner.lock_threads();
        if threads.timer.is_none() {
            let inner = Arc::clone(&self.inner);
            threads.timer = thread::Builder::new()
                .name(String::from("slopdesk-capture-idr"))
                .spawn(move || inner.run_timer())
                .ok();
        }
        if threads.encoder.is_none() && self.inner.gates.encode_off_queue {
            let inner = Arc::clone(&self.inner);
            threads.encoder = thread::Builder::new()
                .name(String::from("slopdesk-capture-encode"))
                .spawn(move || inner.run_encoder())
                .ok();
        }
    }
}

impl Drop for Capturer {
    /// A capturer that is merely let go is torn down IDENTICALLY to one that is stopped: the same
    /// `&self` method, so a stream nobody stopped still leaves no threads holding an `Arc` on state
    /// nothing reads. The stop is idempotent, so this costs nothing on the ordinary path and closes
    /// the one that forgot.
    fn drop(&mut self) {
        self.stop();
    }
}

// ---------------------------------------------------------------------------- //
// The framework's view of the capturer

/// What `ScreenCaptureKit` is handed.
///
/// A separate type rather than [`Inner`] itself, for two reasons. It keeps [`Capturer`]'s public
/// surface free of a trait no caller of this module implements; and `stopped` needs an OWNED handle
/// to hop asynchronously onto the frame queue, which a `&self` on `Inner` cannot produce.
#[derive(Debug)]
struct Tap {
    inner: Arc<Inner>,
}

impl CaptureSink for Tap {
    fn frame(&self, image: &CVImageBuffer, presentation: CMTime) {
        self.inner.deliver_frame(image, presentation);
    }

    /// One audio buffer, on the audio queue — its own serial output, so no frame-queue state is
    /// touched here at all. One lock read per buffer covers the gate and the sink together, and a
    /// disabled session drops the buffer before any extract or encode work.
    fn audio(&self, sample: &CMSampleBuffer) {
        let forwarding = *self
            .inner
            .audio_forwarding
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if forwarding {
            self.inner.events.audio(sample);
        }
    }

    fn stopped(&self) {
        Inner::handle_capture_failure(&self.inner);
    }
}

// ---------------------------------------------------------------------------- //
// The shared body

/// Everything the capture callback, the timer and the encode drain all reach.
///
/// One `Arc`, because the framework's tap holds it, both threads hold it, and the handle holds it —
/// four owners of one capture, which is precisely what an `Arc` is for. Every field is `Send` and
/// `Sync` with no `unsafe` anywhere: that is the whole point of [`FrameBytes`], and it is what
/// makes this type legal as an `Arc<dyn CaptureSink>` in the first place.
struct Inner {
    shape: Shape,
    gates: CaptureGates,
    /// The periodic motion-IDR cadence, in seconds.
    heartbeat: f64,
    /// The resolved delivery ceiling, which is also what the cadence gate's tolerance is half of —
    /// stored so the tolerance and the stream's own configuration cannot disagree.
    capture_hz: i32,
    queue_depth: i32,
    /// How often the static-IDR timer polls. DECOUPLED from the heartbeat: with a multi-second
    /// heartbeat the timer must still service a recovery latch promptly, and the decider only EMITS
    /// when due, so a sub-cadence tick is a cheap no-op.
    idr_tick: f64,
    /// The capture-mode request's raw text, read once and re-asked per start.
    capture_mode: Option<String>,
    events: Arc<dyn CaptureEvents>,
    /// The origin every `f64` second in this module is measured from.
    epoch: Instant,
    /// The serial queue the screen output AND the static-IDR timer share.
    frame_queue: DispatchRetained<DispatchQueue>,
    /// The audio tap's own serial queue, so a ~10 ms buffer never queues behind a video encode.
    audio_queue: DispatchRetained<DispatchQueue>,
    stream: Mutex<Option<CaptureStream>>,
    /// Frame-queue-confined state. Uncontended by construction; see the module note.
    live: Mutex<Live>,
    /// The session's writes. Its own lock so arming a recovery keyframe never blocks behind a
    /// frame.
    latches: Mutex<Latches>,
    audio_forwarding: Mutex<bool>,
    pacer: Mutex<PacerState>,
    anchor: Mutex<AnchorDrive>,
    backlog: Mutex<Backlog>,
    backlog_ready: Condvar,
    /// Woken by a stop, and by a delivery that armed a gated-tail flush sooner than the next poll.
    timer_wake: Condvar,
    timer_stop: Mutex<bool>,
    counters: Mutex<Counters>,
    /// The two join handles, so [`Capturer::stop`] can take a `&self` receiver.
    threads: Mutex<Threads>,
}

/// The two threads a live capture owns.
///
/// Inside [`Inner`] rather than beside the handle for one reason: [`Capturer::stop`] takes `&self`,
/// because the session shares its capture through an `Arc` and a `&mut` receiver would force it to
/// own the only handle at the moment two threads need one. A join handle is the one piece of state
/// a stop must MOVE OUT of, so it lives behind the same kind of lock everything else here does.
///
/// Neither thread ever takes this lock, so it can never be held against them.
#[derive(Debug, Default)]
struct Threads {
    /// The static-IDR timer. `None` until a start arms it, and again after a stop joins it.
    timer: Option<JoinHandle<()>>,
    /// The decoupled encode drain, when the gate admits one. Same lifetime.
    encoder: Option<JoinHandle<()>>,
}

impl fmt::Debug for Inner {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Inner")
            .field("shape", &self.shape)
            .field("gates", &self.gates)
            .field("heartbeat", &self.heartbeat)
            .field("capture_hz", &self.capture_hz)
            .field("queue_depth", &self.queue_depth)
            .field("idr_tick", &self.idr_tick)
            .finish_non_exhaustive()
    }
}

/// One frame's NV12 pixels, in memory this process owns.
///
/// The reason this type exists is the module note's: a `CVImageBuffer` cannot cross a thread and
/// this can. Rows are kept at their SOURCE stride, padding included, because that is what makes the
/// read a plain per-plane copy and what lets [`slopdesk_video::frame_hash`] and
/// [`slopdesk_video::adaptive_qp`] read it with the same `(bytes, stride)` shape they read a locked
/// framework plane with.
///
/// Chroma is optional: a luma-only buffer is a complete frame for every rule here, and a hash over
/// one plane is still a hash over everything the buffer has.
#[derive(Debug)]
struct FrameBytes {
    /// Visible luma samples per row, and rows — the picture, not the mapping.
    width: usize,
    height: usize,
    luma: Vec<u8>,
    luma_stride: usize,
    chroma: Option<Vec<u8>>,
    chroma_stride: usize,
}

/// The state only the frame queue touches: the capture callback and the static-IDR timer, which run
/// on the same serial queue and therefore never at once.
#[derive(Debug)]
struct Live {
    /// The last delivered frame's pixels, which are BOTH the previous frame the two measurements
    /// compare against and the content the static timer re-encodes. Behind an `Arc` so a backlog
    /// entry is a pointer clone rather than a second copy. `None` before the first delivery, and
    /// after a stop or a capture death — a decider with nothing retained emits nothing, which is
    /// the safe answer.
    cached: Option<Arc<FrameBytes>>,
    anchors: EncodeAnchors,
    idr: StaticIdrDecider,
    stillness: StillnessCrispDecider,
    cadence: EncodeCadenceGate,
    /// Consecutive fast-scroll frames, and the Bresenham accumulator beside it.
    motion_run: u32,
    scroll_phase: i32,
    /// The last smoothed adaptive-QP ceiling, and the one this frame staged for the hand-off.
    smoothed_qp: Option<i32>,
    pending_qp: Option<i32>,
    /// Whether the last scroll measurement was non-zero, so the decay arm fires exactly once.
    scroll_was_moving: bool,
    /// The 90 kHz high-water mark every emitted PTS passes through.
    last_pts_ticks: i64,
    /// The hash of the last frame actually SUBMITTED, so the next capture is compared against what
    /// was sent rather than against a frame that was gated and dropped.
    last_submitted_hash: Option<u64>,
    /// The last full hash the idle-skip decision saw, and the last the stillness decider was fed.
    last_idle_hash: Option<u64>,
    last_stillness_hash: Option<u64>,
    /// When the armed one-shot gated-tail flush is due, in epoch seconds.
    gated_flush_due: Option<f64>,
    /// When the next static-IDR poll is due, in epoch seconds.
    next_tick_due: f64,
    /// When the last frame was delivered, for the debug gap trace only.
    last_delivery: f64,
    /// The two one-shot teardown latches, so a deliberate stop and a capture death cannot both win.
    capture_failed: bool,
    capture_stopped: bool,
}

impl Live {
    const fn new(heartbeat: f64, quiet_window: f64) -> Self {
        Self {
            cached: None,
            anchors: EncodeAnchors {
                last_heartbeat: 0.0,
                last_keyframe_emit: 0.0,
                frames_since_anchor: 0,
                force_compact_counter: 0,
                has_emitted_first_frame: false,
            },
            idr: StaticIdrDecider::new(heartbeat, Some(quiet_window)),
            stillness: StillnessCrispDecider::new(),
            cadence: EncodeCadenceGate::new(),
            motion_run: 0,
            scroll_phase: 0,
            smoothed_qp: None,
            pending_qp: None,
            scroll_was_moving: false,
            last_pts_ticks: 0,
            last_submitted_hash: None,
            last_idle_hash: None,
            last_stillness_hash: None,
            gated_flush_due: None,
            next_tick_due: 0.0,
            last_delivery: 0.0,
            capture_failed: false,
            capture_stopped: false,
        }
    }
}

/// Everything a session thread writes and the frame path reads.
///
/// One small lock, held for a single field read or write and never across framework work. Splitting
/// these out of [`Live`] is what keeps [`Capturer::request_keyframe`] from blocking behind a
/// frame's encode — the same reason the Swift kept `keyframeLock` separate from the queue-confined
/// state.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a latch table IS mostly latches; the same shape and the same reason `CaptureGates` carries \
              this allow"
)]
#[derive(Debug, Clone, Copy)]
struct Latches {
    keyframe: bool,
    ltr_refresh: bool,
    client_silence_paused: bool,
    governed_fps: i32,
    self_heal_eligible: bool,
    /// Infinite before any report, so an unmeasured link never suppresses healing.
    self_heal_loss_rate: f64,
}

impl Latches {
    const fn new(fps: i32) -> Self {
        Self {
            keyframe: false,
            ltr_refresh: false,
            client_silence_paused: false,
            governed_fps: fps,
            self_heal_eligible: false,
            self_heal_loss_rate: f64::INFINITY,
        }
    }
}

/// The encode-load pacer, and the two numbers that cross out of it.
///
/// The Swift confined the pacer struct to the serial encode queue and published only its output fps
/// under a lock. One mutex over both is the same guarantee with one fewer invariant to state: the
/// encode drain is the sole mutator either way.
#[derive(Debug)]
struct PacerState {
    pacer: EncodeLoadPacer,
    /// The rate the pacer last actuated.
    paced_fps: i32,
    /// Frames folded so far, for the periodic debug line only.
    wall_samples: u32,
    /// The always-on stats EWMA, in milliseconds. Folded even when the pacer itself is off.
    encode_millis_ewma: f64,
}

impl PacerState {
    fn new(fps: i32, min_fps: i64) -> Self {
        Self {
            pacer: EncodeLoadPacer::new(i64::from(fps), EncodeLoadPacerConfig::default(), min_fps),
            paced_fps: fps,
            wall_samples: 0,
            encode_millis_ewma: 0.0,
        }
    }
}

/// The single-driver re-anchor gate.
///
/// `in_flight` is the claim, `pending` is the LATEST origin nobody has applied yet. A caller that
/// finds the claim taken leaves its origin and returns; the driver loops until `pending` is empty.
#[derive(Debug, Clone, Copy, Default)]
struct AnchorDrive {
    in_flight: bool,
    pending: Option<VideoPoint>,
}

/// One frame waiting for the decoupled encode drain.
///
/// The bytes are an `Arc` clone of what the cache already holds, so enqueuing costs a refcount and
/// not a memcpy — which is what keeps this design at the Swift's own two copies per frame rather
/// than three.
#[derive(Debug)]
struct Pending {
    bytes: Arc<FrameBytes>,
    presentation: Timestamp,
    plan: FramePlan,
    /// Whether this frame may never be dropped: any real obligation.
    forced: bool,
    /// Whether this frame is excluded from the pacer's load EWMA. Big episodic IDRs are 5–10×
    /// encode-time outliers, exactly as the governor excludes them from its bytes EWMA; compact and
    /// LTR refreshes are near steady-state and ARE folded.
    pacer_anchor: bool,
}

/// The decoupled encode backlog.
#[derive(Debug, Default)]
struct Backlog {
    pending: VecDeque<Pending>,
    stopping: bool,
}

impl Inner {
    // -- lock helpers. Each takes the guard and hands it straight to the caller's statement, so a
    //    guard never outlives what needed it.

    fn lock_live(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_latches(&self) -> MutexGuard<'_, Latches> {
        self.latches.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_pacer(&self) -> MutexGuard<'_, PacerState> {
        self.pacer.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_stream(&self) -> MutexGuard<'_, Option<CaptureStream>> {
        self.stream.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_backlog(&self) -> MutexGuard<'_, Backlog> {
        self.backlog.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn lock_threads(&self) -> MutexGuard<'_, Threads> {
        self.threads.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Seconds since this capturer's epoch — the one clock every anchor, decider and gate sees.
    fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    /// Clears the three teardown latches so a stopped capturer can start again.
    fn rearm(&self) {
        {
            let mut live = self.lock_live();
            live.capture_stopped = false;
            live.capture_failed = false;
            live.next_tick_due = 0.0;
        }
        {
            let mut backlog = self.lock_backlog();
            backlog.stopping = false;
        }
        let mut stopping = self.timer_stop.lock().unwrap_or_else(PoisonError::into_inner);
        *stopping = false;
    }

    fn bump<F: FnOnce(&mut Counters)>(&self, body: F) {
        let mut counters = self.counters.lock().unwrap_or_else(PoisonError::into_inner);
        body(&mut counters);
    }

    // -- the re-anchor coalescer

    /// Records `origin` and answers whether this caller became the driver.
    fn claim_anchor_drive(&self, origin: VideoPoint) -> bool {
        let mut anchor = self.anchor.lock().unwrap_or_else(PoisonError::into_inner);
        anchor.pending = Some(origin);
        if anchor.in_flight {
            return false;
        }
        anchor.in_flight = true;
        true
    }

    /// The next origin for the driver to apply, releasing the claim when nothing is pending.
    fn next_anchor(&self) -> Option<VideoPoint> {
        let mut anchor = self.anchor.lock().unwrap_or_else(PoisonError::into_inner);
        let pending = anchor.pending.take();
        if pending.is_none() {
            anchor.in_flight = false;
        }
        pending
    }

    /// Claims the gate for a resize, so a concurrent move defers rather than reconfiguring twice.
    fn hold_anchor_drive(&self) {
        self.anchor
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .in_flight = true;
    }

    /// Releases it, dropping any move recorded meanwhile: the crop the resize just wrote is newer.
    fn release_anchor_drive(&self) {
        let mut anchor = self.anchor.lock().unwrap_or_else(PoisonError::into_inner);
        anchor.in_flight = false;
        anchor.pending = None;
    }

    /// [`Capturer::resize`]'s body, so the anchor gate is released on every exit including errors.
    fn resize_held(&self, pixel_width: i32, pixel_height: i32) -> Result<(), CannotResizeInPlace> {
        let mut held = self.lock_stream();
        let Some(stream) = held.as_mut() else {
            return Err(CannotResizeInPlace::NoStream);
        };
        if !stream.is_display_anchored() {
            return Err(CannotResizeInPlace::NotDisplayAnchored);
        }
        if stream.is_union_anchored() {
            return Err(CannotResizeInPlace::UnionOwned);
        }
        let status = stream.resize(pixel_width, pixel_height);
        drop(held);
        if status != NO_ERROR {
            return Err(CannotResizeInPlace::Refused(status));
        }
        // THE CACHED FRAME IS THE OLD SIZE, and every consumer of it rebuilds a buffer at the size
        // the BYTES describe: the static re-anchor would re-ship a stale-resolution frame into an
        // encoder that has just been re-pointed at the new one, and the idle/scroll comparisons
        // above the cadence gate would diff two different rasters. Dropped rather than converted —
        // the next delivery is one frame away and it arrives at the new size. Everything else in
        // `Live` is kept: the PTS counter must stay monotone and the decider's clock did not move.
        self.lock_live().cached = None;
        Ok(())
    }

    // -- the latches: PEEKED above every gate, DRAINED only below them

    /// Both recovery latches, drained together in the order the below-gate path expects.
    fn drain_recovery(&self) -> (bool, bool) {
        let mut latches = self.lock_latches();
        let keyframe = latches.keyframe;
        let ltr = latches.ltr_refresh;
        latches.keyframe = false;
        latches.ltr_refresh = false;
        drop(latches);
        (keyframe, ltr)
    }

    /// Re-arms whichever kinds were drained, for a timer tick that decided not to fire.
    fn relatch_recovery(&self, keyframe: bool, ltr: bool) {
        let mut latches = self.lock_latches();
        latches.keyframe |= keyframe;
        latches.ltr_refresh |= ltr;
    }

    /// The whole table, read once. PEEKED — a gate above the drain must never swallow a latch.
    fn peek(&self) -> Latches {
        *self.lock_latches()
    }

    /// The effective frame rate: the MORE restrictive of the network governor and the encode-load
    /// pacer, so a congested link and an over-running encoder each cap the rate without fighting.
    ///
    /// Sequential locks, never nested — the pacer's is taken after the latches' is released.
    fn governed_fps(&self) -> i32 {
        let governed = self.peek().governed_fps;
        if !self.gates.encode_pacer {
            return governed;
        }
        let paced = self.lock_pacer().paced_fps;
        governed.min(paced)
    }

    // -- the static-IDR timer

    /// The timer thread: wake, hop onto the frame queue, tick, repeat.
    ///
    /// The wake is the EARLIER of the next poll tick and any armed gated-tail flush, so the
    /// one-shot flush needs no second timer. The body runs through
    /// [`DispatchQueue::exec_sync`], which is the whole point of the thread: it is what
    /// serialises a tick against the capture callback.
    ///
    /// The stop mutex is held ACROSS the wake computation, and the arming path takes it once after
    /// releasing [`Inner::live`], so a flush armed between the computation and the wait cannot be
    /// missed. That is also why the arming path must never hold `live` when it takes this one: the
    /// order here is `timer_stop` then `live`, and the reverse would be an inversion.
    fn run_timer(&self) {
        loop {
            let mut stopping = self.timer_stop.lock().unwrap_or_else(PoisonError::into_inner);
            if *stopping {
                return;
            }
            let wake = {
                let now = self.now();
                let mut live = self.lock_live();
                if live.next_tick_due <= now {
                    live.next_tick_due = now + self.idr_tick;
                }
                let due = live
                    .gated_flush_due
                    .map_or(live.next_tick_due, |flush| flush.min(live.next_tick_due));
                drop(live);
                (due - now).clamp(0.0, self.idr_tick)
            };
            let waited = self
                .timer_wake
                .wait_timeout(stopping, Duration::from_secs_f64(wake))
                .unwrap_or_else(PoisonError::into_inner);
            stopping = waited.0;
            if *stopping {
                return;
            }
            drop(stopping);
            self.frame_queue.exec_sync(|| self.timer_body());
        }
    }

    /// One wake, ON the frame queue: the gated-tail flush first, then the static-IDR poll.
    ///
    /// The flush goes first because it carries the NEWEST content — a poll that emitted a synthetic
    /// IDR ahead of it would ship the same pixels twice, the second time under the older PTS.
    fn timer_body(&self) {
        let now = self.now();
        let (flush, tick) = {
            let mut live = self.lock_live();
            if live.capture_stopped || live.capture_failed {
                return;
            }
            let flush = live.gated_flush_due.is_some_and(|due| now >= due);
            if flush {
                live.gated_flush_due = None;
            }
            let tick = now >= live.next_tick_due;
            if tick {
                live.next_tick_due = now + self.idr_tick;
            }
            drop(live);
            (flush, tick)
        };
        if flush {
            self.gated_tail_flush(now);
        }
        if tick {
            self.idr_poll(now);
        }
    }

    /// The static-IDR poll.
    ///
    /// ⚠️ VIDEO-HOST-1 (`docs/25` §4): on a static window NOTHING is delivered, so the recovery
    /// latch and the heartbeat IDR would never drain and a client that requested loss recovery — or
    /// joined — would freeze on the last good frame. This is the second drainer, and on a truly
    /// static window it is the ONLY path that can produce an IDR at all.
    fn idr_poll(&self, now: f64) {
        // EVENT-DRIVEN crisp: a run of byte-identical complete re-deliveries already proved the
        // screen is at rest, so fire the crisp re-anchor NOW rather than waiting out the wall-clock
        // quiet window. A crisp keyframe is a superset of any pending recovery, so those latches
        // are drained and satisfied; `record_synthetic` re-anchors the normal static
        // cadence, which is what keeps this from double-emitting with the block below.
        if self.gates.still_crisp && self.stillness_ready() {
            let _satisfied = self.drain_recovery();
            {
                let mut live = self.lock_live();
                live.stillness.note_crisp_fired();
                live.idr.record_synthetic(now);
                live.anchors.last_keyframe_emit = now;
            }
            self.emit_cached_crisp();
            return;
        }
        let (keyframe, ltr) = self.drain_recovery();
        // A STATIC window has no live delta to ride an LTR refresh, so an LTR request degrades to
        // the same crisp re-anchor a forced keyframe gets — folded into `forced` here, but the plan
        // still says `ltr_refresh: false`, because this path never issues a real `ForceLTRRefresh`.
        let forced = keyframe || ltr;
        let fire = {
            let live = self.lock_live();
            live.cached.is_some() && live.idr.should_reencode(now, forced, true)
        };
        if !fire {
            // A drained request that did not fire is NOT lost: the live path will service it inside
            // the quiet window, so re-arm each kind that was taken.
            self.relatch_recovery(keyframe, ltr);
            return;
        }
        {
            let mut live = self.lock_live();
            live.idr.record_synthetic(now);
            // The timer ALWAYS emits a keyframe, so it always anchors the recovery cooldown.
            live.anchors.last_keyframe_emit = now;
        }
        self.emit_cached_crisp();
    }

    /// Whether the stillness decider says the screen is at rest and there is content to re-ship.
    fn stillness_ready(&self) -> bool {
        let threshold = usize::try_from(self.gates.still_crisp_threshold).unwrap_or(usize::MAX);
        let live = self.lock_live();
        live.cached.is_some() && live.stillness.should_fire_crisp(threshold)
    }

    /// Re-encodes the cached frame as the static re-anchor, at the synthetic PTS.
    ///
    /// Never compact: at rest no live delta competes for the wire, so the larger near-lossless IDR
    /// is no burst-loss risk. Never adaptive-QP-capped either — the crisp bracket owns its own
    /// quantiser, and a motion ceiling staged by a frame that is now stale would blur a still page.
    fn emit_cached_crisp(&self) {
        let presentation = self.next_synthetic_pts();
        let plan = FramePlan {
            force_keyframe: true,
            crisp: self.gates.crisp_when_static,
            compact: false,
            ltr_refresh: false,
            per_frame_max_qp: None,
        };
        self.hand_off_cached(presentation, plan);
    }

    /// The one-shot flush of a frame the cadence gate held back.
    ///
    /// If a gated delivery turns out to be the LAST of a burst, its content would otherwise sit
    /// unsent until the crisp refresh. The gate is RE-CONSULTED at the boundary so the metronome
    /// stays regular around the flush, and a governed rate that returned to base in the meantime
    /// makes it inert, exactly like the live path.
    fn gated_tail_flush(&self, now: f64) {
        let governed = self.governed_fps();
        if governed < self.shape.fps {
            let latches = self.peek();
            let admitted = {
                let mut live = self.lock_live();
                let must_encode =
                    !live.anchors.has_emitted_first_frame || latches.keyframe || latches.ltr_refresh;
                live.cadence.admit(
                    now,
                    1.0 / f64::from(governed),
                    0.5 / f64::from(self.capture_hz),
                    must_encode,
                )
            };
            if !admitted {
                return; // fired early against the schedule — the next delivery covers it
            }
        }
        let presentation = self.next_synthetic_pts();
        let plan = self.resolve_below_gate(now, governed, None);
        self.hand_off_cached(presentation, plan);
    }

    // -- the live path

    /// One frame carrying NEW pixels, on the frame queue.
    ///
    /// The surface is borrowed for the call only — it goes back to the framework's pool when this
    /// returns, inside `minimumFrameInterval × (queueDepth − 1)` (WWDC22 s10155) — so anything kept
    /// is read out first. A frame the framework marks anything but complete never reaches here at
    /// all, which is why more than nine in ten coding frames cost nothing: no surface touch, no
    /// encode, no send.
    ///
    /// The order below is the module note's, and every step's position is load-bearing.
    #[expect(
        clippy::too_many_lines,
        reason = "the ORDER is the subject: splitting it into helpers hides the one thing a reader must be \
                  able to check in a single pass"
    )]
    fn deliver_frame(&self, image: &CVImageBuffer, presentation: CMTime) {
        let now = self.now();
        let incoming = PixelBuffer::from_retained(CFRetained::from(image));
        let mut live = self.lock_live();
        if live.capture_stopped || live.capture_failed {
            return;
        }

        // The debug gap trace. A gap past 28 ms between two DELIVERED frames during continuous
        // motion means the framework itself stalled, and everything downstream can only inherit the
        // hole. Idle pages gap legitimately, so this is only ever read against a motion test.
        if self.gates.debug_gaps {
            if live.last_delivery > 0.0 && now - live.last_delivery > GAP_TRACE_SECONDS {
                self.events.delivery_gap(now - live.last_delivery);
            }
            live.last_delivery = now;
        }

        // ONE lock of the framework's surface, for everything that must read its pixels: the two
        // measurements against the PREVIOUS frame, the plane read that becomes the new cache, and
        // the shared hash. Splitting them would pay three bracket pairs on a user-interactive queue
        // for three reads of the same memory.
        let Some(locked) = incoming.lock_read_only() else {
            return; // a surface that will not map carries nothing this frame can use
        };
        let measurement = live
            .cached
            .as_ref()
            .map_or(Measurement::NONE, |previous| self.measure(previous, &locked));
        let fresh = read_frame(&locked).map(Arc::new);
        // The shared full-NV12 hash, computed AT MOST ONCE. Idle-skip, still-crisp and
        // static-suppress are three independently gated deciders that would otherwise each pay
        // their own lock and full-frame hash. The union of the three gates is the table's
        // own `needs_frame_hash`; the same value feeds every decider below AND the
        // submitted-hash record at the bottom, which is sound because a hash is
        // deterministic and the buffer is the same one. The Swift recomputed it at the
        // submit site; one computation is the same answer.
        let hash = if self
            .gates
            .needs_frame_hash(measurement.measured, measurement.change_milli)
        {
            hash_locked(&locked).filter(|value| *value != SENTINEL)
        } else {
            None
        };
        drop(locked);

        // SCROLL REPROJECTION: only a confident non-zero shift is sent, plus exactly one zero when
        // scrolling stops, which is the client's cue to stop warping.
        if self.gates.scroll_reproject {
            let hint = measurement.scroll;
            if hint.dx() == 0 && hint.dy() == 0 {
                if live.scroll_was_moving {
                    self.events.scroll(ScrollHint::NONE);
                    live.scroll_was_moving = false;
                }
            } else {
                self.events.scroll(hint);
                live.scroll_was_moving = true;
            }
        }
        live.pending_qp = (self.gates.adaptive_qp && measurement.measured).then(|| {
            // The asymmetric law is the table's: coarsen on motion ONSET by one part in `upRamp`
            // (default 1, so instantly) and re-sharpen on STOP by at most `downStep` per frame,
            // because a snap straight to the floor re-encodes the whole settled viewport in one
            // large frame — the scroll-stop stutter.
            let smoothed = self
                .gates
                .smooth_adaptive_qp(live.smoothed_qp, measurement.raw_qp);
            live.smoothed_qp = Some(smoothed);
            smoothed
        });

        // The cache is replaced HERE: below the reads that needed the old one, and above every path
        // that can return. Every return below — idle skip, decimation, suppression, silence pause,
        // cadence gate — must leave the cache holding THIS frame, or the static timer would re-ship
        // stale pixels for ever and the decider would believe the live path quiet mid-motion.
        live.cached.clone_from(&fresh);

        // TRUE IDLE-SKIP: drop a frame only when it is byte-identical to the previous one by the
        // FULL hash — luma AND chroma, so a syntax-highlight colour flip is never mistaken for
        // idle, which the luma-only change measurement would miss — and it carries no
        // obligation.
        let mut idle_skip = false;
        if self.gates.idle_skip
            && idle_skip_eligible(measurement.measured, measurement.change_milli)
            && let Some(value) = hash
        {
            let obligations = self.obligations(&live, now);
            idle_skip = live.last_idle_hash == Some(value) && should_suppress_static_frame(true, obligations);
            live.last_idle_hash = Some(value);
        }
        // A skipped frame must NOT re-anchor the decider: leaving the quiet-window clock stale is
        // exactly what lets the crisp refresh fire once the screen truly settles.
        if !idle_skip {
            live.idr.on_complete_frame(now);
        }

        // EVENT-DRIVEN crisp: feed hash-equality to the stillness decider BEFORE any suppression
        // return, so it sees every frame and a run of identical re-deliveries can trip the crisp
        // re-anchor ahead of the quiet window. The timer drains it.
        if self.gates.still_crisp
            && let Some(value) = hash
        {
            let equal = live.last_stillness_hash == Some(value);
            live.stillness.on_frame(equal);
            live.last_stillness_hash = Some(value);
        }

        if idle_skip {
            drop(live);
            self.bump(|counters| counters.idle_skipped = counters.idle_skipped.saturating_add(1));
            return;
        }

        // SCROLL-FPS CAP: hold roughly the capped rate during sustained FAST scroll so the hardware
        // encoder never overruns its budget. Bresenham-even decimation; only ordinary live frames
        // drop, because the obligation flag is PEEKED — a frame that owes a latch is never
        // decimated, and a frame the cap lets through never swallows one.
        let obligated = {
            let latches = self.peek();
            latches.keyframe
                || latches.ltr_refresh
                || self
                    .gates
                    .heartbeat_due(now, live.anchors.last_heartbeat, self.heartbeat)
        };
        let decimation = self.gates.scroll_decimation(
            live.motion_run,
            live.scroll_phase,
            self.shape.fps,
            measurement.measured,
            measurement.change_milli,
            obligated,
        );
        live.motion_run = decimation.motion_run;
        live.scroll_phase = decimation.phase;
        if !decimation.encode {
            drop(live);
            self.bump(|counters| {
                counters.scroll_decimated = counters.scroll_decimated.saturating_add(1);
            });
            return;
        }

        // STATIC-FRAME SUPPRESSION: a re-delivery that is pixel-identical to the last SUBMITTED
        // frame, with no obligation pending, is dropped here — before any PTS bookkeeping — so it
        // never re-encodes or re-sends. The cache and the decider clock above already ran, so the
        // static timer still re-anchors on a quiet window. The first frame is covered by
        // `last_submitted_hash` being `None` until something has actually been sent.
        if self.gates.static_suppress
            && let (Some(value), Some(last)) = (hash, live.last_submitted_hash)
        {
            let obligations = self.obligations(&live, now);
            if should_suppress_static_frame(value == last, obligations) {
                drop(live);
                self.bump(|counters| {
                    counters.duplicates_suppressed = counters.duplicates_suppressed.saturating_add(1);
                });
                return;
            }
        }

        // The PTS, clamped up to the high-water mark — the value ACTUALLY handed to the encoder,
        // not merely the tracker, because the live session encodes with frame reordering
        // off and a real frame must never reverse a prior synthetic IDR's timestamp.
        let ticks = monotonic_pts(
            live.last_pts_ticks,
            ticks_90k(presentation.value, presentation.timescale),
        );
        live.last_pts_ticks = ticks;
        let encode_pts = Timestamp {
            value: ticks,
            timescale: PTS_TIMESCALE,
        };

        // Any fresh delivery supersedes a pending one-shot flush: this frame either encodes now, or
        // is gated and re-arms a replacement below. So the flush only ever fires when the frame it
        // was armed for is still the newest content.
        live.gated_flush_due = None;

        // CLIENT-SILENCE PAUSE, exempting a pending recovery latch so a resume is clean.
        let latches = self.peek();
        if latches.client_silence_paused
            && live.anchors.has_emitted_first_frame
            && !(latches.keyframe || latches.ltr_refresh)
        {
            return;
        }

        // The FPS-governor cadence gate. It sits ABOVE the latch drain and PEEKS `forced`, so a
        // gated return is impossible while a recovery latch is pending or before the first frame —
        // recovery converts to the NEXT delivery, and deliveries stay at the full rate. A due
        // motion heartbeat sits BELOW the gate, so it can slip by at most one governed slot
        // on its multi-second cadence, which is acceptable.
        let governed = self.governed_fps();
        if governed < self.shape.fps {
            let must_encode =
                !live.anchors.has_emitted_first_frame || latches.keyframe || latches.ltr_refresh;
            let admitted = live.cadence.admit(
                now,
                1.0 / f64::from(governed),
                0.5 / f64::from(self.capture_hz),
                must_encode,
            );
            if !admitted {
                // Delivered but gated: if this turns out to be the LAST frame of the burst, the
                // one-shot ships its content at the next governed slot instead of leaving a stale
                // tail until the crisp refresh.
                live.gated_flush_due = Some(live.cadence.next_due().max(now));
                drop(live);
                self.wake_timer();
                return;
            }
        }

        let staged = live.pending_qp;
        // Record the hash of the frame about to be SUBMITTED, so the next capture is compared
        // against what was sent rather than against a frame that was gated and dropped.
        if self.gates.static_suppress {
            live.last_submitted_hash = hash;
        }
        drop(live);
        let plan = self.resolve_below_gate(now, governed, staged);
        self.hand_off_live(image, fresh.as_ref(), encode_pts, plan);
    }

    /// Wakes the timer thread, taking its stop mutex first so a wake between the thread's schedule
    /// computation and its wait cannot be lost.
    ///
    /// ⚠️ The caller must have released [`Inner::live`]: the timer takes `timer_stop` then `live`,
    /// and holding them the other way round here would be an inversion.
    fn wake_timer(&self) {
        drop(self.timer_stop.lock().unwrap_or_else(PoisonError::into_inner));
        self.timer_wake.notify_all();
    }

    /// The obligation set the two suppression rules ask about.
    ///
    /// PEEKED, never drained: a suppressed frame must not swallow a pending recovery, which drains
    /// on the next encoded frame exactly as the cadence gate's peek arranges. `ltr_refresh_due` is
    /// folded into `recovery_pending` — they are one latch here — and `self_heal_due` is always
    /// false, because self-heal is decided per-ENCODED frame below the gate and never up here.
    fn obligations(&self, live: &Live, now: f64) -> FrameObligations {
        let latches = self.peek();
        FrameObligations {
            is_first_frame: !live.anchors.has_emitted_first_frame,
            forced_keyframe_pending: latches.keyframe,
            recovery_pending: latches.ltr_refresh,
            heartbeat_due: self
                .gates
                .heartbeat_due(now, live.anchors.last_heartbeat, self.heartbeat),
            ltr_refresh_due: false,
            self_heal_due: false,
        }
    }

    /// The BELOW-GATE resolution, shared verbatim by the live delivery and the gated-tail flush.
    ///
    /// Both latches are DRAINED here, in this order, before anything else looks at them. The whole
    /// first-frame / heartbeat / recovery-cooldown / compact / LTR / self-heal / force-compact
    /// ladder is [`CaptureGates::resolve_encode`] — nine rungs, documented there. The anchors cross
    /// by value and come back advanced, so every counter is ASSIGNED from the answer rather than
    /// mutated in place.
    fn resolve_below_gate(&self, now: f64, governed: i32, staged_qp: Option<i32>) -> FramePlan {
        let (keyframe, ltr) = self.drain_recovery();
        let latches = self.peek();
        // The self-heal cadence is rebased TIME-equivalently at the governed rate, so the
        // wall-clock heal latency stays roughly constant: the rate is governed down exactly
        // when whole-frame loss is most likely and a recovery round trip is most expensive.
        let heal_every = self_heal_effective_every(
            i64::from(self.gates.self_heal_every),
            i64::from(self.shape.fps),
            i64::from(governed),
        );
        let mut live = self.lock_live();
        let resolution = self.gates.resolve_encode(live.anchors, EncodeFrame {
            now,
            heartbeat_interval: self.heartbeat,
            self_heal_loss_rate: latches.self_heal_loss_rate,
            heal_every: i32::try_from(heal_every).unwrap_or(i32::MAX),
            keyframe_latched: keyframe,
            ltr_latched: ltr,
            self_heal_eligible: latches.self_heal_eligible,
        });
        live.anchors = resolution.anchors;
        drop(live);
        FramePlan {
            force_keyframe: resolution.force_keyframe,
            crisp: false, // a live frame is NEVER crisp; only the static timer upgrades one
            compact: resolution.compact,
            ltr_refresh: resolution.ltr_refresh,
            per_frame_max_qp: staged_qp,
        }
    }

    /// The synthetic PTS: one 90 kHz tick past the last emitted one.
    ///
    /// A COUNTER, not a clock: the timer's re-encode of a cached frame has no capture timestamp of
    /// its own, and one tick past the high-water mark is strictly monotonic and collision-free with
    /// every real frame — which the live session requires, since it encodes with reordering off.
    fn next_synthetic_pts(&self) -> Timestamp {
        let mut live = self.lock_live();
        let ticks = synthetic_pts(live.last_pts_ticks);
        live.last_pts_ticks = ticks;
        drop(live);
        Timestamp {
            value: ticks,
            timescale: PTS_TIMESCALE,
        }
    }

    // -- the encode hand-off

    /// The LIVE hand-off: the framework's own surface when the encode happens here, the freshly
    /// cached bytes when it happens on the drain.
    ///
    /// The in-line case is zero-copy and keeps the framework's attachments; the decoupled case
    /// costs an `Arc` clone of bytes this frame had to read out anyway. `bytes` is `None` only
    /// when the plane read failed, and then the frame encodes in line rather than being lost —
    /// a frame the backlog cannot carry is still a frame the client should see.
    fn hand_off_live(
        &self,
        image: &CVImageBuffer,
        bytes: Option<&Arc<FrameBytes>>,
        presentation: Timestamp,
        plan: FramePlan,
    ) {
        if self.gates.encode_off_queue
            && let Some(bytes) = bytes
        {
            self.enqueue(Arc::clone(bytes), presentation, plan);
            return;
        }
        self.events.frame(image, presentation, plan);
    }

    /// The SYNTHETIC hand-off: the cache, for the static re-anchor and the gated-tail flush.
    ///
    /// The cache is an `Arc`, so this is a pointer clone and never a take-and-restore: nothing can
    /// be lost if a delivery lands in between, and nothing needs putting back.
    fn hand_off_cached(&self, presentation: Timestamp, plan: FramePlan) {
        let cached = self.lock_live().cached.clone();
        let Some(bytes) = cached else {
            return; // stopped, or nothing has ever been delivered
        };
        if self.gates.encode_off_queue {
            self.enqueue(bytes, presentation, plan);
            return;
        }
        let Some(rebuilt) = rebuild(&bytes, self.shape.full_range) else {
            return;
        };
        self.events.frame(rebuilt.image(), presentation, plan);
    }

    /// Puts one frame on the decoupled backlog, or drops it, as
    /// [`CaptureGates::backlog_decision`] says: drop-newest by default, freshest-wins under its own
    /// gate.
    fn enqueue(&self, bytes: Arc<FrameBytes>, presentation: Timestamp, plan: FramePlan) {
        let forced = plan.force_keyframe || plan.crisp || plan.compact || plan.ltr_refresh;
        let entry = Pending {
            bytes,
            presentation,
            plan,
            forced,
            pacer_anchor: plan.force_keyframe || plan.crisp,
        };
        let mut backlog = self.lock_backlog();
        if backlog.stopping {
            return;
        }
        let flags: Vec<bool> = backlog.pending.iter().map(|queued| queued.forced).collect();
        match self.gates.backlog_decision(&flags, forced) {
            BacklogDecision::Enqueue => {
                backlog.pending.push_back(entry);
                drop(backlog);
                self.backlog_ready.notify_one();
            },
            BacklogDecision::DropIncoming => {
                drop(backlog);
                self.bump(|counters| {
                    counters.backlog_dropped = counters.backlog_dropped.saturating_add(1);
                });
            },
            BacklogDecision::EvictOldestUnforced(index) => {
                // Coalesce the stalest pending delta out and admit the newest, WITHOUT waking the
                // drain: the count is unchanged, so the wake already outstanding consumes it. That
                // is the blocks-in-flight invariant the Swift kept by not scheduling a second
                // block.
                let _evicted = backlog.pending.remove(index);
                backlog.pending.push_back(entry);
                drop(backlog);
                self.bump(|counters| {
                    counters.backlog_dropped = counters.backlog_dropped.saturating_add(1);
                });
            },
        }
    }

    /// The decoupled encode drain: one frame at a time, in order, off the capture queue.
    ///
    /// The rebuild is OUTSIDE the measured window, because what the pacer is measuring is the
    /// ENCODE — the Swift timed its handler call and not the `copyPixelBuffer` that preceded it,
    /// and folding an allocation into the load average would make the pacer step the rate down
    /// for work the encoder never did.
    fn run_encoder(&self) {
        loop {
            let entry = {
                let mut backlog = self.lock_backlog();
                while backlog.pending.is_empty() && !backlog.stopping {
                    backlog = self
                        .backlog_ready
                        .wait(backlog)
                        .unwrap_or_else(PoisonError::into_inner);
                }
                if backlog.stopping {
                    return;
                }
                backlog.pending.pop_front()
            };
            let Some(entry) = entry else { continue };
            let Some(rebuilt) = rebuild(&entry.bytes, self.shape.full_range) else {
                continue;
            };
            let started = Instant::now();
            self.events.frame(rebuilt.image(), entry.presentation, entry.plan);
            let millis = started.elapsed().as_secs_f64() * 1000.0;
            self.note_encode_wall(millis, entry.pacer_anchor);
        }
    }

    /// Post-encode bookkeeping: the always-on stats EWMA, then the gated pacer fold.
    ///
    /// Past the per-frame budget the encode fills the backlog and forces the ragged drops above;
    /// the pacer folds the same measurement and steps the rate down cleanly instead.
    fn note_encode_wall(&self, millis: f64, pacer_anchor: bool) {
        let mut pacer = self.lock_pacer();
        pacer.encode_millis_ewma = fold_encode_ewma(
            pacer.encode_millis_ewma,
            millis,
            EncodeLoadPacerConfig::default().alpha,
        );
        pacer.wall_samples = pacer.wall_samples.wrapping_add(1);
        let average = pacer.encode_millis_ewma;
        let samples = pacer.wall_samples;
        let step = if self.gates.encode_pacer {
            let before = pacer.paced_fps;
            let governed = pacer.pacer.note(millis, pacer_anchor);
            pacer.paced_fps = i32::try_from(governed).unwrap_or(self.shape.fps);
            (pacer.paced_fps != before).then_some((before, pacer.paced_fps))
        } else {
            None
        };
        drop(pacer);
        if !self.gates.debug_gaps {
            return;
        }
        // Every three hundred frames under the debug switch, the average itself — the number the
        // pacer's threshold is read against, so a run can see how close to the budget it sat.
        if samples.is_multiple_of(300) {
            crate::diag::say(&format!(
                "encode wall avg {average:.1} ms/frame (budget {:.1} ms at {} fps)",
                budget_millis(i64::from(self.shape.fps)),
                self.shape.fps
            ));
        }
        // A step is a cadence change the client sees; under the debug switch it is also a line a
        // cadence run can count against the send gaps it caused.
        if let Some((before, after)) = step {
            crate::diag::say(&format!(
                "encode-load pacer: {before} → {after} fps (encode {average:.1} ms/frame avg, budget {:.1} \
                 ms)",
                budget_millis(i64::from(self.shape.fps))
            ));
        }
    }

    // -- capture death

    /// The stream died: the shared window closed, the display was unplugged, the grant was revoked,
    /// the window server reset.
    ///
    /// Reporting alone is not enough — the timer would keep re-encoding the stale cache as periodic
    /// heartbeat and crisp IDRs, so the client would "decode video" (a frozen frame) with no error
    /// and its stall scrim would never engage. So the cache is dropped and the flush disarmed,
    /// which is what quiesces the synthetic path for good.
    ///
    /// The callback arrives on the framework's own private queue, so this hops onto the frame queue
    /// ASYNCHRONOUSLY — never blocking that queue — where the timer, the cache and the flush all
    /// live. The hop is also what serialises this against [`Capturer::stop`]'s teardown: whichever
    /// side runs first wins, and the other no-ops through the two one-shot latches.
    ///
    /// The dead stream handle is deliberately NOT freed here. It belongs to the start/stop/resize
    /// paths, and a callback-queue write would race them; the session tears down through its
    /// ordinary bye path instead, and stopping an already-dead stream just answers a framework
    /// error, which is nothing to act on.
    fn handle_capture_failure(handle: &Arc<Self>) {
        let inner = Arc::clone(handle);
        handle.frame_queue.exec_async(move || {
            {
                let mut live = inner.lock_live();
                if live.capture_failed || live.capture_stopped {
                    return; // once only, and a deliberate stop wins
                }
                live.capture_failed = true;
                live.gated_flush_due = None;
                live.cached = None;
            }
            inner.events.capture_failed();
        });
    }

    // -- the measurements

    /// Measures this frame against the previous one: the scroll shift and the change magnitude.
    ///
    /// The previous frame comes from the cache as plain memory and the current one from the surface
    /// already locked by the caller, which is why this takes a `Locked` rather than a buffer: one
    /// bracket per delivery, not one per measurement.
    ///
    /// A size mismatch or a missing luma plane answers [`Measurement::NONE`], whose `measured` flag
    /// is false — which is what keeps the rules' degenerate-frame fallback (also change 0) from
    /// ever being mistaken for a genuinely idle frame.
    fn measure(&self, previous: &FrameBytes, current: &Locked<'_>) -> Measurement {
        let Some(current_y) = current.plane_view(LUMA_PLANE) else {
            return Measurement::NONE;
        };
        let width = current_y.width;
        let height = current_y.height;
        if width == 0 || height == 0 || previous.width != width || previous.height != height {
            return Measurement::NONE;
        }
        let before = LumaPlane {
            bytes: &previous.luma,
            stride: previous.luma_stride,
        };
        let after = LumaPlane {
            bytes: current_y.bytes,
            stride: current_y.stride,
        };
        let scroll = if self.gates.scroll_reproject {
            let max_shift = height.div_euclid(SCROLL_SEARCH_DIVISOR).max(SCROLL_SEARCH_FLOOR);
            let estimate = estimate_nv12(
                before,
                after,
                width,
                height,
                max_shift,
                self.gates.scroll_quantize_shift,
            );
            let (top, bottom) = estimate.band.unwrap_or((0, 0));
            ScrollHint::measured(
                estimate.shift,
                confidence_milli(estimate.confidence),
                i32::try_from(top).unwrap_or(i32::MAX),
                i32::try_from(bottom).unwrap_or(i32::MAX),
                height,
            )
        } else {
            ScrollHint::NONE
        };
        if !(self.gates.adaptive_qp || self.gates.idle_skip) {
            return Measurement {
                measured: false,
                raw_qp: 0,
                change_milli: 0,
                scroll,
            };
        }
        let decision = compute_nv12(before, after, width, height, QpCurve {
            qp_sharp: u8::try_from(self.gates.adaptive_qp_sharp).unwrap_or(u8::MAX),
            qp_max: u8::try_from(self.gates.adaptive_qp_max).unwrap_or(u8::MAX),
            b_lo_milli: self.gates.adaptive_qp_band_lo_milli,
            b_hi_milli: self.gates.adaptive_qp_band_hi_milli,
        });
        Measurement {
            measured: true,
            raw_qp: i32::from(decision.qp),
            change_milli: decision.change_milli,
            scroll,
        }
    }
}

/// What one measurement pass answered.
///
/// `measured` is true only on a REAL measurement: it is what separates a frame with zero changed
/// rows from a frame whose change could not be measured at all, and the two must never be confused
/// — one is idle and the other is unknown.
#[derive(Debug, Clone, Copy)]
struct Measurement {
    measured: bool,
    raw_qp: i32,
    change_milli: u32,
    scroll: ScrollHint,
}

impl Measurement {
    /// Nothing was measured: no previous frame, a size mismatch, or a lock that failed.
    const NONE: Self = Self {
        measured: false,
        raw_qp: 0,
        change_milli: 0,
        scroll: ScrollHint::NONE,
    };
}

// ---------------------------------------------------------------------------- //
// The two doors onto framework memory
//
// Every call this module makes into `slopdesk-apple-vt`'s plane views lives in one of these two
// functions, plus the hash below. That is on purpose: they are the only places a change to those
// signatures can reach.

/// Reads one locked NV12 surface into memory this process owns.
///
/// The ONE thing that must happen on the delivery queue, and the reason [`FrameBytes`] exists. Rows
/// are copied at their source stride — padding and all — so the read is one `to_vec` per plane and
/// the result reads back with the same `(bytes, stride)` shape a locked plane has.
///
/// `None` when the buffer has no luma plane, which is a surface that describes no picture.
fn read_frame(locked: &Locked<'_>) -> Option<FrameBytes> {
    let luma = locked.plane_view(LUMA_PLANE)?;
    let chroma = locked.plane_view(CHROMA_PLANE);
    Some(FrameBytes {
        width: luma.width,
        height: luma.height,
        luma: luma.bytes.to_vec(),
        luma_stride: luma.stride,
        chroma: chroma.as_ref().map(|plane| plane.bytes.to_vec()),
        chroma_stride: chroma.as_ref().map_or(0, |plane| plane.stride),
    })
}

/// Builds a fresh IOSurface-backed `CVPixelBuffer` from cached bytes.
///
/// The result is a LOCAL of whichever consumer asked for it — the static re-anchor on the frame
/// queue, or the decoupled drain on its own thread — and is dropped as soon as the encoder has
/// finished with it. It is IOSurface-backed, so the re-encode stays zero-copy into `VideoToolbox`
/// exactly as the live path is, and it carries no colour attachments, which is safe for the reason
/// the module note gives: the encoder session pins the three colour properties itself.
///
/// `None` on an allocation or lock failure, which is safe everywhere it is called: the caller
/// simply ships nothing this tick, and the next one has the same cache to try again with.
fn rebuild(frame: &FrameBytes, full_range: bool) -> Option<PixelBuffer> {
    let target = PixelBuffer::nv12(frame.width, frame.height, full_range).ok()?;
    {
        let mut locked = target.lock()?;
        if let Some(mut luma) = locked.plane_mut(LUMA_PLANE) {
            copy_rows(&frame.luma, frame.luma_stride, &mut luma);
        }
        if let Some(chroma) = frame.chroma.as_ref()
            && let Some(mut plane) = locked.plane_mut(CHROMA_PLANE)
        {
            copy_rows(chroma, frame.chroma_stride, &mut plane);
        }
    }
    Some(target)
}

/// The full NV12 hash of one locked surface: luma and, when the buffer has it, interleaved chroma.
///
/// The visible width and height come from the PLANE, not the buffer, so a padded plane still hashes
/// only its picture. `None` when the luma plane is unavailable, and [`SENTINEL`] when the geometry
/// cannot describe a plane at all — callers filter both, because a hash nobody could compute must
/// never compare equal to one that was.
fn hash_locked(locked: &Locked<'_>) -> Option<u64> {
    let luma = locked.plane_view(LUMA_PLANE)?;
    let chroma = locked.plane_view(CHROMA_PLANE);
    Some(hash_nv12(
        luma.bytes,
        luma.stride,
        luma.width,
        luma.height,
        chroma.as_ref().map(|plane| plane.bytes),
        chroma.as_ref().map_or(0, |plane| plane.stride),
    ))
}

/// Writes rows of `source` into `into`, honouring a stride mismatch.
///
/// The span is the SMALLER of the two strides, not the visible width: for NV12's interleaved chroma
/// plane the visible width is in chroma samples while the row is in bytes, so copying the width
/// would copy half of every row. The bounds come from the slices themselves, so a geometry that
/// does not agree with its mapping writes less rather than past the end of either.
fn copy_rows(source: &[u8], source_stride: usize, into: &mut PlaneBytes<'_>) {
    let span = source_stride.min(into.stride);
    if span == 0 {
        return;
    }
    let available = source.len().checked_div(source_stride).unwrap_or(0);
    let rows: usize = into.height.min(available);
    for row in 0..rows {
        let (Some(from_start), Some(to_start)) =
            (row.checked_mul(source_stride), row.checked_mul(into.stride))
        else {
            return;
        };
        let (Some(from_end), Some(to_end)) = (from_start.checked_add(span), to_start.checked_add(span))
        else {
            return;
        };
        let Some(read) = source.get(from_start..from_end) else {
            return;
        };
        let Some(write) = into.bytes.get_mut(to_start..to_end) else {
            return;
        };
        write.copy_from_slice(read);
    }
}

/// A framework presentation timestamp as 90 kHz ticks.
///
/// The only Core Media arithmetic in this module, and it takes the two SCALARS rather than the
/// `CMTime` so it can be tested without the framework's opaque flags type — which this crate cannot
/// name, because it reaches Core Media only through `slopdesk-apple-sck`. Rounded to the nearest
/// tick rather than truncated, which is `CMTimeConvertScale`'s own default, and computed in `i128`
/// so a nanosecond-scale numerator times ninety thousand cannot overflow before the division brings
/// it back. A non-positive timescale describes no time and answers zero, which the high-water clamp
/// then leaves alone.
#[expect(
    clippy::integer_division,
    reason = "a rational's conversion IS a division, and the half-denominator bias above it is what makes \
              the truncation a round-to-nearest"
)]
fn ticks_90k(value: i64, timescale: i32) -> i64 {
    if timescale <= 0 {
        return 0;
    }
    let denominator = i128::from(timescale);
    let numerator = i128::from(value) * i128::from(PTS_TIMESCALE);
    let half = denominator / 2;
    let rounded = if numerator >= 0 {
        numerator + half
    } else {
        numerator - half
    };
    i64::try_from(rounded / denominator).unwrap_or(i64::MAX)
}

/// A `0.0..=1.0` confidence as the thousandths [`ScrollHint::measured`] takes.
fn confidence_milli(confidence: f64) -> u32 {
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is clamped into 0..=1000 before the cast, where every f64 is exact"
    )]
    let milli = (confidence * 1000.0).clamp(0.0, 1000.0) as u32;
    milli
}

/// How this daemon reads a knob: the real environment FIRST, then the settings overlay.
///
/// `docs/58`'s precedence, and the same closure [`crate::encode`] passes the encoder, for the same
/// reason: Swift folded `video-prefs.json` into the process environment with `setenv` before launch
/// and a Rust daemon cannot, because `std::env::set_var` is `unsafe` and this crate forbids it.
/// Composing the two lookups is that precedence with none of the mutation.
fn reader(overlay: &Overlay) -> impl Fn(&str) -> Option<String> + '_ {
    |key| std::env::var(key).ok().or_else(|| overlay.get(key))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a failed expectation in a test IS the failure report, and each message names what the \
                  framework or the geometry refused"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "a test fills a plane it has just allocated; an out-of-bounds index there is the failure \
                  the test exists to catch"
    )]

    use slopdesk_apple_vt::PixelBuffer;
    use slopdesk_video::frame_hash::SENTINEL;
    use slopdesk_video::geometry::VideoPoint;

    use super::{
        AnchorDrive, PTS_TIMESCALE, Shape, confidence_milli, hash_locked, read_frame, rebuild, ticks_90k,
    };

    /// Nanoseconds, which is the timescale `ScreenCaptureKit` stamps a frame in.
    const NANOS: i32 = 1_000_000_000;

    /// A real NV12 buffer with a reproducible pattern in its luma plane.
    ///
    /// `CVPixelBufferCreate` needs no window server and no Screen-Recording grant, so every test
    /// below runs against the framework's own memory — which is the half of this module the Swift
    /// original could not reach from a test at all.
    fn patterned(width: usize, height: usize) -> PixelBuffer {
        let buffer = PixelBuffer::nv12(width, height, false).expect("an NV12 buffer");
        {
            let mut locked = buffer.lock().expect("the buffer locks for writing");
            let luma = locked.plane_mut(0).expect("it has a luma plane");
            let stride = luma.stride;
            for row in 0..luma.height {
                for column in 0..luma.width {
                    luma.bytes[row * stride + column] =
                        u8::try_from((row * 7 + column * 3) % 251).unwrap_or(0);
                }
            }
        }
        buffer
    }

    #[test]
    fn a_nanosecond_timestamp_becomes_the_nearest_ninety_kilohertz_tick() {
        assert_eq!(ticks_90k(0, NANOS), 0);
        assert_eq!(ticks_90k(1_000_000_000, NANOS), i64::from(PTS_TIMESCALE));
        // One 60 Hz slot is 1/60 s, which is 1500 ticks exactly.
        assert_eq!(ticks_90k(16_666_666, NANOS), 1500);
    }

    #[test]
    fn an_undescribed_timescale_is_zero_rather_than_a_division() {
        assert_eq!(
            ticks_90k(12_345, 0),
            0,
            "a zero timescale describes no time at all"
        );
        assert_eq!(ticks_90k(12_345, -30), 0, "and neither does a negative one");
    }

    #[test]
    fn a_confidence_lands_in_thousandths_and_cannot_leave_the_band() {
        assert_eq!(confidence_milli(0.0), 0);
        assert_eq!(confidence_milli(1.0), 1000);
        assert_eq!(confidence_milli(0.5), 500);
        assert_eq!(confidence_milli(-3.0), 0, "a negative confidence is none");
        assert_eq!(confidence_milli(9.0), 1000, "and one is the ceiling");
    }

    #[test]
    fn a_real_buffer_hashes_to_something_other_than_the_sentinel() {
        let buffer = patterned(32, 16);
        let locked = buffer.lock_read_only().expect("the buffer locks");
        let hash = hash_locked(&locked).expect("a describable geometry hashes");
        assert_ne!(
            hash, SENTINEL,
            "a real buffer's geometry IS describable, so the sentinel would be a bug"
        );
    }

    #[test]
    fn a_frame_read_out_keeps_its_geometry_and_all_of_its_rows() {
        let buffer = patterned(64, 32);
        let locked = buffer.lock_read_only().expect("the buffer locks");
        let luma = locked.plane_view(0).expect("a luma plane");
        let frame = read_frame(&locked).expect("a describable buffer reads out");
        assert_eq!(frame.width, luma.width);
        assert_eq!(frame.height, luma.height);
        assert_eq!(frame.luma_stride, luma.stride);
        assert_eq!(
            frame.luma.len(),
            luma.bytes.len(),
            "the read keeps the mapping whole, padding included"
        );
        assert_eq!(frame.luma, luma.bytes, "and byte for byte");
    }

    #[test]
    fn a_rebuild_of_a_read_out_frame_hashes_the_same_as_what_it_came_from() {
        // This is the round trip the whole cache design rests on: the surface the framework lent
        // becomes bytes, the bytes become a buffer the encoder can take, and the picture is the
        // same one at both ends.
        let source = patterned(48, 24);
        let (frame, before) = {
            let locked = source.lock_read_only().expect("the source locks");
            (
                read_frame(&locked).expect("the source reads out"),
                hash_locked(&locked).expect("the source hashes"),
            )
        };
        let rebuilt = rebuild(&frame, false).expect("the rebuild allocates and locks");
        let locked = rebuilt.lock_read_only().expect("the rebuild locks");
        let after = hash_locked(&locked).expect("the rebuild hashes");
        assert_eq!(before, after, "a round trip that changes the picture is not one");
    }

    #[test]
    fn the_anchor_gate_admits_one_driver_and_keeps_only_the_latest_origin() {
        // The first caller finds the gate free and claims it.
        let mut drive = AnchorDrive {
            pending: Some(VideoPoint::new(10.0, 20.0)),
            ..AnchorDrive::default()
        };
        assert!(!drive.in_flight, "nobody has claimed it yet");
        drive.in_flight = true;
        // A second caller, mid-drive, leaves a NEWER origin and does not drive.
        drive.pending = Some(VideoPoint::new(30.0, 40.0));
        assert!(drive.in_flight, "the claim is still the first caller's");
        assert_eq!(
            drive.pending,
            Some(VideoPoint::new(30.0, 40.0)),
            "latest wins: the position the window has already left is dropped"
        );
        // The driver drains, and an empty gate releases.
        assert_eq!(drive.pending.take(), Some(VideoPoint::new(30.0, 40.0)));
        if drive.pending.is_none() {
            drive.in_flight = false;
        }
        assert!(!drive.in_flight, "an empty gate is released");
    }

    #[test]
    fn a_shape_defaults_to_the_daemons_own_arguments() {
        let shape = Shape::default();
        assert_eq!(shape.fps, 60, "the announced rate a 60 Hz source produces");
        assert!(
            (shape.capture_scale - 1.0).abs() < f64::EPSILON,
            "unscaled by default"
        );
        assert!(!shape.full_range, "video range, not full");
        assert!(
            !shape.prefer_display_anchored,
            "the bare capture check keeps the per-window path; the session opts in"
        );
        assert_eq!(shape.audio_sample_rate, 0, "audio is the caller's to supply");
    }
}
