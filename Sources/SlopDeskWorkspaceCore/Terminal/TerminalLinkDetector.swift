import Foundation

// MARK: - E10 WI-1 (ES-E10-1 / ES-E10-2): pure path / URL / link detector over the terminal grid

/// The classification of a span detected by ``TerminalLinkDetector``. Mirrors the
/// `docs/ui-shell/spec/user-interface__files-and-links.md` "Path and Link Detection" list.
///
/// - ``absolutePath``: a `/…`-rooted filesystem path (`/usr/local/bin/foo`).
/// - ``tildePath``: a `~`-anchored path (`~/project/file.swift`) — anchored at the host `$HOME`,
///   which the pure detector cannot expand (see ``DetectedLink/resolvedAbsolute``).
/// - ``relativePath``: a `./…` / `../…` (or bare `dir/file` carrying a line/col suffix) path,
///   resolved against the pane cwd.
/// - ``pathLineCol``: any of the above carrying a `:line` or `:line:col` suffix
///   (`src/lib.rs:42`, `src/lib.rs:42:5`) — compiler/linter output. The `raw` keeps the suffix; the
///   resolved path drops it.
/// - ``url``: a `scheme://…` URL (subject to the scheme policy) or an always-on `mailto:` address.
/// - ``fileURL``: a `file://…` URL — its filesystem path is surfaced in `resolvedAbsolute`.
public enum DetectedLinkKind: Equatable, Hashable, Sendable, CaseIterable {
    case absolutePath
    case tildePath
    case relativePath
    case pathLineCol
    case url
    case fileURL
}

/// One detected interactive span in a terminal row.
///
/// `colStart ..< colEnd` are **display cell columns** (East-Asian-wide / fullwidth glyphs count as 2
/// cells, combining marks as the base) so the WI-2 geometry seam can map a match straight to a
/// `CGRect` (`originX + cellWidth * colStart`, width `cellWidth * (colEnd − colStart)`) without a
/// second width pass. `colEnd` is exclusive. `raw` is the exact matched substring (line/col suffix
/// included). `resolvedAbsolute` is the absolute filesystem path when it can be derived PURELY (an
/// absolute path, normalized; a relative path joined to an absolute cwd; a `file://` path) — and
/// `nil` otherwise (tilde paths need the host `$HOME`; plain URLs are not filesystem paths).
public struct DetectedLink: Equatable, Hashable, Sendable {
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
    public var kind: DetectedLinkKind
    public var raw: String
    public var resolvedAbsolute: String?

    public init(
        row: Int,
        colStart: Int,
        colEnd: Int,
        kind: DetectedLinkKind,
        raw: String,
        resolvedAbsolute: String?,
    ) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.kind = kind
        self.raw = raw
        self.resolvedAbsolute = resolvedAbsolute
    }
}

/// Which URL schemes the detector underlines / makes clickable — the "Auto-Detect Link Schemes" setting.
///
/// `http`, `https`, `file`, and `mailto` are **always** detected regardless of this policy (hard-coded);
/// this only governs OTHER `scheme://…` forms.
public enum LinkSchemePolicy: Equatable, Hashable, Sendable {
    /// Detect ANY `scheme://…` (the default, labeled "All" in Settings).
    case all
    /// Detect only the always-on schemes plus this user list (labeled "Custom" in Settings, e.g. `codex`,
    /// `ssh`, `vscode`). Compared case-insensitively.
    case custom([String])
}

/// The PURE, headless heart of the terminal's path/URL/link detection (E10 ES-E10-1/2): scan
/// `[String]` rows and return every detected path, `path:line:col`, URL, `file://`, and `mailto:`
/// span with its cell columns and (where derivable) resolved absolute path.
///
/// ## Why a pure enum
/// Detection is a deterministic text scan with **no host round-trip** (the slopdesk mapping note
/// confirms it: the client already tracks the pane cwd via OSC 7). Keeping it a pure, environment-free
/// function makes it unit-testable headless and lets the same code drive the ⌘-hold underline (WI-5),
/// Jump-To (WI-8), and Hint Mode (WI-9) overlays. The thin GUI surfaces feed it
/// `viewportTextRows()` (WI-2) and map `colStart ..< colEnd` to pixels.
///
/// ## Validate-then-drop & bounds (CLAUDE.md §3 habit, applied to untrusted terminal bytes)
/// Terminal output is attacker-influenced (a remote program prints whatever it likes), so the scan is
/// bounded and total: each row is scanned for at most `maxScanColumns` **cells** (a pathological
/// no-whitespace megabyte line can never make this hang), at most ``maxMatchesPerRow`` matches are
/// emitted per row, classification never force-unwraps, and an unrecognised / disallowed span is
/// simply dropped (never a trap). Bare `dir/file` runs without a `./`/`../` prefix are only accepted
/// when they carry a line:col suffix — otherwise ordinary prose (`and/or`, `TODO/DONE`, `git@host:org/repo`)
/// would light up.
///
/// Pinned by `TerminalLinkDetectorTests` (each form, the CJK cell-column mapping, the scheme policy,
/// the column bound, and the no-match noise are revert-to-confirm-fail).
public enum TerminalLinkDetector {
    /// Hard cap on emitted matches per row (output bound, independent of `maxScanColumns`).
    public static let maxMatchesPerRow = 512

