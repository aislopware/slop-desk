//! The state one pane's threads share, and the locks that order it.
//!
//! Seven locks, and each one is the lock those fields already lived under in
//! `Sources/SlopDeskHost/MuxChannelSession.swift`. That is deliberate and it is the whole design
//! rule: a port that re-partitions the locking is not a port, it is a concurrency change wearing
//! one's clothes, and the two failures it would introduce — a lock-order inversion and a
//! contention move — are exactly the two that fail no build and no test.
//!
//! | here | there | serializes |
//! | --- | --- | --- |
//! | [`Shared::outbound`] | `fifoLock` | the outbound queue, the bytes it names, and the drain's wake |
//! | [`Shared::gate`] | the gate's own lock | the three pause sources AND the action, together |
//! | [`Shared::replay`] | `replayLock` | the ring: sequence, ack, retention |
//! | [`Shared::members`] | `subscribersLock` | the roster and every NUMBER about a member |
//! | [`Shared::sequencing`] | `fanoutLock` | whether a frame fans out, held across the sequence |
//! | [`Shared::truths`] | `truthsLock` | the latched truths (seven Swift locks, already one) |
//! | [`Shared::input`] | `inputGateLock` + `inputQueue` | whether writes are still accepted, and how many are in flight |
//!
//! `life` is the eighth piece of state and the odd one out: it serializes ITSELF, and it is held
//! under no caller lock, because the three callers that touch it — the ingest path, the output
//! drain and the exit thread — must never queue behind the teardown ladder.
//!
//! ## The wake lives inside the queue's lock
//!
//! Append-then-notify, under one acquisition, is what makes a lost wake unrepresentable: a producer
//! sets [`Outbound::woken`] in the same critical section it pushed in, so the drain cannot observe
//! the flag without observing the item. The Swift needed an `AsyncStream` continuation and a
//! `bufferingNewest(1)` policy to approximate this; a `Condvar` beside the mutex IS it.
//!
//! ## The pause action runs while the fold's lock is held
//!
//! `PausableQueueGate` answers "did the combined state CHANGE", and applying that answer outside
//! the acquisition is the lost-wakeup that froze a pane forever (`PausableQueueGate.swift`'s FIX
//! #3): an enqueue that decided `pause` could land after a dequeue that already decided `resume`,
//! leaving a reader parked under a queue that is not full and no future event able to free it. So
//! [`Gate::apply`] runs inside. The stream takes its own lock, the order is always gate → stream,
//! and the stream never calls back.
//!
//! ## The throttle is a `Weak`, and that is the C.1 hazard one layer up
//!
//! `SupervisorClient` holds every subscribed sink in an `Arc`, and this crate's sink holds an
//! `Arc<Shared>`. If `Shared` also held the stream, the cycle would be closed —
//! client → sink → `Shared` → stream → client — and every pane nobody explicitly stopped would
//! leak for the daemon's life, `Drop` never running to unsubscribe it. The session owns the stream;
//! `Shared` borrows the right to pause it.

// `significant_drop_tightening` wants every guard released as early as the borrows allow, and in
// THIS module holding one is what the module is. Two shapes earn it and there is no third: a
// `Condvar::wait` cannot be written without the guard — it is the guard that makes the
// predicate-recheck race-free, and dropping it early is precisely the lost wakeup the four waits
// here exist to avoid — and the folds hold theirs across a whole critical section BY DESIGN, which
// the module header spells out for each of the seven. The opt-out is on the module that earns it
// rather than in the manifest, so it cannot cover a file nobody has written.
#![expect(
    clippy::significant_drop_tightening,
    reason = "the guard held across the wait IS the wake discipline, not an oversight"
)]

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use slopdesk_hostpane::PaneOutputStream;
use slopdesk_muxsession::fanout::{Fanout, SubscriberId};
use slopdesk_muxsession::lifecycle::Lifecycle;
use slopdesk_muxsession::outbox::{Frame, Outbox, Slot};
use slopdesk_muxsession::truths::Truths;
use slopdesk_wire::message::WireMessage;
use slopdesk_wire::mux::flow::{MuxFlowControl, PausableQueueGate};
use slopdesk_wire::replay::ReplayBuffer;

