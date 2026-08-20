//! Big-endian wire read/write helpers for the video path — the `Data.appendBE` family and
//! `VideoByteReader` from the deleted `SlopDeskVideoProtocol.VideoWireBytes`.
//!
//! Every multi-byte integer on the wire is big-endian ("network byte order"). Assembly goes through
//! `to_be_bytes` / `from_be_bytes` rather than a pointer cast, so the code is alignment-safe and
//! endian-explicit with no `unsafe`.
//!
//! ## Why this is not `slopdesk_wire::bytes`
//!
//! Because `VideoWireBytes.swift` is not `SlopDeskProtocol`'s reader either, and its header says
//! why: "local to `SlopDeskVideoProtocol` so this target stays a leaf with ZERO dependency". The
//! same argument survives the port — a PATH-2 crate that reached into the PATH-1 crate for a
//! `read_u32` would tie the video transport's build and error vocabulary to the terminal's for the
//! sake of forty lines of shifting. The two readers also do not agree: this one carries
//! [`ByteReader::read_finite_f64`], which the terminal path has no floats to need.
//!
//! One deliberate refinement over the Swift, inherited from the retired core: [`ByteReader`]'s
//! `read_bytes` and `remaining` return BORROWS into the input rather than a fresh buffer. Identical
//! in behaviour, zero-copy; a caller that needs ownership says `.to_vec()`.

use crate::error::{Result, VideoProtocolError};

/// The low bits of a count, at the width its wire field is declared in.
///
/// Every one of these had its own copy — eight across this crate, four more across `slopdesk-ffi` —
/// each with the same `#[expect]` and the same one-line reason. Truncation IS the behaviour: a
/// count that does not fit its field was already past what the format can say, and the callers
/// bound it before it gets here.
#[must_use]
pub const fn truncating_u8(value: usize) -> u8 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "every wire count truncates to its declared width"
    )]
    {
        value as u8
    }
}

/// The low 16 bits of a count — see [`truncating_u8`].
#[must_use]
pub const fn truncating_u16(value: usize) -> u16 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "every wire count truncates to its declared width"
    )]
    {
        value as u16
    }
}

/// The low 32 bits of a count — see [`truncating_u8`].
#[must_use]
pub const fn truncating_u32(value: usize) -> u32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "every wire count truncates to its declared width"
    )]
    {
        value as u32
    }
}

/// A growable big-endian wire encoder — the counterpart of Swift's `Data.appendBE(_:)` family.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ByteWriter {
    buf: Vec<u8>,
}

impl ByteWriter {
    /// A new empty writer.
    #[must_use]
    pub const fn new() -> Self {
        Self { buf: Vec::new() }
    }

    /// A new writer pre-sized for `capacity` bytes.
    #[must_use]
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            buf: Vec::with_capacity(capacity),
        }
    }

    /// Appends one byte.
    pub fn put_u8(&mut self, value: u8) {
        self.buf.push(value);
    }

    /// Appends a big-endian `u16`.
    pub fn put_u16(&mut self, value: u16) {
        self.buf.extend_from_slice(&value.to_be_bytes());
    }

    /// Appends a big-endian `u32`.
    pub fn put_u32(&mut self, value: u32) {
        self.buf.extend_from_slice(&value.to_be_bytes());
    }

    /// Appends a big-endian `u64`.
    pub fn put_u64(&mut self, value: u64) {
        self.buf.extend_from_slice(&value.to_be_bytes());
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

    /// Appends a big-endian IEEE-754 `f64` bit pattern.
    pub fn put_f64(&mut self, value: f64) {
        self.put_u64(value.to_bits());
    }

    /// Appends raw bytes verbatim.
    pub fn put_bytes(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// Number of bytes written so far.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.buf.len()
    }

    /// Whether nothing has been written yet.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Borrows the written bytes.
    #[must_use]
    pub fn as_slice(&self) -> &[u8] {
        &self.buf
    }

    /// Consumes the writer, returning the written bytes.
    #[must_use]
    pub fn into_vec(self) -> Vec<u8> {
        self.buf
    }
}

