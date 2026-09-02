//! Synthetic PATH-2 client over real UDP loopback.
//!
//! Drives the host's INPUT path directly (the root-cause location), so an ordering or
//! button-balance fix can be verified deterministically without the GUI client or a computer-use
//! cursor war. `slopdesk-ops video-input` starts an isolated host and hands it one gesture from
//! here, then reads the injection trace back out of the log.
//!
//! The datagram shapes are the wire's, not this file's — see `docs/20-wire-protocol.md`. What
//! lives here is only how a gesture becomes a sequence of them.

use std::io;
use std::net::UdpSocket;
use std::time::Duration;

/// The loopback the host binds when `slopdesk-ops video-input` starts it.
pub const HOST: &str = "127.0.0.1";
/// The media port, which carries control and input.
pub const MEDIA_PORT: u16 = 9000;
/// The cursor port, primed once so the host sees the same shape the real client makes.
pub const CURSOR_PORT: u16 = 9001;
/// The hello's protocol version.
const VERSION: u16 = 1;
/// Media datagrams are `[1-byte channel tag][payload]`.
const CH_CONTROL: u8 = 0x00;
/// The input channel's tag.
const CH_INPUT: u8 = 0x04;
/// The left mouse button.
const LEFT: u8 = 0;
/// The hello message type.
const MSG_HELLO: u8 = 0x01;
/// The ack message type.
const MSG_ACK: u8 = 0x02;

/// A mouse event's type byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Motion {
    /// Button down.
    Down = 2,
    /// Button up.
    Up = 3,
    /// Movement with the button held.
    Drag = 7,
}

/// The hello body, without its channel tag.
#[must_use]
pub fn hello_body(window_id: u32, width: f64, height: f64) -> Vec<u8> {
    let mut body = vec![MSG_HELLO];
    body.extend_from_slice(&VERSION.to_be_bytes());
    body.extend_from_slice(&window_id.to_be_bytes());
    body.extend_from_slice(&width.to_be_bytes());
    body.extend_from_slice(&height.to_be_bytes());
    body
}

/// One button event: `tag(u32) button(u8) clicks(u8) mods(u8) x(f64) y(f64)`.
#[must_use]
pub fn button_body(motion: Motion, tag: u32, x: f64, y: f64, clicks: u8) -> Vec<u8> {
    let mut body = vec![motion as u8];
    body.extend_from_slice(&tag.to_be_bytes());
    body.extend_from_slice(&[LEFT, clicks, 0]);
    body.extend_from_slice(&x.to_be_bytes());
    body.extend_from_slice(&y.to_be_bytes());
    body
}

/// What the host said about the hello.
#[derive(Debug, Clone, Copy, PartialEq)]
#[expect(
    variant_size_differences,
    reason = "one ack is parsed and matched, never held in a collection"
)]
pub enum Ack {
    /// A well-formed ack.
    Accepted {
        /// Nonzero when the host took the stream.
        accepted: u8,
        /// The stream the host assigned.
        stream_id: u32,
        /// Capture width in pixels.
        capture_width: u16,
        /// Capture height in pixels.
        capture_height: u16,
        /// The window's bounds in points: x, y, width, height.
        bounds: [f64; 4],
    },
    /// A datagram on some other channel.
    OtherChannel(u8),
    /// A control datagram that is not an ack.
    NotAck(u8),
    /// Too short to read.
    Truncated(usize),
}

impl Ack {
    /// Whether the host took the stream.
    #[must_use]
    pub const fn accepted(&self) -> bool {
        matches!(self, Self::Accepted { accepted, .. } if *accepted != 0)
    }
}

/// Read one ack out of a media datagram.
#[must_use]
pub fn parse_ack(data: &[u8]) -> Ack {
    let Some((&tag, payload)) = data.split_first() else {
        return Ack::Truncated(data.len());
    };
    if payload.is_empty() {
        return Ack::Truncated(data.len());
    }
    if tag != CH_CONTROL {
        return Ack::OtherChannel(tag);
    }
    let kind = payload.first().copied().unwrap_or(0);
    if kind != MSG_ACK {
        return Ack::NotAck(kind);
    }
    let Some(rest) = payload.get(1..42) else {
        return Ack::Truncated(data.len());
    };
    let byte = |at: usize| rest.get(at).copied().unwrap_or(0);
    let be16 = |at: usize| u16::from_be_bytes([byte(at), byte(at + 1)]);
    let be32 = |at: usize| u32::from_be_bytes([byte(at), byte(at + 1), byte(at + 2), byte(at + 3)]);
    let be64 = |at: usize| {
        let mut eight = [0_u8; 8];
        for (slot, offset) in eight.iter_mut().zip(at..at + 8) {
            *slot = byte(offset);
        }
        f64::from_be_bytes(eight)
    };
    Ack::Accepted {
        accepted: byte(0),
        stream_id: be32(1),
        capture_width: be16(5),
        capture_height: be16(7),
        bounds: [be64(9), be64(17), be64(25), be64(33)],
    }
}

/// A connected media socket, plus the monotonically increasing event tag.
#[derive(Debug)]
pub struct Client {
    media: UdpSocket,
    cursor: UdpSocket,
    tag: u32,
}

