//! The subscriber set of one pane: who holds it, how far each has got, who has fallen too far
//! behind to keep, and how far retention may be released — docs/45 §8.6, docs/59 step 3.
//!
//! Everything here is a NUMBER about a member. The member itself — a sub-channel pair, four relay
//! tasks, two outbound queues and their wakes — stays where the sockets are; what crosses is an
//! `id` the caller assigned and the cursors that decide what the pane does next.
//!
//! ## The three folds
//! - **Retention** releases to the MIN acked cursor, so no member's tail can be dropped by another
//!   member's progress.
//! - **The producer bound** is the MAX sent cursor among members delivered from an OUTBOX. A max,
//!   not a min: one parked phone must never assert the pause while a Studio is still consuming.
//! - **Eviction** takes every member that is not the healthiest AND is further behind than the
//!   caller's byte threshold. Never with one member — a lone subscriber's backpressure is the
//!   replay gate's job — and never the healthiest, so a pane cannot evict its way to empty.
//!
//! The byte threshold itself never appears here: the fold answers WHICH cursors are behind the
//! frontier, the caller prices each against its retained history, and hands back the ids it wants
//! latched. That split is what keeps this module free of the replay buffer.

use std::collections::BTreeMap;

/// One client's place in a pane. `0` is the channel the session was opened for; joiners count up.
pub type SubscriberId = u64;

/// One member's cursors and latches — everything about a subscriber that is a number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct Member {
    /// The highest seq this member has CONFIRMED. Retention releases to the min of these.
    acked: i64,
    /// The highest seq this member's outbox sender has handed to the wire (or died trying).
    sent: i64,
    /// Whether this member is delivered from an outbox rather than inline. Only a member with one
    /// contributes to the producer bound: an inline-delivered member never advances `sent`.
    has_sender: bool,
    /// Whether this member's `.exit` frame has left its sender (or the member died trying).
    exit_delivered: bool,
    /// One-shot latch: already handed to the caller's eviction seam. Eviction is asynchronous by
    /// necessity, and the condition that triggered it stays true until the close lands.
    evicting: bool,
}

/// One member's ack cursor, for the caller to price against its retained history.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    /// Which member.
    pub id: SubscriberId,
    /// The highest seq it has confirmed.
    pub acked: i64,
}

/// One member's un-acked backlog, as the caller's replay history prices it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Priced {
    /// Which member.
    pub id: SubscriberId,
    /// Bytes still retained above its ack cursor.
    pub retained_bytes: u64,
}

/// The subscriber set of one pane, in ascending id order.
///
/// A `BTreeMap` rather than a hash: every read of this set is either a fold over all of it or a
/// broadcast, and a broadcast has to be in a DETERMINISTIC order. The near side used to pay a
/// `keys.sorted()` per broadcast for exactly that; here the order is the container's.
#[derive(Debug)]
pub struct Fanout {
    /// The population. A member leaves by being REMOVED — there is no tombstone, because every
    /// latch that outlives membership (a retired pair, a cancelled task) is about the OBJECT the
    /// caller still holds, not about the set.
    members: BTreeMap<SubscriberId, Member>,
    /// The next id a join will be admitted under.
    next_id: SubscriberId,
}

impl Default for Fanout {
    /// Spelled out rather than derived: a derived `next_id` would be `0`, and `0` is the one id a
    /// mint may never hand out.
    fn default() -> Self {
        Self::new()
    }
}

