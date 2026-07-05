import XCTest
@testable import SlopDeskWorkspaceCore

/// E3 WI-3 (ES-E3-1): pins the TREE shell's "Reopen Closed Tab" LIFO — the ⇧⌘T chord that brings back the
/// most recently closed tab (its split tree + every pane's spec + the owning session), distinct from the
/// canvas single-slot ``WorkspaceStore/reopenClosedPane()`` (which is a separate, retained-but-dead
/// mechanism on the infinite-canvas path).
///
/// Captured before any TAB-removing close — both the explicit ``WorkspaceStore/closeTab(_:)`` and the
/// implicit sole-leaf ``WorkspaceStore/closePaneTree(_:)`` cascade — and popped LIFO into the active
/// session (or, when the owning session vanished while the record sat on the stack, the active session as
/// a fallback). In-memory only, bounded at ``WorkspaceStore/recentlyClosedTabsCap``. The store is
/// `.tree`-live and backed by the `FakePaneSession` seam — no real `SlopDeskClient` / `HostServer`.
@MainActor
final class ReopenClosedTabTreeTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree`, backed by the `FakePaneSession` seam.
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// A single-session workspace with one single-leaf tab per `title` (each leaf a terminal pane whose
    /// spec title equals the tab title, so a restored tab is identifiable). The first tab is active.
    /// Returns the workspace plus parallel arrays of the tab ids and pane ids, in `titles` order.
    private func tabbedWorkspace(_ titles: [String]) -> (TreeWorkspace, [TabID], [PaneID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var tabIDs: [TabID] = []
        var paneIDs: [PaneID] = []
        for title in titles {
            let pane = PaneID()
            let tab = Tab(title: title, root: .leaf(pane), activePane: pane)
            tabs.append(tab)
            specs[pane] = PaneSpec(kind: .terminal, title: title)
            tabIDs.append(tab.id)
            paneIDs.append(pane)
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), tabIDs, paneIDs)
    }

    private func activeTabTitle(_ store: WorkspaceStore) -> String? {
        store.tree.activeSession?.activeTab?.title
    }

    // MARK: - closeTab captures + reopen restores

    /// Closing a tab records it on the LIFO; ⇧⌘T (``reopenLastClosedPane()``) re-inserts it (selected,
    /// reusing the original pane id + spec) and consumes the slot.
    func testCloseTabThenReopenRestoresIt() {
        let (ws, tabIDs, paneIDs) = tabbedWorkspace(["A", "B", "C"])
        let store = makeTreeStore(restoringTree: ws)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3)

        store.closeTab(tabIDs[1]) // close "B"
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "tab B closed")
        XCTAssertFalse(store.tree.activeSession?.tabs.contains { $0.title == "B" } ?? true, "B gone from the tree")
        XCTAssertEqual(store.recentlyClosedTabs.count, 1, "B captured on the LIFO")

        store.reopenLastClosedPane()
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3, "B restored")
        XCTAssertEqual(activeTabTitle(store), "B", "the reopened tab is selected")
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty, "the slot is consumed")
        // The restored pane reuses its ORIGINAL id + spec, and a FRESH idle session materializes for it.
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, paneIDs[1], "original pane id reused")
        XCTAssertEqual(store.tree.spec(for: paneIDs[1])?.title, "B", "the spec came back")
        XCTAssertNotNil(store.handle(for: paneIDs[1]), "a fresh session materialized for the restored pane")
    }

    // MARK: - Sole-leaf close cascades the whole tab → captured

    /// Closing a tab's ONLY tiled leaf via ``closePaneTree(_:)`` cascades the whole tab away — and is
    /// captured for reopen exactly like an explicit `closeTab`.
    func testCloseSoleLeafOfTabCapturesTheTab() {
        let (ws, _, paneIDs) = tabbedWorkspace(["A", "B"])
        let store = makeTreeStore(restoringTree: ws)

        store.closePaneTree(paneIDs[0]) // the sole leaf of tab A → tab A cascades away
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "tab A cascaded away")
        XCTAssertEqual(store.recentlyClosedTabs.count, 1, "the sole-leaf close captured tab A")

        store.reopenLastClosedPane()
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "tab A restored")
        XCTAssertTrue(store.tree.activeSession?.tabs.contains { $0.title == "A" } ?? false, "A is back")
        XCTAssertEqual(store.tree.spec(for: paneIDs[0])?.title, "A", "the restored leaf's spec came back")
    }

    /// Closing ONE pane of a multi-pane tab leaves the tab alive, so NOTHING is captured — guards against
    /// the naive "record on every `closePaneTree`" that would falsely stack a still-open tab. (Reverting
    /// the `tabRemovedByClosing` guard to "always record" makes this assertion FAIL.)
    func testClosingOneOfSeveralPanesDoesNotCaptureTab() {
        let a = PaneID(), b = PaneID()
        let children = [a, b].map { WeightedChild(weight: .flex(1), node: .leaf($0)) }
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: children)
        let tab = Tab(title: "Split", root: root, activePane: a)
        let specs: [PaneID: PaneSpec] = [
            a: PaneSpec(kind: .terminal, title: "A"),
            b: PaneSpec(kind: .terminal, title: "B"),
        ]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let store = makeTreeStore(restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id))

        store.closePaneTree(a) // tab survives (b remains) → no tab removed → nothing captured
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "the tab is still alive")
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty, "closing one of several panes captures no tab")
    }

    // MARK: - LIFO order

    /// Multiple closes pop in last-in-first-out order.
    func testMultipleClosesPopInLIFOOrder() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C", "D"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // close A (by id — index-shift-safe)
        store.closeTab(tabIDs[2]) // close C
        XCTAssertEqual(store.recentlyClosedTabs.count, 2)

        store.reopenLastClosedPane() // pops the LAST close first → C
        XCTAssertEqual(activeTabTitle(store), "C", "LIFO: the last-closed tab reopens first")
        store.reopenLastClosedPane() // then A
        XCTAssertEqual(activeTabTitle(store), "A")
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty, "both records consumed")
    }

    // MARK: - Index-addressed reopen (E11 review fix: Recent rows reopen the RIGHT tab)

    /// `reopenClosedTab(at:)` reopens EXACTLY the tab at the given LIFO index, not always the newest. Close
    /// A,B,C,D (leaving E so the session never re-seeds), so the LIFO (newest-first) is D(0),C(1),B(2),A(3);
    /// `reopenClosedTab(at: 2)` must restore B — the second-OLDEST close. The default `reopenLastClosedPane()`
    /// (= `at: 0`) would restore D, so asserting B here FAILS against the old `popLast()`-everything routing
    /// the Recent rows used (revert-to-confirm-fail: replace the body with `reopenLastClosedPane()` → "B" ≠ "D").
    func testReopenClosedTabAtIndexRestoresThatTabNotTheNewest() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C", "D", "E"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // A
        store.closeTab(tabIDs[1]) // B
        store.closeTab(tabIDs[2]) // C
        store.closeTab(tabIDs[3]) // D
        XCTAssertEqual(store.recentlyClosedTabs.count, 4, "A,B,C,D captured (oldest→newest)")

        let reopened = store.reopenClosedTab(at: 2) // LIFO top is D(0); index 2 = B (second-oldest)

        XCTAssertEqual(activeTabTitle(store), "B", "index 2 reopens B (NOT the newest D the old popLast did)")
        XCTAssertNotNil(reopened, "the restored tab's active pane id is returned")
        XCTAssertEqual(store.recentlyClosedTabs.count, 3, "exactly B's record is consumed")
        XCTAssertFalse(store.recentlyClosedTabs.contains { $0.tab.title == "B" }, "B is no longer on the LIFO")
        XCTAssertTrue(
            ["A", "C", "D"].allSatisfy { t in store.recentlyClosedTabs.contains { $0.tab.title == t } },
            "the other three records survive untouched",
        )
    }

    /// An out-of-range LIFO index (≥ count, or negative) is a graceful `nil` no-op — never a trap and never a
    /// reopen of an adjacent tab. Pins the bounds check the picker relies on (a row index over UI state).
    func testReopenClosedTabOutOfRangeIndexIsANoOp() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // one record on the LIFO
        XCTAssertEqual(store.recentlyClosedTabs.count, 1)

        XCTAssertNil(store.reopenClosedTab(at: 5), "index past the end is nil")
        XCTAssertNil(store.reopenClosedTab(at: -1), "a negative index is nil")

        XCTAssertEqual(store.recentlyClosedTabs.count, 1, "no record consumed by an out-of-range reopen")
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "the tree is untouched")
    }

    // MARK: - Vanished owning session → fallback to active

    /// A reopen whose owning session was closed (here: emptied by closing its last tab) lands the tab in
    /// the ACTIVE session rather than resurrecting the dead one.
    func testReopenAfterOwningSessionVanishedLandsInActiveSession() {
        let pA = PaneID(), pB = PaneID(), pX = PaneID()
        let tabA = Tab(title: "A", root: .leaf(pA), activePane: pA)
        let tabB = Tab(title: "B", root: .leaf(pB), activePane: pB)
        let s1 = Session(
            name: "One",
            tabs: [tabA, tabB],
            activeTabIndex: 0,
            specs: [pA: PaneSpec(kind: .terminal, title: "A"), pB: PaneSpec(kind: .terminal, title: "B")],
        )
        let s2 = Session(
            name: "Two",
            tabs: [Tab(title: "X", root: .leaf(pX), activePane: pX)],
            activeTabIndex: 0,
            specs: [pX: PaneSpec(kind: .terminal, title: "X")],
        )
        let store = makeTreeStore(restoringTree: TreeWorkspace(sessions: [s1, s2], activeSessionID: s1.id))
        XCTAssertEqual(store.tree.sessions.count, 2)

        store.closeTab(s1.tabs[0].id) // S1 → [B]
        store.closeTab(s1.tabs[1].id) // S1 emptied → session S1 removed; active falls to S2
        XCTAssertEqual(store.tree.sessions.count, 1, "session S1 cascaded away")
        XCTAssertEqual(store.tree.activeSession?.id, s2.id)

        store.reopenLastClosedPane() // pops B (owner S1, now gone) → falls back to the active session S2
        XCTAssertEqual(store.tree.sessions.count, 1, "the dead session is NOT resurrected")
        XCTAssertEqual(store.tree.activeSession?.id, s2.id, "the tab lands in the active session")
        XCTAssertEqual(activeTabTitle(store), "B", "B reopened in S2")
        XCTAssertEqual(store.tree.spec(for: pB)?.title, "B")
        XCTAssertNotNil(store.handle(for: pB), "a fresh session materialized for the restored pane")
    }

    // MARK: - Empty stack is a no-op

    /// ⇧⌘T with nothing recorded leaves the tree untouched.
    func testReopenWithEmptyStackIsNoOp() {
        let (ws, _, _) = tabbedWorkspace(["A", "B"])
        let store = makeTreeStore(restoringTree: ws)
        XCTAssertTrue(store.recentlyClosedTabs.isEmpty)

        store.reopenLastClosedPane()

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "no-op when the LIFO is empty")
    }

    // MARK: - Ephemeral system-dialog tabs are never recorded

    /// An auto-managed system-dialog tab (an all-ephemeral overlay) is NEVER stacked for reopen — the
    /// monitor owns its lifecycle, so "reopening" it would resurrect a dead window stream (mirrors the
    /// canvas `closePane(_:)` `!isEphemeral` reopen-slot guard). Reverting the ephemeral guard in
    /// `recordClosedTab` makes this FAIL (the dialog tab would record).
    func testEphemeralSystemDialogTabIsNotRecorded() {
        let (ws, _, _) = tabbedWorkspace(["A"])
        let store = makeTreeStore(restoringTree: ws)
        // Spawns an ephemeral `.systemDialog` pane in its own transient tab on the tree shell.
        let dialogID = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "sudo", isSecure: true)

        store.closeSystemDialogPane(dialogID) // the monitor's auto-close (routes through closePaneTree)

        XCTAssertTrue(store.recentlyClosedTabs.isEmpty, "an ephemeral system-dialog tab is never recorded for reopen")
    }

    // MARK: - Bounded LIFO (cap)

    /// The LIFO is bounded at ``WorkspaceStore/recentlyClosedTabsCap`` — closing more than the cap drops
    /// the OLDEST records, keeping the most recent ones.
    func testLIFOIsBoundedAtCap() {
        let cap = WorkspaceStore.recentlyClosedTabsCap
        let titles = (0..<(cap + 5)).map { "T\($0)" }
        let (ws, tabIDs, _) = tabbedWorkspace(titles)
        let store = makeTreeStore(restoringTree: ws)

        // Close the first cap+4 tabs by id (leaving ≥1 so the session never re-seeds a default mid-loop).
        for i in 0..<(cap + 4) { store.closeTab(tabIDs[i]) }

        XCTAssertEqual(store.recentlyClosedTabs.count, cap, "the LIFO is bounded at the cap")
        XCTAssertEqual(store.recentlyClosedTabs.last?.tab.title, "T\(cap + 3)", "the most recent close is on top")
        XCTAssertFalse(store.recentlyClosedTabs.contains { $0.tab.title == "T0" }, "the oldest record dropped off")
    }
}
