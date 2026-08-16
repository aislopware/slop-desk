//! The paced-send lane's schedule: which datagrams go out together, and when the next chunk is due.
//!
//! Pacing sleeps must not run inside the encoder-output pump. If they did, pacing frame N would
//! delay the SEND of frames N+1 onward: a large recovery keyframe paced at a post-backoff rate
//! serialises over hundreds of milliseconds, which on a real inter-ISP path measured as send gaps
//! of 28 to 179 ms — the worst of them eleven dropped frame slots, plainly visible as stutter. The
//! loss itself is path weather; what the host can control is not amplifying one lost packet into an
//! eleven-frame hole.
//!
//! So the lane runs its own drain, and what lives here is the part that decides rather than sleeps:
//! the chunk boundaries, their deadlines, and whether a job may skip the lane entirely.
//!
//! ## Absolute deadlines, not relative sleeps
//!
//! A per-gap relative sleep is at the mercy of the platform's timer quantum: a 0.7 ms gap request
//! comes back a 1 to 2 ms sleep, and with six or more gaps in a 50 KB frame the overshoot
//! ACCUMULATES into three or four extra milliseconds of serialisation per frame — and, worse, into
//! per-frame VARIANCE, which surfaces as present-cadence jitter at a client presenting on arrival.
//!
//! Chunk k is instead due at `k × gap` from the job's start on a continuous clock. An oversleep
//! eats into the NEXT gap rather than pushing the whole schedule right, and a chunk already past
//! its deadline sends at once. Total serialisation comes to the theoretical figure plus ONE
//! quantum, whatever the fragment count, and the average wire rate is unchanged.

/// One frame's pacing parameters, computed by the caller that owns the rate and the flags, so the
/// lane itself stays policy-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SendJob {
    /// How many datagrams the frame packetized into.
    pub outgoing_count: usize,
    /// The inter-chunk gap. Zero means single-shot, whatever the size.
    pub gap_nanos: u64,
    /// The chunk size in datagrams. A job no longer than one chunk sends in one shot.
    pub chunk_fragments: usize,
    /// A wait BEFORE anything is sent, which time-separates a keyframe's duplicate copy. Zero for
    /// an ordinary frame.
    pub leading_delay_nanos: u64,
}

impl SendJob {
    /// A job, with the chunk size floored at one datagram so a zero can never stall the drain.
    #[must_use]
    pub const fn new(
        outgoing_count: usize,
        gap_nanos: u64,
        chunk_fragments: usize,
        leading_delay_nanos: u64,
    ) -> Self {
        Self {
            outgoing_count,
            gap_nanos,
            chunk_fragments: if chunk_fragments > 1 { chunk_fragments } else { 1 },
            leading_delay_nanos,
        }
    }
}

/// One chunk of a paced job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacedChunk {
    /// Index of the first datagram in the chunk.
    pub start: usize,
    /// Index one past the last datagram in the chunk.
    pub end: usize,
    /// When the chunk is due, in nanoseconds from the job's start — which is AFTER the leading
    /// delay, so the delay is not paid twice.
    pub due_nanos: u64,
}

/// The whole schedule for one job, in wire order.
///
/// A gapless or single-chunk job comes back as one chunk due immediately, which is the single-shot
/// path. Every later chunk carries an absolute offset, so a caller that overslept catches up by
/// sending at once rather than by pushing the rest of the schedule right.
///
/// The abort check belongs BETWEEN chunks: a flush must drop a mid-pace job at its next boundary,
/// which is the lane's equivalent of re-reading whether media is still flowing.
#[must_use]
pub fn pace_plan(job: SendJob) -> Vec<PacedChunk> {
    if job.outgoing_count == 0 {
        return Vec::new();
    }
    if job.gap_nanos == 0 || job.outgoing_count <= job.chunk_fragments {
        return vec![PacedChunk {
            start: 0,
            end: job.outgoing_count,
            due_nanos: 0,
        }];
    }
    let mut plan = Vec::new();
    let mut start = 0;
    let mut chunk = 0_u64;
    while start < job.outgoing_count {
        let end = start.saturating_add(job.chunk_fragments).min(job.outgoing_count);
        plan.push(PacedChunk {
            start,
            end,
            due_nanos: job.gap_nanos.saturating_mul(chunk),
        });
        start = end;
        chunk += 1;
    }
    plan
}

/// The lane's total serialisation for a job, in nanoseconds — the last chunk's deadline plus any
/// leading delay. What a caller uses to reason about a frame's wire span, not to sleep on.
#[must_use]
pub fn total_span_nanos(job: SendJob) -> u64 {
    let last = pace_plan(job).last().map_or(0, |chunk| chunk.due_nanos);
    job.leading_delay_nanos.saturating_add(last)
}

