import Foundation

// MARK: - KeystrokeReplay (clipboard text → key-event sequence)

/// One synthetic keystroke: a macOS virtual key code (`kVK_*`) plus whether Shift is held. The host's
/// per-event input path (`InputInjector.postKey`) posts each as a `CGEvent` key — which types into a
/// `sudo` / SecurityAgent password field (HW-proven 2026-06-15: a `CGEvent(.cghidEventTap)` keystroke
/// reaches the secure field even with Secure Event Input active).
public struct ReplayStroke: Sendable, Equatable {
    public var keyCode: UInt16
    public var shift: Bool
    public init(keyCode: UInt16, shift: Bool) {
        self.keyCode = keyCode
        self.shift = shift
    }
}

/// Encodes a clipboard string into a sequence of ``ReplayStroke``s against the US-QWERTY layout — the
/// layout-dependent inverse of unicode text injection, needed because secure fields drop synthetic
/// unicode events but accept HID key events. Characters with no US-QWERTY mapping (accented letters,
/// emoji, other scripts) are SKIPPED rather than mis-typed; the count is reported so the caller can
/// warn. Pure + `nonisolated` — fully unit-testable with no view, session, or pasteboard.
public enum KeystrokeReplay {
    /// The encoded result: the strokes to send, and how many input characters had no mapping (skipped).
    public struct Encoded: Sendable, Equatable {
        public var strokes: [ReplayStroke]
        public var skipped: Int
    }

    /// The largest clipboard payload we will replay as keystrokes — a guard against a multi-megabyte
    /// paste turning into an endless typing storm into a password field. Beyond this the caller should
    /// refuse (a password is never this long; a giant accidental paste is the real risk).
    public static let maxLength = 4096

    /// Encodes `text` into key strokes, skipping unmappable characters. Truncates at ``maxLength``
    /// (the overflow counts as skipped so the caller can surface "typed N, skipped M").
    public static func encode(_ text: String) -> Encoded {
        // Normalize Windows / web / Git-on-Windows CRLF line endings to LF FIRST: Swift segments "\r\n" as a
        // SINGLE extended-grapheme Character with no US-QWERTY mapping, so without this every CRLF line break
        // would silently fall through to `skipped` (no Return key sent) and collapse multi-line clipboard
        // text onto one line. A lone "\r" or "\n" already maps to Return; only the combined grapheme needs it.
        let normalized = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        var strokes: [ReplayStroke] = []
        var skipped = 0
        var count = 0
        for ch in normalized {
            if count >= maxLength { skipped += 1
                continue
            }
            count += 1
            if let stroke = stroke(for: ch) {
                strokes.append(stroke)
            } else {
                skipped += 1
            }
        }
        return Encoded(strokes: strokes, skipped: skipped)
    }

    /// The ``ReplayStroke`` for a single character, or `nil` if it is not on the US-QWERTY layout.
    static func stroke(for ch: Character) -> ReplayStroke? {
        // Letters: same key, Shift for upper case.
        if let ascii = ch.asciiValue {
            switch ascii {
            case 0x61...0x7A: // a–z
                guard let kc = letterKey[Character(UnicodeScalar(ascii))] else { return nil }
                return ReplayStroke(keyCode: kc, shift: false)
            case 0x41...0x5A: // A–Z
                guard let kc = letterKey[Character(UnicodeScalar(ascii + 0x20))] else { return nil }
                return ReplayStroke(keyCode: kc, shift: true)
            default:
                break
            }
        }
        return symbolKey[ch]
    }

    // MARK: - US-QWERTY key tables (macOS kVK_ANSI_* virtual key codes)

    /// Lower-case letter → key code.
    private static let letterKey: [Character: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
        "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    ]

    /// Digits, punctuation, their shifted symbols, and whitespace → (key code, Shift).
    private static let symbolKey: [Character: ReplayStroke] = {
        var m: [Character: ReplayStroke] = [:]
        // Digit row, unshifted.
        let digits: [(Character, UInt16)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ]
        for (c, kc) in digits { m[c] = ReplayStroke(keyCode: kc, shift: false) }
        // Digit row, shifted symbols (same keys).
        let shiftedDigits: [(Character, UInt16)] = [
            (")", 29), ("!", 18), ("@", 19), ("#", 20), ("$", 21),
            ("%", 23), ("^", 22), ("&", 26), ("*", 28), ("(", 25),
        ]
        for (c, kc) in shiftedDigits { m[c] = ReplayStroke(keyCode: kc, shift: true) }
        // Punctuation, unshifted.
        let punct: [(Character, UInt16)] = [
            ("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42), (";", 41),
            ("'", 39), (",", 43), (".", 47), ("/", 44), ("`", 50),
        ]
        for (c, kc) in punct { m[c] = ReplayStroke(keyCode: kc, shift: false) }
        // Punctuation, shifted.
        let shiftedPunct: [(Character, UInt16)] = [
            ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42), (":", 41),
            ("\"", 39), ("<", 43), (">", 47), ("?", 44), ("~", 50),
        ]
        for (c, kc) in shiftedPunct { m[c] = ReplayStroke(keyCode: kc, shift: true) }
        // Whitespace.
        m[" "] = ReplayStroke(keyCode: 49, shift: false) // space
        m["\t"] = ReplayStroke(keyCode: 48, shift: false) // tab
        m["\n"] = ReplayStroke(keyCode: 36, shift: false) // return
        m["\r"] = ReplayStroke(keyCode: 36, shift: false)
        return m
    }()
}
