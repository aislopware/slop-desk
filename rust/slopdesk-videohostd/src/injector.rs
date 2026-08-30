//! Remote input's last stop: the raise chain, the scroll resampler's pump, the swipe-back
//! translation, and every event that reaches the window server.
//!
//! This is what [`crate::session_inbound::InputInjector`] describes. That trait names two verbs and
//! no more; everything below is the ORCHESTRATION behind them, which owns no rule of its own. Every
//! decision it reaches for is already written and tested elsewhere — the button balance, the raise
//! policy, the resampler, the flick recogniser, the navigable-app allowlist — and every effect it
//! causes belongs to an `slopdesk-apple-*` crate. What lives here is four pieces of machinery: two
//! worker threads, one interval clock and three locks.
//!
//! Four crates meet here, which is why this is a module of the daemon rather than of any of them:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::input_routing`] | which button is stuck, which up is a duplicate, whether to raise |
//! | `slopdesk-apple-cgevent` | the pointer, scroll, key and text events, built and posted |
//! | [`crate::windowplace`] / `slopdesk-apple-app` | raising the window, and bringing its app forward |
//! | `slopdesk-apple-cgwindow` | who is frontmost, which both the raise and the chord gate on |
//!
//! ## Why the whole orchestration is one place
//!
//! One click is: consult the balance, maybe post a synthetic release, map a normalised point
//! against bounds another thread is updating, post an event, and — off two other threads — run six
//! to ten accessibility round-trips and drain a resampler at 250 Hz. The ORDER is load-bearing at
//! every step, and every one of those steps is either a rule that is already Rust or an effect that
//! is already Rust. Splitting the sequence across a language boundary kept a dozen rules and their
//! only caller on opposite sides of it, and made each crossing a chance to reorder them.
//!
//! ## This handle is called from more than one thread
//!
//! Structurally, not incidentally:
//!
//! * the inbound path calls [`Injector::inject`] and [`Injector::raise_target_window`],
//! * the geometry watcher calls [`Injector::update_bounds`] as the window moves,
//! * teardown calls [`Injector::balance`] to carry held state into the replacement,
//! * and the two threads this handle OWNS call back into it — the raise pump reads the bounds, the
//!   scroll pump reads the balance and posts.
//!
//! So it carries its own locks rather than borrowing a caller's. There are three, each around a few
//! field assignments, and none is ever held across a framework call: a lock held across an
//! accessibility round-trip would reintroduce exactly the multi-second stall the raise thread
//! exists to prevent.
//!
//! ## The two threads
//!
//! * The RAISE pump is a serial worker over a channel. It owns the resolved accessibility pair
//!   ([`RaiseTarget`]), the first-interaction flag and the throttle clock as plain locals, because
//!   it is the only thread that touches any of them — an `AXUIElement` is a Core Foundation object
//!   with no thread-safety contract to lean on, so confinement is not merely tidier.
//! * The SCROLL pump is one `recv_timeout` loop, and that single call is BOTH the ingest queue and
//!   the output timer: a job arrives, or the interval elapses and the residual drains. With nothing
//!   left to meter out the wait has no deadline at all, so an idle pump costs zero wakeups.
//!
//! Both threads are spawned only when they have work — no target window means no raise pump, and a
//! disabled resampler means no scroll pump and a direct-post path instead. Both hold an `Arc` of
//! the shared state and exit when the handle drops its sender, which is what makes teardown a join
//! rather than a cancel.

use std::io::Write as _;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_apple_cgevent::{Button, PointerKind, PointerPost, ScrollPost};
use slopdesk_apple_cgwindow::frontmost_pid;
use slopdesk_video::coordinate_mapping::window_point;
use slopdesk_video::geometry::{VideoPoint, VideoRect};
use slopdesk_video::injector_gates::{InjectorGateContext, InjectorGates, KEYS, SWIPE_NAV_TRACE_KEY};
use slopdesk_video::input_event::{InputEvent, InputModifiers, MouseButton};
use slopdesk_video::input_routing::{InputButtonBalance, should_raise};
use slopdesk_video::scroll_resample::ScrollResampler;
use slopdesk_video::swipe_nav::SwipeDirection;
use slopdesk_video::swipe_nav_config::SwipeNavHostConfig;
use slopdesk_video::swipe_recognizer::{
    FLICK_MAX_DURATION, REFRACTORY, SLOW_DOMINANCE, SLOW_GRACE_MAX_DURATION, SLOW_RELAXED_DOMINANCE,
    SwipeNavRecognizer,
};

use crate::env::Overlay;
use crate::session_inbound::InputInjector;
use crate::windowplace::{AccessibilityTree, ResolvesWindows as _};

/// The minimum spacing between two raise chains.
///
/// One click fires several raise requests — the proactive focus, the down's own, each
/// loss-resilient duplicate up, and the first move after the up. Without this they pile up on the
/// raise thread as N futile accessibility chains per click. Coalescing is harmless because the
/// raise is best-effort: the posted events deliver either way.
const RAISE_THROTTLE: Duration = Duration::from_millis(500);

