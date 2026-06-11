import Foundation

/// Pure, platform-agnostic terminal key-encoding — the macOS-unit-testable core behind the iOS
/// UIKit key path (``TerminalInputResponderView`` / ``KeyboardAccessoryBar``).
///
/// Deliberately kept OUT of the `#if os(iOS)` guard (like ``FloatingCursorMapping`` /
/// ``KeyboardAccessoryDecision``) so the byte mappings are exercised by the headless test runner,
/// not only by an iOS-triple build. The only genuinely UIKit-dependent bit — resolving the arrow
/// keys, whose identity is the opaque `UIKeyCommand.input*Arrow` constants — is INJECTED by the iOS
/// layer via `arrowFallback`, so this type imports no UIKit and the rest of the encoder is testable
/// without a device.
public enum KeyEncoding {
    /// Pure mapping of a key to its ASCII control code. The full C0 range matters, not just letters:
    /// Ctrl-A…Ctrl-Z map to 1…26, Ctrl-[ is the canonical ESC (0x1B) vim/readline users press
    /// constantly, and Ctrl-\ / Ctrl-] / Ctrl-^ / Ctrl-_ / Ctrl-@ are the remaining C0 controls
    /// (0x1C…0x1F, NUL). Previously every non-letter fell through to `v & 0x7F` (a no-op for ASCII),
    /// so Ctrl-[ sent a literal `[` instead of ESC — Escape from the iOS hardware keyboard was
    /// completely broken (R12 #3).
    public static func controlCode(for scalar: UnicodeScalar) -> [UInt8] {
        let v = scalar.value
        if v >= 0x61, v <= 0x7A { return [UInt8(v - 0x60)] }        // a-z → 1…26
        if v >= 0x41, v <= 0x5A { return [UInt8(v - 0x40)] }        // A-Z → 1…26
        if v >= 0x40, v <= 0x5F { return [UInt8(v & 0x1F)] }        // @ [ \ ] ^ _ → 0x00,0x1B,0x1C,0x1D,0x1E,0x1F
        if v == 0x20 { return [0x00] }                              // Ctrl-Space → NUL
        if v == 0x3F { return [0x7F] }                              // Ctrl-? → DEL
        return [UInt8(v & 0x7F)]
    }

    /// Splits a soft-keyboard text commit when the accessory-bar Ctrl is ARMED: the FIRST scalar folds
    /// to its control code (to be sent RAW — the PTY never echoes a control byte), and the remainder
    /// stays plain text. Returns `nil` when not armed or the text is empty (send the text as-is). This is
    /// the pure, headless-testable core of the accessory Ctrl fold — without it the bar's Ctrl button was
    /// a dead no-op for soft-keyboard letters, so Ctrl-C from a pure soft keyboard was impossible (R13 #6).
    public static func foldArmedControl(_ text: String, armed: Bool) -> (controlBytes: [UInt8], rest: String)? {
        guard armed, let first = text.unicodeScalars.first else { return nil }
        let rest = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst()))
        return (controlCode(for: first), rest)
    }

    /// Special-key bytes resolvable WITHOUT UIKit — the `characters`-keyed switch (Esc / Tab /
    /// Shift+Tab / Return / Backspace). Arrows depend on the `UIKeyCommand.input*Arrow` constants and
    /// are resolved by the iOS layer and threaded in through ``encode(_:arrowFallback:)``.
    public static func characterSpecialBytes(for press: InputRouting.KeyPress) -> [UInt8]? {
        switch press.characters {
        case "\u{1B}": return [0x1B]                  // ESC
        // Shift+Tab is back-tab (CBT, ESC [ Z) — UIKit reports the same "\t" with or without Shift,
        // so the shift flag is the only discriminator. Plain Tab stays forward TAB (R12 #6).
        case "\t":     return press.shift ? [0x1B, 0x5B, 0x5A] : [0x09]
        case "\r", "\n": return [0x0D]                // CR (Enter)
        case "\u{7F}", "\u{08}": return [0x7F]        // DEL (Backspace)
        default: return nil
        }
    }

    /// Encodes a classified key-path press into the raw terminal bytes for `sendInput`. Returns `nil`
    /// for a press that carries nothing to send (e.g. a bare modifier). `arrowFallback` resolves the
    /// UIKit-constant arrow keys; pure callers/tests that don't exercise arrows can omit it.
    public static func encode(
        _ press: InputRouting.KeyPress,
        arrowFallback: (InputRouting.KeyPress) -> [UInt8]? = { _ in nil }
    ) -> [UInt8]? {
        if press.isSpecial, let bytes = characterSpecialBytes(for: press) ?? arrowFallback(press) {
            // Option held with a special key applies the same xterm metaSendsEscape prefix the letter
            // path uses below: Option+Backspace → ESC + DEL (readline/zsh delete-previous-word),
            // Option+Return → ESC + CR, Option+Arrow → ESC + CSI. Without this the Option modifier was
            // silently dropped on every special key, degrading word-wise shell editing (R12 #5). Plain
            // (un-Option) special keys are byte-identical to before. Ctrl on a special key is NOT a
            // simple prefix (it needs parameterized CSI, e.g. ESC[1;5D) so it is left unchanged here.
            return press.option ? [0x1B] + bytes : bytes
        }
        // Ctrl/Alt + letter: fold to a control code (Ctrl-C → 0x03) or ESC-prefix (Alt-b).
        let base = press.charactersIgnoringModifiers
        guard let scalar = base.unicodeScalars.first else { return nil }
        if press.control {
            // A co-held Option (Ctrl+Alt+letter) still takes the xterm meta/ESC prefix — e.g.
            // Ctrl+Alt+C → ESC 0x03 — instead of silently dropping the Option (R13).
            let code = controlCode(for: scalar)
            return press.option ? [0x1B] + code : code
        }
        if press.option {
            // Meta/Alt: ESC prefix + the base letter (the xterm metaSendsEscape convention).
            return [0x1B] + Array(base.utf8)
        }
        // A Command-combo is an app shortcut, not terminal input — nothing to send.
        return nil
    }
}
