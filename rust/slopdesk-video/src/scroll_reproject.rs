//! The client-side scroll-hint reprojection law.
//!
//! Integrate the local scroll velocity into a small normalised UV offset on the pacer's
//! *between-content* display ticks, so a remote window scrolls at the display rate rather than the
//! frame rate; clamp that offset to a band; decay it once the scroll stops; and RESET it to exactly
//! zero the instant a real decoded frame is presented. That last step is the whole correctness
//! argument: the decoded frame already contains the scrolled content, so anything still accumulated
//! would be counted twice.
//!
//! Units are normalised — a frame spans `0..1` on each axis — so the law is resolution-independent.
//! Every method takes the elapsed time it needs as a parameter: no wall clock, no environment, no
//! I/O, deterministic to the bit. A non-finite input is dropped rather than integrated, so neither
//! a bad event nor a clock glitch can poison the integrator.

use crate::client_gestures::{
    MOMENTUM_BEGIN, MOMENTUM_CONTINUE, MOMENTUM_END, SCROLL_CANCELLED, SCROLL_ENDED,
};
use crate::geometry::ordered_clamp;

/// The phase of a scroll-velocity sample, as the platform's finer phase codes collapse to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollPhase {
    /// Finger on glass: track the velocity, no decay.
    Active,
    /// Inertial coast: track the velocity, no decay.
    Momentum,
    /// The gesture finished: arm the decay.
    Ended,
}

impl ScrollPhase {
    /// The phase the platform's two scroll codes name together.
    ///
    /// A momentum END arms the decay, a momentum begin or continue coasts, a finger-lift end or a
    /// cancel arms the decay, and anything else with a live finger is active. The momentum code is
    /// read FIRST because it is the later half of one gesture: a frame carrying both a stale finger
    /// phase and a live momentum phase is coasting, not dragging.
    ///
    /// The codes are the platform's, and they are named rather than typed: the two fields use
    /// DIFFERENT encodings — a momentum end is 3 where a scroll end is 4 — so a bare literal here
    /// reads as if it belonged to whichever field the eye happened to be on. `client_gestures` owns
    /// the table both this and the Mac client's phase mapping read.
    ///
    /// An unknown code on either falls to [`ScrollPhase::Active`], which tracks without arming a
    /// decay — the reading a stray sample may not silently stop a live scroll with.
    #[must_use]
    pub const fn of_platform(scroll_phase: u8, momentum_phase: u8) -> Self {
        match momentum_phase {
            MOMENTUM_END => Self::Ended,
            MOMENTUM_BEGIN | MOMENTUM_CONTINUE => Self::Momentum,
            _ => {
                match scroll_phase {
                    SCROLL_ENDED | SCROLL_CANCELLED => Self::Ended,
                    _ => Self::Active,
                }
            },
        }
    }
}

/// One host-MEASURED per-frame scroll shift, in the fixed-point units it crosses the wire in.
///
/// The host measures the true pixel shift between two captured frames; the client must never guess
/// one from local trackpad deltas, because the host applies momentum, acceleration and clamping the
/// client cannot know and a guess snaps and shakes. So the measurement is normalised on the host —
/// a signed shift in TEN-THOUSANDTHS of the frame extent, plus the moving-content band in the same
/// units — travels as four small integers, and turns back into a velocity on the client.
///
/// Both halves live here, together, because they are one encoding: a scale spelled on only one side
/// is a scale the two sides can drift apart on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ScrollHint {
    /// The signed horizontal shift over one frame, in ten-thousandths of the frame width.
    dx: i16,
    /// The signed vertical shift over one frame, in ten-thousandths of the frame height.
    dy: i16,
    /// The top of the moving-content band, in ten-thousandths of the frame height.
    band_top: u16,
    /// The bottom of the band, exclusive, in the same units. Not above the top ⇒ no band.
    band_bottom: u16,
}

impl ScrollHint {
    /// The fixed-point scale: a whole frame extent is ten thousand units.
    pub const SCALE: f64 = 10_000.0;

