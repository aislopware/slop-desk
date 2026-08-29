//! One pane's client session: the handle the near side holds, and the thread behind it.
//!
//! ## The supervisor loop is three deadlines and a mailbox
//!
//! The Swift ran three tasks — an inbound pump, an ack ticker and a ping ticker — plus a fourth
//! supervising task in `ReconnectManager` that watched the event stream for a drop. The inbound
//! pump is gone entirely (a forwarder thread folds inbound where it decodes it, see
//! [`crate::state`]) and the other three collapse into one `recv_timeout` whose bound is the
//! nearest of three instants: the next ack flush, the next round-trip probe, and the next retry.
//!
//! That is not a smaller spelling of the same thing, it is a stronger one. Every tick now runs on
//! the SAME thread as connect, teardown and close, so a ticker cannot fire against a transport
//! another task is mid-way through replacing — the case the Swift's `startAckTicker` had to
//! re-create per connect to avoid, and the case its post-adoption re-check existed for.
//!
//! ## Why the campaign is here and not above
//!
//! `ReconnectManager` was a separate type because it needed a second consumer of the client's event
//! stream, and that need is what `EventBroadcaster` existed to serve. Inside the driver the
//! campaign reads the state directly —
//! [`campaign_runs`](slopdesk_clientsession::gates::campaign_runs) over four flags — so both the
//! extra consumer and the multicast under it dissolve, along with the subscribe-before-connect race
//! the Swift documented at `ReconnectManager.start`: a drop that happens before anybody has
//! subscribed cannot be lost, because nothing has to have subscribed.
//!
//! It is CONFIGURED rather than always on. A driver with [`DriverConfig::reconnect`] set to `None`
//! announces its drops and stops there, which is what a caller driving its own recovery wants and
//! what every test that asserts on a single connection needs.

use std::sync::atomic::Ordering;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use std::{fmt, io};

use slopdesk_clientnet::dial::{Endpoint, mint_connection_id};
use slopdesk_clientnet::registry::ConnectionRegistry;
use slopdesk_clientnet::transport::{ChannelTransport, OpenError};
use slopdesk_clientsession::backoff::{self, Backoff};
use slopdesk_clientsession::gates::{self, Refusal};
use slopdesk_clientsession::seq::{Adoption, ResumeOutcome};
use slopdesk_muxnet::connection::OpenRequest;
use slopdesk_muxnet::subchannel::{ChannelEnd, SendError};
use slopdesk_wire::WireMessage;
use slopdesk_wire::mux::MuxCloseReason;

use crate::event::{Event, Observer};
use crate::reply::Reply;
use crate::state::{ChannelSink, Resize, Shared};

/// The identity a RESTORED pane presents so the host reattaches its live shell.
///
/// Applied at construction rather than by a later call, which is the whole point of it: seeding
/// after the driver exists leaves a window in which a racing connect observes unseeded marks and
/// silently starts a fresh session instead of reattaching.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumeSeed {
    /// The session id the pane last held.
    pub session_id: [u8; 16],
    /// The highest output seq it last rendered.
    pub last_seq: i64,
}

/// How one driver is configured, fixed for its life.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DriverConfig {
    /// What this session's channel is FOR — the `channelOpen`'s class byte. Fixed for the driver's
    /// life: the class decides how the host routes the open, so a channel that changed class across
    /// a reconnect would become a different thing.
    pub channel_class: u8,
    /// How often the coalesced ack ticker may flush. Correctness never depends on it — an
    /// undelivered seq is never acked — it only bounds how stale the host's view of our progress
    /// can get.
    pub ack_interval: Duration,
    /// How often a round-trip probe goes out. One 14-byte control frame each way.
    pub ping_interval: Duration,
    /// The retry schedule, or `None` for a driver that announces its drops and does nothing about
    /// them.
    pub reconnect: Option<Backoff>,
    /// A restored pane's identity, applied before the driver escapes to any other thread.
    pub resume_seed: Option<ResumeSeed>,
}

impl Default for DriverConfig {
    fn default() -> Self {
        Self {
            channel_class: 0,
            ack_interval: Duration::from_millis(50),
            ping_interval: Duration::from_secs(3),
            reconnect: Some(Backoff::default()),
            resume_seed: None,
        }
    }
}

