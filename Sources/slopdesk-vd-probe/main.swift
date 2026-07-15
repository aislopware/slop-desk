// slopdesk-vd-probe — DE-RISK the "beat-free 60fps via a 120Hz virtual-display capture source" plan.
//
// A physical 60Hz panel can never deliver >60 distinct frames/s (WindowServer commits at vsync), so a
// 60fps encode captures 1:1 and beats. A HEADLESS virtual display whose mode we control can advertise
// 120Hz — content rendered on it commits at up to 120Hz, SCStream captures 120, encode consumes 60 =
// 2:1 oversample = no beat. This probe answers the make-or-break question: does WindowServer actually
// GRANT a 120Hz virtual-display mode, or does it clamp the VD to 60?
//
// It creates a VD advertising modes covering `--fps` (default 120 ⇒ refreshRates() yields 120/60/30),
// prints the mode WindowServer reports for it (`CGDisplayCopyDisplayMode`) plus every mode it exposes,
// then destroys it. Run from a WindowServer-attached (Aqua) session — a pure SSH context has no
// WindowServer connection and `create` returns nil.
//
// Usage: slopdesk-vd-probe [--fps 120] [--hold-seconds 2]

#if os(macOS)
import CoreGraphics
import Foundation
import SlopDeskVideoHost

var fps = 120
var holdSeconds: UInt64 = 2
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--fps": fps = it.next().flatMap { Int($0) } ?? fps
    case "--hold-seconds": holdSeconds = it.next().flatMap { UInt64($0) } ?? holdSeconds
    default: break
    }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@MainActor
func run() async -> Int32 {
    eprint("vd-probe: advertising VD modes for fps=\(fps) → \(VirtualDisplayPlanner.refreshRates(fps: fps))")
    let vd = VirtualDisplay()
    // 1920×1080 points at 1× (matches the current headless dongle) — the refresh grant is what matters.
    let geo = VirtualDisplayGeometry(pointWidth: 1920, pointHeight: 1080, scale: 1)
    guard let id = await vd.create(geo, name: "SlopDesk 120Hz Probe", fps: fps) else {
        eprint("vd-probe: FAIL — create returned nil (no WindowServer connection, or the OS refused the VD)")
        return 1
    }
    eprint("vd-probe: VD ONLINE id=\(id)")
    if let mode = CGDisplayCopyDisplayMode(id) {
        eprint("vd-probe: CURRENT mode = \(mode.pixelWidth)×\(mode.pixelHeight) @ \(mode.refreshRate)Hz")
        if mode.refreshRate >= 100 {
            eprint("vd-probe: ✅ WindowServer GRANTED a >100Hz VD mode — the 120Hz-oversample plan is VIABLE")
        } else {
            eprint("vd-probe: ⚠️ current mode is \(mode.refreshRate)Hz — check the advertised list below")
        }
    }
    if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
        let list = modes.map { "\($0.width)×\($0.height)@\(Int($0.refreshRate))" }.joined(separator: ", ")
        eprint("vd-probe: ALL exposed modes = [\(list)]")
        let maxHz = modes.map(\.refreshRate).max() ?? 0
        let verdict = maxHz >= 100 ? "✅ 120Hz reachable" : "❌ clamped ≤ \(Int(maxHz))Hz"
        eprint("vd-probe: max advertised refresh = \(maxHz)Hz \(verdict)")
    }
    try? await Task.sleep(nanoseconds: holdSeconds * 1_000_000_000)
    vd.destroy()
    eprint("vd-probe: VD destroyed — done")
    return 0
}

// The main actor's executor IS the main thread — so DO NOT block it (a semaphore wait would deadlock
// `@MainActor func run`). `dispatchMain()` pumps the main queue so the Task runs; `exit` ends it.
Task {
    let code = await run()
    exit(code)
}

dispatchMain()
#else
fatalError("slopdesk-vd-probe is macOS-only")
#endif
