// SettingsView — the SwiftUI Settings surface (REBUILD-V2, WS-D / D4; E7 9-section taxonomy).
//
// A two-column Settings window whose right column is a THIN `@Bindable` binding over the one live
// `@Observable` `PreferencesStore`. Each section edits a slice of the typed prefs models
// (`TerminalPreferences`, `VideoPreferences`, `AgentPreferences`, `AppearancePreferences`,
// `KeybindingPreferences`) or the fire-time `SettingsKey` toggles (bound via `@Default(.key)`), and the
// store's `didSet` apply-paths do the rest (terminal live-reload, env overlay + sidecar, theme repoint,
// keybinding republish).
//
// LAYOUT (otty fidelity): otty renders Settings as a TWO-COLUMN window — a left NAVIGATOR column with a
// rounded SEARCH PILL pinned at the top and a vertical icon+label section list, and a content column on the
// right (`docs/otty-clone/screenshots/{all-settings,launch-option,editor-settings,cursor-style}.png`). This
// view reproduces that with a flat two-column `HStack` (NOT a macOS `TabView` top tab strip): a fixed-width
// `Otty.Surface.sidebar` navigator (`settingsSidebarWidth`) holding `SettingsSidebarSearchField` + the
// `SettingsSidebarRow` list, a hairline divider, and the selected section's `Form` on the right. The sidebar
// search pill (which SECTION ROWS show) is DISTINCT from the Advanced → All-Settings content search (which
// config KEYS show) — otty surfaces both, and so do we.
//
// E7 reorg: the old 5-tab strip (General / Terminal / Video / Keybindings / Advanced) is reshaped into
// otty's 9 sections (`SettingsSection`): General / Shell / Controls / Editor / Agents / Appearance /
// Recipes / Key Bindings / Advanced. Groups relocate to their otty home proven by the screenshots: terminal
// FONT (family + size) + the CURSOR group (style + blink) → **Appearance** (`font-setting.png` /
// `cursor-style.png` both show them under Appearance); SCROLLBACK → **Controls** (`spec/terminal-features__
// scroll.md`: Settings → Controls → Scroll); theme → Appearance; agent host flags → Agents; the Close
// Confirmation pickers (Closing Tab / Closing Window) → **General** (`launch-option.png` shows them on the
// General page). otty's **Editor** section is the built-in FILE-editor's settings (Soft Wrap / Line Numbers /
// Tab Size — `editor-settings.png`) and **Recipes** is a saved-command library (`all-settings.png`), neither
// of which aislopdesk has an equivalent for, so both stay RESERVED/empty (deferral placeholders, kept 1:1 in
// the navigator, not terminal-render prefs). The 5 orphan toggles + the Controls/Scroll/Copy toggles are
// surfaced via `@Default(.key)`; the Video HOST flags (QP/FEC/pacer/sharpen) have no otty section, so they
// fold into Advanced as a "Video (host)" sub-section (real functionality — not dropped).
//
// SURFACING: the main window is `.hiddenTitleBar` and `OverlayCoordinator` is NOT yet mounted, so this
// rides a STOCK SwiftUI `Settings` scene (`AislopdeskSettingsScene`) — ⌘, opens a separate, system-chromed
// window that does not clash with otty's hover-reveal titlebar. When the coordinator lands, the same view
// tree can be relocated into an in-window otty panel via `settingsVisible`. `SettingsView` itself stays
// cross-platform so the iOS settings sheet (WI-5) can host the same section structs.
//
// DEFERRED vs LIVE-APPLY: each section is tagged with an `ApplyTiming` chip (`.live` applies immediately;
// `.reconnect` is a HOST-read flag shipped via the sidecar that only takes effect on the next host
// connection). Terminal + appearance + keybindings + the fire-time toggles are live; the video/agent HOST
// flags are reconnect-only; SYMMETRIC keys (FEC) additionally carry a "set on both ends" warning.
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import Defaults
import SwiftUI

// MARK: - Settings scene (stock SwiftUI, ⌘,)

/// The stock `Settings` scene wrapper, wired in `AislopdeskClientApp`. Stock (not an otty in-window panel)
/// because the main window hides its titlebar and the overlay host is not yet mounted (see file header).
/// macOS-only: the `Settings` scene is unavailable on iOS (the iOS settings surface lands as an in-app
/// sheet later); `SettingsView` itself stays cross-platform so iOS can host it once that lands.
#if os(macOS)
public struct AislopdeskSettingsScene: Scene {
    private let store: PreferencesStore
    /// The live workspace owner, injected so the Advanced → Workspace rows (E7 WI-4) can export/import. The
    /// `Settings` scene is SEPARATE from the main WindowGroup, so the store is threaded in here explicitly
    /// (an environment value set on the WindowGroup does not cross into this scene). Optional so a preview
    /// or a future host can omit it (the Workspace section then renders disabled).
    private let workspaceStore: WorkspaceStore?

