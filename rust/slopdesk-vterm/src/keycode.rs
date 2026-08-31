//! Which key was pressed, decided from where it sits on the keyboard.
//!
//! `AppKit` hands an `NSEvent` a `keyCode`: a Carbon `kVK_*` virtual keycode naming a POSITION on
//! the hardware, fixed for the life of the machine. The engine's `Key` names a LOGICAL key — the
//! thing `CSI A` and the kitty protocol are defined in terms of. Nothing in either representation
//! derives the other; the bridge between them is a table somebody transcribed once, from
//! ghostty's `src/input/keycodes.zig`, itself from Chromium's `dom_code_data.inc`.
//!
//! A table is a decision, so it lives here rather than in the Swift view. The view is a dumb
//! actuator: it reads a field off an event and forwards it. Were the table over there it would be
//! unreachable from a test — the surfaces that own an `NSEvent` are compile-only behind
//! `#if canImport(...)` — and a wrong row would show up as a key that types the wrong thing on
//! somebody's machine rather than as a red test here.
//!
//! ## What this is NOT for
//!
//! It does not tell you which CHARACTER the key produces. Position is layout-independent by
//! construction: the key at `kVK_ANSI_A` is `Key::A` on QWERTY, AZERTY and Dvorak alike, and on
//! AZERTY it types `q`. The character comes from the event's `characters` string, which the OS has
//! already run through the active layout and any dead-key composition. Feeding this table's answer
//! to a caller that wanted text would type QWERTY on every layout on earth.
//!
//! Consequently a keycode with no logical key is not an error and not a fallback — it is
//! [`None`], and the caller sends the text it already has.

use libghostty_vt::key::Key;

