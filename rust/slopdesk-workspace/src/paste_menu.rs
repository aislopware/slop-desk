//! What the "Paste as Keystrokes" menu SHOWS, and when it is allowed to type at all.
//!
//! The remote-GUI pane can replay the local clipboard into the host as keystrokes. That gives the
//! menu two jobs it must not get wrong, and they pull in opposite directions: it has to show the
//! person WHICH clip they are about to type, and it must never put a credential on screen while
//! doing so.
//!
//! [`preview`] is where those two meet. A clip [`crate::secrets::looks_secret`] flags never renders
//! at all — the row says how LONG it was and nothing else, which is the same "do not echo the
//! secret" rule [`crate::secrets::redact`] applies to a title. Everything else is flattened to one
//! line and cut at [`PREVIEW_LIMIT`], because a menu row is one line whatever the clipboard holds.
//!
//! ## The two glyphs are pinned, and that is not decoration
//!
//! [`MASK_LEAD`] is four U+2022 BULLETs and [`ELLIPSIS`] is one U+2026 HORIZONTAL ELLIPSIS. Both
//! are what the Swift this replaces emitted, byte for byte. Swapping a bullet for a U+00B7 MIDDLE
//! DOT or the ellipsis for three periods changes the rendered WIDTH of every masked row and every
//! truncated one, and no build or test would fail — so the bytes are asserted in this module's
//! suite rather than left to whoever next retypes the string.
//!
//! ## Everything is counted in GRAPHEME CLUSTERS
//!
//! The Swift original counted `String.count` and cut with `index(_:offsetBy:)`, both of which walk
//! extended grapheme clusters. `chars()` would walk SCALARS, and the two disagree on exactly the
//! text a clipboard carries: a family emoji is one cluster and seven scalars, a decomposed `é` is
//! one cluster and two. Counting scalars would make the mask overstate a secret's length and the
//! truncation cut a cluster in half — which renders as a stray combining mark, not as an ellipsis.
//! So the standard's own segmentation decides where a character ends, exactly as it does in
//! [`crate::keystroke_replay`] and for the same reason.
//!
//! ## Whitespace: one rule, and the empty answer it can produce
//!
//! A clip is split on whitespace clusters and rejoined with single spaces, so a multi-line paste is
//! one row. A clip that is ONLY whitespace splits into nothing — and then the fallback is the
//! TRIMMED original, which is the empty string. That is deliberate and it is what the Swift did: a
//! row of invisible spaces reads as a rendering bug, an empty row reads as an empty clip.
//!
//! Rust's `char::is_whitespace` (Unicode `White_Space`) and Foundation's
//! `.whitespacesAndNewlines` (general category `Z*`, plus U+0009–U+000D and U+0085) are the same
//! set of scalars, so the trim lands in the same place in both languages.
//!
//! ## `can_paste` takes a FLAG and never the clipboard
//!
//! [`can_paste`] asks whether there is text, not what it is, and the signature is the whole point:
//! on iOS, reading the pasteboard's CONTENT from a renderer raises the modal "Allow Paste?" alert.
//! A caller that already holds the content because it is about to paste reduces it through
//! [`is_pastable`]; a caller deciding at render time asks a probe. There is deliberately no third
//! spelling, and no `Option<&str>` overload of this one — an enablement path that COULD take
//! content is one that eventually will.

use std::borrow::Cow;

use unicode_segmentation::UnicodeSegmentation;

use crate::secrets;

/// The four bullets a masked preview leads with: U+2022 ×4, pinned by
/// `the_masked_lead_and_the_ellipsis_are_the_bytes_the_chrome_drew`.
pub const MASK_LEAD: &str = "••••";

/// The one character an over-long preview ends with: U+2026, NOT three periods — a period run is a
/// third again as wide in the row's font.
pub const ELLIPSIS: &str = "…";

/// How many grapheme clusters of a non-secret clip survive before [`ELLIPSIS`] takes over.
pub const PREVIEW_LIMIT: usize = 48;

/// How many recent clips the ring submenu lists.
///
/// The ring itself holds more; this is the MENU's cap, because a submenu longer than a screen is a
/// scroll gesture between the person and the clip they wanted.
pub const ROW_LIMIT: usize = 12;

/// One clip as a menu row shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preview<'a> {
    /// What the row DRAWS. Never the clip itself when [`Preview::is_secret`] is set.
    pub label: Cow<'a, str>,
    /// Whether [`crate::secrets::looks_secret`] flagged the clip as a credential.
    pub is_secret: bool,
}

