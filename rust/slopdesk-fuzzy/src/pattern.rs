//! fzf's EXTENDED-SEARCH syntax — `'exact`, `^prefix`, `suffix$`, `!negate`, `|` — over the scorer
//! the rest of this crate already is.
//!
//! ## What it buys
//!
//! The one thing a fuzzy search field cannot express is *precision*. `gc` finds `git commit` and
//! twelve other things, and the only way out is to type more of the answer than you know. fzf's
//! answer is a query LANGUAGE: space-separated terms are `AND`ed, `|` `OR`s them, a leading `'`
//! demands a substring, `^`/`$` anchor, `!` excludes. `git !push ^g` reads exactly as it sounds.
//!
//! It belongs to the SEARCH field and nowhere else. A Tab completion's query is real shell text
//! where `^`, `$`, `!` and `|` are legal characters with other meanings, so
//! [`crate::score`] stays the plain scorer and the syntax is opt-in at the caller.
//!
//! ## What is faithful, and what is simplified
//!
//! Faithful: `parseTerms`' whole precedence, including the parts that only read right in the source
//! — `$` alone is not a suffix marker, `'` FLIPS exactness rather than setting it, `^…$` is an
//! equality rather than a prefix, and a `|` only joins when a term already stands to its left.
//! Faithful too: the four non-fuzzy matchers and `calculateScore`, which is what makes `'git` and
//! `git` land on the same scale so a `|` between them ranks.
//!
//! Simplified, exactly as [`crate`] already is: no `--normalize` accent folding, no `nth` field
//! transformation, and the direction is always forward (fzf's `--tac` reverses the SCAN, not the
//! meaning). `--exact` mode is not carried either: this port is always the fuzzy-by-default one,
//! which is the only mode a terminal search field offers.
//!
//! PORTED FROM: junegunn/fzf, `src/pattern.go` (`parseTerms`, `extendedMatch`) and
//! `src/algo/algo.go` (`exactMatchNaive`, `PrefixMatch`, `SuffixMatch`, `EqualMatch`,
//! `calculateScore`), MIT License, Copyright (c) 2013-2024 Junegunn Choi.

use crate::{
    BONUS_BOUNDARY, BONUS_BOUNDARY_WHITE, BONUS_CONSECUTIVE, BONUS_FIRST_CHAR_MULTIPLIER, CharClass,
    MAX_CANDIDATE_SCALARS, MAX_PATTERN_SCALARS, Match, SCORE_GAP_EXTENSION, SCORE_GAP_START, SCORE_MATCH,
    bonus_for, class_of, fits, lower, matched,
};

/// What one term demands of a candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TermKind {
    /// The default: the term's scalars in order, anywhere — [`crate::score`]'s matcher.
    Fuzzy,
    /// `'term` — the scalars CONTIGUOUS, anywhere.
    Exact,
    /// `'term'` — contiguous AND at both ends of a word.
    ExactBoundary,
    /// `^term` — contiguous at the start.
    Prefix,
    /// `term$` — contiguous at the end.
    Suffix,
    /// `^term$` — the whole candidate, and nothing else.
    Equal,
}

/// One word of the query, with the meaning its sigils gave it.
#[derive(Debug, Clone)]
struct Term {
    kind: TermKind,
    /// `!term` — the candidate matches when this term does NOT.
    inverse: bool,
    /// Pre-lowercased when `case_sensitive` is false, so a matcher never folds the needle.
    text: Vec<char>,
    /// Smart case, decided PER TERM: `git Commit` is case-insensitive in its first word and
    /// case-sensitive in its second, which is what makes the rule usable mid-query.
    case_sensitive: bool,
}

/// A parsed extended-search query: sets of terms, `AND`ed, each set `OR`ed within itself.
///
/// Parsed once and matched against many candidates — the split fzf makes for the same reason, since
/// a ⌃R keystroke re-ranks the whole history and re-parsing per candidate would be the work done
/// thousands of times over.
#[derive(Debug, Clone, Default)]
pub struct Pattern {
    sets: Vec<Vec<Term>>,
}

impl Pattern {
    /// Parses one query.
    ///
    /// Never fails: every string is a valid query, because a sigil that names nothing is just text.
    /// `''` and `!` alone parse to no terms at all, which [`Self::is_empty`] reports and which
    /// match everything — the zero-state a search field opens in.
    #[must_use]
    pub fn parse(query: &str) -> Self {
        Self {
            sets: parse_terms(query),
        }
    }

