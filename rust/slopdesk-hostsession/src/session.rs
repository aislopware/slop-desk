//! One pane's session: what holds the pane, the members and the threads between them.
//!
//! This is `MuxChannelSession`'s spine. What it does NOT contain is as deliberate as what it does —
//! every verdict it takes belongs to a crate that already owns it, and the ladders that change WHO
//! is attached (`join`, `detach`, `rebind`) land at stage C.2c, over the same `Shared` this
//! assembles.
//!
//! ## Who owns what, and why the ownership is the design
//!
//! ```text
//!   PaneSession ──owns──▶ Arc<PtyProcess> ──owns──▶ Arc<SupervisorClient>
//!        │                                                    │
//!        ├──owns──▶ Arc<PaneOutputStream> ──▶ StreamState ◀───┘ (the client's sink table)
//!        │                                        │
//!        └──owns──▶ Arc<Shared> ◀────────────── Ingest (the sink)
//!                        │
//!                        └── Weak ──▶ PaneOutputStream, and Ingest holds Weak ──▶ PtyProcess
//! ```
//!
//! Every arrow that would close a loop is a `Weak`. The client holds the sink for as long as the
//! subscription lives, so anything the sink holds STRONGLY is alive for that long too — which is
//! correct for `Shared` and would be a leak for the pane and the stream. Dropping the session drops
//! the stream, whose `Drop` unsubscribes, which is what finally releases the sink and the `Shared`
//! under it. `docs/60`'s C.1 entry records the same split one layer down; this is that rule applied
//! where it recurs.
//!
//! ## Three threads, and the one contract between them
//!
//! The DRAIN is the only thread that sequences or ships. The EXIT thread is parked in
//! `wait_for_exit` and owns the teardown, because `hangup`/`terminate`/`force_terminate`/`release`
//! park for superd's reply and that reply arrives on the client's reader thread — the same thread
//! the sink runs on. A session that tore down from inside its sink would wait for a message it is
//! blocking. Everything else is per-member and lives in [`crate::subscriber`].

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

use slopdesk_agent::{ClaudeHookEvent, ClaudeStatus};
use slopdesk_hostpane::{PaneOutputStream, PtyProcess};
use slopdesk_muxnet::subchannel::SubChannel;
use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_muxsession::lifecycle::RebindVerdict;
use slopdesk_muxsession::resize_fold::{Attachment, Grid, PRIMARY_SUBSCRIBER};
use slopdesk_superwire::protocol::BlocksReply;
use slopdesk_wire::message::{ProjectGitStatus, WireMessage};
use slopdesk_wire::mux::flow::MuxFlowControl;
use slopdesk_wire::replay::ReplayBuffer;

use crate::detect::{Detect, DetectConfig};
use crate::evict::Eviction;
use crate::ingest::Ingest;
use crate::latches::PaneLatches;
use crate::metadata::{Asked, Metadata, MetadataPerformer, UnservedMetadata};
use crate::project::{IgnoreKeys, InlineResolve, KeyObserver, Project, ResolveExecutor};
use crate::resize::{RESIZE_DEBOUNCE, Resize, SIZE_SETTLE};
use crate::shared::{SessionLog, Shared};
use crate::snapshot::SnapshotPolicy;
use crate::subscriber::{
    Subscriber, run_control_relay, run_control_sender, run_data_sender, run_input_relay,
};
use crate::taps::{BlockTap, CloseTap, OutputTap, TapToken, Taps};
use crate::{detect, drain, facts, history, snapshot};

/// How long the exit thread waits for the read loop to reach EOF before shipping `.exit`.
///
/// The gate exists so the FINAL output tail is enqueued AHEAD of the exit barrier: `ended` is
/// called by the stream only after superd has drained every byte, so waiting on that latch is what
/// puts `.exit` after the last chunk. Bounded, so a wedged or paused read never holds exit delivery
/// open for ever.
const EOF_GATE_TIMEOUT: Duration = Duration::from_secs(2);

/// How long the exit thread waits for the drain to have SENT `.exit` before running `on_exit`.
///
/// `on_exit` triggers the teardown that closes the drain, so firing it early would drop the exit
/// code that is still queued. Bounded for the same reason the gate above is.
const EXIT_SENT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long the kill ladder waits after `SIGHUP`+`SIGTERM`, and again after `SIGKILL`.
const CHILD_EXIT_GRACE: Duration = Duration::from_millis(250);

/// What the session tells its owner.
///
/// One trait rather than a pair of closures for the reason [`SessionLog`] is one: the strict lint
/// set denies a struct with no `Debug`, and this is a field.
pub trait SessionObserver: Send + Sync + core::fmt::Debug {
    /// The child exited and its code is on the wire, or its window for getting there closed.
    ///
    /// Called from the exit thread, never under a lock this crate holds — the owner's handler is
    /// what tears the session down, and it must be free to do so.
    fn exited(&self, code: i32);
}

/// An observer that hears everything and does nothing.
#[derive(Debug, Clone, Copy)]
pub struct SilentObserver;

impl SessionObserver for SilentObserver {
    fn exited(&self, _code: i32) {}
}

/// What the pane tells its owner about the AGENT inside it.
///
/// Separate from [`SessionObserver`] because the two have different lifetimes and different
/// audiences: the exit handler is swapped by every detach and rebind (it names whoever currently
/// owns the pane's end), while this one is the SERVER's cross-pane supervision fan-out and is set
/// once, at spawn, for the pane's whole life. Merging them would make a detach silently re-point
/// the status stream at the detached store.
///
/// Called from whichever thread folded the transition — the foreground poll, the screen scan, the
/// hook feed or the ctl `report` — and always OUTSIDE the folds lock, because the implementor's
/// reaction is an NDJSON write to every subscriber and that must not serialise the next pane's
/// transition.
pub trait StatusObserver: Send + Sync + core::fmt::Debug {
    /// This pane's agent status moved to `status`.
    ///
    /// `quiet` marks the transition as BOOKKEEPING — a `/compact` boundary, an Esc-cancelled
    /// dialog, the screen watchdog correcting a hook block it outlasted. The status still moves
    /// everywhere it shows; it simply must not count as a turn somebody finished. The count itself
    /// is already folded before this is called, so an implementor never has to re-derive it — the
    /// flag is here for the observers that mint an unread badge.
    fn status_changed(&self, status: ClaudeStatus, quiet: bool);
}

/// A status observer that hears every transition and does nothing — the shape a pane with no server
/// above it takes.
#[derive(Debug, Clone, Copy)]
pub struct IgnoreStatus;

impl StatusObserver for IgnoreStatus {
    fn status_changed(&self, _status: ClaudeStatus, _quiet: bool) {}
}

/// What a session needs that it cannot decide for itself.
#[derive(Debug)]
pub struct SessionConfig {
    /// The pane's ring, already built with this host's caps and distiller. Built by the caller
    /// because the caps are environment-derived and the environment is the SERVER's to read.
    pub replay: ReplayBuffer,
    /// Where the session's lines go.
    pub log: Arc<dyn SessionLog>,
    /// Who hears about the exit.
    pub observer: Arc<dyn SessionObserver>,
    /// Who hears about the AGENT — the cross-pane supervision fan-out. See [`StatusObserver`].
    pub status: Arc<dyn StatusObserver>,
    /// Where in superd's ring the read loop starts.
    ///
    /// `0` for a fresh pane; a recorded cursor for a rebind; [`slopdesk_hostpane::FROM_NOW_ON`] for
    /// a pane whose backlog must not be replayed at all.
    pub resume_from: u64,
    /// How a reattach or a join renders the screen a client opens on. `None` replays raw history,
    /// which is what a caller with no screen model wants — see [`crate::snapshot`].
    pub snapshot: Option<Arc<dyn SnapshotPolicy>>,
    /// Whether the subscriber this session was OPENED for votes in the size fold.
    ///
    /// Resolved host-side from the workspace channel's client kind, never from anything the pane
    /// channel itself claims — a phone must not be able to declare itself a Mac.
    pub opened_size_passive: bool,
    /// The latest-wins window before a resolved grid reaches `TIOCSWINSZ`.
    pub resize_debounce: Duration,
    /// The longer window a contributor-set change arms.
    pub size_settle: Duration,
    /// Which of the pane's two detection loops run, and where the screen scan asks its question.
    pub detect: DetectConfig,
    /// Where the project-key ancestor walk runs — see [`ResolveExecutor`].
    pub resolve: Arc<dyn ResolveExecutor>,
    /// Who hears about a new project key. hostd wires the repo-watch refcounts here.
    pub project_keys: Arc<dyn KeyObserver>,
    /// Who runs the metadata verbs — see [`MetadataPerformer`]. Runs on [`Self::resolve`], which is
    /// the pane's ONE serial queue on purpose: a `cd`'s key walk and a `git status` must not fork
    /// behind each other.
    pub metadata: Arc<dyn MetadataPerformer>,
    /// How far a member may fall behind before it is dropped, and who drops it.
    ///
    /// [`Eviction::off`] by default, which is BOTH halves off: a caller with no wire to close a
    /// channel on evicts nobody and prices nothing. The threshold is a number the server hands in
    /// rather than an environment variable this crate reads, for the same reason [`Self::replay`]
    /// arrives already built with its caps.
    pub evict: Eviction,
    /// Whether superd segments this pane into command blocks.
    ///
    /// The same flag the spawn asked the tap for. It gates the block READS as well as the fold, so
    /// a pane whose tap was never installed answers "no blocks" rather than asking superd about a
    /// segmenter that is not running.
    pub blocks_enabled: bool,
}

