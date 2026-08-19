//! ONE ranking for every search field in the app.
//!
//! The palette, the command navigator and Jump-To each had their own scored-and-sorted loop, and
//! all three were the same three lines: score every candidate, drop the misses, order by score with
//! arrival breaking ties. The only real difference is how many things a candidate can be found BY —
//! a command block has one (what was typed), a palette row has three (its title, its subtitle, and
//! the hidden synonyms that make `lock` find "Read Only") — and that difference is a number, not a
//! separate algorithm.
//!
//! ## Fields are a PRIORITY, and the priority is the tier
//!
//! A candidate's fields arrive most-important-first, and the FIRST one that matches decides both
//! its score and its tier. A row found by its title outranks a row found only by its subtitle even
//! when the subtitle scored higher, because what the query hit says more about relevance than how
//! well it hit: someone typing `lock` wants the row CALLED Read Only above the row that merely
//! mentions locking. Ordering on score alone would silently sort the hidden synonyms in among the
//! titles.
//!
//! ## Why positions are asked for by tier
//!
//! Underlining costs a backtrace through the alignment matrix, and a caller underlines exactly one
//! field — the one it draws large. So the caller names that field and gets positions only for rows
//! that matched it; every other row's backtrace is work nobody would read. A caller that underlines
//! nothing asks for none, which is the cheap path fzf itself calls `withPos == false`.

use slopdesk_fuzzy as fuzzy;

/// The most rows a search field hands back, however many matched.
///
/// A person scanning a list stops long before this; what the cap actually protects is the render,
/// which would otherwise build a row view per match on every keystroke. fzf's own
/// `MAX_SEARCH_RESULTS`.
pub const MAX_SEARCH_RESULTS: usize = 250;

/// Where one candidate placed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ranked {
    /// Which candidate this is, by its position in the list the caller passed in.
    pub candidate: usize,
    /// Which of its fields matched — 0 is the most important, and a lower tier always wins.
    pub tier: usize,
    /// The fzf score within that tier; higher is better.
    pub score: i32,
    /// The scalar offsets the query matched in the field named by `tier`, ascending — the
    /// matcher's own width, so nothing is converted between deciding them and drawing them.
    /// Empty unless the caller asked for that tier's positions.
    pub positions: Vec<u32>,
}

