//! What a TREE of panes says when their facts are read together, and what a ring keeps.
//!
//! [`pane_facts`](crate::pane_facts) answers what ONE status landing on ONE pane moves. This is the
//! other half of the same store: the four rules that read a WHOLE list — every leaf of a session,
//! every leaf of a tab, every entry of a most-recently-used ring — and answer one thing about it.
//!
//! They arrived here together because they are the same shape and were spelled four different ways.
//! Two are precedence ladders over a column of optional per-leaf facts ([`aggregate_progress`],
//! [`rollup_completion`]); one is a dedupe-to-front-and-cap ([`push`]) that the store had written
//! out IN PLACE at four separate sites, once per element type it happened to be ringing; and one is
//! the walk down a ring that is deliberately never pruned ([`most_recent_survivor`]).
//!
//! ## Nothing here learns an identity
//!
//! A `PaneID` and a `SessionID` are UUIDs the caller owns, and a clip is the user's own text. Not
//! one of these rules is told any of them. [`push`] is handed one ROLE per existing entry and
//! answers [`Slot`]s — where each surviving entry came FROM — and [`most_recent_survivor`] is
//! handed one bool per ring entry and answers a POSITION. The caller does the only thing it can do
//! better: compare its own values, and read its own list back at the places the answer names.
//!
//! That is what let one rule replace four spellings. A ring of `SessionID`s, a ring of `PaneID`s, a
//! ring of catalogue-id strings and a ring of clipboard texts have nothing in common as data and
//! exactly one thing in common as policy, and the policy is all that crossed.

/// One leaf's `OSC 9;4` progress, as the per-pane mirror holds it.
///
/// The CLEAR state — `9;4;0` — is the absence of an indicator rather than a case here, so a leaf
/// with no progress is `None` and a rollup over nothing is `None` too.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    /// `9;4;3` — a busy spinner with no meaningful percent.
    Indeterminate,
    /// `9;4;1;<pct>` — a determinate value, `0..=100`.
    Determinate(u8),
    /// `9;4;2[;<pct>]` — held red at the percent it failed on.
    Error(u8),
}

/// The rolled-up progress over a set of leaves, ERROR-DOMINANT.
///
/// The precedence is a claim about what a person needs to see first, and each rung earns its place:
///
/// - **Any error wins**, at the percent of the FIRST failing leaf. The macOS Dock tile turns red on
///   this, and a red tile is the most urgent thing the app can say about a whole session.
/// - **Else any determinate value wins, at the MAX percent.** A bar fills toward done, so the
///   closest-to-done leaf is the honest reading of "how far along is this session" — a min or a
///   mean would make one slow pane hide the fact that everything else had finished. A determinate
///   leaf at ZERO still wins over a spinner: it is a program that knows its own scale and has not
///   started, which is more information than a spinner, not less.
/// - **Else any spinner**, and otherwise nothing.
///
/// Integer compares throughout. `CLAUDE.md`'s bit-exact float rule is about the video codec's
/// arithmetic; there is no float here to keep exact.
#[must_use]
pub fn aggregate_progress(states: &[Option<Progress>]) -> Option<Progress> {
    let mut error: Option<u8> = None;
    let mut determinate: Option<u8> = None;
    let mut spinner = false;
    for state in states {
        match *state {
            // `or` rather than a replace: the FIRST failing leaf keeps the held percent, so a second
            // failure arriving later does not rewrite the number already on screen.
            Some(Progress::Error(percent)) => error = error.or(Some(percent)),
            Some(Progress::Determinate(percent)) => {
                determinate = Some(determinate.unwrap_or(0).max(percent));
            },
            Some(Progress::Indeterminate) => spinner = true,
            None => {},
        }
    }
    match (error, determinate, spinner) {
        (Some(percent), ..) => Some(Progress::Error(percent)),
        (None, Some(percent), _) => Some(Progress::Determinate(percent)),
        (None, None, true) => Some(Progress::Indeterminate),
        (None, None, false) => None,
    }
}

/// The badge a BACKGROUND pane carries until you look at it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Completion {
    /// The command exited zero, or with no exit code at all — a clean finish.
    Success,
    /// The command exited non-zero.
    Failure,
}

