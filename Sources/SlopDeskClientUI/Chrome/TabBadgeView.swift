// TabBadgeView — the single status glyph for one sidebar tab row (the LEADING glyph column). Maps a
// pure ``TabBadgeKind`` to its reading via ``StatusPresentation/tabBadge(_:progressFraction:)``. ONE
// SHAPE for every lifecycle state (``StatusRing``, the Linear fill-fraction vocabulary): the same Ø12
// circle varies only how much of it is drawn/filled — working = dashed `◌` (stepped flicker),
// awaiting = ring+dot `◉`, done = solid disc✓, error = solid disc✕, busy = hollow `○`, OSC 9;4 =
// ring + pie wedge at the real fraction, caffeinate/sudo = glyph in the muted ring. One reading,
// fixed 16pt box: state changes never move a pixel of layout AND never swap silhouettes.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — the ring is plain SwiftUI drawing, nothing more.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The status glyph for one sidebar tab row. One reading centered in a fixed box, AX-labelled so the
/// icon-only glyph is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind
    /// The pane's live OSC 9;4 determinate fraction (0…1) — consumed by the `.commandRunning` pie
    /// reading only; every other kind ignores it.
    var progressFraction: Double?

    /// The glyph column is 16pt; the reading centers in this fixed box so rows keep a stable leading
    /// edge. Internal so the row can RESERVE this box unconditionally — without the reserve a badge
    /// appearing would shift the title.
    static let side: CGFloat = 16

    var body: some View {
        glyph
            .frame(width: Self.side, height: Self.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
            .help(StatusPresentation.tabBadgeLabel(kind))
    }

    @ViewBuilder private var glyph: some View {
        switch StatusPresentation.tabBadge(kind, progressFraction: progressFraction) {
        case let .ringWorking(tint):
            StatusRing(reading: .working, tint: tint)
        case let .ringAwaiting(tint):
            StatusRing(reading: .awaiting, tint: tint)
        case let .ringDone(tint):
            StatusRing(reading: .done, tint: tint)
        case let .ringError(tint):
            StatusRing(reading: .error, tint: tint)
        case let .ringHollow(tint):
            StatusRing(reading: .hollow, tint: tint)
        case let .ringPie(fraction, tint):
            StatusRing(reading: .pie(fraction), tint: tint)
        case let .ringGlyph(name, tint):
            StatusRing(reading: .glyph(name), tint: tint)
        }
    }
}
#endif
