//! `slopdesk watch:claude <id>` — the exit-code state machine that decides when a blocking wait is
//! over.
//!
//! The command blocks until the named session reaches an at-rest state, then exits `0` (settled or
//! closed), `4` (the id was never seen) or `9` (the deadline elapsed). The poll loop — the sleep,
//! the socket, the clock — is the caller's; everything that decides an exit code is here, which is
//! why every decision is a test rather than a compiled-and-reviewed branch inside a `main`.
//!
//! It lives in this crate rather than beside the rest of the CLI because every input it reads is an
//! agent fact: a [`ClaudeStatus`], whether that status is at rest, and a deadline over the same
//! monotonic clock the detection machine already uses.

use crate::status::ClaudeStatus;

/// The three terminal exit codes `watch:claude` can produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i32)]
pub enum WatchExit {
    /// The session reached an at-rest state — idle, done, or closed. Exit `0`.
    Settled = 0,
    /// The session id was never seen by the running app. Exit `4`.
    NeverSeen = 4,
    /// The deadline elapsed while the session was still active. Exit `9`.
    TimedOut = 9,
}

impl WatchExit {
    /// The process exit code for this outcome.
    #[must_use]
    pub const fn code(self) -> i32 {
        self as i32
    }
}

/// One poll's observation of the `agent-status` reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WatchObservation {
    /// `seen:true` with the rolled-up status.
    Status(ClaudeStatus),
    /// `seen:true` but NO status token: the pane EXISTS and its agent has not reported yet — the
    /// startup window. Distinct from a settled [`ClaudeStatus::None`], because it is still
    /// starting.
    SeenNoStatus,
    /// `seen:false` — the id does not resolve to any pane the running app knows.
    NotSeen,
}

impl WatchObservation {
    /// Decodes an `agent-status` reply's `{seen, status?}` fields.
    ///
    /// Forward-tolerant, the way every decode in this crate is: `seen:true` with an unknown or
    /// future token degrades to [`ClaudeStatus::None`] — "no agent here", so settled — rather than
    /// trapping. Absent-status and unknown-status are deliberately NOT the same answer: the first
    /// keeps polling, the second finishes.
    #[must_use]
    pub fn decode(seen: bool, status_token: Option<&str>) -> Self {
        if !seen {
            return Self::NotSeen;
        }
        status_token.map_or(Self::SeenNoStatus, |token| {
            Self::Status(ClaudeStatus::from_token(token))
        })
    }
}

/// The decision after one poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WatchStep {
    /// Stop polling and exit with this code.
    Finished(WatchExit),
    /// Not settled yet — sleep and poll again.
    KeepPolling,
}

/// Whether a polled status is "at rest" — a state `watch:claude` returns on.
///
/// At rest means neither actively working nor blocked on a human: [`Idle`](ClaudeStatus::Idle)
/// (awaiting a fresh prompt), [`Done`](ClaudeStatus::Done) (just finished a turn — the leading edge
/// of idle, and the actual "finished" signal) or [`None`](ClaudeStatus::None) (claude exited).
/// [`Working`](ClaudeStatus::Working) and [`NeedsPermission`](ClaudeStatus::NeedsPermission) are
/// both still active — the latter is blocked on a human, which is not the same as idle — so they
/// keep polling until they settle or the deadline elapses.
#[must_use]
pub const fn is_at_rest(status: ClaudeStatus) -> bool {
    matches!(
        status,
        ClaudeStatus::Idle | ClaudeStatus::Done | ClaudeStatus::None
    )
}

/// The BLOCK deadline in monotonic nanoseconds, decoupled from the per-IPC `--timeout`.
///
/// `watch:claude` blocks until the session settles. The per-IPC `--timeout` (3000 ms by default)
/// bounds each poll's socket round-trip and nothing else; feeding it into the block deadline would
/// exit `9` after three seconds, shorter than essentially any real turn. So the block is UNBOUNDED
/// by default (`None`), and only an explicit `--block-timeout` bounds it. A non-positive value is
/// also unbounded — never an instant timeout.
///
/// The addition saturates rather than wrapping: a caller-supplied timeout large enough to overflow
/// the clock means "no deadline I will live to see", and the saturated value says exactly that.
#[must_use]
pub const fn block_deadline_nanos(start_nanos: u64, block_timeout_ms: Option<i64>) -> Option<u64> {
    match block_timeout_ms {
        // The `ms > 0` guard is what makes the unsigned reinterpretation exact, not a truncation.
        Some(ms) if ms > 0 => Some(start_nanos.saturating_add(ms.cast_unsigned().saturating_mul(1_000_000))),
        _ => None,
    }
}

