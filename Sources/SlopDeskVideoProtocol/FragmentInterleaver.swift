import Foundation

/// PURE transmission-order interleaver for a frame's fragments (2026-06-08 — flicker fix).
///
/// WHY: ``XORParityFEC`` recovers exactly ONE lost fragment per group of `groupSize` CONSECUTIVE
/// data fragments (group g = data[g·k … g·k+k−1]). The host previously transmitted fragments in
/// that same consecutive order (`onEncodedFrame`'s tight send loop), so a burst that drops just 2
/// ADJACENT datagrams lands two losses in the SAME group → unrecoverable → a corrupt/partial decode
/// that the next frame only half-fixes → visible FLICKER on fast scroll. Raising the bitrate for the
/// 2× HiDPI display made each frame ~4× more fragments → ~4× more adjacent-loss chances → the flicker
/// the user reported.
///
/// WHAT: reorder TRANSMISSION (not the fragments' `fragIndex` — those are untouched) into column-major
/// "one-per-group" order, so consecutive datagrams on the wire belong to DIFFERENT FEC groups. A burst
/// of up to `numGroups` adjacent losses then spreads to distinct groups, each losing ≤1 → ALL
/// recoverable by single-loss XOR. The data section still precedes the parity section (doc 17 §3.6:
/// a lossless client decodes without waiting for parity; parity still arrives LAST, preserving the
/// reassembler's `fecReorderGrace`).
///
/// HOST-ONLY, NO WIRE/PROTOCOL CHANGE: the client's ``FrameReassembler`` keys data by `fragIndex` and
/// parity by `fragIndex - invertedDataCount(fragCount)` — purely header-derived, reorder-tolerant by
/// design (UDP already reorders) — so the receiver reconstructs identically regardless of send order.
///
/// The reorder law is native Swift (the SINGLE SOURCE OF TRUTH): m-aware — data column-major across
/// FEC groups, then parity column-major across groups; `m == 1` is byte-identical to the prior
/// "parity LAST" order. NO wire change — only the send order differs.
///
/// ## m-awareness
///
/// For `m` parity shards per group the FEC emits parity group-major-then-rank
/// (`[g0p0, g0p1, …, g1p0, …]`). Both the data section and the parity section are emitted
/// column-major across groups (rank-outer, group-inner), so an adjacent-loss burst inside either
/// section spreads across distinct groups (each group then loses ≤1 shard). With `m == 1` every
/// group has exactly one parity shard, so the column-major parity walk reduces to "append parity in
/// group order, LAST" → byte-identical send order to the pre-m-aware wire. `m` is recovered from the
/// parity count and the number of data groups, so the caller passes only the data `groupSize`.
public enum FragmentInterleaver {
    /// Returns `fragments` reordered for burst-resilient transmission, m-aware. A no-op
    /// (byte-for-byte pass-through, original order) when `groupSize <= 1`, there is ≤1 data group,
    /// or there are no more fragments than one group. The returned array is a permutation of the
    /// input — same set of fragments, every `fragIndex` preserved.
    ///
    /// m-aware: `m` (parity shards per group) is derived as `parityCount / numGroups`. With `m == 1`
    /// the parity walk is identical to appending parity in group order, so the send order is
    /// byte-identical to the single-parity wire.
    public static func interleave(_ fragments: [FrameFragment], groupSize: Int) -> [FrameFragment] {
        guard groupSize > 1, fragments.count > groupSize else { return fragments }

        // Single data group → no interleave benefit (any 2 losses in it are unrecoverable
        // regardless). Count first so the fallback preserves the original order.
        let dataCount = fragments.lazy.count(where: { !$0.header.flags.contains(.parity) })
        guard dataCount > groupSize else { return fragments }

        var data: [FrameFragment?] = []
        data.reserveCapacity(dataCount)
        var parity: [FrameFragment?] = []
        // The parity section is exactly the non-data remainder; pre-size it so the split loop never
        // grows its backing buffer. Same set, same order — only the allocation is tightened.
        parity.reserveCapacity(fragments.count - dataCount)
        for f in fragments {
            if f.header.flags.contains(.parity) { parity.append(f) } else { data.append(f) }
        }

        let numGroups = (dataCount + groupSize - 1) / groupSize
        var ordered: [FrameFragment] = []
        ordered.reserveCapacity(data.count + parity.count)
        // DATA column-major: rank 0 of every group, then rank 1 of every group, … Consecutive
        // emissions are thus from distinct groups. Each (rank, group) index is visited exactly once,
        // so a slot is never moved twice.
        for rank in 0..<groupSize {
            for group in 0..<numGroups {
                let idx = group * groupSize + rank
                if idx < data.count, let fragment = data[idx] {
                    data[idx] = nil
                    ordered.append(fragment)
                }
            }
        }
        // PARITY column-major: the FEC lays parity group-major-then-rank as `[g*m + rank]`, so the
        // same rank-outer / group-inner walk spreads the parity section across groups too. `m` is
        // the parity shards per group; `m == 1` makes this the original group-order append (parity
        // LAST, byte-identical). A short / non-uniform parity array (so the division does not divide
        // evenly) degrades safely: any slot left unmoved by the strided walk is swept up in original
        // order afterwards, so the output stays a permutation of the input no matter the count.
        let m = numGroups > 0 ? parity.count / numGroups : 0
        if m > 0 {
            for rank in 0..<m {
                for group in 0..<numGroups {
                    let idx = group * m + rank
                    if idx < parity.count, let fragment = parity[idx] {
                        parity[idx] = nil
                        ordered.append(fragment)
                    }
                }
            }
        }
        // Sweep up any parity not covered by the strided walk (m == 0, or a ragged count),
        // preserving original order — guarantees the result is always a full permutation. Iterate the
        // surviving (non-`nil`) slots directly in index order, which is exactly what `compactMap(\.self)`
        // produced, but without materialising the intermediate array.
        for case let fragment? in parity { ordered.append(fragment) }
        return ordered
    }
}
