import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// W5 (docs/42 §"W5 — Store live-path flip"): pins the CUTOVER that makes the v10 ``TreeWorkspace`` the
/// LIVE source of truth. Unlike the dormant-tree `WorkspaceStoreTreeReconcileTests` (which build a
/// `.canvas` store and drive `reconcileTree()` by hand), these build a store with
/// ``WorkspaceStore/LiveModel/tree`` and assert the LIVE behaviour:
///
/// 1. **init from a persisted v9 fixture migrates → the tree holds the panes → init's reconcileTree
///    materializes them** via the `FakePaneSession` factory (the store-flip end-to-end). This is the
///    headline W5 test; it is proven to FAIL on the un-flipped store (a `.canvas`-default store leaves the
///    tree dormant at init, so the registry would back the canvas pane, not the migrated tree leaves).
/// 2. **a mutation debounce-saves the v10 TREE** (not the canvas) and `loadTree()` round-trips it.
/// 3. **`saveImmediately()` writes the tree** and re-loads identically.
@MainActor
final class WorkspaceStoreLiveTreeTests: XCTestCase {
    // MARK: - Fixtures

    /// A persisted v9 canvas file (two grouped panes + one ungrouped) written to a temp URL, returning the
    /// persistence handle pointed at it and the v9 pane ids.
    private func writeV9Fixture() throws -> (WorkspacePersistence, [PaneID]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w5-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let group = PaneGroup(name: "Servers")
        let pBuild = PaneID(), pLog = PaneID(), pLoose = PaneID()
        let canvas = Canvas(
            items: [
                CanvasItem(
                    id: pBuild,
                    spec: PaneSpec(kind: .terminal, title: "build"),
                    frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                    z: 0,
                    groupID: group.id,
                ),
                CanvasItem(
                    id: pLog,
                    spec: PaneSpec(kind: .terminal, title: "log"),
                    frame: CGRect(x: 700, y: 0, width: 640, height: 420),
                    z: 1,
                    groupID: group.id,
                ),
                CanvasItem(
                    id: pLoose,
                    spec: PaneSpec(kind: .terminal, title: "scratch"),
                    frame: CGRect(x: 0, y: 500, width: 640, height: 420),
                    z: 2,
                ),
            ],
        )
        let v9 = Workspace(
            schemaVersion: 9,
            canvas: canvas,
            focusedPane: pBuild,
            groups: [group],
            connection: ConnectionTarget(host: "10.0.0.7", port: 7420),
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(v9).write(to: url, options: [.atomic])
        return (WorkspacePersistence(fileURL: url), [pBuild, pLog, pLoose])
    }

    private func treeStore(
        persistence: WorkspacePersistence?,
        restoringTree: TreeWorkspace?,
        saveDebounce: Duration = .milliseconds(600),
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            persistence: persistence,
            saveDebounce: saveDebounce,
        )
    }

    private func registryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    // MARK: - 1. The store-flip end-to-end

    // L0 / D2: testLiveTreeStoreMigratesV9FileAndMaterializesTreeLeaves was DELETED — it asserted a v9
    // on-disk file MIGRATES into the live tree and materializes its leaves. The canvas-era v5–v9 migration
    // is removed per the "No backcompat / single-user" directive, so a stale v9 file now decode-fails to
    // the default workspace (one Local terminal pane). The materialization/adopt(id:) path itself is still
    // covered by the reconcile tests in WorkspaceStoreTreeReconcileTests.

    // MARK: - 2. A mutation debounce-saves the v10 TREE (not the canvas)