    /// The confidence, in thousandths, below which a measurement is not a scroll.
    ///
    /// Typing and other non-scroll change produce a shift with a poor match fraction; acting on one
    /// would warp the picture for something that never moved.
    pub const MIN_CONFIDENCE_MILLI: u32 = 500;

    /// The largest magnitude either shift can carry, so the fixed-point value fits its integer.
    const MAX_SHIFT: f64 = 32767.0;

    /// The hint that says nothing moved: no shift, no band.
    pub const NONE: Self = Self {
        dx: 0,
        dy: 0,
        band_top: 0,
        band_bottom: 0,
    };

    /// The hint a measured estimate encodes, given the frame height it was measured over.
    ///
    /// `shift` is in rows, positive meaning the content moved DOWN; `band_top_row` and
    /// `band_bottom_row` are the INCLUSIVE current-frame row span of the moving content, negative
    /// when there is none. An unconfident or zero shift, or a degenerate height, is [`Self::NONE`]
    /// — a defined "nothing to reproject", never a fault.
    ///
    /// The v1 host measures vertical scroll only, so `dx` is always zero here; the field exists
    /// because the wire and the law are both two-axis and a one-axis encoding would have to be
    /// widened on both sides at once.
    #[must_use]
    pub fn measured(
        shift: i32,
        confidence_milli: u32,
        band_top_row: i32,
        band_bottom_row: i32,
        height: usize,
    ) -> Self {
        if confidence_milli < Self::MIN_CONFIDENCE_MILLI || shift == 0 || height == 0 {
            return Self::NONE;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame height that no longer converts exactly is orders of magnitude past any capture"
        )]
        let rows = height as f64;
        // Divide before scaling, each step its own operation: the two ends compare integers, so a
        // fused or reordered arithmetic here would move the value rather than round it differently.
        let dy = fixed(f64::from(shift) / rows);
        let (band_top, band_bottom) = if band_top_row >= 0 && band_bottom_row >= band_top_row {
            // The band's bottom row is INCLUSIVE, so the exclusive edge is one row past it.
            let bottom_edge = i64::from(band_bottom_row) + 1;
            #[expect(
                clippy::cast_precision_loss,
                reason = "a row index this side of a frame height converts exactly"
            )]
            let bottom = bottom_edge as f64;
            (edge(f64::from(band_top_row) / rows), edge(bottom / rows))
        } else {
            (0, 0)
        };
        Self {
            dx: 0,
            dy,
            band_top,
            band_bottom,
        }
    }

    /// The hint a caller that carries these four integers describes.
    ///
    /// Nothing is re-derived: what arrives is what the host measured, and re-clamping a value that
    /// was already clamped where it was made would only invite the two ends to disagree about which
    /// pass did it.
    #[must_use]
    pub const fn restored(dx: i16, dy: i16, band_top: u16, band_bottom: u16) -> Self {
        Self {
            dx,
            dy,
            band_top,
            band_bottom,
        }
    }

    /// The signed horizontal shift, in ten-thousandths of the frame width.
    #[must_use]
    pub const fn dx(&self) -> i16 {
        self.dx
    }

    /// The signed vertical shift, in ten-thousandths of the frame height.
    #[must_use]
    pub const fn dy(&self) -> i16 {
        self.dy
    }

    /// The band's top edge, in ten-thousandths of the frame height.
    #[must_use]
    pub const fn band_top(&self) -> u16 {
        self.band_top
    }

    /// The band's bottom edge, exclusive, in ten-thousandths of the frame height.
    #[must_use]
    pub const fn band_bottom(&self) -> u16 {
        self.band_bottom
    }

    /// The velocity sample this hint is, given the rate the content frames arrive at.
    ///
    /// A shift is measured over ONE frame, so the velocity in normalised units per second is that
    /// shift times the content frame rate. A rate below one frame a second — or a non-finite one —
    /// reads as one, so a stalled or unmeasured stream can never scale the offset to a jump.
    ///
    /// A zero shift is the host saying the scroll STOPPED, which is [`ScrollPhase::Ended`] and arms
    /// the decay; anything else is a live scroll. The client never sees the finger, so this is the
    /// only phase it can honestly report.
    #[must_use]
    pub fn velocity(&self, content_fps: f64) -> ScrollVelocity {
        let fps = if content_fps.is_finite() && content_fps > 1.0 {
            content_fps
        } else {
            1.0
        };
        let norm_x = f64::from(self.dx) / Self::SCALE;
        let norm_y = f64::from(self.dy) / Self::SCALE;
        ScrollVelocity {
            vx: norm_x * fps,
            vy: norm_y * fps,
            phase: if self.dx == 0 && self.dy == 0 {
                ScrollPhase::Ended
            } else {
                ScrollPhase::Active
            },
        }
    }

    /// The moving-content band as normalised edges, or `None` when this hint carries none.
    ///
    /// The renderer warps only inside the band, so the static chrome — toolbars, tabs, a status bar
    /// — stays put instead of sliding with the content. `None` is not "an empty band": a caller
    /// holding one from an earlier frame should KEEP it, so a decay tick eases out still masked.
    #[must_use]
    pub fn band(&self) -> Option<(f32, f32)> {
        (self.band_bottom > self.band_top).then(|| {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the scale is a power-of-ten constant the renderer takes in single precision"
            )]
            let scale = Self::SCALE as f32;
            (
                f32::from(self.band_top) / scale,
                f32::from(self.band_bottom) / scale,
            )
        })
    }
}

