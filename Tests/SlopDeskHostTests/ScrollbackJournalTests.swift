import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Disk scrollback journal: the transcript must survive the DAEMON (hostd restart / reboot /
/// TTL eviction all end in `spawnFreshShell`, which starts an empty transcript — without the
/// journal, scrollback history is lost on reconnect).
///
/// Two `ScrollbackJournalStore` instances over the SAME directory model two daemon lives; the
/// `MuxChannelSession` tests drive the REAL production paths via the `ingestPTYChunkForTesting` /
/// `enqueueRestoredScrollbackForTesting` seams (the production `onChunk` closure and
/// `startRelay()` make exactly those calls). All headless — no PTY spawn, no sockets.
final class ScrollbackJournalTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrollback-journal-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defer { super.tearDown() }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore(
        byteCap: Int = ReplayBuffer.defaultScrollbackBytes,
        distiller: (@Sendable (Data) -> Data)? = nil,
    ) -> ScrollbackJournalStore {
        ScrollbackJournalStore(directory: tempDir, byteCap: byteCap, distiller: distiller)
    }

    // MARK: - The loss case: transcript survives a daemon restart

    /// THE repro-turned-proof: bytes journaled by daemon life 1 are restorable by daemon life 2
    /// (a brand-new store over the same directory — everything in-memory is gone). Without the
    /// journal this is exactly where history died.
    func testTranscriptSurvivesDaemonRestart() {
        let sessionID = UUID()
        let transcript = Data("$ make check\nall green\n".utf8)

        let life1 = makeStore()
        life1.journal(for: sessionID).append(transcript)
        life1.journal(for: sessionID).synchronize()

        let life2 = makeStore() // fresh process: no shared state with life1 but the directory
        let restored = life2.restoredScrollback(for: sessionID)
        XCTAssertEqual(
            restored, transcript + ScrollbackJournalStore.sanitizeSuffix,
            "a returning session ID must get its prior life's transcript (+ the mode-sanitize reset) back",
        )
    }

    /// Continuity: restoring must not double the transcript across restarts — life 2 keeps
    /// APPENDING to the same file (the restored preamble never re-enters the journal), so a
    /// third life sees old + new exactly once.
    func testRestoreDoesNotDoubleAcrossRestarts() {
        let sessionID = UUID()
        let old = Data("old-life\n".utf8)
        let new = Data("new-life\n".utf8)

        let life1 = makeStore()
        life1.journal(for: sessionID).append(old)
        life1.journal(for: sessionID).synchronize()

        let life2 = makeStore()
        _ = life2.restoredScrollback(for: sessionID) // restore consumes nothing…
        life2.journal(for: sessionID).append(new) // …and live output keeps appending
        life2.journal(for: sessionID).synchronize()

        let life3 = makeStore()
        XCTAssertEqual(
            life3.restoredScrollback(for: sessionID),
            old + new + ScrollbackJournalStore.sanitizeSuffix,
            "each restart must see the transcript exactly once (no re-journaled preamble doubling)",
        )
    }

    func testRestoredScrollbackNilWhenNothingJournaled() {
        XCTAssertNil(makeStore().restoredScrollback(for: UUID()))
    }

    /// The distiller runs at RESTORE time over the raw bytes (so a distiller improvement
    /// retroactively benefits old journals), before the sanitize suffix.
    func testRestoreAppliesDistillerThenSanitizeSuffix() {
        let sessionID = UUID()
        let store = makeStore(distiller: { raw in Data("D[".utf8) + raw + Data("]".utf8) })
        store.journal(for: sessionID).append(Data("x".utf8))
        store.journal(for: sessionID).synchronize()

        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("D[x]".utf8) + ScrollbackJournalStore.sanitizeSuffix,
        )
    }

    /// The PRODUCTION store (`makeFromEnvironment` → `ScrollbackReplayTransform`) restores a
    /// journaled zsh prompt cycle with the width-stale PROMPT_SP mark+fill cluster stripped —
    /// the last seam between the unit-tested stripper and the wire preamble.
    func testProductionRestoreStripsPromptEOLMarkClusters() throws {
        let sessionID = UUID()
        let store = try XCTUnwrap(ScrollbackJournalStore.makeFromEnvironment(
            environment: ["SLOPDESK_SCROLLBACK_DIR": tempDir.path],
        ))
        let cluster = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
            + String(repeating: " ", count: 121) + "\r \r"
        let cycle = "ls output\r\n" + cluster + "\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}PS1 "
        store.journal(for: sessionID).append(Data(cycle.utf8))
        store.journal(for: sessionID).synchronize()

        let restored = try XCTUnwrap(store.restoredScrollback(for: sessionID))
        let text = try XCTUnwrap(String(bytes: restored, encoding: .utf8))
        XCTAssertFalse(text.contains("\u{1B}[7m%"), "the standout mark must not reach the preamble")
        XCTAssertFalse(text.contains(String(repeating: " ", count: 40)), "nor the COLUMNS-wide fill")
        XCTAssertTrue(text.contains("ls output"), "real output survives")
        XCTAssertTrue(text.contains("\u{1B}]133;A\u{07}"), "the prompt anchor survives")
        XCTAssertTrue(restored.suffix(ScrollbackJournalStore.sanitizeSuffix.count)
            .elementsEqual(ScrollbackJournalStore.sanitizeSuffix))
    }

    // MARK: - Cap / compaction

    /// The file is bounded: past 2× cap it compacts to the newest ~cap tail, and the surviving
    /// head starts just past a `\n` (line-aligned, not mid-escape).
    func testCompactionKeepsNewestTailLineAligned() throws {
        let cap = 1024
        let sessionID = UUID()
        let store = makeStore(byteCap: cap)
        let journal = store.journal(for: sessionID)

        // 64 numbered 64-byte lines = 4 KiB — crosses 2×cap (2 KiB) mid-way, forcing compaction.
        var lines: [Data] = []
        for i in 0..<64 {
            let body = String(format: "line-%03d-", i)
            let pad = String(repeating: "x", count: 64 - body.count - 1)
            lines.append(Data((body + pad + "\n").utf8))
        }
        for line in lines { journal.append(line) }
        journal.synchronize()

        let bytes = try? Data(contentsOf: tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback"))
        let file = try XCTUnwrap(bytes)
        XCTAssertLessThanOrEqual(file.count, cap + 4096, "compaction must bound the file near the cap")
        XCTAssertTrue(file.suffix(lines[63].count) == lines[63], "the newest line must survive verbatim")
        XCTAssertTrue(
            file.prefix(5) == Data("line-".utf8),
            "the surviving head must start on a line boundary (cut advanced past the next \\n)",
        )
    }

    // MARK: - Deletion / sweep

    func testDeleteRemovesFileAndLateAppendDoesNotResurrect() {
        let sessionID = UUID()
        let store = makeStore()
        let journal = store.journal(for: sessionID)
        journal.append(Data("gone\n".utf8))
        journal.synchronize()

        store.delete(sessionID: sessionID)
        journal.append(Data("zombie\n".utf8)) // a late chunk racing the close
        journal.synchronize()

        XCTAssertNil(store.restoredScrollback(for: sessionID), "deleted journal must stay deleted")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback").path,
            ),
        )
    }

    /// Delete must also work with NO writer in this process (a pane closed right after a
    /// daemon restart — the file exists but no `ScrollbackJournal` was ever vended).
    func testDeleteWithoutWriterRemovesOrphanFile() {
        let sessionID = UUID()
        let life1 = makeStore()
        life1.journal(for: sessionID).append(Data("x".utf8))
        life1.journal(for: sessionID).synchronize()

        let life2 = makeStore() // never vends a writer for this ID
        life2.delete(sessionID: sessionID)
        XCTAssertNil(life2.restoredScrollback(for: sessionID))
    }

    func testSweepDeletesAgedAndOverCountJournals() throws {
        // Files come from a PRIOR daemon life (a separate store instance over the same dir), so
        // the sweeping store holds no live writers — the production shape: sweep runs at daemon
        // start, before any pane vends a journal.
        let priorLife = makeStore()
        let fm = FileManager.default

        // Three journals: one ancient, two fresh.
        let ancient = UUID(), fresh1 = UUID(), fresh2 = UUID()
        for id in [ancient, fresh1, fresh2] {
            priorLife.journal(for: id).append(Data("x".utf8))
            priorLife.journal(for: id).synchronize()
        }
        let ancientURL = tempDir.appendingPathComponent("\(ancient.uuidString).scrollback")
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: ancientURL.path,
        )

        let store = makeStore() // the fresh life doing the sweeping
        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 256)
        XCTAssertFalse(fm.fileExists(atPath: ancientURL.path), "past-maxAge journal must be swept")
        XCTAssertNotNil(store.restoredScrollback(for: fresh1))

        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 1)
        let survivors = try fm.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".scrollback") }
        XCTAssertEqual(survivors.count, 1, "keepNewest must bound the file count")
    }

    /// Sweep must NEVER unlink a file a LIVE writer holds open — POSIX
    /// `write()` to an unlinked inode keeps succeeding silently, so the pane would keep
    /// journaling into a file nobody can ever restore (the whole transcript silently lost).
    /// A reconnect can vend the writer while the startup sweep is still scanning; even a
    /// by-policy-stale file (ancient mtime / over the count cap) is exempt once vended.
    func testSweepSkipsFilesWithLiveWriters() throws {
        let store = makeStore()
        let fm = FileManager.default
        let live = UUID()
        let journal = store.journal(for: live) // vended writer = live pane
        journal.append(Data("still-writing".utf8))
        journal.synchronize()
        let liveURL = tempDir.appendingPathComponent("\(live.uuidString).scrollback")
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: liveURL.path,
        )

        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 256)
        XCTAssertTrue(
            fm.fileExists(atPath: liveURL.path),
            "a live writer's file must survive sweep regardless of its mtime",
        )

        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 0)
        XCTAssertTrue(
            fm.fileExists(atPath: liveURL.path),
            "a live writer's file must survive the keepNewest bound too",
        )

        // And the writer still works after the sweeps (nothing was unlinked under it).
        journal.append(Data(" more".utf8))
        journal.synchronize()
        XCTAssertNotNil(store.restoredScrollback(for: live))
    }

    // MARK: - Write coalescing (buffered appends must never be observable as missing bytes)

    private func journalFileURL(for sessionID: UUID) -> URL {
        tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback", isDirectory: false)
    }

    /// Polls the on-disk journal file until it equals `expected` (or the deadline passes),
    /// returning whatever the file last held. No `synchronize()` — this observes flushes the
    /// journal performs on its own.
    private func waitForDiskBytes(_ expected: Data, sessionID: UUID, timeout: TimeInterval = 3) -> Data? {
        let url = journalFileURL(for: sessionID)
        let deadline = Date().addingTimeInterval(timeout)
        var last: Data?
        while Date() < deadline {
            last = try? Data(contentsOf: url)
            if last == expected { return last }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return last
    }

    /// (a) Appends smaller than any coalescing threshold must be restorable immediately:
    /// `restoredScrollback` forces the writer's buffered bytes to disk before reading, so a
    /// restore can never observe a file missing enqueued appends.
    func testSmallAppendsRestorableViaRestoreWithoutExplicitSynchronize() {
        let sessionID = UUID()
        let store = makeStore()
        let journal = store.journal(for: sessionID)
        journal.append(Data("a".utf8))
        journal.append(Data("b".utf8))
        journal.append(Data("c\n".utf8))
        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("abc\n".utf8) + ScrollbackJournalStore.sanitizeSuffix,
            "restore must observe every append enqueued before it — buffered bytes included",
        )
    }

    /// (b) Idle flush: one small append must reach the DISK file shortly after, with nobody
    /// calling synchronize() — pins the crash-loss window of a coalescing buffer.
    func testIdleFlushPersistsSmallAppendWithoutSynchronize() {
        let sessionID = UUID()
        let store = makeStore()
        let bytes = Data("idle-flush\n".utf8)
        store.journal(for: sessionID).append(bytes)
        XCTAssertEqual(
            waitForDiskBytes(bytes, sessionID: sessionID), bytes,
            "buffered bytes must hit disk via the idle flush without an explicit synchronize",
        )
    }

    /// Threshold flush: a burst crossing the coalescing threshold (32 KiB) must not wait for
    /// idle — the file catches up promptly under a continuous small-chunk stream.
    func testThresholdFlushPersistsLargeVolumeWithoutSynchronize() {
        let sessionID = UUID()
        let store = makeStore()
        let journal = store.journal(for: sessionID)
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 4096)
        var expected = Data()
        for _ in 0..<9 { // 36 KiB — crosses a 32 KiB coalescing threshold
            journal.append(chunk)
            expected.append(chunk)
        }
        XCTAssertEqual(
            waitForDiskBytes(expected, sessionID: sessionID)?.count, expected.count,
            "crossing the coalescing threshold must flush without waiting for idle/synchronize",
        )
    }

    /// (c) Cap/compaction with MANY small appends (each far below any flush threshold): the
    /// cap accounting must count buffered-but-unflushed bytes, and compaction must run over a
    /// file that already contains them — bounded file, newest line verbatim, line-aligned head.
    func testCompactionAfterSmallBufferedAppendsYieldsCorrectFile() throws {
        let cap = 512
        let sessionID = UUID()
        let store = makeStore(byteCap: cap)
        let journal = store.journal(for: sessionID)

        // 64 numbered 32-byte lines = 2 KiB = 4×cap; every chunk is tiny (buffered, never
        // threshold-flushed), so ONLY the cap path can keep the file bounded.
        var lines: [Data] = []
        for i in 0..<64 {
            let body = String(format: "line-%03d-", i)
            let pad = String(repeating: "y", count: 32 - body.count - 1)
            lines.append(Data((body + pad + "\n").utf8))
        }
        for line in lines { journal.append(line) }
        journal.synchronize()

        let file = try XCTUnwrap(try? Data(contentsOf: journalFileURL(for: sessionID)))
        XCTAssertLessThanOrEqual(
            file.count, cap * 2 + 64,
            "cap accounting must include buffered bytes — the file stays bounded near 2×cap",
        )
        XCTAssertEqual(file.suffix(lines[63].count), lines[63], "the newest line must survive verbatim")
        XCTAssertEqual(
            file.prefix(5), Data("line-".utf8),
            "the surviving head must start on a line boundary (cut advanced past the next \\n)",
        )
    }

    /// A deliberate delete discards buffered bytes with the file: a pending (unflushed) append
    /// must not resurrect the journal when a late idle flush fires after closeAndDelete.
    func testDeleteDiscardsBufferedBytesWithoutResurrection() {
        let sessionID = UUID()
        let store = makeStore()
        let journal = store.journal(for: sessionID)
        journal.append(Data("buffered-then-deleted\n".utf8))
        store.delete(sessionID: sessionID) // no synchronize — the append may still be buffered

        // Give any stale idle-flush timer time to fire, then prove the file stayed gone.
        Thread.sleep(forTimeInterval: 0.2)
        journal.synchronize()
        XCTAssertNil(store.restoredScrollback(for: sessionID), "deleted journal must stay deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFileURL(for: sessionID).path))
    }

    // MARK: - Release (non-deliberate end of life: fd + map entry reclaimed, FILE kept)

    /// `release` must flush the coalescing buffer (no lost tail), drop the map entry, and KEEP
    /// the file — nobody calls synchronize, so only the release's own flush can persist the
    /// buffered bytes.
    func testReleaseFlushesBufferDropsWriterAndKeepsFile() {
        let sessionID = UUID()
        let store = makeStore()
        let tail = Data("buffered-tail\n".utf8) // far below the 32 KiB threshold — buffered
        store.journal(for: sessionID).append(tail)

        store.release(sessionID: sessionID, instance: store.journal(for: sessionID))
        XCTAssertFalse(
            store.hasLiveWriterForTesting(sessionID),
            "release must drop the map entry (the fd-leak half of the defect)",
        )
        let url = tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")
        XCTAssertEqual(
            try? Data(contentsOf: url), tail,
            "release must flush the coalescing buffer into the SURVIVING file — losing the "
                + "buffered tail would truncate the restore transcript",
        )
    }

    /// A late append racing the release (a straggling PTY chunk) must not reopen the closed
    /// handle — the store no longer tracks this instance, so a reopened fd would never close.
    func testReleasedWriterDropsLateAppends() {
        let sessionID = UUID()
        let store = makeStore()
        let kept = Data("kept\n".utf8)
        let journal = store.journal(for: sessionID)
        journal.append(kept)
        store.release(sessionID: sessionID, instance: store.journal(for: sessionID))

        journal.append(Data("late-straggler\n".utf8))
        journal.synchronize() // would flush the straggler if the instance were still open
        let url = tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")
        XCTAssertEqual(
            try? Data(contentsOf: url), kept,
            "a released writer must drop late appends instead of resurrecting its handle",
        )
    }

    /// After a release the id must be SWEEPABLE again: the map entry is gone, so `sweep()`'s
    /// live-writer exemption no longer pins the file forever (the on-disk half of the defect).
    func testReleasedJournalIsSweepableByMtime() throws {
        let sessionID = UUID()
        let store = makeStore()
        store.journal(for: sessionID).append(Data("x".utf8))
        store.journal(for: sessionID).synchronize()
        store.release(sessionID: sessionID, instance: store.journal(for: sessionID))

        let url = tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: url.path,
        )
        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 256)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a released (no-live-writer) journal must age out via sweep like any orphan",
        )
    }

    /// The re-vend shape: `journal(for:)` after a release yields a FRESH writer that appends
    /// AT END of the surviving bytes (openIfNeeded's seekToEnd) — full restore round-trip.
    func testJournalForAfterReleaseReopensAppendAtEnd() {
        let sessionID = UUID()
        let store = makeStore()
        let old = Data("old\n".utf8)
        let new = Data("new\n".utf8)
        store.journal(for: sessionID).append(old)
        store.release(sessionID: sessionID, instance: store.journal(for: sessionID))

        store.journal(for: sessionID).append(new) // transparently reopened
        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            old + new + ScrollbackJournalStore.sanitizeSuffix,
            "a post-release journal(for:) must append after the released bytes, corrupting nothing",
        )
    }

    /// The policy boundary: a deliberate close AFTER a release must still delete the file
    /// (the no-writer-in-this-process delete path).
    func testDeleteAfterReleaseRemovesFile() {
        let sessionID = UUID()
        let store = makeStore()
        store.journal(for: sessionID).append(Data("x".utf8))
        store.release(sessionID: sessionID, instance: store.journal(for: sessionID))

        store.delete(sessionID: sessionID)
        let url = tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.restoredScrollback(for: sessionID))
    }

    // MARK: - Fresh-spawn ownership (claimJournal rotation + identity-guarded lifecycle)

    /// `claimJournal(for:)` takes exclusive ownership for a fresh spawn: a ghost instance a
    /// same-UUID predecessor still holds is rotated OUT (flushed + closed — its later appends
    /// drop instead of interleaving), and the fresh writer appends to the SAME file so the
    /// transcript stays continuous.
    func testClaimJournalRotatesGhostWriterKeepingTranscriptContinuous() {
        let sessionID = UUID()
        let store = makeStore()
        let ghost = store.journal(for: sessionID)
        ghost.append(Data("old-life\n".utf8))

        let fresh = store.claimJournal(for: sessionID)
        XCTAssertNotIdentical(ghost, fresh, "a cache hit means a ghost owner — never share the instance")

        ghost.append(Data("GHOST-INTERLEAVE".utf8)) // closed by the rotation → dropped
        fresh.append(Data("new-life\n".utf8))
        fresh.synchronize()
        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("old-life\nnew-life\n".utf8) + ScrollbackJournalStore.sanitizeSuffix,
            "the ghost's flushed tail + the successor's output, in order — no interleave, no loss",
        )
    }

    /// A STALE release (the ghost's late teardown, after a successor claimed the id) must not
    /// close the successor's writer — the exact silent-journaling-death the identity guard fixes.
    func testStaleReleaseCannotCloseSuccessorWriter() {
        let sessionID = UUID()
        let store = makeStore()
        let ghost = store.journal(for: sessionID)
        let fresh = store.claimJournal(for: sessionID)

        store.release(sessionID: sessionID, instance: ghost) // stale owner stands down
        XCTAssertTrue(
            store.hasLiveWriterForTesting(sessionID),
            "the successor's map entry must survive a stale release",
        )
        fresh.append(Data("still journaling\n".utf8))
        fresh.synchronize()
        XCTAssertEqual(
            try? Data(contentsOf: tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")),
            Data("still journaling\n".utf8),
            "the successor must keep journaling after the ghost's stale release",
        )
    }

    /// A STALE delete must not unlink the successor's file (nor drop its writer).
    func testStaleDeleteCannotRemoveSuccessorFile() {
        let sessionID = UUID()
        let store = makeStore()
        let ghost = store.journal(for: sessionID)
        let fresh = store.claimJournal(for: sessionID)
        fresh.append(Data("live\n".utf8))
        fresh.synchronize()

        store.delete(sessionID: sessionID, instance: ghost) // stale owner stands down
        let url = tempDir.appendingPathComponent("\(sessionID.uuidString).scrollback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.hasLiveWriterForTesting(sessionID))

        store.delete(sessionID: sessionID, instance: fresh) // the real owner still deletes
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Environment gates

    func testMakeFromEnvironmentGates() {
        XCTAssertNil(
            ScrollbackJournalStore.makeFromEnvironment(environment: ["SLOPDESK_SCROLLBACK_PERSIST": "0"]),
            "the master scrollback gate must also gate the disk journal",
        )
        XCTAssertNil(
            ScrollbackJournalStore.makeFromEnvironment(environment: ["SLOPDESK_SCROLLBACK_DISK": "0"]),
            "the disk-specific kill switch must disable journaling alone",
        )
        XCTAssertNil(
            ScrollbackJournalStore.makeFromEnvironment(environment: ["SLOPDESK_SCROLLBACK_BYTES": "0"]),
            "a zero cap disables the journal (nothing could ever be kept)",
        )
        let store = ScrollbackJournalStore.makeFromEnvironment(
            environment: ["SLOPDESK_SCROLLBACK_BYTES": "12345"],
        )
        XCTAssertEqual(store?.byteCap, 12345, "default-ON with the ring's byte-cap env honored")
    }
}

/// The `MuxChannelSession` half: the journal hook sits on the PTY chunk path, and the restored
/// preamble enters via the out-FIFO — proving both the delivery ORDER (preamble first) and the
/// no-doubling invariant (preamble never re-journaled).
final class MuxChannelSessionScrollbackJournalTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-journal-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defer { super.tearDown() }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

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

    private func makeSession(journal: ScrollbackJournal? = nil, restored: Data? = nil) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; producers driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            scrollbackJournal: journal,
            restoredScrollback: restored,
        )
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// PTY chunks (the production `onChunk` → `ingestPTYChunk` path) land in the disk journal.
    func testPTYChunksAreJournaled() {
        let store = ScrollbackJournalStore(directory: tempDir)
        let sessionID = UUID()
        let session = makeSession(journal: store.journal(for: sessionID))

        session.ingestPTYChunkForTesting(Data("hello ".utf8))
        session.ingestPTYChunkForTesting(Data("world\n".utf8))
        store.journal(for: sessionID).synchronize()

        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("hello world\n".utf8) + ScrollbackJournalStore.sanitizeSuffix,
            "every PTY output chunk must be journaled in order",
        )
    }

    /// The restored preamble is delivered as the FIRST output — before any live PTY byte — and
    /// is NEVER re-journaled (only the PTY chunk crosses the journal hook).
    func testRestoredPreambleIsDeliveredFirstAndNotReJournaled() async {
        let store = ScrollbackJournalStore(directory: tempDir)
        let sessionID = UUID()
        let preamble = Data("OLD-LIFE\n".utf8)
        let live = Data("NEW-LIFE\n".utf8)
        let session = makeSession(journal: store.journal(for: sessionID), restored: preamble)
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })

        // Mirror startRelay's order: preamble enqueued before any PTY chunk flows.
        session.enqueueRestoredScrollbackForTesting()
        session.ingestPTYChunkForTesting(live)

        // Start the drain against recording sub-channels (the detach→rebind pattern the
        // sibling reattach tests use — no PTY needed).
        session.detach(onDetachedExit: { _ in })
        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))

        let expected = preamble + live
        await waitUntil { recorder.outputBytes == expected }
        XCTAssertEqual(
            recorder.outputBytes, expected,
            "the prior life's transcript must precede every live shell byte on the wire",
        )

        store.journal(for: sessionID).synchronize()
        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            live + ScrollbackJournalStore.sanitizeSuffix,
            "the preamble must NOT be re-journaled — journaling it would double the transcript every restart",
        )
    }

    /// The stored restore preamble must be RELEASED once enqueued: the enqueue copies it into
    /// the out-FIFO (the drain owns it from there), and keeping the stored property pinned a
    /// second up-to-journal-cap copy for the session's entire life — per pane.
    func testRestoredScrollbackIsReleasedAfterEnqueue() {
        let preamble = Data("OLD-LIFE\n".utf8)
        let session = makeSession(restored: preamble)
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        XCTAssertTrue(session.hasRestoredScrollbackForTesting, "precondition: the preamble is held pre-enqueue")

        session.enqueueRestoredScrollbackForTesting()
        XCTAssertFalse(
            session.hasRestoredScrollbackForTesting,
            "the stored preamble must be nil'd after the FIFO enqueue — the session-lifetime "
                + "copy pinned up to the journal cap of memory per restored pane",
        )
        // The FIFO copy is intact — the drain would ship exactly the preamble bytes.
        guard case let .output(bytes, _, _)? = session.takeMergedFrame() else {
            XCTFail("the enqueued preamble must be poppable off the FIFO")
            return
        }
        XCTAssertEqual(bytes, preamble)
    }
}
