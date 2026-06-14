// aislopdesk-capture-probe — host-side frame dumper for geometric capture artifacts.
//
// Drives the REAL `WindowCapturer` (production filter/config path, including the
// `AISLOPDESK_DISPLAY_CAPTURE` mode seam) against one window and writes each DELIVERED frame
// as a PNG (throttled). Built for the Chrome-tooltip crop-shift hunt: hover a link while this
// runs under each capture mode, then pixel-compare the dumps — a client-side screenshot can't
// measure a 1px capture shift through pane scaling/HEVC.
//
// Usage: aislopdesk-capture-probe --title <substring> [--seconds 20] [--out DIR] [--max-hz 4]
//        aislopdesk-capture-probe --list
// Mode comes from the production env seam, e.g.:
//        AISLOPDESK_DISPLAY_CAPTURE=window  .build/debug/aislopdesk-capture-probe --title Chrome
//        AISLOPDESK_DISPLAY_CAPTURE=include .build/debug/aislopdesk-capture-probe --title Chrome
// Runtime needs a GUI session + Screen Recording TCC. Exit 1 on setup failure.

#if os(macOS)
import AislopdeskVideoHost
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

_ = NSApplication.shared // CGS connection — SCStream trips CGS_REQUIRE_INIT without it

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var titleQuery: String?
var windowIDArg: UInt32?
var seconds = 20.0
var outDir = "/tmp/capture-probe"
var maxHz = 4.0
var listOnly = false
var listAll = false
var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = args.next() {
    switch a {
    case "--title": titleQuery = args.next()
    case "--window-id": windowIDArg = args.next().flatMap { UInt32($0) }
    case "--seconds": seconds = args.next().flatMap(Double.init) ?? 20.0
    case "--out": outDir = args.next() ?? outDir
    case "--max-hz": maxHz = args.next().flatMap(Double.init) ?? 4.0
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
        let window: SCWindow
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
        let scale = 1.0 // point-resolution capture: pixel offsets in dumps == point offsets
        let pixelW = Int(window.frame.width * scale), pixelH = Int(window.frame.height * scale)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        eprint(
            "probing id=\(window.windowID) '\(window.title ?? "")' \(pixelW)x\(pixelH)px mode-env=\(ProcessInfo.processInfo.environment["AISLOPDESK_DISPLAY_CAPTURE"] ?? "<unset>") → \(outDir)",
        )

        // Snapshot the MainActor-isolated top-level args into Sendable locals for the frame handler.
        let dir = outDir, hz = maxHz
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        final class SaveState: @unchecked Sendable { let lock = NSLock()
            var lastSave = 0.0
            var saved = 0
        }
        let state = SaveState()
        let t0 = CACurrentMediaTime()
        let capturer = WindowCapturer(fps: 60, captureScale: scale) { pixelBuffer, _, _, _, _, _ in
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
fatalError("aislopdesk-capture-probe is macOS-only")
#endif
