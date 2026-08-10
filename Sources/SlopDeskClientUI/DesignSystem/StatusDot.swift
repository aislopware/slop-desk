// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting — and the title never recolours: the mark column is the AGENT's whole status voice.
//
// The vocabulary is otty's, transcribed rather than approximated (docs/DECISIONS.md round 23), and
// it is otty's `TabBadge` case for case — read out of the shipping app, not guessed at:
//
//   * `running` — a spinner at the row's right edge. otty mounts a 14×14 `NSProgressIndicator`
//     there; ours is DRAWN (``AgentSpinner``) on herdr's braille caravan instead — see that view.
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

    // MARK: - The thinking caravan (``AgentSpinner``)

    /// The TRACK the dots walk — a braille cell's own proportion, upright and taller than it is
    /// wide. This is the shape herdr's spinner literally is: the lit dots are a short line walking
    /// the PERIMETER OF A RECTANGLE, and reading them as an arc on a circle (which the first cut of
    /// this mark did) throws away the one thing about the artwork that is recognisable.
    /// Sized so the DOTS, not the track, fill the column: a dot rides half its own width outside the
    /// track on every edge, so the drawn mark measures `track + dot` and that is what has to fit the
    /// 14pt footprint. The first cut sized the track to the column instead and the mark came out as
    /// three specks in a lot of air.
    static let trackWidth: CGFloat = 8.2
    static let trackHeight: CGFloat = 10.2
    /// The track's corner. Not square: a dot rounding a hard 90° corner changes direction in one
    /// frame and reads as a stutter, which is exactly the quantisation this redraw exists to remove.
    static let trackRadius: CGFloat = 2.2
    /// One dot. Solid and round — a braille dot, at a size that survives the rail's true scale.
    static let dotDiameter: CGFloat = 3.6
    /// How many dots walk together. herdr lights three of the cell's six perimeter positions (a
    /// fourth appears only as its way of faking a half-step, which a drawn caravan does not need).
    static let dotCount = 3
    /// The gap between consecutive dots, as a fraction of the track's perimeter — so the caravan
    /// keeps its shape whatever the track measures. `1/8` leaves roughly a third of a dot of air
    /// between them, which is a braille cell's own dot rhythm: read as one LINE travelling, where a
    /// wider gap reads as three unrelated dots blinking.
    static let dotGap: Double = 1.0 / 8
    /// Seconds per lap — herdr's own tempo, transcribed rather than picked: it advances one of ten
    /// braille frames every 8 ticks of a 60 Hz loop, and those ten frames are exactly one trip
    /// around the cell. So `10 × 8 / 60`. The mark says "alive", not "hurry".
    static let lapPeriod: Double = 10 * 8 / 60
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
/// herdr spends one terminal cell on it: the braille frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, advanced one per 8 ticks
/// of a 60 Hz loop. Decoded, those are three lit dots walking around the six perimeter positions of a
/// braille cell — a short LINE OF DOTS travelling the edge of an upright RECTANGLE — one lap per ten
/// frames. Two of its properties are the medium rather than the design: the walk is quantised to six
/// stops, and the half-steps between them are faked by lighting a fourth dot, which is why the line
/// appears to stretch and shrink as it goes.
///
/// So this draws exactly that, without the two lies: three dots of its own, walking the perimeter of
/// a rounded rectangle continuously at herdr's tempo, brightest at the head. Continuous phase means
/// nothing to quantise and nothing to breathe around — the motion is as smooth as the display can
/// draw, which is the whole reason for redrawing it instead of typing it.
///
/// ⚠️ The first cut of this mark read the same braille frames as an ARC ON A CIRCLE (they are, at six
/// samples, geometrically close) and drew a comet on the resting ring's circle. It was rejected on
/// sight: the rectangle IS the recognisable thing about the artwork, and a turning arc is just the
/// spinner every app already has.
///
/// Three properties are load-bearing:
///
///  * **The phase comes off the WALL CLOCK, from a fixed epoch** — not from an animation started at
///    mount. Every working row in the rail therefore walks in step, and a re-render (a title changing,
///    a row scrolling back into view) lands the caravan mid-lap instead of snapping it back to the
///    start. This is the same rule the typed pulse has followed since MERIDIAN.
///  * **It is PURE SwiftUI**, so `ImageRenderer` can rasterize it. The platform indicator could not
///    be rendered at all (``SlateSnapshotRender`` had to host an offscreen window to photograph the
///    mark sheet), which meant the one mark that moved was also the one mark no test could look at.
///  * **Reduce Motion freezes it** — the platform used to own that call; drawing it makes it ours. A
///    frozen caravan is still a distinct silhouette (three dots down one corner of a rectangle, which
///    no other mark in this column resembles), so the state is never lost, only the movement.
struct AgentSpinner: View {
    /// The head dot's ink at full strength. The dots behind it are this same ink, stepped down.
    let ink: Color
    /// Multiplies the whole mark — the render rig's way of magnifying it without resampling.
    var zoom: CGFloat = 1
    /// Hold the caravan at ONE point of its lap instead of walking it. The render rig's only way to
    /// photograph a moving mark (a still of a wall-clock spinner catches an arbitrary phase, so a
    /// filmstrip of pinned phases is what a reviewer can actually read), and `0` is also what Reduce
    /// Motion asks for — one parameter, so the frozen mark a snapshot shows IS the one that ships.
    var pinnedPhase: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        caravan
            .frame(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
    }

    @ViewBuilder private var caravan: some View {
        if let pinnedPhase {
            dots(phase: pinnedPhase)
        } else if reduceMotion {
            dots(phase: 0)
        } else {
            // `.animation` schedules at the display's own refresh rate, so the walk is drawn at
            // 60/120 Hz rather than stepped — and the phase stays a pure function of the date.
            TimelineView(.animation) { timeline in
                dots(phase: Self.phase(at: timeline.date))
            }
        }
    }

