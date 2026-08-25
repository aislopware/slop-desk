import Foundation
import Observation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// A host frame landing on the mirror has to INVALIDATE the views that read it.
///
/// The mirror is a plain value in a plain box — deliberately, so its convergence is provable without
/// SwiftUI anywhere near it. But that also means nothing about applying a frame is `@Observable`, and
/// a store read funnel that consults only the mirror registers NO dependency: the row would keep
/// rendering its old title until some unrelated mutation happened to repaint it.
///
/// Which is the multi-client case exactly. A second client that changes nothing of its own — no
/// keystroke, no command, no spec edit — is precisely the client whose only source of news is the
/// document. It is the one that must repaint.
@MainActor
final class WorkspaceMirrorObservationTests: XCTestCase {
    /// A flag an Observation callback (nonisolated, `@Sendable`) can raise.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    @discardableResult
    private func applySnapshot(
        _ record: PaneLiveness, to store: WorkspaceStore, epoch: UUID = UUID(), stateNum: Int64 = 1,
    ) -> WorkspaceMirrorBox.ApplyOutcome {
        store.workspaceMirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(HostWorkspaceState(record.entries())),
        )
    }

    // MARK: - Host truth

    func testAHostSnapshotInvalidatesTheTitleRead() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let flag = Flag()

        withObservationTracking {
            _ = store.liveProgramTitle(for: paneID)
        } onChange: {
            flag.raised = true
        }

        applySnapshot(PaneLiveness(
            paneID: paneID.raw, liveness: .attached, liveTitle: "main.swift - NVIM", titleFresh: true,
        ), to: store)

        XCTAssertTrue(flag.raised, "a document that only the host changed still has to repaint the row")
    }

    /// A frame the mirror REFUSES must not invalidate anything: a superseded diff is not news, and
    /// repainting for it would make an idle client re-render on every duplicate the network hands it.
    func testASupersededFrameInvalidatesNothing() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let epoch = UUID()
        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, liveTitle: "nvim", titleFresh: true),
            to: store, epoch: epoch, stateNum: 7,
        )

        let flag = Flag()
        withObservationTracking {
            _ = store.liveProgramTitle(for: paneID)
        } onChange: {
            flag.raised = true
        }

        // A diff based at 3 when we stand at 7 — long since folded in.
        let outcome = store.workspaceMirror.apply(
            kind: WorkspaceEventKind.diff.rawValue, epoch: epoch, baseStateNum: 3, newStateNum: 4,
            payload: WorkspaceStateCodec.encodeDiff(WorkspaceStateDiff(sets: [], deletes: [])),
        )

        XCTAssertEqual(outcome, WorkspaceMirrorBox.ApplyOutcome.ignored)
        XCTAssertFalse(flag.raised, "a duplicate the mirror discards is not a repaint")
    }

    // MARK: - This client's own pushes

    /// The fast path is the other writer. A title push arriving on a pane's own control channel has to
    /// invalidate the same read — the overlay is what drives the row whenever the document is off.
    func testAControlPushInvalidatesTheTitleRead() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let flag = Flag()

        withObservationTracking {
            _ = store.liveProgramTitle(for: paneID)
        } onChange: {
            flag.raised = true
        }

        store.workspaceMirror.writeFastPath(
            pane: paneID.raw, field: WorkspacePaneField.liveTitle, string: "main.swift - NVIM",
        )

        XCTAssertTrue(flag.raised)
    }

    /// A push that changes nothing changes nothing. The box's dirty guard is what keeps a pane
    /// re-asserting the same title on every reattach from churning the rail.
    func testARepeatedIdenticalPushInvalidatesNothing() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.workspaceMirror.writeFastPath(
            pane: paneID.raw, field: WorkspacePaneField.liveTitle, string: "nvim",
        )

        let flag = Flag()
        withObservationTracking {
            _ = store.liveProgramTitle(for: paneID)
        } onChange: {
            flag.raised = true
        }
        store.workspaceMirror.writeFastPath(
            pane: paneID.raw, field: WorkspacePaneField.liveTitle, string: "nvim",
        )

        XCTAssertFalse(flag.raised, "an unchanged value is not an edge")
    }

    /// Stopping the channel empties the mirror. Every row that was rendering from host truth has to
    /// find that out — otherwise a disconnect leaves the rail frozen on a document nobody stands behind.
    func testResettingTheMirrorInvalidatesTheTitleRead() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.noteTitlePushed("nvim", for: paneID)

        let flag = Flag()
        withObservationTracking {
            _ = store.liveProgramTitle(for: paneID)
        } onChange: {
            flag.raised = true
        }
        store.workspaceMirror.reset()

        XCTAssertTrue(flag.raised)
    }
}
