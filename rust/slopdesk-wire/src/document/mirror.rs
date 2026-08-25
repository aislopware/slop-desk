//! A client's REPLICA of the document — the three layers it reads through, and what a frame does
//! to them (docs/45 §7.1).
//!
//! The host owns [`super::state::HostWorkspaceState`]. Every other process holds one of these: the
//! same cells, plus two layers the host has no equivalent of.
//!
//! **Three layers, read `pending` → `entries` → `fast_path`.**
//!
//! - `entries` is host truth and is written ONLY by [`WorkspaceMirror::apply`]. It therefore
//!   remains provably `apply(diffs, base)`, which is the entire convergence argument.
//! - `fast_path` is the low-latency overlay the per-pane control pushes write (wire 21/26/27/32/33/
//!   34/36). It is read only where `entries` has nothing, and any key a snapshot or diff supplies
//!   is ERASED from it in the same step. That erasure is the whole point: the pane channel and the
//!   workspace channel are two independent producers of the same fact, and the push path is lossy
//!   AND unordered relative to this one — so letting an overlay write survive a document value
//!   would freeze that disagreement forever, which is precisely the bug class the document exists
//!   to end, reintroduced as an optimisation.
//! - `pending` sits AHEAD of both. It holds the optimistic patches for intents this client has sent
//!   and the host has not yet answered, so a split appears the instant the user asks for it rather
//!   than a round trip later.
//!
//! ## Why the replica is here and not in the client
//! It was a Swift `struct` for a long time, and the case for that was real: applying a frame is a
//! pure function, so convergence was provable. What it could not have was the ONE implementation
//! rule. Every decision it made — may this frame be folded, has this patch been superseded, which
//! layer answers this key — was already Rust's, reached one at a time through
//! `slopdesk-workspace::mirror_fold`, while the DATA those decisions ran over stayed on the far
//! side of a marshaller. So a fold was a crossing per question and the state machine was split down
//! the middle. Here it is one object: the layers, the frame ladder and the optimistic overlay in
//! the crate that already owns the document, the codec and the intent applier.
//!
//! ## What did NOT come with it
//! The PRESENCE roster. It is never diffed, never versioned, and its lifetime is the connection
//! rather than the document, so it is not a layer of this replica — the near side decodes it and
//! holds it beside the mirror. The roster JOINS (who is viewing, who is holding) stay in
//! `slopdesk-workspace::mirror_fold`, which is where the near side asks them.

use std::collections::{BTreeMap, BTreeSet};

use slopdesk_ids::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};

use super::apply::apply as apply_intent;
use super::codec as wire_codec;
use super::fields::pane as pane_field;
use super::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind, WorkspaceStateDiff};
use super::topology::{WorkspaceTopology, write_topology};
use crate::message::RawUuid;

/// How long an unanswered patch may stand before it is dropped, in seconds.
///
/// The backstop for the case with no other signal: a host that accepted the intent and died before
/// answering. Long enough that a slow link is not mistaken for a lost intent, short enough that a
/// stale optimistic layout does not become the thing the user is looking at.
pub const PENDING_TIMEOUT: f64 = 3.0;

/// What one folded frame DID. The client acts on this and nothing else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyOutcome {
    /// Host truth moved. The argument is the `stateNum` the client must now ACK.
    Applied(i64),
    /// A frame the mirror had already superseded. Nothing changed, and deliberately NOT an error:
    /// duplicates and reorders are no-ops by construction (docs/45 §5.5).
    Ignored,
    /// The frame cannot be based on what is held — wrong epoch, or a base this mirror is not at.
    /// The client re-sends `subscribe`, which IS the resync verb.
    NeedsResubscribe,
    /// Undecodable, or a kind from a newer host. Dropped, never fatal to the channel: this wire has
    /// no version negotiation, and a kind we cannot interpret is not one we can safely guess at.
    Dropped,
    /// The host declared a new document. Host truth is now empty and a snapshot follows.
    Reset,
}

impl ApplyOutcome {
    /// The outcome's tag, for a caller that carries the pair across a boundary.
    #[must_use]
    pub const fn tag(self) -> u8 {
        match self {
            Self::Applied(_) => 0,
            Self::Ignored => 1,
            Self::NeedsResubscribe => 2,
            Self::Dropped => 3,
            Self::Reset => 4,
        }
    }

    /// The `stateNum` an [`Self::Applied`] carries, and `0` for every other arm — which is the
    /// sentinel "I know nothing" and therefore never a state anything acks.
    #[must_use]
    pub const fn state_num(self) -> i64 {
        match self {
            Self::Applied(state) => state,
            _ => 0,
        }
    }
}

/// One in-flight intent's optimistic effect on the document.
///
/// The patch is a DIFF rather than a whole topology, so it composes with host truth the same way a
/// host diff does and two in-flight intents stack in issue order. It is computed by running the
/// SAME [`super::apply::apply`] the host will run, which is what makes the optimistic render and
/// the eventual truth agree except when the host refuses.
#[derive(Debug, Clone, PartialEq)]
struct PendingPatch {
    intent_id: RawUuid,
    sets: BTreeMap<WorkspaceKey, Vec<u8>>,
    deletes: BTreeSet<WorkspaceKey>,
    /// When it was issued, in the caller's clock. The mirror stays clockless — it only compares.
    issued_at: f64,
    /// Set once the host answers `applied`: the frame count at which this patch has certainly been
    /// superseded by host truth.
    retire_at_frame: Option<u64>,
}

