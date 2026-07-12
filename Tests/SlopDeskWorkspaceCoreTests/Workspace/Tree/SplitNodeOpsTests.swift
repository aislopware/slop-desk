import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure ``SplitNode`` operation layer (docs/42 §"Pure ops" — `SplitNode+Ops.swift`): split a
/// leaf, remove a leaf (collapse + rebalance), resize a divider (sum-preserve + clamp), swap. These pin
/// the tree algebra directly, independent of the ``WorkspaceTreeOps`` facade, so a regression in the
/// recursion is caught at its source. Each asserts a real structural/numeric outcome (no tautology).
final class SplitNodeOpsTests: XCTestCase {
    private func flexWeights(_ node: SplitNode) -> [Double] {
        guard case let .split(_, _, children) = node else { return [] }
        return children.map { if case let .flex(w) = $0.weight { return w }
            return .nan
        }
    }

    // MARK: Split

    func testSplittingALeafProducesTwoChildSplit() {
        let a = PaneID(), b = PaneID()
        let split = SplitNode.leaf(a).splitting(a, axis: .vertical, inserting: b)
        guard case let .split(_, axis, children) = split else { XCTFail("expected a split")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(split?.allPaneIDs(), [a, b])
    }

    func testSplittingAbsentLeafReturnsNil() {
        let a = PaneID(), b = PaneID(), ghost = PaneID()
        XCTAssertNil(
            SplitNode.leaf(a).splitting(ghost, axis: .horizontal, inserting: b),
            "splitting a leaf not in the tree is a no-op (nil)",
        )
    }

    func testMatchingAxisSplitInsertsSibling() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let three = two.splitting(b, axis: .horizontal, inserting: c)
        guard case let .split(_, _, children) = three else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(children.count, 3, "same-axis split inserts a 3rd sibling, no nesting")
        XCTAssertEqual(three?.allPaneIDs(), [a, b, c])
    }

    func testCrossAxisSplitNestsAtTheTarget() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let nested = two.splitting(b, axis: .vertical, inserting: c)
        guard case let .split(_, _, children) = nested, children.count == 2,
              case let .split(_, innerAxis, inner) = children[1].node
        else {
            XCTFail("b's slot must become a nested vertical split")
            return
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(nested?.allPaneIDs(), [a, b, c])
    }

    // MARK: Remove

    func testRemovingLoneLeafReturnsNil() {
        let a = PaneID()
        XCTAssertNil(SplitNode.leaf(a).removing(a), "removing the only leaf empties the tree → nil")
    }

