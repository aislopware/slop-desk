import SlopDeskProtocol
import XCTest
@testable import SlopDeskInspector

/// The CLIENT end of the inspector wire: daemon-shaped bytes → loopback → `InspectorClient`.
///
/// The frames come from ``InspectorWireFixture``, hand-built to the wire spec, because the Swift
/// side has no event encoder any more — `slopdesk-inspectord` is the only thing that writes tag 1
/// and tag 2 (`docs/54`). What Swift still owns is decode, plus the one control it sends.
final class InspectorTransportTests: XCTestCase {
    private func sampleEvents() -> [InspectorEvent] {
        [
            .sessionStarted(SessionInfo(sessionID: "s1", model: "claude-opus-4-8", cwd: "/repo")),
            .message(MessageEvent(role: .user, text: "hello")),
            .thinking(ThinkingMarker(isPlaceholder: true, signature: "sig123")),
            .toolCard(ToolCard(
                id: "t1",
                name: "Bash",
                inputDisplay: "command: ls",
                inputSummary: "ls",
                status: .pending,
            )),
            .toolCard(ToolCard(
                id: "t1",
                name: "Bash",
                inputDisplay: "command: ls", inputSummary: "ls",
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
                card: ToolCard(
                    id: "sa1",
                    name: "Grep",
                    inputDisplay: "",
                    inputSummary: "",
                    output: "hit",
                    status: .completed,
                ),
            ),
            .workflow(WorkflowMarker(state: .running)),
            .unknownLine(raw: #"{"type":"future"}"#),
        ]
    }

    func testEveryEventShapeDecodesOffTheWire() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
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

        for event in events {
            try hostChannel.send(InspectorWireFixture.eventFrame(event))
        }

        let received = try await collector.value
        XCTAssertEqual(received, events, "every event shape survives the framed channel")
    }

    func testKeepAliveIsSwallowedByEventStream() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
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

        hostChannel.send(InspectorWireFixture.keepAliveFrame) // must NOT surface as an event
        let real = InspectorEvent.message(MessageEvent(role: .assistant, text: "real"))
        try hostChannel.send(InspectorWireFixture.eventFrame(real))

        let received = try await collector.value
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, real)
    }

    // MARK: - The one frame this end WRITES

    /// `subscribe` is the client's only outbound frame, and its bytes are the contract with
    /// `slopdesk_inspectord::wire::decode`: a 9-byte payload, tag `3`, then a big-endian `Int64`.
    /// Asserted as BYTES rather than through a decode, because this end has no subscribe decoder —
    /// and should not grow one just to check its own encoder.
    func testSubscribeFrameIsExactlyTheWireBytes() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let collector = Task { () -> Data? in
            for try await chunk in hostChannel.inbound { return chunk }
            return nil
        }
        try await client.subscribe(fromSeq: 42)
        let got = try await collector.value

        XCTAssertEqual(got, Data([
            0, 0, 0, 9, // payloadLength = tag + 8 body bytes
            3, // tag: subscribe
            0, 0, 0, 0, 0, 0, 0, 42, // fromSeq, big-endian
        ]))
    }

    /// A negative `fromSeq` is two's complement on the wire, not a clamp — the daemon saturates it
    /// on its side (`replay.rs`), and this end must not quietly change the number it was given.
    func testSubscribeCarriesANegativeSeqAsTwosComplement() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let collector = Task { () -> Data? in
            for try await chunk in hostChannel.inbound { return chunk }
            return nil
        }
        try await client.subscribe(fromSeq: -1)
        let got = try await collector.value

        XCTAssertEqual(got, Data([0, 0, 0, 9, 3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    // MARK: - Codec-level framing (split / coalesced reads)

    func testFrameDecoderReassemblesAcrossArbitraryByteBoundaries() throws {
        let messages: [InspectorWireMessage] = [
            .event(.message(MessageEvent(role: .user, text: "x"))),
            .keepAlive,
            .event(.toolCard(ToolCard(id: "z", name: "Read", inputDisplay: "", inputSummary: "", status: .pending))),
        ]
        var blob = Data()
        for message in messages { try blob.append(frame(for: message)) }

        // Feed one byte at a time → the decoder must still recover every frame in order.
        let decoder = InspectorFrameDecoder()
        var decoded: [InspectorWireMessage] = []
        for byte in blob {
            decoder.append(Data([byte]))
            while let message = try decoder.nextMessage() {
                decoded.append(message)
            }
        }
        XCTAssertEqual(decoded, messages)
    }

    /// Many complete frames delivered in ONE chunk (the shape the daemon's full-history replay
    /// produces after a reconnect: one ≤64KiB TCP read packed with small JSON event frames).
    /// Exercises the lazy `readOffset` cursor draining several frames from a single `append` without
    /// any front-removal in between, and that decode order/content survive a later compaction.
    func testManyFramesInOneChunkDecodeInOrder() throws {
        let messages: [InspectorWireMessage] = (0..<200).map {
            .event(.message(MessageEvent(role: .user, text: "line \($0)")))
        }
        var blob = Data()
        for message in messages { try blob.append(frame(for: message)) }

        let decoder = InspectorFrameDecoder()
        decoder.append(blob) // one chunk holding every frame.
        var decoded: [InspectorWireMessage] = []
        while let message = try decoder.nextMessage() { decoded.append(message) }
        XCTAssertEqual(decoded, messages, "every frame in the chunk decodes, in order")

        // The cursor-then-compact discipline must still work for a SUBSEQUENT chunk after the drain.
        let tail: InspectorWireMessage = .event(.message(MessageEvent(role: .assistant, text: "after")))
        try decoder.append(frame(for: tail))
        XCTAssertEqual(try decoder.nextMessage(), tail)
    }

    func testFrameTooLargeRejected() {
        // Length prefix claiming > 16 MiB must be rejected, not allocated.
        let decoder = InspectorFrameDecoder()
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

    /// The client's OWN control tag, arriving from the daemon, is not a frame this end reads. It
    /// decodes as unknown rather than as a subscribe — which keeps `decode` strictly the
    /// host → client half and cannot be mistaken for a second implementation of the other one.
    func testSubscribeTagIsNotDecodableOnTheClientEnd() {
        XCTAssertThrowsError(try InspectorCodec.decode(payload: Data([3, 0, 0, 0, 0, 0, 0, 0, 7]))) { error in
            XCTAssertEqual(error as? InspectorCodec.CodecError, .unknownType(3))
        }
    }

    // MARK: -

    /// The daemon-side frame for a message this end can decode.
    private func frame(for message: InspectorWireMessage) throws -> Data {
        switch message {
        case let .event(event): try InspectorWireFixture.eventFrame(event)
        case .keepAlive: InspectorWireFixture.keepAliveFrame
        }
    }
}
