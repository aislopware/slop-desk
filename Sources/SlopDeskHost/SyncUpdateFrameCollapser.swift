import Foundation

// MARK: - SyncUpdateFrameCollapser (replay hygiene: static sync repaints contribute nothing)

/// Drops synchronized-output frames (`?2026h … ?2026l`) that repaint the viewport WITHOUT
/// moving any content into history, from a scrollback REPLAY stream.
///
/// ## Why
/// An inline (non-alt-screen) TUI — Claude Code is the canonical tenant — redraws its live
/// widget region tens of times per second, each repaint wrapped in a synchronized-output
/// frame and anchored with absolute cursor positioning. Recorded over hours, that is
/// megabytes of spinner ticks and widget churn whose every intermediate state is invisible
/// in the final display; replaying it renders seconds of stale frames at the RECORDING-time
/// geometry (a different pane size shreds the absolute positioning — the "reconnect while
/// Claude Code runs → broken pane" field report). ``AltScreenSegmentStripper`` cannot help:
/// these TUIs never enter the alt screen, and the churn lives inside an OPEN command span
/// the distiller passes verbatim.
///
/// ## What survives
/// A frame is KEPT when it does anything besides repaint in place:
/// - scrolls content into history: LF/VT/FF, `ESC D` (IND), `ESC E` (NEL), `CSI S`/`CSI T`,
///   or the frame is where transcript lines leave the widget region;
/// - `ESC M` (RI), `CSI 2J`/`3J`, `CSI r` (DECSTBM), `ESC c` — viewport-global effects a
///   later frame may depend on;
/// - enters/leaves the alt screen (47/1047/1049) — ``AltScreenSegmentStripper`` segmentation
///   and the live TUI's screen switch must survive;
/// - carries an OSC `133;` mark — the distiller's block structure must not lose marks;
/// - is the LAST frame of the stream (terminated or not) — the newest recorded widget state,
///   the closest thing to "current" until the post-reattach SIGWINCH repaint lands;
/// - has non-`2026` params on its own opener/closer (never drop a piggybacked mode change).
///
/// Known accepted gap: a frame that scrolls ONLY via autowrap at the last column (no explicit
/// LF) is indistinguishable without a grid emulator and would be dropped; sync-frame TUIs
/// disable autowrap inside frames (Claude Code emits `?7l` per frame), so this stays theoretical.
///
/// ## Where it runs
/// ONLY on the replay-side transform (``ScrollbackReplayTransform``), after
/// ``AltScreenSegmentStripper`` (closed alt-screen segments are already gone — this pass then
/// only chews inline churn and the live open segment) and before the distiller (megabytes less
/// to scan). Final terminal STATE is unaffected: dropped frames are strictly interior repaints,
/// every kept frame re-anchors itself (sync-frame TUIs draw each frame self-contained), and the
/// stream-final input modes are re-asserted by ``TerminalInputModeStripper``'s net-state pass.
///
/// PURE + `nonisolated`, mirroring the sibling strippers ("mirror, don't share").
enum SyncUpdateFrameCollapser {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// The synchronized-output DEC private mode (mode 2026).
    static let syncMode = 2026

    /// DEC private modes whose transitions must never vanish with a dropped frame (mirrors
    /// ``AltScreenSegmentStripper/altModes``).
    private static let altModes: Set<Int> = [47, 1047, 1049]