/// A forward-only big-endian reader over a byte slice.
///
/// Every read consumes from the current offset and answers [`VideoProtocolError::Truncated`] when
/// the buffer is exhausted — never a partial value, never a panic.
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

    /// Bytes not yet consumed.
    #[must_use]
    pub const fn bytes_remaining(&self) -> usize {
        self.data.len() - self.offset
    }

    /// Reads one byte.
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when the buffer is exhausted.
    pub fn read_u8(&mut self) -> Result<u8> {
        let byte = self
            .data
            .get(self.offset)
            .copied()
            .ok_or(VideoProtocolError::Truncated)?;
        self.offset += 1;
        Ok(byte)
    }

    /// Reads a big-endian `u16`.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 2 bytes remain.
    pub fn read_u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.read_array()?))
    }

    /// Reads a big-endian `u32`.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 4 bytes remain.
    pub fn read_u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.read_array()?))
    }

    /// Reads a big-endian `u64`.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 8 bytes remain.
    pub fn read_u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.read_array()?))
    }

    /// Reads a big-endian `i32` (two's-complement bit pattern).
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 4 bytes remain.
    pub fn read_i32(&mut self) -> Result<i32> {
        Ok(self.read_u32()?.cast_signed())
    }

    /// Reads a big-endian `i64` (two's-complement bit pattern).
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 8 bytes remain.
    pub fn read_i64(&mut self) -> Result<i64> {
        Ok(self.read_u64()?.cast_signed())
    }

    /// Reads a big-endian IEEE-754 `f64` bit pattern, which MAY be non-finite. Callers that mean
    /// geometry want [`read_finite_f64`](Self::read_finite_f64) instead.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 8 bytes remain.
    pub fn read_f64(&mut self) -> Result<f64> {
        Ok(f64::from_bits(self.read_u64()?))
    }

    /// Reads an `f64` and REJECTS non-finite values (NaN / ±∞) as malformed.
    ///
    /// Coordinates, sizes, bounds and hotspots arrive as raw IEEE-754 bit patterns off the
    /// (WireGuard-encrypted, but otherwise untrusted) UDP wire. A non-finite value is never a
    /// legitimate geometry and is dangerous downstream in BOTH directions: the host's scroll
    /// injector converts to `Int32` with a trapping initialiser, and the CLIENT propagates NaN
    /// through the aspect-fit math into a `CALayer` frame, where assigning NaN geometry raises an
    /// uncaught `CALayerInvalidGeometry` that kills the process. Treating it as malformed lets the
    /// router drop the single packet, which is the whole contract of this path. `field` names the
    /// offending field for diagnostics only.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than 8 bytes remain, or
    /// [`VideoProtocolError::Malformed`] when the value is NaN or ±∞.
    pub fn read_finite_f64(&mut self, field: &str) -> Result<f64> {
        let value = self.read_f64()?;
        if value.is_finite() {
            Ok(value)
        } else {
            Err(VideoProtocolError::malformed(format!("non-finite {field}")))
        }
    }

    /// Reads exactly `count` raw bytes, borrowed from the input. VALIDATE before the caller
    /// allocates: the bound is checked here, so a hostile length can never drive a huge copy.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than `count` bytes remain.
    pub fn read_bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(count)
            .ok_or(VideoProtocolError::Truncated)?;
        let slice = self
            .data
            .get(self.offset..end)
            .ok_or(VideoProtocolError::Truncated)?;
        self.offset = end;
        Ok(slice)
    }

    /// Consumes and returns everything after the current offset, borrowed from the input.
    pub fn remaining(&mut self) -> &'a [u8] {
        let slice = self.data.get(self.offset..).unwrap_or_default();
        self.offset = self.data.len();
        slice
    }

    /// Reads a fixed-size big-endian field into an array.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] when fewer than `N` bytes remain.
    fn read_array<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.read_bytes(N)?
            .try_into()
            .map_err(|_| VideoProtocolError::Truncated)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{ByteReader, ByteWriter};
    use crate::error::VideoProtocolError;

    #[test]
    fn every_width_round_trips_big_endian() {
        let mut out = ByteWriter::new();
        out.put_u8(0x12);
        out.put_u16(0x3456);
        out.put_u32(0x789A_BCDE);
        out.put_u64(0x0102_0304_0506_0708);
        out.put_i32(-2);
        out.put_i64(-3);
        out.put_f64(-0.5);
        out.put_bytes(&[0xAA, 0xBB]);
        let bytes = out.into_vec();

        let mut reader = ByteReader::new(&bytes);
        assert_eq!(reader.read_u8().unwrap(), 0x12);
        assert_eq!(reader.read_u16().unwrap(), 0x3456);
        assert_eq!(reader.read_u32().unwrap(), 0x789A_BCDE);
        assert_eq!(reader.read_u64().unwrap(), 0x0102_0304_0506_0708);
        assert_eq!(reader.read_i32().unwrap(), -2);
        assert_eq!(reader.read_i64().unwrap(), -3);
        assert!((reader.read_f64().unwrap() - -0.5).abs() < f64::EPSILON);
        assert_eq!(reader.remaining(), &[0xAA, 0xBB]);
        assert_eq!(reader.bytes_remaining(), 0);
    }

    #[test]
    fn the_byte_order_is_actually_big_endian() {
        // Round-tripping proves symmetry, not order — this pins the order itself.
        let mut out = ByteWriter::new();
        out.put_u32(1);
        assert_eq!(out.as_slice(), &[0, 0, 0, 1]);
    }

    #[test]
    fn a_short_buffer_is_truncated_rather_than_partial() {
        let mut reader = ByteReader::new(&[0x01, 0x02, 0x03]);
        assert_eq!(reader.read_u32(), Err(VideoProtocolError::Truncated));
        // The failed read consumed nothing: the three bytes are still there.
        assert_eq!(reader.bytes_remaining(), 3);
        assert_eq!(reader.read_u16().unwrap(), 0x0102);
    }

    #[test]
    fn a_length_that_overflows_the_offset_is_truncated_rather_than_wrapping() {
        let mut reader = ByteReader::new(&[0x01]);
        assert_eq!(reader.read_bytes(usize::MAX), Err(VideoProtocolError::Truncated));
        assert_eq!(reader.bytes_remaining(), 1);
    }

    #[test]
    fn a_non_finite_float_is_malformed_but_a_raw_read_still_returns_it() {
        let mut out = ByteWriter::new();
        out.put_f64(f64::NAN);
        out.put_f64(f64::INFINITY);
        out.put_f64(1.5);
        let bytes = out.into_vec();

        let mut raw = ByteReader::new(&bytes);
        assert!(raw.read_f64().unwrap().is_nan(), "the raw read does NOT filter");

        let mut checked = ByteReader::new(&bytes);
        assert_eq!(
            checked.read_finite_f64("x"),
            Err(VideoProtocolError::malformed("non-finite x"))
        );
        let mut past_nan = ByteReader::new(&bytes);
        past_nan.read_f64().unwrap();
        assert_eq!(
            past_nan.read_finite_f64("y"),
            Err(VideoProtocolError::malformed("non-finite y")),
            "±∞ is refused for the same reason NaN is"
        );
        assert!((past_nan.read_finite_f64("z").unwrap() - 1.5).abs() < f64::EPSILON);
    }

    #[test]
    fn remaining_on_an_exhausted_reader_is_empty_rather_than_a_panic() {
        let mut reader = ByteReader::new(&[]);
        assert!(reader.remaining().is_empty());
        assert!(reader.remaining().is_empty(), "and again, idempotently");
    }
}
