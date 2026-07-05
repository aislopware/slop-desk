import Foundation

/// Pure-Swift ANSI escape-sequence stripper.
///
/// Removes the most common terminal escape sequences from a UTF-8 string,
/// returning plain text suitable for regex matching (the `wait` verb's `--until`
/// predicate). The implementation is a byte-at-a-time state machine — no heap
/// allocation per character, no Foundation regex overhead. Non-destructive in the
/// sense that the caller owns the original string; this returns a new `String`.
///
/// Stripped sequences:
/// - CSI sequences: `ESC [` followed by parameter/intermediate bytes and one final byte.
/// - OSC sequences: `ESC ]` (or `\x9D`) followed by any bytes up to `BEL` / `ST` (`ESC \`).
/// - DCS / SOS / PM / APC sequences: `ESC P/X/^/_` body up to `ST`.
/// - Charset designator sequences: `ESC (` / `)` / `*` / `+` followed by one designator byte.
/// - Single-character C1 controls that are sometimes sent as two-byte `ESC x` (`ESC @` … `ESC _`).
/// - Standalone `ESC c` (RIS) and similar two-byte private sequences outside CSI/OSC range.
/// - Nerd-font private-use-area glyphs (U+E000–U+F8FF, U+F0000–U+FFFFF).
///
/// Passes through printable ASCII, UTF-8 multi-byte codepoints, tab, newline, carriage
/// return, backspace — the text content an `--until` regex needs.
///
/// No C/unsafe: pure Swift byte scanning.
public enum ANSIStripper {
    /// Returns `input` with all recognised ANSI/VT escape sequences removed.
    public static func strip(_ input: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(input.utf8.count)

        let bytes = Array(input.utf8)
        var i = bytes.startIndex
        // Track remaining UTF-8 continuation bytes for the current multi-byte codepoint.
        // When `utf8Tail > 0`, the current byte is a continuation byte (0x80–0xBF) that
        // belongs to a multi-byte sequence started by an earlier leading byte — it must be
        // passed through as-is and must NOT be interpreted as a C1 control byte.
        var utf8Tail = 0

        while i < bytes.endIndex {
            let b = bytes[i]

            // Multi-byte UTF-8 continuation: pass through, decrement tail counter.
            if utf8Tail > 0 {
                out.append(b)
                utf8Tail -= 1
                i = bytes.index(after: i)
                continue
            }

            // Determine if this byte starts a multi-byte UTF-8 sequence.
            // Leading bytes: 0xC0–0xDF (2-byte), 0xE0–0xEF (3-byte), 0xF0–0xF7 (4-byte).
            // We count the continuation bytes to expect AFTER this byte.
            if b >= 0xC2, b <= 0xDF {
                utf8Tail = 1
                out.append(b)
                i = bytes.index(after: i)
                continue
            }
            if b >= 0xE0, b <= 0xEF {
                utf8Tail = 2
                out.append(b)
                i = bytes.index(after: i)
                continue
            }
            if b >= 0xF0, b <= 0xF7 {
                utf8Tail = 3
                out.append(b)
                i = bytes.index(after: i)
                continue
            }

            if b == 0x1B { // ESC
                let next = bytes.index(after: i)
                guard next < bytes.endIndex else { i = bytes.endIndex
                    break
                }
                let b2 = bytes[next]
                switch b2 {
                case 0x5B: // CSI — 'ESC ['
                    i = skipCSI(bytes: bytes, from: bytes.index(after: next))
                case 0x5D, // OSC — 'ESC ]'
                     0x50, // DCS — 'ESC P'
                     0x58, // SOS — 'ESC X'
                     0x5E, // PM  — 'ESC ^'
                     0x5F: // APC — 'ESC _'
                    i = skipStringCommand(bytes: bytes, from: bytes.index(after: next))
                case 0x28, // Charset designator: 'ESC (' — G0
                     0x29, // 'ESC )' — G1
                     0x2A, // 'ESC *' — G2
                     0x2B: // 'ESC +' — G3
                    // Three-byte sequence: ESC + introducer + one designator byte (e.g. 'B' or '0').
                    // The default arm only skips ESC+introducer (2 bytes), leaving the designator
                    // byte in the output. Starship/Powerlevel10k emits ESC(B ESC)0 — fix that here.
                    let designator = bytes.index(after: next)
                    i = designator < bytes.endIndex ? bytes.index(after: designator) : bytes.index(after: next)
                default:
                    // Two-byte ESC sequence (C1 alias or private): skip both bytes.
                    i = bytes.index(after: next)
                }
            } else if b == 0x9B { // C1 CSI (raw 0x9B byte in a Latin-1 / 8-bit stream).
                // NOTE: in valid UTF-8, U+009B encodes as 0xC2 0x9B (two bytes). The leading
                // 0xC2 is handled by the multi-byte leading-byte branch above, which sets
                // utf8Tail = 1; the 0x9B continuation is then passed through, never reaching
                // here. This branch fires ONLY for raw-byte PTY output (8-bit mode streams)
                // where 0x9B is a true standalone C1 CSI byte.
                i = skipCSI(bytes: bytes, from: bytes.index(after: i))
            } else if b == 0x9D { // C1 OSC (8-bit), same rationale as 0x9B above.
                i = skipStringCommand(bytes: bytes, from: bytes.index(after: i))
            } else {
                out.append(b)
                i = bytes.index(after: i)
            }
        }

        let raw = String(bytes: out, encoding: .utf8) ?? String(out.map { Character(UnicodeScalar($0)) })
        // Filter Nerd-font / Powerline private-use-area glyphs (U+E000–U+F8FF, U+F0000–U+FFFFF).
        // They are valid UTF-8 multi-byte sequences so the byte-scanner passes them through; strip
        // them here so agent output is clean for regex matching (they appear as one visible glyph
        // and do not break matching, but they make the stripped text unclean for agent consumption).
        return String(raw.unicodeScalars.filter { s in
            let v = s.value
            return !(v >= 0xE000 && v <= 0xF8FF) && !(v >= 0xF0000 && v <= 0xFFFFF)
        })
    }

