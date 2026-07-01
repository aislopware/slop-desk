// SettingsView — the SwiftUI Settings surface (REBUILD-V2, WS-D / D4; E7 9-section taxonomy).
//
// A two-column Settings window whose right column is a THIN `@Bindable` binding over the one live
// `@Observable` `PreferencesStore`. Each section edits a slice of the typed prefs models
// (`TerminalPreferences`, `VideoPreferences`, `AgentPreferences`, `AppearancePreferences`,
// `KeybindingPreferences`) or the fire-time `SettingsKey` toggles (bound via `@Default(.key)`), and the
// store's `didSet` apply-paths do the rest (terminal live-reload, env overlay + sidecar, theme repoint,
// keybinding republish).
//
// LAYOUT: Settings is a TWO-COLUMN window — a left NAVIGATOR column with a rounded SEARCH PILL pinned at the
// top and a vertical icon+label section list, and a content column on the right
// (`docs/ui-shell/screenshots/{all-settings,launch-option,editor-settings,cursor-style}.png`). This view
// reproduces that with a flat two-column `HStack` (NOT a macOS `TabView` top tab strip): a fixed-width
// `Slate.Surface.sidebar` navigator (`settingsSidebarWidth`) holding `SettingsSidebarSearchField` + the
// `SettingsSidebarRow` list, a hairline divider, and the selected section's `Form` on the right. The sidebar
// search pill (which SECTION ROWS show) is DISTINCT from the Advanced → All-Settings content search (which
// config KEYS show) — both searches are surfaced side by side.
//
// E7 reorg: the old 5-tab strip (General / Terminal / Video / Keybindings / Advanced) is reshaped into a
// 9-section taxonomy (`SettingsSection`): General / Shell / Controls / Editor / Agents / Appearance /
// Recipes / Key Bindings / Advanced. Groups relocate to the section proven by the screenshots: terminal
// FONT (family + size) + the CURSOR group (style + blink) → **Appearance** (`font-setting.png` /
// `cursor-style.png` both show them under Appearance); SCROLLBACK → **Controls** (`spec/terminal-features__
// scroll.md`: Settings → Controls → Scroll); theme → Appearance; agent host flags → Agents; the Close
// Confirmation pickers (Closing Tab / Closing Window) → **General** (`launch-option.png` shows them on the
// General page). The **Editor** section is reserved for the built-in FILE-editor's settings (Soft Wrap /
// Line Numbers / Tab Size — `editor-settings.png`) and **Recipes** is a saved-command library
// (`all-settings.png`), neither of which aislopdesk has an equivalent for, so both stay RESERVED/empty
// (deferral placeholders, kept 1:1 in the navigator, not terminal-render prefs). The 5 orphan toggles + the
// Controls/Scroll/Copy toggles are surfaced via `@Default(.key)`; the Video HOST flags (QP/FEC/pacer/sharpen)
// have no dedicated section, so they fold into Advanced as a "Video (host)" sub-section (real functionality
// — not dropped).
//
// SURFACING: the main window is `.hiddenTitleBar` and `OverlayCoordinator` is NOT yet mounted, so this
// rides a STOCK SwiftUI `Settings` scene (`AislopdeskSettingsScene`) — ⌘, opens a separate, system-chromed
// window that does not clash with the workspace's own hover-reveal titlebar. When the coordinator lands, the
// same view tree can be relocated into an in-window panel via `settingsVisible`. `SettingsView` itself stays
// cross-platform so the iOS settings sheet (WI-5) can host the same section structs.
//
// DEFERRED vs LIVE-APPLY: each section is tagged with an `ApplyTiming` chip (`.live` applies immediately;
// `.reconnect` is a HOST-read flag shipped via the sidecar that only takes effect on the next host
// connection). Terminal + appearance + keybindings + the fire-time toggles are live; the video/agent HOST
// flags are reconnect-only; SYMMETRIC keys (FEC) additionally carry a "set on both ends" warning.
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskCLICore
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import Defaults
import SFSafeSymbols
import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Settings scene (stock SwiftUI, ⌘,)

/// The stock `Settings` scene wrapper, wired in `AislopdeskClientApp`. Stock (not an in-window panel)
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
    /// E13 WI-2: the app-owned Agents install-hooks model, injected so the Agents card's Install/Uninstall/
    /// Status round-trips reach the host. Optional so a preview / future host can omit it (the card then
    /// renders the disabled "Connect a session" state).
    private let agentHooks: AgentHooksController?

    public init(
        store: PreferencesStore,
        workspaceStore: WorkspaceStore? = nil,
        agentHooks: AgentHooksController? = nil,
    ) {
        self.store = store
        self.workspaceStore = workspaceStore
        self.agentHooks = agentHooks
    }

    public var body: some Scene {
        Settings {
            SettingsView(store: store)
                .workspaceStore(workspaceStore)
                .agentHooksController(agentHooks)
                // Settings is native chrome → SYSTEM accent (not the theme accent) so its toggles / steppers /
                // radio rows read as native System-Settings controls; appearance still tracks the theme below.
                .tint(nil)
                .preferredColorScheme(Slate.colorScheme)
        }
    }
}
#endif

// MARK: - Settings taxonomy (the 9 sections — one source for the macOS navigator + the iOS list)

/// The settings taxonomy — 9 sections, each rendered as an icon+label row in the macOS two-column
/// navigator (and, once WI-5 lands, a navigation row in the iOS sheet). The title + sidebar
/// `systemImage` live here as the ONE source so the macOS navigator and the (future) iOS list never drift;
/// `SettingsSectionTaxonomyTests` pins
/// the set + order against an accidental drop/reorder/icon-swap. Order + glyphs mirror the sidebar shown in
/// (`docs/ui-shell/screenshots/all-settings.png`): General, Shell, Controls, Editor, Agents, Appearance,
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

    /// The sidebar glyph for the section (SF Symbol name), chosen to read clearly at a glance: General =
    /// `exclamationmark.circle`, Controls = `cursorarrow` (the pointer/cursor glyph shown beside "Controls"
    /// in `all-settings.png` — input/scroll/pointer settings), Agents = `powerplug`, Recipes = `book`, Key
    /// Bindings = `bolt` (lightning).
    var systemImage: String {
        switch self {
        case .general: "exclamationmark.circle"
        case .shell: "terminal"
        case .controls: "cursorarrow"
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

/// A small inline timing chip (symbol + label). The tint reads the `@MainActor` `Slate.Status` tokens in
/// the view body (not on the nonisolated enum).
private struct TimingChip: View {
    let timing: ApplyTiming
    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemName: timing.symbol)
            Text(timing.label)
        }
        .font(.system(size: Slate.Typeface.small))
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch timing {
        case .live: Slate.Status.ok
        case .reconnect: Slate.Status.warn
        }
    }
}

// MARK: - The two-column Settings view

/// The Settings body: a flat two-column layout — a left navigator (search pill + icon+label
/// section rows) and the selected section's content on the right. The section set + order + icons are driven
/// from `SettingsSection` so the navigator can never drift from the pinned taxonomy.
struct SettingsView: View {
    @Bindable var store: PreferencesStore

    /// The selected section — also bound into ``SettingsSectionContent`` so the Advanced All-Settings list's
    /// ✎ jump buttons can repoint the navigator to the owning section (WI-3).
    @State private var selectedSection: SettingsSection = .general

    /// The SIDEBAR search pill query — narrows which SECTION ROWS show in the left navigator. This is a
    /// DISTINCT control from the Advanced → All-Settings content search (`AllSettingsListView`, which narrows
    /// the config-KEY list): both are shown at once (the navigator pill top-left + the All-Settings field
    /// top-right). A plain case-insensitive substring match over the section titles.
    @State private var sidebarQuery: String = ""

