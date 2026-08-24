//! Whether a working agent should keep the Mac awake.
//!
//! The preference sidecar carries the user's opt-in; the panes carry the work. This is what the two
//! of them mean together, kept away from the `IOPMAssertion` itself — that is
//! `slopdesk-apple-power`'s one job, and it is the half that cannot be tested headlessly.
//!
//! ## The answer is the whole state, not an event
//!
//! Asked on every fold and acted on by a strictly balanced create⇄release, so the rule answers what
//! SHOULD be held right now rather than what changed. A rule phrased as "the last agent finished,
//! so release" leaks the assertion the moment two panes finish in the same fold — and a leaked
//! assertion keeps the machine awake until the daemon dies.
//!
//! ## Why the SET is here and not at the call site
//!
//! hostd hears about one pane at a time, from several threads, so somebody has to remember which
//! panes are still working. That used to be a `Set<String>` in Swift beside the assertion, and the
//! pairing was load-bearing in a way a reader had to be told: mutate the set and apply the verdict
//! under ONE lock, or two interleaved notes can apply in the order that leaves the assertion held
//! with an empty set. [`PreventSleep`] makes it one call instead of two, so the ordering is not
//! something a caller can get wrong — the fold takes `&mut self`, and what it answers is always
//! computed from the set it just updated.

/// Whether the host should be holding a system-sleep assertion.
///
/// Only while the feature is enabled AND at least one agent is working; anything else releases it.
/// Turning the preference off mid-run therefore releases an assertion already held, which is the
/// behaviour the toggle promises.
#[must_use]
pub const fn should_assert(any_agent_working: bool, enabled: bool) -> bool {
    enabled && any_agent_working
}

/// Which panes are working, and therefore whether the assertion should be held.
///
/// A SET rather than a count: hostd's fan-out can report the same pane working twice (a status
/// re-emit, a teardown that races a transition), and a counter would drift up on the first and
/// below zero on the second. A pane id is idempotent in both directions.
#[derive(Debug, Default, Clone)]
pub struct PreventSleep {
    enabled: bool,
    working: std::collections::BTreeSet<String>,
}

impl PreventSleep {
    /// A fold with nothing working yet. `enabled` is the `SLOPDESK_AGENT_PREVENT_SLEEP` opt-in,
    /// read once at launch — the preference is not live-reloadable, and a restart is the reload.
    #[must_use]
    pub const fn new(enabled: bool) -> Self {
        Self {
            enabled,
            working: std::collections::BTreeSet::new(),
        }
    }

    /// Records one pane's `.working` transition and answers what should be held NOW.
    ///
    /// The answer is the whole state, per the note above — a caller drives its assertion to this
    /// value on every edge and never counts anything itself.
    pub fn note(&mut self, pane: &str, working: bool) -> bool {
        if working {
            // Only allocates when the pane is not already known to be working.
            if !self.working.contains(pane) {
                self.working.insert(pane.to_owned());
            }
        } else {
            self.working.remove(pane);
        }
        self.should_hold()
    }

    /// Forgets a pane entirely — the same as noting it not-working, named for the teardown path so
    /// a closed tab reads as a removal rather than as a status nobody will ever correct.
    pub fn forget(&mut self, pane: &str) -> bool {
        self.note(pane, false)
    }

    /// What should be held right now.
    #[must_use]
    pub fn should_hold(&self) -> bool {
        should_assert(!self.working.is_empty(), self.enabled)
    }

    /// How many panes are working. Diagnostic; the assertion only ever asks whether it is zero.
    #[must_use]
    pub fn working_count(&self) -> usize {
        self.working.len()
    }
}

#[cfg(test)]
mod tests {
    use super::{PreventSleep, should_assert};

    #[test]
    fn the_assertion_needs_both_the_opt_in_and_the_work() {
        assert!(should_assert(true, true));
        assert!(!should_assert(true, false), "the feature is off");
        assert!(!should_assert(false, true), "nothing is working");
        assert!(!should_assert(false, false));
    }

    #[test]
    fn the_first_working_pane_asserts_and_the_last_one_to_finish_releases() {
        let mut fold = PreventSleep::new(true);
        assert!(!fold.should_hold());
        assert!(fold.note("a", true));
        assert!(fold.note("b", true));
        assert!(fold.note("a", false), "b is still working");
        assert!(!fold.note("b", false));
        assert_eq!(fold.working_count(), 0);
    }

    /// The drift a counter would have. Two `working: true` for one pane must not need two falses.
    #[test]
    fn repeating_a_transition_does_not_move_the_set() {
        let mut fold = PreventSleep::new(true);
        assert!(fold.note("a", true));
        assert!(fold.note("a", true));
        assert_eq!(fold.working_count(), 1);
        assert!(!fold.note("a", false));
        assert!(!fold.note("a", false), "a second release must not underflow");
        assert_eq!(fold.working_count(), 0);
    }

    /// A pane nobody ever reported as working is not an error to forget — the teardown fan reaches
    /// every closing pane, working or not.
    #[test]
    fn forgetting_an_unknown_pane_is_a_no_op() {
        let mut fold = PreventSleep::new(true);
        assert!(fold.note("a", true));
        assert!(fold.forget("never-seen"), "a is still working");
        assert!(!fold.forget("a"));
    }

    /// With the opt-in off the set is still tracked, so the answer is right the instant a build
    /// with the preference on runs the same fold — the flag gates the ANSWER, not the bookkeeping.
    #[test]
    fn the_opt_in_gates_the_answer_and_not_the_set() {
        let mut fold = PreventSleep::new(false);
        assert!(!fold.note("a", true));
        assert_eq!(fold.working_count(), 1);
        assert!(!fold.should_hold());
    }
}
