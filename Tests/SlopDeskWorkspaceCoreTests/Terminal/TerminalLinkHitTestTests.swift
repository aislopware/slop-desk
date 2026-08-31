import XCTest
@testable import SlopDeskWorkspaceCore

/// ``TerminalLinkHitTest`` — the one point → detected-link hit-test BOTH renderers run: the Mac's ⌘-hover,
/// ⌘click and right-click menu, and the phone's long-press menu. The renderers themselves are compile-only
/// actuators (the real surface hangs without a window server — the hang-safety rule), and until this file
/// was retargeted the copy production ran was the one inside the embedder's `#if os(macOS)`, which nothing
/// here could call. The math is pinned HERE now, once, for both.
///
/// ## What this suite is, since the rule moved
///
/// The rule is `rust/slopdesk-terminal`'s `link_hit` and has its own cases there. This file did not follow
/// it and is not a mirror of it: what it drives is the whole path a caller actually travels — detect the
/// rows through one door, hand the spans to another, and read the record the index names — so it is the
/// BOUNDARY's own test in the sense `docs/55` §4b's `apply_intent` paragraph means. Several of its cases
/// (the cwd resolution, the URL's missing `resolvedAbsolute`, the scheme policy) are about which link came
/// back rather than about which span was nearest, and have no counterpart on the Rust side at all.
///
/// None of these is tautological: each expected path is hand-written, and each probe point is hand-computed
/// from `column = (pointX − originX) / cellWidth`, `row = (pointY − originY) / cellHeight` against the detector's
/// known column span — NOT re-derived from the method under test. Specific regressions each fail a specific
/// case: an inclusive `colEnd` (`<=` instead of `<`) fails ``testColumnEndIsExclusive``; a row/column axis swap
/// fails ``testWrongRowIsNotAHit``; dropping the cwd resolution fails ``testRelativePathResolvesAgainstCwd``;
/// returning `resolvedAbsolute` for a URL (which has none) fails ``testUrlFallsBackToRawText``; a span list
/// marshalled out of step with the array it indexes fails ``testTheAnswerIndexesTheCallersOwnArray``.
///
/// The SLOP cases are the phone's half of it — a fingertip is not a cursor — and each one is written so a
/// slop that leaked into the pointer's reading (`slop: 0` is the default and must stay exact) fails
/// ``testAPointerGetsNoSlopAtAll``.
final class TerminalLinkHitTestTests: XCTestCase {
    private func metrics(cellWidth: CGFloat = 10, cellHeight: CGFloat = 20) -> TerminalCellMetrics {
        TerminalCellMetrics(cellWidth: cellWidth, cellHeight: cellHeight, cols: 80, rows: 24)
    }

    /// The hit-test as its callers spell it: detect the rows, ask what is under the point, and read the link
    /// the way the hover does (`resolvedAbsolute ?? raw` — the fallback for a `~`-path or a bare URL).
    private func hover(
        _ rows: [String],
        cwd: String? = nil,
        schemes: LinkSchemePolicy = .all,
        metrics: TerminalCellMetrics? = nil,
        x: CGFloat,
        y: CGFloat,
        slop: CGFloat = 0,
    ) -> String? {
        TerminalLinkHitTest.link(
            in: TerminalLinkDetector.detect(rows: rows, cwd: cwd, schemes: schemes),
            metrics: metrics ?? self.metrics(),
            pointX: x,
            pointY: y,
            slop: slop,
        )
        .map { $0.resolvedAbsolute ?? $0.raw }
    }

    // MARK: - A point inside a detected span resolves