    /// Detect every interactive span in `rows`.
    ///
    /// - Parameters:
    ///   - rows: terminal rows top→bottom (a viewport slice for the overlays, or scrollback for
    ///     Jump-To). The returned `row` is the index into THIS array.
    ///   - cwd: the pane's last-known working directory (OSC 7). Used to resolve relative paths to an
    ///     absolute `resolvedAbsolute`; ignored unless it is itself absolute.
    ///   - schemes: which `scheme://…` URLs are detected (`http(s)`/`file`/`mailto` are always on).
    ///   - maxScanColumns: per-row cell-scan ceiling (default 4096) — the anti-hang bound.
    /// - Returns: detected links in row-major, left-to-right order.
    public static func detect(
        rows: [String],
        cwd: String?,
        schemes: LinkSchemePolicy,
        maxScanColumns: Int = 4096,
    ) -> [DetectedLink] {
        guard maxScanColumns > 0 else { return [] }
        var out: [DetectedLink] = []
        for (row, line) in rows.enumerated() {
            var matchesThisRow = 0
            for token in tokenize(line, maxScanColumns: maxScanColumns) {
                if matchesThisRow >= maxMatchesPerRow { break }
                let (core, leadingCells) = trimWrapping(token.text)
                guard let link = classify(
                    core: core,
                    row: row,
                    cellStart: token.cellStart + leadingCells,
                    cwd: cwd,
                    schemes: schemes,
                ) else { continue }
                out.append(link)
                matchesThisRow += 1
            }
        }
        return out
    }

    // MARK: - Tokenizing (bounded, single pass)

    /// A whitespace-delimited run with the cell column of its first character.
    private struct RawToken {
        var text: String
        var cellStart: Int
    }

