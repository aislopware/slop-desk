// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along. The agent's states are ONE CIRCLE at one diameter and one
// stroke weight, so they read as a progression instead of a legend: the ring is finely DASHED at rest
// (lucide `circle-dashed`), becomes ONE SOLID ARC chasing its own tail round the circle while the agent
// works, and a FILLED dot once it has finished something unread. The two states you must
// ACT on stay in that same circle with a glyph inside it — `?` a question waits, `!` a failure. An
// idle row renders null, so the resting rail stays bare, and the only thing that MOVES here is the
// working arc: motion means "in flight", never decoration. A plain running COMMAND mounts nothing in
// this column — its ``CommandSpinner`` wheel takes the process-label slot instead (``SlateTabRow``),
// so no row ever carries two activity marks.
//
// ⚠️ Both animated marks are DRAWN, never typed, and at this size both are FLAT INK — a gradient
// spends half its length being nearly invisible, which is legible only when magnified (``AgentWorkingMark``
// carries the full history of that lesson). A glyph spinner here was tried twice and abandoned:
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
/// broken into fine dashes at rest → one live arc chasing its tail while it works → CLOSED and
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
    /// The same ring — the identical cut — with a light travelling through its dashes: a WORKING agent. The one animated mark in this column, and it animates only its INK: the
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
    /// working mark is the same circle drawn as ONE SOLID ARC instead (``AgentWorkingMark``), so the two
    /// states differ in shape as well as in hue — which is what keeps them apart when motion is off.
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

/// The WORKING-AGENT mark — a SOLID arc that chases its own tail round the circle. The head runs ahead
/// to a mark, the tail catches up to it, and the whole figure keeps turning: one revolution and one
/// grow-and-collapse per 1.4 s cycle, so the arc is never the same length twice in a row and never
/// stops. Same diameter and stroke weight as every other mark in the column, so the family holds — the
/// ring is finely dashed while the agent waits, becomes this one live arc while it works, and a FILLED
/// dot once it has finished something you haven't read.
///
/// ⚠️ This is the SIXTH cut, and it is deliberately close to the THIRD — which was rejected. The
/// difference is the whole lesson, so it is written down: cut 3 was a solid arc whose tail dissolved
/// through an `AngularGradient`, and what failed was the GRADIENT, not the arc. At 12pt a fade spends
/// half its length invisible, so the figure read as a shrinking smudge and needed a `lineCap` argument
/// about ink bleeding across the gradient's seam. This cut is FLAT INK with two hard ends: the "tail"
/// is a real geometric end that moves, not a fade. Which also makes ROUND caps safe again — with no
/// gradient there is no seam for a cap to pick ink up across, and round ends are what make a spinner
/// look drawn rather than cut.
///
/// The full history, because five of these were rejected on looks and each bought a rule:
///
///   1. the asterisk bloom TYPED in the instrument face — the mono face has no star, so AppleColorEmojiUI
///      drew `✳` as a COLOUR emoji at 2.4× the advance ⇒ animated marks are DRAWN, never typed;
///   2. the same bloom DRAWN as capsules — at 12pt a radiating star is a burr of spikes ⇒ one stroke
///      scales down, detail does not;
///   3. a solid arc with a dissolving comet TAIL ⇒ at 12pt use FLAT INK, never a gradient;
///   4. a dashed ring TURNING, its arcs splitting into ten and knitting back into five ⇒ a mark this
///      size carries exactly ONE idea;
///   5. the dashed ring standing still with a LIGHT running through its dashes — the calmest cut of all
///      and still not it ⇒ this column is allowed to look like a spinner, as long as it looks like a
///      GOOD one.
///
/// Everything is derived from the wall clock, sampled per display frame, so the mark holds no animation
/// STATE: every working row in the rail is at the identical phase, and a re-render lands mid-cycle
/// instead of snapping the head back to the top (which is exactly what a `repeatForever` animation would
/// do on every chrome tick). REDUCE MOTION freezes it at its widest, where the arc is unmistakably an
/// arc — and the frozen mark still differs from the resting ring by SHAPE (one solid arc against eight
/// dashes), not merely by hue.
struct AgentWorkingMark: View {
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per cycle — one grow-and-collapse of the arc, and one full revolution of the figure.
    /// Material's own indeterminate circular indicator runs at 1.33 s; 1.4 s reads the same and lines up
    /// with nothing else in the chrome, so a rail of working rows never beats against the footer.
    static let cycle: Double = 1.4
    /// How far the HEAD runs ahead of the tail before the tail follows, in turns — the "mark" the head
    /// aims at. Three quarters: long enough that the arc is unmistakably an arc at its widest, short
    /// enough that the gap never closes into a plain circle (a closed ring shows nothing).
    static let span: Double = 0.75
    /// The extra turn the figure drifts per cycle, on top of the ``span`` the arc itself advances. Set so
    /// `span + spin` is exactly ONE turn: the head therefore lands on the same clock position every
    /// cycle, which is what stops a spinner from looking like it is wandering.
    static var spin: Double { 1 - span }
    /// The arc's shortest length, in turns. NOT zero: an arc that collapses to nothing blinks out at the
    /// end of every cycle, and a mark that vanishes 40 times a minute reads as broken rather than busy.
    /// At ~25° it is still visibly an arc with two ends, which is what the eye needs to see it turning.
    static let minSweep: Double = 0.07
    /// The frame ceiling: 60 fps is what makes a rotation this size read as smooth rather than as steps,
    /// and bounding it keeps a rail full of working agents off the display's own 120 Hz treadmill.
    static let maxFrameInterval: Double = 1.0 / 60

