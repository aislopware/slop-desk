//! Big-endian read/write helpers.
//!
//! Every multi-byte integer on this wire is big-endian ("network byte order"). Assembly is
//! byte-by-byte through `to_be_bytes` and slice arithmetic — alignment-safe, endian-explicit, no
//! `unsafe`, no dependency.
//!
//! Resurrected from the retired core's `bytes.rs`, trimmed to what the terminal wire actually uses
//! (the float and video-only helpers are gone) and with one addition the Swift side grew after the
//! retirement: [`clamp_u16_field`], below.
//!
//! ## Strict UTF-8, and why the resurrected code could not simply be kept
//! Every string field on THIS path is strict: an invalid sequence is [`WireError::MalformedBody`],
//! never a replacement-character repair (`WireMessage+Decode.swift:110`). The recovered helpers
//! were the VIDEO path's, where a lossy decode is right because a datagram must not be able to fail
//! a session; copying them over unchanged would have silently relaxed the terminal contract and let
//! a corrupt title through as `U+FFFD`. The lossy readers are gone; the strict ones take a `field`
//! label used only to build the diagnostic hint (hints are not part of the wire format).
//!
//! ## One deliberate refinement over the Swift
//! [`ByteReader::read_bytes`] and [`ByteReader::remaining`] hand back BORROWS into the input where
//! Swift's `BigEndianReader` copies into a fresh `Data`. Same bytes, no copy; a caller that needs
//! ownership says `.to_vec()`. On `.output` under a flood that is one avoided memcpy per frame.

/// The low 16 bits of an index, matching Swift's `UInt16(truncatingIfNeeded:)`.
///
/// Here rather than beside its two call sites because this is the crate's byte module and a
/// narrowing cast is a byte question — the same helper had fifteen homes across the tree before
/// each crate that writes a wire was given exactly one.
#[must_use]
pub const fn truncating_u16(value: usize) -> u16 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the mask is the truncation, stated in the name and matched to Swift's"
    )]
    {
        (value & 0xFFFF) as u16
    }
}

use crate::error::{Result, WireError};

/// Largest UTF-8 byte length a `u16`-length-prefixed string field can carry.
pub const MAX_LENGTH_PREFIXED_BYTES: usize = u16::MAX as usize;

/// The longest prefix of `value` whose UTF-8 fits a `u16` length field, cut at a `char` boundary.
///
/// Identity for anything sane — every producer of a length-prefixed field on this wire caps it far
/// below 64 KiB — so this only guards the pathological case. It has to exist, though: writing a
/// wrapped `u16` length while still appending every byte would make the DECODER mis-split the
/// frame, which for `notification` corrupts the body and for `projectGitStatus` shreds the fixed
/// trailer.
///
/// The `char` (Unicode scalar) boundary is load-bearing, not incidental. Swift's `clampedU16Field`
/// family cuts at the same boundary *specifically* to agree with this function — its own comment
/// says so, and names the parity test that guards it. Cutting at a grapheme cluster instead would
/// disagree byte-for-byte whenever a 65535-byte cut fell inside a multi-scalar grapheme.
#[must_use]
pub fn clamp_u16_field(value: &str) -> &str {
    clamp_utf8(value, MAX_LENGTH_PREFIXED_BYTES)
}

/// The longest prefix of `value` whose UTF-8 fits `max_bytes`, cut at a `char` boundary.
///
/// The general form of [`clamp_u16_field`], for the fields that cap far below 64 KiB — a workspace
/// intent's 512-byte name, a presence label. Same boundary rule for the same reason: the cut has to
/// land where Swift's `unicodeScalars.removeLast()` loop lands, or the two disagree byte-for-byte
/// on any value whose limit falls inside a multi-scalar grapheme.
///
/// Applied on ENCODE only. A decoder REJECTS an over-long declared length rather than trimming it:
/// silently shortening a field a peer over-declared hides a framing bug behind a plausible value.
#[must_use]
pub fn clamp_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value; // fits already — the only case that ever happens
    }
    let mut end = 0;
    for (index, ch) in value.char_indices() {
        let next = index + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    value.get(..end).unwrap_or(value)
}

