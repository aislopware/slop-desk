//! The scroll-resampling law: a bursty low-rate wire stream metered out at a fixed high rate.
//!
//! Six scalars, so it crosses BY VALUE, the way the reprojector next door does. The near side is a
//! Swift `struct` the injector holds inline and mutates on its own serial queue — a value there and
//! a value here, which is the convention the far side is entitled to pick.
//!
//! An ingest answers a FIXED PAIR of sub-events rather than a list, because the law's own branches
//! bound it at two: a marker, and at most one residual flush in front of an ending marker. A
//! variable answer would need an allocation and a length rule where a proved constant does.

use slopdesk_video::scroll_resample::{ScrollResampler, SubEvent};

/// The most sub-events one ingest can answer with — the crate's own proved bound.
pub const SLOPDESK_SCROLL_MAX_INGEST: usize = ScrollResampler::MAX_INGEST_EVENTS;

/// One integer-pixel sub-event to post, carrying the `CoreGraphics` phase codes verbatim.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollSubEvent {
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

/// A sub-event slot with nothing in it, so an unused half of the pair is never read as an event.
const EMPTY_EVENT: SlopDeskScrollSubEvent = SlopDeskScrollSubEvent {
    dx: 0.0,
    dy: 0.0,
    scroll_phase: 0,
    momentum_phase: 0,
    continuous: false,
};

impl SlopDeskScrollSubEvent {
    /// The crossing form of one sub-event.
    const fn of(event: SubEvent) -> Self {
        Self {
            dx: event.dx,
            dy: event.dy,
            scroll_phase: event.scroll_phase,
            momentum_phase: event.momentum_phase,
            continuous: event.continuous,
        }
    }
}

/// The resampler, as it crosses: two knobs, the per-axis residual and the phase the continuations
/// are stamped with.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollResampler {
    /// The fraction divisor: each drain emits about `residual / spread`.
    pub spread: f64,
    /// The per-axis lag cap, in pixels.
    pub lag_cap: f64,
    /// The un-emitted horizontal residual, sub-pixel fraction and all.
    pub residual_x: f64,
    /// The un-emitted vertical residual.
    pub residual_y: f64,
    /// Whether the latest continuous samples are an inertial coast.
    pub coasting: bool,
    /// The precise/continuous flag stamped on resampled continuations.
    pub continuous_flag: bool,
}

impl SlopDeskScrollResampler {
    /// The wrapped resampler this describes.
    const fn inner(self) -> ScrollResampler {
        ScrollResampler::restored(
            self.spread,
            self.lag_cap,
            self.residual_x,
            self.residual_y,
            self.coasting,
            self.continuous_flag,
        )
    }

    /// The crossing form of a wrapped resampler.
    const fn of(resampler: &ScrollResampler) -> Self {
        let (residual_x, residual_y) = resampler.residual();
        Self {
            spread: resampler.spread(),
            lag_cap: resampler.lag_cap(),
            residual_x,
            residual_y,
            coasting: resampler.coasting(),
            continuous_flag: resampler.continuous_flag(),
        }
    }
}

/// One ingest: the state that results, and the markers to post at once.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollIngest {
    /// The resampler after the fold.
    pub resampler: SlopDeskScrollResampler,
    /// The sub-events to post immediately, in order. Only the first `count` are events.
    pub events: [SlopDeskScrollSubEvent; SLOPDESK_SCROLL_MAX_INGEST],
    /// How many of `events` the fold answered with — never more than the array holds.
    pub count: usize,
}

/// One drain tick: the state that results, and the continuation to post if there was one.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollDrain {
    /// The resampler after the tick.
    pub resampler: SlopDeskScrollResampler,
    /// The continuation sub-event, meaningful only when `emitted`.
    pub event: SlopDeskScrollSubEvent,
    /// Whether there was a whole pixel to emit on either axis.
    pub emitted: bool,
}

/// The law's default knobs, so the near side spells neither.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollResamplerDefaults {
    /// The default fraction divisor.
    pub spread: f64,
    /// The default per-axis lag cap, in pixels.
    pub lag_cap: f64,
}

/// The law's default knobs.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_resampler_defaults() -> SlopDeskScrollResamplerDefaults {
    SlopDeskScrollResamplerDefaults {
        spread: ScrollResampler::DEFAULT_SPREAD,
        lag_cap: ScrollResampler::DEFAULT_LAG_CAP,
    }
}

/// A resampler at rest, with both knobs sanitised into the band the law will accept.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_resampler_new(spread: f64, lag_cap: f64) -> SlopDeskScrollResampler {
    SlopDeskScrollResampler::of(&ScrollResampler::new(spread, lag_cap))
}

/// Folds one arriving wire event, answering the markers to post at once. A continuous sample
/// answers with none — it accumulates, and surfaces through a later drain.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_resampler_ingest(
    resampler: SlopDeskScrollResampler,
    dx: f64,
    dy: f64,
    scroll_phase: u8,
    momentum_phase: u8,
    continuous: bool,
) -> SlopDeskScrollIngest {
    let mut inner = resampler.inner();
    let markers = inner.ingest(dx, dy, scroll_phase, momentum_phase, continuous);
    let mut events = [EMPTY_EVENT; SLOPDESK_SCROLL_MAX_INGEST];
    let mut count = 0;
    // The zip is what bounds the copy: the crate proves at most two, and a third could only ever
    // fall off the end here rather than run past the array.
    for (slot, marker) in events.iter_mut().zip(markers) {
        *slot = SlopDeskScrollSubEvent::of(marker);
        count += 1;
    }
    SlopDeskScrollIngest {
        resampler: SlopDeskScrollResampler::of(&inner),
        events,
        count,
    }
}

