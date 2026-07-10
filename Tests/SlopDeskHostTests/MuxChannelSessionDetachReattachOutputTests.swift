import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Detach/reattach OUTPUT retention + gate rebalance (post-audit replay-core fixes).
///
/// While a session is DETACHED the PTY read loop keeps running and appends chunks to the
/// out-FIFO, but the output drain is cancelled — so those bytes are NEVER sequenced into the
/// ReplayBuffer (seq assignment happens at drain time). `rebindRelay` therefore must NOT clear
/// the out-FIFO (the old C3 "bytes already in ReplayBuffer" premise was false for exactly these
/// bytes): the restarted drain must ship them on the NEW data sub-channel, and — because every
/// chunk was accounted into the ``PausableQueueGate`` at enqueue time — sending them is also
/// what rebalances the gate so a read loop paused by the detached-era backlog RESUMES.
///
/// Driven WITHOUT a PTY or `startRelay()` (hang-safety): the unspawned ``PTYProcess`` is never
/// read; the detached-era producer is simulated via `enqueueChunkForTesting` (the exact
/// production `onChunk` accounting+append), and `rebindRelay` restarts the REAL drain against
/// recording sub-channels.
///
/// REVERT-TO-FAIL: restoring `outFIFO.removeAll()` (without a matching gate dequeue) in
/// `rebindRelay` makes BOTH tests fail — the recorder never sees the detached-era bytes, and
/// the gate stays at full `outstanding` with the read loop paused forever.
final class MuxChannelSessionDetachReattachOutputTests: XCTestCase {
    // MARK: - Helpers

    /// Records every framed byte a sub-channel's `muxSend` writes and decodes them back into
    /// ``WireMessage``s (the inner frames are whole `msg.encode()` outputs; the per-channel
    /// FrameDecoder reassembles across chunk boundaries exactly like the real receiver).
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let decoder = FrameDecoder()
        private var messages: [WireMessage] = []

        func record(_ innerFrame: Data) {
            lock.lock()
            defer { lock.unlock() }
            decoder.append(innerFrame)
            do {
                while let message = try decoder.nextMessage() {
                    messages.append(message)
                }
            } catch {
                // A decode fault would fail the byte-equality asserts below; nothing to do here.
            }
        }

        /// Concatenated payload bytes of every recorded `.output`, in send order.
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

    private final class PauseRec: @unchecked Sendable {
        private let lock = NSLock()
        private var current = false
        func apply(_ paused: Bool) {
            lock.lock()
            current = paused
            lock.unlock()
        }

        var isPaused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; producer driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// Polls `condition` (up to ~5 s) so the restarted drain Task gets scheduled — no wall-clock pin.
    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Bug 1 — detached-era output must survive the reattach

