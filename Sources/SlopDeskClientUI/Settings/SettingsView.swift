// SettingsView — the SwiftUI Settings surface.
//
// A two-column Settings window; the right column is a THIN `@Bindable` over the one live `@Observable`
// `PreferencesStore`. Each section edits a slice of the typed prefs models (`TerminalPreferences`,
// `VideoPreferences`, `AgentPreferences`, `AppearancePreferences`, `KeybindingPreferences`) or the fire-time
// `SettingsKey` toggles (`@Default(.key)`); the store's `didSet` apply-paths do the rest (terminal
// live-reload, env overlay + sidecar, theme repoint, keybinding republish).
//
// LAYOUT: left NAVIGATOR (search pill + icon+label section list) + content column
// (`docs/ui-shell/screenshots/{all-settings,launch-option,editor-settings,cursor-style}.png`). The sidebar
// search pill (filters SECTION ROWS) is DISTINCT from the Advanced → All-Settings content search (filters
// config KEYS) — both surfaced at once.
//
// An 8-section taxonomy (`SettingsSection`): General / Shell / Controls / Editor / Agents / Appearance /
// Key Bindings / Advanced — finer-grained than a flat tab strip so each group can sit where its screenshot
// proves it belongs, rather than where it happens to fit. FONT (family + size) + CURSOR (style + blink) →
// **Appearance** (`font-setting.png` / `cursor-style.png`); SCROLLBACK → **Controls**
// (`spec/terminal-features__scroll.md`); theme → Appearance; agent host flags → Agents; Close Confirmation
// (Closing Tab / Closing Window) → **General** (`launch-option.png`). **Editor** is reserved for a built-in
// FILE-editor (Soft Wrap / Line Numbers / Tab Size — `editor-settings.png`) slopdesk lacks, so it stays
// RESERVED/empty (kept 1:1 in the navigator, NOT backfilled with terminal-render prefs). The Video HOST flags
// (QP/FEC/pacer/sharpen) have no dedicated section, so they fold into Advanced as a "Video (host)"
// sub-section — real functionality, not dropped.
//
// SURFACING: the main window is `.hiddenTitleBar` and `OverlayCoordinator` is NOT yet mounted, so this rides
// a STOCK SwiftUI `Settings` scene (`SlopDeskSettingsScene`) — ⌘, opens a separate system-chromed window
// that doesn't clash with the workspace's hover-reveal titlebar. When the coordinator lands the same tree can
// move into an in-window panel via `settingsVisible`. `SettingsView` stays cross-platform so the iOS settings
// sheet can host the same section structs.
//
// DEFERRED vs LIVE-APPLY: each section carries an `ApplyTiming` chip (`.live` = immediate; `.reconnect` = a
// HOST-read sidecar flag, effective on the next host connection). Terminal + appearance + keybindings + the
// fire-time toggles are live; the video/agent HOST flags are reconnect-only; SYMMETRIC keys (FEC) also carry
// a "set on both ends" warning.
//
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskCLICore
import SlopDeskClientCore
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit // UIApplication.openSettingsURLString — the notification-permission deep link.
#endif

// MARK: - Settings scene (stock SwiftUI, ⌘,)

/// The stock `Settings` scene wrapper, wired in `SlopDeskClientApp`. Stock (not an in-window panel) because
/// the main window hides its titlebar and the overlay host isn't mounted yet (see file header). macOS-only:
/// the `Settings` scene is unavailable on iOS (its settings surface lands as an in-app sheet later);
/// `SettingsView` stays cross-platform so iOS can host it.
#if os(macOS)
public struct SlopDeskSettingsScene: Scene {
    private let store: PreferencesStore
    /// The app-owned Agents install-hooks model, injected so the card's Install/Uninstall/Status
    /// round-trips reach the host. Optional — a preview/future host can omit it (card then renders the
    /// disabled "Connect a session" state).
    private let agentHooks: AgentHooksController?
    /// The app-owned ``WorkspaceStore``, injected so the DEVICE-LOCAL preference rows (docs/45 §7.3 —
    /// today: follow the shared focus) reach the value they edit. Optional — a preview can omit it, and
    /// those rows then render the platform default, disabled.
    private let workspace: WorkspaceStore?

    public init(
        store: PreferencesStore,
        agentHooks: AgentHooksController? = nil,
        workspace: WorkspaceStore? = nil,
    ) {
        self.store = store
        self.agentHooks = agentHooks
        self.workspace = workspace
    }

    public var body: some Scene {
        Settings {
            SettingsView(store: store)
                .agentHooksController(agentHooks)
                .workspaceStore(workspace)
            // SYSTEM chrome, end to end: no colour scheme is pinned, so the window follows the OS
            // appearance like System Settings does. Pinning it to the terminal theme used to put a
            // dark-themed preferences window on a light Mac. Controls take the app's one neutral
            // accent (the AccentColor asset) with no per-scene override. See `SettingsInk`.
        }
    }
}
#endif

// MARK: - Settings taxonomy (the 8 sections — one source for the macOS navigator + the iOS list)

/// The settings taxonomy as a DISPATCH key: which section's body to build. It is an enum because that
/// is what ``SettingsSectionContent``'s exhaustive `switch` needs — a section maps to a `some View`,
/// which is the one part of a section that cannot leave Swift.
///
/// Everything a section IS — its title, its glyph, its place in the order, whether the compact list
/// drops it — comes from `slopdesk_workspace::settings_catalog` through ``SettingsCatalog/sections``,
/// so the Mac's navigator and the phone's list read one table rather than two. The cases here carry
/// no data of their own; ``ordered`` is the list to render, and `SettingsSectionTaxonomyTests` pins
/// that it covers every case, which is what stops a case added here from being unreachable in both
/// lists (the same exhaustiveness contract every option group holds).
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shell
    case controls
    case editor
    case agents
    case appearance
    case keybindings
    case advanced

    var id: String { rawValue }

    /// The catalog row behind this case, or `nil` for a case the boundary does not name — which the
    /// taxonomy test is what rules out.
    private var row: SettingsCatalog.Section? { SettingsCatalog.section(rawValue) }

    /// The navigator row label (and the phone list's row title).
    var title: String { row?.title ?? "" }

    /// The sidebar glyph (SF Symbol name).
    var systemImage: String { row?.systemImage ?? "" }

    /// macOS-only sections are dropped from the compact iOS sheet. Only **Keybindings** qualifies: its
    /// chord CAPTURE is a macOS `NSEvent` monitor (`KeyCaptureMonitor` is `#if os(macOS)`), with no iOS
    /// capture UI. Advanced's macOS-HOST-only *rows* (raw `SLOPDESK_*` editor + Video host flags) are gated
    /// INSIDE `AdvancedSettingsTab`, not by hiding the section, so the All-Settings list still reaches iOS.
    var isMacOSOnly: Bool { row?.isMacOSOnly ?? false }

    /// The whole taxonomy IN THE CATALOG'S ORDER — what both lists render. Declaration order here is
    /// not the contract; the boundary's is.
    static let ordered: [Self] = SettingsCatalog.sections.compactMap { Self(rawValue: $0.id) }

    /// What a COMPACT list shows.
    static var compact: [Self] { ordered.filter { !$0.isMacOSOnly } }
}