/// The raise chain's per-message accessibility cap, in seconds.
///
/// Tighter than [`crate::windowplace::TIMEOUT`] because the raise sits directly under a click: a
/// missed raise lands the event on the already-frontmost window, which is a small wrong thing,
/// while an eighth of a second of frozen input is a large one. The placement sequences are not
/// under a click and can afford to wait.
const RAISE_TIMEOUT: f32 = 0.08;

/// `kVK_ANSI_LeftBracket` — ⌘\[ is history BACK in every app the allowlist admits.
const KEY_LEFT_BRACKET: u16 = 0x21;
/// `kVK_ANSI_RightBracket` — ⌘\] is forward.
const KEY_RIGHT_BRACKET: u16 = 0x1E;
/// `kVK_Command` — the chord's bracket, and half of the physical-hold check.
const KEY_COMMAND: u16 = 0x37;
/// `kVK_RightCommand` — the same latch, right side. A distinct key with a distinct held flag.
const KEY_RIGHT_COMMAND: u16 = 0x36;

/// A nanosecond, in the units [`Duration::from_nanos`] takes — the resampler's interval divisor.
const NANOS_PER_SECOND: u64 = 1_000_000_000;

/// One diagnostic line, on stderr, with the prefix every field log for this path already carries.
///
/// A failed write is dropped: a trace that could interrupt injection would be worse than a trace
/// that is missing. `write_all` rather than a print macro because a print PANICS on a closed
/// descriptor, and a daemon whose stderr went away must keep posting events.
fn trace(line: &str) {
    let mut out = std::io::stderr();
    let _ignored = writeln!(out, "slopdesk-videohostd[inject]: {line}");
}

// ---------------------------------------------------------------------------------- //
// The raise target
// ---------------------------------------------------------------------------------- //

/// The window the raise pump raises, and the resolved pair it caches.
///
/// Not `Sync`, and not a field of [`Core`]: an `AXUIElement` has no thread-safety contract, so
/// rather than wrapping the cache in a lock this type is CONFINED to the one thread that raises.
/// [`raise_pump`] builds it inside that thread and nothing else ever sees it.
#[derive(Debug)]
struct RaiseTarget {
    /// The process whose window is raised.
    pid: i32,
    /// The window, by the id the rest of the host knows it by.
    window_id: u32,
    /// The resolved pair, once. A stale element is harmless — every accessibility call on one
    /// answers an error rather than faulting — so it is never invalidated, only replaced when the
    /// resolution failed and is retried.
    resolved: Option<(slopdesk_apple_ax::App, slopdesk_apple_ax::Window)>,
}

impl RaiseTarget {
    /// The raise target for one window of one process. Resolves nothing yet.
    const fn new(pid: i32, window_id: u32) -> Self {
        Self {
            pid,
            window_id,
            resolved: None,
        }
    }

    /// Raises and focuses the window; answers whether it had a target to raise.
    ///
    /// `bounds` is the window's current frame, used only as the fallback when the private id symbol
    /// answers for no candidate at all — a locked screen. It is passed per call rather than held
    /// because the geometry watcher already tracks it and a second copy would go stale.
    ///
    /// This does NOT bring the application forward. Ordering the raise against an activation is the
    /// caller's, and it stays there.
    fn raise(&mut self, bounds: VideoRect) -> bool {
        if self.pid <= 0 {
            return false;
        }
        if self.resolved.is_none() {
            self.resolved = AccessibilityTree.resolve(self.pid, self.window_id, bounds, RAISE_TIMEOUT);
        }
        let Some((app, window)) = self.resolved.as_ref() else {
            return false;
        };
        let _ = window.raise();
        app.focus(window);
        true
    }
}

// ---------------------------------------------------------------------------------- //
// The shared state
// ---------------------------------------------------------------------------------- //

/// Everything both threads and every caller read: the target, the operating point, and the three
/// pieces of mutable state that outlive a single call.
#[derive(Debug)]
struct Core {
    /// The captured window's process, or `0` for a DISPLAY-scoped session (the full-desktop pane),
    /// which has no window to raise and no app to judge navigable.
    pid: i32,
    /// The captured window, by the id the rest of the host knows it by.
    window_id: u32,
    /// The injector's own gate family, resolved once at construction.
    gates: InjectorGates,
    /// The swipe-back family's, likewise — a separate table because its consumers are separate.
    swipe_nav: SwipeNavHostConfig,
    /// Whether the session-wide input trace is on. Not a gate of this family; it arrives resolved.
    input_trace: bool,
    /// The window's `kCGWindowBounds` in CG top-left points, kept current by the geometry watcher
    /// so the normalised → absolute mapping stays right as the window moves.
    bounds: Mutex<VideoRect>,
    /// The held-button and held-modifier balance. Injection is already serial in the ordered path,
    /// so this lock is insurance — except against the scroll pump, which reads it to decide whether
    /// the chord may ride a real ⌘ instead of bracketing its own.
    balance: Mutex<InputButtonBalance>,
    /// The flick recogniser, fed from the inject path.
    swipe: Mutex<SwipeNavRecognizer>,
    /// The origin the recogniser's arrival clock counts from. Wire events carry no timestamps and
    /// the recogniser's budgets are sub-second, so arrival time is the clock it was designed for.
    clock: Instant,
}

