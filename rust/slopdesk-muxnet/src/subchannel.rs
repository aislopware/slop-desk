//! One logical channel on one of a connection's two links.
//!
//! This is `Sources/SlopDeskTransport/Mux/MuxSubChannel.swift`, which is 426 lines of an `actor`
//! holding a decoder, an inbound continuation, a credit window, a FIFO park queue, a send gate,
//! and a lock-guarded `Bool` that exists only so one caller can read the actor's state without
//! suspending into it. Every one of those is Swift concurrency machinery around three ideas: frame
//! it, gate it on credit, hand it up. Written against threads the machinery mostly disappears, and
//! what is left is small enough that the invariants are visible in it.
//!
//! ## The two windows, and why only one of them is here
//!
//! A channel has a SEND window (how much this side may write before the peer grants more) and a
//! RECEIVE window (how much the peer may write before this side grants). The Swift kept the send
//! half on the sub-channel and the receive half in a `[UInt32: ReceiveWindowAccountant]` map on the
//! connection, wired back together by a `consumedSink` closure captured `[weak self]`. Both halves
//! are per-channel state, so both live here: the map, the closure and the weak capture all go, and
//! a channel that is dropped drops its own credit accounting with it rather than relying on the
//! owner to remember to remove a second entry.
//!
//! The grant still rides the CONTROL link — that is a wire property, not a bookkeeping one, and the
//! reason is that a grant queued behind the flooded DATA window it is meant to open is a deadlock.
//! So a DATA sub-channel holds a handle to the control link for exactly that one write.
//!
//! ## What "finished" means
//!
//! One flag, set once, read from anywhere. It ends the inbound stream (the sender is dropped, so
//! the consumer's `recv` reports disconnection), wakes anything parked on credit so it can fail
//! instead of hanging, and records WHY through [`ChannelEnd`] — which the consumer reads after the
//! stream ends. The Swift needed `peerCloseReason` as a separate actor-isolated field plus a
//! `closedByPeer` derived from it plus a `FinishedBox` under an `NSLock` for the nonisolated read;
//! here the reason IS the end, so the fact and its reason cannot disagree and no second lock is
//! needed to look at them.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};

use slopdesk_wire::mux::admission::Link;
use slopdesk_wire::{
    ConsumeResult, FlowCreditPolicy, FrameDecoder, MuxCloseReason, MuxFlowControl, MuxFrame,
    ReceiveWindowAccountant, WireMessage,
};

use crate::link::ByteLink;

/// Why a channel's inbound stream ended.
///
/// The distinction the Swift drew between "the peer closed THIS channel, with a reason" and "the
/// link under it died" is load-bearing above: a link that drops says nothing about any channel on
/// it and is what a reconnect campaign recovers from, while a per-channel close is the peer naming
/// one channel and is final. Both are here, alongside the two this side can cause.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEnd {
    /// This side closed the channel.
    Local,
    /// The peer sent `channelClose` for this channel, with the reason it gave.
    Peer(MuxCloseReason),
    /// The link carrying the channel died. Says nothing about the channel itself.
    LinkDown,
    /// This channel's own inner framing faulted. Fatal for this channel, harmless to its siblings.
    Decode(String),
}

/// Why a send could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendError {
    /// The channel is finished — closed, reaped, or its link is gone.
    Closed,
    /// The write failed on the link. The link is dead; its receive loop will agree shortly.
    Link(String),
}

impl core::fmt::Display for SendError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::Closed => formatter.write_str("mux channel closed"),
            Self::Link(ref reason) => write!(formatter, "mux link write failed: {reason}"),
        }
    }
}

impl std::error::Error for SendError {}

/// The SEND half of a channel's flow control: the credit math, and the park that waits on it.
///
/// [`FlowCreditPolicy`] is the whole decision and it is already `slopdesk_wire`'s. What is added
/// here is one condvar, because a thread that has run out of credit has to wait for the receive
/// loop to grant more — and that is the entire reason this type exists rather than the policy being
/// used directly.
#[derive(Debug)]
struct SendWindow {
    credit: Mutex<FlowCreditPolicy>,
    granted: Condvar,
}

