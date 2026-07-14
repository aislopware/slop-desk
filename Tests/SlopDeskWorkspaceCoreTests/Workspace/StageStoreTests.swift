import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The STAGE (docs/DECISIONS.md "The Stage", 2026-07-14): the dedicated tabbed zone for non-terminal
/// content beside the terminal-only split tree. This suite is the headless authority for the stage
/// domain + store contract: the widened specs invariant (tree leaves ∪ stage panes), additive
/// persistence, the open/activate/close ops, single-active-decode slot handoff, and reconcile
/// materializing/tearing down stage panes through the shared diff.
@MainActor
final class StageStoreTests: XCTestCase {
    private func makeTreeStore(
        restoringTree tree: TreeWorkspace = .defaultWorkspace(),
        liveVideoCap: Int = 2,
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: liveVideoCap,
        )
    }

    // MARK: - Open: the single remote-window ingress

    func testOpenWindowInStageMintsSelectedStageTabAndMaterializes() throws {
        let store = makeTreeStore()
        let treeLeavesBefore = store.tree.allPaneIDs()

        let id = try XCTUnwrap(store.openWindowInStage(windowID: 42, title: "Xcode", appName: "Xcode"))

        XCTAssertEqual(store.stagePaneIDs, [id], "the window lands as a stage tab")
        XCTAssertEqual(store.activeStagePaneID, id, "a fresh stage tab is selected")
        XCTAssertEqual(store.tree.allPaneIDs(), treeLeavesBefore, "the split tree is untouched — terminal-only")
        let spec = try XCTUnwrap(store.tree.spec(for: id))
        XCTAssertEqual(spec.kind, .remoteGUI)
        XCTAssertEqual(spec.video?.windowID, 42)
        XCTAssertEqual(spec.video?.appName, "Xcode")
        XCTAssertNotNil(store.handle(for: id), "reconcile materializes the stage pane through the shared diff")
        XCTAssertTrue(store.tree.isInvariantHeld(), "specs == tree leaves ∪ stage panes")
    }

    func testOpenSameWindowTwiceActivatesInsteadOfDuplicating() throws {
        let store = makeTreeStore()
        let first = try XCTUnwrap(store.openWindowInStage(windowID: 7, title: "Safari", appName: "Safari"))
        let second = try XCTUnwrap(store.openWindowInStage(windowID: 9, title: "Mail", appName: "Mail"))
        XCTAssertEqual(store.activeStagePaneID, second)

        let reopened = store.openWindowInStage(windowID: 7, title: "Safari", appName: "Safari")

        XCTAssertEqual(reopened, first, "an already-staged window is resolved, not re-minted")
        XCTAssertEqual(store.stagePaneIDs, [first, second], "no duplicate tab")
        XCTAssertEqual(store.activeStagePaneID, first, "re-opening ACTIVATES the existing tab")
    }

    // MARK: - Activate: single-active-decode slot handoff

    func testActivateStagePaneFreesThePreviousTabsVideoSlotImmediately() throws {
        let store = makeTreeStore(liveVideoCap: 1)
        let first = try XCTUnwrap(store.openWindowInStage(windowID: 1, title: "A", appName: "A"))
        let second = try XCTUnwrap(store.openWindowInStage(windowID: 2, title: "B", appName: "B"))

        // The selected tab (second) takes the single decode slot, as the view's activation would.
        XCTAssertTrue(store.activateVideo(second), "the selected tab admits against the cap")
        let secondFake = try XCTUnwrap(store.handle(for: second) as? FakePaneSession)
        XCTAssertTrue(secondFake.isVideoActive)

        store.activateStagePane(first)

        XCTAssertEqual(store.activeStagePaneID, first)
        XCTAssertFalse(
            secondFake.isVideoActive,
            "single-active-decode: switching tabs frees the outgoing slot in the SAME op",
        )
        XCTAssertTrue(
            store.activateVideo(first),
            "the incoming tab admits immediately — no transient double-decode against the cap",
        )
    }

    func testActivateIsNoOpForUnstagedOrAlreadyActivePane() throws {
        let store = makeTreeStore()
        let id = try XCTUnwrap(store.openWindowInStage(windowID: 3, title: "C", appName: "C"))
        store.activateStagePane(id) // already selected — no-op
        XCTAssertEqual(store.activeStagePaneID, id)
        store.activateStagePane(PaneID()) // unknown — no-op
        XCTAssertEqual(store.activeStagePaneID, id)
    }

    // MARK: - Close: teardown through the shared diff + neighbour selection

    func testCloseStagePaneTearsDownAndSelectsTheSlidInNeighbour() throws {
        let store = makeTreeStore()
        let a = try XCTUnwrap(store.openWindowInStage(windowID: 1, title: "A", appName: "A"))
        let b = try XCTUnwrap(store.openWindowInStage(windowID: 2, title: "B", appName: "B"))
        let c = try XCTUnwrap(store.openWindowInStage(windowID: 3, title: "C", appName: "C"))
        store.activateStagePane(b)

        store.closeStagePane(b)

        XCTAssertEqual(store.stagePaneIDs, [a, c])
        XCTAssertEqual(store.activeStagePaneID, c, "selection advances to the tab that slid into the closed slot")
        XCTAssertNil(store.handle(for: b), "reconcile tears the closed stage pane down")
        XCTAssertNil(store.tree.spec(for: b), "the spec is gone with the tab")
        XCTAssertTrue(store.tree.isInvariantHeld())

        store.closeStagePane(c)
        XCTAssertEqual(store.activeStagePaneID, a, "closing the last tab falls back to the new last")
        store.closeStagePane(a)
        XCTAssertNil(store.activeStagePaneID, "an emptied stage clears the selection (the zone collapses)")
        XCTAssertEqual(store.stagePaneIDs, [])
    }

    // MARK: - stagedWindowPane: the rail's one "is it already open?" rule

    func testStagedWindowPaneResolvesTabOrdinal() throws {
        let store = makeTreeStore()
        _ = store.openWindowInStage(windowID: 11, title: "A", appName: "A")
        let b = try XCTUnwrap(store.openWindowInStage(windowID: 22, title: "B", appName: "B"))

        let ref = try XCTUnwrap(store.stagedWindowPane(for: 22))
        XCTAssertEqual(ref.paneID, b)
        XCTAssertEqual(ref.tabOrdinal, 2, "1-based stage tab-strip ordinal")
        XCTAssertNil(store.stagedWindowPane(for: 99), "an unstaged window resolves nil")
    }

    // MARK: - Persistence: additive round-trip + pre-stage files decode to an empty stage

    func testSessionStageRoundTripsAndPreStageJSONDecodesEmpty() throws {
        let stagePane = PaneID()
        var session = Session.singlePane(name: "S", spec: PaneSpec(kind: .terminal, title: "Terminal"))
        session.stagePanes = [stagePane]
        session.activeStagePane = stagePane
        session.specs[stagePane] = PaneSpec(
            kind: .remoteGUI, title: "Xcode",
            video: VideoEndpoint(windowID: 5, title: "Xcode", appName: "Xcode"),
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session, "the stage round-trips")

        // A pre-stage file (no stage keys) decodes to an empty stage — additive, never traps.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stagePanes")
        object.removeValue(forKey: "activeStagePane")
        let preStage = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(Session.self, from: preStage)
        XCTAssertEqual(legacy.stagePanes, [])
        XCTAssertNil(legacy.activeStagePane)
    }

    func testStagelessSessionEncodesNoStageKeys() throws {
        let session = Session.singlePane(name: "S", spec: PaneSpec(kind: .terminal, title: "Terminal"))
        let data = try JSONEncoder().encode(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["stagePanes"], "a stage-less session's JSON is byte-identical to the pre-stage shape")
        XCTAssertNil(object["activeStagePane"])
    }

    // MARK: - Normalizing repairs (hostile / hand-edited files)

    func testNormalizingRepairsStageMembershipAndSelection() throws {
        let leaf = PaneID()
        let staged = PaneID()
        let specless = PaneID()
        var session = Session(
            name: "S",
            tabs: [Tab(root: .leaf(leaf), activePane: leaf)],
            specs: [leaf: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        // Hostile stage list: a tree-duplicated id, a spec-less id, a duplicate, and a dangling selection.
        session.stagePanes = [leaf, specless, staged, staged]
        session.specs[staged] = PaneSpec(
            kind: .remoteGUI, title: "W", video: VideoEndpoint(windowID: 1, title: "W", appName: "W"),
        )
        session.activeStagePane = specless
        let ws = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        let repaired = ws.normalized()

        let s = try XCTUnwrap(repaired.sessions.first)
        XCTAssertEqual(s.stagePanes, [staged], "tree-duplicated, spec-less, and duplicate ids are dropped")
        XCTAssertEqual(s.activeStagePane, staged, "the dangling selection re-points at the surviving tab")
        XCTAssertTrue(repaired.isInvariantHeld())
    }

    // MARK: - Focus routing: click-into-the-stream vs click-a-terminal

    func testFocusPaneTreeRoutesStagePaneToStageFocus() throws {
        let store = makeTreeStore()
        let terminal = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let a = try XCTUnwrap(store.openWindowInStage(windowID: 1, title: "A", appName: "A"))
        let b = try XCTUnwrap(store.openWindowInStage(windowID: 2, title: "B", appName: "B"))
        XCTAssertFalse(store.stageFocused, "opening a window does not steal keyboard ownership")

        // Clicking into a background stage tab's stream: ownership moves to the stage AND that tab selects.
        store.focusPaneTree(a)
        XCTAssertTrue(store.stageFocused, "click-into-the-stream captures input ownership")
        XCTAssertEqual(store.activeStagePaneID, a, "focusing a background stage tab also selects it")
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, terminal,
            "the canvas focus is untouched — the zones keep separate focus",
        )

        // Clicking a terminal releases ownership back to the canvas — even the already-active one.
        store.focusPaneTree(terminal)
        XCTAssertFalse(store.stageFocused, "a canvas click is the release affordance")
        _ = b
    }

    func testClosingLastStagePaneReleasesStageFocus() throws {
        let store = makeTreeStore()
        let a = try XCTUnwrap(store.openWindowInStage(windowID: 1, title: "A", appName: "A"))
        store.focusPaneTree(a)
        XCTAssertTrue(store.stageFocused)

        store.closeStagePane(a)

        XCTAssertFalse(store.stageFocused, "an emptied stage cannot hold input ownership")
    }

    // MARK: - Session teardown covers the stage

    func testClosingSessionTearsDownItsStagePanes() throws {
        let store = makeTreeStore()
        let id = try XCTUnwrap(store.openWindowInStage(windowID: 1, title: "A", appName: "A"))
        XCTAssertNotNil(store.handle(for: id))
        // A second session so closing the first is allowed (the workspace is never empty).
        store.newSession(name: "Other", kind: .terminal)
        let firstSession = try XCTUnwrap(store.tree.sessions.first { $0.stageContains(id) })

        store.closeSession(firstSession.id)

        XCTAssertNil(store.handle(for: id), "the closed session's stage panes leave the desired set → teardown")
    }
}
