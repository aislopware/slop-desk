import Foundation

// MARK: - PromptEOLMarkStripper (replay hygiene: no width-stale zsh PROMPT_SP fills)

/// Strips zsh's PROMPT_SP end-of-line-mark clusters from a scrollback REPLAY stream.
///
/// ## Why
/// Before every prompt, zsh (PROMPT_SP + PROMPT_CR, both default-on) emits the PROMPT_EOL_MARK —
/// captured live as `\e[1m\e[7m%\e[27m\e[1m\e[0m` — followed by a `COLUMNS`-wide run of spaces and
/// a CR (plus an anti-xenl ` \r` tick). At the width it was emitted for, the fill lands exactly on
/// the wrap boundary: from column 0 the prompt overprints the mark (invisible); mid-line it wraps
/// once and leaves the mark on the partial line. The trick is WIDTH-DEPENDENT: replayed into a
/// grid narrower than the recording width (the pane was resized/split since, or history spans
/// several widths) the fill wraps for real and every prompt in the restored transcript grows a
/// stray `%` line — the stray-`%`-character bug seen on reconnect.
///
/// ## What
/// A cluster is matched ONLY when it immediately precedes the shim's `133;D` / `133;A` OSC (zsh's
/// `preprompt` runs right before the precmd hooks, so on this wire the cluster always abuts them)
/// AND the mark carries SGR wrapping on BOTH sides (`%B%S` before, the `%s%b`+reset cleanup
/// after — zsh's promptexpand always emits both on a capable TERM). The two-sided SGR requirement
/// is the false-positive guard for sessions that `unsetopt PROMPT_SP`: there the pre-anchor bytes
/// are real command output, and the ordinary "progress: 100%␣␣␣␣\r" pad-to-clear idiom must never
/// match (its `%` is plain text, not SGR-wrapped). A bare dumb-TERM mark is a deliberate MISS.
///
/// Replacement is width-independent, and always re-asserts the SGR reset the swallowed cluster
/// ended with (`…%s%b` + reset) — the match consumes every SGR abutting the mark, which can
/// include one the COMMAND wrote (e.g. its final `\e[0m`); emitting a reset reproduces the exact
/// post-cluster live state either way, so no colour can bleed into the replayed prompt:
/// - **Column 0** (the previous write ended with a newline, looked through zero-width sequences
///   like SGR / EL / DECSCUSR / OSC): the live render was invisible → the cluster becomes `\e[0m`.
/// - **Mid-line** (empty-Enter / Ctrl-C at the prompt, a genuine partial output line): the live
///   render moved the prompt to a fresh line → the cluster becomes `\e[0m` + CRLF. The partial
///   line survives verbatim; only the mark and the stale fill go.
///
/// ## Where it runs
/// ONLY on the replay-side transform (``ScrollbackReplayTransform``), after the distiller and the
/// query stripper. The live stream and the un-acked resume tail are untouched (byte-exact resume);
/// stored journal bytes stay raw, so improvements retroactively benefit existing journals.
///
/// PURE + `nonisolated`, mirroring ``TerminalQueryStripper`` (the codebase's "mirror, don't
/// share" convention for these small VT machines).
enum PromptEOLMarkStripper {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let sp: UInt8 = 0x20

    /// Minimum fill length accepted as a PROMPT_SP space run (`COLUMNS - markwidth - 1`; real
    /// terminals are ≥ 20 columns wide — 8 keeps narrow panes covered without ever matching
    /// ordinary aligned output).
    private static let minFillSpaces = 8

    /// Byte/sequence budgets for the backward column-0 classification walk (a wrong bail-out just
    /// downgrades an excision to the safe CRLF replacement, never corrupts).
    private static let zeroWidthWalkByteBudget = 4096
    private static let zeroWidthWalkSequenceBudget = 64

    /// Returns `data` with every PROMPT_SP cluster normalized (see type docs). Everything else
    /// passes through verbatim.
    static func strip(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = [UInt8](data)
        let n = bytes.count

        // (clusterStart, anchorStart, atColumnZero) — non-overlapping by construction: a cluster
        // ends at its anchor's ESC, and a backward match from the NEXT anchor stops at this
        // anchor's terminator (BEL/ST is not CR).
        var edits: [(start: Int, end: Int, columnZero: Bool)] = []

        var i = 0
        while i + 6 < n {
            // Anchor: `ESC ] 1 3 3 ;` with subcommand A or D (prompt start / command finished).
            guard bytes[i] == esc, bytes[i + 1] == UInt8(ascii: "]"),
                  bytes[i + 2] == UInt8(ascii: "1"), bytes[i + 3] == UInt8(ascii: "3"),
                  bytes[i + 4] == UInt8(ascii: "3"), bytes[i + 5] == UInt8(ascii: ";"),
                  bytes[i + 6] == UInt8(ascii: "A") || bytes[i + 6] == UInt8(ascii: "D")
            else {
                i += 1
                continue
            }
            if let start = clusterEnding(at: i, in: bytes) {
                edits.append((start, i, columnZero(before: start, in: bytes)))
            }
            i += 7
        }
        guard !edits.isEmpty else { return data }

        var out = Data(capacity: n)
        var cursor = 0
        let sgrReset: [UInt8] = [esc, UInt8(ascii: "["), UInt8(ascii: "0"), UInt8(ascii: "m")]
        for edit in edits {
            out.append(contentsOf: bytes[cursor..<edit.start])
            // Re-assert the reset the cluster's own SGR cleanup ended with — the match consumed
            // every SGR abutting the mark (possibly including one the command wrote), and the
            // live post-cluster state was reset either way (see the type docs).
            out.append(contentsOf: sgrReset)
            if !edit.columnZero {
                out.append(cr)
                out.append(lf)
            }
            cursor = edit.end
        }
        out.append(contentsOf: bytes[cursor..<n])
        return out
    }

