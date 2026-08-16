//! The audio jitter STAGE: every buffering decision between the decoder and whatever plays.
//!
//! Decoded ten-millisecond frames of interleaved samples enter keyed by their wire sequence, and
//! come back out as a steady stream. Four rules, and each one is there because the alternative was
//! audible.
//!
//! PRIME — silence until the target depth is buffered, so playback starts with enough slack to
//! absorb ordinary arrival jitter. It is the audio mirror of the video pacer's priming.
//!
//! UNDERRUN — the consumer ran dry mid-play, so conceal with silence and drop BACK to priming.
//! Re-inflating before playing again is the whole point: resuming one frame at a time is a crackle,
//! not a recovery.
//!
//! REORDER — frames insert in wrap-aware sequence order, so a swapped pair of datagrams still plays
//! in order. Anything at or behind the play frontier arrived too late to matter and is dropped
//! rather than played out of place.
//!
//! HIGH WATER — past the pending cap the OLDEST frame is dropped, which skips forward. Stale audio
//! is worse than a click, and audio must never buy loss avoidance with standing latency.
//!
//! The sequence space is session-scoped and SHARED with the channel's config packets, so gaps
//! between pushed frames are normal and the stage plays across them seamlessly.
//!
//! What is NOT here is the lock-free hand-off ring the render callback drains. That ring is raw
//! storage partitioned by two atomic counters — the one structure in the audio path that exists to
//! keep a real-time thread from ever blocking on the producer — and it belongs to the runtime that
//! owns the audio unit. Every buffering DECISION is here; the hand-off is plumbing.

use crate::reassembler::distance_wrapped;

/// Cumulative policy counters. They are monotonic odometers rather than levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AudioJitterStats {
    /// Frames accepted into the stage.
    pub frames_pushed: u64,
    /// Frames dropped for arriving at or behind the play frontier.
    pub late_dropped: u64,
    /// Frames dropped as duplicates of a pending frame, which is a re-delivery.
    pub duplicate_dropped: u64,
    /// Oldest-pending frames dropped past the high-water mark.
    pub overflow_dropped: u64,
    /// How many times the stage ran dry mid-play. Priming silence is NOT an underrun.
    pub underruns: u64,
    /// Zero samples emitted, across both priming and underrun tails.
    pub silence_samples: u64,
}

/// One decoded frame, still keyed by the sequence it arrived under.
#[derive(Debug, Clone, PartialEq)]
struct Block {
    seq: u32,
    samples: Vec<f32>,
}

/// The stage.
#[derive(Debug, Clone, PartialEq)]
pub struct AudioJitterBuffer {
    channels: usize,
    target_depth_frames: usize,
    high_water_frames: usize,
    /// Pending and not-yet-reclaimed frames, in wrap-aware sequence order. The leading consumed
    /// entries are fully played and await reclaim on the push side.
    blocks: Vec<Block>,
    consumed_blocks: usize,
    /// The read offset in samples into the first unconsumed block, for a partial pull.
    head_sample_offset: usize,
    /// The sequence of the newest frame fully played or overflow-dropped. A push at or behind it is
    /// late.
    play_frontier: Option<u32>,
    primed: bool,
    stats: AudioJitterStats,
}

impl AudioJitterBuffer {
    /// A stage for the given interleaved channel count and depth policy. Every argument is floored
    /// at what the policy can actually mean: one channel, one frame of target depth, and a high
    /// water at least the target.
    #[must_use]
    pub const fn new(channels: usize, target_depth_frames: usize, high_water_frames: usize) -> Self {
        let target = if target_depth_frames > 1 {
            target_depth_frames
        } else {
            1
        };
        let high_water = if high_water_frames > target {
            high_water_frames
        } else {
            target
        };
        Self {
            channels: if channels > 1 { channels } else { 1 },
            target_depth_frames: target,
            high_water_frames: high_water,
            blocks: Vec::new(),
            consumed_blocks: 0,
            head_sample_offset: 0,
            play_frontier: None,
            primed: false,
            stats: AudioJitterStats {
                frames_pushed: 0,
                late_dropped: 0,
                duplicate_dropped: 0,
                overflow_dropped: 0,
                underruns: 0,
                silence_samples: 0,
            },
        }
    }

