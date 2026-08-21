import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

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
    /// The wrap is ``ListNavigation/wrappedIndex(_:delta:count:)``, the same ring step the ⌃⇥ pane
    /// switcher and the picker's filter pills take. With NOTHING selected there is no index to step
    /// FROM, so the first match is named outright — a ring rule cannot express "start here", and
    /// asking it to would mean picking an origin the user never sat on.
    public mutating func next() {
        guard !matches.isEmpty else { currentIndex = nil
            return
        }
        guard let cur = currentIndex else { currentIndex = 0
            return
        }
        currentIndex = ListNavigation.wrappedIndex(cur, delta: 1, count: matches.count) ?? cur
    }

    /// Moves the selection to the previous match (wrapping past the first to the last). No-op with no matches.
    ///
    /// The mirror of ``next()``, down to the no-selection arm: ⇧⏎ into an unvisited match list lands
    /// on the LAST match, which is where wrapping backwards off the first one goes.
    public mutating func previous() {
        guard !matches.isEmpty else { currentIndex = nil
            return
        }
        guard let cur = currentIndex else { currentIndex = matches.count - 1
            return
        }
        currentIndex = ListNavigation.wrappedIndex(cur, delta: -1, count: matches.count) ?? cur
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
        )
        if matches.isEmpty {
            currentIndex = nil
        } else if let prev = previous {
            // Keep the user near where they were: clamp the old ordinal into the new range.
            currentIndex = Swift.min(prev, matches.count - 1)
        } else {
            currentIndex = 0
        }
    }

    /// The match scanner (static so it can be reused / tested without an instance). Returns matches
    /// ordered by line then column. `wholeWord` post-filters EITHER mode to word-boundary matches (defaulted
    /// off so existing callers — e.g. ``GlobalSearchController`` — are unaffected).
    ///
    /// The scan itself is `slopdesk_rowscan::find`; this is the marshaller. Three walks over the same rows
    /// used to live here — a literal `NSString` scan, an `NSRegularExpression` pass and a boundary filter —
    /// and the middle one BACKTRACKS, which is a hang waiting for the pattern that provokes it. The Rust
    /// engine is a finite automaton, so a ⌘F pattern is linear in the line no matter what the user typed.
    public static func computeMatches(
        lines: [String],
        query: String,
        caseSensitive: Bool,
        isRegex: Bool,
        wholeWord: Bool = false,
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
            // Most finds land a handful of hits, so guess a stack buffer wide enough for them and pay
            // the second scan only for the query that matches half the scrollback.
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: firstGuessBytes) { guess in
                let needed = call(guess)
                guard needed > guess.count else { return decode(guess, needed) }
                var wide = [UInt8](repeating: 0, count: needed)
                return wide.withUnsafeMutableBufferPointer { buffer in
                    let again = call(buffer)
                    return again <= buffer.count ? decode(buffer, again) : []
                }
            }
        }
    }

    // MARK: The door

    /// Room for 128 matches before the answer outgrows the stack: `[count]` plus 128 records.
    private static let firstGuessBytes = 4 + 128 * recordBytes

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
