//! The length-prefixed receive buffer both streaming decoders read through.
//!
//! [`FrameDecoder`](crate::FrameDecoder) reads terminal frames and
//! [`MuxFrameDecoder`](crate::mux::MuxFrameDecoder) reads mux envelopes, and everything BETWEEN the
//! four-byte prefix and the decode call is the same rule twice: fail-stop poisoning that frees the
//! buffer, a read cursor with a bounded wasted head, a compaction that is OWED rather than taken
//! when the last answer pointed into the buffer, and a span rebased out of payload coordinates into
//! the buffer's own.
//!
//! It was that rule twice, and the copies had already drifted three ways by the time this module
//! was written: one `poison` cleared the owed compaction and the other did not; one took an owed
//! compaction at the top of a decode and the other only at `append`; and on the two
//! not-enough-bytes paths one compacted unconditionally while the other honoured the elide flag.
//! None had produced a bug yet, which is the point — this is what a rule looks like just before one
//! of its copies is fixed and the other is not.
//!
//! Where the two disagreed, the CONSERVATIVE reading won: an owed compaction is taken at the top of
//! every decode (both decoders already document a span as void at the next call, so there is
//! nothing to protect by then), it is cleared by `poison` (which frees the buffer, so an owed move
//! is meaningless), and it is never taken on a path that answered a span.

#![expect(
    clippy::redundant_pub_crate,
    reason = "the module is crate-private and the items are `pub(crate)`, which reads as the intent it is; \
              `pub` inside it then trips the stricter `unreachable_pub`"
)]

use core::ops::Range;

use crate::MAX_FRAME_PAYLOAD_LENGTH;
use crate::error::{Result, WireError};

/// Length of the big-endian `u32` frame-length prefix.
pub(crate) const PREFIX_LENGTH: usize = 4;

/// Reclaim the consumed prefix once the read cursor has advanced past this many bytes, so the
/// buffer's wasted head stays bounded during a long burst. 64 KiB == the largest single read chunk,
/// so in the common case compaction happens at most once per received chunk.
pub(crate) const COMPACTION_THRESHOLD: usize = 64 * 1024;

/// A streaming length-prefixed receive buffer: bytes in, one framed payload at a time out.
///
/// Carries mutable state for a single receive loop and is deliberately not shared across tasks.
#[derive(Debug, Clone, Default)]
pub(crate) struct PrefixedReader {
    /// Received bytes. All indexing is relative to `read_offset`.
    buffer: Vec<u8>,
    /// Leading bytes already consumed by completed frames but not yet physically removed.
    read_offset: usize,
    /// Set once a decode fault occurred; every later call returns it.
    fault: Option<WireError>,
    /// A compaction an eliding call put off, because the span it answered points INTO the buffer
    /// and moving the head would have moved the run out from under a caller mid-copy. Taken at the
    /// top of the next call, where the previous span is void anyway.
    deferred_compaction: bool,
}

impl PrefixedReader {
    /// A fresh reader with an empty buffer.
    pub(crate) const fn new() -> Self {
        Self {
            buffer: Vec::new(),
            read_offset: 0,
            fault: None,
            deferred_compaction: false,
        }
    }

    /// Appends a freshly received chunk. Safe with empty input, one byte, or many frames' worth.
    ///
    /// Dropped entirely once poisoned — the buffer was freed at the fault, so a peer that keeps
    /// feeding a dead channel cannot grow it without bound.
    pub(crate) fn append(&mut self, data: &[u8]) {
        if self.fault.is_some() {
            return;
        }
        // Take an owed compaction HERE, before the new bytes land. Left to the next decode it would
        // move a whole freshly-appended frame instead of the empty tail a just-drained buffer has —
        // measurably an extra copy of every second `.output` under a flood. `append` is a call on
        // this reader, so the run a caller was told about is void by now either way.
        self.settle_owed_compaction();
        self.buffer.extend_from_slice(data);
    }

    /// Bytes currently buffered. Lets a caller assert a poisoned decoder cannot be grown.
    pub(crate) const fn buffered_byte_count(&self) -> usize {
        self.buffer.len()
    }

    /// The bytes a span answered by [`next_payload`](Self::next_payload) names, for a caller in
    /// this address space. Empty for a span the buffer has since outlived.
    pub(crate) fn bytes(&self, run: &Range<usize>) -> &[u8] {
        self.buffer.get(run.clone()).unwrap_or(&[])
    }

    /// Marks the reader poisoned and frees the buffer — the remaining bytes are past a lost
    /// boundary and undecodable by definition. Returns the fault, so sites read
    /// `return Err(reader.poison(e))`.
    pub(crate) fn poison(&mut self, error: WireError) -> WireError {
        self.fault = Some(error.clone());
        self.buffer = Vec::new();
        self.read_offset = 0;
        self.deferred_compaction = false;
        error
    }

