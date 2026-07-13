import Foundation

/// Named-key → PTY byte mapping for the agent-control `write` verb (`--key C-c,Enter,Up`).
///
/// tmux `send-keys` vocabulary: an agent should never have to hand-encode `\u{03}` in JSON to
/// interrupt a command. Pure + dependency-free (unit-pinned by `ControlKeyMapTests`).
///
/// ## Encoding choices
/// - Arrows / Home / End emit the CSI ("normal cursor-key mode") forms (`ESC [ A` …). A full-screen
///   app in DECCKM application mode expects SS3 (`ESC O A`), but every line editor (zle/readline)
///   and most TUIs accept the CSI form too; the host keeps no terminal-mode state to pick from, so
///   the widely-accepted form wins.
/// - `C-<x>` maps to the control byte (`x & 0x1F`); `C-Space` is NUL. `M-<x>` / `A-<x>` is the
///   ESC-prefixed meta form.
/// - Token matching is case-INSENSITIVE for named keys (`enter` == `Enter`); the `<x>` in a
///   `C-`/`M-` chord keeps its case for the meta byte but is lowercased for the control fold
///   (`C-C` == `C-c`, matching tmux).
public enum ControlKeyMap {
    /// The bytes for one key token, or `nil` for an unknown token (validate-then-drop: the
    /// `write` verb rejects the whole request so a typo never sends a partial key sequence).
    public static func bytes(for token: String) -> [UInt8]? {
        // Control chord: C-a … C-z, C-Space (NUL), C-[ ] \ ^ _ (the full ASCII control fold).
        if token.count > 2, token.hasPrefix("C-") || token.hasPrefix("c-") {
            return controlChord(String(token.dropFirst(2)))
        }
        // Meta chord: ESC-prefixed byte(s) of the remainder (tmux M-x; Alt alias).
        if token.count > 2, token.hasPrefix("M-") || token.hasPrefix("m-"),
           let rest = metaChord(String(token.dropFirst(2)))
        {
            return rest
        }
        if token.count > 2, token.hasPrefix("A-") || token.hasPrefix("a-"),
           let rest = metaChord(String(token.dropFirst(2)))
        {
            return rest
        }

        switch token.lowercased() {
        case "enter",
             "return",
             "cr":
            return [0x0D]
        case "tab":
            return [0x09]
        case "space":
            return [0x20]
        case "esc",
             "escape":
            return [0x1B]
        case "backspace",
             "bspace",
             "bs":
            return [0x7F]
        case "delete",
             "del",
             "dc":
            return csi("3~")
        case "up":
            return csi("A")
        case "down":
            return csi("B")
        case "right":
            return csi("C")
        case "left":
            return csi("D")
        case "home":
            return csi("H")
        case "end":
            return csi("F")
        case "pageup",
             "pgup",
             "ppage":
            return csi("5~")
        case "pagedown",
             "pgdn",
             "npage":
            return csi("6~")
        case "insert",
             "ic":
            return csi("2~")
        case "f1":
            return [0x1B, 0x4F, 0x50] // SS3 P
        case "f2":
            return [0x1B, 0x4F, 0x51] // SS3 Q
        case "f3":
            return [0x1B, 0x4F, 0x52] // SS3 R
        case "f4":
            return [0x1B, 0x4F, 0x53] // SS3 S
        case "f5":
            return csi("15~")
        case "f6":
            return csi("17~")
        case "f7":
            return csi("18~")
        case "f8":
            return csi("19~")
        case "f9":
            return csi("20~")
        case "f10":
            return csi("21~")
        case "f11":
            return csi("23~")
        case "f12":
            return csi("24~")
        default:
            return nil
        }
    }

    /// Resolves a comma-separated key list (`"C-c,Enter"`) or an array of tokens into one byte
    /// buffer, or `nil` naming the first unknown token.
    public static func bytes(forTokens tokens: [String]) -> (bytes: [UInt8], unknown: String?) {
        var out: [UInt8] = []
        for token in tokens {
            guard let b = bytes(for: token) else { return ([], token) }
            out.append(contentsOf: b)
        }
        return (out, nil)
    }

    // MARK: - Internals

    private static func csi(_ suffix: String) -> [UInt8] {
        [0x1B, 0x5B] + Array(suffix.utf8)
    }

    /// `C-<x>`: the ASCII control fold. Letters fold case-insensitively (`C-C` == `C-c` == 0x03);
    /// `space` → NUL; the punctuation control set (`[ \ ] ^ _ ?`) folds too (`C-?` = DEL 0x7F).
    private static func controlChord(_ rest: String) -> [UInt8]? {
        if rest.lowercased() == "space" { return [0x00] }
        guard rest.count == 1, let scalar = rest.lowercased().unicodeScalars.first else { return nil }
        switch scalar {
        case "a"..."z":
            return [UInt8(scalar.value & 0x1F)]
        case "[",
             "\\",
             "]",
             "^",
             "_":
            return [UInt8(scalar.value & 0x1F)]
        case "?":
            return [0x7F]
        default:
            return nil
        }
    }

    /// `M-<x>`: ESC + the resolved remainder (a named key or a literal single character).
    private static func metaChord(_ rest: String) -> [UInt8]? {
        if let named = bytes(for: rest) { return [0x1B] + named }
        guard rest.count == 1 else { return nil }
        return [0x1B] + Array(rest.utf8)
    }
}
