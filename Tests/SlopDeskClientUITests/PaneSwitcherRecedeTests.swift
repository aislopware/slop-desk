// PaneSwitcherRecedeTests — pins the ⌃⇥ walk's contrast: while the switcher is open, EXACTLY ONE pane of
// the visible tab stays lit, and it is the pane the walk is on.
//
// The claim is a COMPOSITION, not a predicate: `PaneContainer.showsSwitcherRecede` is trivial on its own,
// and asserting it in isolation would be a tautology. What can actually break is the join — the switcher's
// highlight, the preview that moves this device's focus onto it, and `SplitContainer.isPaneFocused`, which
// is what the view feeds the predicate. So every case below drives a LIVE store and evaluates the same two
// calls the view makes.
//
// Headless: no view is instantiated (both entry points are pure statics) and the store rides the tree-model
// `MountTestPaneSession` fake — no socket, no video, no Metal.

#if os(macOS)
import Defaults
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneSwitcherRecedeTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// Exactly what the view computes, for every pane of the ACTIVE tab: the ids that recede.
    private func receding(_ store: WorkspaceStore) throws -> Set<PaneID> {
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        let open = store.paneSwitcher != nil
        return Set(tab.allPaneIDs().filter { id in
            PaneContainer.showsSwitcherRecede(
                switcherIsOpen: open,
                isFocused: SplitContainer.isPaneFocused(
                    id, in: tab, activeTabID: store.tree.activeSession?.activeTab?.id,
                ),
            )
        })
    }

    /// A tab split three ways, with the switcher shut.
    private func splitThreeWays(_ store: WorkspaceStore) throws -> [PaneID] {
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        store.splitActivePane(axis: .vertical, kind: .terminal, leading: false, launchGrace: .zero)
        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()
        XCTAssertEqual(panes.count, 3, "fixture needs three panes in one tab")
        return panes
    }

    /// AT REST NOTHING RECEDES. The resting focus treatment is the corner marker — dimming the siblings
    /// permanently was tried and removed for washing out live content, and this is the guard that keeps
    /// the walk's contrast from leaking back into that.
    func testNoPaneRecedesWhileTheSwitcherIsShut() throws {
        let store = makeStore()
        _ = try splitThreeWays(store)
        XCTAssertNil(store.paneSwitcher, "precondition: no walk in progress")
        XCTAssertEqual(try receding(store), [], "a resting workspace is at full contrast")
    }

    /// THE FEATURE: mid-walk, the two panes that are not the subject recede and the subject does not.
    func testTheWalkLeavesExactlyTheHighlightedPaneLit() throws {
        let store = makeStore()
        let panes = try splitThreeWays(store)
        Defaults[.paneSwitcherPreview] = true
        defer { Defaults.reset(.paneSwitcherPreview) }

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        let highlighted = try XCTUnwrap(store.paneSwitcher?.highlighted)
        XCTAssertTrue(panes.contains(highlighted), "the walk stayed inside the split tab")

        XCTAssertEqual(
            try receding(store), Set(panes).subtracting([highlighted]),
            "every pane but the one the walk is on recedes",
        )
    }

    /// The contrast FOLLOWS the walk — the lit pane moves with each ⇥ tap rather than being fixed at the
    /// pane the gesture started on.
    func testTheLitPaneMovesWithEachStep() throws {
        let store = makeStore()
        _ = try splitThreeWays(store)
        Defaults[.paneSwitcherPreview] = true
        defer { Defaults.reset(.paneSwitcherPreview) }

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        let first = try receding(store)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        let second = try receding(store)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertNotEqual(first, second, "the second tap lit a different pane")
    }

    /// With the preview OFF the workspace holds still, so the lit pane is where a cancel would leave you —
    /// still exactly one, still the focused one. The contrast is about the SUBJECT, not about the preview.
    func testThePreviewSettingDoesNotDecideWhetherAnythingRecedes() throws {
        let store = makeStore()
        let panes = try splitThreeWays(store)
        Defaults[.paneSwitcherPreview] = false
        defer { Defaults.reset(.paneSwitcherPreview) }
        let focused = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)

        XCTAssertEqual(
            try receding(store), Set(panes).subtracting([focused]),
            "the pane you are on stays lit; its siblings recede",
        )
    }

    /// Ending the gesture ends the treatment — on BOTH exits, so a cancel cannot strand a workspace at
    /// half brightness.
    func testTheContrastEndsWithTheGesture() throws {
        let store = makeStore()
        _ = try splitThreeWays(store)

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertFalse(try receding(store).isEmpty, "precondition: the walk dimmed something")
        store.cancelPaneSwitcher()
        XCTAssertEqual(try receding(store), [], "cancel restored full contrast")

        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        store.commitPaneSwitcher()
        XCTAssertEqual(try receding(store), [], "and so did the commit")
    }

    /// A LONE pane has nothing to recede from, and the switcher refuses to open on one anyway — so the
    /// single-pane workspace never dims itself. (The same reason the resting focus corner hides there.)
    func testASinglePaneWorkspaceNeverRecedes() throws {
        let store = makeStore()
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        XCTAssertNil(store.paneSwitcher, "one pane ⇒ no walk")
        XCTAssertEqual(try receding(store), [])
    }
}
#endif
