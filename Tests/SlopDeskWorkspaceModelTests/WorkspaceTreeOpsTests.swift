import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// Pure split-tree + Session/Tab/`TreeWorkspace` operations (W2, docs/42 Phase C1).
///
/// These pin the W2 contract the store cutover (W4) will lean on: split materializes the right tree and
/// preserves the **specs == leafIDs invariant**; close cascades pane → tab → session and rebalances;
/// `allPaneIDs()` DFS matches the spec keys after EVERY op; zoom is out-of-tree (tree unchanged); resize
/// shifts weight between adjacent siblings with clamp and is sum-preserving; the focus pick after a close
/// is geometrically sane. Each test asserts a value that cannot exist before the W2 types/ops do
/// (revert-to-confirm-fail = the type/op is absent → compile failure).
final class WorkspaceTreeOpsTests: XCTestCase {
    // MARK: Fixtures

    private func termSpec(_ title: String = "Terminal") -> PaneSpec {
        PaneSpec(kind: .terminal, title: title)
    }

    /// A `TreeWorkspace` with one session, one tab, one leaf — the fresh-launch shape.
    private func singleLeaf() -> (TreeWorkspace, PaneID) {
        let ws = TreeWorkspace.singlePane(spec: termSpec())
        let id = ws.allPaneIDs()[0]
        return (ws, id)
    }

    // MARK: The shape-building ops, run the way production runs them

    //
    // A split, a new tab, a new session and a zoom are INTENTS — the client asks, and
    // `slopdesk_wire::document::apply` behind the FFI door decides. Their Swift twins were deleted
    // on 2026-08-17 with the rest of the applier, so what builds a fixture here is the same call the
    // ⌘D that produced it would make. That is strictly better than a private tree edit: a fixture
    // that could not be reached by any gesture is a fixture testing a shape the product cannot hold.
    //
    // The signatures deliberately match the ops they replace, so the tests below read unchanged.

