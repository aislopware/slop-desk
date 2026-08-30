//! The cursor side-channel's host end: a 120 Hz thread, one window-server query, and a cold trip to
//! the main thread for the shape.
//!
//! The host captures with the pointer turned OFF and streams it separately over a small UDP socket,
//! so pointer latency is one round trip rather than "one round trip plus an encode plus a decode"
//! (`docs/17` §3.3).
//!
//! ## What it owns, and what it asks
//! It owns the CADENCE — the ~120 Hz thread, the hop to the main thread, the two locks, and the
//! order the two paths touch them in. Every rule it applies belongs to
//! [`slopdesk_video::cursor_sampling`]: when a tick should refresh, where the pointer sits in the
//! captured window's space, which id a shape's content gets, and what pixel sizes to try rendering
//! it at. The framework reads belong to the seams below, and the shape's bitmap and PNG to
//! `slopdesk-apple-cursor`.
//!
//! ## Two paths, on purpose — this is the whole design
//! The position sample runs on this module's OWN thread so that a main-thread window raise — six to
//! ten synchronous accessibility round-trips — cannot freeze the pointer. The shape read is
//! main-thread-ONLY because `AppKit` says so, and it is therefore reached by an ASYNCHRONOUS hop
//! ([`HopsToMain`]) rather than a call: a synchronous hop from the sampling thread would put the
//! 120 Hz stream behind exactly the main-thread stall the split exists to survive.
//!
//! That is also why [`ReadsPointer`] and [`ReadsShape`] are two traits and not one. They are not
//! split by subject matter; they are split by WHICH THREAD may call them, which is the only
//! distinction either implementation has to get right.
//!
//! ## The two locks, and why nothing is rendered under either
//! [`Sampler`] holds the hot state and the shape inventory behind separate locks. The hot one is
//! taken for a handful of arithmetic operations by both paths; the inventory one only by the cold
//! path and the re-ship door. A PNG render under the hot lock — up to sixteen draws and encodes —
//! would reintroduce the stall this whole shape exists to prevent, so the render happens between
//! the two acquisitions and under neither.
//!
//! ## Datagrams, not values
//! Both sink methods take already-encoded bytes. The session forwards them to the cursor socket
//! verbatim, so building a [`CursorUpdate`] here for the socket to re-encode there would be a parse
//! and a build per sample, 120 times a second, for no reader.
//!
//! ## What it replaces
//! The Swift host's cursor sampler, and `slopdesk-ffi`'s `cursor_sampler` — the handle that joined
//! the three crates below for that Swift face. The rules were already out of the Swift; what is
//! added back here is the values form of the same driver, for a caller that links them rather than
//! dialling them through a C door. The doors die with the Swift.
//!
//! ## The four real seams, and the one answer that is an absence
//! [`HostPointer`], [`HostShape`] and [`MainHop`] are the live implementations; the sink is the
//! session's, because only the session owns a socket. Each of the three took a `docs/57` §2 ruling
//! rather than a convenience:
//!
//! * **The pointer read** is `slopdesk-apple-nsevent`, its own crate. `NSEvent` is a different
//!   framework AREA from `NSCursor` — the same ruling `slopdesk-apple-cursor`'s `primary_height`
//!   note already made about `NSScreen` — and it is `NSEvent` rather than `CGEvent` because
//!   `mouseLocation` is already in global Cocoa points and `CGEventGetLocation` is not.
//! * **The hop** is `slopdesk-apple-nsapp::on_main`, beside the two loops that DRAIN the queue it
//!   posts to. A hop onto a queue nothing drains is work handed to a thread that never looks, so
//!   the pair belongs in one crate.
//! * **The cursor seed** has no wrapper and will not get one. It is `CGSCurrentCursorSeed` behind a
//!   private CoreGraphics connection — no `objc2` binding exists, and hand-writing the `extern`
//!   would put a private symbol inside the one family `docs/57` §2 says calls Apple only through
//!   generated bindings. [`HostPointer::cursor_seed`] therefore answers `None`, which is the exact
//!   case [`ReadsPointer::cursor_seed`] documents: the refresh policy's unconditional cadence is
//!   what carries the shape, one safety refresh later than a seed would have.

