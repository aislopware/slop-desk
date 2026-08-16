//! Splits an incrementally-growing byte stream into complete `\n`-terminated lines.
//!
//! This is the tailer's pure, deterministic core — the part that must not miss a line and must not
//! double-emit one. The tailer feeds raw byte deltas as the file grows; only COMPLETE lines come
//! back, and a partial trailing line is held until its newline arrives.
//!
//! Two hazards are handled here rather than upstream, because the transcript is UNTRUSTED input
//! that arrives one append at a time:
//!
//! - **An unterminated line** (a corrupt feed, or a deliberately huge one) would grow the buffer
//!   without bound — host RAM exhausted by transcript content alone. Past the cap the accumulator
//!   enters SKIP mode: bytes are discarded until the next newline, which ends the over-long line
//!   and re-syncs the stream.
//! - **Invalid UTF-8** must still SURFACE as a line (the caller maps an unparseable one to
//!   `Unknown`) rather than vanish. So the decode is lossy — U+FFFD substitution — never fallible.

/// 16 MiB — well past any real Claude transcript line, and the point at which an unterminated one
/// stops being tolerated.
pub const DEFAULT_MAX_PENDING_BYTES: usize = 16 * 1024 * 1024;

/// Accumulates byte deltas and yields whole lines.
#[derive(Debug)]
pub struct LineAccumulator {
    /// Cap on the buffered partial line before skip mode engages.
    max_pending_bytes: usize,
    /// Bytes received but not yet terminated by a newline.
    pending: Vec<u8>,
    /// True while discarding an over-long line until its terminating newline.
    skipping_overlong_line: bool,
}

impl Default for LineAccumulator {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_PENDING_BYTES)
    }
}

impl LineAccumulator {
    /// A new accumulator holding back at most `max_pending_bytes` of unterminated line.
    ///
    /// A zero cap is meaningless (every line would be over-long before its first byte), so it is
    /// clamped to 1 rather than rejected — this is called from a config path, not a hot loop.
    #[must_use]
    pub fn new(max_pending_bytes: usize) -> Self {
        Self {
            max_pending_bytes: max_pending_bytes.max(1),
            pending: Vec::new(),
            skipping_overlong_line: false,
        }
    }

    /// Appends a delta and returns every newly-completed line, newline stripped.
    ///
    /// A trailing partial line stays buffered and is NOT returned — it surfaces only once its
    /// newline arrives, so a line written as `"abc"` then `"def\n"` emits exactly once, as
    /// `"abcdef"`.
    pub fn append(&mut self, data: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(data);
        self.drain_complete_lines()
    }

    /// Resets everything — used on truncation/rotation, where the byte offset restarts and any
    /// half-line being held is stale.
    pub fn reset(&mut self) {
        self.pending.clear();
        self.skipping_overlong_line = false;
    }

    /// Bytes currently held back as an incomplete line.
    #[must_use]
    pub const fn buffered_byte_count(&self) -> usize {
        self.pending.len()
    }