/// The logical key at a macOS/iOS hardware keycode, or [`None`] if that position has no
/// counterpart.
///
/// [`None`] is the only safe answer for an unknown position, and the reason it is an `Option`
/// rather than the engine's own `Key::Unidentified`: a caller that receives `Unidentified` cannot
/// tell "this key does not exist" from "this key exists and is nameless", and the encoder treats
/// the latter as something worth emitting. Answering `None` keeps a keycode nobody transcribed from
/// being encoded as a key nobody pressed.
///
/// Codes outside `0x00..=0x7E` never appear on Apple hardware — the field is a `u16` only because
/// `NSEvent.keyCode` is — and they fall out of the table as [`None`] with no special case.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "the table IS the function; splitting it would only hide rows"
)]
pub const fn key_from_macos_keycode(code: u16) -> Option<Key> {
    Some(match code {
        // Letters, in hardware order. This is the block that makes the layout point: 0x0C is `Q` on
        // a US board and `A` on a French one, and both report 0x0C.
        0x00 => Key::A,
        0x0B => Key::B,
        0x08 => Key::C,
        0x02 => Key::D,
        0x0E => Key::E,
        0x03 => Key::F,
        0x05 => Key::G,
        0x04 => Key::H,
        0x22 => Key::I,
        0x26 => Key::J,
        0x28 => Key::K,
        0x25 => Key::L,
        0x2E => Key::M,
        0x2D => Key::N,
        0x1F => Key::O,
        0x23 => Key::P,
        0x0C => Key::Q,
        0x0F => Key::R,
        0x01 => Key::S,
        0x11 => Key::T,
        0x20 => Key::U,
        0x09 => Key::V,
        0x0D => Key::W,
        0x07 => Key::X,
        0x10 => Key::Y,
        0x06 => Key::Z,

        // The number row. 5 and 6 are transposed against the obvious reading (0x17, 0x16), as are
        // 7, 8 and 9 (0x1A, 0x1C, 0x19) — that is Apple's numbering, not a transcription slip.
        0x1D => Key::Digit0,
        0x12 => Key::Digit1,
        0x13 => Key::Digit2,
        0x14 => Key::Digit3,
        0x15 => Key::Digit4,
        0x17 => Key::Digit5,
        0x16 => Key::Digit6,
        0x1A => Key::Digit7,
        0x1C => Key::Digit8,
        0x19 => Key::Digit9,

        // Punctuation, named for the US keycap the position carries.
        0x32 => Key::Backquote,
        0x2A => Key::Backslash,
        0x21 => Key::BracketLeft,
        0x1E => Key::BracketRight,
        0x2B => Key::Comma,
        0x18 => Key::Equal,
        0x1B => Key::Minus,
        0x2F => Key::Period,
        0x27 => Key::Quote,
        0x29 => Key::Semicolon,
        0x2C => Key::Slash,

        // The keys with no character of their own. 0x33 is the key Apple labels "delete", which is
        // Backspace everywhere else; the forward delete on the nav cluster is 0x75 below, and
        // swapping the two would make the Backspace key eat forwards.
        0x24 => Key::Enter,
        0x35 => Key::Escape,
        0x33 => Key::Backspace,
        0x30 => Key::Tab,
        0x31 => Key::Space,

        // The navigation cluster. 0x72 is kVK_Help — the key Apple's full-size boards label "help"
        // and everyone else labels "insert"; Chromium calls the position Insert and ghostty follows,
        // so we do too rather than invent a third answer.
        0x72 => Key::Insert,
        0x73 => Key::Home,
        0x74 => Key::PageUp,
        0x75 => Key::Delete,
        0x77 => Key::End,
        0x79 => Key::PageDown,
        0x7B => Key::ArrowLeft,
        0x7C => Key::ArrowRight,
        0x7D => Key::ArrowDown,
        0x7E => Key::ArrowUp,

        // Modifiers, sided. The side is carried by the KEY here and by `Mods`'s `*_SIDE` bits on the
        // event; they must agree, so both come off the same keycode. Note the Meta pair is reversed
        // against every other pair — right Command is 0x36 and left is 0x37.
        0x39 => Key::CapsLock,
        0x3B => Key::ControlLeft,
        0x3E => Key::ControlRight,
        0x38 => Key::ShiftLeft,
        0x3C => Key::ShiftRight,
        0x3A => Key::AltLeft,
        0x3D => Key::AltRight,
        0x37 => Key::MetaLeft,
        0x36 => Key::MetaRight,
        0x6E => Key::ContextMenu,

        // Function keys. Their codes are scattered rather than consecutive, and F13–F20 interleave
        // with the keypad block, so this is the one group where a lookup by arithmetic is wrong.
        0x7A => Key::F1,
        0x78 => Key::F2,
        0x63 => Key::F3,
        0x76 => Key::F4,
        0x60 => Key::F5,
        0x61 => Key::F6,
        0x62 => Key::F7,
        0x64 => Key::F8,
        0x65 => Key::F9,
        0x6D => Key::F10,
        0x67 => Key::F11,
        0x6F => Key::F12,
        0x69 => Key::F13,
        0x6B => Key::F14,
        0x71 => Key::F15,
        0x6A => Key::F16,
        0x40 => Key::F17,
        0x4F => Key::F18,
        0x50 => Key::F19,
        0x5A => Key::F20,

        // The keypad. Distinct from the number row on purpose: under keypad application mode the
        // engine encodes `Numpad4` as `SS3 t` and `Digit4` as the byte `4`, so folding the two would
        // break every curses program that reads the keypad. 0x47 is kVK_ANSI_KeypadClear, which
        // Chromium files as the NumLock position — Apple ships no NumLock key.
        0x47 => Key::NumLock,
        0x52 => Key::Numpad0,
        0x53 => Key::Numpad1,
        0x54 => Key::Numpad2,
        0x55 => Key::Numpad3,
        0x56 => Key::Numpad4,
        0x57 => Key::Numpad5,
        0x58 => Key::Numpad6,
        0x59 => Key::Numpad7,
        0x5B => Key::Numpad8,
        0x5C => Key::Numpad9,
        0x45 => Key::NumpadAdd,
        0x41 => Key::NumpadDecimal,
        0x4B => Key::NumpadDivide,
        0x4C => Key::NumpadEnter,
        0x51 => Key::NumpadEqual,
        0x43 => Key::NumpadMultiply,
        0x4E => Key::NumpadSubtract,

        // International keys and the media row, which the fork itself cannot name.
        //
        // These seven — IntlBackslash, IntlRo, IntlYen, NumpadComma and the three AudioVolume
        // positions — carry a W3C code in ghostty's raw table but are absent from its `code_to_key`
        // map, so `entries` resolves each to `.unidentified` at this pin. The bindings' `Key`
        // declares all seven anyway, and the position is genuinely known, so naming it here loses
        // nothing: the alternative is `None`, which throws away information the caller cannot get
        // back. A caller that wants the fork's exact behaviour should ignore the answer, not ask a
        // narrower question.
        0x0A => Key::IntlBackslash,
        0x5E => Key::IntlRo,
        0x5D => Key::IntlYen,
        0x5F => Key::NumpadComma,
        0x4A => Key::AudioVolumeMute,
        0x48 => Key::AudioVolumeUp,
        0x49 => Key::AudioVolumeDown,

        // Deliberately absent, and the reason differs:
        //
        // 0x66 kVK_JIS_Eisu and 0x68 kVK_JIS_Kana map to Lang2 and Lang1, which the bindings' `Key`
        // does not declare at all — there is no variant to return. They are also missing from
        // ghostty's `code_to_key`, so the fork would answer `.unidentified` for them too. Both are
        // IME toggles the input method consumes before a key event ever reaches a terminal.
        //
        // 0x3F kVK_Function is unmapped upstream as well — ghostty's own table carries a TODO for
        // it — and Apple's Fn key is a layer shift rather than a key an application sees.
        //
        // PrintScreen, ScrollLock, Pause, F21–F24, Power, Help and the media-transport keys were
        // never candidates: their mac column in the raw table is the 0xFFFF sentinel, meaning no
        // such position exists on Apple hardware.
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use libghostty_vt::key::Key;

    use super::key_from_macos_keycode;

    #[test]
    fn a_letter_maps_by_position_so_the_answer_is_the_same_on_every_layout() {
        assert_eq!(key_from_macos_keycode(0x00), Some(Key::A));
        assert_eq!(
            key_from_macos_keycode(0x0C),
            Some(Key::Q),
            "the position AZERTY types `a` from is still Q, because this is not the character"
        );
        assert_eq!(key_from_macos_keycode(0x06), Some(Key::Z));
    }

    #[test]
    fn the_number_row_keeps_apples_transposed_order() {
        assert_eq!(key_from_macos_keycode(0x12), Some(Key::Digit1));
        assert_eq!(key_from_macos_keycode(0x17), Some(Key::Digit5));
        assert_eq!(
            key_from_macos_keycode(0x16),
            Some(Key::Digit6),
            "5 and 6 are transposed against the obvious reading"
        );
        assert_eq!(key_from_macos_keycode(0x1D), Some(Key::Digit0));
    }

    #[test]
    fn the_key_apple_labels_delete_is_backspace_and_the_forward_one_is_not() {
        assert_eq!(key_from_macos_keycode(0x24), Some(Key::Enter));
        assert_eq!(key_from_macos_keycode(0x35), Some(Key::Escape));
        assert_eq!(key_from_macos_keycode(0x30), Some(Key::Tab));
        assert_eq!(key_from_macos_keycode(0x31), Some(Key::Space));
        assert_eq!(key_from_macos_keycode(0x33), Some(Key::Backspace));
        assert_eq!(
            key_from_macos_keycode(0x75),
            Some(Key::Delete),
            "forward delete is a separate position; swapping the two erases the wrong side"
        );
    }

    #[test]
    fn the_four_arrows_are_four_distinct_keys_in_apples_own_order() {
        assert_eq!(key_from_macos_keycode(0x7B), Some(Key::ArrowLeft));
        assert_eq!(key_from_macos_keycode(0x7C), Some(Key::ArrowRight));
        assert_eq!(key_from_macos_keycode(0x7D), Some(Key::ArrowDown));
        assert_eq!(key_from_macos_keycode(0x7E), Some(Key::ArrowUp));
    }

    #[test]
    fn a_function_key_is_found_by_the_table_and_never_by_arithmetic() {
        assert_eq!(key_from_macos_keycode(0x7A), Some(Key::F1));
        assert_eq!(key_from_macos_keycode(0x78), Some(Key::F2));
        assert_eq!(
            key_from_macos_keycode(0x63),
            Some(Key::F3),
            "F3 is nowhere near F2; the codes are scattered"
        );
        assert_eq!(key_from_macos_keycode(0x6D), Some(Key::F10));
        assert_eq!(key_from_macos_keycode(0x5A), Some(Key::F20));
    }

    #[test]
    fn a_modifier_carries_its_side_and_the_command_pair_runs_backwards() {
        assert_eq!(key_from_macos_keycode(0x38), Some(Key::ShiftLeft));
        assert_eq!(key_from_macos_keycode(0x3C), Some(Key::ShiftRight));
        assert_eq!(key_from_macos_keycode(0x3B), Some(Key::ControlLeft));
        assert_eq!(
            key_from_macos_keycode(0x37),
            Some(Key::MetaLeft),
            "left Command is the HIGHER of the Meta pair"
        );
        assert_eq!(key_from_macos_keycode(0x36), Some(Key::MetaRight));
    }

    #[test]
    fn the_keypad_never_collapses_into_the_number_row() {
        assert_eq!(key_from_macos_keycode(0x56), Some(Key::Numpad4));
        assert_ne!(
            key_from_macos_keycode(0x56),
            key_from_macos_keycode(0x15),
            "keypad application mode encodes the two differently"
        );
        assert_eq!(key_from_macos_keycode(0x4C), Some(Key::NumpadEnter));
        assert_ne!(key_from_macos_keycode(0x4C), key_from_macos_keycode(0x24));
    }

    #[test]
    fn an_unassigned_keycode_answers_none_rather_than_a_neighbour() {
        for code in [0x34_u16, 0x42, 0x44, 0x46, 0x4D, 0x6C, 0x70] {
            assert_eq!(key_from_macos_keycode(code), None, "gap at {code:#04x}");
        }
        assert_eq!(
            key_from_macos_keycode(0x3F),
            None,
            "kVK_Function is a layer shift, not a key an application sees"
        );
        for code in [0x66_u16, 0x68] {
            assert_eq!(
                key_from_macos_keycode(code),
                None,
                "the JIS IME toggles have no variant in the bindings' Key"
            );
        }
        assert_eq!(
            key_from_macos_keycode(0x7F),
            None,
            "the table ends at 0x7E; nothing above it exists on Apple hardware"
        );
        assert_eq!(key_from_macos_keycode(u16::MAX), None);
    }

    #[test]
    fn the_positions_the_fork_cannot_name_are_still_named_here() {
        assert_eq!(key_from_macos_keycode(0x0A), Some(Key::IntlBackslash));
        assert_eq!(key_from_macos_keycode(0x5D), Some(Key::IntlYen));
        assert_eq!(key_from_macos_keycode(0x5E), Some(Key::IntlRo));
        assert_eq!(key_from_macos_keycode(0x5F), Some(Key::NumpadComma));
        assert_eq!(key_from_macos_keycode(0x4A), Some(Key::AudioVolumeMute));
    }
}
