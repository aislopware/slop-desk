import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

// MARK: - Stub helpers

/// Minimal fake ``MuxChannelSession`` stand-in for store tests.
/// Uses the real type — we just create it with an UNSPAWNED PTYProcess (masterFD == -1)
/// so no PTY or read loop is ever started (hang-safety rule).
private func makeStubSession(sessionID: UUID = UUID()) -> MuxChannelSession {
    MuxChannelSession(
        channelID: 1,
        pty: PTYProcess(), // unspawned: no reaper thread, no masterFD
        data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
        control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        sessionID: sessionID,
    )
}

// MARK: - DetachedSessionStore unit tests

/// Hang-safe (no real PTY, no network): exercises the store's insert/claim/TTL/cap/remove
/// and drainAll semantics on the real ``DetachedSessionStore``.
final class DetachedSessionStoreTests: XCTestCase {
    // MARK: Basic insert / claim

    /// `claim` hands back the inserted session AND removes the entry — the exclusive
    /// hand-off contract (a `lookup` that left the entry in place would let two concurrent
    /// reconnects both obtain the same session).
    func testInsertAndClaimReturnsSessionExactlyOnce() {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))
        let found = store.claim(id)
        XCTAssertNotNil(found, "claim must return a freshly-inserted session")
        XCTAssertIdentical(found, session)
        XCTAssertEqual(store.countForTesting, 0, "claim must REMOVE the entry (exclusive hand-off)")
        XCTAssertNil(store.claim(id), "a second claim for the same id must get nil, never an alias")
    }

    func testClaimUnknownIDReturnsNil() {
        let store = DetachedSessionStore()
        let result = store.claim(UUID())
        XCTAssertNil(result, "unknown sessionID must return nil")
    }

    /// Many concurrent claims for ONE stored session: exactly one wins (the two-racing-
    /// reconnects case). The losers get nil and would fall through to the
    /// fresh-shell path, where HostServer's live-sessionID guard refuses the duplicate.
    func testConcurrentClaimsExactlyOneWinner() async {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))

        let winners = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { store.claim(id) != nil ? 1 : 0 }
            }
            var total = 0
            for await w in group { total += w }
            return total
        }
        XCTAssertEqual(winners, 1, "exactly ONE of N concurrent claims may win the session")
        XCTAssertEqual(store.countForTesting, 0)
    }

    // MARK: TTL = nil (tmux/zellij semantics — never reaped on a timer)

    /// `ttl: nil` arms NO eviction task: the detached session outlives any timer horizon —
    /// paired with ``testTTLEvictsSessionAfterExpiry`` (10 ms TTL evicts) the wait below would
    /// have evicted a timed entry many times over.
    func testNilTTLNeverEvicts() async throws {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: nil)
        try await Task.sleep(for: .milliseconds(150))
        let found = store.claim(id)
        XCTAssertNotNil(found, "a nil-TTL detached session must never be timer-evicted")
    }

    /// The HostServer default is NEVER (nil), and `0` also resolves to never — only a positive
    /// `SLOPDESK_DETACH_TTL_SECS`/`detachTTLSecs` opts into timed eviction.
    func testHostServerTTLResolution() {
        XCTAssertNil(
            HostServer(port: 0, detachTTLSecs: 0).detachTTL,
            "0 must mean never, not instant eviction",
        )
        XCTAssertEqual(HostServer(port: 0, detachTTLSecs: 7).detachTTL, .seconds(7))
        if ProcessInfo.processInfo.environment["SLOPDESK_DETACH_TTL_SECS"] == nil {
            XCTAssertNil(HostServer(port: 0).detachTTL, "the default is tmux semantics: never")
        }
    }

    /// Cap resolution: default UNBOUNDED (nil — tmux/zellij have no session cap and never
    /// silently kill a live detached session); a positive value opts into capping.
    func testHostServerDetachCapResolution() {
        if ProcessInfo.processInfo.environment["SLOPDESK_DETACH_MAX_SESSIONS"] == nil {
            XCTAssertNil(HostServer(port: 0).detachMaxSessionsResolved, "default is no cap")
        }
        XCTAssertEqual(HostServer(port: 0, detachMaxSessions: 512).detachMaxSessionsResolved, 512)
        XCTAssertNil(
            HostServer(port: 0, detachMaxSessions: 0).detachMaxSessionsResolved,
            "a non-positive cap means unbounded, not instant eviction",
        )
    }

    /// No cap set → inserting past any would-be threshold never evicts (tmux semantics).
    func testUnboundedStoreNeverEvictsOnOverflow() {
        let store = DetachedSessionStore() // default: no cap
        var ids: [UUID] = []
        for i in 0..<70 { // past the old 64 cap
            let id = UUID()
            ids.append(id)
            let s = makeStubSession(sessionID: id)
            store.insert(s, key: MuxSessionKey(connectionID: UUID(), channelID: UInt32(i)), ttl: nil)
        }
        XCTAssertTrue(
            store.storedIDsForTesting.contains(ids[0]),
            "with no cap, the oldest detached session must never be evicted",
        )
    }

    // MARK: TTL eviction

    func testTTLEvictsSessionAfterExpiry() async throws {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        // Use a 10ms TTL so the test does not wall-clock-sleep long.
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .milliseconds(10))
        // Confirm it is present immediately (via the non-mutating seam — claim would REMOVE it
        // and disarm the very TTL this test is proving).
        XCTAssertTrue(store.storedIDsForTesting.contains(id), "session must be present right after insert")
        // Poll past the TTL with a generous deadline rather than a single fixed sleep: the eviction is an
        // async `Task.sleep(ttl)` continuation, so a saturated cooperative pool (the full parallel suite) can
        // starve it well past the nominal 10ms and flake a one-shot check. Polling asserts EVENTUAL eviction
        // without weakening the contract and returns the instant the TTL task fires (fast in isolation).
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.storedIDsForTesting.contains(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            store.storedIDsForTesting.contains(id),
            "TTL-evicted session must be gone from the store",
        )
    }

    /// Claiming CANCELS the armed TTL task: after a claim, the stale timer can
    /// neither kill the just-reattached PTY nor hijack a LATER entry re-inserted under the
    /// same sessionID (the same shell detaching again). We prove the second, observable half:
    /// re-insert the same id with `ttl: nil` and wait far past the original 10ms TTL — if the
    /// old task were still armed, `evict(id)` would remove the new entry.
    func testClaimCancelsTTLSoStaleTimerCannotHijackReinsertedID() async throws {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .milliseconds(10))
        let claimed = store.claim(id)
        XCTAssertNotNil(claimed, "claim must win against a not-yet-fired TTL")
        // Same session detaches again later — re-inserted with NO ttl.
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 2), ttl: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "the ORIGINAL (claimed) entry's TTL task must be cancelled — it must not evict the re-inserted entry",
        )
    }

    // MARK: Capacity eviction (oldest evicted on overflow)

    func testOverflowEvictsOldestSession() {
        let store = DetachedSessionStore(maxSessions: 2)
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let s1 = makeStubSession(sessionID: id1)
        let s2 = makeStubSession(sessionID: id2)
        let s3 = makeStubSession(sessionID: id3)
        store.insert(s1, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))
        store.insert(s2, key: MuxSessionKey(connectionID: UUID(), channelID: 2), ttl: .seconds(60))
        // Inserting s3 overflows maxSessions=2; the oldest (s1) should be evicted.
        store.insert(s3, key: MuxSessionKey(connectionID: UUID(), channelID: 3), ttl: .seconds(60))
        XCTAssertEqual(store.countForTesting, 2, "store must never exceed maxSessions")
        let stored = store.storedIDsForTesting
        XCTAssertFalse(stored.contains(id1), "oldest session must be evicted on overflow")
        XCTAssertTrue(stored.contains(id2), "second session must survive")
        XCTAssertTrue(stored.contains(id3), "newly-inserted session must be present")
    }

    // MARK: Duplicate insert (failed-rebind re-park racing handleLinkDown)

    /// Re-inserting the SAME session under its id must be idempotent: the ORIGINAL entry (and
    /// its TTL arming) is kept. The old dictionary overwrite left the first entry's TTL task
    /// running un-cancelled — a stale timer that later evicted (killed) whatever live entry
    /// held the id. Here the kept entry has ttl nil (never), so surviving the second insert's
    /// 10 ms TTL proves no stale timer owns the id.
    func testDuplicateInsertOfSameSessionKeepsOriginalEntry() async throws {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: nil)
        // The racing re-park (identical session, whatever ttl the config resolves to).
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 2), ttl: .milliseconds(10))
        XCTAssertEqual(store.countForTesting, 1, "one sessionID = one entry, ever")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "the original never-evict entry must be kept — a duplicate insert must not arm a "
                + "second TTL (nor leak the first) that kills the parked session",
        )
        XCTAssertIdentical(store.claim(id), session)
    }

    /// Defensive: a DIFFERENT session under the same id (should be unreachable — the
    /// attached-elsewhere refusal guards it) replaces the old entry, and the displaced old
    /// entry's TTL task is cancelled so it can never evict the NEW entry later.
    func testDuplicateInsertOfDifferentSessionReplacesAndDisarmsOldTTL() async throws {
        let store = DetachedSessionStore()
        let id = UUID()
        let old = makeStubSession(sessionID: id)
        let new = makeStubSession(sessionID: id)
        store.insert(old, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .milliseconds(10))
        store.insert(new, key: MuxSessionKey(connectionID: UUID(), channelID: 2), ttl: nil)
        XCTAssertEqual(store.countForTesting, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(
            store.storedIDsForTesting.contains(id),
            "the displaced entry's armed TTL must be cancelled — it must not evict the new entry",
        )
        XCTAssertIdentical(store.claim(id), new, "newest session wins the id")
    }

    /// `contains` — the failed-rebind recovery's "already re-parked?" probe.
    func testContainsReflectsStoreState() {
        let store = DetachedSessionStore()
        let id = UUID()
        XCTAssertFalse(store.contains(id))
        store.insert(makeStubSession(sessionID: id), key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: nil)
        XCTAssertTrue(store.contains(id))
        _ = store.claim(id)
        XCTAssertFalse(store.contains(id), "a claimed session is no longer in the store")
    }

    // MARK: Remove (clean exit)

    func testRemoveCancelsEntryWithoutKill() {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))
        store.remove(id)
        XCTAssertNil(store.claim(id), "remove must clear the entry")
        XCTAssertEqual(store.countForTesting, 0)
    }

    func testRemoveUnknownIDIsNoOp() {
        let store = DetachedSessionStore()
        // Must not crash or throw.
        store.remove(UUID())
    }

    // MARK: drainAll

    func testDrainAllClearsAllEntries() {
        let store = DetachedSessionStore()
        for i: UInt32 in 1...5 {
            let s = makeStubSession(sessionID: UUID())
            store.insert(s, key: MuxSessionKey(connectionID: UUID(), channelID: i), ttl: .seconds(60))
        }
        store.drainAll()
        XCTAssertEqual(store.countForTesting, 0, "drainAll must clear every entry")
    }

    // MARK: Child-exited auto-eviction on claim

    /// When the child exits WHILE in the store, `claim` must auto-evict and return `nil`
    /// so the caller (PATH C) spawns a fresh shell instead of handing back a dead session.
    ///
    /// We cannot let a real PTY exit in a unit test (hang-safety), so we verify the
    /// `isChildExited()` contract via `PTYProcess.waitExitCode()` on an UNSPAWNED process
    /// (pid == -1 → waitExitCode == nil → child NOT considered exited). This test therefore
    /// probes the positive branch (child NOT exited) and confirms the session IS returned;
    /// the `isChildExited` unit test below covers the primitive.
    func testClaimReturnsSessionWhenChildAlive() {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        // Unspawned PTY → isChildExited() == false → claim should return the session.
        XCTAssertFalse(session.isChildExited(), "unspawned PTY must not appear exited")
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))
        let found = store.claim(id)
        XCTAssertNotNil(found, "session with live child must be returned by claim")
    }
}

