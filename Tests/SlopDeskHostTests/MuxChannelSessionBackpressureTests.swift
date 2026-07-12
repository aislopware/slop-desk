import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Integration test for the ReplayBuffer → read-loop-pause WIRING. The 64 MiB retained-byte cap + 4 MiB
/// offline gate are useless unless `MuxChannelSession` actually consults `shouldPauseDrain` after
/// `append`/`ack`ing the buffer — otherwise a wire-consuming-but-not-acking client grows host RAM
/// unbounded. This proves the relay feeds that signal into the output gate.
///
/// Driven WITHOUT a PTY or read loop: `MuxChannelSession` is built with an UNSPAWNED ``PTYProcess``
/// (never read — `startRelay()` is not called) and a TINY-cap ``ReplayBuffer``, and the real
/// `nextSeq`/`acknowledge`/`setClientOnline` glue is driven through internal test seams against a
/// recording ``PausableQueueGate``.
final class MuxChannelSessionBackpressureTests: XCTestCase {
    private final class PauseRec: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var current = false
        func apply(_ p: Bool) { lock.lock()
            current = p
            lock.unlock()
        }

        var isPaused: Bool { lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    private func makeSession(replay: ReplayBuffer) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned (masterFD == -1) — never touched; relay is not started
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            replay: replay,
        )
    }

    /// Online slow-consumer: appending past the retained-byte cap PAUSES the read loop (cap enforced,
    /// not dead code); an ack that releases the backlog RESUMES it.
    func testAppendPastCapPausesReadLoopAndAckResumes() {
        let rec = PauseRec()
        let session = makeSession(replay: ReplayBuffer(maxBackupBytes: 100, offlineGateBytes: 40))
        // Queue cap huge so ONLY the replay source can drive the pause here.
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { rec.apply($0) })

        let s1 = session.appendForTesting(Data(count: 60)) // retained 60 < 100 → run
        XCTAssertFalse(rec.isPaused, "under the cap → read loop runs")
        session.appendForTesting(Data(count: 60)) // retained 120 ≥ 100 → pause
        XCTAssertTrue(rec.isPaused, "retained past the 64 MiB-equivalent cap → read loop PAUSED (cap enforced)")
        session.ackForTesting(upTo: s1) // release the first 60 → retained 60 < 100
        XCTAssertFalse(rec.isPaused, "ack released enough of the backlog → resume")
    }

    /// The offline gate engages when the client is marked offline (the data channel ended).
    func testOfflineGateEngagesWhenClientGoesOffline() {
        let rec = PauseRec()
        let session = makeSession(replay: ReplayBuffer(maxBackupBytes: 1_000_000, offlineGateBytes: 50))
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { rec.apply($0) })

        session.appendForTesting(Data(count: 60)) // retained 60 ≥ offlineGate(50) but ONLINE → no pause
        XCTAssertFalse(rec.isPaused, "online: the offline gate does not apply")
        session.setClientOnlineForTesting(false) // client unreachable → offline gate engages
        XCTAssertTrue(rec.isPaused, "offline + retained(60) ≥ offlineGate(50) → pause")
        session.setClientOnlineForTesting(true) // back online, retained < the 1 MB cap → resume
        XCTAssertFalse(rec.isPaused, "back online under the cap → resume")
    }

    // MARK: - Exit-ordering EOF latch

    /// Once EOF is signalled (read loop drained the master), the exit gate returns IMMEDIATELY — so
    /// `.exit` is yielded right after the final tail, with no spurious delay on the common path.
    func testExitGateReturnsImmediatelyAfterEOFSignal() async {
        let session = makeSession(replay: ReplayBuffer())
        session.signalEOFForTesting()
        XCTAssertTrue(session.isEOFReachedForTesting())
        let start = ContinuousClock.now
        await session.awaitEOFForTesting(timeout: .seconds(5))
        XCTAssertLessThan(
            start.duration(to: ContinuousClock.now),
            .milliseconds(150),
            "EOF already reached → the exit gate returns immediately (no spurious exit delay)",
        )
    }

    /// If EOF is NEVER reached (a wedged / permanently-paused read), the gate releases at the bounded
    /// timeout so exit delivery can never hang forever.
    func testExitGateTimesOutWhenEOFNeverReached() async {
        let session = makeSession(replay: ReplayBuffer())
        XCTAssertFalse(session.isEOFReachedForTesting())
        let start = ContinuousClock.now
        await session.awaitEOFForTesting(timeout: .milliseconds(120))
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(100),
            "without EOF the gate waits up to the timeout (the safety valve)",
        )
        XCTAssertLessThan(elapsed, .seconds(2), "but it does release at the bounded timeout, not hang")
    }

    /// An EOF signal arriving WHILE the gate is waiting releases it shortly after (the normal race: the
    /// reaper resolves `waitForExit` first, then the read loop drains the tail and signals EOF).
    func testExitGateReleasesWhenEOFArrivesDuringWait() async {
        let session = makeSession(replay: ReplayBuffer())
        let waitTask = Task { await session.awaitEOFForTesting(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        session.signalEOFForTesting() // the tail finished draining → EOF
        await waitTask.value
        XCTAssertLessThan(
            start.duration(to: ContinuousClock.now),
            .milliseconds(200),
            "the gate releases shortly after EOF is signalled mid-wait",
        )
    }

    // MARK: - Exit-sent latch

    /// Once the drain signals `.exit` was SENT on the wire, the exit task's gate returns IMMEDIATELY so
    /// onExit (→ teardown) fires right after — no spurious delay on the common path.
    func testExitSentGateReturnsImmediatelyAfterSignal() async {
        let session = makeSession(replay: ReplayBuffer())
        session.signalExitSentForTesting()
        XCTAssertTrue(session.isExitSentForTesting())
        let start = ContinuousClock.now
        await session.awaitExitSentForTesting(timeout: .seconds(5))
        XCTAssertLessThan(
            start.duration(to: ContinuousClock.now),
            .milliseconds(150),
            "exit already sent → the gate returns immediately",
        )
    }

    /// If `.exit` is NEVER sent (a dead client whose credit never arrives), the gate releases at the
    /// bounded timeout so teardown can never hang forever waiting to deliver an undeliverable code.
    func testExitSentGateTimesOutWhenNeverSent() async {
        let session = makeSession(replay: ReplayBuffer())
        XCTAssertFalse(session.isExitSentForTesting())
        let start = ContinuousClock.now
        await session.awaitExitSentForTesting(timeout: .milliseconds(120))
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100), "without an exit-sent signal it waits the timeout")
        XCTAssertLessThan(elapsed, .seconds(2), "but releases at the bounded timeout, not hang")
    }

    /// An exit-sent signal arriving WHILE the exit task is gated releases it shortly after (the normal
    /// race: the drain finishes sending `.exit`, THEN the gate wakes and onExit fires).
    func testExitSentGateReleasesWhenSignalArrivesDuringWait() async {
        let session = makeSession(replay: ReplayBuffer())
        let waitTask = Task { await session.awaitExitSentForTesting(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        session.signalExitSentForTesting()
        await waitTask.value
        XCTAssertLessThan(
            start.duration(to: ContinuousClock.now),
            .milliseconds(200),
            "the gate releases shortly after exit-sent is signalled mid-wait",
        )
    }

    // MARK: - ZDOTDIR shim-dir cleanup

    /// `shutdown()` deletes the per-session ZDOTDIR shim dir once the child has exited — without this the
    /// host's temp dir accumulated one `slopdesk-zdotdir-*` dir + 4 files per opened pane forever. Driven
    /// with an UNSPAWNED PTY (terminate/forceTerminate guard `pid > 0`, closeMaster guards `fd >= 0`, so
    /// the PTY teardown is a safe no-op) + a real temp dir standing in for the shim.
    func testShutdownDeletesTheShimDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "slopdesk-zdotdir-\(UUID().uuidString)",
            isDirectory: true,
        )
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "shim".write(to: dir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "precondition: the shim dir exists")

        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — the PTY teardown in shutdown() is a guarded no-op
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            shimDir: dir,
        )
        session.shutdown()
        XCTAssertFalse(
            fm.fileExists(atPath: dir.path),
            "shutdown() removes the per-session ZDOTDIR shim dir (no temp-dir leak per pane)",
        )
    }
}
