// AsciiStatusBadge — the sidebar row's status, spoken as TEXT in the instrument voice (the terminal's
// own dialect) instead of a drawn ring. The row is flush-left (no leading glyph column); this badge
// rides the line-1 TRAILING cluster next to the telemetry number, so `✻ 4m` reads like an AI CLI's
// status line. Two live states animate as FRAME-STEPPED loading spinners (hard glyph swaps on the
// wall clock — discrete frames, nothing rotates or eases):
//   • agent working  → the AI-CLI pulse `· ✢ ✳ ✶ ✻ ✽` breathing out and back, in the accent hue;
//   • command running/busy → the classic braille dot-walker `⠋⠙⠹…`, muted — the shell's dialect.
// Terminal states are static characters: `?` amber (answer me), `✗` red (broken), `✓` green/muted
// (unread finish / decayed), `#` (sudo — the root prompt's own sigil), `∞` (caffeinate — never
// sleeps). Both spinners phase off a fixed epoch so every spinning row in the sidebar steps in
// unison and a re-render can't reset a cycle. Pure SwiftUI text — no video/capture (hang-safety #6).

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The text-glyph status badge for one sidebar tab row. AX-labelled via the shared
/// ``StatusPresentation/tabBadgeLabel(_:)`` vocabulary so the reading stays VoiceOver-legible.
struct AsciiStatusBadge: View {
    let kind: TabBadgeKind

    /// The agent spinner's frames — a dot budding into an asterisk and back (the AI-CLI loading
    /// pulse). Cycled as hard swaps; the palindrome makes the loop breathe without easing.
    static let agentFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    /// The command spinner's frames — the braille dot-walker every terminal tool spins.
    static let commandFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    /// Seconds per frame: the agent pulse breathes; the braille walk is brisker (a mechanical
    /// command, not a thinking agent).
    static let agentBeat: Double = 0.15
    static let commandBeat: Double = 0.1

    /// The fixed glyph slot — star / braille / check advance widths differ, so the frame pins the
    /// cluster's layout while frames (or states) swap.
    static let slotWidth: CGFloat = 13

    var body: some View {
        reading
            .frame(width: Self.slotWidth, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
            .help(StatusPresentation.tabBadgeLabel(kind))
    }

    @ViewBuilder private var reading: some View {
        switch kind {
        case .running:
            spinner(Self.agentFrames, beat: Self.agentBeat, tint: Slate.State.accent)
        case .commandRunning,
             .commandBusy:
            spinner(Self.commandFrames, beat: Self.commandBeat, tint: Slate.Text.secondary)
        case .awaitingInput: glyph("?", tint: Slate.Status.warn, weight: .bold)
        case .error: glyph("✗", tint: Slate.Status.err, weight: .semibold)
        case .completed: glyph("✓", tint: Slate.Status.ok, weight: .semibold)
        case .finished: glyph("✓", tint: Slate.Text.secondary, weight: .semibold)
        case .caffeinate: glyph("∞", tint: Slate.Text.secondary, weight: .semibold)
        case .sudo: glyph("#", tint: Slate.Text.secondary, weight: .semibold)
        }
    }

    private func glyph(_ text: String, tint: Color, weight: Font.Weight) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Slate.Typeface.body, weight: weight))
            .foregroundStyle(tint)
            .fixedSize()
    }

    /// A frame-stepped spinner on the wall clock: `TimelineView` re-renders once per beat and the
    /// frame is a pure function of the date, so phase survives re-mounts and rows stay in unison.
    private func spinner(_ frames: [String], beat: Double, tint: Color) -> some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: beat)) { timeline in
            glyph(Self.frame(at: timeline.date, frames: frames, beat: beat), tint: tint, weight: .semibold)
        }
    }

    /// The spinner frame for one wall-clock instant — pure + static so the cadence is unit-pinned
    /// headlessly (frames advance one per beat, wrap at the end, never skip on a re-render).
    static func frame(at date: Date, frames: [String], beat: Double) -> String {
        guard !frames.isEmpty, beat > 0 else { return "" }
        let phase = date.timeIntervalSinceReferenceDate / beat
        let index = Int(phase.rounded(.down)) % frames.count
        return frames[index < 0 ? index + frames.count : index]
    }
}
#endif
