//! What the window's CHROME shows around the panes — the tabs panel, the close prompt, the Dock
//! tile, and who owns the top edge in borderless fullscreen.
//!
//! Decisions that share a shape: each reads a setting the user picked plus a fact about the live
//! workspace, and each has a rung that means "say nothing". Saying nothing matters more here than
//! the positive answers do — a chrome rule that speaks when it should not is one that fights the
//! user (a revealed panel they just swiped away, a prompt on every close, a Dock tile stuck red, a
//! local menu bar that steals a click meant for the remote one).

/// When the vertical TABS panel is shown — the `auto-hide-tabs-panel` config.
///
/// `Default` and `Always` are distinct cases for a possible future horizontal bar; in the
/// vertical-tabs-only shell both mean "never auto-hide", so neither has an opinion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AutoHideMode {
    /// Always shown.
    #[default]
    Never,
    /// Also always shown — kept apart from [`Never`](Self::Never) for the config vocabulary.
    Always,
    /// Hidden while the active session has one tab or none; revealed above that.
    Auto,
}

/// Whether the sidebar should be collapsed for `mode` at `tab_count`, or `None` for NO OPINION.
///
/// A `None` is what leaves a manual ⌘⇧L collapse alone: only [`Auto`](AutoHideMode::Auto) actuates.
/// An empty session collapses like a one-tab one — there is nothing to switch between either way.
#[must_use]
pub const fn desired_collapsed(mode: AutoHideMode, tab_count: usize) -> Option<bool> {
    match mode {
        AutoHideMode::Auto => Some(tab_count <= 1),
        AutoHideMode::Never | AutoHideMode::Always => None,
    }
}

/// The chrome's sidebar flags — what the shell holds between two applications of the policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SidebarState {
    /// Whether the tabs panel is collapsed right now.
    pub collapsed: bool,
    /// Whether the user's own ⌘⇧L (or iPad swipe) is the reason it is where it is.
    pub manual_override: bool,
    /// The last value the auto-hide policy itself drove, or `None` before it has ever driven one.
    pub last_auto: Option<bool>,
}

/// Applies the auto-hide policy to the live chrome, answering the flags it should hold afterwards.
///
/// The `Auto` decision flips only across the 1↔>1 tab-count regime, so actuation is gated on that
/// EDGE rather than on every tab open and close. On an edge — including the very first application
/// — the mode's own opinion wins and any manual override is cleared. WITHIN a regime (2→3 tabs,
/// say) a manual override is honoured and never fought, which is the whole reason the last driven
/// value is remembered at all: without it an iPad user who swiped the panel away at three tabs
/// would have it forcibly revealed by the next unrelated tab they opened.
#[must_use]
pub const fn apply_auto_hide(mode: AutoHideMode, tab_count: usize, state: SidebarState) -> SidebarState {
    let Some(desired) = desired_collapsed(mode, tab_count) else {
        return state;
    };
    let regime_edge = match state.last_auto {
        Some(last) => last != desired,
        None => true,
    };
    let mut next = SidebarState {
        last_auto: Some(desired),
        ..state
    };
    if regime_edge {
        next.manual_override = false;
    } else if state.manual_override {
        return next;
    }
    next.collapsed = desired;
    next
}

/// When a tab / pane / window close must be gated behind a confirmation prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CloseConfirm {
    /// Only while a child process is still running in the closing unit.
    #[default]
    Process,
    /// Every time.
    Always,
    /// Only when the unit holds more than one tab — closing it would lose the others.
    MultipleTabs,
}

/// Whether a close must park behind a confirmation prompt.
#[must_use]
pub const fn should_confirm(policy: CloseConfirm, is_busy: bool, tab_count: usize) -> bool {
    match policy {
        CloseConfirm::Process => is_busy,
        CloseConfirm::Always => true,
        CloseConfirm::MultipleTabs => tab_count > 1,
    }
}

/// The cross-session `OSC 9;4` rollup the Dock tile reads.
///
/// The discriminants are the WIRE's own (`1` in progress, `2` error, `3` indeterminate); `0` —
/// clear — is the ABSENCE of a rollup, so it arrives as `None` rather than as a case here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rollup {
    /// `OSC 9;4;1;<pct>` — a determinate value.
    Determinate(u8),
    /// `OSC 9;4;2[;<pct>]` — held red at the value it failed on.
    Error,
    /// `OSC 9;4;3` — a busy spinner with no meaningful percent.
    Indeterminate,
}

