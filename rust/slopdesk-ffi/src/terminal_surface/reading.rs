//! What the surface ANSWERS: the find bar's hits, the actions a binding performs, and the readback
//! a caller needs to draw its own chrome.
//!
//! The find bar is here rather than beside the selection because a match is a READING of the grid,
//! not a gesture on it; the binding actions are here because every one of them is spelled as a
//! question the session answers rather than a field anything writes.

use core::ffi::c_uchar;

use slopdesk_terminal::surface_action::{SelectionEdge, SurfaceAction};
use slopdesk_vterm::{ClipboardWrite, Scroll, SearchQuery, SelectionAdjust, VtSession};

use super::{SlopDeskTerminalSurface, held, narrow_u32};
use crate::{borrow, deliver, lent, push_text};

// MARK: - The find bar

/// Runs the find bar's query over the whole retained buffer and answers how many hits there are.
///
/// ⚠️ **This door exists because the find bar has four modes and `search:` carries one.** The
/// keybinding verb is a needle and nothing else — a user writing `search:TODO` wants the plain find
/// — so case-sensitivity, whole-word and regex had no way across, and the bar answered them with a
/// SECOND scan of its own over a flat text mirror. Two scans of one buffer meant the `N of M` it
/// printed and the cells the surface lit could disagree. Both routes now end at
/// `VtSession::search_with`; this one just carries the other three flags. See
/// `docs/ui-shell/current-state/terminal-features.md` gap 4.
///
/// The count is the answer rather than a `bool` for the same reason: the bar needs it, and
/// [`slopdesk_term_surface_binding_action`] could only ever say whether something happened.
///
/// An empty needle, or a regex that does not compile, answers `0` and clears the highlight — the
/// two states a find field passes through on the way to a real query, which are not errors.
///
/// # Safety
/// [`held`]'s, plus `(needle, needle_len)` describing `needle_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_find(
    handle: *mut SlopDeskTerminalSurface,
    needle: *const c_uchar,
    needle_len: usize,
    case_sensitive: bool,
    whole_word: bool,
    regex: bool,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `lent` answers "" for anything not valid UTF-8, which is an
    // empty needle and so finds nothing.
    let needle = unsafe { lent(needle, needle_len) };
    let query = SearchQuery::new(needle)
        .case_sensitive(case_sensitive)
        .whole_word(whole_word)
        .regex(regex);
    surface.session.search_with(&query).unwrap_or(0)
}

/// The current hit's position, as the `3 of 17` a find bar prints.
///
/// Answers `false` when nothing is current — no query, or a query with no hits — and writes neither
/// output in that case, so a caller that ignores the answer keeps whatever it had rather than
/// reading a zero as "hit 0 of 0".
///
/// A PULL rather than a return from the navigation verb, which is docs/55 §4's rule for this seam:
/// `navigate_search:` is a keybinding action like any other and answers only whether it moved. The
/// position is read after it, by the one caller that draws a counter.
///
/// # Safety
/// [`held`]'s, plus `current` and `total` each being writable for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_find_position(
    handle: *mut SlopDeskTerminalSurface,
    current: *mut usize,
    total: *mut usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some((at, of)) = surface.session.search_position() else {
        return false;
    };
    if current.is_null() || total.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation; both pointers are non-null and writable for one `usize`.
    unsafe {
        current.write(at);
        total.write(of);
    }
    true
}

// MARK: - Binding actions

/// Performs one keybinding action, spelled by [`SurfaceAction::spell`] on the other side.
///
/// ⚠️ **The client never parses this string and never composes one by hand.**
/// `slopdesk_terminal::surface_action` is the grammar's only home; a spelling this door does not
/// recognise is answered by doing NOTHING and returning `false`, because there is no sound way to
/// guess what a typo meant. That is also why the answer is a `bool` rather than a void: a keystroke
/// that quietly did nothing is the failure mode this seam is built to make visible.
///
/// `false` also means the action was understood and had nothing to do — no prompt in that
/// direction, no selection to adjust, no hit to navigate to. The caller wants the same thing in
/// both cases: leave the key unhandled so something else can have it.
///
/// # Safety
/// [`held`]'s, plus `(action, action_len)` describing `action_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_binding_action(
    handle: *mut SlopDeskTerminalSurface,
    action: *const c_uchar,
    action_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation; `lent` answers "" for anything not valid UTF-8, which then
    // parses to `None` and does nothing.
    let spelling = unsafe { lent(action, action_len) };
    run(&mut surface.session, spelling)
}