    public init(store: PreferencesStore, workspaceStore: WorkspaceStore? = nil) {
        self.store = store
        self.workspaceStore = workspaceStore
    }

    public var body: some Scene {
        Settings {
            SettingsView(store: store)
                .workspaceStore(workspaceStore)
                .tint(Otty.State.accent)
                .preferredColorScheme(Otty.colorScheme)
        }
    }
}
#endif

// MARK: - Settings taxonomy (the 9 otty sections — one source for the macOS navigator + the iOS list)

/// The otty settings taxonomy — 9 sections, each rendered as an icon+label row in the macOS two-column
/// navigator (and, once WI-5 lands, a navigation row in the iOS sheet). The title + otty sidebar
/// `systemImage` live here as the ONE source so the macOS navigator and the (future) iOS list never drift;
/// `SettingsSectionTaxonomyTests` pins
/// the set + order against an accidental drop/reorder/icon-swap. Order + glyphs mirror otty's sidebar
/// (`docs/otty-clone/screenshots/all-settings.png`): General, Shell, Controls, Editor, Agents, Appearance,
/// Recipes, Key Bindings, Advanced.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shell
    case controls
    case editor
    case agents
    case appearance
    case recipes
    case keybindings
    case advanced

    var id: String { rawValue }

    /// The navigator row label (and iOS row title).
    var title: String {
        switch self {
        case .general: "General"
        case .shell: "Shell"
        case .controls: "Controls"
        case .editor: "Editor"
        case .agents: "Agents"
        case .appearance: "Appearance"
        case .recipes: "Recipes"
        case .keybindings: "Key Bindings"
        case .advanced: "Advanced"
        }
    }

    /// The otty sidebar glyph for the section (SF Symbol name), matched to otty's sidebar as closely as SF
    /// Symbols allow: General = `exclamationmark.circle`, Controls = `flag` (pennant/pointer), Agents =
    /// `powerplug`, Recipes = `book`, Key Bindings = `bolt` (lightning).
    var systemImage: String {
        switch self {
        case .general: "exclamationmark.circle"
        case .shell: "terminal"
        case .controls: "flag"
        case .editor: "doc.text"
        case .agents: "powerplug"
        case .appearance: "paintpalette"
        case .recipes: "book"
        case .keybindings: "bolt"
        case .advanced: "wrench"
        }
    }

    /// Whether the section is macOS-only — dropped from the compact iOS settings sheet (WI-5). Today the
    /// sole macOS-only section is **Keybindings**: its chord CAPTURE is a macOS `NSEvent` local monitor
    /// (`KeybindingsEditorView`'s `KeyCaptureMonitor` is `#if os(macOS)`), so there is no iOS capture UI for
    /// it. Every other section is cross-platform — the Advanced section's macOS-HOST-only *rows* (the raw
    /// `AISLOPDESK_*` editor + the Video host flags) are gated INSIDE `AdvancedSettingsTab`, not by hiding
    /// the whole section, so the cross-platform All-Settings list still reaches the iOS sheet. `SettingsSheet`
    /// filters `allCases` on this; `SettingsSectionTaxonomyTests` pins that Keybindings is the only one.
    var isMacOSOnly: Bool {
        switch self {
        case .keybindings: true
        default: false
        }
    }
}

// MARK: - Apply-timing tag (deferred vs live, surfaced as a chip not prose)

/// When a setting takes effect — surfaced as a small chip so the deferred/live distinction is a DATA
/// attribute, not buried in prose (D4).
enum ApplyTiming {
    case live // applies immediately (terminal reload / theme / keybinding republish / fire-time key)
    case reconnect // a HOST-read flag shipped via the sidecar — applies on the next host connection

    var label: String {
        switch self {
        case .live: "Applies now"
        case .reconnect: "Applies on reconnect"
        }
    }

    var symbol: String {
        switch self {
        case .live: "bolt.fill"
        case .reconnect: "arrow.triangle.2.circlepath"
        }
    }
}

