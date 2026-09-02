//! What a POINTER does to the surface: the selection it drags, the modifier bits that qualify it,
//! and the screen coordinates both are phrased in.
//!
//! These are one module because they are one gesture. A press picks a cell, the modifiers decide
//! whether that press extends or restarts, and the row/line doors answer what the caller just
//! selected — splitting them would put the click ladder in one file and the thing it counts in
//! another.

use core::ffi::c_uchar;
use core::time::Duration;

use slopdesk_vterm::{Autoscroll, ClickLadder, CopyFormat, Key, Mods, SurfacePoint, key_from_macos_keycode};

use super::reading::narrow_col;
use super::{SlopDeskTerminalSurface, held};
use crate::{deliver, push_text, saturating_u32};

// MARK: - Selection

/// Whether the selection stops exactly where the cursor stands, which is the only arrangement in
/// which a cut's backspaces delete the selected text rather than somebody else's.
///
/// Asked of the SURFACE rather than computed by the caller because the surface is the only thing
/// that holds both halves — see [`Frame::selection_ends_at_cursor`]. A client that guessed would be
/// guessing about where a shell put its cursor.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_selection_ends_at_cursor(
    handle: *mut SlopDeskTerminalSurface,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.session.frame().selection_ends_at_cursor()
}

/// One pointer press against the selection, answering whether the selection changed.
///
/// `time_ms` and the two repeat thresholds are the platform's own click-sequencing numbers
/// (`NSEvent.doubleClickInterval`, and the slop a finger is allowed): the engine's gesture machine
/// owns the LADDER — single is a cell, double a word, triple a line — and this door only tells it
/// what the platform considers one sequence. See `slopdesk-vterm`'s `selection` header for why the
/// ladder is not re-derived here.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_press(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    time_ms: f64,
    repeat_interval_ms: f64,
    repeat_distance: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.repaint = true;
    let scale = surface.geometry.scale;
    surface
        .session
        .select_press(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            millis(time_ms),
            millis(repeat_interval_ms),
            repeat_distance * scale,
            ClickLadder::default(),
        )
        .unwrap_or(false)
}

/// A millisecond count as a [`Duration`], with every value the platform cannot mean answered.
///
/// `Duration::try_from_secs_f64` refuses a negative or a NaN rather than panicking, and zero is the
/// honest fallback: a press whose timestamp did not survive the crossing starts a NEW click
/// sequence instead of joining the previous one, which is a lost double-click rather than a
/// selection the user did not ask for.
fn millis(value: f64) -> Duration {
    Duration::try_from_secs_f64(value / 1000.0).unwrap_or(Duration::ZERO)
}

/// Extends a live selection to `(x, y)`. `rectangle` selects a block (⌥-drag / ⌃V).
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_drag(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.repaint = true;
    let scale = surface.geometry.scale;
    surface
        .session
        .select_drag(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            rectangle,
        )
        .unwrap_or(false)
}

/// Ends the drag, leaving the selection standing.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_select_release(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.repaint = true;
    let scale = surface.geometry.scale;
    let _refused = surface.session.select_release(SurfacePoint {
        x: x * scale,
        y: y * scale,
    });
}

/// Which way a live selection drag wants the viewport to move: `0` nowhere, `1` up, `2` down.
///
/// Asked by the view's display link, which then calls [`slopdesk_term_surface_select_autoscroll`].
/// Two doors rather than one because the tick needs the pointer's CURRENT position and only the
/// view has it — folding them would mean the engine keeping a copy that a mouse-up could strand.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_autoscroll_direction(
    handle: *mut SlopDeskTerminalSurface,
) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    match surface.session.selection_autoscroll() {
        Ok(Autoscroll::Up) => 1,
        Ok(Autoscroll::Down) => 2,
        Ok(Autoscroll::None) | Err(_) => 0,
    }
}

/// One autoscroll tick with the pointer at `(x, y)`.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_autoscroll(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.repaint = true;
    let scale = surface.geometry.scale;
    surface
        .session
        .select_autoscroll_tick(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            rectangle,
        )
        .unwrap_or(false)
}

/// The selection verbs that take no pointer: `0` clear, `1` select all, `2` has-selection.
///
/// Answers whether anything is selected AFTERWARDS, which makes `2` a read and the other two a
/// write-then-read. One door because the caller — a menu item's enablement, a ⌘A — asks the same
/// question after each, and three doors would be three places to forget it.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_selection_verb(
    handle: *mut SlopDeskTerminalSurface,
    verb: u8,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.repaint = true;
    match verb {
        1 => drop(surface.session.select_all()),
        2 => {},
        _ => drop(surface.session.clear_selection()),
    }
    surface.session.has_selection().unwrap_or(false)
}

