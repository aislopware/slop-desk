//! Frame reassembly with loss detection and FEC — a port of Swift `FrameReassembler`.
//!
//! The stream is plain UDP, so fragments may be lost or reordered. A frame is declared
//! lost (`Dropped`) only once it cannot complete — i.e. a NEWER frame's fragments arrive
//! while this one is still missing data FEC cannot fill. That edge triggers
//! request-recovery.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::adaptive_fec;
use crate::fec::FecScheme;
use crate::fragment::{Flags, FrameFragment};
use crate::seq::distance_wrapped;

/// A fully reassembled frame, ready to feed the decoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReassembledFrame {
    /// The frame's id.
    pub frame_id: u32,
    /// Whether this is a keyframe (IDR).
    pub keyframe: bool,
    /// Whether this is a crisp static refresh.
    pub crisp: bool,
    /// The AVCC byte buffer (length-prefixed NAL units), restored directly or via FEC.
    pub avcc: Vec<u8>,
    /// True when a data hole existed and FEC parity filled it to complete the frame.
    pub recovered_via_fec: bool,
    /// WF-8: this is a Long-Term-Reference frame; on a successful decode the client must
    /// reply `ack(frame_id)` so the host learns the client holds this LTR.
    pub is_ltr: bool,
    /// Bit 7 — this frame was encoded via `ForceLTRRefresh` (references only acked LTRs).
    pub acked_anchored: bool,
}

/// The outcome of feeding one datagram to the reassembler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReassemblyResult {
    /// More fragments are still needed for this frame; nothing to emit yet.
    Incomplete,
    /// The frame is complete and reassembled (possibly via FEC recovery).
    Completed(ReassembledFrame),
    /// The frame was abandoned: a fragment is missing and FEC could not recover it, so
    /// the caller must drop the frame and signal recovery. Carries the lost `frame_id`.
    Dropped {
        /// The lost frame's id.
        frame_id: u32,
    },
    /// The datagram belonged to a frame already completed or dropped — ignored.
    Stale,
}

#[derive(Debug, Default)]
struct Pending {
    frag_count: u16,
    keyframe: bool,
    crisp: bool,
    is_ltr: bool,
    acked_anchored: bool,
    /// FEC tier PINNED from the first fragment seen for this frame.
    fec_tier: u8,
    /// Data-fragment payloads by `frag_index` (the data range is `0 .. data_count`).
    data: HashMap<u16, Vec<u8>>,
    /// Parity-fragment payloads keyed by GROUP ORDER (0-based among parity frags), NOT by
    /// raw `frag_index`, so a lost group-0 parity never shifts the boundary.
    parity: HashMap<usize, Vec<u8>>,
    /// The observed parity boundary (lowest parity `frag_index` seen). Authoritative only
    /// in the no-FEC fallback; with FEC the boundary comes from the fragCount inversion.
    data_count: Option<usize>,
}

/// Reassembles fragmented frames by `frame_id`, detects loss, and applies FEC.
///
/// Owns mutable per-frame buffers; lives inside the single client receive loop (one
/// reassembler per video stream).
pub struct FrameReassembler {
    fec: Option<Box<dyn FecScheme>>,
    pending: HashMap<u32, Pending>,
    highest_retired_frame_id: Option<u32>,
    highest_seen_frame_id: Option<u32>,
    retired: HashSet<u32>,
    dropped_queue: VecDeque<u32>,
    fec_reorder_grace: i32,
}

impl FrameReassembler {
    /// Upper bound on a frame's declared fragment count (hostile-input guard). A real
    /// frame is at most a few thousand fragments; a larger value can only be hostile, so
    /// it is rejected before any per-frame buffer is allocated.
    pub const MAX_FRAGMENTS_PER_FRAME: usize = 8192;

    /// Builds a reassembler. `fec_reorder_grace` is how many frame-ids past the loss
    /// frontier a frame stays eligible for FEC while only awaiting (recoverable) parity
    /// that the packetizer emits last; floored at 0.
    #[must_use]
    pub fn new(fec: Option<Box<dyn FecScheme>>, fec_reorder_grace: i32) -> Self {
        Self {
            fec,
            pending: HashMap::new(),
            highest_retired_frame_id: None,
            highest_seen_frame_id: None,
            retired: HashSet::new(),
            dropped_queue: VecDeque::new(),
            fec_reorder_grace: fec_reorder_grace.max(0),
        }
    }

    /// Pops the next unrecoverably-lost `frame_id` detected during prior `ingest` calls,
    /// or `None`. The client drains this after each ingest and issues a recovery signal
    /// for each.
    pub fn next_dropped_frame(&mut self) -> Option<u32> {
        self.dropped_queue.pop_front()
    }

