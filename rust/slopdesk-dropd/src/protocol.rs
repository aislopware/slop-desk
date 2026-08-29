//! The PATH-4 wire — dropd's END of it.
//!
//! Frame shape is the house style: `[u32 BE payload length][u8 type][body]`. Multi-byte integers
//! are big-endian, strings are `[u16 BE byte length][UTF-8]`, and there is no JSON anywhere.
//!
//! Version 1 only, no negotiation: the client opens with `hello`, dropd answers `helloAck`, and a
//! mismatch is refused outright rather than renegotiated.
//!
//! dropd DECODES the client→host types (1–5) and ENCODES the host→client types (6–9). The mirror
//! image of this file is [`client`](crate::client), which encodes 1–5 and decodes 6–9. It was a
//! Swift module a whole package away until this port; both ends now sit in one crate, which is what
//! lets a test walk every frame type through both instead of the two agreeing by review.

use std::fmt;

/// The only supported version.
pub const VERSION: u8 = 1;

/// Body-payload cap per frame, matching the other paths' 16 MiB ceiling. A length prefix over this
/// is refused before any allocation — never trust an attacker-chosen size.
pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;

/// Hard ceiling on a single offered file (20 GiB). A guard against a hostile or fat-fingered size,
/// not a limit anyone reaches.
pub const MAX_TRANSFER_BYTES: u64 = 20 * 1024 * 1024 * 1024;

/// A client→host frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// Version pin, the first frame a client sends.
    Hello {
        /// Must equal [`VERSION`].
        version: u8,
    },
    /// Announces a file: a client-scoped id, the total size, and the display name — UNTRUSTED, and
    /// sanitised by [`crate::sanitize`] before it touches the filesystem.
    Offer {
        /// Client-scoped transfer id.
        transfer_id: u32,
        /// The body length the client promises to send.
        file_size: u64,
        /// The name as the client spelled it.
        name: String,
    },
    /// A body chunk. TCP already orders bytes; there is no per-chunk sequence number.
    Chunk {
        /// Which transfer these bytes belong to.
        transfer_id: u32,
        /// The raw body bytes (possibly empty).
        data: Vec<u8>,
    },
    /// The client has sent the whole body.
    Finish {
        /// Which transfer is complete.
        transfer_id: u32,
    },
    /// The client abandons the transfer (a read error on its side, say).
    Cancel {
        /// Which transfer to discard.
        transfer_id: u32,
    },
    /// A host→client type (6–9) that arrived on the host's side of the wire.
    ///
    /// Decoded strictly and then ignored, which is what the Swift server it replaces did. A client
    /// spelling one of these is confused rather than hostile, and hanging up on it would turn a
    /// harmless stray frame into a lost upload.
    HostBound,
}

/// A host→client frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    /// Answer to `hello`; `accepted == false` on a version mismatch (the client then closes).
    HelloAck {
        /// Whether the version is the one this build speaks.
        accepted: bool,
    },
    /// A destination is open and dropd is ready for chunks.
    Accept {
        /// Which transfer was accepted.
        transfer_id: u32,
    },
    /// The whole body was written and the file moved into place.
    Complete {
        /// Which transfer finished.
        transfer_id: u32,
    },
    /// The transfer failed. `reason` is a short human string for a toast — never a path.
    Failed {
        /// Which transfer failed.
        transfer_id: u32,
        /// Why, in words a toast can show.
        reason: String,
    },
}

