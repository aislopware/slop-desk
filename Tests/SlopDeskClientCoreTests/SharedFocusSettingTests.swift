// SharedFocusSettingTests — the pure derivations, headless.
//
// `DevicePreferences.followSessionFocus` (docs/45 §8.2) decides whether THIS device's local navigation
// stages a `focusTab` / `focusPane` intent — moving every following client — or only its own
// `WorkspaceStore.DeviceFocus` overlay. It is persisted, platform-defaulted (ON macOS / OFF iOS) and
// settable through `setFollowSessionFocus(_:)`.
//
// These pin the nil-store fallback and the store-backed readout:
// - a nil store ⇒ the PLATFORM DEFAULT and not configurable (a preview must never claim a state no
//   store holds, and must never write into nothing);
// - a store-backed row is configurable, and its readout tracks the store;
// - the row is advertised in the searchable All-Settings list and jumps to the page that hosts it.
//
// docs/56: moved out of `SlopDeskClientUITests` in batch 2 of the draining-floor split — `isFollowing`,
// `isConfigurable`, `valueText` and `catalogKey` name no view framework, so they descended to
// `SlopDeskClientCore` and the pins followed. `binding(_:)` — a SwiftUI `Binding<Bool>` — and the
// environment-slot / `SettingsSheet` wiring stayed in
// `Tests/SlopDeskClientUITests/SharedFocusSettingTests.swift`, which is what its own header now says.

import Foundation
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

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
            makeSession: { seed in RecordingPaneSession(seed.spec) },
            devicePreferences: DevicePreferencesStore(fileURL: fileURL),
        )
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
