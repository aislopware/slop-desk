//! Suppresses the PTY's echo of bytes the compose box just sent, so a prompt the user typed in the
//! overlay is not shown twice (docs/14, B1 execution — mandatory duplicate-prompt dedup).
//!
//! The compose box writes input to the PTY *and* optimistically renders it; the PTY then echoes the
//! same bytes back in the output stream. This ring records recently-sent input and strips the
//! echoed copy out of incoming output.
//!
//! ## Matching strategy — hold-and-confirm (no optimistic drops)
//! We keep a bounded ring of the bytes we expect the PTY to echo back, oldest first. On output we
//! match bytes against the *front* of that expected echo, but we never drop a byte until the match
//! is **confirmed**:
//! - A byte that matches the next expected-echo byte is **held** (tentatively suppressed) and
//!   advances the match cursor.
//! - When the held run completes the whole pending echo, the held bytes are **dropped** (confirmed
//!   echo) and the ring resets.
//! - A byte that breaks the match means the held run was *not* the echo after all: the held bytes
//!   are **flushed back** to the passthrough, the cursor resets, and the breaking byte is
//!   re-processed from the start of the pending echo.
//!
//! This is the key correctness property: a byte that merely *shares a prefix* with the expected
//! echo (the `l` in `total` against an expected `ls`) is held, then flushed intact once the next
//! byte diverges — it is never silently eaten.
//!
//! It handles an exact echo (`ls -la\n` → `ls -la\r\n`), a **partial echo split across chunks**
//! (the held run and the cursor persist between [`filter`](InputDedupRing::filter) calls), and
//! non-echo output (flushed straight through). The common terminal newline echo is normalised (`\n`
//! sent → `\r\n` echoed, and a bare `\r` echo) so the line-ending transform a PTY applies does not
//! defeat the match.
//!
//! ## Ring bound and eviction
//! At most [`capacity`](InputDedupRing::capacity) *bytes* of pending (not-yet-echoed) input are
//! retained, FIFO. When a new send would exceed the bound the oldest pending bytes are evicted —
//! their echo, if it ever arrives, then simply passes through. Correctness over completeness: we
//! never *hold* output waiting for an echo, and we never suppress non-echo content.

/// The default pending-byte bound. A compose-box prompt is small; this bounds memory and staleness.
const DEFAULT_CAPACITY: usize = 4096;

/// The hold-and-confirm echo suppressor.
#[derive(Debug, Clone)]
pub struct InputDedupRing {
    capacity: usize,
    /// The pending echo we still expect to see in the output, oldest byte first.
    pending: Vec<u8>,
    /// How many bytes at the front of `pending` we have already matched against output.
    matched: usize,
    /// Held (tentatively-suppressed) bytes that were EVICTED before their match could be confirmed.
    /// These were real output bytes withheld from passthrough during
    /// [`filter`](Self::filter) awaiting confirmation; eviction is a non-confirmation, so they must
    /// be flushed — the next `filter` emits them first, in stream order, ahead of its own chunk,
    /// instead of eating them.
    flush_buffer: Vec<u8>,
}

impl Default for InputDedupRing {
    fn default() -> Self {
        Self::new()
    }
}

