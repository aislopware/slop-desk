import CAislopdeskFFI
import CoreGraphics
import Foundation

/// Swift-side bridge from `AislopdeskVideoHost` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the host module is contained here; the host's policy types
/// call these typed wrappers so their public APIs stay unchanged. The realtime bitrate logic
/// lives in the Rust core (`aislopdesk-core`) and is exposed over the C-ABI boundary; golden
/// vectors assert byte-/bit-exact output, so the macOS/iOS host and a future Android client
/// drive the identical algorithm from one core. Env knobs stay resolved Swift-side and are
/// passed in, keeping the core env-free.
public enum RustVideoHostFFI {
    /// Resolution-aware target bitrate (bits/sec). Wraps `aisd_live_bitrate_target`.
    static func liveBitrateTarget(
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Int,
        floor: Int,
        bitsPerPixel: Double,
    ) -> Int {
        Int(
            aisd_live_bitrate_target(
                Int64(pixelWidth), Int64(pixelHeight), Int64(fps), Int64(floor), bitsPerPixel,
            ),
        )
    }

    /// The absolute minimum live bitrate (bits/sec). Wraps `aisd_live_bitrate_minimum`.
    static func liveBitrateMinimum() -> Int {
        Int(aisd_live_bitrate_minimum())
    }

    // MARK: - window_placement (pure, flat-struct; HiDPI VD-park path)

