import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Under a fan-out, N live-map KEYS alias ONE `MuxChannelSession`. Every reader and every teardown
/// that means "the pane" rather than "one attachment" has to collapse that.
///
/// The failures this pins are all silent: a pane shut down N times, teardown-fanned N times against
/// a strictly-balanced prevent-sleep counter, listed twice to an orchestrator, or half-reaped so a
/// survivor key keeps a dead session alive in every map.
///
/// Headless: unspawned `PTYProcess` (masterFD == −1, no reaper thread), server never `start()`ed —
/// the hang-safety rule.
final class HostServerFanOutRoutingTests: XCTestCase {
    private func makeSession(sessionID: UUID) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned: no PTY, no read loop
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
        )
    }

    /// One session under two keys, as `performJoin` leaves it.
    private func makeFannedOutPane(
        on server: HostServer,
        sessionID: UUID,
    ) -> (session: MuxChannelSession, first: MuxSessionKey, second: MuxSessionKey) {
        let session = makeSession(sessionID: sessionID)
        let first = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let second = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: first)
        server.registerJoinedKeyForTesting(session, key: second, subscriber: 1)
        return (session, first, second)
    }

    // MARK: - The readers say "one pane", not "one per attachment"

    /// `listPanesForControl` enumerates `muxSessions.values`, which under a fan-out repeats the
    /// same session once per attached client. An orchestrator would see one shell twice, with two
    /// identical pane ids.
    func testAFannedOutPaneIsListedOnce() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        _ = makeFannedOutPane(on: server, sessionID: id)
        XCTAssertEqual(
            server.muxSessionKeyCountForTesting, 2,
            "precondition: two channel keys name the pane",
        )
        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [id.uuidString],
            "one PANE, however many clients hold it",
        )
    }

    // MARK: - A reap takes every key with it

    /// `killPaneForControl` removed only the FIRST matching key and returned. The survivor keeps
    /// the killed pane reported by `listPanesForControl`, re-shut by `stop()`, and read as
    /// still-attached by `recoverFailedRebind`'s live-map scan.
    func testKillPaneForControlRemovesEveryKeyNamingThePane() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        _ = makeFannedOutPane(on: server, sessionID: id)

        XCTAssertTrue(server.killPaneForControl(paneId: id.uuidString))
        XCTAssertEqual(
            server.muxSessionKeyCountForTesting, 0,
            "every alias goes with the kill — a survivor keeps a dead session in every map",
        )
        XCTAssertTrue(
            server.listPanesForControl().isEmpty,
            "and the killed pane stops being reported",
        )
    }

    /// The same for the deliberate-close reap: `removeMuxSession` must not leave N−1 stale entries
    /// pointing at a session it just shut down.
    func testRemovingASessionDropsEveryAliasingKey() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let pane = makeFannedOutPane(on: server, sessionID: UUID())
        server.removeMuxSessionForTesting(pane.first)
        XCTAssertNil(server.muxSessionForTesting(key: pane.first))
        XCTAssertNil(
            server.muxSessionForTesting(key: pane.second),
            "the OTHER client's key named the same dead session and must go too",
        )
        XCTAssertEqual(server.muxSessionKeyCountForTesting, 0)
    }

    // MARK: - Close is a LEAVE while somebody is still watching

    /// A peer `channelClose` under a fan-out must not reap the other client's running agent. It
    /// drops only the closer's registration; the session — and its PTY — stays live.
    func testAPeerCloseWhileAnotherClientWatchesIsALeaveNotAReap() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let pane = makeFannedOutPane(on: server, sessionID: id)

        server.leavePaneChannelForTesting(pane.second)
        XCTAssertNil(server.muxSessionForTesting(key: pane.second), "the leaver's key is gone")
        XCTAssertTrue(
            server.muxSessionForTesting(key: pane.first) === pane.session,
            "the pane itself survives — the other client is still watching it",
        )
        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [id.uuidString],
            "and it is still a live pane",
        )

        // The LAST one leaving DOES reap, exactly as a close always has.
        server.leavePaneChannelForTesting(pane.first)
        XCTAssertEqual(server.muxSessionKeyCountForTesting, 0)
        XCTAssertTrue(server.listPanesForControl().isEmpty)
    }

    /// A whole-link drop retires only THAT connection's member. The surviving client keeps the
    /// pane, and — critically — the session must NOT be parked in the detached store, because
    /// parking engages the 64 MiB offline gate that pauses the PTY drain for everyone.
    func testALinkDropWithAnotherClientAttachedDoesNotParkTheSession() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let pane = makeFannedOutPane(on: server, sessionID: id)

        server.handleLinkDownForTesting(connectionID: pane.second.connectionID)

        XCTAssertNil(server.muxSessionForTesting(key: pane.second), "the dropped link's key is gone")
        XCTAssertTrue(
            server.muxSessionForTesting(key: pane.first) === pane.session,
            "the pane is still attached to the client that did not drop",
        )
        XCTAssertFalse(
            server.detachedStoreForTesting?.contains(id) ?? true,
            "a pane somebody is still watching must NOT be parked — parking pauses its PTY drain",
        )
        XCTAssertTrue(
            pane.session.isClientOnlineForTesting,
            "and the offline gate must stay clear while a client is right there",
        )
    }

    /// The LAST link dropping parks the session, exactly as it always has.
    func testTheLastLinkDroppingStillParksTheSession() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let pane = makeFannedOutPane(on: server, sessionID: id)
        server.handleLinkDownForTesting(connectionID: pane.second.connectionID)
        server.handleLinkDownForTesting(connectionID: pane.first.connectionID)

        XCTAssertEqual(server.muxSessionKeyCountForTesting, 0)
        XCTAssertTrue(
            server.detachedStoreForTesting?.contains(id) ?? false,
            "with nobody left watching, the shell parks for a returning client (tmux semantics)",
        )
    }

    // MARK: - The document drives the unconditional reap

    /// `closePane` / `closeTab` are topology deletes applied HOST-side, so a pane the topology no
    /// longer names is reaped refcount-blind. Without this the fan-out's refcounted close would
    /// leave a running shell with no UI anywhere and no document entry.
    func testAPaneRemovedFromTheTopologyIsReapedRegardlessOfItsSubscriberCount() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let closed = UUID()
        let kept = UUID()
        _ = makeFannedOutPane(on: server, sessionID: closed)
        let keptKey = MuxSessionKey(connectionID: UUID(), channelID: 2)
        server.registerMuxSessionForTesting(makeSession(sessionID: kept), key: keptKey)

        server.reapPanesRemovedFromTopologyForTesting([closed])

        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [kept.uuidString],
            "the pane the topology dropped is gone even though two clients held it",
        )
        XCTAssertEqual(server.muxSessionKeyCountForTesting, 1, "both of its keys went with it")
        XCTAssertFalse(
            server.detachedStoreForTesting?.contains(closed) ?? false,
            "a topology delete REAPS — it must never park a shell nothing will ever show",
        )
    }

    // MARK: - A join that has not landed yet still names its own member

    /// A joining key is registered in `muxSessions` synchronously, but the member it will become
    /// only exists once `joinSubscriber` has composed an O(retained history) screen and shipped it
    /// through the joiner's credit window. A link drop inside that window must retire the JOINER.
    ///
    /// Recording the id only after the join returned left the key resolving to
    /// `primarySubscriberID` for the whole transfer, so the joiner's link dying there retired the
    /// INCUMBENT: its input/control/sender tasks cancelled, its pane silent, and — since it was the
    /// only member — its still-connected session parked in the detached store.
    func testALinkDropDuringAJoinRetiresTheJoinerNotTheIncumbent() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let session = makeSession(sessionID: id)
        let incumbent = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: incumbent)

        // The state `spawnMuxChannel`'s critical section leaves behind — the key is live, the member
        // is not.
        let joining = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let reserved = server.registerJoiningKeyForTesting(session, key: joining)
        XCTAssertNotEqual(
            reserved, MuxChannelSession.primarySubscriberID,
            "a reservation must never collide with the channel the pane was opened for",
        )

        server.handleLinkDownForTesting(connectionID: joining.connectionID)

        XCTAssertNil(server.muxSessionForTesting(key: joining), "the aborted join's key is gone")
        XCTAssertTrue(
            server.muxSessionForTesting(key: incumbent) === session,
            "the incumbent still holds its pane",
        )
        XCTAssertEqual(
            session.subscriberCountForTesting, 1,
            "and is still a MEMBER — a join that never landed may not retire somebody else",
        )
        XCTAssertFalse(
            session.isDetached,
            "so the session must not be parked while its client is right there",
        )
        XCTAssertFalse(server.detachedStoreForTesting?.contains(id) ?? true)
    }

    /// The same window reached by a clean peer `channelClose` — a client cancelling a slow join.
    func testAPeerCloseDuringAJoinLeavesTheIncumbentsShellRunning() {
        let server = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true, workspaceDocEnabled: false)
        defer { Task { await server.stop() } }

        let id = UUID()
        let session = makeSession(sessionID: id)
        let incumbent = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: incumbent)
        let joining = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerJoiningKeyForTesting(session, key: joining)

        server.leavePaneChannelForTesting(joining)

        XCTAssertNil(server.muxSessionForTesting(key: joining))
        XCTAssertEqual(
            server.listPanesForControl().map(\.paneId), [id.uuidString],
            "an aborted join must not hard-kill the incumbent's running shell",
        )
        XCTAssertEqual(session.subscriberCountForTesting, 1)
    }

    // MARK: - The flag

    /// The default is OFF, and it is read with the `== "1"` idiom (`!= "0"` would make it
    /// default-ON, which is the opposite of what the last and riskiest phase may ship as).
    ///
    /// The unset-env assertion is SKIPPED when the suite itself is run with the flag on — that run
    /// exists to prove the fan-out path is green, and the flag it sets is the very input under test.
    func testPaneFanoutIsOffByDefault() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SLOPDESK_PANE_FANOUT"] == nil,
            "the ambient environment names the flag this assertion is about",
        )
        XCTAssertFalse(
            HostServer(port: 0, workspaceDocEnabled: false).paneFanoutEnabled,
            "SLOPDESK_PANE_FANOUT is default-OFF — the shipping path keeps one client per pane",
        )
    }

    /// An explicit override wins over the environment in BOTH directions — the seam every test in
    /// this file (and every future one) needs in order to pin behaviour independently of how the
    /// suite happens to be invoked.
    func testAnExplicitFanoutOverrideWinsOverTheEnvironment() {
        XCTAssertTrue(HostServer(port: 0, workspaceDocEnabled: false, paneFanoutEnabled: true).paneFanoutEnabled)
        XCTAssertFalse(HostServer(port: 0, workspaceDocEnabled: false, paneFanoutEnabled: false).paneFanoutEnabled)
    }
}
