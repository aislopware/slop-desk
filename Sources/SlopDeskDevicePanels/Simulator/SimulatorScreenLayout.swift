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

    /// What a classic wheel NOTCH is worth in points. AppKit reports a trackpad's delta already in
    /// points and a wheel's in LINES, and a line taken as a point is a finger movement of one or two
    /// pixels — under iOS's own pan slop, so the device ignores it entirely and the panel looks like
    /// it eats scrolls.
    package static let pointsPerLine: CGFloat = 32

    /// One scroll event's delta as FINGER TRAVEL on the framebuffer, in points. Measured 2026-08-04
    /// against a live device; getting this wrong produces a panel that scrolls backwards or not at all.
    ///
    /// SCALE. `isPrecise` is `NSEvent.hasPreciseScrollingDeltas`: a trackpad reports points and is
    /// used as-is, a classic wheel reports LINES and is scaled by ``pointsPerLine``.
    ///
    /// SIGN — pass-through, and deliberately so. AppKit has ALREADY applied the user's scroll-direction
    /// preference to `scrollingDeltaY`: a positive value always means "move toward the top of the
    /// document", whichever way the fingers physically went. On a touch surface that is a finger
    /// travelling DOWN the screen, which in this view's flipped space is +y — so the delta maps
    /// straight onto the finger. `NSEvent.isDirectionInvertedFromDevice` reports the RAW device
    /// direction and is informational; folding it in here double-applies the preference, and
    /// synthesized events report it `false` regardless of the setting. Measured both ways 2026-08-04:
    /// with the flag folded in, one scroll gesture moved the device's list opposite to the way the
    /// same gesture moved a native scroll view in the same window.
    ///
    /// ORIENTATION is the one thing that is NOT pass-through, and it was wrong before this existed.
    /// A scroll delta arrives in SCREEN space — AppKit knows nothing about the `rotationEffect` the
    /// bezel is drawn under — while the framebuffer never turns, so on a device on its side the two
    /// disagree by a quarter turn. Points do not need this (SwiftUI hit-tests a rotated view in its
    /// unrotated local space, so a click already arrives in framebuffer coordinates); a delta that
    /// never passed through the view's geometry does.
    package static func scrollVector(
        delta: CGSize, isPrecise: Bool, orientation: SimulatorOrientation,
    ) -> CGSize {
        let scale = isPrecise ? 1 : pointsPerLine
        return unrotated(
            CGSize(width: delta.width * scale, height: delta.height * scale),
            by: orientation.viewAngle,
        )
    }

    /// A screen-space vector in the space of a view drawn at `angle` degrees clockwise. Quarter turns
    /// only, which is all ``SimulatorOrientation`` produces — spelled out rather than run through
    /// trigonometry so the four cases are readable and a test can pin them exactly.
    package static func unrotated(_ vector: CGSize, by angle: Double) -> CGSize {
        switch Int(angle.rounded()) {
        case 90: CGSize(width: vector.height, height: -vector.width)
        case -90,
             270: CGSize(width: -vector.height, height: vector.width)
        case 180,
             -180: CGSize(width: -vector.width, height: -vector.height)
        default: vector
        }
    }

    /// How far into the frame iOS's own edge gestures reach, as a fraction of the framebuffer.
    /// `baguette`'s own web UI uses these two numbers and this classification; they are copied rather
    /// than re-derived because the server interprets the `edge` hint against them.
    package static let bottomBand: CGFloat = 0.93
    package static let topBand: CGFloat = 0.07

    /// Which system edge, if any, a contact starting at `point` belongs to — the hint that lets the
    /// host drive the home indicator, the app switcher and the pull-down shades from a drag instead
    /// of only from a button.
    ///
    /// `portrait-upside-down` is the case that is not a rotation of the others: the physical bottom
    /// edge lands on visual LEFT, so the bands swap axes. The landscape cases deliberately do not —
    /// the framebuffer stays portrait whichever way the device is held, and the home indicator stays
    /// on the same framebuffer edge.
    package static func edge(
        at point: CGPoint, fitted: CGRect, orientation: SimulatorOrientation,
    ) -> String? {
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let xNorm = point.x / fitted.width
        let yNorm = point.y / fitted.height
        let isUpsideDown = orientation == .portraitUpsideDown
        let inBottom = isUpsideDown ? xNorm <= 1 - bottomBand : yNorm >= bottomBand
        let inTop = isUpsideDown ? xNorm >= bottomBand : yNorm <= topBand
        if inBottom { return "bottom" }
        return inTop ? "top" : nil
    }

    /// A pinch's two contacts — shared, see ``DevicePanelGeometry/pinchFingers(centre:spread:fitted:)``.
    package static func pinchFingers(
        centre: CGPoint, spread: CGFloat, fitted: CGRect,
    ) -> (CGPoint, CGPoint) {
        DevicePanelGeometry.pinchFingers(centre: centre, spread: spread, fitted: fitted)
    }
}
#endif
