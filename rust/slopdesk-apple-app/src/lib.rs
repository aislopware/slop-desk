//! `NSRunningApplication` — a pid in, a bundle identifier out.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and makes no decisions of its own. WHICH pid to ask about is the window
//! list's election (`slopdesk_apple_cgwindow::frontmost_pid` feeding
//! `slopdesk_video::window_list`); what the answer MEANS — is this bundle swipe-nav eligible — is
//! `slopdesk-video`'s, and both of those forbid `unsafe`.
//!
//! ## No `unsafe`, and that is the point
//! `objc2-app-kit` generates both calls this crate makes as SAFE functions, and `NSString`'s
//! `to_string` is safe. There is no `#[expect(unsafe_code)]` in this file. `docs/57` §3 sets a bar
//! per crate rather than a budget, and the bar a crate clears by writing none of it is the one this
//! family was opened for: most of what it calls is safe in the bindings already, so `unsafe` here
//! would mean "the framework's own contract" and there is no framework contract to name.
//!
//! ## `NSWorkspace.frontmostApplication` is deliberately absent
//! It is a per-process SNAPSHOT: it populates on first access and then updates only through
//! `AppKit` run-loop machinery a daemon never pumps, so every later read answers the first-access
//! app forever. Probe-verified — with Chrome frontmost, a daemon launched from Terminal read
//! `com.apple.Terminal` on every call, on and off the main thread, while a side-by-side window-list
//! scan tracked Chrome→Finder→Chrome live. That freeze made the swipe-nav status push report
//! `eligible=false` for the daemon's whole life, and left the fire path's allowlist check correct
//! only by luck of first-access ordering.
//!
//! There is no fallback to it here for the same reason. A pid that resolves to no application
//! answers `None`, which every caller reads as "not eligible", so the failure is CLOSED — chip
//! dark, no chord — rather than frozen on whatever was frontmost when the daemon started.

//! ## `NSWorkspace` IS here, for the two verbs that are not a snapshot
//! The paragraph above bars `frontmostApplication` and stands. What arrived with `docs/60` stage E
//! is the other half of the class: `openURL:` and `activateFileViewerSelectingURLs:` are EFFECTS,
//! not observations, so the freeze that makes the frontmost read useless cannot apply — there is
//! nothing cached to go stale, and a call either reached Launch Services or did not.
//!
//! They are in THIS crate rather than a sixth one because §2's unit is a framework AREA and the
//! area is "the running application": which app owns a pid, whether it is hidden, raising one, and
//! handing a file to whichever app claims it. A `slopdesk-apple-workspace` holding two calls would
//! split that area in half and give the metadata performer two doors to pick between.
//!
//! WHICH path may be opened is not here. The tilde expansion, the absolute-path requirement and the
//! existence check are `slopdesk_hostserver::pathaction`, which forbids `unsafe` and is the half a
//! test can hold; these two functions take a path that has already passed all three.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication, NSWorkspace};
#[cfg(target_os = "macos")]
use objc2_foundation::{NSArray, NSString, NSURL};

/// The bundle identifier of the process with this pid.
///
/// `None` when the pid names no running application (it exited, it was never an app bundle, or it
/// is a plain executable with no `Info.plist`) — all of which are the same answer to a caller:
/// nothing can be said about this process, so say nothing.
#[cfg(target_os = "macos")]
#[must_use]
pub fn bundle_id(pid: i32) -> Option<String> {
    // Both calls are generated SAFE — see the module note. `bundleIdentifier` answers `None` for a
    // process that is not an app bundle, which is the same nothing a missing pid gives, and the
    // caller wants them to be the same nothing.
    let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)?;
    Some(app.bundleIdentifier()?.to_string())
}

/// Whether the app with this pid is HIDDEN — ⌘H, or hidden by another app becoming active.
///
/// A pid that names no application answers `false`, which is the same answer the caller wants: a
/// window belonging to nothing is not a window a person hid, and the window feed treats hidden as a
/// reason to suppress a row rather than as a reason to drop one.
#[cfg(target_os = "macos")]
#[must_use]
pub fn is_hidden(pid: i32) -> bool {
    // Generated SAFE, both calls — see the module note.
    NSRunningApplication::runningApplicationWithProcessIdentifier(pid).is_some_and(|app| app.isHidden())
}

/// Brings the app with this pid to the front. `false` when the pid names no application, or when
/// the framework declined — a request, never a guarantee.
///
/// No options: the caller raises and focuses ONE window through the accessibility API first, and
/// `ActivateAllWindows` would undo that by bringing the app's other windows forward with it. Every
/// caller treats a `false` as best-effort, because the click that follows lands on whatever is
/// frontmost either way.
#[cfg(target_os = "macos")]
// `must_use` on an EFFECT, which reads odd until you name what the bool is: not "an activation
// happened" but "the pid resolved and the framework accepted", and a caller that drops it has
// decided the difference does not matter. Making that a deliberate `_ =` is the point.
#[must_use]
pub fn activate(pid: i32) -> bool {
    // Generated SAFE, both calls — see the module note. The framework's own contract is that this
    // is a request the window server may refuse, which is what the `bool` reports.
    NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
        .is_some_and(|app| app.activateWithOptions(NSApplicationActivationOptions::empty()))
}

