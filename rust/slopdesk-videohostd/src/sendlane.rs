//! The paced send lane, and the retransmit log that answers a NACK from what it sent.
//!
//! Replaces the Swift host's video send lane and the retransmit ring beside it.
//!
//! ## What this module OWNS
//! Effects, ordering and lifetime: one consumer thread, one FIFO, the flush generation that aborts
//! a job mid-pace, and the sleeps. Nothing here decides anything — WHICH datagrams go out WHEN is
//! [`slopdesk_video::send_pacing`]'s answer, and WHICH of them survive in the send history is
//! [`slopdesk_video::retransmit_ring`]'s.
//!
//! ## Why the lane exists at all
//! The encoder pump must not sleep. A 50 KB frame is paced onto the wire in chunks so a burst
//! cannot hand the client's socket buffer more than it can drain, and every one of those gaps is a
//! sleep the encoder would otherwise pay for. So the pump enqueues and returns, and this thread
//! pays.
//!
//! ## Absolute deadlines, not relative sleeps
//! Chunk k is due at `start + k × gap` on the monotonic clock, never `sleep(gap)` per chunk.
//! Darwin's ~1 ms timer quantum turns a 0.7 ms gap request into a 1–2 ms actual sleep, and with
//! 6+ gaps per frame the overshoot ACCUMULATES to +3–4 ms of serialisation per frame — worse,
//! into per-frame variance that surfaces as present-cadence jitter at a depth-1, present-on-arrival
//! client. On the absolute schedule an oversleep eats into the NEXT gap instead of pushing the rest
//! of the schedule right, and a chunk already past due sends at once. Total serialisation is the
//! theoretical figure plus ONE quantum, whatever the fragment count.
//!
//! ## Threads and teardown
//! The Swift was an `actor` plus a `Task` the session cancelled. Here it is a real thread, and
//! [`VideoSendLane::close`] is a JOIN, not a cancel (`docs/60`): it sets the closed flag — that
//! flag IS the dropped sender, since after it no producer can enqueue — wakes the consumer, and
//! waits for the thread to leave. That stops a thread from reading state its owner already
//! freed; a cancel would return while a send was still in flight through a sink the session is
//! about to drop. [`Drop`] calls the same `close`, so a lane that is merely let go is torn down the
//! same way.
//!
//! The queue is a [`Mutex`] and a [`Condvar`] rather than a channel because three of the lane's
//! four operations are reads and edits of the queue itself, not sends: [`VideoSendLane::depth`] is
//! the backpressure signal, [`VideoSendLane::flush`] DROPS what is queued, and
//! [`VideoSendLane::try_send_inline`] must read "nothing queued AND nobody mid-drain" as one
//! observation. A channel can express none of the three.
//!
//! ## What is NOT here
//! The pacing rate. A [`Job`] arrives with its gap already computed by the caller that owns the
//! bitrate estimate and the frame's flags, so the lane stays policy-free — the same split the
//! Swift had, where `adaptivePaceGapNanos` lived in the session and never in the lane.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_video::recovery_routing::{Outgoing, VideoChannel};
use slopdesk_video::retransmit_ring::RetransmitRing;
use slopdesk_video::send_pacing::{SendJob, may_send_inline, pace_plan};

use crate::mux_lane::MuxLaneTransport;

/// Where a paced datagram goes.
///
/// A trait rather than the transport itself so the lane's ordering, its abort and its teardown can
/// be tested with no socket, no window server and no client — which is the only way any of it
/// gets tested at all, since everything else on this path needs a TCC grant.
pub trait DatagramSink: Send + Sync + core::fmt::Debug {
    /// Writes one finished datagram to a channel. Called from the lane's consumer thread, and from
    /// a producer's own thread on the inline path — never with the lane's lock held.
    fn send(&self, datagram: &[u8], channel: VideoChannel);
}

impl DatagramSink for MuxLaneTransport {
    fn send(&self, datagram: &[u8], channel: VideoChannel) {
        Self::send(self, datagram, channel);
    }
}

