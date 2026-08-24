//! What an agent's status reads AS in the one-character status slot, and the caption beside it.
//!
//! Every surface that names ONE PANE's agent state goes through here — the sidebar's rolled-up
//! readout, the iOS toolbar glyph, and both halves of the Peek & Reply card — so they can never
//! disagree about the pane the user is watching longest.
//!
//! It is a reading rather than a drawing for the reason the design floor's native/`SwiftUI` split
//! exists: a status has to become a GLYPH and an INK, the Mac resolves those to an `NSColor` and
//! the phone to a `Color`, and the mapping from status to MEANING must be one value with two views
//! rather than two agreements. What each half keeps is the ladder lookup — two spellings of one
//! rung.
//!
//! This is not [`crate::badge`]. That one fuses four independent pane signals into the ONE slot a
//! sidebar tab row has, under a fixed precedence; this one reads a single agent status into the
//! alphabet the compact surfaces speak. They answer different questions about the same pane.

use crate::status::ClaudeStatus;

/// What an agent's status reads as in the one-character status slot.
///
/// A state edge is one character trading for another in the same mono slot, which is why this is an
/// enum of READINGS rather than of glyphs: [`Working`](Self::Working) is a drawn braille cell on
/// both platforms and the other three are characters, and a caller that switched on a glyph string
/// could not tell them apart.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Reading {
    /// An agent is present in this pane and at rest.
    Resting,
    /// Generating right now — the only reading that MOVES.
    Working,
    /// Blocked on a person: a question is waiting.
    Awaiting,
    /// The turn ended and the finish is unread.
    Done,
}

impl Reading {
    /// The discriminant a renderer maps to its own glyph, `0` being "draw nothing".
    ///
    /// The absent reading is spelled in the SAME scalar rather than beside it, because "no agent in
    /// this pane" is what the slot most often holds and a second presence flag would be a second
    /// thing for the two halves to disagree about.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Resting => 1,
            Self::Working => 2,
            Self::Awaiting => 3,
            Self::Done => 4,
        }
    }
}

/// The INK an agent's status is named in — a rung of the status vocabulary, not a colour.
///
/// Four cases and three rungs: [`Thinking`](Self::Thinking) and [`Awaiting`](Self::Awaiting) both
/// land on the warm one, and they are separate cases anyway because what keeps them apart is the
/// SILHOUETTE and the motion rather than the hue. Fusing them here would quietly make a future
/// re-tune of one re-tune the other.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Ink {
    /// No agent, or one at rest — the state that spends no colour.
    Muted,
    /// Generating.
    Thinking,
    /// An unread finish.
    Done,
    /// A question waiting on a person.
    Awaiting,
}

impl Ink {
    /// The discriminant a renderer maps to its own ladder rung.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Muted => 0,
            Self::Thinking => 1,
            Self::Done => 2,
            Self::Awaiting => 3,
        }
    }
}

/// The fixed box every reading is centred in.
///
/// The four readings have different advance widths — a `·`, a `?`, a `●` and a drawn braille cell —
/// so the BOX is what holds the layout still while a pane's state changes under it. Shared because
/// both halves must pin the same width, or the header beside the glyph would shift by a point
/// between platforms.
pub const GLYPH_BOX: f64 = 16.0;

/// The glyph reading, or `None` for "draw nothing" (no agent in this pane).
#[must_use]
pub const fn reading(status: ClaudeStatus) -> Option<Reading> {
    match status {
        ClaudeStatus::None => None,
        ClaudeStatus::Idle => Some(Reading::Resting),
        ClaudeStatus::Working => Some(Reading::Working),
        ClaudeStatus::Done => Some(Reading::Done),
        ClaudeStatus::NeedsPermission => Some(Reading::Awaiting),
    }
}

/// The ink that names the state: act-now for a waiting question, the unread-finish green for a turn
/// that ended, and the resting states spend nothing.
#[must_use]
pub const fn ink(status: ClaudeStatus) -> Ink {
    match status {
        ClaudeStatus::None | ClaudeStatus::Idle => Ink::Muted,
        ClaudeStatus::Working => Ink::Thinking,
        ClaudeStatus::Done => Ink::Done,
        ClaudeStatus::NeedsPermission => Ink::Awaiting,
    }
}

/// The Peek & Reply header's second line: the agent's word, and — only while a live inspector
/// reports one — the todo it is on.
///
/// The scent goes LAST on purpose. The line truncates at the tail, so a squeeze eats the prose
/// first, the `i/n` count second, and the status word never.
#[must_use]
pub fn caption(status: ClaudeStatus, scent: Option<&str>) -> String {
    let label = status.display_label();
    scent.map_or_else(|| label.to_owned(), |scent| format!("{label} \u{b7} {scent}"))
}

#[cfg(test)]
mod tests {
    use super::{Ink, Reading, caption, ink, reading};
    use crate::status::ClaudeStatus;

    /// Only the absent status draws nothing; every other one owns a character in the slot.
    #[test]
    fn the_empty_pane_is_the_only_one_with_no_reading() {
        let silent: Vec<ClaudeStatus> = ClaudeStatus::ALL
            .into_iter()
            .filter(|status| reading(*status).is_none())
            .collect();
        assert_eq!(silent, vec![ClaudeStatus::None]);
    }

    /// Distinct readings take distinct codes, and none of them collides with the absent `0`.
    #[test]
    fn every_reading_has_its_own_non_zero_code() {
        let mut codes: Vec<u8> = ClaudeStatus::ALL
            .into_iter()
            .filter_map(reading)
            .map(Reading::code)
            .collect();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes, vec![1, 2, 3, 4]);
    }

    /// The two resting states spend no colour; the three that want something spend three inks.
    #[test]
    fn the_resting_states_are_the_muted_ones() {
        assert_eq!(ink(ClaudeStatus::None), Ink::Muted);
        assert_eq!(ink(ClaudeStatus::Idle), Ink::Muted);
        assert_eq!(ink(ClaudeStatus::Working), Ink::Thinking);
        assert_eq!(ink(ClaudeStatus::Done), Ink::Done);
        assert_eq!(ink(ClaudeStatus::NeedsPermission), Ink::Awaiting);
    }

    /// Thinking and awaiting share a rung in the ladder but never a case here.
    #[test]
    fn thinking_and_awaiting_stay_separate_cases() {
        assert_ne!(ink(ClaudeStatus::Working), ink(ClaudeStatus::NeedsPermission));
    }

    #[test]
    fn the_caption_puts_the_status_word_first_so_a_squeeze_eats_the_scent() {
        assert_eq!(caption(ClaudeStatus::Working, None), "working");
        assert_eq!(
            caption(ClaudeStatus::Working, Some("wiring the door")),
            "working \u{b7} wiring the door",
        );
        assert_eq!(
            caption(ClaudeStatus::None, None),
            "idle",
            "never the literal word none"
        );
    }
}
