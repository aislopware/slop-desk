//! Producer side: the jitter stage, the depth bound, the rate conversion, the hand-off.
//!
//! Every DECISION here is `slopdesk_video::audio_jitter`'s — prime, conceal, reorder, high water,
//! the combined stage-plus-ring bound, and whether the render side actually starved. This module
//! is the glue that asks them in the right order and moves the samples, and it deliberately
//! contains no policy of its own.
//!
//! ## Why the ring is topped up to TARGET depth and not to its capacity
//! A sample committed to the hand-off belongs to the consumer and can never be taken back. The
//! render side only needs the target depth of headroom between pushes, so everything beyond that
//! stays STAGED — which is the only place the combined depth bound can still shed it when a
//! backlog builds. Filling the ring to the brim instead would convert a sheddable backlog into
//! permanent latency, and stale audio is worse than a click.

use slopdesk_video::audio_jitter::{
    AudioJitterBuffer, consumer_starved, ring_target_samples, shed_to_depth_bound,
};

use crate::handoff::Handoff;
use crate::resample::Resampler;

/// The stage, the bound and the hand-off, in the order they run.
#[derive(Debug)]
pub(crate) struct Pump {
    stage: AudioJitterBuffer,
    handoff: Handoff,
    resampler: Resampler,
    /// Nominal interleaved samples per ten-millisecond wire frame, at the WIRE rate — the unit the
    /// stage's frame-count policy converts through.
    samples_per_frame: usize,
    /// Whether anything has been handed off since the stage last primed. Gates the starvation
    /// check, so priming silence is never miscounted as an underrun.
    emitted_since_prime: bool,
    /// The shortfall odometer at the last check. An advance since then means the render side
    /// genuinely zero-filled in between.
    last_shortfall: u64,
    /// Scratch the resampler appends into, reused across pushes so the audio queue does not
    /// allocate per frame.
    converted: Vec<f32>,
    /// Scratch the stage drains into, same reason.
    drained: Vec<f32>,
}

impl Pump {
    /// A pump over `stage`, feeding `handoff`, converting from the wire rate to `device_rate`.
    pub(crate) fn new(
        stage: AudioJitterBuffer,
        handoff: Handoff,
        samples_per_frame: usize,
        wire_rate: f64,
        device_rate: f64,
    ) -> Self {
        let channels = stage.channels();
        let samples_per_frame = samples_per_frame.max(1);
        Self {
            stage,
            handoff,
            resampler: Resampler::new(wire_rate, device_rate, channels),
            samples_per_frame,
            emitted_since_prime: false,
            last_shortfall: 0,
            converted: Vec::with_capacity(samples_per_frame * 4),
            drained: Vec::with_capacity(samples_per_frame * 4),
        }
    }

    /// One decoded frame: starvation check, stage policy, combined depth bound, hand-off.
    ///
    /// Starvation is detected HERE rather than on the render thread, which must not touch stage
    /// state. The cost is that the detection lags by one push cycle, which is one wire frame.
    pub(crate) fn enqueue(&mut self, seq: u32, samples: Vec<f32>) {
        let shortfall_now = self.handoff.shortfall();
        if consumer_starved(
            self.stage.primed(),
            self.emitted_since_prime,
            shortfall_now,
            self.last_shortfall,
        ) {
            self.stage.note_consumer_starved();
            self.emitted_since_prime = false;
            // The carried interpolation phase is meaningless across a silence gap — the frame it
            // would interpolate FROM is whatever played before the underrun.
            self.resampler.reset();
        }
        self.last_shortfall = shortfall_now;
        self.stage.push(seq, samples);
        // Read the fill BEFORE the mutable borrow: the bound compares two numbers, and taking them
        // in the other order would ask the borrow checker to hold both halves of `self` at once.
        let ring_fill = self.ring_fill_in_wire_samples();
        let _shed = shed_to_depth_bound(&mut self.stage, ring_fill, self.samples_per_frame);
        self.emit();
    }

    /// Local disable: drop the stage AND ask the consumer to skip what it holds.
    ///
    /// The stage keeps its sequence frontier, which is session-scoped: a re-enable must not replay
    /// datagrams still in flight from before the disable.
    pub(crate) fn flush(&mut self) {
        self.stage.clear();
        self.emitted_since_prime = false;
        self.resampler.reset();
        self.handoff.request_flush();
    }

    /// The hand-off's fill, expressed in WIRE samples so the stage's own budget can be compared
    /// against it.
    ///
    /// Without this the two would be in different units on any device not running at the wire
    /// rate, and the depth bound would shed at the wrong point — early on a 44.1 kHz device, late
    /// on a 96 kHz one.
    fn ring_fill_in_wire_samples(&self) -> usize {
        let device_samples = self.handoff.fill();
        self.resampler.input_samples_hint(device_samples)
    }