/// Hands `path` to whichever application Launch Services says owns it — the host half of a ⌘click.
///
/// `false` when Launch Services declined: no app claims the type, the app is damaged, the file
/// vanished between the caller's check and this call. A REQUEST, never a guarantee, exactly like
/// [`activate`] one function up.
///
/// The path arrives ABSOLUTE and already known to exist — `slopdesk_hostserver::pathaction` owns
/// the tilde expansion, the absolute-path refusal and the existence check, and is where a test can
/// assert on all three. Nothing is re-derived here: `NSURL::fileURLWithPath` is handed the string
/// it was given.
#[cfg(target_os = "macos")]
#[must_use]
pub fn open_path(path: &str) -> bool {
    // Generated SAFE, all three calls. `openURL:` is an EFFECT and not a snapshot, so the freeze
    // the module note bars `frontmostApplication` for cannot apply to it.
    let url = NSURL::fileURLWithPath(&NSString::from_str(path));
    NSWorkspace::sharedWorkspace().openURL(&url)
}

/// Opens the host's Finder with `path` SELECTED — the reveal verb.
///
/// Void, because the framework's own call is: there is no "the Finder declined" to report. The
/// caller's success condition is the existence check it already performed, which is why
/// `slopdesk_hostserver::pathaction` answers `ok` on the strength of that and not of this.
///
/// Takes one path rather than a slice deliberately. `activateFileViewerSelectingURLs:` accepts
/// many, and no verb in this repository reveals more than one — a slice here would be a shape the
/// wire cannot produce and a second code path nothing exercises.
#[cfg(target_os = "macos")]
pub fn reveal_path(path: &str) {
    // Generated SAFE, all four calls — see [`open_path`] on why an effect is not the snapshot the
    // module note bars.
    let url = NSURL::fileURLWithPath(&NSString::from_str(path));
    let selection = NSArray::from_retained_slice(&[url]);
    NSWorkspace::sharedWorkspace().activateFileViewerSelectingURLs(&selection);
}

/// The non-macOS shapes, so a caller compiles everywhere and links the doors only where they exist.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn bundle_id(_pid: i32) -> Option<String> {
    None
}

/// The non-macOS twin of [`open_path`]. There is no Launch Services to decline, so it declines.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn open_path(_path: &str) -> bool {
    false
}

/// The non-macOS twin of [`reveal_path`]. There is no Finder to raise, so nothing is raised.
#[cfg(not(target_os = "macos"))]
pub const fn reveal_path(_path: &str) {}

/// The non-macOS twin of [`is_hidden`].
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn is_hidden(_pid: i32) -> bool {
    false
}

/// The non-macOS twin of [`activate`].
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn activate(_pid: i32) -> bool {
    false
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::{activate, bundle_id, is_hidden};

    /// A pid that cannot name an application answers nothing rather than a default. This is the
    /// whole failure mode the crate has: a caller reads `None` as "not eligible" and fails closed.
    #[test]
    fn an_impossible_pid_answers_nothing() {
        assert_eq!(bundle_id(i32::MAX), None);
        assert_eq!(bundle_id(-1), None);
    }

    /// A real pid that is not an app bundle — this test binary — resolves to no bundle id rather
    /// than to an empty string or a panic. `launchd` is the one pid every macOS host has, and it is
    /// also not an app, so the two together pin both halves of "exists but is not an application".
    #[test]
    fn a_live_process_that_is_not_an_app_bundle_answers_nothing() {
        let mine = std::process::id().cast_signed();
        assert_eq!(bundle_id(mine), None);
        assert_eq!(bundle_id(1), None);
    }

    /// A pid that names no application is not hidden. Conflating "gone" with "hidden" would let the
    /// window feed suppress a row for a process it simply could not resolve.
    #[test]
    fn a_pid_that_names_no_application_is_not_hidden() {
        assert!(!is_hidden(i32::MAX));
        assert!(!is_hidden(-1));
    }

    /// Activating a pid that names no application is refused rather than silently "succeeding".
    /// The caller reads `false` as best-effort, but a `true` would claim a raise that never
    /// happened.
    #[test]
    fn activating_a_pid_that_names_no_application_is_refused() {
        assert!(!activate(i32::MAX));
        assert!(!activate(-1));
    }

    /// A path Launch Services cannot open is refused rather than silently "succeeding".
    ///
    /// The ONE assertion this crate makes about `open_path`, and deliberately so: the success arm
    /// launches an application, which needs a window server and a Launch Services session and would
    /// leave a running app behind on whatever machine ran the suite. That is the same hang-safety
    /// line `HostPathActionPerformer` draws in its own header, and the half a test CAN hold —
    /// tilde expansion, the absolute-path refusal, the existence check — is
    /// `slopdesk_hostserver::pathaction`'s, where it is asserted against a fake opener.
    #[test]
    fn a_path_that_cannot_be_opened_is_refused() {
        assert!(!super::open_path("/nonexistent/slopdesk/never-was"));
    }

    /// Called repeatedly, it must keep answering — this is the property `NSWorkspace` does NOT have
    /// and the reason this crate exists. A snapshot API would answer the same thing forever; this
    /// one re-asks, so ten calls cost ten resolutions and none of them is cached by the framework.
    #[test]
    fn the_read_is_not_a_snapshot_that_freezes_after_the_first_call() {
        let mine = std::process::id().cast_signed();
        for _ in 0..10 {
            assert_eq!(bundle_id(mine), None);
        }
    }
}
