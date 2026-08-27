//! Remote input's last stop: the raise chain, the scroll resampler's pump, the swipe-back
//! translation, and every event that reaches the window server.
//!
//! `Sources/SlopDeskVideoHost/InputInjector.swift` was 735 lines that owned no RULE. Every decision
//! it made already had a twin here — the button balance, the raise policy, the resampler, the flick
//! recogniser, the navigable-app allowlist — and every effect it caused was already a door. What
//! kept the file alive was four pieces of machinery: two `DispatchQueue`s, one
//! `DispatchSourceTimer` and three `NSLock`s. This handle is those four things, which is the whole
//! port; eight doors go away with the file it replaces.
//!
//! Four crates meet here, which is the reason this module is in the shim rather than in any of them
//! — the same argument [`crate::ax`] and [`crate::cursor_sampler`] make, and for the same shape of
//! orchestration:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::input_routing`] | which button is stuck, which up is a duplicate, whether to raise |
//! | `slopdesk-apple-cgevent` | the pointer, scroll, key and text events, built and posted |
//! | `slopdesk-apple-ax` / `slopdesk-apple-app` | raising the window, and bringing its app forward |
//! | `slopdesk-apple-cgwindow` | who is frontmost, which both the raise and the chord gate on |
//!
//! ## Why the whole orchestration is here and not in Swift
//!
//! One click is: consult the balance, maybe post a synthetic release, map a normalised point
//! against bounds another thread is updating, post an event, and — off two other threads — run six
//! to ten accessibility round-trips and drain a resampler at 250 Hz. The ORDER is load-bearing at
//! every step, and every one of those steps is either a rule that is already Rust or an effect that
//! is already Rust. Leaving the sequence in Swift kept a dozen rules and their only caller on
//! opposite sides of the boundary, and made each crossing a chance to reorder them.
//!
//! ## This is the second handle that may be called from more than one thread
//!
//! The crate header's handle convention says no two calls on one handle may overlap; every handle
//! but [`crate::cursor_sampler`]'s keeps it because its Swift owner is already serialised. This one
//! cannot, and the reason is structural rather than incidental:
//!
//! * the session actor calls [`slopdesk_injector_inject`] and [`slopdesk_injector_raise`],
//! * the geometry watcher calls [`slopdesk_injector_update_bounds`] as the window moves,
//! * teardown calls [`slopdesk_injector_balance`] to carry held state into the replacement,
//! * and the two threads this handle OWNS call back into it — the raise pump reads the bounds, the
//!   scroll pump reads the balance and posts.
//!
//! So it carries its own locks instead of borrowing the caller's. There are three, each around a
//! few field assignments, and none is ever held across a framework call: a lock held across an
//! accessibility round-trip would reintroduce exactly the multi-second main-thread stall the raise
//! thread exists to prevent.
//!
//! ## The two threads, which are the only thing here that is new
//!
//! Neither is a translation of a `DispatchQueue`; both are the shape that queue was imitating.
//!
//! * The RAISE pump is a serial worker over a channel. It owns the resolved accessibility element
//!   ([`RaiseTarget`]), the first-interaction flag and the throttle clock as plain locals, because
//!   it is the only thread that touches them — three of the Swift's fields and one of its locks
//!   dissolve into thread confinement.
//! * The SCROLL pump is one `recv_timeout` loop, and that single call is BOTH the ingest queue and
//!   the output timer: a job arrives, or the interval elapses and the residual drains. The
//!   `DispatchSourceTimer` and its start/cancel lifetime go away, and the resampler becomes a local
//!   rather than a locked field.
//!
//! Both threads are spawned only when they have work — no target window means no raise pump, and a
//! disabled resampler means no scroll pump and the direct-post path the Swift had. Both hold an
//! `Arc` of the shared state and exit when the handle drops its sender, which is what makes
//! [`slopdesk_injector_free`] a join rather than a cancel.

