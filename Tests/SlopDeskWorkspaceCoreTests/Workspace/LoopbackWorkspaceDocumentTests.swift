import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The seam that lets a test hold a LIVE workspace document — no socket, no `HostServer`, and no
/// suspension point between asking for a change and reading it back.
///
/// The problem it answers is measurable rather than aesthetic. ``WorkspaceChannelClient/send(intent:args:now:)``
/// refuses anything that is not `.live`, and `.live` is published only from inside the async `start()`
/// run loop. Every store mutator is synchronous. So once the store's layout comes from the document,
/// a test that cannot reach `.live` gets a silent no-op from every one of them — the layout simply
/// stops moving, with nothing logged and nothing to grep for.
///
/// ``LoopbackWorkspaceDocument`` closes that by BEING the host: the same
/// ``WorkspaceIntentApplier``, the same `encodeDiff` → `decodeDiff` round trip, the same
/// result-then-document frame order the real session drains in, all on the caller's turn.
@MainActor
final class LoopbackWorkspaceDocumentTests: XCTestCase {
    // MARK: - Fixtures

    /// One session, two single-pane tabs — enough shape that closing one has somewhere to land.
    private struct Seed {
        var workspace: TreeWorkspace
        var session: SessionID
        var tab: TabID
        var other: TabID
        var pane: PaneID
    }

