import Foundation

/// Forward-error-correction over a frame's data fragments.
///
/// doc 17 §3.6 calls for ~20% parity per frame (Sunshine default). The live engine is a native
/// Swift systematic Reed-Solomon erasure codec over GF(2^8) (the all-Swift migration deletes the
/// former Rust core + FFI boundary): ``RustReedSolomonFEC`` is the production ``FECScheme``. With
/// `m == 1` (one parity per group) it is **byte-identical** to the legacy XOR/length-prefix wire
/// format, so a mixed fleet still interoperates and the golden vectors are unchanged. Multi-loss
/// (`m >= 2`) recovers up to `m` lost fragments per group.
///
/// Contract: ``parity(forDataFragments:)`` produces parity fragments from the frame's data
/// fragments; ``recover(dataFragments:parityFragments:)`` fills any `nil` (lost) data fragment it
/// can, returning the repaired array (still possibly holding `nil` for unrecoverable losses, which
/// the caller escalates to request-recovery).
public protocol FECScheme: Sendable {
    /// The DEFAULT group size: how many data fragments share one parity fragment when no explicit
    /// per-frame group size is supplied. With `groupSize = 5` the overhead is 1/5 = 20% parity,
    /// matching the doc-17 target. WF-4 adaptive FEC drives a per-frame group size through the
    /// `groupSize:`-parameterized methods; this value is the tier-0 / convenience default.
    var groupSize: Int { get }

    /// Parity shards per group (the code's `m`): how many losses per group the scheme repairs.
    /// Defaults to `1` (the XOR-equivalent / byte-identical wire). ``RustReedSolomonFEC`` exposes
    /// its configured `m`. Read by ``FrameReassembler`` / ``FramePacketizer`` to build their own
    /// `[k + m, k]` codec with the matching multiplicity.
    var parityCount: Int { get }

    /// Computes parity fragments for `dataFragments`, in group order, grouping by `groupSize`.
    func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data]

    /// Attempts to recover lost (`nil`) data fragments using the parity fragments, grouping by
    /// `groupSize`. Entries that cannot be recovered remain `nil`.
    func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?]
}

public extension FECScheme {
    /// Convenience: parity using the scheme's configured default ``groupSize``. Keeps pre-WF-4
    /// callers (no explicit group size) compiling and behaving identically.
    func parity(forDataFragments dataFragments: [Data]) -> [Data] {
        parity(forDataFragments: dataFragments, groupSize: groupSize)
    }

    /// Convenience: recover using the scheme's configured default ``groupSize``.
    func recover(dataFragments: [Data?], parityFragments: [Data?]) -> [Data?] {
        recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: groupSize)
    }
}

/// The production FEC scheme: a native Swift systematic Reed-Solomon erasure codec over GF(2^8).
/// Each group of `groupSize` data fragments produces `m` parity fragments and recovers up to `m`
/// losses per group.
///
/// **v1 ships `m == 1`**, which the codec special-cases to plain XOR parity — the parity bytes and
/// the recovered bytes are bit-for-bit the legacy length-prefixed XOR (the golden vectors anchor
/// this), so the on-wire datagrams are byte-identical to the pre-port stream and a mixed fleet
/// interoperates. The XOR path still routes through the configured ``GfRegion`` backend, so on
/// Apple Silicon the accumulate is NEON-vectorised.
///
/// **`m == 1` is byte-identical to plain XOR for ANY group size.** A Cauchy parity row is *not*
/// all-ones, so a literal RS encode with `m == 1` would emit different parity bytes than the plain
/// XOR even though recovery would still be correct. Because the wire contract guarantees `m == 1`
/// matches the v1 XOR format exactly, this type special-cases `m == 1` to plain XOR internally and,
/// crucially, does NOT clamp the per-call group size to `k` at `m == 1` (the production FEC path
/// drives an adaptive per-frame group size that can exceed `k`). For `m >= 2` the Cauchy encoder has
/// exactly `k = groupSize` columns, so the per-call size is clamped down to `k`, keeping encode and
/// decode self-consistent.
///
/// Every region operation routes through the configured ``GfRegion`` backend (``NeonGf``):
/// `xorAdd` for identity/data-row combination, `mulAdd` for parity rows. The XOR output is
/// backend-independent, so byte-identity to the legacy XOR holds regardless of `G`.
///
/// Value type, immutable after construction; safe to use concurrently.
public final class RustReedSolomonFEC: FECScheme, @unchecked Sendable {
    public let groupSize: Int
    /// The parity-shard count per group (`m`). v1 is always 1 (XOR-equivalent, wire-identical).
    public let parityCount: Int

