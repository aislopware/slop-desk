// aislopdesk-framewatch — objective frame-cadence instrument (2026-06-10 khựng hunt).
//
// Captures ONE window via ScreenCaptureKit `desktopIndependentWindow` (works on a BACKGROUND /
// occluded window — full-screen `screencapture -v` could not measure this honestly) and records
// the per-frame ARRIVAL timeline: SCK delivers a frame only when the window's content changes,
// so the arrival cadence IS the window's presentation cadence. No video is written — each frame
// is reduced to a timestamp + a cheap luma checksum (detects identical-content re-deliveries).
//
// Output: an inter-frame-interval histogram + stall bins (1-slot ≈ 33ms at 60fps content, worse),
// directly comparable across Aislopdesk and Parsec windows on the same machine.
//
// Usage: aislopdesk-framewatch --title <substring> [--seconds 20] [--fps 120] [--list]
//        aislopdesk-framewatch --latency --title-a <source> --title-b <client> [--seconds 30]
// LATENCY MODE: watches TWO windows at once; the source window is expected to FLASH between
// dark and light (a flasher HTML page); each window's mean luma is tracked with a hysteresis
// state machine, and every source flip is paired with the first same-polarity client flip that
// follows → per-flash glass-to-glass(compositor) latency, reported p50/p90/min/max.
// Runtime needs a GUI session + Screen Recording TCC (run via `open` of a .command on the target
// Mac). Exit code 1 on setup failure with a reason on stderr.

#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// SCStream needs a live window-server (CGS) connection; a bare CLI has none and trips
// `CGS_REQUIRE_INIT`. Touching NSApplication.shared initializes it (GUI session required anyway).
_ = NSApplication.shared

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Args

var titleQuery: String?
var seconds = 20.0
var fps = 120
var listOnly = false
var latencyMode = false
var titleA: String?
var titleB: String?
var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = args.next() {
    switch a {
    case "--title": titleQuery = args.next()
    case "--seconds": seconds = args.next().flatMap(Double.init) ?? 20.0
    case "--fps": fps = args.next().flatMap(Int.init) ?? 120
    case "--list": listOnly = true
    case "--latency": latencyMode = true
    case "--title-a": titleA = args.next()
    case "--title-b": titleB = args.next()
    default: eprint("unknown arg: \(a)"); exit(1)
    }
}

// MARK: - Frame collector

final class Collector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var arrivals: [Double] = []
    private(set) var checksums: [UInt64] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // SCK also delivers idle/status frames — only count COMPLETE content frames.
        if let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = infos.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw), status != .complete {
            return
        }
        let now = CACurrentMediaTime()
        // Cheap content checksum: FNV-1a over one row sampled every 16 rows of the luma plane —
        // enough to distinguish "new content" from a re-delivered identical frame, ~µs cost.
        var hash: UInt64 = 0xcbf29ce484222325
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let plane = CVPixelBufferGetPlaneCount(pb) > 0 ? 0 : -1
        let base = plane >= 0 ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        if let base {
            let height = plane >= 0 ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
            let stride = plane >= 0 ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
            let width = min(stride, 1024)
            var row = 0
            while row < height {
                let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                var col = 0
                while col < width {
                    hash = (hash ^ UInt64(p[col])) &* 0x100000001b3
                    col += 8
                }
                row += 16
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        lock.lock()
        arrivals.append(now)
        checksums.append(hash)
        lock.unlock()
    }

    func report() {
        lock.lock(); defer { lock.unlock() }
        guard arrivals.count > 1 else { print("framewatch: <2 frames captured — window idle or capture failed"); return }
        var dts: [Double] = []
        var repeats = 0
        for i in 1..<arrivals.count {
            dts.append((arrivals[i] - arrivals[i - 1]) * 1000)
            if checksums[i] == checksums[i - 1] { repeats += 1 }
        }
        let sorted = dts.sorted()
        let sum = dts.reduce(0, +)
        let n = Double(dts.count)
        let bin = { (lo: Double, hi: Double) in dts.filter { $0 > lo && $0 <= hi }.count }
        print("framewatch: frames=\(arrivals.count) span=\(String(format: "%.1f", (arrivals.last! - arrivals.first!)))s eff_fps=\(String(format: "%.1f", n / (sum / 1000)))")
        print("framewatch: dt p50=\(String(format: "%.1f", sorted[Int(n * 0.5)]))ms p90=\(String(format: "%.1f", sorted[Int(n * 0.9)]))ms p99=\(String(format: "%.1f", sorted[min(dts.count - 1, Int(n * 0.99))]))ms max=\(String(format: "%.1f", sorted.last!))ms")
        print("framewatch: bins ≤20ms=\(bin(0, 20)) 20-28ms=\(bin(20, 28)) 28-42ms(1-slot)=\(bin(28, 42)) 42-60ms(2-slot)=\(bin(42, 60)) >60ms=\(bin(60, .infinity))")
        print("framewatch: identical-content re-deliveries=\(repeats)")
    }
}

