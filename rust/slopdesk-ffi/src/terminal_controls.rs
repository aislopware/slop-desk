//! The pane's eight stored control vocabularies, in C.
//!
//! The rules are `slopdesk_terminal::controls`; what is here is the marshalling.
//!
//! ## A token TABLE and a repair, not a door per case
//!
//! Every one of these settings is the same shape: a small closed set, a stored spelling per case,
//! and a repair for a token this build does not know. So each crosses twice — one delivery of the
//! whole table in `ALL` order, read once per process, and one door that repairs an arbitrary stored
//! token to a code. A door per case would be forty crossings for eight enumerations whose members
//! are known at compile time on both sides.
//!
//! Three of them carry a SECOND spelling — the value written into the terminal's own config, which
//! is inverted or renamed for reasons the rule module documents — and those tables deliver the
//! pair. That is the whole reason the config value crosses at all: `Disabled → "true"` is exactly
//! the transcription nobody would reproduce correctly twice.

use core::ffi::c_uchar;

use slopdesk_terminal::controls::{
    ClipboardAccess, MouseShiftCapture, OptionAsAlt, RightClickAction, SchemeDetection, ScrollPastFirst,
    ScrollPastLast, resolved_clipboard_gates,
};
use slopdesk_terminal::link_action::{CmdClick, CmdShiftClick};

use crate::{borrow, deliver, push_text};

/// Delivers a table, one or two runs per case, in `ALL` order.
macro_rules! table {
    ($blob:ident, $ty:ty, $($spelling:ident),+) => {
        for case in <$ty>::ALL {
            $(push_text(&mut $blob, case.$spelling());)+
        }
    };
}

/// The code a case sits at in its own `ALL` order.
macro_rules! code_of {
    ($ty:ty, $case:expr) => {{
        let case = $case;
        <$ty>::ALL
            .iter()
            .position(|other| *other == case)
            .and_then(|index| u8::try_from(index).ok())
            .unwrap_or(0)
    }};
}

/// The clipboard-access table: three cases, one stored token each.
///
/// ```text
/// 3 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_clipboard_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, ClipboardAccess, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The clipboard access a stored token names, repaired to Ask when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_clipboard_from_token(token: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(ClipboardAccess, ClipboardAccess::from_token(&token))
}

/// The clipboard text a SILENT read yields, in one delivery, or `0` when the read must be refused
/// or asked about.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `0` is the refusal AND the prompt: the caller that gets no answer raises its own dialog, which
/// is a near-side act either way. A present but EMPTY answer is a silent read of an empty
/// clipboard.
///
/// # Safety
/// `(text, len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_terminal_clipboard_silent_read(
    access: u8,
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(access) = ClipboardAccess::ALL.get(access as usize).copied() else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let text = String::from_utf8_lossy(unsafe { borrow(text, len) });
    let Some(answer) = access.silent_read(&text) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &answer);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Both clipboard gates once the shell's master switch has had its say, read and write.
///
/// The read gate is the low byte, the write gate the next one up. One answer rather than two,
/// because a master switch honoured in one direction and not the other is exactly the failure the
/// rule exists to rule out.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_terminal_clipboard_gates(shell_controlled: bool, read: u8, write: u8) -> u16 {
    let resolve = |code: u8| {
        ClipboardAccess::ALL
            .get(code as usize)
            .copied()
            .unwrap_or_default()
    };
    let (read, write) = resolved_clipboard_gates(shell_controlled, resolve(read), resolve(write));
    u16::from(code_of!(ClipboardAccess, read)) | (u16::from(code_of!(ClipboardAccess, write)) << 8)
}

/// The right-click table: five cases, one stored token each.
///
/// ```text
/// 5 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_right_click_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, RightClickAction, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The right-click action a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_right_click_from_token(token: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(RightClickAction, RightClickAction::from_token(&token))
}

/// The shift-capture table: four cases, one stored token each.
///
/// ```text
/// 4 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_mouse_shift_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, MouseShiftCapture, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The shift-capture case a stored token names, and whether it extends a selection.
///
/// The low byte is the code, bit 8 the selection answer: both are read at the same moment — a
/// stored token is resolved exactly when a shift-drag has to be routed.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_mouse_shift_from_token(token: *const c_uchar, len: usize) -> u16 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    let case = MouseShiftCapture::from_token(&token);
    u16::from(code_of!(MouseShiftCapture, case)) | (u16::from(case.extends_selection()) << 8)
}

/// The option-as-alt table: four cases, one stored token each.
///
/// ```text
/// 4 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_option_as_alt_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, OptionAsAlt, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The option-as-alt case a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_option_as_alt_from_token(token: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(OptionAsAlt, OptionAsAlt::from_token(&token))
}

