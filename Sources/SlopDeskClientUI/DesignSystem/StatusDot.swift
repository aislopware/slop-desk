// StatusDot — the sidebar row's trailing status mark: one fixed right-edge column, one hue budget.
// The HUE names the state — muted = a resting agent, green = an unread finish, amber = a question
// waiting. The mark column is the agent's status voice for everything EXCEPT the two urgent states —
// a blocked agent and a failed command — whose hue now also runs across the row's title
// (`StatusPresentation.urgentInk`, user-directed 2026-08-10); a finish keeps the neutral title.
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
// takes a muted ring of DOTS (``DottedRing``, lucide `circle-dashed` recut). otty draws nothing
// there; our rail needs it, because `claude` sitting at its prompt is otherwise indistinguishable
// from a shell that has been busy for an hour.
//
// ⚠️ A COMMAND's outcome has no mark here at all (round 24, and still true). It used to take otty's
// two — the plain disc for a clean exit, the alert triangle for a failure — and the row printed a
// symbol where the slot beside it was going empty anyway. A command's exit is a fact about a NAME
// (`make` passed, `make` failed), so it reads as that name in the trailing SLOT instead, one less
// glyph vocabulary to learn, and the row now says WHAT finished rather than only that something did.
//
// ⚠️ Round 25 (user-directed) moved the line WITHIN that slot. The command's name is bold on the
// primary ink from the moment it starts running, not only once it exits, so weight and brightness no
// longer mean "finished" — which left a clean exit with nothing to say itself. It gets a bare
// `checkmark` (``StatusPresentation/outcomeSymbol(_:)``) at ``receiptCheckSize``, on the tertiary
// grey, set after the name like punctuation. That is the SAME WORD as `completed` above, three steps
// quieter: no circle, four points smaller, no hue. A failure still takes none — red is that one's
// whole statement, and a cross beside a red word is what cost the triangle its place.
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
    /// The agent-presence ring's diameter. Matched by eye at true size to the outer circle of the
    /// finish mark — ⚠️ which now sits a point ABOVE it (``finishSymbolSize``, user-directed), so a
    /// row that finishes gains a hair of size where it used to gain none.
    static let ringDiameter: CGFloat = 10
    /// How many dots ride the ring. Eight keeps the four-fold symmetry that lets a small circle of
    /// marks read as a CIRCLE — the dots at 12, 3, 6 and 9 o'clock do that work on their own.
    static let ringDotCount = 8
    /// One dot's diameter. Fatter than the 1.5 hairline the ring used to be stroked at, so a dot
    /// reads as a dot rather than as a nick in a thin line, and still under the working cell's Ø2.6:
    /// a PRESENT agent must stay quieter than a thinking one, and size is half of how it does that.
    static let ringDotDiameter: CGFloat = 1.8

    /// The air between two neighbouring dots, measured edge to edge along the circumference. ⚠️ This
    /// is what the round is FOR — user-directed 2026-08-10: the ring is dots now, not dashes, and the
    /// dots stand further apart than the dashes did. Pinned as a value rather than eyeballed, because
    /// it is the only number that separates "a ring of dots" from "a dashed ring with short dashes".
    static var ringDotGap: CGFloat {
        .pi * ringDiameter / CGFloat(ringDotCount) - ringDotDiameter
    }

    // MARK: - otty's badge sizes

    /// The finish mark's point size. ⚠️ 13, user-directed 2026-08-10 — otty configures
    /// `checkmark.circle.fill` at 12, and this is the first place the column stops taking otty's
    /// number. Measured at 12 it was NOT the smaller mark it read as (12.12pt of ink across, against
    /// the resting ring's 11.88 and five times its mass) — it read small because the ring is eight
    /// separate dots and the eye counts the air between them as part of the object, while a filled
    /// disc is only as big as itself. So the correction is to what it READS as, not to a measured
    /// defect: 13 puts ≈13.1pt across the column, a point clear of the ring, still inside the 14pt
    /// box. Its one cost is that a row now grows very slightly when it finishes.
    static let finishSymbolSize: CGFloat = 13
    /// The size otty gives its other badge symbols — a point smaller than the finish, because a
    /// filled straight-edged glyph out-weighs a circle at equal point size. The privilege shield
    /// (``TabBadgeView``) is the one left that uses it.
    static let badgeSymbolSize: CGFloat = 11
    /// The point size of the RECEIPT's completion check — the bare `checkmark` a cleanly-exited
    /// command sets after its name in the trailing slot (``StatusPresentation/outcomeSymbol(_:)``).
    ///
    /// ⚠️ NINE, and the gap to ``finishSymbolSize`` is the whole design: this is the same WORD the
    /// agent's finish says, said quietly. Three things separate them at once — the circle is gone
    /// (no plate, no fill, just the tick), the ink is the tertiary metadata grey instead of green,
    /// and it is four points smaller. Any one of those alone would read as the agent's check gone
    /// faulty; all three read as a different, smaller speaker. It sits a point UNDER the 10pt name
    /// it follows for the same reason a receipt's tick is smaller than the line it closes.
    static let receiptCheckSize: CGFloat = 9
    /// The weight that check is stroked at. `.semibold`: a 9pt tick on a tertiary ink goes to smudge
    /// at `.regular` (the same floor ``symbolWeight`` exists for), and the name beside it is bold —
    /// a hairline tick after a bold word reads as a rendering artefact rather than a mark.
    static let receiptCheckWeight: Font.Weight = .semibold
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
    /// How many dots the hole is WIDE. ⚠️ ONE — back to the braille set, user-directed 2026-08-10,
    /// reversing the two-dot cut made earlier the same day. Two dark dots out of eight took a quarter
    /// of the cell away at once: the block stopped reading as a lit cell with a gap travelling round
    /// it and started reading as a broken cell, and the silhouette is the half of this mark that
    /// carries the state.
    ///
    /// At `1` every frame of the walk is a frame `⣾⣽⣻⢿⡿⣟⣯⣷` actually draws (each is `0xFF` with
    /// exactly one bit cleared), so the mark is a transcription again rather than a drawing.
    /// ``AgentSpinner/lit(_:hole:)`` is the only reader, so the width is the whole switch either way.
    static let holeWidth: Double = 1
    /// herdr's own tempo: one braille frame per 8 ticks of a 60 Hz loop, eight frames to the lap.
    /// The QUICK end of the wander below, and nothing quicker — on its own it read as a hurry.
    static let herdrLapPeriod: Double = 8 * 8 / 60
    /// The SLOW end. Slower than this and a lap stops reading as motion and starts reading as a mark
    /// that has stopped between two frames.
    static let slowestLapPeriod: Double = 2.6
    /// The tempos a running mark passes THROUGH. ⚠️ User-directed 2026-08-10, second cut: the same
    /// spread used to be rolled ONCE PER MOUNT, so a pane picked a speed at birth and held it for its
    /// whole life — a rail of panes each turning at its own fixed rate. The spread now happens in
    /// TIME instead of across panes: one mark speeds up and slows down as it runs, because that is
    /// what thinking looks like from outside, and a perfectly even wheel looks like a progress bar.
    /// The ends are unchanged, so this is the same band of speeds already judged on hardware.
    static let lapPeriodRange: ClosedRange<Double> = herdrLapPeriod...slowestLapPeriod

    // MARK: - The wandering tempo

    /// Laps per second at the quick end of the wander, and at the slow end.
    static var quickRate: Double { 1 / lapPeriodRange.lowerBound }
    static var slowRate: Double { 1 / lapPeriodRange.upperBound }
    /// The tempo the wander swings around, and how far to each side of it.
    ///
    /// ⚠️ The wander is symmetric in RATE, not in period: a spinner's speed is laps per second, and
    /// the period is its reciprocal, so a swing that looked even in seconds-per-lap would spend far
    /// longer crawling than hurrying. The consequence is that the AVERAGE lap is the harmonic middle
    /// of the two ends (≈1.51 s), a touch quicker than the 1.8 s that shipped as the single settled
    /// tempo — the mark's mean speed is the one thing this round changes about how fast it looks.
    static var midRate: Double { (quickRate + slowRate) / 2 }
    static var rateSwing: Double { (quickRate - slowRate) / 2 }
    /// Seconds per lap AT THE MIDDLE of the wander — the tempo of a mark that is not wandering: the
    /// linear term of the phase, every still, every test, every frozen mark.
    static var lapPeriod: Double { 1 / midRate }

    /// One component of the tempo's wander: a sine on the mark's SPEED, `share` of the full swing
    /// wide, `turn` of a cycle ahead of the epoch.
    struct TempoSwell {
        let period: Double
        let share: Double
        let turn: Double
    }

    /// What the wander is MADE OF — three swells whose shares sum to exactly 1, so the tempo reaches
    /// both ends of ``lapPeriodRange`` and can never pass either (past the slow end it would stall or
    /// run backwards; a spinner that reverses reads as a bug, not as a pause).
    ///
    /// ⚠️ The periods are deliberately in NON-INTEGER ratios: three sines whose periods divide each
    /// other resynchronise, and a tempo that repeats on a cycle you can count is a mechanism, which
    /// is the thing being designed away. As set, the sum has no visible period — the long swell
    /// carries the mood, the middle one shapes it, the short one keeps it from ever gliding evenly.
    /// It covers ~93% of the swing inside 30 s, so the wander is legible without watching for it.
    static let tempoSwells: [TempoSwell] = [
        TempoSwell(period: 13.1, share: 0.5, turn: 0),
        TempoSwell(period: 5.9, share: 0.3, turn: 0.37),
        TempoSwell(period: 2.7, share: 0.2, turn: 0.61),
    ]

    /// How far apart two mounts' wanders are set, in seconds of the same clock. Every mark obeys one
    /// tempo law; each rolls its own offset INTO it, so two panes thinking at once are never at the
    /// same point of the same swell. Without this the whole rail would speed up and slow down in
    /// lockstep, which reads as the application hitching rather than as agents thinking.
    static let tempoSeedSpan: Double = 600
}

