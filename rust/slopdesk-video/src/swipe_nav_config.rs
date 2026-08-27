//! The host process's swipe-navigation operating point.
//!
//! ONE parse of the environment family, shared by the path that fires the chord and by the status
//! push that tells the client what the host will actually do.
//!
//! Two parses could drift, and then the client's feedback would LIE — a committed chip and its
//! haptic for a fire the host silently swallows.

use std::collections::BTreeSet;

use crate::swipe_nav::SwipeNavStatusMessage;
use crate::swipe_recognizer::{extra_apps, fire_travel_from_env, is_navigable};

/// One read of a target app's history availability: can the back or forward chord navigate right
/// now?
///
/// A plain value, so the mapping stays testable everywhere; only the reader that PRODUCES it is
/// platform-bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NavHistoryFlags {
    /// Back would navigate.
    pub can_go_back: bool,
    /// Forward would navigate.
    pub can_go_forward: bool,
}

/// The parsed operating point.
#[derive(Debug, Clone, PartialEq)]
pub struct SwipeNavHostConfig {
    /// The master switch, default ON.
    pub enabled: bool,
    /// Extra bundle ids added to the allowlist.
    pub extra_apps: BTreeSet<String>,
    /// The lift-fire travel threshold in points, which scales the recogniser's whole threshold
    /// family.
    pub fire_travel: f64,
    /// Whether the slow tier is accepted, default ON. Off restores the flick-only duration gate.
    pub slow_tier: bool,
    /// Whether history state gates the push, default ON. Off skips the history read entirely, every
    /// push reports the state as unknown, and the client fails open.
    pub history_gate: bool,
}

impl Default for SwipeNavHostConfig {
    fn default() -> Self {
        Self::from_env(None, None, None, None, None)
    }
}

/// The environment keys, in the order [`SwipeNavHostConfig::from_env`] takes its arguments.
///
/// The rules were already here; only the NAMES were still spelled at the call site, which is one
/// spelling too many — a key resolved as `SLOPDESK_SWIPE_NAV_SLOW` and read into the `history` slot
/// is a silent inversion no test would catch. The tracing switch is deliberately absent: it belongs
/// to the injector's table ([`crate::injector_gates::KEYS`]) because it is OR-ed with that family's
/// own input trace, not to this operating point.
pub const KEYS: [&str; 5] = [
    "SLOPDESK_SWIPE_NAV",
    "SLOPDESK_SWIPE_NAV_APPS",
    "SLOPDESK_SWIPE_NAV_TRAVEL",
    "SLOPDESK_SWIPE_NAV_SLOW",
    "SLOPDESK_SWIPE_NAV_HISTORY",
];

/// A switch that is ON unless the environment explicitly says zero.
fn bool_default_on(raw: Option<&str>) -> bool {
    raw != Some("0")
}

impl SwipeNavHostConfig {
    /// Parses the operating point from the raw environment values.
    #[must_use]
    pub fn from_env(
        enabled: Option<&str>,
        apps: Option<&str>,
        travel: Option<&str>,
        slow: Option<&str>,
        history: Option<&str>,
    ) -> Self {
        Self {
            enabled: bool_default_on(enabled),
            extra_apps: extra_apps(apps),
            fire_travel: fire_travel_from_env(travel),
            slow_tier: bool_default_on(slow),
            history_gate: bool_default_on(history),
        }
    }

    /// Whether a qualifying swipe aimed at this app would be translated right now — the single
    /// eligibility rule both the fire path and the status push apply.
    #[must_use]
    pub fn eligible(&self, bundle_id: Option<&str>) -> bool {
        self.enabled && is_navigable(bundle_id, &self.extra_apps)
    }

    /// WINDOW-scoped eligibility: the pane's app must be navigable AND actually frontmost.
    ///
    /// The fire path gates the chord on live focus, because the injected chord lands wherever the
    /// system's key focus is — so the client's chip must go dark on the SAME condition, or the
    /// affordance lies. Bundle-id equality is the same-app proxy the push has, since the push fans
    /// out a bundle id rather than a process.
    #[must_use]
    pub fn eligible_window_target(
        &self,
        pane_bundle_id: Option<&str>,
        frontmost_bundle_id: Option<&str>,
    ) -> bool {
        let (Some(pane), Some(frontmost)) = (pane_bundle_id, frontmost_bundle_id) else {
            return false;
        };
        self.eligible(Some(pane)) && frontmost == pane
    }

    /// The status message describing this operating point for one target app.
    ///
    /// `history` is the target's availability read, or `None` when unknown — where the client fails
    /// open rather than showing a dark chip.
    #[must_use]
    pub fn status(&self, bundle_id: Option<&str>, history: Option<NavHistoryFlags>) -> SwipeNavStatusMessage {
        self.message(self.eligible(bundle_id), history)
    }

    /// The status message for one WINDOW-scoped session.
    ///
    /// The history flags come from the FRONTMOST app's read; eligibility requires the pane to BE
    /// frontmost, so whenever they matter they describe the pane's own app.
    #[must_use]
    pub fn window_status(
        &self,
        pane_bundle_id: Option<&str>,
        frontmost_bundle_id: Option<&str>,
        history: Option<NavHistoryFlags>,
    ) -> SwipeNavStatusMessage {
        self.message(
            self.eligible_window_target(pane_bundle_id, frontmost_bundle_id),
            history,
        )
    }

