//! The paced-send lane's schedule — `Sources/SlopDeskVideoHost/VideoSendLane.swift`.
//!
//! The lane's job splits in two, and only one half crosses. The SLEEPS and the abort generation are
//! Swift structured concurrency, and stay there; what decides — the chunk boundaries, their
//! ABSOLUTE deadlines, and whether a job may skip the lane entirely — is answered here.
//!
//! The datagrams never cross. A plan names the caller's own array by index, the way the motion
//! coalescer's does, so a frame's hundreds of kilobytes stay where they were packetized.
//!
//! One duplicated rule is what motivated this: the session tested `gap == 0 || count <= chunk` to
//! pick the inline path, and the lane tested the same thing again to send in one shot. The comment
//! at the first said it "mirrors the lane's own one-shot test", which is the drift risk stated as a
//! promise. There is one test now, and both callers ask it.

use slopdesk_video::send_pacing::{PacedChunk, SendJob, may_send_inline, pace_plan};

/// One frame's pacing parameters, as its owner computes them.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSendJob {
    /// The inter-chunk gap in nanoseconds. Zero means single-shot, whatever the size.
    pub gap_nanos: u64,
    /// A wait BEFORE anything is sent, which time-separates a keyframe's duplicate copy.
    pub leading_delay_nanos: u64,
    /// How many datagrams the frame packetized into.
    pub outgoing_count: usize,
    /// The chunk size in datagrams, floored at one so a zero can never stall the drain.
    pub chunk_fragments: usize,
}

/// One chunk of a paced job, naming the caller's datagrams by index.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskPacedChunk {
    /// When the chunk is due, in nanoseconds from the job's start — which is AFTER the leading
    /// delay, so the delay is never paid twice.
    pub due_nanos: u64,
    /// Index of the first datagram in the chunk.
    pub start: usize,
    /// Index one past the last datagram in the chunk.
    pub end: usize,
}

/// The job as the law holds it.
const fn job_of(job: SlopDeskSendJob) -> SendJob {
    SendJob::new(
        job.outgoing_count,
        job.gap_nanos,
        job.chunk_fragments,
        job.leading_delay_nanos,
    )
}

/// One chunk as it crosses.
const fn crossing(chunk: PacedChunk) -> SlopDeskPacedChunk {
    SlopDeskPacedChunk {
        due_nanos: chunk.due_nanos,
        start: chunk.start,
        end: chunk.end,
    }
}

/// Writes the job's schedule in wire order and answers how many chunks it has.
///
/// A null `out`, or one too small, writes nothing and still reports the count, so a caller measures
/// with one call and fills with the next. A gapless or single-chunk job is ONE chunk due
/// immediately — the single-shot path — and an empty job is no chunks at all.
///
/// # Safety
/// `out` must be null or point to `cap` writable [`SlopDeskPacedChunk`] slots for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_send_pace_plan(
    job: SlopDeskSendJob,
    out: *mut SlopDeskPacedChunk,
    cap: usize,
) -> usize {
    let plan = pace_plan(job_of(job));
    if out.is_null() || cap < plan.len() {
        return plan.len();
    }
    for (index, chunk) in plan.iter().enumerate() {
        // SAFETY: `index` is under `plan.len()`, which the guard above proved is within `cap`
        // writable slots by the caller's obligation.
        unsafe { out.add(index).write(crossing(*chunk)) };
    }
    plan.len()
}

