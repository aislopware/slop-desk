import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The table of liveness follows the document, not just this device's gestures.
///
/// `WorkspaceStore.tree` is a projection of the workspace document, so the leaf set can move with no
/// local edge at all: another client splits, the host publishes its first snapshot after a subscribe,
/// an optimistic patch rolls back. Every one of those has to reach the registry — a leaf the document
/// added needs a live session, and a leaf it removed must not keep one.
///
/// Deliberately driven through ``WorkspaceStore/graftDocumentTree(_:file:line:)`` rather than a
/// mutator: a mutator reconciles on its own next line, which is exactly what hides this.
@MainActor
final class WorkspaceDocumentReconcileTests: XCTestCase {
    private struct Seed {
        var workspace: TreeWorkspace
        var session: Session
        var pane: PaneID
    }

    private func seed() -> Seed {
        let pane = PaneID()
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [Tab(id: TabID(), title: "one", root: .leaf(pane), activePane: pane)],
            specs: [pane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        return Seed(
            workspace: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            session: session,
            pane: pane,
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

    /// RED before the mirror's change hook reconciled: a pane another client added rendered with no
    /// live session at all — a blank leaf with no PTY channel, no error and no log.
    func testAPaneTheDocumentAddsGetsALiveSession() throws {
        let seed = seed()
        let store = makeStore(seed.workspace)
        let added = PaneID()
        var session = seed.session
        session.tabs.append(Tab(id: TabID(), title: "two", root: .leaf(added), activePane: added))
        session.specs[added] = PaneSpec(kind: .terminal, title: "Terminal")

        try store.graftDocumentTree(
            TreeWorkspace(sessions: [session], activeSessionID: session.id),
        )

        XCTAssertTrue(store.tree.contains(added), "the projection carries the new leaf")
        XCTAssertNotNil(store.handle(for: added), "…and so does the registry")
    }

    /// RED before the hook reconciled: the pane left the projection while its `LivePaneSession` — and
    /// the mux channel behind it — stayed up forever.
    func testAPaneTheDocumentRemovesLosesItsLiveSession() async throws {
        let seed = seed()
        let survivor = PaneID()
        var session = seed.session
        session.tabs.append(Tab(id: TabID(), title: "two", root: .leaf(survivor), activePane: survivor))
        session.specs[survivor] = PaneSpec(kind: .terminal, title: "Terminal")
        let store = makeStore(TreeWorkspace(sessions: [session], activeSessionID: session.id))
        let handle = try XCTUnwrap(store.handle(for: seed.pane) as? FakePaneSession)

        var trimmed = session
        trimmed.tabs.removeFirst()
        trimmed.specs[seed.pane] = nil
        try store.graftDocumentTree(
            TreeWorkspace(sessions: [trimmed], activeSessionID: trimmed.id),
        )

        XCTAssertNil(store.handle(for: seed.pane), "the registry drops the leaf the document dropped")
        await store.quiesce()
        XCTAssertEqual(handle.teardownCount, 1, "…and tears its session down rather than leaking it")
    }

    /// The ABSENCE of a document is not an empty one.
    ///
    /// `WorkspaceChannelClient.stop()` resets the mirror on the way to EVERY re-subscribe, so `tree`
    /// is a workspace of zero sessions for that window. Reconciling against it would tear down every
    /// terminal on screen and rebuild it from the snapshot a moment later — a full dismantle-and-replay
    /// on each reconnect, for a state that is not an error at all.
    func testADroppedSubscriptionKeepsEveryLiveSession() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        let handle = store.handle(for: seed.pane) as? FakePaneSession

        store.workspaceMirror.reset()

        XCTAssertTrue(store.tree.sessions.isEmpty, "there is no layout to render until the next snapshot")
        XCTAssertTrue(store.handle(for: seed.pane) === handle, "…and the pane's session is untouched")
        XCTAssertEqual(handle?.teardownCount, 0)
    }

    /// The connect shape: the host's own document replaces the launch seed wholesale, with pane ids
    /// this client has never seen. Every one of them needs a session.
    func testTheHostsFirstDocumentMaterializesItsOwnPanes() throws {
        let store = makeStore(seed().workspace)
        let hostPaneA = PaneID()
        let hostPaneB = PaneID()
        let session = Session(
            id: SessionID(),
            name: "host",
            tabs: [
                Tab(id: TabID(), title: "a", root: .leaf(hostPaneA), activePane: hostPaneA),
                Tab(id: TabID(), title: "b", root: .leaf(hostPaneB), activePane: hostPaneB),
            ],
            specs: [
                hostPaneA: PaneSpec(kind: .terminal, title: "Terminal"),
                hostPaneB: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )

        try store.graftDocumentTree(TreeWorkspace(sessions: [session], activeSessionID: session.id))

        XCTAssertNotNil(store.handle(for: hostPaneA))
        XCTAssertNotNil(store.handle(for: hostPaneB))
        XCTAssertEqual(store.allSessionHandles.count, 2, "and nothing from the seed is left running")
    }
}
