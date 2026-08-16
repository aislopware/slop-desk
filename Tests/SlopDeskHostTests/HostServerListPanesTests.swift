import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// `list-panes` (the AF_UNIX ctl verb behind `slopdesk-ctl`) must describe EVERY live pane on the
/// host, including the ones with no client attached.
///
/// A detached pane is alive by definition — `DetachedSessionStore` exists so a shell survives its
/// client quitting (tmux semantics). But `listPanesForControl()` enumerated only `muxSessions +
/// controlSessions`, so the single "describe all panes" API in the product reported NOTHING for
/// exactly the pane a user or orchestrator returning to a machine is looking for.
///
/// Headless: unspawned `PTYProcess` (masterFD == -1, no reaper thread), server never `start()`ed —
/// the hang-safety rule. The detach path is driven through the production seam.
final class HostServerListPanesTests: XCTestCase {
    private func makeSession(sessionID: UUID) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: unattachedPTY(), // unspawned: no PTY, no read loop
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
        )
    }

    /// REVERT-TO-FAIL: dropping `detachedStore.allSessions()` from `listPanesForControl()` empties
    /// the listing the moment the link drops.
    ///
    /// Driven through `handleLinkDown` — the REAL park path — not `detachMuxSession` directly:
    /// only the former removes the session from `muxSessions`, and a test that skips it would keep
    /// the pane visible through the mux source and pass no matter what this method does.
    func testDetachedPaneIsListed() throws {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true)
        defer { Task { await server.stop() } }

        let id = UUID()
        let connectionID = UUID()
        let key = MuxSessionKey(connectionID: connectionID, channelID: 1)
        server.registerMuxSessionForTesting(makeSession(sessionID: id), key: key)

        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [id.uuidString],
            "an attached pane is listed (the pre-existing behaviour)",
        )

        server.handleLinkDownForTesting(connectionID: connectionID)

        // Precondition, asserted rather than assumed: the park actually happened. Without this the
        // test below would pass vacuously on any build where the store is nil or the park is a
        // no-op — which is exactly how the first draft of this test fooled itself.
        let store = try XCTUnwrap(server.detachedStoreForTesting, "detach must be enabled here")
        XCTAssertEqual(store.allSessions().map(\.sessionID), [id], "the session parked in the store")
        XCTAssertNil(server.muxSessionForTesting(key: key), "and left the live map")

        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [id.uuidString],
            "the pane survived the client quit and is STILL listed — it is the one a returning "
                + "orchestrator needs to find",
        )
    }

    /// The sources are disjoint by construction (`handleLinkDown` removes from `muxSessions`
    /// before `detachMuxSession` inserts; `claim` removes before the reattach re-registers).
    /// Pinning it means a future refactor that parks a session without unregistering it shows up
    /// as a duplicate row rather than as a silent double-count.
    func testDetachedPaneIsNotListedTwice() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true)
        defer { Task { await server.stop() } }

        let connectionID = UUID()
        let key = MuxSessionKey(connectionID: connectionID, channelID: 1)
        server.registerMuxSessionForTesting(makeSession(sessionID: UUID()), key: key)
        server.handleLinkDownForTesting(connectionID: connectionID)

        XCTAssertEqual(
            server.listPanesForControl().count, 1,
            "a detached pane appears exactly once — never in both muxSessions and the store",
        )
    }

    /// With detach disabled there is no store at all (`detachedStore == nil`); the listing must
    /// degrade to the mux/control sources rather than trap on the optional.
    func testListingWorksWithDetachDisabled() {
        let server = HostServer(port: 0, detachEnabled: false, resumeOnRecovery: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(makeSession(sessionID: id), key: key)

        XCTAssertEqual(server.listPanesForControl().map(\.paneId), [id.uuidString])
    }
}
