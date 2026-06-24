// NavigatorColumn — the left sidebar navigator (otty port). macOS renders otty's flat "TABS" panel: a warm
// `Otty.Surface.sidebar` background (NOT the native `.sidebar` vibrancy/inset-grouped selection — the host
// split item is a PLAIN item now), a "TABS" header with the sort hamburger, and one `OttyTabRow` per visible
// pane of the active session's tabs (name-only rows; ACTIVE = otty's white card). The top 40pt is reserved
// for the traffic lights under the hidden titlebar.
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). otty-styled but keeps the system list's navigation wiring.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    var body: some View {
        #if os(macOS)
        macSidebar
        #else
        iosSidebar
        #endif
    }

    #if os(macOS)
    /// macOS: otty's flat "TABS" panel — name-only rows, white-card active, hamburger sort. Paints its own
    /// warm background (the host `NSSplitViewItem` is a plain item, so there is no native vibrancy/rounding).
    private var macSidebar: some View {
        let rows = RailRowsBuilder.rows(for: store)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // reserve the titlebar / traffic-light strip
            HStack(spacing: 0) {
                Text("TABS")
                    .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Otty.State.header)
                Spacer(minLength: 0)
                OttySortMenuButton()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text("No tabs open")
                            .font(.system(size: Otty.Typeface.body))
                            .foregroundStyle(Otty.Text.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(rows) { row in
                            OttyTabRow(
                                title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
                                active: row.id == selectedPane,
                                onSelect: { select(row.id) },
                                onClose: { store.requestClosePaneTree(row.id) },
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden) // otty's invisible scrollbars
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Otty.Surface.sidebar)
    }
    #else
    /// iOS: a system `List(selection:)` so NavigationSplitView pushes to content on compact; otty-styled.
    private var iosSidebar: some View {
        let rows = RailRowsBuilder.rows(for: store)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            Section("Tabs") {
                if rows.isEmpty {
                    Label("No tabs open", systemSymbol: .squareSplit2x1)
                        .foregroundStyle(Otty.Text.secondary)
                } else {
                    ForEach(rows) { row in
                        Label {
                            Text(row.title.isEmpty ? defaultTitle(for: row.kind) : row.title)
                                .lineLimit(1)
                        } icon: {
                            Image(systemSymbol: Self.symbol(for: row.kind))
                        }
                        .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Otty.Surface.sidebar)
        .tint(Otty.State.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.newTabDefault() } label: { Image(systemSymbol: .plus) }
            }
        }
    }
    #endif

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

    /// Type-safe SF Symbol for a pane kind (iOS rows only; macOS otty rows are name-only).
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        switch kind {
        case .terminal: .appleTerminal
        case .remoteGUI: .display
        case .systemDialog: .lockShield
        }
    }
}
#endif
