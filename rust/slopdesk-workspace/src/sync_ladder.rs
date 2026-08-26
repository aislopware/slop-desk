//! One subscriber's document-sync ladder: what the host may send it next, and against which base.
//!
//! The HOST end of `channelClass 1` (docs/45 §5.5) is a mosh SSP: every frame after the first is a
//! diff computed against the state that subscriber last ACKED, never against the last one SENT.
//! Because a diff assigns rather than mutates, `apply(d, apply(d, s)) == apply(d, s)` holds by
//! construction — duplicates and reorders are no-ops with no extra machinery — and a client four
//! hours offline costs exactly ONE diff, bounded by the SIZE of the tree rather than the DURATION
//! of its absence.
//!
//! Almost none of that is I/O, and none of it is a payload. What is HERE is the whole decision
//! half: whether an offer may ship at all, whether it ships as a snapshot or a diff, which state
//! the diff declares as its base, and which retained states stop being worth keeping. The bytes
//! stay on the near side, indexed by the SLOT this ladder mints — the ladder reads lengths, kinds,
//! epochs and state numbers and never a cell of the document.
//!
//! ## The five rules, and what each one costs when it is wrong
//!
//! **An UNKNOWN ack means snapshot.** An ack naming a state no longer retained (or never sent) is
//! not a base — it is an absence. The tempting fall-through is "prune nothing and carry on", and it
//! is a silent corruption bug: the next diff would declare `baseStateNum` equal to a state the
//! client does not hold, the client would apply it cleanly onto a DIFFERENT base, and the two trees
//! diverge permanently with no error anywhere and no retransmit path on either side to notice.
//! [`SyncLadder::apply_pending_ack`] therefore sets `needs_snapshot`, because a snapshot is
//! self-contained and cannot be based wrong. It clears `outstanding` UNCONDITIONALLY on that path —
//! the client has spoken, so nothing is in flight as far as it is concerned — while the known path
//! clears it only when the ack names the frame actually in flight. That asymmetry is load-bearing:
//! an unknown ack unblocks a snapshot, that snapshot becomes outstanding, and a LATER ack for an
//! older retained state must not then declare the newer frame delivered.
//!
//! **An empty diff is not sent.** Nothing changed since the acked base, so the frame would carry no
//! information and still cost a wire frame, a wake and an ack round-trip on every client — on every
//! no-op mutation, forever. An idle host must be silent. The suppression itself lives on the near
//! side (only it holds the two states to compare), and this ladder makes it free: suppressing is
//! simply not calling [`SyncLadder::commit`], so nothing was minted, nothing became outstanding and
//! nothing was retained.
//!
//! **The retention window is four deep.** Sent-but-unacked states are kept so an ack can become the
//! next diff's base. Past four, an ack falls back to a snapshot, which is always correct — so the
//! window trades a bounded amount of host memory for the common case and never for correctness.
//! Four is what the Swift original retained and the number is per SUBSCRIBER, so an unbounded
//! window would make host memory O(clients × history) with a sleeping phone able to grow it without
//! limit.
//!
//! **A presence clock only ever moves forward.** Presence is newest-wins with no merge, so an
//! update whose clock is not strictly newer is REFUSED. Accepting an equal or older one lets a
//! client that reconnected with a stale clock resurrect a view it has since left, and because the
//! roster is a full replace with no correction path, everyone else then looks at the wrong pane
//! until that client happens to move again.
//!
//! **Before any snapshot has shipped, presence and intent results ride the all-zero epoch.**
//! [`SyncLadder::loose_epoch`] is exactly `sentEpoch ?? WireMessage.newSessionID`. Kinds 2 and 3
//! are epoch-INDEPENDENT — the client's apply rules never check the epoch for them — so the
//! sentinel is honest, where fabricating a UUID would be a value the client could mistake for a
//! real epoch and start rejecting the real one against.
//!
//! ## Why a plan and a commit are two calls
//!
//! Between deciding and sending, the near side computes a diff and `await`s a channel write, and
//! `NSLock` is unavailable across a suspension. So [`SyncLadder::plan`] answers what to build, the
//! caller builds and sends it, and [`SyncLadder::commit`] records what actually went out. Both of
//! the ways a send can end in nothing — an empty diff, a dead link — are then the SAME thing: no
//! commit, no mutation.
//!
//! One mutation deliberately happens in `plan` rather than `commit`: an epoch change drops the base
//! and the window and latches `needs_snapshot` BEFORE the `.reset` frame is on the wire. That is
//! the order the reset exists to enforce — no stale delta may be accepted after it — and the only
//! event that can intervene is a send failure, which closes the subscriber, after which no call is
//! ever made on this ladder again. So the early mutation is unobservable.
//!
//! ## Why HOLD does not consume the offer
//!
//! [`Plan::Hold`] is the answer while a frame is outstanding, and it mutates NOTHING. The near side
//! peeks its depth-1 pending slot rather than taking it for exactly this reason: an offer taken and
//! then declined would be dropped on the floor with no retry trigger anywhere — the wake that
//! carried it is already spent, the send queue is depth-1 and coalescing rather than a queue, and
//! neither end has a retransmit path. The client would sit on a stale document until some unrelated
//! event happened to wake the drain. Holding without consuming is what makes the freshest state
//! coalesce into the same slot and ship as ONE diff when the ack lands — which is also what keeps
//! every diff's declared base equal to what the client actually holds.
//!
//! ## Slots, and the two invariants over them
//!
//! A slot is a QUEUE COORDINATE, not an identity, so it is minted here (docs/59 §4) and the near
//! side keeps a map from it to the `HostWorkspaceState` bytes. Every call that drops a state
//! answers which slots stopped being reachable, and the near side deletes exactly those — a slot
//! never dropped is a leaked document, and one dropped early is a diff with no base.
//!
//! * **The base slot is never also in the window.** Promotion removes the entry it promotes, so a
//!   released list can never name the slot the caller is about to read.
//! * **At most [`MAX_RELEASED`] slots stop being reachable in one call**, which is the window plus
//!   the base — the widest single change, a resubscribe that matches nothing. The caller lends that
//!   many and the write always fits, so no door here retries.

