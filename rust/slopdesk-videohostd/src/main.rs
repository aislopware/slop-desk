//! `slopdesk-videohostd` — the GUI-video host daemon.
//!
//! ## What a `main` is allowed to be
//! An ORDER and nothing else. Every decision below this file is somebody's — a gate's, a policy's,
//! a ladder's — and the only thing that cannot live anywhere else is the sequence they happen in.
//! So there is no logic here beyond "this before that", and each "before" carries the reason it is
//! not the other way round.
//!
//! ## The order, and what each step depends on
//! 1. **Fold the settings sidecar**, as the FIRST act. `docs/58`: there is no settings GUI and no
//!    live reload, so a toggle applies at the next launch and this is that launch. It runs before
//!    the arg parse because `SLOPDESK_VD` is one of the keys it can carry, and the parse resolves
//!    that knob.
//! 2. **Parse argv.** A usage failure must cost nothing — no socket, no stream, no window server
//!    query — so it happens before anything with an effect.
//! 3. The one-shot modes, before the daemon proper: `--list` and `--vd-sck-probe` both answer a
//!    question and exit, and neither should bind a port to do it. They go to STDERR, not stdout —
//!    the Swift's `log` did, every diagnostic on this daemon does, and a listing that split across
//!    two streams would be the one inconsistency an operator noticed.
//! 4. **Block the shutdown signals**, before any thread exists, so every thread spawned after this
//!    inherits the mask and the drain is the only thing that ever sees one. `slopdesk-hostd`'s
//!    `main` argues the same choice at length: `sigwait` on a thread with the whole language
//!    available beats a handler pinned to async-signal-safe calls on whichever thread it landed on.
//! 5. **Connect to the window server.** `SCStream::startCapture` aborts with `CGS_REQUIRE_INIT` in
//!    a process that never established a connection, even though the ENUMERATION `--list` uses
//!    works without one — which is why this is here and not above step 3.
//! 6. **Launch hygiene**, and it must precede step 7. It restores windows a CRASHED previous daemon
//!    left on a virtual display that no longer exists, and its test is "this window intersects no
//!    display I can see". Create this launch's own display first and that test starts seeing the
//!    new display's off-screen bounds as somewhere a window may legitimately be.
//! 7. **The virtual display**, then the parking manager over it.
//! 8. **The transport, the minter, the registry** — in that order, because each takes the one
//!    before it. The knot is that the minter's lanes must report their retirement TO the registry,
//!    which does not exist yet when the minter is built; [`Minter::bind_retired`] is the line that
//!    ties it, the way the Swift's `MuxRetireBox` did.
//! 9. **The main event loop**, last and for ever. It is not a park:
//!    `slopdesk-apple-cgvirtualdisplay` dispatches to the MAIN QUEUE, so a main thread that slept
//!    would deadlock the first display teardown.
//!
//! ⚠️ GUI + TCC ONLY — see [`slopdesk_videohostd`]'s own docs. Run from a desktop session, not SSH.

use std::sync::Arc;

use nix::sys::signal::{SigSet, Signal};
use slopdesk_video::geometry::VideoSize;
use slopdesk_video::host_gates::{self, GateContext, HostGates};
use slopdesk_video::injector_gates::{self, InjectorGateContext, InjectorGates};
use slopdesk_video::keepalive::{IDLE_TIMEOUT_SECONDS, KEEPALIVE_INTERVAL_SECONDS};
use slopdesk_video::video_control::VideoControlMessage;
use slopdesk_videohostd::args::{Arguments, Parsed, Usage};
use slopdesk_videohostd::diag::{program, say};
use slopdesk_videohostd::discovery::Discovery;
use slopdesk_videohostd::env::Overlay;
use slopdesk_videohostd::minter::{LaunchSpec, Minter};
use slopdesk_videohostd::mux_lane::{LaneControl, LaneRetired};
use slopdesk_videohostd::mux_registry::{MuxSessionRegistry, SessionMinter};
use slopdesk_videohostd::mux_sink::MuxSinkTable;
use slopdesk_videohostd::mux_transport::{MuxDatagramTransport, MuxObserver, MuxTiming};
use slopdesk_videohostd::navstatus::{self, HostFrontmost, StatusKicker};
use slopdesk_videohostd::parking::{self, Parking};
use slopdesk_videohostd::vdisplay::{self, Recreate};
use slopdesk_videohostd::windowplace::AccessibilityTree;

