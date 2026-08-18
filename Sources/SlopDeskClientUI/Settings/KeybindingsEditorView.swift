// KeybindingsEditorView — the Settings ▸ Keybindings editor (REBUILD-V2, WS-D / D6).
//
// Renders one row per `WorkspaceBindingRegistry.allBindings` entry (title / category / SF Symbol / the
// effective chord) and lets the user CAPTURE a replacement chord. A captured chord is written into
// `PreferencesStore.keybindings` (`KeybindingPreferences.overrides`, keyed by the registry `bindingID`).
// That is the WHOLE persistence story: the store's `keybindings` `didSet` already republishes the model to
// `WorkspaceBindingRegistry.activeOverrides`, which drives `resolvedChordTable` — so this view adds NO new
// persistence channel (D6 invariant). Conflicts come straight from `store.keybindingConflicts()`.
//
// SCOPE (D6): SINGLE-key chords only — the editor edits whatever the registry's chord model exposes.
//
// ⚠️ THE PHONE's, since docs/56 stage D: the Mac draws the same registry in AppKit
// (``SlopDeskMacUI/MacKeybindingsEditor``), because the recorder there is an `NSEvent` monitor scoped to
// the Settings window and a monitor is not a view. The Rust layout table calls this group
// `Platform::Both` and says why — a phone with a hardware keyboard runs the same bindings, and the LIST
// is worth reading with none — so this half renders every row and its effective chord, and RECORDING is
// the one thing it does not offer: there is no `UIKey` path to the macOS virtual key codes
// ``KeybindingCapture`` resolves against, so a capture UI here would have to invent a second answer to
// "what key is this", which is the duplicate this whole split exists to prevent.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI

/// The Keybindings tab body: a scrollable, category-grouped list of every registry binding with its
/// effective chord and a "record a new chord" affordance. Binds the live `PreferencesStore` (D4 hands it
/// in as `@Bindable`); writes overrides through `store.keybindings`.
struct KeybindingsEditorView: View {
    @Bindable var store: PreferencesStore

    /// The live "Search key bindings" query (filters by action name OR chord). Empty ⇒ show all rows.
    @State private var searchQuery: String = ""

    /// Whether the "Reset all key bindings?" confirmation is showing (a global reset, no per-row revert).
    @State private var showResetConfirm: Bool = false