/// Why a connect did not produce a live session.
#[derive(Debug)]
pub enum ConnectError {
    /// A terminal state refused it. Each arm is permanent for this driver; a recovery that is
    /// allowed builds a new one.
    Refused(Refusal),
    /// There is no endpoint to connect to — a resume before the first connect.
    NoEndpoint,
    /// The channel could not be opened on the pool.
    Open(OpenError),
    /// The host gave no verdict on the open: it refused the channel, the link died, or nothing
    /// arrived inside the handshake bound. One answer for all three, because a pane that cannot be
    /// told where to resume from cannot resume.
    NoVerdict,
    /// A close or a pause landed while this dial was in flight, so what it built was discarded
    /// rather than adopted. NOT a failure: the caller stops, it does not retry.
    Superseded,
    /// The supervisor is gone. Only reachable while the driver is being dropped.
    Gone,
    /// Called from INSIDE an observer callback the supervisor is running. A connect answers only
    /// once the supervisor has dialled, so waiting for it from the supervisor's own thread would
    /// wait forever; the call is refused instead of hanging the pane.
    ///
    /// Only [`Self::connect`](PaneDriver::connect) and [`Self::resume`](PaneDriver::resume) can
    /// report it — [`pause`](PaneDriver::pause) and [`close`](PaneDriver::close) have an answer
    /// nobody reads, so they queue their command and return rather than refusing anything.
    Reentrant,
}

impl fmt::Display for ConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Refused(refusal) => formatter.write_str(refusal.reason()),
            Self::NoEndpoint => formatter.write_str("resume before the first connect"),
            Self::Open(ref failure) => write!(formatter, "{failure}"),
            Self::NoVerdict => {
                formatter.write_str("the channel was refused by the host or the open ack timed out")
            },
            Self::Superseded => formatter.write_str("superseded by a close or a pause"),
            Self::Gone => formatter.write_str("the session driver has been shut down"),
            Self::Reentrant => formatter.write_str("called from inside an observer callback"),
        }
    }
}

impl core::error::Error for ConnectError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        match *self {
            Self::Open(ref failure) => Some(failure),
            _ => None,
        }
    }
}

/// What the near side asks the supervisor to do.
#[derive(Debug)]
pub(crate) enum Command {
    Connect {
        endpoint: Endpoint,
        handshake_timeout: Duration,
        reply: Arc<Reply<Result<(), ConnectError>>>,
    },
    Pause {
        reply: Arc<Reply<()>>,
    },
    Resume {
        handshake_timeout: Duration,
        reply: Arc<Reply<Result<(), ConnectError>>>,
    },
    Close {
        reply: Arc<Reply<()>>,
    },
    /// One channel ended. Posted by a forwarder, which may not end a channel itself.
    Ended {
        epoch: u64,
        end: ChannelEnd,
    },
    /// The driver is being freed. Tear everything down and stop.
    Shutdown {
        reply: Arc<Reply<()>>,
    },
}

/// One pane's client session.
///
/// Every method is safe to call from any thread and blocks only for as long as the supervisor takes
/// to run the command — which for a connect is the dial plus the handshake bound, and for
/// everything else is a lock and a socket write.
///
/// Calling one from INSIDE an [`Observer`] callback is safe too, which is not free: a callback the
/// supervisor is running cannot wait on the supervisor. The four methods that would have waited
/// detect it and answer without waiting — [`Self::connect`] and [`Self::resume`] with
/// [`ConnectError::Reentrant`], [`Self::pause`] and [`Self::close`] by leaving the command queued.
/// Nothing else waits at all, so a send, a readout or a drain from a callback is an ordinary call.
#[derive(Debug)]
pub struct PaneDriver {
    shared: Arc<Shared>,
    commands: Sender<Command>,
    supervisor: Mutex<Option<JoinHandle<()>>>,
}

impl PaneDriver {
    /// Starts a driver over `registry`, reporting to `observer`.
    ///
    /// `registry` is the SHARED per-host pool, passed in rather than built: every pane to one host
    /// and the workspace document all ride one mux connection, and a pool of this driver's own
    /// would be a second TCP pair and a second client identity at the host.
    ///
    /// # Errors
    /// If the supervisor thread could not be spawned. Nothing has been dialled at that point.
    pub fn new(
        registry: Arc<ConnectionRegistry>,
        observer: Arc<dyn Observer>,
        config: DriverConfig,
    ) -> io::Result<Self> {
        let (commands, inbox) = channel();
        let shared = Arc::new(Shared::new(registry, observer, config, commands.clone()));
        let supervisor = {
            let shared = Arc::clone(&shared);
            thread::Builder::new()
                .name("slopdesk-pane-driver".to_owned())
                .spawn(move || supervise(&shared, &inbox))?
        };
        Ok(Self {
            shared,
            commands,
            supervisor: Mutex::new(Some(supervisor)),
        })
    }

    /// Provides the cwd a FRESH host shell should start in.
    ///
    /// Sent on every open rather than only the first: a host-side reattach ignores it (the live
    /// shell's cwd is preserved), and only a respawn reads it — where the pane's project directory
    /// is exactly what is wanted, since the alternative is the daemon's `$HOME` and a pane title
    /// that collapses to "Terminal".
    pub fn set_initial_cwd(&self, cwd: Option<&str>) {
        let trimmed = cwd
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(ToOwned::to_owned);
        self.shared.mutate(|state| state.initial_cwd = trimmed);
    }

