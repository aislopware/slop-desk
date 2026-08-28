//! The packetize lane: one frame in, its wire datagrams and their `frame_id` out, atomically.
//!
//! Replaces the Swift host's packetize lane, and with it the `VideoSendScheduler` half of its
//! session logic that tagged each datagram with the channel it rides.
//!
//! ## What this module OWNS
//! Serialization of the packetizer's two counters, and nothing else. A [`VideoPacketizer`] carries
//! `next_stream_seq` and `next_frame_id`; the host must read the id it is ABOUT to assign — to
//! record the `frame_id ↔ LTR token` mapping for the frame in flight — and then assign it,
//! with no other encoder output landing in between. One lock hold covers both, so the pair is
//! atomic and the ids come out in encode order.
//!
//! ## What it ASKS for
//! Every decision. The MTU split, the FEC ladder, the interleave and the 19-byte header stamp are
//! [`slopdesk_video::packetizer`]'s, pinned byte-for-byte by `golden/golden_vectors.json`; the
//! channel each finished datagram rides is
//! [`slopdesk_video::recovery_routing::schedule_frame_raw`]'s. This module adds a lock; if it ever
//! needs to add a rule, the rule belongs there.
//!
//! ## Why there is no thread here
//! The Swift was an `actor` for one reason: to get packetization OFF the session actor, whose hop
//! also served input and geometry. In this daemon those already run on their own threads — the
//! mux receive loop takes input, the encoder pump calls this — so a hand-off would buy a queue
//! and a wake-up and no concurrency. What actually survives the port is the atomicity above, and a
//! `Mutex` gives exactly that. So [`PacketizeLane`] takes `&self`, is `Sync`, and any thread may
//! call it; callers serialize only for as long as one frame's fragmentation takes.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use slopdesk_video::fec::ReedSolomonFec;
use slopdesk_video::packetizer::{PacketizeOptions, VideoPacketizer};
use slopdesk_video::recovery_routing::{Outgoing, schedule_frame_raw};

/// One packetized frame: the id its fragments carry, and the datagrams themselves.
///
/// The datagrams are behind an [`Arc`] because the send path copies this handle at least twice —
/// the retransmit log takes one, the send lane takes one, and a keyframe takes a second, delayed
/// duplicate. Swift got that sharing free from copy-on-write arrays; Rust has to say it, and a
/// missing `Arc` here would clone a 400 KB IDR on the encoder's own thread.
#[derive(Debug, Clone)]
pub struct PacketizedFrame {
    /// The `frame_id` every fragment of this frame carries.
    pub frame_id: u32,
    /// The frame's datagrams, in send order — data fragments, then parity, then any reorder the
    /// interleaver applied.
    pub outgoings: Arc<[Outgoing]>,
}

/// The packetizer, plus the lock that keeps its two counters in step with the ids it hands out.
#[derive(Debug)]
pub struct PacketizeLane {
    packetizer: Mutex<VideoPacketizer>,
}

impl PacketizeLane {
    /// Builds a lane over a packetizer. `fec` of `None` sends data fragments only.
    #[must_use]
    pub const fn new(fec: Option<ReedSolomonFec>) -> Self {
        Self {
            packetizer: Mutex::new(VideoPacketizer::new(fec)),
        }
    }

    /// The FEC scheme the underlying packetizer was built with, which the host also reads for its
    /// group size when it sizes a recovery request.
    #[must_use]
    pub fn fec(&self) -> Option<ReedSolomonFec> {
        let packetizer = self.locked();
        let scheme = packetizer.fec();
        drop(packetizer);
        scheme
    }

    /// Fragments one encoded frame, answering the id it was given together with its datagrams.
    ///
    /// The id read and the fragmentation happen under ONE lock hold: a caller that read the id
    /// first and packetized second could have another thread's frame slip between, and the LTR
    /// mapping it recorded would then name the wrong frame.
    #[must_use]
    pub fn packetize(&self, frame: &[u8], options: PacketizeOptions) -> PacketizedFrame {
        let mut packetizer = self.locked();
        let frame_id = packetizer.peek_next_frame_id();
        let datagrams = packetizer.packetize_raw(frame, options);
        // Released before the datagrams are wrapped: the tagging is pure and the next frame should
        // not wait on it.
        drop(packetizer);
        PacketizedFrame {
            frame_id,
            outgoings: schedule_frame_raw(datagrams).into(),
        }
    }

    /// The lock, taken through the poison it cannot be hurt by: a panic mid-packetize leaves the
    /// counters at whatever they had reached, which is a gap in `stream_seq` — exactly what a
    /// lost datagram looks like, and the client already recovers from that.
    fn locked(&self) -> MutexGuard<'_, VideoPacketizer> {
        self.packetizer.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::Arc;