/// One scroll-velocity sample, in normalised units per second, with the phase it carries.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScrollVelocity {
    /// The horizontal velocity.
    pub vx: f64,
    /// The vertical velocity.
    pub vy: f64,
    /// The phase the sample folds under.
    pub phase: ScrollPhase,
}

/// A normalised fraction as a signed fixed-point shift, clamped to what the wire field holds.
fn fixed(fraction: f64) -> i16 {
    let scaled = (fraction * ScrollHint::SCALE).round();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "clamped to the field's range before the cast, so the value is exactly representable"
    )]
    let value = ordered_clamp(scaled, -ScrollHint::MAX_SHIFT, ScrollHint::MAX_SHIFT) as i16;
    value
}

/// A normalised fraction as an unsigned fixed-point band edge, clamped to the frame.
fn edge(fraction: f64) -> u16 {
    let scaled = (fraction * ScrollHint::SCALE).round();
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "clamped to `0..=10000` before the cast, so the value is exactly representable"
    )]
    let value = ordered_clamp(scaled, 0.0, ScrollHint::SCALE) as u16;
    value
}

/// The integrator. One per pane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScrollReprojector {
    /// The per-axis clamp on the integrated offset, in normalised units.
    max_band: f64,
    /// The decay time constant after a scroll ends, in seconds.
    decay_seconds: f64,
    /// The current integrated horizontal offset, clamped to the band.
    offset_x: f64,
    /// The current integrated vertical offset.
    offset_y: f64,
    /// The current horizontal velocity, in normalised units per second.
    velocity_x: f64,
    /// The current vertical velocity.
    velocity_y: f64,
    /// Whether a scroll has ended, so an advance decays rather than integrates.
    decaying: bool,
}

impl Default for ScrollReprojector {
    fn default() -> Self {
        Self::new(Self::DEFAULT_MAX_BAND, Self::DEFAULT_DECAY_SECONDS)
    }
}

impl ScrollReprojector {
    /// The default maximum reprojection band per axis, roughly an eighth of the frame.
    ///
    /// A hint never translates the frame further than this: past it the disocclusion gutter would
    /// dominate and the guess would be worse than a static re-show, so the offset clamps.
    pub const DEFAULT_MAX_BAND: f64 = 0.125;

    /// The default decay time constant (seconds) once a scroll has stopped.
    ///
    /// The offset bleeds to zero over about this long, so the picture eases to rest instead of
    /// snapping back when the velocity source goes quiet before a fresh frame has reset it.
    pub const DEFAULT_DECAY_SECONDS: f64 = 0.12;