    /// The GF(2^8) region-arithmetic backend (NEON-accelerated on Apple Silicon, byte-identical to
    /// the scalar reference). Used for every encode/recover region accumulate.
    private let gf: any GfRegion

    /// Builds an `[n = k + m, k]` Reed-Solomon codec.
    ///
    /// - Parameters:
    ///   - groupSize: data fragments per group (`k`). Default 5 ⇒ 20% parity at `m == 1`.
    ///   - parityCount: parity fragments per group (`m`). Default 1 (XOR-equivalent, byte-identical
    ///     to the legacy wire). Values `>= 2` enable multi-loss recovery.
    public init(groupSize: Int = 5, parityCount: Int = 1) {
        precondition(groupSize >= 1, "groupSize must be >= 1")
        precondition(parityCount >= 1, "parityCount must be >= 1")
        precondition(groupSize + parityCount <= 255, "groupSize + parityCount must be <= 255 (GF(2^8))")
        self.groupSize = groupSize
        self.parityCount = parityCount
        gf = NeonGf()
    }

    public func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data] {
        parityM(dataFragments, groupSize: groupSize, m: parityCount)
    }

    public func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?] {
        recoverM(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: groupSize, m: parityCount)
    }

    // MARK: - Effective grouping width

    /// The per-call grouping width for a requested `group_size` at parity multiplicity `m`.
    ///
    /// `m == 1` (plain XOR, no matrix) honours the request EXACTLY — NO clamp to `k` — so the parity
    /// bytes are byte-identical to the standalone length-prefixed XOR for ANY group size (the
    /// production FEC path drives an adaptive per-frame group size that can exceed the codec's `k`).
    /// `m >= 2` (the Cauchy code) clamps down to `k = groupSize`, its column count. A non-positive
    /// size floors to 1 either way (a 0 size must never loop forever).
    private func effectiveGroupSize(_ requested: Int, m: Int) -> Int {
        let floored = max(1, requested)
        return m == 1 ? floored : min(floored, groupSize)
    }

    // MARK: - Parity (encode)

    /// Parity at multiplicity `m`. Groups `data` at ``effectiveGroupSize(_:m:)`` and emits each
    /// group's `m` parity shards in rank order (group-major then rank).
    private func parityM(_ data: [Data], groupSize requested: Int, m: Int) -> [Data] {
        let groupSize = effectiveGroupSize(requested, m: m)
        var parities: [Data] = []
        // `m` parity shards per full group + a tail group ⇒ exact-ish reservation, no growth churn.
        if !data.isEmpty {
            let groups = (data.count + groupSize - 1) / groupSize
            parities.reserveCapacity(groups * m)
        }
        var index = 0
        while index < data.count {
            let upper = min(index + groupSize, data.count)
            encodeGroup(data, range: index..<upper, m: m, into: &parities)
            index += groupSize
        }
        return parities
    }

    /// Encodes one group's `m` parity shards, appended in rank order. The group is the data shards
    /// at `data[range]` — passed as a base array + range to avoid an intermediate slice-copy.
    ///
    /// `m == 1` takes the plain XOR path (byte-identical to the legacy XOR), still routed through the
    /// GF backend. For `m >= 2`, frames each up-to-`k` data shard (length-prefixed) ONCE into a
    /// reusable scratch, zero-pads to the group's widest member `W`, then for each parity row folds
    /// `coeff * framed_shard` into a single reused `W`-wide accumulator (zeroed between ranks) via the
    /// GF backend's `mulAdd`. Output bytes are identical to the per-rank-fresh-buffer version.
    private func encodeGroup(_ data: [Data], range: Range<Int>, m: Int, into out: inout [Data]) {
        if m == 1 {
            out.append(gfXorEncoded(data, range: range))
            return
        }
        // Frame each shard once (length-prefixed). `framed[j]` is reused across all `m` ranks.
        var framed: [[UInt8]] = []
        framed.reserveCapacity(range.count)
        var width = 0
        for i in range {
            let f = Self.lengthPrefixed(data[i])
            if f.count > width { width = f.count }
            framed.append(f)
        }
        let coeffs = ReedSolomonMatrix.parityRows(k: groupSize, m: m)
        // One accumulator, reused across ranks: each rank zeroes the full width before folding, so no
        // stale bytes leak (the result is bit-identical to a fresh per-rank buffer).
        var acc = [UInt8](repeating: 0, count: width)
        acc.withUnsafeMutableBufferPointer { accBuf in
            for rank in 0..<m {
                if rank > 0 {
                    for i in 0..<width { accBuf[i] = 0 }
                }
                for (j, shard) in framed.enumerated() {
                    // Coefficient for parity `rank` over data shard `j`. A short final group holds
                    // fewer than k shards; only the present shards contribute.
                    let coeff = coeffs[rank * groupSize + j]
                    shard.withUnsafeBufferPointer { srcBuf in
                        gf.mulAdd(coeff: coeff, src: srcBuf, dst: accBuf)
                    }
                }
                out.append(Data(accBuf))
            }
        }
    }

    /// XOR of the length-prefixed encodings of a group (`data[range]`), zero-padded to the longest
    /// member, folded through the GF backend's `xorAdd`. Byte-identical to the legacy
    /// `XORParityFEC.xorEncoded` (field addition is XOR regardless of the backend). Frames each
    /// member directly into the accumulator with no per-member `[UInt8]` array kept around.
    private func gfXorEncoded(_ data: [Data], range: Range<Int>) -> Data {
        // Width = the widest length-prefixed member = 4 + max member byte count.
        var maxLen = 0
        for i in range where data[i].count > maxLen { maxLen = data[i].count }
        let width = range.isEmpty ? 0 : 4 + maxLen
        var acc = [UInt8](repeating: 0, count: width)
        acc.withUnsafeMutableBufferPointer { accBuf in
            for i in range {
                Self.appendLengthPrefixedXor(data[i], into: accBuf)
            }
        }
        return Data(acc)
    }

    /// `acc[0..<4+member.count] ^= lengthPrefixed(member)` in place — folds a single length-prefixed
    /// member into the accumulator WITHOUT materialising its framed `[UInt8]`. `acc.count` is the
    /// group width (`>= 4 + member.count`), so every write is in bounds. Byte-identical to building
    /// `lengthPrefixed(member)` and `xorAdd`-ing it.
    @inline(__always)
    private static func appendLengthPrefixedXor(_ member: Data, into acc: UnsafeMutableBufferPointer<UInt8>) {
        let len = UInt32(truncatingIfNeeded: member.count)
        acc[0] ^= UInt8(truncatingIfNeeded: len >> 24)
        acc[1] ^= UInt8(truncatingIfNeeded: len >> 16)
        acc[2] ^= UInt8(truncatingIfNeeded: len >> 8)
        acc[3] ^= UInt8(truncatingIfNeeded: len)
        member.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for j in 0..<bytes.count {
                acc[4 + j] ^= bytes[j]
            }
        }
    }

    /// `parity XOR (encoded survivors)` = the encoded form of the single missing member, zero-padded,
    /// then length-stripped → the recovered shard. Byte-identical to the legacy
    /// `XORParityFEC.xorRecover` but folds straight from the `Data` survivors (`data[range]`, present
    /// only) + the parity `Data`, with NO `[UInt8]`↔`Data` round-trips and ONE reused accumulator.
    /// Survivors are length-prefixed on the fly into the accumulator; `nil` on a corrupt length
    /// prefix (validate-then-drop), identical to the old strip step.
    private func gfXorRecoverHole(parity: Data, data: [Data?], range: Range<Int>) -> Data? {
        // Width = max(parity.count, max over present survivors of 4 + survivor.count).
        var width = parity.count
        for i in range {
            if let s = data[i] {
                let framed = 4 + s.count
                if framed > width { width = framed }
            }
        }
        var acc = [UInt8](repeating: 0, count: width)
        return acc.withUnsafeMutableBufferPointer { accBuf -> Data? in
            // XOR the parity bytes (count <= width).
            parity.withUnsafeBytes { raw in
                let pb = raw.bindMemory(to: UInt8.self)
                for j in 0..<pb.count { accBuf[j] ^= pb[j] }
            }
            // XOR each present survivor's length-prefixed framing (count <= width).
            for i in range {
                if let s = data[i] {
                    Self.appendLengthPrefixedXor(s, into: accBuf)
                }
            }
            return Self.stripLengthPrefix(UnsafeBufferPointer(accBuf))
        }
    }

    // MARK: - Recover (decode)

    /// Recover at multiplicity `m`. The `m` MUST match the one the parity was encoded with: it sets
    /// both the per-group parity stride (`parity[group * m + rank]`) and the recovery budget.
    private func recoverM(
        dataFragments: [Data?],
        parityFragments: [Data?],
        groupSize requested: Int,
        m: Int,
    ) -> [Data?] {
        var result = dataFragments
        let groupSize = effectiveGroupSize(requested, m: m) // matches parityM's grouping
        var groupIndex = 0
        var index = 0
        while index < result.count {
            let upper = min(index + groupSize, result.count)
            recoverGroup(&result, parity: parityFragments, index: index, upper: upper, groupIndex: groupIndex, m: m)
            index += groupSize
            groupIndex += 1
        }
        return result
    }

    /// Recovers a single group's holes in place (indices `index..<upper` of `data`), using the
    /// group's `m` parity shards at `parity[groupIndex * m ..< groupIndex * m + m]`.
    ///
    /// Leaves every hole untouched when unrecoverable (`holes == 0`, `holes > m`, too few surviving
    /// parity, a singular submatrix, or a corrupt length prefix) — never traps.
    private func recoverGroup(
        _ data: inout [Data?],
        parity: [Data?],
        index: Int,
        upper: Int,
        groupIndex: Int,
        m: Int,
    ) {
        let k = groupSize
        let groupLen = upper - index

        // Holes are missing DATA shards; their position within the group is `i - index`.
        let holes = (index..<upper).filter { data[$0] == nil }
        if holes.isEmpty || holes.count > m {
            return // nothing to do, or beyond this group's repair budget
        }

        // m == 1: a single hole, plain XOR recover (byte-identical to the legacy XOR), folded
        // through the GF backend.
        if m == 1 {
            if groupIndex < parity.count, let parityBytes = parity[groupIndex] {
                if let bytes = gfXorRecoverHole(parity: parityBytes, data: data, range: index..<upper) {
                    data[holes[0]] = bytes
                }
            }
            return
        }

        // The encoder treats a short final group (groupLen < k) as having (k - groupLen) implicit
        // all-zero data shards in slots groupLen..<k. Those phantom shards are never missing (the
        // constant 0), so they always count as survivors.
        let parityCoeffs = ReedSolomonMatrix.parityRows(k: k, m: m)

        // Collect k survivor (encoder-row, framed-bytes) pairs. Encoder indices: 0..<k are the data
        // rows (identity), k..<k+m are the parity rows. We need exactly k linearly independent
        // survivors; any k of the n MDS rows suffice.
        var survivorRows: [[UInt8]] = []
        survivorRows.reserveCapacity(k)
        var survivorBytes: [[UInt8]] = []
        survivorBytes.reserveCapacity(k)

        // 1) Present real data shards contribute their identity row e_j and framed bytes.
        for slot in 0..<groupLen {
            if let bytes = data[index + slot] {
                var row = [UInt8](repeating: 0, count: k)
                row[slot] = 1
                survivorRows.append(row)
                survivorBytes.append(Self.lengthPrefixed(bytes))
            }
        }
        // 2) Phantom zero shards in a short final group are known-zero survivors (identity row,
        //    all-zero bytes). They let a short group still reach k independent rows.
        if groupLen < k {
            for slot in groupLen..<k {
                var row = [UInt8](repeating: 0, count: k)
                row[slot] = 1
                survivorRows.append(row)
                survivorBytes.append([]) // all-zero contributes nothing
            }
        }
        // 3) Fill the remaining slots from present parity shards (their Cauchy rows).
        let parityBase = groupIndex * m
        var rank = 0
        while survivorRows.count < k, rank < m {
            let parityIdx = parityBase + rank
            if parityIdx < parity.count, let parityBytes = parity[parityIdx] {
                let row = Array(parityCoeffs[rank * k..<rank * k + k])
                survivorRows.append(row)
                survivorBytes.append([UInt8](parityBytes))
            }
            rank += 1
        }

        if survivorRows.count < k {
            return // not enough surviving shards to solve — leave the holes
        }
        // Use exactly k survivors (we may have collected k from data + phantom already).
        if survivorRows.count > k {
            survivorRows.removeLast(survivorRows.count - k)
            survivorBytes.removeLast(survivorBytes.count - k)
        }

        // Invert the k×k encoder submatrix of the chosen survivors.
        guard let inverse = ReedSolomonMatrix.invertSubset(survivorRows, k: k) else {
            return // singular (should not happen for a true MDS subset) — leave holes
        }

        // Width of the working accumulator: the widest survivor's framed length.
        var width = 0
        for sbytes in survivorBytes where sbytes.count > width { width = sbytes.count }

        // For each missing DATA slot, the original framed shard is row `slot` of
        // (inverse · survivorBytes): acc = Σ_t inverse[slot * k + t] * survivorBytes[t].
        // One accumulator reused across holes (zeroed per hole — no stale bytes leak), folded via
        // the unsafe `mulAdd` overload so survivor bytes are not re-copied per fold.
        var acc = [UInt8](repeating: 0, count: width)
        acc.withUnsafeMutableBufferPointer { accBuf in
            for hole in holes {
                let slot = hole - index // 0..<k position of the missing data shard
                for i in 0..<width { accBuf[i] = 0 }
                for (t, sbytes) in survivorBytes.enumerated() {
                    let coeff = inverse[slot * k + t]
                    sbytes.withUnsafeBufferPointer { srcBuf in
                        gf.mulAdd(coeff: coeff, src: srcBuf, dst: accBuf)
                    }
                }
                if let bytes = Self.stripLengthPrefix(UnsafeBufferPointer(accBuf)) {
                    data[hole] = bytes
                }
            }
        }
    }

    // MARK: - Length-prefix framing (shared by the XOR and Cauchy paths)

    /// `[UInt32 BE length][bytes]`. A fragment never approaches 4 GiB (MTU-bounded), so the `UInt32`
    /// length holds by construction. Both the XOR and the RS code operate over this framed,
    /// zero-padded encoding so recovery reproduces the *exact* original length even when group
    /// members differ in size.
    static func lengthPrefixed(_ data: Data) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(4 + data.count)
        let len = UInt32(truncatingIfNeeded: data.count)
        out.append(UInt8(truncatingIfNeeded: len >> 24))
        out.append(UInt8(truncatingIfNeeded: len >> 16))
        out.append(UInt8(truncatingIfNeeded: len >> 8))
        out.append(UInt8(truncatingIfNeeded: len))
        out.append(contentsOf: data)
        return out
    }

    /// Inverse of ``lengthPrefixed(_:)``: reads the embedded length and slices exactly that many
    /// bytes, ignoring trailing zero padding. `nil` if the declared length does not fit (a corrupt
    /// prefix on hostile input — recovery then leaves the hole rather than crashing). VALIDATE before
    /// allocating: bounds are checked before the slice copy.
    static func stripLengthPrefix(_ data: [UInt8]) -> Data? {
        data.withUnsafeBufferPointer { stripLengthPrefix($0) }
    }

    /// `UnsafeBufferPointer` overload of ``stripLengthPrefix(_:)`` for the hot recover path: parses
    /// the prefix and slices straight out of the working accumulator, skipping the intermediate
    /// `[UInt8]` copy. Identical validate-then-drop semantics: bounds are checked before the copy.
    static func stripLengthPrefix(_ data: UnsafeBufferPointer<UInt8>) -> Data? {
        if data.count < 4 { return nil }
        let length =
            (Int(data[0]) << 24) |
            (Int(data[1]) << 16) |
            (Int(data[2]) << 8) |
            Int(data[3])
        let end = 4 + length
        if length >= 0, end <= data.count {
            return Data(UnsafeBufferPointer(rebasing: data[4..<end]))
        }
        return nil
    }
}

/// Compatibility alias: the legacy name maps to the native Reed-Solomon scheme so the many
/// `XORParityFEC(...)` construction/test sites keep building UNCHANGED while the live FEC engine is
/// the native Swift codec. `m == 1` keeps the wire byte-identical to the old native Swift XOR.
public typealias XORParityFEC = RustReedSolomonFEC
