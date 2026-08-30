//! One client's session: the composition, the lifetime, and the order the pieces come up in.
//!
//! Replaces the composition half of the Swift host's session actor — 3728 lines of which this file
//! keeps the part that is genuinely a session: what exists, what owns what, and what has to happen
//! before what. The state it holds is [`crate::session_wiring`]'s; the decisions it takes are
//! [`slopdesk_video`]'s; the effects it applies belong to the modules named in [`crate`]'s map.
//! What is left here is the join.
//!
//! ## The one thing this file is for
//! A session is FIVE independent lifetimes that must start and stop in one order: the inbound
//! pump, the capture stream, the encoder, the send lane, and the assertions a streaming desktop
//! holds (display wake, privacy blank, audio gate). The Swift kept that order in an actor's
//! sequential inbox. There is no inbox here, so the order is written down — [`Session::start`],
//! [`Session::stop`] and [`Session::apply_effect`] are the three places it lives, and nothing
//! else in the crate reorders them.
//!
//! ## The state machine is not here
//! `VideoSessionLogic.swift` looked like 929 lines of session logic and was a FACE:
//! `SLOPDESK_VIDEO_SESSION_*` and `SlopDeskVideoSessionEffect` are C spellings of
//! [`slopdesk_video::session_state`], which has held the real machine all along. So this file
//! never decides whether a hello is accepted, what size to negotiate, or which effects a message
//! produces — it calls [`VideoSessionStateMachine::handle_control`] and APPLIES what comes back.
//! A `match` in [`Session::apply_effect`] with a branch that decided something would be the bug
//! this note exists to catch.
//!
//! ## Two pumps in the Swift, one here
//! The Swift ran the inbound datagrams and the encoded frames through a queue-plus-wakeup pair
//! each, for the same reason: an `actor` reorders anything that `await`s into it, so a `mouseUp`
//! could overtake its `mouseDown` and stick a button down, and a frame could be assigned an id
//! out of encode order.
//!
//! Only ONE of those reasons survives the port.
//!
//! * **Inbound keeps its queue and its thread.** Not for ordering — the mux receive loop is already
//!   serial — but because the queue is where COALESCING happens: a pointer-motion run collapses to
//!   its latest only if a run has had a chance to pile up. Injecting inline on the receive thread
//!   would make a slow `CGEventPost` back-pressure the socket, and the datagrams that then drop are
//!   dropped by the kernel, which cannot collapse them.
//! * **Encoded frames lost theirs.** `VideoToolbox` calls back on its own SERIAL queue, so encode
//!   order is already the call order; the Swift queue existed only to re-serialise what the actor
//!   hop had scrambled. With no actor, [`crate::encode::EncodedFrameSink`] runs on the framework's
//!   thread and the pump is that call — one queue, one wakeup and one thread hop per frame deleted,
//!   off the path between the encoder and the wire.
//!
//! ## The clock
//! [`Session::epoch`] is constructed ONCE and handed to everything that stamps a timestamp — the
//! fragment headers, the audio lane, the heartbeat, the liveness window. A second `Instant::now()`
//! anywhere below would put two timelines a start-up delay apart, which is a wire bug no gate on
//! either side of the link can see.
//!
//! ⚠️ GUI + TCC ONLY below [`Session::apply_effect`]'s capture arms.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use slopdesk_video::adaptive_fec::multi_loss;
use slopdesk_video::cursor::CursorChannelMessage;
use slopdesk_video::fec::ReedSolomonFec;
use slopdesk_video::geometry::{VideoRect, VideoSize};
use slopdesk_video::host_gates::HostGates;
use slopdesk_video::recovery_idr::RecoveryIdrConfig;
use slopdesk_video::recovery_routing::{VideoChannel, schedule_control};
use slopdesk_video::session_state::{SessionEffect, VideoSessionStateMachine};
use slopdesk_video::swipe_nav_config::{NavHistoryFlags, SwipeNavHostConfig};
use slopdesk_video::video_control::VideoControlMessage;

use crate::encode::Encoder;
use crate::env::Overlay;
use crate::mux_lane::MuxLaneTransport;
use crate::mux_registry::LaneSession;
use crate::packetize::PacketizeLane;
use crate::privacy::{HostGamma, PrivacyBlank};
use crate::sendlane::{DatagramSink, RetransmitLog, VideoSendLane};
use crate::session_inbound::adaptive_m_enabled;
use crate::session_wiring::{ClientLiveness, Controllers, FrameCounters, Live, SessionSpec, Target};

