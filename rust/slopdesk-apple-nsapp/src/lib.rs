//! `NSApplication` — this process's own application object, and the loop it runs.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything. Three calls live here and
//! not one decision: connect this process to the window server, run the main event loop, or drain
//! the main dispatch queue. WHICH of the two loops a daemon runs is `slopdesk-videohostd`'s argv,
//! and it stays there.
//!
//! ## Why a daemon with no user interface talks to `AppKit` at all
//! Live capture needs a window-server connection, and a bare command-line binary never establishes
//! one: `SCStream::startCapture` aborts with `Assertion failed: (did_initialize),
//! CGS_REQUIRE_INIT`. What makes that failure hard to read is that the `SCShareableContent`
//! ENUMERATION `--list` uses works WITHOUT the connection, so the daemon can list every shareable
//! window on the host and still die the moment it tries to capture one — which looks like a
//! Screen-Recording grant problem and is not.
//!
//! Initialising the shared `NSApplication` establishes the connection. `.accessory` is what keeps a
//! process that establishes it out of the Dock and off the menu bar, which is the whole reason a
//! headless daemon can afford to do this at all. It must happen BEFORE any capture starts, which is
//! why [`become_accessory`] is a call `main` makes rather than something a capture path does for
//! itself on demand.
//!
//! ## Two loops, and why they are deliberately not one
//! [`drain_main_queue`] is `dispatch_main()`, and it is the PROVEN path: frame delivery is on
//! `SCStream`'s own dispatch queue and the shutdown source fires on `.main`, so nothing in the
//! ordinary daemon wants more than a drained main queue.
//!
//! [`run`] is `NSApplication.run()`, which runs the main run loop AND drains the main dispatch
//! queue. It exists because a registered `CGVirtualDisplay` needs a live `CFRunLoop` to STAY
//! registered with the window server, and `dispatch_main()` does not provide one — a daemon that
//! only drains the queue loses the display it just created.
//!
//! The Swift this replaces switched to `NSApplication.run()` only when the virtual display was
//! enabled, and stated the reason in the same breath: the default path keeps the proven
//! `dispatchMain()` untouched. That choice is PRESERVED here rather than unified, because unifying
//! it is a claim about the default path — that the superset costs it nothing — and nobody has
//! measured one. **Neither of these two functions is the other's dead twin.** Deleting
//! [`drain_main_queue`] on the grounds that [`run`] does strictly more is exactly the change that
//! needs a measurement in front of it.
//!
//! What is NOT a choice is that the main thread must actually drain the main queue, whichever
//! function does it. `slopdesk-apple-cgvirtualdisplay` dispatches its `WindowServer` round-trips
//! there — `mainhop::on_main` for the create, `release_on_main` for the unregister — so a main
//! thread that parked instead would deadlock the first display teardown.
//!
//! ## No `unsafe`, and neither CoreFoundation admission
//! `objc2-app-kit` generates `sharedApplication`, `setActivationPolicy:` and `run` as SAFE
//! functions, each reached through a `MainThreadMarker` that states `AppKit`'s own thread rule in
//! the type system, and `dispatch2::dispatch_main` is safe too. There is no
//! `#[expect(unsafe_code)]` in this file. Neither §2 admission is spent either, because no
//! CoreFoundation object crosses this crate's boundary — nothing crosses it but a `bool`. Like
//! `slopdesk-apple-app`, this crate clears `docs/57` §3's bar by writing none of the thing the bar
//! is about.
//!
//! ## The main thread is ASKED, never asserted
//! `MainThreadMarker::new()` answers an `Option`, and all three entry points branch on it rather
//! than trapping — `slopdesk-apple-cursor` makes the same choice about the same boundary. A daemon
//! that aborted because a caller reached `AppKit` from the wrong thread would turn a wiring mistake
//! into a crash in front of a person who is trying to work.
//!
//! For [`become_accessory`] the refusal is a `false`, which is the same answer the framework itself
//! gives when it declines the policy, and the same nothing every caller in this family reads as
//! "this did not happen". The two loops cannot return at all, so their refusal is [`park_forever`]
//! — see its own note on why a hang is the right shape there and a trap is not.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
use objc2::MainThreadMarker;
#[cfg(target_os = "macos")]
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy};

