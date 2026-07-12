import Foundation

// MARK: - Pure Hint Mode target detection + Vimium-style 2-letter label assignment

/// Which hint action the user armed — the "Hint to …" family (`docs/ui-shell/spec/terminal-features__hint-mode.md`).
///
/// - ``open``: ⌘⇧J — opens the matched target (a file path on the HOST, a URL on the CLIENT, …).
/// - ``copy``: ⌘⇧Y — copies the matched text to the CLIENT clipboard.
/// - ``reveal``: (chord-less — ⌘⇧R is slopdesk's Toggle Details) — reveals the matched PATH in
///   Finder on the HOST.
public enum HintIntent: Equatable, Sendable {
    case open
    case copy
    case reveal
}

/// A user-defined hint pattern (`hint-pattern` + `hint-pattern-action`): a regex string plus an
/// optional shell-command action template whose `{0}` placeholder is replaced with the matched text.
public struct HintPattern: Equatable, Sendable {
    /// The regex (ICU `NSRegularExpression` syntax) that defines a custom hintable span.
    public var regex: String
    /// The action template run when the label resolves — `{0}` is replaced with the matched text. `nil` when
    /// the pattern carries no paired action (the target then falls back to copy-on-resolve).
    public var action: String?

    public init(regex: String, action: String? = nil) {
        self.regex = regex
        self.action = action
    }
}

/// One hintable target in the visible viewport: its cell span (same display-cell convention as
/// ``DetectedLink`` — fullwidth/East-Asian glyphs count as two cells), the matched text, and the kind that
/// decides how a resolved label actuates.
public struct HintTarget: Equatable, Sendable {
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
    public var raw: String
    public var kind: Kind

    /// What the target is — drives the resolved action (open/copy/reveal) at the actuation site.
    ///
    /// - ``link``: a path / URL / `file://` / `mailto:` span the shared ``TerminalLinkDetector`` already
    ///   classified — carries the full ``DetectedLink`` so the actuator routes through the SAME pure
    ///   ``LinkActionPolicy`` the ⌘click / Jump-To paths use (no parallel mapping to drift).
    /// - ``gitHash``: a `[0-9a-f]{7,40}` commit-hash-shaped token.
    /// - ``ipAddress``: a dotted-quad IPv4 address.
    /// - ``custom``: a user `hint-pattern` match, carrying its optional `{0}` action template.
    public enum Kind: Equatable, Sendable {
        case link(DetectedLink)
        case gitHash
        case ipAddress
        case custom(actionTemplate: String?)
    }

    public init(row: Int, colStart: Int, colEnd: Int, raw: String, kind: Kind) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.raw = raw
        self.kind = kind
    }
}

/// The PURE heart of Hint Mode: scan the visible viewport rows for every hintable
/// target (paths/URLs via the shared ``TerminalLinkDetector``, plus git-hash / IPv4 / user `hint-pattern`
/// forms), then assign **collision-free 2-letter** Vimium labels and filter them as the user types.
///
/// ## Why a pure enum
/// Like ``TerminalLinkDetector``, hint target detection + label assignment is a deterministic text scan with
/// no host round-trip, so keeping it environment-free makes it headless-unit-testable (``HintLabelAssignerTests``)
/// and lets the macOS renderer (key capture) and the iOS overlay (tap-on-label) share ONE engine. The thin
/// ``HintModeOverlay`` feeds it `viewportTextRows()` and maps `colStart ..< colEnd` to pixels via
/// ``TerminalCellMetrics``.
///
/// ## Validate-then-drop & bounds (CLAUDE.md §3 habit, applied to untrusted terminal bytes)
/// Terminal output is attacker-influenced. Each row is scanned for at most `maxScanColumns` **cells**, at
/// most ``TerminalLinkDetector/maxMatchesPerRow`` targets are kept per row, an invalid user regex is dropped
/// (never a trap), and an extra (git-hash/IP/custom) match that OVERLAPS an already-accepted span is dropped
/// so a hex run inside a URL — or an IP inside a path — never double-lights.
public enum HintLabelAssigner {
    /// The label alphabet — home row first, then the top row, then the bottom row (Vimium "ordered by
    /// distance from the home row"). 26 letters ⇒ up to 26² = 676 two-letter labels (far more than a
    /// viewport ever holds). All lowercase; matching is case-insensitive.
    public static let defaultAlphabet: [Character] = Array("asdfghjklqwertyuiopzxcvbnm")

    // MARK: - Label assignment