    /// Output produced while detached (accumulated in the out-FIFO, never sequenced into the
    /// ReplayBuffer) must be DELIVERED on the new data sub-channel after `rebindRelay` — the
    /// "lossless reconnect" promise covers exactly the window the user was away.
    func testDetachedWindowOutputIsDeliveredAfterReattach() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })

        session.detach(onDetachedExit: { _ in })

        // The still-running command prints while the client is away: the read loop appends to
        // the FIFO (accounting into the gate), but with the drain cancelled no seq is assigned
        // and nothing enters the ReplayBuffer — replayTail can NOT replay these bytes.
        let away1 = Data("while-you-were-away-1\n".utf8)
        let away2 = Data("while-you-were-away-2\n".utf8)
        session.enqueueChunkForTesting(bytes: away1)
        session.enqueueChunkForTesting(bytes: away2)

        // Reattach: rebind onto fresh sub-channels and record what the drain sends.
        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))

        let expected = away1 + away2
        await waitUntil { recorder.outputBytes == expected }
        XCTAssertEqual(
            recorder.outputBytes, expected,
            "the detached-window output must be shipped to the returning client by the restarted drain "
                + "(it was never in the ReplayBuffer, so clearing the FIFO would drop it permanently)",
        )
    }

    // MARK: - Bug 2 — gate accounting must rebalance so the pane never freezes

    /// A busy detached window fills the bounded-queue gate and pauses the read loop. After
    /// reattach the drain must send the backlog AND dequeue its gate accounting — `outstanding`
    /// returns to 0 and the loop resumes. (The old `outFIFO.removeAll()` dropped the bytes
    /// WITHOUT any gate dequeue, leaving `outstanding ≥ capacity` forever: the read loop stayed
    /// paused and the pane went permanently silent.)
    func testReattachRebalancesGateAndResumesPausedReadLoop() async {
        let rec = PauseRec()
        let session = makeSession()
        // Tiny capacity so the detached-era backlog crosses the bound (production: 64 KiB).
        let gate = PausableQueueGate(capacity: 32) { rec.apply($0) }
        session.installGateForTesting(gate)

        session.detach(onDetachedExit: { _ in })

        session.enqueueChunkForTesting(bytes: Data(repeating: 0x61, count: 40))
        // (Since the detached-budget re-sizing, the 40-byte backlog no longer pauses the loop —
        // detach() raised the bound. The leak this test guards against is now caught by the
        // `gate.outstanding == 0` assert below: the old bug cleared the FIFO WITHOUT dequeuing
        // its accounting, stranding `outstanding` forever.)
        XCTAssertEqual(gate.outstanding, 40, "precondition: the backlog is accounted in the gate")

        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))

        await waitUntil { gate.outstanding == 0 && !rec.isPaused }
        XCTAssertEqual(
            gate.outstanding, 0,
            "the drain must dequeue the backlog's gate accounting as it sends — no leaked bytes",
        )
        XCTAssertFalse(
            rec.isPaused,
            "the read loop must RESUME after reattach (a leaked full gate froze the pane forever)",
        )
    }

    // MARK: - Detached queue budget (loosened caps: agent keeps running while away)

    /// detach() re-sizes the gate from the attached LATENCY bound to the detached "output
    /// while away" budget: a burst far past the attached bound must NOT pause the read loop
    /// while detached (the old behaviour stalled a still-working agent at 64 KiB + one kernel
    /// buffer). rebindRelay restores the attached bound — the backlog re-pauses the loop until
    /// the restarted drain ships it, which is exactly the C3 rebalance the sibling tests pin.
    func testDetachRaisesQueueBudgetSoAwayOutputDoesNotStallAgent() async {
        let rec = PauseRec()
        let session = makeSession()
        let gate = PausableQueueGate(capacity: 64 * 1024) { rec.apply($0) } // attached sizing
        session.installGateForTesting(gate)

        session.detach(onDetachedExit: { _ in })
        // 1 MiB of while-away output — 16× the attached bound.
        for _ in 0..<16 {
            session.enqueueChunkForTesting(bytes: Data(repeating: 0x61, count: 64 * 1024))
        }
        XCTAssertFalse(
            rec.isPaused,
            "detached output within the detached budget must never pause the read loop (agent stall)",
        )

        // Reattach: the attached bound returns; the >64 KiB backlog re-pauses the loop, the
        // restarted drain ships it and the gate rebalances (loop resumes).
        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        // The recording channel has no real peer granting window updates — top up the send
        // window so the whole 1 MiB backlog (+ frame overhead) can ship without suspending.
        await newData.grantCredit(4 * 1024 * 1024)
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
        await waitUntil { recorder.outputBytes.count == 16 * 64 * 1024 && !rec.isPaused }
        XCTAssertEqual(recorder.outputBytes.count, 16 * 64 * 1024, "the whole away-backlog ships on reattach")
        XCTAssertFalse(rec.isPaused, "gate rebalances back below the restored attached bound")
    }

    // MARK: - Audit #3 — rebindRelay must NOT register a second PTY exit waiter

    /// `PTYProcess.waitForExit()` parks a plain CheckedContinuation with NO cancellation
    /// plumbing: cancelling the task that awaits it never retires the registration. The old
    /// rebindRelay cancelled+recreated the exit task on every reattach-while-alive, so each
    /// cycle added one more parked waiter — when the child finally exited, `completeExit`
    /// resumed ALL of them and the pane sent a duplicate `.exit` wire frame per cycle.
    ///
    /// The fix: the ONE exit task from `startRelay()` is the only waiter, ever (it reads
    /// `onExit` at fire time, so rebinding the handler is enough). On a session that never
    /// ran `startRelay()` (these hang-safe tests), `exitTask` is nil and must STAY nil
    /// across any number of detach/rebind cycles — under the old code the first rebind
    /// created one, which is exactly the double-registration this pins against.
    func testRebindRelayNeverCreatesAnExitWaiter() {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        XCTAssertFalse(session.hasExitTaskForTesting, "precondition: no startRelay → no exit task")

        for cycle in 1...3 {
            session.detach(onDetachedExit: { _ in })
            let newData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
            let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
            XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
            XCTAssertFalse(
                session.hasExitTaskForTesting,
                "rebind cycle \(cycle): rebindRelay must not mint an exit waiter — "
                    + "only startRelay() ever does (duplicate .exit frame regression)",
            )
        }
    }
}
