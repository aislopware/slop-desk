import XCTest
@testable import AislopdeskWorkspaceCore

/// E10 WI-1 (ES-E10-1 / ES-E10-2): the pure terminal path/URL/link detector. These pin every supported
/// form (absolute / tilde / relative / `path:line:col` / `scheme://` / `file://` / `mailto:`), the cwd
/// resolution, the East-Asian-wide cell-column mapping (the jump-to
/// spec confirms CJK), the scheme policy, the anti-hang column bound, and the validate-then-drop of
/// noise. Each case is revert-to-confirm-fail: it fails on a detector that drops the form, mis-columns
/// a wide glyph, ignores the bound, or over-matches prose.
final class TerminalLinkDetectorTests: XCTestCase {
    private func detect(
        _ row: String,
        cwd: String? = nil,
        schemes: LinkSchemePolicy = .all,
        maxScanColumns: Int = 4096,
    ) -> [DetectedLink] {
        TerminalLinkDetector.detect(rows: [row], cwd: cwd, schemes: schemes, maxScanColumns: maxScanColumns)
    }

    private func only(
        _ row: String,
        cwd: String? = nil,
        schemes: LinkSchemePolicy = .all,
    ) -> DetectedLink? {
        let links = detect(row, cwd: cwd, schemes: schemes)
        XCTAssertEqual(links.count, 1, "expected exactly one detection in \(row.debugDescription), got \(links)")
        return links.first
    }

    // MARK: - Forms

    /// Absolute `/…` path: kind + exact cell columns + identity resolution.
    func testAbsolutePathWithColumns() {
        let link = only("open /usr/local/bin")
        XCTAssertEqual(link?.kind, .absolutePath)
        XCTAssertEqual(link?.raw, "/usr/local/bin")
        XCTAssertEqual(link?.colStart, 5) // after "open " (5 cells)
        XCTAssertEqual(link?.colEnd, 19) // 5 + 14
        XCTAssertEqual(link?.resolvedAbsolute, "/usr/local/bin")
    }

    /// Tilde `~/…` path: detected, but NOT resolved — `~` needs the host `$HOME`, which a pure,
    /// environment-free detector must not read (expanded host-side by the open/reveal action).
    func testTildePathDetectedButUnresolved() {
        let link = only("~/project/file.swift")
        XCTAssertEqual(link?.kind, .tildePath)
        XCTAssertEqual(link?.raw, "~/project/file.swift")
        XCTAssertNil(link?.resolvedAbsolute, "tilde expansion is host-side, not pure")
    }

    /// `./` and `../` relative paths resolve against an absolute cwd, collapsing `.`/`..` lexically.
    func testRelativePathsResolveAgainstCwd() {
        let here = only("./src/lib.rs", cwd: "/Users/me/project")
        XCTAssertEqual(here?.kind, .relativePath)
        XCTAssertEqual(here?.resolvedAbsolute, "/Users/me/project/src/lib.rs")

        let up = only("../config/foo.toml", cwd: "/Users/me/project")
        XCTAssertEqual(up?.kind, .relativePath)
        XCTAssertEqual(up?.resolvedAbsolute, "/Users/me/config/foo.toml")
    }

    /// A relative path with no cwd is still DETECTED, just unresolved (detection ⟂ resolution).
    func testRelativePathDetectedWithoutCwd() {
        let link = only("./src/lib.rs", cwd: nil)
        XCTAssertEqual(link?.kind, .relativePath)
        XCTAssertNil(link?.resolvedAbsolute)
    }