/// One frame's datagrams plus the schedule they go out on.
///
/// The datagrams are an [`Arc`] slice because a job is copied at least twice on the send path —
/// once for the retransmit log, once for the lane, and a keyframe a third time for its delayed
/// duplicate. Swift's arrays were copy-on-write, so that sharing was free and invisible; in Rust
/// it has to be named, and a `Vec` here would clone a 400 KB IDR on the encoder's thread.
#[derive(Debug, Clone)]
pub struct Job {
    outgoings: Arc<[Outgoing]>,
    spec: SendJob,
}

impl Job {
    /// Builds a job. `chunk_fragments` is floored at one datagram by
    /// [`SendJob::new`], so a zero can never stall the drain.
    ///
    /// The datagram COUNT is taken from the slice rather than passed, so the schedule can never be
    /// planned for a length the job does not have.
    #[must_use]
    pub fn new(
        outgoings: Arc<[Outgoing]>,
        gap_nanos: u64,
        chunk_fragments: usize,
        leading_delay_nanos: u64,
    ) -> Self {
        let spec = SendJob::new(outgoings.len(), gap_nanos, chunk_fragments, leading_delay_nanos);
        Self { outgoings, spec }
    }

    /// The same datagrams, on the same schedule, behind a leading wait.
    ///
    /// This is how a keyframe's second copy is time-separated from its first: the client dedupes on
    /// `(frame_id, frag_index)`, so the duplicate costs nothing but bandwidth and buys the loss of
    /// a whole IDR back. The bytes are SHARED with the original, not copied.
    #[must_use]
    pub fn delayed(&self, leading_delay_nanos: u64) -> Self {
        Self::new(
            Arc::clone(&self.outgoings),
            self.spec.gap_nanos,
            self.spec.chunk_fragments,
            leading_delay_nanos,
        )
    }

    /// The datagrams, in wire order.
    #[must_use]
    pub fn outgoings(&self) -> &[Outgoing] {
        &self.outgoings
    }

    /// The pacing parameters, as [`slopdesk_video::send_pacing`] wants to be asked them.
    #[must_use]
    pub const fn spec(&self) -> SendJob {
        self.spec
    }
}

/// Everything the consumer thread and its owner share.
#[derive(Debug)]
struct Shared {
    sink: Arc<dyn DatagramSink>,
    state: Mutex<State>,
    wake: Condvar,
}

/// The queue, and the two flags that are read WITH it.
#[derive(Debug)]
struct State {
    fifo: VecDeque<Job>,
    /// Bumped by every flush and by close. A mid-pace job compares it at each chunk boundary and
    /// abandons the rest of its schedule if it changed — the port of the Swift's `mediaFlowing`
    /// re-check, and the reason a dead client's frames are never paced onto the wire.
    generation: u64,
    closed: bool,
    /// True for the WHOLE span a consumer drains a job, so the inline path's drained test is one
    /// observation rather than a race against the moment between two chunks.
    transmitting: bool,
}

/// The paced send lane: a FIFO, one consumer thread, and the sink they both write to.
#[derive(Debug)]
pub struct VideoSendLane {
    shared: Arc<Shared>,
    /// Taken out on close, so a `Drop` after an explicit close joins nothing twice.
    consumer: Mutex<Option<JoinHandle<()>>>,
}

impl VideoSendLane {
    /// Starts a lane and its consumer thread.
    #[must_use]
    pub fn new(sink: Arc<dyn DatagramSink>) -> Self {
        let shared = Arc::new(Shared {
            sink,
            state: Mutex::new(State {
                fifo: VecDeque::new(),
                generation: 0,
                closed: false,
                transmitting: false,
            }),
            wake: Condvar::new(),
        });
        let worker = Arc::clone(&shared);
        let consumer = std::thread::spawn(move || {
            drain(&worker);
        });
        Self {
            shared,
            consumer: Mutex::new(Some(consumer)),
        }
    }

