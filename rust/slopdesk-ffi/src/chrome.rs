//! What the window's chrome shows around the panes, in C.
//!
//! The rules are `slopdesk_settings::chrome`; what is here is the marshalling. Nothing allocates
//! and nothing crosses through a buffer — the widest answer is three flags and a fraction, which
//! fits in a struct returned by value.
//!
//! ## The three-valued answers
//!
//! Several values here have a rung that means "absent", and C has no optional to spell it with, so
//! each carries a `present` flag beside the value it qualifies: `last_auto_present` on the sidebar
//! state, `fraction_present` on the Dock tile. That is §4's rule read at the scale of one value —
//! the refusal must be outside the range of every real answer, or a caller will one day read it as
//! one, and `false` is a perfectly good answer to "was the panel last driven collapsed?".
//!
//! A door whose whole answer is three-valued can say it in the return instead, the way
//! `desired_collapsed` once returned `-1` beside `0` and `1`. That door is gone (see
//! [`slopdesk_ws_sidebar_apply_auto_hide`]); the `present`-flag spelling is what survives, because
//! it composes — a struct can carry several absences, a sentinel return can carry one.

use slopdesk_settings::chrome::{
    self, AutoHideMode, CloseConfirm, DockTile, DwellGate, DwellPhase, Rollup, SidebarState,
};

/// The chrome's sidebar flags, as the shell holds them between two applications of the policy.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CSidebarState {
    /// Whether the tabs panel is collapsed right now.
    pub collapsed: bool,
    /// Whether the user's own ⌘⇧L or swipe is the reason it is where it is.
    pub manual_override: bool,
    /// The last value the policy itself drove — read only when `last_auto_present` is set.
    pub last_auto: bool,
    /// Whether the policy has ever driven a value. False is the first application.
    pub last_auto_present: bool,
}

impl From<CSidebarState> for SidebarState {
    fn from(state: CSidebarState) -> Self {
        Self {
            collapsed: state.collapsed,
            manual_override: state.manual_override,
            last_auto: state.last_auto_present.then_some(state.last_auto),
        }
    }
}

impl From<SidebarState> for CSidebarState {
    fn from(state: SidebarState) -> Self {
        Self {
            collapsed: state.collapsed,
            manual_override: state.manual_override,
            last_auto: state.last_auto.unwrap_or(false),
            last_auto_present: state.last_auto.is_some(),
        }
    }
}

/// What the macOS Dock tile shows.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CDockTile {
    /// Whether the icon carries the red error tint.
    pub tinted: bool,
    /// Whether the tile runs its progress animation.
    pub animates: bool,
    /// The determinate fraction `0..=1` — read only when `fraction_present` is set.
    pub fraction: f64,
    /// Whether there is a determinate fraction at all; false is the indeterminate spinner.
    pub fraction_present: bool,
}

impl From<DockTile> for CDockTile {
    fn from(tile: DockTile) -> Self {
        Self {
            tinted: tile.tinted,
            animates: tile.animates,
            fraction: tile.fraction.unwrap_or(0.0),
            fraction_present: tile.fraction.is_some(),
        }
    }
}

/// `0` never auto-hide · `1` always shown · `2` auto. Anything else reads as never, the mode with
/// no opinion — a disagreement between the two sides should cost the auto-hide, not fight the user.
const fn mode_of(raw: u8) -> AutoHideMode {
    match raw {
        1 => AutoHideMode::Always,
        2 => AutoHideMode::Auto,
        _ => AutoHideMode::Never,
    }
}

/// `0` while a process runs · `1` always · `2` more than one tab. Anything else reads as the
/// process gate, the default a stale stored string already repairs to.
const fn close_of(raw: u8) -> CloseConfirm {
    match raw {
        1 => CloseConfirm::Always,
        2 => CloseConfirm::MultipleTabs,
        _ => CloseConfirm::Process,
    }
}

/// `1` in progress · `2` error · `3` indeterminate — the wire's own `OSC 9;4` discriminants.
/// Anything else, `0` (clear) included, is the ABSENCE of a rollup.
const fn rollup_of(raw: u8, percent: u8) -> Option<Rollup> {
    match raw {
        1 => Some(Rollup::Determinate(percent)),
        2 => Some(Rollup::Error),
        3 => Some(Rollup::Indeterminate),
        _ => None,
    }
}

/// The sidebar flags the chrome should hold after applying the auto-hide policy.
///
/// The bare `desired_collapsed` rung is NOT exported beside this one. It was, and the near side
/// wrapped it in a `SidebarAutoHidePolicy` that the `SwiftUI` wiring called; the imperative shells
/// actuate through this composed door instead, so the wrapper's last caller left with the view and
/// the exported rung existed only to serve it. `chrome::desired_collapsed` is still the rule —
/// `apply_auto_hide` calls it one line down, and `slopdesk-settings` tests it directly.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_sidebar_apply_auto_hide(
    mode: u8,
    tab_count: usize,
    state: CSidebarState,
) -> CSidebarState {
    chrome::apply_auto_hide(mode_of(mode), tab_count, state.into()).into()
}

