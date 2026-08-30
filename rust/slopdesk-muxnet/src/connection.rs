//! One mux connection, from whichever end holds it: two links in, channel events out.
//!
//! This was MuxNWConnection.swift, under Sources/SlopDeskTransport/Mux, until docs/63 §G.3 deleted
//! it. What it does is small — decode a
//! frame, ask three questions about it, hand the bytes to a channel — and all three questions are
//! already answered in `slopdesk_wire::mux`: [`admit`] says whether the connection reasons about
//! the frame at all, [`ChannelTable::route`] says where it goes, and [`peer_close`]/[`poisoned`]
//! say what a channel's ending reaches. None of them is re-derived here. What is here is the
//! threads, the tables they read, and the two links they write on.
//!
//! ## One connection, two roles, and exactly one guard
//!
//! The mux is asymmetric — the client allocates ids and initiates every open, the host only
//! responds — and every one of those three questions takes a [`Role`] because of it. So this type
//! carries a role and SPENDS it. Nothing on the RECEIVING side reads it: there is no `if host` in
//! any routing path below, and the properties that sound like they would need one fall out of the
//! ladder instead: an open arriving at a client is `Admission::Drop(Ignored::OpenAtInitiator)`, so
//! a client connection cannot emit [`MuxEvent::Opened`]; a refusal is only ever produced for a
//! responder on DATA, so [`MuxConnection::send_open_ack`] is only ever reached from the arm that
//! the host reaches. A second copy of either rule here would be a copy that can disagree.
//!
//! The SENDING side has one guard, and naming it is cheaper than a claim that is nearly true:
//! [`MuxConnection::open_channel`] refuses at a responder. `admit` cannot hold that rule, because
//! it judges frames that ARRIVE and this one is about a frame going out — so the rule stays stated
//! once in the wire, as [`Role::initiates_opens`], and this file asks it rather than comparing to a
//! variant. That single question is the whole of what this crate reads about its own role.
//!
//! ## Events, not handlers — and the four things that dissolve with them
//!
//! The Swift installs its hooks AFTER the receive loops start (`HostTransport.associateMux` runs
//! `mux.start()`, then `HostServer.handleNewMuxConnection` sets `hostOpenHandler`), and the client
//! sends `channelOpen` during `connect` without waiting for an ack — so that frame is routinely
//! already buffered when the loop starts. Four mechanisms exist to survive that one ordering
//! problem: `pendingHostOpens`, `pendingHostCloses`, the `linkDownFired` one-shot, and nil-ing
//! every handler in `close()` to break the retain cycle the handlers form.
//!
//! None of them is here, because the ordering problem is not. [`MuxConnection::serve`] hands the
//! caller its [`MuxEvent`] receiver BEFORE it spawns a thread — the same shape
//! `slopdesk_hostnet::listener::Listener::serve` already uses — so the earliest possible event is
//! queued for an owner that already exists. There is nothing to replay, nothing to nil, and no
//! cycle: a channel is a value in a queue, not a closure holding the peer.
//!
//! ## One dead link is a dead connection
//!
//! PATH-1 needs both links: an open is initiated on DATA and every window grant rides CONTROL, so a
//! connection with one link left cannot carry a pane. The Swift models them separately and then
//! reassembles the conclusion out of `linkFailed`, `linkDownFired`, `detachShellsOnLinkDrop` and a
//! `close()` whose longest comment explains that a CONTROL-first drop leaks every PTY unless the
//! reap loop runs there too. Here the first link to end tears the connection down: both links
//! close, every channel on both finishes, and ONE [`MuxEvent::LinkDown`] reports it with the ids
//! that were live. The leak that comment describes cannot be written.
//!
//! ## Policy is the owner's
//!
//! `detachShellsOnLinkDrop` is not a field here. Whether a dropped link detaches its shells or
//! reaps them is a decision about panes, and this file knows nothing about panes — it reports that
//! the link died and which channels were on it, and the owner decides. That also removes the branch
//! in the Swift where the detach path must remember NOT to run the kill loop.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_wire::WireMessage;
use slopdesk_wire::mux::admission::{
    Admission, Arrival, Link, Role, TableStep, Teardown, admit, peer_close, poisoned,
};
use slopdesk_wire::mux::{
    ChannelTable, FrameKind, MuxCloseReason, MuxFrame, MuxFrameDecoder, RoutingDecision,
};

use crate::link::ByteLink;
use crate::preamble::ConnectionId;
use crate::subchannel::SubChannel;

/// How much of one `recv` a link thread reads at a time.
///
/// One buffer per link, reused for the life of the connection, and the mux decoder borrows its
/// payloads straight back out of it — `docs/59` §7's zero-allocations-per-chunk constraint. 64 KiB
/// is two of `MuxFlowControl::max_output_frame_payload_bytes` and one TCP window's worth on a mesh
/// link, so a bulk read is one syscall rather than four.
const RECEIVE_BUFFER_BYTES: usize = 64 * 1024;

