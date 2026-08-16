import CSlopDeskFFI
import Foundation

/// Forward-error-correction over a frame's data fragments.
///
/// doc 17 §3.6 calls for ~20% parity per frame (Sunshine default). ``RustReedSolomonFEC`` is the
/// production ``FECScheme``: a native Swift systematic Reed-Solomon erasure codec over GF(2^8) —
/// the name is a holdover, there is no Rust or FFI boundary in this path. With `m == 1` (one
/// parity per group) it is **byte-identical** to the plain XOR/length-prefix wire format, so a
/// mixed fleet still interoperates and the golden vectors hold. Multi-loss (`m >= 2`) recovers up
/// to `m` lost fragments per group.
///
/// Contract: ``parity(forDataFragments:)`` produces parity fragments from the frame's data
/// fragments; ``recover(dataFragments:parityFragments:)`` fills any `nil` (lost) data fragment it
/// can, returning the repaired array (still possibly holding `nil` for unrecoverable losses, which
/// the caller escalates to request-recovery).
public protocol FECScheme: Sendable {
    /// The DEFAULT group size: how many data fragments share one parity fragment when no explicit
    /// per-frame group size is supplied. With `groupSize = 5` the overhead is 1/5 = 20% parity,
    /// matching the doc-17 target. Adaptive FEC drives a per-frame group size through the
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
    /// Convenience: parity using the scheme's configured default ``groupSize``. Keeps
    /// callers with no explicit group size compiling and behaving identically.
    func parity(forDataFragments dataFragments: [Data]) -> [Data] {
        parity(forDataFragments: dataFragments, groupSize: groupSize)
    }

    /// Convenience: recover using the scheme's configured default ``groupSize``.
    func recover(dataFragments: [Data?], parityFragments: [Data?]) -> [Data?] {
        recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: groupSize)
    }
}

/// The production FEC scheme: a systematic Reed-Solomon erasure codec over GF(2^8), in Rust.
///
/// Each group of `groupSize` data fragments produces `m` parity fragments and recovers up to `m`
/// losses per group. The name is no longer a holdover: `rust/slopdesk-video`'s `fec` module is the
/// implementation, reached through `slopdesk_video_fec_parity` / `slopdesk_video_fec_recover`.
///
/// **v1 ships `m == 1`**, which the codec special-cases to plain XOR parity — the parity bytes and
/// the recovered bytes are bit-for-bit the legacy length-prefixed XOR (the golden vectors anchor
/// this), so the on-wire datagrams are byte-identical to the pre-port stream and a mixed fleet
/// interoperates. `m == 1` also does NOT clamp the per-call group size to `k`, because the
/// production path drives an adaptive per-frame size that can exceed it; for `m >= 2` the Cauchy
/// encoder has exactly `k` columns, so the per-call size is clamped down. Both rules live in the
/// Rust now, which is the point — there is one place they can be got wrong.
///
/// **Why this moved.** The Swift codec was the least safe code in this tree: the GF backend reached
/// through a C target with `UnsafeBufferPointer`, `withUnsafeTemporaryAllocation` and a
/// `swiftlint:disable force_unwrapping`, and both halves passed raw `UnsafeMutableBufferPointer`
/// accumulators around — on the path that parses hostile UDP. `slopdesk-video` is
/// `forbid(unsafe_code)`, so the category is gone rather than reviewed again. The NEON kernel DID
/// come across, but as one small crate (`rust/slopdesk-gfsimd`) holding two byte-region loops and
/// nothing else — the codec, the matrices and the datagram parsing all stayed safe.
/// `docs/DECISIONS.md` carries the measurements that forced that shape.
///
/// Immutable after construction; safe to use concurrently.
public final class RustReedSolomonFEC: FECScheme, @unchecked Sendable {
    public let groupSize: Int
    /// The parity-shard count per group (`m`). v1 is always 1 (XOR-equivalent, wire-identical).
    public let parityCount: Int

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
    }

    public func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data] {
        let width = max(1, groupSize)
        // A shard is the widest member of its group, length-prefixed; there are `m` per group.
        let widest = dataFragments.reduce(0) { Swift.max($0, $1.count) } + 4
        let groups = (dataFragments.count + width - 1) / width
        let bound = FECBlobList.bound(count: groups * parityCount, widest: widest)
        let packed = FECBlobList.encode(dataFragments.map(\.self))
        let answer = packed.withUnsafeBufferPointer { input in
            FECBlobList.call(bound: bound) { out, cap in
                slopdesk_video_fec_parity(
                    self.groupSize, parityCount, width,
                    input.baseAddress, input.count, out, cap,
                )
            }
        }
        // A refusal means the marshalling disagreed with itself, which is a bug on this side rather
        // than a lossy frame. No parity is the safe reading: the frame ships unprotected and a real
        // loss escalates to a recovery request, where a wrong shard would corrupt the picture.
        return FECBlobList.decode(answer)?.map { $0 ?? Data() } ?? []
    }

    public func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?] {
        // The answer is the REPAIRS: a list as long as `dataFragments` in which only the holes this
        // call closed carry bytes. So it is bounded by the holes, not by the frame — a single-loss
        // frame answers with one shard and a run of four-byte absences, rather than handing back a
        // copy of every fragment the caller already has.
        let holes = dataFragments.reduce(0) { $1 == nil ? $0 + 1 : $0 }
        let widest = (dataFragments + parityFragments).reduce(0) { Swift.max($0, $1?.count ?? 0) }
        let bound = 4 + dataFragments.count * 4 + holes * widest
        let packedData = FECBlobList.encode(dataFragments)
        let packedParity = FECBlobList.encode(parityFragments)
        let answer = packedData.withUnsafeBufferPointer { data in
            packedParity.withUnsafeBufferPointer { parity in
                FECBlobList.call(bound: bound) { out, cap in
                    slopdesk_video_fec_recover(
                        self.groupSize, parityCount, max(1, groupSize),
                        data.baseAddress, data.count,
                        parity.baseAddress, parity.count,
                        out, cap,
                    )
                }
            }
        }
        // A refusal, or an answer of the wrong arity, leaves every hole a hole — the caller
        // escalates, which is what it would do for an unrecoverable group anyway.
        guard let repairs = FECBlobList.decode(answer), repairs.count == dataFragments.count else {
            return dataFragments
        }
        var patched = dataFragments
        for (index, repair) in repairs.enumerated() where repair != nil {
            patched[index] = repair
        }
        return patched
    }
}