/// What the session needs from a live capture stream.
///
/// A trait rather than the concrete [`crate::capture::Capturer`] for one reason: the session
/// SWAPS the stream under a resize, and the swap is guarded by
/// [`crate::session_wiring::Live`]'s generation counter, which holds its members behind an
/// [`Arc`]. Everything below therefore takes `&self` — the stream's own interior state is its
/// business, and a `&mut` here would mean the session had to own the only handle at exactly the
/// moment two threads need one.
///
/// The doors from [`Self::set_self_heal_eligible`] down carry an INERT default. Each of them is a
/// framework act only a live `LiveCapture` — [`crate::session_capture`]'s own — can honour, a
/// rebuild's hand-over above all — and a double that models the session's view of a stream rather
/// than the stream itself is right to inherit the answer that changes nothing. A default that LIED
/// would be a different thing entirely, which is why every one of them either does nothing or says
/// `None`.
pub trait CaptureStream: Send + Sync + core::fmt::Debug {
    /// Stops the stream. Idempotent — a reap, a `bye` and a resize rollback can all reach it.
    fn stop(&self);
    /// Opens or closes the audio tap's forwarding gate, without touching the stream itself.
    fn set_audio_forwarding(&self, enabled: bool);
    /// The content cadence the FPS governor settled on.
    fn set_governed_fps(&self, fps: i32);
    /// Whether frames should stop reaching the encoder because the client has gone silent.
    fn set_client_silence_paused(&self, paused: bool);
    /// Asks for a keyframe at the next opportunity.
    fn request_keyframe(&self);
    /// Asks for a long-term-reference refresh at the next opportunity.
    fn request_ltr_refresh(&self);

    /// Whether the capturer's self-heal cadence may still fire.
    ///
    /// Client LTR acks are what arm it, so this moves on the encoded-keyframe arm rather than on a
    /// report; see [`crate::session_pump`].
    fn set_self_heal_eligible(&self, eligible: bool) {
        let _ = eligible;
    }

    /// The freshly folded loss EWMA, for the capturer's CLEAN-LINK self-heal gate.
    ///
    /// Consulted only while that gate is on, and only under it: on a loss-free link the periodic
    /// refresh doublet buys nothing, so the gate suppresses it and this is what re-arms the moment
    /// loss appears. Pushed from the report fold, at the client's report clock — see
    /// [`crate::session_actuate`]. High (infinite) before the first report, which is the capturer's
    /// own default and the reason an unmeasured link never suppresses healing.
    fn set_self_heal_loss_rate(&self, rate: f64) {
        let _ = rate;
    }

    /// The capturer's encode wall-time EWMA in MILLISECONDS, for the stats HUD's second half.
    ///
    /// `0.0` is the wire's own spelling of "no reading yet" — a client renders the encode half
    /// blank rather than being told a number nobody measured — so it is what the default answers
    /// and what a session with no capture stream sends.
    fn encode_millis_ewma(&self) -> f64 {
        0.0
    }

    /// The audio lane this stream forwards into, if the capture gate opened one.
    ///
    /// The one piece of a live set that is SESSION-lifetime rather than capture-lifetime: the
    /// tag-6 sequence it stamps is monotone across capturer rebuilds, and the client LATE-DROPS on
    /// that counter — so a resize that respawned the lane would reset the sequence mid-session and
    /// the client would silently discard every packet after it. A rebuild therefore reads the lane
    /// out here and carries it into the successor, and [`crate::session_pump`]'s capture pump needs
    /// it one step BEFORE a capturer exists, which is why it is a door of its own rather than
    /// something [`Self::hand_over`] could keep to itself.
    fn audio_lane(&self) -> Option<Arc<crate::audio::AudioSender>> {
        None
    }

    /// Mints the successor set over `capturer` and retires this one's capture half.
    ///
    /// The two halves are ONE act, which is why they are one door: after this returns, this set no
    /// longer captures and the successor owns everything of it that outlives a resize — see
    /// [`Self::audio_lane`]. Answers `None` when this stream cannot be succeeded, in which case
    /// nothing was stopped and `capturer` is dropped un-started.
    ///
    /// The successor is NOT started and NOT armed: the caller installs it under the generation
    /// first, because a stream started before its install is one a supersede cannot reclaim.
    fn hand_over(&self, capturer: crate::capture::Capturer) -> Option<Arc<dyn CaptureStream>> {
        // Explicitly, not `let _ =`: a `Capturer` has a destructor, and the whole point of the
        // `None` arm is that the un-started stream is torn down HERE rather than surviving
        // as a leak.
        drop(capturer);
        None
    }

