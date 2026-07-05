import XCTest
@testable import SlopDeskVideoProtocol

/// WIRE BYTE-IDENTITY proof for the Rust-backed FEC (`RustReedSolomonFEC`, `m == 1`).
///
/// The live FEC engine is now the NEON-backed Reed-Solomon codec in the Rust core, reached over the
/// `aisd_fec_*` C ABI. For `m == 1` it MUST be bit-for-bit identical to the legacy native Swift
/// XOR/length-prefix scheme that previously shipped — otherwise a mixed fleet (one end old, one end
/// new) would mis-recover and the on-wire datagrams would diverge.
///
/// The deleted native Swift XOR is re-implemented HERE as a TEST-ONLY golden reference
/// (``LegacySwiftXORFEC``), copied verbatim from the pre-port `XORParityFEC` body, so this test
/// proves equivalence against the exact algorithm that was removed — not against the new engine's
/// own output. The parity bytes AND the single-loss recovery are asserted byte-equal across several
/// group sizes, INCLUDING a per-call group size LARGER than the codec's `k` (the adaptive-tier case
/// the core must honour without clamping).
final class RustFECWireIdentityTests: XCTestCase {
    /// Verbatim re-implementation of the DELETED native Swift `XORParityFEC` (length-prefixed XOR).
    /// This is the golden wire reference: the Rust-backed FEC at `m == 1` must match it byte-exact.
    private struct LegacySwiftXORFEC {
        func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data] {
            let groupSize = max(1, groupSize)
            var parities: [Data] = []
            var index = 0
            while index < dataFragments.count {
                let group = Array(dataFragments[index..<min(index + groupSize, dataFragments.count)])
                parities.append(Self.xorEncoded(group))
                index += groupSize
            }
            return parities
        }

