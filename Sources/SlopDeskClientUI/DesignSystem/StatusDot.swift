// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: a
// DASHED RING while something runs (lucide `circle-dashed`, mounted STATIC there — no spin, no
// blink; the working MOTION lives in the text, which here is the title's shimmer) and a flat
// FILLED dot for the settled attention states. The shape carries the grammar — OUTLINE = in
// flight, FILL = a settled state that needs a human — so the two read apart at a glance, in a
// fixed right-edge column that gives every stateful row weight on both ends. NOTHING here
// animates: an idle row mounts nothing at all (T3 Code renders null — the resting rail stays
// bare), and a running row's only motion is the title's own shimmer.

#if canImport(SwiftUI)
import SwiftUI

/// The status mark's geometry — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width whichever shape mounts, so the right edge
    /// never wavers between a ring row and a dot row.
    static let footprint: CGFloat = 10
    /// The filled dot's diameter — small enough to read as punctuation.
    static let fillDiameter: CGFloat = 6
    /// The dashed ring's diameter — a hair larger than the fill (an outline needs the extra size
    /// to carry the same visual weight).
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

/// One resolved mark: the state's ink and which shape speaks it. A pure value (no view), so the
/// resolver (``StatusPresentation/statusDot(working:badge:)``) unit-tests without rendering.
struct StatusDotStyle: Equatable {
    enum Shape {
        /// The dashed ring — something is RUNNING (T3 Code's `CircleDashedIcon`). Static.
        case ring
        /// The flat filled dot — a settled attention state waiting on a human. Static.
        case fill
    }

    let ink: Color
    let shape: Shape
}

/// The mark itself — one static shape, no timeline, no animation. AX-hidden: the row title's
/// accessibility value already speaks the same state, so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        Group {
            switch style.shape {
            case .ring:
                Circle()
                    .stroke(style.ink, style: StrokeStyle(
                        lineWidth: StatusDot.ringLineWidth, dash: StatusDot.ringDash,
                    ))
                    .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            case .fill:
                Circle()
                    .fill(style.ink)
                    .frame(width: StatusDot.fillDiameter, height: StatusDot.fillDiameter)
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
        .accessibilityHidden(true)
    }
}
#endif
