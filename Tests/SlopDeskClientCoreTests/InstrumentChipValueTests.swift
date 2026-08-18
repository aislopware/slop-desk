// InstrumentChipValueTests — pins the pure values behind the generic notice chip (`ChipNotice`), so the
// wording/data layer stays deterministic without a view (the CopyReceiptTests discipline).
//
// The divider-drag ratio readout used to be pinned here too; it is a seam's own answer now
// (`SplitDividerHandle.splitPercents`) and is pinned beside the rest of the seam's arithmetic.

import XCTest
@testable import SlopDeskClientCore

final class InstrumentChipValueTests: XCTestCase {
    // MARK: ChipNotice (the window-level transient cue value)

    func testShortDetailIsKeptVerbatim() {
        let notice = ChipNotice(label: "Tab closed", detail: "⇧⌘T reopens", epoch: 1, dwell: .seconds(4))
        XCTAssertEqual(notice.detail, "⇧⌘T reopens")
        XCTAssertEqual(notice.accessibilityText, "Tab closed · ⇧⌘T reopens")
    }

    func testOverlongDetailIsClippedDeterministically() {
        let long = String(repeating: "x", count: 200)
        let notice = ChipNotice(label: "Reply sent", detail: long, epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(notice.detail.count, ChipNotice.detailCap, "clip lands exactly at the cap")
        XCTAssertTrue(notice.detail.hasSuffix("…"), "the clip is visible, never a silent cut")
    }

    func testEmptyDetailCollapsesTheSeparator() {
        let notice = ChipNotice(label: "Saved", detail: "", epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(notice.accessibilityText, "Saved", "no dangling `·` when there is no detail")
    }

    /// The chord is DRAWN as a keycap and SPOKEN as text — VoiceOver has no key, so the cap has to rejoin
    /// the sentence in the order the eye reads it, behind the single separator the eye sees.
    func testKeycapRejoinsTheSpokenSentenceInDrawnOrder() {
        let notice = ChipNotice(
            label: "Tab closed", keycap: "⇧⌘T", detail: "reopens", epoch: 1, dwell: .seconds(4),
        )
        XCTAssertEqual(notice.accessibilityText, "Tab closed · ⇧⌘T reopens")
    }

    /// A cap with no trailing verb still speaks — and still takes exactly one separator, so a notice that
    /// only offers a key never reads as `Palette open ·  ⌘K` with a hole in it.
    func testKeycapAloneNeedsNoTrailingVerb() {
        let notice = ChipNotice(label: "Palette", keycap: "⌘K", detail: "", epoch: 1, dwell: .seconds(2))
        XCTAssertEqual(notice.accessibilityText, "Palette · ⌘K")
    }
}
