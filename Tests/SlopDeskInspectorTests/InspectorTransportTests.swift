import SlopDeskProtocol
import XCTest
@testable import SlopDeskInspector

/// Inspector transport round-trip: encode a set of InspectorEvents through
/// InspectorSource → loopback → InspectorClient, assert equality.
final class InspectorTransportTests: XCTestCase {
    private func sampleEvents() -> [InspectorEvent] {
        [
            .sessionStarted(SessionInfo(sessionID: "s1", model: "claude-opus-4-8", cwd: "/repo")),
            .message(MessageEvent(role: .user, text: "hello")),
            .thinking(ThinkingMarker(isPlaceholder: true, signature: "sig123")),
            .toolCard(ToolCard(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), status: .pending)),
            .toolCard(ToolCard(
                id: "t1",
                name: "Bash",
                input: .object(["command": .string("ls")]),
                output: "files",
                status: .completed,
            )),
            .todosUpdated([
                TodoItem(content: "a", status: .completed),
                TodoItem(content: "b", status: .inProgress, activeForm: "doing b"),
            ]),
            .subagentUpdated(SubagentNode(
                id: "deadbeef",
                agentType: "Ariadne",
                status: .stopped,
                lastAssistantMessage: "done",
            )),
            .subagentToolCard(
                agentID: "deadbeef",
                card: ToolCard(id: "sa1", name: "Grep", input: .object([:]), output: "hit", status: .completed),
            ),
            .workflow(WorkflowMarker(state: .running)),
            .unknownLine(raw: #"{"type":"future"}"#),
        ]
    }

