//! The screen engine's VERDICT, in the terms the status machine speaks.
//!
//! The engine itself is [`slopdesk-screend`](../../slopdesk-screend) (docs/52 §4b): the rule
//! ladder, the manifests, the region resolver and both stream trackers live there, so this module
//! has no evaluation input type and no evaluator. It keeps the verdict because the state machine
//! and the temporal hold consume it, and those are the host's — the split is that **screend owns
//! everything reading the BYTES and this crate owns everything reading the CLOCK**.

/// The four-way agent state a manifest rule resolves to (herdr `AgentState`, ported 1:1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum AgentScreenState {
    /// Finished, prompt visible, nothing happening.
    Idle,
    /// Actively processing.
    Working,
    /// Needs human input.
    Blocked,
    /// Plain shell, unrecognised — or a `skip_state_update` freeze rule.
    #[default]
    Unknown,
}

impl AgentScreenState {
    /// The wire/manifest spelling (the Swift enum's raw value).
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Unknown => "unknown",
        }
    }

    /// Parses the wire/manifest spelling. `None` for anything else — an unknown state is a decoding
    /// failure, not a fifth state, and the caller decides what to do about it.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "idle" => Some(Self::Idle),
            "working" => Some(Self::Working),
            "blocked" => Some(Self::Blocked),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }
}

/// One decoded `ScreenDetection` reply — what the engine saw, and how literally it saw it.
///
/// The `visible_*` flags are true only when the SCREEN literally shows the corresponding chrome (a
/// live prompt box, a live blocker form, a live spinner). They gate the temporal layer: a visible
/// idle bypasses the working→idle hold, and a visible blocker gets the steady re-publish heartbeat.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "the three `visible_*` flags are herdr's own reply shape, and collapsing them into an enum \
              would lose that two can be true at once"
)]
pub struct AgentScreenDetection {
    /// The rule ladder's verdict.
    pub state: AgentScreenState,
    /// A freeze rule matched (transcript viewer, model picker): change nothing.
    pub skip_state_update: bool,
    /// A live prompt box is on screen.
    pub visible_idle: bool,
    /// A live blocker form is on screen.
    pub visible_blocker: bool,
    /// A live spinner is on screen.
    pub visible_working: bool,
    /// The winning rule's id, or `None` on the fallback path.
    pub matched_rule_id: Option<String>,
    /// herdr's `fallback_reason` constant when no rule matched a known agent.
    pub fallback_reason: Option<String>,
}

impl AgentScreenDetection {
    /// A verdict carrying `state` and nothing else — every flag clear, no rule named.
    #[must_use]
    pub fn plain(state: AgentScreenState) -> Self {
        Self {
            state,
            ..Self::default()
        }
    }

    /// A verdict whose chrome is literally on screen: `state` plus its matching `visible_*` flag.
    ///
    /// The pairing is the whole point — `visible_idle` is what lets an idle clear a hook block, so
    /// setting it by hand next to the wrong state is the one construction mistake worth removing.
    #[must_use]
    pub fn visible(state: AgentScreenState) -> Self {
        Self {
            state,
            visible_idle: matches!(state, AgentScreenState::Idle),
            visible_blocker: matches!(state, AgentScreenState::Blocked),
            visible_working: matches!(state, AgentScreenState::Working),
            ..Self::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AgentScreenDetection, AgentScreenState};

    #[test]
    fn every_state_round_trips_through_its_manifest_spelling() {
        for state in [
            AgentScreenState::Idle,
            AgentScreenState::Working,
            AgentScreenState::Blocked,
            AgentScreenState::Unknown,
        ] {
            assert_eq!(AgentScreenState::from_name(state.name()), Some(state));
        }
        assert_eq!(AgentScreenState::from_name("busy"), None);
    }

    #[test]
    fn a_visible_verdict_lights_exactly_its_own_chrome_flag() {
        let idle = AgentScreenDetection::visible(AgentScreenState::Idle);
        assert!(idle.visible_idle && !idle.visible_blocker && !idle.visible_working);
        let blocked = AgentScreenDetection::visible(AgentScreenState::Blocked);
        assert!(blocked.visible_blocker && !blocked.visible_idle && !blocked.visible_working);
        let unknown = AgentScreenDetection::visible(AgentScreenState::Unknown);
        assert!(!unknown.visible_idle && !unknown.visible_blocker && !unknown.visible_working);
    }

    #[test]
    fn a_plain_verdict_claims_no_chrome_at_all() {
        let plain = AgentScreenDetection::plain(AgentScreenState::Idle);
        assert_eq!(plain.state, AgentScreenState::Idle);
        assert!(!plain.visible_idle);
        assert!(!plain.skip_state_update);
        assert_eq!(plain.matched_rule_id, None);
    }
}
