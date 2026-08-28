//! PRIVACY BLANK for a full-desktop session: the host's screen goes black, the host's keyboard and
//! mouse go dead, and the client keeps seeing the desktop.
//!
//! The `RustDesk` technique, driver-free. While engaged it (1) blacks the streamed host display
//! with a zero gamma table — the encoder still captures the real framebuffer, so the CLIENT sees
//! the desktop while a bystander at the physical Mac sees only black — and (2) swallows local HID
//! input, so nobody at the host can interfere while the remote operator works.
//!
//! ## What it owns, and what it asks
//! It owns the ENGAGE LOGIC and nothing else: the idempotence, the order of the two effects, the
//! failure arm, and the teardown that must run even when the remote end died. Whether a session may
//! ask at all is [`slopdesk_video::session_state`]'s — a `PrivacyMode` message becomes an
//! `ApplyPrivacyMode` effect only for a DISPLAY target — and the two system effects themselves are
//! the seam below.
//!
//! ## Why the effects are a seam and not a call
//! Two reasons, and the second is the load-bearing one:
//!
//! * The engage logic is the part with cases — first engage, re-engage, a gamma call that failed, a
//!   tap that could not be installed, a double teardown — and every one of them is a unit test here
//!   only because no real `CoreGraphics` runs underneath.
//! * The REAL blank is two framework calls and no cases at all. `HostPrivacyBlank.swift` made them
//!   inline; this crate forbids `unsafe`, so they live in `slopdesk-apple-cgdisplay`'s gamma door
//!   and [`HostGamma`] is the whole of the implementation — four lines that decide nothing. There
//!   is still no DEFAULT implementation of [`BlanksDisplay`], and there must never be an inert one:
//!   a `set_enabled(true)` that reported `true` while the host's screen stayed lit is a privacy
//!   failure that looks like a success on both ends of the wire.
//!
//! ## Caveats, documented rather than solved (carried over from the Swift verbatim)
//! - The gamma blackout is PER-DISPLAY (the session's target display); the input swallow is GLOBAL
//!   (an HID-level tap sees all input) — so on a multi-display host, blanking display A still
//!   freezes the keyboard and mouse everywhere. Single-display hosts, the common remote-desktop
//!   case, are unaffected. Scoping the swallow to the blanked display would need a coordinate
//!   mapping that is unreliable across a blanked display, which is why it was not done.
//! - The remote operator's INJECTED input is not swallowed. That is [`local_input_should_pass`],
//!   which is the tap's whole policy and is a function over two booleans so it can be tested
//!   without one.
//!
//! ## The tap seam was never wired, and that is not an omission
//! `HostPrivacyBlank.swift`'s `installTap` default was `{ false }` for the file's whole life: no
//! caller ever supplied a real event tap, so the shipped behaviour has always been "the screen goes
//! black, local input keeps working". The seam is ported as the seam it was — a defaulted pair of
//! trait methods — rather than promoted into a requirement no implementation exists for.

use core::fmt;
use std::sync::{Mutex, PoisonError};

/// The two system effects a privacy blank has, and the two more it may have.
///
/// One trait rather than the Swift's four closures, because the four were never independent: they
/// are one implementation of "make this host private", and a caller that supplied a blank without
/// its matching restore had already made the mistake the pairing exists to prevent.
pub trait BlanksDisplay: Send + Sync + fmt::Debug {
    /// Blacks `display_id` with a zero gamma ramp. Answers whether the platform call succeeded.
    ///
    /// A `false` leaves the controller DISENGAGED, so the client's next re-assert retries rather
    /// than the host believing in a blank it never applied.
    fn blank(&self, display_id: u32) -> bool;

    /// Restores `display_id`'s calibrated gamma. Infallible by construction: there is nothing a
    /// caller could do with a failure except try the same call again.
    fn restore(&self, display_id: u32);

    /// Installs the local-input-swallowing tap, answering whether it went in.
    ///
    /// Defaults to "no tap", which is the behaviour that has always shipped. A `false` is NOT a
    /// failure of the blank: the screen is dark either way, and only the input swallow is absent —
    /// the state a host without an Accessibility grant would reach anyway.
    fn install_tap(&self) -> bool {
        false
    }

