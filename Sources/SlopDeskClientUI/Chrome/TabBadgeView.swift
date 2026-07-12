// TabBadgeView — the single trailing status badge on a sidebar tab row. Maps a pure
// ``TabBadgeKind`` to its glyph via ``StatusPresentation/tabBadge(_:)``. ONE dot language on the agent
// palette (docs/42: working🟡 done🔵 needs🔴) — the colour carries the state, a spinner ring means "live
// right now", and the dot never resizes between the two:
//   • agent WORKING → amber dot + spinner ring (``SlateOrbitDot``);
//   • OSC 9;4 progress → muted dot + spinner ring (a plain busy shell shows NOTHING);
//   • blocked / failed → static RED dot; done-unread → static BLUE dot; clean-finish flash → GREEN dot;
//   • caffeinate / sudo (at rest) → a tinted SF-symbol fill.
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
            // Agent thinking — the amber dot with the spinner ring (live). The core matches the static
            // dot size, so working→done never resizes the dot the eye is on.
            SlateOrbitDot(color: tint)
        case let .commandBusy(tint):
            // An OSC 9;4 progress load — the same ring in the QUIET muted tint (the ring says "live", the
            // muted colour says "not the agent"). A plain busy shell shows nothing at all.
            SlateOrbitDot(color: tint)
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