// MARK: - Apply-timing tag (deferred vs live, surfaced as a chip not prose)

/// When a setting takes effect — surfaced as a chip so the deferred/live distinction is a DATA
/// attribute, not prose. The two cases and their words are ``SettingsCatalog/ApplyTiming``; only the
/// tint below is a view decision.
typealias ApplyTiming = SettingsCatalog.ApplyTiming

/// A small inline timing chip (symbol + label). The tint is resolved in the view body rather than on the
/// nonisolated `ApplyTiming` enum.
struct TimingChip: View {
    let timing: ApplyTiming
    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemName: timing.symbol)
            Text(timing.label)
        }
        .font(SettingsType.caption)
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch timing {
        case .live: SettingsInk.ok
        case .reconnect: SettingsInk.warn
        }
    }
}

// MARK: - The two-column Settings view

/// The Settings body: a two-column layout — a left navigator (search pill + icon+label section rows) and the
/// selected section's content on the right. Section set + order + icons come from `SettingsSection` so the
/// navigator can't drift from the pinned taxonomy.
struct SettingsView: View {
    @Bindable var store: PreferencesStore

    /// The selected section — also bound into ``SettingsSectionContent`` so the Advanced All-Settings list's
    /// ✎ jump buttons can repoint the navigator to the owning section.
    @State private var selectedSection: SettingsSection = .general

    /// The SIDEBAR search pill query — narrows which SECTION ROWS show. DISTINCT from the Advanced →
    /// All-Settings content search (`AllSettingsListView`, which narrows the config-KEY list); both show at
    /// once. Plain case-insensitive substring match over section titles.
    @State private var sidebarQuery: String = ""

    var body: some View {
        // NATIVE macOS settings chrome: a `NavigationSplitView` with a system `List(selection:)` sidebar +
        // native `.searchable` and the `Form`-based section content as detail — instead of a bespoke
        // two-column `HStack` + custom `SettingsSidebarRow` buttons. Nothing pins the window's appearance:
        // it follows the OS, like every other preferences window.
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
            // A Settings window has a FIXED navigator (like macOS System Settings) — drop the sidebar-collapse
            // toggle macOS auto-adds. Collapsing would leave no way to switch sections.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 480)
        #if os(macOS)
            // Esc closes the window. A stock `Settings` scene has NO Esc behaviour of its own, so ⌘, otherwise
            // opened a window the keyboard could not dismiss; the monitor is window-scoped and defers to a
            // field editor (see `SettingsEscapeDismiss`).
            .background { SettingsEscapeDismisser() }
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
        guard !needle.isEmpty else { return SettingsSection.ordered }
        return SettingsSection.ordered.filter { $0.title.lowercased().contains(needle) }
    }

    /// The body for a section — a thin dispatch onto the shared ``SettingsSectionContent`` (the SAME switch
    /// the iOS sheet renders, so the macOS navigator and the iOS list can never show different content).
    private func content(for section: SettingsSection) -> some View {
        SettingsSectionContent(section: section, store: store, selectedSection: $selectedSection)
    }
}

// MARK: - Shared per-section content (one dispatch for the macOS navigator + the iOS sheet)

/// Resolves a ``SettingsSection`` to its per-section body — the ONE place the section → struct mapping lives,
/// so the macOS navigator (`SettingsView`) and iOS `SettingsSheet` render byte-identical content. The
/// per-section structs stay `private`; this `internal` view lets the iOS sheet (a separate file) reach them
/// without widening their visibility. `selectedSection` threads the navigator selection so the Advanced
/// All-Settings ✎ jump can repoint it (a no-op on iOS, where the jump is deferred).
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
        case .keybindings: KeybindingsSettingsTab(store: store)
        case .advanced: AdvancedSettingsTab(store: store, selectedSection: $selectedSection)
        }
    }
}

// MARK: - General section

