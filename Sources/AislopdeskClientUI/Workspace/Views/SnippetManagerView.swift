#if canImport(SwiftUI)
import SwiftUI

// MARK: - SnippetManagerView (create / edit / delete command macros)

/// The in-app editor for ``Snippet`` command macros, presented as a sheet from ⌘K / Pane ▸ Manage
/// Snippets… The store has always had full snippet CRUD (`addSnippet`/`updateSnippet`/`deleteSnippet`),
/// but nothing ever called it outside import + tests — so before this view a user could only obtain a
/// snippet by hand-editing the workspace JSON. A master list (select / add / delete) beside a live
/// editor (name + body) with a preview of the parsed `{{placeholders}}`.
///
/// Edits bind DIRECTLY through the store (the single source of truth) rather than through draft `@State`
/// — so there is no save button, no lost-edit-on-switch hazard, and the palette/run paths see changes
/// immediately. `updateSnippet` is a metadata-only mutation (debounced persist), so per-keystroke writes
/// are cheap.
struct SnippetManagerView: View {
    let store: WorkspaceStore
    @State private var selectedID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var snippets: [Snippet] { store.snippets }
    private var selected: Snippet? { snippets.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                masterList
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 660, minHeight: 440)
        .onAppear { if selectedID == nil { selectedID = snippets.first?.id } }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Snippets", systemImage: "scroll").font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Master list

    private var masterList: some View {
        VStack(spacing: 0) {
            if snippets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "scroll").font(.title2).foregroundStyle(.secondary)
                    Text("No snippets yet").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(snippets) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WorkspaceStore.snippetName(snippet.name)).lineLimit(1)
                            Text(snippet.body.isEmpty ? "empty" : snippet.body)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(snippet.id)
                    }
                }
            }
            Divider()
            HStack(spacing: 0) {
                Button { addSnippet() } label: { Image(systemName: "plus") }
                    .help("New snippet")
                Button { deleteSelected() } label: { Image(systemName: "minus") }
                    .help("Delete selected snippet")
                    .disabled(selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: Detail editor

    @ViewBuilder
    private var detail: some View {
        if let snippet = selected {
            editor(for: snippet)
        } else {
            ContentUnavailableView {
                Label("No Snippet Selected", systemImage: "scroll")
            } description: {
                Text("Select a snippet to edit, or add a new one.")
            } actions: {
                Button("New Snippet") { addSnippet() }
            }
        }
    }

    private func editor(for snippet: Snippet) -> some View {
        let placeholders = snippet.placeholders
        return Form {
            Section("Name") {
                TextField("Name", text: Binding(
                    get: { selected?.name ?? "" },
                    set: { store.updateSnippet(snippet.id, name: $0, body: selected?.body ?? "") },
                ))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            }
            Section("Command") {
                TextEditor(text: Binding(
                    get: { selected?.body ?? "" },
                    set: { store.updateSnippet(snippet.id, name: selected?.name ?? "", body: $0) },
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Text(
                    "Use `{{name}}` for values you fill at run time, and `<Enter>` / `<Tab>` / "
                        + "`<Esc>` / `<C-c>` / `<Up>` … for control keys.",
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if !placeholders.isEmpty {
                Section("Placeholders") {
                    Text(placeholders.map { "{{\($0)}}" }.joined(separator: "  "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button { runNow(snippet) } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(snippet.body.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    /// Runs the snippet from the manager. A no-placeholder snippet runs and the manager closes. A
    /// PARAMETERIZED one needs the value-entry sheet — but presenting it in the same transaction the
    /// manager sheet dismisses is the macOS "present while dismissing" race (SwiftUI drops the second
    /// sheet). So dismiss the manager first, then arm the value sheet on the NEXT runloop turn, once the
    /// manager has gone (and `requestSnippetManager` clears any stranded flag if it still slips through).
    private func runNow(_ snippet: Snippet) {
        let id = snippet.id
        let parameterized = !snippet.placeholders.isEmpty
        dismiss()
        if parameterized {
            DispatchQueue.main.async { store.beginRunSnippet(id) }
        } else {
            store.runSnippet(id)
        }
    }

    private func addSnippet() {
        let created = store.addSnippet(name: "New Snippet", body: "")
        selectedID = created.id
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        store.deleteSnippet(id)
        selectedID = store.snippets.first?.id
    }
}
#endif
