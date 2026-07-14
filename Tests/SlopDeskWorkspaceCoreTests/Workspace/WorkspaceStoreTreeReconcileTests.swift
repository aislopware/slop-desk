import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// W4 (docs/42 §"W4 — Store retarget"): pins the **DORMANT** tree-driven reconcile path the store
/// gains alongside the live canvas `reconcile()`. ``WorkspaceStore/reconcileTree()`` diffs the desired
/// leaf set `tree.allPaneIDs()` against the SAME `[PaneID: any PaneSessionHandle]` registry the canvas
/// path uses, materializing one idle handle per new leaf and tearing down orphaned ones — mirroring the
/// canvas reconcile, but driven by the new ``TreeWorkspace`` of intent.
///
/// These tests are an EXTENSION of ``WorkspaceStoreReconcileTests`` (same class) so the W4 verify
/// `swift test --filter WorkspaceStoreReconcileTests` exercises both the canvas and the tree paths. They
/// inject the spec-only `makeSession` seam with a ``FakePaneSession`` — never a `SlopDeskClient` /
/// `HostServer` — and assert against the fake's RECORDED materialize (`adopt`) / `teardown` call counts,
/// not against the reconcile's own recomputed output (no tautology).
///
/// Each store is built EMPTY-canvas so the canvas-init reconcile leaves the registry empty; the tree path
/// is then the sole driver, and a registry handle exists iff its leaf is in the tree.
extension WorkspaceStoreReconcileTests {
    // MARK: - Tree fixtures (empty-canvas store + a seeded tree)

