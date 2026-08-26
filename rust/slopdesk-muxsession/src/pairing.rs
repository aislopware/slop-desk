//! Which of the two physical mux sockets just arrived, and what that costs the one already parked.
//!
//! A client dials the host TWICE — a CONTROL socket and a DATA socket — and the two become ONE
//! shared connection only once both have shown the same 16-byte `connectionID` in their preamble.
//! Whichever lands first has to wait somewhere, so the listener parks it in a map keyed by that id.
//! Everything below is about what the SECOND arrival means, and there are only three answers.
//!
//! ## The parked half is a live file descriptor, and the map is the only thing holding it
//!
//! That is the whole reason this is a decision rather than a dictionary write. The reaper that
//! expires an abandoned half-pair walks the CURRENT map entry; a link the map no longer names is a
//! socket nothing will ever close. So a re-park that OVERWRITES the parked half leaks its fd, and a
//! peer that re-sends the same side in a loop leaks one per message — while ALSO restamping the
//! entry's `createdAt`, which pushes the reaper's own deadline out ahead of itself. The two
//! failures compound: the leak grows and the thing that would have bounded it keeps being deferred.
//!
//! [`decide`] therefore reports the displacement as an obligation, and the caller closes what it is
//! about to drop. It cannot be inferred at the call site from "was there an entry" — an entry on
//! the OPPOSITE side is the ordinary completion and must not be closed.
//!
//! ## A control link arriving twice is not the same event as a data link arriving first
//!
//! Both are "there was already something in the map", and they call for opposite acts. The test
//! table below is the whole state space written out, one line per state, because the two that pair
//! and the two that displace differ only in which bool is set — and reading `isControl ? … : …`
//! twice is how a reviewer talks themselves into believing a wrong one.
//!
//! ## Why the expiry test lives here too
//!
//! [`pending_expired`] is the reaper's half of the same map. It is one comparison, and it is here
//! rather than at the call site for one reason: the boundary is STRICT. An entry sitting exactly on
//! its deadline is NOT expired, so an injected timeout of zero — which the tests use to force
//! expiry without a wall-clock sleep — still needs a non-zero elapsed to fire, and a caller that
//! wrote `>=` would reap every half-pair the instant it was parked.

/// What the listener must do about the half-link that just arrived.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Decision {
    /// Both sides are present — build the shared connection and stop parking anything.
    pub paired: bool,
    /// This re-park is displacing an already-parked SAME-SIDE half, whose socket the caller must
    /// `close()`. Never set when the pair completes: the entry being consumed is the OPPOSITE side,
    /// and it is going into the connection rather than into the bin.
    pub closes_displaced_same_side: bool,
}

/// The pairing rule for one arriving half-link, against the half already parked under its id.
///
/// `existing_has_control` / `existing_has_data` describe the parked entry (both `false` when there
/// is none); `is_control` is the side that just arrived.
#[must_use]
pub const fn decide(existing_has_control: bool, existing_has_data: bool, is_control: bool) -> Decision {
    let control_present = if is_control { true } else { existing_has_control };
    let data_present = if is_control { existing_has_data } else { true };
    if control_present && data_present {
        return Decision {
            paired: true,
            closes_displaced_same_side: false,
        };
    }
    // A re-park: the arriving half takes the arriving SIDE's slot, so whatever was in that slot is
    // displaced. Only the same side can be displaced — the opposite side would have paired above.
    Decision {
        paired: false,
        closes_displaced_same_side: if is_control {
            existing_has_control
        } else {
            existing_has_data
        },
    }
}

/// Whether a half-paired entry has waited longer than the listener allows.
///
/// Both spans are whole nanoseconds, which is the only unit that survives the crossing: the near
/// side measures with a monotonic clock whose instants are not numbers this side could hold, and
/// the difference of two of them is.
///
/// STRICTLY greater: an entry exactly on its deadline stays. See the module header for why the
/// other spelling breaks a zero-timeout test rather than a production host.
#[must_use]
pub const fn pending_expired(elapsed_nanos: u64, timeout_nanos: u64) -> bool {
    elapsed_nanos > timeout_nanos
}

#[cfg(test)]
mod tests {
    use super::{Decision, decide, pending_expired};

