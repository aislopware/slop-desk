//! A hardware keyboard's HID usages as macOS virtual keycodes, in C —
//! `Sources/SlopDeskVideoClient/HIDVirtualKeyMap.swift`.
//!
//! The rules are [`slopdesk_workspace::hid_virtual_key`]; what is here is the marshalling. Both
//! doors are `docs/55` §4's "entry that takes no memory at all": one `u16` in, a small `#[repr(C)]`
//! record or a `bool` out, nothing allocated and nothing retained.
//!
//! ## Why the answer is not just a `uint16_t`
//!
//! A usage with no macOS key must send NOTHING — a wrong keycode on a remote desktop types the
//! wrong character into someone's editor — and `0` cannot say so, because `kVK_ANSI_A` IS `0` and
//! `a` is the commonest key on the board. So the `Option` crosses as a value beside a flag, which
//! is `docs/55` §4's rule stated at its narrowest: a sentinel is admissible only when it is outside
//! the answer's range by construction, and here the answer's range is every `u16` the table holds.

use slopdesk_workspace::hid_virtual_key;

/// The virtual keycode for one HID usage, and whether there is one at all.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskHidVirtualKey {
    /// The `kVK_*` code the host posts, meaningful only while `mapped`.
    pub key_code: u16,
    /// Whether this usage has a macOS key. False for the media keys, the international extras past
    /// 0x64, and anything off the keyboard page.
    pub mapped: bool,
}

/// The virtual keycode for `hid_usage`, or an unmapped answer the caller must send nothing for.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_hid_virtual_key(hid_usage: u16) -> SlopDeskHidVirtualKey {
    hid_virtual_key::virtual_key(hid_usage).map_or_else(SlopDeskHidVirtualKey::default, |key_code| {
        SlopDeskHidVirtualKey {
            key_code,
            mapped: true,
        }
    })
}

/// Whether `hid_usage` is a MODIFIER key — either side of ⌘⇧⌃⌥, or Caps Lock.
///
/// The caller latches these so a focus change that swallows the release can synthesize the missing
/// key-up.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_hid_is_modifier(hid_usage: u16) -> bool {
    hid_virtual_key::is_modifier(hid_usage)
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_hid_is_modifier, slopdesk_hid_virtual_key};

    /// The unmapped case is the one the shape exists for: `kVK_ANSI_A` is `0`, so a caller reading
    /// the code alone could not tell "the letter a" from "no key at all".
    #[test]
    fn the_absent_key_crosses_as_a_flag_beside_a_keycode_that_is_zero() {
        let letter = slopdesk_hid_virtual_key(0x04);
        assert!(letter.mapped);
        assert_eq!(letter.key_code, 0, "kVK_ANSI_A really is zero");

        let insert = slopdesk_hid_virtual_key(0x49);
        assert!(!insert.mapped, "insert has no ANSI keycode");
        assert_eq!(insert.key_code, 0);
        assert!(!slopdesk_hid_virtual_key(0xFFFF).mapped);
    }

    #[test]
    fn the_table_answers_through_the_door() {
        assert_eq!(
            slopdesk_hid_virtual_key(0x27).key_code,
            29,
            "the page puts 0 last"
        );
        assert_eq!(slopdesk_hid_virtual_key(0x3A).key_code, 122, "F1");
        assert_eq!(slopdesk_hid_virtual_key(0xE7).key_code, 54, "right command");
    }

    #[test]
    fn the_latch_predicate_names_caps_lock_and_both_sides() {
        assert!(slopdesk_hid_is_modifier(0x39), "caps lock");
        assert!(slopdesk_hid_is_modifier(0xE0));
        assert!(slopdesk_hid_is_modifier(0xE7));
        assert!(!slopdesk_hid_is_modifier(0x04), "a is not a modifier");
    }
}
