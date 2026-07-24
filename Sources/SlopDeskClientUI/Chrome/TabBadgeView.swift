// TabBadgeView — the trailing-slot marker for one sidebar tab row: ONLY the privilege modifiers
// (`#` sudo, `∞` caffeinate), small muted text in the instrument (mono) face. The lifecycle states
// never render here — every lifecycle state is the trailing ring mark's hue
// (`StatusPresentation.statusDot`) — so this view renders NOTHING for them and
// the slot falls through to the shell label. One marker in a fixed 16pt box: state changes never
// move a pixel of layout.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — plain SwiftUI drawing, nothing more.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The privilege marker for one sidebar tab row. Renders nothing for the lifecycle kinds (those speak
/// through the ring mark's hue); AX-labelled so the terse glyph is VoiceOver-legible.
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The marker box is 16pt (the `StatusGlyph` box); the glyph centers in this fixed box so rows
    /// keep a stable trailing edge while states swap.
    static let side: CGFloat = 16

    var body: some View {
        if let style = StatusPresentation.tabBadge(kind) {
            Text(style.text)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: Self.side, height: Self.side)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
                .help(StatusPresentation.tabBadgeLabel(kind))
        }
    }
}
#endif
