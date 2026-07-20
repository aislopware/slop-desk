// VideoPaneModesPersistenceTests — pins the latched video-pane modes' TARGET-keyed persistence
// (`TreeWorkspace.videoModesByTarget`): the additive codable contract, the explicit-toggle → map
// wiring, close-tab → reopen-the-same-target restore, and the relaunch restore seed. The runtime
// (detach-remount) half — injector `didSet` re-asserts — is pinned in `RemoteWindowStreamControlsTests`.

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

    /// Desktop keys by DISPLAY; a window keys by its owning APP (ids recycle, titles churn); a
    /// manual-id binding (no app) falls back to the raw window id.
    func testModesKeyDerivation() {
        XCTAssertEqual(VideoEndpoint(windowID: 0, title: "Desktop", displayID: 2).modesKey, "display:2")
        XCTAssertEqual(VideoEndpoint(windowID: 42, title: "Docs", appName: "Safari").modesKey, "app:Safari")
        XCTAssertEqual(VideoEndpoint(windowID: 42, title: "Docs").modesKey, "window:42")
    }

    // MARK: - TreeWorkspace codable (additive)

    func testTreeRoundTripsVideoModesByTarget() throws {
        var tree = TreeWorkspace.defaultWorkspace()
        tree.videoModesByTarget = [
            "display:0": VideoPaneModes(immersive: true, fpsCap: 30),
            "app:Safari": VideoPaneModes(audioEnabled: true, bitrateCeilingBps: 10_000_000),
        ]
        let restored = try decoder.decode(TreeWorkspace.self, from: makeEncoder().encode(tree))
        XCTAssertEqual(restored.videoModesByTarget, tree.videoModesByTarget)
    }

    /// An older file without the key decodes to an empty map — never traps (additive contract).
    func testAbsentVideoModesByTargetKeyDecodesEmpty() throws {
        var tree = TreeWorkspace.defaultWorkspace()
        tree.videoModesByTarget = ["display:0": VideoPaneModes(immersive: true)]
        let data = try makeEncoder().encode(tree)
        // Simulate a pre-modes file by stripping the key from the emitted JSON object.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "videoModesByTarget"), "precondition: the key was emitted")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let restored = try decoder.decode(TreeWorkspace.self, from: stripped)
        XCTAssertEqual(restored.videoModesByTarget, [:])
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
    private func makeLiveStore(restoringTree: TreeWorkspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoringTree: restoringTree, liveModel: .tree, makeSession: { spec in
            LivePaneSession.make(
                spec,
                makeClient: { _ in fatalError("connect() never runs in this test") },
                makeInspector: { _ in nil },
            )
        })
    }

    private func remoteWindowModel(in store: WorkspaceStore, for id: PaneID) throws -> RemoteWindowModel {
        try XCTUnwrap((store.handle(for: id) as? LivePaneSession)?.remoteWindow)
    }

    /// The persistence edge: an explicit audio toggle lands under the pane's TARGET key, and toggling
    /// everything back off removes the entry (default-normalized — the map never accretes no-op rows).
    func testExplicitToggleLandsUnderTheTargetKey() throws {
        let store = makeLiveStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let model = try remoteWindowModel(in: store, for: id)

        model.open()
        model.audioInjector = { _ in }
        model.applyAudioEnabled(true)

        XCTAssertEqual(
            store.tree.videoModesByTarget["app:Safari"],
            VideoPaneModes(audioEnabled: true),
            "the explicit toggle persists under the target key, not the pane",
        )

        model.applyAudioEnabled(false)
        XCTAssertNil(
            store.tree.videoModesByTarget["app:Safari"],
            "all-default modes remove the entry",
        )
    }

    /// **Close tab → reopen the same target restores the modes.** The reopened pane is a brand-new
    /// PaneID/spec (everything pane-keyed died with the tab); the target-keyed map re-seeds the fresh
    /// model at materialization, and the injector `didSet` re-asserts push the wish into its first session.
    func testCloseTabThenReopenSameTargetRestoresModes() throws {
        let store = makeLiveStore()
        let first = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let firstModel = try remoteWindowModel(in: store, for: first)
        firstModel.open()
        firstModel.audioInjector = { _ in }
        firstModel.streamSettingsInjector = { _, _ in }
        firstModel.applyAudioEnabled(true)
        firstModel.applyStreamSettings(fpsCap: 30, bitrateCeilingBps: 0)

        store.closePaneTree(first)
        XCTAssertNil(store.handle(for: first), "the pane is gone with its tab")

        // Reopen the SAME window (same app) — a brand-new pane.
        let second = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
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

    /// **Relaunch restores too:** the map rides the persisted tree, so a store restored from it seeds
    /// the re-materialized pane's model.
    func testRelaunchRestoreSeedsFromPersistedTree() throws {
        let store = makeLiveStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let model = try remoteWindowModel(in: store, for: id)
        model.open()
        model.viewportInjector = { _ in }
        model.toggleViewportLock()

        // Simulate the relaunch: encode → decode the tree, restore a fresh store from it.
        let restoredTree = try decoder.decode(TreeWorkspace.self, from: makeEncoder().encode(store.tree))
        let relaunched = makeLiveStore(restoringTree: restoredTree)
        let restoredID = try XCTUnwrap(
            relaunched.tree.allPaneIDs().first { relaunched.tree.spec(for: $0)?.video?.windowID == 42 },
        )
        let restoredModel = try remoteWindowModel(in: relaunched, for: restoredID)
        XCTAssertTrue(restoredModel.viewportLocked, "the persisted target modes seed the relaunched pane")
    }

    /// A RE-TARGET inside one pane (pick a different window) re-seeds from the NEW target's saved
    /// modes — each target keeps its own latched set.
    func testRepickSeedsTheNewTargetsModes() throws {
        let store = makeLiveStore()
        // Save modes for Notes under its own key first.
        let notes = try XCTUnwrap(store.openRemoteWindow(windowID: 7, title: "Ideas", appName: "Notes"))
        let notesModel = try remoteWindowModel(in: store, for: notes)
        notesModel.open()
        notesModel.audioInjector = { _ in }
        notesModel.applyAudioEnabled(true)
        store.closePaneTree(notes)

        // A Safari pane with no saved modes re-picks to Notes → inherits Notes' saved modes.
        let pane = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let model = try remoteWindowModel(in: store, for: pane)
        model.open()
        XCTAssertFalse(model.audioStreamEnabled, "Safari has no saved modes")
        model.close()
        model.pick(RemoteWindowSummary(windowID: 7, appName: "Notes", title: "Ideas", width: 800, height: 600))
        model.open()
        XCTAssertTrue(model.audioStreamEnabled, "the endpoint commit seeds the NEW target's saved modes")
    }
}
