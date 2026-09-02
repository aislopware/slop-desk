//! The client receive path — `FrameReassembler` in
//! `Sources/SlopDeskVideoProtocol/FrameReassembler.swift` (doc 17 §3.6).
//!
//! Buffers fragments by `frame_id`, detects loss, applies FEC, and decides — once — that a frame
//! can never be completed. The mirror of [`crate::packetizer`], and the only place in the video
//! path where hostile UDP meets per-frame allocation.
//!
//! ## A frame is lost only when it is PROVABLY lost
//!
//! UDP reorders, so "a fragment is missing" is not loss. A frame is declared dropped only once a
//! NEWER frame's fragments have arrived and this one still has a hole FEC cannot fill — send order
//! only moves forward, so the frontier passing a frame is what makes its hole permanent. Two grace
//! windows sit in front of that verdict: the packetizer emits parity LAST, so a frame whose ONLY
//! obstacle is not-yet-arrived parity waits out `fec_reorder_grace`; and with NACK enabled a small
//! loss is HELD for the retransmit grace instead, since a re-send can still land inside the
//! client's playout buffer. A loss too big to NACK deliberately does NOT get that hold — waiting
//! for a retransmit that will never be requested would stall the in-order client for the whole
//! window.
//!
//! ## The completeness decision is O(1), and that is not an optimisation detail
//!
//! Re-deriving "can this frame still complete" by scanning every data group on every ingest is
//! O(fragments²) per frame — millions of probes on a multi-thousand-fragment IDR, on the client
//! receive path, exactly at the keyframe latency spike. So each frame carries per-group
//! missing-data and surviving-parity counts plus a three-way tally of not-yet-complete groups,
//! updated only on a FIRST arrival. The tally buckets partition the incomplete groups: a group is
//! hopeless (`missing > m`), repairable now (`surviving >= missing`), or awaiting.
//!
//! ## What is pinned per frame, and why
//!
//! `frag_count` and the FEC tier are read from the FIRST fragment seen and never revisited. A later
//! fragment disagreeing about `frag_count` is dropped rather than believed: a SHRUNK count would
//! move the data/parity boundary below already-buffered data, declaring the frame complete while
//! real data is missing — corrupt decoder input AND a suppressed recovery signal — and a GROWN one
//! would wedge the frame forever. The tier is pinned by being resolved once into the frame's group
//! size and `m`.

use std::collections::{BTreeMap, BTreeSet};

use crate::adaptive_fec;
use crate::fec::ReedSolomonFec;
use crate::fragment::{Flags, FrameFragment, HEADER_SIZE, MAX_DATAGRAM_SIZE};

/// Upper bound on a frame's declared fragment count — a hostile-input guard.
///
/// `frag_count` is a peer-controlled `u16`. A real frame is at most a few thousand fragments (a
/// ~2 MB keyframe at ~1.2 KB each is about 1700 data plus parity), and 8192 covers a ~10 MB frame
/// with headroom, so anything larger can only be hostile. Rejected BEFORE any per-frame buffer
/// exists, because the allocation is the attack.
pub const MAX_FRAGMENTS_PER_FRAME: usize = 8192;

/// Upper bound on how far a SINGLE fragment may advance the loss frontier — the `frame_id`
/// companion to [`MAX_FRAGMENTS_PER_FRAME`].
///
/// The encoder's counter advances by one per frame, so a real in-flight window is a few thousand
/// frames at most. A larger jump is a corrupt, off-path or stray datagram; it is rejected without
/// moving the frontier, and [`RESYNC_STREAK`] is how a genuine resync still gets through.
pub const MAX_FRONTIER_JUMP: i32 = 4096;

/// How many CONSECUTIVE clustered frontier-jumping fragments it takes to accept a resync.
///
/// A stream that genuinely moved keeps proposing `frame_id`s near each other — within
/// [`RESYNC_CLUSTER_WINDOW`] — while a lone corrupt datagram does not repeat.
pub const RESYNC_STREAK: usize = 8;

/// How close consecutive jump candidates must be to count as the SAME resync attempt rather than
/// two unrelated bad jumps.
pub const RESYNC_CLUSTER_WINDOW: u32 = 256;

/// The wire cap on how many fragment indices one NACK may name — see
/// [`crate::recovery::MAX_NACK_FRAGMENTS`], which is the codec that enforces it.
///
/// How many retired frame ids to remember before pruning, and how far back to keep.
const RETIRED_SOFT_CAP: usize = 512;
const RETIRED_KEEP_DISTANCE: i32 = 256;

/// Signed wrap-aware distance `value - other` in a 32-bit sequence space, positive when `value` is
/// ahead of `other`.
///
/// A two's-complement wrap-subtract. This is the canonical law the reassembler, the decode frontier
/// and the network estimators all share, and it is what makes the `frame_id` wrap at 2^32 a
/// non-event rather than a session-ending discontinuity.
#[must_use]
pub const fn distance_wrapped(value: u32, other: u32) -> i32 {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "the two's-complement wrap IS the sequence-space distance, not an accident of it"
    )]
    {
        value.wrapping_sub(other) as i32
    }
}

/// A frame reassembled and ready for the decoder.
#[expect(
    clippy::struct_excessive_bools,
    reason = "these ARE the frame's wire flag bits, latched during reassembly"
)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReassembledFrame {
    /// The frame this is.
    pub frame_id: u32,
    /// Whether it is an IDR.
    pub keyframe: bool,
    /// Whether it is a crisp static refresh.
    pub crisp: bool,
    /// The AVCC buffer — exactly the bytes the host packetized, restored directly or via FEC.
    pub avcc: Vec<u8>,
    /// Whether a data hole existed and parity filled it. The `fecRecovered` telemetry numerator.
    pub recovered_via_fec: bool,
    /// Whether the fragments carried bit 6 — a Long-Term Reference the client must ack after a
    /// successful decode, so the host learns this client holds it.
    pub is_ltr: bool,
    /// Whether the fragments carried bit 7 — encoded via `ForceLTRRefresh`, so it references only
    /// acked LTRs. The decode gate's ONLY non-keyframe re-anchor.
    pub acked_anchored: bool,
}

/// The outcome of feeding one datagram to the reassembler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReassemblyResult {
    /// More fragments are still needed; nothing to emit yet.
    Incomplete,
    /// The frame is complete, possibly via FEC recovery.
    Completed(ReassembledFrame),
    /// The frame is unrecoverable: drop it and signal recovery.
    Dropped {
        /// The lost frame.
        frame_id: u32,
    },
    /// The datagram belonged to a frame already completed or dropped, or was implausible.
    Stale,
}

