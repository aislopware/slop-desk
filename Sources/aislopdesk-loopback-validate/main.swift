// aislopdesk-loopback-validate — headless closed-loop validation of the real video software loop.
//
// WHAT IT PROVES (no ScreenCaptureKit capture, no Metal render, no GUI, no admin/TCC):
//   synthetic CVPixelBuffer
//     -> REAL HW VideoEncoder.encodeLive (low-latency HEVC, VTCompressionSession)
//     -> VideoPacketizer.packetize (chosen FEC tier + isLTR + a monotonic hostSendTsMillis)
//     -> deterministic, index-based fragment LOSS injection (NO RNG, NO wall-clock)
//     -> FrameFragment.encode()/decode() wire round-trip on survivors
//     -> FrameReassembler.ingest (FEC single-hole recovery + per-frame tier split + isLTR latch)
//     -> REAL HW VideoDecoder.decode (VTDecompressionSession) -> decoded CVPixelBuffer count
//   PLUS the pure WF-1..WF-8 controllers driven on synthetic telemetry:
//     NetworkEstimate.fold / computeRTTMillis, LiveCongestionController.onReport,
//     AdaptiveFECPolicy.tier, OWDJitterEstimator + AdaptiveJitterController, LTRController.
//
// The HW HEVC encode + decode are MEASURED to run headlessly from a normal executable in a
// Background shell (they hang ONLY inside xctest; only capture + Metal need a GUI/TCC session).
// runLTRCapabilityProbe() runs FIRST as a liveness smoke. The harness is intentionally AppKit-free
// and fully synchronous (encode is drained by completeFrames(); decode uses flags:[] = synchronous),
// so there is NO dispatchMain / NSApplication.run / detached Task — it runs top-to-bottom and exit(0)s.
//
// USAGE:
//   aislopdesk-loopback-validate            # full run: 6 scenarios + FEC-tier sweep + controllers
//   aislopdesk-loopback-validate --smoke    # quick 10-frame clean scenario + controllers (liveness)
//   aislopdesk-loopback-validate --frames N # override per-scenario frame count (default 120)
//   AISLOPDESK_LV_FRAMES=N aislopdesk-loopback-validate

import Foundation

#if os(macOS)
import VideoToolbox
import CoreMedia
import CoreVideo
import AislopdeskVideoHost
import AislopdeskVideoProtocol
import AislopdeskVideoClient

// MARK: - Sinks / counters (Sendable boxes for the @Sendable encoder/decoder handlers)

/// Collects encoder output-handler emissions. The encoder OutputHandler is `@Sendable` and fires on
/// VideoToolbox's own queue; `completeFrames()` drains all pending callbacks before we read. NSLock
/// keeps it race-clean even though the harness is otherwise single-threaded.
final class FrameSink: @unchecked Sendable {
    struct Item { let avcc: Data; let keyframe: Bool; let ltr: Int64? }
    private let lock = NSLock()
    private var items: [Item] = []
    func append(avcc: Data, keyframe: Bool, ltr: Int64?) {
        lock.lock(); items.append(Item(avcc: avcc, keyframe: keyframe, ltr: ltr)); lock.unlock()
    }
    func drain() -> [Item] {
        lock.lock(); let out = items; items.removeAll(); lock.unlock(); return out
    }
}

/// A simple counter the decoder's `@Sendable` handler increments. Decode is synchronous (flags:[]),
/// so the handler runs on the calling thread before decode() returns — no real concurrency.
final class Counter: @unchecked Sendable { var value = 0 }

// MARK: - Per-scenario stats

struct ScenarioStats {
    var name: String
    var encoded = 0
    var fragmentsSent = 0
    var fragmentsDropped = 0
    var reassembled = 0
    var fecRecovered = 0
    var framesDropped = 0
    var decoded = 0
    var decodeFailures = 0
}

// MARK: - Deterministic loss model

enum LossModel {
    /// No loss.
    case none
    /// Drop fragment when its scenario-global index % n == 0 (index 0 never dropped). ~1/n loss.
    case everyN(Int)
    /// Drop the first `k` DATA fragments of EACH per-frame FEC group (parity is never dropped). With
    /// k==1 every group has exactly one recoverable hole → exercises FEC recovery on every group; on
    /// an OFF tier (group size 0 here) only data-fragment-0 is dropped and no parity exists → the
    /// frame is unrecoverable, exercising the .dropped -> forced-keyframe re-anchor path.
    case firstPerGroup(Int)
    /// Drop `len` CONSECUTIVE WIRE positions [start, start+len) within EACH frame's transmission
    /// list. This is the real-world UDP burst: adjacent datagrams lost together (#6 FragmentInterleaver
    /// is meant to survive exactly this). WITHOUT interleave those positions are one FEC group → ≥2
    /// holes → unrecoverable. WITH interleave (column-major) they spread one-per-group → all recoverable.
    /// Operates on the per-frame WIRE index (post-interleave send order), NOT the scenario-global index.
    case wireBurst(start: Int, len: Int)
}

/// Pure, deterministic drop decision. `tierGroupSize` is the resolved per-frame FEC group size
/// (0 when the tier is OFF / no parity). `frameLocalIndex` is the position of this fragment in its
/// frame's WIRE transmission list (after any interleave) — used by `.wireBurst` to model an
/// adjacent-datagram burst loss; `globalIndex` is the scenario-global wire position for `.everyN`.
func shouldDrop(frag: FrameFragment, globalIndex: Int, frameLocalIndex: Int, model: LossModel, tierGroupSize: Int) -> Bool {
    switch model {
    case .none:
        return false
    case .everyN(let n):
        return n > 0 && globalIndex != 0 && globalIndex % n == 0
    case .firstPerGroup(let k):
        if frag.header.flags.contains(.parity) { return false }
        let g = tierGroupSize <= 0 ? Int.max : tierGroupSize
        return Int(frag.header.fragIndex) % g < k
    case .wireBurst(let start, let len):
        return frameLocalIndex >= start && frameLocalIndex < start + len
    }
}

// MARK: - Synthetic frame source

let kWidth = 1280
let kHeight = 720
let kFPS = 60

func makePixelBuffer(width: Int, height: Int, fullRange: Bool) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let fmt = fullRange
        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, fmt,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    guard status == kCVReturnSuccess else { return nil }
    return pb
}

/// Fills `pb` with STRUCTURED, frame-varying content: a 16px checkerboard + a moving luma gradient +
/// a moving high-contrast block. Structured (so an HEVC keyframe is a healthy multi-fragment size,
/// exercising fragmentation + FEC group splitting) yet changes every frame (so deltas are non-trivial
/// — a flat buffer would collapse to ~1 fragment). Chroma stays near-neutral with a faint pattern.
func fillFrame(_ pb: CVPixelBuffer, _ i: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)

    let bx = (i &* 9) % max(1, w)
    let by = (i &* 5) % max(1, h)

    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let yptr = base.assumingMemoryBound(to: UInt8.self)
        let ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<h {
            let row = yptr + y * ystride
            let yband = (y >> 4) & 1
            for x in 0..<w {
                let cell = ((x >> 4) & 1) ^ yband
                let grad = (x &+ y &+ i &* 4) & 0x3F
                var lum: Int = cell == 0 ? (50 + grad) : (190 - grad)
                if abs(x - bx) < 40 && abs(y - by) < 40 { lum = 235 }
                row[x] = UInt8(lum & 0xFF)
            }
        }
    }

    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
        let cptr = base.assumingMemoryBound(to: UInt8.self)
        let cstride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let ch = h / 2
        for y in 0..<ch {
            let row = cptr + y * cstride
            var x = 0
            while x < w {
                row[x] = UInt8((128 + (((x >> 5) ^ (y >> 5) ^ i) & 7)) & 0xFF) // Cb-ish
                if x + 1 < w { row[x + 1] = UInt8((128 + ((x >> 4) & 7)) & 0xFF) } // Cr-ish
                x += 2
            }
        }
    }
}

// MARK: - Tier helpers

func tierDesc(_ tier: UInt8) -> String {
    switch AdaptiveFECPolicy.groupSize(forTier: tier, default: 5) {
    case nil: return "OFF"
    case .some(let g): return "g\(g)"
    }
}

// MARK: - The closed loop (one scenario)

func runScenario(name: String, frames: Int, tier: UInt8, loss: LossModel, fullRange: Bool = false, interleave: Bool = false) -> ScenarioStats {
    var stats = ScenarioStats(name: name)
    let sink = FrameSink()
    let decodedCounter = Counter()

    let enc: VideoEncoder
    do {
        enc = VideoEncoder(
            width: kWidth, height: kHeight, fps: kFPS, fullRange: fullRange, ltrEnabled: false,
            outputHandler: { avcc, kf, _, ltr in sink.append(avcc: avcc, keyframe: kf, ltr: ltr) })
        try enc.createLiveSession()
    } catch {
        print("  [\(name)] ENCODER CREATE FAILED: \(error)")
        return stats
    }

    var pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    let dec = VideoDecoder(decodedFrameHandler: { _ in decodedCounter.value += 1 })
    dec.outputFullRange = fullRange

    guard let pb = makePixelBuffer(width: kWidth, height: kHeight, fullRange: fullRange) else {
        print("  [\(name)] pixel-buffer create failed")
        return stats
    }

    let tierGroupSize = AdaptiveFECPolicy.groupSize(forTier: tier, default: 5) ?? 0
    var globalFrag = 0
    var hostTs: UInt32 = 1
    var recoveryPending = false

    for i in 0..<frames {
        fillFrame(pb, i)
        let force = (i == 0) || recoveryPending
        recoveryPending = false
        do {
            try enc.encodeLive(
                pixelBuffer: pb,
                presentationTime: CMTime(value: Int64(i), timescale: Int32(kFPS)),
                forceKeyframe: force)
        } catch {
            // A frame the encoder could not fit under the hard rate cap is dropped (no output) — count
            // nothing and continue; never crash the harness.
            continue
        }
        enc.completeFrames() // force the async VT output callback(s) to fire, then read the sink.

        for out in sink.drain() {
            stats.encoded += 1
            // Read peekNextFrameID BEFORE packetize (packetize increments it) — mirrors the host LTR map.
            _ = pk.peekNextFrameID
            let packetized = pk.packetize(
                frame: out.avcc, keyframe: out.keyframe,
                hostSendTsMillis: hostTs, fecTier: tier, isLTR: false)
            hostTs &+= 16 // ~60fps monotonic ms stamp (cosmetic here; controllers drive RTT separately)

            // Mirror the LIVE host: when AISLOPDESK_INTERLEAVE is on, transmission is reordered column-major
            // across FEC groups by the SAME group size the parity used. Reassembly is order-independent
            // (header-keyed), so this is a pure send-order permutation — exactly what #6 ships.
            let frags = interleave
                ? FragmentInterleaver.interleave(packetized, groupSize: tierGroupSize)
                : packetized

            for (frameLocalIndex, frag) in frags.enumerated() {
                stats.fragmentsSent += 1
                let drop = shouldDrop(frag: frag, globalIndex: globalFrag, frameLocalIndex: frameLocalIndex, model: loss, tierGroupSize: tierGroupSize)
                globalFrag += 1
                if drop { stats.fragmentsDropped += 1; continue }

                // Wire round-trip the survivor through the real fragment codec.
                let wire = frag.encode()
                guard let parsed = try? FrameFragment.decode(wire) else { continue }

                switch ra.ingest(parsed) {
                case .completed(let f):
                    stats.reassembled += 1
                    if f.recoveredViaFEC { stats.fecRecovered += 1 }
                    do {
                        try dec.decode(f)
                    } catch {
                        // A delta referencing a lost frame, or an FEC mis-recovery — count + re-anchor.
                        stats.decodeFailures += 1
                        recoveryPending = true
                    }
                case .dropped:
                    stats.framesDropped += 1
                    recoveryPending = true
                case .incomplete, .stale:
                    break
                }
                while ra.nextDroppedFrame() != nil {
                    stats.framesDropped += 1
                    recoveryPending = true
                }
            }
        }
    }

    enc.completeFrames()
    stats.decoded = decodedCounter.value

    print("  [done] \(name)")
    print("         enc=\(stats.encoded) fragSent=\(stats.fragmentsSent) fragDrop=\(stats.fragmentsDropped) "
        + "reasm=\(stats.reassembled) fecRecov=\(stats.fecRecovered) framesDrop=\(stats.framesDropped) "
        + "decodeOK=\(stats.decoded) decodeFail=\(stats.decodeFailures)")
    return stats
}

