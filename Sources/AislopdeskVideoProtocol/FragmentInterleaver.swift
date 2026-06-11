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
/// Pure value→value transform; unit-tested (the send path is HW-gated).
public enum FragmentInterleaver {
    /// Returns `fragments` reordered for burst-resilient transmission. Data fragments are emitted
    /// column-major across FEC groups, then the parity fragments (each its own group, so already
    /// burst-safe). A no-op when there is ≤1 group (interleaving cannot help a single group) or
    /// `groupSize <= 1`. The returned array is a permutation of the input — same set of fragments,
    /// every `fragIndex` preserved.
    public static func interleave(_ fragments: [FrameFragment], groupSize: Int) -> [FrameFragment] {
        guard groupSize > 1, fragments.count > groupSize else { return fragments }

        var data: [FrameFragment] = []
        var parity: [FrameFragment] = []
        data.reserveCapacity(fragments.count)
        for f in fragments {
            if f.header.flags.contains(.parity) { parity.append(f) } else { data.append(f) }
        }
        // Single data group → no interleave benefit (any 2 losses in it are unrecoverable regardless).
        guard data.count > groupSize else { return fragments }

        let numGroups = (data.count + groupSize - 1) / groupSize
        var ordered: [FrameFragment] = []
        ordered.reserveCapacity(fragments.count)
        // Column-major: rank 0 of every group, then rank 1 of every group, … Consecutive emissions
        // are thus from distinct groups, so any adjacent-loss burst of length ≤ numGroups spreads to
        // distinct groups (each recoverable by single-loss XOR).
        for rank in 0 ..< groupSize {
            for group in 0 ..< numGroups {
                let idx = group * groupSize + rank
                if idx < data.count { ordered.append(data[idx]) }
            }
        }
        ordered.append(contentsOf: parity) // parity LAST; each parity is its own group → burst-safe
        return ordered
    }
}