    /// About an eight-thousandth of a frame — under one pixel on any realistic panel, so an offset
    /// inside it is treated as rest and snapped to exactly zero.
    const REST_EPSILON: f64 = 1.25e-4;

    /// A reprojector with the given band and decay constant, both sanitised into a sane range so a
    /// hostile knob can never produce a runaway or negative offset. Offset and velocity start zero.
    #[must_use]
    pub fn new(max_band: f64, decay_seconds: f64) -> Self {
        Self {
            max_band: if max_band.is_finite() {
                ordered_clamp(max_band, 0.0, 0.5)
            } else {
                Self::DEFAULT_MAX_BAND
            },
            decay_seconds: if decay_seconds.is_finite() {
                ordered_clamp(decay_seconds, 0.0, 2.0)
            } else {
                Self::DEFAULT_DECAY_SECONDS
            },
            offset_x: 0.0,
            offset_y: 0.0,
            velocity_x: 0.0,
            velocity_y: 0.0,
            decaying: false,
        }
    }

    /// The reprojector a caller that stores this state rather than owning it describes.
    ///
    /// The knobs are NOT re-sanitised: they were sanitised when the state was first built, and
    /// clamping an already-clamped value would only invite the two ends to disagree about which
    /// pass did it. What crosses back is what crossed out.
    #[must_use]
    pub const fn restored(
        max_band: f64,
        decay_seconds: f64,
        offset_x: f64,
        offset_y: f64,
        velocity_x: f64,
        velocity_y: f64,
        decaying: bool,
    ) -> Self {
        Self {
            max_band,
            decay_seconds,
            offset_x,
            offset_y,
            velocity_x,
            velocity_y,
            decaying,
        }
    }

    /// The current offset, without advancing anything.
    #[must_use]
    pub const fn offset(&self) -> (f64, f64) {
        (self.offset_x, self.offset_y)
    }

    /// The live velocity, in normalised units per second.
    #[must_use]
    pub const fn velocity(&self) -> (f64, f64) {
        (self.velocity_x, self.velocity_y)
    }

    /// The per-axis band the offset clamps to, as sanitised at construction.
    #[must_use]
    pub const fn max_band(&self) -> f64 {
        self.max_band
    }

    /// The decay time constant, as sanitised at construction.
    #[must_use]
    pub const fn decay_seconds(&self) -> f64 {
        self.decay_seconds
    }

    /// Whether a scroll has ended, so the next advance decays rather than integrates.
    #[must_use]
    pub const fn decaying(&self) -> bool {
        self.decaying
    }

    /// Folds one scroll-velocity sample, in normalised units per second, with its phase.
    ///
    /// An active or coasting sample sets the live velocity and disarms the decay. An ended sample
    /// KEEPS the last velocity — unless it carried its own non-zero one, as some platforms send a
    /// final sample — and arms the decay, so the next advance eases the offset to rest.
    pub fn note_velocity(&mut self, vx: f64, vy: f64, phase: ScrollPhase) {
        let vx = if vx.is_finite() { vx } else { 0.0 };
        let vy = if vy.is_finite() { vy } else { 0.0 };
        match phase {
            ScrollPhase::Active | ScrollPhase::Momentum => {
                self.velocity_x = vx;
                self.velocity_y = vy;
                self.decaying = false;
            },
            ScrollPhase::Ended => {
                if vx != 0.0 || vy != 0.0 {
                    self.velocity_x = vx;
                    self.velocity_y = vy;
                }
                self.decaying = true;
            },
        }
    }

