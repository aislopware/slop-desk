//! The coalescing inbound pump: one queue, one thread, and everything a datagram from the client
//! turns into.
//!
//! The Swift host session's `receiveBatch`, `injectCoalesced`, the scroll idle flush,
//! `handleControl` and `inject`.
//!
//! ## Why the pump keeps its queue and its own thread
//! [`crate::session`]'s module note says which of the Swift's two pumps survives the port and why.
//! Restated at the site it governs: this one is NOT here for ordering — the mux receive loop is
//! already serial — it is here because the queue is where COALESCING happens. A pointer-motion run
//! collapses to its latest only if a run has had a chance to pile up, and injecting inline on the
//! receive thread would let one slow `CGEventPost` back-pressure the socket. The datagrams that
//! then drop are dropped by the KERNEL, which cannot collapse them: the exact loss the coalescer
//! exists to prevent. A future simplification that deletes the thread deletes the feature.
//!
//! The enqueue side is ENQUEUE THEN SIGNAL, under one lock, so a wakeup is never lost: a consumer
//! that was about to wait sees the item instead, and one already waiting is woken by the signal.
//!
//! ## The scroll idle flush is the pump's own timeout, not a timer
//! The Swift armed a one-shot `Task` that slept one `scrollInjectInterval` and re-planned an EMPTY
//! run — the trailing-flush path — so a residual stranded by a lost gesture-`ended` drained instead
//! of waiting for the next unrelated input. Here that is the consumer's `wait_timeout`: while a
//! residual is held the wait carries the same interval, and a timed-out wait runs the same
//! empty-run plan. Same rule, same clock, one fewer subsystem.
//!
//! ## What this file holds that [`Session`] cannot
//! A session's fields are fixed by [`crate::session::Session`], which this file may not edit, and
//! eight pieces of the Swift actor's state have no field there: the pump itself, the scroll
//! planner, the raise latch, the injector seam, the user stream overrides, the recovery deduper and
//! the host-stats stamp. They live in `SessionExtras`, one per lane, in a module-owned table keyed
//! by the lane's `channel_id` — created by `Session::lane_sink` and removed by
//! `Session::stop_inbound`, so the table's lifetime is exactly the pump's.
//!
//! The adaptive-FEC tier is the ONE piece that does not: it sits on
//! [`crate::session_wiring::Controllers::fec_tier`], because the FRAME path reads it to stamp a
//! packet and the report fold steps it under that same lock. A side table would have handed the
//! packetizer a tier from half a report.
//!
//! ## ⚠️ The injector is a SEAM, and the implementation plugs into it
//! [`InputInjector`] is a trait with a `None` slot, and with nothing installed every `inject` is a
//! no-op — the Swift's own `guard let injector` behaviour before bring-up. What fills the slot is
//! [`crate::injector::Injector`], installed by [`crate::session_capture`]'s step 6 and cleared by
//! its teardown, so the window in which posting is a no-op is exactly the window in which there is
//! no capture to post against. The seam survives the wiring because it is also what lets a test
//! install a recorder and read the ORDER back without a window server.
//!
//! ⚠️ GUI + TCC ONLY below `Session::inject_coalesced`: a posted `CGEvent` needs Accessibility and
//! Post-Event, so no test here installs a real injector.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, LazyLock, Mutex, MutexGuard, PoisonError, Weak};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_video::adaptive_fec::TierState;
use slopdesk_video::congestion::{ABR_KEYS, CongestionConfig};
use slopdesk_video::geometry::VideoSize;
use slopdesk_video::input_event::InputEvent;
use slopdesk_video::input_routing::{self, ScrollCoalescePlanner};
use slopdesk_video::recovery_dedupe::RecoveryRequestDeduper;
use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_video::session_state::clamp_capture_size;
use slopdesk_video::video_control::VideoControlMessage;

use crate::encode::Encoder;
use crate::env::Overlay;
use crate::injector::HeldInput;
use crate::mux_sink::LaneSink;
use crate::session::{CaptureStream, Session};
use crate::session_wiring::Target;

/// The one thing this crate needs from something that can post input at the window server.
///
/// A trait, and not a call into `slopdesk-apple-cgevent`, because the ORCHESTRATION that belongs
/// behind these verbs — the button-balance ledger, the pre-release, the raise pump's own thread,
/// the scroll router — is [`crate::injector`], and what a test needs here is a recorder that posts
/// nothing. The seam is what lets both be the same session's injector.
///
/// Four methods, and the last two are here only because this seam IS the handle: the session owns
/// no other reference to what it installed, so the bring-up's held-input carry-over and the
/// geometry watcher's re-origin both have nowhere else to ask. Anything a caller can reach through
/// its own handle stays off this trait.
pub trait InputInjector: Send + Sync + core::fmt::Debug {
    /// Posts one decoded client event. Fire-and-forget, as the wire is.
    fn inject(&self, event: &InputEvent);
    /// Brings the captured window frontmost. MUST return promptly — the Swift's whole
    /// click-latency note is that this is never awaited, because an accessibility raise against a
    /// slow target costs about a second and the input path cannot pay it.
    fn raise_target_window(&self);
    /// What the user is physically holding, for seeding the injector that replaces this one.
    fn balance(&self) -> HeldInput;

    /// Lets go of everything the user is still holding, because no injector will replace this one.
    ///
    /// The other end of [`Self::balance`]: a re-mint CARRIES the held state, a final teardown
    /// RELEASES it, and the session says which by calling exactly one of the two. Inert by default
    /// for the recorder's reason — it holds nothing.
    fn release_all(&self) {}

    /// Re-points the coordinate mapping at a new rectangle, in GLOBAL CG points.
    ///
    /// The FOURTH method, and here for the same reason the third is: the session owns no other
    /// reference to what it installed, and the two callers that must re-point it — the geometry
    /// watcher's move handler and the dialog-expand rebuild — reach it only through this seam. The
    /// rectangle is the capture's own: the plain window frame ordinarily, and the UNION while an
    /// expanded region is live, which is what keeps a click in the dialog area mapping to the right
    /// absolute point.
    ///
    /// INERT by default, for [`crate::session::CaptureStream`]'s reason: a recorder that models the
    /// session's view of an injector has no mapping to move, and a default that lied would be a
    /// different thing entirely.
    fn update_bounds(&self, bounds: slopdesk_video::geometry::VideoRect) {
        let _ = bounds;
    }
}

/// The inbound queue and its two flags, as ONE lock.
///
/// One lock rather than three because the consumer's wait condition reads all of them and a
/// condvar needs exactly one mutex to pair with. `scroll_pending` lives here — rather than beside
/// the planner that computes it — for the same reason: it is a wait condition, and reading it from
/// a second lock inside this one's critical section would be the only nested hold in the file.
#[derive(Debug, Default)]
struct Pump {
    /// Datagrams the receive thread has handed over, oldest first.
    queue: Vec<(VideoChannel, Vec<u8>)>,
    /// Set once by `Session::stop_inbound`; the consumer's exit condition.
    stopping: bool,
    /// Whether the scroll planner is holding a residual, so the wait carries a timeout.
    scroll_pending: bool,
}

