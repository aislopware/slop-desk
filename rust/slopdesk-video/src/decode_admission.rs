//! What the client's decoder is allowed to see, and in what order.
//!
//! Three rules stand between a reassembled frame and the hardware decoder, each closing a measured
//! failure class: the sequencer puts frames back in id order, the gate refuses frames whose
//! reference chain is known broken, and the budget refuses frames while the decode stage is wedged.
//! A fourth value, the frontier, is what the client tells the host it has actually decoded.
//!
//! All of it is wrap-aware in the reassembler's sequence space, and none of it has a clock or a
//! decoder behind it.
//!
//! ## Why the sequencer moves IDS and not FRAMES
//!
//! Nothing here reads a compressed byte. The ordering law is a function of frame ids and one
//! keyframe bit, so the sequencer holds ids and answers with ids: which are releasable now, and
//! which a keyframe has made obsolete. The caller keeps the payloads it already owns and looks them
//! up by id. Threading megabytes of compressed video through a law that never inspects them would
//! be a copy per frame for nothing.
//!
//! Both valves bound how much can be outstanding, so the sets are FIXED-CAPACITY arrays rather than
//! trees: no allocation on the per-frame path, and the whole sequencer stays a value that copies.

use crate::reassembler::distance_wrapped;
use crate::recovery::NO_FRAME_DECODED_SENTINEL;

/// The highest frame that SUCCESSFULLY decoded, in wrap-aware sequence space.
///
/// Every recovery request carries it, so the host can tell whether a keyframe it recently sent
/// reached this client — a request newer than the keyframe means it arrived — or is a presumed
/// casualty, where a request older than it and past the in-flight grace bypasses the cooldown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DecodeFrontier {
    last_decoded_frame_id: Option<u32>,
}

impl DecodeFrontier {
    /// A client that has decoded nothing.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_decoded_frame_id: None,
        }
    }

    /// The frontier this state describes, so a caller holding it as data can fold into it again.
    #[must_use]
    pub const fn restored(last_decoded_frame_id: Option<u32>) -> Self {
        Self {
            last_decoded_frame_id,
        }
    }

    /// The frontier itself.
    #[must_use]
    pub const fn last_decoded_frame_id(&self) -> Option<u32> {
        self.last_decoded_frame_id
    }

    /// Folds one successfully decoded frame, keeping the newest. A late out-of-order decode is a
    /// no-op, so the frontier only ever advances.
    pub fn note_decoded(&mut self, frame_id: u32) {
        if self
            .last_decoded_frame_id
            .is_none_or(|current| distance_wrapped(frame_id, current) > 0)
        {
            self.last_decoded_frame_id = Some(frame_id);
        }
    }

    /// The on-wire field: the frontier, or the sentinel when nothing has decoded. Frame ids start
    /// at zero, so zero can never be the sentinel.
    #[must_use]
    pub fn wire_value(&self) -> u32 {
        self.last_decoded_frame_id.unwrap_or(NO_FRAME_DECODED_SENTINEL)
    }
}

/// How broken the reference chain is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GateMode {
    /// The chain is intact — everything submits.
    #[default]
    Open,
    /// At least one unrecoverable loss since the last anchor, but the decoder session is alive.
    BrokenChain,
    /// The decoder session is gone, from a hard failure or because none was ever configured.
    NeedKeyframe,
}

/// Whether one reassembled frame reaches the decoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateVerdict {
    /// Hand it to the decoder.
    Submit,
    /// Drop it before the decoder ever sees it.
    Drop,
}

/// Pre-emptive drop-until-anchor decode admission.
///
/// A delta that transitively references an unrecoverably lost frame cannot decode; the hardware
/// decoder throws, measured nine times out of nine on a self-heal probe. Without this gate the
/// client learns that the hard way, once PER FRAME: every post-loss delta is submitted, fails,
/// tears the decode session down, and fires its own keyframe request. Measured over one 139-second
/// session, nine wire losses amplified into twenty-three decode failures and sixty-three repeated
/// requests. The teardown is the expensive part — it wipes the decoder's reference state, killing
/// the cheap recovery path, and forces a full reconfigure on the next keyframe.
///
/// Once the chain is known broken, deltas stop reaching the decoder at all, and only anchor
/// candidates are submitted: a keyframe, which references nothing; an ACKED-ANCHORED frame, which
/// the host encoded against a reference this client acked and therefore provably decoded before the
/// loss, and which the un-torn-down session still holds precisely because the gate kept garbage out
/// of it; or a delta OLDER than the episode's oldest loss, whose references predate the break.
///
/// The long-term-reference bit is NOT an anchor. The encoder surfaces an ack token on virtually
/// every frame once that mode is on — measured live at 7865 frames out of 7874 — so the bit means
/// "ack me on decode", not "decodable past a loss". Treating it as an anchor admits ordinary chain
/// deltas past a break and costs exactly one decode failure per loss episode.
///
/// The two broken modes take different anchor sets, and the difference is the decoder's reference
/// buffer: while the session lives, an acked refresh can decode; once it has been torn down, only a
/// keyframe can.
///
/// Liveness stays with the caller — the escalation episode is armed by the loss-detection path
/// before the first drop, so a lost recovery frame still escalates to a forced keyframe on its own
/// cadence, now without a per-frame request storm.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DecodeGate {
    mode: GateMode,
    min_lost_frame_id: Option<u32>,
    max_lost_frame_id: Option<u32>,
}

