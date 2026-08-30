//! Watching one tracked window move, resize and grow a dialog, at 30 Hz, while AX says nothing.
//!
//! The accessibility notifications for a move or a resize fire at the END of the gesture, which is
//! exactly when the client no longer needs them. Everything in between comes from here: a poll of
//! `CGWindowListCopyWindowInfo` per video frame, diffed against the last one.
//!
//! ## The two things it emits, and why they are separate
//! A [`GeometryChange`] is the tracked window's own frame, and it goes out on every poll the frame
//! differs — coalesced into ONE message when both halves moved, because a client that received a
//! move and a resize for the same frame would map one input event against each.
//!
//! A REGION is the capture crop: the window ∪ any same-pid panel in front of it, which is what a
//! file-open dialog is. That is a discrete event — a dialog opens or it does not — so it is sampled
//! every [`UNION_POLL_DIVIDER`]th poll rather than every one, and it is only sampled at all when a
//! caller armed it. Un-armed costs exactly one branch per poll.
//!
//! ## This module decides nothing
//! The union, the individual content rects and the hysteresis are
//! [`slopdesk_video::capture_region`], golden-pinned. The display under a point is
//! `slopdesk-apple-cgdisplay`. What is here is the CADENCE, the diff against the previous poll, and
//! the every-fifth counter — and all three are testable, which is why [`Poller`] is a value with no
//! thread in it and [`GeometryWatcher`] is the thread that turns a crank.
//!
//! ## What it replaces
//! `WindowGeometryWatcher.swift`'s poller and `HostDisplays`. The file's `resizeWindow` half is
//! [`crate::windowplace::resize`], its own module because a resize is an EFFECT on a window and
//! this one only ever reads.

use core::fmt;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_video::capture_region::{self, DEFAULT_MIN_DELTA, DEFAULT_MIN_OVERLAP_FRACTION, WindowSnapshot};
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

/// Polls per second during a drag — one per video frame at the 30 fps floor.
pub const DRAG_POLL_HZ: f64 = 30.0;

/// Sample the region every this-many polls, so ~6 Hz at the drag cadence.
///
/// A dialog opening is a discrete event and the enumeration behind it walks every on-screen window,
/// so paying for it 30 times a second would be the poller's whole cost for an answer that changes
/// twice a session.
pub const UNION_POLL_DIVIDER: u32 = 5;

/// What changed about the tracked window's frame since the previous poll.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GeometryChange {
    /// Both halves moved, or this is the first poll — one message, never two.
    Bounds(VideoRect),
    /// The window moved without changing size.
    Move(VideoPoint),
    /// The window changed size without moving.
    Resize(VideoSize),
}

/// The two window-server reads a poll makes.
pub trait ReadsGeometry: Send + Sync + fmt::Debug {
    /// The window's frame in CG global points, or `None` when the window is gone.
    fn bounds(&self, window_id: u32) -> Option<VideoRect>;
    /// Every on-screen window strictly in front of `window_id`, front-to-back.
    fn windows_in_front_of(&self, window_id: u32) -> Vec<WindowSnapshot>;
    /// The bounds of the display holding `point`, or `None` when it is off every display.
    fn display_under(&self, point: VideoPoint) -> Option<VideoRect>;
}

/// Where a poll's findings go.
pub trait SendsGeometry: Send + Sync + fmt::Debug {
    /// The tracked window's frame changed: WHAT changed, and the whole frame it changed to.
    ///
    /// Both, because the two answer different questions and only one of them is on the wire. The
    /// [`GeometryChange`] is what the client is told — a move alone, so it does not re-map input
    /// against a size that did not move — while `frame` is what the HOST re-origins its own
    /// coordinate mapping and its display-anchored crop against, and neither of those can act on
    /// half a rectangle. Passing it costs nothing: the poll has just read it, and a consumer that
    /// asked the window server again would be paying a second round trip 30 times a second for the
    /// number it was handed.
    fn geometry(&self, change: GeometryChange, frame: VideoRect);
    /// The capture region changed past the hysteresis: the bounding union, and the individual
    /// opaque rects inside it the client masks the flank between.
    fn region(&self, union: VideoRect, contents: &[VideoRect]);
}