/// The selection as text: `0` plain, `1` with its SGR escapes, `2` as HTML.
///
/// §4's byte count, and `0` for no selection. Soft-wrapped lines are UNWRAPPED and trailing blanks
/// trimmed, which is `slopdesk-vterm`'s decision and not this door's — see its `selection` header
/// for why a copied command that pastes back as two broken ones is the failure that settles it.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_selection_text(
    handle: *mut SlopDeskTerminalSurface,
    format: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let format = match format {
        1 => CopyFormat::Vt,
        2 => CopyFormat::Html,
        _ => CopyFormat::Plain,
    };
    let Ok(Some(text)) = surface.session.selection_text(format) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

// MARK: - Modifier bits

/// The `mods` word [`slopdesk_term_surface_key`] and [`slopdesk_term_surface_mouse`] take, built
/// from what the platform says is held.
///
/// ⚠️ **This door exists so that no modifier BIT is ever spelled in Swift.** The bits are
/// `libghostty_vt`'s `key::Mods`, which is upstream's to renumber; a client that hard-coded them
/// would be a second copy of a layout it does not own, and the failure mode is silent — ⌃C encoding
/// as ⌥C rather than as an error. So the client passes what it actually knows, which is which
/// PHYSICAL keys `AppKit` or `UIKit` reported, and gets back the one word the encoder wants.
///
/// The `right_*` flags say which side a held modifier is on, and are meaningless without the
/// matching held flag. Only `macos-option-as-alt = left|right` reads one, but they cross for every
/// press rather than only when that setting is on: a `mods` word that depended on a config value
/// would be a word the caller could build differently from the one the encoder resolves against.
///
/// Pure — no handle, no state, no failure. A press that holds nothing is `0`.
///
/// Ten `bool`s rather than a packed byte, deliberately: a packed argument would be a bit layout the
/// caller had to know, which is the one thing this door exists to keep on this side.
///
/// # Safety
/// None to honour. The door takes ten `bool`s by value and touches no pointer, so it is `unsafe`
/// only because edition 2024 spells every exported C entry point that way; any call is sound.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_mods(
    shift: bool,
    alt: bool,
    ctrl: bool,
    command: bool,
    caps_lock: bool,
    num_lock: bool,
    right_shift: bool,
    right_alt: bool,
    right_ctrl: bool,
    right_command: bool,
) -> u16 {
    let mut mods = Mods::NONE;
    for (held, bit) in [
        (shift, Mods::SHIFT),
        (alt, Mods::ALT),
        (ctrl, Mods::CTRL),
        (command, Mods::SUPER),
        (caps_lock, Mods::CAPS_LOCK),
        (num_lock, Mods::NUM_LOCK),
        (shift && right_shift, Mods::RIGHT_SHIFT),
        (alt && right_alt, Mods::RIGHT_ALT),
        (ctrl && right_ctrl, Mods::RIGHT_CTRL),
        (command && right_command, Mods::RIGHT_SUPER),
    ] {
        if held {
            mods = mods.union(bit);
        }
    }
    mods.bits()
}

/// Which `adjust_selection` edge a ⇧+arrow press names, or `-1` for a press that names none.
///
/// `keycode` is an `AppKit` `NSEvent.keyCode` and `mods` a [`slopdesk_term_mods`] word, the same
/// pair [`slopdesk_term_surface_key`] takes — this is the rule that reads them, not a second
/// encoding of them. The answer is a [`store_shape`]-coded edge (`0` up, `1` down, `2` left,
/// `3` right), which is what a `adjust_selection:<dir>` binding carries.
///
/// ## The modifier test is ⇧ AND NOTHING ELSE, minus the locks and the sides
///
/// `Mods` reports a right-shift press as `SHIFT | RIGHT_SHIFT`, and Caps Lock and Num Lock ride
/// along on every press while they are on. Comparing the raw word to `SHIFT` would therefore refuse
/// a right-shift ⇧→ and refuse everyone typing with Caps Lock on, which is the class of bug that
/// looks like a setting that works for some people. The side and lock bits are masked out; ⌘, ⌥ and
/// ⌃ are not, because ⇧⌥→ is a word-wise selection the program should still get.
///
/// # Safety
/// None to honour. The door takes two `u16`s by value and touches no pointer, so it is `unsafe`
/// only because edition 2024 spells every exported C entry point that way; any call is sound.
///
/// [`store_shape`]: crate::store_shape
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const unsafe extern "C" fn slopdesk_term_shift_arrow_edge(keycode: u16, mods: u16) -> i32 {
    let held = mods
        & !(Mods::CAPS_LOCK.bits()
            | Mods::NUM_LOCK.bits()
            | Mods::RIGHT_SHIFT.bits()
            | Mods::RIGHT_ALT.bits()
            | Mods::RIGHT_CTRL.bits()
            | Mods::RIGHT_SUPER.bits());
    if held != Mods::SHIFT.bits() {
        return -1;
    }
    match key_from_macos_keycode(keycode) {
        Some(Key::ArrowUp) => 0,
        Some(Key::ArrowDown) => 1,
        Some(Key::ArrowLeft) => 2,
        Some(Key::ArrowRight) => 3,
        _ => -1,
    }
}

