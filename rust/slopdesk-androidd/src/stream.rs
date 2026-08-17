//! The scrcpy video stream's CLIENT end — framing in, access units out.
//!
//! The bridge relays `scrcpy-server`'s stream verbatim, so the daemon never looks inside it and the
//! panel does all the reading. That put a stateful reassembler and an Annex-B rewriter in Swift, on
//! the per-frame path, over bytes a DEVICE wrote. `docs/DECISIONS.md`'s stage-17 rule puts each
//! protocol's client end in the crate that owns the protocol, and this crate already owns scrcpy's
//! dialect — the launch sequence, the version pin, the socket order.
//!
//! ## A byte stream, not a sequence of messages
//! A `recv` hands back whatever arrived: half a header, three frames, a header and two bytes of its
//! payload. So this consumes what it can and keeps the rest. Getting it wrong does not fail loudly
//! — it decodes garbage into a display layer — which is why the reassembly is what the tests lean
//! on hardest, every framing case fed one byte at a time as well as whole.
//!
//! ## The framing
//! ```text
//! [4 bytes BE codec id]   "h264" / "h265" / "\0av1"   — once, at the head of the stream
//! then repeatedly, a 12-byte header:
//!
//!   MSB SET → session packet (video only), no payload:
//!     byte 0: 1000000 0                       byte 3 bit 0: client-resized flag
//!     bytes 4..7:  width  (u32 BE)            bytes 8..11: height (u32 BE)
//!
//!   MSB CLEAR → media packet, followed by <size> bytes:
//!     bytes 0..7:  0 C K <61-bit PTS>         C = config packet, K = key frame
//!     bytes 8..11: size (u32 BE)
//! ```
//!
//! ## What is NOT here
//! The Annex-B walk and the AVCC rewrite. Those are `slopdesk_video::annexb`, next to the AVCC
//! walker that is their other half — the two framings carry the SAME NAL units, and the HEVC type
//! reading was already spelled out once in `slopdesk_video::hevc_parameter_sets`.
//!
//! ## Why a cursor rather than a re-based buffer
//! The Swift original removed each consumed message from the front of a `Data`, which re-based the
//! remainder — a copy of everything still buffered, on EVERY frame. Its own comment named the cost
//! and accepted it, to dodge `Data`'s non-zero-based slice indices. That hazard does not exist
//! here, so the head is a cursor and the buffer compacts only once the consumed prefix is worth
//! reclaiming, which is what `slopdesk-inspectord`'s splitter already does for the same reason.

use core::ops::Range;

use crate::scrcpy::Codec;

/// Refuses a payload length no real stream produces.
///
/// A corrupted or misaligned header otherwise asks for a multi-gigabyte allocation, which is how a
/// decode bug becomes a memory panic instead of a dropped frame.
pub const MAX_PACKET: usize = 32 * 1024 * 1024;

/// Bytes of fixed header ahead of every packet after the codec id.
pub const HEADER_LEN: usize = 12;

const SESSION_FLAG: u8 = 0x80;
const CONFIG_FLAG: u8 = 0x40;
const KEY_FRAME_FLAG: u8 = 0x20;

/// Once the consumed prefix passes this, the buffer reclaims it. Large enough that an ordinary
/// burst of small frames does not memmove per frame, small enough that a stalled reader is not
/// holding a stale megabyte.
const COMPACT_THRESHOLD: usize = 64 * 1024;

/// One thing the stream said.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Message {
    /// The stream's codec, as its four ASCII bytes with the pad stripped. Read once, at the head.
    Codec(String),
    /// The video size changed, or was announced. Sent at the head and again on every rotation or
    /// display rebind.
    Session {
        /// Pixels across.
        width: u32,
        /// Pixels down.
        height: u32,
    },
    /// Parameter sets — SPS/PPS in Annex-B. Never displayed; it is what the format description is
    /// built from.
    Configuration(Vec<u8>),
    /// One access unit, still in Annex-B.
    AccessUnit {
        /// The Annex-B bytes.
        payload: Vec<u8>,
        /// Whether the device marked it a key frame.
        is_keyframe: bool,
    },
}

/// A stateful reassembler over the TCP byte stream.
///
/// Bytes in, whole messages out, nothing else: no socket, no callback, no lock.
#[derive(Clone, Default, Debug)]
pub struct StreamParser {
    buffer: Vec<u8>,
    /// How much of `buffer`'s head has been handed out already.
    consumed: usize,
    /// The four-byte codec id is read exactly once, at the head.
    has_read_codec: bool,
    corrupt: bool,
}

impl StreamParser {
    /// A parser at the head of a fresh stream.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether the stream has said something impossible.
    ///
    /// A desynchronised byte stream cannot be resynchronised — there are no start markers to hunt
    /// for — so the only honest response is to stop parsing and let the connection be redialled.
    #[must_use]
    pub const fn is_corrupt(&self) -> bool {
        self.corrupt
    }