    /// Feeds one parsed fragment, returning the outcome FOR THE INGESTED FRAGMENT'S
    /// frame. Drops of older, now-hopeless frames are surfaced separately via
    /// [`next_dropped_frame`](Self::next_dropped_frame). As a convenience, when the
    /// ingested fragment is incomplete but its own frame became hopeless, `Dropped` is
    /// returned directly.
    pub fn ingest(&mut self, fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header;
        let frame_id = header.frame_id;

        // Hostile-input guard (UDP video has no auth beyond the mesh): reject an
        // implausible header BEFORE allocating any per-frame buffer.
        if !(header.frag_count > 0
            && usize::from(header.frag_count) <= Self::MAX_FRAGMENTS_PER_FRAME
            && header.frag_index < header.frag_count)
        {
            return ReassemblyResult::Stale;
        }

        if self.retired.contains(&frame_id) {
            return ReassemblyResult::Stale;
        }
        if let Some(retired_high) = self.highest_retired_frame_id {
            if distance_wrapped(frame_id, retired_high) <= 0
                && !self.pending.contains_key(&frame_id)
            {
                return ReassemblyResult::Stale;
            }
        }

        // Advance the loss frontier.
        match self.highest_seen_frame_id {
            Some(seen) if distance_wrapped(frame_id, seen) > 0 => {
                self.highest_seen_frame_id = Some(frame_id);
            }
            None => self.highest_seen_frame_id = Some(frame_id),
            Some(_) => {}
        }

        let entry = self.pending.entry(frame_id).or_insert_with(|| Pending {
            frag_count: header.frag_count,
            fec_tier: header.flags.fec_tier(),
            ..Pending::default()
        });
        entry.frag_count = header.frag_count;
        if header.flags.contains(Flags::KEYFRAME) {
            entry.keyframe = true;
        }
        if header.flags.contains(Flags::CRISP) {
            entry.crisp = true;
        }
        if header.flags.contains(Flags::IS_LTR) {
            entry.is_ltr = true;
        }
        if header.flags.contains(Flags::ACKED_ANCHORED) {
            entry.acked_anchored = true;
        }

        if header.flags.contains(Flags::PARITY) {
            let p_index = usize::from(header.frag_index);
            // group size needs `self.fec` (disjoint field) + this entry's pinned tier.
            let g_opt = self
                .fec
                .as_deref()
                .and_then(|f| adaptive_fec::group_size(entry.fec_tier, f.group_size()));
            let data_boundary = match g_opt {
                Some(g) => inverted_data_count(usize::from(entry.frag_count), g),
                None => p_index,
            };
            entry.data_count = Some(entry.data_count.unwrap_or(p_index).min(p_index));
            let group_order = p_index.saturating_sub(data_boundary);
            entry.parity.insert(group_order, fragment.payload);
        } else {
            entry.data.insert(header.frag_index, fragment.payload);
        }

        // Try to complete THIS frame.
        let result = self.try_complete(frame_id);

        // Sweep ALL pending frames strictly older than the frontier that can no longer
        // complete; queue them as drops (runs regardless of `result`, so completing a
        // newer frame never hides an older, hopeless one).
        self.sweep_hopeless_frames();

        if matches!(result, ReassemblyResult::Completed(_)) {
            return result;
        }

        // The ingested frame itself may have just been declared hopeless by the sweep.
        if !self.pending.contains_key(&frame_id) && self.dropped_queue.contains(&frame_id) {
            self.dropped_queue.retain(|&f| f != frame_id);
            return ReassemblyResult::Dropped { frame_id };
        }
        ReassemblyResult::Incomplete
    }

