//! RFC 6455 framing: one frame off a buffer, one frame onto the wire, and the reassembly that
//! turns a run of them back into a message.
//!
//! ## Reassembly is not optional, and it is easy to believe it is
//!
//! The Swift lanes this replaces called `NWConnection.receiveMessage`, which hands back messages
//! that the framework has already reassembled, and their comment said "there is no defragmentation
//! here". That was a true statement about `NWConnection` and a false one about the wire: a server
//! is free to split any message across a first frame and a run of continuations, and a reader that
//! treated each frame as a message would hand half an access unit to the decoder. What the
//! framework did for free is [`Reassembler`] here.
//!
//! ## An untrusted decoder's three obligations
//!
//! The frames come over the mesh from a process the user installed, so this follows the same rule
//! `slopdesk_devicepanel::sim_stream` states for the payloads inside them: an optional answer,
//! validate-then-drop, and not one byte read without a bounds check. Three things are therefore
//! refused rather than trusted — a reserved bit, a control frame that is fragmented or longer than
//! the 125 bytes RFC 6455 §5.5 allows, and a payload longer than [`PAYLOAD_CEILING`]. A length
//! field is a claim, and honouring a 2⁶³-byte claim is an allocation a peer chose for us.

/// The most a single frame's payload may claim before the link is failed.
///
/// Sized for what actually crosses: a simulator access unit runs to tens of kilobytes and a JPEG
/// seed to a few hundred. Sixteen mebibytes is two orders of magnitude of headroom over the largest
/// legitimate message and still small enough that a hostile claim cannot exhaust the app.
pub const PAYLOAD_CEILING: usize = 16 << 20;

/// The most a reassembled message may reach across its fragments. Same argument as
/// [`PAYLOAD_CEILING`]: a peer must not be able to spend the app's memory one continuation at a
/// time.
pub const MESSAGE_CEILING: usize = 16 << 20;

/// The longest payload a control frame may carry. RFC 6455 §5.5.
const CONTROL_CEILING: usize = 125;

/// What a frame's four opcode bits mean, for the six this client speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Opcode {
    /// More of the message the last non-continuation frame began.
    Continuation,
    /// A whole message, or its first fragment, carrying UTF-8.
    Text,
    /// The same, carrying bytes.
    Binary,
    /// The peer is closing.
    Close,
    /// Answer with a [`Self::Pong`] carrying the same payload.
    Ping,
    /// The answer to a ping. Never generated here; accepted and ignored.
    Pong,
}

impl Opcode {
    /// The opcode a nibble names, or `None` for one no build of this client speaks — the reserved
    /// ranges, which RFC 6455 §5.2 says to fail the connection on rather than skip.
    const fn from_nibble(nibble: u8) -> Option<Self> {
        match nibble {
            0x0 => Some(Self::Continuation),
            0x1 => Some(Self::Text),
            0x2 => Some(Self::Binary),
            0x8 => Some(Self::Close),
            0x9 => Some(Self::Ping),
            0xA => Some(Self::Pong),
            _ => None,
        }
    }

    /// The nibble this opcode is written as.
    const fn nibble(self) -> u8 {
        match self {
            Self::Continuation => 0x0,
            Self::Text => 0x1,
            Self::Binary => 0x2,
            Self::Close => 0x8,
            Self::Ping => 0x9,
            Self::Pong => 0xA,
        }
    }

    /// Whether this is one of the three frames that may interleave with a fragmented message and
    /// may never themselves be fragmented.
    const fn is_control(self) -> bool {
        matches!(self, Self::Close | Self::Ping | Self::Pong)
    }
}

/// One frame, borrowing its payload from the read buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame<'a> {
    /// Whether this frame ends the message it belongs to.
    pub fin: bool,
    /// What the frame is.
    pub opcode: Opcode,
    /// The payload, unmasked — a server frame carries no mask, and one that does is refused.
    pub payload: &'a [u8],
}

/// What one attempt to read a frame off the front of a buffer found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step<'a> {
    /// A whole frame, and how many bytes of the buffer it consumed.
    Frame(Frame<'a>, usize),
    /// Nothing yet: the buffer holds a prefix of a frame. Read more.
    Partial,
    /// The peer broke the protocol. Fail the link; do not resynchronise — RFC 6455 §7.1.7, and the
    /// practical reason is that there is no way to find the next frame boundary in a stream whose
    /// framing just proved untrustworthy.
    Invalid,
}

