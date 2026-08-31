//! What the far side PUSHED, held until the surface comes and asks for it.
//!
//! ## Why this module exists at all
//!
//! Every other door in the terminal surface is a QUESTION the view asks — how many rows, where is
//! the cursor, what is selected. The engine answers from state it already holds, so the whole FFI
//! boundary is pull-based and `docs/68` §4 can promise "no callback-registration doors". That works
//! because the questions are all about the grid, and the grid is still there when you ask.
//!
//! Two things are not about the grid, are gone the instant the parser moves on, and have no other
//! place to come from:
//!
//! - **A reply the TERMINAL owes the pty.** `CSI 6n` asks where the cursor is, `CSI c` asks what
//!   the terminal is, `CSI > q` asks its version, `OSC 10/11/4 ?` ask its colours. The engine
//!   composes each answer itself and hands it out ONCE, through [`Terminal::on_pty_write`]. There
//!   is no "what do you owe the pty" getter, because after the callback the engine owes nothing.
//!   Dropping these is not a missing feature — it is a terminal that lies about being a terminal,
//!   and vim, tmux and every prompt that probes for truecolour hang or mis-detect on it.
//! - **An OSC-52 clipboard write.** The program handed over bytes; the engine stores none of them.
//!   A clipboard is per-CLIENT, so unlike everything below there is nothing on the wire that could
//!   carry it.
//!
//! ## What deliberately is NOT here
//!
//! The bell, the OSC-9/777 desktop notification, the OSC-9;4 progress report, the OSC 0/2 title and
//! the OSC-7 working directory are all things this engine sees too. They are NOT drained here,
//! because the host already sniffs each one out of the PTY stream and sends it as its own wire
//! message, and that is the right owner for two reasons that this crate cannot fix from inside:
//!
//! - **Multiclient.** One pane can have several clients attached (`docs/45`). Host-side detection
//!   is one verdict all of them share; client-side detection is N verdicts that drift.
//! - **Replay.** `TerminalViewModel.attachSurface` re-feeds the retained output ring into a rebuilt
//!   surface so it repaints. Those bytes contain the OLD bells, the OLD progress report and the OLD
//!   notification — engine handlers would re-fire every one of them on every remount, re-beeping
//!   and re-posting things that already happened. The wire path replays nothing.
//!
//! The same argument applies to the two kept here, and the surface answers it rather than dodging
//! it: a replay's pty replies and clipboard writes are drained and DISCARDED before the live drain
//! is wired, because the replay is synchronous and there is a defined moment to do it in.
//!
//! ## The shape, and why it is still pull at the boundary
//!
//! [`EventSink`] is an `Rc<RefCell<…>>` shared between the session and the closures the engine
//! holds. The engine's handlers are `FnMut(&Terminal, …) + 'static` stored INSIDE the terminal, so
//! they cannot borrow the session that owns it; a shared cell is the only shape that fits, and `Rc`
//! is free here because `docs/68` §3 already confines the whole handle to one thread.
//!
//! The FFI boundary never sees any of that. `feed` runs the parser, the parser runs the handlers,
//! the handlers fill this sink, and `feed` returns — all synchronously, on the caller's thread. The
//! view then DRAINS, with two ordinary two-attempt doors that answer `0` on the common day where
//! nothing happened. No callback crosses the boundary, and the promise holds.
//!
//! ## Bounded, because the far side is untrusted
//!
//! A program can push a megabyte per OSC-52 and never stop. Both queues here have a ceiling and a
//! documented thing they do when full, so a view that stops draining costs bounded memory rather
//! than the process. The crate's "no panics on hostile input" guarantee is a memory guarantee too.
//!
//! [`Terminal::on_pty_write`]: libghostty_vt::terminal::Terminal::on_pty_write

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

/// The most the pty-reply queue will hold before it stops accepting bytes, in bytes.
///
/// A device-status reply is tens of bytes and a view drains after every feed, so the steady state
/// is a few hundred at most. Reaching 64 KiB means nobody is draining — a surface that was fed
/// without ever being polled — and the useful thing to do with reply number ten thousand is drop
/// it: the far side is asking questions of a terminal nobody is watching.
const PTY_REPLY_CEILING: usize = 64 * 1024;