/// How many sent-but-unacked states one subscriber retains.
///
/// Past this an ack falls back to a snapshot, which is always correct — see the module note.
pub const RETAINED_SENT_STATES: usize = 4;

/// The most slots any single call can stop needing: the whole window plus the base.
pub const MAX_RELEASED: usize = RETAINED_SENT_STATES + 1;

/// The slot that names no payload at all — the EMPTY document, which every ladder starts against
/// and every reset returns to.
pub const NO_SLOT: u32 = u32::MAX;

/// One sent-but-unacked state: what the client would be acking, and where its bytes are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Retained {
    state_num: i64,
    slot: u32,
}

/// The slots one call stopped needing, as a fixed list.
///
/// Fixed rather than a `Vec` because [`MAX_RELEASED`] bounds it by construction, and a heap
/// allocation per document frame is exactly the cost the projection exists to remove.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Released {
    slots: [u32; MAX_RELEASED],
    len: usize,
}

impl Released {
    /// The slots, oldest first. The caller drops the payload each one names.
    #[must_use]
    pub fn slots(&self) -> &[u32] {
        self.slots.get(..self.len).unwrap_or_default()
    }

    /// How many slots were released.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether this call freed nothing.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Records one slot. Silently full-stops past [`MAX_RELEASED`], which the invariant above says
    /// cannot happen — dropping the record is still better than trapping a network-facing path.
    fn push(&mut self, slot: u32) {
        if let Some(cell) = self.slots.get_mut(self.len) {
            *cell = slot;
            self.len += 1;
        }
    }
}

/// What one document offer may become.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plan {
    /// A frame is already in flight. Nothing was changed and the offer must stay PENDING — see the
    /// module note on why the near side peeks rather than takes.
    Hold,
    /// Build and send this, then [`SyncLadder::commit`] the state number if it went out.
    Send(Frame),
}

/// The frame [`SyncLadder::plan`] asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    /// Send a `reset` (kind 4) FIRST, because the epoch changed: a different document with an
    /// unrelated `stateNum` sequence, whose deltas must never be accepted against the old one.
    pub reset_first: bool,
    /// Send a snapshot (kind 0) rather than a diff (kind 1). A snapshot is self-contained and
    /// therefore epoch-independent, so a post-restart client converges in ONE frame after a reset.
    pub snapshot: bool,
    /// The `baseStateNum` a diff declares. `0` for a snapshot.
    pub base_state_num: i64,
    /// Where the state the diff is computed FROM lives. [`NO_SLOT`] for a snapshot, and also for a
    /// diff against the empty document — which cannot happen, because an empty base forces a
    /// snapshot.
    pub base_slot: u32,
    /// Slots that stopped being reachable in this call — non-empty only when `reset_first` is set.
    pub released: Released,
}

/// What one [`SyncLadder::commit`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Commit {
    /// The slot minted for the state just sent. The caller files the bytes under it.
    pub slot: u32,
    /// Slots that fell out of the window: a re-sent state number replacing itself, or the oldest
    /// entry once the window is full.
    pub released: Released,
}

/// One client's presence: what it says it is looking at, and how it wants to be counted.
///
/// Also the shape the roster projection comes back in — see [`SyncLadder::roster_view`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Presence {
    /// The client's own monotone clock. Newest strictly wins.
    pub presence_clock: i64,
    /// The tab it is looking at, all-zero for none.
    pub viewing_tab_id: [u8; 16],
    /// The pane it is looking at, all-zero for none.
    pub viewing_pane_id: [u8; 16],
    /// Its viewport width in cells, `0` when it claims none.
    pub cols: u16,
    /// Its viewport height in cells, `0` when it claims none.
    pub rows: u16,
    /// Whether it wants to be counted in the size fold.
    pub contributes_size: bool,
    /// Whether it follows focus. Carried so nothing is silently dropped, but the ROSTER reads the
    /// subscribe's value — see [`SyncLadder::roster_view`].
    pub follows_focus: bool,
}

