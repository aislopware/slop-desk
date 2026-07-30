// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting, red = failed — and the title never recolours: the mark column is the rail's whole
// status voice.
//
// The SILHOUETTES are otty's, transcribed rather than approximated (docs/DECISIONS.md round 23).
// Two of them are the system symbols otty asks for by name, at otty's own point sizes and weight;
// the third is lucide `hand`, carried as the literal path data otty embeds (``OttyIcon/hand``). An
// earlier round reached for the nearest system look-alike instead and the rail read as a bad copy —
// a specific drawing has no near-enough.
//
//   * awaiting input — lucide `hand`, an open palm. A question is waiting on a person.
//   * the agent's turn ENDED — `checkmark.circle.fill`, otty's completed badge exactly.
//   * a background command's clean exit — `checkmark.circle`, the same word said lighter. Round
//     21's two speakers survive the new vocabulary: an agent's state is continuous and survives
//     being looked at, while a command badge is an unread RECEIPT the store keeps only for an
//     unfocused pane and drops the moment you visit it. Same finish, different weight.
//   * a failure — `exclamationmark.triangle.fill`.
//   * an agent that is merely PRESENT — lucide `circle-dashed`, muted. otty draws nothing here;
//     our rail needs it, because `claude` sitting at its prompt is otherwise indistinguishable
//     from a shell that has been busy for an hour.
//
// ONE state moves, and it spends no hue to do it: an agent GENERATING right now SHIMMERS its ring —
// a highlight travelling around the dashes on the row title's own ink. Thinking is the one thing on
// this rail happening in the present tense, so it is said with the one thing a static mark cannot
// forge. Everything settled holds absolutely still (round 19's lesson survives — a settled rail must
// not twitch), and no other state animates.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The status mark's geometry — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows.
    /// 14 is otty's own badge box, and every mark here is drawn to fit it: the reason the previous
    /// port read as fussy detail was that it squeezed the same silhouettes into 8.
    static let footprint: CGFloat = 14
    /// The agent-presence ring's diameter. Matched by eye at true size to the outer circle of a
    /// 12pt `checkmark.circle.fill`, so a row that finishes does not visibly change size.
    static let ringDiameter: CGFloat = 10
    static let ringLineWidth: CGFloat = 1.5
    /// Dash segments around the ring — the lucide `circle-dashed` cut.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6

    /// The dash pattern: ``ringDashCount`` segments spread evenly around the circumference.
    static var ringDash: [CGFloat] {
        let period = .pi * ringDiameter / CGFloat(ringDashCount)
        return [period * ringDashFill, period * (1 - ringDashFill)]
    }

    // MARK: - otty's symbol sizes

    /// The finish mark's point size — otty configures `checkmark.circle.fill` at exactly this.
    static let finishSymbolSize: CGFloat = 12
    /// The failure mark's point size — otty configures `exclamationmark.triangle.fill` at this,
    /// a point smaller than the finish. A triangle at equal point size out-weighs a circle.
    static let alertSymbolSize: CGFloat = 11
    /// otty renders every badge at `NSFontWeightMedium`. Not `.regular`: at 11pt a regular-weight
    /// symbol goes thin enough on a muted ink to read as smudge rather than mark.
    static let symbolWeight: Font.Weight = .medium
    /// The side lucide `hand` is drawn into — otty's badge box, undivided (an outlined glyph needs
    /// the whole box; a system symbol already carries its own margin inside one).
    static let handSide: CGFloat = 14

    // MARK: - The thinking shimmer

    /// Seconds for the highlight to travel one full lap. Slower than a spinner on purpose: this is
    /// "something is alive here", not "wait for me".
    static let shimmerPeriod: Double = 1.6
    /// The highlight's width as a fraction of the lap. ⚠️ Rendered at 0.28 this lit ONE dash at a
    /// time and read as a defect rather than a sweep — at 14pt the eye needs a BAND, not a spark.
    /// 0.45 puts three or four of the eight dashes on the ramp at once, which is what makes the
    /// travel legible without the whole ring brightening together.
    static let shimmerWindow: CGFloat = 0.45
    /// What the ring is worth OUTSIDE the highlight. ⚠️ Not a dim base: at 0.34 of the primary ink
    /// the unlit ring landed on TOP of the resting ring's muted secondary, so a thinking row and a
    /// sleeping row were the same picture for most of every lap. The ring is fully present and the
    /// highlight brightens it the rest of the way.
    static let shimmerBase: Double = 0.62
    /// Where Reduce Motion parks the highlight. Measured from a render, NOT reasoned: SwiftUI's
    /// angular gradient begins at 3 o'clock and the crest sits half a window in, so this is the
    /// offset that lands it at the TOP of the ring. A state that exists ONLY as an animation is
    /// invisible to someone who asked for stillness, so the frozen frame keeps a crest — even held
    /// still, a thinking ring is visibly brighter on one side than the even resting one.
    static let shimmerFrozenPhase: Double = -171

    /// The highlight's gradient stops, as fractions of one lap starting at its leading edge. A
    /// raised cosine sampled at the quarters: SwiftUI interpolates linearly between stops, and the
    /// mid-points are what keep the band from reading as a hard-edged wedge.
    static var shimmerStops: [Gradient.Stop] {
        let window = Double(shimmerWindow)
        return [
            Gradient.Stop(color: .clear, location: 0),
            Gradient.Stop(color: .white.opacity(0.5), location: window / 4),
            Gradient.Stop(color: .white, location: window / 2),
            Gradient.Stop(color: .white.opacity(0.5), location: window * 3 / 4),
            Gradient.Stop(color: .clear, location: window),
            Gradient.Stop(color: .clear, location: 1),
        ]
    }
}