/// The RECEIVE half: what this side has consumed, and the link a grant is written on.
///
/// Present on DATA sub-channels only. CONTROL is unwindowed in both directions, which is what keeps
/// a resize from queueing behind a megabyte of output.
#[derive(Debug)]
struct ReceiveWindow {
    accountant: Mutex<ReceiveWindowAccountant>,
    /// The CONTROL link — a grant NEVER rides DATA. See the module note.
    grant_link: Arc<dyn ByteLink>,
}

/// One logical `SlopDesk` channel, multiplexed onto one physical link.
#[derive(Debug)]
pub struct SubChannel {
    channel_id: u32,
    lane: Link,
    /// The link this channel's own frames are written on.
    link: Arc<dyn ByteLink>,
    /// `None` on CONTROL: an infinite window, never gated.
    send_window: Option<SendWindow>,
    /// `None` on CONTROL: nothing to account, nothing to grant.
    receive_window: Option<ReceiveWindow>,
    /// The send gate AND the buffer it writes through, which are the same lock because they have
    /// the same lifetime: one sender at a time may emit, and while it does it owns the scratch the
    /// envelope is built in. Holding it across a credit park is what stops two senders interleaving
    /// chunks mid-frame — reassembly at the far end would be corrupted, and an `actor` could not
    /// prevent it because isolation is not held across a suspension.
    outbound: Mutex<Vec<u8>>,
    /// Reassembles this channel's inner frames out of the `channelData` bodies demuxed to it.
    inbound_decoder: Mutex<FrameDecoder>,
    /// Dropped by [`SubChannel::finish`], which is how the consumer learns the stream ended.
    inbound: Mutex<Option<Sender<WireMessage>>>,
    finished: AtomicBool,
    end: Mutex<Option<ChannelEnd>>,
}

impl SubChannel {
    /// A DATA sub-channel: a send window armed at [`MuxFlowControl::initial_window_bytes`], and a
    /// receive window whose grants are written on `control_link`.
    #[must_use]
    pub fn data(
        channel_id: u32,
        link: Arc<dyn ByteLink>,
        control_link: Arc<dyn ByteLink>,
    ) -> (Arc<Self>, Receiver<WireMessage>) {
        let window = MuxFlowControl::initial_window_bytes();
        Self::build(
            channel_id,
            Link::Data,
            link,
            Some(window),
            Some(ReceiveWindow {
                accountant: Mutex::new(ReceiveWindowAccountant::new(window)),
                grant_link: control_link,
            }),
        )
    }

    /// A CONTROL sub-channel: an infinite send window and no receive accounting, so a resize, an
    /// ack, a bye or a window grant can never block behind a full data window.
    #[must_use]
    pub fn control(channel_id: u32, link: Arc<dyn ByteLink>) -> (Arc<Self>, Receiver<WireMessage>) {
        Self::build(channel_id, Link::Control, link, None, None)
    }

    /// A channel with a specific send window, for the tests that need to reach the park path
    /// without pushing a whole window of bytes through it.
    #[must_use]
    pub fn with_send_window(
        channel_id: u32,
        lane: Link,
        link: Arc<dyn ByteLink>,
        send_window_bytes: Option<i64>,
    ) -> (Arc<Self>, Receiver<WireMessage>) {
        Self::build(channel_id, lane, link, send_window_bytes, None)
    }

    fn build(
        channel_id: u32,
        lane: Link,
        link: Arc<dyn ByteLink>,
        send_window_bytes: Option<i64>,
        receive_window: Option<ReceiveWindow>,
    ) -> (Arc<Self>, Receiver<WireMessage>) {
        let (sender, receiver) = channel();
        let channel = Arc::new(Self {
            channel_id,
            lane,
            link,
            send_window: send_window_bytes.map(|bytes| {
                SendWindow {
                    credit: Mutex::new(FlowCreditPolicy::new(bytes)),
                    granted: Condvar::new(),
                }
            }),
            receive_window,
            outbound: Mutex::new(Vec::new()),
            inbound_decoder: Mutex::new(FrameDecoder::new()),
            inbound: Mutex::new(Some(sender)),
            finished: AtomicBool::new(false),
            end: Mutex::new(None),
        });
        (channel, receiver)
    }