    /// One linear pass: advance a cursor, slice each complete line, then drop the whole consumed
    /// prefix ONCE at the end. Removing from the FRONT per line would memmove the entire tail on
    /// every removal, making a newline-dense delta quadratic — a 1 MiB all-newlines poll would
    /// stall the tailer for seconds.
    fn drain_complete_lines(&mut self) -> Vec<String> {
        let mut lines = Vec::new();
        let mut search_start = 0;

        while let Some(offset) = self
            .pending
            .get(search_start..)
            .and_then(|rest| rest.iter().position(|byte| *byte == b'\n'))
        {
            let newline_index = search_start + offset;
            if self.skipping_overlong_line {
                // This newline ends the over-long line being discarded — resync, emit nothing.
                self.skipping_overlong_line = false;
            } else if let Some(slice) = self.pending.get(search_start..newline_index) {
                let bytes = slice.strip_suffix(b"\r").unwrap_or(slice); // CRLF tolerance
                lines.push(String::from_utf8_lossy(bytes).into_owned());
            }
            search_start = newline_index + 1;
        }

        if self.skipping_overlong_line {
            // No newline arrived to end the over-long line; the whole buffer is its still
            // unterminated remainder — discard it and keep skipping.
            self.pending.clear();
        } else {
            if search_start > 0 {
                self.pending.drain(..search_start);
            }
            // Cap the surviving partial: grown past the cap with no newline in sight, discard it and
            // enter skip mode so the REST of that line is dropped too instead of accumulating.
            if self.pending.len() > self.max_pending_bytes {
                self.pending.clear();
                self.skipping_overlong_line = true;
            }
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::LineAccumulator;

    #[test]
    fn a_partial_line_is_held_until_its_newline() {
        let mut acc = LineAccumulator::default();
        assert!(acc.append(b"abc").is_empty());
        assert_eq!(acc.buffered_byte_count(), 3);
        assert_eq!(acc.append(b"def\n"), vec!["abcdef".to_owned()]);
        assert_eq!(acc.buffered_byte_count(), 0);
    }

    #[test]
    fn a_burst_of_many_lines_comes_back_in_order_with_the_tail_held() {
        let mut acc = LineAccumulator::default();
        assert_eq!(acc.append(b"one\ntwo\nthree\npart"), vec![
            "one".to_owned(),
            "two".to_owned(),
            "three".to_owned()
        ]);
        assert_eq!(acc.buffered_byte_count(), 4);
    }

    #[test]
    fn crlf_endings_lose_only_the_carriage_return() {
        let mut acc = LineAccumulator::default();
        assert_eq!(acc.append(b"a\r\nb\n"), vec!["a".to_owned(), "b".to_owned()]);
    }

    #[test]
    fn an_empty_line_is_still_a_line() {
        let mut acc = LineAccumulator::default();
        assert_eq!(acc.append(b"\n\n"), vec![String::new(), String::new()]);
    }

    #[test]
    fn invalid_utf8_surfaces_lossily_rather_than_vanishing() {
        let mut acc = LineAccumulator::default();
        let lines = acc.append(b"ok\xFF\xFEbad\n");
        assert_eq!(lines.len(), 1, "the line must not be dropped");
        assert!(lines[0].contains('\u{FFFD}'));
        assert!(lines[0].starts_with("ok") && lines[0].ends_with("bad"));
    }

    #[test]
    fn a_multibyte_character_split_across_two_appends_reassembles() {
        let mut acc = LineAccumulator::default();
        let snowman = "☃".as_bytes();
        assert!(acc.append(&snowman[..1]).is_empty());
        let mut rest = snowman[1..].to_vec();
        rest.push(b'\n');
        assert_eq!(acc.append(&rest), vec!["☃".to_owned()]);
    }

    #[test]
    fn reset_drops_the_half_line() {
        let mut acc = LineAccumulator::default();
        drop(acc.append(b"stale"));
        acc.reset();
        assert_eq!(acc.buffered_byte_count(), 0);
        assert_eq!(acc.append(b"fresh\n"), vec!["fresh".to_owned()]);
    }

    #[test]
    fn an_overlong_line_is_dropped_and_the_stream_resyncs_on_the_next_newline() {
        let mut acc = LineAccumulator::new(8);
        assert!(acc.append(b"0123456789abcdef").is_empty());
        assert_eq!(acc.buffered_byte_count(), 0, "the over-long tail is dropped");
        // The remainder of the over-long line, its newline, then a good line.
        assert_eq!(acc.append(b"still-the-same-line\ngood\n"), vec![
            "good".to_owned()
        ]);
    }

    #[test]
    fn an_overlong_line_spanning_several_appends_never_grows_the_buffer() {
        let mut acc = LineAccumulator::new(16);
        for _ in 0..64 {
            drop(acc.append(&[b'x'; 64]));
            assert!(acc.buffered_byte_count() <= 16);
        }
        assert_eq!(acc.append(b"\nafter\n"), vec!["after".to_owned()]);
    }

    #[test]
    fn a_zero_cap_is_clamped_rather_than_rejected() {
        let mut acc = LineAccumulator::new(0);
        assert_eq!(acc.append(b"a\n"), vec!["a".to_owned()]);
    }
}