    /// `"see /usr/local/bin"` — the absolute path occupies cells 4..<18. A point in cell 6 (x ∈ [60,70))
    /// returns the lexically-normalized absolute path.
    func testPointOverAbsolutePathReturnsResolvedAbsolute() {
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 65, y: 5), "/usr/local/bin")
    }

    /// The FIRST cell of the span (cell 4, x ∈ [40,50)) is a hit (inclusive lower bound).
    func testColumnStartIsInclusive() {
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 45, y: 5), "/usr/local/bin")
    }

    // MARK: - Boundaries (column / row)

    /// `colEnd` is EXCLUSIVE: a point in the cell AT `colEnd` (cell 18, x ∈ [180,190)) is the next cell, not the
    /// link — an inclusive (`<=`) hit-test would wrongly match it.
    func testColumnEndIsExclusive() {
        XCTAssertNil(hover(["see /usr/local/bin"], x: 185, y: 5))
    }

    /// A point in the cell just BEFORE the span (cell 3, x ∈ [30,40)) is not a hit.
    func testColumnBeforeSpanIsNotAHit() {
        XCTAssertNil(hover(["see /usr/local/bin"], x: 35, y: 5))
    }

    /// The right column but the WRONG row (row 1, y ∈ [20,40)) is not a hit — a row/col axis swap would match.
    func testWrongRowIsNotAHit() {
        XCTAssertNil(hover(["see /usr/local/bin"], x: 65, y: 25))
    }

    /// A link on row 1 is hit only when the point's row maps to 1 (y ∈ [20,40)).
    func testSecondRowLinkHitOnItsRow() {
        let rows = ["nothing here", "go /opt/data"]
        // "/opt/data" starts at cell 3 on row 1; cell 5 → x ∈ [50,60), row 1 → y ∈ [20,40).
        XCTAssertEqual(hover(rows, x: 55, y: 25), "/opt/data")
        // The SAME column on row 0 is over plain prose → no hit.
        XCTAssertNil(hover(rows, x: 55, y: 5))
    }

    // MARK: - Resolution variants

    /// A relative `./src/lib.rs:42` resolves against an absolute cwd (the line:col suffix is dropped from the
    /// resolved path). Without the cwd join the resolved path would be `nil` and the hover would fall back to
    /// the raw `./src/lib.rs:42`.
    func testRelativePathResolvesAgainstCwd() {
        // "edit ./src/lib.rs:42" — the token starts at cell 5; cell 7 → x ∈ [70,80).
        XCTAssertEqual(
            hover(["edit ./src/lib.rs:42"], cwd: "/home/me", x: 75, y: 5),
            "/home/me/src/lib.rs",
        )
    }

    /// A URL has no `resolvedAbsolute`, so the hover falls back to the RAW matched text (never an empty string).
    func testUrlFallsBackToRawText() {
        // "open https://example.com" — the token starts at cell 5; cell 8 → x ∈ [80,90).
        XCTAssertEqual(hover(["open https://example.com"], x: 85, y: 5), "https://example.com")
    }

    // MARK: - Wide glyphs + degenerate geometry

    /// A leading CJK run shifts the link's start column by TWO cells per glyph — the hit-test must use the
    /// display-cell columns the detector emits, not the character offset.
    func testWideGlyphLeadingRunShiftsHitColumn() {
        // "你好 /tmp/x": 你好 = 4 cells, space = cell 4, "/tmp/x" starts at cell 5; cell 6 → x ∈ [60,70).
        XCTAssertEqual(hover(["你好 /tmp/x"], x: 65, y: 5), "/tmp/x")
        // A point over the wide glyph itself (cell 1, x ∈ [10,20)) is over no link.
        XCTAssertNil(hover(["你好 /tmp/x"], x: 15, y: 5))
    }

    /// Degenerate metrics (zero cell size) can never divide → no hit, never a trap. Not even with a slop:
    /// a grid with no cells has no spans to be near.
    func testDegenerateMetricsReturnNil() {
        let zero = TerminalCellMetrics(cellWidth: 0, cellHeight: 0, cols: 80, rows: 24)
        XCTAssertNil(hover(["see /usr/local/bin"], metrics: zero, x: 65, y: 5))
        XCTAssertNil(hover(["see /usr/local/bin"], metrics: zero, x: 65, y: 5, slop: 40))
    }

    /// A point above/left of the viewport origin (negative-mapped cell) is dropped, not force-floored to 0.
    func testPointBeforeOriginReturnsNil() {
        let m = TerminalCellMetrics(cellWidth: 10, cellHeight: 20, cols: 80, rows: 24, originX: 50, originY: 40)
        // x below originX → guarded out.
        XCTAssertNil(hover(["see /usr/local/bin"], metrics: m, x: 20, y: 60))
    }

    /// The scheme policy is honoured: a non-always-on `ssh://` URL is invisible under a `.custom([])` policy, so
    /// hovering its cells returns nil.
    func testSchemePolicyGatesUrlHover() {
        // "go ssh://host/x" — token starts at cell 3; cell 5 → x ∈ [50,60).
        XCTAssertNil(hover(["go ssh://host/x"], schemes: .custom([]), x: 55, y: 5))
        // Same cell, `.all` policy → the URL is detected and its raw text returned.
        XCTAssertEqual(hover(["go ssh://host/x"], schemes: .all, x: 55, y: 5), "ssh://host/x")
    }

    // MARK: - The slop (a fingertip is not a cursor)

    /// THE DEFAULT IS EXACT. Every point the pointer's reading rejects above must still be rejected with the
    /// default slop, and this is the one that would silently loosen if a slop were ever given a non-zero
    /// default: cell 18 is one cell past an exclusive `colEnd`, which is a MISS for a mouse and a hit for a
    /// finger.
    func testAPointerGetsNoSlopAtAll() {
        XCTAssertNil(hover(["see /usr/local/bin"], x: 185, y: 5))
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 185, y: 5, slop: 15), "/usr/local/bin")
    }

    /// The slop reaches PAST the span's end and stops: the rect ends at x = 180, so 190 is 10 points off
    /// (inside a 15pt slop) and 200 is 20 (outside it). A slop that widened by a whole cell regardless of the
    /// number would pass both.
    func testSlopReachesJustPastTheSpanAndThenFallsOff() {
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 190, y: 5, slop: 15), "/usr/local/bin")
        XCTAssertNil(hover(["see /usr/local/bin"], x: 200, y: 5, slop: 15))
    }

    /// …and BEFORE the span's start, symmetrically: the rect begins at x = 40, so 30 is 10 points off and 20
    /// is 20. (Both probes are in cells 2 and 3, which the exact pass rejects.)
    func testSlopReachesBeforeTheSpanToo() {
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 30, y: 5, slop: 15), "/usr/local/bin")
        XCTAssertNil(hover(["see /usr/local/bin"], x: 20, y: 5, slop: 15))
    }

    /// A point ABOVE the viewport origin is dropped by the exact pass (it maps to no cell at all) and is
    /// still eligible for the slop — which is precisely the finger that landed a hair above the first row.
    func testSlopReachesUpIntoTheFirstRowFromAboveTheOrigin() {
        XCTAssertNil(hover(["see /usr/local/bin"], x: 65, y: -5))
        XCTAssertEqual(hover(["see /usr/local/bin"], x: 65, y: -5, slop: 15), "/usr/local/bin")
    }

    /// Two spans on one row, and the point falls in the gap between them: the NEARER one wins, both ways
    /// round. A slop that returned the first candidate within range would answer `/tmp/a` for both.
    func testSlopPicksTheNearerOfTwoSpansOnOneRow() {
        // "/tmp/a    /tmp/b": cells 0..<6 → x ∈ [0,60), cells 10..<16 → x ∈ [100,160).
        let rows = ["/tmp/a    /tmp/b"]
        XCTAssertEqual(hover(rows, x: 70, y: 5, slop: 35), "/tmp/a", "10 points off A, 30 off B")
        XCTAssertEqual(hover(rows, x: 90, y: 5, slop: 35), "/tmp/b", "30 points off A, 10 off B")
    }

    /// A ROW is the coarser mistake a finger makes, so the vertical distance is compared first: the point sits
    /// in the empty row between two spans that share the same columns, and the nearer ROW wins.
    func testSlopComparesTheRowBeforeTheColumn() {
        let rows = ["/tmp/a", "", "/tmp/b"]
        // Row 0 ends at y = 20, row 2 begins at y = 40; both spans cover cell 2 (x ∈ [20,30)), so only the
        // vertical distance can decide.
        XCTAssertEqual(hover(rows, x: 25, y: 32, slop: 15), "/tmp/b", "8 points below row 2, 12 above row 0")
        XCTAssertEqual(hover(rows, x: 25, y: 28, slop: 15), "/tmp/a", "8 points under row 0, 12 over row 2")
    }

    /// A generous slop NEVER re-aims a point that is already ON a span. Both probes sit inside their own
    /// span's cells with a neighbour well within reach, and each must answer with the span it is on — the
    /// exact pass runs first, so a slop can only ever add an answer where there was none.
    func testAGenerousSlopNeverRedirectsAPointThatIsAlreadyOnASpan() {
        // "/tmp/a /tmp/b": cells 0..<6 and 7..<13 (one space at cell 6 — no space and it is one token).
        let rows = ["/tmp/a /tmp/b"]
        XCTAssertEqual(hover(rows, x: 25, y: 5, slop: 40), "/tmp/a", "cell 2 is inside /tmp/a")
        XCTAssertEqual(hover(rows, x: 75, y: 5, slop: 40), "/tmp/b", "cell 7 is inside /tmp/b")
    }

    // MARK: - The marshalling half (what this file owns now that the rule is Rust's)

    /// The cell entry answers a PAIR plus a presence flag, never a sentinel row: `(0, 0)` is the most
    /// ordinary landing a point has, so a door that encoded "no cell" as a number would have to pick a
    /// magic one. A flag lost on the way back would make every refusal read as the viewport's first cell.
    func testTheCellEntryAnswersAPairAndAFlagRatherThanAMagicRow() {
        let live = metrics()
        XCTAssertEqual(TerminalLinkHitTest.cell(metrics: live, pointX: 65, pointY: 25)?.row, 1)
        XCTAssertEqual(TerminalLinkHitTest.cell(metrics: live, pointX: 65, pointY: 25)?.column, 6)
        XCTAssertEqual(TerminalLinkHitTest.cell(metrics: live, pointX: 0, pointY: 0)?.row, 0)
        XCTAssertEqual(TerminalLinkHitTest.cell(metrics: live, pointX: 0, pointY: 0)?.column, 0)
        XCTAssertNil(TerminalLinkHitTest.cell(metrics: live, pointX: -1, pointY: 5), "left of the origin")
        let zero = TerminalCellMetrics(cellWidth: 0, cellHeight: 0, cols: 80, rows: 24)
        XCTAssertNil(TerminalLinkHitTest.cell(metrics: zero, pointX: 65, pointY: 5), "nothing can divide")
    }

    /// What comes back across the boundary is an INDEX, and this side subscripts the array it already
    /// holds — so the record returned is the caller's OWN, `nil` `resolvedAbsolute` and all, not one
    /// rebuilt on the far side. Spans marshalled out of step with the array (a triple dropped, a field
    /// transposed) would answer with a neighbouring link rather than with nothing.
    func testTheAnswerIndexesTheCallersOwnArray() {
        let links = [
            DetectedLink(row: 0, colStart: 0, colEnd: 3, kind: .absolutePath, raw: "/a", resolvedAbsolute: "/a"),
            DetectedLink(row: 1, colStart: 0, colEnd: 3, kind: .absolutePath, raw: "/b", resolvedAbsolute: "/b"),
            DetectedLink(row: 2, colStart: 4, colEnd: 9, kind: .url, raw: "ssh://c", resolvedAbsolute: nil),
        ]
        // Row 2 → y ∈ [40,60); cells 4..<9 → x ∈ [40,90).
        let hit = TerminalLinkHitTest.link(in: links, metrics: metrics(), pointX: 45, pointY: 45)
        XCTAssertEqual(hit?.raw, "ssh://c")
        XCTAssertNil(hit?.resolvedAbsolute, "a URL has none, and nothing on the way back could invent one")
        XCTAssertNil(
            TerminalLinkHitTest.link(in: [], metrics: metrics(), pointX: 45, pointY: 45, slop: 40),
            "an empty list lends no buffer at all, at any slop",
        )
    }
}