impl DecodeGate {
    /// A gate over an intact chain.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            mode: GateMode::Open,
            min_lost_frame_id: None,
            max_lost_frame_id: None,
        }
    }

    /// The gate this state describes, so a caller holding it as data can fold into it again.
    #[must_use]
    pub const fn restored(
        mode: GateMode,
        min_lost_frame_id: Option<u32>,
        max_lost_frame_id: Option<u32>,
    ) -> Self {
        Self {
            mode,
            min_lost_frame_id,
            max_lost_frame_id,
        }
    }

    /// The current admission mode.
    #[must_use]
    pub const fn mode(&self) -> GateMode {
        self.mode
    }

    /// The OLDEST loss of the episode. The chain is intact strictly before it.
    #[must_use]
    pub const fn min_lost_frame_id(&self) -> Option<u32> {
        self.min_lost_frame_id
    }

    /// The NEWEST loss of the episode. An anchor must decode strictly past it to prove the chain
    /// re-anchored.
    #[must_use]
    pub const fn max_lost_frame_id(&self) -> Option<u32> {
        self.max_lost_frame_id
    }

    /// Folds one unrecoverably lost frame, opening the episode.
    ///
    /// A torn-down session is strictly stronger and is never downgraded by a mere loss.
    pub fn note_loss(&mut self, frame_id: u32) {
        if matches!(self.mode, GateMode::Open) {
            self.mode = GateMode::BrokenChain;
        }
        if self
            .max_lost_frame_id
            .is_none_or(|max| distance_wrapped(frame_id, max) > 0)
        {
            self.max_lost_frame_id = Some(frame_id);
        }
        if self
            .min_lost_frame_id
            .is_none_or(|min| distance_wrapped(frame_id, min) < 0)
        {
            self.min_lost_frame_id = Some(frame_id);
        }
    }

    /// A hard decode failure tore the session down — only a keyframe helps now.
    pub const fn note_hard_decode_failure(&mut self) {
        self.mode = GateMode::NeedKeyframe;
    }

    /// The decoder has no session or parameter sets yet, which takes the same anchor set.
    pub const fn note_awaiting_keyframe(&mut self) {
        self.mode = GateMode::NeedKeyframe;
    }

    /// The admission decision for one reassembled frame. Pure — the caller acts on it.
    #[must_use]
    pub fn verdict(&self, frame_id: u32, keyframe: bool, acked_anchored: bool) -> GateVerdict {
        match self.mode {
            GateMode::Open => GateVerdict::Submit,
            GateMode::NeedKeyframe => {
                if keyframe {
                    GateVerdict::Submit
                } else {
                    GateVerdict::Drop
                }
            },
            GateMode::BrokenChain => {
                if keyframe
                    || acked_anchored
                    // A pre-break delta still in flight: its references predate the oldest loss.
                    || self
                        .min_lost_frame_id
                        .is_some_and(|min| distance_wrapped(frame_id, min) < 0)
                {
                    GateVerdict::Submit
                } else {
                    GateVerdict::Drop
                }
            },
        }
    }

    /// Folds one SUCCESSFUL decode.
    ///
    /// A keyframe re-opens the gate unless a loss NEWER than it is already on record, where the
    /// chain past the keyframe is still broken and the next refresh has to finish the job. A
    /// non-keyframe success newer than every loss is the healed anchor.
    ///
    /// A stale keyframe — one that predates the newest loss — re-anchors the chain only up to
    /// itself. It downgrades a broken chain, which then admits an acked refresh, but it must NOT
    /// downgrade a torn-down session: rebuilding one from a stale keyframe leaves a reference
    /// buffer holding only that keyframe, so no pre-teardown acked reference survives and admitting
    /// a refresh would hand the decoder a reference it no longer has — another failure, another
    /// teardown, another request, which is the exact churn this gate exists to prevent.
    pub fn note_decode_succeeded(&mut self, frame_id: u32, keyframe: bool) {
        if keyframe {
            if self
                .max_lost_frame_id
                .is_some_and(|max| distance_wrapped(frame_id, max) <= 0)
            {
                if !matches!(self.mode, GateMode::NeedKeyframe) {
                    self.mode = GateMode::BrokenChain;
                }
            } else {
                *self = Self::new();
            }
            return;
        }
        if matches!(self.mode, GateMode::BrokenChain)
            && self
                .max_lost_frame_id
                .is_some_and(|max| distance_wrapped(frame_id, max) > 0)
        {
            *self = Self::new();
        }
    }
}

