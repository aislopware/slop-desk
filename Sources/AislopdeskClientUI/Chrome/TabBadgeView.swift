// TabBadgeView — the single trailing status badge on a sidebar tab row (E6 WI-4). Maps a pure
// ``TabBadgeKind`` to its glyph via ``StatusPresentation/tabBadge(_:)``: a gray indeterminate spinner
// (running), a small filled accent dot (the settled `finished` marker), or a tinted SF-symbol fill
// (completed / error / awaiting-input / caffeinate / sudo). One glyph, fixed ~16pt box, right-aligned per
// `docs/ui-shell/screenshots/tab-badge.png`.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — the "spinner" is a plain SwiftUI `ProgressView`, nothing more.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The trailing status badge for one sidebar tab row. One glyph centered in a fixed box, AX-labelled so the
/// icon-only badge is VoiceOver-legible (and snapshot/AX-testable).
struct TabBadgeView: View {
    let kind: TabBadgeKind
    /// The pane's live OSC 9;4 progress (design-craft pass, 2026-07-04): a `.running` kind with a
    /// DETERMINATE percent renders the ring instead of the anonymous spinner. `nil` ⇒ resolved-kind glyph.
    var progress: PaneProgress?

    /// The trailing badge column is ~16px (`tab-badge.png`); the glyph centers in this fixed box so rows
    /// with different badge shapes keep a stable trailing edge.
    private static let side: CGFloat = 16

    private var style: TabBadgeStyle { StatusPresentation.tabBadge(kind, progress: progress) }

    /// The a11y/tooltip text — the kind label, plus the live percent when the ring is showing.
    private var label: String {
        if case let .ring(_, percent) = style {
            return "\(StatusPresentation.tabBadgeLabel(kind)) — \(percent)"
        }
        return StatusPresentation.tabBadgeLabel(kind)
    }

    var body: some View {
        glyph
            .frame(width: Self.side, height: Self.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .help(label)
    }

    @ViewBuilder private var glyph: some View {
        switch style {
        case .spinner:
            // A pure SwiftUI indeterminate spinner — the gray ring of `tab-badge.png` row #1. NO video.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.secondary)
        case let .dot(color):
            SlateStatusDot(color: color, size: 8)
        case let .symbol(name, tint):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
        case let .ring(fraction, _):
            // The determinate OSC 9;4 percent ring: a muted track + an accent arc from 12 o'clock. The
            // arc's growth animates gently (progress arrivals are sparse wire events, not per-frame).
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
            .animation(.easeOut(duration: 0.3), value: fraction)
        }
    }
}
#endif
