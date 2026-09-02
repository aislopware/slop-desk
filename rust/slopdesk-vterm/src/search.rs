//! Finding what the user typed in the grid, across the wraps the grid does not know it has.
//!
//! The engine ships no search at all, so this is ours — and ALL FOUR MODES are ours, which is the
//! part that changed. Case-sensitivity, whole-word and regex used to be a second scan somewhere
//! else, over a flat text mirror of the same buffer, because [`SearchQuery`] carried the first two
//! and nothing carried the third. That made the find bar's `N of M` and the cells it lit two
//! answers to one question. There is one matcher now, it lives here, and every mode goes through
//! it.
//!
//! ## Why the regex is not a backtracking one
//!
//! A ⌘F pattern is retyped on every keystroke and re-run over the whole retained buffer. A
//! backtracking engine turns one pathological pattern into a frozen find bar; the `regex` crate is
//! linear in the line. The cost is the dialect — no lookaround, no backreferences — and a pattern
//! using either simply fails to compile, which [`Matcher::new`] answers as "no matches" rather than
//! as an error. That is the same validate-then-drop an unfinished `(foo` already takes, and the
//! user is mid-typing for most of the keystrokes anyway.
//!
//! ## The whole problem is the wrap
//!
//! A terminal row is not a line. `cargo build --release --target aarch64-apple-darwin` in an 80
//! column pane occupies two rows, and a naive per-row scan finds neither `--release --target` nor
//! anything else straddling the seam. Worse, it would find nothing across the seam yet still report
//! confident results for the rest, which is the failure mode that loses trust in a search box.
//!
//! So the unit here is the **logical line**: a run of rows joined by [`FrameRow::wrapped`]. Each
//! run is flattened into one `String` alongside an index that maps every byte back to the cell it
//! came from, the literal is found in the flat text, and the hits are mapped back to grid
//! positions. A match that begins on one row and ends on the next comes back as one [`Match`] with
//! two different rows, which is exactly what a highlight needs to draw two rectangles.
//!
//! ## Why a byte-index map rather than arithmetic
//!
//! Byte offset is not column: `漢` is three bytes and two columns, `e\u{0301}` is three bytes and
//! one, and a blank cell is one byte of padding that belongs to no glyph. Any closed-form mapping
//! from one to the other is wrong for at least one of those. The index is built during the same
//! walk that builds the text, so it costs nothing extra and cannot drift from it.

use regex::{Regex, RegexBuilder};

/// A cell's position in the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CellPos {
    /// Row within whatever row slice was searched.
    pub row: u16,
    /// Column.
    pub col: u16,
}

/// One hit, in grid coordinates.
///
/// [`Self::start`] and [`Self::end`] are both inclusive cell positions, and they may sit on
/// different rows when the match crosses a soft wrap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Match {
    /// The first cell of the hit.
    pub start: CellPos,
    /// The last cell of the hit, inclusive.
    pub end: CellPos,
}

impl Match {
    /// Whether the hit straddles a soft wrap.
    #[must_use]
    pub const fn is_wrapped(self) -> bool {
        self.start.row != self.end.row
    }
}

/// What to look for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchQuery<'a> {
    /// The literal to find. An empty needle matches nothing.
    pub needle: &'a str,
    /// Whether case must match.
    ///
    /// The insensitive fold is `char::to_lowercase`, which is Unicode-correct rather than ASCII —
    /// a search for `straße` should find `STRASSE`'s neighbours in every language the terminal can
    /// print, not just in English.
    pub case_sensitive: bool,
    /// Whether the hit must be bounded by non-word characters on both sides.
    pub whole_word: bool,
    /// Whether [`Self::needle`] is a regular expression rather than a literal.
    ///
    /// Orthogonal to the other two: [`Self::case_sensitive`] becomes the pattern's own
    /// case-insensitivity flag, and [`Self::whole_word`] post-filters what the pattern found — the
    /// same composition the literal modes have, so no mode is a special case of another.
    pub regex: bool,
}

impl<'a> SearchQuery<'a> {
    /// A case-insensitive substring query, which is what a find bar starts as.
    #[must_use]
    pub const fn new(needle: &'a str) -> Self {
        Self {
            needle,
            case_sensitive: false,
            whole_word: false,
            regex: false,
        }
    }

