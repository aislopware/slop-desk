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
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
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

    /// A client looking at NO pane reports the ZERO id — the wire's "none".
    ///
    /// Reached by having no document at all rather than by blanking a tab's `activePane`: the
    /// document's tab decoder repairs a missing focus to the tab's first leaf, so "a tab with no
    /// active pane" is a state host truth cannot carry. What it CAN carry is no workspace, and that
    /// is the state a client actually finds itself in — refused by the host, or not yet subscribed.
    func testAViewOfNoPaneReportsNone() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertEqual(store.currentWorkspaceView().paneID, paneID.raw, "the active pane, by its own id")

        store.workspaceMirror.reset()
        XCTAssertEqual(store.currentWorkspaceView().paneID, WireMessage.newSessionID)
        XCTAssertEqual(store.currentWorkspaceView().tabID, WireMessage.newSessionID)
    }

    /// Who ELSE has this pane on screen. Reads the roster's `viewingPaneID`, in document ids, minus
    /// this client's own entry — a client is not "also" looking at its own pane.
    ///
    /// VIEWING and HOLDING are different facts and both are useful: a client can have a pane on
    /// screen without a channel on it (a background tab it last looked at), and it can hold a
    /// channel on a pane it is not currently showing. ``WorkspaceStore/paneHolders(for:)`` answers
    /// the second question, from the roster's `panes` half.
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

    // MARK: - paneHolders

    /// Who ELSE holds a channel on this pane. The roster's `panes` half publishes one
    /// `WorkspaceRosterPane` per pane carrying one attachment per attached device, joined to
    /// `clients` for a human-readable label — the fact that lets a UI say "held by mac-studio"
    /// instead of guessing.
    func testHoldersNameTheOtherClientsAttachedToAPane() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let mine = UUID()
        let theirs = UUID()
        store.attachWorkspaceChannel(WorkspaceChannelClient(
            box: store.workspaceMirror, clientInstanceID: mine, clientKind: .macOS, label: "mac-studio",
            open: { throw CancellationError() }, close: { _ in },
        ))

        applyRoster(
            to: store,
            clients: [
                rosterClient(mine, label: "mac-studio"),
                rosterClient(theirs, label: "iPad"),
            ],
            panes: [WorkspaceRosterPane(
                paneID: paneID.raw,
                resolvedCols: 120,
                resolvedRows: 40,
                attachments: [
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: mine, contributes: true, cols: 120, rows: 40,
                    ),
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: theirs, contributes: false, cols: 60, rows: 20,
                    ),
                ],
            )],
        )

        XCTAssertEqual(
            store.paneHolders(for: paneID), ["iPad"],
            "the other device is named; this client is not 'also' holding its own pane",
        )
    }

    /// The `slopdesk-client` case, and the reason the join must never be a force-unwrap: a CLI opens
    /// no workspace channel at all, so the host publishes its attachment with the all-zero id. It is
    /// a real client holding a real pane at a real size — dropping the RECORD would make the pane
    /// look unheld, and dropping the attachment would make the size fold's arithmetic unexplainable.
    func testAnUnlabelledAttachmentIsCountedAndNamedNeutrally() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let mine = UUID()
        store.attachWorkspaceChannel(WorkspaceChannelClient(
            box: store.workspaceMirror, clientInstanceID: mine, clientKind: .macOS, label: "mac-studio",
            open: { throw CancellationError() }, close: { _ in },
        ))

        applyRoster(
            to: store,
            clients: [rosterClient(mine, label: "mac-studio")],
            panes: [WorkspaceRosterPane(
                paneID: paneID.raw,
                resolvedCols: 80,
                resolvedRows: 24,
                attachments: [
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: mine, contributes: true, cols: 120, rows: 40,
                    ),
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: WireMessage.newSessionID, contributes: true, cols: 80, rows: 24,
                    ),
                ],
            )],
        )

        XCTAssertEqual(
            store.paneHolders(for: paneID), [WorkspaceStore.unlabelledHolder],
            "the CLI is counted, and named for what it is rather than dropped",
        )
        XCTAssertEqual(
            store.paneAttachmentCount(for: paneID), 2,
            "both attachments count — the fold's arithmetic has to be explainable",
        )
    }

    /// A pane nobody else holds says nothing. Silence is the correct readout for the common case.
    func testAPaneOnlyThisClientHoldsNamesNobody() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let mine = UUID()
        store.attachWorkspaceChannel(WorkspaceChannelClient(
            box: store.workspaceMirror, clientInstanceID: mine, clientKind: .macOS, label: "mac-studio",
            open: { throw CancellationError() }, close: { _ in },
        ))

        applyRoster(
            to: store,
            clients: [rosterClient(mine, label: "mac-studio")],
            panes: [WorkspaceRosterPane(
                paneID: paneID.raw,
                resolvedCols: 120,
                resolvedRows: 40,
                attachments: [WorkspaceRosterPane.Attachment(
                    clientInstanceID: mine, contributes: true, cols: 120, rows: 40,
                )],
            )],
        )

        XCTAssertEqual(store.paneHolders(for: paneID), [])
        XCTAssertEqual(store.paneAttachmentCount(for: paneID), 1)
    }

    // MARK: - The resolved grid, and who clamped it

    /// A size-passive client (iOS) reads the grid the Macs folded to — and the sentence that says
    /// why it is that size. Without the readout a phone shows a pane that is the wrong size for no
    /// stated reason.
    func testASizePassiveClientReadsTheResolvedGridAndItsAuthor() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        let mine = UUID()
        let mac = UUID()
        store.attachWorkspaceChannel(WorkspaceChannelClient(
            box: store.workspaceMirror, clientInstanceID: mine, clientKind: .iOS, label: "iPhone",
            open: { throw CancellationError() }, close: { _ in },
        ))

        applyRoster(
            to: store,
            clients: [rosterClient(mine, label: "iPhone"), rosterClient(mac, label: "MacBook Pro")],
            panes: [WorkspaceRosterPane(
                paneID: paneID.raw,
                resolvedCols: 120,
                resolvedRows: 40,
                attachments: [
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: mac, contributes: true, cols: 120, rows: 40,
                    ),
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: mine, contributes: false, cols: 60, rows: 20,
                    ),
                ],
            )],
        )

        let grid = try XCTUnwrap(store.paneResolvedGrid(for: paneID))
        XCTAssertEqual(grid.cols, 120)
        XCTAssertEqual(grid.rows, 40)
        XCTAssertEqual(store.paneGridReadout(for: paneID), "120×40 · sized by MacBook Pro")
    }

    /// No roster at all (the document is off, or the first presence frame has not landed): no grid
    /// and no readout, so the pane renders exactly as it always did.
    func testNoRosterMeansNoLetterboxAndNoReadout() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertNil(store.paneResolvedGrid(for: paneID))
        XCTAssertNil(store.paneGridReadout(for: paneID))
    }

    private func rosterClient(_ id: UUID, label: String) -> WorkspaceRosterClient {
        WorkspaceRosterClient(
            clientInstanceID: id, clientKind: 0, flags: 0,
            viewingTabID: UUID(), viewingPaneID: WireMessage.newSessionID, cols: 0, rows: 0,
            label: label,
        )
    }

    private func applyRoster(
        to store: WorkspaceStore,
        clients: [WorkspaceRosterClient],
        panes: [WorkspaceRosterPane],
    ) {
        store.workspaceMirror.apply(
            kind: WorkspaceEventKind.presence.rawValue,
            epoch: UUID(), baseStateNum: 0, newStateNum: 0,
            payload: WorkspacePresenceRoster(clients: clients, panes: panes).encode(),
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
