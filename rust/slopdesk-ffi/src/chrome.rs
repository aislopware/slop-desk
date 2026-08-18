//! What the window's chrome shows around the panes, in C.
//!
//! The rules are `slopdesk_workspace::chrome`; what is here is the marshalling. Nothing allocates
//! and nothing crosses through a buffer — the widest answer is three flags and a fraction, which
//! fits in a struct returned by value.
//!
//! ## The three-valued answers
//!
//! Two of these have a rung that means "no opinion", and each says so in the way its own answer
//! allows: the sidebar's returns `-1` beside the two booleans `0` and `1`, and the Dock's carries a
//! `present` flag beside its fraction. Both are §4's rule read at the scale of one value: the
//! refusal must be outside the range of every real answer, or a caller will one day read it as one.

use slopdesk_workspace::chrome::{self, AutoHideMode, CloseConfirm, DockTile, Rollup, SidebarState};

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

/// Whether the sidebar should be collapsed: `1` collapse · `0` reveal · `-1` no opinion.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_sidebar_desired_collapsed(mode: u8, tab_count: usize) -> i32 {
    match chrome::desired_collapsed(mode_of(mode), tab_count) {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    }
}

/// The sidebar flags the chrome should hold after applying the auto-hide policy.
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

#[cfg(test)]
mod tests {
    use super::{
        CSidebarState, slopdesk_ws_close_should_confirm, slopdesk_ws_dock_tile,
        slopdesk_ws_sidebar_apply_auto_hide, slopdesk_ws_sidebar_desired_collapsed,
    };

    #[test]
    fn the_no_opinion_answer_is_outside_both_booleans() {
        assert_eq!(slopdesk_ws_sidebar_desired_collapsed(2, 1), 1);
        assert_eq!(slopdesk_ws_sidebar_desired_collapsed(2, 2), 0);
        assert_eq!(slopdesk_ws_sidebar_desired_collapsed(0, 1), -1);
        assert_eq!(slopdesk_ws_sidebar_desired_collapsed(1, 1), -1);
        assert_eq!(
            slopdesk_ws_sidebar_desired_collapsed(200, 1),
            -1,
            "an unknown mode is quiet"
        );
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
}
