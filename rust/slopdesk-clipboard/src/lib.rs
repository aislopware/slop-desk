//! The pasteboard-to-wire-clip fold, and the four rules that are all it is.
//!
//! Read `Cargo.toml`'s header for why this is a crate rather than a module in either end.
//!
//! ## The four rules, said once
//!
//! 1. **Image before text.** An app that copies a picture usually declares a text flavour too — its
//!    caption, or its source URL. Taking the text would silently downgrade the paste, so the image
//!    IS the clip whenever there is one. PNG as declared, else the TIFF transcoded, else text.
//! 2. **The cap is the codec's.** [`MAX_CLIPBOARD_CONTENT_BYTES`] is checked here and typed nowhere
//!    else; an over-cap clip is dropped rather than truncated, because half an image is not a
//!    smaller image.
//! 3. **A file copy never ships.** A path on one machine means nothing on the other, so a board
//!    declaring [`FILE_URL_TYPE`] answers "nothing to send" — taken from the DECLARED types, which
//!    costs no content read.
//! 4. **A concealed clip never leaves the machine it was copied on, on the PUSH side.** What a
//!    password manager marks with [`CONCEALED_TYPE`] is refused by [`shippable_clip`] when the
//!    caller asks for it — and the caller asks by NAME, because the two ends genuinely differ.
//!
//! ## The asymmetry that is a product decision, not a bug
//!
//! The client refuses to push a concealed clip. The host does not refuse to ship one back on a
//! `readClipboard` pull, so copying a password on the host and pulling from the client applies it
//! to the client's own board. That predates this crate and is preserved deliberately, in the shape
//! that makes it visible: `skipping_concealed` is a NAMED argument at both call sites rather than
//! two function bodies, so the difference is one word a reader can see instead of a divergence
//! nobody can.
//!
//! ## What is NOT here
//!
//! The echo guard — "a read that finds the board at the count our own last push produced answers
//! count-only" — is not a rule about a board, it is state about a conversation, and each end holds
//! its own. The host's is `slopdesk_hostserver::clipsync`'s `Mutex<Option<i64>>`; the client's is
//! the sync engine's. A shared one would need a shared session, which is the thing these two ends
//! deliberately do not have.
//!
//! Nor is the attended/unattended question. Whether a CONTENT read may happen right now is a fact
//! about the platform's paste permission and the user's gesture — UI coupling, and the one thing
//! this fold has no way to know. Callers ask [`Pasteboard::text`] and [`Pasteboard::png`] only
//! where their own platform lets them.

use slopdesk_wire::metadata::codec::{ClipboardClip, ClipboardKind, MAX_CLIPBOARD_CONTENT_BYTES};

/// The concealed-clip marker password managers set (the nspasteboard.org convention).
///
/// A string rather than a framework constant because `AppKit` has none — it is a community
/// convention — and because this crate must build on a machine with no `AppKit` at all. The one
/// place the two spellings could disagree is pinned by a test that CAN see the framework, in
/// `slopdesk-apple-pasteboard`.
pub const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The file-copy UTI, as `NSPasteboardTypeFileURL` and `UTType.fileURL` both spell it.
///
/// Typed here for [`CONCEALED_TYPE`]'s reason and pinned by the same test.
pub const FILE_URL_TYPE: &str = "public.file-url";

/// A system pasteboard, as the four rules need to see it.
///
/// Six methods, each one board operation and no decision. [`Pasteboard::declared`] is what makes
/// the file-copy and concealed refusals FREE — they are answered from what the writer SAID it has,
/// so no content crosses to decide them, and on a platform where a content read costs the user a
/// modal alert that difference is the whole feature.
pub trait Pasteboard: core::fmt::Debug {
    /// The board's change counter, which advances on every write by anybody.
    fn change_count(&self) -> i64;

    /// Every type the current owner declared, as raw UTI strings.
    fn declared(&self) -> Vec<String>;

    /// The board's plain-text flavour, or `None`.
    ///
    /// ⚠️ A CONTENT read. See the crate doc on why this fold does not decide when one is allowed.
    fn text(&self) -> Option<String>;