    /// The interleaved channel count.
    #[must_use]
    pub const fn channels(&self) -> usize {
        self.channels
    }

    /// How many frames must be buffered before playback starts.
    #[must_use]
    pub const fn target_depth_frames(&self) -> usize {
        self.target_depth_frames
    }

    /// The pending-frame cap, past which the oldest is dropped.
    #[must_use]
    pub const fn high_water_frames(&self) -> usize {
        self.high_water_frames
    }

    /// Whether the stage has filled to its target depth and is playing rather than priming.
    #[must_use]
    pub const fn primed(&self) -> bool {
        self.primed
    }

    /// The cumulative counters.
    #[must_use]
    pub const fn stats(&self) -> AudioJitterStats {
        self.stats
    }

    /// The unplayed frame count, which is the stage's live depth.
    #[must_use]
    pub const fn pending_frames(&self) -> usize {
        self.blocks.len() - self.consumed_blocks
    }

    /// The samples available to pull, with a partially played head accounted for.
    #[must_use]
    pub fn available_samples(&self) -> usize {
        let total: usize = self
            .blocks
            .iter()
            .skip(self.consumed_blocks)
            .map(|block| block.samples.len())
            .sum();
        total.saturating_sub(self.head_sample_offset)
    }

    /// Offers one decoded frame. An empty sample set is a decoder miss rather than a frame, and is
    /// dropped without touching any counter.
    pub fn push(&mut self, seq: u32, samples: Vec<f32>) {
        if samples.is_empty() {
            return;
        }
        // Reclaim the consumed frames HERE, on the decode side, so the render side never frees.
        if self.consumed_blocks > 0 {
            self.blocks.drain(..self.consumed_blocks);
            self.consumed_blocks = 0;
        }
        if self.blocks.iter().any(|block| block.seq == seq) {
            self.stats.duplicate_dropped += 1;
            return;
        }
        if let Some(frontier) = self.effective_frontier()
            && distance_wrapped(seq, frontier) <= 0
        {
            self.stats.late_dropped += 1;
            return;
        }
        // Insert in wrap-aware order, walking from the end, because in-order arrival appends.
        let mut index = self.blocks.len();
        while index > 0
            && self
                .blocks
                .get(index - 1)
                .is_some_and(|block| distance_wrapped(seq, block.seq) < 0)
        {
            index -= 1;
        }
        self.blocks.insert(index, Block { seq, samples });
        self.stats.frames_pushed += 1;
        // High water: drop the OLDEST pending frames, which skips forward. Advancing the frontier
        // past each dropped sequence makes a straggling re-send a late drop rather than a
        // re-insert, so the same frame cannot bounce back into the ring behind what already played.
        while self.pending_frames() > self.high_water_frames {
            let dropped = self.blocks.remove(0);
            self.head_sample_offset = 0;
            self.play_frontier = Some(dropped.seq);
            self.stats.overflow_dropped += 1;
        }
        if !self.primed && self.pending_frames() >= self.target_depth_frames {
            self.primed = true;
        }
    }

    /// Fills the buffer with the next interleaved samples, zero-filling whatever the stage cannot
    /// supply — either priming, or a mid-play underrun, which drops back to priming.
    pub fn pull(&mut self, out: &mut [f32]) {
        if out.is_empty() {
            return;
        }
        let wrote = if self.primed { self.copy_available(out) } else { 0 };
        if wrote >= out.len() {
            return;
        }
        if let Some(tail) = out.get_mut(wrote..) {
            tail.fill(0.0);
        }
        let silence = out.len() - wrote;
        self.stats.silence_samples += silence as u64;
        if self.primed {
            // Ran dry mid-play: back to priming, so playback resumes with full slack rather than
            // one frame at a time.
            self.stats.underruns += 1;
            self.primed = false;
        }
    }

