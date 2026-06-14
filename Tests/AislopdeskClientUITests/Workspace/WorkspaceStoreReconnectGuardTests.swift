import XCTest
@testable import AislopdeskClientUI

/// R16 WS-1 regression: `reconnect(id)` resolves the handle synchronously but DIALS in a detached
/// Task. If the pane is closed (reconcile-removed + torn down) in the interim, reviving the captured
/// connection would clear `deliberatelyClosed` and strand a live, supervised, reconnecting connection
/// for a pane that no longer exists. The fix re-checks `paneStillRegistered(id, as: handle)` on the
/// MainActor before dialing; these pin that re-check (the `reconnect` dial itself only acts on a
/// `LivePaneSession`, so the seam is what is asserted here with the `FakePaneSession` test seam).
@MainActor
final class WorkspaceStoreReconnectGuardTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
    }

    private func leafIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.workspace.canvas.allIDs()
    }

    /// The re-check is TRUE while the pane is live, and FALSE once it has been closed — so the detached
    /// reconnect dial is skipped for a closed pane (no zombie revival).
    func testPaneStillRegisteredFlipsFalseAfterClose() async {
        let store = makeStore()
        let original = leafIDs(store)[0]
        store.addPane(kind: .terminal)
        let victim = leafIDs(store).first { $0 != original } ?? leafIDs(store)[1]

        guard let handle = store.handle(for: victim) else {
            XCTFail("victim pane should be registered after split")
            return
        }
        XCTAssertTrue(store.paneStillRegistered(victim, as: handle), "a live pane is still registered")

        store.closePane(victim)
        await store.quiesce()

        XCTAssertNil(store.handle(for: victim), "the closed pane is gone from the registry")
        XCTAssertFalse(
            store.paneStillRegistered(victim, as: handle),
            "after closePane the stale handle no longer matches — reconnect's detached dial must be skipped",
        )
    }

    /// Identity, not key presence: a DIFFERENT handle for the SAME id (e.g. a re-materialized session)
    /// must fail the check, so a reconnect captured against the OLD handle never dials.
    func testPaneStillRegisteredIsByIdentityNotKeyPresence() throws {
        let store = makeStore()
        let id0 = leafIDs(store)[0]
        store.addPane(kind: .terminal)
        let id1 = try XCTUnwrap(leafIDs(store).first { $0 != id0 })

        guard let h0 = store.handle(for: id0), let h1 = store.handle(for: id1) else {
            XCTFail("both panes registered after split")
            return
        }
        XCTAssertTrue(store.paneStillRegistered(id0, as: h0), "matching handle for its own id")
        XCTAssertFalse(
            store.paneStillRegistered(id0, as: h1),
            "a different handle for the SAME id must not match (reference identity, not key presence)",
        )
    }
}
