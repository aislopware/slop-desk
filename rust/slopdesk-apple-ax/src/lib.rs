//! `AXUIElement` — one application's windows, as values, and the four effects on one of them.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and an instruction into an effect, and makes no decisions. Which window
//! to act on, what size to shrink it to, whether an achieved size is close enough, when to re-probe
//! — all of that is `slopdesk_video`'s, which forbids `unsafe`.
//!
//! ## What the whole surface is for
//! Every caller already knows the window it means by `CGWindowID`, because that is the id the
//! capture path, the wire and the client all use. The accessibility tree does not speak that id, so
//! the shape of every operation here is the same: open the app, list its windows, ask each one for
//! its `CGWindowID`, act on the match. [`Window::id`] is the hinge, and it is a private symbol —
//! see the crate's `Cargo.toml` for why it lives one crate over.
//!
//! ## Trust is a READ, and the prompt is an effect
//! [`is_trusted`] answers whether this process may use the rest of this crate at all. It is cheap
//! and is deliberately NOT cached: the grant can be given or revoked while the process runs, and a
//! daemon that cached a `false` at launch would stay dead after the person granted it.
//!
//! ## `AXObserver` IS here, and the note that said otherwise was a state, not a bar
//! This crate used to say an observer with a `CFRunLoop` behind it is a subscription rather than an
//! effect, and therefore not this family's. `slopdesk-apple-fsevents` settled it the other way: a
//! run-loop-backed subscription over an Apple framework belongs here, in the shape §2 permits — a
//! process-wide registry keyed by the handle's ADDRESS, a NULL context, and a callback that follows
//! no pointer. [`observer`] is that shape for `ApplicationServices`, and it is still an observation
//! turned into a value: the callback carries no argument, because which window changed is the
//! caller's to work out.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod attribute;
#[cfg(target_os = "macos")]
mod nav;
#[cfg(target_os = "macos")]
pub mod observer;
#[cfg(target_os = "macos")]
mod own;
#[cfg(target_os = "macos")]
mod window;

#[cfg(target_os = "macos")]
pub use nav::{Element, Step, walk};
#[cfg(target_os = "macos")]
pub use observer::Observer;
#[cfg(target_os = "macos")]
pub use window::{App, Frame, Window};

/// Whether this process holds the Accessibility grant.
///
/// Never cached. The grant is a live TCC state that the person can give or take away in System
/// Settings while the process runs, and every macOS release so far has applied the change without
/// requiring a relaunch. A cached answer is a daemon that stays broken after being fixed.
///
/// # Safety
/// `AXIsProcessTrusted` takes nothing, reads process state and answers a `Boolean`. The binding is
/// `unsafe` only because it is a bare `extern` function; there is no argument to get wrong.
#[cfg(target_os = "macos")]
#[must_use]
#[expect(unsafe_code, reason = "objc2 generates the bare AX entry points unsafe")]
pub fn is_trusted() -> bool {
    // SAFETY: framework rule, above — no arguments, no ownership, no thread requirement.
    unsafe { objc2_application_services::AXIsProcessTrusted() }
}

/// Ask for the Accessibility grant, showing the system's prompt, and answer whether it is already
/// held.
///
/// macOS shows the prompt at most ONCE per app per install — after that the call is a silent read,
/// which is why the caller's own UI has to carry the "open System Settings" path rather than
/// relying on this.
///
/// # Safety
/// `AXIsProcessTrustedWithOptions` takes an optional dictionary whose one documented key is
/// `kAXTrustedCheckOptionPrompt` mapped to a `CFBoolean`, and that is exactly what is built here.
/// The dictionary is borrowed for the call and released after it; nothing crosses under the Create
/// rule in either direction.
///
/// The key is written as a string literal rather than read from the `extern` constant on purpose:
/// the constant is a second symbol to link for a value Apple documents as the literal
/// `AXTrustedCheckOptionPrompt`, and reading an `extern` static is itself an `unsafe` block whose
/// obligation is strictly larger than this one.
#[cfg(target_os = "macos")]
#[must_use]
pub fn prompt_for_trust() -> bool {
    use objc2_core_foundation::{CFBoolean, CFDictionary, CFRetained, CFString, CFType};

    let key = CFString::from_str("AXTrustedCheckOptionPrompt");
    let value = CFBoolean::new(true);
    let options: CFRetained<CFDictionary<CFString, CFType>> =
        CFDictionary::from_slices(&[&*key], &[&**value]);
    // SAFETY: framework rule, above — the one documented key, mapped to the documented type.
    #[expect(unsafe_code, reason = "objc2 generates the bare AX entry points unsafe")]
    unsafe {
        objc2_application_services::AXIsProcessTrustedWithOptions(Some(options.as_opaque()))
    }
}

/// Off macOS there is no accessibility tree, so nothing is trusted.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn is_trusted() -> bool {
    false
}