impl SessionConfig {
    /// A configuration for a pane with a fresh ring, no snapshot policy and a VOTING opener.
    ///
    /// The two windows come from [`RESIZE_DEBOUNCE`] and [`SIZE_SETTLE`]; a test that wants a
    /// resize to land inside its own runtime overwrites them.
    #[must_use]
    pub fn new(log: Arc<dyn SessionLog>, observer: Arc<dyn SessionObserver>) -> Self {
        Self {
            replay: ReplayBuffer::new(),
            log,
            observer,
            status: Arc::new(IgnoreStatus),
            resume_from: 0,
            snapshot: None,
            opened_size_passive: false,
            resize_debounce: RESIZE_DEBOUNCE,
            size_settle: SIZE_SETTLE,
            detect: DetectConfig::off(),
            resolve: Arc::new(InlineResolve),
            project_keys: Arc::new(IgnoreKeys),
            metadata: Arc::new(UnservedMetadata),
            evict: Eviction::off(),
            blocks_enabled: false,
        }
    }
}

/// One pane, its members, and the threads between them.
#[derive(Debug)]
pub struct PaneSession {
    shared: Arc<Shared>,
    pty: Arc<PtyProcess>,
    /// The size fold, its one writer and its three timers.
    resize: Arc<Resize>,
    /// How a reattach or a join renders the screen a client opens on.
    snapshot: Option<Arc<dyn SnapshotPolicy>>,
    /// The pane's detection: the probes, the screen buffer, and the wake the teardown pulls.
    detect: Arc<Detect>,
    /// The cwd latch and the project-key walk behind it.
    project: Project,
    /// The three agent-control registries: output, close, block.
    taps: Arc<Taps>,
    /// The metadata RPC's bound, queue and performer.
    metadata: Metadata,
    /// Whether this pane is segmented into command blocks — see [`SessionConfig::blocks_enabled`].
    blocks_enabled: bool,
    /// `taskLock`'s remaining job, and only that: the objects. Every LATCH that used to sit beside
    /// them is `Lifecycle`'s.
    stream: Mutex<Option<Arc<PaneOutputStream>>>,
    /// The drain's handle, apart from the rest because it is the one thread a DETACH ends and a
    /// REBIND replaces. Keeping it in `threads` would leave the rebind unable to name the handle it
    /// has to join before starting the next one.
    drain_thread: Mutex<Option<JoinHandle<()>>>,
    threads: Mutex<Vec<JoinHandle<()>>>,
    /// How many times the teardown ladder has run to completion — the only thing a test can watch
    /// to know the whole path ran to the END rather than merely started.
    teardowns: AtomicUsize,
}

impl PaneSession {
    /// A session over `pty`, with nothing attached and no thread running.
    #[must_use]
    pub fn new(pty: Arc<PtyProcess>, config: SessionConfig) -> Arc<Self> {
        let shared = Arc::new(Shared::new(
            config.replay,
            MuxFlowControl::host_queue_capacity_bytes(),
            config.detect.done_to_idle,
            Arc::clone(&config.log),
            Arc::clone(&config.observer),
            Arc::clone(&config.status),
            config.evict.clone(),
        ));
        // Seed the resume cursor BEFORE anything can advance it. `record_offset` is monotone except
        // for the `FROM_NOW_ON` sentinel, which the first real offset replaces outright — so a pane
        // told to skip its backlog stays skipped until a chunk actually arrives, and a rebind's
        // recorded cursor can only move forward from here.
        shared.life.record_offset(config.resume_from);
        // Before the fold, because the fold INVALIDATES the screen grid on every applied geometry
        // change and so has to be able to name it.
        let detect = Arc::new(Detect::new(config.detect));
        let resize = Resize::new(
            Arc::clone(&pty),
            Arc::clone(&detect),
            config.opened_size_passive,
            config.resize_debounce,
            config.size_settle,
        );
        Arc::new(Self {
            shared,
            pty,
            resize,
            snapshot: config.snapshot,
            detect,
            project: Project::new(Arc::clone(&config.resolve), config.project_keys),
            taps: Arc::new(Taps::default()),
            // The SAME executor the project walk was handed, not another of the same type: one
            // serial queue per pane is what keeps two `cd`s and a `git status` in the order they
            // were asked in, and two queues would let a probe overtake the resolve that caused it.
            metadata: Metadata::new(config.resolve, config.metadata),
            blocks_enabled: config.blocks_enabled,
            stream: Mutex::new(None),
            drain_thread: Mutex::new(None),
            threads: Mutex::new(Vec::new()),
            teardowns: AtomicUsize::new(0),
        })
    }

    /// The resume cursor this session would re-open at.
    #[must_use]
    pub fn resume_offset(&self) -> u64 {
        self.shared.life.offset()
    }

    /// How many members are attached.
    #[must_use]
    pub fn member_count(&self) -> usize {
        self.shared.member_count()
    }

    /// Whether the child has been reaped.
    #[must_use]
    pub fn is_child_exited(&self) -> bool {
        self.pty.exit_code().is_some()
    }

    /// How many times the teardown ladder has run to completion.
    #[must_use]
    pub fn teardown_completions(&self) -> usize {
        self.teardowns.load(Ordering::Acquire)
    }

    /// How many of this pane's threads — session and member alike — have not RETURNED.
    ///
    /// Public because the leak it exists to catch is invisible from anywhere else: a subscriber
    /// retired mid-rebind is out of the roster while its sender may still be parked, so the leak is
    /// one thread per rebind and a test that attaches once cannot see it. Counting returns rather
    /// than joins is what lets a test ask without blocking on the answer.
    #[must_use]
    pub fn live_thread_count(&self) -> usize {
        self.shared.live_thread_count()
    }

    /// Adds a member and starts its three threads.
    ///
    /// The ORDER is the caller's, as `docs/59` step 3 settled it: reserve the id, register whatever
    /// names it, then join. A link that drops in that window stays attributable to the joiner.
    ///
    /// A member admitted here is a plain attach — the FIRST client of a pane, or a test's. A client
    /// arriving at a pane somebody else is already watching goes through [`Self::join`], which adds
    /// the state transfer and the fan-out switch on top of this same door.
    pub fn attach(
        self: &Arc<Self>,
        data: Arc<SubChannel>,
        data_inbound: Receiver<WireMessage>,
        control: Arc<SubChannel>,
        control_inbound: Receiver<WireMessage>,
        size_passive: bool,
    ) -> SubscriberId {
        let id = self.shared.reserve_subscriber_id();
        let subscriber = Subscriber::new(id, data, control);
        // Read the head BEFORE the roster admits this member. Every frame that can reach its lane is
        // sequenced after the admit, so it is numbered above this — read it after and a frame landing
        // in the window would be at or below the sender's cursor, and silently skipped.
        let head = self.shared.highest_seq();
        self.shared.admit(&subscriber, 0);
        self.resize.add_contributor(id, size_passive);
        self.shared.recompute_client_online();
        self.start_control_sender(&subscriber);
        self.start_relays(&subscriber, data_inbound, control_inbound);

        // A member that joins after the fan-out switch needs its own data sender, and `fan_out`'s
        // one roster walk is already behind it. Without this its lane is enqueued into by the drain
        // and drained by nobody: never-drop makes that an unbounded buffer with no owner, and the
        // member never sees a byte. `start_sender` settles the race with a concurrent `fan_out`.
        if self.shared.is_fanned_out() {
            self.start_data_sender(&subscriber, head);
        }

        id
    }

    /// Starts one member's CONTROL sender, which every path does FIRST.
    ///
    /// Before the drain can reach this member, and before a rebind restarts one: the drain's
    /// sniffed-control hand-off reads each member's queue, so a member the drain can already see
    /// with no sender to drain what it is handed would strand an OSC-0/2 title change until the
    /// next one happened to arrive. Starting it early costs nothing in the other direction — it
    /// parks on an empty lane until the first enqueue.
    fn start_control_sender(self: &Arc<Self>, subscriber: &Arc<Subscriber>) {
        let sender = Arc::clone(subscriber);
        self.launch_owned(subscriber, "slopdesk-control-send", move || {
            run_control_sender(&sender);
        });
    }

