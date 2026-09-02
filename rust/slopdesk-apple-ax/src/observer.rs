//! `AXObserver` — one application's window-level notifications, delivered on a thread of their own.
//!
//! ## Why this is here after all
//! The crate note used to say an observer is a SUBSCRIPTION rather than an effect, and therefore
//! not this family's. `slopdesk-apple-fsevents` settled that the other way: a run-loop-backed
//! subscription over an Apple framework is exactly this family's, and the shape it takes —
//! process-wide registry keyed by the handle's ADDRESS, a callback that follows no pointer, a NULL
//! context — is the shape §2 permits. This module is that shape a second time, for
//! `ApplicationServices` instead of `CoreServices`.
//!
//! The Swift it replaces reached the listener through `Unmanaged::fromOpaque(refcon)`, which is a
//! raw-pointer round trip §2 bars outright. The registry is what removes the need for one: the
//! framework already hands the callback the observer it fired for, and an address is a key.
//!
//! ## The thread, and why it runs the loop in SLICES
//! The daemon's main thread runs no `CFRunLoop`, so an observer needs one of its own — and a
//! beachballing target app must never stall anything but that thread ([`TIMEOUT`] caps even that).
//! The Swift kept the loop alive with a `Port` and re-pointed it from another thread through
//! `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`. This runs `CFRunLoopRunInMode` for
//! [`SLICE_SECONDS`] at a time instead and reads the wanted pid between slices, which costs a
//! wake-up ten times a second and buys two properties the block form does not have: the thread can
//! RETURN, so `Drop` can join it, and there is no block, no `WakeUp`, and no second thread reaching
//! into a run loop it does not own. A retarget therefore lands within a slice — well inside the 150
//! ms debounce the one caller already applies, and far inside the 1 Hz differ that is the backstop
//! for everything here.

use core::ffi::c_void;
use core::ptr::{self, NonNull};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

use objc2_application_services::{AXError, AXObserver, AXUIElement};
use objc2_core_foundation::{CFRetained, CFRunLoop, CFRunLoopMode, CFRunLoopSource, CFString};

use crate::attribute;

/// The per-message cap on the observed application, in seconds.
///
/// The same quarter second the rest of the host opens an application element with. An observer
/// installs by writing six notification registrations to the target app, and a hung app charges the
/// timeout for each; the cap is what bounds a fleet of them to this thread.
pub const TIMEOUT: f32 = 0.25;

/// How long one turn of the run loop is allowed to block, in seconds.
///
/// The retarget and the teardown are both read BETWEEN slices, so this is the worst-case latency of
/// either. A tenth of a second sits under the 150 ms debounce the caller applies to the events that
/// cause a retarget, so shortening it would buy nothing a person could see.
const SLICE_SECONDS: f64 = 0.1;

/// The six window-level notifications the feed differ wants an instant kick from.
///
/// Written as literals rather than read from the `kAX*Notification` `extern` statics, for the
/// reason [`crate::prompt_for_trust`] gives about its own key: reading an `extern` static is an
/// `unsafe` block whose obligation is strictly larger than the one it would discharge, and Apple
/// documents each of these constants as exactly the string below.
const NOTIFICATIONS: [&str; 6] = [
    "AXWindowCreated",
    "AXUIElementDestroyed",
    "AXTitleChanged",
    "AXFocusedWindowChanged",
    "AXWindowMiniaturized",
    "AXWindowDeminiaturized",
];

/// What the callback is allowed to do: nothing but tell somebody. No argument, because which window
/// changed is not this crate's to decode — the caller re-enumerates and diffs.
type Listener = Arc<dyn Fn() + Send + Sync + 'static>;

/// Every installed observer, keyed by the ADDRESS of the `AXObserverRef` the framework minted.
///
/// Process-wide because the callback is a plain function with no state of its own. The key is a
/// `usize` rather than a pointer so that "never followed" is a promise the compiler keeps rather
/// than one this file has to.
fn live() -> &'static Mutex<HashMap<usize, Listener>> {
    static LIVE: LazyLock<Mutex<HashMap<usize, Listener>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
    &LIVE
}

/// One observer handle's registry key.
fn key(observer: &AXObserver) -> usize {
    ptr::from_ref(observer).addr()
}

/// The default run-loop mode, the one mode an `AXObserver` source is added to.
///
/// # Safety
/// `kCFRunLoopDefaultMode` is an `extern` static CoreFoundation initialises when its image loads,
/// which is before any code that could call this has run. Rust cannot see that, so the read is
/// `unsafe`; the framework's contract is that it is a non-null immutable `CFRunLoopMode` for the
/// process's whole life.
#[expect(
    unsafe_code,
    reason = "the run-loop mode constant is an extern static; objc2 cannot generate it safe"
)]
fn default_mode() -> Option<&'static CFRunLoopMode> {
    // SAFETY: framework rule, above — initialised at image load, immutable, process-lifetime.
    unsafe { objc2_core_foundation::kCFRunLoopDefaultMode }
}

