// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting — and the title never recolours: the mark column is the AGENT's whole status voice.
//
// The vocabulary is otty's, transcribed rather than approximated (docs/DECISIONS.md round 23), and
// it is otty's `TabBadge` case for case — read out of the shipping app, not guessed at:
//
//   * `running` — a spinner at the row's right edge. otty mounts a 14×14 `NSProgressIndicator`
//     there; ours is DRAWN (``AgentSpinner``) on herdr's braille cell instead — see that view.
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

    // MARK: - The thinking cell (``AgentSpinner``)

    /// The braille cell's own grid — two columns, four rows, eight dots. This IS the mark: the whole
    /// cell is lit and a single HOLE runs round it, which is what `⣾⣽⣻⢿⡿⣟⣯⣷` draws (each frame is
    /// `0xFF` with exactly one bit cleared). The lit block is the silhouette; the gap is the motion.
    static let cellColumns = 2
    static let cellRows = 4
    /// One dot. A braille dot, at a size that survives the rail's true scale.
    static let dotDiameter: CGFloat = 2.6
    /// Centre-to-centre spacing. Wider across than down, as a real cell is — the two columns have to
    /// stay legible as columns while the four rows read as one run.
    static let dotPitchX: CGFloat = 4.4
    static let dotPitchY: CGFloat = 3.4
    /// What the hole is dimmed TO. Zero — braille has no half-lit dot, and the gap has to be a gap.
    static let holeFloor: Double = 0
    /// Seconds per lap. herdr's own tempo is `8 × 8 / 60` ≈ 1.07 s (one braille frame per 8 ticks of
    /// a 60 Hz loop, eight frames to the lap) — transcribed first, then rejected on hardware for
    /// reading as a HURRY. This is the settled middle of the range, and the value every still, every
    /// test and every frozen mark uses.
    static let lapPeriod: Double = 1.8
    /// ⚠️ EXPERIMENT, user-requested 2026-08-10: each mounted mark rolls its OWN lap time inside this
    /// range instead of every mark sharing one. The point is to watch a spread of tempos on hardware
    /// and pick, so the range is deliberately wide enough to feel at both ends.
    ///
    /// This is the one thing that breaks the marks' unison — see ``AgentSpinner``, which still takes
    /// its PHASE off the wall clock, so a re-render lands mid-lap at whatever tempo that mount rolled.
    /// Collapsing this back to a single value is a one-line change once a tempo is chosen.
    static let lapPeriodRange: ClosedRange<Double> = 1.3...2.6
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
/// The frames are `⣾⣽⣻⢿⡿⣟⣯⣷`: a braille cell with every one of its eight dots lit and exactly one
/// switched OFF, the dark one stepping round the cell, one lap per eight frames. So the mark is a
/// small upright BLOCK OF DOTS, and the thing that moves is the GAP in it. It turns CLOCKWISE, which
/// is the reverse of what the bitmask says — see ``BrailleCell/walk``. herdr's own tempo (a frame per
/// 8 ticks of a 60 Hz loop, ≈1.07 s/lap) shipped first and read as a hurry; see
/// ``StatusDot/lapPeriodRange``.
///
/// Drawn, the one lie in the original goes away: the hole no longer teleports between eight discrete
/// dots, it GLIDES. Each dot's ink is a function of how far the hole currently is from it, so with
/// the hole half a step along, the two dots it sits between are half-dark each — the darkness slides
/// across the block instead of hopping, at whatever rate the display can draw.
///
/// ⚠️ TWO earlier cuts were rejected on sight, both from reading the WRONG braille set (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`,
/// which is three LIT dots walking an otherwise empty cell): first as an arc turning on the resting
/// ring's circle — "a turning arc is the spinner every app already has, and it throws away the
/// rectangle, which is the recognisable thing" — then as three dots walking a rounded rectangle.
/// The mark is a filled cell with a hole in it, not a line of dots on a track.
///
/// Three properties are load-bearing:
///
///  * **The phase comes off the WALL CLOCK, from a fixed epoch** — not from an animation started at
///    mount. A re-render (a title changing, a row scrolling back into view) therefore lands the hole
///    mid-lap instead of snapping it back to the start. This is the rule the typed pulse has followed
///    since MERIDIAN. ⚠️ Rows no longer turn in UNISON, which they did until the per-mount tempo roll
///    (``StatusDot/lapPeriodRange``) — that is the experiment's one real cost.
///  * **It is PURE SwiftUI**, so `ImageRenderer` can rasterize it. The platform indicator could not
///    be rendered at all (``SlateSnapshotRender`` had to host an offscreen window to photograph the
///    mark sheet), which meant the one mark that moved was also the one mark no test could look at.
///  * **Reduce Motion freezes it** — the platform used to own that call; drawing it makes it ours. A
///    frozen cell is still a distinct silhouette (a lit block with one corner missing, which no other
///    mark in this column resembles), so the state is never lost, only the movement.
struct AgentSpinner: View {
    /// The lit dots' ink. The hole is this same ink taken down to ``StatusDot/holeFloor``.
    let ink: Color
    /// Multiplies the whole mark — the render rig's way of magnifying it without resampling.
    var zoom: CGFloat = 1
    /// Hold the hole at ONE point of its lap instead of running it. The render rig's only way to
    /// photograph a moving mark (a still of a wall-clock spinner catches an arbitrary moment, so a
    /// filmstrip of pinned phases is what a reviewer can actually read), and `0` is also what Reduce
    /// Motion asks for — one parameter, so the frozen mark a snapshot shows IS the one that ships.
    var pinnedPhase: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// This mount's own lap time, rolled once from ``StatusDot/lapPeriodRange`` and held for as long
    /// as the view keeps its identity — see that range's note: an EXPERIMENT, so a spread of tempos
    /// can be judged on hardware at once. `@State` rather than a computed roll because a fresh number
    /// on every re-render would make the hole jump, which is the exact defect the wall-clock phase
    /// exists to prevent.
    @State private var period = Double.random(in: StatusDot.lapPeriodRange)