/// What the macOS Dock tile shows.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DockTile {
    /// Whether the icon carries the red error tint.
    pub tinted: bool,
    /// Whether the tile runs its progress animation.
    pub animates: bool,
    /// The determinate fraction `0..=1`, or `None` for the indeterminate spinner.
    pub fraction: Option<f64>,
}

/// The complete Dock-tile decision from the progress rollup, whether any session exited non-zero,
/// and the two macOS toggles.
///
/// A held error and a clear both animate NOTHING: the animation says "still working", and neither
/// is. The fraction is clamped rather than trusted: the percent is validated at the OSC parser, and
/// this is the second place that says so, in the units the tile draws in. `clamp` is exact here
/// because a `u8` over a hundred cannot be `NaN`, which is the only input it would answer badly.
#[must_use]
pub fn dock_tile(
    rollup: Option<Rollup>,
    any_failure: bool,
    animate_enabled: bool,
    error_badge_enabled: bool,
) -> DockTile {
    let is_error = matches!(rollup, Some(Rollup::Error)) || any_failure;
    let mut tile = DockTile {
        tinted: error_badge_enabled && is_error,
        ..DockTile::default()
    };
    if !animate_enabled {
        return tile;
    }
    match rollup {
        Some(Rollup::Indeterminate) => tile.animates = true,
        Some(Rollup::Determinate(percent)) => {
            tile.animates = true;
            tile.fraction = Some((f64::from(percent) / 100.0).clamp(0.0, 1.0));
        },
        Some(Rollup::Error) | None => {},
    }
    tile
}

/// How long the pointer must hold the top edge before the local menu bar reveals.
pub const DWELL_SECONDS: f64 = 0.5;
/// The arming zone: distance from the top edge, in points, that counts as "pressed against it".
/// Tight on purpose — remote work near the top of the screen must not arm the gate.
pub const REVEAL_ZONE_POINTS: f64 = 2.0;
/// The conceal threshold: how far DOWN a revealed gate's pointer must travel to re-hide.
///
/// Wider than the arming zone — hysteresis — so using the revealed menu bar, whose items sit
/// ~12–24 pt down, does not flicker the gate shut.
pub const CONCEAL_ZONE_POINTS: f64 = 36.0;

/// Who owns the top edge of a borderless-fullscreen window.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum DwellPhase {
    /// The local menu bar is hidden — the resting state; top-edge input is the remote's.
    #[default]
    Hidden,
    /// The pointer is pressed against the top edge and the dwell clock is running.
    Arming {
        /// When the pointer first reached the edge.
        since: f64,
    },
    /// The dwell is satisfied: the local menu bar may auto-reveal.
    Revealed,
}

/// The dwell that decides it — the Parallels model, recorded in `docs/DECISIONS.md` 2026-07-22.
///
/// The conflict it settles: in a fullscreen remote desktop the pointer at the very top must reach
/// the REMOTE menu bar first, but macOS's own auto-hide reveals the LOCAL one on a bare touch and
/// steals the click. So a passing touch stays remote, and holding the edge for half a second is the
/// deliberate "I want my Mac's menu bar" gesture.
///
/// Positions are DISTANCE FROM THE TOP EDGE in points — `0` is pressed against it — which is
/// orientation-free, so the one coordinate flip stays with the window layer that owns the screen.
/// The clock arrives as an argument for the same reason: nothing here reads a clock, so the whole
/// gesture is testable without one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DwellGate {
    /// Where the gesture is right now.
    pub phase: DwellPhase,
    /// The hold this gate demands.
    pub dwell_seconds: f64,
    /// Its arming zone.
    pub reveal_zone_points: f64,
    /// Its conceal zone.
    pub conceal_zone_points: f64,
}

impl Default for DwellGate {
    fn default() -> Self {
        Self {
            phase: DwellPhase::Hidden,
            dwell_seconds: DWELL_SECONDS,
            reveal_zone_points: REVEAL_ZONE_POINTS,
            conceal_zone_points: CONCEAL_ZONE_POINTS,
        }
    }
}

