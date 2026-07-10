import XCTest
@testable import SlopDeskVideoProtocol

/// BEHAVIOUR PINS for the reassembler's completeness decision, written BEFORE the incremental-
/// counter refactor (audit perf fix: `ingest` ran a full `canEventuallyComplete` group re-scan per
/// received fragment — O(dataCount²) per frame on a multi-thousand-fragment IDR). Completion
/// semantics must be IDENTICAL after the refactor: the same frames complete/drop at the same ingest,
/// byte-identical `ReassemblyResult`. The two counter traps get explicit coverage:
///
///  * DUPLICATES — the same fragIndex arriving twice must never double-count towards completeness
///    (data) or towards a group's surviving-parity budget (parity);
///  * DATA-vs-PARITY accounting — parity fragments repair budgets per GROUP; they never count as
///    data, and a partial trailing group keeps its own (smaller) hole budget.
final class FrameReassemblerCompletenessPinTests: XCTestCase {
    private func frag(
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        payload: Data,
    ) -> FrameFragment {
        let header = FrameFragmentHeader(
            streamSeq: frameID, frameID: frameID, fragIndex: fragIndex, fragCount: fragCount,
            flags: [], payloadLength: UInt16(payload.count),
        )
        return FrameFragment(header: header, payload: payload)
    }

