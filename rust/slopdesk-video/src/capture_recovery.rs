//! The recovery ladders for the two ways a capture can be lost out from under a live session, and
//! the ordering rule for the window list a client picks from.
//!
//! Every rule here is a pure rung selection. The capture and display side effects — starting a
//! stream, restoring a window, re-creating a display, sending the goodbye — stay in the actor.

use std::collections::BTreeSet;

/// What to do after a capture-region rebuild failed to start.
///
/// The region rebuild stops the OLD capturer before starting the region-override one. If that start
/// throws and nothing intervenes, the session is left streaming with no capturer at all: a silent
/// forever-freeze with no recovery path. So the failure walks a ladder — try the union, degrade to
/// a plain window capture, and only then disconnect, because a visible disconnect the client's
/// reconnect handles beats a frozen picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureFailureAction {
    /// A teardown or a NEWER owner raced the rebuild — do nothing. Rebuilding from here would
    /// double-tear, or orphan the newer owner's live capture stream.
    Abandon,
    /// Rebuild a PLAIN window capture, dropping the region: the stream degrades to the
    /// un-expanded window rather than freezing.
    RebuildPlainWindow,
    /// The plain-window fallback failed too — say goodbye and stop, so the client shows its
    /// reconnect path instead of a dead frame.
    Disconnect,
}

/// The rung for one capture-rebuild failure.
///
/// `superseded` means the failed references are no longer the installed ones, because a newer
/// resize or region owner installed its own capture across a suspension point.
/// `is_fallback_rebuild` means the failure WAS the plain-window fallback — the last rung.
#[must_use]
pub const fn capture_failure_action(
    media_flowing: bool,
    superseded: bool,
    is_fallback_rebuild: bool,
) -> CaptureFailureAction {
    if !media_flowing || superseded {
        CaptureFailureAction::Abandon
    } else if is_fallback_rebuild {
        CaptureFailureAction::Disconnect
    } else {
        CaptureFailureAction::RebuildPlainWindow
    }
}

/// The sessions to disconnect when the virtual display is terminated under them.
///
/// The window server can kill a virtual display out from under the daemon — sleep and wake, a GPU
/// reset, a fast user switch, a display reconfiguration. Restoring the parked window FRAMES is not
/// enough: every live session whose window was parked on the dead display would keep its capture
/// stream pointed at it, which is a silent client freeze with no goodbye and no reconnect. So a
/// session is affected exactly when its lane PARKED a window there AND it is still a live lane.
/// Unparked sessions on a real display are untouched, and parked channels with no live lane are
/// covered by the window restore alone.
///
/// Sorted, so the teardown order is deterministic.
#[must_use]
pub fn channels_to_disconnect(parked_channels: &BTreeSet<u32>, live_channels: &BTreeSet<u32>) -> Vec<u32> {
    parked_channels.intersection(live_channels).copied().collect()
}

/// The default seconds between virtual-display re-create attempts.
pub const RECREATE_COOLDOWN_SECONDS: f64 = 30.0;

/// Whether a virtual-display re-create attempt may start now.
///
/// After a termination the NEXT park request may re-create the display, but at most one attempt at
/// a time — the create call blocks on window-server IPC for up to about ten seconds — and never
/// more often than the cooldown. A host whose window server keeps killing displays has to degrade
/// to unscaled capture, not stall every session bring-up for ten seconds each.
///
/// An in-flight attempt always blocks. Otherwise the first attempt is free and later ones must be a
/// cooldown past the previous attempt's START, stamped at begin, so a hung create cannot re-arm
/// early.
#[must_use]
pub const fn should_attempt_recreate(
    now: f64,
    last_attempt: Option<f64>,
    cooldown: f64,
    attempt_in_flight: bool,
) -> bool {
    if attempt_in_flight {
        return false;
    }
    match last_attempt {
        None => true,
        Some(last) => now - last >= cooldown,
    }
}

/// The gate that composes [`should_attempt_recreate`] for the daemon's concurrent lanes: begin
/// admits exactly one in-flight re-create and stamps the cooldown anchor; end releases the flight.
///
/// Losers fall back to unscaled capture for their own bring-up and retry on a later hello. Plain
/// bookkeeping — the caller owns whatever lock its lanes need, rather than the gate hiding one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VirtualDisplayRecreateGate {
    /// The minimum spacing between attempt STARTS.
    cooldown: f64,
    /// Whether an attempt is in flight.
    in_flight: bool,
    /// When the last attempt started.
    last_attempt: Option<f64>,
}

impl Default for VirtualDisplayRecreateGate {
    fn default() -> Self {
        Self::new(RECREATE_COOLDOWN_SECONDS)
    }
}

impl VirtualDisplayRecreateGate {
    /// A gate with nothing in flight and no history.
    #[must_use]
    pub const fn new(cooldown: f64) -> Self {
        Self {
            cooldown,
            in_flight: false,
            last_attempt: None,
        }
    }

