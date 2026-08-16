//! What the client's decoder is allowed to see, and in what order.
//!
//! Four values, all of them folds the caller copies out, folds into and writes back, so all four
//! cross BY VALUE. Three are a handful of scalars. The fourth is the sequencer, and it is the one
//! worth a paragraph.
//!
//! ## The sequencer moves IDS, and the caller keeps the bytes
//!
//! The ordering law never reads a compressed byte — it is a function of frame ids and one keyframe
//! bit — so the door takes an id and answers with ids: which are releasable now, in order, and
//! which a keyframe has made obsolete. The near side keeps its own frames keyed by id and looks
//! them up. Handing megabytes of compressed video to a law that does not inspect them would be a
//! copy per frame, twice, for nothing.
//!
//! It follows that the near side keys a bag of frames by id, and the two answers say what to do
//! with it: RELEASE first, then FORGET. An id can be in both lists exactly once — a duplicate
//! keyframe that was already held releases as the new arrival and drops as the held copy — and in
//! that order the removal is the no-op it should be.
//!
//! ## Why the SETS travel
//!
//! Which specific ids are outstanding is what the next fold reads: the run at the expectation, the
//! holes it steps over, the flush order. A count would not answer any of those. Both valves bound
//! how much can be outstanding, so both sets cross as fixed-capacity arrays whose capacity is the
//! CEILING of the valves' own band — no legal setting is ever truncated.

use slopdesk_video::decode_admission::{
    DEFAULT_MAX_GAP, DEFAULT_MAX_HELD, DecodeAdmissionBudget, DecodeFrontier, DecodeGate, DecodeSequencer,
    DecodeSequencerSnapshot, GateMode, GateVerdict, HELD_CAPACITY, LOST_CAPACITY, MAX_VALVE,
};

use crate::{optional, optional_of};

/// The chain is intact and everything submits.
pub const SLOPDESK_GATE_MODE_OPEN: u32 = 0;
/// At least one unrecoverable loss since the last anchor, with the decoder session alive.
pub const SLOPDESK_GATE_MODE_BROKEN_CHAIN: u32 = 1;
/// The decoder session is gone, so only a keyframe can re-anchor.
pub const SLOPDESK_GATE_MODE_NEED_KEYFRAME: u32 = 2;

/// The mode as a plain code.
const fn mode_code(mode: GateMode) -> u32 {
    match mode {
        GateMode::Open => SLOPDESK_GATE_MODE_OPEN,
        GateMode::BrokenChain => SLOPDESK_GATE_MODE_BROKEN_CHAIN,
        GateMode::NeedKeyframe => SLOPDESK_GATE_MODE_NEED_KEYFRAME,
    }
}

/// The inverse of [`mode_code`]. An unknown code cannot arise from this door and reads as the mode
/// a fresh gate holds.
const fn mode_of(code: u32) -> GateMode {
    match code {
        SLOPDESK_GATE_MODE_BROKEN_CHAIN => GateMode::BrokenChain,
        SLOPDESK_GATE_MODE_NEED_KEYFRAME => GateMode::NeedKeyframe,
        _ => GateMode::Open,
    }
}

// MARK: the frontier

/// The highest frame that successfully decoded, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeFrontier {
    /// Whether anything has decoded at all.
    pub has_last_decoded: bool,
    /// The frontier itself.
    pub last_decoded_frame_id: u32,
}

impl SlopDeskDecodeFrontier {
    /// The wrapped frontier this describes.
    const fn inner(self) -> DecodeFrontier {
        DecodeFrontier::restored(optional_of(self.has_last_decoded, self.last_decoded_frame_id))
    }

    /// The crossing form of a wrapped frontier.
    const fn of(frontier: DecodeFrontier) -> Self {
        let (has_last_decoded, last_decoded_frame_id) = optional(frontier.last_decoded_frame_id(), 0);
        Self {
            has_last_decoded,
            last_decoded_frame_id,
        }
    }
}

/// A client that has decoded nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_frontier_new() -> SlopDeskDecodeFrontier {
    SlopDeskDecodeFrontier::of(DecodeFrontier::new())
}

/// Folds one successfully decoded frame, keeping the newest.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_frontier_note_decoded(
    frontier: SlopDeskDecodeFrontier,
    frame_id: u32,
) -> SlopDeskDecodeFrontier {
    let mut inner = frontier.inner();
    inner.note_decoded(frame_id);
    SlopDeskDecodeFrontier::of(inner)
}