    /// Bytes received and not yet consumed by a complete message.
    #[must_use]
    pub const fn buffered_len(&self) -> usize {
        self.buffer.len() - self.consumed
    }

    /// Adds received bytes. A corrupt parser ignores them.
    pub fn append(&mut self, incoming: &[u8]) {
        if self.corrupt {
            return;
        }
        self.buffer.extend_from_slice(incoming);
    }

    /// How many payload bytes the next complete message carries, WITHOUT consuming it.
    ///
    /// `None` when no whole message is buffered — including when the stream has just been found
    /// corrupt, which this call is what discovers. A caller sizing a buffer from this may always
    /// call again: the message is still there.
    pub fn peek_payload_len(&mut self) -> Option<usize> {
        Some(self.scan()?.0.payload.len())
    }

    /// The next complete message, or `None` when one is not yet whole.
    pub fn next_message(&mut self) -> Option<Message> {
        let (found, consumed) = self.scan()?;
        let payload = self
            .buffer
            .get(found.payload.clone())
            .unwrap_or_default()
            .to_vec();
        self.consumed += consumed;
        if self.consumed >= COMPACT_THRESHOLD {
            self.buffer.drain(..self.consumed);
            self.consumed = 0;
        }
        self.has_read_codec = true;
        Some(found.into_message(payload))
    }

    /// The unread remainder.
    fn rest(&self) -> &[u8] {
        self.buffer.get(self.consumed..).unwrap_or_default()
    }

    /// Reads the head of the remainder without advancing past it.
    ///
    /// Idempotent on purpose — it is what both `peek_payload_len` and `next_message` go through, so
    /// asking the size cannot change what is read next. The one state it does write is `corrupt`,
    /// which is a terminal verdict either way.
    fn scan(&mut self) -> Option<(Found, usize)> {
        if self.corrupt {
            return None;
        }
        let base = self.consumed;

        if !self.has_read_codec {
            let identifier: [u8; 4] = self.rest().get(..4)?.try_into().ok()?;
            // A leading NUL is how three-letter codecs are spelled (`\0av1`); it is stripped so the
            // caller compares against the name rather than against the padding.
            let start = identifier.iter().position(|byte| *byte != 0);
            let Some(start) = start.filter(|_| core::str::from_utf8(&identifier).is_ok()) else {
                // All-NUL, or not ASCII: the stream is not the one this speaks.
                self.corrupt = true;
                return None;
            };
            return Some((
                Found {
                    kind: Kind::Codec,
                    payload: base + start..base + 4,
                    size: (0, 0),
                    is_keyframe: false,
                },
                4,
            ));
        }

        let header: [u8; HEADER_LEN] = self.rest().get(..HEADER_LEN)?.try_into().ok()?;
        let flags = *header.first()?;

        if flags & SESSION_FLAG != 0 {
            return Some((
                Found {
                    kind: Kind::Session,
                    payload: base..base,
                    size: (read_u32(&header, 4)?, read_u32(&header, 8)?),
                    is_keyframe: false,
                },
                HEADER_LEN,
            ));
        }

        let size = read_u32(&header, 8)? as usize;
        if size == 0 || size > MAX_PACKET {
            // Length zero is what scrcpy's own demuxer rejects outright, and an absurd length means
            // the stream is no longer where we think it is.
            self.corrupt = true;
            return None;
        }
        // Wait for the whole payload rather than delivering it in pieces: an access unit is only
        // meaningful whole, and the decoder downstream takes it that way.
        let end = HEADER_LEN.checked_add(size)?;
        if self.rest().len() < end {
            return None;
        }
        let kind = if flags & CONFIG_FLAG != 0 {
            Kind::Configuration
        } else {
            Kind::AccessUnit
        };
        Some((
            Found {
                kind,
                payload: base + HEADER_LEN..base + end,
                size: (0, 0),
                is_keyframe: flags & KEY_FRAME_FLAG != 0,
            },
            end,
        ))
    }
}

/// What `scan` found: which message, and where its payload sits in the buffer.
///
/// The two scalars sit beside the tag rather than inside it because a `Session`-shaped variant is
/// three times the size of the others, which `variant_size_differences` rejects — and rightly, for
/// a value the hot loop builds per frame.
struct Found {
    kind: Kind,
    payload: Range<usize>,
    /// `Session`'s dimensions, and `(0, 0)` for every other kind.
    size: (u32, u32),
    /// `AccessUnit`'s key-frame mark, and `false` for every other kind.
    is_keyframe: bool,
}

