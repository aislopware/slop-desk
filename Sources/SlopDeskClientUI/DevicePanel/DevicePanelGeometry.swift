#if os(macOS)
import CoreGraphics
import SlopDeskVideoProtocol

/// The three laws the simulator panel and the Android panel share: where a device's frame sits in a
/// sidebar, what a click in that sidebar means, and where a pinch's two contacts go.
///
/// The two panels diverge in almost everything else and should — the simulator's framebuffer never
/// rotates so its deltas must be un-rotated, `scrcpy` rotates on the device so they must not; the
/// Android lane sends touches in the video's own pixel grid because the server DROPS a mismatched
/// pair, the simulator lane sends them in the fitted rect's space because the host rescales. Those
/// are different protocols and they read as different files.
///
/// These three were not different. They were the same arithmetic twice, and the kind that fails
/// quietly: a tap two rows off, a pinch whose contacts leave the frame. Both files said so — "this
/// is the part that can be wrong in a way nobody notices until a tap lands two rows off" — in the
/// two places where it could be wrong two different ways.
enum DevicePanelGeometry {
    /// The largest rect with `contentSize`'s aspect ratio that fits inside `bounds`, centred and
    /// rounded to whole points.
    ///
    /// The ratio itself is `slopdesk-video::geometry::displayed_video_rect` through the door, which
    /// is the SAME law the desktop video client's renderer, input encoder and cursor overlay invert.
    /// Three panels computing an aspect fit three ways is how a click ends up beside the pixel it
    /// was drawn for; `docs/DECISIONS.md` has the entry for why that arithmetic is Rust and stays
    /// bit-exact.
    ///
    /// What stays here is the panel's own contract, which the video client does not share: a
    /// degenerate input answers `.zero` — the view reads that as "nothing to draw yet", the truth
    /// before the first frame — where the door answers the full view rect, and the result is rounded
    /// to whole points because a device frame is drawn on a pixel grid.
    static func fittedRect(content contentSize: CGSize, in bounds: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let rect = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: bounds.width, height: bounds.height),
            videoNativeSize: VideoSize(width: contentSize.width, height: contentSize.height),
            mode: .fit,
        )
        return CGRect(
            x: rect.origin.x.rounded(),
            y: rect.origin.y.rounded(),
            width: rect.size.width.rounded(),
            height: rect.size.height.rounded(),
        )
    }

    /// A point in panel space → a point in the fitted rect's space, or `nil` when the click landed
    /// on the bars either side of the frame.
    ///
    /// `nil` rather than a clamped edge point on purpose: a click beside the device is not a tap on
    /// its edge, and clamping would make the surround a permanently-armed strip that taps the
    /// outermost row of pixels.
    static func devicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint? {
        guard fitted.width > 0, fitted.height > 0, fitted.contains(point) else { return nil }
        return CGPoint(x: point.x - fitted.minX, y: point.y - fitted.minY)
    }

    /// The two contacts a pinch is made of: a pair straddling `centre`, `spread` points apart along
    /// the diagonal. The diagonal rather than the horizontal so a spread has room in both axes on a
    /// screen that is far taller than it is wide, and clamped inside the frame because a finger past
    /// the edge is a system gesture rather than a zoom.
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

    // MARK: - Where a synthetic finger may be planted

    /// How far in from the frame's edge a synthetic contact must stay.
    ///
    /// Planting ON the boundary puts the contact inside the platform's own system-gesture band — the
    /// home indicator and the pull-down shades on iOS, the gesture-navigation strip on Android — so
    /// a scroll would read as a Back or a Home. The number is the same on both because it is a
    /// property of a finger, not of an OS.
    static let edgeMargin: CGFloat = 24

    /// `point`, moved inside the frame by ``edgeMargin``.
    ///
    /// The fallback is the CENTRE of the axis, for a frame too small to hold two margins: a sliver
    /// has no valid band, and the middle is the only place that is not an edge.
    static func planted(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: clamp(point.x, low: edgeMargin, high: fitted.width - edgeMargin, fallback: fitted.width / 2),
            y: clamp(point.y, low: edgeMargin, high: fitted.height - edgeMargin, fallback: fitted.height / 2),
        )
    }

    /// Where the finger lands after running out of screen: at the far end of the axis it was
    /// travelling along, so the next stretch of the same gesture has the full height to move through.
    ///
    /// This is a hand lifting and planting again, which is what makes a long scroll one gesture
    /// rather than a series of unrelated flicks — and both panels reconstruct a real finger for the
    /// same reason, however differently they then spell the contact on the wire.
    static func regrip(travel: CGSize, in fitted: CGRect) -> CGPoint {
        let far = { (extent: CGFloat, direction: CGFloat) -> CGFloat in
            direction >= 0 ? edgeMargin : extent - edgeMargin
        }
        let isVertical = abs(travel.height) >= abs(travel.width)
        return planted(
            CGPoint(
                x: isVertical ? fitted.width / 2 : far(fitted.width, travel.width),
                y: isVertical ? far(fitted.height, travel.height) : fitted.height / 2,
            ),
            in: fitted,
        )
    }

    private static func clamp(
        _ value: CGFloat, low: CGFloat, high: CGFloat, fallback: CGFloat,
    ) -> CGFloat {
        guard low <= high else { return fallback }
        return min(max(value, low), high)
    }
}
#endif