/// Bits per megabit, for the one place `--bitrate` is turned into what the encoder takes.
const BITS_PER_MEGABIT: i64 = 1_000_000;

/// How long the drain may run before it is abandoned, in seconds.
///
/// A normal drain — goodbye, stop every session, restore every parked window, tear the display
/// down — is well under two. Five only trips on a genuine wedge, and a wedge is real: a leaked
/// capture continuation has been observed to suspend a teardown for ever, and a daemon that can
/// only be stopped by `SIGKILL` then relaunches into a port it is still holding.
const DRAIN_DEADLINE_SECONDS: u64 = 5;

fn main() {
    // Step 0. `--version`, before anything is read or folded: the one contract every shipped
    // binary answers (`docs/49` — the version is field two of line one), asked by the packager of
    // the built binary and by the install-side audit of the installed one.
    if std::env::args()
        .nth(1)
        .is_some_and(|argument| argument == "--version")
    {
        print_version();
        return;
    }

    // Step 1. Before the parse, because `SLOPDESK_VD` is a key this file can carry.
    let overlay = Overlay::from_launch();
    let applied = overlay.applied();
    if !applied.is_empty() && std::env::var_os("SLOPDESK_VIDEO_DEBUG").is_some() {
        say(&format!("applied video-prefs.json overlay → {applied:?}"));
    }

    // Step 2. A usage failure costs nothing.
    let argv: Vec<String> = std::env::args().collect();
    let vd = overlay.get("SLOPDESK_VD");
    let Some(parsed) = Arguments::parse(&argv, vd.as_deref()) else {
        say(&Usage(program()).to_string());
        std::process::exit(2);
    };

    // Step 3. The one-shot modes. Each answers a question and exits; neither binds a port.
    if parsed.arguments.list {
        for line in slopdesk_videohostd::list::render(slopdesk_videohostd::shareable::rows()) {
            say(&line);
        }
        std::process::exit(0);
    }
    if parsed.arguments.vd_sck_probe {
        probe_and_exit();
    }

    serve(&parsed, overlay);
}

/// The `--version` banner, on stdout: `slopdesk-videohostd <version>`.
#[expect(clippy::print_stdout, reason = "a --version banner is stdout by convention")]
fn print_version() {
    println!("{}", slopdesk_videohostd::args::version_banner());
}

