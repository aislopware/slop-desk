//! The host output path: a subscription to superd's read of one PTY master.
//!
//! ## No buffer on this side
//! Each chunk is handed to its sink the moment it arrives, on the supervisor client's own reader
//! thread, with the bytes still borrowed out of the frame that carried them. There is no ring
//! buffer here and there must not be one: the only buffer in the system is the transport's replay
//! buffer, and a queue on this path would be exactly the unbounded buffer the `pause` verb exists
//! to prevent (`DECISIONS.md`, "No-buffer relay").
//!
//! ## The backpressure chain, which is the load-bearing part
//! The session's bounded-queue gate asserts a pause when its per-channel queue crosses the
//! high-water mark. [`PaneOutputStream::set_paused`] forwards that to superd, which stops issuing
//! `read` on the master; nothing then drains it, the kernel PTY buffer fills, and the SHELL blocks
//! on its next `write`. No output is produced that anyone would have to drop — the never-drop
//! invariant, kept by pushing the pressure all the way back to the writer.
//!
//! That chain is why the sink is called synchronously here rather than posted to a per-pane queue.
//! Hopping would isolate the panes from each other and turn the queue into the buffer, because the
//! reader would never stop reading.
//!
//! ## EOF arrives two ways
//! Usually as the pane's `exited` notice, which superd broadcasts only after draining the pump to
//! EOF — so the last byte is always through the sink before the end is. But a pane can finish
//! before this subscription exists (`spawn` an `ls` and it is reaped while the reply is still
//! travelling), and that notice went out to nobody. So the subscribe reply carries
//! [`StreamPosition::ended`], and a stream that arrives already finished ends itself: at once when
//! there is no backlog, otherwise on the last byte of one. Both routes go through one latch.
//!
//! ## Why the state is split from the stream
//! `slopdesk_superclient::SupervisorClient` holds every subscribed sink in an `Arc`. If the type
//! that holds the client were also the sink, every stream that was never stopped would be a
//! reference cycle and the pane would leak for the daemon's life. So the sink is [`StreamState`],
//! which knows nothing about the client, and the client reference lives only on the outer
//! [`PaneOutputStream`] — the half a caller holds, and the half that is dropped.

use std::sync::{Arc, Mutex};

use slopdesk_superclient::client::{ClientError, PaneSink, SupervisorClient};
use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::protocol::StreamPosition;
use slopdesk_superwire::sniffwire::SniffEvent;

/// What a pane's output is handed to.
///
/// Every method runs on the supervisor client's single reader thread, shared by every pane, and
/// synchronously — see this module's header for why that is a requirement and not a convenience. An
/// implementation must hand the bytes on without retaining them past its return.
pub trait PaneChunkSink: Send + Sync + std::fmt::Debug {
    /// One chunk, with the absolute offset in the pane's life it ENDS at, and what superd's two
    /// readers found in exactly these bytes.
    ///
    /// The events arrive paired with their own chunk rather than on a stream of their own, which is
    /// what keeps a title latch and the bytes that carried it in step. An EMPTY payload with a
    /// non-empty batch is possible and is still delivered: it is the backlog a resubscribe replays,
    /// whose events belong to bytes this stream already saw.
    ///
    /// The offset has no consumer in hostd today and is passed because it is what superd sent —
    /// this stream's own gap detection is computed from it.
    fn chunk(&self, payload: &[u8], ends_at: u64, sniffed: &[SniffEvent], blocks: &[BlockEvent]);

    /// The pane's master is finished. Called at most once.
    fn ended(&self);

    /// Something worth a line in hostd's log — a lossy resume, a gap, a subscribe that failed.
    fn log(&self, line: &str);
}

/// "Whatever happens from here" — an offset past any ring's head, which superd clamps to the head
/// and answers with an empty backlog.
///
/// For a pane whose history hostd already holds and cannot align with the ring: replaying the
/// backlog would double the transcript, and re-feed the sniffer, the block ledger and the screen
/// engine with it.
pub const FROM_NOW_ON: u64 = u64::MAX;

/// The chunk size superd reads with, restated here because the number is a joint decision.
///
/// 32 KiB: HALF the latency-sized bounded-queue capacity (64 KiB), so the gate's worst overshoot is
/// capacity plus one read rather than capacity plus 128 KiB — a 128 KiB read against a 64 KiB bound
/// would pause on every flood chunk and half-defeat the sizing. The value that actually governs is
/// `pump::READ_CHUNK_BYTES` in superd; changing one without the other re-opens a solved problem.
pub const READ_CHUNK_BYTES: usize = 32 * 1024;

