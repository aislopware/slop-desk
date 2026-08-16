//! Which decoded frame this refresh shows, and when.
//!
//! The presentation policy is a fold the caller copies out, folds into and writes back, so it
//! crosses BY VALUE — the same shape the decoder's admission takes, for the same reason. What is
//! big here is the queue of waiting frames, and the near side never reads it: it reads a handle to
//! present and a list of handles to let go of. Nothing in the law dereferences a handle; the images
//! stay exactly where the decoder left them.
//!
//! ## What the near side must honour
//!
//! One refresh answers with an outcome and a DROP LIST. The outcome says what to put on screen; the
//! list says which images the queue no longer refers to — the trim homeostasis performed to get to
//! the frame it chose. A queue of opaque handles owes its caller that list: a count would say how
//! many died and leave the caller inferring WHICH from an ordering it is deliberately not keeping.
//! The submission answers the same way for the hard cap's own eviction.
//!
//! ## Two depth doors, because there are two controllers
//!
//! `set_live_depth` carries the promote rule — a deeper buffer re-primes, or the slack frame it was
//! asked for never actually gets built. `adopt_live_depth` does not, and is the older
//! arrival-jitter controller's door: that one recommends a depth on every frame and every underrun,
//! and re-priming that often would hold the picture where the user can see it. The two controllers
//! are mutually exclusive upstream, so the two doors never both apply.

use core::ffi::c_char;

use slopdesk_video::present_queue::{
    MAX_QUEUE_DEPTH, MAX_TICK_HZ, MIN_TICK_HZ, PLAYOUT_HARD_CEILING_SECONDS, PLAYOUT_RECOMPUTE_EVERY,
    PresentOutcome, PresentQueue, PresentQueueSnapshot, QUEUE_CAPACITY, QueuedFrame,
    RENDER_CAP_SLACK_SECONDS, clamped_playout_seconds, deadline_due, deadline_for_arrival,
    playout_recompute_due, resolve_tick_rate, should_present_on_arrival, should_render,
};

use crate::{optional, optional_of};

/// Still filling the buffer: re-show `last_shown`, if there is one.
pub const SLOPDESK_PRESENT_PRIMING: u32 = 0;
/// Put `frame` on screen.
pub const SLOPDESK_PRESENT_PRESENT: u32 = 1;
/// The producer fell behind: re-show `last_shown`.
pub const SLOPDESK_PRESENT_RESHOW: u32 = 2;

// MARK: the values that cross

/// One frame waiting its turn: a handle the law never looks inside, and when it arrived.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskQueuedFrame {
    /// The caller's own handle for the image buffer.
    pub handle: u64,
    /// When it was submitted, in the caller's monotonic seconds.
    pub submitted_at: f64,
}

impl SlopDeskQueuedFrame {
    /// The crossing form of a queued frame.
    const fn of(frame: QueuedFrame) -> Self {
        Self {
            handle: frame.handle,
            submitted_at: frame.submitted_at,
        }
    }

    /// The wrapped frame this describes.
    const fn inner(self) -> QueuedFrame {
        QueuedFrame {
            handle: self.handle,
            submitted_at: self.submitted_at,
        }
    }
}

/// The empty slot a crossing's unused queue entries carry.
const EMPTY_SLOT: SlopDeskQueuedFrame = SlopDeskQueuedFrame {
    handle: 0,
    submitted_at: 0.0,
};

/// The queue-mode presentation state machine, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPresentQueue {
    /// The waiting frames, oldest first, the first `len` of them live.
    pub queue: [SlopDeskQueuedFrame; QUEUE_CAPACITY],
    /// How many queue slots are live.
    pub len: usize,
    /// The last handle handed out, which a hold or an underflow re-shows.
    pub last_shown: u64,
    /// The hard cap on buffered frames.
    pub max_depth: u32,
    /// The depth being served right now.
    pub live_depth: u32,
    /// Consecutive empty refreshes.
    pub underflow_run: u32,
    /// Whether anything has ever been handed out.
    pub has_last_shown: bool,
    /// Whether the buffer has filled and steady presentation has begun.
    pub primed: bool,
}

impl SlopDeskPresentQueue {
    /// The crossing form of a wrapped queue.
    fn of(queue: &PresentQueue) -> Self {
        let snapshot = queue.snapshot();
        let (has_last_shown, last_shown) = optional(snapshot.last_shown, 0);
        let mut crossing = Self {
            queue: [EMPTY_SLOT; QUEUE_CAPACITY],
            len: snapshot.len,
            last_shown,
            max_depth: snapshot.max_depth,
            live_depth: snapshot.live_depth,
            underflow_run: snapshot.underflow_run,
            has_last_shown,
            primed: snapshot.primed,
        };
        for (slot, frame) in crossing.queue.iter_mut().zip(snapshot.queue) {
            *slot = SlopDeskQueuedFrame::of(frame);
        }
        crossing
    }

