// VerticalTabRail — Warp's left vertical-tab rail (warp-vertical-tabs.md / ORCH-DECISIONS V1).
//
// 248pt wide, panel bg = fg_overlay_1 (foreground @ 5%) wrapped in a surface_1 @ 90% panel surface with
// 8pt top corners; a 1pt fg@10% divider to the content sits in WorkspaceRootView. A pinned
// RailControlBar (search field + view-options + "+") tops a vertically scrolling list of TabRows.
//
// Binds to the REAL WorkspaceStore: rows = one per visible pane of the active session's tabs (V1 Panes
// granularity). Selecting a row makes its tab active and focuses its pane; "+" opens a new tab; "×"
// closes the pane (direct .tree mutation through the store, W6). Every mutation goes through the store.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct VerticalTabRail: View {
    @Environment(\.theme) private var theme
    let store: WorkspaceStore

    @State private var searchText = ""

    private var allRows: [RailRow] { RailRowsBuilder.rows(for: store) }
    private var rows: [RailRow] { RailRowsBuilder.filtered(allRows, query: searchText) }

    var body: some View {
        VStack(spacing: 0) {
            RailControlBar(searchText: $searchText, onNewTab: { store.newTabDefault() })
            ScrollView(.vertical) {
                LazyVStack(spacing: WarpSpace.s) {
                    if rows.isEmpty {
                        Text(allRows.isEmpty ? "No tabs open" : "No tabs match your search.")
                            .font(WarpType.ui(WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(WarpSpace.xl)
                    } else {
                        ForEach(rows) { row in
                            TabRow(
                                row: row,
                                onSelect: { select(row) },
                                onClose: { store.requestClosePaneTree(row.id) },
                            )
                        }
                    }
                }
                .padding(.horizontal, WarpSpace.m)
                .padding(.bottom, WarpSpace.m)
            }
        }
        .frame(width: WarpSize.railWidth)
        .background(theme.fgOverlay1)
        .background(
            theme.surface1.opacity(0.9),
            in: UnevenRoundedRectangle(
                topLeadingRadius: WarpRadius.dialog,
                topTrailingRadius: WarpRadius.dialog,
            ),
        )
    }

    /// Make the row's tab active (if it isn't) then focus its pane. Both go through the store.
    private func select(_ row: RailRow) {
        if let session = store.tree.activeSession,
           let index = session.tabs.firstIndex(where: { $0.id == row.tabID }),
           index != session.activeTabIndex
        {
            store.selectTab(index)
        }
        store.focusPaneTree(row.id)
    }
}
