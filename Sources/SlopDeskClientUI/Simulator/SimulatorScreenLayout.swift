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
import Foundation

enum SimulatorScreenLayout {
    /// The largest rect with `contentSize`'s aspect ratio that fits inside `bounds`, centred.
    ///
    /// A degenerate input (either dimension zero) yields `.zero` rather than a divide-by-zero or an
    /// infinite rect — the view reads that as "nothing to draw yet", which is the truth before the
    /// first frame arrives and the content size is still unknown.
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
    /// `nil` rather than a clamped edge point on purpose: a click beside the device is not a tap on
    /// its edge, and clamping would make the bezel a permanently-armed strip that taps the outermost
    /// row of pixels.
    static func devicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint? {
        guard fitted.width > 0, fitted.height > 0, fitted.contains(point) else { return nil }
        return CGPoint(x: point.x - fitted.minX, y: point.y - fitted.minY)
    }

    /// The surface descriptor that rides on every positional envelope: the fitted rect's own size, so
    /// the host scales from the space the coordinates were actually measured in.
    static func surface(fitted: CGRect) -> SimulatorInputEnvelope.Surface {
        SimulatorInputEnvelope.Surface(width: fitted.width, height: fitted.height)
    }

    /// What a classic wheel NOTCH is worth in points. AppKit reports a trackpad's delta already in
    /// points and a wheel's in LINES, and a line taken as a point is a swipe of one or two pixels —
    /// under iOS's own pan slop, so the device ignores it entirely and the panel looks like it eats
    /// scrolls. Set ABOVE ``swipeStep`` on purpose — one detent of a physical wheel has to scroll,
    /// never bank against the next one.
    static let pointsPerLine: CGFloat = 32

    /// How far the accumulated scroll must travel before it is sent as one swipe. Two jobs: it clears
    /// iOS's pan slop (a swipe under ~10 pt is not a pan at all), and it rate-limits a trackpad —
    /// which emits a delta per frame, and would otherwise put sixty swipes a second on the wire.
    static let swipeStep: CGFloat = 24

    /// One scroll event's delta as a SWIPE VECTOR in points — the direction a finger should travel on
    /// the device. Measured 2026-08-04 against a live device; getting this wrong produces a panel that
    /// scrolls backwards or not at all.
    ///
    /// SCALE. `isPrecise` is `NSEvent.hasPreciseScrollingDeltas`: a trackpad reports points and is
    /// used as-is, a classic wheel reports LINES and is scaled by ``pointsPerLine``.
    ///
    /// SIGN — pass-through, and deliberately so. AppKit has ALREADY applied the user's scroll-direction
    /// preference to `scrollingDeltaY`: a positive value always means "move toward the top of the
    /// document", whichever way the fingers physically went. On a touch surface that is a finger
    /// travelling DOWN the screen, which in this view's flipped space is +y — so the delta maps
    /// straight onto the swipe. `NSEvent.isDirectionInvertedFromDevice` reports the RAW device
    /// direction and is informational; folding it in here double-applies the preference, and
    /// synthesized events report it `false` regardless of the setting. Measured both ways 2026-08-04:
    /// with the flag folded in, one scroll gesture moved the device's list opposite to the way the
    /// same gesture moved a native scroll view in the same window.
    static func swipeVector(delta: CGSize, isPrecise: Bool) -> CGSize {
        let scale = isPrecise ? 1 : pointsPerLine
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    /// A swipe vector becomes an end point from the pointer. Returns `nil` when the gesture is too
    /// small to be intentional, so wheel jitter does not fire a swipe per tick — the caller banks the
    /// leftover rather than dropping it.
    ///
    /// The end point is clamped INSIDE the rect: a swipe that ends past the edge is a system gesture
    /// on iOS (app switcher, control centre), which is not what someone scrolling a list meant.
    static func swipeEnd(
        from origin: CGPoint, delta: CGSize, fitted: CGRect, minimumDistance: CGFloat = swipeStep,
    ) -> CGPoint? {
        guard abs(delta.width) + abs(delta.height) >= minimumDistance else { return nil }
        let unclamped = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
        let inset: CGFloat = 1
        return CGPoint(
            x: min(max(unclamped.x, inset), fitted.width - inset),
            y: min(max(unclamped.y, inset), fitted.height - inset),
        )
    }
}
#endif
