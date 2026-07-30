// StatusDot — the sidebar row's trailing status mark, ported from T3 Code's SidebarV2 row: one fixed
// right-edge column, one hue budget. The HUE names the state — muted = a resting agent, green = an
// unread finish, amber = a question waiting, red = failed — and the title never recolours: the mark
// column is the rail's whole status voice.
//
// The column has TWO speakers, and the geometry says WHICH:
//
//   * the RING (lucide `circle-dashed`) is the AGENT's. It is the shape for a living session with a
//     lifecycle: dashed while the work is still open (working / resting / a question waiting),
//     CLOSED once the turn ended.
//   * the DOT (a small filled disc, same centre, same column) is a COMMAND's OUTCOME — green for a
//     long background command that exited clean, red for one that failed.
//
// ONE state moves, and it spends no hue to do it: an agent THINKING RIGHT NOW pumps its ring's dash
// segments outward and back in turn — a crest travelling around the circle, the way an EDM
// visualizer's bars run around a ring — on the row title's OWN ink. Thinking is the one thing on
// this rail that is happening in the present tense, so it is said with the one thing a static mark
// cannot forge: motion. Everything settled still holds absolutely still (round 19's lesson survives
// — a settled rail must not twitch), and no other state animates.
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
    /// Sized by the WIDEST thing the column ever draws: the thinking ring at full crest
    /// (`ringDiameter / 2 + pulseAmplitude + ringLineWidth / 2` = 6). Every settled mark keeps
    /// its own size and simply gets more air, so widening this does not restyle a single one of them.
    static let footprint: CGFloat = 12
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

    // MARK: - The thinking pump

    /// A segment at REST sits on ``ringDiameter`` — the pumping ring's trough IS the ordinary dashed
    /// ring, and the wave only ever pushes outward from it. ⚠️ Do not shrink this to buy excursion
    /// room: the dash rhythm is the mark's identity, and the gaps are already narrower than the
    /// stroke at r=4. Rendered at r=3.25 the eight segments fuse into a notched blob — a smaller
    /// pumping ring is a DIFFERENT, worse mark, not a tighter one.
    static let pulseBaseDiameter: CGFloat = ringDiameter
    /// How far a segment travels outward at the crest, in points — every point the column can give
    /// it: `ringDiameter / 2 + this + ringLineWidth / 2` is EXACTLY ``footprint`` / 2, so the crest
    /// grazes the column edge and never crosses it. The swing wants all of that room. The eye reads
    /// it as MOVEMENT long before it could measure it as size: motion perception is what carries the
    /// mark, not the silhouette at any one instant.
    static let pulseAmplitude: CGFloat = 1.25
    /// Seconds for the crest to travel one full lap — ~175 ms per segment at
    /// ``ringDashCount`` = 8. Fast enough to read as alive at a glance, slow enough that a rail of
    /// several thinking agents doesn't strobe.
    static let pulsePeriod: Double = 1.4
    /// The crest's half-width as a fraction of one lap: a segment lifts once the crest is within
    /// this much of it. `0.25` = ±2 segment positions, so ~5 of the 8 ride the wave at any instant
    /// (tapered) — a rolling swell rather than one lonely bump ticking around.
    static let pulseWindow: CGFloat = 0.25
    /// The pumping ring's stroke — the ring's own weight and butt caps, so a lifted segment keeps the
    /// squared-off ends the resting ring's dashes have.
    ///
    /// The join is ROUND because each segment is a POLYLINE (see ``PulsingRingShape``): its corners
    /// are the 3.4° kinks between chords, and rounding them is what makes the chain read as one
    /// smooth arc. Mitre would be defensible here too — but not on the seam a `move`-seeded `addArc`
    /// leaves, which is why that spelling is gone.
    static let pulseStroke = StrokeStyle(lineWidth: ringLineWidth, lineCap: .butt, lineJoin: .round)
    /// The phase Reduce Motion freezes on. A state that exists ONLY as an animation is invisible to
    /// someone who asked for stillness, so the frozen frame keeps a crest (on the 12 o'clock
    /// segment): even held still, a thinking ring is visibly not the even resting one.
    static let pulseFrozenPhase: CGFloat = 0

    /// How far segment `segment` is pushed out at `phase` (laps, `0...1` and periodic beyond) — a
    /// raised-cosine crest travelling around the ring. Pure geometry, so the wave is pinned by value
    /// rather than by eye.
    static func pulseLift(segment: Int, phase: CGFloat) -> CGFloat {
        // Distance from the crest to this segment, wrapped into ±half a lap (the crest reaches
        // segment 7 by travelling FORWARD off segment 0, not backwards across the whole ring).
        let raw = phase - CGFloat(segment) / CGFloat(ringDashCount)
        var lap = raw - raw.rounded(.down)
        if lap > 0.5 { lap -= 1 }
        let reach = abs(lap) / pulseWindow
        guard reach < 1 else { return 0 }
        return pulseAmplitude * 0.5 * (1 + cos(.pi * reach))
    }

    /// The radius segment `segment` is drawn at for `phase` — its resting radius plus its lift.
    static func pulseRadius(segment: Int, phase: CGFloat) -> CGFloat {
        pulseBaseDiameter / 2 + pulseLift(segment: segment, phase: phase)
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
    /// The open ring PUMPS — the agent is generating in this pane RIGHT NOW. Not a fourth mark (three
    /// is the column's ceiling): the same open ring, in motion. ⚠️ Only the raw `.working` status may
    /// set this. `claude` holds the shell's OSC-133 block open for its whole interactive lifetime, so
    /// a "busy ⇒ move" rule would leave every idle agent's row pumping for HOURS
    /// (docs/DECISIONS.md rounds 19, 22).
    var pulsing: Bool = false
}