use crate::subscriber::Subscriber;

/// Where a session writes the lines that used to go to hostd's log closure.
///
/// A trait rather than a boxed closure for the reason [`slopdesk_hostpane::PaneChunkSink`] is one:
/// the strict lint set denies a struct with no `Debug`, and a `Box<dyn Fn>` has none to give.
pub trait SessionLog: Send + Sync + core::fmt::Debug {
    /// Records one line. Called from the drain, the relays and the teardown — never under a lock
    /// this crate holds, so an implementation may take its own.
    fn line(&self, message: &str);
}

/// A log that drops every line, for a caller that has none to give.
#[derive(Debug, Clone, Copy)]
pub struct DiscardLog;

impl SessionLog for DiscardLog {
    fn line(&self, _message: &str) {}
}

/// One slot's bytes and the sniffed control that rides them.
///
/// The control travels WITH the payload rather than in a queue of its own because the fold decided
/// their interleaving when it decided their routes: a title sniffed inside a chunk must reach the
/// client next to the bytes it was found in.
#[derive(Debug, Default)]
struct Queued {
    bytes: Vec<u8>,
    control: Vec<WireMessage>,
}

/// The outbound queue, the payloads it names, and the drain's wake.
#[derive(Debug, Default)]
struct Outbound {
    /// The merge/split fold. Holds LENGTHS and slots; the bytes are next door.
    outbox: Outbox,
    /// Slot → what to ship for it.
    payloads: BTreeMap<Slot, Queued>,
    /// Set by a producer in the same acquisition it appended in.
    woken: bool,
    /// Set once by the teardown: the drain returns instead of parking again.
    closed: bool,
}

/// The three-source pause fold and the action it applies, in one place so they stay atomic.
#[derive(Debug)]
struct Gate {
    fold: PausableQueueGate,
    /// The read loop to pause. `Weak` so `Shared` cannot keep the subscription alive; see the
    /// module note.
    throttle: Weak<PaneOutputStream>,
}

impl Gate {
    /// Applies one fold verdict. `None` means the combined state did not change, which is the whole
    /// point of the verdict: a clear on one source cannot spuriously resume a loop another source
    /// still wants paused.
    fn apply(&self, verdict: Option<bool>) {
        let Some(paused) = verdict else { return };
        if let Some(stream) = self.throttle.upgrade() {
            stream.set_paused(paused);
        }
    }
}

/// The roster and every number about a member — one lock, the innermost, exactly as `docs/59`
/// step 3 settled it.
#[derive(Debug, Default)]
struct Members {
    /// Ordered, so a drain, a reap and a roster walk the same order on every run. The Swift
    /// dictionary had none, and a fan-out whose delivery order changes per process is a difference
    /// no test can pin.
    by_id: BTreeMap<SubscriberId, Arc<Subscriber>>,
    fanout: Fanout,
}

/// Whether a frame fans out — the drain's ordering lock.
///
/// Held across the sequence so a joiner is either IN the set for a frame or state-transferred a
/// screen that already contains it, never neither. It is a mode of the DRAIN rather than a fact
/// about a member, which is why it is not under [`Members`].
#[derive(Debug, Default)]
struct Sequencing {
    fanned_out: bool,
}

/// Whether the PTY still takes writes, and how many are in flight.
///
/// The pair is one lock because the teardown reads them together: it closes the gate and then waits
/// for the count to reach zero, and a close that raced an increment would let a write start after
/// the wait had already decided nothing was running.
#[derive(Debug, Default)]
struct InputGate {
    closed: bool,
    in_flight: usize,
}

