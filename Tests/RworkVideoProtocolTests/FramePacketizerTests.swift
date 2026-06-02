import XCTest
@testable import RworkVideoProtocol

/// Packetize / reassemble round-trips, fragment-loss detection, and the FEC-less
/// drop+recovery path. (FEC recovery is exercised in FECTests / reassembler-with-FEC.)
final class FramePacketizerTests: XCTestCase {

    /// Builds an AVCC frame of `naluSizes` NAL units with deterministic content.
    private func makeAVCC(naluSizes: [Int]) -> Data {
        let units = naluSizes.enumerated().map { i, size in
            Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 &+ i &* 7) })
        }
        return NALUnit.join(units)
    }

    func testSingleFragmentFrameRoundTrips() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [50]) // well under MTU
        let fragments = packetizer.packetize(frame: frame, keyframe: true)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertTrue(fragments[0].header.flags.contains(.keyframe))
        XCTAssertEqual(fragments[0].header.fragCount, 1)

        var reassembler = FrameReassembler()
        let result = reassembler.ingest(fragments[0])
        guard case .completed(let reassembled) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(reassembled.avcc, frame)
        XCTAssertTrue(reassembled.keyframe)
        XCTAssertFalse(reassembled.crisp)
    }

    func testMultiFragmentFrameRoundTripsInOrder() throws {
        var packetizer = VideoPacketizer()
        // A frame larger than several MTUs.
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 3 + 17])
        let fragments = packetizer.packetize(frame: frame, keyframe: false)
        XCTAssertGreaterThan(fragments.count, 1)
        // Every fragment payload is within the MTU budget.
        for fragment in fragments {
            XCTAssertLessThanOrEqual(fragment.encode().count, VideoPacketizer.maxDatagramSize)
            XCTAssertEqual(fragment.header.fragCount, UInt16(fragments.count))
        }

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            if case .completed(let frame) = reassembler.ingest(fragment) { completed = frame }
        }
        XCTAssertEqual(completed?.avcc, frame)
    }

    func testFragmentsRoundTripThroughWireEncodeDecode() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 200, 40])
        let fragments = packetizer.packetize(frame: frame, keyframe: true, crisp: true)

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            // Serialise → parse, exactly like a UDP send/receive.
            let datagram = fragment.encode()
            let parsed = try FrameFragment.decode(datagram)
            XCTAssertEqual(parsed, fragment)
            if case .completed(let f) = reassembler.ingest(parsed) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.crisp, true)
        XCTAssertEqual(completed?.keyframe, true)
    }

    func testReorderedFragmentsStillReassemble() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 5])
        var fragments = packetizer.packetize(frame: frame, keyframe: false)
        fragments.reverse() // worst-case reorder

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
    }

    func testStreamSequenceNumbersAreMonotonic() {
        var packetizer = VideoPacketizer()
        let frameA = packetizer.packetize(frame: makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 10]), keyframe: true)
        let frameB = packetizer.packetize(frame: makeAVCC(naluSizes: [30]), keyframe: false)
        let allSeqs = (frameA + frameB).map(\.header.streamSeq)
        XCTAssertEqual(allSeqs, Array(0 ..< UInt32(allSeqs.count)))
        // Frame IDs increment per frame.
        XCTAssertEqual(frameA[0].header.frameID, 0)
        XCTAssertEqual(frameB[0].header.frameID, 1)
    }

    /// NO FEC: losing a fragment of an OLDER frame, then a NEWER frame's fragment
    /// arriving, must DROP the older frame and signal recovery (doc 17 §3.6).
    func testFragmentLossWithoutFECDropsFrameAndSignalsRecovery() throws {
        var packetizer = VideoPacketizer()
        let lostFrame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 5]) // 3 fragments
        let frame0 = packetizer.packetize(frame: lostFrame, keyframe: true)
        XCTAssertGreaterThanOrEqual(frame0.count, 3)
        let nextFrame = makeAVCC(naluSizes: [30])
        let frame1 = packetizer.packetize(frame: nextFrame, keyframe: false)

        var reassembler = FrameReassembler()
        // Deliver frame0 MISSING its middle fragment.
        XCTAssertEqual(reassembler.ingest(frame0[0]), .incomplete)
        // skip frame0[1] (lost)
        _ = reassembler.ingest(frame0[2])
        XCTAssertNil(reassembler.nextDroppedFrame(), "no drop until a newer frame proves frame0 hopeless")

        // A fragment from the NEWER frame arrives → frame0 is now hopeless. The newer
        // frame completes; the older frame's loss is surfaced via the drop queue so a
        // completed newer frame never hides the older loss (recovery is still signaled).
        let result = reassembler.ingest(frame1[0])
        XCTAssertEqual(result, .completed(ReassembledFrame(frameID: frame1[0].header.frameID, keyframe: false, crisp: false, avcc: nextFrame)))
        let droppedID = reassembler.nextDroppedFrame()
        XCTAssertEqual(droppedID, frame0[0].header.frameID, "frame0 is signaled as dropped for recovery")
        XCTAssertNil(reassembler.nextDroppedFrame(), "exactly one drop queued")
    }

    func testStaleFragmentForRetiredFrameIsIgnored() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [40])
        let fragments = packetizer.packetize(frame: frame, keyframe: true)
        var reassembler = FrameReassembler()
        _ = reassembler.ingest(fragments[0]) // completes & retires
        // A duplicate (late) datagram for the same frame is stale, not a re-complete.
        XCTAssertEqual(reassembler.ingest(fragments[0]), .stale)
    }

    func testCorruptDatagramThrowsNotCrashes() {
        // A datagram claiming a payload longer than its bytes must throw .truncated.
        var bytes = Data()
        bytes.appendBE(UInt32(0))   // streamSeq
        bytes.appendBE(UInt32(0))   // frameID
        bytes.appendBE(UInt16(0))   // fragIndex
        bytes.appendBE(UInt16(1))   // fragCount
        bytes.append(0)             // flags
        bytes.appendBE(UInt16(500)) // payloadLength = 500 but no payload follows
        XCTAssertThrowsError(try FrameFragment.decode(bytes)) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
    }

    func testZeroByteFrameOccupiesOneFragment() throws {
        var packetizer = VideoPacketizer()
        let fragments = packetizer.packetize(frame: Data(), keyframe: true)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].payload.count, 0)
        var reassembler = FrameReassembler()
        guard case .completed(let frame) = reassembler.ingest(fragments[0]) else {
            return XCTFail("empty frame should complete")
        }
        XCTAssertEqual(frame.avcc.count, 0)
    }
}
