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
    found
        .into_iter()
        .filter(|hit| lines.get(hit.line).is_some_and(|line| stands_alone(line, hit)))
        .collect()
}

/// Every occurrence of `needle`, advancing ONE code unit past each hit's start rather than past its
/// end — so overlapping matches are all found (`aa` in `aaa` is two hits, not one).
fn literal_matches(lines: &[&str], needle: &str, case_sensitive: bool) -> Vec<Match> {
    let pattern = folded(needle, case_sensitive);
    if pattern.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let units = folded(line, case_sensitive);
        let Some(last_start) = units.len().checked_sub(pattern.len()) else {
            continue;
        };
        for start in 0..=last_start {
            if units.get(start..start.saturating_add(pattern.len())) == Some(pattern.as_slice()) {
                out.push(Match {
                    line: index,
                    column: start,
                    length: pattern.len(),
                });
            }
        }
    }
    out
}

/// `text` as UTF-16 units, case-folded per UNIT when the search is case-insensitive.
fn folded(text: &str, case_sensitive: bool) -> Vec<u16> {
    text.encode_utf16()
        .map(|unit| if case_sensitive { unit } else { fold(unit) })
        .collect()
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
fn fold(unit: u16) -> u16 {
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
        for hit in regex.find_iter(line) {
            if hit.is_empty() {
                continue;
            }
            let column = utf16_units(line.get(..hit.start()).unwrap_or(""));
            out.push(Match {
                line: index,
                column,
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

/// Whether `hit` stands on word boundaries within `line`.
///
/// The unit immediately before its start and immediately after its end must both be non-word — a
/// letter, digit or `_` on either side means the query landed inside a larger word. A lone
/// surrogate half reads as a separator, which is the behaviour wanted next to an emoji and never a
/// trap.
fn stands_alone(line: &str, hit: &Match) -> bool {
    let units: Vec<u16> = line.encode_utf16().collect();
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

    #[test]
    fn the_order_is_row_then_column() {
        let found = hits(&["x x", "x"], "x", false, false, false);
        let spans: Vec<(usize, usize)> = found.iter().map(|hit| (hit.line, hit.column)).collect();
        assert_eq!(spans, vec![(0, 0), (0, 2), (1, 0)]);
    }
}
