//! fzf's `FuzzyMatchV2` — Smith–Waterman local alignment with fzf's structural bonuses — over
//! Unicode scalars, returning the score AND the matched positions.
//!
//! ## Why the positions come back too
//! A scorer that answers only a number cannot underline what it matched, and every search field in
//! this app underlines something. Upstream fzf has the same two modes (`withPos`), and so does
//! this port: [`score`] backtraces, [`rank`] stops at phase 3 for the callers that only sort. The
//! number is the same either way — the backtrace only reads what the fill already decided.
//!
//! ## What is faithful, and what is simplified
//! Faithful: the DEFAULT scheme's constants, the char classification, the edge-triggered bonus
//! matrix, the two-phase DP and the backtrace's tie-breaking. Simplified (none of which changes a
//! score): the direction is always forward, the `int16` overflow guard / slab allocator /
//! `asciiFuzzyIndex` prefilter are dropped in favour of `i32` and a full scan window, and the
//! accent-folding `normalize` table is not carried.
//!
//! PORTED FROM: junegunn/fzf, `src/algo/algo.go` — `FuzzyMatchV2`, MIT License,
//! Copyright (c) 2013-2024 Junegunn Choi.

// The DP is a rectangle of scores addressed by arithmetic on (row, column), and every read is
// either in range by construction or deliberately reads the zero outside it (the Hleft/Hdiag
// sentinels of row 0). `at`/`put` below make that total: an index the rectangle does not hold
// reads 0 and writes nowhere, which is exactly what the algorithm means by "outside".

/// The default scheme's per-match score.
const SCORE_MATCH: i32 = 16;
/// The penalty for opening a gap between two matched characters.
const SCORE_GAP_START: i32 = -3;
/// The penalty for each further character of an open gap.
const SCORE_GAP_EXTENSION: i32 = -1;
/// A match at a word boundary — upstream spells it `scoreMatch / 2`.
const BONUS_BOUNDARY: i32 = 8;
/// A matched character that is not part of a word — upstream spells it `scoreMatch / 2`.
const BONUS_NON_WORD: i32 = 8;
/// A camelCase hump, or a digit after a non-digit.
const BONUS_CAMEL_123: i32 = BONUS_BOUNDARY + SCORE_GAP_EXTENSION;
/// The floor a character inside a consecutive run earns.
const BONUS_CONSECUTIVE: i32 = -(SCORE_GAP_START + SCORE_GAP_EXTENSION);
/// The first pattern character's bonus counts double — where a match STARTS is what ranks it.
const BONUS_FIRST_CHAR_MULTIPLIER: i32 = 2;
/// A match right after whitespace: the strongest boundary.
const BONUS_BOUNDARY_WHITE: i32 = BONUS_BOUNDARY + 2;
/// A match right after one of the delimiters.
const BONUS_BOUNDARY_DELIMITER: i32 = BONUS_BOUNDARY + 1;

/// The default scheme's delimiters — a match right after one earns [`BONUS_BOUNDARY_DELIMITER`].
const DELIMITERS: [char; 5] = ['/', ',', ':', ';', '|'];

/// A successful match: the fzf score (higher ranks first) and the matched positions, ascending,
/// as offsets into the candidate's Unicode scalars.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    /// The fzf score. Higher is a better match; it is only ever compared, never interpreted.
    pub score: i32,
    /// The matched scalar offsets into the candidate, ascending and without duplicates.
    pub positions: Vec<u32>,
}

/// fzf's `charClass` for the default scheme. The discriminants match `algo.go`'s ordering, which is
/// what makes the `class > charNonWord` gate in [`bonus_for`] a comparison rather than a set test.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum CharClass {
    White = 0,
    NonWord = 1,
    Delimiter = 2,
    Lower = 3,
    Upper = 4,
    Letter = 5,
    Number = 6,
}

