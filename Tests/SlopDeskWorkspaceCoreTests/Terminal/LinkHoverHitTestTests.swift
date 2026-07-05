import CoreGraphics
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

/// E10 WI-5 (ES-E10-4): the PURE ⌘-hover hit-test
/// ``TerminalViewModel/hoveredLinkPath(rows:cwd:schemes:metrics:pointX:pointY:)`` — the headless heart of the
/// status-bar full-path preview (`full-path-hover.png`). The macOS renderer is the compile-only actuator (the
/// real surface hangs without a window server — the hang-safety rule), so the cell math + link resolution are
/// pinned HERE.
///
/// None of these is tautological: each expected path is hand-written, and each probe point is hand-computed
/// from `column = (pointX − originX) / cellWidth`, `row = (pointY − originY) / cellHeight` against the detector's
/// known column span — NOT re-derived from the method under test. Specific regressions each fail a specific
/// case: an inclusive `colEnd` (`<=` instead of `<`) fails ``testColumnEndIsExclusive``; a row/column axis swap
/// fails ``testWrongRowIsNotAHit``; dropping the cwd resolution fails ``testRelativePathResolvesAgainstCwd``;
/// returning `resolvedAbsolute` for a URL (which has none) fails ``testUrlFallsBackToRawText``.
final class LinkHoverHitTestTests: XCTestCase {
    private func metrics(cellWidth: CGFloat = 10, cellHeight: CGFloat = 20) -> TerminalCellMetrics {
        TerminalCellMetrics(cellWidth: cellWidth, cellHeight: cellHeight, cols: 80, rows: 24)
    }

    private func hover(
        _ rows: [String],
        cwd: String? = nil,
        schemes: LinkSchemePolicy = .all,
        metrics: TerminalCellMetrics? = nil,
        x: CGFloat,
        y: CGFloat,
    ) -> String? {
        TerminalViewModel.hoveredLinkPath(
            rows: rows,
            cwd: cwd,
            schemes: schemes,
            metrics: metrics ?? self.metrics(),
            pointX: x,
            pointY: y,
        )
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

    /// Degenerate metrics (zero cell size) can never divide → no hit, never a trap.
    func testDegenerateMetricsReturnNil() {
        let zero = TerminalCellMetrics(cellWidth: 0, cellHeight: 0, cols: 80, rows: 24)
        XCTAssertNil(hover(["see /usr/local/bin"], metrics: zero, x: 65, y: 5))
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
}
