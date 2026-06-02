#if canImport(QuartzCore)
import Foundation
import QuartzCore
import RworkVideoProtocol

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
public final class ClientCursorCompositor {
    /// The cursor overlay layer (caller adds it above the Metal layer).
    public let cursorLayer: CALayer
    /// Cached cursor shape bitmaps by shapeID (shipped once per new id, doc 17 §3.3).
    private var shapeCache: [UInt16: CGImage] = [:]
    private var currentShapeID: UInt16?

    public init() {
        cursorLayer = CALayer()
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000 // above the video layer
    }

    /// Registers a cursor shape bitmap for a shapeID (the side path delivers these
    /// rarely; the hot ``apply(_:videoScale:)`` path is position-only).
    public func registerShape(_ image: CGImage, for shapeID: UInt16) {
        shapeCache[shapeID] = image
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
    public static func layerFrame(for update: CursorUpdate, videoScale: Double, cursorSize: VideoSize) -> VideoRect {
        let x = update.position.x * videoScale - update.hotspot.x
        let y = update.position.y * videoScale - update.hotspot.y
        return VideoRect(x: x, y: y, width: cursorSize.width, height: cursorSize.height)
    }

    /// Applies a cursor update to the overlay layer at display-refresh.
    public func apply(_ update: CursorUpdate, videoScale: Double) {
        cursorLayer.isHidden = !update.visible
        guard update.visible else { return }
        if currentShapeID != update.shapeID, let image = shapeCache[update.shapeID] {
            cursorLayer.contents = image
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            currentShapeID = update.shapeID
        }
        let size = VideoSize(width: cursorLayer.bounds.width, height: cursorLayer.bounds.height)
        let frame = Self.layerFrame(for: update, videoScale: videoScale, cursorSize: size)
        // No implicit animation — the cursor must track at refresh, not tween.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = frame.cgRect
        CATransaction.commit()
    }
}
#endif
