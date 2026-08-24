import CSlopDeskFFI

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pure 2-D point (host-space, points). Mirrors `CGPoint` but carries no platform
/// dependency, so `SlopDeskVideoProtocol` stays a leaf that compiles for macOS + iOS
/// and is unit-testable in isolation. Bridges to/from `CGPoint` where CoreGraphics
/// is available.
public struct VideoPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x
        self.y = y
    }
}

/// A pure 2-D size (points).
public struct VideoSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width
        self.height = height
    }

    /// The record this size crosses as.
    var crossing: SlopDeskVideoSize { SlopDeskVideoSize(width: width, height: height) }
}

/// A pure rectangle (origin + size), in whatever coordinate space the caller states.
public struct VideoRect: Equatable, Sendable {
    public var origin: VideoPoint
    public var size: VideoSize
    public init(origin: VideoPoint, size: VideoSize) { self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = VideoPoint(x: x, y: y)
        size = VideoSize(width: width, height: height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    /// The area of intersection with `other` (0 when disjoint).
    ///
    /// No Swift caller: the multi-monitor screen pick that used to ask this now runs entirely inside
    /// `rust/slopdesk-video`'s `coordinate_mapping`. The face stays because `slopdesk-invariants` pins it
    /// — the crate's NaN-ignoring maxima are what land a degenerate rect on a finite answer instead of
    /// poisoning the pick, and a Swift `max(0, …)` written in its place would not do that.
    public func intersectionArea(_ other: Self) -> Double {
        slopdesk_geometry_intersection_area(crossing, other.crossing)
    }

    /// The record this rect crosses as.
    var crossing: SlopDeskVideoRect {
        SlopDeskVideoRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}

/// How the decoded video is scaled into the on-screen layer (doc 17 §3.7). BOTH modes
/// PRESERVE the native aspect ratio — neither stretches/distorts:
/// - `.fit` (default) letterboxes/pillarboxes: the WHOLE remote window is visible, with
///   black bars on the longer axis when the pane's aspect differs.
/// - `.fill` covers the pane: NO bars, the video is scaled up until it covers the whole
///   pane and the overflowing axis is cropped by the viewport.
/// The user toggles between them ("nút fill"); `zoom`/`pan` then navigate within either
/// (e.g. pan to reach the cropped edges in `.fill`, or zoom in to read in `.fit`).
public enum VideoContentMode: Sendable, Equatable {
    case fit
    case fill

    /// The code this mode crosses as. Public because the cursor overlay asks the SAME transform
    /// from another module, and a second spelling of two cases is what lets them drift apart.
    public var code: UInt32 { self == .fill ? SLOPDESK_CONTENT_MODE_FILL : SLOPDESK_CONTENT_MODE_FIT }
}

/// Aspect geometry — the **single source of truth** for where the decoded video is
/// actually drawn inside the layer (doc 17 §3.7). The Metal renderer scales the frame
/// (letterbox in `.fit`, cover-crop in `.fill`) so the video occupies a centred rect of
/// the layer; both the renderer (`fit` quad scale) and the input/cursor mapping derive
/// their geometry from this one function so render-forward and input-inverse can never
/// drift — including across a fit↔fill toggle.
///
/// Pure + platform-free (lives in the protocol leaf) so it is unit-testable in isolation
/// and usable from both `SlopDeskVideoClient` (renderer + input encoder + cursor compositor).
public enum AspectFit {
    /// The rect (origin + size) the displayed video occupies inside a `viewSize` layer,
    /// preserving the video's native aspect ratio. In `.fit` the rect is CONTAINED in the
    /// view (centred, with letterbox/pillarbox bars). In `.fill` the rect COVERS the view
    /// (centred, can exceed the view → negative origin / size > view; that overflow is the
    /// crop). Either way the rect is the exact region the renderer maps the full texture
    /// onto, and the region `normalize` inverts — so they always agree.
    ///
    /// MUST match `MetalVideoRenderer`'s `fit`-branch exactly: the renderer computes the
    /// same ratios in PIXELS (drawableSize × video pixel size), but aspect ratio is
    /// scale-invariant, so the rect is identical whether measured in points or pixels.
    ///
    /// - Parameters:
    ///   - viewSize: the layer's size (points, or pixels — scale-invariant).
    ///   - videoNativeSize: the decoded video's native size (same unit family).
    ///   - mode: `.fit` (contain, letterbox) or `.fill` (cover, crop). Default `.fit`.
    /// - Returns: the centred displayed-video rect. Falls back to the full `viewSize`
    ///   rect for any non-positive dimension (degenerate input is placed sensibly).
    public static func displayedVideoRect(
        viewSize: VideoSize,
        videoNativeSize: VideoSize,
        mode: VideoContentMode = .fit,
    ) -> VideoRect {
        // The single source of truth shared with the renderer's quad scale — `geometry`'s, through
        // the door, so the two can never be two.
        let rect = slopdesk_geometry_displayed_video_rect(
            viewSize.crossing, videoNativeSize.crossing, mode.code,
        )
        return VideoRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// FORWARD render transform: maps a host-window-space point (points) to where it is
    /// drawn in the layer's view space (points). This is the exact inverse of
    /// ``SlopDeskVideoClient/InputEventEncoder/normalize(viewPoint:layerSize:videoNativeSize:zoom:pan:)``
    /// and the renderer's aspect-fit + zoom/pan crop, used to place the local cursor
    /// overlay where clicks actually land (doc 17 §3.3 / §3.7).
    ///
    /// 1. host point → source 0..1 (`hostPoint / videoNativeSize`).
    /// 2. invert the renderer's zoom/pan crop, giving the displayed 0..1 coordinate.
    /// 3. that coordinate → a view point inside the aspect-fit displayed rect.
    /// Pan is clamped exactly as the renderer clamps it. The three steps and the clamp are the
    /// crate's; see `geometry::view_point` for the arithmetic they are written in.
    public static func viewPoint(
        forHostPoint hostPoint: VideoPoint,
        viewSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
    ) -> VideoPoint {
        // The exact inverse of the input encoder's `normalize`, derived from the same source so
        // they can never drift — `geometry`'s, through the door. The separate multiplies and the
        // NaN-ignoring pan clamp are the crate's, and this number is golden-pinned.
        let answer = slopdesk_geometry_view_point(
            SlopDeskVideoPoint(x: hostPoint.x, y: hostPoint.y),
            viewSize.crossing, videoNativeSize.crossing, zoom,
            SlopDeskVideoPoint(x: pan.x, y: pan.y), mode.code,
        )
        return VideoPoint(x: answer.x, y: answer.y)
    }
}

#if canImport(CoreGraphics)
public extension VideoPoint {
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public extension VideoSize {
    init(_ s: CGSize) { self.init(width: Double(s.width), height: Double(s.height)) }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

public extension VideoRect {
    init(_ r: CGRect) {
        self.init(
            x: Double(r.origin.x),
            y: Double(r.origin.y),
            width: Double(r.size.width),
            height: Double(r.size.height),
        )
    }

    var cgRect: CGRect { CGRect(x: minX, y: minY, width: size.width, height: size.height) }
}
#endif
