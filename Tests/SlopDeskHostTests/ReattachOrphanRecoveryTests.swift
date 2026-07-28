import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Reattach-vs-linkDown orphan cluster (CRITICAL).
///
/// The poison sequence: `performReattach` claims a detached session, then runs the LONG
/// credit-paced `replayTail`. If the new link dies in that window, `finishLink` finishes the
/// sub-channels FIRST and `handleLinkDown` re-parks the session in ``DetachedSessionStore``
/// (isDetached stays true) — but if `rebindRelay`'s only guard is `guard isDetached`, then
/// the still-running reattach rebinds onto the DEAD channels and flips
/// `isDetached = false` while the session sits in the store. The NEXT reconnect claims that
/// poisoned session, `rebindRelay` refuses (`isDetached == false`), and the failed-rebind path
/// only unregisters the map key — the session ends up in NO map and NO store: a live shell +
/// running agent that `stop()`, TTL, and every future reconnect can never reach again (PTY +
/// master fd + read-loop/reaper threads leak per flap; the replacement shell double-writes the
/// same sessionID journal). Under a flapping wifi link this would repeat every few seconds.
///
/// Three pinned layers (defense in depth):
/// 1. `rebindRelay` refuses (returns false) when its target sub-channels are already finished.
/// 2. The failed-rebind path re-parks the claimed session (or reaps an exited child) — never
///    strands it outside both the live map and the store.
/// 3. `detach()` is idempotent — a second detach on an already-detached session is a safe no-op.
///
/// All headless: unspawned PTYs, in-memory ``MuxSubChannel``s, no NWListener (hang-safety).
final class ReattachOrphanRecoveryTests: XCTestCase {
    // MARK: - Helpers

    /// Records framed sub-channel sends and decodes them back to ``WireMessage``s (same helper
    /// shape as `MuxChannelSessionDetachReattachOutputTests`).
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let decoder = FrameDecoder()
        private var messages: [WireMessage] = []

        func record(_ innerFrame: Data) {
            lock.lock()
            defer { lock.unlock() }
            decoder.append(innerFrame)
            while let message = try? decoder.nextMessage() {
                messages.append(message)
            }
        }