    /// `path:line` and `path:line:col` (compiler/linter output) → `.pathLineCol`; the raw keeps the
    /// suffix, the resolved path drops it. Works for the spec's prefix-less `src/lib.rs:42` too.
    func testPathLineColForms() {
        let line = only("src/lib.rs:42", cwd: "/w")
        XCTAssertEqual(line?.kind, .pathLineCol)
        XCTAssertEqual(line?.raw, "src/lib.rs:42")
        XCTAssertEqual(line?.resolvedAbsolute, "/w/src/lib.rs")

        let lineCol = only("src/lib.rs:42:5", cwd: "/w")
        XCTAssertEqual(lineCol?.kind, .pathLineCol)
        XCTAssertEqual(lineCol?.raw, "src/lib.rs:42:5")
        XCTAssertEqual(lineCol?.resolvedAbsolute, "/w/src/lib.rs")

        let absolute = only("/usr/foo.c:42")
        XCTAssertEqual(absolute?.kind, .pathLineCol)
        XCTAssertEqual(absolute?.raw, "/usr/foo.c:42")
        XCTAssertEqual(absolute?.resolvedAbsolute, "/usr/foo.c")
    }

    /// `http`/`https` URLs are always detected as `.url`.
    func testHttpURLs() {
        XCTAssertEqual(only("https://example.com/a")?.kind, .url)
        XCTAssertEqual(only("http://example.com")?.kind, .url)
        XCTAssertEqual(only("http://example.com")?.resolvedAbsolute, nil)
    }

    /// `file://…` → `.fileURL`, surfacing the percent-decoded filesystem path for reveal.
    func testFileURLSurfacesDecodedPath() {
        let link = only("file:///Users/me/My%20File.txt")
        XCTAssertEqual(link?.kind, .fileURL)
        XCTAssertEqual(link?.raw, "file:///Users/me/My%20File.txt")
        XCTAssertEqual(link?.resolvedAbsolute, "/Users/me/My File.txt")
    }

    /// `mailto:` is always on regardless of the scheme policy; a bare `mailto:` (no address) drops.
    func testMailtoAlwaysDetected() {
        XCTAssertEqual(only("mailto:abner@example.com", schemes: .custom([]))?.kind, .url)
        XCTAssertTrue(detect("mailto:", schemes: .all).isEmpty, "bare mailto: has no address → drop")
    }

    // MARK: - CJK cell columns (the wide-glyph mapping)

    /// A path after CJK text starts at the right CELL column (each wide glyph = 2 cells), so the WI-2
    /// geometry seam lands the underline correctly. A naive Character-offset detector would say 4, not 7.
    func testCJKWideGlyphsAdvanceCellColumns() {
        let link = only("日本語 /usr/local/bin/foo")
        XCTAssertEqual(link?.kind, .absolutePath)
        XCTAssertEqual(link?.colStart, 7, "3 wide glyphs (6 cells) + 1 space = cell 7")
        XCTAssertEqual(link?.colEnd, 7 + "/usr/local/bin/foo".count)
    }

    // MARK: - Scheme policy gating

    /// `.all` underlines any `scheme://`; `.custom` restricts to the list, but http(s)/file/mailto
    /// stay always-on. A disallowed scheme is dropped, not reinterpreted as a path.
    func testSchemePolicyGating() {
        XCTAssertEqual(only("myapp://open/thing", schemes: .all)?.kind, .url)

        let custom = LinkSchemePolicy.custom(["codex", "ssh"])
        XCTAssertEqual(only("codex://session/1", schemes: custom)?.kind, .url)
        XCTAssertTrue(detect("myapp://open/thing", schemes: custom).isEmpty, "scheme not in custom list → drop")
        XCTAssertEqual(only("https://example.com", schemes: custom)?.kind, .url, "https always on")
        XCTAssertEqual(only("file:///a/b", schemes: custom)?.kind, .fileURL, "file always on")
    }

    // MARK: - Validate-then-drop / noise

    /// A bare `dir/file` (no ./ ../ prefix, no line:col) is NOT a link — otherwise prose like `and/or`,
    /// times (`12:34:56`), and `host:port` would all light up. Adding a line:col makes it a real match.
    func testNoiseDoesNotMatchButLineColRescues() {
        XCTAssertTrue(detect("choose and/or neither").isEmpty)
        XCTAssertTrue(detect("started at 12:34:56 today").isEmpty)
        XCTAssertTrue(detect("listening on host:8080").isEmpty)
        XCTAssertTrue(detect("ratio 3:4 and version 1.2.3").isEmpty)
        XCTAssertTrue(detect("clone git@github.com:org/repo.git").isEmpty, "SCP remote is not a path")

        let rescued = only("warning at src/lib.rs:42", cwd: "/w")
        XCTAssertEqual(rescued?.kind, .pathLineCol)
        XCTAssertEqual(rescued?.raw, "src/lib.rs:42")
    }

