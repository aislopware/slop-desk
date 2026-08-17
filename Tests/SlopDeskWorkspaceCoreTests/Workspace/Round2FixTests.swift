import CoreGraphics
import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the fixes from the round-2 self-review:
/// G1 palette recents record from apply() (keyboard/menu, not just the palette); G3 live group-drag
/// offset broadcast; G4 nativeFrameSize eviction on close.
@MainActor
final class Round2FixTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { seed in FakePaneSession(seed.spec) }, liveVideoCap: 5)
    }

    private func item(_ id: PaneID, _ frame: CGRect, _ kind: PaneKind = .terminal) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: kind, title: "p"), frame: frame, z: 0)
    }

    // MARK: - G1: recents record at the apply chokepoint

    func testApplyRecordsRecentsForVerbs() {
        let store = makeStore()
        apply(.tidy, to: store)
        apply(.toggleOverview, to: store)
        XCTAssertEqual(
            store.recentCommands,
            [.toggleOverview, .tidy],
            "a command run via apply() (keyboard/menu) populates recents, not just the palette",
        )
    }

    func testApplyDoesNotRecordNavigationVerbs() {
        let store = makeStore()
        apply(.centerAll, to: store)
        apply(.focus(.left), to: store)
        XCTAssertTrue(store.recentCommands.isEmpty, "navigation/transient verbs don't churn the recents ring")
        XCTAssertFalse(WorkspaceCommand.centerAll.isRecentsWorthy)
        XCTAssertTrue(WorkspaceCommand.tidy.isRecentsWorthy)
    }

    // MARK: - G3: live group-drag offset

    func testGroupDragOffsetFollowsAnchorForOthersOnly() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 480, height: 320)),
            item(b, CGRect(x: 600, y: 0, width: 480, height: 320)),
            item(c, CGRect(x: 1200, y: 0, width: 480, height: 320)),
        ]), focusedPane: a))
        store.setSelection([a, b])

        store.updateGroupDrag(anchor: a, delta: CGSize(width: 40, height: 20))
        XCTAssertEqual(
            store.groupDragOffset(for: b),
            CGSize(width: 40, height: 20),
            "a non-anchor selected pane follows",
        )
        XCTAssertEqual(store.groupDragOffset(for: a), .zero, "the anchor uses its own gesture preview")
        XCTAssertEqual(store.groupDragOffset(for: c), .zero, "an unselected pane doesn't move")

        store.endGroupDragLive()
        XCTAssertEqual(store.groupDragOffset(for: b), .zero, "cleared on drag end")
    }

    func testGroupDragIgnoredForSinglePaneSelection() {
        let a = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 480, height: 320)),
        ]), focusedPane: a))
        store.setSelection([a])
        store.updateGroupDrag(anchor: a, delta: CGSize(width: 40, height: 0))
        XCTAssertNil(store.groupDragLive, "a single-pane selection is not a group drag")
    }

    // MARK: - G4: nativeFrameSize eviction

    func testNativeSizeEvictedWhenPaneCloses() {
        let a = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 800, height: 600), .desktop),
        ]), focusedPane: a))
        store.snapPaneToContentSize(
            a,
            target: CGSize(width: 1000, height: 700),
            current: CGSize(width: 760, height: 560),
        )
        XCTAssertTrue(store.hasNativeSize(a))
        store.closePane(a)
        XCTAssertFalse(store.hasNativeSize(a), "a closed pane's cached native size is evicted (no leak)")
    }

    // MARK: - paneAgentStatus eviction on close (review #10/#13)

    /// A closed pane's per-pane Claude status (``WorkspaceStore/paneAgentStatus``) must be pruned in
    /// `reconcileRegistry` — like the sibling `selectedPanes` / `nativeFrameSize` caches. Before the fix
    /// the entry lingered forever (unbounded growth + a dead pane could surface in a rollup). The other
    /// pane's status survives (the prune is selective, not a blanket clear) — revert-to-confirm-fail.
    func testPaneAgentStatusEvictedWhenPaneCloses() {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 800, height: 600)),
            item(b, CGRect(x: 820, y: 0, width: 800, height: 600)),
        ]), focusedPane: a))
        store.setAgentStatus(.needsPermission, for: a)
        store.setAgentStatus(.working, for: b)
        XCTAssertEqual(store.agentStatus(for: a), .needsPermission)

        store.closePane(a)
        XCTAssertEqual(store.agentStatus(for: a), .none, "a closed pane's agent status entry is pruned")
        XCTAssertFalse(store.paneAgentStatus.keys.contains(a), "the dict no longer holds the orphaned pane's key")
        XCTAssertEqual(
            store.agentStatus(for: b),
            .working,
            "the surviving pane's status is untouched (selective prune)",
        )
    }
}
