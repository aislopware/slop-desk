import Foundation

/// Classifies one client→PTY input chunk: does it carry a USER KEYSTROKE, or only the terminal
/// emulator's own automatic traffic?
///
/// The same `input` frames that carry keystrokes also carry replies the client terminal emits with
/// no human behind them — focus in/out (`CSI I`/`CSI O`, sent by merely VISITING a pane), cursor
/// position / device-attribute / mode reports answering the program's queries, and SGR mouse-wheel
/// events from scrolling the transcript. The `.userInput` unblock signal must fire on none of
/// those: a visit or a scroll is READING a blocked pane, not answering its dialog.
///
/// Pure + total (validate-then-drop): any byte sequence is tolerated; a sequence truncated at the
/// chunk boundary classifies as NOT a keystroke (conservative — never demote on an unknowable
/// fragment). The one deliberate exception: a chunk ENDING in a bare `ESC` is the Esc key's legacy
/// encoding — the exact key that cancels a dialog — not a truncated report (reports arrive as
/// complete writes).
public enum PaneInputClassifier {
    /// True iff `bytes` contains at least one user keystroke.
    public static func containsUserKeystroke(_ bytes: Data) -> Bool {
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let byte = bytes[i]
            // Any byte outside an escape sequence — printable, CR, control chords — is a key.
            guard byte == 0x1B else { return true }
            let introducerIndex = bytes.index(after: i)
            // A chunk ending in a bare ESC is the Esc KEY (legacy encoding), not a fragment.
            guard introducerIndex < end else { return true }
            switch bytes[introducerIndex] {
            case UInt8(ascii: "["):
                switch classifyCSI(bytes, parameterStart: bytes.index(after: introducerIndex), end: end) {
                case .keystroke: return true
                case let .report(resumeAt: next): i = next
                case .truncated: return false
                }
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                // OSC / DCS / SOS / PM / APC — string replies (colour queries, XTGETTCAP…).
                // Consume through the BEL or ST terminator; truncated → conservative no.
                guard let next = indexPastStringTerminator(bytes, from: bytes.index(after: introducerIndex), end: end)
                else { return false }
                i = next
            default:
                // ESC + anything else: SS3 function keys (`ESC O P`), alt-chords (`ESC f`),
                // double-Esc — all user keys.
                return true
            }
        }
        return false
    }

    private enum CSIClass {
        case keystroke
        case report(resumeAt: Data.Index)
        case truncated
    }

    /// Classifies one CSI sequence starting at its first parameter byte. Reports are recognised
    /// two ways: a private-marker prefix (`?` = DA1/DECRPM/DECXCPR/kitty-flags replies, `>` = DA2,
    /// `<` = SGR mouse), or a report-only final byte (`R` CPR, `n` DSR, `c` DA, `y` DECRPM,
    /// `I`/`O` focus). Everything else — arrows, tilde keys, `CSI u` kitty keys, shift-tab `Z` —
    /// is a keystroke.
    private static func classifyCSI(_ bytes: Data, parameterStart: Data.Index, end: Data.Index) -> CSIClass {
        var j = parameterStart
        let hasPrivateMarker = j < end && (0x3C...0x3F).contains(bytes[j]) // < = > ?
        while j < end {
            let c = bytes[j]
            if (0x40...0x7E).contains(c) {
                let next = bytes.index(after: j)
                if hasPrivateMarker { return .report(resumeAt: next) }
                switch c {
                case UInt8(ascii: "R"),
                     UInt8(ascii: "n"),
                     UInt8(ascii: "c"),
                     UInt8(ascii: "y"),
                     UInt8(ascii: "I"),
                     UInt8(ascii: "O"):
                    return .report(resumeAt: next)
                default:
                    return .keystroke
                }
            }
            // Parameter / intermediate bytes; anything outside 0x20–0x3F is a malformed
            // sequence — treat like a truncation (conservative no).
            guard (0x20...0x3F).contains(c) else { return .truncated }
            j = bytes.index(after: j)
        }
        return .truncated
    }

    /// Index just past a BEL- or ST-terminated string sequence, or `nil` when the terminator is
    /// missing from this chunk.
    private static func indexPastStringTerminator(_ bytes: Data, from: Data.Index, end: Data.Index) -> Data.Index? {
        var j = from
        while j < end {
            let c = bytes[j]
            if c == 0x07 { return bytes.index(after: j) } // BEL
            if c == 0x1B {
                let next = bytes.index(after: j)
                if next < end, bytes[next] == UInt8(ascii: "\\") { return bytes.index(after: next) } // ST
            }
            j = bytes.index(after: j)
        }
        return nil
    }
}
