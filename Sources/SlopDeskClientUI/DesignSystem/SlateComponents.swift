// SlateComponents — the reusable chrome component kit on the token layer.
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: the terminal-dialect `StatusGlyph` instrument, a key/value row, a
// pill/badge, and an `.slateCard()` surface modifier.
// All built on `Slate.*` tokens + `SlateTheme`. See also SlateControls (`SlatePlateButton`), SlateRow
// (`SlateListRow` / `SlateSectionHeader`) and SlateMonogram (the host-identity plate).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The AGENT status instrument, spoken as TEXT in the terminal's own dialect: each reading is a
/// single character in the instrument (mono) face, centred in a fixed 16pt box — the chrome's status
/// voice IS the pane's voice, exactly the glyphs a CLI would print:
///   • `resting`  → `·` muted (an idle prompt — no colour spent);
///   • `working`  → the AI-CLI pulse `· ✢ ✳ ✶ ✻ ✽` breathing out and back — the agent's own spinner;
///   • `awaiting` → `?` bold in the act-now amber (answer me);
///   • `done`     → `●` (the quiet unread-finish dot, as the character a CLI would print).
/// Mounted where ONE pane's agent state gets a compact readout (the iOS toolbar, the Peek & Reply
/// header). The sidebar rows speak the same states through the trailing ring mark's hue instead
/// (``StatusPresentation/statusDot(working:badge:)``) — so no glyph column rides the rail, and nothing
/// in the rail animates at all.
/// The spinner is FRAME-STEPPED: hard glyph swaps on the wall clock off a fixed epoch, so every
/// spinning mount steps in unison and a re-render lands mid-cycle instead of restarting it.
/// Pure SwiftUI text — no video/capture (hang-safety #6).
struct StatusGlyph: View {
    enum Reading: Equatable {
        case resting
        case working
        case awaiting
        case done
    }

    let reading: Reading
    let tint: Color

    /// The fixed glyph box — star / dot advance widths differ, so the frame pins layout while
    /// frames (or states) swap.
    static let box: CGFloat = 16

    /// The agent spinner's frames — a dot budding into an asterisk and back (the AI-CLI loading
    /// pulse). Cycled as hard swaps; the palindrome makes the loop breathe without easing.
    ///
    /// ⚠️ Every star carries `\u{FE0E}` (VARIATION SELECTOR-15, text presentation). Bare U+2733 `✳`
    /// resolves to `AppleColorEmojiUI` on Apple platforms — a COLOUR emoji that ignores `tint` and
    /// measures 16pt of advance where its Menlo siblings measure 6.62, so that one frame flashed a
    /// coloured star and jumped this glyph's width mid-cycle (and it is the frame this instrument
    /// rests on longest). Same trap ``SlateTabRow`` guards for the title's `✳` marker. `·` (U+00B7)
    /// is the mono face's own glyph and needs nothing.
    ///
    /// ⚠️ The rail's mark column does NOT share these frames and must not be given them: it is a STATIC
    /// dashed ring whose hue names the state, and a whole round of work (docs/DECISIONS.md round 19/20)
    /// established that a 12pt mark cannot carry this bloom's detail — nor any other motion worth
    /// keeping. This instrument is 16pt in a text row, which can, so the typed bloom stays exactly here.
    static let agentFrames = [
        "·", "✢\u{FE0E}", "✳\u{FE0E}", "✶\u{FE0E}", "✻\u{FE0E}",
        "✽\u{FE0E}", "✻\u{FE0E}", "✶\u{FE0E}", "✳\u{FE0E}", "✢\u{FE0E}",
    ]
    /// Seconds per frame — the pulse breathes rather than spins.
    static let agentBeat: Double = 0.15

    var body: some View {
        content
            .frame(width: Self.box, height: Self.box)
    }

    @ViewBuilder private var content: some View {
        switch reading {
        case .resting: glyph("·", weight: .regular)
        case .working: spinner(Self.agentFrames, beat: Self.agentBeat)
        case .awaiting: glyph("?", weight: .bold)
        case .done: glyph("●", weight: .regular)
        }
    }

    private func glyph(_ text: String, weight: Font.Weight) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Slate.Typeface.body, weight: weight))
            .foregroundStyle(tint)
            .fixedSize()
    }

    /// A frame-stepped spinner on the wall clock: `TimelineView` re-renders once per beat and the
    /// frame is a pure function of the date, so phase survives re-mounts and rows stay in unison.
    private func spinner(_ frames: [String], beat: Double) -> some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: beat)) { timeline in
            glyph(Self.frame(at: timeline.date, frames: frames, beat: beat), weight: .semibold)
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

/// A compact label/value row: a secondary label on the left, a trailing primary value.
struct SlateKeyValueRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            Text(label)
                .foregroundStyle(Slate.Text.secondary)
            Spacer(minLength: Slate.Metric.space2)
            value()
                .foregroundStyle(Slate.Text.primary)
        }
    }
}

/// A small pill / badge — optional leading symbol + text, on the theme's element surface with a hairline.
struct SlatePill: View {
    var symbol: SFSymbol?
    let text: String
    var tint: Color = Slate.Text.secondary

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            if let symbol {
                Image(systemSymbol: symbol)
            }
            Text(text)
        }
        .font(.system(size: Slate.Typeface.footnote))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, 2)
        .background(Slate.Surface.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: 1))
    }
}

/// A "card" surface: element background, hairline border, rounded corners. The floating-card idiom
/// for inset content (command output, detail boxes). Use `.slateCard()` on any view.
private struct SlateCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Line.subtle, lineWidth: 1),
            )
    }
}

extension View {
    /// Wraps the view in a card surface (element fill + hairline border + rounded corners).
    func slateCard(
        radius: CGFloat = Slate.Metric.radiusControl,
        fill: Color = Slate.Surface.raised,
    ) -> some View {
        modifier(SlateCardModifier(radius: radius, fill: fill))
    }
}
#endif