    /// The next complete frame's payload, decoded by `decode` and answered with its opaque run
    /// rebased into this reader's own coordinates.
    ///
    /// `decode` is handed the payload BETWEEN the prefix and the frame's end, and answers the
    /// decoded value plus the run it left in place, in PAYLOAD coordinates. A decoder that copies
    /// everything answers an empty run.
    ///
    /// `Ok(None)` means a whole frame is not yet buffered — append more bytes and retry. `elide` is
    /// whether the run this call answers will be read out of the buffer afterwards, which is what
    /// decides whether a compaction may happen now or is owed.
    ///
    /// # Errors
    /// [`WireError::FrameTooLarge`] when a length prefix exceeds [`MAX_FRAME_PAYLOAD_LENGTH`], or
    /// whatever `decode` returns. Once either happens the same fault is returned by every later
    /// call.
    pub(crate) fn next_payload<T>(
        &mut self,
        elide: bool,
        decode: impl FnOnce(&[u8]) -> Result<(T, Range<usize>)>,
    ) -> Result<Option<(T, Range<usize>)>> {
        if let Some(fault) = self.fault.clone() {
            return Err(fault);
        }
        self.settle_owed_compaction();

        // Bytes not yet consumed by a completed frame.
        let available = self.buffer.len() - self.read_offset;
        // Need at least the length prefix to know how big the frame is.
        if available < PREFIX_LENGTH {
            self.compact(elide);
            return Ok(None);
        }

        // A prefix wider than this platform's `usize` is by definition past the cap, and falls into
        // the FrameTooLarge arm below rather than needing a cast that could wrap.
        let payload_length = usize::try_from(self.read_prefix()).unwrap_or(usize::MAX);

        // Reject implausibly large frames before waiting for them. The guard is `<=`, so a prefix
        // exactly AT the cap waits for its body rather than faulting.
        if payload_length > MAX_FRAME_PAYLOAD_LENGTH {
            return Err(self.poison(WireError::FrameTooLarge(payload_length)));
        }

        // Wait until the whole payload has arrived (a partial read — not an error).
        let frame_length = PREFIX_LENGTH + payload_length;
        if available < frame_length {
            self.compact(elide);
            return Ok(None);
        }

        // Decode straight out of the buffer: the borrow ends when `decode` returns its owned value,
        // so a 128 KiB `.output` payload is never copied on this line at all.
        //
        // The `ok_or` arm is unreachable — `available >= frame_length` was just checked — but it is
        // an error rather than an assertion so an arithmetic slip could never panic a receive loop.
        let payload_start = self.read_offset + PREFIX_LENGTH;
        let payload_end = self.read_offset + frame_length;
        let decoded = self
            .buffer
            .get(payload_start..payload_end)
            .ok_or(WireError::Truncated)
            .and_then(decode);

        self.read_offset += frame_length;
        // Bound the wasted head mid-burst; a drain that returns None reclaims the rest.
        if self.read_offset >= COMPACTION_THRESHOLD {
            self.compact(elide);
        }

        match decoded {
            // The run was reported relative to the payload; the caller holds this reader, not that
            // slice, so it is answered in the reader's own coordinates.
            Ok((value, run)) => {
                Ok(Some((
                    value,
                    payload_start.saturating_add(run.start)..payload_start.saturating_add(run.end),
                )))
            },
            Err(error) => Err(self.poison(error)),
        }
    }

    /// Compacts, unless a span this call answered would be moved out from under the caller — in
    /// which case the move is OWED, and paid at the next call on this reader.
    fn compact(&mut self, elide: bool) {
        if elide {
            self.deferred_compaction = true;
        } else {
            self.compact_consumed();
        }
    }

    /// Pays an owed compaction, if one is owed.
    fn settle_owed_compaction(&mut self) {
        if self.deferred_compaction {
            self.deferred_compaction = false;
            self.compact_consumed();
        }
    }

    /// Physically drops the consumed prefix from the front ONCE, resetting the cursor — the single
    /// O(remaining) move that replaces the per-frame one.
    fn compact_consumed(&mut self) {
        if self.read_offset > 0 {
            self.buffer.drain(..self.read_offset);
            self.read_offset = 0;
        }
    }

    /// Reads the 4-byte big-endian length prefix at the cursor WITHOUT consuming it — an incomplete
    /// frame must leave the prefix in place for the next call.
    ///
    /// `from_be_bytes` rather than the shift-and-or loop this used to be, on both sides: the caller
    /// has already checked that four bytes are there, so the `try_into` cannot fail and the zero is
    /// only there to keep the panic denial honest.
    fn read_prefix(&self) -> u32 {
        self.buffer
            .get(self.read_offset..self.read_offset + PREFIX_LENGTH)
            .and_then(|prefix| <[u8; PREFIX_LENGTH]>::try_from(prefix).ok())
            .map_or(0, u32::from_be_bytes)
    }
}