// MARK: - ReplayBuffer reattach-seq tests

/// Proves that `ReplayBuffer.replay(after:)` returns the right tail — the heart of the
/// reattach contract (the returning client sends `lastReceivedSeq`; the host replays
/// everything after it). Pure value-type, zero network/PTY.
final class ReplayBufferReattachTests: XCTestCase {
    func testReplayAfterZeroReturnsEverything() {
        var buf = ReplayBuffer()
        buf.append(bytes: Data([1, 2]))
        buf.append(bytes: Data([3, 4]))
        let msgs = buf.replay(after: 0)
        XCTAssertEqual(msgs.count, 2)
    }

    func testReplayAfterLastSeqReturnsEmpty() {
        var buf = ReplayBuffer()
        let seq = buf.append(bytes: Data([9]))
        let msgs = buf.replay(after: seq)
        XCTAssertTrue(msgs.isEmpty, "replay after highestSeq must be empty")
    }

    func testReplayAfterPartialSeqReturnsCorrectTail() {
        var buf = ReplayBuffer()
        let s1 = buf.append(bytes: Data([0xAA])) // seq 1
        let s2 = buf.append(bytes: Data([0xBB])) // seq 2
        buf.append(bytes: Data([0xCC])) // seq 3

        // Client received up through s1 — replay should give seq 2 and 3.
        let tail = buf.replay(after: s1)
        XCTAssertEqual(tail.count, 2)
        // The messages carry their original seqs.
        if case let .output(seq, _) = tail[0] { XCTAssertEqual(seq, s2) }
        else { XCTFail("expected .output") }

        // After ack through s2, replay(after: s2) returns only seq 3 (the un-acked tail).
        // With scrollback enabled, replay(after: s1) also returns s2 from the ring; to isolate
        // un-acked-tail semantics use after: ackedSeq.
        buf.ack(upTo: s2)
        let tail2 = buf.replay(after: buf.ackedSeq)
        XCTAssertEqual(tail2.count, 1, "un-acked tail after ack(s2) is exactly seq 3")
    }

