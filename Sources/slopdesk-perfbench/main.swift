// slopdesk-perfbench — headless VideoToolbox encode/decode TIMING benchmark.
//
// The loopback-validate tool proves FEC/wire CORRECTNESS but never measures processing TIME.
// This tool answers the performance question the user asked: on THIS machine, with network
// removed, where does the remote-window pipeline spend its milliseconds, and where does quality
// (blur) get lost? It drives the REAL production VideoEncoder + VideoDecoder + packetizer/FEC at
// the ACTUAL host configs (resolution × LiveBitratePolicy bitrate × fps × content-motion) and
// reports per-frame encode latency, output size (→ effective bitrate/QP starvation), drops,
// decode latency, and packetize+FEC time.
//
// Runs from a normal shell (VT hangs only inside xctest). macOS-only.
//
// USAGE: slopdesk-perfbench [--frames N] [--quick] [--bpp X]

import Foundation

#if os(macOS)
import CoreMedia
import CoreVideo
import SlopDeskVideoClient
import SlopDeskVideoHost
import SlopDeskVideoProtocol
import VideoToolbox

// MARK: - CLI

var gFrames = 240
var gQuick = false
do {
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        switch argv[i] {
        case "--frames": if i + 1 < argv.count, let v = Int(argv[i + 1]) { gFrames = v
                i += 1
            }
        case "--quick": gQuick = true
            gFrames = 120
        default: break
        }
        i += 1
    }
}

func nowSec() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0 }
func pctl(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, max(0, Int((p / 100.0) * Double(sorted.count - 1))))
    return sorted[idx]
}

func msStr(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
extension Int { func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) } }

// MARK: - NV12 pool: vertical-scroll shifts of one rich "desktop text" pattern (motion worst case)

final class FramePool {
    let width: Int, height: Int, count: Int
    private var buffers: [CVPixelBuffer] = []
    // `hard`: each pool frame is a SCROLL of a rich text-like base PLUS a per-frame re-rasterization
    // layer (text hinting / AA changes as content moves sub-pixel) + a small noise floor + a fresh
    // band of content scrolling in. That residual is what makes real desktop scroll cost 40-280 KB
    // per frame (a pure translation motion-compensates to ~nothing — unrealistically easy).
    init?(width: Int, height: Int, poolCount: Int) {
        self.width = width
        self.height = height
        count = poolCount
        let baseH = height + poolCount * 4 + 4
        var base = [UInt8](repeating: 0, count: width * baseH)
        for y in 0..<baseH {
            let yband = (y >> 3) & 1
            let isTextRow = (y % 18) < 11 // ~text lines with inter-line gaps
            for x in 0..<width {
                var v = 30
                if isTextRow {
                    // dense glyph-like strokes: thin verticals + serifs, high spatial frequency
                    let glyph = ((UInt(x) &* 2_654_435_761 >> 8) ^ (UInt(y) &* 40503)) & 0xFF
                    v = (glyph < 90) ? 20 : (glyph < 150 ? 220 : 60)
                }
                let checker = (((x >> 6) & 1) ^ yband) == 0 ? 0 : 12
                base[y * width + x] = UInt8((v + checker) & 0xFF)
            }
        }
        for f in 0..<poolCount {
            guard let pb = Self.makeNV12(width: width, height: height) else { return nil }
            let shift = f * 4 // scroll 4 px/frame (≈ a real trackpad scroll velocity at 60fps)
            CVPixelBufferLockBaseAddress(pb, [])
            if let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let yptr = yb.assumingMemoryBound(to: UInt8.self)
                let ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                base.withUnsafeBufferPointer { bp in
                    guard let bb = bp.baseAddress else { return }
                    for y in 0..<height {
                        let src = bb + (y + shift) * width
                        let dst = yptr + y * ystride
                        for x in 0..<width {
                            // scrolled base + per-frame re-rasterization noise (AA / hinting jitter)
                            let n =
                                Int((UInt(x) &* 1_103_515_245 &+ UInt(y) &* 12345 &+ UInt(f) &* 2_246_822_519) >> 25) &
                                0x0F
                            dst[x] = UInt8((Int(src[x]) &+ n - 8).clamped(0, 255))
                        }
                    }
                }
            }
            if let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                let cptr = cb.assumingMemoryBound(to: UInt8.self)
                let cstride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                for y in 0..<(height / 2) {
                    let row = cptr + y * cstride
                    for x in 0..<width { row[x] = 128 }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            buffers.append(pb)
        }
    }