/// WHICH mark a row draws — otty's `TabBadge` set, plus the resting-agent ring otty has no need
/// for. See this file's header for what each one is allowed to say. Every case here is an AGENT's:
/// a command's outcome speaks in the trailing slot as text (``CommandReceipt``), not as a mark.
enum StatusMark: Equatable {
    /// The agent is generating RIGHT NOW — otty's spinner. The only thing on this rail that moves.
    case working
    /// The agent is present in this pane but idle — a muted ring of dots (``DottedRing``).
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
                DottedRing()
                    .fill(style.ink)
                    .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            }
        }
    }
}

/// The agent-presence ring: ``StatusDot/ringDotCount`` DOTS spaced evenly round a circle, the first
/// at 12 o'clock. A `Shape` rather than a stack of circles so the ring has one definition every
/// reading of it must share — and so it is a `Path`, which can be filled, hit-tested and scaled
/// like any other.
///
/// ⚠️ It was a DASHED ring until 2026-08-10 (lucide `circle-dashed`, stroked with a 0.6-fill dash
/// pattern), replaced on the user's instruction by dots standing further apart than those dashes did.
/// A dash is a fragment of a line that happens to be curved; a dot is its own shape, and at this size
/// that is the difference between a ring that looks broken and a ring that looks made of parts.
///
/// The dot size scales with the rect, so a magnified still is a true redraw rather than a blown-up
/// 10pt bitmap — the same lesson ``AgentSpinner`` learned about `scaleEffect`.
struct DottedRing: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let radius = side / 2
        // The dots ride ON the circle and spill half their width outside it, exactly as the stroke
        // they replace did — so the ring's visual diameter, matched by eye to a 12pt
        // `checkmark.circle.fill`, does not change with the cut.
        let dot = StatusDot.ringDotDiameter * (side / StatusDot.ringDiameter)
        var path = Path()
        for index in 0..<StatusDot.ringDotCount {
            let turn = 2 * Double.pi * Double(index) / Double(StatusDot.ringDotCount) - .pi / 2
            let centre = CGPoint(
                x: rect.midX + radius * CGFloat(cos(turn)),
                y: rect.midY + radius * CGFloat(sin(turn)),
            )
            path.addEllipse(
                in: CGRect(
                    x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot,
                ),
            )
        }
        return path
    }
}

