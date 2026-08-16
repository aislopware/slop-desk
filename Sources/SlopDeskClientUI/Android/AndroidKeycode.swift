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

#if os(macOS)
import AppKit

/// One Android `KeyEvent` keycode. A struct rather than an enum: the constant list runs past 300 and
/// the panel needs a couple of dozen, so an open type keeps a missing one from being unrepresentable.
struct AndroidKeycode: RawRepresentable, Equatable, Hashable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(_ rawValue: UInt32) { self.rawValue = rawValue }

    // Navigation — the three that make an Android device usable at all.
    static let home = Self(3)
    static let back = Self(4)
    static let appSwitch = Self(187)

    // Hardware.
    static let power = Self(26)
    static let camera = Self(27)
    static let notification = Self(83)

    // Editing.
    static let del = Self(67)
    static let forwardDel = Self(112)
    static let enter = Self(66)
    static let tab = Self(61)
    static let escape = Self(111)
    static let space = Self(62)

    // Motion.
    static let dpadUp = Self(19)
    static let dpadDown = Self(20)
    static let dpadLeft = Self(21)
    static let dpadRight = Self(22)
    static let moveHome = Self(122)
    static let moveEnd = Self(123)
    static let pageUp = Self(92)
    static let pageDown = Self(93)
}

/// `KeyEvent` meta-state bits.
struct AndroidMetaState: OptionSet {
    let rawValue: UInt32
    static let shift = Self(rawValue: 0x1)
    static let alt = Self(rawValue: 0x02)
    static let control = Self(rawValue: 0x1000)
    /// The `meta` key — Android's name for what macOS calls Command.
    static let meta = Self(rawValue: 0x10000)
}

enum AndroidKeyMap {
    /// What a key press should become on the wire.
    enum Resolution: Equatable {
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
    static let functionalKeys: [UInt16: AndroidKeycode] = [
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

    /// Resolves one key-down event.
    ///
    /// **Shift is not a modifier here.** macOS has already applied it — the event's characters are
    /// already upper case — so folding `.shift` into the meta state as well would ask the device to
    /// apply it twice. That is the same double-application trap `docs/47` records for scroll
    /// direction, in a different channel: when the platform has already resolved something, passing
    /// the raw flag along re-resolves it.
    static func resolve(_ event: NSEvent) -> Resolution {
        let flags = event.modifierFlags
        if let keycode = functionalKeys[event.keyCode] {
            return .keycode(keycode, metaState(from: flags))
        }
        // A chord with a real modifier has to reach the device AS a chord, so it goes as a keycode;
        // but the panel cannot know the device's layout, so only the chords with an unambiguous
        // keycode are forwarded and the rest are dropped rather than typed as stray letters.
        if flags.contains(.command) || flags.contains(.control) {
            return .none
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return .none
        }
        // `characters` (not `charactersIgnoringModifiers`) is what carries the layout's own
        // resolution, including option-composed and dead-key output.
        let typed = event.characters ?? characters
        // Control characters would be inserted literally; there is nothing useful to type.
        let printable = typed.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7F) }
        guard !printable.isEmpty else { return .none }
        return .text(String(String.UnicodeScalarView(printable)))
    }

    /// The meta state for a set of macOS flags, minus shift (see ``resolve(_:)``).
    static func metaState(from flags: NSEvent.ModifierFlags) -> AndroidMetaState {
        var state: AndroidMetaState = []
        if flags.contains(.option) { state.insert(.alt) }
        if flags.contains(.control) { state.insert(.control) }
        if flags.contains(.command) { state.insert(.meta) }
        return state
    }
}
#endif