    func frame(_ i: Int) -> CVPixelBuffer { buffers[i % count] }
    static func makeNV12(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let s = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb,
        )
        return s == kCVReturnSuccess ? pb : nil
    }
}

// MARK: - Encode: back-to-back throughput + sizes, and clean per-frame latency

final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var sizes: [Int] = []
    var keyframes = 0
    var stream: [(Data, Bool)] = []
    func add(_ avcc: Data, kf: Bool) {
        lock.lock()
        sizes.append(avcc.count)
        if kf { keyframes += 1 }
        if stream.count < 200 { stream.append((avcc, kf)) }
        lock.unlock()
    }

    func reset() { lock.lock()
        sizes.removeAll()
        keyframes = 0
        stream.removeAll()
        lock.unlock()
    }
}

struct ThroughputResult {
    var thru: Double
    var encoded: Int
    var drops: Int
    var avgKB: Double
    var p95KB: Double
    var maxKB: Double
    var effMbps: Double
    var keyframes: Int
    var stream: [(Data, Bool)]
}

struct LatencyResult {
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
    var over: Int
    var budgetMs: Double
}

struct DecodeResult {
    var p50: Double
    var p95: Double
    var max: Double
    var ok: Int
    var fail: Int
}

/// Back-to-back encode of `frames` motion frames. Throughput = encoded / wall (sustainable fps).
/// Also returns output-size distribution + effective Mbps at the given fps.
func benchThroughput(width: Int, height: Int, fps: Int, bitrate: Int, pool: FramePool, frames: Int)
    -> ThroughputResult?
{
    let c = Counter()
    let enc = VideoEncoder(width: width, height: height, bitrate: bitrate, fps: fps) { avcc, kf, _, _, _ in
        c.add(avcc, kf: kf)
    }
    do { try enc.createLiveSession() } catch { print("  ENCODER CREATE FAILED: \(error)")
        return nil
    }
    for i in 0..<12 {
        try? enc.encodeLive(
            pixelBuffer: pool.frame(i),
            presentationTime: CMTime(value: Int64(i), timescale: Int32(fps)),
            forceKeyframe: i == 0,
        )
    }
    enc.completeFrames()
    c.reset()

    let t0 = nowSec()
    for i in 0..<frames {
        try? enc.encodeLive(
            pixelBuffer: pool.frame(i),
            presentationTime: CMTime(value: Int64(1000 + i), timescale: Int32(fps)),
            forceKeyframe: i == 0,
        )
    }
    enc.completeFrames()
    let t1 = nowSec()
    c.lock.lock()
    let sizes = c.sizes
    let kf = c.keyframes
    let outStream = c.stream
    c.lock.unlock()
    let encoded = sizes.count
    let wall = t1 - t0
    let thru = wall > 0 ? Double(encoded) / wall : 0
    let sorted = sizes.map { Double($0) }.sorted()
    let totalBytes = sizes.reduce(0, +)
    let effMbps = wall > 0 ? Double(totalBytes) * 8.0 / wall / 1_000_000.0 : 0
    return ThroughputResult(
        thru: thru,
        encoded: encoded,
        drops: frames - encoded,
        avgKB: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count) / 1024,
        p95KB: pctl(sorted, 95) / 1024,
        maxKB: (sorted.last ?? 0) / 1024,
        effMbps: effMbps,
        keyframes: kf,
        stream: outStream,
    )
}