    /// Assign `count` UNIQUE, exactly-2-letter labels over `alphabet`.
    ///
    /// The first letter cycles FASTEST (`alphabet[i % k]`) and the second slowest (`alphabet[i / k]`), so
    /// consecutive on-screen targets get DIFFERENT first letters — typing one key spreads the survivors
    /// across the screen instead of clustering them (the Vimium ergonomic). Each `i` in `0 ..< k²` maps to a
    /// unique `(i % k, i / k)` pair, so the labels are collision-free. Bounded at `k²`: a (pathological)
    /// request for more targets than the alphabet can label 2-deep is clamped (the caller then shows only the
    /// labelled prefix — never an ambiguous or 3-letter label).
    public static func labels(count: Int, alphabet: [Character] = defaultAlphabet) -> [String] {
        guard !alphabet.isEmpty else { return [] }
        let k = alphabet.count
        let n = min(max(count, 0), k * k)
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(String([alphabet[i % k], alphabet[i / k]]))
        }
        return out
    }

    /// The result of filtering the labels against the keys typed so far.
    public struct FilterResult: Equatable, Sendable {
        /// Labels that still start with the typed prefix (kept bright).
        public var matched: [String]
        /// Labels that no longer match (dimmed / hidden to narrow focus).
        public var dimmed: [String]
        /// The label the user has fully typed (2 chars, exact) — the action runs immediately, no Enter.
        public var confirmed: String?

        public init(matched: [String], dimmed: [String], confirmed: String?) {
            self.matched = matched
            self.dimmed = dimmed
            self.confirmed = confirmed
        }
    }

    /// Filter `labels` against `typed` (the keys entered so far). Empty `typed` ⇒ all matched, none dimmed.
    /// One letter ⇒ matched are the labels with that first letter (the rest dim). Two letters ⇒ `confirmed`
    /// is the exact label (if any) — the second key confirms with no Enter required.
    public static func filter(typed: String, labels: [String]) -> FilterResult {
        let key = typed.lowercased()
        guard !key.isEmpty else {
            return FilterResult(matched: labels, dimmed: [], confirmed: nil)
        }
        var matched: [String] = []
        var dimmed: [String] = []
        for label in labels {
            if label.hasPrefix(key) { matched.append(label) } else { dimmed.append(label) }
        }
        // A label is exactly 2 chars; once the prefix is 2 long it either equals a label (confirm) or matches
        // none (an invalid second key — the caller ignores it, keeping the first letter).
        let confirmed = key.count >= 2 ? labels.first { $0 == key } : nil
        return FilterResult(matched: matched, dimmed: dimmed, confirmed: confirmed)
    }

    // MARK: - Target detection

    /// Detect every hintable target in `rows` (the VISIBLE viewport), row-major / left-to-right.
    ///
    /// - Parameters:
    ///   - rows: the visible viewport rows top→bottom (``TerminalViewportSnapshotting/viewportTextRows()``).
    ///   - cwd: the pane's last-known working directory (OSC 7) — resolves relative detected paths.
    ///   - schemes: which `scheme://…` URLs are detected (`http(s)`/`file`/`mailto` always on).
    ///   - patterns: user `hint-pattern` regexes (+ their `{0}` action templates).
    ///   - maxScanColumns: per-row cell-scan ceiling (the anti-hang bound).
    public static func targets(
        rows: [String],
        cwd: String?,
        schemes: LinkSchemePolicy,
        patterns: [HintPattern] = [],
        maxScanColumns: Int = 4096,
    ) -> [HintTarget] {
        guard maxScanColumns > 0 else { return [] }

        // Per-row accepted targets, so the extra regex scans can drop a span that overlaps a link / a
        // higher-priority extra match (a hex inside a URL must NOT also light as a git hash).
        var perRow: [Int: [HintTarget]] = [:]

        // 1) Paths / URLs / file:// / mailto: — reuse the shared detector (cell-accurate columns).
        for link in TerminalLinkDetector.detect(
            rows: rows, cwd: cwd, schemes: schemes, maxScanColumns: maxScanColumns,
        ) {
            perRow[link.row, default: []].append(
                HintTarget(
                    row: link.row, colStart: link.colStart, colEnd: link.colEnd,
                    raw: link.raw, kind: .link(link),
                ),
            )
        }

        // 2) Extra regex targets per row, in priority order: custom patterns, then IPs, then git hashes.
        //    Each is dropped if it overlaps an already-accepted span on the row (validate-then-drop).
        for (row, line) in rows.enumerated() {
            let bounded = boundedPrefix(line, maxCells: maxScanColumns)
            guard !bounded.isEmpty else { continue }
            for pattern in patterns {
                guard let regex = compile(pattern.regex) else { continue } // invalid user regex → dropped
                addMatches(of: regex, in: bounded, row: row, into: &perRow) { range, matched in
                    HintTarget(
                        row: row, colStart: range.start, colEnd: range.end,
                        raw: matched, kind: .custom(actionTemplate: pattern.action),
                    )
                }
            }
            addMatches(of: ipv4Regex, in: bounded, row: row, into: &perRow) { range, matched in
                HintTarget(row: row, colStart: range.start, colEnd: range.end, raw: matched, kind: .ipAddress)
            }
            addMatches(of: gitHashRegex, in: bounded, row: row, into: &perRow) { range, matched in
                // Drop a pure-decimal run (a long number is not a commit hash): require ≥1 hex LETTER.
                guard matched.contains(where: \.isHexLetter) else { return nil }
                return HintTarget(row: row, colStart: range.start, colEnd: range.end, raw: matched, kind: .gitHash)
            }
        }

        // 3) Flatten + order row-major, left-to-right (label assignment then reads this order).
        return perRow.values.flatMap(\.self).sorted {
            $0.row != $1.row ? $0.row < $1.row : $0.colStart < $1.colStart
        }
    }

    // MARK: - Regex scanning helpers

    /// A matched cell span (start inclusive, end exclusive).
    private struct CellSpan {
        var start: Int
        var end: Int
    }

    /// Run `regex` over `bounded` (already cell-bounded), build a target from each match via `make`, and
    /// keep it only when it does NOT overlap an already-accepted span on `row` (and the per-row cap is not
    /// exceeded). Cell columns are computed against the matched substring's UTF-16 prefix using the SAME
    /// display-cell width the detector uses, so an extra match aligns with the link spans on a CJK row.
    private static func addMatches(
        of regex: NSRegularExpression,
        in bounded: String,
        row: Int,
        into perRow: inout [Int: [HintTarget]],
        make: (CellSpan, String) -> HintTarget?,
    ) {
        // `NSString` gives the UTF-16 `substring(with: NSRange)` that `NSRegularExpression` match ranges index
        // into (Swift `String` has no `NSRange` subscript); the bridge is the idiomatic regex-extraction path.
        // swiftlint:disable:next legacy_objc_type
        let ns = bounded as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: bounded, options: [], range: full)
        for match in matches {
            if (perRow[row]?.count ?? 0) >= TerminalLinkDetector.maxMatchesPerRow { break }
            let nsRange = match.range
            guard nsRange.location != NSNotFound, nsRange.length > 0,
                  nsRange.location + nsRange.length <= ns.length else { continue }
            let prefix = ns.substring(to: nsRange.location)
            let matched = ns.substring(with: nsRange)
            let colStart = TerminalLinkDetector.displayCellWidth(of: prefix)
            let colEnd = colStart + TerminalLinkDetector.displayCellWidth(of: matched)
            let span = CellSpan(start: colStart, end: colEnd)
            guard !overlapsAccepted(span, row: row, in: perRow), let target = make(span, matched) else { continue }
            perRow[row, default: []].append(target)
        }
    }

    /// Whether `span` overlaps any already-accepted target's cell span on `row`.
    private static func overlapsAccepted(_ span: CellSpan, row: Int, in perRow: [Int: [HintTarget]]) -> Bool {
        guard let existing = perRow[row] else { return false }
        return existing.contains { span.start < $0.colEnd && $0.colStart < span.end }
    }

    /// A prefix of `line` holding at most `maxCells` display cells (the anti-hang bound; a single wide glyph
    /// that would spill past the cap is excluded whole).
    private static func boundedPrefix(_ line: String, maxCells: Int) -> String {
        var cells = 0
        var out = ""
        for character in line {
            let width = TerminalLinkDetector.displayCellWidth(of: character)
            if cells + width > maxCells { break }
            out.append(character)
            cells += width
        }
        return out
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: - Built-in extra patterns

    // `try!` is safe on these compile-time-constant patterns (a programmer-error trap, never attacker input —
    // only user `hint-pattern` regexes are `try?`-guarded above), matching the `SecretRedactor` idiom. Disabled
    // as a region (not `:next`) so each `///` doc comment stays attached to its declaration.
    // swiftlint:disable force_try

    /// Commit-hash shape: a 7–40 char `[0-9a-f]` run on a word boundary. The fixed-length lookarounds keep it
    /// ICU-legal; the builder additionally requires ≥1 hex LETTER so a long decimal is not mistaken for a hash.
    private static let gitHashRegex = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])", options: [],
    )

    /// IPv4 dotted-quad with each octet validated 0–255 IN the regex, word-boundaried so a 5-part run does not
    /// partially match. `try!` is safe on this compile-time-constant pattern (see ``gitHashRegex``).
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: "(?<![0-9.])(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
            + "(?:\\.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}(?![0-9.])",
        options: [],
    )
    // swiftlint:enable force_try
}

// MARK: - Small ASCII predicate

private extension Character {
    /// A lowercase hex LETTER (`a`–`f`) — used to reject a pure-decimal run as a git hash.
    var isHexLetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x61 && scalar.value <= 0x66
    }
}
