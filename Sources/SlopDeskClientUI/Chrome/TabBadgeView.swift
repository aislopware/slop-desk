// TabBadgeView — the single trailing status badge on a sidebar tab row (E6 WI-4). Maps a pure
// ``TabBadgeKind`` to its glyph via ``StatusPresentation/tabBadge(_:)``. The vocabulary (herdr-inspired,
// animation reserved for the two agent-active states):
//   • agent WORKING → an accent comet arc (``SlateCometArc``, the "agent thinking" spinner);
//   • agent AWAITING INPUT → an amber ping (``SlatePingDot``, the most-urgent state);
//   • plain COMMAND running → a QUIET muted dot (normal secondary text colour, no animation);
//   • finished → a small filled dot; completed / error / caffeinate / sudo → a tinted SF-symbol fill.
// One glyph, fixed ~16pt box, right-aligned. Every glyph stays within the box so a tab row never shifts
// height as its state changes.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — the "spinner" is a plain SwiftUI `ProgressView`, nothing more.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The trailing status badge for one sidebar tab row. One glyph centered in a fixed box, AX-labelled so the
/// icon-only badge is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The trailing badge column is ~16px (`tab-badge.png`); the glyph centers in this fixed box so rows
    /// with different badge shapes keep a stable trailing edge. Internal so the row can RESERVE this height on
    /// its lines (`minHeight`) — the badge box is taller than the subtitle text, so without the reserve a
    /// badge appearing would grow the line and re-centre the row (a visible height jump).
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
        case let .working(tint):
            // Agent thinking — the smooth accent comet arc. Reserved for a working agent (a plain command
            // uses the muted dot below), so a spinning arc always reads as "the agent is working".
            SlateCometArc(color: tint)
        case let .commandBusy(tint):
            // A plain command running — the QUIET muted dot in normal secondary text colour, no animation.
            SlateStatusDot(color: tint, size: 6)
        case let .attention(tint):
            // Awaiting input — the gentle amber ping (the most-urgent state).
            SlatePingDot(color: tint, size: 8)
        case let .dot(color):
            SlateStatusDot(color: color, size: 8)
        case let .symbol(name, tint):
            Image(systemName: name)
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
#endif
