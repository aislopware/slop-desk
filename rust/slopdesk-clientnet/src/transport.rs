//! One channel, from the side that opened it: the lane each verb rides, and the merge of the two
//! inbound streams into one.
//!
//! This is `Sources/SlopDeskTransport/Mux/MuxClientTransport.swift` (`docs/63` G.3), and it is
//! deliberately thin. Everything that decides anything already exists: the pool is
//! [`crate::registry`], the open is
//! [`MuxConnection::open_channel`](slopdesk_muxnet::connection::MuxConnection::open_channel), the
//! window is [`SubChannel`]'s, and the message shapes are `slopdesk_wire`'s. What was left in the
//! Swift actor once all of that moved is three facts, and they are the three this module states.
//!
//! ## 1. Which lane a verb rides
//!
//! `input` goes on DATA and everything else on CONTROL, and the split is not a preference. DATA is
//! flow-controlled, so a keystroke queued behind a paste would wait on credit the paste has not
//! released; CONTROL is unwindowed, so a resize, an ack or a `bye` reaches the host while the DATA
//! lane is saturated. That is the whole reason there are two lanes, and it is spelled once here
//! rather than at each of the seven call sites the face used to have.
//!
//! ## 2. A paste is SPLIT, and the reason is three separate failures
//!
//! One giant `input` frame would (a) reach the PTY only after the whole paste reassembled, so no
//! progressive echo and a `Ctrl-C` queued behind the transfer, (b) exceed the 16 MiB decoder cap
//! and kill the channel, and (c) deadlock credit-at-consumption for any frame at or above the
//! window, because the receiver consumes only COMPLETE frames. The cap is
//! [`MuxFlowControl::max_data_message_payload_bytes`], cross-clamped against the tunable window at
//! its source so this side never has to know the clamp exists. Order across the split survives
//! because [`SubChannel::send`] holds its gate for the whole message and this loop is sequential;
//! a byte stream carries no frame semantics, so the split is invisible at the PTY.
//!
//! ## 3. The merged stream ends on the FIRST sub-channel to end
//!
//! The Swift merged both inbound streams into one `AsyncThrowingStream` and finished it when either
//! forwarder finished, because a channel with one live lane is not a usable channel — the peer
//! closed it, or the link died, and both facts arrive on whichever lane noticed first. Two threads
//! and a shared `Sender` would have given the opposite rule, since an `mpsc` receiver ends on the
//! LAST sender drop, so the end is announced explicitly instead: the first forwarder to finish wins
//! a `swap` on a shared flag and delivers [`InboundSink::ended`], and the second returns in
//! silence.
//!
//! The loser also stops DELIVERING, which the merge in the Swift got for free: a finished
//! `AsyncThrowingStream` drops later yields, so nothing followed the end there either. Here the two
//! lanes are threads, and the losing lane may hold a message that was already queued when the other
//! one ended — so it re-reads the flag under the sink's own lock before each delivery, and leaves.
//!
//! ## The sink, and why it is a trait rather than a channel
//!
//! The one caller that matters is the FFI door, which hands each message to a Swift callback. A
//! `Receiver` in between would mean a third thread and a copy of every PTY payload for no decision.
//! So the sink is called ON the forwarder thread, serialised by a `Mutex` the door does not have to
//! know about — one message at a time, from either of two threads, which is the contract
//! `docs/55` §4b already states for a callback handle.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use std::{fmt, io, mem};

use slopdesk_muxnet::connection::{MuxConnection, OpenAck, OpenRequest};
use slopdesk_muxnet::subchannel::{ChannelEnd, SendError, SubChannel};
use slopdesk_wire::WireMessage;
use slopdesk_wire::mux::flow::MuxFlowControl;

use crate::dial::Endpoint;
use crate::registry::{AcquireError, ConnectionRegistry};

/// Where a channel's inbound goes.
///
/// Both methods are called from a forwarder thread, never concurrently with each other, and
/// [`Self::ended`] is called exactly once and always last.
pub trait InboundSink: Send + Sync + 'static {
    /// One decoded message, from either lane.
    fn message(&self, message: &WireMessage);

    /// The channel is over, and why. Nothing follows it.
    fn ended(&self, end: &ChannelEnd);
}

/// Why a channel could not be opened.
///
/// Two variants and not one, because the second failure happens AFTER the pool has handed out a
/// channel: a transport whose forwarders never started would hold an entry nothing will ever
/// release, so [`ChannelTransport::open`] releases it and says which of the two it was.
#[derive(Debug)]
pub enum OpenError {
    /// The pool could not produce a channel.
    Acquire(AcquireError),
    /// The channel exists but a forwarder thread could not be spawned, so nothing would ever read
    /// it. The channel has already been released.
    Forwarder(io::Error),
}

