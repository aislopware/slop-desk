import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Where a NEW session lands — `newSession` (op 18), the op every session-minting path now goes
/// through, templates included: `newSessionFromTemplate` opens with it and then splits the extra
/// panes off the first one.
///
/// Appends at the END, becomes active, leaves every other session byte-identical, and holds the
/// **specs == leafIDs invariant** for the whole workspace.
final class NewSessionLandingTests: XCTestCase {
    private func twoSessionWorkspace() -> TreeWorkspace {
        let a = Session.singlePane(name: "A", spec: PaneSpec(kind: .terminal, title: "A"))
        let b = Session.singlePane(name: "B", spec: PaneSpec(kind: .terminal, title: "B"))
        return TreeWorkspace(sessions: [a, b], activeSessionID: a.id)
    }

    func testAppendsAtEndAndBecomesActive() {
        let ws = twoSessionWorkspace()
        let (out, pane) = TreeIntent.newSession(in: ws, name: "New", spec: PaneSpec(kind: .terminal, title: "New"))
        XCTAssertEqual(out.sessions.count, 3)
        XCTAssertEqual(out.sessions.last?.name, "New", "the mint goes on the end, not beside the active one")
        XCTAssertEqual(out.activeSessionID, out.sessions.last?.id)
        XCTAssertEqual(out.sessions.last?.allPaneIDs(), [pane], "the proposed id is the one that lands")
    }

    func testOtherSessionsUntouched() {
        let ws = twoSessionWorkspace()
        let (out, _) = TreeIntent.newSession(in: ws, name: "New", spec: PaneSpec(kind: .terminal, title: "New"))
        // The pre-existing two sessions are byte-identical (tabs/specs/active state preserved).
        XCTAssertEqual(Array(out.sessions.prefix(2)), ws.sessions)
    }

    func testInvariantPreserved() {
        let ws = twoSessionWorkspace()
        let (out, _) = TreeIntent.newSession(in: ws, name: "New", spec: PaneSpec(kind: .terminal, title: "New"))
        XCTAssertTrue(out.isInvariantHeld(), "specs == leafIDs holds for the whole workspace after the mint")
    }

    /// A proposed id already in the document is refused — the mint cannot smuggle a duplicate leaf in,
    /// which is what makes a retried intent safe rather than destructive.
    func testAProposedIdAlreadyInUseIsRefused() throws {
        let ws = twoSessionWorkspace()
        let taken = try XCTUnwrap(ws.sessions.first?.allPaneIDs().first)
        let outcome = WorkspaceIntentApplier.apply(
            op: WorkspaceIntentOp.newSession.rawValue,
            args: WorkspaceIntentArgs.encode(
                newSession: SessionID(), newPane: taken, name: "New", spawnCwd: nil,
            ),
            to: WorkspaceTopology(tree: ws),
            documentIsPristine: true,
        )
        XCTAssertEqual(outcome, .rejectedInvalid)
    }
}
