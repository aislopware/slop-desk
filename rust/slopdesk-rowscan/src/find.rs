//! Find-in-terminal: every occurrence of what the user typed, across a buffer of rows.
//!
//! Three matching modes that compose: literal or regex, case-sensitive or not, and a whole-word
//! post-filter over either. The answer is ordered top-to-bottom then left-to-right, the way the eye
//! reads a screen, which is the order ⌘F's next/previous walks.
//!
//! ## Columns are UTF-16 code units
//!
//! Not bytes and not scalars. The caller highlights a match by handing the column straight to a
//! surface that indexes in UTF-16, so an offset in any other unit would have to be converted on the
//! way out — by a second walk over the same line, in the caller, per match. Counting them here is
//! one pass over a prefix the scan already has in hand.
//!
//! ## Why the regex is not `NSRegularExpression`'s
//!
//! Because a ⌘F pattern is retyped on every keystroke and re-run over the whole scrollback. A
//! backtracking engine turns one pathological pattern into a frozen find bar; this one is linear in
//! the line. The cost is the dialect: no lookaround, no backreferences. A pattern using either
//! fails to compile and yields no matches, which is the same validate-then-drop an unfinished
//! pattern already had — the user is mid-typing `(foo` for most of the keystrokes anyway.

use regex::{Regex, RegexBuilder};

/// One found occurrence: the row, and the UTF-16 column range within it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    /// Index into the rows that were searched.
    pub line: usize,
    /// First UTF-16 code unit of the match within its row.
    pub column: usize,
    /// How many UTF-16 code units the match spans. Never `0` — an empty match is not a hit.
    pub length: usize,
}

/// Every match of `query` in `lines`, ordered by row then column.
///
/// An empty query, or a regex that does not compile, answers nothing rather than failing: both are
/// states a find field passes through on the way to a real pattern.
#[must_use]
pub fn matches(
    lines: &[&str],
    query: &str,
    case_sensitive: bool,
    is_regex: bool,
    whole_word: bool,
) -> Vec<Match> {
    if query.is_empty() {
        return Vec::new();
    }
    let found = if is_regex {
        regex_matches(lines, query, case_sensitive)
    } else {
        literal_matches(lines, query, case_sensitive)
    };
    if !whole_word {
        return found;
    }
    // One encoding per LINE, not one per hit. `found` is already ordered by line, so carrying the
    // last row's units forward turns what was `hits × line` work into `rows × line`: a whole-word
    // search for `the` over a scrollback that says it ten thousand times used to re-encode ten
    // thousand rows to look at two code units either side of each hit.
    let mut units: Vec<u16> = Vec::new();
    let mut encoded: Option<usize> = None;
    found
        .into_iter()
        .filter(|hit| {
            let Some(line) = lines.get(hit.line) else {
                return false;
            };
            if encoded != Some(hit.line) {
                units.clear();
                units.extend(line.encode_utf16());
                encoded = Some(hit.line);
            }
            stands_alone(&units, hit)
        })
        .collect()
}