    /// Connects to `host:port`, or reconnects presenting the session this driver already holds.
    ///
    /// # Errors
    /// [`ConnectError`], each arm of which is a different thing for the caller to do: a
    /// [`Refused`](ConnectError::Refused) is permanent, a [`Superseded`](ConnectError::Superseded)
    /// means stop, a [`Reentrant`](ConnectError::Reentrant) is the caller's own bug rather than the
    /// link's, and the rest are worth retrying.
    pub fn connect(&self, host: &str, port: u16, handshake_timeout: Duration) -> Result<(), ConnectError> {
        if self.shared.on_supervisor() {
            return Err(ConnectError::Reentrant);
        }
        let reply = Arc::new(Reply::new());
        self.post(Command::Connect {
            endpoint: Endpoint::new(host, port),
            handshake_timeout,
            reply: Arc::clone(&reply),
        })?;
        reply.wait().unwrap_or(Err(ConnectError::Gone))
    }

    /// Backgrounded: acks what is held, says a clean `bye` and tears the transport down.
    ///
    /// The host keeps the shell and its replay buffer, so output produced while paused is retained.
    /// Idempotent. Returns once the pause has landed, or once it is QUEUED when called from inside
    /// a callback — see the type docs.
    pub fn pause(&self) {
        // Set BEFORE the command is posted: a dial in flight reads this at its adoption point and
        // discards what it built rather than leaking it behind the paused state.
        self.shared.pausing.store(true, Ordering::SeqCst);
        self.post_and_settle(|reply| Command::Pause { reply });
    }

    /// Foregrounded: reconnects with the preserved session id and seq. A no-op unless paused.
    ///
    /// # Errors
    /// As [`Self::connect`], plus [`ConnectError::NoEndpoint`] if nothing was ever connected.
    pub fn resume(&self, handshake_timeout: Duration) -> Result<(), ConnectError> {
        if self.shared.on_supervisor() {
            return Err(ConnectError::Reentrant);
        }
        let reply = Arc::new(Reply::new());
        self.post(Command::Resume {
            handshake_timeout,
            reply: Arc::clone(&reply),
        })?;
        reply.wait().unwrap_or(Err(ConnectError::Gone))
    }

    /// Permanently retires the session: a final ack, a clean `bye`, and a teardown. Idempotent, and
    /// queued rather than awaited when called from inside a callback, as [`Self::pause`] is.
    pub fn close(&self) {
        self.shared.closing.store(true, Ordering::SeqCst);
        self.post_and_settle(|reply| Command::Close { reply });
    }

    /// Sends PTY input, split at the flow-control cap by the transport.
    ///
    /// # Errors
    /// [`SendError::Closed`] before a connect and after a close, [`SendError::Link`] on a dead
    /// link.
    pub fn send_input(&self, bytes: &[u8]) -> Result<(), SendError> {
        self.transport()?.send_input(bytes)
    }

    /// Sends a resize, remembering it so it is re-asserted on every later connection.
    ///
    /// The remembering happens even when the send fails, which is the point: a resize that could
    /// not go out is exactly the one the next connection must assert.
    ///
    /// # Errors
    /// As [`Self::send_input`].
    pub fn send_resize(&self, cols: u16, rows: u16, px_width: u16, px_height: u16) -> Result<(), SendError> {
        self.shared.mutate(|state| {
            state.last_resize = Some(Resize {
                cols,
                rows,
                px_width,
                px_height,
            });
        });
        self.transport()?.send_control(&WireMessage::Resize {
            cols,
            rows,
            px_width,
            px_height,
        })
    }

    /// Sends one CONTROL-lane message.
    ///
    /// Verb-agnostic for the reason `ChannelTransport::send_control` is: `requestBlockOutput`, a
    /// metadata request and a workspace request differ only in the value they carry, and one
    /// wrapper per verb would be one more place for a lane to be chosen wrongly.
    ///
    /// # Errors
    /// As [`Self::send_input`].
    pub fn send_control(&self, message: &WireMessage) -> Result<(), SendError> {
        self.transport()?.send_control(message)
    }

    /// Flushes a pending ack now rather than at the next tick.
    pub fn flush_ack(&self) {
        flush_ack(&self.shared);
    }