/// General: On-Launch behaviour, the tab/window close-confirmation policies (Close Confirmation lives on
/// the General page — `launch-option.png`), privacy (redact secrets), and the default pane kind. All
/// fire-time `Defaults.Keys` — applied LIVE. The NOTIFICATION group is NOT here — it's under **Shell**
/// (`notification-setting.png` shows NOTIFICATION + TAB BADGE on the Shell page).
///
/// INTENTIONAL OMISSIONS (pinned, not a regression): a General page could carry an UPDATE group, a Language
/// picker, and a "Quit When All Windows Closed" row. slopdesk drops all three on purpose — Auto-Update and
/// Language are N/A for a single-user, English-only remote-coding tool with no in-app updater, and the
/// quit-policy row has no backing behaviour. Conversely **Privacy & New Panes** (Redact secrets / Default
/// pane kind) is slopdesk-SPECIFIC — deliberately added, not a stray.
private struct GeneralSettingsTab: View {
    /// Fire-time keys aren't in the typed models, so bind the global `Defaults.Keys` directly via `@Default`
    /// (the default lives in the key declaration). General has no typed-model field, so it takes no `store`.
    @Default(.onLaunch) private var onLaunch
    @Default(.closeConfirmTab) private var closeConfirmTab
    @Default(.closeConfirmWindow) private var closeConfirmWindow
    @Default(.redactSecrets) private var redactSecrets
    /// The device-local `followSessionFocus` lives on the `WorkspaceStore`, not in `Defaults` — it is
    /// persisted in `device-prefs.json` (docs/45 §7.3). Injected at the settings root; nil in a preview,
    /// which greys the row on its platform default (`SharedFocusSetting`).
    @Environment(\.workspaceStore) private var workspaceStore
    // The OS Integration "Default Terminal" status, refreshed on appear + after Set.
    // macOS-only — `DefaultTerminalIntegration` is `#if os(macOS)` (no iOS LaunchServices / deep-links).
    #if os(macOS)
    @State private var isDefaultTerminal = false
    #endif

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.general.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshBespokeState() }
    }

    /// One row, by the setting it edits.
    ///
    /// This switch is what does NOT cross, and the reason is worth naming: `$onLaunch` is a `@Default`
    /// property wrapper over `UserDefaults`, so a key can travel but a BINDING cannot. What used to be
    /// the page — headers, order, wording, and which platform sees what — is now
    /// `slopdesk_workspace::settings_layout`; what is left here is a binding lookup and this half's
    /// idea of what a toggle looks like.
    ///
    /// A key with no arm renders NOTHING rather than a dead control, and `SettingsLayoutTests` is what
    /// notices: it walks the same table this does.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.onLaunchKey:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.onLaunch),
                selection: $onLaunch,
            )
        case SettingsKey.closeConfirmTabKey:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.closeConfirmationTab),
                selection: $closeConfirmTab,
            )
        case SettingsKey.closeConfirmWindowKey:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.closeConfirmation),
                selection: $closeConfirmWindow,
            )
        case SettingsKey.redactSecrets:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $redactSecrets)
        case AllSettingsCatalog.followSessionFocusKey:
            SettingsGlyphToggleRow(
                glyph(row),
                row.label,
                row.subtitle,
                isOn: SharedFocusSetting.binding(workspaceStore),
            )
            .disabled(!SharedFocusSetting.isConfigurable(workspaceStore))
        default:
            bespoke(row)
        }
    }

    /// The groups this page draws itself rather than describing — see `SettingsLayout.Control.bespoke`.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control, id == "os-integration" {
            #if os(macOS)
            osIntegrationRows
            #endif
        }
    }

    /// State a bespoke group needs read at display time rather than held in a table.
    private func refreshBespokeState() {
        #if os(macOS)
        isDefaultTerminal = DefaultTerminalIntegration.isDefaultTerminal()
        #endif
    }

    // MARK: - OS Integration (macOS-only, reachable post-first-launch)

    /// Settings → General → OS Integration (`first-launch-default-terminal.png` /
    /// `getting-started__first-launch.md §2`). REUSES the first-launch sheet's rows so behaviour lives in one
    /// place (`DefaultTerminalIntegration`): a Default-Terminal status row (Set / "Default"), the Finder +
    /// Full-Disk-Access deep-links, and the honestly-DISABLED "Default Terminal for Common Apps" row (a
    /// remote-host editor's config can't be rewritten from the client — no dead button).
    /// macOS-only.
    #if os(macOS)
    private var osIntegrationRows: some View {
        Group {
            osIntegrationRow(
                "Default Terminal",
                "Handle `ssh://` links and shell scripts opened from Finder or `open`.",
            ) {
                if isDefaultTerminal {
                    Label("Default", systemImage: "checkmark").foregroundStyle(SettingsInk.ok)
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
                Text("Unavailable").foregroundStyle(SettingsInk.tertiary)
            }
            osIntegrationRow(
                "Finder Integration",
                "Add \u{201C}Open in SlopDesk\u{201D} to Finder's right-click Services menu for folders.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFinderServicesSettings() }
                    .buttonStyle(.bordered)
            }
            osIntegrationRow(
                "Full Disk Access",
                "Needed when commands run inside SlopDesk must read or write protected files. The app works "
                    + "without it.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFullDiskAccessSettings() }
                    .buttonStyle(.bordered)
            }
        }
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
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}

// MARK: - Shell section

/// Shell: the NOTIFICATION + SOUND + CODE AGENT groups and the window/tab/split
/// working-directory policy. `notification-setting.png` (Shell row highlighted) homes NOTIFICATION under
/// Shell (NOT General): the System Permission status row, the master "Allow App Notifications", per-event
/// toggles, the Notify-While-Foreground tri-state picker, and the macOS-only Bounce Dock Icon — all backed by
/// the pure `NotificationPolicy` engine. Working Directory is also Shell's
/// (`spec/user-interface__window-tab-split.md` 66 + 282, `open-option.png`). NOT here: New Tab Position →
/// **Appearance** (`tab-setting.png`); close-confirmation → **General** (`launch-option.png`); title + OSC-52
/// privilege gates → **Advanced**. Each reads a fire-time `Defaults.Key` at the fire-site, so they apply LIVE.
private struct ShellSettingsTab: View {
    // The NOTIFICATION group's keys, backed by the pure `NotificationPolicy` engine — real behaviour,
    // not deferred stubs.
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.notifyOnFinish) private var notifyOnFinish
    @Default(.notifyOnError) private var notifyOnError
    @Default(.notifyOnWatchFinish) private var notifyOnWatchFinish
    @Default(.notifyWhileForeground) private var notifyWhileForeground
    @Default(.bounceDockIcon) private var bounceDockIcon
    // TAB BADGE — the three COMMAND-driven badges, distinct from the Agents page's agent badges.
    @Default(.tabBadgeOnCommandFinish) private var tabBadgeOnCommandFinish
    @Default(.tabBadgeOnCommandFail) private var tabBadgeOnCommandFail
    @Default(.tabBadgeOnCommandAwaitInput) private var tabBadgeOnCommandAwaitInput
    @Default(.tabBadgeBusyDelaySeconds) private var tabBadgeBusyDelaySeconds
    // SOUND — the BEL gate and the error-exit beep.
    @Default(.soundShellControlled) private var soundShellControlled
    @Default(.soundOnErrorExit) private var soundOnErrorExit
    // CODE AGENT (Claude-only). IPC-driven, so no shell integration is needed.
    @Default(.agentNotifyTaskComplete) private var agentNotifyTaskComplete
    @Default(.agentNotifyAwaitInput) private var agentNotifyAwaitInput
    @Default(.agentSoundTaskComplete) private var agentSoundTaskComplete
    @Default(.agentSoundAwaitInput) private var agentSoundAwaitInput
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    #if os(macOS)
    @State private var cliInstaller = CLIInstaller()
    #endif

    /// The two policy choices the picker surfaces. A custom-path policy (set from the config or the
    /// all-settings editor) reads as `home` here; editing the path lands in the raw editor.
    private enum WorkingDirChoice: String, CaseIterable, Identifiable {
        case inherit
        case home
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.shell.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
            .onAppear { cliInstaller.refreshInstalled() }
        #endif
    }

    /// One row, by the setting it edits — see `GeneralSettingsTab.control(_:)` for why the binding is
    /// the half that cannot cross.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.oscNotifications: toggle(row, $oscNotifications)
        case SettingsKey.notifyOnFinish: toggle(row, $notifyOnFinish)
        case SettingsKey.notifyOnError: toggle(row, $notifyOnError)
        case SettingsKey.notifyOnWatchFinish: toggle(row, $notifyOnWatchFinish)
        case SettingsKey.longCommandNotifications: toggle(row, $longCommandNotifications)
        case SettingsKey.bounceDockIcon: toggle(row, $bounceDockIcon)
        case SettingsKey.tabBadgeOnCommandFinish: toggle(row, $tabBadgeOnCommandFinish)
        case SettingsKey.tabBadgeOnCommandFail: toggle(row, $tabBadgeOnCommandFail)
        case SettingsKey.tabBadgeOnCommandAwaitInput: toggle(row, $tabBadgeOnCommandAwaitInput)
        case SettingsKey.soundShellControlled: toggle(row, $soundShellControlled)
        case SettingsKey.soundOnErrorExit: toggle(row, $soundOnErrorExit)
        case SettingsKey.agentNotifyTaskComplete: toggle(row, $agentNotifyTaskComplete)
        case SettingsKey.agentNotifyAwaitInput: toggle(row, $agentNotifyAwaitInput)
        case SettingsKey.agentSoundTaskComplete: toggle(row, $agentSoundTaskComplete)
        case SettingsKey.agentSoundAwaitInput: toggle(row, $agentSoundAwaitInput)
        case SettingsKey.notifyWhileForegroundKey:
            LabeledContent {
                Picker("", selection: $notifyWhileForeground) {
                    ForEach(SettingsCatalog.options(.notifyWhileForeground, as: NotifyWhileForeground.self)) {
                        Text($0.label).tag($0.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } label: {
                glyphLabel(glyph(row), row.label, row.subtitle)
            }
        case SettingsKey.tabBadgeBusyDelaySeconds:
            SettingsSliderRow(
                row.label,
                subtitle: row.subtitle,
                value: $tabBadgeBusyDelaySeconds,
                range: SettingsCatalog.Ladder.busyDelay.range,
                step: SettingsCatalog.Ladder.busyDelay.step,
                presets: SettingsCatalog.Ladder.busyDelay.presets,
                readout: SettingsCatalog.Ladder.busyDelay.readout,
            )
        case SettingsKey.workingDirectoryNewWindowKey: workingDirRow(row, $workingDirNewWindow)
        case SettingsKey.workingDirectoryNewTabKey: workingDirRow(row, $workingDirNewTab)
        case SettingsKey.workingDirectoryNewSplitKey: workingDirRow(row, $workingDirNewSplit)
        default: bespoke(row)
        }
    }

    /// The glyph-toggle shape every boolean row on this page takes.
    private func toggle(_ row: SettingsLayout.Row, _ binding: Binding<Bool>) -> some View {
        SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: binding)
    }

    /// A working-directory row: the shared two-choice picker over one of the three policy keys.
    private func workingDirRow(_ row: SettingsLayout.Row, _ raw: Binding<String>) -> some View {
        Picker(row.label, selection: workingDirBinding(raw)) {
            ForEach(SettingsCatalog.options(.workingDirectory, as: WorkingDirChoice.self)) {
                Text($0.label).tag($0.value)
            }
        }
    }

    /// The groups this page draws itself rather than describing.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control {
            switch id {
            case "notification-permission": NotificationPermissionRow()
            case "cli-install":
                #if os(macOS)
                CLIInstallCardBody(installer: cliInstaller)
                #endif
            default: EmptyView()
            }
        }
    }

    /// Bridge the `WorkingDirectoryPolicy.rawConfig` String key to the two-way picker: `inherit` ↔
    /// `inherit`, everything else (`home` / empty / a custom path) reads as `home` and writes the
    /// canonical rawConfig.
    private func workingDirBinding(_ raw: Binding<String>) -> Binding<WorkingDirChoice> {
        Binding(
            get: { WorkingDirectoryPolicy(rawConfig: raw.wrappedValue) == .inherit ? .inherit : .home },
            set: { raw.wrappedValue = ($0 == .inherit ? WorkingDirectoryPolicy.inherit : .home).rawConfig },
        )
    }
}