/// Whether a close must park behind a confirmation prompt.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_close_should_confirm(
    policy: u8,
    is_busy: bool,
    tab_count: usize,
) -> bool {
    chrome::should_confirm(close_of(policy), is_busy, tab_count)
}

/// The complete Dock-tile decision.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_dock_tile(
    rollup: u8,
    percent: u8,
    any_failure: bool,
    animate_enabled: bool,
    error_badge_enabled: bool,
) -> CDockTile {
    chrome::dock_tile(
        rollup_of(rollup, percent),
        any_failure,
        animate_enabled,
        error_badge_enabled,
    )
    .into()
}

/// The local menu bar is hidden — the resting state; top-edge input is the remote's.
pub const SLOPDESK_WS_DWELL_HIDDEN: u8 = 0;
/// The pointer is pressed against the top edge and the dwell clock is running.
pub const SLOPDESK_WS_DWELL_ARMING: u8 = 1;
/// The dwell is satisfied: the local menu bar may auto-reveal.
pub const SLOPDESK_WS_DWELL_REVEALED: u8 = 2;

/// The borderless-fullscreen dwell, whole: its phase and the three points it was built with.
///
/// The gate crosses BY VALUE in both directions rather than living behind a handle. It is five
/// numbers with no interior, the caller already owns the window it belongs to, and a fold that
/// returns the next gate cannot leave a stale one behind for a later pointer move to read.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CDwellGate {
    /// One of the `SLOPDESK_WS_DWELL_*` codes.
    pub phase: u8,
    /// When the running dwell started — meaningful only while arming, and `0` otherwise.
    pub since: f64,
    /// The hold this gate demands, in seconds.
    pub dwell_seconds: f64,
    /// Its arming zone, in points from the top edge.
    pub reveal_zone_points: f64,
    /// Its conceal zone, on the same scale.
    pub conceal_zone_points: f64,
}

impl From<CDwellGate> for DwellGate {
    fn from(gate: CDwellGate) -> Self {
        Self {
            phase: match gate.phase {
                SLOPDESK_WS_DWELL_ARMING => DwellPhase::Arming { since: gate.since },
                SLOPDESK_WS_DWELL_REVEALED => DwellPhase::Revealed,
                // An unknown code rests HIDDEN, which is the phase that gives the top edge to the
                // remote — the side a disagreement between the two languages must fall on.
                _ => DwellPhase::Hidden,
            },
            dwell_seconds: gate.dwell_seconds,
            reveal_zone_points: gate.reveal_zone_points,
            conceal_zone_points: gate.conceal_zone_points,
        }
    }
}

impl From<DwellGate> for CDwellGate {
    fn from(gate: DwellGate) -> Self {
        let (phase, since) = match gate.phase {
            DwellPhase::Hidden => (SLOPDESK_WS_DWELL_HIDDEN, 0.0),
            DwellPhase::Arming { since } => (SLOPDESK_WS_DWELL_ARMING, since),
            DwellPhase::Revealed => (SLOPDESK_WS_DWELL_REVEALED, 0.0),
        };
        Self {
            phase,
            since,
            dwell_seconds: gate.dwell_seconds,
            reveal_zone_points: gate.reveal_zone_points,
            conceal_zone_points: gate.conceal_zone_points,
        }
    }
}

/// A resting gate built with the dwell, the arming zone and the conceal zone the decision named —
/// so neither language spells the three numbers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_dwell_gate() -> CDwellGate {
    DwellGate::default().into()
}

/// One pointer observation folded into `gate`, answering the gate it leaves behind.
///
/// `pointer_y_from_top` is DISTANCE FROM THE SCREEN'S TOP EDGE in points, so the one coordinate
/// flip stays with the window layer. Feed this on every pointer move, and once more at
/// [`slopdesk_ws_dwell_deadline`] — a motionless pointer emits no further moves.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_dwell_update(
    gate: CDwellGate,
    pointer_y_from_top: f64,
    now: f64,
) -> CDwellGate {
    let mut folded = DwellGate::from(gate);
    folded.update(pointer_y_from_top, now);
    folded.into()
}