    /// Takes the whole pending output backlog, in order, and credits its wire bytes back to the
    /// host.
    ///
    /// `chunk` is called once per payload with a borrow that ends when it returns. Credit is issued
    /// at CONSUMPTION — "taken" means the single consumer is about to feed them — so the
    /// un-rendered bytes a client holds stay bounded by about one mux window plus the batch in
    /// hand, and the host's PTY-pause backpressure engages against a slow client rather than
    /// against a slow renderer.
    ///
    /// Returns how many payloads were handed over.
    pub fn take_output(&self, mut chunk: impl FnMut(&[u8])) -> usize {
        // Taken under the lock and credited outside it, for `deliver_output`'s reason: the credit
        // can write a frame, and the state lock is on the inbound path of both lanes.
        let taken = self
            .shared
            .with_state(|state| {
                if state.inbox.is_empty() {
                    return None;
                }
                Some((core::mem::take(&mut state.inbox), state.transport.clone()))
            })
            .flatten();
        let Some((batch, transport)) = taken else {
            return 0;
        };
        let mut wire_bytes = 0;
        for entry in &batch {
            wire_bytes += entry.wire_bytes;
            chunk(&entry.bytes);
        }
        if let Some(transport) = transport {
            transport.note_output_consumed(wire_bytes);
        }
        batch.len()
    }

    /// The session id the host acknowledged, or `None` before the first handshake.
    #[must_use]
    pub fn session_id(&self) -> Option<[u8; 16]> {
        self.shared.with_state(|state| state.session_id).flatten()
    }

    /// The highest CONTIGUOUS output seq delivered — what is acked and what the next open presents.
    #[must_use]
    pub fn highest_contiguous_seq(&self) -> i64 {
        self.shared
            .with_state(|state| state.session.highest_contiguous)
            .unwrap_or(0)
    }

    /// Whether the CURRENT connection reattached the same shell or got a fresh one.
    #[must_use]
    pub fn resume_outcome(&self) -> ResumeOutcome {
        self.shared
            .with_state(|state| state.session.outcome)
            .unwrap_or(ResumeOutcome::Undetermined)
    }

    /// The smoothed application-layer round trip in milliseconds, or `None` before the first pong.
    #[must_use]
    pub fn smoothed_rtt_ms(&self) -> Option<f64> {
        self.shared.with_state(|state| state.smoothed_rtt_ms).flatten()
    }

    /// Whether a transport is currently adopted.
    #[must_use]
    pub fn is_connected(&self) -> bool {
        self.shared
            .with_state(|state| state.transport.is_some())
            .unwrap_or(false)
    }

    /// Backgrounded by [`Self::pause`].
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.shared.with_state(|state| state.paused).unwrap_or(false)
    }

    /// Permanently retired by [`Self::close`].
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.shared.with_state(|state| state.closed).unwrap_or(true)
    }

    /// The remote child exited. Terminal: a later connect is refused.
    #[must_use]
    pub fn is_exited(&self) -> bool {
        self.shared
            .with_state(|state| state.child_exited)
            .unwrap_or(false)
    }

    /// Why the HOST closed this pane's channel, or `None` if it did not.
    ///
    /// The gate above this driver asks only WHETHER, never why — every host close ends this session
    /// — but the reason decides what the layer above may build next: `Retired` says the pane is
    /// gone, `SubscriberEvicted` says only this attachment was.
    #[must_use]
    pub fn host_close_reason(&self) -> Option<MuxCloseReason> {
        self.shared.with_state(|state| state.host_close_reason).flatten()
    }

    /// The live transport, or the error a send on nothing reads as.
    fn transport(&self) -> Result<Arc<ChannelTransport>, SendError> {
        self.shared
            .with_state(|state| state.transport.clone())
            .flatten()
            .ok_or(SendError::Closed)
    }

    fn post(&self, command: Command) -> Result<(), ConnectError> {
        self.commands.send(command).map_err(|_gone| ConnectError::Gone)
    }

    /// Posts a command whose answer carries nothing, and waits for it — unless waiting would be a
    /// wait on this very thread.
    ///
    /// The queue is what makes the reentrant path honest rather than merely non-fatal: the command
    /// is enqueued behind whatever the supervisor is doing, so a `close()` from inside a `GaveUp`
    /// callback still closes, one turn of the loop later, in the order it was asked. What the
    /// caller loses is only the guarantee that it has ALREADY happened when the call returns —
    /// and a callback cannot have that guarantee from any spelling, since the thread that would
    /// provide it is the one standing in the callback.
    fn post_and_settle(&self, command: impl FnOnce(Arc<Reply<()>>) -> Command) {
        let reply = Arc::new(Reply::new());
        if self.post(command(Arc::clone(&reply))).is_ok() && !self.shared.on_supervisor() {
            reply.wait();
        }
    }
}

impl Drop for PaneDriver {
    fn drop(&mut self) {
        let reply = Arc::new(Reply::new());
        if self
            .commands
            .send(Command::Shutdown {
                reply: Arc::clone(&reply),
            })
            .is_ok()
        {
            reply.wait();
        }
        // Joined and not merely abandoned: the supervisor closes the transport, which joins both
        // forwarders, which is the quiescence a leak test needs. Only after this returns is nothing
        // running that could touch the observer.
        if let Ok(mut held) = self.supervisor.lock()
            && let Some(handle) = held.take()
        {
            drop(handle.join());
        }
    }
}