// MARK: - System Permission status row (top of the Notification group)

/// The System Permission status row (`terminal-features__notifications.md`, at the TOP of the Notification
/// group): a coloured dot (green = allowed, amber = will-prompt / unknown, red = blocked) + an **Open System
/// Settings** deep-link. The dot DECISION is the pure, headless-pinned
/// ``PermissionStatus/dot(forAuthorization:)``; this view only queries
/// `UNUserNotificationCenter.current().getNotificationSettings` and renders it.
///
/// **iOS caveat (carryover / spec flag):** macOS deep-links to the Notifications pane
/// (`x-apple.systempreferences:com.apple.preference.notifications`); iOS CANNOT deep-link to the per-app OS
/// pane, so the button opens the app's OWN settings via `UIApplication.openSettingsURLString` — macOS
/// deep-link `#if os(macOS)`, iOS fallback `#if os(iOS)`. See docs/DECISIONS.md.
private struct NotificationPermissionRow: View {
    /// The current dot — starts amber (unknown) until the async query resolves, never a false green.
    @State private var dot: PermissionStatus.Dot = .amber
    /// SwiftUI-native URL opener (replaces `NSWorkspace`/`UIApplication.open` for the deep-link below). The
    /// custom `x-apple.systempreferences:` scheme routes through LaunchServices exactly as `NSWorkspace.open` did.
    @Environment(\.openURL) private var openURL

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
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
    }

    private var dotColor: Color {
        switch dot {
        case .green: SettingsInk.ok
        case .amber: SettingsInk.warn
        case .red: SettingsInk.err
        }
    }

    private var dotSubtitle: String {
        switch dot {
        case .green: "Notifications are allowed for slopdesk."
        case .amber: "Notification permission has not been granted yet."
        case .red: "Notifications are blocked — enable them in System Settings."
        }
    }

    /// Query `UNUserNotificationCenter` and map the authorization status through the pure dot decision. Never
    /// instantiated in a test (`PermissionStatusTests` pins the pure mapping) — `current()` traps without a
    /// bundle, the same hang/crash-safety boundary as the video sessions. The `rawValue` Int is extracted
    /// INSIDE the `await` so the non-`Sendable` `UNNotificationSettings` never crosses the actor hop (only the
    /// `Int` does — Swift 6 region isolation).
    private func refresh() async {
        let raw = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue
        dot = PermissionStatus.dot(forAuthorization: raw)
    }

    private func openSystemSettings() {
        // SwiftUI-native `openURL` (was `NSWorkspace`/`UIApplication.open`). The macOS custom scheme routes via
        // LaunchServices; on iOS `UIApplication.openSettingsURLString` is still the URL SOURCE (no SwiftUI
        // equivalent) — only the open ACTION is now `openURL`.
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            openURL(url)
        }
        #elseif os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }
}

// MARK: - Controls section

/// Controls: fire-time toggles + multi-state pickers. The
/// groups mirror `spec/terminal-features__{selection,copy-and-paste,scroll,cursor-and-mouse}.md` +
/// `mouse-option.png`: **Selection**, **Copy & Paste**, **Scroll** (incl. SCROLLBACK depth — the `Settings →
/// Controls → Scroll` home), **Mouse**, **Keyboard** (Undo at Prompt), and the slopdesk-specific **System**
/// dialog-panes toggle. All LIVE — every `Defaults` row re-applies the libghostty config via
/// `refreshTerminalControls()` (the `store.refreshing(_:)` wrapper); the scrollback stepper rebuilds via the
/// `terminal` model's `didSet`. The cursor group is NOT here — it lives under **Appearance**
/// (`cursor-style.png`), hosted by `CursorPreviewView`.
private struct ControlsSettingsTab: View {
    @Bindable var store: PreferencesStore

