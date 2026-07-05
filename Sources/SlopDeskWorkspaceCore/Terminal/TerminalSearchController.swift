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
/// - **Regex**: an `NSRegularExpression` over each line; an invalid pattern yields zero matches (never
///   traps — validate-then-drop, the untrusted-input contract applied to a user-typed pattern).
/// - **Whole-word** (the underlined `ab` toggle): a post-filter over EITHER mode keeping only the matches
///   whose immediately-adjacent code units are non-word (a letter / digit / `_`) — or the line edge — so the
///   query hits a standalone token but NOT a substring inside a larger word (`the` matches "the" but not
///   "theory"). Orthogonal to case / regex; it composes with both.
/// Matches are ordered top-to-bottom, then left-to-right (by line index, then column), so next/prev walk
/// the screen the way the eye reads it.
public struct TerminalSearchController: Equatable, Sendable {
    /// One found occurrence: the 0-based line in the fed buffer and the UTF-16 column range within it
    /// (UTF-16 so a regex `NSRange` maps back without re-encoding; the column is a code-unit offset).
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
    /// Treat ``query`` as an `NSRegularExpression` pattern instead of a literal substring.
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
    public mutating func next() {
        guard !matches.isEmpty else { currentIndex = nil
            return
        }
        let cur = currentIndex ?? -1
        currentIndex = (cur + 1) % matches.count
    }

    /// Moves the selection to the previous match (wrapping past the first to the last). No-op with no matches.
    public mutating func previous() {
        guard !matches.isEmpty else { currentIndex = nil
            return
        }
        let cur = currentIndex ?? 0
        currentIndex = (cur - 1 + matches.count) % matches.count
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

    /// The pure match scanner (static so it can be reused / tested without an instance). Returns matches
    /// ordered by line then column. `wholeWord` post-filters EITHER mode to word-boundary matches (defaulted
    /// off so existing callers — e.g. ``GlobalSearchController`` — are unaffected).
    public static func computeMatches(
        lines: [String],
        query: String,
        caseSensitive: Bool,
        isRegex: Bool,
        wholeWord: Bool = false,
    ) -> [Match] {
        guard !query.isEmpty else { return [] }
        let raw = isRegex
            ? regexMatches(lines: lines, pattern: query, caseSensitive: caseSensitive)
            : literalMatches(lines: lines, needle: query, caseSensitive: caseSensitive)
        guard wholeWord else { return raw }
        return raw.filter { isWholeWordMatch($0, in: lines) }
    }

    /// Whether `match` stands on word boundaries within its line: the code unit immediately before its start
    /// and immediately after its end are both non-word characters (a letter / digit / `_`) — or the line edge.
    /// Tested against single UTF-16 units (matches are UTF-16-column based), so `the` is whole-word inside
    /// "the dog" but not inside "theory".
    private static func isWholeWordMatch(_ match: Match, in lines: [String]) -> Bool {
        guard lines.indices.contains(match.line) else { return false }
        // swiftlint:disable:next legacy_objc_type
        let ns = lines[match.line] as NSString
        let start = match.column
        let end = match.column + match.length
        guard start >= 0, end <= ns.length else { return false }
        if start > 0, isWordCodeUnit(ns.character(at: start - 1)) { return false }
        if end < ns.length, isWordCodeUnit(ns.character(at: end)) { return false }
        return true
    }

    /// A "word" UTF-16 code unit for whole-word boundary detection: a Unicode letter / digit, or `_` (the `\w`
    /// sense). A lone surrogate half (no scalar) reads as a non-word boundary — safe: it never traps and an
    /// emoji etc. is treated as a separator, which is the desired whole-word behaviour next to one.
    private static func isWordCodeUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// Every case-(in)sensitive substring occurrence of `needle`, per line, advancing one UTF-16 unit
    /// past each hit's start so overlapping matches ("aa" in "aaa") are all found.
    private static func literalMatches(lines: [String], needle: String, caseSensitive: Bool) -> [Match] {
        var out: [Match] = []
        // swiftlint:disable:next legacy_objc_type
        let nsNeedle = needle as NSString
        let needleLen = nsNeedle.length
        guard needleLen > 0 else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for (lineIdx, line) in lines.enumerated() {
            // swiftlint:disable:next legacy_objc_type
            let ns = line as NSString
            var searchStart = 0
            while searchStart <= ns.length - needleLen {
                let found = ns.range(
                    of: needle,
                    options: options,
                    range: NSRange(location: searchStart, length: ns.length - searchStart),
                )
                if found.location == NSNotFound { break }
                out.append(Match(line: lineIdx, column: found.location, length: found.length))
                // Advance ONE unit past the match start (not past its end) so overlaps are not skipped.
                searchStart = found.location + 1
            }
        }
        return out
    }

    /// Every regex match per line; an invalid pattern yields `[]` (validate-then-drop, never traps).
    /// A zero-width match advances one unit to avoid an infinite loop.
    private static func regexMatches(lines: [String], pattern: String, caseSensitive: Bool) -> [Match] {
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        var out: [Match] = []
        for (lineIdx, line) in lines.enumerated() {
            // swiftlint:disable:next legacy_objc_type
            let ns = line as NSString
            regex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { result, _, _ in
                guard let r = result?.range, r.location != NSNotFound, r.length > 0 else { return }
                out.append(Match(line: lineIdx, column: r.location, length: r.length))
            }
        }
        return out
    }
}