    /// The same query, case-sensitive.
    #[must_use]
    pub const fn case_sensitive(mut self, value: bool) -> Self {
        self.case_sensitive = value;
        self
    }

    /// The same query, restricted to whole words.
    #[must_use]
    pub const fn whole_word(mut self, value: bool) -> Self {
        self.whole_word = value;
        self
    }

    /// The same query, read as a regular expression.
    #[must_use]
    pub const fn regex(mut self, value: bool) -> Self {
        self.regex = value;
        self
    }
}

/// What counts as inside a word for [`SearchQuery::whole_word`].
///
/// Alphanumerics plus `_`: the same rule readline and every editor's `\w` use, so a whole-word
/// search for `foo` finds it in `foo-bar` and not in `foo_bar`, which is what a reader expects when
/// the terminal is full of identifiers.
fn is_word(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

/// A logical line: its flattened text, and where every byte came from.
///
/// `starts` holds one entry per cell — the byte offset in `text` at which that cell's contribution
/// begins — so a byte offset maps back to a cell with one binary search rather than a rescan.
#[derive(Debug, Default)]
struct LogicalLine {
    text: String,
    folded: String,
    starts: Vec<usize>,
    cells: Vec<CellPos>,
}

impl LogicalLine {
    fn clear(&mut self) {
        self.text.clear();
        self.folded.clear();
        self.starts.clear();
        self.cells.clear();
    }

    /// The text to actually match against, folded when the query is insensitive.
    ///
    /// Folding is skipped entirely for a case-sensitive query, and the needle is folded once by the
    /// caller rather than per line.
    ///
    /// A fold that changed a character's byte length would break the index, so it is applied only
    /// where it does not: `char::to_lowercase` can produce more bytes (`İ` → `i̇`), and a line where
    /// that happens falls back to the unfolded text, which loses insensitivity for that one line
    /// rather than reporting a hit at the wrong column.
    fn haystack(&mut self, case_sensitive: bool) -> &str {
        if case_sensitive {
            return &self.text;
        }
        self.folded.clear();
        for ch in self.text.chars() {
            let mut lowered = ch.to_lowercase();
            match (lowered.next(), lowered.next()) {
                (Some(single), None) if single.len_utf8() == ch.len_utf8() => {
                    self.folded.push(single);
                },
                // Any fold that changes the byte length would shift every offset after it.
                _ => self.folded.push(ch),
            }
        }
        &self.folded
    }

    /// The cell a byte offset belongs to.
    fn cell_at(&self, offset: usize) -> Option<CellPos> {
        let index = match self.starts.binary_search(&offset) {
            Ok(exact) => exact,
            // Between two cells: the offset belongs to the earlier one, which is how a byte in the
            // middle of a multi-byte cluster resolves to the cell that owns the whole cluster.
            Err(0) => return None,
            Err(after) => after - 1,
        };
        self.cells.get(index).copied()
    }

    /// Whether the character immediately before `offset` is a word character.
    fn word_before(&self, offset: usize) -> bool {
        self.text
            .get(..offset)
            .and_then(|prefix| prefix.chars().next_back())
            .is_some_and(is_word)
    }

    /// Whether the character at `offset` is a word character.
    fn word_at(&self, offset: usize) -> bool {
        self.text
            .get(offset..)
            .and_then(|suffix| suffix.chars().next())
            .is_some_and(is_word)
    }
}

/// A [`SearchQuery`] compiled once, ready to run over line after line.
///
/// ⚠️ **Built once per QUERY and never per line.** A whole-buffer search touches thousands of
/// logical lines; folding the needle or compiling the pattern inside that loop would pay for the
/// query once per line. It is also why this is a type rather than three flags threaded through:
/// a `Regex` cannot live on [`SearchQuery`], which is `Copy` and `Eq` because callers compare
/// queries to decide whether anything needs re-running.
#[derive(Debug)]
pub struct Matcher {
    kind: Kind,
    whole_word: bool,
}

/// What the matcher actually looks for.
#[derive(Debug)]
enum Kind {
    /// A substring, and whether the haystack must be folded to find it.
    ///
    /// The needle is already folded when `case_sensitive` is `false`; the haystack fold happens per
    /// line because that is where the text is.
    Literal { needle: String, case_sensitive: bool },
    /// A compiled pattern, run over the UNFOLDED line text — the `regex` crate carries its own
    /// case-insensitivity, so there is nothing to fold and no index to keep in step.
    Pattern(Box<Regex>),
}

impl Matcher {
    /// Compiles `query`, or answers `None` when it can find nothing.
    ///
    /// `None` covers both of the states a find field passes through on the way to a real query — an
    /// empty needle, and a pattern that does not compile — because they have the same answer: no
    /// hits, no error, no highlight. A caller that distinguished them would have to spell an error
    /// path for a string the user is still typing.
    #[must_use]
    pub fn new(query: &SearchQuery<'_>) -> Option<Self> {
        if query.needle.is_empty() {
            return None;
        }
        let kind = if query.regex {
            Kind::Pattern(Box::new(
                RegexBuilder::new(query.needle)
                    .case_insensitive(!query.case_sensitive)
                    .build()
                    .ok()?,
            ))
        } else {
            // The haystack fold is length-preserving by construction, so a needle whose own fold
            // changes length could never be found in it. Such a needle is matched literally
            // instead: the search loses insensitivity for that one query rather than reporting a
            // hit at a wrong column.
            let lowered = query.needle.to_lowercase();
            if query.case_sensitive || lowered.len() != query.needle.len() {
                Kind::Literal {
                    needle: query.needle.to_owned(),
                    case_sensitive: true,
                }
            } else {
                Kind::Literal {
                    needle: lowered,
                    case_sensitive: false,
                }
            }
        };
        Some(Self {
            kind,
            whole_word: query.whole_word,
        })
    }

    /// Whether `text` is worth walking cell by cell.
    ///
    /// The cheap half of the two-pass scan [`crate::screen::VtScreen::search_screen`] documents: a
    /// bulk-rendered line is tested here, and only a line that answers `true` pays for the cell
    /// walk. A regex has no cheaper prefilter than itself, so in that mode this IS the pattern —
    /// still worth it, because the walk it skips is the expensive side by orders of magnitude.
    #[must_use]
    pub fn might_match(&self, text: &str) -> bool {
        match &self.kind {
            Kind::Literal {
                needle,
                case_sensitive: true,
            } => text.contains(needle.as_str()),
            Kind::Literal {
                needle,
                case_sensitive: false,
            } => text.to_lowercase().contains(needle.as_str()),
            Kind::Pattern(pattern) => pattern.is_match(text),
        }
    }
}

/// A logical line assembled cell by cell by a caller that has no [`crate::frame::Frame`].
///
/// The scrollback is never rendered, so its rows have no [`FrameRow`] to search — but the wrap
/// handling, the byte-to-cell index and the whole-word rule are the same problem there as here, and
/// solving it twice is how the two answers drift. A caller walking the engine's grid feeds cells in
/// reading order through [`Self::push_cell`] and hands the result to [`search_line`]; there is no
/// second walker over rendered rows — the screen's own [`crate::screen`] search is the one caller.
///
/// The scan is reused across lines — [`Self::clear`] keeps the buffers — because a whole-buffer
/// search touches thousands of lines and each would otherwise re-allocate.
#[derive(Debug, Default)]
pub struct LineScan {
    line: LogicalLine,
}

impl LineScan {
    /// An empty scan, ready for the first cell.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Forgets the previous line, keeping its allocations.
    pub fn clear(&mut self) {
        self.line.clear();
    }

    /// Appends one cell's text at one grid position.
    ///
    /// An empty `text` contributes a single space, for the reason [`LogicalLine::push_row`] gives:
    /// a search for `foo bar` must find text laid out with a literal gap. A wide cell's trailing
    /// spacer must simply not be pushed — the caller knows which cells those are, and pushing one
    /// would put a phantom blank inside a CJK word.
    pub fn push_cell(&mut self, text: &str, at: CellPos) {
        let text = if text.is_empty() { " " } else { text };
        self.line.starts.push(self.line.text.len());
        self.line.cells.push(at);
        self.line.text.push_str(text);
    }

    /// Whether nothing has been pushed since the last [`Self::clear`].
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.line.cells.is_empty()
    }
}