/// What the drain must ship for one popped frame.
#[derive(Debug)]
pub(crate) enum Ready {
    /// Bytes to sequence, and the sniffed control that rides them.
    Output {
        /// The payload, already merged or split by the fold.
        bytes: Vec<u8>,
        /// What the gate must dequeue once it is SENT.
        byte_count: usize,
        /// Control messages the fold routed to the queue with these bytes.
        control: Vec<WireMessage>,
    },
    /// The pane's exit code. A merge barrier: it never coalesces with a chunk, so it stays strictly
    /// after the final output tail.
    Exit {
        /// The reaped status.
        code: i32,
    },
}

/// One frame, sequenced, with whoever must receive it.
#[derive(Debug)]
pub(crate) struct Sequenced {
    /// The ring index this frame was given.
    pub(crate) seq: i64,
    /// Whether the fan-out path claimed it. `false` means the drain sends inline.
    pub(crate) fanned_out: bool,
    /// Who is attached, in id order.
    pub(crate) targets: Vec<Arc<Subscriber>>,
}

/// Everything one pane's threads share.
#[derive(Debug)]
pub(crate) struct Shared {
    outbound: Mutex<Outbound>,
    /// Signalled whenever [`Outbound::woken`] or [`Outbound::closed`] is set.
    drainable: Condvar,
    gate: Mutex<Gate>,
    replay: Mutex<ReplayBuffer>,
    members: Mutex<Members>,
    /// Signalled when a member is handed the exit, so the exit ladder waits rather than polls.
    delivered: Condvar,
    sequencing: Mutex<Sequencing>,
    truths: Mutex<Truths>,
    input: Mutex<InputGate>,
    /// Signalled when an input write finishes, so the teardown waits rather than polls.
    quiet: Condvar,
    /// Bumped whenever a lifecycle latch is set, so [`Shared::await_latch`] has something to park
    /// on. The TRUTH stays in `life`; this is only the wake.
    latched: Mutex<u64>,
    settled: Condvar,
    /// Serializes itself. The one piece of state held under no caller lock.
    pub(crate) life: Lifecycle,
    /// Set once, first, by the teardown. Read by the exit thread to tell "the child exited" from
    /// "this pane is being let go".
    torn_down: AtomicBool,
    /// Threads started for this pane that have not yet RETURNED — session and member alike.
    ///
    /// A census rather than a roster walk, because the thread this is watching for is the one that
    /// outlives its member: a subscriber retired mid-rebind is out of the roster while its sender
    /// is still parked, and a count taken over the roster would report the leak as zero. It counts
    /// RETURNS, not joins, which is the only version of the question a test can ask without
    /// blocking on the answer.
    live_threads: AtomicUsize,
    pub(crate) log: Arc<dyn SessionLog>,
}

impl Shared {
    /// A pane that has said nothing, with no client attached and no read loop to throttle yet.
    pub(crate) fn new(replay: ReplayBuffer, capacity: i64, log: Arc<dyn SessionLog>) -> Self {
        Self {
            outbound: Mutex::new(Outbound::default()),
            drainable: Condvar::new(),
            gate: Mutex::new(Gate {
                fold: PausableQueueGate::new(capacity),
                throttle: Weak::new(),
            }),
            replay: Mutex::new(replay),
            members: Mutex::new(Members::default()),
            delivered: Condvar::new(),
            sequencing: Mutex::new(Sequencing::default()),
            truths: Mutex::new(Truths::new()),
            input: Mutex::new(InputGate::default()),
            quiet: Condvar::new(),
            latched: Mutex::new(0),
            settled: Condvar::new(),
            life: Lifecycle::new(),
            torn_down: AtomicBool::new(false),
            live_threads: AtomicUsize::new(0),
            log,
        }
    }

    // ------------------------------------------------------------------ truths

