import Foundation

// MARK: - TerminalQueryStripper (replay hygiene: no re-answered queries, no stale color state)

/// Strips terminal QUERY sequences (and their echoed responses) from a scrollback REPLAY stream.
///
/// ## Why
/// The scrollback ring / disk journal record the raw host→client bytes — including the queries a
/// prompt or shell integration sent in the ORIGINAL session (DA1 `CSI c`, XTVERSION `CSI > q`,
/// DECRQM `CSI ? 2026 $ p`, OSC `11;?` background-color probe…). Those queries were answered live,
/// once. Replaying them into the client terminal makes it answer AGAIN: the fresh responses ride
/// the wire back as PTY *input*, and with the foreground process not reading them (`sleep`, a
/// TUI…) they spill onto the command line as garbage
/// (`^[]11;rgb:…^G^[[?62;22;52c^[P>|ghostty…^[\`) — the reattach bug this type fixes. Echoed
/// RESPONSE forms already polluting a recorded transcript are stripped too, so an
/// already-poisoned journal renders clean on its next restore.
///
/// Color-state OSC (10/11/12/17/19, palette 4/104…, and clipboard 52) is stripped in BOTH query
/// and set form: stale color/clipboard state must never ride a history replay into a fresh
/// terminal — the live shell re-asserts what it needs.
///
/// ## Where it runs
/// ONLY on the replay-side transforms — ``ReplayBuffer``'s cold-reattach scrollback-ring pass and
/// ``ScrollbackJournalStore/restoredScrollback(for:)`` — composed after ``ScrollbackDistiller``
/// by ``ScrollbackReplayTransform/make(environment:)``. The un-acked live tail is NEVER touched:
/// a query in the tail was never delivered, so its issuer may legitimately still await the answer
/// (byte-exact resume). Stored bytes stay raw (a stripper improvement retroactively benefits
/// existing journals).
///
/// PURE + `nonisolated`, mirroring ``ScrollbackDistiller``'s string-sequence handling (the
/// codebase's "mirror, don't share" convention for these small VT machines).
enum TerminalQueryStripper {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// Returns `data` with query/response/color-state sequences removed (see type docs).
    /// Everything else — text, SGR, modes (`h`/`l`), OSC titles/marks/hyperlinks, DECSCUSR —
    /// passes through verbatim. A truncated trailing sequence passes through unchanged (a ring
    /// head-cut artifact is display noise, never a replayable query).
    static func strip(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        let n = bytes.count

        while i < n {
            let b = bytes[i]
            guard b == esc, i + 1 < n else {
                out.append(b)
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["): // CSI
                guard let seq = parseCSI(bytes, at: i) else {
                    out.append(contentsOf: bytes[i...]) // truncated — passthrough
                    i = n
                    continue
                }
                if !shouldStripCSI(params: seq.params, intermediates: seq.intermediates, final: seq.final) {
                    out.append(contentsOf: bytes[i..<seq.end])
                }
                i = seq.end
            case UInt8(ascii: "]"): // OSC
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: true) else {
                    out.append(contentsOf: bytes[i...])
                    i = n
                    continue
                }
                if !shouldStripOSC(body: bytes[(i + 2)..<end.bodyEnd]) {
                    out.append(contentsOf: bytes[i..<end.seqEnd])
                }
                i = end.seqEnd
            case UInt8(ascii: "P"): // DCS
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: false) else {
                    out.append(contentsOf: bytes[i...])
                    i = n
                    continue
                }
                if !shouldStripDCS(body: bytes[(i + 2)..<end.bodyEnd]) {
                    out.append(contentsOf: bytes[i..<end.seqEnd])
                }
                i = end.seqEnd
            case UInt8(ascii: "X"),
                 UInt8(ascii: "^"),
                 UInt8(ascii: "_"): // SOS/PM/APC — keep whole
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: false) else {
                    out.append(contentsOf: bytes[i...])
                    i = n
                    continue
                }
                out.append(contentsOf: bytes[i..<end.seqEnd])
                i = end.seqEnd
            case UInt8(ascii: "Z"): // DECID — the ancient DA query
                i += 2
            default: // any other ESC pair — keep
                out.append(contentsOf: bytes[i...(i + 1)])
                i += 2
            }
        }
        return out
    }

    // MARK: CSI

    /// Slices into the shared scan buffer (no per-CSI array allocs — this runs for EVERY CSI over
    /// multi-hundred-MiB cold-reattach/journal blobs, and SGR-final `m` dominates).
    private struct CSISequence {
        let params: ArraySlice<UInt8> // 0x30–0x3F (digits ; : < = > ?)
        let intermediates: ArraySlice<UInt8> // 0x20–0x2F
        let final: UInt8 // 0x40–0x7E
        let end: Int // index just past the final byte
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

    /// Window-op report requests (`CSI Ps t` with these leading params) — the terminal replies
    /// with geometry/title reports. 22/23 (title push/pop) and 8 (resize) are NOT reports → kept.
    private static let windowReportOps: Set<String> = ["11", "13", "14", "15", "16", "18", "19", "20", "21"]

    /// All work is per-branch and byte-wise (params/intermediates are always ASCII by the parseCSI
    /// byte ranges): the overwhelmingly common SGR final `m` falls straight to `false` without
    /// building a String or scanning intermediates — the hot path over huge replay blobs.
    private static func shouldStripCSI(
        params: ArraySlice<UInt8>, intermediates: ArraySlice<UInt8>, final: UInt8,
    ) -> Bool {
        switch final {
        case UInt8(ascii: "c"): // DA1/DA2/DA3 query — and the `?`-prefixed echoed DA response
            return true
        case UInt8(ascii: "n"): // DSR/CPR requests (5n/6n/?6n…) and DSR responses (0n/3n)
            return true
        case UInt8(ascii: "R"): // echoed CPR response (`CSI row;col R`)
            return true
        case UInt8(ascii: "x"): // DECREQTPARM query + its `x`-final response
            return intermediates.isEmpty
        case UInt8(ascii: "p"): // DECRQM query (`$` intermediate); keep DECSTR `!p` etc.
            return intermediates.contains(UInt8(ascii: "$"))
        case UInt8(ascii: "y"): // echoed DECRPM response (`$` intermediate); keep DECTST
            return intermediates.contains(UInt8(ascii: "$"))
        case UInt8(ascii: "q"): // XTVERSION `CSI > Ps q`; keep DECSCUSR `SP q` / DECSCA `" q`
            return intermediates.isEmpty && params.first == UInt8(ascii: ">")
        case UInt8(ascii: "u"): // kitty keyboard-flags query `CSI ? u`; keep push/pop/restore
            return params.first == UInt8(ascii: "?")
        case UInt8(ascii: "t"): // window-op REPORT requests only
            let first = params.prefix(while: { $0 != UInt8(ascii: ";") })
            return windowReportOps.contains(String(bytes: first, encoding: .utf8) ?? "")
        default:
            return false
        }
    }

    // MARK: OSC / DCS

    /// OSC numbers whose query AND set forms are stripped from replay: dynamic colors
    /// (10/11/12/17/19 + resets 110/111/112), palette (4/5/104/105), clipboard (52), and the
    /// kitty color protocol (21 — a live `key=?` query/response OSC in ghostty, same shape and
    /// PTY-input delivery mechanism as 10/11/12).
    private static let strippedOSCNumbers: Set<String> =
        ["4", "5", "10", "11", "12", "17", "19", "21", "52", "104", "105", "110", "111", "112"]

    private static func shouldStripOSC(body: ArraySlice<UInt8>) -> Bool {
        let number = body.prefix(while: { $0 != UInt8(ascii: ";") })
        return strippedOSCNumbers.contains(String(bytes: number, encoding: .utf8) ?? "")
    }

    /// DCS bodies that are queries (XTGETTCAP `+q…`, DECRQSS `$q…`), the echoed XTVERSION
    /// response (`>|…`), or the echoed DECRQSS/XTGETTCAP responses (`{0|1}$r…` / `{0|1}+r…`,
    /// ghostty's reply formats): a poisoned transcript carrying a reply would re-emit raw DCS
    /// garbage on the fresh command line. Anything else (sixel…) is kept.
    private static func shouldStripDCS(body: ArraySlice<UInt8>) -> Bool {
        let prefix = [UInt8](body.prefix(3))
        if prefix.count >= 2 {
            if prefix[0] == UInt8(ascii: "+"), prefix[1] == UInt8(ascii: "q") { return true }
            if prefix[0] == UInt8(ascii: "$"), prefix[1] == UInt8(ascii: "q") { return true }
            if prefix[0] == UInt8(ascii: ">"), prefix[1] == UInt8(ascii: "|") { return true }
        }
        if prefix.count >= 3,
           prefix[0] == UInt8(ascii: "0") || prefix[0] == UInt8(ascii: "1"),
           prefix[1] == UInt8(ascii: "$") || prefix[1] == UInt8(ascii: "+"),
           prefix[2] == UInt8(ascii: "r")
        {
            return true
        }
        // The zero-body miss responses `0$r`/`1$r`/`0+r`/`1+r` are exactly 3 bytes; longer hit
        // responses carry the payload after `r` — both are covered by the 3-byte prefix match.
        return false
    }

    /// Scans a string sequence's body from `bodyStart` to its terminator. Returns the body end
    /// (exclusive of the terminator) and the sequence end (past the terminator), or `nil` when
    /// the buffer ends unterminated. OSC accepts BEL or ST (`ESC \`); DCS/SOS/PM/APC only ST.
    private static func stringSequenceEnd(
        _ bytes: [UInt8], bodyStart: Int, belTerminates: Bool,
    ) -> (bodyEnd: Int, seqEnd: Int)? {
        var j = bodyStart
        while j < bytes.count {
            if belTerminates, bytes[j] == bel { return (j, j + 1) }
            if bytes[j] == esc, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") {
                return (j, j + 2)
            }
            j += 1
        }
        return nil
    }
}