    /// Queued jobs not yet fully sent — the backpressure signal the capture side reads, and ≥1
    /// for as long as a job is mid-pace.
    #[must_use]
    pub fn depth(&self) -> usize {
        let state = self.shared.locked();
        let depth = state.fifo.len() + usize::from(state.transmitting);
        drop(state);
        depth
    }

    /// Appends a job and wakes the consumer. Never blocks, never sleeps, and does nothing at all
    /// once the lane is closed.
    pub fn enqueue(&self, job: Job) {
        let accepted = {
            let mut state = self.shared.locked();
            let open = !state.closed;
            if open {
                state.fifo.push_back(job);
            }
            open
        };
        if accepted {
            self.shared.wake.notify_all();
        }
    }

    /// Sends a job on the CALLER's thread if the wire is drained, answering whether it did. A
    /// `false` means the caller must [`enqueue`](Self::enqueue) instead.
    ///
    /// The lane exists to keep pacing sleeps off the encoder pump; a tiny single-shot delta — the
    /// keystroke frame of an otherwise idle screen — has no sleeps to keep off anything, yet it
    /// still pays a thread hop to reach the consumer. [`may_send_inline`] decides, and it refuses
    /// anything queued, anything mid-pace, and every paced or delayed job, so a keystroke can never
    /// overtake an earlier frame and a duplicate can never lose its separation.
    ///
    /// The verdict is read under the lock and the send happens outside it, which is safe for the
    /// one reason the Swift also relied on: producers are serialized by the caller, so the FIFO
    /// cannot grow between the two, and a consumer never sends while the FIFO is empty.
    #[must_use]
    pub fn try_send_inline(&self, job: &Job) -> bool {
        let may = {
            let state = self.shared.locked();
            may_send_inline(job.spec(), state.closed, state.fifo.len(), state.transmitting)
        };
        if !may {
            return false;
        }
        self.shared.write(job);
        true
    }

    /// Drops every queued job and aborts a mid-pace one at its next chunk boundary.
    ///
    /// Call on bye or media-stop. The wake-up is not the drop — it only lets a sleeping consumer
    /// notice the new generation at once rather than at the end of a gap that may be 40 ms long.
    pub fn flush(&self) {
        {
            let mut state = self.shared.locked();
            state.fifo.clear();
            state.generation = state.generation.wrapping_add(1);
        }
        self.shared.wake.notify_all();
    }

    /// Ends the lane permanently and joins its thread. Idempotent, and called by [`Drop`].
    ///
    /// The join is the point: when this returns, no thread is inside the sink, so the session may
    /// drop everything the sink borrows. The handle is taken out under its own lock and joined with
    /// NO lock held — joining under the state lock would deadlock against the consumer's next
    /// acquisition of it.
    pub fn close(&self) {
        {
            let mut state = self.shared.locked();
            state.closed = true;
            state.fifo.clear();
            state.generation = state.generation.wrapping_add(1);
        }
        self.shared.wake.notify_all();
        let consumer = self
            .consumer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(handle) = consumer {
            drop(handle.join());
        }
    }
}

impl Drop for VideoSendLane {
    fn drop(&mut self) {
        self.close();
    }
}

/// The consumer thread's whole life: drain until the lane closes.
fn drain(shared: &Shared) {
    while let Some((job, generation)) = shared.pop_next() {
        shared.transmit(&job, generation);
    }
}