// MARK: - LTR HW scenario (record -> ack -> ForceLTRRefresh -> decode)

func runLTRHWScenario(frames: Int) -> ScenarioStats {
    var stats = ScenarioStats(name: "6. LTR HW (record/ack/refresh)")
    let sink = FrameSink()
    let decodedCounter = Counter()

    let enc: VideoEncoder
    do {
        enc = VideoEncoder(
            width: kWidth, height: kHeight, fps: kFPS, ltrEnabled: true,
            outputHandler: { avcc, kf, _, ltr in sink.append(avcc: avcc, keyframe: kf, ltr: ltr) })
        try enc.createLiveSession()
    } catch {
        print("  LTR encoder create FAILED: \(error)")
        return stats
    }

    var pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    let dec = VideoDecoder(decodedFrameHandler: { _ in decodedCounter.value += 1 })
    var ltrCtl = LTRController()
    guard let pb = makePixelBuffer(width: kWidth, height: kHeight, fullRange: false) else { return stats }

    var hostTs: UInt32 = 1
    var ltrFramesSeen = 0
    var lastAckedToken: Int64? = nil

    func processOutputs() {
        for out in sink.drain() {
            stats.encoded += 1
            let frameID = pk.peekNextFrameID
            let isLTRFrame = (out.ltr != nil)
            if isLTRFrame { ltrFramesSeen += 1; ltrCtl.recordLTRFrame(frameID: frameID, token: out.ltr!) }
            let frags = pk.packetize(
                frame: out.avcc, keyframe: out.keyframe,
                hostSendTsMillis: hostTs, fecTier: 0, isLTR: isLTRFrame)
            hostTs &+= 16
            for frag in frags {
                stats.fragmentsSent += 1
                let wire = frag.encode()
                guard let parsed = try? FrameFragment.decode(wire) else { continue }
                if case .completed(let f) = ra.ingest(parsed) {
                    stats.reassembled += 1
                    if f.recoveredViaFEC { stats.fecRecovered += 1 }
                    do {
                        try dec.decode(f)
                        if f.isLTR, let tok = ltrCtl.ackFrame(frameID: f.frameID) {
                            lastAckedToken = tok
                            enc.stageAcknowledgedToken(tok) // next encode drains it as AcknowledgedLTRTokens
                        }
                    } catch {
                        stats.decodeFailures += 1
                    }
                }
            }
        }
    }

    // Seed: a forced keyframe SEEDS an LTR reference (carries RequireLTRAcknowledgementToken on HW
    // that supports it). recoveryDecision must be .idr until a token is acked.
    print("  recoveryDecision(.ltrRefresh) BEFORE any ack: \(ltrCtl.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true))")
    fillFrame(pb, 0)
    try? enc.encodeLive(pixelBuffer: pb, presentationTime: CMTime(value: 0, timescale: Int32(kFPS)), forceKeyframe: true)
    enc.completeFrames()
    processOutputs() // records + (on successful decode) acks the keyframe's LTR token, stages it

    if ltrFramesSeen > 0 {
        print("  LTR token observed on keyframe: YES (token=\(lastAckedToken.map(String.init) ?? "nil"))")
    } else {
        print("  LTR token observed on keyframe: no — this HW encoder did not attach "
            + "RequireLTRAcknowledgementToken (VT will fall back to IDR on a refresh; still decodable)")
    }
    print("  hasAckedToken after keyframe decode+ack: \(ltrCtl.hasAckedToken)")
    print("  recoveryDecision(.ltrRefresh) AFTER ack: \(ltrCtl.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true))")

    // A few normal live deltas to build stream depth.
    let deltas = max(2, frames - 2)
    for i in 1..<deltas {
        fillFrame(pb, i)
        try? enc.encodeLive(pixelBuffer: pb, presentationTime: CMTime(value: Int64(i), timescale: Int32(kFPS)), forceKeyframe: false)
        enc.completeFrames()
        processOutputs()
    }

    // The LTR-refresh P-frame: references the acked LTR if one exists (cheap recovery), else VT emits
    // an IDR. Either way it must produce a decodable frame.
    let beforeDecoded = decodedCounter.value
    fillFrame(pb, frames - 1)
    try? enc.encodeLiveLTRRefresh(pixelBuffer: pb, presentationTime: CMTime(value: Int64(frames - 1), timescale: Int32(kFPS)))
    enc.completeFrames()
    processOutputs()
    print("  encodeLiveLTRRefresh produced a decodable frame: \(decodedCounter.value > beforeDecoded ? "YES" : "NO")")

    enc.completeFrames()
    stats.decoded = decodedCounter.value
    print("  [done] \(stats.name)")
    print("         enc=\(stats.encoded) fragSent=\(stats.fragmentsSent) reasm=\(stats.reassembled) "
        + "decodeOK=\(stats.decoded) decodeFail=\(stats.decodeFailures) ltrFrames=\(ltrFramesSeen)")
    return stats
}

// MARK: - ACK-REFERENCED ENCODING probe (Parsec model: every delta references only ACKED LTRs)

/// One arm of the ack-ref experiment. `ackRef=true` encodes EVERY delta with `ForceLTRRefresh`
/// (so VT references only acknowledged LTR frames — the Parsec "ack-referenced" model) and feeds
/// client acks back with a simulated `ackLagFrames` round-trip. `dropEveryN>0` drops one WHOLE frame
/// per N on the wire (the client never sees it, never acks it). `recoverOnFail` mirrors production
/// (decode failure → forced IDR re-anchor); the ack-ref loss arm runs with it OFF to prove the chain
/// needs no recovery at all.
/// LOW-MOTION variant of ``fillFrame``: the checkerboard+gradient background is FROZEN (no `i` term)
/// and only the small high-contrast block moves. Mirrors real desktop content (mostly static) — the
/// discriminator between "ack-ref frames are P (tiny deltas on static content)" and "ack-ref frames
/// are secretly INTRA (size stays large regardless of motion)".
func fillFrameLowMotion(_ pb: CVPixelBuffer, _ i: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let bx = (i &* 9) % max(1, w)
    let by = (i &* 5) % max(1, h)
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let yptr = base.assumingMemoryBound(to: UInt8.self)
        let ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<h {
            let row = yptr + y * ystride
            let yband = (y >> 4) & 1
            for x in 0..<w {
                let cell = ((x >> 4) & 1) ^ yband
                let grad = (x &+ y) & 0x3F
                var lum: Int = cell == 0 ? (50 + grad) : (190 - grad)
                if abs(x - bx) < 40 && abs(y - by) < 40 { lum = 235 }
                row[x] = UInt8(lum & 0xFF)
            }
        }
    }
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
        let cptr = base.assumingMemoryBound(to: UInt8.self)
        let cstride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let ch = h / 2
        for y in 0..<ch {
            let row = cptr + y * cstride
            var x = 0
            while x < w {
                row[x] = 128
                if x + 1 < w { row[x + 1] = 128 }
                x += 2
            }
        }
    }
}

func expectedLumaLowMotion(x: Int, y: Int, frame i: Int, w: Int, h: Int) -> Int {
    let bx = (i &* 9) % max(1, w)
    let by = (i &* 5) % max(1, h)
    let cell = ((x >> 4) & 1) ^ ((y >> 4) & 1)
    let grad = (x &+ y) & 0x3F
    var lum: Int = cell == 0 ? (50 + grad) : (190 - grad)
    if abs(x - bx) < 40 && abs(y - by) < 40 { lum = 235 }
    return lum & 0xFF
}

/// Analytic mirror of ``fillFrame``'s LUMA formula — lets the decode side verify picture CONTENT
/// against the deterministic source without storing reference frames. Any reference-chain corruption
/// (a frame predicted from data the decoder never got) shows up as a large mean-abs-diff (MAD),
/// where a healthy lossy decode sits at a small constant.
func expectedLuma(x: Int, y: Int, frame i: Int, w: Int, h: Int) -> Int {
    let bx = (i &* 9) % max(1, w)
    let by = (i &* 5) % max(1, h)
    let cell = ((x >> 4) & 1) ^ ((y >> 4) & 1)
    let grad = (x &+ y &+ i &* 4) & 0x3F
    var lum: Int = cell == 0 ? (50 + grad) : (190 - grad)
    if abs(x - bx) < 40 && abs(y - by) < 40 { lum = 235 }
    return lum & 0xFF
}

/// Decode-side picture-content verification box. The harness decode is SYNCHRONOUS (flags:[]), so the
/// handler runs inside `dec.decode(...)` on the calling thread — `sourceIndex`/`dropRecent` set just
/// before the call are race-free (NSLock only for discipline).
final class MADBox: @unchecked Sendable {
    private let lock = NSLock()
    var sourceIndex = 0
    var dropRecent = false           // a whole-frame wire loss happened within the last 3 frames
    var lowMotion = false            // verify against the low-motion content formula instead
    private(set) var sumMAD = 0.0
    private(set) var count = 0
    private(set) var maxMAD = 0.0
    private(set) var postDropMaxMAD = 0.0
    var avgMAD: Double { count > 0 ? sumMAD / Double(count) : 0 }
    func measure(_ img: CVImageBuffer) {
        let pb = img as CVPixelBuffer
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        lock.lock(); let i = sourceIndex; let recent = dropRecent; let lowM = lowMotion; lock.unlock()
        var sum = 0, n = 0
        var y = 2
        while y < h {
            let row = ptr + y * stride
            var x = 3
            while x < w {
                let want = lowM
                    ? expectedLumaLowMotion(x: x, y: y, frame: i, w: w, h: h)
                    : expectedLuma(x: x, y: y, frame: i, w: w, h: h)
                sum += abs(Int(row[x]) - want)
                n += 1
                x += 7
            }
            y += 5
        }
        guard n > 0 else { return }
        let mad = Double(sum) / Double(n)
        lock.lock()
        sumMAD += mad; count += 1
        if mad > maxMAD { maxMAD = mad }
        if recent && mad > postDropMaxMAD { postDropMaxMAD = mad }
        lock.unlock()
    }
}

