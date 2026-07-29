import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ⌃⇥ switcher against a LIVE tree store: that it reads the host-owned `focusMRU` ring, that
/// walking the highlight stages no focus intent, and that only a commit moves the active tab.
///
/// The load-bearing distinction this suite exists to pin: ⌃⇥ is RECENCY-ordered while ⌘⇧]/⌘⇧[ is
/// POSITION-ordered. A fixture where the two agree proves nothing, so every switch assertion below is
/// built on a visit order where the recency answer and the positional answer differ.
@MainActor
final class TabSwitcherStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func tabIDs(_ store: WorkspaceStore) -> [TabID] {
        store.tree.activeSession?.tabs.map(\.id) ?? []
    }

    private func activeTab(_ store: WorkspaceStore) -> TabID? {
        store.tree.activeSession?.activeTab?.id
    }

    /// Builds a three-tab session and leaves the visit order A → C → A, so:
    ///   - the MRU ring is [A, C, B]  ⇒ ⌃⇥ must land on **C**
    ///   - the active tab is index 0  ⇒ ⌘⇧] would land on **B**
    /// Any test that cannot tell C from B is not testing recency.
    private func seedDivergentFixture(_ store: WorkspaceStore) -> (a: TabID, b: TabID, c: TabID) {
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        let ids = tabIDs(store)
        XCTAssertEqual(ids.count, 3, "fixture needs three tabs")
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.selectTab(2) // visit C
        store.selectTab(0) // back to A — now MRU = [A, C, B]
        XCTAssertEqual(activeTab(store), a, "fixture leaves A active")
        return (a, b, c)
    }

    // MARK: - The recency-vs-position distinction

    /// One ⌃⇥ and release commits to the most-recently-used OTHER tab — NOT the next tab along.
    func testCommitLandsOnTheRecentTabNotThePositionalNext() {
        let store = makeStore()
        let (_, b, c) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, c, "the highlight is the RECENT tab")
        store.commitTabSwitcher()

        XCTAssertEqual(activeTab(store), c, "⌃⇥ committed to the recently-used tab")
        XCTAssertNotEqual(activeTab(store), b, "and specifically NOT the positional next tab")
    }

    /// The positional cycle is untouched by any of this — ⌘⇧] still steps the tab BAR, proving the two
    /// gestures stayed independent rather than one being reimplemented in terms of the other.
    func testPositionalCycleStillStepsTheTabBar() {
        let store = makeStore()
        let (_, b, _) = seedDivergentFixture(store)
        store.cycleTab(by: 1)
        XCTAssertEqual(activeTab(store), b, "⌘⇧] steps positionally, independent of recency")
    }

    // MARK: - The highlight is local until commit

    /// Walking the highlight must NOT move the active tab: a tab focus is a host intent, and staging one
    /// per step would broadcast every intermediate tab of a cycle to every other attached client.
    func testSteppingDoesNotMoveTheActiveTabBeforeCommit() {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(activeTab(store), a, "three ⇥ taps moved the highlight, not the workspace")
        XCTAssertNotNil(store.tabSwitcher, "and the switcher is still open")
    }

    /// Esc abandons the walk: the active tab is the one we started on, however far the highlight roamed.
    func testCancelLeavesTheActiveTabUntouched() {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        store.cancelTabSwitcher()

        XCTAssertNil(store.tabSwitcher, "cancel closes the switcher")
        XCTAssertEqual(activeTab(store), a, "and commits nothing")
    }

    // MARK: - Repeat presses reuse the open switcher

    /// A second ⌃⇥ while the switcher is open STEPS it — it must not re-open and re-freeze the ring,
    /// which would pin the highlight at index 1 forever and make the gesture unable to reach tab three.
    func testRepeatPressStepsRatherThanReopening() {
        let store = makeStore()
        let (a, _, c) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, c)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlightIndex, 2, "the second press advanced the SAME ring")
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, a, "a third wraps back to the starting tab")
    }

    /// ⇧ mid-gesture reverses without closing.
    func testShiftReversesTheOpenSwitcher() {
        let store = makeStore()
        let (a, _, c) = seedDivergentFixture(store)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, c)
        store.openOrStepTabSwitcher(forward: false, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, a, "⌃⇧⇥ stepped back to the starting tab")
    }

    // MARK: - Degenerate cases

    /// A lone tab has nothing to switch to: the switcher must refuse to open so the dispatcher passes
    /// ⌃⇥ through to the pane instead of swallowing it into a dead overlay.
    func testSingleTabNeverOpensTheSwitcher() {
        let store = makeStore()
        XCTAssertEqual(tabIDs(store).count, 1, "fixture starts with one tab")
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertNil(store.tabSwitcher, "one tab ⇒ no switcher")
    }

    /// Committing a switcher whose highlighted tab was closed mid-gesture must not move focus onto a
    /// tab that no longer exists.
    ///
    /// The fixture deliberately leaves the active tab at index 1, NOT index 0: a commit that resolved a
    /// missing tab to "some index anyway" would land on index 0 and this assertion is what catches it.
    /// With the active tab at index 0 the bug and the correct behaviour are indistinguishable.
    func testCommitOntoAClosedTabIsANoOp() {
        let store = makeStore()
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        let ids = tabIDs(store)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.selectTab(2) // visit C
        store.selectTab(1) // land on B — index 1, so an index-0 fallback would be visible
        XCTAssertEqual(activeTab(store), b)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.tabSwitcher?.highlighted, c, "the highlight is the recently-visited tab")
        store.closeTab(c)
        store.commitTabSwitcher()

        XCTAssertNil(store.tabSwitcher, "the switcher closed")
        XCTAssertEqual(activeTab(store), b, "focus stayed put")
        XCTAssertNotEqual(activeTab(store), a, "and did NOT fall back to the first tab")
    }

    // MARK: - Modifier release

    /// The ⌃⇥ gesture commits when ⌃ comes up — that release IS the selection.
    func testModifierReleaseCommitsAnArmedSwitcher() {
        let store = makeStore()
        let (_, _, c) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        store.commitTabSwitcherOnModifierRelease()

        XCTAssertNil(store.tabSwitcher, "the release closed the switcher")
        XCTAssertEqual(activeTab(store), c, "and committed the highlighted tab")
    }

    /// A switcher opened from the palette has nothing held, so a modifier coming up is an unrelated
    /// key-up — tapping ⇧ while it is open must not silently pick whatever is highlighted.
    func testModifierReleaseLeavesAnUnarmedSwitcherOpen() {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepTabSwitcher(forward: true, armedByModifier: false)
        store.commitTabSwitcherOnModifierRelease()

        XCTAssertNotNil(store.tabSwitcher, "an unarmed switcher survives a modifier release")
        XCTAssertEqual(activeTab(store), a, "and nothing was committed")
    }

    // MARK: - Navigating elsewhere abandons the walk

    /// A switcher opened WITHOUT a held modifier (the palette route) has no key-up coming to end it, and
    /// the overlay takes no clicks — so a click on a pane behind it would leave the card up over a
    /// workspace the user has already moved on from, and the next Return would commit a stale highlight.
    ///
    /// The fixture puts the clicked pane in tab **B**, the one the switcher is NOT highlighting: if the
    /// stale switcher then committed, focus would land on C, and that is what this catches.
    func testFocusingAPaneElsewhereAbandonsTheSwitcher() {
        let store = makeStore()
        let (_, b, c) = seedDivergentFixture(store)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: false)
        XCTAssertEqual(store.tabSwitcher?.highlighted, c, "precondition: the highlight is on C")

        guard let paneInB = store.tree.activeSession?.tabs.first(where: { $0.id == b })?.activePane else {
            XCTFail("fixture tab B should own a pane")
            return
        }
        store.focusPaneTree(paneInB)

        XCTAssertNil(store.tabSwitcher, "clicking into the workspace abandoned the walk")
        XCTAssertEqual(activeTab(store), b, "and focus followed the CLICK, not the stale highlight")
    }

    /// Same guard from the tab bar: clicking a tab directly is a focus change the switcher must yield to.
    func testSelectingAnotherTabAbandonsTheSwitcher() {
        let store = makeStore()
        let (_, b, _) = seedDivergentFixture(store)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: false)

        store.selectTab(1)

        XCTAssertNil(store.tabSwitcher, "a tab-bar click abandoned the walk")
        XCTAssertEqual(activeTab(store), b)
    }

    /// The guard above must not eat the switcher's OWN commit — commit stages a focus too, so ordering the
    /// cancel after the selection would close the switcher and drop the selection on the floor.
    func testCommitSurvivesTheFocusChangeItCauses() {
        let store = makeStore()
        let (_, _, c) = seedDivergentFixture(store)
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)

        store.commitTabSwitcher()

        XCTAssertEqual(activeTab(store), c, "the commit's own focus change did not cancel it")
    }
}
