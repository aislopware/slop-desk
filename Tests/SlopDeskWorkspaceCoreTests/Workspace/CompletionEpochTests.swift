import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// The unread-finish marker, as a comparison instead of a latch.
///
/// A latch is a fact only its owner holds. `paneUnseenDone` was set on the client's own `.done` edge
/// and lived in memory, so it disagreed between two clients and died on relaunch — while the host's
/// own done→idle decay (seconds) meant a client that was disconnected across the finish could never
/// learn of it at all.
///
/// A monotone counter the host publishes, compared against what THIS device has already seen, has
/// none of those properties: it is askable at any time, it survives the decay, and each viewer
/// answers for itself with no per-client state on the host.
@MainActor
final class CompletionEpochTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// Publishes `record` as a host snapshot, carrying the store's CURRENT topology alongside it.
    ///
    /// The topology is not decoration. A snapshot under a fresh epoch resets the mirror, and the
    /// store's layout IS the mirror — so a payload of liveness alone would leave a workspace with no
    /// panes, and a marker about a pane that does not exist is not a test of anything. A real host
    /// republishes its whole document on every restart, which is exactly this.
    private func applySnapshot(
        _ record: PaneLiveness, to store: WorkspaceStore, epoch: UUID = UUID(), stateNum: Int64 = 1,
    ) {
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: store.tree))
        for entry in record.entries() { state.set(entry.key, entry.value) }
        store.workspaceMirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(state),
        )
    }

    /// Two panes: one focused, one not. The unfocused one is what a marker is FOR.
    private func makeBackgroundPane(_ store: WorkspaceStore) throws -> PaneID {
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.newTab(kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first)
        return second
    }

    // MARK: - The host's counter reaches a client that was not listening

    /// The case a latch cannot serve. The agent finished while this client was away; by the time it
    /// reconnects the host's status has long since decayed back to idle, so no `.done` edge will ever
    /// arrive. The counter is still there to be asked.
    func testAFinishThatHappenedWhileAwayIsStillUnread() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)
        let hostPaneID = paneID.raw

        XCTAssertFalse(store.paneUnseenDone.contains(paneID), "nothing has finished")

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 3),
            to: store,
        )

        XCTAssertTrue(
            store.paneUnseenDone.contains(paneID),
            "a counter this device has never seen is an unread finish, with no edge required",
        )
    }

    /// Acknowledging records WHAT was acknowledged. The next finish moves the counter again and the
    /// marker comes back — which a boolean latch can express only by being re-set on an edge it may
    /// never receive.
    func testAcknowledgingRecordsTheCounterAndTheNextFinishReturns() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)
        let hostPaneID = paneID.raw
        let epoch = UUID()

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 1),
            to: store, epoch: epoch,
        )
        XCTAssertTrue(store.paneUnseenDone.contains(paneID))

        store.clearAgentBadge(paneID)
        XCTAssertFalse(store.paneUnseenDone.contains(paneID))

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 2),
            to: store, epoch: epoch, stateNum: 2,
        )
        XCTAssertTrue(store.paneUnseenDone.contains(paneID), "a NEW finish is unread again")
    }

    /// A host restart resets its counters with the document epoch it mints. A `seen` value carried
    /// across that would sit ABOVE the counter and silence the pane forever — so the comparison is
    /// inequality, not "greater than", and a counter back at zero simply means nothing has finished.
    func testAHostRestartDoesNotSilenceThePaneForever() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)
        let hostPaneID = paneID.raw

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 9),
            to: store, epoch: UUID(),
        )
        store.clearAgentBadge(paneID)

        // A fresh daemon: new document epoch, counters from zero, then one finish.
        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 1),
            to: store, epoch: UUID(),
        )

        XCTAssertTrue(
            store.paneUnseenDone.contains(paneID),
            "1 != 9, so the restarted host's first finish is unread — not swallowed by a stale seen",
        )
    }

    // MARK: - A finish you watched happen

    /// The rule the old latch spelled as "do not set it while the pane is visible", said once —
    /// at the comparison — instead of at every edge that could move either side of it. Said only at
    /// the edge, it loses to ordering: with the document live the host's counter and the client's
    /// own `.done` arrive on different paths.
    func testAFinishOnAVisiblePaneIsAlreadySeen() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let hostPaneID = paneID.raw
        store.isAppActive = true

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 4),
            to: store,
        )

        XCTAssertFalse(
            store.paneUnseenDone.contains(paneID),
            "you were looking at it — there is nothing unread about it",
        )
    }

    // MARK: - With no document at all

    /// Default-OFF is still the shipping path. Without a document the client bumps its OWN counter on
    /// the `.done` edge, into the same overlay the host would erase — so the marker behaves exactly
    /// as it did, and turning the flag on changes where the number comes from, not what it means.
    func testTheClientKeepsItsOwnCounterWithNoDocument() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)

        store.setAgentStatus(.working, for: paneID)
        store.setAgentStatus(.done, for: paneID)

        XCTAssertTrue(store.paneUnseenDone.contains(paneID))

        store.clearAgentBadge(paneID)
        XCTAssertFalse(store.paneUnseenDone.contains(paneID))

        // The agent takes another turn.
        store.setAgentStatus(.working, for: paneID)
        store.setAgentStatus(.done, for: paneID)
        XCTAssertTrue(store.paneUnseenDone.contains(paneID))
    }

    /// New activity supersedes an unread finish — the herdr rule. Reading it off the counter means
    /// marking the current one seen, not clearing a bit that the next host frame would set again.
    func testTheAgentMovingOnMarksTheFinishSeen() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)

        store.setAgentStatus(.working, for: paneID)
        store.setAgentStatus(.done, for: paneID)
        XCTAssertTrue(store.paneUnseenDone.contains(paneID))

        store.setAgentStatus(.working, for: paneID)
        XCTAssertFalse(store.paneUnseenDone.contains(paneID), "the agent moved on")

        // …and it stays seen when the document re-asserts the same counter.
        store.setAgentStatus(.done, for: paneID)
        store.clearAgentBadge(paneID)
        let held = store.paneCompletionEpoch(paneID)
        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, completionEpoch: held),
            to: store,
        )
        XCTAssertFalse(store.paneUnseenDone.contains(paneID))
    }

    // MARK: - Persistence

    /// Device-local and persisted, so a relaunch does not re-announce a finish you already read.
    /// Scoped by the DOCUMENT epoch it was recorded under: a map carried across a host restart could
    /// hold a `seen` above the restarted counter, which is the one way this can go permanently quiet.
    func testTheSeenMapIsPersistedAndScopedToItsDocumentEpoch() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)
        let hostPaneID = paneID.raw
        var saved: SeenCompletionEpochs?
        store.completionSeen.save = { saved = $0 }
        let documentEpoch = UUID()

        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 5),
            to: store, epoch: documentEpoch,
        )
        store.clearAgentBadge(paneID)

        let persisted = try XCTUnwrap(saved)
        XCTAssertEqual(persisted.documentEpoch, documentEpoch)
        XCTAssertEqual(persisted.seen[hostPaneID], 5)

        // A relaunch under the SAME document keeps the acknowledgement. The relaunched store restores
        // the SAME tree, so the pane keeps its id — which is exactly the id the seen map is keyed by.
        let restored = store.tree
        let returning = WorkspaceStore(
            restoringTree: restored, liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        returning.attachLoopbackWorkspaceDocument()
        returning.completionSeen.load = { persisted }
        let returningPane = paneID
        try returning.focusPaneTree(XCTUnwrap(returning.tree.allPaneIDs().first { $0 != returningPane }))
        returning.loadCompletionSeen()
        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 5),
            to: returning, epoch: documentEpoch,
        )
        XCTAssertFalse(returning.paneUnseenDone.contains(returningPane), "already read")

        // …and a relaunch against a DIFFERENT document drops it, because the counters restarted.
        let elsewhere = WorkspaceStore(
            restoringTree: restored, liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        elsewhere.attachLoopbackWorkspaceDocument()
        elsewhere.completionSeen.load = { persisted }
        let elsewherePane = paneID
        try elsewhere.focusPaneTree(XCTUnwrap(elsewhere.tree.allPaneIDs().first { $0 != elsewherePane }))
        elsewhere.loadCompletionSeen()
        applySnapshot(
            PaneLiveness(paneID: hostPaneID, liveness: .attached, completionEpoch: 5),
            to: elsewhere, epoch: UUID(),
        )
        XCTAssertTrue(
            elsewhere.paneUnseenDone.contains(elsewherePane),
            "a seen value from another daemon's counting means nothing here",
        )
    }

    // MARK: - The finish that never had a `.done` to announce it

    /// The hook-free pane, which is most of them: `ClaudeStatus.done` is produced only by an
    /// authoritative `Stop` hook, and the screen-manifest engine that runs otherwise has no `done`
    /// verdict at all — its finish is a `working → idle` edge and nothing more.
    ///
    /// So the marker cannot be keyed off the STATUS. The counter carries the finish; the pane sits
    /// at `.idle` throughout; the row still shows the finished dot, exactly as herdr renders
    /// `Idle && !seen` as Done.
    func testAFinishReadsAsFinishedOnAPaneThatWasNeverDone() throws {
        let store = makeStore()
        let paneID = try makeBackgroundPane(store)
        // The whole turn, as a hook-free host reports it: working, then back to rest.
        store.setAgentStatus(.working, for: paneID)
        store.setAgentStatus(.idle, for: paneID)
        XCTAssertEqual(store.agentStatus(for: paneID), .idle, "no `.done` was ever available")

        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, completionEpoch: 1),
            to: store,
        )

        XCTAssertTrue(store.paneUnseenDone.contains(paneID))
        let entry = store.unseenAttentionPanes.first { $0.pane == paneID }
        XCTAssertEqual(entry?.badge, .finished, "an unread finish is the green dot, `.done` or not")
    }
}
