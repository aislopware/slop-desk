#if os(macOS)
import Foundation
import CoreGraphics

/// PURE geometry for the DIALOG-EXPAND feature (host-side, unit-tested): decide the capture region
/// = the target window frame ∪ any associated panel windows (a file-open / print / share dialog
/// the OS attaches to the window), so a dialog larger than the streamed window shows in full and is
/// clickable — instead of being cropped to the window frame by the display-anchored crop.
///
/// The association is by **owning process**: the open/save panel is attributed to the host app's
/// own pid (HW-verified 2026-06-12: a Chrome file dialog enumerates as `pid==Chrome, layer==0,
/// name=="Open"`), so a same-pid, normal-layer window that overlaps the target and sits IN FRONT of
/// it (the caller passes the front-to-back slice up to the target) is treated as an attached panel.
/// On the real deployment the streamed window is parked ALONE on the virtual display, so the only
/// same-pid window overlapping it is its own dialog — robust even on a busy physical desktop.
public enum CaptureRegionMath {

    /// One on-screen window, as read from `CGWindowListCopyWindowInfo` (CG top-left points).
    public struct WindowSnapshot: Equatable, Sendable {
        public let windowID: UInt32
        public let ownerPID: Int32
        public let layer: Int
        public let frame: CGRect
        public init(windowID: UInt32, ownerPID: Int32, layer: Int, frame: CGRect) {
            self.windowID = windowID; self.ownerPID = ownerPID; self.layer = layer; self.frame = frame
        }
    }

    /// The union of `targetFrame` with every qualifying associated panel in `windowsInFront`
    /// (front-to-back order, the slice strictly IN FRONT of the target), clamped to `displayBounds`.
    /// Returns `targetFrame` (clamped) when nothing qualifies — i.e. no dialog, or the dialog fits
    /// inside the window.
    ///
    /// A window qualifies as an attached panel when it is: a different window than the target, owned
    /// by `targetPID`, on the normal window layer (0 — excludes the menu bar / Dock / backstop /
    /// tooltips at other levels), and overlapping the target by a meaningful fraction (≥
    /// `minOverlapFraction` of the smaller rect's area — skips an incidental 1px edge touch from a
    /// sibling window). The whole panel frame joins the union even where it overhangs the window.
    public static func unionRegion(targetFrame: CGRect,
                                   targetWindowID: UInt32,
                                   targetPID: Int32,
                                   windowsInFront: [WindowSnapshot],
                                   displayBounds: CGRect,
                                   minOverlapFraction: Double = 0.30) -> CGRect {
        var union = targetFrame
        let targetArea = targetFrame.width * targetFrame.height
        guard targetArea > 0 else { return targetFrame.intersection(displayBounds) }
        for w in windowsInFront {
            guard w.windowID != targetWindowID, w.ownerPID == targetPID, w.layer == 0 else { continue }
            let inter = w.frame.intersection(targetFrame)
            guard !inter.isNull else { continue }
            let interArea = inter.width * inter.height
            let smallerArea = min(targetArea, w.frame.width * w.frame.height)
            guard smallerArea > 0, interArea / smallerArea >= minOverlapFraction else { continue }
            union = union.union(w.frame)
        }
        let clamped = union.intersection(displayBounds)
        return clamped.isNull ? targetFrame.intersection(displayBounds) : clamped
    }

    /// Hysteresis gate for committing a region change: each change is an encoder rebuild + IDR, so
    /// only retarget when the desired region differs from the current capture region by more than
    /// `minDelta` points on any edge. Returns true when the change is worth a rebuild.
    public static func shouldRetarget(current: CGRect, desired: CGRect, minDelta: Double = 8) -> Bool {
        abs(desired.minX - current.minX) > minDelta
            || abs(desired.minY - current.minY) > minDelta
            || abs(desired.width - current.width) > minDelta
            || abs(desired.height - current.height) > minDelta
    }
}
#endif