    /// Stops the capture half of this set, and only that half.
    ///
    /// Deliberately NOT [`Self::stop`]: a set that has already been handed over lent its audio lane
    /// to its successor, so tearing an orphaned rebuild down through the full stop would silence
    /// the lane the LIVE set is sending on. Idempotent, like every other stop here.
    fn stop_capture_only(&self) {}

    /// Arms this set's heartbeat against `session`.
    ///
    /// Called AFTER the install, for the reason `session_capture`'s step 11 gives: the tick pushes
    /// into whatever capture stream is installed. A set that was never installed is never armed,
    /// which is what stops an abandoned rebuild from leaving a tick behind.
    fn arm_heartbeat(&self, session: &Arc<Session>) {
        let _ = session;
    }

    /// Re-origins a display-anchored crop after the tracked window MOVED.
    ///
    /// `window_origin` is the window's frame origin in GLOBAL CG points. The geometry watcher's
    /// sink calls this on every move it publishes; the capturer coalesces, refuses on a union crop,
    /// and no-ops in per-window mode — see [`crate::capture::Capturer::reanchor`], which owns every
    /// one of those verdicts.
    ///
    /// ⚠️ BLOCKS on the framework while it is the driver, so it is called from the watcher's own
    /// thread and never from the frame queue.
    fn reanchor(&self, window_origin: slopdesk_video::geometry::VideoPoint) {
        let _ = window_origin;
    }

    /// Whether this capture crops a DISPLAY rather than tracking a window object.
    ///
    /// Read before a re-anchor is worth attempting at all: per-window mode has no crop to move, so
    /// a session in it skips the call rather than paying a lock and a framework refusal per poll.
    fn is_display_anchored(&self) -> bool {
        false
    }

    /// Whether the crop is a dialog-expand UNION region rather than the plain window frame.
    ///
    /// A union crop is the geometry poller's own, so a window move must NOT re-anchor it — the
    /// region is re-decided by the next region sample instead. `false` is the honest default for a
    /// double that models no crop at all.
    fn is_union_anchored(&self) -> bool {
        false
    }
}

/// The live half of a session: what only exists while a client is streaming.
///
/// Separate from [`Session`] so that the difference between "listening" and "streaming" is a
/// value, not a scatter of `Option` fields checked one at a time. A session that has not accepted
/// a hello holds `None` here and nothing below it can be half-built.
#[derive(Debug)]
pub struct Streaming {
    /// The capture stream and the encoder it feeds, under one generation.
    pub live: Live<dyn CaptureStream, Encoder>,
    /// Whether this session is holding the host's display awake. Only a display target ever does.
    pub holds_display_wake: bool,
    /// The client's latched audio wish. Reset to `false` on every capture bring-up, because the
    /// client re-sends it after each accepted hello.
    pub audio_enabled: bool,
    /// The 30 Hz window-frame poller, or `None` for a DISPLAY target — a display never moves and
    /// never resizes, so there is nothing to watch.
    ///
    /// Deliberately NOT inside [`Live`]: a resize replaces the capture stream and the encoder as a
    /// SET, and the watcher is watching the same window either way. Rebuilding it there would
    /// restart a poll cadence and re-publish a `Bounds` the client already has.
    pub geometry: Option<crate::session_geometry::LiveGeometry>,
    /// The 120 Hz cursor sampler, for as long as this session streams.
    ///
    /// `None` only when the thread could not be started. Outside [`Live`] for the watcher's reason,
    /// and additionally because the shape inventory it holds is what makes a client's re-ship
    /// request answerable — a rebuild that reset it would re-ship every cursor the session had
    /// already sent.
    pub cursor: Option<crate::session_geometry::LiveCursor>,
    /// The DIALOG-EXPAND crop this session is currently captured at, and the bookkeeping that
    /// keeps two region rebuilds from overlapping.
    pub region: crate::session_geometry::RegionState,
}

