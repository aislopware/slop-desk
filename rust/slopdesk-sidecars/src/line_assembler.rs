//! Turning a service's PTY stream back into the lines it thought it was writing.
//!
//! A panel backend — `code-server`, `baguette serve` — is held by superd, and superd's one spawn
//! primitive is `openpty` + `fork` + `execve`. That is deliberate and it stays that way: a second,
//! pipe-flavoured pre-exec window beside the disassembly-pinned one is a large thing to build in
//! order to buy a carriage return. So the caller gets a TTY stream, and this is what makes it
//! readable again.
//!
//! ## The carriage return is the whole point
//!
//! A service announces its port once, on its first line, and that line is parsed by a marker search
//! plus a digit run. A tty turns the child's `\n` into `\r\n`, so any parser that took the rest of
//! the line after the marker would carry the `\r` into the port. One trailing `\r` therefore comes
//! off each line — and exactly one. Not a loop: a service that genuinely printed `foo\r\r\n` said
//! something with a `\r` in it, and swallowing the lot would be this module inventing content.
//! Interior carriage returns survive for the same reason.
//!
//! ## The cap does not truncate the line, and does not split it — it DROPS the residue
//!
//! Past [`LineAssembler::MAXIMUM_LINE_BYTES`], an unterminated line is discarded rather than grown.
//! The alternative is a long-lived panel whose memory tracks a child that never emits a newline,
//! and a service that writes a megabyte without a break is not one whose port is going to be found
//! in it anyway. Three consequences, each a real behaviour rather than a rounding of it, and each
//! pinned below:
//!
//! * The cap is measured on what is LEFT after complete lines have been taken out, so a line can be
//!   emitted whole at up to the cap plus one chunk. The bound is on retained memory, not on the
//!   length of an answer.
//! * A single unterminated line longer than the cap is dropped in instalments — once per append
//!   that carries the residue over — so when its newline finally lands, what comes out is the tail
//!   accumulated since the last drop, not the line. That tail is a FRAGMENT, and a caller that
//!   parses it will parse a fragment. It is reported rather than suppressed because suppressing it
//!   would mean remembering that a drop happened, which is the state the cap exists to stop
//!   keeping.
//! * The comparison is strict, so a residue of exactly the cap survives to be completed by the next
//!   chunk.
//!
//! ## A line that is not UTF-8 is dropped, not repaired
//!
//! The caller's sink takes strings. Substituting replacement characters would hand a port parser a
//! line that looks like the child's and is not, so an undecodable line is simply not reported — the
//! same validate-then-drop the rest of this path uses.

/// Accumulates PTY chunks and yields the complete lines in them.
///
/// Holds only the residue: everything up to the last newline seen has already left.
#[derive(Clone, Debug, Default)]
pub struct LineAssembler {
    pending: Vec<u8>,
}

impl LineAssembler {
    /// Past this many retained bytes, a line with no newline in it is discarded rather than grown
    /// forever. See the module header for what "discarded" costs.
    pub const MAXIMUM_LINE_BYTES: usize = 64 * 1024;

    /// A fresh assembler with nothing pending.
    #[must_use]
    pub const fn new() -> Self {
        Self { pending: Vec::new() }
    }

    /// Folds one chunk in and returns every line it completed, in order.
    ///
    /// Returns an empty vector when the chunk carried no newline — which is the ordinary answer
    /// while a line is still arriving, and is not distinguishable from the cap having just dropped
    /// one. Nothing here reports the drop; see the module header.
    pub fn append(&mut self, chunk: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(chunk);
        let mut complete = Vec::new();
        let mut consumed = 0;
        while let Some(offset) = self
            .pending
            .get(consumed..)
            .and_then(|rest| rest.iter().position(|&byte| byte == b'\n'))
        {
            let end = consumed.saturating_add(offset);
            let mut line = self.pending.get(consumed..end).unwrap_or_default();
            // Exactly one, and only at the end: what the tty added, and nothing the child wrote.
            if line.last() == Some(&b'\r') {
                line = line.get(..line.len().saturating_sub(1)).unwrap_or_default();
            }
            if let Ok(text) = core::str::from_utf8(line) {
                complete.push(text.to_owned());
            }
            consumed = end.saturating_add(1);
        }
        self.pending.drain(..consumed.min(self.pending.len()));
        // Strictly greater: a residue sitting exactly on the cap is still a line that the next
        // chunk may complete.
        if self.pending.len() > Self::MAXIMUM_LINE_BYTES {
            self.pending = Vec::new();
        }
        complete
    }
}

#[cfg(test)]
mod tests {
    use super::LineAssembler;

    #[test]
    fn complete_lines_come_out_whole_and_in_order() {
        let mut assembler = LineAssembler::new();
        assert_eq!(assembler.append(b"first\nsecond\n"), ["first", "second"]);
    }

    /// The reason this type exists: a trailing `\r` rides into the port on any parser that takes
    /// the rest of the line after the marker.
    #[test]
    fn the_carriage_return_a_pty_adds_is_removed() {
        let mut assembler = LineAssembler::new();
        assert_eq!(assembler.append(b"HTTP server listening on port 41234\r\n"), [
            "HTTP server listening on port 41234"
        ]);
    }

