// VideoPaneModesPersistenceTests — pins the latched video-pane modes' TARGET-keyed persistence
// (`DevicePreferences.videoModesByTarget`, device-local: two clients on one host keep their own
// latches): the codable contract, the explicit-toggle → map wiring, close-tab → reopen-the-same-target
// restore, and the relaunch restore seed. The runtime (detach-remount) half — injector `didSet`
// re-asserts — is pinned in `RemoteWindowStreamControlsTests`.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class VideoPaneModesPersistenceTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private let decoder = JSONDecoder()

    // MARK: - Target key (VideoEndpoint.modesKey)

    /// Desktop keys by DISPLAY; a window-shaped endpoint (the automation seam) keys by its owning APP
    /// (ids recycle, titles churn); a manual-id binding (no app) falls back to the raw window id.
    func testModesKeyDerivation() {
        XCTAssertEqual(VideoEndpoint(windowID: 0, title: "Desktop", displayID: 2).modesKey, "display:2")
        XCTAssertEqual(VideoEndpoint(windowID: 42, title: "Docs", appName: "Safari").modesKey, "app:Safari")
        XCTAssertEqual(VideoEndpoint(windowID: 42, title: "Docs").modesKey, "window:42")
    }

    // MARK: - DevicePreferences codable

    func testDevicePreferencesRoundTripVideoModesByTarget() throws {
        var prefs = DevicePreferences()
        prefs.videoModesByTarget = [
            "display:0": VideoPaneModes(immersive: true, fpsCap: 30),
            "app:Safari": VideoPaneModes(audioEnabled: true, bitrateCeilingBps: 10_000_000),
        ]
        let restored = try decoder.decode(DevicePreferences.self, from: makeEncoder().encode(prefs))
        XCTAssertEqual(restored.videoModesByTarget, prefs.videoModesByTarget)
    }

    /// Per-field additive decode + validate-then-default on the mode struct itself: a partial object
    /// fills the rest with defaults, and a negative persisted cap is repaired to auto.
    func testPartialAndInvalidModesDecodeToDefaults() throws {
        let json = """
        { "audioEnabled": true, "fpsCap": -5 }
        """
        let modes = try decoder.decode(VideoPaneModes.self, from: Data(json.utf8))
        XCTAssertTrue(modes.audioEnabled)
        XCTAssertFalse(modes.immersive, "absent field decodes to its default")
        XCTAssertFalse(modes.viewportLocked)
        XCTAssertEqual(modes.fpsCap, 0, "a negative persisted cap is repaired to auto")
        XCTAssertEqual(modes.bitrateCeilingBps, 0)
    }

    // MARK: - Store wiring: explicit toggle → target map, reopen/relaunch → seeded model

    /// One real session factory for the store tests. `makeClient` is never called here: a video pane
    /// has no PATH-1 connection, and the default workspace's terminal pane is lazy-connect (no view
    /// ever triggers `connect()` in a headless store test).
    private func makeLiveStore(devicePreferences: DevicePreferencesStore? = nil) -> WorkspaceStore {
        WorkspaceStore(
            liveModel: .tree,
            makeSession: { spec in
                LivePaneSession.make(
                    spec,
                    makeClient: { _ in fatalError("connect() never runs in this test") },
                    makeInspector: { _ in nil },
                )
            },
            devicePreferences: devicePreferences,
        )
    }

    private func remoteWindowModel(in store: WorkspaceStore, for id: PaneID) throws -> RemoteWindowModel {
        try XCTUnwrap((store.handle(for: id) as? LivePaneSession)?.remoteWindow)
    }

    /// The persistence edge: an explicit audio toggle lands under the pane's TARGET key, and toggling
    /// everything back off removes the entry (default-normalized — the map never accretes no-op rows).
    func testExplicitToggleLandsUnderTheTargetKey() throws {
        let store = makeLiveStore()
        let id = store.openDesktopWindow()
        let model = try remoteWindowModel(in: store, for: id)

        model.open()
        model.audioInjector = { _ in }
        model.applyAudioEnabled(true)

        XCTAssertEqual(
            store.devicePreferences.videoModesByTarget["display:0"],
            VideoPaneModes(audioEnabled: true),
            "the explicit toggle persists under the target key, not the pane",
        )

        model.applyAudioEnabled(false)
        XCTAssertNil(
            store.devicePreferences.videoModesByTarget["display:0"],
            "all-default modes remove the entry",
        )
    }

    /// **Close tab → reopen the same target restores the modes.** The reopened pane is a brand-new
    /// PaneID/spec (everything pane-keyed died with the tab); the target-keyed map re-seeds the fresh
    /// model at materialization, and the injector `didSet` re-asserts push the wish into its first session.
    func testCloseTabThenReopenSameTargetRestoresModes() throws {
        let store = makeLiveStore()
        let first = store.openDesktopWindow(displayID: 2)
        let firstModel = try remoteWindowModel(in: store, for: first)
        firstModel.open()
        firstModel.audioInjector = { _ in }
        firstModel.streamSettingsInjector = { _, _ in }
        firstModel.applyAudioEnabled(true)
        firstModel.applyStreamSettings(fpsCap: 30, bitrateCeilingBps: 0)

        store.closePaneTree(first)
        XCTAssertNil(store.handle(for: first), "the pane is gone with its tab")

        // Reopen the SAME target (same display) — a brand-new pane.
        let second = store.openDesktopWindow(displayID: 2)
        XCTAssertNotEqual(second, first)
        let secondModel = try remoteWindowModel(in: store, for: second)

        XCTAssertTrue(secondModel.audioStreamEnabled, "the target's saved modes seed the reopened pane")
        XCTAssertEqual(secondModel.streamFpsCap, 30)

        // And the re-assert half: the fresh session's sink publish pushes the restored wish.
        secondModel.open()
        var audio: [Bool] = []
        secondModel.audioInjector = { audio.append($0) }
        XCTAssertEqual(audio, [true])
    }

    /// **Relaunch restores too:** the map rides `device-prefs.json`, through a REAL file. The desktop
    /// PANE itself never restores across relaunch (docs/DECISIONS.md 2026-07-22 — the launch restore
    /// drops it), so the relaunch contract is: reopening the SAME target in a store built on the same
    /// preferences file seeds the fresh model from the persisted target-keyed map.
    func testRelaunchRestoreSeedsFromPersistedDevicePreferences() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-video-modes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefsStore = DevicePreferencesStore(fileURL: dir.appendingPathComponent("device-prefs.json"))

        let store = makeLiveStore(devicePreferences: prefsStore)
        let id = store.openDesktopWindow(displayID: 2)
        let model = try remoteWindowModel(in: store, for: id)
        model.open()
        model.viewportInjector = { _ in }
        model.toggleViewportLock()

        // Simulate the relaunch: a fresh store reading the SAME preferences file.
        let relaunched = makeLiveStore(devicePreferences: prefsStore)
        XCTAssertNil(
            relaunched.tree.allPaneIDs().first { relaunched.tree.spec(for: $0)?.kind == .desktop },
            "a persisted desktop pane never restores (the dedicated-window model)",
        )
        let reopened = relaunched.openDesktopWindow(displayID: 2)
        let restoredModel = try remoteWindowModel(in: relaunched, for: reopened)
        XCTAssertTrue(restoredModel.viewportLocked, "the persisted target modes seed the reopened target")
    }

    /// A RE-TARGET inside one pane (switch to a different display) re-seeds from the NEW target's
    /// saved modes — each target keeps its own latched set.
    func testRepickSeedsTheNewTargetsModes() throws {
        let store = makeLiveStore()
        // Save modes for display 7 under its own key first.
        let second = store.openDesktopWindow(displayID: 7)
        let secondModel = try remoteWindowModel(in: store, for: second)
        secondModel.open()
        secondModel.audioInjector = { _ in }
        secondModel.applyAudioEnabled(true)
        store.closePaneTree(second)

        // A main-display pane with no saved modes switches to display 7 → inherits its saved modes.
        let pane = store.openDesktopWindow()
        let model = try remoteWindowModel(in: store, for: pane)
        model.open()
        XCTAssertFalse(model.audioStreamEnabled, "the main display has no saved modes")
        model.switchDisplay(to: 7)
        XCTAssertTrue(model.audioStreamEnabled, "the endpoint commit seeds the NEW target's saved modes")
    }
}
