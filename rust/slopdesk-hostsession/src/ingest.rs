//! The chunk handler: superd's reader thread, arriving in this pane.
//!
//! Everything here runs on `SupervisorClient`'s ONE reader thread, synchronously, with the payload
//! borrowed out of the frame that carried it. `docs/60` §4 says why it may never be anything else:
//! nothing bounds a subscription queue, so a per-pane channel on this path is precisely the
//! unbounded buffer the `pause` verb exists to prevent, and it would turn the never-drop invariant
//! into a memory leak. The chain that must stay intact is *hostd stops reading → superd's writes
//! block → superd stops reading the master → the kernel PTY buffer fills → the shell is paused*.
//!
//! ## Two things this type may not hold
//!
//! `SupervisorClient` holds every subscribed sink in an `Arc`, and this IS the sink. So it may hold
//! nothing that reaches the client, or the pane leaks for the daemon's life with `Drop` never
//! running to unsubscribe it. That rules out the pane handle — [`PtyProcess`] holds the client — so
//! the one verb this path needs from it, `forget_title_coalescing`, is reached through a [`Weak`].
//! [`Shared`] is safe to hold strongly: it reaches the read loop through a `Weak` of its own, for
//! the same reason.
//!
//! ## What may NOT be called from here
//!
//! `hangup`, `terminate`, `force_terminate` and `release` park for superd's reply, and that reply
//! can only arrive on the thread this is running on. `docs/60` C.1 hands that contract up and this
//! is where it is kept: [`Ingest::ended`] only LATCHES the end. The teardown it implies runs on the
//! exit thread, which is parked in `wait_for_exit` waiting for exactly the notice that ends it.

use std::sync::{Arc, Weak};

use slopdesk_hostpane::{PaneChunkSink, PtyProcess};
use slopdesk_muxsession::truths::Route;
use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::sniffwire::SniffEvent;
use slopdesk_wire::message::WireMessage;

use crate::clock;
use crate::detect::Detect;
use crate::facts::{block_row_message, block_rows, sniffed_facts, sniffed_message};
use crate::project::Project;
use crate::shared::Shared;
use crate::taps::Taps;

/// The pane's half of the read loop.
#[derive(Debug)]
pub(crate) struct Ingest {
    shared: Arc<Shared>,
    /// The pane, weakly — see the module note. A `None` upgrade means the session is already gone,
    /// on which there is nothing left to tell the sniffer.
    pane: Weak<PtyProcess>,
    /// The screen engine's buffer and the detector behind it. Held STRONGLY: it reaches nothing
    /// that reaches back, so it is safe here for the same reason [`Shared`] is.
    detect: Arc<Detect>,
    /// The cwd/project derivation, which needs the pane and so takes it as an argument.
    project: Project,
    /// The agent-control registries. Held strongly for [`Detect`]'s reason — nothing in them
    /// reaches the supervisor client, so nothing here closes a cycle through it.
    taps: Arc<Taps>,
}

impl Ingest {
    /// A sink for `shared`, reaching `pane` without keeping it alive.
    pub(crate) const fn new(
        shared: Arc<Shared>,
        pane: Weak<PtyProcess>,
        detect: Arc<Detect>,
        project: Project,
        taps: Arc<Taps>,
    ) -> Self {
        Self {
            shared,
            pane,
            detect,
            project,
            taps,
        }
    }

    /// Folds one sniffed batch and answers what rides the FIFO with the chunk.
    ///
    /// One acquisition of the fold lock covers the whole thing, including the type-25 gate read in
    /// the SAME acquisition: while a pane's agent announces its own edges through the hook feed,
    /// its OSC notification duplicates the banner the client already raises, so one blocked
    /// prompt raises ONE notification. That is the whole reason the detector lives under this
    /// lock rather than beside it — a gate read a moment before or after the fold would answer
    /// for a different agent's state. Two handles never hold each other, so the verdict crosses
    /// as a VALUE.
    fn fold_sniffed(&self, sniffed: &[SniffEvent]) -> Fold {
        let stamps = clock::stamps();
        self.shared.with_folds(|folds| {
            let suppress = folds.detector.suppresses_child_notifications();
            let truths = &mut folds.truths;
            // A title RETIREMENT folded on another thread since the last chunk (a detected agent
            // exited) also retires the sniffer's coalescing anchor — otherwise the NEXT agent's
            // opening title, very often byte-identical to the one just retired, would be deduped
            // away and the pane would stay untitled.
            let forget_title = truths.take_title_coalescing_reset();
            let facts = sniffed_facts(sniffed);
            let verdicts = truths.ingest_sniffed(&facts, stamps, suppress);
            let mut fifo = Vec::new();
            for verdict in verdicts {
                let Some(fact) = facts.get(verdict.fact as usize) else {
                    continue;
                };
                let Some(message) = sniffed_message(fact) else {
                    continue;
                };
                match verdict.route {
                    // Type-33 is host-gated single-source: the raw OSC-7 cwd is WITHHELD, because
                    // pre-warm-up plugin noise would reach the client unfiltered and a
                    // probe-beaten stale value would arrive at drain time AFTER the probed truth.
                    // [`crate::project`] is what publishes the gated value in its place.
                    Route::Withheld => {},
                    // Broadcast rides the FIFO here, and merging the arms is the honest spelling of
                    // why: nothing in a SNIFFED batch routes to broadcast today, and if a fold ever
                    // starts to, a sniffed fact belongs next to the bytes it was found in — the
                    // control sender would deliver it ahead of them. The broadcast door is the
                    // BLOCK fold's, below, where the fact does not describe a byte offset.
                    Route::Broadcast | Route::Fifo => fifo.push(message),
                }
            }
            Fold { forget_title, fifo }
        })
    }

