import XCTest
@testable import AislopdeskProtocol

/// Guards the advancing-cursor + lazy-compaction rewrite of ``FrameDecoder`` and ``MuxFrameDecoder``
/// (deep-hunt R5, rank 4 — the O(n²) front-removal fix). Two properties:
///   1. CORRECTNESS is byte-identical under a dense chunk of many small frames (which crosses the
///      64 KiB compaction threshold mid-drain) and under arbitrary split boundaries.
///   2. PERF scales ~LINEARLY in frame count — a regression to per-frame front-removal would make the
///      drain quadratic, which this catches via a time-ratio bound (linear ≈ 4×, quadratic ≈ 16× for a
///      4× frame-count increase; the bound is a generous 8× to absorb timing noise).
final class FrameDecoderCursorTests: XCTestCase {
    // MARK: WireMessage / FrameDecoder

    private func smallWireFrames(_ n: Int) -> (frames: [WireMessage], bytes: Data) {
        var frames: [WireMessage] = []
        frames.reserveCapacity(n)
        var bytes = Data()
        for i in 0..<n {
            // Tiny bodies so a 64 KiB chunk holds thousands of frames (the quadratic trigger shape).
            let m = WireMessage.output(seq: Int64(i + 1), bytes: Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)]))
            frames.append(m)
            bytes.append(m.encode())
        }
        return (frames, bytes)
    }

    func testFrameDecoderDecodesManySmallFramesIdenticallyInOneChunk() throws {
        let (expected, bytes) = smallWireFrames(12000) // > 64 KiB of tiny frames → compaction fires mid-drain
        var decoder = FrameDecoder()
        decoder.append(bytes)
        var decoded: [WireMessage] = []
        while let m = try decoder.nextMessage() { decoded.append(m) }
        XCTAssertEqual(decoded, expected, "cursor + mid-drain compaction must decode every frame identically, in order")
        XCTAssertNil(try decoder.nextMessage())
    }

    func testFrameDecoderDecodesIdenticallyAcrossArbitrarySplits() throws {
        let (expected, bytes) = smallWireFrames(3000)
        var decoder = FrameDecoder()
        var decoded: [WireMessage] = []
        // Feed in 7-byte slices so frames straddle append boundaries and the cursor/compaction interact
        // with partial frames repeatedly.
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let end = bytes.index(i, offsetBy: 7, limitedBy: bytes.endIndex) ?? bytes.endIndex
            decoder.append(Data(bytes[i..<end]))
            while let m = try decoder.nextMessage() { decoded.append(m) }
            i = end
        }
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(try decoder.nextMessage())
    }

    func testFrameDecoderScalesLinearlyNotQuadratically() throws {
        let small = try drainTime { smallWireFrames(8000).bytes }
        let large = try drainTime { smallWireFrames(32000).bytes } // 4× the frames
        // Linear ≈ 4×; the old O(n²) front-removal ≈ 16×. Assert well below the quadratic regime.
        XCTAssertLessThan(
            large / max(small, 1e-9),
            8.0,
            "decode time must scale ~linearly in frame count (got \(large / small)× for 4× frames) — "
                + "a ratio near 16 means the O(n²) front-removal regressed",
        )
    }

    private func drainTime(_ make: () -> Data) throws -> Double {
        let bytes = make()
        // One warmup to stabilize allocator/caches, then the measured run.
        for _ in 0..<2 {
            var d = FrameDecoder()
            d.append(bytes)
            while try d.nextMessage() != nil {}
        }
        let clock = ContinuousClock()
        let start = clock.now
        var d = FrameDecoder()
        d.append(bytes)
        while try d.nextMessage() != nil {}
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Back-patched length prefix (rank 11 encode optimization)

    /// The back-patched 4-byte BE prefix must equal `frame.count - 4` for every WireMessage variant —
    /// the exact value the old intermediate-`body` path wrote — and decode must round-trip.
    func testWireMessageEncodePrefixEqualsPayloadLength() throws {
        let samples: [WireMessage] = [
            .output(seq: 42, bytes: Data("hello".utf8)),
            .output(seq: 1, bytes: Data()), // empty payload edge
            .exit(code: 137),
            .input(Data([0x1B, 0x5B, 0x41])),
            .resize(cols: 200, rows: 50, pxWidth: 1, pxHeight: 2),
            .ack(seq: 9_000_000_000),
            .bye, .bell,
            .helloAck(sessionID: UUID(), resumeFromSeq: 7, returningClient: true),
            .title("a-very-long-title-string-with-emoji-✅-and-more"),
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: -1, durationMS: 1234)),
            .commandStatus(.idle(exitCode: nil, durationMS: 0)),
        ]
        for m in samples {
            let f = m.encode()
            XCTAssertGreaterThanOrEqual(f.count, 5, "frame is at least prefix(4) + type(1)")
            let prefix = (UInt32(f[f.startIndex]) << 24) | (UInt32(f[f.startIndex + 1]) << 16)
                | (UInt32(f[f.startIndex + 2]) << 8) | UInt32(f[f.startIndex + 3])
            XCTAssertEqual(Int(prefix), f.count - 4, "back-patched prefix must equal payload length for \(m)")
            // And it must still decode back to the same message.
            var d = FrameDecoder()
            d.append(f)
            XCTAssertEqual(try d.nextMessage(), m)
            XCTAssertNil(try d.nextMessage())
        }
    }

    /// Same invariant for the mux envelope: the back-patched prefix equals the inner-run length and the
    /// frame round-trips.
    func testMuxFrameEncodePrefixEqualsInnerLength() throws {
        let samples: [MuxFrame] = [
            .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 5, channelClass: 0),
            .channelOpenAck(channelID: 2, accepted: true),
            .channelOpenAck(channelID: 3, accepted: false),
            .channelData(channelID: 4, payload: Data("payload-bytes".utf8)),
            .channelData(channelID: 5, payload: Data()), // empty payload edge
            .channelClose(channelID: 6),
            .windowAdjust(channelID: 7, bytesToAdd: 262_144),
        ]
        for fr in samples {
            let f = MuxEnvelopeCodec.encode(fr)
            XCTAssertGreaterThanOrEqual(f.count, 9, "mux frame is at least prefix(4) + channelID(4) + type(1)")
            let prefix = (UInt32(f[f.startIndex]) << 24) | (UInt32(f[f.startIndex + 1]) << 16)
                | (UInt32(f[f.startIndex + 2]) << 8) | UInt32(f[f.startIndex + 3])
            XCTAssertEqual(Int(prefix), f.count - 4, "back-patched mux prefix must equal inner length for \(fr)")
            var d = MuxFrameDecoder()
            d.append(f)
            XCTAssertEqual(try d.nextFrame(), fr)
            XCTAssertNil(try d.nextFrame())
        }
    }

    // MARK: MuxFrame / MuxFrameDecoder

    private func smallMuxFrames(_ n: Int) -> (frames: [MuxFrame], bytes: Data) {
        var frames: [MuxFrame] = []
        frames.reserveCapacity(n)
        var bytes = Data()
        for i in 0..<n {
            // channelClose is the smallest mux frame (empty body) — maximal fragmentation.
            let f = MuxFrame.channelClose(channelID: UInt32(i % 64 + 1))
            frames.append(f)
            bytes.append(MuxEnvelopeCodec.encode(f))
        }
        return (frames, bytes)
    }

    func testMuxFrameDecoderDecodesManySmallFramesIdenticallyInOneChunk() throws {
        let (expected, bytes) = smallMuxFrames(12000)
        var decoder = MuxFrameDecoder()
        decoder.append(bytes)
        var decoded: [MuxFrame] = []
        while let f = try decoder.nextFrame() { decoded.append(f) }
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testMuxFrameDecoderDecodesIdenticallyAcrossArbitrarySplits() throws {
        let (expected, bytes) = smallMuxFrames(3000)
        var decoder = MuxFrameDecoder()
        var decoded: [MuxFrame] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let end = bytes.index(i, offsetBy: 5, limitedBy: bytes.endIndex) ?? bytes.endIndex
            decoder.append(Data(bytes[i..<end]))
            while let f = try decoder.nextFrame() { decoded.append(f) }
            i = end
        }
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testMuxFrameDecoderScalesLinearlyNotQuadratically() throws {
        let small = try muxDrainTime { smallMuxFrames(8000).bytes }
        let large = try muxDrainTime { smallMuxFrames(32000).bytes }
        XCTAssertLessThan(
            large / max(small, 1e-9),
            8.0,
            "mux decode time must scale ~linearly (got \(large / small)× for 4× frames)",
        )
    }

    private func muxDrainTime(_ make: () -> Data) throws -> Double {
        let bytes = make()
        for _ in 0..<2 {
            var d = MuxFrameDecoder()
            d.append(bytes)
            while try d.nextFrame() != nil {}
        }
        let clock = ContinuousClock()
        let start = clock.now
        var d = MuxFrameDecoder()
        d.append(bytes)
        while try d.nextFrame() != nil {}
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
