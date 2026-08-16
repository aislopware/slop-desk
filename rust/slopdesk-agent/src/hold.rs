//! The temporal layer over the pure screen engine: the confirmation holds, the publish-worthiness
//! gate, and the steady visible-blocker heartbeat.
//!
//! A 1:1 port of herdr's `src/pane/agent_detection.rs`, plus one hold that is ours (see
//! [`AgentDetectionHold::should_hold_blocked_to_idle`]). Pure, with an injected clock.

use crate::screen::{AgentScreenDetection, AgentScreenState};

/// The two working→idle and blocked→idle confirmation holds, plus the publish gate.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct AgentDetectionHold {
    /// Pending working→idle confirmation state (herdr `PendingIdleConfirmation`).
    pending_idle_started_at: Option<f64>,
    confirmations: u32,
    /// Pending BLOCKED→idle confirmation state — the same shape, its own counters, so the
    /// herdr-ported working→idle hold stays byte-identical to upstream.
    pending_unblock_started_at: Option<f64>,
    unblock_confirmations: u32,
}

impl AgentDetectionHold {
    /// Recheck interval while a working→idle transition is pending.
    pub const PENDING_IDLE_RECHECK: f64 = 0.100;
    /// Consecutive confirming reads required to publish a plain idle.
    pub const PENDING_IDLE_CONFIRMATIONS: u32 = 3;
    /// Hard ceiling — publish the idle regardless once this much time has passed.
    pub const PENDING_IDLE_CAP: f64 = 0.700;
    /// Re-publish a steady visible blocker this often (a freshness heartbeat).
    pub const STABLE_VISIBLE_SIGNAL_REFRESH: f64 = 0.800;
    /// Suppress detection publishes for this long after a new agent appears (the splash paint).
    pub const STARTUP_GRACE_WINDOW: f64 = 3.0;
    /// The scan cadence when no hold is pending (herdr's detection-loop sleep).
    pub const SCAN_INTERVAL: f64 = 0.300;

