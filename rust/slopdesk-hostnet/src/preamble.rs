//! The shared-mux association preamble — the raw bytes that pair two sockets into one connection.
//!
//! ```text
//! MUX CONTROL:  [ 0x03 ][ 16 raw connectionID bytes ]   (17 bytes)
//! MUX DATA:     [ 0x04 ][ 16 raw connectionID bytes ]   (17 bytes)
//! ```
//!
//! `docs/20-wire-protocol.md` §8. This is NOT a mux frame — it is peeled off before the decoder
//! ever sees a byte, which is why it lives here and not in `slopdesk-wire`.
//!
//! The 16 is [`slopdesk_wire::SESSION_ID_BYTE_COUNT`], asked for rather than typed. The preamble
//! this module frames and the `hello` body the wire crate decodes are the SAME field, and a
//! preamble framed at a width no message uses is a desynchronised socket rather than a wrong value.
//! `ChannelAssociation.swift` already refused to transcribe it; that refusal is carried across.

use slopdesk_wire::SESSION_ID_BYTE_COUNT;

/// Which of a connection's two sockets this one is.
///
/// A data/control split: a burst of PTY output on DATA cannot delay a `resize`/`ack`/`bye` on
/// CONTROL, for every pane rather than one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lane {
    /// Small frames, never flow-controlled.
    Control,
    /// Bulk `channelData`, flow-controlled per channel.
    Data,
}

impl Lane {
    /// Discriminator byte for a shared-mux CONTROL connection.
    pub const CONTROL_TAG: u8 = 0x03;
    /// Discriminator byte for a shared-mux DATA connection.
    pub const DATA_TAG: u8 = 0x04;

    /// The lane a preamble's first byte names, or `None` for any other byte.
    ///
    /// Returning `None` rather than defaulting is the point: a socket that opens with a byte this
    /// host does not know is a peer speaking a protocol this one does not, and guessing a lane for
    /// it parks a half-pair that can never complete.
    #[must_use]
    pub const fn from_tag(tag: u8) -> Option<Self> {
        match tag {
            Self::CONTROL_TAG => Some(Self::Control),
            Self::DATA_TAG => Some(Self::Data),
            _ => None,
        }
    }

    /// This lane's discriminator byte.
    #[must_use]
    pub const fn tag(self) -> u8 {
        match self {
            Self::Control => Self::CONTROL_TAG,
            Self::Data => Self::DATA_TAG,
        }
    }
}

/// The stable identity that pairs one client's CONTROL and DATA sockets.
///
/// Sixteen opaque bytes — the host never parses them, it only compares them. It is a `UUID` on the
/// Swift side and stays one on the wire; representing it as an integer here would invite a byte
/// order this protocol never specified.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ConnectionId([u8; SESSION_ID_BYTE_COUNT]);

impl ConnectionId {
    /// Wraps 16 raw wire bytes.
    #[must_use]
    pub const fn from_bytes(bytes: [u8; SESSION_ID_BYTE_COUNT]) -> Self {
        Self(bytes)
    }

    /// The 16 raw bytes, in the order they arrived.
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; SESSION_ID_BYTE_COUNT] {
        &self.0
    }
}

/// One socket's opening bytes, decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Preamble {
    /// Which lane this socket is.
    pub lane: Lane,
    /// The identity it wants to be paired on.
    pub connection: ConnectionId,
}

/// The preamble's length on the wire: one tag byte plus the connection id.
pub const PREAMBLE_BYTE_COUNT: usize = 1 + SESSION_ID_BYTE_COUNT;

/// Why a preamble was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreambleError {
    /// Fewer than [`PREAMBLE_BYTE_COUNT`] bytes were offered.
    ///
    /// Carries what was offered, because the caller reading a socket needs to know whether to read
    /// more or to give up — a short read is normal, a short CLOSE is not.
    TooShort {
        /// How many bytes the caller had.
        ///
        /// A `u8` because a short preamble is by definition shorter than 17 bytes, so the type
        /// cannot represent a value this variant could not have. It also keeps the enum one word
        /// wide, which `variant_size_differences` is on to enforce and which matters here for the
        /// ordinary reason: this is the return type of a function on the accept path.
        got: u8,
    },
    /// The first byte named no lane this host serves.
    UnknownTag {
        /// The byte that named nothing.
        tag: u8,
    },
}