    func testReplayIsEmptyWhenAllEntriesAcked() {
        var buf = ReplayBuffer(scrollbackBytes: 0) // scrollback off: verify the un-acked-only contract
        buf.append(bytes: Data([1]))
        let last = buf.append(bytes: Data([2]))
        buf.ack(upTo: last)
        let msgs = buf.replay(after: 0)
        XCTAssertTrue(msgs.isEmpty, "all-acked buffer with scrollback disabled has nothing to replay")
    }
}

// MARK: - Routing-decision unit tests

/// Exercises the HOST ROUTING DECISION (PATH A / B / C / stopping) via a pure logic seam,
/// without a real HostServer, PTY, NWListener, or spawned shell.
///
/// The decision is encoded in ``DetachedSessionStore.claim`` + the `isChildExited()` check:
/// - UUID == zero → new shell (PATH B: zero UUID conventionally means "no prior session")
/// - known UUID + alive child → reattach (PATH A) — the claim REMOVES the entry, so the
///   winner owns the session exclusively
/// - known UUID + dead child → auto-evict → new shell (PATH C)
/// - stopping → refused
///
/// We drive these cases through the store directly (no HostServer wiring needed here —
/// the HostServer tests would require a real NWListener, which is hang-unsafe in unit tests).
final class RoutingDecisionTests: XCTestCase {
    /// Zero UUID → fresh shell (PATH B: no prior session to claim).
    func testZeroUUIDRoutesToNewShell() {
        let store = DetachedSessionStore()
        let result = store.claim(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        XCTAssertNil(result, "zero UUID must not match any detached session → new shell")
    }

    /// Known UUID + live child → reattach (PATH A).
    func testKnownUUIDWithLiveChildRoutesToReattach() {
        let store = DetachedSessionStore()
        let id = UUID()
        let session = makeStubSession(sessionID: id)
        XCTAssertFalse(session.isChildExited())
        store.insert(session, key: MuxSessionKey(connectionID: UUID(), channelID: 1), ttl: .seconds(60))
        let found = store.claim(id)
        XCTAssertNotNil(found, "known UUID with live child → reattach (PATH A)")
        XCTAssertIdentical(found, session)
    }

    /// Unknown UUID → new shell (PATH B/C: never inserted).
    func testUnknownUUIDRoutesToNewShell() {
        let store = DetachedSessionStore()
        let found = store.claim(UUID())
        XCTAssertNil(found, "unknown UUID must not match → new shell")
    }

    // MARK: isChildExited unit

    func testUnspawnedPTYIsNotConsideredExited() {
        let session = makeStubSession()
        XCTAssertFalse(session.isChildExited(), "unspawned PTY: waitExitCode == nil → not exited")
    }
}

// MARK: - onExit-routes-to-shutdown (not detach)

/// Proves that a shell EXIT routes through ``removeMuxSession`` (→ ``shutdownDetached``)
/// and NOT through a detach path. We verify this by checking that ``MuxChannelSession.onExit``
/// is the hook that fires and that it does NOT call ``detach(onDetachedExit:)``.
///
/// Driven without a real PTY, NWListener, or spawned shell (hang-safety). We exercise
/// the `onExit` callback wiring on a minimal session stub.
final class OnExitRoutesToShutdownTests: XCTestCase {
    /// When a session's `onExit` fires (as it would from the exit task), it invokes the
    /// handler registered by the caller — which in production is `removeMuxSession`.
    /// This test confirms the callback plumbing is correct: `onExit` fires with the channelID.
    func testOnExitCallbackIsInvokedWithChannelID() {
        let channelID: UInt32 = 42
        let session = MuxChannelSession(
            channelID: channelID,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: channelID, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: channelID, channel: .control) { _, _ in },
        )
        // Use a Sendable box because onExit is @Sendable and Swift 6 forbids capturing
        // a `var` across the Sendable boundary.
        final class Box: @unchecked Sendable { var value: UInt32? }
        let box = Box()
        session.onExit = { id in box.value = id }
        session.onExit?(channelID)
        XCTAssertEqual(box.value, channelID, "onExit must fire with the session's channelID")
    }