    /// Pulls a whole count of interleaved sample-frames, silence-filled. The diagnostic surface;
    /// a live engine drains through [`Self::drain_available`] instead.
    #[must_use]
    pub fn pull_frames(&mut self, frame_count: usize) -> Vec<f32> {
        let mut out = vec![0.0; frame_count * self.channels];
        self.pull(&mut out);
        out
    }

    /// The producer-side drain for a hand-off ring: copies what is available and marks it consumed,
    /// with no zero-fill and no underrun re-prime.
    ///
    /// Running short HERE only means nothing is staged to hand off, which at a ten-millisecond push
    /// cadence against a slightly longer render quantum is routine phase alignment rather than
    /// starvation. Real consumer starvation arrives through [`Self::note_consumer_starved`].
    pub fn drain_available(&mut self, out: &mut [f32]) -> usize {
        if !self.primed || out.is_empty() {
            return 0;
        }
        self.copy_available(out)
    }

    /// The hand-off consumer ran dry mid-play.
    ///
    /// Detected on the producer side, because the render callback itself only zero-fills and must
    /// never touch stage state. The policy mirrors the pull path's: drop back to priming so
    /// playback resumes with full slack. Pending frames stay buffered and re-count toward the
    /// re-prime.
    pub const fn note_consumer_starved(&mut self) {
        if !self.primed {
            return;
        }
        self.stats.underruns += 1;
        self.primed = false;
    }

    /// Skips the oldest PENDING frame forward — the depth-bound drop a pump applies when the
    /// combined stage and hand-off depth passes high water, which the push-side check cannot see
    /// because it counts only staged frames.
    ///
    /// The semantics match the push-side drop: the frontier advances past the dropped sequence and
    /// a partially handed-off head is abandoned mid-frame. It never touches a consumed block
    /// awaiting reclaim, and it never re-primes — shedding latency is a skip, not an underrun.
    pub fn drop_oldest_pending(&mut self) {
        if self.consumed_blocks >= self.blocks.len() {
            return;
        }
        let dropped = self.blocks.remove(self.consumed_blocks);
        self.head_sample_offset = 0;
        self.play_frontier = Some(dropped.seq);
        self.stats.overflow_dropped += 1;
    }

    /// Drops everything buffered and returns to priming, for a local disable.
    ///
    /// It KEEPS the play frontier: the channel's sequence is session-scoped and monotonic, because
    /// config packets consume ids too, so frames arriving after a re-enable are strictly newer and
    /// must not be mistaken for late. The counters stay cumulative.
    pub fn clear(&mut self) {
        self.blocks.clear();
        self.consumed_blocks = 0;
        self.head_sample_offset = 0;
        self.primed = false;
    }

    /// The frontier a push must be strictly ahead of. Once the head frame has BEGUN playing,
    /// nothing at or behind its sequence can be inserted, because it would play out of order.
    fn effective_frontier(&self) -> Option<u32> {
        if self.head_sample_offset > 0
            && let Some(head) = self.blocks.get(self.consumed_blocks)
        {
            return Some(head.seq);
        }
        self.play_frontier
    }

    /// Copies as many buffered samples as the destination holds, advancing the consumed marker and
    /// the play frontier as blocks complete. Consumed frames are only FLAGGED consumed; the next
    /// push reclaims them, so no free happens on a consumption path.
    fn copy_available(&mut self, out: &mut [f32]) -> usize {
        let mut wrote = 0;
        while wrote < out.len() {
            let Some(block) = self.blocks.get(self.consumed_blocks) else {
                break;
            };
            let (seq, total) = (block.seq, block.samples.len());
            let Some(rest) = block.samples.get(self.head_sample_offset..) else {
                break;
            };
            let take = rest.len().min(out.len() - wrote);
            let (Some(source), Some(target)) = (rest.get(..take), out.get_mut(wrote..wrote + take)) else {
                break;
            };
            target.copy_from_slice(source);
            wrote += take;
            self.head_sample_offset += take;
            if self.head_sample_offset >= total {
                self.play_frontier = Some(seq);
                self.consumed_blocks += 1;
                self.head_sample_offset = 0;
            }
        }
        wrote
    }
}