/// What the observer thread is being asked for, read between run-loop slices.
#[derive(Clone, Copy, Debug)]
struct Lane {
    /// The pid to observe. Zero and negatives name no process and install nothing, which is the
    /// state an observer starts in and the state a target that exited returns it to.
    wanted: i32,
    /// Set by [`Observer::drop`]; the thread returns at the end of the current slice.
    stop: bool,
}

/// An `AXObserver` installed for one pid, unwound when it drops.
///
/// Not `Clone`, for `slopdesk-apple-fsevents`' reason: the teardown below runs exactly once, and
/// "once" is a property of the type rather than of a comment.
struct Installed {
    /// The process being observed, so a retarget can tell a no-op from a re-install.
    pid: i32,
    /// The framework's observer. Dropping it releases the observer, which the documentation says
    /// also removes its source from the run loop — the explicit removal below is the documented
    /// alternative, done first so the ORDER is the one `AXUIElement.h` spells out.
    observer: CFRetained<AXObserver>,
    /// The observer's run-loop source, kept so the teardown can remove it by identity.
    source: CFRetained<CFRunLoopSource>,
    /// The application element the six notifications were registered against. Held for the
    /// observer's whole life because the registrations name it, and a released element is a
    /// registration pointing at nothing.
    _app: CFRetained<AXUIElement>,
}

impl Installed {
    /// Creates an observer for `pid`, registers the six notifications, and adds its source to the
    /// CURRENT thread's run loop.
    ///
    /// `None` when the framework refuses to create one — accessibility off, a protected process, a
    /// pid that is not a process — which for the caller means the same as any other AX failure: the
    /// 1 Hz differ stays the only source.
    ///
    /// # Safety
    /// Three framework rules, in call order. `AXObserverCreate` is a **Create-rule** entry point
    /// whose result comes back through an out-parameter; the slot is a live local for the whole
    /// call, on any non-success the framework leaves it untouched, and the retain is claimed by
    /// [`crate::own::claimed`], this crate's one such site. `AXObserverAddNotification` requires
    /// the refcon to be a valid pointer OR NULL, and it is NULL by design — see the module
    /// note. `AXObserverGetRunLoopSource` is a Get-rule read the binding already discharges
    /// into a `CFRetained`; it is `unsafe` only because it is a bare `extern` function.
    #[expect(
        unsafe_code,
        reason = "the three AXObserver entry points are generated unsafe; each call names its rule"
    )]
    fn install(pid: i32, listener: &Listener, mode: Option<&CFRunLoopMode>) -> Option<Self> {
        if pid <= 0 {
            return None;
        }
        let mut slot: *mut AXObserver = ptr::null_mut();
        // SAFETY: framework rule, above — a live, correctly typed out-parameter slot, and a
        // callback that dereferences none of its arguments.
        let status = unsafe { AXObserver::create(pid, Some(on_notification), NonNull::from(&mut slot)) };
        if status != AXError::Success {
            return None;
        }
        // SAFETY: `AXObserverCreate` carries `Create` in its name and has just reported success, so
        // the slot holds a +1 reference nobody else has claimed.
        let observer: CFRetained<AXObserver> = unsafe { crate::own::claimed(slot) }?;

        // SAFETY: framework rule, above — any pid is a legal argument, Create rule on the result,
        // which the binding hands back as a `CFRetained`.
        let app = unsafe { AXUIElement::new_application(pid) };
        attribute::stamp(&app, TIMEOUT);

        // Registered BETWEEN the create and the run-loop add, which is the only window where it can
        // matter: no callback can fire before the source is scheduled, and none may fire after it
        // without a row to find.
        live()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key(&observer), Arc::clone(listener));

        for name in NOTIFICATIONS {
            // Best-effort per notification, exactly as the Swift was: an app that rejects one (an
            // Electron quirk) still delivers the rest, and total refusal leaves the differ.
            // SAFETY: framework rule, above — the refcon is NULL, which the binding admits.
            let _ = unsafe { observer.add_notification(&app, &CFString::from_str(name), ptr::null_mut()) };
        }

        // SAFETY: framework rule, above — a bare `extern` read of the observer's own source.
        let source = unsafe { observer.run_loop_source() };
        let Some(run_loop) = CFRunLoop::current() else {
            // No run loop on this thread is not a state the observer thread can be in, but the
            // binding says it is possible; unwind rather than leave a row behind a source nothing
            // will ever pump.
            live()
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&key(&observer));
            return None;
        };
        run_loop.add_source(Some(&source), mode);

        Some(Self {
            pid,
            observer,
            source,
            _app: app,
        })
    }
}

