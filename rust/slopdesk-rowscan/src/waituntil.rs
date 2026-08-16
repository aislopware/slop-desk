//! `wait --until PATTERN`: the incremental scan of a live PTY stream for a marker.
//!
//! An agent asks the ctl socket to block until something appears in a pane's output. The pattern is
//! the agent's, the output is whatever program holds the far side of the PTY, and the scan runs on
//! the PTY READ LOOP — so both bounds matter: per-chunk work has to stay proportional to the new
//! bytes, and no pattern may take super-linear time in the text. A backtracking engine here does
//! not merely hang a window; it stalls the loop every pane's bytes come through.
//!
//! ## What makes it incremental
//!
//! Three pieces of carried state, each bounded:
//!
//! - `carry` — raw bytes held back because they end mid-escape or mid-codepoint, and can only be
//!   stripped once their continuation arrives. Capped at [`MAX_CARRY_BYTES`]: a sequence that will
//!   not terminate inside that budget is not a real escape worth waiting for, so it is
//!   force-flushed through the stripper rather than buffered without bound.
//! - `recent` — the tail of the already-stripped text, prepended to each new chunk so a marker
//!   split across a chunk boundary still matches. Capped at [`OVERLAP_WINDOW`] scalars, which is
//!   what makes the match window fixed-width instead of the whole accumulation.
//! - `stripped` — the accumulation itself, capped by the caller's budget and trimmed to its newest
//!   half past it.
//!
//! Re-matching the whole accumulation per chunk is the shape this replaced: quadratic over a chatty
//! command, and visibly laggy in the pane.

use regex::Regex;
use slopdesk_sanitize::plaintext::{holdback_start, strip};

/// Raw-byte budget for the held-back tail. Real terminal escapes are far shorter.
pub const MAX_CARRY_BYTES: usize = 128;

/// Scalars of already-stripped text re-included ahead of each new chunk's match window.
pub const OVERLAP_WINDOW: usize = 4096;

/// One live `wait --until` scan over one pane's output.
#[derive(Debug)]
pub struct Scanner {
    regex: Regex,
    buffer_cap: usize,
    carry: Vec<u8>,
    recent: String,
    stripped: Vec<u8>,
}

impl Scanner {
    /// A scanner for `pattern`, or `None` when the pattern does not compile — which the caller
    /// reports as an error rather than dropping, because unlike a find field being typed into, this
    /// pattern arrived whole and a caller that mistyped it would otherwise block until its timeout.
    #[must_use]
    pub fn new(pattern: &str, buffer_cap: usize) -> Option<Self> {
        Regex::new(pattern).ok().map(|regex| {
            Self {
                regex,
                buffer_cap,
                carry: Vec::new(),
                recent: String::new(),
                stripped: Vec::new(),
            }
        })
    }

    /// Feeds one raw PTY chunk. `true` when the pattern matched in the window this chunk completed;
    /// the caller latches that, so a match never has to be re-reported.
    pub fn ingest(&mut self, chunk: &[u8]) -> bool {
        let mut pending = core::mem::take(&mut self.carry);
        pending.extend_from_slice(chunk);

        let mut cut = holdback_start(&pending);
        if pending.len().saturating_sub(cut) > MAX_CARRY_BYTES {
            cut = pending.len();
        }
        if let Some(held) = pending.get(cut..) {
            self.carry.extend_from_slice(held);
        }
        let Some(ready) = pending.get(..cut).filter(|ready| !ready.is_empty()) else {
            return false;
        };

        // Stripped before decoded, which the Swift did the other way round: the grammar is ASCII, so
        // no invalid byte can be part of a sequence, and stripping first is one copy fewer.
        let text = String::from_utf8_lossy(&strip(ready)).into_owned();
        if text.is_empty() {
            return false;
        }

        self.stripped.extend_from_slice(text.as_bytes());
        if self.stripped.len() > self.buffer_cap {
            // Halve by shift rather than `/`: an odd cap's leftover byte is not a quantity worth a
            // rounding decision, and the crate denies integer division so that the ones that ARE
            // have to say so.
            let over = self.stripped.len().saturating_sub(self.buffer_cap >> 1_u32);
            self.stripped.drain(..over);
        }

        let window = format!("{}{text}", self.recent);
        self.recent = tail_scalars(&window, OVERLAP_WINDOW);
        self.regex.is_match(&window)
    }

    /// The capped accumulation of everything stripped so far. Storage only — matching is windowed.
    #[must_use]
    pub fn stripped(&self) -> &[u8] {
        &self.stripped
    }
}

/// The last `count` scalars of `text`.
fn tail_scalars(text: &str, count: usize) -> String {
    let mut start = text.len();
    for (index, _) in text.char_indices().rev().take(count) {
        start = index;
    }
    text.get(start..).unwrap_or(text).to_owned()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{MAX_CARRY_BYTES, Scanner, tail_scalars};

    fn scanner(pattern: &str) -> Scanner {
        Scanner::new(pattern, 64 * 1024).expect("the test patterns compile")
    }

    #[test]
    fn a_pattern_that_does_not_compile_is_refused_rather_than_dropped() {
        assert!(Scanner::new("([unclosed", 1024).is_none());
    }

    #[test]
    fn a_marker_split_across_chunks_still_matches() {
        let mut scan = scanner("BUILD COMPLETE");
        assert!(!scan.ingest(b"lots of earlier output... BUILD COM"));
        assert!(scan.ingest(b"PLETE and a tail"));
    }

    #[test]
    fn an_escape_split_mid_sequence_is_carried_and_strips_clean() {
        let mut scan = scanner("BUILD COMPLETE");
        assert!(!scan.ingest(b"BUILD \x1b[3"));
        assert!(scan.ingest(b"2mCOMPLETE\x1b[0m\n"));
    }

    #[test]
    fn a_codepoint_split_across_chunks_decodes_whole() {
        let mut scan = scanner("réussite");
        assert!(!scan.ingest(b"compilation r\xc3"));
        assert!(scan.ingest(b"\xa9ussite\n"));
    }

    #[test]
    fn a_runaway_body_is_force_flushed_and_the_scan_keeps_working() {
        let mut scan = scanner("MARKER");
        let mut giant = b"\x1b]1337;File=".to_vec();
        giant.extend(std::iter::repeat_n(b'A', MAX_CARRY_BYTES * 32));
        assert!(!scan.ingest(&giant));
        assert!(scan.ingest(b"\nMARKER\n"));
    }

    #[test]
    fn the_accumulator_honours_its_cap_and_keeps_the_newest_half() {
        let mut scan = Scanner::new("NEVER MATCHES ANYTHING", 1024).expect("compiles");
        for _ in 0..64 {
            assert!(!scan.ingest(&[b'a'; 64]));
        }
        assert!(scan.stripped().len() <= 1024, "the cap holds");
        assert!(
            !scan.stripped().is_empty(),
            "the trim keeps the newest half, not nothing"
        );
    }

    #[test]
    fn the_overlap_window_counts_scalars_and_never_splits_one() {
        assert_eq!(tail_scalars("abcdef", 2), "ef");
        assert_eq!(tail_scalars("héé", 2), "éé");
        assert_eq!(tail_scalars("ab", 9), "ab");
    }
}