/// Every occurrence of `needle`, advancing ONE code unit past each hit's start rather than past its
/// end — so overlapping matches are all found (`aa` in `aaa` is two hits, not one).
///
/// ## Why it skips to the first unit rather than comparing at every offset
///
/// A ⌘F scan runs over the WHOLE scrollback on every keystroke, and the shipped scrollback is tens
/// of thousands of rows: comparing the pattern at every one of ~750 000 offsets is the difference
/// between a find bar that keeps up with typing and one that does not. Scanning for the pattern's
/// first unit and only then comparing the rest is the same answer — the loop still advances one
/// unit past each hit's START, so overlapping matches are still all found — reached without
/// touching the offsets that cannot begin a match. Measured over a 10 000-row / 736 KB scrollback,
/// case-insensitive, together with the folding and buffer changes below, against this module at the
/// commit before them and linked into the same binary so both sides run the same `regex` build:
/// 6.3 ms per keystroke before, 1.2 ms after. Case-sensitive, 3.7 ms before and 0.92 ms after; with
/// the whole-word filter on, 8.2 ms and 2.0 ms.
fn literal_matches(lines: &[&str], needle: &str, case_sensitive: bool) -> Vec<Match> {
    let mut pattern = Vec::new();
    fold_into(needle, case_sensitive, &mut pattern);
    let Some((&first, rest)) = pattern.split_first() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    // One buffer for every row rather than one per row: a fresh `Vec<u16>` per line was an
    // allocation and a free per row per keystroke, and the rows are all about the same width.
    let mut units: Vec<u16> = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        fold_into(line, case_sensitive, &mut units);
        let Some(last_start) = units.len().checked_sub(pattern.len()) else {
            continue;
        };
        let mut start = 0_usize;
        while let Some(window) = units.get(start..=last_start) {
            let Some(offset) = window.iter().position(|unit| *unit == first) else {
                break;
            };
            let at = start.saturating_add(offset);
            if units.get(at.saturating_add(1)..at.saturating_add(pattern.len())) == Some(rest) {
                out.push(Match {
                    line: index,
                    column: at,
                    length: pattern.len(),
                });
            }
            start = at.saturating_add(1);
        }
    }
    out
}

/// Fills `out` with `text` as UTF-16 units, case-folded per UNIT when the search is
/// case-insensitive. Takes the buffer rather than returning one so a scan over a scrollback
/// allocates once instead of once per row.
fn fold_into(text: &str, case_sensitive: bool, out: &mut Vec<u16>) {
    out.clear();
    if case_sensitive {
        out.extend(text.encode_utf16());
    } else {
        out.extend(text.encode_utf16().map(fold));
    }
}

/// Simple, LENGTH-PRESERVING case folding of one UTF-16 unit.
///
/// Per unit rather than per string, on purpose: `str::to_lowercase` is the full Unicode mapping,
/// and the full mapping can change a string's length — `İ` lowercases to two scalars. A column into
/// a folded string of a different length is not a column into the line the caller will highlight,
/// so the whole answer would be off by however many units the fold added above it.
///
/// A unit whose lowercase is not a single BMP scalar is left alone. That is also what makes a
/// surrogate half — half of an emoji — pass through untouched instead of becoming a replacement
/// character. The pairs it therefore fails to equate (`ß`/`SS` and friends) are ones nobody types
/// into a find bar expecting the other.
///
/// The ASCII arm is not a second rule, it is the general one's answer reached without building a
/// `ToLowercase` iterator: every ASCII scalar lowercases to exactly one ASCII scalar, which is what
/// `to_ascii_lowercase` returns. It is here because it is the arm that actually runs — a scrollback
/// is compiler output — and it was costing a table walk per code unit of every row, per keystroke.
fn fold(unit: u16) -> u16 {
    if let Ok(byte) = u8::try_from(unit)
        && byte.is_ascii()
    {
        return u16::from(byte.to_ascii_lowercase());
    }
    let Some(scalar) = char::from_u32(u32::from(unit)) else {
        return unit;
    };
    let mut lowered = scalar.to_lowercase();
    match (lowered.next(), lowered.next()) {
        (Some(single), None) => u16::try_from(u32::from(single)).unwrap_or(unit),
        _ => unit,
    }
}