/// The mark itself — one ring or one dot. Only the THINKING ring carries a timeline; every other
/// state is drawn once and holds still. AX-hidden: the row title's accessibility value already
/// speaks the same state, so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        mark
            // ONE footprint for every mark, so ring rows, pumping rows and dot rows share the
            // column's centre line.
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch style.mark {
        case .openRing where style.pulsing:
            PulsingRingView(ink: style.ink)
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

/// The thinking ring's geometry at one instant: ``StatusDot/ringDashCount`` arcs, each at its OWN
/// radius, so the dash segments ride the travelling crest. It cannot be a dash PATTERN — a dashed
/// stroke shares one radius across every segment, and the whole idea here is that they don't.
///
/// A `Shape` (not a `Canvas` / `TimelineView`): `animatableData` hands the phase to SwiftUI's own
/// interpolator, so one `repeatForever` drives the lap on the render server and a rail of thinking
/// rows costs no per-frame view invalidation.
struct PulsingRingShape: Shape {
    /// Laps travelled. Periodic — `phase` and `phase + 1` draw the identical path, which is what
    /// lets a non-autoreversing `repeatForever` loop seamlessly.
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    /// Straight-line steps each segment is drawn in. At a 27° sweep that is a 3.4° chord, whose
    /// deviation from the true arc is 0.002pt — three orders of magnitude under a retina pixel.
    private static let stepsPerSegment = 8

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let sweep = 2 * .pi / CGFloat(StatusDot.ringDashCount) * StatusDot.ringDashFill
        var path = Path()
        for segment in 0..<StatusDot.ringDashCount {
            // Segment 0 sits at 12 o'clock (SwiftUI's angle 0 is 3 o'clock) and the crest travels
            // clockwise, so the frozen Reduce-Motion frame reads as a mark rather than a tilt.
            let centreAngle = 2 * .pi * CGFloat(segment) / CGFloat(StatusDot.ringDashCount) - .pi / 2
            let start = centreAngle - sweep / 2
            let radius = StatusDot.pulseRadius(segment: segment, phase: phase)
            // ⚠️ POLYLINE, not `addArc`. Both of that primitive's spellings are traps here: on a path
            // with no current point it sweeps the 333° complement (eight near-complete rings at eight
            // radii = one fat notched blob), and seeding a current point with `move` leaves a hairline
            // connector into a recomputed arc start — a ~180° corner that mitres into a
            // 10×-lineWidth spike, rounds into a fat pill, and bevels into a visible notch. `addLines`
            // opens its own subpath at a point WE compute, so there is no seam to dress.
            path.addLines((0...Self.stepsPerSegment).map { step in
                let angle = start + sweep * CGFloat(step) / CGFloat(Self.stepsPerSegment)
                return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
            })
        }
        return path
    }
}

/// The thinking mark — ``PulsingRingShape`` driven around one lap, forever, on the row title's own
/// ink. Reduce Motion FREEZES it on a crested frame rather than dropping it: a state that exists only
/// as an animation is invisible to someone who asked for stillness.
private struct PulsingRingView: View {
    let ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = StatusDot.pulseFrozenPhase

    var body: some View {
        PulsingRingShape(phase: phase)
            .stroke(ink, style: StatusDot.pulseStroke)
            .onAppear { reduceMotion ? freeze() : run() }
            .onChange(of: reduceMotion) { _, still in still ? freeze() : run() }
    }

    private func run() {
        // Re-seed first: a row recycled mid-lap would otherwise interpolate from wherever it stopped
        // to 1 in a full period, playing the tail of a lap at the wrong speed.
        phase = StatusDot.pulseFrozenPhase
        withAnimation(.linear(duration: StatusDot.pulsePeriod).repeatForever(autoreverses: false)) {
            phase = StatusDot.pulseFrozenPhase + 1
        }
    }

    /// Replace the repeating animation with a zero-duration one — that, not a bare assignment, is
    /// what ends a `repeatForever` already in flight.
    private func freeze() {
        withAnimation(.linear(duration: 0)) { phase = StatusDot.pulseFrozenPhase }
    }
}
#endif
