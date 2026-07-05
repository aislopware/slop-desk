import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``WorkspaceTreeOps/insertSession(_:in:makeActive:)`` — the pure append-a-prebuilt-session op session
/// templates use. Appends without mutating other sessions; `makeActive` repoints the active session;
/// preserves the **specs == leafIDs invariant**.
final class WorkspaceTreeOpsInsertSessionTests: XCTestCase {
    private func twoSessionWorkspace() -> TreeWorkspace {
        let a = Session.singlePane(name: "A", spec: PaneSpec(kind: .terminal, title: "A"))
        let b = Session.singlePane(name: "B", spec: PaneSpec(kind: .terminal, title: "B"))
        return TreeWorkspace(sessions: [a, b], activeSessionID: a.id)
    }

    private func newSession() -> Session {
        let (session, _) = SessionTemplateEngine.makeSession(
            from: SessionTemplate.builtIns[0], name: "New",
        )
        return session
    }

    func testAppendsAtEnd() {
        let ws = twoSessionWorkspace()
        let session = newSession()
        let out = WorkspaceTreeOps.insertSession(session, in: ws, makeActive: false)
        XCTAssertEqual(out.sessions.count, 3)
        XCTAssertEqual(out.sessions.last?.id, session.id)
    }

    func testMakeActiveRepointsActiveSession() {
        let ws = twoSessionWorkspace()
        let session = newSession()
        let out = WorkspaceTreeOps.insertSession(session, in: ws, makeActive: true)
        XCTAssertEqual(out.activeSessionID, session.id)
    }

    func testMakeActiveFalseLeavesActiveUnchanged() {
        let ws = twoSessionWorkspace()
        let before = ws.activeSessionID
        let out = WorkspaceTreeOps.insertSession(newSession(), in: ws, makeActive: false)
        XCTAssertEqual(out.activeSessionID, before)
    }

    func testOtherSessionsUntouched() {
        let ws = twoSessionWorkspace()
        let out = WorkspaceTreeOps.insertSession(newSession(), in: ws, makeActive: true)
        // The pre-existing two sessions are byte-identical (tabs/specs/active state preserved).
        XCTAssertEqual(Array(out.sessions.prefix(2)), ws.sessions)
    }

    func testInvariantPreserved() {
        let ws = twoSessionWorkspace()
        let out = WorkspaceTreeOps.insertSession(newSession(), in: ws, makeActive: true)
        XCTAssertTrue(out.isInvariantHeld(), "specs == leafIDs holds for the whole workspace after insert")
    }
}