/// Two links that named the same id, ready to become one mux connection.
///
/// The whole of what this crate needs to know about how a connection came to exist. On the host the
/// two arrived at an accept loop and were paired by `slopdesk_hostnet::pending`; on the client they
/// were dialled and each wrote a preamble. From here the two are the same program, and that is the
/// entire reason the split in `docs/63` §3 is where it is.
#[derive(Debug)]
pub struct PairedConnection {
    /// The wire id both preambles carried. The host's relay owner namespaces its per-channel
    /// sessions by `(connection, channel)` — two distinct clients each allocate channel 1 for their
    /// first pane, so a channel-only key cross-resolves one client's session onto another's.
    pub connection: ConnectionId,
    /// The CONTROL link: small frames, never flow-controlled.
    pub control: Box<dyn ByteLink>,
    /// The DATA link: bulk `channelData`, flow-controlled per channel.
    pub data: Box<dyn ByteLink>,
}

/// A peer-initiated channel open, with the pair of sub-channels already registered for it.
///
/// The receivers travel WITH the channels: the owner is handed both ends of the thing it is being
/// told about, so there is no window in which a channel is live and its inbound stream unclaimed.
#[derive(Debug)]
pub struct ChannelOpen {
    /// The channel's logical id on this connection.
    pub channel_id: u32,
    /// The session the client wants this channel bound to.
    pub session_id: [u8; 16],
    /// The highest output seq the client already has, for a byte-exact resume.
    pub last_received_seq: i64,
    /// The raw `channel_class` byte. Raw, not [`slopdesk_wire::MuxChannelClass`], because a class
    /// this build does not route must be REFUSED rather than guessed at — guessing would fork a
    /// shell for a channel that asked for a document.
    pub channel_class: u8,
    /// The working directory the client asked the pane to start in.
    pub initial_cwd: Option<String>,
    /// The DATA sub-channel: PTY bytes, flow-controlled.
    pub data: Arc<SubChannel>,
    /// Its inbound stream.
    pub data_inbound: Receiver<WireMessage>,
    /// The CONTROL sub-channel: resize, ack, bye — never gated.
    pub control: Arc<SubChannel>,
    /// Its inbound stream.
    pub control_inbound: Receiver<WireMessage>,
}

/// What the initiator is asking the responder to open.
///
/// The same four fields [`ChannelOpen`] reports at the other end, which is the point: one struct
/// describes the frame going out and one the frame coming in, and neither carries a sub-channel the
/// sender does not have yet.
#[derive(Debug, Clone)]
pub struct OpenRequest {
    /// The session this channel binds to. The responder resumes an existing pane under it, or mints
    /// one.
    pub session_id: [u8; 16],
    /// The highest output seq this end already holds, for a byte-exact resume.
    pub last_received_seq: i64,
    /// The raw `channel_class` byte — see [`ChannelOpen::channel_class`].
    pub channel_class: u8,
    /// The working directory a freshly minted pane should start in.
    pub initial_cwd: Option<String>,
}

/// A channel this end opened, live from the moment it is returned.
///
/// The pair is usable before the responder has answered, because the responder opens on the first
/// `channelOpen` rather than on a handshake — so the ACK is a verdict about resume, not permission
/// to write. [`MuxConnection::await_open_ack`] is where that verdict is collected.
#[derive(Debug)]
pub struct OpenedChannel {
    /// The id this end allocated.
    pub channel_id: u32,
    /// The DATA sub-channel: PTY bytes, flow-controlled.
    pub data: Arc<SubChannel>,
    /// Its inbound stream.
    pub data_inbound: Receiver<WireMessage>,
    /// The CONTROL sub-channel: resize, ack, bye — never gated.
    pub control: Arc<SubChannel>,
    /// Its inbound stream.
    pub control_inbound: Receiver<WireMessage>,
}

/// The responder's verdict on an open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenAck {
    /// Whether the channel was accepted at all.
    pub accepted: bool,
    /// The output seq the responder will resume from — AUTHORITATIVE, and the reason this verdict
    /// is worth waiting for: the initiator's own `last_received_seq` is a request, this is the
    /// answer.
    pub resume_from_seq: i64,
}

impl OpenAck {
    /// The answer when there is no verdict to be had: the connection died, the channel was closed
    /// under the waiter, or nothing arrived inside the caller's bound.
    ///
    /// One value for all three because the caller does the same thing with each — a pane that
    /// cannot be told where to resume from cannot resume — and a taxonomy nobody branches on is a
    /// taxonomy that goes stale.
    pub const REFUSED: Self = Self {
        accepted: false,
        resume_from_seq: 0,
    };
}

/// Why an open never reached the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenFailure {
    /// This end is the responder. It registers the ids it is SHOWN; it does not mint them.
    NotInitiator,
    /// The connection is torn down, or the write failed. Either way nothing was left registered.
    LinkDown,
}

impl core::fmt::Display for OpenFailure {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let said = match *self {
            Self::NotInitiator => "a responder cannot initiate a channel open",
            Self::LinkDown => "the mux connection is down",
        };
        formatter.write_str(said)
    }
}

impl core::error::Error for OpenFailure {}