/// Which class `ch` falls in, ASCII first because most candidates are paths and identifiers.
fn class_of(ch: char) -> CharClass {
    let v = ch as u32;
    if v <= 127 {
        return match ch {
            'a'..='z' => CharClass::Lower,
            'A'..='Z' => CharClass::Upper,
            '0'..='9' => CharClass::Number,
            ' ' | '\t'..='\r' => CharClass::White,
            _ if DELIMITERS.contains(&ch) => CharClass::Delimiter,
            _ => CharClass::NonWord,
        };
    }
    if ch.is_lowercase() {
        CharClass::Lower
    } else if ch.is_uppercase() {
        CharClass::Upper
    } else if ch.is_numeric() {
        CharClass::Number
    } else if ch.is_alphabetic() {
        CharClass::Letter
    } else if ch.is_whitespace() {
        // Covers NEL (U+0085) and NBSP (U+00A0), which are not ASCII whitespace.
        CharClass::White
    } else if DELIMITERS.contains(&ch) {
        CharClass::Delimiter
    } else {
        CharClass::NonWord
    }
}

/// Single-scalar lowercase, keeping a 1:1 scalar mapping so a matched position stays valid against
/// the ORIGINAL candidate. A full case folding that expanded one scalar into two would shift every
/// position after it and underline the wrong characters.
fn lower(ch: char) -> char {
    if ch.is_ascii() {
        return ch.to_ascii_lowercase();
    }
    ch.to_lowercase().next().unwrap_or(ch)
}

/// fzf's `bonusFor(prevClass, class)` — the edge-triggered structural bonus.
const fn bonus_for(prev: CharClass, cur: CharClass) -> i32 {
    // Upstream gates the word-boundary bonuses on `class > charNonWord` (STRICT): a non-word char
    // never enters this branch — it falls through to `bonusNonWord` (8) whatever preceded it. A
    // `>=` here would over-reward a non-word char after whitespace (10) or a delimiter (9), which
    // is a different ranking, not a rounder number.
    if (cur as u8) > (CharClass::NonWord as u8) {
        match prev {
            CharClass::White => return BONUS_BOUNDARY_WHITE,
            CharClass::Delimiter => return BONUS_BOUNDARY_DELIMITER,
            CharClass::NonWord => return BONUS_BOUNDARY,
            _ => {},
        }
    }
    if (matches!(prev, CharClass::Lower) && matches!(cur, CharClass::Upper))
        || (!matches!(prev, CharClass::Number) && matches!(cur, CharClass::Number))
    {
        return BONUS_CAMEL_123;
    }
    match cur {
        CharClass::NonWord | CharClass::Delimiter => BONUS_NON_WORD,
        CharClass::White => BONUS_BOUNDARY_WHITE,
        _ => 0,
    }
}

/// Reads the DP cell at `index`, answering 0 for anything the rectangle does not hold — the
/// algorithm's own sentinel for "outside".
fn at(cells: &[i32], index: isize) -> i32 {
    usize::try_from(index)
        .ok()
        .and_then(|i| cells.get(i))
        .copied()
        .unwrap_or(0)
}

/// Writes the DP cell at `index`, dropping a write the rectangle does not hold.
fn put(cells: &mut [i32], index: isize, value: i32) {
    if let Some(slot) = usize::try_from(index).ok().and_then(|i| cells.get_mut(i)) {
        *slot = value;
    }
}

/// Smart-case fuzzy match of `query` against `candidate`.
///
/// Case-sensitive exactly when the query carries an uppercase scalar — fzf's rule, and the reason
/// typing lowercase finds everything while typing a capital narrows.
///
/// An empty (or whitespace-only) query matches everything with score 0 and no positions: the
/// zero-state of a search field keeps the list in its source order rather than shuffling it.
/// `None` means the candidate does not contain the pattern in order at all.
#[must_use]
pub fn score(query: &str, candidate: &str) -> Option<Match> {
    run(query, candidate, true)
}

/// The same ranking, for a caller that will not underline anything.
///
/// Most callers are this one: a filtered list sorts by score and highlights only the rows it draws.
/// Skipping the backtrace skips phase 4 and the positions allocation — fzf's own `withPos == false`
/// path — and the score is bit-identical, because phase 4 only READS the matrices phase 3 filled.
#[must_use]
pub fn rank(query: &str, candidate: &str) -> Option<i32> {
    run(query, candidate, false).map(|found| found.score)
}

