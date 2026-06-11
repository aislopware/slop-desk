import XCTest
@testable import AislopdeskClientUI

/// Pins the **pure workspace arithmetic** on ``Workspace`` (docs/31) — the single-canvas + named
/// ``PaneGroup`` model that replaced the retired tab layer. Group CRUD (add / rename / remove / assign
/// / reorder), focus, lookups, and the normalizing repairs, plus the default-workspace factory. Every
/// op returns a new `Workspace` value; no store, no client, no async.
///
/// The subtle contracts asserted here:
/// - `removingGroup(_:)` drops the group but its member panes SURVIVE as ungrouped (deleting a group
///   never closes a pane).
/// - `assigning(pane:toGroup:)` is disjoint — a pane is in at most one group, so re-assigning moves it.
/// - `focusing(_:)` only takes if the pane is on the canvas (no-op otherwise).
/// - `defaultWorkspace()` is exactly one focused "Terminal" pane on a single canvas, not maximized.
final class WorkspaceTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a workspace of `n` terminal panes (titled t0…t(n-1)) on a single canvas with the first
    /// focused, returning the workspace and the ordered pane ids so tests can assert pinned identities.
    private func makeWorkspace(_ n: Int) -> (ws: Workspace, ids: [PaneID]) {
        let panes: [(PaneID, PaneSpec)] = (0..<n).map { i in
            (PaneID(), PaneSpec(kind: .terminal, title: "t\(i)"))
        }
        let ws = Workspace.make(panes: panes, focused: panes.first?.0)
        return (ws, panes.map { $0.0 })
    }

    // MARK: - defaultWorkspace

    func testDefaultWorkspaceIsOneFocusedTerminalPane() {
        let ws = Workspace.defaultWorkspace()
        XCTAssertEqual(ws.schemaVersion, Workspace.currentSchemaVersion)
        XCTAssertEqual(ws.schemaVersion, 4)

        // A single terminal pane on the canvas, focused, not maximized, ungrouped.
        XCTAssertEqual(ws.canvas.itemCount, 1)
        XCTAssertNil(ws.maximizedPane)
        XCTAssertTrue(ws.groups.isEmpty)

        let paneID = ws.canvas.allIDs()[0]
        XCTAssertEqual(ws.focusedPane, paneID, "focus points at the only pane")
        XCTAssertEqual(ws.canvas.spec(for: paneID)?.kind, .terminal)
        XCTAssertEqual(ws.canvas.spec(for: paneID)?.title, "Terminal")
        XCTAssertNil(ws.group(ofPane: paneID), "the only pane is ungrouped")
    }

    // MARK: - addingGroup

    func testAddingGroupAppendsEmptyGroupAndReturnsID() {
        let (ws, _) = makeWorkspace(2)
        let (result, gid) = ws.addingGroup(name: "alpha")

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].id, gid)
        XCTAssertEqual(result.groups[0].name, "alpha")
        XCTAssertEqual(result.group(gid)?.name, "alpha", "lookup finds the freshly minted group")
        // A new group has no members yet — every pane is still ungrouped.
        XCTAssertEqual(result.canvas.ids(inGroup: gid), [], "new group starts empty")
        XCTAssertEqual(result.canvas.ids(inGroup: nil), ws.canvas.allIDs(), "all panes still ungrouped")
    }

    func testAddingGroupPreservesEarlierGroupsInOrder() {
        let (ws, _) = makeWorkspace(1)
        let (afterFirst, first) = ws.addingGroup(name: "alpha")
        let (afterSecond, second) = afterFirst.addingGroup(name: "beta")

        XCTAssertEqual(afterSecond.groups.map { $0.id }, [first, second], "append order is preserved")
        XCTAssertEqual(afterSecond.groupIndex(of: first), 0)
        XCTAssertEqual(afterSecond.groupIndex(of: second), 1)
    }

    // MARK: - renamingGroup

    func testRenamingGroupChangesNameOnly() {
        let (ws, _) = makeWorkspace(1)
        let (a, alpha) = ws.addingGroup(name: "alpha")
        let (b, _) = a.addingGroup(name: "beta")
        let result = b.renamingGroup(alpha, to: "renamed")

        XCTAssertEqual(result.group(alpha)?.name, "renamed")
        XCTAssertEqual(result.groups[1].name, "beta", "siblings untouched")
    }

    func testRenamingAbsentGroupIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        XCTAssertEqual(ws.renamingGroup(PaneGroupID(), to: "x"), ws)
    }

    // MARK: - assigning (disjoint membership)

    func testAssigningPaneToGroupSetsMembership() {
        let (ws, ids) = makeWorkspace(3)
        let (withGroup, gid) = ws.addingGroup(name: "alpha")
        let result = withGroup.assigning(pane: ids[1], toGroup: gid)

        XCTAssertEqual(result.group(ofPane: ids[1])?.id, gid, "the pane now belongs to the group")
        XCTAssertEqual(result.canvas.ids(inGroup: gid), [ids[1]], "group has exactly that member")
        XCTAssertNil(result.group(ofPane: ids[0]), "siblings remain ungrouped")
    }

    /// Membership is disjoint: re-assigning a pane to a second group MOVES it (it is not in two groups).
    func testAssigningPaneToSecondGroupMovesIt() {
        let (ws, ids) = makeWorkspace(2)
        let (a, alpha) = ws.addingGroup(name: "alpha")
        let (b, beta) = a.addingGroup(name: "beta")
        let inAlpha = b.assigning(pane: ids[0], toGroup: alpha)
        let inBeta = inAlpha.assigning(pane: ids[0], toGroup: beta)

        XCTAssertEqual(inBeta.group(ofPane: ids[0])?.id, beta, "re-assignment moves the pane")
        XCTAssertEqual(inBeta.canvas.ids(inGroup: alpha), [], "left the first group")
        XCTAssertEqual(inBeta.canvas.ids(inGroup: beta), [ids[0]], "joined the second group")
    }

    func testAssigningPaneToNilUngroupsIt() {
        let (ws, ids) = makeWorkspace(2)
        let (a, alpha) = ws.addingGroup(name: "alpha")
        let grouped = a.assigning(pane: ids[0], toGroup: alpha)
        let ungrouped = grouped.assigning(pane: ids[0], toGroup: nil)

        XCTAssertNil(ungrouped.group(ofPane: ids[0]), "passing nil ungroups the pane")
        XCTAssertEqual(ungrouped.canvas.ids(inGroup: alpha), [])
    }

    // MARK: - removingGroup (members survive ungrouped)

    func testRemovingGroupDropsGroupButKeepsMembersUngrouped() {
        let (ws, ids) = makeWorkspace(3)
        let (a, alpha) = ws.addingGroup(name: "alpha")
        let grouped = a.assigning(pane: ids[0], toGroup: alpha)
            .assigning(pane: ids[1], toGroup: alpha)
        let result = grouped.removingGroup(alpha)

        XCTAssertNil(result.group(alpha), "the group metadata is gone")
        XCTAssertTrue(result.groups.isEmpty)
        // The panes survive — deleting a group never closes a pane, just clears membership.
        XCTAssertEqual(result.canvas.allIDs(), ids, "all panes survive on the canvas")
        XCTAssertNil(result.group(ofPane: ids[0]), "former members are now ungrouped")
        XCTAssertNil(result.group(ofPane: ids[1]))
    }

    func testRemovingAbsentGroupIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        XCTAssertEqual(ws.removingGroup(PaneGroupID()), ws)
    }

    // MARK: - movingGroup (onMove semantics, identity preserved)

    func testMovingGroupReordersByIdentity() {
        let (ws, _) = makeWorkspace(1)
        let (a, g0) = ws.addingGroup(name: "g0")
        let (b, g1) = a.addingGroup(name: "g1")
        let (c, g2) = b.addingGroup(name: "g2") // [g0, g1, g2]
        // Move g0 (index 0) to the end (destination 3 in SwiftUI onMove terms).
        let result = c.movingGroup(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(result.groups.map { $0.id }, [g1, g2, g0], "groups reorder by identity")
        XCTAssertEqual(result.groups.map { $0.name }, ["g1", "g2", "g0"])
    }

    // MARK: - focus (pure)

    func testFocusingMovesFocusToExistingPane() {
        let (ws, ids) = makeWorkspace(3) // focused = ids[0]
        let result = ws.focusing(ids[2])
        XCTAssertEqual(result.focusedPane, ids[2])
    }

    func testFocusingAbsentPaneIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        let result = ws.focusing(PaneID())
        XCTAssertEqual(result, ws, "focusing a pane not on the canvas is a no-op")
    }

    /// Maximize follows focus: typing must never land on a pane hidden behind a maximized one.
    func testFocusingRepointsMaximizeToTheFocusedPane() {
        let (base, ids) = makeWorkspace(3)
        var ws = base
        ws.maximizedPane = ids[0]
        let result = ws.focusing(ids[2])
        XCTAssertEqual(result.focusedPane, ids[2])
        XCTAssertEqual(result.maximizedPane, ids[2], "maximize tracks the newly focused pane")
    }

    // MARK: - lookups

    func testGroupLookupsByIDAndPane() {
        let (ws, ids) = makeWorkspace(3)
        let (a, gid) = ws.addingGroup(name: "alpha")
        let result = a.assigning(pane: ids[1], toGroup: gid)

        XCTAssertEqual(result.group(gid)?.name, "alpha")
        XCTAssertEqual(result.groupIndex(of: gid), 0)
        XCTAssertNil(result.group(PaneGroupID()), "absent group id resolves to nil")
        XCTAssertNil(result.groupIndex(of: PaneGroupID()))
        XCTAssertEqual(result.group(ofPane: ids[1])?.id, gid)
        XCTAssertNil(result.group(ofPane: ids[0]), "ungrouped pane has no group")
    }

    // MARK: - normalizing repairs (applied on load — never crash on a hand-edited file)

    func testNormalizingFocusRepairsDanglingFocusAndMaximize() {
        let (base, ids) = makeWorkspace(2)
        var ws = base
        ws.focusedPane = PaneID()        // points at a pane not on the canvas
        ws.maximizedPane = PaneID()      // dangling maximize
        let result = ws.normalizingFocus()

        XCTAssertEqual(result.focusedPane, ids[0], "dangling focus repoints to the first pane")
        XCTAssertNil(result.maximizedPane, "dangling maximize clears")
    }

    func testNormalizingFocusFillsNilFocus() {
        let (base, ids) = makeWorkspace(2)
        var ws = base
        ws.focusedPane = nil
        let result = ws.normalizingFocus()
        XCTAssertEqual(result.focusedPane, ids[0], "nil focus repoints to the first pane")
    }

    /// A pane whose `groupID` names a group not in `groups` (a hand-edited / partially-deleted file)
    /// is reset to ungrouped; empty groups are KEPT.
    func testNormalizingGroupsResetsDanglingMembershipKeepsEmptyGroups() {
        let (ws, ids) = makeWorkspace(2)
        let (a, alpha) = ws.addingGroup(name: "alpha")
        // Assign a pane to alpha, then drop the group from `groups` WITHOUT clearing membership,
        // simulating a hand-edited file where the item references a non-existent group.
        var corrupt = a.assigning(pane: ids[0], toGroup: alpha)
        corrupt.groups.removeAll()
        let result = corrupt.normalizingGroups()

        XCTAssertNil(result.group(ofPane: ids[0]), "membership to an absent group is reset to ungrouped")

        // An empty (member-less) but registered group is preserved.
        let (withEmpty, _) = ws.addingGroup(name: "empty")
        let normalized = withEmpty.normalizingGroups()
        XCTAssertEqual(normalized.groups.count, 1, "an empty registered group is kept")
    }
}
