import Foundation

/// The pure routing decision behind the iOS IME proxy (doc 17 §2.5).
///
/// On iOS we must split physical input into two paths to keep CJK / multi-stage IME working:
///
/// - **Key path** — `Ctrl`/`Alt`+letter and bare control keys (Esc, Tab, arrows, Return,
///   Delete) route **straight to key encoding** (`ghostty_surface_key` in the real surface,
///   or the byte encoder here), because a hidden `UITextView` IME proxy would swallow or
///   mis-compose them.
/// - **Text path** — ordinary printable text and committed IME output flows through the
///   hidden `UITextView` proxy → `insertText(_:)` → bytes (`ghostty_surface_text`), so a
///   multi-stage CJK composition commits correctly.
///
/// Doc 17 §2.5: *"Ctrl/Alt+letter route thẳng `ghostty_surface_key`; còn lại qua IME proxy →
/// `ghostty_surface_text`."* Putting a hidden `UITextView` and the `pressesBegan` responder on
/// the **same** view breaks CJK (undefined responder order), so the routing decision is
/// modelled here as a pure function the iOS layer consults; it holds no UIKit type and is
/// unit-tested on macOS.
public enum InputRouting {
    /// A physical key press the router must classify, described platform-agnostically.
    public struct KeyPress: Sendable, Equatable, Hashable {
        /// The committed characters for the press (UIKit `UIKey.characters`), if any.
        public var characters: String
        /// `characters` ignoring modifiers (UIKit `UIKey.charactersIgnoringModifiers`).
        public var charactersIgnoringModifiers: String
        public var control: Bool
        public var option: Bool // Alt
        public var command: Bool
        /// Shift. Deliberately NOT consulted by ``route(_:)`` (a shifted printable letter must still
        /// flow through the IME proxy), only by the special-key byte encoder — UIKit reports the same
        /// `characters` for Tab with or without Shift, so this is the only way to tell Shift+Tab
        /// (back-tab `ESC [ Z`) from a forward Tab (R12 #6).
        public var shift: Bool
        /// True for a non-printable special key (arrows, Esc, Tab, Return, Delete, F-keys).
        public var isSpecial: Bool

        public init(
            characters: String,
            charactersIgnoringModifiers: String? = nil,
            control: Bool = false,
            option: Bool = false,
            command: Bool = false,
            shift: Bool = false,
            isSpecial: Bool = false,
        ) {
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
            self.control = control
            self.option = option
            self.command = command
            self.shift = shift
            self.isSpecial = isSpecial
        }
    }

    /// Where a press should be routed.
    public enum Route: Sendable, Equatable {
        /// Encode as a key event (bypass the IME proxy). Ctrl/Alt-combos + special keys.
        case keyEncoding
        /// Let the hidden IME proxy `UITextView` handle it (ordinary text / CJK composition).
        case imeProxy
    }

    /// Classifies a physical key press into a routing decision.
    ///
    /// Rules (in order):
    /// 1. A **special** key (arrow/Esc/Tab/Return/Delete) → `.keyEncoding`.
    /// 2. **Ctrl** or **Alt(Option)** held with a printable letter → `.keyEncoding` (Ctrl-C,
    ///    Alt-b, …). Command-combos are app shortcuts, not terminal input → `.keyEncoding`.
    /// 3. Otherwise (plain printable text, no terminal-relevant modifier) → `.imeProxy`, so
    ///    a marked-text CJK composition can run.
    public static func route(_ press: KeyPress) -> Route {
        if press.isSpecial { return .keyEncoding }
        if press.control || press.option || press.command { return .keyEncoding }
        return .imeProxy
    }

    /// Convenience: whether the press bypasses the IME proxy (the key path).
    public static func routesToKeyEncoding(_ press: KeyPress) -> Bool {
        route(press) == .keyEncoding
    }

    /// WS-B / B7 — map a `KeyPress` to the framework-neutral ``KeyChord`` the ``TerminalKeyInterceptor``
    /// keys on, or `nil` for a key it cannot classify (which the iOS responder then routes normally —
    /// never swallows). The iOS UIKit responder (`pressesBegan`) consults this BEFORE ``route(_:)`` /
    /// ``KeyEncoding/encode(_:arrowFallback:)`` so the SAME pure prefix machine + override-aware
    /// `resolvedChordTable` that drives macOS owns the workspace chords / tmux-style prefix on iOS too:
    ///
    /// ```swift
    /// // inside pressesBegan, per UIPress.key:
    /// let press = InputRouting.KeyPress(/* from UIKey */)
    /// if let chord = InputRouting.keyChord(for: press) {
    ///     switch interceptor.intercept(chord) {        // interceptor: a TerminalKeyInterceptor the host owns
    ///     case .forward:               break            // fall through to the normal iOS key/IME path
    ///     case .swallow:               return           // armed/resolved/disarmed — send nothing
    ///     case let .sendLiteral(bytes): sendInput(Data(bytes)); return  // tmux send-prefix double-tap
    ///     }
    /// }
    /// // …existing route(press)/KeyEncoding.encode(press) path…
    /// ```
    ///
    /// Mirrors the macOS `KeyChordNormalizer`/`GhosttyLayerBackedView.workspaceChord`: named special keys
    /// FIRST (Return/Tab/arrows), else a single printable `charactersIgnoringModifiers` base with ⇧/⌃/⌥/⌘
    /// carried in the modifier set (⇧ rides `modifiers`, not the char). Whitespace / control scalars are
    /// rejected so a bare key (or ⌃-letter, which still reports its printable base) is classifiable but
    /// normal typing falls through.
    public static func keyChord(for press: KeyPress) -> KeyChord? {
        var mods: KeyChord.Modifiers = []
        if press.shift { mods.insert(.shift) }
        if press.control { mods.insert(.control) }
        if press.option { mods.insert(.option) }
        if press.command { mods.insert(.command) }

        // Named special keys by their committed characters (UIKit reports these for arrows/Return/Tab),
        // mirroring KeyEncoding.characterSpecialBytes' character-keyed switch + the macOS keyCode map.
        if let named = specialKeyChord(for: press, mods: mods) { return named }

        // A single printable base key. `charactersIgnoringModifiers` is the ⌘/⌥/⌃-independent base (⇧ is
        // carried in `mods`); reject whitespace / control scalars (those are never workspace chords).
        let base = press.charactersIgnoringModifiers
        guard let first = base.first, base.count == 1 else { return nil }
        guard !first.isWhitespace, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return KeyChord(character: first, mods)
    }

    /// The named-key ``KeyChord`` for a special press (Return / Tab / arrows), or `nil` if it is not one we
    /// model. Arrows are reported by UIKit as the `UIKeyCommand.input*Arrow` private-use scalars, which the
    /// iOS layer normalizes into `characters` before building the `KeyPress`; we match those plus the
    /// ESC/Tab/Return committed strings (KeyEncoding already keys on the same committed `characters`).
    private static func specialKeyChord(for press: KeyPress, mods: KeyChord.Modifiers) -> KeyChord? {
        switch press.characters {
        case "\r",
             "\n": KeyChord(.return, mods)
        case "\t": KeyChord(.tab, mods)
        case "\u{F702}": KeyChord(.leftArrow, mods) // UIKeyCommand.inputLeftArrow
        case "\u{F703}": KeyChord(.rightArrow, mods) // UIKeyCommand.inputRightArrow
        case "\u{F700}": KeyChord(.upArrow, mods) // UIKeyCommand.inputUpArrow
        case "\u{F701}": KeyChord(.downArrow, mods) // UIKeyCommand.inputDownArrow
        default: nil
        }
    }
}