/// The raise latch and the scroll planner, as ONE lock.
///
/// Grouped because `Session::inject_coalesced` advances both in the same pass and in a fixed
/// order — plan the run, then walk it deciding the raise per event — and the Swift's actor gave
/// exactly that grouping. The injector rides along so a run is planned, latched and posted against
/// one snapshot of "is there an injector at all".
#[derive(Debug)]
struct InputState {
    /// The time-gated scroll accumulator, held ACROSS drains. See
    /// [`ScrollCoalescePlanner`] — the whole fold is its rule, and this file only injects what it
    /// answers.
    planner: ScrollCoalescePlanner,
    /// Whether the next event that can raise SHOULD raise. Cleared by a raise, re-armed by a
    /// mouse-up, so one interaction pays for at most one raise.
    needs_raise: bool,
    /// What posts an event, or `None` before bring-up and after teardown.
    injector: Option<Arc<dyn InputInjector>>,
}

/// The recovery path's own bookkeeping: what has already been answered, and what is due.
///
/// The adaptive-FEC ladder is deliberately NOT here. It lives on
/// [`crate::session_wiring::Controllers`], beside the estimate whose loss EWMA steps it and under
/// the one lock the whole report fold takes — and the FRAME path reads it there too, which is the
/// half a per-lane side table could not serve.
#[derive(Debug)]
pub(crate) struct RecoveryState {
    /// Drops the client's byte-identical 3× copies of one logical request.
    deduper: RecoveryRequestDeduper,
    /// When the host-stats echo last went out, on the session clock. Negative infinity so the very
    /// first report sends one.
    last_host_stats: f64,
}

/// The client's live stream overrides, replaced wholesale by every settings message.
#[derive(Debug, Default, Clone, Copy)]
struct UserSettings {
    /// The cadence cap, or `None` for auto.
    fps_cap: Option<i64>,
    /// The bitrate ceiling, or `None` for auto.
    bitrate_ceiling_bps: Option<i64>,
}

/// Everything one lane's inbound and actuation paths own that [`Session`] has no field for.
///
/// Behind an [`Arc`] because three owners hold it: the sink closure the transport calls, the pump
/// thread, and the table below. None of them holds a strong edge to the [`Session`] — the pump
/// carries a [`Weak`] and upgrades per drain, which is the Swift's `[weak self]` — so a session
/// that drops its last handle is not kept alive by its own queue.
#[derive(Debug)]
pub(crate) struct SessionExtras {
    /// The queue, its flags, and the condvar they are waited on with.
    pump: Mutex<Pump>,
    /// Signalled by every enqueue and by the stop.
    wake: Condvar,
    /// The scroll planner, the raise latch and the injector.
    input: Mutex<InputState>,
    /// The recovery deduper and the host-stats stamp.
    recovery: Mutex<RecoveryState>,
    /// The client's live overrides.
    settings: Mutex<UserSettings>,
    /// The consumer thread, taken and joined by [`Session::stop_inbound`].
    thread: Mutex<Option<JoinHandle<()>>>,
    /// How long a held scroll residual may wait before the idle flush drains it.
    scroll_interval: Duration,
    /// Whether the adaptive-m parity ladder rules instead of the group-size one.
    adaptive_m: bool,
    /// Whether the group-size ladder may relax all the way to OFF.
    fec_allow_off: bool,
    /// The congestion tunables, resolved once.
    ///
    /// Held here — not read per report — because the FPS governor's own congestion evidence needs
    /// them EVEN WHEN ABR is off, and with ABR off there is no controller to ask.
    congestion_config: CongestionConfig,
}

/// Every live lane's extras, by `channel_id`.
///
/// A module-owned table rather than a [`Session`] field because this file may not add one, and a
/// table is the honest shape of what it replaces: the Swift's actor-isolated `private var`s, one
/// set per session, reachable from exactly the paths that own them. Written twice in a lane's life
/// — inserted by [`Session::lane_sink`], removed by [`Session::stop_inbound`].
static EXTRAS: LazyLock<Mutex<BTreeMap<u32, Arc<SessionExtras>>>> =
    LazyLock::new(|| Mutex::new(BTreeMap::new()));

/// The table, through the poison discipline every lock in this crate uses: a panic inside one
/// lane's pump must not stop every other lane from ever registering again, and a map has no
/// invariant a partial write could break.
fn locked_table() -> MutexGuard<'static, BTreeMap<u32, Arc<SessionExtras>>> {
    EXTRAS.lock().unwrap_or_else(PoisonError::into_inner)
}

impl SessionExtras {
    /// Builds a lane's extras, resolving every launch-time knob ONCE.
    ///
    /// Resolved here rather than per report for the reason `docs/46` gives for every gate: there is
    /// no live reload, `just host-restart` is the reload, and a knob read on the report path would
    /// be a second resolution that could disagree with the first.
    fn new(session: &Session) -> Self {
        // Positional by the rules crate's own key order, and BORROWED into a second array because
        // that is the shape `from_env` takes. Built with `from_fn` rather than an indexed loop
        // because this crate denies `indexing_slicing`, and a missing key is a `None` slot — the
        // gate's default — rather than a panic.
        let abr_texts: [Option<String>; ABR_KEYS.len()] =
            core::array::from_fn(|index| ABR_KEYS.get(index).and_then(|key| session.overlay.get(key)));
        let abr: [Option<&str>; ABR_KEYS.len()] =
            core::array::from_fn(|index| abr_texts.get(index).and_then(Option::as_deref));
        Self {
            pump: Mutex::new(Pump::default()),
            wake: Condvar::new(),
            input: Mutex::new(InputState {
                planner: ScrollCoalescePlanner::new(
                    session.gates.scroll_inject_interval,
                    session.gates.scroll_coalesce_enabled,
                ),
                needs_raise: true,
                injector: None,
            }),
            recovery: Mutex::new(RecoveryState {
                deduper: RecoveryRequestDeduper::new(
                    session.gates.recovery_dedup_window,
                    RecoveryRequestDeduper::DEFAULT_CAPACITY,
                ),
                last_host_stats: f64::NEG_INFINITY,
            }),
            settings: Mutex::new(UserSettings::default()),
            thread: Mutex::new(None),
            scroll_interval: Duration::from_secs_f64(session.gates.scroll_inject_interval.max(0.0)),
            adaptive_m: adaptive_m_enabled(&session.overlay),
            fec_allow_off: session.overlay.get("SLOPDESK_FEC_ALLOW_OFF").as_deref() == Some("1"),
            congestion_config: CongestionConfig::from_env(&abr),
        }
    }

    /// The pump, through the poison discipline above.
    fn locked_pump(&self) -> MutexGuard<'_, Pump> {
        self.pump.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The input state, through the poison discipline above.
    fn locked_input(&self) -> MutexGuard<'_, InputState> {
        self.input.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The recovery state, through the poison discipline above.
    pub(crate) fn locked_recovery(&self) -> MutexGuard<'_, RecoveryState> {
        self.recovery.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The user overrides, through the poison discipline above.
    fn locked_settings(&self) -> MutexGuard<'_, UserSettings> {
        self.settings.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Appends one datagram and signals — in that order, under one hold, so a wakeup is never
    /// lost.
    fn enqueue(&self, channel: VideoChannel, datagram: &[u8]) {
        let mut pump = self.locked_pump();
        if pump.stopping {
            return;
        }
        pump.queue.push((channel, datagram.to_vec()));
        drop(pump);
        self.wake.notify_one();
    }