/// The most pending clipboard writes kept.
///
/// Small on purpose. A clipboard write is something a PERSON is meant to see the result of, and a
/// program that queued nine of them while the view was away has not made nine points. The oldest is
/// dropped, so what survives is what happened most recently — which is what a person coming back
/// would expect, and also what an unbounded queue would have ended on.
const CLIPBOARD_QUEUE_CEILING: usize = 8;

/// The largest single clipboard payload kept, in bytes.
///
/// OSC-52 has no length limit in the protocol, and the pasteboard is not the place to find out what
/// a hostile program's is. Anything longer is dropped whole rather than truncated: half a clipboard
/// write is not a smaller clipboard write, it is a wrong one.
const CLIPBOARD_PAYLOAD_CEILING: usize = 512 * 1024;

/// Where a clipboard write is meant to land.
///
/// The three the engine normalises every protocol spelling into. Only [`Self::Standard`] means
/// anything on Apple platforms — there is no selection clipboard on macOS and no clipboard at all
/// on iOS besides the general pasteboard — but the distinction is carried across the boundary
/// rather than collapsed here, because deciding what a destination means belongs to the layer that
/// knows which system it is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardTarget {
    /// The system clipboard.
    Standard,
    /// The selection clipboard, which X11 has and Apple does not.
    Selection,
    /// The primary selection clipboard, likewise.
    Primary,
}

impl ClipboardTarget {
    /// The byte this crosses the FFI boundary as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Standard => 0,
            Self::Selection => 1,
            Self::Primary => 2,
        }
    }
}

/// A clipboard write the running program asked for, already decoded.
///
/// ⚠️ **Asked for, not applied.** Nothing in this crate touches a pasteboard, and nothing above it
/// may either until the user's `clipboard-write` policy has been consulted. Applying one on arrival
/// would make an "Ask" setting behave as "Allow".
#[derive(Debug, Clone)]
pub struct ClipboardWrite {
    /// Where the program wants it to land.
    pub target: ClipboardTarget,
    /// The text, base64 already undone and multipart chunks already joined by the engine.
    pub text: String,
}

/// Everything the far side pushed since the last drain.
///
/// Not `pub` in its own right: the session hands out [`EventSink`], and every field leaves through
/// a `take_*` that empties it. Nothing here is readable without also consuming it, which is what
/// makes "drained exactly once" a property of the type rather than of the caller's discipline.
#[derive(Debug, Default)]
pub(crate) struct Pending {
    pty: Vec<u8>,
    clipboard: VecDeque<ClipboardWrite>,
}

/// The sink the engine's handlers write into and the session drains.
///
/// Cloning is sharing — that is the point. The session keeps one and every registered handler keeps
/// one, and they are the same sink.
#[derive(Debug, Clone, Default)]
pub(crate) struct EventSink(Rc<RefCell<Pending>>);

impl EventSink {
    /// A fresh, empty sink.
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Records bytes the terminal owes the pty, dropping them once the queue is at its ceiling.
    ///
    /// Dropped rather than truncated: half a device-status reply is a malformed escape sequence
    /// arriving at the far side's parser, which is worse than the silence of no reply at all.
    pub(crate) fn push_pty(&self, bytes: &[u8]) {
        let mut pending = self.0.borrow_mut();
        if pending.pty.len().saturating_add(bytes.len()) > PTY_REPLY_CEILING {
            return;
        }
        pending.pty.extend_from_slice(bytes);
    }

    /// Records a clipboard write, dropping the oldest pending one when the queue is full.
    pub(crate) fn push_clipboard(&self, write: ClipboardWrite) {
        if write.text.len() > CLIPBOARD_PAYLOAD_CEILING {
            return;
        }
        let mut pending = self.0.borrow_mut();
        if pending.clipboard.len() >= CLIPBOARD_QUEUE_CEILING {
            pending.clipboard.pop_front();
        }
        pending.clipboard.push_back(write);
    }

    /// Empties the pty-reply queue into `out`, answering whether anything was there.
    ///
    /// Appends rather than replaces so a caller can gather one write across several sessions.
    pub(crate) fn take_pty(&self, out: &mut Vec<u8>) -> bool {
        let mut pending = self.0.borrow_mut();
        if pending.pty.is_empty() {
            return false;
        }
        out.append(&mut pending.pty);
        true
    }

