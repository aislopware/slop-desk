//! The capture side of the audio path, decided without `AudioToolbox` in the room.
//!
//! Three things the host's encoder used to spell inline: how a captured buffer's channels become
//! the fixed stereo wire layout, how a stream of arbitrarily-sized captured buffers becomes a
//! stream of fixed 480-frame blocks, and how a float block becomes the codec-free `s16le` payload.
//! None of them needs a framework. All of them were unreachable from a test where they sat: the
//! file they lived in built an `AudioConverter` on first use, which the repo's hang-safety rule
//! forbids a unit test from doing, so the whole file was exercised only by the loopback harness.
//!
//! `slopdesk-apple-audio` — which does need `AudioToolbox` — reads these rather than deciding
//! anything. The `s16le` DECODE half is [`crate::audio_wire`]'s, next to the wire grammar it
//! belongs to; this module is its mirror and deliberately does not repeat it.
//!
//! ## Why the wire cadence is a constant and not a parameter
//! 480 frames at 48 kHz is 10 ms, and it is the same number twice over: the AAC-ELD 480-frame
//! variant emits exactly one access unit per block, and the `s16le` arm chunks to the same size so
//! both arms put one 10 ms frame on the wire per datagram. Letting either drift would make the
//! client's jitter ring pace two different cadences depending on a codec it does not otherwise
//! care about.

use crate::audio_wire::PCM_S16_FULL_SCALE;

/// The wire sample rate, in Hz. The capture tap is configured to exactly this.
pub const SAMPLE_RATE: u32 = 48_000;

/// The wire channel count — interleaved stereo, whatever the source had.
pub const CHANNEL_COUNT: usize = 2;

/// Sample frames per wire frame per channel: 480 at 48 kHz is 10 ms.
pub const FRAMES_PER_BLOCK: usize = 480;

/// Interleaved samples in one complete wire frame.
pub const SAMPLES_PER_BLOCK: usize = FRAMES_PER_BLOCK * CHANNEL_COUNT;

/// The widest source layout worth believing.
///
/// The tap is configured stereo, so anything past a sane surround layout is a corrupt format
/// description rather than an unusual one. It bounds an allocation sized from that description,
/// which is the only reason it is checked at all.
pub const MAX_SOURCE_CHANNELS: usize = 16;

/// Whether a captured buffer's format description describes something this module will read.
///
/// A buffer that fails this is DROPPED rather than reinterpreted: the tap is trusted, but a
/// surprise layout must never be read as samples, and there is no partial answer worth having —
/// one bad 10 ms frame is inaudible where a misread one is a burst of noise.
#[must_use]
pub const fn source_layout_is_readable(channels: usize) -> bool {
    channels >= 1 && channels <= MAX_SOURCE_CHANNELS
}

/// Folds an INTERLEAVED source buffer into the fixed stereo wire layout.
///
/// Mono duplicates into both wire channels — a coding session's audio is usually mono, and
/// silencing one side of the listener's headphones would be a worse answer than either channel.
/// Channels past the second are dropped, which is defensive only: the tap asks for stereo.
///
/// `None` when `src` does not hold `frames × channels` samples. That is a length that disagrees
/// with the format description it arrived with, and reading it would shear the interleave.
#[must_use]
pub fn fold_interleaved_to_stereo(src: &[f32], frames: usize, channels: usize) -> Option<Vec<f32>> {
    if !source_layout_is_readable(channels) || src.len() < frames.checked_mul(channels)? {
        return None;
    }
    let mut out = vec![0.0_f32; frames.checked_mul(CHANNEL_COUNT)?];
    for (frame, pair) in out.as_chunks_mut::<CHANNEL_COUNT>().0.iter_mut().enumerate() {
        let base = frame * channels;
        let left = *src.get(base)?;
        let right = if channels > 1 { *src.get(base + 1)? } else { left };
        *pair = [left, right];
    }
    Some(out)
}