    /// Runs one closure under the truths lock.
    ///
    /// A closure rather than a guard accessor because every caller's critical section is a FOLD —
    /// read the gate, fold the batch, take the latch — and handing out a guard would let one of
    /// them hold it across a broadcast, which is the re-entrancy the seven-locks collapse was meant
    /// to make impossible.
    pub(crate) fn with_truths<T>(&self, body: impl FnOnce(&mut Truths) -> T) -> T {
        let mut truths = self.truths.lock().unwrap_or_else(PoisonError::into_inner);
        body(&mut truths)
    }

    // ------------------------------------------------------------------- gate

    /// Points the pause action at the read loop it throttles.
    ///
    /// Called once, after the stream exists. Until then the fold still runs and still decides — it
    /// simply has nothing to apply its decision to, which is the correct behaviour for a pane whose
    /// reader has not started.
    pub(crate) fn install_throttle(&self, stream: &Arc<PaneOutputStream>) {
        let mut gate = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        gate.throttle = Arc::downgrade(stream);
    }

    /// Accounts enqueued bytes and applies the combined pause state atomically.
    pub(crate) fn enqueue_accounted(&self, count: usize) {
        let mut gate = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        let verdict = gate.fold.enqueue(saturating_i64(count));
        gate.apply(verdict);
    }

    /// Accounts SENT bytes and applies the combined pause state atomically.
    ///
    /// Post-send on purpose: the gate bounds enqueued-not-yet-sent, and moving this to take-time
    /// would let the read loop refill while a merged frame is still unsent.
    pub(crate) fn dequeue_accounted(&self, count: usize) {
        let mut gate = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        let verdict = gate.fold.dequeue(saturating_i64(count));
        gate.apply(verdict);
    }

    /// Sets the REPLAY pause source — the ring's own caps, which bound sent-but-unacked bytes the
    /// queue can never see.
    pub(crate) fn set_replay_pause(&self, pause: bool) {
        let mut gate = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        let verdict = gate.fold.set_replay_pause(pause);
        gate.apply(verdict);
    }

    /// Sets the FAN-OUT pause source: bytes sequenced that the fastest member has not shipped.
    pub(crate) fn set_fanout_backlog(&self, bytes: usize) {
        let mut gate = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        let verdict = gate.fold.set_fanout_backlog(saturating_i64(bytes));
        gate.apply(verdict);
    }

    // --------------------------------------------------------------- outbound

    /// Appends one chunk and the control that rides it, then wakes the drain.
    ///
    /// The wake is set INSIDE the acquisition and signalled outside it: signalling under the lock
    /// hands the drain a mutex it immediately blocks on, and signalling before the push is the lost
    /// wake this shape exists to make unrepresentable.
    pub(crate) fn append_chunk(&self, bytes: Vec<u8>, control: Vec<WireMessage>) {
        {
            let mut out = self.outbound.lock().unwrap_or_else(PoisonError::into_inner);
            let slot = out.outbox.append_chunk(bytes.len());
            out.payloads.insert(slot, Queued { bytes, control });
            out.woken = true;
        }
        self.drainable.notify_all();
    }

    /// Appends the exit barrier and wakes the drain.
    pub(crate) fn append_exit(&self, code: i32) {
        {
            let mut out = self.outbound.lock().unwrap_or_else(PoisonError::into_inner);
            out.outbox.append_exit(code);
            out.woken = true;
        }
        self.drainable.notify_all();
    }

    /// Tells the drain to return rather than park again, and wakes it to hear that.
    pub(crate) fn close_drain(&self) {
        {
            let mut out = self.outbound.lock().unwrap_or_else(PoisonError::into_inner);
            out.closed = true;
            out.woken = true;
        }
        self.drainable.notify_all();
    }

    /// Parks until there is something to drain. `false` means the queue was closed and the drain
    /// thread must return.
    pub(crate) fn await_drainable(&self) -> bool {
        let mut out = self.outbound.lock().unwrap_or_else(PoisonError::into_inner);
        while !out.woken && !out.closed {
            out = self.drainable.wait(out).unwrap_or_else(PoisonError::into_inner);
        }
        out.woken = false;
        !out.closed
    }