/// The blob-list marshalling for the FEC boundary: `u32 count | (u32 len | bytes)…`, big-endian,
/// with `0xFFFFFFFF` for a fragment lost in flight — or, in a recovery ANSWER, for a fragment this
/// call has nothing to say about.
///
/// The FORMAT is decided in `rust/slopdesk-video/src/blob_list.rs`, under `forbid(unsafe_code)` and
/// with its own tests; this is the encoder for it. A present-but-empty fragment writes length 0,
/// which is not the same as absent — repairing a fragment that was never lost would corrupt the
/// frame, and a zero-length tail fragment is a real thing on this path.
///
/// **Why the arguments are COPIED rather than described.** Passing them as `(address, length)`
/// descriptors would move 132 bytes instead of 9.6 KB, and it was tried. It cannot be done in O(1)
/// stack: `withUnsafeBytes` guarantees its pointer only for its closure body, so describing N
/// fragments means N nested closures, and `RustFECLargeFrameStackTests` exists precisely because a
/// 3000-fragment keyframe then overflows the 512 KB stack the production send path runs on. Nor is
/// escaping the pointer an option — a `Data` of 14 bytes or fewer stores its bytes INSIDE the
/// struct, so the address would be into a temporary. The copy is what makes the lifetime trivial.
enum FECBlobList {
    /// The length that marks an absent (lost) fragment.
    static let absent = UInt32.max

    /// Written against uninitialised storage rather than by appending: this runs once per frame
    /// over every fragment the frame has, so the zero-fill and the growth checks an `append` loop
    /// pays are a measurable share of the whole FEC cost at `m == 1`, where the codec itself is a
    /// few hundred nanoseconds.
    static func encode(_ blobs: [Data?]) -> [UInt8] {
        let total = blobs.reduce(4) { $0 + 4 + ($1?.count ?? 0) }
        return [UInt8](unsafeUninitializedCapacity: total) { buffer, written in
            var at = putBE(UInt32(truncatingIfNeeded: blobs.count), into: buffer, at: 0)
            for blob in blobs {
                guard let blob, let length = UInt32(exactly: blob.count), length != absent else {
                    at = putBE(absent, into: buffer, at: at)
                    continue
                }
                at = putBE(length, into: buffer, at: at)
                if let base = buffer.baseAddress {
                    blob.copyBytes(to: base + at, count: blob.count)
                }
                at += blob.count
            }
            written = at
        }
    }

