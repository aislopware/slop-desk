// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along. The agent's states are ONE CIRCLE at one diameter and one
// stroke weight, so they read as a progression instead of a legend: the ring is DASHED at rest
// (lucide `circle-dashed`), CLOSES with a gap travelling around it while the agent works, and becomes
// a FILLED dot once it has finished something unread. The two states you must ACT on step outside that
// circle deliberately, wearing otty's own pictograms — `✋` a question waits, `⚠` a failure. An idle
// row renders null, so the resting rail stays bare, and the only thing that MOVES here is the working
// ring: motion means "in flight", never decoration. A plain running COMMAND mounts nothing in this
// column — its ``CommandSpinner`` wheel takes the process-label slot instead (``SlateTabRow``), so no
// row ever carries two activity marks.
//
// ⚠️ Both animated marks are DRAWN, never typed. A glyph spinner here was tried twice and abandoned:
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
    /// The static dashed ring — a code agent PRESENT and at rest.
    case ring
    /// The same ring CLOSED, with a gap travelling around it — a WORKING agent. The one animated
    /// mark in this column.
    case sweep
    /// The raised hand — a question waits on you.
    case hand
    /// The filled dot — an unread finish.
    case dot
    /// The warning triangle — a failure.
    case alert

    /// Whether this shape MOVES. Only the working sweep does: a settled rail is motionless.
    var animates: Bool { self == .sweep }
}

/// The mark's geometry + cadence — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows
    /// (nor between shapes: ring, star and symbol all centre in this box).
    static let footprint: CGFloat = 12
    /// The ring's diameter within the footprint.
    static let ringDiameter: CGFloat = 8
    static let ringLineWidth: CGFloat = 1.5
    /// Dash segments around the ring — the lucide `circle-dashed` cut T3 Code mounts.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6
    /// The point size the SYMBOL marks (hand, triangle) draw at inside ``footprint`` — one step under
    /// the row title, so a mark reads as an instrument beside the name rather than competing with it.
    static let symbolSize: CGFloat = 11
    /// The filled unread-finish dot's diameter — smaller than the ring it replaced: a solid mark
    /// carries more weight per point than an outline one.
    static let dotDiameter: CGFloat = 6

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
        case .hand:
            symbol(.handRaised)
        case .dot:
            Circle()
                .fill(style.ink)
                .frame(width: StatusDot.dotDiameter, height: StatusDot.dotDiameter)
        case .alert:
            symbol(.exclamationmarkTriangleFill)
        }
    }

    private func symbol(_ symbol: SFSymbol) -> some View {
        Image(systemSymbol: symbol)
            .font(.system(size: StatusDot.symbolSize, weight: .semibold))
            .foregroundStyle(style.ink)
    }
}

/// The WORKING-AGENT mark — the RESTING RING, closed, with a gap travelling around it. That is the
/// whole idea: the agent's column is ONE circle at the same diameter and stroke weight throughout, so
/// its states read as a progression rather than as a legend to learn — the ring is DASHED while the
/// agent waits at its prompt, CLOSES and turns while it works, and becomes a FILLED dot once it has
/// finished something you haven't read.
///
/// Two earlier cuts of this mark are retired, both for looking bad at 12pt rather than in principle:
/// the asterisk bloom TYPED in the instrument face (the mono face has no star of its own, so Menlo
/// drew some frames and AppleColorEmojiUI drew `✳` as a COLOUR emoji at 2.4× the advance), and the
/// same bloom DRAWN as six capsules — at this size a radiating star is a burr of spikes, and blown up
/// it reads as a cogwheel. A single stroke survives scaling; detail does not.
///
/// Stepped (not eased) on ``StatusDot/frame(at:frames:beat:)`` off the fixed epoch, so every working
/// row turns in unison and a re-render lands mid-rotation instead of restarting it. REDUCE MOTION
/// freezes it at step 0 — still a closed ring with a gap, which reads as "not at rest" while
/// standing still.
struct AgentSweepMark: View {
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Steps per revolution — 12 × ``beat`` ≈ one turn per second. Enough that the gap glides rather
    /// than hops, without paying for a frame nobody can see.
    static let steps = 12
    static let beat: Double = 0.08
    /// The step a REDUCE-MOTION mount freezes on — the gap at the top of the ring.
    static let stillStep = 0
    /// The drawn fraction of the circumference: the ring closes except for one gap. Distinct from the
    /// resting ring at a glance, which spends the SAME ink on eight small gaps instead of one.
    static let drawnFraction: CGFloat = 0.82

    var body: some View {
        Group {
            if reduceMotion {
                ring(step: Self.stillStep)
            } else {
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0), by: Self.beat,
                )) { timeline in
                    ring(step: StatusDot.frame(
                        at: timeline.date, frames: Self.steps, beat: Self.beat,
                    ))
                }
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    private func ring(step: Int) -> some View {
        Circle()
            .trim(from: 0, to: Self.drawnFraction)
            .stroke(ink, style: StrokeStyle(
                lineWidth: StatusDot.ringLineWidth, lineCap: .round,
            ))
            .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            .rotationEffect(.degrees(360 / Double(Self.steps) * Double(step)))
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