impl DwellGate {
    /// Folds one pointer observation and answers the phase it leaves the gate in.
    ///
    /// The caller feeds this on every pointer move AND once at
    /// [`arming_deadline`](Self::arming_deadline): a motionless pointer produces no more move
    /// events, so the dwell can only complete on a timer re-feeding the last position.
    ///
    /// A gate with no dwell at all reveals on contact rather than arming forever — a zero hold is a
    /// caller asking for the plain macOS behaviour, not for a gesture that can never finish.
    pub fn update(&mut self, pointer_y_from_top: f64, now: f64) -> DwellPhase {
        match self.phase {
            DwellPhase::Hidden => {
                if pointer_y_from_top <= self.reveal_zone_points {
                    self.phase = if self.dwell_seconds <= 0.0 {
                        DwellPhase::Revealed
                    } else {
                        DwellPhase::Arming { since: now }
                    };
                }
            },
            DwellPhase::Arming { since } => {
                if pointer_y_from_top > self.reveal_zone_points {
                    // Left the edge before the dwell was up — a passing touch stays remote.
                    self.phase = DwellPhase::Hidden;
                } else if now - since >= self.dwell_seconds {
                    self.phase = DwellPhase::Revealed;
                }
            },
            DwellPhase::Revealed => {
                if pointer_y_from_top >= self.conceal_zone_points {
                    // Back in the stream: re-hide, and make the next reveal dwell again.
                    self.phase = DwellPhase::Hidden;
                }
            },
        }
        self.phase
    }

    /// When a running dwell completes, in the caller's own clock, or `None` when nothing is arming
    /// — the caller schedules its one-shot timer here.
    #[must_use]
    pub const fn arming_deadline(&self) -> Option<f64> {
        match self.phase {
            DwellPhase::Arming { since } => Some(since + self.dwell_seconds),
            DwellPhase::Hidden | DwellPhase::Revealed => None,
        }
    }

    /// Whether the local menu bar may show.
    #[must_use]
    pub const fn is_revealed(&self) -> bool {
        matches!(self.phase, DwellPhase::Revealed)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AutoHideMode, CloseConfirm, DockTile, DwellGate, DwellPhase, Rollup, SidebarState, apply_auto_hide,
        desired_collapsed, dock_tile, should_confirm,
    };

    #[test]
    fn only_the_auto_mode_has_an_opinion() {
        assert_eq!(desired_collapsed(AutoHideMode::Auto, 1), Some(true));
        assert_eq!(desired_collapsed(AutoHideMode::Auto, 0), Some(true));
        assert_eq!(desired_collapsed(AutoHideMode::Auto, 2), Some(false));
        assert_eq!(desired_collapsed(AutoHideMode::Never, 1), None);
        assert_eq!(desired_collapsed(AutoHideMode::Always, 1), None);
    }

    #[test]
    fn a_mode_without_an_opinion_leaves_every_flag_alone() {
        let manual = SidebarState {
            collapsed: true,
            manual_override: true,
            last_auto: None,
        };
        assert_eq!(apply_auto_hide(AutoHideMode::Never, 5, manual), manual);
        assert_eq!(apply_auto_hide(AutoHideMode::Always, 5, manual), manual);
    }

    #[test]
    fn a_manual_collapse_survives_an_unrelated_tab_within_the_regime() {
        // Two tabs: the policy reveals, and remembers that it did.
        let opened = apply_auto_hide(AutoHideMode::Auto, 2, SidebarState::default());
        assert_eq!(opened, SidebarState {
            collapsed: false,
            manual_override: false,
            last_auto: Some(false)
        });
        // The user swipes it away.
        let swiped = SidebarState {
            collapsed: true,
            manual_override: true,
            ..opened
        };
        // A third tab does not flip the regime, so the swipe stands.
        let unrelated = apply_auto_hide(AutoHideMode::Auto, 3, swiped);
        assert_eq!(unrelated, swiped, "an unrelated open must not fight the user");
    }

    #[test]
    fn the_regime_edge_clears_the_override_and_re_asserts() {
        let swiped = SidebarState {
            collapsed: true,
            manual_override: true,
            last_auto: Some(false),
        };
        // Back down to one tab: the 1↔>1 edge, so the mode's own opinion wins again.
        let closed = apply_auto_hide(AutoHideMode::Auto, 1, swiped);
        assert_eq!(closed, SidebarState {
            collapsed: true,
            manual_override: false,
            last_auto: Some(true)
        });
    }

    #[test]
    fn the_first_application_is_an_edge_even_where_it_changes_nothing() {
        let manual = SidebarState {
            collapsed: true,
            manual_override: true,
            last_auto: None,
        };
        let first = apply_auto_hide(AutoHideMode::Auto, 1, manual);
        assert!(
            !first.manual_override,
            "nothing was driven yet, so there is nothing to defer to"
        );
        assert!(first.collapsed);
    }

