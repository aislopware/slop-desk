import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Flex-partition correctness for ``SplitLayoutSolver`` (W1, docs/42 Phase C1).
///
/// The solver is the geometry source of truth that replaces `Canvas.solvedLayout()` and feeds both the
/// render and ``FocusResolver``. These pin: proportional partition along the split axis, nested splits,
/// the minimum-leaf clamp, that every `allPaneIDs()` leaf gets a rect, and that the leaf rects **tile**
/// the bound (no gaps / overlaps) within epsilon for a non-degenerate bound.
final class SplitLayoutSolverTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    // MARK: Trivial

    func testSingleLeafFillsTheBound() {
        let a = PaneID()
        let bound = CGRect(x: 10, y: 20, width: 800, height: 600)
        let solved = SplitLayoutSolver.solve(.leaf(a), in: bound)
        XCTAssertEqual(solved.count, 1)
        let r = try? XCTUnwrap(solved[a])
        XCTAssertEqual(r?.minX ?? .nan, bound.minX, accuracy: eps)
        XCTAssertEqual(r?.minY ?? .nan, bound.minY, accuracy: eps)
        XCTAssertEqual(r?.width ?? .nan, bound.width, accuracy: eps)
        XCTAssertEqual(r?.height ?? .nan, bound.height, accuracy: eps)
    }

    // MARK: Flex partition

    func testTwoWayHorizontalSplitsByWeight() {
        // horizontal = side-by-side columns; weights 1:3 over width 800 → 200 | 600.
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(3), node: .leaf(b)),
        ])
        let bound = CGRect(x: 0, y: 0, width: 800, height: 400)
        let solved = SplitLayoutSolver.solve(root, in: bound)
        XCTAssertEqual(solved[a]?.width ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[b]?.width ?? .nan, 600, accuracy: eps)
        // Full height each, abutting at x = 200.
        XCTAssertEqual(solved[a]?.height ?? .nan, 400, accuracy: eps)
        XCTAssertEqual(solved[a]?.minX ?? .nan, 0, accuracy: eps)
        XCTAssertEqual(solved[b]?.minX ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[a]?.maxX ?? .nan, solved[b]?.minX ?? .nan, accuracy: eps)
    }

    func testThreeWayVerticalSplitsByWeight() {
        // vertical = stacked rows; weights 1:1:2 over height 800 → 200 | 200 | 400.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        let bound = CGRect(x: 0, y: 0, width: 500, height: 800)
        let solved = SplitLayoutSolver.solve(root, in: bound)
        XCTAssertEqual(solved[a]?.height ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[b]?.height ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[c]?.height ?? .nan, 400, accuracy: eps)
        // Stacked, abutting, full width.
        XCTAssertEqual(solved[a]?.minY ?? .nan, 0, accuracy: eps)
        XCTAssertEqual(solved[b]?.minY ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[c]?.minY ?? .nan, 400, accuracy: eps)
        XCTAssertEqual(solved[a]?.width ?? .nan, 500, accuracy: eps)
    }

    func testNestedSplitPartitionsRecursively() {
        // Left column (width 300) holds a leaf; right column (width 300) is split into two rows.
        let left = PaneID(), topRight = PaneID(), bottomRight = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(left)),
            WeightedChild(weight: .flex(1), node: .split(id: SplitNodeID(), axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(topRight)),
                WeightedChild(weight: .flex(1), node: .leaf(bottomRight)),
            ])),
        ])
        let bound = CGRect(x: 0, y: 0, width: 600, height: 400)
        let solved = SplitLayoutSolver.solve(root, in: bound)
        XCTAssertEqual(solved[left]?.width ?? .nan, 300, accuracy: eps)
        XCTAssertEqual(solved[left]?.height ?? .nan, 400, accuracy: eps)
        // Right column halves stack to 200 each, both at x = 300, width 300.
        XCTAssertEqual(solved[topRight]?.minX ?? .nan, 300, accuracy: eps)
        XCTAssertEqual(solved[topRight]?.width ?? .nan, 300, accuracy: eps)
        XCTAssertEqual(solved[topRight]?.height ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[bottomRight]?.minY ?? .nan, 200, accuracy: eps)
        XCTAssertEqual(solved[bottomRight]?.height ?? .nan, 200, accuracy: eps)
    }

    // MARK: minLeaf clamp

    func testMinLeafClampWhenBoundTooSmallForChildren() {
        // 5 columns in a 400-wide bound with minLeaf width 160 → each can't be 80; the clamp keeps every
        // rect ≥ minLeaf (rects will then exceed the bound, which is acceptable — the clamp is a floor).
        let ids = (0..<5).map { _ in PaneID() }
        let children = ids.map { WeightedChild(weight: .flex(1), node: SplitNode.leaf($0)) }
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: children)
        let bound = CGRect(x: 0, y: 0, width: 400, height: 300)
        let minLeaf = CGSize(width: 160, height: 120)
        let solved = SplitLayoutSolver.solve(root, in: bound, minLeaf: minLeaf)
        XCTAssertEqual(solved.count, 5)
        for id in ids {
            let r = solved[id] ?? .null
            XCTAssertGreaterThanOrEqual(r.width, minLeaf.width - eps, "each leaf width ≥ minLeaf.width")
            XCTAssertGreaterThanOrEqual(r.height, minLeaf.height - eps, "each leaf height ≥ minLeaf.height")
        }
    }

    // MARK: Coverage + tiling

    func testEveryLeafGetsARectAndAllPaneIDsIsSubsetOfKeys() {
        let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [
            WeightedChild(weight: .flex(1), node: .split(id: SplitNodeID(), axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(a)),
                WeightedChild(weight: .flex(2), node: .leaf(b)),
            ])),
            WeightedChild(weight: .flex(1), node: .split(id: SplitNodeID(), axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(c)),
                WeightedChild(weight: .flex(1), node: .leaf(d)),
            ])),
        ])
        let bound = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let solved = SplitLayoutSolver.solve(root, in: bound)
        XCTAssertTrue(Set(root.allPaneIDs()).isSubset(of: Set(solved.keys)), "every leaf id is solved")
        XCTAssertEqual(Set(root.allPaneIDs()), Set(solved.keys), "solver keys == leaf ids exactly")
    }

    func testLeafRectsTileTheBoundWithoutGapsOrOverlaps() {
        // A non-degenerate tree where the clamp does NOT bite: the union area of the leaf rects equals
        // the bound area, and no two leaves overlap.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(2), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .split(id: SplitNodeID(), axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let bound = CGRect(x: 0, y: 0, width: 900, height: 600)
        let solved = SplitLayoutSolver.solve(root, in: bound)
        let rects = Array(solved.values)

        // Areas sum to the bound (tiling — no gaps, no overlaps within epsilon).
        var areaSum: CGFloat = 0
        for r in rects { areaSum += r.width * r.height }
        XCTAssertEqual(areaSum, bound.width * bound.height, accuracy: 1.0, "leaf areas tile the bound")

        // Pairwise non-overlap (touching edges are fine, real area overlap is not).
        for i in rects.indices {
            for j in rects.indices where j > i {
                let inter = rects[i].intersection(rects[j])
                let overlapArea = inter.isNull ? 0 : inter.width * inter.height
                XCTAssertLessThan(overlapArea, 1.0, "leaf rects do not overlap")
            }
        }
    }

    // MARK: Fixed-weight bands (reachable via a hand-edited Codable file)

    func testTwoFixedChildrenEachAtLeastTotalDoNotOverlapAndStayInBound() {
        // `.fixed` is dormant in the MVP (only `.flex` is minted) but `SplitWeight.fixed` decodes from a
        // hand-edited file, so a pathological all-fixed split is reachable. Two `.fixed` children each
        // requesting the WHOLE bound (1000pt in a 1000pt bound) + a flex child: the solver must reserve
        // each fixed child its PER-CHILD share (pass 1's running clamp) and emit the SAME share in pass 2,
        // so the rects tile WITHOUT overlap and stay within the bound — never each capped at the whole bound.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .fixed(1000), node: .leaf(a)),
            WeightedChild(weight: .fixed(1000), node: .leaf(b)),
            WeightedChild(weight: .flex(1), node: .leaf(c)),
        ])
        let bound = CGRect(x: 0, y: 0, width: 1000, height: 400)
        // minLeaf .zero so the assertion reads the raw partition, not the per-leaf floor.
        let solved = SplitLayoutSolver.solve(root, in: bound, minLeaf: .zero)

        let ra = solved[a] ?? .null
        let rb = solved[b] ?? .null
        let rc = solved[c] ?? .null

        // Pairwise non-overlap (touching edges fine; real area overlap is the bug).
        for (lhs, rhs) in [(ra, rb), (ra, rc), (rb, rc)] {
            let inter = lhs.intersection(rhs)
            let overlapArea = inter.isNull ? 0 : inter.width * inter.height
            XCTAssertLessThan(overlapArea, 1.0, "fixed children must not overlap")
        }
        // The union of every leaf rect stays within the bound (no overflow past width 1000).
        for r in [ra, rb, rc] {
            XCTAssertGreaterThanOrEqual(r.minX, bound.minX - eps, "no rect starts left of the bound")
            XCTAssertLessThanOrEqual(r.maxX, bound.maxX + eps, "no rect runs past the right edge of the bound")
        }
        // The flex child gets the leftover (here 0) — non-negative, never a negative extent.
        XCTAssertGreaterThanOrEqual(rc.width, -eps, "the flex child width is non-negative")
    }

    func testFixedBandReservesItsShareThenFlexFillsTheRemainder() {
        // A well-behaved fixed band: 200pt fixed + flex over a 1000pt bound → fixed=200, flex=800, abutting.
        let fixed = PaneID(), flex = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .fixed(200), node: .leaf(fixed)),
            WeightedChild(weight: .flex(1), node: .leaf(flex)),
        ])
        let solved = SplitLayoutSolver.solve(root, in: CGRect(x: 0, y: 0, width: 1000, height: 400), minLeaf: .zero)
        XCTAssertEqual(solved[fixed]?.width ?? .nan, 200, accuracy: eps, "fixed band keeps its requested points")
        XCTAssertEqual(solved[flex]?.width ?? .nan, 800, accuracy: eps, "flex fills the remainder")
        XCTAssertEqual(solved[fixed]?.maxX ?? .nan, solved[flex]?.minX ?? .nan, accuracy: eps, "abutting, no gap")
    }

    func testSolvedRectsFeedFocusResolver() {
        // The solver output is exactly the SolvedLayout FocusResolver consumes — moving right from the
        // left column lands on the right column.
        let left = PaneID(), right = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(left)),
            WeightedChild(weight: .flex(1), node: .leaf(right)),
        ])
        let solved = SplitLayoutSolver.solve(root, in: CGRect(x: 0, y: 0, width: 800, height: 400))
        let layout = SolvedLayout(frames: solved)
        XCTAssertEqual(FocusResolver.neighbor(of: left, .right, in: layout), right)
        XCTAssertEqual(FocusResolver.neighbor(of: right, .left, in: layout), left)
    }
}
