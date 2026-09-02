//! One attached client, and the threads that carry its two lanes.
//!
//! A member of a pane is a pair of sub-channels plus two outbound queues, and the queues exist for
//! one reason: neither lane may ever wait on the other. A control fact must not queue behind a full
//! data window, and a data frame must not wait on a peer that has stopped reading its control
//! socket. The Swift bought that with four `Task`s; this buys it with threads, and the difference
//! is what the module has to be careful about.
//!
//! ## A thread has to be able to RETURN
//!
//! Every relay in the Swift was a `Task` the teardown could cancel. Rust has no such lever, so each
//! thread here ends on a condition the teardown can actually cause:
//!
//! - the two RELAYS end when their channel's `Receiver` ends, which
//!   [`SubChannel::finish`](slopdesk_muxnet::subchannel::SubChannel::finish) causes by dropping the
//!   sender;
//! - the two SENDERS end when their lane is CLOSED, which [`Subscriber::close_lanes`] causes, and
//!   they check it under the same lock they park on so a close during a park is not missed.
//!
//! The failure this shape prevents is not a wedged pane — it is one leaked thread per rebind, which
//! a test that attaches once cannot see. `a_retired_subscriber_leaves_no_thread_running` is the one
//! that can.
//!
//! ## Retiring is not joining
//!
//! [`Subscriber::retire`] is called from the input relay's own thread when its channel ends, so it
//! may not join. It closes the lanes, finishes the channels and returns; the JOIN happens in the
//! session's teardown, which skips any handle belonging to the calling thread for exactly this
//! reason.

use std::sync::mpsc::Receiver;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_hostpane::PtyProcess;
use slopdesk_muxnet::subchannel::SubChannel;
use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_muxsession::resize_fold::Grid;
use slopdesk_wire::message::WireMessage;

use crate::detect::Detect;
use crate::resize::Resize;
use crate::shared::Shared;

/// Bound on ONE subscriber's pending control-out queue.
///
/// Control consumers are latest-state folds (title, activity) or droppable samples (pong), so
/// shedding under a flood is safe — and without a bound, a hostile peer spamming `.ping` against
/// its own non-read control socket grows the queue without limit. PER SUBSCRIBER because that is
/// the only shape that keeps the promise: one shared queue with N cursors would let the stalled
/// reader hold it at the cap and shed for the healthy ones too.
const MAX_CONTROL_OUT_QUEUED: usize = 1024;

/// One outbound lane: what is pending on it, and whether it will ever take more.
#[derive(Debug, Default)]
struct Lane {
    pending: Vec<WireMessage>,
    closed: bool,
}

/// One attached client.
#[derive(Debug)]
pub(crate) struct Subscriber {
    /// The roster key. Minted before the member exists, because a channel key names it first.
    pub(crate) id: SubscriberId,
    /// Output and input.
    pub(crate) data: Arc<SubChannel>,
    /// Everything else.
    pub(crate) control: Arc<SubChannel>,
    data_lane: Mutex<Lane>,
    data_wake: Condvar,
    control_lane: Mutex<Lane>,
    control_wake: Condvar,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

impl Subscriber {
    /// A member with both lanes open and no threads yet.
    pub(crate) fn new(id: SubscriberId, data: Arc<SubChannel>, control: Arc<SubChannel>) -> Arc<Self> {
        Arc::new(Self {
            id,
            data,
            control,
            data_lane: Mutex::new(Lane::default()),
            data_wake: Condvar::new(),
            control_lane: Mutex::new(Lane::default()),
            control_wake: Condvar::new(),
            threads: Mutex::new(Vec::new()),
        })
    }

    /// Queues control messages, shedding past the bound.
    ///
    /// Shedding takes the OLDEST first, because every consumer of this lane folds latest-wins: a
    /// dropped stale title is invisible and a dropped fresh one is the pane going quiet.
    pub(crate) fn enqueue_control(&self, messages: Vec<WireMessage>) {
        if messages.is_empty() {
            return;
        }
        {
            let mut lane = self.control_lane.lock().unwrap_or_else(PoisonError::into_inner);
            if lane.closed {
                return;
            }
            lane.pending.extend(messages);
            let overflow = lane.pending.len().saturating_sub(MAX_CONTROL_OUT_QUEUED);
            if overflow > 0 {
                lane.pending.drain(..overflow);
            }
        }
        self.control_wake.notify_all();
    }

    /// Queues data messages. Unbounded on purpose: the ring's retention caps and the fan-out
    /// eviction rule are what bound this lane, and a second cap here would drop OUTPUT, which the
    /// never-drop invariant forbids.
    pub(crate) fn enqueue_data(&self, messages: Vec<WireMessage>) {
        if messages.is_empty() {
            return;
        }
        {
            let mut lane = self.data_lane.lock().unwrap_or_else(PoisonError::into_inner);
            if lane.closed {
                return;
            }
            lane.pending.extend(messages);
        }
        self.data_wake.notify_all();
    }

    /// Parks until the control lane has a batch, or until it closes.
    fn take_control(&self) -> Option<Vec<WireMessage>> {
        take(&self.control_lane, &self.control_wake)
    }