/// The rolled-up completion badge over a set of leaves: a failure if any leaf failed, else a
/// success if any succeeded, else nothing.
///
/// The same dominance argument [`aggregate_progress`] makes, at the badge's own vocabulary — a
/// session with one failing pane among nine clean ones has failed, and a green tick over it would
/// be the surface lying about the one thing worth interrupting for. It returns on the first failure
/// because there is no second question to ask: no later leaf can outrank one.
#[must_use]
pub fn rollup_completion(badges: &[Option<Completion>]) -> Option<Completion> {
    let mut success = false;
    for badge in badges {
        match *badge {
            Some(Completion::Failure) => return Some(Completion::Failure),
            Some(Completion::Success) => success = true,
            None => {},
        }
    }
    success.then_some(Completion::Success)
}

/// What one existing ring entry IS to the push being made.
///
/// The caller assigns these by comparing its own values, which is the one part of the rule that
/// cannot cross: the entries are UUIDs and strings, and the comparison is theirs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Role {
    /// An ordinary entry — it keeps its place, one rung further back.
    #[default]
    Plain,
    /// The entry being pushed, already somewhere in the ring. It leaves that place for the front.
    Selected,
    /// The OUTGOING entry being retained behind the push, already in the ring. It stays where it is
    /// rather than being promoted: it is not what was just chosen, it is only what must not be
    /// lost.
    Previous,
}

/// Where one entry of the pushed ring came FROM.
///
/// Three cases rather than a signed position with two sentinels, because two of them are not places
/// in the caller's list at all and a number pretending otherwise is the mistake this vocabulary
/// removes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Slot {
    /// The entry being pushed. Always the answer's first slot, whether or not the ring already held
    /// it.
    Incoming,
    /// The outgoing entry, SEEDED — the ring did not hold it and now does. Only ever the answer's
    /// second slot.
    Retained,
    /// Keep the caller's existing entry at this position, in the order it already had.
    Kept(u32),
}

/// The one dedupe-to-front-and-cap every ring in the store runs.
///
/// Four sites spelled this out in place, once each, over four element types: the session-retention
/// LRU, the pane visit ring, the palette's recent commands and the clipboard history. Every one of
/// them was `removeAll { $0 == x }` · `insert(x, at: 0)` · trim to a cap, and the fourth was the
/// one that also carried a `previous`.
///
/// `roles` is one entry per existing ring entry, in the ring's own order. `has_previous` says there
/// IS an outgoing entry to retain; when nothing in `roles` is marked [`Role::Previous`], it is
/// seeded in front of the survivors, which is the first-switch-away case — the outgoing session was
/// never itself pushed through this path, so nothing would otherwise have put it in the ring.
///
/// **A `previous` equal to the `selected` is NOT a previous, and the caller says so by passing
/// `has_previous: false`.** Retaining the thing you are promoting is not a second entry: whether
/// the ring already held it or not, both orderings of the original spelling collapse to the plain
/// push, so there is nothing for the flag to express.
///
/// A `cap` of zero answers an empty ring, and a `cap` of one answers the incoming entry alone. The
/// trim takes from the BACK, which is what makes this an LRU rather than a queue: the entry that
/// has gone longest without being pushed is the one that falls off.
#[must_use]
pub fn push(roles: &[Role], has_previous: bool, cap: usize) -> Vec<Slot> {
    let mut out: Vec<Slot> = Vec::with_capacity(roles.len().saturating_add(2));
    out.push(Slot::Incoming);
    if has_previous && !roles.contains(&Role::Previous) {
        out.push(Slot::Retained);
    }
    out.extend(
        roles
            .iter()
            .enumerate()
            .filter(|(_, role)| **role != Role::Selected)
            .map(|(index, _)| Slot::Kept(u32::try_from(index).unwrap_or(u32::MAX))),
    );
    out.truncate(cap);
    out
}

/// The position of the first ring entry that is still there, or [`None`] when none is.
///
/// The ring this walks is deliberately NEVER pruned — a pane that closes simply stops being
/// offered, because every reader intersects with the live set on the way past — so walking over ids
/// nothing can focus any more is the normal case rather than the degenerate one, and the rule is
/// the walk itself. `survives` carries one flag per entry, in the ring's order, because whether an
/// id is still in a tab is a set membership over UUIDs and that is the caller's to answer.
///
/// [`None`] is a real verdict and not a failure: the tree operation's own neighbour rule stands
/// rather than being overridden with a guess.
#[must_use]
pub fn most_recent_survivor(survives: &[bool]) -> Option<usize> {
    survives.iter().position(|alive| *alive)
}