/// Connects this process to the window server without giving it a Dock tile or a menu bar.
///
/// `true` when the shared `NSApplication` was initialised — which IS the connection — and the
/// accessory policy took. `false` when the caller is not on the main thread, or when `AppKit`
/// declined the policy change, and those two are deliberately the same answer: in both the process
/// is not the thing the caller asked for, and nothing downstream can tell the difference or act on
/// it differently.
///
/// Call it from `main`, BEFORE any capture starts. The module note has the failure it prevents and
/// why that failure reads as a permissions problem instead of a missing connection.
#[cfg(target_os = "macos")]
// `must_use` on an EFFECT, for `slopdesk-apple-app::activate`'s reason: the bool is not "a window
// server is now reachable" but "this ran on the main thread and `AppKit` accepted", and a caller that
// has decided the difference does not matter should have to write the `_ =` that says so.
#[must_use]
pub fn become_accessory() -> bool {
    // Generated SAFE, both calls — see the module note. `MainThreadMarker::new()` is the branch
    // rather than an assertion: `sharedApplication` on a secondary thread is the undefined
    // behaviour `AppKit` documents, and refusing is strictly better than performing it.
    let Some(mtm) = MainThreadMarker::new() else {
        return false;
    };
    NSApplication::sharedApplication(mtm).setActivationPolicy(NSApplicationActivationPolicy::Accessory)
}

/// Runs the main run loop AND drains the main dispatch queue. Never returns.
///
/// The superset of [`drain_main_queue`], and the arm the daemon takes when the virtual display is
/// enabled: the `CFRunLoop` this pumps is what keeps a `CGVirtualDisplay` registered, and the main
/// queue it also drains is what lets the shutdown source on `.main` still fire. Read the module
/// note before deleting either of the two — the split is preserved on purpose.
///
/// Diverging is this crate's promise, not `AppKit`'s: `NSApplication.run()` returns when something
/// sends the application `stop:`. Nothing in this daemon sends one, and `terminate:` — the other
/// way out — calls `exit()` rather than returning. So the loop is the honest tail. Re-entering is
/// what an `AppKit` application does after a `stop:` anyway, and it is the only answer here that
/// leaves the process with an event source: a `return` cannot exist, and an abort would end a
/// running host over an event nobody in this repository sends.
///
/// Off the main thread there is no run loop to run and no marker with which to reach one, so this
/// parks. See [`park_forever`].
#[cfg(target_os = "macos")]
pub fn run() -> ! {
    let Some(mtm) = MainThreadMarker::new() else {
        park_forever()
    };
    // Generated SAFE, both calls — see the module note.
    let app = NSApplication::sharedApplication(mtm);
    loop {
        app.run();
    }
}

/// Drains the main dispatch queue. Never returns.
///
/// The DEFAULT path, and the proven one. `SCStream` delivers frames on its own dispatch queue and
/// the shutdown source fires on `.main`, so a drained main queue is the whole requirement — and it
/// is a requirement, not a park: `slopdesk-apple-cgvirtualdisplay` dispatches its window-server
/// round-trips onto that queue, and a main thread that slept would deadlock the first teardown.
///
/// `dispatch_main()` is documented as never returning, so the divergence here is the framework's
/// own and not something this crate arranges.
///
/// Off the main thread this parks instead of calling through. `dispatch_main()` is documented as a
/// call `main` makes, `dispatch2` exposes it safe with an open question about that very rule
/// attached, and this crate does not build on an answer it has not checked — see [`park_forever`].
#[cfg(target_os = "macos")]
pub fn drain_main_queue() -> ! {
    if MainThreadMarker::new().is_none() {
        park_forever()
    }
    dispatch2::dispatch_main()
}