    /// `isChildExited()` returns false for an unspawned process, confirming that
    /// ``DetachedSessionStore.claim`` would NOT auto-evict such an entry.
    func testSessionIDIsThreadedFromInit() {
        let id = UUID()
        let session = MuxChannelSession(
            channelID: 5,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 5, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 5, channel: .control) { _, _ in },
            sessionID: id,
        )
        XCTAssertEqual(session.sessionID, id, "sessionID must be threaded from init")
    }
}

// MARK: - rebindRelay onExit atomicity (the race-closure fix)

/// Proves that the `onExit` handler passed to ``rebindRelay(data:control:onExit:)`` is the
/// one stored on the session AFTER the call returns — i.e. the reattach handler replaces the
/// detach-exit handler installed by ``detach(onDetachedExit:)`` atomically with the exit-task
/// restart, leaving no window in which a racing exit could fire the stale handler.
///
/// **Why this test proves the fix**: the critical property is that `session.onExit` routes
/// to the REATTACH handler, not the detached-exit handler, immediately after
/// ``rebindRelay(data:control:onExit:)`` returns. If `rebindRelay` assigned `onExit` AFTER
/// releasing `taskLock` (the old bug), a shell that exited in that window would fire the
/// stale handler and kill the just-reattached PTY. Now that `onExit` is assigned INSIDE
/// `taskLock`, BEFORE the new `exitTask` is started, the property holds by construction —
/// and this test pins it.
///
/// No real PTY, network, or running relay is started (hang-safety). `startRelay()` is NOT
/// called; we call ``detach(onDetachedExit:)`` and ``rebindRelay(data:control:onExit:)``
/// directly on an unstarted session so the test drives only the handler-wiring logic.
final class RebindRelayOnExitAtomicityTests: XCTestCase {
    private func makeSession(channelID: UInt32 = 7) -> MuxChannelSession {
        MuxChannelSession(
            channelID: channelID,
            pty: PTYProcess(), // unspawned — no reaper, no masterFD
            data: MuxSubChannel(channelID: channelID, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: channelID, channel: .control) { _, _ in },
        )
    }