/// The row label for one clip, and whether it was masked to produce it.
///
/// Four answers, in the order they are decided:
///
/// * a credential — [`MASK_LEAD`], the word "hidden secret", and the CLUSTER count in parentheses.
///   The count is of the RAW clip, before any trimming, because it is a statement about what is on
///   the clipboard rather than about what would have been drawn.
/// * whitespace only — the empty string, per the module header.
/// * short enough — the flattened line, whole.
/// * too long — the first [`PREVIEW_LIMIT`] clusters and [`ELLIPSIS`].
///
/// The classification runs ONCE: the flag and the label are one answer, so a caller cannot ask the
/// classifier a second time and get a different verdict than the label it is about to draw.
#[must_use]
pub fn preview(text: &str) -> Preview<'_> {
    if secrets::looks_secret(text) {
        let clusters = text.graphemes(true).count();
        return Preview {
            label: Cow::Owned(format!("{MASK_LEAD} hidden secret ({clusters} chars)")),
            is_secret: true,
        };
    }
    let flattened = flatten(text);
    let clusters = flattened.graphemes(true).count();
    if clusters <= PREVIEW_LIMIT {
        return Preview {
            label: flattened,
            is_secret: false,
        };
    }
    let kept: String = flattened.graphemes(true).take(PREVIEW_LIMIT).collect();
    Preview {
        label: Cow::Owned(kept + ELLIPSIS),
        is_secret: false,
    }
}

/// How many rows the submenu shows for a ring of `ring_len` clips, capped at `limit`.
///
/// The cap is the rule and the ring's length is the fact, so an empty ring answers 0 — which the
/// view draws as a disabled "No recent clips" rather than as an empty menu.
#[must_use]
pub const fn row_count(ring_len: usize, limit: usize) -> usize {
    if ring_len < limit { ring_len } else { limit }
}

/// Whether the "Paste as Keystrokes" item is enabled.
///
/// Both halves, and neither is redundant: `can_paste_keystrokes` is the LIVE pane's answer
/// (streaming, with a key sink, not read-only) and `clipboard_has_text` is the clipboard's. See the
/// module header for why the second is a flag.
#[must_use]
pub const fn can_paste(can_paste_keystrokes: bool, clipboard_has_text: bool) -> bool {
    can_paste_keystrokes && clipboard_has_text
}

/// Whether `clipboard` — content already in hand — is worth typing: present, and not only
/// whitespace.
///
/// `None` and `Some("")` both answer `false`, which is why the door for this can be a plain
/// `(bytes, len)` pair: an absent clipboard and an empty one are the same nothing HERE, even though
/// they are different questions elsewhere.
#[must_use]
pub fn is_pastable(clipboard: Option<&str>) -> bool {
    clipboard.is_some_and(|text| !text.trim().is_empty())
}

/// One line out of any clip: every run of whitespace becomes a single space.
///
/// Borrows when it can, which is the whitespace-only case — the answer is then a slice of the
/// input, and the only branch here where that is true.
fn flatten(text: &str) -> Cow<'_, str> {
    let mut joined = String::with_capacity(text.len());
    for word in text.split(is_separator) {
        if word.is_empty() {
            continue;
        }
        if !joined.is_empty() {
            joined.push(' ');
        }
        joined.push_str(word);
    }
    if joined.is_empty() {
        // Nothing but whitespace, so there is nothing to join — the trimmed original is the answer
        // and it is a slice.
        return Cow::Borrowed(text.trim());
    }
    Cow::Owned(joined)
}

/// Whether one scalar separates words.
///
/// Swift asked `Character.isWhitespace || Character.isNewline`, which reads the cluster's FIRST
/// scalar; the newline half is subsumed — every newline scalar carries `White_Space` — and is
/// spelled out in the Swift only because the two properties are separate there. Splitting on
/// scalars rather than clusters is safe for exactly this predicate: no whitespace scalar combines,
/// so a whitespace scalar is always a whole cluster.
const fn is_separator(scalar: char) -> bool {
    scalar.is_whitespace()
}

#[cfg(test)]
mod tests {
    use super::{ELLIPSIS, MASK_LEAD, PREVIEW_LIMIT, ROW_LIMIT, can_paste, is_pastable, preview, row_count};

    /// The two glyphs, as BYTES. A bullet that became a middle dot or an ellipsis that became three
    /// periods changes the width of every masked and every truncated row, and nothing else in the
    /// tree would notice.
    #[test]
    fn the_masked_lead_and_the_ellipsis_are_the_bytes_the_chrome_drew() {
        assert_eq!(
            MASK_LEAD.as_bytes(),
            b"\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2"
        );
        assert_eq!(MASK_LEAD.chars().count(), 4);
        assert!(MASK_LEAD.chars().all(|glyph| glyph == '\u{2022}'));
        assert_eq!(ELLIPSIS.as_bytes(), b"\xe2\x80\xa6");
        assert_eq!(ELLIPSIS, "\u{2026}");
        assert_eq!(PREVIEW_LIMIT, 48);
        assert_eq!(ROW_LIMIT, 12);
    }

    /// Ported from `ClipboardPasteMenuTests.testPreviewMasksASecretClipAndNeverEchoesIt`. Assembled
    /// from fragments so no contiguous credential-shaped literal sits in this file, the same reason
    /// [`crate::secrets`]'s suite does it.
    #[test]
    fn a_credential_shaped_clip_is_masked_and_never_echoed() {
        let secret = ["aB3xK9mZ", "2qP7wL5n", "R8tY4vC1"].concat();
        let answer = preview(&secret);
        assert!(
            answer.is_secret,
            "a high-entropy mixed-class token is a credential"
        );
        assert!(answer.label.starts_with(MASK_LEAD), "{}", answer.label);
        assert!(
            !answer.label.contains(&secret),
            "the clip leaked: {}",
            answer.label
        );
        assert_eq!(answer.label, format!("{MASK_LEAD} hidden secret (24 chars)"));
    }

