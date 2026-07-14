import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// ScrollbackJournalStore fd-leak (session-lifecycle audit): the store's `journals` map + each
/// journal's open FileHandle used to be reclaimed ONLY by `delete(sessionID:)` — the deliberate
/// close. Every NON-deliberate end of life (TTL eviction, overflow eviction, shell death while
/// parked) leaked one fd + one map entry for the daemon's lifetime, and — because `sweep()`
/// exempts any id present in the map — made the on-disk file permanently unsweepable too.
///
/// The fix is a RELEASE, distinct from delete: flush the coalescing buffer, close the handle,
/// drop the map entry — and KEEP the file (it is the scrollback-restore source for a later cold
/// client / the next daemon life; delete-the-file stays exclusive to deliberate close).
///
/// All headless: unspawned PTYs, temp-dir stores, no NWListener (hang-safety). The host paths
/// are driven via the same `…ForTesting` seams the reattach-orphan suite uses.
final class HostServerJournalReleaseTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-journal-release-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defer { super.tearDown() }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore(byteCap: Int = ReplayBuffer.defaultScrollbackBytes) -> ScrollbackJournalStore {
        ScrollbackJournalStore(directory: tempDir, byteCap: byteCap)
    }

    /// Mirrors production wiring: `spawnFreshShell` hands the session its `claimJournal(for:)`
    /// writer, and the release paths are IDENTITY-GUARDED against that instance — a session
    /// constructed without its journal would (correctly) never release the store's writer.
    private func makeSession(sessionID: UUID = UUID(), journals: ScrollbackJournalStore? = nil) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — no reaper thread, no masterFD (hang-safety)
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            sessionID: sessionID,
            scrollbackJournal: journals?.journal(for: sessionID),
        )
    }

    private func makeServer(
        journals: ScrollbackJournalStore,
        detachMaxSessions: Int? = nil,
    ) -> HostServer {
        HostServer(
            port: 0,
            detachEnabled: true,
            detachMaxSessions: detachMaxSessions,
            resumeOnRecovery: true,
            scrollbackJournals: journals,
        )
    }

    private func journalFileURL(for sessionID: UUID) -> URL {
        tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback", isDirectory: false)
    }

    /// Polls `condition` (up to ~5 s) so async teardown paths get scheduled.
    private func waitUntil(_ condition: @Sendable () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: - (1) each non-deliberate end of life releases writer + map entry, file survives

    /// A shell that dies while PARKED (the `onDetachedExit` path) never reaches
    /// `removeMuxSession` — the detached-exit closure must release the writer (fd + map entry)
    /// while the FILE survives with full contents (the restore source for a returning client).
    func testDetachedExitReleasesWriterAndKeepsFile() {
        let store = makeStore()
        let server = makeServer(journals: store)
        let id = UUID()
        let transcript = Data("agent output while parked\n".utf8)
        store.journal(for: id).append(transcript)
        store.journal(for: id).synchronize()

        let session = makeSession(sessionID: id, journals: store)
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: session)
        session.onExit?(0) // the shell exits while parked → the wired onDetachedExit fires

        waitUntil { !store.hasLiveWriterForTesting(id) }
        XCTAssertFalse(
            store.hasLiveWriterForTesting(id),
            "detached exit must release the journal writer (fd + map entry) — the old code "
                + "leaked one per parked death for the daemon's lifetime",
        )
        XCTAssertEqual(
            try? Data(contentsOf: journalFileURL(for: id)), transcript,
            "the FILE must survive a detached exit — it is the scrollback-restore source",
        )
    }

    /// TTL eviction (the timer task's `evict`) must release the writer the same way.
    func testTTLEvictionReleasesWriterAndKeepsFile() {
        let store = makeStore()
        let server = makeServer(journals: store)
        let id = UUID()
        let transcript = Data("still restorable after TTL\n".utf8)
        store.journal(for: id).append(transcript)
        store.journal(for: id).synchronize()

        let session = makeSession(sessionID: id, journals: store)
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: session)
        // Drive the REAL eviction path directly (the TTL task's only body) — no timer wait.
        server.detachedStoreForTesting?.evict(id)

        waitUntil { !store.hasLiveWriterForTesting(id) }
        XCTAssertFalse(
            store.hasLiveWriterForTesting(id),
            "TTL eviction must release the journal writer — fd + map entry, one per eviction",
        )
        XCTAssertEqual(
            try? Data(contentsOf: journalFileURL(for: id)), transcript,
            "the FILE must survive TTL eviction (docs: only deliberate close deletes)",
        )
    }

    /// Overflow eviction (the opt-in `SLOPDESK_DETACH_MAX_SESSIONS` cap) evicts the OLDEST
    /// parked session — its writer must be released; the survivor's writer must stay live.
    func testOverflowEvictionReleasesVictimWriterOnly() {
        let store = makeStore()
        let server = makeServer(journals: store, detachMaxSessions: 1)
        let victimID = UUID(), survivorID = UUID()
        let victimBytes = Data("victim transcript\n".utf8)
        store.journal(for: victimID).append(victimBytes)
        store.journal(for: victimID).synchronize()
        _ = store.journal(for: survivorID) // survivor's live writer

        let victim = makeSession(sessionID: victimID, journals: store)
        let survivor = makeSession(sessionID: survivorID, journals: store)
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: victim)
        // Parking the second session overflows the cap=1 store → the oldest (victim) is evicted.
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: survivor)
        XCTAssertEqual(server.detachedStoreForTesting?.storedIDsForTesting, [survivorID])

        waitUntil { !store.hasLiveWriterForTesting(victimID) }
        XCTAssertFalse(
            store.hasLiveWriterForTesting(victimID),
            "the overflow victim's journal writer must be released",
        )
        XCTAssertTrue(
            store.hasLiveWriterForTesting(survivorID),
            "the surviving parked session's writer must stay live",
        )
        XCTAssertEqual(
            try? Data(contentsOf: journalFileURL(for: victimID)), victimBytes,
            "the victim's FILE must survive (a returning client can still cold-restore)",
        )
    }

    // MARK: - (1b) a STALE detached-exit (teardown already taken over) stands down

    /// The reattach-after-parked-death race: the reconnect's `claim()` reaps the dead child
    /// (taking over its teardown) and the same-UUID fresh spawn rotates the journal writer —
    /// then the ghost's exit task fires its `onDetachedExit` closure LATE. The stale closure
    /// must stand down (`remove` returns false): before the guard it released the SHARED
    /// journal instance, silently killing the successor's journaling for the pane's lifetime.
    func testStaleDetachedExitAfterClaimReapStandsDown() {
        let store = makeStore()
        let server = makeServer(journals: store)
        let id = UUID()
        let ghost = makeSession(sessionID: id, journals: store)
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: ghost)
        ghost.pty.completeExitForTesting(code: 0) // dies while parked

        // Reconnect: the claim reaps the dead child — the CALLER now owns the teardown.
        guard case .reapedDeadChild = server.detachedStoreForTesting?.claim(id) else {
            XCTFail("claim of a parked dead child must report .reapedDeadChild")
            return
        }
        // The same-UUID fresh spawn takes journal ownership (what `spawnFreshShell` does).
        let successor = store.claimJournal(for: id)
        successor.append(Data("successor output\n".utf8))

        // The ghost's stale detached-exit closure fires late…
        ghost.onExit?(0)

        // …and the successor's journaling must be unharmed.
        XCTAssertTrue(
            store.hasLiveWriterForTesting(id),
            "a stale detached-exit must not release the successor's writer",
        )
        successor.append(Data("more\n".utf8))
        successor.synchronize()
        XCTAssertEqual(
            try? Data(contentsOf: journalFileURL(for: id)),
            Data("successor output\nmore\n".utf8),
            "the successor keeps journaling after the ghost's late teardown",
        )
    }

    // MARK: - (2) a later journal(for:) transparently reopens append-at-end

    /// The re-park / same-daemon-restore shape: after a release, `journal(for:)` for the same
    /// id must vend a fresh writer that appends AFTER the released bytes — full round-trip via
    /// `restoredScrollback`.
    func testJournalReopensAndAppendsAfterRelease() {
        let store = makeStore()
        let server = makeServer(journals: store)
        let id = UUID()
        let old = Data("before-eviction\n".utf8)
        store.journal(for: id).append(old)
        store.journal(for: id).synchronize()

        let session = makeSession(sessionID: id)
        server.detachMuxSessionForTesting(key: MuxSessionKey(connectionID: UUID(), channelID: 1), session: session)
        session.onExit?(0)
        waitUntil { !store.hasLiveWriterForTesting(id) }

        let new = Data("after-respawn\n".utf8)
        store.journal(for: id).append(new) // a fresh spawn for the returning id re-vends
        XCTAssertEqual(
            store.restoredScrollback(for: id),
            old + new + ScrollbackJournalStore.sanitizeSuffix,
            "a released journal must reopen append-at-end — no corruption, no lost head",
        )
    }

    // MARK: - (3) deliberate close still deletes the file

    /// The policy boundary must not move: a peer `channelClose` / attached child exit
    /// (`removeMuxSession`) still DELETES the file.
    func testDeliberateCloseStillDeletesFile() {
        let store = makeStore()
        let server = makeServer(journals: store)
        let id = UUID()
        store.journal(for: id).append(Data("gone with the pane\n".utf8))
        store.journal(for: id).synchronize()

        let session = makeSession(sessionID: id)
        let key = MuxSessionKey(connectionID: UUID(), channelID: 1)
        server.registerMuxSessionForTesting(session, key: key)
        server.removeMuxSessionForTesting(key)

        let filePath = journalFileURL(for: id).path
        waitUntil { !FileManager.default.fileExists(atPath: filePath) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filePath),
            "deliberate close must keep deleting the journal file",
        )
        XCTAssertFalse(store.hasLiveWriterForTesting(id))
    }
}
