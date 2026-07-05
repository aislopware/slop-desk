import SlopDeskVideoProtocol

// Micro-benchmark for the Swift-level hot paths the all-Swift migration produced. Isolates the
// CPU codecs (frame hash, GF region multiply, Reed-Solomon FEC encode/recover) from the
// VideoToolbox-dominated pipeline so a before/after optimization delta is visible.
//
//   swift build -c release --product slopdesk-bench && .build/release/slopdesk-bench
import Dispatch
import Foundation

@inline(__always)
func timeNs(_ iters: Int, _ body: () -> Void) -> Double {
    // warmup
    for _ in 0..<max(1, iters / 10) { body() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters { body() }
    let t1 = DispatchTime.now().uptimeNanoseconds
    return Double(t1 - t0) / Double(iters)
}

func fmt(_ ns: Double) -> String {
    if ns >= 1000 { return String(format: "%.2f µs", ns / 1000) }
    return String(format: "%.1f ns", ns)
}

// Deterministic filler (no Math.random) so runs are comparable.
func fill(_ n: Int, _ seed: UInt64) -> [UInt8] {
    var s = seed
    var out = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: s >> 33)
    }
    return out
}

print("=== slopdesk hot-path micro-benchmark (release) ===")

// ---- 1. Frame hash: a 1080p NV12 plane (the per-row lane-fold hot loop) ----
do {
    let w = 1920, h = 1080
    let y = fill(w * h, 1)
    let cbcr = fill(w * (h / 2), 2)
    var sink: UInt64 = 0
    let ns = y.withUnsafeBytes { yb in
        cbcr.withUnsafeBytes { cb in
            timeNs(300) {
                sink &+= FrameHasher.hashNV12(
                    y: yb.baseAddress, yStride: w, width: w, height: h,
                    cbcr: cb.baseAddress, cbcrStride: w,
                )
            }
        }
    }
    let mbps = Double(w * h + w * (h / 2)) / ns // bytes per ns = GB/s
    print("  frameHash 1080p NEON : \(fmt(ns))/frame   (\(String(format: "%.1f", mbps)) GB/s)   [sink \(sink & 0xFF)]")
    // Scalar path — Apple Silicon has a fast native 64-bit multiply; NEON has none (synthesized).
    var sink2: UInt64 = 0
    let nsS = timeNs(300) {
        sink2 &+= FrameHasher.hashNV12Scalar(y: y, yStride: w, width: w, height: h, cbcr: cbcr, cbcrStride: w)
    }
    print(
        "  frameHash 1080p SCALAR: \(fmt(nsS))/frame   (\(String(format: "%.1f", Double(w * h + w * (h / 2)) / nsS)) GB/s)   [sink \(sink2 & 0xFF)]   identical=\(sink == sink2)",
    )
}

// ---- 2. GF(2^8) region multiply: 64 KiB (the FEC inner loop, NEON kernel) ----
do {
    let n = 65536
    let src = fill(n, 3)
    var dst = fill(n, 4)
    let gf = NeonGf()
    let ns = timeNs(2000) { gf.mulAdd(coeff: 0xB7, src: src, dst: &dst) }
    let gbs = Double(n) / ns
    print("  GF region mulAdd 64KiB: \(fmt(ns))/op       (\(String(format: "%.1f", gbs)) GB/s)   [sink \(dst[0])]")
}

// ---- 3. Reed-Solomon FEC: encode + recover, k=8 shards x 1200B, m=2, 2 holes ----
do {
    let k = 8, shardLen = 1200
    let data: [Data] = (0..<k).map { Data(fill(shardLen, UInt64(10 + $0))) }
    let fec = RustReedSolomonFEC(groupSize: k, parityCount: 2)
    var sink = 0
    let encNs = timeNs(3000) { sink &+= fec.parity(forDataFragments: data, groupSize: k).count }
    let parity = fec.parity(forDataFragments: data, groupSize: k)
    var holed: [Data?] = data
    holed[2] = nil
    holed[5] = nil // 2 erasures, recoverable with m=2
    let par: [Data?] = parity.map(\.self)
    let recNs = timeNs(3000) { sink &+= (fec.recover(dataFragments: holed, parityFragments: par, groupSize: k).count) }
    print("  FEC encode (k8 m2)   : \(fmt(encNs))/group")
    print("  FEC recover (2 holes): \(fmt(recNs))/group   [sink \(sink & 0xFF)]")
}

// ---- reference values (value-stability pins for the optimization pass) ----
if CommandLine.arguments.contains("--dump") {
    print("=== reference values (must stay identical after optimization) ===")
    for (w, h, seed) in [(64, 4, UInt64(7)), (1920, 1080, UInt64(99)), (17, 9, UInt64(123))] {
        let y = fill(w * h, seed)
        let cbcr = fill(w * (h / 2 == 0 ? 1 : h / 2), seed &+ 1)
        let hv = y.withUnsafeBytes { yb in
            cbcr.withUnsafeBytes { cb in
                FrameHasher.hashNV12(
                    y: yb.baseAddress,
                    yStride: w,
                    width: w,
                    height: h,
                    cbcr: cb.baseAddress,
                    cbcrStride: w,
                )
            }
        }
        // stride > width case (padded plane)
        let yp = fill((w + 13) * h, seed &+ 2)
        let hp = yp.withUnsafeBytes { yb in
            FrameHasher.hashNV12(
                y: yb.baseAddress,
                yStride: w + 13,
                width: w,
                height: h,
                cbcr: nil,
                cbcrStride: 0,
            )
        }
        print("  hashNV12 w=\(w) h=\(h): contiguous=0x\(String(hv, radix: 16)) padded=0x\(String(hp, radix: 16))")
    }
    let k = 8
    let data: [Data] = (0..<k).map { Data(fill(1200, UInt64(10 + $0))) }
    let p = RustReedSolomonFEC(groupSize: k, parityCount: 2).parity(forDataFragments: data, groupSize: k)
    print("  FEC parity[0] first8: \(p[0].prefix(8).map { String($0, radix: 16) }.joined(separator: ","))")
}

print("=== done ===")
