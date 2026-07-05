// A strong, SIMD-friendly 64-bit hash of an NV12 video frame, used by the host to detect a
// pixel-identical re-delivery and skip re-encoding it (static-frame suppression).
//
// This is the resurrected, native-Swift port of the Rust `slopdesk-core::frame_hash` reference
// (`StreamHasher` / `hash_nv12`) — the all-Swift migration deletes the Rust core + FFI boundary.
// The entire hash is PURE SCALAR Swift: the lane seeding, the 32-byte main loop, the `< 32`-byte
// tail, the cross-row buffering, and the finalize all run in `StreamHasher` here.
//
// ## Why no NEON kernel
//
// An xxHash64-block NEON kernel once folded the aligned 32-byte blocks via `CSlopDeskSIMD`, but
// it was MEASURED 3.4× SLOWER than the scalar fold on Apple Silicon (≈730µs vs 213µs per 1080p
// frame): xxHash64 is 64-bit-multiply-heavy and aarch64 NEON has no native 64-bit lane multiply
// (the kernel had to synthesize each `vmulq_u64` from ~6 ops), while the scalar `mul` is 1–3
// cycles. So frame hashing runs scalar; the NEON kernel and its `updateNeon`/`foldAlignedBlocks`
// seam were removed. (The GF(2^8) NEON kernel STAYS — byte-table lookup IS NEON-friendly.) The two
// public entry points (`hashNV12` pointer, `hashNV12Scalar` array) both fold scalar and are proven
// byte-identical by `FrameHashNeonDifferentialTests`.
//
// ## Why this exists
//
// `ScreenCaptureKit` occasionally re-delivers a `.complete` frame whose pixels are byte-identical
// to the previous one. Encoding such a frame wastes the encoder slot and the link. Hashing the
// captured planes and comparing to the last submitted frame's hash drops the duplicate before it
// reaches the encoder.
//
// ## Stride safety
//
// The hash reads ONLY the first `width` bytes of each `stride`-spaced row, so two captures of the
// same image hash identically regardless of how the allocator padded the rows — and a one-pixel
// change anywhere inside the visible area always changes the hash.
//
// ## Bit-exact traps (INTEGER WRAPPING — never plain `+`/`*`/`-`, which TRAP in release):
//   * every Rust `wrapping_mul`/`wrapping_add`/`wrapping_sub` → Swift `&*`/`&+`/`&-`.
//   * every `rotate_left(n)` → `(x << n) | (x >> (64 - n))` on UInt64 (`rotl64`).
//   * `le_u64` / `le_u32` zero-fill past the buffer end (panic-free over-read).
//   * the cross-row 32-byte buffering must land the block boundary identically regardless of how a
//     plane is sliced, so the contiguous fast path and the per-row path agree to the bit.

/// xxHash64 lane primes (large odd constants).
public enum FrameHash {
    /// The first xxHash64 lane prime.
    static let prime64A: UInt64 = 0x9E37_79B1_85EB_CA87
    /// The second xxHash64 lane prime.
    static let prime64B: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    static let prime64C: UInt64 = 0x1656_67B1_9E37_79F9
    static let prime64D: UInt64 = 0x85EB_CA77_C2B2_AE63
    static let prime64E: UInt64 = 0x2752_5BA1_84B2_3A5D

    /// The fixed seed for the NV12 frame hash ("AISLOPDE"). A constant (not env-tunable) so every
    /// consumer agrees on the exact value for a given frame image.
    public static let frameHashSeed: UInt64 = 0x4149_534C_4F50_4445

    /// The value a degenerate / null-guarded call returns instead of hashing — `UInt64.max`,
    /// distinct from `0` so a genuine all-zero plane (which hashes to a real avalanche value, not 0)
    /// is never confused with it. Mirrors `AISD_FRAME_HASH_SENTINEL`.
    public static let SENTINEL: UInt64 = .max
}

