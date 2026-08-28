import Foundation
import SlopDeskTestSupport
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the ``AutoHideTabsPanelMode`` enum's round-trip and its repair out of the config file — what
/// the file's token decodes THROUGH. Deliberately nothing about the auto-hide DECISION: that is
/// `slopdesk_settings::chrome`, tested there, and the `SidebarAutoHidePolicy` wrapper this file used to
/// exercise was deleted with the SwiftUI wiring that was its only caller. A Swift assertion re-stating a
/// Rust one is the cross-language mirror the one-implementation rule forbids; what belongs on this side
/// is the `Defaults`/`AppConfig` bridging below, which has no Rust twin.
///
/// The Swift MARSHALLING of the surviving door — the `nil`↔`(value, present)` trip and its guarded
/// writes — is pinned by `Tests/SlopDeskClientCoreTests/ChromeAutoHideTests.swift`, beside the type that
/// performs it. No `NSWindow`/view instantiation here or there.
@MainActor
final class AutoHideTabsPanelModeTests: XCTestCase {
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
