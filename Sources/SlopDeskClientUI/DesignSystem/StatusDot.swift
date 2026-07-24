// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: ONE
// shape, the dashed ring (lucide `circle-dashed`, mounted STATIC there — no spin, no blink), in
// a fixed right-edge column. The HUE names the state — accent = a working agent, muted = a
// running command, green = an unread finish, amber = a question waiting, red = failed — and the
// title never recolours: the mark column is the rail's whole status voice, one uniform glyph
// down the right edge. An idle row renders null (T3 Code does too), so the resting rail stays
// bare, and NOTHING animates.

#if canImport(SwiftUI)
import SwiftUI

/// The status mark's geometry — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows.
    static let footprint: CGFloat = 10
    /// The ring's diameter within the footprint.
    static let ringDiameter: CGFloat = 8
    static let ringLineWidth: CGFloat = 1.5
    /// Dash segments around the ring — the lucide `circle-dashed` cut T3 Code mounts.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6

    /// The dash pattern: ``ringDashCount`` segments spread evenly around the circumference.
    static var ringDash: [CGFloat] {
        let period = .pi * ringDiameter / CGFloat(ringDashCount)
        return [period * ringDashFill, period * (1 - ringDashFill)]
    }
}

/// One resolved mark: the ink that names the state (the shape is always the dashed ring). A pure
/// value (no view), so the resolver (``StatusPresentation/statusDot(working:badge:)``) unit-tests
/// without rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
}

/// The mark itself — one static dashed ring, no timeline, no animation. AX-hidden: the row
/// title's accessibility value already speaks the same state, so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        Circle()
            .stroke(style.ink, style: StrokeStyle(
                lineWidth: StatusDot.ringLineWidth, dash: StatusDot.ringDash,
            ))
            .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }
}
#endif