/// One unit of work for the scroll pump.
///
/// The two arms are wildly different sizes and stay that way: boxing the big one would put a heap
/// allocation on a path that carries up to a thousand events a second, to save a handful of stack
/// bytes on an arm that fires twice per gesture.
#[expect(
    variant_size_differences,
    reason = "boxing the hot arm would allocate at 250 Hz to shrink a channel slot"
)]
#[derive(Debug)]
enum ScrollJob {
    /// A forwarded wire scroll, to be folded into the resampler.
    Scroll {
        /// Horizontal delta in points.
        dx: f64,
        /// Vertical delta in points.
        dy: f64,
        /// The CoreGraphics gesture phase.
        scroll_phase: u8,
        /// The CoreGraphics momentum phase.
        momentum_phase: u8,
        /// Whether the source gesture was precise rather than a wheel notch.
        continuous: bool,
        /// The self-inject stamp, replayed onto every sub-event the resampler emits.
        tag: u32,
    },
    /// A recognised flick, hopped here so the chord lands strictly AFTER the gesture's own scroll
    /// stream — FIFO on this one thread is the whole ordering guarantee.
    SwipeNav(SwipeDirection),
}

/// A worker thread and the channel that feeds it.
#[derive(Debug)]
struct Pump<T> {
    /// Dropped first on teardown, which is what tells the thread to leave its loop.
    jobs: Option<Sender<T>>,
    /// Joined second, so the handle never outlives a thread still reading its `Arc`.
    thread: Option<JoinHandle<()>>,
}

impl<T> Pump<T> {
    /// Closes the channel and waits for the thread. Idempotent: a second call finds both taken.
    fn stop(&mut self) {
        drop(self.jobs.take());
        if let Some(thread) = self.thread.take() {
            // A pump that panicked has already left its loop, which is all this call is waiting
            // for.
            drop(thread.join());
        }
    }
}

impl<T> Drop for Pump<T> {
    fn drop(&mut self) {
        self.stop();
    }
}

// ---------------------------------------------------------------------------------- //
// Posting
// ---------------------------------------------------------------------------------- //

/// One pointer event's eight decisions, gathered so they cross as a value rather than as a
/// same-typed argument list four booleans deep.
#[derive(Debug, Clone, Copy)]
struct PointerSpec {
    /// Hover, down, up or drag.
    kind: PointerKind,
    /// Which button the event names. A hover names the primary one and means nothing by it.
    button: MouseButton,
    /// The absolute CG point, top-left origin.
    at: VideoPoint,
    /// The originating click's count, carried on drags so selection engines see the down's state.
    click_count: u8,
    /// The wire's modifier bits.
    modifiers: InputModifiers,
    /// The self-inject stamp the cursor and geometry watchers filter on.
    tag: u32,
    /// Warp the cursor before posting.
    warp: bool,
    /// Post the one-round-trip tablet-point move instead of warping. Hover only.
    tablet: bool,
}

impl Core {
    /// The window's current frame, or a degenerate one if the lock is poisoned — which maps every
    /// normalised point to the origin rather than refusing to inject at all.
    fn frame(&self) -> VideoRect {
        self.bounds
            .lock()
            .map_or(VideoRect::xywh(0.0, 0.0, 0.0, 0.0), |bounds| *bounds)
    }

    /// The absolute CG point a normalised window position lands on.
    fn target(&self, normalized: VideoPoint) -> VideoPoint {
        window_point(normalized, self.frame())
    }

    /// Where a posted event is DELIVERED. `None` is the HID tap, which is the production path; the
    /// same-machine loopback seam names the target pid instead, so a host driving a client on the
    /// same Mac does not hijack the global cursor away from the window under test.
    const fn deliver_to(&self) -> Option<i32> {
        if self.gates.inject_to_pid && self.pid != 0 {
            Some(self.pid)
        } else {
            None
        }
    }

    /// One pointer event. Every field is a decision already made; this builds the spec and posts.
    fn post_pointer(&self, spec: PointerSpec) {
        let _ = slopdesk_apple_cgevent::post_pointer(&PointerPost {
            kind: spec.kind,
            button: match spec.button {
                MouseButton::Right => Button::Right,
                MouseButton::Other => Button::Other,
                MouseButton::Left => Button::Left,
            },
            x: spec.at.x,
            y: spec.at.y,
            click_count: spec.click_count,
            modifiers: spec.modifiers.bits(),
            tag: spec.tag,
            warp: spec.warp,
            tablet: spec.tablet,
            to_pid: self.deliver_to(),
        });
    }

    /// A pure HOVER move.
    ///
    /// The tablet path (`tablet_mouse`, real injection only — the loopback seam keeps the warp) is
    /// ONE absolute tablet-point move, so a hover flood costs one window-server round trip instead
    /// of three and no longer stalls capture. A button-held drag is never inferred here: the client
    /// says so explicitly, so a move is always a hover and a lost up can never strand a phantom
    /// drag.
    fn post_move(&self, normalized: VideoPoint, tag: u32) {
        let tablet = self.gates.tablet_mouse && !self.gates.inject_to_pid;
        self.post_pointer(PointerSpec {
            kind: PointerKind::Move,
            button: MouseButton::Left,
            at: self.target(normalized),
            click_count: 1,
            modifiers: InputModifiers::from_bits(0),
            tag,
            warp: !self.gates.inject_to_pid && !tablet,
            tablet,
        });
    }