/// One frame's reassembly buffer, with its FEC geometry resolved once at construction.
#[expect(
    clippy::struct_excessive_bools,
    reason = "the four flags mirror the wire bits they latch from"
)]
#[derive(Debug, Clone, Default)]
struct Pending {
    /// PINNED from the first fragment seen: every boundary decision derives from it.
    frag_count: u16,
    keyframe: bool,
    crisp: bool,
    is_ltr: bool,
    acked_anchored: bool,
    /// Data payloads by `frag_index`, over `0..resolved_data_count`.
    data: BTreeMap<u16, Vec<u8>>,
    /// Parity payloads by FLAT LAYOUT SLOT `group * m + rank`, not by raw `frag_index`, so a lost
    /// group-0 parity never shifts the boundary or mis-maps a surviving higher-group shard. At
    /// `m == 1` the slot collapses to group order — byte-identical to single-parity.
    parity: BTreeMap<usize, Vec<u8>>,
    /// The observed parity boundary — the lowest parity `frag_index` seen. Authoritative ONLY on
    /// the no-FEC path; with FEC the boundary is the unambiguous `frag_count` inversion.
    observed_data_count: Option<usize>,
    /// The per-frame group size, or `None` for a no-FEC client OR an OFF-tier frame.
    group_size: Option<usize>,
    /// The per-frame parity-shards-per-group count, at least 1.
    m: usize,
    /// The FEC-case data/parity boundary. Unused when `group_size` is `None`.
    pinned_data_count: usize,
    /// Missing data fragments per group. FEC case only.
    missing_per_group: Vec<usize>,
    /// Distinct surviving parity slots per group. FEC case only.
    surviving_per_group: Vec<usize>,
    /// Groups past their `m`-erasure budget — any one makes the frame permanently unrecoverable.
    hopeless_groups: usize,
    /// Groups repairable RIGHT NOW from parity already held.
    recoverable_now_groups: usize,
    /// Groups within budget but still waiting on parity or data that has not arrived.
    awaiting_groups: usize,
    /// No-FEC case only: distinct data fragments below the observed boundary.
    data_present_below_boundary: usize,
}

impl Pending {
    /// Resolves the FEC geometry once from the two pinned wire fields plus the fixed scheme, and
    /// starts every group at its all-missing tally.
    fn new(frag_count: u16, group_size: Option<usize>, parity_shards_per_group: usize) -> Self {
        let group = group_size.filter(|size| *size >= 1);
        let m = parity_shards_per_group.max(1);
        let total = usize::from(frag_count);
        let mut pending = Self {
            frag_count,
            group_size: group,
            m,
            pinned_data_count: total,
            ..Self::default()
        };
        let Some(group) = group else {
            // The no-FEC boundary is the observed one; `pinned_data_count` is left unread.
            return pending;
        };
        let data_count = inverted_data_count(total, group, m).unwrap_or(total);
        pending.pinned_data_count = data_count;
        let groups = data_count.div_ceil(group);
        pending.missing_per_group = (0..groups)
            .map(|index| group.min(data_count.saturating_sub(index * group)))
            .collect();
        pending.surviving_per_group = vec![0; groups];
        pending.hopeless_groups = pending
            .missing_per_group
            .iter()
            .filter(|missing| **missing > m)
            .count();
        pending.awaiting_groups = groups - pending.hopeless_groups;
        pending
    }

    /// The no-FEC data/parity boundary: the lowest parity index seen, or the whole frame until one
    /// arrives. Named because three call sites need the same fallback and `unwrap_or` would
    /// evaluate it on the hot data path whether or not it was needed.
    const fn observed_boundary(&self) -> usize {
        match self.observed_data_count {
            Some(seen) => seen,
            None => self.frag_count as usize,
        }
    }

    /// How many of this frame's fragments are DATA rather than parity. O(1) — it reads the pinned
    /// geometry.
    ///
    /// With FEC this is always the `frag_count` inversion, NEVER the observed parity boundary,
    /// which a lost group-0 parity would shift. Without FEC the observed boundary is all there
    /// is.
    const fn resolved_data_count(&self) -> usize {
        if self.group_size.is_some() {
            self.pinned_data_count
        } else {
            self.observed_boundary()
        }
    }

    /// Whether all data is present, or FEC could fill the remaining holes from parity ALREADY HELD.
    ///
    /// At `m == 1` this reads "no group with two or more holes, and every single-hole group has its
    /// one parity". O(1) off the counters.
    fn can_eventually_complete(&self) -> bool {
        let data_count = self.resolved_data_count();
        if data_count == 0 {
            // A zero-data frame is a single empty fragment at index 0.
            return self.data.contains_key(&0);
        }
        if self.group_size.is_none() {
            // No FEC, or the OFF tier: any missing data fragment is terminal once the frame is old.
            return self.data_present_below_boundary == data_count;
        }
        self.hopeless_groups == 0 && self.awaiting_groups == 0
    }

    /// Whether the ONLY obstacle is parity that has not arrived yet: every holed group is inside
    /// its budget, none is repairable from what is held, and at least one hole exists. Not
    /// permanently hopeless, so the sweep grants the reorder grace.
    const fn is_awaiting_recoverable_parity(&self) -> bool {
        self.group_size.is_some()
            && self.hopeless_groups == 0
            && self.recoverable_now_groups == 0
            && self.awaiting_groups > 0
    }

    /// Bookkeeping for a FIRST-arrival data fragment. A data-flagged index outside the pinned data
    /// range is outside every later scan too, so it is not counted.
    fn note_data_arrived(&mut self, index: usize) {
        let Some(group_size) = self.group_size else {
            if index < self.observed_boundary() {
                self.data_present_below_boundary += 1;
            }
            return;
        };
        if index >= self.pinned_data_count {
            return;
        }
        let group = index.div_euclid(group_size);
        self.tally(group, false);
        if let Some(missing) = self.missing_per_group.get_mut(group) {
            *missing = missing.saturating_sub(1);
        }
        self.tally(group, true);
    }

    /// Bookkeeping for a FIRST-arrival parity shard at flat layout slot `group * m + rank`. A
    /// no-FEC frame repairs nothing, so this is a no-op there.
    fn note_parity_arrived(&mut self, slot: usize) {
        if self.group_size.is_none() {
            return;
        }
        let group = slot.div_euclid(self.m);
        if group >= self.surviving_per_group.len() {
            return;
        }
        self.tally(group, false);
        if let Some(surviving) = self.surviving_per_group.get_mut(group) {
            *surviving += 1;
        }
        self.tally(group, true);
    }