impl Shared {
    /// The state, taken through the poison it cannot be hurt by: a panic in a sink leaves a queue
    /// and two flags, and the next close clears all three.
    fn locked(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Writes a whole job to the sink, in wire order and with no lock held.
    fn write(&self, job: &Job) {
        for outgoing in job.outgoings() {
            self.sink.send(&outgoing.bytes, outgoing.channel);
        }
    }

    /// Waits for the next job, answering it with the generation it must survive, or `None` once the
    /// lane is closed — which is how the consumer thread ends.
    fn pop_next(&self) -> Option<(Job, u64)> {
        let mut state = self.locked();
        loop {
            if state.closed {
                state.transmitting = false;
                return None;
            }
            if let Some(job) = state.fifo.pop_front() {
                state.transmitting = true;
                let generation = state.generation;
                drop(state);
                return Some((job, generation));
            }
            // Cleared BEFORE the wait, not after the job: this is the moment the wire is drained,
            // and it is what re-opens the inline path for the next keystroke frame.
            state.transmitting = false;
            state = self.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Sends one job on its absolute-deadline schedule, abandoning it at the next chunk boundary if
    /// the lane was flushed or closed meanwhile.
    fn transmit(&self, job: &Job, generation: u64) {
        if job.spec().leading_delay_nanos > 0 {
            let until = Instant::now() + Duration::from_nanos(job.spec().leading_delay_nanos);
            if !self.park_until(until, generation) {
                return;
            }
        }
        let plan = pace_plan(job.spec());
        // The clock starts AFTER the leading delay, so the delay is not paid twice — the plan's
        // own offsets are relative to this instant.
        let start = Instant::now();
        for (index, chunk) in plan.iter().enumerate() {
            for slot in chunk.start..chunk.end {
                if let Some(outgoing) = job.outgoings().get(slot) {
                    self.sink.send(&outgoing.bytes, outgoing.channel);
                }
            }
            let Some(next) = plan.get(index + 1) else {
                return;
            };
            if !self.park_until(start + Duration::from_nanos(next.due_nanos), generation) {
                return;
            }
        }
    }

    /// Sleeps until `deadline`, answering whether the job may go on.
    ///
    /// Interruptible by design: a flush or a close notifies, so teardown does not wait out a gap
    /// that can be 40 ms long. A deadline already past returns at once with no sleep, which is the
    /// catch-up the absolute schedule exists for.
    fn park_until(&self, deadline: Instant, generation: u64) -> bool {
        let mut state = self.locked();
        while !state.closed && state.generation == generation {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            if remaining.is_zero() {
                break;
            }
            let (parked, _elapsed) = self
                .wake
                .wait_timeout(state, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            state = parked;
        }
        let alive = !state.closed && state.generation == generation;
        drop(state);
        alive
    }
}

/// The bounded send history a NACK is answered from.
///
/// Replaces `RetransmitRing.swift`, which was a face over the same rules type reached through the
/// FFI — the arena the Swift interned bytes into was there to get them across the C boundary, and
/// it vanishes with the boundary.
///
/// Interior mutability, because the two callers are two different threads and nothing else
/// serializes them any more: [`record`](Self::record) runs on the encoder's thread as a frame goes
/// out, [`fragments`](Self::fragments) on the mux receive thread as a request comes back. The Swift
/// got that serialization from the session actor it lived in; the port has to own it.
#[derive(Debug)]
pub struct RetransmitLog {
    ring: Mutex<RetransmitRing>,
}

impl RetransmitLog {
    /// A log holding at most `max_frames` frames and `max_bytes` bytes, each floored at one by
    /// [`RetransmitRing::new`], evicting oldest-first when either ceiling is crossed.
    #[must_use]
    pub const fn new(max_frames: usize, max_bytes: usize) -> Self {
        Self {
            ring: Mutex::new(RetransmitRing::new(max_frames, max_bytes)),
        }
    }

    /// Records a frame's datagrams, before they are handed to the lane.
    ///
    /// The copy is made OUTSIDE the lock: a NACK arriving mid-record should wait on the ring's
    /// bookkeeping, never on a memcpy of an IDR.
    pub fn record(&self, frame_id: u32, outgoings: &[Outgoing]) {
        let datagrams: Vec<Vec<u8>> = outgoings.iter().map(|outgoing| outgoing.bytes.clone()).collect();
        self.locked().record(frame_id, datagrams);
    }

    /// Answers a recovery request with whichever of the asked-for fragments are still held.
    ///
    /// A frame that has aged out answers with nothing, and that is the whole error path: the client
    /// asked for what the host no longer has, and its own recovery ladder takes it from there.
    /// [`VideoChannel::Video`] is restored rather than stored — every retransmission rides the
    /// channel its original did, so keeping a copy of it per datagram would only be a way to get it
    /// wrong.
    #[must_use]
    pub fn fragments(&self, frame_id: u32, frag_indices: &[u16]) -> Vec<Outgoing> {
        let datagrams = self.locked().fragments(frame_id, frag_indices);
        datagrams
            .into_iter()
            .map(|bytes| {
                Outgoing {
                    channel: VideoChannel::Video,
                    bytes,
                }
            })
            .collect()
    }

    /// How many frames the log currently holds — the eviction ceilings, observed.
    #[must_use]
    pub fn frame_count(&self) -> usize {
        let ring = self.locked();
        let count = ring.frame_count();
        drop(ring);
        count
    }

    /// The ring, through the poison it cannot be hurt by: the worst a panicking recorder leaves is
    /// a frame the next request cannot find, which is indistinguishable from one that aged out.
    fn locked(&self) -> MutexGuard<'_, RetransmitRing> {
        self.ring.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::{Arc, Condvar, Mutex, PoisonError};
    use std::time::{Duration, Instant};

    use slopdesk_video::fragment::MAX_PAYLOAD_SIZE;
    use slopdesk_video::packetizer::PacketizeOptions;
    use slopdesk_video::recovery_routing::{Outgoing, VideoChannel};

    use super::{DatagramSink, Job, RetransmitLog, VideoSendLane};
    use crate::packetize::PacketizeLane;

    /// A sink that records what it was given, and can be held INSIDE a send until released —
    /// which is how the flush test parks a job mid-pace with no sleeping and no racing.
    #[derive(Debug, Default)]
    struct Recorder {
        sent: Mutex<Vec<u8>>,
        hold: Mutex<Hold>,
        moved: Condvar,
    }

    #[derive(Debug, Default)]
    struct Hold {
        holding: bool,
        parked: bool,
    }

    impl Recorder {
        fn sent(&self) -> Vec<u8> {
            self.sent.lock().expect("an unpoisoned test recorder").clone()
        }

        fn arm_hold(&self) {
            self.hold.lock().expect("an unpoisoned test hold").holding = true;
        }

        fn release(&self) {
            let mut hold = self.hold.lock().expect("an unpoisoned test hold");
            hold.holding = false;
            drop(hold);
            self.moved.notify_all();
        }

        fn parked(&self) -> bool {
            self.hold.lock().expect("an unpoisoned test hold").parked
        }
    }

    impl DatagramSink for Recorder {
        fn send(&self, datagram: &[u8], channel: VideoChannel) {
            assert_eq!(channel, VideoChannel::Video, "the lane must not retag bytes");
            {
                let mut sent = self.sent.lock().unwrap_or_else(PoisonError::into_inner);
                sent.extend_from_slice(datagram);
            }
            let mut hold = self.hold.lock().unwrap_or_else(PoisonError::into_inner);
            while hold.holding {
                hold.parked = true;
                hold = self.moved.wait(hold).unwrap_or_else(PoisonError::into_inner);
            }
            hold.parked = false;
        }
    }

    /// Polls `done` for up to `window`, so a passing test costs one poll rather than the window.
    fn until(window: Duration, mut done: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + window;
        loop {
            if done() {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// A positive expectation about another thread: generous, because the machine may be loaded.
    fn settle(done: impl FnMut() -> bool) -> bool {
        until(Duration::from_secs(2), done)
    }

    /// A negative expectation: bounded, because "never" can only ever be sampled.
    fn never(done: impl FnMut() -> bool) -> bool {
        !until(Duration::from_millis(300), done)
    }

    /// `count` one-byte datagrams, each carrying its own index, so wire ORDER is readable straight
    /// off the recorder.
    fn marked(first: u8, count: u8) -> Arc<[Outgoing]> {
        (first..first.saturating_add(count))
            .map(|mark| {
                Outgoing {
                    channel: VideoChannel::Video,
                    bytes: vec![mark],
                }
            })
            .collect()
    }

    /// A lane over a recorder, written out because `Arc<Recorder>` reaches `Arc<dyn DatagramSink>`
    /// by coercion, never by a cast.
    fn lane_over(recorder: &Arc<Recorder>) -> VideoSendLane {
        let sink: Arc<dyn DatagramSink> = recorder.clone();
        VideoSendLane::new(sink)
    }

    #[test]
    fn a_drained_lane_sends_a_single_shot_job_on_the_callers_thread() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        let job = Job::new(marked(1, 3), 0, 8, 0);

        assert!(
            lane.try_send_inline(&job),
            "a gapless job on a drained lane skips the thread hop"
        );
        assert_eq!(
            recorder.sent(),
            vec![1, 2, 3],
            "and it is already on the wire when the call returns"
        );
        assert_eq!(lane.depth(), 0);
    }

    #[test]
    fn a_paced_job_is_refused_the_inline_path_and_keeps_its_order_through_the_lane() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        let job = Job::new(marked(1, 9), 200_000, 3, 0);

        assert!(
            !lane.try_send_inline(&job),
            "a job with gaps needs the sleeps the lane exists to pay"
        );
        lane.enqueue(job);
        assert!(settle(|| recorder.sent().len() == 9));
        assert_eq!(
            recorder.sent(),
            (1..=9).collect::<Vec<u8>>(),
            "chunking must not reorder a frame"
        );
    }

    #[test]
    fn a_keystroke_may_not_overtake_a_job_that_is_still_queued() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        recorder.arm_hold();
        lane.enqueue(Job::new(marked(1, 4), 5_000_000, 1, 0));
        assert!(settle(|| recorder.parked()));

        assert!(
            !lane.try_send_inline(&Job::new(marked(90, 1), 0, 8, 0)),
            "the wire is not drained, so the inline path must refuse"
        );
        recorder.release();
        lane.close();
        assert!(
            !recorder.sent().contains(&90),
            "and the refused job must not have reached the wire behind the lane's back"
        );
    }

    #[test]
    fn the_depth_counts_the_job_in_flight_as_well_as_the_queued_ones() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        recorder.arm_hold();
        lane.enqueue(Job::new(marked(1, 4), 5_000_000, 1, 0));
        assert!(settle(|| recorder.parked()));
        lane.enqueue(Job::new(marked(10, 4), 5_000_000, 1, 0));

        assert_eq!(
            lane.depth(),
            2,
            "one mid-pace plus one queued — the backpressure signal is ≥1 while anything drains"
        );
        recorder.release();
        lane.close();
    }

    #[test]
    fn a_flush_abandons_a_mid_pace_job_at_its_next_chunk_boundary() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        recorder.arm_hold();
        // Six datagrams, one per chunk: the consumer parks inside the FIRST send, so the flush
        // lands with five chunks still ahead and no timing to race.
        lane.enqueue(Job::new(marked(1, 6), 5_000_000, 1, 0));
        assert!(settle(|| recorder.parked()));

        lane.flush();
        recorder.release();
        assert!(
            never(|| recorder.sent().len() > 1),
            "a flushed job may finish the chunk it is in and nothing after it"
        );
    }

    #[test]
    fn a_flush_does_not_end_the_lane() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        lane.flush();
        lane.enqueue(Job::new(marked(7, 2), 0, 8, 0));
        assert!(settle(|| recorder.sent() == vec![7, 8]));
    }

    #[test]
    fn a_delayed_copy_pays_its_leading_wait_before_the_first_datagram() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        let delay_nanos: u64 = 40_000_000;
        let start = Instant::now();
        lane.enqueue(Job::new(marked(1, 2), 0, 8, 0).delayed(delay_nanos));

        assert!(settle(|| !recorder.sent().is_empty()));
        assert!(
            start.elapsed() >= Duration::from_nanos(delay_nanos),
            "the duplicate's whole value is that it is separated in TIME from the original"
        );
        assert_eq!(
            recorder.sent(),
            vec![1, 2],
            "the delay is paid once, not per datagram"
        );
    }

