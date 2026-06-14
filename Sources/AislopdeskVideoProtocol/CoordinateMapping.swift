import Foundation

/// A display the host knows about, described purely (no `NSScreen` dependency).
public struct ScreenInfo: Equatable, Sendable {
    /// The screen's frame in **Cocoa bottom-left** space (`NSScreen.frame`): origin
    /// bottom-left of the primary display, +Y up.
    public var cocoaFrame: VideoRect
    /// `NSScreen.backingScaleFactor` (1.0 standard, 2.0 Retina).
    public var backingScaleFactor: Double

    public init(cocoaFrame: VideoRect, backingScaleFactor: Double) {
        self.cocoaFrame = cocoaFrame
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Coordinate-mapping math (doc 18 §B — **SOLVED**; doc 05 §2).
///
/// The pipeline the host runs for every injected pointer event:
///
/// 1. The client streams **normalised (0..1) window coordinates** — never raw
///    pixels — which removes the pixel-vs-point ambiguity entirely (doc 05 §2).
/// 2. `normalized → host-window-point`: `target = windowBounds.origin + n *
///    windowBounds.size`, computed in **CG top-left space** (origin top-left of the
///    primary display, +Y down). `kCGWindowBounds` and CGEvent mouse positions
///    share this exact space, so the click coordinate needs **no Y flip**
///    (doc 05 §2 — the common mistake is flipping here).
/// 3. The Retina `backingScaleFactor` does NOT enter the click math (both sides are
///    points). It is only needed if the client ever sent pixels.
/// 4. The **multi-monitor fix** (doc 18 §B): `kCGWindowBounds` is CG top-left while
///    `NSScreen.frame` is Cocoa bottom-left. To pick the screen the window sits on
///    (and read its `backingScaleFactor`), the window rect must be flipped into
///    Cocoa space FIRST — `cocoaY = primaryHeight - y - height` — before
///    intersecting with each `NSScreen.frame`. Without this flip, a window on a
///    secondary monitor intersects the wrong screen and gets the wrong scale.
///
/// All functions are pure and exhaustively tested (single + multi-monitor + Retina).
public enum CoordinateMapping {
    /// Step 2 — maps a normalised (0..1) window point to a host-window point in
    /// **CG top-left** space, ready for `CGEvent(mouseCursorPosition:)` /
    /// `CGWarpMouseCursorPosition`. No Y flip, no scale (doc 05 §2).
    ///
    /// - Parameters:
    ///   - normalized: the click position within the window, x/y each in 0..1
    ///     (0,0 = window top-left, 1,1 = window bottom-right).
    ///   - windowBounds: `kCGWindowBounds` — the window rect in CG top-left points.
    /// - Returns: the absolute CG-space point to post the event at.
    public static func windowPoint(normalized: VideoPoint, windowBounds: VideoRect) -> VideoPoint {
        // Delegated to the Rust `aislopdesk-core` coordinate-mapping (single source of truth
        // shared with the Android host); byte-identical to the former native arithmetic (pinned
        // by `CoordinateMappingTests` + `RustCoordinateMappingParityTests`).
        RustVideoFFI.coordWindowPoint(normalized: normalized, windowBounds: windowBounds)
    }

    /// Step 4 (helper) — flips a CG-top-left rect into Cocoa bottom-left space given
    /// the primary display height. `cocoaY = primaryHeight - cgY - height`.
    ///
    /// The primary display's top is `cgY = 0` ⇒ its bottom is `cgY = primaryHeight`;
    /// in Cocoa the primary's bottom is `y = 0`. A window whose CG top is `y` and
    /// height `h` therefore has Cocoa bottom-left `primaryHeight - y - h`.
    public static func cgRectToCocoa(_ cgRect: VideoRect, primaryHeight: Double) -> VideoRect {
        // Delegated to the Rust core (see `windowPoint`).
        RustVideoFFI.coordCGRectToCocoa(cgRect, primaryHeight: primaryHeight)
    }

    /// Step 4 — picks the screen a window lives on (largest-overlap) and returns its
    /// `backingScaleFactor`. The window rect (CG top-left) is flipped into Cocoa
    /// space first, then intersected with each `NSScreen.frame` (Cocoa space).
    ///
    /// - Parameters:
    ///   - windowBoundsCG: the window rect in CG top-left points (`kCGWindowBounds`).
    ///   - screens: all displays (each `cocoaFrame` is `NSScreen.frame`).
    ///   - primaryHeight: the primary display's height in points (`NSScreen.screens
    ///     .first!.frame.height`), used for the CG↔Cocoa flip.
    /// - Returns: the `backingScaleFactor` of the best-overlapping screen, or `nil`
    ///   if the window overlaps no known screen.
    public static func backingScaleFactor(
        forWindowBoundsCG windowBoundsCG: VideoRect,
        screens: [ScreenInfo],
        primaryHeight: Double,
    ) -> Double? {
        // Delegated to the Rust core (see `windowPoint`); the screens array is borrowed for the
        // call only. Returns nil for no overlap, exactly as the native loop did.
        RustVideoFFI.coordBackingScaleFactor(
            windowBoundsCG: windowBoundsCG, screens: screens, primaryHeight: primaryHeight,
        )
    }

    /// Convenience for the rare case the client sent **pixels** instead of
    /// normalised coordinates (e.g. raw ScreenCaptureKit-frame pixels): divide by the
    /// resolved `backingScaleFactor` to get points, then add the window origin.
    /// Use ``backingScaleFactor(forWindowBoundsCG:screens:primaryHeight:)`` to get
    /// the scale. Documented so a future caller does NOT double-apply scale
    /// (doc 05 §2 warning).
    public static func windowPoint(
        pixel: VideoPoint,
        windowBoundsCG: VideoRect,
        backingScaleFactor scale: Double,
    ) -> VideoPoint {
        // Delegated to the Rust core (see `windowPoint`).
        RustVideoFFI.coordWindowPoint(pixel: pixel, windowBoundsCG: windowBoundsCG, backingScaleFactor: scale)
    }
}
