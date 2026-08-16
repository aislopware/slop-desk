//! Resampling a bursty, low-rate remote scroll stream into a steady high-rate one.
//!
//! ## Why this exists
//!
//! Chromium renders SYNTHETIC (injected) smooth-scroll at a rate that climbs with the INJECTION
//! rate, only saturating at 60 fps around 250 Hz — four times vsync. Inject at 60 Hz and it renders
//! 20 fps; at 125 Hz, 35 fps. Below about three times vsync the events alias with the compositor
//! and most 16.7 ms frames land no events at all. The remote scroll path injects at the client's
//! trackpad rate, 60 to 120 Hz, made burstier still by network jitter — so an editor scrolls at a
//! juddery 20 to 35 fps even though capture and encode are already running at 60.
//!
//! ## What it does — pure, deterministic, total-preserving
//!
//! [`ScrollResampler::ingest`] folds each arriving wire event; [`ScrollResampler::drain`] is called
//! on a fixed OUTPUT cadence — the caller's ~250 Hz timer — and returns the next integer-pixel
//! sub-event to post.
//!
//! * **Markers pass through 1:1.** Began, Ended, Cancelled, momentum-Began and momentum-End carry
//!   the gesture lifecycle and the rubber-band semantics, so `ingest` returns them immediately and
//!   the exact phase fidelity of the direct path is preserved.
//! * **The continuous stream accumulates.** Changed and momentum-Continue fold into a per-axis
//!   residual, and each `drain` emits a portion of it — lag-capped so a fast flick drains in a few
//!   ticks instead of lagging, with the sub-pixel fraction CARRIED so the summed output equals the
//!   summed input to under a pixel per axis per gesture.
//!
//! No wall clock, no environment, no I/O.

/// The `CGScrollPhase` code for a continuous finger-driven sample.
const SCROLL_CHANGED: u8 = 2;
/// The `CGScrollPhase` code for the end of a gesture.
const SCROLL_ENDED: u8 = 4;
/// The `CGScrollPhase` code for a cancelled gesture.
const SCROLL_CANCELLED: u8 = 8;
/// The `CGMomentumScrollPhase` code that opens an inertial coast.
const MOMENTUM_BEGAN: u8 = 1;
/// The `CGMomentumScrollPhase` code for a continuing coast.
const MOMENTUM_CONTINUE: u8 = 2;
/// The `CGMomentumScrollPhase` code that ends a coast.
const MOMENTUM_END: u8 = 3;

/// One integer-pixel scroll sub-event to post, carrying the `CoreGraphics` phase codes verbatim.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SubEvent {
    /// The horizontal pixel delta — whole pixels; the resampler keeps the fraction.
    pub dx: f64,
    /// The vertical pixel delta.
    pub dy: f64,
    /// The `CGScrollPhase` code: 1 Began, 2 Changed, 4 Ended, 8 Cancelled, 0 none or momentum.
    pub scroll_phase: u8,
    /// The `CGMomentumScrollPhase` code: 1 Began, 2 Continue, 3 End, 0 none.
    pub momentum_phase: u8,
    /// The precise/continuous trackpad flag, forwarded from the wire.
    pub continuous: bool,
}

/// The resampler. One per pane, confined to the caller's serial queue — `ingest` and `drain` are
/// both `&mut self`, so the confinement is the type system's problem rather than a convention.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScrollResampler {
    /// The fraction divisor: each drain emits about `residual / spread`.
    spread: f64,
    /// The per-axis lag cap, in pixels.
    lag_cap: f64,
    /// The un-emitted horizontal residual, carrying the sub-pixel fraction between ticks.
    residual_x: f64,
    /// The un-emitted vertical residual.
    residual_y: f64,
    /// Whether the latest continuous samples are an inertial coast rather than finger-driven, so a
    /// resampled continuation carries momentum-Continue instead of scroll-Changed.
    coasting: bool,
    /// The precise/continuous flag of the latest sample, stamped on resampled continuations.
    continuous_flag: bool,
}

