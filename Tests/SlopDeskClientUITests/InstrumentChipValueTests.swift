// InstrumentChipValueTests — pins the pure values behind the generic notice chip (`ChipNotice`) and the
// divider-drag ratio readout (`PaneMath.splitPercents`), so the wording/data layer stays deterministic
// without a view (the CopyReceiptTests discipline).

import XCTest
@testable import SlopDeskClientUI

final class InstrumentChipValueTests: XCTestCase {
    // MARK: ChipNotice (the window-level transient cue value)

    func testShortDetailIsKeptVerbatim() {
        let notice = ChipNotice(label: "TAB CLOSED", detail: "⇧⌘T REOPENS", epoch: 1, dwell: .seconds(4))
        XCTAssertEqual(notice.detail, "⇧⌘T REOPENS")
        XCTAssertEqual(notice.accessibilityText, "TAB CLOSED · ⇧⌘T REOPENS")
    }

    func testOverlongDetailIsClippedDeterministically() {
        let long = String(repeating: "x", count: 200)
        let notice = ChipNotice(label: "REPLY SENT", detail: long, epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(notice.detail.count, ChipNotice.detailCap, "clip lands exactly at the cap")
        XCTAssertTrue(notice.detail.hasSuffix("…"), "the clip is visible, never a silent cut")
    }

    func testEmptyDetailCollapsesTheSeparator() {
        let notice = ChipNotice(label: "SAVED", detail: "", epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(notice.accessibilityText, "SAVED", "no dangling `·` when there is no detail")
    }

    // MARK: splitPercents (the divider-drag ratio readout)

    func testEvenSplitReadsFiftyFifty() throws {
        let pct = try XCTUnwrap(PaneMath.splitPercents(leading: 1, trailing: 1))
        XCTAssertEqual(pct.leading, 50)
        XCTAssertEqual(pct.trailing, 50)
    }

    func testPercentsAlwaysSumToExactly100() throws {
        // 1/3 ↔ 2/3 rounds to 33 · 67 — the trailing side is the complement of the ROUNDED leading
        // side, never independently rounded (which would read 33 · 67 vs 33.3̄ · 66.6̄ → 33 · 67 here,
        // but 62.5 · 37.5 would drift to 63 · 38 = 101 without the complement rule).
        let thirds = try XCTUnwrap(PaneMath.splitPercents(leading: 1, trailing: 2))
        XCTAssertEqual(thirds.leading + thirds.trailing, 100)
        XCTAssertEqual(thirds.leading, 33)

        let halves = try XCTUnwrap(PaneMath.splitPercents(leading: 62.5, trailing: 37.5))
        XCTAssertEqual(halves.leading + halves.trailing, 100, "the .5 round-up cannot overflow the pair")
        XCTAssertEqual(halves.leading, 63)
        XCTAssertEqual(halves.trailing, 37)
    }

    func testDegeneratePairsAreAbsentNeverWrong() {
        XCTAssertNil(PaneMath.splitPercents(leading: 0, trailing: 1), "a .fixed side (weight 0) shows no ratio")
        XCTAssertNil(PaneMath.splitPercents(leading: 1, trailing: 0))
        XCTAssertNil(PaneMath.splitPercents(leading: .nan, trailing: 1), "float residue never renders")
        XCTAssertNil(PaneMath.splitPercents(leading: .infinity, trailing: 1))
    }
}
