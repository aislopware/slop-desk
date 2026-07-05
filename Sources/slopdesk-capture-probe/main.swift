// slopdesk-capture-probe — host-side frame dumper for geometric capture artifacts.
//
// Drives the REAL `WindowCapturer` (production filter/config path, including the
// `SLOPDESK_DISPLAY_CAPTURE` mode seam) against one window and writes each DELIVERED frame
// as a PNG (throttled). Built for the Chrome-tooltip crop-shift hunt: hover a link while this
// runs under each capture mode, then pixel-compare the dumps — a client-side screenshot can't
// measure a 1px capture shift through pane scaling/HEVC.
//
// Usage: slopdesk-capture-probe --title <substring> [--seconds 20] [--out DIR] [--max-hz 4]
//        slopdesk-capture-probe --list
// Mode comes from the production env seam, e.g.:
//        SLOPDESK_DISPLAY_CAPTURE=window  .build/debug/slopdesk-capture-probe --title Chrome
//        SLOPDESK_DISPLAY_CAPTURE=include .build/debug/slopdesk-capture-probe --title Chrome
// Runtime needs a GUI session + Screen Recording TCC. Exit 1 on setup failure.
// Diagnostic instrument (not shipped product) — excluded from strict lint in .swiftlint.yml, like
// slopdesk-loopback-validate.

#if os(macOS)
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SlopDeskVideoHost
import SlopDeskVideoProtocol

_ = NSApplication.shared // CGS connection — SCStream trips CGS_REQUIRE_INIT without it

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var titleQuery: String?
var windowIDArg: UInt32?
var seconds = 20.0
var outDir = "/tmp/capture-probe"
var maxHz = 4.0
var listOnly = false
var listAll = false
var cadence = false
var captureScaleArg = 1.0
var selfScrollPid: pid_t?
var useVD = false
var encodeMode = "off" // off | inline | offqueue
var crispEvery = 0 // >0: fire encodeLiveCrispKeyframe (synchronous CompleteFrames) every Kth frame
var kfEvery = 0 // >0: fire plain encodeLive(forceKeyframe) (NO CompleteFrames) every Kth frame
var ltrEvery = 0 // >0: fire encodeLiveLTRRefresh every Kth frame (recovery hot path)
var compactEvery = 0 // >0: fire encodeCompactKeyframe every Kth frame

// VD cleanup must survive any exit path (incl. SIGINT/SIGTERM) so the parked window is restored and
// the virtual display destroyed — globals so the signal sources can reach them.
nonisolated(unsafe) var gParking: WindowParkingManager?
nonisolated(unsafe) var gVD: VirtualDisplay?
func vdCleanup() {
    gParking?.restoreAll()
    gParking = nil
    gVD?.destroy()
    gVD = nil
}

nonisolated(unsafe) var gSignalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { vdCleanup()
        exit(2)
    }
    src.resume()
    gSignalSources.append(src)
}

var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = args.next() {
    switch a {
    case "--title": titleQuery = args.next()
    case "--window-id": windowIDArg = args.next().flatMap { UInt32($0) }
    case "--seconds": seconds = args.next().flatMap(Double.init) ?? 20.0
    case "--out": outDir = args.next() ?? outDir
    case "--max-hz": maxHz = args.next().flatMap(Double.init) ?? 4.0
    case "--scale": captureScaleArg = args.next().flatMap(Double.init) ?? 1.0
    case "--cadence": cadence = true // measure SCStream delivery-interval distribution (no PNGs)
    case "--self-scroll": selfScrollPid = args.next().flatMap { Int32($0) } // post scroll-wheel to this pid
    case "--vd": useVD = true // create a HiDPI virtual display + park the window on it (host's real path)
    case "--encode": encodeMode = "inline" // real HW encode INLINE on the capture queue (host default)
    case "--encode-offqueue": encodeMode = "offqueue" // real HW encode on a separate serial queue
    case "--crisp-every": crispEvery = args.next().flatMap { Int($0) } ?? 0 // crisp IDR (CompleteFrames) every Kth
    case "--kf-every": kfEvery = args.next()
        .flatMap { Int($0) } ?? 0 // plain force-keyframe (NO CompleteFrames) every Kth
    case "--ltr-every": ltrEvery = args.next()
        .flatMap { Int($0) } ?? 0 // encodeLiveLTRRefresh every Kth (recovery hot path)
    case "--compact-every": compactEvery = args.next().flatMap { Int($0) } ?? 0 // encodeCompactKeyframe every Kth
    case "--list": listOnly = true
    case "--list-all": listAll = true
    default: eprint("unknown arg: \(a)")
        exit(1)
    }
}

