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
// Q1 (does WindowServer GRANT a 120Hz VD mode) is answered by the mode prints above. Q2 — the real
// make-or-break — is whether WindowServer actually CLOCKS the VD's compositor at 120Hz or idles/caps
// it at 60. A granted 120Hz mode that only ticks 60×/s would defeat the whole oversample plan. We
// answer Q2 WITHOUT ScreenCaptureKit (no TCC needed) by binding a `CVDisplayLink` to the VD's
// displayID and COUNTING its vsync callbacks over `--measure-seconds`: the display link IS the
// display's timing generator, so its observed tick rate is the VD's true commit clock. ~120 ⇒ the
// 2:1 capture-oversample (kill the 60fps beat) is physically reachable; ~60 ⇒ it is not.
//
// Usage: slopdesk-vd-probe [--fps 120] [--hold-seconds 2] [--measure-seconds 3]

#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import SlopDeskVideoHost

var fps = 120
var holdSeconds: UInt64 = 2
var measureSeconds = 3.0
var makeMain = false
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--fps": fps = it.next().flatMap { Int($0) } ?? fps
    case "--hold-seconds": holdSeconds = it.next().flatMap { UInt64($0) } ?? holdSeconds
    case "--measure-seconds": measureSeconds = it.next().flatMap(Double.init) ?? measureSeconds
    case "--make-main": makeMain = true
    default: break
    }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// The online displays as `(id, global-bounds)`, main-first for readability.
func snapshotArrangement() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
    return ids.prefix(Int(n)).map { (id: $0, bounds: CGDisplayBounds($0)) }
}

func describeArrangement(_ a: [(id: CGDirectDisplayID, bounds: CGRect)]) -> String {
    a.map { "id=\($0.id)@(\(Int($0.bounds.minX)),\(Int($0.bounds.minY)))" }.joined(separator: " ")
}

/// Q3 (the make-or-break for build (b)): can a HEADLESS VD be PROMOTED to the main display, so the
/// existing `mintDisplaySession` — which captures `CGMainDisplayID()` — captures the VD's 120Hz surface
/// with NO other code change? Pins the VD at the global origin (0,0) and every physical display to its
/// right, `.forSession` (the scope that relocates the global menubar/desktop, not just this process's
/// coordinate view). Reads back `CGMainDisplayID()`, holds, then RESTORES the original arrangement so
/// the host is never left reconfigured. `.forSession` (not `.permanently`) also self-reverts at logout,
/// a second safety net.
func probeMakeMain(vdID: CGDirectDisplayID, vdWidthPx: Int) {
    let before = snapshotArrangement()
    let beforeMain = CGMainDisplayID()
    eprint("make-main: BEFORE main=\(beforeMain) [\(describeArrangement(before))]")

    func reconfigure(_ place: (CGDisplayConfigRef) -> Void) -> CGError {
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success, let cfg else { return begin }
        place(cfg)
        return CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    // 1) VD → (0,0); every physical display stacked to the right of the VD.
    let apply = reconfigure { cfg in
        CGConfigureDisplayOrigin(cfg, vdID, 0, 0)
        var x = Int32(vdWidthPx)
        for d in before where d.id != vdID {
            CGConfigureDisplayOrigin(cfg, d.id, x, 0)
            x += Int32(d.bounds.width.rounded())
        }
    }
    let afterMain = CGMainDisplayID()
    let after = snapshotArrangement()
    eprint("make-main: APPLY forSession=\(apply.rawValue) → main=\(afterMain) [\(describeArrangement(after))]")
    if afterMain == vdID {
        eprint("make-main: ✅ Q3 PASS — VD is now CGMainDisplayID; mintDisplaySession would capture it unchanged")
    } else {
        eprint("make-main: ❌ Q3 — VD did NOT become main (main=\(afterMain)); a different promotion path is needed")
    }
    Thread.sleep(forTimeInterval: 1.5)

    // 2) RESTORE every display to its captured origin — never leave the host reconfigured.
    let restore = reconfigure { cfg in
        for d in before { CGConfigureDisplayOrigin(
            cfg,
            d.id,
            Int32(d.bounds.minX.rounded()),
            Int32(d.bounds.minY.rounded()),
        ) }
    }
    let restoredMain = CGMainDisplayID()
    eprint("make-main: RESTORE forSession=\(restore.rawValue) → main=\(restoredMain) (was \(beforeMain))")
    if restoredMain != beforeMain {
        eprint("make-main: ⚠️ main did not return to \(beforeMain) — logout/reboot reverts .forSession as a fallback")
    }
}

/// Thread-safe tick counter — the CVDisplayLink handler runs on its own real-time thread, so the
/// main-thread reader needs a lock to see a coherent count.
final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int { lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Q2: bind a CVDisplayLink to the VD and count its vsync ticks over `seconds`. The display link
/// fires once per composite vsync of the target display, independent of ScreenCaptureKit / TCC and
/// independent of whether any content is on the VD — it measures the compositor CLOCK. A VD that
/// WindowServer clocks at 120Hz ticks ~120×/s; one it idles/caps at 60 ticks ~60×/s.
func measureCompositorClock(displayID id: CGDirectDisplayID, seconds: Double) {
    var link: CVDisplayLink?
    let cr = CVDisplayLinkCreateWithCGDisplay(id, &link)
    guard cr == kCVReturnSuccess, let link else {
        eprint("vd-probe: CVDisplayLink create failed (\(cr)) — cannot measure the VD's compositor clock")
        return
    }
    let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    if nominal.timeValue != 0 {
        let hz = Double(nominal.timeScale) / Double(nominal.timeValue)
        eprint("vd-probe: CVDisplayLink NOMINAL refresh = \(String(format: "%.1f", hz))Hz (what the mode advertises)")
    }
    let counter = TickCounter()
    CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
        counter.bump()
        return kCVReturnSuccess
    }
    CVDisplayLinkStart(link)
    // The callback runs on the display link's OWN thread, so this main-thread sleep does not starve
    // it — the count keeps advancing during the wait.
    Thread.sleep(forTimeInterval: seconds)
    CVDisplayLinkStop(link)
    let ticks = counter.count
    let observedHz = Double(ticks) / seconds
    let period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link) // seconds/frame, driver-measured
    let driverHz = period > 0 ? 1.0 / period : 0
    eprint(
        "vd-probe: CVDisplayLink TICKED \(ticks)× in \(String(format: "%.1f", seconds))s = "
            +
            "\(String(format: "%.1f", observedHz))Hz observed (driver-reported \(String(format: "%.1f", driverHz))Hz)",
    )
    if observedHz >= 100 {
        eprint("vd-probe: ✅ Q2 PASS — VD compositor CLOCKS at ~120Hz; SCStream can oversample → beat-kill VIABLE")
    } else {
        eprint(
            "vd-probe: ❌ Q2 FAIL — VD clocks at ~\(Int(observedHz.rounded()))Hz; it does NOT provide a >60Hz "
                + "commit clock, so a 120Hz VD cannot kill the beat",
        )
    }
}

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
    // Q2 — the make-or-break: does WindowServer actually clock this VD at 120Hz?
    if measureSeconds > 0 { measureCompositorClock(displayID: id, seconds: measureSeconds) }
    // Q3 — can the VD be promoted to main so the desktop mint captures it unchanged? (auto-reverts)
    if makeMain { probeMakeMain(vdID: id, vdWidthPx: 1920) }
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
