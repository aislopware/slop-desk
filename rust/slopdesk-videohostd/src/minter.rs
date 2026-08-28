//! A hello into a running session: what the daemon resolves before a [`Session`] can exist.
//!
//! The Swift daemon's mint closure and `mintDisplaySession` — the two hundred lines of that entry
//! point which were not an order but a RESOLUTION, and that had to live in `main` there because
//! only `main` held the virtual display, the parking manager and the shared transport at once.
//!
//! ## What a mint actually decides
//! Nothing. It RESOLVES: which window or display the hello names, whether the virtual display is
//! up, whether the window could be parked on it, and therefore at what scale and size this session
//! captures. Every one of those is a lookup or an effect with a rule behind it —
//! [`slopdesk_video::capture_config`] for the scale and the whole-screen cadence,
//! [`slopdesk_video::window_parking`] for the refcount, [`crate::rescue`] for the off-screen
//! decision tree. What this file contributes is the ORDER they happen in and what each failure
//! degrades to.
//!
//! ## Every failure degrades; only two refuse
//! A window that will not park is captured in place, softly. A virtual display that will not come
//! back is a stream at the host's own scale. A capture scale the operator lowered is honoured. None
//! of that fails a mint, because a pane that streams a soft picture is a working pane and a pane
//! that refuses is a black rectangle with no scrim.
//!
//! The two real refusals are the hello naming a window that does not exist and cannot be rescued,
//! and a hello that lands after [`Minter::close`]. Both answer [`MintRefused`], which the registry
//! turns into a TERMINAL rejected `helloAck` — the client's state machine resolves it and stops
//! retrying, where a silent drop left it re-driving a doomed mint for ever.
//!
//! ## Why the shutdown gate is checked twice
//! `FB17797423`: releasing a virtual display while a stream still targets it wedges the window
//! server. A hello that arrives between the drain's `stop_all` and its display teardown would
//! otherwise mint a fresh capture onto a display about to go away — so the gate is read before the
//! capture starts AND after it has, and the second read tears down what the first could not know
//! was about to be built. The client retries under a fresh lane against the next daemon.
//!
//! ⚠️ GUI + TCC ONLY. Every path here reaches `ScreenCaptureKit` or the accessibility tree.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Instant;

use slopdesk_video::capture_config::{
    CAPTURE_SCALE_KEY, DISPLAY_FPS_KEY, capture_scale_from_env, display_fps_from_env,
};
use slopdesk_video::geometry::{VideoPoint, VideoSize};
use slopdesk_video::host_gates::HostGates;
use slopdesk_video::recovery_idr::RecoveryIdrConfig;
use slopdesk_video::session_state::VideoSessionStateMachine;
use slopdesk_video::video_control::VideoControlMessage;

use crate::diag::say;
use crate::env::Overlay;
use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
use crate::mux_registry::{LaneSession, MintRefused, SessionMinter};
use crate::mux_sink::MuxSinkTable;
use crate::parking::Parking;
use crate::session::Session;
use crate::session_wiring::{SessionSpec, Target};
use crate::vdisplay::{self, Availability, Recreate};
use crate::windowplace::AccessibilityTree;

/// The stream id a fresh session's state machine counts up from.
///
/// Per session, not per daemon: the id identifies a STREAM within one lane's negotiation, and two
/// lanes both starting at one is what the client already expects.
const FIRST_STREAM_ID: u32 = 1;

/// What the command line fixed about every session this daemon will mint.
///
/// Copied into each mint rather than re-read, because there is no live reload: `just host-restart`
/// replays the recorded launch, and the restart IS the reload.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LaunchSpec {
    /// The capture scale to fall back to when no window is parked — the host's own, clamped by
    /// `--scale`.
    pub fallback_scale: f64,
    /// The live encoder's bitrate floor, in bits per second.
    pub bitrate: i64,
    /// The WINDOW path's cadence cap. The whole-screen path derives its own from this.
    pub window_fps: i64,
    /// The virtual display's logical size, in points — the ceiling a client-driven resize clamps
    /// to while a window is parked on it.
    pub vd_point_size: VideoSize,
}

