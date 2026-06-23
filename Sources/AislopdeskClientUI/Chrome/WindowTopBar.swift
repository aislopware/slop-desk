// WindowTopBar — the window title/tab bar (warp-window-chrome.md §1/§2/§4/§5/§6).
//
// Layout: 34pt tall + 1pt bottom border (= 35pt total). macOS reserves 80pt on the left for the native
// traffic lights (64pt + 16pt gap). Left cluster = sidebar-toggle + settings icon buttons; centered
// Omnibar pill; right cluster = inbox + avatar. Background = fg_overlay_1 (foreground @ 5%),
// bottom border = theme.outline() (fg_overlay_2). (The Share button was removed — it had no destination;
// share/remote-control lives in the bottom bar.)
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
    var onInbox: () -> Void = {}

    // MARK: Connection status (app-global) — the right-cluster status pill.

    /// Short connection-state label (e.g. "connected", "reconnecting 3/20", "failed"). Empty ⇒ no pill.
    var statusLabel: String = ""
    /// The dot colour for the current connection state.
    var statusColor: Color = .clear
    /// The hover tooltip for the status pill (host + actionable headline).
    var statusHelp: String = ""
    /// A manual-retry handler — non-`nil` ONLY for a give-up state (.failed/.unreachable), so the retry
    /// affordance is hidden when connected/connecting/reconnecting.
    var onReconnect: (() -> Void)?
    /// Opens the Connect-to-Host editor (the host/port form). Wired to the status-pill body so the
    /// read-only pill becomes the discoverable connect affordance (the only way to change the host).
    var onOpenConnect: () -> Void = {}

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
                if !statusLabel.isEmpty {
                    statusPill
                }
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

    /// The app-global connection status pill: a state-coloured dot + compact label, plus a manual Reconnect
    /// button in a give-up state (`onReconnect != nil`). Surfaces a down/reconnecting host in the chrome.
    private var statusPill: some View {
        HStack(spacing: WarpSpace.xs) {
            // The dot + label are a button that opens the host/port editor (the connect affordance).
            Button(action: onOpenConnect) {
                HStack(spacing: WarpSpace.xs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: WarpSize.badge, height: WarpSize.badge)
                    Text(statusLabel)
                        .font(WarpType.ui(WarpType.overlineSize))
                        .foregroundStyle(theme.textSub)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onReconnect {
                IconButton(systemName: "arrow.clockwise", help: "Reconnect", action: onReconnect)
            }
        }
        .padding(.horizontal, WarpSpace.s)
        .help(statusHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusHelp.isEmpty ? statusLabel : statusHelp)
    }
}