/// The next resampled continuation, on the caller's fixed output cadence.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_resampler_drain(resampler: SlopDeskScrollResampler) -> SlopDeskScrollDrain {
    let mut inner = resampler.inner();
    let drained = inner.drain();
    SlopDeskScrollDrain {
        resampler: SlopDeskScrollResampler::of(&inner),
        event: drained.map_or(EMPTY_EVENT, SlopDeskScrollSubEvent::of),
        emitted: drained.is_some(),
    }
}

/// Whether there is no whole pixel left to drain, so the caller can suspend its timer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_resampler_is_idle(resampler: SlopDeskScrollResampler) -> bool {
    resampler.inner().is_idle()
}

/// Drops the residual and the phase state, for a pane losing focus or a session tearing down.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_resampler_reset(
    resampler: SlopDeskScrollResampler,
) -> SlopDeskScrollResampler {
    let mut inner = resampler.inner();
    inner.reset();
    SlopDeskScrollResampler::of(&inner)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact whole pixels the law truncated to"
    )]

    use super::{
        slopdesk_scroll_resampler_defaults, slopdesk_scroll_resampler_drain,
        slopdesk_scroll_resampler_ingest, slopdesk_scroll_resampler_is_idle, slopdesk_scroll_resampler_new,
        slopdesk_scroll_resampler_reset,
    };

    /// A resampler on the law's own knobs.
    fn fresh() -> super::SlopDeskScrollResampler {
        let defaults = slopdesk_scroll_resampler_defaults();
        slopdesk_scroll_resampler_new(defaults.spread, defaults.lag_cap)
    }

    #[test]
    fn a_continuous_sample_answers_with_nothing_and_drains_later() {
        let ingest = slopdesk_scroll_resampler_ingest(fresh(), 0.0, 10.0, 2, 0, true);
        assert_eq!(ingest.count, 0, "the continuous portion is what gets resampled");
        assert_eq!(ingest.resampler.residual_y, 10.0);
        assert!(!slopdesk_scroll_resampler_is_idle(ingest.resampler));

        let drain = slopdesk_scroll_resampler_drain(ingest.resampler);
        assert!(drain.emitted);
        assert_eq!(drain.event.dy, 5.0, "about half the residual per tick");
        assert_eq!(drain.event.scroll_phase, 2, "a finger-driven continuation");
        assert_eq!(drain.event.momentum_phase, 0);
        assert!(drain.event.continuous);
    }

    #[test]
    fn an_ending_marker_flushes_the_residual_in_front_of_itself() {
        let ingest = slopdesk_scroll_resampler_ingest(fresh(), 0.0, 7.5, 2, 0, true);
        let ended = slopdesk_scroll_resampler_ingest(ingest.resampler, 0.0, 0.0, 4, 0, true);
        assert_eq!(ended.count, 2, "the flush comes first, then the marker");
        assert_eq!(
            ended.events[0].dy, 7.0,
            "whole pixels only — there is no later tick"
        );
        assert_eq!(ended.events[0].scroll_phase, 2);
        assert_eq!(ended.events[1].scroll_phase, 4);
        assert!(
            slopdesk_scroll_resampler_is_idle(ended.resampler),
            "and nothing can drain after the end"
        );
    }

    #[test]
    fn a_momentum_coast_stamps_its_continuations_with_momentum() {
        let began = slopdesk_scroll_resampler_ingest(fresh(), 0.0, 0.0, 0, 1, true);
        assert_eq!(began.count, 1, "a marker passes through on its own");
        assert!(began.resampler.coasting);
        let coast = slopdesk_scroll_resampler_ingest(began.resampler, 0.0, 20.0, 0, 2, true);
        assert_eq!(coast.count, 0);
        let drain = slopdesk_scroll_resampler_drain(coast.resampler);
        assert_eq!(drain.event.scroll_phase, 0);
        assert_eq!(drain.event.momentum_phase, 2, "a coast, not a finger");
    }

    #[test]
    fn a_hostile_knob_or_a_bad_sample_cannot_poison_the_residual() {
        let defaults = slopdesk_scroll_resampler_defaults();
        let state = slopdesk_scroll_resampler_new(f64::NAN, 0.5);
        assert_eq!(state.spread, defaults.spread, "a non-finite knob falls back");
        assert_eq!(state.lag_cap, defaults.lag_cap, "and so does one under a pixel");

        let poisoned = slopdesk_scroll_resampler_ingest(state, f64::INFINITY, f64::NAN, 2, 0, true);
        assert_eq!(poisoned.resampler.residual_x, 0.0);
        assert_eq!(poisoned.resampler.residual_y, 0.0);

        let live = slopdesk_scroll_resampler_ingest(state, 0.0, 30.0, 2, 0, true).resampler;
        let dropped = slopdesk_scroll_resampler_reset(live);
        assert!(slopdesk_scroll_resampler_is_idle(dropped));
        assert!(!slopdesk_scroll_resampler_drain(dropped).emitted);
    }
}