/// The scheme-detection table: two cases, one stored token each.
///
/// ```text
/// 2 × [u32 length][UTF-8 bytes]
/// ```
///
/// The POLICY itself does not cross. It is consumed by the detector, which is already Rust's — a
/// caller holding a `LinkSchemePolicy` would be holding a value only Rust can spend.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_scheme_detection_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, SchemeDetection, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The scheme-detection case a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_scheme_detection_from_token(
    token: *const c_uchar,
    len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(SchemeDetection, SchemeDetection::from_token(&token))
}

/// The two overscroll tables, in one delivery: past-LAST's four, then past-FIRST's four.
///
/// ```text
/// 8 × [u32 length][UTF-8 bytes]
/// ```
///
/// One delivery for the link-click pair's reason: they are one setting with two ends, neither is
/// read without the other, and `same-as-last` makes the second literally quote the first.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_scroll_past_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, ScrollPastLast, token);
    table!(blob, ScrollPastFirst, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The past-LAST mode a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_scroll_past_last_from_token(
    token: *const c_uchar,
    len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(ScrollPastLast, ScrollPastLast::from_token(&token))
}

/// The past-FIRST mode a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_scroll_past_first_from_token(
    token: *const c_uchar,
    len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(ScrollPastFirst, ScrollPastFirst::from_token(&token))
}

/// The two link-click tables, in one delivery: ⌘-click's three, then ⌘⇧-click's two.
///
/// ```text
/// 5 × [u32 length][UTF-8 bytes]
/// ```
///
/// One delivery because the two settings are drawn as one pair of rows and neither is read alone.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_terminal_link_click_tokens(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    table!(blob, CmdClick, token);
    table!(blob, CmdShiftClick, token);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The ⌘-click action a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_cmd_click_from_token(token: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(CmdClick, CmdClick::from_token(&token))
}