    private func applied(
        _ op: WorkspaceIntentOp,
        _ args: Data,
        _ ws: TreeWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> TreeWorkspace {
        let outcome = WorkspaceIntentApplier.apply(
            op: op.rawValue, args: args, to: WorkspaceTopology(tree: ws), documentIsPristine: true,
        )
        guard let next = outcome.topology else {
            XCTFail("the \(op) fixture was refused: \(outcome)", file: file, line: line)
            return ws
        }
        return next.tree
    }

    /// Writes a minted pane's fixture spec. The op gives every new pane a plain terminal, and the
    /// TITLE is what these fixtures name their panes by — so it is written here rather than asked
    /// for, because a `renamePane` would also set the authored bit and change the subject.
    private func titling(_ ws: inout TreeWorkspace, _ pane: PaneID, _ spec: PaneSpec) {
        guard let index = ws.sessions.firstIndex(where: { $0.specs[pane] != nil }) else { return }
        ws.sessions[index].specs[pane] = spec
    }

    private func splitPane(
        _ target: PaneID,
        axis: SplitAxis,
        newSpec: PaneSpec,
        before: Bool = false,
        in ws: TreeWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> (TreeWorkspace, PaneID) {
        let minted = PaneID()
        var next = applied(
            .splitPane,
            WorkspaceIntentArgs.encode(
                target: target.raw, axis: axis, before: before, newPane: minted, spawnCwd: nil,
            ),
            ws, file: file, line: line,
        )
        titling(&next, minted, newSpec)
        return (next, minted)
    }

    private func newTab(
        in ws: TreeWorkspace,
        spec: PaneSpec,
        at position: NewTabPosition = .end,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> (TreeWorkspace, PaneID) {
        guard let session = ws.activeSessionID else { return (ws, PaneID()) }
        let minted = PaneID()
        var next = applied(
            .spawnTab,
            WorkspaceIntentArgs.encode(
                session: session, newPane: minted, position: position, spawnCwd: nil,
            ),
            ws, file: file, line: line,
        )
        titling(&next, minted, spec)
        return (next, minted)
    }

    private func newSession(
        in ws: TreeWorkspace,
        name: String,
        spec: PaneSpec,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> (TreeWorkspace, PaneID) {
        let minted = PaneID()
        var next = applied(
            .newSession,
            WorkspaceIntentArgs.encode(
                newSession: SessionID(), newPane: minted, name: name, spawnCwd: nil,
            ),
            ws, file: file, line: line,
        )
        titling(&next, minted, spec)
        return (next, minted)
    }

    private func setZoom(
        _ pane: PaneID,
        _ zoomed: Bool,
        in ws: TreeWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> TreeWorkspace {
        applied(.setZoom, WorkspaceIntentArgs.encode(id: pane.raw, flag: zoomed), ws, file: file, line: line)
    }

    /// Asserts the load-bearing invariant: the active session's spec keys are EXACTLY the set of leaf ids
    /// across every tab of that session, and globally every leaf has a resolvable spec.
    private func assertInvariant(
        _ ws: TreeWorkspace,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for session in ws.sessions {
            let leafIDs = Set(session.tabs.flatMap { $0.root.allPaneIDs() })
            XCTAssertEqual(
                Set(session.specs.keys), leafIDs,
                "specs == leafIDs invariant broken for session \(session.id) \(message)",
                file: file, line: line,
            )
        }
        for id in ws.allPaneIDs() {
            XCTAssertNotNil(ws.spec(for: id), "every leaf must have a spec \(message)", file: file, line: line)
        }
    }

    // MARK: Construction + facade

    func testSinglePaneStartsWithOneLeafAndMatchingSpec() {
        let (ws, id) = singleLeaf()
        XCTAssertEqual(ws.allPaneIDs(), [id])
        XCTAssertEqual(ws.spec(for: id)?.kind, .terminal)
        XCTAssertEqual(ws.sessions.count, 1)
        XCTAssertEqual(ws.sessions[0].tabs.count, 1)
        XCTAssertEqual(ws.activeSessionID, ws.sessions[0].id)
        assertInvariant(ws)
    }

    // MARK: Split

    // MARK: Close — collapse + rebalance

    func testClosePaneCollapsesSingleChildParentAndRebalances() {
        // a|b|c equal; close b → a|c, weights renormalize to equal (sum-preserve over survivors).
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2)
        XCTAssertEqual(s3.allPaneIDs(), [a, c], "b removed; a and c survive")
        XCTAssertNil(s3.spec(for: b), "spec for the closed pane is dropped")
        assertInvariant(s3)
    }

    func testClosePaneCollapsesTwoChildSplitIntoSurvivor() throws {
        // a|b; close a → the split collapses into just b (a single leaf, no orphan split node).
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = WorkspaceTreeOps.closePane(a, in: s1)
        let root = try activeRoot(s2)
        XCTAssertEqual(root, .leaf(b), "a 2-child split collapses to the lone survivor leaf")
        assertInvariant(s2)
    }

    func testCloseLastPaneInTabClosesTheTab() throws {
        // Session with two tabs; close the only pane of tab 0 → tab 0 disappears, tab 1 survives.
        let (ws, _) = singleLeaf()
        let (s1, _) = newTab(in: ws, spec: termSpec("t2"))
        // s1 active tab is the new one (index 1). Close its lone pane.
        let secondTabPane = try XCTUnwrap(s1.activeSession?.tabs[1].root.allPaneIDs().first)
        XCTAssertEqual(s1.sessions[0].tabs.count, 2)
        let s2 = WorkspaceTreeOps.closePane(secondTabPane, in: s1)
        XCTAssertEqual(s2.sessions[0].tabs.count, 1, "closing a tab's last pane closes the tab")
        assertInvariant(s2)
    }

    func testCloseLastPaneOfLastTabClosesTheSessionWhenAnotherSessionExists() {
        // Two sessions; close the lone pane of session 2 → session 2 is removed entirely.
        let (ws, _) = singleLeaf()
        let (s1, d) = newSession(in: ws, name: "s2", spec: termSpec("d"))
        XCTAssertEqual(s1.sessions.count, 2)
        let s2 = WorkspaceTreeOps.closePane(d, in: s1)
        XCTAssertEqual(s2.sessions.count, 1, "closing the last pane of the last tab closes the session")
        assertInvariant(s2)
    }

    func testCloseLastPaneOfOnlySessionKeepsAFreshDefaultPane() {
        // The whole workspace can never be empty: closing the very last pane re-seeds a default leaf.
        let (ws, a) = singleLeaf()
        let s1 = WorkspaceTreeOps.closePane(a, in: ws)
        XCTAssertEqual(s1.sessions.count, 1, "the only session is preserved")
        XCTAssertEqual(s1.allPaneIDs().count, 1, "a fresh default pane re-seeds the empty workspace")
        XCTAssertNotEqual(s1.allPaneIDs()[0], a, "the re-seeded pane is a new identity")
        assertInvariant(s1)
    }

    func testCloseActivePanePicksASaneNeighbourFocus() throws {
        // a|b|c (horizontal columns) with b focused; close b. The neighbour resolver tries directions in
        // [.left, .right, .up, .down] order against the SOLVED layout, so the FIRST hit (left of b) wins:
        // focus lands DETERMINISTICALLY on `a` (the left column), never `c` and never a ghost. Pinning the
        // exact survivor (not merely "a or c") makes this fail if the neighbour pick regresses (e.g. flips
        // to the right, or falls through to the first leaf).
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        // b is active (split focuses the new pane = c, then we split again; re-focus b explicitly).
        let s2b = WorkspaceTreeOps.focusPane(b, in: s2)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2b)
        let focus = try XCTUnwrap(activeTab(s3).activePane)
        XCTAssertEqual(focus, a, "focus moves to the LEFT neighbour (a), the first cardinal-direction hit")
        XCTAssertNotEqual(focus, c, "the right column is not chosen — left is tried first")
        XCTAssertTrue(s3.allPaneIDs().contains(focus), "the chosen focus is a surviving pane")
    }

    // MARK: Zoom — out of tree

    func testClosingZoomedPaneClearsZoom() throws {
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = setZoom(b, true, in: s1)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2)
        XCTAssertNil(try activeTab(s3).zoomedPane, "closing the zoomed pane clears the dangling zoom")
        assertInvariant(s3)
    }

    // MARK: Resize — sum-preserving, clamped

    func testResizeDividerShiftsWeightBetweenAdjacentSiblingsSumPreserved() throws {
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(splitID, _, before) = try activeRoot(s1) else {
            XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)
        let s2 = WorkspaceTreeOps.resizeDivider(splitID: splitID, leadingChildIndex: 0, delta: 0.3, in: s1)
        guard case let .split(_, _, after) = try activeRoot(s2) else {
            XCTFail("expected split")
            return
        }
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "weight shift is sum-preserving")
        XCTAssertGreaterThan(weight(after[0]), weight(before[0]), "the leading child grew")
        XCTAssertLessThan(weight(after[1]), weight(before[1]), "the trailing child shrank")
    }

    func testResizeDividerClampsAtMinWeight() throws {
        // A huge negative delta cannot starve the leading child below minWeight.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(splitID, _, before) = try activeRoot(s1) else {
            XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)
        let s2 = WorkspaceTreeOps.resizeDivider(splitID: splitID, leadingChildIndex: 0, delta: -100, in: s1)
        guard case let .split(_, _, after) = try activeRoot(s2) else {
            XCTFail("expected split")
            return
        }
        XCTAssertGreaterThanOrEqual(weight(after[0]), SplitWeight.minWeight, "leading child clamped at floor")
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "clamp still sum-preserves")
    }

    // MARK: Tabs / sessions cascade housekeeping

    // MARK: Break pane to a new tab

    // MARK: Move a leaf ACROSS tabs (the rail-drag MOVE of an already-streamed pane, docs/45)

    // MARK: moveFocus facade (directional + cycle)

    func testMoveFocusDirectionalResolvesGeometricNeighbour() throws {
        // a|b horizontal columns, a focused. Move focus right against a real bounds rect → lands on b
        // (the right column); move left from b → back to a.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let withA = WorkspaceTreeOps.focusPane(a, in: s1)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)

        let movedRight = WorkspaceTreeOps.moveFocus(.right, bounds: bounds, in: withA)
        XCTAssertEqual(try activeTab(movedRight).activePane, b, "move-right from the left column lands on the right")

        let movedBack = WorkspaceTreeOps.moveFocus(.left, bounds: bounds, in: movedRight)
        XCTAssertEqual(try activeTab(movedBack).activePane, a, "move-left from the right column returns to the left")
    }

    func testMoveFocusDirectionalIsNoOpAtAnEdge() {
        // a|b horizontal, a focused; move LEFT → no neighbour to the left → workspace unchanged (no-op).
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let withA = WorkspaceTreeOps.focusPane(a, in: s1)
        let moved = WorkspaceTreeOps.moveFocus(.left, bounds: CGRect(x: 0, y: 0, width: 800, height: 400), in: withA)
        XCTAssertEqual(moved, withA, "moving past the left edge is a no-op (no neighbour)")
    }

    func testMoveFocusCycleAdvancesAndWrapsThroughLeaves() throws {
        // a|b|c (pre-order [a,b,c]); .next from a → b, from c wraps → a; .previous from a wraps → c.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 400)

        let fromA = WorkspaceTreeOps.focusPane(a, in: s2)
        let next1 = WorkspaceTreeOps.moveFocus(.next, bounds: bounds, in: fromA)
        XCTAssertEqual(try activeTab(next1).activePane, b, ".next from a → b")

        let fromC = WorkspaceTreeOps.focusPane(c, in: s2)
        let wrapped = WorkspaceTreeOps.moveFocus(.next, bounds: bounds, in: fromC)
        XCTAssertEqual(try activeTab(wrapped).activePane, a, ".next from the last leaf wraps to the first")

        let prevWrap = WorkspaceTreeOps.moveFocus(.previous, bounds: bounds, in: fromA)
        XCTAssertEqual(try activeTab(prevWrap).activePane, c, ".previous from the first leaf wraps to the last")
    }

    func testMoveFocusIsNoOpForASinglePane() throws {
        // A single-pane tab: any directional move has no neighbour → unchanged; .next/.previous cycle to
        // the same lone leaf, so the active pane stays a (no crash, sane).
        let (ws, a) = singleLeaf()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        for dir in [FocusDirection.left, .right, .up, .down] {
            let moved = WorkspaceTreeOps.moveFocus(dir, bounds: bounds, in: ws)
            XCTAssertEqual(moved, ws, "a single pane has no \(dir) neighbour → no-op")
        }
        let cycled = WorkspaceTreeOps.moveFocus(.next, bounds: bounds, in: ws)
        XCTAssertEqual(try activeTab(cycled).activePane, a, ".next over a single leaf cycles back to itself")
    }

    // MARK: Move / swap

    func testSwapPanesExchangesTwoLeaves() throws {
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = WorkspaceTreeOps.swapPanes(a, b, in: s1)
        XCTAssertEqual(
            try XCTUnwrap(s2.activeSession?.tabs[0].root.allPaneIDs()),
            [b, a],
            "the two leaves swapped position",
        )
        assertInvariant(s2)
    }

    // MARK: Move pane in direction (zellij "move pane")

    func testMovePaneInDirectionSwapsWithRightNeighbour() throws {
        // a|b horizontal, a active. Move a RIGHT → swaps with b → leaf order [b, a]; a stays active.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let withA = WorkspaceTreeOps.focusPane(a, in: s1)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)

        let moved = WorkspaceTreeOps.movePaneInDirection(a, .right, bounds: bounds, in: withA)
        XCTAssertEqual(
            try XCTUnwrap(moved.activeSession?.tabs[0].root.allPaneIDs()), [b, a],
            "moving a right exchanges it with the right neighbour b",
        )
        XCTAssertEqual(try activeTab(moved).activePane, a, "the moved pane stays active (PaneID identity preserved)")
        assertInvariant(moved)
    }

    func testMovePaneInDirectionIsNoOpWithoutANeighbour() {
        // a|b horizontal; move a LEFT → no left neighbour → unchanged.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let withA = WorkspaceTreeOps.focusPane(a, in: s1)
        let moved = WorkspaceTreeOps.movePaneInDirection(
            a, .left, bounds: CGRect(x: 0, y: 0, width: 800, height: 400), in: withA,
        )
        XCTAssertEqual(moved, withA, "no neighbour on the requested side → no-op")
    }

    func testMovePaneInDirectionPicksGeometricNeighbourInNestedTree() throws {
        // a | (b over c): root horizontal [a, vertical[b, c]]. Move b DOWN → swaps with c (its vertical
        // neighbour), NOT a. Proves the move resolves against solved geometry, not tree order.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .vertical, newSpec: termSpec("c"), in: s1)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        let moved = WorkspaceTreeOps.movePaneInDirection(b, .down, bounds: bounds, in: s2)
        // After swapping b and c the leaf order becomes [a, c, b] (the right column is now c over b).
        XCTAssertEqual(
            try XCTUnwrap(moved.activeSession?.tabs[0].root.allPaneIDs()), [a, c, b],
            "b moves down by swapping with its vertical neighbour c",
        )
        XCTAssertNotEqual(
            try XCTUnwrap(moved.activeSession?.tabs[0].root.allPaneIDs()), [c, b, a],
            "the move must not touch a (the horizontal neighbour)",
        )
        assertInvariant(moved)
    }

    // MARK: Enclosing-split query (nearest ancestor split on an axis)

    func testEnclosingSplitIsNilForASoleLeaf() throws {
        let (ws, a) = singleLeaf()
        let root = try activeRoot(ws)
        XCTAssertNil(root.enclosingSplit(of: a, axis: .horizontal), "a sole leaf has no enclosing split")
        XCTAssertNil(root.enclosingSplit(of: a, axis: .vertical))
    }

    // MARK: Resize active pane (keyboard divider nudge)

    func testResizeActivePaneGrowsWidthSumPreserved() throws {
        // a|b horizontal, resize a to the RIGHT (grow) → leading divider shifts so a grows, sum preserved.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(_, _, before) = try activeRoot(s1) else { XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)

        let s2 = WorkspaceTreeOps.resizeActivePane(a, .right, step: 0.2, in: s1)
        guard case let .split(_, _, after) = try activeRoot(s2) else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "resize is sum-preserving")
        XCTAssertGreaterThan(weight(after[0]), weight(before[0]), "growing right widens the active (leading) pane")
        XCTAssertLessThan(weight(after[1]), weight(before[1]), "the right sibling shrinks")
        assertInvariant(s2)
    }

    func testResizeActivePaneGrowOnLastChildShiftsThePriorDivider() throws {
        // a|b horizontal, b active (the LAST child). Grow b right → there is no divider to b's right, so the
        // i-1 divider must shift so the trailing child (b) grows and a shrinks.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(_, _, before) = try activeRoot(s1) else { XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)

        let s2 = WorkspaceTreeOps.resizeActivePane(b, .right, step: 0.2, in: s1)
        guard case let .split(_, _, after) = try activeRoot(s2) else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "sum preserved on the last-child path")
        XCTAssertGreaterThan(weight(after[1]), weight(before[1]), "growing the last child widens b")
        XCTAssertLessThan(weight(after[0]), weight(before[0]), "its left sibling a shrinks")
        _ = a
        assertInvariant(s2)
    }

    func testResizeActivePaneTargetsTheCorrectEnclosingSplitForAxis() throws {
        // a | (b over c). Resize b for WIDTH (.right) must hit the ROOT horizontal split (b's column grows);
        // resize b for HEIGHT (.down) must hit the INNER vertical split (b's row grows). Pin via which
        // weights move.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .vertical, newSpec: termSpec("c"), in: s1)

        // WIDTH grow: the root horizontal split's children [a, inner] change; the inner vertical [b,c] stays.
        let wide = WorkspaceTreeOps.resizeActivePane(b, .right, step: 0.2, in: s2)
        guard case let .split(_, .horizontal, rootChildren) = try activeRoot(wide) else {
            XCTFail("root stays horizontal")
            return
        }
        // b's column is child index 1 (the inner split); growing right means index 1 grew. The root started
        // with EQUAL children, so the grown one must now exceed its sibling — pin the real growth, not a
        // tautology.
        XCTAssertGreaterThan(weight(rootChildren[1]), weight(rootChildren[0]), "b's column grew past a for width")
        guard case let .split(_, .vertical, innerWide) = rootChildren[1].node else { XCTFail("inner vertical")
            return
        }
        XCTAssertEqual(weight(innerWide[0]), weight(innerWide[1]), accuracy: 1e-9, "inner vertical untouched by width")

        // HEIGHT grow: the INNER vertical [b,c] weights change (b grows); root horizontal stays equal.
        let tall = WorkspaceTreeOps.resizeActivePane(b, .down, step: 0.2, in: s2)
        guard case let .split(_, .horizontal, rootTall) = try activeRoot(tall) else { XCTFail("root horizontal")
            return
        }
        XCTAssertEqual(weight(rootTall[0]), weight(rootTall[1]), accuracy: 1e-9, "root horizontal untouched by height")
        guard case let .split(_, .vertical, innerTall) = rootTall[1].node else { XCTFail("inner vertical")
            return
        }
        XCTAssertGreaterThan(weight(innerTall[0]), weight(innerTall[1]), "growing down widens b's row (first child)")
        _ = (a, c)
        assertInvariant(tall)
    }

    func testResizeActivePaneIsNoOpForASoleLeaf() {
        // No enclosing split → nothing to resize → unchanged.
        let (ws, a) = singleLeaf()
        let after = WorkspaceTreeOps.resizeActivePane(a, .right, step: 0.2, in: ws)
        XCTAssertEqual(after, ws, "a sole-leaf tab has no split to resize → no-op")
    }

    func testResizeActivePaneClampsAtMinWeight() throws {
        // A huge shrink can't starve the active pane below minWeight.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(_, _, before) = try activeRoot(s1) else { XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)
        let s2 = WorkspaceTreeOps.resizeActivePane(a, .left, step: 100, in: s1) // huge shrink
        guard case let .split(_, _, after) = try activeRoot(s2) else { XCTFail("expected split")
            return
        }
        XCTAssertGreaterThanOrEqual(weight(after[0]), SplitWeight.minWeight, "active clamped at the floor")
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "clamp still sum-preserves")
    }

    func testResizeActivePaneShrinksWidthLeft() throws {
        // a|b horizontal, a active. A small .left nudge must SHRINK a and GROW b (the grow/shrink SIGN is
        // pinned positively, not just at the clamp floor). Fails if .left were mapped to grow.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        guard case let .split(_, _, before) = try activeRoot(s1) else { XCTFail("expected split")
            return
        }
        let sumBefore = flexSum(before)

        let s2 = WorkspaceTreeOps.resizeActivePane(a, .left, step: 0.2, in: s1)
        guard case let .split(_, _, after) = try activeRoot(s2) else { XCTFail("expected split")
            return
        }
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "shrink is sum-preserving")
        XCTAssertLessThan(weight(after[0]), weight(before[0]), "shrinking left narrows the active (leading) pane")
        XCTAssertGreaterThan(weight(after[1]), weight(before[1]), "the right sibling grows")
        assertInvariant(s2)
    }

    func testResizeActivePaneShrinksHeightUp() throws {
        // a over b vertical, a active (the FIRST child). A small .up nudge must SHRINK a and GROW b. Pins the
        // .up (vertical, shrink) mapping — which is otherwise never exercised by resize. Fails if .up grows.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .vertical, newSpec: termSpec("b"), in: ws)
        guard case let .split(_, .vertical, before) = try activeRoot(s1) else { XCTFail("expected vertical split")
            return
        }
        let sumBefore = flexSum(before)

        let s2 = WorkspaceTreeOps.resizeActivePane(a, .up, step: 0.2, in: s1)
        guard case let .split(_, .vertical, after) = try activeRoot(s2) else { XCTFail("expected vertical split")
            return
        }
        XCTAssertEqual(flexSum(after), sumBefore, accuracy: 1e-9, "shrink is sum-preserving")
        XCTAssertLessThan(weight(after[0]), weight(before[0]), "shrinking up shortens the active (top) pane")
        XCTAssertGreaterThan(weight(after[1]), weight(before[1]), "the bottom sibling grows")
        assertInvariant(s2)
    }

    func testResizeActivePaneMutatesTheLocatedTabNotTheActiveTab() throws {
        // a|b in tab 0, then open tab 1 (which becomes active). Resizing a pane that lives in the NON-active
        // tab 0 must still land — the nudge targets the LOCATED tab, not whatever tab is active. Guards the
        // latent coupling where routing through the active-tab-scoped resizeDivider would silently no-op.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, _) = newTab(in: s1, spec: termSpec("c")) // tab 1 is now active
        XCTAssertEqual(s2.activeSession?.activeTabIndex, 1, "the freshly opened tab is active")

        // a lives in tab 0; resize it RIGHT (grow).
        let (sIdx, tIdx) = try XCTUnwrap(WorkspaceTreeOps.locate(a, in: s2))
        guard case let .split(_, _, before) = s2.sessions[sIdx].tabs[tIdx].root else { XCTFail("expected split")
            return
        }
        let resized = WorkspaceTreeOps.resizeActivePane(a, .right, step: 0.2, in: s2)
        guard case let .split(_, _, after) = resized.sessions[sIdx].tabs[tIdx].root else { XCTFail("expected split")
            return
        }
        XCTAssertGreaterThan(weight(after[0]), weight(before[0]), "the located (non-active) tab's pane actually grew")
        XCTAssertNotEqual(resized, s2, "resizing a pane in a non-active tab is NOT a silent no-op")
        assertInvariant(resized)
    }

    func testResizeActivePaneIsNoOpForCycleDirections() {
        // .next/.previous have no divider-nudge meaning → resizeActivePane returns the workspace unchanged.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        XCTAssertEqual(
            WorkspaceTreeOps.resizeActivePane(a, .next, step: 0.2, in: s1), s1, "resize .next is a no-op",
        )
        XCTAssertEqual(
            WorkspaceTreeOps.resizeActivePane(a, .previous, step: 0.2, in: s1), s1, "resize .previous is a no-op",
        )
    }

    func testMovePaneInDirectionIsNoOpForCycleDirections() {
        // .next/.previous have no directional-swap meaning → movePaneInDirection returns ws unchanged.
        let (ws, a) = singleLeaf()
        let (s1, _) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertEqual(
            WorkspaceTreeOps.movePaneInDirection(a, .next, bounds: bounds, in: s1), s1, "move .next is a no-op",
        )
        XCTAssertEqual(
            WorkspaceTreeOps.movePaneInDirection(a, .previous, bounds: bounds, in: s1), s1, "move .previous is a no-op",
        )
    }

    // MARK: Balance splits (tmux even-layout)

    func testRebalancedEqualizesFlexChildren() {
        // A 2-col split with weights 3/1 → equal after rebalance; sum preserved.
        let id = SplitNodeID()
        let a = PaneID(), b = PaneID()
        let node = SplitNode.split(id: id, axis: .horizontal, children: [
            WeightedChild(weight: .flex(3), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        guard case let .split(_, _, children) = node.rebalanced() else { XCTFail("expected split")
            return
        }
        guard case let .flex(w0) = children[0].weight, case let .flex(w1) = children[1].weight else {
            XCTFail("flex weights")
            return
        }
        XCTAssertEqual(w0, w1, accuracy: 1e-9, "rebalance equalizes the two flex children")
        XCTAssertEqual(node.rebalanced().allPaneIDs(), node.allPaneIDs(), "leaf set + order unchanged")
    }

    func testRebalancedEqualizesNestedSplitsAndKeepsFixed() {
        // root horizontal[ fixed(200) leaf, flex(5) leaf, vertical[ flex(9), flex(1) ] ].
        // Rebalance: the two root flex children equalize; the .fixed child keeps 200; the nested vertical
        // equalizes too; tree shape + leaf set unchanged.
        let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()
        let inner = SplitNode.split(id: SplitNodeID(), axis: .vertical, children: [
            WeightedChild(weight: .flex(9), node: .leaf(c)),
            WeightedChild(weight: .flex(1), node: .leaf(d)),
        ])
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .fixed(200), node: .leaf(a)),
            WeightedChild(weight: .flex(5), node: .leaf(b)),
            WeightedChild(weight: .flex(1), node: inner),
        ])
        let balanced = root.rebalanced()
        guard case let .split(_, .horizontal, rc) = balanced else { XCTFail("root split")
            return
        }
        guard case let .fixed(p) = rc[0].weight else { XCTFail("first stays fixed")
            return
        }
        XCTAssertEqual(p, 200, accuracy: 1e-9, ".fixed child keeps its points")
        guard case let .flex(rb1) = rc[1].weight, case let .flex(rb2) = rc[2].weight else {
            XCTFail("flex")
            return
        }
        XCTAssertEqual(rb1, rb2, accuracy: 1e-9, "root flex children equalized (fixed excluded)")
        guard case let .split(_, .vertical, ic) = rc[2].node else { XCTFail("inner vertical survives")
            return
        }
        guard case let .flex(iv0) = ic[0].weight, case let .flex(iv1) = ic[1].weight else { XCTFail("flex")
            return
        }
        XCTAssertEqual(iv0, iv1, accuracy: 1e-9, "nested vertical split equalized too")
        XCTAssertEqual(Set(balanced.allPaneIDs()), Set([a, b, c, d]), "leaf set unchanged")
        XCTAssertEqual(balanced.allPaneIDs(), root.allPaneIDs(), "tree shape / order unchanged")
    }

    func testBalanceSplitsEqualizesTheActiveTabAndPreservesInvariant() throws {
        // a|b|c horizontal then nudge a divider off-balance; balanceSplits resets to equal.
        let (ws, a) = singleLeaf()
        let (s1, b) = splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        guard case let .split(splitID, _, _) = try activeRoot(s2) else { XCTFail("expected split")
            return
        }
        let nudged = WorkspaceTreeOps.resizeDivider(splitID: splitID, leadingChildIndex: 0, delta: 0.4, in: s2)

        let balanced = WorkspaceTreeOps.balanceSplits(activeTabContaining: a, in: nudged)
        guard case let .split(_, _, children) = try activeRoot(balanced) else { XCTFail("expected split")
            return
        }
        let weights = children.compactMap { child -> Double? in
            if case let .flex(w) = child.weight { return w }
            return nil
        }
        XCTAssertEqual(weights.count, 3)
        XCTAssertEqual(weights[0], weights[1], accuracy: 1e-9, "balance equalizes all siblings")
        XCTAssertEqual(weights[1], weights[2], accuracy: 1e-9)
        XCTAssertEqual(balanced.allPaneIDs(), [a, b, c], "leaf set + order unchanged by balance")
        _ = c
        assertInvariant(balanced)
    }

    // MARK: updatingSpec mutates the side table, not the tree

    // MARK: normalizing repairs

    func testNormalizingDropsOrphanSpecsAndReseedsMissing() {
        // Hand-corrupt: an extra spec for a pane not in the tree (orphan) + a leaf whose spec is missing.
        var (ws, a) = singleLeaf()
        var session = ws.sessions[0]
        let orphan = PaneID()
        session.specs[orphan] = termSpec("orphan")
        session.specs.removeValue(forKey: a) // leaf a now has no spec
        ws.sessions[0] = session
        let fixed = ws.normalizingSpecs()
        XCTAssertNil(fixed.sessions[0].specs[orphan], "orphan spec (no leaf) is dropped")
        XCTAssertNotNil(fixed.spec(for: a), "a leaf with a missing spec gets a default re-seeded")
        assertInvariant(fixed)
    }

    func testNormalizingActiveRepairsDanglingSelections() throws {
        var (ws, _) = singleLeaf()
        ws.activeSessionID = SessionID() // dangling
        ws.sessions[0].activeTabIndex = 99 // out of range
        ws.sessions[0].tabs[0].activePane = PaneID() // ghost
        let fixed = ws.normalizingActive()
        XCTAssertEqual(fixed.activeSessionID, fixed.sessions[0].id, "dangling active session repaired")
        XCTAssertTrue(
            fixed.sessions[0].tabs.indices.contains(fixed.sessions[0].activeTabIndex),
            "active tab index clamped into range",
        )
        let leafIDs = Set(fixed.sessions[0].tabs[fixed.sessions[0].activeTabIndex].root.allPaneIDs())
        let active = fixed.sessions[0].tabs[fixed.sessions[0].activeTabIndex].activePane
        XCTAssertTrue(try active == nil || leafIDs.contains(XCTUnwrap(active)), "ghost active pane repaired")
    }

    // MARK: Codable round-trip (matches W1 Domain style: Sendable/Equatable/Codable)

    // MARK: Helpers

    /// The active session's active tab (unwrapped) — the common accessor the ops assertions read.
    private func activeTab(_ ws: TreeWorkspace, file: StaticString = #filePath, line: UInt = #line) throws -> Tab {
        let session = try XCTUnwrap(ws.activeSession, "no active session", file: file, line: line)
        return try XCTUnwrap(session.activeTab, "no active tab", file: file, line: line)
    }

    /// The active tab's root tree.
    private func activeRoot(_ ws: TreeWorkspace, file: StaticString = #filePath, line: UInt = #line) throws
        -> SplitNode
    {
        try activeTab(ws, file: file, line: line).root
    }

    private func flexSum(_ children: [WeightedChild]) -> Double {
        children.reduce(0.0) { acc, child in
            if case let .flex(w) = child.weight { return acc + w }
            return acc
        }
    }

    private func weight(_ child: WeightedChild) -> Double {
        if case let .flex(w) = child.weight { return w }
        return 0
    }
}
