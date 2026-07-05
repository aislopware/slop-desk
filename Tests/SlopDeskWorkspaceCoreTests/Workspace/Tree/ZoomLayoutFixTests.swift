import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Audit fixes for the zoom/layout cluster:
///
/// 1. **Zoom keeps siblings MOUNTED** — `SplitTreeRenderModel` must emit every non-zoomed pane as a
///    zoom-HIDDEN compositor leaf, so `SplitContainer` keeps their surfaces alive at
///    `opacity 0` (the same no-teardown trick as keep-all-tabs-mounted). Before the fix the zoom branch
///    dropped the siblings from the layout entirely → their libghostty surfaces / video streams were torn
///    down and un-zoom repainted them from the lossy replay ring.
/// 2. **Split/focus ops while zoomed exit zoom first** (the documented applyLayout/cycleLayout rule) —
///    otherwise ⌘D while zoomed created an invisible focused pane and the next ⇧⌘↩ zoomed the chooser.
///
/// Headless: pure render-model geometry + pure tree ops.
final class ZoomLayoutFixTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A 2-leaf horizontal split `[a | b]` with equal weights.
    private func twoLeafRoot(_ a: PaneID, _ b: PaneID) -> SplitNode {
        .split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
    }

    // MARK: - 1) Zoom keeps every sibling in the compositor (mounted, hidden)

    /// While zoomed, `compositorLeaves` must still contain EVERY pane of the tab — the zoomed leaf visible
    /// at full bounds, the tiled sibling mounted (for the view to hide) — so no surface is
    /// ever unmounted by a zoom toggle. FAILS on the un-fixed model (zoom emitted ONLY the zoomed leaf).
    func testZoomKeepsEverySiblingInCompositorLeaves() {
        let a = PaneID(), b = PaneID()
        let tab = Tab(root: twoLeafRoot(a, b), activePane: b, zoomedPane: b)

        let zoomed = SplitTreeRenderModel.layout(for: tab, in: bounds)

        // The VISIBLE contract is unchanged: one full-bounds leaf, no dividers.
        XCTAssertEqual(zoomed.leaves.map(\.id), [b], "zoom shows exactly the zoomed leaf")
        XCTAssertEqual(zoomed.leaves.first?.rect, bounds, "the zoomed leaf fills the whole bound")
        XCTAssertTrue(zoomed.dividers.isEmpty, "a zoomed tab shows no dividers")

        // The MOUNT contract is new: every pane of the tab is still a compositor leaf (no teardown).
        XCTAssertEqual(
            Set(zoomed.compositorLeaves.map(\.id)), Set([a, b]),
            "zoom must keep every sibling pane MOUNTED in the compositor (hidden, not unmounted)",
        )
    }

    /// The zoom-hidden entries carry the right flags + rects: the sibling keeps its TILED solver rect (so
    /// its surface never reflows while hidden and un-zoom is a pure visibility flip), while the zoomed leaf
    /// is the only NON-hidden entry.
    func testZoomHiddenLeavesKeepTheirUnzoomedRects() throws {
        let a = PaneID(), b = PaneID()
        let root = twoLeafRoot(a, b)
        let zoomedTab = Tab(root: root, activePane: b, zoomedPane: b)
        let tiledTab = Tab(root: root, activePane: b, zoomedPane: nil)

        let zoomed = SplitTreeRenderModel.layout(for: zoomedTab, in: bounds)
        let tiled = SplitTreeRenderModel.layout(for: tiledTab, in: bounds)

        let hiddenA = try XCTUnwrap(zoomed.compositorLeaves.first { $0.id == a }, "sibling a stays mounted")
        let visibleB = try XCTUnwrap(zoomed.compositorLeaves.first { $0.id == b })

        XCTAssertTrue(hiddenA.isHidden, "the tiled sibling is zoom-hidden")
        XCTAssertFalse(visibleB.isHidden, "the zoomed leaf is the visible one")

        let tiledA = try XCTUnwrap(tiled.leaves.first { $0.id == a })
        XCTAssertEqual(hiddenA.leaf.rect, tiledA.rect, "the hidden sibling keeps its tiled rect (no reflow)")
    }

    /// The un-zoomed layout emits NO hidden leaves — the zoom branch is the only producer, so the normal
    /// tiled path stays byte-identical to before.
    func testUnzoomedLayoutHasNoHiddenLeaves() {
        let a = PaneID(), b = PaneID()
        let tab = Tab(root: twoLeafRoot(a, b), activePane: b)
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        XCTAssertTrue(layout.compositorLeaves.allSatisfy { !$0.isHidden }, "no hidden leaves while un-zoomed")
        XCTAssertEqual(Set(layout.compositorLeaves.map(\.id)), Set([a, b]))
    }

    // MARK: - 2) Split / focus while zoomed exit zoom first

    /// ⌘D while zoomed: `splitPane` must clear the tab's zoom — the new (focused) leaf would otherwise be
    /// collapsed away by the still-zoomed render. FAILS on the un-fixed op (zoomedPane survived the split).
    func testSplitPaneWhileZoomedExitsZoom() throws {
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let a = ws0.allPaneIDs()[0]
        let (ws1, _) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        let zoomedWs = WorkspaceTreeOps.toggleZoom(a, in: WorkspaceTreeOps.focusPane(a, in: ws1))
        XCTAssertEqual(zoomedWs.activeSession?.activeTab?.zoomedPane, a, "precondition: a is zoomed")

        let (ws2, newID) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "c"), in: zoomedWs,
        )

        let tab = try XCTUnwrap(ws2.activeSession?.activeTab)
        XCTAssertNil(tab.zoomedPane, "splitting while zoomed exits zoom (the new pane must be visible)")
        XCTAssertEqual(tab.activePane, newID, "the new leaf still takes focus")
    }

    /// Focusing ANOTHER pane while zoomed exits zoom (focus must never land on a pane the zoom collapse
    /// hides); re-focusing the zoomed pane itself keeps the zoom. FAILS on the un-fixed `focusPane`.
    func testFocusOtherPaneWhileZoomedExitsZoomButRefocusKeepsIt() throws {
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let a = ws0.allPaneIDs()[0]
        let (ws1, b) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        let zoomedWs = WorkspaceTreeOps.toggleZoom(a, in: WorkspaceTreeOps.focusPane(a, in: ws1))
        XCTAssertEqual(zoomedWs.activeSession?.activeTab?.zoomedPane, a, "precondition: a is zoomed")

        // Re-focusing the zoomed pane keeps the zoom (a click on the zoomed pane is not an exit).
        let refocused = WorkspaceTreeOps.focusPane(a, in: zoomedWs)
        XCTAssertEqual(refocused.activeSession?.activeTab?.zoomedPane, a, "refocusing the zoomed pane keeps zoom")

        // Focusing the hidden sibling exits zoom so the newly-focused pane is visible.
        let switched = WorkspaceTreeOps.focusPane(b, in: zoomedWs)
        let tab = try XCTUnwrap(switched.activeSession?.activeTab)
        XCTAssertNil(tab.zoomedPane, "focusing another pane while zoomed exits zoom")
        XCTAssertEqual(tab.activePane, b)
    }

    /// A directional focus move while zoomed resolves against the (zoom-independent) TREE geometry, lands
    /// on the sibling, and exits zoom — the ⌃⌘arrow behaviour while maximized.
    func testMoveFocusWhileZoomedLandsOnSiblingAndExitsZoom() throws {
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let a = ws0.allPaneIDs()[0]
        let (ws1, b) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        let zoomedWs = WorkspaceTreeOps.toggleZoom(a, in: WorkspaceTreeOps.focusPane(a, in: ws1))

        let moved = WorkspaceTreeOps.moveFocus(.right, bounds: bounds, in: zoomedWs)

        let tab = try XCTUnwrap(moved.activeSession?.activeTab)
        XCTAssertEqual(tab.activePane, b, "focus-right from the zoomed left pane lands on the right sibling")
        XCTAssertNil(tab.zoomedPane, "the directional focus move exits zoom")
    }
}