/// A shared reader is a reader — so one window server can serve the watcher and its owner at once
/// without either of them owning it.
impl<T: ReadsGeometry + ?Sized> ReadsGeometry for Arc<T> {
    fn bounds(&self, window_id: u32) -> Option<VideoRect> {
        (**self).bounds(window_id)
    }
    fn windows_in_front_of(&self, window_id: u32) -> Vec<WindowSnapshot> {
        (**self).windows_in_front_of(window_id)
    }
    fn display_under(&self, point: VideoPoint) -> Option<VideoRect> {
        (**self).display_under(point)
    }
}

/// The same, for the sink: the session holds the channel and lends the watcher a handle on it.
impl<T: SendsGeometry + ?Sized> SendsGeometry for Arc<T> {
    fn geometry(&self, change: GeometryChange, frame: VideoRect) {
        (**self).geometry(change, frame);
    }
    fn region(&self, union: VideoRect, contents: &[VideoRect]) {
        (**self).region(union, contents);
    }
}

/// The real window server.
#[derive(Clone, Copy, Debug, Default)]
pub struct HostGeometry;

impl ReadsGeometry for HostGeometry {
    fn bounds(&self, window_id: u32) -> Option<VideoRect> {
        slopdesk_apple_cgwindow::bounds_of(window_id, None)
    }

    fn windows_in_front_of(&self, window_id: u32) -> Vec<WindowSnapshot> {
        slopdesk_apple_cgwindow::windows_in_front_of(window_id)
            .into_iter()
            .map(|record| {
                WindowSnapshot {
                    window_id: record.window_id,
                    owner_pid: record.owner_pid,
                    layer: record.layer,
                    frame: record.bounds,
                }
            })
            .collect()
    }

    fn display_under(&self, point: VideoPoint) -> Option<VideoRect> {
        slopdesk_apple_cgdisplay::under(point).map(|display| display.bounds)
    }
}

/// The poll's whole memory: the previous frame, the previous region, and the region counter.
///
/// A value with no thread and no clock in it, so every case below — first poll, window gone, moved
/// but not resized, a region change under the hysteresis — is a unit test rather than a claim.
#[derive(Clone, Copy, Debug, Default)]
pub struct Poller {
    last_bounds: Option<VideoRect>,
    last_region: Option<VideoRect>,
    ticks: u32,
    armed: bool,
}

impl Poller {
    /// A poller for a window nobody has looked at yet, with the region sampling DISARMED.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_bounds: None,
            last_region: None,
            ticks: 0,
            armed: false,
        }
    }

    /// Arms or disarms the region sampling.
    ///
    /// Disarmed is not "sample and discard": the enumeration never runs, which is the point of the
    /// flag. Re-arming forgets the previous region, so the first sample after it always publishes.
    pub const fn arm_region(&mut self, armed: bool) {
        self.armed = armed;
        if !armed {
            self.last_region = None;
            self.ticks = 0;
        }
    }

    /// Whether the region sampling is armed.
    #[must_use]
    pub const fn region_armed(&self) -> bool {
        self.armed
    }

    /// One poll: read the frame, diff it, publish what changed, and every fifth time also sample
    /// the region.
    ///
    /// A window that cannot be read leaves EVERY piece of state untouched, including the counter —
    /// a transient read failure mid-drag must not be seen as "unchanged" on the next poll, and
    /// must not shift the region cadence either.
    pub fn poll_once<R: ReadsGeometry + ?Sized, S: SendsGeometry + ?Sized>(
        &mut self,
        reader: &R,
        sink: &S,
        window_id: u32,
        pid: i32,
    ) {
        let Some(bounds) = reader.bounds(window_id) else {
            return;
        };
        let previous = self.last_bounds.replace(bounds);
        match previous {
            None => sink.geometry(GeometryChange::Bounds(bounds), bounds),
            Some(previous) => {
                let moved = bounds.origin != previous.origin;
                let resized = bounds.size != previous.size;
                match (moved, resized) {
                    (true, true) => sink.geometry(GeometryChange::Bounds(bounds), bounds),
                    (true, false) => sink.geometry(GeometryChange::Move(bounds.origin), bounds),
                    (false, true) => sink.geometry(GeometryChange::Resize(bounds.size), bounds),
                    (false, false) => {},
                }
            },
        }
        if !self.armed {
            return;
        }
        self.ticks = self.ticks.wrapping_add(1);
        if self.ticks.is_multiple_of(UNION_POLL_DIVIDER) {
            self.sample_region(reader, sink, bounds, window_id, pid);
        }
    }

    /// Asks `capture_region` what the crop should be, and publishes it when it moved far enough.
    ///
    /// The baseline for the hysteresis is the last region PUBLISHED, or — before there is one — the
    /// window's own frame, so a session that opens with no dialog publishes nothing at all rather
    /// than publishing the window frame it is already capturing.
    fn sample_region<R: ReadsGeometry + ?Sized, S: SendsGeometry + ?Sized>(
        &mut self,
        reader: &R,
        sink: &S,
        bounds: VideoRect,
        window_id: u32,
        pid: i32,
    ) {
        let centre = VideoPoint::new(bounds.mid_x(), bounds.mid_y());
        let Some(display) = reader.display_under(centre) else {
            return;
        };
        let in_front = reader.windows_in_front_of(window_id);
        let union = capture_region::union_region(
            bounds,
            window_id,
            pid,
            &in_front,
            display,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        let baseline = self.last_region.unwrap_or(bounds);
        if !capture_region::should_retarget(baseline, union, DEFAULT_MIN_DELTA) {
            return;
        }
        self.last_region = Some(union);
        let contents = capture_region::content_rects(
            bounds,
            window_id,
            pid,
            &in_front,
            display,
            DEFAULT_MIN_OVERLAP_FRACTION,
        );
        sink.region(union, &contents);
    }
}