    #[test]
    fn close_is_idempotent_and_an_enqueue_after_it_is_a_no_op() {
        let recorder = Arc::new(Recorder::default());
        let lane = lane_over(&recorder);
        lane.close();
        lane.close();

        lane.enqueue(Job::new(marked(1, 3), 0, 8, 0));
        assert!(
            !lane.try_send_inline(&Job::new(marked(4, 1), 0, 8, 0)),
            "a closed lane admits nothing by either door"
        );
        assert!(
            never(|| !recorder.sent().is_empty()),
            "nothing reaches a sink whose lane was joined"
        );
        assert_eq!(lane.depth(), 0);
    }

    #[test]
    fn a_job_shares_its_datagrams_with_its_delayed_copy() {
        let outgoings = marked(1, 3);
        let job = Job::new(Arc::clone(&outgoings), 300, 2, 0);
        let dup = job.delayed(9_000);

        assert!(
            Arc::ptr_eq(&job.outgoings, &dup.outgoings),
            "the duplicate must SHARE the datagrams, not copy a 400 KB keyframe"
        );
        assert_eq!(
            dup.spec().leading_delay_nanos,
            9_000,
            "and the delay is the only thing it changes"
        );
        assert_eq!(job.spec().leading_delay_nanos, 0);
        assert_eq!(dup.spec().gap_nanos, 300);
        assert_eq!(dup.spec().chunk_fragments, 2);
        assert_eq!(dup.spec().outgoing_count, 3);
    }