/// The identity pool one staged intent mints from.
///
/// A client PROPOSES object ids (DECISIONS, Multi-client Phase 5 ruling 1), so the ids are the near
/// side's and arrive with the request. Running past the end repeats the last one rather than
/// trapping: a short pool is a caller bug, and a panic inside a replica is a dead client.
struct Pool<'a> {
    ids: &'a [RawUuid],
    next: usize,
}

impl Pool<'_> {
    fn take(&mut self) -> RawUuid {
        let picked = self.ids.get(self.next).or_else(|| self.ids.last());
        self.next += 1;
        picked.copied().unwrap_or([0; 16])
    }
}

impl IdSource for Pool<'_> {
    fn pane(&mut self) -> PaneId {
        PaneId::from_bytes(self.take())
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.take())
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.take())
    }

    fn split(&mut self) -> SplitNodeId {
        SplitNodeId::from_bytes(self.take())
    }
}

/// The client's replica of the host-owned workspace document.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkspaceMirror {
    /// The document identity this mirror is synced to. `None` until the first snapshot.
    ///
    /// Minted per hostd start, so a restarted daemon counting its `stateNum` back up cannot have a
    /// delta of its own accepted against a different document.
    epoch: Option<RawUuid>,
    /// The version of `entries`. `0` means "I know nothing" — the sentinel `subscribe` sends, and
    /// the base every snapshot declares. Host `stateNum` starts at 1 for exactly that reason.
    state_num: i64,
    /// Applied host truth. Snapshot, diff and reset ONLY.
    entries: HostWorkspaceState,
    /// The control-push overlay. Written by the client's own sinks, erased by host truth.
    fast_path: BTreeMap<WorkspaceKey, Vec<u8>>,
    /// Optimistic patches for intents the host has not confirmed, oldest first.
    pending: Vec<PendingPatch>,
    /// How many host DOCUMENT frames (snapshot or diff) this mirror has applied.
    ///
    /// The retirement watermark, and a frame count rather than a `stateNum` because an intent
    /// result does not carry one. It does not need to: the host bumps `stateNum` and queues the new
    /// document BEFORE it queues the result, and the result is not gated on the outstanding frame —
    /// so the first document frame to arrive AFTER an `applied` result provably already contains
    /// that intent's effect.
    frames_applied: u64,
}