/// The on-wire field: the frontier, or the sentinel when nothing has decoded.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_frontier_wire_value(frontier: SlopDeskDecodeFrontier) -> u32 {
    frontier.inner().wire_value()
}

// MARK: the gate

/// The drop-until-anchor admission state, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeGate {
    /// One of the `SLOPDESK_GATE_MODE_*` codes.
    pub mode: u32,
    /// Whether the episode has an oldest loss.
    pub has_min_lost: bool,
    /// The OLDEST loss of the episode. The chain is intact strictly before it.
    pub min_lost_frame_id: u32,
    /// Whether the episode has a newest loss.
    pub has_max_lost: bool,
    /// The NEWEST loss of the episode. An anchor must decode strictly past it.
    pub max_lost_frame_id: u32,
}

impl SlopDeskDecodeGate {
    /// The wrapped gate this describes.
    const fn inner(self) -> DecodeGate {
        DecodeGate::restored(
            mode_of(self.mode),
            optional_of(self.has_min_lost, self.min_lost_frame_id),
            optional_of(self.has_max_lost, self.max_lost_frame_id),
        )
    }

    /// The crossing form of a wrapped gate.
    const fn of(gate: DecodeGate) -> Self {
        let (has_min_lost, min_lost_frame_id) = optional(gate.min_lost_frame_id(), 0);
        let (has_max_lost, max_lost_frame_id) = optional(gate.max_lost_frame_id(), 0);
        Self {
            mode: mode_code(gate.mode()),
            has_min_lost,
            min_lost_frame_id,
            has_max_lost,
            max_lost_frame_id,
        }
    }
}

/// A gate over an intact chain.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_gate_new() -> SlopDeskDecodeGate {
    SlopDeskDecodeGate::of(DecodeGate::new())
}

/// Folds one unrecoverably lost frame, opening the episode.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_gate_note_loss(
    gate: SlopDeskDecodeGate,
    frame_id: u32,
) -> SlopDeskDecodeGate {
    let mut inner = gate.inner();
    inner.note_loss(frame_id);
    SlopDeskDecodeGate::of(inner)
}

/// A hard decode failure tore the session down — only a keyframe helps now.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_gate_note_hard_decode_failure(
    gate: SlopDeskDecodeGate,
) -> SlopDeskDecodeGate {
    let mut inner = gate.inner();
    inner.note_hard_decode_failure();
    SlopDeskDecodeGate::of(inner)
}

/// The decoder has no session or parameter sets yet, which takes the same anchor set.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_gate_note_awaiting_keyframe(
    gate: SlopDeskDecodeGate,
) -> SlopDeskDecodeGate {
    let mut inner = gate.inner();
    inner.note_awaiting_keyframe();
    SlopDeskDecodeGate::of(inner)
}

/// Whether one reassembled frame reaches the decoder. True submits, false drops.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_gate_submits(
    gate: SlopDeskDecodeGate,
    frame_id: u32,
    keyframe: bool,
    acked_anchored: bool,
) -> bool {
    matches!(
        gate.inner().verdict(frame_id, keyframe, acked_anchored),
        GateVerdict::Submit
    )
}

/// Folds one SUCCESSFUL decode.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_gate_note_decode_succeeded(
    gate: SlopDeskDecodeGate,
    frame_id: u32,
    keyframe: bool,
) -> SlopDeskDecodeGate {
    let mut inner = gate.inner();
    inner.note_decode_succeeded(frame_id, keyframe);
    SlopDeskDecodeGate::of(inner)
}

// MARK: the sequencer

/// The in-order admission state, as it crosses. Both sets travel; see the module header.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeSequencer {
    /// Whether a release has anchored the expectation.
    pub has_next_expected: bool,
    /// The next frame id the decoder should see.
    pub next_expected: u32,
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

impl SlopDeskDecodeSequencer {
    /// The wrapped sequencer this describes.
    fn inner(&self) -> DecodeSequencer {
        DecodeSequencer::restored(&DecodeSequencerSnapshot {
            next_expected: optional_of(self.has_next_expected, self.next_expected),
            held: self.held,
            held_len: self.held_len,
            lost_ahead: self.lost_ahead,
            lost_len: self.lost_len,
            max_held: self.max_held,
            max_gap: self.max_gap,
        })
    }

