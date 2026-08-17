// KeyChord — the framework-neutral keyboard chord the bindings table is keyed by.
//
// Split out of the canvas `CommandInterpreter` when that command layer was deleted (docs/56): the
// chord OUTLIVED the interpreter, because the live binding registry (``WorkspaceBindingRegistry``),
// its user overrides, the terminal key interceptor and the iOS input router all key on it. It names
// no framework — platform adapters translate `NSEvent` / SwiftUI `KeyPress` into this shape — so it
// stays `Hashable` and testable with no view in scope.

/// A keyboard chord: a normalized key token plus its modifier set. The join key of the bindings
/// table (``WorkspaceBindingRegistry``). Framework-neutral (no SwiftUI `KeyEquivalent` /
/// `EventModifiers`) so it stays pure and `Hashable`-keyable in tests; platform adapters translate
/// native events into this shape.
public struct KeyChord: Hashable, Sendable {
    /// The modifier flags carried by a chord. An `OptionSet` so combinations (⇧⌘, ⌥⌘) compose.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Self(rawValue: 1 << 0)
        public static let control = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let command = Self(rawValue: 1 << 3)
    }

    /// A normalized key token. Printable keys are lower-cased single characters (the chord is
    /// modifier-explicit, so case is carried by `.shift`, not by the character); named keys cover
    /// the non-printable keys the workspace binds.
    public enum Key: Hashable, Sendable {
        /// A single printable character, normalized to lower case (e.g. `"d"`, `"]"`, `"1"`).
        case character(Character)
        case tab
        case `return`
        /// The Space bar as a NAMED key (keyCode 49), NOT `.character(" ")` — the macOS normalizer rejects a
        /// whitespace character, so a Space chord must be named (like Tab/Return). Only ever bound with a
        /// non-shift modifier (Vi Mode entry is ⌃⇧Space); a bare/⇧-only Space stays normal typing.
        case space
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        /// Non-printable named navigation keys (terminal-native shift-scroll / page-jump chords). The one
        /// exemption to the "every workspace chord is ⌘/⌥-prefixed" §5 rule — a ⇧-prefixed named key cannot
        /// steal a printable terminal letter (E1 scroll bindings).
        case pageUp
        case pageDown
        case home
        case end
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Convenience for a printable-character chord, lower-casing the character so binding lookups
    /// are case-insensitive on the base key (⇧ is expressed in `modifiers`, not in the char).
    public init(character: Character, _ modifiers: Modifiers = []) {
        key = .character(Character(character.lowercased()))
        self.modifiers = modifiers
    }
}
