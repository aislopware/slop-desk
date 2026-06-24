// NavigatorColumn — the left sidebar navigator (REBUILD-V2, L2 → L7 otty restyle).
//
// A clean otty-style sidebar: a `ScrollView` of `OttySidebarRow` buttons (one per visible pane of the
// active session's tabs, via the kept-pure `RailRowsBuilder`) under an `OttySectionHeader` ("Workspace" +
// a "+" plate button). The background is left CLEAR so the hosting `NSSplitViewItem`'s native sidebar
// vibrancy shows through (otty's "one shared material backdrop"); selection is a NEUTRAL gray plate (otty),
// not the system accent highlight. Selecting a row makes its tab active and focuses its pane.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    var body: some View {
        let rows = RailRowsBuilder.rows(for: store)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                OttySectionHeader("Workspace") {
                    OttyPlateButton(systemName: "plus", help: "New tab", plate: 20) {
                        store.newTabDefault()
                    }
                }
                if rows.isEmpty {
                    Label("No tabs open", systemImage: "square.split.2x1")
                        .font(.system(size: Otty.Typeface.base))
                        .foregroundStyle(Otty.Text.secondary)
                        .padding(.horizontal, Otty.Metric.space2)
                        .padding(.vertical, 5)
                } else {
                    ForEach(rows) { row in
                        OttySidebarRow(
                            systemImage: Self.symbol(for: row.kind),
                            title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
                            subtitle: row.subtitle,
                            isSelected: row.id == selectedPane,
                            action: { select(row.id) },
                        )
                    }
                }
            }
            .padding(Otty.Metric.space2)
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.newTabDefault() } label: { Image(systemName: "plus") }
                }
            }
        #endif
    }

    /// Make the row's tab active (if it isn't) then focus its pane. Both go through the store.
    private func select(_ paneID: PaneID) {
        if let session = store.tree.activeSession {
            for (index, tab) in session.tabs.enumerated()
                where tab.root.allPaneIDs().contains(paneID)
            {
                if index != session.activeTabIndex { store.selectTab(index) }
                break
            }
        }
        store.focusPaneTree(paneID)
    }

    private func defaultTitle(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "Terminal"
        case .remoteGUI: "Remote window"
        case .systemDialog: "System dialog"
        }
    }

    /// SF Symbol for a pane kind (system glyphs only — no bundled icon set).
    private static func symbol(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .remoteGUI: "display"
        case .systemDialog: "lock.shield"
        }
    }
}
#endif