    var body: some View {
        // NATIVE macOS settings chrome (issue 1: "settings layout/component đang không native"): a native
        // `NavigationSplitView` with a system `List(selection:)` sidebar + native `.searchable`, and the
        // already-native `Form`-based section content as the detail — instead of the bespoke two-column
        // `HStack` + custom `SettingsSidebarRow` buttons. The window appearance is pinned to the active theme
        // (light/dark) so the native controls render consistently with the workspace (the scene also applies
        // `.preferredColorScheme(Slate.colorScheme)`).
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(filteredSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(
                min: 200, ideal: Slate.Metric.settingsSidebarWidth, max: 320,
            )
            .searchable(text: $sidebarQuery, placement: .sidebar, prompt: "Search")
            // A Settings window has a FIXED navigator (like macOS System Settings) — drop the toolbar
            // sidebar-collapse button macOS auto-adds for every NavigationSplitView. Collapsing the settings
            // sidebar leaves no way to switch sections; removing the toggle keeps the navigator always present.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 480)
        #if os(macOS)
            // Pin the Settings NSWindow to the theme appearance (macOS only — iOS has no NSWindow; its settings
            // surface is the separate `SettingsSheet`, which adopts `.preferredColorScheme` directly).
            .background { SettingsWindowAppearancePinner(isLight: Slate.theme.isLight) }
        #endif
    }

    /// Bridges the non-optional ``selectedSection`` to the optional selection a `List` single-selection binding
    /// needs (a `nil` set — e.g. a sidebar deselect — is ignored, keeping a section always shown in the detail).
    private var selectionBinding: Binding<SettingsSection?> {
        Binding(get: { selectedSection }, set: { if let new = $0 { selectedSection = new } })
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

// MARK: - Settings window appearance pin

#if os(macOS)
/// Pins the Settings `NSWindow`'s appearance to the active Slate theme (light/dark), so the native settings
/// chrome + any AppKit-hosted control renders consistently with the workspace — not the OS default. `isLight`
/// is passed IN (read from `Slate.theme.isLight` in `SettingsView.body`), so a LIVE theme switch re-renders the
/// view → re-runs `updateNSView` → re-pins, with NO `NotificationCenter` observer to leak. The scene's
/// `.preferredColorScheme(Slate.colorScheme)` covers the pure-SwiftUI side; this covers the window itself.
private struct SettingsWindowAppearancePinner: NSViewRepresentable {
    let isLight: Bool
    func makeNSView(context _: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.window?.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
    }
}
#endif

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

/// The General-page SECTION group headers, in render order, as a PURE source list so the body never drifts
/// from a headless taxonomy pin (`GeneralSectionLayoutTests`). The macOS slice appends **OS Integration** —
/// the E20 M1 home for Default Terminal / Finder Integration / Full Disk Access, mirroring the governing
/// screenshot `first-launch-default-terminal.png` and `spec/getting-started__first-launch.md §2` (Settings →
/// General → OS Integration). iOS OMITS the group: the LaunchServices registration + System-Settings
/// deep-links are `#if os(macOS)` (`DefaultTerminalIntegration`), so there is no iOS handler to surface.
enum GeneralSettingsLayout {
    static let general = "General"
    static let closeConfirmation = "Close Confirmation"
    static let privacyAndNewPanes = "Privacy & New Panes"
    #if os(macOS)
    static let osIntegration = "OS Integration"
    #endif

    /// The section headers the General page renders, in order. Drives the `Section(_:)` headers below so the
    /// pure list and the rendered Form stay in lockstep.
    static var sectionTitles: [String] {
        var titles = [general, closeConfirmation, privacyAndNewPanes]
        #if os(macOS)
        titles.append(osIntegration)
        #endif
        return titles
    }
}

/// General: On-Launch behaviour (O1), the tab/window close-confirmation policies (the Close Confirmation
/// group lives on the General page — `launch-option.png`), privacy (redact secrets), and the default
/// pane kind. All fire-time `Defaults.Keys` (bound via `@Default(.key)`) — applied LIVE. NOTE: the
/// NOTIFICATION group is NOT here — it lives under **Shell** instead (`notification-setting.png` shows the
/// NOTIFICATION + TAB BADGE groups on the Shell page), so it lives in `ShellSettingsTab`.
///
/// INTENTIONAL OMISSIONS (pinned, not a regression): a General page could plausibly carry an UPDATE group
/// (Auto Update), a Language picker, and a "Quit When All Windows Closed" row. aislopdesk drops
/// all three on purpose — Auto-Update and Language are N/A for a single-user remote-coding tool that is not a
/// self-updating, localized consumer app (no in-app updater, English-only UI), and the quit-policy row has no
/// backing behaviour here. Conversely, the **Privacy & New Panes** group (Redact secrets / Default pane kind)
/// is aislopdesk-SPECIFIC — deliberately added, not a stray.
private struct GeneralSettingsTab: View {
    /// The fire-time keys are NOT in the typed models, so bind the global `Defaults.Keys` directly through
    /// the type-safe `@Default(.key)` wrapper (the default lives in the key declaration, not here). General
    /// has no typed-model field, so it takes no `store` — all rows are fire-time `Defaults.Keys`.
    @Default(.onLaunch) private var onLaunch
    @Default(.closeConfirmTab) private var closeConfirmTab
    @Default(.closeConfirmWindow) private var closeConfirmWindow
    @Default(.redactSecrets) private var redactSecrets
    @Default(.defaultPaneKind) private var defaultPaneKind
    // E20 M1 (ES-E20-4): the OS Integration group's "Default Terminal" status, refreshed on appear + after the
    // Set action. macOS-only — `DefaultTerminalIntegration` is `#if os(macOS)` (LaunchServices + System
    // Settings deep-links have no iOS equivalent), so iOS omits the whole group.
    #if os(macOS)
    @State private var isDefaultTerminal = false
    #endif

    var body: some View {
        Form {
            slateFormSection(GeneralSettingsLayout.general) {
                Picker("On Launch", selection: $onLaunch) {
                    Text("Restore Last Session").tag(OnLaunchBehavior.restoreLastSession)
                    Text("New Window").tag(OnLaunchBehavior.newWindow)
                }
                timingFooter(.live)
            }

            slateFormSection(GeneralSettingsLayout.closeConfirmation) {
                Picker("Closing Tab", selection: $closeConfirmTab) { closeConfirmOptions }
                Picker("Closing Window", selection: $closeConfirmWindow) { closeConfirmOptions }
                timingFooter(.live)
            }

            slateFormSection(GeneralSettingsLayout.privacyAndNewPanes) {
                Toggle("Redact likely secrets from titles", isOn: $redactSecrets)
                Picker("Default pane kind", selection: $defaultPaneKind) {
                    Text("Terminal").tag(PaneKind.terminal)
                    Text("Remote GUI").tag(PaneKind.remoteGUI)
                }
                timingFooter(.live)
            }

            // OS Integration (E20 M1) — macOS-only. Reuses the SAME `DefaultTerminalIntegration` actions the
            // first-launch sheet builds, so the buttons stay REACHABLE after "Skip Setup" / first launch (the
            // bug this fixes). iOS omits the group (no LaunchServices / System-Settings handler).
            #if os(macOS)
            osIntegrationSection
            #endif
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var closeConfirmOptions: some View {
        Text("Running Process").tag(CloseConfirmationPolicy.process)
        Text("Always").tag(CloseConfirmationPolicy.always)
        Text("Multiple Tabs").tag(CloseConfirmationPolicy.multipleTabs)
    }

    // MARK: - OS Integration (E20 M1 — macOS-only, reachable post-first-launch)

    /// Settings → General → OS Integration (`first-launch-default-terminal.png` /
    /// `getting-started__first-launch.md §2`). REUSES the first-launch sheet's rows so the behaviour lives in
    /// one place (`DefaultTerminalIntegration`): a Default-Terminal status row (Set / "Default"), the
    /// Finder-Integration + Full-Disk-Access System-Settings deep-links, and the honestly-DISABLED "Default
    /// Terminal for Common Apps" row (a remote-host editor's config can't be rewritten from the client — E20
    /// exclusion §4 / no dead button). macOS-only; iOS never compiles this.
    #if os(macOS)
    private var osIntegrationSection: some View {
        slateFormSection(GeneralSettingsLayout.osIntegration) {
            osIntegrationRow(
                "Default Terminal",
                "Handle `ssh://` links and shell scripts opened from Finder or `open`.",
            ) {
                if isDefaultTerminal {
                    Label("Default", systemImage: "checkmark").foregroundStyle(Slate.Status.ok)
                } else {
                    Button("Set as Default Terminal") {
                        Task {
                            await DefaultTerminalIntegration.setAsDefaultTerminal()
                            isDefaultTerminal = DefaultTerminalIntegration.isDefaultTerminal()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            osIntegrationRow(
                "Default Terminal for Common Apps",
                "Editors and git GUIs hardcode Terminal.app. Rewriting their config only works for a LOCAL "
                    + "editor — an editor on the remote host needs a host-side agent, so this is unavailable "
                    + "in the remote model.",
            ) {
                Text("Unavailable").foregroundStyle(Slate.Text.tertiary)
            }
            osIntegrationRow(
                "Finder Integration",
                "Add \u{201C}Open in Aislopdesk\u{201D} to Finder's right-click Services menu for folders.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFinderServicesSettings() }
                    .buttonStyle(.bordered)
            }
            osIntegrationRow(
                "Full Disk Access",
                "Needed when commands run inside Aislopdesk must read or write protected files. The app works "
                    + "without it.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFullDiskAccessSettings() }
                    .buttonStyle(.bordered)
            }
            timingFooter(.live)
        }
        .onAppear { isDefaultTerminal = DefaultTerminalIntegration.isDefaultTerminal() }
    }

    /// The OS-integration row layout: a bold title + gray subtext leading, the action control trailing.
    private func osIntegrationRow(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder trailing: () -> some View,
    ) -> some View {
        LabeledContent {
            trailing()
        } label: {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(title)
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}

// MARK: - Shell section

/// Shell: the full NOTIFICATION group + the SOUND + CODE AGENT groups (E14/K9-K11) and the
/// window/tab/split working-directory policy. `notification-setting.png` (Shell row highlighted) homes the
/// NOTIFICATION group under the Shell section, so the toggles live here (NOT on General): the System
/// Permission status row at the top, the master "Allow App Notifications", the per-event toggles, the
/// Notify-While-Foreground tri-state picker, and the macOS-only Bounce Dock Icon — all backed by the pure
/// `NotificationPolicy` engine (WI-4). The Working Directory group is also Shell's, per
/// `spec/user-interface__window-tab-split.md` lines 66 + 282: "Settings → Shell → Working Directory",
/// `open-option.png`). NOT here: the New Tab Position picker → **Appearance** (`tab-setting.png` shows it in a
/// TABS group on the Appearance page); the close-confirmation policies → **General** (`launch-option.png`);
/// the title + OSC-52 privilege gates → **Advanced** (`terminal-features__notifications.md`). Each reads a
/// fire-time `Defaults.Key` consumed at the new-tab / notification fire-site, so they apply LIVE.
private struct ShellSettingsTab: View {
    // NOTIFICATION group (notification-setting.png). The full panel — the master + per-event toggles +
    // the Notify-While-Foreground tri-state picker — is now backed by the pure `NotificationPolicy` engine
    // (E14/K9, WI-4), so the rows are real behaviour, not deferred stubs.
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.notifyOnFinish) private var notifyOnFinish
    @Default(.notifyOnError) private var notifyOnError
    @Default(.notifyOnWatchFinish) private var notifyOnWatchFinish
    @Default(.notifyWhileForeground) private var notifyWhileForeground
    #if os(macOS)
    @Default(.bounceDockIcon) private var bounceDockIcon
    #endif
    // TAB BADGE group (Shell — progress-state.md "TAB BADGE" section, notification-setting.png). The three
    // COMMAND-driven badge toggles, DISTINCT from the Agents-tab "Agent Behaviour" badge gates.
    @Default(.tabBadgeOnCommandFinish) private var tabBadgeOnCommandFinish
    @Default(.tabBadgeOnCommandFail) private var tabBadgeOnCommandFail
    @Default(.tabBadgeOnCommandAwaitInput) private var tabBadgeOnCommandAwaitInput
    // SOUND group (Shell). BEL → NSSound.beep() gate + error-exit beep (E14/K10).
    @Default(.soundShellControlled) private var soundShellControlled
    @Default(.soundOnErrorExit) private var soundOnErrorExit
    // CODE AGENT group (Claude-only — E14 scope exclusion). IPC-driven, no shell integration needed.
    @Default(.agentNotifyTaskComplete) private var agentNotifyTaskComplete
    @Default(.agentNotifyAwaitInput) private var agentNotifyAwaitInput
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    // E20 WI-9: the "Aislopdesk CLI" card (Install CLI / Omit Prefix / Allow Overwrite). macOS-only — the
    // `/usr/local/bin` symlink + admin escalation are `#if os(macOS)`; iOS omits the section (no dead toggle).
    #if os(macOS)
    @State private var cliInstaller = CLIInstaller()
    #endif

    /// The two policy choices the picker surfaces. A custom-path policy (set from the config / Advanced
    /// editor) is shown as `home` here; editing the path lands in WI-3's All-Settings raw editor.
    private enum WorkingDirChoice: String, CaseIterable, Identifiable {
        case inherit
        case home
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            notificationSection
            tabBadgeSection
            soundSection
            codeAgentSection

            // Working Directory's Shell home is confirmed by the spec docs (NOT unconfirmed-by-screenshot):
            // `spec/user-interface__window-tab-split.md` ("Settings → Shell → Working Directory" + the
            // `open-option.png` reference) places this group on the Shell page.
            slateFormSection("Working Directory") {
                Picker("New window", selection: workingDirBinding($workingDirNewWindow)) { workingDirOptions }
                Picker("New tab", selection: workingDirBinding($workingDirNewTab)) { workingDirOptions }
                Picker("New split", selection: workingDirBinding($workingDirNewSplit)) { workingDirOptions }
                timingFooter(.live)
            }

            // AISLOPDESK CLI (E20 WI-9 — Settings → Shell → CLI card). macOS-only: the `/usr/local/bin`
            // symlink + admin escalation are `#if os(macOS)`, so iOS omits the section rather than ship a dead
            // toggle. Shares `CLIInstallCardBody` with the first-launch Install-CLI step (one source).
            #if os(macOS)
            slateFormSection("Aislopdesk CLI") {
                CLIInstallCardBody(installer: cliInstaller)
                timingFooter(.live)
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
            .onAppear { cliInstaller.refreshInstalled() }
        #endif
    }

    /// The full NOTIFICATION group (notification-setting.png): the System Permission status row at the
    /// TOP, then the master "Allow App Notifications" + the per-event toggles + the Notify-While-Foreground
    /// tri-state picker + Bounce Dock Icon (macOS-only — no Dock on iOS). Extracted so the `Form` closure
    /// stays under the `closure_body_length` ceiling.
    private var notificationSection: some View {
        slateFormSection("Notification") {
            NotificationPermissionRow()
            toggleRow(
                "Allow App Notifications",
                "Allow shell apps to send system notifications (OSC 9 / 777 / 99).",
                isOn: $oscNotifications,
            )
            toggleRow(
                "Notify on Command Finish",
                "Notify when a background command finishes (exit 0).",
                isOn: $notifyOnFinish,
            )
            toggleRow(
                "Notify on Error Exit",
                "Notify when a command fails (exits non-zero).",
                isOn: $notifyOnError,
            )
            toggleRow(
                "Notify on Watch Finish",
                "Notify when an `aislopdesk watch`-wrapped command finishes.",
                isOn: $notifyOnWatchFinish,
            )
            LabeledContent {
                Picker("", selection: $notifyWhileForeground) {
                    ForEach(NotifyWhileForeground.allCases, id: \.self) { policy in
                        Text(policy.displayLabel).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } label: {
                rowLabel("Notify While Foreground", "Banner behavior while aislopdesk is the foreground app.")
            }
            toggleRow(
                "Long-Command Completion",
                "Also notify when a slow command finishes in an unfocused pane.",
                isOn: $longCommandNotifications,
            )
            #if os(macOS)
            toggleRow(
                "Bounce Dock Icon",
                "Bounce the Dock icon when a notification arrives and aislopdesk isn't focused.",
                isOn: $bounceDockIcon,
            )
            #endif
            timingFooter(.live)
        }
    }

    /// The TAB BADGE group (Shell — progress-state.md lines 32-35, rendered directly under NOTIFICATION in
    /// notification-setting.png): the three COMMAND-driven sidebar-badge toggles. DISTINCT from the Agents-tab
    /// "Agent Behaviour" badge gates, so command vs agent badges are controlled independently. "When Command
    /// Awaits Input" gates a plain-command awaiting-input hand; the host detector that DRIVES that badge is a
    /// deferred ceiling (DECISIONS.md), so the toggle ships ahead of the signal it will gate.
    private var tabBadgeSection: some View {
        slateFormSection("Tab Badge") {
            toggleRow(
                "When Command Finishes",
                "Badge the tab when a command exits successfully.",
                isOn: $tabBadgeOnCommandFinish,
            )
            toggleRow(
                "When Command Fails",
                "Badge the tab when a command exits non-zero.",
                isOn: $tabBadgeOnCommandFail,
            )
            toggleRow(
                "When Command Awaits Input",
                "Badge the tab when a command stops at an interactive prompt.",
                isOn: $tabBadgeOnCommandAwaitInput,
            )
            timingFooter(.live)
        }
    }

    /// The SOUND group (Shell): the BEL → system-beep gate + the error-exit beep (E14/K10).
    private var soundSection: some View {
        slateFormSection("Sound") {
            toggleRow(
                "Sound — Shell Controlled",
                "Let shell apps ring the terminal bell (BEL) as the system alert sound.",
                isOn: $soundShellControlled,
            )
            toggleRow(
                "Sound on Error Exit",
                "Beep when a command exits non-zero (requires shell integration).",
                isOn: $soundOnErrorExit,
            )
            timingFooter(.live)
        }
    }

    /// The CODE AGENT group (Claude-only — E14 scope exclusion). IPC-driven, no shell integration needed.
    private var codeAgentSection: some View {
        slateFormSection("Code Agent") {
            toggleRow(
                "Notify When Task Completes",
                "Notify when a coding agent finishes a task and goes idle.",
                isOn: $agentNotifyTaskComplete,
            )
            toggleRow(
                "Notify When Awaiting Input",
                "Notify when a coding agent needs approval or input.",
                isOn: $agentNotifyAwaitInput,
            )
            timingFooter(.live)
        }
    }

    /// A toggle row with a bold-label-over-gray-subtext layout (the switch trailing).
    private func toggleRow(_ title: String, _ subtitle: String? = nil, isOn binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { rowLabel(title, subtitle) }
    }

    /// The row label layout: a bold title with an optional gray subtext beneath.
    private func rowLabel(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

// MARK: - System Permission status row (top of the Notification group)

/// The System Permission status row (`terminal-features__notifications.md`, shown at the TOP of the
/// Notification group): a coloured dot (green = allowed, amber = will-prompt / unknown, red = blocked) plus
/// an **Open System Settings** deep-link. The dot DECISION is the pure, headless-pinned
/// ``PermissionStatus/dot(forAuthorization:)``; this view only queries
/// `UNUserNotificationCenter.current().getNotificationSettings` and renders the result.
///
/// **iOS caveat (carryover / spec flag):** macOS deep-links to the Notifications preference pane
/// (`x-apple.systempreferences:com.apple.preference.notifications`); iOS CANNOT deep-link to the per-app OS
/// notification pane, so the button opens the app's OWN settings via `UIApplication.openSettingsURLString` —
/// the macOS deep-link is `#if os(macOS)` and the iOS fallback `#if os(iOS)`. See docs/DECISIONS.md E14 WI-7.
private struct NotificationPermissionRow: View {
    /// The current dot — starts amber (unknown) until the async query resolves, never a false green.
    @State private var dot: PermissionStatus.Dot = .amber

    var body: some View {
        LabeledContent {
            Button("Open System Settings", action: openSystemSettings)
                .controlSize(.small)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text("System Permission")
                    Text(dotSubtitle)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
    }

    private var dotColor: Color {
        switch dot {
        case .green: Slate.Status.ok
        case .amber: Slate.Status.warn
        case .red: Slate.Status.err
        }
    }

    private var dotSubtitle: String {
        switch dot {
        case .green: "Notifications are allowed for aislopdesk."
        case .amber: "Notification permission has not been granted yet."
        case .red: "Notifications are blocked — enable them in System Settings."
        }
    }

    /// Query `UNUserNotificationCenter` and map the authorization status through the pure dot decision. Never
    /// instantiated in a test (the pure mapping is what `PermissionStatusTests` pins) — `current()` traps
    /// without a bundle, the same hang/crash-safety boundary as the video sessions. The `rawValue` Int is
    /// extracted INSIDE the `await` expression so the non-`Sendable` `UNNotificationSettings` object never
    /// crosses the actor hop (only the `Int` does — Swift 6 region isolation).
    private func refresh() async {
        let raw = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue
        dot = PermissionStatus.dot(forAuthorization: raw)
    }

    private func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #elseif os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

// MARK: - Controls section

/// Controls: the Controls fire-time toggles + multi-state pickers (E8 owns the BEHAVIOUR; E7 declared +
/// persisted them). The groups mirror the section headers from the `spec/terminal-features__
/// {selection,copy-and-paste,scroll,cursor-and-mouse}.md` pages and `mouse-option.png`: **Selection**,
/// **Copy & Paste**, **Scroll** (incl. the SCROLLBACK depth — the `Settings → Controls → Scroll` home),
/// **Mouse**, **Keyboard** (Undo at Prompt), and the aislopdesk-specific **System** dialog-panes toggle.
/// All LIVE — every `Defaults` control row re-applies the libghostty config through `refreshTerminalControls()`
/// on change (the `refreshing(_:)` wrapper), and the scrollback stepper rebuilds via the `terminal` model's
/// own `didSet`. NOTE: the cursor (color / opacity / style / blink / animation) is NOT here — the
/// whole Cursor group lives under **Appearance** (`cursor-style.png`), hosted by `CursorPreviewView`.
private struct ControlsSettingsTab: View {
    @Bindable var store: PreferencesStore

    // Selection (Settings → Controls → Selection).
    @Default(.shiftArrowSelect) private var shiftArrowSelect
    @Default(.clearSelectionOnTyping) private var clearSelectionOnTyping
    @Default(.clearSelectionOnCopy) private var clearSelectionOnCopy
    @Default(.backspaceDeletesSelection) private var backspaceDeletesSelection
    // Copy & Paste.
    @Default(.copyOnSelect) private var copyOnSelect
    @Default(.trimTrailingSpacesOnCopy) private var trimTrailingSpacesOnCopy
    @Default(.pasteProtection) private var pasteProtection
    @Default(.pasteBracketedSafe) private var pasteBracketedSafe
    // Scroll.
    @Default(.scrollOnOutput) private var scrollOnOutput
    @Default(.scrollPastLastLine) private var scrollPastLastLine
    @Default(.scrollPastFirstLine) private var scrollPastFirstLine
    @Default(.smoothScroll) private var smoothScroll
    @Default(.scrollMultiplier) private var scrollMultiplier
    // Mouse (`mouse-option.png` order).
    @Default(.focusFollowsMouse) private var focusFollowsMouse
    @Default(.rightClickAction) private var rightClickAction
    @Default(.mouseHideWhileTyping) private var mouseHideWhileTyping
    @Default(.allowShiftClick) private var allowShiftClick
    @Default(.clickToMove) private var clickToMove
    @Default(.allowMouseCapture) private var allowMouseCapture
    // Keyboard / System.
    @Default(.undoAtPrompt) private var undoAtPrompt
    @Default(.optionAsAlt) private var optionAsAlt
    @Default(.systemDialogPanes) private var systemDialogPanes
    // Links (Settings → Controls → Open With / Link Schemes, E10 WI-3). Client-side link interaction —
    // NOT libghostty config, so these bind DIRECTLY (no `refreshing(_:)` terminal-config rebuild).
    @Default(.linkDetection) private var linkDetection
    @Default(.linkCmdClick) private var linkCmdClick
    @Default(.linkCmdShiftClick) private var linkCmdShiftClick
    @Default(.autoDetectLinkSchemes) private var autoDetectLinkSchemes
    @Default(.customLinkSchemes) private var customLinkSchemes
    // Secure Input (E17 ES-E17-4 / WI-7) — macOS-only (the iOS sheet hides the section). The keys still
    // compile + round-trip on iOS; only the UI is gated.
    #if os(macOS)
    @Default(.autoSecureInput) private var autoSecureInput
    @Default(.secureInputIndicator) private var secureInputIndicator
    #endif

    var body: some View {
        Form {
            slateFormSection("Selection") {
                toggleRow(
                    "Shift+Arrow Select",
                    "Use Shift+arrows to drive a native selection instead of forwarding the arrow escapes.",
                    isOn: $shiftArrowSelect,
                )
                toggleRow(
                    "Clear Selection on Typing",
                    "Drop the selection the moment any key is sent to the program.",
                    isOn: $clearSelectionOnTyping,
                )
                toggleRow(
                    "Clear Selection on Copy",
                    "Drop the highlight after an explicit copy (does not apply when Copy on Select fires).",
                    isOn: $clearSelectionOnCopy,
                )
                toggleRow(
                    "Backspace Deletes Selection",
                    "Not yet functional — the terminal renderer exposes no selection-geometry API, so "
                        + "Backspace deletes a single character whether this is on or off. Off by default.",
                    isOn: $backspaceDeletesSelection,
                )
                timingFooter(.live)
            }

            slateFormSection("Copy & Paste") {
                toggleRow(
                    "Copy on Select",
                    "Copy the selection to the pasteboard as soon as it is made.",
                    isOn: $copyOnSelect,
                )
                toggleRow(
                    "Trim Trailing Spaces on Copy",
                    "Strip trailing whitespace from each copied line.",
                    isOn: $trimTrailingSpacesOnCopy,
                )
                toggleRow(
                    "Paste Protection",
                    "Warn before pasting multi-line, trailing-newline, sudo/su, or control-character text.",
                    isOn: $pasteProtection,
                )
                toggleRow(
                    "Paste Bracketed Safe",
                    "Skip the paste warning when the receiving program advertises bracketed-paste support.",
                    isOn: $pasteBracketedSafe,
                )
                timingFooter(.live)
            }

            scrollSection

            mouseSection

            openWithSection

            linkSchemesSection

            slateFormSection("Keyboard") {
                toggleRow(
                    "Undo at Prompt",
                    "Press Cmd-Z at the shell prompt to emit the readline undo sequence.",
                    isOn: $undoAtPrompt,
                )
                pickerRow(
                    "Option as Alt",
                    "Treat the macOS Option key as Alt/Meta so terminal apps see Esc-prefixed sequences "
                        + "(Emacs, Vim word-jumps, readline). Off keeps Option free for accented characters.",
                    selection: $optionAsAlt,
                ) {
                    Text("Off").tag(OptionAsAlt.off)
                    Text("Both Option Keys").tag(OptionAsAlt.both)
                    Text("Left Option Only").tag(OptionAsAlt.left)
                    Text("Right Option Only").tag(OptionAsAlt.right)
                }
                timingFooter(.live)
            }

            // Secure Input (E17 ES-E17-4 / WI-7) — macOS-only (process-global `EnableSecureEventInput`). The
            // whole Section is `#if os(macOS)`, so the iOS sheet hides it; the `SettingsKey` keys still compile.
            #if os(macOS)
            slateFormSection("Secure Input") {
                toggleRow(
                    "Auto Secure Input",
                    "Automatically engage macOS Secure Keyboard Entry when the remote shell shows a hidden "
                        + "password prompt (sudo, ssh, read -s), so no other app can read your keystrokes.",
                    isOn: $autoSecureInput,
                )
                toggleRow(
                    "Show Secure Input Indicator",
                    "Show the SECURE INPUT pill in the pane while secure keyboard entry is active.",
                    isOn: $secureInputIndicator,
                )
                timingFooter(.live)
            }
            #endif

            slateFormSection("System") {
                Toggle("Auto-spawn panes for system password dialogs", isOn: $systemDialogPanes)
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }

    /// Settings → Controls → Scroll. Extracted from `body` so the `Form` closure stays under the
    /// `closure_body_length` ceiling; the rows are unchanged.
    private var scrollSection: some View {
        slateFormSection("Scroll") {
            toggleRow(
                "Scroll to Bottom on Output",
                "Snap the viewport to the bottom when new output arrives.",
                isOn: $scrollOnOutput,
            )
            pickerRow(
                "Scroll Past Last Line",
                "Overscroll mode past the last content row. Preference saved; the overscroll rendering "
                    + "is not yet active (the terminal renderer owns the viewport — deferred).",
                selection: $scrollPastLastLine,
            ) {
                Text("Disabled").tag(ScrollPastLast.disabled)
                Text("Last Line With Content").tag(ScrollPastLast.lastLineWithContent)
                Text("Last Line In Middle").tag(ScrollPastLast.lastLineInMiddle)
                Text("Cursor Line").tag(ScrollPastLast.cursorLine)
            }
            pickerRow(
                "Scroll Past First Line",
                "Overscroll mode past the first (oldest) scrollback row. Preference saved; the overscroll "
                    + "rendering is not yet active (deferred — same renderer ceiling as Scroll Past Last).",
                selection: $scrollPastFirstLine,
            ) {
                Text("Disabled").tag(ScrollPastFirst.disabled)
                Text("Same as Last Line").tag(ScrollPastFirst.sameAsLast)
                Text("First Line With Content").tag(ScrollPastFirst.firstLineWithContent)
                Text("First Line In Middle").tag(ScrollPastFirst.firstLineInMiddle)
            }
            toggleRow(
                "Smooth Scroll",
                "Scrolling already runs at pixel granularity. The whole-row snap when this is off is not "
                    + "yet active (the renderer exposes no row-snap hook — deferred).",
                isOn: $smoothScroll,
            )
            LabeledContent("Scroll multiplier") {
                HStack(spacing: Slate.Metric.space2) {
                    Slider(value: refreshing($scrollMultiplier), in: 0.25...5, step: 0.25)
                    Text(String(format: "%.2f×", scrollMultiplier))
                        .foregroundStyle(Slate.Text.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(
                "Scrollback: \(store.terminal.scrollbackLines) lines",
                value: $store.terminal.scrollbackLines, in: 1000...100_000, step: 1000,
            )
            timingFooter(.live)
        }
    }

    /// `mouse-option.png` order. Extracted from `body` so the `Form` closure stays under the
    /// `closure_body_length` ceiling; the rows are unchanged.
    private var mouseSection: some View {
        slateFormSection("Mouse") {
            toggleRow(
                "Mouse Over to Focus",
                "Focus the pane under the mouse cursor automatically.",
                isOn: $focusFollowsMouse,
            )
            pickerRow(
                "Right-Click Action",
                "What right-click does in the terminal viewport (Ctrl+right-click always opens the menu).",
                selection: $rightClickAction,
            ) {
                Text("Context Menu").tag(RightClickAction.contextMenu)
                Text("Copy").tag(RightClickAction.copy)
                Text("Paste").tag(RightClickAction.paste)
                Text("Copy or Paste").tag(RightClickAction.copyOrPaste)
                Text("Ignore").tag(RightClickAction.ignore)
            }
            toggleRow(
                "Hide Mouse When Typing",
                "Hide the mouse cursor while the keyboard is in use.",
                isOn: $mouseHideWhileTyping,
            )
            // This surfaces as a simple ON/OFF switch (`spec/cursor-and-mouse`), not a 4-way picker:
            // ON ⇒ ⇧ extends the selection (`MouseShiftCapture.enabled`, the default), OFF ⇒ ⇧ is forwarded
            // to the program (`.disabled`). The leaf enum keeps `.always`/`.never` for the power-user token
            // mapping, but the UI exposes only the binary the spec shows. The getter projects
            // through `extendsSelection` (NOT a bare `== .enabled`) so a value persisted by the removed
            // 4-way picker reads sanely: `.always` → ON, `.never` → OFF.
            toggleRow(
                "Allow Shift with Mouse Click",
                "Hold Shift to select text even when the running app captures the mouse.",
                isOn: Binding(
                    get: { allowShiftClick.extendsSelection },
                    set: { allowShiftClick = $0 ? .enabled : .disabled },
                ),
            )
            toggleRow(
                "Cursor Click-to-Move",
                "Click in the prompt to move the shell cursor — sends arrow keys across soft-wrapped rows.",
                isOn: $clickToMove,
            )
            toggleRow(
                "Allow Mouse Capture",
                "Allow shell apps to capture mouse events (e.g. vim, tmux).",
                isOn: $allowMouseCapture,
            )
            timingFooter(.live)
        }
    }

    // MARK: - E10 Links (Open With + Link Schemes)

    /// Settings → Controls → Open With (E10 WI-3). The link-interaction knobs are CLIENT-side (not
    /// libghostty config), so they bind DIRECTLY — no `refreshing(_:)` terminal-config rebuild.
    ///
    /// HONESTY CEILING (docs/DECISIONS.md): a per-target "Open Files / Folders With → [app]" surrogate
    /// needs a LOCAL file / folder pane, which aislopdesk cannot offer for a REMOTE host (the files live on the
    /// host; there is no file-transfer sub-protocol). So instead of shipping dead Browser / Finder
    /// target pickers, the actionable config keys (`link-cmd-click` / `link-cmd-shift-click`) are
    /// surfaced and the reduced target set is documented as a footnote, not a control.
    private var openWithSection: some View {
        slateFormSection("Open With") {
            Toggle(isOn: $linkDetection) {
                rowLabel(
                    "Detect Links & Paths",
                    "Underline paths and URLs in terminal output on Cmd-hover so they are clickable.",
                )
            }
            linkPickerRow(
                "Cmd-Click on Link",
                "Open in the best handler (files / folders open on the host, URLs in your browser), copy the "
                    + "path / URL, or do nothing.",
                selection: $linkCmdClick,
            ) {
                Text("Open").tag(LinkCmdClick.open)
                Text("Copy").tag(LinkCmdClick.copy)
                Text("Do Nothing").tag(LinkCmdClick.nothing)
            }
            linkPickerRow(
                "Cmd-Shift-Click on Link",
                "Reveal the path in the host Finder, or open it with the host's system-default app.",
                selection: $linkCmdShiftClick,
            ) {
                Text("Reveal in Finder").tag(LinkCmdShiftClick.revealFinder)
                Text("Open with System Default").tag(LinkCmdShiftClick.openSystemDefault)
            }
            Text(
                "Files and folders live on the remote host, so per-target “Open in…” file / folder "
                    + "panes are not available here — paths reveal or open on the host and URLs open in your "
                    + "client browser.",
            )
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)
            timingFooter(.live)
        }
    }

    /// Settings → Controls → Link Schemes (E10 WI-3). The custom-scheme list is editable only when the
    /// mode is Custom; `http(s)` / `file` / `mailto` are always detected regardless of this mode.
    private var linkSchemesSection: some View {
        slateFormSection("Link Schemes") {
            linkPickerRow(
                "Auto-Detect Link Schemes",
                "Which URL schemes get underlined on Cmd-hover and made clickable. All detects any "
                    + "scheme://; Custom restricts to the schemes you list. http(s), file, and mailto are "
                    + "always detected.",
                selection: $autoDetectLinkSchemes,
            ) {
                Text("All").tag(AutoDetectLinkSchemes.all)
                Text("Custom").tag(AutoDetectLinkSchemes.custom)
            }
            if autoDetectLinkSchemes == .custom {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    rowLabel(
                        "Custom Link Schemes",
                        "Comma-separated extra schemes to additionally detect (e.g. codex, ssh, vscode).",
                    )
                    TextField("codex, ssh, vscode", text: customSchemesText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Slate.Typeface.body, design: .monospaced))
                }
            }
            timingFooter(.live)
        }
    }

    /// A dropdown row for a CLIENT-side link knob — like ``pickerRow`` but binds DIRECTLY (no `refreshing(_:)`
    /// terminal-config rebuild, since the link knobs are not libghostty config).
    private func linkPickerRow(
        _ title: String, _ subtitle: String? = nil,
        selection: Binding<some Hashable>, @ViewBuilder options: () -> some View,
    ) -> some View {
        LabeledContent {
            Picker("", selection: selection, content: options)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        } label: {
            rowLabel(title, subtitle)
        }
    }

    /// Bridge the `[String]` custom-schemes key to a comma / space / newline separated text field (each token
    /// trimmed, empties dropped). The setter persists the parsed list straight into `Defaults`.
    private var customSchemesText: Binding<String> {
        Binding(
            get: { customLinkSchemes.joined(separator: ", ") },
            set: { newValue in
                customLinkSchemes = newValue
                    .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            },
        )
    }

    // MARK: - Row helpers

    /// Wrap a fire-time `Defaults` control binding so a change ALSO re-applies the live terminal config (the
    /// E8 Controls passthrough). `PreferencesStore` stays isolated on its injected `UserDefaults`; the global
    /// Controls toggles live in `Defaults.standard`, so `refreshTerminalControls()` is the explicit seam that
    /// re-reads them (there is no `Defaults.observe` in the store, by design — see `PreferencesStore`).
    private func refreshing<V: Equatable>(_ binding: Binding<V>) -> Binding<V> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                store.refreshTerminalControls()
            },
        )
    }

    /// A toggle row with a bold-label-over-gray-subtext layout (the switch trailing).
    private func toggleRow(_ title: String, _ subtitle: String? = nil, isOn binding: Binding<Bool>) -> some View {
        Toggle(isOn: refreshing(binding)) { rowLabel(title, subtitle) }
    }

    /// A dropdown row (label + subtext leading, a `.menu` picker trailing) for the multi-state Controls enums.
    private func pickerRow(
        _ title: String, _ subtitle: String? = nil,
        selection: Binding<some Hashable>, @ViewBuilder options: () -> some View,
    ) -> some View {
        LabeledContent {
            Picker("", selection: refreshing(selection), content: options)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        } label: {
            rowLabel(title, subtitle)
        }
    }

    /// The row label layout: a bold title with an optional gray subtext beneath.
    private func rowLabel(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Editor section (RESERVED — deferred)

/// Editor is RESERVED/empty by design. The Editor section is meant to eventually configure a built-in
/// FILE-editor (Soft Wrap / Show Line Numbers / Show Whitespace / Tab Size / Scroll Past Last Line /
/// Default-to-Preview — see `docs/ui-shell/screenshots/editor-settings.png`). aislopdesk has no built-in file
/// editor, so there are NO settings to surface here. Deliberately we do NOT backfill it with terminal-render
/// prefs — those live elsewhere (FONT + CURSOR → Appearance `font-setting.png`/`cursor-style.png`; SCROLLBACK
/// → Controls `spec/terminal-features__scroll.md`). The section is kept in the taxonomy (pinned by
/// `SettingsSectionTaxonomyTests`) as a placeholder so the navigator stays complete; it fills in if/
/// when a file-pane editor lands (see `docs/ui-shell` backlog).
private struct EditorSettingsTab: View {
    var body: some View {
        Form {
            slateFormSection("Editor") {
                LabeledContent("File editor") {
                    Text("Not available")
                        .foregroundStyle(Slate.Text.tertiary)
                }
                Text(
                    "Editor settings (Soft Wrap, Line Numbers, Tab Size, …) configure a built-in file editor, "
                        + "which aislopdesk does not have yet. Terminal font, cursor, and scrollback live under "
                        + "Appearance and Controls.",
                )
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recipes section (snippet library + Command Replay — E16 WI-7)

/// Recipes is the saved-command / snippet library (`all-settings.png` shows the section, book glyph,
/// between Appearance and Key Bindings). E16 WI-7 populates it with the two surfaces aislopdesk backs today:
///
/// - **Snippets** — the persisted ``Snippet`` list (Name + Alias), each row with a pencil-edit + trash, and
///   an **Add Text Snippet** button that opens the ``SnippetEditorSheet`` (`textsnippet-setting.png`). CRUD
///   routes to the live ``WorkspaceStore`` (`addSnippet`/`updateSnippet`/`deleteSnippet`) injected via the
///   `\.workspaceStore` environment slot (the same seam the Advanced → Workspace rows use).
/// - **Command Replay** — the two replay-mode pickers (Saved Recipes default Auto / Recipe Files default
///   Ask Once) bound to the fire-time `Defaults.Keys` (`@Default(.replayModeSaved)` / `.replayModeFiles`).
///   Ask-Once / Manually surface the in-pane ``RecipeReplayHUD`` to run / step the queue.
///
/// **At-prompt snippet auto-expand is LIVE** (E16 ES-E16-4): the always-on baseline is the explicit palette
/// expand (type a snippet's name or alias under ⌘⇧P); on top of that, the **Expand alias at shell prompt**
/// toggle (`@Default(.snippetAutoExpand)`, default OFF) arms the prompt-aware input interceptor — typing an
/// alias then Tab/Space at an OSC-133;A shell prompt expands it in place (``SnippetAliasExpander``, wired by
/// `WorkspaceStore.wireSnippetExpander`). The toggle drives real behaviour, so it is not a lying control.
///
/// The RECIPE library list itself (saved `.aislopdeskrecipe` files) is store-glue (E16 WI-8/WI-10) and lands with
/// the save/open flows; this tab owns the snippet editor + the replay/expand SETTINGS. Cross-platform — the
/// iOS settings sheet (WI-10) hosts the same struct. Pinned in the taxonomy by `SettingsSectionTaxonomyTests`.
private struct RecipesSettingsTab: View {
    /// The live workspace owner (snippet CRUD). `nil` outside the app scene (previews / before the iOS sheet
    /// wires it, WI-10) → the snippet list renders a neutral unavailable note rather than crashing.
    @Environment(\.workspaceStore) private var workspaceStore

    @Default(.replayModeSaved) private var replayModeSaved
    @Default(.replayModeFiles) private var replayModeFiles
    @Default(.snippetAutoExpand) private var snippetAutoExpand

    /// The snippet currently open in the editor sheet (a fresh target for Add, or the row being edited).
    @State private var editing: SnippetEditTarget?

    var body: some View {
        Form {
            snippetsSection
            commandReplaySection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            SnippetEditorSheet(
                isNew: target.isNew,
                name: target.name,
                alias: target.alias,
                body: target.body,
            ) { name, alias, body in
                if let snippetID = target.snippetID {
                    workspaceStore?.updateSnippet(snippetID, name: name, body: body, alias: alias)
                } else {
                    workspaceStore?.addSnippet(name: name, body: body, alias: alias)
                }
            }
        }
    }

    // MARK: Snippets list + Add

    private var snippetsSection: some View {
        slateFormSection("Snippets") {
            if let store = workspaceStore {
                let snippets = store.snippets
                if snippets.isEmpty {
                    Text(
                        "No snippets yet. Add a text snippet to run it from the command palette, or expand it "
                            + "by alias at the shell prompt.",
                    )
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                } else {
                    ForEach(snippets) { snippet in
                        snippetRow(snippet, store: store)
                    }
                }
                Button { editing = SnippetEditTarget() } label: {
                    Label("Add Text Snippet", systemImage: "plus")
                }
            } else {
                Text("Snippets are unavailable in this context.")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
            }
        }
    }

    /// One snippet row: Name (+ monospaced Alias subtext), a pencil-edit, and a trash-delete (the row
    /// chrome from `textsnippet-setting.png`'s list behind the sheet).
    private func snippetRow(_ snippet: Snippet, store: WorkspaceStore) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(WorkspaceStore.snippetName(snippet.name))
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.primary)
                if !snippet.alias.isEmpty {
                    Text(snippet.alias)
                        .font(.system(size: Slate.Typeface.footnote).monospaced())
                        .foregroundStyle(Slate.Text.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { editing = SnippetEditTarget(snippet) } label: {
                Image(systemSymbol: .pencil)
                    .font(.system(size: Slate.Metric.iconSize))
                    .foregroundStyle(Slate.Text.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit snippet")
            Button { store.deleteSnippet(snippet.id) } label: {
                Image(systemSymbol: .trash)
                    .font(.system(size: Slate.Metric.iconSize))
                    .foregroundStyle(Slate.Text.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete snippet")
        }
    }

    // MARK: Command Replay + at-prompt auto-expand

    private var commandReplaySection: some View {
        slateFormSection("Command Replay") {
            Picker("Saved Recipes", selection: $replayModeSaved) {
                ForEach(RecipeReplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("Recipe Files", selection: $replayModeFiles) {
                ForEach(RecipeReplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(
                "How a recipe's saved commands run when you open it. Auto runs them all; Ask Once shows them, "
                    + "then runs the queue when you confirm in the pane; Manually runs one at a time; Skip opens "
                    + "the layout only.",
            )
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)

            // LIVE toggle (E16 ES-E16-4): at-prompt alias auto-expansion. Default OFF (opt-in) — when on, the
            // pure `SnippetAliasExpander` (wired per terminal pane) watches the in-progress prompt line and, on
            // a bare Tab/Space whose trailing word is a snippet alias, erases the alias and injects the resolved
            // body. Gated on an OSC-133;A prompt + a trusted line mirror so ordinary typing is never corrupted.
            Toggle("Expand alias at shell prompt", isOn: $snippetAutoExpand)
            Text(
                "Snippets always expand from the command palette (⌘⇧P): type a snippet's name or alias to run "
                    + "it. With this on, typing an alias then Tab or Space at the shell prompt expands it in "
                    + "place (needs shell integration for the prompt mark).",
            )
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)

            timingFooter(.live)
        }
    }
}

/// The snippet open in the ``RecipesSettingsTab`` editor sheet — a fresh empty target (Add) or an existing
/// snippet (Edit). `Identifiable` so it drives `.sheet(item:)`; `snippetID == nil` means "new".
private struct SnippetEditTarget: Identifiable {
    let id: UUID
    /// The backing snippet's id, or `nil` for a brand-new snippet (Add).
    let snippetID: UUID?
    let name: String
    let alias: String
    let body: String

    var isNew: Bool { snippetID == nil }

    /// A fresh, empty snippet (Add Text Snippet). A throwaway `id` keeps `.sheet(item:)` happy.
    init() {
        id = UUID()
        snippetID = nil
        name = ""
        alias = ""
        body = ""
    }

    /// Editing an existing snippet — seeds the sheet with its current Name / Alias / Text.
    init(_ snippet: Snippet) {
        id = snippet.id
        snippetID = snippet.id
        name = snippet.name
        alias = snippet.alias
        body = snippet.body
    }
}

// MARK: - Appearance section

/// Appearance: the TABS group (the New Tab Position picker — `tab-setting.png` shows it in a TABS group
/// on the Appearance page, NOT Shell), the theme picker (via `AppearancePreferences` → `ThemeStore`), the
/// density tier, the terminal FONT (family + size) and the CURSOR group (style + blink) — font/cursor
/// relocated here from the old Editor/Controls tabs to match the reference screenshots (`font-setting.png`
/// shows Font Family under Appearance; `cursor-style.png` shows the Cursor group under Appearance) — plus the
/// chrome toggles (command dividers, status bar). All LIVE (theme repoints every token; font/cursor rebuild
/// the libghostty config string and bump `TerminalConfigBroadcaster`; the New Tab Position + chrome toggles
/// are read at fire-time / on the next render).
private struct AppearanceSettingsTab: View {
    @Bindable var store: PreferencesStore

    @Default(.newTabPosition) private var newTabPosition
    // E19/A18 vertical-sidebar auto-hide (`auto-hide-tabs-panel`) — cross-platform (the sidebar is on
    // both macOS + iPad). The decision is the pure `SidebarAutoHidePolicy`; WI-7 drives `chrome.sidebarCollapsed`.
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    @Default(.showBlockDividers) private var showBlockDividers
    #if os(macOS)
    // E19/A29 window-size (`window-size`) — macOS-only: the initial dimensions are an `NSWindow`
    // concept (iOS has no resizable window), so the keys are bound only where the `Window` section renders.
    @Default(.windowSize) private var windowSize
    @Default(.windowCols) private var windowCols
    @Default(.windowRows) private var windowRows
    @Default(.windowWidthPx) private var windowWidthPx
    @Default(.windowHeightPx) private var windowHeightPx
    @Default(.dockIconAnimateProgress) private var dockIconAnimateProgress
    @Default(.dockIconErrorBadge) private var dockIconErrorBadge
    #endif

    var body: some View {
        Form {
            // PRODUCT DECISION (pinned, NOT a regression): an Appearance page could plausibly open with a
            // LAYOUT selector — Vertical Tabs / Tabs Top / Tabs Bottom. aislopdesk is VERTICAL-TABS-ONLY
            // by deliberate product decision: there is no horizontal tab bar, so there is no
            // layout selector to surface and a future reviewer must NOT read the missing horizontal-layout
            // option as a gap to backfill. An "Auto Hide Tabs Panel" row (sidebar-layout-only) and a WINDOW
            // group with a "Window Size" picker are both SURFACED below and BACKED — the Auto Hide picker
            // drives `SidebarAutoHidePolicy` (E19/A18, WI-2/WI-7) and the Window Size picker + steppers feed
            // `WindowSizeMath` through the macOS `NSWindow` glue (E19/A29, WI-1/WI-4); neither is dead UI.
            slateFormSection("Tabs") {
                Picker("New tab position", selection: $newTabPosition) {
                    Text("Automatic").tag(NewTabPosition.auto)
                    Text("End").tag(NewTabPosition.end)
                    Text("After Current Tab").tag(NewTabPosition.afterCurrent)
                }
                // AUTO HIDE TABS PANEL (E19/A18 — `auto-hide-tabs-panel`, `tab-setting.png`): when to show
                // the vertical tabs panel. `.auto` collapses the sidebar when the active session has a single tab
                // (WI-7 reads `SidebarAutoHidePolicy`); `.default`/`.always` never auto-hide. Cross-platform.
                pickerRow(
                    "Auto Hide Tabs Panel",
                    "When to show the tabs panel in Sidebar layout",
                    selection: $autoHideTabsPanel,
                ) {
                    Text("Default").tag(AutoHideTabsPanelMode.default)
                    Text("Always").tag(AutoHideTabsPanelMode.always)
                    Text("Auto").tag(AutoHideTabsPanelMode.auto)
                }
                timingFooter(.live)
            }

            // WINDOW (E19/A29 — `window-size`, `tab-setting.png`). macOS-only: the initial dimensions are
            // an `NSWindow` concept, so iOS (no resizable window) omits the section rather than ship a dead
            // toggle. Extracted to a computed property so the `Form` closure stays under `closure_body_length`.
            #if os(macOS)
            windowSection
            #endif

            // THEME (E15 WI-6): the picker lists every built-in PLUS the scanned custom `.aislopdesktheme`s
            // (`ThemeCatalog.shared.customThemes`); picking a built-in writes `theme`/`themeDark` (clearing the
            // slot's custom slug), picking a custom writes `customLightSlug`/`customDarkSlug` so the slot points
            // at the scanned document. With "Use separated theme for dark mode" ON the OS appearance selects the
            // slot, so a Dark Theme picker appears below the toggle (`dark-mode-theme.png`).
            slateFormSection("Theme") {
                Picker("Theme", selection: themeSelectionBinding(forDarkSlot: false)) {
                    themeOptions
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

            // THEME EDITOR (E15 WI-7): a swatch grid (fg/bg + 16 ANSI dots) + chrome-region groups (Tabbar
            // OMITTED — vertical-tabs-only) + Duplicate / Edit Selected Theme / Open Themes Folder + the Import
            // Theme… dropdown, bound to the active `ThemeStore` theme. macOS hosts the editable ColorPickers +
            // filesystem actions; iOS shows the read-only swatch display (see `ThemeEditorView`).
            ThemeEditorView(store: store)

            Section {
                Toggle(isOn: separateDarkBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use separated theme for dark mode")
                        Text(
                            "Follow the system color scheme: theme above is used in light mode, "
                                + "the dark theme below in dark mode.",
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if store.appearance.useSeparateDarkTheme ?? false {
                slateFormSection("Dark Theme") {
                    Picker("Dark Theme", selection: themeSelectionBinding(forDarkSlot: true)) {
                        themeOptions
                    }
                }
            }

            // FONT (E15 WI-8): the Font-Family scope tabs (Computed / Global / Light Theme / Dark Theme /
            // Fallback) + the "Aa" specimen combobox + Auto-match + per-face families + size + line-height +
            // ligatures + the bold/italic/underline/blink/blending controls (with deferred-apply notes), bound
            // to `store.terminal` and `store.appearance.themeFonts`. Replaces the old family-TextField +
            // size-Stepper Section (`font-setting.png` / `font-setting-bold.png`). See `FontSettingsView`.
            FontSettingsView(store: store)

            // The FULL Cursor group (live preview + color / text-under / opacity / style / blink /
            // animation) lives under Appearance (`cursor-style.png`). macOS hosts the rich `CursorPreviewView` (its
            // color wells + preview caret are AppKit); the compact iOS sheet keeps the cross-platform Style +
            // Blink controls (`CursorPreviewView` is `#if os(macOS)`).
            #if os(macOS)
            CursorPreviewView(store: store)
            #else
            slateFormSection("Cursor") {
                Picker("Style", selection: $store.terminal.cursorStyle) {
                    ForEach(TerminalPreferences.CursorStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Picker("Blink", selection: $store.terminal.cursorBlink) {
                    Text("Default").tag(TerminalPreferences.CursorBlink.default)
                    Text("On").tag(TerminalPreferences.CursorBlink.on)
                    Text("Off").tag(TerminalPreferences.CursorBlink.off)
                }
            }
            #endif

            slateFormSection("Chrome") {
                Toggle("Show command dividers", isOn: $showBlockDividers)
            }

            // DOCK ICON (E14/K5/K8 — M2): these live under **Appearance** (Visual spec,
            // terminal-features__progress-state.md). macOS-only (there is no Dock on iOS — the whole group is
            // `#if os(macOS)`, absent on iOS). Both toggles actuate ``DockProgressController`` via the pure
            // ``DockTintPolicy`` (read fire-time through `WorkspaceStore.dockTileModel`), so neither is dead UI.
            #if os(macOS)
            slateFormSection("Dock Icon") {
                Toggle("Animate Icon on Progress", isOn: $dockIconAnimateProgress)
                Toggle("Red Icon on Error", isOn: $dockIconErrorBadge)
            }
            #endif

            Section { timingFooter(.live) }
        }
        .formStyle(.grouped)
    }

    /// The shared picker options — the fixed built-in list THEN the scanned custom themes (each tagged with a
    /// ``ThemeSelection`` so the SAME body serves both the light/primary slot and the dark slot). Reading
    /// `ThemeCatalog.shared.customThemes` here registers the `@Observable` dependency, so the picker re-renders
    /// live when a freshly imported theme is scanned in.
    @ViewBuilder private var themeOptions: some View {
        Text("System").tag(ThemeSelection.builtin(.system))
        Divider()
        Text("Monokai Pro (Classic)").tag(ThemeSelection.builtin(.monokaiProClassic))
        Text("Monokai Pro Light").tag(ThemeSelection.builtin(.monokaiProClassicLight))
        Text("Monokai Pro Octagon").tag(ThemeSelection.builtin(.monokaiProOctagon))
        Text("Monokai Pro Machine").tag(ThemeSelection.builtin(.monokaiProMachine))
        Text("Monokai Pro Ristretto").tag(ThemeSelection.builtin(.monokaiProRistretto))
        Text("Monokai Pro Spectrum").tag(ThemeSelection.builtin(.monokaiProSpectrum))
        Divider()
        Text("Paper (Light)").tag(ThemeSelection.builtin(.paper))
        Text("Dark").tag(ThemeSelection.builtin(.dark))
        let customThemes = ThemeCatalog.shared.customThemes
        if !customThemes.isEmpty {
            Divider()
            ForEach(customThemes, id: \.slug) { document in
                Text(document.displayName).tag(ThemeSelection.custom(slug: document.slug))
            }
        }
    }

    /// Bridge the unified picker selection to one theme SLOT's pair of model fields (`theme`/`customLightSlug`
    /// for the light/primary slot, `themeDark`/`customDarkSlug` for the dark slot). A non-empty custom slug
    /// reads as `.custom`; otherwise the slot's built-in ``ThemeChoice`` (unset light ⇒ `.system`, unset dark
    /// ⇒ Monokai Pro Classic). Picking a built-in CLEARS the slot's custom slug (so it reverts to the built-in);
    /// picking a custom sets the slug. Writing always sets an explicit choice so the user's pick persists.
    private func themeSelectionBinding(forDarkSlot dark: Bool) -> Binding<ThemeSelection> {
        Binding(
            get: {
                let slug = dark ? store.appearance.customDarkSlug : store.appearance.customLightSlug
                if let slug, !slug.isEmpty { return .custom(slug: slug) }
                let choice = dark ? store.appearance.themeDark : store.appearance.theme
                return .builtin(choice ?? (dark ? .monokaiProClassic : .system))
            },
            set: { selection in
                // Mutate a local copy and assign ONCE so the store's `appearance` didSet (which re-applies the
                // theme) fires a single time for the paired (choice, slug) write.
                var appearance = store.appearance
                switch selection {
                case let .builtin(choice):
                    if dark {
                        appearance.themeDark = choice
                        appearance.customDarkSlug = nil
                    } else {
                        appearance.theme = choice
                        appearance.customLightSlug = nil
                    }
                case let .custom(slug):
                    if dark {
                        appearance.customDarkSlug = slug
                    } else {
                        appearance.customLightSlug = slug
                    }
                }
                store.appearance = appearance
            },
        )
    }

    /// The "Use separated theme for dark mode" toggle (`useSeparateDarkTheme`): `nil` reads as OFF.
    private var separateDarkBinding: Binding<Bool> {
        Binding(
            get: { store.appearance.useSeparateDarkTheme ?? false },
            set: { store.appearance.useSeparateDarkTheme = $0 },
        )
    }

    private var densityBinding: Binding<String> {
        Binding(
            get: { store.appearance.density ?? "comfortable" },
            set: { store.appearance.density = $0 },
        )
    }

    // MARK: - E19/A29 Window section (macOS-only)

    /// The WINDOW group (`tab-setting.png`): the `window-size` policy picker + the mode-specific steppers.
    /// `.remember` restores the autosaved frame (the default); `.grid` sizes to `window-cols × window-rows`;
    /// `.frame` to `window-width-px × window-height-px`. The raw values are clamped by `WindowSizeMath` and
    /// applied ONCE per window open by the introspect glue (WI-4), so a later manual resize is never fought —
    /// the footer note says so. macOS-only (no resizable window on iOS).
    #if os(macOS)
    private var windowSection: some View {
        slateFormSection("Window") {
            pickerRow(
                "Window Size",
                "How new windows decide their initial dimensions.",
                selection: $windowSize,
            ) {
                Text("Remember last size").tag(WindowSizeMode.remember)
                Text("Grid (cols × rows)").tag(WindowSizeMode.grid)
                Text("Frame (pixels)").tag(WindowSizeMode.frame)
            }
            switch windowSize {
            case .remember:
                EmptyView()
            case .grid:
                Stepper("Columns: \(windowCols)", value: $windowCols, in: 1...1000)
                Stepper("Rows: \(windowRows)", value: $windowRows, in: 1...1000)
            case .frame:
                Stepper("Width: \(windowWidthPx) px", value: $windowWidthPx, in: 64...16384, step: 50)
                Stepper("Height: \(windowHeightPx) px", value: $windowHeightPx, in: 64...16384, step: 50)
            }
            Text("Applied to the next window opened.")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
        }
    }
    #endif

    // MARK: - Row helpers

    /// A dropdown row (bold title + optional gray subtext leading, a `.menu` picker trailing) — the
    /// label-with-subtitle picker used by Auto Hide Tabs Panel + Window Size. Binds DIRECTLY (these are plain
    /// `Defaults`, not libghostty config — no terminal-config rebuild), mirroring `ControlsSettingsTab.pickerRow`.
    private func pickerRow(
        _ title: String, _ subtitle: String? = nil,
        selection: Binding<some Hashable>, @ViewBuilder options: () -> some View,
    ) -> some View {
        LabeledContent {
            Picker("", selection: selection, content: options)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        } label: {
            rowLabel(title, subtitle)
        }
    }

    /// The row label layout: a bold title with an optional gray subtext beneath.
    private func rowLabel(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A Theme-picker selection — a built-in ``ThemeChoice`` or a scanned custom theme (by slug). Bridges the
/// dropdown's single selection to a slot's `theme`/`customLightSlug` (resp. `themeDark`/`customDarkSlug`)
/// model pair: a built-in pick clears the slot's custom slug, a custom pick sets it.
private enum ThemeSelection: Hashable {
    case builtin(ThemeChoice)
    case custom(slug: String)
}

// MARK: - Agents section

/// Agents: the CLAUDE CODE install-hooks card (E13 WI-2 — install/uninstall + a status row, driven through
/// the host metadata channel), then the host-side agent-detection flags (relocated from the old Video tab —
/// read by the host daemon, so they apply on reconnect) plus the layout-auto-switch and clipboard-history
/// fire-time toggles (LIVE). **Claude Code only** (E13 binding directive 1): there is NO codex/opencode card
/// — `MetadataCodec.AgentKind.codex` is documented-dead, never rendered.
private struct AgentsSettingsTab: View {
    @Bindable var store: PreferencesStore

    /// E13 WI-2: the install-hooks model, injected by the app scene (its seams target the active connection's
    /// first-pane ``MetadataClient``). `nil` outside the app scene (previews / the iOS sheet before its wiring
    /// lands) → the card renders in the disabled "Connect a session" state rather than crashing.
    @Environment(\.agentHooksController) private var agentHooks

    @Default(.autoSwitchLayouts) private var autoSwitchLayouts
    @Default(.recordClipboardHistory) private var recordClipboardHistory

    // E13 WI-3: the "Agent Behaviour" toggles. badge×3 + notify×2 are fire-time `Defaults.Keys` (apply
    // live); prevent-sleep / resume-on-recovery ride the `AgentPreferences` sidecar (`$store.agent`, reconnect).
    @Default(.agentBadgeWhileProcessing) private var agentBadgeWhileProcessing
    @Default(.agentBadgeWhenComplete) private var agentBadgeWhenComplete
    @Default(.agentBadgeWhenAwaitingInput) private var agentBadgeWhenAwaitingInput
    @Default(.agentNotifyTaskComplete) private var agentNotifyTaskComplete
    @Default(.agentNotifyAwaitInput) private var agentNotifyAwaitInput

    /// The Agent-Behaviour section is greyed out until at least one integration is installed —
    /// read off the install-card controller's state. `nil`/disconnected ⇒ not installed ⇒ greyed.
    private var behaviorEnabled: Bool { AgentSettingsCard.behaviourEnabled(agentHooks) }

    var body: some View {
        Form {
            claudeCodeSection

            slateFormSection("Agent detection (host)") {
                optionalBoolToggle("Foreground-process watch", $store.agent.agentDetect)
                optionalBoolToggle("Claude Code hooks", $store.agent.agentHooks)
                timingFooter(.reconnect)
            }

            agentBehaviorSection
            agentBehaviorHostSection

            slateFormSection("Behaviour") {
                Toggle("Auto-switch layouts on trigger app", isOn: $autoSwitchLayouts)
                Toggle("Record clipboard history", isOn: $recordClipboardHistory)
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
        // Re-probe the host install state on each open (per spec — not cached forever); `.task` re-fires when
        // the Agents tab re-appears and auto-cancels on disappear.
        .task { await agentHooks?.refresh() }
    }

    // MARK: Agent Behaviour (E13 WI-3 — badge×3 + notify×2, greyed until an integration is installed)

    /// The "Agent Behaviour" badge/notify toggles (apply LIVE). Greyed out until at least one
    /// integration is installed (``behaviorEnabled``); Claude-only. The badge toggles drive the GLOBAL
    /// ``AgentBadgeGates`` default the sidebar applies (a per-pane override lives on the tab context-menu).
    private var agentBehaviorSection: some View {
        slateFormSection("Agent Behaviour") {
            Toggle("Badge While Processing", isOn: $agentBadgeWhileProcessing)
            Toggle("Badge When Task Completes", isOn: $agentBadgeWhenComplete)
            Toggle("Badge When Awaiting Input", isOn: $agentBadgeWhenAwaitingInput)
            Toggle("Notify When Task Completes", isOn: $agentNotifyTaskComplete)
            Toggle("Notify When Awaiting Input", isOn: $agentNotifyAwaitInput)
            if !behaviorEnabled {
                Text("Install an integration above to configure agent behaviour.")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
            }
            timingFooter(.live)
        }
        .disabled(!behaviorEnabled)
    }

    /// The host-side Agent-Behaviour flags (apply on RECONNECT) — Prevent Sleep + Resume on Recovery, riding
    /// the ``AgentPreferences`` sidecar (`$store.agent`). Greyed alongside the live section; Claude-only.
    private var agentBehaviorHostSection: some View {
        slateFormSection("Agent Behaviour (host)") {
            optionalBoolToggle("Prevent Sleep While Processing", $store.agent.preventSleep)
            optionalBoolToggle("Resume on Recovery", $store.agent.resumeOnRecovery)
            timingFooter(.reconnect)
        }
        .disabled(!behaviorEnabled)
    }

    // MARK: Claude Code install-hooks card (`install-agent-integeration.png`)

    /// The CLAUDE CODE card: a bold "Install Hooks" title + gray description with trailing pill buttons
    /// (Install when not installed, "Installed" disabled + Uninstall when installed) and a Status row
    /// ("✓ Installed" green / "Not Installed" gray). Disabled with a "Connect a session" note while no pane
    /// backs the card. Claude-only.
    @ViewBuilder
    private var claudeCodeSection: some View {
        let state = AgentSettingsCard.installState(agentHooks)
        slateFormSection("Claude Code") {
            LabeledContent {
                installButtons(state)
            } label: {
                rowLabel(
                    "Install Hooks",
                    "Add aislopdesk hooks to ~/.claude/settings.json for real-time state updates",
                )
            }

            LabeledContent("Status") { statusBadge(state) }

            if state == .disconnected || state == .unknown {
                Text("Connect a session to manage hooks")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
            }

            // Install/uninstall write the host file LIVE, but Claude only re-reads its settings.json on the
            // next launch — so this is an agent-restart caveat, not a host-reconnect-gated sidecar flag (hence
            // a plain caption, not the `.reconnect` "Applies on reconnect" chip, which would mislead).
            Text("Hooks take effect after the agent restarts.")
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.tertiary)
        }
    }

    /// The trailing pill buttons for the Install Hooks row, keyed on the install state. While a write is in
    /// flight a small spinner replaces the buttons; while disconnected/unknown the Install button shows
    /// disabled (honest — never a dead-looking enabled button with no backing pane).
    private func installButtons(_ state: AgentHooksController.InstallState) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            switch state {
            case .installed:
                Button("Installed") {}.disabled(true)
                Button("Uninstall") { Task { await agentHooks?.uninstall() } }
            case .notInstalled:
                Button("Install") { Task { await agentHooks?.install() } }
            case .working:
                ProgressView().controlSize(.small)
            case .disconnected,
                 .unknown:
                Button("Install") {}.disabled(true)
            }
        }
        .buttonStyle(.bordered)
    }

    /// The Status-row trailing badge: a green "✓ Installed" / gray "Not Installed" / neutral "Working…" /
    /// "—" by state.
    @ViewBuilder
    private func statusBadge(_ state: AgentHooksController.InstallState) -> some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark")
                .foregroundStyle(Slate.Status.ok)
        case .notInstalled:
            Text("Not Installed").foregroundStyle(Slate.Text.secondary)
        case .working:
            Text("Working…").foregroundStyle(Slate.Text.secondary)
        case .disconnected,
             .unknown:
            Text("—").foregroundStyle(Slate.Text.tertiary)
        }
    }

    /// The row label layout: a bold title with an optional gray subtext beneath (mirrors the Appearance tab's
    /// `rowLabel`, kept local so the Agents card composes without widening that struct's visibility).
    private func rowLabel(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optionalBoolToggle(_ title: String, _ binding: Binding<Bool?>) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil },
        )) { Text(title) }
    }
}

// MARK: - Agents card state derivation (E13 WI-2 — the ONE nil-controller fallback, shared + testable)

/// The Agents card's derived state from the (optional) injected ``AgentHooksController`` — the ONE place the
/// nil-controller fallbacks live, so the macOS Settings scene and the iOS ``SettingsSheet`` derive the card
/// identically. A `nil` controller (no injection — e.g. the iOS-sheet wiring that this regression fixes) MUST
/// fall back to ``AgentHooksController/InstallState/disconnected`` + behaviour-disabled, NEVER a false live
/// card. Pure + cross-platform so it is unit-pinned headlessly (`AgentSettingsCardTests`).
enum AgentSettingsCard {
    /// The install-card state to show: the controller's state, or `.disconnected` when no controller backs it.
    static func installState(_ controller: AgentHooksController?) -> AgentHooksController.InstallState {
        controller?.state ?? .disconnected
    }

    /// Whether the Agent-Behaviour toggles are configurable (an integration is installed). A nil controller ⇒
    /// `false` ⇒ the whole behaviour section is greyed (the exact iOS bug when the controller is not injected).
    static func behaviourEnabled(_ controller: AgentHooksController?) -> Bool {
        controller?.isInstalled ?? false
    }
}

// MARK: - Agents settings-card environment slot (E13 WI-2)

extension EnvironmentValues {
    /// The single app-owned ``AgentHooksController`` (E13 WI-2), injected at the Settings scene root so the
    /// Agents card reaches it. `nil` outside the app scene (previews / the iOS sheet before its wiring lands)
    /// → the card renders disabled rather than crashing.
    @Entry var agentHooksController: AgentHooksController?
}

extension View {
    /// Inject the app-owned ``AgentHooksController`` into the environment (called at the Settings scene root).
    func agentHooksController(_ controller: AgentHooksController?) -> some View {
        environment(\.agentHooksController, controller)
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
/// whole overlay. The Video HOST flags (QP/FEC/pacer/sharpen) have no dedicated section, so they fold in here
/// as a "Video (host)" sub-section — real functionality, reconnect-tagged + symmetric-FEC-warned.
private struct AdvancedSettingsTab: View {
    @Bindable var store: PreferencesStore
    /// The shared navigator selection — threaded into the All-Settings list so a ✎ jump can repoint it.
    @Binding var selectedSection: SettingsSection

    // E14/K11-K12 privilege surface (terminal-features__notifications.md → Settings → Advanced). Cross-platform
    // — these gate what a remote OSC sequence may do client-side, so they apply on macOS AND iOS.
    @Default(.titleShellControlled) private var titleShellControlled
    @Default(.titleReport) private var titleReport
    @Default(.clipboardShellControlled) private var clipboardShellControlled
    @Default(.clipboardRead) private var clipboardRead
    @Default(.clipboardWrite) private var clipboardWrite

    #if os(macOS)
    /// Local edit buffer of `key = value` lines; committed into `store.rawOverrides` on change. macOS-only:
    /// the raw `AISLOPDESK_*` editor is a HOST-side concern, so the compact iOS sheet (WI-5) omits it.
    @State private var text: String = ""
    #endif

    var body: some View {
        Form {
            privilegesSection

            // The raw `AISLOPDESK_*` override editor + the Video HOST flags are macOS-host-relevant, so the
            // iOS settings sheet (WI-5) omits them; the cross-platform All-Settings list + Workspace transfer
            // below still reach iOS.
            #if os(macOS)
            slateFormSection("Raw overrides") {
                Text(
                    "One AISLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
                )
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                TextEditor(text: $text)
                    .font(.system(size: Slate.Typeface.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: text) { _, new in commit(new) }
                HStack(spacing: Slate.Metric.space1) {
                    Image(systemSymbol: .infoCircle)
                    Text("A real environment variable set on the process still wins over any value here.")
                }
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.tertiary)
            }

            VideoHostSettingsView(store: store)

            configFileSection
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

    // MARK: - Privileges (E14/K11-K12 — title gates + OSC-52 master + read/write tri-state)

    /// The privilege surface (Settings → Advanced, `terminal-features__notifications.md`): the title gates
    /// + the OSC-52 master switch + the read/write tri-state pickers. The pickers are DISABLED while the
    /// master is off (the whole OSC-52 path resolves to Deny then). Title Report is a documented ceiling — it
    /// persists/surfaces but does not yet actuate (the libghostty fork owns XTWINOPS; see docs/DECISIONS.md).
    private var privilegesSection: some View {
        slateFormSection("Privileges") {
            Toggle(isOn: $titleShellControlled) {
                privilegeLabel(
                    "Title — Shell Controlled",
                    "Allow programs to set the tab and window title via OSC 0 / OSC 2.",
                )
            }
            Toggle(isOn: $titleReport) {
                privilegeLabel(
                    "Title Report",
                    "Allow programs to read the window title back via OSC 21 / XTWINOPS. Persisted but not "
                        + "yet enforced — the terminal renderer answers this query itself.",
                )
            }
            Toggle(isOn: refreshingControls($clipboardShellControlled)) {
                privilegeLabel(
                    "Clipboard — Shell Controlled",
                    "Master switch for OSC 52 clipboard access. When off, clipboard read and write are denied.",
                )
            }
            clipboardPicker(
                "Clipboard Read", "Whether a program may READ the clipboard via OSC 52.", $clipboardRead,
            )
            clipboardPicker(
                "Clipboard Write", "Whether a program may WRITE the clipboard via OSC 52.", $clipboardWrite,
            )
            timingFooter(.live)
        }
    }

    /// A tri-state OSC-52 access picker (Ask / Allow / Deny), disabled while the master switch is off. The
    /// change re-applies the live libghostty config (the clipboard tokens feed `clipboard-read/write`).
    private func clipboardPicker(
        _ title: String, _ subtitle: String, _ selection: Binding<ClipboardAccess>,
    ) -> some View {
        LabeledContent {
            Picker("", selection: refreshingControls(selection)) {
                Text("Ask").tag(ClipboardAccess.ask)
                Text("Allow").tag(ClipboardAccess.allow)
                Text("Deny").tag(ClipboardAccess.deny)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            privilegeLabel(title, subtitle)
        }
        .disabled(!clipboardShellControlled)
    }

    /// The row label layout: a bold title with a gray subtext beneath.
    private func privilegeLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(title)
            Text(subtitle)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Wrap a fire-time `Defaults` clipboard binding so a change ALSO re-applies the live terminal config —
    /// the master + read/write tokens are read by `TerminalControls.from(defaults:)` into the libghostty
    /// `clipboard-*` lines, so `refreshTerminalControls()` is the explicit re-read seam (the E8 idiom).
    private func refreshingControls<V: Equatable>(_ binding: Binding<V>) -> Binding<V> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                store.refreshTerminalControls()
            },
        )
    }

    /// Clear the local raw-overrides edit buffer after a reset. macOS-only buffer → a no-op on iOS.
    private func clearRawOverridesBuffer() {
        #if os(macOS)
        text = ""
        #endif
    }

    // MARK: - Config File (settings import/export)

    /// Settings → Advanced → CONFIG FILE group: the resolved config path + "Open Config File" +
    /// "Reload Config". macOS-only — the config file lives in the user's `~/.config` directory tree,
    /// which is inaccessible on iOS (no user-visible filesystem). "Open Config File" creates the parent
    /// directory and the file (if absent) then opens it in the default text editor so the user lands in
    /// a usable state even on a fresh install. "Reload Config" calls the SAME action as the command
    /// palette's "Reload Config" row: `reapplyLiveSettings()` + the config-reload broadcast.
    #if os(macOS)
    private var configFileSection: some View {
        slateFormSection("Config File") {
            LabeledContent("Config path") {
                // `resolvePath(override:nil)` respects `AISLOPDESK_CONFIG_FILE` env override so the
                // displayed path always matches the file the app actually honours (not just the XDG default).
                Text(CLIConfig.resolvePath(override: nil))
                    .font(.system(size: Slate.Typeface.footnote, design: .monospaced))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: Slate.Metric.space3) {
                Button("Open Config File") {
                    let path = CLIConfig.resolvePath(override: nil)
                    let url = URL(fileURLWithPath: path)
                    // Create the parent directory so a first-time open works without a separate setup step.
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: nil,
                    )
                    // Create an empty file if the config doesn't exist yet so the editor opens something.
                    if !FileManager.default.fileExists(atPath: path) {
                        try? "".write(to: url, atomically: true, encoding: .utf8)
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                Button("Reload Config") {
                    // Mirror the palette's "Reload Config" action exactly (same as WorkspaceControlBackend.configReload).
                    store.reapplyLiveSettings()
                    NotificationCenter.default.post(
                        name: WorkspaceControlBackend.configReloadNotification, object: nil,
                    )
                }
                .buttonStyle(.bordered)
            }
            timingFooter(.live)
        }
    }
    #endif

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

/// The Video / FEC / pacer host flags, folded into Advanced (there is no dedicated Video section). These are read by
/// the HOST daemon at launch and shipped via the `video-prefs.json` sidecar, so they are labelled "applies
/// on reconnect"; the SYMMETRIC FEC keys add a "set on both ends" warning. The client-side `sharpen` is the
/// one live field. Body returns a `Group` of `Section`s so the host `Form` (Advanced) renders them inline.
private struct VideoHostSettingsView: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Group {
            slateFormSection("Video · Quality (host)") {
                optionalIntStepper("Sharp QP", $store.video.qpSharp, range: 1...51, default: 26)
                optionalIntStepper("Coarse QP", $store.video.qpCoarse, range: 1...51, default: 40)
                timingFooter(.reconnect)
            }

            slateFormSection("Video · Forward Error Correction (symmetric)") {
                optionalIntStepper("Parity (m)", $store.video.fecM, range: 1...8, default: 1)
                optionalIntStepper("Group size (k)", $store.video.fecK, range: 1...32, default: 8)
                HStack(spacing: Slate.Metric.space1) {
                    Image(systemSymbol: .exclamationmarkTriangleFill)
                    Text("FEC must be set IDENTICALLY on both ends or the host and client disagree.")
                }
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Status.warn)
                timingFooter(.reconnect)
            }

            slateFormSection("Video · Pacer (host)") {
                Picker("Mode", selection: pacerBinding) {
                    Text("Default (deadline)").tag(VideoPreferences.Pacer?.none)
                    Text("Deadline").tag(Optional(VideoPreferences.Pacer.deadline))
                    Text("On arrival").tag(Optional(VideoPreferences.Pacer.arrival))
                }
                timingFooter(.reconnect)
            }

            slateFormSection("Video · Client render") {
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
                Text("\(value)").foregroundStyle(Slate.Text.secondary)
            } else {
                Text("default").foregroundStyle(Slate.Text.tertiary)
                    .font(.system(size: Slate.Typeface.footnote))
            }
        }
    }

    private func optionalDoubleSlider(
        _ title: String, _ binding: Binding<Double?>, range: ClosedRange<Double>, default def: Double,
    ) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
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
