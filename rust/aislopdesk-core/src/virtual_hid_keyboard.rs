//! Virtual-HID keyboard core — a port of Swift `VirtualHIDKeyboard` /
//! `HIDKeyboardState` (`Sources/AislopdeskVideoHost/VirtualHIDKeyboard.swift`).
//!
//! This is the device-independent half of the "type into a macOS `SecurityAgent`
//! login/password dialog from the remote client" path. Secure Event Input
//! (`IsSecureEventInputEnabled()` is `true` while a password prompt is up) blocks the
//! synthetic-`CGEvent` injection path the host normally uses — that is exactly the
//! anti-keylogger filter — but it does NOT block input ingested from a HID *device*.
//! A `DriverKit` virtual HID keyboard (Karabiner-DriverKit-VirtualHIDDevice) delivers
//! reports at the HID layer, so the system treats them like a real USB keyboard and
//! they reach the secure field.
//!
//! The functions here map macOS virtual keycodes (`kVK_*`, the codes the client already
//! forwards) to USB HID **Keyboard/Keypad** usage codes (usage page `0x07`) and fold a
//! stream of key down/up events into the 8-byte **boot-protocol** keyboard reports the
//! dext consumes. Everything is pure (no I/O); the socket transport to the Karabiner
//! daemon lives above this crate.
//!
//! The Swift source is gated `#if os(macOS)` because it is compiled into the host
//! target; the Rust port carries no platform gate — the keycode/usage math is portable
//! and is exactly what a future Android host would reuse over the FFI boundary.

use crate::input_event::InputModifiers;
use std::collections::BTreeSet;

// MARK: macOS virtual keycode -> HID usage (page 0x07)

/// USB HID Keyboard/Keypad usage (usage page `0x07`) for a macOS virtual keycode
/// (`kVK_*`), or `None` if unmapped.
///
/// Mirrors Swift `VirtualHIDKeyboard.hidUsage(forVirtualKey:)` and the `keyMap` table
/// verbatim. Covers the full ANSI set plus the keys a password entry needs (letters, digits,
/// symbols, return, delete, tab, space, escape, arrows, function keys). The source maps
/// the modifier keys too (so a held modifier can be recognised), but
/// [`HIDKeyboardState`] reflects modifiers via the report's modifier BYTE, not the key
/// array — see [`is_modifier_key`].
#[must_use]
pub const fn hid_usage(vk: u16) -> Option<u8> {
    // Source: the kVK_* constants <-> the USB HID Usage Tables §10 Keyboard/Keypad.
    // ANSI layout. Transcribed verbatim from the Swift `keyMap` literal.
    let usage = match vk {
        // Letters (kVK_ANSI_A=0x00 ... the famously non-alphabetical Apple order).
        0x00 => 0x04, // a
        0x0B => 0x05, // b
        0x08 => 0x06, // c
        0x02 => 0x07, // d
        0x0E => 0x08, // e
        0x03 => 0x09, // f
        0x05 => 0x0A, // g
        0x04 => 0x0B, // h
        0x22 => 0x0C, // i
        0x26 => 0x0D, // j
        0x28 => 0x0E, // k
        0x25 => 0x0F, // l
        0x2E => 0x10, // m
        0x2D => 0x11, // n
        0x1F => 0x12, // o
        0x23 => 0x13, // p
        0x0C => 0x14, // q
        0x0F => 0x15, // r
        0x01 => 0x16, // s
        0x11 => 0x17, // t
        0x20 => 0x18, // u
        0x09 => 0x19, // v
        0x0D => 0x1A, // w
        0x07 => 0x1B, // x
        0x10 => 0x1C, // y
        0x06 => 0x1D, // z
        // Digit row (1..9,0).
        0x12 => 0x1E, // 1
        0x13 => 0x1F, // 2
        0x14 => 0x20, // 3
        0x15 => 0x21, // 4
        0x17 => 0x22, // 5
        0x16 => 0x23, // 6
        0x1A => 0x24, // 7
        0x1C => 0x25, // 8
        0x19 => 0x26, // 9
        0x1D => 0x27, // 0
        // Whitespace + edit.
        0x24 => 0x28, // Return
        0x35 => 0x29, // Escape
        0x33 => 0x2A, // Delete (Backspace)
        0x30 => 0x2B, // Tab
        0x31 => 0x2C, // Space
        0x75 => 0x4C, // Forward Delete
        // Symbols.
        0x1B => 0x2D, // - _
        0x18 => 0x2E, // = +
        0x21 => 0x2F, // [ {
        0x1E => 0x30, // ] }
        0x2A => 0x31, // \ |
        0x29 => 0x33, // ; :
        0x27 => 0x34, // ' "
        0x32 => 0x35, // ` ~
        0x2B => 0x36, // , <
        0x2F => 0x37, // . >
        0x2C => 0x38, // / ?
        // Navigation.
        0x7E => 0x52, // Up
        0x7D => 0x51, // Down
        0x7B => 0x50, // Left
        0x7C => 0x4F, // Right
        0x73 => 0x4A, // Home
        0x77 => 0x4D, // End
        0x74 => 0x4B, // Page Up
        0x79 => 0x4E, // Page Down
        // Function row.
        0x7A => 0x3A, // F1
        0x78 => 0x3B, // F2
        0x63 => 0x3C, // F3
        0x76 => 0x3D, // F4
        0x60 => 0x3E, // F5
        0x61 => 0x3F, // F6
        0x62 => 0x40, // F7
        0x64 => 0x41, // F8
        0x65 => 0x42, // F9
        0x6D => 0x43, // F10
        0x67 => 0x44, // F11
        0x6F => 0x45, // F12
        _ => return None,
    };
    Some(usage)
}

