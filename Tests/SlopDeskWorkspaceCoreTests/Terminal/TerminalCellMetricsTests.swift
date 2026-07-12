import CoreGraphics
import SlopDeskTerminal
import XCTest

/// Pins ``TerminalCellMetrics/rect(row:colStart:colEnd:)`` — the
/// SINGLE source of truth the ⌘-hold link underline and the Hint Mode labels both map a
/// detected `(row, colStart ..< colEnd)` cell span through. The live `GhosttySurface` conformer is
/// compile-only (the real surface hangs without a window server — the hang-safety rule), so the pure
/// rect arithmetic is pinned HERE.
///
/// None of these assertions is tautological: every expected `CGRect` is hand-computed from the spec
/// formula (`x = originX + cellWidth*colStart`, `y = originY + cellHeight*row`,
/// `width = cellWidth*(colEnd − colStart)`) with explicit literal numbers, NOT re-derived from the
/// method under test. Specific bugs each fail a specific case: a row/col axis swap (mapping `colStart`
/// to `y`) fails ``testRowMapsToYAndColumnMapsToX``; computing the width from `colEnd` instead of the
/// span `(colEnd − colStart)` fails ``testWideSpanWidthUsesSpanNotEndColumn``; dropping the origin
/// offset fails ``testOriginOffsetIsApplied``.
final class TerminalCellMetricsTests: XCTestCase {
    func testBasicSpanWithOriginMapsToExpectedRect() {
        let metrics = TerminalCellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            cols: 80,
            rows: 24,
            originX: 10,
            originY: 20,
        )
        // x = 10 + 8*3 = 34 ; y = 20 + 16*2 = 52 ; width = 8*(7−3) = 32 ; height = 16.
        let rect = metrics.rect(row: 2, colStart: 3, colEnd: 7)
        XCTAssertEqual(rect, CGRect(x: 34, y: 52, width: 32, height: 16))
    }

    func testRowMapsToYAndColumnMapsToX() {
        let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)
        // A pure column step advances X only (origin defaults to 0): x = 8, y = 0.
        XCTAssertEqual(
            metrics.rect(row: 0, colStart: 1, colEnd: 2),
            CGRect(x: 8, y: 0, width: 8, height: 16),
        )
        // A pure row step advances Y only: x = 0, y = 16. A swap (col→y / row→x) breaks both.
        XCTAssertEqual(
            metrics.rect(row: 1, colStart: 0, colEnd: 1),
            CGRect(x: 0, y: 16, width: 8, height: 16),
        )
    }

    func testWideSpanWidthUsesSpanNotEndColumn() {
        let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)
        // A 2-cell (East-Asian-wide) span at columns 5..<7: width = 8*(7−5) = 16, NOT 8*7 = 56.
        let rect = metrics.rect(row: 0, colStart: 5, colEnd: 7)
        XCTAssertEqual(rect, CGRect(x: 40, y: 0, width: 16, height: 16))
    }

    func testFractionalCellSizeIsPreserved() {
        // HiDPI point sizes are fractional (pixels ÷ backing scale); the rect must carry them exactly.
        let metrics = TerminalCellMetrics(cellWidth: 9.5, cellHeight: 20.5, cols: 80, rows: 24)
        XCTAssertEqual(
            metrics.rect(row: 3, colStart: 0, colEnd: 4),
            CGRect(x: 0, y: 61.5, width: 38, height: 20.5),
        )
    }

    func testOriginOffsetIsApplied() {
        let zeroOrigin = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)
        let shifted = TerminalCellMetrics(
            cellWidth: 8,
            cellHeight: 16,
            cols: 80,
            rows: 24,
            originX: 100,
            originY: 200,
        )
        let span = (row: 1, colStart: 2, colEnd: 3)
        let base = zeroOrigin.rect(row: span.row, colStart: span.colStart, colEnd: span.colEnd)
        let moved = shifted.rect(row: span.row, colStart: span.colStart, colEnd: span.colEnd)
        // The shift must translate the rect by exactly the origin and leave its size unchanged.
        XCTAssertEqual(moved.origin.x - base.origin.x, 100)
        XCTAssertEqual(moved.origin.y - base.origin.y, 200)
        XCTAssertEqual(moved.size, base.size)
        // And the absolute value is the hand-computed one (origin defaults are 0 for `zeroOrigin`).
        XCTAssertEqual(base, CGRect(x: 16, y: 16, width: 8, height: 16))
        XCTAssertEqual(moved, CGRect(x: 116, y: 216, width: 8, height: 16))
    }

    // MARK: - clampedRect (never draw a span off-screen-right)

    /// A span fully inside the grid is unchanged — `clampedRect` equals the raw `rect`.
    func testClampedRectInsideGridEqualsRawRect() {
        let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 80, rows: 24)
        XCTAssertEqual(
            metrics.clampedRect(row: 1, colStart: 2, colEnd: 5),
            metrics.rect(row: 1, colStart: 2, colEnd: 5),
            "a span within the grid is not altered by the clamp",
        )
    }

    /// A span starting AT or BEYOND the last visible column is SKIPPED (nil) — never painted in the void to
    /// the right of the terminal. Revert-to-confirm-fail: a clamp that returned `rect(...)` here would draw
    /// off-screen. `cols == 4` ⇒ valid columns are 0...3, so colStart 4 (and 5) are out.
    func testClampedRectStartingPastGridIsSkipped() {
        let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 4, rows: 24)
        XCTAssertNil(metrics.clampedRect(row: 0, colStart: 4, colEnd: 6), "colStart == cols is off-screen → nil")
        XCTAssertNil(metrics.clampedRect(row: 0, colStart: 5, colEnd: 9), "colStart > cols is off-screen → nil")
    }

    /// A span whose `colEnd` overruns the grid edge is TRIMMED to `cols`, not drawn past it. colStart 2,
    /// colEnd 10 with cols 4 ⇒ width spans 2..<4 = 2 cells = 16pt (NOT 8*(10−2) = 64pt).
    func testClampedRectTrimsColEndToGridWidth() {
        let metrics = TerminalCellMetrics(cellWidth: 8, cellHeight: 16, cols: 4, rows: 24)
        let rect = metrics.clampedRect(row: 0, colStart: 2, colEnd: 10)
        XCTAssertEqual(rect, CGRect(x: 16, y: 0, width: 16, height: 16), "colEnd is clamped to the grid width")
    }

    func testDefaultOriginIsZero() {
        // The convenience init defaults originX/originY to 0 — the GUI viewport origin (the surface
        // fills its hosting view), so a metrics built without an explicit origin maps from (0, 0).
        let metrics = TerminalCellMetrics(cellWidth: 7, cellHeight: 14, cols: 80, rows: 24)
        XCTAssertEqual(metrics.originX, 0)
        XCTAssertEqual(metrics.originY, 0)
        XCTAssertEqual(
            metrics.rect(row: 0, colStart: 0, colEnd: 1),
            CGRect(x: 0, y: 0, width: 7, height: 14),
        )
    }
}