impl WorkspaceMirror {
    /// A replica that has never been spoken to.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            epoch: None,
            state_num: 0,
            entries: HostWorkspaceState::new(),
            fast_path: BTreeMap::new(),
            pending: Vec::new(),
            frames_applied: 0,
        }
    }

    // MARK: Subscribe parameters

    /// The document identity actually held, which `known_epoch` cannot say — it answers a fresh
    /// UUID for "snapshot me".
    #[must_use]
    pub const fn epoch(&self) -> Option<RawUuid> {
        self.epoch
    }

    /// What `subscribe` should declare, so the host can answer with a diff instead of a snapshot.
    ///
    /// The pair is all-or-nothing: an epoch with no state is `stateNum 0`, which reads as "snapshot
    /// me". There is no way to ask for a diff against a document this mirror does not hold.
    #[must_use]
    pub const fn known_state_num(&self) -> i64 {
        if self.epoch.is_some() { self.state_num } else { 0 }
    }

    /// The version of host truth as held, whatever the epoch says.
    #[must_use]
    pub const fn state_num(&self) -> i64 {
        self.state_num
    }

    /// How many document frames have been folded. Back to zero after [`Self::forget`], so a caller
    /// can tell a fold from every other reason its observers fire.
    #[must_use]
    pub const fn frames_applied(&self) -> u64 {
        self.frames_applied
    }

    /// HOST TRUTH alone — the overlay and the pending patches left out.
    ///
    /// Every ordinary read goes through [`Self::value`] or [`Self::resolved`]. This one exists for
    /// the caller that must NOT see the other two layers: an in-process document adopting what a
    /// store seeded is becoming authoritative, and a fast-path guess adopted as truth is a guess
    /// nothing will ever correct.
    #[must_use]
    pub const fn entries(&self) -> &HostWorkspaceState {
        &self.entries
    }

    // MARK: Apply

    /// Folds one type-37 document frame in.
    ///
    /// Takes the decoded header fields rather than a message value, so the replica stays
    /// independent of the envelope — the same reason the host's session takes them apart before
    /// sending. The PRESENCE and INTENT-RESULT kinds are the near side's (see the module
    /// header) and reach here as any other unknown kind would: [`ApplyOutcome::Dropped`], which
    /// is the forward-tolerance rule stated once.
    pub fn apply(
        &mut self,
        kind: u8,
        epoch: RawUuid,
        base_state_num: i64,
        new_state_num: i64,
        payload: &[u8],
    ) -> ApplyOutcome {
        match kind {
            0 => self.apply_snapshot(epoch, new_state_num, payload),
            1 => self.apply_diff(epoch, base_state_num, new_state_num, payload),
            4 => self.apply_reset(epoch),
            _ => ApplyOutcome::Dropped,
        }
    }

    /// A snapshot is self-contained, so it is accepted whatever the mirror holds — including across
    /// an epoch change with no intervening reset, which is exactly the cold-connect case.
    fn apply_snapshot(&mut self, epoch: RawUuid, new_state_num: i64, payload: &[u8]) -> ApplyOutcome {
        let Ok(decoded) = wire_codec::decode_snapshot(payload) else {
            return ApplyOutcome::Dropped;
        };
        let supplied = decoded.keys();
        self.entries = decoded;
        self.epoch = Some(epoch);
        self.state_num = new_state_num;
        self.retire_fast_path(&supplied);
        self.note_document_frame();
        ApplyOutcome::Applied(new_state_num)
    }

    fn apply_diff(&mut self, epoch: RawUuid, base: i64, new: i64, payload: &[u8]) -> ApplyOutcome {
        if self.epoch != Some(epoch) {
            return ApplyOutcome::NeedsResubscribe;
        }
        // Already past it, or a duplicate: a diff whose base is behind what is held describes a
        // transition already made. Not an error — see [`ApplyOutcome::Ignored`].
        if new <= self.state_num {
            return ApplyOutcome::Ignored;
        }
        // A gap. The frame in front of this one never arrived, so folding this one would ack a
        // state that was never reached.
        if base != self.state_num {
            return ApplyOutcome::NeedsResubscribe;
        }
        let Ok(diff) = wire_codec::decode_diff(payload) else {
            return ApplyOutcome::Dropped;
        };
        // A DELETE supplies a fact too — "this key is now absent" — so its overlay value must go as
        // well, or a retired title would reappear from the fast path.
        let mut supplied: Vec<WorkspaceKey> = diff.sets.iter().map(|entry| entry.key).collect();
        supplied.extend(diff.deletes.iter().copied());
        self.entries.apply(&diff);
        self.state_num = new;
        self.retire_fast_path(&supplied);
        self.note_document_frame();
        ApplyOutcome::Applied(new)
    }

    /// The host declared a different document. Host truth goes; the overlay stays.
    ///
    /// Keeping the fast path is deliberate: it is fed by the per-pane channels, whose lifetime is
    /// their own, and clearing it here would blank rows those channels are still painting. With
    /// `entries` empty the overlay simply becomes visible again — the same state the client is in
    /// before its first snapshot, and the same state it runs in when a host refuses the channel.
    ///
    /// Pending patches DO go. They describe edits to a document that no longer exists, so keeping
    /// them would render a split against a tree that never had it. The intents are simply lost,
    /// which is correct: nobody knows whether the old host applied them, and re-sending a guess is
    /// worse than a layout that snaps back.
    fn apply_reset(&mut self, epoch: RawUuid) -> ApplyOutcome {
        self.entries = HostWorkspaceState::new();
        self.epoch = Some(epoch);
        self.state_num = 0;
        self.pending.clear();
        ApplyOutcome::Reset
    }

    fn retire_fast_path(&mut self, supplied: &[WorkspaceKey]) {
        if self.fast_path.is_empty() {
            return;
        }
        for key in supplied {
            self.fast_path.remove(key);
        }
    }

    /// Forgets everything, host truth included.
    ///
    /// The workspace channel calls this when it stops: `entries` is only meaningful against a live
    /// subscription, and a reconnect that kept it could apply a diff to a document the host has
    /// since replaced. Unlike [`Self::apply_reset`] this takes the overlay too — the channel
    /// stopping is the client letting go of the whole document, not the host swapping it.
    pub fn forget(&mut self) {
        *self = Self::new();
    }

    // MARK: Fast path

    /// Records a value pushed on a pane's own control channel.
    ///
    /// Ignored where host truth already holds the key: the document is authoritative, and a push
    /// that raced a diff must not win. `None` clears the overlay entry — a push that retires a
    /// fact.
    ///
    /// - Returns: whether the overlay actually moved, so a caller can repaint only when it did.
    pub fn write_fast_path(&mut self, key: WorkspaceKey, value: Option<&[u8]>) -> bool {
        if self.entries.get(&key).is_some() {
            return false;
        }
        match value {
            Some(bytes) => {
                let held = self.fast_path.get(&key).map(Vec::as_slice);
                if held == Some(bytes) {
                    return false;
                }
                self.fast_path.insert(key, bytes.to_vec());
                true
            },
            None => self.fast_path.remove(&key).is_some(),
        }
    }

    /// Drops every overlay entry for one pane — what a client does when a pane's channel closes.
    pub fn clear_fast_path(&mut self, pane_id: RawUuid) {
        self.fast_path
            .retain(|key, _| !(key.kind == PANE_KIND && key.object_id == pane_id));
    }

    /// Whether the OVERLAY holds `key` — not the full chain.
    ///
    /// The one caller re-evaluates a verdict it computed itself, and only where it has something to
    /// re-evaluate: a client that never observed a push has no verdict to hold, and writing one
    /// would claim a fact about nothing. Asking [`Self::value`] instead would read host truth too
    /// and put this client's guess beside the host's own.
    #[must_use]
    pub fn fast_path_holds(&self, key: WorkspaceKey) -> bool {
        self.fast_path.contains_key(&key)
    }

    /// Every pane with an overlay entry. Distinct from [`Self::pane_ids`], which enumerates the
    /// DOCUMENT.
    #[must_use]
    pub fn fast_path_pane_ids(&self) -> Vec<RawUuid> {
        let mut ids: Vec<RawUuid> = self
            .fast_path
            .keys()
            .filter(|key| key.kind == PANE_KIND)
            .map(|key| key.object_id)
            .collect();
        ids.dedup();
        ids
    }

    // MARK: Pending

    /// Stages one intent's optimistic effect and answers whether anything was staged.
    ///
    /// The patch is computed by running the SAME applier the host will run against the topology as
    /// RESOLVED — host truth with this client's earlier unanswered intents already on it — and
    /// diffing the two TOPOLOGY projections. Topology projections and not the resolved documents:
    /// diffing the documents would sweep liveness and overlay cells into the patch, and host truth
    /// would then erase overlay entries the patch re-asserts. What a person arranged is the only
    /// half a client may propose.
    ///
    /// `pristine` is staged optimistically rather than decided here: whether the host's document is
    /// still untouched is a fact about the host's own FILE, and no cell carries it. A
    /// `rejectedStale` snaps the patch away, which is what the pending layer is for; refusing
    /// here instead would make the bootstrap op unsendable by construction.
    ///
    /// An EMPTY diff still stages, and still sends. A no-op rename is a decision the host has to
    /// take — it is what claims a pristine document — so a client that swallowed it here would
    /// leave the host's first-run default standing and answer `true` to a caller nothing happened
    /// for. The patch it stages carries no cells, which costs one entry in `pending` until the
    /// frame that answers it.
    ///
    /// - Returns: `false` only when this client can already tell the host will refuse — the applier
    ///   gave back no topology at all. That request is a round trip and a rollback for an answer we
    ///   hold.
    pub fn stage_intent(
        &mut self,
        intent_id: RawUuid,
        op: u8,
        args: &[u8],
        minted: &[RawUuid],
        issued_at: f64,
    ) -> bool {
        let resolved = self.resolved();
        let Some(current) = resolved.topology() else {
            return false;
        };
        let lookup = |pane: PaneId| -> Option<String> { resolved.project_key_for_pane(pane) };
        let mut ids = Pool { ids: minted, next: 0 };
        let outcome = apply_intent(op, args, &current, &mut ids, true, &lookup);
        let Some(next) = outcome.topology() else {
            return false;
        };
        let diff = Self::topology_diff(&current, next);
        self.pending.retain(|patch| patch.intent_id != intent_id);
        self.pending.push(PendingPatch {
            intent_id,
            sets: diff
                .sets
                .into_iter()
                .map(|entry| (entry.key, entry.value))
                .collect(),
            deletes: diff.deletes.into_iter().collect(),
            issued_at,
            retire_at_frame: None,
        });
        true
    }

    /// The cells that carry `current` to `next`, TOPOLOGY only.
    fn topology_diff(current: &WorkspaceTopology, next: &WorkspaceTopology) -> WorkspaceStateDiff {
        let mut before = HostWorkspaceState::new();
        write_topology(&mut before, current);
        let mut after = HostWorkspaceState::new();
        write_topology(&mut after, next);
        after.diff_from(&before)
    }

    /// Folds the host's verdict on one intent.
    ///
    /// A non-zero status snaps the layout back IMMEDIATELY rather than at the next frame. That is
    /// the anti-flicker rule stated the useful way round: a refusal is the one case where waiting
    /// shows the user something the host has already said is not true.
    ///
    /// - Returns: whether a patch was found and moved.
    pub fn note_intent_result(&mut self, intent_id: RawUuid, applied: bool) -> bool {
        let Some(index) = self.pending.iter().position(|patch| patch.intent_id == intent_id) else {
            return false;
        };
        if !applied {
            self.pending.remove(index);
            return true;
        }
        // The next document frame provably already contains this intent's effect — see
        // `frames_applied`.
        if let Some(patch) = self.pending.get_mut(index) {
            patch.retire_at_frame = Some(self.frames_applied.saturating_add(1));
        }
        true
    }

    fn note_document_frame(&mut self) {
        self.frames_applied = self.frames_applied.wrapping_add(1);
        let watermark = self.frames_applied;
        self.pending
            .retain(|patch| patch.retire_at_frame.is_none_or(|frame| watermark < frame));
    }

    /// Drops patches the host never answered. The caller owns the clock.
    ///
    /// - Returns: `true` if anything was dropped, so the caller can repaint. A patch that expired
    ///   silently would leave the UI showing a split the host never made, with nothing to correct
    ///   it.
    pub fn expire_pending(&mut self, now: f64, timeout: f64) -> bool {
        let before = self.pending.len();
        self.pending
            .retain(|patch| patch.retire_at_frame.is_some() || now - patch.issued_at < timeout);
        self.pending.len() != before
    }

    /// Drops one staged patch outright — what a client does when the request never left the
    /// machine.
    ///
    /// Distinct from [`Self::expire_pending`]: a send that FAILED needs no grace period. The host
    /// was never asked, so there is no answer coming and no reason to keep showing a split nobody
    /// made for three seconds first.
    pub fn drop_pending(&mut self, intent_id: RawUuid) -> bool {
        let before = self.pending.len();
        self.pending.retain(|patch| patch.intent_id != intent_id);
        self.pending.len() != before
    }

    /// How many optimistic patches are standing.
    #[must_use]
    pub const fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Whether `intent_id`'s optimistic patch is still standing — the intent went out and the host
    /// has neither answered it nor superseded it.
    ///
    /// `false` for an id [`Self::stage_intent`] refused, for one already answered, and after a
    /// [`Self::forget`].
    #[must_use]
    pub fn is_pending(&self, intent_id: RawUuid) -> bool {
        self.pending.iter().any(|patch| patch.intent_id == intent_id)
    }

    // MARK: Read

    /// The single funnel every read goes through: `pending` → `entries` → `fast_path`.
    #[must_use]
    pub fn value(&self, key: WorkspaceKey) -> Option<&[u8]> {
        // Newest first: two in-flight intents touching one cell resolve to the later one, which is
        // the order the host will resolve them in too.
        for patch in self.pending.iter().rev() {
            if let Some(value) = patch.sets.get(&key) {
                return Some(value);
            }
            if patch.deletes.contains(&key) {
                return None;
            }
        }
        self.entries
            .get(&key)
            .or_else(|| self.fast_path.get(&key).map(Vec::as_slice))
    }

    /// The whole document as one value, read through the full precedence chain.
    ///
    /// What the topology projection reads, because a tree has to be rebuilt from every cell at once
    /// and cell-by-cell reads cannot express "this pane is gone".
    #[must_use]
    pub fn resolved(&self) -> HostWorkspaceState {
        let mut out = self.entries.clone();
        for (key, value) in &self.fast_path {
            if out.get(key).is_none() {
                out.set(*key, value.clone());
            }
        }
        for patch in &self.pending {
            for (key, value) in &patch.sets {
                out.set(*key, value.clone());
            }
            for key in &patch.deletes {
                out.set_or_clear(*key, None);
            }
        }
        out
    }

    /// The layout to render right now — host truth with this client's unanswered intents applied.
    #[must_use]
    pub fn topology(&self) -> Option<WorkspaceTopology> {
        self.resolved().topology()
    }

    /// Every pane the DOCUMENT knows about, in canonical key order.
    ///
    /// Membership is the `liveness` field, which the host always emits — a pane with only overlay
    /// values is NOT a document pane and must not be enumerated as one.
    #[must_use]
    pub fn pane_ids(&self) -> Vec<RawUuid> {
        self.entries
            .keys()
            .into_iter()
            .filter(|key| key.kind == PANE_KIND && key.field == pane_field::LIVENESS)
            .map(|key| key.object_id)
            .collect()
    }
}