/// Whether a job may skip the lane and go out on the caller's own thread.
///
/// `queued` and `transmitting` are the lane's own state, read together under its lock: a job that
/// is queued or mid-pace means sending now would let a keystroke overtake an earlier frame. A paced
/// or duplicated job always goes through the lane — it NEEDS the sleeps. What stays with the caller
/// is the policy half (a keyframe, or a delta that will be duplicated, keeps the lane whatever this
/// says), because those enqueue a SECOND copy that must stay ordered behind the first.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_send_may_inline(
    job: SlopDeskSendJob,
    closed: bool,
    queued: usize,
    transmitting: bool,
) -> bool {
    may_send_inline(job_of(job), closed, queued, transmitting)
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the doors as the near side does IS what these tests pin"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "an out-of-range index in a test is the failure report, not a runtime fault"
    )]

    use core::ptr;

    use super::{
        SlopDeskPacedChunk, SlopDeskSendJob, job_of, slopdesk_send_may_inline, slopdesk_send_pace_plan,
    };

    /// 0.7 ms — the gap the timer-quantum argument is about.
    const GAP: u64 = 700_000;

    /// A job of `count` datagrams paced in chunks of four.
    const fn job(count: usize, gap: u64) -> SlopDeskSendJob {
        SlopDeskSendJob {
            gap_nanos: gap,
            leading_delay_nanos: 0,
            outgoing_count: count,
            chunk_fragments: 4,
        }
    }

    /// The plan, measured and then filled exactly as the near side does it.
    fn planned(job: SlopDeskSendJob) -> Vec<SlopDeskPacedChunk> {
        let needed = unsafe { slopdesk_send_pace_plan(job, ptr::null_mut(), 0) };
        let mut room = vec![SlopDeskPacedChunk::default(); needed];
        let written = unsafe { slopdesk_send_pace_plan(job, room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed, "the measure and the fill agree");
        room
    }

    #[test]
    fn a_single_shot_job_is_one_chunk_due_at_once() {
        let plan = planned(job(3, GAP));
        assert_eq!(plan.len(), 1);
        assert_eq!((plan[0].start, plan[0].end, plan[0].due_nanos), (0, 3, 0));
        assert_eq!(
            planned(job(40, 0)).len(),
            1,
            "a gapless job too, whatever its size"
        );
        assert!(planned(job(0, GAP)).is_empty(), "and an empty job is no chunks");
    }

    #[test]
    fn every_later_chunk_carries_an_absolute_deadline() {
        let plan = planned(job(10, GAP));
        assert_eq!(plan.len(), 3);
        assert_eq!((plan[0].start, plan[0].end, plan[0].due_nanos), (0, 4, 0));
        assert_eq!((plan[1].start, plan[1].end, plan[1].due_nanos), (4, 8, GAP));
        assert_eq!(
            (plan[2].start, plan[2].end, plan[2].due_nanos),
            (8, 10, GAP * 2),
            "an oversleep eats the next gap rather than pushing the schedule right"
        );
    }

    #[test]
    fn a_short_lend_writes_nothing_and_still_reports_the_count() {
        let mut room = [SlopDeskPacedChunk::default(); 1];
        let needed = unsafe { slopdesk_send_pace_plan(job(10, GAP), room.as_mut_ptr(), room.len()) };
        assert_eq!(needed, 3);
        assert_eq!(
            room[0].end, 0,
            "nothing was written into a buffer that could not hold it"
        );
    }

    #[test]
    fn the_span_counts_the_leading_delay_once() {
        let mut delayed = job(10, GAP);
        delayed.leading_delay_nanos = 5_000_000;
        assert_eq!(
            slopdesk_video::send_pacing::total_span_nanos(job_of(delayed)),
            5_000_000 + GAP * 2,
        );
    }

    #[test]
    fn only_a_drained_lane_and_a_single_shot_job_may_skip_the_hop() {
        let tiny = job(3, GAP);
        assert!(slopdesk_send_may_inline(tiny, false, 0, false));
        assert!(
            !slopdesk_send_may_inline(tiny, false, 1, false),
            "something is queued"
        );
        assert!(
            !slopdesk_send_may_inline(tiny, false, 0, true),
            "a consumer is mid-drain"
        );
        assert!(
            !slopdesk_send_may_inline(tiny, true, 0, false),
            "the lane is closed"
        );
        assert!(
            !slopdesk_send_may_inline(job(10, GAP), false, 0, false),
            "a paced job needs the sleeps"
        );
        let mut delayed = tiny;
        delayed.leading_delay_nanos = 1;
        assert!(
            !slopdesk_send_may_inline(delayed, false, 0, false),
            "a duplicated copy needs its time separation"
        );
    }
}
