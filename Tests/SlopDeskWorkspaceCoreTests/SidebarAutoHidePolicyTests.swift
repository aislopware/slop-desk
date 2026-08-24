import Foundation
import SlopDeskTestSupport
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the auto-hide CROSSING (``SidebarAutoHidePolicy``) plus the ``AutoHideTabsPanelMode`` enum's
/// round-trip and repair out of the config file, which stay on this side because they are what the
/// file's token decodes through. No `NSWindow`/view instantiation.
@MainActor
final class SidebarAutoHidePolicyTests: XCTestCase {
    /// Each mode reaches its own case index, and the door's `-1` — the no-opinion rung the two
    /// non-`auto` modes answer with — reads back as `nil` rather than as either boolean. The rule is
    /// `slopdesk_workspace::chrome::desired_collapsed`'s.
    func testTheNoOpinionRungReadsBackAsNilForBothNonAutoModes() {
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 1), true)
        XCTAssertEqual(SidebarAutoHidePolicy.desiredCollapsed(mode: .auto, tabCount: 2), false)
        for count in [0, 1, 2, 99] {
            XCTAssertNil(SidebarAutoHidePolicy.desiredCollapsed(mode: .default, tabCount: count))
            XCTAssertNil(SidebarAutoHidePolicy.desiredCollapsed(mode: .always, tabCount: count))
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
    /// The mode resolves from the config file, and a token no case spells — a file hand-edited
    /// against a newer build — repairs to `.default` rather than trapping.
    func testAutoHideTabsPanelResolvesFromTheFileAndRepairsAnUnknownToken() {
        stateCompiledDefaults()
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default)
        stateSetting("shell.auto-hide-tabs-panel", "auto")
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .auto)
        stateSetting("shell.auto-hide-tabs-panel", "garbage-from-a-future-version")
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .default, "an unknown token repairs to default")
    }

    /// The config PATH is stable: it is what the user typed in their own file, so a rename orphans
    /// their choice silently — the schema would even complete the OLD name until they re-read it.
    func testTheAutoHidePathIsDeclared() {
        XCTAssertTrue(AppConfig.compiledDefaults.declaredPaths.contains("shell.auto-hide-tabs-panel"))
    }
}