/// The retention window: sent-but-unacked states, oldest first, at most [`RETAINED_SENT_STATES`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Window {
    entries: [Retained; RETAINED_SENT_STATES],
    len: usize,
}

impl Window {
    const EMPTY: Retained = Retained {
        state_num: 0,
        slot: NO_SLOT,
    };

    const fn new() -> Self {
        Self {
            entries: [Self::EMPTY; RETAINED_SENT_STATES],
            len: 0,
        }
    }

    /// The retained state with this exact number, if it is still held.
    fn find(&self, state_num: i64) -> Option<Retained> {
        self.entries
            .iter()
            .take(self.len)
            .copied()
            .find(|entry| entry.state_num == state_num)
    }

    /// Drops every entry at or below `state_num`. `promoted` names the one whose payload the caller
    /// is KEEPING as the new base: it leaves the window without being released.
    fn drop_through(&mut self, state_num: i64, promoted: u32, released: &mut Released) {
        let mut read = 0_usize;
        let mut write = 0_usize;
        while read < self.len {
            let Some(entry) = self.entries.get(read).copied() else {
                break;
            };
            read += 1;
            if entry.state_num > state_num {
                if let Some(cell) = self.entries.get_mut(write) {
                    *cell = entry;
                    write += 1;
                }
            } else if entry.slot != promoted {
                released.push(entry.slot);
            }
        }
        self.len = write;
    }

    /// Empties the window, keeping `promoted` unreleased for the same reason as
    /// [`Window::drop_through`]. [`NO_SLOT`] promotes nothing.
    fn clear(&mut self, promoted: u32, released: &mut Released) {
        let mut read = 0_usize;
        while read < self.len {
            if let Some(entry) = self.entries.get(read).copied()
                && entry.slot != promoted
            {
                released.push(entry.slot);
            }
            read += 1;
        }
        self.len = 0;
    }

    /// Appends a freshly sent state, replacing any entry with the same number and evicting the
    /// oldest once the window is full.
    fn push(&mut self, entry: Retained, released: &mut Released) {
        let mut read = 0_usize;
        let mut write = 0_usize;
        // A resent state number replaces itself: the client can only hold one payload per number,
        // and keeping both would leave the older one unreachable and un-released.
        while read < self.len {
            let Some(held) = self.entries.get(read).copied() else {
                break;
            };
            read += 1;
            if held.state_num == entry.state_num {
                released.push(held.slot);
            } else if let Some(cell) = self.entries.get_mut(write) {
                *cell = held;
                write += 1;
            }
        }
        self.len = write;
        if self.len == RETAINED_SENT_STATES {
            self.evict_oldest(released);
        }
        if let Some(cell) = self.entries.get_mut(self.len) {
            *cell = entry;
            self.len += 1;
        }
    }

    fn evict_oldest(&mut self, released: &mut Released) {
        if let Some(oldest) = self.entries.first().copied() {
            released.push(oldest.slot);
        }
        let mut index = 1_usize;
        while index < self.len {
            let Some(next) = self.entries.get(index).copied() else {
                break;
            };
            if let Some(cell) = self.entries.get_mut(index - 1) {
                *cell = next;
            }
            index += 1;
        }
        self.len -= 1;
    }
}

/// One subscriber's document-sync ladder.
///
/// `Copy`, like every other all-scalar value in this crate: the one thing holding the LIVE state is
/// the FFI handle the near side owns, and every mutation here runs through a `&mut` borrow of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyncLadder {
    window: Window,
    next_slot: u32,
    /// Where the state this ladder ASSUMES the client holds lives. `None` is the empty document,
    /// which is what a fresh subscriber and a just-reset one both hold.
    base_slot: Option<u32>,
    acked_state_num: i64,
    sent_epoch: Option<[u8; 16]>,
    /// The `stateNum` of the frame in flight; `None` when the client is caught up.
    outstanding: Option<i64>,
    /// The highest ack seen since the last drain — see [`SyncLadder::note_ack`].
    pending_ack: Option<i64>,
    presence: Option<Presence>,
    needs_snapshot: bool,
    contributes_size: bool,
    follows_focus: bool,
}

impl SyncLadder {
    /// A subscriber that holds nothing, has been sent nothing, and is owed a snapshot.
    ///
    /// The two flags are the SUBSCRIBE's — the connection's standing claim, which a later presence
    /// update may override for the size fold but not for focus.
    #[must_use]
    pub const fn new(contributes_size: bool, follows_focus: bool) -> Self {
        Self {
            window: Window::new(),
            next_slot: 0,
            base_slot: None,
            acked_state_num: 0,
            sent_epoch: None,
            outstanding: None,
            pending_ack: None,
            presence: None,
            needs_snapshot: true,
            contributes_size,
            follows_focus,
        }
    }

