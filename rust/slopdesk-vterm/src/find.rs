//! The find bar's cursor: which hit is current, and what "next" means from here.
//!
//! [`crate::search`] answers *where are the hits*; this answers *which one am I looking at*. They
//! are separate because the first is a pure function of the grid and the second is state that
//! survives keystrokes — a user who typed a needle and pressed ⌘G four times is four hops into an
//! answer that was computed once.
//!
//! ## Why the matches are a snapshot and not a live view
//!
//! A hit is a pair of SCREEN coordinates, and screen coordinates shift when the scrollback trims
//! from the front. So a match list goes stale the moment the shell prints enough to push a row out
//! of the buffer — there is no cheap way to keep it live, and an expensive one would re-scan the
//! whole buffer on every write. Instead the list is explicitly a snapshot of the moment the needle
//! was typed: [`VtSession::search`] re-takes it, and everything between two searches navigates the
//! old one. That is what every terminal's find bar does, and the failure mode is benign — a hop
//! lands a line off after heavy output, and retyping fixes it.
//!
//! ## Why "next" starts at the viewport rather than at the top
//!
//! A find that always selected the buffer's first hit would throw the user thousands of rows back
//! on every keystroke, because the find bar re-searches per character typed. Starting at the first
//! hit at or after the viewport's top row means typing narrows in place, which is the behaviour
//! that makes an incremental find usable.

use crate::screen::ScreenMatch;
use crate::search::SearchQuery;
use crate::session::{Result, Scroll, VtSession};

/// The find bar's state: the needle it last ran, its hits, and which one is current.
///
/// Held on the session rather than on the caller because the current hit and the terminal's
/// selection must agree — the selection IS the highlight, and a caller holding the index separately
/// could navigate to a hit while the selection still showed another.
#[derive(Debug, Default)]
pub(crate) struct FindState {
    needle: String,
    matches: Vec<ScreenMatch>,
    /// Index into `matches`. `None` while nothing has been navigated to, which is only possible
    /// when there are no matches at all.
    current: Option<usize>,
}

