//! Wire rate to device rate, because `cpal` does not convert and `AUHAL` did.
//!
//! The Swift this replaces set an `AudioStreamBasicDescription` on the output unit's input scope
//! and let the unit convert to whatever the device was running at. `cpal` has no equivalent: it
//! hands out a stream at a rate the device supports and nothing else. On the common path that
//! costs nothing — every Mac and iOS output this has been pointed at offers 48 kHz, which is the
//! wire rate, and [`Resampler::passthrough`] is then literally a copy. It matters on a device
//! pinned to 44.1 kHz, where the alternative to converting is playing everything a semitone sharp.
//!
//! ## Why linear, and why on the producer side
//! Linear interpolation between two neighbouring frames has an audible cost — it is a gentle
//! low-pass, a fraction of a dB across the top octave at these ratios — and a windowed-sinc would
//! not. It is used anyway because the ratios here are near 1.0 (48000/44100 is 1.088), because the
//! payload is a coding session's audio rather than music, and because the alternative is a
//! filter bank in the one place that must never allocate. Running it on the PRODUCER side is what
//! keeps that promise: the render callback pops samples the device's own rate, and the arithmetic
//! happens on the audio queue where an allocation is free to happen.
//!
//! ## Why this lives here rather than in `slopdesk-video`
//! Every other pure rule on the audio path is `slopdesk-video`'s, because two languages or two
//! processes read it. This one exists only because of `cpal`'s no-conversion contract, has exactly
//! one caller, and would be a cross-crate edge that says nothing. It is unit-tested either way.

// A resampler is arithmetic between two integer counts and a ratio, so it converts between
// `usize`, `f64` and `f32` constantly. Every one of them is bounded by an audio rate or a buffer
// length — both far inside an `f64` mantissa and, after the loop guard, inside a `usize` — so the
// lints have nothing to warn about that a reader has not already been told.
#![expect(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "sample counts and audio rates, each bounded by the guard or the rate that produced it"
)]
// The two float comparisons here are EXACT on purpose, and each says why at its site: the
// passthrough test must not accept a ratio that drifts, and the loop guard is a position against a
// frame count.
#![expect(
    clippy::float_cmp,
    clippy::while_float,
    reason = "an exact ratio test and a position-against-length guard, both documented at their site"
)]
// One integer division: samples over channels, which is a whole number of frames by the caller's
// contract or the remainder is a sheared interleave the caller has already refused.
#![expect(
    clippy::integer_division,
    reason = "interleaved samples over channels is whole frames"
)]

/// Interleaved-frame linear resampler with a carried phase.
///
/// One instance per built device stream; a rate change rebuilds it, because the phase and the
/// carried frame belong to a particular pair of rates.
#[derive(Debug)]
pub(crate) struct Resampler {
    channels: usize,
    /// Input frames consumed per output frame. Exactly 1.0 is the passthrough case.
    step: f64,
    /// Where in the input the next output frame falls, relative to `previous`. Carried across
    /// calls: a chunk boundary is not a discontinuity, and restarting the phase at every 10 ms
    /// frame would put a periodic click at exactly the frame rate.
    phase: f64,
    /// The last input frame of the previous call, which the first output frame of this one
    /// interpolates FROM. Empty until the first call.
    previous: Vec<f32>,
    /// Whether any input has been seen. The first call has no frame to interpolate FROM and starts
    /// one position later instead — see [`Self::convert`].
    started: bool,
}

impl Resampler {
    /// A resampler from `source_rate` to `device_rate` for `channels` interleaved channels.
    ///
    /// A non-finite or non-positive rate on either side is treated as "the same rate", because the
    /// only thing worse than a slightly wrong pitch is dividing by zero on the audio queue.
    pub(crate) fn new(source_rate: f64, device_rate: f64, channels: usize) -> Self {
        let usable =
            source_rate.is_finite() && device_rate.is_finite() && source_rate > 0.0 && device_rate > 0.0;
        Self {
            channels: channels.max(1),
            step: if usable { source_rate / device_rate } else { 1.0 },
            phase: 0.0,
            previous: Vec::new(),
            started: false,
        }
    }

    /// Whether this is a copy rather than a conversion.
    ///
    /// The comparison is exact on purpose: both rates arrive as integers widened to `f64`, so
    /// equal rates divide to exactly 1.0, and a tolerance here would silently accept a ratio that
    /// drifts a sample every few minutes — which is a click every few minutes.
    pub(crate) fn passthrough(&self) -> bool {
        self.step == 1.0
    }

    /// Converts `input` (interleaved, `channels` wide) into `out`, appending.
    ///
    /// Appends rather than replaces because the caller batches several staged frames into one
    /// hand-off; `out` is reused across calls and cleared by the caller when it means to.
    pub(crate) fn convert(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.passthrough() {
            out.extend_from_slice(input);
            return;
        }
        let channels = self.channels;
        let frames = input.len() / channels;
        if frames == 0 {
            return;
        }
        if !self.started {
            // Position 0 is the CARRIED frame, which on the first call does not exist. Start at
            // position 1 — the input's own first frame — rather than seeding a carried frame from
            // it: seeding would emit that sample twice at any ratio below 1.0, which is a click at
            // stream start and a duplicated frame at every rate.
            self.phase = 1.0;
            self.started = true;
        }
        // Position `k` names the carried frame at 0 and input frame `k - 1` after it, so the last
        // position this call can answer is `frames` — beyond that the frame to interpolate TOWARD
        // has not arrived, and it becomes the next call's carried frame instead.
        let last = frames as f64;
        while self.phase <= last {
            let index = self.phase.floor();
            let fraction = (self.phase - index) as f32;
            let base = index as usize;
            for channel in 0..channels {
                let left = if base == 0 {
                    self.previous.get(channel).copied().unwrap_or(0.0)
                } else {
                    input.get((base - 1) * channels + channel).copied().unwrap_or(0.0)
                };
                // Past the last input frame there is nothing to lean toward, which only happens
                // when the fraction is zero — the guard above allows `base == frames` only at an
                // exact position — so the fallback never actually interpolates.
                let right = input.get(base * channels + channel).copied().unwrap_or(left);
                // Two operations, never a fused multiply-add: the repo's float rule is that
                // `a * b + c` stays separable, so the same samples give the same bits on every
                // machine. `mul_add` here would be a one-ULP difference between an arm64 host and
                // anything without an FMA — inaudible, and still a golden vector that disagrees.
                let delta = right - left;
                out.push(left + delta * fraction);
            }
            self.phase += self.step;
        }
        self.phase -= last;
        if let Some(tail) = input.get((frames - 1) * channels..frames * channels) {
            self.previous.clear();
            self.previous.extend_from_slice(tail);
        }
    }