    /// Waits for work and answers the drained batch, or `None` once the pump is stopping.
    ///
    /// An EMPTY batch is not "nothing to do": it is the scroll idle flush, and the caller runs the
    /// empty-run plan for it. That is why the timeout arm answers `Some(vec![])` rather than
    /// looping.
    fn drain(&self) -> Option<Vec<(VideoChannel, Vec<u8>)>> {
        let mut pump = self.locked_pump();
        loop {
            if pump.stopping {
                return None;
            }
            if !pump.queue.is_empty() {
                return Some(core::mem::take(&mut pump.queue));
            }
            if pump.scroll_pending {
                let (guard, timeout) = self
                    .wake
                    .wait_timeout(pump, self.scroll_interval)
                    .unwrap_or_else(PoisonError::into_inner);
                pump = guard;
                if timeout.timed_out() {
                    return Some(Vec::new());
                }
            } else {
                pump = self.wake.wait(pump).unwrap_or_else(PoisonError::into_inner);
            }
        }
    }

    /// Records whether a scroll residual is still held, so the next wait carries the idle timeout.
    fn set_scroll_pending(&self, pending: bool) {
        let mut pump = self.locked_pump();
        pump.scroll_pending = pending;
        drop(pump);
    }
}

/// The adaptive-`m` ladder's gate: `SLOPDESK_ADAPTIVE_FEC_M` is a SWITCH, and its on-value is the
/// literal `1`.
///
/// Spelled exactly as `Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift:162` spells it
/// (`env["SLOPDESK_ADAPTIVE_FEC_M"] == "1"`), because this key is READ ON BOTH SIDES of a shipped
/// wire: a host that disagreed with the client about what turns the ladder on would step tiers
/// 5/6/7 the peer never expects. Reading it as a parity THRESHOLD instead — `>= 2` — inverts it at
/// exactly the documented on-value, so the one setting operators are told to use would be the one
/// setting that leaves the ladder off.
///
/// It does not carry the parity count. `m` comes from the codec
/// ([`slopdesk_video::fec::ReedSolomonFec::parity_count`]), and this gate only says whether the
/// ladder is allowed to steer it.
pub(crate) fn adaptive_m_enabled(overlay: &Overlay) -> bool {
    overlay
        .get("SLOPDESK_ADAPTIVE_FEC_M")
        .is_some_and(|text| text == "1")
}

impl Session {
    /// The sink [`crate::mux_lane::MuxLaneTransport::start`] registers for this lane.
    ///
    /// Building the sink is what BRINGS THE PUMP UP: the extras are created, the table entry is
    /// written and the consumer thread is spawned, and only then is a closure that can enqueue
    /// handed back. The order matters for the one datagram that always races a mint — the hello —
    /// which must be deliverable the instant the sink is registered.
    ///
    /// Idempotent by replacement: a second call for the same lane retires the previous pump first,
    /// so a re-`start` cannot leave two threads draining one session.
    pub(crate) fn lane_sink(self: &Arc<Self>) -> LaneSink {
        self.stop_inbound();
        let extras = Arc::new(SessionExtras::new(self));
        drop(locked_table().insert(self.transport.channel_id(), Arc::clone(&extras)));

        let weak = Arc::downgrade(self);
        let consumer = Arc::clone(&extras);
        let spawned = thread::Builder::new()
            .name("slopdesk-inbound".to_owned())
            .spawn(move || pump_loop(&weak, &consumer));
        // A pump that could not be spawned leaves the session LISTENING with a queue nothing
        // drains, which the idle reaper reclaims — the same outcome as a client that never speaks.
        // Failing the mint instead would turn "out of threads" into "no session at all".
        if let Ok(handle) = spawned {
            let mut slot = extras.thread.lock().unwrap_or_else(PoisonError::into_inner);
            *slot = Some(handle);
            drop(slot);
        }

        let enqueue = Arc::clone(&extras);
        Arc::new(move |channel: VideoChannel, datagram: &[u8]| {
            enqueue.enqueue(channel, datagram);
        })
    }

    /// Stops the pump: step 1 of [`crate::mux_registry::LaneSession::stop`].
    ///
    /// FIRST, before the send lane and before the live components, so no datagram already queued
    /// injects into a half-torn-down session. The thread is joined so the teardown below it cannot
    /// race a drain — except when this is CALLED FROM the pump thread itself, which happens on the
    /// `bye` path: a control datagram retires its own lane, and joining yourself is a deadlock. The
    /// handle is dropped instead; the thread is already unwinding to its exit.
    ///
    /// Idempotent: a reap and a `bye` reach it concurrently by design.
    pub(crate) fn stop_inbound(&self) {
        let Some(extras) = locked_table().remove(&self.transport.channel_id()) else {
            return;
        };
        let mut pump = extras.locked_pump();
        pump.stopping = true;
        pump.queue.clear();
        drop(pump);
        extras.wake.notify_all();

        let mut slot = extras.thread.lock().unwrap_or_else(PoisonError::into_inner);
        let handle = slot.take();
        drop(slot);
        if let Some(handle) = handle {
            if handle.thread().id() == thread::current().id() {
                return;
            }
            // A pump that panicked has already stopped; there is nothing here to report it to that
            // is not the panic itself.
            drop(handle.join());
        }
    }

    /// Installs — or clears — what posts this session's input.
    ///
    /// The bring-up and teardown paths own the call sites, and neither knows this trait exists,
    /// which is why this door is `pub(crate)` rather than a constructor argument. With nothing
    /// installed every post is a no-op, exactly as the Swift's `guard let injector` was
    /// before bring-up.
    pub(crate) fn set_input_injector(&self, injector: Option<Arc<dyn InputInjector>>) {
        let Some(extras) = self.extras() else {
            return;
        };
        let mut input = extras.locked_input();
        input.injector = injector;
        drop(input);
    }

    /// Uninstalls the injector and hands it back, so the caller can act on it OUTSIDE the lock —
    /// a release posts at the window server, and a post under this lock would hold every inbound
    /// drain for a round trip.
    pub(crate) fn take_input_injector(&self) -> Option<Arc<dyn InputInjector>> {
        let extras = self.extras()?;
        let mut input = extras.locked_input();
        let taken = input.injector.take();
        drop(input);
        taken
    }

    /// What the installed injector says the user is physically holding, or an empty ledger.
    ///
    /// Read by the bring-up BEFORE it tears the last stream down, so a transparent reconnect seeds
    /// the replacement with the drag or the ⌘ the user never let go of. Empty when nothing is
    /// installed, which is both the first bring-up and the honest answer after a teardown: with no
    /// injector there is no ledger, and inventing held buttons would suppress the releases that
    /// follow.
    pub(crate) fn input_balance(&self) -> HeldInput {
        let Some(extras) = self.extras() else {
            return HeldInput::default();
        };
        let input = extras.locked_input();
        let held = input.injector.as_ref().map(|injector| injector.balance());
        drop(input);
        held.unwrap_or_default()
    }