use core::ffi::c_uchar;
use std::io::Write as _;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_apple_cgevent::{Button, PointerKind, PointerPost, ScrollPost};
use slopdesk_apple_cgwindow::frontmost_pid;
use slopdesk_video::blob_list;
use slopdesk_video::coordinate_mapping::window_point;
use slopdesk_video::geometry::{VideoPoint, VideoRect};
use slopdesk_video::injector_gates::{InjectorGateContext, InjectorGates, KEYS, SWIPE_NAV_TRACE_KEY};
use slopdesk_video::input_event::{InputEvent, InputModifiers, MouseButton};
use slopdesk_video::input_routing::{InputButtonBalance, should_raise};
use slopdesk_video::scroll_resample::ScrollResampler;
use slopdesk_video::swipe_nav::SwipeDirection;
use slopdesk_video::swipe_nav_config::{KEYS as SWIPE_NAV_KEYS, SwipeNavHostConfig};
use slopdesk_video::swipe_recognizer::{
    FLICK_MAX_DURATION, REFRACTORY, SLOW_DOMINANCE, SLOW_GRACE_MAX_DURATION, SLOW_RELAXED_DOMINANCE,
    SwipeNavRecognizer,
};

use crate::ax::RaiseTarget;
use crate::input_event::{SlopDeskInputEvent, rebuild};
use crate::input_routing::SlopDeskInputBalance;
use crate::video_policy::SlopDeskVideoRect;
use crate::{borrow, deliver};

/// The minimum spacing between two raise chains, in seconds.
///
/// One click fires several raise requests — the proactive focus, the down's own, each
/// loss-resilient duplicate up, and the first move after the up. Without this they pile up on the
/// raise thread as N futile accessibility chains per click. Coalescing is harmless because the
/// raise is best-effort: the posted events deliver either way.
const RAISE_THROTTLE: Duration = Duration::from_millis(500);

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
// The shared state
// ---------------------------------------------------------------------------------- //

/// Everything both threads and every door read: the target, the operating point, and the three
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
            // A pump that panicked has already left its loop, which is all this call is waiting for.
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
/// same-typed argument list four booleans deep — the Swift's `pointerSpec`, kept.
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
    /// The Parsec path (`tablet_mouse`, real injection only — the loopback seam keeps the warp) is
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

impl Core {
    /// The app whose NAVIGABILITY the translation is judged against: the tracked window's app for a
    /// window-scoped session, the frontmost app for a display-scoped one. Both reads go through the
    /// window server rather than a workspace snapshot, which freezes at first access and would pin
    /// the verdict to whatever was frontmost the first time this process looked.
    fn swipe_nav_bundle_id(&self) -> Option<String> {
        if self.pid > 0 {
            return slopdesk_apple_app::bundle_id(self.pid);
        }
        slopdesk_apple_app::bundle_id(frontmost_pid()?)
    }

