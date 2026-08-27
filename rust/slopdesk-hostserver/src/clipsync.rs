//! The two clipboard-sync verbs: write the client's clip onto the host board, read the host's back.
//!
//! `HostClipboardPerformer.swift` (129) plus the `AppKit` half of
//! `PasteboardClip.swift` (the `#if canImport(AppKit)` arm, ~70
//! lines). Neither is host work: the codec is [`slopdesk_wire::metadata::codec`] and the board is
//! `slopdesk_apple_pasteboard`. What the Swift added is the four rules below, and they are what
//! this module is.
//!
//! ## The four rules, said once
//!
//! 1. **Image before text.** An app that copies a picture usually declares a text flavour too — its
//!    caption, or its source URL. Taking the text would silently downgrade the paste, so the image
//!    IS the clip whenever there is one. PNG as declared, else the TIFF transcoded, else text.
//! 2. **The cap is the codec's.** [`MAX_CLIPBOARD_CONTENT_BYTES`] is checked here and typed nowhere
//!    else; an over-cap clip is dropped rather than truncated, because half an image is not a
//!    smaller image.
//! 3. **A file copy never ships.** A path on the host means nothing on the client, so a board
//!    declaring `NSPasteboardTypeFileURL` answers "nothing to send" — taken from the DECLARED
//!    types, which costs no content read.
//! 4. **The echo guard.** After a successful set, the resulting change count is remembered; a read
//!    that finds the board still at that count answers count-only instead of shipping the client's
//!    own clip straight back. The client holds the mirror-image guard, so a bounce needs BOTH ends
//!    to fail.
//!
//! ## The asymmetry that is a product decision, not a bug
//! The CLIENT refuses to push a CONCEALED clip — what a password manager marks with
//! `org.nspasteboard.ConcealedType`. The HOST does not refuse to ship one back on a read. That
//! asymmetry predates the shared reader and `PasteboardClip`'s own header preserves it deliberately
//! as a named parameter rather than closing it in a refactor. It is preserved here for the same
//! reason, in the same shape: [`Clipboard::read_clip`] takes `skipping_concealed`, and the verb-16
//! path passes `false`.
//!
//! ## Host-global, not pane-scoped
//! The pasteboard is machine state: whichever pane's channel carries the request, the effect and
//! the answer are the same. So the echo guard is one `Mutex<Option<i64>>` on this performer, not
//! per-session state — the same singleton shape the Swift used, for the same reason.

use std::sync::{Mutex, PoisonError};

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    CLIPBOARD_BASELINE_PROBE, ClipboardClip, ClipboardKind, MAX_CLIPBOARD_CONTENT_BYTES,
    decode_clipboard_read_request, decode_clipboard_set, encode_clipboard_read_response,
};

/// The system board, as the two rules above need to see it.
///
/// Five methods, each one board operation. `declared` is what makes the file-copy and concealed
/// refusals free — they are answered from what the writer SAID it has, so no content crosses to
/// decide them.
pub trait Clip: Send + Sync + core::fmt::Debug {
    /// The board's change counter, which advances on every write by anybody.
    fn change_count(&self) -> i64;

    /// Every type the current owner declared, as raw UTI strings.
    fn declared(&self) -> Vec<String>;

    /// The board's plain-text flavour, or `None`.
    fn text(&self) -> Option<String>;

    /// The board's PNG bytes: the declared PNG flavour, else its TIFF transcoded, else `None`.
    ///
    /// One method rather than two because the transcode is the board's own fidelity contract and
    /// not a decision this module makes — `slopdesk_apple_pasteboard` owns both halves and answers
    /// the one question the rule above asks: is there an image here, as PNG?
    fn png(&self) -> Option<Vec<u8>>;

    /// Replaces the board with `text`; `false` — board UNTOUCHED — when it will not write.
    fn write_text(&self, text: &str) -> bool;

    /// Replaces the board with a PNG; `false` — board UNTOUCHED — when the bytes will not decode.
    fn write_png(&self, png: &[u8]) -> bool;
}

/// The performer for [`MetadataVerb::SetClipboard`] and [`MetadataVerb::ReadClipboard`].
#[derive(Debug)]
pub struct Clipboard<B> {
    board: B,
    /// The change count the LAST client push produced, or `None` before there has been one.
    ///
    /// Behind a lock because metadata requests run on per-session executors, so two panes' requests
    /// genuinely race. The lock covers one `Option<i64>` and is never held across a board call.
    last_client_set: Mutex<Option<i64>>,
}

impl<B: Clip> Clipboard<B> {
    /// A performer over `board`, with no push remembered yet.
    #[must_use]
    pub const fn new(board: B) -> Self {
        Self {
            board,
            last_client_set: Mutex::new(None),
        }
    }

    /// Verb 15. `error` on a malformed / over-cap payload, an unknown kind byte, non-UTF-8 text or
    /// PNG bytes that will not decode; `ok` after the write, with the new count remembered.
    fn set(&self, payload: &[u8]) -> MetadataStatus {
        let Ok(clip) = decode_clipboard_set(payload) else {
            return MetadataStatus::Error;
        };
        // Validate-then-clear all the way down: the board refuses BEFORE it clears, so a garbage
        // clip off the wire cannot destroy the clip a person put there.
        let wrote = match ClipboardKind::from_byte(clip.kind_byte) {
            Some(ClipboardKind::Text) => {
                core::str::from_utf8(&clip.bytes).is_ok_and(|text| self.board.write_text(text))
            },
            Some(ClipboardKind::ImagePng) => self.board.write_png(&clip.bytes),
            // An unknown future kind — refuse, never guess.
            None => false,
        };
        if !wrote {
            return MetadataStatus::Error;
        }
        *self
            .last_client_set
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(self.board.change_count());
        MetadataStatus::Ok
    }