/// Parses a spelling and runs it, or answers `false` for one the grammar does not know.
///
/// The door above is pointer discipline, this is the grammar, and [`perform`] is the engine. Three
/// steps rather than one because only the first needs `unsafe` and only the last needs a terminal,
/// so the middle one is where a spelling can be tested against a real session with no surface.
pub(super) fn run(session: &mut VtSession, spelling: &str) -> bool {
    SurfaceAction::parse(spelling).is_some_and(|action| perform(session, action))
}

/// Runs a parsed action against the engine.
///
/// Split out of the door so it is reachable without a live surface — this is where every decision
/// is, and the door above it is only the pointer discipline.
pub(super) fn perform(session: &mut VtSession, action: SurfaceAction<'_>) -> bool {
    match action {
        SurfaceAction::Search { needle } => session.search(needle).is_ok(),
        SurfaceAction::NavigateSearch { forward } => session.navigate_search(forward).unwrap_or(false),
        SurfaceAction::EndSearch => session.end_search().is_ok(),
        SurfaceAction::ScrollToRow(row) => {
            session.scroll(Scroll::Row(row));
            true
        },
        SurfaceAction::ScrollLines(delta) => {
            session.scroll(Scroll::Delta(delta));
            true
        },
        SurfaceAction::ScrollFraction(fraction) => {
            let Ok(info) = session.viewport_info() else {
                return false;
            };
            session.scroll(Scroll::Delta(page_lines(fraction, info.viewport_rows)));
            true
        },
        SurfaceAction::ScrollToTop => {
            session.scroll(Scroll::Top);
            true
        },
        SurfaceAction::ScrollToBottom => {
            session.scroll(Scroll::Bottom);
            true
        },
        SurfaceAction::JumpToPrompt(delta) => {
            match session.prompt_row(delta) {
                Ok(Some(row)) => {
                    session.scroll(Scroll::Row(row));
                    true
                },
                // No prompt that way, or the engine could not say. Either way the hop had nowhere to
                // go, and reporting `true` would swallow a key that should fall through.
                _ => false,
            }
        },
        SurfaceAction::AdjustSelection(edge) => {
            let adjust = match edge {
                SelectionEdge::Up => SelectionAdjust::Up,
                SelectionEdge::Down => SelectionAdjust::Down,
                SelectionEdge::Left => SelectionAdjust::Left,
                SelectionEdge::Right => SelectionAdjust::Right,
            };
            session.adjust_selection(adjust).unwrap_or(false)
        },
    }
}

/// How many rows a fractional page motion moves.
///
/// ⚠️ **At least one row, whatever the arithmetic says.** A page fraction of 0.9 over a two-row
/// viewport truncates to 1, but over a ONE-row viewport it truncates to 0 — and a page-down that
/// moves nothing reads as a dead key rather than as a small pane. The floor is the same rule the
/// client applied before this seam moved into Rust, kept here so there is one page-size decision
/// instead of one per platform.
pub(super) fn page_lines(fraction: f64, viewport_rows: u32) -> i32 {
    let rows = f64::from(viewport_rows) * fraction.abs();
    let magnitude = i32::try_from(narrow_u32(rows.floor())).unwrap_or(i32::MAX).max(1);
    if fraction < 0.0 { -magnitude } else { magnitude }
}

/// A column that crossed the boundary as a `u32`, clamped to the grid's addressable width.
///
/// Saturating rather than truncating: a column of `u32::MAX` is a caller's bug either way, and
/// clamping to the last column selects something visible while a wrapping cast would select
/// column 0 — a silently WRONG selection, which is worse than a clamped one.
pub(super) fn narrow_col(value: u32) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}

// MARK: - Readback