    /// A button edge. Warped before posting so a tap with no preceding move still lands where it
    /// was aimed and the visible cursor agrees with where the click registers.
    fn post_button(
        &self,
        button: MouseButton,
        normalized: VideoPoint,
        down: bool,
        click_count: u8,
        modifiers: InputModifiers,
        tag: u32,
    ) {
        self.post_pointer(PointerSpec {
            kind: if down { PointerKind::Down } else { PointerKind::Up },
            button,
            at: self.target(normalized),
            click_count,
            modifiers,
            tag,
            warp: !self.gates.inject_to_pid,
            tablet: false,
        });
    }

    /// A drag move. STATELESS — the client reported the button held, so the host tracks nothing and
    /// a reordered datagram cannot desync a selection.
    fn post_drag(
        &self,
        button: MouseButton,
        normalized: VideoPoint,
        click_count: u8,
        modifiers: InputModifiers,
        tag: u32,
    ) {
        self.post_pointer(PointerSpec {
            kind: PointerKind::Drag,
            button,
            at: self.target(normalized),
            click_count,
            modifiers,
            tag,
            warp: !self.gates.inject_to_pid,
            tablet: false,
        });
    }

    /// ONE scroll event — the single emission point for both the direct path and the resampler's
    /// interpolated sub-events.
    fn post_scroll(
        &self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
        tag: u32,
    ) {
        let phased = self.gates.scroll_phase;
        // A precise gesture must NOT be re-scaled: the OS derives its inertial coast velocity from
        // the delta cadence, so a gain would desync the fling. Gain only means anything for a
        // legacy discrete wheel, so it is 1:1 whenever a real gesture is being replayed.
        let gain = if phased && continuous {
            1.0
        } else {
            self.gates.scroll_gain
        };
        let _ = slopdesk_apple_cgevent::post_scroll(&ScrollPost {
            dx,
            dy,
            gain,
            scroll_phase,
            momentum_phase,
            continuous,
            phased,
            tag,
            to_pid: self.deliver_to(),
        });
    }
}

/// A key edge. Posted at the HID tap and deliberately NOT tagged — a stamped keystroke defeats a
/// host IME's own tap-dedup and composes Telex twice. Free of the injector because a keystroke
/// reads nothing from it: there is no destination to choose and no coordinate to map.
fn post_key(key_code: u16, down: bool, modifiers: InputModifiers) {
    let _ = slopdesk_apple_cgevent::post_key(key_code, down, modifiers.bits());
}

// ---------------------------------------------------------------------------------- //
// The swipe-back translation
// ---------------------------------------------------------------------------------- //
//
// Nothing below ANSWERS a swipe-nav question. The eligibility, the travel and the zeroing rule for
// an ineligible push are `slopdesk_video::swipe_nav_config`'s, and the flick itself is
// `SwipeNavRecognizer`'s; every function here is the EFFECT that follows one of those verdicts —
// which is why each is named for the effect it performs and not for the gesture it serves.

impl Core {
    /// The app whose NAVIGABILITY the translation is judged against: the tracked window's app for a
    /// window-scoped session, the frontmost app for a display-scoped one. Both reads go through the
    /// window server rather than a workspace snapshot, which freezes at first access and would pin
    /// the verdict to whatever was frontmost the first time this process looked.
    fn nav_target_bundle_id(&self) -> Option<String> {
        if self.pid > 0 {
            return slopdesk_apple_app::bundle_id(self.pid);
        }
        slopdesk_apple_app::bundle_id(frontmost_pid()?)
    }

    /// The allowlist check, the focus check, and the chord itself.
    ///
    /// `raise` is the raise pump's channel: a suppressed chord kicks a raise so an immediate retry
    /// lands in the now-raised target.
    fn post_nav_chord(&self, fired: SwipeDirection, raise: Option<&Sender<()>>) {
        // Only drive apps where ⌘[ / ⌘] is history navigation — in an editor it EDITS TEXT, so an
        // unknown app gets nothing beyond the scroll it already received.
        if !self.swipe_nav.eligible(self.nav_target_bundle_id().as_deref()) {
            if self.input_trace {
                trace("swipe-nav flick ignored (app not navigable)");
            }
            return;
        }
        // The chord posts at the HID tap, which delivers to the OS's KEY-FOCUS holder — not
        // necessarily this session's app. The allowlist answered "is the PANE's app navigable";
        // this answers "will the chord actually land there". A nil frontmost read passes through,
        // matching the raise policy's trust in the same z-order proxy.
        if self.pid > 0
            && let Some(front) = frontmost_pid()
            && front != self.pid
        {
            if self.gates.swipe_nav_trace {
                trace(&format!(
                    "swipe-nav(pid {} win {}) suppressed (target not frontmost, front pid {front})",
                    self.pid, self.window_id,
                ));
            }
            if let Some(raise) = raise {
                let _ = raise.send(());
            }
            return;
        }
        if self.input_trace {
            let arrow = if fired == SwipeDirection::Back {
                "⌘[ back"
            } else {
                "⌘] forward"
            };
            trace(&format!("swipe-nav → {arrow}"));
        }
        let key_code = if fired == SwipeDirection::Back {
            KEY_LEFT_BRACKET
        } else {
            KEY_RIGHT_BRACKET
        };
        // BRACKETED chord, never a bare flagged pair: a synthetic key posted with the command mask
        // on both edges LATCHES ⌘ onto the shared event source, after which every later flag-less
        // synthetic event — scrolls included — inherits it and ordinary scrolling becomes zoom.
        // Posting the real ⌘ key around the letter, with the release carrying EMPTY flags, is
        // exactly the shape a forwarded client chord has and leaves the source state clean.
        //
        // EXCEPT when the user PHYSICALLY holds ⌘: the latch is already real, and a synthetic
        // release would be consumed by the balance as the one legitimate one — the user's actual
        // release then dedupes away and the host is left un-⌘'d mid-hold. Ride the real modifier
        // instead, and post the letter pair alone.
        let command_held = self.balance.lock().is_ok_and(|balance| {
            balance.held_modifier_keys().contains(&KEY_COMMAND)
                || balance.held_modifier_keys().contains(&KEY_RIGHT_COMMAND)
        });
        let command = InputModifiers::COMMAND;
        if !command_held {
            post_key(KEY_COMMAND, true, command);
        }
        post_key(key_code, true, command);
        post_key(key_code, false, command);
        if !command_held {
            post_key(KEY_COMMAND, false, InputModifiers::from_bits(0));
        }
    }
}

