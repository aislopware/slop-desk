// SharedFocusSettingTests
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) decides whether THIS device's local navigation
// stages a `focusTab` / `focusPane` intent — moving every following client — or only its own
// `WorkspaceStore.DeviceFocus` overlay. It is persisted, platform-defaulted (ON macOS / OFF iOS) and
// settable through `setFollowSessionFocus(_:)`, but NO control reached it: a device kept its platform
// default forever.
//
// These pin the Settings row's SwiftUI-side wiring headlessly on the iOS triple (docs/56 F4c: the row's
// host, `SettingsSheet`, is `SlopDeskPhoneUI`, which only the simulator bundle compiles —
// `slopdesk-gate ios-tests`):
// - the row's binding WRITE reaches `WorkspaceStore.setFollowSessionFocus(_:)`, and the flag survives a
//   round trip through `device-prefs.json` — a FRESH store reading the same file sees the choice.
//   `devicePreferences` is `public private(set)`, so that setter is the ONLY way a write from this module
//   can land at all — which is what makes the setter's own "resuming follow drops the device-local
//   overlay" rule (pinned in `FollowSessionFocusTests`) apply to the row for free;
// - the iOS settings host (`SettingsSheet`) retains the store, and the environment slot the wiring rides
//   defaults nil. The Mac's host is a different object in a module this bundle cannot link
//   (`MacSettingsWindowController`, `SlopDeskMacUI`), so its half of the claim is not asserted here.
//
// docs/56: the PURE derivations (`isFollowing`, `isConfigurable`, `valueText`, `catalogKey`) moved to
// `SlopDeskClientCore` in batch 2 of the draining-floor split — they name no view framework — and their
// pins moved with them to `Tests/SlopDeskClientCoreTests/SharedFocusSettingTests.swift`. What is left
// here is the half that needs SwiftUI itself: the `Binding`, the `@Entry` environment slot and the
// sheet wiring. `SlopDeskClientCore` is `@testable`-imported for `SharedFocusSetting`, which is
// `package`: this bundle is an Xcode target OUTSIDE the SwiftPM package, so a plain `import` cannot see
// a `package` declaration at all.

#if canImport(SwiftUI)
import Foundation
import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskPhoneUI

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
    ///
    /// The double is ``FakePaneSession``, compiled into this bundle from `SlopDeskWorkspaceCoreTests`
    /// rather than copied. It used to be `MountTestPaneSession`, a fixture that was byte-identical to
    /// `FakePaneSession` from `@MainActor` to its closing brace and existed only because the SwiftPM
    /// suite this test came from could not see the real one. This bundle can, so the copy went with
    /// the move (increment 63). The Mac's own copy is NOT the same situation — `SlopDeskMacUITests`
    /// still cannot reach `FakePaneSession`, which is why one remains there.
    private func makeWorkspaceStore() -> WorkspaceStore {
        WorkspaceStore(
            makeSession: { seed in FakePaneSession(seed.spec) },
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