/// A small inline timing chip (symbol + label). The tint reads the `@MainActor` `Otty.Status` tokens in
/// the view body (not on the nonisolated enum).
private struct TimingChip: View {
    let timing: ApplyTiming
    var body: some View {
        HStack(spacing: Otty.Metric.space1) {
            Image(systemName: timing.symbol)
            Text(timing.label)
        }
        .font(.system(size: Otty.Typeface.small))
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch timing {
        case .live: Otty.Status.ok
        case .reconnect: Otty.Status.warn
        }
    }
}

// MARK: - The two-column Settings view

/// The Settings body: a flat two-column layout (otty fidelity) — a left navigator (search pill + icon+label
/// section rows) and the selected section's content on the right. The section set + order + icons are driven
/// from `SettingsSection` so the navigator can never drift from the pinned taxonomy.
struct SettingsView: View {
    @Bindable var store: PreferencesStore

    /// The selected section — also bound into ``SettingsSectionContent`` so the Advanced All-Settings list's
    /// ✎ jump buttons can repoint the navigator to the owning section (WI-3).
    @State private var selectedSection: SettingsSection = .general

    /// The SIDEBAR search pill query — narrows which SECTION ROWS show in the left navigator. This is a
    /// DISTINCT control from the Advanced → All-Settings content search (`AllSettingsListView`, which narrows
    /// the config-KEY list): otty shows both (the navigator pill top-left + the All-Settings field top-right),
    /// and so do we. A plain case-insensitive substring match over the section titles.
    @State private var sidebarQuery: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(width: Otty.Metric.hairline)
            content(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Otty.Surface.window)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Otty.Surface.window)
    }

    /// The left navigator: the search pill pinned at the top, then the (filtered) icon+label section rows.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space2) {
            SettingsSidebarSearchField(text: $sidebarQuery)
                .padding(.horizontal, Otty.Metric.space2)
                .padding(.top, Otty.Metric.space3)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredSections) { section in
                        SettingsSidebarRow(
                            section: section,
                            isSelected: section == selectedSection,
                            action: { selectedSection = section },
                        )
                    }
                }
                .padding(.horizontal, Otty.Metric.space2)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Otty.Metric.settingsSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Otty.Surface.sidebar)
    }

    /// The section rows the navigator shows — every section, or the title-substring matches when the pill has
    /// a query. Empty / whitespace query ⇒ all sections (taxonomy order preserved).
    private var filteredSections: [SettingsSection] {
        let needle = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { $0.title.lowercased().contains(needle) }
    }

    /// The body for a section — a thin dispatch onto the shared ``SettingsSectionContent`` (the SAME switch
    /// the iOS sheet renders, so the macOS navigator and the iOS list can never show different content).
    private func content(for section: SettingsSection) -> some View {
        SettingsSectionContent(section: section, store: store, selectedSection: $selectedSection)
    }
}

// MARK: - Sidebar navigator pieces (search pill + icon+label rows)

/// The rounded SEARCH PILL pinned at the top of the navigator (otty's top-left sidebar field). A leading
/// magnifying-glass + a plain `TextField` on the inset element surface, clipped to a `Capsule` with a
/// hairline border. Filters which section rows show; see `SettingsView.filteredSections`.
private struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.base))
                .foregroundStyle(Otty.Text.primary)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
        .background(Otty.Surface.element, in: Capsule())
        .overlay(Capsule().strokeBorder(Otty.Line.subtle, lineWidth: 1))
    }
}

/// One navigator row: a leading SF Symbol + the section title, with otty's idle/hover/selected styling (the
/// selected row is the signature elevated card; hover is a flat plate). Mirrors `OttySidebarRow` but binds a
/// `SettingsSection` (whose `systemImage` is a plain SF-Symbol String, not an `SFSymbol`).
private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space2) {
                Image(systemName: section.systemImage)
                    .font(.system(size: Otty.Metric.iconSize))
                    .foregroundStyle(isSelected ? Otty.Text.primary : Otty.Text.icon)
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(isSelected ? Otty.Text.primary : Otty.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Otty.Metric.space2)
            .padding(.vertical, Otty.Metric.space2)
            .background { rowBackground }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
        .animation(Otty.Anim.smallFade, value: isSelected)
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Otty.Metric.radiusTab, style: .continuous)
        if isSelected {
            shape
                .fill(Otty.Surface.selectedCard)
                .overlay(shape.strokeBorder(Otty.Line.card, lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        } else if hovering {
            shape.fill(Otty.State.hover)
        } else {
            Color.clear
        }
    }
}

// MARK: - Shared per-section content (one dispatch for the macOS navigator + the iOS sheet)

