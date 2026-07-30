// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along. The agent's states are ONE CIRCLE at one diameter and one
// stroke weight, so they read as a progression instead of a legend: the ring is finely DASHED at rest
// (lucide `circle-dashed`), its dashes GATHER into five longer arcs and the ring TURNS while the agent
// works, and it becomes a FILLED dot once it has finished something unread. The two states you must
// ACT on stay in that same circle with a glyph inside it — `?` a question waits, `!` a failure. An
// idle row renders null, so the resting rail stays bare, and the only thing that MOVES here is the
// working ring: motion means "in flight", never decoration. A plain running COMMAND mounts nothing in
// this column — its ``CommandSpinner`` wheel takes the process-label slot instead (``SlateTabRow``),
// so no row ever carries two activity marks.
//
// ⚠️ Both animated marks are DRAWN, never typed, and at this size both are FLAT INK — a gradient
// spends half its length being nearly invisible, which is legible only when magnified (see
// ``AgentSweepMark``). A glyph spinner here was tried twice and abandoned:
// the instrument face is only JetBrains Mono when that font is installed (it is not, on every
// machine), so anything outside the system monospaced face's own coverage gets SUBSTITUTED — braille
// lands in AppleBraille (embossing dots, weight ignored, invisible at 11pt) and a bare dingbat star
// lands in AppleColorEmojiUI (a colour emoji that ignores `foregroundStyle` and is 2.4× the advance).
// Vector strokes have none of that: exact size, exact ink, no font on the machine to get in the way.
// A drawn asterisk was then tried and rejected too — at 12pt a radiating star is a burr of spikes.
// The rule that survives: ONE STROKE scales down, DETAIL does not.
//
// Every mark renders inside ONE fixed footprint, so a state edge — or an animation frame — can never
// move a pixel of the row's trailing edge. Hang-safety (CLAUDE.md #6): pure SwiftUI drawing, no
// capture/codec/Metal anywhere.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The mark's SHAPE — one per state, so the pictogram reads before its hue does. A pure value
/// (no view), so the resolver (``StatusPresentation/statusDot(working:badge:agentIdle:)``)
/// unit-tests without rendering.
enum StatusMarkShape: Equatable, Hashable, CaseIterable {
    /// The static, finely dashed ring — a code agent PRESENT and at rest.
    case ring
    /// The same ring with its dashes gathered into fewer, longer arcs, TURNING — a WORKING agent. The
    /// one animated mark in this column.
    case sweep
    /// The ring with a `?` inside — a question waits on you.
    case question
    /// The filled dot — an unread finish.
    case dot
    /// The ring with a `!` inside — a failure.
    case alert

    /// Whether this shape MOVES. Only the working sweep does: a settled rail is motionless.
    var animates: Bool { self == .sweep }

    /// The SF Symbol a shape draws, for the two states that need a HUMAN. Both are CIRCLE variants —
    /// pinned, because the obvious symbols for these states are otty's raised hand and warning
    /// TRIANGLE (which is what shipped first), and a triangle breaks the column's one rule: every
    /// mark is the same circle, so the marks read as a progression instead of a legend. The glyph
    /// inside carries the meaning the silhouette no longer can. `nil` for the drawn shapes.
    var symbol: SFSymbol? {
        switch self {
        case .question: .questionmarkCircle
        case .alert: .exclamationmarkCircle
        case .ring,
             .sweep,
             .dot: nil
        }
    }
}

