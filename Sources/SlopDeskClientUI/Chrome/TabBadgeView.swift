// TabBadgeView — the single status reading for one sidebar tab row's trailing slot: every lifecycle
// state is the SAME Ø12 circle (`StatusRing`) differing only by hue + fill (sweeping comet arc = busy,
// amber ring + blinking cursor dot = awaiting, red broken ring = error, green filled = clean finish) —
// the user separates states by colour, never by learning a different silhouette per state. The privilege
// markers (`#` sudo, `∞` caffeinate) stay small muted text in the shell's own dialect. One reading
// in a fixed 16pt box: state changes never move a pixel of layout.
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

    /// The reading box is 16pt (the `StatusRing` box); the reading centers in this fixed box so rows
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
        case let .ring(ringReading, tint):
            StatusRing(reading: ringReading, tint: tint)
        case let .glyph(text, tint):
            Text(text)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
#endif
