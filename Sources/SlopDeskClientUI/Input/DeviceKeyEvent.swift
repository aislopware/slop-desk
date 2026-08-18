// DeviceKeyEvent — reading one key press off the platform, for both device panels.
//
// The mappings themselves live in `SlopDeskDevicePanels` and are the same answer everywhere — which key
// codes must travel as keycodes and which chords are dropped (`AndroidKeyMap`), which keys have no
// character and so cannot ride the `type` path (`SimulatorKeyMap`). What is platform-shaped is only the
// READING of a key event, so that is all this file is: a few fields off an `NSEvent` or a `UIKey`, and
// the modifier flags folded into the wire's own `InputModifiers` vocabulary.
//
// The two halves DIVERGE in exactly one place, and it is not a second implementation: a Mac numbers a
// key with a virtual key code and an iPad with a USB HID usage, so each calls the overload for its own
// numbering. The names those resolve to — and every rule about what to do with them — are the shared
// floor's, cut once.
//
// There is no second modifier type here on purpose. `InputModifiers` is what the GUI-video input path
// already sends host-ward, so the panels and the video pane agree on what "⌥ was held" means.

#if os(macOS)
import AppKit
import SlopDeskDevicePanels
import SlopDeskVideoProtocol

extension AndroidKeyMap {
    /// Resolve one AppKit key-down into what the device should receive.
    static func resolve(_ event: NSEvent) -> Resolution {
        resolve(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: InputModifiers(event.modifierFlags),
        )
    }
}

extension SimulatorKeyMap {
    /// The modifier names the simulator server expects for one AppKit key event.
    static func modifiers(for event: NSEvent) -> [SimulatorInputEnvelope.Modifier] {
        modifiers(for: InputModifiers(event.modifierFlags))
    }
}

package extension InputModifiers {
    /// The held modifiers an AppKit event carries. Caps Lock and function are folded in for
    /// completeness; the Android map reads only ⌥/⌃/⌘, and deliberately not ⇧ (the layout has already
    /// applied it to the characters), while the simulator map reads the four named ones.
    init(_ flags: NSEvent.ModifierFlags) {
        var value: Self = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.capsLock) { value.insert(.capsLock) }
        if flags.contains(.function) { value.insert(.function) }
        self = value
    }
}

#elseif os(iOS)
import SlopDeskDevicePanels
import SlopDeskVideoProtocol
import UIKit

extension AndroidKeyMap {
    /// Resolve one hardware-keyboard press into what the device should receive.
    ///
    /// `UIKey` has no separate "characters as typed" and "characters ignoring modifiers" pair the way
    /// an `NSEvent` does — `characters` IS the layout's resolution — so both go in and the shared rule
    /// picks. That is the same contract the AppKit half hands over, with one fewer field to lose.
    static func resolve(_ key: UIKey) -> Resolution {
        resolve(
            hidUsage: UInt16(key.keyCode.rawValue),
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: InputModifiers(key.modifierFlags),
        )
    }
}

extension SimulatorKeyMap {
    /// The modifier names the simulator server expects for one hardware-keyboard press.
    static func modifiers(for key: UIKey) -> [SimulatorInputEnvelope.Modifier] {
        modifiers(for: InputModifiers(key.modifierFlags))
    }
}

extension InputModifiers {
    /// The held modifiers a UIKit key event carries. Same four named ones the AppKit half folds, plus
    /// caps lock and the function key for completeness — the panels read only what they need.
    init(_ flags: UIKeyModifierFlags) {
        var value: Self = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.alternate) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.alphaShift) { value.insert(.capsLock) }
        self = value
    }
}
#endif