/// What the watcher's thread is waiting on.
#[derive(Debug)]
struct Lane {
    poller: Poller,
    stop: bool,
}

/// The state the watcher's thread and its owner share.
#[derive(Debug)]
struct Shared<R, S> {
    reader: R,
    sink: S,
    window_id: u32,
    pid: i32,
    lane: Mutex<Lane>,
    wake: Condvar,
}

/// A 30 Hz poller on its own thread, for one window, for as long as it is held.
///
/// Deliberately a real thread rather than a task: this repo's daemons own their threads, and a
/// fixed-cadence loop that spends its life in `wait_timeout` is the shape an executor buys nothing
/// for. The thread ends on `Drop`, which JOINS it — a poll racing the teardown of the socket it
/// publishes to is the one failure this shape rules out entirely.
#[derive(Debug)]
pub struct GeometryWatcher<R: ReadsGeometry + 'static, S: SendsGeometry + 'static> {
    shared: Arc<Shared<R, S>>,
    thread: Option<JoinHandle<()>>,
}

impl<R: ReadsGeometry + 'static, S: SendsGeometry + 'static> GeometryWatcher<R, S> {
    /// Starts polling `window_id` immediately, with the region sampling disarmed.
    #[must_use]
    pub fn start(reader: R, sink: S, window_id: u32, pid: i32) -> Self {
        let shared = Arc::new(Shared {
            reader,
            sink,
            window_id,
            pid,
            lane: Mutex::new(Lane {
                poller: Poller::new(),
                stop: false,
            }),
            wake: Condvar::new(),
        });
        let thread = {
            let shared = Arc::clone(&shared);
            thread::Builder::new()
                .name("slopdesk-geometry".to_owned())
                .spawn(move || run(&shared))
                .ok()
        };
        Self { shared, thread }
    }

    /// Arms or disarms the DIALOG-EXPAND region sampling. Takes effect on the next poll.
    pub fn arm_region(&self, armed: bool) {
        self.shared
            .lane
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .poller
            .arm_region(armed);
    }

    /// Whether the region sampling is armed.
    #[must_use]
    pub fn region_armed(&self) -> bool {
        self.shared
            .lane
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .poller
            .region_armed()
    }

    /// Ends the polling thread and waits for it. Idempotent, and `Drop` calls it.
    pub fn stop(&mut self) {
        self.shared
            .lane
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .stop = true;
        self.shared.wake.notify_all();
        if let Some(thread) = self.thread.take() {
            drop(thread.join());
        }
    }
}

