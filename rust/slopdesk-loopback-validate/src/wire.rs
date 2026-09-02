//! The in-process wire: packetize, lose, encode/decode the fragment, reassemble.
//!
//! Every scenario shares this loop, because every scenario is the same loop with a different loss
//! model and a different thing being measured. The survivors go through `FrameFragment::encode` and
//! `decode` — the REAL codec, not a hand-off of the struct — so a field that stopped surviving the
//! round trip would show here rather than on a client.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::fec::ReedSolomonFec;
use slopdesk_video::fragment::FrameFragment;
use slopdesk_video::loopback::{LossModel, ScenarioStats, should_drop};
use slopdesk_video::packetizer::{PacketizeOptions, VideoPacketizer};
use slopdesk_video::reassembler::{FrameReassembler, ReassembledFrame, ReassemblyResult};

/// The FEC group size every scenario packetizes at. Five data shards per group, which is what the
/// tier ladder's group sizes are expressed against.
pub(crate) const GROUP: usize = 5;

/// What one frame's fragments made of themselves on the far side.
#[derive(Debug, Default)]
pub(crate) struct Transmitted {
    /// Frames the reassembler completed, in the order it completed them.
    pub completed: Vec<ReassembledFrame>,
    /// Frames it gave up on during this batch.
    pub dropped: usize,
}

/// The two halves of the wire, kept together because a packetizer and a reassembler built with
/// different parity counts would silently stop recovering.
#[derive(Debug)]
pub(crate) struct Wire {
    /// The send half.
    pub packetizer: VideoPacketizer,
    /// The receive half.
    pub reassembler: FrameReassembler,
    /// The monotonic host stamp each fragment carries, advanced one frame interval per frame.
    host_ts: u32,
    /// The scenario-global wire position, which the `EveryN` loss model counts.
    global_index: usize,
}

impl Wire {
    /// A wire whose two halves share one parity count.
    ///
    /// `parity` of one is the XOR-equivalent single-hole codec — byte-identical on the wire to what
    /// shipped before Reed-Solomon existed. Two or more recovers that many holes per group.
    #[must_use]
    pub(crate) fn new(parity: usize) -> Self {
        Self {
            packetizer: VideoPacketizer::new(Some(ReedSolomonFec::new(GROUP, parity))),
            // Two frame ids of reorder grace — the client's own default, and what decides how long
            // a hole stays FEC-eligible before the frame is declared lost. A wire that gave up
            // sooner would report drops the real client never sees.
            reassembler: FrameReassembler::new(Some(ReedSolomonFec::new(GROUP, parity)), 2),
            host_ts: 1,
            global_index: 0,
        }
    }

    /// The frame id the NEXT packetize will assign, read before it to mirror the host's LTR map.
    #[must_use]
    pub(crate) const fn peek_frame_id(&self) -> u32 {
        self.packetizer.peek_next_frame_id()
    }

    /// Fragments one frame and advances the host stamp by one frame interval.
    pub(crate) fn packetize(&mut self, avcc: &[u8], options: PacketizeOptions) -> Vec<FrameFragment> {
        let stamped = PacketizeOptions {
            host_send_ts_millis: self.host_ts,
            ..options
        };
        let fragments = self.packetizer.packetize(avcc, stamped);
        self.host_ts = self.host_ts.wrapping_add(16);
        fragments
    }

    /// Fragments one frame at a stamp the CALLER owns.
    ///
    /// The feedback scenarios run a virtual clock the wire knows nothing about, and the host stamp
    /// is what the round-trip estimate is computed from — so those pass their own clock rather than
    /// the fixed frame-interval advance [`Self::packetize`] applies.
    pub(crate) fn packetize_stamped(&mut self, avcc: &[u8], options: PacketizeOptions) -> Vec<FrameFragment> {
        self.packetizer.packetize(avcc, options)
    }

    /// Sends one frame's fragments through the loss model and the fragment codec.
    ///
    /// Answers what the far side made of them and folds the counters into `stats`. A frame the
    /// reassembler gives up on mid-batch is reported in [`Transmitted::dropped`] rather than only
    /// counted, because a caller that must re-anchor learns about it HERE — the deferred queue
    /// [`Self::drain_dropped`] holds only the ones aged out past the reorder grace.
    pub(crate) fn transmit(
        &mut self,
        fragments: &[FrameFragment],
        loss: LossModel,
        tier_group: usize,
        stats: &mut ScenarioStats,
    ) -> Transmitted {
        let mut sent = Transmitted::default();
        for (local, fragment) in fragments.iter().enumerate() {
            stats.fragments_sent = stats.fragments_sent.saturating_add(1);
            let drop = should_drop(fragment, self.global_index, local, loss, tier_group);
            self.global_index = self.global_index.saturating_add(1);
            if drop {
                stats.fragments_dropped = stats.fragments_dropped.saturating_add(1);
                continue;
            }
            let Ok(parsed) = FrameFragment::decode(&fragment.encode()) else {
                continue;
            };
            match self.reassembler.ingest(parsed) {
                ReassemblyResult::Completed(frame) => {
                    stats.reassembled = stats.reassembled.saturating_add(1);
                    if frame.recovered_via_fec {
                        stats.fec_recovered = stats.fec_recovered.saturating_add(1);
                    }
                    sent.completed.push(frame);
                },
                ReassemblyResult::Dropped { .. } => {
                    stats.frames_dropped = stats.frames_dropped.saturating_add(1);
                    sent.dropped = sent.dropped.saturating_add(1);
                },
                ReassemblyResult::Incomplete | ReassemblyResult::Stale => {},
            }
        }
        sent
    }

    /// Drains the deferred drop queue, answering how many frames it held.
    ///
    /// The reassembler defers a drop past its reorder grace, so a frame declared lost mid-burst is
    /// reported here rather than at the fragment that finally aged it out.
    pub(crate) fn drain_dropped(&mut self, stats: &mut ScenarioStats) -> usize {
        let mut count = 0;
        while self.reassembler.next_dropped_frame().is_some() {
            stats.frames_dropped = stats.frames_dropped.saturating_add(1);
            count += 1;
        }
        count
    }

    /// Drains the deferred drop queue without counting it, for a scenario whose whole-frame loss is
    /// deliberate and already accounted for.
    pub(crate) fn discard_dropped(&mut self) {
        while self.reassembler.next_dropped_frame().is_some() {}
    }
}