/// Clean per-frame latency: submit one motion frame, drain, time submit->callback. No pipelining.
func benchLatency(width: Int, height: Int, fps: Int, bitrate: Int, pool: FramePool, frames: Int)
    -> LatencyResult?
{
    final class Box: @unchecked Sendable { let lock = NSLock()
        var t = 0.0
    }
    let box = Box()
    let enc = VideoEncoder(width: width, height: height, bitrate: bitrate, fps: fps) { _, _, _, _, _ in
        box.lock.lock()
        box.t = nowSec()
        box.lock.unlock()
    }
    do { try enc.createLiveSession() } catch { return nil }
    for i in 0..<10 {
        try? enc.encodeLive(
            pixelBuffer: pool.frame(i),
            presentationTime: CMTime(value: Int64(i), timescale: Int32(fps)),
            forceKeyframe: i == 0,
        )
        enc.completeFrames()
    }
    var lat: [Double] = []
    for i in 0..<frames {
        box.lock.lock()
        box.t = 0
        box.lock.unlock()
        let s = nowSec()
        try? enc.encodeLive(
            pixelBuffer: pool.frame(i),
            presentationTime: CMTime(value: Int64(10000 + i), timescale: Int32(fps)),
            forceKeyframe: false,
        )
        enc.completeFrames()
        box.lock.lock()
        let done = box.t
        box.lock.unlock()
        if done > 0 { lat.append(done - s) }
    }
    let sorted = lat.sorted()
    let budgetMs = 1000.0 / Double(fps)
    return LatencyResult(
        p50: pctl(sorted, 50),
        p95: pctl(sorted, 95),
        p99: pctl(sorted, 99),
        max: sorted.last ?? 0,
        over: lat.count(where: { $0 * 1000 > budgetMs }),
        budgetMs: budgetMs,
    )
}

// MARK: - Decode + packetize/FEC timing on a real stream

func benchDecode(_ stream: [(Data, Bool)]) -> DecodeResult {
    let dec = VideoDecoder { _ in }
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    let pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var hostTs: UInt32 = 1
    var lat: [Double] = []
    var ok = 0, fail = 0
    for (avcc, kf) in stream {
        let frags = pk.packetize(frame: avcc, keyframe: kf, hostSendTsMillis: hostTs, fecTier: 0, isLTR: false)
        hostTs &+= 16
        for frag in frags {
            guard let parsed = try? FrameFragment.decode(frag.encode()) else { continue }
            if case let .completed(f) = ra.ingest(parsed) {
                let s = nowSec()
                do { try dec.decode(f)
                    lat.append(nowSec() - s)
                    ok += 1
                } catch { fail += 1 }
            }
        }
    }
    let sorted = lat.sorted()
    return DecodeResult(p50: pctl(sorted, 50), p95: pctl(sorted, 95), max: sorted.last ?? 0, ok: ok, fail: fail)
}

func benchPacketize(_ stream: [(Data, Bool)], fecM: Int) -> (p50: Double, p95: Double, max: Double) {
    var lat: [Double] = []
    let pk = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: 5, parityCount: fecM))
    var hostTs: UInt32 = 1
    for (avcc, kf) in stream {
        let s = nowSec()
        _ = pk.packetize(frame: avcc, keyframe: kf, hostSendTsMillis: hostTs, fecTier: fecM >= 2 ? 4 : 0, isLTR: false)
        lat.append(nowSec() - s)
        hostTs &+= 16
    }
    let sorted = lat.sorted()
    return (pctl(sorted, 50), pctl(sorted, 95), sorted.last ?? 0)
}

// MARK: - Run

print("=== slopdesk-perfbench — Apple M1 Max, headless VT, network removed ===")
print("frames/config=\(gFrames)  motion=full vertical scroll (rate-control + encoder worst case)")
print("bitrate per config = LiveBitratePolicy(bpp=\(LiveBitratePolicy.bitsPerPixelPerFrame), floor 12Mbps)\n")

struct Cfg { let w: Int
    let h: Int
    let fps: Int
    let label: String
}

let configs: [Cfg] = gQuick ? [
    Cfg(w: 1920, h: 1080, fps: 30, label: "1080p30 herdr/current"),
    Cfg(w: 3840, h: 2160, fps: 30, label: "2160p30 VD-2x default"),
] : [
    Cfg(w: 1920, h: 1080, fps: 60, label: "1080p60 (scale1.0 profile)"),
    Cfg(w: 2400, h: 1350, fps: 60, label: "2400x1350@60 (scale1.25)"),
    Cfg(w: 2880, h: 1620, fps: 60, label: "2880x1620@60 (scale1.5)"),
    Cfg(w: 2816, h: 1778, fps: 60, label: "2816x1778@60 VD-2x win"),
    Cfg(w: 3840, h: 2160, fps: 60, label: "2160p60 VD-2x full"),
    Cfg(w: 3840, h: 2160, fps: 30, label: "2160p30 VD-2x full"),
]

