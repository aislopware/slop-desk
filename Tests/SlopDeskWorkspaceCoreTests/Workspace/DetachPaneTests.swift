import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the detach-to-own-window model (docs/DECISIONS.md — pane detach ↔ reattach):
/// The `detachPane` intent moves a leaf OUT of the split tree into the session's
/// ``Session/detached`` list while its spec (and therefore its live registry handle) survives;
/// `reattachPane` folds it back KEEPING the `PaneID`. The widened invariant is
/// `specs.keys == leafIDs ∪ detachedIDs`. Pure ops first, then the store-level reconcile behaviour with
/// the ``FakePaneSession`` seam (never a real client/host).
final class DetachPaneTests: XCTestCase {
    // MARK: - Fixtures

    /// One session, one tab, two terminal leaves (a || split) — the smallest tree where detach leaves
    /// the tab alive. Returns (workspace, left leaf, right leaf).
    private func twoPaneWorkspace() -> (TreeWorkspace, PaneID, PaneID) {
        let ws = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "left"))
        let left = ws.allPaneIDs()[0]
        let (split, right) = TreeIntent.splitPane(
            left, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "right"), in: ws,
        )
        return (split, left, right)
    }

    // MARK: - detachPane (pure op)

    func testDetachRemovesLeafFromTreeButKeepsSpecAndRecordsOrigin() {
        let (ws, left, right) = twoPaneWorkspace()
        let originTab = ws.sessions[0].tabs[0].id

        let out = TreeIntent.detachPane(right, in: ws)

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

        let out = TreeIntent.detachPane(pane, in: ws)

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
        ws = TreeIntent.toggleZoom(right, in: ws)

        let out = TreeIntent.detachPane(right, in: ws)

        XCTAssertNil(out.sessions[0].tabs[0].zoomedPane, "dangling zoom cleared")
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, left, "focus repointed to the survivor")
    }

    func testDetachAbsentOrAlreadyDetachedIsNoOp() {
        let (ws, _, right) = twoPaneWorkspace()
        let detachedOnce = TreeIntent.detachPane(right, in: ws)

        XCTAssertEqual(TreeIntent.detachPane(PaneID(), in: ws), ws, "absent id no-ops")
        XCTAssertEqual(
            TreeIntent.detachPane(right, in: detachedOnce), detachedOnce,
            "an already-detached pane is not a tree leaf — no-op, no duplicate entry",
        )
    }

    // MARK: - reattachPane (pure op)

    func testReattachReturnsToOriginTabFocusedAndRevealed() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

        let out = TreeIntent.reattachPane(right, in: detached)

        XCTAssertTrue(out.contains(right), "pane is a tree leaf again")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabs.count, 1, "reattached into the ORIGIN tab, not a new one")
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, right, "reattached pane is focused")
        XCTAssertTrue(out.contains(left))
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachRecreatesOwnTabWhenOriginTabClosed() {
        let (ws, left, right) = twoPaneWorkspace()
        var detached = TreeIntent.detachPane(right, in: ws)
        // Close the origin tab (its sole survivor `left` cascades the tab away; the session survives
        // because it still owns the detached pane) — a fresh default tab is re-seeded.
        detached = TreeIntent.closePane(left, in: detached)
        XCTAssertTrue(detached.isDetached(right), "satellite survives its origin tab closing")
        let reseededTab = detached.sessions[0].tabs[0].id

        let out = TreeIntent.reattachPane(right, in: detached)

        XCTAssertTrue(out.contains(right))
        XCTAssertFalse(out.isDetached(right))
        // A dead origin gets a FRESH tab, never a dock into whatever tab is active — that would graft
        // the pane into an unrelated split.
        XCTAssertEqual(out.sessions[0].tabs.count, 2, "origin dead → a tab of its own, not a split")
        XCTAssertEqual(out.sessions[0].tabs[1].root.allPaneIDs(), [right])
        XCTAssertFalse(
            out.sessions[0].tabs.first { $0.id == reseededTab }?.contains(right) ?? true,
            "the re-seeded default tab is untouched",
        )
        XCTAssertEqual(out.activeSession?.activeTab?.activePane, right, "landed focused + revealed")
        XCTAssertTrue(out.isInvariantHeld())
    }

    /// The reported daily-driver flow: a desktop pane living in a SPLIT is moved to its own fresh tab,
    /// detached into a satellite, and the satellite closed (close = reattach). The pane's origin tab
    /// died at detach (it was the sole leaf), so the reattach must recreate a lone tab — NOT fall back
    /// into the previously-split tab and become `left`'s split sibling again.
    func testReattachAfterMoveToOwnTabThenDetachDoesNotRejoinOldSplit() {
        let (ws, left, right) = twoPaneWorkspace()
        // Move `right` out of the split into its own fresh tab (the drag-to-New-Tab shape).
        var moved = TreeIntent.breakPaneToTab(right, in: ws)
        XCTAssertEqual(moved.sessions[0].tabs.count, 2, "precondition: the pane owns a lone tab")
        // Detach it — the lone tab is pruned, so the recorded origin tab is now dead.
        moved = TreeIntent.detachPane(right, in: moved)
        XCTAssertEqual(moved.sessions[0].tabs.count, 1, "precondition: the lone origin tab was pruned")

        let out = TreeIntent.reattachPane(right, in: moved)

        XCTAssertEqual(
            out.sessions[0].tabs[0].root.allPaneIDs(), [left],
            "the old split partner keeps its tab to itself — the pane must NOT rejoin the split",
        )
        XCTAssertEqual(out.sessions[0].tabs.count, 2)
        XCTAssertEqual(out.sessions[0].tabs[1].root.allPaneIDs(), [right], "back as a lone tab")
        XCTAssertEqual(out.activeSession?.activeTab?.activePane, right)
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachNotDetachedIsNoOp() {
        let (ws, _, right) = twoPaneWorkspace()
        XCTAssertEqual(TreeIntent.reattachPane(right, in: ws), ws)
        XCTAssertEqual(TreeIntent.reattachPane(PaneID(), in: ws), ws)
    }

    // MARK: - reattachPane(beside:) / (toActiveTabRootEdge:) / reattachPaneToNewTab (drag-to-merge ops)

    func testReattachBesideAnchorInsertsSiblingFocusedAndKeepsSpec() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

        let out = TreeIntent.reattachPane(right, beside: left, axis: .vertical, before: true, in: detached)

        XCTAssertEqual(out.sessions[0].tabs[0].root.allPaneIDs(), [right, left], "inserted on the BEFORE side")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, right, "the reattached pane is focused")
        XCTAssertNotNil(out.sessions[0].specs[right], "spec never left the side table — PaneID preserved")
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachBesideAnchorInBackgroundTabSelectsThatTab() {
        let (ws, left, right) = twoPaneWorkspace()
        var detached = TreeIntent.detachPane(right, in: ws)
        // A fresh tab takes the selection; the anchor `left` now lives in a BACKGROUND tab.
        let (grown, _) = TreeIntent.newTab(in: detached, spec: PaneSpec(kind: .terminal, title: "c"))
        detached = grown
        XCTAssertEqual(detached.sessions[0].activeTabIndex, 1, "precondition: the fresh tab is active")

        let out = TreeIntent.reattachPane(right, beside: left, axis: .horizontal, before: false, in: detached)

        XCTAssertEqual(out.sessions[0].tabs[0].root.allPaneIDs(), [left, right])
        XCTAssertEqual(out.sessions[0].activeTabIndex, 0, "the anchor's tab is revealed")
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, right)
        XCTAssertTrue(out.isInvariantHeld())
    }

    /// The gesture is TWO intents — dock the pane back into the tree, then place it beside the anchor
    /// — and only the FIRST is load-bearing. A refused dock stops the gesture dead; a dock that lands
    /// and a placement that cannot be honoured leaves the pane where the tree's own rule put it, back
    /// in the main window. That is strictly better than the old all-or-nothing helper: a satellite the
    /// user dragged home never bounces back out because the drop target turned out to be unusable.
    func testReattachBesideFallsBackToTheTreesOwnLandingForBadTargets() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)
        XCTAssertEqual(
            TreeIntent.reattachPane(left, beside: right, axis: .horizontal, before: false, in: ws),
            ws, "a pane that is not detached no-ops — the dock is refused, so nothing is staged",
        )

        let absentAnchor = TreeIntent.reattachPane(
            right, beside: PaneID(), axis: .horizontal, before: false, in: detached,
        )
        XCTAssertFalse(absentAnchor.isDetached(right), "the dock landed")
        XCTAssertEqual(
            absentAnchor.sessions[0].tabs[0].root.allPaneIDs(), [left, right],
            "the pane went home to its origin tab; only the placement was dropped",
        )

        // An anchor in ANOTHER session: the spec cannot leave its session's side table, so the
        // placement is refused and the pane stays home.
        let (twoSessions, other) = TreeIntent.newSession(
            in: detached, name: "s2", spec: PaneSpec(kind: .terminal, title: "other"),
        )
        let crossSession = TreeIntent.reattachPane(
            right, beside: other, axis: .horizontal, before: false, in: twoSessions,
        )
        XCTAssertEqual(crossSession.sessions[0].tabs[0].root.allPaneIDs(), [left, right])
        XCTAssertEqual(
            crossSession.sessions[1].allPaneIDs(), [other], "the other session is untouched",
        )
    }

    func testReattachToActiveTabRootEdgeDocksFullSpan() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

        let out = TreeIntent.reattachPane(right, toActiveTabRootEdge: .left, in: detached)

        XCTAssertEqual(out.sessions[0].tabs[0].root.allPaneIDs(), [right, left], "docked BEFORE at the left edge")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabs[0].activePane, right)
        XCTAssertTrue(out.contains(left))
        XCTAssertTrue(out.isInvariantHeld())
    }

    /// A satellite owned by a BACKGROUND session docks into its OWN session, and reveals it — the
    /// spec never left that session's side table, so there is nowhere else the pane could go. The
    /// edge the drop named is honoured against the tab it actually landed in.
    func testReattachToActiveTabRootEdgeRevealsTheOwningSession() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)
        var (twoSessions, _) = TreeIntent.newSession(
            in: detached, name: "s2", spec: PaneSpec(kind: .terminal, title: "other"),
        )
        twoSessions.activeSessionID = twoSessions.sessions[1].id

        let out = TreeIntent.reattachPane(right, toActiveTabRootEdge: .right, in: twoSessions)

        XCTAssertEqual(out.activeSessionID, out.sessions[0].id, "the owning session is revealed")
        XCTAssertFalse(out.isDetached(right))
        XCTAssertEqual(out.sessions[0].tabs[0].root.allPaneIDs(), [left, right])
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testReattachToNewTabAppendsSelectedLoneTab() {
        let (ws, left, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

        let out = TreeIntent.reattachPaneToNewTab(right, in: detached)

        XCTAssertEqual(out.sessions[0].tabs.count, 2)
        XCTAssertEqual(out.sessions[0].tabs[1].root.allPaneIDs(), [right], "a fresh lone-leaf tab")
        XCTAssertEqual(out.sessions[0].activeTabIndex, 1, "the new tab is selected")
        XCTAssertEqual(out.sessions[0].tabs[1].activePane, right)
        XCTAssertFalse(out.isDetached(right))
        XCTAssertTrue(out.contains(left))
        XCTAssertTrue(out.isInvariantHeld())
        XCTAssertEqual(
            TreeIntent.reattachPaneToNewTab(left, in: ws), ws,
            "a pane that is not detached no-ops",
        )
    }

    // MARK: - closeDetachedPane (pure op)

    func testCloseDetachedPaneDropsEntryAndSpec() {
        let (ws, _, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

        let out = TreeIntent.closeDetachedPane(right, in: detached)

        XCTAssertFalse(out.isDetached(right))
        XCTAssertNil(out.sessions[0].specs[right], "spec dropped → reconcile tears the handle down")
        XCTAssertTrue(out.isInvariantHeld())
    }

    // MARK: - cascade survival (the reviewer-flagged session-drop hazard)

    func testClosingLastTreePaneKeepsSessionOwningSatellites() {
        let (ws, left, right) = twoPaneWorkspace()
        let sessionID = ws.sessions[0].id
        var out = TreeIntent.detachPane(right, in: ws)

        // `left` is now the session's sole tree pane; closing it empties the last tab. The cascade must
        // NOT drop the session — it still owns the satellite's spec.
        out = TreeIntent.closePane(left, in: out)

        XCTAssertEqual(out.sessions.map(\.id), [sessionID], "session survives — it owns a satellite")
        XCTAssertTrue(out.isDetached(right))
        XCTAssertNotNil(out.sessions[0].specs[right])
        XCTAssertTrue(out.isInvariantHeld())
    }

    func testExplicitCloseSessionDropsItsSatellitesToo() {
        let (ws, _, right) = twoPaneWorkspace()
        var out = TreeIntent.detachPane(right, in: ws)
        let sessionID = out.sessions[0].id

        out = TreeIntent.closeSession(sessionID, in: out)

        XCTAssertFalse(out.isDetached(right), "an explicit session close is destructive — satellites included")
        XCTAssertNil(out.spec(for: right))
    }

    // MARK: - Persistence (additive Codable + normalizing repairs + launch re-dock)

    func testSessionDetachedRoundTripsAndOldFilesDecodeEmpty() throws {
        let (ws, _, right) = twoPaneWorkspace()
        let detached = TreeIntent.detachPane(right, in: ws)

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
        var corrupt = TreeIntent.detachPane(right, in: ws)
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
        let (grown, _) = TreeIntent.newTab(in: ws, spec: PaneSpec(kind: .terminal, title: "t2"))
        ws = grown // newTab selected tab 1
        var detached = TreeIntent.detachPane(right, in: ws)
        detached = TreeIntent.selectTab(1, in: detached)

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
        let store = WorkspaceStore(
            restoringTree: restoringTree,
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        store.attachLoopbackWorkspaceDocument()
        return store
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
        let detached = TreeIntent.detachPane(right, in: ws)

        // Simulate a relaunch restoring the persisted (detached) tree: v1 re-docks satellites into tabs.
        let store = makeTreeStore(restoringTree: detached)

        XCTAssertTrue(store.tree.contains(right), "launch restore re-docked the satellite")
        XCTAssertTrue(store.detachedPanes.isEmpty)
        XCTAssertNotNil(store.handle(for: right), "and materialized its handle")
    }
}
