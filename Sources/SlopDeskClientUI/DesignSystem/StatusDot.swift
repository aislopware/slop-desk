// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along. The agent's states are ONE CIRCLE at one diameter and one
// stroke weight, so they read as a progression instead of a legend: the ring is finely DASHED at rest
// (lucide `circle-dashed`), its dashes GATHER into five longer arcs with a LIGHT running through them
// while the agent works, and it becomes a FILLED dot once it has finished something unread. The two states you must
// ACT on stay in that same circle with a glyph inside it — `?` a question waits, `!` a failure. An
// idle row renders null, so the resting rail stays bare, and the only thing that MOVES here is the
// working ring — and even that moves only its INK, never its shape (``AgentWorkingMark``): motion means
// "in flight", never decoration. A plain running COMMAND mounts nothing in
// this column — its ``CommandSpinner`` wheel takes the process-label slot instead (``SlateTabRow``),
// so no row ever carries two activity marks.
//
// ⚠️ Both animated marks are DRAWN, never typed, and at this size both are FLAT INK — a gradient
// spends half its length being nearly invisible, which is legible only when magnified (see
// ``AgentWorkingMark``). A glyph spinner here was tried twice and abandoned:
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
import SwiftUI

/// The mark's SHAPE. A pure value (no view), so the resolver
/// (``StatusPresentation/statusDot(working:badge:agentIdle:)``) unit-tests without rendering.
///
/// The vocabulary is ONE circle whose COMPLETENESS rises with how much the row wants from you:
/// broken into fine dashes at rest → gathered into five arcs with a light running through them while it
/// works → CLOSED and
/// still when it is waiting on you → FILLED once it has finished something unread.
///
/// ⚠️ ``question`` and ``alert`` draw the SAME closed ring and are told apart by hue alone (amber vs
/// red). That is a deliberate user ruling — the `?` and `!` glyphs inside the ring were pulled for
/// looking fussy at 8pt — and it is the one place in this column where hue is load-bearing on its own.
/// Both states also speak through the row's own copy (title, tooltip, VoiceOver value), so the hue is
/// the fast read rather than the only one.
enum StatusMarkShape: Equatable, Hashable, CaseIterable {
    /// The static, finely dashed ring — a code agent PRESENT and at rest.
    case ring
    /// The same ring with its dashes gathered into fewer, longer arcs, a light travelling through them
    /// — a WORKING agent. The one animated mark in this column, and it animates only its INK: the
    /// silhouette is as still as the resting ring's. Named for the STATE, not the motion, because the
    /// motion has now been recut five times.
    case working
    /// The ring CLOSED and still — a question waits on you. Amber.
    case question
    /// The filled dot — an unread finish.
    case dot
    /// The ring CLOSED and still — a failure. Red. Drawn identically to ``question``: since the
    /// glyphs came out, these two are told apart by HUE alone (see the enum's own note).
    case alert

    /// Whether this shape MOVES. Only the working sweep does: a settled rail is motionless.
    var animates: Bool { self == .working }
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
    /// working ring is the same circle cut into FEWER, longer arcs (``AgentWorkingMark/dashCount``), so
    /// the two states differ in cut as well as in hue and motion.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6
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
        case .working:
            AgentWorkingMark(ink: style.ink)
        case .dot:
            Circle()
                .fill(style.ink)
                .frame(width: StatusDot.dotDiameter, height: StatusDot.dotDiameter)
        case .alert,
             .question:
            // The ring CLOSED and still — the two states waiting on a human. No glyph inside: `?`
            // and `!` shipped here and were pulled for reading as fussy detail at 8pt (the third
            // time this column has learned that lesson). What remains is the completeness ladder —
            // dashed at rest, turning at work, CLOSED when it wants you, filled when it is done —
            // with hue separating amber from red.
            Circle()
                .stroke(style.ink, lineWidth: StatusDot.ringLineWidth)
                .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
        }
    }
}

