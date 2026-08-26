//! The `pane/titleFresh` verdict, in C.
//!
//! The rule is `slopdesk_wire::document::fields::title_is_fresh`; what is here is the marshalling.
//!
//! ## Why this door exists at all
//!
//! The verdict had two callers in two different Swift targets — the host, which computes it off a
//! live `MuxChannelSession`, and the client's workspace mirror, which reads it back off the
//! document — and one Swift copy of the rule shared between them. The crate already held the same
//! four rules for its own decoder. So there were two implementations of a comparison whose whole
//! job is that the two ends agree, and the only thing keeping them agreeing was that nobody had
//! edited either. This door deletes the Swift one; both callers now ask the same function the
//! document codec asks.
//!
//! ## Two `nil`s, two flags, and no sentinel
//!
//! Both stamps are optional and BOTH absences mean something specific: no title has been sniffed
//! yet (never fresh), and no command block is open (always fresh, because a shell without block
//! markers never opens one and must not lose its title for it). A sentinel `f64` would have to
//! stand for both, and every candidate is a real value on this timeline: `0.0` is the epoch, a
//! negative is a clock that stepped backwards, and NaN compares false against everything — which
//! would turn "no title yet" into "the title is stale" without a branch anywhere saying so. So each
//! stamp crosses as a value plus a presence flag, `docs/55` §4b's rule and the shape
//! `slopdesk_connection_pulse_settled`'s `has_previous` already uses.
//!
//! `liveness` crosses as its wire byte and is read through
//! [`PaneLivenessState::from_byte`](slopdesk_wire::document::fields::PaneLivenessState::from_byte),
//! so a byte from a newer host reads as `Dead` and the pane renders stale. That is the degradation
//! the rule wants: a stale live pane is cosmetic, a live-looking dead pane is the bug the field
//! exists to prevent.

use core::ffi::c_uchar;

use slopdesk_wire::document::fields::{PaneLivenessState, title_is_fresh};

use crate::optional_of;

/// Whether a pane's live title still describes what is on screen.
///
/// `title_stamped_at` and `command_started_at` are host-timeline seconds and are read only when
/// their flag is set; the value beside a clear flag is never looked at.
///
/// A scalar-in/scalar-out door, so there is no buffer and no size-then-read protocol — the answer
/// is one bit.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_title_fresh(
    has_title_stamp: bool,
    title_stamped_at: f64,
    has_command_stamp: bool,
    command_started_at: f64,
    liveness: c_uchar,
) -> bool {
    title_is_fresh(
        optional_of(has_title_stamp, title_stamped_at),
        optional_of(has_command_stamp, command_started_at),
        PaneLivenessState::from_byte(liveness),
    )
}

#[cfg(test)]
mod tests {
    use super::slopdesk_ws_pane_title_fresh;

    /// The wire bytes, spelled out rather than imported, because what the SWIFT side sends is a
    /// number and this is the place that number is read.
    const ATTACHED: u8 = 0;
    const DETACHED: u8 = 1;
    const DEAD: u8 = 2;

    fn fresh(title: Option<f64>, command: Option<f64>, liveness: u8) -> bool {
        slopdesk_ws_pane_title_fresh(
            title.is_some(),
            title.unwrap_or_default(),
            command.is_some(),
            command.unwrap_or_default(),
            liveness,
        )
    }

    /// The four rules, in the order `PaneLivenessTests` pinned them in Swift.
    #[test]
    fn the_four_rules_cross_whole() {
        assert!(
            !fresh(Some(100.0), None, DEAD),
            "rule 1 — a dead pane's restored title describes a process that is gone"
        );
        assert!(
            !fresh(None, None, ATTACHED),
            "rule 2 — no title at all is not a freshness question"
        );
        assert!(
            fresh(Some(100.0), None, ATTACHED),
            "rule 3 — no open command block means trust"
        );
        assert!(
            fresh(Some(100.0), Some(100.0), ATTACHED),
            "rule 4 — stamped exactly at the start still describes THIS command"
        );
        assert!(fresh(Some(101.0), Some(100.0), ATTACHED), "rule 4 — after");
        assert!(!fresh(Some(99.0), Some(100.0), ATTACHED), "rule 4 — before");
    }

    /// A detached PTY is still a process, so its title is still a title.
    #[test]
    fn detached_is_live_and_dead_is_not() {
        assert!(fresh(Some(100.0), None, DETACHED));
        assert!(!fresh(Some(100.0), None, DEAD));
    }

    /// The reason there is no sentinel: `0.0` and a negative are ordinary values on this timeline,
    /// and the flag is what makes them absent.
    #[test]
    fn the_flag_is_what_says_absent_and_not_the_value_beside_it() {
        // SAFETY: a scalar door — there is no pointer to keep live.
        let with_a_zero_stamp = slopdesk_ws_pane_title_fresh(true, 0.0, true, 0.0, ATTACHED);
        assert!(
            with_a_zero_stamp,
            "0.0 is the epoch, not a missing stamp — and 0 >= 0 is fresh"
        );
        // SAFETY: a scalar door — there is no pointer to keep live.
        let with_the_flags_clear = slopdesk_ws_pane_title_fresh(false, 0.0, false, 0.0, ATTACHED);
        assert!(
            !with_the_flags_clear,
            "the same numbers with the flags clear are no title at all"
        );
        assert!(
            !fresh(Some(-2.0), Some(-1.0), ATTACHED),
            "a clock that stepped backwards is still an ordering"
        );
    }

    /// A byte from a build that knows a state this one does not renders STALE rather than live.
    #[test]
    fn an_unknown_liveness_byte_degrades_toward_dead() {
        assert!(!fresh(Some(100.0), None, 3));
        assert!(!fresh(Some(100.0), None, 255));
    }
}