    /// Re-points the installed injector's coordinate mapping at `bounds`, in GLOBAL CG points.
    ///
    /// The other end of [`InputInjector::update_bounds`], and a door for the same reason
    /// [`Self::input_balance`] is one: the seam IS the handle, so the two callers that must
    /// re-point the mapping — a window move and a dialog-expand rebuild — have nowhere else to
    /// ask. A no-op with nothing installed, which is the honest answer before a bring-up and
    /// after a teardown.
    pub(crate) fn reorigin_input(&self, bounds: slopdesk_video::geometry::VideoRect) {
        let Some(extras) = self.extras() else {
            return;
        };
        let input = extras.locked_input();
        let injector = input.injector.clone();
        // Dropped before the call: the mapping write takes the injector's own lock, and holding the
        // inbound one across it would put the receive thread behind a geometry poll.
        drop(input);
        if let Some(injector) = injector {
            injector.update_bounds(bounds);
        }
    }

    /// This lane's extras, or `None` once the pump has been stopped.
    pub(crate) fn extras(&self) -> Option<Arc<SessionExtras>> {
        locked_table().get(&self.transport.channel_id()).map(Arc::clone)
    }

    /// The adaptive-FEC tier the next frame should be packetized at.
    ///
    /// The frame path's read of what the report path stepped, taken from
    /// [`crate::session_wiring::Controllers::fec_tier`] — the same lock the fold steps it under, so
    /// a frame can never be stamped with a tier from half a report. `TierState::default()` before
    /// any report has arrived, which is [`slopdesk_video::adaptive_fec::DEFAULT_TIER`] and the
    /// byte-identical baseline: a session with no feedback yet packetizes exactly as an
    /// un-adaptive one does.
    #[must_use]
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "the frame path reads the tier from `Controllers::fec_tier` INSIDE the lock hold it \
                      already owns (`crate::session_pump`), because taking the lock twice per frame would \
                      let a report land between the two reads. This accessor is the same read for a caller \
                      that holds nothing, which today is only the tests."
        )
    )]
    pub(crate) fn fec_tier_state(&self) -> TierState {
        let controllers = self.locked_controllers();
        let tier = controllers.fec_tier;
        drop(controllers);
        tier
    }

    /// Whether the adaptive-m parity ladder is the one in force, which the wire tier mapping needs.
    ///
    /// Answered from the pump's own resolved gate when there is a pump, and from the overlay
    /// directly when there is not — the FRAME path asks this to map a ladder tier onto the wire,
    /// and it must not depend on whether the inbound pump happens to have been started first.
    #[must_use]
    pub(crate) fn adaptive_m_enabled(&self) -> bool {
        self.extras()
            .map_or_else(|| adaptive_m_enabled(&self.overlay), |extras| extras.adaptive_m)
    }

    /// The client's live bitrate ceiling, or `None` for auto.
    ///
    /// [`crate::session_wiring::Controllers::seed_for_encoder`] takes it as a parameter at EVERY
    /// encoder build, because a user ceiling must survive a mid-session resize: the client sends
    /// its settings once after a hello and never again.
    #[must_use]
    pub(crate) fn user_bitrate_ceiling(&self) -> Option<i64> {
        self.extras().and_then(|extras| {
            let settings = extras.locked_settings();
            let ceiling = settings.bitrate_ceiling_bps;
            drop(settings);
            ceiling
        })
    }

    /// The client's live cadence cap, or `None` for auto.
    #[must_use]
    pub(crate) fn user_fps_cap(&self) -> Option<i64> {
        self.extras().and_then(|extras| {
            let settings = extras.locked_settings();
            let cap = settings.fps_cap;
            drop(settings);
            cap
        })
    }

    /// Replaces the user overrides wholesale, as a settings message does.
    pub(crate) fn store_user_settings(&self, fps_cap: Option<i64>, bitrate_ceiling_bps: Option<i64>) {
        let Some(extras) = self.extras() else {
            return;
        };
        let mut settings = extras.locked_settings();
        settings.fps_cap = fps_cap;
        settings.bitrate_ceiling_bps = bitrate_ceiling_bps;
        drop(settings);
    }

    /// Processes one drained batch.
    ///
    /// Consecutive `.input` datagrams decode into a RUN and collapse through the planner, so only
    /// the latest of each motion run is injected; a `.control` or `.recovery` datagram is a flush
    /// BOUNDARY — the pending run injects first, in arrival order, and only then is the boundary
    /// handled. That is what keeps down/up/key ordering and the button balance identical to the
    /// un-batched path: motion is the only class ever collapsed.
    ///
    /// The trailing flush runs even for an EMPTY run, because an empty plan is exactly the
    /// residual-drain path.
    pub(crate) fn receive_batch(self: &Arc<Self>, batch: &[(VideoChannel, Vec<u8>)]) {
        // CLIENT-SILENCE PAUSE liveness, before any decode: an arriving datagram proves the peer is
        // back whether or not it parses, and waiting to decode it would put a decode on the resume
        // path for no information.
        let now = self.now();
        let mut liveness = self.locked_liveness();
        let resuming = liveness.note_inbound(now);
        drop(liveness);
        if resuming && let Some(capture) = self.capture_stream() {
            capture.set_client_silence_paused(false);
        }

        // Gated on streaming exactly as `input_routing`'s own route is. Read ONCE per batch rather
        // than per datagram: the answer cannot change under this thread — the transitions that
        // flip it are control messages, which this same loop is the one to handle — and a state
        // lock per datagram was the receive path's only per-event lock besides the queue's.
        let flowing = {
            let state = self.locked_state();
            let flowing = state.media_flowing();
            drop(state);
            flowing
        };
        let mut run: Vec<InputEvent> = Vec::new();
        for (channel, datagram) in batch {
            match *channel {
                VideoChannel::Input => {
                    // Decoded HERE so the run can be coalesced. A malformed datagram is dropped; a
                    // corrupt single packet must never take the receiver down.
                    if !flowing {
                        continue;
                    }
                    if let Ok(event) = InputEvent::decode(datagram) {
                        run.push(event);
                    }
                },
                VideoChannel::Control => {
                    let pending = core::mem::take(&mut run);
                    self.inject_coalesced(&pending);
                    self.handle_control(datagram);
                },
                VideoChannel::Recovery => {
                    let pending = core::mem::take(&mut run);
                    self.inject_coalesced(&pending);
                    self.handle_recovery(datagram);
                },
                // Host→client channels. A client that sends one is ignored defensively.
                VideoChannel::Video | VideoChannel::Geometry | VideoChannel::Cursor | VideoChannel::Audio => {
                },
            }
        }
        self.inject_coalesced(&run);
    }

    /// Collapses an arrival-ordered run to its coalesced form and injects each event.
    ///
    /// The per-event raise latch is reproduced exactly: a button-down raises and focuses first, a
    /// coalesced motion run never does, and the latch advances BETWEEN events so a mouse-up re-arms
    /// it for the next interaction.
    ///
    /// With no injector the planner still advances — the scroll accumulator is time-gated state the
    /// wire keeps feeding — but the LATCH does not, mirroring the Swift's `guard let injector`
    /// returning before it touched `inputNeedsRaise`.
    fn inject_coalesced(self: &Arc<Self>, run: &[InputEvent]) {
        let Some(extras) = self.extras() else {
            return;
        };
        let now = self.now();
        let mut input = extras.locked_input();
        let planned = input.planner.plan(run, now);
        let pending = input.planner.has_pending_scroll();
        let injector = input.injector.clone();
        // Decided under the lock and POSTED outside it: the latch is per-event state, and a
        // `CGEventPost` under the lock would hold a teardown's injector clear for the length of a
        // window-server round trip.
        let mut posts: Vec<(InputEvent, bool)> = Vec::with_capacity(planned.len());
        for event in planned {
            let raise = injector.is_some() && input_routing::raise_first(&event, input.needs_raise);
            if injector.is_some() {
                if raise {
                    input.needs_raise = false;
                }
                if input_routing::rearm_raise_after(&event) {
                    input.needs_raise = true;
                }
            }
            posts.push((event, raise));
        }
        drop(input);
        extras.set_scroll_pending(pending);

        let Some(injector) = injector else {
            return;
        };
        for (event, raise) in posts {
            if raise {
                // FIRE-AND-FORGET, never awaited. The Swift's click-latency note is the whole
                // argument: an accessibility raise is several synchronous cross-process calls and
                // costs about a second against a slow target, while the posted event — not the
                // raise — is what actually delivers the click.
                injector.raise_target_window();
            }
            injector.inject(&event);
        }
    }

    /// Handles one control datagram.
    ///
    /// Every decision is [`slopdesk_video::session_state`]'s; the two things decided HERE are the
    /// ones the machine has no semantics for. `focusWindow` is a proactive raise and returns
    /// without consulting the machine at all, and a `bye` frees the pinned UDP flow after the
    /// machine's own effects have run.
    fn handle_control(self: &Arc<Self>, datagram: &[u8]) {
        let Ok(message) = VideoControlMessage::decode(datagram) else {
            return;
        };
        if matches!(message, VideoControlMessage::FocusWindow) {
            // The "raise the focused pane's window" model: bring the captured window frontmost ONCE
            // now, so the user's FIRST click lands instantly instead of paying the
            // activate-then-control stall. Idempotent on the far side, and only meaningful while
            // streaming, because that is when an injector exists.
            let flowing = {
                let state = self.locked_state();
                let flowing = state.media_flowing();
                drop(state);
                flowing
            };
            if !flowing {
                return;
            }
            if let Some(extras) = self.extras() {
                let mut input = extras.locked_input();
                let injector = input.injector.clone();
                if injector.is_some() {
                    // A following move, scroll or key need not re-raise.
                    input.needs_raise = false;
                }
                drop(input);
                if let Some(injector) = injector {
                    injector.raise_target_window();
                }
            }
            return;
        }

        let bounds = self.window_bounds_cg();
        let effects = {
            let mut state = self.locked_state();
            state.handle_control(
                &message,
                bounds,
                |requested, viewport| self.negotiated_capture_size(requested, viewport),
                |requested, desired| self.negotiated_resize_size(requested, desired),
                |requested, viewport| self.negotiated_display_size(requested, viewport),
            )
        };
        self.apply_effects(effects);
        if matches!(message, VideoControlMessage::Bye) {
            // A clean `bye` re-arms the session to listening and tears capture down, but UDP has no
            // FIN, so the pinned flow slot would stay pinned — and a reconnecting client arrives on
            // a NEW source port, a new four-tuple, silently refused at the listener until the
            // daemon restarts.
            self.transport.reset_client_flow();
        }
    }

    /// The capture size for a hello naming `requested`, or `None` when it names another window.
    ///
    /// Accepting only this session's own window is the whole check: one lane serves one target, and
    /// a hello for a different id is a client that has confused two panes.
    fn negotiated_capture_size(&self, requested: u32, viewport: VideoSize) -> Option<(u16, u16)> {
        if self.spec.target.window_id() != Some(requested) {
            return None;
        }
        self.resolve_capture_size(viewport)
    }

    /// The clamped POINT size for a client-driven resize, or `None` for a display session.
    ///
    /// A POLICY pre-clamp only — the achieved size is whatever the window server grants, and the
    /// resize path reads that back. The maximum is the parked window's recorded limit when it has
    /// one, so a resize cannot push the capture crop past the virtual display's framebuffer; else
    /// the wire's own 16-bit limit. A display never resizes, so it answers `None`.
    fn negotiated_resize_size(&self, requested: u32, desired: VideoSize) -> Option<(u16, u16)> {
        let Target::Window { id, resize_limit, .. } = self.spec.target else {
            return None;
        };
        if id != requested {
            return None;
        }
        let max = resize_limit.map_or_else(
            || VideoSize::new(f64::from(u16::MAX), f64::from(u16::MAX)),
            |(width, height)| VideoSize::new(width, height),
        );
        Some(clamp_capture_size(desired, VideoSize::new(1.0, 1.0), max))
    }

    /// The capture size for a display hello, or `None` when it names another display.
    ///
    /// A requested id of zero is "the main display": the daemon resolved the concrete target at
    /// mint, so any id that got this session minted matches.
    fn negotiated_display_size(&self, requested: u32, viewport: VideoSize) -> Option<(u16, u16)> {
        let Target::Display { id } = self.spec.target else {
            return None;
        };
        if requested != id && requested != 0 {
            return None;
        }
        self.resolve_capture_size(viewport)
    }

    /// The live capture stream, cloned out so every framework call below happens OUTSIDE the lock.
    ///
    /// One hold, one clone: a `set_governed_fps` made under the streaming lock would hold a
    /// bring-up or a teardown for the length of a window-server round trip.
    pub(crate) fn capture_stream(&self) -> Option<Arc<dyn CaptureStream>> {
        let streaming = self.locked_streaming();
        let capture = streaming
            .as_ref()
            .and_then(|live| live.live.capture.as_ref().map(Arc::clone));
        drop(streaming);
        capture
    }

    /// The live encoder, cloned out under the same discipline as [`Self::capture_stream`].
    pub(crate) fn encoder(&self) -> Option<Arc<Encoder>> {
        let streaming = self.locked_streaming();
        let encoder = streaming
            .as_ref()
            .and_then(|live| live.live.encode.as_ref().map(Arc::clone));
        drop(streaming);
        encoder
    }
}

