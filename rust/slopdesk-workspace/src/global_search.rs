//! What the `⇧⌘F` cross-tab results surface IS, for both of the halves that draw it, and the mode
//! pills the in-pane find bar shares with it.
//!
//! The sixth surface off the shared floor (`docs/56` stage D): the Mac draws it as a panel, the
//! phone as a full-height card. The match MATH was already shared before this module existed — a
//! controller runs it and the store owns the query — so what is here is the reading of a result:
//! how the matched run is cut out of its line, the two zero-state lines, the summary, and the
//! card's measurements.
//!
//! ## The excerpt's cut is the piece that most looks like layout and is not
//!
//! A hit's highlight is a range of UTF-16 offsets over the near side's `String`, and mapping one
//! onto a character position can FAIL — an offset that lands inside a surrogate pair names no
//! character at all. The rule is to degrade to a FLAT excerpt rather than to trap, and it has to be
//! ONE rule: a half that re-derived it would eventually index out of bounds on the one line in a
//! scrollback that contains an emoji.
//!
//! [`excerpt_cuts`] answers with UTF-8 byte offsets into the same excerpt the caller already holds,
//! never with three strings back. The caller sends the line once and slices it itself; sending the
//! pieces home would pay for a string the sender is still holding.

/// One `Aa` / `ab` / `.*` mode pill.
///
/// ⚠️ The find bar and the global-search query bar render these pills IDENTICALLY — that is a
/// locked invariant — and the labels and help strings live here so the two surfaces read them
/// rather than agree on them. Three surfaces do, in fact: the Mac's results panel is `AppKit` and
/// cannot see the phone's `UIKit` call site at all.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ModePill {
    /// Match the query's case exactly.
    CaseSensitive,
    /// Match only at word boundaries.
    WholeWord,
    /// Read the query as an ICU regular expression.
    Regex,
}

impl ModePill {
    /// Every pill, in drawn order.
    pub const ALL: [Self; 3] = [Self::CaseSensitive, Self::WholeWord, Self::Regex];

    /// The two the CROSS-TAB search offers.
    ///
    /// Whole-word is the in-pane find bar's alone: the global search runs over a scrollback mirror
    /// rather than over the terminal's own buffer, and the two engines do not agree about what a
    /// word boundary is.
    pub const GLOBAL_SEARCH: [Self; 2] = [Self::CaseSensitive, Self::Regex];

    /// The three the IN-PANE find bar offers, in drawn order: `Aa`, `ab`, `.*`.
    ///
    /// It lives beside [`GLOBAL_SEARCH`](Self::GLOBAL_SEARCH) rather than with the find bar's own
    /// words for the reason the sentence above gives — the two lists are one DECISION, "which
    /// engine can answer which question", and a reader who wants to know why whole-word is
    /// missing upstairs has to be able to see both lists at once. A subset spelled in another
    /// file is a subset that can quietly stop being one.
    pub const IN_PANE_FIND_BAR: [Self; 3] = Self::ALL;

    /// The pill at `index` in [`ALL`](Self::ALL), or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::CaseSensitive),
            1 => Some(Self::WholeWord),
            2 => Some(Self::Regex),
            _ => None,
        }
    }

    /// This pill's place in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::CaseSensitive => 0,
            Self::WholeWord => 1,
            Self::Regex => 2,
        }
    }

    /// The glyph on the chip.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::CaseSensitive => "Aa",
            Self::WholeWord => "ab",
            Self::Regex => ".*",
        }
    }

    /// The hover/accessibility help.
    #[must_use]
    pub const fn help(self) -> &'static str {
        match self {
            Self::CaseSensitive => "Case sensitive",
            Self::WholeWord => "Whole word",
            Self::Regex => "Regex (ICU)",
        }
    }

    /// Whether the glyph is drawn underlined — the whole-word chip's own mark, and nothing else's.
    #[must_use]
    pub const fn underlined(self) -> bool {
        matches!(self, Self::WholeWord)
    }

    /// The pills a surface offers, as a bitmask over [`index`](Self::index): `0` the cross-tab
    /// search's two, anything else the in-pane bar's three.
    #[must_use]
    pub const fn offered(global: bool) -> u8 {
        if global { 0b101 } else { 0b111 }
    }
}

