//! What a key event is called, in C — for the dispatcher and for the chord recorder.
//!
//! The rules are `slopdesk_video::key_naming`; what is here is the marshalling. Both doors answer a
//! KIND, because the answer is a sum type: a named key, a printable character, or nothing at all.
//! A `(out, cap) -> needed` return alone could not tell "no chord" from "a chord whose text did not
//! fit", so the length rides beside the kind instead of being it.
//!
//! ## Where the two vocabularies are pinned to each other
//!
//! `slopdesk_video` names the keys and `slopdesk_terminal::keybind` parses the config file that
//! stores them, and neither depends on the other. This crate sees both, so the agreement is a test
//! here: every canonical name the recorder can produce must survive `canonical_base_key` unchanged.
//! Without it a rebind captured in Settings could persist under a spelling the grammar folds away.

use core::ffi::c_uchar;

use slopdesk_video::key_naming::{self, CaptureOutcome, NamedKey};

use crate::{borrow, deliver};

/// `kind` = `0` nothing · `1` a named key · `2` a printable character.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskKeyBase {
    /// Which of the three answers this is.
    pub kind: u8,
    /// The [`NamedKey`] case index, read only when `kind` is `1`.
    pub named: u8,
    /// How many UTF-8 bytes the character needed, read only when `kind` is `2`. A character that
    /// did not fit still reports its size, and nothing was written.
    pub length: usize,
}

impl SlopDeskKeyBase {
    /// No chord to key on.
    const NONE: Self = Self {
        kind: 0,
        named: 0,
        length: 0,
    };

    /// A named key.
    const fn named(key: NamedKey) -> Self {
        Self {
            kind: 1,
            named: key.index(),
            length: 0,
        }
    }
}

/// The base key of a live keystroke, for the dispatcher.
///
/// `non_shift_modifier_held` decides the space bar alone: bare and ⇧-only Space is typing the
/// terminal must receive, while ⌃/⌥/⌘ Space is the Vi-mode chord.
///
/// # Safety
/// `(chars, chars_len)` must be null or describe that many live bytes; `(out, cap)` must be
/// writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_key_chord_base(
    key_code: u16,
    chars: *const c_uchar,
    chars_len: usize,
    non_shift_modifier_held: bool,
    out: *mut c_uchar,
    cap: usize,
) -> SlopDeskKeyBase {
    if let Some(named) = key_naming::dispatch_named_key(key_code, non_shift_modifier_held) {
        return SlopDeskKeyBase::named(named);
    }
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let text = String::from_utf8_lossy(unsafe { borrow(chars, chars_len) });
    let Some(character) = key_naming::dispatch_base_character(&text) else {
        return SlopDeskKeyBase::NONE;
    };
    let mut buffer = [0_u8; 4];
    let encoded = character.encode_utf8(&mut buffer);
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    let length = unsafe { deliver(encoded.as_bytes(), out, cap) };
    SlopDeskKeyBase {
        kind: 2,
        named: 0,
        length,
    }
}