/// The consumer: drain, upgrade, deliver, repeat.
///
/// The [`Weak`] is upgraded per drain rather than held, which is the Swift's `[weak self]`: a
/// session whose last handle has gone stops the pump on its next wake instead of being kept alive
/// by it.
fn pump_loop(session: &Weak<Session>, extras: &Arc<SessionExtras>) {
    while let Some(batch) = extras.drain() {
        let Some(session) = session.upgrade() else {
            return;
        };
        if batch.is_empty() {
            // The scroll idle flush: an empty-run plan IS the trailing-flush path, and the
            // planner's own gate decides whether the residual is due. See the module
            // note.
            session.inject_coalesced(&[]);
        } else {
            session.receive_batch(&batch);
        }
    }
}

/// The session's clock as the wire carries it: host-relative milliseconds, truncated to the wire's
/// 32-bit width.
///
/// The truncation is deliberate and its wrap is well-defined, which is what lets the round-trip
/// fold's wrap-aware subtraction stay correct across the roughly 49.7-day boundary. Both ends of
/// the RTT live in this one clock domain — see [`Session::now`].
pub(crate) fn host_relative_millis(session: &Session) -> u32 {
    let millis = session.now() * 1000.0;
    if !millis.is_finite() || millis < 0.0 {
        return 0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the wrap at the 32-bit boundary is the wire's own rule, not an accident"
    )]
    let whole = millis as i64;
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "truncating to the low 32 bits is exactly Swift's `truncatingIfNeeded`"
    )]
    let wrapped = whole as u32;
    wrapped
}

