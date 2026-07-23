// TabBadgeView — the single trailing status badge on a sidebar tab row. Maps a pure
// ``TabBadgeKind`` to its ring reading via ``StatusPresentation/tabBadge(_:)``. ONE SHAPE for every
// lifecycle state (``StatusRing``): the same Ø12 ring changes stroke style / hue / centre content —
// working = dashed escapement, awaiting = ring⊙ + stepped halo, done = ring✓, error = ring✕,
// OSC 9;4 progress = muted ring⊙ static, caffeinate/sudo = glyph inside the muted ring. Only the plain
// busy shell stays a sub-ring micro-dot (concentric — an agent taking over reads as the dot growing a
// ring). One reading, fixed 16pt box, right-aligned: state changes never move a pixel of layout AND
// never swap silhouettes.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — the ring is plain SwiftUI drawing, nothing more.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The trailing status badge for one sidebar tab row. One ring reading centered in a fixed box,
/// AX-labelled so the icon-only badge is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The trailing badge column is ~16px (`tab-badge.png`); the reading centers in this fixed box so
    /// rows keep a stable trailing edge. Internal so the row can RESERVE this box unconditionally —
    /// without the reserve a badge appearing would grow the line and re-centre the row (a visible
    /// height jump).
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
        case let .ringWorking(tint):
            StatusRing(reading: .working, tint: tint)
        case let .ringAwaiting(tint):
            StatusRing(reading: .awaiting, tint: tint)
        case let .ringDone(tint):
            StatusRing(reading: .done, tint: tint)
        case let .ringError(tint):
            StatusRing(reading: .error, tint: tint)
        case let .ringProgress(tint):
            StatusRing(reading: .progress, tint: tint)
        case let .ringGlyph(name, tint):
            StatusRing(reading: .glyph(name), tint: tint)
        case let .dot(color):
            SlateStatusDot(color: color, size: 6)
        }
    }
}
#endif