/// The pane object kind's tag byte, as the key carries it.
const PANE_KIND: u8 = WorkspaceObjectKind::Pane.as_byte();

#[cfg(test)]
mod tests {
    use slopdesk_ids::identity::{PaneId, SessionId, TabId};
    use slopdesk_tree::session::{PaneKind, PaneSpec};
    use slopdesk_tree::workspace::TreeWorkspace;

    use super::super::codec as wire_codec;
    use super::super::codec::SplitAxis;
    use super::super::fields::pane as pane_field;
    use super::super::intent::{WorkspaceIntentOp, encode_identity};
    use super::super::state::{
        HostWorkspaceState, WorkspaceEntry, WorkspaceKey, WorkspaceObjectKind, WorkspaceStateDiff,
    };
    use super::super::topology::{WorkspaceTopology, is_topology, write_topology};
    use super::{ApplyOutcome, PENDING_TIMEOUT, WorkspaceMirror};

    const EPOCH: [u8; 16] = [0xA1; 16];
    const OTHER_EPOCH: [u8; 16] = [0xB2; 16];

    fn pane_key(pane: u8, field: u8) -> WorkspaceKey {
        WorkspaceKey::of(WorkspaceObjectKind::Pane, [pane; 16], field)
    }

    /// A document holding one pane's liveness — the field that MAKES it a document pane.
    fn one_cell(pane: u8) -> HostWorkspaceState {
        let mut state = HostWorkspaceState::new();
        state.set(pane_key(pane, pane_field::LIVENESS), vec![1]);
        state
    }