    /// A fresh hold with nothing pending.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            pending_idle_started_at: None,
            confirmations: 0,
            pending_unblock_started_at: None,
            unblock_confirmations: 0,
        }
    }

    /// True while EITHER idle hold is pending — callers tighten the recheck cadence to
    /// [`PENDING_IDLE_RECHECK`](Self::PENDING_IDLE_RECHECK).
    #[must_use]
    pub const fn is_holding_idle(&self) -> bool {
        self.pending_idle_started_at.is_some() || self.pending_unblock_started_at.is_some()
    }

    /// herdr `should_hold_working_to_idle`.
    ///
    /// Engages only on working → PLAIN idle: a VISIBLE idle, real prompt chrome, bypasses the hold.
    /// Three consecutive confirmations release it; the 700 ms cap force-releases.
    pub const fn should_hold_working_to_idle(
        &mut self,
        previous: &AgentScreenDetection,
        next: &AgentScreenDetection,
        agent_changed: bool,
        process_exited: bool,
        now: f64,
    ) -> bool {
        let transitioning = matches!(previous.state, AgentScreenState::Working)
            && matches!(next.state, AgentScreenState::Idle)
            && !next.visible_idle
            && !next.visible_blocker
            && !agent_changed
            && !process_exited;
        if !transitioning {
            self.clear();
            return false;
        }
        let Some(started_at) = self.pending_idle_started_at else {
            self.pending_idle_started_at = Some(now);
            self.confirmations = 0;
            return true;
        };
        if now - started_at >= Self::PENDING_IDLE_CAP {
            self.clear();
            return false;
        }
        self.confirmations = self.confirmations.saturating_add(1);
        if self.confirmations >= Self::PENDING_IDLE_CONFIRMATIONS {
            self.clear();
            return false;
        }
        true
    }

    /// The BLOCKED→idle sibling — **ours, not herdr's**, and deliberately stricter than the
    /// working→idle hold above.
    ///
    /// A pane leaving a block is the single most consequential screen edge there is: it clears the
    /// mark, it is the hook-less COMPLETION edge, so it mints an unread finish across every client,
    /// and it can override an authoritative hook block. One bad read must not buy all of that.
    /// Requiring the same three confirmations (or the cap) costs at most ~300 ms on a genuine
    /// unblock — and the ONE unblock with no other announcement, an Esc-cancelled dialog, already
    /// has an instant path of its own
    /// ([`contains_cancel_keystroke`](crate::input::contains_cancel_keystroke) →
    /// [`ClaudeSignal::UserInput`](crate::signal::ClaudeSignal::UserInput)), which does not come
    /// through here at all.
    ///
    /// ⚠️ Unlike [`should_hold_working_to_idle`](Self::should_hold_working_to_idle), a VISIBLE idle
    /// does NOT bypass this hold. The visible idle is exactly the false verdict being guarded
    /// against: with the dialog's footer momentarily erased mid-repaint, the highest rule still
    /// matching is `live_prompt_box` — the dialog's own option list carries the `❯` pointer, and
    /// the footer needles that would veto it sit BELOW the last horizontal rule, outside
    /// `prompt_box_body`. So it reports idle + `visible_idle`, the one shape strong enough to clear
    /// a hook block (user-reported 2026-08-11, the `AskUserQuestion` Tab flap).
    pub const fn should_hold_blocked_to_idle(
        &mut self,
        previous: &AgentScreenDetection,
        next: &AgentScreenDetection,
        agent_changed: bool,
        process_exited: bool,
        now: f64,
    ) -> bool {
        let transitioning = matches!(previous.state, AgentScreenState::Blocked)
            && matches!(next.state, AgentScreenState::Idle)
            && !agent_changed
            && !process_exited;
        if !transitioning {
            self.clear_unblock();
            return false;
        }
        let Some(started_at) = self.pending_unblock_started_at else {
            self.pending_unblock_started_at = Some(now);
            self.unblock_confirmations = 0;
            return true;
        };
        if now - started_at >= Self::PENDING_IDLE_CAP {
            self.clear_unblock();
            return false;
        }
        self.unblock_confirmations = self.unblock_confirmations.saturating_add(1);
        if self.unblock_confirmations >= Self::PENDING_IDLE_CONFIRMATIONS {
            self.clear_unblock();
            return false;
        }
        true
    }

    const fn clear(&mut self) {
        self.pending_idle_started_at = None;
        self.confirmations = 0;
    }

    const fn clear_unblock(&mut self) {
        self.pending_unblock_started_at = None;
        self.unblock_confirmations = 0;
    }

    /// herdr `stable_visible_signal_refresh_due`: a steady visible blocker re-publishes every
    /// 800 ms even without a change.
    #[must_use]
    pub fn stable_visible_signal_refresh_due(
        previous: &AgentScreenDetection,
        next: &AgentScreenDetection,
        last_refresh: Option<f64>,
        now: f64,
    ) -> bool {
        if !next.visible_blocker || !previous.visible_blocker {
            return false;
        }
        let Some(last_refresh) = last_refresh else {
            return true;
        };
        now - last_refresh >= Self::STABLE_VISIBLE_SIGNAL_REFRESH
    }

    /// herdr `should_publish_detection_update`.
    #[must_use]
    pub fn should_publish(
        previous: &AgentScreenDetection,
        next: &AgentScreenDetection,
        agent_changed: bool,
        process_exited: bool,
        refresh_due: bool,
    ) -> bool {
        previous.state != next.state
            || previous.visible_idle != next.visible_idle
            || previous.visible_blocker != next.visible_blocker
            || previous.visible_working != next.visible_working
            || agent_changed
            || process_exited
            || (refresh_due && next.visible_blocker && previous.visible_blocker)
    }

    /// herdr `decide_detection_transition`: a hold means no publish; otherwise the publish gate.
    ///
    /// Both holds are consulted on EVERY decision and neither is short-circuited: each clears its
    /// own pending state when its transition does not apply, so a pane that walks
    /// working → idle → blocked → idle leaves no stale counter behind.
    pub fn decide(
        &mut self,
        previous: &AgentScreenDetection,
        next: &AgentScreenDetection,
        agent_changed: bool,
        process_exited: bool,
        last_refresh: Option<f64>,
        now: f64,
    ) -> bool {
        let holding_working =
            self.should_hold_working_to_idle(previous, next, agent_changed, process_exited, now);
        let holding_unblock =
            self.should_hold_blocked_to_idle(previous, next, agent_changed, process_exited, now);
        if holding_working || holding_unblock {
            return false;
        }
        let refresh_due = Self::stable_visible_signal_refresh_due(previous, next, last_refresh, now);
        Self::should_publish(previous, next, agent_changed, process_exited, refresh_due)
    }
}

#[cfg(test)]
mod tests {
    use super::AgentDetectionHold;
    use crate::screen::{AgentScreenDetection, AgentScreenState};

    fn plain(state: AgentScreenState) -> AgentScreenDetection {
        AgentScreenDetection::plain(state)
    }

    fn visible(state: AgentScreenState) -> AgentScreenDetection {
        AgentScreenDetection::visible(state)
    }