    /// Folds one block batch. Every member BROADCASTS: a block's metadata rides the control sender
    /// so it never stalls behind the output it describes.
    fn fold_blocks(&self, blocks: &[BlockEvent]) -> Vec<WireMessage> {
        if blocks.is_empty() {
            return Vec::new();
        }
        self.shared.with_truths(|truths| {
            let rows = block_rows(blocks);
            let facts = rows.iter().map(|row| row.fact).collect::<Vec<_>>();
            let verdicts = truths.ingest_blocks(&facts);
            let mut messages = Vec::with_capacity(verdicts.len());
            for verdict in verdicts {
                let Some(row) = rows.get(verdict.fact as usize) else {
                    continue;
                };
                if let Some(message) = block_row_message(row) {
                    messages.push(message);
                }
            }
            messages
        })
    }
}

/// What one sniffed fold produced.
struct Fold {
    /// Whether the sniffer's title anchor must be retired before the next chunk is read.
    forget_title: bool,
    /// The messages that ride the FIFO with the chunk they were found in.
    fifo: Vec<WireMessage>,
}

impl core::fmt::Debug for Fold {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Fold")
            .field("forget_title", &self.forget_title)
            .field("fifo", &self.fifo.len())
            .finish()
    }
}

impl PaneChunkSink for Ingest {
    fn chunk(&self, payload: &[u8], ends_at: u64, sniffed: &[SniffEvent], blocks: &[BlockEvent]) {
        // The RESUME CURSOR, recorded first: a detach keeps it and a rebind re-opens there, which
        // is how the detached window stays superd's ring instead of becoming a third copy here.
        self.shared.life.record_offset(ends_at);

        let fold = self.fold_sniffed(sniffed);
        let pane = self.pane.upgrade();
        if fold.forget_title
            && let Some(ref pane) = pane
        {
            pane.forget_title_coalescing();
        }
        // The two taps that only OBSERVE the chunk. Neither may change what is forwarded, and
        // neither may block: the screen tap is a copy under a lock nothing else contends for at this
        // instant, and the derivation's own expensive half is handed to an executor rather than run
        // here. A pane with detection off pays a branch for both.
        //
        // The derivation reads the RAW batch rather than the fold's output, and it has to: the fold
        // WITHHELDs the sniffed OSC-7 precisely so that the only cwd on the wire is the one this
        // derivation publishes, so a cwd read back out of `fold.fifo` would always be absent.
        self.detect.note_output(payload);
        // The orchestrator's tap, with the payload BORROWED: `wait --until` scans for a pattern and
        // copies nothing, and a tap that needs to keep the bytes is the one that pays for them.
        self.taps.notify_output(payload);
        if let Some(ref pane) = pane {
            self.project.derive(&self.shared, pane, sniffed);
        }
        let broadcast = self.fold_blocks(blocks);
        if !broadcast.is_empty() {
            self.shared.broadcast_control(&broadcast);
            // AFTER the fold and after the broadcast: `run --wait` hears that its command completed
            // only once the block's output is retained and askable, so the very next thing it does —
            // request that output — cannot lose the race with the fold that announced it.
            self.taps.notify_blocks(&broadcast);
        }

        // Account the chunk BEFORE enqueueing it: if it pushes the queue to or over the bound, the
        // read loop pauses here, the kernel PTY buffer fills, and the shell is backpressured. After
        // the append the drain could already have shipped it, and the accounting would be a
        // dequeue looking for an enqueue that never happened.
        self.shared.enqueue_accounted(payload.len());
        self.shared.append_chunk(payload.to_vec(), fold.fifo);
    }

    fn ended(&self) {
        // A LATCH and nothing else. The exit thread is what acts on it — see the module note on
        // what may not be called from this thread. Through `Shared` rather than straight at
        // `Lifecycle`, because the latch and the WAKE for it are one operation: a set that skipped
        // the wake would leave the exit thread parked until its timeout, turning a clean exit into
        // a two-second one.
        self.shared.signal_eof();
    }

    fn log(&self, line: &str) {
        self.shared.log.line(&format!("mux: {line}"));
    }
}