/// The default held-frame count before the sequencer gives up on a gap.
pub const DEFAULT_MAX_HELD: usize = 4;
/// The default id span past the expectation before the sequencer gives up on a gap.
pub const DEFAULT_MAX_GAP: i32 = 6;
/// The CEILING of both valve bands, and so the reason the sequencer's sets are arrays.
///
/// The valves are derived from the retransmit grace — a handful of frame ids, eight by default —
/// and this is an order of magnitude past any of it. A wider setting clamps here: patience past
/// this point is a pane frozen for a second, which no gap is worth.
pub const MAX_VALVE_SPAN: i32 = 64;
/// The same ceiling as a count. A distance is signed and a length is not, so the band is spelled
/// once and widened rather than written twice.
pub const MAX_VALVE: usize = MAX_VALVE_SPAN.unsigned_abs() as usize;
/// How many held ids the sequencer can carry: the count valve trips one past its own ceiling.
pub const HELD_CAPACITY: usize = MAX_VALVE + 1;
/// How many declared-lost ids it can carry: the sum valve trips one past both ceilings together.
pub const LOST_CAPACITY: usize = 2 * MAX_VALVE + 1;

/// A fixed-capacity list of frame ids.
///
/// Two shapes share it. The sequencer's two sets keep it in ascending numeric order and deduped,
/// which is what the trees it replaced did; a step's answers push in RELEASE order, which is
/// ascending in wrap space and therefore not always in numeric space.
///
/// Every operation is total. The capacities above are proved against the valves, so a full list is
/// unreachable — and if it were reached, keeping what is there beats a panic, which on the way out
/// through the FFI shim would be an abort rather than an error.
#[derive(Debug, Clone, Copy, Eq)]
struct IdList<const N: usize> {
    ids: [u32; N],
    len: usize,
}

impl<const N: usize> PartialEq for IdList<N> {
    /// Only the live prefix is the value; whatever a removal left behind it is not.
    fn eq(&self, other: &Self) -> bool {
        self.slice() == other.slice()
    }
}

impl<const N: usize> IdList<N> {
    /// An empty list.
    const fn new() -> Self {
        Self { ids: [0; N], len: 0 }
    }

    /// The live ids.
    fn slice(&self) -> &[u32] {
        self.ids.get(..self.len).unwrap_or(&[])
    }

    /// How many ids are live.
    const fn len(&self) -> usize {
        self.len
    }

    /// Appends one id, keeping insertion order.
    fn push(&mut self, id: u32) {
        if let Some(slot) = self.ids.get_mut(self.len) {
            *slot = id;
            self.len += 1;
        }
    }

    /// Adds one id, keeping the list sorted and deduped.
    fn insert_sorted(&mut self, id: u32) {
        let Err(at) = self.slice().binary_search(&id) else {
            return;
        };
        if self.len >= N {
            return;
        }
        self.ids.copy_within(at..self.len, at + 1);
        if let Some(slot) = self.ids.get_mut(at) {
            *slot = id;
            self.len += 1;
        }
    }

    /// Removes one id, answering whether it was there.
    fn remove(&mut self, id: u32) -> bool {
        let Ok(at) = self.slice().binary_search(&id) else {
            return false;
        };
        self.ids.copy_within(at + 1..self.len, at);
        self.len -= 1;
        true
    }

    /// Keeps the ids the predicate accepts.
    fn retain(&mut self, mut keep: impl FnMut(u32) -> bool) {
        let mut kept = Self::new();
        for &id in self.slice() {
            if keep(id) {
                kept.push(id);
            }
        }
        *self = kept;
    }

    /// Drops every id.
    const fn clear(&mut self) {
        self.len = 0;
    }

    /// The newest id in wrap space, which is not the largest one.
    fn newest_wrapped(&self) -> Option<u32> {
        self.slice().iter().copied().reduce(|newest, id| {
            if distance_wrapped(id, newest) > 0 {
                id
            } else {
                newest
            }
        })
    }

    /// Sorts ascending in WRAP space.
    ///
    /// A selection sort rather than the library's: `distance_wrapped` is only a total order over a
    /// span shorter than half the id space, which the valves guarantee and a sort that validates
    /// its comparator would abort on if they ever did not.
    fn sort_wrapped(&mut self) {
        let mut cursor = 0;
        while cursor < self.len {
            let mut best = cursor;
            let mut probe = cursor + 1;
            while probe < self.len {
                if let (Some(&candidate), Some(&current)) = (self.ids.get(probe), self.ids.get(best))
                    && distance_wrapped(candidate, current) < 0
                {
                    best = probe;
                }
                probe += 1;
            }
            self.ids.swap(cursor, best);
            cursor += 1;
        }
    }
}

/// What one fold releases to the decoder, and what it makes obsolete.
///
/// Both are frame ids the caller looks its own payloads up by. An id can be in BOTH lists exactly
/// once: a duplicate keyframe that was already held releases as the new arrival and drops as the
/// held copy, so a caller keyed by id must honour the release first and find the removal a no-op.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SequencerStep {
    released: IdList<HELD_CAPACITY>,
    dropped: IdList<HELD_CAPACITY>,
}

