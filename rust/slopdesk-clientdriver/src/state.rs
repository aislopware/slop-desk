//! The state one pane session keeps, and the sink its two forwarders deliver into.
//!
//! ## Why the inbound fold happens HERE and not on the supervisor
//!
//! [`ChannelSink::message`] runs on whichever forwarder thread decoded the frame, and it does the
//! whole fold there: the dedup verdict, the inbox append, the wake and the window credit. Posting
//! the payload to the supervisor instead would add a thread hop and a second copy of every PTY byte
//! in exchange for a serialisation [`Shared::state`] already provides — and the supervisor is the
//! thread that can be parked for ten seconds inside a dial, which is the worst possible place to
//! put the byte path.
//!
//! The one thing a forwarder must not do is end the channel:
//! [`ChannelTransport::close`](slopdesk_clientnet::transport::ChannelTransport::close) JOINS both
//! forwarders, and one of them would be the caller. So [`ChannelSink::ended`] posts a command and
//! returns.
//!
//! ## The epoch, which is the whole of what `tearingDownDepth` was
//!
//! Every adopted transport is stamped with the epoch its adoption bumped, and its sink carries that
//! stamp. A message or an end from a transport whose stamp no longer matches [`State::epoch`] is
//! one the driver has already replaced — the Swift's "self-inflicted end" — and it is dropped
//! rather than folded. Two overlapping teardowns cannot clobber each other's suppression window,
//! because there is no window: there is a number, and it only goes up.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::sync::atomic::AtomicBool;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use slopdesk_clientnet::dial::Endpoint;
use slopdesk_clientnet::registry::ConnectionRegistry;
use slopdesk_clientnet::transport::{ChannelTransport, InboundSink};
use slopdesk_clientsession::rtt;
use slopdesk_clientsession::seq::{Delivery, Session};
use slopdesk_muxnet::subchannel::ChannelEnd;
use slopdesk_wire::WireMessage;
use slopdesk_wire::mux::MuxCloseReason;

use crate::driver::{Command, DriverConfig};
use crate::event::{Event, Observer};

/// One accepted output payload, waiting for the near side to drain it.
#[derive(Debug)]
pub(crate) struct Chunk {
    /// The raw VT bytes.
    pub(crate) bytes: Vec<u8>,
    /// What the message cost on the wire, which is what a drain credits back to the host.
    ///
    /// Zeroed rather than dropped when a reconnect resets the marks: the bytes are still the only
    /// copy, but the NEW channel's peer never sent them, so crediting them would be a phantom
    /// window grant on a connection that owes nothing.
    pub(crate) wire_bytes: usize,
}

/// The last window size this session asserted, replayed onto every later connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Resize {
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) px_width: u16,
    pub(crate) px_height: u16,
}

/// Everything one pane session mutates, under one lock.
#[derive(Debug)]
pub(crate) struct State {
    /// The four numbers and the flag `slopdesk-clientsession` steps.
    pub(crate) session: Session,
    /// The live channel, or `None` between connections.
    pub(crate) transport: Option<Arc<ChannelTransport>>,
    /// Stamped onto each adopted transport's sink. See the module docs.
    pub(crate) epoch: u64,
    /// The session id the host acknowledged, preserved across reconnects.
    pub(crate) session_id: Option<[u8; 16]>,
    /// Where to reconnect to, remembered from the first connect.
    pub(crate) endpoint: Option<Endpoint>,
    /// The handshake bound the caller's own connect chose, replayed by every retry after it.
    pub(crate) handshake_timeout: Duration,
    /// The cwd hint a FRESH host shell should start in. Sent on every open; a reattach ignores it.
    pub(crate) initial_cwd: Option<String>,
    /// Re-asserted on every connection so a respawned PTY matches the local terminal.
    pub(crate) last_resize: Option<Resize>,
    /// Accepted output the near side has not drained.
    pub(crate) inbox: Vec<Chunk>,
    /// The smoothed application-layer round trip, or `None` until the first pong.
    pub(crate) smoothed_rtt_ms: Option<f64>,
    /// Permanently retired by its owner.
    pub(crate) closed: bool,
    /// Backgrounded. The host keeps the shell; a resume reconnects to it.
    pub(crate) paused: bool,
    /// The remote child exited. Terminal, and the reason a later connect is refused.
    pub(crate) child_exited: bool,
    /// Why the HOST closed this pane's channel, or `None` for a link that died under it.
    pub(crate) host_close_reason: Option<MuxCloseReason>,
}