    func testRemovingCollapsesTwoChildSplitToSurvivor() {
        let a = PaneID(), b = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.removing(a), .leaf(b), "2-child split collapses into the survivor")
    }

    func testRemovingRebalancesSurvivorsEqually() throws {
        // a:1 b:2 c:3 (uneven survivors a,c). Remove b → a,c each get an EQUAL share of the SURVIVORS'
        // conserved flex (a+c = 1+3 = 4 → 2 each): sum-preserving over the remaining siblings, equalized.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let three = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(2), node: .leaf(b)),
            .init(weight: .flex(3), node: .leaf(c)),
        ])
        let pruned = three.removing(b)
        XCTAssertEqual(pruned?.allPaneIDs(), [a, c])
        let weights = try flexWeights(XCTUnwrap(pruned))
        XCTAssertEqual(weights.reduce(0, +), 4, accuracy: 1e-9, "the survivors' total flex is conserved")
        XCTAssertEqual(weights[0], weights[1], accuracy: 1e-9, "survivors rebalanced to an equal share")
        XCTAssertEqual(weights[0], 2, accuracy: 1e-9)
    }

    func testRemovingFlattensSameAxisNestOnCollapse() throws {
        // V[ H[ V[a,b], c ], d ] — remove c. The inner H collapses its lone survivor V[a,b] straight up
        // under the V root; without the same-axis merge that leaves a redundant V[ V[a,b], d ] (vertical
        // nested in vertical), which skews geometry + over-counts depth. The merge splices it flat to
        // V[a,b,d]. This is the shared `removing` so closePane/breakPaneToTab gain it too.
        let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()
        func wc(_ node: SplitNode) -> WeightedChild { WeightedChild(weight: .flex(1), node: node) }
        let innerV = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [wc(.leaf(a)), wc(.leaf(b))])
        let h = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [wc(innerV), wc(.leaf(c))])
        let root = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [wc(h), wc(.leaf(d))])

        let removed = root.removing(c)

        guard case let .split(_, axis, children)? = removed else { XCTFail("expected a split")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children.count, 3, "the V[a,b] nest is flattened into the V root → 3 flat children")
        XCTAssertEqual(removed?.allPaneIDs(), [a, b, d])
        for child in children {
            if case .split(_, .vertical, _) = child.node { XCTFail("a same-axis (vertical) nest survived") }
        }
        // Flattened ⇒ a decode round-trip is a fixed point (no reshape-on-reload).
        let roundTrip = try? JSONDecoder().decode(SplitNode.self, from: try JSONEncoder().encode(XCTUnwrap(removed)))
        XCTAssertEqual(roundTrip, removed, "the flattened tree is decode-stable (no reshape on reload)")
    }

    // MARK: Resize

    func testResizeDividerShiftsAndPreservesSum() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let resized = two.resizingDivider(splitID: sid, leadingIndex: 0, delta: 0.4)
        let w = flexWeights(resized)
        XCTAssertEqual(w[0], 1.4, accuracy: 1e-9)
        XCTAssertEqual(w[1], 0.6, accuracy: 1e-9)
        XCTAssertEqual(w[0] + w[1], 2, accuracy: 1e-9, "sum preserved")
    }

    func testResizeDividerClampsBothSidesAtFloor() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let resized = two.resizingDivider(splitID: sid, leadingIndex: 0, delta: 100)
        let w = flexWeights(resized)
        XCTAssertEqual(w[0] + w[1], 2, accuracy: 1e-9, "clamp still preserves the sum")
        XCTAssertGreaterThanOrEqual(w[1], SplitWeight.minWeight, "trailing child kept at floor")
        XCTAssertLessThanOrEqual(w[0], 2 - SplitWeight.minWeight, "leading child capped so trailing keeps its floor")
    }

    // MARK: Resize — ABSOLUTE set (live drag)

    func testSetDividerWeightSetsLeadingAbsolutelyAndPreservesSum() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        // Absolute set (NOT a delta): leading becomes exactly 1.6, trailing the remainder of the pair sum.
        let w = flexWeights(two.settingDividerWeight(splitID: sid, leadingIndex: 0, leadingWeight: 1.6))
        XCTAssertEqual(w[0], 1.6, accuracy: 1e-9)
        XCTAssertEqual(w[1], 0.4, accuracy: 1e-9)
        XCTAssertEqual(w[0] + w[1], 2, accuracy: 1e-9, "sum preserved")
    }

    func testSetDividerWeightClampsBelowAndAboveTheFloor() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        // A target far below the floor pins the leading at minWeight (trailing keeps the rest) — this is the
        // over-drag-into-the-clamp case the live drag relies on (it HOLDS at the floor, no drift).
        let low = flexWeights(two.settingDividerWeight(splitID: sid, leadingIndex: 0, leadingWeight: -5))
        XCTAssertEqual(low[0], SplitWeight.minWeight, accuracy: 1e-9, "leading pinned at the floor")
        XCTAssertEqual(low[0] + low[1], 2, accuracy: 1e-9, "sum preserved at the clamp")
        // A target far above pins the TRAILING at minWeight (leading capped at pairSum - minWeight).
        let high = flexWeights(two.settingDividerWeight(splitID: sid, leadingIndex: 0, leadingWeight: 99))
        XCTAssertEqual(high[1], SplitWeight.minWeight, accuracy: 1e-9, "trailing pinned at the floor")
        XCTAssertEqual(high[0], 2 - SplitWeight.minWeight, accuracy: 1e-9, "leading capped")
    }

    func testSetDividerWeightNoOpForFixedChild() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .fixed(120), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        // A `.fixed` leading child can't be re-weighted — the tree is returned unchanged.
        XCTAssertEqual(two.settingDividerWeight(splitID: sid, leadingIndex: 0, leadingWeight: 1.5), two)
    }

    // MARK: Swap

    func testSwappingExchangesLeafPositions() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let three = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
            .init(weight: .flex(1), node: .leaf(c)),
        ])
        XCTAssertEqual(three.swapping(a, c).allPaneIDs(), [c, b, a], "a and c exchanged, b fixed")
    }

    // MARK: Insert an existing leaf beside a target (drag-to-re-split)

    func testInsertingBesideLoneTargetBeforeOrdersNewLeafFirst() {
        let s = PaneID(), t = PaneID()
        let tree = SplitNode.leaf(t).inserting(s, beside: t, axis: .vertical, before: true)
        guard case let .split(_, axis, children) = tree else { XCTFail("expected a split")
            return
        }
        XCTAssertEqual(axis, .vertical, "the bare leaf becomes a split on the requested axis")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(tree?.allPaneIDs(), [s, t], "before:true puts the inserted leaf FIRST")
    }

    func testInsertingBesideLoneTargetAfterOrdersTargetFirst() {
        let s = PaneID(), t = PaneID()
        let tree = SplitNode.leaf(t).inserting(s, beside: t, axis: .horizontal, before: false)
        XCTAssertEqual(tree?.allPaneIDs(), [t, s], "before:false puts the inserted leaf AFTER the target")
    }

    func testInsertingSameAxisInsertsPlainSiblingNoNesting() {
        // [a | b] horizontal; insert s beside b along the SAME axis, after → [a, b, s], one flat split.
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let three = two.inserting(s, beside: b, axis: .horizontal, before: false)
        guard case let .split(_, axis, children) = three else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3, "same-axis insert adds a flat sibling, never a nested split")
        XCTAssertEqual(three?.allPaneIDs(), [a, b, s])
    }

    func testInsertingSameAxisBeforeTargetSlotsAhead() {
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.inserting(s, beside: b, axis: .horizontal, before: true)?.allPaneIDs(), [a, s, b])
    }

    func testInsertingCrossAxisNestsAtTheTargetSlot() {
        // [a | b] horizontal; insert s beside b along the OTHER axis → b's slot becomes a nested vertical
        // split [s, b] (before:true), so dropping a pane on b's TOP edge stacks it above b. This delivers
        // the side-by-side-to-stacked transition the user asked for.
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let nested = two.inserting(s, beside: b, axis: .vertical, before: true)
        guard case let .split(_, outerAxis, children) = nested, children.count == 2,
              case let .split(_, innerAxis, inner) = children[1].node
        else {
            XCTFail("b's slot must become a nested vertical split")
            return
        }
        XCTAssertEqual(outerAxis, .horizontal, "the outer split keeps its axis")
        XCTAssertEqual(innerAxis, .vertical, "b's slot re-splits on the other axis")
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(nested?.allPaneIDs(), [a, s, b], "before:true stacks s above b")
    }

    func testInsertingBesideAbsentTargetIsNil() {
        let a = PaneID(), s = PaneID(), ghost = PaneID()
        XCTAssertNil(
            SplitNode.leaf(a).inserting(s, beside: ghost, axis: .vertical, before: true),
            "inserting beside a target not in the tree is a no-op (nil)",
        )
    }

    // MARK: Insert at the root edge (drag-to-dock)

    func testInsertingAtRootSameAxisAppendsOutermostFlatSibling() {
        // [a | b] horizontal; dock s to the RIGHT (axis .horizontal, before:false) → [a, b, s], flat split.
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let docked = two.insertingAtRoot(s, axis: .horizontal, before: false)
        guard case let .split(_, axis, children) = docked else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3, "same-axis root dock appends a flat sibling (no nesting)")
        XCTAssertEqual(docked.allPaneIDs(), [a, b, s])
    }

    func testInsertingAtRootSameAxisBeforePrependsOutermost() {
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.insertingAtRoot(s, axis: .horizontal, before: true).allPaneIDs(), [s, a, b])
    }

    func testInsertingAtRootCrossAxisWrapsTheWholeRoot() {
        // [a | b] horizontal; dock s to the TOP (axis .vertical, before:true) → vertical[s, (a|b)] — s is a
        // full-width top row above the preserved side-by-side pair.
        let a = PaneID(), b = PaneID(), s = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let wrapped = two.insertingAtRoot(s, axis: .vertical, before: true)
        guard case let .split(_, outer, children) = wrapped, children.count == 2,
              case let .split(_, inner, _) = children[1].node
        else {
            XCTFail("the whole root must wrap in a vertical 2-child split [s, (a|b)]")
            return
        }
        XCTAssertEqual(children[0].node, .leaf(s), "s docked as the FIRST (top) child")
        XCTAssertEqual(outer, .vertical)
        XCTAssertEqual(inner, .horizontal, "the original side-by-side split is preserved inside the wrap")
        XCTAssertEqual(wrapped.allPaneIDs(), [s, a, b])
    }

    func testInsertingAtRootBareLeafBecomesTwoChildSplit() {
        let a = PaneID(), s = PaneID()
        XCTAssertEqual(
            SplitNode.leaf(a).insertingAtRoot(s, axis: .vertical, before: false).allPaneIDs(),
            [a, s],
            "docking against a bare-leaf root wraps it in a 2-child split",
        )
    }

    // MARK: Drop-edge → axis mapping (anti-drift: the easy place to invert columns vs rows)

    func testPaneDropEdgeAxisAndSideMapping() {
        XCTAssertEqual(PaneDropEdge.left.axis, .horizontal, "left/right form COLUMNS (.horizontal)")
        XCTAssertEqual(PaneDropEdge.right.axis, .horizontal)
        XCTAssertEqual(PaneDropEdge.top.axis, .vertical, "top/bottom form ROWS (.vertical) — the dọc→ngang stack")
        XCTAssertEqual(PaneDropEdge.bottom.axis, .vertical)
        XCTAssertTrue(PaneDropEdge.left.insertsBefore, "left inserts BEFORE the target")
        XCTAssertTrue(PaneDropEdge.top.insertsBefore, "top inserts BEFORE the target")
        XCTAssertFalse(PaneDropEdge.right.insertsBefore, "right inserts AFTER")
        XCTAssertFalse(PaneDropEdge.bottom.insertsBefore, "bottom inserts AFTER")
    }

    // MARK: Adversarial inputs (must never trap; degenerate args are safe no-ops)

    func testSwappingWithSelfIsNoOp() {
        let a = PaneID(), b = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.swapping(a, a), two, "swapping a leaf with itself leaves the tree unchanged")
    }

    func testSwappingAbsentLeafIsNoOp() {
        let a = PaneID(), b = PaneID(), ghost = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.swapping(a, ghost), two, "swapping with a leaf not in the tree is a no-op")
    }

    func testResizingAbsentSplitIDIsNoOp() {
        let a = PaneID(), b = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        let resized = two.resizingDivider(splitID: SplitNodeID(), leadingIndex: 0, delta: 0.4)
        XCTAssertEqual(resized, two, "resizing a split id absent from the tree leaves it unchanged")
    }

    func testResizingOutOfRangeChildIndexIsNoOp() {
        let a = PaneID(), b = PaneID()
        let sid = SplitNodeID()
        let two = SplitNode.split(id: sid, axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        // leadingIndex past the last divider (the pair leadingIndex/leadingIndex+1 is out of range).
        XCTAssertEqual(
            two.resizingDivider(splitID: sid, leadingIndex: 5, delta: 0.4), two,
            "an out-of-range divider index is a safe no-op (weights unchanged)",
        )
        // A negative index is also safe (no trap, no change).
        XCTAssertEqual(
            two.resizingDivider(splitID: sid, leadingIndex: -1, delta: 0.4), two,
            "a negative divider index is a safe no-op",
        )
        // The last child index has no trailing sibling → no-op.
        XCTAssertEqual(
            two.resizingDivider(splitID: sid, leadingIndex: 1, delta: 0.4), two,
            "the trailing-most child has no divider after it → no-op",
        )
    }

    func testRemovingNonExistentPaneIsNoOp() {
        let a = PaneID(), b = PaneID(), ghost = PaneID()
        let two = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            .init(weight: .flex(1), node: .leaf(a)),
            .init(weight: .flex(1), node: .leaf(b)),
        ])
        XCTAssertEqual(two.removing(ghost), two, "removing a pane not in the tree returns the tree unchanged")
        // Also no-op on a lone leaf for an absent id (must NOT collapse to nil).
        XCTAssertEqual(SplitNode.leaf(a).removing(ghost), .leaf(a), "removing an absent id from a lone leaf is a no-op")
    }
}