impl Default for ScrollResampler {
    fn default() -> Self {
        Self::new(Self::DEFAULT_SPREAD, Self::DEFAULT_LAG_CAP)
    }
}

impl ScrollResampler {
    /// The default fraction divisor: about half the residual per tick, roughly a one-tick lag at
    /// the output rate. Larger is smoother but laggier; smaller is snappier but coarser.
    pub const DEFAULT_SPREAD: f64 = 2.0;
    /// The default per-axis lag cap in pixels — about one frame's travel.
    pub const DEFAULT_LAG_CAP: f64 = 48.0;

    /// The most sub-events one [`Self::ingest`] can answer with.
    ///
    /// A continuous sample answers with none. A marker answers with itself, and an ENDING marker
    /// answers with at most one flush in front of it — the residual is drained whole, in one event.
    /// There is no third branch, which is what lets the answer cross as a fixed pair.
    pub const MAX_INGEST_EVENTS: usize = 2;

    /// The resampler a caller that stores this state rather than owning it describes.
    ///
    /// The knobs are NOT re-sanitised: they were sanitised when the state was first built, and
    /// clamping an already-clamped value would only invite the two ends to disagree about which
    /// pass did it.
    #[must_use]
    pub const fn restored(
        spread: f64,
        lag_cap: f64,
        residual_x: f64,
        residual_y: f64,
        coasting: bool,
        continuous_flag: bool,
    ) -> Self {
        Self {
            spread,
            lag_cap,
            residual_x,
            residual_y,
            coasting,
            continuous_flag,
        }
    }

    /// The fraction divisor, as sanitised at construction.
    #[must_use]
    pub const fn spread(&self) -> f64 {
        self.spread
    }

    /// The per-axis lag cap in pixels, as sanitised at construction.
    #[must_use]
    pub const fn lag_cap(&self) -> f64 {
        self.lag_cap
    }

    /// The un-emitted residual on each axis, sub-pixel fraction and all.
    #[must_use]
    pub const fn residual(&self) -> (f64, f64) {
        (self.residual_x, self.residual_y)
    }

    /// Whether the latest continuous samples are an inertial coast.
    #[must_use]
    pub const fn coasting(&self) -> bool {
        self.coasting
    }

    /// The precise/continuous flag stamped on resampled continuations.
    #[must_use]
    pub const fn continuous_flag(&self) -> bool {
        self.continuous_flag
    }

    /// A resampler with the given drain curve. Both knobs are sanitised into a sane band, so a
    /// hostile value can neither stall the drain nor make it over-emit.
    #[must_use]
    pub fn new(spread: f64, lag_cap: f64) -> Self {
        Self {
            spread: if spread.is_finite() && spread >= 1.0 {
                spread.min(16.0)
            } else {
                Self::DEFAULT_SPREAD
            },
            lag_cap: if lag_cap.is_finite() && lag_cap >= 1.0 {
                lag_cap.min(4096.0)
            } else {
                Self::DEFAULT_LAG_CAP
            },
            residual_x: 0.0,
            residual_y: 0.0,
            coasting: false,
            continuous_flag: false,
        }
    }

    /// Whether there is no whole pixel left to drain, so the caller can suspend its timer.
    #[must_use]
    pub fn is_idle(&self) -> bool {
        self.residual_x.abs() < 1.0 && self.residual_y.abs() < 1.0
    }