/// The visible rows as text, for the link and hint overlays.
///
/// ```text
/// [u32 row_count] row_count × [u32 length][UTF-8 bytes]
/// ```
///
/// The rows the OVERLAYS index, which is why they come from the same frame the painter drew and not
/// from a second scan: an underline placed against a row the surface has since scrolled is an
/// underline under the wrong text.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_viewport_rows(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let frame = surface.frame();
    let count = frame.row_count();
    let mut blob = Vec::new();
    blob.extend_from_slice(&u32::from(count).to_be_bytes());
    for index in 0..count {
        push_text(&mut blob, frame.row(index).map_or("", |row| row.text.as_str()));
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The live cell geometry, in POINTS, as the overlays' `TerminalCellMetrics` reads it.
///
/// ```text
/// [f64 cell_width][f64 cell_height][u32 cols][u32 rows][f64 origin_x][f64 origin_y]
/// ```
///
/// Points, not pixels, and this is the ONE door that converts back: an overlay is an AppKit/UIKit
/// view laid out in points, and handing it pixels would put a second contents-scale division in the
/// client. `slopdesk-termrender`'s "every coordinate that leaves this crate is a DEVICE pixel"
/// holds up to here; this door is where the boundary is crossed, once.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_cell_metrics(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let scale = surface.geometry.scale;
    let (cols, rows) = surface.session.size();
    let insets = surface.insets();
    let mut blob = Vec::with_capacity(40);
    blob.extend_from_slice(&(surface.font.cell_width() / scale).to_be_bytes());
    blob.extend_from_slice(&(surface.font.cell_height() / scale).to_be_bytes());
    blob.extend_from_slice(&u32::from(cols).to_be_bytes());
    blob.extend_from_slice(&u32::from(rows).to_be_bytes());
    blob.extend_from_slice(&(insets.left / scale).to_be_bytes());
    blob.extend_from_slice(&(insets.top / scale).to_be_bytes());
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The four flags the client's policy layers ask about, as bits: `1` alternate screen, `2` mouse
/// tracking, `4` viewport at the bottom, `8` DEC bracketed paste (`?2004h`).
///
/// One door because all four are read TOGETHER on the same events — a keystroke, a scroll, a
/// pointer move, a paste — and reading them separately is four chances to act on a mixed state:
/// forwarding a scroll as a mouse report because tracking was read before the alt-screen flip, or
/// skipping the paste-protection sheet on a `?2004h` the program has since turned off.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_modes(handle: *mut SlopDeskTerminalSurface) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    u8::from(surface.session.is_alternate_screen().unwrap_or(false))
        | (u8::from(surface.session.is_mouse_tracking().unwrap_or(false)) << 1)
        | (u8::from(surface.session.is_viewport_at_bottom().unwrap_or(true)) << 2)
        | (u8::from(surface.session.wants_bracketed_paste().unwrap_or(false)) << 3)
}

/// The exact bytes a paste of `(bytes, len)` should put on the pty.
///
/// ## Why a paste is not "write these bytes"
///
/// The engine scrubs the control bytes a payload must never carry into a prompt (NUL, ESC, DEL),
/// turns newlines into carriage returns when the paste is *not* bracketed, and strips any embedded
/// `ESC [ 201 ~` before wrapping — the classic bracketed-paste breakout, where a clipboard that
/// smuggled an end marker closes the block early and injects its tail as live input. Every one of
/// those is a rule about how the FAR side's parser behaves, so it belongs to the engine that owns
/// that parser, and a Swift `"\u{1b}[200~" + text` would be a second, worse paste implementation.
///
/// `bracketed` is the caller's on purpose: three menu items disagree about it. Ordinary **Paste**
/// passes bit `8` of [`slopdesk_term_surface_modes`], **Bracketed Paste** forces `true`, and
/// **Paste as Keystrokes** forces `false` so the payload arrives as if typed.
///
/// ⚠️ This door does NOT write anything, ask anything or consult a setting. The paste-protection
/// decision is the client's (`PastePrecheck`), and it happens BEFORE these bytes are asked for.
///
/// Non-UTF-8 input answers `0`, as does a null handle. Otherwise the two-attempt convention: the
/// return is bytes NEEDED, written when it fits.
///
/// # Safety
/// [`held`]'s, plus `bytes` being null or readable for `len`, and `(out, cap)` writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_encode_paste(
    handle: *mut SlopDeskTerminalSurface,
    bytes: *const c_uchar,
    len: usize,
    bracketed: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `borrow` states its own.
    let Ok(text) = core::str::from_utf8(unsafe { borrow(bytes, len) }) else {
        return 0;
    };
    let Ok(encoded) = surface.session.encode_paste(text, bracketed) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&encoded, out, cap) }
}