/// The THINKING mark — herdr's spinner, DRAWN.
///
/// It starts from `⣾⣽⣻⢿⡿⣟⣯⣷`: a braille cell with every one of its eight dots lit and one switched
/// OFF, the dark one stepping round the cell, one lap per eight frames. So the mark is a small
/// upright BLOCK OF DOTS, and the thing that moves is the GAP in it — ONE dot wide
/// (``StatusDot/holeWidth``), exactly as the set draws it. ⚠️ A two-dot gap was tried and reversed
/// on the same day (user-directed): a quarter of the cell out at once reads as a BROKEN cell rather
/// than a lit one with something travelling round it. It turns CLOCKWISE, which
/// is the reverse of what the bitmask says — see ``BrailleCell/walk``. herdr's own tempo (a frame per
/// 8 ticks of a 60 Hz loop, ≈1.07 s/lap) shipped as the only tempo and read as a hurry; it is now the
/// QUICK END of a tempo that WANDERS as the mark runs — see ``StatusDot/tempoSwells``.
///
/// ⚠️ The wander is the point of the second cut (user-directed): a spinner turning at a constant rate
/// is a machine reporting that something is switched on, and the thing this mark reports is an agent
/// THINKING. So it hurries and it dwells — the speed drifts across the whole band between herdr's
/// 1.07 s lap and a 2.6 s one, and never sits at either. That band used to be rolled once per MOUNT,
/// which gave a rail of panes each turning evenly at its own speed; the same spread now happens in
/// time, inside every mark. It never stops and never reverses: the tempo is a sum of three swells
/// whose shares add to exactly one, so the speed reaches the slow end and turns back from it.
///
/// Drawn, the one lie in the original goes away: the hole no longer teleports between eight discrete
/// dots, it GLIDES. Each dot's ink is a function of how far the hole's centre currently is from it,
/// so a half-step of travel spills half a dot's darkness onto the next dot along — the gap slides
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
///    mid-lap instead of snapping it back to the start, and lands it at the tempo the wander is
///    CURRENTLY at rather than restarting the wander too. This is the rule the typed pulse has
///    followed since MERIDIAN. ⚠️ Rows no longer turn in UNISON, which they did until the tempo
///    stopped being one shared number — see ``StatusDot/tempoSeedSpan`` for why that is deliberate.
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

    /// Where in the shared wander this mount sits, rolled once and held for as long as the view keeps
    /// its identity (``StatusDot/tempoSeedSpan``). Every mark obeys the same tempo law; the seed is
    /// only an offset into it, so two panes are never hurrying and dwelling in step. `@State` rather
    /// than a computed roll because a fresh number on every re-render would make the hole jump, which
    /// is the exact defect the wall-clock phase exists to prevent.
    @State private var seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)

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
                dots(phase: Self.phase(at: timeline.date, seed: seed))
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

    /// How lit the `index`-th dot is with the hole centred at `hole` (in dot-steps around the cell).
    ///
    /// The hole is ``StatusDot/holeWidth`` dots wide: everything within half that of its centre is
    /// fully dark, and the edge ramps over exactly one more step. At the shipping width of one, that
    /// means the darkness SLIDES — parked ON a dot it is that dot alone, fully out, everything else
    /// at full ink; rolled to the seam between two, each of the pair is half dark. The total ink
    /// removed is the same at every instant, which is what stops the walk pulsing as it goes.
    static func lit(_ index: Int, hole: Double) -> Double {
        let count = Double(BrailleCell.dotCount)
        var gap = abs(Double(index) - hole).truncatingRemainder(dividingBy: count)
        if gap > count / 2 { gap = count - gap }
        let shade = min(1, max(0, gap - (StatusDot.holeWidth - 1) / 2))
        return StatusDot.holeFloor + (1 - StatusDot.holeFloor) * shade
    }

    /// How fast the mark is turning at one wall-clock instant, in LAPS PER SECOND — the wander
    /// itself, as a value. Pure + static, so what the mark is doing at a given moment can be pinned
    /// headlessly; ``phase(at:seed:)`` is this function's integral and nothing else reads it.
    ///
    /// Between ``StatusDot/slowRate`` and ``StatusDot/quickRate`` at every instant, because the
    /// swells' shares sum to one. That bound is the whole safety argument: the mark can dwell but it
    /// can never stall, and it can never run backwards.
    static func rate(at date: Date, seed: Double = 0) -> Double {
        let time = date.timeIntervalSinceReferenceDate + seed
        let wander = StatusDot.tempoSwells.reduce(0) { sum, swell in
            sum + swell.share * sin(2 * .pi * (turn(of: time, in: swell.period) + swell.turn))
        }
        return StatusDot.midRate + StatusDot.rateSwing * wander
    }

    /// The hole's position in its lap, as a fraction of the cell, for one wall-clock instant. Pure +
    /// static so the cadence is unit-pinned headlessly: the phase is locked to the reference epoch
    /// (so a mark's lap is a function of the CLOCK, not of when it was mounted — a re-render lands
    /// mid-lap), and never negative for dates before that epoch.
    ///
    /// This is ``rate(at:seed:)`` INTEGRATED, in closed form rather than accumulated frame by frame:
    /// a sine on the speed integrates to a cosine on the position, so each swell contributes a lead
    /// or a lag to where the hole has got to. Integrating analytically is what keeps the wall clock
    /// load-bearing — a spinner that added `rate × Δt` every frame would depend on WHEN it started
    /// and on which frames it happened to be drawn on, and two panes showing the same agent would
    /// drift apart while a scrolled-away row would come back holding a stale position.
    static func phase(at date: Date, seed: Double = 0) -> Double {
        let time = date.timeIntervalSinceReferenceDate + seed
        // Reduced to its own lap FIRST: the fraction has to keep its precision a couple of decades
        // out from the reference epoch, which the raw interval (~10⁹ s) would spend on the integer
        // part of the lap count nobody reads.
        var laps = turn(of: time, in: StatusDot.lapPeriod)
        for swell in StatusDot.tempoSwells {
            laps -= StatusDot.rateSwing * swell.share * swell.period / (2 * .pi)
                * cos(2 * .pi * (turn(of: time, in: swell.period) + swell.turn))
        }
        let phase = laps.truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }

    /// `time` as a fraction of one cycle of `period`, wrapped into `0..<1` — including for instants
    /// before the reference epoch, where the raw remainder goes negative.
    private static func turn(of time: Double, in period: Double) -> Double {
        guard period > 0 else { return 0 }
        let turn = time.truncatingRemainder(dividingBy: period) / period
        return turn < 0 ? turn + 1 : turn
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