// ---------------------------------------------------------------------------------- //
// The two pumps
// ---------------------------------------------------------------------------------- //

/// The raise pump: one serial worker, throttled, owning the resolved element.
///
/// Everything it needs beyond [`Core`] is a local, because it is the only thread that touches any
/// of it — the accessibility pair, the first-interaction flag, and the clock.
fn raise_pump(core: &Arc<Core>, jobs: &Receiver<()>) {
    let mut target = RaiseTarget::new(core.pid, core.window_id);
    let mut raised_once = false;
    let mut last_raise: Option<Instant> = None;
    while jobs.recv().is_ok() {
        // Skip the whole chain when the app is ALREADY frontmost and has been raised once. Errs
        // toward raising: a backgrounded window, a different frontmost app, or an unreadable
        // frontmost still runs it.
        let frontmost = frontmost_pid();
        let will_raise = should_raise(frontmost, core.pid, !raised_once);
        if core.input_trace {
            let front = frontmost.map_or_else(|| "nil".to_owned(), |pid| pid.to_string());
            let verdict = if will_raise {
                "RAISE(full AX chain)"
            } else {
                "SKIP(no AX)"
            };
            trace(&format!(
                "raise decision frontmost={front} target={} first={} -> {verdict}",
                core.pid, !raised_once,
            ));
        }
        if !will_raise {
            continue;
        }
        if last_raise.is_some_and(|at| at.elapsed() < RAISE_THROTTLE) {
            continue;
        }
        last_raise = Some(Instant::now());
        raised_once = true;
        // The frame is lent only as the fallback the resolution uses when the private id symbol
        // answers for NO candidate, the locked-screen case.
        let _ = target.raise(core.frame());
        let _ = slopdesk_apple_app::activate(core.pid);
    }
}

