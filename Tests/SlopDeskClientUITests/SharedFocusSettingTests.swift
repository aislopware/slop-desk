// SharedFocusSettingTests
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) decides whether THIS device's local navigation
// stages a `focusTab` / `focusPane` intent — moving every following client — or only its own
// `WorkspaceStore.DeviceFocus` overlay. It is persisted, platform-defaulted (ON macOS / OFF iOS) and
// settable through `setFollowSessionFocus(_:)`, but NO control reached it: a device kept its platform
// default forever.
//
// These pin the Settings row headlessly on the macOS `swift test` host (iOS view code rots silently —
// CLAUDE.md):
// - the pure `SharedFocusSetting` derivations map a nil store → the PLATFORM DEFAULT + not configurable
//   (a preview must never claim a state no store holds, and must never write into nothing);
// - the row's binding WRITE reaches `WorkspaceStore.setFollowSessionFocus(_:)`, and the flag survives a
//   round trip through `device-prefs.json` — a FRESH store reading the same file sees the choice.
//   `devicePreferences` is `public private(set)`, so that setter is the ONLY way a write from this module
//   can land at all — which is what makes the setter's own "resuming follow drops the device-local
//   overlay" rule (pinned in `FollowSessionFocusTests`) apply to the row for free;
// - both settings hosts (the macOS `SlopDeskSettingsScene`, the iOS `SettingsSheet`) retain the store,
//   and the environment slot the wiring rides defaults nil.

#if canImport(SwiftUI)
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SharedFocusSettingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-shared-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var fileURL: URL { directory.appendingPathComponent("device-prefs.json") }

    /// A store whose device-local facts persist to THIS test's own `device-prefs.json` (never the real one).
    private func makeWorkspaceStore() -> WorkspaceStore {
        WorkspaceStore(
            liveModel: .tree,
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

    // MARK: - The nil-store fallback (a preview / an un-injected host)

    /// No store ⇒ the row states the PLATFORM DEFAULT and disables itself. It must never claim `On` on a
    /// phone (whose default is OFF) nor `Off` on a Mac, because nothing would be backing the claim.
    func testNilStoreShowsThePlatformDefaultAndIsNotConfigurable() {
        XCTAssertEqual(
            SharedFocusSetting.isFollowing(nil),
            DevicePreferences.platformDefaultFollowSessionFocus,
            "an un-injected row states the platform default, never a made-up state",
        )
        XCTAssertFalse(
            SharedFocusSetting.isConfigurable(nil),
            "an un-injected row is disabled — a write would land nowhere",
        )
        XCTAssertEqual(
            SharedFocusSetting.valueText(nil),
            DevicePreferences.platformDefaultFollowSessionFocus ? "On" : "Off",
        )
    }

    /// A store ⇒ configurable, and the readout tracks the store rather than the platform default.
    func testStoreBackedRowIsConfigurableAndReadsTheStore() {
        let store = makeWorkspaceStore()
        XCTAssertTrue(SharedFocusSetting.isConfigurable(store))

        store.setFollowSessionFocus(true)
        XCTAssertTrue(SharedFocusSetting.isFollowing(store))
        XCTAssertEqual(SharedFocusSetting.valueText(store), "On")

        store.setFollowSessionFocus(false)
        XCTAssertFalse(SharedFocusSetting.isFollowing(store))
        XCTAssertEqual(SharedFocusSetting.valueText(store), "Off")
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

    // MARK: - The searchable All-Settings row

    /// The key is advertised in the searchable All-Settings list, jumps to the page that actually hosts
    /// the control (General), and is findable by the words a user would type.
    func testCatalogAdvertisesTheSharedFocusRowAndJumpsToGeneral() {
        let entry = AllSettingsCatalog.entries.first { $0.key == SharedFocusSetting.catalogKey }
        XCTAssertNotNil(entry, "the shared-focus row must be advertised in All Settings")
        XCTAssertEqual(entry?.bucket, .hasDedicatedTab, "the real control lives on a page, not inline")
        XCTAssertEqual(entry?.targetSection, SettingsSection.general.rawValue)
        XCTAssertTrue(
            AllSettingsCatalog.filter("focus").contains { $0.key == SharedFocusSetting.catalogKey },
            "searching 'focus' must find the row",
        )
    }
}
#endif
