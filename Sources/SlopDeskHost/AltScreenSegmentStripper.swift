import Foundation

// MARK: - AltScreenSegmentStripper (replay hygiene: closed TUI screens contribute nothing)

/// Removes CLOSED alternate-screen segments (`?1049h … ?1049l`, plus the `?47`/`?1047` variants)
/// from a scrollback REPLAY stream.
///
/// ## Why
/// A TUI's alt-screen drawing is meaningless as replayed scrollback: `?1049l` discards the alt
/// screen and restores the main screen, so a segment that CLOSED contributes zero cells to the
/// final display. What it does contribute is cost — a long `vim` session records tens of MiB of
/// cursor-relative redraw churn, and a cold reattach replays every byte of it through the wire
/// and the client terminal: seconds of the pane visibly "stuck inside vim" re-rendering stale
/// frames at the recording-time geometry (the field screenshot behind this type), plus a wide
/// window for the transient-arming leaks the other strippers exist to close.
///
/// A segment still OPEN at end-of-stream is the live TUI's visible screen — it is kept verbatim
/// (entering the alt screen included), because replaying it is exactly how the reattaching client
/// repaints a still-running `vim`.
///
/// ## Semantics
/// - A DECSET whose params include 47/1047/1049 OPENS a segment; the matching DECRST CLOSES it.
///   Both ends and the interior are dropped for a closed segment. Mixed-param CSIs keep their
///   non-alt params (`?1049;12h` → `?12h`, emitted outside the drop).
/// - An alt-DECSET while already inside a segment is interior (dropped with it); an alt-DECRST
///   with no open segment passes through (defensive resets are real, keep them).
/// - String-sequence bodies (OSC/DCS/SOS/PM/APC) are skipped opaquely — an embedded `?1049l`
///   in a DCS body must not close a segment.
/// - Title changes and queries inside a dropped segment vanish with it — titles are re-asserted
///   by the type-21 control truth on reattach, queries would be stripped later anyway.
///
/// ## Where it runs
/// ONLY on the replay-side transform (``ScrollbackReplayTransform``), after
/// ``TerminalInputModeStripper`` (which needs the raw stream for net-state order, and normalizes
/// the mixed-param DECSETs it tracks) and before the distiller (which then scans megabytes less).
/// The un-acked live tail is NEVER touched (byte-exact resume).
///
/// PURE + `nonisolated`, mirroring the sibling strippers ("mirror, don't share").
enum AltScreenSegmentStripper {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// DEC private modes that switch to the alternate screen (mirrors ``TerminalModeTracker``).
    static let altModes: Set<Int> = [47, 1047, 1049]

    /// Returns `data` with closed alt-screen segments removed. A truncated trailing sequence
    /// passes through unchanged (mirrors the sibling strippers).
    static func strip(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        let n = bytes.count
        // Start offset of the currently OPEN segment (its opening CSI included), nil when on
        // the main screen. While open, nothing is emitted — on close the whole range is
        // dropped; at end-of-stream the range is flushed verbatim (live TUI).
        var openSegmentStart: Int?

        func emit(_ range: Range<Int>) {
            if openSegmentStart == nil { out.append(contentsOf: bytes[range]) }
        }

        while i < n {
            let b = bytes[i]
            guard b == esc, i + 1 < n else {
                emit(i..<(i + 1))
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["): // CSI
                guard let seq = parseCSI(bytes, at: i) else {
                    // Truncated trailing CSI — passthrough (or swallow into an open segment).
                    emit(i..<n)
                    i = n
                    continue
                }
                if let transition = altTransition(seq) {
                    switch transition {
                    case .enter:
                        if openSegmentStart == nil {
                            openSegmentStart = i
                            // Non-alt params of the opening CSI survive OUTSIDE the segment.
                            if let rewritten = rewriteDroppingAltParams(seq) {
                                out.append(rewritten)
                            }
                        }
                    // An alt-enter while already open is interior — dropped with the segment.
                    case .leave:
                        if openSegmentStart != nil {
                            openSegmentStart = nil // drop [start, seq.end) — nothing was emitted
                            if let rewritten = rewriteDroppingAltParams(seq) {
                                out.append(rewritten)
                            }
                        } else {
                            emit(i..<seq.end) // defensive reset on the main screen — keep
                        }
                    }
                } else {
                    emit(i..<seq.end)
                }
                i = seq.end
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                let belTerminates = bytes[i + 1] == UInt8(ascii: "]")
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: belTerminates) else {
                    emit(i..<n)
                    i = n
                    continue
                }
                emit(i..<end)
                i = end
            default:
                emit(i..<Swift.min(i + 2, n))
                i += 2
            }
        }
        // End-of-stream inside an OPEN segment: the live TUI's screen — flush verbatim.
        if let start = openSegmentStart {
            out.append(contentsOf: bytes[start...])
        }
        return out
    }

    // MARK: CSI

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

    private enum Transition {
        case enter
        case leave
    }

    /// `.enter`/`.leave` when the CSI is a DECSET/DECRST whose params include an alt-screen mode.
    private static func altTransition(_ seq: CSISequence) -> Transition? {
        guard seq.intermediates.isEmpty,
              seq.final == UInt8(ascii: "h") || seq.final == UInt8(ascii: "l"),
              seq.params.first == UInt8(ascii: "?")
        else { return nil }
        for field in paramFields(seq) where altModes.contains(field) {
            return seq.final == UInt8(ascii: "h") ? .enter : .leave
        }
        return nil
    }

    /// The CSI minus its alt-screen params (`?1049;12h` → `?12h`), or nil when nothing remains.
    private static func rewriteDroppingAltParams(_ seq: CSISequence) -> Data? {
        // Same lossy split discipline as the sibling strippers.
        // swiftlint:disable:next optional_data_string_conversion
        let kept = String(decoding: seq.params.dropFirst(), as: UTF8.self)
            .split(separator: ";")
            .filter { Int($0).map { !altModes.contains($0) } ?? true }
        guard !kept.isEmpty else { return nil }
        let final = Character(UnicodeScalar(seq.final))
        return Data("\u{1B}[?\(kept.joined(separator: ";"))\(final)".utf8)
    }

    private static func paramFields(_ seq: CSISequence) -> [Int] {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: seq.params.dropFirst(), as: UTF8.self)
            .split(separator: ";")
            .compactMap { Int($0) }
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
