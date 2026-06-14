import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pure 2-D point (host-space, points). Mirrors `CGPoint` but carries no platform
/// dependency, so `AislopdeskVideoProtocol` stays a leaf that compiles for macOS + iOS
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

    /// The area of intersection with `other` (0 when disjoint). Used by the
    /// multi-monitor coordinate-mapping screen pick.
    public func intersectionArea(_ other: Self) -> Double {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        return ix * iy
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
}

/// Aspect geometry — the **single source of truth** for where the decoded video is
/// actually drawn inside the layer (doc 17 §3.7). The Metal renderer scales the frame
/// (letterbox in `.fit`, cover-crop in `.fill`) so the video occupies a centred rect of
/// the layer; both the renderer (`fit` quad scale) and the input/cursor mapping derive
/// their geometry from this one function so render-forward and input-inverse can never
/// drift — including across a fit↔fill toggle.
///
/// Pure + platform-free (lives in the protocol leaf) so it is unit-testable in isolation
/// and usable from both `AislopdeskVideoClient` (renderer + input encoder + cursor compositor).
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
        let vw = videoNativeSize.width, vh = videoNativeSize.height
        let viewW = viewSize.width, viewH = viewSize.height
        guard vw > 0, vh > 0, viewW > 0, viewH > 0 else {
            return VideoRect(x: 0, y: 0, width: max(0, viewW), height: max(0, viewH))
        }
        // `.fit` scales to the SMALLER axis ratio (contain → the whole video sits inside,
        // bars on the longer axis). `.fill` scales to the LARGER axis ratio (cover → the
        // video fills the view, the longer axis overflows and is cropped). Both use a single
        // uniform `scale`, so neither distorts the aspect.
        let scaleX = viewW / vw, scaleY = viewH / vh
        let scale = (mode == .fit) ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let w = vw * scale, h = vh * scale
        let ox = (viewW - w) / 2
        let oy = (viewH - h) / 2
        return VideoRect(x: ox, y: oy, width: w, height: h)
    }

    /// FORWARD render transform: maps a host-window-space point (points) to where it is
    /// drawn in the layer's view space (points). This is the exact inverse of
    /// ``AislopdeskVideoClient/InputEventEncoder/normalize(viewPoint:layerSize:videoNativeSize:zoom:pan:)``
    /// and the renderer's aspect-fit + zoom/pan crop, used to place the local cursor
    /// overlay where clicks actually land (doc 17 §3.3 / §3.7).
    ///
    /// 1. host point → source 0..1 (`hostPoint / videoNativeSize`).
    /// 2. invert the renderer's crop (`uv = (in.uv-0.5)·invZoom + 0.5 + pan`):
    ///    `displayUV = (sourceUV - 0.5 - pan)·zoom + 0.5`.
    /// 3. displayUV → view point inside the aspect-fit displayed rect.
    /// Pan is clamped identically to the renderer (`panLimit = 0.5·(1-invZoom)`).
    public static func viewPoint(
        forHostPoint hostPoint: VideoPoint,
        viewSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double = 1,
        pan: VideoPoint = VideoPoint(x: 0, y: 0),
        mode: VideoContentMode = .fit,
    ) -> VideoPoint {
        let su = videoNativeSize.width > 0 ? hostPoint.x / videoNativeSize.width : 0
        let sv = videoNativeSize.height > 0 ? hostPoint.y / videoNativeSize.height : 0
        let z = max(1, zoom)
        let invZoom = 1 / z
        let panLimit = 0.5 * (1 - invZoom)
        let px = min(max(pan.x, -panLimit), panLimit)
        let py = min(max(pan.y, -panLimit), panLimit)
        let du = (su - 0.5 - px) * z + 0.5
        let dv = (sv - 0.5 - py) * z + 0.5
        let r = displayedVideoRect(viewSize: viewSize, videoNativeSize: videoNativeSize, mode: mode)
        return VideoPoint(x: r.origin.x + du * r.size.width, y: r.origin.y + dv * r.size.height)
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