    /// This channel's logical id on the shared connection.
    #[must_use]
    pub const fn channel_id(&self) -> u32 {
        self.channel_id
    }

    /// Which of the two links carries it.
    #[must_use]
    pub const fn lane(&self) -> Link {
        self.lane
    }

    /// Whether the channel has ended. Every later send fails.
    #[must_use]
    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    /// Why it ended, or `None` while it is live.
    #[must_use]
    pub fn end(&self) -> Option<ChannelEnd> {
        self.end.lock().ok().and_then(|end| end.clone())
    }

    // ---------------------------------------------------------------- sending

    /// Frames `message` and writes it, chunked across the send window when there is one.
    ///
    /// ## Infinite window (CONTROL)
    /// The whole framed message goes out as ONE `channelData` envelope, never blocking.
    ///
    /// ## Armed window (DATA)
    /// The framed bytes are chunked across the credit window — yamux / RFC 9113 §5.2
    /// DATA-across-windows. Each iteration consumes `min(remaining, bytes_left)`, always a PARTIAL
    /// consume and therefore always allowed, and writes that slice as its own envelope; when the
    /// window is empty the thread parks until a peer grant replenishes it. This is what makes a
    /// message LARGER than the whole window deliverable: an all-or-nothing consume could never
    /// succeed for one, so it would wait forever for a grant the receiver only emits after
    /// consuming bytes that never arrive.
    ///
    /// The receiver reassembles across those boundaries in [`Self::deliver`], so the split is
    /// invisible to the consumer.
    ///
    /// # Errors
    /// [`SendError::Closed`] if the channel finished, before or during the send;
    /// [`SendError::Link`] if the write failed.
    pub fn send(&self, message: &WireMessage) -> Result<(), SendError> {
        let framed = message.encode();
        // The gate and its scratch buffer. Taken BEFORE the first chunk and held to the last, so a
        // concurrent sender waits its turn rather than interleaving chunks into the same stream.
        let mut scratch = self.outbound.lock().map_err(|_poisoned| SendError::Closed)?;
        if self.is_finished() {
            return Err(SendError::Closed);
        }
        let Some(window) = self.send_window.as_ref() else {
            return self.write_chunk(&mut scratch, &framed);
        };
        let mut offset = 0_usize;
        while offset < framed.len() {
            let wanted = framed.len() - offset;
            let granted = Self::await_chunk_credit(window, &self.finished, wanted)?;
            let end = offset.saturating_add(granted);
            let chunk = framed.get(offset..end).ok_or(SendError::Closed)?;
            self.write_chunk(&mut scratch, chunk)?;
            offset = end;
        }
        Ok(())
    }

    /// Builds one `channelData` envelope into `scratch` and writes it.
    ///
    /// The envelope is encoded with the payload supplied APART from the frame
    /// ([`MuxFrame::encode_with_payload_into`]), so the chunk is copied exactly once — into the
    /// buffer that goes to the socket. Building a `MuxFrame::ChannelData { payload: chunk.to_vec()
    /// }` and calling `encode` would copy it twice and allocate both times, per chunk, forever.
    fn write_chunk(&self, scratch: &mut Vec<u8>, chunk: &[u8]) -> Result<(), SendError> {
        let frame = MuxFrame::ChannelData {
            channel_id: self.channel_id,
            payload: Vec::new(),
        };
        let needed = frame.encoded_byte_count_with_payload(chunk.len());
        if scratch.len() < needed {
            scratch.resize(needed, 0);
        }
        let written = frame.encode_with_payload_into(chunk, scratch);
        let bytes = scratch.get(..written).ok_or(SendError::Closed)?;
        self.link
            .send(bytes)
            .map_err(|failure| SendError::Link(failure.to_string()))
    }

