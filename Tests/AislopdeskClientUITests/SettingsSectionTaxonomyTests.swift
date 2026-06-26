// SettingsSectionTaxonomyTests (E7 WI-2) — the anti-drift pin for the otty 9-section Settings taxonomy.
//
// The macOS tab strip and the (future) iOS settings sheet both drive their sections from `SettingsSection`
// (`Settings/SettingsView.swift`), so a single source can't render an out-of-order / missing / re-iconed
// section. This pins the set + order + titles + otty sidebar glyphs against an INDEPENDENT expectation
// table (not the enum's own derivation), so dropping, reordering, renaming, or re-iconing a section fails
// the build — exactly as `SettingsKeyTests.testSettingsKeyStringsAreStable` pins the key strings.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class SettingsSectionTaxonomyTests: XCTestCase {
    /// The otty taxonomy, frozen: ordered (rawValue, title, systemImage). Edited only with an intentional
    /// taxonomy change (and a matching screenshot/spec update).
    private static let expected: [(raw: String, title: String, icon: String)] = [
        ("general", "General", "exclamationmark.circle"),
        ("shell", "Shell", "terminal"),
        ("controls", "Controls", "flag"),
        ("editor", "Editor", "doc.text"),
        ("agents", "Agents", "powerplug"),
        ("appearance", "Appearance", "paintpalette"),
        ("recipes", "Recipes", "book"),
        ("keybindings", "Key Bindings", "bolt"),
        ("advanced", "Advanced", "wrench"),
    ]

    func testSectionTaxonomyIsPinned() {
        let cases = SettingsSection.allCases
        XCTAssertEqual(cases.count, Self.expected.count, "the taxonomy must have exactly 9 sections")
        XCTAssertEqual(cases.count, 9)
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

    /// WI-5: the compact iOS settings sheet (`SettingsSheet`) drops the macOS-only sections via the
    /// `isMacOSOnly` filter. Pins — against an INDEPENDENT expectation, not the property's own derivation —
    /// that **Keybindings** is the sole macOS-only section (its chord capture is a macOS `NSEvent` monitor)
    /// and that the iOS list is exactly the seven cross-platform sections in taxonomy order. Showing
    /// Keybindings on iOS (or dropping another section) fails this. `isMacOSOnly` is cross-platform, so this
    /// runs headlessly on the macOS `swift test` host.
    func testMacOSOnlySectionsAreKeybindingsOnly() {
        let macOnly = SettingsSection.allCases.filter(\.isMacOSOnly).map(\.rawValue)
        XCTAssertEqual(macOnly, ["keybindings"], "Keybindings is the only macOS-only section")

        let iosVisible = SettingsSection.allCases.filter { !$0.isMacOSOnly }.map(\.rawValue)
        XCTAssertEqual(
            iosVisible,
            ["general", "shell", "controls", "editor", "agents", "appearance", "recipes", "advanced"],
            "the iOS sheet shows the eight cross-platform sections in taxonomy order",
        )
    }
}
#endif
