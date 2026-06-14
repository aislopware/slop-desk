import XCTest
@testable import AislopdeskClientUI

/// Pins the `SettingsKey` fire-time accessors (default ON for the gates, with env/UserDefaults
/// overrides) — the shared source of truth between the Settings scene and the consumers.
@MainActor
final class SettingsKeyTests: XCTestCase {
    private var keys: [String] {
        [
            SettingsKey.oscNotifications,
            SettingsKey.longCommandNotifications,
            SettingsKey.systemDialogPanes,
            SettingsKey.defaultPaneKindKey,
            SettingsKey.snapPanes,
            SettingsKey.snapGrid,
            SettingsKey.showGrid,
            SettingsKey.nonOverlap,
            SettingsKey.autoSwitchLayouts,
            SettingsKey.redactSecrets,
            SettingsKey.recordClipboardHistory,
        ]
    }

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    func testGatesDefaultOnWhenUnset() {
        XCTAssertTrue(SettingsKey.oscNotificationsEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled)
        XCTAssertTrue(SettingsKey.systemDialogPanesEnabled)
    }

    func testGatesRespectAnExplicitFalse() {
        UserDefaults.standard.set(false, forKey: SettingsKey.oscNotifications)
        UserDefaults.standard.set(false, forKey: SettingsKey.systemDialogPanes)
        XCTAssertFalse(SettingsKey.oscNotificationsEnabled)
        XCTAssertFalse(SettingsKey.systemDialogPanesEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled, "an unset key stays default-ON")
    }

    func testCanvasKeyWireValuesArePinned() {
        // These exact strings are the single source of truth shared with every @AppStorage consumer
        // (CanvasView / CanvasItemView / FloatingPaneHandle / the menu toggles). Pinning the wire values
        // here means a rename that would silently split-brain the Settings UI from the canvas consumers
        // (a user toggles a setting that no longer applies) fails this test.
        XCTAssertEqual(SettingsKey.snapPanes, "canvas.snapPanes")
        XCTAssertEqual(SettingsKey.snapGrid, "canvas.snapGrid")
        XCTAssertEqual(SettingsKey.showGrid, "canvas.showGrid")
        XCTAssertEqual(SettingsKey.nonOverlap, "canvas.nonOverlap")
    }

    func testPrivacyAndLayoutGatesDefaultOnAndRespectFalse() {
        XCTAssertTrue(SettingsKey.redactSecretsEnabled)
        XCTAssertTrue(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertTrue(SettingsKey.autoSwitchLayoutsEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.redactSecrets)
        UserDefaults.standard.set(false, forKey: SettingsKey.recordClipboardHistory)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoSwitchLayouts)
        XCTAssertFalse(SettingsKey.redactSecretsEnabled)
        XCTAssertFalse(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertFalse(SettingsKey.autoSwitchLayoutsEnabled)
    }

    func testDefaultPaneKindDefaultsToTerminalAndRoundTrips() {
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal)
        UserDefaults.standard.set(PaneKind.claudeCode.rawValue, forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .claudeCode)
        UserDefaults.standard.set("garbage", forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal, "an invalid raw value falls back to terminal")
    }
}
