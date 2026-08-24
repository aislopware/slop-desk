//! The SUPERVISION vocabulary — what an orchestrator agent asking "which pane needs me?" is told.
//!
//! [`crate::status::ClaudeStatus`] is the host's own five-way reading. The `slopdesk-ctl` NDJSON
//! socket does not expose it: its audience is another agent, and an agent scripting against
//! `needsPermission` would be scripting against a Swift enum case name. So the socket speaks four
//! stable words — `idle`, `working`, `done`, `blocked` — and this module is the whole mapping.
//!
//! ## Why `blocked` and not `needs permission`
//! herdr and Warp both call a stalled-on-a-human agent *blocked*, and an orchestrator reading this
//! stream is reading it to decide where to send a person. `NeedsPermission` names the dominant
//! cause; `blocked` names the situation, which is the thing a supervisor acts on.
//!
//! ## Why [`ClaudeStatus::None`] collapses onto `idle`
//! A live pane whose detector has never seen an agent is, for a supervisor, doing nothing and
//! blocking nothing. Inventing a fifth `unknown` token would widen the closed set the `report` verb
//! validates against for a distinction no supervisor acts on — so the collapse is deliberate.
//!
//! It costs the stream ONE bit: a pane whose agent EXITED emits `"idle"`, byte-identical to the
//! `"idle"` it already sat at, and the subscriber's consecutive-duplicate dedupe swallows it. An
//! orchestrator watching `events` would never see an agent leave. [`presence`] carries that bit
//! alongside the state rather than widening the vocabulary to carry it.

use crate::status::ClaudeStatus;

/// The four supervision words, in increasing urgency — the CLOSED set the `report` verb validates
/// against, and the order [`ALL`] lists them in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SupervisionState {
    /// Nothing running and nothing waiting — including a pane with no agent at all.
    #[default]
    Idle,
    /// A turn is in flight.
    Working,
    /// A turn finished and has not been seen.
    Done,
    /// Stalled on a human: a permission prompt, an approval UI, a waiting-for-input dialog.
    Blocked,
}

/// Every supervision state, in the increasing-urgency order the `report` verb's error message
/// prints and [`crate::status::ClaudeStatus::ALL`] parallels.
pub const ALL: [SupervisionState; 4] = [
    SupervisionState::Idle,
    SupervisionState::Working,
    SupervisionState::Done,
    SupervisionState::Blocked,
];

impl SupervisionState {
    /// The wire word. This is the only spelling the ctl socket ever emits or accepts.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::Blocked => "blocked",
        }
    }

    /// Parses a client-supplied word. `None` for anything outside the closed set — the `report`
    /// verb validates-then-drops on that, BEFORE it touches any session.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        ALL.into_iter().find(|state| state.name() == name)
    }

    /// The supervision reading of a host status. Total, and the ONE place the collapse happens.
    #[must_use]
    pub const fn from_status(status: ClaudeStatus) -> Self {
        match status {
            ClaudeStatus::None | ClaudeStatus::Idle => Self::Idle,
            ClaudeStatus::Working => Self::Working,
            ClaudeStatus::Done => Self::Done,
            ClaudeStatus::NeedsPermission => Self::Blocked,
        }
    }
}

/// Whether an agent is PRESENT in the pane at all — the bit [`SupervisionState::from_status`]
/// collapses away. False only for [`ClaudeStatus::None`]; every other status implies one was
/// detected.
#[must_use]
pub const fn presence(status: ClaudeStatus) -> bool {
    !matches!(status, ClaudeStatus::None)
}

/// Whether `name` is one of the four. The `report` verb's guard, and the `events --state` filter's.
#[must_use]
pub fn is_valid(name: &str) -> bool {
    SupervisionState::from_name(name).is_some()
}

#[cfg(test)]
mod tests {
    use super::{ALL, SupervisionState, is_valid, presence};
    use crate::status::ClaudeStatus;

    #[test]
    fn the_closed_set_is_four_words_in_urgency_order() {
        assert_eq!(ALL.map(SupervisionState::name), [
            "idle", "working", "done", "blocked"
        ]);
    }

    #[test]
    fn every_word_in_the_set_validates_and_nothing_else_does() {
        for state in ALL {
            assert!(is_valid(state.name()), "{} must validate", state.name());
        }
        assert!(
            !is_valid("needsPermission"),
            "an enum case name is not a wire word"
        );
        assert!(
            !is_valid("unknown"),
            "the fifth state was deliberately not invented"
        );
        assert!(!is_valid(""), "empty is not a state");
        assert!(!is_valid("IDLE"), "the words are lowercase, exactly");
    }

    #[test]
    fn a_pane_with_no_agent_reads_idle_but_reports_absent() {
        assert_eq!(
            SupervisionState::from_status(ClaudeStatus::None),
            SupervisionState::Idle
        );
        assert_eq!(
            SupervisionState::from_status(ClaudeStatus::Idle),
            SupervisionState::Idle
        );
        assert!(!presence(ClaudeStatus::None), "no agent");
        assert!(presence(ClaudeStatus::Idle), "an idle agent is still an agent");
    }

    #[test]
    fn blocked_is_the_word_for_needs_permission() {
        assert_eq!(
            SupervisionState::from_status(ClaudeStatus::NeedsPermission).name(),
            "blocked"
        );
    }

    #[test]
    fn every_host_status_maps_and_round_trips_through_its_word() {
        for status in ClaudeStatus::ALL {
            let state = SupervisionState::from_status(status);
            assert_eq!(
                SupervisionState::from_name(state.name()),
                Some(state),
                "{status:?} crossed as {} and did not come back",
                state.name()
            );
            assert!(presence(status) || status == ClaudeStatus::None);
        }
    }
}
