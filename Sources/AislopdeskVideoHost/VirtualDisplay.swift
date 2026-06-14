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
/// is in ``VirtualDisplayGeometry``, which IS unit-tested).
@preconcurrency
@MainActor
public final class VirtualDisplay {
    private let log = Logger(subsystem: "aislopdesk.video.host", category: "VirtualDisplay")
    /// Strong ref = the display stays registered with WindowServer (ARC dealloc unregisters it).
    private var vd: CGVirtualDisplay?
    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var pointSize: CGSize = .zero
    public private(set) var scale: Int = 1

    public init() {}

    /// Create a HiDPI virtual display for `geometry`. Returns its `CGDirectDisplayID` on success,
    /// `nil` on ANY failure (private API absent on this OS, WindowServer refusal, applySettings
    /// timeout/failure, displayID stayed 0, pixel-limit exceeded) — the caller then falls back to
    /// 1× real-display capture.
    public func create(
        _ geometry: VirtualDisplayGeometry,
        name: String = "Aislopdesk Remote",
    ) async -> CGDirectDisplayID? {
        guard !geometry.exceedsPixelLimit else {
            log
                .error(
                    "VD \(geometry.pixelWidth)×\(geometry.pixelHeight)px exceeds chip limit \(geometry.maxHorizontalPixels) — fallback to 1×",
                )
            return nil
        }

        // Capture the CURRENT (physical) main display BEFORE the VD exists, so we can keep it as
        // main afterwards — macOS otherwise promotes a fresh larger display to main, yanking the
        // menu bar/Dock onto the (physically-invisible) VD and disrupting work on the real screen.
        let physicalMain = CGMainDisplayID()
        let physicalBounds = CGDisplayBounds(physicalMain)

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
        desc.queue = DispatchQueue(label: "aislopdesk.video.vd.termination")
        desc.terminationHandler = { _, reason in
            // Delivered on desc.queue. Just log — the daemon drops its strong ref via destroy() on shutdown.
            Logger(subsystem: "aislopdesk.video.host", category: "VirtualDisplay")
                .error("virtual display terminated by WindowServer: \(String(describing: reason))")
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
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(geometry.pointWidth), height: UInt(geometry.pointHeight), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(geometry.pointWidth), height: UInt(geometry.pointHeight), refreshRate: 30),
        ]

        // applySettings BLOCKS on WindowServer IPC — run off-main with a 10s timeout.
        let ok = await Self.applyWithTimeout(vd, settings, seconds: 10)
        guard ok, vd.displayID != 0 else {
            log.error("VD applySettings failed or displayID stayed 0 (pixel-limit/IPC) — fallback to 1×")
            return nil
        }
        let id = vd.displayID

        // Wait (≤1s) for WindowServer to register the new display in the online list.
        for _ in 0..<20 {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &n)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &ids, &n)
            if ids.contains(id) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Force EXTEND mode (macOS sometimes auto-mirrors a new display) AND keep the physical
        // display as MAIN with the VD placed to its right — a single config transaction. A display
        // is "main" iff its origin is (0,0); pinning the physical display at (0,0) and the VD at
        // (physicalWidth, 0) stops macOS from promoting the larger VD to main (which would move the
        // menu bar/Dock onto the physically-invisible VD). A 200ms settle first (WindowServer can be
        // mid-reconfigure right after applySettings).
        try? await Task.sleep(nanoseconds: 200_000_000)
        var cfg: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&cfg) == .success, let cfg {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay) // null master = stop mirroring = extend
            CGConfigureDisplayOrigin(cfg, physicalMain, 0, 0) // physical stays at origin → stays main
            CGConfigureDisplayOrigin(
                cfg,
                id,
                Int32(physicalBounds.width.rounded()),
                0,
            ) // VD to the right of the physical display
            CGCompleteDisplayConfiguration(cfg, .forSession)
        }

        self.vd = vd
        displayID = id
        pointSize = CGSize(width: geometry.pointWidth, height: geometry.pointHeight)
        scale = geometry.scale
        log
            .notice(
                "virtual display ONLINE: id=\(id) \(geometry.pointWidth)×\(geometry.pointHeight)pt @\(geometry.scale)× (\(geometry.pixelWidth)×\(geometry.pixelHeight)px)",
            )
        return id
    }

    /// Release the display (ARC dealloc → WindowServer unregisters). Call on shutdown, AFTER all
    /// SCStreams targeting it have stopped (the FB17797423 retain rule).
    public func destroy() {
        if vd != nil {
            let destroyedID = displayID
            log.notice("virtual display destroyed (id=\(destroyedID))")
        }
        vd = nil
        displayID = 0
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

    /// Runs the blocking `applySettings:` on a background queue, resolving `false` if it does not
    /// return within `seconds` (a wedged WindowServer must not hang daemon bring-up). The once-guard
    /// ensures the continuation resumes exactly once.
    private static func applyWithTimeout(
        _ vd: CGVirtualDisplay,
        _ settings: CGVirtualDisplaySettings,
        seconds: Double,
    ) async -> Bool {
        // The CG classes aren't Sendable; ferry them into the background queue via an explicit
        // unchecked box. Safe: `applySettings:` is the only off-main touch and it runs once, before
        // we store/use `vd` on the main actor (the continuation hop re-synchronizes).
        let box = ApplyBox(vd: vd, settings: settings)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = box.vd.apply(box.settings) // imported Swift name for `-applySettings:`
                if once.fire() { cont.resume(returning: ok) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.fire() { cont.resume(returning: false) }
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
