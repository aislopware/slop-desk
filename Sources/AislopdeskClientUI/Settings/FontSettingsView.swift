// FontSettingsView — the Appearance → Font section (E15 WI-8).
//
// Follows the design spec `docs/ui-shell/screenshots/font-setting.png` + `font-setting-bold.png`: the
// "FONT FAMILY" section opens with a "Settings for" pill row of SCOPE TABS — Computed / Global / Light Theme
// / Dark Theme / Fallback — then a contextual note, the "Auto-match weight & style" toggle, the Font Family
// combobox with "Aa" specimens (and, when auto-match is OFF, the Bold / Italic / Bold-Italic face pickers),
// then Text (size + line-height), Ligatures, and the Style & Rendering controls (bold / italic / underline /
// blink / blending) with deferred-apply notes. Replaces the old `Section("Font")` (family TextField + size
// Stepper) in `AppearanceSettingsTab`.
//
// BINDINGS (golden-safe — pure client chrome, never the wire/sidecar/`EnvConfig`): every render control binds
// `store.terminal` (a ``TerminalPreferences`` font-parity field), so a change flows through the store's
// `terminal` `didSet` → `applyTerminal()` → `TerminalConfigBroadcaster` and re-applies live via the
// font-parity keys the builder emits. The per-theme scope tabs (Light / Dark) write
// `store.appearance.themeFonts[slug]`, keyed by the slot's resolved theme slug (pure
// ``FontScopeResolver/lightSlotSlug(_:)`` / `darkSlotSlug(_:)`); the read-only Computed tab shows
// ``FontScopeResolver/resolvedFamily(global:themeFonts:slug:fallback:)`` for the active OS-appearance slot.
//
// DEFERRED-APPLY (decision #5): the underline-off and SGR-blink toggles, and the `srgb-over` / `linear` /
// `perceptual` blending modes, have no verified stock libghostty key — they PERSIST + surface here with a
// note but are NOT emitted (exactly the precedent set by `cursorAnimation = .smooth`). Ligatures, fallback,
// per-face families, bold/italic mode, line-height, and `macos-like` blending (→ `font-thicken`) DO map and
// re-render live.
//
// HOST-FONT REALITY (`spec/customization__fonts.md` mapping notes): the terminal renders on the HOST inside
// libghostty, so font INSTALLATION is a host concern — there is no client "font folder" to open. The Font
// Family field is therefore a free-text combobox (type any family the host has) whose specimen dropdown lists
// THIS device's monospaced faces only as a convenience; a note makes the host boundary explicit. There are
// no "Install font" / "Open font folder" buttons — no client analog exists (the host owns font installation).
//
// PLATFORM: cross-platform (compiled on iOS too). The installed-font enumeration goes through CoreText
// (`CTFontManagerCopyAvailableFontFamilyNames`), nonisolated + cross-platform — no AppKit/UIKit, no
// MainActor hop. Slate.* tokens only (no raw font/radius literals — `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import CoreText
import SFSafeSymbols
import SwiftUI

// MARK: - FontSettingsView

/// The Appearance → Font `Section`s (scope tabs + family combobox + size / line-height / ligatures / style),
/// bound to the live ``PreferencesStore``. Hosted by `AppearanceSettingsTab` in place of the old Font section.
struct FontSettingsView: View {
    @Bindable var store: PreferencesStore

    /// The active Font-Family SCOPE tab. Defaults to **Global** — the primary, always-rendered family field.
    @State private var scope: FontScope = .global
    /// The custom line-height multiplier (Custom mode), seeded from the model on appear so the slider opens at
    /// the persisted value rather than snapping.
    @State private var customMultiplier: Double = 1.2

    var body: some View {
        Group {
            fontFamilySection
            textSection
            ligaturesSection
            styleSection
        }
        .onAppear {
            if case let .custom(value) = store.terminal.lineHeight { customMultiplier = value }
        }
    }

    // MARK: - Font Family section (scope tabs + combobox)

    private var fontFamilySection: some View {
        slateFormSection("Font Family") {
            scopeTabs
            scopeNote
            scopeBody
            hostFontNote
        }
    }