/// Why a frame could not be decoded. Every one of these ends the connection: a stream whose frame
/// boundaries are in doubt cannot be resynchronised onto attacker bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
    /// A frame with no type byte at all.
    Empty,
    /// A type byte outside 1–9.
    UnknownType(u8),
    /// The body ended in the middle of a field.
    Truncated,
    /// A string field that is not UTF-8.
    BadUtf8,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Empty => formatter.write_str("empty payload"),
            Self::UnknownType(byte) => write!(formatter, "unknown frame type {byte}"),
            Self::Truncated => formatter.write_str("truncated payload"),
            Self::BadUtf8 => formatter.write_str("invalid utf-8 in a string field"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// Decodes one payload (`[u8 type][body]`) into a [`Request`].
///
/// # Errors
/// [`DecodeError`] on an empty, truncated, unknown-type or non-UTF-8 payload.
pub fn decode_request(payload: &[u8]) -> Result<Request, DecodeError> {
    let mut reader = Reader::new(payload);
    let kind = reader.u8()?;
    match kind {
        1 => {
            Ok(Request::Hello {
                version: reader.u8()?,
            })
        },
        2 => {
            let transfer_id = reader.u32()?;
            let file_size = reader.u64()?;
            let name = reader.string()?;
            Ok(Request::Offer {
                transfer_id,
                file_size,
                name,
            })
        },
        3 => {
            let transfer_id = reader.u32()?;
            // Whatever is left is the raw body chunk; an empty one is a legal flush.
            Ok(Request::Chunk {
                transfer_id,
                data: reader.rest().to_vec(),
            })
        },
        4 => {
            Ok(Request::Finish {
                transfer_id: reader.u32()?,
            })
        },
        5 => {
            Ok(Request::Cancel {
                transfer_id: reader.u32()?,
            })
        },
        // Decoded strictly, then discarded: a truncated one of these is still a broken stream.
        6 => {
            reader.u8()?;
            Ok(Request::HostBound)
        },
        7 | 8 => {
            reader.u32()?;
            Ok(Request::HostBound)
        },
        9 => {
            reader.u32()?;
            reader.string()?;
            Ok(Request::HostBound)
        },
        other => Err(DecodeError::UnknownType(other)),
    }
}

/// The full framed bytes for `reply`: `[u32 BE payload length][u8 type][body]`.
#[must_use]
pub fn encode_reply_frame(reply: &Reply) -> Vec<u8> {
    let payload = encode_reply_payload(reply);
    let mut frame = Vec::with_capacity(4 + payload.len());
    // A reply payload is a handful of bytes plus a short reason, so the cast cannot lose anything.
    frame.extend_from_slice(&u32::try_from(payload.len()).unwrap_or(u32::MAX).to_be_bytes());
    frame.extend_from_slice(&payload);
    frame
}

/// The payload only (`[u8 type][body]`), for callers that frame separately.
#[must_use]
pub fn encode_reply_payload(reply: &Reply) -> Vec<u8> {
    let mut out = Vec::new();
    match *reply {
        Reply::HelloAck { accepted } => {
            out.push(6);
            out.push(u8::from(accepted));
        },
        Reply::Accept { transfer_id } => {
            out.push(7);
            out.extend_from_slice(&transfer_id.to_be_bytes());
        },
        Reply::Complete { transfer_id } => {
            out.push(8);
            out.extend_from_slice(&transfer_id.to_be_bytes());
        },
        Reply::Failed {
            transfer_id,
            ref reason,
        } => {
            out.push(9);
            out.extend_from_slice(&transfer_id.to_be_bytes());
            push_string(&mut out, reason);
        },
    }
    out
}

/// `[u16 BE byte length][UTF-8]`, truncated to the prefix's capacity. A reason is short by
/// construction and a filename never approaches 64 KiB, so this bound is a formality — but it is
/// the formality that keeps the length prefix honest.
pub(crate) fn push_string(out: &mut Vec<u8>, text: &str) {
    let bytes = text.as_bytes();
    let length = u16::try_from(bytes.len()).unwrap_or(u16::MAX);
    out.extend_from_slice(&length.to_be_bytes());
    // `get` rather than a slice: the truncation above can only shorten, so the fallback is dead —
    // but a panic on the encode path of a service is not a thing worth leaving to an invariant.
    out.extend_from_slice(bytes.get(..usize::from(length)).unwrap_or(bytes));
}

/// A forward-only cursor that length-checks every read — the validate-then-drop contract for
/// untrusted bytes, in the one place where all of them arrive.
pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    pub(crate) const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.offset.checked_add(count).ok_or(DecodeError::Truncated)?;
        let slice = self.bytes.get(self.offset..end).ok_or(DecodeError::Truncated)?;
        self.offset = end;
        Ok(slice)
    }

    pub(crate) fn u8(&mut self) -> Result<u8, DecodeError> {
        // An empty payload is its own error: it means a frame with no type byte, not a short field.
        if self.bytes.is_empty() {
            return Err(DecodeError::Empty);
        }
        self.take(1)?.first().copied().ok_or(DecodeError::Truncated)
    }

    pub(crate) fn u32(&mut self) -> Result<u32, DecodeError> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_ignored| DecodeError::Truncated)?;
        Ok(u32::from_be_bytes(bytes))
    }

    fn u64(&mut self) -> Result<u64, DecodeError> {
        let bytes: [u8; 8] = self
            .take(8)?
            .try_into()
            .map_err(|_ignored| DecodeError::Truncated)?;
        Ok(u64::from_be_bytes(bytes))
    }

    pub(crate) fn string(&mut self) -> Result<String, DecodeError> {
        let bytes: [u8; 2] = self
            .take(2)?
            .try_into()
            .map_err(|_ignored| DecodeError::Truncated)?;
        let length = usize::from(u16::from_be_bytes(bytes));
        let slice = self.take(length)?;
        std::str::from_utf8(slice)
            .map(str::to_owned)
            .map_err(|_ignored| DecodeError::BadUtf8)
    }

    fn rest(&mut self) -> &'a [u8] {
        let slice = self.bytes.get(self.offset..).unwrap_or(&[]);
        self.offset = self.bytes.len();
        slice
    }
}