    /// Whether the query demands nothing, so every candidate matches with score 0.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.sets.is_empty()
    }

    /// Matches `candidate`, answering the summed score and the positions to underline.
    #[must_use]
    pub fn score(&self, candidate: &str) -> Option<Match> {
        self.run(candidate, true)
    }

    /// The same verdict for a caller that will not underline anything.
    #[must_use]
    pub fn rank(&self, candidate: &str) -> Option<i32> {
        self.run(candidate, false).map(|found| found.score)
    }

    /// fzf's `extendedMatch` plus `MatchItem`'s `len(offsets) == len(termSets)` test, which is the
    /// AND: a set that matched nothing contributes no offset, and one missing offset fails the
    /// whole pattern.
    fn run(&self, candidate: &str, with_pos: bool) -> Option<Match> {
        if self.is_empty() {
            return Some(Match {
                score: 0,
                positions: Vec::new(),
            });
        }
        // The same refusal as [`crate::score`]'s, and for the same reason: the collect below is
        // the first allocation the candidate's length would size, and the exact matchers walk a
        // `candidate × term` rectangle just as the fuzzy one does.
        if !fits(candidate, MAX_CANDIDATE_SCALARS)
            || self
                .sets
                .iter()
                .flatten()
                .any(|term| term.text.len() > MAX_PATTERN_SCALARS)
        {
            return None;
        }
        let text: Vec<char> = candidate.chars().collect();
        let mut score = 0;
        let mut positions: Vec<u32> = Vec::new();
        for set in &self.sets {
            let mut satisfied = false;
            for term in set {
                match term.apply(&text, with_pos) {
                    // A matched NEGATION is not this set's answer, but it is not a failure either —
                    // the rest of the set still gets its turn. (Upstream's `continue`.)
                    Some(_) if term.inverse => {},
                    Some(found) => {
                        score += found.score;
                        if with_pos {
                            positions.extend(found.positions);
                        }
                        satisfied = true;
                        break;
                    },
                    // An unmatched negation is exactly what it asked for: the set is satisfied, and
                    // it scores NOTHING, so `!x` never orders the results it merely filters.
                    None if term.inverse => satisfied = true,
                    None => {},
                }
            }
            if !satisfied {
                return None;
            }
        }
        // Terms match in query order, not in candidate order, so `git ^c` collects positions out of
        // order — and the underline reads them as a sorted run.
        positions.sort_unstable();
        positions.dedup();
        Some(Match { score, positions })
    }
}

impl Term {
    fn apply(&self, text: &[char], with_pos: bool) -> Option<Match> {
        match self.kind {
            TermKind::Fuzzy => matched(&self.text, text, self.case_sensitive, with_pos),
            TermKind::Exact => exact_match(text, &self.text, self.case_sensitive, false, with_pos),
            TermKind::ExactBoundary => exact_match(text, &self.text, self.case_sensitive, true, with_pos),
            TermKind::Prefix => prefix_match(text, &self.text, self.case_sensitive, with_pos),
            TermKind::Suffix => suffix_match(text, &self.text, self.case_sensitive, with_pos),
            TermKind::Equal => equal_match(text, &self.text, self.case_sensitive, with_pos),
        }
    }
}