/// Decodes exactly [`PREAMBLE_BYTE_COUNT`] bytes off the front of a freshly-accepted socket.
///
/// Trailing bytes are IGNORED rather than refused: the preamble is a prefix of a byte stream, and
/// whatever follows it is the first mux frame. The caller keeps the remainder and feeds it to the
/// decoder.
///
/// # Errors
/// [`PreambleError::TooShort`] if fewer than 17 bytes are available, [`PreambleError::UnknownTag`]
/// if the first byte is neither `0x03` nor `0x04`.
pub fn decode(bytes: &[u8]) -> Result<Preamble, PreambleError> {
    let Some((&tag, rest)) = bytes.split_first() else {
        return Err(PreambleError::TooShort { got: 0 });
    };
    let Some(id) = rest.get(..SESSION_ID_BYTE_COUNT) else {
        // Unreachable above 16 by the `get` that failed; saturating rather than unwrapping so the
        // error path of a parser stays a parser and never a panic.
        return Err(PreambleError::TooShort {
            got: u8::try_from(bytes.len()).unwrap_or(u8::MAX),
        });
    };
    // The tag is checked AFTER the length so a truncated read of a valid preamble reports the
    // truncation rather than a tag it never finished sending.
    let Some(lane) = Lane::from_tag(tag) else {
        return Err(PreambleError::UnknownTag { tag });
    };
    let mut connection = [0_u8; SESSION_ID_BYTE_COUNT];
    connection.copy_from_slice(id);
    Ok(Preamble {
        lane,
        connection: ConnectionId(connection),
    })
}

/// Encodes a preamble — the client's side of the handshake, and every test's fixture.
#[must_use]
pub fn encode(preamble: Preamble) -> [u8; PREAMBLE_BYTE_COUNT] {
    let mut out = [0_u8; PREAMBLE_BYTE_COUNT];
    out[0] = preamble.lane.tag();
    out[1..].copy_from_slice(preamble.connection.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{ConnectionId, Lane, PREAMBLE_BYTE_COUNT, Preamble, PreambleError, decode, encode};

    const ID: ConnectionId = ConnectionId::from_bytes([
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    ]);

    #[test]
    fn the_preamble_is_seventeen_bytes_and_round_trips_on_both_lanes() {
        for lane in [Lane::Control, Lane::Data] {
            let bytes = encode(Preamble { lane, connection: ID });
            assert_eq!(bytes.len(), PREAMBLE_BYTE_COUNT);
            assert_eq!(bytes.len(), 17);
            assert_eq!(decode(&bytes), Ok(Preamble { lane, connection: ID }));
        }
    }

    /// The tags are `0x03`/`0x04` on the wire, not whatever an enum discriminant happens to be.
    #[test]
    fn the_tags_are_the_bytes_the_swift_client_writes() {
        assert_eq!(Lane::Control.tag(), 0x03);
        assert_eq!(Lane::Data.tag(), 0x04);
        assert_eq!(
            encode(Preamble {
                lane: Lane::Control,
                connection: ID
            })[0],
            0x03
        );
        assert_eq!(
            encode(Preamble {
                lane: Lane::Data,
                connection: ID
            })[0],
            0x04
        );
    }

    /// A frame follows the preamble on the same stream; refusing the extra bytes would refuse
    /// every real connection.
    #[test]
    fn trailing_bytes_belong_to_the_decoder_not_to_this_module() {
        let mut stream = encode(Preamble {
            lane: Lane::Data,
            connection: ID,
        })
        .to_vec();
        stream.extend_from_slice(b"the first mux frame");
        assert_eq!(
            decode(&stream),
            Ok(Preamble {
                lane: Lane::Data,
                connection: ID
            })
        );
    }

    /// A truncated read of a VALID preamble must report the truncation, not a tag verdict — the
    /// caller's next move is "read more", and an `UnknownTag` would send it to "hang up".
    #[test]
    fn a_short_read_reports_its_length_before_it_judges_the_tag() {
        let full = encode(Preamble {
            lane: Lane::Control,
            connection: ID,
        });
        // 17 as a `u8` literal, pinned to the constant by the round-trip test above: the loop
        // variable IS the value the error must carry, and that field is a `u8`.
        for got in 0_u8..17 {
            let short = full
                .get(..usize::from(got))
                .expect("a prefix of a 17-byte preamble");
            assert_eq!(
                decode(short),
                Err(PreambleError::TooShort { got }),
                "at {got} bytes"
            );
        }
    }

    #[test]
    fn an_unknown_first_byte_names_no_lane() {
        assert_eq!(Lane::from_tag(0x00), None);
        assert_eq!(Lane::from_tag(0x02), None);
        assert_eq!(Lane::from_tag(0x05), None);
        let mut hostile = encode(Preamble {
            lane: Lane::Data,
            connection: ID,
        });
        hostile[0] = 0x05;
        assert_eq!(decode(&hostile), Err(PreambleError::UnknownTag { tag: 0x05 }));
    }
}