    private struct Fixture {
        var box: WorkspaceMirrorBox
        var document: LoopbackWorkspaceDocument
        var seed: Seed
        var tab: TabID { seed.tab }
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
            tab: session.tabs[0].id,
            other: session.tabs[1].id,
            pane: first,
        )
    }

    private func fixture() -> Fixture {
        let seed = seed()
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: seed.workspace))
        let box = WorkspaceMirrorBox()
        let document = LoopbackWorkspaceDocument(box: box)
        document.install(state, pristine: true)
        return Fixture(box: box, document: document, seed: seed)
    }

    private func title(of tab: TabID, in box: WorkspaceMirrorBox) -> String? {
        box.hostTruth.string(WorkspaceKey(.tab, tab.raw, WorkspaceTabField.title))
    }

    // MARK: - The failure this seam exists to remove

    /// A client built the production way refuses every intent until its run loop reaches `.live`.
    ///
    /// This is the whole reason the seam is needed, stated as a pin: the document is seeded, the
    /// applier would accept the rename, and the call still returns `false` without staging anything.
    func testAChannelThatIsNotLiveRefusesEveryIntent() {
        let f = fixture()
        let client = WorkspaceChannelClient(
            box: f.box,
            clientKind: .macOS,
            label: "mac-studio",
            open: { throw SlopDeskTransportError.notConnected("no transport in this test") },
            close: { _ in },
        )

        XCTAssertEqual(client.state, .idle)
        XCTAssertFalse(
            client.send(intent: .renameTab, args: WorkspaceIntentArgs.encode(id: f.tab.raw, name: "build")),
            "a synchronous caller cannot reach `.live`, so the intent never leaves",
        )
        XCTAssertEqual(f.box.pendingIntentCount, 0, "nothing is staged either")
        XCTAssertEqual(title(of: f.tab, in: f.box), "one")
    }

    // MARK: - The seam

    /// The headline: a store with no network holds a document that ANSWERS, and the answer is host
    /// truth — `entries` — by the time the call returns.
    ///
    /// Asserted on `entries` rather than `topology` on purpose. `topology` reads through the pending
    /// layer, so an optimistic patch alone would satisfy it; `entries` moves only when a decoded
    /// document frame lands.
    func testAnIntentServedInProcessIsHostTruthOnTheNextLine() throws {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0.spec) })
        let document = store.attachLoopbackWorkspaceDocument()
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let revisionBefore = store.workspaceMirrorRevision

        let accepted = store.workspaceChannel?.send(
            intent: .renameTab, args: WorkspaceIntentArgs.encode(id: tab.raw, name: "build"),
        )

        XCTAssertEqual(accepted, true)
        XCTAssertEqual(title(of: tab, in: store.workspaceMirror), "build", "host truth moved")
        XCTAssertEqual(
            store.workspaceMirror.topology?.tree.activeSession?.activeTab?.title, "build",
            "and the PROJECTION the UI renders agrees",
        )
        XCTAssertEqual(document.stateNum, 2, "one accepted intent costs exactly one version")
        XCTAssertGreaterThan(store.workspaceMirrorRevision, revisionBefore, "the repaint fired")
    }

    /// An accepted intent leaves NO optimistic patch standing.
    ///
    /// That is a claim about frame ORDER, and it is the host's real one: `WorkspaceChannelSession`
    /// drains `intentResult`s before the document frame, so the result arms the patch at
    /// `framesApplied + 1` and the diff immediately behind it retires the patch in the same turn. A
    /// loopback that published the diff first would leave one inert patch shadowing the document
    /// until the next unrelated intent.
    func testAnAcceptedIntentLeavesNoOptimisticPatchStanding() {
        let f = fixture()
        let client = WorkspaceChannelClient.loopback(document: f.document, label: "loopback")

        XCTAssertTrue(client.send(
            intent: .renameTab, args: WorkspaceIntentArgs.encode(id: f.tab.raw, name: "build"),
        ))

        XCTAssertEqual(f.box.pendingIntentCount, 0, "the result armed it and the diff retired it")
        XCTAssertEqual(title(of: f.tab, in: f.box), "build")
    }

    /// A refusal is ANSWERED, not swallowed: the patch snaps back and the document does not move.
    func testARefusedIntentMovesNothing() throws {
        let f = fixture()
        // Staged by hand, because a client running the same applier would refuse this before it ever
        // reached the document — which is exactly the round trip `stageIntent` exists to save.
        let staged = try XCTUnwrap(f.box.stageIntent(
            op: .renameTab,
            args: WorkspaceIntentArgs.encode(id: f.tab.raw, name: "build"),
            issuedAt: 0,
        ))
        let intent = WorkspaceIntent(
            intentID: staged.intentID,
            op: WorkspaceIntentOp.renameTab.rawValue,
            args: WorkspaceIntentArgs.encode(id: UUID(), name: "ghost"),
        )

        XCTAssertEqual(f.document.serve(intent), .rejectedNotFound)

        XCTAssertEqual(f.box.pendingIntentCount, 0, "the refusal snapped the patch away at once")
        XCTAssertEqual(title(of: f.tab, in: f.box), "one")
        XCTAssertEqual(f.document.stateNum, 1, "a refusal costs no version")
    }

    /// A no-op intent costs no version — the same rule `HostWorkspaceDocument.mutate` enforces by
    /// comparing VALUES rather than by asking whether the closure ran.
    func testAnAcceptedNoOpCostsNoVersion() {
        let f = fixture()
        let client = WorkspaceChannelClient.loopback(document: f.document, label: "loopback")

        XCTAssertTrue(client.send(
            intent: .renameTab, args: WorkspaceIntentArgs.encode(id: f.tab.raw, name: "one"),
        ))

        XCTAssertEqual(f.document.stateNum, 1)
        XCTAssertFalse(f.document.isPristine, "any accepted intent takes ownership of the workspace")
    }

    // MARK: - Drift

    //
    // The drift pin is NOT here, and it is not gone either — it is CROSS-LANGUAGE, so no XCTest can
    // hold it. `testTheLoopbackAndTheHostDocumentAgreeByteForByte` used to run one fixed intent
    // script through BOTH documents and compare the encoded snapshots, because the decision function
    // is shared (`WorkspaceIntentApplier`, which marshals into `slopdesk_wire::document::apply`) but
    // the versioning around it was written twice. `docs/60` F.9 deleted the Swift host, so the second
    // document is `rust/slopdesk-hostserver`'s `workspace.rs`.
    //
    // It now lives in the two places a two-ended wire fact does:
    //
    //   - the SWIFT end MINTS it — `Sources/slopdesk-corevectors/main.swift`, the
    //     `workspaceDocumentVersioning` section, which serves the script through a REAL
    //     ``LoopbackWorkspaceDocument`` and emits, per step, the op and its args, the verdict,
    //     `stateNum`, `isPristine`, whether the step published, and the diff of the two consecutive
    //     states — into `golden/golden_vectors.json`;
    //   - the RUST end REPLAYS it — `rust/slopdesk-hostserver/tests/workspace.rs`'s
    //     `the_versioning_ladder_this_document_climbs_is_the_one_the_swift_loopback_climbs`, which
    //     runs the same script through `WorkspaceDocument` and asserts every field.
    //
    // `slopdesk-gate golden` is what keeps the corpus honest against this side (the key is EMITTED,
    // so a regeneration that moved a byte fails), and the Rust test is what keeps the other side
    // honest against the corpus. The tests above stay: they pin the loopback's OWN behaviour — the
    // frame order, the patch retirement, the mirror lifecycle — none of which the host has.

    // MARK: - Lifecycle

    /// A loopback client neither opens a channel nor resets the mirror.
    ///
    /// `stop()` calls `box.reset()`, which is correct for a subscription — `entries` is only
    /// meaningful against a live one — and fatal here, because the loopback's document IS `entries`.
    /// The store re-opens the channel on every connection establish, so this has to hold structurally
    /// rather than by nobody calling it.
    func testALoopbackClientNeitherOpensNorResetsTheMirror() {
        let f = fixture()
        let client = WorkspaceChannelClient.loopback(document: f.document, label: "loopback")

        client.start()
        client.stop()

        XCTAssertFalse(client.isRunningForTesting, "there is nothing to open")
        XCTAssertEqual(client.state, .live(1), "it was live from the moment it was built")
        XCTAssertEqual(title(of: f.tab, in: f.box), "one", "and host truth survived")
    }

    /// Installing the loopback on a store adopts the launch seed rather than replacing it: the tree
    /// the store restored is the document's opening state, per-pane cache included.
    func testInstallingOnAStoreAdoptsTheLaunchSeed() {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0.spec) })
        let seeded = store.workspaceMirror.hostTruth

        let document = store.attachLoopbackWorkspaceDocument()

        XCTAssertEqual(document.snapshot, seeded)
        XCTAssertEqual(document.stateNum, store.workspaceMirror.knownStateNum)
        XCTAssertEqual(store.workspaceMirror.hostTruth, seeded, "no re-publish, no churn")
    }

    /// A default store still has no channel and no document. This commit is a seam, not a cutover:
    /// nothing installs the loopback unless a caller asks for it.
    func testADefaultStoreInstallsNothing() {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0.spec) })
        XCTAssertNil(store.workspaceChannel)
    }
}