        var outputBytes: Data {
            lock.lock()
            defer { lock.unlock() }
            var joined = Data()
            for message in messages {
                if case let .output(_, bytes) = message { joined.append(bytes) }
            }
            return joined
        }
    }

    private func makeSession(sessionID: UUID = UUID(), shimDir: URL? = nil) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — no reaper thread, no masterFD (hang-safety)
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
            shimDir: shimDir,
        )
    }

    /// A detach-enabled server with NO listener started — only the detach/reattach state
    /// machine is exercised (explicit flags so ambient `SLOPDESK_*` env can't flip the gate).
    private func makeServer() -> HostServer {
        HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true)
    }

    /// A dead channel pair — what `open.data`/`open.control` look like once `finishLink` ran.
    private func makeFinishedChannels() async -> (data: MuxSubChannel, control: MuxSubChannel) {
        let data = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let control = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        await data.finish()
        await control.finish()
        return (data, control)
    }

    /// Polls `condition` (up to ~5 s) so background teardown/drain tasks get scheduled.
    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Layer 1 — rebindRelay must refuse finished sub-channels

    /// `finishLink` finishes every sub-channel BEFORE firing `linkDownHandler`, so channels that
    /// are already finished mean the new connection died mid-reattach. Rebinding onto them
    /// flipped `isDetached = false` on a session `handleLinkDown` had (or was about to have)
    /// parked in the store — the poison that made the next claim unrecoverable.
    func testRebindRelayRefusesFinishedChannels() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        let away = Data("while-you-were-away\n".utf8)
        session.enqueueChunkForTesting(bytes: away)

        let dead = await makeFinishedChannels()
        XCTAssertFalse(
            session.rebindRelay(data: dead.data, control: dead.control, onExit: nil),
            "rebindRelay must refuse sub-channels whose link already died — rebinding would mark "
                + "a store-parked session as attached (the un-claimable poison state)",
        )
        XCTAssertTrue(
            session.isDetached,
            "a refused rebind must leave the session detached, so the store hand-off stays claimable",
        )

        // The session must still reattach cleanly onto LIVE channels afterwards — nothing about
        // the refusal may corrupt the relay state or drop the detached-window backlog.
        let recorder = SendRecorder()
        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let liveControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(
            session.rebindRelay(data: liveData, control: liveControl, onExit: nil),
            "a later reattach onto live channels must succeed after a refused dead-channel rebind",
        )
        await waitUntil { recorder.outputBytes == away }
        XCTAssertEqual(recorder.outputBytes, away, "the detached-window output survives the refused rebind")
    }

    /// Both halves of the pair matter: a finished CONTROL channel alone (data still live)
    /// still means the link is dead — resize/ack/bye could never flow.
    func testRebindRelayRefusesWhenOnlyControlChannelFinished() async {
        let session = makeSession()
        session.detach(onDetachedExit: { _ in })

        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let deadControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        await deadControl.finish()
        XCTAssertFalse(
            session.rebindRelay(data: liveData, control: deadControl, onExit: nil),
            "a finished control sub-channel must refuse the rebind like a finished data one",
        )
        XCTAssertTrue(session.isDetached)
    }

    // MARK: - Layer 2 — the failed-rebind path must never strand the claimed session

    /// The full poison sequence, through the REAL host state machine: detach → claim+register
    /// (the spawnMuxChannel critical section) → link dies mid-replay (`finishLink` finishes the
    /// sub-channels, `handleLinkDown` re-parks the session) → the late `rebindRelay` refuses →
    /// the failed-rebind recovery leaves the session claimable — and the next reconnect wins it.
    func testLinkDownMidReattachNeverOrphansTheSession() async {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let id = UUID()
        let session = makeSession(sessionID: id)
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })

        // Flap 1: link drop parks the session.
        let key1 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.detachMuxSessionForTesting(key: key1, session: session)
        XCTAssertTrue(store.storedIDsForTesting.contains(id))

        // Flap-2 reconnect: the claim critical section takes it out of the store and registers
        // it under the new key — exactly the state performReattach starts its replayTail in.
        let conn2 = UUID()
        let key2 = MuxSessionKey(connectionID: conn2, channelID: 1)
        let claimed = store.claim(id).claimedSession
        XCTAssertIdentical(claimed, session, "the reconnect's claim must win the parked session")
        server.registerMuxSessionForTesting(session, key: key2)

        // Mid-replay the new link dies: finishLink finishes the channels FIRST, then the
        // link-down sweep re-parks the session (removing key2 from the live map).
        let dead = await makeFinishedChannels()
        server.handleLinkDownForTesting(connectionID: conn2)
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "handleLinkDown must re-park the claimed session when the new link dies mid-reattach",
        )
        XCTAssertNil(server.muxSessionForTesting(key: key2))

        // The still-unwinding performReattach now reaches rebindRelay — it must refuse the dead
        // channels and must NOT flip the parked session to attached (the un-claimable poison).
        XCTAssertFalse(
            session.rebindRelay(
                data: dead.data,
                control: dead.control,
                onExit: { _ in },
            ),
            "rebindRelay must refuse once the link died mid-replay (finished sub-channels)",
        )
        XCTAssertTrue(session.isDetached, "the parked session must stay detached after the refusal")

        // ...and its failed-rebind path must leave exactly ONE claimable store entry.
        server.recoverFailedRebindForTesting(session: session, key: key2)
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "after a failed rebind the session must still be claimable — never in no map and no store",
        )
        XCTAssertEqual(store.countForTesting, 1, "the recovery must not duplicate the store entry")

        // Flap-3 reconnect: the session reattaches for real.
        let key3 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let claimedAgain = store.claim(id).claimedSession
        XCTAssertIdentical(claimedAgain, session, "the next reconnect must be able to claim the session")
        server.registerMuxSessionForTesting(session, key: key3)
        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let liveControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(
            session.rebindRelay(data: liveData, control: liveControl, onExit: nil),
            "the recovered session must reattach onto the next live connection",
        )
    }

    /// The ordering variant where the link-down sweep has NOT re-parked the session (it found
    /// the key already unregistered, or fired before the claim): after the refused rebind the
    /// claimed session is in the live map only, and recovery must re-park it into the store —
    /// the tmux semantics (the running agent survives), not a kill.
    func testFailedRebindReparksClaimedSessionWhenLinkDownMissedIt() async {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let id = UUID()
        let session = makeSession(sessionID: id)

        let key1 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.detachMuxSessionForTesting(key: key1, session: session)
        let key2 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let claimed = store.claim(id).claimedSession
        XCTAssertIdentical(claimed, session)
        server.registerMuxSessionForTesting(session, key: key2)
        XCTAssertFalse(store.storedIDsForTesting.contains(id), "claimed: the store entry is gone")

        // Link died (channels finished) but no handleLinkDown re-park happened for key2.
        let dead = await makeFinishedChannels()
        XCTAssertFalse(session.rebindRelay(data: dead.data, control: dead.control, onExit: nil))

        server.recoverFailedRebindForTesting(session: session, key: key2)
        XCTAssertNil(server.muxSessionForTesting(key: key2), "the dead attachment key must be unregistered")
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "recovery must RE-PARK the claimed session (live child, tmux semantics) — the old "
                + "unregister-only path left it unreachable by every map, store, TTL, and stop()",
        )
        XCTAssertTrue(session.isDetached)

        // Claimable again, and the next rebind works.
        let claimedAgain = store.claim(id).claimedSession
        XCTAssertIdentical(claimedAgain, session)
        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let liveControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: liveData, control: liveControl, onExit: nil))
    }

    /// Legacy-poison shape: a claimed session that is NOT detached (`isDetached == false` —
    /// the double-attach loser / a session poisoned before the finished-channel guard). The
    /// recovery must still detach + re-park it rather than dropping it.
    func testFailedRebindRecoversNonDetachedOrphanIntoStore() {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let id = UUID()
        let session = makeSession(sessionID: id) // never detached: isDetached == false
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: key)

        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let liveControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertFalse(
            session.rebindRelay(data: liveData, control: liveControl, onExit: nil),
            "precondition: rebindRelay refuses a non-detached session (existing contract)",
        )

        server.recoverFailedRebindForTesting(session: session, key: key)
        XCTAssertNil(server.muxSessionForTesting(key: key))
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "a claimed-but-unrebindable live session must be parked, not stranded",
        )
        XCTAssertTrue(session.isDetached, "recovery must put the session into the detached state")
    }

    /// A session attached under ANOTHER live key is someone else's pane — recovery must leave
    /// it alone (no re-park, no detach of the winner's relay).
    func testFailedRebindLeavesSessionAttachedElsewhereAlone() {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let id = UUID()
        let session = makeSession(sessionID: id)
        let loserKey = MuxSessionKey(connectionID: UUID(), channelID: 1)
        let winnerKey = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: winnerKey)

        server.recoverFailedRebindForTesting(session: session, key: loserKey)
        XCTAssertIdentical(
            server.muxSessionForTesting(key: winnerKey), session,
            "the winner's attachment must be untouched",
        )
        XCTAssertFalse(session.isDetached, "the winner's live relay must not be detached")
        XCTAssertFalse(store.storedIDsForTesting.contains(id), "no store entry for an attached session")
    }

    /// A claimed session whose child EXITED mid-reattach has nothing to park: recovery must
    /// shut it down (fd + shim-dir teardown), not insert a corpse into the store.
    func testFailedRebindShutsDownExitedChildInsteadOfParking() async {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let shimDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-recovery-shim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shimDir) }

        let id = UUID()
        let session = makeSession(sessionID: id, shimDir: shimDir)
        let key1 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.detachMuxSessionForTesting(key: key1, session: session)
        let key2 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        XCTAssertIdentical(store.claim(id).claimedSession, session)
        server.registerMuxSessionForTesting(session, key: key2)

        // The child dies while the reattach is replaying, then the link dies too.
        session.pty.completeExitForTesting(code: 0)
        let dead = await makeFinishedChannels()
        XCTAssertFalse(session.rebindRelay(data: dead.data, control: dead.control, onExit: nil))

        server.recoverFailedRebindForTesting(session: session, key: key2)
        XCTAssertFalse(
            store.storedIDsForTesting.contains(id),
            "an exited child must be shut down, never parked as a claimable corpse",
        )
        XCTAssertNil(server.muxSessionForTesting(key: key2))
        // shutdown() deletes the shim dir once the child is reaped — the observable proof the
        // teardown path actually ran (it is dispatched to the teardown queue).
        await waitUntil { !FileManager.default.fileExists(atPath: shimDir.path) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shimDir.path),
            "recovery must run the real teardown (shutdown deletes the per-session shim dir)",
        )
    }

    /// `stop()`'s `drainAll()` must reap a re-parked session — the recovery keeps the session
    /// inside the store's teardown domain, so the daemon can still shut everything down.
    func testDrainAllReapsReparkedSession() async {
        let server = makeServer()
        guard let store = server.detachedStoreForTesting else {
            XCTFail("detach-enabled server must have a store")
            return
        }
        let shimDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-recovery-drain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shimDir) }

        let id = UUID()
        let session = makeSession(sessionID: id, shimDir: shimDir)
        let key1 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.detachMuxSessionForTesting(key: key1, session: session)
        let key2 = MuxSessionKey(connectionID: UUID(), channelID: 1)
        XCTAssertIdentical(store.claim(id).claimedSession, session)
        server.registerMuxSessionForTesting(session, key: key2)

        let dead = await makeFinishedChannels()
        XCTAssertFalse(session.rebindRelay(data: dead.data, control: dead.control, onExit: nil))
        server.recoverFailedRebindForTesting(session: session, key: key2)
        XCTAssertTrue(store.storedIDsForTesting.contains(id), "precondition: re-parked")

        store.drainAll()
        XCTAssertEqual(store.countForTesting, 0)
        // The drain's shutdownDetached tears the PTY down (SIGTERM→SIGKILL escalation on a live
        // child; here the unspawned PTY makes it a pure fd/shim teardown) — the shim-dir delete
        // is the observable completion of that path.
        await waitUntil { !FileManager.default.fileExists(atPath: shimDir.path) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shimDir.path),
            "drainAll must reap a re-parked session (no PTY left behind after stop())",
        )
    }

    // MARK: - Layer 3 — detach() idempotence

    /// A second `detach()` on an already-detached session (the failed-rebind re-park racing
    /// `handleLinkDown`'s own detach) must be a safe no-op beyond refreshing the exit handler:
    /// the detached-window backlog and the relay state survive, and the session still
    /// reattaches cleanly.
    func testSecondDetachIsSafeAndKeepsSessionReattachable() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        let away = Data("agent-output-while-away\n".utf8)
        session.enqueueChunkForTesting(bytes: away)

        // Second detach — must not double-tear-down, drop the backlog, or corrupt the relay.
        session.detach(onDetachedExit: { _ in })
        XCTAssertTrue(session.isDetached)

        let recorder = SendRecorder()
        let liveData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let liveControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(
            session.rebindRelay(data: liveData, control: liveControl, onExit: nil),
            "a double-detached session must still reattach",
        )
        await waitUntil { recorder.outputBytes == away }
        XCTAssertEqual(recorder.outputBytes, away, "the detached-window backlog survives a double detach")
    }

    /// The second detach must rewire the exit handler to the LATEST park's closure (the C2
    /// contract): a shell that exits while parked must fire the newest detached-exit handler.
    func testSecondDetachRewiresExitHandler() {
        final class Box: @unchecked Sendable {
            var first = false
            var second = false
        }
        let box = Box()
        let session = makeSession()
        session.detach(onDetachedExit: { _ in box.first = true })
        session.detach(onDetachedExit: { _ in box.second = true })
        session.onExit?(1)
        XCTAssertFalse(box.first, "the stale park's exit handler must not fire")
        XCTAssertTrue(box.second, "the latest park's exit handler must fire")
    }
}