    /// Starts one member's two INBOUND relays.
    ///
    /// Last of the three on the join path, because until they exist the member cannot type — and a
    /// keystroke arriving before its state transfer has shipped would be echoed into a screen the
    /// client has not been given yet.
    fn start_relays(
        self: &Arc<Self>,
        subscriber: &Arc<Subscriber>,
        data_inbound: Receiver<WireMessage>,
        control_inbound: Receiver<WireMessage>,
    ) {
        let relay = Arc::clone(subscriber);
        let shared = Arc::clone(&self.shared);
        let pty = Arc::clone(&self.pty);
        let detect = Arc::clone(&self.detect);
        self.launch_owned(subscriber, "slopdesk-input-relay", move || {
            run_input_relay(&relay, &data_inbound, &shared, &pty, &detect);
        });

        let relay = Arc::clone(subscriber);
        let shared = Arc::clone(&self.shared);
        let resize = Arc::clone(&self.resize);
        self.launch_owned(subscriber, "slopdesk-control-relay", move || {
            run_control_relay(&relay, &control_inbound, &shared, &resize);
        });
    }

    /// Gives one member the data sender the fan-out path requires of it.
    ///
    /// Claims first and launches second, so a spawn that fails can give the claim back: a member
    /// marked as having a sender that does not exist would never be given one again, and its lane
    /// would fill for ever behind a thread that was never born.
    fn start_data_sender(&self, member: &Arc<Subscriber>, head: i64) {
        if !self.shared.start_sender(member.id, head) {
            return;
        }
        let sender = Arc::clone(member);
        let shared = Arc::clone(&self.shared);
        if !self.launch_owned(member, "slopdesk-data-send", move || {
            run_data_sender(&sender, &shared);
        }) {
            self.shared.clear_sender(member.id);
        }
    }

    /// Switches this pane to the fan-out path and gives every member a data sender.
    ///
    /// Separate from [`Self::attach`] because it is a decision about the DRAIN's mode rather than
    /// about a member: with one member the drain sends inline on its own thread, and the moment
    /// there are two it must not, or the slower peer's credit window would gate the faster one.
    pub fn fan_out(&self) {
        if !self.shared.begin_fan_out() {
            return;
        }
        // One head for the whole walk, read before it. Re-reading per member would hand a later
        // joiner a cursor above a frame already sitting in its lane.
        let head = self.shared.highest_seq();
        for member in self.shared.roster() {
            self.start_data_sender(&member, head);
        }
    }

    /// Seeds a prior life's transcript as this pane's FIRST output, before anything live.
    ///
    /// The restore rides the ordinary drain — one `.output` chunk, sequenced into this session's
    /// own ring, on the wire as frames indistinguishable from the shell's. That is what makes
    /// it a restore rather than a wire change: a client is handed history it can scroll, ack
    /// and be replayed from, and nothing downstream needs a second code path for it.
    ///
    /// Call it BEFORE [`Self::start`]. The ordering guarantee is the whole point — restored history
    /// must precede every live byte — and the read loop is what produces a live byte, so the window
    /// closes the moment `start` opens the stream. The Swift enqueued it inside `startRelay()` for
    /// the same reason, gated on the bounded queue already existing; here the queue exists from
    /// construction, so the call site is simply earlier.
    ///
    /// The bytes are MOVED, not copied: an accepted restore is up to the journal cap in size, and a
    /// caller that kept its own copy would pin that much for the pane's whole life. Empty is a
    /// no-op, so the ordinary "nothing to restore" answer needs no branch at the call site.
    pub fn seed_restored(&self, bytes: Vec<u8>) {
        if bytes.is_empty() {
            return;
        }
        self.shared.append_chunk(bytes, Vec::new());
    }

    /// Starts the pane: the drain, the read loop and the exit thread, in that order.
    ///
    /// The order is load-bearing at two points. The gate must exist before the read loop starts, or
    /// the first chunk is unaccounted; and the read loop must start before the exit thread parks,
    /// or a child that exits instantly is waited for by a thread whose EOF gate can never close.
    ///
    /// The one-time claim is `Lifecycle`'s, which serializes it — a second caller loses there
    /// rather than under a lock this type holds.
    pub fn start(self: &Arc<Self>) {
        if !self.shared.life.start() {
            return;
        }

        self.start_drain();

        // superd does the reading now: hostd's duplicate of the master is for writes, `TIOCSWINSZ`
        // and the two probes only. An unspawned pane's stream is EOF from the start, so nothing
        // below is conditional on a child existing.
        let sink = Arc::new(Ingest::new(
            Arc::clone(&self.shared),
            Arc::downgrade(&self.pty),
            Arc::clone(&self.detect),
            self.project.clone(),
            Arc::clone(&self.taps),
        ));
        let stream = Arc::new(self.pty.make_output_stream(self.shared.life.offset(), sink));
        // The gate's action, wired now that there is something to throttle. Weakly — see the
        // module note.
        self.shared.install_throttle(&stream);
        self.shared.life.stream_opened();
        *self.stream.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(&stream));
        stream.start();

        let shared = Arc::clone(&self.shared);
        let pty = Arc::clone(&self.pty);
        let taps = Arc::clone(&self.taps);
        self.launch("slopdesk-pane-exit", move || {
            let code = pty.wait_for_exit();
            // A teardown woke this rather than the child: the pane is being let go and its exit is
            // not this session's to announce.
            if shared.is_torn_down() {
                return;
            }
            // Gate the exit on the read loop having drained the master to EOF, so the FINAL output
            // tail is enqueued AHEAD of `.exit` on the shared queue.
            if !shared.await_eof(EOF_GATE_TIMEOUT) {
                shared.log.line(
                    "the read loop had not reached EOF when the exit gate expired — a late output tail will \
                     land after .exit rather than before it",
                );
            }
            // Between the EOF gate and the exit message, and that position IS the contract: an
            // orchestrator watching this pane has now been handed every output byte, and has not yet
            // been told the pane is gone. Ahead of `append_exit` rather than after it because the
            // exit rides a queue — a close fired afterwards would still be the SECOND thing the
            // watcher heard only by luck of the drain's timing.
            taps.notify_closed();
            shared.append_exit(code);
            // Wait until the drain actually SENT it before firing the observer, which is what
            // triggers the teardown that closes the drain. Otherwise a torn-down drain drops the
            // buffered exit code and the client never learns why its pane went quiet.
            if !shared.await_exit_sent(EXIT_SENT_TIMEOUT) {
                shared.log.line(
                    "the exit code was still unsent when its window closed — the teardown runs anyway \
                     rather than holding the pane open for a client that is not reading",
                );
            }
            // Read at FIRE time, never captured: detach installs the detached-store handler and
            // rebind installs the returning connection's, so whichever life the child dies in, the
            // CURRENT handler is the one that runs. A captured `Arc` would see the one this pane
            // started with — which after a reattach means killing a pane that had just come back.
            //
            // This thread is deliberately never cancelled and re-created by a rebind, either:
            // `wait_for_exit` parks a registration this crate cannot retire, so a second waiter
            // would resume BOTH and the pane would send a duplicate `.exit` per reattach cycle.
            shared.observer().exited(code);
        });