/// Something the connection is telling its owner about.
#[derive(Debug)]
pub enum MuxEvent {
    /// The peer opened a channel. Mint the pane behind it and answer with
    /// [`MuxConnection::send_open_ack`].
    Opened(Box<ChannelOpen>),
    /// The peer closed ONE channel, and said why. A decision about that channel, so the pane behind
    /// it is gone.
    Closed {
        /// The channel the peer named.
        channel_id: u32,
        /// The reason it gave.
        reason: MuxCloseReason,
    },
    /// A link died, taking every channel on the connection with it. An ACCIDENT, not a decision:
    /// it says nothing about any one channel, which is why the ids are reported rather than
    /// delivered as closes.
    LinkDown {
        /// `true` for a transport failure or a decode fault, `false` for a clean FIN. The
        /// difference matters to whoever decides between detaching and reaping.
        failed: bool,
        /// The channels that were live when it happened.
        channels: Vec<u32>,
    },
}

/// The tables and dispatch maps both link threads share.
///
/// One lock, not two, and held across a whole `route` — which is exactly the serialisation the
/// Swift got from actor isolation. Per-link ordering survives it because each link thread holds it
/// for the whole decode → route → deliver of one frame, so a channel's bytes reach it in the order
/// its link delivered them.
#[derive(Debug)]
struct Tables {
    control: ChannelTable,
    data: ChannelTable,
    control_channels: HashMap<u32, Arc<SubChannel>>,
    data_channels: HashMap<u32, Arc<SubChannel>>,
}

/// One channel's pair of sub-channels, freshly registered, with the ends the owner is handed.
///
/// Both roles mint exactly this: the responder when an open ARRIVES, the initiator when it sends
/// one. The two used to be the same five lines written twice in the Swift (`acceptChannel` and
/// `openChannel` both call `registerChannels`), and they are one function here for the same reason
/// — a channel registered in one map and not the other routes half its frames into nothing.
#[derive(Debug)]
struct Registered {
    data: Arc<SubChannel>,
    data_inbound: Receiver<WireMessage>,
    control: Arc<SubChannel>,
    control_inbound: Receiver<WireMessage>,
}

impl Tables {
    fn new() -> Self {
        Self {
            control: ChannelTable::new(),
            data: ChannelTable::new(),
            control_channels: HashMap::new(),
            data_channels: HashMap::new(),
        }
    }

    /// Mints and registers the pair of sub-channels for `channel_id` in both dispatch maps.
    ///
    /// Does NOT touch either [`ChannelTable`]: which table step a registration owes is different at
    /// the two ends — the responder mirrors a peer's open, the initiator opens both of its own —
    /// and a function that guessed would be the second copy of the rule.
    fn register(
        &mut self,
        channel_id: u32,
        data_link: &Arc<dyn ByteLink>,
        control_link: &Arc<dyn ByteLink>,
    ) -> Registered {
        let (data, data_inbound) =
            SubChannel::data(channel_id, Arc::clone(data_link), Arc::clone(control_link));
        let (control, control_inbound) = SubChannel::control(channel_id, Arc::clone(control_link));
        self.data_channels.insert(channel_id, Arc::clone(&data));
        self.control_channels.insert(channel_id, Arc::clone(&control));
        Registered {
            data,
            data_inbound,
            control,
            control_inbound,
        }
    }

    /// Applies the bookkeeping half of a [`Teardown`] and hands back what it removed.
    ///
    /// It does not FINISH what it removes: how a sub-channel ends depends on whether the peer named
    /// a reason for it, which is the caller's question. Every removal and every table step here
    /// happens under one lock with nothing in between, so nothing can observe a half-torn channel.
    fn unregister(
        &mut self,
        verdict: Teardown,
        channel_id: u32,
    ) -> (Option<Arc<SubChannel>>, Option<Arc<SubChannel>>) {
        let data = if verdict.drop_data {
            self.data_channels.remove(&channel_id)
        } else {
            None
        };
        let control = if verdict.drop_control {
            self.control_channels.remove(&channel_id)
        } else {
            None
        };
        Self::advance(&mut self.data, verdict.data_table, channel_id);
        Self::advance(&mut self.control, verdict.control_table, channel_id);
        (data, control)
    }

    fn advance(table: &mut ChannelTable, step: TableStep, channel_id: u32) {
        match step {
            // Not "nothing happened": the router already applied this one.
            TableStep::Hold => {},
            TableStep::Local => {
                let _stepped = table.local_close(channel_id);
            },
            TableStep::Remote => {
                let _stepped = table.remote_close(channel_id);
            },
        }
    }
}

