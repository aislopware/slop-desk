// TabBadgeView — the single status glyph for one sidebar tab row's trailing slot, the otty badge set
// (`docs/otty-clone/screenshots/tab-badge.png`): a muted rays SPINNER for anything busy, the orange
// raised hand for a blocked prompt, the red triangle for a failure, the green check for a completed
// task, and the small green dot for an unseen finish. The privilege markers (`#` sudo, `∞`
// caffeinate) stay small muted text in the shell's own dialect. One reading in a fixed 16pt box:
// state changes never move a pixel of layout.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — plain SwiftUI drawing, nothing more.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// The status glyph for one sidebar tab row. One reading centered in a fixed box, AX-labelled so the
/// icon-only glyph is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The glyph box is 16pt; the reading centers in this fixed box so rows keep a stable trailing
    /// edge while states swap.
    static let side: CGFloat = 16

    var body: some View {
        glyph
            .frame(width: Self.side, height: Self.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
            .help(StatusPresentation.tabBadgeLabel(kind))
    }

    @ViewBuilder private var glyph: some View {
        switch StatusPresentation.tabBadge(kind) {
        case let .spinner(tint):
            // The otty gray spinner: the system rays glyph stepping its spokes (a discrete
            // variable-colour walk, not a rotation).
            Image(systemSymbol: .rays)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative)
        case let .symbol(symbol, tint):
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(tint)
        case let .dot(tint):
            // The unseen-finish dot — otty's small filled circle.
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
        case let .glyph(text, tint):
            Text(text)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
#endif
