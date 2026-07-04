// KeybindingsEditorView — the Settings ▸ Keybindings editor (REBUILD-V2, WS-D / D6).
//
// Renders one row per `WorkspaceBindingRegistry.allBindings` entry (title / category / SF Symbol / the
// effective chord) and lets the user CAPTURE a replacement chord. A captured chord is written into
// `PreferencesStore.keybindings` (`KeybindingPreferences.overrides`, keyed by the registry `bindingID`).
// That is the WHOLE persistence story: the store's `keybindings` `didSet` already republishes the model to
// `WorkspaceBindingRegistry.activeOverrides`, which drives `resolvedChordTable` — so this view adds NO new
// persistence channel (D6 invariant). Conflicts come straight from `store.keybindingConflicts()`.
//
// SCOPE (D6): SINGLE-key chords only — the editor edits whatever the registry's chord model exposes today.
// WS-B later extends the chord model to multi-key sequences; this view re-renders whatever the registry
// surfaces, so it needs no change for that. Chord CAPTURE is a macOS-only `NSEvent` local monitor (the
// client's primary surface); on iOS the rows render read-only (no hardware-key capture UI here).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Keybindings tab body: a scrollable, category-grouped list of every registry binding with its
/// effective chord and a "record a new chord" affordance. Binds the live `PreferencesStore` (D4 hands it
/// in as `@Bindable`); writes overrides through `store.keybindings`.
struct KeybindingsEditorView: View {
    @Bindable var store: PreferencesStore