let task = Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if listAll {
            // RAW dump — every window SCK exposes, NO title/system filtering. Answers "does SCK list
            // SecurityAgent / system-dialog windows at all, and with what owner/pid/layer?".
            for w in content.windows.sorted(by: { $0.windowLayer < $1.windowLayer }) {
                let app = w.owningApplication
                let f = w.frame
                print("id=\(w.windowID) layer=\(w.windowLayer) onScreen=\(w.isOnScreen) pid=\(app?.processID ?? -1) " +
                    "[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] " +
                    "app=\(app?.applicationName ?? "?") bundle=\(app?.bundleIdentifier ?? "?") title=\(w.title ?? "<nil>")")
            }
            exit(0)
        }
        if listOnly {
            for w in content.windows where w.title?.isEmpty == false {
                print(
                    "id=\(w.windowID) [\(Int(w.frame.width))x\(Int(w.frame.height))] \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")",
                )
            }
            exit(0)
        }
        var window: SCWindow
        if let wid = windowIDArg {
            guard let w = content.windows.first(where: { $0.windowID == wid }) else {
                eprint("no window with id \(wid)")
                exit(1)
            }
            window = w
        } else if let needle = titleQuery {
            guard let w = content.windows
                .filter({
                    ($0.title ?? "")
                        .localizedCaseInsensitiveContains(needle) || ($0.owningApplication?.applicationName ?? "")
                        .localizedCaseInsensitiveContains(needle) })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else {
                eprint("no window matching '\(needle)'")
                exit(1)
            }
            window = w
        } else {
            eprint("need --window-id <N> or --title <substring> (or --list)")
            exit(1)
        }
        // VD MODE: create a HiDPI virtual display + park the window on it — the host's real capture
        // substrate. Isolates whether the CGVirtualDisplay's SYNTHESIZED vsync (no hardware VBLANK)
        // is what slips during scroll (vs a physical display). Restored on every exit path.
        if useVD {
            let geo = VirtualDisplayGeometry(pointWidth: 1920, pointHeight: 1080, scale: 2)
            let vd = VirtualDisplay()
            guard let vdID = await vd.create(geo, fps: 60) else { eprint("VD create FAILED")
                exit(1)
            }
            gVD = vd
            let pm = WindowParkingManager()
            guard let parked = pm.park(
                channelID: 1, windowID: window.windowID,
                pid: window.owningApplication?.processID ?? 0, displayID: vdID,
            ) else { eprint("park FAILED")
                vdCleanup()
                exit(1)
            }
            gParking = pm
            eprint("VD \(vdID) created, window parked at \(Int(parked.width))x\(Int(parked.height))pt")
            try await Task.sleep(nanoseconds: 500_000_000) // let WindowServer settle the move
            let c2 = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let w2 = c2.windows.first(where: { $0.windowID == window.windowID }) { window = w2 }
        }
        let scale = captureScaleArg // default 1.0 (point-resolution); --scale 2 mirrors the VD HiDPI path
        let pixelW = Int(window.frame.width * scale), pixelH = Int(window.frame.height * scale)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        eprint(
            "probing id=\(window.windowID) '\(window.title ?? "")' \(pixelW)x\(pixelH)px mode-env=\(ProcessInfo.processInfo.environment["SLOPDESK_DISPLAY_CAPTURE"] ?? "<unset>") → \(outDir)",
        )

        // ── CADENCE MODE: record every SCStream delivery timestamp, print the interval distribution.
        // This isolates the ONE question — does SCStream stall during scroll? — with no encode/client/net.
        // Scroll the window continuously (so every frame is `.complete`) while this runs; large intervals
        // during continuous scroll = real capture stalls. Effective fps = count/seconds.
        if cadence {
            final class Cad: @unchecked Sendable { let lock = NSLock()
                var ts: [Double] = []
            }
            let cad = Cad()
            cad.ts.reserveCapacity(Int(seconds * 130))
            // Optional REAL HW encode in the capture handler — replicates the host's per-frame encode
            // load. inline = on the capture queue (host default); offqueue = on a serial encode queue.
            final class EncStat: @unchecked Sendable { let lock = NSLock()
                var kfMaxBytes = 0
                var kfCount = 0
            }
            let estat = EncStat()
            var encoderTmp: VideoEncoder?
            let encQ = DispatchQueue(label: "probe.encode", qos: .userInteractive)
            let mode0 = encodeMode // immutable snapshot for the @Sendable handler
            if mode0 != "off" {
                let enc = VideoEncoder(
                    width: pixelW, height: pixelH, bitrate: 12_000_000, fps: 60,
                    fullRange: false, ltrEnabled: true, outputHandler: { avcc, keyframe, _, _, _ in
                        guard keyframe else { return }
                        estat.lock.lock()
                        estat.kfCount += 1
                        estat.kfMaxBytes = max(estat.kfMaxBytes, avcc.count)
                        estat.lock.unlock()
                    },
                )
                try enc.createLiveSession()
                encoderTmp = enc
                eprint("encode \(mode0) → real HW HEVC \(pixelW)x\(pixelH) @12Mbps ltr=on")
            }
            let encoder = encoderTmp // immutable for the @Sendable handler
            let crispK = crispEvery, kfK = kfEvery, ltrK = ltrEvery, compactK = compactEvery
            final class FrameN: @unchecked Sendable { var n = 0 }
            let fn = FrameN()
            let capturer = WindowCapturer(fps: 60, captureScale: scale) { pb, pts, _, _, _, _, _ in
                let now = CACurrentMediaTime()
                cad.lock.lock()
                cad.ts.append(now)
                cad.lock.unlock()
                guard let enc = encoder else { return }
                fn.n += 1
                let crisp = crispK > 0 && fn.n % crispK == 0
                let plainKF = kfK > 0 && fn.n % kfK == 0
                let ltr = ltrK > 0 && fn.n % ltrK == 0
                let compact = compactK > 0 && fn.n % compactK == 0
                nonisolated(unsafe) let buf = pb
                let doEncode: @Sendable () -> Void = {
                    do {
                        if crisp { try enc.encodeLiveCrispKeyframe(pixelBuffer: buf, presentationTime: pts) }
                        else if ltr { try enc.encodeLiveLTRRefresh(pixelBuffer: buf, presentationTime: pts) }
                        else if compact { try enc.encodeCompactKeyframe(pixelBuffer: buf, presentationTime: pts) }
                        else { try enc.encodeLive(pixelBuffer: buf, presentationTime: pts, forceKeyframe: plainKF) }
                    } catch {}
                }
                if mode0 == "offqueue" { encQ.async(execute: doEncode) } else { doEncode() }
            }
            // SELF-SCROLL: post scroll-wheel events to the target pid (no focus steal, postToPid) every
            // ~8ms, reversing direction every ~0.5s — a reproducible continuous scroll + reversals so the
            // captured content changes every frame. Removes any dependency on external input timing.
            final class ScrollFlag: @unchecked Sendable { var run = true }
            let sflag = ScrollFlag()
            if let spid = selfScrollPid {
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                let env = ProcessInfo.processInfo.environment
                let scrollLines = Int32(env["PROBE_SCROLL_LINES"].flatMap { Int($0) } ?? 3) // ± lines/tick
                let scrollMs = env["PROBE_SCROLL_MS"].flatMap { Double($0) } ?? 8.0 // tick interval (ms)
                let reverseTicks = env["PROBE_SCROLL_REVERSE"].flatMap { Int($0) } ?? 64 // reverse every N ticks
                // SMOOTH mode (PROBE_SMOOTH=<pixels/tick>): mimic the PRODUCTION trackpad injection —
                // pixel units + IsContinuous + a Began→Changed scroll PHASE, posted via the HID tap to
                // the FOCUSED window (window must be frontmost). This is what makes Chromium/Electron run
                // its native smooth-scroll, vs legacy line-wheel postToPid (per-notch stepping).
                let smoothPx = env["PROBE_SMOOTH"].flatMap { Int32($0) }
                // RESAMPLE mode (PROBE_RESAMPLE=1): feed a LOW-rate input (every PROBE_INPUT_DIV ticks)
                // through the REAL `ScrollResampler` and post its drained output EVERY tick — exactly
                // what the host's InputInjector pump does. Proves end-to-end that low-rate input → ~tick
                // -rate output → 60fps Chromium (vs the same low-rate posted DIRECTLY = ~35fps).
                let probeResample = env["PROBE_RESAMPLE"] != nil
                let inputDiv = max(1, env["PROBE_INPUT_DIV"].flatMap { Int($0) } ?? 2)
                eprint(
                    "self-scroll → pid \(spid) @\(Int(center.x)),\(Int(center.y)) (\(probeResample ? "RESAMPLE inputDiv=\(inputDiv) " : "")\(smoothPx != nil ? "SMOOTH pixel+phase \(smoothPx!)px" : "wheel \(scrollLines)line")/\(Int(scrollMs))ms, reverse \(reverseTicks))",
                )
                func postPixelScroll(dy: Int32, scrollPhase: Int64, momentumPhase: Int64) {
                    guard let ev = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0,
                    ) else { return }
                    ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    if scrollPhase != 0 { ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase) }
                    if momentumPhase !=
                        0 { ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase) }
                    ev.location = center
                    ev.post(tap: .cghidEventTap)
                }
                Thread.detachNewThread {
                    var i = 0
                    var started = false
                    var resampler = ScrollResampler()
                    while sflag.run {
                        if probeResample, let px = smoothPx {
                            let dir: Int32 = (i / reverseTicks) % 2 == 0 ? -px : px
                            if i % inputDiv == 0 {
                                let markers = resampler.ingest(
                                    dx: 0, dy: Double(dir * Int32(inputDiv)),
                                    scrollPhase: started ? 2 : 1, momentumPhase: 0, continuous: true,
                                )
                                for m in markers {
                                    postPixelScroll(
                                        dy: Int32(m.dy),
                                        scrollPhase: Int64(m.scrollPhase),
                                        momentumPhase: Int64(m.momentumPhase),
                                    )
                                }
                                started = true
                            }
                            if let s = resampler.drain() {
                                postPixelScroll(
                                    dy: Int32(s.dy),
                                    scrollPhase: Int64(s.scrollPhase),
                                    momentumPhase: Int64(s.momentumPhase),
                                )
                            }
                        } else if let px = smoothPx {
                            let dir: Int32 = (i / reverseTicks) % 2 == 0 ? -px : px
                            postPixelScroll(dy: dir, scrollPhase: started ? 2 : 1, momentumPhase: 0)
                            started = true
                        } else if let ev = CGEvent(
                            scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: (i / reverseTicks) % 2 == 0 ? -scrollLines : scrollLines,
                            wheel2: 0, wheel3: 0,
                        ) {
                            ev.location = center // hit-test over the window's editor area
                            ev.postToPid(spid)
                        }
                        i += 1
                        Thread.sleep(forTimeInterval: scrollMs / 1000.0)
                    }
                }
            }
            nonisolated(unsafe) let w0 = window
            try await capturer.start(window: w0, pixelWidth: pixelW, pixelHeight: pixelH)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            sflag.run = false
            await capturer.stop()
            let ts = cad.lock.withLock { cad.ts }
            guard ts.count > 2 else { eprint("CADENCE: only \(ts.count) frames — scroll the window during the run")
                exit(1)
            }
            var iv: [Double] = []
            iv.reserveCapacity(ts.count - 1)
            for i in 1..<ts.count { iv.append((ts[i] - ts[i - 1]) * 1000.0) } // ms
            let sorted = iv.sorted()
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            let span = ts.last! - ts.first!
            let effFps = Double(ts.count - 1) / span
            let stalls33 = iv.count(where: { $0 > 33 })
            let stalls50 = iv.count(where: { $0 > 50 })
            let stalls100 = iv.count(where: { $0 > 100 })
            let maxIv = sorted.last ?? 0
            let mode = ProcessInfo.processInfo.environment["SLOPDESK_DISPLAY_CAPTURE"] ?? "<unset>"
            print("=== CADENCE mode=\(mode) scale=\(scale) win=\(pixelW)x\(pixelH) ===")
            print(String(
                format: "frames=%d span=%.1fs effFps=%.1f  p50=%.1f p95=%.1f p99=%.1f max=%.1f ms",
                ts.count, span, effFps, pct(0.50), pct(0.95), pct(0.99), maxIv,
            ))
            print("stalls: >33ms=\(stalls33)  >50ms=\(stalls50)  >100ms=\(stalls100)")
            let (kfN, kfMax) = estat.lock.withLock { (estat.kfCount, estat.kfMaxBytes) }
            if kfN > 0 { print("keyframes=\(kfN) maxBytes=\(kfMax) (\(kfMax / 1024)KB)") }
            vdCleanup()
            exit(0)
        }

        // Snapshot the MainActor-isolated top-level args into Sendable locals for the frame handler.
        let dir = outDir, hz = maxHz
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        final class SaveState: @unchecked Sendable { let lock = NSLock()
            var lastSave = 0.0
            var saved = 0
        }
        let state = SaveState()
        let t0 = CACurrentMediaTime()
        let capturer = WindowCapturer(fps: 60, captureScale: scale) { pixelBuffer, _, _, _, _, _, _ in
            let now = CACurrentMediaTime()
            state.lock.lock()
            let due = (now - state.lastSave) >= (1.0 / hz)
            if due { state.lastSave = now
                state.saved += 1
            }
            let n = state.saved
            state.lock.unlock()
            guard due else { return }
            let img = CIImage(cvPixelBuffer: pixelBuffer)
            let ms = Int((now - t0) * 1000)
            let url = URL(fileURLWithPath: "\(dir)/frame-\(String(format: "%03d", n))-\(ms)ms.png")
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
                preconditionFailure("CGColorSpace(name: .sRGB) is a built-in color space and is never nil")
            }
            do {
                try ciContext.writePNGRepresentation(
                    of: img,
                    to: url,
                    format: .RGBA8,
                    colorSpace: srgb,
                )
            } catch { FileHandle.standardError.write(Data("png write failed: \(error)\n".utf8)) }
        }
        nonisolated(unsafe) let w = window // single-owner hand-off, same as the session's start path
        try await capturer.start(window: w, pixelWidth: pixelW, pixelHeight: pixelH)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await capturer.stop()
        let total = state.lock.withLock { state.saved }
        eprint("done: \(total) frames dumped to \(outDir)")
        exit(0)
    } catch {
        eprint("probe failed: \(error)")
        exit(1)
    }
}

_ = task
RunLoop.main.run()
#else
fatalError("slopdesk-capture-probe is macOS-only")
#endif