    /// The allowlist check, the focus check, and the chord itself.
    ///
    /// `raise` is the raise pump's channel: a suppressed chord kicks a raise so an immediate retry
    /// lands in the now-raised target.
    fn fire_swipe_nav(&self, fired: SwipeDirection, raise: Option<&Sender<()>>) {
        // Only drive apps where ⌘[ / ⌘] is history navigation — in an editor it EDITS TEXT, so an
        // unknown app gets nothing beyond the scroll it already received.
        if !self.swipe_nav.eligible(self.swipe_nav_bundle_id().as_deref()) {
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
/// of it — the accessibility element (which is a Core Foundation object with no thread-safety
/// contract, so confinement is not merely tidier), the first-interaction flag, and the clock.
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
/// the steady output rate. With NOTHING left to meter out the wait has no deadline at all — an
/// idle pump costs zero wakeups, where the `DispatchSourceTimer` it replaced kept ticking from the
/// first scroll of the session to the last.
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
            Ok(ScrollJob::SwipeNav(fired)) => core.fire_swipe_nav(fired, raise),
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
// The handle
// ---------------------------------------------------------------------------------- //

/// One session's injector: the shared state, and the threads that outlive a call into it.
#[derive(Debug)]
pub struct SlopDeskInjector {
    /// What both threads and every door read.
    core: Arc<Core>,
    /// The raise worker. Absent for a display-scoped session, which has no window to raise.
    raise: Option<Pump<()>>,
    /// The resampler worker. Absent when the resampler is off, which is the direct-post path.
    scroll: Option<Pump<ScrollJob>>,
}

impl Drop for SlopDeskInjector {
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

impl SlopDeskInjector {
    /// The raise pump's channel, for the scroll pump's suppressed-chord retry.
    fn raise_sender(&self) -> Option<&Sender<()>> {
        self.raise.as_ref().and_then(|pump| pump.jobs.as_ref())
    }

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
                self.translate_swipe_nav(
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
    fn translate_swipe_nav(&self, dx: f64, dy: f64, scroll_phase: u8, momentum_phase: u8, continuous: bool) {
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
            None => self.core.fire_swipe_nav(fired, self.raise_sender()),
        }
    }
}

// ---------------------------------------------------------------------------------- //
// Resolving the operating point
// ---------------------------------------------------------------------------------- //

/// The two families' keys plus the one name that belongs to neither, in the order the resolver
/// reads their values.
fn gate_keys() -> Vec<&'static str> {
    let mut names = Vec::with_capacity(KEYS.len() + SWIPE_NAV_KEYS.len() + 1);
    names.extend_from_slice(&KEYS);
    names.extend_from_slice(&SWIPE_NAV_KEYS);
    names.push(SWIPE_NAV_TRACE_KEY);
    names
}

/// The blob's entries as texts in key order, or `None` when the caller built the list wrong — which
/// it can only do from its own environment, so there is nothing to salvage.
fn texts(blob: &[u8]) -> Option<Vec<Option<&str>>> {
    let entries = blob_list::decode(blob)?;
    if entries.len() != gate_keys().len() {
        return None;
    }
    let mut out = Vec::with_capacity(entries.len());
    for entry in entries {
        match entry {
            None => out.push(None),
            Some(bytes) => out.push(Some(core::str::from_utf8(bytes).ok()?)),
        }
    }
    Some(out)
}

/// Both tables, from the texts of [`gate_keys`].
///
/// Total: a missing text is a key the environment does not set, which every parse rule in both
/// families already answers with its own default. There is no such thing as an unresolvable
/// operating point, only an unreadable BLOB — and [`texts`] is where that is refused.
fn resolve(values: &[Option<&str>], input_trace: bool) -> (InjectorGates, SwipeNavHostConfig) {
    let at = |key: &str| -> Option<&str> {
        gate_keys()
            .iter()
            .position(|name| *name == key)
            .and_then(|index| values.get(index).copied().flatten())
    };
    let mut injector: [Option<&str>; KEYS.len()] = [None; KEYS.len()];
    for (slot, key) in injector.iter_mut().zip(KEYS) {
        *slot = at(key);
    }
    let swipe_nav = SwipeNavHostConfig::from_env(
        at("SLOPDESK_SWIPE_NAV"),
        at("SLOPDESK_SWIPE_NAV_APPS"),
        at("SLOPDESK_SWIPE_NAV_TRAVEL"),
        at("SLOPDESK_SWIPE_NAV_SLOW"),
        at("SLOPDESK_SWIPE_NAV_HISTORY"),
    );
    let gates = InjectorGates::from_env(&injector, at(SWIPE_NAV_TRACE_KEY), InjectorGateContext {
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
// The doors
// ---------------------------------------------------------------------------------- //

/// The environment keys, NUL-joined, in the order [`slopdesk_injector_new`] reads their values.
///
/// Two gate families and one name that is in neither, delivered as ONE list because the caller
/// resolves them all through the same overlay-aware lookup in the same breath.
/// `SLOPDESK_INPUT_TRACE` is deliberately absent: the session's own gate table already resolves it,
/// and a key looked up twice is the drift these lists exist to delete.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_injector_gate_keys(out: *mut c_uchar, cap: usize) -> usize {
    let answer = gate_keys().join("\0");
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The resampler's output rate, or `0` for the direct-post path.
///
/// The session's own gate table needs this BEFORE any injector exists — the scroll coalescer's
/// default follows it, because the resampler already caps the post rate and stacking the summing
/// gate under it double-quantizes the stream. So the one field crosses on its own rather than the
/// caller re-deriving a rule from a key it would have to spell itself.
///
/// # Safety
/// `values` must be null or point to `len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the blob is the caller's to keep live"
)]
pub unsafe extern "C" fn slopdesk_injector_resample_hz(values: *const c_uchar, len: usize) -> i64 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let blob = unsafe { borrow(values, len) };
    let Some(texts) = texts(blob) else {
        return InjectorGates::DEFAULT_RESAMPLE_HZ;
    };
    resolve(&texts, false).0.scroll_resample_hz
}

/// Builds one session's injector and starts whichever threads it needs. Never null.
///
/// `pid` is `0` for a DISPLAY-scoped session, which raises nothing: whole-desktop input goes to
/// whatever is frontmost, exactly like a local user's.
///
/// `held` SEEDS the balance, and is what a stale injector's [`slopdesk_injector_balance`] answered
/// — the same [`SlopDeskInputBalance`] record the per-event fold already crosses as, per `docs/55`
/// §4b. A transparent reconnect rebuilds the injector while the user may still be physically
/// holding a drag or ⌘; seeding empty would classify the eventual release as an orphan, suppress
/// it, and strand the host mid-drag.
///
/// # Safety
/// `values` must be null or point to `len` live bytes. The answer must be passed to
/// [`slopdesk_injector_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_injector_new(
    values: *const c_uchar,
    len: usize,
    input_trace: bool,
    pid: i32,
    window_id: u32,
    bounds: SlopDeskVideoRect,
    held: SlopDeskInputBalance,
) -> *mut SlopDeskInjector {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let blob = unsafe { borrow(values, len) };
    // An unreadable list is a caller that built it from its own environment wrong, so there is
    // nothing to salvage and nothing to guess: every gate takes the default it would have taken had
    // the environment been empty, which is the operating point a fresh machine runs.
    let (gates, swipe_nav) = texts(blob).map_or_else(
        || {
            (
                InjectorGates::from_env(&[None; KEYS.len()], None, InjectorGateContext { input_trace }),
                SwipeNavHostConfig::from_env(None, None, None, None, None),
            )
        },
        |texts| resolve(&texts, input_trace),
    );
    announce_regime(pid, window_id, &gates, &swipe_nav);
    let core = Arc::new(Core {
        pid,
        window_id,
        gates,
        input_trace,
        bounds: Mutex::new(bounds.of()),
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
    Box::into_raw(Box::new(SlopDeskInjector { core, raise, scroll }))
}

/// Views an injector handle as a shared reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_injector_new`].
#[expect(
    unsafe_code,
    reason = "the shim's whole job is turning a caller's pointer into a reference"
)]
const unsafe fn injector<'a>(handle: *const SlopDeskInjector) -> Option<&'a SlopDeskInjector> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, above.
    Some(unsafe { &*handle })
}

/// Stops both threads and releases the injector. Null is inert.
///
/// This JOINS rather than cancels. A pump still holding an `Arc` of the shared state when the box
/// went away would be reading freed memory the moment the last handle dropped, so the wait is the
/// safety property and not a courtesy — and it is bounded, because the only thing either thread
/// blocks on is the channel this call closes.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_injector_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_injector_free(handle: *mut SlopDeskInjector) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free, and `Drop` joins both pumps.
    drop(unsafe { Box::from_raw(handle) });
}