    /// Records an ack. HIGHEST wins: an out-of-order or duplicated ack can only ever move the base
    /// forward, so keeping the maximum is both correct and the cheapest coalescing there is.
    pub const fn note_ack(&mut self, state_num: i64) {
        self.pending_ack = Some(match self.pending_ack {
            Some(held) if held >= state_num => held,
            _ => state_num,
        });
    }

    /// Whether an ack is waiting to be applied.
    #[must_use]
    pub const fn has_pending_ack(&self) -> bool {
        self.pending_ack.is_some()
    }

    /// Applies the highest ack seen since the last call, and answers which slots that freed.
    ///
    /// Both halves of the unknown-ack rule are here — see the module note.
    pub fn apply_pending_ack(&mut self) -> Released {
        let mut released = Released::default();
        let Some(state_num) = self.pending_ack.take() else {
            return released;
        };
        let Some(retained) = self.window.find(state_num) else {
            // Do NOT guess a base. A re-ack of the base we already hold is not news, so it does not
            // force a snapshot; anything else is an absence, and a snapshot is the self-contained
            // answer.
            if state_num != self.acked_state_num {
                self.needs_snapshot = true;
            }
            self.outstanding = None;
            return released;
        };
        self.window.drop_through(state_num, retained.slot, &mut released);
        self.adopt_base(Some(retained.slot), state_num, &mut released);
        if self.outstanding == Some(state_num) {
            self.outstanding = None;
        }
        released
    }

    /// A repeat `subscribe` IS the resync verb — there is deliberately no separate "resend".
    ///
    /// The client says exactly where it is, and that supersedes any guess based on a frame it may
    /// or may not have applied, so whatever was in flight is abandoned. Its claim is honoured only
    /// when the EPOCH matches and the exact state is still retained; reconnect, a missed frame and
    /// a four-hour absence all land on the one snapshot path.
    pub fn resubscribe(
        &mut self,
        known_epoch: [u8; 16],
        known_state_num: i64,
        contributes_size: bool,
        follows_focus: bool,
    ) -> Released {
        self.contributes_size = contributes_size;
        self.follows_focus = follows_focus;
        self.outstanding = None;
        let mut released = Released::default();
        let claimed = if self.sent_epoch == Some(known_epoch) && known_state_num != 0 {
            self.window.find(known_state_num)
        } else {
            None
        };
        if let Some(retained) = claimed {
            self.window.clear(retained.slot, &mut released);
            self.adopt_base(Some(retained.slot), retained.state_num, &mut released);
            self.needs_snapshot = false;
            return released;
        }
        self.window.clear(NO_SLOT, &mut released);
        self.adopt_base(None, 0, &mut released);
        self.needs_snapshot = true;
        released
    }

    /// What to do with the freshest document offer, which the caller has NOT consumed.
    ///
    /// Answers [`Plan::Hold`] without touching anything while a frame is outstanding.
    #[must_use]
    pub fn plan(&mut self, epoch: [u8; 16]) -> Plan {
        if self.outstanding.is_some() {
            return Plan::Hold;
        }
        let mut released = Released::default();
        let reset_first = self.sent_epoch.is_some_and(|sent| sent != epoch);
        if reset_first {
            self.window.clear(NO_SLOT, &mut released);
            self.adopt_base(None, 0, &mut released);
            self.needs_snapshot = true;
        }
        self.sent_epoch = Some(epoch);
        // The third clause can never fire on its own — an acked state number always has a base
        // beside it — and is written out because a diff against a base the client does not hold
        // applies CLEANLY and corrupts silently, which is the one failure this ladder exists to
        // make impossible.
        let snapshot = self.needs_snapshot || self.acked_state_num == 0 || self.base_slot.is_none();
        Plan::Send(Frame {
            reset_first,
            snapshot,
            base_state_num: if snapshot { 0 } else { self.acked_state_num },
            base_slot: if snapshot {
                NO_SLOT
            } else {
                self.base_slot.unwrap_or(NO_SLOT)
            },
            released,
        })
    }

    /// Records that the planned frame went out, and mints the slot its state is filed under.
    ///
    /// Called ONLY after a successful send: an empty diff and a dead link both end in no commit,
    /// which is what leaves the ladder exactly where it was.
    pub fn commit(&mut self, state_num: i64) -> Commit {
        let mut released = Released::default();
        self.needs_snapshot = false;
        self.outstanding = Some(state_num);
        let slot = self.mint_slot();
        self.window.push(Retained { state_num, slot }, &mut released);
        Commit { slot, released }
    }

    /// The epoch to stamp on a frame that does not depend on one — presence and intent results.
    ///
    /// All-zero before any document has shipped; see the module note.
    #[must_use]
    pub fn loose_epoch(&self) -> [u8; 16] {
        self.sent_epoch.unwrap_or([0; 16])
    }

    /// Records the client's view.
    ///
    /// Returns `false` when the update is IGNORED because its clock is not strictly newer. Presence
    /// is per-CONNECTION and dies with the link, so the connection itself is the TTL — a timer
    /// could only ever fire after the subscriber was already gone.
    pub fn note_presence(&mut self, update: Presence) -> bool {
        if self
            .presence
            .is_some_and(|current| update.presence_clock <= current.presence_clock)
        {
            return false;
        }
        self.presence = Some(update);
        true
    }