/// Whether a macOS virtual keycode is a modifier key
/// (shift/control/option/command/fn/capsLock). Mirrors Swift
/// `VirtualHIDKeyboard.isModifierKey(_:)` and the `modifierKeys` set.
///
/// Such a key is carried in the report's modifier BYTE (derived from
/// [`InputModifiers`] via [`modifier_byte`]), NOT the key array.
#[must_use]
// The ten modifier keycodes happen to be contiguous (0x36..=0x3F), but they are kept as
// the explicit per-keycode list — each labelled with its kVK_* name — to transcribe the
// Swift `modifierKeys` set verbatim for parity review, rather than collapse to a range.
#[allow(clippy::manual_range_patterns)]
pub const fn is_modifier_key(vk: u16) -> bool {
    matches!(
        vk,
        0x37 // kVK_Command
            | 0x36 // kVK_RightCommand
            | 0x38 // kVK_Shift
            | 0x3C // kVK_RightShift
            | 0x3A // kVK_Option
            | 0x3D // kVK_RightOption
            | 0x3B // kVK_Control
            | 0x3E // kVK_RightControl
            | 0x39 // kVK_CapsLock
            | 0x3F // kVK_Function
    )
}

/// The HID boot-keyboard MODIFIER byte (report byte 0) for our [`InputModifiers`].
/// Mirrors Swift `VirtualHIDKeyboard.modifierByte(_:)`.
///
/// Bits (left variants): ctrl `0x01`, shift `0x02`, alt/option `0x04`, GUI/command
/// `0x08`. `CapsLock` + Fn are NOT HID modifier-byte bits (`CapsLock` is a lock key; the
/// client uses Shift for case), so they are omitted — uppercase comes through Shift
/// exactly as a physical keyboard would send it.
#[must_use]
pub const fn modifier_byte(m: InputModifiers) -> u8 {
    let mut b: u8 = 0;
    if m.contains(InputModifiers::CONTROL) {
        b |= 0x01;
    }
    if m.contains(InputModifiers::SHIFT) {
        b |= 0x02;
    }
    if m.contains(InputModifiers::OPTION) {
        b |= 0x04;
    }
    if m.contains(InputModifiers::COMMAND) {
        b |= 0x08;
    }
    b
}

/// Build an 8-byte boot-protocol keyboard report:
/// `[modifiers, 0x00, k1, k2, k3, k4, k5, k6]`. Mirrors Swift
/// `VirtualHIDKeyboard.bootReport(modifiers:keys:)`.
///
/// The HID boot keyboard reports at most 6 concurrent non-modifier keys; if more than 6
/// are held the spec says fill all six key slots with `0x01` (`ErrorRollOver`). Keys are
/// emitted in ascending usage order for a deterministic report (the order is irrelevant
/// to the host).
#[must_use]
pub fn boot_report(modifiers: u8, keys: &[u8]) -> Vec<u8> {
    let mut report: Vec<u8> = vec![modifiers, 0x00, 0, 0, 0, 0, 0, 0];
    let mut sorted: Vec<u8> = keys.to_vec();
    sorted.sort_unstable();
    if sorted.len() > 6 {
        for slot in report.iter_mut().skip(2) {
            *slot = 0x01; // ErrorRollOver
        }
    } else {
        for (i, k) in sorted.iter().enumerate() {
            report[2 + i] = *k;
        }
    }
    report
}

