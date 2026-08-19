import CoreGraphics
import SlopDeskWorkspaceModel
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

    // MARK: - The seams cross as the caller's own splits

    /// Every seam comes back tagged with the SwiftUI-side identities and geometry it was asked
    /// about: the owning ``SplitNodeID``, the leading child's index, the axis, and a band centred on
    /// the cut — for a nested split as much as a top-level one, each carrying ITS split's span.
    func testEverySeamCrossesBackAsTheSplitItBelongsTo() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let outerID = SplitNodeID(), innerID = SplitNodeID()
        let root = SplitNode.split(id: outerID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .split(id: innerID, axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(3), node: .leaf(c)),
            ])),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 2, "one seam per level")
        let outer = try XCTUnwrap(layout.dividers.first { $0.splitID == outerID })
        let inner = try XCTUnwrap(layout.dividers.first { $0.splitID == innerID })
        XCTAssertEqual(outer.axis, .horizontal)
        XCTAssertEqual(outer.childIndex, 0)
        XCTAssertEqual(outer.rect.midX, 500, accuracy: eps, "centred on the cut")
        XCTAssertEqual(outer.rect.width, SplitTreeRenderModel.dividerThickness, accuracy: eps)
        XCTAssertEqual(outer.rect.height, bounds.height, accuracy: eps, "a column seam spans the height")
        XCTAssertEqual(outer.parentSpan, bounds.width, accuracy: eps)
        XCTAssertEqual(
            inner.parentSpan, bounds.width / 2, accuracy: eps,
            "a nested seam spans ITS split, not the container — that is what makes a drag track 1:1",
        )
        XCTAssertEqual(inner.rect.midX, 625, accuracy: eps, "the 1:3 cut of the right half")
        XCTAssertEqual(inner.leadingWeight, 1, accuracy: 1e-9)
        XCTAssertEqual(inner.trailingWeight, 3, accuracy: 1e-9)
        // The seam is exactly where the two tiles meet.
        let solved = SplitLayoutSolver.solve(root, in: bounds)
        XCTAssertEqual(solved[a]?.maxX ?? .nan, outer.rect.midX, accuracy: eps)
    }

    /// A lone leaf has nothing to drag, and n siblings share n-1 seams.
    func testSeamCountFollowsTheSiblings() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        XCTAssertTrue(
            SplitTreeRenderModel.layout(root: .leaf(a), zoomedPane: nil, in: bounds).dividers.isEmpty,
        )
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        XCTAssertEqual(SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers.count, 2)
    }

    /// A `.fixed` side crosses as the unresizable sentinel `0`, which freezes the seam both ways.
    func testAFixedSideCrossesAsTheUnresizableSentinel() throws {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .fixed(200), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let handle = try XCTUnwrap(
            SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds).dividers.first,
        )
        XCTAssertEqual(handle.leadingWeight, 0)
        XCTAssertFalse(handle.canMoveTowardLeading)
        XCTAssertFalse(handle.canMoveTowardTrailing)
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

    // The conversion under test is the SEAM's own (`SplitDividerHandle.weightDelta(pixelIncrement:)`),
    // never a local copy of it: pinning the seam's answer proves it moves 1:1 with the cursor. With
    // the OLD `Δpixel / span` (flexSum == 1 implicit) the top-level case moves N/2 and the nested
    // case N/4 — these assertions fail on the un-fixed code.

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
        let delta = handle.weightDelta(pixelIncrement: n)
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
        let delta = inner.weightDelta(pixelIncrement: n)
        let moved = root.resizingDivider(splitID: innerID, leadingIndex: 0, delta: delta)
        let x1 = try XCTUnwrap(SplitLayoutSolver.solve(moved, in: bounds)[b]?.maxX)

        XCTAssertEqual(x1 - x0, n, accuracy: 0.5, "nested seam tracks 1:1 (N/4 on the un-fixed code)")
    }

    // MARK: - The drag's three answers reach their rule

    /// Each entry point on a handle reaches the crate rule of the same name: both directions live
    /// mid-range, dead once that side sits at the solver's PIXEL floor (not merely the weight one),
    /// and the clamp lands a proposal on that floor either side while passing an in-range one
    /// through. The enumeration of the rule itself lives in `split_layout`'s own tests.
    func testTheDragsAnswersReachTheirRule() {
        let free = handle(leading: 1, trailing: 1, span: 1000)
        XCTAssertTrue(free.canMoveTowardLeading)
        XCTAssertTrue(free.canMoveTowardTrailing)
        // Span 1000 at a flex sum of 2: the 160 pt column floor is weight 0.32.
        XCTAssertEqual(free.clampedLeadingWeight(0), 0.32, accuracy: 1e-9, "the leading floor")
        XCTAssertEqual(free.clampedLeadingWeight(5), 1.68, accuracy: 1e-9, "sum-preserving on the other side")
        XCTAssertEqual(free.clampedLeadingWeight(0.9), 0.9, accuracy: 1e-9, "in range, untouched")

        // 0.5 of a flex sum of 2 over 400 pt renders 100 pt: over the weight floor, under the pixel one.
        let starved = handle(leading: 0.5, trailing: 1.5, span: 400)
        XCTAssertGreaterThan(0.5, SplitWeight.minWeight, "premise: the weight floor alone would allow this")
        XCTAssertFalse(starved.canMoveTowardLeading, "100 pt is under the 160 pt floor")
        XCTAssertTrue(starved.canMoveTowardTrailing)
    }

    /// A ROW seam floors at the min-leaf HEIGHT, so the axis crosses as itself rather than defaulting.
    func testTheAxisCrossesAsItselfSoARowSeamFloorsAtTheHeight() {
        let row = SplitTreeRenderModel.DividerHandle(
            splitID: SplitNodeID(), childIndex: 0, axis: .vertical, rect: .zero,
            parentSpan: 1000, flexSum: 2, leadingWeight: 1, trailingWeight: 1,
        )
        XCTAssertEqual(row.clampedLeadingWeight(0), 0.24, accuracy: 1e-9, "120/1000·2, not the width's 0.32")
    }

    private func handle(
        leading: Double, trailing: Double, span: CGFloat = 800,
    ) -> SplitTreeRenderModel.DividerHandle {
        SplitTreeRenderModel.DividerHandle(
            splitID: SplitNodeID(), childIndex: 0, axis: .horizontal, rect: .zero,
            parentSpan: span, flexSum: leading + trailing,
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
