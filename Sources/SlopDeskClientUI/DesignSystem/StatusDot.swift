// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting, red = failed — and the title never recolours: the mark column is the rail's whole
// status voice.
//
// The vocabulary is otty's, transcribed rather than approximated (docs/DECISIONS.md round 23), and
// it is otty's `TabBadge` case for case — read out of the shipping app, not guessed at:
//
//   * `running` — a spinning `NSProgressIndicator`, 14×14, at the row's right edge. otty's OWN
//     answer for "the agent is generating right now", and the one this rail now uses.
//   * `completed` — `checkmark.circle.fill` at 12pt Medium. The AGENT's turn ending.
//   * `finished` — a plain filled 8pt disc. A background COMMAND's clean exit. otty draws these two
//     differently, which is round 21's two speakers arrived at independently: an agent's state is
//     continuous and survives being looked at, while a command badge is an unread RECEIPT the store
//     keeps only for an unfocused pane and drops the moment you visit it.
//   * `error` — `exclamationmark.triangle.fill` at 11pt Medium.
//   * `awaitingInput` — lucide `hand`, carried as the literal path data otty embeds
//     (``OttyIcon/hand``). A question is waiting on a person.
//
// Plus one mark that is OURS, because otty has no need for it: an agent that is merely PRESENT
// takes lucide `circle-dashed`, muted. otty draws nothing there; our rail needs it, because
// `claude` sitting at its prompt is otherwise indistinguishable from a shell that has been busy for
// an hour.
//
// ONE state moves — the spinner — and everything settled holds absolutely still (round 19's lesson
// survives: a settled rail must not twitch).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The status mark's geometry — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows.
    /// 14 is otty's own badge box (it lays the spinner out at exactly `14 × 14`, 8pt in from the
    /// row's trailing edge), and every mark here is drawn to fit it: the reason the previous port
    /// read as fussy detail was that it squeezed the same silhouettes into 8.
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

    /// The ring's stroke — lucide's dash rhythm at the ring's own weight.
    static var ringStroke: StrokeStyle {
        StrokeStyle(lineWidth: ringLineWidth, dash: ringDash)
    }

    // MARK: - otty's badge sizes

    /// The finish mark's point size — otty configures `checkmark.circle.fill` at exactly this.
    static let finishSymbolSize: CGFloat = 12
    /// The failure mark's point size — otty configures `exclamationmark.triangle.fill` at this,
    /// a point smaller than the finish. A triangle at equal point size out-weighs a circle.
    static let alertSymbolSize: CGFloat = 11
    /// otty renders every badge at `NSFontWeightMedium`. Not `.regular`: at 11pt a regular-weight
    /// symbol goes thin enough on a muted ink to read as smudge rather than mark.
    static let symbolWeight: Font.Weight = .medium
    /// The command-outcome disc's diameter — otty fills an 8×8 oval for its `finished` badge.
    static let dotDiameter: CGFloat = 8
    /// The side lucide `hand` is drawn into — otty's badge box, undivided (an outlined glyph needs
    /// the whole box; a system symbol already carries its own margin inside one).
    static let handSide: CGFloat = 14
    /// The side otty gives the spinner. Same box as everything else in this column.
    static let spinnerSide: CGFloat = 14
}

/// WHICH mark a row draws — otty's `TabBadge` set, plus the resting-agent ring otty has no need
/// for. See this file's header for what each one is allowed to say.
enum StatusMark: Equatable {
    /// The agent is generating RIGHT NOW — otty's spinner. The only thing on this rail that moves.
    case working
    /// The agent is present in this pane but idle — lucide `circle-dashed`, muted.
    case agentRing
    /// A person's turn: the agent is blocked on input — lucide `hand`, otty's own awaiting badge.
    case awaiting
    /// The AGENT's turn ended and the finish is unread — `checkmark.circle.fill`.
    case agentFinish
    /// A background COMMAND exited clean while you were away — the plain filled disc.
    case commandFinish
    /// Something failed — `exclamationmark.triangle.fill`.
    case failure
}

/// One resolved mark: the ink that names the state, plus WHICH mark carries it. A pure value (no
/// view), so the resolver (``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)``)
/// unit-tests without rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
    /// The silhouette. Defaults to the agent ring, the shape the resting-agent branch wants.
    var mark: StatusMark = .agentRing
}

/// The mark itself. Only the spinner carries a timeline; every other state is drawn once and holds
/// still. AX-hidden: the row title's accessibility value already speaks the same state, so the mark
/// never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        mark
            // ONE footprint for every mark, so ring rows, spinning rows and symbol rows share the
            // column's centre line.
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch style.mark {
        case .working:
            WorkingSpinner()
        case .agentRing:
            DashedRing()
                .stroke(style.ink, style: StatusDot.ringStroke)
                .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        case .awaiting:
            VectorIconView(icon: OttyIcon.hand, side: StatusDot.handSide, ink: style.ink)
        case .agentFinish:
            symbol(.checkmarkCircleFill, size: StatusDot.finishSymbolSize)
        case .commandFinish:
            Circle()
                .fill(style.ink)
                .frame(width: StatusDot.dotDiameter, height: StatusDot.dotDiameter)
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

/// The agent-presence ring. A `Shape` rather than a bare `Circle` so the ring has one definition
/// the resting mark and any future reading of it must share.
struct DashedRing: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect)
    }
}

/// The THINKING mark — otty's, literally: the platform's indeterminate circular progress indicator
/// (`NSProgressIndicator` on macOS, `UIActivityIndicatorView` on iOS), in the 14pt box otty lays it
/// out in. A hand-rolled spinner was tried in round 19 and pulled; this is the system's own, so it
/// matches every other spinner the user sees and needs no ink, no cadence and no frozen frame of
/// our choosing.
///
/// ⚠️ Reduce Motion is the PLATFORM's call here, not ours. Every other mark in this column is
/// static, so there is nothing left for us to freeze.
struct WorkingSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            // The small control is 16pt; otty's box is 14. Scaling the VECTOR (rather than clipping
            // a 16pt spinner into a 14pt frame) keeps the fins crisp and the column exact.
            .scaleEffect(StatusDot.spinnerSide / 16)
            .frame(width: StatusDot.spinnerSide, height: StatusDot.spinnerSide)
    }
}
#endif