/// Every hit of `matcher` in one caller-assembled line, in reading order.
///
/// Positions come back in whatever row space the caller pushed. [`CellPos::row`] is a `u16`, so a
/// scrollback walker pushes each row's offset WITHIN the line — at most a screenful — and adds the
/// line's own first row on the way out.
///
/// A [`Matcher`] rather than a [`SearchQuery`] because this is the per-LINE call: the buffer walker
/// that drives it holds thousands of lines and one query.
#[must_use]
pub fn search_line(scan: &mut LineScan, matcher: &Matcher) -> Vec<Match> {
    if scan.is_empty() {
        return Vec::new();
    }
    let mut hits = Vec::new();
    collect(&mut scan.line, matcher, &mut hits);
    hits
}

/// Finds every non-overlapping hit in one logical line, as half-open byte ranges.
///
/// The ranges come out before any cell is touched because the literal path borrows the line's fold
/// to find them, and that borrow must end before the word-boundary checks read the UNFOLDED text.
/// A word boundary is the same under either casing, so reading the unfolded text is not an
/// approximation — it is the only text whose offsets both halves agree on.
fn spans(line: &mut LogicalLine, matcher: &Matcher) -> Vec<(usize, usize)> {
    match &matcher.kind {
        Kind::Literal {
            needle,
            case_sensitive,
        } => {
            let haystack = line.haystack(*case_sensitive);
            let mut found = Vec::new();
            let mut cursor = 0_usize;
            while let Some(relative) = haystack.get(cursor..).and_then(|rest| rest.find(needle.as_str())) {
                let at = cursor + relative;
                let end = at + needle.len();
                found.push((at, end));
                // Advance past the whole hit so overlapping occurrences of `aa` in `aaa` report
                // once, which is what a find bar's "next" walks through.
                cursor = end;
            }
            found
        },
        // An empty match is not a hit: `a*` matches the gap before every character, and reporting
        // those would put a zero-width highlight on every cell in the line.
        Kind::Pattern(pattern) => {
            pattern
                .find_iter(&line.text)
                .filter(|hit| hit.start() != hit.end())
                .map(|hit| (hit.start(), hit.end()))
                .collect()
        },
    }
}

