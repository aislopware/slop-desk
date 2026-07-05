// SettingsSectionTaxonomyTests (E7 WI-2) — the anti-drift pin for the 8-section Settings taxonomy.
//
// The macOS tab strip and the (future) iOS settings sheet both drive their sections from `SettingsSection`
// (`Settings/SettingsView.swift`), so a single source can't render an out-of-order / missing / re-iconed
// section. This pins the set + order + titles + sidebar glyphs against an INDEPENDENT expectation
// table (not the enum's own derivation), so dropping, reordering, renaming, or re-iconing a section fails
// the build — exactly as `SettingsKeyTests.testSettingsKeyStringsAreStable` pins the key strings.
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
@testable import SlopDeskClientUI

final class SettingsSectionTaxonomyTests: XCTestCase {
    /// The Settings taxonomy, frozen: ordered (rawValue, title, systemImage). Edited only with an intentional
    /// taxonomy change (and a matching screenshot/spec update).
    ///
    /// 5th-ROW LABEL NOTE: the reference screenshots disagree on this row's label across revisions —
    /// `all-settings.png` and `notification-setting.png` label it **Agents**, while `tab-setting.png` /
    /// `launch-option.png` label it **Integrations**. slopdesk pins to all-settings.png's **"Agents"**; a
    /// future reviewer comparing against a build that shows "Integrations" should NOT treat that as a
    /// regression (the label is the only thing that differs — same row, same `powerplug` glyph, same slot).
    private static let expected: [(raw: String, title: String, icon: String)] = [
        ("general", "General", "exclamationmark.circle"),
        ("shell", "Shell", "terminal"),
        ("controls", "Controls", "cursorarrow"),
        ("editor", "Editor", "doc.text"),
        ("agents", "Agents", "powerplug"),
        ("appearance", "Appearance", "paintpalette"),
        ("keybindings", "Key Bindings", "bolt"),
        ("advanced", "Advanced", "wrench"),
    ]

    func testSectionTaxonomyIsPinned() {
        let cases = SettingsSection.allCases
        XCTAssertEqual(cases.count, Self.expected.count, "the taxonomy must have exactly 8 sections")
        XCTAssertEqual(cases.count, 8)
        for (section, want) in zip(cases, Self.expected) {
            XCTAssertEqual(section.rawValue, want.raw, "section order / rawValue drifted")
            XCTAssertEqual(section.title, want.title, "title drifted for \(want.raw)")
            XCTAssertEqual(section.systemImage, want.icon, "systemImage drifted for \(want.raw)")
            XCTAssertEqual(section.id, want.raw, "id must be the rawValue")
        }
    }

    /// Titles + icons are unique (no two tabs collide in the strip).
    func testTitlesAndIconsAreUnique() {
        let titles = SettingsSection.allCases.map(\.title)
        let icons = SettingsSection.allCases.map(\.systemImage)
        XCTAssertEqual(Set(titles).count, titles.count, "duplicate section titles")
        XCTAssertEqual(Set(icons).count, icons.count, "duplicate section icons")
    }

    /// E20 M1 (ES-E20-4): the General page surfaces an **OS Integration** group on macOS — the reachable,
    /// post-first-launch home for Default Terminal / Finder Integration / Full Disk Access (governing
    /// screenshot `first-launch-default-terminal.png`, `spec/getting-started__first-launch.md §2`). Before the
    /// fix these actions lived ONLY in the one-time first-launch sheet, so a user who clicked "Skip Setup"
    /// could never reach "Set as Default Terminal" again. Pinned against an INDEPENDENT expectation (not the
    /// helper's own derivation): macOS shows the four groups in order with OS Integration last; iOS omits it
    /// (the LaunchServices + System-Settings deep-links are `#if os(macOS)`). Reverting the
    /// `titles.append(osIntegration)` line fails the macOS branch.
    func testGeneralPageSurfacesOSIntegrationOnMacOSOnly() {
        let titles = GeneralSettingsLayout.sectionTitles
        #if os(macOS)
        XCTAssertEqual(
            titles,
            ["General", "Close Confirmation", "Privacy & New Panes", "OS Integration"],
            "macOS General page must home the OS Integration group (E20 M1) so it is reachable post-first-launch",
        )
        XCTAssertEqual(GeneralSettingsLayout.osIntegration, "OS Integration")
        #else
        XCTAssertEqual(
            titles,
            ["General", "Close Confirmation", "Privacy & New Panes"],
            "iOS omits OS Integration — no LaunchServices / System-Settings handler",
        )
        XCTAssertFalse(titles.contains("OS Integration"), "OS Integration is macOS-only")
        #endif
    }

    /// WI-5: the compact iOS settings sheet (`SettingsSheet`) drops the macOS-only sections via the
    /// `isMacOSOnly` filter. Pins — against an INDEPENDENT expectation, not the property's own derivation —
    /// that **Keybindings** is the sole macOS-only section (its chord capture is a macOS `NSEvent` monitor)
    /// and that the iOS list is exactly the cross-platform sections in taxonomy order. Showing
    /// Keybindings on iOS (or dropping another section) fails this. `isMacOSOnly` is cross-platform, so this
    /// runs headlessly on the macOS `swift test` host.
    func testMacOSOnlySectionsAreKeybindingsOnly() {
        let macOnly = SettingsSection.allCases.filter(\.isMacOSOnly).map(\.rawValue)
        XCTAssertEqual(macOnly, ["keybindings"], "Keybindings is the only macOS-only section")

        let iosVisible = SettingsSection.allCases.filter { !$0.isMacOSOnly }.map(\.rawValue)
        XCTAssertEqual(
            iosVisible,
            ["general", "shell", "controls", "editor", "agents", "appearance", "advanced"],
            "the iOS sheet shows the seven cross-platform sections in taxonomy order",
        )
    }
}
#endif