/// The mark's geometry + cadence — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows
    /// (nor between shapes: every mark centres in this box).
    static let footprint: CGFloat = 12
    /// ⚠️ THE diameter — one number for EVERY mark in the column, no exceptions. The finish dot used
    /// to be drawn smaller on the argument that a solid mark carries more weight per point than an
    /// outline one; true in the abstract, and wrong here, because it made the column's sizes wobble
    /// row to row and that is the one thing a fixed status column may not do. Same circle, same size,
    /// only the inside changes.
    static let ringDiameter: CGFloat = 8
    static let ringLineWidth: CGFloat = 1.5
    /// Dash segments around the RESTING ring — the lucide `circle-dashed` cut T3 Code mounts. The
    /// working ring is the same circle cut into FEWER, longer arcs (``AgentSweepMark/dashCount``), so
    /// the two states differ in cut as well as in hue and motion.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6
    /// The point size the two SYMBOL marks (`?`, `!`) draw at inside ``footprint``. Chosen so their
    /// circle lands on ``ringDiameter`` rather than by type scale: an SF Symbol circle draws at roughly
    /// 0.8× its point size, and the column's whole premise is that every mark is the SAME circle — a
    /// `?` a point wider than the ring above it breaks the family faster than any hue could.
    static let symbolSize: CGFloat = 10
    /// The filled unread-finish dot — the SAME circle as every other mark, filled in. Aliased rather
    /// than given its own number so it cannot drift away from the family again.
    static var dotDiameter: CGFloat { ringDiameter }

    /// The dash pattern: ``ringDashCount`` segments spread evenly around the circumference.
    static var ringDash: [CGFloat] {
        let period = .pi * ringDiameter / CGFloat(ringDashCount)
        return [period * ringDashFill, period * (1 - ringDashFill)]
    }

    /// The frame index for one wall-clock instant, off a FIXED epoch — the cadence primitive both
    /// animated marks step on. Pure + static so the timing is unit-pinned headlessly: frames advance
    /// one per beat, wrap at `frames`, and a re-render at the same instant lands on the same frame
    /// (phase is a function of the clock, not of mount count), so every animating row in the rail
    /// steps in unison and nothing restarts mid-cycle.
    static func frame(at date: Date, frames: Int, beat: Double) -> Int {
        guard frames > 0, beat > 0 else { return 0 }
        let index = Int((date.timeIntervalSinceReferenceDate / beat).rounded(.down)) % frames
        return index < 0 ? index + frames : index
    }
}

/// One resolved mark: the SHAPE that names the state plus the ink it wears.
struct StatusDotStyle: Equatable {
    let shape: StatusMarkShape
    let ink: Color
}

/// The mark itself. AX-hidden: the row title's accessibility value already speaks the same state,
/// so the mark never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        content
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch style.shape {
        case .ring:
            Circle()
                .stroke(style.ink, style: StrokeStyle(
                    lineWidth: StatusDot.ringLineWidth, dash: StatusDot.ringDash,
                ))
                .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        case .sweep:
            AgentSweepMark(ink: style.ink)
        case .dot:
            Circle()
                .fill(style.ink)
                .frame(width: StatusDot.dotDiameter, height: StatusDot.dotDiameter)
        case .alert,
             .question:
            if let symbol = style.shape.symbol { self.symbol(symbol) }
        }
    }

    /// One of the two circle SYMBOLS, drawn to the ring's own optical size so the `?`/`!` circle sits
    /// at the same diameter as the rings above and below it in the column.
    private func symbol(_ symbol: SFSymbol) -> some View {
        Image(systemSymbol: symbol)
            .font(.system(size: StatusDot.symbolSize, weight: .semibold))
            .foregroundStyle(style.ink)
    }
}