impl SequencerStep {
    /// A fold that released nothing and dropped nothing.
    const fn empty() -> Self {
        Self {
            released: IdList::new(),
            dropped: IdList::new(),
        }
    }

    /// One id, released.
    fn only(frame_id: u32) -> Self {
        let mut step = Self::empty();
        step.released.push(frame_id);
        step
    }

    /// The ids the decoder should now see, in order.
    #[must_use]
    pub fn released(&self) -> &[u32] {
        self.released.slice()
    }

    /// The ids a keyframe made obsolete, which the caller can forget.
    #[must_use]
    pub fn dropped(&self) -> &[u32] {
        self.dropped.slice()
    }
}

/// IN-ORDER decode admission.
///
/// The reassembler completes frames in arrival and recovery order, not id order — its own reorder
/// grace describes the canonical case, where frame N−1 waits for late parity while frame N, small
/// enough to be one datagram, completes first. Submitting completion order straight to the decoder
/// lets N reference a not-yet-decoded N−1, which throws, tears the session down and forces a
/// keyframe: a freeze of roughly 150 ms for a frame that was about to complete anyway. Every hard
/// failure on a loss-free wire had the frontier two frames behind at submit — N−1 still pending —
/// which is exactly the case this closes.
///
/// Frames are released strictly in id order. One ahead of the expectation is HELD; the gap closes
/// when the missing frame completes or when the reassembler declares it lost, in which case the
/// hole is simply skipped and the gate drops non-anchors downstream, which is its job.
///
/// KEYFRAMES bypass ordering entirely. They reference nothing, and waiting on a pre-keyframe gap
/// would delay the very frame that heals it; held frames older than the keyframe are obsolete,
/// because the keyframe repaints everything, and are dropped.
///
/// The hold is BOUNDED. A gap that neither completes nor is declared trips an overflow valve — a
/// held count or an id span — and everything held is flushed in ascending order, which is the
/// pre-sequencer behaviour, rather than stalling the pane. The worst added hold on the unhappy path
/// is about a span of frame intervals, near 100 ms at 60 fps; the happy path of in-order
/// completions, which is the overwhelming norm, releases immediately at no cost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeSequencer {
    next_expected: Option<u32>,
    held: IdList<HELD_CAPACITY>,
    lost_ahead: IdList<LOST_CAPACITY>,
    max_held: usize,
    max_gap: i32,
}

impl Default for DecodeSequencer {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_HELD, DEFAULT_MAX_GAP)
    }
}

impl DecodeSequencer {
    /// A sequencer with its own valve settings, each floored so neither can be disabled and capped
    /// at [`MAX_VALVE`], which is what the state's capacity is proved against.
    #[must_use]
    pub const fn new(max_held: usize, max_gap: i32) -> Self {
        Self {
            next_expected: None,
            held: IdList::new(),
            lost_ahead: IdList::new(),
            max_held: clamp_valve_count(max_held),
            max_gap: clamp_valve_span(max_gap),
        }
    }

    /// The sequencer this state describes, so a caller holding it as data can fold into it again.
    ///
    /// The two sets arrive as the arrays they are; anything past their stated length is ignored,
    /// and the valves are re-clamped, so no crossing can hand back a state the law cannot hold.
    #[must_use]
    pub fn restored(snapshot: &DecodeSequencerSnapshot) -> Self {
        let mut sequencer = Self::new(snapshot.max_held, snapshot.max_gap);
        sequencer.next_expected = snapshot.next_expected;
        for &id in snapshot
            .held
            .get(..snapshot.held_len.min(HELD_CAPACITY))
            .unwrap_or(&[])
        {
            sequencer.held.insert_sorted(id);
        }
        for &id in snapshot
            .lost_ahead
            .get(..snapshot.lost_len.min(LOST_CAPACITY))
            .unwrap_or(&[])
        {
            sequencer.lost_ahead.insert_sorted(id);
        }
        sequencer
    }

    /// Everything a crossing has to carry for the next fold to answer the same way.
    #[must_use]
    pub const fn snapshot(&self) -> DecodeSequencerSnapshot {
        DecodeSequencerSnapshot {
            next_expected: self.next_expected,
            held: self.held.ids,
            held_len: self.held.len(),
            lost_ahead: self.lost_ahead.ids,
            lost_len: self.lost_ahead.len(),
            max_held: self.max_held,
            max_gap: self.max_gap,
        }
    }

    /// The next frame id the decoder should see, once the first release has anchored it.
    #[must_use]
    pub const fn next_expected(&self) -> Option<u32> {
        self.next_expected
    }

    /// The held-frame valve.
    #[must_use]
    pub const fn max_held(&self) -> usize {
        self.max_held
    }

    /// The id-span valve.
    #[must_use]
    pub const fn max_gap(&self) -> i32 {
        self.max_gap
    }