// MARK: - ScrollbackReplayTransform (the ONE replay-side transform pipeline)

/// Builds the transform applied to replayed history — the scrollback ring's cold-reattach pass
/// (``MuxChannelSession/makeReplayBuffer()``) and the disk journal's restore
/// (``ScrollbackJournalStore``) — so both replay paths stay behaviour-identical.
///
/// Composition (all default-ON, the `!= "0"` idiom):
/// 1. `SLOPDESK_SCROLLBACK_DISTILL` — ``ScrollbackDistiller`` collapses B→C line-editor churn.
/// 2. `SLOPDESK_SCROLLBACK_STRIP_QUERIES` — ``TerminalQueryStripper`` removes terminal queries /
///    echoed responses / stale color state (the reattach "garbage input" fix).
/// 3. `SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS` — ``PromptEOLMarkStripper`` normalizes zsh PROMPT_SP
///    mark+fill clusters, whose width-dependent overprint trick surfaces stray `%` lines when
///    history is replayed at a different grid width. Runs LAST: the earlier passes only improve
///    its cluster→`133;D`/`133;A` adjacency anchor (the distiller flushes clusters buffered in a
///    B→C span; the query stripper removes interposed query OSCs).
///
/// Returns `nil` when all are disabled (raw replay — the pre-transform behaviour).
enum ScrollbackReplayTransform {
    static func make(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
    ) -> (@Sendable (Data) -> Data)? {
        let distill = env["SLOPDESK_SCROLLBACK_DISTILL"] != "0"
        let stripQueries = env["SLOPDESK_SCROLLBACK_STRIP_QUERIES"] != "0"
        let stripEOLMarks = env["SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS"] != "0"
        guard distill || stripQueries || stripEOLMarks else { return nil }
        return { @Sendable data in
            var result = data
            if distill { result = ScrollbackDistiller.distill(result) }
            if stripQueries { result = TerminalQueryStripper.strip(result) }
            if stripEOLMarks { result = PromptEOLMarkStripper.strip(result) }
            return result
        }
    }
}
