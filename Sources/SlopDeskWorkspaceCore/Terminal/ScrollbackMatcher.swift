import CSlopDeskFFI
import Foundation

// MARK: - ScrollbackMatcher (⇧⌘F's cross-pane scan over a text mirror)

/// The scan behind CROSS-TAB Global Search (⇧⌘F): a flat, line-oriented text mirror of one pane's
/// scrollback in, an ordered match list out. No view, no engine, no store.
///
/// ⚠️ **THE IN-PANE ⌘F BAR IS NOT A CALLER, and it used to be.** It drove its counter from this scan
/// while the surface lit cells from its own — two engines over two representations of one buffer,
/// which is gap 4. ⌘F now asks the surface for all four modes and reads the count back from it
/// (``TerminalSurfaceActions/find(_:caseSensitive:wholeWord:isRegex:)``), so this has exactly one
/// consumer left.
///
/// ⚠️ **That leaves two matchers in the tree, and the split is deliberate rather than left over.**
/// ⇧⌘F searches EVERY open pane on every keystroke; asking each pane's live engine would cross the
/// FFI seam per pane per character, so ``WorkspaceStore/beginGlobalSearchSession()`` mirrors every
/// scrollback ONCE when the overlay opens and re-runs this in memory afterwards. The two scans are
/// not two answers to one question — one addresses grid CELLS in a live buffer, the other line
/// INDICES in a snapshot — and each is the only shape its feature can have.
///
/// ### Matching
/// - **Literal** (default): a case-insensitive (or case-sensitive) substring scan, finding EVERY
///   occurrence on every line (overlapping matches advance by one, so "aa" in "aaa" yields two).
/// - **Regex**: the `regex` crate's dialect over each line — linear in the line, so no pattern can hang the
///   find bar; the price is no lookaround and no backreferences. An invalid (or unsupported) pattern yields
///   zero matches, never a trap — validate-then-drop, the untrusted-input contract applied to a user-typed
///   pattern, and the same path an unfinished `(foo` already took on every keystroke.
/// - **Whole-word** (the underlined `ab` toggle): a post-filter over EITHER mode keeping only the matches
///   whose immediately-adjacent code units are non-word (a letter / digit / `_`) — or the line edge — so the
///   query hits a standalone token but NOT a substring inside a larger word (`the` matches "the" but not
///   "theory"). Orthogonal to case / regex; it composes with both.
/// Matches are ordered top-to-bottom, then left-to-right (by line index, then column), so next/prev walk
/// the screen the way the eye reads it.
public enum ScrollbackMatcher {
    /// One found occurrence: the 0-based line in the scanned buffer and the UTF-16 column range within it
    /// (UTF-16 because that is what the highlighting surface indexes in; the column is a code-unit offset).
    public struct Match: Equatable, Sendable {
        public let line: Int
        public let column: Int
        public let length: Int
        public init(line: Int, column: Int, length: Int) {
            self.line = line
            self.column = column
            self.length = length
        }
    }

    /// The scan. Returns matches ordered by line then column. `wholeWord` post-filters EITHER mode to
    /// word-boundary matches (defaulted off, which is what ``GlobalSearchController`` wants — its
    /// overlay has no `ab` pill).
    ///
    /// The scan itself is `slopdesk_rowscan::find`; this is the marshaller. Three walks over the same rows
    /// used to live here — a literal `NSString` scan, an `NSRegularExpression` pass and a boundary filter —
    /// and the middle one BACKTRACKS, which is a hang waiting for the pattern that provokes it. The Rust
    /// engine is a finite automaton, so a ⌘F pattern is linear in the line no matter what the user typed.
    ///
    /// `expecting` is how many matches the caller already has reason to think it will get — the
    /// previous keystroke's count. It buys the answer in ONE scan: the door reports the size it would
    /// have written and keeps nothing, so a guess that is one record short costs a second scan of the
    /// whole scrollback. A caller with nothing to go on passes nothing and gets the stack-sized guess,
    /// which is what a first keystroke does.
    ///
    /// ### The flatten is NOT worth memoizing — measured
    /// `lines` does not change between keystrokes, so re-flattening it here looks like the classic
    /// re-derivation. It is not one worth removing: measured over a 10 000-row / 736 KB scrollback the
    /// flatten is 136 µs against a 1.83 ms scan — 5.7% of the call, and holding a
    /// `(blob, lengths)` cache would put two representations of the buffer on an `Equatable, Sendable`
    /// value type, invalidated by hand. ``GlobalSearchController`` calls this per pane with lines it
    /// holds nowhere, so a cache would not reach the ⇧⌘F path at all.
    public static func computeMatches(
        lines: [String],
        query: String,
        caseSensitive: Bool,
        isRegex: Bool,
        wholeWord: Bool = false,
        expecting expected: Int = 0,
    ) -> [Match] {
        guard !query.isEmpty else { return [] }
        let (rowBlob, rowLengths) = TerminalLinkDetector.flatten(lines)
        var needle = query
        return needle.withUTF8 { queryBytes -> [Match] in
            let call = { (out: UnsafeMutableBufferPointer<UInt8>) -> Int in
                slopdesk_find_matches(
                    rowBlob, rowBlob.count,
                    rowLengths, rowLengths.count,
                    queryBytes.baseAddress, queryBytes.count,
                    caseSensitive, isRegex, wholeWord,
                    out.baseAddress, out.count,
                )
            }
            return read(guessing: Swift.max(stackGuessRecords, expected), call)
        }
    }