    /// Empties the clipboard queue, oldest first.
    pub(crate) fn take_clipboard(&self) -> Vec<ClipboardWrite> {
        std::mem::take(&mut self.0.borrow_mut().clipboard).into()
    }

    /// Whether a clipboard write is waiting.
    ///
    /// Lets the encoding door answer `0` without building a frame on the common day where the
    /// program asked for nothing.
    pub(crate) fn has_clipboard(&self) -> bool {
        !self.0.borrow().clipboard.is_empty()
    }

    /// Forgets everything pending.
    ///
    /// A reset re-makes the terminal, so a reply the OLD terminal owed is a reply about state that
    /// no longer exists — sending it would answer a question with the wrong terminal's answer. The
    /// surface's replay path uses the same door for the same reason.
    pub(crate) fn clear(&self) {
        *self.0.borrow_mut() = Pending::default();
    }
}

/// The text a clipboard write means, out of the MIME representations it carries.
///
/// `text/plain` where the program offered one, and otherwise the first representation, which is the
/// rule the deleted fork's `write_clipboard_cb` used and the one upstream's own apprt uses. So the
/// MIME is what CHOOSES, and a write carrying only an image mime is still asked the question rather
/// than skipped — the program said it wanted this on a clipboard, and a mime we did not expect is
/// not by itself a reason to disbelieve it.
///
/// Then BYTES in, text out, and that conversion is the second half of the answer. An OSC 52 payload
/// is base64-decoded arbitrary data chosen by whatever is running in the pty —
/// `printf '\e]52;c;//4=\a'` decodes to `FF FE` — so the chosen representation is CHECKED, and one
/// that is not text lands as nothing. Which is where this parts company with the deleted fork,
/// deliberately: that one passed an image mime's bytes through on the reasoning that a pasteboard
/// declining them is a decline the user can see, and a silent drop is worse. The reasoning was
/// sound and the option is gone — what is downstream of here is spelled `String` the whole way, the
/// queue, the encoded frame and the pasteboard's own door, so "pass it through" means a `String`
/// whose bytes are not UTF-8. The upstream bindings used to manufacture exactly that with
/// `from_utf8_unchecked`, which is the unsoundness our pinned fork fixes by handing over `&[u8]`
/// and leaving the question here. A drop is the honest end of it.
pub(crate) fn preferred_text<'a>(mut contents: impl Iterator<Item = (&'a str, &'a [u8])>) -> Option<String> {
    let first = contents.next()?;
    if first.0 == "text/plain" {
        return as_text(first.1);
    }
    for (mime, data) in contents {
        if mime == "text/plain" {
            return as_text(data);
        }
    }
    as_text(first.1)
}

