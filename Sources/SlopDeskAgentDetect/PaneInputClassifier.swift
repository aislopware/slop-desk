import Foundation

/// Classifies one client→PTY input chunk: does it carry a USER KEYSTROKE, or only the terminal
/// emulator's own automatic traffic — and, more narrowly, does it carry a CANCEL key?
///
/// The same `input` frames that carry keystrokes also carry replies the client terminal emits with
/// no human behind them — focus in/out (`CSI I`/`CSI O`, sent by merely VISITING a pane), cursor
/// position / device-attribute / window-geometry reports answering the program's queries, and mouse
/// events (motion included: the renderer forwards every pointer position to a mouse-reporting TUI, so
/// merely HOVERING a pane floods this path). The unblock signal must fire on none of those: a visit,
/// a scroll or a hover is READING a blocked pane, not answering its dialog.
///
/// Pure + total (validate-then-drop): any byte sequence is tolerated; a sequence truncated at the
/// chunk boundary classifies as NOT a keystroke (conservative — never demote on an unknowable
/// fragment). The one deliberate exception: a chunk ENDING in a bare `ESC` is the Esc key's legacy
/// encoding — the exact key that cancels a dialog — not a truncated report (reports arrive as
/// complete writes).
public enum PaneInputClassifier {
    /// True iff `bytes` contains at least one user keystroke.
    public static func containsUserKeystroke(_ bytes: Data) -> Bool {
        scan(bytes, cancelOnly: false)
    }

    /// True iff `bytes` contains a CANCEL key — `Esc` in ANY of its encodings (the bare legacy
    /// `0x1B`, `ESC ESC`, and kitty's `CSI 27 u`, which is what Claude Code's own keyboard mode
    /// actually sends) or `Ctrl-C` (`0x03`, still legacy under kitty's disambiguate flag).
    ///
    /// This, not ``containsUserKeystroke(_:)``, is what may demote a standing `.needsPermission`
    /// (see the note on `ClaudeSignal.userInput`). The unblock exists for exactly ONE case — an
    /// Esc-cancelled dialog, which fires no hook and would otherwise leave the pane blocked forever
    /// — and every OTHER way of resolving a dialog announces itself: answering a permission prompt
    /// fires `PreToolUse`, answering an `AskUserQuestion` fires its `PostToolUse`. Demoting on ANY
    /// keystroke therefore bought nothing and cost a false edge: arrowing between an
    /// `AskUserQuestion`'s options, or retyping an answer, walked the pane blocked → idle, the
    /// still-visible dialog walked it straight back to blocked, and the second entry rang the
    /// awaiting-input cue again — once per keypress (user-reported 2026-08-10).
    public static func containsCancelKeystroke(_ bytes: Data) -> Bool {
        scan(bytes, cancelOnly: true)
    }

    /// The ONE scanner behind both predicates: walks `bytes`, consuming the emulator's automatic
    /// replies, and answers whether it saw a key (`cancelOnly == false`) or specifically a cancel
    /// key (`cancelOnly == true`). Sharing the walk is what keeps the two answers from drifting —
    /// a report shape taught to one is known to both.
    private static func scan(_ bytes: Data, cancelOnly: Bool) -> Bool {
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let byte = bytes[i]
            guard byte == 0x1B else {
                // Any byte outside an escape sequence — printable, CR, control chords — is a key.
                // For the cancel question only `Ctrl-C` qualifies; everything else keeps scanning,
                // because a later byte in the same chunk may still be the Esc we are looking for.
                if !cancelOnly { return true }
                if byte == 0x03 { return true }
                i = bytes.index(after: i)
                continue
            }
            let introducerIndex = bytes.index(after: i)
            // A chunk ending in a bare ESC is the Esc KEY (legacy encoding), not a fragment.
            guard introducerIndex < end else { return true }
            switch bytes[introducerIndex] {
            case UInt8(ascii: "["):
                switch classifyCSI(bytes, parameterStart: bytes.index(after: introducerIndex), end: end) {
                case let .keystroke(resumeAt: next, isCancel: isCancel):
                    // Most CSI keys (arrows, tilde keys, shift-tab) are not cancels, so the cancel
                    // scan STEPS OVER them and keeps looking — returning false here would miss the
                    // Esc in a chunk that batched an arrow and an Esc into one write. The exception
                    // is kitty's `CSI 27 u`, which IS the Esc key (see `classifyCSI`).
                    if !cancelOnly || isCancel { return true }
                    i = next
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
            case 0x1B:
                // ESC ESC — the Esc key pressed twice (or once, with the emulator's meta-escape).
                // The FIRST one is a genuine bare Esc: a cancel. Resume at the second so it gets
                // its own reading.
                return true
            default:
                // ESC + anything else: SS3 function keys (`ESC O P`), alt-chords (`ESC f`) — all
                // user keys, none of them a cancel.
                if !cancelOnly { return true }
                i = bytes.index(after: introducerIndex)
            }
        }
        return false
    }