struct AckRefArmResult {
    var name = ""
    var encoded = 0
    var keyframes = 0
    var ltrTokenFrames = 0
    var deltaBytesTotal = 0
    var deltaCount = 0
    var kfBytesTotal = 0
    var decodeOK = 0
    var decodeFail = 0
    var recoveryIDRs = 0
    var framesDroppedOnWire = 0
    var avgMAD = 0.0
    var maxMAD = 0.0
    var postDropMaxMAD = 0.0
    var refreshBytesTotal = 0
    var refreshCount = 0
    var avgRefreshBytes: Int { refreshCount > 0 ? refreshBytesTotal / refreshCount : 0 }
    var avgDeltaBytes: Int { deltaCount > 0 ? deltaBytesTotal / deltaCount : 0 }
    var avgKFBytes: Int { keyframes > 0 ? kfBytesTotal / keyframes : 0 }
    /// Size-blind average across ALL frames — the honest cross-arm comparator when the NotSync
    /// attachment mislabels LTR-refresh P-frames as "keyframes".
    var avgFrameBytes: Int { encoded > 0 ? (deltaBytesTotal + kfBytesTotal) / encoded : 0 }
}

/// `refreshEvery > 0` switches the arm from PER-FRAME refresh to SPARSE: normal P-chain deltas with
/// one `encodeLiveLTRRefresh` every `refreshEvery` frames (the WF-8 recovery shape) — sizes of those
/// refresh frames land in `refreshBytesTotal` (P-sized ⇒ genuine LTR reference; intra-sized ⇒ VT's
/// "LTR refresh" is just a coarse intra and the LTR API never yields real long-term P references).
func runAckRefArm(name: String, frames: Int, ackRef: Bool, ackLagFrames: Int, dropEveryN: Int, recoverOnFail: Bool, neverAck: Bool = false, verbose: Bool = false, lowMotion: Bool = false, refreshEvery: Int = 0, dropFrames: Set<Int> = []) -> AckRefArmResult {
    var r = AckRefArmResult(); r.name = name
    let sink = FrameSink()
    let decodedCounter = Counter()
    let enc: VideoEncoder
    do {
        enc = VideoEncoder(
            width: kWidth, height: kHeight, fps: kFPS, ltrEnabled: ackRef,
            outputHandler: { avcc, kf, _, ltr in sink.append(avcc: avcc, keyframe: kf, ltr: ltr) })
        try enc.createLiveSession()
    } catch {
        print("  [\(name)] ENCODER CREATE FAILED: \(error)")
        return r
    }

    var pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    let mad = MADBox()
    mad.lowMotion = lowMotion
    let dec = VideoDecoder(decodedFrameHandler: { img in decodedCounter.value += 1; mad.measure(img) })
    var ltrCtl = LTRController()
    guard let pb = makePixelBuffer(width: kWidth, height: kHeight, fullRange: false) else { return r }

    var hostTs: UInt32 = 1
    /// Simulated ack RTT: a decoded LTR frame's ack arrives back at the host `ackLagFrames` later.
    var pendingAcks: [(dueAtFrame: Int, frameID: UInt32)] = []
    var recoveryPending = false
    var lastDropIndex = -1_000_000 // NOT Int.min — `i - lastDropIndex` would overflow-trap

    for i in 0..<frames {
        // Deliver acks whose simulated round-trip elapsed (BEFORE this encode — an arriving datagram).
        if ackRef && !neverAck {
            for a in pendingAcks where a.dueAtFrame <= i {
                if let tok = ltrCtl.ackFrame(frameID: a.frameID) { enc.stageAcknowledgedToken(tok) }
            }
            pendingAcks.removeAll { $0.dueAtFrame <= i }
        }

        if lowMotion { fillFrameLowMotion(pb, i) } else { fillFrame(pb, i) }
        let force = (i == 0) || recoveryPending
        recoveryPending = false
        if force && i > 0 { r.recoveryIDRs += 1 }
        let isRefreshFrame = ackRef && !force
            && (refreshEvery == 0 || (i > 0 && i % refreshEvery == 0))
        do {
            if isRefreshFrame {
                // Per-frame (refreshEvery==0) or sparse (every N) ForceLTRRefresh.
                try enc.encodeLiveLTRRefresh(pixelBuffer: pb, presentationTime: CMTime(value: Int64(i), timescale: Int32(kFPS)))
            } else {
                try enc.encodeLive(pixelBuffer: pb, presentationTime: CMTime(value: Int64(i), timescale: Int32(kFPS)), forceKeyframe: force)
            }
        } catch { continue }
        enc.completeFrames()

        // Whole-frame wire loss: a mid-cycle frame so the seed keyframe is never the one dropped.
        // Negative dropEveryN = BURST mode: drop |n| CONSECUTIVE frames once per 24 (the worst case
        // for any internal "reference an older LTR" policy — both adjacent LTR slots die together).
        let dropThisFrame: Bool
        if !dropFrames.isEmpty {
            dropThisFrame = dropFrames.contains(i)
        } else if dropEveryN < 0 {
            let burst = -dropEveryN
            dropThisFrame = i > 0 && (i % 24) >= 12 && (i % 24) < 12 + burst
        } else {
            dropThisFrame = dropEveryN > 0 && i > 0 && (i % dropEveryN == dropEveryN / 2)
        }
        if dropThisFrame { r.framesDroppedOnWire += 1; lastDropIndex = i }

        for out in sink.drain() {
            r.encoded += 1
            if out.keyframe { r.keyframes += 1; r.kfBytesTotal += out.avcc.count } else { r.deltaBytesTotal += out.avcc.count; r.deltaCount += 1 }
            if isRefreshFrame && refreshEvery > 0 {
                r.refreshBytesTotal += out.avcc.count; r.refreshCount += 1
                if verbose { print("    refresh@\(i) kf=\(out.keyframe) ltrTok=\(out.ltr.map(String.init) ?? "-") bytes=\(out.avcc.count)") }
            }
            if verbose && r.encoded <= 12 {
                print("    f#\(r.encoded - 1) kf=\(out.keyframe) ltrTok=\(out.ltr.map(String.init) ?? "-") bytes=\(out.avcc.count)")
            }
            let frameID = pk.peekNextFrameID
            let isLTRFrame = (out.ltr != nil)
            if isLTRFrame { r.ltrTokenFrames += 1; ltrCtl.recordLTRFrame(frameID: frameID, token: out.ltr!) }
            let frags = pk.packetize(
                frame: out.avcc, keyframe: out.keyframe,
                hostSendTsMillis: hostTs, fecTier: 0, isLTR: isLTRFrame)
            hostTs &+= 16
            if dropThisFrame { continue } // lost on the wire: never reassembled, never decoded, never acked
            for frag in frags {
                let wire = frag.encode()
                guard let parsed = try? FrameFragment.decode(wire) else { continue }
                if case .completed(let f) = ra.ingest(parsed) {
                    do {
                        mad.sourceIndex = i
                        mad.dropRecent = (i - lastDropIndex) <= 3
                        try dec.decode(f)
                        r.decodeOK += 1
                        if ackRef, !neverAck, f.isLTR {
                            pendingAcks.append((dueAtFrame: i + max(1, ackLagFrames), frameID: f.frameID))
                        }
                    } catch {
                        r.decodeFail += 1
                        if recoverOnFail { recoveryPending = true }
                    }
                }
            }
        }
        while ra.nextDroppedFrame() != nil {} // whole-frame loss is intentional here — drain bookkeeping
    }
    enc.completeFrames()
    r.avgMAD = mad.avgMAD; r.maxMAD = mad.maxMAD; r.postDropMaxMAD = mad.postDropMaxMAD
    print("  [\(name)] enc=\(r.encoded) kf=\(r.keyframes) ltrTok=\(r.ltrTokenFrames) "
        + "avgALL=\(r.avgFrameBytes)B framesLost=\(r.framesDroppedOnWire) "
        + "decodeOK=\(r.decodeOK) decodeFail=\(r.decodeFail) recoveryIDRs=\(r.recoveryIDRs) "
        + String(format: "MAD avg=%.1f max=%.1f postDrop=%.1f", r.avgMAD, r.maxMAD, r.postDropMaxMAD))
    return r
}