/// Every regex match per row. A zero-width match is not a hit — a caret with no width is nothing to
/// highlight and nothing to navigate to.
fn regex_matches(lines: &[&str], pattern: &str, case_sensitive: bool) -> Vec<Match> {
    let Ok(regex) = compile(pattern, case_sensitive) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        // `find_iter` yields non-overlapping hits in increasing start order, so the column of each
        // is the previous column plus the units BETWEEN them — counted once. Measuring it from the
        // start of the line per hit made a row that matches n times cost n walks over its prefix,
        // which is quadratic in the row. A terminal reaches that shape whenever a program prints
        // one long unwrapped line — a JSON blob, a `PATH`, a stack trace. Measured on a single
        // 160 KB row with 20 000 hits: 782 ms per keystroke before, 1.9 ms after. Three quarters of
        // a second on the main thread, per character typed into the find bar.
        let mut counted_bytes = 0_usize;
        let mut counted_units = 0_usize;
        for hit in regex.find_iter(line) {
            if hit.is_empty() {
                continue;
            }
            counted_units =
                counted_units.saturating_add(utf16_units(line.get(counted_bytes..hit.start()).unwrap_or("")));
            counted_bytes = hit.start();
            out.push(Match {
                line: index,
                column: counted_units,
                length: utf16_units(hit.as_str()),
            });
        }
    }
    out
}

/// Compiles `pattern`, case-folding when asked.
fn compile(pattern: &str, case_sensitive: bool) -> Result<Regex, regex::Error> {
    RegexBuilder::new(pattern)
        .case_insensitive(!case_sensitive)
        .build()
}

/// How many UTF-16 code units `text` occupies.
fn utf16_units(text: &str) -> usize {
    text.encode_utf16().count()
}

/// Whether `hit` stands on word boundaries within its row, given that row's UTF-16 units.
///
/// The unit immediately before its start and immediately after its end must both be non-word — a
/// letter, digit or `_` on either side means the query landed inside a larger word. A lone
/// surrogate half reads as a separator, which is the behaviour wanted next to an emoji and never a
/// trap.
///
/// Takes the units rather than the row because the caller holds them across every hit on that row;
/// encoding here meant re-encoding the whole line once per hit.
fn stands_alone(units: &[u16], hit: &Match) -> bool {
    let end = hit.column.saturating_add(hit.length);
    if end > units.len() {
        return false;
    }
    let before = hit.column.checked_sub(1).and_then(|at| units.get(at).copied());
    let after = units.get(end).copied();
    !before.is_some_and(is_word_unit) && !after.is_some_and(is_word_unit)
}

/// A `\w`-sense UTF-16 code unit: a Unicode letter or digit, or `_`.
fn is_word_unit(unit: u16) -> bool {
    char::from_u32(u32::from(unit)).is_some_and(|scalar| scalar.is_alphanumeric() || scalar == '_')
}

#[cfg(test)]
mod tests {
    use super::{Match, matches};

    fn hits(
        lines: &[&str],
        query: &str,
        case_sensitive: bool,
        is_regex: bool,
        whole_word: bool,
    ) -> Vec<Match> {
        matches(lines, query, case_sensitive, is_regex, whole_word)
    }

    #[test]
    fn an_empty_query_finds_nothing_rather_than_everything() {
        assert!(hits(&["anything"], "", false, false, false).is_empty());
        assert!(hits(&["anything"], "", false, true, false).is_empty());
    }

    #[test]
    fn overlapping_literal_hits_are_all_found() {
        let found = hits(&["aaa"], "aa", true, false, false);
        assert_eq!(found.len(), 2, "advancing one unit past the START, not the end");
        assert_eq!(found.first().map(|hit| hit.column), Some(0));
        assert_eq!(found.get(1).map(|hit| hit.column), Some(1));
    }

    #[test]
    fn case_folding_is_a_mode_and_not_a_default() {
        assert_eq!(hits(&["Error and error"], "error", false, false, false).len(), 2);
        assert_eq!(hits(&["Error and error"], "error", true, false, false).len(), 1);
    }

    #[test]
    fn the_whole_word_filter_composes_with_either_mode() {
        assert_eq!(hits(&["the theory of the"], "the", false, false, false).len(), 3);
        assert_eq!(hits(&["the theory of the"], "the", false, false, true).len(), 2);
        assert_eq!(hits(&["the theory of the"], "th.", false, true, true).len(), 2);
    }

