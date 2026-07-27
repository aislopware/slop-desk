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
        WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
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

    // MARK: - One id

    /// The document keys panes by the id the CLIENT proposed, which is the pane's own ``PaneID``. So
    /// host truth and this client's control-push overlay land on the SAME key — which is what lets the
    /// erasure rule (host truth deletes the overlay entry for any key it supplies) actually fire.
    ///
    /// Keyed apart, a client guess that host truth contradicted would win forever. That is the bug.
    func testHostTruthErasesTheOverlayItContradicts() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        store.handleCommandStarted(id: paneID)
        store.noteTitlePushed("vi .", for: paneID)
        store.handleCommandStarted(id: paneID)
        XCTAssertNil(store.liveProgramTitle(for: paneID), "the client alone cannot tell")

        applySnapshot(
            PaneLiveness(
                paneID: paneID.raw, liveness: .attached, liveTitle: "main.swift - NVIM", titleFresh: true,
            ),
            to: store,
        )

        XCTAssertEqual(store.liveProgramTitle(for: paneID), "main.swift - NVIM")
        XCTAssertTrue(
            store.workspaceMirror.mirror.fastPath.isEmpty,
            "host truth erases the overlay it contradicted — which needs both to be keyed the same",
        )
    }

    /// A pane with no host truth yet still reads its own overlay: the reads work headlessly, with no
    /// channel and nothing to reconcile against.
    func testAPaneWithNoHostTruthReadsItsOwnOverlay() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        store.noteTitlePushed("nvim", for: paneID)

        XCTAssertEqual(store.liveProgramTitle(for: paneID), "nvim")
    }

    // MARK: - Presence

    /// A TAB with no active pane reports the ZERO id — the wire's "none", which the host reads as a
    /// client looking at nothing in particular.
    func testAViewOfNoPaneReportsNone() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertEqual(store.currentWorkspaceView().paneID, paneID.raw, "the active pane, by its own id")

        store.tree.sessions[0].tabs[0].activePane = nil
        XCTAssertEqual(store.currentWorkspaceView().paneID, WireMessage.newSessionID)
    }

    /// Who ELSE has this pane on screen. Reads the roster's `viewingPaneID`, in document ids, minus
    /// this client's own entry — a client is not "also" looking at its own pane.
    ///
    /// Deliberately viewers and not owners: attachment needs the pane channel to declare whose it is,
    /// and only the workspace channel's subscribe carries a `clientInstanceID` today.
    func testViewersNameTheOtherClientsLookingAtAPane() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let hostPaneID = paneID.raw
        let mine = UUID()
        let theirs = UUID()
        store.attachWorkspaceChannel(WorkspaceChannelClient(
            box: store.workspaceMirror, clientInstanceID: mine, clientKind: .macOS, label: "mac-studio",
            open: { throw CancellationError() }, close: { _ in },
        ))

        store.workspaceMirror.apply(
            kind: WorkspaceEventKind.presence.rawValue,
            epoch: UUID(), baseStateNum: 0, newStateNum: 0,
            payload: WorkspacePresenceRoster(clients: [
                WorkspaceRosterClient(
                    clientInstanceID: mine, clientKind: 0, flags: 0,
                    viewingTabID: UUID(), viewingPaneID: hostPaneID, cols: 0, rows: 0,
                    label: "mac-studio",
                ),
                WorkspaceRosterClient(
                    clientInstanceID: theirs, clientKind: 1, flags: 0,
                    viewingTabID: UUID(), viewingPaneID: hostPaneID, cols: 0, rows: 0,
                    label: "iPad",
                ),
            ]).encode(),
        )

        XCTAssertEqual(
            store.paneViewers(for: paneID), ["iPad"],
            "the other client is listed; this one is not 'also' looking at its own pane",
        )
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