    #[test]
    fn a_zero_chunk_size_is_floored_rather_than_stalling_the_drain() {
        let job = Job::new(marked(1, 4), 1_000, 0, 0);
        assert_eq!(job.spec().chunk_fragments, 1);
    }

    /// A real frame's datagrams, so the log is exercised on bytes whose headers are the ones the
    /// selection reads.
    fn packetized(lane: &PacketizeLane, fill: u8) -> (u32, Arc<[Outgoing]>) {
        let frame = lane.packetize(&vec![fill; MAX_PAYLOAD_SIZE * 3], PacketizeOptions::default());
        (frame.frame_id, frame.outgoings)
    }

    #[test]
    fn only_the_asked_for_fragments_come_back_and_they_come_back_on_video() {
        let packetizer = PacketizeLane::new(None);
        let (frame_id, outgoings) = packetized(&packetizer, 3);
        let log = RetransmitLog::new(8, 1 << 20);
        log.record(frame_id, &outgoings);

        let answer = log.fragments(frame_id, &[2, 0]);
        assert_eq!(answer.len(), 2);
        assert!(
            answer
                .iter()
                .all(|outgoing| outgoing.channel == VideoChannel::Video)
        );
        assert!(
            answer.iter().all(|outgoing| outgoings.contains(outgoing)),
            "a retransmission is the ORIGINAL datagram, re-sent, not a re-encode of it"
        );
    }

    #[test]
    fn a_frame_that_aged_out_answers_with_nothing() {
        let packetizer = PacketizeLane::new(None);
        let log = RetransmitLog::new(1, 1 << 20);
        let (first, first_outgoings) = packetized(&packetizer, 1);
        let (second, second_outgoings) = packetized(&packetizer, 2);
        log.record(first, &first_outgoings);
        log.record(second, &second_outgoings);

        assert_eq!(log.frame_count(), 1, "the older frame is evicted, oldest first");
        assert!(
            log.fragments(first, &[0]).is_empty(),
            "and the client's recovery ladder takes it from there"
        );
        assert_eq!(log.fragments(second, &[0]).len(), 1);
    }

    #[test]
    fn a_request_for_an_index_the_frame_never_had_answers_with_nothing() {
        let packetizer = PacketizeLane::new(None);
        let (frame_id, outgoings) = packetized(&packetizer, 4);
        let log = RetransmitLog::new(8, 1 << 20);
        log.record(frame_id, &outgoings);

        assert!(log.fragments(frame_id, &[99]).is_empty());
        assert!(log.fragments(frame_id.wrapping_add(7), &[0]).is_empty());
    }
}
