//! Taking a parked session back OUT of the detached store, in C.
//!
//! The rules are `slopdesk_muxsession::detach_retention`'s `take` and `ttl_on_insert`. The insert
//! side of the same store is [`crate::detach_retention`]; this is the other half of its lock, and
//! it is a second door rather than a widening of the first because the two are asked at opposite
//! ends of a session's parked life and by different callers.
//!
//! ## What crosses is a fact the near side established, not a question it asked
//!
//! `present` is not "is this id in the store" — that would be a lookup whose answer is stale before
//! it is read. It is the RESULT of the removal the near side has already performed under its lock,
//! which is the only place the race can be resolved. So the door is asked after the fact, and its
//! answer is what the caller now OWES: whether it won, whether a timer must be cancelled, and
//! whether it inherited a teardown.
//!
//! `child_exited` is the near side's `isChildExited()` — a `waitpid` that has already reaped, so an
//! unspawned pane answers false. It cannot be asked from here for the ordinary reason: there is no
//! process on this side of the boundary, only the answer about one.
//!
//! ## The timer choice crosses as a byte, and the `Task` never crosses at all
//!
//! Arming a TTL is `Task { sleep; evict }`, which is Swift's to run. What is decided here is
//! whether there is to be one — and the arm that matters is the one that says NO on an idempotent
//! re-park, because a second timer beside the first evicts by id and the id belongs to a live entry
//! by the time either fires.

use slopdesk_muxsession::detach_retention::{self, TtlChoice};

/// What one attempt to take an entry out of the store concluded.
// No `Default`: a zeroed `ttl` is `SLOPDESK_TTL_ARM`, and an "empty" record that reads as
// "arm a timer" is the one wrong answer this door must not have a shorthand for.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHostDetachTake {
    /// THIS call removed the entry — it won the teardown and owns what the entry's own cleanup
    /// would have done. `false` means somebody else already took it and this caller must stand
    /// down: releasing the journal writer and the hook-sink key now would cut them out from under
    /// a same-UUID successor that is already using both.
    pub won: bool,
    /// What to do about the entry's timer, as [`SLOPDESK_TTL_ARM`] / [`SLOPDESK_TTL_CANCEL`] /
    /// [`SLOPDESK_TTL_LEAVE_ALONE`].
    pub ttl: u8,
    /// The shell had already exited: shut the parked session down, and report this apart from "not
    /// found". The winner has assumed a teardown the session's own exit closure stood down from, so
    /// it still owes the final agent-status `.none` — the prevent-sleep balance is strict — and the
    /// drop of the hook-sink key, before it spawns the fresh shell for the same id.
    pub reap_dead_child: bool,
}

/// Arm a fresh eviction timer over the configured TTL.
pub const SLOPDESK_TTL_ARM: u8 = 0;
/// Cancel the timer this entry carries.
pub const SLOPDESK_TTL_CANCEL: u8 = 1;
/// Touch no timer — either because one is already armed on an entry being kept, or because none was
/// ever configured.
pub const SLOPDESK_TTL_LEAVE_ALONE: u8 = 2;

/// The take rule, for every caller that removes an entry by id.
///
/// `present` is whether the removal the near side just performed found anything; `child_exited` is
/// its `isChildExited()`. The caller that removes an entry BECAUSE the shell exited passes false —
/// its `onExit` has already fired, so there is nothing left to discover and nothing left to reap.
///
/// # Safety
/// Nothing is borrowed; both parameters are values. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_host_detach_take(
    present: bool,
    child_exited: bool,
) -> SlopDeskHostDetachTake {
    let verdict = detach_retention::take(present, child_exited);
    SlopDeskHostDetachTake {
        won: verdict.won,
        ttl: verdict.ttl.code(),
        reap_dead_child: verdict.reap_dead_child,
    }
}

