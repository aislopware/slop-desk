//! A device panel's hardware key press, in C —
//! `Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift` and `Sources/SlopDeskDevicePanels/
//! Simulator/SimulatorKeyMap.swift`.
//!
//! The rules are [`slopdesk_devicepanel::panel_key`]; what is here is the marshalling. Each door
//! answers a WHOLE question — "what should the simulator panel send for this key", "what should the
//! Android panel do about this press" — rather than handing back a table row for the near side to
//! reassemble. A door per table would have put the composition back in Swift, which is the thing
//! the port exists to end.
//!
//! ## Which numbering, as an argument rather than a door
//!
//! A Mac reports a virtual keycode and an iPad reports a USB HID usage. That is one bit, so it
//! rides as one, the way [`crate::settings_rows`]'s `shown(index, mac)` carries which half is
//! asking: two doors that differed only in how they looked up the same key would be the same
//! marshalling written twice.
//!
//! ## Why the Android answer is a tagged blob
//!
//! It has three shapes — send nothing, send a keycode with a meta state, type this text — and the
//! caller cannot know which until the rule has run. So the answer is one `(out, cap)` delivery
//! under `docs/55` §4's retry protocol, tagged by its first byte, and the near side reads the tag
//! to know what follows. The alternative was a "which case is it" door followed by a conditional
//! second call, which is two crossings for one question and a window where the two could disagree.

use core::ffi::c_uchar;

use slopdesk_devicepanel::panel_key::{self, AndroidResolution, FunctionalKey};
use slopdesk_video::input_event::InputModifiers;

use crate::{borrow, deliver};

/// Send nothing.
pub const SLOPDESK_ANDROID_KEY_NOTHING: u8 = 0;
/// A `KeyEvent` keycode and meta state follow, four big-endian bytes each.
pub const SLOPDESK_ANDROID_KEY_KEYCODE: u8 = 1;
/// UTF-8 to type follows.
pub const SLOPDESK_ANDROID_KEY_TEXT: u8 = 2;

/// The functional key behind one press, under whichever numbering the caller has.
fn resolve_key(code: u16, hid: bool) -> Option<FunctionalKey> {
    if hid {
        panel_key::functional_key_for_hid(code)
    } else {
        panel_key::functional_key(code)
    }
}

/// One optional string, as a pointer, a length and the flag that tells `nil` from `""` apart.
///
/// The flag is not ceremony. `characters` being ABSENT means "fall back to the stripped spelling",
/// and being EMPTY means "this press produced nothing" — two different answers, and a null pointer
/// standing in for both would silently turn the second into the first.
///
/// # Safety
/// `(ptr, len)` must be readable for `len` bytes when `present`.
#[expect(
    unsafe_code,
    reason = "borrows the caller's pair, and only when the flag says it is live"
)]
unsafe fn borrow_text<'a>(ptr: *const c_uchar, len: usize, present: bool) -> Option<&'a str> {
    if !present {
        return None;
    }
    // SAFETY: the caller's contract, narrowed by `present` to the case where the pair is live.
    let bytes = unsafe { borrow(ptr, len) };
    core::str::from_utf8(bytes).ok()
}

/// The simulator server's `KeyboardEvent.code` for one press, or `0` for a key that types text.
///
/// `0` is admissible as "no code" here where it was not for the HID keycode door: every code this
/// vocabulary can answer is a non-empty name, so an empty delivery is outside the answer's range by
/// construction rather than colliding with a real one.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_panel_simulator_key_code(
    code: u16,
    hid: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(key) = resolve_key(code, hid) else {
        return 0;
    };
    // SAFETY: the caller's contract.
    unsafe { deliver(key.simulator_code().as_bytes(), out, cap) }
}

/// What the Android panel should do about one key-down, as a tagged blob.
///
/// The first byte is one of `SLOPDESK_ANDROID_KEY_*`. `NOTHING` is the whole answer; `KEYCODE` is
/// followed by the keycode and the meta state as four big-endian bytes each; `TEXT` is followed by
/// the UTF-8 to type. A return larger than `cap` means nothing was written — ask again at that
/// size.
///
/// # Safety
/// `(characters, characters_len)` and `(bare, bare_len)` must be readable when their flags are set,
/// and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and three of the four buffers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_panel_android_key_resolve(
    code: u16,
    hid: bool,
    characters: *const c_uchar,
    characters_len: usize,
    characters_present: bool,
    bare: *const c_uchar,
    bare_len: usize,
    bare_present: bool,
    modifiers: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's contract, one pair at a time.
    let (typed, stripped) = unsafe {
        (
            borrow_text(characters, characters_len, characters_present),
            borrow_text(bare, bare_len, bare_present),
        )
    };
    let answer = panel_key::resolve_android(
        resolve_key(code, hid),
        typed,
        stripped,
        InputModifiers::from_bits(modifiers),
    );
    let blob = match answer {
        AndroidResolution::Nothing => vec![SLOPDESK_ANDROID_KEY_NOTHING],
        AndroidResolution::Keycode { keycode, meta_state } => {
            let mut bytes = vec![SLOPDESK_ANDROID_KEY_KEYCODE];
            bytes.extend_from_slice(&keycode.to_be_bytes());
            bytes.extend_from_slice(&meta_state.to_be_bytes());
            bytes
        },
        AndroidResolution::Text(text) => {
            let mut bytes = vec![SLOPDESK_ANDROID_KEY_TEXT];
            bytes.extend_from_slice(text.as_bytes());
            bytes
        },
    };
    // SAFETY: the caller's contract.
    unsafe { deliver(&blob, out, cap) }
}

