//! Which pane is asking for the human, and which one the user is sent to next.
//!
//! Three questions, one subject, so they are written together: whether a status CHANGE is worth
//! interrupting someone for, which waiting pane is the oldest, and where one press of the
//! jump-to-attention chord goes.
//!
//! ## Edges, not levels
//!
//! A notification fires on the TRANSITION into an attention state, never on being in one. The
//! caller compares against the last state it notified for, not the last state it saw, so
//! `done → working → done` interrupts once: a flap that re-enters a state it never really left is
//! the same event twice, and a level test would fire on every poll.
//!
//! ## Two ways to finish
//!
//! An agent with a Stop hook mints [`ClaudeStatus::Done`] and that is the finish. One without ever
//! only settles back to [`ClaudeStatus::Idle`], so LEAVING an active state for idle is the same
//! event for it — that is [`is_completion`]. `Done → Idle` is not: it is the decay of a finish
//! already announced, and firing there would interrupt twice for one turn.

use crate::status::ClaudeStatus;

/// Whether `status` is an ATTENTION state — waiting on a human, or finished and unseen.
///
/// The LEVEL predicate the ring and the tab glow read, with no history in it: blocked is the most
/// urgent thing a pane can be, and a finished turn is the thing a user came back to look for.
#[must_use]
pub const fn is_attention(status: ClaudeStatus) -> bool {
    matches!(status, ClaudeStatus::NeedsPermission | ClaudeStatus::Done)
}

/// Whether `previous → current` is an attention EDGE worth a notification.
///
/// The state must be an attention state AND a change: `previous` is what the caller last notified
/// for, so re-entering the state it is already announcing is not news.
#[must_use]
pub const fn is_edge(previous: ClaudeStatus, current: ClaudeStatus) -> bool {
    !matches!(
        (previous, current),
        (ClaudeStatus::NeedsPermission, ClaudeStatus::NeedsPermission)
            | (ClaudeStatus::Done, ClaudeStatus::Done)
    ) && is_attention(current)
}

/// Whether `previous → current` is a HOOK-LESS completion: an agent that left an active state and
/// settled to plain idle without ever minting a `Done`.
///
/// `Done → Idle` is the decay of an announced finish, and `None → Idle` is presence appearing —
/// neither is a turn ending.
#[must_use]
pub const fn is_completion(previous: ClaudeStatus, current: ClaudeStatus) -> bool {
    matches!(current, ClaudeStatus::Idle)
        && matches!(previous, ClaudeStatus::Working | ClaudeStatus::NeedsPermission)
}

/// The position of the OLDEST pane needing attention, or `None` when none does.
///
/// `statuses` is the caller's panes in canonical order, so the answer is a position in ITS list
/// rather than an identity this crate would have to carry. Blocked outranks finished wherever it
/// sits — being stuck is more urgent than having finished — and within a bucket the earliest pane
/// wins, which in traversal order is the one that has been waiting longest.
#[must_use]
pub fn oldest_needing_attention(statuses: &[ClaudeStatus]) -> Option<usize> {
    let blocked = statuses
        .iter()
        .position(|status| matches!(status, ClaudeStatus::NeedsPermission));
    blocked.or_else(|| {
        statuses
            .iter()
            .position(|status| matches!(status, ClaudeStatus::Done))
    })
}

/// What one press of the jump-to-attention chord does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Step onto the queue entry at this position.
    Advance(usize),
    /// The queue's unvisited entries are exhausted: go back where the walk started.
    PopHome,
    /// Exhausted with nowhere to go back to — the walk never started, or its origin is gone.
    PopNowhere,
}

/// One press of the walk: the next unvisited pane, else home.
///
/// `visited` is one flag per queue entry, in the caller's queue order. Termination is the VISITED
/// SET, not an empty queue: a still-blocked pane re-enters the queue the moment focus leaves it, so
/// a walk that only asked "is the queue empty" would oscillate between the two panes it just left
/// forever.
#[must_use]
pub fn walk_step(visited: &[bool], origin_is_live: bool) -> Step {
    visited.iter().position(|seen| !seen).map_or(
        if origin_is_live {
            Step::PopHome
        } else {
            Step::PopNowhere
        },
        Step::Advance,
    )
}

#[cfg(test)]
mod tests {
    use super::{Step, is_attention, is_completion, is_edge, oldest_needing_attention, walk_step};
    use crate::status::ClaudeStatus;

    #[test]
    fn only_blocked_and_finished_are_attention() {
        for status in ClaudeStatus::ALL {
            assert_eq!(
                is_attention(status),
                matches!(status, ClaudeStatus::NeedsPermission | ClaudeStatus::Done),
                "{status:?}"
            );
        }
    }

    #[test]
    fn an_edge_is_an_attention_state_that_was_not_already_announced() {
        assert!(is_edge(ClaudeStatus::Working, ClaudeStatus::Done));
        assert!(is_edge(ClaudeStatus::Done, ClaudeStatus::NeedsPermission));
        assert!(
            !is_edge(ClaudeStatus::Done, ClaudeStatus::Done),
            "the same finish twice is one finish"
        );
        for status in ClaudeStatus::ALL {
            assert!(!is_edge(status, ClaudeStatus::Working), "in-flight is not news");
            assert!(!is_edge(status, ClaudeStatus::Idle));
            assert!(!is_edge(status, ClaudeStatus::None));
        }
    }

    #[test]
    fn a_hook_less_finish_is_leaving_an_active_state_for_idle() {
        assert!(is_completion(ClaudeStatus::Working, ClaudeStatus::Idle));
        assert!(is_completion(ClaudeStatus::NeedsPermission, ClaudeStatus::Idle));
        assert!(
            !is_completion(ClaudeStatus::Done, ClaudeStatus::Idle),
            "an announced finish decaying is not a second finish"
        );
        assert!(
            !is_completion(ClaudeStatus::None, ClaudeStatus::Idle),
            "presence appearing is not a finish"
        );
        assert!(!is_completion(ClaudeStatus::Working, ClaudeStatus::Done));
    }

    #[test]
    fn blocked_outranks_finished_wherever_it_sits() {
        let panes = [
            ClaudeStatus::Idle,
            ClaudeStatus::Done,
            ClaudeStatus::Working,
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::NeedsPermission,
        ];
        assert_eq!(
            oldest_needing_attention(&panes),
            Some(3),
            "blocked first, then oldest"
        );
        assert_eq!(
            oldest_needing_attention(&panes[..3]),
            Some(1),
            "with nothing blocked, the oldest finish"
        );
        assert_eq!(oldest_needing_attention(&[ClaudeStatus::Working]), None);
        assert_eq!(oldest_needing_attention(&[]), None);
    }

    #[test]
    fn the_walk_steps_to_the_first_unvisited_then_goes_home() {
        assert_eq!(walk_step(&[true, false, false], true), Step::Advance(1));
        assert_eq!(walk_step(&[true, true], true), Step::PopHome);
        assert_eq!(walk_step(&[true, true], false), Step::PopNowhere);
        assert_eq!(
            walk_step(&[], true),
            Step::PopHome,
            "a walk with nothing to step onto is already exhausted"
        );
    }
}
