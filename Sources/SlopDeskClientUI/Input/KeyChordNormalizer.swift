// KeyChordNormalizer — the PURE NSEvent→`KeyChord` mapping (WS-B / B3), AppKit-free so the chord mapping is
// unit-tested headlessly. The live dispatcher (`WorkspaceKeyDispatcher`) destructures the `NSEvent` into the
// primitives this takes (`charactersIgnoringModifiers`, `keyCode`, the four modifier booleans) and feeds
// them here; this file imports NO AppKit so a ClientUI test can exercise every chord without an `NSEvent`.
//
// PARITY with GhosttyTerminalView: the terminal's `keyDown` reads `event.modifierFlags` (mapped by
// `ghosttyMods`) + `charactersIgnoringModifiers` to key its own chords (the ⌘D/⌘⇧D split branch). We mirror
// the SAME two signals — modifier flags → `KeyChord.Modifiers`, and `charactersIgnoringModifiers` (which
// ignores ⌘/⌥/⌃ but NOT ⇧, so a shifted key still reports its base via the lowercase normalization in
// `KeyChord.init(character:)`) → the base key — so the dispatcher and the terminal agree on what a chord is.
// Named non-printable keys (Return/Tab/arrows) are mapped from `keyCode` exactly as the keybindings editor's
// `baseKey(for:)` does, so a rebind captured in the editor matches a chord the dispatcher produces.

#if canImport(SwiftUI)
import Foundation
import SlopDeskWorkspaceCore

/// Pure NSEvent→`KeyChord` normalization (no AppKit). The dispatcher passes the destructured event fields;
/// this returns the framework-neutral `KeyChord` the binding tables key on, or `nil` for a pure-modifier /
/// unmapped keystroke (which the dispatcher then leaves untouched — never swallowed).
enum KeyChordNormalizer {
    /// The four modifier booleans, destructured from `NSEvent.modifierFlags` by the caller so this stays
    /// AppKit-free and testable. Mirrors the set `ghosttyMods` reads (shift/control/option/command).
    struct Modifiers {
        let shift: Bool
        let control: Bool
        let option: Bool
        let command: Bool

        init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
            self.shift = shift
            self.control = control
            self.option = option
            self.command = command
        }
    }

    /// Build a `KeyChord` from the destructured NSEvent fields, or `nil` when there is no chord to key on (a
    /// pure-modifier press, or a key with no printable base + no recognised named key).
    ///
    /// - `keyCode` maps the non-printable named keys (Return/Tab/arrows) FIRST — exactly the keybindings
    ///   editor's `baseKey(for:)` codes — so an editor-captured rebind and a dispatcher-produced chord agree.
    /// - otherwise `charactersIgnoringModifiers` (the ⌘/⌥/⌃-independent base; ⇧ is carried in `modifiers`,
    ///   not in the char) supplies a single printable character.
    static func chord(
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifierFlags: Modifiers,
    ) -> KeyChord? {
        var mods: KeyChord.Modifiers = []
        if modifierFlags.shift { mods.insert(.shift) }
        if modifierFlags.control { mods.insert(.control) }
        if modifierFlags.option { mods.insert(.option) }
        if modifierFlags.command { mods.insert(.command) }

        // Named keys by keyCode (parity with KeybindingsEditorView.baseKey).
        switch keyCode {
        case 36,
             76: return KeyChord(.return, mods) // Return / keypad Enter
        case 48: return KeyChord(.tab, mods)
        case 123: return KeyChord(.leftArrow, mods)
        case 124: return KeyChord(.rightArrow, mods)
        case 126: return KeyChord(.upArrow, mods)
        case 125: return KeyChord(.downArrow, mods)
        case 116: return KeyChord(.pageUp, mods)
        case 121: return KeyChord(.pageDown, mods)
        case 115: return KeyChord(.home, mods)
        case 119: return KeyChord(.end, mods)
        // Space (keyCode 49) maps to the NAMED `.space` chord ONLY when a non-shift modifier (⌃/⌥/⌘) is held —
        // Vi Mode entry is bound to ⌃⇧Space. A BARE or ⇧-only Space is normal typing and must reach the terminal,
        // so it falls through to the whitespace rejection below → `nil` (preserving the bare-space passthrough
        // boundary the dispatcher relies on; a shifted-but-modifierless Space still types a space).
        case 49 where modifierFlags.control || modifierFlags.option || modifierFlags.command:
            return KeyChord(.space, mods)
        default: break
        }

        // A single printable character. `charactersIgnoringModifiers` ignores ⌘/⌥/⌃ but still reflects ⇧;
        // `KeyChord.init(character:)` lowercases it, so ⇧-state lives in `mods`, not the char (a shifted
        // letter and its lowercase produce the same base key, matching the table's case-insensitive lookup).
        guard let chars = charactersIgnoringModifiers, let first = chars.first, chars.count == 1 else {
            return nil
        }
        // Reject whitespace / control scalars: those are never workspace chords and must pass through to the
        // terminal (a bare key is normal typing). A Ctrl-letter still reports its printable base here (e.g.
        // ⌃B → "b") so a Ctrl-modified chord is recognised.
        guard !first.isWhitespace, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return KeyChord(character: first, mods)
    }
}
#endif