#[cfg(test)]
mod tests {
    use super::{
        Completion, Progress, Role, Slot, aggregate_progress, most_recent_survivor, push, rollup_completion,
    };

    // MARK: aggregate_progress

    #[test]
    fn nothing_rolls_up_to_nothing() {
        assert_eq!(aggregate_progress(&[]), None);
        assert_eq!(aggregate_progress(&[None, None, None]), None);
    }

    #[test]
    fn an_error_dominates_every_other_state() {
        let states = [
            Some(Progress::Determinate(99)),
            Some(Progress::Indeterminate),
            Some(Progress::Error(12)),
            Some(Progress::Determinate(100)),
        ];
        assert_eq!(aggregate_progress(&states), Some(Progress::Error(12)));
    }

    #[test]
    fn the_first_failing_leaf_keeps_the_held_percent() {
        let states = [
            None,
            Some(Progress::Error(30)),
            Some(Progress::Error(70)),
            Some(Progress::Error(0)),
        ];
        assert_eq!(
            aggregate_progress(&states),
            Some(Progress::Error(30)),
            "a later failure must not rewrite the number already on screen"
        );
    }

    #[test]
    fn determinate_rolls_up_to_the_maximum_percent() {
        let states = [
            Some(Progress::Determinate(4)),
            Some(Progress::Determinate(88)),
            Some(Progress::Determinate(37)),
        ];
        assert_eq!(aggregate_progress(&states), Some(Progress::Determinate(88)));
    }

    #[test]
    fn a_determinate_zero_still_outranks_a_spinner() {
        let states = [Some(Progress::Indeterminate), Some(Progress::Determinate(0))];
        assert_eq!(
            aggregate_progress(&states),
            Some(Progress::Determinate(0)),
            "a program that knows its own scale says more than one that does not"
        );
    }

    #[test]
    fn a_spinner_is_the_last_rung_above_nothing() {
        assert_eq!(
            aggregate_progress(&[None, Some(Progress::Indeterminate), None]),
            Some(Progress::Indeterminate)
        );
    }

    #[test]
    fn one_leaf_rolls_up_to_itself() {
        for state in [
            Progress::Indeterminate,
            Progress::Determinate(55),
            Progress::Error(1),
        ] {
            assert_eq!(aggregate_progress(&[Some(state)]), Some(state), "{state:?}");
        }
    }

    // MARK: rollup_completion

    #[test]
    fn no_badge_rolls_up_to_nothing() {
        assert_eq!(rollup_completion(&[]), None);
        assert_eq!(rollup_completion(&[None, None]), None);
    }

    #[test]
    fn a_failure_anywhere_dominates_every_success() {
        let badges = [
            Some(Completion::Success),
            Some(Completion::Success),
            Some(Completion::Failure),
        ];
        assert_eq!(rollup_completion(&badges), Some(Completion::Failure));
        assert_eq!(
            rollup_completion(&[Some(Completion::Failure), Some(Completion::Success)]),
            Some(Completion::Failure),
            "and the order it is found in does not change the answer"
        );
    }

    #[test]
    fn a_success_survives_the_gaps_around_it() {
        let badges = [None, Some(Completion::Success), None];
        assert_eq!(rollup_completion(&badges), Some(Completion::Success));
    }

    // MARK: push

    /// The plain three sites: no `previous`, and an entry already in the ring moves to the front
    /// rather than being duplicated.
    #[test]
    fn a_push_fronts_the_selected_entry_and_keeps_the_rest_in_order() {
        let roles = [Role::Plain, Role::Selected, Role::Plain];
        assert_eq!(push(&roles, false, 8), vec![
            Slot::Incoming,
            Slot::Kept(0),
            Slot::Kept(2)
        ]);
    }

    #[test]
    fn a_first_arrival_is_pushed_in_front_of_everything() {
        let roles = [Role::Plain, Role::Plain];
        assert_eq!(push(&roles, false, 8), vec![
            Slot::Incoming,
            Slot::Kept(0),
            Slot::Kept(1)
        ]);
    }

    #[test]
    fn an_empty_ring_answers_the_incoming_entry_alone() {
        assert_eq!(push(&[], false, 4), vec![Slot::Incoming]);
    }

