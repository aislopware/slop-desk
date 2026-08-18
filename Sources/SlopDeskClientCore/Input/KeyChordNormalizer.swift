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
// Named non-printable keys (Return/Tab/arrows) come from `slopdesk_video::key_naming` — the ONE table, which
// the keybindings recorder reads too, so a rebind captured in Settings matches a chord produced here.

import CSlopDeskFFI
import SlopDeskWorkspaceCore

/// Pure NSEvent→`KeyChord` normalization (no AppKit). The dispatcher passes the destructured event fields;
/// this returns the framework-neutral `KeyChord` the binding tables key on, or `nil` for a pure-modifier /
/// unmapped keystroke (which the dispatcher then leaves untouched — never swallowed).
package enum KeyChordNormalizer {
    /// The four modifier booleans, destructured from `NSEvent.modifierFlags` by the caller so this stays
    /// AppKit-free and testable. Mirrors the set `ghosttyMods` reads (shift/control/option/command).
    package struct Modifiers {
        package let shift: Bool
        package let control: Bool
        package let option: Bool
        package let command: Bool

        package init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
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
    package static func chord(
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifierFlags: Modifiers,
    ) -> KeyChord? {
        var mods: KeyChord.Modifiers = []
        if modifierFlags.shift { mods.insert(.shift) }
        if modifierFlags.control { mods.insert(.control) }
        if modifierFlags.option { mods.insert(.option) }
        if modifierFlags.command { mods.insert(.command) }

        var characters = charactersIgnoringModifiers ?? ""
        var printable = [UInt8](repeating: 0, count: 4) // one character's UTF-8, never more
        let base = characters.withUTF8 { chars in
            printable.withUnsafeMutableBufferPointer { out in
                slopdesk_key_chord_base(
                    keyCode,
                    chars.baseAddress,
                    chars.count,
                    modifierFlags.control || modifierFlags.option || modifierFlags.command,
                    out.baseAddress,
                    out.count,
                )
            }
        }
        switch base.kind {
        case 1:
            guard let named = KeyChord.Key(namedIndex: base.named) else { return nil }
            return KeyChord(named, mods)
        case 2:
            guard let text = String(bytes: printable.prefix(max(0, base.length)), encoding: .utf8),
                  let character = text.first
            else { return nil }
            return KeyChord(character: character, mods)
        default: return nil
        }
    }
}