impl fmt::Display for OpenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Acquire(ref failure) => write!(formatter, "{failure}"),
            Self::Forwarder(ref failure) => {
                write!(
                    formatter,
                    "the mux channel's forwarder could not start: {failure}"
                )
            },
        }
    }
}

impl core::error::Error for OpenError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        match *self {
            Self::Acquire(ref failure) => Some(failure),
            Self::Forwarder(ref failure) => Some(failure),
        }
    }
}

/// A channel held open by this end, with its pooled connection.
///
/// Dropping it does NOT release the pool entry: a release names a reason, so it is
/// [`ChannelTransport::close`] rather than a `Drop` that has to invent one.
#[derive(Debug)]
pub struct ChannelTransport {
    registry: Arc<ConnectionRegistry>,
    endpoint: Endpoint,
    connection: Arc<MuxConnection>,
    channel_id: u32,
    data: Arc<SubChannel>,
    control: Arc<SubChannel>,
    /// The two forwarders, joined by [`Self::close`] so a closed transport has no thread left
    /// holding a sink the caller is about to free.
    forwarders: Mutex<Vec<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl ChannelTransport {
    /// Acquires a channel on the pooled connection to `endpoint` and starts forwarding into `sink`.
    ///
    /// The channel is usable the moment this returns: the responder opens on the first
    /// `channelOpen` rather than on a handshake, so [`Self::await_open_ack`] collects a verdict
    /// about RESUME and is not permission to write.
    ///
    /// `sink` may be called BEFORE this returns, including on the error path — the forwarder that
    /// did start can deliver an [`InboundSink::ended`] while the second one is being spawned. It is
    /// never called after an `Err`: the failure arm joins that forwarder first, so a caller whose
    /// open failed may free whatever the sink borrows the moment this answers.
    ///
    /// # Errors
    /// Whatever [`ConnectionRegistry::acquire`] could not do — dial, open, or a pool that was
    /// poisoned by a panicking holder — or a forwarder that could not be spawned.
    pub fn open(
        registry: Arc<ConnectionRegistry>,
        endpoint: &Endpoint,
        request: &OpenRequest,
        sink: Arc<dyn InboundSink>,
    ) -> Result<Self, OpenError> {
        let acquisition = registry.acquire(endpoint, request).map_err(OpenError::Acquire)?;
        let channel = acquisition.channel;

        // The sink is shared by both forwarders and called under one lock, so a message and the end
        // that follows it can never interleave with the other lane's. `ended` is the §3 rule.
        let gate = Arc::new(Mutex::new(sink));
        let ended = Arc::new(AtomicBool::new(false));
        let started = forward(
            "slopdesk-mux-data",
            channel.data_inbound,
            Arc::clone(&channel.data),
            Arc::clone(&gate),
            Arc::clone(&ended),
        )
        .map_err(|failure| (failure, Vec::new()))
        .and_then(|data| {
            match forward(
                "slopdesk-mux-control",
                channel.control_inbound,
                Arc::clone(&channel.control),
                gate,
                ended,
            ) {
                Ok(control) => Ok(vec![data, control]),
                Err(failure) => Err((failure, vec![data])),
            }
        });
        let forwarders = match started {
            Ok(forwarders) => forwarders,
            Err((failure, spawned)) => {
                // Nothing will ever read this channel, so it is released here rather than left for
                // a caller holding an `Err` to remember. The one forwarder that may have started is
                // JOINED before the error is returned: it holds the sink, and a caller whose open
                // failed is entitled to free the context behind it the moment this call answers.
                registry.release(endpoint, channel.channel_id);
                for handle in spawned {
                    drop(handle.join());
                }
                return Err(OpenError::Forwarder(failure));
            },
        };

        Ok(Self {
            registry,
            endpoint: endpoint.clone(),
            connection: acquisition.connection,
            channel_id: channel.channel_id,
            forwarders: Mutex::new(forwarders),
            closed: AtomicBool::new(false),
            data: channel.data,
            control: channel.control,
        })
    }

    /// The id this end allocated. Stable for the channel's whole life.
    #[must_use]
    pub const fn channel_id(&self) -> u32 {
        self.channel_id
    }

    /// Waits for the responder's verdict on the open, or gives up after `within`.
    ///
    /// A refusal is NOT a close: the caller decides whether to release, because a client that gave
    /// up on the ack and a host that refused the channel want different reasons on the wire.
    #[must_use]
    pub fn await_open_ack(&self, within: Duration) -> OpenAck {
        self.connection.await_open_ack(self.channel_id, within)
    }

    /// PTY input, split across `input` frames at the flow-control cap. See the module docs, §2.
    ///
    /// # Errors
    /// [`SendError::Closed`] if the channel finished, [`SendError::Link`] if a write failed.
    pub fn send_input(&self, bytes: &[u8]) -> Result<(), SendError> {
        let cap = usize::try_from(MuxFlowControl::max_data_message_payload_bytes()).unwrap_or(usize::MAX);
        if bytes.len() <= cap {
            return self.data.send(&WireMessage::Input(bytes.to_vec()));
        }
        for chunk in bytes.chunks(cap) {
            self.data.send(&WireMessage::Input(chunk.to_vec()))?;
        }
        Ok(())
    }

    /// Sends one control-lane message. See the module docs, §1.
    ///
    /// Verb-agnostic on purpose: `resize`, `ack`, `bye`, `ping`, `requestBlockOutput`,
    /// `metadataRequest` and `workspaceRequest` differ only in their payload, and seven
    /// near-identical wrappers here would be seven places for a lane to be chosen wrongly.
    ///
    /// # Errors
    /// As [`Self::send_input`].
    pub fn send_control(&self, message: &WireMessage) -> Result<(), SendError> {
        self.control.send(message)
    }

    /// Reports that the caller's REAL consumer drained `bytes` of data-lane inbound.
    ///
    /// Credit is granted at CONSUMPTION rather than at demux, which is the whole reason this call
    /// exists: a grant issued when a frame was decoded would let a flooding pane commit the window
    /// to bytes nothing has rendered. Control-lane messages are unwindowed and are not reported.
    pub fn note_output_consumed(&self, bytes: usize) {
        if bytes > 0 {
            self.data.note_consumed(bytes);
        }
    }

    /// Why the channel ended, or `None` while it is live.
    ///
    /// The DATA lane is asked first for the same reason the Swift asked it first: a host closing a
    /// pane closes both lanes, and DATA is the one whose reason the caller renders.
    #[must_use]
    pub fn end(&self) -> Option<ChannelEnd> {
        self.data.end().or_else(|| self.control.end())
    }

    /// Releases the pool entry and joins both forwarders.
    ///
    /// No reason argument, because the pool already has one: [`ConnectionRegistry::release`] sends
    /// `channelClose` with [`MuxCloseReason::Retired`](slopdesk_wire::mux::MuxCloseReason::Retired)
    /// and tears the connection down if this was the last channel on it. A reason typed here
    /// would be a second spelling of a decision the pool makes.
    ///
    /// Idempotent, because a caller that saw [`InboundSink::ended`] and a caller that decided to
    /// leave are the same caller, and it does not know which of them ran first.
    ///
    /// Never call this from inside a sink callback: it JOINS the thread the callback is running on.
    pub fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.registry.release(&self.endpoint, self.channel_id);
        // Joined and not merely dropped: the sink outlives this call only if nothing is still
        // holding it, and a forwarder mid-callback is exactly that.
        let handles = self
            .forwarders
            .lock()
            .map(|mut held| mem::take(&mut *held))
            .unwrap_or_default();
        for handle in handles {
            drop(handle.join());
        }
    }
}