/// Where a [`ByteWriter`] puts what it is handed.
#[derive(Debug)]
enum Sink<'a> {
    /// A buffer the writer grows itself — what every encoder that hands back a `Vec` uses.
    Owned(Vec<u8>),
    /// A buffer the CALLER owns, for the encoders that write straight into memory somebody else
    /// allocated: the FFI boundary sizes a frame, allocates once, and has the encoder fill it,
    /// rather than encoding into a `Vec` and copying that `Vec` across. `len` counts what the
    /// frame NEEDS, which keeps rising past the buffer's end — a write that does not fit is
    /// skipped, so the count is still the §4 answer when the caller under-sized.
    Borrowed { buf: &'a mut [u8], len: usize },
}

/// A big-endian encoder, over a buffer it grows or one it was lent.
#[derive(Debug)]
pub struct ByteWriter<'a> {
    sink: Sink<'a>,
}

impl Default for ByteWriter<'_> {
    fn default() -> Self {
        Self::new()
    }
}

impl<'a> ByteWriter<'a> {
    /// A new empty writer over a buffer it grows itself.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            sink: Sink::Owned(Vec::new()),
        }
    }

    /// A new writer over a buffer it grows itself, pre-sized for `capacity` bytes.
    #[must_use]
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            sink: Sink::Owned(Vec::with_capacity(capacity)),
        }
    }

    /// A new writer over a buffer the CALLER owns.
    ///
    /// Nothing is allocated and nothing grows: [`len`](Self::len) counts what was asked for, so a
    /// caller that lent too little still learns the size it should have lent.
    #[must_use]
    pub const fn borrowing(buf: &'a mut [u8]) -> Self {
        Self {
            sink: Sink::Borrowed { buf, len: 0 },
        }
    }

    /// Appends raw bytes verbatim — the one place either sink is actually written.
    fn put_slice(&mut self, bytes: &[u8]) {
        match self.sink {
            Sink::Owned(ref mut buf) => buf.extend_from_slice(bytes),
            Sink::Borrowed {
                ref mut buf,
                ref mut len,
            } => {
                let end = len.saturating_add(bytes.len());
                if let Some(slot) = buf.get_mut(*len..end) {
                    slot.copy_from_slice(bytes);
                }
                *len = end;
            },
        }
    }

    /// Appends one byte.
    pub fn put_u8(&mut self, value: u8) {
        self.put_slice(&[value]);
    }

    /// Appends a byte carrying a boolean, as `1` or `0`.
    pub fn put_bool(&mut self, value: bool) {
        self.put_slice(&[u8::from(value)]);
    }

    /// Appends a big-endian `u16`.
    pub fn put_u16(&mut self, value: u16) {
        self.put_slice(&value.to_be_bytes());
    }

    /// Appends a big-endian `u32`.
    pub fn put_u32(&mut self, value: u32) {
        self.put_slice(&value.to_be_bytes());
    }

    /// Appends a big-endian `u64`.
    pub fn put_u64(&mut self, value: u64) {
        self.put_slice(&value.to_be_bytes());
    }

    /// Appends a big-endian `i32` (two's-complement bit pattern, like Swift's
    /// `UInt32(bitPattern:)`).
    pub fn put_i32(&mut self, value: i32) {
        self.put_u32(value.cast_unsigned());
    }

    /// Appends a big-endian `i64` (two's-complement bit pattern).
    pub fn put_i64(&mut self, value: i64) {
        self.put_u64(value.cast_unsigned());
    }

    /// Appends raw bytes verbatim.
    pub fn put_bytes(&mut self, bytes: &[u8]) {
        self.put_slice(bytes);
    }

    /// Appends a `u16` byte-length prefix followed by the string's UTF-8, clamped by
    /// [`clamp_u16_field`] so the written length and the written bytes always agree.
    pub fn put_length_prefixed_str(&mut self, value: &str) {
        let bytes = clamp_u16_field(value).as_bytes();
        // The clamp guarantees this fits; `as` would be a silent wrap if it ever did not.
        self.put_u16(u16::try_from(bytes.len()).unwrap_or(u16::MAX));
        self.put_bytes(bytes);
    }

    /// Number of bytes written so far — or, over a lent buffer, the number ASKED for.
    #[must_use]
    pub const fn len(&self) -> usize {
        match self.sink {
            Sink::Owned(ref buf) => buf.len(),
            Sink::Borrowed { len, .. } => len,
        }
    }

    /// Whether nothing has been written yet.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Borrows the written bytes — over a lent buffer, only as far as the buffer actually reached.
    #[must_use]
    pub fn as_slice(&self) -> &[u8] {
        match self.sink {
            Sink::Owned(ref buf) => buf,
            Sink::Borrowed { ref buf, len } => buf.get(..len).unwrap_or(buf),
        }
    }

    /// Overwrites the four bytes at `offset` with `value` in big-endian order.
    ///
    /// Exists for exactly one caller: the frame encoder writes a placeholder length prefix, encodes
    /// the body into the same buffer, then back-patches the prefix — which is what keeps a 128 KiB
    /// `.output` payload from being copied twice under a flood. Out-of-range is a silent no-op
    /// rather than a panic; the only call site computes the offset itself.
    pub fn patch_u32(&mut self, offset: usize, value: u32) {
        let end = offset.saturating_add(4);
        let slot = match self.sink {
            Sink::Owned(ref mut buf) => buf.get_mut(offset..end),
            Sink::Borrowed { ref mut buf, .. } => buf.get_mut(offset..end),
        };
        if let Some(slot) = slot {
            slot.copy_from_slice(&value.to_be_bytes());
        }
    }

    /// Consumes the writer, returning the written bytes.
    ///
    /// Over a LENT buffer this copies what was written, because the bytes belong to the lender —
    /// which is why the FFI boundary reads [`len`](Self::len) instead and never calls this.
    #[must_use]
    pub fn into_vec(self) -> Vec<u8> {
        match self.sink {
            Sink::Owned(buf) => buf,
            Sink::Borrowed { buf, len } => buf.get(..len).unwrap_or(buf).to_vec(),
        }
    }
}