/// One mux connection, seen from whichever end holds it.
#[derive(Debug)]
pub struct MuxConnection {
    connection: ConnectionId,
    /// Which end this is. Spent on `slopdesk_wire::mux::admission`, never branched on here.
    role: Role,
    control_link: Arc<dyn ByteLink>,
    data_link: Arc<dyn ByteLink>,
    tables: Mutex<Tables>,
    events: Sender<MuxEvent>,
    /// One slot per open this end has in flight, keyed by the id it allocated. `None` is "sent, not
    /// yet answered"; `Some` is the responder's verdict, waiting to be collected once.
    ///
    /// A LEAF lock: [`Self::route`] takes it while holding [`Self::tables`], so nothing may ever
    /// take `tables` while holding this one. Every method here that needs both releases one first.
    ///
    /// Bounded by this end's own opens: a peer cannot add a key, only answer one. A verdict nobody
    /// ever collects is dropped when its channel closes or the connection tears down — the same
    /// bound the Swift's `openAckResults` carries, and the reason a REFUSED open's slot is left
    /// standing here rather than swept by the router: the router's teardown runs a few lines after
    /// the verdict was recorded, and sweeping would discard the answer it was recorded for.
    open_acks: Mutex<HashMap<u32, Option<OpenAck>>>,
    /// Woken whenever a slot is answered or removed — the second being how a teardown answers.
    ack_settled: Condvar,
    /// Set by the first of [`Self::close`] or a link ending, so the teardown runs once.
    torn_down: AtomicBool,
}

/// The threads a served connection owns, so a caller can wait for them to unwind.
#[derive(Debug)]
pub struct ConnectionThreads {
    joins: Vec<JoinHandle<()>>,
}

impl ConnectionThreads {
    /// Waits for both receive loops to return. Call it AFTER [`MuxConnection::close`], never from
    /// inside a link thread.
    pub fn join(self) {
        for handle in self.joins {
            drop(handle.join());
        }
    }
}

impl MuxConnection {
    /// Adopts a paired connection at `role` and starts reading both links.
    ///
    /// The receiver is built and returned before any thread exists, so the earliest frame on the
    /// wire is queued for an owner that is already there. That ordering is the whole reason the
    /// Swift's two replay queues are absent.
    ///
    /// `role` is not a mode: it is the argument every `slopdesk_wire::mux::admission` call below
    /// takes, and passing it is the ONE place this crate says which end it is.
    #[must_use]
    pub fn serve(pair: PairedConnection, role: Role) -> (Arc<Self>, Receiver<MuxEvent>, ConnectionThreads) {
        let (events, inbox) = channel();
        let connection = Arc::new(Self {
            connection: pair.connection,
            role,
            control_link: Arc::from(pair.control),
            data_link: Arc::from(pair.data),
            tables: Mutex::new(Tables::new()),
            events,
            open_acks: Mutex::new(HashMap::new()),
            ack_settled: Condvar::new(),
            torn_down: AtomicBool::new(false),
        });
        let mut joins = Vec::with_capacity(2);
        for lane in [Link::Control, Link::Data] {
            let worker = Arc::clone(&connection);
            let spawned = thread::Builder::new()
                .name(format!("slopdesk-mux-{}", lane_name(lane)))
                .spawn(move || worker.receive_loop(lane));
            // A connection reading one of its two links is the one failure mode this crate must not
            // have: it would deliver half the frames and report nothing about the other half. Only
            // an exhausted process runs out of threads, so the `else` is near-unreachable — but
            // limping silently is worse than hanging up, so hang up. The links close, the surviving
            // loop unwinds, and the owner is told the same way any dead link tells it.
            if let Ok(join) = spawned {
                joins.push(join);
            } else {
                connection.close();
                drop(connection.events.send(MuxEvent::LinkDown {
                    failed: true,
                    channels: Vec::new(),
                }));
                break;
            }
        }
        (connection, inbox, ConnectionThreads { joins })
    }

    /// The id both preambles carried. The owner namespaces its sessions by `(connection, channel)`.
    #[must_use]
    pub const fn connection_id(&self) -> ConnectionId {
        self.connection
    }

    /// Whether this connection is finished — closed by its owner, or ended by a dead link.
    ///
    /// The Swift's `isDead` is `closed || linkFailed`, two fields because two things could end a
    /// connection separately. Here one link ending IS the connection ending, so there is one flag
    /// and the disjunction cannot go stale. A pool asks this before handing a connection out:
    /// reusing a corpse would open a channel whose first frame fails and whose pane never
    /// recovers.
    #[must_use]
    pub fn is_down(&self) -> bool {
        self.torn_down.load(Ordering::Acquire)
    }

    /// How many channels are live. The owner drops the connection when this reaches zero.
    #[must_use]
    pub fn live_channel_count(&self) -> usize {
        self.tables.lock().map_or(0, |tables| tables.data_channels.len())
    }

    /// Answers a [`MuxEvent::Opened`]. Rides the DATA link, which is the only link an open is
    /// initiated on and so the only one the initiator listens on for the answer.
    pub fn send_open_ack(&self, channel_id: u32, accepted: bool, resume_from_seq: i64) {
        let ack = MuxFrame::ChannelOpenAck {
            channel_id,
            accepted,
            resume_from_seq,
        }
        .encode();
        // Best effort: a failed write means the link is already gone, which its own receive loop is
        // finding out. Reporting it twice would not make it truer.
        drop(self.data_link.send(&ack));
    }