/// One client's video session over one mux lane.
///
/// Held behind an [`Arc`] by the registry and by every thread the session starts, which is why
/// each mutable part is behind its own lock rather than the whole thing behind one: the encoder
/// pump takes [`Session::counters`] on every frame and must not wait on a resize holding
/// [`Session::state`].
#[derive(Debug)]
pub struct Session {
    /// What the mint fixed and nothing changes: the target, the scale, and the launch bitrate and
    /// frame rate.
    pub(crate) spec: SessionSpec,
    /// The session's ONE clock. See the module note — every timestamp on the wire is relative to
    /// this instant, on every channel.
    pub(crate) epoch: Instant,
    /// The gate table, resolved once at mint through the settings overlay. There is no live
    /// reload; `just host-restart` is the reload.
    pub(crate) gates: HostGates,
    /// The settings overlay every knob below resolves through, kept because the encoder and the
    /// audio lane resolve theirs at BUILD time and a session outlives several builds.
    pub(crate) overlay: Overlay,
    /// This session's lane on the one shared flow.
    pub(crate) transport: Arc<MuxLaneTransport>,
    /// The pure machine. Every control message goes through it and every effect comes out of it.
    pub(crate) state: Mutex<VideoSessionStateMachine>,
    /// The rate, quantiser, frame-rate and reference controllers, as one lock.
    ///
    /// One lock and not four because they are actuated TOGETHER: a feedback report drives the
    /// congestion controller, whose target the QP ladder reads, whose verdict the governor reads.
    /// Four locks would let a second report interleave between two of those reads and actuate a
    /// bitrate the quantiser was never told about.
    pub(crate) controllers: Mutex<Controllers>,
    /// The per-frame counters the encoder pump owns: frames out, and the keyframe duplication
    /// window.
    pub(crate) counters: Mutex<FrameCounters>,
    /// When the client was last heard from, and whether video is paused for its silence.
    pub(crate) liveness: Mutex<ClientLiveness>,
    /// The live components, or `None` while the session is listening.
    pub(crate) streaming: Mutex<Option<Streaming>>,
    /// The host's privacy blank: `Some` from the first wish that engages one, `None` before that
    /// and after the teardown takes it.
    ///
    /// Its own lock, NOT a field inside [`Streaming`], and the difference is the whole
    /// teardown-race answer. Two threads reach it — the inbound pump applying the client's wish,
    /// and whichever of `bye`, reap or shutdown tears the session down — and the loss the ordering
    /// prevents is a blank ENGAGED after the teardown has already restored, which would leave the
    /// host's screen dark with nothing left alive to light it again.
    /// [`Session::apply_privacy_mode`] holds this lock across its "is the session still streaming"
    /// check for exactly that reason; `teardown_live`'s step 3 takes the value out under the same
    /// lock and disengages it. See both — neither half is the answer alone.
    pub(crate) privacy: Mutex<Option<PrivacyBlank<HostGamma>>>,
    /// One encoded frame into datagrams, FEC and all.
    pub(crate) packetize: PacketizeLane,
    /// The paced drain. `None` when `SLOPDESK_SEND_LANE=0` pins the operator to the inline path.
    pub(crate) send_lane: Option<VideoSendLane>,
    /// What a NACK can still be answered from. `None` when the gate disables retransmission.
    pub(crate) retransmit: Option<RetransmitLog>,
    /// Set once, by whichever of `bye`, reap or shutdown reaches [`Session::stop`] first.
    ///
    /// The teardown below touches a framework, a thread and a socket, and doing any of that twice
    /// is a use-after-free in one of three libraries. An `AtomicBool` rather than a flag inside a
    /// lock because `stop` must be answerable while another thread holds any of them.
    pub(crate) stopped: AtomicBool,
}