/// One lane's forwarder: every message to the sink, then the end if this lane noticed it first.
///
/// # Errors
/// Whatever the OS said when the thread could not be spawned.
fn forward(
    name: &str,
    inbound: Receiver<WireMessage>,
    lane: Arc<SubChannel>,
    gate: Arc<Mutex<Arc<dyn InboundSink>>>,
    ended: Arc<AtomicBool>,
) -> io::Result<JoinHandle<()>> {
    thread::Builder::new().name(name.to_owned()).spawn(move || {
        for message in &inbound {
            let Ok(sink) = gate.lock() else { return };
            // Checked HERE, under the gate, and not once before the loop: the other lane can end
            // the channel at any point, including while this message sat in the queue. Nothing
            // follows `ended`, so this lane drops what it was about to deliver and leaves. The
            // flag is read and written only under this lock, which is what makes the pair atomic
            // against the other forwarder.
            if ended.load(Ordering::Acquire) {
                return;
            }
            sink.message(&message);
        }
        // The receiver ended, so the lane is finished and `end()` is already recorded. The
        // fallback is not a guess about which end it was: it is the one case where a lane's
        // sender was dropped without a reason being written, which only a teardown does.
        let Ok(sink) = gate.lock() else { return };
        if ended.swap(true, Ordering::AcqRel) {
            return;
        }
        let end = lane.end().unwrap_or(ChannelEnd::Local);
        sink.ended(&end);
    })
}