    /// Integrates the velocity over `elapsed_seconds` — or decays a stopped scroll — clamps each
    /// axis to the band, and returns the resulting normalised offset.
    ///
    /// Called once per spare display tick with the time since the last one. A non-finite or
    /// negative elapsed time is treated as zero and the offset comes back unchanged, so a clock
    /// glitch can never jump the picture.
    pub fn advance(&mut self, elapsed_seconds: f64) -> (f64, f64) {
        let dt = if elapsed_seconds.is_finite() && elapsed_seconds > 0.0 {
            elapsed_seconds
        } else {
            0.0
        };
        if self.decaying {
            self.apply_decay(dt);
        } else {
            // Keep the multiply and the add separate: fusing them would break bit-exact parity.
            let step_x = self.velocity_x * dt;
            self.offset_x += step_x;
            let step_y = self.velocity_y * dt;
            self.offset_y += step_y;
        }
        self.offset_x = ordered_clamp(self.offset_x, -self.max_band, self.max_band);
        self.offset_y = ordered_clamp(self.offset_y, -self.max_band, self.max_band);
        (self.offset_x, self.offset_y)
    }

    /// Resets the offset to exactly zero — the no-double-count reset.
    ///
    /// Call this the instant a real decoded frame is presented. The live velocity is PRESERVED, as
    /// the gesture may still be in flight and the next spare tick re-integrates from zero, but the
    /// decay flag is cleared: the fresh frame is the authoritative rest position.
    pub const fn note_real_frame(&mut self) {
        self.offset_x = 0.0;
        self.offset_y = 0.0;
        self.decaying = false;
    }

    /// Drops the offset AND the velocity — for a pane going idle or losing focus, so a stale
    /// velocity cannot resume on the next event.
    pub const fn reset(&mut self) {
        self.offset_x = 0.0;
        self.offset_y = 0.0;
        self.velocity_x = 0.0;
        self.velocity_y = 0.0;
        self.decaying = false;
    }

    /// A geometric ease-out toward zero on the decay time constant, snapping to exactly zero inside
    /// the rest epsilon so the offset settles rather than asymptoting forever.
    fn apply_decay(&mut self, dt: f64) {
        if self.decay_seconds <= 0.0 {
            // A zero or degenerate time constant means "stop instantly".
            self.offset_x = 0.0;
            self.offset_y = 0.0;
            return;
        }
        let factor = (-dt / self.decay_seconds).exp();
        self.offset_x *= factor;
        self.offset_y *= factor;
        if self.offset_x.abs() < Self::REST_EPSILON {
            self.offset_x = 0.0;
        }
        if self.offset_y.abs() < Self::REST_EPSILON {
            self.offset_y = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the assertions on exact equality are on values the law SNAPPED to a constant — zero, or \
                  the band — which is the property under test; the integrated values are compared with a \
                  tolerance"
    )]

    use super::{ScrollHint, ScrollPhase, ScrollReprojector};

    #[test]
    fn the_momentum_code_is_read_before_the_finger_because_it_is_the_later_half() {
        assert_eq!(ScrollPhase::of_platform(2, 0), ScrollPhase::Active);
        assert_eq!(ScrollPhase::of_platform(1, 0), ScrollPhase::Active);
        assert_eq!(ScrollPhase::of_platform(0, 1), ScrollPhase::Momentum);
        assert_eq!(ScrollPhase::of_platform(0, 2), ScrollPhase::Momentum);
        assert_eq!(ScrollPhase::of_platform(4, 0), ScrollPhase::Ended);
        assert_eq!(ScrollPhase::of_platform(8, 0), ScrollPhase::Ended);
        assert_eq!(ScrollPhase::of_platform(0, 3), ScrollPhase::Ended);
        assert_eq!(
            ScrollPhase::of_platform(4, 2),
            ScrollPhase::Momentum,
            "a lifted finger under a live coast is still coasting"
        );
        assert_eq!(
            ScrollPhase::of_platform(99, 99),
            ScrollPhase::Active,
            "an unknown code tracks rather than silently arming a decay"
        );
    }

    #[test]
    fn a_measured_shift_crosses_as_a_fraction_of_the_frame_it_was_measured_over() {
        let hint = ScrollHint::measured(48, 900, 100, 899, 960);
        assert_eq!(hint.dy(), 500, "48 rows of 960 is a twentieth of the frame");
        assert_eq!(hint.dx(), 0, "the v1 host measures the vertical axis only");
        assert_eq!(
            (hint.band_top(), hint.band_bottom()),
            (1042, 9375),
            "the band's inclusive bottom row becomes an exclusive edge"
        );
    }