    /// This subscriber as the host describes it to everyone else.
    ///
    /// The view and the viewport come from the last accepted presence update, and are all-zero
    /// while it has sent none — a silent subscriber views nothing rather than views something
    /// invented. The presence update's `contributes_size` WINS over the subscribe's: willingness to
    /// be counted in the size fold is a live property of the client's window, not of its
    /// connection. `follows_focus` is deliberately the SUBSCRIBE's, because it says what kind of
    /// client this is rather than what it is doing this second.
    #[must_use]
    pub fn roster_view(&self) -> Presence {
        let seen = self.presence.unwrap_or_default();
        Presence {
            contributes_size: self
                .presence
                .map_or(self.contributes_size, |presence| presence.contributes_size),
            follows_focus: self.follows_focus,
            ..seen
        }
    }

    /// The `stateNum` of the frame in flight, `None` when the client is caught up.
    #[must_use]
    pub const fn outstanding(&self) -> Option<i64> {
        self.outstanding
    }

    /// Whether the next frame must be a snapshot.
    #[must_use]
    pub const fn needs_snapshot(&self) -> bool {
        self.needs_snapshot
    }

    /// The state number this ladder assumes the client holds.
    #[must_use]
    pub const fn acked_state_num(&self) -> i64 {
        self.acked_state_num
    }

    /// Moves the assumed-acked base, releasing the payload the old one named.
    ///
    /// The `!=` guard is belt and braces for the invariant that the base is never also in the
    /// window: releasing the slot we are about to adopt would hand the caller a diff with no base.
    fn adopt_base(&mut self, slot: Option<u32>, state_num: i64, released: &mut Released) {
        if let Some(old) = self.base_slot.take()
            && Some(old) != slot
        {
            released.push(old);
        }
        self.base_slot = slot;
        self.acked_state_num = state_num;
    }

