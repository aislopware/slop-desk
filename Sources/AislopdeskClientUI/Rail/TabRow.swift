// TabRow — one pane row in the vertical-tab rail (warp-vertical-tabs.md §2/§5). Padding uniform 8,
// radius 4, icon 24 + 8pt gap + a text column (title 12 over subtitle/path sub-text). Active row =
// fg_overlay_2 fill + 1px fg_overlay_3 border (NO left accent bar, §7). Hover reveals a floating
// close(×)/kebab(⋮) pill at the row's top-right (neutral_3 bg, 1px neutral_4 border).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

/// The data a single rail row binds to (derived from a pane within the active session's tabs).
struct RailRow: Identifiable, Equatable {
    let id: PaneID
    let tabID: TabID
    let kind: PaneKind
    let title: String
    let subtitle: String?
    let status: ClaudeStatus
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    let isSelected: Bool
}

struct TabRow: View {
    @Environment(\.theme) private var theme

    let row: RailRow
    let onSelect: () -> Void
    let onClose: () -> Void
    var onKebab: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: row.subtitle == nil ? .center : .top, spacing: WarpSpace.m) {
                TabIconWithStatus(kind: row.kind, status: row.status)
                VStack(alignment: .leading, spacing: WarpSpace.xxs) {
                    Text(row.title.isEmpty ? defaultTitle : row.title)
                        .font(WarpType.ui(WarpType.uiSize))
                        .foregroundStyle(theme.textMain)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(WarpType.ui(WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(WarpSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(rowBorder)
            .clipShape(RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { actionPill }
        .onHover { hovering = $0 }
    }

    private var defaultTitle: String {
        switch row.kind {
        case .terminal: "Terminal"
        case .remoteGUI: "Remote window"
        case .systemDialog: "System dialog"
        }
    }

    @ViewBuilder private var rowBackground: some View {
        if row.isSelected {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.fgOverlay2)
        } else if hovering {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.fgOverlay1)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var rowBorder: some View {
        if row.isSelected {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .strokeBorder(theme.fgOverlay3, lineWidth: WarpBorder.width)
        }
    }

    /// The hover-revealed floating close/kebab pill (warp-vertical-tabs.md §5.1).
    @ViewBuilder private var actionPill: some View {
        if hovering {
            HStack(spacing: WarpSpace.xxs) {
                pillButton(systemName: "ellipsis", action: onKebab)
                pillButton(systemName: "xmark", action: onClose)
            }
            .padding(WarpSpace.xxs)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                    .fill(theme.surface3)
                    .overlay(
                        RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                            .strokeBorder(theme.neutral4, lineWidth: WarpBorder.width),
                    ),
            )
            .padding(.trailing, WarpSpace.s)
            .padding(.top, WarpSpace.s)
        }
    }

    private func pillButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12, height: 12)
                .padding(WarpSpace.xxs)
                .foregroundStyle(theme.textSub)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