/// When a running dwell completes, written to `out`. `false` means nothing is arming, and then
/// `out` is untouched — a caller with no timer to schedule.
///
/// # Safety
/// `out` must be null or point to one writable `double`, live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_dwell_deadline(gate: CDwellGate, out: *mut f64) -> bool {
    let Some(deadline) = DwellGate::from(gate).arming_deadline() else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: the caller's obligation, restated above.
        unsafe { out.write(deadline) };
    }
    true
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        CSidebarState, SLOPDESK_WS_DWELL_ARMING, SLOPDESK_WS_DWELL_HIDDEN, SLOPDESK_WS_DWELL_REVEALED,
        slopdesk_ws_close_should_confirm, slopdesk_ws_dock_tile, slopdesk_ws_dwell_deadline,
        slopdesk_ws_dwell_gate, slopdesk_ws_dwell_update, slopdesk_ws_sidebar_apply_auto_hide,
    };

    /// A mode byte no case spells stays QUIET rather than picking a rung. This survived the
    /// deletion of the bare `desired_collapsed` door, which is where it used to be asserted:
    /// `mode_of` is the arm that repairs it, and the composed door is now the only way to reach
    /// it from outside.
    #[test]
    fn an_unknown_mode_byte_actuates_nothing() {
        let held = CSidebarState {
            collapsed: true,
            manual_override: true,
            last_auto: false,
            last_auto_present: true,
        };
        let after = slopdesk_ws_sidebar_apply_auto_hide(200, 5, held);
        assert!(after.collapsed, "an unknown mode repairs to one with no opinion");
        assert!(after.manual_override, "…so every flag is handed straight back");
        assert!(after.last_auto_present);
        assert!(!after.last_auto);
    }

    #[test]
    fn the_absent_last_value_makes_the_first_application_an_edge() {
        let manual = CSidebarState {
            collapsed: true,
            manual_override: true,
            last_auto: true,
            last_auto_present: false,
        };
        let first = slopdesk_ws_sidebar_apply_auto_hide(2, 1, manual);
        assert!(first.last_auto_present, "the policy has now driven one");
        assert!(first.last_auto);
        assert!(!first.manual_override, "an edge clears the override");
    }

    #[test]
    fn the_case_indexes_are_the_ones_the_header_names() {
        assert!(
            !slopdesk_ws_close_should_confirm(0, false, 9),
            "the process gate, not busy"
        );
        assert!(slopdesk_ws_close_should_confirm(1, false, 1), "always");
        assert!(slopdesk_ws_close_should_confirm(2, false, 2), "more than one tab");
        assert!(
            !slopdesk_ws_close_should_confirm(200, false, 9),
            "unknown repairs to the process gate"
        );
    }

    #[test]
    fn the_dock_reads_the_wires_own_progress_discriminants() {
        let determinate = slopdesk_ws_dock_tile(1, 40, false, true, true);
        assert!(determinate.animates);
        assert!(determinate.fraction_present);
        assert!((determinate.fraction - 0.4).abs() < f64::EPSILON);

        let held = slopdesk_ws_dock_tile(2, 80, false, true, true);
        assert!(held.tinted);
        assert!(!held.animates);
        assert!(!held.fraction_present);

        let cleared = slopdesk_ws_dock_tile(0, 0, false, true, true);
        assert!(!cleared.tinted);
        assert!(!cleared.animates);
    }

    fn deadline(gate: super::CDwellGate) -> Option<f64> {
        let mut answer = 0.0;
        // SAFETY: one live local double, borrowed for the duration of the call.
        let arming = unsafe { slopdesk_ws_dwell_deadline(gate, &raw mut answer) };
        arming.then_some(answer)
    }

    #[test]
    fn the_gate_survives_the_round_trip_it_makes_on_every_pointer_move() {
        // The phase and the clock BOTH have to come back, or a dwell restarts on each move and can
        // never finish. This is the crossing the gesture is made of.
        let armed = slopdesk_ws_dwell_update(slopdesk_ws_dwell_gate(), 0.0, 100.0);
        assert_eq!(armed.phase, SLOPDESK_WS_DWELL_ARMING);
        assert_eq!(deadline(armed), Some(100.5));

        let still_arming = slopdesk_ws_dwell_update(armed, 1.0, 100.4);
        assert_eq!(still_arming.phase, SLOPDESK_WS_DWELL_ARMING);
        assert_eq!(deadline(still_arming), Some(100.5), "the clock did not restart");

        let revealed = slopdesk_ws_dwell_update(still_arming, 1.0, 100.5);
        assert_eq!(revealed.phase, SLOPDESK_WS_DWELL_REVEALED);
        assert_eq!(deadline(revealed), None, "nothing to schedule once revealed");
    }

    #[test]
    fn an_unknown_phase_code_rests_hidden_and_gives_the_edge_to_the_remote() {
        let confused = super::CDwellGate {
            phase: 99,
            ..slopdesk_ws_dwell_gate()
        };
        // Hidden only ARMS on contact — it can never reveal in one fold, which is the safe side.
        assert_eq!(
            slopdesk_ws_dwell_update(confused, 0.0, 100.0).phase,
            SLOPDESK_WS_DWELL_ARMING
        );
        assert_eq!(
            slopdesk_ws_dwell_update(confused, 500.0, 100.0).phase,
            SLOPDESK_WS_DWELL_HIDDEN
        );
    }
}