    fn snapshot(state: &HostWorkspaceState) -> Vec<u8> {
        wire_codec::encode_snapshot(state)
    }

    fn diff_of(sets: Vec<WorkspaceEntry>, deletes: Vec<WorkspaceKey>) -> Vec<u8> {
        wire_codec::encode_diff(&WorkspaceStateDiff::new(sets, deletes))
    }

    /// A mirror holding one pane at state 1.
    fn seeded() -> WorkspaceMirror {
        let mut mirror = WorkspaceMirror::new();
        assert_eq!(
            mirror.apply(0, EPOCH, 0, 1, &snapshot(&one_cell(1))),
            ApplyOutcome::Applied(1)
        );
        mirror
    }

    #[test]
    fn a_snapshot_is_accepted_whatever_is_held_and_names_the_state_to_ack() {
        let mut mirror = seeded();
        assert_eq!(mirror.epoch(), Some(EPOCH));
        assert_eq!(mirror.known_state_num(), 1);
        assert_eq!(mirror.frames_applied(), 1);
        // A DIFFERENT document, with no intervening reset: the cold-connect case.
        assert_eq!(
            mirror.apply(0, OTHER_EPOCH, 0, 9, &snapshot(&one_cell(2))),
            ApplyOutcome::Applied(9)
        );
        assert_eq!(mirror.pane_ids(), vec![[2_u8; 16]]);
    }