    /// Folds one reassembler completion, answering what is now releasable in id order.
    ///
    /// Possibly nothing, because the frame was held; possibly several, because it closed a gap.
    pub fn note_completed(&mut self, frame_id: u32, keyframe: bool) -> SequencerStep {
        let Some(expected) = self.next_expected else {
            // The session's first frame anchors the expectation.
            self.next_expected = Some(frame_id.wrapping_add(1));
            return SequencerStep::only(frame_id);
        };
        if keyframe {
            if distance_wrapped(frame_id, expected) >= 0 {
                let mut step = SequencerStep::only(frame_id);
                for &id in self.held.slice() {
                    if distance_wrapped(id, frame_id) <= 0 {
                        step.dropped.push(id);
                    }
                }
                self.held.retain(|id| distance_wrapped(id, frame_id) > 0);
                self.lost_ahead.retain(|id| distance_wrapped(id, frame_id) > 0);
                self.next_expected = Some(frame_id.wrapping_add(1));
                self.drain_contiguous(&mut step);
                return step;
            }
            // A stale straggler: release it and leave the expectation where it is.
            return SequencerStep::only(frame_id);
        }
        let distance = distance_wrapped(frame_id, expected);
        if distance < 0 {
            // Older than the expectation. Release it — the gate and the decoder decide — and never
            // let the expectation regress.
            return SequencerStep::only(frame_id);
        }
        if distance == 0 {
            self.next_expected = Some(expected.wrapping_add(1));
            let mut step = SequencerStep::only(frame_id);
            self.drain_contiguous(&mut step);
            return step;
        }
        self.held.insert_sorted(frame_id);
        if self.held.len() > self.max_held || distance > self.max_gap {
            return self.flush_all();
        }
        SequencerStep::empty()
    }

    /// Folds one loss declaration: the hole will never fill, so it is skipped.
    pub fn note_lost(&mut self, frame_id: u32) -> SequencerStep {
        let Some(expected) = self.next_expected else {
            return SequencerStep::empty();
        };
        let distance = distance_wrapped(frame_id, expected);
        if distance < 0 {
            return SequencerStep::empty(); // already behind the expectation
        }
        if distance == 0 {
            self.next_expected = Some(expected.wrapping_add(1));
            let mut step = SequencerStep::empty();
            self.drain_contiguous(&mut step);
            return step;
        }
        self.lost_ahead.insert_sorted(frame_id);
        // A loss can trip the span valve too: the gap is now known unfillable up to it.
        if self.lost_ahead.len() + self.held.len() > self.max_held + self.max_gap.unsigned_abs() as usize {
            return self.flush_all();
        }
        SequencerStep::empty()
    }

    /// Releases the contiguous run available at the expectation: held ids go, declared-lost ids are
    /// skipped, and the first true hole stops the run.
    fn drain_contiguous(&mut self, step: &mut SequencerStep) {
        while let Some(expected) = self.next_expected {
            if self.held.remove(expected) {
                step.released.push(expected);
                self.next_expected = Some(expected.wrapping_add(1));
            } else if self.lost_ahead.remove(expected) {
                self.next_expected = Some(expected.wrapping_add(1));
            } else {
                break;
            }
        }
    }

    /// The overflow valve: give up on the gap, release everything held in ascending order, and jump
    /// the expectation past all of it.
    fn flush_all(&mut self) -> SequencerStep {
        let mut step = SequencerStep::empty();
        self.held.sort_wrapped();
        for &id in self.held.slice() {
            step.released.push(id);
        }
        let past_lost = self
            .lost_ahead
            .newest_wrapped()
            .map(|newest| newest.wrapping_add(1));
        if let Some(&last) = step.released.slice().last() {
            let past_held = last.wrapping_add(1);
            self.next_expected = match past_lost {
                Some(lost) if distance_wrapped(lost, past_held) > 0 => Some(lost),
                _ => Some(past_held),
            };
        } else if let Some(lost) = past_lost {
            self.next_expected = Some(lost);
        }
        self.held.clear();
        self.lost_ahead.clear();
        step
    }
}

/// Both valve settings floored so neither can be disabled and capped at [`MAX_VALVE`].
const fn clamp_valve_count(max_held: usize) -> usize {
    if max_held < 1 {
        1
    } else if max_held > MAX_VALVE {
        MAX_VALVE
    } else {
        max_held
    }
}

/// The span valve, on the same band. It is signed because a distance is.
const fn clamp_valve_span(max_gap: i32) -> i32 {
    if max_gap < 1 {
        1
    } else if max_gap > MAX_VALVE_SPAN {
        MAX_VALVE_SPAN
    } else {
        max_gap
    }
}

/// Everything a sequencer crossing has to carry.
///
/// The two sets travel as the arrays they are, because a fold reads which specific ids are
/// outstanding — a count would not answer the same question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeSequencerSnapshot {
    /// The next frame id the decoder should see, if a release has anchored one.
    pub next_expected: Option<u32>,
    /// The held ids, ascending, the first `held_len` of them live.
    pub held: [u32; HELD_CAPACITY],
    /// How many held slots are live.
    pub held_len: usize,
    /// The declared-lost ids ahead of the expectation, ascending, the first `lost_len` live.
    pub lost_ahead: [u32; LOST_CAPACITY],
    /// How many lost slots are live.
    pub lost_len: usize,
    /// The held-count valve.
    pub max_held: usize,
    /// The id-span valve.
    pub max_gap: i32,
}

