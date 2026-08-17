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

#if os(macOS)
import Carbon.HIToolbox
import SlopDeskVideoProtocol

package enum SimulatorKeyMap {
    /// The `KeyboardEvent.code` for a macOS virtual key code, or `nil` when the key produces text and
    /// belongs on the `type` path instead.
    package static func code(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Return,
             kVK_ANSI_KeypadEnter: "Enter"
        case kVK_Delete: "Backspace"
        case kVK_ForwardDelete: "Delete"
        case kVK_Tab: "Tab"
        case kVK_Escape: "Escape"
        case kVK_LeftArrow: "ArrowLeft"
        case kVK_RightArrow: "ArrowRight"
        case kVK_UpArrow: "ArrowUp"
        case kVK_DownArrow: "ArrowDown"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "PageUp"
        case kVK_PageDown: "PageDown"
        case kVK_Space: "Space"
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
#endif
