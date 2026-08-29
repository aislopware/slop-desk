//! What a pane's supervision FACTS become when one status lands on them.
//!
//! `slopdesk_agent::attention` already answers the three EDGE questions — is this an attention
//! state, is this transition worth interrupting somebody for, did a hook-less agent just finish.
//! What it does not answer is the one the store actually asks: given all three plus the coalescing
//! memory, WHICH of the pane's seven facts move. That composition was the last decision left in
//! `WorkspaceStore`, spelled as thirty lines of interleaved `if` and mutation, and it is the shape
//! a rule drifts in — every writer that reached the map had to re-derive the same ladder.
//!
//! ## A verdict, not a mutation
//!
//! [`commit`] answers what to write and writes nothing. The facts stay on the far side as the
//! caller's own observable dictionaries, because a projection an interface binds to has to live
//! where the binding is; the LADDER lives here, and the caller applies it without a branch of its
//! own. That is the whole port: the decision crossed, the storage did not.
//!
//! ## The two clocks stay outside
//!
//! Nothing here reads a clock. `commit` says WHETHER a stamp moves and the caller supplies the
//! instant, exactly as `slopdesk_agent`'s detector takes its `now` as a parameter — a rule that
//! reads the wall clock cannot be tested at a chosen moment, and half of this ladder is about
//! ordering two stamps.

use slopdesk_agent::attention;
use slopdesk_agent::badge::{self, Attention, TabBadge};
use slopdesk_agent::status::ClaudeStatus;

/// Which of a pane's facts one committed status change moves.
///
/// Every field is an INSTRUCTION to the caller's projection, not a fact about the pane: the caller
/// applies them in field order and asks nothing else. Absent from the struct are the three writes
/// that follow from the change ITSELF rather than from its shape — the parked notification is
/// always dropped, the attention stamp is always refreshed, and the focus-dwell watch is always
/// re-evaluated — because a flag that is never false is a flag a reader has to check anyway.
#[expect(
    clippy::struct_excessive_bools,
    reason = "this IS the list of writes; a bitset would hide that each one is an independent instruction \
              the caller applies verbatim, and an enum would claim an exclusivity only the first two have"
)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Commit {
    /// Latch the new status as the one last notified for, and PARK a notification for it.
    ///
    /// Mutually exclusive with [`rearm_notified`](Self::rearm_notified): a transition either earns
    /// a ring or releases the memory that suppresses the next one.
    pub notify_edge: bool,
    /// Forget what was last notified — the pane left the attention bucket, so its next entry is
    /// news again.
    pub rearm_notified: bool,
    /// Park a notification for a HOOK-LESS finish (an agent that settled to idle without ever
    /// minting a done). Independent of [`notify_edge`](Self::notify_edge): the two edges read
    /// different histories, and idle is not itself an attention state.
    pub schedule_completion: bool,
    /// Stamp the completion instant, arm the flash decay, and bump this client's own completion
    /// counter — a turn just ended.
    pub stamp_completed: bool,
    /// Mark the pane's current finish READ — the agent moved on, so an unread marker for the
    /// previous turn is stale news.
    pub mark_seen: bool,
    /// Anchor the turn clock at the caller's instant. `false` means RETIRE it: the pane left
    /// `Working`, and an anchor outliving its turn would print an elapsed time that never stops.
    pub stamp_working: bool,
}

/// The ladder one `set status` runs, or [`None`] when the status did not actually change.
///
/// `last_notified` is the coalescing memory — the state a notification was last raised FOR, which
/// is not the same as the previous status: `done → working → done` re-enters an announced state and
/// must stay quiet, and only a memory can tell that from a first arrival.
///
/// `quiet` is the host's own qualification that a transition is BOOKKEEPING (today only the
/// `/compact` boundary). It vetoes both rings and nothing else — the dots, the stamps and the
/// rollups all still move, because the pane really did change state. It deliberately does NOT veto
/// [`rearm_notified`](Commit::rearm_notified): a quiet transition is still a real one, and leaving
/// the memory latched would swallow the pane's next genuine block.
#[must_use]
pub fn commit(
    previous: ClaudeStatus,
    last_notified: ClaudeStatus,
    next: ClaudeStatus,
    quiet: bool,
) -> Option<Commit> {
    if previous == next {
        return None;
    }
    let notify_edge = !quiet && attention::is_edge(last_notified, next);
    Some(Commit {
        notify_edge,
        rearm_notified: !notify_edge
            && matches!(
                next,
                ClaudeStatus::Idle | ClaudeStatus::Working | ClaudeStatus::None
            ),
        schedule_completion: !quiet && attention::is_completion(previous, next),
        stamp_completed: matches!(next, ClaudeStatus::Done),
        mark_seen: matches!(next, ClaudeStatus::Working | ClaudeStatus::NeedsPermission),
        stamp_working: matches!(next, ClaudeStatus::Working),
    })
}

