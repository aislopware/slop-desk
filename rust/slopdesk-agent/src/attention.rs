//! Which pane is asking for the human, and which one the user is sent to next.
//!
//! Four questions, one subject, so they are written together: whether a status CHANGE is worth
//! interrupting someone for, which waiting pane is the oldest, where one press of the
//! jump-to-attention chord goes, and which pane the Peek & Reply card answers without going
//! anywhere at all.
//!
//! ## Why the card's selection lives beside the chord's
//!
//! They rank the same panes by the same predicate and differ in one clause — the chord MOVES focus,
//! so it has no reason to prefer where you already are, and the card replies in place, so it does.
//! Written apart, that one clause is the seam a second ordering grows out of, and the card's own
//! "N of M" counter would then be counting a queue the chain does not walk.
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

/// Whether `previous → current` mints one FINISHED TURN — the count each viewer compares its own
/// device-local "seen" against (`pane/completionEpoch`).
///
/// [`is_completion`] plus the hook path: entering `Done` is the authoritative finish and mints at
/// the edge the `Stop` hook announces it, so a host WITH hooks counts the turn once there and the
/// `Done → Idle` decay that follows mints nothing. A host WITHOUT hooks never sees `Done` at all —
/// the screen engine has no such verdict — and counts the same turn at `Working|NeedsPermission →
/// Idle`. One rule, both hosts, never twice for one turn.
///
/// Separate from [`is_completion`] because the two questions differ on exactly one edge: a
/// NOTIFICATION for a hook-driven finish already fired on the `Done` attention edge ([`is_edge`]),
/// so folding the mint in there would interrupt twice for the turn it counts once.
#[must_use]
pub const fn mints_finished_turn(previous: ClaudeStatus, current: ClaudeStatus) -> bool {
    if matches!(current, ClaudeStatus::Done) {
        return !matches!(previous, ClaudeStatus::Done);
    }
    is_completion(previous, current)
}

/// The position of the OLDEST pane needing attention, or `None` when none does.
///
/// `statuses` is the caller's panes in canonical order, so the answer is a position in ITS list
/// rather than an identity this crate would have to carry. Blocked outranks finished wherever it
/// sits — being stuck is more urgent than having finished — and within a bucket the earliest pane
/// wins, which in traversal order is the one that has been waiting longest.
#[must_use]
pub fn oldest_needing_attention(statuses: &[ClaudeStatus]) -> Option<usize> {
    oldest_needing_attention_among(statuses, &[])
}

/// The same ordering with some panes ALREADY ANSWERED, still counted in the caller's positions.
///
/// `answered` is one flag per pane; a short or missing run reads as all-false, because it is the
/// caller's array and a card that offered one pane too many is a better failure than a refusal.
///
/// It exists so the peek card's advance can skip the pane it just replied to. The reason it
/// delegates instead of filtering first is the position: a caller that pre-filtered would get an
/// index into a list it does not hold, and would have to map it back — which is where the ordering
/// would eventually be re-derived and start to disagree with itself.
#[must_use]
pub fn oldest_needing_attention_among(statuses: &[ClaudeStatus], answered: &[bool]) -> Option<usize> {
    let unanswered = |position: &usize| !answered.get(*position).copied().unwrap_or(false);
    let oldest = |wanted: ClaudeStatus| {
        statuses
            .iter()
            .enumerate()
            .filter(|(_, status)| **status == wanted)
            .map(|(position, _)| position)
            .find(unanswered)
    };
    oldest(ClaudeStatus::NeedsPermission).or_else(|| oldest(ClaudeStatus::Done))
}

/// The FOCUSED pane, as the peek selection sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FocusedPane {
    /// What it is doing.
    pub status: ClaudeStatus,
    /// Whether this run of the card has already replied to it.
    pub answered: bool,
}

/// Which pane the peek card answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeekTarget {
    /// The focused pane — which the caller holds, and which need not be in the list it passed.
    Focused,
    /// The pane at this position in the caller's list.
    Pane(usize),
}