    /// Reserves between 1 and `max_wanted` bytes of send credit, parking while the window is empty.
    ///
    /// Associated rather than a method so the borrow is exactly the two fields it reads: a `&self`
    /// here would hold the whole channel across a park for no reason.
    fn await_chunk_credit(
        window: &SendWindow,
        finished: &AtomicBool,
        max_wanted: usize,
    ) -> Result<usize, SendError> {
        let wanted = i64::try_from(max_wanted).unwrap_or(i64::MAX);
        let mut credit = window.credit.lock().map_err(|_poisoned| SendError::Closed)?;
        loop {
            if finished.load(Ordering::Acquire) {
                return Err(SendError::Closed);
            }
            let available = credit.remaining();
            if available > 0 {
                let take = if available < wanted { available } else { wanted };
                // `take <= remaining`, so this is always allowed — the partial consume that keeps
                // an oversized message from parking forever.
                if let ConsumeResult::Allowed(_) = credit.consume(take) {
                    return usize::try_from(take).map_err(|_unrepresentable| SendError::Closed);
                }
            }
            credit = window
                .granted
                .wait(credit)
                .map_err(|_poisoned| SendError::Closed)?;
        }
    }

    /// Replenishes the send window by `bytes_to_add` and wakes every parked sender.
    ///
    /// A peer `windowAdjust`. A no-op on an unwindowed channel.
    pub fn grant_credit(&self, bytes_to_add: i64) {
        let Some(window) = self.send_window.as_ref() else {
            return;
        };
        if let Ok(mut credit) = window.credit.lock() {
            credit.adjust(bytes_to_add);
        }
        window.granted.notify_all();
    }

    // -------------------------------------------------------------- receiving

    /// Feeds one demuxed `channelData` body into this channel's decoder and hands every complete
    /// inner message to the consumer. Answers how many wire bytes were taken.
    ///
    /// A decode fault is fatal for THIS channel and harmless to its siblings: the channel is
    /// finished with [`ChannelEnd::Decode`], the decoder poisons itself so a body already in flight
    /// is dropped rather than re-buffered, and the caller reads [`Self::is_finished`] to stop
    /// routing to it.
    ///
    /// No credit is granted here. Granting at demux time would let an output flood buffer without
    /// bound between the demux and whoever actually reads it — the demux always keeps up with the
    /// wire, so the peer's backpressure would never engage. The grant comes from
    /// [`Self::note_consumed`], which the REAL consumer calls.
    pub fn deliver(&self, payload: &[u8]) -> usize {
        let Ok(mut decoder) = self.inbound_decoder.lock() else {
            return payload.len();
        };
        decoder.append(payload);
        loop {
            match decoder.next_message() {
                Ok(Some(message)) => {
                    let Ok(mut inbound) = self.inbound.lock() else {
                        break;
                    };
                    let Some(sender) = inbound.as_ref() else {
                        break;
                    };
                    if sender.send(message).is_err() {
                        // The consumer is gone. Drop the sender so nothing keeps feeding a stream
                        // nobody reads, and stop.
                        *inbound = None;
                        break;
                    }
                },
                Ok(None) => break,
                Err(fault) => {
                    let reason = fault.to_string();
                    drop(decoder);
                    self.finish_with(ChannelEnd::Decode(reason));
                    break;
                },
            }
        }
        payload.len()
    }

    /// Reports that `bytes` wire bytes were CONSUMED — rendered, or written to the PTY — and emits
    /// the peer's window grant once the accountant's threshold is crossed.
    ///
    /// Credit-at-CONSUMPTION, not at demux: see [`Self::deliver`]. Every DATA consumer must call
    /// this per message it processes, or its peer parks after one window and never wakes.
    pub fn note_consumed(&self, bytes: usize) {
        let Some(receive) = self.receive_window.as_ref() else {
            return;
        };
        let taken = i64::try_from(bytes).unwrap_or(i64::MAX);
        let Ok(mut accountant) = receive.accountant.lock() else {
            return;
        };
        let Some(grant) = accountant.consume(taken) else {
            return;
        };
        drop(accountant);
        let bytes_to_add = u32::try_from(grant).unwrap_or(u32::MAX);
        let adjust = MuxFrame::WindowAdjust {
            channel_id: self.channel_id,
            bytes_to_add,
        }
        .encode();
        // A failed grant means the control link is gone, which its own receive loop is already
        // finding out. There is nobody to report it to here.
        drop(receive.grant_link.send(&adjust));
    }

    // ---------------------------------------------------------------- ending

    /// Ends the channel because this side closed it.
    pub fn finish(&self) {
        self.finish_with(ChannelEnd::Local);
    }