/// Re-points the coordinate mapping at the window's current frame.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_injector_update_bounds(
    handle: *mut SlopDeskInjector,
    bounds: SlopDeskVideoRect,
) {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { injector(handle) }) else {
        return;
    };
    if let Ok(mut frame) = state.core.bounds.lock() {
        *frame = bounds.of();
    }
}

/// Requests the raise chain for the first event of an interaction, and returns IMMEDIATELY.
///
/// The chain is six to ten synchronous accessibility round-trips against a backgrounded target —
/// measured at one to seven seconds — which is why it never runs on the caller's thread. On the
/// main actor it starved the cursor-shape refresh, which `AppKit` makes main-only, for whole
/// seconds. A display-scoped session has nothing to raise and this is a no-op.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_injector_raise(handle: *mut SlopDeskInjector) {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { injector(handle) }) else {
        return;
    };
    if let Some(jobs) = state.raise_sender() {
        let _ = jobs.send(());
    }
}

/// Posts one remote input event.
///
/// `text` carries the text arm's bytes and is ignored by every other arm — the same split
/// [`crate::input_event`] uses, because a string has no home in a flat record and the caller is
/// already holding the datagram it came out of.
///
/// Answers whether the record described an event at all; a shape no arm answers to posts nothing.
///
/// # Safety
/// `handle` must be null or live, and `text` null or point to `text_len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_injector_inject(
    handle: *mut SlopDeskInjector,
    event: SlopDeskInputEvent,
    text: *const c_uchar,
    text_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { injector(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, text_len) };
    let Some(rebuilt) = rebuild(event, bytes) else {
        return false;
    };
    state.inject(&rebuilt);
    true
}

