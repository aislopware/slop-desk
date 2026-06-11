#if os(macOS)
import Foundation
import CoreGraphics

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
        return CGSize(width: Double(pixelWidth) / ppi * 25.4,
                      height: Double(pixelHeight) / ppi * 25.4)
    }
}
#endif