    /// Verb 16's response body for `last_seen`.
    ///
    /// Count-only (kind `0`) when the board is unchanged since `last_seen`, is the client's own
    /// last push, or is a baseline probe — and when there is simply nothing shippable on it.
    fn read(&self, last_seen: i64) -> Vec<u8> {
        let count = self.board.change_count();
        let is_own_push = *self
            .last_client_set
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            == Some(count);
        let unchanged = count == last_seen || last_seen == CLIPBOARD_BASELINE_PROBE || is_own_push;
        // `skipping_concealed: false` — see the module doc. The HOST ships a concealed clip where
        // the client refuses to push one, and that asymmetry is a product decision.
        let clip = if unchanged { None } else { self.read_clip(false) };
        encode_clipboard_read_response(count, clip.as_ref())
    }

    /// The board's current shippable clip, under the four rules in the module doc.
    ///
    /// `None` for an empty board, a file copy, an over-cap clip, an image that will not transcode,
    /// and — when `skipping_concealed` — a concealed one. The board is left untouched in every
    /// case.
    pub fn read_clip(&self, skipping_concealed: bool) -> Option<ClipboardClip> {
        let declared = self.board.declared();
        let has = |uti: &str| declared.iter().any(|ty| ty == uti);
        if skipping_concealed && has(CONCEALED_TYPE) {
            return None;
        }
        if has(FILE_URL_TYPE) {
            return None;
        }
        if let Some(png) = self.board.png() {
            return under_cap(ClipboardKind::ImagePng, png);
        }
        let text = self.board.text().filter(|text| !text.is_empty())?;
        under_cap(ClipboardKind::Text, text.into_bytes())
    }
}

/// The concealed-clip marker password managers set (the nspasteboard.org convention).
///
/// Typed here for [`FILE_URL_TYPE`]'s reason, and pinned by the same kind of test: this crate is
/// where the RULE lives and it must build on a machine with no `AppKit` at all.
const CONCEALED_TYPE: &str = "org.nspasteboard.ConcealedType";

/// The file-copy UTI, as `NSPasteboardTypeFileURL` spells it.
///
/// Typed here rather than reached through `slopdesk_apple_pasteboard` because this crate must
/// compile on a machine with no `AppKit`. The one place the two spellings could disagree is pinned
/// by `tests/clipsync.rs`, which asserts both against the strings `AppKit` actually declares.
const FILE_URL_TYPE: &str = "public.file-url";

/// `bytes` as a clip of `kind`, or `None` when they exceed the codec's cap.
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

impl<B: Clip> MetadataPerformer for Clipboard<B> {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        match MetadataVerb::from_byte(request.verb) {
            Some(MetadataVerb::SetClipboard) => {
                MetadataAnswer {
                    status: self.set(request.payload).as_byte(),
                    payload: Vec::new(),
                }
            },
            Some(MetadataVerb::ReadClipboard) => {
                // A truncated request is malformed → error, and the host ALWAYS replies so the
                // client's pending-request registry never hangs.
                decode_clipboard_read_request(request.payload).map_or(
                    MetadataAnswer {
                        status: MetadataStatus::Error.as_byte(),
                        payload: Vec::new(),
                    },
                    |last_seen| {
                        MetadataAnswer {
                            status: MetadataStatus::Ok.as_byte(),
                            payload: self.read(last_seen),
                        }
                    },
                )
            },
            _ => {
                MetadataAnswer {
                    status: MetadataStatus::UnsupportedVerb.as_byte(),
                    payload: Vec::new(),
                }
            },
        }
    }
}

/// The production door: this machine's general pasteboard.
///
/// Holds NOTHING. `NSPasteboard.generalPasteboard` is a process-wide singleton and re-asking for it
/// is a lookup, not an allocation — so the door is a unit struct that is trivially `Send + Sync`,
/// where a stored `Retained<NSPasteboard>` would drag `AppKit`'s thread-safety question into a type
/// this crate shares across pane executors.
#[cfg(target_os = "macos")]
#[derive(Debug, Clone, Copy)]
pub struct GeneralBoard;

#[cfg(target_os = "macos")]
impl Clip for GeneralBoard {
    fn change_count(&self) -> i64 {
        slopdesk_apple_pasteboard::Board::general().change_count()
    }

    fn declared(&self) -> Vec<String> {
        slopdesk_apple_pasteboard::Board::general().declared()
    }

    fn text(&self) -> Option<String> {
        slopdesk_apple_pasteboard::Board::general().text()
    }

    fn png(&self) -> Option<Vec<u8>> {
        slopdesk_apple_pasteboard::Board::general().png()
    }

    fn write_text(&self, text: &str) -> bool {
        slopdesk_apple_pasteboard::Board::general().write_text(text)
    }

    fn write_png(&self, png: &[u8]) -> bool {
        slopdesk_apple_pasteboard::Board::general().write_png(png)
    }
}