    var body: some View {
        cell
            .frame(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
    }

    @ViewBuilder private var cell: some View {
        if let pinnedPhase {
            dots(phase: pinnedPhase)
        } else if reduceMotion {
            dots(phase: 0)
        } else {
            // `.animation` schedules at the display's own refresh rate, so the hole slides at
            // 60/120 Hz rather than stepping — and the phase stays a pure function of the date.
            TimelineView(.animation) { timeline in
                dots(phase: Self.phase(at: timeline.date, period: period))
            }
        }
    }

    private func dots(phase: Double) -> some View {
        let hole = phase * Double(BrailleCell.dotCount)
        let side = StatusDot.dotDiameter * zoom
        let box = CGSize(
            width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom,
        )
        return ZStack {
            ForEach(0..<BrailleCell.dotCount, id: \.self) { index in
                Circle()
                    .fill(ink.opacity(Self.lit(index, hole: hole)))
                    .frame(width: side, height: side)
                    .position(BrailleCell.position(of: index, in: box, zoom: zoom))
            }
        }
        .frame(width: box.width, height: box.height)
    }

    /// How lit the `index`-th dot is with the hole at `hole` (in dot-steps around the cell). Linear
    /// in the circular distance and clamped at one step: the hole is one dot wide, so at any instant
    /// it is either sitting ON a dot or split across the two it lies between — which is exactly what
    /// makes the darkness slide rather than hop.
    static func lit(_ index: Int, hole: Double) -> Double {
        let count = Double(BrailleCell.dotCount)
        var gap = abs(Double(index) - hole).truncatingRemainder(dividingBy: count)
        if gap > count / 2 { gap = count - gap }
        return StatusDot.holeFloor + (1 - StatusDot.holeFloor) * min(1, gap)
    }

    /// The hole's position in its lap, as a fraction of the cell, for one wall-clock instant. Pure +
    /// static so the cadence is unit-pinned headlessly: one lap per `period`, phase locked to the
    /// reference epoch (so a mark's lap is a function of the CLOCK, not of when it was mounted — a
    /// re-render lands mid-lap), and never negative for dates before that epoch.
    static func phase(at date: Date, period: Double = StatusDot.lapPeriod) -> Double {
        guard period > 0 else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return phase < 0 ? phase + 1 : phase
    }
}

/// The braille cell's eight dots, IN THE ORDER THE HOLE VISITS THEM — down the RIGHT column, then up
/// the LEFT, which is CLOCKWISE.
///
/// ⚠️ Decoding `⣾⣽⣻⢿⡿⣟⣯⣷` bit by bit gives the opposite (dots 1·2·3·7 then 8·6·5·4 — down the left,
/// up the right, anticlockwise) and that is what shipped first. Reversed on hardware, user-directed:
/// the way a spinner TURNS is judged by eye, not derived from a bitmask, and a mark that runs against
/// the direction every other spinner on the machine turns reads as wrong before it reads as anything.
///
/// A pure function rather than a laid-out stack, because the positions ARE the mark: as values they
/// are unit-pinnable — the walk really does go down one side and up the other, and the block really
/// is centred in the column it has to share with a Ø10 ring.
enum BrailleCell {
    static let dotCount = StatusDot.cellColumns * StatusDot.cellRows

    /// `(column, row)` for each step of the lap. Right column top-to-bottom, left column
    /// bottom-to-top.
    static let walk: [(column: Int, row: Int)] = {
        let rows = StatusDot.cellRows
        let right = StatusDot.cellColumns - 1
        return (0..<rows).map { (column: right, row: $0) } + (0..<rows).map { (column: 0, row: rows - 1 - $0) }
    }()

    /// Where the `index`-th step of the lap sits, centred in a box of `size`.
    static func position(of index: Int, in size: CGSize, zoom: CGFloat) -> CGPoint {
        guard walk.indices.contains(index) else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let dot = walk[index]
        let pitchX = StatusDot.dotPitchX * zoom
        let pitchY = StatusDot.dotPitchY * zoom
        let spanX = pitchX * CGFloat(StatusDot.cellColumns - 1)
        let spanY = pitchY * CGFloat(StatusDot.cellRows - 1)
        return CGPoint(
            x: (size.width - spanX) / 2 + pitchX * CGFloat(dot.column),
            y: (size.height - spanY) / 2 + pitchY * CGFloat(dot.row),
        )
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