/// Builds and starts the session a hello asks for.
#[derive(Debug)]
pub struct Minter {
    /// The shared transport every lane sends through.
    lanes: Arc<dyn LaneControl>,
    /// The sink table a lane registers into, synchronously, inside `start`.
    sinks: Arc<MuxSinkTable>,
    /// Who to tell when a lane retires itself.
    ///
    /// Late-bound, and `Weak`, for one reason each. Late because the registry takes this minter by
    /// `Arc` at construction, so the registry cannot exist yet when this does — the Swift called
    /// the same knot a `MuxRetireBox`. Weak because a strong edge back would be a cycle no drop
    /// could break, and the registry outlives every lane it mints.
    retired: Mutex<Option<Weak<dyn LaneRetired>>>,
    /// The parked-window manager: the accessibility half of putting a window on the display.
    parking: Arc<Parking<AccessibilityTree>>,
    /// The virtual display handle, held for the daemon's lifetime by `main` and read per mint.
    display: Arc<slopdesk_apple_cgvirtualdisplay::VirtualDisplay>,
    /// What a re-create would need, or `None` when the display is disabled or never came up.
    ///
    /// `None` is the whole gate: an environment where the display never worked must not pay a
    /// blocking `WindowServer` round trip on every hello for the rest of the daemon's life.
    recreate: Option<Recreate>,
    /// The settings overlay every gate below resolves through.
    overlay: Overlay,
    /// The gate table, resolved once at launch and handed to every session.
    gates: HostGates,
    /// What the command line fixed.
    launch: LaunchSpec,
    /// The daemon's own clock, so a re-create cooldown is measured against one timeline.
    epoch: Instant,
    /// Closed at the START of the shutdown drain. See the module note on why it is read twice.
    closed: AtomicBool,
}

