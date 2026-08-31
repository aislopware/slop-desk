//! What a gesture at the terminal surface means, in C.
//!
//! Six entry points over [`slopdesk_terminal::surface`], and none takes §4's `(out, cap)` shape:
//! every answer is a boolean, a case index or a count, so there is nothing to size and nothing to
//! retry. The one door that could have answered text does not —
//! [`slopdesk_term_forwards_encoder_text`] says only WHETHER the characters may be forwarded,
//! because the text it would otherwise write back is the caller's own input, byte for byte.
//!
//! ## What is NOT here
//! The rules: which clicks the embedder takes for itself, why a full-screen program's ownership of
//! the screen outranks the prompt zone, and why redo has no byte. Those are `slopdesk-terminal`'s,
//! in a crate that forbids `unsafe`.

use core::ffi::c_uchar;

use slopdesk_terminal::surface::{self, ClipboardWrite, Cut, RightClick};

use crate::borrow;

/// What a clipboard WRITE should do: `0` write · `1` confirm first · `2` nothing to write.
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_term_clipboard_write(
    confirm_requested: bool,
    payload: *const c_uchar,
    payload_len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let payload = String::from_utf8_lossy(unsafe { borrow(payload, payload_len) });
    match surface::clipboard_write(confirm_requested, &payload) {
        ClipboardWrite::Write => 0,
        ClipboardWrite::Confirm => 1,
        ClipboardWrite::Drop => 2,
    }
}

/// What a Cut should do: `0` nothing · `1` copy only · `2` copy and delete.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_term_cut_action(
    has_selection: bool,
    alternate_screen: bool,
    prompt_zone: bool,
) -> u8 {
    match surface::cut_action(has_selection, alternate_screen, prompt_zone) {
        Cut::None => 0,
        Cut::CopyOnly => 1,
        Cut::CopyAndDelete => 2,
    }
}

/// How many DEL bytes the delete half of a cut sends; `0` degrades the cut to a copy.
///
/// # Safety
/// `(selection, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_term_cut_delete_count(
    selection: *const c_uchar,
    selection_len: usize,
    selection_ends_at_cursor: bool,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let selection = String::from_utf8_lossy(unsafe { borrow(selection, selection_len) });
    surface::cut_delete_count(&selection, selection_ends_at_cursor)
}

/// Whether a hover should claim the workspace focus.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_term_focus_follows_mouse(setting: bool, already_focused: bool) -> bool {
    surface::focus_follows_mouse(setting, already_focused)
}

/// Whether a key event's characters may be handed to the encoder as text.
///
/// # Safety
/// `(characters, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_term_forwards_encoder_text(
    characters: *const c_uchar,
    characters_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let characters = String::from_utf8_lossy(unsafe { borrow(characters, characters_len) });
    surface::forwards_encoder_text(&characters)
}

/// The byte an undo/redo gesture sends, or `-1` for none.
///
/// A sentinel outside the answer's range by construction: the answer is one byte, so every real one
/// is `0..=255` and cannot be mistaken for the refusal.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_term_prompt_edit_byte(undo: bool, redo: bool, in_prompt_zone: bool) -> i32 {
    match surface::prompt_edit_byte(undo, redo, in_prompt_zone) {
        Some(byte) => byte as i32,
        None => -1,
    }
}

/// What a bare right-click does: `0` forward · `1` paste · `2` copy · `3` menu · `4` ignore.
/// `action` is the config token.
///
/// # Safety
/// `(action, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_term_right_click(
    action: *const c_uchar,
    action_len: usize,
    has_selection: bool,
    mouse_captured: bool,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let action = String::from_utf8_lossy(unsafe { borrow(action, action_len) });
    match surface::right_click(&action, has_selection, mouse_captured) {
        RightClick::Forward => 0,
        RightClick::Paste => 1,
        RightClick::Copy => 2,
        RightClick::Menu => 3,
        RightClick::Ignore => 4,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        slopdesk_term_clipboard_write, slopdesk_term_cut_action, slopdesk_term_cut_delete_count,
        slopdesk_term_forwards_encoder_text, slopdesk_term_prompt_edit_byte, slopdesk_term_right_click,
    };

    #[test]
    fn the_case_indexes_are_the_ones_the_header_names() {
        // SAFETY: two live literals, borrowed for the call.
        let write = |confirm, payload: &str| unsafe {
            slopdesk_term_clipboard_write(confirm, payload.as_ptr(), payload.len())
        };
        assert_eq!(write(false, "x"), 0);
        assert_eq!(write(true, "x"), 1);
        assert_eq!(write(true, ""), 2);
        assert_eq!(slopdesk_term_cut_action(false, false, true), 0);
        assert_eq!(slopdesk_term_cut_action(true, true, true), 1);
        assert_eq!(slopdesk_term_cut_action(true, false, true), 2);
    }

    #[test]
    fn a_null_payload_is_read_as_empty_rather_than_dereferenced() {
        // SAFETY: a null pair is one of the shapes the door's contract admits.
        let (write, count, forwards) = unsafe {
            (
                slopdesk_term_clipboard_write(true, core::ptr::null(), 0),
                slopdesk_term_cut_delete_count(core::ptr::null(), 0, true),
                slopdesk_term_forwards_encoder_text(core::ptr::null(), 0),
            )
        };
        assert_eq!(write, 2, "nothing to write");
        assert_eq!(count, 0);
        assert!(forwards, "an empty payload carries no placeholder and no control");
    }

    #[test]
    fn the_undo_byte_and_its_refusal_cannot_be_confused() {
        assert_eq!(slopdesk_term_prompt_edit_byte(true, false, true), 0x1F);
        assert_eq!(slopdesk_term_prompt_edit_byte(true, false, false), -1);
        assert_eq!(slopdesk_term_prompt_edit_byte(false, true, true), -1);
    }

    #[test]
    fn the_right_click_reads_the_config_token_it_was_written_with() {
        // SAFETY: one live literal, borrowed for the call.
        let click = |action: &str, selected, captured| unsafe {
            slopdesk_term_right_click(action.as_ptr(), action.len(), selected, captured)
        };
        assert_eq!(click("paste", true, false), 1);
        assert_eq!(click("copy-or-paste", true, false), 2);
        assert_eq!(click("copy-or-paste", false, false), 1);
        assert_eq!(click("paste", false, true), 0, "the program owns the pointer");
        assert_eq!(click("ignore", false, false), 4);
        assert_eq!(
            click("contextMenu", false, false),
            3,
            "the token, not the case name"
        );
    }
}