// -- the supervisor ------------------------------------------------------------------------ //

/// Where a campaign stands. `None` between campaigns.
#[derive(Debug, Clone, Copy)]
struct Campaign {
    /// The 1-based attempt already made. `0` before the first.
    attempt: u32,
    /// The wait before the next attempt.
    delay: Duration,
    /// When it fires.
    at: Instant,
}

/// The one thread every command, tick and retry runs on.
fn supervise(shared: &Arc<Shared>, inbox: &Receiver<Command>) {
    // Published before the first command is read, so no command this thread runs — and therefore no
    // observer call it makes — can observe an unpublished id and mistake itself for the near side.
    let _published = shared.supervisor.set(thread::current().id());
    let mut campaign: Option<Campaign> = None;
    let mut next_ack = Instant::now() + shared.config.ack_interval;
    let mut next_ping = Instant::now() + shared.config.ping_interval;
    loop {
        let now = Instant::now();
        let deadline = [Some(next_ack), Some(next_ping), campaign.map(|run| run.at)]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(now);
        match inbox.recv_timeout(deadline.saturating_duration_since(now)) {
            Ok(Command::Shutdown { reply }) => {
                teardown(shared);
                reply.fill(());
                // Every other command still in the mailbox is answered rather than dropped, so a
                // caller blocked on one of them does not park on an answer that is never coming.
                for pending in inbox.try_iter() {
                    abandon(pending);
                }
                return;
            },
            Ok(command) => {
                run(shared, command, &mut campaign);
            },
            Err(RecvTimeoutError::Timeout) => {
                let now = Instant::now();
                if now >= next_ack {
                    next_ack = now + shared.config.ack_interval;
                    flush_ack(shared);
                }
                if now >= next_ping {
                    next_ping = now + shared.config.ping_interval;
                    probe(shared);
                }
                if campaign.is_some_and(|run| now >= run.at) {
                    attempt_retry(shared, &mut campaign);
                }
            },
            // Every sender is gone, which cannot happen while `Shared` lives — but a supervisor
            // that spun on a dead mailbox would burn a core, so it leaves.
            Err(RecvTimeoutError::Disconnected) => {
                teardown(shared);
                return;
            },
        }
    }
}

/// Answers a command nobody will run, so its caller stops waiting.
fn abandon(command: Command) {
    match command {
        Command::Connect { reply, .. } | Command::Resume { reply, .. } => reply.abandon(),
        Command::Pause { reply } | Command::Close { reply } | Command::Shutdown { reply } => reply.abandon(),
        Command::Ended { .. } => {},
    }
}

fn run(shared: &Arc<Shared>, command: Command, campaign: &mut Option<Campaign>) {
    match command {
        Command::Connect {
            endpoint,
            handshake_timeout,
            reply,
        } => {
            // A connect the near side asked for ends whatever campaign was running: it IS the
            // recovery, and a retry firing behind it would fight it.
            *campaign = None;
            let verdict = connect(shared, &endpoint, handshake_timeout);
            reply.fill(verdict);
        },
        Command::Resume {
            handshake_timeout,
            reply,
        } => {
            *campaign = None;
            reply.fill(resume(shared, handshake_timeout));
        },
        Command::Pause { reply } => {
            *campaign = None;
            pause(shared);
            reply.fill(());
        },
        Command::Close { reply } => {
            *campaign = None;
            close(shared);
            reply.fill(());
        },
        Command::Ended { epoch, end } => {
            ended(shared, epoch, &end, campaign);
        },
        // Handled by the loop, which must tear down before it returns.
        Command::Shutdown { reply } => reply.fill(()),
    }
}

