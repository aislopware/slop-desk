// Pins how the ⌘/ cheat sheet deals its categories into columns.
//
// The rule that matters is BALANCE BY HEIGHT, not by count. The first attempt at two columns was a
// `LazyVGrid`, which pairs sections into grid ROWS and centres a short category against the tall one beside
// it — photographed, and the short column floated halfway down the card with dead air above and below. The
// replacement packs real columns, and this suite is what stops it regressing to "first half / second half",
// which looks identical on a uniform table and falls apart on the real one (Panes has three times the rows
// of Sessions).

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class CheatSheetColumnBalanceTests: XCTestCase {
    /// Total rendered height of a column: each section costs its rows PLUS its own header line.
    private func heights(rowCounts: [Int], assignment: [Int], columns: Int = 2) -> [Int] {
        var out = Array(repeating: 0, count: columns)
        for (rows, column) in zip(rowCounts, assignment) { out[column] += rows + 1 }
        return out
    }

    func testALongSectionIsBalancedAgainstSeveralShortOnes() {
        // The shape that breaks a naive split: one huge category, then three small ones.
        let rowCounts = [18, 4, 3, 2]
        let assignment = KeyboardCheatSheetView.columnAssignment(rowCounts: rowCounts)
        let tall = heights(rowCounts: rowCounts, assignment: assignment)
        // Halving the LIST would put 18+4 in one column against 3+2 in the other — a 24-to-7 split.
        XCTAssertLessThanOrEqual(
            abs(tall[0] - tall[1]), 18,
            "the long section sets the floor; every short one must land in the OTHER column",
        )
        XCTAssertEqual(
            assignment[0], 0,
            "the first section opens the first column — the registry's order still reads down the page",
        )
        XCTAssertEqual(
            Set(assignment[1...]), [1],
            "with one section at 19 units and the rest at 5/4/3, all three belong beside it",
        )
    }

    func testAUniformTableSplitsDownTheMiddle() {
        let rowCounts = [5, 5, 5, 5]
        let assignment = KeyboardCheatSheetView.columnAssignment(rowCounts: rowCounts)
        XCTAssertEqual(assignment, [0, 1, 0, 1], "equal sections alternate, which is the balanced deal")
    }

    func testEverySectionIsPlacedExactlyOnce() {
        let rowCounts = [7, 2, 9, 1, 4, 6]
        let assignment = KeyboardCheatSheetView.columnAssignment(rowCounts: rowCounts)
        XCTAssertEqual(assignment.count, rowCounts.count, "no section may be dropped or duplicated")
        XCTAssertTrue(assignment.allSatisfy { (0..<2).contains($0) }, "every column index is in range")
    }

    /// Total order-independence would be wrong — but the SET of column loads must not depend on which
    /// column happens to be picked first when both are empty.
    func testTheDealNeverTrapsOnDegenerateInput() {
        XCTAssertEqual(KeyboardCheatSheetView.columnAssignment(rowCounts: []), [])
        XCTAssertEqual(
            KeyboardCheatSheetView.columnAssignment(rowCounts: [3], columns: 0), [0],
            "a zero column count clamps to one column rather than dividing by zero",
        )
        XCTAssertEqual(
            KeyboardCheatSheetView.columnAssignment(rowCounts: [0, 0, 0]), [0, 1, 0],
            "an empty section still costs its header line, so it still alternates",
        )
    }
}
#endif
