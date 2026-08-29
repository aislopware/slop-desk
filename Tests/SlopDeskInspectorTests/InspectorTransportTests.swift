import XCTest
@testable import SlopDeskInspector

/// The CLIENT end of the inspector wire: daemon-shaped bytes → loopback → `InspectorClient`.
///
/// The frames come from ``InspectorWireFixture``, hand-built to the wire spec, because the Swift
/// side has no event encoder any more — `slopdesk-inspectord` is the only thing that writes tag 1
/// and tag 2 (`docs/54`). What Swift still owns is FRAMING, plus the one control it sends.
///
/// What a body SAYS is not asserted here and cannot be: since `docs/66` the body crosses this layer
/// unread, and the taxonomy it belongs to is pinned in `slopdesk-inspectord`'s `golden_events.rs`
/// against the same corpus. So these tests assert the property that is actually this layer's — the
/// bytes between the length prefixes arrive whole, in order, and unaltered.
final class InspectorTransportTests: XCTestCase {
    /// One body per event SHAPE the daemon emits, spelled as `slopdesk-inspectord` writes them.
    /// Kept as text so the fixture frames exactly these bytes and the assertion is byte-for-byte.
    private func sampleBodies() -> [String] {
        [
            #"{"sessionStarted":{"_0":{"sessionID":"s1","model":"opus"}}}"#,
            #"{"message":{"_0":{"role":"assistant","text":"hi"}}}"#,
            #"{"thinking":{"_0":{"isPlaceholder":true,"signature":"sig"}}}"#,
            #"{"toolCard":{"_0":{"id":"toolu_1","name":"Read","input":{"file_path":"/tmp/a"},"status":"pending"}}}"#,
            #"{"todosUpdated":{"_0":[{"content":"port it","status":"in_progress","activeForm":"porting it"}]}}"#,
            #"{"subagentUpdated":{"_0":{"id":"a1","agentType":"Ariadne","status":"stopped"}}}"#,
            #"{"subagentToolCard":{"agentID":"a1","card":{"id":"toolu_2","name":"Grep","input":{},"status":"completed"}}}"#,
            #"{"workflow":{"_0":{"state":"running"}}}"#,
            #"{"unknownLine":{"raw":"{not json"}}"#,
            #"{"historyTruncated":{"droppedCount":7}}"#,
        ]
    }

    func testEveryEventBodyCrossesTheWireWhole() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let bodies = sampleBodies()

        // Collect on the client first.
        let stream = await client.events()
        let collector = Task { () -> [Data] in
            var got: [Data] = []
            for try await body in stream {
                got.append(body)
                if got.count >= bodies.count { break }
            }
            return got
        }

        for body in bodies {
            hostChannel.send(InspectorWireFixture.eventFrame(body))
        }

        let received = try await collector.value
        XCTAssertEqual(received, bodies.map { Data($0.utf8) }, "every body survives the framed channel")
    }

    func testKeepAliveIsSwallowedByEventStream() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> [Data] in
            var got: [Data] = []
            for try await body in stream {
                got.append(body)
                if got.count >= 1 { break }
            }
            return got
        }

        hostChannel.send(InspectorWireFixture.keepAliveFrame) // must NOT surface as an event
        let real = #"{"message":{"_0":{"role":"assistant","text":"real"}}}"#
        hostChannel.send(InspectorWireFixture.eventFrame(real))

        let received = try await collector.value
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first, Data(real.utf8))
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
            .event(Data(#"{"message":{"_0":{"role":"user","text":"x"}}}"#.utf8)),
            .keepAlive,
            .event(Data(#"{"toolCard":{"_0":{"id":"z","name":"Read","input":{},"status":"pending"}}}"#.utf8)),
        ]
        var blob = Data()
        for message in messages { blob.append(frame(for: message)) }

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
    ///
    /// It is also what pins the ONE copy the decoder still makes: its scratch buffer is reused per
    /// frame, so a body yielded as a view onto it would read as the LAST frame's by the time the
    /// caller looked. 200 frames drained before anything is compared is exactly that trap.
    func testManyFramesInOneChunkDecodeInOrder() throws {
        let messages: [InspectorWireMessage] = (0..<200).map {
            .event(Data(#"{"message":{"_0":{"role":"user","text":"line \#($0)"}}}"#.utf8))
        }
        var blob = Data()
        for message in messages { blob.append(frame(for: message)) }

        let decoder = InspectorFrameDecoder()
        decoder.append(blob) // one chunk holding every frame.
        var decoded: [InspectorWireMessage] = []
        while let message = try decoder.nextMessage() { decoded.append(message) }
        XCTAssertEqual(decoded, messages, "every frame in the chunk decodes, in order")

        // The cursor-then-compact discipline must still work for a SUBSEQUENT chunk after the drain.
        let tail: InspectorWireMessage = .event(Data(#"{"message":{"_0":{"role":"assistant","text":"after"}}}"#.utf8))
        decoder.append(frame(for: tail))
        XCTAssertEqual(try decoder.nextMessage(), tail)
    }

    func testFrameTooLargeRejected() {
        // Length prefix claiming > 16 MiB must be rejected, not allocated.
        let decoder = InspectorFrameDecoder()
        var prefix = Data()
        let tooBig = UInt32(InspectorCodec.maxFramePayloadLength + 1)
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
    private func frame(for message: InspectorWireMessage) -> Data {
        switch message {
        case let .event(body): InspectorWireFixture.eventFrame(body)
        case .keepAlive: InspectorWireFixture.keepAliveFrame
        }
    }
}