    #[test]
    fn a_diff_needs_the_epoch_and_the_base_it_declares() {
        let mut mirror = seeded();
        let payload = diff_of(
            vec![WorkspaceEntry::new(pane_key(1, pane_field::LIVENESS), vec![2])],
            vec![],
        );
        assert_eq!(
            mirror.apply(1, OTHER_EPOCH, 1, 2, &payload),
            ApplyOutcome::NeedsResubscribe,
            "a diff against another document is not foldable"
        );
        assert_eq!(
            mirror.apply(1, EPOCH, 7, 8, &payload),
            ApplyOutcome::NeedsResubscribe,
            "a gap means the frame in front never arrived"
        );
        assert_eq!(
            mirror.apply(1, EPOCH, 0, 1, &payload),
            ApplyOutcome::Ignored,
            "a state already held is a duplicate, and duplicates are free"
        );
        assert_eq!(mirror.apply(1, EPOCH, 1, 2, &payload), ApplyOutcome::Applied(2));
    }

    #[test]
    fn an_unknown_kind_and_undecodable_bytes_are_dropped_never_fatal() {
        let mut mirror = seeded();
        assert_eq!(
            mirror.apply(2, EPOCH, 0, 0, &[]),
            ApplyOutcome::Dropped,
            "presence is the near side's"
        );
        assert_eq!(
            mirror.apply(3, EPOCH, 0, 0, &[]),
            ApplyOutcome::Dropped,
            "an intent result is too"
        );
        assert_eq!(
            mirror.apply(99, EPOCH, 0, 0, &[]),
            ApplyOutcome::Dropped,
            "so is a kind from a newer host"
        );
        assert_eq!(mirror.apply(0, EPOCH, 0, 2, &[0xFF, 0xFF]), ApplyOutcome::Dropped);
        assert_eq!(mirror.known_state_num(), 1, "none of them moved host truth");
    }

    #[test]
    fn host_truth_erases_the_overlay_for_every_key_it_supplies_including_a_delete() {
        let mut mirror = seeded();
        let title = pane_key(1, pane_field::LIVE_TITLE);
        let cwd = pane_key(1, pane_field::CWD);
        assert!(mirror.write_fast_path(title, Some(b"nvim")));
        assert!(mirror.write_fast_path(cwd, Some(b"/tmp")));
        assert_eq!(mirror.value(title), Some(b"nvim".as_slice()));

        let payload = diff_of(vec![WorkspaceEntry::new(title, b"vi .".to_vec())], vec![cwd]);
        assert_eq!(mirror.apply(1, EPOCH, 1, 2, &payload), ApplyOutcome::Applied(2));
        assert_eq!(mirror.value(title), Some(b"vi .".as_slice()), "host truth won");
        assert_eq!(
            mirror.value(cwd),
            None,
            "a DELETE supplies a fact too — the overlay value goes with it"
        );
    }

    #[test]
    fn the_overlay_never_overwrites_a_key_host_truth_already_holds() {
        let mut mirror = seeded();
        let liveness = pane_key(1, pane_field::LIVENESS);
        assert!(
            !mirror.write_fast_path(liveness, Some(&[9])),
            "refused, so nothing to repaint"
        );
        assert_eq!(mirror.value(liveness), Some([1_u8].as_slice()));
    }

    #[test]
    fn an_overlay_write_that_changes_nothing_reports_no_repaint() {
        let mut mirror = seeded();
        let title = pane_key(1, pane_field::LIVE_TITLE);
        assert!(mirror.write_fast_path(title, Some(b"nvim")));
        assert!(
            !mirror.write_fast_path(title, Some(b"nvim")),
            "same bytes, no edge"
        );
        assert!(mirror.write_fast_path(title, None), "retiring it IS an edge");
        assert!(
            !mirror.write_fast_path(title, None),
            "and retiring nothing is not"
        );
    }

