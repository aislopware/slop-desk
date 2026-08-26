#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import Foundation
import OSLog

// @preconcurrency: the private CG classes (clang module) predate Swift concurrency and are not
// `Sendable`; we cross them into a background queue ONLY inside ``applyWithTimeout`` via an explicit
// unchecked-Sendable box, so downgrade the module-level Sendable notes to warnings.
@preconcurrency import CSlopDeskVirtualDisplay

/// Owns ONE HiDPI virtual display for the daemon lifetime. The remoted
/// window is moved onto it (see ``WindowPlacement``) so it renders at real Retina 2× backing and is
/// captured sharp, instead of the soft point-resolution-upscale path on a 1× host display.
///
/// ⚠️ CONTRACT (from the CGVirtualDisplay research):
/// - `CGVirtualDisplay(descriptor:)` must run on the MAIN THREAD (synchronous WindowServer Mach IPC)
///   → this type is `@MainActor`.
/// - The process must keep a live run loop (slopdesk-videohostd switches `dispatchMain()` →
///   `NSApplication.run()` when the VD is enabled) or WindowServer tears the display down.
/// - The `CGVirtualDisplay` object must be RETAINED for its lifetime — ARC dealloc unregisters it.
///   Hence the strong `vd` ref here, held by a daemon-lifetime owner; `destroy()` releases it.
/// - `applySettings:` BLOCKS on WindowServer IPC → run off-main with a timeout.
/// - EVERY failure returns nil → caller falls back to 1× capture. NEVER crashes.
///
/// HW-GATED: needs a window server + a run loop; not exercised in tests. Everything below the IPC —
/// the pixel/point/millimetre math, the placement and the advertised modes — is
/// `rust/slopdesk-video`'s `virtual_display`, reached through ``VirtualDisplayGeometry`` /
/// ``VirtualDisplayPlanner``, and is tested there and by the golden corpus.
@preconcurrency
@MainActor
public final class VirtualDisplay {
    private let log = Logger(subsystem: "slopdesk.video.host", category: "VirtualDisplay")
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

    /// Whether the four private `CGVirtualDisplay*` classes actually exist in the running process's
    /// CoreGraphics.framework. They are `weak_import`ed (see `CGVirtualDisplayPrivate.h`) precisely
    /// so this can be a plain runtime check instead of a dyld-time hard failure — a future macOS
    /// point release that removes/renames one of them just flips this to `false` instead of
    /// crashing the daemon on launch. Checked once (`static let` is lazy + thread-safe-once) and
    /// cached for the process lifetime; never instantiates a display.
    static let privateClassesAvailable: Bool =
        NSClassFromString("CGVirtualDisplay") != nil &&
        NSClassFromString("CGVirtualDisplayDescriptor") != nil &&
        NSClassFromString("CGVirtualDisplaySettings") != nil &&
        NSClassFromString("CGVirtualDisplayMode") != nil