/// One representation's bytes as text, or nothing if they are not text.
fn as_text(data: &[u8]) -> Option<String> {
    core::str::from_utf8(data).ok().map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::{
        CLIPBOARD_PAYLOAD_CEILING, CLIPBOARD_QUEUE_CEILING, ClipboardTarget, ClipboardWrite, EventSink,
        PTY_REPLY_CEILING, preferred_text,
    };

    fn write(text: &str) -> ClipboardWrite {
        ClipboardWrite {
            target: ClipboardTarget::Standard,
            text: text.to_owned(),
        }
    }

    /// The whole reason the module exists: a reply pushed during a feed is still there afterwards,
    /// and leaves exactly once.
    #[test]
    fn a_pty_reply_survives_the_feed_and_drains_once() {
        let sink = EventSink::new();
        sink.push_pty(b"\x1b[2;5R");
        let mut out = Vec::new();
        assert!(sink.take_pty(&mut out));
        assert_eq!(out, b"\x1b[2;5R");
        out.clear();
        assert!(!sink.take_pty(&mut out), "a second drain finds nothing");
        assert!(out.is_empty());
    }

    /// A view that never drains costs bounded memory, and the bound is a DROP rather than a
    /// truncation — half an escape sequence is worse at the far side than none.
    #[test]
    fn a_pty_queue_nobody_drains_stops_growing_without_splitting_a_reply() {
        let sink = EventSink::new();
        let reply = vec![b'x'; 1024];
        for _ in 0..1000 {
            sink.push_pty(&reply);
        }
        let mut out = Vec::new();
        assert!(sink.take_pty(&mut out));
        assert!(out.len() <= PTY_REPLY_CEILING);
        assert_eq!(out.len() % 1024, 0, "no reply was cut in half to fit");
    }

    /// What survives a full queue is what happened most recently.
    #[test]
    fn a_full_clipboard_queue_keeps_the_newest_and_drops_the_oldest() {
        let sink = EventSink::new();
        for index in 0..CLIPBOARD_QUEUE_CEILING + 3 {
            sink.push_clipboard(write(&index.to_string()));
        }
        let drained = sink.take_clipboard();
        assert_eq!(drained.len(), CLIPBOARD_QUEUE_CEILING);
        assert_eq!(drained.first().map(|w| w.text.as_str()), Some("3"));
        assert_eq!(drained.last().map(|w| w.text.as_str()), Some("10"));
        assert!(sink.take_clipboard().is_empty(), "a second drain finds nothing");
    }

    /// A write too large to be a clipboard is dropped WHOLE — never truncated into a wrong one.
    #[test]
    fn an_oversized_clipboard_write_is_dropped_rather_than_cut_down() {
        let sink = EventSink::new();
        sink.push_clipboard(write(&"x".repeat(CLIPBOARD_PAYLOAD_CEILING + 1)));
        assert!(!sink.has_clipboard());
        sink.push_clipboard(write("small"));
        assert_eq!(sink.take_clipboard().len(), 1);
    }

    /// The cheap check the encoding door leans on, so a quiet feed builds no frame.
    #[test]
    fn a_quiet_sink_reads_as_empty_without_being_drained() {
        let sink = EventSink::new();
        assert!(!sink.has_clipboard());
        sink.push_clipboard(write("hello"));
        assert!(sink.has_clipboard());
        assert_eq!(sink.take_clipboard().len(), 1);
        assert!(!sink.has_clipboard());
    }

    /// A reset's replies belong to a terminal that no longer exists — and so does a replay's.
    #[test]
    fn a_clear_forgets_a_reply_the_old_terminal_owed() {
        let sink = EventSink::new();
        sink.push_pty(b"\x1b[2;5R");
        sink.push_clipboard(write("hello"));
        sink.clear();
        let mut out = Vec::new();
        assert!(!sink.take_pty(&mut out));
        assert!(!sink.has_clipboard());
    }

    /// `text/plain` wins wherever it appears, and a write without one still lands somewhere.
    #[test]
    fn the_preferred_representation_is_text_plain_wherever_it_sits() {
        assert_eq!(
            preferred_text([("image/png", &b"bytes"[..]), ("text/plain", b"hello")].into_iter()).as_deref(),
            Some("hello")
        );
        assert_eq!(
            preferred_text([("text/plain", &b"hello"[..])].into_iter()).as_deref(),
            Some("hello")
        );
        assert_eq!(
            preferred_text([("image/png", &b"bytes"[..])].into_iter()).as_deref(),
            Some("bytes")
        );
        assert_eq!(preferred_text(std::iter::empty()), None);
    }

    /// The bytes a hostile program picks are not text, and saying so is the whole reason this
    /// function takes bytes: `printf '\e]52;c;//4=\a'` decodes to `FF FE`, which the pinned fork
    /// hands over as bytes precisely so nobody builds a `str` out of it.
    #[test]
    fn a_representation_that_is_not_text_is_declined_rather_than_carried() {
        assert_eq!(
            preferred_text([("text/plain", &[0xFF, 0xFE][..])].into_iter()),
            None
        );
        assert_eq!(
            preferred_text([("image/png", &[0x89, 0x50, 0x4E][..])].into_iter()),
            None
        );
        // The mime rule still runs FIRST: a text/plain that is text wins over a leading
        // representation that is not, rather than the invalid one deciding the answer is nothing.
        assert_eq!(
            preferred_text([("image/png", &[0xFF, 0xFE][..]), ("text/plain", b"hello")].into_iter())
                .as_deref(),
            Some("hello")
        );
    }
}