    /// Ends the channel because the peer named it, with the reason the peer gave.
    pub fn finish_closed_by_peer(&self, reason: MuxCloseReason) {
        self.finish_with(ChannelEnd::Peer(reason));
    }

    /// Ends the channel because the link under it died.
    pub fn finish_link_down(&self) {
        self.finish_with(ChannelEnd::LinkDown);
    }

    /// Ends the channel once, recording `end`, closing the inbound stream and waking every parked
    /// sender so a close with an empty window does not strand one.
    ///
    /// Idempotent by the compare-exchange: the FIRST reason to arrive is the one recorded, because
    /// a link dropping under a channel the peer already closed should not overwrite the peer's
    /// answer with the accident that followed it.
    fn finish_with(&self, end: ChannelEnd) {
        if self
            .finished
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        if let Ok(mut slot) = self.end.lock() {
            *slot = Some(end);
        }
        if let Ok(mut inbound) = self.inbound.lock() {
            *inbound = None; // the consumer's `recv` now reports disconnection
        }
        if let Some(window) = self.send_window.as_ref() {
            // Take the lock before notifying so a sender between its `finished` check and its wait
            // cannot miss the wakeup and park forever.
            drop(window.credit.lock());
            window.granted.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::io;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use slopdesk_wire::mux::admission::Link;
    use slopdesk_wire::{MuxFrame, MuxFrameDecoder, WireMessage};

    use super::{ChannelEnd, SendError, SubChannel};
    use crate::link::ByteLink;

    /// A link that records what was written to it and never reads.
    #[derive(Debug, Default)]
    struct Recorder {
        written: Mutex<Vec<u8>>,
        closed: AtomicBool,
        fail: AtomicBool,
    }

    /// Coerces a concrete recorder into the trait object the channel takes. A free function
    /// because the coercion has to happen at a return position; an `as` cast is a trivial cast the
    /// crate's lint block refuses.
    fn shared(recorder: &Arc<Recorder>) -> Arc<dyn ByteLink> {
        let concrete: Arc<Recorder> = Arc::clone(recorder);
        concrete
    }

    impl Recorder {
        fn frames(&self) -> Vec<MuxFrame> {
            let mut decoder = MuxFrameDecoder::new();
            decoder.append(&self.written.lock().unwrap());
            let mut out = Vec::new();
            while let Some(frame) = decoder.next_frame().expect("the recorder holds whole frames") {
                out.push(frame);
            }
            out
        }
    }

    impl ByteLink for Recorder {
        fn send(&self, bytes: &[u8]) -> io::Result<()> {
            if self.fail.load(Ordering::Acquire) {
                return Err(io::Error::other("the test asked this write to fail"));
            }
            self.written.lock().unwrap().extend_from_slice(bytes);
            Ok(())
        }

        fn recv(&self, _buf: &mut [u8]) -> io::Result<usize> {
            Ok(0)
        }

        fn close(&self) {
            self.closed.store(true, Ordering::Release);
        }
    }

    fn keystroke(bytes: &[u8]) -> WireMessage {
        WireMessage::Input(bytes.to_vec())
    }

    #[test]
    fn a_control_send_is_one_envelope_and_never_gated() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::control(7, shared(&link));
        channel.send(&keystroke(b"resize")).expect("control never blocks");
        let frames = link.frames();
        assert_eq!(frames.len(), 1, "one message, one envelope");
        assert_eq!(frames[0].channel_id(), 7);
    }

    /// The property the chunking exists for: a message LARGER than the whole window still lands.
    #[test]
    fn a_message_larger_than_the_window_is_chunked_rather_than_parked_forever() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::with_send_window(3, Link::Data, shared(&link), Some(16));
        let sender = Arc::clone(&channel);
        let writing = std::thread::spawn(move || sender.send(&keystroke(&[b'x'; 200])));

        // It cannot finish on 16 bytes of credit, so grant repeatedly until it does. A bounded
        // probe, not a sleep: the loop ends the moment the send returns.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !writing.is_finished() {
            assert!(Instant::now() < deadline, "the chunked send never completed");
            channel.grant_credit(16);
            std::thread::sleep(Duration::from_millis(1));
        }
        writing
            .join()
            .expect("the sending thread did not panic")
            .expect("the send completed");