impl Fanout {
    /// An empty set whose first minted id is `1` — `0` belongs to the channel the session was
    /// opened for, and that member is entered under it explicitly.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            members: BTreeMap::new(),
            next_id: 1,
        }
    }

    /// RESERVES the id a pending join will enter under, before the member exists.
    ///
    /// The caller registers a channel key under this id inside the same critical section, so a link
    /// dropping between the reservation and the join is attributable to the JOINER rather than
    /// falling back to the primary. A reservation the join never uses simply skips an id.
    pub const fn reserve_id(&mut self) -> SubscriberId {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1);
        id
    }

    /// Enters a member under `id`, seeding its ack cursor at `acked`.
    ///
    /// REPLACES any member already at that id, which is what a returning client is: a subscriber is
    /// its channel pair, so a new pair is a new member under the same id rather than a swap
    /// underneath the tasks a departed one owned.
    ///
    /// The seed is the caller's, and it is not zero for a joiner: a joiner is state-transferred a
    /// RENDERED screen, not the history behind it, so its retention cursor must not hold bytes
    /// every other member has already acked.
    pub fn join(&mut self, id: SubscriberId, acked: i64) {
        self.members.insert(id, Member {
            acked,
            ..Member::default()
        });
    }

    /// Drops a member and answers whether the set is now EMPTY.
    ///
    /// Refcounted, deliberately: with two clients on one pane, one closing its lid must not engage
    /// the offline gate the caller reserves for an empty set.
    pub fn leave(&mut self, id: SubscriberId) -> bool {
        self.members.remove(&id);
        self.members.is_empty()
    }

    /// Every member in ascending id order — the deterministic broadcast order.
    #[must_use]
    pub fn ids(&self) -> Vec<SubscriberId> {
        self.members.keys().copied().collect()
    }

    /// How many members hold this pane right now.
    #[must_use]
    pub fn len(&self) -> usize {
        self.members.len()
    }

    /// Whether nobody holds this pane.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.members.is_empty()
    }

    /// Records `id`'s confirmation of `seq` and answers the retention floor over the members that
    /// REMAIN — `None` for an empty set, where there is no laggard left to hold the buffer for.
    ///
    /// An ack from a member that is NOT in the set records nothing: a departed member's control
    /// relay can still deliver one buffered ack, and honouring that cursor would release the tail
    /// of a laggard that is still here.
    pub fn acknowledge(&mut self, id: SubscriberId, seq: i64) -> Option<i64> {
        if let Some(member) = self.members.get_mut(&id) {
            member.acked = seq;
        }
        self.retention_floor()
    }

    /// The lowest ack cursor in the set — how far retention may be released. `None` when empty.
    #[must_use]
    pub fn retention_floor(&self) -> Option<i64> {
        self.members.values().map(|member| member.acked).min()
    }

    /// Marks `id` delivered from an OUTBOX and seeds its delivery frontier at `head`, answering
    /// whether this call is what started it.
    ///
    /// `false` when the member already has a sender or is not in the set, so the caller builds the
    /// task exactly once. The seed is the HEAD rather than zero because everything through it has
    /// already reached this member — inline, for an incumbent the drain was sending to directly; in
    /// the state transfer, for a joiner. A zero would read as "has shipped nothing" and pause the
    /// read loop until the sender re-shipped a history it had already delivered.
    pub fn start_sender(&mut self, id: SubscriberId, head: i64) -> bool {
        let Some(member) = self.members.get_mut(&id) else {
            return false;
        };
        if member.has_sender {
            return false;
        }
        member.has_sender = true;
        member.sent = head;
        true
    }

    /// Drops `id` back off the producer bound, for a member whose sender has been cancelled.
    ///
    /// A frontier frozen by a task nobody will resume would pin the producer for as long as the
    /// member stays in the set, which a teardown that cancels without retiring membership does.
    pub fn clear_sender(&mut self, id: SubscriberId) {
        if let Some(member) = self.members.get_mut(&id) {
            member.has_sender = false;
        }
    }

    /// Records that `id`'s sender put `seq` on the wire (or died trying — a failed send still
    /// retires the member, and a frontier frozen by a dead channel would pin the producer).
    pub fn note_sent(&mut self, id: SubscriberId, seq: i64) {
        if let Some(member) = self.members.get_mut(&id)
            && seq > member.sent
        {
            member.sent = seq;
        }
    }

    /// The delivery frontier: the highest seq the FASTEST outbox-delivered member has shipped.
    ///
    /// `None` unless somebody is delivered from an outbox — a pane on the inline path is already
    /// bounded by its own queue accounting, and an empty set has no consumer to lag behind.
    #[must_use]
    pub fn frontier(&self) -> Option<i64> {
        self.members
            .values()
            .filter(|member| member.has_sender)
            .map(|member| member.sent)
            .max()
    }

    /// Marks `id`'s `.exit` frame delivered.
    pub fn mark_exit_delivered(&mut self, id: SubscriberId) {
        if let Some(member) = self.members.get_mut(&id) {
            member.exit_delivered = true;
        }
    }

    /// Whether `id` is still owed its `.exit`. A member that has LEFT is owed nothing: the exit
    /// task must not hold the teardown open for a pair nobody is draining.
    #[must_use]
    pub fn exit_pending(&self, id: SubscriberId) -> bool {
        self.members.get(&id).is_some_and(|member| !member.exit_delivered)
    }

    /// Every member that is BEHIND the healthiest ack cursor — the eviction ladder's first half.
    ///
    /// Empty for a set of one: a lone subscriber's backpressure is the replay gate's, exactly as it
    /// has always been, and evicting it would turn a slow link into a dropped session. Empty for a
    /// zero `threshold` too, which is what disables eviction — the caller must not pay an
    /// O(retained history) query per member to price a rule that is switched off. The
    /// furthest-ahead member is never a candidate either: if every member were behind the
    /// threshold, nobody is consuming, which is the offline gate's job and not eviction's.
    ///
    /// The caller prices each of these against its retained history and hands them all back to
    /// [`Self::latch_evicting`], which applies the threshold.
    #[must_use]
    pub fn lagging_cursors(&self, threshold: u64) -> Vec<Cursor> {
        if threshold == 0 || self.members.len() < 2 {
            return Vec::new();
        }
        let Some(healthiest) = self.members.values().map(|member| member.acked).max() else {
            return Vec::new();
        };
        self.members
            .iter()
            .filter(|(_, member)| member.acked != healthiest)
            .map(|(&id, member)| {
                Cursor {
                    id,
                    acked: member.acked,
                }
            })
            .collect()
    }

    /// Applies the threshold to what the caller priced, latches every loser that is not already on
    /// its way out, and answers which ones this call claimed — the ids whose eviction it must fire.
    ///
    /// The latch is what stops a concurrent producer and ack path from both deciding to evict the
    /// same member, and what stops every subsequent frame from firing another close for a member
    /// already on its way out. STRICTLY greater: a member exactly at the threshold is buffered for,
    /// not dropped.
    pub fn latch_evicting(&mut self, priced: &[Priced], threshold: u64) -> Vec<SubscriberId> {
        if threshold == 0 {
            return Vec::new();
        }
        let mut claimed = Vec::new();
        for entry in priced.iter().filter(|entry| entry.retained_bytes > threshold) {
            if let Some(member) = self.members.get_mut(&entry.id)
                && !member.evicting
            {
                member.evicting = true;
                claimed.push(entry.id);
            }
        }
        claimed
    }
}