/// Drains the bytes the TERMINAL owes the pty, and empties the queue.
///
/// ⚠️ **The caller must poll this after every [`slopdesk_term_surface_feed`] and write what it
/// finds to the host.** It is not optional and not a feature: `CSI 6n` asks where the cursor is,
/// `CSI c` what the terminal is, `CSI > q` its version, `OSC 10/11/4 ?` its colours, and the engine
/// composes every one of those answers itself and hands it over exactly once, here. A surface that
/// never polls is a terminal that never answers — vim probing for truecolour, tmux for the cursor,
/// a prompt negotiating bracketed paste all block or guess wrong.
///
/// Distinct from [`slopdesk_term_surface_key`]'s answer, which is what the USER typed. Both end up
/// on the same pty and neither can stand in for the other: a keystroke's bytes exist because a
/// person pressed a key, and these exist because a program asked a question.
///
/// The queue is bounded (`slopdesk_vterm::events`), so a surface that stops polling costs bounded
/// memory rather than the process. `0` for a null handle or an empty queue — the common answer.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_take_pty_replies(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // Drained into the surface's own buffer rather than straight out, because the two-attempt
    // convention means a first call that found the caller's buffer too small must still have
    // something to hand over on the second. Emptying the engine's queue into a buffer this handle
    // owns makes the retry an ordinary re-read instead of a lost reply.
    if surface.pty_replies.is_empty() {
        surface.session.take_pty_replies(&mut surface.pty_replies);
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    let needed = unsafe { deliver(&surface.pty_replies, out, cap) };
    if needed <= cap {
        surface.pty_replies.clear();
    }
    needed
}

/// Drains the clipboard writes running programs asked for, as one frame.
///
/// The other push the engine can see and this door does NOT carry: the bell, the OSC-9/777
/// notification, the OSC-9;4 progress report, the OSC 0/2 title and the OSC-7 working directory.
/// Every one of those already arrives as its own wire message from the host, which is the only
/// owner that survives multiclient and the only one that does not re-fire when
/// `TerminalViewModel.attachSurface` replays the retained ring into a rebuilt surface.
/// `slopdesk_vterm::events` carries the whole argument. A clipboard is per-CLIENT, so it is the one
/// with nowhere else to come from.
///
/// The frame, big-endian throughout:
///
/// ```text
/// u16  count
///   u8   target             0 standard · 1 selection · 2 primary
///   u32  length + bytes     the text, `text/plain` where the program offered one
/// ```
///
/// `0` on the common day, which costs one call and no allocation.
///
/// ⚠️ **A write here has NOT been applied.** The door reports what a program ASKED for; whether it
/// reaches a pasteboard is `slopdesk_term_clipboard_write`'s decision, made where the user's
/// `clipboard-write` setting lives. Writing straight from this frame would make "Ask" behave as
/// "Allow" — the exact defect the deleted fork's `write_clipboard_cb` carried before it honoured
/// the flag.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_take_clipboard_writes(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // Same retry contract as the pty door: drain into the handle's buffer, and keep it until it has
    // actually been delivered. `has_clipboard_writes` is what keeps the quiet path free of a `Vec`.
    if surface.clipboard_writes.is_empty() && surface.session.has_clipboard_writes() {
        surface.clipboard_writes = encode_clipboard_writes(&surface.session.take_clipboard_writes());
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    let needed = unsafe { deliver(&surface.clipboard_writes, out, cap) };
    if needed <= cap {
        surface.clipboard_writes.clear();
    }
    needed
}

/// The frame [`slopdesk_term_surface_take_clipboard_writes`] documents, built from one drain.
fn encode_clipboard_writes(writes: &[ClipboardWrite]) -> Vec<u8> {
    let mut blob = Vec::new();
    // The queue is capped far below `u16::MAX` in `slopdesk_vterm::events`, so the saturation is a
    // proof obligation discharged rather than a case that can arise.
    blob.extend_from_slice(&u16::try_from(writes.len()).unwrap_or(u16::MAX).to_be_bytes());
    for write in writes {
        blob.push(write.target.code());
        push_text(&mut blob, &write.text);
    }
    blob
}
