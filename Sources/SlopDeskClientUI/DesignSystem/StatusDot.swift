// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: a
// DASHED RING while something runs (lucide `circle-dashed`, mounted STATIC there — no spin, no
// blink) and a SOLID RING for the unread finish (the loop closed — same silhouette, whole
// stroke). Those are the ONLY marks: T3 Code's waiting states (approval / input / failed) mount
// no icon at all — the tinted status label alone carries them, which here is the title's own
// attention ink — and an idle row renders null, so the resting rail stays bare. The shape carries
// the grammar — broken outline = in flight, closed outline = done — in a fixed right-edge column
// that gives every running or freshly-finished row weight on both ends. NOTHING here animates,
// and nothing anywhere else does either: the mark IS the running indicator (the title stands
// still).

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

/// One resolved mark: the state's ink and which shape speaks it. A pure value (no view), so the
/// resolver (``StatusPresentation/statusDot(working:badge:)``) unit-tests without rendering.
struct StatusDotStyle: Equatable {
    enum Shape {
        /// The dashed ring — something is RUNNING (T3 Code's `CircleDashedIcon`). Static.
        case dashedRing
        /// The solid ring — the run FINISHED, unread: the dashed loop closes into a whole
        /// stroke (same silhouette as the run it ends). Static.
        case solidRing
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
            case .dashedRing:
                Circle()
                    .stroke(style.ink, style: StrokeStyle(
                        lineWidth: StatusDot.ringLineWidth, dash: StatusDot.ringDash,
                    ))
            case .solidRing:
                Circle()
                    .stroke(style.ink, lineWidth: StatusDot.ringLineWidth)
            }
        }
        .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
        .accessibilityHidden(true)
    }
}
#endif