/// The mutable half, all under one lock.
///
/// The five flags are five INDEPENDENT facts about one subscription, not a state machine folded
/// into booleans: a stream can be started and stopped and paused and finished and lossy in almost
/// any combination, and every pairing is reachable. Collapsing them into an enum would need one
/// variant per product.
#[expect(
    clippy::struct_excessive_bools,
    reason = "five orthogonal facts about one subscription, not a state machine"
)]
#[derive(Debug, Default)]
struct Guarded {
    started: bool,
    stopped: bool,
    /// Where the next byte is expected, for gap detection. `None` until the first chunk.
    expected_offset: Option<u64>,
    /// Where the stream is known to end, when superd said so at subscribe time. `None` for the
    /// ordinary case of a pane still running.
    ends_at: Option<u64>,
    /// Whether the end has been declared. It can be learned two ways and must be told once.
    reported_eof: bool,
    /// The gate's latest decision, kept so `stop` can tell whether it is leaving one behind and so
    /// a resubscribe can restate it.
    paused: bool,
    /// Whether the subscribe was answered from further along than it asked for.
    lossy_resume: bool,
    /// The sniffed events waiting for the chunk they were found in. superd writes the sniff frame
    /// and the output frame it precedes under one hold of its own wire lock, so the pairing is
    /// guaranteed and it is this stream's to make.
    pending_sniffed: Vec<SniffEvent>,
    /// The block changes waiting for the chunk that produced them — same frame ordering, same
    /// reasoning.
    pending_blocks: Vec<BlockEvent>,
}

/// The reader-thread half of a stream: everything that decides, and nothing that can reach the
/// socket.
///
/// This is what `SupervisorClient` holds as a sink. It deliberately has no client reference — see
/// the module header.
#[derive(Debug)]
pub struct StreamState {
    /// Named only so the log lines can say which pane. `None` for a pane with no identity.
    pane_id: Option<String>,
    sink: Arc<dyn PaneChunkSink>,
    guarded: Mutex<Guarded>,
}

impl StreamState {
    fn new(pane_id: Option<String>, sink: Arc<dyn PaneChunkSink>) -> Self {
        Self {
            pane_id,
            sink,
            guarded: Mutex::new(Guarded::default()),
        }
    }

    /// The same state as the client's trait object. A helper rather than an `as` cast, which this
    /// crate's `trivial_casts` refuses — the coercion happens in the return position instead.
    fn as_sink(self: &Arc<Self>) -> Arc<dyn PaneSink> {
        let concrete: Arc<Self> = Arc::clone(self);
        concrete
    }

    /// The pane's name for a log line, or a dash. A stream with no identity still logs.
    fn name(&self) -> &str {
        self.pane_id.as_deref().unwrap_or("-")
    }

    /// Declares the stream over, at most once.
    ///
    /// Two things can declare it — the pane's `exited` notice, and a subscribe that already knew
    /// where the stream stopped — and for a pane that dies at just the wrong moment both fire.
    /// Downstream this closes a session, and closing one twice is a use-after-teardown.
    fn finish(&self) {
        let already = match self.guarded.lock() {
            Ok(mut guarded) => std::mem::replace(&mut guarded.reported_eof, true),
            // A poisoned lock means another thread panicked mid-update. Declaring the end is the
            // safe direction: a session that ends early is recoverable, one that never ends is a
            // leaked pane.
            Err(poisoned) => std::mem::replace(&mut poisoned.into_inner().reported_eof, true),
        };
        if !already {
            self.sink.ended();
        }
    }
}

