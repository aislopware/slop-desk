import SlopDeskProtocol
import SlopDeskScreen
import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// Snapshot (state-transfer) replay at the SESSION level — the reattach path that renders the
/// screen model once instead of replaying byte history (docs/DECISIONS.md 2026-07-25).
///
/// Driven WITHOUT a PTY or `startRelay()` (hang-safety): sequenced history enters via
/// `appendForTesting` (the real `nextSeq` glue), frames the drain has not shipped yet via
/// `enqueueChunkForTesting`, and `replayTail` sends into recording sub-channels.
///
/// The compose walks SEQUENCED history only. A detached pane's output is not hostd's to hold:
/// it lives in superd's ring, and the rebind re-subscribes at the recorded byte offset (see
/// `docs/DECISIONS.md` 2026-08-25).
final class MuxChannelSessionSnapshotReplayTests: XCTestCase {
    /// The composer under test IS `slopdesk-screend`, and so is the oracle these tests read the
    /// result with. Skips by name when the engine is not built rather than passing vacuously.
    override func setUpWithError() throws {
        try ScreendFixture.requireDaemon()
    }

    /// What a fresh terminal shows after `bytes`. The oracle used to be a Swift `TerminalScreenModel`
    /// standing beside the composer; there is one screen engine now, and asking it is the point.
    private func screen(_ bytes: Data, rows: Int = 24, cols: Int = 80) throws -> ScreenSnapshot {
        try ScreenClient.shared.snapshot(raw: bytes, rows: rows, cols: cols)
    }

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
            pty: unattachedPTY(), // unspawned — currentWindowSize() is nil, composer uses 24×80
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
    /// covered (ack-release), and reproduces the terminal's final visible state.
    func testColdReattachComposesSnapshotFromSequencedHistory() async throws {
        let session = makeSession()
        session.installGateForTesting(PausableQueueGate(capacity: 1_000_000) { _ in })
        session.appendForTesting(Data("hello\r\n".utf8)) // seq 1
        session.appendForTesting(Data("world".utf8)) // seq 2
        session.detach(onDetachedExit: { _ in })

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

        // Feeding it to a fresh terminal reproduces the final state.
        let snap = try screen(bytes)
        XCTAssertEqual(snap.lines[0], "hello")
        XCTAssertEqual(snap.lines[1], "world")
        XCTAssertEqual(snap.cursorRow, 1)
        XCTAssertEqual(snap.cursorCol, 5)
    }

    /// A frame the drain never shipped carries no seq yet, so the snapshot cannot contain it:
    /// it must reach the client EXACTLY ONCE, from the restarted drain, after the snapshot.
    /// (Double-print is the failure this pins — it was live while the compose consumed the FIFO.)
    func testUnsentFrameShipsOnceAfterTheSnapshot() async {
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
        // Wait for the restarted drain to ship it, then give a duplicate room to arrive.
        await waitUntil { String(bytes: recorder.outputBytes, encoding: .utf8)?.contains("backlog-marker") == true }
        try? await Task.sleep(for: .milliseconds(150))

        let text = String(bytes: recorder.outputBytes, encoding: .utf8) ?? ""
        XCTAssertEqual(
            text.components(separatedBy: "backlog-marker").count - 1, 1,
            "the unsent frame reaches the client exactly once, from the drain",
        )
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
            pty: unattachedPTY(),
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            snapshotReplay: MuxChannelSession.SnapshotReplayPolicy(
                compose: { raw, rows, cols in spy.compose(raw, rows: rows, cols: cols) },
                warmThresholdBytes: 4 * 1024 * 1024,
            ),
        )
    }

    // MARK: History canonicalization (adopt)

    /// The adoption pin: the cold compose REPLACES the retained history with the rendered
    /// stream ("as if the host had emitted it all along"), so a SECOND cold reattach (the
    /// first client died before acking) reproduces the same screen while walking the small
    /// canonical render instead of re-parsing the raw churn.
    func testSecondColdSnapshotWalksTheAdoptedHistory() async throws {
        let spy = ComposeSpy()
        let session = makeSpySession(spy)
        // ~24 KiB of CR-overprint churn: one visible line, thousands of retained seqs.
        for tick in 0..<2000 { session.appendForTesting(Data("\rtick \(tick)".utf8)) }

        let first = SendRecorder()
        let firstComposed = await session.replayTail(after: 0, on: recordingChannel(first))
        XCTAssertTrue(firstComposed)

        let second = SendRecorder()
        let secondComposed = await session.replayTail(after: 0, on: recordingChannel(second))
        XCTAssertTrue(secondComposed)
        XCTAssertEqual(try screen(second.outputBytes).lines[0], "tick 1999", "adopted state stays correct")

        // The second compose walked the ADOPTED canonical history, not the raw one —
        // its input is exactly the stream the first compose delivered, and far smaller.
        XCTAssertEqual(spy.inputs.count, 2)
        XCTAssertEqual(spy.inputs[1], first.outputBytes, "compose #2 input = adopted stream")
        XCTAssertLessThan(spy.inputs[1].count, spy.inputs[0].count, "adoption shrinks the history")
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
    func testWarmReconnectOverThresholdSnapshotsFullHistory() async throws {
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
        let snap = try screen(recorder.outputBytes)
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