/// WHICH mark a row draws. The set is otty's badge vocabulary, plus the resting-agent ring otty has
/// no need for — see this file's header for what each one is allowed to say.
enum StatusMark: Equatable {
    /// The agent is present in this pane — lucide `circle-dashed`. Shimmers while it generates.
    case agentRing
    /// A person's turn: the agent is blocked on input — lucide `hand`, otty's own awaiting badge.
    case awaiting
    /// The AGENT's turn ended and the finish is unread — `checkmark.circle.fill`.
    case agentFinish
    /// A background COMMAND exited clean while you were away — `checkmark.circle`.
    case commandFinish
    /// Something failed — `exclamationmark.triangle.fill`.
    case failure
}

/// One resolved mark: the ink that names the state, plus WHICH mark carries it. A pure value (no
/// view), so the resolver (``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)``)
/// unit-tests without rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
    /// The silhouette. Defaults to the agent ring, the shape every live-agent branch wants.
    var mark: StatusMark = .agentRing
    /// The ring SHIMMERS — the agent is generating in this pane RIGHT NOW. Not a sixth mark: the
    /// same ring, in motion. ⚠️ Only the raw `.working` status may set this. `claude` holds the
    /// shell's OSC-133 block open for its whole interactive lifetime, so a "busy ⇒ move" rule would
    /// leave every idle agent's row shimmering for HOURS (docs/DECISIONS.md rounds 19, 22, 23).
    var shimmering: Bool = false
}

