// SimulatorKeyMap — macOS virtual key codes → the `KeyboardEvent.code` names the server's HID table
// is keyed on.
//
// Only the keys that have no CHARACTER are mapped. Everything printable goes through the `type`
// envelope instead, using the event's own characters: that path costs nothing to maintain, respects
// whatever layout the user actually has (a Vietnamese, French or Dvorak layout produces the right
// letter without this file knowing the layout exists), and cannot drift out of date.
//
// So the table below is deliberately SHORT. It covers the keys a text field needs that produce no
// text — return, delete, tab, escape, arrows — and stops. Adding printable keys here would be a
// silent regression for every non-US layout.

import SlopDeskVideoProtocol

package enum SimulatorKeyMap {
    /// The `KeyboardEvent.code` for a macOS virtual key code, or `nil` when the key produces text and
    /// belongs on the `type` path instead.
    ///
    /// The codes are LITERALS, not `kVK_` constants, for the same reason ``AndroidKeyMap/functionalKeys``
    /// spells its own out: `kVK_` lives in `Carbon.HIToolbox`, which does not exist on the iOS triple,
    /// and this table is the panel's shared floor — one implementation for every UI half (docs/56), not
    /// a macOS-only one. The numbering itself is the one thing about a Mac keyboard that has never
    /// moved; ``SimulatorKeyMapTests`` pins every row against the SDK's constant on macOS so a typo
    /// here cannot survive a build.
    package static func code(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, // Return
             76: "Enter" // Enter (keypad)
        case 51: "Backspace" // Delete
        case 117: "Delete" // Forward delete
        case 48: "Tab"
        case 53: "Escape"
        case 123: "ArrowLeft"
        case 124: "ArrowRight"
        case 126: "ArrowUp"
        case 125: "ArrowDown"
        case 115: "Home"
        case 119: "End"
        case 116: "PageUp"
        case 121: "PageDown"
        case 49: "Space"
        default: nil
        }
    }

    /// The modifier names the server expects. `.function` and `.capsLock` are deliberately absent:
    /// neither has a name on this wire, and sending one would be an unknown token rather than a
    /// no-op.
    ///
    /// Takes `InputModifiers` — the wire's own held-modifier vocabulary, which the GUI-video input
    /// path already sends host-ward — rather than an `NSEvent.ModifierFlags`, so the panel's key
    /// mapping is one implementation and the reading of a key EVENT is the platform's half
    /// (`SimulatorKeyEvent`, and `AndroidKeyEvent` beside it).
    package static func modifiers(for held: InputModifiers) -> [SimulatorInputEnvelope.Modifier] {
        var modifiers: [SimulatorInputEnvelope.Modifier] = []
        if held.contains(.shift) { modifiers.append(.shift) }
        if held.contains(.control) { modifiers.append(.control) }
        if held.contains(.option) { modifiers.append(.option) }
        if held.contains(.command) { modifiers.append(.command) }
        return modifiers
    }
}