impl PaneSink for StreamState {
    fn bytes(&self, offset: u64, payload: &[u8]) {
        // `wrapping_add`, not `+`: both numbers came off the wire. A version skew or superd's own
        // poisoned-ring fallback could send a shape that overflows, and this process must not DIE
        // of arithmetic on a number it is about to validate anyway.
        let next = offset.wrapping_add(payload.len() as u64);

        let Ok(mut guarded) = self.guarded.lock() else {
            return;
        };
        let expected = guarded.expected_offset;
        let dropped = guarded.stopped;
        let last_of_a_backlog = guarded.ends_at.is_some_and(|end| next >= end);
        // The boundary moves inside the SAME hold that read the end against it, so this handler and
        // `open` cannot both conclude that the other one will declare the stream over. Advancing it
        // after the chunk was handed on left a window one instruction wide where a backlog frame was
        // delivered before `open` recorded the end: the handler saw no end yet, `open` then read the
        // not-yet-advanced offset and judged the backlog unfinished, and NEITHER finished. A pane
        // that ran to completion before anyone subscribed hung there for ever.
        if !dropped {
            guarded.expected_offset = Some(next);
        }
        // Taken unconditionally, so a batch can never outlive the chunk it describes and attach
        // itself to the next one.
        let sniffed = std::mem::take(&mut guarded.pending_sniffed);
        let blocks = std::mem::take(&mut guarded.pending_blocks);
        drop(guarded);

        // A late frame for a pane already let go of is ordinary — `unsubscribe` drops the local
        // sink before its verb reaches superd — and must not reach a torn-down session.
        if dropped {
            return;
        }
        if let Some(expected) = expected
            && offset != expected
        {
            // Not recoverable, only reportable: the bytes are gone from superd's ring. Passing the
            // chunk on anyway is still the best available answer — a terminal missing a region
            // redraws on the next full frame, whereas dropping the rest of the stream never
            // recovers at all.
            let lost = offset.saturating_sub(expected);
            self.sink.log(&format!(
                "pane {}: output gap — expected offset {expected}, got {offset} ({lost} bytes lost)",
                self.name(),
            ));
        }
        if !payload.is_empty() || !sniffed.is_empty() || !blocks.is_empty() {
            self.sink.chunk(payload, next, &sniffed, &blocks);
        }
        // The end goes out AFTER the bytes it follows, on this same thread, so a session's exit
        // frame stays behind its last output frame on the wire.
        if last_of_a_backlog {
            self.finish();
        }
    }

    fn sniffed(&self, events: &[SniffEvent]) {
        // Held, not delivered: superd sends these immediately BEFORE the chunk they were found in,
        // and the pairing is what the caller needs.
        if let Ok(mut guarded) = self.guarded.lock() {
            guarded.pending_sniffed.extend_from_slice(events);
        }
    }

    fn blocks(&self, events: &[BlockEvent]) {
        // Held for the same reason, and released by the same line: the chunk that closed a command
        // and the metadata saying it closed must reach the session together.
        if let Ok(mut guarded) = self.guarded.lock() {
            guarded.pending_blocks.extend_from_slice(events);
        }
    }

    fn ended(&self) {
        self.finish();
    }
}

/// A pane's output subscription, as its owner holds it.
///
/// Dropping one unsubscribes; see [`PaneOutputStream::stop`], which `Drop` calls.
#[derive(Debug)]
pub struct PaneOutputStream {
    client: Arc<SupervisorClient>,
    state: Arc<StreamState>,
    /// `None` for a pane that was never spawned or adopted. Such a stream is EOF from the start,
    /// which is load-bearing rather than lenient: most of the host suite wants the SESSION object
    /// and never a child, and a session's control and input planes are not dependents of its output
    /// path — a `ping` must still be answered by a session whose shell does not exist.
    pane_id: Option<String>,
    /// Where the FIRST subscribe asks from. A resubscribe uses the offset reached instead.
    initial_offset: u64,
}

impl PaneOutputStream {
    /// Builds a stream. Nothing is subscribed until [`PaneOutputStream::start`].
    ///
    /// `from_offset` is where in the pane's LIFE to resume: `0` for the whole ring, or
    /// [`FROM_NOW_ON`] for a pane whose history the caller already holds and cannot align with the
    /// ring. Offsets belong to a pane life and live in superd's memory, so the decision is the
    /// caller's — the hostd that knew where this pane's stream had got to is usually the one that
    /// just died.
    #[must_use]
    pub fn new(
        client: Arc<SupervisorClient>,
        pane_id: Option<String>,
        from_offset: u64,
        sink: Arc<dyn PaneChunkSink>,
    ) -> Self {
        Self {
            client,
            state: Arc::new(StreamState::new(pane_id.clone(), sink)),
            pane_id,
            initial_offset: from_offset,
        }
    }