print(pad("config", 24) + lpad("fps", 4) + lpad("Mbit", 7) + lpad("thruFps", 9)
    + lpad("drop", 6) + lpad("effMbps", 9) + lpad("avgKB", 8) + lpad("p95KB", 8)
    + lpad("enc99", 8) + lpad("over", 6))
print(String(repeating: "-", count: 90))

var firstStream: [(Data, Bool)] = []
for cfg in configs {
    guard let pool = FramePool(width: cfg.w, height: cfg.h, poolCount: 16)
    else { print("  \(cfg.label): pool alloc failed")
        continue
    }
    let bitrate = LiveBitratePolicy.targetBitrate(
        pixelWidth: cfg.w,
        pixelHeight: cfg.h,
        fps: cfg.fps,
        floor: 12_000_000,
    )
    guard let t = benchThroughput(
        width: cfg.w,
        height: cfg.h,
        fps: cfg.fps,
        bitrate: bitrate,
        pool: pool,
        frames: gFrames,
    ) else { continue }
    let lat = benchLatency(
        width: cfg.w,
        height: cfg.h,
        fps: cfg.fps,
        bitrate: bitrate,
        pool: pool,
        frames: min(120, gFrames),
    )
    // Reference at 150 Mbps: the size the SAME content "wants" un-starved. avgKB_ref / avgKB tells us
    // how hard the production budget is coarsening motion frames (the blur = QP starvation ratio).
    let ref = benchThroughput(
        width: cfg.w,
        height: cfg.h,
        fps: cfg.fps,
        bitrate: 150_000_000,
        pool: pool,
        frames: min(120, gFrames),
    )
    if firstStream.isEmpty { firstStream = t.stream }
    let enc99 = lat.map { msStr($0.p99) } ?? "?"
    let over = lat.map { String($0.over) } ?? "?"
    print(pad(cfg.label, 24)
        + lpad(String(cfg.fps), 4)
        + lpad(String(format: "%.0f", Double(bitrate) / 1_000_000), 7)
        + lpad(String(format: "%.1f", t.thru), 9)
        + lpad(String(t.drops), 6)
        + lpad(String(format: "%.1f", t.effMbps), 9)
        + lpad(String(format: "%.1f", t.avgKB), 8)
        + lpad(String(format: "%.0f", t.p95KB), 8)
        + lpad(enc99, 8)
        + lpad(over, 6))
    if let lat {
        let starve = ref.map { $0.avgKB > 0 ? $0.avgKB / max(0.01, t.avgKB) : 0 } ?? 0
        print(
            "      encLat p50=\(msStr(lat.p50)) p95=\(msStr(lat.p95)) p99=\(msStr(lat.p99)) max=\(msStr(lat.max)) ms  (budget \(String(format: "%.1f", lat.budgetMs))ms over=\(lat.over)/\(min(120, gFrames)))  maxKB=\(String(format: "%.0f", t.maxKB))",
        )
        print(
            "      QP-starvation: motion frame avg \(String(format: "%.1f", t.avgKB))KB @\(Int(bitrate / 1_000_000))Mbps  vs  \(String(format: "%.1f", ref?.avgKB ?? 0))KB @150Mbps  →  \(String(format: "%.1fx", starve)) coarser (higher = more blur)",
        )
    }
}

print("\n=== decode + packetize/FEC timing (first config's motion stream, n=\(firstStream.count)) ===")
if !firstStream.isEmpty {
    let d = benchDecode(firstStream)
    print("  decode         p50=\(msStr(d.p50)) p95=\(msStr(d.p95)) max=\(msStr(d.max)) ms   ok=\(d.ok) fail=\(d.fail)")
    let p1 = benchPacketize(firstStream, fecM: 1)
    let p2 = benchPacketize(firstStream, fecM: 2)
    print("  packetize m=1  p50=\(msStr(p1.p50)) p95=\(msStr(p1.p95)) max=\(msStr(p1.max)) ms")
    print("  packetize m=2  p50=\(msStr(p2.p50)) p95=\(msStr(p2.p95)) max=\(msStr(p2.max)) ms")
}

print("\n=== done ===")

#else
print("perfbench is macOS-only")
#endif