    /// Ported from `testPreviewPassesShortPlainTextThrough`.
    #[test]
    fn short_plain_text_passes_through_whole() {
        let answer = preview("hello world");
        assert!(!answer.is_secret);
        assert_eq!(answer.label, "hello world");
    }

    /// Ported from `testPreviewCollapsesNewlinesToOneLine`.
    #[test]
    fn every_run_of_whitespace_collapses_to_one_space() {
        let answer = preview("line one\nline two\n\tindented");
        assert!(!answer.is_secret);
        assert_eq!(answer.label, "line one line two indented");
        assert!(!answer.label.contains('\n'));
        // Leading and trailing runs vanish rather than becoming a leading or trailing space.
        assert_eq!(preview("  padded  ").label, "padded");
        assert_eq!(
            preview("a \u{00a0}\u{2003}b").label,
            "a b",
            "non-ASCII whitespace too"
        );
    }

    /// Ported from `testPreviewTruncatesLongText`.
    #[test]
    fn an_over_long_clip_is_cut_at_the_limit_and_ellipsized() {
        let long = "x".repeat(PREVIEW_LIMIT + 40);
        let answer = preview(&long);
        assert!(!answer.is_secret);
        assert!(answer.label.ends_with(ELLIPSIS));
        assert_eq!(
            answer.label.chars().count(),
            PREVIEW_LIMIT + 1,
            "the limit's characters, plus the one ellipsis",
        );
        // Exactly at the limit is NOT truncated — the Swift guard was `>`, not `>=`.
        let exact = "y".repeat(PREVIEW_LIMIT);
        assert_eq!(preview(&exact).label, exact);
        assert!(!preview(&exact).label.contains(ELLIPSIS));
    }

    /// The cut counts CLUSTERS, so a clip of astral characters loses no glyph to a half-scalar
    /// slice — the failure a `chars()` cut would produce is a broken cluster, never an error.
    #[test]
    fn the_cut_and_the_count_are_in_grapheme_clusters() {
        // A family emoji: one cluster, seven scalars.
        let family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}";
        assert_eq!(
            family.chars().count(),
            7,
            "precondition: this is a multi-scalar cluster"
        );
        let clip = family.repeat(PREVIEW_LIMIT + 5);
        let answer = preview(&clip);
        assert!(answer.label.ends_with(ELLIPSIS));
        assert_eq!(
            answer.label,
            format!("{}{ELLIPSIS}", family.repeat(PREVIEW_LIMIT)),
            "the cut lands on a cluster boundary",
        );
        // A decomposed é is one cluster and two scalars, and the limit must count it as one.
        let decomposed = "e\u{0301}".repeat(PREVIEW_LIMIT);
        assert_eq!(
            preview(&decomposed).label,
            decomposed,
            "48 clusters is not over the limit"
        );
    }

    /// A clip of nothing but whitespace previews as the EMPTY string, never as invisible spaces.
    #[test]
    fn a_whitespace_only_clip_previews_as_nothing() {
        for blank in ["", "   ", "\n\n", " \t \n "] {
            let answer = preview(blank);
            assert_eq!(answer.label, "", "{blank:?}");
            assert!(!answer.is_secret);
        }
    }

    /// Ported from `testRowsRespectLimitAndCarryIndexAndFullText` and
    /// `testRowsEmptyRingYieldsNoRows` — the half of `rows` that is a rule. The clip TEXT never
    /// crosses: the caller already holds the ring it asked about.
    #[test]
    fn the_row_count_is_the_ring_capped_at_the_limit() {
        assert_eq!(row_count(20, 5), 5);
        assert_eq!(row_count(3, 5), 3);
        assert_eq!(row_count(0, ROW_LIMIT), 0, "an empty ring lists nothing");
        assert_eq!(row_count(usize::MAX, ROW_LIMIT), ROW_LIMIT);
        assert_eq!(row_count(5, 0), 0);
    }

    /// Ported from `testCanPasteRequiresBothALiveSinkAndNonEmptyClipboard`.
    #[test]
    fn enablement_needs_a_live_sink_and_something_to_type() {
        assert!(can_paste(true, true));
        assert!(
            !can_paste(false, true),
            "no key sink — read-only or not streaming"
        );
        assert!(!can_paste(true, false), "nothing on the clipboard");
        assert!(!can_paste(false, false));
    }

    /// Ported from `testIsPastableRejectsMissingAndWhitespaceOnlyClips`.
    #[test]
    fn a_clip_worth_typing_is_present_and_not_only_whitespace() {
        assert!(is_pastable(Some("hi")));
        assert!(!is_pastable(None), "no clipboard");
        assert!(!is_pastable(Some("")), "an empty clipboard");
        assert!(!is_pastable(Some("   \n\t ")), "whitespace only");
        assert!(is_pastable(Some("  x  ")), "padding does not make a clip empty");
    }
}