/// The WORKING-AGENT mark — the RESTING RING'S OWN DASHES, gathered into five longer arcs, with a
/// LIGHT running round them. That is the whole idea: the agent's column is ONE circle at the same
/// diameter and stroke weight throughout, so its states read as a progression rather than as a legend
/// to learn — the ring is finely dashed while the agent waits at its prompt, its dashes gather into
/// fewer, longer arcs and a pulse of ink travels through them while it works, and it becomes a FILLED
/// dot once it has finished something you haven't read.
///
/// ⚠️ NOTHING HERE MOVES GEOMETRICALLY. The arcs sit at fixed angles for the mark's whole life; what
/// travels is BRIGHTNESS, each arc handing the light to its neighbour. That is the point, and it is the
/// fifth cut of this mark — the four before it all moved the shape and were all rejected as cheap:
///
///   1. the asterisk bloom TYPED in the instrument face — the mono face has no star, so AppleColorEmojiUI
///      drew `✳` as a COLOUR emoji at 2.4× the advance;
///   2. the same bloom DRAWN as capsules — at 12pt a radiating star is a burr of spikes, and magnified
///      it is a cogwheel;
///   3. a solid arc with a dissolving comet TAIL — which is what every loading spinner on every platform
///      already is, and at 12pt a gradient spends half its length invisible, so it read generic-to-muddy
///      no matter how it was eased;
///   4. the dashed ring TURNING, with the arcs splitting into ten and knitting back into five — the
///      split read as a gimmick, and a turning ring is still a spinner.
///
/// The rules those four bought, all of which this cut obeys: at 12pt use FLAT INK and WHOLE SHAPES
/// (gradients and detail are luxuries of the zoomed-in view); a mark this size carries exactly ONE idea;
/// and a rail that jitters is worse than a rail that is dull, so the moving thing here is light rather
/// than geometry. It also gets the rail closest to round 9's original verdict (*nothing in the rail
/// animates*) while still saying "in flight": the figure's silhouette is as still as the resting ring's.
///
/// The travel is a smooth function of the wall clock sampled per display frame, so nothing needs
/// animation STATE: every working row in the rail lights the same arc at the same instant, and a
/// re-render lands mid-lap instead of restarting the chase (which is exactly what a `repeatForever`
/// animation would do on every chrome tick). REDUCE MOTION freezes the light at the TOP of the ring —
/// and the mark stays legible frozen, because ``dashCount`` differs from the resting ring's: still or
/// moving, five long arcs are not eight short ones.
struct AgentWorkingMark: View {
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Arcs around the working ring — FEWER than the resting ring's ``StatusDot/ringDashCount``, so
    /// the same circle carries more ink while it works. It is also what keeps the mark readable when
    /// motion is off: a frozen working ring differs from a resting one in its CUT, not just its hue.
    static let dashCount = 5
    /// The DRAWN fraction of each arc's slot. Above ~0.75 the ring is a solid circle with notches in it;
    /// below ~0.5 it reads as a dotted line rather than a circle.
    static let dashFill: CGFloat = 0.62
    /// Seconds for the light to travel once round the ring — so an arc lights every `lap / dashCount`
    /// ≈ 0.24 s. Faster than the eye can count and slower than a flicker: it reads as one light moving,
    /// which is the entire illusion. Halve it and the ring strobes; double it and the mark looks asleep.
    static let lap: Double = 1.2
    /// The pulse's width, as a standard deviation in TURNS. At ~0.7 of an arc slot the light is clearly
    /// ON one arc while just touching its neighbours — which is what makes the hand-off read as travel
    /// rather than as five arcs blinking in sequence.
    static let pulseWidth: Double = 0.14
    /// How dim an arc gets when the light is on the far side. NOT zero: the ring must stay a ring — the
    /// comet cut proved that ink fading to nothing at 12pt just disappears, and half a ring vanishing
    /// is the "generic spinner" look this replaced. The floor is what keeps the SHAPE constant while
    /// only the light moves.
    static let dimFloor: Double = 0.28
    /// Where a REDUCE-MOTION mount parks the light: ON the arc nearest the TOP of the ring. ⚠️ Not 12
    /// o'clock itself — with five arcs nothing sits exactly there, and parking the light in a GAP is the
    /// one frozen frame that reads as broken: two arcs half-lit, none of them the subject. Computed
    /// rather than written down, so it stays on an arc if ``dashCount`` ever changes.
    static var stillPhase: Double {
        let top = 0.75 // 0 is 3 o'clock, turning clockwise
        let nearest = (0..<dashCount).min { lhs, rhs in
            abs(middle(arc: lhs) - top) < abs(middle(arc: rhs) - top)
        } ?? 0
        return middle(arc: nearest)
    }

    /// The frame ceiling: 60 fps is smooth for a fade this small, and bounding it keeps a rail full of
    /// working agents off the display's own 120 Hz treadmill.
    static let maxFrameInterval: Double = 1.0 / 60

    var body: some View {
        Group {
            if reduceMotion {
                ring(phase: Self.stillPhase)
            } else {
                TimelineView(.animation(minimumInterval: Self.maxFrameInterval)) { timeline in
                    ring(phase: Self.phase(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    /// Where the light is at one instant, in TURNS clockwise from 3 o'clock. Linear: the travel of a
    /// light has no mass, so easing it would be the mechanism showing through rather than hidden — the
    /// opposite of the turning cut, where a constant rate was exactly the tell. Pure, so the cadence is
    /// unit-pinned headlessly and every mount at the same instant lights the same arc.
    static func phase(at time: TimeInterval) -> Double {
        guard lap > 0 else { return stillPhase }
        var phase = (time / lap).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return phase
    }

    /// Where an arc STARTS, in turns — a function of its index and nothing else. The signature is the
    /// invariant: this mark cannot move its geometry, because there is no instant to move it with.
    static func start(arc: Int) -> Double { Double(arc) / Double(dashCount) }

    /// One arc's length, in turns — ``dashFill`` of its slot.
    static var arcLength: Double { Double(dashFill) / Double(dashCount) }

    /// The MIDDLE of an arc, in turns — what the light's distance is measured to, so an arc reaches full
    /// ink when the light is over its centre rather than as the light arrives at its leading edge.
    static func middle(arc: Int) -> Double { start(arc: arc) + arcLength / 2 }

    /// How lit an arc is when the light sits at `phase` — a gaussian on the WRAPPED angular distance
    /// between the two, so the chase has no seam at 12 o'clock (an unwrapped distance would make the
    /// light stall and jump there once per lap). Never below ``dimFloor``.
    static func brightness(arc: Int, phase: Double) -> Double {
        guard pulseWidth > 0 else { return 1 }
        var gap = abs(middle(arc: arc) - phase)
        gap = Double.minimum(gap, 1 - gap)
        let lit = exp(-((gap / pulseWidth) * (gap / pulseWidth)))
        // Keep the multiply and the add separate — never `addingProduct` (CLAUDE.md bit-exactness).
        let span = 1 - dimFloor
        return dimFloor + span * lit
    }

    private func ring(phase: Double) -> some View {
        ZStack {
            ForEach(0..<Self.dashCount, id: \.self) { arc in
                Circle()
                    .trim(from: 0, to: Self.arcLength)
                    .stroke(
                        ink.opacity(Self.brightness(arc: arc, phase: phase)),
                        style: StrokeStyle(lineWidth: StatusDot.ringLineWidth, lineCap: .butt),
                    )
                    .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
                    .rotationEffect(.degrees(Self.start(arc: arc) * 360))
            }
        }
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
