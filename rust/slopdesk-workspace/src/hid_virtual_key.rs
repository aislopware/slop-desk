//! USB HID keyboard usage → macOS virtual keycode (`kVK_*`), for a hardware keyboard driving a
//! remote DESKTOP.
//!
//! ## Why a positional table and not a character
//!
//! The rule the whole remote-desktop input path is built on is that ALL keys ride the layout-level
//! KEYCODE, so the HOST's keyboard layout and input method interpret them server-side (the
//! "scancode mode" every remote-desktop protocol ends up with). A key sent as a pre-baked character
//! is invisible to a keycode-driven IME composer — `OpenKey` reads the virtual keycode and the
//! shift flag, never the Unicode string — so Vietnamese Telex would never compose. A key event
//! hands the client BOTH, and the HID usage is the one that carries position: it is what the
//! physical key IS, before any layout ran.
//!
//! Usage page 0x07 (Keyboard/Keypad) only. The platform's `UIKeyboardHIDUsage` is that page's
//! numbering verbatim, which is why this side of the table can be plain `u16` and this module names
//! no framework at all.
//!
//! ## The printable run is NOT a second table
//!
//! Every letter, digit and punctuation key here already has its `kVK_ANSI_*` number written down
//! once, in [`crate::keystroke_replay`], keyed by the character the key types. Restating those 47
//! numbers against HID usages instead would be the same table in two spellings, drifting the day
//! one of them was corrected — the failure `docs/55` §8 is a catalogue of. So the printable run of
//! the HID page is mapped to the CHARACTER its key carries and the code is asked for there. What is
//! left below is the run that has no character to ask about: escape, backspace, the function row,
//! the navigation cluster, the keypad, the two ISO extras and the modifiers.

use crate::keystroke_replay;

/// Caps Lock's usage — a TOGGLE, not a held key, and the reason [`is_modifier`] names it separately
/// from the contiguous run below.
const CAPS_LOCK: u16 = 0x39;

/// Left Control — the first of the eight contiguous modifier usages.
const LEFT_CONTROL: u16 = 0xE0;

/// Right GUI (⌘) — the last of them.
const RIGHT_GUI: u16 = 0xE7;

/// The virtual keycode for `hid_usage`, or `None` for a usage with no macOS key.
///
/// `None` covers the media keys, the international extras past 0x64 and anything off the keyboard
/// page. A caller that gets it must send NOTHING: a wrong keycode on a remote desktop types the
/// wrong character into someone's editor, which is worse than a dropped key.
#[must_use]
pub fn virtual_key(hid_usage: u16) -> Option<u16> {
    if let Some(byte) = printable_character(hid_usage) {
        return keystroke_replay::ascii_key_code(byte);
    }
    positional_key(hid_usage)
}

/// Whether `hid_usage` is a MODIFIER key: either side of ⌘⇧⌃⌥, or Caps Lock.
///
/// The caller latches these so a focus change that swallows the release can synthesize the missing
/// key-up.
#[must_use]
pub const fn is_modifier(hid_usage: u16) -> bool {
    hid_usage == CAPS_LOCK || (hid_usage >= LEFT_CONTROL && hid_usage <= RIGHT_GUI)
}

/// The unshifted ASCII character the key at `hid_usage` carries, for the run of the page that has
/// one.
///
/// `a`…`z` (0x04…0x1D) and `1`…`9`,`0` (0x1E…0x27) are contiguous on the HID page and contiguous in
/// ASCII, so each run is one step rather than a ladder — the two numberings genuinely agree here,
/// unlike HID against `kVK_*`, where nothing lines up. Note that the page puts ZERO LAST: an
/// off-by-one in that arm types a 9 for every 0.
fn printable_character(hid_usage: u16) -> Option<u8> {
    let usage = u8::try_from(hid_usage).ok()?;
    Some(match usage {
        0x04..=0x1D => b'a' + (usage - 0x04),
        0x1E..=0x26 => b'1' + (usage - 0x1E),
        0x27 => b'0',
        // Whitespace and Return. Escape and Backspace sit between them on the page and have no
        // character, so they are in `positional_key` instead.
        0x28 => b'\n',
        0x2B => b'\t',
        0x2C => b' ',
        // Punctuation, in HID order.
        0x2D => b'-',
        0x2E => b'=',
        0x2F => b'[',
        0x30 => b']',
        // Non-US `#` is the same physical key as `\` on an ANSI board, which is the ONE deliberate
        // collision in this table.
        0x31 | 0x32 => b'\\',
        0x33 => b';',
        0x34 => b'\'',
        0x35 => b'`',
        0x36 => b',',
        0x37 => b'.',
        0x38 => b'/',
        _ => return None,
    })
}