    func testRoundTripPreservesEventsExactly() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostChannel)
        let client = InspectorClient(channel: clientChannel)

        let events = sampleEvents()

        // Collect on the client first.
        let stream = await client.events()
        let collector = Task { () -> [InspectorEvent] in
            var got: [InspectorEvent] = []
            for try await event in stream {
                got.append(event)
                if got.count >= events.count { break }
            }
            return got
        }

        // Send from the host.
        for event in events {
            try await source.send(event)
        }

        let received = try await collector.value
        XCTAssertEqual(received, events, "every event round-trips byte-exact through the framed channel")
    }

    func testKeepAliveIsSwallowedByEventStream() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostChannel)
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> [InspectorEvent] in
            var got: [InspectorEvent] = []
            for try await event in stream {
                got.append(event)
                if got.count >= 1 { break }
            }
            return got
        }

        try await source.sendKeepAlive() // must NOT surface as an event
        try await source.send(.message(MessageEvent(role: .assistant, text: "real")))

        let received = try await collector.value
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, .message(MessageEvent(role: .assistant, text: "real")))
    }

    func testSubscribeControlReachesHost() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let source = InspectorSource(channel: hostChannel)
        let client = InspectorClient(channel: clientChannel)

        let controls = await source.controls()
        let collector = Task { () -> InspectorWireMessage? in
            for try await message in controls { return message }
            return nil
        }
        try await client.subscribe(fromSeq: 42)
        let got = try await collector.value
        XCTAssertEqual(got, .subscribe(fromSeq: 42))
    }

    // MARK: - InspectorSource.stream — dead-peer pump termination

    /// A ``ByteChannel`` whose `send` succeeds `failAfter` times, then throws forever
    /// (a peer that died mid-stream). Counts every send attempt.
    private final class FailingSendChannel: ByteChannel, @unchecked Sendable {
        struct PeerGone: Error {}
        private let lock = NSLock()
        private var attempts = 0
        private let failAfter: Int

        init(failAfter: Int) { self.failAfter = failAfter }

        var sendAttempts: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        /// Synchronous (non-async) so the locking is legal from the async `send`.
        private func recordAttempt() -> Int {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            return attempts
        }

        func send(_: Data) async throws {
            // `await Task.yield()` satisfies the protocol's async signature (and the
            // async_without_await strict-lint rule) — the repo's fake-channel idiom.
            await Task.yield()
            if recordAttempt() > failAfter { throw PeerGone() }
        }

        var inbound: AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
        func close() {}
    }

    /// `InspectorSource.stream(_:)` must STOP pumping when a send fails (dead peer),
    /// matching the hand-rolled pump in `InspectorServer.serve` — not swallow the error
    /// and keep draining (pre-fix: `try? await send(event)` consumed the entire upstream
    /// forever, parking on a never-finishing live stream for a peer that is gone).
    func testStreamStopsPumpingOnSendFailure() async throws {
        let channel = FailingSendChannel(failAfter: 2)
        let source = InspectorSource(channel: channel)

        var continuation: AsyncStream<InspectorEvent>.Continuation!
        let events = AsyncStream<InspectorEvent> { continuation = $0 }
        for i in 0..<10 {
            continuation.yield(.message(MessageEvent(role: .assistant, text: "e\(i)")))
        }
        // Deliberately NOT finished: a live tail never "ends" on its own — the pump must
        // terminate on the send failure, not wait for upstream exhaustion.

        let pump = Task { await source.stream(events) }
        // Race the pump against a timeout so the pre-fix hang FAILS the test, not the suite.
        struct PumpNeverReturned: Error {}
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pump.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                pump.cancel()
                throw PumpNeverReturned()
            }
            try await group.next()!
            group.cancelAll()
        }

        XCTAssertEqual(
            channel.sendAttempts,
            3,
            "2 successful sends + the 1 failing send, then the pump stops — the remaining 7 events are never sent",
        )
        continuation.finish()
    }

    // MARK: - Codec-level framing (split / coalesced reads)

    func testFrameDecoderReassemblesAcrossArbitraryByteBoundaries() throws {
        let messages: [InspectorWireMessage] = [
            .event(.message(MessageEvent(role: .user, text: "x"))),
            .keepAlive,
            .subscribe(fromSeq: 7),
            .event(.toolCard(ToolCard(id: "z", name: "Read", input: .object([:]), status: .pending))),
        ]
        var blob = Data()
        for message in messages { try blob.append(InspectorCodec.encode(message)) }

        // Feed one byte at a time → the decoder must still recover every frame in order.
        var decoder = InspectorFrameDecoder()
        var decoded: [InspectorWireMessage] = []
        for byte in blob {
            decoder.append(Data([byte]))
            while let message = try decoder.nextMessage() {
                decoded.append(message)
            }
        }
        XCTAssertEqual(decoded, messages)
    }

    /// Many complete frames delivered in ONE chunk (the shape an `InspectorReplayLog` full-history
    /// replay produces after a reconnect: one ≤64KiB TCP read packed with small JSON event frames).
    /// Exercises the lazy `readOffset` cursor draining several frames from a single `append` without
    /// any front-removal in between, and that decode order/content survive a later compaction.
    func testManyFramesInOneChunkDecodeInOrder() throws {
        let messages: [InspectorWireMessage] = (0..<200).map {
            .event(.message(MessageEvent(role: .user, text: "line \($0)")))
        }
        var blob = Data()
        for message in messages { try blob.append(InspectorCodec.encode(message)) }

        var decoder = InspectorFrameDecoder()
        decoder.append(blob) // one chunk holding every frame.
        var decoded: [InspectorWireMessage] = []
        while let message = try decoder.nextMessage() { decoded.append(message) }
        XCTAssertEqual(decoded, messages, "every frame in the chunk decodes, in order")

        // The cursor-then-compact discipline must still work for a SUBSEQUENT chunk after the drain.
        let tail: InspectorWireMessage = .event(.message(MessageEvent(role: .assistant, text: "after")))
        try decoder.append(InspectorCodec.encode(tail))
        XCTAssertEqual(try decoder.nextMessage(), tail)
    }

    func testFrameTooLargeRejected() {
        // Length prefix claiming > 16 MiB must be rejected, not allocated.
        var decoder = InspectorFrameDecoder()
        var prefix = Data()
        let tooBig = UInt32(SlopDesk.maxFramePayloadLength + 1)
        prefix.append(UInt8(truncatingIfNeeded: tooBig >> 24))
        prefix.append(UInt8(truncatingIfNeeded: tooBig >> 16))
        prefix.append(UInt8(truncatingIfNeeded: tooBig >> 8))
        prefix.append(UInt8(truncatingIfNeeded: tooBig))
        decoder.append(prefix)
        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            XCTAssertEqual(error as? InspectorCodec.CodecError, .frameTooLarge(Int(tooBig)))
        }
    }

    func testUnknownTypeTagRejected() {
        XCTAssertThrowsError(try InspectorCodec.decode(payload: Data([0xFF]))) { error in
            XCTAssertEqual(error as? InspectorCodec.CodecError, .unknownType(0xFF))
        }
    }
}
