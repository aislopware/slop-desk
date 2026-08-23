// FontSettingsView — the Appearance → Font section.
//
// Follows the design spec `docs/ui-shell/screenshots/font-setting.png` + `font-setting-bold.png`: the
// "FONT FAMILY" section opens with a "Settings for" pill row of SCOPE TABS — Global / Fallback — then a
// contextual note, the "Auto-match weight & style" toggle, the Font Family combobox with "Aa" specimens
// (and, when auto-match is OFF, the Bold / Italic / Bold-Italic face pickers), then Text (size +
// line-height), Ligatures, and the Style & Rendering controls (bold / italic / underline / blink /
// blending) with deferred-apply notes. This is the whole Font section for `AppearanceSettingsTab` — a
// single family TextField + size Stepper can't express scope tabs, per-face pickers, or deferred-apply
// notes.
//
// The Computed / Light Theme / Dark Theme tabs went with the theme picker (user-directed 2026-08-08):
// with one appearance there is one font slot, so Global IS the computed family and there is no per-theme
// map for it to lose against.
//
// BINDINGS (golden-safe — pure client chrome, never the wire/sidecar/`EnvConfig`): every render control binds
// `store.terminal` (a ``TerminalPreferences`` font-parity field), so a change flows through the store's
// `terminal` `didSet` → `applyTerminal()` → `TerminalConfigBroadcaster` and re-applies live via the
// font-parity keys the builder emits.
//
// EVERY CONTROL HERE ACTUATES. Ligatures, fallback, per-face families, bold/italic mode, line-height and
// `macos-like` blending (→ `font-thicken`) all map to a verified libghostty key and re-render live. The
// controls that did NOT — an underline-off toggle, an SGR-blink toggle, and the `srgb-over` / `linear` /
// `perceptual` blending modes — used to sit here behind a "saved but deferred" note; they are gone
// (2026-07-30). A note admitting a control does nothing is still a control that does nothing.
//
// HOST-FONT REALITY (`spec/customization__fonts.md` mapping notes): the terminal renders on the HOST inside
// libghostty, so font INSTALLATION is a host concern — there is no client "font folder" to open. The Font
// Family field is therefore a free-text combobox (type any family the host has) whose specimen dropdown lists
// THIS device's monospaced faces only as a convenience; a note makes the host boundary explicit. There are
// no "Install font" / "Open font folder" buttons — no client analog exists (the host owns font installation).
//
// PLATFORM: this is the PHONE's drawing. The Mac grew its own in increment 49
// (``SlopDeskMacUI/MacFontFamilySurface``), and everything both of them SAY or DECIDE went down to
// `SlopDeskClientCore` with it: the scope tabs and their notes (``SettingsFontScope``), every placeholder
// and the host-boundary note (``SettingsFontSurface``), the fallback list's parse/join/dedupe rules
// (``SettingsFontFallbackList``) and the installed-family enumeration (``InstalledFontFamilies``, still
// CoreText, still nonisolated and cross-platform). Nothing here re-decides one of them.
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail the `design-token-leaks` gate).

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - FontSettingsView

/// The Appearance → Font `Section`s (scope tabs + family combobox + size / line-height / ligatures / style),
/// bound to the live ``PreferencesStore``. Hosted by `AppearanceSettingsTab` in place of the old Font section.
struct FontSettingsView: View {
    @Bindable var store: PreferencesStore

    /// The active Font-Family SCOPE tab. Defaults to **Global** — the primary, always-rendered family field.
    @State private var scope: SettingsFontScope = .global

    /// The section's HEADER comes from the layout table, which places this surface, so this draws only
    /// what a row cannot: a pair of tabs whose choice picks which other controls exist.
    var body: some View {
        Group {
            scopeTabs
            scopeNote
            scopeBody
            hostFontNote
        }
    }