    /// Subscribes. Idempotent, and safe to call after [`PaneOutputStream::stop`], where it does
    /// nothing.
    pub fn start(&self) {
        let from = {
            let Ok(mut guarded) = self.state.guarded.lock() else {
                return;
            };
            if guarded.started || guarded.stopped {
                return;
            }
            guarded.started = true;
            guarded.expected_offset.unwrap_or(self.initial_offset)
        };
        // The answer is discarded on purpose: a first subscribe that fails has already finished the
        // stream, which is the whole report. Only a REOPEN hands its verdict back, because there
        // the caller has a session to decide about.
        let _opened = self.open(from, false);
    }

    /// Re-opens the subscription after the supervisor connection dropped and came back.
    ///
    /// The pane and its shell are untouched by a control-socket drop — superd holds the master
    /// either way — but the client's sink table went with the connection, so without this the
    /// terminal renders nothing ever again while keystrokes still travel: a window the user types
    /// into that never answers.
    ///
    /// A no-op for a stream that never started, has stopped, or has already ended. Returns whether
    /// a subscription is live afterwards — `false` means superd no longer knows this pane, and the
    /// caller must end the session rather than wait for output that is never coming.
    #[must_use]
    pub fn resubscribe(&self) -> bool {
        let Ok(guarded) = self.state.guarded.lock() else {
            return false;
        };
        let eligible = guarded.started && !guarded.stopped && !guarded.reported_eof;
        let from = guarded.expected_offset.unwrap_or(self.initial_offset);
        drop(guarded);
        if !eligible || self.pane_id.is_none() {
            return false;
        }
        self.open(from, true)
    }

    /// The one subscribe path, shared by [`PaneOutputStream::start`] and
    /// [`PaneOutputStream::resubscribe`].
    fn open(&self, offset: u64, reopening: bool) -> bool {
        // No identity means no child was ever spawned, so there is nothing to subscribe to and
        // nothing wrong. EOF at once, quietly — the loud path below is for a pane that DOES exist
        // and whose stream could not be opened, which is a real fault.
        let Some(pane_id) = self.pane_id.as_deref() else {
            self.state.finish();
            return false;
        };

        let position = match self.client.subscribe(pane_id, offset, self.state.as_sink()) {
            Ok(position) => position,
            Err(error) => return self.subscribe_failed(pane_id, &error, reopening),
        };
        self.accept(pane_id, &position, reopening);
        true
    }

    /// Records a subscribe reply, and declares the end when the reply already carried one.
    fn accept(&self, pane_id: &str, position: &StreamPosition, reopening: bool) {
        // The backlog frames may already have been delivered: superd writes them straight after the
        // reply, and the client's reader is a different thread from this one. So this must not
        // REWIND the expected offset past a chunk already accounted for — which would log a gap
        // that never happened — and it must notice an end that has already been reached.
        let (finished_already, still_paused) = {
            let Ok(mut guarded) = self.state.guarded.lock() else {
                return;
            };
            let reached = guarded.expected_offset.unwrap_or(position.start);
            guarded.expected_offset = Some(reached);
            guarded.ends_at = position.ended.then_some(position.head);
            if position.lossy {
                guarded.lossy_resume = true;
            }
            (position.ended && reached >= position.head, guarded.paused)
        };

        if position.lossy {
            // `saturating_sub`, not `-`: both numbers are decoded off the wire, and `head < start`
            // is a shape superd should never send but this process must not die of. Everything else
            // decoded from superd here is validate-then-drop; the arithmetic is too.
            let retained = position.head.saturating_sub(position.start);
            self.state.sink.log(&format!(
                "pane {pane_id}: superd had already evicted the start of the stream — resumed at {}, \
                 {retained} bytes retained",
                position.start,
            ));
        }
        // A pane that finished before we got here was announced dead before this subscription
        // existed, so no `exited` notice is coming. With a backlog still to arrive the end is
        // declared once its last byte lands; with nothing left to wait for, now.
        if finished_already {
            self.state.finish();
        }
        if reopening {
            self.state.sink.log(&format!(
                "pane {pane_id}: output stream re-opened at {} after a supervisor reconnect",
                position.start,
            ));
            // The gate's last decision has to be re-stated: it lives in superd, and this is a
            // different connection from the one that heard it.
            if still_paused {
                self.client.set_paused(pane_id, true);
            }
        }
    }