    /// One, not all — and only at the end. A child that printed a `\r` printed it.
    #[test]
    fn exactly_one_trailing_carriage_return_comes_off() {
        let mut assembler = LineAssembler::new();
        assert_eq!(assembler.append(b"a\r\r\n"), ["a\r"]);
        assert_eq!(assembler.append(b"mid\rdle\r\n"), ["mid\rdle"]);
        assert_eq!(assembler.append(b"\r\n"), [""]);
    }

    #[test]
    fn a_partial_line_waits_for_its_newline_across_chunks() {
        let mut assembler = LineAssembler::new();
        assert!(assembler.append(b"listening on por").is_empty());
        assert_eq!(assembler.append(b"t 41234\r\n"), ["listening on port 41234"]);
    }

    #[test]
    fn an_empty_line_is_still_a_line() {
        let mut assembler = LineAssembler::new();
        assert_eq!(assembler.append(b"\r\na\n"), ["", "a"]);
    }

    /// A service that emits a megabyte with no break is not one whose port is going to be found,
    /// and growing the buffer for it is how a long-running panel leaks.
    #[test]
    fn a_runaway_line_is_discarded_rather_than_grown_forever() {
        let mut assembler = LineAssembler::new();
        let flood = vec![b'x'; LineAssembler::MAXIMUM_LINE_BYTES + 1];
        assert!(assembler.append(&flood).is_empty());
        assert_eq!(
            assembler.append(b"after the flood\n"),
            ["after the flood"],
            "the cap drops the runaway, and the next real line must still arrive",
        );
    }

    /// Strictly greater. A residue of exactly the cap is a line that has not gone wrong yet.
    #[test]
    fn a_residue_of_exactly_the_cap_survives_to_be_completed() {
        let mut assembler = LineAssembler::new();
        let exact = vec![b'x'; LineAssembler::MAXIMUM_LINE_BYTES];
        assert!(assembler.append(&exact).is_empty());
        let completed = assembler.append(b"yy\n");
        assert_eq!(
            completed.first().map(String::len),
            Some(LineAssembler::MAXIMUM_LINE_BYTES + 2),
            "the cap bounds RETAINED bytes, not the length of an answer — the check runs after the complete \
             lines have been taken out",
        );
    }

    /// The consequence of dropping the residue rather than the line: the tail that arrived AFTER
    /// the last drop is reported as if it were a line. It is a fragment, and it is pinned here
    /// because suppressing it would mean remembering the drop — the state the cap exists to avoid.
    #[test]
    fn the_tail_after_a_dropped_runaway_is_reported_as_a_line() {
        let mut assembler = LineAssembler::new();
        assert!(
            assembler
                .append(&vec![b'x'; LineAssembler::MAXIMUM_LINE_BYTES + 1])
                .is_empty()
        );
        assert_eq!(
            assembler.append(b"tail\n"),
            ["tail"],
            "a parser reading this reads a fragment of the runaway, not a line the child wrote",
        );
    }

    /// The caller's sink takes strings, and a repaired line looks like the child's without being
    /// it. Its newline is still consumed, so the lines around it are unaffected.
    #[test]
    fn a_line_that_is_not_utf8_is_dropped_and_its_neighbours_are_not() {
        let mut assembler = LineAssembler::new();
        let mut chunk = b"before\n".to_vec();
        chunk.extend_from_slice(&[0xFF, 0xFE, b'\n']);
        chunk.extend_from_slice(b"after\n");
        assert_eq!(assembler.append(&chunk), ["before", "after"]);
    }

    /// Multi-byte UTF-8 split across a chunk boundary must not be read as two broken halves — the
    /// pending bytes are held as BYTES and only decoded once a newline says the line is whole.
    #[test]
    fn a_multibyte_character_split_across_chunks_survives() {
        let mut assembler = LineAssembler::new();
        let text = "café ☕".as_bytes();
        // Seven bytes lands INSIDE the three-byte ☕, which is the boundary a chunked read hits.
        let (head, tail) = text.split_at(7);
        assert!(assembler.append(head).is_empty());
        let mut rest = tail.to_vec();
        rest.push(b'\n');
        assert_eq!(assembler.append(&rest), ["café ☕"]);
    }

    #[test]
    fn an_empty_chunk_completes_nothing_and_loses_nothing() {
        let mut assembler = LineAssembler::new();
        assert!(assembler.append(b"half").is_empty());
        assert!(assembler.append(b"").is_empty());
        assert_eq!(assembler.append(b"-done\n"), ["half-done"]);
    }

    /// One chunk carrying many lines is the ordinary shape of a ring replay on adopt: the whole of
    /// a service's retained output arrives at once, and the announce line is the first of it.
    #[test]
    fn a_replayed_ring_yields_every_line_it_holds_in_order() {
        let mut assembler = LineAssembler::new();
        let lines = assembler.append(b"one\r\ntwo\r\nthree\r\npart");
        assert_eq!(lines, ["one", "two", "three"]);
        assert_eq!(assembler.append(b"ial\n"), ["partial"]);
    }
}
