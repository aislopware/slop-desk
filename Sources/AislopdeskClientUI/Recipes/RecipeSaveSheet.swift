// RecipeSaveSheet — the ⌘S "Save Recipe" modal (E16 WI-10, spec `customization__custom-commands.md` §Save
// Layout / §Custom Commands). A self-contained otty-card sheet that snapshots the live tree to a `.ottyrecipe`
// via the store's `saveRecipe(scope:content:name:portable:commands:)` glue (WI-8). It owns only its form state;
// the tree snapshot + file IO + self-saved-trust recording all live in `WorkspaceStore+Recipes`.
//
// FIDELITY: a card-surface sheet (title + `×` close) with a **Name** field, a **scope** segmented control
// (Current Tab / Current Window / Commands), then a branch:
//   • tab / window scope → a **Content** radio group (Layout Only · Include Commands · Include Scrollback —
//     the last GREYED honestly, deferred per the plan's pinned deferrals) + a "Make paths portable" toggle;
//   • commands scope → the recent-OSC-133 commands list (oldest-first) with a **Select All** toggle and
//     inline-editable text, Save enabled only when ≥ 1 is ticked (spec §Custom Commands).
// Footer: a plain Cancel + a solid-accent Save. Cross-platform (macOS ⌘S + iOS File-menu equivalent).
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The ⌘S save-recipe sheet. Reads the active session's recent commands off `store` for the commands-scope
/// sub-list and calls `store.saveRecipe(...)` on Save.
struct RecipeSaveSheet: View {
    let store: WorkspaceStore

