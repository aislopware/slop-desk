import AislopdeskTransport
import XCTest
@testable import AislopdeskWorkspaceCore

// MARK: - RemoteWindowTabLandingTests (WS-A store landing)

/// Pins the store landing for the WS-A GUI/video pane: ``WorkspaceStore/newRemoteWindowTab(windowID:title:appName:)``
/// (the tree-path "New Remote Window Tab" / picker-resolve entry, WorkspaceStore+RemoteWindow.swift) mints a
/// `.remoteGUI` leaf pre-bound to a host window, preserves the registry-key invariant, and — through
/// `wireMaterializedLeaf` — wires the materialized ``RemoteWindowModel``'s `onEndpointCommitted` so an
/// `open()` persists the live binding back into the pane's `spec.video` (PANE REBIND: a relaunch re-streams
/// instead of re-showing the picker).
///
/// Shape assertions use the spec-only ``FakePaneSession`` seam; the `onEndpointCommitted` persistence test
/// uses a real ``LivePaneSession`` (via ``WorkspaceStore/liveMakeSession`` with a throwing
/// ``ConnectionRegistry`` — a `.remoteGUI` pane never builds a terminal mux connection) so the actual store
/// wiring runs, but NEVER instantiates `VideoWindowView`/SCStream/VT/Metal.
@MainActor
final class RemoteWindowTabLandingTests: XCTestCase {
    // MARK: - kind + invariant

    /// `newRemoteWindowTab` mints a `.remoteGUI` leaf, selects+focuses it, and leaves the registry-key
    /// invariant intact (`Set(registry ids) == Set(pane ids)`).
    func testNewRemoteWindowTabMintsRemoteGUILeaf() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)

        let id = store.newRemoteWindowTab(windowID: 42, title: "Apple", appName: "Safari")

        let handle = try XCTUnwrap(store.handle(for: id))
        XCTAssertEqual(handle.kind, .remoteGUI, "the new tab is a remote-GUI video pane")
        XCTAssertTrue(handle.kind.isVideo)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, id, "selected + focused like newTab(kind:)")

        // Registry-key invariant: one handle per pane, keyed by pane id.
        XCTAssertEqual(
            Set(store.allSessions.map(\.id)),
            Set(store.tree.allPaneIDs()),
            "registry keys == pane ids after newRemoteWindowTab",
        )
        XCTAssertTrue(store.tree.isInvariantHeld(), "tree specs==leafIDs invariant holds")
    }

    /// The leaf's spec carries the pre-bound ``VideoEndpoint`` (so the materialized model opens
    /// immediately) and the label folds title→appName→"Remote window".
    func testNewRemoteWindowTabPreBindsTheVideoEndpoint() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)

        let id = store.newRemoteWindowTab(windowID: 7, title: "", appName: "Finder")
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])
        XCTAssertEqual(spec.kind, .remoteGUI)
        XCTAssertEqual(spec.title, "Finder", "empty title folds to the app name")
        XCTAssertEqual(spec.video?.windowID, 7, "the spec is pre-bound to the chosen host window")
        XCTAssertEqual(spec.video?.appName, "Finder")
    }

    /// The picker's discovery `bundleID` is stamped into the endpoint at mint time (the sidebar Windows
    /// row's local icon-lookup key — no re-poll needed), and defaults to "" when the caller has none.
    func testNewRemoteWindowTabStampsBundleID() {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)

        let picked = store.newRemoteWindowTab(
            windowID: 9, title: "main.swift", appName: "Xcode", bundleID: "com.apple.dt.Xcode",
        )
        XCTAssertEqual(
            store.tree.activeSession?.specs[picked]?.video?.bundleID, "com.apple.dt.Xcode",
            "the discovery bundleID rides the endpoint",
        )

        let legacy = store.newRemoteWindowTab(windowID: 10, title: "W", appName: "App")
        XCTAssertEqual(
            store.tree.activeSession?.specs[legacy]?.video?.bundleID, "",
            "no bundleID ⇒ empty (icon falls back to the generic symbol)",
        )
    }

    /// A ``VideoEndpoint`` persisted BEFORE the `bundleID` field still decodes (tolerant decode → ""), so
    /// a pre-existing workspace tree loads instead of decode-failing the whole pane.
    func testVideoEndpointDecodesWithoutBundleID() throws {
        let legacyJSON = Data(#"{"windowID":42,"title":"Apple","appName":"Safari"}"#.utf8)
        let decoded = try JSONDecoder().decode(VideoEndpoint.self, from: legacyJSON)
        XCTAssertEqual(decoded.windowID, 42)
        XCTAssertEqual(decoded.appName, "Safari")
        XCTAssertEqual(decoded.bundleID, "", "missing key decodes to empty, never throws")
    }

    // MARK: - onEndpointCommitted persists into spec.video (the real wiring)

    /// With a real ``LivePaneSession`` materialized, the store's `wireMaterializedLeaf` set the model's
    /// `onEndpointCommitted`; a re-pick + `open()` then persists the NEW binding back into `spec.video`.
    /// (Drives the model directly — no UDP, no `VideoWindowView`.)
    func testOpenPersistsEndpointIntoSpecViaWiredCallback() throws {
        let registry = ConnectionRegistry { _, _ in
            throw AislopdeskTransportError.invalidState("remoteGUI pane never builds a terminal mux connection")
        }
        let store = WorkspaceStore(
            liveModel: .tree,
            makeSession: WorkspaceStore.liveMakeSession(muxRegistry: registry),
            liveVideoCap: 2,
        )

        // Land a remote-GUI tab pre-bound to window 42, then materialize its live session.
        let id = store.newRemoteWindowTab(windowID: 42, title: "Apple", appName: "Safari")
        let live = try XCTUnwrap(store.handle(for: id) as? LivePaneSession)
        let model = try XCTUnwrap(live.remoteWindow, "a remoteGUI session always has a RemoteWindowModel")
        XCTAssertNotNil(model.onEndpointCommitted, "wireMaterializedLeaf wired the persistence callback")

        // The user re-picks a DIFFERENT host window in the live pane and opens it.
        model.pick(RemoteWindowSummary(windowID: 99, appName: "Chrome", title: "GitHub", width: 800, height: 600))
        model.open()

        // The new binding is persisted back into the pane's spec (PANE REBIND).
        let spec = try XCTUnwrap(store.tree.activeSession?.specs[id])
        XCTAssertEqual(spec.video?.windowID, 99, "open() committed the re-picked window into spec.video")
        XCTAssertEqual(spec.video?.appName, "Chrome")
        XCTAssertEqual(spec.video?.title, "GitHub")
        XCTAssertEqual(spec.title, "GitHub", "the title followed the binding (it had tracked the prior binding)")
    }
}
