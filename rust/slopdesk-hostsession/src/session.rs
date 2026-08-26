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

use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_hostpane::{PaneOutputStream, PtyProcess};
use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_wire::message::WireMessage;
use slopdesk_wire::mux::flow::MuxFlowControl;
use slopdesk_wire::replay::ReplayBuffer;

use crate::ingest::Ingest;
use crate::shared::{SessionLog, Shared};
use crate::subscriber::{
    Subscriber, run_control_relay, run_control_sender, run_data_sender, run_input_relay,
};
use crate::{drain, facts};

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
    /// Where in superd's ring the read loop starts.
    ///
    /// `0` for a fresh pane; a recorded cursor for a rebind; [`slopdesk_hostpane::FROM_NOW_ON`] for
    /// a pane whose backlog must not be replayed at all.
    pub resume_from: u64,
}

/// One pane, its members, and the threads between them.
#[derive(Debug)]
pub struct PaneSession {
    shared: Arc<Shared>,
    pty: Arc<PtyProcess>,
    observer: Arc<dyn SessionObserver>,
    /// `taskLock`'s remaining job, and only that: the objects. Every LATCH that used to sit beside
    /// them is `Lifecycle`'s.
    stream: Mutex<Option<Arc<PaneOutputStream>>>,
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
            Arc::clone(&config.log),
        ));
        // Seed the resume cursor BEFORE anything can advance it. `record_offset` is monotone except
        // for the `FROM_NOW_ON` sentinel, which the first real offset replaces outright — so a pane
        // told to skip its backlog stays skipped until a chunk actually arrives, and a rebind's
        // recorded cursor can only move forward from here.
        shared.life.record_offset(config.resume_from);
        Arc::new(Self {
            shared,
            pty,
            observer: Arc::clone(&config.observer),
            stream: Mutex::new(None),
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
    /// A member admitted here is a plain attach. The JOIN ladder — the snapshot compose, the
    /// catch-up replay and the fan-out switch — is stage C.2c's, and it will admit through this
    /// same door.
    pub fn attach(
        self: &Arc<Self>,
        data: Arc<SubChannel>,
        data_inbound: Receiver<WireMessage>,
        control: Arc<SubChannel>,
        control_inbound: Receiver<WireMessage>,
    ) -> SubscriberId {
        let id = self.shared.reserve_subscriber_id();
        let subscriber = Subscriber::new(id, data, control);
        // Read the head BEFORE the roster admits this member. Every frame that can reach its lane is
        // sequenced after the admit, so it is numbered above this — read it after and a frame landing
        // in the window would be at or below the sender's cursor, and silently skipped.
        let head = self.shared.highest_seq();
        self.shared.admit(&subscriber, 0);
        self.shared.recompute_client_online();

        let sender = Arc::clone(&subscriber);
        self.launch_owned(&subscriber, "slopdesk-control-send", move || {
            run_control_sender(&sender);
        });

        let relay = Arc::clone(&subscriber);
        let shared = Arc::clone(&self.shared);
        let pty = Arc::clone(&self.pty);
        self.launch_owned(&subscriber, "slopdesk-input-relay", move || {
            run_input_relay(&relay, &data_inbound, &shared, &pty);
        });

        let relay = Arc::clone(&subscriber);
        let shared = Arc::clone(&self.shared);
        self.launch_owned(&subscriber, "slopdesk-control-relay", move || {
            run_control_relay(&relay, &control_inbound, &shared);
        });

        // A member that joins after the fan-out switch needs its own data sender, and `fan_out`'s
        // one roster walk is already behind it. Without this its lane is enqueued into by the drain
        // and drained by nobody: never-drop makes that an unbounded buffer with no owner, and the
        // member never sees a byte. `start_sender` settles the race with a concurrent `fan_out`.
        if self.shared.is_fanned_out() {
            self.start_data_sender(&subscriber, head);
        }

        id
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

        let shared = Arc::clone(&self.shared);
        self.launch("slopdesk-pane-drain", move || drain::run(&shared));

        // superd does the reading now: hostd's duplicate of the master is for writes, `TIOCSWINSZ`
        // and the two probes only. An unspawned pane's stream is EOF from the start, so nothing
        // below is conditional on a child existing.
        let sink = Arc::new(Ingest::new(Arc::clone(&self.shared), Arc::downgrade(&self.pty)));
        let stream = Arc::new(self.pty.make_output_stream(self.shared.life.offset(), sink));
        // The gate's action, wired now that there is something to throttle. Weakly — see the
        // module note.
        self.shared.install_throttle(&stream);
        self.shared.life.stream_opened();
        *self.stream.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(&stream));
        stream.start();

        let shared = Arc::clone(&self.shared);
        let pty = Arc::clone(&self.pty);
        let observer = Arc::clone(&self.observer);
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
            observer.exited(code);
        });
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

        self.join_threads(&members);
        self.teardowns.fetch_add(1, Ordering::AcqRel);
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

    /// Re-sends the pane's block backfill to every member — the reattach half of the block feed.
    ///
    /// Here rather than at C.2d because it needs nothing but the snapshot superd already holds, and
    /// the ONE constructor it goes through is what keeps a re-sent block and a live one from
    /// disagreeing about a field.
    pub fn resend_blocks(&self) {
        let Some(blocks) = self.pty.block_snapshot() else {
            return;
        };
        let messages = blocks.iter().map(facts::block_message).collect::<Vec<_>>();
        self.shared.broadcast_control(&messages);
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