// MARK: - Latency mode (two-window flash correlation)

/// Tracks one window's mean luma with a hysteresis state machine; records flip timestamps.
/// `>0.62` of full scale = light, `<0.38` = dark (wide hysteresis so HEVC ringing/QP noise on
/// the streamed copy can't double-trigger). Flip event = state transition after the first state.
final class LumaFlipDetector: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Flip { let time: Double; let toLight: Bool }
    private let lock = NSLock()
    private(set) var flips: [Flip] = []
    private var state: Bool? // nil until first classification; true = light
    let label: String
    init(label: String) { self.label = label }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = infos.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw), status != .complete {
            return
        }
        let now = CACurrentMediaTime()
        var sum = 0, count = 0
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let planar = CVPixelBufferGetPlaneCount(pb) > 0
        if let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) {
            let height = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
            let width = min(stride, 1024)
            var row = height / 4   // sample the central half (skip window chrome / pane borders)
            while row < (height * 3) / 4 {
                let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                var col = width / 4
                while col < (width * 3) / 4 {
                    sum += Int(p[col]); count += 1
                    col += 8
                }
                row += 8
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        guard count > 0 else { return }
        let avg = Double(sum) / Double(count) / 255.0
        let newState: Bool?
        if avg > 0.62 { newState = true } else if avg < 0.38 { newState = false } else { newState = nil }
        guard let newState else { return }
        lock.lock()
        if let s = state, s != newState {
            flips.append(Flip(time: now, toLight: newState))
        }
        if state != newState { state = newState }
        lock.unlock()
    }

    func snapshotFlips() -> [Flip] { lock.lock(); defer { lock.unlock() }; return flips }
}

@MainActor
func startWatch(window: SCWindow, fps: Int, output: SCStreamOutput & NSObject, asDisplay: SCDisplay? = nil) throws -> SCStream {
    // `asDisplay` non-nil ⇒ capture the WHOLE display the window sits on (the game-streaming
    // path) instead of the per-window composite — used to A/B SCK's delivery latency between
    // the two filter kinds (the window path is suspected of ~1 extra frame of internal latency).
    let filter = asDisplay.map { SCContentFilter(display: $0, excludingWindows: []) }
        ?? SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = max(64, Int(window.frame.width) / 2)
    config.height = max(64, Int(window.frame.height) / 2)
    if let asDisplay {
        // Crop the display capture to the window's rect (display-local points) so the luma
        // detector reads the SAME content as the window-filter watcher.
        let db = CGDisplayBounds(asDisplay.displayID)
        config.sourceRect = CGRect(x: window.frame.minX - db.minX, y: window.frame.minY - db.minY,
                                   width: window.frame.width, height: window.frame.height)
    }
    config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
    config.queueDepth = 8
    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    config.showsCursor = false
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "framewatch.\(ObjectIdentifier(output))", qos: .userInteractive))
    return stream
}