    private func dots(phase: Double) -> some View {
        let track = Self.track(zoom: zoom)
        let side = StatusDot.dotDiameter * zoom
        return ZStack {
            ForEach(0..<StatusDot.dotCount, id: \.self) { index in
                Circle()
                    .fill(ink.opacity(Self.dim(index)))
                    .frame(width: side, height: side)
                    .position(
                        RectTrack.point(
                            at: phase - Double(index) * StatusDot.dotGap,
                            in: track, radius: StatusDot.trackRadius * zoom,
                        ),
                    )
            }
        }
        .frame(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
    }

    /// The track, centred in the mark column's own footprint and inset by half a dot so a dot on the
    /// edge sits fully inside the column rather than half out of it.
    static func track(zoom: CGFloat) -> CGRect {
        let side = StatusDot.footprint * zoom
        let size = CGSize(width: StatusDot.trackWidth * zoom, height: StatusDot.trackHeight * zoom)
        return CGRect(
            x: (side - size.width) / 2, y: (side - size.height) / 2,
            width: size.width, height: size.height,
        )
    }

    /// How bright the `index`-th dot behind the head is. Stepped, on the opacity ladder's own rungs —
    /// braille has no fade at all (a dot is lit or it is not), so this is the smallest departure that
    /// still names WHICH end is the head, and therefore which way the line is walking.
    static func dim(_ index: Int) -> Double {
        switch index {
        case 0: 1
        case 1: Slate.Opacity.muted
        default: Slate.Opacity.dim
        }
    }

    /// The caravan head's position in its lap, as a fraction of the perimeter, for one wall-clock
    /// instant. Pure + static so the cadence is unit-pinned headlessly: one lap per
    /// ``StatusDot/lapPeriod``, phase locked to the reference epoch (so every mount agrees), and
    /// never negative for dates before it.
    static func phase(at date: Date) -> Double {
        let period = StatusDot.lapPeriod
        guard period > 0 else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return phase < 0 ? phase + 1 : phase
    }
}

/// Where a point sits on the perimeter of a rounded rectangle, given how far around it has walked.
///
/// A pure function rather than a `Path` trick (`trimmedPath(from:to:).currentPoint` would also give a
/// point) because the dots' positions are the whole mark: as values they are unit-pinnable — corners
/// land where the geometry says, the lap closes exactly, and a fraction outside `0..<1` wraps instead
/// of flying off the track.
enum RectTrack {
    /// Clockwise from the START OF THE TOP EDGE (just past the top-left corner) — the braille cell's
    /// own dot 1, so a frozen mark at phase 0 sits where herdr's frame 0 lights up.
    static func point(at fraction: Double, in rect: CGRect, radius: CGFloat) -> CGPoint {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let across = rect.width - 2 * r
        let down = rect.height - 2 * r
        let corner = .pi / 2 * Double(r)
        let perimeter = 2 * Double(across) + 2 * Double(down) + 4 * corner
        guard perimeter > 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        var walked = fraction.truncatingRemainder(dividingBy: 1)
        if walked < 0 { walked += 1 }
        var left = walked * perimeter

        // Each leg in walking order: a straight run, then the corner arc that turns out of it.
        let legs: [(length: Double, point: (Double) -> CGPoint)] = [
            (Double(across), { t in CGPoint(x: rect.minX + r + CGFloat(t), y: rect.minY) }),
            (corner, { t in
                Self.onArc(centre: CGPoint(x: rect.maxX - r, y: rect.minY + r), r: r, from: -90, arc: t, corner: corner)
            }),
            (Double(down), { t in CGPoint(x: rect.maxX, y: rect.minY + r + CGFloat(t)) }),
            (corner, { t in
                Self.onArc(centre: CGPoint(x: rect.maxX - r, y: rect.maxY - r), r: r, from: 0, arc: t, corner: corner)
            }),
            (Double(across), { t in CGPoint(x: rect.maxX - r - CGFloat(t), y: rect.maxY) }),
            (corner, { t in
                Self.onArc(centre: CGPoint(x: rect.minX + r, y: rect.maxY - r), r: r, from: 90, arc: t, corner: corner)
            }),
            (Double(down), { t in CGPoint(x: rect.minX, y: rect.maxY - r - CGFloat(t)) }),
            (corner, { t in
                Self.onArc(centre: CGPoint(x: rect.minX + r, y: rect.minY + r), r: r, from: 180, arc: t, corner: corner)
            }),
        ]
        for leg in legs {
            // A zero-length leg is SKIPPED, not landed on: a square track (`radius` 0) has four of
            // them, and stopping at the first one parks every dot past the top-right corner.
            guard leg.length > 0 else { continue }
            if left <= leg.length { return leg.point(left) }
            left -= leg.length
        }
        // Float drift on the last leg only — the lap is closed, so this is the start.
        return CGPoint(x: rect.minX + r, y: rect.minY)
    }

    /// One quarter-turn corner: `from` is the arc's starting angle in degrees (0 = due right, growing
    /// clockwise, because y runs down), `arc` how far along that quarter the walk has come.
    private static func onArc(
        centre: CGPoint, r: CGFloat, from: Double, arc: Double, corner: Double,
    ) -> CGPoint {
        let sweep = corner > 0 ? arc / corner * 90 : 0
        let angle = (from + sweep) * .pi / 180
        return CGPoint(x: centre.x + r * CGFloat(cos(angle)), y: centre.y + r * CGFloat(sin(angle)))
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