impl Found {
    fn into_message(self, payload: Vec<u8>) -> Message {
        match self.kind {
            // Already proven UTF-8 by `scan`; a lossy read here would be a second, softer rule.
            Kind::Codec => Message::Codec(String::from_utf8_lossy(&payload).into_owned()),
            Kind::Session => {
                Message::Session {
                    width: self.size.0,
                    height: self.size.1,
                }
            },
            Kind::Configuration => Message::Configuration(payload),
            Kind::AccessUnit => {
                Message::AccessUnit {
                    payload,
                    is_keyframe: self.is_keyframe,
                }
            },
        }
    }
}

/// A message minus everything that varies, so `scan` can name one without copying anything.
enum Kind {
    Codec,
    Session,
    Configuration,
    AccessUnit,
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    let field: [u8; 4] = bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?;
    Some(u32::from_be_bytes(field))
}

/// The codec a stream identifier names, if the panel can display it.
///
/// [`Codec::parse`] is what the DAEMON asks the server for, and it knows three. This is the
/// client's question, which is narrower: AV1 is deliberately refused, because a decode session
/// gains it only on M3-class hardware and later, so offering it would make the panel's ability to
/// show anything depend on which Mac the CLIENT is running.
#[must_use]
pub fn decodable_codec(identifier: &str) -> Option<Codec> {
    match Codec::parse(identifier) {
        Some(Codec::Av1) | None => None,
        decodable => decodable,
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "cutting a fixture the test just built at an offset the test just chose: the `None` arm is \
              unreachable, and a panic in a test IS the failure report"
)]
mod tests {
    use super::{Codec, MAX_PACKET, Message, StreamParser, decodable_codec};

    /// A session packet: MSB set, no payload, the size fields at 4 and 8.
    fn session_packet(width: u32, height: u32) -> Vec<u8> {
        let mut data = vec![0x80, 0, 0, 0];
        data.extend_from_slice(&width.to_be_bytes());
        data.extend_from_slice(&height.to_be_bytes());
        data
    }

    /// A media packet: flags in byte 0, PTS ignored, size at 8.
    fn media_packet(flags: u8, payload: &[u8]) -> Vec<u8> {
        let mut data = vec![flags, 0, 0, 0, 0, 0, 0, 0];
        data.extend_from_slice(&u32::try_from(payload.len()).unwrap_or(u32::MAX).to_be_bytes());
        data.extend_from_slice(payload);
        data
    }

    /// Feeds a whole stream in one chunk.
    fn decode(stream: &[u8]) -> Vec<Message> {
        let mut parser = StreamParser::new();
        parser.append(stream);
        core::iter::from_fn(|| parser.next_message()).collect()
    }

    /// Feeds the same stream ONE BYTE AT A TIME. Any difference from `decode` is a reassembly bug,
    /// which is the class of bug this decoder exists not to have.
    fn decode_byte_at_a_time(stream: &[u8]) -> Vec<Message> {
        let mut parser = StreamParser::new();
        let mut messages = Vec::new();
        for byte in stream {
            parser.append(&[*byte]);
            while let Some(message) = parser.next_message() {
                messages.push(message);
            }
        }
        messages
    }