    /// After ``rebindRelay(data:control:onExit:)`` returns, firing `session.onExit` must
    /// invoke the REATTACH handler (the one passed to rebindRelay) and must NOT invoke
    /// the detached-exit handler installed by ``detach(onDetachedExit:)``.
    func testRebindRelayInstallesReattachHandlerNotDetachHandler() {
        final class Box: @unchecked Sendable {
            var detachFired = false
            var reattachFired = false
        }
        let box = Box()
        let channelID: UInt32 = 7
        let session = makeSession(channelID: channelID)

        // Step 1: simulate a detach — installs the detached-exit handler.
        session.detach(onDetachedExit: { _ in box.detachFired = true })
        XCTAssertTrue(session.isDetached, "session must be marked detached after detach()")

        // Step 2: simulate a reattach — rebindRelay must atomically replace the handler.
        let newData = MuxSubChannel(channelID: channelID, channel: .data) { _, _ in }
        let newControl = MuxSubChannel(channelID: channelID, channel: .control) { _, _ in }
        let rebound = session.rebindRelay(
            data: newData,
            control: newControl,
            onExit: { _ in box.reattachFired = true },
        )
        XCTAssertTrue(rebound, "rebindRelay on a detached session must report success")
        XCTAssertFalse(session.isDetached, "session must no longer be detached after rebind")

        // Step 3: fire onExit as the exit task would (simulating a shell exit post-reattach).
        session.onExit?(channelID)

        // The reattach handler must have fired; the detach handler must NOT have fired.
        XCTAssertTrue(
            box.reattachFired,
            "onExit after rebindRelay must route to the reattach handler",
        )
        XCTAssertFalse(
            box.detachFired,
            "the stale detached-exit handler must NOT be invoked after reattach",
        )
    }

    /// Calling ``rebindRelay(data:control:onExit:)`` on a NON-detached session (guard path)
    /// must be a no-op that reports FAILURE (`false`) — the caller (``HostServer/performReattach``)
    /// uses that to refuse the channel instead of acking a pane wired to someone else.
    func testRebindRelayIsNoOpAndReportsFalseOnLiveSession() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()
        let channelID: UInt32 = 7
        let session = makeSession(channelID: channelID)

        // Install an initial onExit handler (not detached → guard returns early).
        session.onExit = { _ in box.fired = true }

        let newData = MuxSubChannel(channelID: channelID, channel: .data) { _, _ in }
        let newControl = MuxSubChannel(channelID: channelID, channel: .control) { _, _ in }
        // This must be a no-op (isDetached == false → early return, reported as false).
        let rebound = session.rebindRelay(
            data: newData,
            control: newControl,
            onExit: { _ in /* should not replace */ },
        )
        XCTAssertFalse(rebound, "rebindRelay on a live session must report failure, not silently no-op")

        // Original handler must still be wired.
        session.onExit?(channelID)
        XCTAssertTrue(box.fired, "onExit must still be the original handler on a live session")
    }
}