/// The recovery state accessors this file publishes to [`crate::session_actuate`], which owns the
/// only other path that touches them.
impl RecoveryState {
    /// Whether this datagram should be PROCESSED: true on a first sighting, false for one of the
    /// client's redundant copies.
    pub(crate) fn admit(&mut self, datagram: &[u8], now: f64) -> bool {
        self.deduper.admit(datagram, now)
    }

    /// Whether the host-stats echo is due, stamping it when it is.
    ///
    /// Asks and stamps in one call because the two must not be separable: a caller that checked and
    /// then decided not to send would leave the stamp advanced and skip the next window.
    pub(crate) fn host_stats_due(&mut self, now: f64, interval: f64) -> bool {
        if now - self.last_host_stats < interval {
            return false;
        }
        self.last_host_stats = now;
        true
    }
}

/// The extras' report-path knobs, published to [`crate::session_actuate`].
impl SessionExtras {
    /// Whether the adaptive-m parity ladder rules.
    pub(crate) const fn adaptive_m(&self) -> bool {
        self.adaptive_m
    }

    /// Whether the group-size ladder may relax to OFF.
    pub(crate) const fn fec_allow_off(&self) -> bool {
        self.fec_allow_off
    }

    /// The congestion tunables, which the FPS governor's evidence needs even with ABR off.
    pub(crate) const fn congestion_config(&self) -> CongestionConfig {
        self.congestion_config
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Weak;
    use std::sync::atomic::{AtomicU32, Ordering};

    use slopdesk_video::adaptive_fec::DEFAULT_TIER;
    use slopdesk_video::geometry::{VideoPoint, VideoSize};
    use slopdesk_video::host_gates::{GateContext, HostGates};
    use slopdesk_video::input_event::{InputEvent, InputModifiers, MouseButton, MouseButtonEvent};
    use slopdesk_video::recovery_idr::RecoveryIdrConfig;
    use slopdesk_video::session_state::{PROTOCOL_VERSION, VideoSessionStateMachine};
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{Arc, InputInjector, Mutex, PoisonError, Session, VideoChannel, host_relative_millis};
    use crate::env::Overlay;
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;
    use crate::session_wiring::{SessionSpec, Target};

    /// The two timings a live daemon resolves before it folds the gate table, spelled the way the
    /// rules crate spells them — a made-up pair would exercise a clamp that never runs.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    /// The window this session is minted for.
    const WINDOW: u32 = 4_242;

    /// A lane id nobody else in this process is using.
    ///
    /// The extras table is process-wide by construction — it replaces actor-isolated fields, and a
    /// lane id is what identifies one — so two tests sharing an id would share a pump. A counter
    /// rather than a literal per test, because the failure mode is a flake that appears only when
    /// the suite runs its threads in a different order.
    fn fresh_channel() -> u32 {
        static NEXT: AtomicU32 = AtomicU32::new(9_000);
        NEXT.fetch_add(1, Ordering::Relaxed)
    }

    /// A shared flow that records nothing and reaches no socket.
    #[derive(Debug, Default)]
    struct Flow;

    impl LaneControl for Flow {
        fn admit(&self, _channel_id: u32) {}

        fn retire(&self, _channel_id: u32) {}

        fn send(&self, _datagram: &[u8], _channel: VideoChannel, _channel_id: u32) {}
    }

    /// The registry's half of a lane's retirement, which a test session never consults.
    #[derive(Debug, Default)]
    struct Registry;

    impl LaneRetired for Registry {
        fn lane_retired(&self, _channel_id: u32) {}
    }

    /// An injector that records the exact order it was asked to act in.
    ///
    /// The ORDER is the assertion in every test below: coalescing, the raise latch and the button
    /// balance are all statements about a sequence, so a recorder that kept only counts would pass
    /// for the wrong reason.
    #[derive(Debug, Default)]
    struct Recorder {
        acted: Mutex<Vec<String>>,
    }

    impl Recorder {
        /// What was asked of it, in order.
        fn acted(&self) -> Vec<String> {
            self.acted.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        /// How many raises it was asked for.
        fn raises(&self) -> usize {
            self.acted().iter().filter(|entry| *entry == "raise").count()
        }
    }

    impl InputInjector for Recorder {
        fn inject(&self, event: &InputEvent) {
            self.acted
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(name(event));
        }

        fn balance(&self) -> super::HeldInput {
            super::HeldInput::default()
        }

        fn raise_target_window(&self) {
            self.acted
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push("raise".to_owned());
        }
    }

    /// One event's shape, as a test can assert on it.
    fn name(event: &InputEvent) -> String {
        match *event {
            InputEvent::MouseMove { .. } => "move".to_owned(),
            InputEvent::MouseDrag(..) => "drag".to_owned(),
            InputEvent::MouseDown(..) => "down".to_owned(),
            InputEvent::MouseUp(..) => "up".to_owned(),
            InputEvent::Scroll(..) => "scroll".to_owned(),
            InputEvent::Key(..) => "key".to_owned(),
            InputEvent::Text(..) => "text".to_owned(),
        }
    }

    /// A listening session over a lane with no socket under it.
    ///
    /// The registry handle rides back with it because the lane holds only a [`Weak`] to it, and a
    /// dropped registry would make every retirement a no-op for a reason the test did not choose.
    fn session() -> (Arc<Session>, Arc<Registry>) {
        let registry = Arc::new(Registry);
        // The unsizing happens at this typed binding, not inside `downgrade`. `registry` is
        // returned to the caller, so the allocation outlives the strong handle dropped here.
        let watcher: Arc<dyn LaneRetired> = registry.clone();
        let observer: Weak<dyn LaneRetired> = Arc::downgrade(&watcher);
        let flow: Arc<dyn LaneControl> = Arc::new(Flow);
        let transport = Arc::new(MuxLaneTransport::new(
            fresh_channel(),
            flow,
            Arc::new(MuxSinkTable::new()),
            observer,
        ));
        let mut gates = HostGates::from_env(&[], CONTEXT);
        // The paced drain owns a thread of its own and none of these tests is about pacing.
        gates.send_lane_enabled = false;
        let session = Arc::new(Session::new(
            SessionSpec {
                target: Target::Window {
                    id: WINDOW,
                    pid: 99,
                    size_override: Some((640.0, 480.0)),
                    resize_limit: Some((800.0, 600.0)),
                },
                capture_scale: 1.0,
                bitrate: 8_000_000,
                fps: 60,
            },
            transport,
            gates,
            RecoveryIdrConfig::default(),
            Overlay::default(),
            VideoSessionStateMachine::new(1, false),
        ));
        (session, registry)
    }

    /// Puts the session's MACHINE into streaming without bringing a framework up.
    ///
    /// The effects are discarded on purpose: applying them would start an `SCStream`, and every
    /// property under test here is about what the inbound path does once the media gate is OPEN,
    /// not about what capture does behind it.
    fn open_the_media_gate(session: &Arc<Session>) {
        let hello = VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: WINDOW,
            viewport: VideoSize::new(640.0, 480.0),
        };
        let mut state = session.locked_state();
        // A hello is only accepted from LISTENING, and the machine this fixture built is still
        // Idle: production reaches Listening through `Session::start`, which also binds sockets.
        let _listening = state.start();
        let effects = state.handle_control(
            &hello,
            slopdesk_video::geometry::VideoRect::new(VideoPoint::new(0.0, 0.0), VideoSize::new(640.0, 480.0)),
            |_, _| Some((640, 480)),
            |_, _| None,
            |_, _| None,
        );
        drop(state);
        drop(effects);
        assert!(
            session.locked_state().media_flowing(),
            "the fixture must open the gate"
        );
    }

    /// Installs a recorder as the session's injector, answering it so a test can read the order.
    fn recorder(session: &Arc<Session>) -> Arc<Recorder> {
        let recorder = Arc::new(Recorder::default());
        let injector: Arc<dyn InputInjector> = recorder.clone();
        session.set_input_injector(Some(injector));
        recorder
    }

    /// A pointer move, as the wire carries one.
    fn pointer(x: f64) -> InputEvent {
        InputEvent::MouseMove {
            normalized: VideoPoint::new(x, 0.5),
            tag: 0,
        }
    }

    /// A mouse button payload, shared by every down and up below.
    fn button() -> MouseButtonEvent {
        MouseButtonEvent {
            button: MouseButton::Left,
            normalized: VideoPoint::new(0.5, 0.5),
            click_count: 1,
            modifiers: InputModifiers::default(),
        }
    }

    #[test]
    fn building_the_sink_brings_the_pump_up_and_the_stop_leaves_nothing_behind() {
        let (session, _registry) = session();
        let sink = session.lane_sink();
        assert!(
            session.extras().is_some(),
            "the hello races the mint, so the pump must exist by the time the sink is handed back"
        );
        drop(sink);
        session.stop_inbound();
        assert!(
            session.extras().is_none(),
            "a later lane with the same id must not inherit this one's queue"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_second_sink_retires_the_first_pump_rather_than_running_two_threads_on_one_session() {
        let (session, _registry) = session();
        let first = session.lane_sink();
        let second = session.lane_sink();
        assert!(session.extras().is_some());
        drop((first, second));
        session.stop_inbound();
    }

    #[test]
    fn the_pump_delivers_everything_the_sink_is_handed_and_stops_when_it_is_told_to() {
        let (session, _registry) = session();
        open_the_media_gate(&session);
        let sink = session.lane_sink();
        let recorder = recorder(&session);
        for step in 0..64_u32 {
            sink(VideoChannel::Input, &pointer(f64::from(step) / 100.0).encode());
        }
        session.stop_inbound();
        assert!(
            session.extras().is_none(),
            "the stop retires the table entry and the thread"
        );
        assert!(
            recorder.acted().len() <= 64,
            "a coalescing pump may inject fewer than it was handed — never more"
        );
    }

    #[test]
    fn a_motion_run_collapses_to_its_latest_while_every_button_event_survives() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.inject_coalesced(&[
            pointer(0.1),
            pointer(0.2),
            pointer(0.3),
            InputEvent::MouseDown(button(), 0),
            InputEvent::MouseUp(button(), 0),
        ]);
        let acted = recorder.acted();
        assert_eq!(
            acted.iter().filter(|entry| *entry == "move").count(),
            1,
            "a motion run must collapse to its latest, or the window server saturates"
        );
        let down = acted.iter().position(|entry| entry == "down");
        let up = acted.iter().position(|entry| entry == "up");
        assert!(
            down.is_some() && up.is_some(),
            "every down and up must survive the collapse"
        );
        assert!(down < up, "and the run must inject in strict arrival order");
        session.stop_inbound();
    }

    #[test]
    fn a_button_down_raises_first_and_a_following_move_does_not_raise_again() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.inject_coalesced(&[InputEvent::MouseDown(button(), 0)]);
        session.inject_coalesced(&[pointer(0.9)]);
        assert_eq!(
            recorder.acted().first().map(String::as_str),
            Some("raise"),
            "the raise comes before the post it belongs to"
        );
        assert_eq!(
            recorder.raises(),
            1,
            "one interaction pays for at most one raise — the whole click-latency argument"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_mouse_up_rearms_the_latch_so_the_next_interaction_raises_and_focuses_again() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.inject_coalesced(&[
            InputEvent::MouseDown(button(), 0),
            InputEvent::MouseUp(button(), 0),
        ]);
        session.inject_coalesced(&[InputEvent::MouseDown(button(), 0)]);
        assert_eq!(
            recorder.raises(),
            2,
            "a mouse-up ends the interaction, so the NEXT one must raise and focus again"
        );
        session.stop_inbound();
    }

    #[test]
    fn an_absent_injector_posts_nothing_and_leaves_the_raise_latch_armed() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        // Planned with no injector: the accumulator advances, the LATCH does not — the Swift's
        // `guard let injector` returned before it touched `inputNeedsRaise`.
        session.inject_coalesced(&[pointer(0.1), InputEvent::MouseUp(button(), 0)]);
        let recorder = recorder(&session);
        session.inject_coalesced(&[InputEvent::MouseDown(button(), 0)]);
        assert_eq!(
            recorder.acted().first().map(String::as_str),
            Some("raise"),
            "the first event a real injector sees must still raise"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_control_datagram_is_a_flush_boundary_for_the_input_run_before_it() {
        let (session, _registry) = session();
        open_the_media_gate(&session);
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.receive_batch(&[
            (VideoChannel::Input, InputEvent::MouseDown(button(), 0).encode()),
            // Undecodable, so the boundary is all this datagram contributes — which is the point:
            // a boundary flushes whether or not the message behind it means anything.
            (VideoChannel::Control, vec![0xFF]),
            (VideoChannel::Input, InputEvent::MouseUp(button(), 0).encode()),
        ]);
        assert_eq!(
            recorder
                .acted()
                .into_iter()
                .filter(|entry| entry == "down" || entry == "up")
                .collect::<Vec<String>>(),
            vec!["down".to_owned(), "up".to_owned()],
            "the run before the boundary injects first, in arrival order, and the run after follows"
        );
        session.stop_inbound();
    }

    #[test]
    fn input_that_arrives_before_a_hello_is_dropped_at_the_media_gate() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.receive_batch(&[(VideoChannel::Input, InputEvent::MouseDown(button(), 0).encode())]);
        assert!(
            recorder.acted().is_empty(),
            "a client that still believes its session is live must not reach the window server"
        );
        session.stop_inbound();
    }

    #[test]
    fn an_undecodable_input_datagram_is_dropped_and_the_rest_of_the_batch_carries_on() {
        let (session, _registry) = session();
        open_the_media_gate(&session);
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.receive_batch(&[
            (VideoChannel::Input, vec![0xFF, 0x00]),
            (VideoChannel::Input, InputEvent::MouseDown(button(), 0).encode()),
            // Host→client channels, ignored defensively rather than trusted.
            (VideoChannel::Video, vec![1, 2, 3]),
            (VideoChannel::Cursor, vec![4]),
            (VideoChannel::Geometry, vec![5]),
            (VideoChannel::Audio, vec![6]),
        ]);
        assert!(
            recorder.acted().contains(&"down".to_owned()),
            "one corrupt datagram must never cost the batch behind it"
        );
        session.stop_inbound();
    }

    #[test]
    fn any_inbound_datagram_resumes_paused_video_before_it_is_decoded() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let mut liveness = session.locked_liveness();
        liveness.saw_feedback = true;
        liveness.paused = true;
        liveness.last_inbound = 0.0;
        drop(liveness);

        session.receive_batch(&[(VideoChannel::Input, vec![0xFF])]);
        let liveness = session.locked_liveness();
        let paused = liveness.paused;
        drop(liveness);
        assert!(
            !paused,
            "an arriving datagram proves the peer is back whether or not it parses"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_client_silence_pause_re_latches_only_after_the_client_goes_quiet_again() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        session.receive_batch(&[(VideoChannel::Input, vec![0xFF])]);
        let liveness = session.locked_liveness();
        let pauses_without_evidence = liveness.should_pause(liveness.last_inbound + 10_000.0, 5.0);
        drop(liveness);
        assert!(
            !pauses_without_evidence,
            "a client that never reported must never be paused, however long it is quiet"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_bye_frees_the_pinned_flow_so_a_reconnect_can_re_pin_without_a_daemon_restart() {
        let (session, _registry) = session();
        open_the_media_gate(&session);
        let _sink = session.lane_sink();
        session.receive_batch(&[(VideoChannel::Control, VideoControlMessage::Bye.encode())]);
        assert!(
            !session.locked_state().media_flowing(),
            "a clean bye re-arms the session to listening"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_focus_window_message_raises_once_and_asks_the_machine_nothing() {
        let (session, _registry) = session();
        open_the_media_gate(&session);
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.receive_batch(&[(VideoChannel::Control, VideoControlMessage::FocusWindow.encode())]);
        assert_eq!(
            recorder.acted(),
            vec!["raise".to_owned()],
            "a proactive raise and nothing else"
        );
        // The latch it cleared spares a following MOVE, scroll or key the raise. A button-down is
        // not spared: `input_routing::always_raises` fires it regardless of the latch, so the seam
        // is asked twice. The two collapse into ONE accessibility chain a layer lower, at the raise
        // pump's own `RAISE_THROTTLE` — the Swift coalesced in exactly that place and not here.
        session.inject_coalesced(&[InputEvent::MouseDown(button(), 0)]);
        assert_eq!(
            recorder.raises(),
            2,
            "a button-down always asks; the pump's throttle, not this seam, is what coalesces"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_focus_window_message_before_a_hello_raises_nothing() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        let recorder = recorder(&session);
        session.receive_batch(&[(VideoChannel::Control, VideoControlMessage::FocusWindow.encode())]);
        assert!(
            recorder.acted().is_empty(),
            "the raise is only meaningful while streaming, because that is when an injector exists"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_resize_is_clamped_to_the_parked_windows_recorded_limit_and_refused_for_another_pane() {
        let (session, _registry) = session();
        assert_eq!(
            session.negotiated_resize_size(WINDOW, VideoSize::new(4_000.0, 4_000.0)),
            Some((800, 600)),
            "a resize past the virtual display's framebuffer would push the capture crop off it"
        );
        assert_eq!(
            session.negotiated_resize_size(WINDOW, VideoSize::new(0.0, 0.0)),
            Some((1, 1)),
            "and the floor is one point, because a zero divides by zero in the client's aspect fit"
        );
        assert!(
            session
                .negotiated_resize_size(7, VideoSize::new(100.0, 100.0))
                .is_none(),
            "a resize naming another pane's window must be refused, not applied to this one"
        );
    }

    #[test]
    fn a_window_session_answers_its_own_hello_and_refuses_every_other_targets() {
        let (session, _registry) = session();
        assert_eq!(
            session.negotiated_capture_size(WINDOW, VideoSize::new(10.0, 10.0)),
            Some((640, 480)),
            "the mint's recorded post-move size outranks the enumeration snapshot"
        );
        assert!(
            session
                .negotiated_capture_size(1, VideoSize::new(10.0, 10.0))
                .is_none(),
            "a hello for another window is a client that has confused two panes"
        );
        assert!(
            session
                .negotiated_display_size(0, VideoSize::new(10.0, 10.0))
                .is_none(),
            "a window session has no display to answer for"
        );
    }

    #[test]
    fn the_user_overrides_are_replaced_wholesale_by_every_settings_message() {
        let (session, _registry) = session();
        let _sink = session.lane_sink();
        assert_eq!(
            session.user_bitrate_ceiling(),
            None,
            "auto until the client says otherwise"
        );
        session.store_user_settings(Some(30), Some(6_000_000));
        assert_eq!(
            (session.user_fps_cap(), session.user_bitrate_ceiling()),
            (Some(30), Some(6_000_000))
        );
        session.store_user_settings(None, None);
        assert_eq!(
            (session.user_fps_cap(), session.user_bitrate_ceiling()),
            (None, None),
            "a second message REPLACES the first — both axes, every time"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_fec_tier_reads_as_the_byte_identical_baseline_before_any_report_arrives() {
        let (session, _registry) = session();
        assert_eq!(
            session.fec_tier_state().tier,
            DEFAULT_TIER,
            "a session with no feedback yet must packetize exactly as an un-adaptive one does"
        );
        assert!(!session.adaptive_m_enabled(), "the parity ladder is opt-in");
    }

    #[test]
    fn every_accessor_answers_without_a_lane_and_none_of_them_panics() {
        let (session, _registry) = session();
        session.set_input_injector(None);
        session.store_user_settings(Some(20), Some(1_000_000));
        assert_eq!(
            session.user_fps_cap(),
            None,
            "a stopped pump has no state to store an override on"
        );
        session.inject_coalesced(&[pointer(0.1)]);
        assert!(session.capture_stream().is_none());
        assert!(session.encoder().is_none());
    }

    #[test]
    fn the_wire_clock_starts_at_zero_and_never_reads_negative() {
        let (session, _registry) = session();
        assert!(
            host_relative_millis(&session) < 1_000,
            "a session that has just been built is at the start of its own clock"
        );
    }
}