    // MARK: The door

    /// Reads the door's answer, sizing the first buffer at `records` matches and re-asking at the size
    /// it reports if that was short.
    ///
    /// The retry is docs/55 §4's, and on this door it is EXPENSIVE in a way the convention's cheap
    /// doors are not: `slopdesk_find_matches` builds its answer by scanning the whole scrollback, so a
    /// first guess that is one record short costs a second scan of every row. That is why the guess is
    /// worth carrying forward rather than fixing at a constant, and why nothing here probes with a null
    /// output — a null-output call is the retry with the first scan thrown away.
    private static func read(
        guessing records: Int,
        _ ask: (UnsafeMutableBufferPointer<UInt8>) -> Int,
    ) -> [Match] {
        var needed = 0
        let attempt = { (room: UnsafeMutableBufferPointer<UInt8>) -> [Match]? in
            needed = ask(room)
            return needed > room.count ? nil : decode(room, needed)
        }
        let bytes = 4 + Swift.max(0, records) * recordBytes
        // The stack only for the guess that fits it. A find over a big scrollback can legitimately
        // expect tens of thousands of matches, and a temporary allocation that size is a stack the
        // find bar does not have; a malloc is tens of nanoseconds against a scan that is milliseconds.
        let first: [Match]? =
            if records <= stackGuessRecords {
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bytes, attempt)
            } else {
                heap(bytes: bytes, attempt)
            }
        if let first { return first }
        return heap(bytes: needed, attempt) ?? []
    }

    /// One heap-backed attempt at `bytes` wide. Separate only so the two call sites in ``read(guessing:_:)``
    /// spell the allocation once.
    private static func heap(bytes: Int, _ attempt: (UnsafeMutableBufferPointer<UInt8>) -> [Match]?) -> [Match]? {
        var room = [UInt8](repeating: 0, count: Swift.max(0, bytes))
        return room.withUnsafeMutableBufferPointer { buffer in attempt(buffer) }
    }

    /// Room for 128 matches before the answer outgrows the stack: `[count]` plus 128 records.
    private static let stackGuessRecords = 128

    /// `[uint32 line][uint32 column][uint32 length]`.
    private static let recordBytes = 12

    /// Reads `[uint32 count]` and that many fixed-stride records out of the door's answer.
    ///
    /// A short or truncated answer decodes to nothing rather than to a partial list — a find bar showing
    /// "3 of 7" over four highlights is worse than one showing nothing, because the count is the thing
    /// the user navigates by.
    private static func decode(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ length: Int) -> [Match] {
        guard length >= 4 else { return [] }
        let word = { (at: Int) -> Int in
            var value = 0
            for offset in at..<(at + 4) { value = value << 8 | Int(bytes[offset]) }
            return value
        }
        let count = word(0)
        guard length >= 4 + count * recordBytes else { return [] }
        var out: [Match] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let at = 4 + index * recordBytes
            out.append(Match(line: word(at), column: word(at + 4), length: word(at + 8)))
        }
        return out
    }
}
