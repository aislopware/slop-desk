#if canImport(QuartzCore)
import Foundation
import QuartzCore
import AislopdeskVideoProtocol
#if os(macOS)
import AppKit
#endif

/// Composites the side-channel cursor over the decoded video at display-refresh
/// (doc 17 §3.3 — the highest-impact native-feel technique).
///
/// ⚠️ **GUI-ONLY:** drives a `CALayer`. COMPILED + reviewed; the placement math is
/// pure and unit-testable, the layer wiring is GUI-only.
///
/// Because the host stripped the cursor from the video (`showsCursor=false`) and
/// streams its position over a separate low-latency channel, the client draws the
/// cursor as a `CALayer` (or Metal quad) on TOP of the decoded frame each vsync.
/// Result: **pointer latency = RTT**, fully decoupled from encode/decode (doc 17
/// §3.3). The cursor moves smoothly even while video frames are stale.
///
/// `@MainActor`-isolated: it mutates a `CALayer`, which must be touched on the main
/// thread. The orchestrator actor talks to it through main-actor-hops (the position
/// path) so the hot cursor update lands on the layer at refresh.
@MainActor
public final class ClientCursorCompositor {
    /// The cursor overlay layer (caller adds it above the Metal layer).
    public let cursorLayer: CALayer
    /// Cached cursor shape bitmaps by shapeID (shipped once per new id, doc 17 §3.3).
    private var shapeCache: [UInt16: (image: CGImage, logicalSize: VideoSize)] = [:]
    private var currentShapeID: UInt16?

    public init() {
        cursorLayer = CALayer()
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000 // above the video layer
    }

    #if os(macOS)
    /// Builds a LOCAL `NSCursor` from the cached host shape bitmap + hotspot, for the macOS
    /// "Parsec model": the OS draws the host's cursor SHAPE at the INSTANT local mouse position
    /// (zero added latency), instead of compositing the host's RTT-delayed POSITION as an overlay.
    /// Returns `nil` if the shape isn't cached yet (caller shows the plain arrow until it arrives).
    ///
    /// The image is wrapped at its LOGICAL point size (the CGImage may be a Retina/MTU-downscaled
    /// bitmap) and the hotspot is in host-window points — which equal the NSCursor image points here
    /// because capture is point-resolution — so `NSCursor(image:hotSpot:)` faithfully reproduces the
    /// host pointer (arrow / I-beam / hand / resize / …).
    func makeCursor(shapeID: UInt16, hotspot: VideoPoint) -> NSCursor? {
        guard let cached = shapeCache[shapeID] else { return nil }
        let w = cached.logicalSize.width > 0 ? cached.logicalSize.width : Double(cached.image.width)
        let h = cached.logicalSize.height > 0 ? cached.logicalSize.height : Double(cached.image.height)
        guard w > 0, h > 0 else { return nil }
        let image = NSImage(cgImage: cached.image, size: NSSize(width: w, height: h))
        // Clamp the hotspot into the image bounds (a malformed/oversized hotspot would otherwise
        // make AppKit reject the cursor) — defensive, the wire floats are already finite-checked.
        let hx = min(max(hotspot.x, 0), w)
        let hy = min(max(hotspot.y, 0), h)
        return NSCursor(image: image, hotSpot: NSPoint(x: hx, y: hy))
    }
    #endif

    /// Registers a cursor shape bitmap for a shapeID (the side path delivers these
    /// rarely; the hot ``apply(_:videoScale:)`` path is position-only).
    /// Registers a cursor shape bitmap + its LOGICAL point size for a shapeID. The overlay renders
    /// at `logicalSize` (CALayer scales `contents` to the layer bounds), so a Retina or
    /// MTU-downscaled bitmap shows at the cursor's TRUE size rather than its raw pixel dimensions.
    public func registerShape(_ image: CGImage, logicalSize: VideoSize, for shapeID: UInt16) {
        shapeCache[shapeID] = (image: image, logicalSize: logicalSize)
    }

    /// Computes where the cursor layer should sit, in the client view's coordinate
    /// space, given a host-space ``CursorUpdate`` and the video's display scale
    /// (host-window-points → client-view-points). Pure: returns the frame the layer
    /// should take; unit-testable without a layer.
    ///
    /// - Parameters:
    ///   - update: the host-space cursor position + hotspot.
    ///   - videoScale: client-view-points per host-window-point (1.0 when the remote
    ///     window is displayed 1:1). The hotspot is subtracted so the cursor's
    ///     "tip" lands on the reported position.
    nonisolated public static func layerFrame(for update: CursorUpdate, videoScale: Double, cursorSize: VideoSize) -> VideoRect {
        let x = update.position.x * videoScale - update.hotspot.x
        let y = update.position.y * videoScale - update.hotspot.y
        return VideoRect(x: x, y: y, width: cursorSize.width, height: cursorSize.height)
    }

