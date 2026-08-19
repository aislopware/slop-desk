// Pins what the ⌘/ cheat sheet SAYS and how its categories are dealt into columns — the one source both
// halves of the app render (an `NSPanel` on the Mac, a native sheet on the phone), so a drift here is a
// drift on both platforms at once.
//
// The balance rule that matters is BY HEIGHT, not by count. The first two-column attempt was a
// `LazyVGrid`, which pairs sections into grid ROWS and centres a short category against the tall one
// beside it — photographed, and the short column floated halfway down the card with dead air above and
// below. The replacement packs real columns, and this suite is what stops it regressing to "first half /
// second half", which looks identical on a uniform table and falls apart on the real one (Panes has three
// times the rows of the shortest category).
//
// The deal itself is `slopdesk_workspace::cheat_sheet`, pinned again on its own side; what is pinned HERE
// is the crossing — that the door's answer arrives as one column index per section, in order.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class CheatSheetContentTests: XCTestCase {
    /// Total rendered height of each column: a section costs its rows PLUS its own header line.
    private func heights(rowCounts: [Int], assignment: [Int], columns: Int = 2) -> [Int] {
        var out = Array(repeating: 0, count: columns)
        for (rows, column) in zip(rowCounts, assignment) where out.indices.contains(column) {
            out[column] += rows + 1
        }
        return out
    }

    // MARK: - The deal

    func testALongSectionIsBalancedAgainstSeveralShortOnes() {
        // The shape that breaks a naive split: one huge category, then three small ones.
        let rowCounts = [18, 4, 3, 2]
        let assignment = CheatSheetContent.columnAssignment(rowCounts: rowCounts, columns: 2)
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
        XCTAssertEqual(
            CheatSheetContent.columnAssignment(rowCounts: [5, 5, 5, 5], columns: 2), [0, 1, 0, 1],
            "equal sections alternate, which is the balanced deal",
        )
    }

    func testEverySectionIsPlacedExactlyOnce() {
        let rowCounts = [7, 2, 9, 1, 4, 6]
        let assignment = CheatSheetContent.columnAssignment(rowCounts: rowCounts, columns: 2)
        XCTAssertEqual(assignment.count, rowCounts.count, "no section may be dropped or duplicated")
        XCTAssertTrue(assignment.allSatisfy { (0..<2).contains($0) }, "every column index is in range")
    }

    func testTheDealNeverTrapsOnDegenerateInput() {
        XCTAssertEqual(CheatSheetContent.columnAssignment(rowCounts: [], columns: 2), [])
        XCTAssertEqual(
            CheatSheetContent.columnAssignment(rowCounts: [3], columns: 0), [0],
            "a zero column count clamps to one column rather than dividing by zero",
        )
        XCTAssertEqual(
            CheatSheetContent.columnAssignment(rowCounts: [0, 0, 0], columns: 2), [0, 1, 0],
            "an empty section still costs its header line, so it still alternates",
        )
    }

    /// The phone asks for ONE column and that has to be a real answer, not a degenerate case — it is the
    /// whole layout divergence between the two halves.
    func testOneColumnTakesTheWholeTableInOrder() {
        let dealt = CheatSheetContent.dealt(CheatSheetContent.sections, into: 1)
        XCTAssertEqual(dealt.count, 1, "asking for one column yields exactly one bucket")
        XCTAssertEqual(
            dealt[0].map(\.id), CheatSheetContent.sections.map(\.id),
            "a single column is the table in the registry's own order",
        )
    }

    /// Two columns must lose nothing and duplicate nothing — the deal is a partition.
    func testTwoColumnsPartitionTheTable() {
        let dealt = CheatSheetContent.dealt(CheatSheetContent.sections, into: 2)
        XCTAssertEqual(dealt.count, 2)
        XCTAssertEqual(
            Set(dealt.flatMap { $0.map(\.id) }), Set(CheatSheetContent.sections.map(\.id)),
            "every section survives the deal",
        )
        XCTAssertEqual(
            dealt.reduce(0) { $0 + $1.count }, CheatSheetContent.sections.count,
            "and none of them survives it twice",
        )
    }

    // MARK: - The content

    /// Pin the four categories in their fixed display order — a reorder / dropped section would silently
    /// rearrange (or hide) a whole chunk of the cheat sheet on both platforms.
    func testSectionsCoverTheFourCategoriesInOrder() {
        XCTAssertEqual(
            CheatSheetContent.sections.map(\.id),
            WorkspaceAction.Category.allCases.map(\.rawValue),
            "the sheet renders the four categories in their fixed display order",
        )
        XCTAssertTrue(
            CheatSheetContent.sections.allSatisfy { !$0.rows.isEmpty },
            "every rendered section has at least one binding row",
        )
    }

    /// The trap this gating exists for: `glyph(for:)` of the collapsed ⌘1…⌘9 representative's stand-in
    /// `.selectPane(1)` action resolves the REAL ⌘1 binding — so a source that asked the ACTION instead of
    /// the ROW would stamp a "⌘1" cap onto the "Select Pane (⌘1…⌘9)" row, whose title already carries the
    /// range. Every chord-less row (the palette-/menu-only verbs) takes no cap for the same reason.
    func testTheCapIsGatedOnTheRowsOwnChordNotTheActions() {
        let rows = CheatSheetContent.sections.flatMap(\.rows)
        let chordLess = Set(WorkspaceBindingRegistry.groupedForDisplay
            .flatMap(\.bindings)
            .filter { $0.chord == nil }
            .map(\.id))
        XCTAssertFalse(chordLess.isEmpty, "the fixture is only meaningful with chord-less rows in it")
        for row in rows where chordLess.contains(row.id) {
            XCTAssertNil(row.glyph, "\(row.id) has no chord of its own, so it renders no cap")
        }
        for row in rows where !chordLess.contains(row.id) {
            XCTAssertEqual(
                row.glyph?.isEmpty, false, "\(row.id) bears a chord, so its cap must resolve",
            )
        }
    }

    /// The representative specifically — the one row whose title carries its own hint.
    func testTheCollapsedSelectPaneRowKeepsItsRangeInTheTitleAndTakesNoCap() {
        let row = CheatSheetContent.sections
            .flatMap(\.rows)
            .first { $0.id == "pane.selectN" }
        XCTAssertNotNil(row, "the collapsed ⌘1…⌘9 representative is part of the rendered table")
        XCTAssertNil(row?.glyph)
        XCTAssertEqual(row?.title.contains("⌘1"), true, "its range is baked into the title instead")
    }
}