    func testMutationDebounceSavesTheTreeAndLoadTreeRoundTrips() async throws {
        let (persistence, _) = try writeV9Fixture()
        let restoredTree = persistence.loadTree()
        // A short debounce so the test does not stall. The wait below is bounded by a CONDITION (the file
        // reflecting the split), not a fixed sleep, so it can't flake: a slow CI just polls a few more times.
        let store = treeStore(
            persistence: persistence,
            restoringTree: restoredTree,
            saveDebounce: .milliseconds(20),
        )
        let leavesBefore = store.tree.allPaneIDs().count

        // Mutate the LIVE tree (split the active pane) — this schedules a debounced save of the TREE.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let expectedLeaves = Set(store.tree.allPaneIDs())
        XCTAssertEqual(expectedLeaves.count, leavesBefore + 1)

        // DETERMINISTIC WAIT (C5): poll the persisted tree until the debounced write lands, bounded by a
        // generous 5s ceiling (the debounce is 20ms) so the assertion fires on the CONDITION, never a race
        // with a fixed sleep. The `loadTree()` round-trip proves it was saved as a v10 TREE (a canvas save
        // would not round-trip through `loadTree` at v10).
        var reloaded = persistence.loadTree()
        let deadline = Date().addingTimeInterval(5)
        while Set(reloaded.allPaneIDs()) != expectedLeaves, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            reloaded = persistence.loadTree()
        }
        XCTAssertEqual(reloaded.schemaVersion, TreeWorkspace.currentSchemaVersion)
        XCTAssertEqual(
            Set(reloaded.allPaneIDs()),
            expectedLeaves,
            "the debounced save persisted the live TREE (the split survived the round-trip)",
        )
    }

    // MARK: - 2b. A dead-canvas mutation cannot tear down the LIVE tree's registry

    /// W5 SAFETY: with `liveModel == .tree` the canvas is retained-but-dead — a leftover canvas mutation
    /// (e.g. the system-dialog monitor's `addSystemDialogPane`, deferred to a later item) calls the canvas
    /// `reconcile()`, which diffs the SAME registry against the (default, dead) canvas leaf set. Without the
    /// guard that would orphan + tear down every tree-materialized handle. This pins that a canvas mutation
    /// on a tree store leaves the tree's registry untouched.
    func testCanvasMutationDoesNotTearDownLiveTreeRegistry() throws {
        let (persistence, _) = try writeV9Fixture()
        let store = treeStore(persistence: persistence, restoringTree: persistence.loadTree())
        let liveLeaves = Set(store.tree.allPaneIDs())
        XCTAssertEqual(registryIDs(store), liveLeaves, "the tree's leaves are live before the canvas mutation")
        let fakesBefore = store.tree.allPaneIDs().compactMap { store.handle(for: $0) as? FakePaneSession }

        // A canvas mutation (would normally run the canvas `reconcile()` over the dead default canvas).
        store.addPane(kind: .terminal)

        XCTAssertEqual(
            registryIDs(store),
            liveLeaves,
            "the live tree's registry is UNCHANGED by a dead-canvas mutation (reconcile() was a no-op)",
        )
        for fake in fakesBefore {
            XCTAssertEqual(fake.teardownCount, 0, "no live tree handle was torn down by the dead-canvas mutation")
        }
    }

    // MARK: - 3. saveImmediately() writes the tree

    func testSaveImmediatelyWritesTheTree() throws {
        let (persistence, _) = try writeV9Fixture()
        let restoredTree = persistence.loadTree()
        let store = treeStore(persistence: persistence, restoringTree: restoredTree)

        store.newTab(kind: .terminal) // grow the tree
        store.saveImmediately()

        let reloaded = persistence.loadTree()
        XCTAssertEqual(reloaded.schemaVersion, TreeWorkspace.currentSchemaVersion)
        XCTAssertEqual(
            Set(reloaded.allPaneIDs()),
            Set(store.tree.allPaneIDs()),
            "saveImmediately persisted the live tree synchronously",
        )
        // The peeked on-disk schema version is v10 (the file is a TreeWorkspace, not a canvas Workspace).
        let data = try Data(contentsOf: persistence.fileURL)
        XCTAssertEqual(WorkspacePersistence.peekSchemaVersion(in: data), TreeWorkspace.currentSchemaVersion)
    }
}