/// The pending-decode admission budget.
///
/// Every released frame is dispatched onto a decode queue holding the full compressed buffer, and
/// the decode itself is synchronous. One wedged decode — the documented background-suspend hang —
/// lets every later frame pile up at wire rate with no bound. Counting what is in flight lets the
/// caller drop a frame BEFORE dispatch once the stage saturates, routed through the same
/// drop-until-anchor gate and keyframe request as if it had been lost on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeAdmissionBudget {
    pending_count: usize,
    pending_bytes: usize,
    max_pending_count: usize,
    max_pending_bytes: usize,
}

impl Default for DecodeAdmissionBudget {
    /// The frame cap is generous: a healthy decode of a few milliseconds against a 33 ms arrival
    /// cadence keeps the stage near empty, and a post-stall burst of sequencer releases and
    /// retransmits can spike it briefly — past the cap, decode is genuinely not keeping up. The
    /// byte cap bounds the worst case of a few large keyframes queued behind a wedge.
    fn default() -> Self {
        Self::new(32, 16 << 20)
    }
}

impl DecodeAdmissionBudget {
    /// A budget with nothing in flight.
    #[must_use]
    pub const fn new(max_pending_count: usize, max_pending_bytes: usize) -> Self {
        Self {
            pending_count: 0,
            pending_bytes: 0,
            max_pending_count,
            max_pending_bytes,
        }
    }

    /// The budget this state describes, so a caller holding it as data can fold into it again.
    #[must_use]
    pub const fn restored(
        pending_count: usize,
        pending_bytes: usize,
        max_pending_count: usize,
        max_pending_bytes: usize,
    ) -> Self {
        Self {
            pending_count,
            pending_bytes,
            max_pending_count,
            max_pending_bytes,
        }
    }

    /// Frames dispatched and not yet completed.
    #[must_use]
    pub const fn pending_count(&self) -> usize {
        self.pending_count
    }

    /// Compressed bytes dispatched and not yet completed.
    #[must_use]
    pub const fn pending_bytes(&self) -> usize {
        self.pending_bytes
    }

    /// The frame cap.
    #[must_use]
    pub const fn max_pending_count(&self) -> usize {
        self.max_pending_count
    }

    /// The byte cap.
    #[must_use]
    pub const fn max_pending_bytes(&self) -> usize {
        self.max_pending_bytes
    }

    /// Admits one compressed frame onto the decode queue.
    ///
    /// False means the stage is saturated: drop the frame before dispatch and arm the recovery
    /// path, and the stream re-syncs on the next admitted anchor.
    ///
    /// An IDLE stage ALWAYS admits, whatever the size. The budget bounds QUEUED work, and a frame
    /// whose size alone exceeds the byte cap — an extreme recovery keyframe, or an inflated
    /// mis-recovered reassembly — would otherwise be refused forever, since every replacement is
    /// the same size class, and the pane would livelock with the decode stage sitting empty.
    pub const fn admit(&mut self, bytes: usize) -> bool {
        if self.pending_count > 0
            && (self.pending_count >= self.max_pending_count
                || self.pending_bytes + bytes > self.max_pending_bytes)
        {
            return false;
        }
        self.pending_count += 1;
        self.pending_bytes += bytes;
        true
    }

