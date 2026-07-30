// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: ONE
// circle, at one diameter and one stroke weight, in a fixed right-edge column. The HUE names the
// state — accent = a working agent, muted = a resting one, green = an unread finish, amber = a
// question waiting, red = failed — and the title never recolours: the mark column is the rail's
// whole status voice, one uniform glyph down the right edge. An idle row renders null (T3 Code does
// too), so the resting rail stays bare, and NOTHING animates.
//
// The circle is DASHED (lucide `circle-dashed`, mounted STATIC there — no spin, no blink) for every
// state except one: an unread FINISH closes it. That is the only shape distinction the column
// carries, and it is the one that earns its keep — the broken ring means something is still open
// (working, resting, waiting, failed), the whole ring means the work came to an end. Nothing else
// about the mark changes: same diameter, same stroke, same column.

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

/// One resolved mark: the ink that names the state, plus whether the ring is CLOSED. A pure value
/// (no view), so the resolver (``StatusPresentation/statusDot(working:badge:)``) unit-tests without
/// rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
    /// Whether the ring is drawn as one continuous stroke rather than the dashed cut. TRUE for
    /// exactly one state — the unread FINISH — because a closed circle is what an ended piece of work
    /// looks like; every state that is still open keeps the broken ring. Defaulted, so the resolver's
    /// other branches read as they did before this distinction existed.
    var closed: Bool = false
}

/// The mark itself — one static ring, no timeline, no animation; dashed while the work is open and
/// CLOSED once it has finished. AX-hidden: the row title's accessibility value already speaks the
/// same state, so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        Circle()
            // An empty dash array IS a continuous stroke, so the closed ring is the same draw call
            // with the pattern withheld — one geometry, one stroke weight, no second code path to
            // drift out of alignment with the dashed one.
            .stroke(style.ink, style: StrokeStyle(
                lineWidth: StatusDot.ringLineWidth,
                dash: style.closed ? [] : StatusDot.ringDash,
            ))
            .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }
}
#endif
