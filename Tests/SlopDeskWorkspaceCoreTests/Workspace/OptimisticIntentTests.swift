import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The optimistic layer: what the user sees between asking for a change and the host confirming it.
///
/// Without it every split, rename and close waits a full round trip before anything moves — a
/// latency the user reads as the app being slow, and one that gets worse the further from the host
/// they are. With it, the risk moves: the client can now show something the host never agreed to.
/// Every test here is about the moment that risk resolves.
@MainActor
final class OptimisticIntentTests: XCTestCase {
    private struct Fixture {
        var box: WorkspaceMirrorBox
        var session: SessionID
        var tab: TabID
        var pane: PaneID
    }

    private func fixture() -> Fixture {
        let pane = PaneID()
        let tab = Tab(id: TabID(), title: "one", root: .leaf(pane), activePane: pane)
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [tab],
            specs: [pane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: TreeWorkspace(
            sessions: [session], activeSessionID: session.id,
            layoutPresets: [], launchPresets: [], sessionTemplates: [],
        )))
        let box = WorkspaceMirrorBox()
        box.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: UUID(), baseStateNum: 0, newStateNum: 1,
            payload: WorkspaceStateCodec.encodeSnapshot(state),
        )
        return Fixture(box: box, session: session.id, tab: tab.id, pane: pane)
    }

    private func renameArgs(_ f: Fixture, _ title: String) -> Data {
        WorkspaceIntentArgs.encode(id: f.tab.raw, name: title)
    }

    /// Applies a host frame carrying `topology` at `stateNum`, as a diff from what the mirror holds.
    @discardableResult
    private func hostPublishes(
        _ topology: WorkspaceTopology,
        to f: Fixture,
        stateNum: Int64,
    ) -> HostWorkspaceMirror.ApplyOutcome {
        var next = HostWorkspaceState()
        next.write(topology: topology)
        let diff = next.diff(from: f.box.mirror.entries)
        return f.box.apply(
            kind: WorkspaceEventKind.diff.rawValue,
            epoch: f.box.mirror.epoch ?? WireMessage.newSessionID,
            baseStateNum: f.box.mirror.stateNum,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeDiff(diff),
        )
    }

    private func result(_ intentID: UUID, _ status: WorkspaceIntentStatus, to f: Fixture) {
        f.box.apply(
            kind: WorkspaceEventKind.intentResult.rawValue,
            epoch: UUID(), baseStateNum: 0, newStateNum: 0,
            payload: WorkspaceIntentResult(intentID: intentID, status: status).encode(),
        )
    }

    // MARK: - The point of it

    /// The change is on screen in the same frame the user asked for it, not a round trip later.
    func testAStagedIntentIsVisibleImmediately() {
        let f = fixture()
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "one")

        let intent = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0)

        XCTAssertNotNil(intent)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build")
        XCTAssertEqual(
            f.box.mirror.entries.string(WorkspaceKey(.tab, f.tab.raw, WorkspaceTabField.title)), "one",
            "host truth is untouched — the overlay is a separate layer, not a write",
        )
    }

    /// A split appears with its new pane already in the tree. That is what the client-proposed pane
    /// id buys: an overlay cannot insert a leaf it has no id for.
    func testAnOptimisticSplitCarriesItsNewPane() throws {
        let f = fixture()
        let proposed = PaneID()

        _ = f.box.stageIntent(op: .splitPane, args: WorkspaceIntentArgs.encode(
            target: f.pane.raw, axis: .horizontal, before: false, newPane: proposed, spawnCwd: "",
        ), issuedAt: 0)

        let topology = try XCTUnwrap(f.box.topology)
        XCTAssertTrue(topology.tree.contains(proposed))
        XCTAssertEqual(topology.tree.sessions[0].tabs[0].allPaneIDs().count, 2)
    }

    // MARK: - Resolution

    /// The accepted path, and the anti-flicker rule: the patch is HELD after the answer and retired
    /// by the frame that makes it real, so the row never blinks out in between.
    func testAnAcceptedPatchIsHeldUntilHostTruthArrives() throws {
        let f = fixture()
        let intent = try XCTUnwrap(f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0))

        result(intent.intentID, .applied, to: f)
        XCTAssertEqual(f.box.pendingIntentCount, 1, "retiring here would blink the old title back")
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build")

        var host = try XCTUnwrap(f.box.topology)
        host.tree.sessions[0].tabs[0].title = "build"
        hostPublishes(host, to: f, stateNum: 2)

        XCTAssertEqual(f.box.pendingIntentCount, 0)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build", "now from host truth")
    }

    /// A refusal snaps back AT ONCE. Waiting for a frame would keep showing the user something the
    /// host has already said is not true — the one case where holding the patch is wrong.
    func testARefusedPatchSnapsBackImmediately() throws {
        let f = fixture()
        let intent = try XCTUnwrap(f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0))
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build")

        result(intent.intentID, .rejectedInvalid, to: f)

        XCTAssertEqual(f.box.pendingIntentCount, 0)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "one")
    }

    /// The backstop, for a host that accepted the intent and died before answering. Without it the
    /// UI keeps rendering a layout nothing will ever correct.
    func testAnUnansweredPatchExpires() {
        let f = fixture()
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 100)

        f.box.expirePending(now: 100 + HostWorkspaceMirror.pendingTimeout - 0.001)
        XCTAssertEqual(f.box.pendingIntentCount, 1, "a slow link is not a lost intent")

        f.box.expirePending(now: 100 + HostWorkspaceMirror.pendingTimeout)
        XCTAssertEqual(f.box.pendingIntentCount, 0)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "one")
    }

    /// …but an ACCEPTED patch does not expire on the clock. The host has said yes; the only thing
    /// left is the frame, and timing that out would flicker the change away right before it lands.
    func testAnAcceptedPatchDoesNotExpireOnTheClock() throws {
        let f = fixture()
        let intent = try XCTUnwrap(f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 100))
        result(intent.intentID, .applied, to: f)

        f.box.expirePending(now: 100 + HostWorkspaceMirror.pendingTimeout * 10)

        XCTAssertEqual(f.box.pendingIntentCount, 1)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build")
    }

    /// A host frame that arrives BEFORE the result must not retire the patch. The host queues the
    /// document ahead of the result, so an early frame is one this intent is not in yet — retiring on
    /// it would show the old layout until the next unrelated change.
    func testAFrameBeforeTheResultDoesNotRetireThePatch() throws {
        let f = fixture()
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0)

        var unrelated = try XCTUnwrap(f.box.mirror.entries.topology)
        unrelated.tree.sessions[0].name = "renamed elsewhere"
        hostPublishes(unrelated, to: f, stateNum: 2)

        XCTAssertEqual(f.box.pendingIntentCount, 1)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "build")
        XCTAssertEqual(
            f.box.topology?.tree.sessions[0].name,
            "renamed elsewhere",
            "the other client's change still lands underneath",
        )
    }

    // MARK: - Stacking

    /// Two in-flight intents touching one cell resolve to the LATER one — the order the host will
    /// resolve them in too, because they reach its actor in the order they were sent.
    func testTheNewerOfTwoPatchesWins() {
        let f = fixture()
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "first"), issuedAt: 0)
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "second"), issuedAt: 1)

        XCTAssertEqual(f.box.pendingIntentCount, 2)
        XCTAssertEqual(f.box.topology?.tree.sessions[0].tabs[0].title, "second")
    }

    /// An intent this client can already tell is invalid is never sent. A request whose answer is
    /// known is a round trip and a rollback for nothing.
    func testAnIntentTheClientKnowsIsInvalidIsNotSent() {
        let f = fixture()
        XCTAssertNil(
            f.box.stageIntent(op: .renameTab, args: WorkspaceIntentArgs.encode(id: UUID(), name: "x"), issuedAt: 0),
        )
        XCTAssertEqual(f.box.pendingIntentCount, 0)
    }

    /// A reset means the host declared a DIFFERENT document. The patches describe edits to a tree
    /// that no longer exists, so keeping them would render a split against something that never had
    /// one. Losing the intents is correct — nobody knows whether the old host applied them.
    func testAResetDropsEveryPendingPatch() {
        let f = fixture()
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0)

        f.box.apply(
            kind: WorkspaceEventKind.reset.rawValue,
            epoch: UUID(), baseStateNum: 0, newStateNum: 0, payload: Data(),
        )

        XCTAssertEqual(f.box.pendingIntentCount, 0)
    }

    // MARK: - Layer discipline

    /// The overlay sits AHEAD of the fast path as well as of host truth, so an optimistic close does
    /// not leave a row alive on the strength of a control push.
    func testThePendingLayerOutranksTheFastPath() {
        let f = fixture()
        let proposed = PaneID()
        _ = f.box.stageIntent(op: .splitPane, args: WorkspaceIntentArgs.encode(
            target: f.pane.raw, axis: .horizontal, before: false, newPane: proposed, spawnCwd: "",
        ), issuedAt: 0)
        f.box.writeFastPath(pane: proposed.raw, field: WorkspacePaneField.title, string: "pushed")

        XCTAssertEqual(
            f.box.string(.pane, proposed.raw, WorkspacePaneField.title), "Terminal",
            "the staged spec wins over a push for the same cell",
        )
    }

    /// Every read the UI makes goes through one funnel, so the overlay cannot be visible in one
    /// surface and absent in another.
    func testTheOverlayIsVisibleThroughTheOrdinaryReads() {
        let f = fixture()
        _ = f.box.stageIntent(op: .renameTab, args: renameArgs(f, "build"), issuedAt: 0)

        XCTAssertEqual(f.box.string(.tab, f.tab.raw, WorkspaceTabField.title), "build")
    }
}