    // MARK: - Private helpers

    /// Skips a CSI sequence body. Called immediately AFTER the CSI introducer.
    /// CSI body = zero or more parameter bytes (0x30–0x3F) + intermediate bytes (0x20–0x2F)
    /// + exactly one final byte (0x40–0x7E). Returns the index of the first byte AFTER the sequence.
    private static func skipCSI(bytes: [UInt8], from start: Int) -> Int {
        var i = start
        // Parameter bytes: 0x30–0x3F
        while i < bytes.endIndex, bytes[i] >= 0x30, bytes[i] <= 0x3F { i = bytes.index(after: i) }
        // Intermediate bytes: 0x20–0x2F
        while i < bytes.endIndex, bytes[i] >= 0x20, bytes[i] <= 0x2F { i = bytes.index(after: i) }
        // Final byte: 0x40–0x7E
        if i < bytes.endIndex, bytes[i] >= 0x40, bytes[i] <= 0x7E { i = bytes.index(after: i) }
        return i
    }

    /// Skips an OSC/DCS/SOS/PM/APC string-command body.
    /// Body ends at BEL (0x07) or String Terminator (ST = ESC \\ = 0x1B 0x5C).
    /// Returns the index of the first byte AFTER the terminator.
    private static func skipStringCommand(bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0x07 { // BEL terminates OSC
                return bytes.index(after: i)
            }
            if b == 0x1B { // ESC — check for ST (ESC \)
                let next = bytes.index(after: i)
                if next < bytes.endIndex, bytes[next] == 0x5C {
                    return bytes.index(after: next)
                }
                // Malformed: treat ESC without '\' as terminator to avoid runaway skip.
                return next
            }
            if b == 0x9C { // C1 ST (8-bit)
                return bytes.index(after: i)
            }
            i = bytes.index(after: i)
        }
        return i // ran to end of input
    }
}
