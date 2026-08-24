//! Whether a streaming session should keep the host's DISPLAY lit.
//!
//! A client watching the desktop must never have the picture go dark because the host's
//! display-sleep timer fired mid-session. The stream itself is not user activity as far as the
//! window server is concerned — nobody is touching that Mac's keyboard — so the host has to say so,
//! and this is the rule that decides when.
//!
//! ## Why a refcount and not a set
//! Unlike `slopdesk_agent::sleep`'s pane fold, the thing being counted here has no id worth
//! remembering: sessions acquire on start and release on end, exactly once each, and two sessions
//! streaming the same display are two holders rather than one. What the fold has to survive is the
//! UNBALANCED release — a teardown path that releases twice, or one that releases a session that
//! never acquired — which clamps at zero rather than underflowing into "held forever". A `usize`
//! that wrapped would be the leak, not the crash.
//!
//! ## Only the desktop counts
//! Window-target sessions never hold: the desktop stream is the one a person is actively LOOKING
//! at, and a background window feed keeping a Mac's screen lit all night is a bug rather than a
//! feature. That choice is the CALLER's — it acquires or does not — because which target a session
//! has is the session's own state and not this fold's.
//!
//! The assertion itself is `slopdesk-apple-power`'s `SleepAssertion` with `SleepKind::Display`.
//! What crosses between them is one `bool`, on every edge, so the create⇄release stays balanced
//! against a state rather than against a history.

/// How many streaming display sessions are live, and therefore whether the display assertion should
/// be held.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct DisplayWake {
    holders: usize,
}

impl DisplayWake {
    /// A fold with no holders.
    #[must_use]
    pub const fn new() -> Self {
        Self { holders: 0 }
    }

    /// One more streaming display session. Answers what should be held now.
    ///
    /// Saturating rather than wrapping: a count that reached `usize::MAX` and rolled to zero would
    /// release an assertion every live session still needs, which is the one failure a refcount can
    /// have that a leak check never sees.
    pub const fn acquire(&mut self) -> bool {
        self.holders = self.holders.saturating_add(1);
        self.should_hold()
    }

    /// One streaming display session ended. Answers what should be held now.
    ///
    /// Clamps at zero: an unbalanced release must not underflow into a count no later release can
    /// bring back down, which would hold the display awake until the daemon dies.
    pub const fn release(&mut self) -> bool {
        self.holders = self.holders.saturating_sub(1);
        self.should_hold()
    }

    /// What should be held right now.
    #[must_use]
    pub const fn should_hold(&self) -> bool {
        self.holders > 0
    }

    /// How many sessions are holding. Diagnostic; the assertion only asks whether it is zero.
    #[must_use]
    pub const fn holders(&self) -> usize {
        self.holders
    }
}

#[cfg(test)]
mod tests {
    use super::DisplayWake;

    #[test]
    fn the_first_holder_lights_the_display_and_the_last_one_out_lets_it_sleep() {
        let mut wake = DisplayWake::new();
        assert!(!wake.should_hold());
        assert!(wake.acquire());
        assert!(wake.acquire());
        assert!(wake.release(), "one session is still streaming");
        assert!(!wake.release());
        assert_eq!(wake.holders(), 0);
    }

    /// The leak an underflow would be: a stray release must not put the count somewhere no
    /// balanced pair can return from.
    #[test]
    fn an_unbalanced_release_clamps_at_zero() {
        let mut wake = DisplayWake::new();
        assert!(!wake.release());
        assert!(!wake.release());
        assert_eq!(wake.holders(), 0);
        assert!(wake.acquire(), "a later session still lights it");
        assert!(!wake.release());
    }

    /// The other end of the same property, stated where a `+= 1` would have wrapped.
    #[test]
    fn the_count_saturates_rather_than_wrapping() {
        let mut wake = DisplayWake::new();
        for _ in 0..64 {
            assert!(wake.acquire());
        }
        assert_eq!(wake.holders(), 64);
        for _ in 0..63 {
            assert!(wake.release());
        }
        assert!(!wake.release());
    }
}
