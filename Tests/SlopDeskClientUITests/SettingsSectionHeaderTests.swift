// SettingsSectionHeaderTests (Batch-5 UI fidelity) — pins the Settings section-header CASING.
//
// In-page Settings SECTION labels render UPPERCASE (`mouse-option.png` "MOUSE" / "SECURE INPUT",
// `notification-setting.png` "NOTIFICATION" / "TAB BADGE", `all-settings.png` "ALL SETTINGS"). An earlier
// build rendered them in macOS's native Title-Case via `Section("Title")`. `slateFormSection` now routes
// the label through `SlateSettingsSectionHeader.label`, which UPPERCASES it. This pins that transform so a
// refactor can't silently regress the header back to the raw Title-Case title.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

final class SettingsSectionHeaderTests: XCTestCase {
    /// Mixed-case section titles from the live Settings pages map to all-UPPERCASE headers. The expectations
    /// are an INDEPENDENT hand-written table (not `input.uppercased()`), matching the reference screenshots.
    func testSectionHeaderLabelIsUppercased() {
        XCTAssertEqual(SlateSettingsSectionHeader.label("Copy & Paste"), "COPY & PASTE")
        XCTAssertEqual(SlateSettingsSectionHeader.label("Secure Input"), "SECURE INPUT")
        XCTAssertEqual(SlateSettingsSectionHeader.label("Tab Badge"), "TAB BADGE")
        // Through a real Settings-page section constant, proving live titles are re-cased.
        XCTAssertEqual(SlateSettingsSectionHeader.label(GeneralSettingsLayout.closeConfirmation), "CLOSE CONFIRMATION")
    }

    /// The revert-to-confirm-fail guard: the header must NOT pass the raw Title-Case title through (which is
    /// exactly what the native `Section("…")` initializer rendered on macOS grouped Forms). Dropping the
    /// `.uppercased()` re-casing fails here.
    func testSectionHeaderIsNotRawTitleCaseTitle() {
        for title in ["Selection", "Mouse", "Notification", "Window"] {
            XCTAssertNotEqual(
                SlateSettingsSectionHeader.label(title), title,
                "section headers render UPPERCASE, not the raw Title-Case title",
            )
        }
    }
}
#endif
