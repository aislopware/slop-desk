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
// ## ⚠️ The server does NOT rescale a positional message. It DROPS it.
//
// This panel first shipped believing the opposite — that a touch could be sent in the fitted rect's
// own space paired with that rect's size, and `scrcpy` would scale it — and the result was a mirror
// where the toolbar buttons worked and nothing on the frame did. `PositionMapper` in the 4.1 jar
// compares the pair on the wire against the size it is CURRENTLY encoding and, on any difference,
// logs `Ignore positional event generated for size … (current size is …)` and returns null. It reads
// a mismatch as an event generated against a stale geometry — a touch made just before the device
// rotated — and discarding those is the point of the check.
//
// So every positional message must be in the DEVICE's own pixel grid, paired with the exact size of
// the video being encoded. That size is not something this file can derive from the panel: it comes
// off the wire in the session packet (``AndroidStreamMessage/session(width:height:)``), and it is not
// the device's screen either — `max_size` scales the encode down. ``Surface`` carries the pair, and
// nothing may send a positional message without one.

#if os(macOS)
import CoreGraphics

package enum AndroidScreenLayout {
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
    package static func clampedDevicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint {
        DevicePanelGeometry.clampedDevicePoint(from: point, fitted: fitted)
    }

    /// The two geometries a positional message needs at once: where the frame is drawn, and what the
    /// device is actually encoding.
    ///
    /// Gestures are measured in the FITTED rect, because that is where the pointer is. They are SENT
    /// in the video's own pixels, because that is the only grid the server will accept (see the file
    /// comment). Keeping both in one value is what stops the two from being paired by accident: there
    /// is no way to reach the size on the wire without also having the rect it must be converted from.
    package struct Surface: Equatable {
        /// Where the frame sits in the panel, in points.
        package let fitted: CGRect
        /// The size the server is encoding right now, in its own pixels — the session packet's
        /// numbers, NOT the device's screen size, which `max_size` scales down from.
        package let video: CGSize

        /// False while the stream has not yet named a size, or the panel is too small to draw in. A
        /// message built from an unusable surface would be discarded by the device anyway.
        package var isUsable: Bool {
            DevicePanelGeometry.surfaceIsUsable(fitted: fitted, video: video)
        }

        /// The pair that rides on the wire, as the protocol's `u16`. Clamped rather than truncated:
        /// the field is 16 bits, and a size past 65535 would wrap and place every touch at the origin.
        package init(fitted: CGRect, video: CGSize) {
            self.fitted = fitted
            self.video = video
        }

        package var width: UInt16 { clampToUInt16(video.width) }
        package var height: UInt16 { clampToUInt16(video.height) }

        /// A point in the fitted rect's own space → the video's pixel grid — shared, see
        /// ``DevicePanelGeometry/videoPixels(_:fitted:video:)``.
        package func pixels(_ point: CGPoint) -> CGPoint {
            DevicePanelGeometry.videoPixels(point, fitted: fitted, video: video)
        }
    }

    package static func clampToUInt16(_ value: CGFloat) -> UInt16 {
        DevicePanelGeometry.clampToUInt16(value)
    }

    package static func clampToInt32(_ value: CGFloat) -> Int32 {
        DevicePanelGeometry.clampToInt32(value)
    }

    /// What a classic wheel NOTCH is worth in points — shared, see
    /// ``DevicePanelGeometry/pointsPerLine``.
    package static var pointsPerLine: CGFloat { DevicePanelGeometry.pointsPerLine }

    /// One scroll event's delta as FINGER TRAVEL, in points — shared, see
    /// ``DevicePanelGeometry/scrollVector(delta:isPrecise:)``, which carries the note about why the
    /// SIGN is pass-through.
    ///
    /// No un-rotation, for the reason in the file comment: the frame is never drawn turned. That is
    /// the whole difference between this call and the simulator panel's.
    package static func scrollVector(delta: CGSize, isPrecise: Bool) -> CGSize {
        DevicePanelGeometry.scrollVector(delta: delta, isPrecise: isPrecise)
    }

    /// A pinch's two contacts — shared, see ``DevicePanelGeometry/pinchFingers(centre:spread:fitted:)``.
    package static func pinchFingers(
        centre: CGPoint, spread: CGFloat, fitted: CGRect,
    ) -> (CGPoint, CGPoint) {
        DevicePanelGeometry.pinchFingers(centre: centre, spread: spread, fitted: fitted)
    }
}
#endif
