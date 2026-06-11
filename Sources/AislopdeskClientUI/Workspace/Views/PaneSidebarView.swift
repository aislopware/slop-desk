#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneSidebarView (the left rail — lists every pane, grouped + searchable)

/// The left sidebar (docs/31): a native source-list of EVERY pane on the single canvas, organized into
/// collapsible ``PaneGroup`` sections (plus an "Ungrouped" bucket), with a search field over pane titles
/// and group names. Replaces the retired `TabSidebarView`.
///
/// ### Interaction
/// - Selecting a pane row → `store.focus(id)` + `store.centerOnPane(id)` (the pane may be far off the
///   viewport on the infinite canvas, so we pan to it).
/// - Tapping a group header → `store.centerOnGroup(id)` (frame the group's panes).
/// - A pane's context menu: rename, move to / out of a group, close.
/// - A group's context menu: rename, add a pane into it, delete (members survive as ungrouped).
/// - Footer: "New Pane" (kind menu) + "New Group".
///
/// Selection is bound to `workspace.focusedPane` through a computed `Binding` so the highlight always
/// follows the store (a programmatic focus updates the rail with no extra wiring). Rename is an inline
/// `TextField` swapped in for the row/header label while editing; the ⌘R / menu / palette "Rename" entry
/// points nudge `store.renameRequest`, observed here to begin renaming the focused pane.
struct PaneSidebarView: View {
    let store: WorkspaceStore

    /// The live search query (pane titles + group names). Empty ⇒ the grouped layout; non-empty ⇒ a
    /// flat fuzzy-filtered result list.
    @State private var query: String = ""
    /// The pane currently being renamed inline, or `nil`.
    @State private var renamingPane: PaneID?
    /// The group currently being renamed inline, or `nil`.
    @State private var renamingGroup: PaneGroupID?
    /// The working text for whichever inline rename field is open.
    @State private var draft: String = ""
    /// Focus for the inline rename field so it grabs the keyboard the instant it appears.
    @FocusState private var fieldFocused: Bool