/// The held-button and held-modifier ledger, as a snapshot.
///
/// The session reads this off the STALE injector at teardown and threads it into the replacement's
/// seed, so a transparent auto-reconnect never wipes the knowledge of what the user is physically
/// holding. A record rather than a handle, per `docs/55` §4b: the balance is twelve bits, and a
/// handle for it would be an allocation to leak — the same reason the per-event fold already
/// crosses as one.
///
/// # Safety
/// `handle` must be null or live, and `out` null or writable for one [`SlopDeskInputBalance`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_injector_balance(
    handle: *const SlopDeskInjector,
    out: *mut SlopDeskInputBalance,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { injector(handle) }) else {
        return false;
    };
    let Ok(balance) = state.core.balance.lock() else {
        return false;
    };
    let (buttons, modifiers) = balance.masks();
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one of these — a plain
        // `Copy` aggregate of two integers.
        unsafe { out.write(SlopDeskInputBalance { modifiers, buttons }) };
    }
    true
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a test that cannot build its own fixture has already failed, and loudly is right"
)]
mod tests {
    use slopdesk_video::blob_list;
    use slopdesk_video::geometry::VideoRect;
    use slopdesk_video::injector_gates::InjectorGates;

    use super::{
        SlopDeskInputEvent, gate_keys, resolve, slopdesk_injector_balance, slopdesk_injector_free,
        slopdesk_injector_gate_keys, slopdesk_injector_inject, slopdesk_injector_new,
        slopdesk_injector_raise, slopdesk_injector_resample_hz, slopdesk_injector_update_bounds, texts,
    };
    use crate::input_routing::SlopDeskInputBalance;
    use crate::video_policy::SlopDeskVideoRect;