    /// Decorative prompt art (starship cats, powerline glyphs) is a SINGLE exotic glyph after the root —
    /// `/ᐠ` in a `/ᐠ - ˕ -マ ≫` prompt — and must not be underlined on ⌘-hover. A candidate is dropped
    /// only when it is single-segment AND carries no ordinary (ASCII alnum) char; a structured path — any
    /// ASCII alnum, OR ≥2 segments — still matches, so genuine non-Latin paths keep the affordance.
    func testDecorativePromptArtNotDetectedAsPath() {
        // Dropped: lone exotic glyph after the root (single segment, no ordinary char).
        XCTAssertTrue(detect("/ᐠ - ˕ -マ ≫").isEmpty, "a starship cat prompt is not a path")
        XCTAssertTrue(detect("aislopdesk on  main via  v6.3.2").isEmpty, "prompt context line is not a path")
        XCTAssertTrue(detect("/≫").isEmpty, "a lone exotic glyph after / is not a path")
        XCTAssertTrue(detect("/ᐠ:42").isEmpty, "a lone exotic glyph + fake :line suffix is still not a path")

        // Kept: any ASCII alnum present.
        XCTAssertEqual(only("/Users/名前/notes.txt")?.kind, .absolutePath)
        XCTAssertEqual(only("/usr/bin/foo")?.kind, .absolutePath)
        XCTAssertEqual(only("~/プロジェクト/main.swift")?.kind, .tildePath)
        // Kept: multi-segment paths even with NO ASCII anywhere (real localized/non-Latin directories) —
        // the ≥2-segment structure (the `~` / leading `/` anchor counts) rescues them from the art guard.
        XCTAssertEqual(only("/дом/данные")?.kind, .absolutePath)
        XCTAssertEqual(only("~/デスクトップ")?.kind, .tildePath)
        XCTAssertEqual(only("~/مجلد")?.kind, .tildePath)
    }

    /// Wrapping brackets / quotes and trailing sentence punctuation are stripped, and `colStart`
    /// advances past the leading bracket — but the `:line:col` colon survives the trailing trim.
    func testWrappingPunctuationTrimmed() {
        let link = only("see (https://example.com).")
        XCTAssertEqual(link?.raw, "https://example.com")
        XCTAssertEqual(link?.colStart, 5) // "see " = 4, "(" = +1
        XCTAssertEqual(link?.colEnd, 5 + "https://example.com".count)

        let path = only("at \"./a/b.rs:7\"", cwd: "/w")
        XCTAssertEqual(path?.kind, .pathLineCol)
        XCTAssertEqual(path?.raw, "./a/b.rs:7")
        XCTAssertEqual(path?.resolvedAbsolute, "/w/a/b.rs")
    }

    /// The standard clang/swiftc/gcc diagnostic form `path:line:col:` (trailing colon before ` error:`)
    /// must resolve as `.pathLineCol` with the `:line:col` split OFF the resolved path — otherwise ⌘click
    /// open/reveal dispatches a path literally named `main.swift:3:14` and silently fails. FAILS on the
    /// pre-fix order (splitLineCol ran before the trailing-colon strip, so `:3:14` stayed baked into
    /// `raw` / `resolvedAbsolute` and the kind was `.absolutePath`).
    func testCompilerDiagnosticTrailingColonSplitsLineCol() {
        let abs = only("/Users/me/main.swift:3:14:")
        XCTAssertEqual(abs?.kind, .pathLineCol)
        XCTAssertEqual(abs?.raw, "/Users/me/main.swift:3:14")
        XCTAssertEqual(abs?.resolvedAbsolute, "/Users/me/main.swift", "the :line:col suffix is dropped from the path")

        // The same shape after the whitespace-split of a full `path:line:col: error: …` line.
        let onlyLoc = detect("/Users/me/main.swift:3:14: error: cannot find 'x' in scope").first
        XCTAssertEqual(onlyLoc?.kind, .pathLineCol)
        XCTAssertEqual(onlyLoc?.resolvedAbsolute, "/Users/me/main.swift")

        // Relative + line-only trailing colon (`path:line:`) also splits.
        let rel = only("src/lib.rs:42:", cwd: "/w")
        XCTAssertEqual(rel?.kind, .pathLineCol)
        XCTAssertEqual(rel?.raw, "src/lib.rs:42")
        XCTAssertEqual(rel?.resolvedAbsolute, "/w/src/lib.rs")

        // A trailing-colon-only log path (no numbers) still resolves as a plain path (regression guard for
        // the reordered strip).
        XCTAssertEqual(only("/var/log/system.log:")?.kind, .absolutePath)
        XCTAssertEqual(only("/var/log/system.log:")?.raw, "/var/log/system.log")
    }