/// The results panel's width on the Mac.
///
/// It is a large card rather than a full-window surface: the workspace behind it is the context the
/// search is ABOUT, and a results panel that covered it would make every hit a jump into the dark.
/// The phone takes the whole sheet instead, which is the same intent at a screen where there is no
/// "behind".
pub const PANEL_WIDTH: f64 = 720.0;

/// The results panel's height on the Mac. See [`PANEL_WIDTH`].
pub const PANEL_HEIGHT: f64 = 560.0;

/// The query bar's prompt.
pub const QUERY_PROMPT: &str = "Search across all tabs…";

/// What a group's disclosure ANNOUNCES.
///
/// The Mac hangs it off the chevron's accessibility description, the phone off its accessibility
/// value, and both said it themselves. A state a screen reader reads out is copy, and copy is the
/// surface's meaning, not its drawing.
#[must_use]
pub const fn disclosure_state(collapsed: bool) -> &'static str {
    if collapsed { "Collapsed" } else { "Expanded" }
}

/// The zero-state line: a hint before anything is typed, a verdict once something was.
///
/// The distinction is the whole point of having two — "No results." under an empty field would
/// report a failure nobody asked for.
#[must_use]
pub fn empty_state_line(query: &str) -> &'static str {
    if is_blank(query) {
        "Search every tab’s scrollback."
    } else {
        "No results."
    }
}

/// The `N results — M tabs` line, or `None` when there is nothing to count yet.
///
/// Gated on a NON-EMPTY query rather than on non-empty results: a blank field with a stale result
/// set behind it would otherwise print a count for a search the user has cleared. `counted` is
/// `false` when no search has run at all, which is a different fact from a search that found
/// nothing.
#[must_use]
pub fn summary(counted: bool, total_matches: u32, tab_count: u32, query: &str) -> Option<String> {
    if !counted || is_blank(query) {
        return None;
    }
    Some(format!("{total_matches} results — {tab_count} tabs"))
}

/// Where the matched run starts and ends in `excerpt`, as UTF-8 byte offsets.
///
/// `low` and `high` arrive as UTF-16 offsets, pre-clamped into the excerpt's bounds by the search
/// controller. `None` is the FLAT excerpt: the whole line drawn in the supporting ink with nothing
/// marked, which is what a renderer already does for an empty middle run, so it needs no flag of
/// its own at either call site.
///
/// Four ways to reach it, and all four are the same answer — a range that cannot be placed marks
/// nothing:
///
/// - an offset past the end of the excerpt,
/// - an offset landing INSIDE a surrogate pair, which names no character position,
/// - a `high` before its `low`,
/// - an excerpt whose UTF-16 length the offsets simply do not fit.
#[must_use]
pub fn excerpt_cuts(excerpt: &str, low: usize, high: usize) -> Option<(usize, usize)> {
    if high < low {
        return None;
    }
    let (mut low_byte, mut high_byte) = (None, None);
    let mut units = 0_usize;
    for (byte, character) in excerpt.char_indices() {
        if units == low {
            low_byte = Some(byte);
        }
        if units == high {
            high_byte = Some(byte);
        }
        units += character.len_utf16();
    }
    // The end of the string is a position too — both Swift's `endIndex` and Rust's `len()`.
    if units == low {
        low_byte = Some(excerpt.len());
    }
    if units == high {
        high_byte = Some(excerpt.len());
    }
    Some((low_byte?, high_byte?))
}