/// The mark itself. Only the THINKING ring carries a timeline; every other state is drawn once and
/// holds still. AX-hidden: the row title's accessibility value already speaks the same state, so the
/// mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        mark
            // ONE footprint for every mark, so ring rows, shimmering rows and symbol rows share the
            // column's centre line.
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch style.mark {
        case .agentRing where style.shimmering:
            ShimmerRingView(ink: style.ink)
        case .agentRing:
            DashedRing()
                .stroke(style.ink, style: StatusDot.ringStroke)
                .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        case .awaiting:
            VectorIconView(icon: OttyIcon.hand, side: StatusDot.handSide, ink: style.ink)
        case .agentFinish:
            symbol(.checkmarkCircleFill, size: StatusDot.finishSymbolSize)
        case .commandFinish:
            symbol(.checkmarkCircle, size: StatusDot.finishSymbolSize)
        case .failure:
            symbol(.exclamationmarkTriangleFill, size: StatusDot.alertSymbolSize)
        }
    }

    /// A system symbol at otty's configuration for it — the artwork is Apple's, so this is the
    /// EXACT drawing otty mounts rather than a redraw of it.
    private func symbol(_ symbol: SFSymbol, size: CGFloat) -> some View {
        Image(systemSymbol: symbol)
            .font(.system(size: size, weight: StatusDot.symbolWeight))
            .foregroundStyle(style.ink)
    }
}

extension StatusDot {
    /// The ring's stroke — lucide's dash rhythm at the ring's own weight.
    static var ringStroke: StrokeStyle {
        StrokeStyle(lineWidth: ringLineWidth, dash: ringDash)
    }
}

/// The agent-presence ring. A `Shape` rather than a bare `Circle` so the shimmer and the resting
/// mark stroke the IDENTICAL geometry — the two must be the same ring, one of them merely lit.
struct DashedRing: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect)
    }
}

/// The thinking ring at ONE instant of its sweep — the resting ring, plus the same ring lit through
/// a rotating highlight. Split out from the animating view so a snapshot harness can render an
/// honest frame at a chosen phase (a moving mark cannot be judged from the values alone).
///
/// The highlight is an angular gradient used as a MASK over a second copy of the ring, so the lit
/// and unlit rings are the IDENTICAL geometry — one of them merely brighter.
struct ShimmerRing: View {
    let ink: Color
    /// Degrees the highlight has travelled. Periodic at 360, which is what lets a non-autoreversing
    /// `repeatForever` loop with no seam.
    let phase: Double

    var body: some View {
        ZStack {
            ring.foregroundStyle(ink.opacity(StatusDot.shimmerBase))
            ring
                .foregroundStyle(ink)
                .mask {
                    // The gradient's square is the FULL footprint, and the ring lives well inside
                    // that square's inscribed circle — so rotating the mask can never uncover a
                    // corner of the ring, at any angle.
                    AngularGradient(stops: StatusDot.shimmerStops, center: .center)
                        .rotationEffect(.degrees(phase))
                }
        }
        .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
    }

    private var ring: some View {
        DashedRing().stroke(style: StatusDot.ringStroke)
    }
}

/// The thinking mark — ``ShimmerRing`` driven around one lap, forever.
///
/// The animation is one `rotationEffect`: SwiftUI hands a rotation to the render server, so a rail
/// of thinking rows costs no per-frame view invalidation. Reduce Motion freezes the sweep on a
/// crested frame rather than dropping it.
private struct ShimmerRingView: View {
    let ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = StatusDot.shimmerFrozenPhase

    var body: some View {
        ShimmerRing(ink: ink, phase: phase)
            .onAppear { reduceMotion ? freeze() : run() }
            .onChange(of: reduceMotion) { _, still in still ? freeze() : run() }
    }

    private func run() {
        // Re-seed first: a row recycled mid-lap would otherwise interpolate from wherever it stopped
        // round to 360 in a full period, playing the tail of a lap at the wrong speed.
        phase = StatusDot.shimmerFrozenPhase
        withAnimation(.linear(duration: StatusDot.shimmerPeriod).repeatForever(autoreverses: false)) {
            phase = StatusDot.shimmerFrozenPhase + 360
        }
    }

    /// Replace the repeating animation with a zero-duration one — that, not a bare assignment, is
    /// what ends a `repeatForever` already in flight.
    private func freeze() {
        withAnimation(.linear(duration: 0)) { phase = StatusDot.shimmerFrozenPhase }
    }
}
#endif