impl Client {
    /// Dial the host and prime the cursor port the way the real client does.
    ///
    /// # Errors
    /// When either socket cannot be bound or connected.
    pub fn dial(media_port: u16, cursor_port: u16) -> io::Result<Self> {
        let media = UdpSocket::bind("0.0.0.0:0")?;
        media.connect((HOST, media_port))?;
        media.set_read_timeout(Some(Duration::from_secs(2)))?;
        let cursor = UdpSocket::bind("0.0.0.0:0")?;
        cursor.connect((HOST, cursor_port))?;
        // Cursor prime — mirrors the real client, and harmless.
        cursor.send(&[0x00])?;
        Ok(Self {
            media,
            cursor,
            // The Python this replaces started at 101, and the host only ever compares tags for
            // ordering, so the first tag is arbitrary as long as it is stable.
            tag: 100,
        })
    }

    /// Say hello and read the host's answer.
    ///
    /// # Errors
    /// When the send fails. A read timeout is an `Ack::Truncated(0)`, not an error.
    pub fn hello(&self, window_id: u32) -> io::Result<Ack> {
        let mut datagram = vec![CH_CONTROL];
        datagram.extend_from_slice(&hello_body(window_id, 656.0, 433.0));
        self.media.send(&datagram)?;
        let mut buffer = [0_u8; 2048];
        // A read timeout is not an error: a host that never answered is a finding the caller
        // prints, not a failure to send.
        Ok(self.media.recv(&mut buffer).map_or(Ack::Truncated(0), |read| {
            parse_ack(buffer.get(..read).unwrap_or(&[]))
        }))
    }

    /// Send one mouse event at normalized `(x, y)`.
    ///
    /// # Errors
    /// When the send fails.
    pub fn send(&mut self, motion: Motion, x: f64, y: f64, clicks: u8) -> io::Result<()> {
        self.tag = self.tag.wrapping_add(1);
        let mut datagram = vec![CH_INPUT];
        datagram.extend_from_slice(&button_body(motion, self.tag, x, y, clicks));
        self.media.send(&datagram)?;
        Ok(())
    }

    /// Close both sockets by dropping them.
    pub fn close(self) {
        drop(self.media);
        drop(self.cursor);
    }
}

/// Where a step of a straight drag lands.
///
/// Written as `start + span * fraction` rather than a fused multiply-add on purpose: this is a
/// coordinate that crosses the wire, and `mul_add` rounds once where the two operations round
/// twice. `CLAUDE.md` bans the fusion tree-wide for exactly that reason.
#[must_use]
pub fn along(start: f64, end: f64, fraction: f64) -> f64 {
    let span = end - start;
    start + span * fraction
}

#[cfg(test)]
mod tests {
    use super::{Ack, Motion, along, button_body, hello_body, parse_ack};

    #[test]
    fn the_hello_is_the_shape_the_host_reads() {
        let body = hello_body(267, 656.0, 433.0);
        assert_eq!(body.len(), 1 + 2 + 4 + 8 + 8);
        assert_eq!(body.first(), Some(&0x01));
        assert_eq!(body.get(1..3), Some(&[0, 1][..]), "version, big-endian");
        assert_eq!(body.get(3..7), Some(&267_u32.to_be_bytes()[..]));
    }

    #[test]
    fn a_button_event_carries_its_tag_and_normalized_point() {
        let body = button_body(Motion::Drag, 0x0102_0304, 0.25, 0.5, 1);
        assert_eq!(body.first(), Some(&7), "drag is type 7");
        assert_eq!(body.get(1..5), Some(&[1, 2, 3, 4][..]));
        assert_eq!(body.get(5..8), Some(&[0, 1, 0][..]), "left, one click, no mods");
        assert_eq!(body.get(8..16), Some(&0.25_f64.to_be_bytes()[..]));
        assert_eq!(body.get(16..24), Some(&0.5_f64.to_be_bytes()[..]));
    }

    #[test]
    fn an_ack_round_trips() {
        let mut datagram = vec![0x00, 0x02, 1];
        datagram.extend_from_slice(&7_u32.to_be_bytes());
        datagram.extend_from_slice(&1312_u16.to_be_bytes());
        datagram.extend_from_slice(&866_u16.to_be_bytes());
        for value in [10.0_f64, 20.0, 656.0, 433.0] {
            datagram.extend_from_slice(&value.to_be_bytes());
        }
        let ack = parse_ack(&datagram);
        assert!(ack.accepted());
        assert_eq!(ack, Ack::Accepted {
            accepted: 1,
            stream_id: 7,
            capture_width: 1312,
            capture_height: 866,
            bounds: [10.0, 20.0, 656.0, 433.0],
        });
    }

    #[test]
    fn a_datagram_that_is_not_an_ack_says_which_kind_it_is() {
        assert_eq!(parse_ack(&[0x04, 0x02]), Ack::OtherChannel(0x04));
        assert_eq!(parse_ack(&[0x00, 0x09]), Ack::NotAck(0x09));
        assert_eq!(parse_ack(&[0x00]), Ack::Truncated(1));
        assert_eq!(parse_ack(&[]), Ack::Truncated(0));
        // A control ack cut short is truncated, not a half-read set of bounds.
        assert_eq!(parse_ack(&[0x00, 0x02, 1, 0, 0]), Ack::Truncated(5));
        assert!(!parse_ack(&[0x00, 0x02, 0]).accepted());
    }

    #[test]
    fn a_drag_reaches_both_ends() {
        assert!((along(0.05, 0.75, 0.0) - 0.05).abs() < f64::EPSILON);
        assert!((along(0.05, 0.75, 1.0) - 0.75).abs() < f64::EPSILON);
    }
}
