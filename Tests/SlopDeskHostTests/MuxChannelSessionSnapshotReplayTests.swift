import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Snapshot (state-transfer) replay at the SESSION level — the reattach path that renders the
/// screen model once instead of replaying byte history (docs/DECISIONS.md 2026-07-25).
///
/// Driven WITHOUT a PTY or `startRelay()` (hang-safety): sequenced history enters via
/// `appendForTesting` (the real `nextSeq` glue), the detached-window backlog via
/// `enqueueChunkForTesting`, and `replayTail` sends into recording sub-channels.
final class MuxChannelSessionSnapshotReplayTests: XCTestCase {
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

        var outputMessages: [(seq: Int64, bytes: Data)] {
            lock.lock()
            defer { lock.unlock() }
            return messages.compactMap {
                if case let .output(seq, bytes) = $0 { return (seq, bytes) }
                return nil
            }
        }

        var outputBytes: Data {
            var joined = Data()
            for message in outputMessages { joined.append(message.bytes) }
            return joined
        }
    }

    private func makeSession(
        warmThresholdBytes: Int = 4 * 1024 * 1024,
        snapshot: Bool = true,
    ) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — currentWindowSize() is nil, composer uses 24×80
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            snapshotReplay: snapshot
                ? MuxChannelSession.SnapshotReplayPolicy(
                    compose: { raw, rows, cols in
                        TerminalReplaySnapshot.compose(raw: raw, rows: rows, cols: cols)
                    },
                    warmThresholdBytes: warmThresholdBytes,
                )
                : nil,
        )
    }

    private func recordingChannel(_ recorder: SendRecorder) -> MuxSubChannel {
        MuxSubChannel(channelID: 1, channel: .data) { _, frame in recorder.record(frame) }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Cold reattach

    /// A cold reattach with the policy injected replays a RENDERED snapshot: the recorded
    /// stream is a render (reset preamble first), rides the retained seqs with the LAST seq
    /// covered (ack-release), and reproduces the terminal's final visible state — including
    /// the detached-window FIFO backlog, which is consumed INTO the snapshot.
    func testColdReattachComposesSnapshotIncludingDetachedBacklog() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.appendForTesting(Data("hello\r\n".utf8)) // seq 1
        session.appendForTesting(Data("world".utf8)) // seq 2
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("-away".utf8))

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 0, on: recordingChannel(recorder))
        XCTAssertTrue(composed, "cold reattach with a policy must snapshot")

        let outputs = recorder.outputMessages
        XCTAssertFalse(outputs.isEmpty)
        XCTAssertEqual(outputs.last?.seq, 2, "the LAST retained seq must be covered (ack-release)")
        XCTAssertEqual(outputs.map(\.seq), outputs.map(\.seq).sorted(), "seqs ascending")

        // The stream is a RENDER, not the raw history: it starts with the reset preamble.
        let bytes = recorder.outputBytes
        XCTAssertTrue(bytes.starts(with: Data("\u{1B}[?1049l".utf8)))

        // Feeding it to a fresh terminal reproduces the final state — backlog included.
        var terminal = TerminalScreenModel(rows: 24, cols: 80)
        terminal.feed(bytes)
        let snap = terminal.snapshot()
        XCTAssertEqual(snap.lines[0], "hello")
        XCTAssertEqual(snap.lines[1], "world-away")
        XCTAssertEqual(snap.cursorRow, 1)
        XCTAssertEqual(snap.cursorCol, 10)
    }

    /// The consumed backlog must NOT be shipped again by the restarted drain — its bytes are
    /// inside the snapshot, and a re-send would double-print.
    func testConsumedBacklogIsNotReshippedByRestartedDrain() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.appendForTesting(Data("prompt$ ".utf8)) // seq 1
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("backlog-marker".utf8))

        let recorder = SendRecorder()
        let newData = recordingChannel(recorder)
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        let composed = await session.replayTail(after: 0, on: newData)
        XCTAssertTrue(composed)
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
        // Give the restarted drain a chance to (wrongly) ship the consumed backlog.
        try? await Task.sleep(for: .milliseconds(150))

        let text = String(bytes: recorder.outputBytes, encoding: .utf8) ?? ""
        XCTAssertEqual(
            text.components(separatedBy: "backlog-marker").count - 1, 1,
            "the backlog renders exactly once (inside the snapshot)",
        )
        session.shutdown()
    }

    /// Consuming the backlog must release its queue-gate accounting (the compactor's
    /// rebalance contract) — a leaked residue would leave the read loop paused forever.
    ///
    /// Uses a STUB composer (1-byte render): the recording sub-channel grants no credit, so a
    /// realistically-sized rendered stream would park `send` on the credit window — and the
    /// accounting under test is the CONSUME side, not the render.
    func testConsumedBacklogReleasesGateAccounting() async {
        let session = MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            snapshotReplay: MuxChannelSession.SnapshotReplayPolicy(
                compose: { _, _, _ in Data("S".utf8) },
                warmThresholdBytes: 0,
            ),
        )
        final class PauseRec: @unchecked Sendable {
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
        let rec = PauseRec()
        // `detach()` raises the gate to the detached budget and `rebindRelay` restores the
        // 64 KiB attached bound — so a >64 KiB backlog whose accounting LEAKED (consumed
        // without a dequeue) would leave the gate paused forever after the rebind, with
        // nothing left in the FIFO to ship and rebalance it.
        session.installGateForTesting(PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) {
            rec.apply($0)
        })
        // Several retained seqs so the ~100 KiB rendered stream fits the per-seq frame-cap
        // budget (one lone seq would trip the credit-invariant guard and fall back).
        for _ in 0..<8 { session.appendForTesting(Data("x".utf8)) }
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data(repeating: UInt8(ascii: "b"), count: 100 * 1024))

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 0, on: recordingChannel(recorder))
        XCTAssertTrue(composed)
        let newData = recordingChannel(SendRecorder())
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(rec.isPaused, "consuming the backlog must dequeue its gate accounting")
        session.shutdown()
    }

    /// Records every input the composer is fed — the adopted-history observability seam.
    private final class ComposeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Data] = []

        func compose(_ raw: Data, rows: Int, cols: Int) -> Data {
            lock.lock()
            recorded.append(raw)
            lock.unlock()
            return TerminalReplaySnapshot.compose(raw: raw, rows: rows, cols: cols)
        }

        var inputs: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private func makeSpySession(_ spy: ComposeSpy) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            snapshotReplay: MuxChannelSession.SnapshotReplayPolicy(
                compose: { raw, rows, cols in spy.compose(raw, rows: rows, cols: cols) },
                warmThresholdBytes: 4 * 1024 * 1024,
            ),
        )
    }

    // MARK: History canonicalization (adopt + detach-time fold)

    /// The backlog-hole pin: the consumed detached-window backlog got no seqs of its own, so
    /// unless the compose ADOPTS the rendered stream as the retained history, a SECOND cold
    /// reattach (the first client died before acking) replays a history the backlog has
    /// vanished from.
    func testDetachedBacklogSurvivesIntoSecondColdSnapshot() async {
        let spy = ComposeSpy()
        let session = makeSpySession(spy)
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.appendForTesting(Data("hello\r\n".utf8)) // seq 1
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("away-output".utf8))

        let first = SendRecorder()
        let firstComposed = await session.replayTail(after: 0, on: recordingChannel(first))
        XCTAssertTrue(firstComposed)

        let second = SendRecorder()
        let secondComposed = await session.replayTail(after: 0, on: recordingChannel(second))
        XCTAssertTrue(secondComposed)
        var terminal = TerminalScreenModel(rows: 24, cols: 80)
        terminal.feed(second.outputBytes)
        let snap = terminal.snapshot()
        XCTAssertEqual(snap.lines[0], "hello")
        XCTAssertEqual(snap.lines[1], "away-output", "the consumed backlog must survive adoption")

        // And the second compose walked the ADOPTED canonical history, not the raw one —
        // its input is exactly the stream the first compose delivered.
        XCTAssertEqual(spy.inputs.count, 2)
        XCTAssertEqual(spy.inputs[1], first.outputBytes, "compose #2 input = adopted stream")
    }

    /// Detaching folds the acked ring in the background: the eventual reattach compose walks
    /// the small canonical render instead of the raw churn (the "reattach stalls for seconds
    /// re-parsing 64 MiB of build output" fix).
    func testDetachFoldsRingSoReattachComposeIsSmall() async {
        let spy = ComposeSpy()
        let session = makeSpySession(spy)
        session.installGateForTesting(PausableQueueGate(capacity: 100 * 1024 * 1024) { _ in })
        // ~240 KiB of CR-overprint churn (over the 128 KiB fold floor), fully acked → ring.
        var seq: Int64 = 0
        for tick in 0..<20000 {
            session.appendForTesting(Data("\rtick \(tick)".utf8))
            seq += 1
        }
        session.ackForTesting(upTo: seq)
        let rawRingBytes = session.scrollbackRingBytesForTesting()
        session.detach(onDetachedExit: { _ in })

        // The fold splices asynchronously — wait for the ring to actually SHRINK (the spy
        // recording its input only proves the render started).
        await waitUntil { session.scrollbackRingBytesForTesting() < rawRingBytes }
        XCTAssertLessThan(session.scrollbackRingBytesForTesting(), rawRingBytes, "fold must land")

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 0, on: recordingChannel(recorder))
        XCTAssertTrue(composed)
        guard let reattachInput = spy.inputs.last else {
            XCTFail("no reattach compose")
            return
        }
        XCTAssertLessThan(
            reattachInput.count, 64 * 1024,
            "reattach compose must walk the folded canonical ring, not ~240 KiB of raw churn",
        )
        var terminal = TerminalScreenModel(rows: 24, cols: 80)
        terminal.feed(recorder.outputBytes)
        XCTAssertEqual(terminal.snapshot().lines[0], "tick 19999", "folded state stays correct")
    }

    // MARK: Warm reconnect

    /// A warm reconnect BELOW the threshold replays the raw tail byte-exact — the live grid's
    /// byte-exact continuation is worth more than a wipe+re-render.
    func testWarmReconnectBelowThresholdReplaysRawTail() async {
        let session = makeSession() // 4 MiB threshold — far above this tail
        session.appendForTesting(Data("acked\r\n".utf8)) // seq 1
        session.ackForTesting(upTo: 1)
        session.appendForTesting(Data("unacked-tail".utf8)) // seq 2

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 1, on: recordingChannel(recorder))
        XCTAssertFalse(composed)
        let outputs = recorder.outputMessages
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].seq, 2)
        XCTAssertEqual(outputs[0].bytes, Data("unacked-tail".utf8), "warm tail is byte-exact")
    }

    /// A warm reconnect AT/ABOVE the threshold snapshots instead: the rendered preamble wipes
    /// the stale grid and the FULL history (acked ring included) re-renders, riding only the
    /// un-replayed seqs.
    func testWarmReconnectOverThresholdSnapshotsFullHistory() async {
        let session = makeSession(warmThresholdBytes: 1)
        session.appendForTesting(Data("ring-line\r\n".utf8)) // seq 1 → ring after ack
        session.ackForTesting(upTo: 1)
        session.appendForTesting(Data("tail-line".utf8)) // seq 2

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 1, on: recordingChannel(recorder))
        XCTAssertTrue(composed)
        let outputs = recorder.outputMessages
        XCTAssertEqual(outputs.map(\.seq).last, 2)
        XCTAssertTrue(outputs.allSatisfy { $0.seq > 1 }, "rides only seqs above lastReceivedSeq")
        var terminal = TerminalScreenModel(rows: 24, cols: 80)
        terminal.feed(recorder.outputBytes)
        let snap = terminal.snapshot()
        XCTAssertEqual(snap.lines[0], "ring-line", "acked history re-renders after the wipe")
        XCTAssertEqual(snap.lines[1], "tail-line")
    }

    // MARK: Fallbacks

    /// No retained seqs (a backlog-only detached window) → nothing to ride the snapshot on:
    /// fall back, leave the backlog for the restarted drain (existing delivery path).
    func testBacklogOnlySessionFallsBackAndPreservesBacklog() async {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.detach(onDetachedExit: { _ in })
        session.enqueueChunkForTesting(bytes: Data("only-backlog".utf8))

        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 0, on: recordingChannel(recorder))
        XCTAssertFalse(composed)
        XCTAssertTrue(recorder.outputMessages.isEmpty, "nothing retained to replay")

        // The backlog still ships via the restarted drain.
        let drainRecorder = SendRecorder()
        let newData = MuxSubChannel(channelID: 1, channel: .data) { _, frame in drainRecorder.record(frame) }
        let newControl = MuxSubChannel(channelID: 1, channel: .control) { _, _ in }
        XCTAssertTrue(session.rebindRelay(data: newData, control: newControl, onExit: nil))
        await waitUntil { drainRecorder.outputBytes.count >= "only-backlog".utf8.count }
        XCTAssertEqual(String(bytes: drainRecorder.outputBytes, encoding: .utf8), "only-backlog")
        session.shutdown()
    }

    /// Policy nil (SLOPDESK_SCROLLBACK_SNAPSHOT=0) → byte-identical to the old path.
    func testDisabledPolicyReplaysExactlyAsBefore() async {
        let session = makeSession(snapshot: false)
        session.appendForTesting(Data("raw-history".utf8))
        let recorder = SendRecorder()
        let composed = await session.replayTail(after: 0, on: recordingChannel(recorder))
        XCTAssertFalse(composed)
        XCTAssertEqual(recorder.outputBytes, Data("raw-history".utf8))
    }

    /// The env factory: default-ON, `"0"` disables, threshold override parses.
    func testMakeSnapshotReplayPolicyEnvGates() {
        XCTAssertNotNil(MuxChannelSession.makeSnapshotReplayPolicy(environment: [:]))
        XCTAssertNil(
            MuxChannelSession.makeSnapshotReplayPolicy(environment: ["SLOPDESK_SCROLLBACK_SNAPSHOT": "0"]),
        )
        let tuned = MuxChannelSession.makeSnapshotReplayPolicy(
            environment: ["SLOPDESK_SNAPSHOT_WARM_BYTES": "123"],
        )
        XCTAssertEqual(tuned?.warmThresholdBytes, 123)
        XCTAssertEqual(
            MuxChannelSession.makeSnapshotReplayPolicy(environment: [:])?.warmThresholdBytes,
            4 * 1024 * 1024,
        )
    }
}