    /// The WHOLE state space of [`decide`], one line per state, with what each state MEANS.
    ///
    /// Eight entries because the inputs are three bools and none of the eight is folded away. The
    /// last two are unreachable in the listener — a map entry holding BOTH sides has already been
    /// consumed into a connection and removed — and they are here anyway, because the function is
    /// total and a reader deserves to know that the impossible state still answers "pair it" rather
    /// than "close something".
    const STATES: &[(bool, bool, bool, Decision, &str)] = &[
        (
            false,
            false,
            true,
            Decision {
                paired: false,
                closes_displaced_same_side: false,
            },
            "the first CONTROL of a new connection: park it, there is nothing to displace",
        ),
        (
            false,
            false,
            false,
            Decision {
                paired: false,
                closes_displaced_same_side: false,
            },
            "the first DATA of a new connection: the client dialled data-first, which is legal",
        ),
        (
            true,
            false,
            false,
            Decision {
                paired: true,
                closes_displaced_same_side: false,
            },
            "the DATA that completes a parked CONTROL — the ordinary handshake",
        ),
        (
            false,
            true,
            true,
            Decision {
                paired: true,
                closes_displaced_same_side: false,
            },
            "the CONTROL that completes a parked DATA — the same handshake, dialled the other way",
        ),
        (
            true,
            false,
            true,
            Decision {
                paired: false,
                closes_displaced_same_side: true,
            },
            "a SECOND control while one is parked: not a partner, a duplicate — its predecessor's fd leaves \
             the map and must be closed",
        ),
        (
            false,
            true,
            false,
            Decision {
                paired: false,
                closes_displaced_same_side: true,
            },
            "a SECOND data while one is parked: the same duplicate, the same leak",
        ),
        (
            true,
            true,
            true,
            Decision {
                paired: true,
                closes_displaced_same_side: false,
            },
            "unreachable — a full pair is consumed and removed, never left parked. Total anyway",
        ),
        (
            true,
            true,
            false,
            Decision {
                paired: true,
                closes_displaced_same_side: false,
            },
            "unreachable, the other side. Also total",
        ),
    ];

    #[test]
    fn every_state_of_the_pairing_is_the_state_the_listener_expects() {
        for &(has_control, has_data, is_control, expected, why) in STATES {
            assert_eq!(decide(has_control, has_data, is_control), expected, "{why}");
        }
    }

    /// The invariant behind the table, asserted apart from it so a bad table row cannot hide it: a
    /// completion NEVER closes anything, because the entry it consumed is going into the
    /// connection.
    #[test]
    fn a_completed_pair_never_closes_a_socket() {
        for &(has_control, has_data, is_control, ..) in STATES {
            let decision = decide(has_control, has_data, is_control);
            assert!(
                !(decision.paired && decision.closes_displaced_same_side),
                "({has_control}, {has_data}, {is_control}) would close a socket it just paired",
            );
        }
    }

    /// The other invariant: a displacement is only ever of the side that ARRIVED. Restated as a
    /// property because the ternary in `decide` is exactly the line a refactor gets backwards.
    #[test]
    fn only_the_arriving_side_is_ever_displaced() {
        for &(has_control, has_data, is_control, ..) in STATES {
            let decision = decide(has_control, has_data, is_control);
            let same_side_was_parked = if is_control { has_control } else { has_data };
            assert_eq!(
                decision.closes_displaced_same_side,
                same_side_was_parked && !decision.paired,
                "({has_control}, {has_data}, {is_control})",
            );
        }
    }

    #[test]
    fn an_entry_exactly_on_its_deadline_is_not_yet_expired() {
        assert!(!pending_expired(15_000_000_000, 15_000_000_000));
        assert!(pending_expired(15_000_000_001, 15_000_000_000));
        assert!(!pending_expired(0, 15_000_000_000));
    }

    /// A zero timeout is what a test injects to force expiry with no wall-clock wait. It must still
    /// require some elapsed time, or an entry parked and reaped in the same instant would vanish
    /// before its partner could possibly have been accepted.
    #[test]
    fn a_zero_timeout_still_spares_an_entry_with_no_elapsed_time() {
        assert!(!pending_expired(0, 0));
        assert!(pending_expired(1, 0));
    }

    /// The clock never runs backwards, but a saturating subtraction on the near side answers zero
    /// when it appears to. Zero elapsed is never expired, so the fold is safe rather than lucky.
    #[test]
    fn the_largest_span_expires_and_the_largest_timeout_does_not() {
        assert!(pending_expired(u64::MAX, 0));
        assert!(!pending_expired(u64::MAX, u64::MAX));
    }
}