    private enum CSIClass {
        /// A real key. Carries the resume index anyway, so the CANCEL scan can step over it and
        /// keep looking (a chunk may batch an arrow key and an Esc into one write). `isCancel` is
        /// true for the ONE CSI key that cancels a dialog — kitty's `CSI 27 u` Esc.
        case keystroke(resumeAt: Data.Index, isCancel: Bool)
        case report(resumeAt: Data.Index)
        case truncated
    }

    /// Classifies one CSI sequence starting at its first parameter byte. Reports are recognised
    /// three ways: a private-marker prefix (`?` = DA1/DECRPM/DECXCPR/kitty-flags replies, `>` = DA2,
    /// `<` = SGR mouse), a report-only final byte (`R` CPR, `n` DSR, `c` DA, `y` DECRPM, `I`/`O`
    /// focus, `t` XTWINOPS geometry, `M` mouse), or the bare X10 mouse form, whose three POSITION
    /// bytes follow the final `M` and must be consumed with it. Everything else — arrows, tilde
    /// keys, `CSI u` kitty keys, shift-tab `Z` — is a keystroke.
    ///
    /// ⚠️ `M` is why hovering a blocked pane used to ring the awaiting-input cue. libghostty encodes
    /// mouse reports in whatever scheme the program asked for, and the X10 default (`CSI M Cb Cx Cy`)
    /// has no private marker and a final byte this switch did not know — so every pointer MOTION
    /// event over a mouse-reporting TUI classified as a keystroke, demoted the block, and let the
    /// still-visible dialog re-raise it (user-reported 2026-08-10). No keyboard encoding produces
    /// `CSI …M`/`CSI …t`, so both finals are unconditionally reports.
    private static func classifyCSI(_ bytes: Data, parameterStart: Data.Index, end: Data.Index) -> CSIClass {
        var j = parameterStart
        let hasPrivateMarker = j < end && (0x3C...0x3F).contains(bytes[j]) // < = > ?
        while j < end {
            let c = bytes[j]
            if (0x40...0x7E).contains(c) {
                let next = bytes.index(after: j)
                if hasPrivateMarker { return .report(resumeAt: next) }
                switch c {
                case UInt8(ascii: "M"):
                    // Bare `CSI M` (no parameters consumed) is X10/UTF-8 mouse: three position
                    // bytes ride BEHIND the final byte and are not part of any grammar this
                    // scanner would otherwise skip — leaving them would re-enter the loop on a
                    // raw `Cb` byte and read it as a keystroke. A parameterised `CSI …M` is the
                    // urxvt (1015) mouse form, which carries its position in the parameters.
                    guard j == parameterStart else { return .report(resumeAt: next) }
                    guard let past = bytes.index(next, offsetBy: 3, limitedBy: end) else { return .truncated }
                    return .report(resumeAt: past)
                case UInt8(ascii: "R"),
                     UInt8(ascii: "c"),
                     UInt8(ascii: "I"),
                     UInt8(ascii: "O"),
                     UInt8(ascii: "n"),
                     UInt8(ascii: "t"),
                     UInt8(ascii: "y"):
                    return .report(resumeAt: next)
                case UInt8(ascii: "u"):
                    // kitty keyboard protocol (`CSI <keycode>[;<mods>] u`), which Claude Code turns
                    // on. Under it the Esc KEY stops arriving as a bare `0x1B` and becomes
                    // `CSI 27 u` — so without this branch the Esc-cancel unblock, the whole reason
                    // the cancel predicate exists, would never fire inside a claude pane.
                    let code = firstParameter(bytes, from: parameterStart, to: j)
                    return .keystroke(resumeAt: next, isCancel: code == 27)
                default:
                    return .keystroke(resumeAt: next, isCancel: false)
                }
            }
            // Parameter / intermediate bytes; anything outside 0x20–0x3F is a malformed
            // sequence — treat like a truncation (conservative no).
            guard (0x20...0x3F).contains(c) else { return .truncated }
            j = bytes.index(after: j)
        }
        return .truncated
    }

    /// The leading DECIMAL parameter of a CSI sequence (the bytes between `from` and the first `;`
    /// or the final byte at `to`), or `nil` when it is absent / non-numeric / absurdly long. Used
    /// only to read a kitty key code; bounded by construction, so no overflow path exists.
    private static func firstParameter(_ bytes: Data, from: Data.Index, to: Data.Index) -> Int? {
        var value = 0
        var digits = 0
        var j = from
        while j < to, bytes[j] != UInt8(ascii: ";") {
            let c = bytes[j]
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c), digits < 6 else { return nil }
            value = value * 10 + Int(c - UInt8(ascii: "0"))
            digits += 1
            j = bytes.index(after: j)
        }
        return digits > 0 ? value : nil
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