/// The connect ladder, run to completion on one thread.
fn connect(
    shared: &Arc<Shared>,
    endpoint: &Endpoint,
    handshake_timeout: Duration,
) -> Result<(), ConnectError> {
    let opening = shared.with_state(|state| {
        // The three terminal states, asked as one, at the one call that actually opens a channel.
        if let Some(refusal) = gates::connect_refusal(
            state.closed,
            state.child_exited,
            state.host_close_reason.is_some(),
        ) {
            return Err(ConnectError::Refused(refusal));
        }
        state.endpoint = Some(endpoint.clone());
        state.handshake_timeout = handshake_timeout;
        Ok(Opening {
            session_id: state.session_id,
            last_received_seq: state.session.highest_contiguous,
            initial_cwd: state.initial_cwd.clone(),
            last_resize: state.last_resize,
        })
    });
    let Some(opening) = opening else {
        return Err(ConnectError::Gone);
    };
    let opening = opening?;

    // Tear the prior transport down BEFORE dialling, so the two can never both be pumping. The
    // epoch bump inside makes the old sink's end self-inflicted and silent.
    teardown(shared);

    let returning = opening.session_id.is_some();
    let session_id = opening.session_id.unwrap_or_else(fresh_session_id);
    let epoch = shared
        .with_state(|state| {
            state.epoch += 1;
            state.epoch
        })
        .ok_or(ConnectError::Gone)?;
    let sink = Arc::new(ChannelSink::new(Arc::downgrade(shared), epoch));
    let transport = ChannelTransport::open(
        Arc::clone(&shared.registry),
        endpoint,
        &OpenRequest {
            session_id,
            last_received_seq: opening.last_received_seq,
            channel_class: shared.config.channel_class,
            initial_cwd: opening.initial_cwd,
        },
        sink,
    )
    .map_err(ConnectError::Open)?;

    // The host acks BEFORE it replays, on the same lane, so this costs one verdict round trip and
    // not the replay. A refusal, a dead link and a timeout are one answer: a pane that cannot be
    // told where to resume from cannot resume.
    let ack = transport.await_open_ack(handshake_timeout);
    if !ack.accepted {
        discard(shared, transport);
        return Err(ConnectError::NoVerdict);
    }

    // The two adoption conditions that survive one supervisor thread: a close or a pause posted
    // while this dial was in flight. A newer connect and a cancelled task cannot happen — every
    // command runs to completion on this thread — so both are `false` rather than tracked.
    if !gates::adopts(
        shared.closing.load(Ordering::SeqCst),
        shared.pausing.load(Ordering::SeqCst),
        false,
        false,
    ) {
        discard(shared, transport);
        return Err(ConnectError::Superseded);
    }

    let transport = Arc::new(transport);
    let adoption = shared.with_state(|state| {
        state.transport = Some(Arc::clone(&transport));
        state.session_id = Some(session_id);
        // The reset is conditional on the HOST-AUTHORITATIVE `resume_from_seq`, never on the
        // client's own "returning" flag — which is true on every reconnect, so gating on it would
        // skip the reset exactly when it is needed.
        state
            .session
            .adopt(opening.last_received_seq, ack.resume_from_seq)
    });
    if adoption == Some(Adoption::MarksReset) {
        // KEEP the un-drained bytes and ZERO their credit. They are the only copy — this open
        // already presented the mark they advanced, so the host will never re-send them — and the
        // new channel's peer never sent them, so crediting would be a phantom grant.
        shared.mutate(|state| {
            for entry in &mut state.inbox {
                entry.wire_bytes = 0;
            }
        });
    }
    if returning {
        shared.observer.event(&Event::Reconnected {
            session_id,
            resume_from_seq: ack.resume_from_seq,
        });
    }
    // Re-assert the window size so a respawned PTY matches the local terminal. Best-effort: a
    // resize that cannot go out is a cosmetic loss, not a failed connect.
    if let Some(size) = opening.last_resize {
        drop(transport.send_control(&WireMessage::Resize {
            cols: size.cols,
            rows: size.rows,
            px_width: size.px_width,
            px_height: size.px_height,
        }));
    }
    Ok(())
}

/// What a connect reads out of the state before it starts dialling.
#[derive(Debug)]
struct Opening {
    session_id: Option<[u8; 16]>,
    last_received_seq: i64,
    initial_cwd: Option<String>,
    last_resize: Option<Resize>,
}

/// A brand-new session id.
///
/// `slopdesk-ids` states the rule as "no clock and no randomness" for ids a caller can supply, and
/// this is the exception the dialler already made: a session the host has never seen has no
/// argument to be passed. An entropy source that fails leaves an all-zero id, which the host reads
/// as the new-session sentinel — the same request, minted differently.
fn fresh_session_id() -> [u8; 16] {
    mint_connection_id().map_or([0; 16], |id| *id.as_bytes())
}

/// What a resume decided to do about itself.
#[derive(Debug)]
enum Resuming {
    /// Not paused, or closed, or exited — a no-op, exactly as the Swift `resume()` was.
    Nothing,
    /// Paused, and there is somewhere to go back to.
    Reconnect(Endpoint),
    /// Paused, but nothing was ever connected. A resume before the first connect is a caller's
    /// error rather than a quiet no-op, because the caller believes it had a session.
    Nowhere,
}

fn resume(shared: &Arc<Shared>, handshake_timeout: Duration) -> Result<(), ConnectError> {
    let decision = shared.with_state(|state| {
        // An exited pane must not come back on foreground: a resume would spawn a fresh host shell
        // into a wake stream whose consumer has already returned.
        if !state.paused || state.closed || state.child_exited {
            return Resuming::Nothing;
        }
        state.paused = false;
        state
            .endpoint
            .clone()
            .map_or(Resuming::Nowhere, Resuming::Reconnect)
    });
    match decision {
        None => Err(ConnectError::Gone),
        Some(Resuming::Nothing) => Ok(()),
        Some(Resuming::Nowhere) => Err(ConnectError::NoEndpoint),
        Some(Resuming::Reconnect(endpoint)) => {
            shared.pausing.store(false, Ordering::SeqCst);
            connect(shared, &endpoint, handshake_timeout)
        },
    }
}

