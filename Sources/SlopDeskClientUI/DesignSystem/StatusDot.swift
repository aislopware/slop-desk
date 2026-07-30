// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along: the states you act on wear otty's own pictograms (`✋` a
// question waits, `●` an unread finish, `⚠` a failure), a WORKING agent breathes a DRAWN asterisk,
// and a resting code agent keeps the original static dashed ring (lucide `circle-dashed`) — present,
// spending no hue. An idle row renders null, so the resting rail stays bare, and the only thing that
// MOVES here is the agent's breath: motion means "in flight", never decoration. A plain running
// COMMAND mounts nothing in this column — its ``CommandSpinner`` wheel takes the process-label slot
// instead (``SlateTabRow``), so no row ever carries two activity marks.
//
// ⚠️ Both animated marks are DRAWN, never typed. A glyph spinner here was tried and abandoned: the
// instrument face is only JetBrains Mono when that font is installed (it is not, on every machine),
// so anything outside the system monospaced face's own coverage gets SUBSTITUTED — braille lands in
// AppleBraille (embossing dots, weight ignored, invisible at 11pt) and a bare dingbat star lands in
// AppleColorEmojiUI (a colour emoji that ignores `foregroundStyle` and is 2.4× the advance). Vector
// strokes have none of that: exact size, exact ink, no font on the machine to get in the way.
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
        case .pulse:
            AgentPulseMark(ink: style.ink)
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

/// The WORKING-AGENT mark — the AI-CLI asterisk pulse, DRAWN: six spokes budding out of a centre dot
/// and settling back, the `· ✢ ✳ ✶ ✻ ✽` bloom as vector strokes. The same figure was first typed in
/// the instrument face and it looked wrong for reasons that had nothing to do with the design — the
/// mono face on this machine has no star of its own, so Menlo drew some frames and AppleColorEmojiUI
/// drew others as a COLOUR emoji at 2.4× the advance. Drawn, the bloom is exact at any size, wears
/// the accent ink it is handed, and depends on no font being installed.
///
/// Stepped (not eased) on ``StatusDot/frame(at:frames:beat:)`` so it breathes in hard swaps like a
/// terminal spinner and stays in unison across rows. REDUCE MOTION freezes it at full bloom — the
/// frame that reads "an agent is here and busy" while standing still.
struct AgentPulseMark: View {
    var ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Spokes of the star — six, the asterisk's own count. Eight muddies into a blob at 12pt.
    static let spokeCount = 6
    /// The bloom, as each frame's fraction of full spoke length. A PALINDROME, so the star swells and
    /// settles without easing; frame 0 is bare centre dot (the `·` the cycle used to open on).
    static let bloom: [CGFloat] = [0, 0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]
    /// Seconds per frame — the pulse breathes rather than spins.
    static let beat: Double = 0.15
    /// The frame a REDUCE-MOTION mount freezes on — full bloom, the widest reading of "busy".
    static let stillFrame = 5

    private static let centreDiameter: CGFloat = 2.6
    private static let innerRadius: CGFloat = 1.9
    private static let spokeLength: CGFloat = 3.6
    private static let spokeWidth: CGFloat = 1.4

    var body: some View {
        Group {
            if reduceMotion {
                star(frame: Self.stillFrame)
            } else {
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0), by: Self.beat,
                )) { timeline in
                    star(frame: StatusDot.frame(
                        at: timeline.date, frames: Self.bloom.count, beat: Self.beat,
                    ))
                }
            }
        }
        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
    }

    private func star(frame: Int) -> some View {
        let scale = Self.bloom[min(max(frame, 0), Self.bloom.count - 1)]
        let length = Self.spokeLength * scale
        return ZStack {
            // The centre dot is always drawn: at scale 0 it IS the mark, so the cycle never blinks out.
            Circle()
                .fill(ink)
                .frame(width: Self.centreDiameter, height: Self.centreDiameter)
            ForEach(0..<Self.spokeCount, id: \.self) { spoke in
                Capsule()
                    .fill(ink)
                    .frame(width: Self.spokeWidth, height: length)
                    .offset(y: -(Self.innerRadius + length / 2))
                    .rotationEffect(.degrees(360 / Double(Self.spokeCount) * Double(spoke)))
            }
            // A zero-length capsule still paints its own cap; hide the spokes outright at the bud.
            .opacity(scale > 0 ? 1 : 0)
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