    /// One admitted frame finished, whether it decoded or failed — the work left the queue either
    /// way. Saturating, so an unpaired call can never wedge the budget.
    pub const fn complete(&mut self, bytes: usize) {
        self.pending_count = self.pending_count.saturating_sub(1);
        self.pending_bytes = self.pending_bytes.saturating_sub(bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DecodeAdmissionBudget, DecodeFrontier, DecodeGate, DecodeSequencer, GateMode, GateVerdict, MAX_VALVE,
        SequencerStep,
    };
    use crate::recovery::NO_FRAME_DECODED_SENTINEL;

    /// Every completion in these tests is a delta unless it says otherwise.
    fn completed(sequencer: &mut DecodeSequencer, frame_id: u32) -> SequencerStep {
        sequencer.note_completed(frame_id, false)
    }

    #[test]
    fn the_frontier_only_ever_advances() {
        let mut frontier = DecodeFrontier::new();
        assert_eq!(frontier.wire_value(), NO_FRAME_DECODED_SENTINEL);
        frontier.note_decoded(10);
        frontier.note_decoded(7);
        assert_eq!(frontier.wire_value(), 10, "a late decode never walks it back");
        frontier.note_decoded(11);
        assert_eq!(frontier.last_decoded_frame_id(), Some(11));
    }

    /// Frame ids start at zero, so zero must be a real frontier rather than "nothing yet".
    #[test]
    fn frame_zero_is_a_frontier_and_not_the_sentinel() {
        let mut frontier = DecodeFrontier::new();
        frontier.note_decoded(0);
        assert_eq!(frontier.wire_value(), 0);
    }

    #[test]
    fn the_frontier_advances_across_the_wrap() {
        let mut frontier = DecodeFrontier::new();
        frontier.note_decoded(u32::MAX - 1);
        frontier.note_decoded(3);
        assert_eq!(frontier.last_decoded_frame_id(), Some(3));
    }

    #[test]
    fn an_intact_chain_submits_everything() {
        let gate = DecodeGate::new();
        assert_eq!(gate.verdict(5, false, false), GateVerdict::Submit);
    }

    /// The amplification this gate exists to stop: one loss, then a failure per delta.
    #[test]
    fn a_broken_chain_admits_only_anchors() {
        let mut gate = DecodeGate::new();
        gate.note_loss(10);
        assert_eq!(gate.mode(), GateMode::BrokenChain);
        assert_eq!(gate.verdict(11, false, false), GateVerdict::Drop);
        assert_eq!(gate.verdict(11, true, false), GateVerdict::Submit);
        assert_eq!(
            gate.verdict(11, false, true),
            GateVerdict::Submit,
            "an acked-anchored refresh references only what this client decoded",
        );
        assert_eq!(
            gate.verdict(9, false, false),
            GateVerdict::Submit,
            "a pre-break delta still in flight references nothing lost",
        );
    }

    /// A torn-down session has no reference buffer left, so a refresh has nothing to anchor on.
    #[test]
    fn a_torn_down_session_takes_a_keyframe_and_nothing_else() {
        let mut gate = DecodeGate::new();
        gate.note_loss(10);
        gate.note_hard_decode_failure();
        assert_eq!(gate.verdict(11, false, true), GateVerdict::Drop);
        assert_eq!(gate.verdict(9, false, false), GateVerdict::Drop);
        assert_eq!(gate.verdict(11, true, false), GateVerdict::Submit);
    }

    #[test]
    fn a_loss_never_downgrades_a_torn_down_session() {
        let mut gate = DecodeGate::new();
        gate.note_awaiting_keyframe();
        gate.note_loss(10);
        assert_eq!(gate.mode(), GateMode::NeedKeyframe);
    }

    #[test]
    fn a_keyframe_past_every_loss_reopens_the_gate() {
        let mut gate = DecodeGate::new();
        gate.note_loss(10);
        gate.note_decode_succeeded(11, true);
        assert_eq!(gate.mode(), GateMode::Open);
        assert_eq!(gate.max_lost_frame_id(), None);
    }

    #[test]
    fn a_non_keyframe_past_every_loss_is_the_healed_anchor() {
        let mut gate = DecodeGate::new();
        gate.note_loss(10);
        gate.note_decode_succeeded(9, false);
        assert_eq!(gate.mode(), GateMode::BrokenChain, "not past the loss yet");
        gate.note_decode_succeeded(11, false);
        assert_eq!(gate.mode(), GateMode::Open);
    }

    /// The churn a stale keyframe would otherwise restart on a torn-down session.
    #[test]
    fn a_stale_keyframe_reanchors_a_live_session_but_not_a_torn_down_one() {
        let mut live = DecodeGate::new();
        live.note_loss(10);
        live.note_decode_succeeded(8, true);
        assert_eq!(live.mode(), GateMode::BrokenChain);
        assert_eq!(
            live.verdict(11, false, true),
            GateVerdict::Submit,
            "the pre-loss acked references survived in the decoder",
        );

        let mut torn = DecodeGate::new();
        torn.note_loss(10);
        torn.note_hard_decode_failure();
        torn.note_decode_succeeded(8, true);
        assert_eq!(torn.mode(), GateMode::NeedKeyframe);
        assert_eq!(
            torn.verdict(11, false, true),
            GateVerdict::Drop,
            "nothing pre-teardown survived to anchor against",
        );
    }

    #[test]
    fn the_first_frame_anchors_the_expectation_wherever_it_starts() {
        let mut sequencer = DecodeSequencer::default();
        assert_eq!(sequencer.note_completed(100, true).released(), [100]);
        assert_eq!(sequencer.next_expected(), Some(101));
    }

    /// The canonical reorder: a small frame completes while its predecessor waits for parity.
    #[test]
    fn a_frame_ahead_of_a_gap_waits_for_it_and_then_both_release_in_order() {
        let mut sequencer = DecodeSequencer::default();
        sequencer.note_completed(0, true);
        assert!(completed(&mut sequencer, 2).released().is_empty());
        assert_eq!(
            completed(&mut sequencer, 1).released(),
            [1, 2],
            "the gap closing releases the run",
        );
        assert_eq!(sequencer.next_expected(), Some(3));
    }

    #[test]
    fn a_declared_loss_skips_the_hole_and_releases_what_was_behind_it() {
        let mut sequencer = DecodeSequencer::default();
        sequencer.note_completed(0, true);
        completed(&mut sequencer, 2);
        completed(&mut sequencer, 3);
        assert_eq!(sequencer.note_lost(1).released(), [2, 3]);
    }

    #[test]
    fn a_loss_declared_ahead_of_the_expectation_is_remembered_until_the_run_reaches_it() {
        let mut sequencer = DecodeSequencer::default();
        sequencer.note_completed(0, true);
        assert!(sequencer.note_lost(2).released().is_empty());
        assert_eq!(
            completed(&mut sequencer, 1).released(),
            [1],
            "frame 2 is a hole the run steps over",
        );
        assert_eq!(sequencer.next_expected(), Some(3));
    }

    /// Waiting on a pre-keyframe gap would delay the very frame that heals it.
    #[test]
    fn a_keyframe_bypasses_the_ordering_and_drops_what_it_makes_obsolete() {
        let mut sequencer = DecodeSequencer::default();
        completed(&mut sequencer, 0);
        completed(&mut sequencer, 2); // held behind the gap at 1
        let step = sequencer.note_completed(4, true);
        assert_eq!(step.released(), [4]);
        assert_eq!(
            step.dropped(),
            [2],
            "the keyframe repaints what was held behind it"
        );
        assert_eq!(sequencer.next_expected(), Some(5));
        assert_eq!(
            completed(&mut sequencer, 1).released(),
            [1],
            "a straggler older than the expectation releases without holding anything up",
        );
    }

    #[test]
    fn the_held_count_valve_flushes_rather_than_stalling_the_pane() {
        let mut sequencer = DecodeSequencer::new(2, 100);
        sequencer.note_completed(0, true);
        assert!(completed(&mut sequencer, 2).released().is_empty());
        assert!(completed(&mut sequencer, 3).released().is_empty());
        assert_eq!(
            completed(&mut sequencer, 4).released(),
            [2, 3, 4],
            "everything held, in ascending order",
        );
        assert_eq!(sequencer.next_expected(), Some(5));
    }

    #[test]
    fn the_id_span_valve_flushes_a_gap_that_is_simply_too_far_ahead() {
        let mut sequencer = DecodeSequencer::new(100, 3);
        sequencer.note_completed(0, true);
        assert_eq!(completed(&mut sequencer, 9).released(), [9]);
        assert_eq!(sequencer.next_expected(), Some(10));
    }

    #[test]
    fn a_flush_jumps_the_expectation_past_the_losses_it_gave_up_on_too() {
        let mut sequencer = DecodeSequencer::new(2, 100);
        sequencer.note_completed(0, true);
        sequencer.note_lost(7);
        completed(&mut sequencer, 2);
        completed(&mut sequencer, 3);
        assert_eq!(completed(&mut sequencer, 4).released(), [2, 3, 4]);
        assert_eq!(
            sequencer.next_expected(),
            Some(8),
            "past the newest thing it knows about, held or lost",
        );
    }

    /// Patience past the band is a frozen pane, so the valves stop there — and the state's
    /// capacity is proved against exactly that ceiling.
    #[test]
    fn the_valves_clamp_to_the_band_the_capacity_is_proved_against() {
        let wide = DecodeSequencer::new(usize::MAX, i32::MAX);
        assert_eq!(wide.max_held(), MAX_VALVE);
        assert_eq!(wide.max_gap(), i32::try_from(MAX_VALVE).unwrap_or(1));
        let narrow = DecodeSequencer::new(0, 0);
        assert_eq!(narrow.max_held(), 1, "neither valve can be disabled");
        assert_eq!(narrow.max_gap(), 1);
    }

    /// The sets are the state: a fold reads which ids are outstanding, not how many.
    #[test]
    fn a_sequencer_survives_the_round_trip_through_its_own_snapshot() {
        let mut sequencer = DecodeSequencer::default();
        sequencer.note_completed(0, true);
        completed(&mut sequencer, 2);
        sequencer.note_lost(4);
        let carried = DecodeSequencer::restored(&sequencer.snapshot());
        assert_eq!(carried, sequencer);
        let mut original = sequencer;
        let mut copy = carried;
        assert_eq!(
            completed(&mut original, 1).released(),
            completed(&mut copy, 1).released(),
            "the same next fold, because the same ids were outstanding",
        );
        assert_eq!(original.next_expected(), copy.next_expected());
    }

    #[test]
    fn an_idle_stage_admits_a_frame_that_alone_exceeds_the_byte_cap() {
        let mut budget = DecodeAdmissionBudget::new(32, 1024);
        assert!(budget.admit(4096), "otherwise every replacement livelocks");
        assert_eq!(budget.pending_bytes(), 4096);
        assert!(!budget.admit(1), "and the queue is now over budget");
    }

    #[test]
    fn a_saturated_stage_refuses_before_dispatch() {
        let mut budget = DecodeAdmissionBudget::new(2, 1 << 20);
        assert!(budget.admit(10));
        assert!(budget.admit(10));
        assert!(!budget.admit(10));
        budget.complete(10);
        assert!(budget.admit(10), "a completion frees the slot");
    }

    #[test]
    fn an_unpaired_completion_cannot_wedge_the_budget_negative() {
        let mut budget = DecodeAdmissionBudget::default();
        budget.complete(999);
        assert_eq!(budget.pending_count(), 0);
        assert_eq!(budget.pending_bytes(), 0);
        assert!(budget.admit(10));
    }
}