fn run(query: &str, candidate: &str, with_pos: bool) -> Option<Match> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    let case_sensitive = trimmed.chars().any(|c| matches!(class_of(c), CharClass::Upper));
    let pattern: Vec<char> = if case_sensitive {
        trimmed.chars().collect()
    } else {
        trimmed.chars().map(lower).collect()
    };
    let text: Vec<char> = candidate.chars().collect();
    matched(&pattern, &text, case_sensitive, with_pos)
}

/// The core matcher. `pattern` MUST be pre-lowercased when `case_sensitive` is false; the text is
/// folded internally. `None` when not every pattern scalar is matched, in order.
#[must_use]
pub fn match_pattern(pattern: &[char], input: &[char], case_sensitive: bool) -> Option<Match> {
    matched(pattern, input, case_sensitive, true)
}

fn matched(pattern: &[char], input: &[char], case_sensitive: bool, with_pos: bool) -> Option<Match> {
    let pattern_count = pattern.len();
    if pattern_count == 0 {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    if pattern_count > input.len() {
        return None;
    }
    let scan = row_zero(pattern, input, case_sensitive)?;
    if pattern_count == 1 {
        return Some(Match {
            score: scan.best,
            positions: if with_pos {
                vec![u32::try_from(scan.best_col).unwrap_or(u32::MAX)]
            } else {
                Vec::new()
            },
        });
    }
    Some(fill(pattern, &scan, with_pos))
}

/// What phase 2 leaves behind: the folded text, the row-0 scores, the position bonuses, and where
/// each pattern scalar first appears. `None` when the text does not carry every pattern scalar in
/// order — the cheap refusal that keeps the matrix from being built at all.
struct RowZero {
    /// The text, case-folded when the match is case-insensitive. Scalar-for-scalar the original.
    chars: Vec<char>,
    /// Row 0 of the score matrix: the best chunk score ending at each column.
    h0: Vec<i32>,
    /// Row 0 of the consecutive matrix: the run length ending at each column.
    c0: Vec<i32>,
    /// The edge-triggered position bonus at each column.
    bonuses: Vec<i32>,
    /// The first column each pattern scalar appears in — strictly increasing.
    first_occ: Vec<usize>,
    /// The last column any pattern scalar was seen at: the right edge of the scan window.
    last_idx: usize,
    /// The best row-0 score, which IS the answer when the pattern is one scalar long.
    best: i32,
    /// The column that best score sits in.
    best_col: usize,
}

fn row_zero(pattern: &[char], input: &[char], case_sensitive: bool) -> Option<RowZero> {
    let pattern_count = pattern.len();
    let text_count = input.len();
    let mut chars = input.to_vec();
    let mut h0 = vec![0_i32; text_count];
    let mut c0 = vec![0_i32; text_count];
    let mut bonuses = vec![0_i32; text_count];
    let mut first_occ = vec![0_usize; pattern_count];

    let mut best = 0;
    let mut best_col = 0;
    let mut matched_count = 0;
    let mut last_idx = 0;
    let &pchar0 = pattern.first()?;
    let mut pchar = pchar0;
    let mut prev_h0 = 0;
    let mut prev_class = CharClass::White; // fzf's `initialCharClass` for the default scheme
    let mut in_gap = false;

    for off in 0..text_count {
        let mut ch = at_char(&chars, off);
        let cls = class_of(ch);
        if !case_sensitive && matches!(cls, CharClass::Upper) {
            ch = lower(ch);
            if let Some(slot) = chars.get_mut(off) {
                *slot = ch;
            }
        }
        let position_bonus = bonus_for(prev_class, cls);
        put(&mut bonuses, offset(off), position_bonus);
        prev_class = cls;

        if ch == pchar {
            if matched_count < pattern_count {
                if let Some(slot) = first_occ.get_mut(matched_count) {
                    *slot = off;
                }
                matched_count += 1;
                pchar = pattern
                    .get(matched_count.min(pattern_count - 1))
                    .copied()
                    .unwrap_or(pchar);
            }
            last_idx = off;
        }

        if ch == pchar0 {
            let scored = SCORE_MATCH + position_bonus * BONUS_FIRST_CHAR_MULTIPLIER;
            put(&mut h0, offset(off), scored);
            put(&mut c0, offset(off), 1);
            if pattern_count == 1 && scored > best {
                best = scored;
                best_col = off;
                if position_bonus >= BONUS_BOUNDARY {
                    // A one-scalar pattern landing on a boundary cannot be beaten, so the scan
                    // stops — no column after it can score higher.
                    break;
                }
            }
            in_gap = false;
        } else {
            let carried = if in_gap {
                prev_h0 + SCORE_GAP_EXTENSION
            } else {
                prev_h0 + SCORE_GAP_START
            };
            put(&mut h0, offset(off), carried.max(0));
            put(&mut c0, offset(off), 0);
            in_gap = true;
        }
        prev_h0 = at(&h0, offset(off));
    }

    if matched_count != pattern_count {
        return None;
    }
    Some(RowZero {
        chars,
        h0,
        c0,
        bonuses,
        first_occ,
        last_idx,
        best,
        best_col,
    })
}

/// Phase 3 + 4 — fill the `(pattern_count × width)` score and consecutive matrices, then walk back
/// through them for the matched columns. Only reached for a pattern of two scalars or more; a
/// one-scalar pattern's answer is already row 0's best cell.
///
/// `with_pos == false` stops after phase 3. The walk only READS what phase 3 wrote, so the score is
/// the same either way — this is fzf's own split between `FuzzyMatchV2` with and without positions.
fn fill(pattern: &[char], scan: &RowZero, with_pos: bool) -> Match {
    let pattern_count = pattern.len();
    let f0 = scan.first_occ.first().copied().unwrap_or(0);
    let width = scan.last_idx + 1 - f0;
    let mut hmat = vec![0_i32; width * pattern_count];
    let mut cmat = vec![0_i32; width * pattern_count];
    for k in 0..width {
        put(&mut hmat, offset(k), at(&scan.h0, offset(f0 + k)));
        put(&mut cmat, offset(k), at(&scan.c0, offset(f0 + k)));
    }
    let mut best = scan.best;
    let mut best_col = scan.best_col;

    for row in 1..pattern_count {
        let f = scan.first_occ.get(row).copied().unwrap_or(0);
        // `first_occ` is strictly increasing, so `f > f0` for every row past the first, and this
        // base is therefore at least `width + 1` — the Hleft/Hdiag reads below stay in range.
        let base = offset(row * width + f - f0);
        let target = pattern.get(row).copied().unwrap_or('\u{0}');
        let mut row_gap = false;
        put(&mut hmat, base - 1, 0); // Hleft[0]
        for off in 0..=(scan.last_idx - f) {
            let col = f + off;
            let step = offset(off);
            let mut s1 = 0;
            let mut consecutive = 0;
            let s2 = at(&hmat, base - 1 + step)
                + if row_gap {
                    SCORE_GAP_EXTENSION
                } else {
                    SCORE_GAP_START
                };

            if target == at_char(&scan.chars, col) {
                let diag = base - 1 - offset(width) + step;
                s1 = at(&hmat, diag) + SCORE_MATCH;
                let mut b = at(&scan.bonuses, offset(col));
                consecutive = at(&cmat, diag) + 1;
                if consecutive > 1 {
                    let run_start = col + 1 - usize::try_from(consecutive).unwrap_or(1);
                    let first_bonus = at(&scan.bonuses, offset(run_start));
                    if b >= BONUS_BOUNDARY && b > first_bonus {
                        consecutive = 1; // the start of a STRONGER boundary chunk
                    } else {
                        b = b.max(BONUS_CONSECUTIVE.max(first_bonus));
                    }
                }
                if s1 + b < s2 {
                    s1 += at(&scan.bonuses, offset(col));
                    consecutive = 0;
                } else {
                    s1 += b;
                }
            }
            put(&mut cmat, base + step, consecutive);
            row_gap = s1 < s2;
            let scored = s1.max(s2.max(0));
            if row == pattern_count - 1 && scored > best {
                best = scored;
                best_col = col;
            }
            put(&mut hmat, base + step, scored);
        }
    }

    Match {
        score: best,
        positions: if with_pos {
            backtrace(&hmat, &cmat, width, &scan.first_occ, pattern_count, f0, best_col)
        } else {
            Vec::new()
        },
    }
}

/// The scalar at `index`, or a scalar that cannot appear in a pattern position it would match.
fn at_char(chars: &[char], index: usize) -> char {
    chars.get(index).copied().unwrap_or('\u{0}')
}

/// `usize` → the signed index space the DP addresses in, saturating rather than wrapping.
fn offset(index: usize) -> isize {
    isize::try_from(index).unwrap_or(isize::MAX)
}

/// Walk back from the best cell, preferring diagonal (match) moves, to recover the matched columns
/// ascending. Mirrors `algo.go`'s `withPos` backtrace, tie-break included.
fn backtrace(
    hmat: &[i32],
    cmat: &[i32],
    width: usize,
    first_occ: &[usize],
    pattern_count: usize,
    f0: usize,
    max_score_pos: usize,
) -> Vec<u32> {
    let mut positions = Vec::with_capacity(pattern_count);
    let mut row = pattern_count.saturating_sub(1);
    let mut col = offset(max_score_pos);
    let mut prefer_match = true;
    loop {
        let i_base = offset(row * width);
        let col_off = col - offset(f0);
        let s = at(hmat, i_base + col_off);
        let f = offset(first_occ.get(row).copied().unwrap_or(0));
        let mut s1 = 0;
        let mut s2 = 0;
        if row > 0 && col >= f {
            s1 = at(hmat, i_base - offset(width) + col_off - 1);
        }
        if col > f {
            s2 = at(hmat, i_base + col_off - 1);
        }
        if s > s1 && (s > s2 || (s == s2 && prefer_match)) {
            positions.push(u32::try_from(col).unwrap_or(u32::MAX));
            if row == 0 {
                break;
            }
            row -= 1;
        }
        let down_right = i_base + offset(width) + col_off + 1;
        prefer_match = at(cmat, i_base + col_off) > 1 || at(cmat, down_right) > 0;
        col -= 1;
        // The row-0 match above is what ends the walk; this is the floor that makes the loop
        // total if a hand-built matrix ever disagreed with the phase that produced it.
        if col < 0 {
            break;
        }
    }
    positions.reverse();
    positions
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a candidate a test asserts positions for has nothing to assert if it did not match"
    )]

    use super::*;

    fn s(query: &str, candidate: &str) -> Option<i32> {
        score(query, candidate).map(|m| m.score)
    }

    // The single-character score is `SCORE_MATCH + positionBonus * BONUS_FIRST_CHAR_MULTIPLIER`,
    // so these read the position bonus table straight off the answer.

    #[test]
    fn the_first_character_is_worth_where_it_sits() {
        assert_eq!(s("a", "a"), Some(36)); // start of string ⇒ boundary-white 10
        assert_eq!(s("a", " a"), Some(36)); // after whitespace ⇒ boundary-white 10
        assert_eq!(s("a", "/a"), Some(34)); // after a delimiter ⇒ boundary-delimiter 9
        assert_eq!(s("a", "-a"), Some(32)); // after a non-word char ⇒ boundary 8
        assert_eq!(s("a", "ba"), Some(16)); // mid-word ⇒ no bonus
    }

    #[test]
    fn a_non_word_character_is_never_a_word_boundary() {
        // Whatever precedes it, a matched non-word char earns `BONUS_NON_WORD` (8) — never the
        // after-whitespace (10) or after-delimiter (9) bonuses. A `>=` gate would give it those.
        assert_eq!(s("-", " -"), Some(32));
        assert_eq!(s("-", ":-"), Some(32));
        assert_eq!(s("-", "a-"), Some(32));
        assert_eq!(s("-", "-"), Some(32));
    }

    #[test]
    fn a_consecutive_chunk_carries_its_first_characters_bonus() {
        // 'a' at the start scores 16 + 10*2 = 36; the consecutive 'b' adds 16 plus the chunk's
        // carried-forward boundary bonus 10.
        assert_eq!(s("ab", "ab"), Some(62));
    }

    #[test]
    fn the_matched_positions_are_the_leftmost_optimal_ones() {
        let m = score("fz", "fuzzy").expect("fz matches fuzzy");
        assert_eq!(m.score, 49);
        assert_eq!(m.positions, vec![0, 2]);
    }

    #[test]
    fn the_positions_index_the_original_candidate_not_the_folded_one() {
        let candidate = "FuzzyMatcher";
        let m = score("fm", candidate).expect("fm matches FuzzyMatcher");
        let matched: String = m
            .positions
            .iter()
            .filter_map(|&p| candidate.chars().nth(p as usize))
            .collect();
        assert_eq!(matched, "FM"); // F@0 (boundary) + M@5 (camelCase hump)
    }

    // The ordering properties are lifted from `algo.go`'s own doc comment: they ARE the spec, and
    // a prefix/contains ladder ties every one of them.

    #[test]
    fn a_word_boundary_outranks_a_packed_run() {
        assert!(s("ff", "fuzzy-finder") > s("ff", "fuzzyfinder"));
    }

    #[test]
    fn a_consecutive_chunk_outranks_a_boundary_gap() {
        assert!(s("foob", "foobar") > s("foob", "foo-bar"));
    }

    #[test]
    fn the_first_character_at_a_boundary_outranks_one_inside_a_word() {
        assert!(s("br", "fo-bar") > s("br", "foob-r"));
    }

    #[test]
    fn a_camel_hump_outranks_a_distant_mid_word_match() {
        assert!(s("gc", "getConfig") > s("gc", "gymnastic"));
    }

    #[test]
    fn order_matters_and_an_omission_is_not_a_match() {
        assert_eq!(s("xyz", "getConfig"), None);
        assert_eq!(s("zx", "xyz"), None); // out of order
        assert_eq!(s("abc", "ab"), None); // pattern longer than the candidate
        assert!(s("xz", "xyz").is_some()); // in order, with a gap
    }

    #[test]
    fn the_case_of_the_query_is_what_decides_case_sensitivity() {
        assert!(s("gc", "getConfig").is_some());
        assert_eq!(s("GC", "getConfig"), None);
        assert!(s("GC", "GetConfig").is_some());
    }

    #[test]
    fn an_empty_query_matches_everything_without_re_ordering_it() {
        let m = score("", "anything").expect("an empty query is a match");
        assert_eq!(m.score, 0);
        assert!(m.positions.is_empty());
        assert_eq!(s("   ", "anything"), Some(0));
    }

    #[test]
    fn a_scalar_outside_ascii_neither_crashes_nor_shifts_a_position() {
        // The candidate's scalars are what positions index — a two-byte scalar is ONE position.
        let m = score("é", "café").expect("é matches café");
        assert_eq!(m.positions, vec![3]);
        // Folding stays 1:1, so an uppercase non-ASCII scalar matches its lowercase form in place.
        let folded = score("é", "CAFÉ").expect("é matches CAFÉ case-insensitively");
        assert_eq!(folded.positions, vec![3]);
    }

    /// The whole point of the score-only path: it must never re-rank anything. One assertion per
    /// candidate shape the DP takes — a one-scalar pattern (row 0 only), a multi-row fill, a
    /// consecutive run, a boundary win, a refusal and the empty query.
    #[test]
    fn skipping_the_backtrace_never_changes_the_score() {
        for (query, candidate) in [
            ("f", "FuzzyMatcher"),
            ("fm", "FuzzyMatcher"),
            ("fz", "fuzzy"),
            ("ab", "ab"),
            ("ff", "fuzzy-finder"),
            ("ff", "fuzzyfinder"),
            ("gc", "getConfig"),
            ("gc", "git commit"),
            ("src", "Sources/SlopDeskClientUI/Palette/FuzzyMatcher.swift"),
            ("xyz", "getConfig"),
            ("", "anything"),
            ("é", "CAFÉ"),
        ] {
            assert_eq!(
                rank(query, candidate),
                s(query, candidate),
                "{query:?} against {candidate:?}"
            );
        }
    }

    #[test]
    fn a_pattern_the_text_cannot_hold_is_refused_before_the_matrix_is_built() {
        assert_eq!(match_pattern(&['a', 'b'], &['a'], false), None);
        assert_eq!(
            match_pattern(&[], &['a'], false),
            Some(Match {
                score: 0,
                positions: Vec::new()
            })
        );
    }
}