/// The 5-arm experiment + verdicts. Answers the THREE unknowns of Parsec-style ack-referenced
/// encoding on THIS HW before any production wiring:
///   (1) does the low-latency HEVC encoder accept per-frame ForceLTRRefresh and emit a token EVERY
///       frame (not just occasionally)?
///   (2) what is the byte overhead of referencing an (RTT-old) acked LTR instead of prev-frame —
///       at a 2-frame lag (~33ms RTT) and a 6-frame lag (~100ms RTT)?
///   (3) does the decode chain actually SURVIVE whole-frame loss with NO recovery round-trip
///       (decodeFail==0, recoveryIDRs==0), where the baseline P-chain breaks?
func runAckRefProbe(frames: Int) {
    print("=== ACK-REF probe :: per-frame ForceLTRRefresh (Parsec ack-referenced encoding) on REAL HW ===")
    print("    \(frames) frames/arm, whole-frame wire loss 1/13 (~7.7%), ack lag in FRAMES (60fps ⇒ 2≈33ms RTT, 6≈100ms)\n")

    let base     = runAckRefArm(name: "A base P-chain    clean          ", frames: frames, ackRef: false, ackLagFrames: 0, dropEveryN: 0,  recoverOnFail: true)
    let baseLoss = runAckRefArm(name: "B base P-chain    drop1/13 +rec  ", frames: frames, ackRef: false, ackLagFrames: 0, dropEveryN: 13, recoverOnFail: true)
    let ackClean = runAckRefArm(name: "C ack-ref lag2    clean          ", frames: frames, ackRef: true,  ackLagFrames: 2, dropEveryN: 0,  recoverOnFail: true, verbose: true)
    let ackLoss  = runAckRefArm(name: "D ack-ref lag2    drop1/13 NOrec ", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 13, recoverOnFail: false)
    let ackLag6  = runAckRefArm(name: "E ack-ref lag6    clean          ", frames: frames, ackRef: true,  ackLagFrames: 6, dropEveryN: 0,  recoverOnFail: true)
    // ADVERSARIAL: drop only TOKEN (LTR) frames — i%16==8 is always even = the observed token cadence.
    // If VT references the previous LTR UNCONDITIONALLY (ignoring acks), losing an LTR frame must
    // corrupt its dependents → postDrop MAD spikes (or decode fails). If VT honours acks, the next
    // refresh references an OLDER acked LTR and the picture stays clean.
    let ackTokLoss = runAckRefArm(name: "F ack-ref lag2    dropTOKEN NOrec", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 16, recoverOnFail: false)
    // NO acks ever: per VT's contract every ForceLTRRefresh without an acked LTR should fall back
    // to IDR (or reference only its internal always-safe anchor). Distinguishes ack-driven from
    // ack-ignored behaviour when byte sizes are compared against C/E.
    let ackNever = runAckRefArm(name: "G ack-ref NO-acks drop1/13 NOrec ", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 13, recoverOnFail: false, neverAck: true)
    // BURST: 4 consecutive whole frames die every 24 (≥2 adjacent token/LTR frames lost together) —
    // the worst case for an internal older-LTR reference policy. If even this stays pixel-clean the
    // healing envelope covers the real path's measured burst shape.
    let ackBurst = runAckRefArm(name: "H ack-ref lag2    BURST4/24 NOrec", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: -4, recoverOnFail: false)
    // Find the healing HORIZON: 8 consecutive lost frames (133ms outage). If this breaks, the client's
    // existing loss-recovery (refresh/IDR request) remains the backstop for outages past the horizon.
    let ackBurst8 = runAckRefArm(name: "I ack-ref lag2    BURST8/24 NOrec", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: -8, recoverOnFail: false)
    // THE INTRA-DETECTOR: low-motion content (frozen background, only the block moves) — real desktop
    // shape. P deltas collapse to a few KB; a secretly-INTRA stream stays large. This decides whether
    // per-frame ForceLTRRefresh is shippable at all (all-intra would balloon idle bitrate ~10×).
    let baseLow = runAckRefArm(name: "J base P-chain    LOW-MOTION clean", frames: frames, ackRef: false, ackLagFrames: 0, dropEveryN: 0, recoverOnFail: true, lowMotion: true)
    let ackLow  = runAckRefArm(name: "K ack-ref lag2    LOW-MOTION clean", frames: frames, ackRef: true,  ackLagFrames: 2, dropEveryN: 0, recoverOnFail: true, lowMotion: true)
    // SPARSE refresh (the WF-8 recovery shape): normal P-chain + ForceLTRRefresh every 30 frames.
    // Refresh frame P-sized (~few KB on low-motion) ⇒ VT emits a GENUINE P against the acked LTR;
    // intra-sized (~25KB) ⇒ even sparse "LTR refresh" is a coarse intra (= compact-IDR equivalent).
    let sparse = runAckRefArm(name: "L sparse-refresh  LOW-MOTION clean", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 0, recoverOnFail: true, verbose: true, lowMotion: true, refreshEvery: 30)
    // WHICH LTR does the sparse refresh reference? Burst-kill frames 25–29 (their tokens are never
    // acked), refresh fires at 30. ACKED-LTR semantics (Parsec) ⇒ the refresh references ≤24 (the
    // newest acked LTR), the client holds it, decode + MAD stay clean WITHOUT any recovery.
    // Newest-INTERNAL-LTR semantics ⇒ the refresh references a dead frame → decode fails/corrupts.
    let anchored = runAckRefArm(name: "M sparse+burst25-29 acked  NOrec  ", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 0, recoverOnFail: false, lowMotion: true, refreshEvery: 30, dropFrames: [25, 26, 27, 28, 29])
    // Same but NO acks ever: VT's documented contract says ForceLTRRefresh without an acknowledged
    // LTR falls back to an IDR — the safety net under the host's ACKED-ONLY gate.
    let anchoredNoAck = runAckRefArm(name: "N sparse+burst25-29 NOack  NOrec  ", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 0, recoverOnFail: false, neverAck: true, lowMotion: true, refreshEvery: 30, dropFrames: [25, 26, 27, 28, 29])
    // Refresh COST on real motion: full-motion content, refresh every 6 frames (100ms self-heal
    // cadence) — how much bigger is a refresh (referencing an ~RTT-old acked LTR) than a 1-back delta?
    let sparseCost = runAckRefArm(name: "O sparse6 MOTION  clean (cost)    ", frames: frames, ackRef: true, ackLagFrames: 2, dropEveryN: 0, recoverOnFail: true, refreshEvery: 6)

    func pct(_ a: Int, _ b: Int) -> String {
        guard b > 0 else { return "n/a" }
        return String(format: "%+.1f%%", (Double(a) / Double(b) - 1.0) * 100.0)
    }
    let tokenCoverage = ackClean.encoded > 0 ? Double(ackClean.ltrTokenFrames) / Double(ackClean.encoded) : 0
    // The CLEAN arm's own max MAD = the lossy-codec noise floor; a post-drop MAD within ~1.5× of it
    // means the picture after a loss is as healthy as a picture with no loss at all.
    let cleanCeiling = max(3.0, ackClean.maxMAD * 1.5)
    let dSurvives = ackLoss.decodeFail == 0 && ackLoss.recoveryIDRs == 0 && ackLoss.postDropMaxMAD <= cleanCeiling
    let fSurvives = ackTokLoss.decodeFail == 0 && ackTokLoss.recoveryIDRs == 0 && ackTokLoss.postDropMaxMAD <= cleanCeiling
    let baselineBreaks = baseLoss.decodeFail > 0 || baseLoss.recoveryIDRs > 0

    print("")
    print("  token cadence (LTR frames/encoded)      : \(ackClean.ltrTokenFrames)/\(ackClean.encoded) = \(String(format: "%.0f%%", tokenCoverage * 100))")
    print("  byte overhead vs baseline  lag2 / lag6  : \(pct(ackClean.avgFrameBytes, base.avgFrameBytes)) / \(pct(ackLag6.avgFrameBytes, base.avgFrameBytes)) (base \(base.avgFrameBytes)B)")
    print("  acks ignored by encoder?                : lag2=\(ackClean.avgFrameBytes)B lag6=\(ackLag6.avgFrameBytes)B noAck=\(ackNever.avgFrameBytes)B "
        + "(identical ⇒ AcknowledgedLTRTokens has no effect)")
    print("  VERDICT survive 7.7% mixed frame loss, ZERO recovery : \(dSurvives ? "✅" : "❌") "
        + String(format: "(decodeFail=%d recIDR=%d postDropMAD=%.1f vs clean %.1f)", ackLoss.decodeFail, ackLoss.recoveryIDRs, ackLoss.postDropMaxMAD, ackClean.maxMAD))
    print("  VERDICT survive TOKEN-frame loss, ZERO recovery      : \(fSurvives ? "✅" : "❌") "
        + String(format: "(decodeFail=%d recIDR=%d postDropMAD=%.1f)", ackTokLoss.decodeFail, ackTokLoss.recoveryIDRs, ackTokLoss.postDropMaxMAD))
    let hSurvives = ackBurst.decodeFail == 0 && ackBurst.recoveryIDRs == 0 && ackBurst.postDropMaxMAD <= cleanCeiling
    print("  VERDICT survive BURST-4 frame loss, ZERO recovery    : \(hSurvives ? "✅" : "❌") "
        + String(format: "(decodeFail=%d recIDR=%d postDropMAD=%.1f)", ackBurst.decodeFail, ackBurst.recoveryIDRs, ackBurst.postDropMaxMAD))
    let iSurvives = ackBurst8.decodeFail == 0 && ackBurst8.recoveryIDRs == 0 && ackBurst8.postDropMaxMAD <= cleanCeiling
    print("  horizon  survive BURST-8 frame loss, ZERO recovery   : \(iSurvives ? "✅" : "❌ (past horizon — client recovery backstop applies)") "
        + String(format: "(decodeFail=%d postDropMAD=%.1f)", ackBurst8.decodeFail, ackBurst8.postDropMaxMAD))
    print("  VERDICT no-acks arm under loss (VT contract check)   : "
        + String(format: "decodeFail=%d postDropMAD=%.1f kf=%d", ackNever.decodeFail, ackNever.postDropMaxMAD, ackNever.keyframes))
    print("  baseline P-chain breaks under same loss (contrast)   : \(baselineBreaks ? "✅ breaks as expected" : "⚠️ did not break") "
        + String(format: "(decodeFail=%d recIDR=%d postDropMAD=%.1f)", baseLoss.decodeFail, baseLoss.recoveryIDRs, baseLoss.postDropMaxMAD))
    let intraRatio = baseLow.avgFrameBytes > 0 ? Double(ackLow.avgFrameBytes) / Double(baseLow.avgFrameBytes) : 0
    let isSecretlyIntra = intraRatio > 3.0
    print("  INTRA-DETECTOR low-motion bytes base→ackRef          : \(baseLow.avgFrameBytes)B → \(ackLow.avgFrameBytes)B "
        + String(format: "(%.1f×) ", intraRatio)
        + (isSecretlyIntra ? "❌ ack-ref frames are SECRETLY INTRA — per-frame refresh NOT shippable" : "✅ genuine P-frames — shippable"))
    let sparseRefreshIsP = sparse.avgRefreshBytes > 0 && sparse.avgRefreshBytes < baseLow.avgFrameBytes * 8
    print("  SPARSE refresh frame size (every 30, low-motion)     : \(sparse.avgRefreshBytes)B vs P-delta \(baseLow.avgFrameBytes)B vs intra ~\(ackLow.avgFrameBytes)B → "
        + (sparseRefreshIsP ? "✅ GENUINE LTR-P (WF-8 recovery is a real P-frame)" : "❌ intra-sized (VT LTR refresh = coarse intra, no real long-term P reference)"))
    // M: only the refresh@30 + followers matter. Post-burst MAD clean + no decode failures AFTER
    // frame 30 ⇒ acked-LTR anchored. (Frames 25–29 were never delivered; deltas before 30 that
    // referenced a dead frame would throw — count via decodeFail timing instead of total.)
    let mHealed = anchored.postDropMaxMAD <= cleanCeiling && anchored.postDropMaxMAD > 0
    print("  VERDICT refresh anchors to ACKED LTR (burst-kill 25-29): \(mHealed ? "✅ healed at refresh@30 with zero recovery" : "❌ refresh referenced a dead frame") "
        + String(format: "(decodeFail=%d postDropMAD=%.1f kf=%d)", anchored.decodeFail, anchored.postDropMaxMAD, anchored.keyframes))
    print("  VERDICT no-ack refresh falls back to IDR (VT contract) : "
        + String(format: "kf=%d decodeFail=%d postDropMAD=%.1f refreshAvg=%dB", anchoredNoAck.keyframes, anchoredNoAck.decodeFail, anchoredNoAck.postDropMaxMAD, anchoredNoAck.avgRefreshBytes))
    let costRatio = base.avgFrameBytes > 0 ? Double(sparseCost.avgRefreshBytes) / Double(base.avgFrameBytes) : 0
    print("  refresh COST on motion (every 6, vs 1-back delta)      : \(sparseCost.avgRefreshBytes)B vs \(base.avgFrameBytes)B "
        + String(format: "(%.2f× per refresh ⇒ +%.1f%% stream at K=6)", costRatio, max(0, costRatio - 1) / 6 * 100))
}

