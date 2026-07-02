import XCTest
@testable import AislopdeskClient
@testable import AislopdeskWorkspaceCore

/// R-lifecycle #3: the keep-mounted invariant must span SESSIONS, not just the active session's tabs — else a
/// session switch dismantles every outgoing surface and returning repaints from the lossy 256 KB ring. The
/// store tracks a bounded ``WorkspaceStore/retainedSessionIDs`` LRU (active + previous) that `SplitContainer`
/// renders as hidden mounted layers; these tests pin the LRU logic headlessly (the view keep-mounted is a
/// SwiftUI concern proven manually).
@MainActor
final class SessionRetentionLRUTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    /// Creating a second session KEEPS the outgoing (original) session retained, so returning to it does not
    /// repaint from the ring — the new + previous sessions are both mounted.
    func testNewSessionRetainsOutgoing() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.tree.activeSessionID)
        store.newSession(name: "B", kind: .terminal)
        let b = try XCTUnwrap(store.tree.activeSessionID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.retainedSessionIDs, [b, a], "the outgoing session A stays mounted behind new B")
    }

    /// An A→B→A round trip keeps BOTH sessions retained throughout (the bug: A was unmounted on the switch to
    /// B and repainted lossily on return).
    func testRoundTripKeepsBothRetained() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.tree.activeSessionID)
        store.newSession(name: "B", kind: .terminal)
        let b = try XCTUnwrap(store.tree.activeSessionID)

        store.selectSession(a)
        XCTAssertEqual(store.retainedSessionIDs, [a, b], "returning to A keeps B mounted (front = active A)")
        XCTAssertTrue(store.retainedSessionIDs.contains(a) && store.retainedSessionIDs.contains(b))

        store.selectSession(b)
        XCTAssertEqual(store.retainedSessionIDs, [b, a])
    }

    /// Pure LRU: beyond the cap the least-recently-active session is evicted (A→B→C drops A at cap 2).
    func testPureLRUEvictsBeyondCap() {
        let a = SessionID(), b = SessionID(), c = SessionID()
        // A active, switch to B: [B, A]
        let afterB = WorkspaceStore.pushingSessionRetention(b, previous: a, into: [], cap: 2)
        XCTAssertEqual(afterB, [b, a])
        // switch to C: [C, B] — A evicted (LRU)
        let afterC = WorkspaceStore.pushingSessionRetention(c, previous: b, into: afterB, cap: 2)
        XCTAssertEqual(afterC, [c, b])
        XCTAssertFalse(afterC.contains(a), "the least-recently-active session A is evicted beyond the cap")
    }

    /// Closing a session drops it from the retention set and keeps the now-active session retained.
    func testCloseSessionPrunesRetention() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.tree.activeSessionID)
        store.newSession(name: "B", kind: .terminal)
        let b = try XCTUnwrap(store.tree.activeSessionID)
        XCTAssertEqual(store.retainedSessionIDs, [b, a])

        store.closeSession(b)
        XCTAssertFalse(store.retainedSessionIDs.contains(b), "a closed session leaves the retention set")
        let nowActive = try XCTUnwrap(store.tree.activeSessionID)
        XCTAssertTrue(store.retainedSessionIDs.contains(nowActive), "the now-active session stays retained")
    }
}