/// Whether a query field holds nothing worth searching for.
///
/// Rust's `trim` also drops newlines, where the near side's character set counted only horizontal
/// whitespace. The widening is deliberate: a query that is one newline is not a search under either
/// reading, and the alternative is a second whitespace vocabulary maintained to disagree with the
/// standard one.
fn is_blank(query: &str) -> bool {
    query.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::{ModePill, disclosure_state, empty_state_line, excerpt_cuts, summary};

    /// The run the caller would slice out, which is what the offsets are FOR.
    fn cut(excerpt: &str, low: usize, high: usize) -> Option<&str> {
        let (low, high) = excerpt_cuts(excerpt, low, high)?;
        excerpt.get(low..high)
    }

    /// The subset is a SUBSET, and whole-word is the one the cross-tab engine cannot answer.
    #[test]
    fn the_cross_tab_search_offers_every_pill_but_whole_word() {
        assert!(!ModePill::GLOBAL_SEARCH.contains(&ModePill::WholeWord));
        assert!(ModePill::IN_PANE_FIND_BAR.contains(&ModePill::WholeWord));
        for pill in ModePill::GLOBAL_SEARCH {
            assert!(ModePill::ALL.contains(&pill));
            assert!(ModePill::offered(true) & (1 << pill.index()) != 0);
        }
        assert_eq!(ModePill::offered(true).count_ones(), 2);
        assert_eq!(ModePill::offered(false).count_ones(), 3);
    }

    #[test]
    fn only_the_whole_word_chip_is_underlined() {
        let underlined: Vec<ModePill> = ModePill::ALL
            .into_iter()
            .filter(|pill| pill.underlined())
            .collect();
        assert_eq!(underlined, vec![ModePill::WholeWord]);
        for pill in ModePill::ALL {
            assert_eq!(ModePill::from_index(pill.index()), Some(pill));
            assert!(!pill.label().is_empty() && !pill.help().is_empty());
        }
        assert_eq!(ModePill::from_index(3), None);
    }

    /// A blank field is a HINT; a field with something in it that matched nothing is a verdict.
    #[test]
    fn the_zero_state_tells_a_hint_from_a_verdict() {
        assert_eq!(empty_state_line(""), "Search every tab’s scrollback.");
        assert_eq!(empty_state_line("   "), "Search every tab’s scrollback.");
        assert_eq!(empty_state_line("let"), "No results.");
        assert_eq!(disclosure_state(true), "Collapsed");
        assert_eq!(disclosure_state(false), "Expanded");
    }

    /// A cleared field prints no count, however many results are still cached behind it.
    #[test]
    fn a_cleared_field_prints_no_count_over_a_stale_result_set() {
        assert_eq!(
            summary(true, 4, 3, "let"),
            Some(String::from("4 results — 3 tabs")),
        );
        assert_eq!(summary(true, 4, 3, "  "), None);
        assert_eq!(summary(false, 0, 0, "let"), None);
    }

    #[test]
    fn an_ascii_run_cuts_where_the_offsets_say() {
        let line = "let value = 3";
        assert_eq!(excerpt_cuts(line, 4, 9), Some((4, 9)));
        assert_eq!(cut(line, 4, 9), Some("value"));
    }

    /// A range whose ends sit on character boundaries places, even past an astral plane character
    /// that costs two UTF-16 units and four UTF-8 bytes.
    #[test]
    fn an_emoji_shifts_the_byte_offsets_without_breaking_the_cut() {
        let line = "a🙂bc";
        // UTF-16: a=1, 🙂=2, b=1 → the `b` starts at unit 3 and at byte 5.
        assert_eq!(excerpt_cuts(line, 3, 4), Some((5, 6)));
        assert_eq!(cut(line, 3, 4), Some("b"));
    }

    /// THE degradation this module exists for: an offset inside a surrogate pair marks nothing
    /// rather than trapping or guessing a run.
    #[test]
    fn an_offset_inside_a_surrogate_pair_degrades_to_a_flat_excerpt() {
        let line = "a🙂bc";
        assert_eq!(excerpt_cuts(line, 2, 4), None, "low inside the pair");
        assert_eq!(excerpt_cuts(line, 1, 2), None, "high inside the pair");
    }

    #[test]
    fn an_unplaceable_range_is_flat_whatever_made_it_unplaceable() {
        let line = "abc";
        assert_eq!(excerpt_cuts(line, 0, 3), Some((0, 3)), "the end is a position");
        assert_eq!(excerpt_cuts(line, 0, 4), None, "past the end");
        assert_eq!(excerpt_cuts(line, 9, 9), None, "both past the end");
        assert_eq!(excerpt_cuts(line, 2, 1), None, "inverted");
        assert_eq!(
            excerpt_cuts("", 0, 0),
            Some((0, 0)),
            "an empty line has one position"
        );
    }
}
