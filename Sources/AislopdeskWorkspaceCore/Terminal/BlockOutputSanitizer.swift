import Foundation

// MARK: - BlockOutputSanitizer (raw VT bytes → clipboard plain text)

/// Turns a Block's RAW captured VT output bytes (control sequences preserved on the wire) into PLAIN
/// TEXT suitable for the clipboard (WB2): it strips the terminal control sequences (CSI / SGR colour
/// runs, OSC, single-char C0/C1 controls) and keeps the PRINTABLE characters + newlines + tabs.
///
/// This is a deliberately SMALL, robust VT skimmer — not a full terminal emulator. It does not try to
/// interpret cursor motion / clears (the host's captured output is already the on-screen byte stream for
/// the command, so a linear strip reproduces what the user saw closely enough for a copy). It is built to
/// NEVER trap on a malformed / truncated sequence: an unterminated CSI/OSC at end-of-buffer simply
/// consumes to the end, and every index advance is bounds-checked.
///
/// PURE + `nonisolated` so it runs off any actor and is headlessly unit-testable (the WB2 brief's ask:
/// colour runs stripped, text preserved, malformed sequences don't trap).
public enum BlockOutputSanitizer {
    /// Strips VT control sequences from `bytes` and decodes the surviving printable run as UTF-8 (lossy:
    /// an invalid byte becomes U+FFFD — the clipboard text is best-effort, never a throw). Newlines (`\n`,
    /// and a `\r\n` collapsed to `\n`) and tabs are preserved; a bare `\r` (carriage return without a
    /// following `\n`) is dropped (it is overwrite-cursor motion, not a line the user wants pasted).
    public static func plainText(from bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }
        let input = [UInt8](bytes)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        let n = input.count
        // CR line-rewrite semantics: the current visual line is a column-indexed byte buffer with a cursor,
        // so a progress bar (which redraws one line via `\r`) collapses to its FINAL frame instead of every
        // frame concatenated. A printable byte writes at the cursor (overwriting an earlier frame), a lone
        // `\r` rewinds the cursor to column 0, `ESC [ K` truncates at the cursor, and LF commits the line.
        var line: [UInt8] = []
        var col = 0 // invariant: 0 ≤ col ≤ line.count
        // Reverse-video (SGR 7) tracking so a trailing zsh PROMPT_EOL_MARK can be dropped. zsh prints a
        // reverse-video `%` (or `#` for root) padded with spaces + a bare CR when the command's last output
        // line lacks a trailing newline — it lands INSIDE the captured C→D bytes and, once the SGR is
        // stripped, would otherwise survive as a bare trailing "%". `eolMark` remembers the column on the
        // current line of a reverse-video `%`/`#` followed only by pad whitespace; it is chopped at the end.
        var reverseOn = false
        var eolMark: Int?
        func put(_ b: UInt8) {
            if col < line.count { line[col] = b } else { line.append(b) }
            col += 1
        }
        func commitLine() {
            out.append(contentsOf: line)
            out.append(0x0A)
            line.removeAll(keepingCapacity: true)
            col = 0
            eolMark = nil
        }
        while i < n {
            let byte = input[i]
            switch byte {
            case 0x1B: // ESC — start of an escape sequence
                let end = skipEscapeSequence(input, from: i)
                if let effect = sgrReverseEffect(input, from: i, upTo: end) {
                    reverseOn = effect
                } else if isEraseToLineEnd(input, from: i, upTo: end), col < line.count {
                    line.removeLast(line.count - col) // `ESC [ K` — erase cursor→end of line
                }
                i = end
            case 0x0A: // LF — commit the current visual line (a real newline)
                commitLine()
                i += 1
            case 0x09: // HT — keep (a tab; meaningful whitespace in pasted output) at the cursor
                eolMark = nil
                put(0x09)
                i += 1
            case 0x0D: // CR — `\r\n` → newline; a lone `\r` rewinds the cursor to column 0 (overwrite motion)
                if i + 1 < n, input[i + 1] == 0x0A {
                    commitLine()
                    i += 2
                } else {
                    col = 0
                    i += 1
                }
            case 0x00...0x08,
                 0x0B,
                 0x0C,
                 0x0E...0x1F,
                 0x7F:
                // Other C0 controls + DEL — drop (BS/VT/FF/SI/SO/etc. are formatting noise for a paste).
                i += 1
            case 0x23,
                 0x25: // '#' / '%' — candidate zsh EOL mark iff currently reverse-video
                eolMark = reverseOn ? col : nil
                put(byte)
                i += 1
            case 0x20: // space — pad after the EOL mark; keep it AND any pending mark candidate
                put(byte)
                i += 1
            default:
                // Printable ASCII or a UTF-8 continuation/lead byte (≥ 0x80) — keep verbatim; the final
                // lossy UTF-8 decode reassembles multi-byte scalars (and replaces any broken ones). Any
                // ordinary printable invalidates a pending EOL-mark candidate.
                eolMark = nil
                put(byte)
                i += 1
            }
        }
        // Chop a trailing zsh PROMPT_EOL_MARK from the current (unterminated) line: the reverse-video
        // `%`/`#` at `eolMark` plus the pad whitespace after it, then flush the line WITHOUT a newline.
        if let eolMark, eolMark < line.count { line.removeLast(line.count - eolMark) }
        out.append(contentsOf: line)
        // LOSSY by design: a clipboard paste is best-effort — a broken UTF-8 byte in the captured output
        // becomes U+FFFD rather than dropping the whole copy. `String(decoding:as:)` is the non-failable
        // lossy initializer; the failable `String(bytes:encoding:)` the lint rule prefers would return nil
        // on any invalid byte and lose the paste, which is the wrong trade-off here.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out, as: UTF8.self)
    }

    /// Returns the index PAST the escape sequence beginning at `start` (where `input[start] == ESC`).
    /// Handles the three shapes the host's captured output can contain:
    ///   • CSI `ESC [ … <final 0x40–0x7E>` (SGR colours, cursor ops, erases) — skip to the final byte;
    ///   • OSC `ESC ] … (BEL | ESC \\)` (title / hyperlink / clipboard) — skip to the terminator;
    ///   • a SHORT two-byte escape `ESC <byte>` (e.g. `ESC ( B` charset, `ESC =` keypad) — skip both.
    /// An UNTERMINATED sequence at end-of-buffer consumes to the end (never reads past `n`).
    private static func skipEscapeSequence(_ input: [UInt8], from start: Int) -> Int {
        let n = input.count
        let next = start + 1
        guard next < n else { return n } // a trailing bare ESC — consume it
        switch input[next] {
        case 0x5B: // '[' — CSI: parameter/intermediate bytes (0x20–0x3F) then a final (0x40–0x7E)
            var j = next + 1
            while j < n {
                let b = input[j]
                if (0x40...0x7E).contains(b) { return j + 1 } // final byte ends the CSI
                j += 1
            }
            return n // unterminated CSI — consumed to the end
        case 0x5D: // ']' — OSC: runs until BEL (0x07) or ST (ESC '\\')
            var j = next + 1
            while j < n {
                if input[j] == 0x07 { return j + 1 } // BEL terminator
                if input[j] == 0x1B, j + 1 < n, input[j + 1] == 0x5C { return j + 2 } // ST = ESC '\'
                j += 1
            }
            return n // unterminated OSC — consumed to the end
        case 0x50, // 'P' DCS (sixel, DECRQSS, …)
             0x58, // 'X' SOS
             0x5E, // '^' PM
             0x5F, // '_' APC (kitty graphics)
             0x6B: // 'k' (screen/tmux title) — string sequences: consume the payload up to ST (ESC \) or BEL
            var j = next + 1
            while j < n {
                if input[j] == 0x07 { return j + 1 } // BEL terminator
                if input[j] == 0x1B, j + 1 < n, input[j + 1] == 0x5C { return j + 2 } // ST = ESC '\'
                j += 1
            }
            return n // unterminated string sequence — consumed to the end
        default:
            // A short escape (charset select `ESC ( X`, keypad `ESC =`, etc.). Most are two bytes; the
            // charset-designator forms are three (`ESC ( B`). Skip the introducer; if the next byte is a
            // charset-designation introducer ('(' ')' '*' '+'), skip its argument too. Bounds-checked.
            let intro = input[next]
            if intro == 0x28 || intro == 0x29 || intro == 0x2A || intro == 0x2B, next + 1 < n {
                return next + 2 // ESC ( B  → 3 bytes total
            }
            return next + 1 // ESC X → 2 bytes total
        }
    }

    /// Interprets the escape sequence `input[start..<end]` (where `input[start] == ESC`) as an SGR and
    /// returns its effect on the reverse-video (standout) state, used ONLY to detect a zsh EOL mark:
    ///   • `true`  — the SGR turns reverse-video ON (a `7` parameter);
    ///   • `false` — the SGR turns it OFF (a `0`/empty reset, or an explicit `27`);
    ///   • `nil`   — not an SGR, or an SGR that doesn't touch reverse-video (leave the state unchanged).
    /// Only a CSI ending in `m` is an SGR; parameters are `;`-separated decimal runs between `ESC [` and `m`.
    private static func sgrReverseEffect(_ input: [UInt8], from start: Int, upTo end: Int) -> Bool? {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x6D else { return nil } // `ESC [ … m`
        // Empty params (`ESC [ m`) == `ESC [ 0 m` == a full reset → reverse OFF.
        guard end - 1 > start + 2 else { return false }
        var result: Bool?
        var value = 0
        var sawDigit = false
        func commit() {
            if !sawDigit { result = false } // an empty field is a `0` reset → reverse OFF
            else if value == 7 { result = true }
            else if value == 0 || value == 27 { result = false }
            sawDigit = false
            value = 0
        }
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            if b == 0x3B { // ';' — parameter separator
                commit()
            } else if (0x30...0x39).contains(b) { // '0'…'9'
                // Cap the accumulation so a degenerate long-digit parameter (e.g. `ESC [ 99999…m`) can never
                // overflow Int and TRAP — this skimmer must never crash on malformed input (see the header).
                if value < 100_000_000 { value = value * 10 + Int(b - 0x30) }
                sawDigit = true
            } else {
                return nil // an intermediate byte (e.g. `ESC [ ? … m`) — not a plain SGR we interpret
            }
        }
        commit()
        return result
    }

    /// True iff `input[start…end]` is an ERASE-TO-END-OF-LINE CSI (`ESC [ K` or `ESC [ 0 K`) — the form a
    /// progress bar uses to clear stale trailing characters after a shorter frame. `ESC [ 1 K` / `ESC [ 2 K`
    /// (and any other final byte) return `false` so they stay stripped no-ops.
    private static func isEraseToLineEnd(_ input: [UInt8], from start: Int, upTo end: Int) -> Bool {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x4B else { return false } // `ESC [ … K`
        if end - 1 > start + 2, (0x3C...0x3F).contains(input[start + 2]) { return false } // private-mode CSI
        var value = 0
        var sawDigit = false
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            guard (0x30...0x39).contains(b) else { return false } // `;` / intermediate — not a simple erase
            if value < 100_000_000 { value = value * 10 + Int(b - 0x30) } // capped (never trap on a digit run)
            sawDigit = true
        }
        return !sawDigit || value == 0 // empty param == `0` == erase-to-end
    }
}