/// Folds a PLANAR source buffer into the fixed stereo wire layout.
///
/// `right` is `None` for a mono source, which duplicates `left` the way the interleaved arm does.
/// `None` when either plane is shorter than `frames`.
#[must_use]
pub fn fold_planar_to_stereo(left: &[f32], right: Option<&[f32]>, frames: usize) -> Option<Vec<f32>> {
    if left.len() < frames || right.is_some_and(|plane| plane.len() < frames) {
        return None;
    }
    let mut out = vec![0.0_f32; frames.checked_mul(CHANNEL_COUNT)?];
    for (frame, pair) in out.as_chunks_mut::<CHANNEL_COUNT>().0.iter_mut().enumerate() {
        let sample = *left.get(frame)?;
        // A mono source duplicates; a stereo one takes its own plane. The `?` cannot fire — both
        // lengths were checked against `frames` above — but asking is free and states the bound.
        let other = match right {
            Some(plane) => *plane.get(frame)?,
            None => sample,
        };
        *pair = [sample, other];
    }
    Some(out)
}

/// Interleaved float samples to the interleaved `s16le` the codec-free arm puts on the wire.
///
/// Saturating, because an inter-sample overshoot is a real thing a mix produces and wrapping it
/// would turn a loud passage into a click. Little-endian per the payload's contract, which is the
/// one place this wire disagrees with its own big-endian headers.
#[must_use]
pub fn pack_s16le(samples: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        // The full-scale POSITIVE value is one less than the negative one, so the clamp is
        // asymmetric in the codomain and symmetric here — the alternative rounds +1.0 to a value
        // that wraps to full-scale negative, which is the loudest possible click.
        let clamped = f64::from(*sample).clamp(-1.0, 1.0);
        let scaled = clamped * f64::from(PCM_S16_FULL_SCALE - 1.0);
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the clamp above bounds this to ±32767, which every i16 holds"
        )]
        let value = scaled.round() as i16;
        out.extend_from_slice(&value.to_le_bytes());
    }
    out
}

/// The sub-block remainder between captured buffers.
///
/// The tap's delivery sizes are not multiples of 480, so almost every captured buffer completes
/// some whole wire frames and leaves a tail. This holds the tail; nothing else.
///
/// It is a type rather than a `Vec` in the caller because of what [`Self::reset`] means: on the
/// enable transition the tail is however old the disable window was, and splicing minutes-stale
/// samples into the first fresh frame plays a ten-millisecond shard of the past. Naming that
/// operation is the point.
#[derive(Debug, Default)]
pub struct BlockAccumulator {
    pending: Vec<f32>,
    /// How far into `pending` the blocks handed out so far reach. Compacting on every block would
    /// memmove the tail once per 10 ms for no reason; compacting on push moves it once per
    /// captured buffer instead.
    taken: usize,
}

impl BlockAccumulator {
    /// An accumulator holding nothing, with room for a captured buffer and a block's tail.
    #[must_use]
    pub fn new() -> Self {
        Self {
            pending: Vec::with_capacity(SAMPLES_PER_BLOCK * 4),
            taken: 0,
        }
    }

    /// Appends interleaved stereo samples, dropping whatever previous blocks already consumed.
    pub fn push(&mut self, samples: &[f32]) {
        if self.taken > 0 {
            self.pending.drain(..self.taken);
            self.taken = 0;
        }
        self.pending.extend_from_slice(samples);
    }

    /// The next complete wire frame, or `None` when the tail is short of one.
    ///
    /// Borrows out of the accumulator rather than answering a `Vec`: the encoder hands this
    /// straight to the codec, so a copy here would be one allocation per 10 ms that nothing reads.
    pub fn next_block(&mut self) -> Option<&[f32]> {
        let end = self.taken.checked_add(SAMPLES_PER_BLOCK)?;
        if end > self.pending.len() {
            return None;
        }
        let block = self.pending.get(self.taken..end)?;
        self.taken = end;
        Some(block)
    }

    /// Samples held that do not yet make a block.
    #[must_use]
    pub const fn pending_samples(&self) -> usize {
        self.pending.len().saturating_sub(self.taken)
    }