/// The ring top-up bound in samples.
///
/// The render side only needs the target depth of headroom between pushes. Everything beyond it
/// stays STAGED, which is what lets the combined depth bound shed it — samples committed to a
/// hand-off ring belong to the consumer and can never be taken back.
#[must_use]
pub const fn ring_target_samples(target_depth_frames: usize, samples_per_frame: usize) -> usize {
    target_depth_frames * samples_per_frame
}

/// The combined stage-plus-ring depth cap in samples, which is the client-side latency bound the
/// whole audio policy is written against.
#[must_use]
pub const fn high_water_samples(high_water_frames: usize, samples_per_frame: usize) -> usize {
    high_water_frames * samples_per_frame
}

/// Whether the render side actually played conceal silence since the last push.
///
/// The ring's shortfall ODOMETER is the signal, not a fill level of zero: a consumer that drains
/// the ring exactly dry zero-fills nothing, and at a ten-millisecond push cadence against a
/// slightly longer render quantum that phase alignment is routine. Priming silence is excluded by
/// the emitted flag, so a stage that has handed nothing off yet can never be called starved.
#[must_use]
pub const fn consumer_starved(
    primed: bool,
    emitted_since_prime: bool,
    shortfall_now: u64,
    last_shortfall: u64,
) -> bool {
    primed && emitted_since_prime && shortfall_now != last_shortfall
}