    /// Opens a channel from this side: allocates an id, registers its pair, and sends `channelOpen`
    /// on DATA — the link an open is initiated on, and so the one the answer comes back on.
    ///
    /// It does NOT wait for the ack, because the responder does not wait to act on the open: it
    /// registers the channel and mints the pane on the first `channelOpen`, so the returned pair is
    /// writable at once and the ack is a resume verdict collected separately by
    /// [`Self::await_open_ack`]. Making this call block would serialise every pane's first byte
    /// behind a round trip that decides nothing about whether it may be sent.
    ///
    /// The allocator is the DATA table itself. `ChannelTable::allocate` hands out odd ids from a
    /// monotonic counter that is independent of its state map, so its eviction ring can never make
    /// it re-issue a live id, and `reject` is documented to accept the transition from `Open`
    /// precisely because an initiator marks a channel open before the frame is on the wire. A
    /// separate table kept only to count would be a second allocator that could disagree with the
    /// one the router reads.
    ///
    /// # Errors
    /// [`OpenFailure::NotInitiator`] at a responder, [`OpenFailure::LinkDown`] if the connection is
    /// already down or the write fails. In both cases nothing is left registered.
    pub fn open_channel(&self, request: &OpenRequest) -> Result<OpenedChannel, OpenFailure> {
        if !self.role.initiates_opens() {
            return Err(OpenFailure::NotInitiator);
        }
        // A pooled connection outlives the pane that made it, so a reconnecting pane can reach a
        // corpse: the registry hands out a connection whose links died a moment ago. Registering on
        // one would leave a channel nothing will ever finish.
        if self.torn_down.load(Ordering::Acquire) {
            return Err(OpenFailure::LinkDown);
        }

        let (channel_id, fresh) = {
            let Ok(mut tables) = self.tables.lock() else {
                return Err(OpenFailure::LinkDown);
            };
            let channel_id = tables.data.allocate();
            tables.data.open(channel_id);
            tables.control.open(channel_id);
            let fresh = tables.register(channel_id, &self.data_link, &self.control_link);
            (channel_id, fresh)
        };
        // The slot exists before the frame does. A responder that answers instantly — a loopback
        // mesh link is fast enough — must find somewhere to record its verdict, or the ack is
        // discarded as a phantom and the first `await_open_ack` waits out its whole bound.
        if let Ok(mut acks) = self.open_acks.lock() {
            acks.insert(channel_id, None);
        }

        let open = MuxFrame::ChannelOpen {
            channel_id,
            session_id: request.session_id,
            last_received_seq: request.last_received_seq,
            channel_class: request.channel_class,
            initial_cwd: request.initial_cwd.clone(),
        }
        .encode();
        if self.data_link.send(&open).is_err() {
            // The link is dead, so the peer will never close this id and nothing else ever will
            // either: an orphan here holds `live_channel_count` above zero forever, and the pool
            // above only retires a connection that reaches zero. Undo the whole registration.
            self.abandon(channel_id);
            return Err(OpenFailure::LinkDown);
        }
        Ok(OpenedChannel {
            channel_id,
            data: fresh.data,
            data_inbound: fresh.data_inbound,
            control: fresh.control,
            control_inbound: fresh.control_inbound,
        })
    }

    /// Collects the responder's verdict on an open this end sent, waiting up to `within` for it.
    ///
    /// Answers [`OpenAck::REFUSED`] for every way there is no verdict: the bound elapsed, the
    /// channel was closed under the waiter, the connection died, or the id was never one this end
    /// opened. The verdict is collected ONCE — it is the answer to a handshake, not a state — so a
    /// second caller for the same id is told the same thing as a caller for an id nobody opened.
    ///
    /// The Swift reaches this with a recorded-results map, a waiter list, a monotonic waiter id and
    /// a cancellation handler, because a continuation must be resumed exactly once by exactly one
    /// of four paths. Here the map IS all four: a slot's presence is the phantom-id discipline, its
    /// `None` is the waiter's predicate, its `Some` is a recorded verdict, and its removal is how a
    /// teardown answers everyone parked at once.
    #[must_use]
    pub fn await_open_ack(&self, channel_id: u32, within: Duration) -> OpenAck {
        let Ok(acks) = self.open_acks.lock() else {
            return OpenAck::REFUSED;
        };
        let Ok((mut acks, _timed_out)) = self
            .ack_settled
            .wait_timeout_while(acks, within, |acks| matches!(acks.get(&channel_id), Some(None)))
        else {
            return OpenAck::REFUSED;
        };
        // Only an ANSWERED slot is taken. A slot still pending is one this call gave up on, and
        // leaving it lets a late ack still be recorded for whoever asks next — the channel's own
        // close is what finally clears it.
        if matches!(acks.get(&channel_id), Some(Some(_))) {
            acks.remove(&channel_id).flatten().unwrap_or(OpenAck::REFUSED)
        } else {
            OpenAck::REFUSED
        }
    }