fn pause(shared: &Arc<Shared>) {
    let proceed = shared.with_state(|state| {
        if state.paused || state.closed {
            return false;
        }
        state.paused = true;
        true
    });
    if proceed != Some(true) {
        return;
    }
    // A clean ack of what is held, then a clean `bye` so the host marks us offline at once rather
    // than waiting for the FIN the kernel will send a few seconds later anyway.
    flush_ack(shared);
    say_goodbye(shared);
    teardown(shared);
    shared.observer.event(&Event::Disconnected {
        reason: "paused (backgrounded)",
    });
}

fn close(shared: &Arc<Shared>) {
    let proceed = shared.with_state(|state| {
        if state.closed {
            return false;
        }
        state.closed = true;
        true
    });
    if proceed != Some(true) {
        return;
    }
    flush_ack(shared);
    say_goodbye(shared);
    teardown(shared);
}

/// Retires the live transport and makes everything it still delivers silent.
///
/// The epoch bump comes FIRST and under the same lock as the take, so there is no instant at which
/// a forwarder can fold a message into a session that has moved on. `close` is called with the lock
/// released, because it joins both forwarder threads and one of them may be blocked on that lock.
fn teardown(shared: &Arc<Shared>) {
    let retired = shared.with_state(|state| {
        state.epoch += 1;
        state.transport.take()
    });
    if let Some(Some(transport)) = retired {
        transport.close();
    }
}

/// Throws away a transport a dial built but will not adopt, and makes its end silent.
///
/// The epoch bump is the whole point, and it is NOT optional bookkeeping. A discarded transport is
/// still closed, its sink still fires [`InboundSink::ended`](slopdesk_clientnet::InboundSink), and
/// that end still carries the epoch the dial minted — which is the CURRENT one, because the dial
/// bumped it on the way in. Without a second bump, [`ended`] reads a self-inflicted close as a live
/// drop, announces a disconnect for a transport nobody ever had, and starts a campaign that resets
/// the attempt counter to zero.
///
/// That is not a cosmetic miscount. A campaign whose every failed attempt restarts it never reaches
/// the give-up ceiling, so a host that refuses the channel — a version skew, say — is dialled
/// forever instead of twenty times. The bug the Swift's `connectGeneration` was really guarding was
/// this one, and one supervisor thread does not dissolve it: the stale epoch is what does.
fn discard(shared: &Arc<Shared>, transport: ChannelTransport) {
    let _bumped = shared.with_state(|state| state.epoch += 1);
    transport.close();
    // BY VALUE and dropped here rather than borrowed: a discarded transport has no second reader,
    // and taking ownership is what says so at the signature.
    drop(transport);
}

/// One inbound stream ended.
fn ended(shared: &Arc<Shared>, epoch: u64, end: &ChannelEnd, campaign: &mut Option<Campaign>) {
    let announce = shared.with_state(|state| {
        // A stale epoch is this driver's own teardown coming back to it. Recorded nowhere and
        // announced never: the transport it speaks for was replaced on purpose.
        if state.epoch != epoch {
            return None;
        }
        if let ChannelEnd::Peer(reason) = *end {
            // Recorded BEFORE the event goes out, so every reader of `host_close_reason` on the
            // announcement — the campaign gate first among them — sees it already set.
            state.host_close_reason = Some(reason);
        }
        // The dead connection's resume verdict must not survive it: a stale `ResumedSession` read
        // between the drop and the next connect would let a surface skip a wipe the next session
        // needs.
        state.session.stream_ended();
        let announced = gates::announces_drop(state.closed, false, state.child_exited);
        let runs = announced
            && gates::campaign_runs(
                state.paused,
                state.closed,
                state.child_exited,
                state.host_close_reason.is_some(),
            );
        Some((announced, runs))
    });
    let Some(Some((announced, runs))) = announce else {
        return;
    };
    if !announced {
        return;
    }
    shared.observer.event(&Event::Disconnected {
        reason: &reason_for(end),
    });
    if runs && let Some(schedule) = shared.config.reconnect {
        shared.observer.event(&Event::Log(&format!(
            "reconnect: transport dropped ({}) — retrying",
            reason_for(end)
        )));
        *campaign = Some(Campaign {
            attempt: 0,
            delay: Duration::from_nanos(schedule.initial_ns),
            at: Instant::now(),
        });
    }
}

