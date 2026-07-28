import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Hook-sink lifetime: the `AgentHookListener` routing key must be STABLE for the life of the
/// session.
///
/// The pane id is exported ONCE into the child env as `SLOPDESK_PANE_ID` at fresh spawn and is
/// immutable for the shell's life — the agent's hook POSTs are forever tagged with the ORIGINAL
/// `connectionID:channelID`. Registering a NEW per-connection key on every reattach therefore
/// (a) leaked one dead sink per detach/reattach cycle (String key + closure per wifi flap, for
/// weeks) and (b) was functionally dead anyway — only the original key ever routes.
///
/// Deliberate design (do not regress): detach does NOT unregister — hook records must keep
/// folding into the detector while the session is parked, so a status change during the
/// detached window is re-asserted on reattach rather than lost.
///
/// All headless: unspawned PTYs, no socket bind, no NWListener (hang-safety) — the listener's
/// router is driven via `routeRecordForTesting`, the host paths via the `…ForTesting` seams
/// that call the REAL private state machine.
final class HostServerHookSinkStableKeyTests: XCTestCase {
    private func makeSession(sessionID: UUID = UUID()) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — no reaper thread, no masterFD (hang-safety)
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
        )
    }

    /// A detach-enabled server carrying an (unbound) hook listener — only the sink bookkeeping
    /// is exercised, never the socket (explicit flags so ambient `SLOPDESK_*` env can't flip
    /// the gates).
    private func makeServer(listener: AgentHookListener) -> HostServer {
        HostServer(
            port: 0,
            agentHookListener: listener,
            detachEnabled: true,
            resumeOnRecovery: true,
        )
    }

    /// A framed hook record (the `pane=` header + real Claude hook JSON) that flips the
    /// detector to `.working` when it routes.
    private func workingRecord(paneID: String) -> Data {
        Data("pane=\(paneID)\n{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\"}".utf8)
    }

    /// Runs one full detach → claim → reattach cycle through the real host seams, returning the
    /// new attachment key. Mirrors `spawnMuxChannel`'s PATH A step sequence.
    private func cycleDetachReattach(
        server: HostServer,
        session: MuxChannelSession,
        from oldKey: MuxSessionKey,
    ) -> MuxSessionKey {
        server.detachMuxSessionForTesting(key: oldKey, session: session)
        let newKey = MuxSessionKey(connectionID: UUID(), channelID: 1)
        XCTAssertIdentical(server.detachedStoreForTesting?.claim(session.sessionID).claimedSession, session)
        server.registerMuxSessionForTesting(session, key: newKey)
        server.reattachHookSinkForTesting(
            session: session, connectionID: newKey.connectionID, channelID: newKey.channelID,
        )
        return newKey
    }

    // MARK: - (1) reattach must not grow the sink map

    /// THE leak pin: N detach/reattach cycles must leave exactly ONE sink — keyed by the
    /// ORIGINAL pane id (the one baked into the shell env).
    func testReattachCyclesDoNotGrowSinks() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        var key = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let originalPaneID = HostServer.paneID(connectionID: key.connectionID, channelID: key.channelID)

        server.registerHookSinkForTesting(
            session: session, connectionID: key.connectionID, channelID: key.channelID,
        )
        XCTAssertEqual(listener.sinkCountForTesting, 1, "fresh spawn registers exactly one sink")

        for flap in 1...3 {
            key = cycleDetachReattach(server: server, session: session, from: key)
            XCTAssertEqual(
                listener.sinkCountForTesting, 1,
                "cycle \(flap): reattach must not leak a sink — the env-baked pane id never changes",
            )
        }
        XCTAssertEqual(
            listener.sinkPaneIDsForTesting, [originalPaneID],
            "the surviving sink must be the ORIGINAL key — a new-connection key can never route "
                + "(the agent's POSTs carry the env-baked id)",
        )
    }

    // MARK: - (2) records still route via the ORIGINAL pane id after a cycle

    /// The functional half: after a detach+reattach cycle, a hook POST tagged with the
    /// ORIGINAL pane id (the only id the shell env ever knew) must still reach the session's
    /// detector.
    func testHookRecordRoutesViaOriginalPaneIDAfterReattachCycle() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        let key0 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let originalPaneID = HostServer.paneID(connectionID: key0.connectionID, channelID: key0.channelID)

        server.registerHookSinkForTesting(
            session: session, connectionID: key0.connectionID, channelID: key0.channelID,
        )
        _ = cycleDetachReattach(server: server, session: session, from: key0)

        listener.routeRecordForTesting(workingRecord(paneID: originalPaneID))
        XCTAssertEqual(
            session.agentStatusForControl, .working,
            "a hook record tagged with the env-baked ORIGINAL pane id must fold into the "
                + "reattached session's detector",
        )
    }

    // MARK: - detach keeps the sink (the detached-window status hole stays closed)

    /// Deliberate: while parked, hook records keep folding into the detector (so a status
    /// change during the detached window is re-asserted on reattach). Detach must NOT
    /// unregister.
    func testDetachKeepsSinkRegisteredAndRouting() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let paneID = HostServer.paneID(connectionID: key.connectionID, channelID: key.channelID)

        server.registerHookSinkForTesting(
            session: session, connectionID: key.connectionID, channelID: key.channelID,
        )
        server.detachMuxSessionForTesting(key: key, session: session)

        XCTAssertEqual(listener.sinkCountForTesting, 1, "detach must not drop the sink")
        listener.routeRecordForTesting(workingRecord(paneID: paneID))
        XCTAssertEqual(
            session.agentStatusForControl, .working,
            "hook records must keep folding into the detector while the session is parked",
        )
    }

    // MARK: - (3) deliberate close unregisters the ORIGINAL key

    /// A peer `channelClose` after a reattach cycle arrives under the NEW composite key —
    /// the unregister must still remove the ORIGINAL sink (zero sinks left, nothing leaked).
    func testDeliberateCloseAfterReattachCycleUnregistersOriginalKey() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        let key0 = MuxSessionKey(connectionID: UUID(), channelID: 1)

        server.registerHookSinkForTesting(
            session: session, connectionID: key0.connectionID, channelID: key0.channelID,
        )
        let key1 = cycleDetachReattach(server: server, session: session, from: key0)

        server.removeMuxSessionForTesting(key1)
        XCTAssertEqual(
            listener.sinkCountForTesting, 0,
            "deliberate close must unregister the ORIGINAL sink — unregistering the current "
                + "key leaves the env-baked entry (and its session closure) behind forever",
        )
        XCTAssertEqual(server.hookPaneIDCountForTesting, 0, "the pane-id bookkeeping must not leak either")
    }

    // MARK: - (4) detached exit cleans up too

    /// A shell that dies while PARKED never reaches `removeMuxSession` — the detached-exit
    /// path (`onDetachedExit`) must drop the sink itself, or every parked-death leaks one.
    func testDetachedExitUnregistersSink() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)

        server.registerHookSinkForTesting(
            session: session, connectionID: key.connectionID, channelID: key.channelID,
        )
        server.detachMuxSessionForTesting(key: key, session: session)

        session.onExit?(0) // the shell exits while parked → the wired onDetachedExit fires
        XCTAssertEqual(server.detachedStoreForTesting?.countForTesting, 0, "store entry reaped")
        XCTAssertEqual(
            listener.sinkCountForTesting, 0,
            "a session that dies while detached must take its hook sink with it",
        )
        XCTAssertEqual(server.hookPaneIDCountForTesting, 0, "the pane-id bookkeeping must not leak either")
    }

    /// TTL eviction kills a parked session without ever touching `removeMuxSession` — the
    /// eviction must drop the sink too (same non-deliberate end-of-life class).
    func testTTLEvictionUnregistersSink() {
        let listener = AgentHookListener()
        let server = makeServer(listener: listener)
        let session = makeSession()
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)

        server.registerHookSinkForTesting(
            session: session, connectionID: key.connectionID, channelID: key.channelID,
        )
        server.detachMuxSessionForTesting(key: key, session: session)

        // Drive the REAL eviction path directly (the TTL task's only body) — no timer wait.
        server.detachedStoreForTesting?.evict(session.sessionID)
        XCTAssertEqual(server.detachedStoreForTesting?.countForTesting, 0, "entry evicted")
        XCTAssertEqual(
            listener.sinkCountForTesting, 0,
            "a TTL-evicted session must take its hook sink with it",
        )
        XCTAssertEqual(server.hookPaneIDCountForTesting, 0, "the pane-id bookkeeping must not leak either")
    }
}
