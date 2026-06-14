import AislopdeskProtocol
import XCTest
@testable import AislopdeskInspector

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

    func testFrameTooLargeRejected() {
        // Length prefix claiming > 16 MiB must be rejected, not allocated.
        var decoder = InspectorFrameDecoder()
        var prefix = Data()
        let tooBig = UInt32(Aislopdesk.maxFramePayloadLength + 1)
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