    // Selection.
    @Default(.shiftArrowSelect) private var shiftArrowSelect
    @Default(.clearSelectionOnTyping) private var clearSelectionOnTyping
    @Default(.clearSelectionOnCopy) private var clearSelectionOnCopy
    // Copy & Paste.
    @Default(.copyOnSelect) private var copyOnSelect
    @Default(.trimTrailingSpacesOnCopy) private var trimTrailingSpacesOnCopy
    @Default(.pasteProtection) private var pasteProtection
    @Default(.pasteBracketedSafe) private var pasteBracketedSafe
    // Scroll.
    @Default(.scrollMultiplier) private var scrollMultiplier
    // Mouse (`mouse-option.png` order).
    @Default(.focusFollowsMouse) private var focusFollowsMouse
    @Default(.rightClickAction) private var rightClickAction
    @Default(.mouseHideWhileTyping) private var mouseHideWhileTyping
    @Default(.allowShiftClick) private var allowShiftClick
    @Default(.clickToMove) private var clickToMove
    @Default(.allowMouseCapture) private var allowMouseCapture
    // Keyboard.
    @Default(.undoAtPrompt) private var undoAtPrompt
    @Default(.optionAsAlt) private var optionAsAlt
    // Links. CLIENT-side link interaction, NOT libghostty config, so these bind DIRECTLY — no
    // `store.refreshing(_:)` terminal-config rebuild.
    @Default(.linkDetection) private var linkDetection
    @Default(.linkCmdClick) private var linkCmdClick
    @Default(.linkCmdShiftClick) private var linkCmdShiftClick
    @Default(.autoDetectLinkSchemes) private var autoDetectLinkSchemes
    @Default(.customLinkSchemes) private var customLinkSchemes
    // Secure Input. The page draws these only on macOS (the table says so); the keys compile and
    // round-trip on both platforms, which is why they need no gate here.
    @Default(.autoSecureInput) private var autoSecureInput
    @Default(.secureInputIndicator) private var secureInputIndicator

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.controls.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
    }

    /// One row, by the setting it edits — see `GeneralSettingsTab.control(_:)` for why the binding is
    /// the half that cannot cross.
    ///
    /// Every toggle here goes through `store.refreshing(_:)`, which is what makes this page's switch
    /// different from Shell's: these are libghostty config, so a change must also re-apply the live
    /// terminal config. That seam is a property of the PAGE, not of the row, so it stays here.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.shiftArrowSelect: toggle(row, $shiftArrowSelect)
        case SettingsKey.clearSelectionOnTyping: toggle(row, $clearSelectionOnTyping)
        case SettingsKey.clearSelectionOnCopy: toggle(row, $clearSelectionOnCopy)
        case SettingsKey.copyOnSelect: toggle(row, $copyOnSelect)
        case SettingsKey.trimTrailingSpacesOnCopy: toggle(row, $trimTrailingSpacesOnCopy)
        case SettingsKey.pasteProtection: toggle(row, $pasteProtection)
        case SettingsKey.pasteBracketedSafe: toggle(row, $pasteBracketedSafe)
        case SettingsKey.focusFollowsMouse: toggle(row, $focusFollowsMouse)
        case SettingsKey.mouseHideWhileTyping: toggle(row, $mouseHideWhileTyping)
        case SettingsKey.clickToMove: toggle(row, $clickToMove)
        case SettingsKey.allowMouseCapture: toggle(row, $allowMouseCapture)
        case SettingsKey.undoAtPrompt: toggle(row, $undoAtPrompt)
        case SettingsKey.autoSecureInput: toggle(row, $autoSecureInput)
        case SettingsKey.secureInputIndicator: toggle(row, $secureInputIndicator)
        // Surfaces as a plain ON/OFF switch (`spec/cursor-and-mouse`), not the leaf enum's 4-way:
        // ON ⇒ ⇧ extends the selection, OFF ⇒ ⇧ is forwarded to the program. The getter projects
        // through `extendsSelection` rather than `== .enabled` so a value left by the removed 4-way
        // picker still reads sanely.
        case SettingsKey.allowShiftClickKey:
            toggle(row, Binding(
                get: { allowShiftClick.extendsSelection },
                set: { allowShiftClick = $0 ? .enabled : .disabled },
            ))
        case SettingsKey.linkDetection:
            Toggle(isOn: $linkDetection) { rowLabel(row.label, row.subtitle) }
        case SettingsKey.rightClickActionKey:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.rightClickAction),
                selection: store.refreshing($rightClickAction),
            )
        case SettingsKey.optionAsAltKey:
            SettingsOptionCards(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.optionAsAlt),
                selection: store.refreshing($optionAsAlt),
            ) { option in
                SettingsOptionKeyArt(mode: option.value)
            }
        case SettingsKey.scrollMultiplier:
            slider(row, store.refreshing($scrollMultiplier), .scrollMultiplier)
        case AllSettingsCatalog.RenderKey.scrollbackLimit:
            slider(row, scrollbackBinding, .scrollback)
        case SettingsKey.linkCmdClickKey: linkMenu(row, .linkCmdClick, $linkCmdClick)
        case SettingsKey.linkCmdShiftClickKey: linkMenu(row, .linkCmdShiftClick, $linkCmdShiftClick)
        case SettingsKey.autoDetectLinkSchemesKey:
            linkMenu(row, .autoDetectLinkSchemes, $autoDetectLinkSchemes)
        // Drawn only while the mode above is Custom — a condition on another setting's VALUE, which
        // is dynamic rather than layout, so the table lists the row and the page decides.
        case SettingsKey.customLinkSchemes:
            if autoDetectLinkSchemes == .custom {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    rowLabel(row.label, row.subtitle)
                    TextField("codex, ssh, vscode", text: customSchemesText)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsType.mono)
                }
            }
        default:
            if case .note = row.control {
                Text(row.subtitle)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
            }
        }
    }

    // MARK: - Row shapes

    /// A toggle row through the `store.refreshing(_:)` seam, so the change re-applies the live
    /// terminal config. A row whose meaning no icon improves still lands on the icon RAIL, so a
    /// twenty-switch page stays scannable.
    private func toggle(_ row: SettingsLayout.Row, _ binding: Binding<Bool>) -> some View {
        SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: store.refreshing(binding))
    }

    private func slider(
        _ row: SettingsLayout.Row, _ value: Binding<Double>, _ ladder: SettingsCatalog.Ladder,
    ) -> some View {
        SettingsSliderRow(
            row.label,
            subtitle: row.subtitle,
            value: value,
            range: ladder.range,
            step: ladder.step,
            presets: ladder.presets,
            readout: ladder.readout,
        )
    }

    /// A dropdown for a CLIENT-side link knob: binds DIRECTLY, with no `store.refreshing(_:)` hop,
    /// because the link knobs are not libghostty config.
    private func linkMenu<Value: RawRepresentable & Hashable & Sendable>(
        _ row: SettingsLayout.Row, _ group: SettingsCatalog.Group, _ selection: Binding<Value>,
    ) -> some View where Value.RawValue == String {
        LabeledContent {
            Picker("", selection: selection) {
                ForEach(SettingsCatalog.options(group, as: Value.self)) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            rowLabel(row.label, row.subtitle)
        }
    }

    /// Bridge the `[String]` custom-schemes key to a comma / space / newline separated field (each
    /// token trimmed, empties dropped). The setter persists the parsed list straight into `Defaults`.
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

    /// Bridge the `scrollbackLines` Int model field to the slider's `Double`. Rounded (never
    /// truncated) so a float-stepped drag cannot land one line BELOW the stop it visually snapped to
    /// — and written straight to `store.terminal`, whose `didSet` rebuilds the libghostty config.
    private var scrollbackBinding: Binding<Double> {
        Binding(
            get: { Double(store.terminal.scrollbackLines) },
            set: { store.terminal.scrollbackLines = Int($0.rounded()) },
        )
    }
}

// MARK: - Editor section (RESERVED — deferred)

