// AndroidKeycode — Android's `KeyEvent` constants, and the mapping from a macOS key press to one.
//
// ## Why keys take two different routes
//
// A key press on a mirrored device is one of two unrelated things, and conflating them is what makes
// a remote keyboard feel broken:
//
//  - **Text** — a letter, a digit, an accented character, an emoji. What the device needs is the
//    CHARACTER, not the key that produced it, because the client's layout has already resolved dead
//    keys, `option`-combinations and the input method. That goes out as `INJECT_TEXT` and reaches
//    whatever field has focus. Sending `KEYCODE_A` instead would type `a` on a QWERTY device and
//    something else on any other layout, and would type nothing at all for a character with no
//    keycode.
//  - **A key with no character** — Return, Backspace, the arrows, Escape, Tab — plus anything held
//    with a non-shift modifier, where the device has to see the CHORD. Those go out as
//    `INJECT_KEYCODE` with a meta state.
//
// The split is the same one the simulator panel makes, for the same reason. What differs is the
// ceiling: `docs/47` records the simulator server typing at ~7 characters per second with batching no
// help, because the cost is inside its HID key dispatch. `scrcpy`'s `INJECT_TEXT` hands the whole
// string to the device's input method in ONE message with no acknowledgement, so a paste is a single
// write rather than a per-character round trip.

import Foundation
import SlopDeskVideoProtocol

/// One Android `KeyEvent` keycode. A struct rather than an enum: the constant list runs past 300 and
/// the panel needs a couple of dozen, so an open type keeps a missing one from being unrepresentable.
package struct AndroidKeycode: RawRepresentable, Equatable, Hashable {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package init(_ rawValue: UInt32) { self.rawValue = rawValue }

    // Navigation — the three that make an Android device usable at all.
    package static let home = Self(3)
    package static let back = Self(4)
    package static let appSwitch = Self(187)

    // Hardware.
    package static let power = Self(26)
    package static let camera = Self(27)
    package static let notification = Self(83)

    // Editing.
    package static let del = Self(67)
    package static let forwardDel = Self(112)
    package static let enter = Self(66)
    package static let tab = Self(61)
    package static let escape = Self(111)
    package static let space = Self(62)

    // Motion.
    package static let dpadUp = Self(19)
    package static let dpadDown = Self(20)
    package static let dpadLeft = Self(21)
    package static let dpadRight = Self(22)
    package static let moveHome = Self(122)
    package static let moveEnd = Self(123)
    package static let pageUp = Self(92)
    package static let pageDown = Self(93)
}

/// `KeyEvent` meta-state bits.
package struct AndroidMetaState: OptionSet {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package static let shift = Self(rawValue: 0x1)
    package static let alt = Self(rawValue: 0x02)
    package static let control = Self(rawValue: 0x1000)
    /// The `meta` key — Android's name for what macOS calls Command.
    package static let meta = Self(rawValue: 0x10000)
}

package enum AndroidKeyMap {
    /// What a key press should become on the wire.
    package enum Resolution: Equatable {
        /// Send these characters as text.
        case text(String)
        /// Send this keycode with this meta state.
        case keycode(AndroidKeycode, AndroidMetaState)
        /// Nothing to send — a bare modifier, or a chord the client keeps for itself.
        case none
    }

    /// The macOS virtual key codes that have no character and must travel as keycodes.
    ///
    /// Keyed on `keyCode` rather than on the event's characters because several of these DO produce
    /// characters — Return gives `\r`, Tab gives `\t`, Escape gives `\u{1b}` — and sending those as
    /// text inserts a control character into the field instead of dismissing the keyboard or moving
    /// focus.
    package static let functionalKeys: [UInt16: AndroidKeycode] = [
        36: .enter, // Return
        76: .enter, // Enter (keypad)
        48: .tab,
        51: .del, // Delete (backspace)
        117: .forwardDel, // Forward delete
        53: .escape,
        126: .dpadUp,
        125: .dpadDown,
        123: .dpadLeft,
        124: .dpadRight,
        115: .moveHome,
        119: .moveEnd,
        116: .pageUp,
        121: .pageDown,
    ]

    /// The same keys, numbered the way an iPad numbers them: USB HID keyboard usages, which is what a
    /// `UIKey` reports. Only the NUMBERING differs — the keycodes it maps to, and every rule below,
    /// are the ones above (``resolve(functional:characters:charactersIgnoringModifiers:modifiers:)``
    /// is where both domains meet). `AndroidKeycodeTests` asserts the two tables name the same set.
    package static let hidFunctionalKeys: [UInt16: AndroidKeycode] = [
        40: .enter, // Return / Enter
        88: .enter, // Keypad Enter
        43: .tab,
        42: .del, // Delete or Backspace
        76: .forwardDel, // Delete Forward
        41: .escape,
        82: .dpadUp,
        81: .dpadDown,
        80: .dpadLeft,
        79: .dpadRight,
        74: .moveHome,
        77: .moveEnd,
        75: .pageUp,
        78: .pageDown,
    ]

    /// Resolves one key-down event, described without naming a platform's event type.
    ///
    /// `characters` is what the client's own layout produced (option-composed output, dead-key
    /// resolution, the input method's answer); `charactersIgnoringModifiers` is the same press with
    /// the layout's modifier handling stripped. Both are what a platform key event already carries —
    /// this takes them as values so the mapping is one implementation for every UI half (docs/56).
    ///
    /// **Shift is not a modifier here.** The platform has already applied it — the characters are
    /// already upper case — so folding `.shift` into the meta state as well would ask the device to
    /// apply it twice. That is the same double-application trap `docs/47` records for scroll
    /// direction, in a different channel: when the platform has already resolved something, passing
    /// the raw flag along re-resolves it.
    package static func resolve(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        resolve(
            functional: functionalKeys[keyCode], characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers,
        )
    }

    /// The same round for a key numbered as a USB HID usage — an iPad's `UIKey`.
    package static func resolve(
        hidUsage: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        resolve(
            functional: hidFunctionalKeys[hidUsage], characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, modifiers: modifiers,
        )
    }

    /// The rule itself, once, after the platform's numbering has been resolved away. `functional` is
    /// non-nil for a key that has no character of its own.
    package static func resolve(
        functional: AndroidKeycode?,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: InputModifiers,
    ) -> Resolution {
        if let keycode = functional {
            return .keycode(keycode, metaState(from: modifiers))
        }
        // A chord with a real modifier has to reach the device AS a chord, so it goes as a keycode;
        // but the panel cannot know the device's layout, so only the chords with an unambiguous
        // keycode are forwarded and the rest are dropped rather than typed as stray letters.
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return .none
        }
        guard let bare = charactersIgnoringModifiers, !bare.isEmpty else {
            return .none
        }
        // `characters` (not `charactersIgnoringModifiers`) is what carries the layout's own
        // resolution, including option-composed and dead-key output.
        let typed = characters ?? bare
        // Control characters would be inserted literally; there is nothing useful to type.
        let printable = typed.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7F) }
        guard !printable.isEmpty else { return .none }
        return .text(String(String.UnicodeScalarView(printable)))
    }

    /// The meta state for a set of held modifiers, minus shift (see ``resolve(keyCode:characters:charactersIgnoringModifiers:modifiers:)``).
    package static func metaState(from modifiers: InputModifiers) -> AndroidMetaState {
        var state: AndroidMetaState = []
        if modifiers.contains(.option) { state.insert(.alt) }
        if modifiers.contains(.control) { state.insert(.control) }
        if modifiers.contains(.command) { state.insert(.meta) }
        return state
    }
}