impl State {
    fn new(seed: Option<crate::driver::ResumeSeed>) -> Self {
        let (session, session_id) = seed.map_or_else(
            || (Session::default(), None),
            |seed| (Session::seeded(seed.last_seq), Some(seed.session_id)),
        );
        Self {
            session,
            transport: None,
            epoch: 0,
            session_id,
            endpoint: None,
            handshake_timeout: Duration::from_secs(10),
            initial_cwd: None,
            last_resize: None,
            inbox: Vec::new(),
            smoothed_rtt_ms: None,
            closed: false,
            paused: false,
            child_exited: false,
            host_close_reason: None,
        }
    }
}

/// What the supervisor thread, the sink and the near side all reach through.
pub(crate) struct Shared {
    /// The per-host pool. SHARED with every other channel to the same host — the workspace document
    /// included — which is the property PATH-1 exists for and the reason it is passed in rather
    /// than built here.
    pub(crate) registry: Arc<ConnectionRegistry>,
    pub(crate) observer: Arc<dyn Observer>,
    pub(crate) config: DriverConfig,
    pub(crate) state: Mutex<State>,
    /// Set by `close`/`pause` BEFORE the command is posted, so a dial already in flight discards
    /// what it built instead of adopting it. The two surviving adoption conditions; see the crate
    /// docs.
    pub(crate) closing: AtomicBool,
    pub(crate) pausing: AtomicBool,
    /// The zero of the monotonic clock both the ping and the pong fold read. `Instant` carries no
    /// epoch, and the wire wants a number the host echoes verbatim, so the session picks one.
    pub(crate) clock: Instant,
    pub(crate) commands: Sender<Command>,
    /// The supervisor's own thread, published by that thread as its first act.
    ///
    /// It exists so a post-and-wait method can tell "the near side is asking" from "the observer is
    /// asking, from inside the very thread that would have to answer" — the second of which is a
    /// deadlock rather than a slow call. Every campaign event is emitted from the supervisor, so a
    /// consumer that calls `close()` on a `GaveUp` is making the ordinary mistake, and it must get
    /// the close rather than a frozen pane. A forwarder reads this too and correctly reads `false`,
    /// whether or not the supervisor has published yet.
    pub(crate) supervisor: OnceLock<ThreadId>,
}

impl core::fmt::Debug for Shared {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // The observer is a trait object with nothing to print, and a poisoned lock must not turn a
        // debug print into a panic.
        formatter
            .debug_struct("Shared")
            .field("state", &self.state.try_lock().ok())
            .finish_non_exhaustive()
    }
}

impl Shared {
    pub(crate) fn new(
        registry: Arc<ConnectionRegistry>,
        observer: Arc<dyn Observer>,
        config: DriverConfig,
        commands: Sender<Command>,
    ) -> Self {
        let seed = config.resume_seed;
        Self {
            registry,
            observer,
            config,
            state: Mutex::new(State::new(seed)),
            closing: AtomicBool::new(false),
            pausing: AtomicBool::new(false),
            clock: Instant::now(),
            commands,
            supervisor: OnceLock::new(),
        }
    }

    /// Whether the CALLER is the supervisor thread itself.
    pub(crate) fn on_supervisor(&self) -> bool {
        self.supervisor.get() == Some(&thread::current().id())
    }

