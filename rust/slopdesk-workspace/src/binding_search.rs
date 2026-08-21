//! Which keybinding rows a search query keeps.
//!
//! ## Why this is not [`crate::settings_rows::matches`]
//!
//! Same rule, different table, and the difference is where the table lives. A settings row is DATA
//! in this crate, so its filter reads [`crate::settings_rows::ROWS`] and answers positions in it. A
//! keybinding row is not: `WorkspaceBindingRegistry` writes the title, the keywords and the symbol
//! as Swift literals beside the `WorkspaceAction` case each row routes to, and moving those here
//! would put a crossing in front of every cheat-sheet, menu and palette row that reads a title
//! today. So the ROWS are lent — the caller marshals its four spellings per row once into a blob
//! and this side answers which of them a query keeps.
//!
//! ## Why it crosses at all
//!
//! Because `String.contains(_: String)` is the wrong primitive and Swift has no cheap one. Measured
//! against the shipped `SlopDeskFFI.xcframework` on an M-series Mac: `"…".lowercased()` is 94ns,
//! and `contains` over the result is **825ns for a 35-byte title and 1,652ns for a 70-byte keyword
//! run** — grapheme-aware search over text that is ASCII. The same containment as a byte scan is
//! 29ns and 53ns. Four spellings across eighty-five rows is 415µs per keystroke in the keybindings
//! editor, of which ~210µs survives after every door on that path is memoized away, and all of it
//! is that one call. One crossing and a byte scan is ~5µs.
//!
//! ## The fold, and why the fast path cannot disagree with the slow one
//!
//! A row matches when ANY of its spellings contains the query, case-folded — the same sentence
//! [`crate::settings_rows`] applies to its four fields. Three of a binding's spellings are ASCII
//! (the title, the keyword run, the `cmd+shift+t` canonical) and one is not (the `⌘⇧T` glyph), so
//! the fold takes an ASCII byte path when both sides are ASCII and Unicode's when either is not.
//! The two agree by construction — Unicode simple lowercasing IS ASCII lowercasing over ASCII — and
//! `the_two_folds_agree_wherever_both_apply` pins it rather than leaving it asserted here.
//!
//! GOLDEN-SAFE: a filter. Nothing here reads or writes a value or touches a wire codec.

/// A record whose length prefix ran past the end of the blob, or whose bytes are not UTF-8.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MalformedRecords;

/// The rows `query` keeps, as POSITIONS in `records`.
///
/// `records` is `[u32 count]` followed by `count` records, each `[u8 field_count]` followed by that
/// many `[u32 len][len bytes]` fields. Little-endian, because the only caller is an Apple silicon
/// process handing bytes to itself.
///
/// An empty (or blank) query keeps everything, in order — a search box that has not been typed into
/// is not a filter. A malformed blob is refused WHOLE rather than matched as far as it parsed: a
/// keybindings list that silently drops its tail is worse than one that draws nothing, because only
/// the second is visible.
///
/// # Errors
/// [`MalformedRecords`] when a length prefix runs past the end of the blob or a field is not UTF-8.
pub fn matches(query: &str, records: &[u8]) -> Result<Vec<usize>, MalformedRecords> {
    let rows = parse(records)?;
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Ok((0..rows.len()).collect());
    }
    Ok(rows
        .iter()
        .enumerate()
        .filter(|(_, fields)| fields.iter().any(|field| contains_folded(field, &needle)))
        .map(|(index, _)| index)
        .collect())
}

/// Whether `haystack` contains `needle`, which is ALREADY trimmed and lowercased.
///
/// Public because the fold is the rule, and a test that could only reach it through the blob would
/// be pinning the reader rather than the rule.
#[must_use]
pub fn contains_folded(haystack: &str, needle: &str) -> bool {
    if haystack.is_ascii() && needle.is_ascii() {
        ascii_contains(haystack.as_bytes(), needle.as_bytes())
    } else {
        haystack.to_lowercase().contains(needle)
    }
}

/// Case-insensitive containment over two ASCII runs, `needle` already lowercased.
fn ascii_contains(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|window| {
        window
            .iter()
            .zip(needle)
            .all(|(h, n)| h.to_ascii_lowercase() == *n)
    })
}

/// The blob read back as one field list per row.
fn parse(records: &[u8]) -> Result<Vec<Vec<&str>>, MalformedRecords> {
    let mut cursor = Cursor(records);
    let count = cursor.length().ok_or(MalformedRecords)?;
    let mut rows = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        let fields = cursor.byte().ok_or(MalformedRecords)?;
        let mut row = Vec::with_capacity(usize::from(fields));
        for _ in 0..fields {
            let len = cursor.length().ok_or(MalformedRecords)?;
            let bytes = cursor.take(len).ok_or(MalformedRecords)?;
            row.push(core::str::from_utf8(bytes).map_err(|_| MalformedRecords)?);
        }
        rows.push(row);
    }
    Ok(rows)
}

