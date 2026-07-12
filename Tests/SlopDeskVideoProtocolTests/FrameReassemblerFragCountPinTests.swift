import XCTest
@testable import SlopDeskVideoProtocol

/// `fragCount` must be PINNED from the FIRST fragment seen for a frame,
/// exactly like the `fecTier` pin. Every boundary decision — `resolvedDataCount`, the
/// parity-slot mapping, `canEventuallyComplete`, `assemble`, the hopeless sweep — derives the
/// data/parity split from `fragCount`, so a later fragment for the SAME pending frameID carrying a
/// DIFFERENT fragCount (corrupt or hostile UDP — it passes the per-fragment `fragIndex < fragCount`
/// guard on its own header) must be dropped, not believed:
///
///  * a SHRUNK fragCount silently moves the boundary below already-buffered data → the frame is
///    declared "complete" while real data is still missing (corrupted decoder input) AND the
///    loss-recovery signal for the true hole is suppressed;
///  * a GROWN fragCount wedges the frame (it now waits for fragments that will never exist).
///
/// Untrusted-UDP validate-then-drop: the disagreeing fragment is discarded as `.stale`; the pinned
/// boundary survives and the frame completes/drops exactly as if the corrupt datagram never arrived.
final class FrameReassemblerFragCountPinTests: XCTestCase {
    private func frag(
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        parity: Bool = false,
        keyframe: Bool = false,
        payload: Data = Data([1, 2, 3]),
    ) -> FrameFragment {
        var flags: FrameFragmentHeader.Flags = []
        if parity { flags.insert(.parity) }
        if keyframe { flags.insert(.keyframe) }
        let header = FrameFragmentHeader(
            streamSeq: frameID, frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
            flags: flags, payloadLength: UInt16(payload.count),
        )
        return FrameFragment(header: header, payload: payload)
    }