/// Which document the mirror holds, relative to the one this device's seen-map is filed under.
///
/// The three UUIDs the caller compares to answer this — the live epoch, the store's own seed, the
/// epoch the map was filed under — never cross. They are identities the caller owns, and the
/// question the rule below asks is not about which document it is, only about whether it is a real
/// one and whether it is the same one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentIdentity {
    /// No document at all, or the store's own seed — which is the QUESTION a client sends, never a
    /// host's answer, so nothing may be filed under it.
    Unanswered,
    /// The very document the map is already filed under.
    Adopted,
    /// A real host document, and not the one on file.
    New,
}

/// What to do with this device's seen-map when the mirror's document identity is read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SeenDocument {
    /// Nothing. Either there is no answer to act on, or the map is already filed correctly.
    Ignore,
    /// File the map under this document, keeping what is in it.
    Adopt,
    /// EMPTY the map first, then file it: these are another document's pane ids, and a counter
    /// recorded against one document says nothing about the same-numbered pane in another.
    ClearAndAdopt,
}

/// Decides what a read of the mirror's document identity does to the seen-map.
///
/// `has_stored` is what separates the two adopting arms, and it is the whole reason this is a rule
/// rather than an assignment: a FIRST adopt is a map restored from disk meeting the document it was
/// written for, and clearing there would throw away every acknowledgement the user made in the
/// previous run. A LATER one is a genuine document switch, where keeping them would carry stale
/// counters onto ids that merely happen to collide.
#[must_use]
pub const fn seen_document(identity: DocumentIdentity, has_stored: bool) -> SeenDocument {
    match identity {
        DocumentIdentity::Unanswered | DocumentIdentity::Adopted => SeenDocument::Ignore,
        DocumentIdentity::New if has_stored => SeenDocument::ClearAndAdopt,
        DocumentIdentity::New => SeenDocument::Adopt,
    }
}

/// What one pane's unread-finish marker should become.
///
/// The marker is a COMPARISON, not a latch: the host publishes a monotone counter per pane and
/// holds no per-client acknowledgement, so each device decides for itself by comparing that counter
/// against what it has recorded as seen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unseen {
    /// Not unread, and nothing to record. Either nothing has ever finished here, or the recorded
    /// value already matches.
    Clear,
    /// Not unread, and RECORD it: the pane is on screen, and a finish you are looking at is a
    /// finish you have seen.
    SeenThenClear,
    /// Unread — mark it.
    Mark,
}

/// Decides pane's unread-finish marker from the live counter, what this device recorded, and
/// whether the pane is on screen.
///
/// Two clauses earn their comments:
///
/// - **A zero counter records NOTHING.** Every pane reads zero until the document arrives, and
///   writing that down would erase a restored map before the channel had said which document this
///   is.
/// - **Inequality, not "greater than".** A restarted daemon counts from zero again, so a recorded
///   value stranded ABOVE the live counter is the one way this can go permanently quiet.
#[must_use]
pub const fn unseen_done(epoch: u32, seen: Option<u32>, is_visible: bool) -> Unseen {
    if epoch == 0 {
        return Unseen::Clear;
    }
    if is_visible {
        return Unseen::SeenThenClear;
    }
    match seen {
        Some(recorded) if recorded == epoch => Unseen::Clear,
        _ => Unseen::Mark,
    }
}

/// Whether an unbroken watch of `watched` seconds has earned the finish-marker acknowledge.
///
/// Ordered compare rather than a bare `<`, per the repo's NaN-faithful convention, and it settles
/// once the watch REACHES the window rather than after it — a window is how long you have to look,
/// not how long you have to look plus one tick.
#[must_use]
pub fn settle_due(watched: f64, window: f64) -> bool {
    !watched.lt(&window)
}

/// One pane in the unseen-attention queue, as the order rule needs it.
///
/// `since` crosses as a flag plus a value rather than a sentinel: the absent case is REAL here — a
/// manual badge override carries no age evidence at all — and a NaN standing in for it would sort
/// by whatever the comparison happened to do with a NaN.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Waiting {
    /// The pane's resolved, gated badge — the same vocabulary the sidebar renders.
    pub badge: TabBadge,
    /// When the pane entered attention, when that is known.
    pub since: Option<f64>,
}