    /// Pops the next frame, resolving the fold's slot arithmetic into the bytes to ship.
    ///
    /// The single-slot, unsplit case MOVES its payload out of the map rather than copying it, which
    /// is the steady interactive state: one 32 KiB chunk in, one frame out, and the only copy on
    /// the path is the one the sink already made to outlive its borrowed buffer.
    pub(crate) fn take_frame(&self) -> Option<Ready> {
        let mut out = self.outbound.lock().unwrap_or_else(PoisonError::into_inner);
        let frame = out.outbox.take(merge_cap())?;
        let (first_slot, slots, byte_count, split) = match frame {
            Frame::Exit { code } => return Some(Ready::Exit { code }),
            Frame::Output {
                first_slot,
                slots,
                byte_count,
                split,
            } => (first_slot, slots, byte_count, split),
        };
        if split {
            // The head stays queued holding the remainder, and its control rides the PREFIX: a
            // per-channel control FIFO is the only order anything downstream relies on, so the
            // sniffed messages go out with the first half rather than waiting for the second.
            let Some(queued) = out.payloads.get_mut(&first_slot) else {
                return Some(empty_frame());
            };
            let remainder = queued.bytes.split_off(byte_count.min(queued.bytes.len()));
            let prefix = core::mem::replace(&mut queued.bytes, remainder);
            let control = core::mem::take(&mut queued.control);
            return Some(Ready::Output {
                byte_count: prefix.len(),
                bytes: prefix,
                control,
            });
        }
        if slots == 1 {
            let queued = out.payloads.remove(&first_slot).unwrap_or_default();
            return Some(Ready::Output {
                byte_count: queued.bytes.len(),
                bytes: queued.bytes,
                control: queued.control,
            });
        }
        let mut bytes = Vec::with_capacity(byte_count);
        let mut control = Vec::new();
        for offset in 0..slots {
            let slot = first_slot.wrapping_add(offset as Slot);
            let Some(queued) = out.payloads.remove(&slot) else {
                continue;
            };
            bytes.extend_from_slice(&queued.bytes);
            control.extend(queued.control);
        }
        Some(Ready::Output {
            byte_count: bytes.len(),
            bytes,
            control,
        })
    }

    // ----------------------------------------------------------- the sequence

    /// Sequences one frame and answers who must receive it.
    ///
    /// The whole body runs under [`Shared::sequencing`], which is what makes a JOIN atomic with
    /// respect to a frame: a joiner is either in `targets` for this seq, or it state-transferred a
    /// screen that already contains these bytes. Never neither, and never both.
    ///
    /// `bytes` is BORROWED and copied once, into the ring, because the ring must own what it
    /// retains. The caller keeps the original for the message it builds, so the frame the single
    /// member receives adds no second copy.
    pub(crate) fn sequence(&self, bytes: &[u8]) -> Sequenced {
        let sequencing = self.sequencing.lock().unwrap_or_else(PoisonError::into_inner);
        let targets = {
            let members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
            members.by_id.values().map(Arc::clone).collect::<Vec<_>>()
        };
        let seq = self
            .replay
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .append(bytes.to_vec());
        Sequenced {
            seq,
            fanned_out: sequencing.fanned_out,
            targets,
        }
    }

    /// Switches the drain to the fan-out path, answering `false` if it already was.
    pub(crate) fn begin_fan_out(&self) -> bool {
        let mut sequencing = self.sequencing.lock().unwrap_or_else(PoisonError::into_inner);
        if sequencing.fanned_out {
            return false;
        }
        sequencing.fanned_out = true;
        true
    }

    /// Answers whether the drain is already on the fan-out path.
    ///
    /// For a member that joins AFTER the switch: it needs a data sender of its own, and
    /// [`Self::begin_fan_out`]'s roster walk has already happened. The answer races with that walk
    /// by construction, and does not need not to — [`Self::start_sender`] is the arbiter, so the
    /// member gets exactly one sender whichever of the two reaches it first.
    pub(crate) fn is_fanned_out(&self) -> bool {
        self.sequencing
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .fanned_out
    }

