import Foundation

// MARK: - SyncInputByteFilter (keyboard-only mirror hygiene for the sync-input fan-out)

/// Strips the NON-KEYBOARD sequences out of an input chunk before ``WorkspaceStore/fanSyncInput(from:_:)``
/// mirrors it into sibling panes.
///
/// ## Why
/// The sync-input tap rides ``TerminalViewModel/sendInput(_:)`` — the pane's single OUT funnel — which
/// carries MORE than keystrokes: the terminal emulator answers its shell's queries (CPR `ESC[row;colR`,
/// DA `ESC[?…c`, XTWINOPS `ESC[8;…t`, DECRPM `ESC[?…$y`, kitty-flags `ESC[?…u`, OSC color/clipboard
/// replies, DCS `XTGETTCAP` replies) and streams mouse reports (`ESC[<…M/m`, `ESC[M…`) and focus events
/// (`ESC[I`/`ESC[O`) through the same path. Those bytes are answers to questions only the SOURCE pane's
/// shell asked; mirrored into a sibling shell that never asked, they type garbage onto its command line —
/// and the next mirrored `↩` EXECUTES it (observed in the field: a scroll burst + a window report ran as
/// a command in the sibling).
///
/// ## What survives
/// Everything a keyboard or paste actually produces: plain bytes/UTF-8, control bytes, `ESC`-prefixed
/// keys (SS3 `ESC O …`, CSI arrows/nav/`~`-keys, kitty `CSI code;mods u` — the non-private form),
/// bracketed-paste wrappers + body (`type once, run everywhere` covers paste).
///
/// Known accepted gap: a MODIFIED F3 (`ESC[1;mR`) is byte-identical to a cursor-position report and is
/// dropped from the MIRROR (the source pane still receives it); plain F3 (`ESC O R`) is unaffected.
///
/// A TRUNCATED trailing sequence passes through verbatim — input arrives one whole key/reply event per
/// chunk, so a split sequence is not a real shape and passthrough is the least surprising fallback
/// (mirrors the replay strippers' convention). PURE + `nonisolated`.
public enum SyncInputByteFilter {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// Returns `data` with terminal-reply and mouse/focus-report sequences removed.
    public static func keyboardOnly(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let n = bytes.count
        var out = Data(capacity: n)
        var i = 0
        while i < n {
            guard bytes[i] == esc, i + 1 < n else {
                out.append(bytes[i])
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["):
                guard let seq = parseCSI(bytes, at: i) else {
                    // Truncated trailing CSI — passthrough verbatim.
                    out.append(contentsOf: bytes[i...])
                    i = n
                    continue
                }
                if isReplyOrReport(seq) {
                    i = seq.end
                    // X10 mouse: `ESC [ M` is followed by 3 raw payload bytes (button, x, y) that
                    // are NOT CSI params (coords exceed 0x3F) — consume them with the report.
                    if seq.final == UInt8(ascii: "M"), seq.params.isEmpty, seq.intermediates.isEmpty {
                        i = min(i + 3, n)
                    }
                } else {
                    out.append(contentsOf: bytes[i..<seq.end])
                    i = seq.end
                }
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                // OSC / DCS / SOS / PM / APC in the INPUT direction are always replies (color queries,
                // OSC 52 clipboard, XTGETTCAP) — never keystrokes. Drop the whole string body.
                let belTerminates = bytes[i + 1] == UInt8(ascii: "]")
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: belTerminates) else {
                    out.append(contentsOf: bytes[i...]) // truncated — passthrough
                    i = n
                    continue
                }
                i = end
            default:
                // Two-byte escapes (SS3 keys `ESC O …`, meta-prefixed chars) are keyboard — keep.
                out.append(bytes[i])
                out.append(bytes[i + 1])
                i += 2
            }
        }
        return out
    }

    // MARK: CSI classification

    /// Whether a CSI arriving on the INPUT path is a terminal reply or a mouse/focus report — never
    /// something a keyboard produces.
    private static func isReplyOrReport(_ seq: CSISequence) -> Bool {
        let isPrivate = seq.params.first.map { (0x3C...0x3F).contains($0) } ?? false // < = > ?
        switch seq.final {
        case UInt8(ascii: "M"),
             UInt8(ascii: "m"):
            // SGR mouse (`ESC[<…M/m`) or X10 mouse (`ESC[M` + 3 payload bytes). A plain `m` without
            // the `<` marker is not an input-direction shape either, but keep the check tight: only
            // the `<`-marked SGR form and the bare-`M` X10 form are reports.
            if seq.params.first == UInt8(ascii: "<") { return true }
            return seq.final == UInt8(ascii: "M") && seq.params.isEmpty && seq.intermediates.isEmpty
        case UInt8(ascii: "R"):
            // CPR `ESC[row;colR`. Accepted gap: modified F3 shares the shape (see type doc).
            return !seq.params.isEmpty
        case UInt8(ascii: "n"),
             UInt8(ascii: "c"),
             UInt8(ascii: "t"),
             UInt8(ascii: "y"):
            // DSR status (`0n`/`3n`), DA1/DA2 (`?…c`/`>…c`), XTWINOPS (`8;…t`), DECRPM (`?…$y`).
            // No keyboard encoding uses these finals.
            return true
        case UInt8(ascii: "I"),
             UInt8(ascii: "O"):
            // Focus in/out — exactly `ESC[I` / `ESC[O`, no params.
            return seq.params.isEmpty && seq.intermediates.isEmpty
        case UInt8(ascii: "u"):
            // Kitty keyboard-flags REPLY is the private `ESC[?flags u`; the non-private
            // `CSI code;mods u` is a KEYSTROKE and must survive.
            return isPrivate
        default:
            return false
        }
    }

    // MARK: CSI parse (mirrors the replay strippers — "mirror, don't share")

    private struct CSISequence {
        let params: ArraySlice<UInt8>
        let intermediates: ArraySlice<UInt8>
        let final: UInt8
        let end: Int
    }

    private static func parseCSI(_ bytes: [UInt8], at start: Int) -> CSISequence? {
        var j = start + 2
        let paramsStart = j
        while j < bytes.count, (0x30...0x3F).contains(bytes[j]) {
            j += 1
        }
        let intersStart = j
        while j < bytes.count, (0x20...0x2F).contains(bytes[j]) {
            j += 1
        }
        guard j < bytes.count, (0x40...0x7E).contains(bytes[j]) else { return nil }
        return CSISequence(
            params: bytes[paramsStart..<intersStart],
            intermediates: bytes[intersStart..<j],
            final: bytes[j],
            end: j + 1,
        )
    }

    private static func stringSequenceEnd(_ bytes: [UInt8], bodyStart: Int, belTerminates: Bool) -> Int? {
        var j = bodyStart
        while j < bytes.count {
            if belTerminates, bytes[j] == bel { return j + 1 }
            if bytes[j] == esc, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") {
                return j + 2
            }
            j += 1
        }
        return nil
    }
}