    /// Folds one arriving wire event, returning any MARKER sub-events to post immediately.
    ///
    /// The continuous portion is accumulated instead, and surfaces later through [`Self::drain`]. A
    /// non-finite delta is treated as zero, so a bad sample cannot poison the residual.
    pub fn ingest(
        &mut self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
    ) -> Vec<SubEvent> {
        let dx = if dx.is_finite() { dx } else { 0.0 };
        let dy = if dy.is_finite() { dy } else { 0.0 };
        self.continuous_flag = continuous;

        // The high-volume CONTINUOUS portion is what gets resampled: accumulate it, and let `drain`
        // meter it out at the output rate.
        if scroll_phase == SCROLL_CHANGED {
            self.residual_x += dx;
            self.residual_y += dy;
            self.coasting = false;
            return Vec::new();
        }
        if momentum_phase == MOMENTUM_CONTINUE {
            self.residual_x += dx;
            self.residual_y += dy;
            self.coasting = true;
            return Vec::new();
        }

        // A MARKER. If it ENDS the gesture, FLUSH the pending residual first — as a continuation
        // under its current, pre-flip phase — so that no later timer tick can drain leftover pixels
        // AFTER the End marker. That would be a Changed-after-Ended, phase 2 after phase 4, and it
        // corrupts rubber-banding in AppKit and Chromium alike. Other markers just pass through.
        let mut out = Vec::new();
        let ends_gesture = scroll_phase == SCROLL_ENDED
            || scroll_phase == SCROLL_CANCELLED
            || momentum_phase == MOMENTUM_END;
        if ends_gesture && let Some(flush) = self.flush_residual() {
            out.push(flush);
        }
        if momentum_phase == MOMENTUM_BEGAN {
            self.coasting = true;
        }
        if ends_gesture {
            self.coasting = false;
        }
        out.push(SubEvent {
            dx,
            dy,
            scroll_phase,
            momentum_phase,
            continuous,
        });
        out
    }

    /// Emits the whole pending residual as one final continuation sub-event and zeroes it.
    ///
    /// Whole pixels only — the sub-pixel remainder is dropped rather than carried, because there is
    /// no later tick to carry it into. `None` when there is under a pixel per axis to flush.
    fn flush_residual(&mut self) -> Option<SubEvent> {
        let dx = self.residual_x.trunc();
        let dy = self.residual_y.trunc();
        self.residual_x = 0.0;
        self.residual_y = 0.0;
        if dx == 0.0 && dy == 0.0 {
            return None;
        }
        Some(self.continuation(dx, dy))
    }

    /// The next resampled continuation sub-event, or `None` once the residual is drained.
    ///
    /// Call this on the fixed output cadence. The phase reflects whether the latest continuous
    /// samples were finger-driven or an inertial coast.
    pub fn drain(&mut self) -> Option<SubEvent> {
        let dx = drain_axis(&mut self.residual_x, self.spread, self.lag_cap);
        let dy = drain_axis(&mut self.residual_y, self.spread, self.lag_cap);
        if dx == 0.0 && dy == 0.0 {
            return None;
        }
        Some(self.continuation(dx, dy))
    }

    /// A continuation sub-event under the phase the latest continuous samples established.
    const fn continuation(&self, dx: f64, dy: f64) -> SubEvent {
        SubEvent {
            dx,
            dy,
            scroll_phase: if self.coasting { 0 } else { SCROLL_CHANGED },
            momentum_phase: if self.coasting { MOMENTUM_CONTINUE } else { 0 },
            continuous: self.continuous_flag,
        }
    }

    /// Drops the residual and the phase state — for a pane losing focus or a session tearing down,
    /// so a stale half-pixel cannot resume on the next gesture.
    pub const fn reset(&mut self) {
        self.residual_x = 0.0;
        self.residual_y = 0.0;
        self.coasting = false;
        self.continuous_flag = false;
    }
}