    /// The "Settings for" label + the pill row of scope tabs (Computed / Global / Light / Dark / Fallback).
    private var scopeTabs: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text("Settings for")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
            HStack(spacing: Slate.Metric.space2) {
                ForEach(FontScope.allCases) { tab in scopePill(tab) }
            }
        }
    }

    private func scopePill(_ tab: FontScope) -> some View {
        let selected = tab == scope
        return Button { scope = tab } label: {
            Text(tab.label)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(selected ? Slate.Surface.window : Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(Capsule().fill(selected ? Slate.Text.primary : Color.clear))
                .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: selected ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The contextual note under the tab row — the muted "saved into …" line, or (Global) the precedence
    /// banner. NOTE: aislopdesk resolves a per-theme font OVER Global (scope-over-Global, see
    /// ``FontScopeResolver``), so the banner states the real precedence — Global applies only where a theme
    /// sets no font of its own, not "takes priority everywhere".
    @ViewBuilder private var scopeNote: some View {
        switch scope {
        case .computed:
            note("Read-only — the effective font for the active theme. Edit Global, Light Theme, or Dark "
                + "Theme to change it.")
        case .global:
            warnNote("Applies everywhere a theme sets no font of its own; a Light or Dark theme font "
                + "overrides this.")
        case .light:
            note("Saved into the light theme — travels with that theme.")
        case .dark:
            note("Saved into the dark theme — travels with that theme.")
        case .fallback:
            note("Fonts used, in order, when the primary font lacks a glyph (e.g. CJK or Nerd-Font icons).")
        }
    }

    /// The body for the active scope — the read-only Computed value, the Global auto-match + four face
    /// pickers, a single per-theme family picker for Light / Dark, or the Fallback list editor.
    @ViewBuilder private var scopeBody: some View {
        switch scope {
        case .computed:
            LabeledContent("Font Family") {
                Text(computedFamily)
                    .font(.system(size: Slate.Typeface.body, design: .monospaced))
                    .foregroundStyle(Slate.Text.secondary)
            }
        case .global:
            globalFamilyEditors
        case .light:
            primaryFamilyRow(themeFontBinding(slug: lightSlug), placeholder: "Default (Global)")
        case .dark:
            primaryFamilyRow(themeFontBinding(slug: darkSlug), placeholder: "Default (Global)")
        case .fallback:
            FallbackListEditor(raw: $store.terminal.fontFamilyFallback)
        }
    }

    /// Global scope: the Auto-match toggle, the primary Font Family combobox, then the Bold / Italic /
    /// Bold-Italic face pickers (shown always but DISABLED + dimmed while auto-match is on, per
    /// `font-setting.png`). The per-face families are global ``TerminalPreferences`` fields.
    @ViewBuilder private var globalFamilyEditors: some View {
        Toggle("Auto-match weight & style", isOn: $store.terminal.autoMatchWeightStyle)
        primaryFamilyRow($store.terminal.fontFamily, placeholder: "Default")
        let locked = store.terminal.autoMatchWeightStyle
        faceRow("Font Family (Bold)", $store.terminal.fontFamilyBold, locked: locked)
        faceRow("Font Family (Italic)", $store.terminal.fontFamilyItalic, locked: locked)
        faceRow("Font Family (Bold Italic)", $store.terminal.fontFamilyBoldItalic, locked: locked)
    }

    private func primaryFamilyRow(_ binding: Binding<String>, placeholder: String) -> some View {
        LabeledContent("Font Family") {
            FontFamilyComboBox(selection: binding, placeholder: placeholder)
        }
    }

    private func faceRow(_ label: String, _ binding: Binding<String>, locked: Bool) -> some View {
        LabeledContent(label) {
            FontFamilyComboBox(selection: binding, placeholder: locked ? "Auto" : "Unset")
        }
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
    }

    /// The host-installation boundary note (the terminal renders on the host; specimens are this device's).
    private var hostFontNote: some View {
        note("Fonts are installed and rendered on the host. Type any family the host has; the picker lists "
            + "this device's monospaced faces for convenience.")
    }

    // MARK: - Text section (size + line height)

    private var textSection: some View {
        slateFormSection("Text") {
            Stepper(
                "Size: \(Int(store.terminal.fontSize))",
                value: $store.terminal.fontSize, in: 8...32, step: 1,
            )
            LabeledContent("Line height") {
                Picker("", selection: lineHeightChoiceBinding) {
                    Text("Default").tag(LineHeightChoice.default)
                    Text("Compact (1.0×)").tag(LineHeightChoice.compact)
                    Text("Loose (1.2×)").tag(LineHeightChoice.loose)
                    Text("Custom").tag(LineHeightChoice.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if lineHeightChoiceBinding.wrappedValue == .custom {
                LabeledContent("Multiplier") {
                    HStack(spacing: Slate.Metric.space2) {
                        Slider(value: customMultiplierBinding, in: 0.8...2.0, step: 0.05)
                        Text(String(format: "%.2f×", customMultiplier))
                            .foregroundStyle(Slate.Text.secondary)
                            .monospacedDigit()
                    }
                }
                note("Changing line height re-measures the cell and reflows the terminal (a resize).")
            }
        }
    }

    // MARK: - Ligatures section

    private var ligaturesSection: some View {
        slateFormSection("Ligatures") {
            Picker("Ligatures", selection: $store.terminal.fontLigatures) {
                Text("Off").tag(FontLigatures.off)
                Text("Standard (calt)").tag(FontLigatures.calt)
                Text("Discretionary (dlig)").tag(FontLigatures.dlig)
            }
            Toggle("Extend ligation to alphabetic sequences", isOn: $store.terminal.fontLigaturesAlphabet)
                .disabled(store.terminal.fontLigatures == .off)
            note("Requires a font with ligatures (e.g. Fira Code, JetBrains Mono); the default SF Mono has none.")
        }
    }

    // MARK: - Style & Rendering section (bold / italic / underline / blink / blending + deferral notes)

    private var styleSection: some View {
        slateFormSection("Style & Rendering") {
            Picker("Bold", selection: $store.terminal.fontBold) { styleModeOptions }
            Picker("Italic", selection: $store.terminal.fontItalic) { styleModeOptions }

            Toggle("Render SGR underlines", isOn: $store.terminal.fontUnderline)
            if !store.terminal.fontUnderline {
                note("Underline-off is saved but deferred — no verified renderer key, so SGR underlines still "
                    + "draw. OSC 8 link underlines and strikethrough are unaffected either way.")
            }

            Toggle("Render SGR blink", isOn: $store.terminal.fontBlink)
            if store.terminal.fontBlink {
                note("Blink is saved but deferred — no verified renderer key, so SGR 5/6 cells do not yet blink.")
            }

            Picker("Blending", selection: $store.terminal.fontBlending) { blendingOptions }
            if isDeferredBlending(store.terminal.fontBlending) {
                note("This blending mode is saved but deferred — only Default and macOS-like apply (macOS-like "
                    + "maps to font-thicken). sRGB Over, Linear, and Perceptual have no verified renderer key.")
            }
        }
    }

    @ViewBuilder private var styleModeOptions: some View {
        Text("Auto").tag(FontStyleMode.auto)
        Text("Off").tag(FontStyleMode.off)
        Text("Primary Only").tag(FontStyleMode.primaryOnly)
        Text("Synthetic").tag(FontStyleMode.synthetic)
    }

    @ViewBuilder private var blendingOptions: some View {
        Text("Default").tag(FontBlending.default)
        Text("sRGB Over").tag(FontBlending.srgbOver)
        Text("macOS-like").tag(FontBlending.macosLike)
        Text("Linear").tag(FontBlending.linear)
        Text("Perceptual").tag(FontBlending.perceptual)
    }

    /// Whether a blending mode is one of the persisted-but-not-emitted modes (everything except `default` and
    /// `macos-like`, which is the one mode that maps to a verified `font-thicken` key).
    private func isDeferredBlending(_ mode: FontBlending) -> Bool {
        switch mode {
        case .default,
             .macosLike: false
        case .srgbOver,
             .linear,
             .perceptual: true
        }
    }

    // MARK: - Scope slug resolution + bindings

    /// The slug the Light Theme tab writes under (pure ``FontScopeResolver``).
    private var lightSlug: String { FontScopeResolver.lightSlotSlug(store.appearance) }
    /// The slug the Dark Theme tab writes under.
    private var darkSlug: String { FontScopeResolver.darkSlotSlug(store.appearance) }

    /// The read-only Computed family for the slot active under the current OS appearance: Global wins, else the
    /// active slot's per-theme font, else the bundled default. `ThemeStore.shared.osIsDark()` is the live OS
    /// appearance probe (a closure → safe to read in `body`).
    private var computedFamily: String {
        let slug = FontScopeResolver.activeSlotSlug(store.appearance, osIsDark: ThemeStore.shared.osIsDark())
        return FontScopeResolver.resolvedFamily(
            global: store.terminal.fontFamily,
            themeFonts: store.appearance.themeFonts,
            slug: slug,
            fallback: TerminalPreferences().fontFamily,
        )
    }

    /// Bind a per-theme font (`appearance.themeFonts[slug]`): an empty write CLEARS the entry (and empties the
    /// dict to `nil` when it was the last) so the slot reverts to Global — keeping the all-`nil` golden-safe
    /// default. Mutating `store.appearance` once routes through its `didSet` (theme repoint), persisting only
    /// to `UserDefaults`.
    private func themeFontBinding(slug: String) -> Binding<String> {
        Binding(
            get: { store.appearance.themeFonts?[slug] ?? "" },
            set: { newValue in
                var appearance = store.appearance
                var map = appearance.themeFonts ?? [:]
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    map.removeValue(forKey: slug)
                } else {
                    map[slug] = newValue
                }
                appearance.themeFonts = map.isEmpty ? nil : map
                store.appearance = appearance
            },
        )
    }

    /// Bridge ``LineHeightMode`` (an associated-value enum) to the four-case picker. A `.custom` pick seeds
    /// from the live `customMultiplier`; switching back preserves the model.
    private var lineHeightChoiceBinding: Binding<LineHeightChoice> {
        Binding(
            get: {
                switch store.terminal.lineHeight {
                case .default: .default
                case .compact: .compact
                case .loose: .loose
                case .custom: .custom
                }
            },
            set: { choice in
                switch choice {
                case .default: store.terminal.lineHeight = .default
                case .compact: store.terminal.lineHeight = .compact
                case .loose: store.terminal.lineHeight = .loose
                case .custom: store.terminal.lineHeight = .custom(customMultiplier)
                }
            },
        )
    }

    /// The custom line-height multiplier slider binding — updates the local seed AND the model (`.custom(m)`).
    private var customMultiplierBinding: Binding<Double> {
        Binding(
            get: { customMultiplier },
            set: { value in
                customMultiplier = value
                store.terminal.lineHeight = .custom(value)
            },
        )
    }

    // MARK: - Note helpers

    /// A muted footnote note (a gray contextual line).
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The red/amber-tinted banner styling (`font-setting-bold.png`), reused for the Global-scope
    /// precedence call-out (a per-theme font can override Global).
    private func warnNote(_ text: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .exclamationmarkTriangle)
            Text(text)
        }
        .font(.system(size: Slate.Typeface.footnote))
        .foregroundStyle(Slate.Status.warn)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .fill(Slate.Status.warn.opacity(0.12)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .strokeBorder(Slate.Status.warn.opacity(0.4), lineWidth: 1),
        )
    }
}

// MARK: - FontScope (the five "Settings for" tabs)

/// The Font-Family scope tabs (`font-setting.png`): the read-only effective family, the global override, the
/// per-theme slots, and the fallback list. UI-only (the per-scope write target lives in `FontSettingsView`).
private enum FontScope: String, CaseIterable, Identifiable {
    case computed
    case global
    case light
    case dark
    case fallback

    var id: String { rawValue }

    var label: String {
        switch self {
        case .computed: "Computed"
        case .global: "Global"
        case .light: "Light Theme"
        case .dark: "Dark Theme"
        case .fallback: "Fallback"
        }
    }
}

// MARK: - LineHeightChoice (picker tag for the associated-value LineHeightMode)

/// A flat, `Hashable` mirror of ``LineHeightMode``'s four cases for the SwiftUI `Picker` tag (the model enum
/// carries an associated `Double` on `.custom`, so it can't be a tag directly). The custom multiplier lives in
/// `FontSettingsView.customMultiplier`.
private enum LineHeightChoice: Hashable {
    case `default`
    case compact
    case loose
    case custom
}

// MARK: - FontFamilyComboBox (free-text entry + "Aa" specimen dropdown)

/// The Font Family combobox: an editable field bound to the scope value, with a trailing chevron that opens
/// a searchable popover of this device's monospaced faces, each shown as an "Aa" specimen in its own face.
/// Free-text (not a closed Picker) because the terminal renders on the HOST — any host-installed family can be
/// typed even if this device lacks it.
private struct FontFamilyComboBox: View {
    @Binding var selection: String
    var placeholder: String

    @State private var showingList = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            TextField(placeholder, text: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .frame(minWidth: 150, alignment: .leading)
            Button {
                showingList.toggle()
            } label: {
                Image(systemSymbol: .chevronUpChevronDown)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingList, arrowEdge: .bottom) { specimenList }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                .fill(Slate.Surface.element),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl, style: .continuous)
                .strokeBorder(Slate.Line.subtle, lineWidth: 1),
        )
    }

    /// The popover: a search field + a scrollable specimen list. A custom popover (not an `NSMenu`) so the
    /// per-row "Aa" renders in the actual font (menu items flatten custom fonts).
    private var specimenList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemSymbol: .magnifyingglass)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Slate.Typeface.base))
            }
            .padding(Slate.Metric.space2)
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { family in
                        specimenRow(family)
                    }
                    if filtered.isEmpty {
                        Text("No matching fonts on this device.")
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.tertiary)
                            .padding(Slate.Metric.space2)
                    }
                }
            }
        }
        .frame(width: 280, height: 320)
        .background(Slate.Surface.window)
    }

    private func specimenRow(_ family: String) -> some View {
        Button {
            selection = family
            showingList = false
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Text("Aa")
                    .font(.custom(family, size: Slate.Typeface.body))
                    .frame(width: 28, alignment: .leading)
                Text(family)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.primary)
                Spacer(minLength: 0)
                if family == selection {
                    Image(systemSymbol: .checkmark)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.State.accent)
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return InstalledFonts.families }
        return InstalledFonts.families.filter { $0.lowercased().contains(needle) }
    }
}