/// The scroll pump: ingest and output timer in one `recv_timeout`.
///
/// A job arriving folds into the resampler and emits its markers plus the first chunk immediately,
/// so a fresh scroll moves pixels on the arrival hop rather than a tick later; the timeout arm is
/// the steady output rate. With NOTHING left to meter out the wait has no deadline at all — an idle
/// pump costs zero wakeups.
#[expect(
    clippy::integer_division,
    reason = "a period in whole nanoseconds from a whole-hertz rate; the truncation is the answer"
)]
fn scroll_pump(core: &Arc<Core>, jobs: &Receiver<ScrollJob>, raise: Option<&Sender<()>>, hz: u64) {
    let interval = Duration::from_nanos((NANOS_PER_SECOND / hz).max(1));
    let mut resampler = ScrollResampler::new(core.gates.scroll_spread, ScrollResampler::DEFAULT_LAG_CAP);
    // The tag of the latest forwarded scroll, replayed onto the interpolated sub-events so the
    // self-inject filter still recognises them.
    let mut last_tag = 0_u32;
    loop {
        // `is_idle` is exactly the condition under which `drain` answers `None`, so a deadline
        // while it holds buys a wakeup and nothing else.
        let job = if resampler.is_idle() {
            jobs.recv().map_err(|_| RecvTimeoutError::Disconnected)
        } else {
            jobs.recv_timeout(interval)
        };
        match job {
            Ok(ScrollJob::Scroll {
                dx,
                dy,
                scroll_phase,
                momentum_phase,
                continuous,
                tag,
            }) => {
                last_tag = tag;
                for marker in resampler.ingest(dx, dy, scroll_phase, momentum_phase, continuous) {
                    core.post_scroll(
                        marker.dx,
                        marker.dy,
                        marker.scroll_phase,
                        marker.momentum_phase,
                        marker.continuous,
                        tag,
                    );
                }
                if let Some(sub) = resampler.drain() {
                    core.post_scroll(
                        sub.dx,
                        sub.dy,
                        sub.scroll_phase,
                        sub.momentum_phase,
                        sub.continuous,
                        tag,
                    );
                }
            },
            Ok(ScrollJob::SwipeNav(fired)) => core.post_nav_chord(fired, raise),
            Err(RecvTimeoutError::Timeout) => {
                if let Some(sub) = resampler.drain() {
                    core.post_scroll(
                        sub.dx,
                        sub.dy,
                        sub.scroll_phase,
                        sub.momentum_phase,
                        sub.continuous,
                        last_tag,
                    );
                }
            },
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

// ---------------------------------------------------------------------------------- //
// Resolving the operating point
// ---------------------------------------------------------------------------------- //

/// Both gate families, read off the launch overlay in one pass.
///
/// Total: a missing key is one the environment does not set, which every parse rule in both
/// families already answers with its own default. There is no such thing as an unresolvable
/// operating point.
///
/// `SLOPDESK_INPUT_TRACE` is deliberately absent from the read: the session's own gate table
/// already resolves it and hands it in, and a key looked up twice is the drift these tables exist
/// to delete.
fn resolve(overlay: &Overlay, input_trace: bool) -> (InjectorGates, SwipeNavHostConfig) {
    let injector_values = overlay.resolve(&KEYS);
    let mut injector: [Option<&str>; KEYS.len()] = [None; KEYS.len()];
    for (slot, held) in injector.iter_mut().zip(injector_values.iter()) {
        *slot = held.as_deref();
    }
    // The SAME resolution the status beat makes, and asked of it rather than repeated: the chord
    // this injector fires and the chip that promises it must be the one operating point.
    let swipe_nav = crate::navstatus::operating_point(overlay);
    let swipe_trace = overlay.get(SWIPE_NAV_TRACE_KEY);
    let gates = InjectorGates::from_env(&injector, swipe_trace.as_deref(), InjectorGateContext {
        input_trace,
    });
    (gates, swipe_nav)
}

/// The regime banner: one line per injector naming the swipe-nav threshold family.
///
/// A field log spanning host restarts self-describes which recogniser produced each verdict —
/// without it, an audit once carried two lines from a stale build that were identifiable only by
/// their message format having since changed.
fn announce_regime(pid: i32, window_id: u32, gates: &InjectorGates, swipe_nav: &SwipeNavHostConfig) {
    if !gates.swipe_nav_trace || !swipe_nav.enabled {
        return;
    }
    let travel = swipe_nav.fire_travel;
    let slow = if swipe_nav.slow_tier { "on" } else { "off" };
    let millis = |seconds: f64| (seconds * 1000.0).trunc();
    trace(&format!(
        "swipe-nav regime(pid {pid} win {window_id}) fireTravel={} slow={slow} grace={}→{}ms \
         band={}×@{}→{}×@{} refractory={}ms",
        travel.trunc(),
        millis(FLICK_MAX_DURATION),
        millis(SLOW_GRACE_MAX_DURATION),
        SLOW_DOMINANCE.trunc(),
        (travel * 2.0).trunc(),
        SLOW_RELAXED_DOMINANCE.trunc(),
        (travel * 3.0).trunc(),
        millis(REFRACTORY),
    ));
}

// ---------------------------------------------------------------------------------- //
// The handle
// ---------------------------------------------------------------------------------- //

/// The held-button and held-modifier ledger, as a snapshot.
///
/// The session reads this off the STALE injector at teardown and seeds the replacement with it, so
/// a transparent auto-reconnect never wipes the knowledge of what the user is physically holding.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HeldInput {
    /// The held modifier keys, as the balance's own mask — one bit per code in its held-key table.
    pub modifiers: u16,
    /// The held mouse buttons, likewise — one bit per button.
    pub buttons: u8,
}

/// One session's injector: the shared state, and the threads that outlive a call into it.
#[derive(Debug)]
pub struct Injector {
    /// What both threads and every caller read.
    core: Arc<Core>,
    /// The raise worker. Absent for a display-scoped session, which has no window to raise.
    raise: Option<Pump<()>>,
    /// The resampler worker. Absent when the resampler is off, which is the direct-post path.
    scroll: Option<Pump<ScrollJob>>,
}

impl Drop for Injector {
    fn drop(&mut self) {
        // ORDER: the scroll pump may still send a suppressed chord's raise request, so it stops
        // first and the raise pump's channel outlives it. Reversing these would drop a raise on the
        // floor at teardown — harmless, but only by luck.
        if let Some(scroll) = self.scroll.as_mut() {
            scroll.stop();
        }
        if let Some(raise) = self.raise.as_mut() {
            raise.stop();
        }
    }
}

impl Injector {
    /// Builds one session's injector and starts whichever threads it needs.
    ///
    /// `pid` is `0` for a DISPLAY-scoped session, which raises nothing: whole-desktop input goes to
    /// whatever is frontmost, exactly like a local user's.
    ///
    /// `held` SEEDS the balance, and is what a stale injector's [`Self::balance`] answered. A
    /// transparent reconnect rebuilds the injector while the user may still be physically holding a
    /// drag or ⌘; seeding empty would classify the eventual release as an orphan, suppress it, and
    /// strand the host mid-drag.
    #[must_use]
    pub fn new(
        overlay: &Overlay,
        input_trace: bool,
        pid: i32,
        window_id: u32,
        bounds: VideoRect,
        held: HeldInput,
    ) -> Self {
        let (gates, swipe_nav) = resolve(overlay, input_trace);
        announce_regime(pid, window_id, &gates, &swipe_nav);
        let core = Arc::new(Core {
            pid,
            window_id,
            gates,
            input_trace,
            bounds: Mutex::new(bounds),
            balance: Mutex::new(InputButtonBalance::from_masks(held.buttons, held.modifiers)),
            swipe: Mutex::new(SwipeNavRecognizer::new(
                swipe_nav.fire_travel,
                swipe_nav.slow_tier,
                gates.swipe_nav_trace,
            )),
            swipe_nav,
            clock: Instant::now(),
        });
        let raise = (pid > 0).then(|| {
            let (jobs, inbox) = channel();
            let shared = Arc::clone(&core);
            Pump {
                jobs: Some(jobs),
                thread: std::thread::Builder::new()
                    .name("slopdesk.window-raise".to_owned())
                    .spawn(move || raise_pump(&shared, &inbox))
                    .ok(),
            }
        });
        let hz = u64::try_from(core.gates.scroll_resample_hz).unwrap_or(0);
        let scroll = (hz > 0).then(|| {
            let (jobs, inbox) = channel();
            let shared = Arc::clone(&core);
            let retry = raise.as_ref().and_then(|pump: &Pump<()>| pump.jobs.clone());
            Pump {
                jobs: Some(jobs),
                thread: std::thread::Builder::new()
                    .name("slopdesk.scroll-resample".to_owned())
                    .spawn(move || scroll_pump(&shared, &inbox, retry.as_ref(), hz))
                    .ok(),
            }
        });
        Self { core, raise, scroll }
    }

    /// The raise pump's channel, for the scroll pump's suppressed-chord retry.
    fn raise_sender(&self) -> Option<&Sender<()>> {
        self.raise.as_ref().and_then(|pump| pump.jobs.as_ref())
    }

    /// Routes a forwarded wire scroll: straight out on the direct path, or onto the pump.
    fn route_scroll(
        &self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
        tag: u32,
    ) {
        let Some(jobs) = self.scroll.as_ref().and_then(|pump| pump.jobs.as_ref()) else {
            self.core
                .post_scroll(dx, dy, scroll_phase, momentum_phase, continuous, tag);
            return;
        };
        let _ = jobs.send(ScrollJob::Scroll {
            dx,
            dy,
            scroll_phase,
            momentum_phase,
            continuous,
            tag,
        });
    }

    /// Feeds the recogniser and, on a qualifying completed flick, fires the chord.
    ///
    /// On the direct path the chord runs strictly after the gesture's `ended` scroll was posted; in
    /// resample mode the residual and that marker post asynchronously on the pump, so the fire is
    /// hopped onto the same thread and FIFO keeps the key after the stream it belongs to.
    fn feed_swipe_recognizer(
        &self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
    ) {
        if !self.core.swipe_nav.enabled {
            return;
        }
        let now = self.core.clock.elapsed().as_secs_f64();
        let Ok(mut swipe) = self.core.swipe.lock() else {
            return;
        };
        let fired = swipe.ingest(dx, dy, scroll_phase, momentum_phase, continuous, now);
        let verdict = swipe.take_trace_line();
        drop(swipe);
        if let Some(line) = verdict {
            // Tagged with the capture target so two concurrent injectors stay attributable in the
            // shared stderr log.
            trace(&format!(
                "swipe-nav(pid {} win {}) {line}",
                self.core.pid, self.core.window_id,
            ));
        }
        let Some(fired) = fired else {
            return;
        };
        match self.scroll.as_ref().and_then(|pump| pump.jobs.as_ref()) {
            Some(jobs) => {
                let _ = jobs.send(ScrollJob::SwipeNav(fired));
            },
            None => self.core.post_nav_chord(fired, self.raise_sender()),
        }
    }
}

impl InputInjector for Injector {
    /// Posts one remote input event, having first applied the safety plan the balance decides.
    fn inject(&self, event: &InputEvent) {
        let Ok(mut balance) = self.core.balance.lock() else {
            return;
        };
        let plan = balance.plan(event);
        drop(balance);
        // SAFETY auto-release: clear a button left stuck by a lost up BEFORE posting a fresh down
        // on it, so a click never begins inside a phantom selection.
        if let (Some(stuck), InputEvent::MouseDown(down, tag)) = (plan.pre_release, event) {
            if self.core.input_trace {
                trace(&format!("SAFETY pre-release of stuck {stuck:?} before mouseDown"));
            }
            self.core
                .post_button(stuck, down.normalized, false, 1, down.modifiers, *tag);
        }
        if plan.suppress {
            // A duplicate up from the client's loss-resilient 3× send — drop it so the host never
            // posts a spurious extra up.
            if self.core.input_trace {
                trace("suppressed duplicate mouseUp (button not held)");
            }
            return;
        }
        match *event {
            InputEvent::MouseMove { normalized, tag } => self.core.post_move(normalized, tag),
            InputEvent::MouseDown(ref button, tag) => {
                self.core.post_button(
                    button.button,
                    button.normalized,
                    true,
                    button.click_count,
                    button.modifiers,
                    tag,
                );
            },
            InputEvent::MouseUp(ref button, tag) => {
                self.core.post_button(
                    button.button,
                    button.normalized,
                    false,
                    button.click_count,
                    button.modifiers,
                    tag,
                );
            },
            InputEvent::MouseDrag(ref button, tag) => {
                self.core.post_drag(
                    button.button,
                    button.normalized,
                    button.click_count,
                    button.modifiers,
                    tag,
                );
            },
            InputEvent::Scroll(ref scroll, tag) => {
                self.route_scroll(
                    scroll.dx,
                    scroll.dy,
                    scroll.scroll_phase,
                    scroll.momentum_phase,
                    scroll.continuous,
                    tag,
                );
                self.feed_swipe_recognizer(
                    scroll.dx,
                    scroll.dy,
                    scroll.scroll_phase,
                    scroll.momentum_phase,
                    scroll.continuous,
                );
            },
            InputEvent::Key(ref key, _) => {
                post_key(key.key_code, key.down, key.modifiers);
            },
            InputEvent::Text(ref text, _) => {
                let _ = slopdesk_apple_cgevent::post_text(text);
            },
        }
    }

    /// What the user is physically holding right now, for seeding a replacement.
    fn balance(&self) -> HeldInput {
        let Ok(balance) = self.core.balance.lock() else {
            return HeldInput::default();
        };
        let (buttons, modifiers) = balance.masks();
        HeldInput { modifiers, buttons }
    }

    /// Re-points the coordinate mapping at `bounds`, in GLOBAL CG points.
    ///
    /// The rectangle every normalised client point is projected through, so it is the CAPTURE's
    /// rectangle rather than the window's: a dialog-expand session maps against the union, which is
    /// what keeps a click in the overhanging panel landing where the person aimed it.
    ///
    /// A poisoned lock leaves the previous mapping in place, which is the honest degradation — a
    /// stale origin puts clicks a window-move away from where they were aimed, and no mapping at
    /// all would put every one of them at the desktop origin.
    fn update_bounds(&self, bounds: VideoRect) {
        if let Ok(mut frame) = self.core.bounds.lock() {
            *frame = bounds;
        }
    }

    /// Requests the raise chain for the first event of an interaction, and returns IMMEDIATELY.
    ///
    /// The chain is six to ten synchronous accessibility round-trips against a backgrounded target
    /// — measured at one to seven seconds — which is why it never runs on the caller's thread.
    /// A display-scoped session has nothing to raise and this is a no-op.
    fn raise_target_window(&self) {
        if let Some(jobs) = self.raise_sender() {
            let _ = jobs.send(());
        }
    }
}

/// The resampler's output rate, or `0` for the direct-post path.
///
/// The session's own gate table needs this BEFORE any injector exists — the scroll coalescer's
/// default follows it, because the resampler already caps the post rate and stacking the summing
/// gate under it double-quantizes the stream.
#[must_use]
pub fn resample_hz(overlay: &Overlay) -> i64 {
    resolve(overlay, false).0.scroll_resample_hz
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::VideoRect;

    use super::{HeldInput, Injector, resample_hz};
    use crate::env::Overlay;
    use crate::session_inbound::InputInjector as _;

    /// A DISPLAY-scoped injector raises nothing, so it must start no raise thread at all — the
    /// whole-desktop pane has no window to bring forward and asking the tree for one would cost an
    /// accessibility round trip per click for an answer that can only be `None`.
    #[test]
    fn a_display_scoped_injector_starts_no_raise_pump() {
        let injector = Injector::new(
            &Overlay::default(),
            false,
            0,
            0,
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            HeldInput::default(),
        );
        assert!(
            injector.raise.is_none(),
            "pid 0 is the full-desktop target, which has no window to raise"
        );
    }

    /// The seed is what makes a transparent reconnect safe: the replacement must answer the held
    /// state it was handed, or the eventual release reads as an orphan and is suppressed.
    #[test]
    fn the_balance_seed_survives_construction() {
        let held = HeldInput {
            modifiers: 0b101,
            buttons: 0b10,
        };
        let injector = Injector::new(
            &Overlay::default(),
            false,
            0,
            0,
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            held,
        );
        assert_eq!(injector.balance(), held);
    }

    /// The bounds are the coordinate mapping's only input, and the geometry watcher rewrites them
    /// from another thread as the window moves.
    #[test]
    fn updating_the_bounds_repoints_the_mapping() {
        let injector = Injector::new(
            &Overlay::default(),
            false,
            0,
            0,
            VideoRect::xywh(0.0, 0.0, 100.0, 100.0),
            HeldInput::default(),
        );
        let moved = VideoRect::xywh(40.0, 60.0, 800.0, 600.0);
        injector.update_bounds(moved);
        assert_eq!(injector.core.frame(), moved);
    }

    /// An empty overlay is a fresh machine, and the rate it answers there is the family's own
    /// default — not zero, which would silently take every install off the resampled path.
    ///
    /// The three-way parse itself — unset, an explicit zero, an unparseable value — is
    /// `slopdesk_video::injector_gates`'s own test. What is pinned HERE is that the daemon reaches
    /// that table through the overlay at all, which is the half a rules-crate test cannot see.
    #[test]
    fn an_empty_overlay_answers_the_default_resample_rate() {
        assert!(
            resample_hz(&Overlay::default()) > 0,
            "an unset key is the default rate, and the default rate runs the pump"
        );
    }
}
