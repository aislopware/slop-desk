// TabIconWithStatus — the leading icon of a tab row (warp-vertical-tabs.md §2.2). A plain terminal is a
// neutral `>` shell glyph in main_text; an agent (Claude) pane is the neutral asterisk-flower brand
// circle tinted by the agent footer brand, with a status badge encoding the ClaudeStatus. A remote-GUI
// pane uses a display icon. Total box = 24×24 (VERTICAL_TABS_ICON_SIZE).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct TabIconWithStatus: View {
    @Environment(\.theme) private var theme

    let kind: PaneKind
    /// The agent verdict for this pane (`.none` ⇒ not an agent → neutral terminal glyph).
    let status: ClaudeStatus

    private var isAgent: Bool { status != .none }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            iconBody
            if isAgent, let badge = badgeColor {
                Circle()
                    .fill(badge)
                    .frame(width: WarpSize.iconButtonPadding + 2, height: WarpSize.iconButtonPadding + 2)
                    .overlay(Circle().strokeBorder(theme.background, lineWidth: 1))
            }
        }
        .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
    }

    @ViewBuilder private var iconBody: some View {
        if isAgent {
            // Brand circle (CIRCLE_RATIO 0.76 → ~18px) with the neutral asterisk-flower mark.
            Circle()
                .fill(theme.agentFooterBrand.opacity(0.18))
                .frame(width: WarpSize.iconButton * 0.76, height: WarpSize.iconButton * 0.76)
                .overlay(
                    AgentBrandGlyph(color: theme.agentFooterBrand, size: WarpSize.iconButton * 0.46),
                )
        } else {
            switch kind {
            case .terminal:
                Image(systemName: "chevron.right")
                    .font(.system(size: WarpSize.iconGlyph * 0.72, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
            case .remoteGUI:
                Image(systemName: "display")
                    .font(.system(size: WarpSize.iconGlyph * 0.72))
                    .foregroundStyle(theme.textSub)
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
            case .systemDialog:
                Image(systemName: "lock.shield")
                    .font(.system(size: WarpSize.iconGlyph * 0.72))
                    .foregroundStyle(theme.textSub)
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
            }
        }
    }

    /// The status-badge color for the agent verdict (nil ⇒ no badge).
    private var badgeColor: Color? {
        switch status {
        case .none: nil
        case .idle: theme.uiGreen
        case .working: theme.uiYellow
        case .done: theme.accent
        case .needsPermission: theme.uiError
        }
    }
}