    /// The binding id currently in capture mode (its row shows "Press a key…"), or `nil`. Only one row
    /// records at a time so the local key monitor has a single unambiguous target.
    @State private var recordingID: String?

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
                                    .background(Slate.Surface.window)
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
        #if os(macOS)
        .background(KeyCaptureMonitor(
            isActive: recordingID != nil,
            onKey: { event in handleCapturedEvent(event) },
            // Cancel recording if the Settings window loses focus (click-away / app switch) so a stray
            // keystroke elsewhere is never silently recorded as the new chord.
            onCancel: { recordingID = nil },
        ))
        #endif
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: Slate.Typeface.body, weight: .semibold))
                    .foregroundStyle(Slate.Text.primary)
                Text("Click a shortcut to record a replacement; Backspace clears it, Esc cancels.")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
            }
            Spacer(minLength: Slate.Metric.space2)
            // The "Reset to Default" button appears in the top-right ONLY once a binding has been
            // customized; clicking it confirms then clears ALL overrides (there is NO per-row revert).
            if KeybindingsEditorModel.hasCustomizations(store.keybindings) {
                Button("Reset to Default") { showResetConfirm = true }
                    .buttonStyle(.plain)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.State.accent)
                    .help("Reset every customized shortcut to its default")
            }
        }
    }

    /// The full-width rounded "Search key bindings" field (magnifier + clear button) that filters rows by
    /// action name OR chord — see `KeybindingsEditorModel.matches`.
    private var searchField: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
            TextField("Search key bindings", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.primary)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            Slate.Surface.element,
            in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(Slate.Line.subtle, lineWidth: 1),
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
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Slate.Status.warn)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Slate.Metric.space2)
        .slateCard()
    }

    private func row(for binding: WorkspaceBinding, isConflicting: Bool) -> some View {
        let isRecording = recordingID == binding.id
        return HStack(spacing: Slate.Metric.space2) {
            Image(systemName: binding.symbol)
                .font(.system(size: Slate.Metric.iconSize))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: 18)
            Text(binding.title)
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
            if isConflicting {
                Image(systemSymbol: .exclamationmarkTriangleFill)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Status.warn)
                    .help("This shortcut conflicts with another command")
            }
            Spacer(minLength: Slate.Metric.space2)
            // There is NO per-row revert — the chord chip records a replacement; Backspace (while recording)
            // clears it, and the header's "Reset to Default" reverts everything at once.
            chordChip(for: binding, isRecording: isRecording)
        }
        .padding(.vertical, 4)
    }

    /// The trailing chord chip — the effective shortcut glyph, tappable to start recording. While recording
    /// it reads "Press a key…"; click again (or Escape, handled by the monitor) to cancel.
    private func chordChip(for binding: WorkspaceBinding, isRecording: Bool) -> some View {
        Button {
            toggleRecording(binding.id)
        } label: {
            Text(isRecording ? "Press a key…" : effectiveGlyph(for: binding))
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(isRecording ? Slate.State.accent : Slate.Text.secondary)
                .lineLimit(1)
                .padding(.horizontal, Slate.Metric.space2)
                .padding(.vertical, 2)
                .frame(minWidth: 64)
                .background(
                    isRecording ? Slate.State.accentMuted : Slate.Surface.element,
                    in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .strokeBorder(isRecording ? Slate.State.accent : Slate.Line.subtle, lineWidth: 1),
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Data helpers

    /// The bindings in `category`, excluding the synthetic ⌘1…⌘9 representative (it has no single chord to
    /// rebind and the real per-digit chords are an implementation detail) and any row filtered OUT by the live
    /// search query. Reads `allBindings` so the generated select-tab chords are present but the display-only
    /// representative is filtered out.
    private func bindings(in category: WorkspaceAction.Category) -> [WorkspaceBinding] {
        WorkspaceBindingRegistry.allBindings.filter {
            $0.category == category
                && $0.id != WorkspaceBindingRegistry.selectTabRepresentative.id
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

    private func toggleRecording(_ id: String) {
        recordingID = (recordingID == id) ? nil : id
    }

    /// Remove the override for `id` (restores the registry default). Writes a fresh model so the store's
    /// `didSet` fires (it compares to `oldValue`).
    private func clearOverride(_ id: String) {
        guard store.keybindings.chord(for: id) != nil else { return }
        // MUTATE the existing model (preserving sequenceOverrides / textBindings / unbinds) — rebuilding it as
        // `KeybindingPreferences(overrides:)` would default those three to empty, silently wiping the user's
        // config.toml literal-byte / unbind / sequence bindings on every edit.
        store.keybindings = KeybindingsEditorModel.clearingOverride(for: id, in: store.keybindings)
    }

    /// The global "Reset to Default": clear EVERY customization (single-chord, sequence, text-byte, and
    /// unbind overrides) at once by assigning a fresh empty model — the single persistence channel republishes
    /// the cleared overrides to the live registry.
    private func resetAllOverrides() {
        recordingID = nil
        store.keybindings = KeybindingPreferences()
    }

    /// Write `chord` as the override for `id` and stop recording. The single persistence channel: setting
    /// `store.keybindings` republishes to `WorkspaceBindingRegistry.activeOverrides` (D6 invariant).
    private func setOverride(_ chord: KeybindingPreferences.KeyChord, for id: String) {
        // MUTATE the existing model (preserving sequenceOverrides / textBindings / unbinds) — see clearOverride.
        store.keybindings = KeybindingsEditorModel.settingOverride(chord, for: id, in: store.keybindings)
        recordingID = nil
    }

    #if os(macOS)
    /// Map a captured `NSEvent` to a ``KeybindingCaptureOutcome`` (pure, headless logic in
    /// `KeybindingCapture`) and apply it to the recording row: Escape cancels (no write), Backspace /
    /// Forward-Delete CLEAR the binding (unbind), a usable chord is recorded, and an unmappable key is
    /// ignored (stays in recording mode).
    private func handleCapturedEvent(_ event: NSEvent) {
        guard let id = recordingID else { return }
        let mods = event.modifierFlags
        switch KeybindingCapture.outcome(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            command: mods.contains(.command),
            shift: mods.contains(.shift),
            option: mods.contains(.option),
            control: mods.contains(.control),
        ) {
        case .cancel:
            recordingID = nil
        case .clear:
            clearOverride(id)
            recordingID = nil
        case .ignore:
            break // no usable chord yet — keep recording
        case let .bind(chord):
            setOverride(chord, for: id)
        }
    }
    #endif
}

#if os(macOS)
/// A zero-size `NSViewRepresentable` that installs a LOCAL `NSEvent` keyDown monitor while `isActive` so a
/// captured keystroke reaches `onKey` (and is SWALLOWED — the monitor returns `nil` so the keystroke does
/// not also trigger a menu shortcut / type into a field while recording). Removed when inactive.
///
/// SCOPING (keyboard-audit fix): a `.keyDown` local monitor fires for events delivered to ANY window in the
/// process. Without scoping, clicking "Press a key…" and then clicking away (into the Settings search field
/// or the main workspace window) meant every keystroke app-wide was swallowed and the first one recorded as a
/// bogus chord. So the monitor captures ONLY events destined for its OWN hosting key window; a keystroke aimed
/// elsewhere passes THROUGH unchanged. It also observes its window losing key focus and fires `onCancel` so
/// recording stops on click-away rather than lying in wait for a stray key.
private struct KeyCaptureMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKey: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hostView = view
        context.coordinator.onKey = onKey
        context.coordinator.onCancel = onCancel
        context.coordinator.isActive = isActive
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        var onKey: (NSEvent) -> Void = { _ in }
        var onCancel: () -> Void = {}
        weak var hostView: NSView?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        var isActive: Bool = false {
            didSet {
                guard isActive != oldValue else { return }
                if isActive { install() } else { teardown() }
            }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Only capture keystrokes aimed at THIS Settings window (the one hosting the recorder). A key
                // delivered to any other window / field passes through UNCHANGED — never swallowed, never
                // mis-recorded.
                guard let window = hostView?.window, window.isKeyWindow, event.window === window else {
                    return event
                }
                onKey(event)
                return nil // swallow the keystroke while recording, only for our own window
            }
            // Cancel recording if our window loses key focus (click-away / app switch) so a later keystroke
            // elsewhere can never be silently captured as the new chord.
            if let window = hostView?.window {
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main,
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onCancel() }
                }
            }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
        }
    }
}
#endif
#endif
