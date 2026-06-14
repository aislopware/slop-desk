import XCTest
@testable import AislopdeskVideoProtocol

/// Packetize / reassemble round-trips, fragment-loss detection, and the FEC-less
/// drop+recovery path. (FEC recovery is exercised in FECTests / reassembler-with-FEC.)
final class FramePacketizerTests: XCTestCase {
    /// Builds an AVCC frame of `naluSizes` NAL units with deterministic content.
    private func makeAVCC(naluSizes: [Int]) -> Data {
        let units = naluSizes.enumerated().map { i, size in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ i &* 7) })
        }
        return NALUnit.join(units)
    }

    func testSingleFragmentFrameRoundTrips() {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [50]) // well under MTU
        let fragments = packetizer.packetize(frame: frame, keyframe: true)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertTrue(fragments[0].header.flags.contains(.keyframe))
        XCTAssertEqual(fragments[0].header.fragCount, 1)

        var reassembler = FrameReassembler()
        let result = reassembler.ingest(fragments[0])
        guard case let .completed(reassembled) = result else {
            XCTFail("expected completed, got \(result)")
            return
        }
        XCTAssertEqual(reassembled.avcc, frame)
        XCTAssertTrue(reassembled.keyframe)
        XCTAssertFalse(reassembled.crisp)
        XCTAssertFalse(reassembled.isLTR, "no isLTR by default")
    }

    // MARK: WF-8 isLTR flag (bit 6)

    /// An LTR-flagged frame round-trips bit 6 through wire encode/decode and reassembly: every
    /// fragment carries `.isLTR`, and the completed frame reports `isLTR == true` so the client knows
    /// to ack it. A multi-fragment frame proves the flag rides every fragment (not just the first).
    func testIsLTRFlagRoundTripsThroughWireAndReassembly() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 200, 40]) // > 1 fragment
        let fragments = packetizer.packetize(frame: frame, keyframe: false, isLTR: true)
        XCTAssertGreaterThan(fragments.count, 1)
        for fragment in fragments {
            // Survives a full wire encode→decode.
            let decoded = try FrameFragment.decode(fragment.encode())
            XCTAssertTrue(decoded.header.flags.contains(.isLTR), "every fragment carries bit 6")
        }
        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            let wire = try FrameFragment.decode(fragment.encode())
            if case let .completed(f) = reassembler.ingest(wire) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.isLTR, true, "the reassembled frame is marked an LTR frame")
    }

    // MARK: ackedAnchored flag (bit 7, 2026-06-12)

    /// A `ForceLTRRefresh` product round-trips bit 7 through wire encode/decode and reassembly —
    /// every fragment carries `.ackedAnchored`, the completed frame reports it, and bit 6 rides
    /// independently (a refresh is BOTH an LTR frame and acked-anchored).
    func testAckedAnchoredFlagRoundTripsThroughWireAndReassembly() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 200, 40]) // > 1 fragment
        let fragments = packetizer.packetize(frame: frame, keyframe: false, isLTR: true, ackedAnchored: true)
        XCTAssertGreaterThan(fragments.count, 1)
        for fragment in fragments {
            let decoded = try FrameFragment.decode(fragment.encode())
            XCTAssertTrue(decoded.header.flags.contains(.ackedAnchored), "every fragment carries bit 7")
            XCTAssertTrue(decoded.header.flags.contains(.isLTR), "bit 6 rides independently")
        }
        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            let wire = try FrameFragment.decode(fragment.encode())
            if case let .completed(f) = reassembler.ingest(wire) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.ackedAnchored, true)
        XCTAssertEqual(completed?.isLTR, true)
    }

    /// Ordinary frames leave bit 7 zero (byte-identical to omitting the argument) and the
    /// reassembled frame reports `ackedAnchored == false` — plus bit 7 never collides with the
    /// FEC tier bits / bit 6.
    func testAckedAnchoredOffIsByteIdenticalAndDisjoint() {
        var p1 = VideoPacketizer()
        var p2 = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [200])
        let omitted = p1.packetize(frame: frame, keyframe: false, fecTier: 2, isLTR: true)
        let explicitOff = p2.packetize(frame: frame, keyframe: false, fecTier: 2, isLTR: true, ackedAnchored: false)
        XCTAssertEqual(omitted.map { $0.encode() }, explicitOff.map { $0.encode() })
        for fragment in omitted {
            XCTAssertFalse(fragment.header.flags.contains(.ackedAnchored))
            XCTAssertEqual(fragment.header.flags.rawValue & 0x80, 0, "bit 7 (0x80) is zero")
            XCTAssertEqual(fragment.header.flags.fecTier, 2, "tier bits undisturbed")
        }
    }

    /// The OFF path is byte-identical: `isLTR: false` (the default) leaves bit 6 zero, the flags byte
    /// is identical to omitting the argument, and the reassembled frame reports `isLTR == false`. This
    /// is the wire-byte-equality guarantee for `AISLOPDESK_LTR` off.
    func testIsLTROffIsByteIdentical() {
        var p1 = VideoPacketizer()
        var p2 = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 200, 40])
        let omitted = p1.packetize(frame: frame, keyframe: true, crisp: true)
        let explicitOff = p2.packetize(frame: frame, keyframe: true, crisp: true, isLTR: false)
        XCTAssertEqual(
            omitted.map { $0.encode() },
            explicitOff.map { $0.encode() },
            "isLTR:false is byte-identical to omitting it",
        )
        for fragment in omitted {
            XCTAssertFalse(fragment.header.flags.contains(.isLTR), "bit 6 clear when off")
            XCTAssertEqual(fragment.header.flags.rawValue & 0x40, 0, "bit 6 (0x40) is zero")
        }
        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in omitted {
            if case let .completed(f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertEqual(completed?.isLTR, false)
    }

    /// isLTR is disjoint from keyframe/crisp/FEC-tier: a keyframe+crisp+isLTR frame on a non-zero tier
    /// preserves every bit independently through the wire.
    func testIsLTRIsDisjointFromOtherFlagBits() throws {
        var packetizer = VideoPacketizer(fec: XORParityFEC(groupSize: 4))
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 11])
        let fragments = packetizer.packetize(frame: frame, keyframe: true, crisp: true, fecTier: 1, isLTR: true)
        // The data fragments carry keyframe+crisp+isLTR+tier1; assert all coexist on at least the first.
        let head = try FrameFragment.decode(fragments[0].encode())
        XCTAssertTrue(head.header.flags.contains(.keyframe))
        XCTAssertTrue(head.header.flags.contains(.crisp))
        XCTAssertTrue(head.header.flags.contains(.isLTR))
        XCTAssertEqual(head.header.flags.fecTier, 1, "tier bits 3-5 intact alongside isLTR bit 6")
    }

    func testMultiFragmentFrameRoundTripsInOrder() {
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
            if case let .completed(frame) = reassembler.ingest(fragment) { completed = frame }
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
            if case let .completed(f) = reassembler.ingest(parsed) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.crisp, true)
        XCTAssertEqual(completed?.keyframe, true)
    }

    func testReorderedFragmentsStillReassemble() {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 5])
        var fragments = packetizer.packetize(frame: frame, keyframe: false)
        fragments.reverse() // worst-case reorder

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for fragment in fragments {
            if case let .completed(f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
    }

    func testStreamSequenceNumbersAreMonotonic() {
        var packetizer = VideoPacketizer()
        let frameA = packetizer.packetize(
            frame: makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 10]),
            keyframe: true,
        )
        let frameB = packetizer.packetize(frame: makeAVCC(naluSizes: [30]), keyframe: false)
        let allSeqs = (frameA + frameB).map(\.header.streamSeq)
        XCTAssertEqual(allSeqs, Array(0..<UInt32(allSeqs.count)))
        // Frame IDs increment per frame.
        XCTAssertEqual(frameA[0].header.frameID, 0)
        XCTAssertEqual(frameB[0].header.frameID, 1)
    }

    /// NO FEC: losing a fragment of an OLDER frame, then a NEWER frame's fragment
    /// arriving, must DROP the older frame and signal recovery (doc 17 §3.6).
    func testFragmentLossWithoutFECDropsFrameAndSignalsRecovery() {
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
        XCTAssertEqual(
            result,
            .completed(ReassembledFrame(
                frameID: frame1[0].header.frameID,
                keyframe: false,
                crisp: false,
                avcc: nextFrame,
            )),
        )
        let droppedID = reassembler.nextDroppedFrame()
        XCTAssertEqual(droppedID, frame0[0].header.frameID, "frame0 is signaled as dropped for recovery")
        XCTAssertNil(reassembler.nextDroppedFrame(), "exactly one drop queued")
    }

    func testStaleFragmentForRetiredFrameIsIgnored() {
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
        bytes.appendBE(UInt32(0)) // streamSeq
        bytes.appendBE(UInt32(0)) // frameID
        bytes.appendBE(UInt16(0)) // fragIndex
        bytes.appendBE(UInt16(1)) // fragCount
        bytes.append(0) // flags
        bytes.appendBE(UInt16(500)) // payloadLength = 500 but no payload follows
        XCTAssertThrowsError(try FrameFragment.decode(bytes)) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
    }

    func testZeroByteFrameOccupiesOneFragment() {
        var packetizer = VideoPacketizer()
        let fragments = packetizer.packetize(frame: Data(), keyframe: true)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].payload.count, 0)
        var reassembler = FrameReassembler()
        guard case let .completed(frame) = reassembler.ingest(fragments[0]) else {
            XCTFail("empty frame should complete")
            return
        }
        XCTAssertEqual(frame.avcc.count, 0)
    }
}