    /// The ring is a caller's array and a caller's array can hold anything. Every entry marked
    /// selected leaves, not just the first — the spelling this replaced was `removeAll`, and a rule
    /// that removed one occurrence would leave a duplicate behind on exactly the input that already
    /// had one.
    #[test]
    fn every_selected_entry_leaves_not_only_the_first() {
        let roles = [Role::Selected, Role::Plain, Role::Selected];
        assert_eq!(push(&roles, false, 8), vec![Slot::Incoming, Slot::Kept(1)]);
    }

    #[test]
    fn the_cap_trims_from_the_back() {
        let roles = [Role::Plain, Role::Plain, Role::Plain];
        assert_eq!(push(&roles, false, 2), vec![Slot::Incoming, Slot::Kept(0)]);
        assert_eq!(push(&roles, false, 1), vec![Slot::Incoming]);
        assert!(
            push(&roles, false, 0).is_empty(),
            "a ring that keeps nothing keeps nothing, including the push"
        );
    }

    #[test]
    fn a_cap_wider_than_the_ring_trims_nothing() {
        let roles = [Role::Plain];
        assert_eq!(push(&roles, false, 99), vec![Slot::Incoming, Slot::Kept(0)]);
    }

    /// The session-retention case: the outgoing session was never pushed through this path, so the
    /// first switch away has to seed it.
    #[test]
    fn an_absent_previous_is_seeded_behind_the_push() {
        assert_eq!(
            push(&[], true, 2),
            vec![Slot::Incoming, Slot::Retained],
            "A active, switching to B: [B, A]"
        );
    }

    /// A→B→C at cap 2: C is pushed, B is already in the ring so it keeps its place, and A falls
    /// off.
    #[test]
    fn a_previous_already_in_the_ring_keeps_its_place() {
        let roles = [Role::Previous, Role::Plain];
        assert_eq!(
            push(&roles, true, 2),
            vec![Slot::Incoming, Slot::Kept(0)],
            "the previous is not promoted — it is only kept"
        );
    }

    /// Seeding happens in front of the survivors and behind the push, never anywhere else.
    #[test]
    fn a_seeded_previous_is_always_the_second_slot() {
        let roles = [Role::Plain, Role::Selected, Role::Plain];
        assert_eq!(push(&roles, true, 9), vec![
            Slot::Incoming,
            Slot::Retained,
            Slot::Kept(0),
            Slot::Kept(2)
        ]);
    }

    #[test]
    fn a_seeded_previous_is_capped_like_any_other_slot() {
        assert_eq!(push(&[Role::Plain], true, 1), vec![Slot::Incoming]);
        assert_eq!(push(&[Role::Plain], true, 2), vec![
            Slot::Incoming,
            Slot::Retained
        ]);
    }

    /// The collision the caller resolves before it asks: a `previous` that IS the `selected` is no
    /// previous at all, and both spellings of the original agree with the plain push.
    #[test]
    fn a_previous_equal_to_the_selected_is_the_plain_push() {
        let held = [Role::Plain, Role::Selected];
        assert_eq!(push(&held, false, 4), vec![Slot::Incoming, Slot::Kept(0)]);
        let absent = [Role::Plain];
        assert_eq!(push(&absent, false, 4), vec![Slot::Incoming, Slot::Kept(0)]);
    }

    /// The LRU property the whole rule exists for, run as the sequence the store runs it as.
    #[test]
    fn repeated_pushes_evict_the_least_recently_pushed() {
        // A→B: [B, A].
        let after_b = push(&[], true, 2);
        assert_eq!(after_b, vec![Slot::Incoming, Slot::Retained]);
        // B→C, with B (now at position 0) marked previous: [C, B] — A is trimmed.
        let after_c = push(&[Role::Previous, Role::Plain], true, 2);
        assert_eq!(after_c, vec![Slot::Incoming, Slot::Kept(0)]);
    }

    // MARK: most_recent_survivor

    #[test]
    fn the_first_surviving_ring_entry_wins() {
        assert_eq!(most_recent_survivor(&[false, true, true]), Some(1));
        assert_eq!(most_recent_survivor(&[true, true]), Some(0));
    }

    #[test]
    fn dead_ring_entries_are_walked_past() {
        assert_eq!(
            most_recent_survivor(&[false, false, false, true]),
            Some(3),
            "the ring is never pruned, so the walk has to cross ids nothing can focus"
        );
    }

    #[test]
    fn a_ring_with_no_live_survivor_decides_nothing() {
        assert_eq!(most_recent_survivor(&[]), None);
        assert_eq!(most_recent_survivor(&[false, false]), None);
    }
}