    #[test]
    fn an_unconfident_or_still_frame_measures_nothing_rather_than_something_small() {
        assert_eq!(ScrollHint::measured(48, 499, 0, 100, 960), ScrollHint::NONE);
        assert_eq!(ScrollHint::measured(0, 1000, 0, 100, 960), ScrollHint::NONE);
        assert_eq!(
            ScrollHint::measured(48, 1000, 0, 100, 0),
            ScrollHint::NONE,
            "a frame with no height is not a frame that scrolled infinitely"
        );
        assert_eq!(
            ScrollHint::measured(48, 1000, -1, -1, 960).band(),
            None,
            "no band is absent, not an empty span at the top of the frame"
        );
    }

    #[test]
    fn a_shift_past_the_frame_saturates_rather_than_wrapping_into_the_other_direction() {
        let hint = ScrollHint::measured(40_000, 1000, -1, -1, 960);
        assert_eq!(hint.dy(), 32767);
        let up = ScrollHint::measured(-40_000, 1000, -1, -1, 960);
        assert_eq!(up.dy(), -32767);
    }

    #[test]
    fn one_frame_of_shift_becomes_a_velocity_at_the_rate_the_frames_arrive() {
        let hint = ScrollHint::restored(0, 500, 0, 5000);
        let sample = hint.velocity(60.0);
        assert_eq!(sample.vy, 3.0, "a twentieth of a frame, sixty times a second");
        assert_eq!(sample.vx, 0.0);
        assert_eq!(sample.phase, ScrollPhase::Active);
        assert_eq!(hint.band(), Some((0.0, 0.5)));
        let stalled = hint.velocity(f64::NAN);
        assert_eq!(
            stalled.vy, 0.05,
            "an unmeasured rate is one frame a second, not a jump"
        );
    }

    #[test]
    fn a_zero_shift_is_the_host_saying_the_scroll_stopped() {
        let sample = ScrollHint::restored(0, 0, 1000, 2000).velocity(60.0);
        assert_eq!(sample.phase, ScrollPhase::Ended);
        assert_eq!(sample.vy, 0.0);
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(sample.vx, sample.vy, sample.phase);
        assert!(reprojector.decaying(), "and that arms the decay");
        assert_eq!(
            ScrollHint::restored(0, 0, 2000, 2000).band(),
            None,
            "a band of no height is no band"
        );
    }