    var body: some View {
        let conflicts = store.keybindingConflicts()
        // The set of binding ids that collide with at least one other id on the same chord (for the badge).
        let conflictingIDs = Set(conflicts.values.flatMap(\.self))

        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            header
            searchField
            if !conflicts.isEmpty {
                conflictBanner(conflicts)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Slate.Metric.space3, pinnedViews: [.sectionHeaders]) {
                    ForEach(WorkspaceAction.Category.allCases, id: \.self) { category in
                        let rows = bindings(in: category)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows, id: \.id) { binding in
                                    row(for: binding, isConflicting: conflictingIDs.contains(binding.id))
                                }
                            } header: {
                                SlateSectionHeader(category.rawValue)
                                    .background(SettingsInk.ground)
                            }
                        }
                    }
                }
            }
        }
        .padding(Slate.Metric.space4)
        .confirmationDialog(
            "Reset all key bindings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible,
        ) {
            Button("Reset to Default", role: .destructive) { resetAllOverrides() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every customized shortcut and restores the defaults.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text("Keyboard Shortcuts")
                    .font(SettingsType.body.weight(.semibold))
                    .foregroundStyle(SettingsInk.primary)
                Text("Click a shortcut to record a replacement; Backspace clears it, Esc cancels.")
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
            }
            Spacer(minLength: Slate.Metric.space2)
            // The "Reset to Default" button appears in the top-right ONLY once a binding has been
            // customized; clicking it confirms then clears ALL overrides (there is NO per-row revert).
            if KeybindingsEditorModel.hasCustomizations(store.keybindings) {
                Button("Reset to Default") { showResetConfirm = true }
                    .buttonStyle(.plain)
                    .font(SettingsType.subtitle.weight(.medium))
                    .foregroundStyle(SettingsInk.accent)
                    .help("Reset every customized shortcut to its default")
            }
        }
    }

    /// The full-width rounded "Search key bindings" field (magnifier + clear button) that filters rows by
    /// action name OR chord — see `KeybindingsEditorModel.matches`.
    private var searchField: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
            TextField("Search key bindings", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(SettingsType.label)
                .foregroundStyle(SettingsInk.primary)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            SettingsInk.inset,
            in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(SettingsInk.hairline, lineWidth: 1),
        )
    }

    private func conflictBanner(_ conflicts: [String: [String]]) -> some View {
        // Each conflict key is a canonical chord string shared by ≥2 ids; surface them plainly.
        let lines = conflicts.map { chord, ids -> String in
            let titles = ids.compactMap { id in binding(forID: id)?.title }.sorted()
            return "\(chord): \(titles.joined(separator: ", "))"
        }.sorted()
        return VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Label("Shortcut conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(SettingsType.subtitle.weight(.semibold))
                .foregroundStyle(SettingsInk.warn)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsInk.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Slate.Metric.space2)
        .slateCard()
    }

    private func row(for binding: WorkspaceBinding, isConflicting: Bool) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemName: binding.symbol)
                .font(.system(size: Slate.Metric.iconSize))
                .foregroundStyle(SettingsInk.icon)
                .frame(width: 18)
            Text(binding.title)
                .font(SettingsType.label)
                .foregroundStyle(SettingsInk.primary)
                .lineLimit(1)
            if isConflicting {
                Image(systemSymbol: .exclamationmarkTriangleFill)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsInk.warn)
                    .help("This shortcut conflicts with another command")
            }
            Spacer(minLength: Slate.Metric.space2)
            // There is NO per-row revert here and no recorder: the header's "Reset to Default" is the
            // one edit this half offers, and it reverts everything at once.
            chordChip(for: binding)
        }
        .padding(.vertical, Slate.Metric.space1)
    }

    /// The trailing chord chip — the effective shortcut, on the same inset plate the Mac's recorder
    /// rests at. A plate rather than a button, because tapping it here does nothing: what it shows is
    /// the chord that fires.
    private func chordChip(for binding: WorkspaceBinding) -> some View {
        Text(effectiveGlyph(for: binding))
            .font(SettingsType.subtitle.weight(.medium))
            .foregroundStyle(SettingsInk.secondary)
            .lineLimit(1)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, 2)
            .frame(minWidth: 64)
            .background(
                SettingsInk.inset,
                in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                    .strokeBorder(SettingsInk.hairline, lineWidth: 1),
            )
    }

    // MARK: Data helpers

    /// The bindings in `category`, excluding the synthetic ⌘1…⌘9 representative (it has no single chord to
    /// rebind and the real per-digit chords are an implementation detail) and any row filtered OUT by the live
    /// search query. Reads `allBindings` so the generated select-tab chords are present but the display-only
    /// representative is filtered out.
    private func bindings(in category: WorkspaceAction.Category) -> [WorkspaceBinding] {
        WorkspaceBindingRegistry.allBindings.filter {
            $0.category == category
                && $0.id != WorkspaceBindingRegistry.selectPaneRepresentative.id
                && KeybindingsEditorModel.matches(
                    $0, effectiveChord: effectiveChord(for: $0), query: searchQuery,
                )
        }
    }

    private func binding(forID id: String) -> WorkspaceBinding? {
        WorkspaceBindingRegistry.allBindings.first { $0.id == id }
    }

    /// The binding's EFFECTIVE chord (user override if it maps, else the registry default) — the same source
    /// `effectiveGlyph` renders, surfaced as a `KeyChord` so the search filter can match its glyph + canonical.
    private func effectiveChord(for binding: WorkspaceBinding) -> KeyChord? {
        WorkspaceBindingRegistry.resolvedChord(for: binding.action, overrides: store.keybindings)
    }

    /// The glyph for the binding's EFFECTIVE chord: the user override (if it maps) else the registry
    /// default. Mirrors `WorkspaceBindingRegistry.resolvedChord(for:)` so the chip shows what actually fires.
    private func effectiveGlyph(for binding: WorkspaceBinding) -> String {
        if let override = store.keybindings.chord(for: binding.id), let mapped = override.asRegistryChord {
            return WorkspaceBindingRegistry.glyph(mapped)
        }
        if let chord = binding.chord {
            return WorkspaceBindingRegistry.glyph(chord)
        }
        return "—"
    }

    // MARK: Mutation (all routed through `store.keybindings`)

    /// The global "Reset to Default": clear EVERY customization (single-chord, text-byte, and
    /// unbind overrides) at once by assigning a fresh empty model — the single persistence channel republishes
    /// the cleared overrides to the live registry.
    private func resetAllOverrides() {
        store.keybindings = KeybindingPreferences()
    }
}
#endif