    use slopdesk_video::fec::ReedSolomonFec;
    use slopdesk_video::fragment::{FrameFragmentHeader, MAX_PAYLOAD_SIZE};
    use slopdesk_video::packetizer::{PacketizeOptions, VideoPacketizer};
    use slopdesk_video::recovery_routing::{Outgoing, VideoChannel, schedule_frame_raw};

    use super::PacketizeLane;

    /// A frame big enough to need several fragments, filled with a byte the test can recognise.
    fn frame(fragments: usize, fill: u8) -> Vec<u8> {
        vec![fill; MAX_PAYLOAD_SIZE * fragments]
    }

    #[test]
    fn the_frame_id_is_assigned_in_encode_order() {
        let lane = PacketizeLane::new(None);
        let first = lane.packetize(&frame(2, 1), PacketizeOptions::keyframe());
        let second = lane.packetize(&frame(1, 2), PacketizeOptions::default());
        let third = lane.packetize(&frame(1, 3), PacketizeOptions::default());
        assert_eq!(
            (first.frame_id, second.frame_id, third.frame_id),
            (0, 1, 2),
            "the id answered is the one the fragments carry, and it advances once per frame"
        );
    }

    #[test]
    fn the_answered_id_is_the_one_stamped_on_every_fragment() {
        let lane = PacketizeLane::new(Some(ReedSolomonFec::default()));
        drop(lane.packetize(&frame(1, 9), PacketizeOptions::default()));
        let packed = lane.packetize(&frame(6, 4), PacketizeOptions::keyframe());
        for outgoing in packed.outgoings.iter() {
            let (header, _) =
                FrameFragmentHeader::decode(&outgoing.bytes).expect("a datagram we just encoded");
            assert_eq!(
                header.frame_id, packed.frame_id,
                "the lane must not answer an id the wire does not carry"
            );
        }
    }

    #[test]
    fn every_datagram_of_a_frame_rides_the_video_channel() {
        let lane = PacketizeLane::new(Some(ReedSolomonFec::default()));
        let packed = lane.packetize(&frame(7, 5), PacketizeOptions::keyframe());
        assert!(
            packed.outgoings.len() > 7,
            "the FEC scheme must have added parity, or this test proves nothing about it"
        );
        assert!(
            packed
                .outgoings
                .iter()
                .all(|outgoing| outgoing.channel == VideoChannel::Video),
            "parity is not a separate channel"
        );
    }

    #[test]
    fn the_lane_is_byte_identical_to_the_packetizer_it_wraps() {
        let options = PacketizeOptions {
            keyframe: true,
            host_send_ts_millis: 77,
            interleave: true,
            ..PacketizeOptions::default()
        };
        let payload = frame(9, 6);
        let mut bare = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let expected = bare.packetize_raw(&payload, options);

        let lane = PacketizeLane::new(Some(ReedSolomonFec::default()));
        let packed = lane.packetize(&payload, options);
        let actual: Vec<Vec<u8>> = packed
            .outgoings
            .iter()
            .map(|outgoing| outgoing.bytes.clone())
            .collect();
        assert_eq!(
            actual, expected,
            "the lane may add a lock and a channel tag, never a byte"
        );
    }

    #[test]
    fn a_zero_byte_frame_still_occupies_one_datagram() {
        let lane = PacketizeLane::new(None);
        let packed = lane.packetize(&[], PacketizeOptions::default());
        assert_eq!(
            packed.outgoings.len(),
            1,
            "an empty frame is still a frame — the client needs the header to advance"
        );
        assert_eq!(packed.frame_id, 0);
    }

    #[test]
    fn two_threads_never_interleave_the_counters() {
        let lane = Arc::new(PacketizeLane::new(None));
        // The collect is LOAD-BEARING: it spawns all four threads before the first join, which is
        // the whole point of a test about two of them running at once.
        #[expect(
            clippy::needless_collect,
            reason = "collecting IS the concurrency this test needs"
        )]
        let threads: Vec<_> = (0..4)
            .map(|which| {
                let lane = Arc::clone(&lane);
                std::thread::spawn(move || {
                    (0..25)
                        .map(|_| lane.packetize(&frame(1, which), PacketizeOptions::default()))
                        .map(|packed| packed.frame_id)
                        .collect::<Vec<u32>>()
                })
            })
            .collect();

        let mut ids: Vec<u32> = threads
            .into_iter()
            .flat_map(|thread| thread.join().expect("a test thread that only packetizes"))
            .collect();
        ids.sort_unstable();
        assert_eq!(
            ids,
            (0..100).collect::<Vec<u32>>(),
            "every id handed out exactly once, however the threads raced"
        );
    }

    #[test]
    fn the_video_constructor_is_the_channel_the_retransmit_path_restores() {
        assert_eq!(schedule_frame_raw(vec![vec![1, 2, 3]]), vec![Outgoing {
            channel: VideoChannel::Video,
            bytes: vec![1, 2, 3],
        }]);
    }
}