/// The daemon proper: steps 4 through 9.
///
/// Split out from [`main`] only so that the one-shot modes above return by falling off a short
/// function rather than by an early exit buried in a long one.
#[expect(
    clippy::exit,
    reason = "a daemon that cannot bind its two ports has no degraded mode to offer: it has already said \
              why on stderr, and the honest answer to launchd is a non-zero status, not a process that runs \
              for ever serving nothing"
)]
fn serve(parsed: &Parsed, overlay: Overlay) {
    let args = parsed.arguments;

    // Step 4. Before any thread exists, so every thread inherits the mask.
    let signals = block_shutdown_signals();

    // Step 5. Capture needs a window-server connection; `.accessory` keeps this off the Dock.
    if !slopdesk_apple_nsapp::become_accessory() {
        say("WARNING: could not connect to the window server — capture will refuse to start");
    }

    let gates = HostGates::from_env(
        &overlay
            .resolve(&host_gates::KEYS)
            .iter()
            .map(Option::as_deref)
            .collect::<Vec<Option<&str>>>(),
        GateContext {
            // DERIVED, never assumed. `GateContext`'s own doc says the scroll coalescer's default
            // follows the injector's resampler because stacking the two double-quantizes the
            // stream — so the only truthful answer is the injector's own resolver run over the
            // same overlay. A hardcoded `true` here would silently flip the coalescer's default
            // for any operator who set `SLOPDESK_SCROLL_RESAMPLE_HZ=0`, and no gate could see it.
            scroll_resampler_active: scroll_resampler_active(&overlay),
            keepalive_interval: KEEPALIVE_INTERVAL_SECONDS,
            idle_timeout: IDLE_TIMEOUT_SECONDS,
        },
    );

    // Step 6. BEFORE this launch's own display exists — see the module note.
    let sidecar = parking::default_sidecar();
    let tree = AccessibilityTree;
    if let Some(path) = sidecar.as_ref() {
        let restored =
            parking::run_launch_hygiene(&tree, path, &parking::online_display_bounds(), |window, pid| {
                slopdesk_apple_cgwindow::bounds_of(window, Some(pid))
            });
        if restored > 0 {
            say(&format!(
                "launch hygiene: restored {restored} window(s) a previous unclean daemon exit left stranded"
            ));
        }
    }

    // Step 7. The display, then the manager that parks windows on it.
    let display = Arc::new(slopdesk_apple_cgvirtualdisplay::VirtualDisplay::new());
    let parking = Arc::new(Parking::new(tree, sidecar));
    let recreate = bring_up_display(&display, args);

    // Step 8. The transport, the minter, the registry — each takes the one before it.
    let timing = MuxTiming::contract();
    let transport = match MuxDatagramTransport::bind(args.media_port, args.cursor_port, timing) {
        Ok(bound) => Arc::new(bound),
        Err(why) => {
            say(&format!(
                "failed to start: cannot bind media:{} cursor:{}: {why}",
                args.media_port, args.cursor_port
            ));
            // `EADDRINUSE` is another videohostd already serving these ports — a checkout's beside
            // the installed agent's, or a relaunch racing the process it replaced — and that is
            // exit 0, for hostd's reason (`ops/launchd.rs`): under the agent's
            // `SuccessfulExit: false` an exit 1 would respawn the loser every ten seconds for ever.
            let held = why.kind() == std::io::ErrorKind::AddrInUse;
            std::process::exit(i32::from(!held));
        },
    };
    let sinks = Arc::new(MuxSinkTable::new());
    let lanes: Arc<dyn LaneControl> = transport.clone();
    // Resolved here rather than beside the kicker below, because the minter TAKES the overlay: the
    // daemon's one operating point has to be read off it while it is still the daemon's to read.
    let nav_config = navstatus::operating_point(&overlay);
    let nav_trace = navstatus::traced(&overlay);
    let minter = Arc::new(Minter::new(
        Arc::clone(&lanes),
        Arc::clone(&sinks),
        Arc::clone(&parking),
        Arc::clone(&display),
        recreate,
        overlay,
        gates,
        LaunchSpec {
            fallback_scale: args.scale,
            bitrate: i64::from(args.bitrate_mbps) * BITS_PER_MEGABIT,
            window_fps: i64::from(args.fps),
            vd_point_size: VideoSize::new(f64::from(args.vd_point_width), f64::from(args.vd_point_height)),
        },
    ));
    let session_minter: Arc<dyn SessionMinter> = minter.clone();
    let registry = Arc::new(MuxSessionRegistry::new(
        Arc::clone(&sinks),
        Arc::clone(&lanes),
        session_minter,
    ));
    // The knot the Swift called a `MuxRetireBox`: the lanes the minter builds report their
    // retirement to a registry that could not exist when the minter was constructed. Held for the
    // daemon's whole life in `retirements` because the lane's edge back is WEAK — dropping this
    // binding would silently turn every retirement into a no-op.
    let retirements = Arc::new(Retirements {
        registry: Arc::clone(&registry),
        parking: Arc::clone(&parking),
    });
    let retired: Arc<dyn LaneRetired> = retirements;
    minter.bind_retired(&retired);

    // The session-LESS answers — the picker's window and display lists, and the host-window feed.
    // They are asked BEFORE the registry, because a lane that only ever asks what is shareable must
    // never mint a session and start a capture for the privilege.
    let discovery = Arc::new(Discovery::new(Arc::clone(&lanes)));
    let observer: Arc<dyn MuxObserver> = Arc::new(Front {
        discovery: Arc::clone(&discovery),
        registry: Arc::clone(&registry),
        parking: Arc::clone(&parking),
        sinks: Arc::clone(&sinks),
    });

    // ARMED BEFORE the first datagram can arrive. The Swift armed this at create time, and the
    // reason survives the port: a hello admitted between `start` and this line would mint a capture
    // onto a display whose termination nothing is yet listening for, and that session then streams
    // a dead display with its window stranded off-screen.
    arm_display_termination(&display, &registry, &parking, &lanes);
    transport.start(&observer);

    // Started AFTER the transport, because its first beat is a forced one: a beat that fanned out
    // before a lane could exist would spend a window-server query on an audience that cannot be
    // there yet. It costs nothing while idle — see the module note's first bullet.
    let nav_status = StatusKicker::start(nav_config, nav_trace, HostFrontmost, Arc::clone(&registry));

    arm_shutdown(
        signals, &transport, &registry, &minter, &parking, &display, &lanes, nav_status,
    );

    say(&format!(
        "UDP-mux: serving SHARED flow on media:{} cursor:{} — N panes, one flow, per-hello windows",
        args.media_port, args.cursor_port
    ));
    say("client: open the SlopDesk app → Remote window; each pane's hello picks its window");

    // Step 9. Never returns. Not a park — see the module note on the main queue.
    if args.virtual_display {
        // `CGVirtualDisplay` needs a live `CFRunLoop` to stay registered with the window server,
        // which draining the main queue alone does not provide.
        slopdesk_apple_nsapp::run()
    } else {
        // The proven default path, kept as the Swift chose it rather than unified without a
        // measurement to justify the change.
        slopdesk_apple_nsapp::drain_main_queue()
    }
}

