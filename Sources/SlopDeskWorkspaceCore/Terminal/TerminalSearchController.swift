import CSlopDeskFFI
import Foundation

// MARK: - TerminalSearch (pure scrollback find-in-terminal core)

/// The PURE engine behind ⌘F find-in-terminal (docs/42 W14 #5, Warp/Ghostty parity). It is fed a flat,
/// line-oriented text mirror of the visible scrollback (the client keeps one off ``TerminalViewModel``)
/// and computes the ordered match list, the current selection, the match count, and next/prev/wrap
/// navigation — with NO view, NO libghostty, NO store. The GUI `TerminalFindBar` overlay is a thin
/// driver over this; libghostty's own `start_search` action is wired compile-only as an enhancement
/// (it owns the in-surface highlight), but the count/nav UX is computed HERE so it is fully unit-testable
/// against an in-memory buffer (libghostty's search-result callbacks are not plumbed through the C
/// `action_cb` yet — see ``TerminalFindBar``).
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
public struct TerminalSearchController: Equatable, Sendable {
    /// One found occurrence: the 0-based line in the fed buffer and the UTF-16 column range within it
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

    /// The buffer being searched, one entry per scrollback line (no trailing newline). Set by ``setLines(_:)``.
    public private(set) var lines: [String] = []
    /// The current query text. Empty ⇒ no matches.
    public private(set) var query: String = ""
    /// Case-sensitive literal/regex matching (default off — terminals are usually searched case-insensitively).
    public private(set) var caseSensitive: Bool = false
    /// Treat ``query`` as a regular expression instead of a literal substring.
    public private(set) var isRegex: Bool = false
    /// Whole-word matching (the underlined `ab` toggle): keep only matches that stand on word boundaries —
    /// the code units immediately before and after the match are non-word (letter/digit/`_`) or the line edge
    /// — so the query hits a standalone token but not a substring of a larger word. Composes with case/regex.
    public private(set) var wholeWord: Bool = false
    /// The ordered match list for the current `(lines, query, caseSensitive, isRegex)` — recomputed on any change.
    public private(set) var matches: [Match] = []
    /// The index into ``matches`` that is "current" (the one the surface scrolls to / highlights), or `nil`
    /// when there are no matches. Navigation moves this; a recompute snaps it to the nearest valid slot.
    public private(set) var currentIndex: Int?

    public init() {}

    /// The number of matches (the "3 of 12" denominator).
    public var matchCount: Int { matches.count }

    /// The human "N of M" position (1-based), or `nil` when there are no matches. The find bar renders this.
    public var positionLabel: (current: Int, total: Int)? {
        guard let idx = currentIndex, !matches.isEmpty else { return nil }
        return (idx + 1, matches.count)
    }

    /// The currently-selected match, or `nil`.
    public var current: Match? {
        guard let idx = currentIndex, matches.indices.contains(idx) else { return nil }
        return matches[idx]
    }

    // MARK: Mutators (each recomputes the match list, preserving the selection where possible)

    /// Replaces the searched buffer (the client pushes the latest scrollback text here on every find).
    public mutating func setLines(_ newLines: [String]) {
        lines = newLines
        recompute()
    }

    /// Sets the query text (the find field's binding). Empty clears the matches.
    public mutating func setQuery(_ text: String) {
        query = text
        recompute()
    }

    /// Toggles case sensitivity and recomputes.
    public mutating func setCaseSensitive(_ on: Bool) {
        caseSensitive = on
        recompute()
    }

    /// Toggles regex mode and recomputes.
    public mutating func setRegex(_ on: Bool) {
        isRegex = on
        recompute()
    }

    /// Toggles whole-word matching and recomputes.
    public mutating func setWholeWord(_ on: Bool) {
        wholeWord = on
        recompute()
    }

    /// Advances the selection to the next match (wrapping past the last back to the first). No-op with no matches.
    ///
    /// Where it lands is `slopdesk_workspace::find_bar::step` — the ring wrap, and the no-selection arm
    /// that a ring rule cannot express: ⏎ into an unvisited match list names the FIRST match outright
    /// rather than picking an origin the user never sat on.
    public mutating func next() {
        currentIndex = Self.landing(from: currentIndex, forward: true, of: matches.count)
    }