/// Schedules `work` on the main dispatch queue and returns IMMEDIATELY.
///
/// The other half of the two loops above. They are what DRAINS the main queue; this is what puts
/// something on it, and the pair lives in one crate because the second is worthless without the
/// first — a caller that hops onto a queue nothing drains has handed its work to a thread that will
/// never look. `slopdesk-apple-cgvirtualdisplay` keeps its own `pub(crate)` twin of this because
/// its hop ferries a framework object with a thread rule of its own; this one takes a plain closure
/// and is the general door.
///
/// ASYNCHRONOUS, and that is the contract rather than an implementation detail. The one caller is
/// `slopdesk-videohostd`'s 120 Hz cursor sampler, whose whole shape exists to keep a main-thread
/// stall off the pointer stream — a synchronous hop would reintroduce exactly the stall the split
/// prevents. Work that never runs because the process ended costs whatever that work was; nothing
/// here waits to find out.
///
/// Callable from ANY thread, the main one included, where it still defers to the next drain rather
/// than running inline.
#[cfg(target_os = "macos")]
pub fn on_main(work: impl FnOnce() + Send + 'static) {
    // `dispatch2` generates this safe: the closure is `Send + 'static`, which is the whole rule
    // libdispatch states about work handed to another queue.
    dispatch2::DispatchQueue::main().exec_async(work);
}

/// The refusing arm of the two loops: block this thread for ever, doing nothing.
///
/// A diverging function has no `false` to answer with, so "refuse without trapping" has exactly one
/// shape. Parking is chosen over an abort deliberately: reaching either loop off the main thread is
/// a WIRING mistake in the caller, the caller's real main thread is still running whatever it was
/// running, and taking the host down for it would turn a mis-ordered `main` into a dead session. It
/// is chosen over calling through for the reason each loop's own note gives — `AppKit` and
/// libdispatch both state the main-thread rule, and neither is a rule this crate is willing to
/// break quietly.
///
/// It parks rather than sleeps because there is nothing to wake for: no timer, no deadline, no
/// second chance at the main thread. A spurious wake re-parks.
#[cfg(target_os = "macos")]
fn park_forever() -> ! {
    loop {
        std::thread::park();
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::become_accessory;

    /// Off the main thread the connection is REFUSED rather than trapped. A `cargo test` thread is
    /// not `AppKit`'s main thread, so this is also the only arm a headless suite can reach — and it
    /// is the arm that matters, because `sharedApplication` on a secondary thread is undefined
    /// behaviour and a daemon that got its launch order wrong must survive saying so.
    ///
    /// The success arm has no test anywhere and cannot: it initialises the shared `NSApplication`,
    /// which connects the process to a window server the suite may not have, and leaves a
    /// registered accessory application behind in the runner for the rest of the process's life.
    /// The two Swift files this crate replaces drew the same line in their own headers.
    ///
    /// The thread is spawned explicitly rather than trusting libtest's harness, for
    /// `slopdesk-apple-cursor`'s reason: which thread a test body runs on is the harness's business
    /// and changes with `--test-threads`, and this assertion is about a thread, not about a test.
    #[test]
    fn becoming_an_accessory_off_the_main_thread_is_refused() {
        let answered = std::thread::spawn(become_accessory).join();
        assert_eq!(answered.ok(), Some(false));
    }

    /// Asked repeatedly it keeps answering the same nothing — no application is created, no
    /// connection is half-opened, no autorelease pool grows. The leak test `docs/57` §3 asks each
    /// crate in this family for, in the shape this crate's one observable has: the central object
    /// is never constructed on this path, so what the loop proves is that the refusal itself
    /// accumulates nothing across a thousand calls.
    #[test]
    fn repeated_refusals_accumulate_nothing() {
        for _ in 0..1_000 {
            assert_eq!(std::thread::spawn(become_accessory).join().ok(), Some(false));
        }
    }
}