/// Android's `META_*` bitmask for a set of held modifiers — shift excluded, deliberately.
///
/// Exported beside the resolve door because the panel's own toolbar presses a keycode with no key
/// event behind it, so it needs the meta state without a press to resolve.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_panel_android_meta_state(modifiers: u8) -> u32 {
    panel_key::android_meta_state(InputModifiers::from_bits(modifiers))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        SLOPDESK_ANDROID_KEY_KEYCODE, SLOPDESK_ANDROID_KEY_NOTHING, SLOPDESK_ANDROID_KEY_TEXT,
        slopdesk_panel_android_key_resolve, slopdesk_panel_android_meta_state,
        slopdesk_panel_simulator_key_code,
    };

    fn simulator_code(code: u16, hid: bool) -> Option<String> {
        let mut buffer = [0_u8; 32];
        // SAFETY: the buffer is a live local.
        let needed =
            unsafe { slopdesk_panel_simulator_key_code(code, hid, buffer.as_mut_ptr(), buffer.len()) };
        if needed == 0 {
            return None;
        }
        buffer
            .get(..needed)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    fn android(code: u16, hid: bool, typed: Option<&str>, bare: Option<&str>, mods: u8) -> Vec<u8> {
        let mut buffer = [0_u8; 64];
        let (chars, chars_len, chars_present) = typed.map_or((core::ptr::null(), 0, false), |text| {
            (text.as_ptr(), text.len(), true)
        });
        let (raw, raw_len, raw_present) = bare.map_or((core::ptr::null(), 0, false), |text| {
            (text.as_ptr(), text.len(), true)
        });
        // SAFETY: every pair is a live local, and a null one carries `present == false`.
        let needed = unsafe {
            slopdesk_panel_android_key_resolve(
                code,
                hid,
                chars,
                chars_len,
                chars_present,
                raw,
                raw_len,
                raw_present,
                mods,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        buffer.get(..needed).unwrap_or_default().to_vec()
    }

    #[test]
    fn both_numberings_reach_the_same_simulator_code_through_one_door() {
        assert_eq!(simulator_code(36, false).as_deref(), Some("Enter"));
        assert_eq!(
            simulator_code(40, true).as_deref(),
            Some("Enter"),
            "the iPad's Return"
        );
        assert_eq!(simulator_code(123, false).as_deref(), Some("ArrowLeft"));
        assert_eq!(simulator_code(80, true).as_deref(), Some("ArrowLeft"));
        assert_eq!(simulator_code(0, false), None, "kVK_ANSI_A types a letter");
        assert_eq!(simulator_code(4, true), None, "and so does its HID usage");
    }

    #[test]
    fn a_simulator_overflow_reports_the_size_it_needs_and_writes_nothing() {
        let mut tiny = [0xAA_u8; 2];
        // SAFETY: the buffer is a live local.
        let needed = unsafe { slopdesk_panel_simulator_key_code(123, false, tiny.as_mut_ptr(), tiny.len()) };
        assert_eq!(needed, "ArrowLeft".len());
        assert_eq!(tiny, [0xAA; 2], "an overflow leaves the caller's buffer alone");
    }

    #[test]
    fn the_android_tag_says_which_of_the_three_shapes_followed() {
        assert_eq!(
            android(36, false, Some("\r"), Some("\r"), 0),
            [SLOPDESK_ANDROID_KEY_KEYCODE, 0, 0, 0, 66, 0, 0, 0, 0],
            "Return is keycode 66 with no meta state",
        );
        assert_eq!(
            android(0, false, Some("a"), Some("a"), 0),
            [SLOPDESK_ANDROID_KEY_TEXT, b'a'],
            "a letter is text",
        );
        assert_eq!(
            android(0, false, Some("a"), Some("a"), InputModifiersBits::COMMAND),
            [SLOPDESK_ANDROID_KEY_NOTHING],
            "a chord the panel cannot name is dropped",
        );
    }

    #[test]
    fn an_absent_character_is_not_an_empty_one_across_the_boundary() {
        assert_eq!(
            android(0, false, None, Some("e"), 0),
            [SLOPDESK_ANDROID_KEY_TEXT, b'e'],
            "absent falls back to the stripped spelling",
        );
        assert_eq!(
            android(0, false, Some(""), Some("e"), 0),
            [SLOPDESK_ANDROID_KEY_NOTHING],
            "empty is a press that produced nothing, and the flag is what tells them apart",
        );
    }

    #[test]
    fn the_meta_state_door_answers_without_a_press_behind_it() {
        assert_eq!(slopdesk_panel_android_meta_state(InputModifiersBits::SHIFT), 0);
        assert_eq!(
            slopdesk_panel_android_meta_state(InputModifiersBits::COMMAND),
            0x1_0000
        );
    }

    /// The wire's modifier bits, spelled here so a test can hand the door a raw byte.
    struct InputModifiersBits;

    impl InputModifiersBits {
        const SHIFT: u8 = 1 << 0;
        const CONTROL: u8 = 1 << 1;
        const COMMAND: u8 = 1 << 3;
    }

    #[test]
    fn a_control_chord_is_dropped_the_way_a_command_chord_is() {
        assert_eq!(
            android(0, false, Some("a"), Some("a"), InputModifiersBits::CONTROL),
            [SLOPDESK_ANDROID_KEY_NOTHING],
        );
    }
}