/// Whether a job may skip the lane and go out on the caller's own thread.
///
/// The lane exists to keep pacing sleeps off the encoder pump. A tiny single-shot delta — the
/// keystroke frame of an otherwise idle screen — has no sleeps to keep off anything, yet it still
/// pays a task hop to reach the consumer. When the wire is already drained, sending it here saves
/// that hop.
///
/// Drained means nothing queued AND no consumer mid-drain, read together: a job that is queued or
/// mid-pace means sending now would let the keystroke overtake an earlier frame, so it goes through
/// the lane instead. A paced or duplicated job always goes through the lane — it NEEDS the sleeps.
#[must_use]
pub const fn may_send_inline(job: SendJob, closed: bool, queued: usize, transmitting: bool) -> bool {
    !closed
        && queued == 0
        && !transmitting
        && job.leading_delay_nanos == 0
        && (job.gap_nanos == 0 || job.outgoing_count <= job.chunk_fragments)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "an out-of-range index in a test is the failure report, not a runtime fault"
    )]

    use super::{PacedChunk, SendJob, may_send_inline, pace_plan, total_span_nanos};

    const GAP: u64 = 700_000; // 0.7 ms, the gap the quantum argument is about

    #[test]
    fn a_gapless_job_goes_out_in_one_shot() {
        let plan = pace_plan(SendJob::new(40, 0, 4, 0));
        assert_eq!(plan, vec![PacedChunk {
            start: 0,
            end: 40,
            due_nanos: 0
        }],);
    }

    #[test]
    fn a_job_no_longer_than_one_chunk_never_waits() {
        let plan = pace_plan(SendJob::new(4, GAP, 4, 0));
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].due_nanos, 0);
    }

    /// The whole point: deadline k is k gaps from the START, never from the previous send.
    #[test]
    fn every_chunk_is_due_at_an_absolute_offset_from_the_jobs_start() {
        let plan = pace_plan(SendJob::new(10, GAP, 4, 0));
        assert_eq!(plan, vec![
            PacedChunk {
                start: 0,
                end: 4,
                due_nanos: 0
            },
            PacedChunk {
                start: 4,
                end: 8,
                due_nanos: GAP
            },
            PacedChunk {
                start: 8,
                end: 10,
                due_nanos: GAP * 2
            },
        ],);
    }

    /// Six gaps of accumulated quantum overshoot is what the absolute schedule exists to avoid.
    #[test]
    fn a_fat_keyframes_serialisation_is_the_theoretical_figure_and_no_more() {
        let job = SendJob::new(28, GAP, 4, 0);
        let plan = pace_plan(job);
        assert_eq!(plan.len(), 7);
        assert_eq!(plan[6].due_nanos, GAP * 6);
        assert_eq!(total_span_nanos(job), GAP * 6);
    }

    #[test]
    fn every_datagram_is_scheduled_exactly_once_and_in_wire_order() {
        let plan = pace_plan(SendJob::new(23, GAP, 5, 0));
        let mut next = 0;
        for chunk in &plan {
            assert_eq!(chunk.start, next, "no gap and no overlap");
            assert!(chunk.end > chunk.start);
            next = chunk.end;
        }
        assert_eq!(next, 23);
    }

    #[test]
    fn the_leading_delay_is_paid_once_and_before_the_schedule() {
        let job = SendJob::new(10, GAP, 4, 5_000_000);
        assert_eq!(
            pace_plan(job)[0].due_nanos,
            0,
            "the schedule starts after the delay, not on top of it",
        );
        assert_eq!(total_span_nanos(job), 5_000_000 + GAP * 2);
    }

    /// A zero chunk size would otherwise schedule nothing and stall the drain forever.
    #[test]
    fn a_degenerate_chunk_size_still_makes_progress() {
        let plan = pace_plan(SendJob::new(3, GAP, 0, 0));
        assert_eq!(plan.len(), 3);
        assert_eq!(plan[2].due_nanos, GAP * 2);
    }

    #[test]
    fn a_job_with_nothing_to_send_schedules_nothing() {
        assert!(pace_plan(SendJob::new(0, GAP, 4, 0)).is_empty());
        assert_eq!(total_span_nanos(SendJob::new(0, GAP, 4, 0)), 0);
    }

    #[test]
    fn an_idle_wire_sends_the_keystroke_frame_without_the_hop() {
        let keystroke = SendJob::new(1, GAP, 4, 0);
        assert!(may_send_inline(keystroke, false, 0, false));
    }

    /// A keystroke must never overtake an earlier frame that is still draining.
    #[test]
    fn anything_queued_or_mid_pace_sends_the_job_through_the_lane() {
        let keystroke = SendJob::new(1, GAP, 4, 0);
        assert!(!may_send_inline(keystroke, false, 1, false));
        assert!(!may_send_inline(keystroke, false, 0, true));
        assert!(!may_send_inline(keystroke, true, 0, false));
    }

    #[test]
    fn a_job_that_needs_sleeps_always_takes_the_lane() {
        assert!(
            !may_send_inline(SendJob::new(40, GAP, 4, 0), false, 0, false),
            "a paced job needs the gaps",
        );
        assert!(
            !may_send_inline(SendJob::new(1, 0, 4, 5_000_000), false, 0, false),
            "a duplicate copy needs its time separation",
        );
    }
}