    var body: some View {
        Group {
            if reduceMotion {
                arc(tail: 0, sweep: Self.span)
            } else {
                TimelineView(.animation(minimumInterval: Self.maxFrameInterval)) { timeline in
                    let figure = Self.figure(at: timeline.date.timeIntervalSinceReferenceDate)
                    arc(tail: figure.tail, sweep: figure.sweep)
                }
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    /// The arc at one instant: where its TAIL sits (in absolute turns, growing forever) and how long it
    /// is. Pure, so the cadence is unit-pinned headlessly and every mount at the same instant draws the
    /// same figure.
    ///
    /// The shape of the motion: in the FIRST half of a cycle the head runs from the tail to ``span``; in
    /// the SECOND half the tail catches up to it. Both moves are eased (smoothstep), so the arc swells
    /// and collapses smoothly instead of snapping. ⚠️ The two halves are what make the cycle seamless:
    /// at the end of a cycle head and tail have both travelled exactly `span`, which is precisely where
    /// the next cycle starts from — no reset, no jump, and therefore no need for animation state.
    static func figure(at time: TimeInterval) -> (tail: Double, sweep: Double) {
        guard cycle > 0 else { return (0, span) }
        let cycles = time / cycle
        let index = cycles.rounded(.down)
        let phase = cycles - index
        // The head leads through the first half; the tail follows through the second.
        let head = span * ease(Double.minimum(1, phase * 2))
        let follow = span * ease(Double.maximum(0, phase * 2 - 1))
        // Keep the multiply and the add separate — never `addingProduct` (CLAUDE.md bit-exactness).
        let drift = spin * phase
        let base = index * (span + spin)
        let tail = base + drift + follow
        return (tail, Double.maximum(minSweep, head - follow))
    }

    /// Smoothstep — flat at both ends, steep through the middle. The head accelerates away and settles
    /// onto its mark rather than arriving at a constant rate, which is the difference between a spinner
    /// that looks drawn and one that looks driven.
    static func ease(_ value: Double) -> Double {
        let clamped = Double.maximum(0, Double.minimum(1, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func arc(tail: Double, sweep: Double) -> some View {
        Circle()
            .trim(from: 0, to: sweep)
            // FLAT ink and ROUND caps. Flat because a gradient at 12pt spends half its length invisible
            // (cut 3); round because with no gradient there is no seam for a cap to pick up ink across,
            // which is the bug that made cut 3's tail sprout a detached dot.
            .stroke(
                ink, style: StrokeStyle(lineWidth: StatusDot.ringLineWidth, lineCap: .round),
            )
            .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            .rotationEffect(.degrees(tail * 360))
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