/// Editor is RESERVED/empty by design — meant to eventually configure a built-in FILE-editor (Soft Wrap /
/// Line Numbers / Whitespace / Tab Size / Scroll Past Last Line / Default-to-Preview —
/// `docs/ui-shell/screenshots/editor-settings.png`). slopdesk has no file editor, so there are NO settings
/// here. Deliberately NOT backfilled with terminal-render prefs — those live elsewhere (FONT + CURSOR →
/// Appearance; SCROLLBACK → Controls). Kept in the taxonomy (pinned by `SettingsSectionTaxonomyTests`) as a
/// placeholder so the navigator stays complete; fills in when a file-pane editor lands.
private struct EditorSettingsTab: View {
    var body: some View {
        Form {
            slateFormSection("Editor") {
                // A RESERVED page states its own emptiness in the empty-state voice (MERIDIAN C3: muted
                // symbol, short title, one-line cause) rather than as a "File editor — Not available" row,
                // which read like a broken control. Local to this page, NOT a new `SlateEmptyState.Cause`:
                // that enum's typed causes are the pane area's connection states, with pinned copy per case.
                VStack(spacing: Slate.Metric.space2) {
                    Image(systemSymbol: .textDocument)
                        .font(SettingsType.placeholderGlyph)
                        .foregroundStyle(SettingsInk.tertiary)
                    Text("No File Editor Yet")
                        .font(SettingsType.body.weight(.semibold))
                    Text(
                        "Soft Wrap, Line Numbers, and Tab Size configure a built-in file editor slopdesk "
                            + "does not have. Terminal font and cursor live under Appearance; scrollback "
                            + "under Controls.",
                    )
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Slate.Metric.space4)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance section

/// Appearance, rendered from `settings_layout`'s table: the TABS group (New Tab Position —
/// `tab-setting.png` shows it here, NOT Shell), the macOS WINDOW group, the density tier, the terminal
/// FONT (family + size) and CURSOR (style + blink) — font/cursor belong here, not the Editor/Controls
/// tabs, per `font-setting.png` / `cursor-style.png` — and the Dock icon toggles. All LIVE (font/cursor
/// rebuild the libghostty config string and bump `TerminalConfigBroadcaster`; New Tab Position + chrome
/// toggles are read at fire-time / next render).
///
/// Two absences are DECISIONS, not gaps: there is no LAYOUT selector (Vertical Tabs / Tabs Top / Tabs
/// Bottom) because slopdesk is vertical-tabs-only, and no THEME gallery because the app ships ONE
/// appearance (user-directed 2026-08-08). Either would be a control with a single actuatable state.
///
/// This is the page where the halves diverge in three ways at once, which is what makes it the sharpest
/// case for a platform gate being data: groups the phone omits (Window, Dock Icon), groups both draw
/// identically (Tabs, Appearance), and one position where each half draws a DIFFERENT thing for the same
/// two settings — the Mac's live caret preview against the phone's two plain rows.
private struct AppearanceSettingsTab: View {
    @Bindable var store: PreferencesStore

    @Default(.newTabPosition) private var newTabPosition
    @Default(.paneSwitcherPreview) private var paneSwitcherPreview
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    // The `window.*`, `desktopWindow.*` and `satelliteWindow.*` keys are declared on BOTH platforms
    // and round-trip on both, so they need no gate here — the table is what says only the Mac draws
    // them, and it says so once.
    @Default(.windowSize) private var windowSize
    @Default(.windowCols) private var windowCols
    @Default(.windowRows) private var windowRows
    @Default(.windowWidthPx) private var windowWidthPx
    @Default(.windowHeightPx) private var windowHeightPx
    @Default(.desktopWindowPresentation) private var desktopWindowPresentation
    @Default(.satelliteBackgroundPointer) private var satelliteBackgroundPointer
    @Default(.dockIconAnimateProgress) private var dockIconAnimateProgress
    @Default(.dockIconErrorBadge) private var dockIconErrorBadge

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.appearance.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
    }

    /// One row, by the setting it edits — see `GeneralSettingsTab.control(_:)` for why the binding is
    /// the half that cannot cross.
    ///
    /// Two rows here are conditional, and on the same thing: the grid steppers are drawn only in Grid
    /// mode and the frame steppers only in Frame mode. That is a condition on another setting's VALUE
    /// — dynamic rather than layout — so the table lists all four and the page picks the pair.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.newTabPositionKey:
            cards(row, .newTabPosition, $newTabPosition) { SettingsTabPositionArt(position: $0) }
        case SettingsKey.paneSwitcherPreview:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $paneSwitcherPreview)
        case SettingsKey.autoHideTabsPanelKey:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.autoHideTabsPanel),
                selection: $autoHideTabsPanel,
            )
        case SettingsKey.windowSizeKey:
            cards(row, .windowSize, $windowSize) { windowSizeArt($0) }
        case SettingsKey.windowColsKey: if windowSize == .grid { stepper(row, $windowCols) }
        case SettingsKey.windowRowsKey: if windowSize == .grid { stepper(row, $windowRows) }
        case SettingsKey.windowWidthPxKey: if windowSize == .frame { stepper(row, $windowWidthPx) }
        case SettingsKey.windowHeightPxKey: if windowSize == .frame { stepper(row, $windowHeightPx) }
        case SettingsKey.desktopWindowPresentationKey:
            cards(row, .desktopPresentation, $desktopWindowPresentation) { desktopPresentationArt($0) }
        case SettingsKey.satelliteBackgroundPointerKey:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $satelliteBackgroundPointer)
        case SettingsKey.density:
            SettingsOptionCards(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.stringOptions(.density),
                selection: densityBinding,
            ) { option in
                SettingsDensityArt(compact: option.value == SettingsCatalog.densityCompact)
            }
        case SettingsKey.dockIconAnimateProgress:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $dockIconAnimateProgress)
        case SettingsKey.dockIconErrorBadge:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $dockIconErrorBadge)
        // The two cursor settings, as the PHONE draws them. The Mac reaches the same pair through the
        // live preview surface below, which is why neither half is missing a capability.
        case AllSettingsCatalog.RenderKey.cursorStyle:
            SettingsOptionCards(
                row.label,
                options: SettingsCatalog.options(.cursorStyle),
                selection: $store.terminal.cursorStyle,
            ) { option in
                SettingsCaretArt(style: option.value, color: SettingsInk.primary)
            }
        case AllSettingsCatalog.RenderKey.cursorStyleBlink:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.cursorBlink),
                selection: $store.terminal.cursorBlink,
            )
        default: bespoke(row)
        }
    }

    /// The groups this page draws itself rather than describing — see `SettingsLayout.Control.bespoke`.
    /// Both are whole surfaces with their own headers, which is why their groups carry no title.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control {
            switch id {
            // The Font-Family scope tabs, "Aa" specimen combobox, per-face families, size,
            // line-height, ligatures and the bold/italic/underline controls (`font-setting.png`).
            case "font": FontSettingsView(store: store)
            // The live caret preview with its colour wells and text-under toggle (`cursor-style.png`)
            // — AppKit, hence the gate, which dies with the AppKit port.
            case "cursor-preview":
                #if os(macOS)
                CursorPreviewView(store: store)
                #endif
            default: EmptyView()
            }
        }
    }

    // MARK: - Row shapes

    /// An illustrated radio group over a catalog group, with the art the page draws per option.
    private func cards<Value: RawRepresentable & Hashable & Sendable>(
        _ row: SettingsLayout.Row,
        _ group: SettingsCatalog.Group,
        _ selection: Binding<Value>,
        @ViewBuilder art: @escaping (Value) -> some View,
    ) -> some View where Value.RawValue == String {
        SettingsOptionCards(
            row.label,
            subtitle: row.subtitle,
            options: SettingsCatalog.options(group),
            selection: selection,
        ) { option in
            art(option.value)
        }
    }

    /// A plus/minus numeric field over the row's own range. The value's UNIT rides the range's
    /// readout (`1000 px`), so "Width" and "Columns" are told apart by their label alone.
    @ViewBuilder
    private func stepper(_ row: SettingsLayout.Row, _ value: Binding<Int>) -> some View {
        if case let .stepper(range) = row.control {
            Stepper(
                "\(row.label): \(range.readout(value.wrappedValue))",
                value: value,
                in: range.range,
                step: range.step,
            )
        }
    }

    private var densityBinding: Binding<String> {
        Binding(
            get: { store.appearance.density ?? SettingsCatalog.densityComfortable },
            set: { store.appearance.density = $0 },
        )
    }

    /// The card art per window-size mode: the UNIT each mode measures in.
    private func windowSizeArt(_ mode: WindowSizeMode) -> some View {
        SettingsWindowArt(fills: false, titled: true) {
            switch mode {
            case .remember: SettingsRememberArt()
            case .grid: SettingsGridArt()
            case .frame: SettingsPixelArt()
            }
        }
    }

    /// The card art per desktop presentation. `fills` shows the window's relationship to the screen bezel;
    /// `titled` is the one mark that separates native fullscreen from a borderless cover.
    private func desktopPresentationArt(_ kind: DesktopWindowPresentation) -> some View {
        SettingsWindowArt(fills: kind != .window, titled: kind != .borderless) {
            EmptyView()
        }
    }
}