/// Read one frame off the front of `buffer`.
#[must_use]
pub fn step(buffer: &[u8]) -> Step<'_> {
    let (Some(&first), Some(&second)) = (buffer.first(), buffer.get(1)) else {
        return Step::Partial;
    };
    // RSV1..3 are extension bits and this client negotiates no extensions, so a set one is a
    // server talking a dialect that was never agreed.
    if first & 0x70 != 0 {
        return Step::Invalid;
    }
    let Some(opcode) = Opcode::from_nibble(first & 0x0F) else {
        return Step::Invalid;
    };
    let fin = first & 0x80 != 0;
    // A server frame is never masked (RFC 6455 §5.1). One that is came from something that is not
    // speaking the server half of this protocol.
    if second & 0x80 != 0 {
        return Step::Invalid;
    }

    let short = usize::from(second & 0x7F);
    let (length, header): (usize, usize) = match short {
        126 => {
            match buffer.get(2..4) {
                Some(&[high, low]) => (usize::from(u16::from_be_bytes([high, low])), 4),
                _ => return Step::Partial,
            }
        },
        127 => {
            match buffer.get(2..10) {
                Some(bytes) => {
                    let mut wide = [0_u8; 8];
                    for (slot, byte) in wide.iter_mut().zip(bytes) {
                        *slot = *byte;
                    }
                    let claimed = u64::from_be_bytes(wide);
                    // The claim is refused BEFORE it is narrowed: on a 64-bit host the cast would
                    // succeed and the ceiling would catch it, but the order here is the one that stays
                    // right if this is ever built somewhere narrower.
                    match usize::try_from(claimed) {
                        Ok(length) => (length, 10),
                        Err(_) => return Step::Invalid,
                    }
                },
                None => return Step::Partial,
            }
        },
        _ => (short, 2),
    };

    if length > PAYLOAD_CEILING {
        return Step::Invalid;
    }
    if opcode.is_control() && (!fin || length > CONTROL_CEILING) {
        return Step::Invalid;
    }
    let Some(total) = header.checked_add(length) else {
        return Step::Invalid;
    };
    let Some(payload) = buffer.get(header..total) else {
        return Step::Partial;
    };
    Step::Frame(Frame { fin, opcode, payload }, total)
}

/// Write one client frame.
///
/// Always masked: RFC 6455 §5.3 requires it of every client frame, and a server is required to
/// fail the connection on an unmasked one. The mask is a per-frame value from the caller — see the
/// handshake module on where randomness matters here and where it does not.
#[must_use]
pub fn encode(opcode: Opcode, payload: &[u8], mask: [u8; 4]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 14);
    out.push(0x80 | opcode.nibble());
    let length = payload.len();
    if length < 126 {
        // The cast is exact: this arm is only reached below 126.
        out.push(0x80 | u8::try_from(length).unwrap_or(0));
    } else if let Ok(short) = u16::try_from(length) {
        out.push(0x80 | 0x7E);
        out.extend_from_slice(&short.to_be_bytes());
    } else {
        out.push(0x80 | 0x7F);
        out.extend_from_slice(&u64::try_from(length).unwrap_or(u64::MAX).to_be_bytes());
    }
    out.extend_from_slice(&mask);
    for (at, byte) in payload.iter().enumerate() {
        // The mask cycles every four bytes; `& 3` is the index RFC 6455 §5.3 names.
        out.push(byte ^ mask.get(at & 3).copied().unwrap_or(0));
    }
    out
}

/// A whole message, once its fragments have been put back together.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// A complete text message. Not validated as UTF-8 here — the lane decides what a bad byte
    /// means for its own payload.
    Text(Vec<u8>),
    /// A complete binary message.
    Binary(Vec<u8>),
    /// The peer is closing; the payload is its code and reason, which this client does not read.
    Close,
    /// A ping, to be answered with its own payload.
    Ping(Vec<u8>),
}

/// The fragment fold: frames in, whole messages out.
///
/// Control frames pass STRAIGHT through, even in the middle of a fragmented message, which is what
/// RFC 6455 §5.4 requires — a ping that had to wait for a 400 kB access unit to finish arriving
/// would be answered after the server's idle timer had already given up on it.
#[derive(Debug, Default)]
pub struct Reassembler {
    /// The opcode of the message being assembled, or `None` between messages.
    started: Option<Opcode>,
    /// What has arrived of it.
    buffer: Vec<u8>,
}

