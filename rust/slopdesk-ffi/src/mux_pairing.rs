//! Pairing the two physical mux sockets, in C.
//!
//! The rule is `slopdesk_muxsession::pairing`; what is here is the marshalling, and there is almost
//! none of it — every input is a bool or a count, so nothing is lent and nothing is delivered.
//!
//! ## Why the socket does not cross, and could not
//!
//! The thing being decided ABOUT is an `NWConnection`: a Network.framework object with a queue, a
//! state handler and a file descriptor underneath. It never crosses and it never needs to. The
//! listener asks which side just arrived and which side it already holds — three bools — and gets
//! back the two acts it owes: build the pair, and close the socket it is about to drop. Closing is
//! the near side's, because the fd is.
//!
//! ## The clock does not cross either
//!
//! The listener measures with a `ContinuousClock`, whose instants are monotonic tokens rather than
//! numbers. Their DIFFERENCE is a number, so what crosses is one elapsed span and one timeout, both
//! as whole nanoseconds — the unit every `Duration` in this tree crosses under. A saturating
//! subtraction on the near side means a clock that appears to run backwards answers zero elapsed,
//! which the rule reads as "not expired", which is the safe direction: the entry waits for the next
//! tick rather than being reaped the moment it was parked.

use slopdesk_muxsession::pairing;

/// What the listener must do about the half-link that just arrived.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskMuxPairing {
    /// Both sides are present — build the shared connection.
    pub paired: bool,
    /// This re-park displaces an already-parked SAME-SIDE half, whose socket the caller must close.
    /// The reaper only ever sees the CURRENT map entry, so a displaced link the caller does not
    /// close is a file descriptor nothing will ever reach again — and a peer re-sending one side in
    /// a loop leaks one per message while restamping the entry the reaper measures against.
    pub closes_displaced_same_side: bool,
}

/// The pairing rule for one arriving half-link, against the half already parked under its id.
///
/// `existing_has_control` / `existing_has_data` describe the parked entry — both false when there
/// is none — and `is_control` is the side that just arrived. A scalar door: there is nothing to
/// size, nothing to retry, and no answer that could be absent.
///
/// # Safety
/// Nothing is borrowed; every parameter is a value. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_mux_pairing_decide(
    existing_has_control: bool,
    existing_has_data: bool,
    is_control: bool,
) -> SlopDeskMuxPairing {
    let decision = pairing::decide(existing_has_control, existing_has_data, is_control);
    SlopDeskMuxPairing {
        paired: decision.paired,
        closes_displaced_same_side: decision.closes_displaced_same_side,
    }
}

/// Whether a half-paired entry has waited past the listener's bound, both spans in whole
/// nanoseconds.
///
/// STRICTLY greater, which is what lets a test inject a zero timeout and still park an entry for
/// one instant before reaping it. The rule's own module says what the other spelling costs.
///
/// # Safety
/// Nothing is borrowed; both parameters are values. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_mux_pending_expired(elapsed_nanos: u64, timeout_nanos: u64) -> bool {
    pairing::pending_expired(elapsed_nanos, timeout_nanos)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{SlopDeskMuxPairing, slopdesk_mux_pairing_decide, slopdesk_mux_pending_expired};

    /// The door, with the three bools in the order the header declares them.
    fn decide(has_control: bool, has_data: bool, is_control: bool) -> SlopDeskMuxPairing {
        // SAFETY: every parameter is a value; there is no memory to keep live.
        unsafe { slopdesk_mux_pairing_decide(has_control, has_data, is_control) }
    }

    /// A first arrival parks with nothing displaced — the default record, which is what a caller
    /// that misread the struct would also see, so it is worth naming.
    #[test]
    fn a_first_arrival_neither_pairs_nor_closes() {
        assert_eq!(decide(false, false, true), SlopDeskMuxPairing::default());
        assert_eq!(decide(false, false, false), SlopDeskMuxPairing::default());
    }

    #[test]
    fn the_opposite_side_completes_the_pair_either_way_round() {
        assert!(decide(true, false, false).paired);
        assert!(decide(false, true, true).paired);
        assert!(!decide(true, false, false).closes_displaced_same_side);
    }

    /// The fd-leak guard: the two states where the arriving side is already parked.
    #[test]
    fn a_duplicate_same_side_half_reports_the_socket_the_caller_must_close() {
        let duplicate_control = decide(true, false, true);
        assert!(!duplicate_control.paired);
        assert!(duplicate_control.closes_displaced_same_side);

        let duplicate_data = decide(false, true, false);
        assert!(!duplicate_data.paired);
        assert!(duplicate_data.closes_displaced_same_side);
    }

    #[test]
    fn an_entry_on_its_deadline_stays_and_one_past_it_goes() {
        // SAFETY: both parameters are values.
        assert!(unsafe { !slopdesk_mux_pending_expired(15_000_000_000, 15_000_000_000) });
        // SAFETY: ditto.
        assert!(unsafe { slopdesk_mux_pending_expired(15_000_000_001, 15_000_000_000) });
        // SAFETY: ditto — the saturated answer of a clock that appears to run backwards.
        assert!(unsafe { !slopdesk_mux_pending_expired(0, 0) });
    }
}