    #[test]
    fn a_steady_velocity_integrates_into_an_offset() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(0.0, 0.2, ScrollPhase::Active);
        let (_, y) = reprojector.advance(0.1);
        assert!((y - 0.02).abs() < 1e-12);
        let (_, y) = reprojector.advance(0.1);
        assert!((y - 0.04).abs() < 1e-12, "it accumulates rather than replacing");
    }

    /// The band is what keeps a flick from translating the frame into its own disocclusion gutter.
    #[test]
    fn the_offset_clamps_to_the_band_in_both_directions() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(9.0, -9.0, ScrollPhase::Active);
        let (x, y) = reprojector.advance(1.0);
        assert_eq!(x, ScrollReprojector::DEFAULT_MAX_BAND);
        assert_eq!(y, -ScrollReprojector::DEFAULT_MAX_BAND);
    }

    /// The reset is the entire no-double-count argument.
    #[test]
    fn a_real_frame_zeroes_the_offset_but_keeps_the_gesture() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(0.0, 0.2, ScrollPhase::Active);
        assert!(reprojector.advance(0.1).1 > 0.0);
        reprojector.note_real_frame();
        assert_eq!(reprojector.offset(), (0.0, 0.0));
        // The gesture is still in flight, so the next spare tick re-integrates from zero.
        let (_, y) = reprojector.advance(0.1);
        assert!((y - 0.02).abs() < 1e-12);
    }

    #[test]
    fn an_ended_gesture_decays_to_rest_and_stays_there() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(0.0, 0.5, ScrollPhase::Active);
        let started = reprojector.advance(0.1).1;
        assert!(started > 0.0);
        reprojector.note_velocity(0.0, 0.0, ScrollPhase::Ended);
        let mut previous = started;
        for _ in 0..100 {
            let now = reprojector.advance(0.01).1;
            assert!(now <= previous, "the decay never grows the offset");
            previous = now;
        }
        assert_eq!(
            previous, 0.0,
            "it settles at exactly zero rather than asymptoting"
        );
    }

    /// An end sample that carries its own velocity replaces the last one; one that does not, keeps
    /// it — the difference between platforms that send a final sample and ones that do not.
    #[test]
    fn an_end_sample_only_replaces_the_velocity_when_it_carries_one() {
        let mut kept = ScrollReprojector::default();
        kept.note_velocity(0.0, 0.5, ScrollPhase::Active);
        kept.note_velocity(0.0, 0.0, ScrollPhase::Ended);
        assert_eq!(
            kept.velocity_y, 0.5,
            "an empty end sample does not zero the coast"
        );

        let mut replaced = ScrollReprojector::default();
        replaced.note_velocity(0.0, 0.5, ScrollPhase::Active);
        replaced.note_velocity(0.0, 0.1, ScrollPhase::Ended);
        assert_eq!(
            replaced.velocity_y, 0.1,
            "one that carries a velocity replaces it"
        );
    }

    #[test]
    fn a_zero_time_constant_stops_the_offset_instantly() {
        let mut reprojector = ScrollReprojector::new(0.125, 0.0);
        reprojector.note_velocity(0.0, 0.5, ScrollPhase::Active);
        assert!(reprojector.advance(0.1).1 > 0.0);
        reprojector.note_velocity(0.0, 0.0, ScrollPhase::Ended);
        assert_eq!(reprojector.advance(0.01), (0.0, 0.0));
    }

    #[test]
    fn a_momentum_sample_keeps_integrating_rather_than_decaying() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(0.0, 0.2, ScrollPhase::Active);
        reprojector.note_velocity(0.0, 0.1, ScrollPhase::Momentum);
        let (_, first) = reprojector.advance(0.1);
        let (_, second) = reprojector.advance(0.1);
        assert!(second > first, "a coast still moves the picture");
    }

    #[test]
    fn a_bad_sample_or_a_bad_clock_can_never_jump_the_picture() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(f64::NAN, f64::INFINITY, ScrollPhase::Active);
        assert_eq!(
            reprojector.advance(0.1),
            (0.0, 0.0),
            "a non-finite sample is zero"
        );

        reprojector.note_velocity(0.0, 0.2, ScrollPhase::Active);
        let held = reprojector.advance(0.1);
        assert_eq!(
            reprojector.advance(f64::NAN),
            held,
            "a non-finite tick advances nothing"
        );
        assert_eq!(
            reprojector.advance(-1.0),
            held,
            "and neither does a backwards one"
        );
    }

    #[test]
    fn a_hostile_knob_falls_back_to_its_default_or_clamps() {
        assert_eq!(
            ScrollReprojector::new(f64::NAN, f64::NAN),
            ScrollReprojector::default()
        );
        let wild = ScrollReprojector::new(9.0, 9.0);
        assert_eq!(wild, ScrollReprojector::new(0.5, 2.0), "clamped, not rejected");
        let negative = ScrollReprojector::new(-1.0, -1.0);
        assert_eq!(
            negative,
            ScrollReprojector::new(0.0, 0.0),
            "a negative band is no band"
        );
    }

    #[test]
    fn a_reset_drops_the_velocity_too() {
        let mut reprojector = ScrollReprojector::default();
        reprojector.note_velocity(0.0, 0.2, ScrollPhase::Active);
        assert!(reprojector.advance(0.1).1 > 0.0);
        reprojector.reset();
        assert_eq!(reprojector.advance(0.1), (0.0, 0.0), "nothing resumed");
    }
}