    /// How many output frames `input_frames` of input will produce, near enough to size a buffer.
    ///
    /// Over-estimates by one frame rather than under: the caller uses it as a reserve, and a
    /// re-allocation on the audio queue is what this avoids.
    pub(crate) fn output_frames_hint(&self, input_frames: usize) -> usize {
        if self.passthrough() {
            return input_frames;
        }
        ((input_frames as f64) / self.step).ceil() as usize + 1
    }

    /// How many INPUT samples a count of device samples came from, near enough to compare against
    /// a budget expressed at the source rate.
    ///
    /// The depth bound compares the hand-off's fill against the stage's own budget. The hand-off
    /// holds DEVICE samples and the budget is in wire samples, so on any device not running at the
    /// wire rate the comparison needs one side converted or it sheds at the wrong point — early on
    /// a 44.1 kHz device, late on a 96 kHz one.
    pub(crate) fn input_samples_hint(&self, device_samples: usize) -> usize {
        if self.passthrough() {
            return device_samples;
        }
        ((device_samples as f64) * self.step).round() as usize
    }

    /// Drops the carried phase and frame — a flush, or a re-prime after silence.
    pub(crate) fn reset(&mut self) {
        self.phase = 0.0;
        self.previous.clear();
        self.started = false;
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a test that indexes past its own fixture should fail loudly"
    )]

    use super::Resampler;

    #[test]
    fn equal_rates_are_a_copy_not_a_conversion() {
        let mut resampler = Resampler::new(48_000.0, 48_000.0, 2);
        assert!(resampler.passthrough());
        let mut out = Vec::new();
        resampler.convert(&[0.1, 0.2, 0.3, 0.4], &mut out);
        assert_eq!(out, vec![0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn a_nonsense_rate_falls_back_to_a_copy_rather_than_dividing_by_zero() {
        assert!(Resampler::new(48_000.0, 0.0, 2).passthrough());
        assert!(Resampler::new(f64::NAN, 48_000.0, 2).passthrough());
    }

    #[test]
    fn halving_the_rate_drops_every_other_frame() {
        // 48k → 24k is a step of 2.0, which lands every output frame exactly ON an input frame,
        // so no interpolation happens and the answer is exact.
        let mut resampler = Resampler::new(48_000.0, 24_000.0, 1);
        let mut out = Vec::new();
        resampler.convert(&[0.0, 1.0, 2.0, 3.0], &mut out);
        assert_eq!(out, vec![0.0, 2.0]);
    }

    #[test]
    fn doubling_the_rate_interpolates_the_midpoints() {
        let mut resampler = Resampler::new(24_000.0, 48_000.0, 1);
        let mut out = Vec::new();
        resampler.convert(&[0.0, 2.0], &mut out);
        // The first output frame is the input's own first sample (no ramp from silence), then the
        // midpoint, then the second sample.
        assert_eq!(out, vec![0.0, 1.0, 2.0]);
    }

    #[test]
    fn the_phase_carries_across_calls_rather_than_restarting() {
        // A restart at every chunk boundary puts a click at exactly the chunk rate, which at a
        // 10 ms wire cadence is a 100 Hz buzz. Two halves must equal one whole.
        let whole: Vec<f32> = (0..8).map(|n| n as f32).collect();
        let mut one_shot = Resampler::new(48_000.0, 44_100.0, 1);
        let mut expected = Vec::new();
        one_shot.convert(&whole, &mut expected);

        let mut split = Resampler::new(48_000.0, 44_100.0, 1);
        let mut actual = Vec::new();
        split.convert(&whole[..4], &mut actual);
        split.convert(&whole[4..], &mut actual);
        assert_eq!(actual, expected);
    }

    #[test]
    fn stereo_channels_stay_in_their_lanes() {
        let mut resampler = Resampler::new(24_000.0, 48_000.0, 2);
        let mut out = Vec::new();
        // Left ramps up, right ramps down — a swapped interleave would show as a crossed pair.
        resampler.convert(&[0.0, 10.0, 2.0, 8.0], &mut out);
        assert_eq!(out, vec![0.0, 10.0, 1.0, 9.0, 2.0, 8.0]);
    }

    #[test]
    fn the_hint_is_never_short() {
        let resampler = Resampler::new(44_100.0, 48_000.0, 2);
        let mut counting = Resampler::new(44_100.0, 48_000.0, 2);
        let mut out = Vec::new();
        counting.convert(&vec![0.5; 441 * 2], &mut out);
        assert!(resampler.output_frames_hint(441) >= out.len() / 2);
    }
}