    /// Records a verdict for an id this end opened, and wakes whoever is waiting on it.
    ///
    /// An id with no slot is one this end never opened: ignored, never inserted. That is what keeps
    /// the map bounded by this end's own in-flight opens rather than by what a peer chooses to
    /// send.
    fn note_open_ack(&self, channel_id: u32, ack: OpenAck) {
        let Ok(mut acks) = self.open_acks.lock() else {
            return;
        };
        if let Some(slot) = acks.get_mut(&channel_id) {
            *slot = Some(ack);
            self.ack_settled.notify_all();
        }
    }

    /// Drops `channel_id`'s ack slot and wakes any waiter, which then reads [`OpenAck::REFUSED`].
    ///
    /// Every path that ends a channel or the connection owes this call. A waiter is parked on a
    /// condvar with a bound, not on a link, so nothing else will ever tell it that the thing it is
    /// waiting for can no longer happen.
    fn forget_open_ack(&self, channel_id: u32) {
        if let Ok(mut acks) = self.open_acks.lock() {
            acks.remove(&channel_id);
        }
        self.ack_settled.notify_all();
    }

    /// Ends a channel HERE: out of both dispatch maps, both tables stepped locally, both
    /// sub-channels finished, and its ack slot dropped.
    ///
    /// The whole local half of ending a channel, and the only copy of it. [`Self::close_channel`]
    /// is this plus the frame that tells the peer; an open whose frame never reached the wire
    /// is this alone, because the peer was never told the channel existed.
    ///
    /// Finishing a sub-channel wakes anything parked on an exhausted send window, so a close with a
    /// full window never strands a thread.
    fn abandon(&self, channel_id: u32) {
        let removed = {
            let Ok(mut tables) = self.tables.lock() else {
                return;
            };
            let data = tables.data_channels.remove(&channel_id);
            let control = tables.control_channels.remove(&channel_id);
            let _closed_data = tables.data.local_close(channel_id);
            let _closed_control = tables.control.local_close(channel_id);
            (data, control)
        };
        if let Some(channel) = removed.0 {
            channel.finish();
        }
        if let Some(channel) = removed.1 {
            channel.finish();
        }
        self.forget_open_ack(channel_id);
    }

    /// Closes one channel from this side: tells the peer on both links, then ends it here.
    ///
    /// Best effort on the wire — a failed write means the link is already gone, which its own
    /// receive loop is finding out — and unconditional locally, including for an open whose ack is
    /// still outstanding: a connect that raced a teardown must not leave a thread parked on a
    /// verdict that is no longer coming.
    pub fn close_channel(&self, channel_id: u32, reason: MuxCloseReason) {
        let close = MuxFrame::ChannelClose { channel_id, reason }.encode();
        drop(self.data_link.send(&close));
        drop(self.control_link.send(&close));
        self.abandon(channel_id);
    }

    /// Tears the whole connection down: both links closed, every channel finished.
    ///
    /// Idempotent, and silent — the owner asked for this, so no [`MuxEvent::LinkDown`] is emitted.
    /// The receive loops end when their links do; [`ConnectionThreads::join`] waits for them.
    pub fn close(&self) {
        drop(self.tear_down());
    }