#[cfg(test)]
mod tests {
    use super::{Cursor, Fanout, Priced};

    const fn priced(id: u64, retained_bytes: u64) -> Priced {
        Priced { id, retained_bytes }
    }

    fn seeded(cursors: &[(u64, i64)]) -> Fanout {
        let mut fanout = Fanout::new();
        for &(id, acked) in cursors {
            fanout.join(id, acked);
        }
        fanout
    }

    #[test]
    fn the_first_minted_id_leaves_zero_to_the_channel_the_session_was_opened_for() {
        let mut fanout = Fanout::new();
        assert_eq!(fanout.reserve_id(), 1);
        assert_eq!(fanout.reserve_id(), 2);
        assert!(fanout.is_empty(), "a reservation is not a member");
    }

    #[test]
    fn a_reservation_the_join_never_uses_only_skips_an_id() {
        let mut fanout = Fanout::new();
        let _skipped = fanout.reserve_id();
        let used = fanout.reserve_id();
        fanout.join(used, 0);
        assert_eq!(fanout.ids(), vec![2]);
    }

    #[test]
    fn members_come_back_in_ascending_id_order_whatever_order_they_joined_in() {
        let fanout = seeded(&[(7, 0), (0, 0), (3, 0)]);
        assert_eq!(fanout.ids(), vec![0, 3, 7]);
    }

    #[test]
    fn a_returning_client_replaces_the_member_at_its_id_rather_than_adding_one() {
        let mut fanout = seeded(&[(0, 900)]);
        fanout.start_sender(0, 900);
        fanout.join(0, 0);
        assert_eq!(fanout.len(), 1);
        assert_eq!(fanout.retention_floor(), Some(0), "the replacement starts fresh");
        assert_eq!(fanout.frontier(), None, "and with no sender");
    }

    #[test]
    fn retention_releases_to_the_slowest_member_not_the_fastest() {
        let mut fanout = seeded(&[(0, 400), (1, 90)]);
        assert_eq!(fanout.acknowledge(0, 700), Some(90));
        assert_eq!(fanout.acknowledge(1, 500), Some(500));
    }

    #[test]
    fn an_ack_from_a_member_that_has_left_records_nothing() {
        let mut fanout = seeded(&[(0, 10), (1, 400)]);
        fanout.leave(1);
        assert_eq!(
            fanout.acknowledge(1, 9000),
            Some(10),
            "the laggard still here still holds it"
        );
    }

    #[test]
    fn an_empty_set_has_no_retention_floor() {
        let mut fanout = seeded(&[(0, 10)]);
        assert!(fanout.leave(0));
        assert_eq!(fanout.acknowledge(0, 50), None);
    }

    #[test]
    fn a_leave_is_refcounted_rather_than_a_teardown() {
        let mut fanout = seeded(&[(0, 0), (1, 0)]);
        assert!(!fanout.leave(1), "somebody still holds the pane");
        assert!(fanout.leave(0), "and now nobody does");
    }

    #[test]
    fn only_the_first_start_sender_seeds_the_frontier() {
        let mut fanout = seeded(&[(0, 0)]);
        assert!(fanout.start_sender(0, 120), "this call started it");
        assert!(!fanout.start_sender(0, 999), "and this one found it running");
        assert_eq!(fanout.frontier(), Some(120), "so the second seed was not taken");
    }

    #[test]
    fn a_member_that_is_not_in_the_set_never_starts_a_sender() {
        let mut fanout = Fanout::new();
        assert!(!fanout.start_sender(4, 10));
        assert_eq!(fanout.frontier(), None);
    }