/// Rotate-left a 64-bit value by `r` (1...63): `(x << r) | (x >> (64 - r))`. NEVER use a stdlib
/// rotate helper — written out so it is obviously the same op the C kernel and the Rust reference
/// perform. `r` is always in 1...63 on every call site here, so `64 - r` never shifts by 64 (UB).
@inline(__always)
func rotl64(_ x: UInt64, _ r: UInt64) -> UInt64 {
    (x << r) | (x >> (64 &- r))
}

/// Seeds the four accumulator lanes from a base seed, exactly as xxHash64 does (`+P1+P2`, `+P2`,
/// `0`, `-P1`). WRAPPING adds/sub.
@inline(__always)
func seedLanes(_ seed: UInt64) -> (UInt64, UInt64, UInt64, UInt64) {
    (
        seed &+ FrameHash.prime64A &+ FrameHash.prime64B,
        seed &+ FrameHash.prime64B,
        seed,
        seed &- FrameHash.prime64A,
    )
}

/// One xxHash64 round: `acc = rotl(acc + lane * P2, 31) * P1`. WRAPPING mul/add + manual rotl.
@inline(__always)
func xxhRound(_ acc: UInt64, _ lane: UInt64) -> UInt64 {
    rotl64(acc &+ (lane &* FrameHash.prime64B), 31) &* FrameHash.prime64A
}

/// Reads 8 little-endian bytes of `buf` starting at `off` as a `u64`, panic-free: bytes past the end
/// read as 0. Mirrors the Rust `le_u64` (over-read ⇒ zero-fill).
@inline(__always)
func leU64(_ buf: UnsafeBufferPointer<UInt8>, _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    let end = min(off + 8, buf.count)
    var i = off
    var shift: UInt64 = 0
    while i < end {
        v |= UInt64(buf[i]) << shift
        shift &+= 8
        i += 1
    }
    return v
}

/// Reads 4 little-endian bytes of `buf` starting at `off` as a `u32`, panic-free (over-read ⇒ 0).
@inline(__always)
func leU32(_ buf: UnsafeBufferPointer<UInt8>, _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    let end = min(off + 4, buf.count)
    var i = off
    var shift: UInt32 = 0
    while i < end {
        v |= UInt32(buf[i]) << shift
        shift &+= 8
        i += 1
    }
    return v
}

/// A streaming xxHash64 over a byte stream presented in pieces (the visible un-padded rows of a
/// plane), carrying the partial 32-byte block across rows so the result equals hashing the
/// concatenation of all visible rows.
///
/// PURE SCALAR — the single source of truth and the only fold path. Both public `FrameHasher`
/// entry points (`hashNV12`, `hashNV12Scalar`) drive this hasher's `update`, so they are byte-identical.
public struct StreamHasher {
    /// The four 64-bit lane accumulators (xxHash64 state) once ≥32 bytes have been seen.
    private var lanes: (UInt64, UInt64, UInt64, UInt64)
    /// The seed (the hash base for a <32-byte total — xxHash64's short path).
    private let seed: UInt64
    /// Total bytes consumed so far (folded into the finish, selects short vs long path). WRAPPING.
    private var total: UInt64
    /// Bytes buffered toward the next full 32-byte block (0..<32).
    private var buf: [UInt8]
    private var bufLen: Int
    /// Whether the 32-byte main loop has ever run (⇒ use `lanes`, not the seed short path).
    private var started: Bool

    /// A fresh hasher seeded with `seed`.
    public init(seed: UInt64) {
        lanes = seedLanes(seed)
        self.seed = seed
        total = 0
        buf = [UInt8](repeating: 0, count: 32)
        bufLen = 0
        started = false
    }

    /// Folds one full 32-byte block (four little-endian u64 lanes) into the accumulators.
    @inline(__always)
    private mutating func consumeBlock(_ block: UnsafeBufferPointer<UInt8>) {
        lanes.0 = xxhRound(lanes.0, leU64(block, 0))
        lanes.1 = xxhRound(lanes.1, leU64(block, 8))
        lanes.2 = xxhRound(lanes.2, leU64(block, 16))
        lanes.3 = xxhRound(lanes.3, leU64(block, 24))
        started = true
    }