// MARK: - CLOSED-LOOP adaptation (full reflex through REAL components, in-process lossy transport)

/// Drives the COMPLETE closed-loop adaptation reflex end-to-end with the real product components —
/// the gap a 0%-loss loopback (headless harness scenarios 1-9 + GUI loopback) cannot exercise:
///
///   REAL HW encode (at the live bitrate) → VideoPacketizer.packetize(currentTier) → in-code per-frag
///   LOSS → FrameFragment wire round-trip → REAL FrameReassembler (+FEC, reads tier per-frag) → client
///   windowed counters + OWDJitterEstimator → NetworkStatsReport → REAL RecoveryMessage wire both ways
///   → host NetworkEstimate.computeRTTMillis + .fold → AdaptiveFECPolicy.tier (next packetize) +
///   LiveCongestionController.onReport → VideoEncoder.setLiveBitrate (REAL VTSessionSetProperty) ;
///   client AdaptiveJitterController.noteFrame(jitterSeconds:) → playout depth.
///
/// This mirrors EXACTLY the orchestration in AislopdeskVideoClientSession.sendNetworkStatsIfStreaming /
/// ingestVideo and AislopdeskVideoHostSession.handleRecovery(.networkStats) (read 2026-06-09). Loss/jitter
/// are injected in code, but every estimate, wire message, controller tick and the encoder bitrate
/// mutation are the REAL ones. Three phases: CLEAN → ADVERSE (loss + arrival jitter) → CLEAN, so each
/// controller must move AWAY from baseline under stress and BACK afterwards. Deterministic (no RNG, a
/// virtual 16 ms/frame clock — never wall-clock), so it is repeatable. `enableFEC=false` pins tier 0
/// (the adaptive-FEC A/B control: same physical loss, no redundancy escalation ⇒ more unrecovered).
struct ClosedLoopResult {
    var phaseAvgBitrateMbps: [Double] = []
    var phasePeakTier: [UInt8] = []
    var phasePeakDepth: [Int] = []
    var phaseUnrecovered: [Int] = []
    var phaseAvgEncBytes: [Int] = []
    var adverseUnrecSecondHalf = 0     // steady-state (after the FEC climb settles) — the fair A/B window
    var bitrateFellInAdverse = false
    var bitrateRecoveredAfter = false
    /// Bitrate at the END of the recovery phase. The recovery VERDICT keys on this vs the adverse
    /// TROUGH, not the adverse phase average: by design the climb starts only after the RTT-EWMA
    /// decays (~0.7s) + the hold-down (~1s), and DELAY-TARGETING (2026-06-11) deliberately climbs
    /// CAUTIOUSLY above the remembered knee — "recovered" means the climb is underway (end above the
    /// trough), not "back at the ceiling within a 1.5s window" (that fast reclimb WAS the pumping).
    var endBitrateMbps = 0.0
    /// Lowest actuated bitrate during the adverse phase (the trough the recovery verdict compares to).
    var adverseTroughMbps = Double.infinity
}

/// `fixedTier != nil` pins the FEC tier (non-adaptive baseline); `nil` lets AdaptiveFECPolicy drive it.
/// `congestRTTInAdverse`: when true the adverse phase ALSO inflates the one-way delay (queue
/// build-up → measured RTT ~90ms vs ~10ms baseline) so the loss is CORROBORATED — real congestion.
/// When false the adverse phase is WEATHER loss (loss at flat RTT, the 2026-06-10 measured path
/// shape) and the LOSS-TOLERANCE #4 controller must HOLD the bitrate.
func runClosedLoopAdaptation(framesPerPhase: Int, enableABR: Bool, enableFEC: Bool, enableJitter: Bool, fixedTier: UInt8? = nil, congestRTTInAdverse: Bool = true, verbose: Bool) -> ClosedLoopResult {
    var result = ClosedLoopResult()

    // ── Host-side real components ──
    let ceiling = LiveBitratePolicy.targetBitrate(pixelWidth: kWidth, pixelHeight: kHeight, fps: kFPS, floor: 2_000_000)
    var pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    var est = NetworkEstimate()
    var cc = LiveCongestionController(ceiling: ceiling)
    var currentTier: UInt8 = fixedTier ?? AdaptiveFECPolicy.defaultTier   // 0 = g5
    var lastActuated = ceiling
    var lastTarget = ceiling

    let sink = FrameSink()
    let decoded = Counter()
    let enc: VideoEncoder
    do {
        enc = VideoEncoder(width: kWidth, height: kHeight, fps: kFPS, ltrEnabled: false,
                           outputHandler: { avcc, kf, _, ltr in sink.append(avcc: avcc, keyframe: kf, ltr: ltr) })
        try enc.createLiveSession()
    } catch { print("  closed-loop encoder create FAILED: \(error)"); return result }
    _ = enc.setLiveBitrate(ceiling)
    let dec = VideoDecoder(decodedFrameHandler: { _ in decoded.value += 1 })
    guard let pb = makePixelBuffer(width: kWidth, height: kHeight, fullRange: false) else { return result }

    // ── Client-side real components ──
    var owd = OWDJitterEstimator()
    var jc = AdaptiveJitterController(minDepth: 1, maxDepth: 8, fps: Double(kFPS), initialDepth: 1)
    var winFrames: UInt32 = 0, winFec: UInt32 = 0, winUnrec: UInt32 = 0
    var latestHostSendTs: UInt32 = 0
    var latestObservedAtMs = 0.0

    // ── Virtual clock + per-phase loss/jitter schedule ──
    let reportEvery = 3                     // ~50 ms at 60 fps
    // One-way delay: ~10ms RTT baseline; a CONGESTED adverse phase inflates it to ~90ms RTT
    // (queue build-up — the corroboration LOSS-TOLERANCE #4 requires), a WEATHER adverse phase
    // keeps it flat (loss alone must NOT move the bitrate).
    func oneWayMs(phase: Int) -> Double { (congestRTTInAdverse && phase == 1) ? 45.0 : 5.0 }
    var clockMs = 0.0
    var globalFrag = 0
    var recoveryPending = false
    var depth = jc.targetDepth
    var adverseSecondHalfUnrec = 0          // steady-state window (2nd half of adverse) for the fair FEC A/B

    func lossPercent(phase: Int) -> Int { phase == 1 ? 3 : 0 }           // adverse = 3%/frag (realistic congestion)
    func jitterMs(phase: Int, frame: Int) -> Double {                     // adverse = ±0/30 ms saw
        guard enableJitter, phase == 1 else { return 0 }
        return (frame & 1) == 0 ? 0 : 40
    }

    for phase in 0..<3 {
        let loss = lossPercent(phase: phase)
        var phaseBitrateSum = 0.0, phaseBitrateN = 0
        var phasePeakTier: UInt8 = 0, phasePeakDepth = 0, phaseUnrec = 0
        var phaseEncBytesSum = 0, phaseEncN = 0
        let phaseName = phase == 1
            ? "ADVERSE (3% loss\(congestRTTInAdverse ? " + RTT inflation" : " at FLAT RTT = weather")\(enableJitter ? " + jitter" : ""))"
            : (phase == 0 ? "CLEAN" : "CLEAN recovery")
        if verbose { print("  ── PHASE \(phase + 1) \(phaseName) ──") }

        for f in 0..<framesPerPhase {
            // HOST: encode at the live bitrate (real HW honours the last setLiveBitrate).
            fillFrame(pb, phase * framesPerPhase + f)
            let force = (phase == 0 && f == 0) || recoveryPending
            recoveryPending = false
            clockMs += 1000.0 / Double(kFPS)
            do {
                try enc.encodeLive(pixelBuffer: pb, presentationTime: CMTime(value: Int64(phase * framesPerPhase + f), timescale: Int32(kFPS)), forceKeyframe: force)
            } catch { continue }
            enc.completeFrames()

            for out in sink.drain() {
                phaseEncBytesSum += out.avcc.count; phaseEncN += 1
                let sendTs = UInt32(clockMs)
                _ = pk.peekNextFrameID
                let frags = pk.packetize(frame: out.avcc, keyframe: out.keyframe, hostSendTsMillis: sendTs, fecTier: currentTier, isLTR: false)
                let tierGroup = AdaptiveFECPolicy.groupSize(forTier: currentTier, default: 5) ?? 0
                // The frame's fragments arrive spread across the wire (host paces large frames ~8 ms), NOT
                // all at one instant — so the per-fragment OWD jitter estimator sees realistic inter-arrival
                // deltas (the same `owd.note(arrival:)` per-fragment cadence as AislopdeskVideoClientSession).
                let frameArrivalMs = clockMs + oneWayMs(phase: phase) + jitterMs(phase: phase, frame: f)
                let intraGap = frags.count > 1 ? 8.0 / Double(frags.count) : 0.0

                // CLIENT: ingest each surviving fragment exactly as AislopdeskVideoClientSession.ingestVideo.
                for (localIdx, frag) in frags.enumerated() {
                    globalFrag += 1
                    let arrivalMs = frameArrivalMs + Double(localIdx) * intraGap
                    if loss > 0 && (globalFrag * 7 + 3) % 100 < loss { continue }   // deterministic ~loss%
                    guard let parsed = try? FrameFragment.decode(frag.encode()) else { continue }
                    owd.note(arrival: arrivalMs / 1000.0)
                    let ts = parsed.header.hostSendTsMillis
                    if ts != 0, latestHostSendTs == 0 || ts.distanceWrapped(from: latestHostSendTs) > 0 {
                        latestHostSendTs = ts; latestObservedAtMs = arrivalMs
                    }
                    switch ra.ingest(parsed) {
                    case .completed(let frame):
                        winFrames &+= 1
                        if frame.recoveredViaFEC { winFec &+= 1 }
                        try? dec.decode(frame)
                        if enableJitter { depth = jc.noteFrame(jitterSeconds: owd.jitterSeconds) }
                        phasePeakDepth = max(phasePeakDepth, depth)
                    case .dropped:
                        winUnrec &+= 1; phaseUnrec += 1; recoveryPending = true
                        if phase == 1 && f >= framesPerPhase / 2 { adverseSecondHalfUnrec += 1 }
                    case .incomplete, .stale:
                        break
                    }
                    while ra.nextDroppedFrame() != nil {
                        winUnrec &+= 1; phaseUnrec += 1; recoveryPending = true
                        if phase == 1 && f >= framesPerPhase / 2 { adverseSecondHalfUnrec += 1 }
                    }
                }
                _ = tierGroup

                // CLIENT: emit a NetworkStatsReport every `reportEvery` frames (the 50 ms cadence).
                if phaseEncN % reportEvery == 0 {
                    let holdMs = latestHostSendTs == 0 ? 0 : UInt32(max(0, arrivalMsHold(now: clockMs + oneWayMs(phase: phase), observedAt: latestObservedAtMs)))
                    let report = NetworkStatsReport(framesReceived: winFrames, fecRecovered: winFec,
                                                    unrecovered: winUnrec, latestHostSendTs: latestHostSendTs,
                                                    clientHoldMs: holdMs, owdJitterMicros: owd.jitterMicros())
                    winFrames = 0; winFec = 0; winUnrec = 0
                    // REAL wire round-trip of the telemetry.
                    let wire = RecoveryMessage.networkStats(report).encode()
                    guard case .networkStats(let rx)? = try? RecoveryMessage.decode(wire) else { continue }

                    // HOST: fold + tick + actuate — exactly AislopdeskVideoHostSession.handleRecovery(.networkStats).
                    let hostNowMs = UInt32(clockMs + oneWayMs(phase: phase) * 2)
                    let rtt = NetworkEstimate.computeRTTMillis(hostNowMs: hostNowMs, latestHostSendTs: rx.latestHostSendTs, clientHoldMs: rx.clientHoldMs)
                    est.fold(rttMillis: rtt, framesReceived: rx.framesReceived, unrecovered: rx.unrecovered, owdJitterMicros: rx.owdJitterMicros)
                    if enableFEC, fixedTier == nil { currentTier = AdaptiveFECPolicy.tier(forLossRate: est.lossRate, previousTier: currentTier) }
                    phasePeakTier = maxTier(phasePeakTier, currentTier)
                    if enableABR {
                        let target = cc.onReport(est)
                        lastTarget = target
                        if LiveCongestionController.isMaterialChange(previous: lastActuated, target: target, ceiling: cc.ceiling) {
                            lastActuated = target
                            _ = enc.setLiveBitrate(target)
                        }
                    }
                    phaseBitrateSum += Double(lastActuated) / 1_000_000.0; phaseBitrateN += 1
                    // The recovery verdict keys on the controller TARGET, not the actuated rate: the
                    // material-change gate deliberately hides sub-500k moves, and the cautious
                    // above-knee climb is sub-500k per tick by design.
                    if phase == 1 { result.adverseTroughMbps = min(result.adverseTroughMbps, Double(lastTarget) / 1_000_000.0) }

                    if verbose && (phaseEncN % (reportEvery * 5) == 0) {
                        print(String(format: "    f%-3d loss=%.3f unrec/win=%d  tier=%d(%@)  bitrate=%.1fMbps  depth=%d  enc~%dB",
                                     f, est.lossRate, Int(rx.unrecovered), Int(currentTier), tierDesc(currentTier),
                                     Double(lastActuated) / 1_000_000.0, depth, phaseEncN > 0 ? phaseEncBytesSum / phaseEncN : 0))
                    }
                }
            }
        }
        result.phaseAvgBitrateMbps.append(phaseBitrateN > 0 ? phaseBitrateSum / Double(phaseBitrateN) : Double(lastActuated) / 1_000_000.0)
        result.phasePeakTier.append(phasePeakTier)
        result.phasePeakDepth.append(phasePeakDepth)
        result.phaseUnrecovered.append(phaseUnrec)
        result.phaseAvgEncBytes.append(phaseEncN > 0 ? phaseEncBytesSum / phaseEncN : 0)
    }

    result.adverseUnrecSecondHalf = adverseSecondHalfUnrec
    result.endBitrateMbps = Double(lastTarget) / 1_000_000.0
    if result.phaseAvgBitrateMbps.count == 3 {
        result.bitrateFellInAdverse = result.phaseAvgBitrateMbps[1] < result.phaseAvgBitrateMbps[0] - 0.05
        // Recovery = the END state climbed back above the adverse TROUGH (see endBitrateMbps doc).
        result.bitrateRecoveredAfter = result.adverseTroughMbps.isFinite
            && result.endBitrateMbps > result.adverseTroughMbps + 0.05
    }
    return result
}