/// Routes one demultiplexed datagram: an admitted lane's sink, then discovery, then the mint.
///
/// The order is the Swift's and it is load-bearing at both ends. An ADMITTED lane goes first
/// because its sink appends to the session's inbound queue SYNCHRONOUSLY, on the receive thread, in
/// arrival order — a `mouseUp` that overtook its `mouseDown` sticks a button down, and video
/// tolerates reorder where input does not. Discovery goes before the mint because a lane that only
/// asked what is shareable must not be answered by starting a capture for it.
#[derive(Debug)]
struct Front {
    /// The session-less answers.
    discovery: Arc<Discovery>,
    /// The mint-and-route half.
    registry: Arc<MuxSessionRegistry>,
    /// A reaped lane's window has to come back — see [`MuxObserver::reap_lane`] below.
    parking: Arc<Parking<AccessibilityTree>>,
    /// Read directly, so an admitted lane costs one lookup and no lock beyond it.
    sinks: Arc<MuxSinkTable>,
}

impl MuxObserver for Front {
    fn receive(
        self: Arc<Self>,
        channel_id: u32,
        channel: slopdesk_video::recovery_routing::VideoChannel,
        payload: &[u8],
    ) {
        if let Some(sink) = self.sinks.sink(channel_id) {
            sink(channel, payload);
        } else if !self.discovery.dispatch(channel_id, channel, payload) {
            self.registry.dispatch(channel_id, channel, payload);
        }
    }

    /// A lane the transport gave up on: stop the session, and PUT THE WINDOW BACK.
    ///
    /// The unpark is not a courtesy. A pane closed by a client that simply stopped answering never
    /// reaches the clean-bye path, so without this line its window stays shrunk on a virtual
    /// display the user cannot see, and stays there until the daemon exits. `Parking::unpark` is
    /// idempotent, so a lane that also retired cleanly costs nothing here.
    fn reap_lane(self: Arc<Self>, channel_id: u32) {
        self.registry.retire_and_stop(channel_id);
        // The retire is inline because it clears the sink table and the reaper's next tick must see
        // that. The unpark is NOT: it is seconds of synchronous accessibility IPC into an app that
        // may itself be the reason this lane went quiet, and this is the transport's reaper thread
        // — one hung app would otherwise hold every OTHER dead lane's reap behind it. The Swift's
        // actor hop bought the same thing. `Parking` serialises its own AX phases, so the thread
        // races nothing.
        let parking = Arc::clone(&self.parking);
        drop(std::thread::spawn(move || parking.unpark(channel_id)));
    }
}

