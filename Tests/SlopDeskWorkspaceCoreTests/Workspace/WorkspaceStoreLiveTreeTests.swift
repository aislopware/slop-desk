import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// W5 (docs/42 §"W5 — Store live-path flip"): pins that the v10 ``TreeWorkspace`` is what the store
/// PERSISTS. The store restores from `loadTree()`, materializes those leaves through the
/// `FakePaneSession` factory at init, and every later mutation writes the tree back:
///
/// 1. **a mutation debounce-saves the TREE** and `loadTree()` round-trips it.
/// 2. **`saveImmediately()` writes the tree** and re-loads identically.
@MainActor
final class WorkspaceStoreLiveTreeTests: XCTestCase {
    // MARK: - Fixtures

    /// A ``WorkspacePersistence`` pointed at a fresh, EMPTY temp file — so `loadTree()` yields the default
    /// workspace (one Local terminal pane) and the tests below assert on what the store WRITES, not on a
    /// hand-authored fixture. The directory is torn down with the test (720 of them once piled up in TMPDIR).
    private func scratchPersistence() throws -> WorkspacePersistence {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))
    }

    private func treeStore(
        persistence: WorkspacePersistence?,
        restoringTree: TreeWorkspace?,
        saveDebounce: Duration = .milliseconds(600),
    ) -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: restoringTree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            persistence: persistence,
            saveDebounce: saveDebounce,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func registryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    // MARK: - 1. init materializes the restored tree's leaves

    /// The restored tree IS the registry's desired set the instant init returns — the store-flip contract
    /// the whole shell rests on.
    func testInitMaterializesTheRestoredTreesLeaves() throws {
        let store = try treeStore(persistence: scratchPersistence(), restoringTree: .defaultWorkspace())
        XCTAssertEqual(
            registryIDs(store),
            Set(store.tree.allPaneIDs()),
            "init reconciled the tree: one live handle per restored leaf, and nothing else",
        )
    }

    // MARK: - 2. A mutation debounce-saves the v10 TREE

    func testMutationDebounceSavesTheTreeAndLoadTreeRoundTrips() async throws {
        let persistence = try scratchPersistence()
        // A short debounce so the test does not stall. The wait below is bounded by a CONDITION (the file
        // reflecting the split), not a fixed sleep, so it can't flake: a slow CI just polls a few more times.
        let store = treeStore(
            persistence: persistence,
            restoringTree: persistence.loadTree(),
            saveDebounce: .milliseconds(20),
        )
        let leavesBefore = store.tree.allPaneIDs().count

        // Mutate the LIVE tree (split the active pane) — this schedules a debounced save of the TREE.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let expectedLeaves = Set(store.tree.allPaneIDs())
        XCTAssertEqual(expectedLeaves.count, leavesBefore + 1)

        // DETERMINISTIC WAIT (C5): poll the persisted tree until the debounced write lands, bounded by a
        // generous 5s ceiling (the debounce is 20ms) so the assertion fires on the CONDITION, never a race
        // with a fixed sleep.
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

    // MARK: - 3. saveImmediately() writes the tree

    func testSaveImmediatelyWritesTheTree() throws {
        let persistence = try scratchPersistence()
        let store = treeStore(persistence: persistence, restoringTree: persistence.loadTree())

        store.newTab(kind: .terminal) // grow the tree
        store.saveImmediately()

        let reloaded = persistence.loadTree()
        XCTAssertEqual(reloaded.schemaVersion, TreeWorkspace.currentSchemaVersion)
        XCTAssertEqual(
            Set(reloaded.allPaneIDs()),
            Set(store.tree.allPaneIDs()),
            "saveImmediately persisted the live tree synchronously",
        )
    }
}
