import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``SplitTreeRenderModel`` (W5, docs/42 §"W5 — First-test"): the headless seam the
/// `SplitTreeView` renders from. These assert: leaf placement matches ``SplitLayoutSolver`` exactly,
/// `zoomedPane` collapses to one full-bounds leaf with no dividers, divider rects lie ON the seam
/// BETWEEN adjacent siblings (tagged with the right `splitID` / leading `childIndex` / `axis`), and the
/// degenerate empty / single-leaf cases.
///
/// GUI views are compiled + code-reviewed only (hang-safety — no SCStream/VT/Metal/libghostty in tests);
/// this render model is the headless proof of the split-view geometry.
final class SplitTreeRenderModelTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    // MARK: - Placement matches the solver

    func testSingleLeafFillsBoundsNoDividers() {
        let a = PaneID()
        let bounds = CGRect(x: 5, y: 7, width: 800, height: 600)
        let layout = SplitTreeRenderModel.layout(root: .leaf(a), zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertEqual(layout.leaves.first?.id, a)
        assertRectEqual(layout.leaves.first?.rect, bounds)
        XCTAssertTrue(layout.dividers.isEmpty, "a single leaf has no divider")
    }

    func testLeafPlacementMatchesSolverExactly() {
        // A nested tree: horizontal split of [a | (b over c)] so both axes + nesting are exercised.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let innerID = SplitNodeID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(2), node: .split(id: innerID, axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)
        let solved = SplitLayoutSolver.solve(root, in: bounds)

        // Every solver leaf appears EXACTLY once with the solver's rect.
        XCTAssertEqual(Set(layout.leaves.map(\.id)), Set(solved.keys))
        XCTAssertEqual(layout.leaves.count, solved.count)
        for placed in layout.leaves {
            assertRectEqual(placed.rect, solved[placed.id])
        }
        // Order is the tree's deterministic pre-order DFS.
        XCTAssertEqual(layout.leaves.map(\.id), root.allPaneIDs())
    }

    // MARK: - Zoom → one full-bounds leaf

    func testZoomYieldsOneFullBoundsLeafNoDividers() {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 10, y: 20, width: 1000, height: 700)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: b, in: bounds)

        XCTAssertEqual(layout.leaves.count, 1, "zoom renders exactly the zoomed leaf")
        XCTAssertEqual(layout.leaves.first?.id, b)
        assertRectEqual(layout.leaves.first?.rect, bounds, "the zoomed leaf fills the whole bound")
        XCTAssertTrue(layout.dividers.isEmpty, "a zoomed tab shows no dividers")
    }

    func testStaleZoomFallsThroughToTiledLayout() {
        // A zoom naming a pane NOT in the tree is ignored (the tiled layout renders).
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: PaneID(), in: bounds)

        XCTAssertEqual(layout.leaves.count, 2, "a stale zoom id does not collapse the layout")
        XCTAssertEqual(layout.dividers.count, 1)
    }

    // MARK: - Dividers lie between siblings

    func testHorizontalSplitDividerSitsOnTheSeam() {
        // weights 1:3 over width 800 → seam at x = 200; the divider is a vertical band centered there.
        let a = PaneID(), b = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(3), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let thickness: CGFloat = 8

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds, dividerThickness: thickness)

        XCTAssertEqual(layout.dividers.count, 1)
        let d = layout.dividers[0]
        XCTAssertEqual(d.splitID, splitID)
        XCTAssertEqual(d.childIndex, 0, "the divider's leading child is index 0")
        XCTAssertEqual(d.axis, .horizontal)
        // The band is centered on the seam x = 200, full parent height.
        XCTAssertEqual(d.rect.midX, 200, accuracy: eps)
        XCTAssertEqual(d.rect.width, thickness, accuracy: eps)
        XCTAssertEqual(d.rect.minY, bounds.minY, accuracy: eps)
        XCTAssertEqual(d.rect.height, bounds.height, accuracy: eps)
        // The seam is exactly where leaf a ends and leaf b begins.
        let solved = SplitLayoutSolver.solve(root, in: bounds)
        XCTAssertEqual(solved[a]?.maxX ?? .nan, d.rect.midX, accuracy: eps)
        XCTAssertEqual(solved[b]?.minX ?? .nan, d.rect.midX, accuracy: eps)
    }

    func testVerticalSplitDividerIsHorizontalBand() {
        // weights 1:1 over height 600 → seam at y = 300; the divider is a horizontal band centered there.
        let a = PaneID(), b = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .vertical, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 1)
        let d = layout.dividers[0]
        XCTAssertEqual(d.axis, .vertical)
        XCTAssertEqual(d.rect.midY, 300, accuracy: eps)
        XCTAssertEqual(d.rect.minX, bounds.minX, accuracy: eps)
        XCTAssertEqual(d.rect.width, bounds.width, accuracy: eps, "a vertical split's divider spans the full width")
    }

    func testThreeWaySplitYieldsTwoDividersAtSeams() {
        // weights 1:1:2 over width 800 → seams at x = 200 and x = 400.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 2, "n children → n-1 dividers")
        let byIndex = layout.dividers.sorted { $0.childIndex < $1.childIndex }
        XCTAssertEqual(byIndex[0].childIndex, 0)
        XCTAssertEqual(byIndex[0].rect.midX, 200, accuracy: eps)
        XCTAssertEqual(byIndex[1].childIndex, 1)
        XCTAssertEqual(byIndex[1].rect.midX, 400, accuracy: eps)
        XCTAssertTrue(byIndex.allSatisfy { $0.splitID == splitID })
    }

    func testNestedSplitsEmitDividersForBothLevels() {
        // [a | (b / c)] → one outer (horizontal) divider + one inner (vertical) divider, distinct splitIDs.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let outerID = SplitNodeID(), innerID = SplitNodeID()
        let root = SplitNode.split(id: outerID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .split(id: innerID, axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 2)
        let outer = layout.dividers.first { $0.splitID == outerID }
        let inner = layout.dividers.first { $0.splitID == innerID }
        XCTAssertNotNil(outer)
        XCTAssertNotNil(inner)
        XCTAssertEqual(outer?.axis, .horizontal)
        XCTAssertEqual(inner?.axis, .vertical)
        // The inner (vertical) divider lives in the right half (x ≥ 500) and is centered at its mid-height.
        XCTAssertGreaterThanOrEqual(inner?.rect.minX ?? -1, 500 - eps)
        XCTAssertEqual(inner?.rect.midY ?? .nan, 300, accuracy: eps)
    }

    // MARK: - Tab entry point + degenerate cases

    func testTabEntryPointHonorsZoom() {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let tab = Tab(root: root, activePane: a, zoomedPane: a)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)

        XCTAssertEqual(layout.leaves.map(\.id), [a])
        assertRectEqual(layout.leaves.first?.rect, bounds)
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    func testOneLeafTabHasNoDividers() {
        let a = PaneID()
        let tab = Tab(root: .leaf(a), activePane: a)
        let layout = SplitTreeRenderModel.layout(for: tab, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    // MARK: - Divider drag → on-screen seam movement (revert-to-confirm-fail for the flexSum fix)

    /// The production pixel→weight conversion (mirrors `PaneMath.weightDelta`, which lives in ClientUI):
    /// `Δweight = Δpixel / span * flexSum`. Pinning it HERE proves the seam moves 1:1 with the cursor once
    /// the conversion is span-and-flexSum aware. With the OLD `Δpixel / span` (flexSum == 1 implicit) the
    /// top-level case moves N/2 and the nested case N/4 — these assertions fail on the un-fixed code.
    private func weightDelta(pixel: CGFloat, span: CGFloat, flexSum: CGFloat) -> Double {
        Double(pixel) / Double(span) * Double(flexSum)
    }

    /// A top-level 50/50 horizontal split: dragging the divider by N points moves the leading leaf's
    /// trailing edge by ~N points (NOT N/2). Uses the `flexSum` the render model now publishes.
    func testDividerDragMovesSeamOneToOneTopLevel() throws {
        let a = PaneID(), b = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let span: CGFloat = 800
        let bounds = CGRect(x: 0, y: 0, width: span, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)
        let handle = try XCTUnwrap(layout.dividers.first)
        XCTAssertEqual(handle.flexSum, 2, "a seeded 50/50 split has flexSum == 2")
        XCTAssertEqual(handle.parentSpan, span, "a top-level divider's parentSpan is the full bound")

        let x0 = try XCTUnwrap(SplitLayoutSolver.solve(root, in: bounds)[a]?.maxX)
        let n: CGFloat = 120
        let delta = weightDelta(pixel: n, span: handle.parentSpan, flexSum: handle.flexSum)
        let moved = root.resizingDivider(splitID: splitID, leadingIndex: 0, delta: delta)
        let x1 = try XCTUnwrap(SplitLayoutSolver.solve(moved, in: bounds)[a]?.maxX)

        XCTAssertEqual(x1 - x0, n, accuracy: 0.5, "the seam tracks the cursor 1:1 (N/2 on the un-fixed code)")
    }

    /// A NESTED split: the inner split's `parentSpan` is half the bound, so the 4× under-tracking of the
    /// un-fixed code (N/4) is pinned to ~N here.
    func testDividerDragMovesSeamOneToOneNested() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let innerID = SplitNodeID()
        // outer: [a | inner(b|c)] with equal outer weights ⇒ inner occupies the trailing HALF of the bound.
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .split(id: innerID, axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let span: CGFloat = 800
        let bounds = CGRect(x: 0, y: 0, width: span, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)
        let inner = try XCTUnwrap(layout.dividers.first { $0.splitID == innerID })
        XCTAssertEqual(inner.parentSpan, span / 2, accuracy: eps, "the inner split spans half the bound")
        XCTAssertEqual(inner.flexSum, 2)

        let x0 = try XCTUnwrap(SplitLayoutSolver.solve(root, in: bounds)[b]?.maxX)
        let n: CGFloat = 60
        let delta = weightDelta(pixel: n, span: inner.parentSpan, flexSum: inner.flexSum)
        let moved = root.resizingDivider(splitID: innerID, leadingIndex: 0, delta: delta)
        let x1 = try XCTUnwrap(SplitLayoutSolver.solve(moved, in: bounds)[b]?.maxX)

        XCTAssertEqual(x1 - x0, n, accuracy: 0.5, "nested seam tracks 1:1 (N/4 on the un-fixed code)")
    }

    // MARK: - Divider live-drag anchor (leadingWeight)

    /// Each divider handle carries the LEADING child's current `.flex` weight — the anchor a live drag reads
    /// once at drag start, then offsets by the cursor translation (`leadingWeight + Δpx·flexSum/parentSpan`).
    /// Pins that it mirrors the tree weight and is per-seam (each seam reports ITS leading child).
    func testDividerLeadingWeightMirrorsTheChildFlexWeight() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(3), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let dividers = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers
            .sorted { $0.childIndex < $1.childIndex }

        XCTAssertEqual(dividers.count, 2)
        XCTAssertEqual(dividers[0].leadingWeight, 1, accuracy: 1e-9, "seam 0's leading child is weight 1")
        XCTAssertEqual(dividers[1].leadingWeight, 3, accuracy: 1e-9, "seam 1's leading child is weight 3")
    }

    /// A `.fixed` leading child makes the seam unresizable, so the handle reports `leadingWeight == 0`.
    func testDividerLeadingWeightZeroForFixedLeadingChild() throws {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .fixed(200), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let handle = try XCTUnwrap(
            SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers.first,
        )
        XCTAssertEqual(handle.leadingWeight, 0, "a fixed leading child reports 0 (unresizable)")
    }

    /// The handle also carries the TRAILING child's flex weight — the other half of the drag clamp's
    /// pair, feeding the hover cursor's movability. Per-seam like `leadingWeight`; a layout that dropped
    /// it (leaving the default 0) would read every seam as one-way-immovable.
    func testDividerTrailingWeightMirrorsTheNextChildFlexWeight() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(3), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let dividers = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers
            .sorted { $0.childIndex < $1.childIndex }

        XCTAssertEqual(dividers.count, 2)
        XCTAssertEqual(dividers[0].trailingWeight, 3, accuracy: 1e-9, "seam 0's trailing child is weight 3")
        XCTAssertEqual(dividers[1].trailingWeight, 2, accuracy: 1e-9, "seam 1's trailing child is weight 2")
    }

    // MARK: - Divider movability (the hover cursor's one-way vs two-way truth)

    /// Mid-range weights: both directions live — the two-way resize cursor.
    func testDividerMovabilityBothWaysMidRange() {
        let handle = movabilityHandle(leading: 1, trailing: 1)
        XCTAssertTrue(handle.canMoveTowardLeading)
        XCTAssertTrue(handle.canMoveTowardTrailing)
    }

    /// The LEADING child parked AT the ``SplitWeight/minWeight`` floor (where the live-drag clamp
    /// leaves it): the seam can no longer move toward it — the cursor must drop to the one-way arrow.
    func testDividerMovabilityDeadTowardLeadingAtFloor() {
        let handle = movabilityHandle(leading: SplitWeight.minWeight, trailing: 1.95)
        XCTAssertFalse(handle.canMoveTowardLeading, "leading child at the floor — that direction is dead")
        XCTAssertTrue(handle.canMoveTowardTrailing)
    }

    /// The TRAILING child at the floor — the mirror case.
    func testDividerMovabilityDeadTowardTrailingAtFloor() {
        let handle = movabilityHandle(leading: 1.95, trailing: SplitWeight.minWeight)
        XCTAssertTrue(handle.canMoveTowardLeading)
        XCTAssertFalse(handle.canMoveTowardTrailing, "trailing child at the floor — that direction is dead")
    }

    /// A `.fixed` side (weight sentinel 0) kills BOTH directions — the seam is not resizable at all.
    func testDividerMovabilityDeadForFixedSide() {
        let handle = movabilityHandle(leading: 0, trailing: 1)
        XCTAssertFalse(handle.canMoveTowardLeading)
        XCTAssertFalse(handle.canMoveTowardTrailing)
    }

    private func movabilityHandle(leading: Double, trailing: Double) -> SplitTreeRenderModel.DividerHandle {
        SplitTreeRenderModel.DividerHandle(
            splitID: SplitNodeID(), childIndex: 0, axis: .horizontal, rect: .zero,
            parentSpan: 800, flexSum: leading + trailing,
            leadingWeight: leading, trailingWeight: trailing,
        )
    }

    // MARK: - Stable identity key (load-bearing for the live-drag ForEach)

    /// The divider's `key` MUST be invariant to the live `rect`/`leadingWeight`: it's the SwiftUI identity the
    /// `ForEach` keys on, and during a live drag the weight (hence rect) changes every frame. If the key moved
    /// with the weight, SwiftUI would tear down + recreate the divider view mid-drag and cancel the in-flight
    /// resize gesture (the drag stalls partway). Same structural seam `(splitID, childIndex, axis)` → equal key,
    /// regardless of weight; a different seam → different key. (Revert: key off `\.self` and this fails.)
    func testDividerKeyIsStableAcrossWeightAndRect() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let splitID = SplitNodeID()
        func seam0Key(leadingWeight: Double) -> SplitTreeRenderModel.DividerHandle.Key {
            let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
                WeightedChild(weight: .flex(leadingWeight), node: .leaf(a)),
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
            let dividers = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers
                .sorted { $0.childIndex < $1.childIndex }
            return dividers[0].key
        }
        // Dragging seam 0 changes its leading weight (1 → 5) and so its rect — the key must NOT move.
        XCTAssertEqual(
            seam0Key(leadingWeight: 1),
            seam0Key(leadingWeight: 5),
            "the same seam's key is invariant to weight/rect (else the gesture is cancelled mid-drag)",
        )
    }

    /// Distinct seams of the same split get distinct keys (so the `ForEach` renders them as separate handles).
    func testDividerKeysAreDistinctPerSeam() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
            WeightedChild(weight: .flex(1), node: .leaf(c)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let keys = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "every seam has a unique identity key")
    }

    // MARK: - Helpers

    private func assertRectEqual(
        _ lhs: CGRect?,
        _ rhs: CGRect?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        guard let lhs, let rhs else {
            XCTFail("nil rect \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: eps, "minX \(message)", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: eps, "minY \(message)", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: eps, "width \(message)", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: eps, "height \(message)", file: file, line: line)
    }
}