/// The one observer the minter's lanes report their retirement to.
///
/// TWO things happen on a retirement and the Swift's `MuxRetireBox` did both: the registry forgets
/// the session, and the parking manager puts the window back. Binding the registry alone — which it
/// implements [`LaneRetired`] for — would leak a shrunk window on the invisible display on every
/// clean pane close, which is the common path, not the exceptional one.
#[derive(Debug)]
struct Retirements {
    /// Forgets the session.
    registry: Arc<MuxSessionRegistry>,
    /// Puts the window back where the user left it.
    parking: Arc<Parking<AccessibilityTree>>,
}

impl LaneRetired for Retirements {
    fn lane_retired(&self, channel_id: u32) {
        self.registry.lane_retired(channel_id);
        self.parking.unpark(channel_id);
    }
}

/// Brings the virtual display up, and answers what a later re-create would need.
///
/// `None` — no re-create ever attempted — when the display is disabled or its launch-time create
/// failed. That is the whole gate: an environment where the display has never worked must not pay a
/// blocking window-server round trip on every hello for the rest of the daemon's life.
fn bring_up_display(
    display: &slopdesk_apple_cgvirtualdisplay::VirtualDisplay,
    args: Arguments,
) -> Option<Recreate> {
    if !args.virtual_display {
        return None;
    }
    let geometry = vdisplay::geometry(
        i32::try_from(args.vd_point_width).unwrap_or_default(),
        i32::try_from(args.vd_point_height).unwrap_or_default(),
        &cpu_brand(),
    );
    let fps = i32::try_from(args.fps).unwrap_or_default();
    let Some(id) = vdisplay::bring_up(display, &geometry, fps) else {
        say(
            "WARNING: virtual display unavailable — capturing in place, text SOFT. Set SLOPDESK_VD=0 to \
             silence.",
        );
        return None;
    };
    say(&format!(
        "virtual display ONLINE id={id} ({}x{}pt) — windows will be moved onto it for sharp capture",
        args.vd_point_width, args.vd_point_height
    ));
    Some(Recreate::new(geometry, fps))
}

/// Arms the drain the window server's own teardown of the virtual display needs.
///
/// Every session whose window was parked on a display that has just gone is still capturing it — a
/// silent frozen pane — so each is told goodbye and stopped, and its window put back. The client's
/// ordinary reconnect path then engages and its fresh hello re-mints onto a re-created display, or
/// in place. Which channels those are is [`vdisplay::channels_to_disconnect`]'s rule: the ones that
/// are parked AND live, because a channel that never parked has nothing to recover from.
fn arm_display_termination(
    display: &slopdesk_apple_cgvirtualdisplay::VirtualDisplay,
    registry: &Arc<MuxSessionRegistry>,
    parking: &Arc<Parking<AccessibilityTree>>,
    lanes: &Arc<dyn LaneControl>,
) {
    let registry = Arc::clone(registry);
    let parking = Arc::clone(parking);
    let lanes = Arc::clone(lanes);
    display.on_terminated(Box::new(move || {
        let registry = Arc::clone(&registry);
        let parking = Arc::clone(&parking);
        let lanes = Arc::clone(&lanes);
        // ON A THREAD, because this callback runs on the framework's own delivery queue. The work
        // below is seconds of accessibility round trips — one `AXUIElementSetAttributeValue` per
        // parked window, each a synchronous IPC into an app that may be busy — and holding that
        // queue for seconds stalls every other display notification behind it. The Swift wrapped
        // the same body in a `Task` for the same reason.
        drop(std::thread::spawn(move || {
            let affected =
                vdisplay::channels_to_disconnect(parking.parked_channel_ids(), registry.live_channel_ids());
            let count = affected.len();
            for channel_id in affected {
                farewell(lanes.as_ref(), channel_id);
                registry.retire_and_stop(channel_id);
                parking.unpark(channel_id);
            }
            // Idempotent with the per-channel unparks above, and it catches a lane that was parked
            // before its session was ever admitted.
            parking.restore_all();
            say(&format!(
                "virtual display terminated by WindowServer — disconnected {count} parked session(s), \
                 windows restored; next pane hello re-creates it"
            ));
        }));
    }));
}