/// The bytes that walk the shell's cursor to a clicked cell, or `0` for a click this may not
/// answer.
///
/// `column` and `row` are the clicked CELL, as `slopdesk_link_hit_cell` resolves one from a point —
/// the same hit-test the link doors use, rather than a second mapping of points to cells. `row` is
/// a row of the VIEWPORT, which is what that hit-test answers.
///
/// The rule, what it refuses and why it is same-row-only are [`VtSession::click_to_move`]'s.
/// Answers §4's byte count, so a caller with a small buffer retries; `0` is a refusal, and the
/// caller sends nothing.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_click_to_move(
    handle: *mut SlopDeskTerminalSurface,
    column: u16,
    row: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(Some(bytes)) = surface.session.click_to_move(column, row) else {
        return 0;
    };
    // SAFETY: as above; `deliver` writes at most `cap`.
    unsafe { deliver(&bytes, out, cap) }
}

// MARK: - Screen coordinates

/// Where the viewport sits in the screen coordinate space, and where the cursor is in it.
///
/// ```text
/// [u32 total_rows][u32 viewport_top_row][u32 viewport_rows][u32 cols][u32 cursor_col][u32 cursor_row]
/// ```
///
/// One door for six numbers because copy mode reads them together and any two of them from
/// different moments describe a grid that never existed — the argument
/// [`slopdesk_vterm::ViewportInfo`] makes for its own shape, carried across the boundary intact.
///
/// The cursor is in SCREEN rows, not viewport rows: everything else in this blob is screen-space,
/// and mixing one viewport-relative number in would be the kind of seam that reads correct until
/// the user scrolls. A terminal with no visible cursor reports it at the viewport's top-left, which
/// is where copy mode starts when there is nothing better to start from.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_viewport_info(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(info) = surface.session.viewport_info() else {
        return 0;
    };
    let cursor = surface.frame().cursor;
    let mut blob = Vec::with_capacity(24);
    for value in [
        info.total_rows,
        info.viewport_top_row,
        info.viewport_rows,
        u32::from(info.cols),
        u32::from(cursor.map_or(0, |at| at.x)),
        info.viewport_top_row
            .saturating_add(u32::from(cursor.map_or(0, |at| at.y))),
    ] {
        blob.extend_from_slice(&value.to_be_bytes());
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Selects from one SCREEN coordinate to another, replacing whatever was selected.
///
/// Both ends are inclusive and either order; `rectangle` selects a block. Answers whether the
/// engine accepted the range — `false` means an endpoint has scrolled out of the buffer, which is
/// an ordinary outcome for a coordinate the caller held across time.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_selection(
    handle: *mut SlopDeskTerminalSurface,
    anchor_col: u32,
    anchor_row: u32,
    head_col: u32,
    head_row: u32,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.repaint = true;
    surface
        .session
        .set_screen_selection(
            (narrow_col(anchor_col), anchor_row),
            (narrow_col(head_col), head_row),
            rectangle,
        )
        .unwrap_or(false)
}

/// One SCREEN row's text, trailing padding trimmed.
///
/// §4's byte count. `0` for a row that is no longer retained AND for a blank one — the two are the
/// same answer to "what text is there", and a caller that needs to tell them apart asks
/// [`slopdesk_term_surface_viewport_info`] for the extent.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_screen_row(
    handle: *mut SlopDeskTerminalSurface,
    row: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(Some(text)) = surface.session.screen_row_text(row) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// The inclusive SCREEN row range of the logical line containing `row`.
///
/// ```text
/// [u32 first][u32 last]
/// ```
///
/// `0` for a row that is no longer retained. A row that is not soft-wrapped answers `row, row`, so
/// the caller never needs a separate "is this wrapped" question.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_line_range(
    handle: *mut SlopDeskTerminalSurface,
    row: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(Some((first, last))) = surface.session.logical_line_range(row) else {
        return 0;
    };
    let mut blob = Vec::with_capacity(8);
    blob.extend_from_slice(&first.to_be_bytes());
    blob.extend_from_slice(&last.to_be_bytes());
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The WHOLE retained buffer as logical lines, oldest first.
///
/// ```text
/// [u32 line_count] line_count × [u32 first_row][u32 last_row][u32 length][UTF-8 bytes]
/// ```
///
/// Each line carries its screen rows because every caller turns a line it matched back into
/// somewhere to SCROLL, and a line's index is not its row — one wrapped line is several rows. A
/// blob without them would make that mapping the client's arithmetic to get wrong, in Swift, which
/// is the wrong side of the boundary for arithmetic.
///
/// ⚠️ This reads the entire scrollback and allocates its text. It is a gesture door — the find
/// bar's row-driven modes and the block extractor — and must never be called per frame.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_logical_lines(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(lines) = surface.session.logical_lines() else {
        return 0;
    };
    let mut blob = Vec::new();
    blob.extend_from_slice(&saturating_u32(lines.len()).to_be_bytes());
    for line in &lines {
        blob.extend_from_slice(&line.first_row.to_be_bytes());
        blob.extend_from_slice(&line.last_row.to_be_bytes());
        push_text(&mut blob, &line.text);
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}