/// The WORKING-AGENT mark — the RESTING RING'S OWN DASHES, fused into five longer arcs, TURNING.
/// That is the whole idea: the agent's column is ONE circle at the same diameter and stroke weight
/// throughout, so its states read as a progression rather than as a legend to learn — the ring is
/// finely dashed while the agent waits at its prompt, its dashes GATHER into fewer, longer arcs and
/// the whole ring turns while it works, and it becomes a FILLED dot once it has finished something you
/// haven't read. More ink, in motion, means more happening.
///
/// ⚠️ A DASHED ring, not a solid arc — the fourth cut of this mark and the one that stuck. Three
/// earlier cuts died at 12pt rather than in principle: the asterisk bloom TYPED in the instrument face
/// (the mono face has no star, so AppleColorEmojiUI drew `✳` as a COLOUR emoji at 2.4× the advance),
/// the same bloom DRAWN as capsules (at this size a radiating star is a burr of spikes; magnified it
/// is a cogwheel), and a single solid arc with a dissolving comet tail — which is what every loading
/// spinner on every platform already is, so it read as generic no matter how it was eased.
/// Dashes fix that for a reason worth keeping: the motion is carried by SEVERAL small shapes crossing
/// the ring, so it is legible even though each shape is barely two points long — where a comet must
/// spend half its length being nearly invisible to read as a comet at all. Rendered side by side, the
/// gradient cuts lose their faded half entirely at true size and only look good magnified. The rule
/// that survives all four: at 12pt, FLAT INK and WHOLE SHAPES; gradients and detail are luxuries of
/// the zoomed-in view.
///
/// The motion is CONTINUOUS, not stepped, and two things move at once:
///
///   * the ring TURNS, eased. A hop is a mechanism showing through, and so is a constant rate — so the
///     angle is a smooth function of the wall clock that surges and coasts once per DASH (see
///     ``swing``), which reads as each arc gliding into its neighbour's place rather than a wheel
///     being driven round.
///   * the dashes BREATHE. Their drawn fraction of each period oscillates on a slow sine against the
///     rotation, so the arcs lengthen and shorten as they travel and the figure never repeats a
///     silhouette. A fixed pattern going round at a fixed rate is the definition of a plastic spinner.
///
/// Both derive from the SAME wall clock, so nothing needs animation STATE: every working row in the
/// rail is at the identical phase, and a re-render lands mid-rotation instead of snapping the ring
/// back to the top (which is exactly what a `repeatForever` animation would do on every chrome tick).
/// REDUCE MOTION freezes it — and it stays legible frozen, because ``dashCount`` differs from the
/// resting ring's: still or moving, five long arcs are not eight short ones.
struct AgentSweepMark: View {
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Arcs around the working ring — FEWER than the resting ring's ``StatusDot/ringDashCount``, so
    /// the same circle carries more ink while it works. It is also what keeps the mark readable when
    /// motion is off: a frozen working ring differs from a resting one in its CUT, not just its hue.
    static let dashCount = 5
    /// Seconds per full revolution. Read it through the dashes, not the ring: what the eye tracks is
    /// one arc crossing into the next slot, which takes `revolution / dashCount` ≈ 0.7 s — brisk
    /// enough to say "working", calm enough to stay in the corner of the eye. Turning the RING itself
    /// at that rate would strobe: with rotational symmetry every `1/5` turn, a fast spin is eight
    /// visual cycles a second.
    static let revolution: Double = 3.6
    /// Seconds per breath of the dashes' LENGTH — deliberately not a multiple of ``revolution``, so
    /// the two cycles drift against each other and the motion never looks like a loop.
    static let breath: Double = 2.3
    /// ⚠️ How far the rotation LEADS and LAGS a constant rate, in turns. This is what stops the motion
    /// reading as plastic: a constant angular rate is the tell of a mechanism, so the ring accelerates
    /// and coasts once per DASH — the surge is tied to the dash period rather than the revolution
    /// because the dashes are what the eye tracks, and a surge per revolution would read as a wobble
    /// with no visible cause.
    ///
    /// The ceiling is arithmetic, not taste: the angle is `t + swing·sin(2πN·t)`, whose derivative is
    /// `1 + 2πN·swing·cos(2πN·t)`, so anything at or above `1/2πN` makes the ring STALL and then run
    /// BACKWARDS once a cycle — broken, not eased. 0.020 against five dashes gives roughly
    /// 0.37×…1.63× rate.
    static let swing: Double = 0.020
    /// The hard ceiling ``swing`` must stay under to keep the rotation monotonic — pinned by test.
    static var swingCeiling: Double { 1 / (2 * .pi * Double(dashCount)) }
    /// The DRAWN fraction of each dash period, sweeping between these two as the ring breathes. Never
    /// high enough to close the gaps (at 8pt, a 0.78 fill is a solid ring with notches in it) nor low
    /// enough to read as a dotted line rather than a circle.
    static let fillRange: ClosedRange<CGFloat> = 0.5...0.7
    /// The fill a REDUCE-MOTION mount holds still at — mid-breath, which is a frame the moving figure
    /// actually passes through.
    static var stillFill: CGFloat { (fillRange.lowerBound + fillRange.upperBound) / 2 }
    /// The frame ceiling while turning: 60 fps is smooth for a rotation this size, and bounding it
    /// keeps a rail full of working agents off the display's own 120 Hz treadmill.
    static let maxFrameInterval: Double = 1.0 / 60

