import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the persistence-cluster fixes for the SHIPPED tree app (`liveModel: .tree`): workspace
/// export/import round-trips the REAL tree. Before the fix this targeted the retained-but-dead canvas
/// `Workspace.defaultWorkspace()`, so export wrote an empty default while import silently no-oped.
@MainActor
final class TreePersistenceFixTests: XCTestCase {
    // MARK: - Fixtures

    private func singlePaneTree(spec: PaneSpec = PaneSpec(kind: .terminal, title: "Terminal")) -> TreeWorkspace {
        .singlePane(spec: spec)
    }

    private func treeStore(
        _ restoringTree: TreeWorkspace? = nil,
        persistence: WorkspacePersistence? = nil,
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
            persistence: persistence,
        )
    }

    // MARK: - Bug 2: export serializes the REAL tree; import applies it

    func testExportImportRoundTripPreservesTheTree() {
        let src = treeStore()
        // Build a real workspace: rename the session, add a tab.
        src.renameSession(src.tree.activeSessionID ?? SessionID(), to: "Project")
        src.newTab(kind: .terminal)
        let tabCount = src.tree.activeSession?.tabs.count ?? 0
        XCTAssertGreaterThanOrEqual(tabCount, 2, "precondition: a real multi-tab session")

        let data = src.exportWorkspaceData()

        // A fresh tree store imports the document, REPLACING its default single-pane tree.
        let dst = treeStore()
        XCTAssertTrue(dst.importWorkspace(data), "the tree document imports")
        XCTAssertEqual(dst.tree.activeSession?.name, "Project", "the session name survived the round trip")
        XCTAssertEqual(dst.tree.activeSession?.tabs.count, tabCount, "the tabs survived")
        // Every imported leaf materialized a live session (registry == tree invariant).
        for id in dst.tree.allPaneIDs() {
            XCTAssertNotNil(dst.handle(for: id), "every imported leaf materialized a session")
        }
    }

    func testImportRejectsHostileBytesLeavingTreeUntouched() {
        let st = treeStore()
        let before = st.tree.allPaneIDs()
        XCTAssertFalse(st.importWorkspace(Data("not a workspace".utf8)), "garbage is rejected")
        XCTAssertFalse(st.importWorkspace(Data()), "empty data is rejected")
        // A canvas document must NOT import into the tree app (distinct magic).
        let canvasDoc = WorkspaceTransfer.export(Workspace.defaultWorkspace())
        XCTAssertFalse(st.importWorkspace(canvasDoc), "a foreign (canvas) document is rejected")
        XCTAssertEqual(st.tree.allPaneIDs(), before, "a rejected import leaves the live tree intact")
    }

    func testExportStripsPerSessionConnection() throws {
        var tree = singlePaneTree()
        tree.sessions[0].connection = ConnectionTarget(host: "secret", port: 7420, mediaPort: 9000, cursorPort: 9001)
        let st = treeStore(tree)
        let decoded = try XCTUnwrap(WorkspaceTransfer.decodeTree(st.exportWorkspaceData()))
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.connection == nil }, "host:port is never exported")
    }

    func testImportReMintsIDsSoASameSessionReImportDoesNotCollide() {
        let st = treeStore()
        let originalPanes = Set(st.tree.allPaneIDs())
        let data = st.exportWorkspaceData()
        XCTAssertTrue(st.importWorkspace(data), "re-import into the SAME store")
        XCTAssertTrue(
            Set(st.tree.allPaneIDs()).isDisjoint(with: originalPanes),
            "every imported pane id is re-minted (no collision with the live registry)",
        )
    }

    func testTreeDocumentRoundTripThroughDecodeTree() throws {
        let tree = singlePaneTree()
        let data = WorkspaceTransfer.exportTree(tree)
        let decoded = try XCTUnwrap(WorkspaceTransfer.decodeTree(data), "a current-version tree document round-trips")
        XCTAssertEqual(decoded.schemaVersion, TreeWorkspace.currentSchemaVersion)
    }
}