    /// Split `line` into whitespace-delimited tokens, tracking display cell columns and stopping once
    /// `maxScanColumns` cells have been consumed (the anti-hang bound). A token that began within
    /// bounds but spills past the cap is kept truncated — bounded work, never a wrong span outside it.
    private static func tokenize(_ line: String, maxScanColumns: Int) -> [RawToken] {
        var tokens: [RawToken] = []
        var cell = 0
        var current = ""
        var currentStart = 0
        for character in line {
            if cell >= maxScanColumns { break }
            let width = cellWidth(of: character)
            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(RawToken(text: current, cellStart: currentStart))
                    current = ""
                }
                cell += width
                continue
            }
            if current.isEmpty { currentStart = cell }
            current.append(character)
            cell += width
        }
        if !current.isEmpty {
            tokens.append(RawToken(text: current, cellStart: currentStart))
        }
        return tokens
    }

    // MARK: - Wrapping-punctuation trim

    private static let leadingTrim: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`", "\u{201C}", "\u{2018}"]
    private static let trailingTrim: Set<Character> = [
        ".", ",", ";", "!", "?", ")", "]", "}", ">", "\"", "'", "`", "\u{201D}", "\u{2019}",
    ]

    /// Closing brackets whose trailing trim is BALANCED against their opener inside the token — so a URL
    /// whose path legitimately ends in a matched close (`…/Swift_(programming_language)`, a `#L10)` prose
    /// anchor) keeps it, while an unmatched wrapping close (prose `(https://x.com)`) is still stripped.
    private static let balancedClosers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// Strip wrapping brackets/quotes and trailing sentence punctuation so `(https://x.com).` →
    /// `https://x.com`. Crucially `:` is NOT trailing-trimmed — the `:line:col` suffix must survive.
    /// Returns the trimmed core plus the cell count removed from the FRONT (so the caller can advance
    /// `cellStart`); trailing trims never move `cellStart`.
    private static func trimWrapping(_ text: String) -> (core: String, leadingCells: Int) {
        var chars = Array(text)
        var leadingCells = 0
        while let first = chars.first, leadingTrim.contains(first) {
            leadingCells += cellWidth(of: first)
            chars.removeFirst()
        }
        while let last = chars.last, trailingTrim.contains(last) {
            // A closing bracket is only trailing-trimmed when UNBALANCED (more of it than its opener remains
            // in the token) — a balanced pair (a wiki disambiguation `(…)`, a `[…]`/`{…}` in the path) is a
            // real part of the URL and must survive, matching iTerm2/ghostty paren balancing.
            if let opener = balancedClosers[last] {
                let closeCount = chars.reduce(0) { $0 + ($1 == last ? 1 : 0) }
                let openCount = chars.reduce(0) { $0 + ($1 == opener ? 1 : 0) }
                if closeCount <= openCount { break }
            }
            chars.removeLast()
        }
        return (String(chars), leadingCells)
    }

    // MARK: - Classification

    private static func classify(
        core: String,
        row: Int,
        cellStart: Int,
        cwd: String?,
        schemes: LinkSchemePolicy,
    ) -> DetectedLink? {
        guard !core.isEmpty else { return nil }
        if let link = classifyURL(core, row: row, cellStart: cellStart, schemes: schemes) { return link }
        if let link = classifyMailto(core, row: row, cellStart: cellStart) { return link }
        if let link = classifyPath(core, row: row, cellStart: cellStart, cwd: cwd) { return link }
        return nil
    }

    /// `scheme://…` (and `file://…`). A scheme outside the policy is DROPPED, not reinterpreted as a
    /// path — it is unambiguously a URL the user opted not to detect.
    private static func classifyURL(
        _ core: String,
        row: Int,
        cellStart: Int,
        schemes: LinkSchemePolicy,
    ) -> DetectedLink? {
        guard let separator = core.range(of: "://") else { return nil }
        let scheme = String(core[core.startIndex..<separator.lowerBound])
        guard isValidScheme(scheme), separator.upperBound < core.endIndex else { return nil }
        let lower = scheme.lowercased()
        let kind: DetectedLinkKind
        var resolved: String?
        if lower == "file" {
            kind = .fileURL
            resolved = fileURLPath(core)
        } else if isSchemeAllowed(lower, schemes) {
            kind = .url
        } else {
            return nil
        }
        return DetectedLink(
            row: row,
            colStart: cellStart,
            colEnd: cellStart + cellWidthOf(core),
            kind: kind,
            raw: core,
            resolvedAbsolute: resolved,
        )
    }

    /// `mailto:user@host` — always detected regardless of the scheme policy. Requires an `@`
    /// so a bare `mailto:` is dropped (validate-then-drop).
    private static func classifyMailto(_ core: String, row: Int, cellStart: Int) -> DetectedLink? {
        guard core.lowercased().hasPrefix("mailto:") else { return nil }
        let address = core.dropFirst("mailto:".count)
        guard !address.isEmpty, address.contains("@") else { return nil }
        return DetectedLink(
            row: row,
            colStart: cellStart,
            colEnd: cellStart + cellWidthOf(core),
            kind: .url,
            raw: core,
            resolvedAbsolute: nil,
        )
    }

    private enum PathShape: Equatable {
        case absolute
        case tilde
        case relativeDot
        case bareRelative
    }

    /// Absolute / tilde / relative / `path:line[:col]` filesystem paths.
    private static func classifyPath(
        _ core: String,
        row: Int,
        cellStart: Int,
        cwd: String?,
    ) -> DetectedLink? {
        // Strip trailing colons FIRST (a log "/path:" or "Error:", and — critically — the standard
        // compiler-diagnostic form `path:line:col:` whose trailing `:` would otherwise defeat splitLineCol,
        // leaving `:line:col` baked into the resolved path so open/reveal fails), THEN split the numeric
        // `:line[:col]` suffix off the cleaned token so `path:line:col:` resolves as `.pathLineCol`.
        // Strip trailing colons FIRST (a log "/path:" or "Error:", and — critically — the standard
        // compiler-diagnostic form `path:line:col:` whose trailing `:` would otherwise defeat splitLineCol,
        // leaving `:line:col` baked into the resolved path so open/reveal fails), THEN split the numeric
        // `:line[:col]` suffix off the cleaned token so `path:line:col:` resolves as `.pathLineCol`.
        var cleaned = core
        while cleaned.hasSuffix(":") { cleaned.removeLast() }
        let (pathPart, suffix) = splitLineCol(cleaned)
        guard !pathPart.isEmpty, let shape = pathShape(pathPart) else { return nil }
        // Decorative prompt art (starship cats, powerline glyphs) frequently begins with `/` — e.g. the
        // `/ᐠ` in a `/ᐠ - ˕ -マ ≫` prompt — but is NOT a filesystem path. Such art is a SINGLE exotic glyph
        // after the root; a real path is structured. So drop a candidate only when it is BOTH single-segment
        // AND carries no ordinary path character (an ASCII letter or digit — dir/file names, extensions). A
        // multi-segment path (`/дом/данные`, `~/デスクトップ` — the `~`/`.`/`..` anchor counts as a segment,
        // and `/Users/名前/notes.txt`) or any path with an ASCII alnum still passes, so genuine non-Latin
        // paths keep their ⌘-hover underline; only a lone-glyph decoration is validate-then-dropped.
        let hasOrdinaryChar = pathPart.unicodeScalars.contains { $0.isASCIILetter || $0.isASCIIDigit }
        let segmentCount = pathPart.split(separator: "/", omittingEmptySubsequences: true).count
        guard hasOrdinaryChar || segmentCount >= 2 else { return nil }
        let hasLineCol = !suffix.isEmpty
        // A bare `dir/file` (no ./ ../ prefix) is only a link when it carries a line:col suffix —
        // otherwise prose like `and/or` or an SCP remote `git@host:org/repo` would falsely match.
        if shape == .bareRelative, !hasLineCol { return nil }
        let raw = pathPart + suffix
        return DetectedLink(
            row: row,
            colStart: cellStart,
            colEnd: cellStart + cellWidthOf(raw),
            kind: hasLineCol ? .pathLineCol : kind(for: shape),
            raw: raw,
            resolvedAbsolute: resolvePath(pathPart, shape: shape, cwd: cwd),
        )
    }

    private static func pathShape(_ path: String) -> PathShape? {
        if path.hasPrefix("/") { return .absolute }
        if path == "~" || path.hasPrefix("~/") { return .tilde }
        if path.hasPrefix("./") || path.hasPrefix("../") { return .relativeDot }
        if path.contains("/") { return .bareRelative }
        return nil
    }

    private static func kind(for shape: PathShape) -> DetectedLinkKind {
        switch shape {
        case .absolute: .absolutePath
        case .tilde: .tildePath
        case .relativeDot: .relativePath
        case .bareRelative: .relativePath
        }
    }

    /// Resolve to an absolute path PURELY (no `$HOME` / disk access). Tilde paths stay unresolved —
    /// `~` expansion needs the host `$HOME`, done host-side in the open/reveal action (WI-6/WI-7).
    private static func resolvePath(_ path: String, shape: PathShape, cwd: String?) -> String? {
        if shape == .absolute { return lexicallyNormalize(path) }
        if shape == .tilde { return nil } // ~ expansion is host-side, not pure
        // relativeDot / bareRelative: resolve against an absolute cwd, else leave unresolved.
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return lexicallyNormalize(cwd + "/" + path)
    }

    // MARK: - Suffix / scheme / path helpers

    /// Split a trailing `:line` or `:line:col` numeric suffix off `text`. Returns `(path, suffix)`
    /// where `suffix` keeps its leading colon (or `""`). A `12:34` time yields `("12", ":34")` — the
    /// `12` then fails the path-shape test, so times / `host:port` never light up.
    private static func splitLineCol(_ text: String) -> (path: String, suffix: String) {
        let chars = Array(text)

        // Start index of a ":<digits>" run that ENDS at `end`, else nil.
        func colonNumber(endingAt end: Int) -> Int? {
            var index = end
            var sawDigit = false
            while index > 0, chars[index - 1].isASCIIDigit {
                index -= 1
                sawDigit = true
            }
            if sawDigit, index > 0, chars[index - 1] == ":" { return index - 1 }
            return nil
        }

        guard let colStart = colonNumber(endingAt: chars.count) else { return (text, "") }
        if let lineStart = colonNumber(endingAt: colStart) {
            return (String(chars[0..<lineStart]), String(chars[lineStart...]))
        }
        return (String(chars[0..<colStart]), String(chars[colStart...]))
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter else { return false }
        for scalar in scheme.unicodeScalars where !scalar.isSchemeTail {
            return false
        }
        return true
    }

    private static func isSchemeAllowed(_ lowercasedScheme: String, _ policy: LinkSchemePolicy) -> Bool {
        if lowercasedScheme == "http" || lowercasedScheme == "https"
            || lowercasedScheme == "file" || lowercasedScheme == "mailto"
        {
            return true
        }
        switch policy {
        case .all:
            return true
        case let .custom(list):
            return list.contains { $0.lowercased() == lowercasedScheme }
        }
    }

    /// The filesystem path of a `file://…` URL: `file:///a/b` → `/a/b`, `file://host/a/b` → `/a/b`,
    /// percent-decoded so `%20` → space. `nil` when there is no path component.
    private static func fileURLPath(_ core: String) -> String? {
        guard let separator = core.range(of: "://") else { return nil }
        let afterScheme = String(core[separator.upperBound...])
        let path: String
        if afterScheme.hasPrefix("/") {
            path = afterScheme
        } else if let slash = afterScheme.firstIndex(of: "/") {
            path = String(afterScheme[slash...])
        } else {
            return nil
        }
        return path.removingPercentEncoding ?? path
    }

    /// Collapse `.` / `..` segments lexically (no disk access). An absolute input stays absolute and a
    /// `..` cannot escape the root; a relative input keeps leading `..` it cannot resolve.
    private static func lexicallyNormalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(segment))
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    // MARK: - Display cell width (East-Asian-wide aware)

    /// Display width of one grapheme cluster in terminal cells: 0 for a zero-width / combining base,
    /// 2 for an East-Asian-wide / fullwidth / emoji base, else 1.
    private static func cellWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if isZeroWidth(scalar) { return 0 }
        if isWide(scalar) { return 2 }
        return 1
    }

    private static func cellWidthOf(_ text: String) -> Int {
        var total = 0
        for character in text { total += cellWidth(of: character) }
        return total
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.value {
        case 0x0300...0x036F, // Combining Diacritical Marks
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x20D0...0x20FF, // Combining Diacritical Marks for Symbols
             0xFE20...0xFE2F: // Combining Half Marks
            return true
        default:
            return false
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, // Hangul Jamo
             0x2E80...0x303E, // CJK Radicals … CJK Symbols & Punctuation
             0x3041...0x33FF, // Hiragana, Katakana, … CJK compatibility
             0x3400...0x4DBF, // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xA000...0xA4CF, // Yi Syllables / Radicals
             0xAC00...0xD7A3, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFE30...0xFE4F, // CJK Compatibility Forms
             0xFF00...0xFF60, // Fullwidth Forms
             0xFFE0...0xFFE6, // Fullwidth signs
             0x1F300...0x1FAFF, // Emoji & pictographs
             0x20000...0x3FFFD: // CJK Unified Ideographs Extension B and beyond
            true
        default:
            false
        }
    }
}

