import Defaults
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ⌃⇥ switcher against a LIVE tree store: that it walks PANES across the whole session, that
/// walking the highlight stages no focus intent, and that only a commit moves the workspace.
///
/// The load-bearing distinction this suite exists to pin: ⌃⇥ is RECENCY-ordered while ⌘]/⌘[ and the
/// tab bar are POSITION-ordered. A fixture where the two agree proves nothing, so every switch
/// assertion below is built on a visit order where the recency answer and the positional answer differ.
@MainActor
final class PaneSwitcherStoreTests: XCTestCase {
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

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func activeTab(_ store: WorkspaceStore) -> TabID? {
        store.tree.activeSession?.activeTab?.id
    }

    /// HOST TRUTH — the projection BEFORE this device's local overlays (the follow-along preview rides
    /// one). This is what "nothing was committed" has to mean while a switcher is open: `activePane`
    /// reads what the device is LOOKING at, which the preview legitimately moves.
    private func committedPane(_ store: WorkspaceStore) -> PaneID? {
        store.workspaceMirror.topology?.tree.activeSession?.activeTab?.activePane
    }

    /// The one pane of tab `id`.
    private func pane(of id: TabID, in store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.tabs.first { $0.id == id }?.activePane)
    }

    /// Builds a three-tab session (one pane each) and leaves the visit order A → C → A, so:
    ///   - the ring is [paneA, paneC, paneB]  ⇒ ⌃⇥ must land on **C's pane**
    ///   - the active tab is index 0          ⇒ ⌘⇧] would land on **B**
    /// Any test that cannot tell C from B is not testing recency.
    private func seedDivergentFixture(_ store: WorkspaceStore) -> (a: TabID, b: TabID, c: TabID) {
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        let ids = tabIDs(store)
        XCTAssertEqual(ids.count, 3, "fixture needs three tabs")
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.selectTab(2) // visit C
        store.selectTab(0) // back to A — now the ring is [paneA, paneC, paneB]
        XCTAssertEqual(activeTab(store), a, "fixture leaves A active")
        return (a, b, c)
    }

    // MARK: - The recency-vs-position distinction

    /// One ⌃⇥ and release commits to the most-recently-used OTHER pane — NOT the next tab along.
    func testCommitLandsOnTheRecentPaneNotThePositionalNext() throws {
        let store = makeStore()
        let (_, b, c) = seedDivergentFixture(store)

        let recent = try pane(of: c, in: store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.paneSwitcher?.highlighted, recent, "the highlight is RECENT")
        store.commitPaneSwitcher()

        XCTAssertEqual(activeTab(store), c, "⌃⇥ committed to the recently-used pane, bringing its tab")
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

    /// The reason this switcher counts panes rather than tabs: two panes of ONE tab are two places to
    /// be, and a tab-keyed ring could not tell them apart — ⌃⇥ inside a split was a dead gesture.
    func testTheSwitcherWalksBetweenTwoPanesOfTheSameTab() throws {
        let store = makeStore()
        let first = try XCTUnwrap(activePane(store))
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(activePane(store))
        XCTAssertNotEqual(first, second, "the split focused the new pane")

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.paneSwitcher?.highlighted, first, "⌃⇥ offers the sibling pane")
        store.commitPaneSwitcher()

        XCTAssertEqual(activePane(store), first, "and lands on it without leaving the tab")
        XCTAssertEqual(tabIDs(store).count, 1, "one tab throughout")
    }

    // MARK: - The highlight is local until commit

    /// Walking the highlight must NOT move the workspace: a pane focus is a host intent, and staging one
    /// per step would broadcast every intermediate pane of a cycle to every other attached client.
    func testSteppingDoesNotMoveTheActivePaneBeforeCommit() throws {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(
            committedPane(store), try pane(of: a, in: store),
            "three ⇥ taps moved the highlight, not the workspace",
        )
        XCTAssertNotNil(store.paneSwitcher, "and the switcher is still open")
    }

    /// Esc abandons the walk: the active pane is the one we started on, however far the highlight roamed.
    func testCancelLeavesTheActivePaneUntouched() {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.cancelPaneSwitcher()

        XCTAssertNil(store.paneSwitcher, "cancel closes the switcher")
        XCTAssertEqual(activeTab(store), a, "and commits nothing")
    }

    // MARK: - Repeat presses reuse the open switcher

    /// A second ⌃⇥ while the switcher is open STEPS it — it must not re-open and re-freeze the ring,
    /// which would pin the highlight at index 1 forever and make the gesture unable to reach pane three.
    func testRepeatPressStepsRatherThanReopening() throws {
        let store = makeStore()
        let (a, _, c) = seedDivergentFixture(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.paneSwitcher?.highlighted, try pane(of: c, in: store))
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.paneSwitcher?.highlightIndex, 2, "the second press advanced the SAME ring")
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(
            store.paneSwitcher?.highlighted, try pane(of: a, in: store),
            "a third wraps back to the starting pane",
        )
    }

    /// ⇧ mid-gesture reverses without closing.
    func testShiftReversesTheOpenSwitcher() throws {
        let store = makeStore()
        let (a, _, c) = seedDivergentFixture(store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(store.paneSwitcher?.highlighted, try pane(of: c, in: store))
        store.openOrStepPaneSwitcher(forward: false, armedByModifier: true)
        XCTAssertEqual(
            store.paneSwitcher?.highlighted, try pane(of: a, in: store),
            "⌃⇧⇥ stepped back to the starting pane",
        )
    }

    // MARK: - Degenerate cases

    /// A lone pane has nothing to switch to: the switcher must refuse to open so the dispatcher passes
    /// ⌃⇥ through to the pane instead of swallowing it into a dead overlay.
    func testSinglePaneNeverOpensTheSwitcher() {
        let store = makeStore()
        XCTAssertEqual(store.flatOrderedPaneIDs().count, 1, "fixture starts with one pane")
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertNil(store.paneSwitcher, "one pane ⇒ no switcher")
    }

    /// Committing a switcher whose highlighted pane was closed mid-gesture must not move focus onto a
    /// pane that no longer exists.
    ///
    /// The fixture deliberately leaves the active tab at index 1, NOT index 0: a commit that resolved a
    /// missing pane to "some index anyway" would land on index 0 and this assertion is what catches it.
    /// With the active tab at index 0 the bug and the correct behaviour are indistinguishable.
    func testCommitOntoAClosedPaneIsANoOp() throws {
        let store = makeStore()
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        let ids = tabIDs(store)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.selectTab(2) // visit C
        store.selectTab(1) // land on B — index 1, so an index-0 fallback would be visible
        XCTAssertEqual(activeTab(store), b)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertEqual(
            store.paneSwitcher?.highlighted, try pane(of: c, in: store),
            "the highlight is the recently-visited pane",
        )
        store.closeTab(c)
        store.commitPaneSwitcher()

        XCTAssertNil(store.paneSwitcher, "the switcher closed")
        XCTAssertEqual(activeTab(store), b, "focus stayed put")
        XCTAssertNotEqual(activeTab(store), a, "and did NOT fall back to the first tab")
    }

    // MARK: - Modifier release

    /// The ⌃⇥ gesture commits when ⌃ comes up — that release IS the selection.
    func testModifierReleaseCommitsAnArmedSwitcher() {
        let store = makeStore()
        let (_, _, c) = seedDivergentFixture(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.commitPaneSwitcherOnModifierRelease()

        XCTAssertNil(store.paneSwitcher, "the release closed the switcher")
        XCTAssertEqual(activeTab(store), c, "and committed the highlighted pane")
    }

    /// A switcher opened from the palette has nothing held, so a modifier coming up is an unrelated
    /// key-up — tapping ⇧ while it is open must not silently pick whatever is highlighted.
    func testModifierReleaseLeavesAnUnarmedSwitcherOpen() throws {
        let store = makeStore()
        let (a, _, _) = seedDivergentFixture(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        store.commitPaneSwitcherOnModifierRelease()

        XCTAssertNotNil(store.paneSwitcher, "an unarmed switcher survives a modifier release")
        XCTAssertEqual(committedPane(store), try pane(of: a, in: store), "and nothing was committed")
    }

    // MARK: - Navigating elsewhere abandons the walk

    /// A switcher opened WITHOUT a held modifier (the palette route) has no key-up coming to end it, and
    /// the overlay takes no clicks — so a click on a pane behind it would leave the card up over a
    /// workspace the user has already moved on from, and the next Return would commit a stale highlight.
    ///
    /// The fixture puts the clicked pane in tab **B**, the one the switcher is NOT highlighting: if the
    /// stale switcher then committed, focus would land on C, and that is what this catches.
    func testFocusingAPaneElsewhereAbandonsTheSwitcher() throws {
        let store = makeStore()
        let (_, b, c) = seedDivergentFixture(store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        XCTAssertEqual(
            store.paneSwitcher?.highlighted, try pane(of: c, in: store),
            "precondition: the highlight is on C's pane",
        )

        try store.focusPaneTree(pane(of: b, in: store))

        XCTAssertNil(store.paneSwitcher, "clicking into the workspace abandoned the walk")
        XCTAssertEqual(activeTab(store), b, "and focus followed the CLICK, not the stale highlight")
    }

    /// Same guard from the tab bar: clicking a tab directly is a focus change the switcher must yield to.
    func testSelectingAnotherTabAbandonsTheSwitcher() {
        let store = makeStore()
        let (_, b, _) = seedDivergentFixture(store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)

        store.selectTab(1)

        XCTAssertNil(store.paneSwitcher, "a tab-bar click abandoned the walk")
        XCTAssertEqual(activeTab(store), b)
    }

    /// The guard above must not eat the switcher's OWN commit — commit stages a focus too, so ordering the
    /// cancel after the selection would close the switcher and drop the selection on the floor.
    func testCommitSurvivesTheFocusChangeItCauses() {
        let store = makeStore()
        let (_, _, c) = seedDivergentFixture(store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)

        store.commitPaneSwitcher()

        XCTAssertEqual(activeTab(store), c, "the commit's own focus change did not cancel it")
    }

    // MARK: - ⌘1…⌘9 (the same unit, counted in the sidebar's DRAWN order)

    /// The digit names a PANE, in `displayOrderedPaneIDs()` order. With no project keys every pane
    /// shares the "Other" bucket, so the drawn order IS the flat creation order here — and a split
    /// tab shifts the numbers of everything after it, which is exactly what makes the number mean
    /// "the Nth pane" rather than "the Nth tab".
    func testDigitSelectsTheNthPaneAcrossTabs() {
        let store = makeStore()
        let (a, b, _) = seedDivergentFixture(store)
        store.selectTab(0)
        store.splitActivePane(axis: .horizontal, kind: .terminal) // A now holds two panes

        let drawn = store.displayOrderedPaneIDs()
        XCTAssertEqual(drawn, store.flatOrderedPaneIDs(), "keyless panes: one bucket, creation order")
        XCTAssertEqual(drawn.count, 4, "two panes in A, one each in B and C")

        store.selectPaneNumber(3) // the FIRST pane of tab B, not tab C
        XCTAssertEqual(activePane(store), drawn[2])
        XCTAssertEqual(activeTab(store), b, "the digit brought the owning tab with it")

        store.selectPaneNumber(2) // A's second pane
        XCTAssertEqual(activePane(store), drawn[1])
        XCTAssertEqual(activeTab(store), a)
    }

    /// THE ORDER THE DIGIT COUNTS: the sidebar's project-grouped DRAWN order, not `session.tabs`
    /// creation order. C returning to A's project draws beside A — so ⌘2 must land on C, even though
    /// creation order says B. A creation-order `selectPaneNumber` fails this with ⌘2 → B: the digit
    /// pointing at a row nowhere near the second one on screen, which is the reported bug.
    func testDigitFollowsTheProjectGroupedDrawnOrder() throws {
        let store = makeStore()
        let (a, b, c) = seedDivergentFixture(store)
        try store.setProjectKey("/work/alpha", for: pane(of: a, in: store))
        try store.setProjectKey("/work/beta", for: pane(of: b, in: store))
        try store.setProjectKey("/work/alpha", for: pane(of: c, in: store)) // C rejoins alpha

        let drawn = store.displayOrderedPaneIDs()
        XCTAssertEqual(
            drawn, try [pane(of: a, in: store), pane(of: c, in: store), pane(of: b, in: store)],
            "the drawn order groups C beside A; creation order (A, B, C) would prove nothing",
        )
        XCTAssertEqual(
            drawn.map { store.shortcutNumber(for: $0) }, [1, 2, 3],
            "the ⌘-held hint digits count that same drawn order",
        )

        store.selectPaneNumber(2)
        XCTAssertEqual(activePane(store), try pane(of: c, in: store), "⌘2 = the SECOND ROW on screen")
        XCTAssertEqual(activeTab(store), c, "and it brought C's tab, not creation-order B")
    }

    /// A digit past the pane count does nothing — it must not clamp to the last pane, the native
    /// ⌘-digit idiom.
    func testDigitPastThePaneCountIsANoOp() {
        let store = makeStore()
        _ = seedDivergentFixture(store)
        let before = activePane(store)
        store.selectPaneNumber(9)
        XCTAssertEqual(activePane(store), before, "⌘9 with three panes is a no-op")
    }

    // MARK: - The follow-along preview (`controls.paneSwitcherPreview`, default ON)

    /// Runs `body` with the preview setting forced to `enabled`, restoring it after — the key is a real
    /// `UserDefaults` entry, so a test that flipped it and walked away would leak into every later one.
    private func withPreview(_ enabled: Bool, _ body: () -> Void) {
        let previous = Defaults[.paneSwitcherPreview]
        Defaults[.paneSwitcherPreview] = enabled
        defer { Defaults[.paneSwitcherPreview] = previous }
        body()
    }

    /// The point of the feature: while the highlight walks, THIS DEVICE looks at the highlighted pane.
    func testStepShowsTheHighlightedPaneWhileTheSwitcherIsOpen() {
        withPreview(true) {
            let store = makeStore()
            let (a, b, c) = seedDivergentFixture(store)

            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            XCTAssertEqual(activeTab(store), c, "the first candidate is on screen")
            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            XCTAssertEqual(activeTab(store), b, "and the walk keeps the view with it")
            XCTAssertEqual(
                committedPane(store), try? pane(of: a, in: store),
                "…while the WORKSPACE has not moved",
            )
        }
    }

    /// ⚠️ THE FOUNDING RULE SURVIVES: the preview is a device-local overlay, never an intent. Host truth
    /// stays on the starting pane for the whole walk, so no other client is dragged through the cycle.
    func testPreviewStagesNoIntent() {
        withPreview(true) {
            let store = makeStore()
            let (a, _, _) = seedDivergentFixture(store)
            let start = try? pane(of: a, in: store)
            for _ in 0..<5 { store.openOrStepPaneSwitcher(forward: true, armedByModifier: true) }
            XCTAssertEqual(committedPane(store), start, "five steps staged nothing on the host")
        }
    }

    /// Esc puts the view back where the gesture found it — the preview must not survive its own walk.
    func testCancelRestoresTheViewThePreviewMovedOffOf() {
        withPreview(true) {
            let store = makeStore()
            let (a, _, _) = seedDivergentFixture(store)

            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            XCTAssertNotEqual(activeTab(store), a, "the preview did move the view")
            store.cancelPaneSwitcher()

            XCTAssertEqual(activeTab(store), a, "cancel put it back")
            XCTAssertEqual(committedPane(store), try? pane(of: a, in: store))
            XCTAssertFalse(store.paneSwitcherPreviewing, "and the preview state is unwound")
        }
    }

    /// A commit still lands the pane for real — the preview is unwound first, so the ONE staged focus is
    /// the commit's, computed from the focus the gesture began with.
    func testCommitAfterAPreviewLandsThePaneForReal() {
        withPreview(true) {
            let store = makeStore()
            let (_, _, c) = seedDivergentFixture(store)

            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            store.commitPaneSwitcher()

            XCTAssertEqual(
                committedPane(store), try? pane(of: c, in: store),
                "the host moved exactly once, at the commit",
            )
            XCTAssertEqual(activeTab(store), c)
            XCTAssertFalse(store.paneSwitcherPreviewing)
            XCTAssertNil(store.paneSwitcherFocusBeforePreview, "no saved focus left behind")
        }
    }

    /// OFF is a real mode: the walk moves the highlight and NOTHING else, exactly as it did before the
    /// preview existed.
    func testPreviewOffLeavesTheViewWhereItWas() {
        withPreview(false) {
            let store = makeStore()
            let (a, _, c) = seedDivergentFixture(store)

            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
            store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)

            XCTAssertEqual(activeTab(store), a, "the view held still")
            XCTAssertFalse(store.paneSwitcherPreviewing)
            store.openOrStepPaneSwitcher(forward: false, armedByModifier: true)
            store.commitPaneSwitcher()
            XCTAssertEqual(committedPane(store), try? pane(of: c, in: store), "and the commit still works")
        }
    }
}