/// The codec this session packetizes with, resolved from `SLOPDESK_FEC_K` / `SLOPDESK_FEC_M`.
///
/// The host used to pin [`ReedSolomonFec::default`] here, and that made `SLOPDESK_FEC_M` a
/// CLIENT-ONLY key on a wire both ends have to read the same way. The client's
/// `AdaptiveFECPolicy.MultiLoss` resolved it from its own environment and mapped the parity
/// boundary of every group at that `m`; this end kept emitting one parity shard per group. The
/// reassembler takes `parity_shards_per_group` from its OWN configured scheme and never off the
/// wire — deliberately, since `m` is not a wire field — so the disagreement is silent in the worst
/// way available: nothing fails to decode and nothing logs, repairs simply stop happening. Reading
/// the same two keys here is what makes multi-loss's **DEPLOY TOGETHER** note
/// ([`multi_loss`](slopdesk_video::adaptive_fec::multi_loss)) something an operator can obey at
/// all.
///
/// Unset is byte-identical to what shipped, which is the property that lets this land without a
/// fleet step: `resolve_group_size(None, None)` is `DEFAULT_K` = 5 and `resolve_parity_count(None)`
/// is `DEFAULT_M` = 1, and that pair IS [`ReedSolomonFec::default`].
///
/// Resolution, clamping and the GF(2^8) `k + m <= 255` cap are `multi_loss`'s, asked for rather
/// than restated: both ends call the same two functions, and a second clamp here is exactly the
/// kind of near-agreement that puts a host and a client one shard apart with both configs looking
/// correct.
fn configured_fec(overlay: &Overlay) -> ReedSolomonFec {
    let m = overlay.get("SLOPDESK_FEC_M");
    let k = overlay.get("SLOPDESK_FEC_K");
    ReedSolomonFec::new(
        multi_loss::resolve_group_size(k.as_deref(), m.as_deref()),
        multi_loss::resolve_parity_count(m.as_deref()),
    )
}

impl Session {
    /// Builds a listening session for one lane.
    ///
    /// Nothing is captured and nothing is encoded yet: capture starts only when the state machine
    /// accepts a hello, so a client that connects and says nothing never spins up an `SCStream`.
    #[must_use]
    pub fn new(
        spec: SessionSpec,
        transport: Arc<MuxLaneTransport>,
        gates: HostGates,
        recovery_idr: RecoveryIdrConfig,
        overlay: Overlay,
        state: VideoSessionStateMachine,
    ) -> Self {
        // The lane is what the send lane writes to, so the sink is taken before `transport` moves
        // into the struct. One `Arc`, two owners, and the lane's own thread outlives neither.
        let sink: Arc<dyn DatagramSink> = transport.clone();
        Self {
            spec,
            // Stamped here and NOWHERE else — see the module note on the clock.
            epoch: Instant::now(),
            state: Mutex::new(state),
            controllers: Mutex::new(Controllers::new(recovery_idr, adaptive_m_enabled(&overlay))),
            counters: Mutex::new(FrameCounters::default()),
            // Zero, because the liveness window is measured in seconds since `epoch` and `epoch`
            // is the instant above: the session starts at time zero on its own clock.
            liveness: Mutex::new(ClientLiveness::starting_at(0.0)),
            streaming: Mutex::new(None),
            // Nothing is darkened until a client asks: a session that never sends `PrivacyMode`
            // never constructs a blank, so there is nothing for its teardown to restore either.
            privacy: Mutex::new(None),
            // `fec_disabled` is the gate's own spelling of "data fragments only", which is what a
            // `None` scheme means to the packetizer — asked rather than restated.
            packetize: PacketizeLane::new((!gates.fec_disabled).then(|| configured_fec(&overlay))),
            send_lane: gates.send_lane_enabled.then(|| VideoSendLane::new(sink)),
            // Both bounds are GATES, not constants here. The frame count bounds what a client can
            // still name and the byte ceiling is what actually holds the memory down — sixteen 4K
            // keyframes is tens of megabytes, and this log answers a lost fragment, not a GOP.
            retransmit: gates.nack_enabled.then(|| {
                RetransmitLog::new(
                    usize::try_from(gates.retransmit_ring_frames).unwrap_or_default(),
                    usize::try_from(gates.retransmit_ring_max_bytes).unwrap_or_default(),
                )
            }),
            stopped: AtomicBool::new(false),
            transport,
            gates,
            overlay,
        }
    }

    /// Seconds since this session's [`Session::epoch`] — the one clock every timestamp below is
    /// relative to, and the shape every rule in [`slopdesk_video`] takes its `now` in.
    #[must_use]
    pub fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    /// Brings the session up to LISTENING: the inbound pump, and the lane's sink.
    ///
    /// Capture does not start here. The registry has already routed this lane's hello to the
    /// sink this call registers, so by the time it returns the hello may already have been
    /// handled — which is the intended race, and why the sink is registered before the lane is
    /// admitted rather than after.
    pub fn start(self: &Arc<Self>) {
        // The pump BEFORE the lane, and both before the machine's start effects. `lane_sink` is
        // what brings the pump up — see its own note — and `MuxLaneTransport::start` registers the
        // sink before it admits the lane, so the hello that is already in flight lands in a queue
        // a thread is draining rather than in one nothing has been spawned for.
        self.transport.start(self.lane_sink());
        let effects = self.locked_state().start();
        self.apply_effects(effects);
    }