    /// THE exploit shape: a real fragCount=4 frame has fragments 0/1/2 buffered (3 lost in flight);
    /// a crafted duplicate of fragment 0 carrying fragCount=3 passes the per-fragment guard
    /// (`fragIndex 0 < fragCount 3`) and — unfixed — shrank the boundary so the frame "completed"
    /// with only 3 of its 4 real data fragments. The disagreeing fragment must be dropped and the
    /// pinned boundary must survive: the frame completes only when the REAL fragment 3 arrives, with
    /// all four payloads.
    func testLaterShrunkFragCountIsDroppedAndBoundarySurvives() {
        let r = FrameReassembler() // no FEC: fragCount IS the data boundary
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 0, fragCount: 4, payload: Data([0]))), .incomplete)
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 1, fragCount: 4, payload: Data([1]))), .incomplete)
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 2, fragCount: 4, payload: Data([2]))), .incomplete)

        // Crafted duplicate: same pending frameID, fragCount shrunk 4 → 3.
        let crafted = frag(frameID: 7, fragIndex: 0, fragCount: 3, payload: Data([0]))
        XCTAssertEqual(
            r.ingest(crafted),
            .stale,
            "a fragment whose fragCount disagrees with the pinned count is validate-then-dropped",
        )

        // The pinned boundary survived: the real 4th fragment completes the frame with ALL FOUR
        // real payloads (nothing was retired early, nothing corrupted).
        XCTAssertEqual(
            r.ingest(frag(frameID: 7, fragIndex: 3, fragCount: 4, payload: Data([3]))),
            .completed(ReassembledFrame(frameID: 7, keyframe: false, crisp: false, avcc: Data([0, 1, 2, 3]))),
            "the frame completes at the PINNED fragCount, byte-exact",
        )
        XCTAssertNil(r.nextDroppedFrame(), "no spurious drop for a frame that completed")
    }

    /// Loss signalling survives the shrink attempt: if the real 4th fragment never arrives, the
    /// frame must still be declared LOST once the frontier advances (unfixed, the shrunken boundary
    /// "completed" the frame corrupt and the recovery signal never fired).
    func testShrinkAttemptDoesNotSuppressLossSignalling() {
        let r = FrameReassembler()
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 0, fragCount: 4, payload: Data([0]))), .incomplete)
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 1, fragCount: 4, payload: Data([1]))), .incomplete)
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 2, fragCount: 4, payload: Data([2]))), .incomplete)
        XCTAssertEqual(r.ingest(frag(frameID: 7, fragIndex: 0, fragCount: 3, payload: Data([0]))), .stale)

        // A newer frame advances the loss frontier; frame 7 (no FEC, real hole at fragment 3) is
        // hopeless and must surface as a drop → the LTR-RFI/IDR recovery signal fires.
        if case .completed = r.ingest(frag(frameID: 8, fragIndex: 0, fragCount: 1)) {} else {
            XCTFail("the newer single-fragment frame should complete")
        }
        XCTAssertEqual(
            r.nextDroppedFrame(),
            7,
            "the true loss is still signalled — the crafted shrink must not suppress recovery",
        )
    }

    /// The GROW direction: a crafted fragment with a LARGER fragCount (its fragIndex chosen inside
    /// the inflated range, so the per-fragment guard passes) must not move the boundary either —
    /// unfixed, it wedged the frame waiting for fragments that never exist.
    func testLaterGrownFragCountIsDroppedAndFrameStillCompletes() {
        let r = FrameReassembler()
        XCTAssertEqual(r.ingest(frag(frameID: 3, fragIndex: 0, fragCount: 2, payload: Data([10]))), .incomplete)
        // Crafted: fragCount grown 2 → 6, fragIndex 5 valid against ITS OWN header only.
        XCTAssertEqual(
            r.ingest(frag(frameID: 3, fragIndex: 5, fragCount: 6, payload: Data([99]))),
            .stale,
            "a grown fragCount (and its out-of-pinned-range fragIndex) is dropped",
        )
        XCTAssertEqual(
            r.ingest(frag(frameID: 3, fragIndex: 1, fragCount: 2, payload: Data([11]))),
            .completed(ReassembledFrame(frameID: 3, keyframe: false, crisp: false, avcc: Data([10, 11]))),
            "the frame still completes at the pinned fragCount",
        )
    }

    /// FEC path: the data/parity split and the parity-slot mapping both derive from the pinned
    /// fragCount. A disagreeing fragCount mid-frame must be dropped so late parity still maps to the
    /// right group and recovers the real hole byte-exact.
    func testFECRecoveryStillWorksAfterDisagreeingFragCountDropped() {
        let fec = XORParityFEC(groupSize: 5)
        let packetizer = VideoPacketizer(fec: fec)
        // Exactly 6 data fragments (g5 → 2 parity groups): fragCount = 6 data + 2 parity = 8.
        let frameBytes = NALUnit
            .join([Data((0..<(VideoPacketizer.maxPayloadSize * 5 + 200)).map { UInt8(truncatingIfNeeded: $0) })])
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(parity.count, 2)
        let frameID = data[0].header.frameID
        let pinnedCount = data[0].header.fragCount

        let r = FrameReassembler(fec: fec)
        // data[0] is lost; deliver data[1..5].
        for f in data.dropFirst() { _ = r.ingest(f) }

        // Crafted mid-frame fragment: fragCount off by one (7 ≠ 8), garbage payload at index 0.
        let crafted = frag(frameID: frameID, fragIndex: 0, fragCount: pinnedCount - 1, payload: Data([0xAA]))
        XCTAssertEqual(r.ingest(crafted), .stale, "the disagreeing fragCount is dropped on the FEC path too")

        // Parity arrives (packetizer emits it last) → group-0 hole recovered byte-exact.
        var completed: ReassembledFrame?
        for f in parity {
            if case let .completed(rf) = r.ingest(f) { completed = rf }
        }
        XCTAssertEqual(completed?.avcc, frameBytes, "FEC recovery is intact after the crafted fragment was dropped")
        XCTAssertEqual(completed?.recoveredViaFEC, true, "completion came via FEC (the real hole existed)")
        XCTAssertNil(r.nextDroppedFrame())
    }
}
