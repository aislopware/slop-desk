// TabSidePartitionTests — pins the TabSide partition (terminal ⟂ remote-window columns): the pure side
// derivation, the per-side displayed-tab resolution + stamping, the side-scoped tab cycling / ⌘N
// numbering, and the mixed-tab break-out on a chooser resolution.
//
// Headless: a tree-model `WorkspaceStore` over the `FakePaneSession` fake (no socket / video / Metal —
// hang-safety).

import XCTest
@testable import AislopdeskWorkspaceCore

@MainActor
final class TabSidePartitionTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    /// Opens a `.remoteGUI` tab on `store` and returns its id.
    @discardableResult
    private func openGuiTab(_ store: WorkspaceStore) -> TabID {
        store.newRemoteWindowTab(windowID: 42, title: "Xcode — main.swift", appName: "Xcode")
        return store.tree.activeSession!.activeTab!.id
    }

    // MARK: Side derivation (pure)

    func testSideDerivation() throws {
        let store = makeStore()
        let session = try XCTUnwrap(store.tree.activeSession)
        let terminalTab = try XCTUnwrap(session.activeTab)
        XCTAssertEqual(session.side(ofTab: terminalTab), .terminal, "a terminal tab is terminal-side")

        openGuiTab(store)
        let after = try XCTUnwrap(store.tree.activeSession)
        let guiTab = try XCTUnwrap(after.activeTab)
        XCTAssertEqual(after.side(ofTab: guiTab), .gui, "a remote-window tab is gui-side")
    }

    func testChooserOnlyTabIsTerminalSideUntilResolved() throws {
        let store = makeStore()
        // A persisted-LEGACY chooser tab (the gesture no longer mints one) — minted directly for the pin.
        store.newTab(kind: .chooser, launchGrace: .zero)
        let session = try XCTUnwrap(store.tree.activeSession)
        let chooserTab = try XCTUnwrap(session.activeTab)
        XCTAssertEqual(
            session.side(ofTab: chooserTab), .terminal,
            "an undecided chooser tab stays on the terminal side (it must not flash the GUI column open)",
        )
        // Resolving the chooser to a remote window flips the SAME tab to the gui side (no new tab needed).
        let pane = try XCTUnwrap(chooserTab.activePane)
        store.choosePaneKind(pane, kind: .remoteGUI, launchGrace: .zero)
        let resolved = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(
            try resolved.side(ofTab: XCTUnwrap(resolved.activeTab)), .gui,
            "a chooser tab that resolves to Remote window migrates to the gui side in place",
        )
    }

    func testMixedTabIsTerminalSideAndDetected() {
        let store = makeStore()
        // Build a mixed tab by hand (persisted-legacy shape): terminal + remoteGUI in one split tree.
        let a = PaneID(), b = PaneID()
        let tab = Tab(root: .split(
            id: SplitNodeID(), axis: .horizontal,
            children: [
                WeightedChild(weight: .flex(1), node: .leaf(a)),
                WeightedChild(weight: .flex(1), node: .leaf(b)),
            ],
        ), activePane: a)
        let session = Session(
            name: "S", tabs: [tab],
            specs: [
                a: PaneSpec(kind: .terminal, title: "Terminal"),
                b: PaneSpec(kind: .remoteGUI, title: "W", video: VideoEndpoint(windowID: 1, title: "W")),
            ],
        )
        XCTAssertEqual(session.side(ofTab: tab), .terminal, "a mixed tab anchors to the terminal column")
        XCTAssertTrue(session.isMixedTab(tab))
    }

    // MARK: Displayed-tab resolution (each column keeps its own tab while focus is in the other)

    func testDisplayedTabPerSideSurvivesFocusInOtherColumn() throws {
        let store = makeStore()
        let terminalTabID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let guiTabID = openGuiTab(store)

        // Focus lives on the GUI tab (it was just created + selected) …
        XCTAssertEqual(store.displayedTabID(on: .gui), guiTabID)
        // … while the terminal column keeps displaying its own last tab.
        XCTAssertEqual(store.displayedTabID(on: .terminal), terminalTabID)

        // Focus back to the terminal tab: the GUI column keeps ITS tab.
        store.selectTab(id: terminalTabID)
        XCTAssertEqual(store.displayedTabID(on: .terminal), terminalTabID)
        XCTAssertEqual(store.displayedTabID(on: .gui), guiTabID)
    }

    func testDisplayedTabFallsBackWhenRememberedTabCloses() throws {
        let store = makeStore()
        let terminalTabID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let gui1 = openGuiTab(store)
        let gui2 = openGuiTab(store)
        XCTAssertNotEqual(gui1, gui2)

        // Focus the terminal side, then close the GUI side's remembered (last-displayed) tab.
        store.selectTab(id: terminalTabID)
        XCTAssertEqual(store.displayedTabID(on: .gui), gui2, "last-active GUI tab is remembered")
        store.closeTab(gui2)
        XCTAssertEqual(
            store.displayedTabID(on: .gui), gui1,
            "a closed remembered tab falls back to the side's first live tab",
        )
        store.closeTab(gui1)
        XCTAssertNil(store.displayedTabID(on: .gui), "no GUI tabs ⇒ the column shows its empty state")
        XCTAssertEqual(store.tabCount(on: .gui), 0)
    }

    // MARK: Side-scoped cycling + terminal-scoped ⌘N numbering

    func testCycleTabStaysWithinSide() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // terminal tab #2
        let terminal2 = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        openGuiTab(store) // gui tab, index 2, now active

        // Cycling from the GUI tab must NOT step into the terminal tabs (it is the only GUI tab → no-op).
        let before = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        store.cycleTab(by: -1)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, before, "single GUI tab: cycling is a no-op")

        // From a terminal tab, cycling steps through terminal tabs only (skipping the GUI tab between/after).
        store.selectTab(id: terminal2)
        store.cycleTab(by: -1)
        XCTAssertEqual(
            store.tree.activeSession?.activeTabIndex, 0,
            "cycling back from terminal #2 lands on terminal #1",
        )
        store.cycleTab(by: 1)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, terminal2, "and forward returns to terminal #2")
    }

    func testSelectTabNumberCountsTerminalTabsOnly() throws {
        let store = makeStore()
        openGuiTab(store) // gui tab at index 1
        store.newTab(kind: .terminal, launchGrace: .zero) // terminal #2 (index 2)
        let terminal2 = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)

        store.selectTabNumber(2)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, terminal2,
            "⌘2 targets the SECOND TERMINAL tab, skipping the GUI tab at raw index 1",
        )
        store.selectTabNumber(3)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, terminal2,
            "a number past the terminal tab count is a no-op (never lands on a GUI tab)",
        )
    }

    // MARK: Mixed-tab break-out (a LEGACY chooser pane resolving across the partition)

    // The gesture path no longer mints choosers (a split is side-pure by construction), but a PERSISTED
    // legacy chooser can still resolve to the other side — the break-out keeps the partition clean.

    func testLegacyChooserResolvingToRemoteWindowBreaksOutToOwnTab() throws {
        let store = makeStore()
        let terminalTabID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        // A legacy chooser split beside the terminal (minted directly — the gesture no longer does).
        store.splitActivePane(axis: .horizontal, kind: .chooser, leading: false, launchGrace: .zero)
        let chooser = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.choosePaneKind(chooser, kind: .remoteGUI, launchGrace: .zero)

        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session.tabs.count, 2, "the video pane broke out into its own tab")
        XCTAssertFalse(session.tabs.contains(where: session.isMixedTab), "no mixed tab survives the pick")
        let terminalTab = try XCTUnwrap(session.tabs.first { $0.id == terminalTabID })
        XCTAssertEqual(terminalTab.root.leafCount, 1, "the source terminal tab collapsed back to one leaf")
        XCTAssertEqual(
            try session.side(ofTab: XCTUnwrap(session.activeTab)), .gui,
            "the broken-out video tab is gui-side and selected",
        )
        XCTAssertEqual(session.activeTab?.activePane, chooser, "focus stays on the resolved pane")
    }

    func testLegacyChooserResolvingToTerminalInGuiTabBreaksOut() throws {
        let store = makeStore()
        openGuiTab(store)
        store.splitActivePane(axis: .vertical, kind: .chooser, leading: false, launchGrace: .zero)
        let chooser = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.choosePaneKind(chooser, kind: .terminal, launchGrace: .zero)

        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertFalse(session.tabs.contains(where: session.isMixedTab), "no mixed tab survives the pick")
        XCTAssertEqual(
            try session.side(ofTab: XCTUnwrap(session.activeTab)), .terminal,
            "the terminal pane broke out into a terminal-side tab",
        )
    }
}