    fn try_complete(&mut self, frame_id: u32) -> ReassemblyResult {
        let fec = self.fec.as_deref();
        let Some(entry) = self.pending.get(&frame_id) else {
            return ReassemblyResult::Stale;
        };
        let Some((avcc, recovered_via_fec)) = assemble(fec, entry) else {
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

    fn sweep_hopeless_frames(&mut self) {
        let Some(frontier) = self.highest_seen_frame_id else {
            return;
        };
        let fec = self.fec.as_deref();
        let grace = self.fec_reorder_grace;
        let mut hopeless: Vec<u32> = self
            .pending
            .iter()
            .filter_map(|(&fid, entry)| {
                // fid strictly OLDER than the frontier: frontier - fid > 0.
                let age = distance_wrapped(frontier, fid);
                if age <= 0 || can_eventually_complete(fec, entry) {
                    return None;
                }
                // Hole(s) only fillable by not-yet-arrived parity → keep within the grace
                // window so reordered parity (emitted last) still has a chance to land.
                if awaiting_recoverable_parity(fec, entry) && age <= grace {
                    return None;
                }
                Some(fid)
            })
            .collect();
        // Drop oldest-first for deterministic recovery-signal ordering.
        hopeless.sort_by(|&a, &b| distance_wrapped(a, b).cmp(&0));
        for fid in hopeless {
            self.retire(fid);
            self.dropped_queue.push_back(fid);
        }
    }

    fn retire(&mut self, frame_id: u32) {
        self.pending.remove(&frame_id);
        self.retired.insert(frame_id);
        match self.highest_retired_frame_id {
            Some(high) if distance_wrapped(frame_id, high) > 0 => {
                self.highest_retired_frame_id = Some(frame_id);
            }
            None => self.highest_retired_frame_id = Some(frame_id),
            Some(_) => {}
        }
        // Bound the retired set so a long session doesn't grow it unboundedly.
        if self.retired.len() > 512 {
            if let Some(high) = self.highest_retired_frame_id {
                self.retired.retain(|&x| distance_wrapped(high, x) <= 256);
            }
        }
    }
}

/// The PER-FRAME FEC group size for `entry`: `None` for a no-FEC client OR an OFF-tier
/// frame, in which case the frame is treated as no-parity.
fn parity_group_size(fec: Option<&dyn FecScheme>, entry: &Pending) -> Option<usize> {
    fec.and_then(|f| adaptive_fec::group_size(entry.fec_tier, f.group_size()))
}

/// Resolves how many of a frame's fragments are DATA (vs FEC parity). With FEC, always
/// derive `data_count` from the unambiguous fragCount inversion (never the observed
/// parity boundary, which a lost group-0 parity would shift). With no FEC,
/// `data_count == frag_count`.
fn resolved_data_count(fec: Option<&dyn FecScheme>, entry: &Pending) -> usize {
    let total = usize::from(entry.frag_count);
    parity_group_size(fec, entry).map_or_else(
        || entry.data_count.unwrap_or(total),
        |g| inverted_data_count(total, g),
    )
}

/// Inverts `frag_count = data_count + ceil(data_count / group_size)` to recover the data
/// fragment count from the total. Monotonic in `data_count`, so a descending scan finds
/// the unique solution. A zero `group_size` (defensive) returns `total` unchanged.
const fn inverted_data_count(total: usize, group_size: usize) -> usize {
    if group_size < 1 {
        return total;
    }
    let mut d = total;
    while d > 0 {
        let parity = d.div_ceil(group_size);
        if d + parity == total {
            return d;
        }
        if d + parity < total {
            break;
        }
        d -= 1;
    }
    total
}

/// Returns the reassembled AVCC bytes if all data fragments are present (after FEC
/// recovery), else `None`. The bool is true when a hole existed and FEC filled it.
fn assemble(fec: Option<&dyn FecScheme>, entry: &Pending) -> Option<(Vec<u8>, bool)> {
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        // A zero-data frame: only valid if it is a single empty fragment at index 0.
        return entry.data.get(&0).map(|only| (only.clone(), false));
    }

    let mut data_fragments: Vec<Option<Vec<u8>>> = (0..data_count)
        .map(|i| entry.data.get(&(i as u16)).cloned())
        .collect();

    let had_hole = data_fragments.iter().any(Option::is_none);
    if had_hole {
        if let (Some(fec), Some(g)) = (fec, parity_group_size(fec, entry)) {
            let parity_count = usize::from(entry.frag_count).saturating_sub(data_count);
            let parity_fragments: Vec<Option<Vec<u8>>> = (0..parity_count)
                .map(|i| entry.parity.get(&i).cloned())
                .collect();
            fec.recover(&mut data_fragments, &parity_fragments, g);
        }
    }

    if data_fragments.iter().any(Option::is_none) {
        return None;
    }
    let mut avcc = Vec::new();
    for fragment in data_fragments {
        avcc.extend_from_slice(&fragment.expect("checked non-none above"));
    }
    Some((avcc, had_hole))
}

/// Whether a frame still has a chance to complete (all data present or FEC could fill
/// remaining holes).
fn can_eventually_complete(fec: Option<&dyn FecScheme>, entry: &Pending) -> bool {
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        return entry.data.contains_key(&0);
    }
    let Some(g) = parity_group_size(fec, entry) else {
        // No FEC (or OFF tier): ANY missing data fragment is terminal once "old".
        return !(0..data_count).any(|i| !entry.data.contains_key(&(i as u16)));
    };
    let mut index = 0;
    let mut group_index = 0;
    while index < data_count {
        let upper = (index + g).min(data_count);
        let missing = (index..upper)
            .filter(|&i| !entry.data.contains_key(&(i as u16)))
            .count();
        if missing >= 2 {
            return false;
        }
        if missing == 1 && !entry.parity.contains_key(&group_index) {
            return false;
        }
        index += g;
        group_index += 1;
    }
    true
}

