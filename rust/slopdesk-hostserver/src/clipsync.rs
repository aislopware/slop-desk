//! The two clipboard-sync verbs: write the client's clip onto the host board, read the host's back.
//!
//! `HostClipboardPerformer.swift` (129), and nothing more than that. The codec is
//! [`slopdesk_wire::metadata::codec`], the board is `slopdesk_apple_pasteboard`, and the four rules
//! that turn one into the other are [`slopdesk_clipboard`] — which the CLIENT reads too, because a
//! disagreement between the two ends is a drift in the protocol that no compiler sees.
//!
//! What is left here is the part that is genuinely the host's: the two verbs, and the echo guard.
//!
//! ## The echo guard
//!
//! After a successful set, the resulting change count is remembered; a read that finds the board
//! still at that count answers count-only instead of shipping the client's own clip straight back.
//! The client holds the mirror-image guard, so a bounce needs BOTH ends to fail. It is not in the
//! shared crate because it is state about a CONVERSATION rather than a rule about a board, and the
//! two ends do not share one.
//!
//! ## The asymmetry that is a product decision, not a bug
//! The CLIENT refuses to push a CONCEALED clip — what a password manager marks with
//! `org.nspasteboard.ConcealedType`. The HOST does not refuse to ship one back on a read. That
//! asymmetry is preserved as a named argument rather than two function bodies, which is why
//! [`Clipboard::read_clip`] takes `skipping_concealed` and the verb-16 path passes `false`.
//!
//! ## Host-global, not pane-scoped
//! The pasteboard is machine state: whichever pane's channel carries the request, the effect and
//! the answer are the same. So the echo guard is one `Mutex<Option<i64>>` on this performer, not
//! per-session state — the same singleton shape the Swift used, for the same reason.

use std::sync::{Mutex, PoisonError};

use slopdesk_clipboard::{Pasteboard, apply_clip, shippable_clip};
use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    CLIPBOARD_BASELINE_PROBE, ClipboardClip, decode_clipboard_read_request, decode_clipboard_set,
    encode_clipboard_read_response,
};

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

/// `Send + Sync` on top of [`Pasteboard`] because a HOST board is asked from several threads at
/// once: metadata requests run on per-session executors, so two panes' clipboard verbs genuinely
/// race. A client's own board carries no such bound, which is why the shared trait does not.
impl<B: Pasteboard + Send + Sync> Clipboard<B> {
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
        if !apply_clip(&self.board, &clip) {
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

    /// The board's current shippable clip, under [`slopdesk_clipboard`]'s four rules.
    ///
    /// `None` for an empty board, a file copy, an over-cap clip, an image that will not transcode,
    /// and — when `skipping_concealed` — a concealed one. The board is left untouched in every
    /// case.
    ///
    /// A method rather than a re-export because callers hold a performer, not a board: the board is
    /// this type's private field, and `readClipboard`'s own path needs the count beside the clip.
    pub fn read_clip(&self, skipping_concealed: bool) -> Option<ClipboardClip> {
        shippable_clip(&self.board, skipping_concealed)
    }
}

impl<B: Pasteboard + Send + Sync> MetadataPerformer for Clipboard<B> {
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
impl Pasteboard for GeneralBoard {
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