/// The pane the Peek & Reply card should answer, or `None` when nothing is waiting.
///
/// This is [`oldest_needing_attention`]'s ordering with ONE clause in front of it: a focused pane
/// that is itself blocked is answered first. The jump chord MOVES focus, so it has no reason to
/// prefer where you already are; the card replies in place, so the pane you are looking at is the
/// one you can answer without reading anything new.
///
/// `answered` drops a pane from BOTH clauses, which is what makes the advance-to-next work: a pane
/// that was just replied to keeps reporting blocked until the host re-reports, so without the
/// exclusion the card would hand back the pane it had only that moment finished with.
///
/// The focused pane is answered as [`PeekTarget::Focused`] rather than as a position, because it
/// need not appear in `statuses` at all — the caller may be looking at a pane the list it built
/// does not include, and a position would have to lie about which one.
#[must_use]
pub fn peek_target(
    focused: Option<FocusedPane>,
    statuses: &[ClaudeStatus],
    answered: &[bool],
) -> Option<PeekTarget> {
    if let Some(pane) = focused
        && !pane.answered
        && matches!(pane.status, ClaudeStatus::NeedsPermission)
    {
        return Some(PeekTarget::Focused);
    }
    oldest_needing_attention_among(statuses, answered).map(PeekTarget::Pane)
}

/// The card's "N of M" triage counter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueuePosition {
    /// Which of the queue this card is on — one past however many were answered, so it reads `M+1`
    /// of `M` on the press that empties it and the card is closing anyway.
    pub position: usize,
    /// How many panes this run of the card set out to answer.
    pub total: usize,
}