    /// Reads the drain's mode and the roster together, for the exit ladder — the one other place
    /// that must see the same pair the sequence saw.
    pub(crate) fn hand_off_exit(&self) -> (bool, Vec<Arc<Subscriber>>) {
        let sequencing = self.sequencing.lock().unwrap_or_else(PoisonError::into_inner);
        let members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        (
            sequencing.fanned_out,
            members.by_id.values().map(Arc::clone).collect(),
        )
    }

    /// The ring's highest assigned seq — a fresh sender's frontier seed.
    pub(crate) fn highest_seq(&self) -> i64 {
        self.replay
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .highest_seq()
    }

    /// Acks the ring up to `seq` and re-applies the replay pause source.
    ///
    /// Two acquisitions rather than one: the roster answers the retention FLOOR, the ring applies
    /// it, and the gate applies what the ring then wants. Nesting them would make one handle hold
    /// another's lock, which is the aliasing `docs/59` step 3 forbids.
    pub(crate) fn acknowledge(&self, id: SubscriberId, seq: i64) {
        let floor = {
            let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
            members.fanout.acknowledge(id, seq).unwrap_or(seq)
        };
        let pause = {
            let mut replay = self.replay.lock().unwrap_or_else(PoisonError::into_inner);
            replay.ack(floor);
            replay.should_pause_drain()
        };
        self.set_replay_pause(pause);
    }

    /// Publishes whether a client is reachable, which arms or disarms the ring's offline gate.
    pub(crate) fn set_client_online(&self, online: bool) {
        let pause = {
            let mut replay = self.replay.lock().unwrap_or_else(PoisonError::into_inner);
            replay.set_client_online(online);
            replay.should_pause_drain()
        };
        self.set_replay_pause(pause);
    }

    /// Re-derives the online truth from the SET.
    ///
    /// From the set rather than asserted, because with one member the answer is the `false` a
    /// departing relay always applied — and the moment there are two, asserting it outright would
    /// pause the PTY for a client that is still right there.
    pub(crate) fn recompute_client_online(&self) {
        self.set_client_online(self.member_count() > 0);
    }

    // ---------------------------------------------------------------- members

    /// Adds a member to the roster and the fanout numbers together — they are one lock because a
    /// key with no cursor and a cursor with no key are both states nothing can act on.
    pub(crate) fn admit(&self, subscriber: &Arc<Subscriber>, acked: i64) {
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        members.fanout.join(subscriber.id, acked);
        members.by_id.insert(subscriber.id, Arc::clone(subscriber));
    }

    /// Mints the next subscriber id.
    ///
    /// On the roster's lock so the counter is not a second piece of state, but the ORDER — reserve,
    /// register whatever names it, then join — stays the caller's, because a channel key names a
    /// subscriber before the member exists.
    pub(crate) fn reserve_subscriber_id(&self) -> SubscriberId {
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        members.fanout.reserve_id()
    }

    /// Removes a member, IDENTITY-guarded, and answers whether the set emptied.
    ///
    /// The guard is the whole point: a relay tail that lands after a REPLACE must not evict the
    /// member that took its place.
    pub(crate) fn retire(&self, subscriber: &Arc<Subscriber>) -> bool {
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        let incumbent = members
            .by_id
            .get(&subscriber.id)
            .is_some_and(|held| Arc::ptr_eq(held, subscriber));
        if !incumbent {
            return members.by_id.is_empty();
        }
        members.by_id.remove(&subscriber.id);
        members.fanout.leave(subscriber.id)
    }

    /// Everyone currently attached, in id order.
    pub(crate) fn roster(&self) -> Vec<Arc<Subscriber>> {
        let members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        members.by_id.values().map(Arc::clone).collect()
    }

