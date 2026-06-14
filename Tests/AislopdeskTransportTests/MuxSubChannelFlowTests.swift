import AislopdeskProtocol
import XCTest
@testable import AislopdeskTransport

/// S2 per-channel flow-control tests for ``MuxSubChannel`` in isolation (no shared connection, no
/// socket). Proves the consume→suspend / grant→wake decision and the close-while-blocked wakeup —
/// the actor-level seam around the pure ``FlowCreditPolicy`` decider.
final class MuxSubChannelFlowTests: XCTestCase {
    /// Records every framed payload the sub-channel actually wrote out (i.e. that passed the window).
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [Data] = []
        func record(_ d: Data) { lock.lock()
            sent.append(d)
            lock.unlock()
        }

        var count: Int { lock.lock()
            defer { lock.unlock() }
            return sent.count
        }

        /// Total bytes written across all envelopes (chunks for one frame may be several envelopes).
        var totalBytes: Int { lock.lock()
            defer { lock.unlock() }
            return sent.reduce(0) { $0 + $1.count }
        }

        /// Concatenation of every envelope's bytes IN WRITE ORDER — the stream the receiver's
        /// `FrameDecoder` reassembles. Used to prove chunks reassemble to the original frame(s).
        var concatenated: Data { lock.lock()
            defer { lock.unlock() }
            return sent.reduce(into: Data()) { $0.append($1) }
        }
    }

    /// A `.input(N body bytes)` frame is `5 + N` bytes on the wire (4 length prefix + 1 type byte +
    /// N body — see `WireMessage.encode()`). We size the send window to admit EXACTLY the first
    /// frame and leave too little for the second, so the suspend path is hit without pushing 256 KiB.
    func testSendSuspendsWhenWindowExhaustedAndWakesOnGrant() async throws {
        let sink = Sink()
        // First frame: 1 body byte ⇒ 6 wire bytes. Window = 6 ⇒ first frame fits EXACTLY, then 0 left.
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: 6) { _, inner in
            sink.record(inner)
        }
        try await ch.send(WireMessage.input(Data("a".utf8))) // exactly fills the 6-byte window
        XCTAssertEqual(sink.count, 1, "first frame fits the window and is written")

        // The second send should SUSPEND (window now exhausted). Launch it and confirm it does NOT
        // complete on its own within a short grace period.
        let secondDone = expectation(description: "second send completes after grant")
        let sendTask = Task {
            try? await ch.send(WireMessage.input(Data("b".utf8)))
            secondDone.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.count, 1, "the second send must be SUSPENDED (window exhausted), not written")

        // A windowAdjust grant must WAKE the suspended sender so it proceeds.
        await ch.grantCredit(10000)
        await fulfillment(of: [secondDone], timeout: 2)
        XCTAssertEqual(sink.count, 2, "after the grant the suspended frame is written")
        _ = await sendTask.value
    }

    /// Foot-gun #2: a close while a sender is blocked on an exhausted window must WAKE that sender
    /// (it throws) rather than leak a suspended task forever.
    func testCloseWhileBlockedWakesSenderWithThrow() async throws {
        let sink = Sink()
        // 1 body byte ⇒ 6 wire bytes; window = 6 ⇒ first send fits exactly, the next must block.
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: 6) { _, inner in
            sink.record(inner)
        }
        try await ch.send(WireMessage.input(Data("x".utf8))) // exactly fills the 6-byte window

        let threw = expectation(description: "blocked sender throws on close")
        let sendTask = Task {
            do {
                try await ch.send(WireMessage.input(Data("y".utf8)))
                XCTFail("a send blocked on an exhausted window must THROW when the channel closes")
            } catch {
                threw.fulfill()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        await ch.finish() // close while the second send is parked
        await fulfillment(of: [threw], timeout: 2)
        _ = await sendTask.value
    }

    /// With flow OFF (infinite window) a send NEVER blocks — byte-identical to S1.
    func testFlowOffNeverBlocks() async throws {
        let sink = Sink()
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: nil) { _, inner in
            sink.record(inner)
        }
        for _ in 0..<50 { try await ch.send(WireMessage.input(Data(repeating: 0x41, count: 10000))) }
        XCTAssertEqual(sink.count, 50, "flow OFF → every send goes straight through, no blocking")
    }

    /// With flow OFF the WHOLE framed message is ONE envelope (S1: never split). A frame that would
    /// dwarf any S2 window is still a single `.channelData` write off the OFF path.
    func testFlowOffSendsWholeFrameAsOneEnvelope() async throws {
        let sink = Sink()
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: nil) { _, inner in
            sink.record(inner)
        }
        let big = WireMessage.input(Data(repeating: 0x41, count: 500 * 1024)) // ≫ any S2 window
        try await ch.send(big)
        XCTAssertEqual(sink.count, 1, "flow OFF → one envelope per WireMessage, never chunked (S1-identical)")
        XCTAssertEqual(sink.concatenated, big.encode(), "the single envelope is the exact framed bytes")
    }

    // MARK: - FIX #1: an OVERSIZED frame (> the whole window) is chunked, never parks forever

    /// FIX #1 (permanent-deadlock HIGH): a single framed `WireMessage` LARGER than the entire send
    /// window must be CHUNKED across the window — consume `min(remaining, bytesLeft)` per step, emit
    /// that sub-slice as its own envelope, park when the window hits 0, resume on a grant — until the
    /// whole frame is sent. The old all-or-nothing consume could NEVER admit a `> window` frame, so
    /// it parked forever waiting for a grant the receiver only emits after consuming bytes that never
    /// arrive. We seed a TINY window (8 bytes) and send a frame far bigger, granting credit
    /// incrementally from another task, and assert: (a) it completes (no deadlock), (b) it took
    /// MULTIPLE envelopes (the chunking path was exercised), (c) the concatenated chunks reassemble
    /// to the EXACT original frame via a fresh `FrameDecoder` (the receiver's reassembly contract).
    func testOversizedFrameIsChunkedAcrossWindowAndReassembles() async throws {
        let sink = Sink()
        let window = 8
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: window) { _, inner in
            sink.record(inner)
        }
        // 200 body bytes ⇒ 205 wire bytes ≫ the 8-byte window (≈26 chunks), so it MUST chunk + park.
        let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
        let message = WireMessage.input(payload)
        let framed = message.encode()

        let done = expectation(description: "oversized frame fully sent after incremental grants")
        let sendTask = Task {
            try? await ch.send(message)
            done.fulfill()
        }
        // Drive incremental grants until the whole frame is out. Each grant tops the window back up by
        // one window's worth; the sender consumes it as another chunk and re-parks. This models the
        // receiver's half-window replenish without an infinite single grant.
        for _ in 0..<(framed.count / window + 2) {
            try await Task.sleep(for: .milliseconds(5))
            await ch.grantCredit(window)
        }
        await fulfillment(of: [done], timeout: 5)
        _ = await sendTask.value

        XCTAssertGreaterThan(
            sink.count,
            1,
            "an oversized frame must be split into MULTIPLE envelopes (chunking exercised)",
        )
        XCTAssertEqual(sink.totalBytes, framed.count, "every byte of the framed message is written exactly once")
        // The receiver's per-channel FrameDecoder reassembles the inner WireMessage across the
        // .channelData chunk boundaries — feed the concatenated chunks and assert the ORIGINAL frame.
        var decoder = FrameDecoder()
        decoder.append(sink.concatenated)
        let reassembled = try decoder.nextMessage()
        guard case let .input(bytes) = reassembled else {
            XCTFail("reassembled message must be the original .input, got \(String(describing: reassembled))")
            return
        }
        XCTAssertEqual(bytes, payload, "chunks reassemble to the EXACT original frame (no corruption)")
        XCTAssertNil(try decoder.nextMessage(), "exactly one frame reassembled (no trailing bytes)")
    }

    /// FIX #1 order preservation: two consecutive sends — the FIRST oversized (chunked + parked), the
    /// SECOND a small frame — must NOT interleave. The actor serialises calls AND a single send emits
    /// ALL its chunks before returning, so the second send's bytes appear strictly AFTER the first
    /// frame's last chunk on the wire. We assert the concatenated stream reassembles to [big, small]
    /// in that exact order.
    func testChunkedSendDoesNotInterleaveWithFollowingSend() async throws {
        let sink = Sink()
        let window = 8
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: window) { _, inner in
            sink.record(inner)
        }
        let bigPayload = Data((0..<120).map { UInt8($0 & 0xFF) })
        let big = WireMessage.input(bigPayload)
        let small = WireMessage.input(Data("z".utf8))

        // Two sends issued back-to-back. Because the actor serialises calls, the second awaits the
        // first; both park on the window until grants flow. Order on the wire must be big-then-small.
        let done = expectation(description: "both sends complete")
        let task = Task {
            try? await ch.send(big)
            try? await ch.send(small)
            done.fulfill()
        }
        let bigFramedLen = big.encode().count
        let smallFramedLen = small.encode().count
        for _ in 0..<((bigFramedLen + smallFramedLen) / window + 4) {
            try await Task.sleep(for: .milliseconds(5))
            await ch.grantCredit(window)
        }
        await fulfillment(of: [done], timeout: 5)
        _ = await task.value

        var decoder = FrameDecoder()
        decoder.append(sink.concatenated)
        let first = try decoder.nextMessage()
        let second = try decoder.nextMessage()
        guard case let .input(b1) = first, case let .input(b2) = second else {
            XCTFail(
                "expected two .input frames in order, got \(String(describing: first)), \(String(describing: second))",
            )
            return
        }
        XCTAssertEqual(
            b1,
            bigPayload,
            "first reassembled frame is the big one (chunks not interleaved with the small send)",
        )
        XCTAssertEqual(
            b2,
            Data("z".utf8),
            "second reassembled frame is the small one, strictly AFTER the big frame's last chunk",
        )
    }

    /// Re-review (send-gate): two CONCURRENT sends (SEPARATE Tasks) of oversized frames on ONE
    /// sub-channel must NOT interleave their chunks. An `actor` yields at the credit-park, so WITHOUT
    /// the per-channel send gate a second concurrent send could slip its chunk between the first's
    /// chunks → the receiver's `FrameDecoder` reads body bytes as a length prefix and the stream
    /// corrupts (the proven failure: `frameTooLarge(0xAAAAAAAA)`). The send gate serialises the whole
    /// chunk loop, so the wire is [frameA whole][frameB whole] (in gate order) and BOTH reassemble
    /// intact. (On the un-gated code this test fails with a decode throw / wrong payloads.)
    func testConcurrentSendsDoNotInterleaveChunks() async throws {
        let sink = Sink()
        let window = 8
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: window) { _, inner in
            sink.record(inner)
        }
        let payloadA = Data(repeating: 0xAA, count: 120)
        let payloadB = Data(repeating: 0xBB, count: 120)
        let msgA = WireMessage.input(payloadA)
        let msgB = WireMessage.input(payloadB)

        let bothDone = expectation(description: "both concurrent sends complete")
        bothDone.expectedFulfillmentCount = 2
        // Issue the two sends from SEPARATE concurrent Tasks — the corruption trigger.
        let taskA = Task { try? await ch.send(msgA)
            bothDone.fulfill()
        }
        let taskB = Task { try? await ch.send(msgB)
            bothDone.fulfill()
        }
        let totalFramed = msgA.encode().count + msgB.encode().count
        // Grant ONE window's worth incrementally so BOTH sends chunk+park repeatedly (max interleave
        // opportunity on the buggy code); credit banks in FlowCreditPolicy so it cannot deadlock.
        for _ in 0..<(totalFramed / window + 8) {
            try await Task.sleep(for: .milliseconds(5))
            await ch.grantCredit(window)
        }
        await fulfillment(of: [bothDone], timeout: 5)
        _ = await taskA.value
        _ = await taskB.value

        // The wire must reassemble to EXACTLY two intact .input frames (no interleave → no corruption).
        var decoder = FrameDecoder()
        decoder.append(sink.concatenated)
        let f1 = try decoder.nextMessage()
        let f2 = try decoder.nextMessage()
        XCTAssertNil(try decoder.nextMessage(), "exactly two frames reassembled — no trailing/garbled bytes")
        guard case let .input(b1) = f1, case let .input(b2) = f2 else {
            XCTFail(
                "expected two intact .input frames, got \(String(describing: f1)), \(String(describing: f2))",
            )
            return
        }
        // Order is whichever took the gate first; both payloads must appear INTACT.
        XCTAssertEqual(
            Set([b1, b2]),
            Set([payloadA, payloadB]),
            "both frames reassemble intact (chunks not interleaved)",
        )
    }

    /// FIX #1 close-mid-chunk: a `finish()` while a chunked send is parked between chunks must THROW
    /// (the send does not emit a partial-then-stranded continuation). The receiver's half-reassembled
    /// frame is discarded with its decoder on channel close — we only assert the sender throws and is
    /// not leaked.
    func testFinishMidChunkThrows() async throws {
        let sink = Sink()
        let window = 8
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: window) { _, inner in
            sink.record(inner)
        }
        let message = WireMessage.input(Data(repeating: 0x42, count: 200)) // ≫ 8-byte window

        let threw = expectation(description: "chunked send throws when the channel closes mid-frame")
        let sendTask = Task {
            do {
                try await ch.send(message)
                XCTFail("a chunked send parked mid-frame must THROW when the channel closes")
            } catch {
                threw.fulfill()
            }
        }
        // Let it send the first chunk(s) and park on the exhausted window, then close.
        try await Task.sleep(for: .milliseconds(100))
        let beforeClose = sink.count
        XCTAssertGreaterThanOrEqual(beforeClose, 1, "at least the first chunk should have gone out before parking")
        XCTAssertLessThan(
            sink.totalBytes,
            message.encode().count,
            "the frame must NOT be fully sent (still parked mid-chunk)",
        )
        await ch.finish()
        await fulfillment(of: [threw], timeout: 2)
        _ = await sendTask.value
    }

    /// Round-3 leak fix: a sender PARKED on an exhausted window must be woken by TASK CANCELLATION
    /// (not only by a `windowAdjust` grant or `finish()`), so a teardown that merely `cancel()`s the
    /// drain Task — e.g. `HostServer.stop()` → `MuxChannelSession.shutdown()`, which never `finish()`es
    /// the sub-channel — does not leak the parked task + its retained actors forever.
    func testCancelWhileBlockedWakesSenderInsteadOfLeaking() async throws {
        let sink = Sink()
        // 1 body byte ⇒ 6 wire bytes; window = 6 ⇒ the first send fits exactly, the next must block.
        let ch = MuxSubChannel(channelID: 1, channel: .data, sendWindowBytes: 6) { _, inner in
            sink.record(inner)
        }
        try await ch.send(WireMessage.input(Data("x".utf8))) // exactly fills the 6-byte window
        XCTAssertEqual(sink.count, 1)

        let completed = expectation(description: "the blocked send completes when its Task is cancelled")
        let sendTask = Task {
            try? await ch.send(WireMessage.input(Data("y".utf8))) // parks on the exhausted window
            completed.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.count, 1, "the second send must be SUSPENDED (window exhausted)")

        // Cancelling the Task must WAKE the parked sender (cancellation-aware park) so it throws and the
        // Task completes — instead of leaking. Without the fix, `completed` never fulfils (timeout).
        sendTask.cancel()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(sink.count, 1, "the cancelled send did not write the frame (it threw out of the park)")
        _ = await sendTask.value
    }
}