    /// Appends the `count` bytes at `base` to the stream. Buffers across calls so row-by-row feeding
    /// is exact. Mirrors the Rust `StreamHasher::update`.
    public mutating func update(_ base: UnsafePointer<UInt8>, _ count: Int) {
        total = total &+ UInt64(count)
        let input = UnsafeBufferPointer(start: base, count: count)
        var pos = 0

        // Top off a partially-filled buffer first.
        if bufLen > 0 {
            let need = 32 - bufLen
            let take = min(need, input.count - pos)
            for i in 0..<take { buf[bufLen + i] = input[pos + i] }
            bufLen += take
            pos += take
            if bufLen == 32 {
                buf.withUnsafeBufferPointer { consumeBlock($0) }
                bufLen = 0
            } else {
                return // still didn't fill a block
            }
        }

        // Consume full 32-byte blocks straight out of `input` (use `base`, already non-optional).
        while input.count - pos >= 32 {
            let block = UnsafeBufferPointer(start: base + pos, count: 32)
            consumeBlock(block)
            pos += 32
        }

        // Stash the remainder for next time.
        let rest = input.count - pos
        if rest > 0 {
            for i in 0..<rest { buf[i] = input[pos + i] }
            bufLen = rest
        }
    }

    /// Consumes the hasher and returns the final 64-bit hash (merge-lanes or the short path, then the
    /// tail + avalanche). Mirrors the Rust `StreamHasher::finish`.
    public func finish() -> UInt64 {
        let base: UInt64 =
            if started {
                mergeLanes(lanes)
            } else {
                // Short input (< 32 bytes total): xxHash64 starts from `seed + PRIME5`.
                seed &+ FrameHash.prime64E
            }
        return buf.withUnsafeBufferPointer { full in
            let tail = UnsafeBufferPointer(start: full.baseAddress, count: bufLen)
            return finalizeTail(base, tail, total)
        }
    }
}

/// Merges one finished lane accumulator into the running 64-bit hash (xxHash64's `mergeRound`).
@inline(__always)
private func mergeRound(_ hash: UInt64, _ acc: UInt64) -> UInt64 {
    let h = hash ^ xxhRound(0, acc)
    return (h &* FrameHash.prime64A) &+ FrameHash.prime64D
}

/// Combines the four lane accumulators into a single 64-bit value (xxHash64's long-input fold):
/// `rotl(a1,1)+rotl(a2,7)+rotl(a3,12)+rotl(a4,18)`, then four merges.
@inline(__always)
func mergeLanes(_ lanes: (UInt64, UInt64, UInt64, UInt64)) -> UInt64 {
    let (a1, a2, a3, a4) = lanes
    var hash = rotl64(a1, 1) &+ rotl64(a2, 7) &+ rotl64(a3, 12) &+ rotl64(a4, 18)
    hash = mergeRound(hash, a1)
    hash = mergeRound(hash, a2)
    hash = mergeRound(hash, a3)
    hash = mergeRound(hash, a4)
    return hash
}

/// xxHash64's final avalanche: scrambles every bit of the folded value. WRAPPING muls.
@inline(__always)
func avalanche(_ h0: UInt64) -> UInt64 {
    var h = h0
    h ^= h >> 33
    h = h &* FrameHash.prime64B
    h ^= h >> 29
    h = h &* FrameHash.prime64C
    h ^= h >> 32
    return h
}