    /// The one control-message door, for the acknowledgements the SESSION mints itself.
    ///
    /// The state machine's own [`SessionEffect::SendControl`] carries a typed message the LAW
    /// minted; this is the other half — a resize ack the session just actuated, the cadence it
    /// just governed, the goodbye. Both end at the same encoder, so there is one spelling of a
    /// control datagram on the wire.
    pub fn send_control(&self, message: &VideoControlMessage) {
        let outgoing = schedule_control(message);
        self.transport.send(&outgoing.bytes, outgoing.channel);
    }

    /// Applies a batch of effects in the order the machine emitted them.
    ///
    /// Order is load-bearing and this is the only place it is kept: a `stopCapture` followed by a
    /// `sendControl` says goodbye AFTER the stream is down, and swapping them tells the client the
    /// session is over while frames are still arriving.
    pub fn apply_effects(self: &Arc<Self>, effects: Vec<SessionEffect>) {
        for effect in effects {
            self.apply_effect(effect);
        }
    }

    /// Applies ONE effect.
    ///
    /// Every arm is an effect and none is a decision — see the module note. The one thing to look
    /// for in a review of this function is a branch that asks a question the state machine was not
    /// asked.
    pub fn apply_effect(self: &Arc<Self>, effect: SessionEffect) {
        match effect {
            SessionEffect::SendControl(message) => self.send_control(&message),
            SessionEffect::StartCapture { width, height, .. } => self.start_capture(width, height),
            SessionEffect::StopCapture => self.stop_capture(),
            SessionEffect::ResizeCapture { width, height, epoch } => {
                self.resize_capture(width, height, epoch);
            },
            SessionEffect::ApplyStreamSettings {
                fps_cap,
                bitrate_ceiling_bps,
            } => self.apply_stream_settings(fps_cap, bitrate_ceiling_bps),
            SessionEffect::ApplyAudioControl { enabled } => self.apply_audio_control(enabled),
            SessionEffect::ApplyPrivacyMode { enabled } => self.apply_privacy_mode(enabled),
        }
    }

    /// The window's current CG top-left bounds, which every control decision is taken against.
    ///
    /// A display target answers its whole frame; a window target asks the window server, and a
    /// window that has since closed answers an empty rect rather than a stale one — the state
    /// machine reads an empty rect as "no window", which is the truth.
    #[must_use]
    pub fn window_bounds_cg(&self) -> VideoRect {
        match self.spec.target {
            Target::Window { id, pid, .. } => {
                // The pid is passed so the window server's answer is checked against the process
                // that owned the window at mint: a recycled `CGWindowID` under another app would
                // otherwise hand this session another app's geometry.
                slopdesk_apple_cgwindow::bounds_of(id, Some(pid))
                    .unwrap_or(VideoRect::xywh(0.0, 0.0, 0.0, 0.0))
            },
            Target::Display { id } => slopdesk_apple_cgdisplay::bounds_of(id),
        }
    }

    /// The capture size this session negotiates for a viewport, in points.
    ///
    /// The mint may have PINNED a size — a parked window on a virtual display is captured at the
    /// size the ledger recorded, not at whatever the client asks for — and that override wins over
    /// the viewport, which is why it is asked first.
    #[must_use]
    pub fn resolve_capture_size(&self, viewport: VideoSize) -> Option<(u16, u16)> {
        let source = if let Target::Window {
            size_override: Some((width, height)),
            ..
        } = self.spec.target
        {
            VideoSize::new(width, height)
        } else {
            let bounds = self.window_bounds_cg().size;
            if bounds.width <= 0.0 || bounds.height <= 0.0 {
                return None;
            }
            bounds
        };
        let _ = viewport;
        Some(clamp_to_wire(source))
    }