// MARK: - Bottleneck-queue scenario (DELAY-TARGETING, 2026-06-11)

/// Result of ``runBottleneckQueueScenario``.
struct BottleneckResult {
    var convergedAtMs: Double?      // first virtual time the actuated rate reached ≤ capacity
    var tailAvgQueueMs = 0.0        // mean standing queue over the last 25% of the run
    var tailMaxQueueMs = 0.0
    var rebashCount = 0             // post-convergence climbs back above capacity × 1.35 (pumping)
    var endActuatedMbps = 0.0
    var capacityMbps = 0.0
}

/// The scenario the scripted ADVERSE phase cannot express: a REAL feedback loop. The link is a fluid
/// bottleneck (capacity C, FIFO queue) — the queue grows when the encoder's actual bytes exceed C and
/// drains otherwise, and the RTT the controller sees IS `base + queue/C`. This is the measured
/// 2026-06-11 inter-ISP path shape (RTT 11ms idle → 80–110ms during scroll at loss=0.000): pure
/// bufferbloat, zero loss. Open-loop (ABR off / old once-per-second ×0.85) lets the queue stand for
/// seconds; the DELAY-TARGETING controller must (a) converge the rate under C quickly, (b) end with a
/// near-drained queue, (c) not pump back above C over and over (knee memory).
func runBottleneckQueueScenario(frames: Int, verbose: Bool) -> BottleneckResult {
    var result = BottleneckResult()

    let ceiling = LiveBitratePolicy.targetBitrate(pixelWidth: kWidth, pixelHeight: kHeight, fps: kFPS, floor: 2_000_000)
    let capacityBps = ceiling * 55 / 100        // between the 25% floor and the ceiling — convergence is reachable
    result.capacityMbps = Double(capacityBps) / 1_000_000.0
    var pk = VideoPacketizer(fec: XORParityFEC(groupSize: 5))
    var ra = FrameReassembler(fec: XORParityFEC(groupSize: 5))
    var est = NetworkEstimate()
    var cc = LiveCongestionController(ceiling: ceiling)
    var lastActuated = ceiling

    let sink = FrameSink()
    let decoded = Counter()
    let enc: VideoEncoder
    do {
        enc = VideoEncoder(width: kWidth, height: kHeight, fps: kFPS, ltrEnabled: false,
                           outputHandler: { avcc, kf, _, ltr in sink.append(avcc: avcc, keyframe: kf, ltr: ltr) })
        try enc.createLiveSession()
    } catch { print("  bottleneck encoder create FAILED: \(error)"); return result }
    _ = enc.setLiveBitrate(ceiling)
    let dec = VideoDecoder(decodedFrameHandler: { _ in decoded.value += 1 })
    guard let pb = makePixelBuffer(width: kWidth, height: kHeight, fullRange: false) else { return result }

    var owd = OWDJitterEstimator()
    var winFrames: UInt32 = 0, winFec: UInt32 = 0, winUnrec: UInt32 = 0
    var latestHostSendTs: UInt32 = 0
    var latestObservedAtMs = 0.0

    let frameIntervalMs = 1000.0 / Double(kFPS)
    let baseOneWayMs = 5.0
    var clockMs = 0.0
    var queueMs = 0.0                           // standing bottleneck queue, in ms-of-drain-time
    var encN = 0
    var queueSamples: [(ms: Double, queue: Double, actuated: Int)] = []

    for f in 0..<frames {
        fillFrame(pb, f)
        clockMs += frameIntervalMs
        // The bottleneck drains continuously, one frame-interval per frame tick.
        queueMs = max(0, queueMs - frameIntervalMs)
        do {
            try enc.encodeLive(pixelBuffer: pb, presentationTime: CMTime(value: Int64(f), timescale: Int32(kFPS)), forceKeyframe: f == 0)
        } catch { continue }
        enc.completeFrames()

        for out in sink.drain() {
            encN += 1
            let sendTs = UInt32(clockMs)
            let frags = pk.packetize(frame: out.avcc, keyframe: out.keyframe, hostSendTsMillis: sendTs, fecTier: 0, isLTR: false)
            // FEEDBACK: this frame's wire bytes join the queue; its own delivery waits behind it.
            let wireBytes = frags.reduce(0) { $0 + $1.encode().count }
            queueMs += Double(wireBytes * 8) / Double(capacityBps) * 1000.0
            let oneWay = baseOneWayMs + queueMs
            let frameArrivalMs = clockMs + oneWay
            let intraGap = frags.count > 1 ? 8.0 / Double(frags.count) : 0.0

            for (localIdx, frag) in frags.enumerated() {
                let arrivalMs = frameArrivalMs + Double(localIdx) * intraGap
                guard let parsed = try? FrameFragment.decode(frag.encode()) else { continue }
                owd.note(arrival: arrivalMs / 1000.0)
                let ts = parsed.header.hostSendTsMillis
                if ts != 0, latestHostSendTs == 0 || ts.distanceWrapped(from: latestHostSendTs) > 0 {
                    latestHostSendTs = ts; latestObservedAtMs = arrivalMs
                }
                switch ra.ingest(parsed) {
                case .completed(let frame):
                    winFrames &+= 1
                    if frame.recoveredViaFEC { winFec &+= 1 }
                    try? dec.decode(frame)
                case .dropped: winUnrec &+= 1
                case .incomplete, .stale: break
                }
            }

            if encN % 3 == 0 {                  // the ~50ms report cadence
                let holdMs = latestHostSendTs == 0 ? 0 : UInt32(max(0, arrivalMsHold(now: clockMs + oneWay, observedAt: latestObservedAtMs)))
                let report = NetworkStatsReport(framesReceived: winFrames, fecRecovered: winFec,
                                                unrecovered: winUnrec, latestHostSendTs: latestHostSendTs,
                                                clientHoldMs: holdMs, owdJitterMicros: owd.jitterMicros())
                winFrames = 0; winFec = 0; winUnrec = 0
                let wire = RecoveryMessage.networkStats(report).encode()
                guard case .networkStats(let rx)? = try? RecoveryMessage.decode(wire) else { continue }
                let hostNowMs = UInt32(clockMs + oneWay + baseOneWayMs)   // return path rides the un-queued direction
                let rtt = NetworkEstimate.computeRTTMillis(hostNowMs: hostNowMs, latestHostSendTs: rx.latestHostSendTs, clientHoldMs: rx.clientHoldMs)
                est.fold(rttMillis: rtt, framesReceived: rx.framesReceived, unrecovered: rx.unrecovered, owdJitterMicros: rx.owdJitterMicros)
                let target = cc.onReport(est)
                if LiveCongestionController.isMaterialChange(previous: lastActuated, target: target, ceiling: cc.ceiling) {
                    lastActuated = target
                    _ = enc.setLiveBitrate(target)
                }
                queueSamples.append((clockMs, queueMs, lastActuated))
                if result.convergedAtMs == nil, lastActuated <= capacityBps { result.convergedAtMs = clockMs }
                if verbose && encN % 30 == 0 {
                    print(String(format: "    t=%5.0fms  queue=%5.1fms  smoothedRTT=%5.1fms  rate=%4.1fMbps  knee=%@",
                                 clockMs, queueMs, est.smoothedRTTMillis, Double(lastActuated) / 1_000_000.0,
                                 cc.kneeBps.map { String(format: "%.1fM", Double($0) / 1_000_000.0) } ?? "-"))
                }
            }
        }
    }

    let tail = queueSamples.suffix(max(1, queueSamples.count / 4))
    result.tailAvgQueueMs = tail.reduce(0.0) { $0 + $1.queue } / Double(tail.count)
    result.tailMaxQueueMs = tail.reduce(0.0) { max($0, $1.queue) }
    if let conv = result.convergedAtMs {
        result.rebashCount = zip(queueSamples, queueSamples.dropFirst())
            .filter { $0.0.ms >= conv && $0.0.actuated <= capacityBps * 135 / 100 && $0.1.actuated > capacityBps * 135 / 100 }
            .count
    }
    result.endActuatedMbps = Double(lastActuated) / 1_000_000.0
    return result
}

