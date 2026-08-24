//! Plain text as LOGICAL lines — what an agent's regex is actually matched against.
//!
//! [`crate::plaintext`] renders retained PTY bytes as text; this splits that text where the shell
//! itself ended a line, and takes the tail an orchestrator asked for. The two are one pipeline, so
//! they live in one crate: every caller of the second has already called the first.
//!
//! ## Why a hard `\n` is the only boundary
//!
//! The host keeps no screen buffer and the scrollback ring stores raw read-CHUNK slices, not
//! width-aware rows, so un-wrapping a soft-wrapped visual row is not possible here — a wrapped row
//! carries no marker saying it was one. What this fold DOES give is independence from chunk and
//! transport boundaries: the caller joins every stored chunk in sequence first, so a hard line
//! split across two reads is one string by the time it arrives.
//!
//! ## The last line is KEPT
//!
//! A trailing `\n` leaves an empty final element that is a separator artifact, and that one is
//! dropped. Text that does NOT end in `\n` ends in a complete-but-unterminated line instead — and
//! host-side that is indistinguishable from the very thing an orchestrator scrapes for: a live
//! shell prompt, or an agent's "awaiting input" line, neither of which carries a newline. Dropping
//! it would swallow the freshest line the caller came for; keeping a genuinely half-written one
//! costs a regex nothing.

/// `text` as logical lines, at most `limit` of them counting from the END.
///
/// `None` (or `Some(0)`) is every line. Empty text is no lines at all — not one empty line, which
/// is what a naive split answers and what would make "did anything arrive" unanswerable.
///
/// Borrowed rather than owned: the caller already holds the text, and the tail is the common case.
#[must_use]
pub fn logical_lines(text: &str, limit: Option<usize>) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    let body = text.strip_suffix('\n').unwrap_or(text);
    let mut rows: Vec<&str> = body.split('\n').collect();
    if let Some(limit) = limit
        && limit > 0
        && rows.len() > limit
    {
        rows.drain(..rows.len() - limit);
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::logical_lines;

    #[test]
    fn every_hard_line_is_one_row() {
        assert_eq!(logical_lines("alpha\nbeta\ngamma", None), [
            "alpha", "beta", "gamma"
        ]);
    }

    #[test]
    fn a_terminating_newline_is_a_separator_not_a_row() {
        assert_eq!(logical_lines("alpha\nbeta\n", None), ["alpha", "beta"]);
    }

    #[test]
    fn a_blank_line_inside_the_text_is_content() {
        assert_eq!(logical_lines("a\n\nb\n", None), ["a", "", "b"]);
    }

    #[test]
    fn an_unterminated_last_line_is_kept() {
        // The prompt, or an "awaiting input" cue. Losing this is the failure the fold exists to
        // avoid; including a half-written line costs a regex nothing.
        assert_eq!(logical_lines("done\n$ ", None), ["done", "$ "]);
    }

    #[test]
    fn the_limit_takes_the_tail() {
        assert_eq!(logical_lines("a\nb\nc\nd\n", Some(2)), ["c", "d"]);
        assert_eq!(logical_lines("a\nb\n", Some(9)), ["a", "b"]);
        assert_eq!(logical_lines("a\nb\n", Some(0)), ["a", "b"], "no limit at all");
    }

    #[test]
    fn empty_text_is_no_lines() {
        assert!(logical_lines("", None).is_empty());
        assert_eq!(logical_lines("\n", None), [""], "one empty line IS a line");
    }
}