    /// The state machine, through the poison a session cannot be hurt by.
    ///
    /// A panic mid-transition leaves the machine in whichever state it had reached, and the next
    /// message is decided from there. The alternative — refusing every later message — turns one
    /// panicking control datagram into a session that can never be told to stop.
    pub(crate) fn locked_state(&self) -> MutexGuard<'_, VideoSessionStateMachine> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The controller set, through the same poison discipline as [`Self::locked_state`].
    pub(crate) fn locked_controllers(&self) -> MutexGuard<'_, Controllers> {
        self.controllers.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The frame counters, through the same poison discipline as [`Self::locked_state`].
    pub(crate) fn locked_counters(&self) -> MutexGuard<'_, FrameCounters> {
        self.counters.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The client-liveness window, through the same poison discipline as [`Self::locked_state`].
    pub(crate) fn locked_liveness(&self) -> MutexGuard<'_, ClientLiveness> {
        self.liveness.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live components, through the same poison discipline as [`Self::locked_state`].
    pub(crate) fn locked_streaming(&self) -> MutexGuard<'_, Option<Streaming>> {
        self.streaming.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl LaneSession for Session {
    /// Stops capture, encode and every timer this session started.
    ///
    /// The order is the whole function, and it is the Swift's own, restated where it can be read:
    ///
    /// 1. **The inbound pump first**, so no datagram already in the queue injects into a
    ///    half-torn-down session.
    /// 2. **The send lane**, whose queued frames belong to a session that will not exist by the
    ///    time they drain.
    /// 3. **The state machine's own stop effects**, which include the goodbye — sent while the lane
    ///    is still up, because a `bye` on a retired lane goes nowhere.
    /// 4. **The live components**, which is where the framework calls are.
    /// 5. **The lane**, last, because every step above may still want to send.
    ///
    /// Idempotent by the [`Session::stopped`] latch: a reap and a client `bye` reach this
    /// concurrently in normal operation, and each of steps 2, 4 and 5 is a double-free in a
    /// different library if it runs twice.
    fn stop(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        // 1. The inbound pump, so nothing already queued injects into a half-torn-down session.
        //    `stop_inbound` is self-join-safe: a `bye` is handled ON the pump thread, so this call
        //    can reach it from the thread it would otherwise wait for.
        self.stop_inbound();
        if let Some(lane) = self.send_lane.as_ref() {
            lane.close();
        }
        let effects = self.locked_state().stop();
        for effect in effects {
            // Only the goodbye can reach here — every other stop effect names a live component,
            // and the teardown below is what answers those. Sending it directly keeps this path
            // free of the `Arc<Self>` that `apply_effect` needs, so a session dropping its last
            // handle can still say goodbye.
            if let SessionEffect::SendControl(message) = effect {
                self.send_control(&message);
            }
        }
        self.teardown_live();
        self.transport.stop();
    }

    /// Ships this session's status over its own cursor lane.
    ///
    /// The only branch is which QUESTION the operating point is asked, and it is the same split the
    /// FIRE path takes: a WINDOW session is eligible when its own app is the frontmost one, because
    /// the chord posts at the HID tap and lands in whatever holds OS key focus
    /// ([`crate::injector`] suppresses and raises on a mismatch) — a chip that promised otherwise
    /// would promise fires the host swallows. A DISPLAY session follows the frontmost app, which
    /// mirrors the same check exactly.
    ///
    /// Silent before media flows: a listening session has no cursor lane a client is reading.
    fn push_nav_status(
        &self,
        config: &SwipeNavHostConfig,
        frontmost_bundle_id: Option<&str>,
        history: Option<NavHistoryFlags>,
    ) {
        if !self.locked_state().media_flowing() {
            return;
        }
        let status = match self.spec.target {
            // The same door the window feed and the injector ask, off the main thread like both.
            Target::Window { pid, .. } if pid > 0 => {
                config.window_status(
                    slopdesk_apple_app::bundle_id(pid).as_deref(),
                    frontmost_bundle_id,
                    history,
                )
            },
            Target::Window { .. } | Target::Display { .. } => config.status(frontmost_bundle_id, history),
        };
        self.transport.send(
            &CursorChannelMessage::SwipeNavStatus(status).encode(),
            VideoChannel::Cursor,
        );
    }
}

/// Clamps a point size to what the wire can carry, with a floor of one.
///
/// Both ends are real: a zero would divide by zero in the client's aspect fit, and a window wider
/// than `u16::MAX` points does not exist but a garbage bounds read does.
fn clamp_to_wire(size: VideoSize) -> (u16, u16) {
    let width = size.width.round().clamp(1.0, f64::from(u16::MAX));
    let height = size.height.round().clamp(1.0, f64::from(u16::MAX));
    // The clamp above is what makes these casts total; there is no value left that can wrap.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the clamp to [1, u16::MAX] is what makes the cast total"
    )]
    (width as u16, height as u16)
}
