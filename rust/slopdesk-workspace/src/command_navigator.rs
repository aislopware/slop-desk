//! The Command Navigator card's words and its two measurements.
//!
//! The navigator has two drawings — the phone's `SwiftUI` view and the Mac's `AppKit` one — and
//! everything below is the part of that card which is neither: a placeholder, four zero-state
//! sentences, three footer hints, the two help strings the row's affordances carry, and the card's
//! own width and results ceiling. It sits here for the reason the palette's and find bar's numbers
//! do: a number or a sentence re-typed into a second renderer is a pair that drifts the first time
//! either is tuned, and nothing in the repo compares a string literal in one file with a string
//! literal in another.
//!
//! What is NOT here: the ranking, the list itself, the jump and the clamp. Each of those was
//! already shared before this module existed; this only finishes the set with the card's own
//! vocabulary.

/// The card's fixed width.
///
/// Narrower than the palette's, because a row here is ONE command line rather than a title, a place
/// line and a keycap column.
pub const PANEL_WIDTH: f64 = 480.0;

/// The tallest the results viewport may be.
///
/// Past this the list scrolls instead of the card growing; a renderer standing in a SHORT pane may
/// shrink it further, never grow it.
pub const RESULTS_MAX_HEIGHT: f64 = 320.0;

/// Which segment the card is filtered to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter {
    /// Every command in the pane.
    All,
    /// The ones that exited non-zero.
    Failed,
    /// The ones the reader starred.
    Bookmarked,
}

impl Filter {
    /// Every segment, in code order.
    pub const ALL: [Self; 3] = [Self::All, Self::Failed, Self::Bookmarked];

    /// The segment a code names. An unrecognised code reads as [`Filter::All`], the widest one — a
    /// zero state that names the wrong segment is worse than one that names the whole pane.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Failed,
            2 => Self::Bookmarked,
            _ => Self::All,
        }
    }

    /// This segment's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::All => 0,
            Self::Failed => 1,
            Self::Bookmarked => 2,
        }
    }
}

/// One word the card says, in the near side's own declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Word {
    /// The search field's placeholder.
    SearchPlaceholder,
    /// The zero state when the query matched nothing but the pane HAS commands.
    NoMatches,
    /// The selected row's "run this again in the pane" affordance, with the chord that does it
    /// without the pointer.
    ReRunHelp,
    /// The selected row's "put this command's captured output on the clipboard" affordance.
    CopyOutputHelp,
    /// The per-row star.
    BookmarkHelp,
    /// ↑/↓ walk the list.
    NavigateHintLabel,
    /// The caps those arrows print as.
    NavigateHintGlyph,
    /// ↩ jumps the pane's scrollback to the selected command and closes.
    JumpHintLabel,
    /// The cap ↩ prints as.
    JumpHintGlyph,
    /// Esc closes without moving the viewport.
    CloseHintLabel,
    /// The cap Esc prints as.
    CloseHintGlyph,
}

impl Word {
    /// Every word, in index order — the order one delivery carries them in.
    pub const ALL: [Self; 11] = [
        Self::SearchPlaceholder,
        Self::NoMatches,
        Self::ReRunHelp,
        Self::CopyOutputHelp,
        Self::BookmarkHelp,
        Self::NavigateHintLabel,
        Self::NavigateHintGlyph,
        Self::JumpHintLabel,
        Self::JumpHintGlyph,
        Self::CloseHintLabel,
        Self::CloseHintGlyph,
    ];

    /// What it says.
    ///
    /// A hint's label and its glyph ride as a PAIR rather than as one pre-joined string, so the two
    /// renderers cannot end up saying "Navigate" and "Move" about the same key — and so neither has
    /// to un-join a label to set the cap in its own type.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::SearchPlaceholder => "Search commands\u{2026}",
            Self::NoMatches => "No matches",
            Self::ReRunHelp => "Re-run (\u{2318}\u{21a9})",
            Self::CopyOutputHelp => "Copy Output (\u{2318}C)",
            Self::BookmarkHelp => "Bookmark",
            Self::NavigateHintLabel => "Navigate",
            Self::NavigateHintGlyph => "\u{2191}\u{2193}",
            Self::JumpHintLabel => "Jump",
            Self::JumpHintGlyph => "\u{21a9}",
            Self::CloseHintLabel => "Close",
            Self::CloseHintGlyph => "esc",
        }
    }
}

/// The zero-state line for an empty list, scoped to the active segment.
///
/// Two questions in one answer, because they are asked together and answered differently: a query
/// that matched nothing is `No matches` — the list is empty because of what was TYPED — and an
/// empty segment names the segment, because the list is empty for what the pane holds.
#[must_use]
pub const fn empty_line(filter: Filter, has_blocks: bool) -> &'static str {
    if has_blocks {
        return Word::NoMatches.text();
    }
    match filter {
        Filter::All => "No commands yet",
        Filter::Failed => "No failed commands",
        Filter::Bookmarked => "No bookmarked commands",
    }
}

#[cfg(test)]
mod tests {
    use super::{Filter, PANEL_WIDTH, RESULTS_MAX_HEIGHT, Word, empty_line};

    #[test]
    fn the_card_is_narrower_than_it_is_allowed_to_be_tall_is_not_the_claim() {
        const { assert!(PANEL_WIDTH > 0.0) }
        const { assert!(RESULTS_MAX_HEIGHT > 0.0) }
        // A results ceiling taller than the card is wide would put a one-line row in a column.
        const { assert!(RESULTS_MAX_HEIGHT < PANEL_WIDTH) }
    }

    /// The whole point of the two-question answer: a typed query and an empty segment differ.
    #[test]
    fn a_typed_query_blames_the_query_and_an_empty_segment_names_itself() {
        for filter in Filter::ALL {
            assert_eq!(empty_line(filter, true), Word::NoMatches.text(), "{filter:?}");
        }
        assert_eq!(empty_line(Filter::All, false), "No commands yet");
        assert_eq!(empty_line(Filter::Failed, false), "No failed commands");
        assert_eq!(empty_line(Filter::Bookmarked, false), "No bookmarked commands");
    }

    #[test]
    fn no_two_segments_share_a_zero_state() {
        let mut lines: Vec<&str> = Filter::ALL.iter().map(|f| empty_line(*f, false)).collect();
        lines.sort_unstable();
        let count = lines.len();
        lines.dedup();
        assert_eq!(lines.len(), count);
    }

    #[test]
    fn every_word_says_something() {
        for word in Word::ALL {
            assert!(!word.text().is_empty(), "{word:?}");
        }
    }

    #[test]
    fn every_segment_round_trips_and_an_unknown_code_reads_as_the_widest() {
        for filter in Filter::ALL {
            assert_eq!(Filter::from_code(filter.code()), filter);
        }
        assert_eq!(Filter::from_code(200), Filter::All);
    }
}