    /// Records the lowest parity `frag_index` seen. On the no-FEC path this IS the data boundary,
    /// so a shrink evicts already-counted data at or past the new boundary — O(shrink), and
    /// only on a no-FEC parity arrival, never on the hot data path.
    fn note_observed_parity_boundary(&mut self, parity_index: usize) {
        if self.group_size.is_none() {
            let old = self.observed_boundary();
            let new = old.min(parity_index);
            for index in new..old {
                if let Ok(key) = u16::try_from(index)
                    && self.data.contains_key(&key)
                {
                    self.data_present_below_boundary = self.data_present_below_boundary.saturating_sub(1);
                }
            }
        }
        self.observed_data_count = Some(
            self.observed_data_count
                .map_or(parity_index, |seen| seen.min(parity_index)),
        );
    }

    /// Moves `group`'s contribution into (`add`) or out of (`!add`) the three-way tally — called
    /// either side of a counter change.
    ///
    /// The buckets partition the NOT-yet-complete groups; a hole-free group is counted nowhere. A
    /// group has exactly `m` parity slots, so `surviving <= m`, which makes `missing > m`
    /// (hopeless) and `surviving >= missing` (repairable now) mutually exclusive.
    fn tally(&mut self, group: usize, add: bool) {
        let Some(&missing) = self.missing_per_group.get(group) else {
            return;
        };
        if missing < 1 {
            return;
        }
        let surviving = self.surviving_per_group.get(group).copied().unwrap_or(0);
        let bucket = if missing > self.m {
            &mut self.hopeless_groups
        } else if surviving >= missing {
            &mut self.recoverable_now_groups
        } else {
            &mut self.awaiting_groups
        };
        if add {
            *bucket += 1;
        } else {
            *bucket = bucket.saturating_sub(1);
        }
    }

    /// The missing DATA fragment indices, ascending, for a NACK — or `None` when there are none,
    /// the count exceeds `max_frags`, or the data count is unknown.
    ///
    /// Parity is never requested: the host's retransmit ring holds the original data datagrams, and
    /// once enough data arrives the frame completes, with FEC covering any residual hole.
    fn missing_data_frags(&self, max_frags: usize) -> Option<Vec<u16>> {
        let data_count = self.resolved_data_count();
        if data_count == 0 {
            return None;
        }
        let mut missing = Vec::new();
        for index in 0..data_count {
            let key = u16::try_from(index).ok()?;
            if !self.data.contains_key(&key) {
                missing.push(key);
                // Bail as soon as the request would exceed the cap: a BIG loss is not worth
                // re-sending into a burst, and building the whole list first would be work spent to
                // reach the same answer.
                if missing.len() > max_frags {
                    return None;
                }
            }
        }
        if missing.is_empty() { None } else { Some(missing) }
    }
}

/// Inverts `frag_count = data_count + m * ceil(data_count / group_size)` for `data_count`.
///
/// The right-hand side is monotonic non-decreasing in `data_count`, so a descending scan finds the
/// unique solution when one exists. `None` means no `data_count` solves it — a corrupt header, or a
/// `frag_count` shaped for a different `m` — and every call site falls back to the total. Called
/// once per frame, never on the per-fragment path.
const fn inverted_data_count(total: usize, group_size: usize, m: usize) -> Option<usize> {
    if group_size < 1 || m < 1 {
        return None;
    }
    let mut data_count = total;
    while data_count > 0 {
        let parity = m * data_count.div_ceil(group_size);
        if data_count + parity == total {
            return Some(data_count);
        }
        if data_count + parity < total {
            // Monotonic: every smaller `data_count` undershoots further, so no solution exists.
            return None;
        }
        data_count -= 1;
    }
    // Zero data fragments means zero parity, so the total must be zero too.
    if total == 0 { Some(0) } else { None }
}

/// Reassembles fragmented frames, detects loss, and applies FEC.
///
/// Owns mutable per-frame state, so one lives per video stream on the client receive loop.
#[derive(Debug, Default)]
pub struct FrameReassembler {
    fec: Option<ReedSolomonFec>,
    /// Frames currently being assembled.
    pending: BTreeMap<u32, Pending>,
    /// The highest frame completed or dropped — anything at or behind it is stale.
    highest_retired_frame_id: Option<u32>,
    /// The highest frame ever SEEN a fragment for: the loss frontier. Once a newer frame appears,
    /// strictly older incomplete frames FEC cannot fill are hopeless, because send order only moves
    /// forward.
    highest_seen_frame_id: Option<u32>,
    /// Recently retired frames, for classifying late stragglers. Bounded.
    retired: BTreeSet<u32>,
    /// Unrecoverably lost frames the caller drains, so one ingest can both complete its own frame
    /// and surface older drops. Each maps to one recovery signal.
    dropped_queue: Vec<u32>,
    /// How many frame ids past the frontier a frame stays FEC-eligible when the only thing missing
    /// is parity that could still fill its holes.
    fec_reorder_grace: i32,
    /// How many frame ids past the frontier a FEC-unrecoverable frame is HELD pending so a
    /// retransmit can fill it. 0 disables NACK entirely.
    retransmit_grace: i32,
    /// Frames already surfaced for retransmit, so each is requested once. Cleared on retire.
    nacked: BTreeSet<u32>,
    /// `(frame_id, missing data indices)` the client should NACK, oldest first.
    needs_retransmit_queue: Vec<(u32, Vec<u16>)>,
    /// Only NACK a loss of at most this many data fragments.
    nack_max_frags: usize,
    /// Consecutive fragments rejected for jumping the frontier, oldest first.
    frontier_jump_candidates: Vec<u32>,
    /// Total fragments dropped for jumping the frontier, including ones a later resync absorbed.
    frontier_jump_rejected_count: u64,
}

impl FrameReassembler {
    /// Builds a reassembler matching the host's FEC.
    ///
    /// `fec` supplies the per-group data count and the configured parity multiplicity; `None` — or
    /// a degenerate `m == 0` scheme — builds a no-FEC reassembler, so the recover path never
    /// reads parity that cannot exist. `fec_reorder_grace` is floored at 0.
    #[must_use]
    pub fn new(fec: Option<ReedSolomonFec>, fec_reorder_grace: i32) -> Self {
        Self {
            fec: fec.filter(|scheme| scheme.parity_count() >= 1),
            fec_reorder_grace: fec_reorder_grace.max(0),
            ..Self::default()
        }
    }

    /// Enables NACK / selective ARQ.
    ///
    /// A FEC-unrecoverable frame is HELD for `grace` frame ids past the frontier instead of dropped
    /// at the reorder grace, so a host retransmit can still fill it inside the client's playout
    /// buffer. Only losses of at most `max_frags` fragments are requested — a bigger loss skips
    /// straight to the drop-and-LTR-refresh fallback. `max_frags` is clamped to the wire cap.
    pub fn enable_retransmit(&mut self, grace: i32, max_frags: usize) {
        self.retransmit_grace = grace.max(0);
        self.nack_max_frags = max_frags.min(crate::recovery::MAX_NACK_FRAGMENTS);
    }