/// A forward-only big-endian reader over a byte slice.
///
/// Every read consumes from the current offset and returns [`WireError::Truncated`] when the buffer
/// is exhausted, so a hostile body can shorten a frame but never make the reader over-read.
#[derive(Debug, Clone)]
pub struct ByteReader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> ByteReader<'a> {
    /// Wraps a slice for reading.
    #[must_use]
    pub const fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    /// How far into the input the next read starts.
    ///
    /// Exists so a decoder can answer WHERE a field sits rather than what it says — the shape a
    /// caller that already holds the datagram needs, because a copy handed back to it would only be
    /// copied again.
    #[must_use]
    pub const fn position(&self) -> usize {
        self.offset
    }

    /// Bytes not yet consumed.
    #[must_use]
    pub const fn bytes_remaining(&self) -> usize {
        self.data.len() - self.offset
    }

    fn next_byte(&mut self) -> Result<u8> {
        let byte = *self.data.get(self.offset).ok_or(WireError::Truncated)?;
        self.offset += 1;
        Ok(byte)
    }

    /// Reads one byte.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when the buffer is exhausted.
    pub fn read_u8(&mut self) -> Result<u8> {
        self.next_byte()
    }

    /// Reads one byte as a boolean, `!= 0`.
    ///
    /// The untrusted-bool rule: a byte off the wire is not a `bool`, and any non-zero value means
    /// true rather than only `1`.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when the buffer is exhausted.
    pub fn read_bool(&mut self) -> Result<bool> {
        Ok(self.next_byte()? != 0)
    }

    /// Reads a big-endian `u16`.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than 2 bytes remain.
    pub fn read_u16(&mut self) -> Result<u16> {
        let b0 = u16::from(self.next_byte()?);
        let b1 = u16::from(self.next_byte()?);
        Ok((b0 << 8) | b1)
    }

    /// Reads a big-endian `u32`.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than 4 bytes remain.
    pub fn read_u32(&mut self) -> Result<u32> {
        let mut value: u32 = 0;
        for _ in 0..4 {
            value = (value << 8) | u32::from(self.next_byte()?);
        }
        Ok(value)
    }

    /// Reads a big-endian `u64`.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than 8 bytes remain.
    pub fn read_u64(&mut self) -> Result<u64> {
        let mut value: u64 = 0;
        for _ in 0..8 {
            value = (value << 8) | u64::from(self.next_byte()?);
        }
        Ok(value)
    }

    /// Reads a big-endian `i32` (two's-complement bit pattern).
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than 4 bytes remain.
    pub fn read_i32(&mut self) -> Result<i32> {
        Ok(self.read_u32()?.cast_signed())
    }

    /// Reads a big-endian `i64` (two's-complement bit pattern).
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than 8 bytes remain.
    pub fn read_i64(&mut self) -> Result<i64> {
        Ok(self.read_u64()?.cast_signed())
    }

    /// Reads exactly `count` raw bytes, borrowed from the input.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when fewer than `count` bytes remain.
    pub fn read_bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        let end = self.offset.checked_add(count).ok_or(WireError::Truncated)?;
        let slice = self.data.get(self.offset..end).ok_or(WireError::Truncated)?;
        self.offset = end;
        Ok(slice)
    }

    /// Consumes and returns everything left, borrowed from the input.
    pub fn remaining(&mut self) -> &'a [u8] {
        let slice = self.data.get(self.offset..).unwrap_or(&[]);
        self.offset = self.data.len();
        slice
    }

    /// Reads a `u16`-length-prefixed strict-UTF-8 string.
    ///
    /// A prefix longer than what remains is [`WireError::Truncated`] — the frame is dropped, never
    /// over-read — and the declared length is checked BEFORE any of it is read, so a hostile
    /// `0xFFFF` in front of two bytes costs nothing.
    ///
    /// # Errors
    /// [`WireError::Truncated`] when the declared length exceeds what remains, or
    /// [`WireError::MalformedBody`] when the bytes are not valid UTF-8.
    pub fn read_length_prefixed_str(&mut self, field: &str) -> Result<String> {
        let len = usize::from(self.read_u16()?);
        let bytes = self.read_bytes(len)?;
        utf8(bytes, field)
    }

    /// Decodes everything left as strict UTF-8 — the trailing-string shape (`title`, `cwd`,
    /// `projectKey`, `agentSessionIntent`, a `notification` body), where the remainder IS the value
    /// and so needs no length prefix to be unambiguous.
    ///
    /// # Errors
    /// [`WireError::MalformedBody`] when the remaining bytes are not valid UTF-8.
    pub fn remaining_str(&mut self, field: &str) -> Result<String> {
        utf8(self.remaining(), field)
    }
}

