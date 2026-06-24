// PaneHeader — the native pane title bar (REBUILD-V2, L2). A row with the pane title and trailing SF
// Symbol buttons: split-right (`square.split.2x1`), split-down (`square.split.1x2`), and close (`xmark`,
// only when the pane is in a split). Controls hover-reveal (or stay visible when the pane is active). A 1px
// bottom `Divider()`. SYSTEM colours/fonts only — NO design-system, NO custom tokens.
//
// The control-visibility rules live in `PaneHeaderControls` (pure) so they are unit-testable without a
// view (hover-reveal + close-only-in-split rules).

#if canImport(SwiftUI)
import SwiftUI

/// Pure visibility rules for the header's right-side controls (testable).
enum PaneHeaderControls {
    /// The close `×` is shown only when the pane is IN A SPLIT and the controls are revealed (hover/active).
    static func showsClose(isInSplit: Bool, controlsRevealed: Bool) -> Bool {
        isInSplit && controlsRevealed
    }

    /// The overflow / split controls are shown whenever the controls are revealed.
    static func showsOverflow(controlsRevealed: Bool) -> Bool { controlsRevealed }

    /// Controls are revealed when the header is hovered OR the pane is the active pane.
    static func controlsRevealed(isHovered: Bool, isActive: Bool) -> Bool { isHovered || isActive }
}

struct PaneHeader: View {
    let title: String
    /// Whether this pane is the active (focused) pane — keeps the controls visible at rest.
    let isActive: Bool
    /// Whether the pane lives in a split (gates the × close button).
    let isInSplit: Bool

    var onSplitRight: () -> Void = {}
    var onSplitDown: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var hovering = false

    private var revealed: Bool {
        PaneHeaderControls.controlsRevealed(isHovered: hovering, isActive: isActive)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "Terminal" : title)
                .font(.system(size: Otty.Typeface.base, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Otty.Text.primary : Otty.Text.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if PaneHeaderControls.showsOverflow(controlsRevealed: revealed) {
                headerButton("square.split.2x1", help: "Split right", action: onSplitRight)
                headerButton("square.split.1x2", help: "Split down", action: onSplitDown)
            }
            if PaneHeaderControls.showsClose(isInSplit: isInSplit, controlsRevealed: revealed) {
                headerButton("xmark", help: "Close pane", action: onClose)
            }
        }
        .padding(.horizontal, Otty.Metric.space2)
        .frame(height: Otty.Metric.paneHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(NativePaneColor.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: revealed)
    }

    private func headerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        OttyPlateButton(systemName: systemName, help: help, action: action)
    }
}
#endif
