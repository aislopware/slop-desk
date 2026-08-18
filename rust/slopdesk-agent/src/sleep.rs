//! Whether a working agent should keep the Mac awake.
//!
//! The host rolls its live panes up into one flag — is ANY agent working — and the preference
//! sidecar carries the user's opt-in. This is what the two of them mean together, kept away from
//! the glue that holds the actual `IOPMAssertion` because that glue is the half that cannot be
//! tested headlessly.
//!
//! ## The answer is the whole state, not an event
//!
//! Asked on every fold and acted on by a strictly balanced create⇄release, so the rule answers what
//! SHOULD be held right now rather than what changed. A rule phrased as "the last agent finished,
//! so release" leaks the assertion the moment two panes finish in the same fold — and a leaked
//! assertion keeps the machine awake until the daemon dies.

/// Whether the host should be holding a system-sleep assertion.
///
/// Only while the feature is enabled AND at least one agent is working; anything else releases it.
/// Turning the preference off mid-run therefore releases an assertion already held, which is the
/// behaviour the toggle promises.
#[must_use]
pub const fn should_assert(any_agent_working: bool, enabled: bool) -> bool {
    enabled && any_agent_working
}

#[cfg(test)]
mod tests {
    use super::should_assert;

    #[test]
    fn the_assertion_needs_both_the_opt_in_and_the_work() {
        assert!(should_assert(true, true));
        assert!(!should_assert(true, false), "the feature is off");
        assert!(!should_assert(false, true), "nothing is working");
        assert!(!should_assert(false, false));
    }
}
