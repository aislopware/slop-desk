// PalettePresentationTests — pins what the command palette IS, below both platforms.
//
// The palette is drawn twice now (docs/56 stage D): an `NSPanel` on the Mac, a paper card on the
// phone. Everything pinned here is what the two halves must agree on — how the ranked rows pair with
// the keyboard's index, which row an auto-scroll scrolls to, and how far one ⇞ jumps. A half that
// re-derived any of them would drift the moment a section header appeared.
//
// The BADGE's own rule is `PaneSpec::cwd_badge_path` and is pinned in Rust; what the badge test here
// proves is the half Rust cannot see — that the pill hangs off the header that owns it and off no
// other.

import XCTest
@testable import SlopDeskClientCore

@MainActor
final class PalettePresentationTests: XCTestCase {
    private func row(_ id: String, separator: Bool = false) -> RankedRow {
        RankedRow(item: PaletteItem(
            id: id, icon: "circle", title: id, filter: .actions,
            action: .noOp, isSeparator: separator,
        ))
    }

    // MARK: - The two indices

    /// A separator occupies a LINE but not a selection, so the draw order and the keyboard's order
    /// are different sequences. This is the pairing every half would otherwise get one off the first
    /// time a section header landed mid-list.
    func testSeparatorsTakeALineButNotASelectableIndex() {
        let display = PalettePresentation.displayRows([
            row("WORKING DIRECTORY", separator: true),
            row("a"), row("b"),
            row("VIEW", separator: true),
            row("c"),
        ])
        XCTAssertEqual(display.map(\.selectableIndex), [nil, 0, 1, nil, 2])
        XCTAssertEqual(display.map(\.id), ["WORKING DIRECTORY", "a", "b", "VIEW", "c"])
    }

    /// The row the keyboard sits on is found by counting SELECTABLE rows, not lines — the third
    /// selectable row in a sectioned list is nowhere near the third line.
    func testTheSelectedRowIsFoundByCountingSelectableRows() {
        let rows = [
            row("HEADER", separator: true),
            row("a"), row("b"),
            row("OTHER", separator: true),
            row("c"),
        ]
        XCTAssertEqual(PalettePresentation.selectedRowID(rows, selection: 0), "a")
        XCTAssertEqual(PalettePresentation.selectedRowID(rows, selection: 2), "c")
    }

    /// A selection past the end scrolls NOWHERE rather than to the top: the query narrowing the list
    /// under a parked selection is the common way to reach this, and snapping to the first row would
    /// move the list out from under a user who had not touched the arrows.
    func testASelectionPastTheEndNamesNoRow() {
        XCTAssertNil(PalettePresentation.selectedRowID([row("a")], selection: 4))
        XCTAssertNil(PalettePresentation.selectedRowID([row("H", separator: true)], selection: 0))
    }

    // MARK: - The page

    /// One ⇞ is one VIEWPORT of rows, derived from the two numbers that size the viewport — so
    /// re-tuning the card re-tunes the page rather than leaving a stride that no longer matches what
    /// the eye just skipped.
    func testAPageIsAViewportOfRows() {
        XCTAssertEqual(PaletteMetrics.pageStride(rowHeight: 44), 7)
        XCTAssertEqual(PaletteMetrics.pageStride(rowHeight: PaletteMetrics.resultsMaxHeight), 1)
        XCTAssertEqual(
            PaletteMetrics.pageStride(rowHeight: 10000), 1,
            "a row taller than the viewport still pages by one — never by zero, which would hang ⇟",
        )
        XCTAssertEqual(PaletteMetrics.pageStride(rowHeight: 0), 1, "and a zero height never divides")
    }

    // MARK: - The badge

    /// The pill hangs off the category that OWNS it, matched by that category's own label — not off
    /// "whichever separator sorts first", which mislabelled a Recents/Actions header before the
    /// Working Directory section existed.
    func testOnlyTheWorkingDirectoryHeaderCarriesThePill() {
        XCTAssertTrue(PalettePresentation.headerOwnsWorkingDirectoryBadge(
            PaletteCategory.workingDirectory.label,
        ))
        for other in PaletteCategory.allCases where other != .workingDirectory {
            XCTAssertFalse(
                PalettePresentation.headerOwnsWorkingDirectoryBadge(other.label),
                "\(other.label) must not grow a working-directory pill",
            )
        }
        XCTAssertFalse(PalettePresentation.headerOwnsWorkingDirectoryBadge("WORKING DIRECTORY"))
    }
}