    /// The next slot coordinate. Wraps, skipping [`NO_SLOT`] — at most [`MAX_RELEASED`] slots are
    /// live at once, so a number reused after four billion frames cannot collide with one of them.
    const fn mint_slot(&mut self) -> u32 {
        let slot = self.next_slot;
        self.next_slot = self.next_slot.wrapping_add(1);
        if self.next_slot == NO_SLOT {
            self.next_slot = 0;
        }
        slot
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "an unreachable branch in a test IS the report — a silent `return` would pass"
    )]
    use super::{MAX_RELEASED, NO_SLOT, Plan, Presence, RETAINED_SENT_STATES, SyncLadder};

    const EPOCH_A: [u8; 16] = [1; 16];
    const EPOCH_B: [u8; 16] = [2; 16];
    const TAB: [u8; 16] = [7; 16];
    const PANE: [u8; 16] = [8; 16];

    /// Plans and commits one state, answering the frame that was planned and the slot minted.
    fn ship(ladder: &mut SyncLadder, epoch: [u8; 16], state_num: i64) -> (bool, u32) {
        let Plan::Send(frame) = ladder.plan(epoch) else {
            panic!("the ladder held a frame the test expected to ship");
        };
        let commit = ladder.commit(state_num);
        (frame.snapshot, commit.slot)
    }

    /// Ported from `testFirstDeliveryIsASelfContainedSnapshot`.
    #[test]
    fn the_first_frame_is_a_snapshot_against_nothing() {
        let mut ladder = SyncLadder::new(true, false);
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("a fresh subscriber holds nothing back");
        };
        assert!(frame.snapshot);
        assert!(!frame.reset_first);
        assert_eq!(frame.base_state_num, 0);
        assert_eq!(frame.base_slot, NO_SLOT);
        assert!(frame.released.is_empty());
        assert_eq!(ladder.outstanding(), None);
        let commit = ladder.commit(1);
        assert_eq!(ladder.outstanding(), Some(1));
        assert!(commit.released.is_empty());
    }

    /// Ported from `testAChangeAfterTheAckArrivesAsADiffFromTheAckedBase`.
    #[test]
    fn an_acked_state_becomes_the_next_diff_base() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, slot) = ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        let released = ladder.apply_pending_ack();
        assert!(
            released.is_empty(),
            "the acked state is PROMOTED to the base, not dropped"
        );
        assert_eq!(ladder.outstanding(), None);
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("nothing is outstanding");
        };
        assert!(!frame.snapshot);
        assert_eq!(frame.base_state_num, 1);
        assert_eq!(frame.base_slot, slot);
    }

    /// Ported from `testUpdatesArrivingBeforeTheAckCoalesceIntoOneDiff` and
    /// `testAnUpdateArrivingMidSendIsNotLost`, which together are the whole reason the near side
    /// PEEKS its pending slot rather than taking it.
    #[test]
    fn an_outstanding_frame_holds_the_offer_without_consuming_it() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        let before = ladder;
        assert_eq!(ladder.plan(EPOCH_A), Plan::Hold);
        assert_eq!(
            ladder, before,
            "a HOLD must change nothing, or the offer it declined is lost"
        );
        // The ack releases the hold, and the very next plan ships the coalesced state.
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        assert!(matches!(ladder.plan(EPOCH_A), Plan::Send(_)));
    }

    /// Ported from `testAnAckForAnUnretainedStateFallsBackToASnapshot`.
    #[test]
    fn an_unknown_ack_forces_a_snapshot_and_clears_the_flight() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        ship(&mut ladder, EPOCH_A, 2);
        ladder.note_ack(99);
        let released = ladder.apply_pending_ack();
        assert!(
            released.is_empty(),
            "an ack we cannot base on prunes nothing — the window may still be acked later"
        );
        assert!(ladder.needs_snapshot());
        assert_eq!(
            ladder.outstanding(),
            None,
            "the client has spoken, so nothing is in flight as far as it knows"
        );
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("the unknown ack cleared the flight");
        };
        assert!(frame.snapshot);
    }

    /// A re-ack of the base the ladder already holds is not news and must not cost a snapshot.
    #[test]
    fn a_duplicate_ack_of_the_current_base_changes_nothing() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        assert!(!ladder.needs_snapshot());
        ladder.note_ack(1);
        let released = ladder.apply_pending_ack();
        assert!(released.is_empty());
        assert!(
            !ladder.needs_snapshot(),
            "the client is telling us where it already was"
        );
        assert_eq!(ladder.acked_state_num(), 1);
    }

    /// The asymmetry in how `outstanding` is cleared. An unknown ack unblocks a snapshot; a LATER
    /// ack for an older retained state must not then declare that snapshot delivered.
    #[test]
    fn a_stale_known_ack_does_not_clear_a_newer_frame_in_flight() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 5);
        ladder.note_ack(3);
        ladder.apply_pending_ack();
        assert_eq!(ladder.outstanding(), None);
        ship(&mut ladder, EPOCH_A, 6);
        assert_eq!(ladder.outstanding(), Some(6));
        ladder.note_ack(5);
        ladder.apply_pending_ack();
        assert_eq!(
            ladder.outstanding(),
            Some(6),
            "6 is still on the wire — an ack for 5 says nothing about it"
        );
        assert_eq!(ladder.acked_state_num(), 5);
    }

    #[test]
    fn the_highest_ack_wins_however_they_arrive() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, first) = ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        ship(&mut ladder, EPOCH_A, 2);
        ladder.note_ack(2);
        ladder.note_ack(1);
        let released = ladder.apply_pending_ack();
        assert_eq!(ladder.acked_state_num(), 2);
        assert_eq!(
            released.slots(),
            [first],
            "the old base is the only thing that stopped being reachable"
        );
    }

    /// Ported from `testResubscribeAtARetainedStateResumesWithADiff`.
    #[test]
    fn a_resubscribe_at_a_retained_state_diffs_against_it() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, first) = ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        let (_, second) = ship(&mut ladder, EPOCH_A, 2);
        let released = ladder.resubscribe(EPOCH_A, 2, true, false);
        assert_eq!(
            released.slots(),
            [first],
            "the promoted state is kept; the base it replaces is freed"
        );
        assert_eq!(ladder.outstanding(), None, "a resync abandons the flight");
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("the resync cleared the flight");
        };
        assert!(!frame.snapshot);
        assert_eq!(frame.base_state_num, 2);
        assert_eq!(frame.base_slot, second);
    }

    /// Ported from `testResubscribeFromZeroReSnapshots`.
    #[test]
    fn a_resubscribe_from_zero_re_snapshots() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, first) = ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        let (_, second) = ship(&mut ladder, EPOCH_A, 2);
        let released = ladder.resubscribe(EPOCH_A, 0, true, false);
        assert_eq!(released.slots(), [second, first]);
        assert!(ladder.needs_snapshot());
        assert_eq!(ladder.acked_state_num(), 0);
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("the resync cleared the flight");
        };
        assert!(frame.snapshot);
        assert_eq!(frame.base_slot, NO_SLOT);
    }

    /// Ported from `testResubscribeWithAForeignEpochReSnapshots`.
    #[test]
    fn a_resubscribe_naming_another_epoch_re_snapshots() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        let released = ladder.resubscribe(EPOCH_B, 1, true, false);
        assert_eq!(released.len(), 1, "the state it claims is not ours to base on");
        assert!(ladder.needs_snapshot());
    }

    /// A subscriber that has been sent nothing has no epoch, so no claim of theirs can match — the
    /// Swift original's `request.knownEpoch == sentEpoch` against a `nil` `sentEpoch`.
    #[test]
    fn a_resubscribe_before_anything_shipped_matches_nothing() {
        let mut ladder = SyncLadder::new(true, false);
        let released = ladder.resubscribe([0; 16], 4, true, false);
        assert!(released.is_empty());
        assert!(ladder.needs_snapshot());
    }

    /// Ported from `testAStateBeyondTheRetentionWindowFallsBackToASnapshot`. The window only ever
    /// grows past one entry down the unknown-ack path, because that is the one thing that unblocks
    /// a send without pruning — so that is how a test has to reach the overflow at all.
    #[test]
    fn a_state_that_fell_out_of_the_window_can_only_be_answered_with_a_snapshot() {
        const _: () = assert!(RETAINED_SENT_STATES == 4, "the loop below sends one past it");
        let mut ladder = SyncLadder::new(true, false);
        for state_num in 1..=5_i64 {
            ship(&mut ladder, EPOCH_A, state_num);
            // An ack for a state we never sent: it clears the flight without pruning anything.
            ladder.note_ack(-1);
            ladder.apply_pending_ack();
        }
        // The fifth push evicted the first, so acking 1 is now an ack we cannot base on.
        ladder.note_ack(1);
        assert!(ladder.apply_pending_ack().is_empty());
        assert!(ladder.needs_snapshot());
        // The second-oldest IS still retained, so acking it promotes an honest base — but the
        // latched snapshot survives it, exactly as the Swift original left it: only a frame that
        // actually went out clears the flag, and until one does, a snapshot is the safe answer.
        ladder.note_ack(2);
        assert!(
            ladder.apply_pending_ack().is_empty(),
            "nothing below 2 is left to free, and 2 itself is promoted"
        );
        assert_eq!(ladder.acked_state_num(), 2);
        assert!(ladder.needs_snapshot());
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("the acks cleared the flight");
        };
        assert!(frame.snapshot);
    }

    /// The eviction itself, isolated: the fifth commit releases the first slot.
    #[test]
    fn the_fifth_retained_state_releases_the_first() {
        let mut ladder = SyncLadder::new(true, false);
        let mut first = NO_SLOT;
        for state_num in 1..=4_i64 {
            let commit = {
                assert!(matches!(ladder.plan(EPOCH_A), Plan::Send(_)));
                ladder.commit(state_num)
            };
            if state_num == 1 {
                first = commit.slot;
            }
            assert!(commit.released.is_empty());
            ladder.note_ack(-1);
            ladder.apply_pending_ack();
        }
        assert!(matches!(ladder.plan(EPOCH_A), Plan::Send(_)));
        let commit = ladder.commit(5);
        assert_eq!(commit.released.slots(), [first]);
    }

    /// A resent state number replaces itself rather than sitting in the window twice with one of
    /// the two payloads unreachable.
    #[test]
    fn resending_a_state_number_frees_the_payload_it_replaces() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, first) = ship(&mut ladder, EPOCH_A, 7);
        ladder.note_ack(-1);
        ladder.apply_pending_ack();
        let commit = {
            assert!(matches!(ladder.plan(EPOCH_A), Plan::Send(_)));
            ladder.commit(7)
        };
        assert_eq!(commit.released.slots(), [first]);
        assert_ne!(commit.slot, first);
    }

    /// Ported from `testANewEpochSendsResetThenConvergesInOneSnapshot`.
    #[test]
    fn a_new_epoch_resets_first_then_snapshots_once() {
        let mut ladder = SyncLadder::new(true, false);
        let (_, first) = ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        let Plan::Send(frame) = ladder.plan(EPOCH_B) else {
            panic!("nothing is outstanding");
        };
        assert!(frame.reset_first);
        assert!(frame.snapshot);
        assert_eq!(frame.base_state_num, 0);
        assert_eq!(frame.released.slots(), [first]);
        ladder.commit(1);
        // The epoch is now B, so the next frame is an ordinary one.
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        let Plan::Send(next) = ladder.plan(EPOCH_B) else {
            panic!("the ack cleared the flight");
        };
        assert!(!next.reset_first);
        assert!(!next.snapshot);
    }

    /// The widest single release there is: an epoch change mid-window drops the base AND all four
    /// retained states, which is where [`MAX_RELEASED`] comes from.
    #[test]
    fn an_epoch_change_mid_window_releases_the_base_and_the_whole_window() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        for state_num in 2..=5_i64 {
            ship(&mut ladder, EPOCH_A, state_num);
            ladder.note_ack(-1);
            ladder.apply_pending_ack();
        }
        let Plan::Send(frame) = ladder.plan(EPOCH_B) else {
            panic!("the unknown acks cleared the flight");
        };
        assert!(frame.reset_first);
        assert_eq!(frame.released.len(), MAX_RELEASED);
        assert!(ladder.needs_snapshot());
        assert_eq!(ladder.acked_state_num(), 0);
    }

    /// The near side suppresses an empty diff by simply not committing, and that must leave the
    /// ladder able to ship the very next offer. The far half of
    /// `testANoOpMutationNeitherBumpsTheVersionNorSendsAFrame`.
    #[test]
    fn a_suppressed_empty_diff_leaves_the_ladder_untouched() {
        let mut ladder = SyncLadder::new(true, false);
        ship(&mut ladder, EPOCH_A, 1);
        ladder.note_ack(1);
        ladder.apply_pending_ack();
        let before = ladder;
        let Plan::Send(frame) = ladder.plan(EPOCH_A) else {
            panic!("nothing is outstanding");
        };
        assert!(!frame.snapshot);
        assert_eq!(
            ladder, before,
            "planning a same-epoch frame decides nothing until it is committed"
        );
        assert_eq!(ladder.outstanding(), None);
    }

    /// The `sentEpoch ?? WireMessage.newSessionID` sentinel — kinds 2 and 3 are epoch-independent,
    /// so they ride the all-zero id rather than a fabricated one.
    #[test]
    fn the_loose_epoch_is_all_zero_until_a_document_ships() {
        let mut ladder = SyncLadder::new(true, false);
        assert_eq!(ladder.loose_epoch(), [0; 16]);
        assert!(matches!(ladder.plan(EPOCH_A), Plan::Send(_)));
        assert_eq!(
            ladder.loose_epoch(),
            EPOCH_A,
            "the epoch is claimed by the PLAN, before the frame is acked"
        );
    }

    /// Ported from `testAStaleClockIsRefusedAndChangesNothing`.
    #[test]
    fn a_presence_clock_only_moves_forward() {
        let mut ladder = SyncLadder::new(true, false);
        assert!(ladder.note_presence(Presence {
            presence_clock: 5,
            viewing_tab_id: TAB,
            viewing_pane_id: PANE,
            cols: 100,
            rows: 40,
            contributes_size: true,
            follows_focus: true,
        }));
        assert!(
            !ladder.note_presence(Presence {
                presence_clock: 5,
                ..Presence::default()
            }),
            "EQUAL is refused too: two updates minted in one turn must not race"
        );
        assert!(!ladder.note_presence(Presence {
            presence_clock: 4,
            ..Presence::default()
        }));
        let view = ladder.roster_view();
        assert_eq!(view.viewing_pane_id, PANE);
        assert_eq!(view.cols, 100);
        assert!(ladder.note_presence(Presence {
            presence_clock: 6,
            ..Presence::default()
        }));
        assert_eq!(
            ladder.roster_view().viewing_pane_id,
            [0; 16],
            "newest wins with no merge"
        );
    }

    /// Ported from `testASilentSubscriberViewsNothing` and
    /// `testTheViewportIsCarriedButNotClaimed`.
    #[test]
    fn a_silent_subscriber_views_nothing_and_keeps_its_subscribe_flags() {
        let ladder = SyncLadder::new(true, true);
        let view = ladder.roster_view();
        assert_eq!(view.viewing_tab_id, [0; 16]);
        assert_eq!(view.viewing_pane_id, [0; 16]);
        assert_eq!(view.cols, 0);
        assert_eq!(view.rows, 0);
        assert_eq!(view.presence_clock, 0);
        assert!(view.contributes_size);
        assert!(view.follows_focus);
    }

    /// The presence update's size claim WINS over the subscribe's; its focus claim does not.
    #[test]
    fn presence_overrides_the_size_claim_and_never_the_focus_one() {
        let mut ladder = SyncLadder::new(true, false);
        assert!(ladder.note_presence(Presence {
            presence_clock: 1,
            contributes_size: false,
            follows_focus: true,
            ..Presence::default()
        }));
        let view = ladder.roster_view();
        assert!(!view.contributes_size, "the window said no, and it is live");
        assert!(!view.follows_focus, "focus is a property of the CONNECTION");
    }

    /// A resubscribe restates the connection's standing claims, so the roster follows them.
    #[test]
    fn a_resubscribe_restates_the_subscribe_flags() {
        let mut ladder = SyncLadder::new(false, false);
        assert!(!ladder.roster_view().contributes_size);
        ladder.resubscribe([0; 16], 0, true, true);
        let view = ladder.roster_view();
        assert!(view.contributes_size);
        assert!(view.follows_focus);
    }

    /// A slot is a coordinate, not an identity: two live states never share one.
    #[test]
    fn every_retained_state_gets_its_own_slot() {
        let mut ladder = SyncLadder::new(true, false);
        let mut seen = Vec::new();
        for state_num in 1..=6_i64 {
            let (_, slot) = ship(&mut ladder, EPOCH_A, state_num);
            seen.push(slot);
            ladder.note_ack(-1);
            ladder.apply_pending_ack();
        }
        seen.sort_unstable();
        let before = seen.len();
        seen.dedup();
        assert_eq!(seen.len(), before);
        assert!(!seen.contains(&NO_SLOT));
    }

    #[test]
    fn an_ack_is_pending_only_until_it_is_applied() {
        let mut ladder = SyncLadder::new(true, false);
        assert!(!ladder.has_pending_ack());
        ladder.note_ack(3);
        assert!(ladder.has_pending_ack());
        ladder.apply_pending_ack();
        assert!(!ladder.has_pending_ack());
        assert!(ladder.apply_pending_ack().is_empty());
    }
}