// MARK: - Display-cell width (shared with E10 Hint Mode, WI-9)

public extension TerminalLinkDetector {
    /// Display width of `character` in terminal cells (0 zero-width, 2 East-Asian-wide / fullwidth / emoji,
    /// else 1) — the SAME convention this detector uses for `colStart ..< colEnd`. Exposed so the Hint Mode
    /// label assigner (``HintLabelAssigner``) maps its git-hash / IP / custom-pattern matches to cell columns
    /// that align with the link spans on a CJK row (single source of truth for the width).
    static func displayCellWidth(of character: Character) -> Int { cellWidth(of: character) }

    /// Display width of `text` in terminal cells — the sum over its grapheme clusters.
    static func displayCellWidth(of text: String) -> Int { cellWidthOf(text) }
}

// MARK: - Small ASCII scalar predicates (avoid Foundation locale surprises)

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { value >= 0x30 && value <= 0x39 }
    var isASCIILetter: Bool { (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) }
    /// A character permitted after the first in a URL scheme (`[A-Za-z0-9+.-]`).
    var isSchemeTail: Bool { isASCIILetter || isASCIIDigit || self == "+" || self == "-" || self == "." }
}

private extension Character {
    var isASCIIDigit: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return scalar.isASCIIDigit
    }
}