    /// How many are attached.
    pub(crate) fn member_count(&self) -> usize {
        self.members
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .by_id
            .len()
    }

    /// Hands a pane-wide control fact to every member's sender.
    pub(crate) fn broadcast_control(&self, messages: &[WireMessage]) {
        if messages.is_empty() {
            return;
        }
        for member in self.roster() {
            member.enqueue_control(messages.to_vec());
        }
    }

    /// Claims one member's data sender, seeding its frontier at the ring's head.
    pub(crate) fn start_sender(&self, id: SubscriberId, head: i64) -> bool {
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        members.fanout.start_sender(id, head)
    }

    /// Releases one member's sender claim.
    pub(crate) fn clear_sender(&self, id: SubscriberId) {
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        members.fanout.clear_sender(id);
    }

    /// Records that a member shipped a seq, then re-prices the fan-out backlog.
    pub(crate) fn note_sent(&self, id: SubscriberId, seq: i64) {
        let frontier = {
            let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
            members.fanout.note_sent(id, seq);
            members.fanout.frontier()
        };
        let Some(frontier) = frontier else {
            self.set_fanout_backlog(0);
            return;
        };
        let bytes = self
            .replay
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retained_bytes_above(frontier);
        self.set_fanout_backlog(bytes);
    }

    /// Latches that a member has been handed the exit, and wakes whoever is waiting for that.
    pub(crate) fn mark_exit_delivered(&self, id: SubscriberId) {
        {
            let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
            members.fanout.mark_exit_delivered(id);
        }
        self.delivered.notify_all();
    }

