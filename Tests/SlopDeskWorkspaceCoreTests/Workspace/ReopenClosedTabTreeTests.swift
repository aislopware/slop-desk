import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the TREE shell's "Reopen Closed Tab" LIFO — the ⇧⌘T chord that brings back the
/// most recently closed tab (its split tree + every pane's spec + the owning session), distinct from the
/// canvas single-slot ``WorkspaceStore/reopenClosedPane()`` (which is a separate, retained-but-dead
/// mechanism on the infinite-canvas path).
///
/// Captured before any TAB-removing close — both the explicit ``WorkspaceStore/closeTab(_:)`` and the
/// implicit sole-leaf ``WorkspaceStore/closePaneTree(_:)`` cascade — and popped LIFO into the active
/// session (or, when the owning session vanished while the record sat on the stack, the active session as
/// a fallback). The ring is the DOCUMENT's (``WorkspaceStore/closedTabRecords``, newest FIRST), bounded
/// at ``WorkspaceTopology/closedTabRingCap``. The store is `.tree`-live and backed by the
/// `FakePaneSession` seam — no real `SlopDeskClient` / `HostServer`.
@MainActor
final class ReopenClosedTabTreeTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree`, backed by the `FakePaneSession` seam.
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
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
        XCTAssertEqual(store.closedTabRecords.count, 1, "B captured on the ring")

        store.reopenLastClosedPane()
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3, "B restored")
        XCTAssertEqual(activeTabTitle(store), "B", "the reopened tab is selected")
        XCTAssertTrue(store.closedTabRecords.isEmpty, "the slot is consumed")
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
        XCTAssertEqual(store.closedTabRecords.count, 1, "the sole-leaf close captured tab A")

        store.reopenLastClosedPane()
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "tab A restored")
        XCTAssertTrue(store.tree.activeSession?.tabs.contains { $0.title == "A" } ?? false, "A is back")
        XCTAssertEqual(store.tree.spec(for: paneIDs[0])?.title, "A", "the restored leaf's spec came back")
    }

    /// Closing ONE pane of a multi-pane tab leaves the tab alive, so NOTHING is captured — guards against
    /// the naive "record on every `closePaneTree`" that would falsely stack a still-open tab. (Relaxing the
    /// sole-leaf guard to "always record" makes this assertion FAIL.)
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
        XCTAssertTrue(store.closedTabRecords.isEmpty, "closing one of several panes captures no tab")
    }

    // MARK: - LIFO order

    /// Multiple closes pop in last-in-first-out order.
    func testMultipleClosesPopInLIFOOrder() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C", "D"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // close A (by id — index-shift-safe)
        store.closeTab(tabIDs[2]) // close C
        XCTAssertEqual(store.closedTabRecords.count, 2)

        store.reopenLastClosedPane() // pops the LAST close first → C
        XCTAssertEqual(activeTabTitle(store), "C", "LIFO: the last-closed tab reopens first")
        store.reopenLastClosedPane() // then A
        XCTAssertEqual(activeTabTitle(store), "A")
        XCTAssertTrue(store.closedTabRecords.isEmpty, "both records consumed")
    }

    // MARK: - Index-addressed reopen (Recent rows reopen the RIGHT tab)

    /// `reopenClosedTab(at:)` reopens EXACTLY the tab at the given LIFO index, not always the newest. Close
    /// A,B,C,D (leaving E so the session never re-seeds), so the LIFO (newest-first) is D(0),C(1),B(2),A(3);
    /// `reopenClosedTab(at: 2)` must restore B — the second-OLDEST close. The default `reopenLastClosedPane()`
    /// (= `at: 0`) would restore D, so asserting B here catches any regression that routes every Recent row
    /// through `reopenLastClosedPane()` instead of the given index (replace the body with that call → "B" ≠ "D").
    func testReopenClosedTabAtIndexRestoresThatTabNotTheNewest() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C", "D", "E"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // A
        store.closeTab(tabIDs[1]) // B
        store.closeTab(tabIDs[2]) // C
        store.closeTab(tabIDs[3]) // D
        XCTAssertEqual(store.closedTabRecords.count, 4, "A,B,C,D captured (newest first)")

        let reopened = store.reopenClosedTab(at: 2) // LIFO top is D(0); index 2 = B (second-oldest)

        XCTAssertEqual(activeTabTitle(store), "B", "index 2 reopens B (NOT the newest D the old popLast did)")
        XCTAssertNotNil(reopened, "the restored tab's active pane id is returned")
        XCTAssertEqual(store.closedTabRecords.count, 3, "exactly B's record is consumed")
        XCTAssertFalse(store.closedTabRecords.contains { $0.tab.title == "B" }, "B is no longer on the ring")
        XCTAssertTrue(
            ["A", "C", "D"].allSatisfy { t in store.closedTabRecords.contains { $0.tab.title == t } },
            "the other three records survive untouched",
        )
    }

    /// An out-of-range LIFO index (≥ count, or negative) is a graceful `nil` no-op — never a trap and never a
    /// reopen of an adjacent tab. Pins the bounds check the picker relies on (a row index over UI state).
    func testReopenClosedTabOutOfRangeIndexIsANoOp() {
        let (ws, tabIDs, _) = tabbedWorkspace(["A", "B", "C"])
        let store = makeTreeStore(restoringTree: ws)
        store.closeTab(tabIDs[0]) // one record on the LIFO
        XCTAssertEqual(store.closedTabRecords.count, 1)

        XCTAssertNil(store.reopenClosedTab(at: 5), "index past the end is nil")
        XCTAssertNil(store.reopenClosedTab(at: -1), "a negative index is nil")

        XCTAssertEqual(store.closedTabRecords.count, 1, "no record consumed by an out-of-range reopen")
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
        XCTAssertTrue(store.closedTabRecords.isEmpty)

        store.reopenLastClosedPane()

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "no-op when the LIFO is empty")
    }

    // MARK: - The tab-close-recorded hook (the "TAB CLOSED · ⇧⌘T REOPENS" cue's source)

    /// ``WorkspaceStore/onTabCloseRecorded`` fires exactly when a REOPENABLE tab lands on the LIFO —
    /// the app wires it to the transient undo-affordance chip, so the hook must track the record
    /// one-to-one: fire for a real close (the chip's promise is honest — ⇧⌘T will work), stay silent
    /// for a pane close that leaves its tab alive (nothing was lost).
    func testTabCloseRecordedHookTracksTheRecordExactly() {
        let (ws, tabIDs, paneIDs) = tabbedWorkspace(["A", "B"])
        let store = makeTreeStore(restoringTree: ws)
        var fired = 0
        store.onTabCloseRecorded = { fired += 1 }

        store.closeTab(tabIDs[0])
        XCTAssertEqual(fired, 1, "an explicit tab close records ⇒ the hook fires")

        store.closePaneTree(paneIDs[1]) // sole leaf ⇒ the cascade removes the tab ⇒ records
        XCTAssertEqual(fired, 2, "a sole-leaf pane close cascades the tab away ⇒ the hook fires")
    }

    /// A pane close that leaves its tab alive records nothing ⇒ the hook stays silent (the tab — and
    /// the ⇧⌘T affordance — did not change).
    func testPaneCloseThatKeepsTabAliveDoesNotFireTheHook() {
        let (ws, _, paneIDs) = tabbedWorkspace(["A"])
        let store = makeTreeStore(restoringTree: ws)
        store.splitPaneTree(paneIDs[0], axis: .horizontal, kind: .terminal) // two leaves — tab survives one close
        var fired = 0
        store.onTabCloseRecorded = { fired += 1 }

        store.closePaneTree(paneIDs[0])
        XCTAssertEqual(fired, 0, "closing one of several leaves keeps the tab ⇒ no record, no cue")
    }

    /// The cue survives a FULL ring.
    ///
    /// RED before the hook asked about the ring's newest RECORD: the applier trims to
    /// ``WorkspaceTopology/closedTabRingCap`` right after appending, so a `count` comparison stops
    /// growing at the cap. The ring is host-persisted and shared, so it reaches the cap and stays
    /// there — every close from that moment on would lose the ⇧⌘T affordance for good, while ⇧⌘T
    /// itself still worked.
    func testTheHookStillFiresOnceTheRingIsFull() {
        let cap = WorkspaceTopology.closedTabRingCap
        let (ws, tabIDs, _) = tabbedWorkspace((0..<(cap + 2)).map { "T\($0)" })
        let store = makeTreeStore(restoringTree: ws)
        for i in 0..<cap { store.closeTab(tabIDs[i]) }
        XCTAssertEqual(store.closedTabRecords.count, cap, "the ring is full")
        var fired = 0
        store.onTabCloseRecorded = { fired += 1 }

        store.closeTab(tabIDs[cap])

        XCTAssertEqual(store.closedTabRecords.first?.tab.id, tabIDs[cap], "the tab IS reopenable")
        XCTAssertEqual(fired, 1, "…so the undo affordance is offered")
    }

    // MARK: - Bounded LIFO (cap)

    /// The ring is bounded at ``WorkspaceTopology/closedTabRingCap`` — closing more than the cap drops
    /// the OLDEST records, keeping the most recent ones.
    func testLIFOIsBoundedAtCap() {
        let cap = WorkspaceTopology.closedTabRingCap
        let titles = (0..<(cap + 5)).map { "T\($0)" }
        let (ws, tabIDs, _) = tabbedWorkspace(titles)
        let store = makeTreeStore(restoringTree: ws)

        // Close the first cap+4 tabs by id (leaving ≥1 so the session never re-seeds a default mid-loop).
        for i in 0..<(cap + 4) { store.closeTab(tabIDs[i]) }

        XCTAssertEqual(store.closedTabRecords.count, cap, "the ring is bounded at the cap")
        XCTAssertEqual(store.closedTabRecords.first?.tab.title, "T\(cap + 3)", "the most recent close is on top")
        XCTAssertFalse(store.closedTabRecords.contains { $0.tab.title == "T0" }, "the oldest record dropped off")
    }
}
