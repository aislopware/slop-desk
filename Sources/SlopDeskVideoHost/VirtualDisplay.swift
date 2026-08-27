#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import Foundation

/// Owns ONE HiDPI virtual display for the daemon lifetime. The remoted window is moved onto it
/// (see ``WindowPlacement``) so it renders at real Retina 2× backing and is captured sharp, instead
/// of the soft point-resolution-upscale path on a 1× host display.
///
/// This is a FACE over `rust/slopdesk-apple-cgvirtualdisplay`, reached through the
/// `slopdesk_virtual_display_*` doors. The four private `CGVirtualDisplay*` classes, the descriptor,
/// the settings, the blocking `applySettings:` and the extend transaction all live there; what is
/// left here is the handle's lifetime and the C trampoline that turns a function pointer back into
/// a Swift closure.
///
/// ⚠️ NOT `@MainActor`, and that inversion is the point. The old class was, because
/// `initWithDescriptor:` is a synchronous WindowServer round-trip that must run on the main thread.
/// But `applySettings:` BLOCKS for seconds and must NOT. The door resolves that the only honest way:
/// ``create(_:name:fps:)`` is an OFF-MAIN blocking call that hops to main twice inside itself, so
/// calling it FROM the main actor DEADLOCKS. `Task.detached` below is what keeps that true.
///
/// The process must also keep a live run loop — `slopdesk-videohostd` switches `dispatchMain()` →
/// `NSApplication.run()` when the VD is enabled — or WindowServer tears the display down.
public final class VirtualDisplay: @unchecked Sendable {
    /// The Rust handle. One `_free` per `_new`, in ``deinit``.
    private let handle: OpaquePointer

    /// The live `CGDirectDisplayID`, or 0. An atomic read on the far side, so it is answerable
    /// while another pane's ``create(_:name:fps:)`` is blocked inside WindowServer.
    public var displayID: CGDirectDisplayID { slopdesk_virtual_display_id(handle) }

    /// The live display's backing scale, or 1.
    public var scale: Int { Int(slopdesk_virtual_display_scale(handle)) }

    /// Every trampoline box this handle has ever been given, alive until the handle is freed.
    ///
    /// A LIST, not one slot, and none of them is released on replacement: clearing the callback only
    /// stops the NEXT delivery, and a handler already in flight is still holding the pointer it was
    /// registered with. `slopdesk_virtual_display_free` is the one barrier that ends that — it waits
    /// out any handler in flight — so every box is released after it, and none before.
    private var terminationBoxes: [Unmanaged<TerminationBox>] = []

    /// Whether the four private `CGVirtualDisplay*` classes exist in this process's CoreGraphics.
    /// Cached on the far side for the process lifetime; instantiates nothing.
    public static var privateClassesAvailable: Bool {
        slopdesk_virtual_display_private_classes_available() == 1
    }

    public init() {
        guard let handle = slopdesk_virtual_display_new() else {
            preconditionFailure("slopdesk_virtual_display_new never answers null")
        }
        self.handle = handle
    }

    deinit {
        // Clear the callback first, then free — the free is what WAITS for a handler already inside
        // the trampoline, which is why the boxes may only be released once it has returned.
        slopdesk_virtual_display_set_terminated(handle, nil, nil)
        slopdesk_virtual_display_free(handle)
        for box in terminationBoxes { box.release() }
    }

    /// Create a HiDPI virtual display for `geometry`, advertising refresh modes that cover `fps`.
    /// Returns its `CGDirectDisplayID` on success, `nil` on ANY failure (private API absent on this
    /// OS, WindowServer refusal, applySettings timeout/failure, displayID stayed 0, pixel-limit
    /// exceeded) — the caller then falls back to 1× real-display capture.
    ///
    /// ⚠️ Blocks for up to ~11 seconds, off the main thread. `Task.detached` is load-bearing: the
    /// door deadlocks if it runs on the main actor.
    public func create(
        _ geometry: VirtualDisplayGeometry,
        name: String = "SlopDesk Remote",
        fps: Int = 60,
    ) async -> CGDirectDisplayID? {
        let handle = handle
        let id = await Task.detached(priority: .userInitiated) { () -> CGDirectDisplayID in
            var name = name
            return name.withUTF8 { bytes in
                slopdesk_virtual_display_create(
                    handle,
                    UInt32(clamping: geometry.pointWidth),
                    UInt32(clamping: geometry.pointHeight),
                    UInt32(clamping: geometry.scale),
                    UInt32(clamping: geometry.maxHorizontalPixels),
                    UInt32(clamping: fps),
                    bytes.baseAddress,
                    bytes.count,
                )
            }
        }.value
        return id == 0 ? nil : id
    }

    /// Registers what to run when WindowServer TERMINATES the display out from under us (display
    /// reconfig, GPU reset, fast-user-switch, sleep/wake). By the time it runs `displayID` is
    /// already cleared, so the daemon can restore parked windows + fall new mints back to 1×.
    ///
    /// ⚠️ Delivered on the framework's own queue, NOT the main actor, and it must not call
    /// ``destroy()``.
    @preconcurrency
    public func setOnTerminated(_ handler: (@Sendable () -> Void)?) {
        guard let handler else {
            slopdesk_virtual_display_set_terminated(handle, nil, nil)
            return
        }
        let box = Unmanaged.passRetained(TerminationBox(handler))
        terminationBoxes.append(box)
        slopdesk_virtual_display_set_terminated(handle, virtualDisplayTerminated, box.toOpaque())
    }

    /// Release the display (WindowServer unregisters it). Call on shutdown, AFTER all SCStreams
    /// targeting it have stopped (the FB17797423 retain rule) and AFTER parked windows have been
    /// restored (the original display must still exist). Idempotent.
    public func destroy() {
        slopdesk_virtual_display_destroy(handle)
    }
}

/// The closure, on the heap, so a C context pointer can name it.
private final class TerminationBox {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
}

/// The `@convention(c)` trampoline. Top-level so it captures nothing — a C function pointer cannot
/// carry context, which is what the `context` argument is for.
///
/// `takeUnretainedValue`: the box is owned by the ``VirtualDisplay`` that registered it and is
/// released only AFTER `slopdesk_virtual_display_free` has returned — never here, and never when the
/// callback is merely replaced.
private func virtualDisplayTerminated(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<TerminationBox>.fromOpaque(context).takeUnretainedValue().handler()
}

/// The Swift face of `rust/slopdesk-video`'s `virtual_display`: what the descriptor gets FILLED
/// WITH — the point grid a `CGVirtualDisplayMode` is built from, the `maxPixelsWide/High`
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
