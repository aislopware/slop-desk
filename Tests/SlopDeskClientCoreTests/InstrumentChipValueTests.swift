// InstrumentChipValueTests — the CROSSING behind the generic notice chip (`ChipNotice`). Where the
// cut lands and how the chord rejoins the spoken sentence are `slopdesk_workspace::chip_notice`'s and
// pinned there; what is pinned here is that the arena carries all three strings, that an ABSENT
// keycap stays absent, and that the drawn detail and the spoken one come back from the same call and
// therefore cannot disagree.
//
// The divider-drag ratio readout used to be pinned here too; it is a seam's own answer now
// (`SplitDividerHandle.splitPercents`) and is pinned beside the rest of the seam's arithmetic.

import XCTest
@testable import SlopDeskClientCore

final class InstrumentChipValueTests: XCTestCase {
    func testAllThreeStringsCrossAndTheChordReadsWhereItIsDrawn() {
        let notice = ChipNotice(
            label: "Tab closed", keycap: "⇧⌘T", detail: "reopens", epoch: 1, dwell: .seconds(4),
        )
        XCTAssertEqual(notice.detail, "reopens", "the chip draws the detail alone; the cap is its own object")
        XCTAssertEqual(notice.accessibilityText, "Tab closed · ⇧⌘T reopens")
    }

    /// A notice that offers nothing to press passes the keycap slot ABSENT rather than empty, which
    /// is what stops the separator being left hanging with nothing behind it.
    func testAnAbsentChordIsNotAnEmptyOne() {
        let offered = ChipNotice(label: "Palette", keycap: "⌘K", detail: "", epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(offered.accessibilityText, "Palette · ⌘K")
        let silent = ChipNotice(label: "Saved", detail: "", epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(silent.accessibilityText, "Saved", "no dangling `·` when there is nothing to say")
    }

    /// The two runs come back from ONE call, so the chip cannot draw a clipped sentence while the
    /// screen reader speaks the whole one.
    func testTheSpokenFormCarriesTheSameCutTheChipDraws() {
        let long = String(repeating: "x", count: 200)
        let notice = ChipNotice(label: "Reply sent", detail: long, epoch: 1, dwell: .seconds(2))
        XCTAssertTrue(notice.detail.hasSuffix("…"), "the clip is visible, never a silent cut")
        XCTAssertLessThan(notice.detail.count, long.count)
        XCTAssertEqual(notice.accessibilityText, "Reply sent · \(notice.detail)")
    }
}