/// Folds a stream of key down/up events into HID boot-keyboard reports — the stateful
/// half that the host's virtual-HID backend drives. A port of Swift `HIDKeyboardState`.
///
/// HID keyboard reports carry the FULL set of currently pressed keys plus the modifier
/// byte, so this tracks pressed non-modifier usages and rebuilds the report on each
/// change. Pure value type (no I/O). The pressed set is a [`BTreeSet`] so iteration —
/// and therefore the report — is deterministic regardless of insertion order (the Swift
/// source uses an unordered `Set` and sorts inside [`boot_report`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HIDKeyboardState {
    /// Currently-pressed non-modifier HID usages.
    pressed: BTreeSet<u8>,
}

impl HIDKeyboardState {
    /// A fresh state with no keys held. Mirrors Swift `HIDKeyboardState.init()`.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The currently-pressed non-modifier HID usages (introspection / parity with the
    /// Swift `private(set) var pressed`).
    #[must_use]
    pub const fn pressed(&self) -> &BTreeSet<u8> {
        &self.pressed
    }

    /// Apply one key event and return the report to send, or `None` if the event maps
    /// to nothing (an unmapped key). Mirrors Swift
    /// `HIDKeyboardState.apply(virtualKey:down:modifiers:)`.
    ///
    /// Modifiers come from the authoritative [`InputModifiers`] carried on every event —
    /// a held Shift is reflected in the report's modifier byte, not the key array, so a
    /// modifier key never enters [`pressed`](Self::pressed()). A modifier keycode emits a
    /// report so a lone press/release still lands. A no-op repeat (autorepeat down on an
    /// already-pressed key) still re-emits so the host sees the key held; releasing a key
    /// that was never pressed likewise still re-emits (the `changed` flag is discarded in
    /// the Swift source).
    #[must_use]
    pub fn apply(
        &mut self,
        virtual_key: u16,
        down: bool,
        modifiers: InputModifiers,
    ) -> Option<Vec<u8>> {
        let mod_byte = modifier_byte(modifiers);
        if is_modifier_key(virtual_key) {
            // The modifier byte already reflects the new state — emit a report so the
            // change lands even when no regular key is involved.
            return Some(boot_report(mod_byte, &self.pressed_keys()));
        }
        let usage = hid_usage(virtual_key)?;
        if down {
            self.pressed.insert(usage);
        } else {
            self.pressed.remove(&usage);
        }
        Some(boot_report(mod_byte, &self.pressed_keys()))
    }

    /// The all-zero report (no keys, no modifiers). Mirrors Swift
    /// `HIDKeyboardState.releaseAllReport()`.
    ///
    /// Pure — does NOT clear the folded press state; a caller actually RELEASING the
    /// keyboard must use [`release_all`](Self::release_all) so the in-memory model
    /// matches the zero report it sends.
    #[must_use]
    // Instance method to mirror Swift's `HIDKeyboardState.releaseAllReport()` (a
    // non-mutating method on the value type); the all-zero report is independent of
    // state, so `self` is intentionally unused.
    #[allow(clippy::unused_self)]
    pub fn release_all_report(&self) -> Vec<u8> {
        boot_report(0, &[])
    }

    /// Releases every key/modifier: CLEARS the folded press state AND returns the
    /// all-zero report to send (teardown, or the virtual-HID -> `CGEvent` backend switch).
    /// Mirrors Swift `HIDKeyboardState.releaseAll()`.
    ///
    /// Without clearing [`pressed`](Self::pressed()), a later key event would fold into the
    /// STALE set via [`apply`](Self::apply) and re-assert the previously-held key(s) as
    /// phantom presses into the NEXT secure field — a key the user never pressed.
    #[must_use]
    pub fn release_all(&mut self) -> Vec<u8> {
        self.pressed.clear();
        self.release_all_report()
    }