    /// The crossing form of a wrapped sequencer.
    const fn of(sequencer: &DecodeSequencer) -> Self {
        let snapshot = sequencer.snapshot();
        let (has_next_expected, next_expected) = optional(snapshot.next_expected, 0);
        Self {
            has_next_expected,
            next_expected,
            held: snapshot.held,
            held_len: snapshot.held_len,
            lost_ahead: snapshot.lost_ahead,
            lost_len: snapshot.lost_len,
            max_held: snapshot.max_held,
            max_gap: snapshot.max_gap,
        }
    }
}

/// One fold of the sequencer: the state that results, and what to do with the caller's frames.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeSequencerStep {
    /// The sequencer after the fold.
    pub sequencer: SlopDeskDecodeSequencer,
    /// The ids the decoder should now see, in order, the first `released_len` live.
    pub released: [u32; HELD_CAPACITY],
    /// How many released slots are live.
    pub released_len: usize,
    /// The ids a keyframe made obsolete, the first `dropped_len` live. Honour these AFTER the
    /// releases: one id can be in both lists, and in that order the removal is a no-op.
    pub dropped: [u32; HELD_CAPACITY],
    /// How many dropped slots are live.
    pub dropped_len: usize,
}

impl SlopDeskDecodeSequencerStep {
    /// The crossing form of one fold.
    fn of(sequencer: &DecodeSequencer, released: &[u32], dropped: &[u32]) -> Self {
        let mut step = Self {
            sequencer: SlopDeskDecodeSequencer::of(sequencer),
            released: [0; HELD_CAPACITY],
            released_len: 0,
            dropped: [0; HELD_CAPACITY],
            dropped_len: 0,
        };
        for (slot, &id) in step.released.iter_mut().zip(released) {
            *slot = id;
            step.released_len += 1;
        }
        for (slot, &id) in step.dropped.iter_mut().zip(dropped) {
            *slot = id;
            step.dropped_len += 1;
        }
        step
    }
}

/// The law's fixed numbers, so the near side spells none of them.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeSequencerConstants {
    /// The stock held-frame valve.
    pub default_max_held: usize,
    /// The stock id-span valve.
    pub default_max_gap: i32,
    /// The ceiling both valves clamp to, which is what the capacities are proved against.
    pub max_valve: usize,
    /// How many held or released ids one crossing can carry.
    pub held_capacity: usize,
    /// How many declared-lost ids one crossing can carry.
    pub lost_capacity: usize,
}

/// The law's fixed numbers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_sequencer_constants() -> SlopDeskDecodeSequencerConstants {
    SlopDeskDecodeSequencerConstants {
        default_max_held: DEFAULT_MAX_HELD,
        default_max_gap: DEFAULT_MAX_GAP,
        max_valve: MAX_VALVE,
        held_capacity: HELD_CAPACITY,
        lost_capacity: LOST_CAPACITY,
    }
}

/// A sequencer with its own valve settings, each floored so neither can be disabled and capped at
/// the band the state's capacity is proved against.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_sequencer_new(
    max_held: usize,
    max_gap: i32,
) -> SlopDeskDecodeSequencer {
    SlopDeskDecodeSequencer::of(&DecodeSequencer::new(max_held, max_gap))
}

/// Folds one reassembler completion, answering what is now releasable in id order.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_sequencer_note_completed(
    sequencer: &SlopDeskDecodeSequencer,
    frame_id: u32,
    keyframe: bool,
) -> SlopDeskDecodeSequencerStep {
    let mut inner = sequencer.inner();
    let step = inner.note_completed(frame_id, keyframe);
    SlopDeskDecodeSequencerStep::of(&inner, step.released(), step.dropped())
}

/// Folds one loss declaration: the hole will never fill, so it is skipped.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_sequencer_note_lost(
    sequencer: &SlopDeskDecodeSequencer,
    frame_id: u32,
) -> SlopDeskDecodeSequencerStep {
    let mut inner = sequencer.inner();
    let step = inner.note_lost(frame_id);
    SlopDeskDecodeSequencerStep::of(&inner, step.released(), step.dropped())
}

// MARK: the budget

/// The pending-decode admission budget, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeBudget {
    /// Frames dispatched and not yet completed.
    pub pending_count: usize,
    /// Compressed bytes dispatched and not yet completed.
    pub pending_bytes: usize,
    /// The frame cap.
    pub max_pending_count: usize,
    /// The byte cap.
    pub max_pending_bytes: usize,
}

impl SlopDeskDecodeBudget {
    /// The wrapped budget this describes.
    const fn inner(self) -> DecodeAdmissionBudget {
        DecodeAdmissionBudget::restored(
            self.pending_count,
            self.pending_bytes,
            self.max_pending_count,
            self.max_pending_bytes,
        )
    }