    static func decode(_ bytes: [UInt8]) -> [Data?]? {
        var reader = bytes[...]
        guard let count = takeBE(&reader) else { return nil }
        var blobs: [Data?] = []
        blobs.reserveCapacity(min(Int(count), reader.count / 4))
        for _ in 0..<count {
            guard let length = takeBE(&reader) else { return nil }
            if length == absent {
                blobs.append(nil)
                continue
            }
            guard reader.count >= Int(length) else { return nil }
            blobs.append(Data(reader.prefix(Int(length))))
            reader = reader.dropFirst(Int(length))
        }
        return reader.isEmpty ? blobs : nil
    }

    /// Reads back a list in which every blob is PRESENT — the send path, where nothing was lost.
    ///
    /// Separate from ``decode(_:)`` rather than a `compactMap` over it because the two differ in what
    /// an absence means: there it is a fragment the wire dropped, here it could only be a marshalling
    /// bug, so the whole list is refused rather than silently one datagram short of a frame.
    static func decodeAll(_ bytes: [UInt8]) -> [Data]? {
        var reader = bytes[...]
        guard let count = takeBE(&reader) else { return nil }
        var blobs: [Data] = []
        blobs.reserveCapacity(min(Int(count), reader.count / 4))
        for _ in 0..<count {
            guard let length = takeBE(&reader), length != absent,
                  reader.count >= Int(length) else { return nil }
            blobs.append(Data(reader.prefix(Int(length))))
            reader = reader.dropFirst(Int(length))
        }
        return reader.isEmpty ? blobs : nil
    }

    /// The two-call retry the boundary's convention asks for: ask with a buffer sized from the
    /// input, and only if the answer does not fit, ask again with one that does. The first guess is
    /// right for every shape the packetizer produces, so the second call is the shape that has not
    /// happened yet rather than the common case.
    ///
    /// `unsafeUninitializedCapacity` rather than `repeating: 0` because this is the per-frame FEC
    /// path: zeroing a buffer the callee is about to overwrite showed up as ~5 µs/group against a
    /// codec that costs ~5, which is the whole reason this is written the careful way.
    static func call(bound: Int, _ body: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8] {
        var needed = 0
        let out = [UInt8](unsafeUninitializedCapacity: bound) { buffer, count in
            needed = body(buffer.baseAddress, buffer.count)
            count = Swift.min(needed, buffer.count)
        }
        guard needed > 0 else { return [] }
        if needed <= bound { return out }
        var grown = 0
        let bigger = [UInt8](unsafeUninitializedCapacity: needed) { buffer, count in
            grown = body(buffer.baseAddress, buffer.count)
            count = Swift.min(grown, buffer.count)
        }
        return grown > 0 && grown <= needed ? bigger : []
    }

    /// An upper bound on a blob list holding `count` blobs no longer than `widest`: the `u32` count,
    /// then a `u32` length and the bytes for each. Exact when every blob is that wide.
    static func bound(count: Int, widest: Int) -> Int {
        4 + count * (4 + widest)
    }

    /// Writes a big-endian `u32` at `at` and answers the next offset.
    private static func putBE(_ value: UInt32, into buffer: UnsafeMutableBufferPointer<UInt8>, at: Int) -> Int {
        buffer[at] = UInt8(truncatingIfNeeded: value >> 24)
        buffer[at + 1] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[at + 2] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[at + 3] = UInt8(truncatingIfNeeded: value)
        return at + 4
    }

    private static func takeBE(_ reader: inout ArraySlice<UInt8>) -> UInt32? {
        guard reader.count >= 4 else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(reader.removeFirst())
        }
        return value
    }
}

/// Compatibility alias: `XORParityFEC` names the type so the many `XORParityFEC(...)` construction
/// and test sites keep building unchanged, even though the FEC engine behind it is the Rust
/// Reed-Solomon codec. `m == 1` keeps the wire byte-identical to plain XOR.
public typealias XORParityFEC = RustReedSolomonFEC