    /// Milliseconds since this session's own zero — the reading a `ping` carries and a `pong`
    /// echoes.
    pub(crate) fn now_ms(&self) -> u64 {
        u64::try_from(self.clock.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Runs `body` against the state, or answers `None` if the lock is poisoned.
    ///
    /// A poisoned lock means a thread panicked while holding it, and this crate denies `panic`. The
    /// honest response to the impossible is to stop touching the state rather than to panic a
    /// second time in a callback the near side is standing in.
    pub(crate) fn with_state<T>(&self, body: impl FnOnce(&mut State) -> T) -> Option<T> {
        self.state.lock().ok().map(|mut state| body(&mut state))
    }

    /// Runs `body` against the state for its EFFECT alone.
    ///
    /// The same lock and the same poisoned-lock answer as [`Self::with_state`], spelled separately
    /// so a caller that wants nothing back does not have to discard an `Option<()>` at every site.
    pub(crate) fn mutate(&self, body: impl FnOnce(&mut State)) {
        if let Ok(mut state) = self.state.lock() {
            body(&mut state);
        }
    }
}

/// One transport's inbound, folded on the forwarder thread that produced it.
///
/// Holds a [`Weak`] and not an [`Arc`]: the state owns the transport, the transport owns this sink,
/// and a strong reference here would close that ring into a leak that survives every teardown. An
/// upgrade that fails means the driver is gone, and a message with nowhere to go is dropped.
#[derive(Debug)]
pub(crate) struct ChannelSink {
    shared: Weak<Shared>,
    epoch: u64,
}

impl ChannelSink {
    pub(crate) const fn new(shared: Weak<Shared>, epoch: u64) -> Self {
        Self { shared, epoch }
    }
}

impl InboundSink for ChannelSink {
    fn message(&self, message: &WireMessage) {
        let Some(shared) = self.shared.upgrade() else {
            return;
        };
        match *message {
            WireMessage::Output { seq, ref bytes } => {
                deliver_output(&shared, self.epoch, seq, bytes, message.wire_byte_count());
            },
            WireMessage::Exit { .. } => {
                deliver_exit(&shared, self.epoch, message);
            },
            WireMessage::Pong { timestamp_ms } => {
                deliver_pong(&shared, self.epoch, timestamp_ms);
            },
            _ => {
                if current(&shared, self.epoch) {
                    shared.observer.event(&Event::Message(message));
                }
            },
        }
    }

    fn ended(&self, end: &ChannelEnd) {
        // Posted rather than handled: ending a channel joins the thread this call is on.
        let Some(shared) = self.shared.upgrade() else {
            return;
        };
        // A closed mailbox means the supervisor has already gone, which is the one case an end has
        // nowhere to be reported and nothing to be done about.
        drop(shared.commands.send(Command::Ended {
            epoch: self.epoch,
            end: end.clone(),
        }));
    }
}

/// Whether this sink still speaks for the adopted transport.
fn current(shared: &Shared, epoch: u64) -> bool {
    shared.with_state(|state| state.epoch == epoch).unwrap_or(false)
}

/// The dedup + inbox + credit fold, which is what is left of `deliverOutput` once the verdict
/// moved.
fn deliver_output(shared: &Shared, epoch: u64, seq: i64, bytes: &[u8], wire_bytes: usize) {
    // The credit is issued OUTSIDE the state lock: `note_output_consumed` takes the sub-channel's
    // own gate and may write a `windowAdjust` frame, and holding the session lock across a socket
    // write would let a wedged host stall the other lane's forwarder.
    let outcome = shared.with_state(|state| {
        if state.epoch != epoch {
            return None;
        }
        match state.session.deliver(seq) {
            Delivery::Accepted => {
                // Append THEN wake, so a wake the near side is already parked on always observes a
                // complete inbox and no chunk can be stranded without one.
                state.inbox.push(Chunk {
                    bytes: bytes.to_vec(),
                    wire_bytes,
                });
                Some((None, true))
            },
            // Dropped, but still credited: the bytes crossed the wire and were fully processed by
            // being discarded. Withholding the credit leaks window capacity on every replay.
            Delivery::Duplicate => Some((state.transport.clone(), false)),
        }
    });
    let Some((credit, wake)) = outcome.flatten() else {
        return;
    };
    if let Some(transport) = credit {
        transport.note_output_consumed(wire_bytes);
    }
    if wake {
        shared.observer.output_ready();
    }
}

/// The child exited: terminal for this session, recorded before the near side is told.
fn deliver_exit(shared: &Shared, epoch: u64, message: &WireMessage) {
    let Some(Some(transport)) = shared.with_state(|state| {
        if state.epoch != epoch {
            return None;
        }
        state.child_exited = true;
        Some(state.transport.clone())
    }) else {
        return;
    };
    shared.observer.event(&Event::Message(message));
    // `exit` rode the windowed DATA lane and never enters the inbox, so its credit is issued here
    // rather than by a drain that will never see it.
    if let Some(transport) = transport {
        transport.note_output_consumed(message.wire_byte_count());
    }
}

/// One pong, folded into the smoothed round trip.
fn deliver_pong(shared: &Shared, epoch: u64, sent_at_ms: u64) {
    let now_ms = shared.now_ms();
    let reading = shared.with_state(|state| {
        if state.epoch != epoch {
            return None;
        }
        let reading = rtt::fold(now_ms, sent_at_ms, state.smoothed_rtt_ms)?;
        state.smoothed_rtt_ms = Some(reading);
        Some(reading)
    });
    if let Some(reading) = reading.flatten() {
        shared.observer.event(&Event::RoundTrip(reading));
    }
}