    /// Runs the teardown once. Answers the ids that were live, or `None` if it had already run.
    fn tear_down(&self) -> Option<Vec<u32>> {
        if self
            .torn_down
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return None;
        }
        // Close the links FIRST so both receive loops wake and unwind while the channels are being
        // finished, rather than sitting in `recv` behind a peer that has stopped sending.
        self.control_link.close();
        self.data_link.close();
        // Every parked waiter, at once. An ack rides the DATA link, so a dead link is the end of
        // every verdict in flight — and a waiter is parked on a condvar rather than on the link, so
        // this is the only thing that will ever tell it so.
        if let Ok(mut acks) = self.open_acks.lock() {
            acks.clear();
        }
        self.ack_settled.notify_all();
        let (ids, channels) = {
            let Ok(mut tables) = self.tables.lock() else {
                return Some(Vec::new());
            };
            let ids: Vec<u32> = tables.data_channels.keys().copied().collect();
            let mut channels: Vec<Arc<SubChannel>> = tables.data_channels.drain().map(|(_, ch)| ch).collect();
            channels.extend(tables.control_channels.drain().map(|(_, ch)| ch));
            (ids, channels)
        };
        for channel in channels {
            channel.finish_link_down();
        }
        Some(ids)
    }

    fn link(&self, lane: Link) -> &Arc<dyn ByteLink> {
        match lane {
            Link::Control => &self.control_link,
            Link::Data => &self.data_link,
        }
    }

    // ------------------------------------------------------------ the two loops

    /// One link's whole life: read, decode, route, until it ends.
    ///
    /// The decoder and the buffer are LOCALS. The Swift keeps both decoders on the connection
    /// because an actor has nowhere else to put them; here each is touched by exactly one thread,
    /// so neither needs a lock and the buffer is allocated once per link rather than per chunk.
    fn receive_loop(self: Arc<Self>, lane: Link) {
        let link = Arc::clone(self.link(lane));
        let mut buffer = vec![0_u8; RECEIVE_BUFFER_BYTES];
        let mut decoder = MuxFrameDecoder::new();
        let failed = loop {
            let read = match link.recv(&mut buffer) {
                Ok(0) => break false, // clean FIN
                Ok(count) => count,
                // A signal interrupted the read; the link is fine.
                Err(ref failure) if failure.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break true,
            };
            let Some(chunk) = buffer.get(..read) else {
                break true;
            };
            decoder.append(chunk);
            if self.drain(&mut decoder, lane).is_err() {
                // A decode fault loses the byte boundary for the whole link, so there is no
                // recovering the stream — and a peer whose socket stays open would keep feeding a
                // decoder wedged on the same bad prefix.
                break true;
            }
        };
        self.report_link_down(failed);
    }

    /// Routes every complete frame the decoder can yield. `Err` is a decode fault.
    ///
    /// The payload is left in the decoder's buffer and read back as a slice, so a `channelData`
    /// body travels from the socket to the channel's reassembler without an allocation in between.
    fn drain(&self, decoder: &mut MuxFrameDecoder, lane: Link) -> Result<(), ()> {
        loop {
            match decoder.next_frame_leaving_payload() {
                Ok(Some((frame, payload))) => {
                    let bytes = decoder.payload_bytes(&payload);
                    self.route(&frame, bytes, lane);
                },
                Ok(None) => return Ok(()),
                Err(_fault) => return Err(()),
            }
        }
    }

    /// Everything that happens to one decoded frame.
    fn route(&self, frame: &MuxFrame, payload: &[u8], lane: Link) {
        let Some(kind) = FrameKind::from_wire(frame.mux_type().as_byte()) else {
            return; // a type byte no rule claims — dropped, never guessed at
        };
        let id = frame.channel_id();

        let Ok(mut tables) = self.tables.lock() else {
            return;
        };

        // The four guards, in the precedence `slopdesk_wire::mux::admission` fixes. Each bounds
        // something a correct peer never touches, and a cap checked after the table advances is a
        // cap that stopped bounding the table it was written to bound.
        match admit(&Arrival {
            role: self.role,
            link: lane,
            kind,
            registered: tables.data_channels.contains_key(&id),
            live_channels: tables.data_channels.len(),
            prior_data_state: tables.data.state_of(id),
        }) {
            Admission::Proceed => {},
            Admission::Refuse(_) => {
                // A refusal is an ANSWER — the initiator is waiting on one — so it is sent rather
                // than dropped. Outside the lock: the write must not serialise the other link.
                drop(tables);
                self.send_open_ack(id, false, 0);
                return;
            },
            // Nobody legitimate is waiting: an ack would be an ack on a link that does not carry
            // them, or at a role that does not.
            Admission::Drop(_) => return,
        }

        // The host's verdict on an open THIS end initiated, recorded before the routing decision
        // below can finish a refused channel. A waiter that lost that race would be woken by the
        // teardown and answered with its default rather than with what the host actually said. An
        // id this end never opened has no slot, which is the whole of the phantom-id
        // discipline — and the reason a host reaching this line records nothing without
        // asking its role.
        if let MuxFrame::ChannelOpenAck {
            channel_id,
            accepted,
            resume_from_seq,
        } = *frame
        {
            self.note_open_ack(channel_id, OpenAck {
                accepted,
                resume_from_seq,
            });
        }

        let table = match lane {
            Link::Control => &mut tables.control,
            Link::Data => &mut tables.data,
        };
        // `accepted` is read for `ChannelOpenAck` alone. The host is the side that SENDS those, so
        // one arriving here is spurious or hostile — but it is still ROUTED, so the frame's own
        // bool has to be carried rather than assumed. Assuming `false` turns every stray
        // ack into a `reject`, which marks a live id dead and reaps the pane behind it: a
        // peer could kill an arbitrary pane with fourteen bytes. With the real bool, an
        // `accepted: true` stray is the no-op it is on the client (`open` on an
        // already-open id), which is the behaviour the Swift had.
        let accepted = matches!(*frame, MuxFrame::ChannelOpenAck { accepted: true, .. });
        let decision = table.route(kind, id, accepted);

        // A grant is never a lifecycle event, so it returns before the decision switch: the router
        // reports a `windowAdjust` as a lifecycle state purely informationally, and on the CONTROL
        // link a grant for an id that table does not hold open would be misread as a peer close and
        // would destructively finish the channel.
        if let MuxFrame::WindowAdjust { bytes_to_add, .. } = *frame {
            let channel = tables.data_channels.get(&id).map(Arc::clone);
            drop(tables);
            if let Some(channel) = channel {
                channel.grant_credit(i64::from(bytes_to_add));
            }
            return;
        }

        if let MuxFrame::ChannelOpen {
            session_id,
            last_received_seq,
            channel_class,
            ref initial_cwd,
            ..
        } = *frame
            && lane == Link::Data
        {
            // Mirror the open into the CONTROL table either way, so this id's control frames route.
            tables.control.open(id);
            // A DUPLICATE open for a live id must not mint a second pane: that forks a second shell
            // and orphans the first, leaking its master fd, its child and its reaper. The id is
            // already registered so its data and control still route; the redundant open is simply
            // suppressed. Over-cap NEW opens were already refused above, so anything here is within
            // the cap.
            //
            // The check and the registration are one critical section — the lock is held across
            // both — so no second open can land in between and mint a rival pair.
            if !tables.data_channels.contains_key(&id) {
                let fresh = tables.register(id, &self.data_link, &self.control_link);
                drop(self.events.send(MuxEvent::Opened(Box::new(ChannelOpen {
                    channel_id: id,
                    session_id,
                    last_received_seq,
                    channel_class,
                    initial_cwd: initial_cwd.clone(),
                    data: fresh.data,
                    data_inbound: fresh.data_inbound,
                    control: fresh.control,
                    control_inbound: fresh.control_inbound,
                }))));
            }
        }

        match decision {
            RoutingDecision::DeliverData { channel_id } => {
                self.deliver(&mut tables, channel_id, payload, lane);
            },
            RoutingDecision::Lifecycle { channel_id, state } => {
                if matches!(
                    state,
                    slopdesk_wire::ChannelState::Closed | slopdesk_wire::ChannelState::HalfClosed
                ) {
                    self.peer_closed(&mut tables, channel_id, frame, lane);
                }
            },
            // A stale or hostile frame for an id this table does not hold. Dropped, never a crash.
            RoutingDecision::Drop { .. } => {},
        }
    }

    /// Hands one `channelData` body to its channel, or tears the channel down if it has poisoned
    /// itself.
    ///
    /// Delivery happens under the tables lock, on this link's own thread. That is what makes a
    /// channel's byte order its link's byte order with no sequencing anywhere: the next frame on
    /// this link cannot be routed until this one has been handed over.
    fn deliver(&self, tables: &mut Tables, channel_id: u32, payload: &[u8], lane: Link) {
        let map = match lane {
            Link::Control => &tables.control_channels,
            Link::Data => &tables.data_channels,
        };
        let Some(target) = map.get(&channel_id).map(Arc::clone) else {
            return;
        };
        if target.is_finished() {
            // Still registered but finished means its own inner framing faulted while the rest of
            // the mux is healthy. Stop routing to it, and on the host tear the SIBLING down with
            // it: the pair anchors one shell, the peer's side is already finished, and no
            // `channelClose` is coming to reap it.
            let verdict = poisoned(self.role, lane);
            let (data, control) = tables.unregister(verdict, channel_id);
            // The arriving link's own channel is the one that faulted — it is already finished, and
            // finishing it again is the redundant wake this leaves out on purpose.
            let sibling = if lane == Link::Control { data } else { control };
            if let Some(sibling) = sibling {
                sibling.finish();
            }
            if verdict.reap {
                drop(self.events.send(MuxEvent::Closed {
                    channel_id,
                    reason: MuxCloseReason::Retired,
                }));
            }
            return;
        }
        // No credit is granted here — see `SubChannel::deliver`. The grant follows real
        // consumption, which is what bounds what can pile up behind the demux.
        target.deliver(payload);
    }

    /// The peer ended one channel on one link.
    fn peer_closed(&self, tables: &mut Tables, channel_id: u32, frame: &MuxFrame, lane: Link) {
        // A peer close on DATA takes the sibling with it: a client that closes both links makes the
        // sibling step a harmless no-op, and one that closes DATA only would otherwise leave a
        // control channel and an open control-table entry that nothing ever collects.
        let verdict = peer_close(self.role, lane);
        let (data, control) = tables.unregister(verdict, channel_id);
        let (arriving, sibling) = if lane == Link::Control {
            (control, data)
        } else {
            (data, control)
        };
        // A `channelClose` FRAME is the peer closing this ONE channel and naming a reason, and the
        // reason decides opposite behaviours upstream: a reaped pane is gone, so re-opening under
        // its session id is a fresh spawn, while an evicted subscriber's pane is still there. Keyed
        // on the frame, not on the state: a REFUSED `channelOpenAck` also resolves to closed, and a
        // refusal is an answer about an open, not a closed channel. The sibling is finished plainly
        // — the peer named this link and said nothing about the other one.
        let reason = match *frame {
            MuxFrame::ChannelClose { reason, .. } => Some(reason),
            _ => None,
        };
        if let Some(arriving) = arriving {
            match reason {
                Some(reason) => arriving.finish_closed_by_peer(reason),
                None => arriving.finish(),
            }
        }
        if let Some(sibling) = sibling {
            sibling.finish();
        }
        if verdict.reap {
            drop(self.events.send(MuxEvent::Closed {
                channel_id,
                reason: reason.unwrap_or(MuxCloseReason::Retired),
            }));
        }
    }

    /// One link ended. Tears the connection down and reports it — once, whichever link is first.
    fn report_link_down(&self, failed: bool) {
        let Some(channels) = self.tear_down() else {
            return; // the owner closed us, or the other link already reported it
        };
        drop(self.events.send(MuxEvent::LinkDown { failed, channels }));
    }
}

const fn lane_name(lane: Link) -> &'static str {
    match lane {
        Link::Control => "control",
        Link::Data => "data",
    }
}
