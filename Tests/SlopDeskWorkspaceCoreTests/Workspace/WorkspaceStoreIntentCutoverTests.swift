import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The cutover itself: what the store renders is what the DOCUMENT holds.
///
/// Every mutator here is asserted twice — once against `store.tree` (what the user sees) and once
/// against `workspaceMirror.mirror.entries` (host truth, with the optimistic layer deliberately
/// excluded). Asserting only the first would pass on a store that still owned its own tree, which is
/// precisely the state this phase removes.
///
/// **No ack pump, no `await`.** ``LoopbackWorkspaceDocument`` answers on the caller's turn: the
/// intent is applied, the result frame delivered and the document frame published before
/// `send(intent:args:)` returns. Adding a suspension point here would only hide a synchronous
/// mutator that stopped working.
@MainActor
final class WorkspaceStoreIntentCutoverTests: XCTestCase {
    // MARK: - Fixtures

    private struct Seed {
        var workspace: TreeWorkspace
        var session: SessionID
        var first: TabID
        var second: TabID
        var firstPane: PaneID
        var secondPane: PaneID
    }

    private func seed() -> Seed {
        let first = PaneID()
        let second = PaneID()
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [
                Tab(id: TabID(), title: "one", root: .leaf(first), activePane: first),
                Tab(id: TabID(), title: "two", root: .leaf(second), activePane: second),
            ],
            specs: [
                first: PaneSpec(kind: .terminal, title: "Terminal"),
                second: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        return Seed(
            workspace: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            session: session.id,
            first: session.tabs[0].id,
            second: session.tabs[1].id,
            firstPane: first,
            secondPane: second,
        )
    }

    private func makeStore(_ tree: TreeWorkspace) -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: tree,
            makeSession: { FakePaneSession($0.spec) },
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// Whether host truth — `entries`, NOT the pending overlay — still lists `tab` as OPEN.
    ///
    /// Deliberately the session's tab order rather than the tab's own cells: a CLOSED tab keeps every
    /// `tab/*` entry it had, because the reopen ring carries whole tabs and a closed tab is exactly one
    /// whose `tab/sessionID` names a session that no longer lists it.
    private func hostTruthHasTab(_ tab: TabID, _ store: WorkspaceStore) -> Bool {
        hostTruthTopology(store)?.tree.sessions.contains { $0.tabs.contains { $0.id == tab } } ?? false
    }

    private func hostTruthTopology(_ store: WorkspaceStore) -> WorkspaceTopology? {
        WorkspaceTopology(entries: store.workspaceMirror.mirror.entries)
    }

    // MARK: - The cutover

    /// RED before the store's mutators became intents: `closeTab` rewrote a locally-owned tree and
    /// the document was never asked, so the tab stayed in `entries` forever.
    func testClosingATabAsksTheDocumentRatherThanRewritingALocalTree() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        XCTAssertTrue(hostTruthHasTab(seed.second, store))

        store.closeTab(seed.second)

        XCTAssertFalse(
            hostTruthHasTab(seed.second, store),
            "the closed tab is gone from HOST TRUTH, not merely from a local copy",
        )
        XCTAssertEqual(store.tree.sessions.first?.tabs.count, 1)
        XCTAssertEqual(store.tree.sessions.first?.tabs.first?.id, seed.first)
        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "an accepted intent leaves no patch standing")
    }

    /// The layout the store renders IS the projection: nothing outside the document can move it.
    func testTheRenderedTreeIsTheDocumentsTree() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        XCTAssertEqual(store.tree, hostTruthTopology(store)?.tree)

        store.newTab(kind: .terminal)

        XCTAssertEqual(store.tree, hostTruthTopology(store)?.tree)
        XCTAssertEqual(store.tree.sessions.first?.tabs.count, 3)
    }

    /// A store with no document at all renders NOTHING, and every mutation is a silent no-op. The one
    /// state worth pinning by name, because it is what a client against a flag-off host looks like.
    func testAStoreWithNoDocumentRendersNothing() {
        let store = WorkspaceStore(
            restoringTree: seed().workspace,
            makeSession: { FakePaneSession($0.spec) },
        )
        store.workspaceMirror.reset()
        XCTAssertTrue(store.tree.sessions.isEmpty)
        XCTAssertFalse(store.canMutate)
        store.newTab(kind: .terminal)
        XCTAssertTrue(store.tree.sessions.isEmpty)
    }

    /// A split's new pane id is minted by the CLIENT, so the leaf appears in host truth with the very
    /// id the store went on to materialize — no round trip, no rename.
    func testASplitMintsItsPaneIDClientSideAndTheDocumentKeepsIt() throws {
        let seed = seed()
        let store = makeStore(seed.workspace)

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        let panes = hostTruthTopology(store)?.tree.sessions.first?.tabs.first?.allPaneIDs() ?? []
        XCTAssertEqual(panes.count, 2)
        XCTAssertTrue(panes.contains(seed.firstPane))
        let minted = try XCTUnwrap(panes.first { $0 != seed.firstPane })
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, minted)
        XCTAssertNotNil(store.handle(for: minted), "the store materialized the very leaf the document named")
    }

    // MARK: - The divider preview

    /// A live drag moves the rendered weights WITHOUT staging anything: the preview is local, and it
    /// is discarded the instant the commit's single intent is staged.
    func testALiveDividerDragPreviewsWithoutStagingAnIntent() throws {
        let seed = seed()
        let store = makeStore(seed.workspace)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let split = try XCTUnwrap(firstSplitID(in: store.tree), "no split to drag")
        let before = store.workspaceMirror.mirror.stateNum

        store.setDividerWeightLive(splitID: split, leadingChildIndex: 0, leadingWeight: 1.5)

        XCTAssertEqual(leadingWeight(of: split, in: store.tree), 1.5)
        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "a drag frame stages nothing")
        XCTAssertEqual(store.workspaceMirror.mirror.stateNum, before, "a drag frame publishes nothing")
    }

    /// The commit sends exactly ONE intent, and the preview stops overlaying the moment it does.
    func testCommittingADividerDragSendsExactlyOneIntent() throws {
        let seed = seed()
        let store = makeStore(seed.workspace)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let split = try XCTUnwrap(firstSplitID(in: store.tree), "no split to drag")
        store.setDividerWeightLive(splitID: split, leadingChildIndex: 0, leadingWeight: 1.5)
        let before = store.workspaceMirror.mirror.stateNum

        store.commitDividerResize()

        XCTAssertEqual(store.workspaceMirror.mirror.stateNum, before + 1, "exactly one document frame")
        XCTAssertEqual(leadingWeight(of: hostTruthTopology(store)?.tree, of: split), 1.5)
        XCTAssertEqual(
            leadingWeight(of: split, in: store.tree), 1.5,
            "the projection carries what the preview showed",
        )
    }

    private func firstSplitID(in tree: TreeWorkspace) -> SplitNodeID? {
        guard case let .split(id, _, _) = tree.activeSession?.activeTab?.root else { return nil }
        return id
    }

    private func leadingWeight(of split: SplitNodeID, in tree: TreeWorkspace) -> Double? {
        guard case let .split(id, _, children) = tree.activeSession?.activeTab?.root, id == split,
              let first = children.first, case let .flex(weight) = first.weight else { return nil }
        return weight
    }

    private func leadingWeight(of tree: TreeWorkspace?, of split: SplitNodeID) -> Double? {
        tree.flatMap { leadingWeight(of: split, in: $0) }
    }

    // MARK: - The ring

    /// ⇧⌘T reads the DOCUMENT's ring. A client-owned LIFO alongside it would reopen a tab the host
    /// never heard of, which the next host frame would then delete.
    func testTheReopenRingIsTheDocumentsRing() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        store.closeTab(seed.second)
        XCTAssertEqual(hostTruthTopology(store)?.closedTabs.count, 1)

        _ = store.reopenClosedTab(at: 0)

        XCTAssertEqual(store.tree.sessions.first?.tabs.count, 2)
        XCTAssertTrue(hostTruthHasTab(seed.second, store))
        XCTAssertEqual(hostTruthTopology(store)?.closedTabs.count, 0)
    }

    // MARK: - Sync input

    /// The armed bit is host truth, carried by `tab/syncInputArmed`.
    func testSyncInputArmsThroughTheDocument() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        XCTAssertFalse(store.syncInputArmed(for: seed.firstPane))

        store.toggleSyncInput(tabID: seed.first)

        XCTAssertTrue(store.syncInputArmed(for: seed.firstPane))
        XCTAssertEqual(hostTruthTopology(store)?.syncInputTabs, [seed.first])

        store.toggleSyncInput(tabID: seed.first)

        XCTAssertFalse(store.syncInputArmed(for: seed.firstPane))
        XCTAssertEqual(hostTruthTopology(store)?.syncInputTabs, [])
    }

    // MARK: - Spawn cwd

    /// A pane's spawn directory rides the intent, so it is in the document rather than only in this
    /// client's memory — which is what makes a relaunch respawn it where the user put it.
    func testANewTabsSpawnCwdLandsInTheDocument() throws {
        let seed = seed()
        let store = makeStore(seed.workspace)
        store.setLastKnownCwd("/Volumes/Lacie/Workspace", for: seed.firstPane)

        store.newTab(kind: .terminal)

        let pane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "no new pane")
        XCTAssertEqual(hostTruthTopology(store)?.spawnCwd[pane], "/Volumes/Lacie/Workspace")
        XCTAssertEqual(store.spawnCwd(for: pane), "/Volumes/Lacie/Workspace")
    }
}
