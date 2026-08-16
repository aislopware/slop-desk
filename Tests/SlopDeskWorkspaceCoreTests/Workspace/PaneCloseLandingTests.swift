import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// WHERE THE KEYBOARD LANDS WHEN A PANE CLOSES. The tree op's own refocus is the closing pane's
/// geometric NEIGHBOUR, so in an `A | B | C` row closing `B` always hands the keyboard to `A` — however
/// long the user had been working between `C` and `B` (user-reported 2026-08-10: "it focuses some
/// arbitrary pane"). The store names the landing from its visit ring instead, and says it as a focus
/// INTENT so every client agrees on it.
///
/// Pins the pure pick (``WorkspaceStore/mostRecentSurvivor(mru:survivors:)``); the store wiring that
/// feeds it is exercised by the close paths in `WorkspaceStoreTreeTests`.
@MainActor
final class PaneCloseLandingTests: XCTestCase {
    func testTheMostRecentSURVIVORWins() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        // The ring's front is the pane being closed; `c` is where the user was before it.
        XCTAssertEqual(
            WorkspaceStore.mostRecentSurvivor(mru: [b, c, a], survivors: [a, c]),
            c,
            "the pane the user was just in, not the first survivor in tree order",
        )
    }

    func testDeadRingEntriesAreSkipped() {
        let a = PaneID(), ghost = PaneID()
        // The ring is never pruned on close (the switcher intersects with the live set instead), so
        // the pick has to walk past ids nothing can focus any more.
        XCTAssertEqual(WorkspaceStore.mostRecentSurvivor(mru: [ghost, a], survivors: [a]), a)
    }

    func testARingWithNoLiveSurvivorDecidesNothing() {
        // Nothing recorded, or nothing recorded that is still open — the tree op's neighbour rule
        // stands rather than being overridden with a guess.
        XCTAssertNil(WorkspaceStore.mostRecentSurvivor(mru: [], survivors: [PaneID()]))
        XCTAssertNil(WorkspaceStore.mostRecentSurvivor(mru: [PaneID()], survivors: [PaneID()]))
    }

    // MARK: - Store wiring (the reported repro)

    /// THE REPRO. Three panes in a row; the user works in `c`, then in `b`, then closes `b`. The tree
    /// op's geometric rule hands that to `a` (pinned by `WorkspaceTreeOpsTests`); the keyboard belongs
    /// in `c`.
    func testClosingTheActivePaneLandsWhereTheUserJustWas() {
        let store = makeStore()
        let (a, b, c) = threePaneRow(in: store)

        store.focusPaneTree(c)
        store.focusPaneTree(b)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, b)

        store.closePaneTree(b)

        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, c,
            "the pane the user was just in, not b's geometric neighbour a",
        )
        XCTAssertFalse(store.tree.contains(b))
        XCTAssertTrue(store.tree.contains(a))
    }

    /// Closing a pane the user is NOT in must not move the keyboard at all — the landing question
    /// only arises for the pane that has it.
    func testClosingABackgroundPaneLeavesFocusAlone() {
        let store = makeStore()
        let (a, b, c) = threePaneRow(in: store)

        store.focusPaneTree(a)
        store.focusPaneTree(c)
        store.closePaneTree(b)

        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, c)
    }

    /// The last two panes have exactly one answer, and the ring must not invent a different one.
    func testTheFinalSurvivorTakesTheFocusWithoutTheRing() {
        let store = makeStore()
        let (a, b, _) = threePaneRow(in: store)

        store.focusPaneTree(b)
        store.closePaneTree(a)
        store.closePaneTree(b)

        XCTAssertEqual(store.tree.activeSession?.activeTab?.allPaneIDs().count, 1)
        XCTAssertNotNil(store.tree.activeSession?.activeTab?.activePane)
    }

    // MARK: - Focus intent (what the landing cannot say on its own)

    /// The two choke points record WHICH was asked for, so the shell can tell a tab switch from a
    /// cross-tab pane jump — they land identically otherwise. See ``WorkspaceStore/FocusIntent``.
    func testTheChokePointsRecordWhatTheyNamed() {
        let store = makeStore()
        let (a, b, _) = threePaneRow(in: store)

        store.focusPaneTree(a)
        let firstJump = store.lastFocusIntent
        XCTAssertEqual(firstJump?.kind, .pane)

        store.focusPaneTree(b)
        XCTAssertEqual(store.lastFocusIntent?.kind, .pane)
        XCTAssertNotEqual(
            store.lastFocusIntent?.seq, firstJump?.seq,
            "a repeat of the same KIND still has to read as a new intent",
        )

        store.newTab(kind: .terminal)
        store.selectTab(0)
        XCTAssertEqual(store.lastFocusIntent?.kind, .tab)
    }

    /// A focus move that passes through NEITHER choke point (here: a split's new leaf) leaves the
    /// sequence standing still — that is how the shell knows the landing moved on its own.
    func testASplitRecordsNoIntent() {
        let store = makeStore()
        let (a, _, _) = threePaneRow(in: store)
        store.focusPaneTree(a)
        let before = store.lastFocusIntent

        store.splitPaneTree(a, axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.lastFocusIntent, before)
    }

    // MARK: - Harness

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// `a | b | c` in one tab, in that order.
    private func threePaneRow(in store: WorkspaceStore) -> (PaneID, PaneID, PaneID) {
        let a = store.tree.activeSession?.activeTab?.activePane
        store.splitPaneTree(a ?? PaneID(), axis: .horizontal, kind: .terminal)
        let b = store.tree.activeSession?.activeTab?.activePane
        store.splitPaneTree(b ?? PaneID(), axis: .horizontal, kind: .terminal)
        let c = store.tree.activeSession?.activeTab?.activePane
        let ids = store.tree.activeSession?.activeTab?.allPaneIDs() ?? []
        XCTAssertEqual(ids.count, 3, "the row the geometric rule is measured against")
        XCTAssertEqual(ids, [a, b, c].compactMap(\.self), "split inserts after its target")
        return (a ?? PaneID(), b ?? PaneID(), c ?? PaneID())
    }
}
