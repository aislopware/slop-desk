import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E19/A18 — pins the PURE vertical-sidebar single-tab auto-hide decision (``SidebarAutoHidePolicy``) + the
/// ``AutoHideTabsPanelMode`` enum and its persisted-`Defaults` round-trip / repair. Headless: the policy is
/// the tested unit; the view-side glue that conditionally drives `chrome.sidebarCollapsed` (WI-7) reads this
/// same decision. No `NSWindow`/view instantiation.
@MainActor
final class SidebarAutoHidePolicyTests: XCTestCase {
    private let autoHideKey = SettingsKey.autoHideTabsPanelKey

    override func setUp() { SettingsKey.store.removeObject(forKey: autoHideKey) }
    override func tearDown() { SettingsKey.store.removeObject(forKey: autoHideKey) }

    // MARK: desiredCollapsed

    /// `.auto` collapses the sidebar when there is ≤1 tab and reveals it when there is more than one — the
    /// sidebar is only useful for switching between tabs, so it hides itself when there is nothing to switch
    /// between. Asserts against an INDEPENDENT truth table, not the function's own derivation.
    func testAutoCollapsesAtOrBelowOneTab() {
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 0), true, "0 tabs → collapse")
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 1), true, "1 tab → collapse")
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 2), false, "2 tabs → reveal")
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 7), false, ">1 tab → reveal")
    }

    /// `.default` / `.always` have NO opinion (`nil`) for EVERY count — the wiring leaves a manual ⌘⇧L
    /// collapse alone outside `.auto`. (In the vertical-tabs-only clone the two non-`auto` modes both mean
    /// "never auto-hide".)
    func testDefaultAndAlwaysHaveNoOpinion() {
        for count in [0, 1, 2, 99] {
            XCTAssertNil(
                SidebarAutoHidePolicy.desiredCollapsed(mode: .default, tabCount: count),
                ".default has no opinion at tabCount \(count)",
            )
            XCTAssertNil(
                SidebarAutoHidePolicy.desiredCollapsed(mode: .always, tabCount: count),
                ".always has no opinion at tabCount \(count)",
            )
        }
    }

    // MARK: AutoHideTabsPanelMode raw values + Defaults round-trip / repair

    /// The enum raw values are the `auto-hide-tabs-panel` config tokens and round-trip exactly.
    func testAutoHideTabsPanelModeRawRoundTrip() {
        XCTAssertEqual(AutoHideTabsPanelMode.allCases, [.default, .always, .auto])
        XCTAssertEqual(AutoHideTabsPanelMode.default.rawValue, "default")
        XCTAssertEqual(AutoHideTabsPanelMode.always.rawValue, "always")
        XCTAssertEqual(AutoHideTabsPanelMode.auto.rawValue, "auto")
        XCTAssertEqual(AutoHideTabsPanelMode(rawValue: "auto"), .auto)
        XCTAssertNil(AutoHideTabsPanelMode(rawValue: "garbage-from-a-future-version"))
    }

    /// The new `Defaults.Key` reads its declared default (`.default`) when unset, round-trips a written value
    /// from its persisted form, and a bogus persisted raw repairs to `.default` (the
    /// `Defaults.PreferRawRepresentable` bridge) rather than trapping. Read through the public
    /// ``SettingsKey/autoHideTabsPanel`` accessor + the raw `UserDefaults` the `@Default(.autoHideTabsPanel)`
    /// picker binds (the file's established no-`import Defaults` convention).
    func testAutoHideTabsPanelDefaultsRoundTripAndRepair() {
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default)
        SettingsKey.store.set("auto", forKey: autoHideKey)
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .auto)
        SettingsKey.store.set("garbage-from-a-future-version", forKey: autoHideKey)
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default, "an invalid raw value repairs to default")
    }

    /// The persisted key string is stable (the `@Default(.autoHideTabsPanel)` picker + a future All-Settings
    /// catalog row bind it; a rename would silently orphan the user's choice).
    func testAutoHideTabsPanelKeyStringIsStable() {
        XCTAssertEqual(SettingsKey.autoHideTabsPanelKey, "shell.autoHideTabsPanel")
    }
}