// MARK: - Agents section

/// Agents: the CLAUDE CODE install-hooks card (install/uninstall + status row, via the host
/// metadata channel), the host-side agent-detection flags (belong here rather than Video — host-read, so
/// reconnect), plus layout-auto-switch and clipboard-history fire-time toggles (LIVE). **Claude Code only**:
/// NO codex/opencode card — `MetadataCodec.AgentKind.codex` is documented-dead, never rendered.
private struct AgentsSettingsTab: View {
    @Bindable var store: PreferencesStore

    /// The install-hooks model, injected by the app scene (seams target the active connection's
    /// first-pane ``MetadataClient``). `nil` outside the app scene (previews / iOS sheet pre-wiring) → the card
    /// renders disabled ("Connect a session") rather than crashing.
    @Environment(\.agentHooksController) private var agentHooks

    @Default(.recordClipboardHistory) private var recordClipboardHistory

    // The "Agent Behaviour" toggles. badge×3 + notify×2 are fire-time `Defaults.Keys` (apply
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

            // "Agent detection (host)" is gone. It held two switches — the foreground-process watch
            // and the Claude hooks — over the machinery that tells you what the agent in a pane is
            // doing, which is what this product is for. Neither had an OFF worth offering; both are
            // now unconditional. What remains a choice is INSTALLING the hooks into the user's own
            // `~/.claude/settings.json`, which the Claude Code card above owns.
            agentBehaviorSection
            agentBehaviorHostSection

            slateFormSection("Behaviour") {
                Toggle("Record clipboard history", isOn: $recordClipboardHistory)
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
        // Re-probe the host install state on each open (per spec — not cached forever); `.task` re-fires when
        // the Agents tab re-appears and auto-cancels on disappear.
        .task { await agentHooks?.refresh() }
    }

    // MARK: Agent Behaviour (badge×3 + notify×2, greyed until an integration is installed)

    /// The "Agent Behaviour" badge/notify toggles (apply LIVE). Greyed out until at least one
    /// integration is installed (``behaviorEnabled``); Claude-only. The badge toggles drive the GLOBAL
    /// ``AgentBadgeGates`` default the sidebar applies (a per-pane override lives on the tab context-menu).
    private var agentBehaviorSection: some View {
        slateFormSection("Agent Behaviour") {
            SettingsGlyphToggleRow(
                .circleDashed, "Badge While Processing",
                "Ring the tab while the agent is working.", isOn: $agentBadgeWhileProcessing,
            )
            SettingsGlyphToggleRow(
                .checkmarkCircle, "Badge When Task Completes",
                "Mark the tab when the agent goes idle.", isOn: $agentBadgeWhenComplete,
            )
            SettingsGlyphToggleRow(
                .handRaised, "Badge When Awaiting Input",
                "Mark the tab when the agent needs approval.", isOn: $agentBadgeWhenAwaitingInput,
            )
            SettingsGlyphToggleRow(
                .bell, "Notify When Task Completes", isOn: $agentNotifyTaskComplete,
            )
            SettingsGlyphToggleRow(
                .bellBadge, "Notify When Awaiting Input", isOn: $agentNotifyAwaitInput,
            )
            if !behaviorEnabled {
                Text("Install an integration above to configure agent behaviour.")
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.tertiary)
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
                    "Add slopdesk hooks to ~/.claude/settings.json for real-time state updates",
                )
            }

            LabeledContent("Status") { statusBadge(state) }

            if state == .disconnected || state == .unknown {
                Text("Connect a session to manage hooks")
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.tertiary)
            }

            // installed-but-INACTIVE — hooks are in settings.json but the host daemon's hook listener isn't
            // bound, so every hook exits silently and no live agent states (or prompt-queue turn signals)
            // arrive. There is no toggle to blame any more (the listener binds unconditionally), so this
            // now means the bind FAILED or the host predates it. Show the fix, not a green check over a
            // dead integration.
            if state == .installedInactive {
                Text(
                    "Hooks are installed but the host isn't listening — its socket failed to bind, or "
                        + "the host daemon is an older build. Restart it, then open new panes.",
                )
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.warn)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Install/uninstall write the host file LIVE, but Claude re-reads settings.json only on next launch
            // — an agent-restart caveat, not a host-reconnect sidecar flag (hence a plain caption, not the
            // `.reconnect` chip, which would mislead).
            Text("Hooks take effect after the agent restarts.")
                .font(SettingsType.caption)
                .foregroundStyle(SettingsInk.tertiary)
        }
    }

    /// The trailing pill buttons for the Install Hooks row, keyed on the install state. While a write is in
    /// flight a small spinner replaces the buttons; while disconnected/unknown the Install button shows
    /// disabled (honest — never a dead-looking enabled button with no backing pane).
    private func installButtons(_ state: AgentHooksController.InstallState) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            switch state {
            case .installed,
                 .installedInactive: // the entries are on disk either way — Uninstall stays actionable
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

    /// The Status-row trailing badge: a green "✓ Installed" (ONLY when the listener is live) / an amber
    /// "Installed — inactive" warning / gray "Not Installed" / neutral "Working…" / "—" by state.
    @ViewBuilder
    private func statusBadge(_ state: AgentHooksController.InstallState) -> some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark")
                .foregroundStyle(SettingsInk.ok)
        case .installedInactive:
            Label("Installed — inactive", systemImage: "exclamationmark.triangle")
                .foregroundStyle(SettingsInk.warn)
        case .notInstalled:
            Text("Not Installed").foregroundStyle(SettingsInk.secondary)
        case .working:
            Text("Working…").foregroundStyle(SettingsInk.secondary)
        case .disconnected,
             .unknown:
            Text("—").foregroundStyle(SettingsInk.tertiary)
        }
    }

    /// The row label layout: a bold title with an optional gray subtext beneath (mirrors the Appearance tab's
    /// `rowLabel`, kept local so the Agents card composes without widening that struct's visibility).

    private func optionalBoolToggle(_ title: String, _ binding: Binding<Bool?>) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil },
        )) { Text(title) }
    }
}

// MARK: - Agents card state derivation (the ONE nil-controller fallback, shared + testable)