impl Drop for Installed {
    fn drop(&mut self) {
        if let Some(run_loop) = CFRunLoop::current() {
            run_loop.remove_source(Some(&self.source), default_mode());
        }
        // AFTER the removal, deliberately, and for `slopdesk-apple-fsevents`' reason: a callback
        // already dispatched when the source came out may still run, and it then finds no row and
        // does nothing. Removing the row first would only widen that window.
        live()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&key(&self.observer));
    }
}

/// A live subscription to one application's window notifications, re-pointable, torn down on drop.
///
/// One per process is the shape the caller wants: the feed follows the FRONTMOST app, so the
/// observer is retargeted rather than replaced, and the thread outlives every app it watches.
#[derive(Debug)]
pub struct Observer {
    /// What the thread should be doing. Written here, read there.
    lane: Arc<Mutex<Lane>>,
    /// The thread, taken and joined by [`Drop`].
    thread: Option<JoinHandle<()>>,
}

impl Observer {
    /// Starts the observer thread, watching NOTHING until [`Self::retarget`] names a pid.
    ///
    /// `on_event` is called on the observer thread for every notification that arrives, with no
    /// argument: which window changed is the caller's to work out by re-enumerating, and decoding
    /// the element here would be this crate making a decision.
    #[must_use]
    pub fn watching<F>(on_event: F) -> Self
    where
        F: Fn() + Send + Sync + 'static,
    {
        let lane = Arc::new(Mutex::new(Lane {
            wanted: 0,
            stop: false,
        }));
        let listener: Listener = Arc::new(on_event);
        let held = Arc::clone(&lane);
        let thread = std::thread::Builder::new()
            .name("slopdesk.ax.observer".to_owned())
            .spawn(move || serve(&held, &listener))
            .ok();
        Self { lane, thread }
    }

    /// Re-points the observer at `pid`, taking effect within one run-loop slice.
    ///
    /// Callable from any thread. A pid that refuses observation simply leaves the observer
    /// installing nothing, which is the same answer as never having been retargeted.
    pub fn retarget(&self, pid: i32) {
        self.lane.lock().unwrap_or_else(PoisonError::into_inner).wanted = pid;
    }

    /// Which pid the observer has been ASKED to watch. `0` when it has been asked for none.
    #[must_use]
    pub fn target(&self) -> i32 {
        self.lane.lock().unwrap_or_else(PoisonError::into_inner).wanted
    }
}

impl Drop for Observer {
    fn drop(&mut self) {
        self.lane.lock().unwrap_or_else(PoisonError::into_inner).stop = true;
        if let Some(thread) = self.thread.take() {
            // Joined rather than detached: the thread owns the installed observer, and the registry
            // row goes with it. A detached one would let a drop return while a row is still live.
            drop(thread.join());
        }
    }
}

/// The observer thread: install what is wanted, pump for a slice, look again.
fn serve(lane: &Arc<Mutex<Lane>>, listener: &Listener) {
    let mode = default_mode();
    let mut installed: Option<Installed> = None;
    loop {
        let asked = *lane.lock().unwrap_or_else(PoisonError::into_inner);
        if asked.stop {
            break;
        }
        if installed.as_ref().is_none_or(|one| one.pid != asked.wanted) {
            // Dropped BEFORE the new one is built, so the old source leaves this run loop first —
            // an app that is being switched away from must not keep delivering into the new one's
            // slice budget.
            drop(installed.take());
            installed = Installed::install(asked.wanted, listener, mode);
        }
        if installed.is_some() {
            CFRunLoop::run_in_mode(mode, SLICE_SECONDS, false);
        } else {
            // A run loop with no source at all answers `Finished` immediately, so pumping one would
            // spin. Sleeping the same slice keeps the retarget latency identical either way.
            std::thread::sleep(Duration::from_secs_f64(SLICE_SECONDS));
        }
    }
}

/// The framework's callback, defined SAFE and coerced to the `unsafe extern` pointer
/// `AXObserverCreate` wants.
///
/// The first argument is used as an ADDRESS and never followed; the other three are ignored. That
/// is what keeps this function free of the raw-pointer dereference `docs/57` §2 bars, and it is why
/// the refcon is NULL — the Swift's `Unmanaged::fromOpaque` round trip has no Rust spelling this
/// family permits.
///
/// The listener is cloned OUT of the table before it is called, so a callback cannot hold the lock
/// while running caller code — a listener that itself dropped an [`Observer`] would otherwise
/// deadlock against this very map.
extern "C-unwind" fn on_notification(
    observer: NonNull<AXObserver>,
    _element: NonNull<AXUIElement>,
    _notification: NonNull<CFString>,
    _refcon: *mut c_void,
) {
    let listener = live()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&observer.as_ptr().addr())
        .map(Arc::clone);
    if let Some(listener) = listener {
        listener();
    }
}

