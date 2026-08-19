// SettingsSectionTaxonomyTests — the pin the boundary CANNOT hold: that every dispatch case is reachable.
//
// The taxonomy itself — which sections exist, what they are called, their glyphs, their order, and the one
// that needs a Mac — is `slopdesk_workspace::settings_catalog::Section`, pinned there against its own
// independent table. Restating that table here would be a cross-language mirror, so it is gone.
//
// What is left is the half of the contract Rust cannot see. `SettingsSection` is a Swift enum because
// `SettingsSectionContent`'s exhaustive `switch` needs one; the catalog's rows are keyed by STRING. So a case
// added to the enum with no row behind it, or a row whose id no case parses, produces a section that either
// renders with no title or never renders at all — and both are silent. `SettingsSection.ordered` is a
// `compactMap`, which means a dropped row is INVISIBLE exactly the way a dropped card is. This asserts the
// two lists are the same set, in the boundary's order.
//
// SECTION-CONTENT GAPS ARE INTENTIONAL (the per-section bodies are `private` to `SettingsView.swift`, so the
// gaps are pinned by the doc-comment notes on each tab struct rather than by an assertion here — recorded for
// a reviewer auditing this anti-drift file): Editor stays RESERVED/empty (no file-editor);
// Shell → NOTIFICATIONS surfaces only the two rows backed by real behaviour (the rest of the
// NOTIFICATION + TAB BADGE groups deferred-until-backed); General has no Auto-Update / Language /
// "Quit When All Windows Closed" controls (N/A for a single-user remote tool) and ADDS the slopdesk-specific
// Privacy & New Panes group; Appearance → TABS is VERTICAL-TABS-ONLY by product decision (a horizontal
// Tabs Top / Tabs Bottom LAYOUT selector is dropped, not missing) with Auto-Hide-Tabs-Panel + Window-Size
// deferred. None of these are regressions; see the matching struct doc-comments in `SettingsView.swift`.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI

final class SettingsSectionTaxonomyTests: XCTestCase {
    /// Every dispatch case has a catalog row, and every catalog row a dispatch case — the same set, in the
    /// BOUNDARY's order. A case with no row would render titleless; a row with no case would vanish out of
    /// `ordered`'s `compactMap` with nothing on screen hinting it existed.
    func testEveryDispatchCaseIsReachableFromTheCatalog() {
        let ordered = SettingsSection.ordered
        XCTAssertEqual(
            Set(ordered), Set(SettingsSection.allCases),
            "a case with no catalog row, or a row no case parses — either way a section no one can open",
        )
        XCTAssertEqual(ordered.map(\.rawValue), SettingsCatalog.sections.map(\.id), "order is the catalog's")
        XCTAssertEqual(ordered.count, Set(ordered).count, "a case listed twice")
    }

    /// The crossing actually delivers. A door that answered zero bytes would leave every row blank rather
    /// than failing, so the near side asserts it got words — and that no two sections collide in the strip.
    func testEverySectionCrossesWithAWordAndAGlyph() {
        for section in SettingsSection.ordered {
            XCTAssertFalse(section.title.isEmpty, "\(section.rawValue) crossed with no title")
            XCTAssertFalse(section.systemImage.isEmpty, "\(section.rawValue) crossed with no glyph")
            XCTAssertEqual(section.id, section.rawValue, "id must be the rawValue — it is the catalog's key")
        }
        let titles = SettingsSection.ordered.map(\.title)
        let icons = SettingsSection.ordered.map(\.systemImage)
        XCTAssertEqual(Set(titles).count, titles.count, "duplicate section titles")
        XCTAssertEqual(Set(icons).count, icons.count, "duplicate section icons")
    }

    /// The General page surfaces an **OS Integration** group on macOS — the reachable,
    /// post-first-launch home for Default Terminal / Finder Integration / Full Disk Access (governing
    /// screenshot `first-launch-default-terminal.png`, `spec/getting-started__first-launch.md §2`). Without
    /// The General page's platform difference — macOS shows OS Integration, iOS omits it — used to be
    /// pinned here, against `GeneralSettingsLayout.sectionTitles` under an `#if os(macOS)`. It moved to
    /// `SettingsLayoutTests` with the table it describes, and got stronger doing it: a `#if` can only
    /// assert about the half that COMPILED, so the iOS expectation in a macOS test run was dead text.
    /// The table takes the half as an argument, so one process now checks both.

    /// The phone's list is the WHOLE taxonomy. It used to be the taxonomy minus Keybindings, on the
    /// grounds that recording a chord needs an `NSEvent` monitor; the phone records with a first
    /// responder off the same Rust tables (docs/56 increment 30), so the subtraction — and the
    /// per-section platform flag that carried it across the boundary — is gone. A page the phone
    /// cannot draw is now a statement the LAYOUT table makes about groups, per half, as data.
    func testEveryPageReachesBothHalves() {
        XCTAssertTrue(SettingsSection.ordered.contains(.keybindings))
        XCTAssertEqual(
            Set(SettingsSection.ordered), Set(SettingsSection.allCases),
            "no section is one half's alone",
        )
    }
}
#endif