    #[test]
    fn an_invalid_pattern_yields_nothing_and_never_traps() {
        assert!(hits(&["([unclosed"], "([unclosed", false, true, false).is_empty());
        // The literal reading of the same text still finds it — the modes are independent.
        assert_eq!(hits(&["([unclosed"], "([unclosed", false, false, false).len(), 1);
    }

    #[test]
    fn a_zero_width_match_is_not_a_hit() {
        assert!(hits(&["abc"], "x*", false, true, false).is_empty());
    }

    #[test]
    fn the_columns_are_utf16_units_so_the_surface_can_index_them() {
        // An emoji outside the BMP is TWO UTF-16 units, so the match after it starts at column 2.
        let found = hits(&["\u{1F600}ab"], "ab", false, false, false);
        assert_eq!(found.first().map(|hit| (hit.column, hit.length)), Some((2, 2)));
        let found = hits(&["\u{1F600}ab"], "ab", false, true, false);
        assert_eq!(found.first().map(|hit| (hit.column, hit.length)), Some((2, 2)));
    }

    /// The regex path counts each column from the PREVIOUS hit rather than from the start of the
    /// row, so a row with several hits and a surrogate pair before, between and after them is the
    /// arm that would catch a carried cursor drifting.
    #[test]
    fn regex_columns_stay_absolute_across_several_hits_on_one_row() {
        let row = "\u{1F600}ab\u{1F600}ab\u{1F600}ab";
        let columns: Vec<usize> = hits(&[row], "ab", false, true, false)
            .iter()
            .map(|hit| hit.column)
            .collect();
        assert_eq!(
            columns,
            vec![2, 6, 10],
            "each column is measured from the row, not the last hit"
        );
        // The literal path walks the same row independently and must agree unit for unit.
        let literal: Vec<usize> = hits(&[row], "ab", false, false, false)
            .iter()
            .map(|hit| hit.column)
            .collect();
        assert_eq!(
            columns, literal,
            "the two matchers index the same row the same way"
        );
    }

    /// The whole-word filter now reads units the caller encoded once per ROW rather than once per
    /// hit, so a row carrying many hits is the arm that would catch a stale carried buffer — and a
    /// row that follows one, since the cache is keyed on the line index.
    #[test]
    fn the_whole_word_filter_reads_the_right_row_when_hits_repeat() {
        let found = hits(&["the the then the", "then", "the"], "the", false, false, true);
        let spans: Vec<(usize, usize)> = found.iter().map(|hit| (hit.line, hit.column)).collect();
        assert_eq!(
            spans,
            vec![(0, 0), (0, 4), (0, 13), (2, 0)],
            "`then` is never a whole word"
        );
    }

    /// ASCII folds through the fast arm and non-ASCII through the general one; a query that spans
    /// both must still equate the same pairs either way.
    #[test]
    fn the_ascii_fold_agrees_with_the_general_one() {
        assert_eq!(
            hits(&["Ünicode ünicode"], "ünicode", false, false, false).len(),
            2
        );
        assert_eq!(
            hits(&["Ünicode ünicode"], "ÜNICODE", false, false, false).len(),
            2
        );
        assert_eq!(hits(&["Ünicode ünicode"], "ünicode", true, false, false).len(), 1);
        // `_` is ASCII and not a letter: the fast arm must leave it exactly as it found it.
        assert_eq!(hits(&["A_B a_b"], "a_b", false, false, false).len(), 2);
        assert_eq!(hits(&["A_B a_b"], "a_b", true, false, false).len(), 1);
    }

    #[test]
    fn the_order_is_row_then_column() {
        let found = hits(&["x x", "x"], "x", false, false, false);
        let spans: Vec<(usize, usize)> = found.iter().map(|hit| (hit.line, hit.column)).collect();
        assert_eq!(spans, vec![(0, 0), (0, 2), (1, 0)]);
    }
}