/// How many observers are registered — the leak test's only window onto the table.
#[cfg(test)]
fn registered() -> usize {
    live().lock().unwrap_or_else(PoisonError::into_inner).len()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::time::Duration;

    use super::{NOTIFICATIONS, Observer, SLICE_SECONDS, registered};

    /// The registration table is PROCESS-wide, so EVERY test that installs an observer takes a
    /// turn — the three that read the table's size, and the one that does not, because its row
    /// is still a row the other three count. Without this they read each other's rows and the
    /// deltas come out as whatever the scheduler chose — which is exactly how this suite failed
    /// the first time it was run, and again under a loaded build farm once the leak test ran
    /// outside the lock.
    static ROSTER: Mutex<()> = Mutex::new(());

    /// Long enough for the thread to have taken at least two slices, so an install has been
    /// attempted and a retarget has been seen.
    fn settle() {
        std::thread::sleep(Duration::from_secs_f64(SLICE_SECONDS * 3.0));
    }

    /// The leak test `docs/57` §3 asks every crate in this family for: what the observer retains,
    /// it lets go of. Green whether or not the Accessibility grant is held — an observer that
    /// never installed still holds the listener on its thread, and the join is what releases
    /// it.
    #[test]
    fn a_dropped_observer_lets_go_of_everything_it_held() {
        let _turn = ROSTER.lock().unwrap_or_else(PoisonError::into_inner);
        let seen = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&seen);
        let observer = Observer::watching(move || {
            held.fetch_add(1, Ordering::SeqCst);
        });
        observer.retarget(std::process::id().cast_signed());
        settle();
        drop(observer);
        assert_eq!(
            Arc::strong_count(&seen),
            1,
            "dropping the observer must release the listener — a retained closure is the leak this test \
             exists for",
        );
    }

    /// The table is not a second lifetime. Ten thousand would be the shape the sibling crates use,
    /// but an observer owns a THREAD, so the count is what an installed-and-dropped observer must
    /// return the table to rather than how many can be made.
    #[test]
    fn a_dropped_observer_leaves_no_row_behind() {
        let _turn = ROSTER.lock().unwrap_or_else(PoisonError::into_inner);
        let before = registered();
        {
            let observer = Observer::watching(|| {});
            observer.retarget(std::process::id().cast_signed());
            settle();
        }
        assert_eq!(
            registered(),
            before,
            "a dead observer must leave no row for a later handle address to collide with"
        );
    }

    /// A pid that is not a process still INSTALLS — `AXObserverCreate` has nothing to check the pid
    /// against, exactly as `AXUIElementCreateApplication` does not — and the row is real. What must
    /// hold is that it never fires, and that the drop takes the row and the listener with it. This
    /// is the arm a headless suite reaches, and the one a target app exiting mid-session takes.
    #[test]
    fn an_observer_pointed_at_no_process_never_fires_and_still_lets_go() {
        let _turn = ROSTER.lock().unwrap_or_else(PoisonError::into_inner);
        let seen = Arc::new(AtomicUsize::new(0));
        let held = Arc::clone(&seen);
        let before = registered();
        let observer = Observer::watching(move || {
            held.fetch_add(1, Ordering::SeqCst);
        });
        observer.retarget(i32::MAX);
        settle();
        assert_eq!(observer.target(), i32::MAX);
        assert_eq!(seen.load(Ordering::SeqCst), 0, "a dead pid must never notify");
        drop(observer);
        assert_eq!(registered(), before, "the row goes when the observer does");
        assert_eq!(Arc::strong_count(&seen), 1);
        assert_eq!(seen.load(Ordering::SeqCst), 0, "and it must never have fired");
    }

    /// A retarget to zero uninstalls rather than leaving the old app observed — the state the
    /// observer starts in, and the one it returns to when the frontmost app is unknowable.
    #[test]
    fn retargeting_to_no_process_at_all_takes_the_row_out_again() {
        let _turn = ROSTER.lock().unwrap_or_else(PoisonError::into_inner);
        let before = registered();
        let observer = Observer::watching(|| {});
        observer.retarget(std::process::id().cast_signed());
        settle();
        observer.retarget(0);
        settle();
        assert_eq!(registered(), before, "an observer watching nobody holds no row");
    }

    /// The six notification names are the ones `AXNotificationConstants.h` documents, spelled
    /// without the `kAX`/`Notification` affixes the C constants carry. A typo here is a feed that
    /// silently never kicks, which no other test in this crate could see.
    #[test]
    fn the_six_notification_names_are_the_ones_the_header_documents() {
        assert_eq!(NOTIFICATIONS, [
            "AXWindowCreated",
            "AXUIElementDestroyed",
            "AXTitleChanged",
            "AXFocusedWindowChanged",
            "AXWindowMiniaturized",
            "AXWindowDeminiaturized",
        ]);
    }
}
