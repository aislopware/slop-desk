import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Detach/reattach OUTPUT retention + gate rebalance.
///
/// While a session is DETACHED the PTY read loop keeps running and appends chunks to the
/// out-FIFO, but the output drain is cancelled — so those bytes are NEVER sequenced into the
/// ReplayBuffer (seq assignment happens at drain time). `rebindRelay` therefore must NOT clear
/// the out-FIFO (the "bytes already in ReplayBuffer" premise is false for exactly these
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

        /// Snapshot of every decoded message, in send order (control-channel assertions).
        var allMessages: [WireMessage] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    /// A lock-guarded one-shot recording box (the control-wake ordering probe's landing spot).
    private final class ObservedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func set(_ value: Bool) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return stored
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
    /// the restarted drain ships it, which is exactly the rebalance the sibling tests pin.
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

    // MARK: - Control wake must be installed before the output drain runs

    /// The restarted output drain's first act on a detached backlog is `takeMergedFrame()` →
    /// `enqueueControl(sniffed control)`. `detach()` nil'd `controlWakeContinuation`, so if the
    /// drain is created + kicked BEFORE the new control wake is installed, a control message
    /// sniffed from the detached backlog (e.g. an OSC-0/2 title change while away) can land in
    /// `controlOut` with NO wake — and `.title` is not re-asserted by any reestablish call, so a
    /// quiet reconnect never flushes it (title lost until the next live title edge).
    ///
    /// The race window itself (the drain Task getting scheduled inside the few rebind-thread
    /// instructions between the backlog kick and the wake install) cannot be forced
    /// deterministically from outside — the drain is an unstructured Task and the test has no way
    /// to pause the rebind thread mid-method. So this pins the ORDER structurally via the
    /// `onOutputDrainRestartedForTesting` seam: at the earliest instant the drain can be running,
    /// the control wake must ALREADY be installed.
    func testRebindInstallsControlWakeBeforeOutputDrainIsKicked() {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        // A detached-era chunk whose sniffed control (a title change while away) rides the
        // backlog — exactly what the restarted drain hands to enqueueControl.
        session.enqueueChunkForTesting(
            bytes: Data("away\n".utf8), control: [.title("away-title")],
        )

        let observed = ObservedBox()
        session.onOutputDrainRestartedForTesting = { [weak session] in
            observed.set(session?.hasControlWakeContinuationForTesting ?? false)
        }
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
        session.onOutputDrainRestartedForTesting = nil
        XCTAssertEqual(
            observed.value, true,
            "rebindRelay must install the control wake + sender BEFORE creating/kicking the "
                + "output drain — otherwise the drain can enqueueControl onto a nil continuation "
                + "and strand a detached-window title in controlOut with no wake",
        )
    }

    /// End-to-end companion: the sniffed control riding a detached-backlog chunk must actually be
    /// DELIVERED on the returning client's new control sub-channel (the user-visible contract the
    /// ordering test above protects).
    func testDetachedBacklogSniffedControlIsDeliveredAfterReattach() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(
            bytes: Data("away\n".utf8), control: [.title("away-title")],
        )

        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, frame in
            recorder.record(frame)
        }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))

        await waitUntil { recorder.allMessages.contains(.title("away-title")) }
        XCTAssertTrue(
            recorder.allMessages.contains(.title("away-title")),
            "the detached-window title sniffed off the backlog must reach the new control channel",
        )
    }

    // MARK: - Cold-client backlog transform (reconnect-while-Claude-runs hygiene)

    /// COLD reattach (`transformDetachedBacklog: true` — the client presented seq 0, a fresh
    /// surface): the detached-window backlog must ship TRANSFORMED (it is history to a terminal
    /// that has rendered nothing — raw live-TUI churn would replay for seconds and render wrong
    /// at the new geometry), and the gate accounting must rebalance by the shrink delta so the
    /// books still reach zero once the drain ships the smaller backlog.
    func testColdReattachTransformsDetachedBacklog() async {
        let dropDashes: @Sendable (Data) -> Data = { Data($0.filter { $0 != UInt8(ascii: "-") }) }
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            replay: ReplayBuffer(scrollbackBytes: 4096, scrollbackDistiller: dropDashes),
        )
        let gate = PausableQueueGate(capacity: 1_000_000) { _ in }
        session.installGateForTesting(gate)
        session.detach(onDetachedExit: { _ in })

        session.enqueueChunkForTesting(bytes: Data("churn--1\n".utf8))
        session.enqueueChunkForTesting(bytes: Data("churn--2\n".utf8))
        XCTAssertEqual(gate.outstanding, 18, "precondition: raw backlog accounted")

        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(
            data: newData, control: newControl, onExit: nil, transformDetachedBacklog: true,
        ))

        let expected = Data("churn1\nchurn2\n".utf8)
        await waitUntil { recorder.outputBytes == expected && gate.outstanding == 0 }
        XCTAssertEqual(recorder.outputBytes, expected, "cold backlog ships transformed")
        XCTAssertEqual(
            gate.outstanding, 0,
            "compaction dequeues the shrink delta and the drain dequeues the rest — no leaked bytes",
        )
    }

    /// WARM reattach (default `transformDetachedBacklog: false`): the backlog ships RAW —
    /// the client's live grid needs byte-exact continuation.
    func testWarmReattachKeepsRawDetachedBacklog() async {
        let dropDashes: @Sendable (Data) -> Data = { Data($0.filter { $0 != UInt8(ascii: "-") }) }
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            replay: ReplayBuffer(scrollbackBytes: 4096, scrollbackDistiller: dropDashes),
        )
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("raw--bytes\n".utf8))

        let recorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))

        let expected = Data("raw--bytes\n".utf8)
        await waitUntil { recorder.outputBytes == expected }
        XCTAssertEqual(recorder.outputBytes, expected, "warm backlog stays byte-exact")
    }

    // MARK: - rebindRelay must NOT register a second PTY exit waiter

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
