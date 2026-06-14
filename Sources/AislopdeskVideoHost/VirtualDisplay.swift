#if os(macOS)
import CoreGraphics
import Foundation

// @preconcurrency: the private CG classes (clang module) predate Swift concurrency and are not
// `Sendable`; we cross them into a background queue ONLY inside ``applyWithTimeout`` via an explicit
// unchecked-Sendable box, so downgrade the module-level Sendable notes to warnings.
@preconcurrency import CAislopdeskVirtualDisplay
import OSLog

/// Owns ONE HiDPI virtual display for the daemon lifetime (feature #1, 2026-06-08). The remoted
/// window is moved onto it (see ``WindowPlacement``) so it renders at real Retina 2× backing and is
/// captured sharp, instead of the soft point-resolution-upscale path on a 1× host display.
///
/// ⚠️ CONTRACT (from the CGVirtualDisplay research):
/// - `CGVirtualDisplay(descriptor:)` must run on the MAIN THREAD (synchronous WindowServer Mach IPC)
///   → this type is `@MainActor`.
/// - The process must keep a live run loop (aislopdesk-videohostd switches `dispatchMain()` →
///   `NSApplication.run()` when the VD is enabled) or WindowServer tears the display down.
/// - The `CGVirtualDisplay` object must be RETAINED for its lifetime — ARC dealloc unregisters it.
///   Hence the strong `vd` ref here, held by a daemon-lifetime owner; `destroy()` releases it.
/// - `applySettings:` BLOCKS on WindowServer IPC → run off-main with a timeout.
/// - EVERY failure returns nil → caller falls back to 1× capture. NEVER crashes.
///
/// HW-GATED: needs a window server + a run loop; not exercised in tests (the pure pixel/point math
/// is in ``VirtualDisplayGeometry`` / ``VirtualDisplayPlanner``, which ARE unit-tested).
@preconcurrency
@MainActor
public final class VirtualDisplay {
    private let log = Logger(subsystem: "aislopdesk.video.host", category: "VirtualDisplay")
    /// Strong ref = the display stays registered with WindowServer (ARC dealloc unregisters it).
    private var vd: CGVirtualDisplay?
    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var pointSize: CGSize = .zero
    public private(set) var scale: Int = 1

    /// Fired (on the main actor) when WindowServer TERMINATES the display out from under us
    /// (display reconfig, GPU reset, fast-user-switch, sleep/wake). By the time it runs `displayID`
    /// is already cleared, so the daemon can restore parked windows + fall new mints back to 1×.
    public var onTerminated: (@Sendable () -> Void)?

    public init() {}