    /// Waits — bounded — for every member of `targets` to have been handed the exit.
    ///
    /// A condvar rather than a poll: the latch is set by the sender threads, so they can wake this
    /// directly. `false` means the window closed with someone still owed it, which is a dead client
    /// rather than an error and is exactly why the wait is bounded.
    pub(crate) fn await_exit_delivery(&self, targets: &[Arc<Subscriber>], timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut members = self.members.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            let pending = targets
                .iter()
                .any(|target| members.fanout.exit_pending(target.id));
            if !pending {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (guard, outcome) = self
                .delivered
                .wait_timeout(members, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            members = guard;
            if outcome.timed_out() {
                return !targets
                    .iter()
                    .any(|target| members.fanout.exit_pending(target.id));
            }
        }
    }

    // ----------------------------------------------------------- the latches

    /// Latches EOF and wakes whoever is gating on it.
    pub(crate) fn signal_eof(&self) {
        self.life.signal_eof();
        self.bump_latches();
    }

    /// Latches "the exit went out" and wakes whoever is gating on it.
    pub(crate) fn signal_exit_sent(&self) {
        self.life.signal_exit_sent();
        self.bump_latches();
    }

    /// Waits — bounded — for the read loop to have drained the master to EOF.
    pub(crate) fn await_eof(&self, timeout: Duration) -> bool {
        self.await_latch(timeout, || self.life.is_eof())
    }

    /// Waits — bounded — for the drain to have SENT the exit.
    pub(crate) fn await_exit_sent(&self, timeout: Duration) -> bool {
        self.await_latch(timeout, || self.life.is_exit_sent())
    }

    /// Bumps the wake counter the latch waiters park on.
    ///
    /// The counter is not the truth — `life` is — so this is only what turns a set into a wake. The
    /// acquisition is what makes it race-free: a waiter re-reads the predicate under this same lock
    /// before parking, so a set between its check and its park cannot be missed.
    fn bump_latches(&self) {
        {
            let mut generation = self.latched.lock().unwrap_or_else(PoisonError::into_inner);
            *generation = generation.wrapping_add(1);
        }
        self.settled.notify_all();
    }

    /// Parks until `ready` or the deadline, whichever comes first.
    fn await_latch(&self, timeout: Duration, ready: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        let mut generation = self.latched.lock().unwrap_or_else(PoisonError::into_inner);
        while !ready() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (guard, _) = self
                .settled
                .wait_timeout(generation, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            generation = guard;
        }
        true
    }

    // -------------------------------------------------------- the input gate

    /// Claims one in-flight PTY write, or refuses it because the gate has closed.
    ///
    /// The claim is what makes the teardown's wait meaningful: a write that started before the
    /// close is counted, so `close_master` cannot run under it and hand the freed fd number to a
    /// concurrent `openpty` while a stale write is still in the kernel.
    pub(crate) fn begin_input_write(&self) -> bool {
        let mut gate = self.input.lock().unwrap_or_else(PoisonError::into_inner);
        if gate.closed {
            return false;
        }
        gate.in_flight = gate.in_flight.saturating_add(1);
        true
    }

    /// Releases one in-flight write and wakes a teardown waiting for quiet.
    pub(crate) fn end_input_write(&self) {
        {
            let mut gate = self.input.lock().unwrap_or_else(PoisonError::into_inner);
            gate.in_flight = gate.in_flight.saturating_sub(1);
        }
        self.quiet.notify_all();
    }

    /// Refuses every write from here on.
    pub(crate) fn close_input_gate(&self) {
        let mut gate = self.input.lock().unwrap_or_else(PoisonError::into_inner);
        gate.closed = true;
    }

    /// Waits — bounded — for every in-flight write to return. `false` means one is still parked in
    /// the kernel, on which the caller must NOT close the descriptor under it.
    pub(crate) fn await_input_quiet(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut gate = self.input.lock().unwrap_or_else(PoisonError::into_inner);
        while gate.in_flight > 0 {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (guard, _) = self
                .quiet
                .wait_timeout(gate, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            gate = guard;
        }
        true
    }

    // ------------------------------------------------------------- teardown

    /// Latches that this session is being torn down.
    pub(crate) fn mark_torn_down(&self) {
        self.torn_down.store(true, Ordering::Release);
    }

    /// Whether the teardown has begun.
    pub(crate) fn is_torn_down(&self) -> bool {
        self.torn_down.load(Ordering::Acquire)
    }

    // ------------------------------------------------------------ the census

    /// Counts one thread as started. Called BEFORE the spawn, so a body that returns immediately
    /// cannot decrement a counter it was never added to.
    pub(crate) fn enter_thread(&self) {
        self.live_threads.fetch_add(1, Ordering::AcqRel);
    }

    /// Counts one thread as returned.
    pub(crate) fn leave_thread(&self) {
        self.live_threads.fetch_sub(1, Ordering::AcqRel);
    }

    /// How many of this pane's threads have not returned.
    pub(crate) fn live_thread_count(&self) -> usize {
        self.live_threads.load(Ordering::Acquire)
    }
}

/// A frame whose slot went missing, which the outbox's own arithmetic makes unreachable.
///
/// Shipped rather than skipped so the gate's dequeue still runs: a take that returned nothing at
/// all would strand the enqueued bytes and wedge the read loop, which is the one failure mode
/// worse than an empty frame on the wire.
const fn empty_frame() -> Ready {
    Ready::Output {
        bytes: Vec::new(),
        byte_count: 0,
        control: Vec::new(),
    }
}

/// The merge cap, read per pop.
///
/// Read here rather than held because it is `slopdesk-wire`'s number and `slopdesk-muxsession`
/// deliberately has no edge to the protocol crate — the fold takes it as an argument so it stays
/// spelled once, and `SLOPDESK_MUX_MERGE_CAP` stays live.
fn merge_cap() -> usize {
    usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(usize::MAX)
}

/// A byte count as the signed number the accounting speaks, saturating rather than wrapping.
///
/// Unreachable in practice — a chunk is 32 KiB — and saturating rather than truncating because an
/// accounting that wrapped would report a full queue as empty, which is the one direction that
/// silently removes the backpressure this whole path exists to apply.
fn saturating_i64(count: usize) -> i64 {
    i64::try_from(count).unwrap_or(i64::MAX)
}