        func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?] {
            let groupSize = max(1, groupSize)
            var result = dataFragments
            var groupIndex = 0
            var index = 0
            while index < dataFragments.count {
                let upper = min(index + groupSize, dataFragments.count)
                let range = index..<upper
                let missing = range.filter { result[$0] == nil }
                if missing.count == 1, groupIndex < parityFragments.count, let parity = parityFragments[groupIndex] {
                    let survivors = range.compactMap { result[$0] }
                    let recoveredEncoded = Self.xorRecover(parity: parity, survivors: survivors)
                    if let bytes = Self.stripLengthPrefix(recoveredEncoded) {
                        result[missing[0]] = bytes
                    }
                }
                index += groupSize
                groupIndex += 1
            }
            return result
        }

        private static func lengthPrefixed(_ data: Data) -> Data {
            var out = Data()
            let count = UInt32(data.count)
            out.append(UInt8((count >> 24) & 0xFF))
            out.append(UInt8((count >> 16) & 0xFF))
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
            out.append(data)
            return out
        }

        private static func stripLengthPrefix(_ data: Data) -> Data? {
            guard data.count >= 4 else { return nil }
            let base = data.startIndex
            let length =
                (Int(data[base]) << 24) |
                (Int(data[base + 1]) << 16) |
                (Int(data[base + 2]) << 8) |
                Int(data[base + 3])
            guard length >= 0, 4 + length <= data.count else { return nil }
            let start = base + 4
            return Data(data[start..<start + length])
        }

        private static func xorEncoded(_ group: [Data]) -> Data {
            let encoded = group.map { lengthPrefixed($0) }
            let width = encoded.map(\.count).max() ?? 0
            var acc = [UInt8](repeating: 0, count: width)
            for member in encoded {
                let base = member.startIndex
                for i in 0..<member.count { acc[i] ^= member[base + i] }
            }
            return Data(acc)
        }

        private static func xorRecover(parity: Data, survivors: [Data]) -> Data {
            let encodedSurvivors = survivors.map { lengthPrefixed($0) }
            let width = max(parity.count, encodedSurvivors.map(\.count).max() ?? 0)
            var acc = [UInt8](repeating: 0, count: width)
            let pBase = parity.startIndex
            for i in 0..<parity.count { acc[i] ^= parity[pBase + i] }
            for member in encodedSurvivors {
                let base = member.startIndex
                for i in 0..<member.count { acc[i] ^= member[base + i] }
            }
            return Data(acc)
        }
    }

    /// Deterministic, seedable PRNG (no Foundation randomness so the corpus is reproducible).
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func range(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// PARITY BYTE-IDENTITY: the Rust-backed FEC parity bytes EQUAL the legacy Swift XOR parity for
    /// several group sizes — 5 (prod default), 8, 2, and 10 (LARGER than the codec's default k=5, the
    /// adaptive-tier case) — and for varied shard counts and per-shard sizes (incl. empty shards).
    func testParityBytesIdenticalToLegacySwiftXOR() {
        let legacy = LegacySwiftXORFEC()
        var rng = SplitMix(seed: 0xA15D_0DE5_F00D)
        // Codec built with the prod default k=5; the per-call group size VARIES (incl. > k=5).
        let fec = RustReedSolomonFEC(groupSize: 5)
        for groupSize in [5, 8, 2, 10] {
            for trial in 0..<60 {
                let count = 1 + rng.range(3 * groupSize + 1)
                let data: [Data] = (0..<count).map { _ in
                    let len = rng.range(40) // includes empty shards (len 0)
                    return Data((0..<len).map { _ in rng.byte() })
                }
                let legacyParity = legacy.parity(forDataFragments: data, groupSize: groupSize)
                let rustParity = fec.parity(forDataFragments: data, groupSize: groupSize)
                XCTAssertEqual(
                    rustParity,
                    legacyParity,
                    "Rust-backed FEC parity must be BYTE-IDENTICAL to legacy Swift XOR " +
                        "(groupSize=\(groupSize), trial=\(trial), count=\(count))",
                )
                // Count proves the per-call group size was honoured (NOT clamped to the codec k=5).
                XCTAssertEqual(
                    rustParity.count,
                    (count + groupSize - 1) / groupSize,
                    "parity count must reflect the per-call groupSize=\(groupSize), not codec k=5",
                )
            }
        }
    }

    /// RECOVERY BYTE-IDENTITY: lose ONE data fragment per group; the Rust-backed FEC recovers to the
    /// EXACT same bytes as the legacy Swift XOR, across the same group sizes (incl. > k).
    func testSingleLossRecoveryIdenticalToLegacySwiftXOR() {
        let legacy = LegacySwiftXORFEC()
        var rng = SplitMix(seed: 0x5EED_BEEF_CAFE)
        let fec = RustReedSolomonFEC(groupSize: 5)
        for groupSize in [5, 8, 2, 10] {
            for _ in 0..<60 {
                let count = 1 + rng.range(3 * groupSize + 1)
                let data: [Data] = (0..<count).map { _ in
                    Data((0..<rng.range(40)).map { _ in rng.byte() })
                }
                let parity = fec.parity(forDataFragments: data, groupSize: groupSize)
                // The legacy parity must match (proven above); recover from the SAME parity bytes.
                XCTAssertEqual(parity, legacy.parity(forDataFragments: data, groupSize: groupSize))

                // Drop one random shard in each group.
                var received: [Data?] = data.map(\.self)
                let groups = (count + groupSize - 1) / groupSize
                for g in 0..<groups {
                    let base = g * groupSize
                    let hi = min(base + groupSize, count)
                    let hole = base + rng.range(hi - base)
                    received[hole] = nil
                }
                let parityOpt: [Data?] = parity.map(\.self)
                let legacyRecovered = legacy.recover(
                    dataFragments: received, parityFragments: parityOpt, groupSize: groupSize,
                )
                let rustRecovered = fec.recover(
                    dataFragments: received, parityFragments: parityOpt, groupSize: groupSize,
                )
                XCTAssertEqual(
                    rustRecovered, legacyRecovered,
                    "Rust recovery must equal legacy XOR recovery (groupSize=\(groupSize))",
                )
                // And both must restore the originals exactly.
                XCTAssertEqual(
                    rustRecovered.map(\.self), data.map { Optional($0) },
                    "Rust FEC must restore the originals byte-exact (groupSize=\(groupSize))",
                )
            }
        }
    }

    /// TWO-LOSS UNRECOVERABILITY parity: two holes in one group leave both `nil` in BOTH schemes
    /// (the `m == 1` budget is one loss per group).
    func testTwoLossesUnrecoverableIdenticalToLegacy() {
        let legacy = LegacySwiftXORFEC()
        let fec = RustReedSolomonFEC(groupSize: 5)
        let data: [Data] = (0..<5).map { Data([UInt8($0), UInt8($0) &+ 1, UInt8($0) &+ 2]) }
        let parity = fec.parity(forDataFragments: data, groupSize: 5)
        var received: [Data?] = data.map(\.self)
        received[1] = nil
        received[3] = nil // two losses in the single group → unrecoverable
        let legacyRecovered = legacy.recover(dataFragments: received, parityFragments: parity.map(\.self), groupSize: 5)
        let rustRecovered = fec.recover(dataFragments: received, parityFragments: parity.map(\.self), groupSize: 5)
        XCTAssertEqual(rustRecovered, legacyRecovered)
        XCTAssertNil(rustRecovered[1])
        XCTAssertNil(rustRecovered[3])
    }

    /// Differently-sized fragments (the short final shard) recover their EXACT original length via
    /// the length prefix — byte-identical to the legacy scheme.
    func testRecoversDifferentlySizedFragmentsLikeLegacy() {
        let legacy = LegacySwiftXORFEC()
        let fec = RustReedSolomonFEC(groupSize: 4)
        let data: [Data] = [
            Data((0..<200).map { UInt8(truncatingIfNeeded: $0) }),
            Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &+ 1) }),
            Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &+ 2) }),
            Data((0..<37).map { UInt8(truncatingIfNeeded: $0 &+ 3) }), // short
        ]
        XCTAssertEqual(fec.parity(forDataFragments: data), legacy.parity(forDataFragments: data, groupSize: 4))
        var received: [Data?] = data.map(\.self)
        received[3] = nil // lose the short shard
        let rust = fec.recover(dataFragments: received, parityFragments: fec.parity(forDataFragments: data).map(\.self))
        XCTAssertEqual(rust[3], data[3])
        XCTAssertEqual(rust[3]?.count, 37)
    }

    /// EMPTY-but-PRESENT shard is NOT a hole (a zero-length payload must round-trip): lose a
    /// different shard, recover it; the present empty shard stays empty.
    func testEmptyPresentShardIsNotTreatedAsHole() {
        let fec = RustReedSolomonFEC(groupSize: 3)
        let data: [Data] = [Data(), Data([0xAA, 0xAB, 0xAC]), Data([0xBB, 0xBC])]
        let parity = fec.parity(forDataFragments: data, groupSize: 3)
        var received: [Data?] = data.map(\.self) // shard 0 is present-but-empty
        received[1] = nil // the real hole
        let recovered = fec.recover(dataFragments: received, parityFragments: parity.map(\.self), groupSize: 3)
        XCTAssertEqual(recovered[0], Data(), "the empty present shard stays empty (not recovered as a hole)")
        XCTAssertEqual(recovered[1], data[1], "the real hole recovered byte-exact")
        XCTAssertEqual(recovered[2], data[2])
    }
}