    /// Total fragments rejected for jumping the loss frontier — telemetry.
    #[must_use]
    pub const fn frontier_jump_rejected_count(&self) -> u64 {
        self.frontier_jump_rejected_count
    }

    /// Pops the next NACK request a prior [`Self::ingest`] queued, or `None`. Inert unless
    /// [`Self::enable_retransmit`] was called.
    pub fn next_needs_retransmit(&mut self) -> Option<(u32, Vec<u16>)> {
        if self.needs_retransmit_queue.is_empty() {
            None
        } else {
            Some(self.needs_retransmit_queue.remove(0))
        }
    }

    /// Pops the next unrecoverably lost frame id, or `None`. The client issues one recovery signal
    /// — LTR refresh, then IDR fallback — per id it drains.
    pub fn next_dropped_frame(&mut self) -> Option<u32> {
        if self.dropped_queue.is_empty() {
            None
        } else {
            Some(self.dropped_queue.remove(0))
        }
    }

    /// Feeds one parsed fragment and returns the outcome FOR THAT FRAGMENT'S frame.
    ///
    /// Drops of older, now-hopeless frames are surfaced separately through
    /// [`Self::next_dropped_frame`], so completing a newer frame never hides an older loss. If the
    /// ingested fragment's own frame became hopeless, `Dropped` is returned directly.
    pub fn ingest(&mut self, fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header;
        let frame_id = header.frame_id;

        // Hostile input — UDP video has no auth beyond the mesh, so an implausible header is
        // rejected BEFORE any per-frame buffer exists. A crafted `frag_count` makes
        // assembly build and iterate a `data_count`-sized array per frame, and `frag_index
        // >= frag_count` can never complete.
        // The payload is bounded by the DATAGRAM budget, not by the 64 KiB read window: every other
        // guard here bounds counts, and without this one a frame declaring the maximum fragment
        // count at the maximum datagram size would be held at half a gibibyte until the frontier
        // swept it. The bound is the widest payload a datagram inside the budget can carry — a
        // parity shard is `MAX_PAYLOAD_SIZE` plus its length prefix — so the honest path is
        // byte-identical.
        if header.frag_count == 0
            || usize::from(header.frag_count) > MAX_FRAGMENTS_PER_FRAME
            || header.frag_index >= header.frag_count
            || fragment.payload.len() > MAX_DATAGRAM_SIZE - HEADER_SIZE
        {
            return ReassemblyResult::Stale;
        }

        if self.retired.contains(&frame_id) {
            return ReassemblyResult::Stale;
        }
        // At or behind the retire frontier and not actively pending: a late straggler the bounded
        // `retired` set may already have forgotten.
        if let Some(retired_high) = self.highest_retired_frame_id
            && distance_wrapped(frame_id, retired_high) <= 0
            && !self.pending.contains_key(&frame_id)
        {
            return ReassemblyResult::Stale;
        }

        if !self.advance_frontier(frame_id) {
            return ReassemblyResult::Stale;
        }

        let fec = self.fec;
        let tier = header.flags.fec_tier();
        let entry = self.pending.entry(frame_id).or_insert_with(|| {
            Pending::new(
                header.frag_count,
                fec.and_then(|scheme| adaptive_fec::group_size(tier, scheme.group_size())),
                adaptive_fec::parity_count(tier, fec.map_or(1, |scheme| scheme.parity_count())),
            )
        });
        // THE FRAGCOUNT PIN. A fragment disagreeing with the pinned count passes its OWN header's
        // `frag_index < frag_count` guard, so it has to be rejected here or it would move a
        // boundary that everything else already depends on. Equality also re-establishes
        // the index guard against the pinned count.
        if header.frag_count != entry.frag_count {
            return ReassemblyResult::Stale;
        }

        entry.keyframe |= header.flags.contains(Flags::KEYFRAME);
        entry.crisp |= header.flags.contains(Flags::CRISP);
        entry.is_ltr |= header.flags.contains(Flags::IS_LTR);
        entry.acked_anchored |= header.flags.contains(Flags::ACKED_ANCHORED);

        if header.flags.contains(Flags::PARITY) {
            let parity_index = usize::from(header.frag_index);
            // The boundary parity is keyed against is the PINNED one, so it can never disagree with
            // the boundary assembly uses. Only the no-FEC path falls back to the observed index.
            let boundary = if entry.group_size.is_some() {
                entry.pinned_data_count
            } else {
                parity_index
            };
            entry.note_observed_parity_boundary(parity_index);
            // Parity is laid out group-major then rank AFTER the data, so `frag_index - boundary`
            // IS the flat slot `group * m + rank`. At `m == 1` it collapses to group
            // order.
            let slot = parity_index.saturating_sub(boundary);
            // Duplicates overwrite; only a first arrival counts.
            if entry.parity.insert(slot, fragment.payload).is_none() {
                entry.note_parity_arrived(slot);
            }
        } else if entry.data.insert(header.frag_index, fragment.payload).is_none() {
            entry.note_data_arrived(usize::from(header.frag_index));
        }

        let result = self.try_complete(frame_id);

        // Sweep every pending frame older than the frontier that can no longer complete. This runs
        // whatever `result` was, so completing a newer frame never hides an older hopeless one.
        self.sweep_hopeless_frames();

        if matches!(result, ReassemblyResult::Completed(_)) {
            return result;
        }
        // The ingested frame itself may have just been declared hopeless by that sweep.
        if !self.pending.contains_key(&frame_id) && self.dropped_queue.contains(&frame_id) {
            self.dropped_queue.retain(|queued| *queued != frame_id);
            return ReassemblyResult::Dropped { frame_id };
        }
        ReassemblyResult::Incomplete
    }

    /// Advances the loss frontier, bounded to [`MAX_FRONTIER_JUMP`] per fragment. Returns whether
    /// the fragment may proceed; a rejected jump starts no entry and leaves the frontier
    /// untouched.
    fn advance_frontier(&mut self, frame_id: u32) -> bool {
        let Some(seen) = self.highest_seen_frame_id else {
            self.highest_seen_frame_id = Some(frame_id);
            return true;
        };
        let jump = distance_wrapped(frame_id, seen);
        if jump > MAX_FRONTIER_JUMP {
            self.frontier_jump_rejected_count += 1;
            if !self.resync_on_consistent_jump(frame_id) {
                return false;
            }
        } else {
            self.frontier_jump_candidates.clear();
        }
        if jump > 0 {
            self.highest_seen_frame_id = Some(frame_id);
        }
        true
    }