impl VtSession {
    /// Run `needle` over the whole retained buffer and select the first hit from the viewport down.
    ///
    /// The search is a plain case-insensitive substring, because that is what the `search:` verb
    /// carries. Regex, whole-word and case-sensitive finds are the find bar's own — it computes
    /// those match rows itself and drives this session through
    /// [`scroll`](VtSession::scroll)/[`set_screen_selection`](VtSession::set_screen_selection)
    /// instead.
    ///
    /// An empty needle clears the hits and the highlight without closing anything: that is the
    /// state a find bar is in between the user opening it and typing.
    ///
    /// Answers how many hits there are, which is what the find bar prints as `3/17`.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn search(&mut self, needle: &str) -> Result<usize> {
        self.find.needle.clear();
        self.find.needle.push_str(needle);
        self.find.matches = self.search_screen(&SearchQuery::new(needle))?;
        self.find.current = None;
        if self.find.matches.is_empty() {
            // The previous needle's highlight must go even when the new one finds nothing, or a
            // typo leaves the last good hit selected and looking like a match.
            self.clear_selection()?;
            return Ok(0);
        }
        let from = self.viewport_info()?.viewport_top_row;
        let start = self
            .find
            .matches
            .iter()
            .position(|hit| hit.start_row >= from)
            .unwrap_or(0);
        self.show_match(start)?;
        Ok(self.find.matches.len())
    }

    /// Move to the next hit (`forward`) or the previous one, wrapping at either end.
    ///
    /// Wrapping rather than stopping: a find bar that goes quiet at the last hit is
    /// indistinguishable from one that has broken, and every editor wraps.
    ///
    /// Answers `false` when there is nothing to move between — no needle, or no hits.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn navigate_search(&mut self, forward: bool) -> Result<bool> {
        let count = self.find.matches.len();
        if count == 0 {
            return Ok(false);
        }
        let next = match self.find.current {
            // Nothing current yet — `search` only leaves that state when there are no hits, so this
            // is the defensive branch rather than a reachable one.
            None => 0,
            Some(index) if forward => (index + 1) % count,
            Some(index) => (index + count - 1) % count,
        };
        self.show_match(next)?;
        Ok(true)
    }

    /// The current hit's position in its list, as `(one-based index, total)`.
    ///
    /// One-based because its only consumer is the `3/17` a find bar prints, and shipping the
    /// conversion here keeps it from being done differently on each platform.
    #[must_use]
    pub fn search_position(&self) -> Option<(usize, usize)> {
        self.find
            .current
            .map(|index| (index + 1, self.find.matches.len()))
    }

    /// Every hit of the current needle, in reading order.
    #[must_use]
    pub fn search_matches(&self) -> &[ScreenMatch] {
        &self.find.matches
    }

    /// Close the find: drop the needle, the hits, and the highlight they painted.
    ///
    /// The highlight goes because it is the terminal's ONE selection — leaving it behind would mean
    /// ⌘C after dismissing the find bar copies the last hit instead of nothing.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn end_search(&mut self) -> Result<()> {
        let painted = !self.find.matches.is_empty();
        self.find.needle.clear();
        self.find.matches.clear();
        self.find.current = None;
        if painted {
            self.clear_selection()?;
        }
        Ok(())
    }

    /// Selects hit `index` and scrolls it into view.
    fn show_match(&mut self, index: usize) -> Result<()> {
        let Some(hit) = self.find.matches.get(index).copied() else {
            return Ok(());
        };
        self.find.current = Some(index);
        let info = self.viewport_info()?;
        let below = hit.start_row < info.viewport_top_row;
        let above = hit.end_row >= info.viewport_top_row.saturating_add(info.viewport_rows);
        if below || above {
            // One row of context above the hit, so it does not land flush against the top edge
            // where a reader cannot see what produced it.
            self.scroll(Scroll::Row(hit.start_row.saturating_sub(1)));
        }
        self.set_screen_selection((hit.start_col, hit.start_row), (hit.end_col, hit.end_row), false)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use crate::selection::CopyFormat;
    use crate::session::VtSession;

    fn session() -> VtSession {
        VtSession::new(8, 3, 20, 40).unwrap()
    }

    /// Three hits, one per line, spread far enough that most are off screen.
    fn seeded() -> VtSession {
        let mut vt = session();
        vt.feed(b"hit one\r\nfill\r\nhit two\r\nfill\r\nhit thr\r\n");
        vt
    }

    #[test]
    fn a_search_counts_every_hit_in_the_buffer() {
        let mut vt = seeded();
        assert_eq!(vt.search("hit").unwrap(), 3);
    }

    #[test]
    fn a_search_selects_a_hit_and_says_which_one() {
        let mut vt = seeded();
        vt.search("hit").unwrap();
        assert_eq!(
            vt.selection_text(CopyFormat::Plain).unwrap().as_deref(),
            Some("hit")
        );
        let (index, total) = vt.search_position().unwrap();
        assert_eq!(total, 3);
        assert!((1..=3).contains(&index));
    }

    /// The incremental-find rule: typing must not throw the viewport back to the buffer's start.
    #[test]
    fn a_fresh_search_starts_at_the_viewport_rather_than_the_top() {
        let mut vt = seeded();
        let top = vt.viewport_info().unwrap().viewport_top_row;
        vt.search("hit").unwrap();
        let first = vt.search_matches()[vt.search_position().unwrap().0 - 1];
        assert!(
            first.start_row >= top,
            "the search jumped backwards to row {} from a viewport at {top}",
            first.start_row
        );
    }

    #[test]
    fn navigating_wraps_at_both_ends() {
        let mut vt = seeded();
        let total = vt.search("hit").unwrap();
        let start = vt.search_position().unwrap().0;
        for _ in 0..total {
            assert!(vt.navigate_search(true).unwrap());
        }
        assert_eq!(
            vt.search_position().unwrap().0,
            start,
            "a full lap did not come back to where it began"
        );
        assert!(vt.navigate_search(false).unwrap());
        assert_ne!(vt.search_position().unwrap().0, start);
    }

    #[test]
    fn navigating_scrolls_an_off_screen_hit_into_view() {
        let mut vt = seeded();
        vt.search("hit").unwrap();
        for _ in 0..3 {
            vt.navigate_search(true).unwrap();
            let info = vt.viewport_info().unwrap();
            let hit = vt.search_matches()[vt.search_position().unwrap().0 - 1];
            assert!(
                hit.start_row >= info.viewport_top_row
                    && hit.end_row < info.viewport_top_row + info.viewport_rows,
                "hit at {} is outside a viewport of {}..{}",
                hit.start_row,
                info.viewport_top_row,
                info.viewport_top_row + info.viewport_rows
            );
        }
    }

    #[test]
    fn a_needle_that_finds_nothing_drops_the_previous_highlight() {
        let mut vt = seeded();
        vt.search("hit").unwrap();
        assert!(vt.has_selection().unwrap());
        assert_eq!(vt.search("zzz").unwrap(), 0);
        assert!(!vt.has_selection().unwrap());
        assert!(!vt.navigate_search(true).unwrap());
        assert!(vt.search_position().is_none());
    }

    #[test]
    fn an_empty_needle_clears_without_finding_anything() {
        let mut vt = seeded();
        vt.search("hit").unwrap();
        assert_eq!(vt.search("").unwrap(), 0);
        assert!(vt.search_matches().is_empty());
        assert!(!vt.has_selection().unwrap());
    }

    #[test]
    fn ending_the_search_drops_the_hits_and_the_highlight() {
        let mut vt = seeded();
        vt.search("hit").unwrap();
        vt.end_search().unwrap();
        assert!(vt.search_matches().is_empty());
        assert!(vt.search_position().is_none());
        assert!(!vt.has_selection().unwrap());
    }

    /// Ending a search that never painted must not clear a selection the USER made — the find bar
    /// closing is not a reason to lose a drag.
    #[test]
    fn ending_a_search_that_found_nothing_leaves_a_users_selection_alone() {
        let mut vt = seeded();
        assert!(vt.select_all().unwrap());
        vt.end_search().unwrap();
        assert!(vt.has_selection().unwrap());
    }
}
