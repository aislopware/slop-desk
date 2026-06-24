// NavigatorColumn — the left sidebar navigator (REBUILD-V2, L2). A native `List(selection:)` bound to the
// store: one selectable row per visible pane of the active session's tabs (via the kept-pure
// `RailRowsBuilder`). Selecting a row makes its tab active and focuses its pane (so the content area shows
// that tab). A "+" button opens a new tab. SYSTEM colours/SF Symbols/fonts only — NO design-system.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// `selection` getter = the active tab's active pane; setter = select the row's tab + focus its pane.
    /// (Both go through existing public store methods — `selectTab(_:)` + `focusPaneTree(_:)`.)
    private var selection: Binding<PaneID?> {
        Binding(
            get: { store.tree.activeSession?.activeTab?.activePane },
            set: { newValue in
                guard let paneID = newValue else { return }
                select(paneID)
            },
        )
    }

    var body: some View {
        let rows = RailRowsBuilder.rows(for: store)
        List(selection: selection) {
            Section {
                if rows.isEmpty {
                    Label("No tabs open", systemImage: "square.split.2x1")
                        .foregroundStyle(Otty.Text.secondary)
                } else {
                    ForEach(rows) { row in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title.isEmpty ? defaultTitle(for: row.kind) : row.title)
                                    .lineLimit(1)
                                if let subtitle = row.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Otty.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        } icon: {
                            Image(systemName: Self.symbol(for: row.kind))
                        }
                        .tag(row.id)
                    }
                }
            } header: {
                HStack {
                    Text("Workspace")
                    Spacer(minLength: 0)
                    Button {
                        store.newTabDefault()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New tab")
                }
            }
        }
        .listStyle(.sidebar)
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