    @State private var name = ""
    @State private var scope: RecipeScope = .window
    @State private var content: RecipeSaveContent = .layoutOnly
    @State private var portable = false
    /// The commands-scope sub-list — recent OSC-133 commands (oldest-first), ticked + inline-editable.
    @State private var commandRows: [CommandRow] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space4) {
            header
            nameField
            scopePicker
            if scope == .commands {
                commandsSection
            } else {
                contentSection
                portableToggle
            }
            footer
        }
        .padding(Otty.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Otty.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
            .onAppear(perform: loadCommands)
            .onChange(of: scope) { _, newScope in if newScope == .commands { loadCommands() } }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Save Recipe")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: 0)
            closeButton
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(Otty.Text.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            label("Name")
            TextField("Recipe name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .padding(Otty.Metric.space2)
                .background(plate)
        }
    }

    // MARK: Scope

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            label("Scope")
            Picker("Scope", selection: $scope) {
                Text("Current Tab").tag(RecipeScope.tab)
                Text("Current Window").tag(RecipeScope.window)
                Text("Commands").tag(RecipeScope.commands)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    // MARK: Content (tab / window scope)

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space2) {
            label("Content")
            contentRow(.layoutOnly, "Layout Only", "Save the tabs, splits, and working directories.")
            contentRow(.includeCommands, "Include Commands", "Also capture recent commands to replay on open.")
            // Include Scrollback is DEFERRED (scrollback serialization across the libghostty seam is not wired
            // yet) — render it GREYED + non-selectable rather than shipping a dead toggle (plan §6 deferrals).
            scrollbackRow
        }
    }

    private func contentRow(_ value: RecipeSaveContent, _ title: String, _ subtitle: String) -> some View {
        Button { content = value } label: {
            radioRow(title: title, subtitle: subtitle, selected: content == value, enabled: true)
        }
        .buttonStyle(.plain)
    }

    private var scrollbackRow: some View {
        radioRow(
            title: "Include Scrollback",
            subtitle: "Not yet available — Layout Only and Include Commands are supported today.",
            selected: false,
            enabled: false,
        )
    }

    private var portableToggle: some View {
        Toggle(isOn: $portable) {
            VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                Text("Make paths portable")
                    .font(.system(size: Otty.Typeface.base, weight: .medium))
                    .foregroundStyle(Otty.Text.primary)
                Text("Replace your home and current folder with template variables so the recipe travels.")
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
            }
        }
        .tint(Otty.State.accent)
    }

    // MARK: Commands (commands scope)

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space2) {
            HStack {
                label("Commands")
                Spacer(minLength: 0)
                if !commandRows.isEmpty {
                    Button(allTicked ? "Deselect All" : "Select All") { toggleAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.State.accent)
                }
            }
            if commandRows.isEmpty {
                Text("No recent commands. Run a command (with shell integration) to capture it here.")
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
            } else {
                ForEach($commandRows) { $row in
                    commandRow($row)
                }
            }
        }
    }

    private func commandRow(_ row: Binding<CommandRow>) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Button { row.wrappedValue.ticked.toggle() } label: {
                Image(systemName: row.wrappedValue.ticked ? "checkmark.square.fill" : "square")
                    .font(.system(size: Otty.Metric.iconSize))
                    .foregroundStyle(row.wrappedValue.ticked ? Otty.State.accent : Otty.Text.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.wrappedValue.ticked ? "Deselect command" : "Select command")
            // Inline-editable text — click into the field to edit a command before saving (spec §Custom
            // Commands "double-click any item to edit"; here a persistent editable field is the looser idiom).
            TextField("", text: row.text)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body).monospaced())
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent)
                .padding(Otty.Metric.space1)
                .background(plate)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Otty.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
            saveButton
        }
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Surface.card)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(saveDisabled ? Otty.State.accentMuted : Otty.State.accent),
                )
        }
        .buttonStyle(.plain)
        .disabled(saveDisabled)
    }

    // MARK: Shared chrome

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Otty.Typeface.base, weight: .medium))
            .foregroundStyle(Otty.Text.primary)
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
            .fill(Otty.Surface.element)
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
            )
    }

    /// A radio-style option row: a filled/empty circle + a title + a subtitle. A disabled row renders tertiary
    /// (the honest "greyed option" — never a tappable dead control).
    private func radioRow(title: String, subtitle: String, selected: Bool, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: Otty.Metric.space2) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: Otty.Metric.iconSize))
                .foregroundStyle(enabled ? (selected ? Otty.State.accent : Otty.Text.icon) : Otty.Text.tertiary)
            VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                Text(title)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(enabled ? Otty.Text.primary : Otty.Text.tertiary)
                Text(subtitle)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: State helpers

    private var allTicked: Bool { !commandRows.isEmpty && commandRows.allSatisfy(\.ticked) }

    /// Save is blocked only for a commands-scope save with nothing ticked (a commands recipe with no commands
    /// to replay is meaningless — the store's `saveRecipe` would refuse it anyway). A blank name falls back to
    /// "Recipe", so it never blocks Save.
    private var saveDisabled: Bool {
        scope == .commands && !commandRows.contains(where: \.ticked)
    }

    private func toggleAll() {
        let target = !allTicked
        for index in commandRows.indices { commandRows[index].ticked = target }
    }

    private func loadCommands() {
        guard commandRows.isEmpty else { return } // don't clobber edits when re-entering commands scope
        commandRows = store.recentCommandsForReplay().map { CommandRow(text: $0, ticked: true) }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Recipe" : trimmed
        if scope == .commands {
            let curated = commandRows.filter(\.ticked).map(\.text)
            store.saveRecipe(scope: .commands, content: .includeCommands, name: finalName, commands: curated)
        } else {
            store.saveRecipe(scope: scope, content: content, name: finalName, portable: portable)
        }
        dismiss()
    }

    /// One row in the commands-scope sub-list — a recent command, whether it is ticked for capture, and its
    /// (possibly inline-edited) text. A throwaway `id` keeps `ForEach($commandRows)` stable across edits.
    private struct CommandRow: Identifiable {
        let id = UUID()
        var text: String
        var ticked: Bool
    }
}
#endif