/// What one frame did to the fold.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Folded {
    /// A message finished.
    Message(Message),
    /// The frame was absorbed; there is nothing to deliver yet.
    Pending,
    /// The peer broke the protocol — a continuation with nothing to continue, a new message on top
    /// of an unfinished one, or a message past [`MESSAGE_CEILING`]. Fail the link.
    Invalid,
}

impl Reassembler {
    /// A fold with no message in progress.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            started: None,
            buffer: Vec::new(),
        }
    }

    /// Absorb one frame.
    pub fn push(&mut self, frame: Frame<'_>) -> Folded {
        match frame.opcode {
            Opcode::Close => return Folded::Message(Message::Close),
            Opcode::Ping => return Folded::Message(Message::Ping(frame.payload.to_vec())),
            // A pong is the answer to a ping this client never sends; accepted and dropped.
            Opcode::Pong => return Folded::Pending,
            Opcode::Continuation if self.started.is_none() => return Folded::Invalid,
            Opcode::Text | Opcode::Binary if self.started.is_some() => return Folded::Invalid,
            Opcode::Continuation | Opcode::Text | Opcode::Binary => {},
        }

        if self.buffer.len().saturating_add(frame.payload.len()) > MESSAGE_CEILING {
            return Folded::Invalid;
        }
        let kind = self.started.unwrap_or(frame.opcode);
        self.buffer.extend_from_slice(frame.payload);
        if !frame.fin {
            self.started = Some(kind);
            return Folded::Pending;
        }

        self.started = None;
        let whole = core::mem::take(&mut self.buffer);
        match kind {
            Opcode::Text => Folded::Message(Message::Text(whole)),
            _ => Folded::Message(Message::Binary(whole)),
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]
    #![expect(clippy::panic, reason = "a let-else in a test has nowhere else to go")]
    #![expect(clippy::indexing_slicing, reason = "a test drives literals it wrote itself")]

    use super::{Folded, Frame, Message, Opcode, Reassembler, Step, encode, step};

    /// A server frame, unmasked, with the short length form.
    fn server(fin: bool, opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![if fin { 0x80 | opcode } else { opcode }];
        out.push(u8::try_from(payload.len()).unwrap());
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn a_whole_binary_frame_reads_back_with_its_length() {
        let bytes = server(true, 0x2, b"pixels");
        let Step::Frame(frame, consumed) = step(&bytes) else {
            panic!("a whole frame");
        };
        assert_eq!(consumed, bytes.len());
        assert_eq!(frame, Frame {
            fin: true,
            opcode: Opcode::Binary,
            payload: b"pixels"
        });
    }

    #[test]
    fn a_prefix_asks_for_more_rather_than_guessing() {
        let bytes = server(true, 0x2, b"pixels");
        for cut in 0..bytes.len() {
            assert_eq!(step(&bytes[..cut]), Step::Partial, "cut at {cut}");
        }
    }

    /// The two extended length forms, each at its own boundary.
    #[test]
    fn the_extended_length_forms_are_read_at_their_boundaries() {
        let payload = vec![7_u8; 200];
        let mut medium = vec![0x82, 126, 0, 200];
        medium.extend_from_slice(&payload);
        let Step::Frame(frame, consumed) = step(&medium) else {
            panic!("a 16-bit length");
        };
        assert_eq!((consumed, frame.payload.len()), (204, 200));

        let mut wide = vec![0x82, 127];
        wide.extend_from_slice(&200_u64.to_be_bytes());
        wide.extend_from_slice(&payload);
        let Step::Frame(frame, consumed) = step(&wide) else {
            panic!("a 64-bit length");
        };
        assert_eq!((consumed, frame.payload.len()), (210, 200));
    }

    /// The allocation a peer must not get to choose. The claim is refused on the HEADER, before a
    /// byte of the payload has been waited for.
    #[test]
    fn a_length_past_the_ceiling_fails_the_link_rather_than_waiting_for_it() {
        let mut hostile = vec![0x82, 127];
        hostile.extend_from_slice(&u64::MAX.to_be_bytes());
        assert_eq!(step(&hostile), Step::Invalid);

        let mut large = vec![0x82, 127];
        large.extend_from_slice(&(u64::try_from(super::PAYLOAD_CEILING).unwrap() + 1).to_be_bytes());
        assert_eq!(step(&large), Step::Invalid);
    }

    #[test]
    fn a_reserved_bit_or_a_reserved_opcode_fails_the_link() {
        assert_eq!(step(&[0xC2, 0x00]), Step::Invalid);
        assert_eq!(step(&[0x83, 0x00]), Step::Invalid);
        assert_eq!(step(&[0x8B, 0x00]), Step::Invalid);
    }

    #[test]
    fn a_masked_server_frame_is_not_a_server_frame() {
        assert_eq!(step(&[0x82, 0x80, 1, 2, 3, 4]), Step::Invalid);
    }

    #[test]
    fn a_control_frame_may_be_neither_long_nor_fragmented() {
        assert_eq!(step(&server(true, 0x9, &[3_u8; 126])), Step::Invalid);
        assert_eq!(step(&server(false, 0x9, b"ping")), Step::Invalid);
    }

    /// The property the Swift original got for free and this must do itself.
    #[test]
    fn a_message_split_across_continuations_arrives_whole() {
        let mut fold = Reassembler::new();
        assert_eq!(
            fold.push(Frame {
                fin: false,
                opcode: Opcode::Binary,
                payload: b"one"
            }),
            Folded::Pending
        );
        assert_eq!(
            fold.push(Frame {
                fin: false,
                opcode: Opcode::Continuation,
                payload: b"two"
            }),
            Folded::Pending
        );
        assert_eq!(
            fold.push(Frame {
                fin: true,
                opcode: Opcode::Continuation,
                payload: b"three"
            }),
            Folded::Message(Message::Binary(b"onetwothree".to_vec()))
        );
    }

    /// A ping that had to wait for the access unit around it to finish would be answered after the
    /// server's idle timer had given up.
    #[test]
    fn a_ping_between_two_fragments_is_answered_without_disturbing_them() {
        let mut fold = Reassembler::new();
        let _pending = fold.push(Frame {
            fin: false,
            opcode: Opcode::Text,
            payload: b"{\"a\":",
        });
        assert_eq!(
            fold.push(Frame {
                fin: true,
                opcode: Opcode::Ping,
                payload: b"beat"
            }),
            Folded::Message(Message::Ping(b"beat".to_vec()))
        );
        assert_eq!(
            fold.push(Frame {
                fin: true,
                opcode: Opcode::Continuation,
                payload: b"1}"
            }),
            Folded::Message(Message::Text(b"{\"a\":1}".to_vec()))
        );
    }

    #[test]
    fn a_continuation_with_nothing_to_continue_fails_the_link() {
        let mut fold = Reassembler::new();
        assert_eq!(
            fold.push(Frame {
                fin: true,
                opcode: Opcode::Continuation,
                payload: b"x"
            }),
            Folded::Invalid
        );
    }

    #[test]
    fn a_new_message_on_top_of_an_unfinished_one_fails_the_link() {
        let mut fold = Reassembler::new();
        let _pending = fold.push(Frame {
            fin: false,
            opcode: Opcode::Text,
            payload: b"x",
        });
        assert_eq!(
            fold.push(Frame {
                fin: true,
                opcode: Opcode::Binary,
                payload: b"y"
            }),
            Folded::Invalid
        );
    }

    /// A client frame is masked, and unmasking it with its own key gives the payload back — which
    /// is the whole of what the mask is.
    #[test]
    fn a_client_frame_is_masked_and_round_trips_through_its_own_key() {
        let written = encode(Opcode::Text, b"{\"type\":\"touch1-move\"}", [
            0x37, 0xFA, 0x21, 0x3D,
        ]);
        assert_eq!(written[0], 0x81);
        assert_eq!(written[1] & 0x80, 0x80, "every client frame is masked");
        let mask = &written[2..6];
        let unmasked: Vec<u8> = written[6..]
            .iter()
            .enumerate()
            .map(|(at, byte)| byte ^ mask[at & 3])
            .collect();
        assert_eq!(unmasked, b"{\"type\":\"touch1-move\"}");
    }

    #[test]
    fn an_empty_client_frame_is_a_header_and_a_mask() {
        assert_eq!(encode(Opcode::Pong, &[], [1, 2, 3, 4]), vec![
            0x8A, 0x80, 1, 2, 3, 4
        ]);
    }

    #[test]
    fn the_client_writes_the_length_form_the_payload_needs() {
        assert_eq!(encode(Opcode::Binary, &[0; 125], [0; 4])[1], 0x80 | 0x7D);
        assert_eq!(encode(Opcode::Binary, &[0; 126], [0; 4])[1], 0x80 | 0x7E);
        let wide = vec![0_u8; 70_000];
        assert_eq!(encode(Opcode::Binary, &wide, [0; 4])[1], 0x80 | 0x7F);
    }
}
