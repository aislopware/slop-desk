//! Forward-only big-endian reader for the terminal path — a port of Swift
//! `AislopdeskProtocol.BigEndianReader`.
//!
//! All multi-byte integers on the wire are big-endian ("network byte order"); assembly
//! is byte-by-byte so the code is alignment-safe and endian-explicit, with no `unsafe`.
//! Every read consumes from the current offset and returns
//! [`TerminalProtocolError::Truncated`] when the buffer is exhausted.
//!
//! As in [`crate::bytes::ByteReader`], [`read_bytes`](BigEndianReader::read_bytes) and
//! [`remaining`](BigEndianReader::remaining) return *borrows* into the input rather than
//! copying into a fresh buffer (the one intentional, behaviour-identical improvement over
//! the Swift reader, which returns a fresh `Data`). Callers that need ownership call
//! `.to_vec()`.

use super::error::{Result, TerminalProtocolError};

/// A forward-only big-endian reader over a byte slice.
#[derive(Debug, Clone)]
pub struct BigEndianReader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> BigEndianReader<'a> {
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
            Err(TerminalProtocolError::Truncated)
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

    /// Reads a big-endian `i32` (two's-complement bit pattern, like Swift's
    /// `Int32(bitPattern:)`).
    pub fn read_i32(&mut self) -> Result<i32> {
        Ok(self.read_u32()? as i32)
    }

    /// Reads a big-endian `i64` (two's-complement bit pattern).
    pub fn read_i64(&mut self) -> Result<i64> {
        Ok(self.read_u64()? as i64)
    }

    /// Reads exactly `count` raw bytes, returned as a borrow into the input. Returns
    /// [`TerminalProtocolError::Truncated`] if fewer than `count` bytes remain.
    pub fn read_bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        if self.bytes_remaining() >= count {
            let start = self.offset;
            self.offset += count;
            Ok(&self.data[start..start + count])
        } else {
            Err(TerminalProtocolError::Truncated)
        }
    }

    /// Consumes and returns all remaining bytes as a borrow into the input.
    pub fn remaining(&mut self) -> &'a [u8] {
        let start = self.offset;
        self.offset = self.data.len();
        &self.data[start..]
    }
}
