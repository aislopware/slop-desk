// WindowTopBar — the window title/tab bar (warp-window-chrome.md §1/§2/§4/§5/§6).
//
// Layout: 34pt tall + 1pt bottom border (= 35pt total). macOS reserves 80pt on the left for the native
// traffic lights (64pt + 16pt gap). Left cluster = sidebar-toggle + settings icon buttons; centered
// Omnibar pill; right cluster = share + inbox + avatar. Background = fg_overlay_1 (foreground @ 5%),
// bottom border = theme.outline() (fg_overlay_2).
//
// The buttons emit typed callbacks so the parent (WorkspaceRootView) routes them to the store — views
// stay thin (never mutate state inline).

import AislopdeskDesignSystem
import SwiftUI

struct WindowTopBar: View {
    @Environment(\.theme) private var theme

    /// Whether the sidebar (vertical-tab rail) is collapsed — drives the toggle button's active state.
    var sidebarCollapsed: Bool
    var onToggleSidebar: () -> Void
    var onOpenSettings: () -> Void
    var onOpenOmnibar: () -> Void
    /// Whether there is a pending notification (drives the inbox unread badge).
    var hasUnread: Bool = false
    var onShare: () -> Void = {}
    var onInbox: () -> Void = {}

    /// Left inset reserved for the macOS traffic lights (collapses on non-macOS).
    private var leadingInset: CGFloat {
        #if os(macOS)
        WarpSize.trafficLightInset
        #else
        WarpSize.tabBarPadLeft
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left icon cluster (after the traffic-light inset).
            HStack(spacing: WarpSpace.tabBarIconGap) {
                IconButton(
                    systemName: "sidebar.left",
                    isActive: !sidebarCollapsed,
                    help: "Tabs panel",
                    action: onToggleSidebar,
                )
                IconButton(
                    systemName: "slider.horizontal.3",
                    help: "Settings",
                    action: onOpenSettings,
                )
            }
            .padding(.leading, leadingInset)

            // Centered Omnibar slot (Shrinkable(1) — fills the remaining width, pill centered).
            Omnibar(onOpen: onOpenOmnibar)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarpSpace.omnibarSlotPad)

            // Right icon cluster.
            HStack(spacing: WarpSpace.tabBarIconGap) {
                IconButton(systemName: "square.and.arrow.up", help: "Share", action: onShare)
                IconButton(systemName: "tray", help: "Inbox", action: onInbox)
                    .overlay(alignment: .topTrailing) {
                        if hasUnread {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: WarpSize.badge, height: WarpSize.badge)
                                .offset(x: -2, y: 2)
                        }
                    }
                AvatarCircle()
                    .padding(WarpSpace.xxs)
            }
            .padding(.trailing, WarpSpace.tabBarPadRight)
        }
        .frame(height: WarpSize.titleBarHeight)
        .background(theme.fgOverlay1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.outline)
                .frame(height: WarpSize.titleBarBorder)
        }
    }
}