/// Waits out a shutdown signal on its own thread and drains, then exits.
///
/// A thread rather than the main one because the main thread is the event loop, and the display
/// teardown below dispatches TO it — a drain that ran on the main thread would be waiting for
/// itself. The mask blocked in [`block_shutdown_signals`] is inherited here, so this is the only
/// thread that can see the signal at all.
#[expect(
    clippy::exit,
    reason = "the drain runs on a worker while the main thread is parked in its run loop for ever; \
              returning from here would leave the daemon alive with every socket closed and every session \
              stopped, so the exit IS the shutdown"
)]
#[expect(
    clippy::too_many_arguments,
    reason = "each argument is one thing the drain must touch, IN THIS ORDER — the order is the whole \
              function, and a struct grouping them would be a parameter object whose only reader is this \
              call"
)]
fn arm_shutdown(
    signals: SigSet,
    transport: &Arc<MuxDatagramTransport>,
    registry: &Arc<MuxSessionRegistry>,
    minter: &Arc<Minter>,
    parking: &Arc<Parking<AccessibilityTree>>,
    display: &Arc<slopdesk_apple_cgvirtualdisplay::VirtualDisplay>,
    lanes: &Arc<dyn LaneControl>,
    mut nav_status: StatusKicker<HostFrontmost, Arc<MuxSessionRegistry>>,
) {
    let transport = Arc::clone(transport);
    let registry = Arc::clone(registry);
    let minter = Arc::clone(minter);
    let parking = Arc::clone(parking);
    let display = Arc::clone(display);
    let lanes = Arc::clone(lanes);
    drop(std::thread::spawn(move || {
        match signals.wait() {
            Ok(signal) => say(&format!("{signal} — shutting down")),
            Err(why) => say(&format!("signal wait failed ({why}) — shutting down")),
        }
        // Closed FIRST: a hello landing between the stop below and the display teardown would
        // otherwise mint a capture onto a display about to be released, which is the window-server
        // wedge `FB17797423` names.
        minter.close();
        // Stopped with the minter and for the same reason: it is a PUSH into lanes the next lines
        // retire, and a beat still in flight would be writing to sockets a farewell has closed.
        nav_status.stop();
        arm_drain_deadline();

        // Every live client is told FIRST. Closing the sockets silently on a clean restart would
        // leave each client's session streaming for ever — a frozen pane and dead input until the
        // app is relaunched — where a goodbye engages its rebuild-and-re-hello path at once.
        for channel_id in registry.live_channel_ids() {
            farewell(lanes.as_ref(), channel_id);
        }
        registry.stop_all();
        transport.stop();
        // Windows go back BEFORE the display is destroyed, while the display they came FROM still
        // exists; the display goes last, after every capture targeting it has stopped.
        parking.restore_all();
        display.destroy();
        std::process::exit(0);
    }));
}

/// Abandons a drain that has not finished in [`DRAIN_DEADLINE_SECONDS`].
///
/// `abort`, not `exit`: by definition the process state is wedged at this point, and no at-exit
/// hygiene is worth staying undead for. The alternative is a daemon that only `SIGKILL` can stop
/// and whose successor cannot bind the port it is still holding.
///
/// The trade, said out loud so nobody "fixes" it: `abort` raises `SIGABRT`, so `launchd` records a
/// CRASH and a report is written, where the Swift's `_exit(0)` left a clean stop. That is the price
/// of a `forbid(unsafe_code)` crate — `_exit` is a raw libc call — and it is the RIGHT price,
/// because the deadline thread races the drain thread and two concurrent `exit()`s run the atexit
/// handlers twice, which is undefined behaviour. An abort racing an exit is not. A crash report on
/// a path that only fires when the daemon is already wedged is the cheaper half of that trade.
fn arm_drain_deadline() {
    drop(std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(DRAIN_DEADLINE_SECONDS));
        say(&format!(
            "shutdown drain wedged >{DRAIN_DEADLINE_SECONDS}s — force-exiting"
        ));
        // The drain thread races this one and both would exit; whichever arrives first wins, and
        // the loser is inside a process that is already leaving.
        std::process::abort();
    }));
}

