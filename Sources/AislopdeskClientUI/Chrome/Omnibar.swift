// Omnibar — the centered search pill in the title bar (warp-window-chrome.md §5). Max width 320pt,
// 4pt corner, fg_overlay_1 fill → fg_overlay_2 on hover, leading 16×16 search glyph, 14pt sub-text
// placeholder "Search sessions, agents, files…". On tap it calls a no-op callback hook for the future
// command palette (wired in L5).

import AislopdeskDesignSystem
import SwiftUI

struct Omnibar: View {
    @Environment(\.theme) private var theme

    /// Called on tap — the future command-palette open hook (no-op until L5).
    var onOpen: () -> Void = {}

    @State private var hovering = false

    private static let placeholder = "Search sessions, agents, files…"

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: WarpSize.iconGlyph * 0.78))
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                    .foregroundStyle(theme.textSub)
                Text(Self.placeholder)
                    .font(WarpType.ui(WarpType.paletteSize))
                    .foregroundStyle(theme.textSub)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarpSpace.omnibarPadHorizontal)
            .padding(.vertical, WarpSpace.omnibarPadVertical)
            .frame(maxWidth: WarpSize.omnibarMaxWidth)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                    .fill(hovering ? theme.fgOverlay2 : theme.fgOverlay1),
            )
            .contentShape(RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(macOS)
            .pointerStyle(.link)
        #endif
    }
}
