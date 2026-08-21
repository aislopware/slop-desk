// HIDVirtualKeyMap — USB HID keyboard usage → macOS virtual keycode (`kVK_*`).
//
// WHY A POSITIONAL TABLE AND NOT `charactersIgnoringModifiers`. The rule this whole input path is
// built on is spelled at `MetalLayerBackedView.keyDown` on the Mac's half: ALL keys ride the
// layout-level KEYCODE so the HOST's keyboard layout and input method interpret them server-side
// (Parsec / VNC "scancode mode"). A key sent as a pre-baked character is invisible to a keycode-driven
// IME composer — OpenKey reads the virtual keycode and the shift flag, never the Unicode string — so
// Vietnamese Telex would never compose. A `UIKey` hands us BOTH, and the HID usage is the one that
// carries position: it is what the physical key IS, before any layout ran.
//
// The table itself is `slopdesk_workspace::hid_virtual_key`, beside the US-QWERTY grapheme table it
// shares its `kVK_ANSI_*` numbers with — the printable run of the HID page is resolved through the
// character its key types rather than restated, so those 47 numbers exist once. This file is the
// FACE: two calls and no table.

import CSlopDeskFFI

/// USB HID keyboard usages → the macOS virtual keycodes the host's `InputInjector.postKey` posts.
public enum HIDVirtualKeyMap {
    /// The virtual keycode for `hidUsage`, or `nil` for a usage with no macOS key (media keys, the
    /// international extras past 0x64, anything off the keyboard page). A `nil` sends NOTHING — a
    /// wrong keycode on a remote desktop is worse than a dropped one.
    ///
    /// The door answers a keycode beside a FLAG rather than a sentinel, because `kVK_ANSI_A` is `0`:
    /// the commonest key on the board and "there is no key here" would otherwise be one answer.
    public static func virtualKey(hidUsage: UInt16) -> UInt16? {
        let answer = slopdesk_hid_virtual_key(hidUsage)
        return answer.mapped ? answer.key_code : nil
    }

    /// Whether `hidUsage` is a MODIFIER key (either side of ⌘⇧⌃⌥, or Caps Lock). The caller latches
    /// these so a focus change that swallows the release can synthesize the missing key-up — the
    /// `ModifierLatchTracker` discipline the Mac's `flagsChanged` feeds.
    public static func isModifier(hidUsage: UInt16) -> Bool {
        slopdesk_hid_is_modifier(hidUsage)
    }
}