    /// Removes the local-input tap. Called only when [`Self::install_tap`] answered `true`.
    fn remove_tap(&self) {}
}

/// The real host: Quartz's gamma table, through the one crate allowed to call it.
///
/// Carries no state — the display id travels with each call, and [`PrivacyBlank`] is what remembers
/// which display is dark. There is nothing here to construct wrongly and nothing to leak.
///
/// The tap half is left at the trait's default, because it was never wired in the Swift either.
#[derive(Clone, Copy, Debug, Default)]
pub struct HostGamma;

impl BlanksDisplay for HostGamma {
    fn blank(&self, display_id: u32) -> bool {
        slopdesk_apple_cgdisplay::set_gamma_black(display_id)
    }

    fn restore(&self, display_id: u32) {
        slopdesk_apple_cgdisplay::restore_gamma(display_id);
    }
}

/// Whether a local HID event should PASS while the blank is in the given state.
///
/// The real tap callback's whole policy, extracted so it is a function over two booleans rather
/// than a branch inside a callback no test can reach. While the blank is engaged every hardware
/// event is swallowed; the remote operator's injected events carry a marker the tap recognises, and
/// pass.
#[must_use]
pub const fn local_input_should_pass(engaged: bool, injected_by_remote: bool) -> bool {
    !engaged || injected_by_remote
}

/// What is currently true of the host, as opposed to what the client asked for.
///
/// Two flags rather than one, because they can differ: an engaged blank with no tap is the ordinary
/// state on a host with no Accessibility grant, and a teardown must not call `remove_tap` for a tap
/// that was never installed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct State {
    engaged: bool,
    tap_installed: bool,
}

/// One display's privacy blank, for one session.
///
/// One controller per display session. The lock is here rather than in the caller because two
/// threads reach it: the session applying the client's wish, and the teardown path — and a
/// re-assert racing a disengage is exactly how a host ends up dark with nothing left to restore it.
#[derive(Debug)]
pub struct PrivacyBlank<B: BlanksDisplay> {
    display_id: u32,
    seam: B,
    state: Mutex<State>,
}

impl<B: BlanksDisplay> PrivacyBlank<B> {
    /// A disengaged blank for `display_id`.
    ///
    /// Nothing happens to the display here. Construction is free, so a session can build one at the
    /// moment it learns its target display and let the client's first wish decide whether the host
    /// is ever darkened at all.
    #[must_use]
    pub fn new(display_id: u32, seam: B) -> Self {
        Self {
            display_id,
            seam,
            state: Mutex::new(State::default()),
        }
    }

    /// Applies the client's privacy wish, and answers the state actually REACHED.
    ///
    /// Idempotent: a re-sent `enabled` — which is what a per-session re-assert after a re-hello
    /// is — is a no-op when the state already matches, so the gamma table is not re-zeroed under a
    /// display that is already black.
    ///
    /// The order on engage is gamma FIRST, tap second, and it is not arbitrary. The gamma call is
    /// the one that can fail in a way the client must hear about, and a tap installed in front of a
    /// blank that then failed would have deadened the host's keyboard for a screen that stayed lit.
    ///
    /// The lock is held across both effects, deliberately. They are a pair — a half-applied blank
    /// is the state with no name — and both are single synchronous window-server calls, so nothing
    /// waits behind them for long enough to matter.
    pub fn set_enabled(&self, on: bool) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if on && !state.engaged {
            if !self.seam.blank(self.display_id) {
                // Gamma failed: stay disengaged so the client's next re-send retries. Remembering
                // the failure would turn one refused call into a session that is never private.
                return false;
            }
            state.engaged = true;
            state.tap_installed = self.seam.install_tap();
        } else if !on && state.engaged {
            self.teardown(&mut state);
        }
        state.engaged
    }

    /// Whether the host is dark right now.
    #[must_use]
    pub fn is_engaged(&self) -> bool {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).engaged
    }

    /// Teardown on session end: restores the gamma and removes the tap, unconditionally.
    ///
    /// Called on `Drop` too, and that is the point of it. A crashed remote must never strand the
    /// host with a black screen and a dead keyboard, and nothing at the physical Mac could undo
    /// either — the keyboard that would type the undo is the one that was swallowed.
    pub fn disengage(&self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.teardown(&mut state);
    }

    /// The teardown itself, with the lock already held.
    ///
    /// Tap first, gamma second — the reverse of the engage order, so the host is never left with a
    /// visible screen it still cannot type at. A tap that was never installed is not removed: the
    /// seam has no way to tell a spurious removal from a real one, and the flag is what remembers.
    fn teardown(&self, state: &mut State) {
        if !state.engaged {
            return;
        }
        if state.tap_installed {
            self.seam.remove_tap();
            state.tap_installed = false;
        }
        self.seam.restore(self.display_id);
        state.engaged = false;
    }
}