    /// A store whose canvas is EMPTY (so the canvas-init reconcile yields an empty registry) and whose
    /// `tree` is seeded from `restoringTree`. The tree path is then the only thing that touches the
    /// registry, so a tree test can assert the registry 1:1 against `tree.allPaneIDs()` with no canvas
    /// pane confounding it. NEVER a real client/host (`FakePaneSession` seam).
    private func makeTreeStore(
        restoringTree: TreeWorkspace,
        liveVideoCap: Int = 2,
        videoTeardownSettle: Duration = .zero,
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: []), focusedPane: nil),
            restoringTree: restoringTree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: liveVideoCap,
            videoTeardownSettle: videoTeardownSettle,
        )
    }

    /// The set of ids the registry currently holds (via the only public window, `allSessions`).
    private func treeRegistryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    /// The fake handle for `id` (downcast for recorded-lifecycle accessors), or `nil`.
    private func treeFake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    /// THE tree invariant, asserted after every tree op: `Set(registry.keys) == Set(tree.allPaneIDs())`
    /// AND every materialized handle adopted its leaf id.
    private func assertTreeInvariant(
        _ store: WorkspaceStore,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let leaves = Set(store.tree.allPaneIDs())
        XCTAssertEqual(
            treeRegistryIDs(store),
            leaves,
            "registry.keys != tree.allPaneIDs() \(message)",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            store.allSessions.count,
            leaves.count,
            "registry has duplicate/extra handles \(message)",
            file: file,
            line: line,
        )
        XCTAssertTrue(store.tree.isInvariantHeld(), "tree specs == leafIDs broken \(message)", file: file, line: line)
        for id in leaves {
            XCTAssertEqual(
                store.handle(for: id)?.id,
                id,
                "handle.id != its leaf id (adopt failed) \(message)",
                file: file,
                line: line,
            )
        }
    }

    // MARK: - reconcileTree materializes the seeded tree

    /// Seeding a tree and calling `reconcileTree()` materializes exactly one idle handle per leaf,
    /// adopting each leaf id — the registry now matches the tree (it started empty from the empty canvas).
    func testReconcileTreeMaterializesSeededTreeLeaves() {
        let tree = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "root"))
        let store = makeTreeStore(restoringTree: tree)

        // The empty canvas left an empty registry; the seeded tree is dormant until reconcileTree runs.
        store.reconcileTree()

        let leaf = store.tree.allPaneIDs()[0]
        XCTAssertEqual(store.allSessions.count, 1, "one leaf → one materialized handle")
        assertTreeInvariant(store, "after reconcileTree(seeded single-leaf tree)")
        let handle = treeFake(store, leaf)
        XCTAssertEqual(handle?.kind, .terminal, "materialized session mirrors the leaf spec kind")
        XCTAssertEqual(handle?.events.first, .adopt(leaf), "reconcileTree re-points identity via adopt(id:)")
        XCTAssertEqual(handle?.isVideoActive, false, "materialized session is idle (no video)")
    }

    // MARK: - splitting the active pane materializes exactly one new leaf

    /// Splitting the active pane creates ONE new leaf; reconcileTree materializes exactly one new handle
    /// and KEEPS the original — assert via the fakes' adopt/teardown counts, not the tree output.
    func testSplitActivePaneMaterializesExactlyOneNewLeaf() throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let original = store.tree.allPaneIDs()[0]
        let originalFake = treeFake(store, original)
        XCTAssertEqual(store.allSessions.count, 1)

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "split added one leaf to the tree")
        XCTAssertEqual(store.allSessions.count, 2, "reconcileTree materialized exactly one new handle")
        assertTreeInvariant(store, "after splitActivePane")
        // The original handle is the SAME object (never re-materialized) — teardown never ran on it.
        XCTAssertTrue(treeFake(store, original) === originalFake, "original handle untouched by the split")
        XCTAssertEqual(originalFake?.teardownCount, 0, "original session never torn down on split")
        // The new leaf is the active pane and its handle adopted that exact id.
        let newLeaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != original })
        XCTAssertEqual(treeFake(store, newLeaf)?.events.first, .adopt(newLeaf), "new leaf adopted its id")
    }

    /// Repeated same-axis splits each materialize exactly one new handle (n-ary insert).
    func testRepeatedSplitsMaterializeEachNewLeafOnce() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        XCTAssertEqual(store.allSessions.count, 1)

        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.tree.allPaneIDs().count, 3, "two same-axis splits → three leaves")
        XCTAssertEqual(store.allSessions.count, 3, "each new leaf materialized exactly once")
        assertTreeInvariant(store, "after two splits")
        // No handle was torn down across the two splits.
        for id in store.tree.allPaneIDs() {
            XCTAssertEqual(treeFake(store, id)?.teardownCount, 0, "no session torn down during split sequence")
        }
    }

    // MARK: - closing a pane orphans + tears down EXACTLY its handle

    /// Closing a split pane removes its registry key synchronously and tears down its handle exactly once;
    /// the surviving pane's handle is untouched (assert teardown counts, awaited via quiesce()).
    func testCloseTreePaneTearsDownExactlyOneOrphan() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let a = store.tree.allPaneIDs()[0]
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let b = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != a })
        let aFake = treeFake(store, a)
        let bFake = treeFake(store, b)
        XCTAssertEqual(store.allSessions.count, 2)

        store.closePaneTree(b)

        // Registry key dropped SYNCHRONOUSLY (invariant holds the instant the mutation returns).
        XCTAssertNil(store.handle(for: b), "closed leaf's registry key removed synchronously")
        XCTAssertEqual(store.allSessions.count, 1, "one survivor remains registered")
        assertTreeInvariant(store, "after closePaneTree(b)")
        // The orphan's teardown completes after quiesce(); the survivor's never runs.
        await store.quiesce()
        XCTAssertEqual(bFake?.teardownCount, 1, "closed leaf torn down EXACTLY once")
        XCTAssertEqual(aFake?.teardownCount, 0, "surviving leaf never torn down")
        XCTAssertTrue(treeFake(store, a) === aFake, "surviving handle is the same object")
    }

    // MARK: - closing the LAST pane in a tab/session cascades the registry

    /// Closing the last pane of the only tab/session re-seeds a fresh default leaf (the workspace is never
    /// empty): reconcileTree tears down the old handle and materializes the re-seeded one.
    func testCloseLastPaneCascadesAndReseeds() async {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let only = store.tree.allPaneIDs()[0]
        let onlyFake = treeFake(store, only)
        XCTAssertEqual(store.allSessions.count, 1)

        store.closePaneTree(only)

        // The tree re-seeded a brand-new default leaf (never empty); the registry now backs THAT leaf.
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "workspace re-seeded one default leaf")
        let reseeded = store.tree.allPaneIDs()[0]
        XCTAssertNotEqual(reseeded, only, "the re-seeded leaf is a fresh id")
        XCTAssertEqual(store.allSessions.count, 1, "registry backs the re-seeded leaf")
        XCTAssertNil(store.handle(for: only), "the old leaf's handle was orphaned")
        assertTreeInvariant(store, "after close-last cascade")
        await store.quiesce()
        XCTAssertEqual(onlyFake?.teardownCount, 1, "the closed leaf torn down once")
    }

    /// Closing the last pane of a tab (in a multi-tab session) closes the tab and cascades: that tab's
    /// leaf is torn down, the other tab's leaves survive untouched.
    func testCloseLastPaneOfTabClosesTabAndCascadesRegistry() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let tab0Leaf = store.tree.allPaneIDs()[0]
        // Open a second tab with its own leaf.
        store.newTab(kind: .terminal)
        let tab1Leaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != tab0Leaf })
        XCTAssertEqual(store.allSessions.count, 2, "two tabs, one leaf each, both materialized")
        let tab0Fake = treeFake(store, tab0Leaf)
        let tab1Fake = treeFake(store, tab1Leaf)

        // Close the second tab's only leaf → the tab closes; tab0's leaf survives.
        store.closePaneTree(tab1Leaf)

        XCTAssertEqual(store.tree.allPaneIDs(), [tab0Leaf], "only tab0's leaf remains in the tree")
        XCTAssertEqual(store.allSessions.count, 1, "registry cascaded to one leaf")
        XCTAssertNil(store.handle(for: tab1Leaf), "the closed tab's leaf was orphaned")
        assertTreeInvariant(store, "after close-last-of-tab")
        await store.quiesce()
        XCTAssertEqual(tab1Fake?.teardownCount, 1, "the closed tab's leaf torn down once")
        XCTAssertEqual(tab0Fake?.teardownCount, 0, "the surviving tab's leaf untouched")
    }

    // MARK: - new session materializes its leaf; close session tears it down

    /// A new session adds one tab/leaf and materializes it; closing the session tears that leaf down and
    /// keeps the other session's leaves.
    func testNewAndCloseSessionMaterializeAndTeardownRegistry() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let s0Leaf = store.tree.allPaneIDs()[0]
        let s0Fake = treeFake(store, s0Leaf)

        store.newSession(name: "host-2", kind: .terminal)
        let s1Leaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != s0Leaf })
        XCTAssertEqual(store.allSessions.count, 2, "new session's leaf materialized")
        assertTreeInvariant(store, "after newSession")
        let s1Fake = treeFake(store, s1Leaf)

        let s1ID = try XCTUnwrap(store.tree.tab(containing: s1Leaf)?.0)
        store.closeSession(s1ID)

        XCTAssertEqual(store.tree.allPaneIDs(), [s0Leaf], "only the first session's leaf remains")
        XCTAssertEqual(store.allSessions.count, 1, "registry cascaded to the surviving session")
        assertTreeInvariant(store, "after closeSession")
        await store.quiesce()
        XCTAssertEqual(s1Fake?.teardownCount, 1, "the closed session's leaf torn down once")
        XCTAssertEqual(s0Fake?.teardownCount, 0, "the surviving session's leaf untouched")
    }

    // MARK: - selecting a tab/session keeps ALL leaves registered (full set, not active tab)

    /// reconcileTree keeps the FULL leaf set registered (not just the active tab's): selecting a different
    /// tab/session changes focus/active state but never materializes or tears down a handle.
    func testSelectTabKeepsFullLeafSetRegistered() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let tab0Leaf = store.tree.allPaneIDs()[0]
        store.newTab(kind: .terminal)
        XCTAssertEqual(store.allSessions.count, 2, "both tabs' leaves are registered (full set)")
        let before = treeRegistryIDs(store)
        let beforeFakes = store.tree.allPaneIDs().compactMap { treeFake(store, $0) }

        // Switch back to the first tab — pure active-state change.
        store.selectTab(0)

        XCTAssertEqual(treeRegistryIDs(store), before, "tab switch left the registry unchanged (full set)")
        XCTAssertEqual(store.allSessions.count, 2, "no handle materialized or torn down on tab switch")
        // No handle re-materialized → the same objects + zero teardowns.
        for fake in beforeFakes {
            XCTAssertEqual(fake.teardownCount, 0, "tab switch tore nothing down")
        }
        _ = tab0Leaf
        assertTreeInvariant(store, "after selectTab")
    }

    // MARK: - idempotency: reconcileTree twice = no churn

    /// Calling `reconcileTree()` a second time with no tree change materializes nothing new and tears
    /// nothing down — the registry is unchanged (assert the same handle objects + zero teardowns).
    func testReconcileTreeIsIdempotent() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let leaves = store.tree.allPaneIDs()
        let fakesBefore = leaves.map { treeFake(store, $0) }
        let countBefore = store.allSessions.count

        store.reconcileTree() // second pass, no tree change

        XCTAssertEqual(store.allSessions.count, countBefore, "idempotent reconcileTree added no handle")
        assertTreeInvariant(store, "after idempotent reconcileTree")
        for (i, id) in leaves.enumerated() {
            XCTAssertTrue(treeFake(store, id) === fakesBefore[i], "no handle re-materialized on the second pass")
            XCTAssertEqual(treeFake(store, id)?.teardownCount, 0, "idempotent reconcileTree tore nothing down")
        }
    }

    // MARK: - the canvas reconcile path is NOT perturbed by the tree path

    /// The tree path uses the SAME registry but is dormant for the live canvas path: a store driven ONLY
    /// by the canvas (default construction) never gains a tree leaf in its registry, and `tree` defaults to
    /// the single-pane default without being reconciled at init (canvas `reconcile()` is the only init
    /// reconcile). This pins that init does NOT call reconcileTree (no double-binding).
    func testInitDoesNotReconcileTree() {
        // Default construction (non-empty default canvas) — the canvas path materialized its pane.
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        // The registry backs the CANVAS pane, NOT the tree's default leaf (init did not reconcileTree).
        let canvasPane = store.workspace.canvas.allIDs()[0]
        XCTAssertEqual(store.allSessions.count, 1, "init materialized exactly the canvas pane")
        XCTAssertNotNil(store.handle(for: canvasPane), "canvas pane is registered")
        // The default tree leaf is a DIFFERENT id and is NOT in the registry (dormant).
        let treeLeaf = store.tree.allPaneIDs()[0]
        XCTAssertNotEqual(treeLeaf, canvasPane, "tree default leaf is independent of the canvas pane")
        XCTAssertNil(store.handle(for: treeLeaf), "the tree default leaf is NOT registered at init (dormant)")
    }

    // MARK: - Finding 1: the tree path honors the SAME video-cap teardown accounting as the canvas path

    /// Closing a `.remoteGUI` leaf that holds a LIVE video slot through the TREE path
    /// (``WorkspaceStore/closePaneTree(_:)``) drives the SAME ceiling-accounting the canvas
    /// `LiveVideoCapTests` pin — proving the shared ``WorkspaceStore`` reconcile core (not a duplicated
    /// branch) bites on the tree path too. Mirrors `LiveVideoCapTests.testClosingActiveVideoPaneFreesSlot`
    /// / `testTeardownSettleHoldsSlotPastTeardownThenFrees`, driven by the tree:
    ///  (a) at close time the orphan is recorded in `tearingDownVideo` (so a same-tick reopen is GATED);
    ///  (b) `videoPromotionGeneration` advanced (the close-time slot-freeing nudge);
    ///  (c) with a NON-ZERO `videoTeardownSettle` the slot stays HELD past `teardown()`'s return until
    ///      `quiesce()` drains the settle — only then does the gated reopen admit.
    func testCloseTreeVideoPaneHonorsCapTeardownAccounting() async throws {
        // A two-`.remoteGUI`-leaf tree (split the seed) under cap=2 + a non-zero settle, so a same-tick
        // reopen has nowhere to go until the closing pane's stack actually releases.
        let videoSpec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let store = makeTreeStore(
            restoringTree: .singlePane(spec: videoSpec),
            liveVideoCap: 2,
            videoTeardownSettle: .milliseconds(80),
        )
        store.reconcileTree()
        let a = store.tree.allPaneIDs()[0]
        store.splitActivePane(axis: .horizontal, kind: .remoteGUI)
        let b = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != a })
        XCTAssertEqual(store.allSessions.count, 2, "two remoteGUI leaves materialized")

        // Mark BOTH leaves' handles video-active through the store's cap-checked admission (cap=2).
        XCTAssertTrue(store.activateVideo(a))
        XCTAssertTrue(store.activateVideo(b), "cap=2 saturated by two live video panes")
        let bFake = try XCTUnwrap(treeFake(store, b))

        let genBefore = store.videoPromotionGeneration

        // Close b through the TREE path. Its teardown returns immediately (no gate) but the settle holds
        // its slot; b is gone from the registry synchronously.
        store.closePaneTree(b)
        XCTAssertNil(store.handle(for: b), "closed leaf removed from the registry synchronously")
        assertTreeInvariant(store, "after closePaneTree(b) of a live video leaf")

        // (b) The close was a slot-freeing event for a LIVE video pane ⇒ exactly one close-time nudge.
        XCTAssertEqual(
            store.videoPromotionGeneration,
            genBefore + 1,
            "closing a live video tree leaf is a slot-freeing event ⇒ one close-time promotion nudge",
        )

        // (a) + (c) Same tick, split a third `.remoteGUI` leaf in. While the closing pane's slot is still
        // held by the settle (a live (1) + b settling (1) = cap of 2 occupied), the reopen is GATED.
        store.splitActivePane(axis: .horizontal, kind: .remoteGUI)
        let reopened = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != a })
        await Task.yield() // let teardown() return but leave the settle sleep in flight
        XCTAssertFalse(
            store.activateVideo(reopened),
            "same-tick reopen GATED — b is recorded in tearingDownVideo and its slot is still settling",
        )

        // After quiesce() drains the teardown task INCLUDING its settle sleep, the slot frees.
        await store.quiesce()
        XCTAssertEqual(bFake.teardownCount, 1, "the closed video leaf was torn down exactly once")
        XCTAssertTrue(
            store.activateVideo(reopened),
            "once the settle elapsed and the stack released, the reopened tree leaf admits",
        )
        let activeIDs = Set(store.allSessions.filter(\.isVideoActive).map(\.id))
        XCTAssertEqual(activeIDs, Set([a, reopened]), "exactly cap=2 live; the ceiling was never exceeded")
    }

    // MARK: - Finding 3: closeTab orphaning >1 leaf in a single reconcileTree pass

    /// ``WorkspaceStore/closeTab(_:)`` closing a MULTI-pane tab orphans every one of that tab's leaves in a
    /// SINGLE `reconcileTree` pass: each is torn down exactly once, the other tab's leaves are untouched,
    /// and the tree invariant holds. (Exercises the orphan loop with >1 orphan — no prior test does.)
    func testCloseTabTearsDownAllLeavesOfAMultiPaneTab() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let tab0Leaf = store.tree.allPaneIDs()[0]

        // Build a SECOND tab and grow it to ≥3 leaves (two same-axis splits of its lone leaf).
        store.newTab(kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        XCTAssertEqual(store.allSessions.count, 4, "tab0 (1 leaf) + tab1 (3 leaves) all materialized")
        assertTreeInvariant(store, "after building the multi-pane second tab")

        // Capture the second tab's id + the fakes of ALL its leaves (and tab0's, to prove it is untouched).
        let tab1ID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let tab1Leaves = try XCTUnwrap(store.tree.activeSession?.activeTab?.allPaneIDs())
        XCTAssertEqual(tab1Leaves.count, 3, "the second tab has three leaves")
        let tab1Fakes = tab1Leaves.map { treeFake(store, $0) }
        let tab0Fake = treeFake(store, tab0Leaf)

        // Close the whole multi-pane tab — orphans all three of its leaves in ONE reconcileTree pass.
        store.closeTab(tab1ID)

        // Synchronously: only tab0's leaf remains; the invariant holds.
        XCTAssertEqual(store.tree.allPaneIDs(), [tab0Leaf], "only tab0's leaf survives in the tree")
        XCTAssertEqual(store.allSessions.count, 1, "registry cascaded to the one surviving leaf")
        for id in tab1Leaves {
            XCTAssertNil(store.handle(for: id), "every closed-tab leaf removed from the registry synchronously")
        }
        assertTreeInvariant(store, "after closeTab(multi-pane tab)")

        await store.quiesce()
        // Every leaf of the closed tab torn down EXACTLY once; the surviving tab's leaf untouched.
        for fake in tab1Fakes {
            XCTAssertEqual(fake?.teardownCount, 1, "each leaf of the closed multi-pane tab torn down exactly once")
        }
        XCTAssertEqual(tab0Fake?.teardownCount, 0, "the surviving tab's leaf was never torn down")
        XCTAssertTrue(treeFake(store, tab0Leaf) === tab0Fake, "the surviving handle is the same object")
    }

    // MARK: - Finding 4: pure active-state methods are a registry no-op (full leaf set, same objects)

    /// The pure active-state tree methods (`moveFocusTree` / `toggleZoomTree` / `selectSession`) change
    /// focus/zoom/active-session only — the FULL leaf set stays registered, the same handle OBJECTS
    /// persist, the session count is unchanged, and nothing is torn down. (Mirrors
    /// `testSelectTabKeepsFullLeafSetRegistered` for the remaining active-state surface.)
    func testActiveStateMethodsAreRegistryNoOp() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        // ≥2 leaves in the active tab (so moveFocus/toggleZoom have a target), plus a second session.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.newSession(name: "host-2", kind: .terminal)
        // Re-select the first session so the multi-leaf tab is active for the focus/zoom ops.
        if let firstSessionID = store.tree.sessions.first?.id { store.selectSession(firstSessionID) }

        let beforeIDs = treeRegistryIDs(store)
        let beforeCount = store.allSessions.count
        let beforeFakes = store.tree.allPaneIDs().compactMap { treeFake(store, $0) }
        XCTAssertEqual(beforeCount, 3, "two leaves in session 0 + one leaf in session 1")

        // Pure active-state ops: none touches the leaf set.
        store.moveFocusTree(.right, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        store.toggleZoomTree()
        if let secondSessionID = store.tree.sessions.dropFirst().first?.id {
            store.selectSession(secondSessionID)
        }

        XCTAssertEqual(treeRegistryIDs(store), beforeIDs, "active-state ops left the registry leaf set unchanged")
        XCTAssertEqual(store.allSessions.count, beforeCount, "no handle materialized or torn down")
        assertTreeInvariant(store, "after the active-state ops")
        // The SAME handle objects persist, with zero teardowns.
        for fake in beforeFakes {
            XCTAssertTrue(treeFake(store, fake.id) === fake, "the same handle object persists (never re-materialized)")
            XCTAssertEqual(fake.teardownCount, 0, "active-state ops tore nothing down")
        }
    }
}