    /// The pressed usages as a `Vec` for [`boot_report`]. `BTreeSet` iteration already
    /// yields ascending order, so the report is deterministic before `boot_report` even
    /// re-sorts.
    fn pressed_keys(&self) -> Vec<u8> {
        self.pressed.iter().copied().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Convenience modifier-set builders mirroring the Swift `OptionSet` literals.
    const fn mods(raw: u8) -> InputModifiers {
        InputModifiers(raw)
    }

    // MARK: keycode -> HID usage (mirrors Swift `VirtualHIDKeyboardTests`).

    #[test]
    fn letter_mapping() {
        assert_eq!(hid_usage(0x00), Some(0x04)); // kVK_ANSI_A -> HID a
        assert_eq!(hid_usage(0x06), Some(0x1D)); // kVK_ANSI_Z -> HID z
        assert_eq!(hid_usage(0x11), Some(0x17)); // kVK_ANSI_T -> HID t
    }

    #[test]
    fn digit_and_symbol_mapping() {
        assert_eq!(hid_usage(0x12), Some(0x1E)); // 1
        assert_eq!(hid_usage(0x1D), Some(0x27)); // 0
        assert_eq!(hid_usage(0x18), Some(0x2E)); // = +
        assert_eq!(hid_usage(0x2C), Some(0x38)); // / ?
    }

    #[test]
    fn edit_and_nav_keys() {
        assert_eq!(hid_usage(0x24), Some(0x28)); // Return
        assert_eq!(hid_usage(0x33), Some(0x2A)); // Delete/Backspace
        assert_eq!(hid_usage(0x31), Some(0x2C)); // Space
        assert_eq!(hid_usage(0x35), Some(0x29)); // Escape
        assert_eq!(hid_usage(0x7C), Some(0x4F)); // Right arrow
    }

    #[test]
    fn unmapped_key_returns_none() {
        assert_eq!(hid_usage(0xFFFF), None);
    }

    // MARK: modifier byte.

    #[test]
    fn modifier_byte_bits() {
        assert_eq!(modifier_byte(InputModifiers::default()), 0x00);
        assert_eq!(modifier_byte(InputModifiers::SHIFT), 0x02);
        assert_eq!(modifier_byte(InputModifiers::CONTROL), 0x01);
        assert_eq!(modifier_byte(InputModifiers::OPTION), 0x04);
        assert_eq!(modifier_byte(InputModifiers::COMMAND), 0x08);
        assert_eq!(
            modifier_byte(InputModifiers::COMMAND.union(InputModifiers::SHIFT)),
            0x0A
        );
        // CapsLock + Fn are NOT modifier-byte bits (case comes via Shift).
        assert_eq!(
            modifier_byte(InputModifiers::CAPS_LOCK.union(InputModifiers::FUNCTION)),
            0x00
        );
    }

    #[test]
    fn modifier_key_detection() {
        assert!(is_modifier_key(0x38)); // kVK_Shift
        assert!(is_modifier_key(0x37)); // kVK_Command
        assert!(!is_modifier_key(0x00)); // a is not a modifier
    }

    // MARK: boot report.

    #[test]
    fn boot_report_layout() {
        assert_eq!(
            boot_report(0x02, &[0x04]),
            vec![0x02, 0x00, 0x04, 0, 0, 0, 0, 0],
            "shift + 'a' -> 'A'"
        );
        assert_eq!(
            boot_report(0, &[]),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
            "empty report"
        );
    }

    #[test]
    fn boot_report_sorts_keys() {
        assert_eq!(
            boot_report(0, &[0x10, 0x04, 0x08]),
            vec![0, 0, 0x04, 0x08, 0x10, 0, 0, 0]
        );
    }

    #[test]
    fn boot_report_rolls_over_past_six() {
        let r = boot_report(0, &[1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(
            &r[2..],
            &[0x01, 0x01, 0x01, 0x01, 0x01, 0x01],
            "ErrorRollOver"
        );
    }

    // MARK: stateful fold (typing "Ab").

    #[test]
    fn typing_shifted_then_unshifted() {
        let mut s = HIDKeyboardState::new();
        // Shift down -> modifier byte set, no keys.
        assert_eq!(
            s.apply(0x38, true, InputModifiers::SHIFT),
            Some(vec![0x02, 0, 0, 0, 0, 0, 0, 0])
        );
        // 'a' down with shift held -> 'A'.
        assert_eq!(
            s.apply(0x00, true, InputModifiers::SHIFT),
            Some(vec![0x02, 0, 0x04, 0, 0, 0, 0, 0])
        );
        // 'a' up.
        assert_eq!(
            s.apply(0x00, false, InputModifiers::SHIFT),
            Some(vec![0x02, 0, 0, 0, 0, 0, 0, 0])
        );
        // Shift up.
        assert_eq!(
            s.apply(0x38, false, InputModifiers::default()),
            Some(vec![0, 0, 0, 0, 0, 0, 0, 0])
        );
        // 'b' down, no modifiers -> 'b'.
        assert_eq!(
            s.apply(0x0B, true, InputModifiers::default()),
            Some(vec![0, 0, 0x05, 0, 0, 0, 0, 0])
        );
        assert_eq!(
            s.apply(0x0B, false, InputModifiers::default()),
            Some(vec![0, 0, 0, 0, 0, 0, 0, 0])
        );
    }

    #[test]
    fn two_keys_held_concurrently() {
        let mut s = HIDKeyboardState::new();
        let _ = s.apply(0x00, true, InputModifiers::default()); // a
        let r = s.apply(0x0B, true, InputModifiers::default()); // + b
        assert_eq!(
            r,
            Some(vec![0, 0, 0x04, 0x05, 0, 0, 0, 0]),
            "both a(0x04) and b(0x05) held"
        );
    }

    #[test]
    fn unmapped_key_yields_no_report() {
        let mut s = HIDKeyboardState::new();
        assert_eq!(s.apply(0xFFFF, true, InputModifiers::default()), None);
    }

    #[test]
    fn release_all_report_is_zero() {
        assert_eq!(
            HIDKeyboardState::new().release_all_report(),
            vec![0, 0, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn release_all_clears_held_keys_so_later_keys_are_not_phantom_reasserted() {
        // release_all() must CLEAR the folded press state, not merely return the zero
        // report. Otherwise a key held when the keyboard was released re-appears in the
        // NEXT key's report — a phantom press typed into the next secure (password)
        // field, a key the user never pressed.
        let mut s = HIDKeyboardState::new();
        let _ = s.apply(0x00, true, InputModifiers::default()); // press 'a' (held, never released)
        assert_eq!(
            s.release_all(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
            "release ships the all-zero report"
        );
        // Type 'b' next: the report must contain ONLY 'b' (0x05), NOT the held 'a'.
        let r = s.apply(0x0B, true, InputModifiers::default());
        assert_eq!(
            r,
            Some(vec![0, 0, 0x05, 0, 0, 0, 0, 0]),
            "the released 'a' is gone — no phantom re-assertion"
        );
    }

    // MARK: ADDED edge cases.

    #[test]
    fn hid_usage_is_const() {
        // `hid_usage` is `const fn` — usable in const context.
        const A: Option<u8> = hid_usage(0x00);
        const NONE: Option<u8> = hid_usage(0xFFFF);
        assert_eq!(A, Some(0x04));
        assert_eq!(NONE, None);
    }

    #[test]
    fn key_map_has_exactly_73_entries_all_distinct_nonzero() {
        // The transcribed table maps 26 letters + 10 digits + 6 whitespace/edit
        // + 11 symbols + 8 navigation + 12 function = 73 keycodes. Sweep the whole
        // u16 space and prove the count, that every usage is a distinct nonzero
        // page-0x07 value (a real Keyboard/Keypad usage is never 0), and within range.
        let mut usages = BTreeSet::new();
        let mut count = 0usize;
        for vk in 0u16..=u16::MAX {
            if let Some(u) = hid_usage(vk) {
                count += 1;
                assert_ne!(u, 0x00, "usage 0 is the 'no event' sentinel, never mapped");
                assert!(
                    u <= 0x52,
                    "all mapped usages stay within the populated range"
                );
                assert!(
                    usages.insert(u),
                    "duplicate HID usage {u:#04x} for vk {vk:#06x}"
                );
            }
        }
        assert_eq!(count, 73);
        assert_eq!(usages.len(), 73);
    }

    #[test]
    fn every_modifier_keycode_is_detected_and_no_letter_is() {
        for &vk in &[
            0x37u16, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x39, 0x3F,
        ] {
            assert!(is_modifier_key(vk), "vk {vk:#06x} should be a modifier");
        }
        // A representative non-modifier sweep: every mapped HID key is NOT a modifier.
        for vk in 0u16..=u16::MAX {
            if hid_usage(vk).is_some() {
                assert!(
                    !is_modifier_key(vk),
                    "mapped HID key {vk:#06x} must not be a modifier keycode"
                );
            }
        }
    }

    #[test]
    fn modifier_byte_all_bits() {
        let all = InputModifiers::CONTROL
            .union(InputModifiers::SHIFT)
            .union(InputModifiers::OPTION)
            .union(InputModifiers::COMMAND);
        assert_eq!(modifier_byte(all), 0x0F);
        // Adding the non-bit modifiers does not change the byte.
        let with_locks = all
            .union(InputModifiers::CAPS_LOCK)
            .union(InputModifiers::FUNCTION);
        assert_eq!(modifier_byte(with_locks), 0x0F);
    }

    #[test]
    fn boot_report_exactly_six_keys_is_not_rollover() {
        // 6 is the boundary: filled verbatim, NOT ErrorRollOver.
        assert_eq!(
            boot_report(0, &[6, 5, 4, 3, 2, 1]),
            vec![0, 0, 1, 2, 3, 4, 5, 6]
        );
    }

    #[test]
    fn boot_report_rollover_keeps_modifier_byte() {
        assert_eq!(
            boot_report(0x02, &[1, 2, 3, 4, 5, 6, 7]),
            vec![0x02, 0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01]
        );
    }

    #[test]
    fn modifier_keycode_with_keys_held_reemits_full_state() {
        // Pressing a modifier KEY while a regular key is held re-emits a report that
        // carries both the modifier byte AND the held key array.
        let mut s = HIDKeyboardState::new();
        let _ = s.apply(0x00, true, InputModifiers::default()); // 'a' held
        let r = s.apply(0x38, true, InputModifiers::SHIFT); // Shift down
        assert_eq!(r, Some(vec![0x02, 0, 0x04, 0, 0, 0, 0, 0]));
        assert_eq!(
            s.pressed(),
            &BTreeSet::from([0x04]),
            "modifier key never enters pressed"
        );
    }

    #[test]
    fn autorepeat_down_on_held_key_reemits_same_report() {
        let mut s = HIDKeyboardState::new();
        let first = s.apply(0x00, true, InputModifiers::default());
        let repeat = s.apply(0x00, true, InputModifiers::default());
        assert_eq!(first, repeat, "autorepeat re-emits the held-key report");
        assert_eq!(first, Some(vec![0, 0, 0x04, 0, 0, 0, 0, 0]));
    }

    #[test]
    fn release_of_unpressed_key_still_emits_report() {
        // Swift discards the `changed` flag and always emits for a mapped key.
        let mut s = HIDKeyboardState::new();
        let r = s.apply(0x00, false, InputModifiers::default()); // 'a' up, never pressed
        assert_eq!(r, Some(vec![0, 0, 0, 0, 0, 0, 0, 0]));
        assert!(s.pressed().is_empty());
    }

    #[test]
    fn release_all_resets_to_default_state() {
        let mut s = HIDKeyboardState::new();
        let _ = s.apply(0x00, true, InputModifiers::default());
        let _ = s.apply(0x0B, true, InputModifiers::default());
        assert_eq!(s.pressed().len(), 2);
        let _ = s.release_all();
        assert_eq!(
            s,
            HIDKeyboardState::new(),
            "release_all returns to the fresh state"
        );
    }

    #[test]
    fn release_all_report_does_not_clear_state() {
        // releaseAllReport() is the PURE variant: returns zeros but leaves pressed intact.
        let mut s = HIDKeyboardState::new();
        let _ = s.apply(0x00, true, InputModifiers::default());
        assert_eq!(s.release_all_report(), vec![0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(
            s.pressed(),
            &BTreeSet::from([0x04]),
            "state untouched by the pure report"
        );
    }

    #[test]
    fn insertion_order_independent_report() {
        // BTreeSet + boot_report sort -> the report is the same regardless of which key
        // was pressed first.
        let mut a = HIDKeyboardState::new();
        let _ = a.apply(0x0B, true, InputModifiers::default()); // b first (0x05)
        let ra = a.apply(0x00, true, InputModifiers::default()); // then a (0x04)
        let mut b = HIDKeyboardState::new();
        let _ = b.apply(0x00, true, InputModifiers::default()); // a first
        let rb = b.apply(0x0B, true, InputModifiers::default()); // then b
        assert_eq!(ra, rb);
        assert_eq!(ra, Some(vec![0, 0, 0x04, 0x05, 0, 0, 0, 0]));
    }

    #[test]
    fn mods_helper_matches_named_constants() {
        // Sanity-check the local raw-bit helper against the named modifier constants.
        // InputModifiers WIRE bits: shift=1<<0, control=1<<1, option=1<<2, command=1<<3.
        assert_eq!(
            modifier_byte(mods(0x01)),
            modifier_byte(InputModifiers::SHIFT)
        );
        assert_eq!(
            modifier_byte(mods(0x02)),
            modifier_byte(InputModifiers::CONTROL)
        );
        // command (wire 0x08) | control (wire 0x02) -> HID command 0x08 | control 0x01 = 0x09.
        assert_eq!(modifier_byte(mods(0x08 | 0x02)), 0x09);
    }
}