    var body: some View {
        Group {
            if reduceMotion {
                ring(turns: 0, fill: Self.stillFill)
            } else {
                TimelineView(.animation(minimumInterval: Self.maxFrameInterval)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ring(turns: Self.turns(at: time), fill: Self.fill(at: time))
                }
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    /// The rotation for one instant, in TURNS (fractions of a revolution) — EASED, not linear: a
    /// constant rate is what made the earlier cuts read as plastic, so the angle leads and lags an
    /// even sweep by ``swing`` once per DASH (surging as an arc leaves its slot, coasting as it
    /// settles into the next). Always forward, never stalling — see ``swingCeiling``. Pure, so the
    /// cadence is unit-pinned headlessly and every mount at the same instant sits at the same angle.
    static func turns(at time: TimeInterval) -> Double {
        guard revolution > 0 else { return 0 }
        var phase = (time / revolution).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        // Keep the multiply and the add separate — never `addingProduct` (CLAUDE.md bit-exactness).
        let lead = swing * sin(phase * 2 * .pi * Double(dashCount))
        let eased = phase + lead
        // The ease can push the angle past a turn boundary; wrap so the result stays one clean turn.
        return eased - eased.rounded(.down)
    }

    /// The dashes' drawn fraction for one instant, oscillating across ``fillRange`` on a sine of
    /// ``breath``. Pure + clock-derived, so it needs no animation state and stays in unison across rows.
    static func fill(at time: TimeInterval) -> CGFloat {
        guard breath > 0 else { return stillFill }
        // Keep the multiply and the add separate — never `addingProduct` (CLAUDE.md bit-exactness).
        let swing = (sin(time / breath * 2 * .pi) + 1) / 2
        let span = fillRange.upperBound - fillRange.lowerBound
        return fillRange.lowerBound + CGFloat(swing) * span
    }

    /// The working ring's dash pattern for one breath frame — ``dashCount`` whole periods around the
    /// circumference (so the arcs stay evenly spread with no seam where the stroke closes), split into
    /// drawn/gap by `fill`.
    static func dash(fill: CGFloat) -> [CGFloat] {
        let period = .pi * StatusDot.ringDiameter / CGFloat(dashCount)
        return [period * fill, period * (1 - fill)]
    }

    private func ring(turns: Double, fill: CGFloat) -> some View {
        Circle()
            // FLAT ink and a dashed stroke: no gradient, no line caps to reason about. The comet cut
            // this replaced needed BOTH — and its round caps painted a half-disc past the stroke end
            // that picked up ink across the angular gradient's seam, showing up as a detached dot
            // chasing the arc. A dashed ring has no ends to cap and no seam to cross.
            .stroke(ink, style: StrokeStyle(
                lineWidth: StatusDot.ringLineWidth, dash: Self.dash(fill: fill),
            ))
            .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            .rotationEffect(.degrees(turns * 360))
    }
}

/// The RUNNING-COMMAND spinner — otty's `TabsPanelRowView` mounts an `NSProgressIndicator` in the
/// row's right slot while a command runs, and this is that wheel drawn on the house tokens: eight
/// tapered spokes with a comet tail, stepping ONE spoke per beat so the eye reads direction. Drawn
/// (not `ProgressView`) for three reasons: the ink is a theme token rather than the system accent,
/// the footprint is pinned to the mark column's, and the phase comes off the same fixed wall-clock
/// epoch the pulse uses — so every spinning row in the rail steps in unison and a re-render never
/// restarts the wheel. REDUCE MOTION freezes it on ``stillStep``.
///
/// It replaces the row's process-label text (the otty behaviour: the wheel says "running", the
/// title says what), so a busy row never carries two activity marks.
struct CommandSpinner: View {
    var ink: Color = Slate.Text.tertiary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Spokes around the wheel — the AppKit spinner's own count.
    static let spokeCount = 8
    /// Seconds per spoke step: 8 × 0.1 s = one revolution in 0.8 s (otty's own indeterminate cadence).
    static let beat: Double = 0.1
    /// The step a REDUCE-MOTION mount freezes on — spoke 0, the fully-lit wheel.
    static let stillStep = 0
    /// The wheel's diameter — the mark column's footprint, so a spinning row and a marked row keep
    /// the same trailing edge.
    static let diameter = StatusDot.footprint
    private static let spokeLength: CGFloat = 3.5
    private static let spokeWidth: CGFloat = 1.5

    var body: some View {
        Group {
            if reduceMotion {
                wheel(step: Self.stillStep)
            } else {
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0), by: Self.beat,
                )) { timeline in
                    wheel(step: StatusDot.frame(
                        at: timeline.date, frames: Self.spokeCount, beat: Self.beat,
                    ))
                }
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }

    private func wheel(step: Int) -> some View {
        ZStack {
            ForEach(0..<Self.spokeCount, id: \.self) { spoke in
                Capsule()
                    .fill(ink)
                    .frame(width: Self.spokeWidth, height: Self.spokeLength)
                    .opacity(Self.opacity(spoke: spoke, step: step))
                    .offset(y: -(Self.diameter / 2 - Self.spokeLength / 2))
                    .rotationEffect(.degrees(360 / Double(Self.spokeCount) * Double(spoke)))
            }
        }
    }

    /// A spoke's opacity: full at the LEADING spoke, ramping down with each step behind it — the
    /// comet tail that gives an otherwise symmetric wheel a direction. Never reaches zero, so the
    /// ring reads as a complete wheel rather than a broken arc.
    static func opacity(spoke: Int, step: Int) -> Double {
        let behind = ((step - spoke) % spokeCount + spokeCount) % spokeCount
        let fade = Double(behind) / Double(spokeCount)
        return 1 - fade * 0.75
    }
}
#endif