    #[test]
    fn clearing_one_panes_overlay_leaves_every_other_panes_alone() {
        let mut mirror = seeded();
        mirror.write_fast_path(pane_key(1, pane_field::LIVE_TITLE), Some(b"one"));
        mirror.write_fast_path(pane_key(2, pane_field::LIVE_TITLE), Some(b"two"));
        assert_eq!(mirror.fast_path_pane_ids().len(), 2);
        mirror.clear_fast_path([1; 16]);
        assert_eq!(mirror.fast_path_pane_ids(), vec![[2_u8; 16]]);
    }

    #[test]
    fn a_reset_empties_host_truth_keeps_the_overlay_and_drops_the_pending() {
        let mut mirror = with_topology();
        let title = pane_key(1, pane_field::LIVE_TITLE);
        mirror.write_fast_path(title, Some(b"nvim"));
        stage_a_split(&mut mirror);
        assert_eq!(mirror.pending_count(), 1);

        assert_eq!(mirror.apply(4, OTHER_EPOCH, 0, 0, &[]), ApplyOutcome::Reset);
        assert_eq!(mirror.epoch(), Some(OTHER_EPOCH));
        assert_eq!(mirror.known_state_num(), 0);
        assert_eq!(
            mirror.pending_count(),
            0,
            "those edits were to a document that no longer exists"
        );
        assert_eq!(
            mirror.value(title),
            Some(b"nvim".as_slice()),
            "the pane channels are still painting this row"
        );
    }

    #[test]
    fn forgetting_takes_the_overlay_too_which_is_what_a_reset_does_not() {
        let mut mirror = seeded();
        mirror.write_fast_path(pane_key(1, pane_field::LIVE_TITLE), Some(b"nvim"));
        mirror.forget();
        assert_eq!(mirror.epoch(), None);
        assert_eq!(mirror.frames_applied(), 0);
        assert!(mirror.fast_path_pane_ids().is_empty());
    }

    #[test]
    fn pane_ids_enumerate_the_document_not_the_overlay() {
        let mut mirror = seeded();
        mirror.write_fast_path(pane_key(2, pane_field::LIVE_TITLE), Some(b"ghost"));
        assert_eq!(
            mirror.pane_ids(),
            vec![[1_u8; 16]],
            "a pane with only overlay values is not a document pane"
        );
    }

    // MARK: The optimistic layer

    /// A document with one real topology on it, which is what an intent can be applied to.
    fn with_topology() -> WorkspaceMirror {
        let topology = WorkspaceTopology::new(TreeWorkspace::single_pane(
            SessionId::from_bytes([1; 16]),
            TabId::from_bytes([1; 16]),
            PaneId::from_bytes([1; 16]),
            PaneSpec::new(PaneKind::Terminal, "Terminal"),
        ));
        let mut state = HostWorkspaceState::new();
        write_topology(&mut state, &topology);
        let mut mirror = WorkspaceMirror::new();
        assert_eq!(
            mirror.apply(0, EPOCH, 0, 1, &snapshot(&state)),
            ApplyOutcome::Applied(1)
        );
        mirror
    }

    /// Splits the one pane, optimistically. The minted ids are the near side's, as they are live.
    fn stage_a_split(mirror: &mut WorkspaceMirror) -> bool {
        let args =
            super::super::intent::encode_split(&[1; 16], SplitAxis::Horizontal, false, &[0x51; 16], "");
        mirror.stage_intent(
            [7; 16],
            WorkspaceIntentOp::SplitPane.as_byte(),
            &args,
            &[[0x52; 16], [0x53; 16], [0x54; 16], [0x55; 16]],
            100.0,
        )
    }

    #[test]
    fn a_staged_patch_touches_topology_cells_and_nothing_else() {
        let mut mirror = with_topology();
        // An overlay fact and a liveness cell, both of which `resolved` sees.
        mirror.write_fast_path(pane_key(1, pane_field::LIVE_TITLE), Some(b"nvim"));
        assert!(stage_a_split(&mut mirror), "the split applied");

        // The patch is the only thing standing ahead of host truth, so every key it answers that
        // host truth does not is one it staged.
        let staged = mirror.resolved();
        for key in staged.keys() {
            if mirror_holds_only_via_patch(&mirror, [7; 16], key) {
                assert!(
                    is_topology(&key),
                    "the patch staged a NON-topology cell: {key:?} — host truth would erase it and the \
                     patch would re-assert it forever"
                );
            }
        }
    }

    /// Whether `key` is answered by `intent`'s patch alone.
    fn mirror_holds_only_via_patch(
        mirror: &WorkspaceMirror,
        intent: crate::RawUuid,
        key: WorkspaceKey,
    ) -> bool {
        let mut bare = mirror.clone();
        let answered = mirror.value(key).map(<[u8]>::to_vec);
        bare.drop_pending(intent);
        answered.is_some() && bare.value(key).map(<[u8]>::to_vec) != answered
    }