/// A goodbye on one lane, sent twice.
///
/// Twice because a goodbye is a single unacked datagram and this is the last thing the client will
/// ever hear from this daemon: the cost of the duplicate is one datagram, and the cost of the loss
/// is a pane frozen until the app is relaunched.
fn farewell(lanes: &dyn LaneControl, channel_id: u32) {
    let outgoing = slopdesk_video::recovery_routing::schedule_control(&VideoControlMessage::Bye);
    for _ in 0..2 {
        lanes.send(&outgoing.bytes, outgoing.channel, channel_id);
    }
}

/// Blocks the shutdown signals on the calling thread, so every thread spawned later inherits it.
///
/// Answers the set to wait on. A mask that could not be applied is still answered: the wait then
/// competes with the default disposition, which is exactly the outcome an unhandled signal already
/// had, and refusing to start over it would be worse.
///
/// All three, not just `SIGINT`: `SIGTERM` is what `launchd` and an ordinary `kill` send, and
/// `SIGHUP` is what closing the terminal that launched it sends. A daemon that restored parked
/// windows on `Ctrl-C` alone would strand them on every other stop path, which is most of them.
fn block_shutdown_signals() -> SigSet {
    let mut signals = SigSet::empty();
    signals.add(Signal::SIGINT);
    signals.add(Signal::SIGTERM);
    signals.add(Signal::SIGHUP);
    let _applied = signals.thread_block();
    signals
}

/// Whether the input injector's scroll resampler will be running, from the same overlay.
///
/// Asked of [`InjectorGates`] rather than reparsed here, because the key is three-way — unset is
/// the default rate, an explicit zero or an unparseable value is OFF — and a second reading of that
/// rule is a second place for it to drift. `input_trace` is `false` because the only field read
/// back is the rate, and the trace switch does not reach it.
fn scroll_resampler_active(overlay: &Overlay) -> bool {
    let resolved = overlay.resolve(&injector_gates::KEYS);
    let texts: Vec<Option<&str>> = resolved.iter().map(Option::as_deref).collect();
    let Ok(values) = <[Option<&str>; injector_gates::KEYS.len()]>::try_from(texts.as_slice()) else {
        return true;
    };
    InjectorGates::from_env(&values, None, InjectorGateContext { input_trace: false }).scroll_resample_hz > 0
}

/// The CPU brand string, which decides the virtual display's framebuffer pixel limit.
///
/// Empty on any failure, which the planner reads as its permissive fallback: refusing to create a
/// display because a `sysctl` did not answer would be a worse trade than creating one a base chip
/// then declines.
fn cpu_brand() -> String {
    slopdesk_posix::hoststats::cpu_brand().unwrap_or_default()
}

/// Runs `--vd-sck-probe` on a worker while the main thread services its run loop, then exits.
///
/// The worker is not an optimisation and not a style: [`vdisplay::run_sck_probe`] brings a display
/// up, and that call hops to the main thread inside itself — running it ON the main thread would
/// have it wait for a queue only it could drain. This is the shape the Swift's `Task` plus
/// `dispatchMain()` had, said out loud.
#[expect(
    clippy::exit,
    reason = "a one-shot probe's whole contract is to answer and go; the main thread it left draining the \
              queue cannot be told to stop any other way"
)]
fn probe_and_exit() -> ! {
    drop(std::thread::spawn(|| {
        let report = vdisplay::run_sck_probe();
        for line in &report.lines {
            say(line);
        }
        std::process::exit(0);
    }));
    slopdesk_apple_nsapp::drain_main_queue()
}
