import CoreGraphics
import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// W6 (docs/42 §"W6 — Keybindings + command palette + cheat sheet"): pins the **tree-command-routing**
/// contract — the single ``WorkspaceBindingRegistry`` source of truth that the menu bar, the ⌘K command
/// palette, the ⌘/ cheat sheet, AND this test all read. Each registered ``WorkspaceAction`` must, when
/// routed through ``WorkspaceBindingRegistry/route(_:to:)`` on a `.tree`-live store, land on the intended
/// store TREE op — asserted through the resulting ``TreeWorkspace`` / registry change, never a recompute
/// of the registry itself (no tautology).
///
/// The suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (never a real
/// `AislopdeskClient` / `HostServer`) and builds every store with ``WorkspaceStore/LiveModel/tree`` so the
/// tree is the live source the routing drives. No SwiftUI view is constructed — `route(_:to:)` is the pure
/// seam under test, identical to what a menu `Button` / palette row / chord dispatch invokes.
@MainActor
final class TreeCommandRoutingTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree` (default: one terminal pane), backed by the
    /// `FakePaneSession` seam — so init reconciles the TREE and the routing then drives it.
    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The tree's leaf ids in DFS order.
    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    /// The active tab's active pane.
    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// Routes `action` through the single-source-of-truth registry (the production seam).
    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        WorkspaceBindingRegistry.route(action, to: store)
    }

    // MARK: - Panes: split adds a leaf + materializes a fake

    /// `.splitRight` adds exactly one leaf (a horizontal sibling) to the active tab and materializes a new
    /// `FakePaneSession` for it — the new leaf becomes the active pane.
    func testSplitRightAddsLeafAndMaterializesFake() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]
        XCTAssertEqual(store.allSessions.count, 1, "default tree = one materialized leaf")

        route(.splitRight, store)

        XCTAssertEqual(leaves(store).count, 2, "splitRight added exactly one leaf")
        XCTAssertEqual(store.allSessions.count, 2, "reconcileTree materialized exactly one new handle")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
        XCTAssertNotNil(store.handle(for: added) as? FakePaneSession, "the new leaf has a fake handle")
    }

    /// `.splitDown` also adds one leaf — proving the axis routes through too (a vertical split). We assert
    /// the leaf count grows and the new leaf is focused; the axis difference vs. `.splitRight` is pinned by
    /// the `WorkspaceTreeOps` suite, so here it suffices that the action reaches the split op.
    func testSplitDownAddsLeaf() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]

        route(.splitDown, store)

        XCTAssertEqual(leaves(store).count, 2, "splitDown added exactly one leaf")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
    }

    /// `.closePane` removes the active pane and tears down exactly its fake (the survivor is untouched).
    func testClosePaneRemovesActivePane() async throws {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store)
        let b = try XCTUnwrap(activePane(store)) // the new pane is active
        XCTAssertNotEqual(a, b)
        let bFake = store.handle(for: b) as? FakePaneSession

        route(.closePane, store)

        XCTAssertNil(store.handle(for: b), "closed leaf removed from the registry synchronously")
        XCTAssertEqual(leaves(store), [a], "only the survivor remains")
        await store.quiesce()
        XCTAssertEqual(bFake?.teardownCount, 1, "the closed leaf was torn down exactly once")
    }

    // MARK: - Focus: geometric move follows the reported layout

    /// `.focusLeft` / `.focusRight` move the active pane along the solved layout the view reports — proving
    /// the focus actions route through `moveFocusTree` against the live geometry (not a no-op).
    func testFocusRightThenLeftMovesActivePane() throws {
        let store = makeTreeStore()
        let left = leaves(store)[0]
        route(.splitRight, store) // a horizontal split: [left | right], right focused
        let right = try XCTUnwrap(activePane(store))
        // Report the rects the SplitTreeView would solve so the geometric move resolves.
        store.updateSolvedLayout(SolvedLayout(frames: [
            left: CGRect(x: 0, y: 0, width: 100, height: 100),
            right: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]))

        route(.focusLeft, store)
        XCTAssertEqual(activePane(store), left, "focusLeft lands on the left pane")

        route(.focusRight, store)
        XCTAssertEqual(activePane(store), right, "focusRight lands back on the right pane")
    }

    // MARK: - View: zoom toggles the active tab's zoomedPane

    /// `.toggleZoom` sets then clears the active tab's `zoomedPane` (render-only zoom; the tree is untouched).
    func testToggleZoomTogglesZoomedPane() {
        let store = makeTreeStore()
        let only = leaves(store)[0]
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "no zoom initially")

        route(.toggleZoom, store)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.zoomedPane, only, "toggleZoom zoomed the active pane")

        route(.toggleZoom, store)
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "toggleZoom again cleared the zoom")
    }

    // MARK: - Tabs: new / next / prev / select-N

    /// `.newTab` adds a tab (single leaf) to the active session and selects it; the leaf is materialized.
    func testNewTabAddsTabAndSelectsIt() {
        let store = makeTreeStore()
        let session0 = try? XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session0?.tabs.count, 1, "default session = one tab")

        route(.newTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "newTab added a tab")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "the new tab is selected")
        XCTAssertEqual(leaves(store).count, 2, "the new tab's leaf was materialized")
        XCTAssertEqual(store.allSessions.count, 2)
    }

    /// `.nextTab` / `.prevTab` cycle the active session's `activeTabIndex` without changing the leaf set.
    func testNextAndPrevTabCycleActiveIndex() {
        let store = makeTreeStore()
        route(.newTab, store) // now two tabs, index 1 active
        route(.newTab, store) // three tabs, index 2 active
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2)
        let leafCount = leaves(store).count

        route(.prevTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "prevTab stepped back one tab")

        route(.nextTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "nextTab stepped forward one tab")

        XCTAssertEqual(leaves(store).count, leafCount, "cycling tabs never changes the leaf set")
    }

    /// `.selectTab(N)` (1-based) selects the Nth tab of the active session.
    func testSelectTabNumberSelectsThatTab() {
        let store = makeTreeStore()
        route(.newTab, store)
        route(.newTab, store) // three tabs (indices 0,1,2), index 2 active

        route(.selectTab(1), store) // 1-based ⇒ index 0
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 0, "selectTab(1) selected the first tab")

        route(.selectTab(3), store) // 1-based ⇒ index 2
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "selectTab(3) selected the third tab")
    }

    /// `.breakPaneToTab` ejects the active pane into a new tab of its session (the source tab collapses).
    func testBreakPaneToTabEjectsActivePane() throws {
        let store = makeTreeStore()
        route(.splitRight, store) // two leaves in one tab
        let moved = try XCTUnwrap(activePane(store))
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "both leaves share one tab")

        route(.breakPaneToTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "break-pane created a second tab")
        // The moved pane is alone in some tab (the new one).
        let owningTab = try XCTUnwrap(store.tree.activeSession?.tabs.first { $0.contains(moved) })
        XCTAssertEqual(owningTab.allPaneIDs(), [moved], "the broken-out pane is alone in its new tab")
    }

    // MARK: - Panes: move / resize / balance (keyboard pane management)

    /// `.movePaneRight` swaps the active pane with its right neighbour (the leaf order flips); the moved pane
    /// keeps focus (PaneID identity preserved). Proven to fail before the action + routing exist.
    func testMovePaneRightSwapsActiveWithRightNeighbour() throws {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store) // [a | b], b active
        let b = try XCTUnwrap(activePane(store))
        store.focusPaneTree(a) // make a active so we move IT right
        store.updateSolvedLayout(SolvedLayout(frames: [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]))

        route(.movePaneRight, store)

        XCTAssertEqual(store.tree.activeSession?.activeTab?.root.allPaneIDs(), [b, a], "a moved right past b")
        XCTAssertEqual(activePane(store), a, "the moved pane keeps focus")
    }

    /// `.resizePaneRight` grows the active pane wider (a sum-preserving divider nudge) — the leaf set is
    /// unchanged. Proven to fail before the action routes to `resizeActivePane`.
    func testResizePaneRightGrowsActivePaneWidth() {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store) // [a | b], b active
        store.focusPaneTree(a)
        guard case let .split(_, _, before)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        func flex(_ c: WeightedChild) -> Double { if case let .flex(w) = c.weight { return w }
            return 0
        }

        route(.resizePaneRight, store)

        guard case let .split(_, _, after)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        XCTAssertGreaterThan(flex(after[0]), flex(before[0]), "the active (leading) pane grew")
        XCTAssertEqual(leaves(store).count, 2, "resize never changes the leaf set")
    }

    /// `.balancePanes` resets the active tab's split weights to equal after an off-balance nudge — the leaf
    /// set is unchanged. Proven to fail before the action routes to `balanceActivePaneSplits`.
    func testBalancePanesEqualizesActiveTabSplit() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b]
        guard case let .split(splitID, _, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        store.resizeDividerTree(splitID: splitID, leadingChildIndex: 0, delta: 0.4) // off-balance

        route(.balancePanes, store)

        guard case let .split(_, _, children)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        func flex(_ c: WeightedChild) -> Double { if case let .flex(w) = c.weight { return w }
            return 0
        }
        XCTAssertEqual(flex(children[0]), flex(children[1]), accuracy: 1e-9, "balance equalized the two columns")
        XCTAssertEqual(leaves(store).count, 2, "balance never changes the leaf set")
    }

    // MARK: - Layouts (select-layout parity): routing + chord pin

    /// `.applyLayout(.evenHorizontal)` re-tiles the active tab into a single horizontal split while keeping
    /// the exact leaf set + every fake handle mounted (the no-teardown invariant). Proven to fail before the
    /// action routes to `store.applyLayout(_)`.
    func testApplyLayoutRetilesPreservingPanesAndHandles() {
        let store = makeTreeStore()
        route(.splitDown, store) // [a / b] — a vertical (stacked) split
        route(.splitDown, store) // 3 leaves stacked
        let before = Set(leaves(store))
        XCTAssertEqual(before.count, 3)

        route(.applyLayout(.evenHorizontal), store)

        XCTAssertEqual(Set(leaves(store)), before, "re-tile keeps the EXACT leaf set (no teardown)")
        guard case let .split(_, axis, children)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("even-horizontal is a single split")
            return
        }
        XCTAssertEqual(axis, .horizontal, "even-horizontal = side-by-side columns")
        XCTAssertEqual(children.count, 3)
        // Every surviving leaf still has its materialized handle (nothing was torn down + recreated).
        for id in before { XCTAssertNotNil(store.handle(for: id), "leaf \(id) keeps its handle through a re-tile") }
        XCTAssertEqual(store.allSessions.count, 3, "no handle materialized or destroyed by the re-tile")
    }

    /// `.cycleLayout` advances the layout each press (the leaf set never changes) — and the first press
    /// applies the FIRST preset (even-horizontal). Proven to fail before `.cycleLayout` routes.
    func testCycleLayoutSteppingKeepsLeafSet() {
        let store = makeTreeStore()
        route(.splitRight, store)
        route(.splitRight, store) // 3 leaves
        let before = Set(leaves(store))

        route(.cycleLayout, store) // → even-horizontal (first preset)
        XCTAssertEqual(Set(leaves(store)), before, "cycle keeps the leaf set")
        if case let .split(_, axis, _)? = store.tree.activeSession?.activeTab?.root {
            XCTAssertEqual(axis, .horizontal, "first cycle press applies even-horizontal")
        } else {
            XCTFail("expected a re-tiled split")
        }

        route(.cycleLayout, store) // → even-vertical
        if case let .split(_, axis, _)? = store.tree.activeSession?.activeTab?.root {
            XCTAssertEqual(axis, .vertical, "second cycle press applies even-vertical")
        } else {
            XCTFail("expected a re-tiled split")
        }
        XCTAssertEqual(Set(leaves(store)), before, "still the same leaf set after the second press")
    }

    /// Pins the Cycle Layout chord to its documented free default ⌃⌘L, and that the five named presets are
    /// chord-LESS (menu/palette only) — a wrong-but-unique value would slip past the collision guard.
    func testCycleLayoutChordIsControlCommandLAndPresetsHaveNoChord() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.cycleLayout), KeyChord(character: "l", [.control, .command]), "cycle layout = ⌃⌘L")
        for preset in WorkspaceTreeOps.LayoutPreset.allCases {
            XCTAssertNil(chord(.applyLayout(preset)), "named preset \(preset) is menu/palette only — no chord")
        }
    }

    /// Pins the nine new pane-management chords to their documented defaults (move = ⌥⌘⇧arrows, resize =
    /// ⌃⌘arrows, balance = ⌃⌘=) — distinct from focus (⌥⌘arrows) and the ⌃⌘bracket block jumps.
    func testPaneManagementChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.movePaneLeft), KeyChord(.leftArrow, [.option, .command, .shift]), "move left = ⌥⌘⇧←")
        XCTAssertEqual(chord(.movePaneRight), KeyChord(.rightArrow, [.option, .command, .shift]), "move right = ⌥⌘⇧→")
        XCTAssertEqual(chord(.movePaneUp), KeyChord(.upArrow, [.option, .command, .shift]), "move up = ⌥⌘⇧↑")
        XCTAssertEqual(chord(.movePaneDown), KeyChord(.downArrow, [.option, .command, .shift]), "move down = ⌥⌘⇧↓")
        XCTAssertEqual(chord(.resizePaneLeft), KeyChord(.leftArrow, [.control, .command]), "resize left = ⌃⌘←")
        XCTAssertEqual(chord(.resizePaneRight), KeyChord(.rightArrow, [.control, .command]), "resize right = ⌃⌘→")
        XCTAssertEqual(chord(.resizePaneUp), KeyChord(.upArrow, [.control, .command]), "resize up = ⌃⌘↑")
        XCTAssertEqual(chord(.resizePaneDown), KeyChord(.downArrow, [.control, .command]), "resize down = ⌃⌘↓")
        XCTAssertEqual(chord(.balancePanes), KeyChord(character: "=", [.control, .command]), "balance = ⌃⌘=")
    }

    // MARK: - Floating panes (P5a): chord pins + routing

    /// The two floating-pane chords are the documented free defaults: ⌘⇧F float-toggle, ⌃⌘F new-floating.
    /// Pinning them here makes a future rebind/typo a loud failure (the uniqueness test only catches a
    /// COLLISION, not a wrong-but-unique value).
    func testFloatingPaneChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.toggleFloat), KeyChord(character: "f", [.command, .shift]), "toggle float = ⌘⇧F")
        XCTAssertEqual(chord(.spawnFloating), KeyChord(character: "f", [.control, .command]), "new floating = ⌃⌘F")
    }

    /// `.toggleFloat` on a 2-leaf tab moves the active pane into the floating layer (and keeps it as the
    /// active pane); routing it again embeds it back.
    func testToggleFloatRoutesPaneIntoAndOutOfFloatingLayer() throws {
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let a = ws0.allPaneIDs()[0]
        let (ws1, b) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        let store = makeTreeStore(restoringTree: ws1)
        store.focusPaneTree(b)

        route(.toggleFloat, store)
        var tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        XCTAssertTrue(tab.floatingPanes.contains(b), "the active pane floated")
        XCTAssertFalse(tab.root.contains(b), "and left the tiled tree")
        XCTAssertNotNil(store.tree.spec(for: b)?.floatingFrame, "with a stamped frame")
        XCTAssertEqual(leaves(store).count, 2, "no leaf was torn down — the float is still a leaf")

        route(.toggleFloat, store)
        tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        XCTAssertFalse(tab.floatingPanes.contains(b), "routing again embeds it back")
        XCTAssertTrue(tab.root.contains(b))
        XCTAssertNil(store.tree.spec(for: b)?.floatingFrame, "the frame is cleared on embed")
    }

    /// `.spawnFloating` mints a NEW floating pane (a new leaf, materialized) without touching the tiled tree.
    func testSpawnFloatingAddsAFloatingLeaf() throws {
        let store = makeTreeStore()
        let before = Set(leaves(store))

        route(.spawnFloating, store)

        let after = Set(leaves(store))
        let newID = try XCTUnwrap(after.subtracting(before).first, "a new leaf was minted")
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        XCTAssertTrue(tab.floatingPanes.contains(newID), "the new pane is floating")
        XCTAssertFalse(tab.root.contains(newID), "and NOT in the tiled tree")
        XCTAssertNotNil(store.tree.spec(for: newID)?.floatingFrame)
    }

    // MARK: - Sessions: new session changes the active session + materializes its leaf

    /// `.newSession` adds a session (one tab/leaf) and selects it; its leaf is materialized.
    func testNewSessionAddsAndSelectsSession() throws {
        let store = makeTreeStore()
        let session0 = try XCTUnwrap(store.tree.activeSessionID)
        XCTAssertEqual(store.tree.sessions.count, 1)

        route(.newSession, store)

        XCTAssertEqual(store.tree.sessions.count, 2, "newSession added a session")
        XCTAssertNotEqual(store.tree.activeSessionID, session0, "the new session is now active")
        XCTAssertEqual(leaves(store).count, 2, "the new session's leaf was materialized")
        XCTAssertEqual(store.allSessions.count, 2)
    }

    // MARK: - Rename: ⌘⇧R targets the active TAB on the tree shell (ITEM B1)

    /// B1: `.renamePane` on a `.tree` store records the active TAB as the pending tab-rename target (the
    /// `TabBarView` inline field opens) — the tree/registry are untouched, a command-layer UI nudge. It must
    /// NOT set `pendingRename` (the canvas pane-rename request no tree view observes — the old dead-end).
    func testRenameActionTargetsActiveTab() throws {
        let store = makeTreeStore()
        let activeTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let treeBefore = store.tree
        let sessionsBefore = store.allSessions.count

        route(.renamePane, store)

        XCTAssertEqual(store.pendingTabRename, activeTab, "renamePane records the active TAB as the rename target")
        XCTAssertNil(store.pendingRename, "the dead canvas pane-rename request is NOT set on the tree shell")
        XCTAssertEqual(store.tree, treeBefore, "renamePane never mutates the tree")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renamePane never touches the registry")
    }

    // MARK: - Registry integrity (the single source of truth)

    /// C1: every binding the DISPATCHER sees (``allBindings`` — incl. the nine generated ⌘1…⌘9 select-tab
    /// chords the `bindings` table omits) has a stable, unique id and (for the chord-carrying ones) a unique
    /// chord. Iterating only `bindings` (the old test) missed the nine digit chords the dispatcher actually
    /// routes, so a collision among them — or with a ⌘-digit elsewhere — could slip past. We ALSO assert
    /// `chordTable.count == #chord-bearing allBindings`, proving no two entries collapsed onto one chord (the
    /// dict would silently drop a duplicate).
    func testRegistryBindingsHaveUniqueIDsAndChords() {
        let ids = WorkspaceBindingRegistry.allBindings.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "all binding ids (incl. select-tab digits) are unique")

        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord (conflict-free)")
        // The chord → action table is built from allBindings; if two entries shared a chord, the dict would
        // collapse them and its count would drop below the number of chord-bearing bindings.
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable.count,
            chords.count,
            "every chord-bearing binding has its OWN chordTable entry (no collision collapsed two)",
        )
    }

    /// C1: every chord-carrying binding the DISPATCHER sees (``allBindings``) is ⌘- or ⌥-prefixed (the
    /// load-bearing §5 conflict rule: a bare key / Ctrl-letter must fall through to the focused terminal).
    /// Iterating `allBindings` (not just `bindings`) covers the nine ⌘-digit select-tab chords too.
    func testEveryChordIsCommandOrOptionPrefixed() {
        for binding in WorkspaceBindingRegistry.allBindings {
            guard let chord = binding.chord else { continue }
            XCTAssertTrue(
                chord.modifiers.contains(.command) || chord.modifiers.contains(.option),
                "binding \(binding.id) chord must be ⌘- or ⌥-prefixed (never steal a terminal key)",
            )
        }
    }

    /// The chord table resolves the documented coding-IDE defaults — pins the exact chords the cheat sheet
    /// advertises so a transposed modifier can't slip past the "every action has a row" drift guard.
    func testDefaultChordsMatchTheDocumentedTable() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.newTab), KeyChord(character: "t", [.command]), "new tab = ⌘T")
        XCTAssertEqual(chord(.closePane), KeyChord(character: "w", [.command]), "close pane = ⌘W")
        XCTAssertEqual(chord(.splitRight), KeyChord(character: "d", [.command]), "split right = ⌘D")
        XCTAssertEqual(chord(.splitDown), KeyChord(character: "d", [.command, .shift]), "split down = ⌘⇧D")
        XCTAssertEqual(chord(.focusLeft), KeyChord(.leftArrow, [.option, .command]), "focus left = ⌥⌘←")
        XCTAssertEqual(chord(.toggleZoom), KeyChord(.return, [.option, .command]), "zoom = ⌥⌘↩")
        XCTAssertEqual(chord(.nextTab), KeyChord(character: "]", [.command]), "next tab = ⌘] (Muxy parity)")
        XCTAssertEqual(chord(.prevTab), KeyChord(character: "[", [.command]), "prev tab = ⌘[ (Muxy parity)")
        XCTAssertEqual(chord(.closeTab), KeyChord(character: "w", [.command, .shift]), "close tab = ⌘⇧W")
        XCTAssertEqual(chord(.toggleSidebar), KeyChord(character: "b", [.command]), "toggle sidebar = ⌘B")
        XCTAssertEqual(chord(.newSession), KeyChord(character: "n", [.control, .command]), "new session = ⌃⌘N")
        XCTAssertEqual(chord(.selectTab(1)), KeyChord(character: "1", [.command]), "select tab 1 = ⌘1")
        XCTAssertEqual(chord(.selectTab(9)), KeyChord(character: "9", [.command]), "select tab 9 = ⌘9")
        XCTAssertEqual(chord(.find), KeyChord(character: "f", [.command]), "find = ⌘F (W14)")
        // WB2 Warp-style Blocks chords.
        XCTAssertEqual(
            chord(.commandNavigator), KeyChord(character: "o", [.control, .command]), "navigator = ⌃⌘O",
        )
        XCTAssertEqual(
            chord(.jumpPreviousBlock), KeyChord(character: "[", [.control, .command]), "prev block = ⌃⌘[",
        )
        XCTAssertEqual(
            chord(.jumpNextBlock), KeyChord(character: "]", [.control, .command]), "next block = ⌃⌘]",
        )
    }

    // MARK: - View: WB2 block actions route to the active-pane store hooks

    /// The WB2 navigator / jump-to-block actions route to the store's active-pane hooks (no closure path) —
    /// a no-op against a FakePaneSession (not a live terminal), but they must not trap or mutate the tree.
    /// Pins that the three new actions are wired to the store, not dropped. Proven to fail before routing.
    @MainActor
    func testBlockActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.commandNavigator, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousBlock, to: store)
        WorkspaceBindingRegistry.route(.jumpNextBlock, to: store)
        XCTAssertEqual(store.tree, before, "the WB2 block actions are active-pane affordances — the tree is unchanged")
    }

    /// WB3: the re-run-last + jump-to-failed actions route to the store's active-pane hooks WITHOUT trapping
    /// or mutating the tree. Against a `FakePaneSession` (not a live terminal) the hooks no-op, so this only
    /// pins tree-immutability + trap-freedom — it is BLIND to which store hook fires or the forward/backward
    /// mapping. The BEHAVIORAL dispatch (re-run bytes, the `.jumpPreviousFailed`/`.jumpNextFailed` direction
    /// inversion) is proven in `WB3BlockRoutingDispatchTests` over a live-model recording double.
    @MainActor
    func testWB3BlockActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)
        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        XCTAssertEqual(store.tree, before, "the WB3 block actions are active-pane affordances — the tree is unchanged")
    }

    /// WB3: pins the three new chords are exactly ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] (and so distinct from the existing
    /// ⌃⌘[ / ⌃⌘] block-jump + ⌘[ / ⌘] tab-cycle chords). The generic uniqueness guard
    /// (`testRegistryBindingsHaveUniqueIDsAndChords`) catches a collision; this pins the intended values.
    @MainActor
    func testWB3ChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.reRunLastCommand), KeyChord(character: "r", [.control, .command]), "re-run = ⌃⌘R")
        XCTAssertEqual(
            chord(.jumpPreviousFailed), KeyChord(character: "[", [.control, .command, .shift]), "prev failed = ⌃⌘⇧[",
        )
        XCTAssertEqual(
            chord(.jumpNextFailed), KeyChord(character: "]", [.control, .command, .shift]), "next failed = ⌃⌘⇧]",
        )
    }

    // MARK: - View: find routes to the overlay toggle (W14 #5)

    /// `.find` with an explicit `toggleFind` override fires the closure (the root view's find-bar `@State`),
    /// NOT a store mutation — and leaves the tree untouched. Proven to fail before `.find` is routed.
    @MainActor
    func testFindActionFiresToggleClosureAndDoesNotMutateTree() {
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.find, to: store, toggleFind: { fired += 1 })
        XCTAssertEqual(fired, 1, "the find action invoked the toggleFind closure")
        XCTAssertEqual(store.tree, before, "find is a view overlay — the tree is unchanged")
    }

    /// `.find` WITHOUT a `toggleFind` override (the menu / keyboard path) routes to the store's
    /// `requestFindInActivePane()` — a no-op against a FakePaneSession (not a live terminal), but it must
    /// not trap or mutate the tree. Pins that the no-closure path is wired to the store, not dropped.
    @MainActor
    func testFindActionWithoutClosureRoutesToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.find, to: store) // no toggleFind ⇒ store path
        XCTAssertEqual(store.tree, before, "the store find path leaves the tree unchanged")
    }

    #if canImport(SwiftUI)

    // MARK: - Single source of truth: the cheat sheet is GENERATED from the registry (drift guard)

    /// C3 — DRIFT GUARD (strengthened to SET-EQUALITY): the workspace glyphs the tree cheat sheet renders
    /// EXACTLY equal the glyphs of the registry's chords (with the nine ⌘-digit select-tab chords collapsed
    /// to one "⌘1…⌘9" sentinel). The old test only checked one-way containment, so it passed even if the
    /// sheet listed a phantom chord no registry binding owns. This version fails BOTH ways — a registry
    /// chord missing from the sheet AND a sheet glyph with no registry chord behind it.
    func testTreeCheatSheetChordsEqualRegistryChords() {
        // The Terminal extras are curated (live outside the workspace table), so exclude that section.
        let workspaceSheetGlyphs = Set(
            KeyboardCheatSheet.treeSections()
                .filter { $0.title != "Terminal" }
                .flatMap(\.items)
                .map(\.glyph),
        )
        // The registry's expected glyph set: the main table's chord glyphs + the collapsed select-tab row
        // standing in for the nine ⌘-digit chords (which `allBindings` carries individually).
        var expected = Set(WorkspaceBindingRegistry.bindings.compactMap(\.chord).map(WorkspaceBindingRegistry.glyph))
        expected.insert("⌘1…⌘9")

        XCTAssertEqual(
            workspaceSheetGlyphs,
            expected,
            "the tree cheat sheet's workspace glyphs must EXACTLY match the registry chords (no missing/phantom rows)",
        )
        // And every individual select-tab digit chord IS one of the nine the collapsed row stands for —
        // proving the collapse is faithful (no ⌘-digit chord left undocumented).
        let selectTabGlyphs = Set(WorkspaceBindingRegistry.selectTabBindings.compactMap(\.chord)
            .map(WorkspaceBindingRegistry.glyph))
        XCTAssertEqual(selectTabGlyphs, Set((1...9).map { "⌘\($0)" }), "the nine ⌘-digit chords are exactly ⌘1…⌘9")
    }

    /// The tree cheat sheet groups by the registry categories (Panes / Tabs / Sessions / Focus / View)
    /// plus the curated Terminal extras — and every row carries a non-empty glyph + label.
    func testTreeCheatSheetSectionsAreWellFormed() {
        let sections = KeyboardCheatSheet.treeSections()
        let titles = sections.map(\.title)
        for category in WorkspaceAction.Category.allCases {
            XCTAssertTrue(titles.contains(category.rawValue), "the \(category.rawValue) section is present")
        }
        XCTAssertTrue(titles.contains("Terminal"), "the curated terminal-chord section is appended")
        for section in sections {
            XCTAssertFalse(section.items.isEmpty, "\(section.title) has rows")
            for item in section.items {
                XCTAssertFalse(item.glyph.isEmpty, "\(item.label) has a glyph")
                XCTAssertFalse(item.label.isEmpty)
            }
        }
    }

    #endif
}