    #[test]
    fn three_confirmations_release_a_plain_working_to_idle() {
        let mut hold = AgentDetectionHold::new();
        let working = plain(AgentScreenState::Working);
        let idle = plain(AgentScreenState::Idle);
        assert!(!hold.decide(&working, &idle, false, false, None, 0.0));
        assert!(hold.is_holding_idle());
        assert!(!hold.decide(&working, &idle, false, false, None, 0.1));
        assert!(!hold.decide(&working, &idle, false, false, None, 0.2));
        // Third confirmation releases: the publish gate now sees a real state change.
        assert!(hold.decide(&working, &idle, false, false, None, 0.3));
        assert!(!hold.is_holding_idle());
    }

    #[test]
    fn the_cap_force_releases_a_hold_no_confirmation_ever_finishes() {
        let mut hold = AgentDetectionHold::new();
        let working = plain(AgentScreenState::Working);
        let idle = plain(AgentScreenState::Idle);
        assert!(!hold.decide(&working, &idle, false, false, None, 0.0));
        assert!(hold.decide(&working, &idle, false, false, None, 0.7));
        assert!(!hold.is_holding_idle());
    }

    #[test]
    fn a_visible_idle_bypasses_the_working_hold_but_not_the_unblock_hold() {
        let mut hold = AgentDetectionHold::new();
        assert!(hold.decide(
            &plain(AgentScreenState::Working),
            &visible(AgentScreenState::Idle),
            false,
            false,
            None,
            0.0
        ));
        assert!(!hold.is_holding_idle());

        let mut unblock = AgentDetectionHold::new();
        assert!(!unblock.decide(
            &plain(AgentScreenState::Blocked),
            &visible(AgentScreenState::Idle),
            false,
            false,
            None,
            0.0
        ));
        assert!(unblock.is_holding_idle());
    }

    #[test]
    fn an_agent_change_or_an_exit_publishes_immediately() {
        let mut hold = AgentDetectionHold::new();
        let working = plain(AgentScreenState::Working);
        let idle = plain(AgentScreenState::Idle);
        assert!(hold.decide(&working, &idle, true, false, None, 0.0));
        assert!(!hold.is_holding_idle());
        assert!(hold.decide(&working, &idle, false, true, None, 0.0));
    }

    #[test]
    fn walking_through_a_block_leaves_no_stale_counter_behind() {
        let mut hold = AgentDetectionHold::new();
        let working = plain(AgentScreenState::Working);
        let idle = plain(AgentScreenState::Idle);
        let blocked = plain(AgentScreenState::Blocked);
        assert!(!hold.decide(&working, &idle, false, false, None, 0.0));
        // A blocked verdict is not either hold's transition — both clear.
        assert!(hold.decide(&idle, &blocked, false, false, None, 0.1));
        assert!(!hold.is_holding_idle());
        // …so the next working→idle starts its own three-read count from scratch.
        assert!(!hold.decide(&working, &idle, false, false, None, 0.2));
        assert!(!hold.decide(&working, &idle, false, false, None, 0.3));
        assert!(!hold.decide(&working, &idle, false, false, None, 0.4));
        assert!(hold.decide(&working, &idle, false, false, None, 0.5));
    }

    #[test]
    fn a_steady_visible_blocker_re_publishes_on_the_heartbeat_and_not_before() {
        let blocker = visible(AgentScreenState::Blocked);
        assert!(AgentDetectionHold::stable_visible_signal_refresh_due(
            &blocker, &blocker, None, 0.0
        ));
        assert!(!AgentDetectionHold::stable_visible_signal_refresh_due(
            &blocker,
            &blocker,
            Some(0.0),
            0.5
        ));
        assert!(AgentDetectionHold::stable_visible_signal_refresh_due(
            &blocker,
            &blocker,
            Some(0.0),
            0.8
        ));
        // Not a blocker on both sides → never due.
        assert!(!AgentDetectionHold::stable_visible_signal_refresh_due(
            &plain(AgentScreenState::Idle),
            &blocker,
            None,
            9.0
        ));
    }

    #[test]
    fn an_unchanged_verdict_publishes_nothing() {
        let mut hold = AgentDetectionHold::new();
        let idle = plain(AgentScreenState::Idle);
        assert!(!hold.decide(&idle, &idle, false, false, None, 0.0));
    }

    #[test]
    fn a_chrome_flag_alone_is_worth_a_publish() {
        let mut hold = AgentDetectionHold::new();
        assert!(hold.decide(
            &plain(AgentScreenState::Blocked),
            &visible(AgentScreenState::Blocked),
            false,
            false,
            None,
            0.0
        ));
    }
}
