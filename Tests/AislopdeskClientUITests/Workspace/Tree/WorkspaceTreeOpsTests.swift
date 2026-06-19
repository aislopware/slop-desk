import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskClientUI

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

    func testAllPaneIDsIsDFSAcrossSessionsTabsAndTree() throws {
        // Two sessions; the first has two tabs; the second has a 2-leaf split. allPaneIDs must visit
        // session → tab → pre-order tree, deterministically.
        var ws = TreeWorkspace.singlePane(spec: termSpec("a"))
        let a = ws.allPaneIDs()[0]
        let (ws1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        ws = ws1
        // New tab with a single leaf c.
        let (ws2, c) = WorkspaceTreeOps.newTab(in: ws, spec: termSpec("c"))
        ws = ws2
        // New session with a single leaf d.
        let (ws3, d) = WorkspaceTreeOps.newSession(in: ws, name: "s2", spec: termSpec("d"))
        ws = ws3
        let ids = ws.allPaneIDs()
        XCTAssertEqual(Set(ids), Set([a, b, c, d]))
        // a and b come before c (same session, earlier tab); a,b,c (session 1) before d (session 2).
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: a)), try XCTUnwrap(ids.firstIndex(of: c)))
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: b)), try XCTUnwrap(ids.firstIndex(of: c)))
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: c)), try XCTUnwrap(ids.firstIndex(of: d)))
        assertInvariant(ws)
    }

    // MARK: Split

    func testSplitReplacesLeafWithTwoChildSplitWhenNewAxis() throws {
        let (ws, a) = singleLeaf()
        let (after, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let root = try activeRoot(after)
        guard case let .split(_, axis, children) = root else {
            XCTFail("split of a leaf must produce a 2-child split, got \(root)")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2, "leaf → 2-child split")
        XCTAssertEqual(root.allPaneIDs(), [a, b], "original first, new pane second")
        // Equal flex weights.
        for child in children {
            guard case let .flex(w) = child.weight else {
                XCTFail("expected flex weight")
                return
            }
            XCTAssertEqual(w, 1, accuracy: 1e-9)
        }
        XCTAssertEqual(after.spec(for: b)?.title, "b")
        assertInvariant(after)
    }

    func testSplitInsertsSiblingWhenParentAxisMatches() throws {
        // a|b (horizontal). Split b horizontally again → a|b|c as a 3-way sibling list, NOT a nested split.
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        let root = try activeRoot(s2)
        guard case let .split(_, axis, children) = root else {
            XCTFail("expected split")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3, "matching-axis split inserts a sibling — no nested intermediary")
        XCTAssertEqual(root.allPaneIDs(), [a, b, c], "c inserted directly after b")
        assertInvariant(s2)
    }

    func testSplitDifferentAxisNestsAtTheTarget() throws {
        // a|b horizontal; split b VERTICALLY → a | (b stacked over c). b's slot becomes a vertical split.
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .vertical, newSpec: termSpec("c"), in: s1)
        let root = try activeRoot(s2)
        guard case let .split(_, axis, children) = root, axis == .horizontal, children.count == 2 else {
            XCTFail("root must stay a 2-child horizontal split")
            return
        }
        guard case let .split(_, innerAxis, inner) = children[1].node else {
            XCTFail("b's slot must become a nested split")
            return
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(root.allPaneIDs(), [a, b, c])
        assertInvariant(s2)
    }

    func testSplitFocusesAndActivatesTheNewPane() throws {
        let (ws, a) = singleLeaf()
        let (after, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        XCTAssertEqual(try activeTab(after).activePane, b, "the freshly split pane takes focus")
    }

    // MARK: Close — collapse + rebalance

    func testClosePaneCollapsesSingleChildParentAndRebalances() {
        // a|b|c equal; close b → a|c, weights renormalize to equal (sum-preserve over survivors).
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2)
        XCTAssertEqual(s3.allPaneIDs(), [a, c], "b removed; a and c survive")
        XCTAssertNil(s3.spec(for: b), "spec for the closed pane is dropped")
        assertInvariant(s3)
    }

    func testClosePaneCollapsesTwoChildSplitIntoSurvivor() throws {
        // a|b; close a → the split collapses into just b (a single leaf, no orphan split node).
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = WorkspaceTreeOps.closePane(a, in: s1)
        let root = try activeRoot(s2)
        XCTAssertEqual(root, .leaf(b), "a 2-child split collapses to the lone survivor leaf")
        assertInvariant(s2)
    }

    func testCloseLastPaneInTabClosesTheTab() throws {
        // Session with two tabs; close the only pane of tab 0 → tab 0 disappears, tab 1 survives.
        let (ws, _) = singleLeaf()
        let (s1, _) = WorkspaceTreeOps.newTab(in: ws, spec: termSpec("t2"))
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
        let (s1, d) = WorkspaceTreeOps.newSession(in: ws, name: "s2", spec: termSpec("d"))
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
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        // b is active (split focuses the new pane = c, then we split again; re-focus b explicitly).
        let s2b = WorkspaceTreeOps.focusPane(b, in: s2)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2b)
        let focus = try XCTUnwrap(activeTab(s3).activePane)
        XCTAssertEqual(focus, a, "focus moves to the LEFT neighbour (a), the first cardinal-direction hit")
        XCTAssertNotEqual(focus, c, "the right column is not chosen — left is tried first")
        XCTAssertTrue(s3.allPaneIDs().contains(focus), "the chosen focus is a surviving pane")
    }

    // MARK: Zoom — out of tree

    func testToggleZoomLeavesTheTreeUnchanged() throws {
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let treeBefore = try activeRoot(s1)
        let s2 = WorkspaceTreeOps.toggleZoom(b, in: s1)
        let tab = try activeTab(s2)
        XCTAssertEqual(tab.zoomedPane, b, "zoom records the pane out-of-tree")
        XCTAssertEqual(tab.root, treeBefore, "zoom must NOT mutate the split tree")
        // Toggling the same pane clears it.
        let s3 = WorkspaceTreeOps.toggleZoom(b, in: s2)
        XCTAssertNil(try activeTab(s3).zoomedPane)
        XCTAssertEqual(try activeRoot(s3), treeBefore)
    }

    func testClosingZoomedPaneClearsZoom() throws {
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = WorkspaceTreeOps.toggleZoom(b, in: s1)
        let s3 = WorkspaceTreeOps.closePane(b, in: s2)
        XCTAssertNil(try activeTab(s3).zoomedPane, "closing the zoomed pane clears the dangling zoom")
        assertInvariant(s3)
    }

    // MARK: Resize — sum-preserving, clamped

    func testResizeDividerShiftsWeightBetweenAdjacentSiblingsSumPreserved() throws {
        let (ws, a) = singleLeaf()
        let (s1, _) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
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
        let (s1, _) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
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

    func testCloseTabSelectsAdjacentTab() throws {
        let (ws, _) = singleLeaf()
        let (s1, _) = WorkspaceTreeOps.newTab(in: ws, spec: termSpec("t2"))
        let (s2, _) = WorkspaceTreeOps.newTab(in: s1, spec: termSpec("t3"))
        // 3 tabs, active = index 2. Close it.
        let closeID = try XCTUnwrap(s2.activeSession?.tabs[2].id)
        let s3 = WorkspaceTreeOps.closeTab(closeID, in: s2)
        XCTAssertEqual(s3.activeSession?.tabs.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(s3.activeSession?.activeTabIndex),
            1,
            "active index clamps to a valid tab after close",
        )
        assertInvariant(s3)
    }

    func testCloseSessionSelectsAnother() throws {
        let (ws, _) = singleLeaf()
        let (s1, _) = WorkspaceTreeOps.newSession(in: ws, name: "s2", spec: termSpec("d"))
        let closeID = try XCTUnwrap(s1.activeSessionID)
        let s2 = WorkspaceTreeOps.closeSession(closeID, in: s1)
        XCTAssertEqual(s2.sessions.count, 1)
        XCTAssertEqual(s2.activeSessionID, s2.sessions[0].id, "active session repoints to a survivor")
        assertInvariant(s2)
    }

    func testCloseLastSessionReseedsDefault() throws {
        let (ws, _) = singleLeaf()
        let onlyID = try XCTUnwrap(ws.activeSessionID)
        let s1 = WorkspaceTreeOps.closeSession(onlyID, in: ws)
        XCTAssertEqual(s1.sessions.count, 1, "the workspace always has ≥ 1 session")
        XCTAssertEqual(s1.allPaneIDs().count, 1)
        assertInvariant(s1)
    }

    // MARK: Break pane to a new tab

    func testBreakPaneToTabMovesLeafIntoANewTabAndCollapsesSource() {
        // a|b|c in one tab; break b into a new tab. The source tab collapses to a|c (b removed, rebalanced),
        // a NEW tab holds b as its lone leaf and is selected, and the spec stays in the same session table.
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
        XCTAssertEqual(s2.sessions[0].tabs.count, 1, "precondition: one multi-pane tab")

        let s3 = WorkspaceTreeOps.breakPaneToTab(b, in: s2)
        XCTAssertEqual(s3.sessions[0].tabs.count, 2, "a new tab is appended")
        // Source tab (index 0) collapsed to a|c, b gone.
        XCTAssertEqual(s3.sessions[0].tabs[0].root.allPaneIDs(), [a, c], "source tab keeps a and c, drops b")
        // New tab (index 1) holds exactly b as a single leaf, and is the active tab.
        XCTAssertEqual(s3.sessions[0].tabs[1].root, .leaf(b), "the new tab is b as a lone leaf")
        XCTAssertEqual(s3.sessions[0].tabs[1].activePane, b, "b is active in its new tab")
        XCTAssertEqual(s3.sessions[0].activeTabIndex, 1, "the freshly-broken tab is selected")
        XCTAssertEqual(s3.spec(for: b)?.title, "b", "b's spec is preserved in the same session table")
        assertInvariant(s3)
    }

    func testBreakPaneToTabIsNoOpForALoneLeaf() {
        // A tab's only pane can't be broken out (nothing to break from) — the workspace is unchanged.
        let (ws, a) = singleLeaf()
        let after = WorkspaceTreeOps.breakPaneToTab(a, in: ws)
        XCTAssertEqual(after, ws, "breaking out a tab's sole leaf is a no-op")
        XCTAssertEqual(after.sessions[0].tabs.count, 1, "no new tab is created")
    }

    func testBreakPaneToTabIsNoOpForAnAbsentPane() {
        let (ws, _) = singleLeaf()
        let after = WorkspaceTreeOps.breakPaneToTab(PaneID(), in: ws)
        XCTAssertEqual(after, ws, "breaking out a pane not in the workspace is a no-op")
    }

    // MARK: moveFocus facade (directional + cycle)

    func testMoveFocusDirectionalResolvesGeometricNeighbour() throws {
        // a|b horizontal columns, a focused. Move focus right against a real bounds rect → lands on b
        // (the right column); move left from b → back to a.
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
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
        let (s1, _) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let withA = WorkspaceTreeOps.focusPane(a, in: s1)
        let moved = WorkspaceTreeOps.moveFocus(.left, bounds: CGRect(x: 0, y: 0, width: 800, height: 400), in: withA)
        XCTAssertEqual(moved, withA, "moving past the left edge is a no-op (no neighbour)")
    }

    func testMoveFocusCycleAdvancesAndWrapsThroughLeaves() throws {
        // a|b|c (pre-order [a,b,c]); .next from a → b, from c wraps → a; .previous from a wraps → c.
        let (ws, a) = singleLeaf()
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let (s2, c) = WorkspaceTreeOps.splitPane(b, axis: .horizontal, newSpec: termSpec("c"), in: s1)
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
        let (s1, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let s2 = WorkspaceTreeOps.swapPanes(a, b, in: s1)
        XCTAssertEqual(
            try XCTUnwrap(s2.activeSession?.tabs[0].root.allPaneIDs()),
            [b, a],
            "the two leaves swapped position",
        )
        assertInvariant(s2)
    }

    // MARK: updatingSpec mutates the side table, not the tree

    func testUpdatingSpecChangesSpecNotTree() throws {
        let (ws, a) = singleLeaf()
        let (s1, _) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: termSpec("b"), in: ws)
        let treeBefore = try XCTUnwrap(s1.activeSession?.tabs[0].root)
        let s2 = WorkspaceTreeOps.updatingSpec(a, in: s1) { spec in spec.title = "renamed" }
        XCTAssertEqual(s2.spec(for: a)?.title, "renamed")
        XCTAssertEqual(try XCTUnwrap(s2.activeSession?.tabs[0].root), treeBefore, "a rename never churns the tree")
        assertInvariant(s2)
    }

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

    func testTreeWorkspaceRoundTrips() throws {
        let (ws0, a) = singleLeaf()
        let (ws1, _) = WorkspaceTreeOps.splitPane(a, axis: .vertical, newSpec: termSpec("b"), in: ws0)
        let (ws2, _) = WorkspaceTreeOps.newTab(in: ws1, spec: termSpec("c"))
        let (ws, _) = WorkspaceTreeOps.newSession(in: ws2, name: "s2", spec: termSpec("d"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ws)
        let back = try JSONDecoder().decode(TreeWorkspace.self, from: data)
        XCTAssertEqual(back, ws, "TreeWorkspace round-trips byte-stable")
        XCTAssertEqual(try encoder.encode(back), data)
    }

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