    #[test]
    fn each_close_policy_reads_its_own_fact() {
        assert!(should_confirm(CloseConfirm::Process, true, 1));
        assert!(!should_confirm(CloseConfirm::Process, false, 9));
        assert!(should_confirm(CloseConfirm::Always, false, 1));
        assert!(should_confirm(CloseConfirm::MultipleTabs, false, 2));
        assert!(!should_confirm(CloseConfirm::MultipleTabs, true, 1));
    }

    #[test]
    fn a_held_error_tints_but_never_animates() {
        let tile = dock_tile(Some(Rollup::Error), false, true, true);
        assert_eq!(tile, DockTile {
            tinted: true,
            animates: false,
            fraction: None
        });
    }

    #[test]
    fn a_non_zero_exit_tints_without_any_progress_at_all() {
        assert!(dock_tile(None, true, true, true).tinted);
        assert!(
            !dock_tile(None, true, true, false).tinted,
            "the badge toggle is off"
        );
    }

    #[test]
    fn the_determinate_fraction_is_the_percent_over_a_hundred_clamped() {
        assert_eq!(
            dock_tile(Some(Rollup::Determinate(40)), false, true, true).fraction,
            Some(0.4)
        );
        assert_eq!(
            dock_tile(Some(Rollup::Determinate(200)), false, true, true).fraction,
            Some(1.0)
        );
        assert_eq!(
            dock_tile(Some(Rollup::Determinate(40)), false, false, true).fraction,
            None,
            "no animation, no fraction to draw it with"
        );
    }

    #[test]
    fn an_indeterminate_rollup_spins_without_a_fraction() {
        let tile = dock_tile(Some(Rollup::Indeterminate), false, true, true);
        assert_eq!(tile, DockTile {
            tinted: false,
            animates: true,
            fraction: None
        });
    }

    #[test]
    fn a_bare_touch_at_the_top_edge_arms_but_does_not_reveal() {
        // The whole point: that first touch belongs to the REMOTE menu bar.
        let mut gate = DwellGate::default();
        assert_eq!(gate.update(0.0, 100.0), DwellPhase::Arming { since: 100.0 });
        assert!(!gate.is_revealed());
        assert_eq!(
            gate.arming_deadline(),
            Some(100.5),
            "the AppKit layer schedules its dwell timer here"
        );
    }

    #[test]
    fn a_held_pointer_reveals_once_the_dwell_is_up() {
        let mut gate = DwellGate::default();
        gate.update(0.0, 100.0);
        assert_eq!(
            gate.update(1.0, 100.4),
            DwellPhase::Arming { since: 100.0 },
            "still inside the dwell"
        );
        assert_eq!(gate.update(1.0, 100.5), DwellPhase::Revealed);
        assert_eq!(gate.arming_deadline(), None, "no timer once revealed");
    }

    #[test]
    fn a_passing_touch_never_reveals_even_if_the_timer_fires_late() {
        let mut gate = DwellGate::default();
        gate.update(0.0, 100.0);
        assert_eq!(
            gate.update(10.0, 100.2),
            DwellPhase::Hidden,
            "left the edge inside the dwell"
        );
        // A stale deadline cannot reveal: the phase is already hidden, and hidden only arms.
        assert_eq!(gate.update(10.0, 100.6), DwellPhase::Hidden);
    }

    #[test]
    fn working_the_revealed_menu_bar_does_not_flicker_it_shut() {
        let mut gate = DwellGate::default();
        gate.update(0.0, 100.0);
        gate.update(0.0, 100.6);
        assert!(gate.is_revealed());
        assert_eq!(
            gate.update(20.0, 101.0),
            DwellPhase::Revealed,
            "menu-bar depth stays revealed"
        );
        assert_eq!(
            gate.update(36.0, 101.2),
            DwellPhase::Hidden,
            "past the threshold re-hides"
        );
        // And the next reveal dwells again — a conceal is a full re-arm, never a sticky reveal.
        assert_eq!(gate.update(0.0, 102.0), DwellPhase::Arming { since: 102.0 });
    }

    #[test]
    fn a_pointer_anywhere_else_is_inert() {
        // The overwhelmingly common fold: every move that is not near the edge changes nothing.
        let mut gate = DwellGate::default();
        for y in [50.0, 500.0, 1400.0] {
            assert_eq!(gate.update(y, 100.0), DwellPhase::Hidden);
        }
    }

    #[test]
    fn a_zero_dwell_reveals_on_contact_rather_than_arming_forever() {
        let mut gate = DwellGate {
            dwell_seconds: 0.0,
            ..DwellGate::default()
        };
        assert_eq!(gate.update(0.0, 100.0), DwellPhase::Revealed);
    }
}