    /// The crossing form of a wrapped budget.
    const fn of(budget: DecodeAdmissionBudget) -> Self {
        Self {
            pending_count: budget.pending_count(),
            pending_bytes: budget.pending_bytes(),
            max_pending_count: budget.max_pending_count(),
            max_pending_bytes: budget.max_pending_bytes(),
        }
    }
}

/// One admission decision: the budget that results, and whether the frame may be dispatched.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDecodeBudgetAdmit {
    /// The budget after the decision.
    pub budget: SlopDeskDecodeBudget,
    /// Whether the caller may dispatch. False means drop before dispatch and arm recovery.
    pub admitted: bool,
}

/// The operating point the budget ships with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_budget_default() -> SlopDeskDecodeBudget {
    SlopDeskDecodeBudget::of(DecodeAdmissionBudget::default())
}

/// A budget with nothing in flight and caps of the caller's choosing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_budget_new(
    max_pending_count: usize,
    max_pending_bytes: usize,
) -> SlopDeskDecodeBudget {
    SlopDeskDecodeBudget::of(DecodeAdmissionBudget::new(max_pending_count, max_pending_bytes))
}

/// Admits one compressed frame onto the decode queue.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_budget_admit(
    budget: SlopDeskDecodeBudget,
    bytes: usize,
) -> SlopDeskDecodeBudgetAdmit {
    let mut inner = budget.inner();
    let admitted = inner.admit(bytes);
    SlopDeskDecodeBudgetAdmit {
        budget: SlopDeskDecodeBudget::of(inner),
        admitted,
    }
}

/// One admitted frame finished, whether it decoded or failed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_decode_budget_complete(
    budget: SlopDeskDecodeBudget,
    bytes: usize,
) -> SlopDeskDecodeBudget {
    let mut inner = budget.inner();
    inner.complete(bytes);
    SlopDeskDecodeBudget::of(inner)
}

/// Whether two sequencers are the same state.
///
/// The sets make this the one comparison the near side cannot spell for itself: a C array is a
/// tuple over there, and a tuple that long has no equality.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_decode_sequencer_eq(
    left: &SlopDeskDecodeSequencer,
    right: &SlopDeskDecodeSequencer,
) -> bool {
    left.inner() == right.inner()
}

#[cfg(test)]
mod tests {
    use super::{
        SLOPDESK_GATE_MODE_BROKEN_CHAIN, SLOPDESK_GATE_MODE_NEED_KEYFRAME, SLOPDESK_GATE_MODE_OPEN,
        SlopDeskDecodeSequencer, SlopDeskDecodeSequencerStep, slopdesk_decode_budget_admit,
        slopdesk_decode_budget_complete, slopdesk_decode_budget_default, slopdesk_decode_budget_new,
        slopdesk_decode_frontier_new, slopdesk_decode_frontier_note_decoded,
        slopdesk_decode_frontier_wire_value, slopdesk_decode_gate_new,
        slopdesk_decode_gate_note_awaiting_keyframe, slopdesk_decode_gate_note_decode_succeeded,
        slopdesk_decode_gate_note_hard_decode_failure, slopdesk_decode_gate_note_loss,
        slopdesk_decode_gate_submits, slopdesk_decode_sequencer_constants, slopdesk_decode_sequencer_eq,
        slopdesk_decode_sequencer_new, slopdesk_decode_sequencer_note_completed,
        slopdesk_decode_sequencer_note_lost,
    };

    /// The live prefix of a step's releases.
    fn released(step: &SlopDeskDecodeSequencerStep) -> &[u32] {
        step.released.get(..step.released_len).unwrap_or(&[])
    }

    /// The live prefix of a step's drops.
    fn dropped(step: &SlopDeskDecodeSequencerStep) -> &[u32] {
        step.dropped.get(..step.dropped_len).unwrap_or(&[])
    }

    /// One delta completion, folded in place.
    fn complete(sequencer: &mut SlopDeskDecodeSequencer, frame_id: u32) -> SlopDeskDecodeSequencerStep {
        let step = slopdesk_decode_sequencer_note_completed(sequencer, frame_id, false);
        *sequencer = step.sequencer;
        step
    }

