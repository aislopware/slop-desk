import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// The per-pane facts a client reads back OUT of the workspace document.
///
/// Most of a pane's liveness survives a reattach without the document: the host re-asserts types
/// 26/27/36 (foreground process, agent status + label, session intent) for a returning client whose
/// mirrors reset on reconnect. The open command's TEXT is the exception — it lives in the client's own
/// `CommandBlock` model, which is per-MATERIALIZATION, so a pane whose bytes this client has never
/// rendered has no blocks at all and nothing ever tells it otherwise.
@MainActor
final class WorkspaceMirrorFactsTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    @discardableResult
    private func applySnapshot(
        _ record: PaneLiveness, to store: WorkspaceStore, epoch: UUID = UUID(), stateNum: Int64 = 1,
    ) -> HostWorkspaceMirror.ApplyOutcome {
        store.workspaceMirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: epoch,
            baseStateNum: 0,
            newStateNum: stateNum,
            payload: WorkspaceStateCodec.encodeSnapshot(HostWorkspaceState(record.entries())),
        )
    }

    // MARK: - Whose pane id?

    /// The document keys panes by the id the HOST mints on channel open. This client's ``PaneID`` is a
    /// different UUID entirely — minted here, when the pane was created — so a client that queries its
    /// own id reads a key host truth never writes, and the whole document lands where nothing looks.
    ///
    /// The mapping is already on disk: `onResumeIdentitySnapshot` fires on every connect and the store
    /// persists what it learns into ``PaneSpec/resumeSessionID``.
    func testHostTruthLandsUnderTheHostsPaneID() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let hostPaneID = UUID()
        store.noteResumeIdentity(sessionID: hostPaneID, seq: 0, for: paneID)

        applySnapshot(
            PaneLiveness(
                paneID: hostPaneID, liveness: .attached, liveTitle: "main.swift - NVIM", titleFresh: true,
            ),
            to: store,
        )

        XCTAssertEqual(store.liveProgramTitle(for: paneID), "main.swift - NVIM")
    }

    /// …and the overlay has to use that same key, or the two layers are keyed apart and the erasure
    /// rule — the thing that keeps them disjoint — can never fire. A client guess host truth
    /// contradicts would then win forever, which is the bug this document exists to end.
    func testTheOverlayAndHostTruthShareTheHostsKey() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let hostPaneID = UUID()
        store.noteResumeIdentity(sessionID: hostPaneID, seq: 0, for: paneID)

        store.handleCommandStarted(id: paneID)
        store.noteTitlePushed("vi .", for: paneID)
        store.handleCommandStarted(id: paneID)
        XCTAssertNil(store.liveProgramTitle(for: paneID), "the client alone cannot tell")

        applySnapshot(
            PaneLiveness(
                paneID: hostPaneID, liveness: .attached, liveTitle: "main.swift - NVIM", titleFresh: true,
            ),
            to: store,
        )

        XCTAssertEqual(store.liveProgramTitle(for: paneID), "main.swift - NVIM")
        XCTAssertTrue(
            store.workspaceMirror.mirror.fastPath.isEmpty,
            "host truth erases the overlay it contradicted — which needs both to be keyed the same",
        )
    }

    /// A pane that has never connected has no host id to be keyed by. Its overlay stays under the
    /// local id, which is right: there is no host truth to reconcile with yet, and the reads have to
    /// keep working headlessly.
    func testAPaneThatNeverConnectedKeepsItsLocalKey() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        store.noteTitlePushed("nvim", for: paneID)

        XCTAssertEqual(store.liveProgramTitle(for: paneID), "nvim")
    }

    // MARK: - runningCommand

    /// The degradation, then the repair. A client with no blocks of its own can say no more than
    /// "something called zsh is in the foreground"; the document knows the command line.
    func testTheHostsOpenCommandTitlesARowThatHasNoBlocksOfItsOwn() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        XCTAssertEqual(
            store.liveRunningCommand(for: paneID, processLabel: "zsh"), "zsh",
            "with no blocks and no document the row can only name the process",
        )

        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, runningCommand: "sleep 30 && make"),
            to: store,
        )

        XCTAssertEqual(store.liveRunningCommand(for: paneID, processLabel: "zsh"), "sleep 30 && make")
    }

    /// The command finishing REMOVES the fact. A snapshot that no longer carries it must take the
    /// title with it — a `runningCommand` that latches is the same "edge published, value retained
    /// nowhere" failure one layer up.
    func testACommandThatFinishedStopsTitlingTheRow() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let epoch = UUID()

        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, runningCommand: "make check"),
            to: store, epoch: epoch,
        )
        XCTAssertEqual(store.liveRunningCommand(for: paneID, processLabel: "zsh"), "make check")

        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached),
            to: store, epoch: epoch, stateNum: 2,
        )
        XCTAssertEqual(store.liveRunningCommand(for: paneID, processLabel: "zsh"), "zsh")
    }

    /// A blank command is not a command. The host emits `""` for a block whose text it never saw
    /// (a prompt whose command line scrolled past), and blanking the row would read as a bug.
    func testABlankHostedCommandFallsThrough() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        applySnapshot(
            PaneLiveness(paneID: paneID.raw, liveness: .attached, runningCommand: "   "),
            to: store,
        )

        XCTAssertEqual(store.liveRunningCommand(for: paneID, processLabel: "zsh"), "zsh")
    }

    /// No document AND no process label leaves nothing to say — `nil`, so the caller's own chain
    /// (last executed command → cwd folder → generic) keeps resolving.
    func testNothingKnownStaysAbsent() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        XCTAssertNil(store.liveRunningCommand(for: paneID, processLabel: nil))
    }
}