impl InputDedupRing {
    /// A ring at the default 4096-byte bound.
    #[must_use]
    pub const fn new() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }

    /// A ring at an explicit bound. `0` is raised to `1`: a zero-capacity ring would evict every
    /// byte it was just handed, which is a configuration mistake rather than a state worth
    /// representing.
    #[must_use]
    pub const fn with_capacity(capacity: usize) -> Self {
        Self {
            capacity: if capacity == 0 { 1 } else { capacity },
            pending: Vec::new(),
            matched: 0,
            flush_buffer: Vec::new(),
        }
    }

    /// The pending-byte bound in force.
    #[must_use]
    pub const fn capacity(&self) -> usize {
        self.capacity
    }

    /// Number of pending (un-echoed) bytes currently retained.
    #[must_use]
    pub const fn pending_count(&self) -> usize {
        self.pending.len() - self.matched
    }

    /// Records bytes the compose box just wrote to the PTY. Their echo will be suppressed when it
    /// appears in the output; the byte form is normalised so newline-echo transforms still match.
    pub fn record_sent(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        // Append the expected echo of these bytes. We do NOT compact away a tentative (unconfirmed)
        // match prefix here — those held bytes might still need to be flushed back if the in-flight
        // match diverges. Compaction happens only on a confirmed full match (which clears
        // `pending`) or via the FIFO eviction below.
        for &byte in bytes {
            // A PTY in cooked mode (`ONLCR`) echoes a sent `\n` as `\r\n`, and the line discipline
            // often echoes an Enter (`\r`) as `\r\n` too. Expand both so the echo matches either
            // way.
            if byte == b'\n' || byte == b'\r' {
                self.pending.push(b'\r');
                self.pending.push(b'\n');
            } else {
                self.pending.push(byte);
            }
        }

        if self.pending.len() <= self.capacity {
            return;
        }
        let drop_count = self.pending.len() - self.capacity;
        // The evicted region may overlap the already-HELD (matched) prefix — bytes suppressed from
        // passthrough during `filter` awaiting confirmation. Evicting them gives up on the match,
        // so they are real output that must be FLUSHED, not silently eaten. The un-held
        // evicted bytes (expected echo not yet seen in output) are correctly dropped: their
        // future echo, if any, simply passes through — the documented
        // correctness-over-completeness rule.
        let held_evicted = self.matched.min(drop_count);
        if held_evicted > 0 {
            self.flush_buffer
                .extend(self.pending.iter().take(held_evicted).copied());
        }
        self.pending.drain(..drop_count);
        self.matched = self.matched.saturating_sub(drop_count);
    }

    /// Filters an incoming output chunk: drops bytes that are the confirmed echo of recently-sent
    /// input and returns the remaining (non-echo) bytes to render. Non-echo output passes through
    /// untouched.
    pub fn filter(&mut self, output: &[u8]) -> Vec<u8> {
        // Fast path only when there is nothing held AND nothing to flush.
        if self.pending.is_empty() && self.flush_buffer.is_empty() {
            return output.to_vec();
        }

        let mut passthrough = Vec::with_capacity(self.flush_buffer.len() + output.len());
        // Emit any held bytes that were evicted unconfirmed BEFORE this chunk — they precede it in
        // the output stream, having been withheld during an earlier `filter`.
        passthrough.append(&mut self.flush_buffer);

        if self.pending.is_empty() {
            passthrough.extend_from_slice(output);
            return passthrough;
        }
        for &byte in output {
            self.step(byte, &mut passthrough);
        }
        passthrough
    }

    fn step(&mut self, byte: u8, passthrough: &mut Vec<u8>) {
        let Some(&expected) = self.pending.get(self.matched) else {
            passthrough.push(byte);
            return;
        };
        if byte == expected {
            // Tentative match — hold it (do NOT emit yet) and advance.
            self.matched += 1;
            if self.matched == self.pending.len() {
                // The whole pending echo is confirmed: drop the held run, reset the ring.
                self.pending.clear();
                self.matched = 0;
            }
        } else if self.matched > 0 {
            // Mismatch: the bytes we held were NOT echo. Flush them back intact, then re-process
            // this byte against a reset cursor — it may start a fresh match.
            passthrough.extend(self.pending.iter().take(self.matched).copied());
            self.matched = 0;
            self.step(byte, passthrough);
        } else {
            // Nothing held and the very first byte diverges — pass it straight.
            passthrough.push(byte);
        }
    }

    /// Clears all pending state (a mode change, a focus loss, a session boundary).
    pub fn reset(&mut self) {
        self.pending.clear();
        self.matched = 0;
        self.flush_buffer.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::InputDedupRing;

    #[test]
    fn with_no_pending_input_output_passes_through_untouched() {
        let mut ring = InputDedupRing::new();
        assert_eq!(ring.filter(b"anything at all"), b"anything at all");
    }

    #[test]
    fn an_exact_echo_is_suppressed() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"ls -la\n");
        assert_eq!(ring.filter(b"ls -la\r\n"), b"");
        assert_eq!(ring.pending_count(), 0);
    }

    #[test]
    fn a_bare_carriage_return_send_also_expands() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"hi\r");
        assert_eq!(ring.filter(b"hi\r\n"), b"");
    }

    #[test]
    fn an_echo_split_across_chunks_is_still_suppressed() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"echo hi\n");
        assert_eq!(ring.filter(b"echo "), b"");
        assert_eq!(ring.filter(b"hi\r"), b"");
        assert_eq!(ring.filter(b"\n"), b"");
        assert_eq!(ring.pending_count(), 0);
    }

    #[test]
    fn output_that_only_shares_a_prefix_is_flushed_intact() {
        // The `l` in `total` matches the expected `ls`, so it is HELD — and then flushed whole once
        // the `o` diverges. Eating it would be the classic dedup bug.
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"ls");
        assert_eq!(ring.filter(b"total 4"), b"total 4");
    }

    #[test]
    fn a_held_prefix_is_flushed_before_a_later_real_match() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"ls");
        // `l` held, `o` diverges → flush `l`, re-process `o`; then the real `ls` matches and is
        // eaten.
        assert_eq!(ring.filter(b"lols"), b"lo");
        assert_eq!(ring.pending_count(), 0);
    }

    #[test]
    fn an_echo_followed_by_real_output_in_the_same_chunk_keeps_only_the_output() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"pwd\n");
        assert_eq!(ring.filter(b"pwd\r\n/home/me\r\n"), b"/home/me\r\n");
    }

    #[test]
    fn non_echo_output_between_sends_passes_through() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"a");
        assert_eq!(ring.filter(b"zzz"), b"zzz");
        assert_eq!(ring.filter(b"a"), b"");
    }

    #[test]
    fn two_sends_are_matched_as_one_run() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"ab");
        ring.record_sent(b"cd");
        assert_eq!(ring.filter(b"abcd"), b"");
        assert_eq!(ring.pending_count(), 0);
    }

    #[test]
    fn an_eviction_that_cuts_into_the_held_prefix_flushes_it_rather_than_eating_it() {
        // Capacity 4. Send `abcd`, hold `abc` from the output, then send `efgh` — the eviction
        // drops `abcd` and takes the held `abc` with it. Those three bytes were real output
        // withheld from passthrough, so the next filter must emit them first.
        let mut ring = InputDedupRing::with_capacity(4);
        ring.record_sent(b"abcd");
        assert_eq!(ring.filter(b"abc"), b"", "held, awaiting confirmation");
        ring.record_sent(b"efgh");
        assert_eq!(ring.filter(b"zz"), b"abczz", "the held run precedes this chunk");
    }

    #[test]
    fn an_eviction_below_the_held_prefix_drops_only_un_held_bytes() {
        let mut ring = InputDedupRing::with_capacity(4);
        ring.record_sent(b"abcd");
        // Nothing held yet; the eviction is pure expected-echo that never arrived.
        ring.record_sent(b"ef");
        assert_eq!(ring.filter(b"cdef"), b"");
    }

    #[test]
    fn a_reset_forgets_the_pending_echo_and_the_flush_buffer() {
        let mut ring = InputDedupRing::with_capacity(4);
        ring.record_sent(b"abcd");
        assert_eq!(ring.filter(b"abc"), b"");
        ring.record_sent(b"efgh");
        ring.reset();
        assert_eq!(
            ring.filter(b"zz"),
            b"zz",
            "the flush buffer is gone with everything else"
        );
        assert_eq!(ring.pending_count(), 0);
    }

    #[test]
    fn an_empty_send_is_a_no_op() {
        let mut ring = InputDedupRing::new();
        ring.record_sent(b"");
        assert_eq!(ring.pending_count(), 0);
        assert_eq!(ring.filter(b"x"), b"x");
    }

    #[test]
    fn a_zero_capacity_is_raised_to_one_rather_than_evicting_everything() {
        let ring = InputDedupRing::with_capacity(0);
        assert_eq!(ring.capacity(), 1);
    }

    #[test]
    fn a_send_longer_than_the_capacity_keeps_only_its_tail() {
        let mut ring = InputDedupRing::with_capacity(3);
        ring.record_sent(b"abcdef");
        assert_eq!(ring.pending_count(), 3);
        // The retained tail is the NEWEST bytes — the oldest expected echo is the one given up on.
        assert_eq!(ring.filter(b"abcdef"), b"abc");
    }

    #[test]
    fn feeding_the_echo_one_byte_at_a_time_matches_feeding_it_whole() {
        let mut whole = InputDedupRing::new();
        whole.record_sent(b"claude --help\n");
        let bulk = whole.filter(b"claude --help\r\nUsage:");

        let mut streamed = InputDedupRing::new();
        streamed.record_sent(b"claude --help\n");
        let mut produced = Vec::new();
        for byte in b"claude --help\r\nUsage:" {
            produced.extend(streamed.filter(&[*byte]));
        }
        assert_eq!(produced, bulk);
        assert_eq!(produced, b"Usage:");
    }
}
