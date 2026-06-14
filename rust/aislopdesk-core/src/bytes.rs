//! Big-endian wire read/write helpers — a faithful port of Swift
//! `AislopdeskVideoProtocol.VideoWireBytes` (the `Data.appendBE` family +
//! `VideoByteReader`).
//!
//! All multi-byte integers on the wire are big-endian ("network byte order").
//! Assembly is byte-by-byte so the code is alignment-safe and endian-explicit, with
//! no `unsafe` and no third-party dependency — matching the Swift source exactly.
//!
//! The one intentional improvement over the Swift reader: [`ByteReader::read_bytes`]
//! and [`ByteReader::remaining`] return *borrows* into the input rather than copying
//! into a fresh buffer. This is byte-identical in behaviour and strictly faster
//! (zero-copy); callers that need ownership call `.to_vec()`.

use crate::error::{Result, VideoProtocolError};

/// Largest UTF-8 byte length a `u16`-length-prefixed string can carry on the wire.
const MAX_LENGTH_PREFIXED_BYTES: usize = u16::MAX as usize;

/// A growable big-endian wire encoder. Mirrors the `Data.appendBE(_:)` extensions.
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
        self.put_u32(value as u32);
    }

    /// Appends a big-endian `i64` (two's-complement bit pattern).
    pub fn put_i64(&mut self, value: i64) {
        self.put_u64(value as u64);
    }

    /// Appends a big-endian IEEE-754 `f64` bit pattern.
    pub fn put_f64(&mut self, value: f64) {
        self.put_u64(value.to_bits());
    }

    /// Appends raw bytes verbatim.
    pub fn put_bytes(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// Appends a `u16` byte-length prefix followed by the string's UTF-8 bytes.
    ///
    /// A string whose UTF-8 exceeds `u16::MAX` bytes is truncated at a byte boundary
    /// (matching Swift's `Array(string.utf8).prefix(UInt16.max)`), which the lossy
    /// decoder on the read side tolerates. Window titles are never that long; this
    /// only guards a pathological input.
    pub fn put_length_prefixed_str(&mut self, value: &str) {
        let bytes = value.as_bytes();
        let len = bytes.len().min(MAX_LENGTH_PREFIXED_BYTES);
        self.put_u16(len as u16);
        self.put_bytes(&bytes[..len]);
    }

    /// Number of bytes written so far.
    #[must_use]
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    /// Whether nothing has been written yet.
    #[must_use]
    pub fn is_empty(&self) -> bool {
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

/// A forward-only big-endian reader over a byte slice. Mirrors `VideoByteReader`;
/// every read consumes from the current offset and returns
/// [`VideoProtocolError::Truncated`] when the buffer is exhausted.
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

    fn next_byte(&mut self) -> Result<u8> {
        if self.offset < self.data.len() {
            let byte = self.data[self.offset];
            self.offset += 1;
            Ok(byte)
        } else {
            Err(VideoProtocolError::Truncated)
        }
    }

    /// Reads one byte.
    pub fn read_u8(&mut self) -> Result<u8> {
        self.next_byte()
    }

    /// Reads a big-endian `u16`.
    pub fn read_u16(&mut self) -> Result<u16> {
        let b0 = u16::from(self.next_byte()?);
        let b1 = u16::from(self.next_byte()?);
        Ok((b0 << 8) | b1)
    }

    /// Reads a big-endian `u32`.
    pub fn read_u32(&mut self) -> Result<u32> {
        let mut value: u32 = 0;
        for _ in 0..4 {
            value = (value << 8) | u32::from(self.next_byte()?);
        }
        Ok(value)
    }

    /// Reads a big-endian `u64`.
    pub fn read_u64(&mut self) -> Result<u64> {
        let mut value: u64 = 0;
        for _ in 0..8 {
            value = (value << 8) | u64::from(self.next_byte()?);
        }
        Ok(value)
    }

    /// Reads a big-endian `i32` (two's-complement bit pattern).
    pub fn read_i32(&mut self) -> Result<i32> {
        Ok(self.read_u32()? as i32)
    }

    /// Reads a big-endian `i64` (two's-complement bit pattern).
    pub fn read_i64(&mut self) -> Result<i64> {
        Ok(self.read_u64()? as i64)
    }

    /// Reads a big-endian IEEE-754 `f64` bit pattern (may be non-finite).
    pub fn read_f64(&mut self) -> Result<f64> {
        Ok(f64::from_bits(self.read_u64()?))
    }

    /// Reads an `f64` and rejects non-finite values (NaN / ±∞) as malformed.
    ///
    /// Coordinates, sizes, bounds and hotspots arrive as raw IEEE-754 bit patterns
    /// off the untrusted wire. A non-finite value is never legitimate geometry and is
    /// dangerous downstream (trapping float→int conversions, invalid layer geometry),
    /// so a corrupt datagram is dropped rather than propagated. `field` names the
    /// offending field for diagnostics only.
    pub fn read_finite_f64(&mut self, field: &str) -> Result<f64> {
        let value = self.read_f64()?;
        if value.is_finite() {
            Ok(value)
        } else {
            Err(VideoProtocolError::malformed(format!("non-finite {field}")))
        }
    }

    /// Reads exactly `count` raw bytes, returned as a borrow into the input.
    pub fn read_bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        if self.bytes_remaining() >= count {
            let start = self.offset;
            self.offset += count;
            Ok(&self.data[start..start + count])
        } else {
            Err(VideoProtocolError::Truncated)
        }
    }

    /// Consumes and returns all remaining bytes as a borrow into the input.
    pub fn remaining(&mut self) -> &'a [u8] {
        let start = self.offset;
        self.offset = self.data.len();
        &self.data[start..]
    }

    /// Reads a `u16`-length-prefixed UTF-8 string (counterpart to
    /// [`ByteWriter::put_length_prefixed_str`]).
    ///
    /// A prefix larger than the remaining bytes returns
    /// [`VideoProtocolError::Truncated`] (the datagram is dropped, never over-read).
    /// Invalid UTF-8 decodes lossily — a remote window title must never crash the
    /// receiver (matches Swift's `String(decoding:as:UTF8.self)`).
    pub fn read_length_prefixed_str(&mut self) -> Result<String> {
        let len = usize::from(self.read_u16()?);
        let bytes = self.read_bytes(len)?;
        Ok(String::from_utf8_lossy(bytes).into_owned())
    }
}