/// fzf's `parseTerms`, with `fuzzy = true`, `CaseSmart` and `normalize = false`.
///
/// The order of the tests is the grammar, and it is not the order the sigils are written in: `!`
/// is stripped before `$`, `$` before `'`, and `^` last, which is why `!^a$` is a negated EQUALITY
/// rather than four separate readings.
fn parse_terms(query: &str) -> Vec<Vec<Term>> {
    // A backslash-escaped space is part of ONE term. Standing in a tab for it makes the split a
    // plain whitespace split, and the tab goes back to a space inside the term.
    let escaped = query.replace("\\ ", "\t");
    let mut sets: Vec<Vec<Term>> = Vec::new();
    let mut set: Vec<Term> = Vec::new();
    // Whether the NEXT term starts a new AND-set. False right after a `|`, which is the whole
    // mechanism: `a | b` leaves it false so `b` joins `a`'s set.
    let mut switch_set = false;
    let mut after_bar = false;
    for token in escaped.split(' ') {
        if token.is_empty() {
            // `split` on a run of spaces yields empties. Upstream's regex split collapses runs, and
            // the `len(text) > 0` guard drops what is left; this is the same drop, earlier.
            continue;
        }
        let mut text: Vec<char> = token.chars().map(|c| if c == '\t' { ' ' } else { c }).collect();
        let case_sensitive = text.iter().any(|&c| matches!(class_of(c), CharClass::Upper));
        if !case_sensitive {
            for ch in &mut text {
                *ch = lower(*ch);
            }
        }
        let mut kind = TermKind::Fuzzy;
        let mut inverse = false;

        // A `|` with nothing to its left is a literal `|`, and two in a row are one — both fall out
        // of the guard rather than being spelled as cases.
        if !set.is_empty() && !after_bar && text == ['|'] {
            switch_set = false;
            after_bar = true;
            continue;
        }
        after_bar = false;

        if text.first() == Some(&'!') {
            inverse = true;
            // A negation is always EXACT: `!foo` excludes the substring, never anything `foo` might
            // fuzzily reach — an exclusion that guessed would delete rows the user meant to keep.
            kind = TermKind::Exact;
            text.remove(0);
        }

        // `$` ALONE is a term, not an anchor for the empty string.
        if text.len() > 1 && text.last() == Some(&'$') {
            kind = TermKind::Suffix;
            text.pop();
        }

        if text.len() > 2 && text.first() == Some(&'\'') && text.last() == Some(&'\'') {
            kind = TermKind::ExactBoundary;
            text.pop();
            text.remove(0);
        } else if text.first() == Some(&'\'') {
            // FLIPS exactness rather than setting it, which is what makes `'` mean the same thing
            // in `--exact` mode read backwards. Here the pattern is fuzzy by default,
            // so a bare `'` demands exact — unless the term is already a negation,
            // which is exact anyway, and the flip hands it back its fuzziness.
            kind = if inverse { TermKind::Fuzzy } else { TermKind::Exact };
            text.remove(0);
        } else if text.first() == Some(&'^') {
            // `^` after a `$` was already taken is the two-ended anchor, and that is an EQUALITY —
            // not a prefix that happens to end where the candidate does.
            kind = if matches!(kind, TermKind::Suffix) {
                TermKind::Equal
            } else {
                TermKind::Prefix
            };
            text.remove(0);
        }

        if text.is_empty() {
            continue;
        }
        if switch_set {
            sets.push(std::mem::take(&mut set));
        }
        set.push(Term {
            kind,
            inverse,
            text,
            case_sensitive,
        });
        switch_set = true;
    }
    if !set.is_empty() {
        sets.push(set);
    }
    sets
}

/// The class of the scalar at `index`, or the class a candidate's imaginary left edge has.
fn class_at(text: &[char], index: usize) -> CharClass {
    text.get(index).copied().map_or(CharClass::White, class_of)
}

/// fzf's `bonusAt` — the structural bonus a match STARTING at `index` would earn.
fn bonus_at(text: &[char], index: usize) -> i32 {
    if index == 0 {
        return BONUS_BOUNDARY_WHITE;
    }
    bonus_for(class_at(text, index - 1), class_at(text, index))
}

/// Whether the scalar beside a boundary match is one a word may end against.
///
/// `<= charDelimiter` in upstream, and a comparison for the same reason [`bonus_for`]'s gate is:
/// the class discriminants are ordered so whitespace, non-word and delimiter are the three below
/// every letter and digit.
fn is_boundary_side(text: &[char], index: usize) -> bool {
    class_at(text, index) <= CharClass::Delimiter
}