/// Folds a sub-32-byte tail (plus the total length) into the hash, reproducing xxHash64's tail loop:
/// 8-byte groups, then a 4-byte group, then single bytes; then avalanche. WRAPPING throughout.
@inline(__always)
func finalizeTail(_ hash0: UInt64, _ tail: UnsafeBufferPointer<UInt8>, _ totalLen: UInt64) -> UInt64 {
    var hash = hash0 &+ totalLen
    var off = 0
    // 8-byte groups.
    while tail.count - off >= 8 {
        let k = xxhRound(0, leU64(tail, off))
        hash ^= k
        hash = (rotl64(hash, 27) &* FrameHash.prime64A) &+ FrameHash.prime64D
        off += 8
    }
    // One 4-byte group.
    if tail.count - off >= 4 {
        let k = UInt64(leU32(tail, off))
        hash ^= k &* FrameHash.prime64A
        hash = (rotl64(hash, 23) &* FrameHash.prime64B) &+ FrameHash.prime64C
        off += 4
    }
    // Remaining single bytes.
    while off < tail.count {
        hash ^= UInt64(tail[off]) &* FrameHash.prime64E
        hash = rotl64(hash, 11) &* FrameHash.prime64A
        off += 1
    }
    return avalanche(hash)
}

/// The NV12 frame hasher. Two public entry points, both PURE SCALAR and byte-identical: the
/// pointer-based `hashNV12` (the zero-copy entry the host calls over borrowed plane pointers) and
/// the array-based `hashNV12Scalar` (drives the same `StreamHasher` walk from Swift arrays so the
/// test can exercise it without raw pointers). The differential test pins the two equal.
public enum FrameHasher {
    // MARK: - Pointer public entry (matches the old `aisd_frame_hash_nv12` ABI)

    /// Hashes an NV12 frame's already-locked luma + interleaved-chroma planes into one strong 64-bit
    /// value over BORROWED plane pointers (zero-copy). Reads ONLY the first `width` bytes of each
    /// `*Stride`-spaced row (padding-independent). Returns `FrameHash.SENTINEL` for a null `y` / zero
    /// dims / `yStride < width` / a `stride * height` overflow (never a crash). `cbcr == nil` ⇒
    /// luma-only. Folds the aligned 32-byte blocks with the scalar `StreamHasher`.
    public static func hashNV12(
        y: UnsafeRawPointer?,
        yStride: Int,
        width: Int,
        height: Int,
        cbcr: UnsafeRawPointer?,
        cbcrStride: Int,
    ) -> UInt64 {
        guard let y, width > 0, height > 0, yStride >= width else { return FrameHash.SENTINEL }
        // `checked_mul` analogue: a hostile stride*height must not wrap the implied length.
        let (yLen, yOverflow) = yStride.multipliedReportingOverflow(by: height)
        if yOverflow { return FrameHash.SENTINEL }

        let yPlane = UnsafeBufferPointer(
            start: y.assumingMemoryBound(to: UInt8.self), count: yLen,
        )

        var hasher = StreamHasher(seed: FrameHash.frameHashSeed)
        hashPlaneScalar(&hasher, yPlane, yStride, width, height)

        // NV12 chroma: half the luma height; each row carries `width / 2` interleaved Cb,Cr pairs ⇒
        // `(width / 2) * 2` even bytes/row. Luma-only when null / zero stride / no chroma rows.
        let chromaRows = height / 2
        if let cbcr, cbcrStride > 0, chromaRows > 0 {
            let (cLen, cOverflow) = cbcrStride.multipliedReportingOverflow(by: chromaRows)
            if !cOverflow {
                let cbcrPlane = UnsafeBufferPointer(
                    start: cbcr.assumingMemoryBound(to: UInt8.self), count: cLen,
                )
                let chromaWidth = (width / 2) * 2
                hashPlaneScalar(&hasher, cbcrPlane, cbcrStride, chromaWidth, chromaRows)
            }
            // A pathological stride*rows overflow ⇒ fall back to luma-only rather than fault.
        }
        return hasher.finish()
    }

    // MARK: - Scalar reference entry (the single source of truth)

    /// The array-driven NV12 hash: identical lane seeding / plane walk / tail / scalar
    /// `StreamHasher.update` fold as `hashNV12`, but operating over Swift arrays so the differential
    /// test can drive it without raw pointers. Pinned byte-identical to the pointer entry.
    public static func hashNV12Scalar(
        y: [UInt8],
        yStride: Int,
        width: Int,
        height: Int,
        cbcr: [UInt8],
        cbcrStride: Int,
    ) -> UInt64 {
        var hasher = StreamHasher(seed: FrameHash.frameHashSeed)
        y.withUnsafeBufferPointer { yBuf in
            hashPlaneScalar(&hasher, yBuf, yStride, width, height)
        }
        let chromaWidth = (width / 2) * 2
        cbcr.withUnsafeBufferPointer { cBuf in
            hashPlaneScalar(&hasher, cBuf, cbcrStride, chromaWidth, height / 2)
        }
        return hasher.finish()
    }