    #[test]
    fn the_codec_id_is_read_once_and_only_once() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert_eq!(parser.next_message(), Some(Message::Codec("h264".to_owned())));
        // The next four bytes are a header, not a second codec id.
        parser.append(&session_packet(1080, 2400));
        assert_eq!(
            parser.next_message(),
            Some(Message::Session {
                width: 1080,
                height: 2400
            })
        );
    }

    #[test]
    fn a_three_letter_codec_is_spelled_with_a_leading_nul() {
        assert_eq!(decode(b"\0av1"), vec![Message::Codec("av1".to_owned())]);
    }

    #[test]
    fn only_the_two_decodable_codecs_resolve() {
        assert_eq!(decodable_codec("h264"), Some(Codec::H264));
        assert_eq!(decodable_codec("h265"), Some(Codec::H265));
        // The daemon knows AV1 and will ask the server for it; this end still cannot show it.
        assert_eq!(Codec::parse("av1"), Some(Codec::Av1));
        assert_eq!(decodable_codec("av1"), None);
        assert_eq!(decodable_codec("vp9"), None);
    }

    #[test]
    fn an_all_nul_codec_id_is_corrupt_rather_than_empty() {
        let mut parser = StreamParser::new();
        parser.append(&[0, 0, 0, 0]);
        assert_eq!(parser.next_message(), None);
        assert!(parser.is_corrupt());
    }

    #[test]
    fn each_header_flag_selects_its_message() {
        let mut stream = b"h264".to_vec();
        stream.extend_from_slice(&session_packet(460, 1024));
        stream.extend_from_slice(&media_packet(0x40, &[0xAA, 0xBB]));
        stream.extend_from_slice(&media_packet(0x20, &[0xCC]));
        stream.extend_from_slice(&media_packet(0x00, &[0xDD]));

        let expected = vec![
            Message::Codec("h264".to_owned()),
            Message::Session {
                width: 460,
                height: 1024,
            },
            Message::Configuration(vec![0xAA, 0xBB]),
            Message::AccessUnit {
                payload: vec![0xCC],
                is_keyframe: true,
            },
            Message::AccessUnit {
                payload: vec![0xDD],
                is_keyframe: false,
            },
        ];
        assert_eq!(decode(&stream), expected);
        assert_eq!(decode_byte_at_a_time(&stream), expected);
    }

    #[test]
    fn a_packet_split_across_receives_is_held_until_it_is_whole() {
        // The failure this prevents: half an access unit handed to a decoder as a whole one.
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        let packet = media_packet(0x20, &[0xEE; 40]);
        parser.append(packet.get(..12 + 39).unwrap());
        assert_eq!(parser.next_message(), None);
        parser.append(packet.get(12 + 39..).unwrap());
        assert_eq!(
            parser.next_message(),
            Some(Message::AccessUnit {
                payload: vec![0xEE; 40],
                is_keyframe: true
            })
        );
    }

    #[test]
    fn a_header_split_across_receives_is_not_read_early() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        let session = session_packet(1080, 2400);
        parser.append(session.get(..11).unwrap());
        assert_eq!(parser.next_message(), None);
        parser.append(session.get(11..).unwrap());
        assert_eq!(
            parser.next_message(),
            Some(Message::Session {
                width: 1080,
                height: 2400
            })
        );
    }

    #[test]
    fn many_packets_in_one_receive_all_come_out() {
        // The ordinary case under load: a 64 KiB read holds several frames.
        let mut stream = b"h264".to_vec();
        for index in 0_u8..8 {
            stream.extend_from_slice(&media_packet(0, &[index]));
        }
        assert_eq!(decode(&stream).len(), 9);
    }

    #[test]
    fn a_length_of_zero_is_corruption_rather_than_an_empty_frame() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        parser.append(&media_packet(0, &[]));
        assert_eq!(parser.next_message(), None);
        assert!(parser.is_corrupt());
    }

    #[test]
    fn an_absurd_length_is_refused_rather_than_allocated() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        let mut header = vec![0_u8; 8];
        header.extend_from_slice(&u32::try_from(MAX_PACKET + 1).unwrap_or(u32::MAX).to_be_bytes());
        parser.append(&header);
        assert_eq!(parser.next_message(), None);
        assert!(parser.is_corrupt());
    }

    #[test]
    fn a_corrupt_parser_stays_silent_forever() {
        // No resynchronisation is attempted, so nothing may leak out afterwards.
        let mut parser = StreamParser::new();
        parser.append(&[0, 0, 0, 0]);
        assert_eq!(parser.next_message(), None);
        assert!(parser.is_corrupt());
        parser.append(&media_packet(0x20, &[1]));
        assert_eq!(parser.next_message(), None);
    }

    /// The cursor reclaims its head rather than growing without bound — the property the Swift
    /// original bought with a copy of the remainder on every single frame.
    #[test]
    fn a_long_stream_does_not_hold_every_byte_it_ever_read() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        for _ in 0..64 {
            parser.append(&media_packet(0, &[0xAB; 4096]));
            assert!(parser.next_message().is_some());
        }
        assert_eq!(parser.buffered_len(), 0, "everything read has been consumed");
        assert!(
            parser.buffer.len() < 64 * 4096,
            "and the consumed head was reclaimed rather than retained"
        );
    }

    /// Asking the size must not consume the message — the whole point of the peek is that a caller
    /// who sized too small may grow and call again with the frame still there.
    #[test]
    fn peeking_a_payload_length_leaves_the_message_where_it_was() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert_eq!(parser.peek_payload_len(), Some(4));
        assert_eq!(parser.peek_payload_len(), Some(4), "twice is the same answer");
        assert_eq!(parser.next_message(), Some(Message::Codec("h264".to_owned())));

        parser.append(&media_packet(0x20, &[0xEE; 40]));
        assert_eq!(parser.peek_payload_len(), Some(40));
        assert_eq!(
            parser.next_message(),
            Some(Message::AccessUnit {
                payload: vec![0xEE; 40],
                is_keyframe: true
            })
        );
        assert_eq!(parser.peek_payload_len(), None, "and nothing is left behind");
    }

    /// A session packet carries no payload, so its peek is zero rather than absent.
    #[test]
    fn a_session_packet_peeks_as_an_empty_payload() {
        let mut parser = StreamParser::new();
        parser.append(b"h264");
        assert!(parser.next_message().is_some());
        parser.append(&session_packet(1080, 2400));
        assert_eq!(parser.peek_payload_len(), Some(0));
    }
}