/// The timer choice for an entry going IN, given the insert verdict's `idempotent` flag and whether
/// a TTL is configured at all.
///
/// An absent TTL — `SLOPDESK_DETACH_TTL_SECS` unset or `0` — means the parked session lives
/// indefinitely, which is the default and the tmux/zellij semantics: the resource bound in that
/// mode is the opt-in session cap, never a clock.
///
/// # Safety
/// Nothing is borrowed; both parameters are values. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_host_detach_ttl_on_insert(idempotent: bool, has_ttl: bool) -> u8 {
    detach_retention::ttl_on_insert(idempotent, has_ttl).code()
}

/// The three timer bytes, asserted against the rule's own enum rather than transcribed.
///
/// A constant respelled in the header is the drift this whole boundary exists to prevent, so the
/// header's numbers are checked against these and these against [`TtlChoice`].
const _: () = {
    assert!(TtlChoice::Arm.code() == SLOPDESK_TTL_ARM);
    assert!(TtlChoice::Cancel.code() == SLOPDESK_TTL_CANCEL);
    assert!(TtlChoice::LeaveAlone.code() == SLOPDESK_TTL_LEAVE_ALONE);
};

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SLOPDESK_TTL_ARM, SLOPDESK_TTL_CANCEL, SLOPDESK_TTL_LEAVE_ALONE, SlopDeskHostDetachTake,
        slopdesk_host_detach_take, slopdesk_host_detach_ttl_on_insert,
    };

    fn take(present: bool, child_exited: bool) -> SlopDeskHostDetachTake {
        // SAFETY: both parameters are values; there is no memory to keep live.
        unsafe { slopdesk_host_detach_take(present, child_exited) }
    }

    fn ttl(idempotent: bool, has_ttl: bool) -> u8 {
        // SAFETY: both parameters are values.
        unsafe { slopdesk_host_detach_ttl_on_insert(idempotent, has_ttl) }
    }

    /// The loser of two concurrent claims. Everything false, including the timer — there is no
    /// entry, so there is nothing armed to cancel.
    #[test]
    fn an_absent_entry_is_the_default_record() {
        assert_eq!(take(false, false), SlopDeskHostDetachTake {
            won: false,
            ttl: SLOPDESK_TTL_LEAVE_ALONE,
            reap_dead_child: false,
        });
        assert_eq!(take(false, true), take(false, false));
    }

    #[test]
    fn a_live_entry_is_won_and_its_timer_cancelled() {
        let verdict = take(true, false);
        assert!(verdict.won);
        assert_eq!(verdict.ttl, SLOPDESK_TTL_CANCEL);
        assert!(!verdict.reap_dead_child);
    }

    /// The outcome the near side must not fold into "not found": the winner inherited a teardown.
    #[test]
    fn a_dead_child_is_won_reaped_and_told_apart_from_both_neighbours() {
        let dead = take(true, true);
        assert!(dead.won);
        assert!(dead.reap_dead_child);
        assert_ne!(dead, take(false, true));
        assert_ne!(dead, take(true, false));
    }

    #[test]
    fn only_a_fresh_insert_with_a_configured_ttl_arms_a_timer() {
        assert_eq!(ttl(false, true), SLOPDESK_TTL_ARM);
        assert_eq!(ttl(false, false), SLOPDESK_TTL_LEAVE_ALONE);
        assert_eq!(
            ttl(true, true),
            SLOPDESK_TTL_LEAVE_ALONE,
            "the original entry's timer is already armed; a second evicts by id and the id is a live \
             entry's by the time either fires",
        );
        assert_eq!(ttl(true, false), SLOPDESK_TTL_LEAVE_ALONE);
    }

    /// The three bytes are distinct, which is what keeps a departure from reading as an arming on
    /// the far side.
    #[test]
    fn the_three_timer_bytes_do_not_collide() {
        let codes = [SLOPDESK_TTL_ARM, SLOPDESK_TTL_CANCEL, SLOPDESK_TTL_LEAVE_ALONE];
        assert_eq!(codes, [0, 1, 2]);
    }
}