    /// A frame splitting into exactly `dataFragments` full-MTU data fragments (the
    /// MultiLossFECActivationTests recipe: one NAL per fragment, minus the 4-byte AVCC prefix).
    private func multiFragmentFrame(dataFragments: Int) -> Data {
        let nalSize = VideoPacketizer.maxPayloadSize - 4
        return NALUnit.join((0..<dataFragments).map { i in
            Data((0..<nalSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i &* 17 &+ 7) })
        })
    }

    private func splitDataParity(_ frags: [FrameFragment]) -> (data: [FrameFragment], parity: [FrameFragment]) {
        (
            frags.filter { !$0.header.flags.contains(.parity) }.sorted { $0.header.fragIndex < $1.header.fragIndex },
            frags.filter { $0.header.flags.contains(.parity) }.sorted { $0.header.fragIndex < $1.header.fragIndex },
        )
    }

    // MARK: full frame, in order / out of order

    /// In-order arrival: `.incomplete` for every fragment but the last, `.completed` exactly at the
    /// last, byte-exact concatenation. 40 fragments so the counters cross several groups.
    func testInOrderFrameCompletesExactlyOnLastFragment() {
        let r = FrameReassembler()
        let count: UInt16 = 40
        var expected = Data()
        for i in 0..<count {
            let payload = Data([UInt8(i), UInt8(i) &* 3, 0xC0])
            expected.append(payload)
            let result = r.ingest(frag(frameID: 1, fragIndex: i, fragCount: count, payload: payload))
            if i < count - 1 {
                XCTAssertEqual(result, .incomplete, "fragment \(i) of \(count) must not complete the frame")
            } else {
                XCTAssertEqual(
                    result,
                    .completed(ReassembledFrame(frameID: 1, keyframe: false, crisp: false, avcc: expected)),
                    "completion fires exactly at the last fragment, byte-exact",
                )
            }
        }
        XCTAssertNil(r.nextDroppedFrame())
    }

    /// Out-of-order arrival completes at the last MISSING fragment (not the highest index).
    func testOutOfOrderArrivalCompletesOnLastMissingFragment() {
        let r = FrameReassembler()
        let payloads: [Data] = [Data([0]), Data([1]), Data([2]), Data([3])]
        for i in [3, 0, 2] {
            XCTAssertEqual(
                r.ingest(frag(frameID: 5, fragIndex: UInt16(i), fragCount: 4, payload: payloads[i])),
                .incomplete,
            )
        }
        XCTAssertEqual(
            r.ingest(frag(frameID: 5, fragIndex: 1, fragCount: 4, payload: payloads[1])),
            .completed(ReassembledFrame(frameID: 5, keyframe: false, crisp: false, avcc: Data([0, 1, 2, 3]))),
            "reordered fragments reassemble in index order, byte-exact",
        )
    }

    // MARK: duplicates — THE incremental-counter trap

    /// The same data fragIndex arriving twice must NOT count twice: 3 ingests of a fragCount-3 frame
    /// where one is a duplicate leave the frame incomplete; the true 3rd index completes it. The
    /// duplicate's payload OVERWRITES the slot (existing last-write-wins semantics, pinned here).
    func testDuplicateDataFragmentDoesNotDoubleCount() {
        let r = FrameReassembler()
        XCTAssertEqual(r.ingest(frag(frameID: 2, fragIndex: 0, fragCount: 3, payload: Data([1]))), .incomplete)
        XCTAssertEqual(
            r.ingest(frag(frameID: 2, fragIndex: 0, fragCount: 3, payload: Data([9]))),
            .incomplete,
            "duplicate fragIndex 0 must not advance completeness",
        )
        XCTAssertEqual(r.ingest(frag(frameID: 2, fragIndex: 1, fragCount: 3, payload: Data([2]))), .incomplete)
        XCTAssertEqual(
            r.ingest(frag(frameID: 2, fragIndex: 2, fragCount: 3, payload: Data([3]))),
            .completed(ReassembledFrame(
                frameID: 2, keyframe: false, crisp: false,
                avcc: Data([9, 2, 3]), // last-write-wins on the duplicated slot
            )),
            "completion needs all three DISTINCT indices; the dup overwrote slot 0",
        )
    }

    /// Duplicate PARITY must not double-count a group's surviving-parity budget. m=2/k=5: one group
    /// loses TWO data fragments but only ONE of its two parity shards survives — delivered TWICE.
    /// The frame is genuinely unrecoverable (2 holes > 1 surviving shard); a double-counted survivor
    /// would claim "recoverable now" forever and the frame would wedge un-dropped. It must instead be
    /// dropped once the frontier passes the FEC reorder grace.
    func testDuplicateParityDoesNotDoubleCountSurvivingBudget() {
        let k = 5
        let m = 2
        let fec = RustReedSolomonFEC(groupSize: k, parityCount: m)
        let packetizer = VideoPacketizer(fec: fec)
        let frame0 = packetizer.packetize(frame: multiFragmentFrame(dataFragments: k), keyframe: true)
        let (data, parity) = splitDataParity(frame0)
        XCTAssertEqual(data.count, k)
        XCTAssertEqual(parity.count, m, "one group of k ⇒ m parity shards")
        let frameID = data[0].header.frameID

        let r = FrameReassembler(fec: fec, fecReorderGrace: 1)
        // Lose data[0] AND data[1] (2 holes) plus parity shard 1: only parity shard 0 survives.
        for f in data.dropFirst(2) { XCTAssertEqual(r.ingest(f), .incomplete) }
        XCTAssertEqual(r.ingest(parity[0]), .incomplete)
        XCTAssertEqual(r.ingest(parity[0]), .incomplete, "the DUPLICATE surviving shard changes nothing")

        // Advance the frontier past the reorder grace: two newer frames.
        for _ in 0..<2 {
            let next = packetizer.packetize(frame: NALUnit.join([Data([7])]), keyframe: false)
            _ = r.ingest(next[0])
        }
        XCTAssertEqual(
            r.nextDroppedFrame(),
            frameID,
            "2 holes vs 1 surviving shard is unrecoverable — a double-counted duplicate must not wedge the frame",
        )
    }

    // MARK: FEC recoverable / unrecoverable

    /// FEC-recoverable single loss per group (m=1): completion fires exactly when the covering
    /// parity arrives, byte-exact, flagged `recoveredViaFEC`.
    func testFECRecoverableLossCompletesOnCoveringParity() {
        let fec = XORParityFEC(groupSize: 5)
        let packetizer = VideoPacketizer(fec: fec)
        let frameBytes = multiFragmentFrame(dataFragments: 10) // 2 groups of 5
        let (data, parity) = splitDataParity(packetizer.packetize(frame: frameBytes, keyframe: true))
        XCTAssertEqual(parity.count, 2)

        let r = FrameReassembler(fec: fec)
        // Lose data[7] (group 1); deliver everything else, group-0 parity first.
        for f in data where f.header.fragIndex != 7 { XCTAssertEqual(r.ingest(f), .incomplete) }
        XCTAssertEqual(r.ingest(parity[0]), .incomplete, "group-0 parity cannot repair the group-1 hole")
        guard case let .completed(rf) = r.ingest(parity[1]) else {
            XCTFail("group-1 parity must complete the frame via FEC recovery")
            return
        }
        XCTAssertEqual(rf.avcc, frameBytes, "recovered frame is byte-identical")
        XCTAssertTrue(rf.recoveredViaFEC)
        XCTAssertNil(r.nextDroppedFrame())
    }

    /// A PARTIAL trailing group (10 data at g4 → sizes 4,4,2) keeps its own budget: losing its one
    /// remaining hole's parity → unrecoverable → swept once past the grace. Pins the partial-group
    /// accounting the counters must reproduce.
    func testPartialTrailingGroupLossIsSweptAfterGrace() {
        let fec = XORParityFEC(groupSize: 4)
        let packetizer = VideoPacketizer(fec: fec)
        let frame0 = packetizer.packetize(frame: multiFragmentFrame(dataFragments: 10), keyframe: true)
        let (data, parity) = splitDataParity(frame0)
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(parity.count, 3, "groups 0..3, 4..7, 8..9")
        let frameID = data[0].header.frameID

        let r = FrameReassembler(fec: fec, fecReorderGrace: 1)
        // Lose data[9] (the partial group 8..9) AND its parity[2]; everything else arrives.
        for f in data where f.header.fragIndex != 9 { _ = r.ingest(f) }
        _ = r.ingest(parity[0])
        _ = r.ingest(parity[1])
        XCTAssertNil(r.nextDroppedFrame(), "still awaiting the trailing group's parity within grace")

        for _ in 0..<2 {
            let next = packetizer.packetize(frame: NALUnit.join([Data([3])]), keyframe: false)
            _ = r.ingest(next[0])
        }
        XCTAssertEqual(r.nextDroppedFrame(), frameID, "partial-group hole with lost parity → dropped past grace")
    }

    // MARK: retransmit (NACK / selective-ARQ) grace

    /// With retransmit enabled, a small FEC-unrecoverable loss is HELD (not dropped), surfaced ONCE
    /// via `nextNeedsRetransmit()` with the exact missing data indices, and the retransmitted
    /// fragment then completes the frame byte-exact.
    func testRetransmitGraceHoldsNACKsOnceAndCompletesOnResend() {
        let packetizer = VideoPacketizer() // no FEC: any hole is FEC-unrecoverable
        let frameBytes = multiFragmentFrame(dataFragments: 4)
        let (data, _) = splitDataParity(packetizer.packetize(frame: frameBytes, keyframe: true))
        XCTAssertEqual(data.count, 4)
        let frameID = data[0].header.frameID

        let r = FrameReassembler()
        r.enableRetransmit(grace: 8, maxFrags: 8)
        for f in data where f.header.fragIndex != 1 { XCTAssertEqual(r.ingest(f), .incomplete) }

        // A newer frame advances the frontier → the loss is NACKed and the frame HELD, not dropped.
        let next = packetizer.packetize(frame: NALUnit.join([Data([1])]), keyframe: false)
        _ = r.ingest(next[0])
        let nack = r.nextNeedsRetransmit()
        XCTAssertEqual(nack?.frameID, frameID)
        XCTAssertEqual(nack?.frags, [1], "exactly the missing data index is requested")
        XCTAssertNil(r.nextNeedsRetransmit(), "the NACK is surfaced once")
        XCTAssertNil(r.nextDroppedFrame(), "held for retransmit, not dropped")

        // Another newer frame inside the window must NOT re-NACK or drop the held frame.
        let next2 = packetizer.packetize(frame: NALUnit.join([Data([2])]), keyframe: false)
        _ = r.ingest(next2[0])
        XCTAssertNil(r.nextNeedsRetransmit(), "no duplicate NACK for an already-requested frame")
        XCTAssertNil(r.nextDroppedFrame())

        // The host retransmits the missing fragment → the frame completes byte-exact.
        guard case let .completed(rf) = r.ingest(data[1]) else {
            XCTFail("the retransmitted fragment must complete the held frame")
            return
        }
        XCTAssertEqual(rf.avcc, frameBytes)
        XCTAssertFalse(rf.recoveredViaFEC, "completed by the real data fragment, not FEC")
    }
}
