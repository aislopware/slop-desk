// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting — and the title never recolours: the mark column is the AGENT's whole status voice.
//
// The vocabulary is otty's, transcribed rather than approximated (docs/DECISIONS.md round 23), and
// it is otty's `TabBadge` case for case — read out of the shipping app, not guessed at:
//
//   * `running` — a spinner at the row's right edge. otty mounts a 14×14 `NSProgressIndicator`
//     there; ours is DRAWN (``AgentSpinner``) on herdr's braille comet instead — see that view.
//   * `completed` — `checkmark.circle.fill` at 12pt Medium. The AGENT's turn ending.
//   * `awaitingInput` — lucide `hand`, carried as the literal path data otty embeds
//     (``OttyIcon/hand``). A question is waiting on a person.
//
// Plus one mark that is OURS, because otty has no need for it: an agent that is merely PRESENT
// takes lucide `circle-dashed`, muted. otty draws nothing there; our rail needs it, because
// `claude` sitting at its prompt is otherwise indistinguishable from a shell that has been busy for
// an hour.
//
// ⚠️ A COMMAND's outcome has no mark here at all (round 24). It used to take otty's two — the plain
// disc for a clean exit, the alert triangle for a failure — and the row printed a symbol where the
// slot beside it was going empty anyway. A command's exit is a fact about a NAME (`make` passed,
// `make` failed), so it reads as that name in the trailing slot instead, in the slot's own register
// (``StatusPresentation/outcomeInk(_:)``): bright + bold for the exit that worked, red for the one
// that didn't. One less glyph vocabulary to
// learn, and the row now says WHAT finished rather than only that something did.
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
    /// The size otty gives its other badge symbols — a point smaller than the finish, because a
    /// filled straight-edged glyph out-weighs a circle at equal point size. The privilege shield
    /// (``TabBadgeView``) is the one left that uses it.
    static let badgeSymbolSize: CGFloat = 11
    /// otty renders every badge at `NSFontWeightMedium`. Not `.regular`: at 11pt a regular-weight
    /// symbol goes thin enough on a muted ink to read as smudge rather than mark.
    static let symbolWeight: Font.Weight = .medium
    /// The side lucide `hand` is drawn into — otty's badge box, undivided (an outlined glyph needs
    /// the whole box; a system symbol already carries its own margin inside one).
    static let handSide: CGFloat = 14
    /// The side otty gives the spinner. Same box as everything else in this column.
    static let spinnerSide: CGFloat = 14
    /// The platform's own `.small` control side — what ``spinnerSide`` is scaled DOWN from.
    static let smallControlSide: CGFloat = 16

    // MARK: - The thinking comet (``AgentSpinner``)

    /// The comet turns on the SAME circle the resting mark draws, at the same weight. A working
    /// agent and a merely present one are ONE silhouette — the only difference is that one of them
    /// is turning, which is the whole reading: the ring answers "an agent lives here", the motion
    /// answers "and it is thinking right now".
    static let cometDiameter: CGFloat = ringDiameter
    /// How much of the circle the comet spans, in degrees. herdr lights 3–4 of a braille cell's six
    /// perimeter dots (180°–240°, breathing between the two as the arc crosses a half-step). Drawn,
    /// the breathing is unnecessary — the sweep is fixed and the tail's own fade carries what the
    /// fourth dot was standing in for — and the sweep opens to 270° so the GAP stays wide enough to
    /// read as a gap at Ø10 (below ~90° of clearance a turning arc reads as a whole ring vibrating).
    static let cometSweep: Double = 270
    /// Seconds per revolution — herdr's own tempo, transcribed rather than picked: it advances one
    /// of ten braille frames every 8 ticks of a 60 Hz loop, and those ten frames are exactly one
    /// turn around the cell. So `10 × 8 / 60`. Slower than the platform wheel on purpose; the mark
    /// says "alive", not "hurry".
    static let cometPeriod: Double = 10 * 8 / 60
    /// Where the comet's HEAD sits at zero rotation — 12 o'clock, so a frozen spinner (Reduce
    /// Motion) reads as a deliberately-cut ring rather than a random arc.
    static let cometHead: Double = -90
}

/// WHICH mark a row draws — otty's `TabBadge` set, plus the resting-agent ring otty has no need
/// for. See this file's header for what each one is allowed to say. Every case here is an AGENT's:
/// a command's outcome speaks in the trailing slot as text (``CommandReceipt``), not as a mark.
enum StatusMark: Equatable {
    /// The agent is generating RIGHT NOW — otty's spinner. The only thing on this rail that moves.
    case working
    /// The agent is present in this pane but idle — lucide `circle-dashed`, muted.
    case agentRing
    /// A person's turn: the agent is blocked on input — lucide `hand`, otty's own awaiting badge.
    case awaiting
    /// The AGENT's turn ended and the finish is unread — `checkmark.circle.fill`.
    case agentFinish