        let frames = link.frames();
        assert!(
            frames.len() > 1,
            "a 200-byte message on a 16-byte window must chunk"
        );
        let carried: usize = frames.iter().map(|frame| frame.opaque_payload().len()).sum();
        assert_eq!(
            carried,
            keystroke(&[b'x'; 200]).encode().len(),
            "every byte arrived, once"
        );
    }

    /// A sender parked on an empty window must fail when the channel ends, not hang.
    #[test]
    fn finishing_wakes_a_sender_parked_on_an_empty_window() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::with_send_window(3, Link::Data, shared(&link), Some(0));
        let sender = Arc::clone(&channel);
        let writing = std::thread::spawn(move || sender.send(&keystroke(b"blocked")));

        let deadline = Instant::now() + Duration::from_secs(10);
        while !writing.is_finished() {
            assert!(Instant::now() < deadline, "finish did not wake the parked sender");
            channel.finish();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            writing.join().expect("no panic"),
            Err(SendError::Closed),
            "the woken sender reports the close rather than proceeding",
        );
        assert_eq!(channel.end(), Some(ChannelEnd::Local));
    }

    #[test]
    fn delivered_bodies_are_reassembled_into_whole_messages() {
        let link = Arc::new(Recorder::default());
        let (channel, inbound) = SubChannel::control(1, shared(&link));
        let framed = keystroke(b"hello").encode();
        // Split mid-frame: reassembly across `channelData` boundaries is the whole contract.
        let (head, tail) = framed.split_at(3);
        assert_eq!(channel.deliver(head), head.len());
        assert_eq!(channel.deliver(tail), tail.len());
        assert_eq!(
            inbound.try_recv().expect("one whole message"),
            keystroke(b"hello")
        );
    }

    #[test]
    fn a_decode_fault_finishes_only_this_channel_and_says_why() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::control(1, shared(&link));
        // A length prefix no frame can satisfy: the decoder faults rather than buffering forever.
        channel.deliver(&[0xFF, 0xFF, 0xFF, 0xFF, 0x01]);
        assert!(channel.is_finished());
        assert!(matches!(channel.end(), Some(ChannelEnd::Decode(_))));
    }

    #[test]
    fn a_grant_rides_the_control_link_not_the_data_one() {
        let data = Arc::new(Recorder::default());
        let control = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::data(5, shared(&data), shared(&control));
        // A whole window's worth of consumption crosses the accountant's threshold.
        channel
            .note_consumed(usize::try_from(slopdesk_wire::MuxFlowControl::initial_window_bytes()).unwrap());
        assert!(data.frames().is_empty(), "no grant on the flooded link");
        let frames = control.frames();
        assert_eq!(frames.len(), 1);
        assert!(
            matches!(frames[0], MuxFrame::WindowAdjust { channel_id: 5, .. }),
            "the grant names this channel: {:?}",
            frames[0],
        );
    }

    #[test]
    fn the_first_reason_to_arrive_is_the_one_kept() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::control(1, shared(&link));
        channel.finish_closed_by_peer(slopdesk_wire::MuxCloseReason::SubscriberEvicted);
        // The link dying afterwards must not overwrite the peer's answer with the accident.
        channel.finish_link_down();
        assert_eq!(
            channel.end(),
            Some(ChannelEnd::Peer(slopdesk_wire::MuxCloseReason::SubscriberEvicted)),
        );
    }

    #[test]
    fn a_send_after_the_channel_ends_fails_rather_than_writing() {
        let link = Arc::new(Recorder::default());
        let (channel, _inbound) = SubChannel::control(1, shared(&link));
        channel.finish();
        assert_eq!(channel.send(&keystroke(b"late")), Err(SendError::Closed));
        assert!(link.frames().is_empty());
    }

    #[test]
    fn a_link_write_failure_surfaces_to_the_caller() {
        let link = Arc::new(Recorder::default());
        link.fail.store(true, Ordering::Release);
        let (channel, _inbound) = SubChannel::control(1, shared(&link));
        assert!(matches!(
            channel.send(&keystroke(b"doomed")),
            Err(SendError::Link(_))
        ));
    }
}
