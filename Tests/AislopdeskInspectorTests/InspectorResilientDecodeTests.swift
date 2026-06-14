import AislopdeskProtocol
import XCTest
@testable import AislopdeskInspector

/// BUG-G: a single malformed / unknown-type frame must be SKIPPED (logged + continue),
/// not finish the whole inspector stream. Only a genuine framing desync (frameTooLarge)
/// ends the stream so the client resubscribes. Pure: a hand-fed loopback channel.
final class InspectorResilientDecodeTests: XCTestCase {
    /// Builds a length-prefixed frame from a raw payload (`typeTag + body`), bypassing
    /// `InspectorCodec.encode` so we can craft a *malformed* body deliberately.
    private func frame(payload: Data) -> Data {
        var out = Data()
        let len = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: len >> 24))
        out.append(UInt8(truncatingIfNeeded: len >> 16))
        out.append(UInt8(truncatingIfNeeded: len >> 8))
        out.append(UInt8(truncatingIfNeeded: len))
        out.append(payload)
        return out
    }

    private func good(_ text: String) throws -> Data {
        try InspectorCodec.encode(.event(.message(MessageEvent(role: .assistant, text: text))))
    }

    /// A type-1 (event) frame whose body is NOT valid JSON → `CodecError.malformedBody`.
    private func malformedEventFrame() -> Data {
        var payload = Data([1]) // type tag = .event
        payload.append(Data("not-json{".utf8))
        return frame(payload: payload)
    }

    /// A frame with an unknown type tag → `CodecError.unknownType`.
    private func unknownTypeFrame() -> Data {
        frame(payload: Data([0x7F, 0x01, 0x02]))
    }

    /// good → malformed (event JSON garbage) → unknown-type → good : the two good events
    /// must surface, the bad two are skipped, the stream stays alive.
    func testMalformedAndUnknownFramesAreSkippedStreamContinues() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> [InspectorEvent] in
            var got: [InspectorEvent] = []
            for try await event in stream {
                got.append(event)
                if got.count >= 2 { break }
            }
            return got
        }

        // Feed raw bytes straight onto the host end of the loopback (so the client
        // decodes them). `hostChannel.send` bytes surface on `clientChannel.inbound`.
        try await hostChannel.send(good("first"))
        try await hostChannel.send(malformedEventFrame())
        try await hostChannel.send(unknownTypeFrame())
        try await hostChannel.send(good("second"))

        let got = try await collector.value
        XCTAssertEqual(
            got,
            [
                .message(MessageEvent(role: .assistant, text: "first")),
                .message(MessageEvent(role: .assistant, text: "second")),
            ],
            "malformed + unknown frames are skipped; the two good events still arrive",
        )
    }

    /// A frameTooLarge length prefix IS a framing desync — the stream finishes (throwing)
    /// so the client side ends its feed and resubscribes, rather than dying silently or
    /// looping on garbage.
    func testFrameTooLargeFinishesStreamForResubscribe() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> (events: [InspectorEvent], threw: Bool) in
            var got: [InspectorEvent] = []
            do {
                for try await event in stream { got.append(event) }
                return (got, false)
            } catch {
                return (got, true)
            }
        }

        // One good event, then an oversized length prefix (claims > 16 MiB).
        try await hostChannel.send(good("before"))
        var bad = Data()
        let tooBig = UInt32(Aislopdesk.maxFramePayloadLength + 1)
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 24))
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 16))
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 8))
        bad.append(UInt8(truncatingIfNeeded: tooBig))
        try await hostChannel.send(bad)

        let result = await collector.value
        XCTAssertEqual(result.events, [.message(MessageEvent(role: .assistant, text: "before"))])
        XCTAssertTrue(result.threw, "frameTooLarge desync finishes the stream (throwing) → client resubscribes")
    }
}
