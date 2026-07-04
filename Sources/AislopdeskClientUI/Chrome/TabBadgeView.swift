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

    /// The trailing badge column is ~16px (`tab-badge.png`); the glyph centers in this fixed box so rows
    /// with different badge shapes keep a stable trailing edge.
    private static let side: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        glyph
            .frame(width: Self.side, height: Self.side)
            // A kind change is a MOMENT (command finished / errored / wants input): the incoming symbol
            // pops in with a small spring (design-craft pass, 2026-07-04). Kind changes are infrequent —
            // never keyboard-frequency — so the beat is earned; Reduce Motion collapses it to a plain swap.
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.35), value: kind)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
            .help(StatusPresentation.tabBadgeLabel(kind))
    }

    @ViewBuilder private var glyph: some View {
        switch StatusPresentation.tabBadge(kind) {
        case .spinner:
            // A pure SwiftUI indeterminate spinner — the gray ring of `tab-badge.png` row #1. NO video.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.secondary)
                .transition(.opacity)
        case let .dot(color):
            SlateStatusDot(color: color, size: 8)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case let .symbol(name, tint):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                // Symbol→symbol swaps (completed → error) morph via the SF-Symbols replace, not a hard cut.
                .contentTransition(.symbolEffect(.replace))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}
#endif