    /// Create a HiDPI virtual display for `geometry`, advertising refresh modes that cover `fps`.
    /// Returns its `CGDirectDisplayID` on success, `nil` on ANY failure (private API absent on this
    /// OS, WindowServer refusal, applySettings timeout/failure, displayID stayed 0, pixel-limit
    /// exceeded) — the caller then falls back to 1× real-display capture.
    public func create(
        _ geometry: VirtualDisplayGeometry,
        name: String = "Aislopdesk Remote",
        fps: Int = 60,
    ) async -> CGDirectDisplayID? {
        guard !geometry.exceedsPixelLimit else {
            log
                .error(
                    "VD \(geometry.pixelWidth)×\(geometry.pixelHeight)px exceeds chip limit \(geometry.maxHorizontalPixels) — fallback to 1×",
                )
            return nil
        }

        // Snapshot the CURRENT (physical) displays BEFORE the VD exists, so the reconfigure can pin
        // every one of them at its current origin (stopping WindowServer from reflowing the user's
        // real multi-monitor layout) and place the VD past the rightmost edge where it can never
        // overlap a real display. On a single-display host this reduces to today's behaviour: pin
        // main at (0,0), VD at (mainWidth, 0).
        let physicalDisplays = Self.onlineDisplayBounds()
        let vdOrigin = VirtualDisplayPlanner.originToRight(of: physicalDisplays.map(\.bounds))

        let desc = CGVirtualDisplayDescriptor()
        desc.vendorID = 0xEEEE // arbitrary NON-ZERO (a zero vendorID → initWithDescriptor: nil)
        desc.productID = 0x0001
        // serial: GUARDED KVC. The property name diverges across macOS versions (`serialNum` vs
        // `serialNumber`); setting via a typed accessor that the runtime class lacks would crash with
        // an unrecognized selector. It is cosmetic, so set whichever the class actually exposes, else skip.
        Self.setSerialIfPossible(desc, 0x0001)
        desc.name = name
        desc.maxPixelsWide = UInt32(geometry.pixelWidth)
        desc.maxPixelsHigh = UInt32(geometry.pixelHeight)
        desc.sizeInMillimeters = geometry.sizeInMillimeters()
        // EXACT sRGB IEC 61966-2.1 D65 primaries — a custom profile can deadlock colorsyncd against
        // WindowServer's render threads; the cached sRGB profile avoids that.
        desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        desc.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        desc.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        desc.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        desc.queue = DispatchQueue(label: "aislopdesk.video.vd.termination", qos: .userInitiated)
        desc.terminationHandler = { [weak self] _, reason in
            // Delivered on desc.queue (background). Log, then hop to the main actor to clear our
            // state + notify the daemon (so it restores parked windows and stops targeting a dead id).
            Logger(subsystem: "aislopdesk.video.host", category: "VirtualDisplay")
                .error("virtual display terminated by WindowServer: \(String(describing: reason))")
            Task { @MainActor in self?.handleTermination() }
        }

        guard let vd = CGVirtualDisplay(descriptor: desc) else {
            log
                .error(
                    "CGVirtualDisplay(descriptor:) → nil (private API absent / WindowServer refused) — fallback to 1×",
                )
            return nil
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = (geometry.scale >= 2) ? 1 : 0 // 1 = 2× Retina backing
        settings.modes = VirtualDisplayPlanner.refreshRates(fps: fps).map {
            CGVirtualDisplayMode(width: UInt(geometry.pointWidth), height: UInt(geometry.pointHeight), refreshRate: $0)
        }

        // applySettings BLOCKS on WindowServer IPC — run off-main with a 10s timeout. The result
        // snapshot reads `displayID` ON the apply queue, AFTER apply returned, so the main actor
        // never touches the live (possibly still-mutating, on the timeout path) CG object.
        let result = await Self.applyWithTimeout(vd, settings, seconds: 10)
        guard result.ok, result.displayID != 0 else {
            log.error("VD applySettings failed or displayID stayed 0 (pixel-limit/IPC) — fallback to 1×")
            return nil
        }
        let id = result.displayID

        // Wait (≤1s) for WindowServer to register the new display in the online list.
        var appeared = false
        for _ in 0..<20 {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &n)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &ids, &n)
            if ids.contains(id) { appeared = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !appeared {
            log.error("VD id=\(id) did not appear in the online list within 1s — reconfigure may be a no-op")
        }

        // Force EXTEND (macOS sometimes auto-mirrors a new display) AND keep the user's real
        // arrangement: pin every physical display at its captured origin and place the VD past the
        // rightmost edge — a single atomic transaction so the overlap resolver can't reflow anything.
        // `.forAppOnly` scopes the geometry change to THIS process, so it auto-reverts when the daemon
        // exits OR crashes (matching the VD's ARC lifetime), without a manual restore. A 200ms settle
        // first (WindowServer can be mid-reconfigure right after applySettings).
        try? await Task.sleep(nanoseconds: 200_000_000)
        applyExtendConfiguration(vdID: id, vdOrigin: vdOrigin, physicalDisplays: physicalDisplays)

        self.vd = vd
        displayID = id
        pointSize = CGSize(width: geometry.pointWidth, height: geometry.pointHeight)
        scale = geometry.scale
        log
            .notice(
                "virtual display ONLINE: id=\(id) \(geometry.pointWidth)×\(geometry.pointHeight)pt @\(geometry.scale)× (\(geometry.pixelWidth)×\(geometry.pixelHeight)px) origin (\(Int(vdOrigin.x)),\(Int(vdOrigin.y)))",
            )
        return id
    }

    /// Release the display (ARC dealloc → WindowServer unregisters). Call on shutdown, AFTER all
    /// SCStreams targeting it have stopped (the FB17797423 retain rule) and AFTER parked windows have
    /// been restored (the original display must still exist).
    public func destroy() {
        if vd != nil {
            let destroyedID = displayID
            log.notice("virtual display destroyed (id=\(destroyedID))")
        }
        vd = nil
        displayID = 0
    }

    /// WindowServer terminated the display. Clear our state so nothing keeps targeting the dead id,
    /// then notify the daemon. Idempotent (a later `destroy()` is a no-op).
    private func handleTermination() {
        guard vd != nil || displayID != 0 else { return }
        vd = nil
        displayID = 0
        onTerminated?()
    }

    /// The online displays' `(id, global-bounds)` — the physical set when called before the VD exists.
    private static func onlineDisplayBounds() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { (id: $0, bounds: CGDisplayBounds($0)) }
    }