/// The `kVK_*` code for a key with no character on it.
///
/// A `match` and not a map: it is a fixed table read once per keypress, and a `match` is the form a
/// reviewer can check against `Carbon/HIToolbox/Events.h` by eye — the same argument
/// [`crate::keystroke_replay`] makes for its own.
const fn positional_key(hid_usage: u16) -> Option<u16> {
    Some(match hid_usage {
        0x29 => 53, // escape
        0x2A => 51, // delete (backspace)
        0x39 => 57, // caps lock
        // F1…F12 — kVK's function keys are famously out of order.
        0x3A => 122,
        0x3B => 120,
        0x3C => 99,
        0x3D => 118,
        0x3E => 96,
        0x3F => 97,
        0x40 => 98,
        0x41 => 100,
        0x42 => 101,
        0x43 => 109,
        0x44 => 103,
        0x45 => 111,
        // Navigation. Insert (0x49) has no ANSI keycode and is deliberately absent.
        0x4A => 115, // home
        0x4B => 116, // page up
        0x4C => 117, // forward delete
        0x4D => 119, // end
        0x4E => 121, // page down
        0x4F => 124, // right
        0x50 => 123, // left
        0x51 => 125, // down
        0x52 => 126, // up
        // Keypad, which shares no key with the main board: its `/` is not the `/` above.
        0x53 => 71, // num lock / clear
        0x54 => 75, // keypad /
        0x55 => 67, // keypad *
        0x56 => 78, // keypad -
        0x57 => 69, // keypad +
        0x58 => 76, // keypad enter
        0x59 => 83, // keypad 1
        0x5A => 84,
        0x5B => 85,
        0x5C => 86,
        0x5D => 87,
        0x5E => 88,
        0x5F => 89,
        0x60 => 91,
        0x61 => 92, // keypad 9
        0x62 => 82, // keypad 0
        0x63 => 65, // keypad .
        0x64 => 10, // non-US \ (ISO §/±)
        // Modifiers — both sides, because the host's latch balance counts them separately.
        0xE0 => 59, // left control
        0xE1 => 56, // left shift
        0xE2 => 58, // left option
        0xE3 => 55, // left command
        0xE4 => 62, // right control
        0xE5 => 60, // right shift
        0xE6 => 61, // right option
        0xE7 => 54, // right command
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{is_modifier, virtual_key};

    #[test]
    fn the_letter_ladder_maps_both_ends() {
        assert_eq!(virtual_key(0x04), Some(0), "a → kVK_ANSI_A");
        assert_eq!(virtual_key(0x1D), Some(6), "z → kVK_ANSI_Z");
        assert_eq!(virtual_key(0x16), Some(1), "s → kVK_ANSI_S");
        assert_eq!(virtual_key(0x0F), Some(37), "l → kVK_ANSI_L");
    }

    #[test]
    fn the_digit_ladder_puts_zero_last() {
        assert_eq!(virtual_key(0x1E), Some(18), "1 → kVK_ANSI_1");
        assert_eq!(virtual_key(0x26), Some(25), "9 → kVK_ANSI_9");
        assert_eq!(
            virtual_key(0x27),
            Some(29),
            "the HID page runs 1…9 then 0 — an off-by-one here types a 9 for every 0"
        );
    }

    #[test]
    fn editing_and_whitespace() {
        assert_eq!(virtual_key(0x28), Some(36), "return");
        assert_eq!(virtual_key(0x29), Some(53), "escape");
        assert_eq!(virtual_key(0x2A), Some(51), "backspace");
        assert_eq!(virtual_key(0x2B), Some(48), "tab");
        assert_eq!(virtual_key(0x2C), Some(49), "space");
    }

    #[test]
    fn the_punctuation_run_is_the_stroke_table_read_by_position() {
        assert_eq!(virtual_key(0x2D), Some(27), "-");
        assert_eq!(virtual_key(0x2E), Some(24), "=");
        assert_eq!(virtual_key(0x2F), Some(33), "[");
        assert_eq!(virtual_key(0x30), Some(30), "]");
        assert_eq!(virtual_key(0x33), Some(41), ";");
        assert_eq!(virtual_key(0x34), Some(39), "'");
        assert_eq!(virtual_key(0x35), Some(50), "`");
        assert_eq!(virtual_key(0x36), Some(43), ",");
        assert_eq!(virtual_key(0x37), Some(47), ".");
        assert_eq!(virtual_key(0x38), Some(44), "/");
        assert_eq!(
            virtual_key(0x54),
            Some(75),
            "the KEYPAD slash is a different key from the one above it"
        );
    }

    #[test]
    fn the_function_row_is_not_sequential() {
        assert_eq!(virtual_key(0x3A), Some(122), "F1");
        assert_eq!(virtual_key(0x3B), Some(120), "F2 — kVK's F-keys are out of order");
        assert_eq!(virtual_key(0x3E), Some(96), "F5");
        assert_eq!(virtual_key(0x45), Some(111), "F12");
    }

    #[test]
    fn arrows_and_navigation() {
        assert_eq!(virtual_key(0x4F), Some(124), "right");
        assert_eq!(virtual_key(0x50), Some(123), "left");
        assert_eq!(virtual_key(0x51), Some(125), "down");
        assert_eq!(virtual_key(0x52), Some(126), "up");
        assert_eq!(virtual_key(0x4C), Some(117), "forward delete");
    }

    /// The host's latch balance counts left and right separately; folding them would leave one side
    /// stuck down after a two-handed ⇧.
    #[test]
    fn both_sides_of_every_modifier_are_distinct() {
        let pairs = [
            (0xE0_u16, 59_u16),
            (0xE1, 56),
            (0xE2, 58),
            (0xE3, 55),
            (0xE4, 62),
            (0xE5, 60),
            (0xE6, 61),
            (0xE7, 54),
        ];
        for (usage, expected) in pairs {
            assert_eq!(virtual_key(usage), Some(expected), "usage {usage:#x}");
            assert!(is_modifier(usage), "usage {usage:#x} must latch");
        }
    }

    #[test]
    fn caps_lock_is_a_modifier_but_a_letter_is_not() {
        assert_eq!(virtual_key(0x39), Some(57), "caps lock");
        assert!(is_modifier(0x39));
        assert!(!is_modifier(0x04), "a is not a modifier");
        assert!(!is_modifier(0x28), "return is not a modifier");
    }

    /// A key with no macOS equivalent must answer `None` so the caller forwards NOTHING and lets
    /// the responder chain have it — inventing a keycode types the wrong character on someone's
    /// desktop.
    #[test]
    fn unmapped_usages_send_nothing() {
        assert_eq!(virtual_key(0x00), None, "reserved / no-event");
        assert_eq!(virtual_key(0x49), None, "insert has no ANSI keycode");
        assert_eq!(virtual_key(0x65), None, "past the mapped range");
        assert_eq!(virtual_key(0xFFFF), None, "off the keyboard page entirely");
    }

    /// Every usage that maps must map somewhere reachable, and the only DELIBERATE duplicate is the
    /// non-US `#` sharing the ANSI backslash key. A second collision means a typo in a table.
    #[test]
    fn the_table_has_no_accidental_collisions() {
        let mut owners: BTreeMap<u16, Vec<u16>> = BTreeMap::new();
        for usage in 0..=0xE7_u16 {
            if let Some(key_code) = virtual_key(usage) {
                owners.entry(key_code).or_default().push(usage);
            }
        }
        let collisions: Vec<_> = owners.into_iter().filter(|(_, seen)| seen.len() > 1).collect();
        assert_eq!(collisions, vec![(42, vec![0x31, 0x32])], "\\ and non-US #");
    }
}