    /// Parks until the data lane has a batch, or until it closes.
    fn take_data(&self) -> Option<Vec<WireMessage>> {
        take(&self.data_lane, &self.data_wake)
    }

    /// Closes both lanes and wakes whoever is parked on them, so the two senders return.
    pub(crate) fn close_lanes(&self) {
        {
            let mut lane = self.data_lane.lock().unwrap_or_else(PoisonError::into_inner);
            lane.closed = true;
            lane.pending.clear();
        }
        {
            let mut lane = self.control_lane.lock().unwrap_or_else(PoisonError::into_inner);
            lane.closed = true;
            lane.pending.clear();
        }
        self.data_wake.notify_all();
        self.control_wake.notify_all();
    }

    /// Takes this member out of service: close the lanes, finish the channels.
    ///
    /// Every one of those is what makes some thread return, and none of them joins — see the module
    /// note. Idempotent, because a clean `bye` and a dropped link can both reach it.
    pub(crate) fn retire(&self) {
        self.close_lanes();
        self.data.finish();
        self.control.finish();
    }

    /// Remembers a thread this member owns.
    pub(crate) fn adopt(&self, handle: JoinHandle<()>) {
        self.threads
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(handle);
    }

    /// Joins every thread this member owns, EXCEPT one belonging to the caller.
    ///
    /// The exception is not a nicety: the input relay retires its own subscriber when its channel
    /// ends, and a teardown reached from there would otherwise join the thread it is running on.
    pub(crate) fn join_threads(&self) {
        let running = std::thread::current().id();
        let handles = core::mem::take(&mut *self.threads.lock().unwrap_or_else(PoisonError::into_inner));
        let mut carried = Vec::new();
        for handle in handles {
            if handle.thread().id() == running {
                carried.push(handle);
                continue;
            }
            drop(handle.join());
        }
        self.threads
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend(carried);
    }
}

/// One lane's park-and-take, shared by both because the shape is identical and the two locks are
/// not.
fn take(lane: &Mutex<Lane>, wake: &Condvar) -> Option<Vec<WireMessage>> {
    let mut held = lane.lock().unwrap_or_else(PoisonError::into_inner);
    while held.pending.is_empty() && !held.closed {
        held = wake.wait(held).unwrap_or_else(PoisonError::into_inner);
    }
    if held.pending.is_empty() {
        return None;
    }
    Some(core::mem::take(&mut held.pending))
}

/// Drains this member's CONTROL queue onto its control sub-channel, FIFO.
///
/// FIFO per subscriber is the only ordering anything relies on: every consumer folds each type
/// independently, and cross-socket order against data is non-deterministic by construction.
pub(crate) fn run_control_sender(subscriber: &Arc<Subscriber>) {
    while let Some(batch) = subscriber.take_control() {
        for message in &batch {
            // A send that fails means the channel ended under us. Keep draining rather than
            // returning: the lane's close is what ends this thread, and it is the only thing that
            // may, or a peer that half-closed would strand the batch a retire is about to clear.
            drop(subscriber.control.send(message));
        }
    }
}

/// Drains this member's DATA queue onto its data sub-channel, parking on the credit window.
///
/// Only a FANNED-OUT pane has one of these. With a single member the drain sends inline on its own
/// thread, exactly as the Swift did, so the common pane costs no sender thread at all.
pub(crate) fn run_data_sender(subscriber: &Arc<Subscriber>, shared: &Arc<Shared>) {
    while let Some(batch) = subscriber.take_data() {
        for message in &batch {
            let sent = subscriber.data.send(message).is_ok();
            match *message {
                WireMessage::Output { seq, .. } if sent => shared.note_sent(subscriber.id, seq),
                WireMessage::Exit { .. } => shared.mark_exit_delivered(subscriber.id),
                _ => {},
            }
        }
    }
    shared.clear_sender(subscriber.id);
}

/// The shortest gap between two termios `ECHO` samples on the input path.
///
/// One scheduler quantum: a shell that flips the bit does so from its own read loop, which cannot
/// turn around between two keystrokes that land closer than this.
const ECHO_SAMPLE_GAP: Duration = Duration::from_millis(16);

/// Carries this member's inbound DATA — its keystrokes — to the master fd.
///
/// The write is blocking and it is deliberate: credit is granted only AFTER it returns, so a PTY
/// that has stopped reading transitively parks the CLIENT's sender at one window instead of
/// buffering the paste in host RAM. Every member of a pane writes; the fan-out is tmux's, where
/// each attached client types into the same shell.
pub(crate) fn run_input_relay(
    subscriber: &Arc<Subscriber>,
    inbound: &Receiver<WireMessage>,
    shared: &Arc<Shared>,
    pty: &Arc<PtyProcess>,
    detect: &Arc<Detect>,
) {
    let mut last_echo_sample: Option<Instant> = None;
    while let Ok(message) = inbound.recv() {
        if let WireMessage::Input(ref bytes) = message {
            // CLAIM the write before making it. The teardown closes this gate and then waits for
            // the count to fall to zero, and that wait is the only thing standing between
            // `close_master` and a freed fd number being recycled by a concurrent `openpty` while
            // this blocking `write(2)` is still in the kernel — which would inject this pane's
            // keystrokes into an unrelated one. A refused claim means the pane is going away, on
            // which the bytes are dropped and the credit is still granted below: a sender left
            // parked on an exhausted window would never learn its pane had ended.
            if shared.begin_input_write() {
                if let Err(error) = pty.write(bytes) {
                    shared.log.line(&format!("pane input write failed: {error}"));
                }
                shared.end_input_write();
            }
            // Two folds over what was just typed, here rather than anywhere else for one reason:
            // the termios `ECHO` bit flips fastest around a password prompt, and the
            // instant after the keystroke that opened it is when the probe is right.
            // The cancel edge has the same shape — a `Ctrl-C` observed after the output
            // it interrupted is an agent reported busy through its own interruption.
            // Both are cheap enough to sit on this path: one `tcgetattr`, and a fold
            // that bails on its status check before reading a byte.
            //
            // The `tcgetattr` is rate-limited to the shell's own reaction time: the bit cannot
            // flip between two keystrokes closer than the shell can run its read loop, so a
            // paste that lands as a run of input messages, or a key repeat, samples once per
            // gap rather than once per message, and the foreground poll remains the backstop.
            if last_echo_sample.is_none_or(|sampled| sampled.elapsed() >= ECHO_SAMPLE_GAP) {
                Detect::sample_echo(shared, pty);
                last_echo_sample = Some(Instant::now());
            }
            detect.fold_input(shared, bytes);
        }
        // Consumed: grant the window back ON THE CHANNEL THE BYTES ARRIVED ON. Every sub-channel
        // owns its own accountant, and a sender parked on an exhausted window wakes only on a grant
        // for ITS channel — crediting any other one parks the real sender with no event that can
        // ever free it.
        subscriber.data.note_consumed(message.wire_byte_count());
    }
    // The DATA channel ended, cleanly or not: this member is no longer reachable. Retire it —
    // identity-guarded inside `Shared`, so a tail that lands after a REPLACE cannot evict the
    // member that took its place — and recompute the session's online truth from the SET. With one
    // member that recompute is `false`; asserting `false` outright is what would, the moment there
    // are two, pause the PTY for a client that is still right there.
    subscriber.retire();
    // Whether that EMPTIED the set is the detach ladder's question, and the detach ladder is stage
    // C.2c's. What the answer changes here is nothing: the online truth below is recomputed from
    // the set either way.
    let _emptied = shared.retire(subscriber);
    shared.recompute_client_online();
}

/// Carries this member's inbound CONTROL — the acks, the byes, the size offers and the probes.
///
/// The metadata verbs land at stage C.2d. What is here now is the set the output path itself
/// depends on: an ack is what releases ring retention, and without it the replay pause source never
/// clears.
///
/// ## Which messages FLUSH the size fold, and why it is not all of them
///
/// This loop is serial, so a size offer that arrived before some other message must land before
/// that message's effects — otherwise the ordering the client sees is the debounce's timer rather
/// than the order it sent things in. So an ack, a bye, a channel close and anything unrecognised
/// resolve the fold unconditionally first.
///
/// Three deliberately do NOT: a ping, a block-output request and a metadata request. Each orders
/// against nothing, and a periodic ping that flushed would defeat the resize micro-debounce
/// outright — a client that pings every second would `TIOCSWINSZ` once per second mid-drag.
pub(crate) fn run_control_relay(
    subscriber: &Arc<Subscriber>,
    inbound: &Receiver<WireMessage>,
    shared: &Arc<Shared>,
    resize: &Arc<Resize>,
) {
    while let Ok(message) = inbound.recv() {
        match message {
            WireMessage::Resize {
                cols,
                rows,
                px_width,
                px_height,
            } => {
                resize.offer(subscriber.id, Grid {
                    cols,
                    rows,
                    px: px_width,
                    py: px_height,
                });
            },
            WireMessage::Ack { seq } => {
                resize.flush();
                shared.acknowledge(subscriber.id, seq);
            },
            // A stateless echo. The timestamp is the CLIENT's clock and only the client reads it,
            // so nothing here interprets it.
            WireMessage::Ping { timestamp_ms } => {
                subscriber.enqueue_control(vec![WireMessage::Pong { timestamp_ms }]);
            },
            // Served at stage C.2d. Listed here rather than left to the catch-all because the
            // catch-all FLUSHES, and neither of these may.
            WireMessage::RequestBlockOutput { .. } | WireMessage::MetadataRequest { .. } => {},
            // A clean departure. The peer will finish the channel; ending here rather than waiting
            // for that makes the intent explicit and costs nothing if the finish arrives anyway.
            WireMessage::Bye => {
                resize.flush();
                break;
            },
            _ => resize.flush(),
        }
    }
    // The channel closed: apply any settled-but-undebounced final size before the loop ends, so a
    // client leaving never strands one.
    resize.flush();
    subscriber.retire();
}