    /// The board's PNG bytes: the declared PNG flavour, else its TIFF transcoded, else `None`.
    ///
    /// One method rather than two because the transcode is the board's own fidelity contract and
    /// not a decision this crate makes — the framework wrapper owns both halves and answers the one
    /// question rule 1 asks: is there an image here, as PNG?
    ///
    /// ⚠️ A CONTENT read, the same way [`Pasteboard::text`] is.
    fn png(&self) -> Option<Vec<u8>>;

    /// Replaces the board with `text`; `false` — board UNTOUCHED — when it will not write.
    fn write_text(&self, text: &str) -> bool;

    /// Replaces the board with a PNG; `false` — board UNTOUCHED — when the bytes will not decode.
    fn write_png(&self, png: &[u8]) -> bool;
}

/// Whether a board declaring `declared` may have its content leave this machine.
///
/// The two refusals of rules 3 and 4 asked WITHOUT the content, which is the only way to ask them
/// on a platform that prompts for a read. A caller that already holds text somebody else read
/// attended still owes the privacy refusal, and re-reading the board to get it would spend a second
/// permission — so the refusal is a function of the DECLARED types and nothing else.
#[must_use]
pub fn is_syncable(declared: &[String]) -> bool {
    !declares(declared, CONCEALED_TYPE) && !declares(declared, FILE_URL_TYPE)
}

/// The board's current shippable clip under the four rules, or `None` when there is nothing to
/// ship.
///
/// `None` for an empty board, a file copy, an over-cap clip, an image that will not transcode, and
/// — when `skipping_concealed` — a concealed one. The board is left untouched in every case.
#[must_use]
pub fn shippable_clip<B: Pasteboard + ?Sized>(board: &B, skipping_concealed: bool) -> Option<ClipboardClip> {
    let declared = board.declared();
    if skipping_concealed && declares(&declared, CONCEALED_TYPE) {
        return None;
    }
    if declares(&declared, FILE_URL_TYPE) {
        return None;
    }
    if let Some(png) = board.png() {
        return under_cap(ClipboardKind::ImagePng, png);
    }
    let text = board.text().filter(|text| !text.is_empty())?;
    under_cap(ClipboardKind::Text, text.into_bytes())
}

/// The shippable clip for text the caller ALREADY HOLDS, or `None` when there is nothing to ship.
///
/// The attended door. A platform that refuses an unattended content read gives its push half the
/// text on the paste the user asked for, and by then re-reading the board through
/// [`shippable_clip`] would spend a permission the caller already spent. This exists so that path
/// does not type rule 2's cap a second time — it did, for one afternoon, inline in a sync engine
/// that could not see the other copies change.
///
/// Rules 3 and 4 are deliberately NOT here: the caller takes those from the declared types through
/// [`is_syncable`], which needs no content read. This door answers only what a clip made of text is
/// allowed to be.
#[must_use]
pub fn clip_of_text(text: &str) -> Option<ClipboardClip> {
    under_cap(ClipboardKind::Text, text.as_bytes().to_vec())
}

/// Writes `clip` onto `board`; `false` — board UNTOUCHED — for content that will not decode.
///
/// Validate-then-clear all the way down: every implementor refuses BEFORE it clears, so a garbage
/// clip off the wire cannot destroy the clip a person put there. An unknown future kind byte is
/// refused rather than guessed at.
#[must_use]
pub fn apply_clip<B: Pasteboard + ?Sized>(board: &B, clip: &ClipboardClip) -> bool {
    match ClipboardKind::from_byte(clip.kind_byte) {
        Some(ClipboardKind::Text) => {
            core::str::from_utf8(&clip.bytes).is_ok_and(|text| board.write_text(text))
        },
        Some(ClipboardKind::ImagePng) => board.write_png(&clip.bytes),
        None => false,
    }
}

/// Whether `declared` names `uti`.
fn declares(declared: &[String], uti: &str) -> bool {
    declared.iter().any(|ty| ty == uti)
}