    /// The blob the caller builds: one entry per key, absent entries and all.
    fn blob(pairs: &[(&str, &str)]) -> Vec<u8> {
        let entries: Vec<Option<&[u8]>> = gate_keys()
            .iter()
            .map(|key| {
                pairs
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, value)| value.as_bytes())
            })
            .collect();
        blob_list::encode(&entries)
    }

    /// The names cross in the order the resolver reads them, and every one is named ONCE — a
    /// duplicate would make the by-name lookup answer for whichever came first and silently drop
    /// the other family's key.
    #[test]
    fn the_key_list_names_both_families_once_each() {
        let names = gate_keys();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len(), "a name is spelled twice");
        assert!(names.contains(&"SLOPDESK_SCROLL_RESAMPLE_HZ"));
        assert!(names.contains(&"SLOPDESK_SWIPE_NAV_APPS"));
        assert!(names.contains(&"SLOPDESK_SWIPE_NAV_TRACE"));
        assert!(
            !names.contains(&"SLOPDESK_INPUT_TRACE"),
            "the session's table resolves that one, and resolving it twice is the drift",
        );
    }

    /// The door hands over exactly those names, NUL-joined, under §4's size-then-fill convention.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn the_keys_door_delivers_the_list_it_reads() {
        // SAFETY: the null probe writes nothing, and the buffer below is a live local.
        let needed = unsafe { slopdesk_injector_gate_keys(std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is live and exactly `needed` bytes.
        let written = unsafe { slopdesk_injector_gate_keys(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        let joined = String::from_utf8(out).expect("the names are ASCII");
        assert_eq!(joined.split('\0').collect::<Vec<_>>(), gate_keys());
    }

    /// A blob of the wrong LENGTH is refused rather than read positionally — the failure mode a
    /// by-position table has, and the reason the length is checked before the lookup.
    #[test]
    fn a_blob_that_is_not_the_key_list_is_refused() {
        assert!(texts(&blob(&[])).is_some());
        let short = blob_list::encode(&[Some(b"250".as_slice())]);
        assert!(texts(&short).is_none(), "one entry is not the whole list");
        assert!(texts(b"\xff\xff").is_none(), "not a blob list at all");
    }

    /// Both families resolve from ONE list, by name — the property a positional read loses the
    /// moment either family gains a key.
    #[test]
    fn one_list_resolves_both_families_by_name() {
        let blob = blob(&[
            ("SLOPDESK_SCROLL_RESAMPLE_HZ", "9000"),
            ("SLOPDESK_SWIPE_NAV_TRAVEL", "120"),
            ("SLOPDESK_SWIPE_NAV_SLOW", "0"),
        ]);
        let texts = texts(&blob).expect("the blob is the key list");
        let (gates, swipe_nav) = resolve(&texts, false);
        assert_eq!(gates.scroll_resample_hz, 1000, "clamped to the band's ceiling");
        assert!(!swipe_nav.slow_tier);
        assert!(swipe_nav.enabled, "unset means on for that family");
        assert!(
            (swipe_nav.fire_travel - 120.0).abs() < f64::EPSILON,
            "the travel came from the same list",
        );
    }

    /// The trace key is OR-ed with the session's, which is the one input the list does not carry.
    #[test]
    fn the_session_trace_reaches_the_swipe_nav_trace_without_a_key() {
        let list = blob(&[]);
        let texts = texts(&list).expect("the blob is the key list");
        let (quiet, _) = resolve(&texts, false);
        let (loud, _) = resolve(&texts, true);
        assert!(!quiet.swipe_nav_trace);
        assert!(loud.swipe_nav_trace, "the session trace turns it on alone");
    }

    /// The rate door answers the resolved field, and answers the DEFAULT for a blob it cannot read
    /// — the resampler is on unless somebody said otherwise, and an unreadable list said nothing.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn the_rate_door_answers_the_field_and_defaults_a_bad_blob() {
        let list = blob(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "0")]);
        // SAFETY: `list` is a live local for the call.
        let off = unsafe { slopdesk_injector_resample_hz(list.as_ptr(), list.len()) };
        assert_eq!(off, 0, "an explicit zero disables it");
        // SAFETY: a null pair is the documented empty case.
        let unreadable = unsafe { slopdesk_injector_resample_hz(std::ptr::null(), 0) };
        assert_eq!(unreadable, InjectorGates::DEFAULT_RESAMPLE_HZ);
    }

    /// Null is inert on every door that takes a handle. The one arm a headless suite can reach on
    /// all six, and the one a caller hits when a session tore down mid-datagram.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn every_door_refuses_rather_than_faults() {
        let rect = SlopDeskVideoRect::from(VideoRect::xywh(0.0, 0.0, 10.0, 10.0));
        // SAFETY: every pointer here is null, which each door documents as inert.
        unsafe {
            slopdesk_injector_update_bounds(std::ptr::null_mut(), rect);
            slopdesk_injector_raise(std::ptr::null_mut());
            slopdesk_injector_free(std::ptr::null_mut());
            assert!(!slopdesk_injector_inject(
                std::ptr::null_mut(),
                SlopDeskInputEvent::default(),
                std::ptr::null(),
                0,
            ));
            assert!(!slopdesk_injector_balance(std::ptr::null(), std::ptr::null_mut()));
        }
    }

    /// The balance SURVIVES the rebuild, which is the reconnect fix in one assertion: what the
    /// stale injector answers is what seeds the replacement, and a held button crosses as a mask
    /// rather than as an object with a lifetime.
    ///
    /// Both injectors here are display-scoped with the resampler off, so NEITHER spawns a thread
    /// and no door reaches the window server — the one shape of this handle a headless suite may
    /// build.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_rebuilt_injector_carries_the_balance_the_stale_one_held() {
        let list = blob(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "0")]);
        let rect = SlopDeskVideoRect::from(VideoRect::xywh(0.0, 0.0, 100.0, 100.0));
        // SAFETY: `list` is live for the call, and the handle is freed at the end of the block.
        unsafe {
            let seed = SlopDeskInputBalance {
                modifiers: 0b11,
                buttons: 0b101,
            };
            let stale = slopdesk_injector_new(list.as_ptr(), list.len(), false, 0, 0, rect, seed);
            assert!(!stale.is_null());
            let mut held = SlopDeskInputBalance::default();
            assert!(slopdesk_injector_balance(stale, &raw mut held));
            assert_eq!(held, seed, "the seed survives the fold that never happened");
            let fresh = slopdesk_injector_new(list.as_ptr(), list.len(), false, 0, 0, rect, held);
            let mut carried = SlopDeskInputBalance::default();
            assert!(slopdesk_injector_balance(fresh, &raw mut carried));
            assert_eq!(carried, held);
            slopdesk_injector_free(fresh);
            slopdesk_injector_free(stale);
        }
    }
}