    /// Create a HiDPI virtual display for `geometry`, advertising refresh modes that cover `fps`.
    /// Returns its `CGDirectDisplayID` on success, `nil` on ANY failure (private API absent on this
    /// OS, WindowServer refusal, applySettings timeout/failure, displayID stayed 0, pixel-limit
    /// exceeded) — the caller then falls back to 1× real-display capture.
    public func create(
        _ geometry: VirtualDisplayGeometry,
        name: String = "SlopDesk Remote",
        fps: Int = 60,
    ) async -> CGDirectDisplayID? {
        // Gate the FIRST use of any of the four private classes behind the weak-linked existence
        // check — constructing `CGVirtualDisplayDescriptor()` below with a class that dyld resolved
        // to nil (a removed/renamed private API on a future OS) would crash on the first message
        // send. This keeps the documented "EVERY failure returns nil → 1× fallback, NEVER crashes"
        // contract even when the private API itself is gone.
        guard Self.privateClassesAvailable else {
            log.error("CGVirtualDisplay* private classes unavailable on this OS — fallback to 1×")
            return nil
        }
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
        // overlap a real display. On a single-display host this reduces to: pin
        // main at (0,0), VD at (mainWidth, 0).
        // ONLINE and not active: a sleeping or mirrored display still owns its origin, and pinning
        // only the drawable ones would let WindowServer reflow the rest. The enumeration is
        // ``HostDisplays`` — `rust/slopdesk-apple-cgdisplay` — because the two-call
        // `CGGetOnlineDisplayList` dance is exactly the shape that reads as correct while dropping
        // a display, and the tree gets to spell it once.
        let physicalDisplays = HostDisplays.displays(online: true)
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
        desc.queue = DispatchQueue(label: "slopdesk.video.vd.termination", qos: .userInitiated)
        desc.terminationHandler = { [weak self] _, reason in
            // Delivered on desc.queue (background). Log, then hop to the main actor to clear our
            // state + notify the daemon (so it restores parked windows and stops targeting a dead id).
            Logger(subsystem: "slopdesk.video.host", category: "VirtualDisplay")
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

    /// The extend + origin-pin transaction. Stops any auto-mirror on the VD, pins every captured
    /// physical display at its original origin, and places the VD at `vdOrigin`, committing
    /// `.forAppOnly`. Each CGError is checked + logged; on a complete-failure the half-built
    /// transaction is verified rather than reported as success.
    private func applyExtendConfiguration(
        vdID id: CGDirectDisplayID,
        vdOrigin: CGPoint,
        physicalDisplays: [HostDisplays.Display],
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

/// The Swift face of `rust/slopdesk-video`'s `virtual_display`: what the descriptor above gets
/// FILLED WITH — the point grid a `CGVirtualDisplayMode` is built from, the `maxPixelsWide/High`
/// framebuffer, and the `sizeInMillimeters` that decides the reported density.
///
/// Every field is read out of ONE crossing, taken at init. The floors ride back with the derived
/// pixels precisely so this side keeps no `max(1, …)` of its own: a zero-width request is answered
/// once, on the side that also answers what it means for the pixel-limit guard.
///
/// The HiDPI rule these numbers serve (CGVirtualDisplay research / FreeDisplay / force-hidpi /
/// Chromium): mode width/height are POINTS, `maxPixelsWide/High = points × scale`, and
/// `settings.hiDPI = 1` makes the OS back the point grid with `scale`× pixels — so a 1920×1080-point
/// mode with `maxPixels = 3840×2160` and `hiDPI = 1` is a true Retina 2× display.
public struct VirtualDisplayGeometry: Equatable, Sendable {
    /// Logical (point) resolution — what the window "sees" as the display size.
    public let pointWidth: Int
    public let pointHeight: Int
    /// Backing pixel scale (2 = Retina 2×).
    public let scale: Int
    /// The chip's maximum horizontal framebuffer pixels this geometry was judged against.
    public let maxHorizontalPixels: Int
    /// Backing framebuffer width in pixels (`points × scale`).
    public let pixelWidth: Int
    /// Backing framebuffer height in pixels (`points × scale`).
    public let pixelHeight: Int
    /// True when the backing framebuffer would exceed the chip's horizontal pixel limit — the
    /// caller must NOT create the VD (it would silently fail) and should fall back to 1× capture.
    public let exceedsPixelLimit: Bool

    public init(
        pointWidth: Int,
        pointHeight: Int,
        scale: Int = 2,
        maxHorizontalPixels: Int = VirtualDisplayPlanner.unknownChipPixelLimit,
    ) {
        // `Int32(clamping:)` is a WIDTH conversion, not a floor — a five-figure request saturates
        // instead of trapping, and what a degenerate one MEANS is decided on the far side.
        let geometry = slopdesk_vd_geometry(
            Int32(clamping: pointWidth),
            Int32(clamping: pointHeight),
            Int32(clamping: scale),
            Int32(clamping: maxHorizontalPixels),
        )
        self.pointWidth = Int(geometry.point_width)
        self.pointHeight = Int(geometry.point_height)
        self.scale = Int(geometry.scale)
        self.maxHorizontalPixels = Int(geometry.max_horizontal_pixels)
        pixelWidth = Int(geometry.pixel_width)
        pixelHeight = Int(geometry.pixel_height)
        exceedsPixelLimit = geometry.exceeds_pixel_limit
    }

    /// Physical size in millimeters for a target pixel density. macOS derives the reported DPI and
    /// HiDPI eligibility from this, so the rounding order is pinned by `virtualDisplayGeometry` in
    /// `golden/golden_vectors.json` as BIT PATTERNS — which is the reason the division and the
    /// multiplication are spelled once, on the far side, rather than here beside a copy of them.
    public func sizeInMillimeters(targetPPI: Double = slopdesk_vd_default_target_ppi()) -> CGSize {
        let millimetres = slopdesk_vd_size_in_millimeters(
            Int32(clamping: pointWidth),
            Int32(clamping: pointHeight),
            Int32(clamping: scale),
            Int32(clamping: maxHorizontalPixels),
            targetPPI,
        )
        return CGSize(width: millimetres.width, height: millimetres.height)
    }
}

/// The Swift face of the same crate's placement and capability rules: where the virtual display goes
/// in the global display space, what the running chip can drive, and which refresh modes to
/// advertise. No arithmetic lives here — the marshalling does.
public enum VirtualDisplayPlanner {
    /// The VD's global origin: flush to the RIGHT of the rightmost existing display, at y = 0.
    /// Placing it past every real display guarantees it never overlaps one — macOS resolves an
    /// overlap by REFLOWING displays, which corrupts the user's real multi-monitor arrangement. On a
    /// single-display host this reduces to `(mainWidth, 0)`.
    public static func originToRight(of existingDisplays: [CGRect]) -> CGPoint {
        // RAW stored fields, NOT `CGRect.width`: the far side standardises, and pre-abs'ing an
        // extent while keeping the raw origin would move the right edge of a right-to-left rect.
        var scalars = [Double]()
        scalars.reserveCapacity(existingDisplays.count * 4)
        for bounds in existingDisplays {
            scalars.append(contentsOf: [
                bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
            ])
        }
        let origin = scalars.withUnsafeBufferPointer { displays in
            slopdesk_vd_origin_to_right(displays.baseAddress, existingDisplays.count)
        }
        return CGPoint(x: origin.x, y: origin.y)
    }

    /// CGVirtualDisplay maximum horizontal framebuffer pixels for the running chip, from its
    /// `machdep.cpu.brand_string`. The live `sysctl` read lives in the daemon; this is the rule.
    public static func chipPixelLimit(cpuBrand: String) -> Int {
        var brand = cpuBrand
        return brand.withUTF8 { bytes in
            Int(slopdesk_vd_chip_pixel_limit(bytes.baseAddress, bytes.count))
        }
    }

    /// The budget an UNRECOGNISED chip is judged against — the permissive one, because an
    /// over-budget create still fails safe through the `displayID == 0` guard while an over-strict
    /// limit refuses a display that would have worked. Named rather than typed, so the number stays
    /// the far side's.
    public static let unknownChipPixelLimit = chipPixelLimit(cpuBrand: "")

    /// The refresh-rate modes to advertise for a VD used as the capture SOURCE for an `fps`-fps
    /// encode: the 60 + 30 baseline, the capped 2:1 oversample that stops the capture beating
    /// against the commit, and the window's own rate when it exceeds 60. Descending, deduplicated.
    public static func refreshRates(fps: Int) -> [Double] {
        // The rule's answer is bounded by construction; the retry below is what makes that bound an
        // optimisation rather than a contract, so a wider rule cannot silently truncate the order.
        var rates = [Double](repeating: 0, count: 4)
        var count = rates.withUnsafeMutableBufferPointer { out in
            slopdesk_vd_refresh_rates(Int32(clamping: fps), out.baseAddress, out.count)
        }
        if count > rates.count {
            rates = [Double](repeating: 0, count: count)
            count = rates.withUnsafeMutableBufferPointer { out in
                slopdesk_vd_refresh_rates(Int32(clamping: fps), out.baseAddress, out.count)
            }
        }
        return Array(rates.prefix(count))
    }
}
#endif