/// fzf's `calculateScore` — the score of a match already located, over the window `start..end`.
///
/// Distinct from the DP scorer: that one has to FIND the alignment, this one is told it. The two
/// agree on the arithmetic, which is what puts an exact match and a fuzzy one on one scale.
fn calculate_score(
    text: &[char],
    pattern: &[char],
    case_sensitive: bool,
    start: usize,
    end: usize,
    with_pos: bool,
) -> Match {
    let mut pattern_index = 0;
    let mut score = 0;
    let mut in_gap = false;
    let mut consecutive = 0;
    let mut first_bonus = 0;
    let mut positions = Vec::new();
    let mut prev_class = if start > 0 {
        class_at(text, start - 1)
    } else {
        CharClass::White
    };
    for (index, &raw) in text.iter().enumerate().take(end).skip(start) {
        let class = class_of(raw);
        let ch = if case_sensitive { raw } else { lower(raw) };
        if pattern.get(pattern_index) == Some(&ch) {
            if with_pos {
                positions.push(u32::try_from(index).unwrap_or(u32::MAX));
            }
            score += SCORE_MATCH;
            let mut bonus = bonus_for(prev_class, class);
            if consecutive == 0 {
                first_bonus = bonus;
            } else {
                if bonus >= BONUS_BOUNDARY && bonus > first_bonus {
                    first_bonus = bonus;
                }
                bonus = bonus.max(first_bonus).max(BONUS_CONSECUTIVE);
            }
            score += if pattern_index == 0 {
                bonus * BONUS_FIRST_CHAR_MULTIPLIER
            } else {
                bonus
            };
            in_gap = false;
            consecutive += 1;
            pattern_index += 1;
        } else {
            score += if in_gap {
                SCORE_GAP_EXTENSION
            } else {
                SCORE_GAP_START
            };
            in_gap = true;
            consecutive = 0;
            first_bonus = 0;
        }
        prev_class = class;
    }
    Match { score, positions }
}

/// A contiguous window, as the answer the non-fuzzy matchers give.
fn window(start: usize, end: usize, score: i32, with_pos: bool) -> Match {
    Match {
        score,
        positions: if with_pos {
            (start..end)
                .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
                .collect()
        } else {
            Vec::new()
        },
    }
}

