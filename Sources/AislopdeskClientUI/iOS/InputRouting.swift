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
        public var option: Bool    // Alt
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
            isSpecial: Bool = false
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
}
