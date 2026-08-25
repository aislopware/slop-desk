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

    /// The same mapping for a point that may have left the frame mid-drag, CLAMPED instead of
    /// dropped — shared, see ``DevicePanelGeometry/clampedDevicePoint(from:fitted:)``.
    ///
    /// This lane spelled it itself until 2026-08-22, and the copy was WRONG: it clamped to the
    /// fitted rect's size where the shared rule clamps to the last addressable point inside it. A
    /// drag to the right edge of a 200-point frame therefore reported x = 200 into a surface whose
    /// columns are `0..<200`, and the host scales that straight off the far side of the
    /// framebuffer. The Android lane had asked through the door since the door existed.
    package static func clampedDevicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint {
        DevicePanelGeometry.clampedDevicePoint(from: point, fitted: fitted)
    }

    /// The surface descriptor that rides on every positional envelope: the fitted rect's own size, so
    /// the host scales from the space the coordinates were actually measured in.
    package static func surface(fitted: CGRect) -> SimulatorInputEnvelope.Surface {
        SimulatorInputEnvelope.Surface(width: fitted.width, height: fitted.height)
    }

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