    /// Admits and stamps a re-create attempt, or refuses because one is in flight or the cooldown
    /// has not elapsed.
    pub const fn begin(&mut self, now: f64) -> bool {
        if !should_attempt_recreate(now, self.last_attempt, self.cooldown, self.in_flight) {
            return false;
        }
        self.in_flight = true;
        self.last_attempt = Some(now);
        true
    }

    /// Releases the in-flight attempt. The cooldown stamped at begin still throttles the next one,
    /// whether this attempt succeeded or failed.
    pub const fn end(&mut self) {
        self.in_flight = false;
    }
}

/// Arranges a window list reply built from the FULL window enumeration.
///
/// The reply is the client's authority for both the picker and its open-time revalidation.
/// Minimized and other-space windows ARE streamable — the bring-up path rescues them — so they must
/// appear here: an on-screen-only reply made a freshly picked minimized window resolve to nothing
/// and close the pane while the host was mid-rescue on the very hello it was about to accept.
///
/// On-screen windows come first, each side keeping its original relative order, so the reply's
/// record cap can only ever crowd out the off-screen tail. UNTITLED off-screen entries are dropped:
/// phantom enumeration junk carries no title, while a real minimized window keeps its. Untitled
/// ON-screen windows stay, because real apps do show them.
#[must_use]
pub fn arrange_streamable_windows<W, S, T>(windows: Vec<W>, is_on_screen: S, title: T) -> Vec<W>
where
    S: Fn(&W) -> bool,
    T: Fn(&W) -> &str,
{
    let (on_screen, off_screen): (Vec<W>, Vec<W>) =
        windows.into_iter().partition(|window| is_on_screen(window));
    let mut arranged = on_screen;
    arranged.extend(off_screen.into_iter().filter(|window| !title(window).is_empty()));
    arranged
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::{
        CaptureFailureAction, RECREATE_COOLDOWN_SECONDS, VirtualDisplayRecreateGate,
        arrange_streamable_windows, capture_failure_action, channels_to_disconnect, should_attempt_recreate,
    };

    #[test]
    fn the_capture_ladder_degrades_before_it_disconnects() {
        assert_eq!(
            capture_failure_action(true, false, false),
            CaptureFailureAction::RebuildPlainWindow,
        );
        assert_eq!(
            capture_failure_action(true, false, true),
            CaptureFailureAction::Disconnect,
            "the fallback itself failed",
        );
    }

    /// Rebuilding after a teardown or under a newer owner is worse than doing nothing.
    #[test]
    fn a_raced_rebuild_is_abandoned() {
        assert_eq!(
            capture_failure_action(false, false, false),
            CaptureFailureAction::Abandon
        );
        assert_eq!(
            capture_failure_action(true, true, false),
            CaptureFailureAction::Abandon
        );
        assert_eq!(
            capture_failure_action(true, true, true),
            CaptureFailureAction::Abandon,
            "abandoning outranks even the last rung",
        );
    }

    #[test]
    fn only_live_lanes_that_parked_on_the_dead_display_are_disconnected() {
        let parked = BTreeSet::from([1_u32, 2, 3]);
        let live = BTreeSet::from([2_u32, 3, 9]);
        assert_eq!(channels_to_disconnect(&parked, &live), vec![2, 3]);
        assert!(channels_to_disconnect(&BTreeSet::new(), &live).is_empty());
    }

    #[test]
    fn the_recreate_throttle_admits_one_at_a_time() {
        assert!(
            should_attempt_recreate(100.0, None, 30.0, false),
            "the first is free"
        );
        assert!(!should_attempt_recreate(100.0, None, 30.0, true), "one at a time");
        assert!(
            !should_attempt_recreate(120.0, Some(100.0), 30.0, false),
            "inside the cooldown"
        );
        assert!(should_attempt_recreate(130.0, Some(100.0), 30.0, false));
    }

    /// A create that hangs must not re-arm the throttle early.
    #[test]
    fn the_gate_stamps_at_begin_rather_than_at_end() {
        let mut gate = VirtualDisplayRecreateGate::default();
        assert!(gate.begin(100.0));
        assert!(!gate.begin(100.1), "the flight blocks it");
        // The create finally fails, ten seconds in.
        gate.end();
        assert!(!gate.begin(110.0), "still inside the cooldown stamped at begin");
        assert!(gate.begin(100.0 + RECREATE_COOLDOWN_SECONDS));
    }

    #[test]
    fn on_screen_windows_come_first_and_untitled_phantoms_are_dropped() {
        let windows = vec![
            ("off-a", false, "Minimized"),
            ("on-a", true, "Editor"),
            ("phantom", false, ""),
            ("on-b", true, ""),
            ("off-b", false, "Other Space"),
        ];
        let arranged = arrange_streamable_windows(windows, |window| window.1, |window| window.2);
        let names: Vec<&str> = arranged.iter().map(|window| window.0).collect();
        assert_eq!(names, ["on-a", "on-b", "off-a", "off-b"]);
    }
}
