// SlateSearchFieldTests — pins the jump-free contract of the AppKit-backed search field.
//
// The component exists for ONE reason: a SwiftUI `TextField` at `Slate.Typeface.footnote` bumps
// its text up 1pt on focus (unfocused cell draw vs focused field-editor baseline — the two AppKit
// text paths round vertical centering differently at 11pt). The fix's load-bearing configuration
// is pinned here headlessly (an `NSTextField` with no window is hang-safe); the actual pixel
// stability was measured once by screenshot (focused/unfocused centroid diff 0.0 vs SwiftUI's
// 1.0) and holds as long as this configuration does.

import AppKit
import SwiftUI
import XCTest
@testable import SlopDeskSlate

@MainActor
final class SlateSearchFieldTests: XCTestCase {
    /// REVERT-TO-CONFIRM-FAIL: re-introduce a bezel / background / vertical stretch and the
    /// cell-vs-field-editor rounding split reopens — these are the exact knobs that keep both
    /// AppKit text paths resolving one origin.
    func testConfiguredFieldKeepsTheJumpFreeInvariants() {
        let field = SlateNativeSearchField.makeConfiguredField(text: "", delegate: nil)

        XCTAssertFalse(field.isBezeled, "a bezel adds cell insets the field editor does not share")
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.drawsBackground, "the plate behind the field owns the fill")
        XCTAssertEqual(field.focusRingType, .none, "no system halo — the plate is the affordance")
        XCTAssertTrue(field.usesSingleLineMode)
        XCTAssertEqual(field.cell?.isScrollable, true, "long queries scroll, never wrap or clip")
        XCTAssertEqual(field.font?.pointSize, Slate.Typeface.footnote)
        XCTAssertEqual(
            field.contentHuggingPriority(for: .vertical), .required,
            "INTRINSIC height is the jump-free invariant — the field must never stretch vertically",
        )
    }
}