use core::fmt;
use std::collections::HashMap;
use std::io::Write as _;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_apple_cursor::CursorShape;
use slopdesk_video::cursor::{CursorShapeMessage, CursorUpdate};
use slopdesk_video::cursor_sampling::{
    MAX_SHAPE_BITMAP_BYTES, ShapeRefreshPolicy, ShapeTable, render_ladder, window_position,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

/// Sample rate — `docs/17` §3.3's "~120 Hz".
pub const SAMPLE_HZ: f64 = 120.0;

/// The two reads the HOT path makes, both safe off the main thread.
///
/// `NSEvent.mouseLocation` and the window server's cursor seed are window-server queries rather
/// than `AppKit` state, which is what lets the 120 Hz thread ask them directly instead of hopping.
pub trait ReadsPointer: Send + Sync + fmt::Debug {
    /// The pointer, in GLOBAL COCOA points — origin bottom-left, +Y up. That is the space
    /// [`window_position`] documents as its input, and converting to CG is its job rather than the
    /// reader's.
    fn pointer_cocoa(&self) -> VideoPoint;

    /// The window server's cursor seed, or `None` when the private symbol is gone.
    ///
    /// `None` is not an error and must not be logged: it is a private API that may vanish on any OS
    /// release, and the refresh policy has an unconditional cadence to fall back to.
    fn cursor_seed(&self) -> Option<i32>;
}

/// The two reads the COLD path makes, on the MAIN THREAD only.
///
/// Called from inside a [`HopsToMain::hop`] and nowhere else. An implementation is free to answer
/// nothing when it finds itself off the main thread — which is what `slopdesk-apple-cursor` does,
/// and which the sampler already treats as "keep the last shape".
pub trait ReadsShape: Send + Sync + fmt::Debug {
    /// The cursor the person is looking at, or `None` when nothing can be read.
    fn displayed_shape(&self) -> Option<CursorShape>;

    /// The PRIMARY display's height in points, for the Cocoa-to-CG flip.
    ///
    /// Read on the same trip as the shape because nothing else brings the sampler here, and because
    /// nothing bumps the cursor seed when a display changes — the slow safety refresh is what keeps
    /// this number current.
    fn primary_height(&self) -> f64;
}

/// Where the two encoded messages go.
pub trait SendsCursor: Send + Sync + fmt::Debug {
    /// An encoded [`CursorUpdate`], ~120 times a second.
    fn update(&self, datagram: &[u8]);

    /// An encoded [`CursorShapeMessage`], ONCE per newly-seen shape id (and again on a re-ship
    /// request), for the client to cache and composite.
    fn shape(&self, datagram: &[u8]);
}

/// The main-thread hop `AppKit` forces on the shape read.
///
/// ASYNCHRONOUS by contract: `hop` must return without waiting for `work`. A synchronous hop would
/// park the sampling thread behind whatever the main thread is doing, and the main thread is
/// precisely where a window raise spends six to ten accessibility round-trips — the stall the two
/// paths exist to keep apart. Work that never runs because the main queue never drained costs one
/// refresh, which the next tick asks for again.
pub trait HopsToMain: Send + Sync + fmt::Debug {
    /// Schedules `work` on the main thread.
    fn hop(&self, work: Box<dyn FnOnce() + Send + 'static>);
}

/// A shared reader is a reader — so one window-server face can serve the sampling thread and its
/// owner at once without either of them owning it. The same forwarding [`crate::windowgeometry`]
/// gives its two traits, for the same reason.
impl<T: ReadsPointer + ?Sized> ReadsPointer for Arc<T> {
    fn pointer_cocoa(&self) -> VideoPoint {
        (**self).pointer_cocoa()
    }
    fn cursor_seed(&self) -> Option<i32> {
        (**self).cursor_seed()
    }
}

/// The same, for the cold reads.
impl<T: ReadsShape + ?Sized> ReadsShape for Arc<T> {
    fn displayed_shape(&self) -> Option<CursorShape> {
        (**self).displayed_shape()
    }
    fn primary_height(&self) -> f64 {
        (**self).primary_height()
    }
}

/// The same, for the sink: the session owns the cursor socket and lends the sampler a handle on it.
impl<T: SendsCursor + ?Sized> SendsCursor for Arc<T> {
    fn update(&self, datagram: &[u8]) {
        (**self).update(datagram);
    }
    fn shape(&self, datagram: &[u8]) {
        (**self).shape(datagram);
    }
}

/// The real pointer, read on the SAMPLING thread.
///
/// `slopdesk-apple-nsevent`'s one call, which answers global Cocoa points because that is what
/// [`window_position`] takes — see that crate's header for why the read is `NSEvent` and not
/// `CGEvent`. Nothing here is `unsafe` and nothing here decides anything.
#[derive(Clone, Copy, Debug, Default)]
pub struct HostPointer;

impl ReadsPointer for HostPointer {
    fn pointer_cocoa(&self) -> VideoPoint {
        slopdesk_apple_nsevent::pointer_cocoa()
    }

    /// Always `None`, and permanently.
    ///
    /// The window server's cursor seed is `CGSCurrentCursorSeed` behind a private CoreGraphics
    /// connection. No `objc2` binding exists for it, and hand-writing the `extern` would put a
    /// private symbol inside the one crate family `docs/57` §2 restricts to generated bindings — so
    /// the answer is the absence [`ReadsPointer::cursor_seed`] already documents rather than a
    /// fourth `unsafe` crate. The cost is bounded and known: [`ShapeRefreshPolicy`] falls back to
    /// its unconditional cadence, so a shape change lands one fallback tick late instead of on the
    /// tick the seed would have flagged.
    fn cursor_seed(&self) -> Option<i32> {
        None
    }
}

/// The real hop: `slopdesk-apple-nsapp`'s main queue.
///
/// One call, and it is the crate that RUNS the queue — see [`HopsToMain`] for why the contract is
/// asynchronous and what a synchronous hop would cost the 120 Hz stream.
#[derive(Clone, Copy, Debug, Default)]
pub struct MainHop;

impl HopsToMain for MainHop {
    fn hop(&self, work: Box<dyn FnOnce() + Send + 'static>) {
        slopdesk_apple_nsapp::on_main(work);
    }
}

/// The real main display and the real displayed cursor.
///
/// Both calls are `slopdesk-apple-*`'s, so nothing here is `unsafe` and nothing here decides
/// anything.
#[derive(Clone, Copy, Debug, Default)]
pub struct HostShape;

impl ReadsShape for HostShape {
    fn displayed_shape(&self) -> Option<CursorShape> {
        slopdesk_apple_cursor::current_system()
    }

    /// The FIRST active display's height.
    ///
    /// The Swift read `NSScreen.screens.first`, which is the same display by a different route:
    /// CoreGraphics documents the active display list's first entry as the main one, and CG's
    /// global space is anchored to that display's top-left corner. Asked of the display list rather
    /// than of `AppKit` because this is a CG-space number, and `NSScreen.frame` is bottom-left —
    /// the y-flip nobody remembers to write is exactly the bug the position math is trying to
    /// avoid.
    ///
    /// A host with no active display answers `0`, which puts every pointer above the window and
    /// therefore reports it invisible. That is the honest answer for a machine with nothing to look
    /// at, and it self-corrects on the next safety refresh.
    fn primary_height(&self) -> f64 {
        slopdesk_apple_cgdisplay::active()
            .first()
            .map_or(0.0, |display| display.bounds.size.height)
    }
}

/// The state both paths touch, and the refresh path writes.
#[derive(Debug)]
struct Hot {
    /// The captured window in CG top-left points, kept current by the geometry watcher.
    bounds: VideoRect,
    /// The primary display's height, for the Cocoa-to-CG flip.
    primary_height: f64,
    /// The shape id every position update carries until the next refresh changes it.
    shape_id: u16,
    /// That shape's hotspot.
    hotspot: VideoPoint,
    /// Whether the first refresh has landed. Until it has, the position path answers NOTHING — an
    /// update sent before this would carry shape id 0, which the client has not been told about,
    /// and a screen height of 0, which would put the pointer off the bottom of the window.
    primed: bool,
    /// Ticks counted for the refresh cadence.
    tick: u64,
    /// The seed-to-refresh rule.
    policy: ShapeRefreshPolicy,
    /// Set when a refresh changed the shape id, cleared by [`Sampler::take_id_change`].
    id_changed: bool,
}

/// The shape inventory.
#[derive(Debug, Default)]
struct Shapes {
    /// Content to id.
    table: ShapeTable,
    /// Every encoded shape message minted this session, so a client whose one-shot shipment was
    /// lost can ask for it again without the cursor ever being read a second time.
    messages: HashMap<u16, Vec<u8>>,
}

/// Everything the sampler knows, with the framework reads and the threading taken out.
///
/// A value with no thread and no clock in it, the way [`crate::windowgeometry::Poller`] is: the
/// prime gate, the id-change flag, the inventory and the re-ship path are all reachable from a
/// headless test, and the pieces that are not — a real cursor bitmap, a real PNG — are exactly the
/// pieces the seams above hand in.
///
/// Its methods take `&self` rather than `&mut self` because two threads call them by design, which
/// is the same reason `slopdesk-ffi`'s handle carried its own locks instead of borrowing the
/// caller's.
#[derive(Debug)]
pub struct Sampler {
    hot: Mutex<Hot>,
    shapes: Mutex<Shapes>,
}

impl Sampler {
    /// A sampler for a window at these CG top-left bounds, with nothing primed.
    ///
    /// There is no bounds rectangle this can refuse: a degenerate one simply reports every pointer
    /// position as outside the window, which is what a zero-sized window means.
    #[must_use]
    pub fn new(bounds: VideoRect) -> Self {
        Self {
            hot: Mutex::new(Hot {
                bounds,
                primary_height: 0.0,
                shape_id: 0,
                hotspot: VideoPoint::new(0.0, 0.0),
                primed: false,
                tick: 0,
                policy: ShapeRefreshPolicy::new(),
                id_changed: false,
            }),
            shapes: Mutex::new(Shapes::default()),
        }
    }

    /// Retargets the sampler at new window bounds, in CG top-left points.
    pub fn set_bounds(&self, bounds: VideoRect) {
        self.hot.lock().unwrap_or_else(PoisonError::into_inner).bounds = bounds;
    }

    /// Counts one sampling tick and answers whether it should go to the main thread for a fresh
    /// shape.
    ///
    /// The seed is passed in rather than read here, because reading it is a framework question and
    /// this type is the part that has none.
    pub fn should_refresh(&self, seed: Option<i32>) -> bool {
        let mut hot = self.hot.lock().unwrap_or_else(PoisonError::into_inner);
        hot.tick = hot.tick.wrapping_add(1);
        let tick = hot.tick;
        hot.policy.should_refresh(seed, tick)
    }

    /// The encoded [`CursorUpdate`] for a mouse at these GLOBAL COCOA points, or `None` before the
    /// first refresh has primed the shape and the screen height.
    ///
    /// That `None` is the whole gate: an update sent early would name a shape the client has never
    /// been given, and place it against a screen height of zero.
    #[must_use]
    pub fn position(&self, mouse_cocoa: VideoPoint) -> Option<Vec<u8>> {
        let hot = self.hot.lock().unwrap_or_else(PoisonError::into_inner);
        if !hot.primed {
            return None;
        }
        let (position, visible) = window_position(mouse_cocoa, hot.primary_height, hot.bounds);
        let update = CursorUpdate::new(position, hot.shape_id, hot.hotspot, visible);
        drop(hot);
        Some(update.encode())
    }

    /// Records the displayed cursor, and answers a shape message the FIRST time a distinct one is
    /// seen.
    ///
    /// `None` is the common case by far: a session sees a few dozen distinct cursors and refreshes
    /// thousands of times. It is also the answer when the shape carries no bitmap that could be
    /// rendered — the id is still interned and the hot state is still primed, because a pointer
    /// with a stale picture beats no pointer.
    ///
    /// The render sits BETWEEN the two locks on purpose; see this module's own docs for why.
    pub fn refresh(&self, shape: &CursorShape, primary_height: f64) -> Option<Vec<u8>> {
        let hotspot = VideoPoint::new(shape.hotspot_x, shape.hotspot_y);
        let (id, minted) = {
            let mut inventory = self.shapes.lock().unwrap_or_else(PoisonError::into_inner);
            inventory.table.intern(&shape.tiff, hotspot)
        };
        {
            let mut hot = self.hot.lock().unwrap_or_else(PoisonError::into_inner);
            hot.id_changed |= hot.primed && hot.shape_id != id;
            hot.primary_height = primary_height;
            hot.shape_id = id;
            hot.hotspot = hotspot;
            hot.primed = true;
        }
        if !minted {
            return None;
        }
        let png = fitting_png(&shape.tiff, shape.width, shape.height)?;
        let message =
            CursorShapeMessage::new(id, VideoSize::new(shape.width, shape.height), hotspot, png).encode();
        {
            let mut inventory = self.shapes.lock().unwrap_or_else(PoisonError::into_inner);
            inventory.messages.insert(id, message.clone());
        }
        Some(message)
    }

    /// Whether a refresh has changed the shape id since this was last asked — and CLEARS the flag.
    ///
    /// Taken rather than read so the caller emits exactly ONE extra position update per change. The
    /// client switches its pointer on the next update carrying the new id, and waiting for the
    /// ordinary tick would show the old shape for up to one sampling interval after the cursor has
    /// already changed under the person's hand.
    pub fn take_id_change(&self) -> bool {
        let mut hot = self.hot.lock().unwrap_or_else(PoisonError::into_inner);
        core::mem::replace(&mut hot.id_changed, false)
    }

    /// An already-shipped shape message, by id.
    ///
    /// `None` for an id never minted: there is nothing to re-send, and reading the cursor again
    /// would answer whatever shape is displayed NOW rather than the one asked for. Safe from any
    /// thread — it reads a cache and touches no framework.
    #[must_use]
    pub fn shape(&self, shape_id: u16) -> Option<Vec<u8>> {
        self.shapes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .messages
            .get(&shape_id)
            .cloned()
    }
}

/// Renders the largest PNG of this cursor that fits one datagram.
///
/// Walks [`render_ladder`] largest-first and stops at the first PNG within
/// [`MAX_SHAPE_BITMAP_BYTES`]. If none fits — a pathological custom cursor — the SMALLEST one that
/// encoded at all is sent anyway: it will be IP-fragmented, which risks the shipment, and that
/// still beats a session with no pointer.
///
/// An empty bitmap is refused before the framework is asked. `slopdesk-apple-cursor` documents an
/// empty `tiff` as "the framework had no representation to give", and handing zero bytes to an
/// image decoder is a framework call whose answer is already known.
fn fitting_png(tiff: &[u8], logical_width: f64, logical_height: f64) -> Option<Vec<u8>> {
    if tiff.is_empty() {
        return None;
    }
    let bitmap = slopdesk_apple_cursor::measure(tiff)?;
    let mut last = None;
    for (width, height) in render_ladder(
        logical_width.max(logical_height),
        bitmap.pixels_wide,
        bitmap.pixels_high,
    ) {
        let Some(png) = slopdesk_apple_cursor::render_png(tiff, width, height) else {
            continue;
        };
        if png.len() <= MAX_SHAPE_BITMAP_BYTES {
            return Some(png);
        }
        last = Some(png);
    }
    last
}

/// One line on stderr per newly-minted shape, under `SLOPDESK_VIDEO_DEBUG`.
///
/// The one diagnostic this path keeps, because it is the only way a hardware run can confirm that
/// distinct cursors — I-beam, hand, resize — are really being detected and shipped. It fires on a
/// MINT, which is a few dozen times a session, so the environment is read per call rather than
/// cached: a static would buy nothing at that rate and would freeze the answer for the process.
fn trace_mint(bytes: usize) {
    if std::env::var_os("SLOPDESK_VIDEO_DEBUG").is_none() {
        return;
    }
    // ONE `write_all` of ONE buffer: two writes can interleave with another thread's.
    let _ignored = std::io::stderr().write_all(format!("[cursor] mint shapeBytes={bytes}\n").as_bytes());
}

/// Everything the sampling thread and its hops share.
#[derive(Debug)]
struct Shared<P, K, S, H> {
    sampler: Sampler,
    pointer: P,
    shape: K,
    sink: S,
    hop: H,
    stop: Mutex<bool>,
    wake: Condvar,
}

/// A ~120 Hz cursor sampler on its own thread, for one window, for as long as it is held.
///
/// A real thread rather than a task, for the reason [`crate::windowgeometry::GeometryWatcher`] is
/// one: this repo's daemons own their threads, and a fixed-cadence loop that spends its life in
/// `wait_timeout` is the shape an executor buys nothing for. The thread ends on `Drop`, which JOINS
/// it — a sample racing the teardown of the socket it publishes to is the one failure this rules
/// out entirely.
///
/// A hop already in flight when the thread stops may still run. It touches only the sampler and the
/// sink, both of which outlive it because this type owns them, so the worst it costs is one
/// datagram after the last one anybody wanted.
#[derive(Debug)]
pub struct CursorSampler<P, K, S, H>
where
    P: ReadsPointer + 'static,
    K: ReadsShape + 'static,
    S: SendsCursor + 'static,
    H: HopsToMain + 'static,
{
    shared: Arc<Shared<P, K, S, H>>,
    thread: Option<JoinHandle<()>>,
}

impl<P, K, S, H> CursorSampler<P, K, S, H>
where
    P: ReadsPointer + 'static,
    K: ReadsShape + 'static,
    S: SendsCursor + 'static,
    H: HopsToMain + 'static,
{
    /// Starts sampling a window at these CG top-left bounds.
    ///
    /// The first refresh is scheduled BEFORE the thread starts, so the shape and the screen height
    /// are primed as early as the main thread will allow and the first emitted position already
    /// carries a shape id the client has been told about. Until that lands the position path emits
    /// nothing at all, which is the deliberate gate rather than a startup race.
    #[must_use]
    pub fn start(pointer: P, shape: K, sink: S, hop: H, window_bounds_cg: VideoRect) -> Self {
        let shared = Arc::new(Shared {
            sampler: Sampler::new(window_bounds_cg),
            pointer,
            shape,
            sink,
            hop,
            stop: Mutex::new(false),
            wake: Condvar::new(),
        });
        schedule_refresh(&shared);
        let thread = {
            let shared = Arc::clone(&shared);
            thread::Builder::new()
                .name("slopdesk-cursor".to_owned())
                .spawn(move || run(&shared))
                .ok()
        };
        Self { shared, thread }
    }

    /// Updates the tracked window bounds. Call from the geometry watcher.
    pub fn set_bounds(&self, bounds: VideoRect) {
        self.shared.sampler.set_bounds(bounds);
    }

    /// Re-emits the already-shipped bytes for `shape_id`, for a client whose one-shot shipment was
    /// lost and which re-requested it over the recovery channel.
    ///
    /// A no-op for an id never minted — the cursor is NOT re-read, because that would answer
    /// whatever shape is displayed now rather than the one asked for.
    pub fn reship_shape(&self, shape_id: u16) {
        if let Some(datagram) = self.shared.sampler.shape(shape_id) {
            self.shared.sink.shape(&datagram);
        }
    }

    /// Ends the sampling thread and waits for it. Idempotent, and `Drop` calls it.
    pub fn stop(&mut self) {
        *self.shared.stop.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.shared.wake.notify_all();
        if let Some(thread) = self.thread.take() {
            drop(thread.join());
        }
    }
}

impl<P, K, S, H> Drop for CursorSampler<P, K, S, H>
where
    P: ReadsPointer + 'static,
    K: ReadsShape + 'static,
    S: SendsCursor + 'static,
    H: HopsToMain + 'static,
{
    fn drop(&mut self) {
        self.stop();
    }
}

/// The cadence: sample, then wait one interval or until told to stop.
fn run<P, K, S, H>(shared: &Arc<Shared<P, K, S, H>>)
where
    P: ReadsPointer + 'static,
    K: ReadsShape + 'static,
    S: SendsCursor + 'static,
    H: HopsToMain + 'static,
{
    // A reciprocal, computed once: the cadence is a constant and the division is not the loop's.
    let interval = Duration::from_secs_f64(1.0 / SAMPLE_HZ);
    loop {
        if stopped(shared) {
            return;
        }
        emit_position(shared);
        // Asked every tick, and it counts the tick — the fallback cadence is a tick count, so a
        // sampler that only asked while the seed was readable would never reach it.
        if shared.sampler.should_refresh(shared.pointer.cursor_seed()) {
            schedule_refresh(shared);
        }
        if !wait_a_tick(shared, interval) {
            return;
        }
    }
}

/// The hot path: read the pointer, and publish what the sampler makes of it.
///
/// The pointer read is the ONLY framework call here, and everything the position depends on besides
/// it — the window bounds, the screen height, the current shape id and its hotspot — is behind the
/// sampler's own lock.
fn emit_position<P, K, S, H>(shared: &Shared<P, K, S, H>)
where
    P: ReadsPointer,
    K: ReadsShape,
    S: SendsCursor,
    H: HopsToMain,
{
    let Some(datagram) = shared.sampler.position(shared.pointer.pointer_cocoa()) else {
        return;
    };
    shared.sink.update(&datagram);
}

/// Queues the cold path onto the main thread.
fn schedule_refresh<P, K, S, H>(shared: &Arc<Shared<P, K, S, H>>)
where
    P: ReadsPointer + 'static,
    K: ReadsShape + 'static,
    S: SendsCursor + 'static,
    H: HopsToMain + 'static,
{
    let hopped = Arc::clone(shared);
    shared.hop.hop(Box::new(move || refresh_on_main(&hopped)));
}

/// The cold path, on the main thread: read the displayed cursor and the primary screen's height,
/// and ship a bitmap the first time a distinct shape appears.
///
/// During a window raise this is delayed — the main thread is busy — but the position path keeps
/// flowing, so the pointer never freezes and only its shape briefly lags.
///
/// The shape is read BEFORE the display height because it is the read that can answer nothing: a
/// hop that landed off the main thread, or a framework with no representation to give, primes
/// nothing, and paying for a display query first would be a call made for a trip that is over.
fn refresh_on_main<P, K, S, H>(shared: &Shared<P, K, S, H>)
where
    P: ReadsPointer,
    K: ReadsShape,
    S: SendsCursor,
    H: HopsToMain,
{
    let Some(cursor) = shared.shape.displayed_shape() else {
        return;
    };
    let height = shared.shape.primary_height();
    if let Some(datagram) = shared.sampler.refresh(&cursor, height) {
        trace_mint(datagram.len());
        shared.sink.shape(&datagram);
    }
    // The client switches its local pointer on the NEXT update that carries the new id, so one goes
    // out immediately rather than letting the shape lag by up to a sampling tick. It is emitted
    // from here rather than bounced back to the sampling thread because the pointer read is a
    // window-server query that is safe on any thread — and a bounce would cost the very interval it
    // is trying to save.
    if shared.sampler.take_id_change() {
        emit_position(shared);
    }
}

/// Whether the thread has been told to end.
fn stopped<P, K, S, H>(shared: &Shared<P, K, S, H>) -> bool {
    *shared.stop.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Waits one interval, or until [`CursorSampler::stop`] says otherwise. Answers whether to
/// continue.
fn wait_a_tick<P, K, S, H>(shared: &Shared<P, K, S, H>, interval: Duration) -> bool {
    let stop = shared.stop.lock().unwrap_or_else(PoisonError::into_inner);
    let (stop, _) = shared
        .wake
        .wait_timeout_while(stop, interval, |stop| !*stop)
        .unwrap_or_else(PoisonError::into_inner);
    !*stop
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::time::{Duration, Instant};

    use slopdesk_apple_cursor::CursorShape;
    use slopdesk_video::cursor::CursorUpdate;
    use slopdesk_video::geometry::{VideoPoint, VideoRect};

    use super::{CursorSampler, HopsToMain, ReadsPointer, ReadsShape, Sampler, SendsCursor, fitting_png};

    /// A cursor with no bitmap: everything the sampler keys on except the picture.
    ///
    /// Every shape below is bitmap-less on purpose. A real TIFF would put an `AppKit` image decode
    /// and an offscreen draw inside a unit test, and what these tests are about — the prime gate,
    /// the id table, the change flag, the inventory — is reachable without one.
    const fn shape(hotspot_x: f64) -> CursorShape {
        CursorShape {
            hotspot_x,
            hotspot_y: 1.0,
            width: 24.0,
            height: 24.0,
            tiff: Vec::new(),
        }
    }

    /// A window server that answers a pointer the test can move and a seed it can bump, and counts
    /// what was asked of it.
    #[derive(Debug, Default)]
    struct Desk {
        seed: AtomicI32,
        /// Global Cocoa points, as the pair the reader turns into a point — `VideoPoint` has no
        /// `Default`, and a fake that needed one would be shaping the type for the test.
        mouse: Mutex<(f64, f64)>,
        reads: AtomicU32,
        shape_reads: AtomicU32,
    }

    impl ReadsPointer for Desk {
        fn pointer_cocoa(&self) -> VideoPoint {
            self.reads.fetch_add(1, Ordering::Relaxed);
            let (x, y) = *self.mouse.lock().unwrap_or_else(PoisonError::into_inner);
            VideoPoint::new(x, y)
        }
        fn cursor_seed(&self) -> Option<i32> {
            Some(self.seed.load(Ordering::Relaxed))
        }
    }

    impl ReadsShape for Desk {
        fn displayed_shape(&self) -> Option<CursorShape> {
            self.shape_reads.fetch_add(1, Ordering::Relaxed);
            Some(shape(1.0))
        }
        fn primary_height(&self) -> f64 {
            1000.0
        }
    }

    /// Everything published, in order.
    #[derive(Debug, Default)]
    struct Log {
        updates: Mutex<Vec<Vec<u8>>>,
        shapes: Mutex<Vec<Vec<u8>>>,
    }

    impl Log {
        fn update_count(&self) -> usize {
            self.updates.lock().unwrap_or_else(PoisonError::into_inner).len()
        }
        fn shape_count(&self) -> usize {
            self.shapes.lock().unwrap_or_else(PoisonError::into_inner).len()
        }
    }

    impl SendsCursor for Log {
        fn update(&self, datagram: &[u8]) {
            self.updates
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(datagram.to_vec());
        }
        fn shape(&self, datagram: &[u8]) {
            self.shapes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(datagram.to_vec());
        }
    }

    /// A hop that runs the work where it stands.
    ///
    /// Legitimate rather than a shortcut: the real hop takes the same inline path when the caller
    /// already IS the main thread, because dispatching onto the queue you are running on deadlocks.
    /// What a test cannot reproduce is the DELAY, and no assertion here depends on one.
    #[derive(Clone, Copy, Debug, Default)]
    struct Inline;

    impl HopsToMain for Inline {
        fn hop(&self, work: Box<dyn FnOnce() + Send + 'static>) {
            work();
        }
    }

    /// The window every test samples against: 800 × 600 at the origin, under a 1000-point display.
    const WINDOW: VideoRect = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);

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

    /// What a position datagram says, or `None` if it did not decode.
    fn decoded(datagram: &[u8]) -> Option<(u16, bool, VideoPoint)> {
        CursorUpdate::decode(datagram)
            .ok()
            .map(|update| (update.shape_id, update.visible, update.position))
    }

    // ----------------------------------------------------------------- sampler

    /// Before any refresh the position path says NOTHING, however many times it is asked. This is
    /// the gate that keeps an update naming an unshipped shape id off the wire.
    #[test]
    fn nothing_is_emitted_before_the_first_refresh_primes_the_state() {
        let sampler = Sampler::new(WINDOW);
        for _ in 0..100 {
            assert_eq!(sampler.position(VideoPoint::new(400.0, 300.0)), None);
        }
        assert!(!sampler.take_id_change());
    }

    /// The first refresh primes, and the position that follows carries the shape id and the
    /// Cocoa-to-CG flip: a pointer at the top of a 1000-point display is at y = 0 in the window.
    #[test]
    fn the_first_refresh_primes_and_the_next_position_carries_the_shape() {
        let sampler = Sampler::new(WINDOW);
        assert_eq!(
            sampler.refresh(&shape(1.0), 1000.0),
            None,
            "a bitmap-less shape mints an id but ships no picture"
        );
        assert_eq!(
            sampler
                .position(VideoPoint::new(10.0, 1000.0))
                .as_deref()
                .and_then(decoded),
            Some((0, true, VideoPoint::new(10.0, 0.0)))
        );
    }

    /// The same cursor keeps one id and raises no change; a different one raises exactly one, and
    /// TAKING it clears it. The flag is what buys the client its extra update, and a flag that
    /// stuck would buy it one per tick.
    #[test]
    fn a_new_shape_flags_one_id_change_and_the_same_shape_flags_none() {
        let sampler = Sampler::new(WINDOW);
        let _priming = sampler.refresh(&shape(1.0), 1000.0);
        assert!(!sampler.take_id_change(), "the priming refresh is not a change");
        let _again = sampler.refresh(&shape(1.0), 1000.0);
        assert!(!sampler.take_id_change());
        let _different = sampler.refresh(&shape(9.0), 1000.0);
        assert!(sampler.take_id_change());
        assert!(!sampler.take_id_change(), "taking it clears it");
    }

    /// Retargeting the window moves the reported position with it, without a refresh — the geometry
    /// watcher writes bounds far more often than the cursor changes shape.
    #[test]
    fn retargeting_the_window_moves_the_reported_position() {
        let sampler = Sampler::new(WINDOW);
        let _priming = sampler.refresh(&shape(1.0), 1000.0);
        sampler.set_bounds(VideoRect::xywh(100.0, 50.0, 800.0, 600.0));
        assert_eq!(
            sampler
                .position(VideoPoint::new(150.0, 900.0))
                .as_deref()
                .and_then(decoded),
            Some((0, true, VideoPoint::new(50.0, 50.0)))
        );
    }

    /// A pointer off the window is reported, and reported as INVISIBLE rather than withheld: the
    /// client stops drawing the pointer on that flag, and a withheld update would freeze it where
    /// it was last seen.
    #[test]
    fn a_pointer_outside_the_window_is_still_reported_and_marked_invisible() {
        let sampler = Sampler::new(WINDOW);
        let _priming = sampler.refresh(&shape(1.0), 1000.0);
        assert_eq!(
            sampler
                .position(VideoPoint::new(-40.0, 1000.0))
                .as_deref()
                .and_then(decoded),
            Some((0, false, VideoPoint::new(-40.0, 0.0)))
        );
    }

    /// A shape never minted has nothing to re-ship, and asking does not read the cursor to invent
    /// one — a client asking for a lost id must get that id or nothing, never whatever is on screen
    /// now. Nothing renderable was ever stored here, so even the id that WAS minted answers
    /// nothing.
    #[test]
    fn an_unknown_shape_id_has_nothing_to_reship() {
        let sampler = Sampler::new(WINDOW);
        let _priming = sampler.refresh(&shape(1.0), 1000.0);
        for id in [0_u16, 1, 7, u16::MAX] {
            assert_eq!(sampler.shape(id), None);
        }
    }

    /// The cadence is driven by the seed and the tick count alone, so it runs whether or not a
    /// shape can be read. The first tick refreshes — that is the prime — the ticks after it mostly
    /// do not, and a moved seed refreshes on that very tick.
    #[test]
    fn the_cadence_advances_on_the_seed_and_the_tick_count_alone() {
        let sampler = Sampler::new(WINDOW);
        assert!(sampler.should_refresh(Some(6001)), "the first tick primes");
        let refreshed = (2..=100).filter(|_| sampler.should_refresh(Some(6001))).count();
        assert!(
            refreshed <= 25,
            "{refreshed} refreshes in 99 ticks is not a cadence"
        );
        assert!(sampler.should_refresh(Some(6002)));
    }

    /// A cursor with no bitmap renders nothing rather than asking the framework to decode zero
    /// bytes. The one branch of the render path a headless suite can reach, and the one that keeps
    /// an `AppKit` call out of every other test in this file.
    #[test]
    fn an_empty_bitmap_renders_nothing() {
        assert_eq!(fitting_png(&[], 24.0, 24.0), None);
    }

    // ------------------------------------------------------------------ driver

    /// The thread samples, and the prime landed BEFORE the first tick — an emitted update is the
    /// proof, because the position path answers nothing until a refresh has primed it.
    #[test]
    fn the_thread_primes_before_it_samples_and_then_keeps_sampling() {
        let desk = Arc::new(Desk::default());
        *desk.mouse.lock().unwrap_or_else(PoisonError::into_inner) = (10.0, 1000.0);
        let log = Arc::new(Log::default());
        let mut sampler = CursorSampler::start(
            Arc::clone(&desk),
            Arc::clone(&desk),
            Arc::clone(&log),
            Inline,
            WINDOW,
        );
        assert!(until(|| log.update_count() >= 3), "the thread never sampled");
        assert!(
            desk.shape_reads.load(Ordering::Relaxed) >= 1,
            "the prime hop never ran"
        );
        assert_eq!(
            log.shape_count(),
            0,
            "a bitmap-less cursor mints an id but ships no picture"
        );
        sampler.stop();
        let settled = desk.reads.load(Ordering::Relaxed);
        std::thread::sleep(Duration::from_millis(120));
        assert_eq!(
            desk.reads.load(Ordering::Relaxed),
            settled,
            "the thread outlived its stop"
        );
    }

    /// Dropping the sampler joins its thread, so nothing publishes to a sink that has gone away —
    /// the property that makes it safe to tear the cursor socket down straight afterwards.
    #[test]
    fn dropping_the_sampler_ends_its_thread() {
        let desk = Arc::new(Desk::default());
        let log = Arc::new(Log::default());
        drop(CursorSampler::start(
            Arc::clone(&desk),
            Arc::clone(&desk),
            Arc::clone(&log),
            Inline,
            WINDOW,
        ));
        // The thread is joined by `Drop`, so the only live references left are the test's own.
        assert_eq!(Arc::strong_count(&desk), 1);
        assert_eq!(Arc::strong_count(&log), 1);
    }

    /// A re-ship request for an id nobody minted publishes nothing at all. The client must get the
    /// id it asked for or silence — never whatever cursor happens to be on screen when it asked.
    #[test]
    fn a_reship_for_an_id_that_was_never_minted_publishes_nothing() {
        let desk = Arc::new(Desk::default());
        let log = Arc::new(Log::default());
        let sampler = CursorSampler::start(
            Arc::clone(&desk),
            Arc::clone(&desk),
            Arc::clone(&log),
            Inline,
            WINDOW,
        );
        sampler.reship_shape(0);
        sampler.reship_shape(u16::MAX);
        assert_eq!(log.shape_count(), 0);
    }
}
