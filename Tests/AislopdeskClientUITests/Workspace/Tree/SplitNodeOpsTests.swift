import Foundation
import XCTest
@testable import AislopdeskClientUI

/// The pure ``SplitNode`` operation layer (W2, docs/42 §"Pure ops" — `SplitNode+Ops.swift`): split a
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
