import XCTest
@testable import RworkVideoProtocol

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

    /// With FEC, losing a data fragment AND its group's parity is unrecoverable → the
    /// frame is dropped once a newer frame arrives.
    func testReassemblerDropsWhenFECCannotRecover() throws {
        let fec = XORParityFEC(groupSize: 5)
        var packetizer = VideoPacketizer(fec: fec)
        let frame = NALUnit.join([Data((0 ..< (VideoPacketizer.maxPayloadSize * 2)).map { UInt8(truncatingIfNeeded: $0) })])
        let frame0 = packetizer.packetize(frame: frame, keyframe: true)
        let next = packetizer.packetize(frame: NALUnit.join([Data([1, 2, 3])]), keyframe: false)

        let data0 = frame0.filter { !$0.header.flags.contains(.parity) }
        // Deliver data fragments except the first, and NO parity → unrecoverable.
        var reassembler = FrameReassembler(fec: fec)
        for fragment in data0.dropFirst() { _ = reassembler.ingest(fragment) }
        // The newer single-fragment frame completes; the unrecoverable older frame is
        // surfaced as a drop via the recovery queue.
        let result = reassembler.ingest(next[0])
        if case .completed = result {} else { XCTFail("newer frame should complete, got \(result)") }
        XCTAssertEqual(reassembler.nextDroppedFrame(), data0[0].header.frameID)
    }
}
