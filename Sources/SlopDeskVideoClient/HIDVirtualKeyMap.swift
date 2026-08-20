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
// Usage page 0x07 (Keyboard/Keypad) only. `UIKeyboardHIDUsage` is that page's numbering verbatim,
// which is why the far side of this table can be plain `UInt16` and this file needs no UIKit — it
// compiles (and is tested) on the Mac runner, where the iOS surface that feeds it never can be.
//
// ⚠️ PORT CANDIDATE, same as ``TouchPointerPlan``: the sibling table (US-QWERTY grapheme →
// `kVK_*`, behind `slopdesk_keystroke_replay`) already lives in Rust, and this one belongs beside it.

/// USB HID keyboard usages → the macOS virtual keycodes the host's `InputInjector.postKey` posts.
public enum HIDVirtualKeyMap {
    /// The virtual keycode for `hidUsage`, or `nil` for a usage with no macOS key (media keys, the
    /// international extras past 0x64, anything off the keyboard page). A `nil` sends NOTHING — a
    /// wrong keycode on a remote desktop is worse than a dropped one.
    public static func virtualKey(hidUsage: UInt16) -> UInt16? {
        if let letterOrDigit = alphanumeric(hidUsage) { return letterOrDigit }
        return fixed[hidUsage]
    }

    /// Whether `hidUsage` is a MODIFIER key (either side of ⌘⇧⌃⌥, or Caps Lock). The caller latches
    /// these so a focus change that swallows the release can synthesize the missing key-up — the
    /// `ModifierLatchTracker` discipline the Mac's `flagsChanged` feeds.
    public static func isModifier(hidUsage: UInt16) -> Bool {
        hidUsage == capsLock || (hidUsage >= leftControl && hidUsage <= rightGUI)
    }

    // MARK: The table

    /// Caps Lock's usage — a TOGGLE, not a held key (see `ModifierLatchTracker.note`).
    private static let capsLock: UInt16 = 0x39
    private static let leftControl: UInt16 = 0xE0
    private static let rightGUI: UInt16 = 0xE7

    /// `a`…`z` (0x04…0x1D) and `1`…`9`,`0` (0x1E…0x27) are contiguous on the HID page but scattered
    /// across the ANSI keycodes, so each run indexes its own literal ladder rather than pretending
    /// there is arithmetic between the two numberings.
    private static func alphanumeric(_ usage: UInt16) -> UInt16? {
        if usage >= 0x04, usage <= 0x1D { return letters[Int(usage - 0x04)] }
        if usage >= 0x1E, usage <= 0x27 { return digits[Int(usage - 0x1E)] }
        return nil
    }

    /// kVK_ANSI_A…Z in alphabet order.
    private static let letters: [UInt16] = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    ]

    /// kVK_ANSI_1…9 then 0 — the HID page's own order, which puts zero LAST.
    private static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    /// Everything that is not a letter or a digit. Built once; a dictionary rather than a `switch`
    /// so ``virtualKey(hidUsage:)`` stays one lookup and the table reads as a table.
    private static let fixed: [UInt16: UInt16] = [
        // Editing / whitespace.
        0x28: 36, // return
        0x29: 53, // escape
        0x2A: 51, // delete (backspace)
        0x2B: 48, // tab
        0x2C: 49, // space
        // Punctuation, in HID order.
        0x2D: 27, // -
        0x2E: 24, // =
        0x2F: 33, // [
        0x30: 30, // ]
        0x31: 42, // \
        0x32: 42, // non-US # — the same physical key on an ANSI board
        0x33: 41, // ;
        0x34: 39, // '
        0x35: 50, // `
        0x36: 43, // ,
        0x37: 47, // .
        0x38: 44, // /
        0x39: 57, // caps lock
        // F1…F12 — kVK's function keys are famously out of order.
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97,
        0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        // Navigation. Insert (0x49) has no ANSI keycode and is deliberately absent.
        0x4A: 115, // home
        0x4B: 116, // page up
        0x4C: 117, // forward delete
        0x4D: 119, // end
        0x4E: 121, // page down
        0x4F: 124, // right
        0x50: 123, // left
        0x51: 125, // down
        0x52: 126, // up
        // Keypad.
        0x53: 71, // num lock / clear
        0x54: 75, // keypad /
        0x55: 67, // keypad *
        0x56: 78, // keypad -
        0x57: 69, // keypad +
        0x58: 76, // keypad enter
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87,
        0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92,
        0x62: 82, // keypad 0
        0x63: 65, // keypad .
        0x64: 10, // non-US \ (ISO §/±)
        // Modifiers — both sides, because the host's latch balance counts them separately.
        0xE0: 59, // left control
        0xE1: 56, // left shift
        0xE2: 58, // left option
        0xE3: 55, // left command
        0xE4: 62, // right control
        0xE5: 60, // right shift
        0xE6: 61, // right option
        0xE7: 54, // right command
    ]
}