    /// The system symbol this mark draws and the point size otty configures for it — `nil` for the
    /// marks that are not system symbols (the ring, the hand, the spinner). ONE source, so a
    /// magnified render cannot show a different symbol from the one the rail mounts.
    var systemSymbol: (symbol: SFSymbol, size: CGFloat)? {
        switch self {
        case .agentFinish: (.checkmarkCircleFill, StatusDot.finishSymbolSize)
        case .agentRing,
             .awaiting,
             .working: nil
        }
    }
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
        if let system = style.mark.systemSymbol {
            // A system symbol at otty's configuration for it — the artwork is Apple's, so this is
            // the EXACT drawing otty mounts rather than a redraw of it.
            Image(systemSymbol: system.symbol)
                .font(.system(size: system.size, weight: StatusDot.symbolWeight))
                .foregroundStyle(style.ink)
        } else {
            switch style.mark {
            case .working:
                AgentSpinner(ink: style.ink)
            case .awaiting:
                VectorIconView(icon: OttyIcon.hand, side: StatusDot.handSide, ink: style.ink)
            default:
                DashedRing()
                    .stroke(style.ink, style: StatusDot.ringStroke)
                    .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            }
        }
    }
}

/// The agent-presence ring. A `Shape` rather than a bare `Circle` so the ring has one definition
/// the resting mark and any future reading of it must share.
struct DashedRing: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect)
    }
}

/// The THINKING mark — herdr's spinner, DRAWN.
///
/// herdr spends one terminal cell on it: the braille frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, which are an arc of
/// three-to-four lit dots travelling around the six perimeter cells of a braille cell, one full turn
/// per ten frames. Read as artwork rather than as text, that is a COMET on a circle — and the two
/// things braille has to fake, it fakes visibly: the rotation is quantised to six positions (so the
/// arc jumps a sixth of a turn at a time) and the "in between" positions are approximated by lighting
/// a FOURTH dot, which is why the arc appears to breathe as it turns.
///
/// So this draws what those frames are a low-resolution picture OF: one arc on the resting ring's own
/// circle, at the resting ring's own weight, turning continuously at herdr's tempo, its tail fading
/// out behind the head. Continuous phase means no quantisation to hide and nothing to breathe around
/// — the motion is as smooth as the display can draw, which is the entire reason for redrawing it.
///
/// Three properties are load-bearing:
///
///  * **The phase comes off the WALL CLOCK, from a fixed epoch** — not from an animation started at
///    mount. Every spinning row in the rail is therefore at the same angle, and a re-render (a title
///    changing, a row scrolling back into view) lands the comet mid-turn instead of snapping it back
///    to 12 o'clock. This is the same rule the typed pulse has followed since MERIDIAN.
///  * **It is PURE SwiftUI**, so `ImageRenderer` can rasterize it. The platform indicator could not
///    be rendered at all (``SlateSnapshotRender`` had to host an offscreen window to photograph the
///    mark sheet), which meant the one mark that moved was also the one mark no test could look at.
///  * **Reduce Motion freezes it** — the platform used to own that call; drawing it makes it ours.
///    A frozen comet is still a distinct silhouette (a ring cut at 12 o'clock, its tail faded) so
///    the state is never lost, only the movement.
struct AgentSpinner: View {
    /// The comet's ink at full strength — the head. The tail is this same ink, fading out.
    let ink: Color
    var diameter: CGFloat = StatusDot.cometDiameter
    var lineWidth: CGFloat = StatusDot.ringLineWidth
    /// Hold the comet at ONE angle instead of turning it. The render rig's only way to photograph a
    /// moving mark (a still of a wall-clock spinner catches an arbitrary phase, so a filmstrip of
    /// pinned angles is what a reviewer can actually read), and `0` is also what Reduce Motion asks
    /// for — one parameter, so the frozen mark a snapshot shows IS the frozen mark that ships.
    var pinnedTurn: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        comet.frame(width: diameter, height: diameter)
    }

    @ViewBuilder private var comet: some View {
        if let pinnedTurn {
            arc(turn: pinnedTurn)
        } else if reduceMotion {
            arc(turn: 0)
        } else {
            // `.animation` schedules at the display's own refresh rate, so the turn is drawn at
            // 60/120 Hz rather than stepped — and the angle stays a pure function of the date.
            TimelineView(.animation) { timeline in
                arc(turn: Self.turn(at: timeline.date))
            }
        }
    }

    private func arc(turn: Double) -> some View {
        CometArc(sweep: StatusDot.cometSweep, lineWidth: lineWidth)
            // The gradient is laid over the SAME angular span the arc occupies, in the same
            // (unrotated) space, so head and tail stay welded to their ends as the whole thing turns.
            .stroke(
                AngularGradient(
                    gradient: tail,
                    center: .center,
                    startAngle: .degrees(StatusDot.cometHead - StatusDot.cometSweep),
                    endAngle: .degrees(StatusDot.cometHead),
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
            )
            .rotationEffect(.degrees(turn))
    }

    /// The taper from tail to head, on the opacity ladder's own rungs — and it TAPERS rather than
    /// fades out: the arc still ends in a visible cap at ``Slate/Opacity/dim``.
    ///
    /// ⚠️ Two things were settled on pixels here, both against the version that faded to nothing.
    /// (1) A vanishing tail is a lovely comet at 6× and a thin crescent at Ø10 — it left the working
    /// mark carrying LESS ink than the resting dashed ring beside it (eight dashes at full strength
    /// are a lot of ink), so the rail's hierarchy came out upside down: the row doing something read
    /// quieter than the row doing nothing. (2) herdr's braille arc has no fade in it at all — its
    /// dots are lit or they are not, and the "tail" is one extra dot dropped in behind the leading
    /// one. A hard-ended arc with a gentle taper is the closer transcription AND the stronger mark;
    /// the taper is kept only because it is what names which end is the HEAD, and therefore which
    /// way the thing is turning.
    private var tail: Gradient {
        Gradient(stops: [
            .init(color: ink.opacity(Slate.Opacity.dim), location: 0),
            .init(color: ink.opacity(Slate.Opacity.muted), location: 0.55),
            .init(color: ink, location: 1),
        ])
    }

    /// The comet's rotation for one wall-clock instant, in degrees. Pure + static so the cadence is
    /// unit-pinned headlessly: one turn per ``StatusDot/cometPeriod``, phase locked to the reference
    /// epoch (so every mount agrees), and never negative for dates before it.
    static func turn(at date: Date) -> Double {
        let period = StatusDot.cometPeriod
        guard period > 0 else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return (phase < 0 ? phase + 1 : phase) * 360
    }
}

