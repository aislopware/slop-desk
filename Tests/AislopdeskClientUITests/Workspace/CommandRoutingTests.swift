import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the **command-routing** contract (docs/30 §7): the one tested `apply(_:to:)` free function
/// that every keyboard surface — the macOS menu-bar ``WorkspaceCommands``, the iPad hardware-keyboard
/// HUD, and the compact on-screen affordances — funnels through. Each `WorkspaceCommand` case must
/// land on the expected ``WorkspaceStore`` mutation, observable through the store's public surface
/// (the single canvas of intent + the `FakePaneSession`-backed registry).
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (docs/22 §0,
/// §8) so it exercises the command → mutation chain **without ever building a `AislopdeskClient` or a
/// `HostServer`** (the latter deadlocks the pool). No view is constructed: `apply(_:to:)` is the pure
/// seam under test, identical to what a `Button` action in ``WorkspaceCommands`` invokes.
@MainActor
final class CommandRoutingTests: XCTestCase {
    // MARK: - Fixtures

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(
            restoring: restoring,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The canvas's pane ids in z-order.
    private func paneIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.workspace.canvas.allIDs()
    }

    /// Reports a left/right SolvedLayout so geometric focus moves resolve: `left` fills the left half,
    /// `right` the right half (exactly as the canvas view does after solving, docs/30 §6.2).
    private func reportTwoPaneLayout(_ store: WorkspaceStore, left: PaneID, right: PaneID) {
        store.updateSolvedLayout(SolvedLayout(
            frames: [
                left: CGRect(x: 0, y: 0, width: 100, height: 100),
                right: CGRect(x: 100, y: 0, width: 100, height: 100),
            ],
        ))
    }

    // MARK: - New pane / tidy

    /// `apply(.newPane)` adds a pane to the canvas, grows the pane count by one, and focuses the new pane.
    func testApplyNewPaneGrowsPaneCountAndFocusesNewPane() {
        let store = makeStore()
        XCTAssertEqual(paneIDs(store).count, 1, "default workspace = one pane")
        let original = store.workspace.focusedPane

        apply(.newPane(.terminal), to: store)

        let ids = paneIDs(store)
        XCTAssertEqual(ids.count, 2, "newPane adds exactly one pane")
        XCTAssertEqual(store.allSessions.count, 2, "reconcile materialized the new pane's session")
        let focused = store.workspace.focusedPane
        XCTAssertNotEqual(focused, original, "focus moved to the newly created pane")
        XCTAssertTrue(focused.map(ids.contains) ?? false, "the focused pane is on the canvas")
    }

    /// `apply(.tidy)` packs the canvas into a non-overlapping grid (pane count + sessions unchanged).
    func testApplyTidyArrangesWithoutChangingPaneSet() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        apply(.newPane(.terminal), to: store) // three panes
        XCTAssertEqual(paneIDs(store).count, 3)

        apply(.tidy, to: store)

        XCTAssertEqual(paneIDs(store).count, 3, "tidy never changes the pane set")
        XCTAssertEqual(store.allSessions.count, 3, "tidy is a registry no-op")
        // No two panes overlap after tidy.
        let frames = store.workspace.canvas.items.map(\.frame)
        for i in frames.indices {
            for j in (i + 1)..<frames.count {
                let inter = frames[i].intersection(frames[j])
                XCTAssertTrue(inter.isNull || inter.isEmpty, "tidied panes must not overlap")
            }
        }
    }

    /// `apply(.centerFocusedPane)` only moves the camera (no pane-set / focus change).
    func testApplyCenterFocusedPaneMovesOnlyCamera() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        let focused = store.workspace.focusedPane
        let panesBefore = paneIDs(store)

        apply(.centerFocusedPane, to: store)

        XCTAssertEqual(paneIDs(store), panesBefore, "center never changes the pane set")
        XCTAssertEqual(store.workspace.focusedPane, focused, "center never changes focus")
    }

    /// `apply(.centerAll)` only moves the camera (no pane-set / focus change).
    func testApplyCenterAllMovesOnlyCamera() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        apply(.newPane(.terminal), to: store) // three panes spread across the canvas
        let focused = store.workspace.focusedPane
        let panesBefore = paneIDs(store)

        apply(.centerAll, to: store)

        XCTAssertEqual(paneIDs(store), panesBefore, "centerAll never changes the pane set")
        XCTAssertEqual(store.workspace.focusedPane, focused, "centerAll never changes focus")
    }

    // MARK: - Close pane

    /// `apply(.closePane)` removes the focused pane from a multi-pane canvas and re-points focus.
    func testApplyClosePaneRemovesFocusedPane() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store) // two panes, the new one focused
        XCTAssertEqual(paneIDs(store).count, 2)
        let closing = store.workspace.focusedPane

        apply(.closePane, to: store)

        let ids = paneIDs(store)
        XCTAssertEqual(ids.count, 1, "closePane removed the focused pane")
        XCTAssertFalse(closing.map(ids.contains) ?? false, "the closed pane is gone")
        XCTAssertEqual(store.workspace.focusedPane, ids[0], "focus re-pointed to the survivor")
    }

    // MARK: - Groups: lifecycle

    /// `apply(.newGroup)` with NOTHING selected appends a new EMPTY group; the pane set / focus /
    /// registry are untouched (a group is metadata, not a pane). With a selection it groups it instead
    /// (see `testApplyNewGroupGroupsTheSelection`).
    func testApplyNewGroupAddsGroupWithoutTouchingPanes() {
        let store = makeStore()
        XCTAssertTrue(store.workspace.groups.isEmpty, "default workspace has no groups")
        let panesBefore = paneIDs(store)
        let sessionsBefore = store.allSessions.count

        apply(.newGroup, to: store)

        XCTAssertEqual(store.workspace.groups.count, 1, "newGroup appended a group")
        XCTAssertEqual(paneIDs(store), panesBefore, "newGroup must not change the pane set")
        XCTAssertTrue(
            store.workspace.groups.first.map { store.workspace.canvas.ids(inGroup: $0.id).isEmpty } ?? false,
            "with no selection the group is empty",
        )
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "newGroup must not touch the registry")
    }

    /// `apply(.newGroup)` WITH a multi-selection groups the selection into one new group (the common
    /// intent) instead of the old invisible empty-group dead-end.
    func testApplyNewGroupGroupsTheSelection() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store) // two panes
        let ids = paneIDs(store)
        store.setSelection(Set(ids))

        apply(.newGroup, to: store)

        XCTAssertEqual(store.workspace.groups.count, 1)
        let gid = store.workspace.groups[0].id
        XCTAssertEqual(Set(store.workspace.canvas.ids(inGroup: gid)), Set(ids), "every selected pane joined the group")
        XCTAssertTrue(store.selectedPanes.isEmpty, "the transient selection is cleared after grouping")
    }

    /// `groupSelection()` assigns every selected pane (in canvas order) to one new group and clears the
    /// selection; the pane set + registry are untouched (grouping is metadata).
    func testGroupSelectionAssignsAllSelectedAndClearsSelection() throws {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        apply(.newPane(.terminal), to: store) // three panes
        let ids = paneIDs(store)
        let sessionsBefore = store.allSessions.count
        store.setSelection([ids[0], ids[2]]) // two of three

        let gid = store.groupSelection(name: "G")

        XCTAssertNotNil(gid)
        XCTAssertEqual(try Set(store.workspace.canvas.ids(inGroup: XCTUnwrap(gid))), Set([ids[0], ids[2]]))
        XCTAssertNil(store.workspace.group(ofPane: ids[1]), "the unselected pane stays ungrouped")
        XCTAssertTrue(store.selectedPanes.isEmpty)
        XCTAssertEqual(paneIDs(store), ids, "grouping never changes the pane set")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "grouping never touches the registry")
    }

    func testGroupSelectionNoopWithEmptySelection() {
        let store = makeStore()
        XCTAssertNil(store.groupSelection(), "no selection → nil, no group created")
        XCTAssertTrue(store.workspace.groups.isEmpty)
        apply(.groupSelection, to: store) // also a no-op via the command
        XCTAssertTrue(store.workspace.groups.isEmpty)
    }

    func testGroupChordsAreBound() {
        let interp = CommandInterpreter()
        XCTAssertEqual(interp.feed(KeyChord(character: "g", [.control, .command])), .newGroup)
        XCTAssertEqual(interp.feed(KeyChord(character: "g", [.option, .command])), .groupSelection)
    }

    func testRecentPaneSwitchChordsAreBound() {
        let interp = CommandInterpreter()
        XCTAssertEqual(
            interp.feed(KeyChord(character: ";", [.option, .command])),
            .switchRecentPane(forward: false),
            "⌥⌘; goes to the previously-focused pane",
        )
        XCTAssertEqual(
            interp.feed(KeyChord(character: ";", [.option, .command, .shift])),
            .switchRecentPane(forward: true),
            "⌥⇧⌘; walks back toward newer",
        )
    }

    func testGroupCycleAndRunLastSnippetChordsAreBound() {
        // Pins both the modifier set AND the forward flag — a transposed ]/[ or a wrong modifier would
        // otherwise slip past the cheat-sheet drift guard (which only checks each command HAS a row).
        let interp = CommandInterpreter()
        XCTAssertEqual(
            interp.feed(KeyChord(character: "]", [.control, .command])),
            .cycleFocusInGroup(forward: true),
            "⌃⌘] cycles forward within the group",
        )
        XCTAssertEqual(
            interp.feed(KeyChord(character: "[", [.control, .command])),
            .cycleFocusInGroup(forward: false),
            "⌃⌘[ cycles back within the group",
        )
        XCTAssertEqual(
            interp.feed(KeyChord(character: "r", [.option, .command])),
            .runLastSnippet,
            "⌥⌘R re-fires the last snippet",
        )
    }

    /// The pure group arithmetic the sidebar / store funnel through:
    /// `addGroup` → `assignPane` → `renameGroup` → `removeGroup` (members survive ungrouped).
    func testGroupArithmeticAssignsRenamesAndRemoves() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store) // two panes on the canvas
        let ids = paneIDs(store)
        let pane = ids[0]

        let groupID = store.addGroup(name: "Servers")
        XCTAssertEqual(store.workspace.group(groupID)?.name, "Servers", "the group was created and named")

        store.assignPane(pane, toGroup: groupID)
        XCTAssertEqual(store.workspace.group(ofPane: pane)?.id, groupID, "the pane was assigned to the group")

        store.renameGroup(groupID, "Hosts")
        XCTAssertEqual(store.workspace.group(groupID)?.name, "Hosts", "the group was renamed")

        store.removeGroup(groupID)
        XCTAssertNil(store.workspace.group(groupID), "the group was removed")
        XCTAssertNil(store.workspace.group(ofPane: pane), "the member survives, now ungrouped")
        XCTAssertEqual(paneIDs(store), ids, "removing a group never closes its panes")
    }

    /// `moveGroup(from:to:)` reorders the group list without changing membership or the pane set.
    func testMoveGroupReordersWithoutChangingPanes() {
        let store = makeStore()
        let panesBefore = paneIDs(store)
        let first = store.addGroup(name: "First")
        let second = store.addGroup(name: "Second")
        XCTAssertEqual(store.workspace.groups.map(\.id), [first, second])

        store.moveGroup(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(store.workspace.groups.map(\.id), [second, first], "the second group moved to the front")
        XCTAssertEqual(paneIDs(store), panesBefore, "moveGroup never changes the pane set")
    }

    // MARK: - Center on group

    /// `centerOnGroup` only moves the camera onto the group's bounding box (no pane-set / focus change).
    func testCenterOnGroupMovesOnlyCamera() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        let ids = paneIDs(store)
        let groupID = store.addGroup(name: "G")
        store.assignPane(ids[1], toGroup: groupID)
        let panesBefore = paneIDs(store)
        let focused = store.workspace.focusedPane

        store.centerOnGroup(groupID)

        XCTAssertEqual(paneIDs(store), panesBefore, "centerOnGroup never changes the pane set")
        XCTAssertEqual(store.workspace.focusedPane, focused, "centerOnGroup never changes focus")
    }

    // MARK: - Focus: geometric

    func testApplyFocusDirectionMovesGeometrically() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store) // two panes
        let ids = paneIDs(store) // z-order: [original, new]
        let left = ids[0], right = ids[1]
        reportTwoPaneLayout(store, left: left, right: right)

        store.focus(left)
        XCTAssertEqual(store.workspace.focusedPane, left)

        apply(.focus(.right), to: store)
        XCTAssertEqual(store.workspace.focusedPane, right, "focus(.right) lands on the right pane")

        apply(.focus(.left), to: store)
        XCTAssertEqual(store.workspace.focusedPane, left, "focus(.left) lands back on the left pane")
    }

    func testApplyFocusDirectionNoopWithoutSolvedLayout() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        let focusedBefore = store.workspace.focusedPane

        apply(.focus(.left), to: store) // no updateSolvedLayout called

        XCTAssertEqual(store.workspace.focusedPane, focusedBefore, "no layout ⇒ no directional move")
    }

    // MARK: - Focus: cycle

    func testApplyCycleFocusWrapsThroughPanes() {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        let ids = paneIDs(store) // [a, b]
        let a = ids[0], b = ids[1]
        store.focus(a)

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.workspace.focusedPane, b, "cycle forward a → b")

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.workspace.focusedPane, a, "cycle forward wraps b → a")

        apply(.cycleFocus(forward: false), to: store)
        XCTAssertEqual(store.workspace.focusedPane, b, "cycle backward wraps a → b")
    }

    // MARK: - Maximize

    func testApplyToggleZoomTogglesMaximizedPane() {
        let store = makeStore()
        let focused = store.workspace.focusedPane
        XCTAssertNil(store.workspace.maximizedPane, "no maximize initially")

        apply(.toggleZoom, to: store)
        XCTAssertEqual(store.workspace.maximizedPane, focused, "toggleZoom maximized the focused pane")

        apply(.toggleZoom, to: store)
        XCTAssertNil(store.workspace.maximizedPane, "toggleZoom again cleared the maximize")
    }

    // MARK: - Rename (command-layer no-op for the tree)

    /// `apply(.renamePane)` does not mutate the canvas / focus / maximize / registry — it only nudges the
    /// inline-rename request (the sidebar field commits the value, docs/30 §7).
    func testApplyRenamePaneDoesNotMutateTreeOrRegistry() {
        let store = makeStore()
        let before = store.workspace
        let sessionsBefore = store.allSessions.count

        apply(.renamePane, to: store)

        XCTAssertEqual(store.workspace, before, "renamePane command must not mutate the canvas")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renamePane command must not touch the registry")
        XCTAssertEqual(store.pendingRename, store.focusedPane, "renamePane recorded the pending rename target")
    }

    // MARK: - Terminal bell badge (focus clears it; it persists on unfocused panes)

    private func fake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    func testFocusClearsTheNewlyFocusedPanesBell() throws {
        let store = makeStore()
        apply(.newPane(.terminal), to: store) // two panes; the new one is focused
        let ids = paneIDs(store)
        let other = try XCTUnwrap(ids.first { $0 != store.focusedPane })
        // The background pane rings.
        fake(store, other)?.bellPending = true
        XCTAssertTrue(fake(store, other)?.bellPending ?? false)
        // Focusing it dismisses the badge.
        store.focus(other)
        XCTAssertEqual(fake(store, other)?.clearBellCount, 1, "focus cleared the bell")
        XCTAssertFalse(fake(store, other)?.bellPending ?? true)
    }

    func testBellPersistsWhileTheRingingPaneStaysUnfocused() throws {
        let store = makeStore()
        apply(.newPane(.terminal), to: store)
        let ids = paneIDs(store)
        let focused = try XCTUnwrap(store.focusedPane)
        let background = try XCTUnwrap(ids.first { $0 != focused })
        fake(store, background)?.bellPending = true
        // Focusing the ALREADY-focused pane is a no-op and must not clear a different pane's bell.
        store.focus(focused)
        XCTAssertTrue(fake(store, background)?.bellPending ?? false, "an unfocused pane keeps its badge")
        XCTAssertEqual(fake(store, background)?.clearBellCount, 0)
    }
}