    private var canvas: Canvas { store.workspace.canvas }
    private var groups: [PaneGroup] { store.workspace.groups }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List(selection: selectionBinding) {
            if isSearching {
                searchResults
            } else {
                groupedList
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .searchable(text: $query, placement: .sidebar, prompt: "Search panes & groups")
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("Panes")
        // ⌘R / menu / palette "Rename" → nudge → begin renaming the focused pane's row.
        .onChange(of: store.renameRequest) { _, _ in
            if let id = store.focusedPane { beginRenamePane(id) }
        }
    }

    // MARK: Grouped layout (query empty)

    @ViewBuilder
    private var groupedList: some View {
        ForEach(groups) { group in
            Section {
                ForEach(canvas.ids(inGroup: group.id), id: \.self) { paneRow($0) }
            } header: {
                groupHeader(group)
            }
        }
        let ungrouped = canvas.ids(inGroup: nil)
        if !ungrouped.isEmpty {
            Section(groups.isEmpty ? "Panes" : "Ungrouped") {
                ForEach(ungrouped, id: \.self) { paneRow($0) }
            }
        }
    }

    // MARK: Search results (query non-empty)

    @ViewBuilder
    private var searchResults: some View {
        let matchingGroups = groups.filter { fuzzyMatches($0.name) }
        let matchingPanes = canvas.allIDs().filter { id in
            guard let spec = canvas.spec(for: id) else { return false }
            return fuzzyMatches(spec.title)
        }
        if !matchingGroups.isEmpty {
            Section("Groups") {
                ForEach(matchingGroups) { group in
                    Button { store.centerOnGroup(group.id) } label: {
                        Label(group.name, systemImage: "square.on.square.dashed")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        Section("Panes") {
            if matchingPanes.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            } else {
                ForEach(matchingPanes, id: \.self) { paneRow($0) }
            }
        }
    }

    /// Whether `text` fuzzy-matches the current query (reuses the command-palette scorer — one matcher).
    private func fuzzyMatches(_ text: String) -> Bool {
        CommandPaletteView.fuzzyScore(query: query.trimmingCharacters(in: .whitespaces), in: text) != nil
    }

    // MARK: Pane row

    @ViewBuilder
    private func paneRow(_ id: PaneID) -> some View {
        if let spec = canvas.spec(for: id) {
            HStack(spacing: 8) {
                Image(systemName: PaneLeafView.icon(for: spec.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)   // the title Text carries the row label

                PaneStatusDot(status: PaneConnectionStatus.from(liveStatus(id)))

                if renamingPane == id {
                    TextField("Pane name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { commitPaneRename(id) }
                        #if os(macOS)
                        .onExitCommand { renamingPane = nil }
                        #endif
                } else {
                    Text(spec.title).lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .tag(id)
            .contextMenu { paneContextMenu(id) }
        }
    }

    @ViewBuilder
    private func paneContextMenu(_ id: PaneID) -> some View {
        Button("Rename") { beginRenamePane(id) }
        Menu("Move to Group") {
            Button("New Group…") {
                let gid = store.addGroup(name: "Group")
                store.assignPane(id, toGroup: gid)
                beginRenameGroup(gid, name: "Group")
            }
            if canvas.item(id)?.groupID != nil {
                Button("Ungroup") { store.assignPane(id, toGroup: nil) }
            }
            if !groups.isEmpty {
                Divider()
                ForEach(groups) { group in
                    Button(group.name) { store.assignPane(id, toGroup: group.id) }
                }
            }
        }
        Divider()
        Button("Close Pane", role: .destructive) { store.closePane(id) }
    }

    // MARK: Group header

    @ViewBuilder
    private func groupHeader(_ group: PaneGroup) -> some View {
        HStack(spacing: 6) {
            if renamingGroup == group.id {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commitGroupRename(group.id) }
                    #if os(macOS)
                    .onExitCommand { renamingGroup = nil }
                    #endif
            } else {
                Text(group.name)
            }
            Spacer(minLength: 0)
            Text("\(canvas.ids(inGroup: group.id).count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        // A tap on the header frames the group's panes (groups are spatial clusters on the canvas).
        .onTapGesture { store.centerOnGroup(group.id) }
        .contextMenu {
            Button("Rename Group") { beginRenameGroup(group.id, name: group.name) }
            Button("New Pane in Group") { store.addPane(kind: .terminal, inGroup: group.id) }
            Divider()
            Button("Delete Group", role: .destructive) { store.removeGroup(group.id) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Button { store.addPane(kind: .terminal) } label: {
                    Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
                }
                Button { store.addPane(kind: .claudeCode) } label: {
                    Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
                }
                Button { store.addPane(kind: .remoteGUI) } label: {
                    Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
                }
            } label: {
                Label("New Pane", systemImage: "plus")
            } primaryAction: {
                store.addPane(kind: .terminal)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()

            Spacer()

            Button {
                let gid = store.addGroup(name: "Group")
                beginRenameGroup(gid, name: "Group")
            } label: {
                Label("New Group", systemImage: "square.on.square.dashed")
            }
            .buttonStyle(.borderless)
            .help("Create a group")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Selection binding (routes through the store)

    /// A `Binding` over the focused pane: reads `store.focusedPane`, writes via `focus` + `centerOnPane`
    /// so selecting a row both focuses the pane and pans the camera to reveal it.
    private var selectionBinding: Binding<PaneID?> {
        Binding(
            get: { store.focusedPane },
            set: { newValue in
                guard let id = newValue else { return }
                store.focus(id)
                store.centerOnPane(id)
            }
        )
    }

    // MARK: Live status

    /// The pane's live PATH-1 connection status for its dot, or `nil` (no dot) for a video / faked pane.
    private func liveStatus(_ id: PaneID) -> ConnectionViewModel.Status? {
        (store.handle(for: id) as? LivePaneSession)?.connection?.status
    }

    // MARK: Rename flow

    private func beginRenamePane(_ id: PaneID) {
        draft = canvas.spec(for: id)?.title ?? ""
        renamingGroup = nil
        renamingPane = id
        fieldFocused = true
    }

    private func commitPaneRename(_ id: PaneID) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.updateSpec(id) { $0.title = trimmed } }
        renamingPane = nil
    }

    private func beginRenameGroup(_ id: PaneGroupID, name: String) {
        draft = name
        renamingPane = nil
        renamingGroup = id
        fieldFocused = true
    }

    private func commitGroupRename(_ id: PaneGroupID) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.renameGroup(id, trimmed) }
        renamingGroup = nil
    }
}
#endif
