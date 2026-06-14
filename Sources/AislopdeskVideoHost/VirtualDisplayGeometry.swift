#if os(macOS)
import CoreGraphics
import Foundation

/// PURE point↔pixel↔millimeter arithmetic for a HiDPI virtual display (feature #1, 2026-06-08).
/// No CoreGraphics IPC, no private API — just the math that decides the `CGVirtualDisplayMode`
/// (POINT size), the descriptor's `maxPixelsWide/High` (PIXEL framebuffer), and
/// `sizeInMillimeters` (for a target PPI). Kept separate from ``VirtualDisplay`` so the
/// pixel/point/PPI decisions are headlessly unit-testable while the WindowServer IPC stays thin.
///
/// The HiDPI rule (from the CGVirtualDisplay research / FreeDisplay / force-hidpi / Chromium):
/// mode width/height are POINTS; `maxPixelsWide/High = points × scale`; `settings.hiDPI = 1`
/// makes the OS back the point grid with `scale`× pixels. So a 1920×1080-POINT mode with
/// `maxPixels = 3840×2160` and `hiDPI = 1` is a true Retina 2× display.
public struct VirtualDisplayGeometry: Equatable, Sendable {
    /// Logical (point) resolution — what the window "sees" as the display size.
    public let pointWidth: Int
    public let pointHeight: Int
    /// Backing pixel scale (2 = Retina 2×).
    public let scale: Int
    /// Per-chip maximum horizontal framebuffer pixels. Apple Silicon: base M1/M2 = 6144,
    /// Pro/Max/Ultra + M3+ = 7680. Exceeding it makes `applySettings:` silently fail
    /// (returns YES but displayID stays 0), so we refuse up front and fall back to 1×.
    public let maxHorizontalPixels: Int

    public init(pointWidth: Int, pointHeight: Int, scale: Int = 2, maxHorizontalPixels: Int = 7680) {
        self.pointWidth = max(1, pointWidth)
        self.pointHeight = max(1, pointHeight)
        self.scale = max(1, scale)
        self.maxHorizontalPixels = max(1, maxHorizontalPixels)
    }

    /// Backing framebuffer width in pixels (`points × scale`).
    public var pixelWidth: Int { pointWidth * scale }
    /// Backing framebuffer height in pixels (`points × scale`).
    public var pixelHeight: Int { pointHeight * scale }

    /// True when the backing framebuffer would exceed the chip's horizontal pixel limit — the
    /// caller must NOT create the VD (it would silently fail) and should fall back to 1× capture.
    public var exceedsPixelLimit: Bool { pixelWidth > maxHorizontalPixels }

    /// Physical size in millimeters for a target pixel density. macOS derives the reported DPI +
    /// HiDPI eligibility from this; ~163 PPI (27" 4K-class) is universally accepted. Computed from
    /// the PIXEL dimensions so the density matches the real framebuffer. `1 inch = 25.4 mm`.
    public func sizeInMillimeters(targetPPI: Double = 163) -> CGSize {
        let ppi = max(1, targetPPI)
        return CGSize(
            width: Double(pixelWidth) / ppi * 25.4,
            height: Double(pixelHeight) / ppi * 25.4,
        )
    }
}

/// PURE display-placement / chip-capability arithmetic for the virtual display. No CoreGraphics IPC
/// — separated from ``VirtualDisplay`` so the layout + limit decisions are headlessly unit-testable.
public enum VirtualDisplayPlanner {
    /// The VD's global origin: flush to the RIGHT of the rightmost existing display, at y = 0. Placing
    /// it past every real display guarantees it never overlaps one — macOS resolves an overlap by
    /// reflowing displays, which corrupts the user's real multi-monitor arrangement. On a
    /// single-display host the rightmost edge IS the main display's width, so this reduces to the
    /// historical `(mainWidth, 0)`. `existingDisplays` are the online displays' global bounds.
    public static func originToRight(of existingDisplays: [CGRect]) -> CGPoint {
        let maxX = existingDisplays.map(\.maxX).max() ?? 0
        return CGPoint(x: maxX, y: 0)
    }

    /// CGVirtualDisplay maximum horizontal framebuffer pixels for the running chip, from the
    /// `machdep.cpu.brand_string`. A Pro/Max/Ultra die has the larger display-pipe budget (7680); a
    /// base "Apple M…" die is 6144. Intel / unknown → 7680 (permissive — an over-budget create still
    /// fails safe via the `displayID == 0` guard, falling back to 1×). Pure + unit-tested; the live
    /// `sysctl` read lives in the daemon.
    public static func chipPixelLimit(cpuBrand: String) -> Int {
        let s = cpuBrand.lowercased()
        if s.contains("pro") || s.contains("max") || s.contains("ultra") { return 7680 }
        if s.contains("apple m") { return 6144 } // plain base M-series (M1/M2/M3/M4…)
        return 7680
    }

    /// The refresh-rate modes to advertise for a VD driven at `fps`. WindowServer composites a
    /// VD-parked window at most at the VD's refresh, so a window at `--fps 90` needs a ≥90 Hz mode or
    /// capture is silently capped at 60. Always include 60 + 30 (the safe baseline) and `fps` when it
    /// exceeds 60; deduped + descending. Pure + unit-tested.
    public static func refreshRates(fps: Int) -> [Double] {
        var rates = [60.0, 30.0]
        if fps > 60 { rates.append(Double(fps)) }
        return Array(Set(rates)).sorted(by: >)
    }
}
#endif
