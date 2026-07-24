// TabBadgeView — the single status reading for one sidebar tab row's trailing slot, spoken in the
// terminal's own text dialect (`StatusGlyph`): the AI-CLI asterisk pulse = agent working, the braille
// dot-walker = command running, blinking `?` = awaiting input, `✗` = error, `●` = clean finish — the
// characters a CLI would print, in the instrument (mono) face, so status reads as terminal output
// rather than drawn iconography. The privilege markers (`#` sudo, `∞` caffeinate) stay small muted
// text in the same voice. One reading in a fixed 16pt box: state changes never move a pixel of layout.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — plain SwiftUI drawing, nothing more.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The status reading for one sidebar tab row. One reading centered in a fixed box, AX-labelled so the
/// icon-free circle is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The reading box is 16pt (the `StatusGlyph` box); the reading centers in this fixed box so rows
    /// keep a stable trailing edge while states swap.
    static let side: CGFloat = 16

    var body: some View {
        reading
            .frame(width: Self.side, height: Self.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
            .help(StatusPresentation.tabBadgeLabel(kind))
    }

    @ViewBuilder private var reading: some View {
        switch StatusPresentation.tabBadge(kind) {
        case let .reading(glyphReading, tint):
            StatusGlyph(reading: glyphReading, tint: tint)
        case let .glyph(text, tint):
            Text(text)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
#endif
