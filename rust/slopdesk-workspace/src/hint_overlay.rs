//! The Vimium-style Hint Mode overlay's decisions and wording.
//!
//! The MATH was already below the view before this module existed: the scan finds the spans, the
//! assigner hands out the two-letter labels and filters them against what has been typed, and the
//! cell metrics turn a cell into a rect. What was still spelled inside the `SwiftUI` overlay is
//! everything between that math and the ink — which badge is faded, which is dimmed, whether the
//! overlay is up at all, and every word it says.
//!
//! ## The per-letter fade is the piece that looks like layout and is not
//!
//! A label is two characters and the overlay draws them in two different inks — the already-typed
//! prefix faded, the rest solid — so the user can see which key is next. Said as one rule it is one
//! rule; re-derived per renderer it is a place where a half could fade the wrong letter and still
//! look plausible, because on the very common case (nothing typed yet) both spellings agree.
//!
//! The badge's plate is a FIXED yellow with BLACK text — theme-independent so it reads over any
//! terminal background, the same rationale the secure-input pill's fixed blue carries. That is a
//! token decision, so it stays with the renderers; what is here is which ink ROLE each letter
//! takes, never which colour.

/// Whether the overlay draws at all.
///
/// Three things have to hold together, and the third is the honest ceiling: a headless surface
/// reports no cell metrics, so the overlay renders NOTHING. Labels are ABSENT, never wrong — a
/// badge drawn at a guessed cell size would point at the wrong word.
///
/// The two metrics arrive as scalars rather than as an optional pair because both halves already
/// have them as scalars at the point the question is asked, and `0` is exactly what a caller with
/// no snapshot holds.
#[must_use]
pub fn is_armed(armed: bool, cell_width: f64, cell_height: f64) -> bool {
    armed && cell_width > 0.0 && cell_height > 0.0
}

/// The label AS DRAWN.
///
/// Hint labels are assigned lowercase and always shown uppercase — a two-letter badge over terminal
/// output has to be read at a glance, and mixed case at 10pt on a yellow plate is not.
#[must_use]
pub fn display_label(label: &str) -> String {
    label.to_uppercase()
}

/// Whether the character at `offset` of a label has already been typed, and so draws faded.
///
/// The comparison is against the typed prefix's LENGTH rather than against its characters: hint
/// labels are ASCII by construction, and comparing lengths keeps the rule honest for a
/// partially-typed label that no longer matches at all — those badges are dimmed as a whole by
/// [`dimmed`], and a dimmed badge showing its first letter faded is exactly the progress cue that
/// was wanted.
///
/// `typed` is counted in CHARACTERS, not bytes: the alphabet is ASCII so the two agree for every
/// label, and counting characters is the reading that stays true if a caller ever passes a stray
/// multi-byte keystroke through.
#[must_use]
pub fn is_faded(offset: usize, typed: &str) -> bool {
    offset < typed.chars().count()
}

/// Whether a badge is DIMMED: the typed prefix has ruled its label out.
///
/// Ruled-out badges are dimmed rather than removed. A label that vanished would let the eye think a
/// target had gone away, and the remaining badges would then have to be re-read from scratch after
/// every keystroke; dimmed, the field the user is scanning stays where it was.
#[must_use]
pub fn dimmed(label: &str, matched: &[&str]) -> bool {
    !matched.contains(&label)
}

/// One word the overlay says, in the near side's own declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Word {
    /// The caps word on the mode badge.
    Title,
    /// The mode badge's accessibility hint — the two ways out, said once.
    BadgeAccessibilityHint,
    /// The `×` plate's tooltip.
    ExitHelp,
}

impl Word {
    /// Every word, in index order.
    pub const ALL: [Self; 3] = [Self::Title, Self::BadgeAccessibilityHint, Self::ExitHelp];

    /// What it says.
    ///
    /// The exit tooltip names the KEY as well as the action, because the `×` is the fallback and
    /// Esc is the way the mode is actually left.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::Title => "HINTS",
            Self::BadgeAccessibilityHint => "Press a label, or Escape to exit",
            Self::ExitHelp => "Exit hint mode (Esc)",
        }
    }
}

/// What `VoiceOver` calls one badge.
#[must_use]
pub fn label_accessibility(label: &str) -> String {
    format!("Hint {}", display_label(label))
}

/// What `VoiceOver` calls the mode badge — the mode's own word, under the family name.
#[must_use]
pub fn badge_accessibility_label(intent: &str) -> String {
    format!("Hint mode {intent}")
}

#[cfg(test)]
mod tests {
    use super::{
        Word, badge_accessibility_label, dimmed, display_label, is_armed, is_faded, label_accessibility,
    };

    /// A headless surface has no cell size, and the overlay must then draw nothing at all.
    #[test]
    fn an_unmeasured_surface_never_arms() {
        assert!(is_armed(true, 7.0, 15.0));
        assert!(!is_armed(false, 7.0, 15.0));
        assert!(!is_armed(true, 0.0, 15.0));
        assert!(!is_armed(true, 7.0, 0.0));
        assert!(!is_armed(true, -1.0, 15.0));
    }

    #[test]
    fn a_label_is_always_drawn_in_caps() {
        assert_eq!(display_label("as"), "AS");
        assert_eq!(display_label("AS"), "AS");
        assert_eq!(label_accessibility("df"), "Hint DF");
    }

    /// Nothing typed is the common case, and the case where a wrong spelling would still look
    /// right.
    #[test]
    fn the_fade_walks_the_typed_prefix_one_letter_at_a_time() {
        assert!(!is_faded(0, ""));
        assert!(!is_faded(1, ""));
        assert!(is_faded(0, "a"));
        assert!(!is_faded(1, "a"));
        assert!(is_faded(0, "as"));
        assert!(is_faded(1, "as"));
        assert!(!is_faded(2, "as"));
    }

    /// A label that no longer matches still fades its typed prefix — the progress cue survives the
    /// badge being ruled out.
    #[test]
    fn a_ruled_out_badge_is_dimmed_whole_and_still_fades_its_prefix() {
        let matched = ["as"];
        assert!(!dimmed("as", &matched));
        assert!(dimmed("df", &matched));
        assert!(dimmed("df", &[]));
        assert!(is_faded(0, "a"), "the first letter still reads as typed");
    }

    #[test]
    fn every_word_says_something_distinct() {
        let mut said: Vec<&str> = Word::ALL.iter().map(|word| word.text()).collect();
        for text in &said {
            assert!(!text.is_empty());
        }
        said.sort_unstable();
        let count = said.len();
        said.dedup();
        assert_eq!(said.len(), count);
        assert_eq!(badge_accessibility_label("Open"), "Hint mode Open");
    }
}