/// fzf's `exactMatchNaive` — the best CONTIGUOUS occurrence, ranked by where it starts.
///
/// "Best" is the one whose first scalar earns the highest structural bonus, and the scan stops
/// early on any occurrence at a word boundary, since nothing later can beat it. `boundary`
/// additionally demands that both ends of the match sit against a word edge, which is what `'term'`
/// asks for.
///
/// The `asciiFuzzyIndex` prefilter is dropped, as everywhere in this crate: it changes how long the
/// scan takes and never what it finds.
fn exact_match(
    text: &[char],
    pattern: &[char],
    case_sensitive: bool,
    boundary: bool,
    with_pos: bool,
) -> Option<Match> {
    if pattern.is_empty() {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    if text.len() < pattern.len() {
        return None;
    }
    let mut pattern_index = 0_usize;
    let mut bonus = 0;
    let mut boundary_bonus = 0;
    let mut best: Option<(usize, i32)> = None;
    let mut index = 0_usize;
    while index < text.len() {
        let raw = text.get(index).copied().unwrap_or('\0');
        let ch = if case_sensitive { raw } else { lower(raw) };
        let mut ok = pattern.get(pattern_index) == Some(&ch);
        if ok {
            if pattern_index == 0 {
                bonus = bonus_at(text, index);
                boundary_bonus = bonus;
            }
            if boundary {
                ok = boundary_bonus >= BONUS_BOUNDARY;
                if ok && pattern_index == 0 {
                    ok = index == 0 || is_boundary_side(text, index - 1);
                }
                if ok && pattern_index == pattern.len() - 1 {
                    ok = index == text.len() - 1 || is_boundary_side(text, index + 1);
                }
            }
        }
        if ok {
            pattern_index += 1;
            if pattern_index == pattern.len() {
                if best.is_none_or(|(_, best_bonus)| bonus > best_bonus) {
                    best = Some((index, bonus));
                }
                if bonus >= BONUS_BOUNDARY {
                    break;
                }
                // Back to the scalar after this occurrence STARTED, so overlapping ones are seen.
                index -= pattern_index - 1;
                pattern_index = 0;
                bonus = 0;
            }
        } else {
            index -= pattern_index;
            pattern_index = 0;
            bonus = 0;
        }
        index += 1;
    }
    let (end_index, bonus) = best?;
    let start = end_index + 1 - pattern.len();
    let end = end_index + 1;
    if !boundary {
        // The window is contiguous, so `calculate_score` fills exactly the positions the window
        // would — no gap can open inside a run of scalars the pattern matched one for one.
        return Some(calculate_score(
            text,
            pattern,
            case_sensitive,
            start,
            end,
            with_pos,
        ));
    }
    // A boundary match is scored by its EDGES rather than by its characters, and an underscore is
    // the weakest edge there is — `foo_bar` should lose to `foo bar` for `'foo'`.
    let mut score = bonus;
    let mut deduct = bonus - BONUS_BOUNDARY + 1;
    if start > 0 && text.get(start - 1) == Some(&'_') {
        score -= deduct + 1;
        deduct = 1;
    }
    if text.get(end) == Some(&'_') {
        score -= deduct;
    }
    let length = i32::try_from(pattern.len()).unwrap_or(i32::MAX);
    // The base is what lets a boundary match compete on the same scale in `'foo' | bar`.
    score += SCORE_MATCH * length + BONUS_BOUNDARY_WHITE * (length + 1);
    Some(window(start, end, score, with_pos))
}

/// How many scalars of leading whitespace `text` opens with.
fn leading_whitespace(text: &[char]) -> usize {
    text.iter().take_while(|c| c.is_whitespace()).count()
}

/// How many it ends with.
fn trailing_whitespace(text: &[char]) -> usize {
    text.iter().rev().take_while(|c| c.is_whitespace()).count()
}

/// Whether `text[at..]` opens with `pattern`.
fn equal_run(text: &[char], pattern: &[char], case_sensitive: bool, at: usize) -> bool {
    pattern.iter().enumerate().all(|(offset, &want)| {
        text.get(at + offset)
            .is_some_and(|&raw| want == if case_sensitive { raw } else { lower(raw) })
    })
}

/// fzf's `PrefixMatch` — `^term`.
///
/// Leading whitespace is skipped unless the term itself opens with whitespace, so `^git` finds a
/// history entry the user happened to type with a leading space.
fn prefix_match(text: &[char], pattern: &[char], case_sensitive: bool, with_pos: bool) -> Option<Match> {
    if pattern.is_empty() {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    let start = if pattern.first().is_some_and(|c| c.is_whitespace()) {
        0
    } else {
        leading_whitespace(text)
    };
    if text.len().checked_sub(start)? < pattern.len() {
        return None;
    }
    if !equal_run(text, pattern, case_sensitive, start) {
        return None;
    }
    let end = start + pattern.len();
    let found = calculate_score(text, pattern, case_sensitive, start, end, with_pos);
    Some(window(start, end, found.score, with_pos))
}

/// fzf's `SuffixMatch` — `term$`.
fn suffix_match(text: &[char], pattern: &[char], case_sensitive: bool, with_pos: bool) -> Option<Match> {
    let trimmed = if pattern.last().is_none_or(|c| !c.is_whitespace()) {
        text.len() - trailing_whitespace(text)
    } else {
        text.len()
    };
    if pattern.is_empty() {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    let start = trimmed.checked_sub(pattern.len())?;
    if !equal_run(text, pattern, case_sensitive, start) {
        return None;
    }
    let found = calculate_score(text, pattern, case_sensitive, start, trimmed, with_pos);
    Some(window(start, trimmed, found.score, with_pos))
}

/// fzf's `EqualMatch` — `^term$`, the whole candidate once its edges are trimmed.
///
/// Scored by a formula rather than by [`calculate_score`], because an equality has no shape to
/// reward: every equal match is as good as every other, and the constant is chosen to beat them.
fn equal_match(text: &[char], pattern: &[char], case_sensitive: bool, with_pos: bool) -> Option<Match> {
    if pattern.is_empty() {
        return None;
    }
    let start = if pattern.first().is_some_and(|c| c.is_whitespace()) {
        0
    } else {
        leading_whitespace(text)
    };
    let trailing = if pattern.last().is_some_and(|c| c.is_whitespace()) {
        0
    } else {
        trailing_whitespace(text)
    };
    if text.len().checked_sub(start)?.checked_sub(trailing)? != pattern.len() {
        return None;
    }
    if !equal_run(text, pattern, case_sensitive, start) {
        return None;
    }
    let length = i32::try_from(pattern.len()).unwrap_or(i32::MAX);
    let score = (SCORE_MATCH + BONUS_BOUNDARY_WHITE) * length
        + (BONUS_FIRST_CHAR_MULTIPLIER - 1) * BONUS_BOUNDARY_WHITE;
    Some(window(start, start + pattern.len(), score, with_pos))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a test that asserts a term's shape has nothing to assert if the parse gave it none"
    )]

    use super::{Pattern, TermKind};

    /// The shape one query parses to, as `(kind, inverse, text)` per term.
    fn shape(query: &str) -> Vec<Vec<(TermKind, bool, String)>> {
        Pattern::parse(query)
            .sets
            .iter()
            .map(|set| {
                set.iter()
                    .map(|term| (term.kind, term.inverse, term.text.iter().collect::<String>()))
                    .collect()
            })
            .collect()
    }

    /// PORTED FROM fzf's `TestParseTermsExtended` — one query carrying every sigil and every
    /// interaction between them, which is the only way to pin a grammar whose rules are ordered.
    #[test]
    fn every_sigil_parses_the_way_fzf_reads_it() {
        let sets = shape("aaa 'bbb ^ccc ddd$ !eee !'fff !^ggg !hhh$ | ^iii$ ^xxx | 'yyy | zzz$ | !ZZZ |");
        assert_eq!(sets.len(), 9, "{sets:?}");
        assert_eq!(sets[0], [(TermKind::Fuzzy, false, "aaa".into())]);
        assert_eq!(sets[1], [(TermKind::Exact, false, "bbb".into())]);
        assert_eq!(sets[2], [(TermKind::Prefix, false, "ccc".into())]);
        assert_eq!(sets[3], [(TermKind::Suffix, false, "ddd".into())]);
        assert_eq!(sets[4], [(TermKind::Exact, true, "eee".into())]);
        // `!'fff` — the quote FLIPS, and a negation was already exact, so it lands back on fuzzy.
        assert_eq!(sets[5], [(TermKind::Fuzzy, true, "fff".into())]);
        assert_eq!(sets[6], [(TermKind::Prefix, true, "ggg".into())]);
        // The `|` joins `!hhh$` and `^iii$` into ONE set: either may satisfy it.
        assert_eq!(sets[7], [
            (TermKind::Suffix, true, "hhh".into()),
            (TermKind::Equal, false, "iii".into()),
        ],);
        // Four ORed, and the trailing `|` names nothing, so it is dropped rather than joining air.
        assert_eq!(sets[8], [
            (TermKind::Prefix, false, "xxx".into()),
            (TermKind::Exact, false, "yyy".into()),
            (TermKind::Suffix, false, "zzz".into()),
            (TermKind::Exact, true, "ZZZ".into()),
        ],);
    }

    /// PORTED FROM fzf's `TestParseTermsEmpty`. A sigil with nothing after it demands nothing.
    #[test]
    fn a_query_of_bare_sigils_demands_nothing() {
        assert!(Pattern::parse("' ^ !' !^").is_empty());
        assert!(Pattern::parse("").is_empty());
        assert!(Pattern::parse("   ").is_empty());
    }

    /// `$` alone is a term, not an anchor — the one case the suffix rule spells out.
    #[test]
    fn a_lone_dollar_is_a_term() {
        assert_eq!(shape("$"), [[(TermKind::Fuzzy, false, "$".into())]]);
    }

    /// Smart case is decided per TERM, which is what makes it usable mid-query.
    #[test]
    fn each_term_decides_its_own_case_sensitivity() {
        let pattern = Pattern::parse("git Commit");
        assert!(!pattern.sets[0][0].case_sensitive, "a lowercase term is loose");
        assert!(
            pattern.sets[1][0].case_sensitive,
            "and a capital narrows just that one"
        );
        assert!(
            pattern.rank("git commit").is_none(),
            "so the lowercase entry is out"
        );
        assert!(
            pattern.rank("GIT Commit").is_some(),
            "and the capitalised one is in"
        );
    }

    #[test]
    fn terms_are_anded() {
        let pattern = Pattern::parse("git push");
        assert!(pattern.rank("git push origin").is_some());
        assert!(
            pattern.rank("git commit").is_none(),
            "one term unmet fails the whole query"
        );
    }

    #[test]
    fn a_bar_ors_the_terms_around_it() {
        let pattern = Pattern::parse("^git push | pull");
        assert!(pattern.rank("git push origin").is_some());
        assert!(pattern.rank("git pull --rebase").is_some());
        assert!(pattern.rank("git fetch").is_none());
        assert!(
            pattern.rank("hub push origin").is_none(),
            "the anchored set still has to hold"
        );
    }

    #[test]
    fn a_negation_excludes_without_ranking() {
        let pattern = Pattern::parse("git !push");
        assert!(pattern.rank("git commit").is_some());
        assert!(pattern.rank("git push origin").is_none());
        // The negated set contributes 0, so the score is the `git` term's alone.
        assert_eq!(
            pattern.rank("git commit"),
            Pattern::parse("git").rank("git commit")
        );
    }

    #[test]
    fn an_exact_term_demands_contiguity_where_a_fuzzy_one_does_not() {
        assert!(
            Pattern::parse("gcm").rank("git commit").is_some(),
            "fuzzy reaches across"
        );
        assert!(
            Pattern::parse("'gcm").rank("git commit").is_none(),
            "exact does not"
        );
        assert!(Pattern::parse("'commit").rank("git commit").is_some());
    }

    /// PORTED FROM fzf's `TestExact`: `'abc` against `aabbcc abc` takes the LATE occurrence,
    /// because the one at a word boundary outranks the one buried in `aabbcc`.
    #[test]
    fn an_exact_term_prefers_the_occurrence_at_a_word_boundary() {
        let found = Pattern::parse("'abc").score("aabbcc abc").expect("it matches");
        assert_eq!(found.positions, [7, 8, 9]);
    }

    #[test]
    fn the_anchors_bind_to_the_ends() {
        assert!(Pattern::parse("^git").rank("git status").is_some());
        assert!(Pattern::parse("^git").rank("sudo git status").is_none());
        assert!(Pattern::parse("status$").rank("git status").is_some());
        assert!(Pattern::parse("status$").rank("git status --short").is_none());
        assert!(Pattern::parse("^git$").rank("git").is_some());
        assert!(Pattern::parse("^git$").rank("git status").is_none());
    }

    /// PORTED FROM fzf's `TestEqual`, whose point is the whitespace: an equality trims the
    /// candidate's edges, so a history entry typed with a stray space still equals the term.
    #[test]
    fn an_equality_trims_the_candidates_edges() {
        let pattern = Pattern::parse("^AbC$");
        assert!(pattern.rank("AbC").is_some());
        assert!(pattern.rank(" AbC ").is_some());
        assert!(pattern.rank("AbCd").is_none());
    }

    /// A quoted term demands both ends of a word, which is what separates `'git'` from `'git`.
    #[test]
    fn a_doubly_quoted_term_demands_word_edges() {
        let pattern = Pattern::parse("'git'");
        assert!(pattern.rank("git status").is_some());
        assert!(
            pattern.rank("gitk --all").is_none(),
            "`gitk` does not end the word"
        );
    }

    /// A backslash-escaped space keeps one term whole — otherwise no query could name a path with a
    /// space in it.
    #[test]
    fn an_escaped_space_stays_inside_its_term() {
        // Kept as typed, because the capitals made this term case-sensitive — smart case is read
        // off the whole token, sigils and escaped space included.
        assert_eq!(shape("'My\\ Documents"), [[(
            TermKind::Exact,
            false,
            "My Documents".into()
        )]]);
        assert!(
            Pattern::parse("'My\\ Documents")
                .rank("cd My Documents")
                .is_some()
        );
        assert!(
            Pattern::parse("'my\\ documents")
                .rank("cd My Documents")
                .is_some(),
            "and lowercase still reaches it"
        );
    }

    /// The syntax has to stay OFF the plain scorer: a Tab completion's query is shell text where
    /// every one of these characters means something else.
    #[test]
    fn the_plain_scorer_reads_the_sigils_as_text() {
        assert!(
            crate::score("^git", "^git").is_some(),
            "the caret is a character there"
        );
        assert!(crate::score("^git", "git status").is_none());
    }

    #[test]
    fn an_empty_query_matches_everything_at_zero() {
        let pattern = Pattern::parse("");
        assert_eq!(pattern.rank("anything at all"), Some(0));
        assert_eq!(pattern.score("anything at all").expect("matches").positions, []);
    }

    /// Positions come back sorted even though terms match in QUERY order, because the underline
    /// walks them forward.
    #[test]
    fn the_positions_come_back_in_candidate_order() {
        let found = Pattern::parse("status$ ^git")
            .score("git status")
            .expect("both hold");
        assert_eq!(found.positions, [0, 1, 2, 4, 5, 6, 7, 8, 9]);
    }
}
