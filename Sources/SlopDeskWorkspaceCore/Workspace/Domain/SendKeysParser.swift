import Foundation

// MARK: - SendKeysParser (tmux-style control-key tokens → bytes)

/// Pure parser turning `<Token>`-marked text into the raw byte sequence to feed a PTY — the shared
/// "send-keys" primitive (launch presets, session templates, block re-run, drops, the CLI `pane
/// send-keys`). Literal runs become their UTF-8 bytes; `<Token>` markers become control bytes. An UNRECOGNIZED
/// `<...>` (or a bare `<` with no close) is emitted LITERALLY, so ordinary text containing `<` (`a < b`,
/// `printf "<3"`) is never mangled. Token names are case-insensitive. Fully table-tested.
public enum SendKeysParser {
    public static func encode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "<" {
                // Look for a closing '>' within a bounded window (token names are short).
                if let close = findClose(scalars, from: i + 1),
                   let bytes = token(String(String.UnicodeScalarView(scalars[(i + 1)..<close])))
                {
                    out += bytes
                    i = close + 1
                    continue
                }
                // Not a recognized token — emit '<' literally and advance one scalar.
                out += Array("<".utf8)
                i += 1
                continue
            }
            out += Array(String(s).utf8)
            i += 1
        }
        return out
    }

    /// Index of the next '>' after `from`, within a small window (a token name is short), or `nil`.
    private static func findClose(_ scalars: [Unicode.Scalar], from: Int) -> Int? {
        let limit = min(scalars.count, from + 12) // longest token ("Backspace") + slack
        var j = from
        while j < limit {
            if scalars[j] == ">" { return j }
            if scalars[j] == "<" { return nil } // a nested '<' means the first wasn't a token open
            j += 1
        }
        return nil
    }

    private static let esc: UInt8 = 0x1B

    /// The bytes for a token name (without the angle brackets), or `nil` if unrecognized.
    private static func token(_ raw: String) -> [UInt8]? {
        let name = raw.lowercased()
        switch name {
        case "enter",
             "cr",
             "return": return [0x0D]
        case "nl",
             "lf",
             "newline": return [0x0A]
        case "tab": return [0x09]
        case "esc",
             "escape": return [esc]
        case "space": return [0x20]
        case "bs",
             "backspace": return [0x7F]
        case "del",
             "delete": return [esc, 0x5B, 0x33, 0x7E] // ESC [ 3 ~
        case "up": return [esc, 0x5B, 0x41] // ESC [ A
        case "down": return [esc, 0x5B, 0x42]
        case "right": return [esc, 0x5B, 0x43]
        case "left": return [esc, 0x5B, 0x44]
        case "home": return [esc, 0x5B, 0x48]
        case "end": return [esc, 0x5B, 0x46]
        default:
            // Ctrl chord: <C-x> → control byte (x masked to 0x1F). Meta chord: <M-x> → ESC + x.
            if name.hasPrefix("c-"), name.count == 3, let ch = name.last, let a = ch.asciiValue {
                // a..z / @ [ \ ] ^ _ map to 0x00..0x1F via & 0x1F (upper-case folding for letters).
                let upper = (ch.isLetter ? Character(ch.uppercased()) : ch)
                guard let u = upper.asciiValue else { return nil }
                _ = a
                return [u & 0x1F]
            }
            if name.hasPrefix("m-"), name.count == 3, let ch = name.last, ch.isASCII {
                return [esc] + Array(String(ch).utf8)
            }
            return nil
        }
    }
}
