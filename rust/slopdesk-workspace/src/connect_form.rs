//! The Connect-to-Host form's vocabulary, and its one non-obvious rule.
//!
//! The form is a FORM on both platforms, so it takes the platform's own modal on both: an `AppKit`
//! sheet on the Mac, a `SwiftUI` `.sheet` on the phone. Neither owns a connection model — the near
//! side already holds the editable fields, the parse and the `connect()` lifecycle — so what is
//! left to share is the words, and one question asked when a connect completes: does this dismiss
//! the card?
//!
//! Every label, prompt and button title on this card was spelled TWICE, character for character,
//! with the two files' comments explaining the same layout decision in the same words. A
//! user-facing string spelled once per shell is a translation bug that has already happened.
//!
//! ## What is NOT here: the three port prompts
//!
//! They are `String(ConnectionTarget.default.port)` and its two siblings, and that is the point of
//! them. The two halves once prompted `9000` / `9001` / `9002` against a default of `7420` / `9000`
//! / `9001` — one slot off, so an emptied Port field advertised the MEDIA port as the terminal one,
//! and the two halves AGREED, which is how a duplicated literal hides a bug. Deriving them from the
//! default is what makes a prompt unable to outlive the value it quotes; spelling them here would
//! put the number back in a second place and re-open exactly that door.

/// One word on the form, in the near side's own declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Word {
    /// The card's title.
    Title,
    /// The machine field's label.
    HostLabel,
    /// Its terminal-mux port's label.
    PortLabel,
    /// The host field's prompt.
    HostPrompt,
    /// The folded disclosure over the two video ports.
    VideoPortsLabel,
    /// The media port's label.
    MediaPortLabel,
    /// The cursor port's label.
    CursorPortLabel,
    /// The confirming action.
    ConnectAction,
}

impl Word {
    /// Every word, in index order — the order one delivery carries them in.
    pub const ALL: [Self; 8] = [
        Self::Title,
        Self::HostLabel,
        Self::PortLabel,
        Self::HostPrompt,
        Self::VideoPortsLabel,
        Self::MediaPortLabel,
        Self::CursorPortLabel,
        Self::ConnectAction,
    ];

    /// What it says.
    ///
    /// The host prompt shows BOTH spellings a reader might reach for, a name and an address,
    /// because the field takes either and an example of one reads as a rule against the other.
    ///
    /// Cancel is deliberately absent: it is the platform's own word on both halves — a
    /// `keyEquivalent` on the Mac, a footer role on the phone — so respelling it here would give a
    /// system-supplied button a second, competing spelling.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::Title => "Connect to Host",
            Self::HostLabel => "Host",
            Self::PortLabel => "Port",
            Self::HostPrompt => "host.local or 10.0.0.7",
            Self::VideoPortsLabel => "Video ports",
            Self::MediaPortLabel => "Media port",
            Self::CursorPortLabel => "Cursor port",
            Self::ConnectAction => "Connect",
        }
    }
}

/// Whether a `connect()` completion should dismiss the card.
///
/// Every terminal status except a failure does. A failed connect leaves the card up with the reason
/// inline: dropping the card and leaving the reason reachable only through the status pill's
/// tooltip is a silent failure.
///
/// A live connecting/reconnecting state never reaches here — `connect()` has already resolved by
/// the time this is asked.
#[must_use]
pub const fn should_close_after_connect(failed: bool) -> bool {
    !failed
}

#[cfg(test)]
mod tests {
    use super::{Word, should_close_after_connect};

    #[test]
    fn every_word_says_something_and_no_two_say_the_same_thing() {
        let mut said: Vec<&str> = Word::ALL.iter().map(|word| word.text()).collect();
        for text in &said {
            assert!(!text.is_empty());
        }
        said.sort_unstable();
        let count = said.len();
        said.dedup();
        assert_eq!(
            said.len(),
            count,
            "two labels that read alike are one field named twice"
        );
    }

    /// The prompt's whole job: offer both spellings the field accepts.
    #[test]
    fn the_host_prompt_offers_a_name_and_an_address() {
        let prompt = Word::HostPrompt.text();
        assert!(prompt.contains(".local"), "{prompt:?}");
        assert!(prompt.contains("10.0.0.7"), "{prompt:?}");
    }

    /// A prompt is NOT a port number — the derivation stays on the near side, where the default is.
    #[test]
    fn no_word_spells_a_port() {
        for word in Word::ALL {
            let text = word.text();
            assert!(
                !text.contains("7420") && !text.contains("9000") && !text.contains("9001"),
                "{word:?} quotes a port: {text:?}",
            );
        }
    }

    #[test]
    fn only_a_failure_keeps_the_card_up() {
        assert!(should_close_after_connect(false));
        assert!(!should_close_after_connect(true));
    }
}
