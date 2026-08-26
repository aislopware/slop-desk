//! The pane's retained output, in the three shapes something other than a client asks for it in.
//!
//! A subscriber never comes here: it is sent the ring as sequenced frames, and the snapshot
//! renderer composes what a joiner opens on. These are for the callers that are READING the pane
//! rather than displaying it — the screen scan's rebuild, `ctl read`, `ctl last-output`, and the
//! `wait --until` predicate's regex.
//!
//! ## The host keeps no screen, so "lines" means what it can mean
//!
//! The ring holds RAW read-chunk slices, not width-aware rows, so a soft-wrapped visual row carries
//! no marker to un-wrap and true reverse-of-wrapping is impossible here. What [`logical_lines`]
//! gives an agent's regex instead is robustness to arbitrary chunk and transport boundaries: every
//! stored chunk is joined in sequence order first, so a hard line split across two reads is ONE
//! string, and only then is it split on `\n`.
//!
//! ## Stripping happens on BYTES, before any decode
//!
//! `slopdesk-sanitize`'s scanner reads the VT grammar over bytes and only ever drops whole
//! sequences and whole codepoints, so stripping first and decoding second is both cheaper and more
//! faithful than decoding a stream full of escapes and stripping the result. What survives is valid
//! UTF-8 by construction; the lossy decode is for the input's own truncated tail, which a
//! scrollback window cut at a chunk boundary genuinely can carry.

use crate::shared::Shared;

/// The newest retained bytes, at most `cap` of them.
///
/// Cut at a BYTE rather than at a message boundary, deliberately: the callers are a full-screen
/// repaint (which converges after one redraw, the same property the ring's own truncation relies
/// on) and a text scrape (where a half-line at the very top is what a scrollback window always
/// looks like). A message-aligned cut would drop a whole chunk to save a few bytes.
pub(crate) fn newest(shared: &Shared, cap: usize) -> Vec<u8> {
    let mut history = shared.snapshot_source(0).history;
    if history.len() > cap {
        history.drain(..history.len() - cap);
    }
    history
}

/// Every retained byte as plain text, with the terminal escape sequences removed.
///
/// `strip` also takes the Nerd-font / Powerline private-use glyphs: they are valid UTF-8 a byte
/// scanner would pass through, and to a predicate matching words they are decoration.
pub(crate) fn text(shared: &Shared, ansi_strip: bool) -> String {
    let raw = shared.snapshot_source(0).history;
    let bytes = if ansi_strip {
        slopdesk_sanitize::plaintext::strip(&raw)
    } else {
        raw
    };
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The stripped scrollback as LOGICAL lines, at most `limit` of them counting from the end.
///
/// An unterminated last line is KEPT, which is `slopdesk-sanitize`'s rule and the right one here:
/// host-side, the half-written line at the bottom is indistinguishable from the prompt an
/// orchestrator is scraping for. Empty text is NO lines rather than one empty one.
pub(crate) fn logical_lines(shared: &Shared, limit: Option<usize>) -> Vec<String> {
    let text = text(shared, true);
    slopdesk_sanitize::lines::logical_lines(&text, limit)
        .into_iter()
        .map(String::from)
        .collect()
}