    /// The extend + origin-pin transaction. Stops any auto-mirror on the VD, pins every captured
    /// physical display at its original origin, and places the VD at `vdOrigin`, committing
    /// `.forAppOnly`. Each CGError is checked + logged; on a complete-failure the half-built
    /// transaction is verified rather than reported as success.
    private func applyExtendConfiguration(
        vdID id: CGDirectDisplayID,
        vdOrigin: CGPoint,
        physicalDisplays: [(id: CGDirectDisplayID, bounds: CGRect)],
    ) {
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success, let cfg else {
            log
                .error(
                    "VD extend: CGBeginDisplayConfiguration failed (\(begin.rawValue)) — leaving WindowServer default",
                )
            return
        }
        // null master = stop mirroring = extend.
        let mirror = CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        if mirror != .success { log.error("VD extend: stop-mirror failed (\(mirror.rawValue))") }
        for d in physicalDisplays { // keep each real display exactly where it was
            let r = CGConfigureDisplayOrigin(cfg, d.id, Int32(d.bounds.minX.rounded()), Int32(d.bounds.minY.rounded()))
            if r != .success { log.error("VD extend: pin display \(d.id) failed (\(r.rawValue))") }
        }
        let vdPin = CGConfigureDisplayOrigin(cfg, id, Int32(vdOrigin.x.rounded()), Int32(vdOrigin.y.rounded()))
        if vdPin != .success { log.error("VD extend: pin VD origin failed (\(vdPin.rawValue))") }
        let complete = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        if complete != .success {
            log.error("VD extend: CGCompleteDisplayConfiguration failed (\(complete.rawValue)) — cancelling")
            CGCancelDisplayConfiguration(cfg)
            return
        }
        // Post-condition: a still-mirrored VD would capture the physical display's content, not an
        // independent desktop — surface it (the caller can't otherwise tell).
        if CGDisplayIsInMirrorSet(id) != 0 {
            log
                .error(
                    "VD extend: display \(id) is STILL mirrored after reconfigure — capture may show the wrong content",
                )
        }
    }

    /// Sets the descriptor serial via the property name the runtime class actually exposes
    /// (`serialNum` first, then `serialNumber`); skips if neither responds (cosmetic field).
    private static func setSerialIfPossible(_ desc: CGVirtualDisplayDescriptor, _ value: UInt32) {
        for key in ["serialNum", "serialNumber"] {
            let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            if desc.responds(to: setter) {
                // `value` (UInt32) bridges to `NSNumber` across the KVC `setValue(_:forKey:)` boundary.
                desc.setValue(value, forKey: key)
                return
            }
        }
    }

    /// The off-main `applySettings:` outcome — `displayID` is read ON the apply queue (after apply
    /// returns) so the main actor never reads the live CG object on the timeout path.
    private struct ApplyResult {
        let ok: Bool
        let displayID: CGDirectDisplayID
    }

    /// Runs the blocking `applySettings:` on a background queue, resolving `ok=false` if it does not
    /// return within `seconds` (a wedged WindowServer must not hang daemon bring-up). The once-guard
    /// ensures the continuation resumes exactly once. On the timeout (abandoned) path the
    /// CGVirtualDisplay is released back ON THE MAIN THREAD (its dealloc unregisters via synchronous
    /// Mach IPC, which must be main) once `apply` finally returns.
    private static func applyWithTimeout(
        _ vd: CGVirtualDisplay,
        _ settings: CGVirtualDisplaySettings,
        seconds: Double,
    ) async -> ApplyResult {
        // The CG classes aren't Sendable; ferry them into the background queue via an explicit
        // unchecked box. `displayID` is read inside this closure, after `apply`, so its value crosses
        // back as a plain Sendable Int — the main actor never touches the live object on timeout.
        let box = ApplyBox(vd: vd, settings: settings)
        return await withCheckedContinuation { (cont: CheckedContinuation<ApplyResult, Never>) in
            let once = OnceFlag()
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = box.vd.apply(box.settings) // imported Swift name for `-applySettings:`
                let id = ok ? box.vd.displayID : 0
                if once.fire() {
                    cont.resume(returning: ApplyResult(ok: ok, displayID: id))
                } else {
                    // Timeout already won: we are the abandoned apply. Hand the CG object to the main
                    // thread for release so its WindowServer-unregistering dealloc runs on main.
                    let abandoned = box.vd
                    DispatchQueue.main.async { _ = abandoned }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.fire() { cont.resume(returning: ApplyResult(ok: false, displayID: 0)) }
            }
        }
    }

    /// Unchecked-Sendable ferry for the non-Sendable CG objects into the background `apply` queue.
    private struct ApplyBox: @unchecked Sendable {
        let vd: CGVirtualDisplay
        let settings: CGVirtualDisplaySettings
    }
}

/// One-shot guard so two racing closures resume a continuation exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
#endif
