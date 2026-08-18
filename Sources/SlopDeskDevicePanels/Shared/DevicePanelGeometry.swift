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
// The simulator's framebuffer never turns, so its scroll deltas must be un-rotated; `scrcpy` rotates
// on the device, so the Android panel's must not. The Android lane sends touches in the video's own
// pixel grid because the server DROPS a mismatched pair; the simulator lane sends them in the fitted
// rect's space because the host rescales. Those are different protocols, and they read as different
// files calling different doors.

#if os(macOS)
import CoreGraphics
import CSlopDeskFFI

package enum DevicePanelGeometry {
    // MARK: The numbers both panels are written against

    /// How far in from the frame's edge a synthetic contact must stay.
    ///
    /// Planting ON the boundary puts the contact inside the platform's own system-gesture band — the
    /// home indicator and the pull-down shades on iOS, the gesture-navigation strip on Android — so
    /// a scroll would read as a Back or a Home. The number is the same on both because it is a
    /// property of a finger, not of an OS.
    package static let edgeMargin = CGFloat(slopdesk_panel_metric(SLOPDESK_PANEL_METRIC_EDGE_MARGIN))

    /// What a classic wheel NOTCH is worth in points. AppKit reports a trackpad's delta already in
    /// points and a wheel's in LINES, and a line taken as a point is a finger movement of one or two
    /// pixels — under both platforms' own touch slop, so the device discards it and the panel looks
    /// like it eats scrolls.
    package static let pointsPerLine = CGFloat(slopdesk_panel_metric(SLOPDESK_PANEL_METRIC_POINTS_PER_LINE))

    /// How far up the framebuffer iOS's bottom edge gesture reaches, as a fraction.
    package static let bottomBand = CGFloat(slopdesk_panel_metric(SLOPDESK_PANEL_METRIC_BOTTOM_BAND))
    /// How far down the framebuffer iOS's top edge gesture reaches, as a fraction.
    package static let topBand = CGFloat(slopdesk_panel_metric(SLOPDESK_PANEL_METRIC_TOP_BAND))

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

    // MARK: Scroll

    /// One scroll event's delta as FINGER TRAVEL, in points.
    ///
    /// SCALE only: a trackpad's delta is already in points, a classic wheel's is in lines.
    ///
    /// SIGN — pass-through, and deliberately so. AppKit has ALREADY applied the user's
    /// scroll-direction preference to `scrollingDeltaY`. `NSEvent.isDirectionInvertedFromDevice`
    /// reports the RAW device direction; folding it in double-applies the preference, and
    /// synthesized events report it `false` regardless of the setting. That trap cost the simulator
    /// panel a round and is recorded in `docs/47`.
    package static func scrollVector(delta: CGSize, isPrecise: Bool) -> CGSize {
        read(slopdesk_panel_scroll_vector(lent(delta), isPrecise))
    }

    /// A screen-space vector in the space of a view drawn at `angle` degrees clockwise. Quarter
    /// turns only, spelled out per angle rather than run through trigonometry, so a `sin(90°)` that
    /// comes back as 0.9999999 can never leave a scroll drifting sideways.
    package static func unrotated(_ vector: CGSize, by angle: Double) -> CGSize {
        read(slopdesk_panel_unrotated(lent(vector), angle))
    }

    // MARK: Where a synthetic finger may be planted

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

    /// `point`, moved inside the frame by ``edgeMargin``. The fallback is the CENTRE of the axis,
    /// for a frame too small to hold two margins: a sliver has no valid band, and the middle is the
    /// only place that is not an edge.
    package static func planted(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        read(slopdesk_panel_planted(lent(point), lent(fitted)))
    }

    /// Where the finger lands after running out of screen: at the far end of the axis it was
    /// travelling along, so the next stretch of the same gesture has the full height to move
    /// through. This is a hand lifting and planting again, which is what makes a long scroll one
    /// gesture rather than a series of unrelated flicks.
    package static func regrip(travel: CGSize, in fitted: CGRect) -> CGPoint {
        read(slopdesk_panel_regrip(lent(travel), lent(fitted)))
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

    private static func read(_ record: SlopDeskVideoSize) -> CGSize {
        CGSize(width: record.width, height: record.height)
    }

    private static func read(_ record: SlopDeskVideoRect) -> CGRect {
        CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
    }
}
#endif