    /// Drops the remainder. The enable transition calls this; see the type note.
    pub fn reset(&mut self) {
        self.pending.clear();
        self.taken = 0;
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::float_cmp,
        reason = "a panic in a test is the failure report, and a sample-format convert is pinned by EXACT \
                  bit patterns, which is what makes it a test at all"
    )]

    use super::{
        BlockAccumulator, CHANNEL_COUNT, SAMPLES_PER_BLOCK, fold_interleaved_to_stereo,
        fold_planar_to_stereo, pack_s16le, source_layout_is_readable,
    };

    #[test]
    fn a_mono_source_reaches_both_ears() {
        let folded = fold_interleaved_to_stereo(&[0.25, -0.5], 2, 1).expect("mono folds");
        assert_eq!(folded, vec![0.25, 0.25, -0.5, -0.5]);
        let planar = fold_planar_to_stereo(&[0.25, -0.5], None, 2).expect("mono folds");
        assert_eq!(planar, folded);
    }

    #[test]
    fn channels_past_the_second_are_dropped_not_mixed() {
        // Two frames of 5.1: only the first two channels of each reach the wire.
        let src: Vec<f32> = (0_i16..12).map(f32::from).collect();
        let folded = fold_interleaved_to_stereo(&src, 2, 6).expect("surround folds");
        assert_eq!(folded, vec![0.0, 1.0, 6.0, 7.0]);
    }

    #[test]
    fn a_length_that_disagrees_with_the_layout_is_dropped_whole() {
        // Five samples cannot be three stereo frames; a partial read would shear the interleave.
        assert!(fold_interleaved_to_stereo(&[0.0; 5], 3, 2).is_none());
        assert!(fold_planar_to_stereo(&[0.0; 3], Some(&[0.0; 2]), 3).is_none());
        assert!(!source_layout_is_readable(0));
        assert!(!source_layout_is_readable(17));
    }

    #[test]
    fn an_oversized_sample_clamps_rather_than_wrapping() {
        // +1.5 wrapping would land at full-scale NEGATIVE — the loudest possible click.
        let packed = pack_s16le(&[1.5, -1.5, 0.0]);
        assert_eq!(packed, vec![0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00]);
    }

    #[test]
    fn full_scale_round_trips_through_the_wire_decoder() {
        let packed = pack_s16le(&[1.0, -1.0]);
        let mut room = [0.0_f32; 2];
        let written = crate::audio_wire::decode_pcm_s16le_into(&packed, CHANNEL_COUNT, &mut room)
            .expect("two whole stereo samples decode");
        assert_eq!(written, 2);
        // 32767/32768 back at BOTH ends, not ±1.0. The pack scales by 32767 so it never emits the
        // one asymmetric code (-32768) the format has, and the decode divides by 32768 — so full
        // scale round-trips one step short in each direction. That step is 0.00003: inaudible, and
        // the alternative is the wrapping click the clamp test above pins.
        assert!((room[0] - 0.999_97).abs() < 1e-4);
        assert!((room[1] + 0.999_97).abs() < 1e-4);
    }

    #[test]
    fn a_captured_buffer_completes_whole_blocks_and_keeps_the_tail() {
        let mut blocks = BlockAccumulator::new();
        blocks.push(&vec![0.5; SAMPLES_PER_BLOCK + 7]);
        assert_eq!(
            blocks.next_block().expect("one whole block").len(),
            SAMPLES_PER_BLOCK
        );
        assert!(blocks.next_block().is_none());
        assert_eq!(blocks.pending_samples(), 7);
        // The tail joins the next buffer rather than being dropped or padded.
        blocks.push(&vec![0.25; SAMPLES_PER_BLOCK]);
        let second = blocks.next_block().expect("the tail plus the next buffer");
        assert_eq!(second.len(), SAMPLES_PER_BLOCK);
        assert_eq!(second[0], 0.5);
        assert_eq!(second[7], 0.25);
        assert_eq!(blocks.pending_samples(), 7);
    }

    #[test]
    fn the_enable_transition_drops_a_stale_tail() {
        let mut blocks = BlockAccumulator::new();
        blocks.push(&[0.5; 7]);
        blocks.reset();
        assert_eq!(blocks.pending_samples(), 0);
        // A fresh buffer starts a block at its own first sample, with no shard of the past spliced in.
        blocks.push(&vec![0.25; SAMPLES_PER_BLOCK]);
        assert_eq!(blocks.next_block().expect("a clean block")[0], 0.25);
    }
}
