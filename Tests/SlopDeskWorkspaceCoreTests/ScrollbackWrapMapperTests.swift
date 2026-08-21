import XCTest
@testable import SlopDeskWorkspaceCore

/// Bug 1 (soft-wrap coordinate mapping): the pure ``ScrollbackWrapMapper`` that maps a LOGICAL (unwrapped)
/// scrollback line index — the index into the collapsed `searchScrollbackLines()` mirror — to the PHYSICAL
/// grid row libghostty's `scroll_to_row:` addresses (every soft-wrap continuation counts as a row).
///
/// ## What this suite is for now
///
/// The rule moved to `slopdesk_terminal::wrap_map` and its invariants are pinned there, case for case, in
/// Rust. What stayed here is the whole CROSSING: `[String]` flattened to one UTF-8 blob plus a byte length
/// per line, two signed counts widened to `intptr_t`, and a `size_t` row read back. Every case below still
/// drives the same public entry point the find bar calls, so a marshalling mistake — a byte length sent as
/// a character count, a negative width silently widened, an empty array handed over as a null pair — fails
/// here rather than in a viewport that scrolls to the wrong line.
final class ScrollbackWrapMapperTests: XCTestCase {
    private func row(_ line: Int, _ lines: [String], _ cols: Int) -> Int {
        ScrollbackWrapMapper.physicalRow(forLogicalLine: line, in: lines, columns: cols)
    }

    /// Unknown grid width (`columns <= 0`) ⇒ identity: exactly the pre-fix un-mapped index.
    ///
    /// This is also the door's sign test. `columns` crosses as `intptr_t`; declared `size_t`, the `-1`
    /// below would arrive as `SIZE_MAX` and the answer would be a coincidence rather than the identity.
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

    // MARK: - The marshalling half

    /// The lengths sent across are UTF-8 BYTE counts, not characters and not cells — three different
    /// numbers for the same line. A face that sent either of the other two would split the blob mid-glyph
    /// and hand every line after the first a measurement of somebody else's bytes.
    ///
    /// Each line here is a different byte-per-character ratio (1, 2, 3, 4) with a plain ASCII line between,
    /// so a misaligned split cannot land back on a boundary by luck.
    func testLineLengthsCrossAsBytesNotCharacters() {
        let lines = ["ab", "éé", "文文", "🙂", "xyz"] // 2, 4, 6, 4 bytes; 2, 2, 4, 2 cells
        // At a width wide enough that nothing wraps, the mapping is the identity — and it can only BE the
        // identity if every line was split where its own bytes end.
        for index in 0...lines.count {
            XCTAssertEqual(row(index, lines, 80), index, "line \(index) after a multi-byte prefix")
        }
        // And at a width narrow enough to wrap, the cell counts have to be the ones above: "文文" is 4
        // cells (2 rows at width 2) where "éé" is 2 (1 row) despite both being multi-byte.
        XCTAssertEqual(row(1, lines, 2), 1) // "ab" = 2 cells = 1 row
        XCTAssertEqual(row(2, lines, 2), 2) // + "éé" = 2 cells = 1 row
        XCTAssertEqual(row(3, lines, 2), 4) // + "文文" = 4 cells = 2 rows
        XCTAssertEqual(row(4, lines, 2), 5) // + "🙂" = 2 cells = 1 row
    }

    /// An empty mirror is a real input, not a refusal. Swift hands an empty array over as a null pointer
    /// pair, which the door borrows as empty — so the answer is the phantom-row count, and a return of `0`
    /// here means physical row zero rather than "the door declined".
    func testEmptyMirrorCrossesAsEmptyAndStillAnswers() {
        XCTAssertEqual(row(0, [], 80), 0)
        XCTAssertEqual(row(7, [], 80), 7)
        XCTAssertEqual(row(0, ["abcdefgh"], 4), 0, "row zero is an answer the caller acts on")
    }

    /// A negative logical index is floored at zero rather than widened into a walk over the whole mirror.
    /// The old Swift guard was `max(0, logicalLine)`; the door keeps it by crossing as `intptr_t`.
    func testNegativeLogicalLineIsRowZero() {
        XCTAssertEqual(row(-1, ["abcdefgh", "ij"], 4), 0)
        XCTAssertEqual(row(-9, ["abcdefgh", "ij"], 0), 0)
    }

    /// The crossing is one call for the whole mirror, so it has to stay correct at a mirror size worth
    /// having moved the loop for. Ten thousand two-row lines put the answer well past anything a truncated
    /// blob or a short lengths array could produce.
    func testLargeMirrorCrossesInOnePiece() {
        let lines = [String](repeating: "abcdefgh", count: 10000) // 8 cells ⇒ 2 rows at cols=4
        XCTAssertEqual(row(10000, lines, 4), 20000)
        XCTAssertEqual(row(4321, lines, 4), 8642)
    }
}