    /// Whether `frame_id` extends a run of [`RESYNC_STREAK`] rejected candidates clustered within
    /// [`RESYNC_CLUSTER_WINDOW`] — a stream that genuinely moved rather than a lone bad datagram.
    ///
    /// A candidate outside the window clears the run and starts a fresh one, so two unrelated bad
    /// jumps cannot compound into a false resync.
    fn resync_on_consistent_jump(&mut self, frame_id: u32) -> bool {
        if let Some(&last) = self.frontier_jump_candidates.last()
            && distance_wrapped(frame_id, last).unsigned_abs() > RESYNC_CLUSTER_WINDOW
        {
            self.frontier_jump_candidates.clear();
        }
        self.frontier_jump_candidates.push(frame_id);
        if self.frontier_jump_candidates.len() >= RESYNC_STREAK {
            self.frontier_jump_candidates.clear();
            return true;
        }
        false
    }

    fn try_complete(&mut self, frame_id: u32) -> ReassemblyResult {
        let Some(entry) = self.pending.get(&frame_id) else {
            return ReassemblyResult::Stale;
        };
        // The CHEAP precheck before the expensive assembly, which copies every present payload and
        // runs recovery. It is outcome-equivalent to "assembly would succeed now" and reads the
        // O(1) counters, so the hot path never re-scans the groups.
        if !entry.can_eventually_complete() {
            return ReassemblyResult::Incomplete;
        }
        let Some((avcc, recovered_via_fec)) = self.assemble(entry) else {
            return ReassemblyResult::Incomplete;
        };
        let frame = ReassembledFrame {
            frame_id,
            keyframe: entry.keyframe,
            crisp: entry.crisp,
            avcc,
            recovered_via_fec,
            is_ltr: entry.is_ltr,
            acked_anchored: entry.acked_anchored,
        };
        self.retire(frame_id);
        ReassemblyResult::Completed(frame)
    }

    /// Retires every pending frame strictly older than the frontier that can no longer complete.
    fn sweep_hopeless_frames(&mut self) {
        let Some(frontier) = self.highest_seen_frame_id else {
            return;
        };
        let mut hopeless: Vec<u32> = Vec::new();
        let mut nack: Vec<(u32, Vec<u16>)> = Vec::new();
        for (&frame_id, entry) in &self.pending {
            let age = distance_wrapped(frontier, frame_id);
            if age <= 0 || entry.can_eventually_complete() {
                continue; // Newer than the frontier, or completable now.
            }
            // A hole only fillable by parity that has not arrived: keep it inside the grace window,
            // because the packetizer emits parity last and UDP reorders.
            if entry.is_awaiting_recoverable_parity() && age <= self.fec_reorder_grace {
                continue;
            }
            // FEC cannot recover this from what is here. With NACK on and the loss small enough,
            // HOLD it for the retransmit window and request it once. A loss too BIG to NACK falls
            // through to the prompt drop rather than being held uselessly — nothing would ever
            // come.
            if self.retransmit_grace > 0 && age <= self.retransmit_grace {
                if self.nacked.contains(&frame_id) {
                    continue; // Already requested: hold for its retransmit.
                }
                if let Some(missing) = entry.missing_data_frags(self.nack_max_frags) {
                    nack.push((frame_id, missing));
                    continue;
                }
            }
            hopeless.push(frame_id);
        }
        // Oldest-first in BOTH queues, so the recovery signals a client sends are a function of the
        // stream rather than of map iteration order.
        nack.sort_by(|left, right| {
            distance_wrapped(left.0, right.0)
                .cmp(&0)
                .then(left.0.cmp(&right.0))
        });
        for (frame_id, missing) in nack {
            self.nacked.insert(frame_id);
            self.needs_retransmit_queue.push((frame_id, missing));
        }
        hopeless.sort_by(|left, right| distance_wrapped(*left, *right).cmp(&0));
        for frame_id in hopeless {
            self.retire(frame_id);
            self.dropped_queue.push(frame_id);
        }
    }

    /// The reassembled AVCC bytes, and whether a hole existed that FEC filled — or `None` if a hole
    /// remains.
    fn assemble(&self, entry: &Pending) -> Option<(Vec<u8>, bool)> {
        let data_count = entry.resolved_data_count();
        if data_count == 0 {
            // A zero-data frame is valid only as a single empty fragment at index 0.
            return entry.data.get(&0).map(|only| (only.clone(), false));
        }

        let mut had_hole = false;
        let mut present: Vec<Option<&[u8]>> = Vec::with_capacity(data_count);
        for index in 0..data_count {
            let payload = u16::try_from(index)
                .ok()
                .and_then(|key| entry.data.get(&key))
                .map(Vec::as_slice);
            had_hole |= payload.is_none();
            present.push(payload);
        }

        if !had_hole {
            // The whole-arrival path never materialises an intermediate copy of the frame.
            return Some((concat(present.into_iter().flatten()), false));
        }

        // A hole with no per-frame group size — no FEC, or the OFF tier — stays a hole.
        let (Some(fec), Some(group_size)) = (self.fec, entry.group_size) else {
            return None;
        };
        let mut data: Vec<Option<Vec<u8>>> = present
            .into_iter()
            .map(|payload| payload.map(<[u8]>::to_vec))
            .collect();
        // The flat parity array in group-major then rank order — the layout recovery indexes. A
        // lost shard leaves its slot `None`.
        let parity_slots = usize::from(entry.frag_count).saturating_sub(data_count);
        let parity: Vec<Option<Vec<u8>>> = (0..parity_slots)
            .map(|slot| entry.parity.get(&slot).cloned())
            .collect();
        // Recover at the SAME per-frame `m` the host encoded with, which sets both the parity
        // stride and the per-group budget. For every production tier this equals the
        // codec's own `m`, so it collapses to a plain recover. Going through the configured
        // codec rather than building one at `(group_size, m)` is exact here — an m-tier
        // resolves its group size to the default, so the Cauchy rows are the same rows —
        // and it keeps a construction assert off a wire path.
        fec.recover_with_m(&mut data, &parity, group_size, entry.m);

        if data.iter().any(Option::is_none) {
            return None;
        }
        Some((concat(data.iter().flatten().map(Vec::as_slice)), true))
    }

    fn retire(&mut self, frame_id: u32) {
        self.pending.remove(&frame_id);
        // A retired frame is no longer a retransmit candidate, so the once-per-frame guard forgets
        // it.
        self.nacked.remove(&frame_id);
        self.retired.insert(frame_id);
        let ahead = self
            .highest_retired_frame_id
            .is_none_or(|high| distance_wrapped(frame_id, high) > 0);
        if ahead {
            self.highest_retired_frame_id = Some(frame_id);
        }
        // Bound the retired set so a long session cannot grow it without limit.
        if self.retired.len() > RETIRED_SOFT_CAP
            && let Some(high) = self.highest_retired_frame_id
        {
            self.retired
                .retain(|id| distance_wrapped(high, *id) <= RETIRED_KEEP_DISTANCE);
        }
    }
}