    #[test]
    fn the_producer_bound_follows_the_fastest_member_so_one_parked_phone_cannot_assert_it() {
        let mut fanout = seeded(&[(0, 0), (1, 0)]);
        fanout.start_sender(0, 0);
        fanout.start_sender(1, 0);
        fanout.note_sent(0, 5000);
        fanout.note_sent(1, 12);
        assert_eq!(fanout.frontier(), Some(5000));
    }

    #[test]
    fn an_inline_delivered_member_is_not_on_the_producer_bound_at_all() {
        let mut fanout = seeded(&[(0, 0)]);
        fanout.note_sent(0, 900);
        assert_eq!(fanout.frontier(), None, "no sender, no bound");
    }

    #[test]
    fn a_cancelled_sender_stops_pinning_the_producer_even_while_its_member_stays() {
        let mut fanout = seeded(&[(0, 0)]);
        fanout.start_sender(0, 400);
        fanout.clear_sender(0);
        assert_eq!(fanout.frontier(), None);
        assert_eq!(fanout.len(), 1, "cancelling a task is not leaving the set");
    }

    #[test]
    fn the_frontier_never_goes_backwards() {
        let mut fanout = seeded(&[(0, 0)]);
        fanout.start_sender(0, 0);
        fanout.note_sent(0, 90);
        fanout.note_sent(0, 12);
        assert_eq!(fanout.frontier(), Some(90));
    }

    #[test]
    fn an_exit_is_pending_until_it_is_delivered_and_a_departed_member_is_owed_nothing() {
        let mut fanout = seeded(&[(0, 0), (1, 0)]);
        assert!(fanout.exit_pending(0));
        fanout.mark_exit_delivered(0);
        assert!(!fanout.exit_pending(0));
        fanout.leave(1);
        assert!(!fanout.exit_pending(1), "nobody is draining that pair");
    }

    #[test]
    fn a_lone_subscriber_is_never_a_laggard() {
        let fanout = seeded(&[(0, 0)]);
        assert!(fanout.lagging_cursors(1024).is_empty());
    }

    #[test]
    fn a_zero_threshold_disables_eviction_before_the_caller_prices_anything() {
        let mut fanout = seeded(&[(0, 900), (1, 0)]);
        assert!(fanout.lagging_cursors(0).is_empty());
        assert_eq!(
            fanout.latch_evicting(&[priced(1, u64::MAX)], 0),
            Vec::<u64>::new()
        );
    }

    #[test]
    fn the_healthiest_member_is_never_a_candidate_and_ties_at_it_all_survive() {
        let fanout = seeded(&[(0, 900), (1, 900), (2, 3)]);
        assert_eq!(fanout.lagging_cursors(1024), vec![Cursor { id: 2, acked: 3 }]);
    }

    #[test]
    fn every_member_behind_the_frontier_is_a_candidate_in_id_order() {
        let fanout = seeded(&[(0, 5), (1, 900), (2, 40)]);
        assert_eq!(fanout.lagging_cursors(1024), vec![
            Cursor { id: 0, acked: 5 },
            Cursor { id: 2, acked: 40 }
        ],);
    }

    #[test]
    fn a_member_exactly_at_the_threshold_is_buffered_for_rather_than_dropped() {
        let mut fanout = seeded(&[(0, 900), (1, 0)]);
        assert_eq!(fanout.latch_evicting(&[priced(1, 1024)], 1024), Vec::<u64>::new());
        assert_eq!(fanout.latch_evicting(&[priced(1, 1025)], 1024), vec![1]);
    }

    #[test]
    fn the_latch_is_one_shot_so_a_second_pass_fires_nothing() {
        let mut fanout = seeded(&[(0, 900), (1, 0)]);
        assert_eq!(fanout.latch_evicting(&[priced(1, 9999)], 1024), vec![1]);
        assert_eq!(fanout.latch_evicting(&[priced(1, 9999)], 1024), Vec::<u64>::new());
    }

    #[test]
    fn the_latch_claims_nothing_for_a_member_that_is_not_in_the_set() {
        let mut fanout = seeded(&[(0, 0)]);
        assert_eq!(fanout.latch_evicting(&[priced(9, 9999)], 1024), Vec::<u64>::new());
    }

    #[test]
    fn a_replacement_at_a_latched_id_arrives_unlatched() {
        let mut fanout = seeded(&[(0, 900), (1, 0)]);
        assert_eq!(fanout.latch_evicting(&[priced(1, 9999)], 1024), vec![1]);
        fanout.join(1, 900);
        assert_eq!(
            fanout.latch_evicting(&[priced(1, 9999)], 1024),
            vec![1],
            "a new pair is a new member",
        );
    }
}