        self.start_detection();
    }

    /// Starts whichever detection loops this pane's gates asked for.
    ///
    /// Both survive a DETACH, deliberately: an agent working in a detached pane is exactly the case
    /// the supervision surface exists for, and a poll that stopped at detach would report the pane
    /// idle for the whole window. What the detach does take is the members, so an edge crossed
    /// while away broadcasts to nobody — and the rebind's re-assert is what tells the returning
    /// client what it missed.
    fn start_detection(self: &Arc<Self>) {
        if self.detect.polls() {
            let shared = Arc::clone(&self.shared);
            let pty = Arc::clone(&self.pty);
            let detect = Arc::clone(&self.detect);
            // The FIRST sample happens here rather than after the first interval: a pane that opens
            // with an agent already running would otherwise report nothing for a whole poll period,
            // which is the window a fresh split spends looking empty.
            Detect::sample_foreground(&shared, &pty);
            self.launch("slopdesk-pane-agent", move || detect.poll_loop(&shared, &pty));
        }
        if self.detect.scans() {
            let shared = Arc::clone(&self.shared);
            let pty = Arc::clone(&self.pty);
            let detect = Arc::clone(&self.detect);
            self.launch("slopdesk-pane-screen", move || detect.scan_loop(&shared, &pty));
        }
    }

    /// Starts the pane's ONE drain thread, remembering the handle a detach will have to join.
    fn start_drain(self: &Arc<Self>) {
        let shared = Arc::clone(&self.shared);
        match spawn(&self.shared, "slopdesk-pane-drain", move || drain::run(&shared)) {
            Ok(handle) => {
                *self.drain_thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(handle);
            },
            Err(error) => {
                self.shared
                    .log
                    .line(&format!("could not start slopdesk-pane-drain: {error}"));
            },
        }
    }

    // MARK: The ladders that change WHO is attached

    /// Admits a client to a pane somebody else is already watching.
    ///
    /// The whole difference from [`Self::attach`] is that there is an INCUMBENT, and everything
    /// below follows from not being allowed to cost it anything:
    ///
    /// 1. The screen is composed OUTSIDE the join lock. Rendering the model is an O(retained
    ///    history) walk — seconds on a pane with a full scrollback — and holding the drain's
    ///    ordering lock across it would stall the incumbent's output for that whole window.
    /// 2. [`Shared::admit_joiner`](crate::shared::Shared::admit_joiner) then does the atomic half
    ///    under that lock, bridging the render's gap with the frames sequenced while it ran.
    /// 3. The joiner's own data sender is started only AFTER the state transfer has shipped, so the
    ///    replay owns its channel until it is done and live frames queue behind it in order.
    ///
    /// `reserved` is the id the caller took from [`Self::reserve_subscriber_id`] inside the same
    /// critical section that registered this channel's key. The key is visible to every per-client
    /// teardown path the instant it is written, but the member does not exist until this returns —
    /// so the reservation is what makes a link dropping in that window attributable to the JOINER
    /// rather than to the incumbent it would otherwise retire.
    ///
    /// `None` when the pair is already dead, when the session is detached, or when the set emptied
    /// while the render ran. The set is untouched in every one of those, so the caller may refuse
    /// the channel rather than ack a pane the joiner is not on.
    pub fn join(
        self: &Arc<Self>,
        reserved: Option<SubscriberId>,
        data: Arc<SubChannel>,
        data_inbound: Receiver<WireMessage>,
        control: Arc<SubChannel>,
        control_inbound: Receiver<WireMessage>,
        size_passive: bool,
    ) -> Option<SubscriberId> {
        if data.is_finished() || control.is_finished() {
            return None;
        }
        // A detached session has no drain to join; that is `rebind`'s job. Re-checked inside
        // `admit_joiner` under the join lock — this early exit only avoids paying for a render that
        // could not be used.
        if self.shared.life.is_detached() {
            return None;
        }
        let (rendered, composed_through) =
            snapshot::compose_join(&self.shared, &self.pty, self.snapshot.as_ref());
        let admission = self.shared.admit_joiner(reserved, composed_through, move |id| {
            Subscriber::new(id, data, control)
        })?;
        let member = Arc::clone(&admission.subscriber);
        let id = member.id;

        // The drain fans out from here on, so every INCUMBENT needs a sender of its own — with one
        // member the drain sends inline, and the moment there are two it must not, or the slower
        // peer's credit window would gate the faster one. Started after the lock rather than under
        // it: a frame sequenced in this window queues in a lane whose sender is a microsecond away,
        // and `start_sender` is the arbiter either way.
        for incumbent in &admission.incumbents {
            self.start_data_sender(incumbent, admission.head);
        }
        self.resize.add_contributor(id, size_passive);
        self.start_control_sender(&member);

        // The state transfer, on the joiner's own channel. Its data sender does not exist yet, so
        // this owns the channel until it is done and the live frames accumulating in its lane land
        // strictly after — the rendered screen, then the bytes produced while it rendered, then
        // everything since, with no hole and nothing twice.
        for message in rendered.iter().chain(admission.catch_up.iter()) {
            if member.data.send(message).is_err() {
                break;
            }
        }
        self.start_data_sender(&member, admission.head);

        // Join-scoped re-asserts, addressed to the new member only: the incumbents were told these
        // truths when they happened, and re-telling them would flood a client that is up to date.
        self.reassert_to(&member);

        self.start_relays(&member, data_inbound, control_inbound);
        self.shared.recompute_client_online();
        Some(id)
    }

    /// Non-destructively detaches this session from its current client connection.
    ///
    /// **The subscription is DROPPED, and the resume cursor is what survives.** The pane's bytes
    /// while away are superd's ring — absolute-offset addressed, with announced eviction — so hostd
    /// buffers none of them. The shell keeps running at full speed: superd's pump keeps draining
    /// the master whether or not anyone is subscribed, and losing the last subscriber CLEARS
    /// the pause (`docs/51` §6.5), so a detached agent is never the one that blocks. Pausing
    /// the read loop instead — the shape before — transitively backpressured the SHELL through
    /// the kernel PTY buffer the moment the host-side queue filled, and the detached budget
    /// only chose how long an agent ran before it froze.
    ///
    /// `on_detached_exit` is installed BEFORE anything else, and on the idempotent second call it
    /// is the only thing that happens: a shell exiting while this session is in the store must
    /// reach the store's handler and not a connection that is gone.
    ///
    /// The out-FIFO is KEPT. Its frames were never sequenced, so no replay can recover them, and
    /// dropping them would leak their gate accounting too — a ≥64 KiB residue leaves the read loop
    /// paused for ever. [`Self::rebind`] restarts a drain over the same queue.
    pub fn detach(self: &Arc<Self>, on_detached_exit: Arc<dyn SessionObserver>) {
        // The flag flip and the "is this call the one that tears down" answer are `Lifecycle`'s,
        // taken FIRST because the ladder serializes itself.
        let verdict = self.shared.life.detach();
        self.shared.set_observer(on_detached_exit);
        // Idempotence: a second detach — a failed rebind's re-park racing link-down's own — is a
        // no-op past the handler refresh above. The members are already retired, the drain already
        // stopped and the subscription already dropped; re-running this would only churn state
        // another thread may be reading, and would re-read a cursor that has stopped advancing.
        if !verdict.first {
            return;
        }
        // Retire every member. The resize contributors are DELIBERATELY left in the fold: a reattach
        // swaps the sub-channels while the same PTY lives on, and forgetting the standing offer here
        // would snap the pane back to its spawn size until the returning client sent a new one.
        for member in self.shared.roster() {
            member.retire();
            let _emptied = self.shared.retire(&member);
            member.join_threads();
        }
        // The set is empty, so the SESSION-wide half goes too. This is the teardown that belongs to
        // the set EMPTYING — a lone member losing its channel does not get to stop the drain for
        // anyone else.
        self.shared.close_drain();
        self.join_drain();
        // Hand the pane's detached window back to superd. `stop()` is PERMANENT for a
        // `PaneOutputStream`, which is why the rebind mints a NEW one at the resume cursor rather
        // than reviving this one; both go through `PaneOutputStream`, so neither is a second `read`
        // on the master.
        let stream = if verdict.stop_stream {
            self.stream.lock().unwrap_or_else(PoisonError::into_inner).take()
        } else {
            None
        };
        if let Some(stream) = stream {
            stream.stop();
        }
        // Nobody holds the pane, which the ring's retention still wants to know: with no client
        // online its offline gate bounds what is kept for a return. There is no read loop left to
        // pause, so this is accounting only.
        self.shared.recompute_client_online();
    }

    /// Rebinds this session to a fresh pair of sub-channels from a returning client.
    ///
    /// Re-opens the supervised output at the cursor [`Self::detach`] left. The resumed bytes enter
    /// the queue exactly as live ones do, are sequenced at drain time, and land after the caller's
    /// [`Self::replay_tail`] — fresh seqs above every replayed seq, so byte order is preserved. A
    /// resume older than superd's ring is LOSSY and announced as such; the window is bounded by the
    /// ring and the client's own repaint covers the seam.
    ///
    /// `observer` is taken here rather than assigned afterwards, and that is the whole point of the
    /// parameter: it is installed before the drain restarts, so the detached-exit handler can never
    /// be the one a reattached pane's exit fires. A caller that assigns after this returns reopens
    /// the window this closes.
    ///
    /// `false` when the session was not detached, or when the returning pair is already dead —
    /// nothing is changed in either case. Refusing rather than silently no-op'ing is what keeps the
    /// loser of a concurrent double-reattach from believing it owns the pane.
    pub fn rebind(
        self: &Arc<Self>,
        data: Arc<SubChannel>,
        data_inbound: Receiver<WireMessage>,
        control: Arc<SubChannel>,
        control_inbound: Receiver<WireMessage>,
        observer: Arc<dyn SessionObserver>,
    ) -> bool {
        let ladder = self.shared.life.rebind(data.is_finished(), control.is_finished());
        let RebindVerdict::Proceed { resume_from } = ladder else {
            return false;
        };
        // Back to ONE member, so back to the inline send — see `end_fan_out` for what leaving the
        // flag set would cost the returning client. Safe precisely because the set EMPTIED.
        self.shared.end_fan_out();
        self.shared.set_observer(observer);
        // The returning client REPLACES the member the detach retired: a subscriber IS its channel
        // pair, so a new pair is a new member under the same id, never a swap underneath the threads
        // a departed one owned.
        let member = Subscriber::new(PRIMARY_SUBSCRIBER, data, control);
        self.shared.admit(&member, 0);

        // Re-open the supervised output at the cursor detach left behind. This is the whole of the
        // detached-window recovery: superd kept pumping the master into its ring the entire time,
        // and a subscribe at the resume cursor replays exactly the bytes produced since. It is a
        // `subscribe`, not a `read` — superd owns the only reader on this master, and a second one
        // would STEAL bytes from the pane rather than observe them.
        //
        // The GATE is not rebuilt. It lives in `Shared` and outlived the detach holding its own
        // accounting, so the bytes the stopped drain never shipped are still counted and the books
        // still sum to zero once the restarted drain ships them. `install_throttle` only re-points
        // the `Weak` at the new stream. The Swift had to CARRY the outstanding count onto a fresh
        // gate because the gate's sink named the stream being stopped; ownership dissolves that.
        let resumed = resume_from.map(|offset| {
            let sink = Arc::new(Ingest::new(
                Arc::clone(&self.shared),
                Arc::downgrade(&self.pty),
                Arc::clone(&self.detect),
                self.project.clone(),
                Arc::clone(&self.taps),
            ));
            let stream = Arc::new(self.pty.make_output_stream(offset, sink));
            self.shared.install_throttle(&stream);
            *self.stream.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(&stream));
            stream
        });

        self.start_control_sender(&member);
        self.shared.reopen_drain();
        self.start_drain();
        // Kick the restarted drain ONCE if unsent frames are already waiting: their producer-side
        // wakes landed on the thread detach ended, and a shell that has gone idle since produces no
        // future chunk to re-wake this one. Without it the carried frames — and their gate
        // accounting — would sit undelivered until the pane happened to speak again.
        let _carried = self.shared.kick_drain();

        // Re-establish the control-only truths on reattach, for the same reason a join gets them:
        // none of them is in the replayed byte stream, and the returning client reset its mirrors.
        self.reassert_to(&member);

        self.start_relays(&member, data_inbound, control_inbound);
        // Somebody holds the pane again, so this reads TRUE and the offline gate clears. Ordered
        // before the stream starts, so the gate's replay-pause source is already at its attached
        // value when the first resumed chunk lands.
        self.shared.recompute_client_online();
        if let Some(stream) = resumed {
            stream.start();
        }
        true
    }

    /// Pumps the retained tail above `after` onto `channel` — the reconnect replay that brings a
    /// returning client up to date.
    ///
    /// Called BEFORE [`Self::rebind`] starts the live drain, so the tail is delivered in order
    /// without interleaving live output. Answers whether the replay was a RENDERED snapshot: the
    /// caller's redraw-jiggle workaround is unnecessary then, because every row the app believes is
    /// painted IS painted.
    pub fn replay_tail(&self, after: i64, channel: &SubChannel) -> bool {
        let (messages, composed) =
            snapshot::replay_tail(&self.shared, &self.pty, self.snapshot.as_ref(), after);
        for message in &messages {
            if channel.send(message).is_err() {
                break;
            }
        }
        composed
    }

    /// Retires ONE member and reports whether the set is now EMPTY.
    ///
    /// Refcounted, deliberately: with two clients on one pane, one closing its lid must not engage
    /// the offline gate that pauses the drain — the other client's pane would go dead-quiet while
    /// the shell keeps producing. The session-wide teardown belongs to the set EMPTYING, and the
    /// caller owns that decision.
    pub fn remove_subscriber(self: &Arc<Self>, id: SubscriberId) -> bool {
        let Some(member) = self.shared.member(id) else {
            return self.shared.member_count() == 0;
        };
        member.retire();
        let emptied = self.shared.retire(&member);
        self.resize.remove_contributor(id);
        // Recomputed from the SET, never asserted: with somebody still holding the pane this reads
        // TRUE and the offline gate stays clear, which is the whole difference between a refcounted
        // leave and a detach. Only an emptied set reads false.
        self.shared.recompute_client_online();
        self.shared.release_retention_to_minimum();
        emptied
    }

    /// Reserves the id a pending join will enter the set under, before the join runs.
    ///
    /// See [`Self::join`] for why the reservation and the caller's key registration must share one
    /// critical section. A reservation the join never uses simply skips an id.
    #[must_use]
    pub fn reserve_subscriber_id(&self) -> SubscriberId {
        self.shared.reserve_subscriber_id()
    }

    /// The highest sequence number this session has ever assigned — the ceiling of any honest
    /// resume verdict.
    ///
    /// A reattach needs it because a session's numbering is a property of the SESSION OBJECT, and
    /// an adopted pane is a new object around an old shell: its buffer starts at zero while the
    /// client coming back to it is warm and remembers thousands.
    #[must_use]
    pub fn highest_assigned_seq(&self) -> i64 {
        self.shared.highest_seq()
    }

    /// Whether this session is parked in the detached store.
    #[must_use]
    pub fn is_detached(&self) -> bool {
        self.shared.life.is_detached()
    }

    // MARK: The size fold

    /// Records one client's latest size offer. Debounced — see [`crate::resize`].
    pub fn offer_size(&self, subscriber: SubscriberId, cols: u16, rows: u16, px: u16, py: u16) {
        self.resize.offer(subscriber, Grid { cols, rows, px, py });
    }

    /// Installs the ctl socket's size override and applies it at once.
    pub fn set_ctl_size(&self, cols: u16, rows: u16) {
        self.resize.set_ctl_override(Grid {
            cols,
            rows,
            px: 0,
            py: 0,
        });
    }

    /// The grid the fold resolved for this pane, as the roster publishes it.
    #[must_use]
    pub fn resolved_grid(&self) -> (u16, u16) {
        self.resize.resolved_grid()
    }

    /// Every contributor's standing offer, in subscriber order — what a client turns into "who is
    /// clamping this pane".
    #[must_use]
    pub fn size_contributions(&self) -> Vec<Attachment> {
        self.resize.attachments()
    }

    /// How many delayed redraw nudges this pane has scheduled, ever. A regression seam: the nudge
    /// itself is a `SIGWINCH` to somebody else's process group, which nothing this side of the
    /// kernel can observe.
    #[must_use]
    pub fn scheduled_redraw_nudges(&self) -> u64 {
        self.resize.scheduled_nudges()
    }

    /// Admits `subscriber` to the contributing set, at the passivity its CONNECTION resolved.
    ///
    /// [`Self::attach`] and [`Self::join`] each do this for the member they add, so the only caller
    /// left is the one that adds no member: a REATTACH replaces the primary the detach retired,
    /// under the same id, so nothing in [`Self::rebind`] would otherwise re-file it — and a
    /// returning client that contributed nothing would be clamped by whoever else is watching,
    /// at a size its own window never asked for. Passivity is re-resolved rather than
    /// remembered because the returning device may not be the one that left: a Mac's pane
    /// picked up on a phone.
    pub fn add_resize_contributor(&self, subscriber: SubscriberId, size_passive: bool) {
        self.resize.add_contributor(subscriber, size_passive);
    }

    /// Makes the foreground program repaint, after a reattach handed it a fresh surface.
    ///
    /// A returning client's terminal is empty of buffered output, so without this the pane stays
    /// blank until the user presses a key. Which of the two signals it earns is the CALLER's
    /// verdict — [`slopdesk_muxsession::open_route::redraw`] — because it turns on what the replay
    /// was, and this pane does not know. What lives here is the HOLD, which is a fact about the
    /// program rather than about the reattach: a differential renderer ignores a same-size
    /// `SIGWINCH` for rows it believes are painted, so only a real size change forces the
    /// re-layout, and the two edges have to be far enough apart for the app's event loop to observe
    /// the intermediate size or the pair coalesces into "unchanged".
    ///
    /// BLOCKING for the length of that hold. Called off the caller's own delayed thread.
    pub fn redraw(&self, jiggle: bool) {
        /// Long enough for a full-screen program's event loop to see the intermediate size.
        const JIGGLE_HOLD: Duration = Duration::from_millis(200);

        let taken = if jiggle {
            self.pty.begin_redraw_jiggle()
        } else {
            None
        };
        if let Some(token) = taken {
            std::thread::sleep(JIGGLE_HOLD);
            self.pty.end_redraw_jiggle(token);
        } else {
            self.pty.nudge_redraw();
        }
    }

    /// Drops `subscriber` from the contributing set.
    ///
    /// The unwind half of a JOIN that reserved an id and then could not use it: the reservation is
    /// visible to a workspace `subscribe` landing mid-join, which registers it as a contributor,
    /// and a phantom would then clamp the pane for the rest of its life with no window behind
    /// it. A pane whose set EMPTIES keeps its last size rather than snapping back to 80×24 —
    /// `docs/45` §8.3.
    pub fn remove_resize_contributor(&self, subscriber: SubscriberId) {
        self.resize.remove_contributor(subscriber);
    }

    /// Ends this pane: the teardown, WITH the child.
    pub fn shutdown(&self) {
        self.teardown(true);
    }

    /// Lets this pane GO: the same teardown, but the child is neither signalled nor waited for and
    /// superd is never told the pane is over.
    ///
    /// ⚠️ hostd-lifecycle ONLY. The distinction is the entire product change behind `docs/51`:
    /// "this daemon is going away" and "this pane is over" used to be the same path, so restarting
    /// the host cost the user every running agent. Now hostd drops its duplicate of the master and
    /// exits; superd still holds the original, the shell never sees a `SIGHUP`, and the next hostd
    /// adopts the pane back.
    pub fn relinquish(&self) {
        // The stream is stopped FIRST: a pane being let go is a pane in mid-sentence and its
        // subscriber is going away. Idempotent — the teardown stops it again a moment later.
        self.stop_stream();
        self.teardown(false);
    }

    /// Unsubscribes this pane's supervised output without touching the child.
    fn stop_stream(&self) {
        let stream = self.stream.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(stream) = stream {
            stream.stop();
        }
    }

    /// The teardown ladder, in the one order that ends green.
    fn teardown(&self, kill_child: bool) {
        self.shared.mark_torn_down();
        self.stop_stream();
        // Nobody holds a dead pane at a size, and no timer may still be pending against it. The
        // fold's GENERATION is deliberately not rewound by `clear_members` — a body already past its
        // sleep must not find its stale generation matching a fresh one — and `stop` then makes the
        // question moot by dropping every pending body and joining the thread that would run them.
        self.resize.clear_members();
        self.resize.stop();
        // Both detection loops park on a condvar rather than sleeping, precisely so this is
        // immediate: a `thread::sleep` would hold the teardown for up to the scan interval — which
        // the ENGINE chooses, not this crate — on every pane the host is closing.
        self.detect.stop();
        // The roster, snapshotted BEFORE anything is closed. Every close below is what makes some
        // relay return, and a relay's last act is to retire its own member — so a roster read after
        // the closes would be missing exactly the members whose threads are still finishing, and
        // those handles would be dropped unjoined.
        let members = self.shared.roster();
        // The drain returns rather than parking again, and every member's two senders return with
        // it. MEMBERSHIP is left alone: the session is dying, and a torn-down relay is not the same
        // statement as "nobody holds this pane", which is what an empty roster says to the online
        // recompute and to the size fold.
        self.shared.close_drain();
        for member in &members {
            member.close_lanes();
            member.data.finish();
            member.control.finish();
        }
        // Release both latches so a parked exit thread returns at once rather than waiting out its
        // timeout, and unpark one that is still waiting on the child — on the kill path below the
        // reaper would have woken it anyway, and on the relinquish path nothing ever would.
        self.shared.signal_eof();
        self.shared.signal_exit_sent();
        self.pty.complete_exit_from_supervisor_loss();

        if kill_child {
            self.end_child();
            // The close is announced HERE and nowhere earlier in this ladder, because this is the
            // first point at which the trait's own sentence is true: the stream was unsubscribed at
            // the top, so every byte hostd will ever see has already reached every output tap; the
            // EOF latch was released a few lines up; and `end_child` has just reaped the child. An
            // announcement before the signal would tell an orchestrator its agent was gone while the
            // shell was still running, which is the same lie the relinquish path is silent to avoid.
            //
            // Which is why a `relinquish` says NOTHING. The pane is not over: superd still holds the
            // master, the shell never sees a `SIGHUP`, and the next hostd adopts it back. Nothing
            // waits on the silence either — hostd is exiting, so a `subscribe` pump ends on its own
            // socket regardless.
            //
            // Idempotent with the exit thread's call, which is the announcer on the path where the
            // CHILD ends first — there the exit thread runs its EOF gate and fires ahead of `.exit`,
            // and reaches this ladder afterwards to find the latch already thrown.
            self.taps.notify_closed();
        }

        // Quiesce the PTY WRITER before closing the master. Every input write is a blocking
        // `write(2)`; close the gate, then wait for an in-flight one to COMPLETE — otherwise the
        // freed fd number could be recycled by a concurrent `openpty` and the stale write would
        // inject bytes into an unrelated pane. Bounded, and the TIMEOUT decides the close: a drain
        // that did not finish keeps hostd's duplicate OPEN. One leaked fd on a pane nobody could
        // type into anyway, against a daemon that cannot exit or a pane that receives another's
        // keystrokes.
        //
        // The bound differs by path for the reason the child does: on the kill path the child is
        // already dead, so a write parked on a full kernel buffer returns `EIO` as soon as the
        // slave side is gone. On the relinquish path the child is alive BY DESIGN and a foreground
        // program that is not reading its tty can hold a large paste in the kernel for as long as
        // it likes — and every one of those is a pane `HostServer::stop` waits on.
        self.shared.close_input_gate();
        let quiet = self.shared.await_input_quiet(if kill_child {
            Duration::from_secs(5)
        } else {
            Duration::from_secs(2)
        });
        if quiet {
            self.pty.close_master();
        } else {
            self.shared.log.line(
                "an input write is still parked in the kernel — hostd's duplicate of the master is left \
                 open rather than closed under it. The shell keeps running under superd; the fd goes when \
                 this process does",
            );
        }

        self.join_drain();
        self.join_threads(&members);
        self.teardowns.fetch_add(1, Ordering::AcqRel);
    }

    /// Joins the drain thread, if one is running and it is not the caller.
    ///
    /// The skip is the same one [`Self::join_threads`] makes and for the same reason: a teardown
    /// reached from inside the drain would join the thread it is running on.
    fn join_drain(&self) {
        let handle = self
            .drain_thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let Some(handle) = handle else { return };
        if handle.thread().id() == std::thread::current().id() {
            *self.drain_thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(handle);
            return;
        }
        drop(handle.join());
    }

    /// The DESTROY-path child termination ladder.
    ///
    /// `SIGHUP` first — an interactive shell treats it as "terminal closed" and persists its
    /// history before exiting, where it IGNORES `SIGTERM` and a `SIGKILL` would discard everything
    /// typed in this pane since it opened — plus `SIGTERM` for children that catch it; then a
    /// bounded wait; then `SIGKILL`; and only if all of that failed, `release`.
    ///
    /// `release` is the authoritative end — superd drops its own master and kills — and it is
    /// issued ONLY here, after the whole ladder failed. On the ordinary path the child is already
    /// dead and a release would race the reaper for the same pane. It is also necessarily LAST:
    /// the client forgets the pane's sink and its exit handler before the verb goes out, so
    /// anything still waiting on a notice after one waits for ever.
    fn end_child(&self) {
        self.pty.hangup();
        self.pty.terminate();
        if self.pty.wait_until_exited(CHILD_EXIT_GRACE) {
            return;
        }
        self.pty.force_terminate();
        if self.pty.wait_until_exited(CHILD_EXIT_GRACE) {
            return;
        }
        // Every signal above travelled the supervisor socket, and a signal that never arrived
        // leaves the child running with nothing left to end it: the user closes a tab, the agent
        // behind it keeps going, and the next adoption hands the closed tab back, live.
        if !self.pty.release(true) {
            self.shared.log.line(
                "the child survived SIGHUP, SIGTERM and SIGKILL and superd could not be reached to release \
                 it — the shell is still running under superd and can be ended with `slopdesk-ctl`",
            );
        }
    }

    /// Starts a thread this SESSION owns, or says why it could not.
    fn launch(&self, name: &str, body: impl FnOnce() + Send + 'static) -> bool {
        match spawn(&self.shared, name, body) {
            Ok(handle) => {
                self.threads
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(handle);
                true
            },
            Err(error) => {
                self.shared.log.line(&format!("could not start {name}: {error}"));
                false
            },
        }
    }

    /// Starts a thread a MEMBER owns, or says why it could not.
    fn launch_owned(
        &self,
        owner: &Arc<Subscriber>,
        name: &str,
        body: impl FnOnce() + Send + 'static,
    ) -> bool {
        match spawn(&self.shared, name, body) {
            Ok(handle) => {
                owner.adopt(handle);
                true
            },
            Err(error) => {
                self.shared.log.line(&format!("could not start {name}: {error}"));
                false
            },
        }
    }

    /// Joins every thread this session and its members own, skipping any belonging to the caller.
    ///
    /// The skip is not a nicety: the exit thread's observer is what usually calls `shutdown`, so
    /// the teardown routinely runs ON one of the threads it is joining.
    fn join_threads(&self, members: &[Arc<Subscriber>]) {
        for member in members {
            member.join_threads();
        }
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

/// Hands a pane-wide control fact to every member's sender.
///
/// A free function on the session rather than a method on `Shared` would put the roster walk in two
/// places; it is `Shared`'s because that is where the roster is.
impl PaneSession {
    /// Tells everyone holding this pane one control fact.
    pub fn broadcast(&self, messages: &[WireMessage]) {
        self.shared.broadcast_control(messages);
    }

    /// One repo's git summary, delivered iff this pane is sectioned under that repo.
    ///
    /// The host's type-35 fan-in calls this on every live pane and lets the latch decide. The
    /// compare and the send are one statement here for the reason [`Self::is_under_project`] gives:
    /// a caller that fetched the key to compare it itself would be comparing a value that may have
    /// moved. A detached pane is not special-cased — its members' senders are the wiped control-out
    /// the reconnect pull catches up, so the push costs nothing and the rule stays one rule.
    pub fn push_project_git_status(&self, status: &ProjectGitStatus) {
        if !self.is_under_project(&status.repo_root) {
            return;
        }
        self.shared
            .broadcast_control(&[WireMessage::ProjectGitStatus(status.clone())]);
    }

    /// The same backfill, addressed to ONE member — what a join and a rebind want.
    ///
    /// Addressed rather than broadcast because a re-assert is a fact about what THAT client has yet
    /// to be told, not a pane-wide edge: telling the incumbents again would rebuild a navigator
    /// that is already correct.
    fn resend_blocks_to(&self, member: &Arc<Subscriber>) {
        let Some(messages) = self.block_backfill() else {
            return;
        };
        member.enqueue_control(messages);
    }

    /// Everything an ARRIVING member has yet to be told, in the one order that lands.
    ///
    /// Every fact here is control-only and edge-triggered: none of it is in the replayed output
    /// bytes, and a client resets its mirrors on connect. So without this burst a `sleep 300`, a
    /// working agent, an open OSC 9;4 spinner or — worst — a `sudo` password prompt that spans the
    /// arrival leaves the client showing nothing, and in the last case leaves its automatic Secure
    /// Keyboard Entry disengaged for the rest of the entry.
    ///
    /// The order is the ladder's, and two steps of it are load-bearing:
    ///
    /// 1. **Echo first**, because it is the one whose absence is a security consequence rather than
    ///    a cosmetic one, and because it needs no lock the rest of the ladder holds.
    /// 2. **The detector's re-assert splices BETWEEN the truths' two halves**, at the position the
    ///    Swift ladder used: `reestablish_head` is the running/progress pair, then the agent's own
    ///    status, then `reestablish_tail`, whose last entry is the title. Title last is the other
    ///    load-bearing step — the client judges a title's freshness against the command-start stamp
    ///    the head just republished, and a title that arrived first loses that comparison for the
    ///    rest of the session.
    ///
    /// The blocks go last, being the only part that is a round trip rather than a latch read.
    fn reassert_to(&self, member: &Arc<Subscriber>) {
        if let Some(echo) = Detect::reassert_echo(&self.shared, &self.pty) {
            member.enqueue_control(vec![echo]);
        }
        // ONE acquisition for the whole ladder: the two halves and the detector's splice have to
        // describe the same instant, and a status paired with a title from either side of a fold is
        // exactly the mismatch keeping the detector under this lock exists to prevent.
        let messages = self.shared.with_folds(|folds| {
            let mut ladder = Vec::new();
            for entry in folds.truths.reestablish_head() {
                ladder.extend(facts::reassert_message(&folds.truths, entry));
            }
            ladder.extend(detect::emitted(&folds.detector.reestablish_on_reattach()));
            for entry in folds.truths.reestablish_tail() {
                ladder.extend(facts::reassert_message(&folds.truths, entry));
            }
            ladder
        });
        if !messages.is_empty() {
            member.enqueue_control(messages);
        }
        self.resend_blocks_to(member);
    }

    /// The pane's held blocks as control messages, through the ONE constructor that keeps a re-sent
    /// block and a live one from disagreeing about a field.
    fn block_backfill(&self) -> Option<Vec<WireMessage>> {
        // The gate the FOLD already honours, honoured on the read side too. Without it every
        // arrival on a pane with no segmenter spends a blocking superd round trip to be told there
        // are no blocks — the wire is identical either way, so this is cost rather than behaviour,
        // and it is cost on the one path a client is waiting on.
        if !self.blocks_enabled {
            return None;
        }
        let blocks = self.pty.block_snapshot()?;
        Some(blocks.iter().map(facts::block_message).collect())
    }
}

/// The pane as the agent-control surface sees it: what is true right now, and the two verbs that
/// change it.
///
/// Every fact below is already published as an edge-triggered control message; these read the value
/// that edge left behind, which is what lets a caller who was not listening at the instant of the
/// edge still be told what is true. Each is ONE acquisition of the fold lock, and the ones that
/// return a pair are a pair for that reason: two separate reads could interleave a transition and
/// hand back a fresh status beside a stale label.
impl PaneSession {
    /// Injects bytes into the PTY on the control plane's behalf.
    ///
    /// Fire-and-forget, and it takes the SAME gate a client keystroke does — the teardown drains
    /// one counter, and an injection that escaped it could land on a recycled fd. Injected keys
    /// are the human's proxy (the supervision cockpit routes a dialog answer down this verb),
    /// so they fold through the detector as an unblock edge exactly as a typed key does.
    pub fn write_for_control(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        if self.shared.begin_input_write() {
            if let Err(error) = self.pty.write(bytes) {
                self.shared
                    .log
                    .line(&format!("pane control-plane write failed: {error}"));
            }
            self.shared.end_input_write();
        }
        self.detect.fold_input(&self.shared, bytes);
    }

    /// The shell's pid, or `-1` once superd has taken the record away.
    ///
    /// `-1` rather than an `Option` because that is what the readouts downstream of it already
    /// spell — a pane list carries an integer per row, and a caller with no pid to show prints the
    /// same sentinel the Swift did.
    #[must_use]
    pub fn pid(&self) -> i32 {
        self.pty.pid().unwrap_or(-1)
    }

    /// The last OSC-sniffed window title, empty until one arrives.
    #[must_use]
    pub fn title(&self) -> String {
        self.shared.with_truths(|truths| String::from(truths.title()))
    }

    /// When the CURRENT command block opened, `None` at a prompt — the verdict's other half.
    #[must_use]
    pub fn command_running_since(&self) -> Option<f64> {
        self.shared.with_truths(|truths| truths.command_running_since())
    }

    /// The host's own open command block: the pane's running command line, `None` at a prompt or
    /// with block tracking off.
    ///
    /// The one fact of this group a client cannot reproduce. A client's running command comes from
    /// its own materialized block model, so a client that has rendered zero bytes has none at all
    /// and its sidebar row falls back to the raw command line — publishing the HOST's block is
    /// what lets the host alone render that row.
    #[must_use]
    pub fn running_command(&self) -> Option<String> {
        self.shared
            .with_truths(|truths| truths.running_command().map(String::from))
    }

    /// The freshest host-observed cwd, `None` until one is derived.
    #[must_use]
    pub fn cwd(&self) -> Option<String> {
        self.shared.with_truths(|truths| truths.cwd().map(String::from))
    }

    /// The freshest By-Project key — type 34's current value.
    #[must_use]
    pub fn project_key(&self) -> Option<String> {
        self.shared
            .with_truths(|truths| truths.project_key().map(String::from))
    }

    /// Whether this pane is currently sectioned under `repo_root`.
    ///
    /// The comparison stays inside this crate on purpose: it is a latch read, and a caller that
    /// fetched the key to compare it itself would be doing the compare against a value that may
    /// have moved. hostd's type-35 fan-in asks this question per pane and pushes only to the
    /// matches.
    #[must_use]
    pub fn is_under_project(&self, repo_root: &str) -> bool {
        self.shared
            .with_truths(|truths| truths.project_key_matches(repo_root))
    }

    /// The freshest OSC 9;4 progress pair, `None` when cleared or never reported.
    #[must_use]
    pub fn progress(&self) -> Option<(u8, u8)> {
        self.shared.with_truths(|truths| truths.progress())
    }

    /// The last completed command's exit code, `None` until the first code-carrying `D`.
    #[must_use]
    pub fn last_exit_code(&self) -> Option<i32> {
        self.shared.with_truths(|truths| truths.last_exit())
    }

    /// The host-measured duration of the last completed command, `None` until the first `D`.
    #[must_use]
    pub fn last_duration_ms(&self) -> Option<u32> {
        self.shared.with_truths(|truths| truths.last_duration())
    }

    /// How many `working → done` edges this pane has produced.
    #[must_use]
    pub fn completion_epoch(&self) -> u32 {
        self.shared.with_truths(|truths| truths.completion_epoch())
    }

    /// The rolled-up agent status, and its human label, in ONE acquisition.
    ///
    /// A pane whose detector never saw an agent answers [`ClaudeStatus::None`] and no label.
    #[must_use]
    pub fn agent_status(&self) -> (ClaudeStatus, Option<String>) {
        self.shared.with_folds(|folds| {
            (
                folds.detector.status(),
                folds.detector.status_label().map(String::from),
            )
        })
    }

    /// Every latch a workspace CAPTURE reads, in ONE acquisition of the folds lock.
    ///
    /// Grouped rather than left as a run of accessors because of who asks: the document's
    /// reconciler captures EVERY pane on every tick, and a call per field would take the same lock
    /// once per field — each gap a chance to interleave with the read loop that writes them, and a
    /// record whose title came from before a command edge and whose running-command came from after
    /// it. One acquisition makes a capture a consistent view of one pane rather than a view per
    /// field.
    ///
    /// Nothing here parses, probes or derives: every field is a value the pane already latched, so
    /// a capture is one lock and a handful of clones. [`Self::foreground_name`] is deliberately NOT
    /// among them — that one is a `tcgetpgrp`+`proc_pidpath` pair, and the poll's own latch is what
    /// [`PaneLatches::foreground`] carries instead.
    ///
    /// The GRID is left out for the opposite reason: it is behind the PTY's lock rather than the
    /// folds', and taking a second lock inside the first is the nesting this crate does not do.
    /// [`Self::window_size`] answers it beside this call.
    #[must_use]
    pub fn latches(&self) -> PaneLatches {
        self.shared.with_folds(|folds| {
            let triple = folds.detector.last_emitted_status();
            PaneLatches {
                title: String::from(folds.truths.title()),
                title_at: folds.truths.title_at(),
                command_started_at: folds.truths.command_running_since(),
                running_command: folds.truths.running_command().map(String::from),
                cwd: folds.truths.cwd().map(String::from),
                project_key: folds.truths.project_key().map(String::from),
                progress: folds.truths.progress(),
                last_exit_code: folds.truths.last_exit(),
                last_duration_ms: folds.truths.last_duration(),
                completion_epoch: folds.truths.completion_epoch(),
                agent_state: triple.map_or(0, |triple| triple.state),
                agent_kind: triple.map_or(0, |triple| triple.kind),
                agent_label: folds.detector.status_label().map(String::from),
                agent_intent: folds.detector.session_intent().map(String::from),
                foreground: folds.detector.foreground_name().map(String::from),
            }
        })
    }

    /// Seeds the pane's cwd and project truths from the SPAWN directory — see
    /// [`Project::seed`](crate::project::Project::seed) for why this is ungated where the
    /// derivation is not.
    pub fn seed_project(&self, cwd: &str) {
        self.project.seed(&self.shared, cwd);
    }

    /// Folds an agent's SELF-REPORT of its state, with an optional human label.
    ///
    /// Authoritative — it beats the foreground-process floor — because an agent inside the pane
    /// knows what it is doing and a `ps`-shaped guess does not. Through the SAME detector the
    /// foreground poll and the hook relay drive, so the precedence and dedupe rules apply
    /// unchanged; a second machine here is how one pane comes to hold two disagreeing states.
    ///
    /// Validate-then-drop, and the validation is the detector's: an unrecognised `state` folds to
    /// nothing. The ctl verb in front of this rejects one first, so a caller sees an error rather
    /// than a silent success — but the floor is here, where a future caller cannot skip it.
    pub fn report_agent_status(&self, state: &str, message: Option<&str>) {
        Detect::fold_report(&self.shared, state, message);
    }

    /// Folds one hook event — the agent announcing its own edge through the installed relay.
    ///
    /// The most AUTHORITATIVE of the four feeds: `done` has no other source, so a pane that cannot
    /// be reached this way reports a finished turn only when the screen watchdog eventually guesses
    /// one. Through the same detector as everything else, for [`Self::report_agent_status`]'s
    /// reason, and the decode is deliberately the CALLER's — see `Detect::fold_hook`.
    pub fn fold_hook(&self, event: ClaudeHookEvent, kind_byte: u8, prompt: Option<&str>) {
        Detect::fold_hook(&self.shared, event, kind_byte, prompt);
    }

    /// The pane's LIVE grid as the kernel holds it, or `None` when the PTY is gone.
    ///
    /// The live size rather than [`Self::resolved_grid`], and the two genuinely differ: the
    /// resolved grid is what the size fold NEGOTIATED across the attached clients, while this is
    /// what `TIOCGWINSZ` says the program is drawing into right now. A ctl `resize` moves the
    /// second without moving the first, so a reader that wants to render the pane's screen must ask
    /// this one.
    #[must_use]
    pub fn window_size(&self) -> Option<(u16, u16)> {
        self.pty.window_size().map(|size| (size.rows, size.cols))
    }

    /// The canonical name of whatever holds the pane's terminal, or an EMPTY string when nothing
    /// does.
    ///
    /// CANONICAL rather than the raw basename: the Claude Code native installer names its
    /// executable by version, so a raw basename reads `2.1.218` — not a program any caller can
    /// recognise. The same probe the detector's own foreground poll uses, uncached, because a
    /// caller asking this is asking about NOW.
    #[must_use]
    pub fn foreground_name(&self) -> String {
        crate::probe::Foreground::name(&self.pty)
    }
}

/// The pane as an ORCHESTRATOR sees it: what it has said, what it is running, and the three ways to
/// be told when that changes.
///
/// Everything here is `slopdesk-ctl`'s side of the pane — `read`, `last-output`, `wait --until`,
/// `run --wait`, `subscribe`, and the metadata RPC a client's own panels ask over. None of it is on
/// the byte path: the scrollback readouts compose from the ring under its own lock, the taps are
/// callbacks the read loop fans to, and the metadata work never touches the control loop at all.
impl PaneSession {
    /// The pane's retained output as plain text, escapes removed unless `ansi_strip` says not to.
    #[must_use]
    pub fn scrollback_text(&self, ansi_strip: bool) -> String {
        history::text(&self.shared, ansi_strip)
    }

    /// The newest retained bytes, at most `cap` — the `screen` verb's on-demand grid rebuild.
    #[must_use]
    pub fn scrollback_raw(&self, cap: usize) -> Vec<u8> {
        history::newest(&self.shared, cap)
    }

    /// The stripped scrollback as logical lines, at most `limit` counting from the end.
    #[must_use]
    pub fn recent_lines(&self, limit: Option<usize>) -> Vec<String> {
        history::logical_lines(&self.shared, limit)
    }

    /// The pane's held command blocks, or `None` when it is not segmented.
    ///
    /// One superd round trip for all three of the reply's parts, because the three are only
    /// consistent with each other if superd read them together.
    #[must_use]
    pub fn blocks(&self, limit: usize) -> Option<BlocksReply> {
        if !self.blocks_enabled {
            return None;
        }
        self.pty.block_control(limit)
    }

    /// One block's retained output. `None` means the pane has no tap; EMPTY means the block was
    /// evicted or never existed — a distinction the `run --wait` caller acts on.
    #[must_use]
    pub fn block_output(&self, index: u32) -> Option<Vec<u8>> {
        if !self.blocks_enabled {
            return None;
        }
        self.pty.block_output(index)
    }

    /// Watches every output chunk. Returns the token that retires it.
    pub fn add_output_tap(&self, tap: Arc<dyn OutputTap>) -> TapToken {
        self.taps.add_output(tap)
    }

    /// Retires an output watcher. Idempotent.
    pub fn remove_output_tap(&self, token: TapToken) {
        self.taps.remove_output(token);
    }

    /// Watches this pane's end. Fires AT ONCE if the pane has already ended — see [`crate::taps`].
    pub fn add_close_tap(&self, tap: Arc<dyn CloseTap>) -> TapToken {
        self.taps.add_close(tap)
    }

    /// Retires a close watcher. Idempotent.
    pub fn remove_close_tap(&self, token: TapToken) {
        self.taps.remove_close(token);
    }

    /// Watches this pane's command blocks. Returns the token that retires it.
    pub fn add_block_tap(&self, tap: Arc<dyn BlockTap>) -> TapToken {
        self.taps.add_block(tap)
    }

    /// Retires a block watcher. Idempotent.
    pub fn remove_block_tap(&self, token: TapToken) {
        self.taps.remove_block(token);
    }

    /// Serves one metadata request, answering `id` exactly once.
    ///
    /// Orders against NOTHING else this pane does — like a ping, and deliberately: a `git status`
    /// that resolved a pending grid would let a repository walk decide when the terminal resizes.
    pub fn serve_metadata(&self, id: SubscriberId, request_id: u32, verb: u8, payload: Vec<u8>) {
        self.metadata.serve(&self.shared, id, Asked {
            request_id,
            verb,
            payload,
            master_fd: self.pty.master_fd_snapshot().unwrap_or(-1),
            shell_pid: self.pty.pid().unwrap_or(0),
        });
    }

    /// How many metadata work items are admitted and unfinished — the flood test's only window on
    /// the bound, since a refusal and a slow answer look identical from the wire.
    #[must_use]
    pub fn metadata_in_flight(&self) -> u32 {
        self.metadata.in_flight()
    }
}

/// Spawns a named, CENSUSED thread, and says so if the OS refused.
///
/// The name is not decoration: it is what `sample`, `lldb` and a spindump call this thread, and a
/// pane's drain being distinguishable from its exit thread is most of what makes a hung host
/// diagnosable at all.
///
/// Fallible on purpose. `Builder::spawn` CONSUMES the closure, so a failure cannot be retried
/// unnamed — and silently substituting an empty body would leave a session with a drain that never
/// runs and no way to tell. The error goes to the caller, which logs it. The census entry is undone
/// on that path, or the pane would report a leaked thread that was never born.
fn spawn(
    shared: &Arc<Shared>,
    name: &str,
    body: impl FnOnce() + Send + 'static,
) -> std::io::Result<JoinHandle<()>> {
    shared.enter_thread();
    let counted = Arc::clone(shared);
    let outcome = std::thread::Builder::new()
        .name(String::from(name))
        .spawn(move || {
            body();
            counted.leave_thread();
        });
    if outcome.is_err() {
        shared.leave_thread();
    }
    outcome
}