    // MARK: - Single contiguous-row entry (allocation-free; for per-row hashing)

    /// Hashes ONE contiguous run of `buf` bytes into a 64-bit value, byte-identical to
    /// `hashNV12(y: buf.base, yStride: buf.count, width: buf.count, height: 1, cbcr: nil)` — i.e. the
    /// frame hash of a single luma-only row — but WITHOUT constructing a `StreamHasher` (whose 32-byte
    /// carry buffer is a heap allocation). The per-row scroll/adaptive-QP hashers call this thousands
    /// of times per frame, so the saved allocation matters; the fold itself is the same xxHash64 walk
    /// (full 32-byte blocks straight from `buf`, then the `< 32`-byte tail), so the result is provably
    /// the same value the streaming hasher would produce for that single contiguous run.
    static func hashRow(_ buf: UnsafeBufferPointer<UInt8>, seed: UInt64) -> UInt64 {
        // A null / empty run is the xxHash64 short path over zero bytes (seed + PRIME5, no tail).
        guard let base = buf.baseAddress, !buf.isEmpty else {
            return finalizeTail(seed &+ FrameHash.prime64E, UnsafeBufferPointer(start: nil, count: 0), 0)
        }
        let n = buf.count
        var off = 0
        let baseHash: UInt64
        // ≥ 32 bytes ⇒ run the four-lane main loop over the aligned 32-byte blocks (started path);
        // otherwise the short path starts from `seed + PRIME5` and the whole run is the tail.
        if n >= 32 {
            var lanes = seedLanes(seed)
            while n - off >= 32 {
                lanes.0 = xxhRound(lanes.0, leU64(buf, off))
                lanes.1 = xxhRound(lanes.1, leU64(buf, off &+ 8))
                lanes.2 = xxhRound(lanes.2, leU64(buf, off &+ 16))
                lanes.3 = xxhRound(lanes.3, leU64(buf, off &+ 24))
                off &+= 32
            }
            baseHash = mergeLanes(lanes)
        } else {
            baseHash = seed &+ FrameHash.prime64E
        }
        // The remainder `[off, n)` is the `< 32`-byte tail — point `finalizeTail` straight at it.
        let tail = UnsafeBufferPointer(start: base + off, count: n - off)
        return finalizeTail(baseHash, tail, UInt64(n))
    }

    // MARK: - Plane walk (the single scalar fold both entry points drive)

    /// Folds the visible `width × height` region of one `stride`-spaced plane into `hasher` via the
    /// SCALAR `StreamHasher.update`. Only the first `width` bytes of each row are read; a truncated
    /// plane stops early.
    static func hashPlaneScalar(
        _ hasher: inout StreamHasher,
        _ plane: UnsafeBufferPointer<UInt8>,
        _ stride: Int, _ width: Int, _ height: Int,
    ) {
        if width == 0 || height == 0 || stride < width { return }
        guard let pBase = plane.baseAddress else { return }
        // CONTIGUOUS FAST PATH: when there is no row padding (`stride == width`), the visible region
        // is `width * height` back-to-back bytes — one `update` over that run is byte-identical to the
        // per-row loop (the streaming hash is associative over how a contiguous run is sliced). Skips
        // ~`height` separate dispatches. Guarded so a truncated plane still stops early via the loop.
        let total = width * height
        if stride == width, total <= plane.count {
            hasher.update(pBase, total)
            return
        }
        for row in 0..<height {
            let start = row * stride
            let end = start + width
            if end > plane.count { break }
            hasher.update(pBase + start, width)
        }
    }
}
