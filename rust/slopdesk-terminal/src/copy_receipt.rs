//! What just landed on the clipboard, and the one sentence that says so.
//!
//! A copy is the highest-frequency INVISIBLE action in a terminal, so the transient confirmation
//! has to answer the one real doubt — "did I get the whole thing?" — in a glance. Which number
//! answers it depends on the shape of the grab: a multi-line selection may extend past the
//! viewport, so its doubt is about LINES; a single-line grab is fully visible, so its doubt is
//! about truncation, which is CHARACTERS. Hence the ladder in [`detail`]: never "1 line", always
//! the more informative number.
//!
//! Counting and wording live together because they are one answer. Two chips draw this — the pane's
//! and the window's — and a receipt whose count came from here while its sentence came from a view
//! would be the two-renderer split the rail's git line already paid for once.

use unicode_segmentation::UnicodeSegmentation;

/// The two figures a receipt carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Counts {
    /// Grapheme-CLUSTER count — what a user would call "characters", and what Swift's
    /// `String.count` answers, which is the number the label used to print.
    pub chars: usize,
    /// Logical lines: newline-separated segments, with a SINGLE trailing newline not counted as an
    /// extra empty one.
    pub lines: usize,
}

/// Counts what was copied.
///
/// The trailing-newline rule is the whole subtlety: a shell line copy arrives as `"foo\n"`, and
/// calling that two lines would report a phantom empty one on the most ordinary copy there is. Only
/// ONE trailing newline is absorbed — `"a\n\n"` really does end with a blank line, and a receipt
/// that hid it would be describing a different clipboard.
#[must_use]
pub fn counts(text: &str) -> Counts {
    let chars = text.graphemes(true).count();
    let mut segments: Vec<&str> = text.split('\n').collect();
    if segments.len() > 1 && segments.last().is_some_and(|last| last.is_empty()) {
        segments.pop();
    }
    Counts {
        chars,
        lines: segments.len(),
    }
}

/// The count half of the label: `"18 lines"` for a multi-line grab, `"1,204 characters"` /
/// `"1 character"` for a single line.
#[must_use]
pub fn detail(counts: Counts) -> String {
    if counts.lines > 1 {
        return format!("{} lines", grouped(counts.lines));
    }
    let noun = if counts.chars == 1 {
        "character"
    } else {
        "characters"
    };
    format!("{} {noun}", grouped(counts.chars))
}

/// The full sentence — `"Copied · 1,204 characters"`.
///
/// ⚠️ SENTENCE CASE, and the words are spelled out. Both went with the surface: the receipt moved
/// off the glass onto the floating family's paper capsule, whose voice is the system's neutral
/// semantics in sentence case, so the instrument caps register stayed with the glass it belonged
/// to. "CHARS" was an abbreviation that register needed to stay narrow; a proportional face at
/// reading size does not, and "characters" is what the number actually counts.
#[must_use]
pub fn label(counts: Counts) -> String {
    format!("Copied · {}", detail(counts))
}

/// Deterministic thousands grouping (`1204` → `"1,204"`).
///
/// Written out rather than taken from a locale formatter on purpose: the instrument voice must read
/// identically on every machine, and the label's pins must not drift with a system setting nobody
/// changed for this app's benefit.
#[must_use]
pub fn grouped(value: usize) -> String {
    let digits = value.to_string();
    let len = digits.len();
    let mut out = String::with_capacity(len + len.div_euclid(3));
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (len - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{Counts, counts, detail, grouped, label};

    #[test]
    fn a_shell_line_copy_is_one_line_and_its_trailing_newline_is_not_a_second() {
        assert_eq!(counts("foo\n"), Counts { chars: 4, lines: 1 });
        assert_eq!(counts("foo"), Counts { chars: 3, lines: 1 });
        assert_eq!(counts(""), Counts { chars: 0, lines: 1 });
    }

    /// Only one trailing newline is absorbed — the clipboard really does end with a blank line
    /// here, and a receipt that hid it would describe a different clipboard.
    #[test]
    fn a_second_trailing_newline_is_a_real_blank_line() {
        assert_eq!(counts("a\n\n").lines, 2);
        assert_eq!(counts("\n").lines, 1);
        assert_eq!(counts("a\nb\nc").lines, 3);
    }

    /// The chars figure is what Swift's `String.count` answers — grapheme CLUSTERS — because that
    /// is the number the label printed before it crossed, and a family emoji is one character
    /// to the person who selected it.
    #[test]
    fn characters_are_clusters_and_never_scalars_or_bytes() {
        assert_eq!(counts("é").chars, 1, "precomposed");
        assert_eq!(
            counts("e\u{301}").chars,
            1,
            "decomposed — one cluster, two scalars"
        );
        assert_eq!(
            counts("👨‍👩‍👧‍👦").chars,
            1,
            "one family, four scalars and three joiners"
        );
    }

    #[test]
    fn a_single_line_grab_speaks_characters_and_never_says_one_line() {
        assert_eq!(detail(counts("hello")), "5 characters");
        assert_eq!(detail(counts("x")), "1 character");
        assert_eq!(detail(counts("")), "0 characters");
    }

    #[test]
    fn a_multi_line_grab_speaks_lines() {
        assert_eq!(detail(counts("a\nb")), "2 lines");
        assert_eq!(label(counts("a\nb")), "Copied · 2 lines");
    }

    #[test]
    fn the_grouping_is_the_apps_own_and_not_the_machines() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1_000), "1,000");
        assert_eq!(grouped(1_204), "1,204");
        assert_eq!(grouped(12_345), "12,345");
        assert_eq!(grouped(1_234_567), "1,234,567");
    }
}