#[cfg(test)]
mod tests {
    use super::{DecodeError, MAX_TRANSFER_BYTES, Reply, Request, decode_request, encode_reply_frame};

    #[test]
    fn an_offer_round_trips_from_the_swift_clients_bytes() {
        // Hand-assembled exactly as `FileTransferCodec.encodePayload` writes it.
        let mut payload = vec![2u8];
        payload.extend_from_slice(&7u32.to_be_bytes());
        payload.extend_from_slice(&1234u64.to_be_bytes());
        payload.extend_from_slice(&3u16.to_be_bytes());
        payload.extend_from_slice(b"a.c");
        assert_eq!(
            decode_request(&payload),
            Ok(Request::Offer {
                transfer_id: 7,
                file_size: 1234,
                name: "a.c".to_owned(),
            })
        );
    }

    #[test]
    fn a_chunk_carries_the_whole_tail_including_an_empty_one() {
        let mut payload = vec![3u8];
        payload.extend_from_slice(&1u32.to_be_bytes());
        assert_eq!(
            decode_request(&payload),
            Ok(Request::Chunk {
                transfer_id: 1,
                data: Vec::new(),
            })
        );
        payload.extend_from_slice(b"body");
        assert_eq!(
            decode_request(&payload),
            Ok(Request::Chunk {
                transfer_id: 1,
                data: b"body".to_vec(),
            })
        );
    }

    #[test]
    fn every_truncation_is_an_error_rather_than_a_panic() {
        let mut payload = vec![2u8];
        payload.extend_from_slice(&7u32.to_be_bytes());
        payload.extend_from_slice(&MAX_TRANSFER_BYTES.to_be_bytes());
        payload.extend_from_slice(&9u16.to_be_bytes()); // claims 9 bytes of name
        payload.extend_from_slice(b"short");
        assert_eq!(decode_request(&payload), Err(DecodeError::Truncated));
        for cut in 1..payload.len() {
            let head = payload.get(..cut).unwrap_or_default();
            // The only requirement is that it ANSWERS: any prefix is either a shorter valid frame
            // or an error, and never a panic.
            let _ignored = decode_request(head);
        }
    }

    #[test]
    fn an_empty_payload_and_an_unknown_type_are_distinct_errors() {
        assert_eq!(decode_request(&[]), Err(DecodeError::Empty));
        assert_eq!(decode_request(&[42]), Err(DecodeError::UnknownType(42)));
    }

    #[test]
    fn a_name_that_is_not_utf8_is_refused() {
        let mut payload = vec![2u8];
        payload.extend_from_slice(&1u32.to_be_bytes());
        payload.extend_from_slice(&1u64.to_be_bytes());
        payload.extend_from_slice(&2u16.to_be_bytes());
        payload.extend_from_slice(&[0xFF, 0xFE]);
        assert_eq!(decode_request(&payload), Err(DecodeError::BadUtf8));
    }

    #[test]
    fn a_host_bound_type_is_decoded_and_ignored_rather_than_hung_up_on() {
        let mut payload = vec![9u8];
        payload.extend_from_slice(&3u32.to_be_bytes());
        payload.extend_from_slice(&2u16.to_be_bytes());
        payload.extend_from_slice(b"no");
        assert_eq!(decode_request(&payload), Ok(Request::HostBound));
    }

    #[test]
    fn a_reply_frame_is_length_prefixed_and_big_endian() {
        let frame = encode_reply_frame(&Reply::Accept {
            transfer_id: 0x0102_0304,
        });
        assert_eq!(frame, vec![0, 0, 0, 5, 7, 1, 2, 3, 4]);
    }

    #[test]
    fn a_failure_reason_rides_as_a_length_prefixed_string() {
        let frame = encode_reply_frame(&Reply::Failed {
            transfer_id: 1,
            reason: "write failed".to_owned(),
        });
        assert_eq!(frame.len(), 4 + 1 + 4 + 2 + "write failed".len());
        assert_eq!(frame.get(4), Some(&9u8));
    }
}