    /// The "Settings for" label + the pill row of scope tabs (Global / Fallback).
    private var scopeTabs: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(SettingsFontSurface.scopeHeading)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
            HStack(spacing: Slate.Metric.space2) {
                ForEach(SettingsFontScope.allCases) { tab in scopePill(tab) }
            }
        }
    }

    private func scopePill(_ tab: SettingsFontScope) -> some View {
        let selected = tab == scope
        return Button { scope = tab } label: {
            Text(tab.label)
                .font(SettingsType.subtitle)
                .foregroundStyle(selected ? SettingsInk.ground : SettingsInk.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(Capsule().fill(selected ? SettingsInk.primary : Color.clear))
                .overlay(Capsule().strokeBorder(SettingsInk.hairline, lineWidth: selected ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The contextual note under the tab row.
    private var scopeNote: some View { note(scope.note) }

    /// The body for the active scope — the Global auto-match + four face pickers, or the Fallback list
    /// editor.
    @ViewBuilder private var scopeBody: some View {
        switch scope {
        case .global:
            globalFamilyEditors
        case .fallback:
            FallbackListEditor(raw: $store.terminal.fontFamilyFallback)
        }
    }

    /// Global scope: the Auto-match toggle, the primary Font Family combobox, then the Bold / Italic /
    /// Bold-Italic face pickers (shown always but DISABLED + dimmed while auto-match is on, per
    /// `font-setting.png`). The per-face families are global ``TerminalPreferences`` fields.
    @ViewBuilder private var globalFamilyEditors: some View {
        Toggle(
            settingLabel(AllSettingsCatalog.RenderKey.fontAutoMatchWeightStyle),
            isOn: $store.terminal.autoMatchWeightStyle,
        )
        primaryFamilyRow($store.terminal.fontFamily, placeholder: SettingsFontSurface.primaryPlaceholder)
        let locked = store.terminal.autoMatchWeightStyle
        faceRow(AllSettingsCatalog.RenderKey.fontFamilyBold, $store.terminal.fontFamilyBold, locked: locked)
        faceRow(AllSettingsCatalog.RenderKey.fontFamilyItalic, $store.terminal.fontFamilyItalic, locked: locked)
        faceRow(
            AllSettingsCatalog.RenderKey.fontFamilyBoldItalic,
            $store.terminal.fontFamilyBoldItalic,
            locked: locked,
        )
    }

    private func primaryFamilyRow(_ binding: Binding<String>, placeholder: String) -> some View {
        LabeledContent(settingLabel(AllSettingsCatalog.RenderKey.fontFamily)) {
            FontFamilyComboBox(selection: binding, placeholder: placeholder)
        }
    }

    private func faceRow(_ key: String, _ binding: Binding<String>, locked: Bool) -> some View {
        LabeledContent(settingLabel(key)) {
            FontFamilyComboBox(
                selection: binding, placeholder: SettingsFontSurface.derivedPlaceholder(locked: locked),
            )
        }
        .disabled(locked)
        .opacity(locked ? Slate.Opacity.withheld : 1)
    }

    /// The host-installation boundary note (the terminal renders on the host; specimens are this device's).
    private var hostFontNote: some View { note(SettingsFontSurface.hostNote) }

    // MARK: - Note helpers

    /// A muted footnote note (a gray contextual line).
    private func note(_ text: String) -> some View {
        Text(text)
            .font(SettingsType.subtitle)
            .foregroundStyle(SettingsInk.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - FontFamilyComboBox (free-text entry + "Aa" specimen dropdown)

/// The Font Family combobox: an editable field bound to the scope value, with a trailing chevron that opens
/// a searchable popover of this device's monospaced faces, each shown as an "Aa" specimen in its own face.
/// Free-text (not a closed Picker) because the terminal renders on the HOST — any host-installed family can be
/// typed even if this device lacks it.
///
/// DRAFT-COMMIT: the store-backed rows must NOT write `selection` per keystroke — every
/// write rides `PreferencesStore.terminal`/`.appearance` `didSet` → persist + `TerminalConfigBroadcaster`
/// → every live terminal reloads libghostty config + PTY-resizes. So keystrokes edit a LOCAL draft that is
/// committed via ``DraftCommitDebouncer`` — after a short idle pause (live preview: one trailing commit per
/// burst), and immediately on submit / focus loss / teardown. A specimen pick writes `selection` directly
/// (one discrete, intentional commit). `draftCommit: false` keeps the old write-through for a binding that
/// is itself a cheap local `@State` read synchronously by a sibling control (the Fallback "Add" row).
private struct FontFamilyComboBox: View {
    @Binding var selection: String
    var placeholder: String
    /// Whether keystrokes are held in a local draft and committed on idle/submit/blur (default — for the
    /// store-backed rows). `false` = write-through (local-`@State` bindings only, e.g. the Fallback add row).
    var draftCommit = true

    @State private var showingList = false
    @State private var query = ""
    /// The local draft the text field edits in draft-commit mode (seeded from `selection`).
    @State private var draft = ""
    /// The trailing-edge idle committer (one commit per typing burst — see `DraftCommitDebouncerTests`).
    @State private var debouncer = DraftCommitDebouncer()
    /// Focus probe for the commit-on-blur edge.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            TextField(placeholder, text: draftCommit ? $draft : $selection)
                .textFieldStyle(.plain)
                .font(SettingsType.body)
                .frame(minWidth: 150, alignment: .leading)
                .focused($fieldFocused)
                .onSubmit { commitDraftNow() }
            Button {
                showingList.toggle()
            } label: {
                Image(systemSymbol: .chevronUpChevronDown)
                    .font(SettingsType.caption)
                    .foregroundStyle(SettingsInk.tertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingList, arrowEdge: .bottom) { specimenList }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                .fill(SettingsInk.inset),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                .strokeBorder(SettingsInk.hairline, lineWidth: 1),
        )
        .onAppear { draft = selection }
        .onChange(of: selection) { _, external in
            // An external write (specimen pick / reset / another scope) resyncs the draft. Also the echo of
            // our own commit — `external == draft` then, so the guarded assignment is a no-op.
            if external != draft { draft = external }
        }
        .onChange(of: draft) { _, newValue in
            guard draftCommit else { return }
            guard newValue != selection else {
                debouncer.cancel() // typed back to the committed value / resync echo — nothing to commit
                return
            }
            // Reschedules per keystroke; only the LAST closure (latest draft) fires, once, after idle.
            debouncer.schedule { selection = newValue }
        }
        .onChange(of: fieldFocused) { _, focused in
            if !focused { commitDraftNow() } // commit-on-blur
        }
        .onDisappear { commitDraftNow() } // teardown (scope-tab switch / sheet close) never drops an edit
    }

    /// Submit / blur / teardown: commit the draft NOW, cancelling any pending idle commit (never double-fires;
    /// an unchanged draft is a no-op so the store `didSet` isn't churned).
    private func commitDraftNow() {
        guard draftCommit else { return }
        debouncer.flush {
            if draft != selection { selection = draft }
        }
    }

    /// The popover: a search field + a scrollable specimen list. A custom popover (not an `NSMenu`) so the
    /// per-row "Aa" renders in the actual font (menu items flatten custom fonts).
    private var specimenList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemSymbol: .magnifyingglass)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.tertiary)
                TextField(SettingsFontSurface.specimenSearchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(SettingsType.label)
            }
            .padding(Slate.Metric.space2)
            Rectangle().fill(SettingsInk.hairline).frame(height: Slate.Metric.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { family in
                        specimenRow(family)
                    }
                    if filtered.isEmpty {
                        Text(SettingsFontSurface.specimenEmpty)
                            .font(SettingsType.subtitle)
                            .foregroundStyle(SettingsInk.tertiary)
                            .padding(Slate.Metric.space2)
                    }
                }
            }
        }
        .frame(width: 280, height: 320)
        .background(SettingsInk.ground)
    }

    private func specimenRow(_ family: String) -> some View {
        Button {
            selection = family
            showingList = false
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Text("Aa")
                    .font(.custom(family, size: SettingsMetric.resolvedBodyPointSize))
                    .frame(width: 28, alignment: .leading)
                Text(family)
                    .font(SettingsType.body)
                    .foregroundStyle(SettingsInk.primary)
                Spacer(minLength: 0)
                if family == selection {
                    Image(systemSymbol: .checkmark)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.accent)
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [String] { InstalledFontFamilies.matching(query) }
}

// MARK: - FallbackListEditor (the comma-separated fallback list)

/// The Fallback scope's list editor: each existing fallback family as a removable "Aa" row, plus an add
/// combobox. Reads/writes the comma-separated ``TerminalPreferences/fontFamilyFallback`` (which the builder
/// emits as the repeated-`font-family` fallback chain — ghostty has no `font-family-fallback` key).
private struct FallbackListEditor: View {
    @Binding var raw: String
    @State private var draft = ""

    private var entries: [String] { SettingsFontFallbackList.entries(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            if entries.isEmpty {
                Text(SettingsFontSurface.fallbackEmpty)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.tertiary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, family in
                    HStack(spacing: Slate.Metric.space2) {
                        Text("Aa")
                            .font(.custom(family, size: SettingsMetric.resolvedBodyPointSize))
                            .frame(width: 28, alignment: .leading)
                        Text(family)
                            .font(SettingsType.body)
                        Spacer(minLength: 0)
                        Button { remove(at: index) } label: {
                            Image(systemSymbol: .minusCircle)
                                .foregroundStyle(SettingsInk.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(SettingsFontSurface.fallbackRemoveHint)
                    }
                }
            }
            HStack(spacing: Slate.Metric.space2) {
                // Write-through (`draftCommit: false`): this binding is the editor's own local `@State` —
                // no store write per keystroke — and the Add button + its `.disabled` gate read it
                // synchronously, so an inner idle-draft would make Add act on a stale value.
                FontFamilyComboBox(
                    selection: $draft,
                    placeholder: SettingsFontSurface.fallbackAddPlaceholder,
                    draftCommit: false,
                )
                Button(SettingsFontSurface.fallbackAddTitle) { add() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// A `nil` from the shared rule means there is nothing to add — an empty name, or one the list already
    /// has — and leaving `raw` alone is what keeps an identical rewrite from churning the store's `didSet`.
    private func add() {
        let name = draft
        draft = ""
        guard let updated = SettingsFontFallbackList.adding(name, to: raw) else { return }
        raw = updated
    }

    private func remove(at index: Int) {
        guard let updated = SettingsFontFallbackList.removing(at: index, from: raw) else { return }
        raw = updated
    }
}

#endif
