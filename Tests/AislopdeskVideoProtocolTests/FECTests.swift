import XCTest
@testable import AislopdeskVideoProtocol

/// FEC must demonstrate REAL recovery (per the spec — not faked). These tests prove
/// a single lost fragment per group is reconstructed byte-for-byte, both directly on
/// the `XORParityFEC` and end-to-end through the reassembler.
final class FECTests: XCTestCase {

    private func frag(_ seed: UInt8, _ size: Int) -> Data {
        Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    func testTwentyPercentOverheadWithGroupSizeFive() {
        let fec = XORParityFEC(groupSize: 5)
        XCTAssertEqual(fec.groupSize, 5)
        let data = (0 ..< 10).map { frag(UInt8($0), 100) }
        let parity = fec.parity(forDataFragments: data)
        // 10 data fragments / group 5 = 2 parity fragments = 20% overhead.
        XCTAssertEqual(parity.count, 2)
    }

    func testRecoversSingleLossInEachGroupExactly() {
        let fec = XORParityFEC(groupSize: 3)
        let data = (0 ..< 6).map { frag(UInt8($0 &* 11), 80) }
        let parity = fec.parity(forDataFragments: data)
        XCTAssertEqual(parity.count, 2)

        // Lose fragment 1 (group 0) and fragment 4 (group 1) — one per group.
        var received: [Data?] = data
        received[1] = nil
        received[4] = nil

        let recovered = fec.recover(dataFragments: received, parityFragments: parity)
        XCTAssertEqual(recovered.compactMap { $0 }.count, 6, "all fragments recovered")
        XCTAssertEqual(recovered, data, "recovered bytes match the originals exactly")
    }

    func testRecoversLossOfDifferentlySizedFragments() {
        // The last fragment of a frame is usually shorter; the length-prefixed XOR
        // must still recover the exact original (incl. its true length).
        let fec = XORParityFEC(groupSize: 4)
        let data = [frag(1, 200), frag(2, 200), frag(3, 200), frag(4, 37)] // last is short
        let parity = fec.parity(forDataFragments: data)

        // Lose the short last fragment.
        var received: [Data?] = data
        received[3] = nil
        let recovered = fec.recover(dataFragments: received, parityFragments: parity)
        XCTAssertEqual(recovered[3], data[3])
        XCTAssertEqual(recovered[3]?.count, 37)
    }

    func testTwoLossesInOneGroupAreUnrecoverable() {
        let fec = XORParityFEC(groupSize: 4)
        let data = (0 ..< 4).map { frag(UInt8($0), 50) }
        let parity = fec.parity(forDataFragments: data)
        var received: [Data?] = data
        received[0] = nil
        received[2] = nil // two in the same group → XOR cannot recover
        let recovered = fec.recover(dataFragments: received, parityFragments: parity)
        XCTAssertNil(recovered[0])
        XCTAssertNil(recovered[2])
    }

    func testNoLossLeavesDataUnchanged() {
        let fec = XORParityFEC(groupSize: 5)
        let data = (0 ..< 7).map { frag(UInt8($0), 64) }
        let parity = fec.parity(forDataFragments: data)
        let recovered = fec.recover(dataFragments: data.map { $0 }, parityFragments: parity)
        XCTAssertEqual(recovered.compactMap { $0 }, data)
    }

    /// End-to-end: packetize WITH FEC, lose ONE data fragment, and the reassembler
    /// recovers the frame (no drop). This is the real recovery the spec demands.
    func testReassemblerRecoversSingleLostDataFragmentViaFEC() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        // A frame spanning a few fragments so there is a real group to repair.
        let units = [Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 333)).map { UInt8(truncatingIfNeeded: $0) })]
        let frame = NALUnit.join(units)
        let fragments = packetizer.packetize(frame: frame, keyframe: true)

        let dataFragments = fragments.filter { !$0.header.flags.contains(.parity) }
        let parityFragments = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertGreaterThanOrEqual(dataFragments.count, 2)
        XCTAssertGreaterThanOrEqual(parityFragments.count, 1)

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?
        // Deliver all data fragments EXCEPT the first one (lost), then the parity.
        for fragment in dataFragments.dropFirst() {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        for fragment in parityFragments {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed, "FEC should recover the single lost data fragment")
        XCTAssertEqual(completed?.avcc, frame, "recovered frame matches original exactly")
    }

    /// REALISTIC REORDER: the packetizer emits parity LAST within a frame, so on a
    /// reordering UDP network frame N's parity is exactly the fragment most likely to
    /// arrive AFTER frame N+1's data has begun. With the bounded FEC reorder grace, a
    /// single-loss frame whose parity is reordered past the next frame must still
    /// recover (NOT be swept/dropped). This is the case the rest of the suite never
    /// exercised (it always delivered parity BEFORE the next frame).
    func testReassemblerRecoversWhenParityReorderedAfterNextFrame() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) })])
        let frame0 = packetizer.packetize(frame: frameBytes, keyframe: true)
        let frame1 = packetizer.packetize(frame: NALUnit.join([Data([9, 8, 7])]), keyframe: false)

        let data0 = frame0.filter { !$0.header.flags.contains(.parity) }
        let parity0 = frame0.filter { $0.header.flags.contains(.parity) }
        XCTAssertGreaterThanOrEqual(data0.count, 2)
        XCTAssertGreaterThanOrEqual(parity0.count, 1)

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?

        // 1) frame 0 data arrives EXCEPT the first fragment (lost).
        for fragment in data0.dropFirst() {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNil(completed, "frame 0 still missing its first data fragment")

        // 2) frame 1's data arrives — this advances the loss frontier PAST frame 0.
        //    The naive sweep would drop frame 0 here; the grace must keep it eligible.
        for fragment in frame1 {
            _ = reassembler.ingest(fragment)
        }
        XCTAssertNil(reassembler.nextDroppedFrame(), "frame 0 must NOT be dropped while within FEC reorder grace")

        // 3) frame 0's parity finally arrives (reordered after frame 1) → recover.
        for fragment in parity0 {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed, "late, reordered parity must still recover frame 0")
        XCTAssertEqual(completed?.frameID, data0[0].header.frameID)
        XCTAssertEqual(completed?.avcc, frameBytes, "recovered frame matches original exactly")
        XCTAssertNil(reassembler.nextDroppedFrame(), "no drop signalled for the recovered frame")
    }

    /// The reorder grace is BOUNDED: if the reordered parity never arrives and the
    /// frontier advances beyond the grace window, the single-loss frame is still
    /// declared dropped (recovery is escalated, not deferred forever).
    func testReassemblerDropsWhenParityExceedsReorderGrace() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) })])
        let frame0 = packetizer.packetize(frame: frameBytes, keyframe: true)

        let data0 = frame0.filter { !$0.header.flags.contains(.parity) }
        // Grace of 1: a single newer frame keeps frame 0 alive; the SECOND newer frame
        // pushes it past the window with parity still absent → dropped.
        var reassembler = FrameReassembler(fec: fec, fecReorderGrace: 1)
        for fragment in data0.dropFirst() { _ = reassembler.ingest(fragment) }

        let f1 = packetizer.packetize(frame: NALUnit.join([Data([1])]), keyframe: false)
        _ = reassembler.ingest(f1[0])
        XCTAssertNil(reassembler.nextDroppedFrame(), "frame 0 still within grace after one newer frame")

        let f2 = packetizer.packetize(frame: NALUnit.join([Data([2])]), keyframe: false)
        _ = reassembler.ingest(f2[0])
        XCTAssertEqual(reassembler.nextDroppedFrame(), data0[0].header.frameID, "frame 0 dropped once parity exceeds the reorder grace")
    }

    /// A frame that is permanently hopeless (>=2 data losses in one group, which XOR
    /// parity cannot repair) is swept IMMEDIATELY when the frontier advances — the
    /// reorder grace applies only to single-hole, parity-repairable frames.
    func testReassemblerDropsPermanentlyHopelessImmediatelyDespiteGrace() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        // 3 data fragments in one group; drop two so parity (one) cannot recover.
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 50)).map { UInt8(truncatingIfNeeded: $0) })])
        let frame0 = packetizer.packetize(frame: frameBytes, keyframe: true)
        let data0 = frame0.filter { !$0.header.flags.contains(.parity) }
        XCTAssertGreaterThanOrEqual(data0.count, 3)

        var reassembler = FrameReassembler(fec: fec, fecReorderGrace: 4)
        // Deliver only the LAST data fragment → first two of the group are missing.
        _ = reassembler.ingest(data0.last!)

        let f1 = packetizer.packetize(frame: NALUnit.join([Data([1])]), keyframe: false)
        _ = reassembler.ingest(f1[0]) // advances frontier past frame 0
        XCTAssertEqual(reassembler.nextDroppedFrame(), data0[0].header.frameID, "two-loss group is unrepairable → dropped immediately, grace does not apply")
    }

    /// FIX #1 (empirically reproduced): the reassembler must NOT trust the lowest
    /// observed parity `fragIndex` as the data boundary when an FEC scheme is present.
    /// The packetizer assigns parity `fragIndex = trueDataCount + groupOrder`, so if the
    /// GROUP-0 parity is lost and a LATER group's parity arrives first, the lowest
    /// surviving parity fragIndex EXCEEDS the true dataCount. The old code set the
    /// boundary to that inflated value, treating a real data fragment as parity → the
    /// frame could never complete even though every data fragment eventually arrived.
    ///
    /// Repro: a 10-data-fragment frame (groupSize 5 → 2 parity groups) delivered as
    /// data[0..8], then GROUP-1 parity (group-0 parity LOST), then data[9]. The frame
    /// MUST complete (it previously returned nil forever — the inflated boundary treated
    /// data[9] as parity). Here NO parity for the group containing the hole arrives until
    /// data[9] itself does, so completion is by all-data-present, not FEC recovery.
    func testFrameCompletesWhenGroup0ParityLostButAllDataArrives() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        // Force EXACTLY 10 data fragments: 10 full-MTU payloads (the 10th carries the rest).
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 9 + 17)).map { UInt8(truncatingIfNeeded: $0) })])
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertEqual(data.count, 10, "frame must split into exactly 10 data fragments")
        XCTAssertEqual(parity.count, 2, "10 data / groupSize 5 = 2 parity groups")

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?

        // 1) data[0..3] arrive (group 0: 0..4) — withhold the group-0 member data[4] so the
        //    GROUP-1 parity, when it lands, cannot prematurely "recover" anything (group 1
        //    is whole-once-data[9]-arrives; group 0 still has a hole that group-1 parity
        //    cannot touch). data[5..8] arrive too (group 1: 5..9, only data[9] withheld).
        for fragment in data where fragment.header.fragIndex != 4 && fragment.header.fragIndex != 9 {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNil(completed, "still missing data[4] and data[9]")

        // 2) GROUP-1 parity arrives FIRST (group-0 parity is LOST). With the OLD off-by-one
        //    this shifted the boundary to fragIndex 11, so data[9] was treated as parity and
        //    the frame could never assemble. Group 1 still has its data[9] hole AND no group-0
        //    parity, so nothing completes yet — but the boundary must stay at 10.
        if case .completed(let f) = reassembler.ingest(parity[1]) { completed = f }
        // Group 1 hole (data[9]) IS repairable by parity[1] now → it recovers; group 0 still
        // missing data[4] with no parity → frame stays incomplete.
        XCTAssertNil(completed, "group-0 still missing data[4] (its parity was lost)")

        // 3) data[4] AND data[9] finally arrive → ALL data present → frame MUST complete.
        for fragment in data where fragment.header.fragIndex == 4 || fragment.header.fragIndex == 9 {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed, "all data arrived; lost group-0 parity must NOT wedge the frame")
        XCTAssertEqual(completed?.avcc, frameBytes, "recovered frame matches original exactly")
        XCTAssertNil(reassembler.nextDroppedFrame(), "a fully-arrived frame is never dropped")
    }

    /// FIX #1 companion: a SINGLE data loss in group 1, recovered by group-1 parity, while
    /// the GROUP-0 parity is lost. The group-0 parity loss is irrelevant (group 0 has no
    /// hole) and must NOT misalign the surviving group-1 parity. Keying parity by GROUP
    /// ORDER means group-1 parity lands at slot 1 (where recover() expects it), not shifted.
    func testGroup1DataLossRecoversWhenGroup0ParityLost() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 9 + 80)).map { UInt8(truncatingIfNeeded: $0) })])
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(parity.count, 2)

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?

        // All data EXCEPT data[7] (a hole in group 1: indices 5..9).
        for fragment in data where fragment.header.fragIndex != 7 {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNil(completed, "group-1 still missing data[7]")

        // GROUP-1 parity arrives; group-0 parity is LOST. The single group-1 hole must be
        // recovered (parity correctly aligned at group order 1).
        if case .completed(let f) = reassembler.ingest(parity[1]) { completed = f }
        XCTAssertNotNil(completed, "group-1 parity must recover data[7] even with group-0 parity lost")
        XCTAssertEqual(completed?.avcc, frameBytes, "recovered frame matches original exactly")
        XCTAssertNil(reassembler.nextDroppedFrame())
    }

    /// With FEC, losing a data fragment AND its group's parity is unrecoverable. With
    /// the reorder grace DISABLED (`fecReorderGrace: 0`, the old immediate-sweep
    /// behavior) the frame is dropped as soon as a newer frame arrives.
    func testReassemblerDropsWhenFECCannotRecover() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frame = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2)).map { UInt8(truncatingIfNeeded: $0) })])
        let frame0 = packetizer.packetize(frame: frame, keyframe: true)
        let next = packetizer.packetize(frame: NALUnit.join([Data([1, 2, 3])]), keyframe: false)

        let data0 = frame0.filter { !$0.header.flags.contains(.parity) }
        // Deliver data fragments except the first, and NO parity → unrecoverable.
        // Grace 0 = the legacy "sweep the instant the frontier advances" behavior.
        var reassembler = FrameReassembler(fec: fec, fecReorderGrace: 0)
        for fragment in data0.dropFirst() { _ = reassembler.ingest(fragment) }
        // The newer single-fragment frame completes; the unrecoverable older frame is
        // surfaced as a drop via the recovery queue.
        let result = reassembler.ingest(next[0])
        if case .completed = result {} else { XCTFail("newer frame should complete, got \(result)") }
        XCTAssertEqual(reassembler.nextDroppedFrame(), data0[0].header.frameID)
    }

    // MARK: WF-4 adaptive FEC — host encodes at a wire tier, the client reads the tier per-frame

    /// A frame sized to split into exactly `target` data fragments (`target-1` full payloads + 1 partial).
    private func adaptiveFrame(dataFragmentTarget target: Int) -> Data {
        NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * (target - 1) + 200)).map { UInt8(truncatingIfNeeded: $0) })])
    }

    /// GOLD AGREEMENT: the host packetizes at `tier` (mapping to `expectedGroupSize`); a SEPARATE
    /// reassembler — configured with the prod default groupSize 5, told NOTHING about the tier — must
    /// derive THIS frame's data/parity split + parity-group mapping from the wire tier alone and
    /// recover a single dropped data fragment. If it used its local g5 it would mis-split and fail.
    private func assertClientRecoversWireSignalledTier(_ tier: UInt8, expectedGroupSize: Int, file: StaticString = #file, line: UInt = #line) throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = adaptiveFrame(dataFragmentTarget: 6)
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true, fecTier: tier)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertEqual(data.count, 6, "frame must split into exactly 6 data fragments", file: file, line: line)
        XCTAssertEqual(parity.count, (6 + expectedGroupSize - 1) / expectedGroupSize, "parity count = ceil(6 / groupSize)", file: file, line: line)
        XCTAssertTrue(fragments.allSatisfy { $0.header.flags.fecTier == tier }, "every fragment carries the SAME tier", file: file, line: line)

        // Reassembler is g5; it must override per-frame from the wire tier (NOT use its local constant).
        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?
        // Drop data[0] (a single loss in group 0); deliver the rest, then all parity → recover.
        for fragment in data.dropFirst() {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNil(completed, "still missing data[0] before parity arrives", file: file, line: line)
        for fragment in parity {
            if case .completed(let f) = reassembler.ingest(fragment) { completed = f }
        }
        XCTAssertNotNil(completed, "wire-signalled tier \(tier) must let the client recover the single loss", file: file, line: line)
        XCTAssertEqual(completed?.avcc, frameBytes, "recovered frame matches the original exactly", file: file, line: line)
        XCTAssertTrue(completed?.recoveredViaFEC ?? false, "completion was via FEC recovery (a hole existed)", file: file, line: line)
        XCTAssertNil(reassembler.nextDroppedFrame(), file: file, line: line)
    }

    func testClientRecoversWireSignalledTierLight() throws { try assertClientRecoversWireSignalledTier(2, expectedGroupSize: 10) }
    func testClientRecoversWireSignalledTierHeavy() throws { try assertClientRecoversWireSignalledTier(3, expectedGroupSize: 3) }
    func testClientRecoversWireSignalledTierSevere() throws { try assertClientRecoversWireSignalledTier(4, expectedGroupSize: 2) }

    /// Tier 0 (the default + gate-off value) is BYTE-IDENTICAL to the pre-WF-4 no-tier packetize: same
    /// flags byte (spare bits zero), same parity shape, same fragCount. This is the gate-off invariant.
    func testTierZeroPacketizeIsByteIdenticalToPreWF4() {
        let fec = XORParityFEC(groupSize: 5)
        var preWF4Packetizer = VideoPacketizer(fec: fec)
        var tier0Packetizer = VideoPacketizer(fec: fec)
        let frame = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2 + 333)).map { UInt8(truncatingIfNeeded: $0) })])
        // Fresh packetizers start at the same streamSeq/frameID, so identical inputs ⇒ identical bytes.
        let preWF4 = preWF4Packetizer.packetize(frame: frame, keyframe: true, crisp: true, hostSendTsMillis: 4242)
        let tier0 = tier0Packetizer.packetize(frame: frame, keyframe: true, crisp: true, hostSendTsMillis: 4242, fecTier: 0)
        XCTAssertEqual(preWF4.map { $0.encode() }, tier0.map { $0.encode() }, "tier 0 must be byte-identical to the no-tier default")
        XCTAssertEqual(
            tier0.filter { $0.header.flags.contains(.parity) }.count,
            preWF4.filter { $0.header.flags.contains(.parity) }.count,
            "tier 0 keeps the g5 parity shape"
        )
    }

    /// OFF tier (tier 1): the host emits ZERO parity (fragCount == dataCount); the client completes on
    /// all-data with `fec` still non-nil — the gate is the PER-FRAME group size, not `fec != nil`.
    func testOffTierEmitsNoParityAndCompletesDataOnly() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = adaptiveFrame(dataFragmentTarget: 4)
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true, fecTier: 1)
        XCTAssertTrue(fragments.allSatisfy { !$0.header.flags.contains(.parity) }, "OFF tier emits NO parity")
        XCTAssertTrue(fragments.allSatisfy { $0.header.flags.fecTier == 1 }, "every fragment carries the OFF tier")
        XCTAssertEqual(fragments.count, 4, "fragCount == dataCount (no parity appended)")

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?
        for f in fragments { if case .completed(let r) = reassembler.ingest(f) { completed = r } }
        XCTAssertNotNil(completed, "an OFF-tier frame completes on all-data even though the client holds a non-nil fec")
        XCTAssertEqual(completed?.avcc, frameBytes)
        XCTAssertFalse(completed?.recoveredViaFEC ?? true, "no FEC recovery on an OFF-tier frame")
    }

    /// OFF tier single loss is unrecoverable (no parity exists) and is dropped the instant the frontier
    /// advances — an OFF frame is granted NO reorder grace (it isn't "awaiting parity").
    func testOffTierSingleLossIsUnrecoverableAndDropped() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frame0bytes = adaptiveFrame(dataFragmentTarget: 4)
        let frame0 = packetizer.packetize(frame: frame0bytes, keyframe: true, fecTier: 1)
        let next = packetizer.packetize(frame: NALUnit.join([Data([1, 2, 3])]), keyframe: false, fecTier: 1)
        XCTAssertEqual(frame0.filter { $0.header.flags.contains(.parity) }.count, 0, "OFF tier: no parity to recover with")

        var reassembler = FrameReassembler(fec: fec) // default grace — proves OFF frames get no grace
        for f in frame0.dropFirst() { _ = reassembler.ingest(f) } // lose data[0]
        let result = reassembler.ingest(next[0])
        if case .completed = result {} else { XCTFail("newer frame should complete, got \(result)") }
        XCTAssertEqual(reassembler.nextDroppedFrame(), frame0[0].header.frameID, "OFF tier single loss is unrecoverable → dropped")
    }

    /// Dropping a PARITY fragment is harmless when every data fragment arrived — the frame completes by
    /// all-data regardless of group size (here tier 3 / g3 with two parity groups, the first dropped).
    func testAdaptiveTierCompletesWhenAParityFragmentIsDropped() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frameBytes = adaptiveFrame(dataFragmentTarget: 6)
        let fragments = packetizer.packetize(frame: frameBytes, keyframe: true, fecTier: 3)
        let data = fragments.filter { !$0.header.flags.contains(.parity) }
        let parity = fragments.filter { $0.header.flags.contains(.parity) }
        XCTAssertEqual(parity.count, 2, "6 data / g3 = 2 parity groups")

        var reassembler = FrameReassembler(fec: fec)
        var completed: ReassembledFrame?
        for f in data { if case .completed(let r) = reassembler.ingest(f) { completed = r } } // all data → completes
        _ = reassembler.ingest(parity[1]) // parity[0] dropped; irrelevant since data is whole
        XCTAssertNotNil(completed, "dropping a parity fragment is harmless when all data arrived")
        XCTAssertEqual(completed?.avcc, frameBytes)
        XCTAssertFalse(completed?.recoveredViaFEC ?? true, "no hole ⇒ not FEC-recovered")
    }
}