    /// Moves the selection to the previous match (wrapping past the first to the last). No-op with no matches.
    ///
    /// The mirror of ``next()``, down to the no-selection arm: ⇧⏎ into an unvisited match list lands
    /// on the LAST match, which is where wrapping backwards off the first one goes.
    public mutating func previous() {
        currentIndex = Self.landing(from: currentIndex, forward: false, of: matches.count)
    }

    /// Clears the query + matches (the find bar's "close" / ⎋). The buffer is kept so reopening is cheap.
    public mutating func clear() {
        query = ""
        matches = []
        currentIndex = nil
    }

    // MARK: Recompute

    /// Rebuilds ``matches`` for the current inputs and re-anchors ``currentIndex`` (keep the same ordinal
    /// when still in range, else clamp to the last match, else `nil`). Pure — no I/O.
    private mutating func recompute() {
        let previous = currentIndex
        matches = Self.computeMatches(
            lines: lines,
            query: query,
            caseSensitive: caseSensitive,
            isRegex: isRegex,
            wholeWord: wholeWord,
            // What the LAST keystroke found, as the first guess for what this one will. Typing into
            // a find bar narrows: `w` → `wa` → `war` can only ever match fewer rows, so after the
            // first character the previous count is an over-estimate, which under docs/55 §4 is an
            // exact hit. Guessing 128 instead made every query that matches more than 128 times pay
            // the whole scan TWICE — the door reports the size it would have written and keeps
            // nothing, so the retry re-scans the entire scrollback. Measured through the door over a
            // 10 000-row / 736 KB scrollback, a query matching every row: 3.52 ms per keystroke at
            // the fixed guess against 1.83 ms at the carried one.
            expecting: matches.count,
        )
        // Keep the user near where they were: the same ORDINAL when it is still in range, the last
        // match when the list shrank under it, the first when they had not chosen one, and nothing
        // when the query now matches nothing. The rule is `slopdesk_workspace::find_bar::reanchor`.
        currentIndex = Self.index(slopdesk_ws_find_reanchor(
            previous != nil, previous ?? 0, matches.count,
        ))
    }

    // MARK: The two selection doors

    /// Where one step lands, as an index into ``matches`` or `nil`.
    private static func landing(from current: Int?, forward: Bool, of count: Int) -> Int? {
        index(slopdesk_ws_find_step(current != nil, current ?? 0, forward, count))
    }

    /// The door's `-1`-for-nothing answer as an optional index — `ListNavigation`'s own convention.
    private static func index(_ answer: Int) -> Int? {
        answer < 0 ? nil : answer
    }

    /// The match scanner (static so it can be reused / tested without an instance). Returns matches
    /// ordered by line then column. `wholeWord` post-filters EITHER mode to word-boundary matches (defaulted
    /// off so existing callers — e.g. ``GlobalSearchController`` — are unaffected).
    ///
    /// The scan itself is `slopdesk_rowscan::find`; this is the marshaller. Three walks over the same rows
    /// used to live here — a literal `NSString` scan, an `NSRegularExpression` pass and a boundary filter —
    /// and the middle one BACKTRACKS, which is a hang waiting for the pattern that provokes it. The Rust
    /// engine is a finite automaton, so a ⌘F pattern is linear in the line no matter what the user typed.
    ///
    /// `expecting` is how many matches the caller already has reason to think it will get — the previous
    /// keystroke's count, for a find bar. It buys the answer in ONE scan; see ``recompute()``. A caller
    /// with nothing to go on passes nothing and gets the stack-sized guess, which is what every find
    /// bar's FIRST keystroke does.
    ///
    /// ### The flatten is NOT worth memoizing — measured
    /// `lines` does not change between keystrokes, so re-flattening it here looks like the classic
    /// re-derivation. It is not one worth removing: measured over a 10 000-row / 736 KB scrollback the
    /// flatten is 136 µs against a 1.83 ms scan — 5.7% of the call, and holding a
    /// `(blob, lengths)` cache would put two representations of the buffer on an `Equatable, Sendable`
    /// value type, invalidated by hand. ``GlobalSearchController`` calls this per pane with lines it
    /// holds nowhere, so a cache on the struct would not reach the ⇧⌘F path at all.
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
