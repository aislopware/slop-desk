import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the detach-to-own-window model (docs/DECISIONS.md — pane detach ↔ reattach):
/// ``WorkspaceTreeOps/detachPane(_:in:)`` moves a leaf OUT of the split tree into the session's
/// ``Session/detached`` list while its spec (and therefore its live registry handle) survives;
/// ``WorkspaceTreeOps/reattachPane(_:in:)`` folds it back KEEPING the `PaneID`. The widened invariant is
/// `specs.keys == leafIDs ∪ detachedIDs`. Pure ops first, then the store-level reconcile behaviour with
/// the ``FakePaneSession`` seam (never a real client/host).
final class DetachPaneTests: XCTestCase {
    // MARK: - Fixtures

    /// One session, one tab, two terminal leaves (a || split) — the smallest tree where detach leaves
    /// the tab alive. Returns (workspace, left leaf, right leaf).
    private func twoPaneWorkspace() -> (TreeWorkspace, PaneID, PaneID) {
        let ws = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "left"))
        let left = ws.allPaneIDs()[0]
        let (split, right) = WorkspaceTreeOps.splitPane(
            left, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "right"), in: ws,
        )
        return (split, left, right)
    }

    // MARK: - detachPane (pure op)

    func testDetachRemovesLeafFromTreeButKeepsSpecAndRecordsOrigin() {
        let (ws, left, right) = twoPaneWorkspace()
        let originTab = ws.sessions[0].tabs[0].id

        let out = WorkspaceTreeOps.detachPane(right, in: ws)

        XCTAssertFalse(out.contains(right), "detached pane left the split tree")
        XCTAssertTrue(out.contains(left), "sibling stays tiled")
        XCTAssertTrue(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].detached.map(\.pane), [right])
        XCTAssertEqual(out.sessions[0].detached[0].originTab, originTab, "origin tab recorded for reattach")
        XCTAssertNotNil(out.sessions[0].specs[right], "spec survives — the live handle must not tear down")
        XCTAssertTrue(out.isInvariantHeld(), "specs == leafIDs ∪ detachedIDs")
    }

    func testDetachSolePaneKeepsSessionAliveWithReseededTab() {
        let ws = TreeWorkspace.singlePane(spec: PaneSpec(kind: .desktop, title: "desktop"))
        let pane = ws.allPaneIDs()[0]
        let sessionID = ws.sessions[0].id

        let out = WorkspaceTreeOps.detachPane(pane, in: ws)

        XCTAssertEqual(out.sessions.map(\.id), [sessionID], "the owning session SURVIVES (it owns the satellite)")
        XCTAssertTrue(out.isDetached(pane))
        XCTAssertNotNil(out.sessions[0].specs[pane])
        XCTAssertEqual(out.sessions[0].tabs.count, 1, "normalizingActive re-seeded a default tab")
        XCTAssertFalse(out.sessions[0].tabs[0].contains(pane), "the re-seeded tab is fresh, not the satellite")
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testDetachFocusedZoomedPaneClearsZoomAndRepointsFocus() {
        var (ws, left, right) = twoPaneWorkspace()
        ws = WorkspaceTreeOps.focusPane(right, in: ws)
        ws = WorkspaceTreeOps.toggleZoom(right, in: ws)

        let out = WorkspaceTreeOps.detachPane(right, in: ws)

        XCTAssertNil(out.sessions[0].tabs[0].zoomedPane, "dangling zoom cleared")
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, left, "focus repointed to the survivor")
    }

    func testDetachAbsentOrAlreadyDetachedIsNoOp() {
        let (ws, _, right) = twoPaneWorkspace()
        let detachedOnce = WorkspaceTreeOps.detachPane(right, in: ws)

        XCTAssertEqual(WorkspaceTreeOps.detachPane(PaneID(), in: ws), ws, "absent id no-ops")
        XCTAssertEqual(
            WorkspaceTreeOps.detachPane(right, in: detachedOnce), detachedOnce,
            "an already-detached pane is not a tree leaf — no-op, no duplicate entry",
        )
    }

    // MARK: - reattachPane (pure op)

    func testReattachReturnsToOriginTabFocusedAndRevealed() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = WorkspaceTreeOps.detachPane(right, in: ws)

        let out = WorkspaceTreeOps.reattachPane(right, in: detached)

        XCTAssertTrue(out.contains(right), "pane is a tree leaf again")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabs.count, 1, "reattached into the ORIGIN tab, not a new one")
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, right, "reattached pane is focused")
        XCTAssertTrue(out.contains(left))
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachFallsBackToActiveTabWhenOriginTabClosed() {
        let (ws, left, right) = twoPaneWorkspace()
        var detached = WorkspaceTreeOps.detachPane(right, in: ws)
        // Close the origin tab (its sole survivor `left` cascades the tab away; the session survives
        // because it still owns the detached pane) — a fresh default tab is re-seeded.
        detached = WorkspaceTreeOps.closePane(left, in: detached)
        XCTAssertTrue(detached.isDetached(right), "satellite survives its origin tab closing")

        let out = WorkspaceTreeOps.reattachPane(right, in: detached)

        XCTAssertTrue(out.contains(right))
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.activeSession?.activeTab?.activePane, right, "landed focused in the active tab")
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachNotDetachedIsNoOp() {
        let (ws, _, right) = twoPaneWorkspace()
        XCTAssertEqual(WorkspaceTreeOps.reattachPane(right, in: ws), ws)
        XCTAssertEqual(WorkspaceTreeOps.reattachPane(PaneID(), in: ws), ws)
    }

    // MARK: - closeDetachedPane (pure op)

    func testCloseDetachedPaneDropsEntryAndSpec() {
        let (ws, _, right) = twoPaneWorkspace()
        let detached = WorkspaceTreeOps.detachPane(right, in: ws)

        let out = WorkspaceTreeOps.closeDetachedPane(right, in: detached)

        XCTAssertFalse(out.isDetached(right))
        XCTAssertNil(out.sessions[0].specs[right], "spec dropped → reconcile tears the handle down")
        XCTAssertTrue(out.isInvariantHeld())
    }

    // MARK: - cascade survival (the reviewer-flagged session-drop hazard)

    func testClosingLastTreePaneKeepsSessionOwningSatellites() {
        let (ws, left, right) = twoPaneWorkspace()
        let sessionID = ws.sessions[0].id
        var out = WorkspaceTreeOps.detachPane(right, in: ws)

        // `left` is now the session's sole tree pane; closing it empties the last tab. The cascade must
        // NOT drop the session — it still owns the satellite's spec.
        out = WorkspaceTreeOps.closePane(left, in: out)

        XCTAssertEqual(out.sessions.map(\.id), [sessionID], "session survives — it owns a satellite")
        XCTAssertTrue(out.isDetached(right))
        XCTAssertNotNil(out.sessions[0].specs[right])
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testExplicitCloseSessionDropsItsSatellitesToo() {
        let (ws, _, right) = twoPaneWorkspace()
        var out = WorkspaceTreeOps.detachPane(right, in: ws)
        let sessionID = out.sessions[0].id

        out = WorkspaceTreeOps.closeSession(sessionID, in: out)

        XCTAssertFalse(out.isDetached(right), "an explicit session close is destructive — satellites included")
        XCTAssertNil(out.spec(for: right))
    }

    // MARK: - Persistence (additive Codable + normalizing repairs + launch re-dock)

    func testSessionDetachedRoundTripsAndOldFilesDecodeEmpty() throws {
        let (ws, _, right) = twoPaneWorkspace()
        let detached = WorkspaceTreeOps.detachPane(right, in: ws)

        let data = try JSONEncoder().encode(detached.sessions[0])
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded.detached, detached.sessions[0].detached, "detached list round-trips")
        XCTAssertEqual(decoded.specs[right], detached.sessions[0].specs[right])

        // A pre-feature file (no `detached` key) decodes to an empty list — additive tolerance.
        let plain = try JSONEncoder().encode(ws.sessions[0])
        XCTAssertFalse(
            (String(bytes: plain, encoding: .utf8) ?? "").contains("\"detached\""),
            "a detach-free session encodes NO detached key (byte-stable with pre-feature files)",
        )
        let decodedPlain = try JSONDecoder().decode(Session.self, from: plain)
        XCTAssertEqual(decodedPlain.detached, [])
    }

    func testNormalizingSpecsRepairsDetachedList() {
        let (ws, left, right) = twoPaneWorkspace()
        var corrupt = WorkspaceTreeOps.detachPane(right, in: ws)
        // Corrupt the file three ways: an entry shadowing a live tree leaf, a duplicate of a valid
        // entry, and an entry with no spec to materialize from.
        let specless = PaneID()
        corrupt.sessions[0].detached.append(DetachedPane(pane: left))
        corrupt.sessions[0].detached.append(DetachedPane(pane: right))
        corrupt.sessions[0].detached.append(DetachedPane(pane: specless))

        let out = corrupt.normalizingSpecs()

        XCTAssertEqual(out.sessions[0].detached.map(\.pane), [right], "tree-shadowed / dupe / spec-less dropped")
        XCTAssertNotNil(out.sessions[0].specs[right], "the valid satellite's spec is KEPT, not orphan-pruned")
        XCTAssertNotNil(out.sessions[0].specs[left])
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testRedockingFoldsDetachedBackWithoutStealingSelection() {
        // Two tabs; detach a pane from tab 0, keep tab 1 selected — the launch re-dock must fold the
        // pane back into its origin tab while PRESERVING the persisted selection.
        var (ws, _, right) = twoPaneWorkspace()
        let (grown, _) = WorkspaceTreeOps.newTab(in: ws, spec: PaneSpec(kind: .terminal, title: "t2"))
        ws = grown // newTab selected tab 1
        var detached = WorkspaceTreeOps.detachPane(right, in: ws)
        detached = WorkspaceTreeOps.selectTab(1, in: detached)

        let out = detached.redockingDetachedPanes()

        XCTAssertTrue(out.contains(right), "detached pane re-docked at launch")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabIndex(containing: right), 0, "back into its ORIGIN tab")
        XCTAssertEqual(out.sessions[0].activeTabIndex, 1, "persisted selection preserved")
        XCTAssertTrue(out.isInvariantHeld())
    }

    // MARK: - Store-level reconcile (the live-handle survival contract)

    /// A store whose canvas is empty (so only the tree drives the registry), seeded with `restoringTree`
    /// and the ``FakePaneSession`` seam.
    @MainActor
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: []), focusedPane: nil),
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
        )
    }

    @MainActor
    func testStoreDetachKeepsHandleAliveAndReattachKeepsIdentity() {
        let (ws, _, right) = twoPaneWorkspace()
        let store = makeTreeStore(restoringTree: ws)
        let fakeBefore = store.handle(for: right) as? FakePaneSession
        XCTAssertNotNil(fakeBefore)

        store.detachPaneToWindow(right)

        XCTAssertFalse(store.tree.contains(right))
        XCTAssertTrue(store.tree.isDetached(right))
        XCTAssertEqual(store.detachedPanes.map(\.pane), [right])
        let fakeDetached = store.handle(for: right) as? FakePaneSession
        XCTAssertTrue(fakeBefore === fakeDetached, "registry handle SURVIVES the detach (no teardown)")
        XCTAssertEqual(fakeDetached?.teardownCount, 0)

        store.reattachPane(right)

        XCTAssertTrue(store.tree.contains(right))
        XCTAssertTrue(store.detachedPanes.isEmpty)
        XCTAssertTrue(fakeBefore === (store.handle(for: right) as? FakePaneSession), "same handle after reattach")
        XCTAssertEqual(fakeBefore?.teardownCount, 0)
    }

    @MainActor
    func testStoreClosePaneTreeOnDetachedPaneTearsDown() async {
        let (ws, _, right) = twoPaneWorkspace()
        let store = makeTreeStore(restoringTree: ws)
        store.detachPaneToWindow(right)
        let fake = store.handle(for: right) as? FakePaneSession

        store.closePaneTree(right)

        XCTAssertNil(store.handle(for: right), "detached close routes to closeDetachedPane → registry removal")
        XCTAssertFalse(store.tree.isDetached(right))
        await store.quiesce()
        XCTAssertEqual(fake?.teardownCount, 1, "the orphaned satellite handle tore down")
    }

    @MainActor
    func testStoreRestoreRedocksPersistedDetachedPanes() {
        let (ws, _, right) = twoPaneWorkspace()
        let detached = WorkspaceTreeOps.detachPane(right, in: ws)

        // Simulate a relaunch restoring the persisted (detached) tree: v1 re-docks satellites into tabs.
        let store = makeTreeStore(restoringTree: detached)

        XCTAssertTrue(store.tree.contains(right), "launch restore re-docked the satellite")
        XCTAssertTrue(store.detachedPanes.isEmpty)
        XCTAssertNotNil(store.handle(for: right), "and materialized its handle")
    }
}