func findWindow(_ content: SCShareableContent, query: String) -> SCWindow? {
    let q = query.lowercased()
    return content.windows.filter {
        ($0.title?.lowercased().contains(q) ?? false) || ($0.owningApplication?.applicationName.lowercased().contains(q) ?? false)
    }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

// MARK: - Main

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if listOnly {
            for w in content.windows where w.isOnScreen || w.frame.width > 100 {
                print("id=\(w.windowID)\t\(w.owningApplication?.applicationName ?? "?")\t\(w.title ?? "")\t[\(Int(w.frame.width))x\(Int(w.frame.height))]")
            }
            exit(0)
        }
        if latencyMode {
            guard let qa = titleA, let qb = titleB else { eprint("--latency needs --title-a and --title-b"); exit(1) }
            // "@display" suffix on either title ⇒ watch the DISPLAY containing that window
            // (SCK filter-kind A/B). e.g. --title-a "FLASHER@display" --title-b "FLASHER".
            func resolve(_ q: String) -> (SCWindow, SCDisplay?)? {
                var qEff = q
                var disp: SCDisplay? = nil
                if q.hasSuffix("@display") {
                    qEff = String(q.dropLast("@display".count))
                    guard let w = findWindow(content, query: qEff) else { return nil }
                    disp = content.displays.first { CGDisplayBounds($0.displayID).intersects(w.frame) } ?? content.displays.first
                    return (w, disp)
                }
                guard let w = findWindow(content, query: qEff) else { return nil }
                return (w, nil)
            }
            guard let (wa, aAsDisplay) = resolve(qa) else { eprint("no window matching \"\(qa)\""); exit(1) }
            guard let (wb, bAsDisplay) = resolve(qb) else { eprint("no window matching \"\(qb)\""); exit(1) }
            print("framewatch[latency]: A=\(wa.windowID) \(wa.owningApplication?.applicationName ?? "?") \"\(wa.title ?? "")\"  B=\(wb.windowID) \(wb.owningApplication?.applicationName ?? "?") \"\(wb.title ?? "")\"  \(Int(seconds))s")
            let da = LumaFlipDetector(label: "A"), db = LumaFlipDetector(label: "B")
            let sa = try await startWatch(window: wa, fps: fps, output: da, asDisplay: aAsDisplay)
            let sb = try await startWatch(window: wb, fps: fps, output: db, asDisplay: bAsDisplay)
            try await sa.startCapture()
            try await sb.startCapture()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try? await sa.stopCapture()
            try? await sb.stopCapture()
            let fa = da.snapshotFlips(), fb = db.snapshotFlips()
            // Pair each source flip with the NEAREST same-polarity client flip within ±450ms
            // (half the flash period) — SIGNED delta, so an inverted hypothesis (B earlier than
            // A) reads as negative latency instead of zero pairs.
            var lats: [Double] = []
            for a in fa {
                var best: Double? = nil
                for b in fb where b.toLight == a.toLight {
                    let d = (b.time - a.time) * 1000
                    if abs(d) < 450, abs(d) < abs(best ?? .infinity) { best = d }
                }
                if let best { lats.append(best) }
            }
            print("framewatch[latency]: sourceFlips=\(fa.count) clientFlips=\(fb.count) paired=\(lats.count)")
            guard lats.count >= 5 else { print("framewatch[latency]: not enough pairs — is the flasher running and the pane streaming it?"); exit(1) }
            let s = lats.sorted()
            let f = { (v: Double) in String(format: "%.1f", v) }
            print("framewatch[latency]: glass-to-glass p50=\(f(s[s.count / 2]))ms p90=\(f(s[(s.count * 9) / 10]))ms min=\(f(s.first!))ms max=\(f(s.last!))ms n=\(s.count)")
            exit(0)
        }
        guard let query = titleQuery else { eprint("need --title <substring> (or --list)"); exit(1) }
        let q = query.lowercased()
        // Prefer the LARGEST match (the content window, not a toolbar/status sliver).
        let candidates = content.windows.filter {
            ($0.title?.lowercased().contains(q) ?? false) || ($0.owningApplication?.applicationName.lowercased().contains(q) ?? false)
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        guard let window = candidates.first else {
            eprint("no window matching \"\(query)\" — try --list"); exit(1)
        }
        print("framewatch: watching id=\(window.windowID) \(window.owningApplication?.applicationName ?? "?") \"\(window.title ?? "")\" [\(Int(window.frame.width))x\(Int(window.frame.height))] for \(Int(seconds))s @\(fps)Hz")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Quarter-size luma is plenty for cadence + checksum, and keeps capture overhead trivial.
        config.width = max(64, Int(window.frame.width) / 2)
        config.height = max(64, Int(window.frame.height) / 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false

        let collector = Collector()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "framewatch.frames", qos: .userInteractive))
        try await stream.startCapture()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try? await stream.stopCapture()
        collector.report()
        exit(0)
    } catch {
        eprint("framewatch failed: \(error.localizedDescription) (Screen Recording TCC? GUI session?)")
        exit(1)
    }
}

// SCK delivers several callbacks via the main run loop — park main IN the run loop (a
// semaphore.wait() here deadlocks SCShareableContent's completion delivery).
RunLoop.main.run()
#else
fatalError("aislopdesk-framewatch is macOS-only")
#endif