/// clientHoldMs as the real client computes it: (now − observedAt) in ms, clamped non-negative.
func arrivalMsHold(now: Double, observedAt: Double) -> Double { max(0, now - observedAt) }
/// Peak by REDUNDANCY level (wire tier numbering is non-monotonic), so g2 ranks above g5 above OFF.
func maxTier(_ a: UInt8, _ b: UInt8) -> UInt8 {
    func g(_ t: UInt8) -> Int { switch AdaptiveFECPolicy.groupSize(forTier: t, default: 5) { case nil: return 0; case .some(let v): return 100 - v } }
    return g(b) > g(a) ? b : a
}

func runClosedLoopSuite(framesPerPhase: Int) {
    print("\n=== CLOSED-LOOP ADAPTATION :: full reflex through REAL components (in-process lossy transport) ===")
    print("    real HW encode→packetize(tier)→LOSS→reassemble+FEC→NetworkStatsReport(REAL wire)→")
    print("    host fold→AdaptiveFECPolicy.tier + LiveCongestionController→encoder.setLiveBitrate; client jitter→depth.")
    print("    \(framesPerPhase) frames/phase, phases: CLEAN → ADVERSE(3% loss+jitter) → CLEAN.\n")

    print("  [A] ALL adaptation ON (ABR + adaptive FEC + adaptive jitter)")
    let on = runClosedLoopAdaptation(framesPerPhase: framesPerPhase, enableABR: true, enableFEC: true, enableJitter: true, verbose: true)
    func mbps(_ x: Double) -> String { String(format: "%.1f", x) }
    print("    BITRATE  Mbps/phase  : clean=\(mbps(on.phaseAvgBitrateMbps[0]))  adverse=\(mbps(on.phaseAvgBitrateMbps[1]))  recovery=\(mbps(on.phaseAvgBitrateMbps[2]))")
    print("    ENC bytes/frame      : clean=\(on.phaseAvgEncBytes[0])  adverse=\(on.phaseAvgEncBytes[1])  recovery=\(on.phaseAvgEncBytes[2])  (HW honoured setLiveBitrate ⇒ bytes track bitrate)")
    print("    FEC tier  peak/phase : clean=\(tierDesc(on.phasePeakTier[0]))  adverse=\(tierDesc(on.phasePeakTier[1]))  recovery=\(tierDesc(on.phasePeakTier[2]))")
    print("    JITTER depth peak    : clean=\(on.phasePeakDepth[0])  adverse=\(on.phasePeakDepth[1])  recovery=\(on.phasePeakDepth[2])")
    print("    UNRECOVERED/phase    : clean=\(on.phaseUnrecovered[0])  adverse=\(on.phaseUnrecovered[1])  recovery=\(on.phaseUnrecovered[2])")

    print("\n  [B] adaptive-FEC A/B control (ABR+jitter ON, FEC pinned at today-default g5 = non-adaptive baseline)")
    let fecPinned = runClosedLoopAdaptation(framesPerPhase: framesPerPhase, enableABR: true, enableFEC: false, enableJitter: true, fixedTier: 0, verbose: false)
    // Fair window = STEADY-STATE (2nd half of adverse): excludes the adaptive run's climb-from-OFF transient,
    // which the pinned baseline doesn't pay. There the adaptive tier has settled at its heaviest (g3/g2).
    print("    adverse STEADY-STATE (2nd half) UNRECOVERED : adaptive=\(on.adverseUnrecSecondHalf)  vs  pinned-g5=\(fecPinned.adverseUnrecSecondHalf)")
    print("    adverse FULL-phase UNRECOVERED              : adaptive=\(on.phaseUnrecovered[1])  vs  pinned-g5=\(fecPinned.phaseUnrecovered[1])  (adaptive pays a climb-from-OFF transient)")
    let fecHelped = on.adverseUnrecSecondHalf <= fecPinned.adverseUnrecSecondHalf

    print("\n  [C] LOSS-TOLERANCE #4 weather control (ABR ON, 3% loss at FLAT RTT — the measured 2026-06-10 path shape)")
    let weather = runClosedLoopAdaptation(framesPerPhase: framesPerPhase, enableABR: true, enableFEC: true, enableJitter: false,
                                          congestRTTInAdverse: false, verbose: false)
    let weatherHeld = !weather.bitrateFellInAdverse
    print("    BITRATE  Mbps/phase  : clean=\(mbps(weather.phaseAvgBitrateMbps[0]))  weather=\(mbps(weather.phaseAvgBitrateMbps[1]))  after=\(mbps(weather.phaseAvgBitrateMbps[2]))")

    print("\n  [D] DELAY-TARGETING bottleneck queue (capacity = 55% of ceiling, ZERO loss — the measured 2026-06-11 scroll shape)")
    let bn = runBottleneckQueueScenario(frames: framesPerPhase * 5, verbose: true)
    let bnConverged = bn.convergedAtMs.map { $0 <= 2_500 } ?? false
    // The controller TARGETS the rttSlack (15ms) trim boundary, so the steady hover averages around
    // it (± probe overshoot) — 25ms is the "queue is governed, not standing" gate (vs ~600-900ms
    // ungoverned).
    let bnDrained = bn.tailAvgQueueMs < 25.0
    let bnNoPump = bn.rebashCount <= 1
    print(String(format: "    capacity=%.1fMbps  converged at t=%@  end rate=%.1fMbps", bn.capacityMbps,
                 bn.convergedAtMs.map { String(format: "%.0fms", $0) } ?? "NEVER", bn.endActuatedMbps))
    print(String(format: "    tail (last 25%%) queue: avg=%.1fms max=%.1fms   re-bash climbs after convergence=%d", bn.tailAvgQueueMs, bn.tailMaxQueueMs, bn.rebashCount))

    print("\n  ===== CLOSED-LOOP VERDICT =====")
    print("    #2 ABR        : bitrate fell under CORROBORATED loss (RTT inflated)=\(on.bitrateFellInAdverse ? "YES" : "no")  recovered after=\(on.bitrateRecoveredAfter ? "YES" : "no")  \(on.bitrateFellInAdverse && on.bitrateRecoveredAfter ? "✅" : "⚠️")")
    print("    #2b weather   : bitrate HELD under uncorroborated weather loss (flat RTT)=\(weatherHeld ? "YES" : "no")  \(weatherHeld ? "✅" : "⚠️")")
    let tierClimbed = maxTier(on.phasePeakTier[1], on.phasePeakTier[0]) == on.phasePeakTier[1] && on.phasePeakTier[1] != on.phasePeakTier[0]
    print("    #3 adaptiveFEC: tier escalated under loss=\(tierClimbed ? "YES" : "no")  reduced unrecovered=\(fecHelped ? "YES" : "no")  \(tierClimbed && fecHelped ? "✅" : "⚠️")")
    let depthGrew = on.phasePeakDepth[1] > on.phasePeakDepth[0]
    print("    #4 adaptiveJit: playout depth grew under jitter=\(depthGrew ? "YES" : "no")  \(depthGrew ? "✅" : "⚠️")")
    let hwTracked = on.phaseAvgEncBytes[1] < on.phaseAvgEncBytes[0]
    print("    HW actuation  : encoded bytes shrank with bitrate=\(hwTracked ? "YES" : "no") (real VTSessionSetProperty took effect)  \(hwTracked ? "✅" : "⚠️")")
    print("    #5 delay-targeting: converged ≤2.5s=\(bnConverged ? "YES" : "no")  tail queue <25ms=\(bnDrained ? "YES" : "no")  no pumping=\(bnNoPump ? "YES" : "no")  \(bnConverged && bnDrained && bnNoPump ? "✅" : "⚠️")")
}

// MARK: - Pure controller drive (no HW)