/// Joins fragment payloads into one buffer, sized exactly once so the concatenation never grows.
fn concat<'a>(fragments: impl Iterator<Item = &'a [u8]> + Clone) -> Vec<u8> {
    let total = fragments.clone().map(<[u8]>::len).sum();
    let mut out = Vec::with_capacity(total);
    for fragment in fragments {
        out.extend_from_slice(fragment);
    }
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        FrameReassembler, MAX_FRAGMENTS_PER_FRAME, MAX_FRONTIER_JUMP, RESYNC_CLUSTER_WINDOW, RESYNC_STREAK,
        ReassemblyResult, distance_wrapped, inverted_data_count,
    };
    use crate::fec::ReedSolomonFec;
    use crate::fragment::{
        Flags, FrameFragment, FrameFragmentHeader, HEADER_SIZE, MAX_DATAGRAM_SIZE, MAX_PAYLOAD_SIZE,
    };
    use crate::packetizer::{PacketizeOptions, VideoPacketizer};

    /// The frontier bound as a `frame_id` offset.
    fn frontier_jump() -> u32 {
        u32::try_from(MAX_FRONTIER_JUMP).expect("the bound is positive")
    }

    fn frame_of(len: usize) -> Vec<u8> {
        #[expect(clippy::cast_possible_truncation, reason = "a deterministic test pattern")]
        (0..len).map(|index| index as u8).collect()
    }

    /// The fragments the real packetizer would emit for one frame — the encoder and decoder checked
    /// against each other rather than against a hand-built header.
    fn packetized(
        frame: &[u8],
        fec: Option<ReedSolomonFec>,
        options: PacketizeOptions,
    ) -> Vec<FrameFragment> {
        VideoPacketizer::new(fec).packetize(frame, options)
    }

    fn completed(result: ReassemblyResult) -> Vec<u8> {
        match result {
            ReassemblyResult::Completed(frame) => frame.avcc,
            other => panic!("expected a completed frame, got {other:?}"),
        }
    }

    #[test]
    fn a_whole_frame_arriving_in_order_reassembles_to_the_original_bytes() {
        let frame = frame_of(4000);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        let last = fragments.len() - 1;
        for fragment in &fragments[..last] {
            assert_eq!(reassembler.ingest(fragment.clone()), ReassemblyResult::Incomplete);
        }
        assert_eq!(completed(reassembler.ingest(fragments[last].clone())), frame);
    }

    #[test]
    fn a_reordered_frame_reassembles_identically() {
        let frame = frame_of(4000);
        let mut fragments = packetized(&frame, None, PacketizeOptions::default());
        fragments.reverse();
        let mut reassembler = FrameReassembler::new(None, 2);
        let mut rebuilt = None;
        for fragment in &fragments {
            if let ReassemblyResult::Completed(done) = reassembler.ingest(fragment.clone()) {
                rebuilt = Some(done.avcc);
            }
        }
        assert_eq!(rebuilt.expect("the frame completes"), frame);
    }

    #[test]
    fn a_duplicate_fragment_changes_nothing() {
        let frame = frame_of(4000);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        let last = fragments.len() - 1;
        for fragment in &fragments[..last] {
            reassembler.ingest(fragment.clone());
            reassembler.ingest(fragment.clone()); // twice
        }
        assert_eq!(completed(reassembler.ingest(fragments[last].clone())), frame);
    }

    #[test]
    fn a_zero_byte_frame_completes_from_its_single_empty_fragment() {
        let fragments = packetized(&[], None, PacketizeOptions::default());
        assert_eq!(fragments.len(), 1);
        let mut reassembler = FrameReassembler::new(None, 2);
        assert_eq!(
            completed(reassembler.ingest(fragments[0].clone())),
            Vec::<u8>::new()
        );
    }

    #[test]
    fn one_lost_data_fragment_per_group_is_repaired_from_parity() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(Some(codec), 2);
        let mut rebuilt = None;
        // Drop data fragment 0 (group 0) and 5 (group 1) — one hole per group, both repairable.
        for (index, fragment) in fragments.iter().enumerate() {
            if index == 0 || index == 5 {
                continue;
            }
            if let ReassemblyResult::Completed(done) = reassembler.ingest(fragment.clone()) {
                assert!(done.recovered_via_fec, "a filled hole is a FEC recovery");
                rebuilt = Some(done.avcc);
            }
        }
        assert_eq!(rebuilt.expect("FEC completes the frame"), frame);
    }

    #[test]
    fn two_losses_in_one_group_are_not_repairable_and_the_frame_drops() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(Some(codec), 0);
        for (index, fragment) in fragments.iter().enumerate() {
            if index == 0 || index == 1 {
                continue; // both in group 0, beyond a single-parity budget
            }
            reassembler.ingest(fragment.clone());
        }
        // Nothing is lost until the frontier proves it: a NEWER frame has to arrive first.
        assert_eq!(reassembler.next_dropped_frame(), None);
        let next = packetized(&frame_of(10), Some(codec), PacketizeOptions::default());
        let mut second = VideoPacketizer::new(Some(codec));
        drop(second.packetize(&frame, PacketizeOptions::default()));
        for fragment in &next {
            let mut bumped = fragment.clone();
            bumped.header.frame_id = 1;
            reassembler.ingest(bumped.clone());
        }
        assert_eq!(reassembler.next_dropped_frame(), Some(0));
    }

    #[test]
    fn a_frame_waiting_only_on_parity_gets_the_reorder_grace() {
        // The packetizer emits parity LAST, so frame N's parity commonly lands after frame N+1's
        // data. Without the grace that ordering alone would look like loss.
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let data_count = fragments.len() - 1;

        let mut reassembler = FrameReassembler::new(Some(codec), 2);
        for fragment in &fragments[1..data_count] {
            reassembler.ingest(fragment.clone()); // frame 0, missing data 0 and its parity
        }
        // A newer frame arrives; the grace keeps frame 0 alive.
        let mut newer = fragments[0].clone();
        newer.header.frame_id = 1;
        reassembler.ingest(newer);
        assert_eq!(reassembler.next_dropped_frame(), None, "still inside the grace");

        // The late parity lands and repairs the hole.
        let mut parity = fragments[data_count].clone();
        parity.header.frame_id = 0;
        assert_eq!(completed(reassembler.ingest(parity)), frame);
    }

    #[test]
    fn the_grace_expires_and_the_frame_is_declared_lost() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let data_count = fragments.len() - 1;
        let mut reassembler = FrameReassembler::new(Some(codec), 2);
        for fragment in &fragments[1..data_count] {
            reassembler.ingest(fragment.clone());
        }
        // Newer frames that COMPLETE, so nothing but frame 0 is ever a drop candidate.
        let tick = packetized(&frame_of(10), Some(codec), PacketizeOptions::default());
        for frame_id in 1..=3 {
            for fragment in &tick {
                let mut newer = fragment.clone();
                newer.header.frame_id = frame_id;
                reassembler.ingest(newer.clone());
            }
        }
        assert_eq!(reassembler.next_dropped_frame(), Some(0));
        assert_eq!(
            reassembler.next_dropped_frame(),
            None,
            "and nothing else was lost"
        );
    }

    #[test]
    fn a_retired_frame_is_stale_and_never_reopens() {
        let frame = frame_of(2000);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        for fragment in &fragments {
            reassembler.ingest(fragment.clone());
        }
        assert_eq!(reassembler.ingest(fragments[0].clone()), ReassemblyResult::Stale);
    }

    #[test]
    fn an_implausible_header_is_rejected_before_any_buffer_exists() {
        let mut reassembler = FrameReassembler::new(None, 2);
        let mut fragment = FrameFragment::default();

        fragment.header.frag_count = 0;
        assert_eq!(
            reassembler.ingest(fragment.clone()),
            ReassemblyResult::Stale,
            "zero fragments"
        );

        #[expect(clippy::cast_possible_truncation, reason = "the guard is stated in u16 terms")]
        {
            fragment.header.frag_count = MAX_FRAGMENTS_PER_FRAME as u16 + 1;
        }
        assert_eq!(
            reassembler.ingest(fragment.clone()),
            ReassemblyResult::Stale,
            "an absurd count"
        );

        fragment.header.frag_count = 4;
        fragment.header.frag_index = 4;
        assert_eq!(
            reassembler.ingest(fragment),
            ReassemblyResult::Stale,
            "index past the count"
        );
    }

    #[test]
    fn a_fragment_disagreeing_about_the_fragment_count_is_dropped_not_believed() {
        // A shrunk count would move the boundary below buffered data and declare the frame complete
        // while real data is missing — corrupt decoder input AND a suppressed recovery signal.
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        reassembler.ingest(fragments[0].clone());

        let mut liar = fragments[1].clone();
        liar.header.frag_count = 2;
        assert_eq!(reassembler.ingest(liar), ReassemblyResult::Stale);

        // The frame is untouched and still completes on the honest fragments.
        let mut rebuilt = None;
        for fragment in &fragments[1..] {
            if let ReassemblyResult::Completed(done) = reassembler.ingest(fragment.clone()) {
                rebuilt = Some(done.avcc);
            }
        }
        assert_eq!(
            rebuilt.expect("the rejected fragment must not have wedged the frame"),
            frame
        );
    }

    #[test]
    fn a_lone_frontier_jump_is_rejected_without_moving_the_frontier() {
        let frame = frame_of(100);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        reassembler.ingest(fragments[0].clone());

        let mut far = fragments[0].clone();
        far.header.frame_id = frontier_jump() + 99;
        assert_eq!(reassembler.ingest(far), ReassemblyResult::Stale);
        assert_eq!(reassembler.frontier_jump_rejected_count(), 1);

        // The frontier never moved, so an ordinary next frame is still accepted.
        let mut ordinary = fragments[0].clone();
        ordinary.header.frame_id = 1;
        assert_ne!(reassembler.ingest(ordinary), ReassemblyResult::Stale);
    }

    #[test]
    fn a_consistent_run_of_jumps_is_accepted_as_a_resync() {
        let frame = frame_of(100);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        reassembler.ingest(fragments[0].clone());

        let base = frontier_jump() + 1000;
        for offset in 0..RESYNC_STREAK - 1 {
            let mut jumped = fragments[0].clone();
            jumped.header.frame_id = base + u32::try_from(offset).expect("a small offset");
            assert_eq!(reassembler.ingest(jumped.clone()), ReassemblyResult::Stale);
        }
        let mut accepted = fragments[0].clone();
        accepted.header.frame_id = base + u32::try_from(RESYNC_STREAK).expect("a small streak");
        assert_ne!(
            reassembler.ingest(accepted),
            ReassemblyResult::Stale,
            "a stream that keeps proposing nearby ids really moved"
        );
    }

    #[test]
    fn two_unrelated_jumps_never_compound_into_a_false_resync() {
        let frame = frame_of(100);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        reassembler.ingest(fragments[0].clone());

        let base = frontier_jump() + 1000;
        for step in 0..RESYNC_STREAK * 2 {
            let mut jumped = fragments[0].clone();
            // Alternate between two regions far further apart than the cluster window, so no run
            // ever reaches the streak.
            jumped.header.frame_id = if step % 2 == 0 {
                base
            } else {
                base + RESYNC_CLUSTER_WINDOW * 10
            };
            assert_eq!(
                reassembler.ingest(jumped.clone()),
                ReassemblyResult::Stale,
                "step {step}"
            );
        }
    }

    #[test]
    fn a_small_unrecoverable_loss_is_nacked_and_held() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(Some(codec), 0);
        reassembler.enable_retransmit(4, 8);
        for (index, fragment) in fragments.iter().enumerate() {
            if index == 0 || index == 1 {
                continue; // two holes in group 0: FEC cannot fix it
            }
            reassembler.ingest(fragment.clone());
        }
        let mut newer = fragments[2].clone();
        newer.header.frame_id = 1;
        reassembler.ingest(newer);

        assert_eq!(reassembler.next_needs_retransmit(), Some((0, vec![0, 1])));
        assert_eq!(reassembler.next_dropped_frame(), None, "held for the retransmit");
        assert_eq!(
            reassembler.next_needs_retransmit(),
            None,
            "requested exactly once"
        );
    }

    #[test]
    fn a_loss_too_big_to_nack_drops_promptly_instead_of_stalling() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(Some(codec), 0);
        reassembler.enable_retransmit(4, 1); // a one-fragment NACK budget
        reassembler.ingest(fragments[2].clone());
        let mut newer = fragments[2].clone();
        newer.header.frame_id = 1;
        reassembler.ingest(newer);

        assert_eq!(reassembler.next_needs_retransmit(), None, "too big to request");
        assert_eq!(
            reassembler.next_dropped_frame(),
            Some(0),
            "holding it would stall the client for the whole window with nothing coming"
        );
    }

    #[test]
    fn the_nack_never_asks_for_parity() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        let codec = ReedSolomonFec::default();
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let data_count = fragments
            .iter()
            .filter(|fragment| !fragment.header.flags.contains(Flags::PARITY))
            .count();
        let mut reassembler = FrameReassembler::new(Some(codec), 0);
        reassembler.enable_retransmit(4, 64);
        // Deliver nothing but parity, then advance the frontier.
        for fragment in &fragments[data_count..] {
            reassembler.ingest(fragment.clone());
        }
        let mut newer = fragments[data_count].clone();
        newer.header.frame_id = 1;
        reassembler.ingest(newer);

        let (frame_id, missing) = reassembler.next_needs_retransmit().expect("a request");
        assert_eq!(frame_id, 0);
        assert_eq!(missing.len(), data_count, "every DATA index, and nothing else");
        assert_eq!(missing.first(), Some(&0));
    }

    #[test]
    fn an_oversized_payload_is_stale_rather_than_held() {
        // A peer on the mesh, not the host: the packetizer never writes a payload past its own
        // ceiling, so a wider one is refused before any per-frame buffer exists.
        let mut reassembler = FrameReassembler::new(None, 0);
        let header = FrameFragmentHeader::new(0, 7, 0, 2, Flags::default(), 0, 0);
        let widest = MAX_DATAGRAM_SIZE - HEADER_SIZE;
        let wide = FrameFragment::new(header, vec![0xAB; widest + 1]);
        assert_eq!(reassembler.ingest(wide), ReassemblyResult::Stale);
        let exact = FrameFragment::new(header, vec![0xAB; widest]);
        assert_eq!(reassembler.ingest(exact), ReassemblyResult::Incomplete);
    }

    #[test]
    fn the_off_tier_carries_no_parity_and_any_hole_is_terminal() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 4);
        let codec = ReedSolomonFec::default();
        let options = PacketizeOptions {
            fec_tier: 1,
            ..PacketizeOptions::default()
        };
        let fragments = packetized(&frame, Some(codec), options);
        assert_eq!(fragments.len(), 4, "the OFF tier emits no parity at all");

        let mut reassembler = FrameReassembler::new(Some(codec), 0);
        for fragment in &fragments[1..] {
            reassembler.ingest(fragment.clone());
        }
        let mut newer = fragments[1].clone();
        newer.header.frame_id = 1;
        reassembler.ingest(newer);
        assert_eq!(reassembler.next_dropped_frame(), Some(0));
    }

    #[test]
    fn every_group_size_tier_round_trips_through_both_ends() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 7 + 33);
        let codec = ReedSolomonFec::default();
        for tier in [0_u8, 2, 3, 4] {
            let options = PacketizeOptions {
                fec_tier: tier,
                ..PacketizeOptions::default()
            };
            let fragments = packetized(&frame, Some(codec), options);
            let mut reassembler = FrameReassembler::new(Some(codec), 2);
            let mut rebuilt = None;
            for fragment in &fragments {
                if let ReassemblyResult::Completed(done) = reassembler.ingest(fragment.clone()) {
                    rebuilt = Some(done.avcc);
                }
            }
            assert_eq!(rebuilt.expect("the frame completes"), frame, "tier {tier}");
        }
    }

    #[test]
    fn a_multi_loss_codec_repairs_up_to_m_holes_per_group() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 5);
        let codec = ReedSolomonFec::new(5, 3);
        let fragments = packetized(&frame, Some(codec), PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(Some(codec), 2);
        let mut rebuilt = None;
        for (index, fragment) in fragments.iter().enumerate() {
            if index < 3 {
                continue; // three holes in the one group, exactly the budget
            }
            if let ReassemblyResult::Completed(done) = reassembler.ingest(fragment.clone()) {
                rebuilt = Some(done.avcc);
            }
        }
        assert_eq!(rebuilt.expect("m == 3 repairs three holes"), frame);
    }

    #[test]
    fn the_frame_flags_latch_from_whichever_fragment_carries_them() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3);
        let options = PacketizeOptions {
            crisp: true,
            is_ltr: true,
            acked_anchored: true,
            ..PacketizeOptions::keyframe()
        };
        let mut fragments = packetized(&frame, None, options);
        fragments.reverse();
        let mut reassembler = FrameReassembler::new(None, 2);
        let mut done = None;
        for fragment in &fragments {
            if let ReassemblyResult::Completed(frame) = reassembler.ingest(fragment.clone()) {
                done = Some(frame);
            }
        }
        let done = done.expect("the frame completes");
        assert!(done.keyframe && done.crisp && done.is_ltr && done.acked_anchored);
        assert!(!done.recovered_via_fec, "a whole arrival is not a recovery");
    }

    #[test]
    fn the_inversion_solves_the_fragment_count_equation_or_says_it_cannot() {
        // 6 data at g5 m1 is 2 parity shards ⇒ 8 total.
        assert_eq!(inverted_data_count(8, 5, 1), Some(6));
        // 5 data at g5 m3 is 3 shards ⇒ 8 total, a DIFFERENT frame with the same total.
        assert_eq!(inverted_data_count(8, 5, 3), Some(5));
        assert_eq!(inverted_data_count(0, 5, 1), Some(0));
        // 4 data at g5 m3 is also 3 shards ⇒ 7, so the same total can mean different frames under
        // different `m` — which is exactly why `m` is pinned per frame rather than guessed.
        assert_eq!(inverted_data_count(7, 5, 3), Some(4));
        // No data count solves this one, so the caller falls back to the total.
        assert_eq!(inverted_data_count(2, 5, 3), None);
        assert_eq!(inverted_data_count(8, 0, 1), None, "a hostile group size");
    }

    #[test]
    fn the_wrap_distance_treats_the_sequence_space_as_a_circle() {
        assert_eq!(distance_wrapped(5, 3), 2);
        assert_eq!(distance_wrapped(3, 5), -2);
        assert_eq!(distance_wrapped(0, u32::MAX), 1, "the wrap is a non-event");
        assert_eq!(distance_wrapped(u32::MAX, 0), -1);
        assert_eq!(distance_wrapped(7, 7), 0);
    }

    #[test]
    fn a_frame_completes_across_the_frame_id_wrap() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3);
        let fragments = packetized(&frame, None, PacketizeOptions::default());
        let mut reassembler = FrameReassembler::new(None, 2);
        // The last frame before the wrap, then the first after it.
        let mut rebuilt = None;
        for frame_id in [u32::MAX, 0] {
            for fragment in &fragments {
                let mut wrapped = fragment.clone();
                wrapped.header.frame_id = frame_id;
                if let ReassemblyResult::Completed(done) = reassembler.ingest(wrapped.clone()) {
                    rebuilt = Some((frame_id, done.avcc));
                }
            }
        }
        assert_eq!(rebuilt.expect("the post-wrap frame completes"), (0, frame));
    }
}