/// Every candidate that matches `query`, best first.
///
/// `fields` is one flat array holding `stride` fields per candidate in priority order — a flat
/// array and a stride rather than a slice of slices, because the caller is a C ABI handing over one
/// contiguous block and the alternative is an allocation per candidate on a keystroke. A field a
/// candidate does not have is `None`, which is skipped rather than matched-as-empty.
///
/// `positions_for` names the ONE field the caller will underline; positions come back only for rows
/// that matched it. A blank query matches everything with score 0, so a search field's zero state
/// is the list in its own order rather than a reshuffle.
#[must_use]
pub fn rank(
    fields: &[Option<&str>],
    stride: usize,
    query: &str,
    positions_for: Option<usize>,
) -> Vec<Ranked> {
    if stride == 0 {
        return Vec::new();
    }
    let mut out: Vec<Ranked> = fields
        .chunks(stride)
        .enumerate()
        .filter_map(|(candidate, group)| {
            // The first field that MATCHES, not the first field that exists: an absent field and a
            // present one the query misses both fall through to the next rung.
            group.iter().enumerate().find_map(|(tier, field)| {
                let text = (*field)?;
                if positions_for == Some(tier) {
                    let hit = fuzzy::score(query, text)?;
                    return Some(Ranked {
                        candidate,
                        tier,
                        score: hit.score,
                        positions: hit.positions,
                    });
                }
                Some(Ranked {
                    candidate,
                    tier,
                    score: fuzzy::rank(query, text)?,
                    positions: Vec::new(),
                })
            })
        })
        .collect();
    out.sort_by(|left, right| {
        left.tier
            .cmp(&right.tier)
            .then(right.score.cmp(&left.score))
            .then(left.candidate.cmp(&right.candidate))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::{MAX_SEARCH_RESULTS, rank};

    /// The palette's shape: title, subtitle, hidden synonyms.
    fn palette<'a>(rows: &[[Option<&'a str>; 3]]) -> Vec<Option<&'a str>> {
        rows.iter().flatten().copied().collect()
    }

    #[test]
    fn a_title_hit_outranks_a_subtitle_hit_that_scored_higher() {
        // The second row's subtitle is an exact hit; the first row's title carries l-o-c-k only
        // scattered across four words. Scored on the number alone the decoy would lead.
        let fields = palette(&[[Some("Reload Custom Keymap"), None, None], [
            Some("Split Right"),
            Some("lock lock lock"),
            None,
        ]]);
        let ranked = rank(&fields, 3, "lock", Some(0));
        assert_eq!(
            ranked
                .iter()
                .map(|found| (found.candidate, found.tier))
                .collect::<Vec<_>>(),
            [(0, 0), (1, 1)],
            "the row whose TITLE carries the query leads, whatever the other one scored"
        );
        let scores: Vec<i32> = ranked.iter().map(|found| found.score).collect();
        assert!(
            scores.get(1) > scores.first(),
            "and it leads DESPITE the lower score, which is the whole point of the tier"
        );
    }

    #[test]
    fn a_hidden_synonym_sits_below_every_visible_hit() {
        let fields = palette(&[[Some("Read Only"), None, Some("lock freeze view only")], [
            Some("Split Right"),
            Some("lock"),
            None,
        ]]);
        let ranked = rank(&fields, 3, "lock", Some(0));
        assert_eq!(
            ranked.iter().map(|r| (r.candidate, r.tier)).collect::<Vec<_>>(),
            [(1, 1), (0, 2)]
        );
    }

    #[test]
    fn positions_come_back_only_for_the_field_the_caller_underlines() {
        let fields = palette(&[[Some("lock"), None, None], [Some("Reload"), Some("lock"), None]]);
        let underlined: Vec<Vec<u32>> = rank(&fields, 3, "lock", Some(0))
            .into_iter()
            .map(|found| found.positions)
            .collect();
        assert_eq!(
            underlined,
            [vec![0, 1, 2, 3], Vec::new()],
            "the title it underlines, and nothing for the subtitle hit below it"
        );
        assert!(
            rank(&fields, 3, "lock", None)
                .iter()
                .all(|found| found.positions.is_empty()),
            "a caller that underlines nothing asks for nothing"
        );
    }

    #[test]
    fn a_blank_query_keeps_the_list_in_its_own_order() {
        let fields = [Some("zeta"), Some("alpha"), Some("mid")];
        let ranked = rank(&fields, 1, "   ", None);
        assert_eq!(ranked.iter().map(|found| found.candidate).collect::<Vec<_>>(), [
            0, 1, 2
        ]);
        assert!(ranked.iter().all(|found| found.score == 0));
    }

    #[test]
    fn a_single_field_list_drops_the_misses_and_breaks_ties_by_arrival() {
        let fields = [Some("make check"), Some("git status"), Some("make check")];
        let ranked = rank(&fields, 1, "mk", None);
        assert_eq!(
            ranked.iter().map(|found| found.candidate).collect::<Vec<_>>(),
            [0, 2],
            "git status carries no `mk` in order at all, and equal scores keep their arrival"
        );
        let scores: Vec<i32> = ranked.iter().map(|found| found.score).collect();
        assert_eq!(scores.first(), scores.get(1));
    }

    #[test]
    fn an_absent_field_is_skipped_rather_than_matched_as_empty() {
        let fields = [None, Some("make")];
        let ranked = rank(&fields, 2, "make", None);
        assert_eq!(
            ranked
                .iter()
                .map(|found| (found.candidate, found.tier))
                .collect::<Vec<_>>(),
            [(0, 1)],
            "the one candidate matched on its SECOND field"
        );
    }

    #[test]
    fn a_stride_of_zero_answers_nothing_rather_than_dividing_by_it() {
        assert!(rank(&[Some("make")], 0, "make", None).is_empty());
    }

    #[test]
    fn the_cap_is_the_render_budget_fzf_uses() {
        assert_eq!(MAX_SEARCH_RESULTS, 250);
    }
}