/// The Agents card's derived state from the (optional) injected ``AgentHooksController`` — the ONE place the
/// nil-controller fallbacks live, so the macOS scene and iOS ``SettingsSheet`` derive the card identically. A
/// `nil` controller (no injection — e.g. the iOS-sheet wiring this regression fixes) MUST fall back to
/// ``AgentHooksController/InstallState/disconnected`` + behaviour-disabled, NEVER a false live card. Pure +
/// cross-platform, unit-pinned headlessly (`AgentSettingsCardWiringTests`).
@MainActor
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

// MARK: - Agents settings-card environment slot

extension EnvironmentValues {
    /// The single app-owned ``AgentHooksController``, injected at the Settings scene root so the
    /// Agents card reaches it. `nil` outside the app scene (previews / the iOS sheet before its wiring lands)
    /// → the card renders disabled rather than crashing.
    @Entry var agentHooksController: AgentHooksController?
}

package extension View {
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

/// The power-user raw `SLOPDESK_*` override box, folded LAST into the env overlay (so a typed raw key beats
/// the matching typed pref); a precedence note makes clear a REAL process env var still wins over the whole
/// overlay. The Video HOST flags (QP/FEC/pacer/sharpen) have no dedicated section, so they fold in here as a
/// "Video (host)" sub-section — real functionality, reconnect-tagged + symmetric-FEC-warned.
private struct AdvancedSettingsTab: View {
    @Bindable var store: PreferencesStore
    /// The shared navigator selection — threaded into the All-Settings list so a ✎ jump can repoint it.
    @Binding var selectedSection: SettingsSection

    // Privilege surface (terminal-features__notifications.md → Settings → Advanced). Cross-platform
    // — these gate what a remote OSC sequence may do client-side, so they apply on macOS AND iOS.
    @Default(.titleShellControlled) private var titleShellControlled
    @Default(.clipboardShellControlled) private var clipboardShellControlled
    @Default(.clipboardRead) private var clipboardRead
    @Default(.clipboardWrite) private var clipboardWrite

    #if os(macOS)
    /// Local edit buffer of `key = value` lines; committed into `store.rawOverrides` on change. macOS-only:
    /// the raw `SLOPDESK_*` editor is a HOST-side concern, so the compact iOS sheet omits it.
    @State private var text: String = ""
    #endif

    var body: some View {
        Form {
            privilegesSection

            // The raw `SLOPDESK_*` editor + Video HOST flags are macOS-host-relevant, so the iOS sheet
            // omits them; the cross-platform All-Settings list below still reaches iOS.
            #if os(macOS)
            slateFormSection("Raw overrides") {
                Text(
                    "One SLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
                )
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                TextEditor(text: $text)
                    .font(SettingsType.monoSubtitle)
                    .frame(minHeight: 120)
                    .onChange(of: text) { _, new in commit(new) }
                HStack(spacing: Slate.Metric.space1) {
                    Image(systemSymbol: .infoCircle)
                    Text("A real environment variable set on the process still wins over any value here.")
                }
                .font(SettingsType.caption)
                .foregroundStyle(SettingsInk.tertiary)
            }

            VideoHostSettingsView(store: store)

            configFileSection
            #endif

            // The searchable All Settings list + Reset-All / Reset-Advanced. Pure SwiftUI, so the iOS sheet
            // shows it too. `onAfterReset` clears the local raw-overrides buffer so the box reflects the
            // cleared store (a no-op on iOS, where the buffer doesn't exist).
            AllSettingsListView(
                store: store, selectedSection: $selectedSection, onAfterReset: { clearRawOverridesBuffer() },
            )
        }
        .formStyle(.grouped)
        #if os(macOS)
            .onAppear { text = Self.render(store.rawOverrides) }
        #endif
    }

    // MARK: - Privileges (title gates + OSC-52 master + read/write tri-state)

    /// The privilege surface (Settings → Advanced, `terminal-features__notifications.md`): the title gate +
    /// the OSC-52 master switch + read/write tri-state pickers. The pickers are DISABLED while the master is
    /// off (the whole OSC-52 path resolves to Deny).
    private var privilegesSection: some View {
        slateFormSection("Privileges") {
            Toggle(isOn: $titleShellControlled) {
                privilegeLabel(
                    settingLabel(SettingsKey.titleShellControlled),
                    "Allow programs to set the tab and window title via OSC 0 / OSC 2.",
                )
            }
            Toggle(isOn: store.refreshing($clipboardShellControlled)) {
                privilegeLabel(
                    settingLabel(SettingsKey.clipboardShellControlled),
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
            Picker("", selection: store.refreshing(selection)) {
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
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Clear the local raw-overrides edit buffer after a reset. macOS-only buffer → a no-op on iOS.
    private func clearRawOverridesBuffer() {
        #if os(macOS)
        text = ""
        #endif
    }

    // MARK: - Config File (settings import/export)

    /// Settings → Advanced → CONFIG FILE group: the resolved config path + "Open Config File" + "Reload
    /// Config". macOS-only — the config file lives under `~/.config`, inaccessible on iOS. "Open Config File"
    /// creates the parent dir + the file (if absent) then opens it in the default editor, so a fresh install
    /// lands usable. "Reload Config" mirrors the CLI `config reload`: `reapplyLiveSettings()` + the
    /// config-reload broadcast.
    #if os(macOS)
    private var configFileSection: some View {
        slateFormSection("Config File") {
            LabeledContent("Config path") {
                // `resolvePath(override:nil)` respects `SLOPDESK_CONFIG_FILE` env override so the
                // displayed path always matches the file the app actually honours (not just the XDG default).
                Text(CLIConfig.resolvePath(override: nil))
                    .font(SettingsType.monoSubtitle)
                    .foregroundStyle(SettingsInk.secondary)
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
                    ExternalOpen.url(url)
                }
                .buttonStyle(.bordered)
                Button("Reload Config") {
                    // Mirror the CLI `config reload` action exactly (same as WorkspaceControlBackend.configReload).
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

/// The Video / FEC / pacer host flags, folded into Advanced (no dedicated Video section). Read by the HOST
/// daemon at launch and shipped via the `video-prefs.json` sidecar, so labelled "applies on reconnect"; the
/// SYMMETRIC FEC keys add a "set on both ends" warning. Client-side `sharpen` is the one live field. Body
/// returns a `Group` of `Section`s so the host `Form` (Advanced) renders them inline.
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
                optionalIntStepper("Group size (k)", $store.video.fecK, range: 1...32, default: 5)
                HStack(spacing: Slate.Metric.space1) {
                    Image(systemSymbol: .exclamationmarkTriangleFill)
                    Text("FEC must be set IDENTICALLY on both ends or the host and client disagree.")
                }
                .font(SettingsType.caption)
                .foregroundStyle(SettingsInk.warn)
                timingFooter(.reconnect)
            }

            slateFormSection("Video · Pacer (client present)") {
                Picker("Mode", selection: pacerBinding) {
                    Text("Default (on arrival)").tag(VideoPreferences.Pacer?.none)
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
                Text("\(value)").foregroundStyle(SettingsInk.secondary)
            } else {
                Text("default").foregroundStyle(SettingsInk.tertiary)
                    .font(SettingsType.subtitle)
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
#endif