/// `bytes` as a clip of `kind`, or `None` when they are empty or exceed the codec's cap.
///
/// An over-cap clip is DROPPED and not truncated: half an image is not a smaller image, and half a
/// string is not a shorter one when the cut lands mid-sequence.
fn under_cap(kind: ClipboardKind, bytes: Vec<u8>) -> Option<ClipboardClip> {
    (!bytes.is_empty() && bytes.len() <= MAX_CLIPBOARD_CONTENT_BYTES).then(|| {
        ClipboardClip {
            kind_byte: kind.as_byte(),
            bytes,
        }
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod tests {
    use std::cell::RefCell;

    use slopdesk_wire::metadata::codec::{ClipboardKind, MAX_CLIPBOARD_CONTENT_BYTES};

    use super::{
        CONCEALED_TYPE, ClipboardClip, FILE_URL_TYPE, Pasteboard, apply_clip, clip_of_text, is_syncable,
        shippable_clip,
    };

    /// A board with no framework under it: every rule in this crate is decided by what a board
    /// SAYS, so a fake that says it is the whole fixture the fold needs.
    #[derive(Debug, Default)]
    struct FakeBoard {
        declared: Vec<String>,
        text: Option<String>,
        png: Option<Vec<u8>>,
        written: RefCell<Vec<(&'static str, Vec<u8>)>>,
        /// What the next write answers. `false` is how a fake spells "these bytes will not decode".
        writes_land: bool,
    }

    impl FakeBoard {
        fn declaring(types: &[&str]) -> Self {
            Self {
                declared: types.iter().map(|ty| (*ty).to_owned()).collect(),
                writes_land: true,
                ..Self::default()
            }
        }

        fn with_text(mut self, text: &str) -> Self {
            self.text = Some(text.to_owned());
            self
        }

        fn with_png(mut self, png: &[u8]) -> Self {
            self.png = Some(png.to_vec());
            self
        }

        fn refusing_writes(mut self) -> Self {
            self.writes_land = false;
            self
        }
    }

    impl Pasteboard for FakeBoard {
        fn change_count(&self) -> i64 {
            7
        }

        fn declared(&self) -> Vec<String> {
            self.declared.clone()
        }

        fn text(&self) -> Option<String> {
            self.text.clone()
        }

        fn png(&self) -> Option<Vec<u8>> {
            self.png.clone()
        }

        fn write_text(&self, text: &str) -> bool {
            if self.writes_land {
                self.written.borrow_mut().push(("text", text.as_bytes().to_vec()));
            }
            self.writes_land
        }

        fn write_png(&self, png: &[u8]) -> bool {
            if self.writes_land {
                self.written.borrow_mut().push(("png", png.to_vec()));
            }
            self.writes_land
        }
    }

    fn text_clip(text: &str) -> ClipboardClip {
        ClipboardClip {
            kind_byte: ClipboardKind::Text.as_byte(),
            bytes: text.as_bytes().to_vec(),
        }
    }

    #[test]
    fn an_image_wins_over_the_text_declared_beside_it() {
        let board = FakeBoard::declaring(&["public.png", "public.utf8-plain-text"])
            .with_png(b"pretend png")
            .with_text("the caption nobody asked to copy");
        let clip = shippable_clip(&board, true).expect("a board with an image has a clip");
        assert_eq!(
            clip.kind_byte,
            ClipboardKind::ImagePng.as_byte(),
            "rule 1: the image is the fidelity ceiling, so taking the caption downgrades the paste",
        );
    }

    #[test]
    fn text_ships_when_there_is_no_image() {
        let board = FakeBoard::declaring(&["public.utf8-plain-text"]).with_text("hello");
        let clip = shippable_clip(&board, true).expect("text is a clip");
        assert_eq!(clip.kind_byte, ClipboardKind::Text.as_byte());
        assert_eq!(clip.bytes, b"hello");
    }

    #[test]
    fn a_file_copy_never_ships_even_when_it_declares_text_too() {
        let board = FakeBoard::declaring(&[FILE_URL_TYPE, "public.utf8-plain-text"])
            .with_text("/Users/someone/secret.txt");
        assert!(
            shippable_clip(&board, false).is_none(),
            "rule 3: a path on one machine means nothing on the other, and the refusal must hold even where \
             the concealed one is not being asked for",
        );
    }

    #[test]
    fn a_concealed_clip_is_refused_only_when_the_caller_asks_for_the_refusal() {
        let board = FakeBoard::declaring(&[CONCEALED_TYPE, "public.utf8-plain-text"]).with_text("hunter2");
        assert!(
            shippable_clip(&board, true).is_none(),
            "the PUSH side refuses a password manager's clip"
        );
        assert!(
            shippable_clip(&board, false).is_some(),
            "the PULL side does not — the asymmetry is a product decision, and the named argument is what \
             makes it one word rather than a divergence",
        );
    }

    #[test]
    fn an_over_cap_clip_is_dropped_rather_than_truncated() {
        let huge = "x".repeat(MAX_CLIPBOARD_CONTENT_BYTES + 1);
        let board = FakeBoard::declaring(&["public.utf8-plain-text"]).with_text(&huge);
        assert!(
            shippable_clip(&board, true).is_none(),
            "rule 2: half a string is not a shorter one when the cut lands mid-sequence"
        );
        assert!(
            clip_of_text(&huge).is_none(),
            "the attended door takes the same cap"
        );
    }

    #[test]
    fn a_clip_exactly_at_the_cap_still_ships() {
        let exact = "x".repeat(MAX_CLIPBOARD_CONTENT_BYTES);
        let board = FakeBoard::declaring(&["public.utf8-plain-text"]).with_text(&exact);
        assert!(
            shippable_clip(&board, true).is_some(),
            "the cap is a ceiling, not an exclusive bound — an off-by-one here silently shrinks the protocol",
        );
        assert!(
            clip_of_text(&exact).is_some(),
            "and the attended door agrees with it"
        );
    }

    #[test]
    fn an_empty_board_and_an_empty_string_are_both_nothing_to_ship() {
        assert!(shippable_clip(&FakeBoard::declaring(&[]), true).is_none());
        let board = FakeBoard::declaring(&["public.utf8-plain-text"]).with_text("");
        assert!(
            shippable_clip(&board, true).is_none(),
            "a declared but empty text flavour is not a clip"
        );
        assert!(clip_of_text("").is_none());
    }

    #[test]
    fn syncability_is_answered_from_the_declared_types_alone() {
        assert!(is_syncable(&["public.utf8-plain-text".to_owned()]));
        assert!(!is_syncable(&[CONCEALED_TYPE.to_owned()]));
        assert!(!is_syncable(&[FILE_URL_TYPE.to_owned()]));
        assert!(
            is_syncable(&[]),
            "an empty board discloses nothing and refuses nothing — `shippable_clip` is what answers that \
             there is no clip on it",
        );
    }

    #[test]
    fn applying_a_text_clip_writes_it() {
        let board = FakeBoard::declaring(&[]);
        assert!(apply_clip(&board, &text_clip("landed")));
        assert_eq!(board.written.borrow().as_slice(), [("text", b"landed".to_vec())]);
    }

    #[test]
    fn applying_non_utf8_text_refuses_without_touching_the_board() {
        let board = FakeBoard::declaring(&[]);
        let clip = ClipboardClip {
            kind_byte: ClipboardKind::Text.as_byte(),
            bytes: vec![0xFF, 0xFE],
        };
        assert!(!apply_clip(&board, &clip), "text that is not UTF-8 is not text");
        assert!(
            board.written.borrow().is_empty(),
            "a refused clip must not have cleared what a person put on the board"
        );
    }

    #[test]
    fn an_unknown_future_kind_is_refused_rather_than_guessed_at() {
        let board = FakeBoard::declaring(&[]);
        let clip = ClipboardClip {
            kind_byte: 0xEE,
            bytes: b"whatever this is".to_vec(),
        };
        assert!(!apply_clip(&board, &clip));
        assert!(board.written.borrow().is_empty());
    }

    #[test]
    fn a_board_that_refuses_the_write_is_reported_as_a_refusal() {
        let board = FakeBoard::declaring(&[]).refusing_writes();
        assert!(
            !apply_clip(&board, &text_clip("nope")),
            "the fold reports what the board answered — this is how a caller tells `those bytes were not an \
             image` from `it is on the clipboard`",
        );
    }
}