    /// Aspect-fit + zoom/pan-correct cursor placement: maps the host-space cursor through
    /// the EXACT FORWARD render transform (``AspectFit/viewPoint(forHostPoint:viewSize:videoNativeSize:zoom:pan:)``)
    /// so the overlay tracks the same displayed pixel a click lands on. The hotspot (in
    /// host-window points) is scaled by the displayed-rect's per-point scale before being
    /// subtracted, so the cursor "tip" stays on the reported position at any zoom. Pure.
    ///
    /// Supersedes the scalar ``layerFrame(for:videoScale:cursorSize:)`` (which assumed the
    /// video fills the layer from origin) on the live path; the scalar form is retained as
    /// the underlying math primitive + for the 1:1 fast case.
    nonisolated public static func layerFrame(
        for update: CursorUpdate,
        viewSize: VideoSize,
        videoNativeSize: VideoSize,
        zoom: Double,
        pan: VideoPoint,
        cursorSize: VideoSize,
        mode: VideoContentMode = .fit
    ) -> VideoRect {
        let tip = AspectFit.viewPoint(forHostPoint: update.position, viewSize: viewSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, mode: mode)
        // The hotspot is reported in host-window points; scale it into view points by the
        // displayed-rect's effective per-source-point scale (× zoom for the crop).
        let r = AspectFit.displayedVideoRect(viewSize: viewSize, videoNativeSize: videoNativeSize, mode: mode)
        let scaleX = videoNativeSize.width > 0 ? (r.size.width / videoNativeSize.width) * max(1, zoom) : 1
        let scaleY = videoNativeSize.height > 0 ? (r.size.height / videoNativeSize.height) * max(1, zoom) : 1
        return VideoRect(
            x: tip.x - update.hotspot.x * scaleX,
            y: tip.y - update.hotspot.y * scaleY,
            width: cursorSize.width, height: cursorSize.height)
    }

    /// Applies a cursor update to the overlay layer at display-refresh.
    public func apply(_ update: CursorUpdate, videoScale: Double) {
        let size = applyShape(update)
        guard update.visible else { return }
        let frame = Self.layerFrame(for: update, videoScale: videoScale, cursorSize: size)
        setLayerFrame(frame)
    }

    /// Aspect-fit + zoom/pan-correct apply: places the overlay through the same forward
    /// render transform the input encoder inverts, so the cursor tracks where clicks land
    /// even when the video is letterboxed or (on iOS) zoomed/panned.
    public func apply(_ update: CursorUpdate, viewSize: VideoSize, videoNativeSize: VideoSize, zoom: Double, pan: VideoPoint, mode: VideoContentMode = .fit) {
        let size = applyShape(update)
        guard update.visible else { return }
        let frame = Self.layerFrame(for: update, viewSize: viewSize, videoNativeSize: videoNativeSize, zoom: zoom, pan: pan, cursorSize: size, mode: mode)
        setLayerFrame(frame)
    }

    /// Updates visibility + swaps the cached shape bitmap if the shapeID changed; returns
    /// the current cursor bitmap size (points). Shared by both `apply` overloads.
    private func applyShape(_ update: CursorUpdate) -> VideoSize {
        cursorLayer.isHidden = !update.visible
        if currentShapeID != update.shapeID, let cached = shapeCache[update.shapeID] {
            cursorLayer.contents = cached.image
            // Size the layer by the LOGICAL point size (not the raw bitmap pixels) so the cursor
            // renders at its true size — CALayer scales `contents` to these bounds. Fall back to the
            // bitmap pixels only if the logical size is degenerate (<= 0).
            let w = cached.logicalSize.width > 0 ? cached.logicalSize.width : Double(cached.image.width)
            let h = cached.logicalSize.height > 0 ? cached.logicalSize.height : Double(cached.image.height)
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            currentShapeID = update.shapeID
        }
        return VideoSize(width: cursorLayer.bounds.width, height: cursorLayer.bounds.height)
    }

    /// Converts a TOP-LEFT layer-origin Y (the convention the aspect-fit placement math —
    /// and the input path's `bounds.height - p.y` flip — use) into the BOTTOM-LEFT Y a macOS
    /// layer-backed `NSView` uses for its sublayers (`y' = parentHeight - y - height`). Pure so
    /// the flip is unit-tested without a `CALayer`. iOS `UIView` layers are top-left and never
    /// call this (the placement frame is used as-is).
    nonisolated public static func bottomLeftOriginY(topLeftY: Double, height: Double, parentHeight: Double) -> Double {
        parentHeight - topLeftY - height
    }

    private func setLayerFrame(_ frame: VideoRect) {
        // Belt-and-suspenders: assigning a CALayer frame with a non-finite (NaN/±inf) component
        // raises an uncaught CALayerInvalidGeometry exception that kills the process. The codec now
        // rejects non-finite wire floats (readFiniteFloat64), so a malformed cursor datagram is
        // dropped upstream; this guard also covers any NaN that could arise from degenerate
        // aspect-fit math (e.g. a zero video/view dimension) — skip the update rather than crash.
        let r = frame.cgRect
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.size.width.isFinite, r.size.height.isFinite else { return }
        var placed = r
        #if os(macOS)
        // The overlay layer is a sublayer of the macOS `CAMetalLayer`, whose host view sets
        // neither `isFlipped` nor `isGeometryFlipped` → its sublayer coordinate space is
        // BOTTOM-LEFT (+Y up). The placement math returns a TOP-LEFT frame (the same space the
        // input path flips into via `bounds.height - p.y`), so writing it verbatim mirrors the
        // cursor vertically — it tracks the wrong pixel and looks badly offset from where clicks
        // land ("con trỏ client/server lệch rất nhiều"). Flip Y into the parent's bottom-left
        // space so the composited cursor sits on the SAME pixel the input encoder targets.
        // (Reads the live parent bounds in POINTS — the sublayer frame is in the parent's point
        // space, not the pixel `drawableSize`.) iOS `UIView` layers are already top-left → no flip.
        if let parentHeight = cursorLayer.superlayer?.bounds.height, parentHeight > 0 {
            placed.origin.y = Self.bottomLeftOriginY(topLeftY: r.origin.y, height: r.size.height, parentHeight: parentHeight)
        }
        #endif
        // No implicit animation — the cursor must track at refresh, not tween.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = placed
        CATransaction.commit()
    }
}
#endif