    /// One loss declaration, folded in place.
    fn lose(sequencer: &mut SlopDeskDecodeSequencer, frame_id: u32) -> SlopDeskDecodeSequencerStep {
        let step = slopdesk_decode_sequencer_note_lost(sequencer, frame_id);
        *sequencer = step.sequencer;
        step
    }

    /// A stock sequencer, anchored on a keyframe at zero.
    fn anchored() -> SlopDeskDecodeSequencer {
        let constants = slopdesk_decode_sequencer_constants();
        let fresh = slopdesk_decode_sequencer_new(constants.default_max_held, constants.default_max_gap);
        slopdesk_decode_sequencer_note_completed(&fresh, 0, true).sequencer
    }

    #[test]
    fn the_frontier_only_ever_advances_and_zero_is_not_the_sentinel() {
        let empty = slopdesk_decode_frontier_new();
        assert!(!empty.has_last_decoded);
        assert_ne!(
            slopdesk_decode_frontier_wire_value(empty),
            0,
            "the sentinel is not a frame"
        );
        let zero = slopdesk_decode_frontier_note_decoded(empty, 0);
        assert_eq!(slopdesk_decode_frontier_wire_value(zero), 0);
        let ten = slopdesk_decode_frontier_note_decoded(zero, 10);
        assert_eq!(
            slopdesk_decode_frontier_note_decoded(ten, 7).last_decoded_frame_id,
            10,
            "a late decode never walks it back",
        );
    }

    #[test]
    fn the_gate_admits_only_anchors_once_the_chain_is_broken() {
        let open = slopdesk_decode_gate_new();
        assert_eq!(open.mode, SLOPDESK_GATE_MODE_OPEN);
        assert!(slopdesk_decode_gate_submits(open, 5, false, false));

        let broken = slopdesk_decode_gate_note_loss(open, 10);
        assert_eq!(broken.mode, SLOPDESK_GATE_MODE_BROKEN_CHAIN);
        assert!(!slopdesk_decode_gate_submits(broken, 11, false, false));
        assert!(slopdesk_decode_gate_submits(broken, 11, true, false));
        assert!(
            slopdesk_decode_gate_submits(broken, 11, false, true),
            "an acked-anchored refresh references only what this client decoded",
        );
        assert!(
            slopdesk_decode_gate_submits(broken, 9, false, false),
            "a pre-break delta still in flight references nothing lost",
        );

        let torn = slopdesk_decode_gate_note_hard_decode_failure(broken);
        assert_eq!(torn.mode, SLOPDESK_GATE_MODE_NEED_KEYFRAME);
        assert!(!slopdesk_decode_gate_submits(torn, 11, false, true));
        assert!(slopdesk_decode_gate_submits(torn, 11, true, false));
    }

    #[test]
    fn a_stale_keyframe_reanchors_a_live_session_but_not_a_torn_down_one() {
        let broken = slopdesk_decode_gate_note_loss(slopdesk_decode_gate_new(), 10);
        let live = slopdesk_decode_gate_note_decode_succeeded(broken, 8, true);
        assert_eq!(live.mode, SLOPDESK_GATE_MODE_BROKEN_CHAIN);
        assert!(slopdesk_decode_gate_submits(live, 11, false, true));

        let torn = slopdesk_decode_gate_note_decode_succeeded(
            slopdesk_decode_gate_note_hard_decode_failure(broken),
            8,
            true,
        );
        assert_eq!(torn.mode, SLOPDESK_GATE_MODE_NEED_KEYFRAME);
        assert!(
            !slopdesk_decode_gate_submits(torn, 11, false, true),
            "nothing pre-teardown survived to anchor against",
        );

        let healed = slopdesk_decode_gate_note_decode_succeeded(broken, 11, false);
        assert_eq!(healed.mode, SLOPDESK_GATE_MODE_OPEN);
        assert!(!healed.has_max_lost);
    }

    #[test]
    fn a_loss_never_downgrades_a_torn_down_session() {
        let awaiting = slopdesk_decode_gate_note_awaiting_keyframe(slopdesk_decode_gate_new());
        assert_eq!(
            slopdesk_decode_gate_note_loss(awaiting, 10).mode,
            SLOPDESK_GATE_MODE_NEED_KEYFRAME,
        );
    }

    /// The canonical reorder: a small frame completes while its predecessor waits for parity.
    #[test]
    fn the_whole_set_crosses_so_a_gap_closing_releases_the_run() {
        let mut sequencer = anchored();
        assert!(released(&complete(&mut sequencer, 2)).is_empty());
        assert_eq!(
            sequencer.held_len, 1,
            "the id is outstanding, and the crossing says which"
        );
        assert_eq!(released(&complete(&mut sequencer, 1)), [1, 2]);
        assert_eq!(sequencer.next_expected, 3);
        assert_eq!(sequencer.held_len, 0);
    }

