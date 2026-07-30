// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: one fixed
// right-edge column, one hue budget, NOTHING animated. The HUE names the state — accent = a working
// agent, muted = a resting one, green = an unread finish, amber = a question waiting, red = failed —
// and the title never recolours: the mark column is the rail's whole status voice.
//
// The column has TWO speakers, and the geometry says WHICH:
//
//   * the RING (lucide `circle-dashed`, mounted STATIC — no spin, no blink) is the AGENT's. It is
//     the shape for a living session with a lifecycle: dashed while the work is still open
//     (working / resting / a question waiting), CLOSED once the turn ended.
//   * the DOT (a small filled disc, same centre, same column) is a COMMAND's OUTCOME — green for a
//     long background command that exited clean, red for one that failed.
//
// That split is not decoration, it is what the two signals ARE. An agent's state is continuous and
// survives being looked at; a command badge is an EVENT — the store only records it for an UNFOCUSED
// pane and clears it the instant the pane gains focus, so it is an unread receipt, not a state. Ring
// = something is (or was) alive here. Dot = something happened here while you were away. The dot is
// deliberately the LIGHTER mark (a 5pt disc against an 8pt ring's stroke): a finished `make` must not
// outshout a live agent.
//
// One footprint, one centre, one hue budget across both, so the right edge still reads as a single
// column down the rail — see docs/DECISIONS.md round 21.

#if canImport(SwiftUI)
import SwiftUI

/// The status mark's geometry — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows.
    static let footprint: CGFloat = 10
    /// The ring's diameter within the footprint.
    static let ringDiameter: CGFloat = 8
    static let ringLineWidth: CGFloat = 1.5
    /// The command-outcome DOT's diameter, picked by rendering 3–6pt beside the ring at true size:
    /// below 4 it reads as a stray pixel rather than a mark, at 6 it weighs as much as the ring it
    /// must stay quieter than. 5 also fits INSIDE the ring's aperture (`ringDiameter -
    /// ringLineWidth` = 6.5), so both marks live in one envelope and the column never widens.
    static let dotDiameter: CGFloat = 5
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

/// WHICH of the column's two marks a row draws — the AGENT's ring (open or closed) or a COMMAND's
/// outcome dot. Deliberately THREE cases and no more: this is the geometry saying who is speaking
/// and whether their work is over, not a silhouette per state (a previous round gave every state its
/// own pictogram — hand, triangle, `?`, `!` — and every one of them was pulled for reading as fussy
/// detail at 8pt; docs/DECISIONS.md rounds 19–21).
enum StatusMark: Equatable {
    /// The agent's ring, DASHED — a session whose work is still open (working, resting, or waiting
    /// on a human).
    case openRing
    /// The agent's ring, CLOSED — its turn ENDED and the finish is unread. A whole circle is what an
    /// ended piece of work looks like.
    case closedRing
    /// A COMMAND's outcome — the small filled disc. An event that happened while you were away
    /// (green = exited clean, red = failed), cleared the moment the pane is visited.
    case dot
}

/// One resolved mark: the ink that names the state, plus WHICH mark carries it. A pure value (no
/// view), so the resolver (``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)``)
/// unit-tests without rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
    /// The geometry — the agent's ring (open/closed) or a command's outcome dot. Defaults to the
    /// open ring, the shape every live-agent branch wants.
    var mark: StatusMark = .openRing
}

/// The mark itself — one static ring or one static dot, no timeline, no animation. AX-hidden: the
/// row title's accessibility value already speaks the same state, so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        mark
            // ONE footprint for both marks, so ring rows and dot rows share the column's centre line.
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch style.mark {
        case .openRing,
             .closedRing:
            Circle()
                // An empty dash array IS a continuous stroke, so the closed ring is the same draw
                // call with the pattern withheld — one geometry, one stroke weight, no second code
                // path to drift out of alignment with the dashed one.
                .stroke(style.ink, style: StrokeStyle(
                    lineWidth: StatusDot.ringLineWidth,
                    dash: style.mark == .closedRing ? [] : StatusDot.ringDash,
                ))
                .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        case .dot:
            Circle()
                .fill(style.ink)
                .frame(width: StatusDot.dotDiameter, height: StatusDot.dotDiameter)
        }
    }
}
#endif
