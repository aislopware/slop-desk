import Foundation

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
    ///
    /// Native Swift, byte-identical to `geometry::VideoRect::intersection_area`. The
    /// Rust core uses NaN-ignoring `f64::max`/`f64::min`, mirrored here with the IEEE
    /// `Double.maximum`/`Double.minimum` static forms (NOT `Swift.max`/`Swift.min`,
    /// which propagate NaN) so any NaN handling matches the core bit-for-bit.
    public func intersectionArea(_ other: Self) -> Double {
        let ix = Double.maximum(0, Double.minimum(maxX, other.maxX) - Double.maximum(minX, other.minX))
        let iy = Double.maximum(0, Double.minimum(maxY, other.maxY) - Double.maximum(minY, other.minY))
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
        // Native Swift — the single source of truth shared with the renderer's quad scale.
        // Byte-identical to `geometry::aspect_fit::displayed_video_rect`.
        let vw = videoNativeSize.width, vh = videoNativeSize.height
        let capW = viewSize.width, capH = viewSize.height
        guard vw > 0, vh > 0, capW > 0, capH > 0 else {
            return VideoRect(x: 0, y: 0, width: Double.maximum(0, capW), height: Double.maximum(0, capH))
        }
        // `.fit` scales to the SMALLER axis ratio (contain → the whole video sits inside,
        // bars on the longer axis). `.fill` scales to the LARGER axis ratio (cover → the
        // video fills the view, the longer axis overflows and is cropped). Both use a single
        // uniform `scale`, so neither distorts the aspect. NaN-ignoring IEEE min/max mirrors
        // the core's `f64::min`/`f64::max` (inputs are guarded positive, so this is moot here
        // but stays faithful to the Rust reference).
        let scaleX = capW / vw, scaleY = capH / vh
        let scale = (mode == .fit) ? Double.minimum(scaleX, scaleY) : Double.maximum(scaleX, scaleY)
        let w = vw * scale, h = vh * scale
        let ox = (capW - w) / 2
        let oy = (capH - h) / 2
        return VideoRect(x: ox, y: oy, width: w, height: h)
    }

    /// FORWARD render transform: maps a host-window-space point (points) to where it is
    /// drawn in the layer's view space (points). This is the exact inverse of
    /// ``SlopDeskVideoClient/InputEventEncoder/normalize(viewPoint:layerSize:videoNativeSize:zoom:pan:)``
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
        // Native Swift — the exact inverse of the input encoder's `normalize`, derived from
        // the same source so they can never drift. Byte-identical to
        // `geometry::aspect_fit::view_point`.
        let su = videoNativeSize.width > 0 ? hostPoint.x / videoNativeSize.width : 0
        let sv = videoNativeSize.height > 0 ? hostPoint.y / videoNativeSize.height : 0
        let z = Double.maximum(1, zoom)
        let invZoom = 1 / z
        // keep mul+add separate — FMA breaks bit-exact golden parity
        let panLimit = 0.5 * (1 - invZoom)
        // NaN-ignoring clamp — the core deliberately uses `f64::max`/`f64::min` so a NaN pan
        // clamps to ±panLimit (a finite coordinate). Use IEEE `Double.maximum`/`Double.minimum`,
        // NOT `Swift.max`/`Swift.min` (which would poison NaN → NaN as the pre-port Swift did).
        // See the core's pan-clamp NOTE: the finite-clamping behaviour is the one we keep.
        let px = Double.minimum(Double.maximum(pan.x, -panLimit), panLimit)
        let py = Double.minimum(Double.maximum(pan.y, -panLimit), panLimit)
        // keep mul+add separate — FMA breaks bit-exact golden parity
        let du = (su - 0.5 - px) * z + 0.5
        let dv = (sv - 0.5 - py) * z + 0.5
        let r = displayedVideoRect(viewSize: viewSize, videoNativeSize: videoNativeSize, mode: mode)
        // keep mul+add separate — FMA breaks bit-exact golden parity
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
