// SimulatorScreenLayout — where the device's frame sits inside the panel, and how a point in the
// panel becomes a point the host can act on.
//
// Pure geometry, split out of the view for the obvious reason: this is the part that can be wrong in
// a way nobody notices until a tap lands two rows off, and it is the part a test can pin exactly.
//
// The device is TALL and the panel is a sidebar, so the frame is almost always height-limited with
// bars either side. Aspect-fit rather than fill: cropping a phone screen hides the status bar or the
// home indicator, which are precisely the things someone mirroring a device is looking at.
//
// Coordinates sent upstream are in the FITTED RECT's own space, paired with that rect's size — the
// wire carries `width`/`height` with every positional envelope, so the host does the scaling to the
// real framebuffer. That is why nothing here needs the device's pixel dimensions: only the ratio.

#if os(macOS)
import CoreGraphics

package enum SimulatorScreenLayout {
    /// Where the frame sits inside the panel — ``DevicePanelGeometry/fittedRect(content:in:)``,
    /// which both device panels share and which reaches the same aspect-fit law the video client's
    /// renderer uses.
    package static func fittedRect(content contentSize: CGSize, in bounds: CGSize) -> CGRect {
        DevicePanelGeometry.fittedRect(content: contentSize, in: bounds)
    }

    /// A panel-space point in the frame's own space, or `nil` beside it — shared, see
    /// ``DevicePanelGeometry/devicePoint(from:fitted:)``.
    package static func devicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint? {
        DevicePanelGeometry.devicePoint(from: point, fitted: fitted)
    }

    /// The surface descriptor that rides on every positional envelope: the fitted rect's own size, so
    /// the host scales from the space the coordinates were actually measured in.
    package static func surface(fitted: CGRect) -> SimulatorInputEnvelope.Surface {
        SimulatorInputEnvelope.Surface(width: fitted.width, height: fitted.height)
    }

    /// What a classic wheel NOTCH is worth in points — shared, see
    /// ``DevicePanelGeometry/pointsPerLine``.
    package static var pointsPerLine: CGFloat { DevicePanelGeometry.pointsPerLine }

    /// One scroll event's delta as FINGER TRAVEL on the framebuffer, in points. Measured 2026-08-04
    /// against a live device; getting this wrong produces a panel that scrolls backwards or not at all.
    ///
    /// SCALE and SIGN are the shared rule — see ``DevicePanelGeometry/scrollVector(delta:isPrecise:)``,
    /// which carries the measurement behind the pass-through sign.
    ///
    /// ORIENTATION is the one thing this panel adds, and it was wrong before this existed. A scroll
    /// delta arrives in SCREEN space — AppKit knows nothing about the `rotationEffect` the bezel is
    /// drawn under — while the framebuffer never turns, so on a device on its side the two disagree
    /// by a quarter turn. Points do not need this (SwiftUI hit-tests a rotated view in its unrotated
    /// local space, so a click already arrives in framebuffer coordinates); a delta that never passed
    /// through the view's geometry does. The Android panel has no such step: `scrcpy` rotates on the
    /// DEVICE, so its frame is always already the right way up.
    package static func scrollVector(
        delta: CGSize, isPrecise: Bool, orientation: SimulatorOrientation,
    ) -> CGSize {
        unrotated(
            DevicePanelGeometry.scrollVector(delta: delta, isPrecise: isPrecise),
            by: orientation.viewAngle,
        )
    }

    /// A screen-space vector in the space of a view drawn at `angle` degrees clockwise — shared, see
    /// ``DevicePanelGeometry/unrotated(_:by:)``.
    package static func unrotated(_ vector: CGSize, by angle: Double) -> CGSize {
        DevicePanelGeometry.unrotated(vector, by: angle)
    }

    /// How far into the frame iOS's own edge gestures reach, as a fraction of the framebuffer.
    /// `baguette`'s own web UI uses these two numbers and this classification; they are copied rather
    /// than re-derived because the server interprets the `edge` hint against them.
    package static var bottomBand: CGFloat { DevicePanelGeometry.bottomBand }
    package static var topBand: CGFloat { DevicePanelGeometry.topBand }

    /// Which system edge, if any, a contact starting at `point` belongs to — the hint that lets the
    /// host drive the home indicator, the app switcher and the pull-down shades from a drag instead
    /// of only from a button.
    ///
    /// The classification is ``DevicePanelGeometry/systemEdge(at:fitted:isUpsideDown:)``. What stays
    /// here is which orientation counts as upside-down, and the wire's spelling of the answer: the
    /// server reads a lowercase name, not a kind.
    package static func edge(
        at point: CGPoint, fitted: CGRect, orientation: SimulatorOrientation,
    ) -> String? {
        DevicePanelGeometry.systemEdge(
            at: point, fitted: fitted, isUpsideDown: orientation == .portraitUpsideDown,
        )?.rawValue
    }

    /// A pinch's two contacts — shared, see ``DevicePanelGeometry/pinchFingers(centre:spread:fitted:)``.
    package static func pinchFingers(
        centre: CGPoint, spread: CGFloat, fitted: CGRect,
    ) -> (CGPoint, CGPoint) {
        DevicePanelGeometry.pinchFingers(centre: centre, spread: spread, fitted: fitted)
    }
}
#endif