// MARK: - FallbackListEditor (the comma-separated fallback list)

/// The Fallback scope's list editor: each existing fallback family as a removable "Aa" row, plus an add
/// combobox. Reads/writes the comma-separated ``TerminalPreferences/fontFamilyFallback`` (which the builder
/// emits as the repeated-`font-family` fallback chain — ghostty has no `font-family-fallback` key).
private struct FallbackListEditor: View {
    @Binding var raw: String
    @State private var draft = ""

    private var entries: [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            if entries.isEmpty {
                Text("No fallback fonts.")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, family in
                    HStack(spacing: Slate.Metric.space2) {
                        Text("Aa")
                            .font(.custom(family, size: Slate.Typeface.body))
                            .frame(width: 28, alignment: .leading)
                        Text(family)
                            .font(.system(size: Slate.Typeface.body))
                        Spacer(minLength: 0)
                        Button { remove(at: index) } label: {
                            Image(systemSymbol: .minusCircle)
                                .foregroundStyle(Slate.Text.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove fallback font")
                    }
                }
            }
            HStack(spacing: Slate.Metric.space2) {
                FontFamilyComboBox(selection: $draft, placeholder: "Add a fallback font")
                Button("Add") { add() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        guard !name.isEmpty, !entries.contains(name) else { return }
        raw = (entries + [name]).joined(separator: ", ")
    }

    private func remove(at index: Int) {
        var list = entries
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        raw = list.joined(separator: ", ")
    }
}

// MARK: - InstalledFonts (this device's monospaced faces — a typing convenience, not authoritative)

/// The locally-installed monospaced font families (best-effort), computed ONCE (a `static let` is lazy +
/// thread-safe) via CoreText so it stays nonisolated + cross-platform. NOTE: these are the CLIENT's fonts —
/// the terminal renders on the HOST, which may have a different set; the list is a convenience for typing,
/// never an authoritative or enforced set. The monospace filter falls back to the full family list if it
/// resolves nothing (so the picker is never empty on an unusual font setup).
private enum InstalledFonts {
    static let families: [String] = compute()

    private static func compute() -> [String] {
        let all = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let mono = all.filter(isMonospace)
        return (mono.isEmpty ? all : mono).sorted()
    }

    /// Whether a family resolves to a monospaced (fixed-pitch) face — a CoreText symbolic-trait probe.
    private static func isMonospace(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary,
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }
}
#endif
