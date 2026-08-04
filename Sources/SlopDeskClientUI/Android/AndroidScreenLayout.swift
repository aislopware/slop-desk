// AndroidScreenLayout — where the device's frame sits inside the panel, and how a point in the panel
// becomes a point the device can act on.
//
// Pure geometry, split out of the view for the same reason as its simulator counterpart: this is the
// part that can be wrong in a way nobody notices until a tap lands two rows off, and it is the part a
// test can pin exactly.
//
// ## One whole class of bug the simulator panel has and this one does not
//
// `SimulatorScreenLayout` has to un-rotate scroll deltas, because the simulator's framebuffer NEVER
// turns — the bezel is drawn under a `rotationEffect` and a delta that never passed through the view's
// geometry disagrees with it by a quarter turn on a device held sideways. `scrcpy` rotates on the
// DEVICE: when the screen turns, the server tears down its encoder and starts a new session with the
// axes swapped, and the client is told so by a session packet carrying the new width and height. The
// frame arriving here is therefore always already the right way up, the view never rotates, and there
// is no angle for a vector to be out of step with. Rotation is a size change and nothing more.
//
// Coordinates sent upstream are in the FITTED RECT's own space, paired with that rect's size: every
// positional control message carries the `width`/`height` it was measured against and the server
// rescales. So nothing here needs the device's pixel dimensions either — only the ratio.

#if os(macOS)
import CoreGraphics
import Foundation

enum AndroidScreenLayout {
    /// The largest rect with `contentSize`'s aspect ratio that fits inside `bounds`, centred.
    ///
    /// A degenerate input yields `.zero` rather than a divide-by-zero — the view reads that as
    /// "nothing to draw yet", which is the truth before the session packet has named a size.
    static func fittedRect(content contentSize: CGSize, in bounds: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width.rounded(),
            height: size.height.rounded(),
        )
    }

    /// A point in panel space → a point in the fitted rect's space, or `nil` when the click landed on
    /// the bars either side of the frame.
    ///
    /// `nil` rather than a clamped edge point: a click beside the device is not a tap on its edge, and
    /// clamping would make the surround a permanently-armed strip that taps the outermost column.
    static func devicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint? {
        guard fitted.width > 0, fitted.height > 0, fitted.contains(point) else { return nil }
        return CGPoint(x: point.x - fitted.minX, y: point.y - fitted.minY)
    }

    /// The same mapping for a point that may have left the frame mid-drag, CLAMPED instead of dropped.
    ///
    /// A drag legitimately runs off the edge — that is how a shade is pulled down and how a swipe-back
    /// finishes — and dropping those moves would freeze the gesture at the boundary while the button
    /// is still held. Only the DOWN that starts a gesture uses the strict form above.
    static func clampedDevicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x - fitted.minX, 0), fitted.width - 1),
            y: min(max(point.y - fitted.minY, 0), fitted.height - 1),
        )
    }

    /// The device-space size that rides on every positional message, as the protocol's `u16`.
    ///
    /// Clamped rather than truncated: the field is 16 bits, and a panel dragged past 65535 points
    /// would otherwise wrap and place every touch at the top-left corner.
    static func surface(fitted: CGRect) -> (width: UInt16, height: UInt16) {
        (clampToUInt16(fitted.width), clampToUInt16(fitted.height))
    }

    static func clampToUInt16(_ value: CGFloat) -> UInt16 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= CGFloat(UInt16.max) ? UInt16.max : UInt16(value)
    }

    static func clampToInt32(_ value: CGFloat) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= CGFloat(Int32.max) { return .max }
        if value <= CGFloat(Int32.min) { return .min }
        return Int32(value)
    }

    /// What a classic wheel NOTCH is worth in points. AppKit reports a trackpad's delta already in
    /// points and a wheel's in LINES, and a line taken as a point is a finger movement of one or two
    /// pixels — under Android's own `touchSlop`, so the device discards it and the panel looks like it
    /// eats scrolls.
    static let pointsPerLine: CGFloat = 32

    /// One scroll event's delta as FINGER TRAVEL, in points.
    ///
    /// SIGN — pass-through, and deliberately so. AppKit has ALREADY applied the user's scroll-direction
    /// preference to `scrollingDeltaY`. `NSEvent.isDirectionInvertedFromDevice` reports the RAW device
    /// direction; folding it in double-applies the preference, and synthesized events report it
    /// `false` regardless of the setting. That trap cost the simulator panel a round and is recorded
    /// in `docs/47`; it is the same event here.
    ///
    /// No un-rotation, for the reason in the file comment: the frame is never drawn turned.
    static func scrollVector(delta: CGSize, isPrecise: Bool) -> CGSize {
        let scale = isPrecise ? 1 : pointsPerLine
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    /// How far a finger has to travel before Android calls it a scroll rather than a tap.
    /// `ViewConfiguration.getScaledTouchSlop()` is 8dp on every current device; the panel uses it to
    /// decide when an accumulated wheel delta is worth a move message at all.
    static let touchSlop: CGFloat = 8

    /// The two contacts a pinch is made of: a pair straddling `centre`, `spread` points apart along the
    /// diagonal. The diagonal rather than the horizontal so a spread has room in both axes on a screen
    /// far taller than it is wide, and clamped inside the frame because a finger past the edge is a
    /// system gesture rather than a zoom.
    static func pinchFingers(
        centre: CGPoint, spread: CGFloat, fitted: CGRect,
    ) -> (CGPoint, CGPoint) {
        let arm = spread / 2 * CGFloat(2.0.squareRoot() / 2)
        let inset: CGFloat = 1
        let clamped = { (point: CGPoint) -> CGPoint in
            CGPoint(
                x: min(max(point.x, inset), max(inset, fitted.width - inset)),
                y: min(max(point.y, inset), max(inset, fitted.height - inset)),
            )
        }
        return (
            clamped(CGPoint(x: centre.x + arm, y: centre.y + arm)),
            clamped(CGPoint(x: centre.x - arm, y: centre.y - arm)),
        )
    }
}
#endif