/// The sentence one end reads as.
fn reason_for(end: &ChannelEnd) -> String {
    match *end {
        ChannelEnd::Local => "stream ended (FIN)".to_owned(),
        ChannelEnd::Peer(reason) => format!("the host closed the channel ({reason:?})"),
        ChannelEnd::LinkDown => "the link died".to_owned(),
        ChannelEnd::Decode(ref detail) => format!("the channel's inner framing faulted: {detail}"),
    }
}

/// One turn of a retry campaign.
fn attempt_retry(shared: &Arc<Shared>, campaign: &mut Option<Campaign>) {
    let Some(mut run) = *campaign else {
        return;
    };
    let Some(schedule) = shared.config.reconnect else {
        *campaign = None;
        return;
    };
    // All four states can arrive DURING a campaign: the app backgrounds, the owner closes the pane,
    // a freshly respawned shell exits at once, or the host closes the channel under it.
    let wanted = shared.with_state(|state| {
        gates::campaign_runs(
            state.paused,
            state.closed,
            state.child_exited,
            state.host_close_reason.is_some(),
        )
    });
    if wanted != Some(true) {
        *campaign = None;
        return;
    }
    // The bound this attempt gives the handshake is the one the connect that WAS running used, kept
    // for exactly this: a retry that invented its own would be a second spelling of a number the
    // caller already chose.
    let Some(Some((endpoint, handshake_timeout))) = shared.with_state(|state| {
        state
            .endpoint
            .clone()
            .map(|target| (target, state.handshake_timeout))
    }) else {
        *campaign = None;
        return;
    };
    run.attempt += 1;
    if backoff::exhausted(run.attempt) {
        shared.observer.event(&Event::Log(&format!(
            "reconnect: gave up after {} attempt(s) — could not reach {}:{}",
            backoff::MAX_RECONNECT_ATTEMPTS,
            endpoint.host,
            endpoint.port
        )));
        shared.observer.event(&Event::GaveUp {
            attempts: backoff::MAX_RECONNECT_ATTEMPTS,
        });
        *campaign = None;
        return;
    }
    // This attempt fires now, so there is no instant to count down to.
    shared.observer.event(&Event::Retry {
        attempt: run.attempt,
        delay_ms: 0,
    });
    match connect(shared, &endpoint, handshake_timeout) {
        Ok(()) => {
            shared.observer.event(&Event::Log(&format!(
                "reconnect: resumed after {} attempt(s)",
                run.attempt
            )));
            *campaign = None;
        },
        // A refusal is terminal and a supersede means stop; neither is worth another turn.
        Err(ConnectError::Refused(_) | ConnectError::Superseded | ConnectError::Gone) => {
            *campaign = None;
        },
        Err(failure) => {
            shared.observer.event(&Event::Log(&format!(
                "reconnect: attempt {} failed ({failure}); backing off {:?}",
                run.attempt, run.delay
            )));
            shared.observer.event(&Event::Retry {
                attempt: run.attempt,
                delay_ms: u64::try_from(run.delay.as_millis()).unwrap_or(u64::MAX),
            });
            run.at = Instant::now() + run.delay;
            run.delay = Duration::from_nanos(schedule.next_after(duration_ns(run.delay)));
            *campaign = Some(run);
        },
    }
}

fn duration_ns(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

/// Sends a coalesced ack, if one is pending and there is somewhere to send it.
///
/// The transport is read FIRST, so a tick with nowhere to send leaves the flag armed for the next
/// live one. Past that the gate is `slopdesk-clientsession`'s: it clears the flag, and answers a
/// seq only when there is one — never zero, and never one that has not been delivered.
fn flush_ack(shared: &Arc<Shared>) {
    let pending = shared
        .with_state(|state| {
            let transport = state.transport.clone()?;
            let seq = state.session.ack()?;
            Some((transport, seq))
        })
        .flatten();
    let Some((transport, seq)) = pending else {
        return;
    };
    if transport.send_control(&WireMessage::Ack { seq }).is_err() {
        // The channel dropped under the send: re-arm so the next live transport says it instead.
        shared.mutate(|state| state.session.ack_failed());
    }
}

/// One round-trip probe on the CONTROL lane. Best-effort — a dropped probe skips a sample.
fn probe(shared: &Arc<Shared>) {
    let now_ms = shared.now_ms();
    let Some(Some(transport)) = shared.with_state(|state| state.transport.clone()) else {
        return;
    };
    drop(transport.send_control(&WireMessage::Ping { timestamp_ms: now_ms }));
}

/// A clean `bye`, so the host marks this client offline at once.
fn say_goodbye(shared: &Arc<Shared>) {
    if let Some(Some(transport)) = shared.with_state(|state| state.transport.clone()) {
        drop(transport.send_control(&WireMessage::Bye));
    }
}
