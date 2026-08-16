// DesktopWindowDomainTests — pins the dedicated-desktop-window pivot's DOMAIN half
// (docs/DECISIONS.md 2026-07-22): a `.desktop` pane lives ONLY in `Session.detached` (its satellite
// window), is minted there directly, never reattaches into a tab, and never survives a relaunch.

import SlopDeskWorkspaceModel
import XCTest

final class DesktopWindowDomainTests: XCTestCase {
    private var ws: TreeWorkspace { .defaultWorkspace() }

    private func desktopSpec(displayID: UInt32 = 0) -> PaneSpec {
        PaneSpec(
            kind: .desktop,
            title: "Desktop",
            video: VideoEndpoint(windowID: 0, title: "Desktop", displayID: displayID),
        )
    }

    // MARK: - mintDetachedPane

    /// A desktop pane is born DIRECTLY into `detached`: the spec joins the side table, no tab
    /// changes, and the (detach-widened) specs invariant holds.
    func testMintDetachedPaneNeverTouchesTheTree() {
        let before = ws
        let tabsBefore = before.activeSession?.tabs.count
        let (after, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: before)

        XCTAssertEqual(after.activeSession?.tabs.count, tabsBefore, "no tab is minted or grown")
        XCTAssertTrue(after.activeSession?.isDetached(id) == true)
        XCTAssertEqual(after.spec(for: id)?.kind, .desktop)
        XCTAssertTrue(after.isInvariantHeld())
    }

    /// Each mint is a fresh pane (one per display is the multi-display shape).
    func testMintDetachedPaneMintsSiblings() {
        var tree = ws
        let (t1, first) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(displayID: 0), in: tree)
        tree = t1
        let (t2, second) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(displayID: 7), in: tree)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(t2.activeSession?.detached.count, 2)
    }

    // MARK: - reattach guards (the desktop never joins a tab)

    func testReattachPaneNoOpsForADesktopPane() {
        let (tree, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: ws)
        let after = WorkspaceTreeOps.reattachPane(id, in: tree)
        XCTAssertEqual(after, tree, "a desktop pane must never fold back into a tab")
    }

    func testReattachPaneToNewTabNoOpsForADesktopPane() {
        let (tree, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: tree0())
        let after = WorkspaceTreeOps.reattachPaneToNewTab(id, in: tree)
        XCTAssertEqual(after, tree)
    }

    func testReattachBesideAnchorNoOpsForADesktopPane() throws {
        let (tree, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: tree0())
        let anchor = try XCTUnwrap(tree.activeSession?.activeTab?.allPaneIDs().first)
        let after = WorkspaceTreeOps.reattachPane(id, beside: anchor, axis: .horizontal, before: false, in: tree)
        XCTAssertEqual(after, tree)
    }

    func testReattachToRootEdgeNoOpsForADesktopPane() {
        let (tree, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: tree0())
        let after = WorkspaceTreeOps.reattachPane(id, toActiveTabRootEdge: .right, in: tree)
        XCTAssertEqual(after, tree)
    }

    /// A non-desktop detached pane still reattaches — the guard is desktop-shaped, not a blanket.
    func testTerminalDetachedPaneStillReattaches() throws {
        var tree = tree0()
        let target = try XCTUnwrap(tree.activeSession?.activeTab?.allPaneIDs().first)
        // Give the tab a second leaf so the detach leaves the tab alive.
        tree = WorkspaceTreeOps.splitPane(
            target, axis: .horizontal,
            newSpec: PaneSpec(kind: .terminal, title: "Terminal"),
            in: tree,
        ).0
        tree = WorkspaceTreeOps.detachPane(target, in: tree)
        XCTAssertTrue(tree.activeSession?.isDetached(target) == true)
        let after = WorkspaceTreeOps.reattachPane(target, in: tree)
        XCTAssertFalse(after.activeSession?.isDetached(target) == true)
    }

    // MARK: - launch drop (the desktop never survives a relaunch)

    func testRedockDropsDetachedDesktopPanes() {
        let (tree, id) = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: tree0())
        let restored = tree.redockingDetachedPanes()
        XCTAssertNil(restored.spec(for: id), "a persisted desktop window is dropped, never redocked")
        XCTAssertFalse(restored.activeSession?.isDetached(id) == true)
        XCTAssertTrue(restored.isInvariantHeld())
    }

    /// An older file may carry a `.desktop` TREE leaf (the pre-pivot tab era) — dropped at launch,
    /// never rendered as a tab again.
    func testRedockDropsTreeResidentDesktopLeavesFromOlderFiles() throws {
        var tree = tree0()
        let anchor = try XCTUnwrap(tree.activeSession?.activeTab?.allPaneIDs().first)
        let (grown, desktopLeaf) = WorkspaceTreeOps.splitPane(
            anchor, axis: .horizontal, newSpec: desktopSpec(), in: tree,
        )
        tree = grown
        XCTAssertEqual(tree.spec(for: desktopLeaf)?.kind, .desktop)

        let restored = tree.redockingDetachedPanes()
        XCTAssertNil(restored.spec(for: desktopLeaf))
        XCTAssertFalse(restored.allPaneIDs().contains(desktopLeaf))
        XCTAssertNotNil(restored.spec(for: anchor), "the neighbouring terminal survives the drop")
        XCTAssertTrue(restored.isInvariantHeld())
    }

    /// The drop is surgical: a terminal detached pane in the SAME file still redocks.
    func testRedockKeepsRedockingTerminalDetachedPanes() throws {
        var tree = tree0()
        let target = try XCTUnwrap(tree.activeSession?.activeTab?.allPaneIDs().first)
        tree = WorkspaceTreeOps.splitPane(
            target, axis: .horizontal,
            newSpec: PaneSpec(kind: .terminal, title: "Terminal"),
            in: tree,
        ).0
        tree = WorkspaceTreeOps.detachPane(target, in: tree)
        tree = WorkspaceTreeOps.mintDetachedPane(spec: desktopSpec(), in: tree).0

        let restored = tree.redockingDetachedPanes()
        XCTAssertFalse(restored.activeSession?.isDetached(target) == true, "the terminal redocked")
        XCTAssertNotNil(restored.spec(for: target))
        XCTAssertFalse(
            restored.sessions.flatMap(\.detached).contains { restored.spec(for: $0.pane)?.kind == .desktop },
            "no desktop pane survives the launch restore",
        )
    }

    private func tree0() -> TreeWorkspace { .defaultWorkspace() }
}