    /// Tops the hand-off up to the target-depth budget from the stage, and no further.
    fn emit(&mut self) {
        while self.stage.primed() && self.stage.available_samples() > 0 {
            let budget = ring_target_samples(self.stage.target_depth_frames(), self.samples_per_frame);
            let headroom = budget.saturating_sub(self.ring_fill_in_wire_samples());
            if headroom == 0 {
                return;
            }
            let want = headroom.min(self.stage.available_samples());
            self.drained.clear();
            self.drained.resize(want, 0.0);
            let written = self.stage.drain_available(&mut self.drained);
            if written == 0 {
                return;
            }
            self.drained.truncate(written);
            self.converted.clear();
            #[expect(
                clippy::integer_division,
                reason = "interleaved samples over channels is a whole number of frames — the stage only \
                          ever drains whole ones"
            )]
            let frames = written / self.stage.channels().max(1);
            self.converted.reserve(self.resampler.output_frames_hint(frames));
            self.resampler.convert(&self.drained, &mut self.converted);
            if self.handoff.commit(&self.converted) == 0 {
                return;
            }
            self.emitted_since_prime = true;
        }
    }

    /// The stage's cumulative counters, for the diagnostics door.
    pub(crate) const fn stats(&self) -> slopdesk_video::audio_jitter::AudioJitterStats {
        self.stage.stats()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "at the wire rate the pump moves samples without touching them, so the assertions name \
                  exact bits"
    )]

    use slopdesk_video::audio_jitter::AudioJitterBuffer;

    use super::Pump;
    use crate::handoff::pair;

    /// A pump at the wire rate, so the resampler is a copy and the assertions read as samples.
    fn pump(capacity: usize) -> (Pump, crate::handoff::Render) {
        let (handoff, render) = pair(capacity);
        let stage = AudioJitterBuffer::new(2, 2, 8);
        (Pump::new(stage, handoff, 4, 48_000.0, 48_000.0), render)
    }

    #[test]
    fn nothing_plays_until_the_stage_primes() {
        let (mut pump, mut render) = pump(64);
        // Target depth is two frames; one is not enough to start.
        pump.enqueue(1, vec![1.0; 4]);
        let mut out = [-1.0_f32; 4];
        render.fill(&mut out);
        assert_eq!(out, [0.0; 4], "priming silence, not the first frame");
        pump.enqueue(2, vec![2.0; 4]);
        render.fill(&mut out);
        assert_eq!(out, [1.0; 4], "primed, and the FIRST frame is the one that plays");
    }

    #[test]
    fn a_swapped_pair_of_datagrams_still_plays_in_order() {
        let (mut pump, mut render) = pump(64);
        pump.enqueue(2, vec![2.0; 4]);
        pump.enqueue(1, vec![1.0; 4]);
        let mut out = [0.0_f32; 8];
        render.fill(&mut out);
        assert_eq!(out, [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0]);
    }

    #[test]
    fn a_flush_falls_silent_without_waiting_for_the_ring_to_drain() {
        let (mut pump, mut render) = pump(64);
        pump.enqueue(1, vec![1.0; 4]);
        pump.enqueue(2, vec![2.0; 4]);
        pump.flush();
        let mut out = [-1.0_f32; 8];
        render.fill(&mut out);
        assert_eq!(out, [0.0; 8]);
    }

    #[test]
    fn the_handoff_is_topped_up_to_target_depth_and_no_further() {
        // Eight frames staged against a target depth of two: only the target's worth may cross,
        // because everything past it must stay where the depth bound can still shed it.
        let (mut pump, _render) = pump(1024);
        for seq in 1..=8 {
            #[expect(
                clippy::cast_precision_loss,
                reason = "a loop counter under ten, written as a sample so the assertions can name it"
            )]
            let value = seq as f32;
            pump.enqueue(seq, vec![value; 4]);
        }
        // Two frames of four samples each.
        assert_eq!(pump.handoff.fill(), 8);
    }

    #[test]
    fn a_device_at_another_rate_measures_the_bound_in_wire_samples() {
        // Half the wire rate: the hand-off holds half as many samples for the same audio, and the
        // depth bound has to compare like with like or it sheds at the wrong point.
        let (handoff, _render) = pair(1024);
        let stage = AudioJitterBuffer::new(2, 2, 8);
        let mut pump = Pump::new(stage, handoff, 4, 48_000.0, 24_000.0);
        for seq in 1..=8 {
            #[expect(
                clippy::cast_precision_loss,
                reason = "a loop counter under ten, written as a sample so the assertions can name it"
            )]
            let value = seq as f32;
            pump.enqueue(seq, vec![value; 4]);
        }
        // Four device samples IS the two-frame, eight-wire-sample budget.
        assert_eq!(pump.handoff.fill(), 4);
    }
}
