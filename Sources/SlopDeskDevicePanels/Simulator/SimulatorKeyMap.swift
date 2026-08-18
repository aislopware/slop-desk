// SimulatorKeyMap — a key press → the `KeyboardEvent.code` names the server's HID table is keyed on.
//
// Only the keys that have no CHARACTER are mapped. Everything printable goes through the `type`
// envelope instead, using the event's own characters: that path costs nothing to maintain, respects
// whatever layout the user actually has (a Vietnamese, French or Dvorak layout produces the right
// letter without this file knowing the layout exists), and cannot drift out of date.
//
// So the table below is deliberately SHORT. It covers the keys a text field needs that produce no
// text — return, delete, tab, escape, arrows — and stops. Adding printable keys here would be a
// silent regression for every non-US layout.
//
// ONE VOCABULARY, TWO DOMAINS. The names in ``SimulatorKeyMap/FunctionalKey`` are the server's, cut
// once; what differs by platform is only how a keyboard NUMBERS its keys. A Mac reports a virtual
// key code and an iPad reports a USB HID usage, so each gets a lookup into the same vocabulary
// rather than its own copy of the names — the same shape ``SimulatorKeyMap/modifiers(for:)`` already
// has, where the platform hands over `InputModifiers` and the naming happens once. `SimulatorKeyMapTests`
// asserts the two tables cover the SAME set, which is the invariant that keeps them from drifting.

import SlopDeskVideoProtocol

package enum SimulatorKeyMap {
    /// The keys that produce no character, under the names the server's HID table uses. The raw value
    /// IS the `KeyboardEvent.code` — there is no second spelling anywhere.
    package enum FunctionalKey: String, CaseIterable, Sendable {
        case enter = "Enter"
        case backspace = "Backspace"
        case forwardDelete = "Delete"
        case tab = "Tab"
        case escape = "Escape"
        case arrowLeft = "ArrowLeft"
        case arrowRight = "ArrowRight"
        case arrowUp = "ArrowUp"
        case arrowDown = "ArrowDown"
        case home = "Home"
        case end = "End"
        case pageUp = "PageUp"
        case pageDown = "PageDown"
        case space = "Space"
    }

    /// macOS virtual key codes. LITERALS, not `kVK_` constants, for the same reason
    /// ``AndroidKeyMap/functionalKeys`` spells its own out: `kVK_` lives in `Carbon.HIToolbox`, which
    /// does not exist on the iOS triple, and this table is the panel's shared floor — one
    /// implementation for every UI half (docs/56), not a macOS-only one. The numbering itself is the
    /// one thing about a Mac keyboard that has never moved; `SimulatorKeyMapTests` pins every row
    /// against the SDK's constant on macOS so a typo here cannot survive a build.
    ///
    /// Both Returns are `.enter`: the server's table has no keypad variant, and a text field that
    /// told them apart would be wrong on every keyboard with a numeric pad.
    package static let byVirtualKey: [UInt16: FunctionalKey] = [
        36: .enter, // Return
        76: .enter, // Enter (keypad)
        51: .backspace, // Delete
        117: .forwardDelete,
        48: .tab,
        53: .escape,
        123: .arrowLeft,
        124: .arrowRight,
        126: .arrowUp,
        125: .arrowDown,
        115: .home,
        119: .end,
        116: .pageUp,
        121: .pageDown,
        49: .space,
    ]

    /// USB HID keyboard usages — what a `UIKey` reports on iPadOS. Same literal treatment and the
    /// same pinning (`UIKeyboardHIDUsage` is a UIKit type, so the shared floor cannot name it), and
    /// the same two-Returns rule.
    package static let byHIDUsage: [UInt16: FunctionalKey] = [
        40: .enter, // Return / Enter
        88: .enter, // Keypad Enter
        42: .backspace, // Delete or Backspace
        76: .forwardDelete, // Delete Forward
        43: .tab,
        41: .escape,
        80: .arrowLeft,
        79: .arrowRight,
        82: .arrowUp,
        81: .arrowDown,
        74: .home,
        77: .end,
        75: .pageUp,
        78: .pageDown,
        44: .space,
    ]

    /// The `KeyboardEvent.code` for a macOS virtual key code, or `nil` when the key produces text and
    /// belongs on the `type` path instead.
    package static func code(for keyCode: UInt16) -> String? {
        byVirtualKey[keyCode]?.rawValue
    }

    /// The `KeyboardEvent.code` for a USB HID keyboard usage — the iPad's half of the same question.
    package static func code(hidUsage: UInt16) -> String? {
        byHIDUsage[hidUsage]?.rawValue
    }

    /// The modifier names the server expects. `.function` and `.capsLock` are deliberately absent:
    /// neither has a name on this wire, and sending one would be an unknown token rather than a
    /// no-op.
    ///
    /// Takes `InputModifiers` — the wire's own held-modifier vocabulary, which the GUI-video input
    /// path already sends host-ward — rather than an `NSEvent.ModifierFlags`, so the panel's key
    /// mapping is one implementation and the reading of a key EVENT is the platform's half
    /// (`DeviceKeyEvent` on each side).
    package static func modifiers(for held: InputModifiers) -> [SimulatorInputEnvelope.Modifier] {
        var modifiers: [SimulatorInputEnvelope.Modifier] = []
        if held.contains(.shift) { modifiers.append(.shift) }
        if held.contains(.control) { modifiers.append(.control) }
        if held.contains(.option) { modifiers.append(.option) }
        if held.contains(.command) { modifiers.append(.command) }
        return modifiers
    }
}