/// Sheds the oldest staged frames until the combined depth is back at the target.
///
/// The stage's own high-water check sees only STAGED frames, so the combined stage and ring fill is
/// the real client-side latency figure. Past high water, in-flow matches out-flow and a backlog
/// never drains on its own: one clean skip forward beats permanently added latency, because stale
/// audio is worse than a click. Returns how many frames were shed.
pub fn shed_to_depth_bound(
    stage: &mut AudioJitterBuffer,
    ring_fill: usize,
    samples_per_frame: usize,
) -> usize {
    let high_water = high_water_samples(stage.high_water_frames(), samples_per_frame);
    let target = ring_target_samples(stage.target_depth_frames(), samples_per_frame);
    if stage.available_samples() + ring_fill <= high_water {
        return 0;
    }
    let mut shed = 0;
    while stage.pending_frames() > 0 && stage.available_samples() + ring_fill > target {
        stage.drop_oldest_pending();
        shed += 1;
    }
    shed
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::indexing_slicing,
        reason = "the samples are exact small integers written as floats, and a test that indexes past its \
                  own fixture should fail loudly"
    )]

    use super::{AudioJitterBuffer, consumer_starved, shed_to_depth_bound};

    /// A small sequence as a marker value, which every f32 holds exactly.
    fn marker(seq: u32) -> f32 {
        f32::from(u8::try_from(seq).unwrap_or(u8::MAX))
    }

    /// One frame of `count` samples, every one carrying the frame's own marker.
    fn frame(marker: f32, count: usize) -> Vec<f32> {
        vec![marker; count]
    }

    /// A stage primed with two frames of four samples each.
    fn primed() -> AudioJitterBuffer {
        let mut stage = AudioJitterBuffer::new(2, 2, 8);
        stage.push(1, frame(1.0, 4));
        assert!(!stage.primed(), "one frame is not the target depth");
        stage.push(2, frame(2.0, 4));
        assert!(stage.primed());
        stage
    }

    #[test]
    fn priming_plays_silence_until_the_target_depth_is_buffered() {
        let mut stage = AudioJitterBuffer::new(2, 2, 8);
        stage.push(1, frame(1.0, 4));
        let out = stage.pull_frames(2);
        assert_eq!(out, vec![0.0; 4]);
        assert_eq!(stage.stats().silence_samples, 4);
        assert_eq!(stage.stats().underruns, 0, "priming silence is not an underrun");
    }

    #[test]
    fn a_primed_stage_plays_its_frames_in_order() {
        let mut stage = primed();
        let out = stage.pull_frames(4);
        assert_eq!(out, vec![1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0]);
        assert_eq!(stage.stats().silence_samples, 0);
    }

    #[test]
    fn a_partial_pull_resumes_mid_frame() {
        let mut stage = primed();
        assert_eq!(stage.pull_frames(1), vec![1.0, 1.0]);
        assert_eq!(stage.pull_frames(1), vec![1.0, 1.0]);
        assert_eq!(stage.pull_frames(1), vec![2.0, 2.0]);
        assert_eq!(stage.available_samples(), 2);
    }

    #[test]
    fn running_dry_mid_play_conceals_and_drops_back_to_priming() {
        let mut stage = primed();
        let out = stage.pull_frames(6);
        assert_eq!(out.len(), 12);
        assert_eq!(out[8], 0.0, "the tail is conceal silence");
        assert_eq!(stage.stats().underruns, 1);
        assert_eq!(stage.stats().silence_samples, 4);
        assert!(!stage.primed(), "re-inflate before playing again");
    }

    #[test]
    fn a_swapped_pair_of_datagrams_still_plays_in_order() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(2, frame(2.0, 2));
        stage.push(1, frame(1.0, 2));
        assert_eq!(stage.pull_frames(4), vec![1.0, 1.0, 2.0, 2.0]);
    }

    #[test]
    fn a_frame_behind_the_play_frontier_is_too_late_to_matter() {
        let mut stage = primed();
        assert_eq!(stage.pull_frames(2), vec![1.0, 1.0, 1.0, 1.0]);
        stage.push(1, frame(9.0, 4));
        assert_eq!(stage.stats().late_dropped, 1);
        assert_eq!(stage.pull_frames(2), vec![2.0, 2.0, 2.0, 2.0]);
    }

    #[test]
    fn a_frame_behind_the_half_played_head_cannot_be_inserted_either() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(5, frame(5.0, 4));
        stage.push(6, frame(6.0, 4));
        assert_eq!(stage.pull_frames(2), vec![5.0, 5.0]);
        stage.push(4, frame(9.0, 4));
        assert_eq!(
            stage.stats().late_dropped,
            1,
            "the head has begun playing past it"
        );
        stage.push(5, frame(9.0, 4));
        assert_eq!(
            stage.stats().duplicate_dropped,
            1,
            "the half-played head is still a pending frame, so its re-send is a duplicate",
        );
    }

    #[test]
    fn a_re_delivered_pending_frame_is_a_duplicate_rather_than_a_reorder() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(1, frame(1.0, 2));
        stage.push(1, frame(9.0, 2));
        assert_eq!(stage.stats().duplicate_dropped, 1);
        assert_eq!(stage.pending_frames(), 1);
    }

    #[test]
    fn an_empty_sample_set_is_a_decoder_miss_and_touches_no_counter() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(1, Vec::new());
        assert_eq!(stage.stats(), AudioJitterBuffer::new(1, 2, 8).stats());
        assert_eq!(stage.pending_frames(), 0);
    }

    #[test]
    fn past_high_water_the_oldest_frame_is_skipped_rather_than_the_newest_refused() {
        let mut stage = AudioJitterBuffer::new(1, 2, 3);
        for seq in 1..=5_u32 {
            stage.push(seq, frame(marker(seq), 2));
        }
        assert_eq!(stage.pending_frames(), 3);
        assert_eq!(stage.stats().overflow_dropped, 2);
        assert_eq!(stage.pull_frames(6), vec![3.0, 3.0, 4.0, 4.0, 5.0, 5.0]);
    }

    #[test]
    fn a_straggling_re_send_of_a_skipped_frame_is_a_late_drop_not_a_re_insert() {
        let mut stage = AudioJitterBuffer::new(1, 2, 3);
        for seq in 1..=5_u32 {
            stage.push(seq, frame(marker(seq), 2));
        }
        stage.push(2, frame(9.0, 2));
        assert_eq!(stage.stats().late_dropped, 1);
        assert_eq!(stage.pending_frames(), 3);
    }

    #[test]
    fn the_sequence_order_survives_the_wrap() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(2, frame(2.0, 2));
        stage.push(u32::MAX, frame(1.0, 2));
        assert_eq!(stage.pull_frames(4), vec![1.0, 1.0, 2.0, 2.0]);
    }

    #[test]
    fn the_drain_hands_off_what_is_staged_without_concealing_anything() {
        let mut stage = primed();
        let mut out = [0.0; 16];
        assert_eq!(stage.drain_available(&mut out), 8);
        assert_eq!(stage.drain_available(&mut out), 0);
        assert_eq!(stage.stats().underruns, 0, "a short drain is not starvation");
        assert_eq!(stage.stats().silence_samples, 0);
    }

    #[test]
    fn a_stage_that_is_not_primed_hands_off_nothing() {
        let mut stage = AudioJitterBuffer::new(1, 2, 8);
        stage.push(1, frame(1.0, 4));
        let mut out = [0.0; 8];
        assert_eq!(stage.drain_available(&mut out), 0);
    }

    #[test]
    fn the_producer_side_starvation_signal_re_primes_the_stage() {
        let mut stage = primed();
        stage.note_consumer_starved();
        assert!(!stage.primed());
        assert_eq!(stage.stats().underruns, 1);
        assert_eq!(
            stage.pending_frames(),
            2,
            "the frames stay and re-count toward the prime"
        );
        stage.note_consumer_starved();
        assert_eq!(stage.stats().underruns, 1, "priming cannot starve");
    }

    #[test]
    fn shedding_latency_is_a_skip_rather_than_an_underrun() {
        let mut stage = primed();
        stage.drop_oldest_pending();
        assert!(stage.primed());
        assert_eq!(stage.stats().overflow_dropped, 1);
        assert_eq!(stage.stats().underruns, 0);
        assert_eq!(stage.pull_frames(2), vec![2.0, 2.0, 2.0, 2.0]);
    }

    #[test]
    fn a_local_disable_drops_the_buffer_but_keeps_the_frontier() {
        let mut stage = primed();
        assert_eq!(stage.pull_frames(2), vec![1.0, 1.0, 1.0, 1.0]);
        stage.clear();
        assert!(!stage.primed());
        assert_eq!(stage.pending_frames(), 0);
        stage.push(1, frame(9.0, 4));
        assert_eq!(
            stage.stats().late_dropped,
            1,
            "the session sequence keeps running"
        );
        stage.push(7, frame(7.0, 4));
        assert_eq!(stage.pending_frames(), 1);
    }

    #[test]
    fn the_combined_depth_bound_sheds_what_the_stage_alone_cannot_see() {
        let mut stage = AudioJitterBuffer::new(1, 4, 8);
        for seq in 1..=6_u32 {
            stage.push(seq, frame(marker(seq), 4));
        }
        // Six staged frames sit under the stage's own eight-frame cap, so it dropped nothing — but
        // the ring holds another two and a half frames' worth, which only the combined bound sees.
        assert_eq!(stage.stats().overflow_dropped, 0);
        assert_eq!(shed_to_depth_bound(&mut stage, 10, 4), 5);
        assert_eq!(stage.pending_frames(), 1);
        assert_eq!(shed_to_depth_bound(&mut stage, 10, 4), 0, "the bound is met");
        assert_eq!(
            stage.pull_frames(4),
            vec![6.0, 6.0, 6.0, 6.0],
            "the newest survived"
        );
    }

    #[test]
    fn the_starvation_signal_reads_the_odometer_rather_than_the_fill_level() {
        assert!(consumer_starved(true, true, 480, 0));
        assert!(
            !consumer_starved(true, true, 480, 480),
            "an exact dry drain played no silence"
        );
        assert!(!consumer_starved(false, true, 480, 0), "priming cannot starve");
        assert!(
            !consumer_starved(true, false, 480, 0),
            "nothing was handed off yet"
        );
    }

    #[test]
    fn the_constructor_floors_every_argument_at_what_the_policy_can_mean() {
        let stage = AudioJitterBuffer::new(0, 0, 0);
        assert_eq!(stage.channels(), 1);
        assert_eq!(stage.target_depth_frames(), 1);
        assert_eq!(stage.high_water_frames(), 1);
        let stage = AudioJitterBuffer::new(2, 4, 2);
        assert_eq!(
            stage.high_water_frames(),
            4,
            "high water can never sit under the target"
        );
    }
}
