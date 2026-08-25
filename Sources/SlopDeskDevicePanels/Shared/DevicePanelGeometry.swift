// DevicePanelGeometry — where a device's frame sits in a sidebar, and what a point in it means.
//
// The LAWS live in `slopdesk_devicepanel::geometry`. What is left on this side is `CGRect`/`CGPoint`
// becoming the door's records and back — a struct copy either way, no allocation, nothing to free.
//
// ## Why they moved
//
// This is the part of a device panel that fails QUIETLY: both Swift files said "this is the part
// that can be wrong in a way nobody notices until a tap lands two rows off", in the two places where
// it could be wrong two different ways. The aspect fit is now the SAME function the desktop video
// client's renderer, input encoder and cursor overlay invert — a third answer to that question is
// how a click ends up beside the pixel it was drawn for.
//
// ## What the two panels still do not share, and should not
//
// The Android lane sends touches in the video's own pixel grid because the server DROPS a mismatched
// pair; the simulator lane sends them in the fitted rect's space because the host rescales. Those are
// different protocols, and they read as different files calling different doors.
//
// The scroll machine used to be half here — the wheel's scale, the quarter turn the simulator's
// never-rotating framebuffer needs undone, the plant and the re-grip. It is now `SimulatorScrollGesture`
// and `AndroidScrollGesture`, both handles over `slopdesk_panel_scroll_accept`, which applies all four
// inside Rust. The un-rotation survives as that door's `angle` argument: the simulator passes its
// orientation's, the Android lane passes zero because `scrcpy` rotates on the device.

import CoreGraphics
import CSlopDeskFFI

package enum DevicePanelGeometry {
    // MARK: Where the frame is, and what a point in it means

    /// The largest rect with `contentSize`'s aspect ratio that fits inside `bounds`, centred and
    /// rounded to whole points. A degenerate input answers `.zero` — the truth before the first
    /// frame, which the view reads as "nothing to draw yet".
    package static func fittedRect(content contentSize: CGSize, in bounds: CGSize) -> CGRect {
        read(slopdesk_panel_fitted_rect(lent(contentSize), lent(bounds)))
    }

    /// A point in panel space in the fitted rect's own space, or `nil` when the click landed on the
    /// bars either side of the frame.
    ///
    /// `nil` rather than a clamped edge point on purpose: a click beside the device is not a tap on
    /// its edge, and clamping would make the surround a permanently-armed strip that taps the
    /// outermost row of pixels.
    package static func devicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint? {
        var answer = SlopDeskVideoPoint()
        guard slopdesk_panel_device_point(lent(point), lent(fitted), &answer) else { return nil }
        return read(answer)
    }

    /// The same mapping for a point that may have left the frame mid-drag, CLAMPED instead of
    /// dropped.
    ///
    /// A drag legitimately runs off the edge — that is how a shade is pulled down and how a
    /// swipe-back finishes — and dropping those would freeze the gesture at the boundary while the
    /// button is still held. Only the DOWN that starts a gesture uses the strict form above.
    package static func clampedDevicePoint(from point: CGPoint, fitted: CGRect) -> CGPoint {
        read(slopdesk_panel_clamped_device_point(lent(point), lent(fitted)))
    }

    /// A point in the fitted rect's own space, in the video's pixel grid — the only grid `scrcpy`
    /// will accept a positional message in.
    package static func videoPixels(_ point: CGPoint, fitted: CGRect, video: CGSize) -> CGPoint {
        read(slopdesk_panel_video_pixels(lent(point), lent(fitted), lent(video)))
    }

    /// Whether a positional message may be built at all: a frame drawn somewhere, and a stream that
    /// has named what it is encoding.
    package static func surfaceIsUsable(fitted: CGRect, video: CGSize) -> Bool {
        slopdesk_panel_surface_is_usable(lent(fitted), lent(video))
    }

    // MARK: Multi-touch

    /// The two contacts a pinch is made of: a pair straddling `centre`, `spread` points apart along
    /// the diagonal. The diagonal rather than the horizontal so a spread has room in both axes on a
    /// screen far taller than it is wide, and clamped inside the frame because a finger past the
    /// edge is a system gesture rather than a zoom.
    package static func pinchFingers(
        centre: CGPoint, spread: CGFloat, fitted: CGRect,
    ) -> (CGPoint, CGPoint) {
        let pair = slopdesk_panel_pinch_fingers(lent(centre), spread, lent(fitted))
        return (read(pair.first), read(pair.second))
    }

    // MARK: Edges

    /// A system edge a contact can start on — the hint that lets the host drive the home indicator,
    /// the app switcher and the pull-down shades from a drag instead of only from a button.
    package enum SystemEdge: String {
        case bottom
        case top
    }

    /// Which system edge, if any, a contact starting at `point` belongs to.
    ///
    /// `isUpsideDown` is the case that is not a rotation of the others: the physical bottom edge
    /// lands on visual LEFT, so the bands swap axes. The landscape cases deliberately do not — the
    /// framebuffer stays portrait whichever way the device is held, and the home indicator stays on
    /// the same framebuffer edge.
    package static func systemEdge(
        at point: CGPoint, fitted: CGRect, isUpsideDown: Bool,
    ) -> SystemEdge? {
        switch slopdesk_panel_system_edge(lent(point), lent(fitted), isUpsideDown) {
        case UInt32(SLOPDESK_PANEL_EDGE_BOTTOM): .bottom
        case UInt32(SLOPDESK_PANEL_EDGE_TOP): .top
        default: nil
        }
    }

    // MARK: The wire's geometry fields

    /// A size as the protocol's `u16`. Clamped rather than truncated: the field is 16 bits, and a
    /// size past 65535 would wrap and place every touch at the origin.
    package static func clampToUInt16(_ value: CGFloat) -> UInt16 {
        slopdesk_panel_clamp_u16(Double(value))
    }

    /// A coordinate as the protocol's `i32`, saturating at both ends.
    package static func clampToInt32(_ value: CGFloat) -> Int32 {
        slopdesk_panel_clamp_i32(Double(value))
    }

    // MARK: - Marshalling

    private static func lent(_ point: CGPoint) -> SlopDeskVideoPoint {
        SlopDeskVideoPoint(x: Double(point.x), y: Double(point.y))
    }

    private static func lent(_ size: CGSize) -> SlopDeskVideoSize {
        SlopDeskVideoSize(width: Double(size.width), height: Double(size.height))
    }

    private static func lent(_ rect: CGRect) -> SlopDeskVideoRect {
        SlopDeskVideoRect(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.size.width), height: Double(rect.size.height),
        )
    }

    private static func read(_ record: SlopDeskVideoPoint) -> CGPoint {
        CGPoint(x: record.x, y: record.y)
    }

    private static func read(_ record: SlopDeskVideoRect) -> CGRect {
        CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
    }
}