/// Finds every non-overlapping hit in one logical line, in grid coordinates.
fn collect(line: &mut LogicalLine, matcher: &Matcher, hits: &mut Vec<Match>) {
    for (at, end) in spans(line, matcher) {
        if matcher.whole_word && (line.word_before(at) || line.word_at(end)) {
            continue;
        }
        let last = end.saturating_sub(1);
        let (Some(start), Some(end)) = (line.cell_at(at), line.cell_at(last)) else {
            continue;
        };
        hits.push(Match { start, end });
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CellPos, LineScan, Match, Matcher, SearchQuery, search_line};
    use crate::frame::{CellFlags, FrameCell, FrameRow};

    /// Every hit of `query` in `rows`, joined across soft wraps the way the screen walker joins
    /// them: one [`LineScan`] per logical line, fed cell by cell with the wide tails skipped, then
    /// [`search_line`]. The rows are the fixture; the API under test is the one `screen.rs` calls.
    fn search_rows(rows: &[FrameRow], query: &SearchQuery<'_>) -> Vec<Match> {
        let Some(matcher) = Matcher::new(query) else {
            return Vec::new();
        };
        let mut hits = Vec::new();
        let mut scan = LineScan::new();
        let mut start = 0_usize;
        while start < rows.len() {
            scan.clear();
            let mut end = start;
            while let Some(row) = rows.get(end) {
                for (x, cell) in row.cells.iter().enumerate() {
                    if cell.flags.contains(CellFlags::WIDE_TAIL) || cell.flags.contains(CellFlags::WIDE_HEAD)
                    {
                        continue;
                    }
                    scan.push_cell(row.cell_text(*cell), CellPos {
                        row: u16::try_from(end).unwrap_or(u16::MAX),
                        col: u16::try_from(x).unwrap_or(u16::MAX),
                    });
                }
                end += 1;
                if !row.wrapped {
                    break;
                }
            }
            hits.extend(search_line(&mut scan, &matcher));
            start = end.max(start + 1);
        }
        hits
    }

    /// A row whose cells are one character each, as an ASCII line would be.
    fn row(text: &str, wrapped: bool) -> FrameRow {
        let mut row = FrameRow {
            wrapped,
            ..FrameRow::default()
        };
        for ch in text.chars() {
            let mut buf = [0_u8; 4];
            let piece = ch.encode_utf8(&mut buf);
            row.push_cell(if piece == " " { "" } else { piece }, FrameCell::default());
        }
        row
    }

    #[test]
    fn a_literal_is_found_at_its_column() {
        let rows = [row("the cat sat", false)];
        let hits = search_rows(&rows, &SearchQuery::new("cat"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].start, CellPos { row: 0, col: 4 });
        assert_eq!(hits[0].end, CellPos { row: 0, col: 6 });
        assert!(!hits[0].is_wrapped());
    }

    #[test]
    fn a_match_across_a_soft_wrap_is_one_hit_on_two_rows() {
        let rows = [row("cargo bui", true), row("ld --release", false)];
        let hits = search_rows(&rows, &SearchQuery::new("build"));
        assert_eq!(hits.len(), 1, "the seam is invisible to the search");
        assert_eq!(hits[0].start, CellPos { row: 0, col: 6 });
        assert_eq!(hits[0].end, CellPos { row: 1, col: 1 });
        assert!(hits[0].is_wrapped());
    }

    #[test]
    fn an_unwrapped_row_boundary_does_not_join() {
        let rows = [row("cargo bui", false), row("ld --release", false)];
        assert!(
            search_rows(&rows, &SearchQuery::new("build")).is_empty(),
            "two separate lines are not one line"
        );
    }

    #[test]
    fn case_is_ignored_by_default_and_honoured_on_request() {
        let rows = [row("Error: Failed", false)];
        assert_eq!(search_rows(&rows, &SearchQuery::new("error")).len(), 1);
        assert!(search_rows(&rows, &SearchQuery::new("error").case_sensitive(true)).is_empty());
        assert_eq!(
            search_rows(&rows, &SearchQuery::new("Error").case_sensitive(true)).len(),
            1
        );
    }

    #[test]
    fn whole_word_rejects_a_hit_inside_an_identifier() {
        let rows = [row("foo foobar foo_bar foo-bar", false)];
        let hits = search_rows(&rows, &SearchQuery::new("foo").whole_word(true));
        assert_eq!(hits.len(), 2, "the bare one and the hyphenated one");
        assert_eq!(hits[0].start.col, 0);
        assert_eq!(hits[1].start.col, 19, "foo-bar, because `-` is not a word char");
    }

    #[test]
    fn blanks_are_searchable_as_spaces() {
        let rows = [row("a  b", false)];
        let hits = search_rows(&rows, &SearchQuery::new("a  b"));
        assert_eq!(hits.len(), 1, "the gap the user sees is the gap they can search");
    }

    #[test]
    fn overlapping_occurrences_report_once_each() {
        let rows = [row("aaaa", false)];
        let hits = search_rows(&rows, &SearchQuery::new("aa"));
        assert_eq!(hits.len(), 2, "positions 0 and 2, not 0, 1 and 2");
        assert_eq!(hits[0].start.col, 0);
        assert_eq!(hits[1].start.col, 2);
    }

    #[test]
    fn an_empty_needle_matches_nothing() {
        let rows = [row("anything", false)];
        assert!(search_rows(&rows, &SearchQuery::new("")).is_empty());
    }

    #[test]
    fn a_wide_cells_tail_does_not_shift_the_columns_after_it() {
        let mut row = FrameRow::default();
        row.push_cell("漢", FrameCell {
            flags: CellFlags::WIDE,
            ..FrameCell::default()
        });
        row.push_cell("", FrameCell {
            flags: CellFlags::WIDE_TAIL,
            ..FrameCell::default()
        });
        row.push_cell("x", FrameCell::default());

        let hits = search_rows(&[row], &SearchQuery::new("x"));
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].start,
            CellPos { row: 0, col: 2 },
            "the column is the grid's, not the byte offset's"
        );
    }

    #[test]
    fn a_multi_byte_cluster_is_found_at_its_own_cell() {
        let mut row = FrameRow::default();
        row.push_cell("e\u{0301}", FrameCell::default());
        row.push_cell("t", FrameCell::default());
        row.push_cell("e", FrameCell::default());

        let hits = search_rows(&[row], &SearchQuery::new("te"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].start, CellPos { row: 0, col: 1 });
        assert_eq!(hits[0].end, CellPos { row: 0, col: 2 });
    }

    #[test]
    fn hits_come_back_in_reading_order() {
        let rows = [row("x", false), row("x", false), row("x", false)];
        let hits = search_rows(&rows, &SearchQuery::new("x"));
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].start.row, 0);
        assert_eq!(hits[1].start.row, 1);
        assert_eq!(hits[2].start.row, 2);
    }

    #[test]
    fn a_run_of_three_wrapped_rows_is_one_line() {
        let rows = [row("ab", true), row("cd", true), row("ef", false)];
        let hits = search_rows(&rows, &SearchQuery::new("bcde"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].start, CellPos { row: 0, col: 1 });
        assert_eq!(hits[0].end, CellPos { row: 2, col: 0 });
    }

    // The regex mode, which is the half that used to be a second scan somewhere else.

    #[test]
    fn a_pattern_finds_what_no_literal_could() {
        let rows = [row("error 42 warn 7", false)];
        let hits = search_rows(&rows, &SearchQuery::new(r"\d+").regex(true));
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].start.col, 6);
        assert_eq!(hits[0].end.col, 7, "the whole run, not the first digit");
        assert_eq!(hits[1].start.col, 14);
    }

    #[test]
    fn a_pattern_spans_a_soft_wrap_like_a_literal_does() {
        let rows = [row("cargo bui", true), row("ld --release", false)];
        let hits = search_rows(&rows, &SearchQuery::new("bui.d").regex(true));
        assert_eq!(hits.len(), 1, "the seam is invisible to the pattern too");
        assert_eq!(hits[0].start, CellPos { row: 0, col: 6 });
        assert_eq!(hits[0].end, CellPos { row: 1, col: 1 });
    }

    #[test]
    fn a_pattern_that_does_not_compile_finds_nothing_rather_than_failing() {
        let rows = [row("error(", false)];
        assert!(
            search_rows(&rows, &SearchQuery::new("error(").regex(true)).is_empty(),
            "validate-then-drop: an unfinished group is a keystroke, not an error"
        );
    }

    #[test]
    fn a_pattern_that_can_match_nothing_is_not_a_hit_on_every_cell() {
        let rows = [row("abc", false)];
        assert!(
            search_rows(&rows, &SearchQuery::new("z*").regex(true)).is_empty(),
            "an empty match is the gap before a character, and a gap cannot be highlighted"
        );
    }

    #[test]
    fn the_three_modes_compose_rather_than_override_each_other() {
        let rows = [row("Cat cathode CAT", false)];
        let pattern = SearchQuery::new("ca.").regex(true);
        assert_eq!(
            search_rows(&rows, &pattern).len(),
            3,
            "case-insensitive by default, like the literal mode"
        );
        let exact = search_rows(&rows, &pattern.case_sensitive(true));
        assert_eq!(
            exact.len(),
            1,
            "case-sensitivity is the pattern's own flag, not a second filter"
        );
        assert_eq!(exact[0].start.col, 4, "only the lowercase one, inside cathode");
        let whole = search_rows(&rows, &pattern.whole_word(true));
        assert_eq!(whole.len(), 2, "the bare Cat and CAT, not the one inside cathode");
        assert_eq!(whole[0].start.col, 0);
        assert_eq!(whole[1].start.col, 12);
    }

    #[test]
    fn an_anchor_binds_to_the_logical_line_not_the_grid_row() {
        let rows = [row("ab", true), row("cd", false)];
        let hits = search_rows(&rows, &SearchQuery::new("^abc").regex(true));
        assert_eq!(hits.len(), 1, "the wrap continuation is not a fresh line start");
        assert_eq!(hits[0].end, CellPos { row: 1, col: 0 });
        assert!(
            search_rows(&rows, &SearchQuery::new("^cd").regex(true)).is_empty(),
            "row 1 is the middle of a line, so nothing starts there"
        );
    }

    #[test]
    fn a_pattern_addresses_cells_not_bytes() {
        let mut wide = FrameRow::default();
        wide.push_cell("漢", FrameCell {
            flags: CellFlags::WIDE,
            ..FrameCell::default()
        });
        wide.push_cell("", FrameCell {
            flags: CellFlags::WIDE_TAIL,
            ..FrameCell::default()
        });
        wide.push_cell("7", FrameCell::default());

        let hits = search_rows(&[wide], &SearchQuery::new(r"\d").regex(true));
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].start,
            CellPos { row: 0, col: 2 },
            "a three-byte glyph ahead of the hit must not shift its column"
        );
    }
}