/// Strict UTF-8 decode, naming `field` in the fault so a log says which one was corrupt.
fn utf8(bytes: &[u8], field: &str) -> Result<String> {
    core::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| WireError::malformed(format!("{field}: invalid UTF-8")))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{ByteReader, ByteWriter, MAX_LENGTH_PREFIXED_BYTES, WireError, clamp_u16_field};

    #[test]
    fn every_integer_width_round_trips_big_endian() {
        let mut w = ByteWriter::new();
        w.put_u8(0xAB);
        w.put_u16(0x1234);
        w.put_u32(0xDEAD_BEEF);
        w.put_u64(0x0102_0304_0506_0708);
        w.put_i32(-2);
        w.put_i64(i64::MIN);
        let bytes = w.into_vec();

        let mut r = ByteReader::new(&bytes);
        assert_eq!(r.read_u8().unwrap(), 0xAB);
        assert_eq!(r.read_u16().unwrap(), 0x1234);
        assert_eq!(r.read_u32().unwrap(), 0xDEAD_BEEF);
        assert_eq!(r.read_u64().unwrap(), 0x0102_0304_0506_0708);
        assert_eq!(r.read_i32().unwrap(), -2);
        assert_eq!(r.read_i64().unwrap(), i64::MIN);
        assert_eq!(r.bytes_remaining(), 0);
    }

    #[test]
    fn the_byte_order_is_network_order_not_the_hosts() {
        // Spelled out rather than round-tripped: a reader and writer that were both little-endian
        // would pass the test above and produce a wire no other implementation could read.
        let mut w = ByteWriter::new();
        w.put_u32(1);
        assert_eq!(w.as_slice(), &[0, 0, 0, 1]);
    }

    #[test]
    fn a_signed_value_travels_as_its_twos_complement_bit_pattern() {
        let mut w = ByteWriter::new();
        w.put_i32(-1);
        assert_eq!(w.as_slice(), &[0xFF, 0xFF, 0xFF, 0xFF]);
    }

    #[test]
    fn reading_past_the_end_is_truncated_rather_than_a_panic() {
        let mut r = ByteReader::new(&[0, 1]);
        r.read_u32().expect_err("only two bytes are there");
        let mut r = ByteReader::new(&[1, 2, 3]);
        r.read_bytes(4).expect_err("only three bytes are there");
    }

    #[test]
    fn a_length_prefix_longer_than_the_body_is_refused_rather_than_over_read() {
        // The hostile shape: a 0xFFFF length in front of two bytes.
        let mut r = ByteReader::new(&[0xFF, 0xFF, b'h', b'i']);
        r.read_length_prefixed_str("title")
            .expect_err("the declared length is not there");
    }

    #[test]
    fn invalid_utf8_is_malformed_rather_than_repaired() {
        // The terminal path is STRICT — the resurrected video helper repaired this to U+FFFD.
        let mut w = ByteWriter::new();
        w.put_u16(2);
        w.put_bytes(&[0xFF, 0xFE]);
        let bytes = w.into_vec();
        let err = ByteReader::new(&bytes)
            .read_length_prefixed_str("title")
            .unwrap_err();
        assert_eq!(err, WireError::malformed("title: invalid UTF-8"));
    }

    #[test]
    fn a_trailing_string_round_trips_and_is_strict_too() {
        let mut r = ByteReader::new("hello ✅".as_bytes());
        assert_eq!(r.remaining_str("title").unwrap(), "hello ✅");
        ByteReader::new(&[0xC3, 0x28])
            .remaining_str("cwd")
            .expect_err("not valid UTF-8");
    }

    #[test]
    fn a_bool_byte_is_true_for_anything_non_zero() {
        let mut r = ByteReader::new(&[0, 1, 2, 255]);
        assert!(!r.read_bool().unwrap());
        assert!(r.read_bool().unwrap());
        assert!(r.read_bool().unwrap(), "2 is not 1, and is still true");
        assert!(r.read_bool().unwrap());
    }

    #[test]
    fn a_field_that_fits_the_length_prefix_is_returned_untouched() {
        assert_eq!(clamp_u16_field("hello"), "hello");
        assert_eq!(clamp_u16_field(""), "");
        let exact = "a".repeat(MAX_LENGTH_PREFIXED_BYTES);
        assert_eq!(clamp_u16_field(&exact).len(), MAX_LENGTH_PREFIXED_BYTES);
    }

    #[test]
    fn an_oversized_field_is_cut_at_a_char_boundary_and_stays_valid_utf8() {
        // 4-byte scalars, so the 65535-byte limit lands mid-scalar: 65535 = 4*16383 + 3.
        let huge = "😀".repeat(20000);
        let cut = clamp_u16_field(&huge);
        assert!(cut.len() <= MAX_LENGTH_PREFIXED_BYTES);
        assert_eq!(cut.len() % 4, 0, "cut on a scalar boundary, never inside one");
        assert!(cut.chars().all(|c| c == '😀'));
    }

    #[test]
    fn the_written_length_and_the_written_bytes_agree_even_when_clamped() {
        let huge = "😀".repeat(20000);
        let mut w = ByteWriter::new();
        w.put_length_prefixed_str(&huge);
        let bytes = w.into_vec();
        let prefix = bytes.get(..2).and_then(|b| <[u8; 2]>::try_from(b).ok()).unwrap();
        let declared = usize::from(u16::from_be_bytes(prefix));
        assert_eq!(
            declared,
            bytes.len() - 2,
            "a wrapped length would mis-split the next field"
        );
    }

    #[test]
    fn patching_the_length_prefix_rewrites_exactly_four_bytes() {
        let mut w = ByteWriter::new();
        w.put_bytes(&[0, 0, 0, 0, 0xAA]);
        w.patch_u32(0, 0x0102_0304);
        assert_eq!(w.as_slice(), &[1, 2, 3, 4, 0xAA]);
    }

    #[test]
    fn patching_out_of_range_changes_nothing_rather_than_panicking() {
        let mut w = ByteWriter::new();
        w.put_bytes(&[1, 2]);
        w.patch_u32(0, 0xFFFF_FFFF);
        assert_eq!(w.as_slice(), &[1, 2]);
    }
}