/// A forward-only reader over the lent blob. No indexing: every read is a checked split, so a
/// hostile or truncated length is a refusal rather than a panic in a crate that denies both.
struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
    /// The next `n` bytes, or `None` when the blob is shorter than it claims.
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let (head, tail) = self.0.split_at_checked(n)?;
        self.0 = tail;
        Some(head)
    }

    /// The next little-endian `u32`, as a length.
    fn length(&mut self) -> Option<usize> {
        let word: [u8; 4] = self.take(4)?.try_into().ok()?;
        usize::try_from(u32::from_le_bytes(word)).ok()
    }

    /// The next single byte.
    fn byte(&mut self) -> Option<u8> {
        self.take(1)?.first().copied()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, and these blobs are this module's own"
    )]

    use super::{MalformedRecords, contains_folded, matches};

    /// Writes the blob the Swift side writes.
    fn blob(rows: &[&[&str]]) -> Vec<u8> {
        let mut out = u32::try_from(rows.len())
            .expect("a row count")
            .to_le_bytes()
            .to_vec();
        for row in rows {
            out.push(u8::try_from(row.len()).expect("a field count"));
            for field in *row {
                out.extend_from_slice(&u32::try_from(field.len()).expect("a field length").to_le_bytes());
                out.extend_from_slice(field.as_bytes());
            }
        }
        out
    }

    /// The four spellings a binding row crosses with, shaped like the registry's.
    const REGISTRY: [[&str; 4]; 5] = [
        [
            "Split Right",
            "split column side vertical divider new pane",
            "⌘D",
            "cmd+d",
        ],
        [
            "Split Down",
            "split row stacked horizontal divider new pane below",
            "⌘⇧D",
            "cmd+shift+d",
        ],
        ["Close Pane", "quit kill end terminate remove", "⌘W", "cmd+w"],
        ["Rename Tab", "title label name tab", "", ""],
        ["Select Pane 1", "switch jump pane tab 1", "⌘1", "cmd+1"],
    ];

    fn registry() -> Vec<u8> {
        let rows: Vec<&[&str]> = REGISTRY.iter().map(|row| &row[..]).collect();
        blob(&rows)
    }

    #[test]
    fn a_blank_query_keeps_every_row_in_order() {
        let bytes = registry();
        assert_eq!(matches("", &bytes), Ok(vec![0, 1, 2, 3, 4]));
        assert_eq!(matches("   \n\t ", &bytes), Ok(vec![0, 1, 2, 3, 4]));
    }

    #[test]
    fn a_query_narrows_across_every_spelling() {
        let bytes = registry();
        // the title
        assert_eq!(matches("close", &bytes), Ok(vec![2]));
        // the keyword run
        assert_eq!(matches("terminate", &bytes), Ok(vec![2]));
        // the glyph, which is what a user types when they mean "what is on ⌘W"
        assert_eq!(matches("⌘w", &bytes), Ok(vec![2]));
        // the canonical spelling, which is the documented search-by-chord form
        assert_eq!(matches("cmd+shift+d", &bytes), Ok(vec![1]));
        assert_eq!(matches("cmd+", &bytes), Ok(vec![0, 1, 2, 4]));
        assert_eq!(matches("no such command", &bytes), Ok(vec![]));
    }

    #[test]
    fn the_query_is_trimmed_and_case_folded_on_both_sides() {
        let bytes = registry();
        assert_eq!(matches("  CLOSE  ", &bytes), Ok(vec![2]));
        assert_eq!(matches("SpLiT", &bytes), Ok(vec![0, 1]));
        assert_eq!(matches("CMD+W", &bytes), Ok(vec![2]));
    }

    #[test]
    fn a_row_with_no_chord_still_matches_by_name() {
        let bytes = registry();
        assert_eq!(matches("rename", &bytes), Ok(vec![3]));
        // …and its two empty spellings do not make it match everything.
        assert_eq!(matches("zzz", &bytes), Ok(vec![]));
    }

    /// The ASCII fast path and the Unicode one are one rule, so wherever both apply they must
    /// answer the same. Walked over every field of every row against every prefix of every field —
    /// the fast path is chosen by the DATA, so only the data can show they diverge.
    #[test]
    fn the_two_folds_agree_wherever_both_apply() {
        let mut checked = 0;
        for row in &REGISTRY {
            for haystack in row {
                for other in REGISTRY.iter().flat_map(|r| r.iter()) {
                    for end in 0..=other.len() {
                        let Some(prefix) = other.get(..end) else { continue };
                        let needle = prefix.to_lowercase();
                        let slow = haystack.to_lowercase().contains(&needle);
                        assert_eq!(
                            contains_folded(haystack, &needle),
                            slow,
                            "{haystack:?} vs {needle:?}"
                        );
                        checked += 1;
                    }
                }
            }
        }
        assert!(checked > 1000, "the walk covered {checked} pairs");
    }

    #[test]
    fn a_truncated_length_is_refused_whole() {
        let bytes = registry();
        for cut in 1..bytes.len() {
            assert!(
                matches("split", &bytes[..cut]).is_err(),
                "a blob cut at {cut} parsed"
            );
        }
        assert_eq!(matches("split", &[]), Err(MalformedRecords));
    }

    #[test]
    fn a_field_that_is_not_utf8_is_refused_whole() {
        let mut bytes = blob(&[&["ok"]]);
        let last = bytes.len() - 1;
        bytes[last] = 0xFF;
        assert_eq!(matches("ok", &bytes), Err(MalformedRecords));
    }

    #[test]
    fn a_length_prefix_larger_than_the_blob_is_refused_rather_than_trusted() {
        let mut bytes = blob(&[&["ok"]]);
        // Claim the one field is four gigabytes long.
        bytes.splice(5..9, u32::MAX.to_le_bytes());
        assert_eq!(matches("ok", &bytes), Err(MalformedRecords));
        // …and claim there are four billion rows.
        let mut many = blob(&[&["ok"]]);
        many.splice(0..4, u32::MAX.to_le_bytes());
        assert_eq!(matches("ok", &many), Err(MalformedRecords));
    }

    #[test]
    fn a_zero_row_blob_matches_nothing_and_is_not_an_error() {
        let bytes = blob(&[]);
        assert_eq!(matches("", &bytes), Ok(vec![]));
        assert_eq!(matches("split", &bytes), Ok(vec![]));
    }
}