    /// The wrapped queue this describes.
    fn inner(&self) -> PresentQueue {
        let mut snapshot = PresentQueueSnapshot {
            queue: [QueuedFrame {
                handle: 0,
                submitted_at: 0.0,
            }; QUEUE_CAPACITY],
            len: self.len.min(QUEUE_CAPACITY),
            last_shown: optional_of(self.has_last_shown, self.last_shown),
            max_depth: self.max_depth,
            live_depth: self.live_depth,
            underflow_run: self.underflow_run,
            primed: self.primed,
        };
        for (slot, frame) in snapshot.queue.iter_mut().zip(self.queue) {
            *slot = frame.inner();
        }
        PresentQueue::restored(&snapshot)
    }
}

/// One submission: the queue that results, and what the hard cap had to evict for it.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPresentSubmit {
    /// The queue after the frame landed.
    pub queue: SlopDeskPresentQueue,
    /// The handle the hard cap evicted, live only when `has_evicted`.
    pub evicted: u64,
    /// Whether the queue was empty before this frame landed — what the present-on-arrival gate
    /// reads, and the one thing it cannot recover afterwards.
    pub was_empty: bool,
    /// Whether the cap evicted anything.
    pub has_evicted: bool,
}

/// One refresh: the queue that results, what to show, and what to let go of.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPresentStep {
    /// The queue after the refresh.
    pub queue: SlopDeskPresentQueue,
    /// The frame to show. Live only when `kind` is `SLOPDESK_PRESENT_PRESENT`.
    pub frame: SlopDeskQueuedFrame,
    /// The handles this refresh made obsolete, oldest first, the first `dropped_len` live.
    pub dropped: [u64; QUEUE_CAPACITY],
    /// How many dropped slots are live.
    pub dropped_len: usize,
    /// The handle to re-show. Live only when `has_last_shown` and `kind` is not a present.
    pub last_shown: u64,
    /// One of the `SLOPDESK_PRESENT_*` codes.
    pub kind: u32,
    /// Whether anything has ever been handed out.
    pub has_last_shown: bool,
    /// A present that follows at least one empty refresh WHILE STILL PRIMED — a real, transient
    /// starvation, and the caller's cue to grow the buffer. Deliberately false after an idle
    /// re-prime, so the host going quiet never inflates anything.
    pub transient_dip: bool,
    /// Whether this refresh dropped back to priming, which is also the caller's cue to reset its
    /// jitter estimator — otherwise the idle gap becomes one enormous inter-arrival.
    pub re_primed: bool,
}

impl SlopDeskPresentStep {
    /// The crossing form of one refresh.
    fn of(queue: &PresentQueue, step: slopdesk_video::present_queue::PresentStep) -> Self {
        let mut crossing = Self {
            queue: SlopDeskPresentQueue::of(queue),
            frame: EMPTY_SLOT,
            dropped: [0; QUEUE_CAPACITY],
            dropped_len: 0,
            last_shown: 0,
            kind: SLOPDESK_PRESENT_PRIMING,
            has_last_shown: false,
            transient_dip: false,
            re_primed: false,
        };
        for (slot, &handle) in crossing.dropped.iter_mut().zip(step.dropped.slice()) {
            *slot = handle;
            crossing.dropped_len += 1;
        }
        match step.outcome {
            PresentOutcome::Priming { last_shown } => {
                (crossing.has_last_shown, crossing.last_shown) = optional(last_shown, 0);
            },
            PresentOutcome::Present { frame, transient_dip } => {
                crossing.kind = SLOPDESK_PRESENT_PRESENT;
                crossing.frame = SlopDeskQueuedFrame::of(frame);
                crossing.transient_dip = transient_dip;
                crossing.has_last_shown = true;
                crossing.last_shown = frame.handle;
            },
            PresentOutcome::Reshow {
                last_shown,
                re_primed,
            } => {
                crossing.kind = SLOPDESK_PRESENT_RESHOW;
                crossing.re_primed = re_primed;
                (crossing.has_last_shown, crossing.last_shown) = optional(last_shown, 0);
            },
        }
        crossing
    }
}