/// True when the only obstacle is FEC parity that has not yet arrived: every group with a
/// missing data fragment is missing exactly one (XOR-recoverable) and that group's parity
/// has not been ingested. Such a frame is not permanently hopeless, so the sweep grants it
/// the reorder grace.
fn awaiting_recoverable_parity(fec: Option<&dyn FecScheme>, entry: &Pending) -> bool {
    let Some(g) = parity_group_size(fec, entry) else {
        return false;
    };
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        return false;
    }
    let mut index = 0;
    let mut group_index = 0;
    let mut saw_repairable_hole = false;
    while index < data_count {
        let upper = (index + g).min(data_count);
        let missing = (index..upper)
            .filter(|&i| !entry.data.contains_key(&(i as u16)))
            .count();
        if missing >= 2 {
            return false; // not parity-repairable: permanently hopeless
        }
        if missing == 1 {
            if entry.parity.contains_key(&group_index) {
                return false; // parity already here → not "awaiting"
            }
            saw_repairable_hole = true;
        }
        index += g;
        group_index += 1;
    }
    saw_repairable_hole
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fec::XorParityFec;
    use crate::fragment::{PacketizeOptions, VideoPacketizer};

    fn keyframe_opts() -> PacketizeOptions {
        PacketizeOptions {
            keyframe: true,
            ..PacketizeOptions::default()
        }
    }

    #[test]
    fn whole_frame_completes_in_order() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![5u8; VideoPacketizer::MAX_PAYLOAD_SIZE + 100];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(None, 2);
        let mut completed = None;
        for f in frags {
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("frame should complete");
        assert_eq!(rf.avcc, frame);
        assert!(rf.keyframe);
        assert!(!rf.recovered_via_fec);
    }

    #[test]
    fn fec_recovers_single_dropped_fragment() {
        let fec_host = XorParityFec::new(5);
        let mut p = VideoPacketizer::new(Some(Box::new(fec_host)));
        let frame = vec![3u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 2);
        let mut completed = None;
        for (i, f) in frags.into_iter().enumerate() {
            if i == 1 {
                continue; // drop one data fragment; parity in the same group recovers it
            }
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("FEC should recover the frame");
        assert_eq!(rf.avcc, frame);
        assert!(rf.recovered_via_fec);
    }

    #[test]
    fn unrecoverable_loss_drops_when_newer_frame_arrives() {
        // No FEC: losing a data fragment of frame 0 is terminal once frame 1 appears.
        let mut p = VideoPacketizer::new(None);
        let frame0 = vec![1u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 3];
        let frame1 = vec![2u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
        let f0 = p.packetize(&frame0, keyframe_opts());
        let f1 = p.packetize(&frame1, keyframe_opts());

        let mut r = FrameReassembler::new(None, 2);
        // ingest only fragments 0 and 2 of frame 0 (fragment 1 lost)
        r.ingest(f0[0].clone());
        r.ingest(f0[2].clone());
        // frame 1 arrives, advancing the frontier → frame 0 is hopeless
        r.ingest(f1[0].clone());
        assert_eq!(r.next_dropped_frame(), Some(0));
        assert_eq!(r.next_dropped_frame(), None);
    }

    #[test]
    fn stale_fragment_for_retired_frame_is_ignored() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![9u8; 10];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(None, 2);
        assert!(matches!(
            r.ingest(frags[0].clone()),
            ReassemblyResult::Completed(_)
        ));
        // re-ingesting the same (now retired) frame's fragment is stale
        assert_eq!(r.ingest(frags[0].clone()), ReassemblyResult::Stale);
    }

    #[test]
    fn hostile_fragcount_rejected() {
        let mut frag = {
            let mut p = VideoPacketizer::new(None);
            p.packetize(&[1, 2, 3], keyframe_opts())[0].clone()
        };
        frag.header.frag_count = (FrameReassembler::MAX_FRAGMENTS_PER_FRAME + 1) as u16;
        let mut r = FrameReassembler::new(None, 2);
        assert_eq!(r.ingest(frag), ReassemblyResult::Stale);
    }

    #[test]
    fn inverted_data_count_matches_forward() {
        // forward: data + ceil(data/g); inversion must recover `data`.
        for g in 1..=10usize {
            for data in 1..=200usize {
                let total = data + data.div_ceil(g);
                assert_eq!(inverted_data_count(total, g), data, "g={g} data={data}");
            }
        }
    }
}