/// Off macOS there is nothing to prompt for.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn prompt_for_trust() -> bool {
    false
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use std::time::{Duration, Instant};

    use super::{App, Step, is_trusted, walk};

    /// A pid that cannot be running still yields an element — the framework has nothing to check it
    /// against — and every read through it answers empty rather than trapping. This is the arm a
    /// headless suite reaches, and it is the arm that matters: a target app exiting mid-session is
    /// the normal way a window disappears.
    #[test]
    fn an_app_that_is_not_there_publishes_no_windows() {
        let app = App::new(i32::MAX, 0.05);
        assert!(app.windows().is_empty());
    }

    /// A pid of zero is not a process, and neither is a negative one. Both must be values rather
    /// than faults, because the display-scoped injector passes pid 0 by design.
    #[test]
    fn a_pid_that_is_not_a_process_publishes_no_windows() {
        assert!(App::new(0, 0.05).windows().is_empty());
        assert!(App::new(-1, 0.05).windows().is_empty());
    }

    /// The trust read is cheap, repeatable and never traps, whether or not the grant is held — the
    /// property that lets it be called on every status refresh instead of cached.
    #[test]
    fn the_trust_read_is_stable_and_free_of_side_effects() {
        let first = is_trusted();
        for _ in 0..1_000 {
            assert_eq!(is_trusted(), first);
        }
    }

    /// This crate's own process HAS an accessibility element, so this exercises the whole create →
    /// timeout → read → drop cycle against a live target rather than a missing one. It is the leak
    /// test `docs/57` §3 asks each crate for: ten thousand elements, every `CFRetained` released by
    /// scope, and the answer identical at the end.
    #[test]
    fn ten_thousand_elements_are_created_and_released_without_drift() {
        let pid = std::process::id().cast_signed();
        let first = App::new(pid, 0.05).windows().len();
        for _ in 0..10_000 {
            assert_eq!(App::new(pid, 0.05).windows().len(), first);
        }
    }

    /// Every window a live app publishes answers its own frame and minimized state, or answers
    /// nothing — never a partial one. Vacuous without the Accessibility grant, which is why the
    /// three tests above carry the weight; this one is the arm that runs on a granted machine.
    #[test]
    fn a_live_window_answers_a_whole_frame_or_none_at_all() {
        for window in App::new(std::process::id().cast_signed(), 0.25).windows() {
            if let Some(frame) = window.frame() {
                assert!(frame.width.is_finite() && frame.height.is_finite());
            }
            assert!(window.minimized().is_none_or(|_| true));
        }
    }

    /// A zero node budget visits nothing, and it is checked BEFORE the root rather than after — a
    /// walk that always paid for its first node would spend a round trip on a target it had already
    /// decided not to search.
    #[test]
    fn a_walk_with_no_allowance_makes_no_round_trip_at_all() {
        let app = App::new(std::process::id().cast_signed(), 0.05);
        let Some(bar) = app.menu_bar() else { return };
        let mut seen = 0_u32;
        let visited = walk(
            &bar,
            8,
            0,
            Instant::now() + Duration::from_secs(1),
            &mut |_, _| {
                seen += 1;
                Step::Descend
            },
        );
        assert_eq!((visited, seen), (0, 0));
    }

    /// A deadline already in the past stops the walk on the same terms, and for a different reason:
    /// the node bounds cap the call COUNT, and a target answering slowly-but-successfully stays
    /// under them forever.
    #[test]
    fn a_walk_past_its_deadline_stops_before_it_starts() {
        let app = App::new(std::process::id().cast_signed(), 0.05);
        let Some(bar) = app.menu_bar() else { return };
        // Taken and then waited past, rather than subtracted from now: `Instant` subtraction can
        // underflow near boot and the checked form's only recovery is a panic.
        let past = Instant::now();
        std::thread::sleep(Duration::from_millis(2));
        let mut seen = 0_u32;
        assert_eq!(
            walk(&bar, 8, 1_000, past, &mut |_, _| {
                seen += 1;
                Step::Descend
            }),
            0
        );
        assert_eq!(seen, 0);
    }

    /// `Step::Stop` from the root ends the walk having visited exactly the root — the property the
    /// pair search relies on to stop the moment it has both controls, rather than finishing a
    /// subtree it no longer needs.
    #[test]
    fn a_walk_told_to_stop_at_the_root_visits_only_the_root() {
        let app = App::new(std::process::id().cast_signed(), 0.05);
        let Some(bar) = app.menu_bar() else { return };
        let mut depths = Vec::new();
        let visited = walk(
            &bar,
            8,
            1_000,
            Instant::now() + Duration::from_secs(1),
            &mut |_, depth| {
                depths.push(depth);
                Step::Stop
            },
        );
        assert_eq!((visited, depths.as_slice()), (1, [0].as_slice()));
    }

    /// The same window fetched twice compares equal, because `CFEqual` on an element compares
    /// (pid, accessibility object) and not pointer identity. The per-window currency check is
    /// nothing but this comparison, so a framework that compared by pointer would make every check
    /// fail and every beat rescan. Vacuous without the grant; live on a granted machine.
    #[test]
    fn the_same_window_fetched_twice_is_the_same_window() {
        let app = App::new(std::process::id().cast_signed(), 0.25);
        let (Some(first), Some(second)) = (app.focused_or_first_window(), app.focused_or_first_window())
        else {
            return;
        };
        assert_eq!(first, second);
    }
}
