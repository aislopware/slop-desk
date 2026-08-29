import XCTest
@testable import SlopDeskInspector

/// BUG-G: a single bad frame must be SKIPPED (logged + continue), not finish the whole inspector
/// stream. Only a genuine framing desync (frameTooLarge) ends the stream so the client resubscribes.
/// Pure: a hand-fed loopback channel.
///
/// The malformed-BODY half of BUG-G moved one layer in with the parse (`docs/66`): a body the store
/// cannot read is not a framing event at all, so the stream hands it over like any other and the
/// store answers `false`. Same inputs, same guarantee, asserted at the surface that now decides.
final class InspectorResilientDecodeTests: XCTestCase {
    private func good(_ text: String) -> Data {
        InspectorWireFixture.eventFrame(#"{"message":{"_0":{"role":"assistant","text":"\#(text)"}}}"#)
    }

    private func body(_ text: String) -> Data {
        Data(#"{"message":{"_0":{"role":"assistant","text":"\#(text)"}}}"#.utf8)
    }

    /// A frame with an unknown type tag → `CodecError.unknownType`.
    private func unknownTypeFrame() -> Data {
        InspectorWireFixture.frame(tag: 0x7F, body: Data([0x01, 0x02]))
    }

    /// good → malformed (event JSON garbage) → unknown-type → good : the unknown tag is skipped by
    /// the stream, the garbage body is carried through for the store to refuse, and both good events
    /// surface. The stream stays alive throughout.
    func testMalformedAndUnknownFramesAreSkippedStreamContinues() async throws {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> [Data] in
            var got: [Data] = []
            for try await body in stream {
                got.append(body)
                if got.count >= 3 { break }
            }
            return got
        }

        // Feed raw bytes straight onto the host end of the loopback (so the client
        // decodes them). `hostChannel.send` bytes surface on `clientChannel.inbound`.
        let garbage = Data("not-json{".utf8)
        hostChannel.send(good("first"))
        hostChannel.send(InspectorWireFixture.frame(tag: 1, body: garbage))
        hostChannel.send(unknownTypeFrame())
        hostChannel.send(good("second"))

        let got = try await collector.value
        XCTAssertEqual(
            got,
            [body("first"), garbage, body("second")],
            "the unknown tag is skipped; the three type-1 bodies all cross, garbage included",
        )
    }

    /// The garbage body's actual cost, at the surface that pays it: one event, not the session.
    @MainActor
    func testAMalformedBodyCostsOnlyItsOwnEvent() {
        let model = InspectorViewModel()

        XCTAssertTrue(model.apply(body("first")))
        let afterGood = model.revision

        XCTAssertFalse(model.apply(Data("not-json{".utf8)), "the store refuses a body it cannot read")
        XCTAssertEqual(model.revision, afterGood, "and nothing folded, so nothing moved")

        XCTAssertTrue(model.apply(body("second")), "the next event still folds")
        XCTAssertGreaterThan(model.revision, afterGood)
    }

    /// A frameTooLarge length prefix IS a framing desync — the stream finishes (throwing)
    /// so the client side ends its feed and resubscribes, rather than dying silently or
    /// looping on garbage.
    func testFrameTooLargeFinishesStreamForResubscribe() async {
        let (hostChannel, clientChannel) = LoopbackByteChannel.pair()
        let client = InspectorClient(channel: clientChannel)

        let stream = await client.events()
        let collector = Task { () -> (bodies: [Data], threw: Bool) in
            var got: [Data] = []
            do {
                for try await body in stream { got.append(body) }
                return (got, false)
            } catch {
                return (got, true)
            }
        }

        // One good event, then an oversized length prefix (claims > 16 MiB).
        hostChannel.send(good("before"))
        var bad = Data()
        let tooBig = UInt32(InspectorCodec.maxFramePayloadLength + 1)
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 24))
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 16))
        bad.append(UInt8(truncatingIfNeeded: tooBig >> 8))
        bad.append(UInt8(truncatingIfNeeded: tooBig))
        hostChannel.send(bad)

        let result = await collector.value
        XCTAssertEqual(result.bodies, [body("before")])
        XCTAssertTrue(result.threw, "frameTooLarge desync finishes the stream (throwing) → client resubscribes")
    }
}