/// The ⌘⇧-click action a stored token names, repaired when this build cannot read it.
///
/// # Safety
/// `(token, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_terminal_cmd_shift_click_from_token(
    token: *const c_uchar,
    len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let token = String::from_utf8_lossy(unsafe { borrow(token, len) });
    code_of!(CmdShiftClick, CmdShiftClick::from_token(&token))
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_terminal::controls::{
        ClipboardAccess, MouseShiftCapture, OptionAsAlt, RightClickAction, SchemeDetection,
        resolved_clipboard_gates,
    };
    use slopdesk_terminal::link_action::{CmdClick, CmdShiftClick};

    use super::{
        slopdesk_terminal_clipboard_from_token, slopdesk_terminal_clipboard_gates,
        slopdesk_terminal_clipboard_silent_read, slopdesk_terminal_clipboard_tokens,
        slopdesk_terminal_cmd_click_from_token, slopdesk_terminal_cmd_shift_click_from_token,
        slopdesk_terminal_link_click_tokens, slopdesk_terminal_mouse_shift_from_token,
        slopdesk_terminal_mouse_shift_tokens, slopdesk_terminal_option_as_alt_from_token,
        slopdesk_terminal_option_as_alt_tokens, slopdesk_terminal_right_click_from_token,
        slopdesk_terminal_right_click_tokens, slopdesk_terminal_scheme_detection_from_token,
        slopdesk_terminal_scheme_detection_tokens,
    };
    use crate::testing::{delivered, runs};

    /// Reads a delivered table.
    fn table(door: impl FnMut(*mut core::ffi::c_uchar, usize) -> usize, count: usize) -> Vec<String> {
        runs(&delivered(door), count)
    }

    /// Crosses one token through a repair door.
    fn repair(mut door: impl FnMut(*const core::ffi::c_uchar, usize) -> u8, token: &str) -> u8 {
        let bytes = token.as_bytes().to_vec();
        door(bytes.as_ptr(), bytes.len())
    }

    #[test]
    fn every_table_crosses_in_its_own_order() {
        let clipboard = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_clipboard_tokens(out, cap) }
            },
            ClipboardAccess::ALL.len(),
        );
        for (index, case) in ClipboardAccess::ALL.into_iter().enumerate() {
            assert_eq!(clipboard.get(index).map(String::as_str), Some(case.token()));
        }
        let right_click = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_right_click_tokens(out, cap) }
            },
            RightClickAction::ALL.len(),
        );
        for (index, case) in RightClickAction::ALL.into_iter().enumerate() {
            assert_eq!(right_click.get(index).map(String::as_str), Some(case.token()));
        }
        let schemes = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_scheme_detection_tokens(out, cap) }
            },
            SchemeDetection::ALL.len(),
        );
        for (index, case) in SchemeDetection::ALL.into_iter().enumerate() {
            assert_eq!(schemes.get(index).map(String::as_str), Some(case.token()));
        }
    }

    /// The two four-case tables answer their own `ALL` order and nothing beside it.
    #[test]
    fn the_four_case_tables_carry_one_spelling_each() {
        let shift = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_mouse_shift_tokens(out, cap) }
            },
            MouseShiftCapture::ALL.len(),
        );
        for (index, case) in MouseShiftCapture::ALL.into_iter().enumerate() {
            assert_eq!(shift.get(index).map(String::as_str), Some(case.token()));
        }
        let option = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_option_as_alt_tokens(out, cap) }
            },
            OptionAsAlt::ALL.len(),
        );
        for (index, case) in OptionAsAlt::ALL.into_iter().enumerate() {
            assert_eq!(option.get(index).map(String::as_str), Some(case.token()));
        }
    }

    #[test]
    fn the_two_link_click_tables_ride_together() {
        let tokens = table(
            |out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_terminal_link_click_tokens(out, cap) }
            },
            CmdClick::ALL.len() + CmdShiftClick::ALL.len(),
        );
        for (index, case) in CmdClick::ALL.into_iter().enumerate() {
            assert_eq!(tokens.get(index).map(String::as_str), Some(case.token()));
        }
        for (index, case) in CmdShiftClick::ALL.into_iter().enumerate() {
            assert_eq!(
                tokens.get(CmdClick::ALL.len() + index).map(String::as_str),
                Some(case.token()),
            );
        }
    }

    #[test]
    fn every_stored_token_round_trips_and_an_unreadable_one_is_repaired() {
        for (index, case) in ClipboardAccess::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_clipboard_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
        // SAFETY: the borrowed bytes are a live local for the call.
        let repaired = repair(
            |ptr, len| unsafe { slopdesk_terminal_clipboard_from_token(ptr, len) },
            "nonsense",
        );
        assert_eq!(
            ClipboardAccess::ALL.get(repaired as usize).copied(),
            Some(ClipboardAccess::from_token("nonsense")),
        );
        for (index, case) in RightClickAction::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_right_click_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
        for (index, case) in OptionAsAlt::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_option_as_alt_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
        for (index, case) in SchemeDetection::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_scheme_detection_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
        for (index, case) in CmdClick::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_cmd_click_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
        for (index, case) in CmdShiftClick::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let code = repair(
                |ptr, len| unsafe { slopdesk_terminal_cmd_shift_click_from_token(ptr, len) },
                case.token(),
            );
            assert_eq!(usize::from(code), index, "{case:?}");
        }
    }

    #[test]
    fn the_shift_capture_repair_answers_the_selection_question_in_the_same_call() {
        for (index, case) in MouseShiftCapture::ALL.into_iter().enumerate() {
            // SAFETY: the borrowed bytes are a live local for the call.
            let bytes = case.token().as_bytes().to_vec();
            let packed = unsafe { slopdesk_terminal_mouse_shift_from_token(bytes.as_ptr(), bytes.len()) };
            assert_eq!(usize::from(packed & 0xFF), index, "{case:?}");
            assert_eq!(packed >> 8 == 1, case.extends_selection(), "{case:?}");
        }
    }

    #[test]
    fn a_silent_read_yields_text_or_declines() {
        for access in ClipboardAccess::ALL {
            let code = code(access);
            let text = b"pasted".to_vec();
            let blob = delivered(|out, cap| {
                // SAFETY: `text` and `out` are live locals for the call.
                unsafe { slopdesk_terminal_clipboard_silent_read(code, text.as_ptr(), text.len(), out, cap) }
            });
            match access.silent_read("pasted") {
                None => assert!(blob.is_empty(), "{access:?}"),
                Some(expected) => assert_eq!(runs(&blob, 1).first().cloned(), Some(expected)),
            }
        }
    }

    /// A case's own code.
    fn code(access: ClipboardAccess) -> u8 {
        ClipboardAccess::ALL
            .iter()
            .position(|other| *other == access)
            .and_then(|index| u8::try_from(index).ok())
            .unwrap_or(0)
    }

    /// The master switch has to be honoured in BOTH directions, which is why one call answers both.
    #[test]
    fn the_master_switch_closes_both_gates_at_once() {
        for shell_controlled in [false, true] {
            for read in ClipboardAccess::ALL {
                for write in ClipboardAccess::ALL {
                    let packed = slopdesk_terminal_clipboard_gates(shell_controlled, code(read), code(write));
                    let (expected_read, expected_write) =
                        resolved_clipboard_gates(shell_controlled, read, write);
                    assert_eq!(u8::try_from(packed & 0xFF).unwrap_or(0), code(expected_read));
                    assert_eq!(u8::try_from(packed >> 8).unwrap_or(0), code(expected_write));
                }
            }
        }
    }
}