impl Minter {
    /// A minter over the daemon's shared pieces.
    #[must_use]
    #[expect(
        clippy::too_many_arguments,
        reason = "the daemon's shared pieces, each with a different owner and lifetime; a bag struct would \
                  only move the same eight names one line up"
    )]
    pub fn new(
        lanes: Arc<dyn LaneControl>,
        sinks: Arc<MuxSinkTable>,
        parking: Arc<Parking<AccessibilityTree>>,
        display: Arc<slopdesk_apple_cgvirtualdisplay::VirtualDisplay>,
        recreate: Option<Recreate>,
        overlay: Overlay,
        gates: HostGates,
        launch: LaunchSpec,
    ) -> Self {
        Self {
            lanes,
            sinks,
            retired: Mutex::new(None),
            parking,
            display,
            recreate,
            overlay,
            gates,
            launch,
            epoch: Instant::now(),
            closed: AtomicBool::new(false),
        }
    }

    /// Tells the minter who to notify when a lane retires. Called once, the line after the registry
    /// is built — see [`Minter::retired`].
    pub fn bind_retired(&self, observer: &Arc<dyn LaneRetired>) {
        *self.retired.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::downgrade(observer));
    }

    /// Refuses every later mint. One-way, and the first act of the shutdown drain.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }

    /// Whether the shutdown drain has begun.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Seconds since the daemon's own start — the clock the re-create cooldown is stamped on.
    fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    /// The whole-screen cadence: the operator's pin, or this daemon's window rate lifted to the
    /// whole-screen floor. The rule is [`display_fps_from_env`]'s; the composition is the mint's.
    fn display_fps(&self) -> i64 {
        display_fps_from_env(
            self.overlay.get(DISPLAY_FPS_KEY).as_deref(),
            self.launch.window_fps,
        )
    }

    /// The lane transport for `channel_id`, bound to whoever is listening for retirements.
    ///
    /// A lane whose observer is not bound yet — which can only happen if a datagram beat the line
    /// after the registry's construction — still sends and still serves; it just cannot report its
    /// own retirement, and the reaper closes that gap on the idle timeout.
    fn lane(&self, channel_id: u32) -> MuxLaneTransport {
        let observer = self
            .retired
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .unwrap_or_else(|| Weak::<crate::mux_registry::MuxSessionRegistry>::new());
        MuxLaneTransport::new(
            channel_id,
            Arc::clone(&self.lanes),
            Arc::clone(&self.sinks),
            observer,
        )
    }

    /// Builds the session, starts it, and answers it — or tears it back down if the drain began
    /// while it was coming up. See the module note on the two gate reads.
    fn bring_up(
        &self,
        channel_id: u32,
        spec: SessionSpec,
        lane: MuxLaneTransport,
    ) -> Result<Arc<Session>, MintRefused> {
        let session = Arc::new(Session::new(
            spec,
            Arc::new(lane),
            self.gates,
            RecoveryIdrConfig::default(),
            self.overlay.clone(),
            VideoSessionStateMachine::new(FIRST_STREAM_ID, self.gates.full_range),
        ));
        session.start();
        if self.is_closed() {
            LaneSession::stop(session.as_ref());
            self.parking.unpark(channel_id);
            return Err(MintRefused);
        }
        Ok(session)
    }

    /// Where this window will be captured from, and how large.
    ///
    /// Parks the window on the virtual display when there is one, and answers the display's REAL
    /// backing scale, the size the window actually took there, and the point ceiling a later resize
    /// is held under. Every failure answers the launch fallback and no override, which is the 1×
    /// in-place capture — see the module note on degrading.
    fn resolve_placement(&self, channel_id: u32, window_id: u32, pid: Option<i32>) -> Placement {
        let Some(recreate) = self.recreate.as_ref() else {
            return Placement::in_place(self.launch.fallback_scale);
        };
        let live = match vdisplay::ensure_live(&self.display, recreate, self.now()) {
            Availability::Live(live) => live,
            Availability::Recreated(live) => {
                say(&format!(
                    "virtual display RE-CREATED (id={}) after WindowServer termination",
                    live.display_id
                ));
                live
            },
            Availability::RecreateFailed => {
                say("virtual display re-create failed — capturing in place; retrying after cooldown");
                return Placement::in_place(self.launch.fallback_scale);
            },
            Availability::Throttled => return Placement::in_place(self.launch.fallback_scale),
        };
        let Some(pid) = pid.filter(|owner| *owner > 0) else {
            return Placement::in_place(self.launch.fallback_scale);
        };
        let bounds = slopdesk_apple_cgdisplay::bounds_of(live.display_id);
        let Some(achieved) = self.parking.park(channel_id, window_id, pid, bounds) else {
            say(&format!(
                "mux: could not move window {window_id} onto the virtual display — capturing in place"
            ));
            return Placement::in_place(self.launch.fallback_scale);
        };
        // The display's own scale, not [`vdisplay::SCALE`]: a window server that granted a
        // different backing ratio than it was asked for would otherwise make every capture off by
        // that ratio, silently. The knob can only lower it.
        let display_scale = f64::from(live.scale.max(1));
        Placement {
            capture_scale: capture_scale_from_env(
                self.overlay.get(CAPTURE_SCALE_KEY).as_deref(),
                display_scale,
            ),
            size_override: Some((achieved.width, achieved.height)),
            resize_limit: Some((self.launch.vd_point_size.width, self.launch.vd_point_size.height)),
        }
    }

    /// The window mint: resolve the window the hello names, park it, and bring the session up.
    fn mint_window(&self, channel_id: u32, window_id: u32) -> Result<Arc<dyn LaneSession>, MintRefused> {
        // Re-enumerated for THIS hello rather than read from a launch-time list: a pane may open
        // long after the daemon did, and the window it names may not have existed then.
        let found = slopdesk_apple_sck::ShareableContent::current(false, true)
            .and_then(|content| content.window(window_id));
        let window = if let Some(window) = found {
            window
        } else {
            // The host-windows rail offers minimized windows and windows on another Space, and
            // the on-screen enumeration above can never resolve either. The rescue un-minimizes
            // one when that is what hides it.
            let rescued = crate::rescue::rescue_off_screen_window(window_id).ok_or(MintRefused)?;
            say(&format!(
                "mux: window-id={window_id} was off-screen (minimized / other Space) — rescued for capture"
            ));
            rescued
        };
        let pid = window.owner_pid();
        let placement = self.resolve_placement(channel_id, window_id, pid);
        // ⚠️ Documented and un-coded, and it needs two panes naming the SAME window: each lane
        // mints its own session bound to this window, so two `resizeRequest`s would each write the
        // one real window and the last write would win. `docs/25` scopes that configuration out.
        let spec = SessionSpec {
            target: Target::Window {
                id: window_id,
                pid: pid.unwrap_or_default(),
                size_override: placement.size_override,
                resize_limit: placement.resize_limit,
            },
            capture_scale: placement.capture_scale,
            bitrate: self.launch.bitrate,
            fps: self.launch.window_fps,
        };
        let lane = self.lane(channel_id);
        let session = self.bring_up(channel_id, spec, lane).inspect_err(|_refused| {
            // The park happened before the bring-up, so a refused bring-up must undo it or the
            // window is stranded on a display nobody is looking at.
            self.parking.unpark(channel_id);
        })?;
        say(&format!(
            "mux: minted session chan={channel_id} window-id={window_id} scale={} over the shared flow",
            placement.capture_scale
        ));
        Ok(session)
    }

    /// The whole-screen mint: no window to resolve, no parking, and the display's own backing
    /// ratio.
    ///
    /// A display never moves and never resizes, and each of those absences is why a branch the
    /// window path needs is simply not here rather than merely unused.
    fn mint_display(&self, channel_id: u32, display_id: u32) -> Result<Arc<dyn LaneSession>, MintRefused> {
        let content = slopdesk_apple_sck::ShareableContent::current(false, true).ok_or(MintRefused)?;
        // Zero means the main display, and the main display is the one at the global origin by
        // CoreGraphics' own definition — asked for that way rather than through a second lookup
        // that would have to agree with this one.
        let resolved = if display_id == 0 {
            slopdesk_apple_cgdisplay::under(VideoPoint { x: 0.0, y: 0.0 }).map(|display| display.id)
        } else {
            Some(display_id)
        };
        let display = resolved.and_then(|id| content.display(id)).ok_or(MintRefused)?;
        let id = display.id();
        // The display's backing ratio: two on Retina, one otherwise. Read from the display rather
        // than assumed, for the reason the parked path reads the virtual display's.
        let capture_scale = slopdesk_apple_cgdisplay::backing_scale(id);
        let fps = self.display_fps();
        let spec = SessionSpec {
            target: Target::Display { id },
            capture_scale,
            bitrate: self.launch.bitrate,
            fps,
        };
        let lane = self.lane(channel_id);
        let session = self.bring_up(channel_id, spec, lane)?;
        say(&format!(
            "mux: minted FULL-DESKTOP session chan={channel_id} display-id={id} scale={capture_scale} \
             fps={fps}"
        ));
        Ok(session)
    }
}

