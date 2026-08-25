//! The words behind every transient window-level cue, and the one place they are cut to fit.
//!
//! A notice reads `label · detail`: the label names the event in SENTENCE CASE ("Tab closed",
//! "Reply sent"), and the detail carries the actionable answer ("⇧⌘T reopens", a pane's title) and
//! is the dominant half. Between them a chord may be offered, drawn as a KEYCAP rather than as text
//! — so the notice reads `Tab closed ⇧⌘T reopens`: a sentence with a pressable object in it.
//!
//! Two things must not be decided by whichever chip is drawing. The TRUNCATION, because a
//! fixed-size capsule that outgrows its window is a layout bug that only appears on the long
//! notices nobody tests; and the SPOKEN form, because `VoiceOver` has no keycap and the chord has
//! to rejoin the sentence as plain text in the order the eye reads it. Both are here, so the
//! phone's chip and the Mac's say the same sentence and cut it in the same place.

use unicode_segmentation::UnicodeSegmentation;

/// The longest detail kept verbatim. A longer one is tail-clipped to an ellipsis at construction.
pub const DETAIL_CAP: usize = 48;

/// The detail as the chip may draw it: itself, or its head plus an ellipsis.
///
/// Cut in grapheme CLUSTERS, not scalars — the cap is about how much text FITS, and a family emoji
/// occupies one cell however many scalars it took to spell. Cutting by scalar would also be able to
/// halve a cluster, which renders as a stray combining mark rather than as a character.
///
/// The ellipsis takes one of the cap's own positions rather than being added past it, so the result
/// is never longer than the cap and the capsule's width is a fact rather than an estimate.
#[must_use]
pub fn capped(detail: &str) -> String {
    let clusters: Vec<&str> = detail.graphemes(true).collect();
    if clusters.len() <= DETAIL_CAP {
        return detail.to_owned();
    }
    let mut out: String = clusters.into_iter().take(DETAIL_CAP - 1).collect();
    out.push('…');
    out
}

/// The whole notice as ONE string, for the reader that has no keycap to press.
///
/// The chord rejoins the sentence as plain text in the reading order it is DRAWN in, and the
/// separator sits where the eye's separator sits — before the answer — so the spoken form and the
/// drawn form say the same thing in the same order. A notice that offers nothing and says nothing
/// past its label is just its label, with no dangling separator.
#[must_use]
pub fn accessibility_text(label: &str, keycap: Option<&str>, detail: &str) -> String {
    let answer = match (keycap.filter(|text| !text.is_empty()), detail) {
        (Some(keycap), "") => keycap.to_owned(),
        (Some(keycap), detail) => format!("{keycap} {detail}"),
        (None, detail) => detail.to_owned(),
    };
    if answer.is_empty() {
        label.to_owned()
    } else {
        format!("{label} · {answer}")
    }
}

#[cfg(test)]
mod tests {
    use super::{DETAIL_CAP, accessibility_text, capped};

    #[test]
    fn a_detail_that_fits_is_left_exactly_as_it_was_written() {
        assert_eq!(capped(""), "");
        assert_eq!(capped("⇧⌘T reopens"), "⇧⌘T reopens");
        let exact = "x".repeat(DETAIL_CAP);
        assert_eq!(capped(&exact), exact, "the cap itself fits");
    }

    /// The ellipsis takes one of the cap's own positions — the answer is never LONGER than the cap,
    /// which is what makes the capsule's width a fact.
    #[test]
    fn a_longer_detail_is_tail_clipped_inside_the_cap_and_not_past_it() {
        let long = "y".repeat(DETAIL_CAP + 20);
        let cut = capped(&long);
        assert_eq!(cut.chars().count(), DETAIL_CAP);
        assert!(cut.ends_with('…'));
        assert!(cut.starts_with(&"y".repeat(DETAIL_CAP - 1)));
    }

    /// Cutting by scalar could halve a cluster, which draws as a stray combining mark rather than
    /// as a character — so the cut counts what the eye counts.
    #[test]
    fn the_cut_lands_between_clusters_and_never_inside_one() {
        let long = "👨‍👩‍👧‍👦".repeat(DETAIL_CAP + 5);
        let cut = capped(&long);
        assert!(cut.ends_with('…'));
        assert_eq!(
            cut.matches('\u{200d}').count(),
            (DETAIL_CAP - 1) * 3,
            "every family kept whole"
        );
    }

    #[test]
    fn the_spoken_form_puts_the_chord_where_the_eye_reads_it() {
        assert_eq!(
            accessibility_text("Tab closed", Some("⇧⌘T"), "reopens"),
            "Tab closed · ⇧⌘T reopens",
        );
        assert_eq!(
            accessibility_text("Reply sent", None, "to slopdesk"),
            "Reply sent · to slopdesk"
        );
    }

    /// Most notices offer nothing to press, and one says nothing past its label — neither may leave
    /// the separator hanging with no answer behind it.
    #[test]
    fn a_notice_with_no_answer_is_just_its_label() {
        assert_eq!(accessibility_text("Tab closed", None, ""), "Tab closed");
        assert_eq!(accessibility_text("Tab closed", Some(""), ""), "Tab closed");
        assert_eq!(
            accessibility_text("Tab closed", Some("⇧⌘T"), ""),
            "Tab closed · ⇧⌘T"
        );
    }
}