impl<R: ReadsGeometry + 'static, S: SendsGeometry + 'static> Drop for GeometryWatcher<R, S> {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The cadence: poll, then wait one interval or until told to stop.
///
/// The poller is taken OUT of the lock for the poll itself and written back after. The read behind
/// it goes to the window server and can block, and holding the lane across it would make
/// [`GeometryWatcher::arm_region`] — which a caller invokes from the session thread — wait on the
/// window server.
#[expect(
    clippy::significant_drop_tightening,
    reason = "the guard IS the condvar's argument — narrowing it would mean waiting without it"
)]
fn run<R: ReadsGeometry, S: SendsGeometry>(shared: &Arc<Shared<R, S>>) {
    // A reciprocal, computed once: the cadence is a constant and the division is not the loop's.
    let interval = Duration::from_secs_f64(1.0 / DRAG_POLL_HZ);
    loop {
        let mut poller = {
            let lane = shared.lane.lock().unwrap_or_else(PoisonError::into_inner);
            if lane.stop {
                return;
            }
            lane.poller
        };
        poller.poll_once(&shared.reader, &shared.sink, shared.window_id, shared.pid);
        let mut lane = shared.lane.lock().unwrap_or_else(PoisonError::into_inner);
        if lane.stop {
            return;
        }
        // The ARMING is the caller's and may have changed under the poll; everything else is the
        // poll's own. Writing the whole poller back would undo an `arm_region` that landed
        // mid-poll, and a disarm that does not take is a dialog enumeration nobody asked for.
        let armed = lane.poller.armed;
        lane.poller = poller;
        lane.poller.arm_region(armed);
        let (lane, _) = shared
            .wake
            .wait_timeout(lane, interval)
            .unwrap_or_else(PoisonError::into_inner);
        if lane.stop {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::time::{Duration, Instant};

    use slopdesk_video::capture_region::WindowSnapshot;
    use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

    use super::{GeometryChange, GeometryWatcher, Poller, ReadsGeometry, SendsGeometry, UNION_POLL_DIVIDER};

    /// A window server that answers a scripted sequence of frames and one fixed occluder set.
    #[derive(Debug, Default)]
    struct Desk {
        frames: Mutex<Vec<Option<VideoRect>>>,
        /// The frame handed out once the script runs out — `None` re-uses the last one.
        held: Mutex<Option<VideoRect>>,
        in_front: Mutex<Vec<WindowSnapshot>>,
        display: Option<VideoRect>,
        reads: AtomicU32,
        enumerations: AtomicU32,
    }

    impl Desk {
        fn scripted(frames: Vec<Option<VideoRect>>) -> Self {
            Self {
                frames: Mutex::new(frames.into_iter().rev().collect()),
                display: Some(VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0)),
                ..Self::default()
            }
        }
    }

    impl ReadsGeometry for Desk {
        fn bounds(&self, _window_id: u32) -> Option<VideoRect> {
            self.reads.fetch_add(1, Ordering::Relaxed);
            let next = self.frames.lock().unwrap_or_else(PoisonError::into_inner).pop();
            next.map_or_else(
                || *self.held.lock().unwrap_or_else(PoisonError::into_inner),
                |frame| {
                    *self.held.lock().unwrap_or_else(PoisonError::into_inner) = frame;
                    frame
                },
            )
        }
        fn windows_in_front_of(&self, _window_id: u32) -> Vec<WindowSnapshot> {
            self.enumerations.fetch_add(1, Ordering::Relaxed);
            self.in_front
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
        fn display_under(&self, _point: VideoPoint) -> Option<VideoRect> {
            self.display
        }
    }

    /// Everything published, in order.
    #[derive(Debug, Default)]
    struct Log {
        changes: Mutex<Vec<GeometryChange>>,
        frames: Mutex<Vec<VideoRect>>,
        regions: Mutex<Vec<(VideoRect, Vec<VideoRect>)>>,
    }

    impl Log {
        fn changes(&self) -> Vec<GeometryChange> {
            self.changes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
        fn regions(&self) -> Vec<(VideoRect, Vec<VideoRect>)> {
            self.regions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
        fn frames(&self) -> Vec<VideoRect> {
            self.frames.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl SendsGeometry for Log {
        fn geometry(&self, change: GeometryChange, frame: VideoRect) {
            self.changes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(change);
            self.frames
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(frame);
        }
        fn region(&self, union: VideoRect, contents: &[VideoRect]) {
            self.regions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((union, contents.to_vec()));
        }
    }

    const WINDOW: VideoRect = VideoRect::xywh(100.0, 100.0, 800.0, 600.0);

    /// Waits for `ready`, with a ceiling. A condition with a deadline, never a fixed sleep — a
    /// sleep long enough to be reliable is a second of suite time, and a short one is a flake.
    fn until(ready: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if ready() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        ready()
    }

    /// The first poll always publishes, and publishes the WHOLE frame: the client has no prior
    /// geometry, so a `Move` alone would leave it sizing against nothing.
    #[test]
    fn the_first_poll_publishes_the_whole_frame() {
        let desk = Desk::scripted(vec![Some(WINDOW)]);
        let log = Log::default();
        Poller::new().poll_once(&desk, &log, 7, 42);
        assert_eq!(log.changes(), vec![GeometryChange::Bounds(WINDOW)]);
    }

    /// A frame that did not change publishes NOTHING. The poller runs 30 times a second and a
    /// window is still almost all of that time; a message per poll would be the channel's whole
    /// traffic.
    #[test]
    fn an_unchanged_frame_publishes_nothing_at_all() {
        let desk = Desk::scripted(vec![Some(WINDOW), Some(WINDOW), Some(WINDOW)]);
        let log = Log::default();
        let mut poller = Poller::new();
        for _ in 0..3 {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert_eq!(log.changes(), vec![GeometryChange::Bounds(WINDOW)]);
    }

    /// The three diffs are distinguished, and a move-AND-resize coalesces into ONE message — a
    /// client that received both would map one input event against each.
    #[test]
    fn the_diff_names_which_half_moved_and_coalesces_when_both_did() {
        let desk = Desk::scripted(vec![
            Some(WINDOW),
            Some(VideoRect::xywh(150.0, 100.0, 800.0, 600.0)),
            Some(VideoRect::xywh(150.0, 100.0, 640.0, 480.0)),
            Some(VideoRect::xywh(0.0, 0.0, 320.0, 240.0)),
        ]);
        let log = Log::default();
        let mut poller = Poller::new();
        for _ in 0..4 {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert_eq!(log.changes(), vec![
            GeometryChange::Bounds(WINDOW),
            GeometryChange::Move(VideoPoint::new(150.0, 100.0)),
            GeometryChange::Resize(VideoSize::new(640.0, 480.0)),
            GeometryChange::Bounds(VideoRect::xywh(0.0, 0.0, 320.0, 240.0)),
        ]);
        // The WHOLE frame rides beside every one of them, including the two that name a single
        // half. That is what the host's own re-origin acts on — a `Move` carries no size and a
        // `Resize` carries no origin, and neither is a rectangle anything can be mapped against.
        assert_eq!(log.frames(), vec![
            WINDOW,
            VideoRect::xywh(150.0, 100.0, 800.0, 600.0),
            VideoRect::xywh(150.0, 100.0, 640.0, 480.0),
            VideoRect::xywh(0.0, 0.0, 320.0, 240.0),
        ]);
    }

    /// A window the server cannot answer for leaves every piece of state untouched — the NEXT poll
    /// diffs against the last frame that was really read, not against a gap. A gap treated as
    /// "changed" would publish a phantom move on every hiccup.
    #[test]
    fn a_read_that_fails_is_not_a_change_and_does_not_become_one_later() {
        let desk = Desk::scripted(vec![Some(WINDOW), None, Some(WINDOW)]);
        let log = Log::default();
        let mut poller = Poller::new();
        for _ in 0..3 {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert_eq!(log.changes(), vec![GeometryChange::Bounds(WINDOW)]);
    }

    /// Disarmed is not "sample and throw away": the enumeration behind a region sample walks every
    /// on-screen window, and a caller that never opens a dialog must not pay for it.
    #[test]
    fn a_disarmed_poller_never_enumerates_anything() {
        let desk = Desk::scripted(vec![Some(WINDOW)]);
        let log = Log::default();
        let mut poller = Poller::new();
        for _ in 0..UNION_POLL_DIVIDER * 4 {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert_eq!(desk.enumerations.load(Ordering::Relaxed), 0);
        assert!(log.regions().is_empty());
    }

    /// Armed, the region is sampled every FIFTH poll and not more often — six times a second at the
    /// drag cadence, which is ample for an event that happens twice a session.
    #[test]
    fn an_armed_poller_enumerates_once_every_fifth_poll() {
        let desk = Desk::scripted(vec![Some(WINDOW)]);
        let log = Log::default();
        let mut poller = Poller::new();
        poller.arm_region(true);
        for _ in 0..UNION_POLL_DIVIDER * 3 {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert_eq!(desk.enumerations.load(Ordering::Relaxed), 3);
    }

    /// With nothing in front, the union is the window itself — and it is NOT published, because the
    /// baseline before a first region is the window frame the caller is already capturing.
    #[test]
    fn a_region_that_equals_the_window_is_never_published() {
        let desk = Desk::scripted(vec![Some(WINDOW)]);
        let log = Log::default();
        let mut poller = Poller::new();
        poller.arm_region(true);
        for _ in 0..UNION_POLL_DIVIDER {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert!(log.regions().is_empty());
    }

    /// A same-pid panel overlapping the window expands the region, and the CONTENT rects go out
    /// beside the union — the bounding box alone cannot express the hole beside a narrow popup, so
    /// the client would mask the wrong pixels.
    #[test]
    fn an_attached_dialog_expands_the_region_and_names_its_pieces() {
        let desk = Desk::scripted(vec![Some(WINDOW)]);
        *desk.in_front.lock().unwrap_or_else(PoisonError::into_inner) = vec![WindowSnapshot {
            window_id: 9,
            owner_pid: 42,
            layer: 0,
            frame: VideoRect::xywh(500.0, 300.0, 600.0, 400.0),
        }];
        let log = Log::default();
        let mut poller = Poller::new();
        poller.arm_region(true);
        for _ in 0..UNION_POLL_DIVIDER {
            poller.poll_once(&desk, &log, 7, 42);
        }
        let regions = log.regions();
        assert_eq!(regions.len(), 1);
        let Some((union, contents)) = regions.first() else {
            return;
        };
        assert_eq!(*union, VideoRect::xywh(100.0, 100.0, 1000.0, 600.0));
        assert_eq!(contents.len(), 2);
        assert_eq!(contents.first().copied(), Some(WINDOW));
    }

    /// A window on no display at all — a locked screen, a display asleep — samples nothing rather
    /// than clamping the region to an empty rect and cropping the stream to nothing.
    #[test]
    fn a_window_on_no_display_publishes_no_region() {
        let desk = Desk {
            display: None,
            ..Desk::scripted(vec![Some(WINDOW)])
        };
        let log = Log::default();
        let mut poller = Poller::new();
        poller.arm_region(true);
        for _ in 0..UNION_POLL_DIVIDER {
            poller.poll_once(&desk, &log, 7, 42);
        }
        assert!(log.regions().is_empty());
    }

    /// Disarming forgets the previous region, so re-arming republishes rather than suppressing the
    /// first sample against a baseline from a session ago.
    #[test]
    fn disarming_forgets_the_baseline() {
        let mut poller = Poller::new();
        poller.arm_region(true);
        assert!(poller.region_armed());
        poller.arm_region(false);
        assert!(!poller.region_armed());
    }

    /// The thread polls on its own, and `stop` ends it. The wait is a CONDITION with a ceiling, not
    /// a sleep: the cadence is 30 Hz, so a first frame lands in tens of milliseconds on any machine
    /// that is not wedged.
    #[test]
    fn the_watcher_thread_polls_until_it_is_stopped() {
        let desk = Arc::new(Desk::scripted(vec![Some(WINDOW)]));
        let log = Arc::new(Log::default());
        let mut watcher = GeometryWatcher::start(Arc::clone(&desk), Arc::clone(&log), 7, 42);
        assert!(until(|| desk.reads.load(Ordering::Relaxed) >= 3));
        assert_eq!(log.changes(), vec![GeometryChange::Bounds(WINDOW)]);
        watcher.stop();
        let settled = desk.reads.load(Ordering::Relaxed);
        std::thread::sleep(Duration::from_millis(120));
        assert_eq!(desk.reads.load(Ordering::Relaxed), settled);
    }

    /// Arming from the owning thread reaches the polling thread, and the poll does not undo it.
    #[test]
    fn arming_from_outside_reaches_the_polling_thread() {
        let desk = Arc::new(Desk::scripted(vec![Some(WINDOW)]));
        let log = Arc::new(Log::default());
        let watcher = GeometryWatcher::start(Arc::clone(&desk), Arc::clone(&log), 7, 42);
        assert!(until(|| desk.reads.load(Ordering::Relaxed) >= 2));
        watcher.arm_region(true);
        assert!(until(|| desk.enumerations.load(Ordering::Relaxed) >= 1));
        assert!(watcher.region_armed());
    }

    /// Dropping the watcher joins its thread, so nothing publishes to a sink that has gone away.
    #[test]
    fn dropping_the_watcher_ends_its_thread() {
        let desk = Arc::new(Desk::scripted(vec![Some(WINDOW)]));
        let log = Arc::new(Log::default());
        drop(GeometryWatcher::start(Arc::clone(&desk), Arc::clone(&log), 7, 42));
        // The thread is joined by `Drop`, so the only live references left are the test's own.
        assert_eq!(Arc::strong_count(&desk), 1);
        assert_eq!(Arc::strong_count(&log), 1);
    }
}