/// What capturing one keystroke means to the chord recorder.
///
/// `0` cancel · `1` clear · `2` ignore · `3` bind, with the bound base key's canonical text written
/// to `(out, cap)` and its length in `needed`. Only a bind writes anything.
///
/// # Safety
/// `(chars, chars_len)` must be null or describe that many live bytes; `(out, cap)` must be
/// writable and `needed` null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_key_capture_outcome(
    key_code: u16,
    chars: *const c_uchar,
    chars_len: usize,
    out: *mut c_uchar,
    cap: usize,
    needed: *mut usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let text = String::from_utf8_lossy(unsafe { borrow(chars, chars_len) });
    let base = key_naming::capture_base_key(key_code, &text).unwrap_or_default();
    if let Some(needed) = unsafe { needed.as_mut() } {
        *needed = base.len();
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(base.as_bytes(), out, cap) };
    match key_naming::capture_outcome(key_code, &text) {
        CaptureOutcome::Cancel => 0,
        CaptureOutcome::Clear => 1,
        CaptureOutcome::Ignore => 2,
        CaptureOutcome::Bind => 3,
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_terminal::keybind::canonical_base_key;
    use slopdesk_video::key_naming::NamedKey;

    use super::{slopdesk_key_capture_outcome, slopdesk_key_chord_base};

    const ALL_NAMED: [NamedKey; 11] = [
        NamedKey::Return,
        NamedKey::Tab,
        NamedKey::Space,
        NamedKey::Left,
        NamedKey::Right,
        NamedKey::Up,
        NamedKey::Down,
        NamedKey::PageUp,
        NamedKey::PageDown,
        NamedKey::Home,
        NamedKey::End,
    ];

    #[test]
    fn every_name_the_recorder_stores_is_one_the_config_grammar_keeps() {
        for key in ALL_NAMED {
            assert_eq!(
                canonical_base_key(key.canonical()),
                key.canonical(),
                "a captured chord must persist under the spelling the grammar reads back"
            );
        }
    }

    #[test]
    fn a_named_key_crosses_as_its_index_and_writes_nothing() {
        let mut out = [b'x'; 8];
        // SAFETY: one live buffer, borrowed for the call.
        let base =
            unsafe { slopdesk_key_chord_base(36, core::ptr::null(), 0, false, out.as_mut_ptr(), out.len()) };
        assert_eq!(base.kind, 1);
        assert_eq!(base.named, NamedKey::Return.index());
        assert_eq!(out, [b'x'; 8], "a named key needs no text");
    }

    #[test]
    fn a_printable_key_crosses_as_its_utf8() {
        let chars = "D";
        let mut out = [0_u8; 8];
        // SAFETY: two live buffers, borrowed for the call.
        let base = unsafe {
            slopdesk_key_chord_base(2, chars.as_ptr(), chars.len(), false, out.as_mut_ptr(), out.len())
        };
        assert_eq!(base.kind, 2);
        assert_eq!(base.length, 1);
        assert_eq!(out.get(..base.length), Some(b"d".as_slice()), "lower-cased");
    }

    #[test]
    fn the_space_bar_answers_differently_with_and_without_a_modifier() {
        let space = " ";
        let mut out = [0_u8; 8];
        // SAFETY: two live buffers, borrowed for both calls.
        let held =
            unsafe { slopdesk_key_chord_base(49, space.as_ptr(), 1, true, out.as_mut_ptr(), out.len()) };
        // SAFETY: as above.
        let bare =
            unsafe { slopdesk_key_chord_base(49, space.as_ptr(), 1, false, out.as_mut_ptr(), out.len()) };
        assert_eq!(held.kind, 1);
        assert_eq!(held.named, NamedKey::Space.index());
        assert_eq!(bare.kind, 0, "a bare space is typing, not a chord");
    }

    #[test]
    fn the_outcome_indexes_are_the_ones_the_header_names() {
        let mut out = [0_u8; 16];
        let mut needed = 0;
        // SAFETY: two live buffers, borrowed for the call.
        let outcome = |code: u16, chars: &str, out: &mut [u8], needed: &mut usize| unsafe {
            slopdesk_key_capture_outcome(
                code,
                chars.as_ptr(),
                chars.len(),
                out.as_mut_ptr(),
                out.len(),
                needed,
            )
        };
        assert_eq!(outcome(53, "", &mut out, &mut needed), 0, "cancel");
        assert_eq!(outcome(51, "\u{7f}", &mut out, &mut needed), 1, "clear");
        assert_eq!(outcome(999, "", &mut out, &mut needed), 2, "ignore");
        assert_eq!(outcome(123, "", &mut out, &mut needed), 3, "bind");
        assert_eq!(needed, "left".len());
        assert_eq!(out.get(..needed), Some(b"left".as_slice()));
    }
}