/// Drains one axis by one output tick, in whole pixels, mutating the residual.
///
/// Emits `residual / spread` — at least one pixel so it always makes progress, at most the whole
/// residual so it never overshoots — but at least `residual - lag_cap`, so a fast flick comes back
/// down to the cap this tick rather than crawling. A sub-pixel residual is held and CARRIED, which
/// is what makes the integer outputs sum to the float input.
fn drain_axis(residual: &mut f64, spread: f64, lag_cap: f64) -> f64 {
    let magnitude = residual.abs();
    if magnitude < 1.0 {
        return 0.0; // sub-pixel: hold and carry, never emit a fractional pixel
    }
    let by_fraction = magnitude / spread;
    let by_lag_cap = magnitude - lag_cap;
    // The FASTER of the two drains, floored at a pixel of progress and capped at the residual.
    let emit_magnitude = magnitude.min(by_fraction.max(by_lag_cap).max(1.0));
    let emit = if *residual > 0.0 {
        emit_magnitude
    } else {
        -emit_magnitude
    }
    .trunc();
    *residual -= emit;
    emit
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        MOMENTUM_BEGAN, MOMENTUM_CONTINUE, MOMENTUM_END, SCROLL_CANCELLED, SCROLL_CHANGED, SCROLL_ENDED,
        ScrollResampler, SubEvent,
    };

    /// A finger-driven continuous sample.
    fn changed(dx: f64, dy: f64) -> (f64, f64, u8, u8, bool) {
        (dx, dy, SCROLL_CHANGED, 0, true)
    }

    /// Feeds one tuple through `ingest`.
    fn ingest(resampler: &mut ScrollResampler, sample: (f64, f64, u8, u8, bool)) -> Vec<SubEvent> {
        let (dx, dy, scroll_phase, momentum_phase, continuous) = sample;
        resampler.ingest(dx, dy, scroll_phase, momentum_phase, continuous)
    }

    #[test]
    fn a_continuous_sample_emits_nothing_until_it_is_drained() {
        let mut resampler = ScrollResampler::default();
        assert!(ingest(&mut resampler, changed(0.0, 10.0)).is_empty());
        assert!(!resampler.is_idle());
        assert_eq!(
            resampler.drain(),
            Some(SubEvent {
                dx: 0.0,
                dy: 5.0,
                scroll_phase: SCROLL_CHANGED,
                momentum_phase: 0,
                continuous: true,
            }),
            "half of the residual, at the default spread",
        );
    }

    /// The property the whole design turns on: what goes in comes out, to under a pixel.
    #[test]
    fn the_drained_total_equals_the_ingested_total() {
        let mut resampler = ScrollResampler::default();
        let mut emitted = 0.0;
        for step in 0..20 {
            assert!(
                ingest(&mut resampler, changed(0.0, 7.3)).is_empty(),
                "step {step}"
            );
            while let Some(event) = resampler.drain() {
                emitted += event.dy;
            }
        }
        let ingested = 7.3 * 20.0;
        // Nothing is lost: what has not been emitted is still held as carry, and the carry is only
        // ever the sub-pixel remainder.
        let held = resampler.residual_y;
        assert!(held.abs() < 1.0, "held {held}");
        assert!(
            (ingested - (emitted + held)).abs() < 1e-9,
            "{emitted} + {held} against {ingested}"
        );
    }

    #[test]
    fn a_marker_passes_through_immediately_and_alone() {
        let mut resampler = ScrollResampler::default();
        let began = ingest(&mut resampler, (0.0, 0.0, 1, 0, true));
        assert_eq!(began, vec![SubEvent {
            dx: 0.0,
            dy: 0.0,
            scroll_phase: 1,
            momentum_phase: 0,
            continuous: true
        }],);
    }

    /// A `Changed` after an `Ended` corrupts rubber-banding, so the residual has to leave with the
    /// gesture that produced it.
    #[test]
    fn an_ending_marker_flushes_the_residual_before_itself() {
        let mut resampler = ScrollResampler::default();
        assert!(ingest(&mut resampler, changed(0.0, 30.0)).is_empty());
        let out = ingest(&mut resampler, (0.0, 0.0, SCROLL_ENDED, 0, true));
        assert_eq!(out.len(), 2);
        assert_eq!(
            out.first().map(|event| event.dy),
            Some(30.0),
            "the whole residual, first"
        );
        assert_eq!(out.first().map(|event| event.scroll_phase), Some(SCROLL_CHANGED));
        assert_eq!(out.get(1).map(|event| event.scroll_phase), Some(SCROLL_ENDED));
        assert_eq!(resampler.drain(), None, "nothing survives the End marker");
        assert!(resampler.is_idle());
    }

    #[test]
    fn a_cancel_and_a_momentum_end_flush_the_same_way() {
        for ending in [(SCROLL_CANCELLED, 0_u8), (0, MOMENTUM_END)] {
            let mut resampler = ScrollResampler::default();
            assert!(ingest(&mut resampler, changed(0.0, 12.0)).is_empty());
            let out = ingest(&mut resampler, (0.0, 0.0, ending.0, ending.1, true));
            assert_eq!(out.len(), 2, "{ending:?}");
            assert_eq!(resampler.drain(), None);
        }
    }

    /// A momentum coast has to keep its own phase, or the resampled continuation reads as a finger
    /// back on the glass.
    #[test]
    fn a_coasting_continuation_carries_momentum_rather_than_changed() {
        let mut resampler = ScrollResampler::default();
        assert_eq!(
            ingest(&mut resampler, (0.0, 0.0, 0, MOMENTUM_BEGAN, true)).len(),
            1
        );
        assert!(ingest(&mut resampler, (0.0, 20.0, 0, MOMENTUM_CONTINUE, true)).is_empty());
        let drained = resampler.drain().expect("a whole pixel to emit");
        assert_eq!(drained.scroll_phase, 0);
        assert_eq!(drained.momentum_phase, MOMENTUM_CONTINUE);
        // A finger sample flips it back.
        assert!(ingest(&mut resampler, changed(0.0, 20.0)).is_empty());
        let after = resampler.drain().expect("a whole pixel to emit");
        assert_eq!(after.scroll_phase, SCROLL_CHANGED);
        assert_eq!(after.momentum_phase, 0);
    }

    /// The lag cap is what stops a flick crawling out over dozens of ticks.
    #[test]
    fn a_flick_drains_down_to_the_lag_cap_in_one_tick() {
        let mut resampler = ScrollResampler::new(2.0, 48.0);
        assert!(ingest(&mut resampler, changed(0.0, 400.0)).is_empty());
        assert_eq!(
            resampler.drain().map(|event| event.dy),
            Some(352.0),
            "400 down to the cap"
        );
        // From there the fraction drain takes over.
        assert_eq!(resampler.drain().map(|event| event.dy), Some(24.0));
    }

    #[test]
    fn a_sub_pixel_residual_is_held_and_carried_rather_than_rounded_away() {
        let mut resampler = ScrollResampler::default();
        for _ in 0..4 {
            assert!(ingest(&mut resampler, changed(0.0, 0.2)).is_empty());
            assert_eq!(resampler.drain(), None, "under a pixel emits nothing");
        }
        // Four fifths of a pixel so far, and the carry is what finally makes one whole.
        assert!(ingest(&mut resampler, changed(0.0, 0.3)).is_empty());
        assert_eq!(resampler.drain().map(|event| event.dy), Some(1.0));
    }

    #[test]
    fn a_bad_sample_cannot_poison_the_residual() {
        let mut resampler = ScrollResampler::default();
        assert!(ingest(&mut resampler, changed(f64::NAN, f64::INFINITY)).is_empty());
        assert!(resampler.is_idle());
        assert_eq!(resampler.drain(), None);
    }

    #[test]
    fn a_hostile_knob_falls_back_to_its_default() {
        assert_eq!(
            ScrollResampler::new(f64::NAN, f64::NAN),
            ScrollResampler::default()
        );
        assert_eq!(
            ScrollResampler::new(0.5, 0.5),
            ScrollResampler::default(),
            "under the floor"
        );
        // …and an absurd one is clamped rather than rejected.
        let wild = ScrollResampler::new(1e9, 1e9);
        assert_eq!(wild, ScrollResampler::new(16.0, 4096.0));
    }

    #[test]
    fn a_reset_drops_the_residual_and_the_phase() {
        let mut resampler = ScrollResampler::default();
        assert!(ingest(&mut resampler, (0.0, 40.0, 0, MOMENTUM_CONTINUE, true)).is_empty());
        resampler.reset();
        assert!(resampler.is_idle());
        assert_eq!(resampler.drain(), None);
        assert!(ingest(&mut resampler, changed(0.0, 10.0)).is_empty());
        assert_eq!(
            resampler.drain().map(|event| event.momentum_phase),
            Some(0),
            "the coast did not survive the reset",
        );
    }
}