    /// A URL whose path legitimately ends in a BALANCED close paren (Wikipedia disambiguation, MSDN, a
    /// `#Lnn)` prose anchor) keeps it — the trailing-paren trim must balance against an opener inside the
    /// token. FAILS on the pre-fix unconditional strip (which dropped the final `)`, truncating both the
    /// underline and the opened URL).
    func testBalancedTrailingParenSurvivesInURL() {
        let wiki = only("https://en.wikipedia.org/wiki/Swift_(programming_language)")
        XCTAssertEqual(wiki?.kind, .url)
        XCTAssertEqual(wiki?.raw, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        XCTAssertEqual(wiki?.colEnd, "https://en.wikipedia.org/wiki/Swift_(programming_language)".count)

        // An UNMATCHED wrapping paren (prose) is still stripped — the balancing only keeps matched pairs.
        let wrapped = only("see (https://example.com)")
        XCTAssertEqual(wrapped?.raw, "https://example.com", "the wrapping (unbalanced) paren is trimmed")

        // A wrapped URL that itself contains a balanced pair: the outer wrapping close is unbalanced (its
        // opener was leading-trimmed) so it is stripped, but the inner balanced pair survives.
        let both = only("(https://en.wikipedia.org/wiki/Swift_(programming_language))")
        XCTAssertEqual(both?.raw, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
    }

    // MARK: - Bounds

    /// The per-row CELL scan is capped: a path that begins past `maxScanColumns` is never reached, so a
    /// pathological long line cannot hang. Removing the bound would surface the trailing path.
    func testMaxScanColumnsBoundsTheScan() {
        let far = String(repeating: " ", count: 5000) + "/usr/bin/foo"
        XCTAssertTrue(detect(far, maxScanColumns: 4096).isEmpty, "path past the column cap is not scanned")

        // The same path within a small explicit budget IS found (the bound gates position, not content).
        XCTAssertEqual(detect("/usr/bin/foo", maxScanColumns: 32).first?.kind, .absolutePath)
    }

    /// Row index and left-to-right ordering across multiple matches per row.
    func testRowIndexAndMultipleMatches() {
        let rows = ["see /a/b and https://x.com", "/c/d"]
        let links = TerminalLinkDetector.detect(rows: rows, cwd: nil, schemes: .all)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].kind, .absolutePath)
        XCTAssertEqual(links[0].row, 0)
        XCTAssertEqual(links[0].raw, "/a/b")
        XCTAssertEqual(links[1].kind, .url)
        XCTAssertEqual(links[1].row, 0)
        XCTAssertLessThan(links[0].colStart, links[1].colStart, "left-to-right order")
        XCTAssertEqual(links[2].kind, .absolutePath)
        XCTAssertEqual(links[2].row, 1)
        XCTAssertEqual(links[2].raw, "/c/d")
    }

    /// An empty rows array / zero budget is total and inert (validate-then-drop).
    func testDegenerateInputsAreInert() {
        XCTAssertTrue(TerminalLinkDetector.detect(rows: [], cwd: nil, schemes: .all).isEmpty)
        XCTAssertTrue(detect("/usr/bin/foo", maxScanColumns: 0).isEmpty)
    }
}
