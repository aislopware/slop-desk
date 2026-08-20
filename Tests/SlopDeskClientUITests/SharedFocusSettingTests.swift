// SharedFocusSettingTests
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) decides whether THIS device's local navigation
// stages a `focusTab` / `focusPane` intent — moving every following client — or only its own
// `WorkspaceStore.DeviceFocus` overlay. It is persisted, platform-defaulted (ON macOS / OFF iOS) and
// settable through `setFollowSessionFocus(_:)`, but NO control reached it: a device kept its platform
// default forever.
//
// These pin the Settings row's SwiftUI-side wiring headlessly on the macOS `swift test` host (iOS view
// code rots silently — CLAUDE.md):
// - the row's binding WRITE reaches `WorkspaceStore.setFollowSessionFocus(_:)`, and the flag survives a
//   round trip through `device-prefs.json` — a FRESH store reading the same file sees the choice.
//   `devicePreferences` is `public private(set)`, so that setter is the ONLY way a write from this module
//   can land at all — which is what makes the setter's own "resuming follow drops the device-local
//   overlay" rule (pinned in `FollowSessionFocusTests`) apply to the row for free;
// - both settings hosts (the macOS `MacSettingsWindowController`, the iOS `SettingsSheet`) retain the store,
//   and the environment slot the wiring rides defaults nil.
//
// docs/56: the PURE derivations (`isFollowing`, `isConfigurable`, `valueText`, `catalogKey`) moved to
// `SlopDeskClientCore` in batch 2 of the draining-floor split — they name no view framework — and their
// pins moved with them to `Tests/SlopDeskClientCoreTests/SharedFocusSettingTests.swift`. What is left
// here is the half that needs SwiftUI itself: the `Binding`, the `@Entry` environment slot and the
// sheet wiring.

#if canImport(SwiftUI)
import Foundation
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SharedFocusSettingTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-shared-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var fileURL: URL { directory.appendingPathComponent("device-prefs.json") }

    /// A store whose device-local facts persist to THIS test's own `device-prefs.json` (never the real one).
    private func makeWorkspaceStore() -> WorkspaceStore {
        WorkspaceStore(
            makeSession: { seed in MountTestPaneSession(seed.spec) },
            devicePreferences: DevicePreferencesStore(fileURL: fileURL),
        )
    }

    private func makePreferencesStore(_ name: String = #function) -> PreferencesStore {
        let suite = "SharedFocusSettingTests." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
    }

    // MARK: - The row reaches `setFollowSessionFocus` and persists

    /// The load-bearing pin: flipping the ROW's binding is what `setFollowSessionFocus(_:)` sees, and the
    /// choice survives to a FRESH `DevicePreferencesStore` reading the same `device-prefs.json`. Both
    /// directions, so neither is an accident of the platform default.
    func testRowBindingReachesSetFollowSessionFocusAndSurvivesADiskRoundTrip() {
        let store = makeWorkspaceStore()
        let binding = SharedFocusSetting.binding(store)

        binding.wrappedValue = false
        XCTAssertFalse(store.devicePreferences.followSessionFocus, "the row's write reaches the store")
        XCTAssertFalse(
            DevicePreferencesStore(fileURL: fileURL).load().followSessionFocus,
            "OFF must survive a round trip through device-prefs.json",
        )
        XCTAssertFalse(binding.wrappedValue, "the row reads back what it wrote")

        binding.wrappedValue = true
        XCTAssertTrue(store.devicePreferences.followSessionFocus)
        XCTAssertTrue(
            DevicePreferencesStore(fileURL: fileURL).load().followSessionFocus,
            "ON must survive a round trip through device-prefs.json",
        )
        XCTAssertTrue(binding.wrappedValue)
    }

    /// A nil store SWALLOWS the write rather than trapping — a preview toggle is inert, never a crash.
    func testNilStoreBindingWriteIsInert() {
        let binding = SharedFocusSetting.binding(nil)
        binding.wrappedValue = !DevicePreferences.platformDefaultFollowSessionFocus
        XCTAssertEqual(binding.wrappedValue, DevicePreferences.platformDefaultFollowSessionFocus)
    }

    // MARK: - The wiring both settings hosts ride

    func testWorkspaceStoreEnvironmentSlotDefaultsNilAndRoundTrips() {
        var env = EnvironmentValues()
        XCTAssertNil(env.workspaceStore, "the slot defaults nil so an un-injected row disables itself")
        let store = makeWorkspaceStore()
        env.workspaceStore = store
        XCTAssertTrue(env.workspaceStore === store)
    }

    /// The iOS sheet must RETAIN the workspace store handed to it — a sheet does not inherit the
    /// presenter's custom environment values, so without this the iOS row is permanently disabled (the
    /// exact shape of the Agents-card regression).
    func testIOSSettingsSheetRetainsTheWorkspaceStore() {
        let store = makeWorkspaceStore()
        let sheet = SettingsSheet(store: makePreferencesStore(), workspace: store)
        XCTAssertTrue(sheet.workspace === store)
        XCTAssertTrue(SharedFocusSetting.isConfigurable(sheet.workspace))
    }

    func testSettingsSheetWithoutAWorkspaceStoreStaysDisabled() {
        let sheet = SettingsSheet(store: makePreferencesStore())
        XCTAssertNil(sheet.workspace)
        XCTAssertFalse(SharedFocusSetting.isConfigurable(sheet.workspace))
    }
}
#endif
