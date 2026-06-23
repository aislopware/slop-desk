// IconButton — the shared 24×24 chrome icon button (warp-window-chrome.md §4). 4pt corner radius,
// 4pt glyph inset (→ 16×16 effective glyph area), hover/active backgrounds from the theme. Reused by
// the window top bar (sidebar/settings/share/inbox) and the rail control bar (filter/new-tab).
//
// Per F3 we replicate generic UI icons with SF Symbols where they match Warp's shapes; the agent brand
// uses a neutral asterisk-flower glyph, never a trademarked logo.

import AislopdeskDesignSystem
import SwiftUI

/// A small square chrome icon button. The glyph is supplied as an `Image` (SF Symbol or custom shape).
struct IconButton: View {
    @Environment(\.theme) private var theme

    let systemName: String
    /// Whether the button is "toggled on" (active) — paints `fgOverlay3` like Warp's active icon bg.
    var isActive: Bool = false
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: WarpSize.iconGlyph * 0.78, weight: .regular))
                .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                .padding(WarpSize.iconButtonPadding)
                .foregroundStyle(isActive ? theme.textMain : theme.textSub)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }

    @ViewBuilder private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .fill(theme.fgOverlay3)
        } else if hovering {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .fill(theme.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                        .strokeBorder(theme.surface3, lineWidth: WarpBorder.width),
                )
        } else {
            Color.clear
        }
    }
}
