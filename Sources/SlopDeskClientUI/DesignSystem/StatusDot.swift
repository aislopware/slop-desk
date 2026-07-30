// StatusDot — the sidebar row's trailing status mark. Round 19 (otty parity) makes the SHAPE the
// grammar and lets the hue ride along: the states you act on wear otty's own pictograms (`✋` a
// question waits, `●` an unread finish, `⚠` a failure), a WORKING agent breathes the app's own
// asterisk pulse (`StatusGlyph.agentFrames`, so the rail and the compact agent surfaces speak one
// vocabulary), and a resting code agent keeps the original static dashed ring (lucide
// `circle-dashed`) — present, spending no hue. An idle row renders null, so the resting rail stays
// bare, and the only thing that MOVES here is the agent's breath: motion means "in flight", never
// decoration. A plain running COMMAND mounts nothing in this column — its ``CommandSpinner`` takes
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
    ///
    /// ⚠️ Every star frame carries `\u{FE0E}` (VARIATION SELECTOR-15, text presentation). Bare
    /// U+2733 `✳` resolves to `AppleColorEmojiUI` on Apple platforms — a COLOUR emoji that ignores
    /// `foregroundStyle` and measures 16pt of advance where its Menlo siblings measure 6.62, so that
    /// one frame flashed a coloured star and jumped the mark's width mid-cycle. Same trap
    /// ``SlateTabRow`` already guards for the title's `✳` marker. `·` (U+00B7) is the font's own
    /// glyph and needs nothing; the selector is harmless on the frames that were already text.
    static let pulseFrames = [
        "·", "✢\u{FE0E}", "✳\u{FE0E}", "✶\u{FE0E}", "✻\u{FE0E}",
        "✽\u{FE0E}", "✻\u{FE0E}", "✶\u{FE0E}", "✳\u{FE0E}", "✢\u{FE0E}",
    ]
    /// Seconds per frame — the pulse breathes rather than spins.
    static let pulseBeat: Double = 0.15
    /// The frame a REDUCE-MOTION mount freezes on — the mid-swell asterisk, the one frame that
    /// reads as "an agent is here and busy" while standing still (`·` would read as a resting dot).
    static let pulseStillFrame = "✳\u{FE0E}"
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

/// The RUNNING-COMMAND spinner — otty mounts an `NSProgressIndicator` where its row's shell label
/// sits, and this is that slot behaviour in the row's OWN VOICE: the ASCII line spinner `| / - \`,
/// set in the instrument mono on the secondary ink, exactly the register of the `zsh` it displaces.
/// A drawn AppKit-style wheel was the first cut and read as foreign — system chrome parachuted into
/// a column of mono metadata.
///
/// Frame-stepped off the same fixed wall-clock epoch the agent pulse uses (via
/// ``StatusGlyph/frame(at:frames:beat:)``), so every spinning row in the rail steps in unison and a
/// re-render lands mid-cycle instead of restarting the cycle. REDUCE MOTION freezes it on
/// ``stillFrame``.
///
/// Distinct from the agent's breath by CHARACTER as well as by cadence: the agent blooms a star in
/// place, a command sweeps a line around — the two never read as the same thing on adjacent rows,
/// and neither can be mistaken for the still marks (ring, dot, hand, triangle).
struct CommandSpinner: View {
    /// One step up from the label's tertiary ink: a single thin stroke needs the extra contrast to
    /// read as motion where a whole word did not.
    var ink: Color = Slate.Text.secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The classic ASCII line spinner — the oldest one in the terminal, and the only cycle here that
    /// draws from the mono face's OWN glyphs. Braille (`⠋⠙⠹…` and the heavy `⣾⣽⣻…`) was tried first
    /// and BOTH are unusable in this slot: no mono face we can count on carries U+2800…U+28FF (the
    /// terminal's JetBrains Mono is not installed on every machine and the fallback is the system
    /// monospaced face), so CoreText substitutes **AppleBraille** — an embossing font that draws
    /// sparse little circles, ignores the weight, and makes the heavy and light cycles look
    /// identical and nearly invisible at 11pt. These four are the font's own, all at the SAME 6.8pt
    /// advance, so the slot cannot jitter as frames swap.
    static let frames = ["|", "/", "-", "\\"]
    /// Seconds per frame: 4 × 0.12 s = one rotation per 0.48 s — brisk enough to read as motion at a
    /// glance, slower than a terminal's own 80 ms spin. The rail is glanced at, not watched.
    static let beat: Double = 0.12
    /// The frame a REDUCE-MOTION mount freezes on — a rotation has no "complete" frame, so this is
    /// simply the first; every frame carries the same weight of ink.
    static let stillFrame = frames[0]
    /// The glyph's point size — the mark column's, so the spinner reads level with the marks down
    /// the trailing edge rather than a size below them.
    static let size = StatusDot.symbolSize

    var body: some View {
        Group {
            if reduceMotion {
                glyph(Self.stillFrame)
            } else {
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0), by: Self.beat,
                )) { timeline in
                    glyph(StatusGlyph.frame(
                        at: timeline.date, frames: Self.frames, beat: Self.beat,
                    ))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func glyph(_ text: String) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Self.size))
            .foregroundStyle(ink)
            .fixedSize()
    }
}
#endif
