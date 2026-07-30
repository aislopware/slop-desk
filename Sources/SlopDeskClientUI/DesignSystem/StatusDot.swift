// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along: the states you act on wear otty's own pictograms (`✋` a
// question waits, `●` an unread finish, `⚠` a failure), a WORKING agent breathes the app's own
// asterisk pulse (`StatusGlyph.agentFrames`, so the rail and the compact agent surfaces speak one
// vocabulary), and a resting code agent keeps the original static dashed ring (lucide
// `circle-dashed`) — present, spending no hue. An idle row renders null, so the resting rail stays
// bare, and the only thing that MOVES here is the agent's breath: motion means "in flight", never
// decoration. A plain running COMMAND mounts nothing in this column — its ``SpokeSpinner`` takes
// the process-label slot instead (``SlateTabRow``), so no row ever carries two activity marks.
//
// Every mark renders inside ONE fixed footprint, so a state edge — or a spinner frame — can never
// move a pixel of the row's trailing edge. Hang-safety (CLAUDE.md #6): pure SwiftUI drawing +
// text, no capture/codec/Metal anywhere.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The mark's SHAPE — one per state, so the pictogram reads before its hue does. A pure value
/// (no view), so the resolver (``StatusPresentation/statusDot(working:badge:agentIdle:)``)
/// unit-tests without rendering.
enum StatusMarkShape: Equatable, Hashable, CaseIterable {
    /// The static dashed ring — a code agent PRESENT and at rest.
    case ring
    /// The breathing asterisk — a WORKING agent. The one animated mark in this column.
    case pulse
    /// The raised hand — a question waits on you.
    case hand
    /// The filled dot — an unread finish.
    case dot
    /// The warning triangle — a failure.
    case alert

    /// Whether this shape MOVES. Only the working pulse does: a settled rail is motionless.
    var animates: Bool { self == .pulse }
}

/// The mark's geometry + cadence — pure constants, unit-testable.
enum StatusDot {
    /// The mark's fixed footprint — one column width, so the right edge never wavers between rows
    /// (nor between shapes: ring, glyph and symbol all centre in this box).
    static let footprint: CGFloat = 12
    /// The ring's diameter within the footprint.
    static let ringDiameter: CGFloat = 8
    static let ringLineWidth: CGFloat = 1.5
    /// Dash segments around the ring — the lucide `circle-dashed` cut T3 Code mounts.
    static let ringDashCount = 8
    /// The drawn fraction of each dash period — lucide's roughly-even dash/gap rhythm.
    static let ringDashFill: CGFloat = 0.6
    /// The point size the SYMBOL marks (hand, triangle) and the pulse glyph draw at inside
    /// ``footprint`` — one step under the row title, so a mark reads as an instrument beside the
    /// name rather than competing with it.
    static let symbolSize: CGFloat = 11
    /// The filled unread-finish dot's diameter — smaller than the ring it replaced: a solid mark
    /// carries more weight per point than an outline one.
    static let dotDiameter: CGFloat = 6

    /// The dash pattern: ``ringDashCount`` segments spread evenly around the circumference.
    static var ringDash: [CGFloat] {
        let period = .pi * ringDiameter / CGFloat(ringDashCount)
        return [period * ringDashFill, period * (1 - ringDashFill)]
    }

    /// The working agent's breath — a dot budding into an asterisk and back (the AI-CLI loading
    /// pulse). Cycled as hard swaps; the palindrome makes the loop breathe without easing. The ONE
    /// definition: ``StatusGlyph`` (the iOS toolbar / Peek & Reply header) reads its `agentFrames`
    /// from here, so no two surfaces can disagree about one pane's `working`.
    static let pulseFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    /// Seconds per frame — the pulse breathes rather than spins.
    static let pulseBeat: Double = 0.15
    /// The frame a REDUCE-MOTION mount freezes on — the mid-swell asterisk, the one frame that
    /// reads as "an agent is here and busy" while standing still (`·` would read as a resting dot).
    static let pulseStillFrame = "✳"
}

/// One resolved mark: the SHAPE that names the state plus the ink it wears.
struct StatusDotStyle: Equatable {
    let shape: StatusMarkShape
    let ink: Color
}

/// The mark itself. AX-hidden: the row title's accessibility value already speaks the same state,
/// so the mark never double-announces. The pulse is FRAME-STEPPED off a fixed wall-clock epoch —
/// hard glyph swaps, so every spinning row steps in unison and a re-render lands mid-cycle instead
/// of restarting it; REDUCE MOTION freezes it on ``StatusDot/pulseStillFrame`` rather than hiding
/// the state.
struct StatusDotView: View {
    let style: StatusDotStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        case .pulse:
            if reduceMotion {
                glyph(StatusDot.pulseStillFrame)
            } else {
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0), by: StatusDot.pulseBeat,
                )) { timeline in
                    glyph(StatusGlyph.frame(
                        at: timeline.date, frames: StatusDot.pulseFrames, beat: StatusDot.pulseBeat,
                    ))
                }
            }
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

    /// One pulse frame, in the instrument (mono) face so the agent's breath reads in the terminal's
    /// own voice — `fixedSize` because the asterisk frames have differing advance widths.
    private func glyph(_ text: String) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(StatusDot.symbolSize, weight: .semibold))
            .foregroundStyle(style.ink)
            .fixedSize()
    }

    private func symbol(_ symbol: SFSymbol) -> some View {
        Image(systemSymbol: symbol)
            .font(.system(size: StatusDot.symbolSize, weight: .semibold))
            .foregroundStyle(style.ink)
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
struct SpokeSpinner: View {
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
                    wheel(step: Self.step(at: timeline.date))
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

    /// The lit spoke for one wall-clock instant — pure + static so the cadence is unit-pinned
    /// headlessly (one spoke per beat, wraps at ``spokeCount``, never skips on a re-render).
    static func step(at date: Date) -> Int {
        guard beat > 0 else { return stillStep }
        let phase = date.timeIntervalSinceReferenceDate / beat
        let index = Int(phase.rounded(.down)) % spokeCount
        return index < 0 ? index + spokeCount : index
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