/// The urgency rank a badge sorts at: a waiting question, then a failure, then an unread finish.
///
/// [`Attention::ALL`]'s own order, read through [`badge::attention`] rather than re-listed — a
/// second nine-case ladder here would be the drift pair the one-implementation rule exists for. A
/// badge with no attention role ranks last; none reaches the queue, and a total order needs a tail.
fn rank(badge: TabBadge) -> usize {
    badge::attention(badge).map_or(Attention::ALL.len(), |role| {
        Attention::ALL
            .into_iter()
            .position(|candidate| candidate == role)
            .unwrap_or(Attention::ALL.len())
    })
}

/// The order the unseen-attention queue is walked in, as POSITIONS into `entries`.
///
/// Rank first, then longest-waiting first, then the caller's own traversal order as the tie. The
/// tie is load-bearing and is why this answers positions rather than sorting in place: the caller's
/// traversal is session → tab → pre-order DFS, and two panes that entered attention in the same
/// instant have to come back in it rather than in whatever a sort did with equal keys.
///
/// A dated entry outranks an undated one at the same rank — age is evidence, and an entry with none
/// cannot claim to have waited longer than one that can prove it.
#[must_use]
pub fn attention_order(entries: &[Waiting]) -> Vec<u32> {
    let mut order: Vec<u32> = (0..entries.len())
        .map(|index| u32::try_from(index).unwrap_or(u32::MAX))
        .collect();
    order.sort_by(|left, right| {
        let (Some(a), Some(b)) = (entries.get(*left as usize), entries.get(*right as usize)) else {
            return left.cmp(right);
        };
        rank(a.badge)
            .cmp(&rank(b.badge))
            .then_with(|| {
                match (a.since, b.since) {
                    (Some(x), Some(y)) => x.total_cmp(&y),
                    (Some(_), None) => core::cmp::Ordering::Less,
                    (None, Some(_)) => core::cmp::Ordering::Greater,
                    (None, None) => core::cmp::Ordering::Equal,
                }
            })
            .then_with(|| left.cmp(right))
    });
    order
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::*;

    const NONE: ClaudeStatus = ClaudeStatus::None;
    const IDLE: ClaudeStatus = ClaudeStatus::Idle;
    const WORKING: ClaudeStatus = ClaudeStatus::Working;
    const DONE: ClaudeStatus = ClaudeStatus::Done;
    const BLOCKED: ClaudeStatus = ClaudeStatus::NeedsPermission;

    #[test]
    fn an_unchanged_status_commits_nothing() {
        for status in ClaudeStatus::ALL {
            assert_eq!(commit(status, NONE, status, false), None, "{status:?}");
        }
    }

    #[test]
    fn a_first_block_rings_and_a_flap_back_into_it_does_not() {
        let first = commit(WORKING, NONE, BLOCKED, false).expect("changed");
        assert!(first.notify_edge);
        // The memory now holds `BLOCKED`. Leaving and re-entering is the same news twice.
        let away = commit(BLOCKED, BLOCKED, WORKING, false).expect("changed");
        assert!(!away.notify_edge && away.rearm_notified);
        let again = commit(WORKING, BLOCKED, BLOCKED, false).expect("changed");
        assert!(!again.notify_edge, "re-entering an announced state is quiet");
    }

    #[test]
    fn leaving_the_attention_bucket_rearms_and_entering_it_does_not() {
        for next in [IDLE, WORKING, NONE] {
            let out = commit(DONE, DONE, next, false).expect("changed");
            assert!(out.rearm_notified, "{next:?}");
        }
        for next in [DONE, BLOCKED] {
            let out = commit(WORKING, NONE, next, false).expect("changed");
            assert!(!out.rearm_notified && out.notify_edge, "{next:?}");
        }
    }

    #[test]
    fn a_quiet_transition_moves_every_stamp_but_rings_for_nothing() {
        let out = commit(WORKING, NONE, DONE, true).expect("changed");
        assert!(!out.notify_edge && !out.schedule_completion);
        assert!(out.stamp_completed, "the dot and the stamps are not the ring");
        // A quiet transition still releases the memory when it leaves the bucket.
        let leaving = commit(BLOCKED, BLOCKED, IDLE, true).expect("changed");
        assert!(leaving.rearm_notified);
    }

    #[test]
    fn a_hookless_finish_is_scheduled_and_a_done_decay_is_not() {
        assert!(
            commit(WORKING, NONE, IDLE, false)
                .expect("changed")
                .schedule_completion
        );
        assert!(
            !commit(DONE, DONE, IDLE, false)
                .expect("changed")
                .schedule_completion,
            "the decay of an announced finish is not a second finish"
        );
        assert!(
            !commit(NONE, NONE, IDLE, false)
                .expect("changed")
                .schedule_completion,
            "presence appearing is not a turn ending"
        );
    }

    #[test]
    fn the_turn_clock_anchors_only_while_working() {
        for next in ClaudeStatus::ALL {
            let Some(out) = commit(DONE, NONE, next, false) else {
                continue;
            };
            assert_eq!(out.stamp_working, next == WORKING, "{next:?}");
        }
    }

    #[test]
    fn moving_on_marks_the_previous_finish_read() {
        for next in [WORKING, BLOCKED] {
            assert!(commit(DONE, NONE, next, false).expect("changed").mark_seen);
        }
        for next in [IDLE, NONE, DONE] {
            let Some(out) = commit(WORKING, NONE, next, false) else {
                continue;
            };
            assert!(!out.mark_seen, "{next:?}");
        }
    }

    #[test]
    fn a_first_adopt_keeps_the_restored_map_and_a_switch_empties_it() {
        use super::{DocumentIdentity, SeenDocument, seen_document};
        // The store's own seed is the question, so nothing may be filed under it.
        assert_eq!(
            seen_document(DocumentIdentity::Unanswered, false),
            SeenDocument::Ignore
        );
        assert_eq!(
            seen_document(DocumentIdentity::Unanswered, true),
            SeenDocument::Ignore
        );
        // Already filed correctly — a re-read of the same document is not an event.
        assert_eq!(
            seen_document(DocumentIdentity::Adopted, true),
            SeenDocument::Ignore
        );
        // A map restored from disk meeting the document it was written for keeps every
        // acknowledgement the previous run made.
        assert_eq!(seen_document(DocumentIdentity::New, false), SeenDocument::Adopt);
        // A genuine switch does not: those counters were recorded against other panes.
        assert_eq!(
            seen_document(DocumentIdentity::New, true),
            SeenDocument::ClearAndAdopt
        );
    }
    #[test]
    fn a_zero_counter_is_clear_and_records_nothing() {
        assert_eq!(unseen_done(0, None, false), Unseen::Clear);
        assert_eq!(unseen_done(0, Some(4), true), Unseen::Clear);
    }

    #[test]
    fn a_visible_finish_is_a_seen_finish() {
        assert_eq!(unseen_done(3, None, true), Unseen::SeenThenClear);
    }

    #[test]
    fn a_recorded_counter_clears_and_any_mismatch_marks() {
        assert_eq!(unseen_done(3, Some(3), false), Unseen::Clear);
        assert_eq!(unseen_done(3, Some(2), false), Unseen::Mark);
        assert_eq!(
            unseen_done(1, Some(9), false),
            Unseen::Mark,
            "a restarted daemon counts from zero; stranded-above must not go quiet"
        );
        assert_eq!(unseen_done(3, None, false), Unseen::Mark);
    }

    #[test]
    fn a_watch_settles_when_it_reaches_the_window() {
        assert!(!settle_due(1.9, 2.0));
        assert!(settle_due(2.0, 2.0));
        assert!(settle_due(2.1, 2.0));
    }

    #[test]
    fn the_queue_is_blocked_first_then_oldest_then_traversal() {
        let entries = [
            Waiting {
                badge: TabBadge::Finished,
                since: Some(1.0),
            },
            Waiting {
                badge: TabBadge::AwaitingInput,
                since: Some(9.0),
            },
            Waiting {
                badge: TabBadge::Error,
                since: Some(5.0),
            },
            Waiting {
                badge: TabBadge::AwaitingInput,
                since: Some(2.0),
            },
        ];
        assert_eq!(attention_order(&entries), vec![3, 1, 2, 0]);
    }

    #[test]
    fn a_dated_entry_outranks_an_undated_one_at_the_same_rank() {
        let entries = [
            Waiting {
                badge: TabBadge::AwaitingInput,
                since: None,
            },
            Waiting {
                badge: TabBadge::AwaitingInput,
                since: Some(99.0),
            },
        ];
        assert_eq!(attention_order(&entries), vec![1, 0]);
    }

    #[test]
    fn equal_keys_come_back_in_traversal_order() {
        let entries = [
            Waiting {
                badge: TabBadge::Finished,
                since: None,
            },
            Waiting {
                badge: TabBadge::Finished,
                since: None,
            },
            Waiting {
                badge: TabBadge::Finished,
                since: None,
            },
        ];
        assert_eq!(attention_order(&entries), vec![0, 1, 2]);
    }

    #[test]
    fn an_empty_queue_has_an_empty_order() {
        assert!(attention_order(&[]).is_empty());
    }

    #[test]
    fn a_busy_badge_ranks_behind_every_waiting_one() {
        let entries = [
            Waiting {
                badge: TabBadge::Running,
                since: Some(0.0),
            },
            Waiting {
                badge: TabBadge::Finished,
                since: Some(100.0),
            },
        ];
        assert_eq!(attention_order(&entries), vec![1, 0]);
    }
}