    /// Clamp `windowSize` DOWN to `displayBounds` (never enlarge) and place it at the display's
    /// top-left origin. Wraps `aisd_window_placement`.
    static func windowPlacement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool)
    {
        let p = aisd_window_placement(
            Double(windowSize.width), Double(windowSize.height), aisdRect(displayBounds),
        )
        return (
            CGPoint(x: p.x, y: p.y),
            CGSize(width: p.width, height: p.height),
            p.needs_resize != 0,
        )
    }

    /// Whether `size` fits inside `bounds` (½-pt tolerance). Wraps `aisd_window_fits`.
    static func windowFits(_ size: CGSize, within bounds: CGRect) -> Bool {
        aisd_window_fits(Double(size.width), Double(size.height), aisdRect(bounds)) != 0
    }

    // MARK: - virtual_display_geometry (VD creation path)

    /// Builds a (clamped) VD geometry with its derived pixel dims + chip-limit check. Wraps
    /// `aisd_vd_geometry`.
    public static func vdGeometry(
        pointWidth: Int,
        pointHeight: Int,
        scale: Int,
        maxHorizontalPixels: Int = 7680,
    ) -> VDGeometry {
        let r = aisd_vd_geometry(
            Int64(pointWidth), Int64(pointHeight), Int64(scale), Int64(maxHorizontalPixels),
        )
        return VDGeometry(
            pointWidth: Int(r.point_width),
            pointHeight: Int(r.point_height),
            scale: Int(r.scale),
            maxHorizontalPixels: Int(r.max_horizontal_pixels),
            pixelWidth: Int(r.pixel_width),
            pixelHeight: Int(r.pixel_height),
            exceedsPixelLimit: r.exceeds_pixel_limit != 0,
        )
    }

    /// Physical size in millimetres for a `pixelWidth × pixelHeight` display at `targetPPI`.
    /// Wraps `aisd_vd_size_in_millimeters`.
    static func vdSizeInMillimeters(pixelWidth: Int, pixelHeight: Int, targetPPI: Double = 163) -> CGSize {
        let mm = aisd_vd_size_in_millimeters(Int64(pixelWidth), Int64(pixelHeight), targetPPI)
        return CGSize(width: mm.width, height: mm.height)
    }

    /// The VD origin flush right of the rightmost display (`(0,0)` when none). Wraps
    /// `aisd_vd_origin_to_right`.
    static func vdOriginToRight(of displayBounds: [CGRect]) -> CGPoint {
        let rects = displayBounds.map { aisdRect($0) }
        let p = rects.withUnsafeBufferPointer { buf in
            aisd_vd_origin_to_right(buf.baseAddress, buf.count)
        }
        return CGPoint(x: p.x, y: p.y)
    }

    /// The chip's horizontal pixel ceiling from a CPU brand string. Wraps
    /// `aisd_vd_chip_pixel_limit`.
    public static func vdChipPixelLimit(cpuBrand: String) -> Int {
        Int(cpuBrand.withCString { aisd_vd_chip_pixel_limit($0) })
    }

    /// The descending refresh-rate modes for a VD at `fps` (always 2 or 3). Wraps
    /// `aisd_vd_refresh_rates`.
    static func vdRefreshRates(fps: Int) -> [Double] {
        var buf = [Double](repeating: 0, count: 3) // max output is (fps, 60, 30)
        let count = buf.withUnsafeMutableBufferPointer { ptr in
            aisd_vd_refresh_rates(Int64(fps), ptr.baseAddress, ptr.count)
        }
        return Array(buf.prefix(count))
    }

    // MARK: - capture_region (dialog-expand capture math; AX-event-driven)

    /// The capture union region: target window ∪ qualifying same-pid panels in front, clamped to
    /// the display. Wraps `aisd_capture_union_region`.
    static func captureUnionRegion(
        targetFrame: CGRect,
        targetWindowID: UInt32,
        targetPID: Int32,
        windowsInFront: [CaptureWindow],
        displayBounds: CGRect,
        minOverlapFraction: Double = 0.30,
    ) -> CGRect {
        let cWindows = windowsInFront.map {
            AisdCaptureWindowSnapshot(
                window_id: $0.windowID,
                owner_pid: $0.ownerPID,
                layer: $0.layer,
                frame: aisdRect($0.frame),
            )
        }
        let out = cWindows.withUnsafeBufferPointer { buf in
            aisd_capture_union_region(
                aisdRect(targetFrame), targetWindowID, targetPID,
                buf.baseAddress, buf.count,
                aisdRect(displayBounds), minOverlapFraction,
            )
        }
        return cgRect(out)
    }

    /// Hysteresis gate: `true` if `desired` differs from `current` by more than `minDelta` on any
    /// edge. Wraps `aisd_capture_should_retarget`.
    static func captureShouldRetarget(current: CGRect, desired: CGRect, minDelta: Double = 8) -> Bool {
        aisd_capture_should_retarget(aisdRect(current), aisdRect(desired), minDelta) != 0
    }

    /// Whether a geometry change should re-origin capture to the plain window frame (no union
    /// active). Wraps `aisd_capture_reorigin_on_geometry`.
    static func captureReoriginOnGeometry(activeRegionGlobal: CGRect?) -> Bool {
        aisd_capture_reorigin_on_geometry(activeRegionGlobal == nil ? 1 : 0) != 0
    }

    /// Flattens a `CGRect` into the C-ABI `AisdRect` (x, y, width, height — all `Double`).
    private static func aisdRect(_ r: CGRect) -> AisdRect {
        AisdRect(
            x: Double(r.origin.x),
            y: Double(r.origin.y),
            width: Double(r.size.width),
            height: Double(r.size.height),
        )
    }

    /// Rebuilds a `CGRect` from the C-ABI `AisdRect`.
    private static func cgRect(_ r: AisdRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}

/// A virtual-display geometry value: clamped fields + derived pixel dims + chip-limit check.
///
/// The geometry math lives in the Rust core (`aislopdesk_core::virtual_display_geometry`);
/// this is the value carrier the host's VD-creation path consumes.
public struct VDGeometry: Equatable, Sendable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let scale: Int
    public let maxHorizontalPixels: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let exceedsPixelLimit: Bool

    /// Physical size in millimetres at `targetPPI` (computed by the Rust core).
    public func sizeInMillimeters(targetPPI: Double = 163) -> CGSize {
        RustVideoHostFFI.vdSizeInMillimeters(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, targetPPI: targetPPI,
        )
    }
}

/// One on-screen window (`CGWindowListCopyWindowInfo` row) fed to the capture-region math.
struct CaptureWindow {
    let windowID: UInt32
    let ownerPID: Int32
    let layer: Int64
    let frame: CGRect
}