    /// An INELIGIBLE push zeroes the history bits.
    ///
    /// The client ignores them behind a dark chip anyway, and a canonical all-zero tail keeps
    /// "ineligible" byte-identical regardless of what the history read happened to say.
    fn message(&self, eligible: bool, history: Option<NavHistoryFlags>) -> SwipeNavStatusMessage {
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "the travel threshold is parsed clamped to 20..=500, so it always fits"
        )]
        let fire_travel = self.fire_travel as u16;
        SwipeNavStatusMessage {
            eligible,
            slow_tier: self.slow_tier,
            fire_travel,
            can_go_back: eligible && history.is_some_and(|flags| flags.can_go_back),
            can_go_forward: eligible && history.is_some_and(|flags| flags.can_go_forward),
            history_known: eligible && history.is_some(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{KEYS, NavHistoryFlags, SwipeNavHostConfig};

    #[test]
    fn the_key_order_matches_the_argument_order() {
        assert_eq!(KEYS[0], "SLOPDESK_SWIPE_NAV", "the master switch is first");
        assert_eq!(KEYS[1], "SLOPDESK_SWIPE_NAV_APPS");
        assert_eq!(KEYS[2], "SLOPDESK_SWIPE_NAV_TRAVEL");
        assert_eq!(KEYS[3], "SLOPDESK_SWIPE_NAV_SLOW");
        assert_eq!(KEYS[4], "SLOPDESK_SWIPE_NAV_HISTORY");
        let unique: std::collections::BTreeSet<&str> = KEYS.iter().copied().collect();
        assert_eq!(unique.len(), KEYS.len(), "a key is spelled twice");
        assert!(
            !KEYS.contains(&"SLOPDESK_SWIPE_NAV_TRACE"),
            "the trace switch belongs to the injector's table — it is OR-ed with the input trace"
        );
    }

    const BOTH: NavHistoryFlags = NavHistoryFlags {
        can_go_back: true,
        can_go_forward: true,
    };

    #[test]
    fn every_switch_is_on_unless_the_environment_says_zero() {
        let config = SwipeNavHostConfig::default();
        assert!(config.enabled && config.slow_tier && config.history_gate);
        let off = SwipeNavHostConfig::from_env(Some("0"), None, None, Some("0"), Some("0"));
        assert!(!off.enabled && !off.slow_tier && !off.history_gate);
        let noise = SwipeNavHostConfig::from_env(Some("yes"), None, None, None, None);
        assert!(noise.enabled, "only an explicit zero turns it off");
    }

    #[test]
    fn the_allowlist_takes_the_extra_bundle_ids() {
        let config = SwipeNavHostConfig::from_env(None, Some("com.example.reader"), None, None, None);
        assert!(config.eligible(Some("com.apple.Safari")), "a bundled entry");
        assert!(config.eligible(Some("com.example.reader")), "and an added one");
        assert!(!config.eligible(Some("com.apple.Terminal")));
        assert!(!config.eligible(None));
    }

    #[test]
    fn the_master_switch_makes_every_target_ineligible() {
        let off = SwipeNavHostConfig::from_env(Some("0"), None, None, None, None);
        assert!(!off.eligible(Some("com.apple.Safari")));
    }

    /// The affordance must go dark on exactly the condition the fire path swallows on.
    #[test]
    fn a_window_target_is_only_eligible_while_its_own_app_is_frontmost() {
        let config = SwipeNavHostConfig::default();
        assert!(config.eligible_window_target(Some("com.apple.Safari"), Some("com.apple.Safari")));
        assert!(
            !config.eligible_window_target(Some("com.apple.Safari"), Some("com.apple.Terminal")),
            "the chord would land in the other app",
        );
        assert!(!config.eligible_window_target(Some("com.apple.Safari"), None));
        assert!(!config.eligible_window_target(None, Some("com.apple.Safari")));
    }

    #[test]
    fn an_eligible_push_carries_the_history_read_and_the_operating_point() {
        let config = SwipeNavHostConfig::from_env(None, None, Some("120"), None, None);
        let status = config.status(Some("com.apple.Safari"), Some(BOTH));
        assert!(status.eligible && status.slow_tier && status.history_known);
        assert!(status.can_go_back && status.can_go_forward);
        assert_eq!(status.fire_travel, 120);
    }

    /// A canonical all-zero tail, so "ineligible" is byte-identical however the read went.
    #[test]
    fn an_ineligible_push_zeroes_the_history_bits() {
        let config = SwipeNavHostConfig::default();
        let status = config.status(Some("com.apple.Terminal"), Some(BOTH));
        assert!(!status.eligible);
        assert!(!status.can_go_back && !status.can_go_forward && !status.history_known);
        assert_eq!(
            status,
            config.status(Some("com.apple.Terminal"), None),
            "with or without a read, the tail is the same",
        );
    }

    /// The client fails open rather than showing a dark chip it cannot justify.
    #[test]
    fn an_unread_history_is_reported_as_unknown_rather_than_as_blocked() {
        let config = SwipeNavHostConfig::default();
        let status = config.status(Some("com.apple.Safari"), None);
        assert!(status.eligible);
        assert!(!status.history_known);
        assert!(!status.can_go_back && !status.can_go_forward);
    }

    #[test]
    fn the_window_push_mirrors_the_window_eligibility_rule() {
        let config = SwipeNavHostConfig::default();
        let matched = config.window_status(Some("com.apple.Safari"), Some("com.apple.Safari"), Some(BOTH));
        assert!(matched.eligible && matched.can_go_back);
        let mismatched =
            config.window_status(Some("com.apple.Safari"), Some("com.apple.Terminal"), Some(BOTH));
        assert!(!mismatched.eligible && !mismatched.can_go_back);
    }
}