/// Decides the next step from one poll.
///
/// - `has_ever_been_seen` carries forward across polls, so a session that WAS seen and then
///   disappears reads as "closed" (exit `0`), while an id unknown on the very first poll reads as
///   "never seen" (exit `4`).
/// - `deadline_exceeded` is the caller's clock verdict, and it only forces a timeout while the
///   session is still active. A settled, closed or never-seen verdict wins over an expired
///   deadline, so a just-in-time finish is never reported as a timeout.
#[must_use]
pub const fn decide(
    observation: WatchObservation,
    has_ever_been_seen: bool,
    deadline_exceeded: bool,
) -> WatchStep {
    match observation {
        WatchObservation::Status(status) if is_at_rest(status) => WatchStep::Finished(WatchExit::Settled),
        // Still working, or blocked on a human, or in the agent-startup window before the first
        // report: keep polling unless the deadline has elapsed.
        WatchObservation::Status(_) | WatchObservation::SeenNoStatus => {
            if deadline_exceeded {
                WatchStep::Finished(WatchExit::TimedOut)
            } else {
                WatchStep::KeepPolling
            }
        },
        // An id resolving to NO pane is "closed" when we have seen it before, else "never seen".
        WatchObservation::NotSeen => {
            WatchStep::Finished(if has_ever_been_seen {
                WatchExit::Settled
            } else {
                WatchExit::NeverSeen
            })
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{WatchExit, WatchObservation, WatchStep, block_deadline_nanos, decide, is_at_rest};
    use crate::status::ClaudeStatus;

    #[test]
    fn the_exit_codes_are_the_documented_ones() {
        assert_eq!(WatchExit::Settled.code(), 0);
        assert_eq!(WatchExit::NeverSeen.code(), 4);
        assert_eq!(WatchExit::TimedOut.code(), 9);
    }

    #[test]
    fn at_rest_is_exactly_idle_done_and_none() {
        assert!(is_at_rest(ClaudeStatus::Idle));
        assert!(is_at_rest(ClaudeStatus::Done));
        assert!(is_at_rest(ClaudeStatus::None));
        assert!(!is_at_rest(ClaudeStatus::Working));
        // Blocked on a human is NOT idle, however long it stays there.
        assert!(!is_at_rest(ClaudeStatus::NeedsPermission));
    }

    #[test]
    fn an_unseen_id_decodes_regardless_of_any_status_token() {
        assert_eq!(WatchObservation::decode(false, None), WatchObservation::NotSeen);
        assert_eq!(
            WatchObservation::decode(false, Some("working")),
            WatchObservation::NotSeen
        );
    }

    #[test]
    fn a_seen_pane_with_no_token_is_the_startup_window_not_a_settled_none() {
        assert_eq!(
            WatchObservation::decode(true, None),
            WatchObservation::SeenNoStatus
        );
        assert_ne!(
            WatchObservation::decode(true, None),
            WatchObservation::Status(ClaudeStatus::None)
        );
    }

    #[test]
    fn every_known_token_decodes_to_its_status() {
        for status in ClaudeStatus::ALL {
            assert_eq!(
                WatchObservation::decode(true, Some(status.token())),
                WatchObservation::Status(status),
                "{}",
                status.token()
            );
        }
    }

    #[test]
    fn an_unknown_token_degrades_to_none_and_therefore_settles() {
        let observed = WatchObservation::decode(true, Some("compacting"));
        assert_eq!(observed, WatchObservation::Status(ClaudeStatus::None));
        assert_eq!(
            decide(observed, true, false),
            WatchStep::Finished(WatchExit::Settled)
        );
    }

    #[test]
    fn an_active_status_keeps_polling_until_the_deadline() {
        for status in [ClaudeStatus::Working, ClaudeStatus::NeedsPermission] {
            let observed = WatchObservation::Status(status);
            assert_eq!(decide(observed, true, false), WatchStep::KeepPolling);
            assert_eq!(
                decide(observed, true, true),
                WatchStep::Finished(WatchExit::TimedOut)
            );
        }
    }

    #[test]
    fn the_startup_window_keeps_polling_rather_than_reporting_never_seen() {
        assert_eq!(
            decide(WatchObservation::SeenNoStatus, false, false),
            WatchStep::KeepPolling
        );
        assert_eq!(
            decide(WatchObservation::SeenNoStatus, false, true),
            WatchStep::Finished(WatchExit::TimedOut)
        );
    }

    #[test]
    fn a_disappearing_id_is_closed_but_an_unknown_one_was_never_seen() {
        assert_eq!(
            decide(WatchObservation::NotSeen, true, false),
            WatchStep::Finished(WatchExit::Settled)
        );
        assert_eq!(
            decide(WatchObservation::NotSeen, false, false),
            WatchStep::Finished(WatchExit::NeverSeen)
        );
    }

    #[test]
    fn a_settled_verdict_beats_an_expired_deadline() {
        // A just-in-time finish is never reported as a timeout, and neither is an unknown id.
        assert_eq!(
            decide(WatchObservation::Status(ClaudeStatus::Done), true, true),
            WatchStep::Finished(WatchExit::Settled)
        );
        assert_eq!(
            decide(WatchObservation::NotSeen, false, true),
            WatchStep::Finished(WatchExit::NeverSeen)
        );
    }

    #[test]
    fn the_block_is_unbounded_unless_a_positive_timeout_asks_otherwise() {
        assert_eq!(block_deadline_nanos(1_000, None), None);
        assert_eq!(block_deadline_nanos(1_000, Some(0)), None);
        assert_eq!(block_deadline_nanos(1_000, Some(-5)), None);
        assert_eq!(block_deadline_nanos(1_000, Some(2)), Some(2_001_000));
    }

    #[test]
    fn an_absurd_timeout_saturates_instead_of_wrapping_into_the_past() {
        let deadline = block_deadline_nanos(u64::MAX - 1, Some(i64::MAX));
        assert_eq!(deadline, Some(u64::MAX));
        // The point of saturating: the deadline is never BEHIND the start, which would time out at once.
        assert!(deadline.is_some_and(|nanos| nanos >= u64::MAX - 1));
    }
}
