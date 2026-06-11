import XCTest
@testable import AislopdeskVideoProtocol

/// Wire-safety for the network-feedback channel's NEW header field: the 4-byte
/// `hostSendTsMillis` the host stamps on every video fragment. Pure (no transport, no
/// VideoToolbox). A malformed/short datagram must DROP (throw), never crash.
final class NetworkFeedbackWireTests: XCTestCase {

    private func makeFragment(ts: UInt32, payload: Data) -> FrameFragment {
        let header = FrameFragmentHeader(
            streamSeq: 0x0102_0304, frameID: 0x0506_0708, fragIndex: 7, fragCount: 9,
            flags: [.keyframe, .crisp], payloadLength: UInt16(payload.count), hostSendTsMillis: ts)
        return FrameFragment(header: header, payload: payload)
    }

    func testHeaderIsNineteenBytes() {
        XCTAssertEqual(FrameFragmentHeader.size, 19, "header grew 15→19 for the 4-byte hostSendTsMillis")
        // The payload cap derives from the header size, so it shrank by the same 4 bytes.
        XCTAssertEqual(VideoPacketizer.maxPayloadSize, 1200 - 19)
    }

    func testHostSendTsRoundTrips() throws {
        for ts: UInt32 in [0, 1, 1_234_567, .max] {
            let payload = Data([0xAA, 0xBB, 0xCC, 0xDD])
            let fragment = makeFragment(ts: ts, payload: payload)
            let decoded = try FrameFragment.decode(fragment.encode())
            XCTAssertEqual(decoded, fragment, "fragment round-trips with ts=\(ts)")
            XCTAssertEqual(decoded.header.hostSendTsMillis, ts)
        }
    }

    func testZeroPayloadWithTsRoundTrips() throws {
        let fragment = makeFragment(ts: 999, payload: Data())
        let decoded = try FrameFragment.decode(fragment.encode())
        XCTAssertEqual(decoded.header.hostSendTsMillis, 999)
        XCTAssertEqual(decoded.payload.count, 0)
    }

    /// A datagram shorter than the 19-byte header (e.g. truncated mid-timestamp) must throw
    /// `.truncated` so the router drops the single packet — never an out-of-bounds read / crash.
    func testTooShortDatagramThrows() {
        let full = makeFragment(ts: 0xDEAD_BEEF, payload: Data([1, 2, 3])).encode()
        XCTAssertEqual(full.count, 19 + 3)
        // Every prefix shorter than the full 19-byte header must throw (incl. mid-timestamp at 13..16).
        for prefix in [0, 12, 13, 14, 16, 18] {
            XCTAssertThrowsError(try FrameFragment.decode(full.prefix(prefix))) { error in
                XCTAssertEqual(error as? VideoProtocolError, .truncated, "prefix \(prefix) should be .truncated")
            }
        }
    }

    /// The packetizer stamps the SAME ts on every fragment (data + parity) of one frame.
    func testPacketizerStampsAllFragments() {
        var packetizer = VideoPacketizer(fec: XORParityFEC())
        let frame = Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 10)).map { UInt8(truncatingIfNeeded: $0) })
        let fragments = packetizer.packetize(frame: frame, keyframe: true, crisp: false, hostSendTsMillis: 424242)
        XCTAssertGreaterThan(fragments.count, 1, "multi-fragment frame (incl. parity)")
        for fragment in fragments {
            XCTAssertEqual(fragment.header.hostSendTsMillis, 424242)
        }
    }

    /// Default (telemetry off) stamps 0 — the existing packetize call sites that omit the arg.
    func testPacketizerDefaultsTsToZero() {
        var packetizer = VideoPacketizer()
        let fragments = packetizer.packetize(frame: Data([1, 2, 3]), keyframe: false)
        XCTAssertEqual(fragments.first?.header.hostSendTsMillis, 0)
    }

    // MARK: recoveredViaFEC (the fecRecovered telemetry numerator)

    /// A frame that arrives WHOLE (no hole) is not FEC-recovered.
    func testWholeFrameNotMarkedFECRecovered() throws {
        var packetizer = VideoPacketizer(fec: XORParityFEC())
        let fragments = packetizer.packetize(frame: Data([1, 2, 3, 4]), keyframe: true)
        var reassembler = FrameReassembler(fec: XORParityFEC())
        var completed: ReassembledFrame?
        for fragment in fragments {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed)
        XCTAssertFalse(completed?.recoveredViaFEC ?? true, "a frame received whole was not FEC-recovered")
    }

    /// A single-data-loss frame completed by its parity is marked `recoveredViaFEC` (drives the
    /// client's windowed `fecRecovered` counter).
    func testFECRecoveredFrameIsMarked() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) })])
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertGreaterThanOrEqual(data.count, 2)
        XCTAssertGreaterThanOrEqual(parity.count, 1)

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?
        // Drop the FIRST data fragment, deliver the rest + the parity → XOR recovers the hole.
        for fragment in data.dropFirst() {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        for fragment in parity {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.avcc, frameBytes, "recovered bytes match the original exactly")
        XCTAssertTrue(completed?.recoveredViaFEC ?? false, "a parity-recovered frame is marked FEC-recovered")
    }
}
