import Foundation

// MARK: - AltScreenCutScanner (front-truncation vs alt-screen segments)

/// Exact alternate-screen state at a front-truncation CUT of a terminal byte stream, and the
/// DECSET that re-opens the segment the cut beheaded.
///
/// ## Why
/// Both scrollback retainers cut their stream from the FRONT when it outgrows the cap: the
/// in-memory ring (``ReplayBuffer/ack(upTo:)`` eviction) and the on-disk journal
/// (`ScrollbackJournal.compact`). A cut that lands INSIDE an open alt-screen segment
/// (`?1049h … ?1049l` — a Claude Code session holds one open for its whole run) beheads it:
/// the surviving stream starts with segment interior and ends it with an UNPAIRED `?1049l`.
/// Replay-side segmentation (`AltScreenSegmentStripper`) rightly treats an unpaired leave as a
/// defensive reset and passes everything through — so tens of MiB of full-screen TUI churn
/// replays onto the MAIN screen and floods the client's scrollback.
///
/// "Drop the prefix up to the unpaired leave" is NOT a safe heuristic: apps emit redundant
/// `?1049l` while already on the main screen (Claude's exit cleanup does), and that would eat
/// real history. This scanner removes the guess: the evictor feeds it the exact bytes being
/// dropped, and the net DECSET/DECRST state says whether the cut is inside a segment.
///
/// ## Repair invariant — the state lives IN the bytes
/// When the cut is inside a segment, the evictor PREPENDS the returned re-opener to the
/// surviving head (ring entry / file tail). The surviving stream is then well-formed again, so
/// the NEXT eviction's scan — which starts from that repaired head — needs no carried state.
/// For the journal the repair is on disk, so the invariant survives the daemon.
///
/// ## Semantics (mirrors `AltScreenSegmentStripper` — "mirror, don't share" is deliberately
/// broken here: host AND transport need this one, so it lives in the lower module)
/// - DECSET/DECRST with any of 47/1047/1049 flips the state; the re-opener uses the SAME mode
///   that last entered (a `?47h` app must not be re-opened with 1049's save/clear semantics).
/// - String-sequence bodies (OSC/DCS/SOS/PM/APC) are opaque — an embedded `?1049h` is body
///   text. A body still open at the end of the dropped prefix cannot contain transitions, so
///   the state at the cut is the state at the body's start.
/// - A CSI that STRADDLES the cut (starts in the dropped prefix, finishes in the kept head) is
///   resolved by peeking a bounded slice of the kept head; sequences that START in the kept
///   head belong to the surviving stream and are never applied.
public enum AltScreenCutScanner {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// DEC private modes that switch to the alternate screen.
    static let altModes: Set<Int> = [47, 1047, 1049]

    /// Bounded kept-head peek: enough to finish any realistic straddling CSI (params + final).
    private static let straddlePeekBytes = 64

    /// Scans `dropped` (the bytes being evicted from the front of a scrollback stream) and
    /// returns the DECSET to prepend to the surviving tail when the cut lands inside an open
    /// alt-screen segment (e.g. `ESC [ ? 1049 h`), else `nil`.
    ///
    /// - Parameter keptHead: the first bytes of the SURVIVING stream, used only to resolve a
    ///   sequence straddling the cut. Pass what is cheap; missing bytes degrade to "straddler
    ///   unresolved → state unchanged", never to a wrong transition.
    public static func reopenSequence(afterDropped dropped: Data, keptHead: Data) -> Data? {
        var bytes = [UInt8](dropped)
        let boundary = bytes.count
        bytes.append(contentsOf: keptHead.prefix(straddlePeekBytes))
        var inAlt = false
        var enterMode = 1049
        var i = 0
        // Only sequences STARTING inside the dropped prefix are applied; one straddler may
        // finish in the peek region, after which `i >= boundary` ends the scan.
        while i < boundary {
            let b = bytes[i]
            guard b == esc, i + 1 < bytes.count else {
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["): // CSI
                guard let seq = parseCSI(bytes, at: i) else {
                    i = bytes.count // truncated trailing CSI — unresolvable, state as-is
                    continue
                }
                if let altParam = altTransitionParam(seq) {
                    inAlt = seq.final == UInt8(ascii: "h")
                    if inAlt { enterMode = altParam }
                }
                i = seq.end
            case UInt8(ascii: "]"),
                 UInt8(ascii: "P"),
                 UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"):
                let belTerminates = bytes[i + 1] == UInt8(ascii: "]")
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: belTerminates)
                else {
                    i = bytes.count // cut inside the body — no transitions possible past here
                    continue
                }
                i = end
            default:
                i += 2
            }
        }
        guard inAlt else { return nil }
        return Data("\u{1B}[?\(enterMode)h".utf8)
    }

    // MARK: CSI

    private struct CSISequence {
        let params: ArraySlice<UInt8>
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
        // Intermediates present ⇒ not a DECSET/DECRST; params still parsed for uniform skipping.
        let final = intersStart == j ? bytes[j] : 0
        return CSISequence(params: bytes[paramsStart..<intersStart], final: final, end: j + 1)
    }

    /// The alt-screen mode when the CSI is a DECSET/DECRST whose params include one, else nil.
    private static func altTransitionParam(_ seq: CSISequence) -> Int? {
        guard seq.final == UInt8(ascii: "h") || seq.final == UInt8(ascii: "l"),
              seq.params.first == UInt8(ascii: "?")
        else { return nil }
        // Same lossy split discipline as the stripper siblings.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: seq.params.dropFirst(), as: UTF8.self)
            .split(separator: ";")
            .compactMap { Int($0) }
            .first { altModes.contains($0) }
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