    /// The failure half of [`PaneOutputStream::open`], kept separate so the success path reads
    /// straight through.
    fn subscribe_failed(&self, pane_id: &str, error: &ClientError, reopening: bool) -> bool {
        // A pane whose output never arrives is visibly broken, so this must be loud. It is not
        // recoverable here either: the alternative used to be reading the fd ourselves, and that
        // implementation is deliberately gone.
        self.state.sink.log(&format!(
            "pane {pane_id}: could not subscribe to superd's output stream — {error}",
        ));
        // On a REOPEN the caller decides: superd may simply have restarted, in which case this
        // pane's shell died with the old one and the session is over — but that is a fact about the
        // pane, checked against superd's own list, not something to infer from one error.
        if !reopening {
            self.state.finish();
        }
        false
    }

    /// Whether superd had already evicted the bytes this stream asked for — the ring moved past
    /// them while nobody was subscribed.
    ///
    /// Readable the moment [`PaneOutputStream::start`] returns. A caller that subscribed from `0`
    /// specifically to READ something out of the backlog (a panel backend re-learning its port from
    /// its own announce line) has to know that the backlog no longer reaches the start, because
    /// there is nothing in the bytes themselves to say so.
    #[must_use]
    pub fn resumed_lossily(&self) -> bool {
        self.state
            .guarded
            .lock()
            .is_ok_and(|guarded| guarded.lossy_resume)
    }

    /// Whether the end has been declared.
    #[must_use]
    pub fn has_ended(&self) -> bool {
        self.state
            .guarded
            .lock()
            .is_ok_and(|guarded| guarded.reported_eof)
    }

    /// Forwards the bounded-queue gate's decision to superd.
    ///
    /// **Deliberately not gated on [`PaneOutputStream::start`] having happened.** The gate asserts
    /// its first pause while a restore preamble is being enqueued, which the session does BEFORE it
    /// starts the stream — every adopted pane, and any cold reattach with a journal over the queue
    /// capacity. Dropping that call is worse than a missed pause, because the gate latches the
    /// decision as applied and only re-sends it on a CHANGE: it would then believe the pane paused,
    /// the subscription would open wide, and the whole ring backlog would arrive with no
    /// backpressure asserted at all.
    ///
    /// superd's pause is a property of the pane's PUMP, not of a subscription, so it is meaningful
    /// before one exists — and it survives the `subscribe` that follows, because subscribing only
    /// counts. What lifts it is the last unsubscribe, or the gate's own resume.
    pub fn set_paused(&self, paused: bool) {
        let deliverable = {
            let Ok(mut guarded) = self.state.guarded.lock() else {
                return;
            };
            guarded.paused = paused;
            !guarded.stopped
        };
        if let Some(pane_id) = self.pane_id.as_deref()
            && deliverable
        {
            self.client.set_paused(pane_id, paused);
        }
    }

    /// Unsubscribes permanently. Idempotent, and safe to call before
    /// [`PaneOutputStream::start`].
    ///
    /// It does NOT need the child to die first, and it does not stop superd reading the pane. That
    /// distinction is the one the whole design turns on: a hostd relinquishing a pane wants its
    /// reader back without signalling anything, and the pane must keep being drained after it goes.
    pub fn stop(&self) {
        let (was_stopped, was_started, left_paused) = {
            let Ok(mut guarded) = self.state.guarded.lock() else {
                return;
            };
            let was_stopped = std::mem::replace(&mut guarded.stopped, true);
            (was_stopped, guarded.started, guarded.paused)
        };
        let Some(pane_id) = self.pane_id.as_deref() else {
            return;
        };
        if was_stopped {
            return;
        }
        if was_started {
            // superd lifts any pause when the last subscriber leaves, so this covers both jobs.
            self.client.unsubscribe(pane_id);
        } else if left_paused {
            // A pause applied before a subscription that never came. Nobody else will lift it — the
            // un-pause rides the last unsubscribe, and there was never a subscribe — and a paused
            // pane with no reader is the frozen agent superd exists to prevent.
            self.client.set_paused(pane_id, false);
        }
    }
}

impl Drop for PaneOutputStream {
    /// The sink is held by the client, so a stream that is merely dropped would keep receiving —
    /// and keep the pane's state alive — for as long as the client lives. `stop` is what takes it
    /// back out, and it is idempotent, so an owner that already called it pays nothing.
    fn drop(&mut self) {
        self.stop();
    }
}