    /// Returns `data` with static (non-scrolling) synchronized-output frames removed. A
    /// truncated trailing sequence passes through unchanged (mirrors the sibling strippers).
    static func collapse(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let n = bytes.count
        // Segment pass: record each frame's range + verdict, emit everything else verbatim.
        // Two-phase (ranges first, bytes second) so the LAST frame can be kept regardless of
        // its own verdict without pre-scanning for it.
        var frames: [Frame] = []
        var i = 0
        while i < n {
            guard bytes[i] == esc, i + 1 < n else {
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["):
                guard let seq = parseCSI(bytes, at: i) else {
                    i = n // truncated trailing CSI — passthrough
                    continue
                }
                if syncTransition(seq) == .begin {
                    let frame = scanFrame(bytes, opener: seq)
                    frames.append(Frame(range: i..<frame.end, droppable: frame.droppable))
                    i = frame.end
                } else {
                    i = seq.end
                }
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                // Skip string bodies opaquely — an embedded `?2026h` must not open a frame.
                let belTerminates = bytes[i + 1] == UInt8(ascii: "]")
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: belTerminates) else {
                    i = n
                    continue
                }
                i = end
            default:
                i += 2
            }
        }
        guard frames.contains(where: \.droppable) else { return data }
        var out = Data(capacity: n)
        var cursor = 0
        for (index, frame) in frames.enumerated() {
            out.append(contentsOf: bytes[cursor..<frame.range.lowerBound])
            // The last frame is always kept: it is the newest recorded widget state.
            if !frame.droppable || index == frames.count - 1 {
                out.append(contentsOf: bytes[frame.range])
            }
            cursor = frame.range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return out
    }

    // MARK: Frame scan

    /// One synchronized-output frame: its byte range (markers inclusive) and drop verdict.
    private struct Frame {
        let range: Range<Int>
        let droppable: Bool
    }

    /// Scans one frame from its opener to the matching `?2026l` (or end-of-stream), deciding
    /// whether it may be dropped. An UNTERMINATED frame (live repaint in progress at the cut
    /// point) is never droppable.
    private static func scanFrame(
        _ bytes: [UInt8], opener: CSISequence,
    ) -> (end: Int, droppable: Bool) {
        let n = bytes.count
        // A piggybacked param on the opener (`?2026;…h`) must survive — keep the whole frame.
        var keep = paramFields(opener) != [syncMode]
        var j = opener.end
        while j < n {
            let b = bytes[j]
            if b == 0x0A || b == 0x0B || b == 0x0C {
                keep = true
                j += 1
                continue
            }
            guard b == esc, j + 1 < n else {
                j += 1
                continue
            }
            switch bytes[j + 1] {
            case UInt8(ascii: "["):
                guard let seq = parseCSI(bytes, at: j) else {
                    return (n, false) // truncated trailing CSI inside the frame — passthrough
                }
                if syncTransition(seq) == .end {
                    if paramFields(seq) != [syncMode] { keep = true }
                    return (seq.end, !keep)
                }
                if mustKeep(seq) { keep = true }
                j = seq.end
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                let belTerminates = bytes[j + 1] == UInt8(ascii: "]")
                // A semantic prompt mark inside the frame anchors the distiller — keep.
                if belTerminates, matchesOSC133(bytes, bodyStart: j + 2) { keep = true }
                guard let end = stringSequenceEnd(bytes, bodyStart: j + 2, belTerminates: belTerminates) else {
                    return (n, false) // unterminated string body — the frame is still being drawn
                }
                j = end
            case UInt8(ascii: "D"),
                 UInt8(ascii: "E"),
                 UInt8(ascii: "M"),
                 UInt8(ascii: "c"):
                // IND/NEL scroll at the bottom margin, RI at the top, RIS resets everything.
                keep = true
                j += 2
            default:
                j += 2
            }
        }
        return (n, false) // no closer — the live TUI's in-flight frame, keep verbatim
    }

    /// CSIs inside a frame that force the frame to survive (effects a later frame or the final
    /// display may depend on — see the type doc).
    private static func mustKeep(_ seq: CSISequence) -> Bool {
        guard seq.intermediates.isEmpty else { return false }
        switch seq.final {
        case UInt8(ascii: "S"),
             UInt8(ascii: "T"):
            return true // scroll up/down — content crosses the history boundary
        case UInt8(ascii: "J"):
            // ED 2 (full viewport) / 3 (scrollback erase); plain/0/1 are the churn itself.
            return paramFields(seq).contains { $0 == 2 || $0 == 3 }
        case UInt8(ascii: "r"):
            return true // DECSTBM — scroll-region geometry later frames rely on
        case UInt8(ascii: "h"),
             UInt8(ascii: "l"):
            guard seq.params.first == UInt8(ascii: "?") else { return false }
            return paramFields(seq).contains(where: altModes.contains)
        default:
            return false
        }
    }

    // MARK: CSI (mirrors AltScreenSegmentStripper — "mirror, don't share")

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

    private enum SyncTransition {
        case begin
        case end
    }

    /// `.begin`/`.end` when the CSI is a DECSET/DECRST whose params include mode 2026.
    private static func syncTransition(_ seq: CSISequence) -> SyncTransition? {
        guard seq.intermediates.isEmpty,
              seq.final == UInt8(ascii: "h") || seq.final == UInt8(ascii: "l"),
              seq.params.first == UInt8(ascii: "?")
        else { return nil }
        guard paramFields(seq).contains(syncMode) else { return nil }
        return seq.final == UInt8(ascii: "h") ? .begin : .end
    }

    private static func paramFields(_ seq: CSISequence) -> [Int] {
        // Unlike the alt-screen sibling this parses NON-private CSIs too (`2J`), so the
        // leading byte is dropped only when it is the `?` private marker.
        let params = seq.params.first == UInt8(ascii: "?") ? seq.params.dropFirst() : seq.params
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: params, as: UTF8.self)
            .split(separator: ";")
            .compactMap { Int($0) }
    }

    /// Whether an OSC body starting at `bodyStart` is a semantic prompt mark (`133;…`).
    private static func matchesOSC133(_ bytes: [UInt8], bodyStart: Int) -> Bool {
        let mark: [UInt8] = [UInt8(ascii: "1"), UInt8(ascii: "3"), UInt8(ascii: "3"), UInt8(ascii: ";")]
        guard bodyStart + mark.count <= bytes.count else { return false }
        return Array(bytes[bodyStart..<bodyStart + mark.count]) == mark
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