func runControllerDrive() {
    print("\n=== 5. PURE CONTROLLERS on synthetic telemetry (no HW) ===")

    // --- NetworkEstimate ---
    print("  [NetworkEstimate]")
    var est = NetworkEstimate()
    for _ in 0..<5 { est.fold(rttMillis: 20, framesReceived: 100, unrecovered: 0, owdJitterMicros: 500) }
    print(String(format: "    clean x5  -> smoothedRTT=%.1fms minRTT=%.1fms lossRate=%.4f lastLoss=%.4f owdRising=%@",
                 est.smoothedRTTMillis, est.minRTTMillis, est.lossRate, est.lastLossSample, est.owdGradientRising ? "true" : "false"))
    est.fold(rttMillis: 60, framesReceived: 100, unrecovered: 12, owdJitterMicros: 3000)
    print(String(format: "    loss spike -> smoothedRTT=%.1fms minRTT=%.1fms lossRate=%.4f lastLoss=%.4f owdRising=%@",
                 est.smoothedRTTMillis, est.minRTTMillis, est.lossRate, est.lastLossSample, est.owdGradientRising ? "true" : "false"))
    let rtt = NetworkEstimate.computeRTTMillis(hostNowMs: 1000, latestHostSendTs: 950, clientHoldMs: 10)
    print("    computeRTTMillis(hostNow=1000, sendTs=950, hold=10) = \(rtt.map(String.init) ?? "nil") ms (expect 40)")

    // --- LiveCongestionController ---
    print("  [LiveCongestionController] AIMD bitrate (ceiling=45 Mbps)")
    var cc = LiveCongestionController(ceiling: 45_000_000)
    print("    ceiling=\(cc.ceiling) floor=\(cc.floor) start=\(cc.current)")
    var ce = NetworkEstimate()
    for _ in 0..<10 { ce.fold(rttMillis: 20, framesReceived: 100, unrecovered: 0, owdJitterMicros: 400); cc.onReport(ce) }
    print("    after 10 warmup clean reports: current=\(cc.current) (held at ceiling)")
    for k in 0..<5 {
        ce.fold(rttMillis: 25, framesReceived: 100, unrecovered: 4, owdJitterMicros: 600) // raw loss 0.04 > 0.02
        print("    congestion report \(k + 1) (loss 4%): current=\(cc.onReport(ce))")
    }
    ce.fold(rttMillis: 30, framesReceived: 100, unrecovered: 20, owdJitterMicros: 900) // raw loss 0.20 severe
    print("    SEVERE report (loss 20%): current=\(cc.onReport(ce))")
    for _ in 0..<30 { ce.fold(rttMillis: 20, framesReceived: 100, unrecovered: 0, owdJitterMicros: 300); cc.onReport(ce) }
    print("    after 30 clean recovery reports: current=\(cc.current) (additive climb back toward ceiling)")

    // --- AdaptiveFECPolicy.tier ---
    print("  [AdaptiveFECPolicy.tier] loss -> tier ladder (hysteresis + one-step clamp)")
    var t: UInt8 = 0
    let lossSweep: [Double] = [0.0, 0.006, 0.025, 0.06, 0.12, 0.12, 0.04, 0.012, 0.001, 0.0, 0.0]
    for l in lossSweep {
        t = AdaptiveFECPolicy.tier(forLossRate: l, previousTier: t)
        print(String(format: "    loss=%.3f -> tier=%d (%@)", l, Int(t), tierDesc(t)))
    }

    // --- OWDJitterEstimator + AdaptiveJitterController ---
    print("  [OWDJitterEstimator + AdaptiveJitterController]")
    var jit = OWDJitterEstimator()
    var arrival = 0.0
    let intervals: [Double] = [0.016, 0.016, 0.050, 0.016, 0.045, 0.016, 0.055, 0.016, 0.040, 0.016]
    for dt in intervals { arrival += dt; jit.note(arrival: arrival) }
    print("    jittery arrival series -> jitterMicros=\(jit.jitterMicros())us (smoothed seconds=\(String(format: "%.5f", jit.jitterSeconds)))")
    var jc = AdaptiveJitterController(maxDepth: 8, fps: 60, initialDepth: 1)
    print("    targetDepth start=\(jc.targetDepth)")
    for j in [0.0, 0.005, 0.010, 0.020, 0.030] {
        print(String(format: "    noteFrame(jitter=%.3fs) -> depth=%d (grow-fast)", j, jc.noteFrame(jitterSeconds: j)))
    }
    print("    noteUnderrun() -> depth=\(jc.noteUnderrun()) (bump)")
    for _ in 0..<200 { jc.noteFrame(jitterSeconds: 0.0) } // shrink-slow: one step per cooldown
    print("    after 200 low-jitter frames -> depth=\(jc.targetDepth) (shrink-slow)")

    // --- LTRController (pure) ---
    print("  [LTRController] record -> ack -> recoveryDecision -> reset")
    var ltr = LTRController()
    print("    before ack: recoveryDecision(.ltrRefresh) = \(ltr.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true)) (expect idr)")
    ltr.recordLTRFrame(frameID: 10, token: 7777)
    print("    ackFrame(10) -> \(ltr.ackFrame(frameID: 10).map(String.init) ?? "nil") (expect 7777)")
    print("    hasAckedToken = \(ltr.hasAckedToken)")
    print("    after ack: recoveryDecision(.ltrRefresh) = \(ltr.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true)) (expect ltrRefresh)")
    print("    requestIDR always -> \(ltr.recoveryDecision(request: .idr, hasEnableLTR: true)) (expect idr)")
    print("    LTR off -> \(ltr.recoveryDecision(request: .ltrRefresh, hasEnableLTR: false)) (expect idr)")
    print("    ackFrame(unknown 999) -> \(ltr.ackFrame(frameID: 999).map(String.init) ?? "nil") (expect nil)")
    ltr.reset()
    print("    after reset: hasAckedToken=\(ltr.hasAckedToken) recoveryDecision(.ltrRefresh)=\(ltr.recoveryDecision(request: .ltrRefresh, hasEnableLTR: true)) (expect false, idr)")

    // --- NetworkStatsReport round-trip (the telemetry wire that feeds the above) ---
    let report = NetworkStatsReport(framesReceived: 120, fecRecovered: 5, unrecovered: 2, latestHostSendTs: 950, clientHoldMs: 10, owdJitterMicros: 1500)
    let wire = RecoveryMessage.networkStats(report).encode()
    if case .networkStats(let rt)? = try? RecoveryMessage.decode(wire) {
        print("  [NetworkStatsReport] wire round-trip OK: framesReceived=\(rt.framesReceived) unrecovered=\(rt.unrecovered) jitter=\(rt.owdJitterMicros)us (\(wire.count)-byte msg)")
    } else {
        print("  [NetworkStatsReport] wire round-trip FAILED")
    }
}

// MARK: - Summary

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}

func printSummary(_ all: [ScenarioStats]) {
    print("\n========================== SUMMARY ==========================")
    print(pad("scenario", 34) + lpad("enc", 5) + lpad("fragS", 8) + lpad("fragD", 7)
        + lpad("reasm", 7) + lpad("fecR", 6) + lpad("drop", 6) + lpad("decOK", 7) + lpad("decErr", 7))
    for s in all {
        print(pad(s.name, 34) + lpad("\(s.encoded)", 5) + lpad("\(s.fragmentsSent)", 8)
            + lpad("\(s.fragmentsDropped)", 7) + lpad("\(s.reassembled)", 7) + lpad("\(s.fecRecovered)", 6)
            + lpad("\(s.framesDropped)", 6) + lpad("\(s.decoded)", 7) + lpad("\(s.decodeFailures)", 7))
    }
    print("============================================================")
}

// MARK: - Entry (top-level, synchronous)

let args = CommandLine.arguments
let smoke = args.contains("--smoke")
let closedLoopOnly = args.contains("--closed-loop")
let ackRefOnly = args.contains("--ack-ref")
var frameCount = Int(ProcessInfo.processInfo.environment["AISLOPDESK_LV_FRAMES"] ?? "") ?? 120
if let idx = args.firstIndex(of: "--frames"), idx + 1 < args.count, let n = Int(args[idx + 1]) { frameCount = n }
if smoke { frameCount = 10 }

print("=== aislopdesk-loopback-validate :: headless closed-loop video validation ===")
print("    mode=\(smoke ? "SMOKE" : "FULL")  perScenarioFrames=\(frameCount)  size=\(kWidth)x\(kHeight)@\(kFPS)\n")

print("=== HW HEVC LTR capability probe (proves the HW encode path is alive headlessly) ===")
VideoEncoder.runLTRCapabilityProbe(log: { print("  " + $0) })
print("")

if closedLoopOnly {
    runClosedLoopSuite(framesPerPhase: max(60, frameCount))
    print("\naislopdesk-loopback-validate: COMPLETE (closed-loop only) — exiting 0")
    exit(0)
}

if ackRefOnly {
    runAckRefProbe(frames: max(60, frameCount))
    print("\naislopdesk-loopback-validate: COMPLETE (ack-ref probe only) — exiting 0")
    exit(0)
}

var allStats: [ScenarioStats] = []

if smoke {
    print("=== SMOKE: clean link, FEC OFF (10 frames) ===")
    allStats.append(runScenario(name: "SMOKE clean FEC OFF", frames: frameCount, tier: 1, loss: .none))
} else {
    print("=== 1. clean link, FEC OFF ===")
    allStats.append(runScenario(name: "1. clean link, FEC OFF", frames: frameCount, tier: 1, loss: .none))
    print("=== 2. clean link, FEC g5 ===")
    allStats.append(runScenario(name: "2. clean link, FEC g5", frames: frameCount, tier: 0, loss: .none))
    print("=== 3. 2% loss, FEC g5 (expect most frames FEC-recovered) ===")
    allStats.append(runScenario(name: "3. 2% loss, FEC g5", frames: frameCount, tier: 0, loss: .everyN(50)))
    print("=== 4. 10% loss, FEC g3 (heavier redundancy) ===")
    allStats.append(runScenario(name: "4. 10% loss, FEC g3", frames: frameCount, tier: 3, loss: .everyN(10)))

    print("=== FEC tier sweep: drop 1 data fragment per group (OFF must NOT recover; others must) ===")
    let demoFrames = max(10, min(frameCount, 30))
    for tier in [UInt8(1), 2, 3, 4, 0] {
        allStats.append(runScenario(
            name: "FEC tier \(tier) (\(tierDesc(tier))) 1-hole/grp",
            frames: demoFrames, tier: tier, loss: .firstPerGroup(1)))
    }

    // ── #6 INTERLEAVE investigation: prove the column-major send reorder (a) decodes cleanly through
    // the REAL HW decoder with NO loss (the white-screen regression would surface here if it were a
    // protocol/codec fault), and (b) turns an adjacent-datagram BURST that single-loss XOR cannot
    // recover in consecutive order into a fully recoverable, decodable stream. Tier 0 = g5 parity.
    print("=== 7. INTERLEAVE, clean link (tier g5) — must decode ALL through real HW (white-screen check) ===")
    allStats.append(runScenario(name: "7. interleave clean g5", frames: frameCount, tier: 0, loss: .none, interleave: true))

    print("=== 8. burst-2 adjacent, NO interleave (tier g5) — 2 in one group → expect UNRECOVERED ===")
    allStats.append(runScenario(name: "8. burst-2 NO interleave g5", frames: frameCount, tier: 0, loss: .wireBurst(start: 1, len: 2), interleave: false))

    print("=== 9. burst-2 adjacent, WITH interleave (tier g5) — spread 1/group → expect FEC RECOVERS ===")
    allStats.append(runScenario(name: "9. burst-2 interleave g5", frames: frameCount, tier: 0, loss: .wireBurst(start: 1, len: 2), interleave: true))

    print("=== 9b. burst-3 adjacent, WITH interleave (tier g5) — deeper burst still recovers ===")
    allStats.append(runScenario(name: "9b. burst-3 interleave g5", frames: frameCount, tier: 0, loss: .wireBurst(start: 1, len: 3), interleave: true))

    print("=== 6. LTR HW (record -> ack -> ForceLTRRefresh -> decode) ===")
    allStats.append(runLTRHWScenario(frames: max(6, min(frameCount, 12))))

    runClosedLoopSuite(framesPerPhase: 90)
}

runControllerDrive()
printSummary(allStats)

print("\naislopdesk-loopback-validate: COMPLETE — exiting 0")
exit(0)

#else
FileHandle.standardError.write(Data("aislopdesk-loopback-validate requires macOS (VideoToolbox HW encode/decode).\n".utf8))
exit(1)
#endif
