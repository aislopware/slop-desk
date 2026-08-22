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
// the Settings window and a monitor is not a view. This half records with a view instead —
// ``KeybindingCaptureHost``, a zero-sized first responder mounted on the armed row — and the two answer
// the same four things because both ask Rust: the Mac `slopdesk_video::key_naming` off a virtual key
// code, the phone `slopdesk_workspace::phone_key` off a HID usage, pinned to each other by a test in
// `slopdesk-ffi` (docs/56 increment 30). The earlier claim that a phone recorder would have to invent a
// second answer to "what key is this" was wrong twice over: the HID usage IS the identity, and the
// chord it builds was already resolving against this same table on every terminal keystroke.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
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

    /// The binding id currently recording a replacement chord, or `nil`. At most one row records at
    /// a time — the recorder is one first responder, and two would make the order UIKit's.
    @State private var recordingID: String?

    var body: some View {
        let conflicts = store.keybindingConflicts()
        // The set of binding ids that collide with at least one other id on the same chord (for the badge).
        let conflictingIDs = Set(conflicts.values.flatMap(\.self))
        // One crossing for the whole table, hoisted out of the `ForEach` for the same reason
        // `conflictingIDs` is: the answer does not vary by category.
        let kept = surviving()

        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            header
            searchField
            if !conflicts.isEmpty {
                conflictBanner(conflicts)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Slate.Metric.space3, pinnedViews: [.sectionHeaders]) {
                    ForEach(WorkspaceAction.Category.allCases, id: \.self) { category in
                        let rows = bindings(in: category, surviving: kept)
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
            KeybindingsEditorCopy.resetConfirmTitle,
            isPresented: $showResetConfirm,
            titleVisibility: .visible,
        ) {
            Button(KeybindingsEditorCopy.resetAction, role: .destructive) { resetAllOverrides() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(KeybindingsEditorCopy.resetConfirmBody)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(KeybindingsEditorCopy.title)
                    .font(SettingsType.body.weight(.semibold))
                    .foregroundStyle(SettingsInk.primary)
                Text(KeybindingsEditorCopy.subtitle)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
            }
            Spacer(minLength: Slate.Metric.space2)
            // The "Reset to Default" button appears in the top-right ONLY once a binding has been
            // customized; clicking it confirms then clears ALL overrides (there is NO per-row revert).
            if KeybindingsEditorModel.hasCustomizations(store.keybindings) {
                Button(KeybindingsEditorCopy.resetAction) { showResetConfirm = true }
                    .buttonStyle(.plain)
                    .font(SettingsType.subtitle.weight(.medium))
                    .foregroundStyle(SettingsInk.accent)
                    .help(KeybindingsEditorCopy.resetHelp)
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
            TextField(KeybindingsEditorCopy.searchPrompt, text: $searchQuery)
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
        // Each conflict key is a canonical chord string shared by ≥2 ids; surfaced plainly, and by the
        // same floor call the Mac's banner makes — these lines used to be built inline here and in a
        // private `conflictLines` there, which is why a file-level `cmp` never saw the pair.
        let lines = KeybindingsEditorReading.conflictLines(conflicts)
        return VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Label(KeybindingsEditorCopy.conflictsTitle, systemImage: "exclamationmark.triangle.fill")
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
                    .help(KeybindingsEditorCopy.conflictHelp)
            }
            Spacer(minLength: Slate.Metric.space2)
            // Tap to record, exactly as the Mac's row does — there is still NO per-row revert, and
            // Backspace during a recording is what clears one.
            chordChip(for: binding)
        }
        .padding(.vertical, Slate.Metric.space1)
    }

    /// The trailing chord chip — the effective shortcut, on the same inset plate the Mac's recorder
    /// rests at, and the same affordance: tapping it arms this row, and the next hardware press is
    /// the answer. While armed it carries the recorder itself, a zero-sized first responder.
    private func chordChip(for binding: WorkspaceBinding) -> some View {
        let isRecording = recordingID == binding.id
        return Button {
            recordingID = isRecording ? nil : binding.id
        } label: {
            Text(isRecording ? "Press a shortcut…" : effectiveGlyph(for: binding))
                .font(SettingsType.subtitle.weight(.medium))
                .foregroundStyle(isRecording ? SettingsInk.accent : SettingsInk.secondary)
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
                        .strokeBorder(
                            isRecording ? SettingsInk.accent : SettingsInk.hairline, lineWidth: 1,
                        ),
                )
                .overlay(
                    KeybindingCaptureHost(isRecording: isRecording) { press in
                        capture(press, for: binding.id)
                    },
                )
        }
        .buttonStyle(.plain)
    }

    /// Esc cancels (no write), Backspace / Forward Delete CLEAR the binding, a usable chord is
    /// recorded, and an unmappable press is ignored — the row stays armed. The rule is
    /// `slopdesk_workspace::phone_key`'s, reached through ``PhoneKey/captureOutcome(_:)``; this only
    /// applies the answer, through the SAME pure store transitions the Mac's recorder writes with.
    private func capture(_ press: PhoneKey.Press, for id: String) {
        switch PhoneKey.captureOutcome(press) {
        case .cancel:
            recordingID = nil
        case .clear:
            if store.keybindings.chord(for: id) != nil {
                store.keybindings = KeybindingsEditorModel.clearingOverride(for: id, in: store.keybindings)
            }
            recordingID = nil
        case .ignore:
            break // no usable chord yet — keep recording
        case let .bind(chord):
            store.keybindings = KeybindingsEditorModel.settingOverride(chord, for: id, in: store.keybindings)
            recordingID = nil
        }
    }

    // MARK: Data helpers

    /// Every read below is ``KeybindingsEditorReading``'s, below both editors — they were five helpers
    /// spelled twice, four of them byte-identical down to the doc comments. What is left here is the
    /// one thing this half owns: the live `store` and the live query.
    private func bindings(
        in category: WorkspaceAction.Category, surviving: [Bool],
    ) -> [WorkspaceBinding] {
        KeybindingsEditorReading.bindings(in: category, surviving: surviving)
    }

    private func surviving() -> [Bool] {
        KeybindingsEditorReading.surviving(overrides: store.keybindings, query: searchQuery)
    }

    private func binding(forID id: String) -> WorkspaceBinding? {
        KeybindingsEditorReading.binding(forID: id)
    }

    private func effectiveChord(for binding: WorkspaceBinding) -> KeyChord? {
        KeybindingsEditorReading.effectiveChord(for: binding, overrides: store.keybindings)
    }

    private func effectiveGlyph(for binding: WorkspaceBinding) -> String {
        KeybindingsEditorReading.effectiveGlyph(for: binding, overrides: store.keybindings)
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