    #[test]
    fn an_intent_this_client_can_already_see_refused_stages_nothing() {
        let mut mirror = with_topology();
        let args = encode_identity(&[0xDD; 16]);
        assert!(
            !mirror.stage_intent([8; 16], WorkspaceIntentOp::ClosePane.as_byte(), &args, &[], 100.0),
            "a pane the document does not hold is a refusal we can read here — a round trip and a rollback \
             for nothing"
        );
        assert_eq!(mirror.pending_count(), 0);
    }

    /// A no-op is NOT a refusal this client may read for itself: whether the host's document is
    /// still pristine is a fact about the host's own file, and taking ownership of it is the only
    /// effect a rename-to-the-same-name has. Swallowing it here would answer "nothing happened" to
    /// a caller the host was about to move for.
    #[test]
    fn an_intent_that_changes_no_cell_still_stages_and_still_goes_out() {
        let mut mirror = with_topology();
        let rename = super::super::intent::encode_name(&[1; 16], "build");
        let stage = |id: crate::RawUuid, mirror: &mut WorkspaceMirror| {
            mirror.stage_intent(id, WorkspaceIntentOp::RenameTab.as_byte(), &rename, &[], 100.0)
        };
        assert!(stage([8; 16], &mut mirror), "the rename moved the title");
        // The SAME rename again, against a resolved document the first one already carries: the
        // applier accepts it and the diff is empty.
        assert!(stage([9; 16], &mut mirror));
        assert!(mirror.is_pending([9; 16]), "the empty patch is standing");

        // Empty, so it hides nothing: dropping it changes no answer the first patch already gave.
        let resolved = mirror.resolved();
        for key in resolved.keys() {
            assert!(
                !mirror_holds_only_via_patch(&mirror, [9; 16], key),
                "the no-op patch answered {key:?} on its own"
            );
        }
    }

    #[test]
    fn an_intent_against_no_document_stages_nothing() {
        let mut mirror = WorkspaceMirror::new();
        assert!(!stage_a_split(&mut mirror));
    }

    #[test]
    fn an_applied_result_retires_at_the_next_frame_and_a_refusal_immediately() {
        let mut mirror = with_topology();
        assert!(stage_a_split(&mut mirror));
        assert!(mirror.is_pending([7; 16]));
        assert!(mirror.note_intent_result([7; 16], true));
        assert!(
            mirror.is_pending([7; 16]),
            "an accepted result only ARMS the patch"
        );

        let payload = diff_of(
            vec![WorkspaceEntry::new(pane_key(3, pane_field::LIVENESS), vec![1])],
            vec![],
        );
        assert_eq!(mirror.apply(1, EPOCH, 1, 2, &payload), ApplyOutcome::Applied(2));
        assert!(
            !mirror.is_pending([7; 16]),
            "the first frame after provably carries the effect"
        );

        assert!(stage_a_split(&mut mirror));
        assert!(mirror.note_intent_result([7; 16], false));
        assert!(
            !mirror.is_pending([7; 16]),
            "a refusal snaps back NOW — waiting shows what the host has already denied"
        );
    }

    #[test]
    fn a_result_for_an_unknown_intent_moves_nothing() {
        let mut mirror = with_topology();
        assert!(!mirror.note_intent_result([0xCC; 16], true));
    }

    #[test]
    fn an_unanswered_patch_expires_and_an_armed_one_does_not() {
        let mut mirror = with_topology();
        assert!(stage_a_split(&mut mirror));
        assert!(!mirror.expire_pending(100.0 + PENDING_TIMEOUT - 0.5, PENDING_TIMEOUT));
        assert!(mirror.expire_pending(100.0 + PENDING_TIMEOUT, PENDING_TIMEOUT));
        assert_eq!(mirror.pending_count(), 0);

        assert!(stage_a_split(&mut mirror));
        assert!(mirror.note_intent_result([7; 16], true));
        assert!(
            !mirror.expire_pending(1_000_000.0, PENDING_TIMEOUT),
            "an ARMED patch waits for its frame, however long the clock says"
        );
    }

    #[test]
    fn dropping_a_patch_needs_no_grace_period() {
        let mut mirror = with_topology();
        assert!(stage_a_split(&mut mirror));
        assert!(mirror.drop_pending([7; 16]));
        assert!(
            !mirror.drop_pending([7; 16]),
            "and there is nothing left to drop twice"
        );
    }

    #[test]
    fn the_newest_patch_answers_a_cell_two_of_them_touch() {
        let mut mirror = seeded();
        let title = pane_key(1, pane_field::LIVE_TITLE);
        mirror.write_fast_path(title, Some(b"overlay"));
        assert_eq!(mirror.value(title), Some(b"overlay".as_slice()));
        // The read funnel's own order, exercised through the layers a hand-built mirror can reach:
        // host truth outranks the overlay.
        let payload = diff_of(vec![WorkspaceEntry::new(title, b"host".to_vec())], vec![]);
        assert_eq!(mirror.apply(1, EPOCH, 1, 2, &payload), ApplyOutcome::Applied(2));
        assert_eq!(mirror.value(title), Some(b"host".as_slice()));
    }
}