impl SessionMinter for Minter {
    fn mint(
        &self,
        channel_id: u32,
        hello: &VideoControlMessage,
    ) -> Result<Arc<dyn LaneSession>, MintRefused> {
        // The first of the two reads. See the module note.
        if self.is_closed() {
            return Err(MintRefused);
        }
        match *hello {
            VideoControlMessage::HelloDisplay {
                requested_display_id, ..
            } => self.mint_display(channel_id, requested_display_id),
            VideoControlMessage::Hello {
                requested_window_id, ..
            } => self.mint_window(channel_id, requested_window_id),
            // Anything else reached a mint only because the routing rule admitted it as a
            // bootstrap; the refusal is the wire's own answer and no reason travels with it.
            _ => Err(MintRefused),
        }
    }
}

/// Where a session captures from: the scale, the pinned size, and the resize ceiling.
///
/// One value rather than three returns because the three are decided together and are wrong apart —
/// a pinned size without the scale that produced it over-crops, and a resize ceiling without a
/// parked window bounds a window nothing is holding.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Placement {
    /// Capture at target points times this many pixels.
    capture_scale: f64,
    /// The AUTHORITATIVE post-move point size, or `None` when nothing moved.
    size_override: Option<(f64, f64)>,
    /// The point ceiling a client-driven resize is held under while parked.
    resize_limit: Option<(f64, f64)>,
}

impl Placement {
    /// The degraded answer: capture the window where it stands, at the launch scale.
    const fn in_place(scale: f64) -> Self {
        Self {
            capture_scale: scale,
            size_override: None,
            resize_limit: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Placement;

    /// The degraded placement pins nothing, which is what makes the session read the live window.
    #[test]
    fn in_place_pins_nothing() {
        let placement = Placement::in_place(2.0);
        assert!(placement.size_override.is_none());
        assert!(placement.resize_limit.is_none());
        assert!((placement.capture_scale - 2.0).abs() < f64::EPSILON);
    }
}
