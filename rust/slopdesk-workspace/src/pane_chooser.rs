//! What a pane KIND is called, and what stands for it.
//!
//! One row per [`PaneKind`]: the title a freshly-made pane of that kind carries, the SF Symbol name
//! the chrome draws beside it, and the single key that would pick it. Three surfaces read this —
//! the tab strip's new-pane menu, the navigator column, and the store's default title — and the
//! reason it is a table rather than three `switch`es is that it already was three, and they had
//! already drifted: a kind added in one was a kind missing from another, and nothing said so.
//!
//! ## What is NOT here, and why the absence is the point
//!
//! **Whether a kind is video.** [`PaneKind::is_video`] answers that, and this table asks it rather
//! than carrying a fourth column. The Swift `PaneChooserOption` this replaces carried the boolean
//! itself and its doc admitted the duplication in the word "mirrors" — which is the shape a pair
//! takes right before it disagrees. A caller still reads `is_video` off the option, but the option
//! is now assembled from the one function that decides it.
//!
//! **The terminal's title.** It is [`FALLBACK_PANE_TITLE`], not a fresh `"Terminal"` literal, for
//! the reason that constant already gives: rename what an unnamed pane is called and a second
//! literal here would go on offering the old word in the menu while every made pane took the new
//! one. Nothing would fail. The workspace would just say two things.
//!
//! ## Total over bytes, because the far side speaks bytes
//!
//! [`option_for_byte`] folds an unknown discriminator to the terminal row, the same way
//! [`PaneKind::from_byte`] does and for the same reason: a kind this build does not know still
//! occupies a real slot, and naming it "Terminal" is a degraded row where refusing it would be a
//! hole in a menu.

use slopdesk_tree::session::PaneKind;

use crate::templates::FALLBACK_PANE_TITLE;

/// Everything a surface needs to NAME a pane kind without deriving it again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KindOption {
    /// The kind this row is about.
    pub kind: PaneKind,
    /// The title a freshly-made pane of this kind carries.
    pub title: &'static str,
    /// An SF Symbol NAME, never a loaded image — which glyph that resolves to is the renderer's.
    pub symbol: &'static str,
    /// The single lower-case key that picks this row. Unique across the table.
    pub mnemonic: char,
    /// Whether this kind rides the shared video flow and counts against the live-video cap.
    ///
    /// Filled from [`PaneKind::is_video`] by [`option_for`] — never written down per row.
    pub is_video: bool,
}

/// The presentation metadata for `kind`. Total, and exhaustive by the `match`: a new [`PaneKind`]
/// fails to compile here until it has been given a name.
#[must_use]
pub const fn option_for(kind: PaneKind) -> KindOption {
    let (title, symbol, mnemonic) = match kind {
        PaneKind::Terminal => (FALLBACK_PANE_TITLE, "apple.terminal", 't'),
        PaneKind::Desktop => ("Desktop", "display", 'd'),
    };
    KindOption {
        kind,
        title,
        symbol,
        mnemonic,
        is_video: kind.is_video(),
    }
}

/// The row a wire/FFI kind byte names, folding an unknown byte to the terminal row.
#[must_use]
pub const fn option_for_byte(byte: u8) -> KindOption {
    option_for(PaneKind::from_byte(byte))
}

#[cfg(test)]
mod tests {
    use slopdesk_tree::session::PaneKind;

    use super::{KindOption, option_for, option_for_byte};

    /// The exact strings `PaneChooserRegistry.option(for:)` shipped in Swift, which is what the two
    /// call sites that read `.title` are already drawing.
    #[test]
    fn every_kind_keeps_the_words_it_shipped_with() {
        let terminal = option_for(PaneKind::Terminal);
        assert_eq!(terminal.title, "Terminal");
        assert_eq!(terminal.symbol, "apple.terminal");
        assert_eq!(terminal.mnemonic, 't');

        let desktop = option_for(PaneKind::Desktop);
        assert_eq!(desktop.title, "Desktop");
        assert_eq!(desktop.symbol, "display");
        assert_eq!(desktop.mnemonic, 'd');
    }

    /// The column that used to be typed twice. If `is_video` is ever written down per row again,
    /// this is the test that stops agreeing with it.
    #[test]
    fn the_video_column_is_the_kinds_own_answer_and_not_a_second_one() {
        for kind in PaneKind::ALL {
            assert_eq!(
                option_for(kind).is_video,
                kind.is_video(),
                "{kind:?} — the option must not hold an opinion the kind does not"
            );
        }
    }

    /// A mnemonic that collided would pick the wrong kind silently, so the uniqueness is asserted
    /// rather than assumed.
    #[test]
    fn no_two_kinds_answer_to_the_same_key() {
        let mut seen: Vec<char> = Vec::new();
        for kind in PaneKind::ALL {
            let mnemonic = option_for(kind).mnemonic;
            assert!(
                mnemonic.is_ascii_lowercase(),
                "{kind:?} — a mnemonic is one lower-case key"
            );
            assert!(!seen.contains(&mnemonic), "{mnemonic:?} names two kinds");
            seen.push(mnemonic);
        }
    }

    /// Every kind has a row, and none of them is blank — the property the exhaustive `match` buys
    /// and the reason the function has no `Option` in its signature.
    #[test]
    fn the_table_is_total_and_says_something_for_every_row() {
        for kind in PaneKind::ALL {
            let KindOption {
                title,
                symbol,
                kind: back,
                ..
            } = option_for(kind);
            assert_eq!(back, kind, "a row names its own kind");
            assert!(!title.is_empty());
            assert!(!symbol.is_empty());
        }
    }

    /// A byte from a build that knows a kind this one does not still draws a row.
    #[test]
    fn an_unknown_byte_reads_as_the_terminal_row() {
        assert_eq!(option_for_byte(0), option_for(PaneKind::Terminal));
        assert_eq!(option_for_byte(1), option_for(PaneKind::Desktop));
        assert_eq!(option_for_byte(7), option_for(PaneKind::Terminal));
        assert_eq!(option_for_byte(255), option_for(PaneKind::Terminal));
    }
}
