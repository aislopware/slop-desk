import XCTest
@testable import AislopdeskVideoProtocol

/// PURE transmission-interleave tests (2026-06-08 flicker fix). Proves the column-major reorder turns
/// an adjacent-loss BURST — which single-loss XOR FEC cannot recover when fragments are sent in
/// consecutive group order — into spread loss that IS recoverable, with NO wire/protocol change
/// (the reassembler reconstructs identically regardless of send order).
final class FragmentInterleaverTests: XCTestCase {
    private let groupSize = 5

    /// A frame whose AVCC bytes fragment into ~23 data fragments (5 groups: 5,5,5,5,3) + 5 parity.
    private func makeFrameBytes(_ n: Int = 27000) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func packetized() -> [FrameFragment] {
        var p = VideoPacketizer(fec: XORParityFEC(groupSize: groupSize))
        return p.packetize(frame: makeFrameBytes(), keyframe: true)
    }

    private func group(of f: FrameFragment) -> Int { Int(f.header.fragIndex) / groupSize }
    private func isData(_ f: FrameFragment) -> Bool { !f.header.flags.contains(.parity) }

    // The interleaved output is a PERMUTATION — same fragments, every fragIndex preserved.
    func testIsPermutation() {
        let frags = packetized()
        let out = FragmentInterleaver.interleave(frags, groupSize: groupSize)
        XCTAssertEqual(out.count, frags.count)
        XCTAssertEqual(Set(out.map(\.header.fragIndex)), Set(frags.map(\.header.fragIndex)))
        XCTAssertEqual(out.map(\.header.fragIndex).sorted(), frags.map(\.header.fragIndex).sorted())
    }

    // Data still precedes parity (doc 17 §3.6: lossless client decodes before parity; parity LAST).
    func testDataPrecedesParity() {
        let out = FragmentInterleaver.interleave(packetized(), groupSize: groupSize)
        let firstParity = out.firstIndex { !isData($0) } ?? out.count
        let lastData = out.lastIndex { isData($0) } ?? -1
        XCTAssertLessThan(lastData, firstParity, "no data fragment appears after a parity fragment")
    }

    // The core guarantee, stated honestly: the MIN wire distance between two emissions of the same
    // group = the longest adjacent-loss burst guaranteed to spread one-per-group (→ FEC-recoverable).
    // It is `numGroups` when data divides evenly, else `numGroups − 1` (a partial last group shortens
    // the trailing ranks). Either way every adjacent pair differs and bursts up to numGroups−1 recover.
    func testBurstResilienceSpacing() {
        let out = FragmentInterleaver.interleave(packetized(), groupSize: groupSize)
        let dataOut = out.filter(isData)
        let dataCount = dataOut.count
        let numGroups = (dataCount + groupSize - 1) / groupSize
        var lastPos: [Int: Int] = [:]
        var minSpacing = Int.max
        for (pos, f) in dataOut.enumerated() {
            let g = group(of: f)
            if let prev = lastPos[g] { minSpacing = min(minSpacing, pos - prev) }
            lastPos[g] = pos
        }
        let expected = dataCount.isMultiple(of: groupSize) ? numGroups : numGroups - 1
        XCTAssertEqual(minSpacing, expected, "guaranteed recoverable adjacent-burst length")
        XCTAssertGreaterThanOrEqual(minSpacing, numGroups - 1)
    }

    // GOLD: a burst of 2 ADJACENT wire datagrams dropped → fully recovered after interleave.
    func testBurstOfTwoAdjacentRecovered() throws {
        let frame = makeFrameBytes()
        let out = FragmentInterleaver.interleave(packetized(), groupSize: groupSize)
        // Drop wire positions 1 and 2 (adjacent). Interleaved → two DIFFERENT groups → recoverable.
        let survivors = out.enumerated().filter { $0.offset != 1 && $0.offset != 2 }.map(\.element)
        var r = FrameReassembler(fec: XORParityFEC(groupSize: groupSize))
        var completed: ReassembledFrame?
        for f in survivors {
            if case let .completed(c) = try r.ingest(FrameFragment.decode(f.encode())) { completed = c }
        }
        XCTAssertEqual(completed?.avcc, frame, "interleaved adjacent burst-of-2 fully recovered by FEC")
    }

    // CONTRAST: WITHOUT interleave, the SAME adjacent burst-of-2 lands in ONE group → unrecoverable.
    // (Proves the fix is load-bearing, not cosmetic.)
    func testNonInterleavedAdjacentBurstIsUnrecoverable() throws {
        let frags = packetized() // raw consecutive order: data[0],data[1],… both in group 0
        let survivors = frags.enumerated().filter { $0.offset != 1 && $0.offset != 2 }.map(\.element)
        XCTAssertEqual(group(of: frags[1]), group(of: frags[2]), "precondition: positions 1,2 share a group")
        var r = FrameReassembler(fec: XORParityFEC(groupSize: groupSize))
        var completed: ReassembledFrame?
        for f in survivors {
            if case let .completed(c) = try r.ingest(FrameFragment.decode(f.encode())) { completed = c }
        }
        XCTAssertNil(completed, "two losses in one group are unrecoverable by single-loss XOR")
    }

    // A burst as long as `numGroups` adjacent datagrams still recovers (one loss per group).
    func testBurstUpToNumGroupsRecovered() throws {
        let frame = makeFrameBytes()
        let out = FragmentInterleaver.interleave(packetized(), groupSize: groupSize)
        let dataCount = out.filter(isData).count
        let numGroups = (dataCount + groupSize - 1) / groupSize
        // Drop the first `numGroups` wire positions (all data, rank-0 = one per group).
        let survivors = out.enumerated().filter { $0.offset >= numGroups }.map(\.element)
        var r = FrameReassembler(fec: XORParityFEC(groupSize: groupSize))
        var completed: ReassembledFrame?
        for f in survivors {
            if case let .completed(c) = try r.ingest(FrameFragment.decode(f.encode())) { completed = c }
        }
        XCTAssertEqual(completed?.avcc, frame, "a \(numGroups)-long adjacent burst spread one-per-group is recovered")
    }

    // No-op guards: a single group can't benefit; groupSize ≤ 1 has no groups to spread across.
    func testSingleGroupReturnedUnchanged() {
        var p = VideoPacketizer(fec: XORParityFEC(groupSize: groupSize))
        let smallFrame = Data((0..<100).map { UInt8(truncatingIfNeeded: $0) }) // 1 data fragment
        let frags = p.packetize(frame: smallFrame, keyframe: true)
        let out = FragmentInterleaver.interleave(frags, groupSize: groupSize)
        XCTAssertEqual(out.map(\.header.fragIndex), frags.map(\.header.fragIndex))
    }

    func testGroupSizeOneIsNoOp() {
        let frags = packetized()
        let out = FragmentInterleaver.interleave(frags, groupSize: 1)
        XCTAssertEqual(out.map(\.header.fragIndex), frags.map(\.header.fragIndex))
    }
}