/// The law's fixed numbers, so the near side spells none of them.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPresentConstants {
    /// The backstop ceiling on the playout delay, in seconds.
    pub playout_hard_ceiling_seconds: f64,
    /// The slack the frame-rate cap allows, in seconds.
    pub render_cap_slack_seconds: f64,
    /// The lowest tick rate the override accepts.
    pub min_tick_hz: f64,
    /// The highest tick rate the override accepts.
    pub max_tick_hz: f64,
    /// How many frames one crossing of the queue carries.
    pub queue_capacity: usize,
    /// The deepest queue any configuration may ask for.
    pub max_queue_depth: u32,
    /// How many jitter samples pass between playout recomputations.
    pub playout_recompute_every: u32,
}

/// Whether the playout cadence gate opens, and the sample count that follows.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskPlayoutRecompute {
    /// The count to carry into the next arrival.
    pub next_samples: u32,
    /// Whether the delay should be recomputed now.
    pub due: bool,
}

// MARK: the queue

/// The law's fixed numbers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_present_constants() -> SlopDeskPresentConstants {
    SlopDeskPresentConstants {
        playout_hard_ceiling_seconds: PLAYOUT_HARD_CEILING_SECONDS,
        render_cap_slack_seconds: RENDER_CAP_SLACK_SECONDS,
        min_tick_hz: MIN_TICK_HZ,
        max_tick_hz: MAX_TICK_HZ,
        queue_capacity: QUEUE_CAPACITY,
        max_queue_depth: MAX_QUEUE_DEPTH,
        playout_recompute_every: PLAYOUT_RECOMPUTE_EVERY,
    }
}

/// An empty queue at the given live depth, under a hard cap bounded by the law's own band.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_new(live_depth: u32, max_depth: u32) -> SlopDeskPresentQueue {
    SlopDeskPresentQueue::of(&PresentQueue::new(live_depth, max_depth))
}

/// Adopts a depth from the depth controller: a PROMOTE re-primes, so the slack it asked for is
/// actually built. A DEMOTE needs nothing — homeostasis trims the extra frame on the next refresh.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_set_live_depth(
    queue: &SlopDeskPresentQueue,
    depth: u32,
) -> SlopDeskPresentQueue {
    let mut inner = queue.inner();
    inner.set_live_depth(depth);
    SlopDeskPresentQueue::of(&inner)
}

/// Adopts a depth from the arrival-jitter controller: bounded, but never re-priming. See the
/// module header for why there are two of these.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_adopt_live_depth(
    queue: &SlopDeskPresentQueue,
    depth: u32,
) -> SlopDeskPresentQueue {
    let mut inner = queue.inner();
    inner.adopt_live_depth(depth);
    SlopDeskPresentQueue::of(&inner)
}

/// Enqueues a decoded frame, trimming to the hard cap.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_submit(
    queue: &SlopDeskPresentQueue,
    handle: u64,
    submitted_at: f64,
) -> SlopDeskPresentSubmit {
    let mut inner = queue.inner();
    let submission = inner.submit(QueuedFrame { handle, submitted_at });
    let (has_evicted, evicted) = optional(submission.evicted, 0);
    SlopDeskPresentSubmit {
        queue: SlopDeskPresentQueue::of(&inner),
        evicted,
        was_empty: submission.was_empty,
        has_evicted,
    }
}

/// One refresh.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_step(queue: &SlopDeskPresentQueue) -> SlopDeskPresentStep {
    let mut inner = queue.inner();
    let step = inner.step();
    SlopDeskPresentStep::of(&inner, step)
}

/// Whether two queues are the same state. A C array is a tuple on the near side, and a tuple that
/// long has no equality of its own.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_queue_eq(
    left: &SlopDeskPresentQueue,
    right: &SlopDeskPresentQueue,
) -> bool {
    left == right
}

// MARK: the schedule, pure

/// Bounds a stepped playout delay into the range the presentation path will accept.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_present_clamped_playout_seconds(next_seconds: f64) -> f64 {
    clamped_playout_seconds(next_seconds)
}

/// Whether the playout cadence gate opens on this sample.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_present_playout_recompute_due(
    samples_since_last: u32,
) -> SlopDeskPlayoutRecompute {
    let (due, next_samples) = playout_recompute_due(samples_since_last);
    SlopDeskPlayoutRecompute { next_samples, due }
}

/// When a newly arrived frame should be presented, in the deadline mode.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_deadline_for_arrival(
    arrival: f64,
    last_deadline: f64,
    interval: f64,
    playout_delay: f64,
) -> f64 {
    deadline_for_arrival(arrival, last_deadline, interval, playout_delay)
}

/// Whether a scheduled present is due at this tick.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_deadline_due(deadline: f64, now: f64, half_tick: f64) -> bool {
    deadline_due(deadline, now, half_tick)
}

