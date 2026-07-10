import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Disk scrollback journal: the transcript must survive the DAEMON (hostd restart / reboot /
/// TTL eviction all end in `spawnFreshShell`, which used to start an empty transcript — the
/// "reconnect lại thì bị mất history" loss case).
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
        let store = makeStore()
        let fm = FileManager.default

        // Three journals: one ancient, two fresh.
        let ancient = UUID(), fresh1 = UUID(), fresh2 = UUID()
        for id in [ancient, fresh1, fresh2] {
            store.journal(for: id).append(Data("x".utf8))
            store.journal(for: id).synchronize()
        }
        let ancientURL = tempDir.appendingPathComponent("\(ancient.uuidString).scrollback")
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 3600)], ofItemAtPath: ancientURL.path,
        )

        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 256)
        XCTAssertFalse(fm.fileExists(atPath: ancientURL.path), "past-maxAge journal must be swept")
        XCTAssertNotNil(store.restoredScrollback(for: fresh1))

        store.sweep(maxAge: 14 * 24 * 3600, keepNewest: 1)
        let survivors = try fm.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".scrollback") }
        XCTAssertEqual(survivors.count, 1, "keepNewest must bound the file count")
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
        session.rebindRelay(data: newData, control: newControl, onExit: nil)

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
}