impl<B: BlanksDisplay> Drop for PrivacyBlank<B> {
    fn drop(&mut self) {
        self.disengage();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

    use super::{BlanksDisplay, PrivacyBlank, local_input_should_pass};

    /// A host that counts what was done to it, and can be told to refuse.
    #[derive(Debug, Default)]
    struct Host {
        blanks: AtomicU32,
        restores: AtomicU32,
        installs: AtomicU32,
        removals: AtomicU32,
        /// The display id the last blank named, so the controller cannot quietly darken another.
        blanked: AtomicU32,
        refuses_gamma: AtomicBool,
        has_tap: AtomicBool,
    }

    impl Host {
        fn counts(&self) -> (u32, u32, u32, u32) {
            (
                self.blanks.load(Ordering::Relaxed),
                self.restores.load(Ordering::Relaxed),
                self.installs.load(Ordering::Relaxed),
                self.removals.load(Ordering::Relaxed),
            )
        }
    }

    impl BlanksDisplay for &Host {
        fn blank(&self, display_id: u32) -> bool {
            self.blanks.fetch_add(1, Ordering::Relaxed);
            self.blanked.store(display_id, Ordering::Relaxed);
            !self.refuses_gamma.load(Ordering::Relaxed)
        }
        fn restore(&self, _display_id: u32) {
            self.restores.fetch_add(1, Ordering::Relaxed);
        }
        fn install_tap(&self) -> bool {
            self.installs.fetch_add(1, Ordering::Relaxed);
            self.has_tap.load(Ordering::Relaxed)
        }
        fn remove_tap(&self) {
            self.removals.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A host whose seam is entirely defaulted — no tap at all, which is what has always shipped.
    #[derive(Debug, Default)]
    struct GammaOnly {
        blanks: AtomicU32,
        restores: AtomicU32,
    }

    impl BlanksDisplay for &GammaOnly {
        fn blank(&self, _display_id: u32) -> bool {
            self.blanks.fetch_add(1, Ordering::Relaxed);
            true
        }
        fn restore(&self, _display_id: u32) {
            self.restores.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The engage path, and the display it names. A controller that blanked a display other than
    /// its session's would darken a bystander's screen and leave the streamed one lit.
    #[test]
    fn engaging_blacks_this_sessions_display_and_installs_the_tap() {
        let host = Host::default();
        host.has_tap.store(true, Ordering::Relaxed);
        let blank = PrivacyBlank::new(7, &host);
        assert!(blank.set_enabled(true));
        assert!(blank.is_engaged());
        assert_eq!(host.counts(), (1, 0, 1, 0));
        assert_eq!(host.blanked.load(Ordering::Relaxed), 7);
    }

    /// A re-sent wish is a no-op. The client re-asserts privacy after every re-hello, and
    /// re-zeroing a gamma table that is already zero is a window-server call per reconnect for no
    /// change.
    #[test]
    fn a_re_sent_wish_touches_nothing() {
        let host = Host::default();
        let blank = PrivacyBlank::new(1, &host);
        assert!(blank.set_enabled(true));
        assert!(blank.set_enabled(true));
        assert!(blank.set_enabled(true));
        assert_eq!(host.counts(), (1, 0, 1, 0));
    }

    /// A gamma call that failed leaves the controller DISENGAGED and installs no tap — so the next
    /// re-send retries, and the host is never left deadened behind a screen that stayed lit.
    #[test]
    fn a_refused_gamma_leaves_nothing_engaged_and_no_tap_installed() {
        let host = Host::default();
        host.refuses_gamma.store(true, Ordering::Relaxed);
        host.has_tap.store(true, Ordering::Relaxed);
        let blank = PrivacyBlank::new(1, &host);
        assert!(!blank.set_enabled(true));
        assert!(!blank.is_engaged());
        assert_eq!(host.counts(), (1, 0, 0, 0), "the tap must not go in");

        host.refuses_gamma.store(false, Ordering::Relaxed);
        assert!(blank.set_enabled(true), "the retry is what the arm exists for");
    }

    /// An absent tap still leaves the screen dark. This is the ordinary state on a host with no
    /// Accessibility grant, and it is the state the shipped default seam always reaches.
    #[test]
    fn a_tap_that_could_not_be_installed_still_leaves_the_screen_dark() {
        let host = Host::default();
        let blank = PrivacyBlank::new(1, &host);
        assert!(blank.set_enabled(true));
        assert!(blank.is_engaged());
        blank.set_enabled(false);
        assert_eq!(
            host.counts(),
            (1, 1, 1, 0),
            "a tap never installed is not removed"
        );
    }

    /// Disengaging restores the gamma and removes the tap, and doing it twice does neither twice.
    #[test]
    fn disengaging_restores_once_however_often_it_is_asked() {
        let host = Host::default();
        host.has_tap.store(true, Ordering::Relaxed);
        let blank = PrivacyBlank::new(1, &host);
        assert!(blank.set_enabled(true));
        blank.disengage();
        blank.disengage();
        blank.set_enabled(false);
        assert!(!blank.is_engaged());
        assert_eq!(host.counts(), (1, 1, 1, 1));
    }

    /// Dropping an ENGAGED controller restores the host. This is the path a crashed remote takes,
    /// and the one case where nobody at the physical Mac could undo the state by hand.
    #[test]
    fn dropping_an_engaged_controller_gives_the_host_back() {
        let host = Host::default();
        host.has_tap.store(true, Ordering::Relaxed);
        {
            let blank = PrivacyBlank::new(1, &host);
            assert!(blank.set_enabled(true));
        }
        assert_eq!(host.counts(), (1, 1, 1, 1));
    }

    /// A disengaged controller that is dropped touches nothing — the common case, since most
    /// sessions never ask for privacy at all.
    #[test]
    fn dropping_a_controller_that_never_engaged_touches_nothing() {
        let host = GammaOnly::default();
        drop(PrivacyBlank::new(1, &host));
        assert_eq!(host.blanks.load(Ordering::Relaxed), 0);
        assert_eq!(host.restores.load(Ordering::Relaxed), 0);
    }

    /// The defaulted seam: no tap is installed, none is removed, and the blank still works. This is
    /// the shape `HostPrivacyBlank.swift` actually shipped with for its whole life.
    #[test]
    fn the_defaulted_seam_blanks_without_ever_touching_a_tap() {
        let host = GammaOnly::default();
        let blank = PrivacyBlank::new(3, &host);
        assert!(blank.set_enabled(true));
        blank.set_enabled(false);
        assert_eq!(host.blanks.load(Ordering::Relaxed), 1);
        assert_eq!(host.restores.load(Ordering::Relaxed), 1);
    }

    /// The tap's whole policy: local input passes unless the blank is engaged, and the remote
    /// operator's own injected events always pass — otherwise engaging privacy would lock out the
    /// person the session exists for.
    #[test]
    fn only_an_engaged_blank_swallows_input_and_never_the_remotes_own() {
        assert!(local_input_should_pass(false, false));
        assert!(local_input_should_pass(false, true));
        assert!(!local_input_should_pass(true, false));
        assert!(local_input_should_pass(true, true));
    }
}