/// Resolves a ``SettingsSection`` to its per-section body. The ONE place the section → struct mapping lives,
/// so the macOS two-column navigator (`SettingsView`) and the iOS `SettingsSheet` (WI-5) render
/// byte-identical section content. The per-section structs stay `private` to this file; this `internal` view
/// is how the iOS sheet (a separate file) reaches them without widening their visibility. `selectedSection`
/// threads the shared navigator selection so the Advanced All-Settings ✎ jump can repoint the navigator to
/// the owning section (a no-op on the iOS list, where the jump is deferred — see WI-3).
struct SettingsSectionContent: View {
    let section: SettingsSection
    @Bindable var store: PreferencesStore
    @Binding var selectedSection: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralSettingsTab()
        case .shell: ShellSettingsTab()
        case .controls: ControlsSettingsTab(store: store)
        case .editor: EditorSettingsTab()
        case .agents: AgentsSettingsTab(store: store)
        case .appearance: AppearanceSettingsTab(store: store)
        case .recipes: RecipesSettingsTab()
        case .keybindings: KeybindingsSettingsTab(store: store)
        case .advanced: AdvancedSettingsTab(store: store, selectedSection: $selectedSection)
        }
    }
}

// MARK: - General section

/// General: On-Launch behaviour (O1), the tab/window close-confirmation policies (otty puts the Close
/// Confirmation group on the General page — `launch-option.png`), notifications (OSC 9/777 + long-command),
/// privacy (redact secrets), and the default pane kind. All fire-time `Defaults.Keys` (bound via
/// `@Default(.key)`) — applied LIVE.
private struct GeneralSettingsTab: View {
    /// The fire-time keys are NOT in the typed models, so bind the global `Defaults.Keys` directly through
    /// the type-safe `@Default(.key)` wrapper (the default lives in the key declaration, not here). General
    /// has no typed-model field, so it takes no `store` — all rows are fire-time `Defaults.Keys`.
    @Default(.onLaunch) private var onLaunch
    @Default(.closeConfirmTab) private var closeConfirmTab
    @Default(.closeConfirmWindow) private var closeConfirmWindow
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.redactSecrets) private var redactSecrets
    @Default(.defaultPaneKind) private var defaultPaneKind

    var body: some View {
        Form {
            Section("General") {
                Picker("On Launch", selection: $onLaunch) {
                    Text("Restore Last Session").tag(OnLaunchBehavior.restoreLastSession)
                    Text("New Window").tag(OnLaunchBehavior.newWindow)
                }
                timingFooter(.live)
            }

            Section("Close Confirmation") {
                Picker("Closing Tab", selection: $closeConfirmTab) { closeConfirmOptions }
                Picker("Closing Window", selection: $closeConfirmWindow) { closeConfirmOptions }
                timingFooter(.live)
            }

            Section("Notifications") {
                Toggle("Explicit notifications (OSC 9 / 777)", isOn: $oscNotifications)
                Toggle("Long-command completion", isOn: $longCommandNotifications)
                timingFooter(.live)
            }

            Section("Privacy & New Panes") {
                Toggle("Redact likely secrets from titles", isOn: $redactSecrets)
                Picker("Default pane kind", selection: $defaultPaneKind) {
                    Text("Terminal").tag(PaneKind.terminal)
                    Text("Remote GUI").tag(PaneKind.remoteGUI)
                }
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var closeConfirmOptions: some View {
        Text("Running Process").tag(CloseConfirmationPolicy.process)
        Text("Always").tag(CloseConfirmationPolicy.always)
        Text("Multiple Tabs").tag(CloseConfirmationPolicy.multipleTabs)
    }
}

// MARK: - Shell section

/// Shell: the otty window/tab/split working-directory policy and the new-tab insertion position. Each reads
/// a fire-time `Defaults.Key` consumed at the new-tab fire-site, so they apply LIVE (on the next ⌘T). The
/// close-confirmation policies live under **General** (otty's `launch-option.png`), not here.
private struct ShellSettingsTab: View {
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    @Default(.newTabPosition) private var newTabPosition

    /// The two policy choices the picker surfaces. A custom-path policy (set from the config / Advanced
    /// editor) is shown as `home` here; editing the path lands in WI-3's All-Settings raw editor.
    private enum WorkingDirChoice: String, CaseIterable, Identifiable {
        case inherit
        case home
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Working Directory") {
                Picker("New window", selection: workingDirBinding($workingDirNewWindow)) { workingDirOptions }
                Picker("New tab", selection: workingDirBinding($workingDirNewTab)) { workingDirOptions }
                Picker("New split", selection: workingDirBinding($workingDirNewSplit)) { workingDirOptions }
                timingFooter(.live)
            }

            Section("New Tab") {
                Picker("New tab position", selection: $newTabPosition) {
                    Text("Automatic").tag(NewTabPosition.auto)
                    Text("End").tag(NewTabPosition.end)
                    Text("After Current Tab").tag(NewTabPosition.afterCurrent)
                }
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var workingDirOptions: some View {
        Text("Same as Current").tag(WorkingDirChoice.inherit)
        Text("Home Directory").tag(WorkingDirChoice.home)
    }

    /// Bridge the `WorkingDirectoryPolicy.rawConfig` String key to the 2-way picker: `inherit` ↔ `inherit`,
    /// everything else (`home` / empty / a custom path) reads as `home` and writes the canonical rawConfig.
    private func workingDirBinding(_ raw: Binding<String>) -> Binding<WorkingDirChoice> {
        Binding(
            get: { WorkingDirectoryPolicy(rawConfig: raw.wrappedValue) == .inherit ? .inherit : .home },
            set: { raw.wrappedValue = ($0 == .inherit ? WorkingDirectoryPolicy.inherit : .home).rawConfig },
        )
    }
}

// MARK: - Controls section

/// Controls: the otty Controls/Scroll/Copy fire-time toggles (E8 owns the BEHAVIOUR; E7 surfaces + persists
/// them), the SCROLLBACK depth (otty's `Settings → Controls → Scroll` home — `spec/terminal-features__
/// scroll.md`, relocated out of the old Editor tab), and the system-dialog-panes toggle. All LIVE (the
/// toggles + scroll knobs are read at fire-time / next render; scrollback rebuilds the libghostty config).
/// NOTE: the cursor (style + blink) is NOT here — otty puts it under **Appearance** (`cursor-style.png`).
private struct ControlsSettingsTab: View {
    @Bindable var store: PreferencesStore

    @Default(.copyOnSelect) private var copyOnSelect
    @Default(.trimTrailingSpacesOnCopy) private var trimTrailingSpacesOnCopy
    @Default(.pasteProtection) private var pasteProtection
    @Default(.mouseHideWhileTyping) private var mouseHideWhileTyping
    @Default(.focusFollowsMouse) private var focusFollowsMouse
    @Default(.scrollOnOutput) private var scrollOnOutput
    @Default(.scrollMultiplier) private var scrollMultiplier
    @Default(.systemDialogPanes) private var systemDialogPanes

    var body: some View {
        Form {
            Section("Copy & Paste") {
                Toggle("Copy on select", isOn: $copyOnSelect)
                Toggle("Trim trailing spaces on copy", isOn: $trimTrailingSpacesOnCopy)
                Toggle("Paste protection", isOn: $pasteProtection)
                timingFooter(.live)
            }

            Section("Mouse & Scroll") {
                Toggle("Hide mouse while typing", isOn: $mouseHideWhileTyping)
                Toggle("Focus follows mouse", isOn: $focusFollowsMouse)
                Toggle("Scroll to bottom on output", isOn: $scrollOnOutput)
                LabeledContent("Scroll multiplier") {
                    HStack(spacing: Otty.Metric.space2) {
                        Slider(value: $scrollMultiplier, in: 0.25...5, step: 0.25)
                        Text(String(format: "%.2f×", scrollMultiplier))
                            .foregroundStyle(Otty.Text.secondary)
                            .monospacedDigit()
                    }
                }
                timingFooter(.live)
            }

            Section("Scrollback") {
                Stepper(
                    "Lines: \(store.terminal.scrollbackLines)",
                    value: $store.terminal.scrollbackLines, in: 1000...100_000, step: 1000,
                )
                timingFooter(.live)
            }

            Section("System") {
                Toggle("Auto-spawn panes for system password dialogs", isOn: $systemDialogPanes)
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor section (RESERVED — deferred)

/// Editor is RESERVED/empty by design. In otty the Editor section configures the built-in FILE-editor (Soft
/// Wrap / Show Line Numbers / Show Whitespace / Tab Size / Scroll Past Last Line / Default-to-Preview — see
/// `docs/otty-clone/screenshots/editor-settings.png`). aislopdesk has no built-in file editor, so there are
/// NO settings to surface here. Deliberately we do NOT backfill it with terminal-render prefs — those have
/// otty homes elsewhere (FONT + CURSOR → Appearance `font-setting.png`/`cursor-style.png`; SCROLLBACK →
/// Controls `spec/terminal-features__scroll.md`). The section is kept in the taxonomy (pinned by
/// `SettingsSectionTaxonomyTests`) as a placeholder so the navigator stays 1:1 with otty's; it fills in if/
/// when a file-pane editor lands (otty-clone backlog).
private struct EditorSettingsTab: View {
    var body: some View {
        Form {
            Section("Editor") {
                LabeledContent("File editor") {
                    Text("Not available")
                        .foregroundStyle(Otty.Text.tertiary)
                }
                Text(
                    "Editor settings (Soft Wrap, Line Numbers, Tab Size, …) configure a built-in file editor, "
                        + "which aislopdesk does not have yet. Terminal font, cursor, and scrollback live under "
                        + "Appearance and Controls.",
                )
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recipes section (RESERVED — deferred)

/// Recipes is RESERVED/empty by design — kept in the taxonomy so the navigator stays 1:1 with otty's
/// (`docs/otty-clone/screenshots/all-settings.png` shows a Recipes section, book glyph, between Appearance
/// and Key Bindings). In otty, Recipes is a saved-command / snippet library; aislopdesk has no equivalent
/// yet, so — exactly like the Editor placeholder — there are NO settings to surface here and we deliberately
/// do NOT backfill it. The section fills in if/when a recipe library lands (otty-clone backlog); it is pinned
/// by `SettingsSectionTaxonomyTests`.
private struct RecipesSettingsTab: View {
    var body: some View {
        Form {
            Section("Recipes") {
                LabeledContent("Recipe library") {
                    Text("Not available")
                        .foregroundStyle(Otty.Text.tertiary)
                }
                Text(
                    "Recipes are a saved-command library, which aislopdesk does not have yet. This section is "
                        + "reserved to stay 1:1 with otty's navigator.",
                )
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance section

/// Appearance: the otty theme picker (via `AppearancePreferences` → `ThemeStore`), the density tier, the
/// terminal FONT (family + size) and the CURSOR group (style + blink) — both relocated here from the old
/// Editor/Controls tabs to match otty's screenshots (`font-setting.png` shows Font Family under Appearance;
/// `cursor-style.png` shows the Cursor group under Appearance) — plus the chrome toggles (command dividers,
/// status bar). All LIVE (theme repoints every token; font/cursor rebuild the libghostty config string and
/// bump `TerminalConfigBroadcaster`; the chrome toggles are read on the next render).
private struct AppearanceSettingsTab: View {
    @Bindable var store: PreferencesStore

    @Default(.showBlockDividers) private var showBlockDividers
    @Default(.hideStatusBar) private var hideStatusBar

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: themeBinding) {
                    Text("System").tag(ThemeChoice.system)
                    Divider()
                    Text("Monokai Pro (Classic)").tag(ThemeChoice.monokaiProClassic)
                    Text("Monokai Pro Light").tag(ThemeChoice.monokaiProClassicLight)
                    Text("Monokai Pro Octagon").tag(ThemeChoice.monokaiProOctagon)
                    Text("Monokai Pro Machine").tag(ThemeChoice.monokaiProMachine)
                    Text("Monokai Pro Ristretto").tag(ThemeChoice.monokaiProRistretto)
                    Text("Monokai Pro Spectrum").tag(ThemeChoice.monokaiProSpectrum)
                    Divider()
                    Text("Paper (Light)").tag(ThemeChoice.paper)
                    Text("Dark").tag(ThemeChoice.dark)
                }
                LabeledContent("Density") {
                    Picker("Density", selection: densityBinding) {
                        Text("Comfortable").tag("comfortable")
                        Text("Compact").tag("compact")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            Section("Font") {
                TextField("Family", text: $store.terminal.fontFamily)
                Stepper(
                    "Size: \(Int(store.terminal.fontSize))",
                    value: $store.terminal.fontSize, in: 8...32, step: 1,
                )
            }

            Section("Cursor") {
                Picker("Style", selection: $store.terminal.cursorStyle) {
                    ForEach(TerminalPreferences.CursorStyle.allCases, id: \.self) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
                Toggle("Blink", isOn: $store.terminal.cursorBlink)
            }

            Section("Chrome") {
                Toggle("Show command dividers", isOn: $showBlockDividers)
                Toggle("Hide status bar", isOn: $hideStatusBar)
            }

            Section { timingFooter(.live) }
        }
        .formStyle(.grouped)
    }

    /// Bridge the picker (non-optional `ThemeChoice`) to the optional model field: unset (`nil`) reads as
    /// `.system`-equivalent default but writing always sets an explicit choice (so the user's pick persists).
    private var themeBinding: Binding<ThemeChoice> {
        Binding(
            get: { store.appearance.theme ?? .system },
            set: { store.appearance.theme = $0 },
        )
    }

    private var densityBinding: Binding<String> {
        Binding(
            get: { store.appearance.density ?? "comfortable" },
            set: { store.appearance.density = $0 },
        )
    }
}

// MARK: - Agents section

/// Agents: the host-side agent-detection flags (relocated from the old Video tab — read by the host daemon,
/// so they apply on reconnect) plus the layout-auto-switch and clipboard-history fire-time toggles (LIVE).
private struct AgentsSettingsTab: View {
    @Bindable var store: PreferencesStore

    @Default(.autoSwitchLayouts) private var autoSwitchLayouts
    @Default(.recordClipboardHistory) private var recordClipboardHistory

    var body: some View {
        Form {
            Section("Agent detection (host)") {
                optionalBoolToggle("Foreground-process watch", $store.agent.agentDetect)
                optionalBoolToggle("Claude Code hooks", $store.agent.agentHooks)
                timingFooter(.reconnect)
            }

            Section("Behaviour") {
                Toggle("Auto-switch layouts on trigger app", isOn: $autoSwitchLayouts)
                Toggle("Record clipboard history", isOn: $recordClipboardHistory)
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }

    private func optionalBoolToggle(_ title: String, _ binding: Binding<Bool?>) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil },
        )) { Text(title) }
    }
}

// MARK: - Keybindings section

private struct KeybindingsSettingsTab: View {
    @Bindable var store: PreferencesStore
    var body: some View {
        KeybindingsEditorView(store: store)
    }
}

// MARK: - Advanced section (raw overrides + folded-in Video host flags)

/// The power-user raw `AISLOPDESK_*` override box, folded LAST into the env overlay (so a typed raw key
/// beats the matching typed pref). A precedence note makes clear a REAL process env var still wins over the
/// whole overlay. The Video HOST flags (QP/FEC/pacer/sharpen) have no otty section, so they fold in here as
/// a "Video (host)" sub-section — real functionality, reconnect-tagged + symmetric-FEC-warned.
private struct AdvancedSettingsTab: View {
    @Bindable var store: PreferencesStore
    /// The shared navigator selection — threaded into the All-Settings list so a ✎ jump can repoint it.
    @Binding var selectedSection: SettingsSection

    #if os(macOS)
    /// Local edit buffer of `key = value` lines; committed into `store.rawOverrides` on change. macOS-only:
    /// the raw `AISLOPDESK_*` editor is a HOST-side concern, so the compact iOS sheet (WI-5) omits it.
    @State private var text: String = ""
    #endif

    var body: some View {
        Form {
            // The raw `AISLOPDESK_*` override editor + the Video HOST flags are macOS-host-relevant, so the
            // iOS settings sheet (WI-5) omits them; the cross-platform All-Settings list + Workspace transfer
            // below still reach iOS.
            #if os(macOS)
            Section("Raw overrides") {
                Text(
                    "One AISLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
                )
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                TextEditor(text: $text)
                    .font(.system(size: Otty.Typeface.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: text) { _, new in commit(new) }
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemName: "info.circle")
                    Text("A real environment variable set on the process still wins over any value here.")
                }
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
            }

            VideoHostSettingsView(store: store)
            #endif

            // E7 WI-4: portable workspace export / import (file picker over `WorkspaceTransferDocument`).
            // Reads the live `WorkspaceStore` from `\.workspaceStore` (injected at the Settings scene root on
            // macOS and onto the iOS sheet in WI-5; `nil` → the rows render disabled rather than crashing).
            WorkspaceTransferSettingsView()

            // The searchable All Settings list + Reset-All / Reset-Advanced (replaces the bare reset button).
            // Pure SwiftUI, so it is shown on the iOS sheet too. `onAfterReset` clears the local raw-overrides
            // buffer so the box reflects the cleared store (a no-op on iOS, where the buffer does not exist).
            AllSettingsListView(
                store: store, selectedSection: $selectedSection, onAfterReset: { clearRawOverridesBuffer() },
            )
        }
        .formStyle(.grouped)
        #if os(macOS)
            .onAppear { text = Self.render(store.rawOverrides) }
        #endif
    }

    /// Clear the local raw-overrides edit buffer after a reset. macOS-only buffer → a no-op on iOS.
    private func clearRawOverridesBuffer() {
        #if os(macOS)
        text = ""
        #endif
    }

    #if os(macOS)
    /// Parse the `key=value` lines and write them into `store.rawOverrides` (empty / malformed lines ignored).
    private func commit(_ raw: String) {
        var map: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        if map != store.rawOverrides { store.rawOverrides = map }
    }

    private static func render(_ map: [String: String]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
    #endif
}

// MARK: - Video (host) sub-section — folded into Advanced

/// The Video / FEC / pacer host flags, folded into Advanced (otty has no Video section). These are read by
/// the HOST daemon at launch and shipped via the `video-prefs.json` sidecar, so they are labelled "applies
/// on reconnect"; the SYMMETRIC FEC keys add a "set on both ends" warning. The client-side `sharpen` is the
/// one live field. Body returns a `Group` of `Section`s so the host `Form` (Advanced) renders them inline.
private struct VideoHostSettingsView: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Group {
            Section("Video · Quality (host)") {
                optionalIntStepper("Sharp QP", $store.video.qpSharp, range: 1...51, default: 26)
                optionalIntStepper("Coarse QP", $store.video.qpCoarse, range: 1...51, default: 40)
                timingFooter(.reconnect)
            }

            Section {
                optionalIntStepper("Parity (m)", $store.video.fecM, range: 1...8, default: 1)
                optionalIntStepper("Group size (k)", $store.video.fecK, range: 1...32, default: 8)
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("FEC must be set IDENTICALLY on both ends or the host and client disagree.")
                }
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Status.warn)
                timingFooter(.reconnect)
            } header: {
                Text("Video · Forward Error Correction (symmetric)")
            }

            Section("Video · Pacer (host)") {
                Picker("Mode", selection: pacerBinding) {
                    Text("Default (deadline)").tag(VideoPreferences.Pacer?.none)
                    Text("Deadline").tag(Optional(VideoPreferences.Pacer.deadline))
                    Text("On arrival").tag(Optional(VideoPreferences.Pacer.arrival))
                }
                timingFooter(.reconnect)
            }

            Section("Video · Client render") {
                optionalDoubleSlider("Sharpen", $store.video.sharpen, range: 0...2, default: 0)
                timingFooter(.live)
            }
        }
    }

    private var pacerBinding: Binding<VideoPreferences.Pacer?> {
        Binding(get: { store.video.pacer }, set: { store.video.pacer = $0 })
    }

    // MARK: Optional-field editors (nil = "unset / use compile-time default")

    /// An optional-Int stepper: a leading "Set" toggle gates the value (off ⇒ `nil` ⇒ unset, golden-safe).
    private func optionalIntStepper(
        _ title: String, _ binding: Binding<Int?>, range: ClosedRange<Int>, default def: Int,
    ) -> some View {
        HStack {
            Toggle(isOn: setBinding(binding, default: def)) { Text(title) }
                .toggleStyle(.switch)
            Spacer()
            if let value = binding.wrappedValue {
                Stepper("\(value)", value: nonOptional(binding, default: def), in: range)
                    .labelsHidden()
                Text("\(value)").foregroundStyle(Otty.Text.secondary)
            } else {
                Text("default").foregroundStyle(Otty.Text.tertiary)
                    .font(.system(size: Otty.Typeface.footnote))
            }
        }
    }

    private func optionalDoubleSlider(
        _ title: String, _ binding: Binding<Double?>, range: ClosedRange<Double>, default def: Double,
    ) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Toggle(isOn: setBinding(binding, default: def)) { Text(title) }
                .toggleStyle(.switch)
            if binding.wrappedValue != nil {
                Slider(value: nonOptional(binding, default: def), in: range)
            }
        }
    }

    /// A `Bool` binding that toggles an optional field between `nil` (unset) and a default value.
    private func setBinding<T>(_ binding: Binding<T?>, default def: T) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue != nil },
            set: { binding.wrappedValue = $0 ? def : nil },
        )
    }

    /// A non-optional projection of an optional binding (only used when the value is already non-nil; falls
    /// back to `def` defensively).
    private func nonOptional<T>(_ binding: Binding<T?>, default def: T) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue ?? def },
            set: { binding.wrappedValue = $0 },
        )
    }
}

// MARK: - Shared timing footer

/// A right-aligned timing chip used as a section footer so each section's apply timing is visible inline.
private func timingFooter(_ timing: ApplyTiming) -> some View {
    HStack {
        Spacer()
        TimingChip(timing: timing)
    }
}
#endif