    #[test]
    fn a_declared_loss_skips_the_hole_and_releases_what_was_behind_it() {
        let mut sequencer = anchored();
        complete(&mut sequencer, 2);
        complete(&mut sequencer, 3);
        assert_eq!(released(&lose(&mut sequencer, 1)), [2, 3]);
    }

    #[test]
    fn a_keyframe_bypasses_the_ordering_and_names_what_it_made_obsolete() {
        let mut sequencer = anchored();
        complete(&mut sequencer, 1);
        complete(&mut sequencer, 3); // held behind the gap at 2
        let step = slopdesk_decode_sequencer_note_completed(&sequencer, 5, true);
        assert_eq!(released(&step), [5]);
        assert_eq!(dropped(&step), [3], "the caller can forget that frame's bytes");
        assert_eq!(step.sequencer.next_expected, 6);
    }

    #[test]
    fn the_valves_flush_rather_than_stalling_the_pane() {
        let tight = slopdesk_decode_sequencer_new(2, 100);
        let mut sequencer = slopdesk_decode_sequencer_note_completed(&tight, 0, true).sequencer;
        assert!(released(&complete(&mut sequencer, 2)).is_empty());
        assert!(released(&complete(&mut sequencer, 3)).is_empty());
        assert_eq!(
            released(&complete(&mut sequencer, 4)),
            [2, 3, 4],
            "everything held, in ascending order",
        );
        assert_eq!(sequencer.next_expected, 5);
    }

    #[test]
    fn the_valves_clamp_to_the_band_the_capacity_is_proved_against() {
        let constants = slopdesk_decode_sequencer_constants();
        let wide = slopdesk_decode_sequencer_new(usize::MAX, i32::MAX);
        assert_eq!(wide.max_held, constants.max_valve);
        assert_eq!(wide.max_gap, i32::try_from(constants.max_valve).unwrap_or(1));
        assert_eq!(constants.held_capacity, constants.max_valve + 1);
        assert_eq!(constants.lost_capacity, 2 * constants.max_valve + 1);
        let narrow = slopdesk_decode_sequencer_new(0, 0);
        assert_eq!(narrow.max_held, 1, "neither valve can be disabled");
        assert_eq!(narrow.max_gap, 1);
    }

    #[test]
    fn the_state_compares_the_whole_set_and_not_just_its_expectation() {
        let mut sequencer = anchored();
        complete(&mut sequencer, 2);
        assert!(slopdesk_decode_sequencer_eq(&sequencer, &sequencer));
        let mut moved = sequencer;
        complete(&mut moved, 3);
        assert!(
            !slopdesk_decode_sequencer_eq(&sequencer, &moved),
            "same expectation, different outstanding ids",
        );
        assert_eq!(sequencer.next_expected, moved.next_expected);
    }

    #[test]
    fn an_idle_stage_admits_a_frame_that_alone_exceeds_the_byte_cap() {
        let budget = slopdesk_decode_budget_new(32, 1024);
        let big = slopdesk_decode_budget_admit(budget, 4096);
        assert!(big.admitted, "otherwise every replacement livelocks");
        assert_eq!(big.budget.pending_bytes, 4096);
        assert!(!slopdesk_decode_budget_admit(big.budget, 1).admitted);
    }

    #[test]
    fn a_saturated_stage_refuses_before_dispatch_until_a_completion_frees_a_slot() {
        let mut budget = slopdesk_decode_budget_new(2, 1 << 20);
        for _ in 0..2 {
            let step = slopdesk_decode_budget_admit(budget, 10);
            assert!(step.admitted);
            budget = step.budget;
        }
        assert!(!slopdesk_decode_budget_admit(budget, 10).admitted);
        assert!(slopdesk_decode_budget_admit(slopdesk_decode_budget_complete(budget, 10), 10).admitted);
    }

    #[test]
    fn an_unpaired_completion_cannot_wedge_the_budget_negative() {
        let stock = slopdesk_decode_budget_default();
        let after = slopdesk_decode_budget_complete(stock, 999);
        assert_eq!(after.pending_count, 0);
        assert_eq!(after.pending_bytes, 0);
        assert!(slopdesk_decode_budget_admit(after, 10).admitted);
    }
}