/// The comet's path: one arc, ending at the head, on the circle the ring mark uses. A `Shape` (not a
/// trimmed `Circle`) because the stroke's own width has to be inset out of the radius — a trimmed
/// circle strokes ASTRIDE the frame's edge and the comet would be clipped a half-weight all round.
struct CometArc: Shape {
    /// The arc's span in degrees, measured back from the head.
    let sweep: Double
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        guard radius > 0 else { return path }
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(StatusDot.cometHead - sweep),
            endAngle: .degrees(StatusDot.cometHead),
            clockwise: false,
        )
        return path
    }
}

/// The PLATFORM's indeterminate circular progress indicator — the generic "this control is waiting"
/// spinner, in the 14pt box otty lays its own out in. NOT the agent's mark any more (that is
/// ``AgentSpinner``): what is left here is the ordinary busy affordance a button or a list row shows
/// while a request is in flight, where matching every other spinner on the machine is the point
/// (`NSProgressIndicator` on macOS, `UIActivityIndicatorView` on iOS).
///
/// ⚠️ Reduce Motion is the PLATFORM's call here — the control makes it, which is half of why a
/// generic wait still uses it.
///
/// The control inherits the window's appearance, which follows the OS (no theme pin anywhere —
/// user-directed 2026-08-07), so it always paints with the right contrast on the system chrome.
struct WorkingSpinner: View {
    var body: some View {
        indicator
            // The small control is 16pt; otty's box is 14. Scaling the control (rather than clipping
            // a 16pt spinner into a 14pt frame) keeps the fins whole and the column exact.
            .scaleEffect(StatusDot.spinnerSide / StatusDot.smallControlSide)
            .frame(width: StatusDot.spinnerSide, height: StatusDot.spinnerSide)
    }

    #if canImport(AppKit)
    private var indicator: some View { AppKitSpinner() }
    #else
    private var indicator: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(Slate.Text.secondary)
    }
    #endif
}

#if canImport(AppKit)
/// The macOS indicator, reached through a representable rather than `ProgressView` — the AppKit
/// class draws itself from the window's effective appearance directly (which now follows the OS),
/// and reaching for it also happens to be exactly what otty does.
private struct AppKitSpinner: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        // Nothing in this column may leave a mark behind when its state ends — a stopped spinner
        // must vanish, not sit there as a static wheel.
        indicator.isDisplayedWhenStopped = false
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context _: Context) {
        // No appearance pin: the chrome follows the OS appearance (user-directed 2026-08-07), so the
        // control inherits the window's appearance like every other native control. (The old pin
        // existed because the window was pinned to a THEME appearance the environment scheme
        // couldn't reach across the hosting boundary — both halves of that problem are gone.)
        // Idempotent, and it has to run on UPDATE as well as creation: an indicator only starts
        // once it has a window, which it does not have when `makeNSView` returns.
        indicator.startAnimation(nil)
    }
}
#endif
#endif
