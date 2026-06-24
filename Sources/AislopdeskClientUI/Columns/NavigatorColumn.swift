// NavigatorColumn — the left sidebar (REBUILD-V2, L1). A stock `List(.sidebar)` of the workspace's
// panes, derived from the kept-pure `RailRowsBuilder` (one row per visible pane of the active session).
// SYSTEM colours/fonts only. L2 makes this a real, selectable, drag-reorderable navigator with sections.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    var body: some View {
        let rows = RailRowsBuilder.rows(for: store)
        List {
            Section("Workspace") {
                if rows.isEmpty {
                    Label("Sessions", systemImage: "square.split.2x1")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title.isEmpty ? "Untitled" : row.title)
                                    .lineLimit(1)
                                if let subtitle = row.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        } icon: {
                            Image(systemName: Self.symbol(for: row.kind))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
