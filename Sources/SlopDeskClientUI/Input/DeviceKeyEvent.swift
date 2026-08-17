// DeviceKeyEvent — the AppKit half of both device panels' key mapping: an `NSEvent` described as values.
//
// The mappings themselves live in `SlopDeskDevicePanels` and are the same answer everywhere — which key
// codes must travel as keycodes and which chords are dropped (`AndroidKeyMap`), which keys have no
// character and so cannot ride the `type` path (`SimulatorKeyMap`). What is platform-shaped is only the
// READING of a key event, so that is all this file is: a few fields off an `NSEvent` and the modifier
// flags folded into the wire's own `InputModifiers` vocabulary.
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

extension InputModifiers {
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
#endif
