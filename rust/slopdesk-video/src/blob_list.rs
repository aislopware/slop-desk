//! A list of byte blobs, any of which may be ABSENT, flattened into one buffer.
//!
//! This is the shape the FEC boundary carries. The codec's arguments are not scalars — they are a
//! frame's fragments, `[Data]` on one side and `&[&[u8]]` on the other, with `nil`/`None` meaning
//! "this datagram was lost". The `(ptr, len)` in / `(out, cap)` out convention that
//! `slopdesk-ffi`'s header describes takes exactly one input span per argument, so the list has to
//! become a span before it can cross.
//!
//! ## Why the format lives here and not in `slopdesk-ffi`
//! Because it is a decision — how a length is written, what an absence looks like, what a lie
//! about a count does — and `slopdesk-ffi` is not allowed to make one. Here it is ordinary safe
//! code under `forbid(unsafe_code)` with its own tests; there it would be parsing inside the crate
//! that is only supposed to marshal.
//!
//! ## The format
//! ```text
//! u32 count | for each: u32 len | len bytes
//! ```
//! Big-endian like everything else on this path. `len == ABSENT` (`u32::MAX`) is a lost fragment
//! and carries no bytes — distinct from `len == 0`, which is a fragment that is present and empty.
//! A frame's fragments really can be empty (a zero-length tail), so conflating the two would repair
//! a datagram that was never lost.
//!
//! A count or a length that overruns the buffer is a refusal, not a truncation: [`decode`] returns
//! `None` and the caller drops the whole call. These bytes are assembled by the caller on the same
//! machine rather than read off a socket, so a malformed list is a bug in the marshalling and there
//! is nothing to salvage from it.

use crate::bytes::{ByteReader, ByteWriter};

/// The length that means "this blob is absent" — a fragment lost in flight.
///
/// `u32::MAX` rather than a separate presence byte because it is unrepresentable as a real length:
/// a fragment 4 GiB long cannot exist on a path whose datagrams are bounded by the MTU.
pub const ABSENT: u32 = u32::MAX;

/// Flattens a list of optional blobs into one buffer.
#[must_use]
pub fn encode(blobs: &[Option<&[u8]>]) -> Vec<u8> {
    let body: usize = blobs.iter().map(|b| 4 + b.map_or(0, <[u8]>::len)).sum();
    let mut out = ByteWriter::with_capacity(4 + body);
    out.put_u32(u32::try_from(blobs.len()).unwrap_or(0));
    for blob in blobs {
        match *blob {
            // A blob too long to describe is written as absent rather than truncated: the FEC
            // treats an absence as a hole it may repair, and a truncation as bytes it must trust.
            Some(bytes) => {
                match u32::try_from(bytes.len()) {
                    Ok(len) if len != ABSENT => {
                        out.put_u32(len);
                        out.put_bytes(bytes);
                    },
                    _ => out.put_u32(ABSENT),
                }
            },
            None => out.put_u32(ABSENT),
        }
    }
    out.into_vec()
}

/// Flattens a list of blobs that are all present — the encode side, where nothing was lost.
#[must_use]
pub fn encode_all(blobs: &[Vec<u8>]) -> Vec<u8> {
    let borrowed: Vec<Option<&[u8]>> = blobs.iter().map(|b| Some(b.as_slice())).collect();
    encode(&borrowed)
}

/// Reads a list back, BORROWING into `bytes` rather than copying.
///
/// Returns `None` if the count or any length overruns the buffer, or if trailing bytes are left
/// over — a list that does not describe itself exactly is not a list this side will guess at.
#[must_use]
pub fn decode(bytes: &[u8]) -> Option<Vec<Option<&[u8]>>> {
    let mut reader = ByteReader::new(bytes);
    let count = reader.read_u32().ok()? as usize;
    // A blob costs at least its own `u32` length, so a list claiming more blobs than the remaining
    // buffer could describe even if every one were empty is refused before a single allocation.
    // The division is exact by intent: four bytes is a blob's floor, so the quotient IS the
    // ceiling on how many more blobs the buffer could still describe.
    #[expect(clippy::integer_division, reason = "the floor is the bound being computed")]
    let ceiling = reader.bytes_remaining() / 4;
    if count > ceiling {
        return None;
    }
    let mut blobs = Vec::with_capacity(count);
    for _ in 0..count {
        let len = reader.read_u32().ok()?;
        if len == ABSENT {
            blobs.push(None);
        } else {
            blobs.push(Some(reader.read_bytes(len as usize).ok()?));
        }
    }
    (reader.bytes_remaining() == 0).then_some(blobs)
}

#[cfg(test)]
// Every fixture is a literal built in the same function, so `expect` IS the assertion.
#[expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
mod tests {
    use super::{ABSENT, decode, encode, encode_all};

    #[test]
    fn a_present_empty_blob_is_not_a_lost_one() {
        let list = [Some(&b""[..]), None, Some(&b"xy"[..])];
        let bytes = encode(&list);
        let decoded = decode(&bytes).expect("round trip");
        assert_eq!(decoded, vec![Some(&b""[..]), None, Some(&b"xy"[..])]);
    }

    #[test]
    fn an_empty_list_round_trips_as_an_empty_list() {
        let bytes = encode(&[]);
        assert_eq!(decode(&bytes), Some(vec![]));
    }

    #[test]
    fn encode_all_marks_every_blob_present() {
        let blobs = vec![vec![1_u8, 2], vec![], vec![3]];
        let bytes = encode_all(&blobs);
        let decoded = decode(&bytes).expect("round trip");
        assert_eq!(decoded, vec![
            Some(&[1_u8, 2][..]),
            Some(&[][..]),
            Some(&[3_u8][..])
        ]);
    }

    #[test]
    fn a_length_that_overruns_the_buffer_is_refused() {
        let mut bytes = encode(&[Some(&b"abc"[..])]);
        // Say the blob is three bytes longer than it is: the low byte of its length sits just
        // before the body, and the body is the last three bytes.
        if let Some(low) = bytes.len().checked_sub(4).and_then(|i| bytes.get_mut(i)) {
            *low = 6;
        }
        assert_eq!(decode(&bytes), None);
    }

    #[test]
    fn a_count_larger_than_the_buffer_could_hold_is_refused_before_allocating() {
        // Four bytes of count claiming a billion blobs, and nothing after it.
        let bytes = [0xFF_u8, 0xFF, 0xFF, 0xFE];
        assert_eq!(decode(&bytes), None);
    }

    #[test]
    fn trailing_bytes_make_the_whole_list_a_refusal() {
        let mut bytes = encode(&[Some(&b"ab"[..])]);
        bytes.push(0);
        assert_eq!(decode(&bytes), None);
    }

    #[test]
    fn a_truncated_header_is_refused_rather_than_read_as_empty() {
        assert_eq!(decode(&[0_u8, 0, 1]), None);
    }

    #[test]
    fn absent_is_not_a_length_any_real_fragment_could_claim() {
        // The MTU bounds a fragment at ~1500 bytes; the sentinel is 4 GiB - 1. The test is here so
        // that a future format change which makes ABSENT representable fails loudly.
        assert_eq!(ABSENT, u32::MAX);
    }
}
