import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the 4 fixes from the round-2 self-review:
/// G1 palette recents record from apply() (keyboard/menu, not just the palette); G2 deterministic
/// auto-switch winner; G3 live group-drag offset broadcast; G4 nativeFrameSize eviction on close.
@MainActor
final class Round2FixTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
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
        apply(.saveBookmark(1), to: store)
        apply(.recallBookmark(1), to: store)
        apply(.centerAll, to: store)
        apply(.focus(.left), to: store)
        XCTAssertTrue(store.recentCommands.isEmpty, "navigation/transient verbs don't churn the recents ring")
        XCTAssertFalse(WorkspaceCommand.saveBookmark(1).isRecentsWorthy)
        XCTAssertTrue(WorkspaceCommand.tidy.isRecentsWorthy)
    }

    // MARK: - G2: deterministic auto-switch order

    func testAutoSwitchPicksFirstPresetInSavedOrder() {
        // Two presets, two triggers — the FIRST-saved preset whose trigger appears wins, deterministically.
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 480, height: 320)),
            item(b, CGRect(x: 600, y: 0, width: 480, height: 320)),
        ]), focusedPane: a))
        // Save "first" (1 pane) with trigger Alpha, then "second" (2 panes) with trigger Beta.
        store.closePane(b)
        store.saveLayoutPreset(name: "first", triggerAppName: "Alpha")
        store.addPane(kind: .terminal) // 2 panes
        store.saveLayoutPreset(name: "second", triggerAppName: "Beta")
        // Both triggers present: the loop iterates presets in saved order, so "first" wins.
        // (Drive the store's per-app switch as the monitor would, in preset order.)
        for preset in store.workspace.layoutPresets {
            if let t = preset.triggerAppName, ["Alpha", "Beta"].contains(t) {
                if store.autoSwitchForLaunchedApp(t) { break }
            }
        }
        XCTAssertEqual(store.workspace.canvas.items.count, 1, "the first-saved matching layout (1 pane) won")
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
            item(a, CGRect(x: 0, y: 0, width: 800, height: 600), .remoteGUI),
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
}
