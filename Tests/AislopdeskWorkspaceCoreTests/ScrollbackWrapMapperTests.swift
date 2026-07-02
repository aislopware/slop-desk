import XCTest
@testable import AislopdeskWorkspaceCore

/// Bug 1 (soft-wrap coordinate mapping): the pure ``ScrollbackWrapMapper`` that maps a LOGICAL (unwrapped)
/// scrollback line index — the index into the collapsed `searchScrollbackLines()` mirror — to the PHYSICAL
/// grid row libghostty's `scroll_to_row:` addresses (every soft-wrap continuation counts as a row).
final class ScrollbackWrapMapperTests: XCTestCase {
    private func row(_ line: Int, _ lines: [String], _ cols: Int) -> Int {
        ScrollbackWrapMapper.physicalRow(forLogicalLine: line, in: lines, columns: cols)
    }

    /// Unknown grid width (`columns <= 0`) ⇒ identity: exactly the pre-fix un-mapped index.
    func testUnknownColumnsIsIdentity() {
        let lines = ["a very long line that would wrap", "short"]
        XCTAssertEqual(row(1, lines, 0), 1)
        XCTAssertEqual(row(5, lines, -1), 5)
    }

    /// No wrapping (every line fits) ⇒ physical row equals the logical index.
    func testNoWrapEqualsLogicalIndex() {
        let lines = ["abc", "de", "fghi"] // all ≤ 4 cells
        XCTAssertEqual(row(0, lines, 4), 0)
        XCTAssertEqual(row(1, lines, 4), 1)
        XCTAssertEqual(row(2, lines, 4), 2)
    }

    /// A line wider than the grid occupies ceil(width/cols) physical rows; later lines shift down by the
    /// extra continuation rows. cols=4: "abcdefgh" (8) = 2 rows, "ij" (2) = 1 row.
    func testWrappedLineShiftsLaterRowsDown() {
        let lines = ["abcdefgh", "ij", "klmnopqrstuv"] // 8, 2, 12 cells
        XCTAssertEqual(row(0, lines, 4), 0) // first line always starts at physical row 0
        XCTAssertEqual(row(1, lines, 4), 2) // after the 2-row line 0
        XCTAssertEqual(row(2, lines, 4), 3) // + the 1-row line 1
        // Boundary: a line exactly `cols` wide is ONE row (wrap only PAST the edge).
        XCTAssertEqual(row(1, ["abcd", "x"], 4), 1)
        // One cell past the edge wraps to a second row.
        XCTAssertEqual(row(1, ["abcde", "x"], 4), 2)
    }

    /// An empty line still occupies exactly one physical row (never zero).
    func testEmptyLineCountsAsOneRow() {
        XCTAssertEqual(row(2, ["", "", "x"], 4), 2)
    }

    /// A logical index past the mirror's end (a stale/shrunk snapshot) contributes one physical row per
    /// missing line — never traps or under-counts.
    func testIndexPastEndNeverTraps() {
        let lines = ["abcdefgh"] // 1 line, 2 physical rows
        XCTAssertEqual(row(1, lines, 4), 2) // the one wrapped line
        XCTAssertEqual(row(3, lines, 4), 4) // + 2 phantom rows for indices 1,2
    }

    /// East-Asian-wide glyphs count as two cells (same measure as ``TerminalLinkDetector``), so a CJK line
    /// wraps sooner than its character count suggests.
    func testWideGlyphsCountAsTwoCells() {
        // "文文文" = 6 cells at cols=4 ⇒ 2 physical rows.
        XCTAssertEqual(row(1, ["文文文", "x"], 4), 2)
    }
}