/// Whether a render may run under the frame-rate cap.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_present_should_render(now: f64, last_render: f64, max_frame_rate: f64) -> bool {
    should_render(now, last_render, max_frame_rate)
}

/// Whether an arriving frame should be presented immediately rather than waiting for the next tick.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_present_should_present_on_arrival(
    enabled: bool,
    queue_was_empty: bool,
    queue_count: u32,
    live_depth: u32,
) -> bool {
    should_present_on_arrival(enabled, queue_was_empty, queue_count, live_depth)
}

/// The rate the display link should run at.
///
/// The override is borrowed UTF-8 rather than a value, because it is an environment variable: text
/// the far side parses and forgets. A null pointer, an empty span or bytes that are not a finite
/// number all mean "no override", which is one answer and not three.
///
/// # Safety
/// `env_override` must be null, or point to `env_override_len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_present_resolve_tick_rate(
    env_override: *const c_char,
    env_override_len: usize,
    display_max_hz: u32,
    floor: f64,
) -> f64 {
    let borrowed = if env_override.is_null() || env_override_len == 0 {
        None
    } else {
        // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
        let bytes = unsafe { core::slice::from_raw_parts(env_override.cast::<u8>(), env_override_len) };
        core::str::from_utf8(bytes).ok()
    };
    resolve_tick_rate(borrowed, display_max_hz, floor)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        unsafe_code,
        reason = "the schedule fixtures are exact sums of exact binary fractions, and the one pointer entry \
                  has to be called to be tested"
    )]

    use super::{
        SLOPDESK_PRESENT_PRESENT, SLOPDESK_PRESENT_PRIMING, SLOPDESK_PRESENT_RESHOW, SlopDeskPresentQueue,
        slopdesk_present_clamped_playout_seconds, slopdesk_present_constants, slopdesk_present_deadline_due,
        slopdesk_present_deadline_for_arrival, slopdesk_present_playout_recompute_due,
        slopdesk_present_queue_adopt_live_depth, slopdesk_present_queue_eq, slopdesk_present_queue_new,
        slopdesk_present_queue_set_live_depth, slopdesk_present_queue_step, slopdesk_present_queue_submit,
        slopdesk_present_resolve_tick_rate, slopdesk_present_should_present_on_arrival,
        slopdesk_present_should_render,
    };

    fn submit(queue: &SlopDeskPresentQueue, handle: u64) -> SlopDeskPresentQueue {
        slopdesk_present_queue_submit(queue, handle, f64::from(u32::try_from(handle).unwrap_or(0))).queue
    }

    #[test]
    fn a_queue_fills_then_serves_in_order_through_the_door() {
        let mut queue = slopdesk_present_queue_new(2, 6);
        assert_eq!(slopdesk_present_queue_step(&queue).kind, SLOPDESK_PRESENT_PRIMING);
        queue = submit(&queue, 1);
        queue = submit(&queue, 2);
        let step = slopdesk_present_queue_step(&queue);
        assert_eq!(step.kind, SLOPDESK_PRESENT_PRESENT);
        assert_eq!(step.frame.handle, 1);
        assert!(step.queue.primed);
    }

    #[test]
    fn the_step_names_every_handle_homeostasis_dropped() {
        let mut queue = slopdesk_present_queue_new(2, 6);
        for handle in 1..=6 {
            queue = submit(&queue, handle);
        }
        let step = slopdesk_present_queue_step(&queue);
        assert_eq!(step.frame.handle, 5);
        assert_eq!(step.dropped_len, 4);
        assert_eq!(&step.dropped[..4], &[1, 2, 3, 4]);
    }

    #[test]
    fn the_submission_names_the_handle_the_hard_cap_evicted() {
        let queue = slopdesk_present_queue_new(1, 2);
        let first = slopdesk_present_queue_submit(&queue, 1, 1.0);
        assert!(first.was_empty);
        assert!(!first.has_evicted);
        let second = slopdesk_present_queue_submit(&first.queue, 2, 2.0);
        let third = slopdesk_present_queue_submit(&second.queue, 3, 3.0);
        assert!(third.has_evicted);
        assert_eq!(third.evicted, 1, "or the caller holds that image forever");
    }

    #[test]
    fn a_present_carries_the_frontier_forward_so_a_reshow_has_something_to_show() {
        let mut queue = slopdesk_present_queue_new(1, 6);
        queue = submit(&queue, 7);
        let present = slopdesk_present_queue_step(&queue);
        assert!(present.has_last_shown);
        assert_eq!(present.last_shown, 7);
        let reshow = slopdesk_present_queue_step(&present.queue);
        assert_eq!(reshow.kind, SLOPDESK_PRESENT_RESHOW);
        assert_eq!(reshow.last_shown, 7);
        assert!(
            !reshow.re_primed,
            "one empty tick at the floor is a dip, not an idle"
        );
        let idle = slopdesk_present_queue_step(&reshow.queue);
        assert!(idle.re_primed);
    }

    #[test]
    fn the_transient_dip_survives_the_crossing_and_the_idle_resume_does_not_fake_one() {
        let mut queue = slopdesk_present_queue_new(1, 6);
        queue = submit(&queue, 1);
        queue = slopdesk_present_queue_step(&queue).queue;
        queue = slopdesk_present_queue_step(&queue).queue; // one empty tick: a real starvation
        queue = submit(&queue, 2);
        assert!(slopdesk_present_queue_step(&queue).transient_dip);
    }

    #[test]
    fn the_two_depth_doors_differ_on_exactly_one_thing() {
        let mut queue = slopdesk_present_queue_new(1, 6);
        queue = submit(&queue, 1);
        queue = slopdesk_present_queue_step(&queue).queue;
        assert!(queue.primed);
        assert!(
            !slopdesk_present_queue_set_live_depth(&queue, 2).primed,
            "the controller's promote re-primes so the slack is built",
        );
        assert!(
            slopdesk_present_queue_adopt_live_depth(&queue, 2).primed,
            "the jitter estimator's does not",
        );
    }

    #[test]
    fn the_depth_is_bounded_by_the_band_the_capacity_is_proved_against() {
        let constants = slopdesk_present_constants();
        let queue = slopdesk_present_queue_new(999, 999);
        assert_eq!(queue.live_depth, constants.max_queue_depth);
        assert_eq!(queue.max_depth, constants.max_queue_depth);
        assert_eq!(constants.queue_capacity, constants.max_queue_depth as usize);
    }

    #[test]
    fn a_queue_equals_itself_across_the_array_no_tuple_can_compare() {
        let left = submit(&slopdesk_present_queue_new(2, 6), 1);
        let right = submit(&slopdesk_present_queue_new(2, 6), 1);
        assert!(slopdesk_present_queue_eq(&left, &right));
        assert!(!slopdesk_present_queue_eq(&left, &submit(&left, 2)));
    }

    #[test]
    fn the_schedule_entries_answer_what_the_law_answers() {
        assert_eq!(
            slopdesk_present_deadline_for_arrival(10.0, 0.0, 0.016_25, 0.004),
            10.004
        );
        assert_eq!(
            slopdesk_present_deadline_for_arrival(10.019, 10.004, 0.016, 0.004),
            10.02
        );
        assert!(slopdesk_present_deadline_due(10.007, 10.0, 0.008));
        assert!(!slopdesk_present_deadline_due(10.009, 10.0, 0.008));
        assert!(slopdesk_present_should_render(1.0163, 1.0, 60.0));
        assert!(!slopdesk_present_should_render(1.005, 1.0, 60.0));
        assert!(slopdesk_present_should_present_on_arrival(true, true, 1, 1));
        assert!(!slopdesk_present_should_present_on_arrival(true, false, 3, 1));
        assert_eq!(slopdesk_present_clamped_playout_seconds(9.0), 0.2);
        assert_eq!(slopdesk_present_clamped_playout_seconds(-1.0), 0.0);
    }

    #[test]
    fn the_playout_cadence_counts_to_sixty_and_starts_over() {
        let mut samples = 0;
        for _ in 0..59 {
            let gate = slopdesk_present_playout_recompute_due(samples);
            assert!(!gate.due);
            samples = gate.next_samples;
        }
        let gate = slopdesk_present_playout_recompute_due(samples);
        assert!(gate.due);
        assert_eq!(gate.next_samples, 0);
    }

    #[test]
    fn the_tick_rate_takes_a_borrowed_override_and_a_null_means_none() {
        // SAFETY: a null pointer is the documented "no override" case.
        let none = unsafe { slopdesk_present_resolve_tick_rate(core::ptr::null(), 0, 120, 60.0) };
        assert_eq!(none, 120.0);
        let raw = c"10000";
        // SAFETY: the literal outlives the call.
        let clamped = unsafe { slopdesk_present_resolve_tick_rate(raw.as_ptr(), 5, 60, 60.0) };
        assert_eq!(clamped, 240.0);
        let nonsense = c"nan";
        // SAFETY: the literal outlives the call.
        let ignored = unsafe { slopdesk_present_resolve_tick_rate(nonsense.as_ptr(), 3, 120, 60.0) };
        assert_eq!(ignored, 120.0, "a bad override is no override");
    }
}