/// The counter above the card, or `None` when there is no queue worth counting.
///
/// `answered_count` is how many panes this run has already advanced PAST, and it is passed rather
/// than counted out of `answered` because a pane can be answered and then closed: it left the list,
/// it did not stop having been answered, and a total that shrank under the person would make the
/// card look like it was losing work.
///
/// What still counts as remaining is [`is_attention`] — the SAME predicate
/// [`oldest_needing_attention`] orders by — so the number on the card and the chain it counts can
/// never disagree about which panes are in the queue.
///
/// Under two, there is no queue: one waiting pane is just a waiting pane, and "1 of 1" is noise
/// where the card's calm static caption belongs.
#[must_use]
pub fn peek_queue(
    statuses: &[ClaudeStatus],
    answered: &[bool],
    answered_count: usize,
) -> Option<QueuePosition> {
    let remaining = statuses
        .iter()
        .enumerate()
        .filter(|(position, status)| {
            is_attention(**status) && !answered.get(*position).copied().unwrap_or(false)
        })
        .count();
    let total = answered_count.saturating_add(remaining);
    (total >= 2).then(|| {
        QueuePosition {
            position: answered_count.saturating_add(1),
            total,
        }
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
    use super::{
        FocusedPane, PeekTarget, QueuePosition, Step, is_attention, is_completion, is_edge,
        mints_finished_turn, oldest_needing_attention, peek_queue, peek_target, walk_step,
    };
    use crate::status::ClaudeStatus;

    /// A focused pane in that status, not yet answered.
    const fn looking_at(status: ClaudeStatus) -> FocusedPane {
        FocusedPane {
            status,
            answered: false,
        }
    }

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
    fn a_finished_turn_is_counted_once_on_either_host() {
        // The hook-free host: the screen engine has no `Done`, so the settle IS the finish.
        assert!(mints_finished_turn(ClaudeStatus::Working, ClaudeStatus::Idle));
        assert!(mints_finished_turn(
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::Idle
        ));

        // The hook host: the `Stop` hook's `Done` mints, from anywhere that was not already `Done`.
        assert!(mints_finished_turn(ClaudeStatus::Working, ClaudeStatus::Done));
        assert!(mints_finished_turn(ClaudeStatus::Idle, ClaudeStatus::Done));
        assert!(
            !mints_finished_turn(ClaudeStatus::Done, ClaudeStatus::Idle),
            "the decay of an announced finish is the same turn ending twice"
        );

        assert!(
            !mints_finished_turn(ClaudeStatus::None, ClaudeStatus::Idle),
            "an agent appearing is not a turn ending"
        );
        for status in ClaudeStatus::ALL {
            assert!(
                !mints_finished_turn(status, status),
                "a re-assertion is not a transition: {status:?}"
            );
        }
        assert!(!mints_finished_turn(ClaudeStatus::Idle, ClaudeStatus::Working));
        assert!(!mints_finished_turn(
            ClaudeStatus::Working,
            ClaudeStatus::NeedsPermission
        ));
        assert!(!mints_finished_turn(ClaudeStatus::Done, ClaudeStatus::None));
        assert!(!mints_finished_turn(ClaudeStatus::Idle, ClaudeStatus::None));
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

    /// The one clause that separates the card from the chord: being looked at wins.
    #[test]
    fn a_focused_blocked_pane_is_answered_before_an_older_one() {
        let panes = [ClaudeStatus::NeedsPermission, ClaudeStatus::NeedsPermission];
        assert_eq!(
            peek_target(Some(looking_at(ClaudeStatus::NeedsPermission)), &panes, &[]),
            Some(PeekTarget::Focused)
        );
    }

    #[test]
    fn a_focused_pane_that_is_not_blocked_does_not_pre_empt_the_order() {
        let panes = [ClaudeStatus::NeedsPermission, ClaudeStatus::Working];
        for busy in [ClaudeStatus::Working, ClaudeStatus::Idle, ClaudeStatus::None] {
            assert_eq!(
                peek_target(Some(looking_at(busy)), &panes, &[]),
                Some(PeekTarget::Pane(0)),
                "{busy:?}"
            );
        }
        // A finished focused pane does NOT jump the queue either: only blocked does, because only
        // blocked is holding something up.
        assert_eq!(
            peek_target(Some(looking_at(ClaudeStatus::Done)), &panes, &[]),
            Some(PeekTarget::Pane(0))
        );
    }

    #[test]
    fn with_nothing_focused_the_card_is_the_chord_order() {
        let panes = [
            ClaudeStatus::Done,
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::Done,
        ];
        assert_eq!(peek_target(None, &panes, &[]), Some(PeekTarget::Pane(1)));
        assert_eq!(
            peek_target(None, &panes, &[]).map(|target| {
                match target {
                    PeekTarget::Pane(position) => Some(position),
                    PeekTarget::Focused => None,
                }
            }),
            Some(oldest_needing_attention(&panes))
        );
    }

    #[test]
    fn nothing_waiting_is_no_target() {
        let panes = [ClaudeStatus::Working, ClaudeStatus::Idle];
        assert_eq!(
            peek_target(Some(looking_at(ClaudeStatus::Working)), &panes, &[]),
            None
        );
        assert_eq!(peek_target(None, &[], &[]), None);
    }

    /// The advance drops the answered pane from BOTH clauses, or the card hands back the pane it
    /// has only just finished with — it is still reporting blocked until the host re-reports.
    #[test]
    fn an_answered_pane_leaves_both_the_focused_clause_and_the_candidates() {
        let panes = [ClaudeStatus::NeedsPermission, ClaudeStatus::NeedsPermission];
        let focused = Some(FocusedPane {
            status: ClaudeStatus::NeedsPermission,
            answered: true,
        });
        assert_eq!(
            peek_target(focused, &panes, &[true, false]),
            Some(PeekTarget::Pane(1))
        );
        assert_eq!(peek_target(focused, &panes, &[true, true]), None);
    }

    #[test]
    fn the_counter_advances_while_the_total_holds_still() {
        let panes = [
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::Done,
        ];
        assert_eq!(
            peek_queue(&panes, &[], 0),
            Some(QueuePosition {
                position: 1,
                total: 3
            })
        );
        assert_eq!(
            peek_queue(&panes, &[true, false, false], 1),
            Some(QueuePosition {
                position: 2,
                total: 3
            })
        );
        // All answered: one PAST the total, which is the press that closes the card.
        assert_eq!(
            peek_queue(&panes, &[true, true, true], 3),
            Some(QueuePosition {
                position: 4,
                total: 3
            })
        );
    }

    /// The counter's predicate is the chain's, so a finished pane counts exactly like a blocked one
    /// and a working pane never inflates the total.
    #[test]
    fn the_counter_counts_what_the_chain_walks() {
        let panes = [
            ClaudeStatus::NeedsPermission,
            ClaudeStatus::Working,
            ClaudeStatus::Idle,
            ClaudeStatus::Done,
            ClaudeStatus::None,
        ];
        assert_eq!(peek_queue(&panes, &[], 0).map(|queue| queue.total), Some(2));
    }

    #[test]
    fn a_queue_of_one_is_not_a_queue() {
        assert_eq!(peek_queue(&[ClaudeStatus::NeedsPermission], &[], 0), None);
        assert_eq!(peek_queue(&[], &[], 0), None);
        assert_eq!(
            peek_queue(&[ClaudeStatus::Working], &[], 1),
            None,
            "one answered and nothing left is still not a queue"
        );
    }

    /// A short or absent `answered` run reads as all-false rather than refusing: it is the caller's
    /// array, and offering one pane too many beats offering none.
    #[test]
    fn a_ragged_answered_run_reads_as_unanswered() {
        let panes = [ClaudeStatus::NeedsPermission, ClaudeStatus::NeedsPermission];
        assert_eq!(peek_target(None, &panes, &[true]), Some(PeekTarget::Pane(1)));
        assert_eq!(peek_queue(&panes, &[true], 1).map(|queue| queue.total), Some(2));
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