    // MARK: Backward cluster match

    /// Matches `SGR* mark SGR* SP{≥8} CR (SP CR){0,2}` ending exactly at `anchor` (the `ESC` of
    /// the `133;D`/`133;A` OSC). Returns the cluster's start index, or `nil`.
    private static func clusterEnding(at anchor: Int, in bytes: [UInt8]) -> Int? {
        var j = anchor
        // PROMPT_CR, newest-last: an optional anti-xenl ` \r` tick (observed once; tolerate two),
        // then the mandatory CR that ends the space fill.
        guard j > 0, bytes[j - 1] == cr else { return nil }
        j -= 1
        var ticks = 0
        while ticks < 2, j >= 2, bytes[j - 1] == sp, bytes[j - 2] == cr {
            j -= 2
            ticks += 1
        }
        // The COLUMNS-wide space fill.
        let fillEnd = j
        while j > 0, bytes[j - 1] == sp {
            j -= 1
        }
        guard fillEnd - j >= minFillSpaces else { return nil }
        // SGR run after the mark (`%s%b` + reset), the mark itself (`%` — or `#` for a root
        // shell), and the SGR run before it (`%B%S`). BOTH runs must be non-empty — the
        // false-positive guard: a plain-text `%`/`#` at the end of real command output (a session
        // that `unsetopt PROMPT_SP`, followed by a pad-to-clear + CR) has no SGR wrapping, while
        // zsh's promptexpand always emits both sides on a capable TERM. A bare dumb-TERM mark is
        // a deliberate miss.
        let suffixEnd = j
        while let s = sgrStart(before: j, in: bytes) {
            j = s
        }
        guard j < suffixEnd else { return nil }
        guard j > 0, bytes[j - 1] == UInt8(ascii: "%") || bytes[j - 1] == UInt8(ascii: "#")
        else { return nil }
        j -= 1
        let prefixEnd = j
        while let s = sgrStart(before: j, in: bytes) {
            j = s
        }
        guard j < prefixEnd else { return nil }
        return j
    }

    /// Matches an SGR (`ESC [ params m`) ending exactly at `end`; returns its `ESC` index.
    private static func sgrStart(before end: Int, in bytes: [UInt8]) -> Int? {
        guard end >= 3, bytes[end - 1] == UInt8(ascii: "m") else { return nil }
        var i = end - 2
        let floor = max(0, end - 24) // SGR params are short; bound the scan
        while i > floor, (0x30...0x3B).contains(bytes[i]) { // digits ; :
            i -= 1
        }
        guard i >= 1, bytes[i] == UInt8(ascii: "["), bytes[i - 1] == esc else { return nil }
        return i - 1
    }

    // MARK: Column-0 classification

    /// Whether the byte stream is provably at column 0 when the cluster starts: the nearest
    /// preceding NON-zero-width byte is a newline / CR, or the stream start. Zero-width writes —
    /// SGR, EL (`ESC[K`), DECSCUSR (`ESC[n SP q`), any OSC — are looked through (the captured
    /// `cd ~` cycle interposes `\e[0 q` between the CRLF and the cluster). Anything unrecognized
    /// (cursor motion, alt-screen exit, plain text) ends the walk: text ⇒ mid-line; unknown
    /// control ⇒ the column is unknowable, and "not column 0" (CRLF replacement) is the safe
    /// answer — a spare newline, never an overprinted line.
    private static func columnZero(before start: Int, in bytes: [UInt8]) -> Bool {
        var i = start
        var budget = zeroWidthWalkSequenceBudget
        let floor = max(0, start - zeroWidthWalkByteBudget)
        while i > floor, budget > 0 {
            if let s = zeroWidthSequenceStart(before: i, floor: floor, in: bytes) {
                i = s
                budget -= 1
                continue
            }
            break
        }
        if i == 0 { return true }
        guard i > floor else { return false } // budget exhausted mid-walk — unknown
        return bytes[i - 1] == lf || bytes[i - 1] == cr
    }

    /// Matches one zero-width sequence ending exactly at `end`; returns its start (the `ESC`).
    private static func zeroWidthSequenceStart(before end: Int, floor: Int, in bytes: [UInt8]) -> Int? {
        guard end >= 3 else { return nil }
        let last = bytes[end - 1]
        // CSI finals that never move the cursor or print: SGR `m`, EL `K`, DECSCUSR `SP q`.
        if last == UInt8(ascii: "m") || last == UInt8(ascii: "K") || last == UInt8(ascii: "q") {
            var i = end - 2
            if last == UInt8(ascii: "q") {
                guard bytes[i] == sp else { return nil } // DECSCUSR's intermediate
                i -= 1
            }
            while i > floor, (0x30...0x3B).contains(bytes[i]) {
                i -= 1
            }
            guard i >= 1, bytes[i] == UInt8(ascii: "["), bytes[i - 1] == esc else { return nil }
            return i - 1
        }
        // OSC (title set, hyperlink, a 133 mark…), BEL- or ST-terminated: scan back to `ESC ]`.
        var bodyEnd = 0
        if last == bel {
            bodyEnd = end - 1
        } else if last == UInt8(ascii: "\\"), bytes[end - 2] == esc {
            bodyEnd = end - 2
        } else {
            return nil
        }
        var i = bodyEnd - 1
        while i > floor {
            let b = bytes[i]
            if b == esc {
                return bytes[i + 1] == UInt8(ascii: "]") ? i : nil
            }
            if b == bel || b == lf || b == cr { return nil } // crossed another terminator/line
            i -= 1
        }
        return nil
    }
}
