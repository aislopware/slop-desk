// SettingsView — the SwiftUI Settings surface (REBUILD-V2, WS-D / D4; E7 9-section taxonomy).
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
// E7 reorg: the old 5-tab strip (General / Terminal / Video / Keybindings / Advanced) → an 8-section taxonomy
// (`SettingsSection`): General / Shell / Controls / Editor / Agents / Appearance / Key Bindings / Advanced.
// Groups relocate to the section the screenshots prove: FONT (family + size) + CURSOR (style + blink) →
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
// sheet (WI-5) can host the same section structs.
//
// DEFERRED vs LIVE-APPLY: each section carries an `ApplyTiming` chip (`.live` = immediate; `.reconnect` = a
// HOST-read sidecar flag, effective on the next host connection). Terminal + appearance + keybindings + the
// fire-time toggles are live; the video/agent HOST flags are reconnect-only; SYMMETRIC keys (FEC) also carry
// a "set on both ends" warning.
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskCLICore
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Settings scene (stock SwiftUI, ⌘,)

/// The stock `Settings` scene wrapper, wired in `SlopDeskClientApp`. Stock (not an in-window panel) because
/// the main window hides its titlebar and the overlay host isn't mounted yet (see file header). macOS-only:
/// the `Settings` scene is unavailable on iOS (its settings surface lands as an in-app sheet later);
/// `SettingsView` stays cross-platform so iOS can host it.
#if os(macOS)
public struct SlopDeskSettingsScene: Scene {
    private let store: PreferencesStore
    /// E13 WI-2: the app-owned Agents install-hooks model, injected so the card's Install/Uninstall/Status
    /// round-trips reach the host. Optional — a preview/future host can omit it (card then renders the
    /// disabled "Connect a session" state).
    private let agentHooks: AgentHooksController?

    public init(
        store: PreferencesStore,
        agentHooks: AgentHooksController? = nil,
    ) {
        self.store = store
        self.agentHooks = agentHooks
    }

    public var body: some Scene {
        Settings {
            SettingsView(store: store)
                .agentHooksController(agentHooks)
                // Native chrome → SYSTEM accent (not the theme accent) so toggles/steppers/radios read as
                // native System-Settings controls; appearance still tracks the theme below.
                .tint(nil)
                .preferredColorScheme(Slate.colorScheme)
        }
    }
}
#endif

// MARK: - Settings taxonomy (the 8 sections — one source for the macOS navigator + the iOS list)

/// The settings taxonomy — 8 sections, each an icon+label row in the macOS navigator (and, once WI-5 lands,
/// an iOS-sheet row). Title + `systemImage` live here as the ONE source so the macOS and (future) iOS lists
/// never drift; `SettingsSectionTaxonomyTests` pins the set + order against a drop/reorder/icon-swap. Order +
/// glyphs mirror `docs/ui-shell/screenshots/all-settings.png`: General, Shell, Controls, Editor, Agents,
/// Appearance, Key Bindings, Advanced.
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

    /// The navigator row label (and iOS row title).
    var title: String {
        switch self {
        case .general: "General"
        case .shell: "Shell"
        case .controls: "Controls"
        case .editor: "Editor"
        case .agents: "Agents"
        case .appearance: "Appearance"
        case .keybindings: "Key Bindings"
        case .advanced: "Advanced"
        }
    }

    /// The sidebar glyph (SF Symbol name). Controls = `cursorarrow` mirrors the pointer glyph beside
    /// "Controls" in `all-settings.png` (input/scroll/pointer settings).
    var systemImage: String {
        switch self {
        case .general: "exclamationmark.circle"
        case .shell: "terminal"
        case .controls: "cursorarrow"
        case .editor: "doc.text"
        case .agents: "powerplug"
        case .appearance: "paintpalette"
        case .keybindings: "bolt"
        case .advanced: "wrench"
        }
    }

    /// macOS-only sections are dropped from the compact iOS sheet (WI-5). Only **Keybindings** qualifies: its
    /// chord CAPTURE is a macOS `NSEvent` monitor (`KeyCaptureMonitor` is `#if os(macOS)`), with no iOS
    /// capture UI. Advanced's macOS-HOST-only *rows* (raw `SLOPDESK_*` editor + Video host flags) are gated
    /// INSIDE `AdvancedSettingsTab`, not by hiding the section, so the All-Settings list still reaches iOS.
    /// `SettingsSheet` filters `allCases` on this; `SettingsSectionTaxonomyTests` pins Keybindings as the only one.
    var isMacOSOnly: Bool {
        switch self {
        case .keybindings: true
        default: false
        }
    }
}

// MARK: - Apply-timing tag (deferred vs live, surfaced as a chip not prose)

/// When a setting takes effect — surfaced as a chip so the deferred/live distinction is a DATA attribute,
/// not prose (D4).
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

/// The Settings body: a two-column layout — a left navigator (search pill + icon+label section rows) and the
/// selected section's content on the right. Section set + order + icons come from `SettingsSection` so the
/// navigator can't drift from the pinned taxonomy.
struct SettingsView: View {
    @Bindable var store: PreferencesStore

    /// The selected section — also bound into ``SettingsSectionContent`` so the Advanced All-Settings list's
    /// ✎ jump buttons can repoint the navigator to the owning section (WI-3).
    @State private var selectedSection: SettingsSection = .general

    /// The SIDEBAR search pill query — narrows which SECTION ROWS show. DISTINCT from the Advanced →
    /// All-Settings content search (`AllSettingsListView`, which narrows the config-KEY list); both show at
    /// once. Plain case-insensitive substring match over section titles.
    @State private var sidebarQuery: String = ""

    var body: some View {
        // NATIVE macOS settings chrome: a `NavigationSplitView` with a system `List(selection:)` sidebar +
        // native `.searchable` and the `Form`-based section content as detail — instead of a bespoke
        // two-column `HStack` + custom `SettingsSidebarRow` buttons. Window appearance is pinned to the active
        // theme so native controls render consistently with the workspace (the scene also applies
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
            // A Settings window has a FIXED navigator (like macOS System Settings) — drop the sidebar-collapse
            // toggle macOS auto-adds. Collapsing would leave no way to switch sections.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 480)
        #if os(macOS)
            // Pin the Settings NSWindow to the theme appearance (macOS only — iOS has no NSWindow; its settings
            // surface is `SettingsSheet`, which adopts `.preferredColorScheme` directly).
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
/// Pins the Settings `NSWindow`'s appearance to the active Slate theme so native chrome + AppKit-hosted
/// controls match the workspace, not the OS default. `isLight` is passed IN (from `Slate.theme.isLight` in
/// `SettingsView.body`), so a live theme switch re-renders → re-runs `updateNSView` → re-pins, with NO
/// `NotificationCenter` observer to leak. The scene's `.preferredColorScheme` covers the SwiftUI side; this
/// covers the window itself.
private struct SettingsWindowAppearancePinner: NSViewRepresentable {
    let isLight: Bool
    func makeNSView(context _: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.window?.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
    }
}
#endif

// MARK: - Shared per-section content (one dispatch for the macOS navigator + the iOS sheet)

/// Resolves a ``SettingsSection`` to its per-section body — the ONE place the section → struct mapping lives,
/// so the macOS navigator (`SettingsView`) and iOS `SettingsSheet` (WI-5) render byte-identical content. The
/// per-section structs stay `private`; this `internal` view lets the iOS sheet (a separate file) reach them
/// without widening their visibility. `selectedSection` threads the navigator selection so the Advanced
/// All-Settings ✎ jump can repoint it (a no-op on iOS, where the jump is deferred — WI-3).
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

/// The General-page SECTION group headers, in render order, as a PURE source list so the body can't drift
/// from a headless taxonomy pin (`GeneralSectionLayoutTests`). macOS appends **OS Integration** — the E20 M1
/// home for Default Terminal / Finder Integration / Full Disk Access (`first-launch-default-terminal.png`,
/// `spec/getting-started__first-launch.md §2`). iOS OMITS it: the LaunchServices registration +
/// System-Settings deep-links are `#if os(macOS)` (`DefaultTerminalIntegration`), no iOS handler.
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

/// General: On-Launch behaviour (O1), the tab/window close-confirmation policies (Close Confirmation lives on
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
    @Default(.defaultPaneKind) private var defaultPaneKind
    // E20 M1 (ES-E20-4): the OS Integration "Default Terminal" status, refreshed on appear + after Set.
    // macOS-only — `DefaultTerminalIntegration` is `#if os(macOS)` (no iOS LaunchServices / deep-links).
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

            // OS Integration (E20 M1) — macOS-only. Reuses the SAME `DefaultTerminalIntegration` actions as
            // the first-launch sheet, so the buttons stay REACHABLE after "Skip Setup" (the bug this fixes).
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
    /// `getting-started__first-launch.md §2`). REUSES the first-launch sheet's rows so behaviour lives in one
    /// place (`DefaultTerminalIntegration`): a Default-Terminal status row (Set / "Default"), the Finder +
    /// Full-Disk-Access deep-links, and the honestly-DISABLED "Default Terminal for Common Apps" row (a
    /// remote-host editor's config can't be rewritten from the client — E20 exclusion §4 / no dead button).
    /// macOS-only.
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

/// Shell: the NOTIFICATION + SOUND + CODE AGENT groups (E14/K9-K11) and the window/tab/split
/// working-directory policy. `notification-setting.png` (Shell row highlighted) homes NOTIFICATION under
/// Shell (NOT General): the System Permission status row, the master "Allow App Notifications", per-event
/// toggles, the Notify-While-Foreground tri-state picker, and the macOS-only Bounce Dock Icon — all backed by
/// the pure `NotificationPolicy` engine (WI-4). Working Directory is also Shell's
/// (`spec/user-interface__window-tab-split.md` 66 + 282, `open-option.png`). NOT here: New Tab Position →
/// **Appearance** (`tab-setting.png`); close-confirmation → **General** (`launch-option.png`); title + OSC-52
/// privilege gates → **Advanced**. Each reads a fire-time `Defaults.Key` at the fire-site, so they apply LIVE.
private struct ShellSettingsTab: View {
    // NOTIFICATION group (notification-setting.png). Backed by the pure `NotificationPolicy` engine (E14/K9,
    // WI-4) — real behaviour, not deferred stubs.
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
    @Default(.tabBadgeBusyDelaySeconds) private var tabBadgeBusyDelaySeconds
    // SOUND group (Shell). BEL → NSSound.beep() gate + error-exit beep (E14/K10).
    @Default(.soundShellControlled) private var soundShellControlled
    @Default(.soundOnErrorExit) private var soundOnErrorExit
    // CODE AGENT group (Claude-only — E14 scope exclusion). IPC-driven, no shell integration needed.
    @Default(.agentNotifyTaskComplete) private var agentNotifyTaskComplete
    @Default(.agentNotifyAwaitInput) private var agentNotifyAwaitInput
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    // E20 WI-9: the "SlopDesk CLI" card (Install CLI / Omit Prefix / Allow Overwrite). macOS-only — the
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

            // Working Directory's Shell home is spec-confirmed: `spec/user-interface__window-tab-split.md`
            // ("Settings → Shell → Working Directory" + `open-option.png`) places it on the Shell page.
            slateFormSection("Working Directory") {
                Picker("New window", selection: workingDirBinding($workingDirNewWindow)) { workingDirOptions }
                Picker("New tab", selection: workingDirBinding($workingDirNewTab)) { workingDirOptions }
                Picker("New split", selection: workingDirBinding($workingDirNewSplit)) { workingDirOptions }
                timingFooter(.live)
            }

            // SLOPDESK CLI (E20 WI-9 — Settings → Shell → CLI card). macOS-only: the `/usr/local/bin` symlink
            // + admin escalation are `#if os(macOS)`, so iOS omits it. Shares `CLIInstallCardBody` with the
            // first-launch Install-CLI step (one source).
            #if os(macOS)
            slateFormSection("SlopDesk CLI") {
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

    /// The NOTIFICATION group (notification-setting.png): System Permission status row, master "Allow App
    /// Notifications", per-event toggles, the Notify-While-Foreground tri-state picker, Bounce Dock Icon
    /// (macOS-only — no Dock on iOS). Extracted to keep the `Form` closure under `closure_body_length`.
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
                "Notify when an `slopdesk watch`-wrapped command finishes.",
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
                rowLabel("Notify While Foreground", "Banner behavior while slopdesk is the foreground app.")
            }
            toggleRow(
                "Long-Command Completion",
                "Also notify when a slow command finishes in an unfocused pane.",
                isOn: $longCommandNotifications,
            )
            #if os(macOS)
            toggleRow(
                "Bounce Dock Icon",
                "Bounce the Dock icon when a notification arrives and slopdesk isn't focused.",
                isOn: $bounceDockIcon,
            )
            #endif
            timingFooter(.live)
        }
    }

    /// The TAB BADGE group (Shell — progress-state.md 32-35, under NOTIFICATION in notification-setting.png):
    /// three COMMAND-driven sidebar-badge toggles. DISTINCT from the Agents-tab "Agent Behaviour" badge gates,
    /// so command vs agent badges are independent. "When Command Awaits Input" ships ahead of its signal — the
    /// host detector that drives it is a deferred ceiling (DECISIONS.md).
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
            // The busy-dot reveal delay (`WorkspaceStore.paneShowsBusyDot`): how long a command must run
            // before the plain busy dot shows — a fast `ls` never flashes the rail. 0 = immediate.
            LabeledContent("Busy dot delay") {
                HStack(spacing: Slate.Metric.space2) {
                    Slider(value: $tabBadgeBusyDelaySeconds, in: 0...10, step: 0.5)
                    Text(String(format: "%.1fs", tabBadgeBusyDelaySeconds))
                        .foregroundStyle(Slate.Text.secondary)
                        .monospacedDigit()
                }
            }
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

/// The System Permission status row (`terminal-features__notifications.md`, at the TOP of the Notification
/// group): a coloured dot (green = allowed, amber = will-prompt / unknown, red = blocked) + an **Open System
/// Settings** deep-link. The dot DECISION is the pure, headless-pinned
/// ``PermissionStatus/dot(forAuthorization:)``; this view only queries
/// `UNUserNotificationCenter.current().getNotificationSettings` and renders it.
///
/// **iOS caveat (carryover / spec flag):** macOS deep-links to the Notifications pane
/// (`x-apple.systempreferences:com.apple.preference.notifications`); iOS CANNOT deep-link to the per-app OS
/// pane, so the button opens the app's OWN settings via `UIApplication.openSettingsURLString` — macOS
/// deep-link `#if os(macOS)`, iOS fallback `#if os(iOS)`. See docs/DECISIONS.md E14 WI-7.
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

/// Controls: fire-time toggles + multi-state pickers (E8 owns BEHAVIOUR; E7 declared + persisted them). The
/// groups mirror `spec/terminal-features__{selection,copy-and-paste,scroll,cursor-and-mouse}.md` +
/// `mouse-option.png`: **Selection**, **Copy & Paste**, **Scroll** (incl. SCROLLBACK depth — the `Settings →
/// Controls → Scroll` home), **Mouse**, **Keyboard** (Undo at Prompt), and the slopdesk-specific **System**
/// dialog-panes toggle. All LIVE — every `Defaults` row re-applies the libghostty config via
/// `refreshTerminalControls()` (the `refreshing(_:)` wrapper); the scrollback stepper rebuilds via the
/// `terminal` model's `didSet`. The cursor group is NOT here — it lives under **Appearance**
/// (`cursor-style.png`), hosted by `CursorPreviewView`.
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

    /// Settings → Controls → Scroll. Extracted to keep the `Form` closure under `closure_body_length`.
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

    /// `mouse-option.png` order. Extracted to keep the `Form` closure under `closure_body_length`.
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
            // Surfaces as a simple ON/OFF switch (`spec/cursor-and-mouse`), not a 4-way picker: ON ⇒ ⇧ extends
            // the selection (`MouseShiftCapture.enabled`, default), OFF ⇒ ⇧ forwarded to the program
            // (`.disabled`). The leaf enum keeps `.always`/`.never` for the power-user token mapping. The
            // getter projects through `extendsSelection` (NOT a bare `== .enabled`) so a value from the removed
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

    /// Settings → Controls → Open With (E10 WI-3). The link-interaction knobs are CLIENT-side (not libghostty
    /// config), so they bind DIRECTLY — no `refreshing(_:)` rebuild.
    ///
    /// HONESTY CEILING (docs/DECISIONS.md): a per-target "Open Files / Folders With → [app]" surrogate needs a
    /// LOCAL file/folder pane slopdesk can't offer for a REMOTE host (files live on the host; no file-transfer
    /// sub-protocol). So instead of dead Browser / Finder target pickers, the actionable keys
    /// (`link-cmd-click` / `link-cmd-shift-click`) are surfaced and the reduced target set is a footnote.
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
    /// E8 Controls passthrough). `PreferencesStore` is isolated on its injected `UserDefaults`; the global
    /// Controls toggles live in `Defaults.standard`, so `refreshTerminalControls()` is the explicit re-read
    /// seam (there is no `Defaults.observe` in the store, by design — see `PreferencesStore`).
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
                LabeledContent("File editor") {
                    Text("Not available")
                        .foregroundStyle(Slate.Text.tertiary)
                }
                Text(
                    "Editor settings (Soft Wrap, Line Numbers, Tab Size, …) configure a built-in file editor, "
                        + "which slopdesk does not have yet. Terminal font, cursor, and scrollback live under "
                        + "Appearance and Controls.",
                )
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance section

/// Appearance: the TABS group (New Tab Position — `tab-setting.png` shows it here, NOT Shell), the theme
/// picker (via `AppearancePreferences` → `ThemeStore`), the density tier, the terminal FONT (family + size)
/// and CURSOR (style + blink) — font/cursor relocated here from the old Editor/Controls tabs per
/// `font-setting.png` / `cursor-style.png` — plus the chrome toggles. All LIVE (theme repoints every token;
/// font/cursor rebuild the libghostty config string and bump `TerminalConfigBroadcaster`; New Tab Position +
/// chrome toggles are read at fire-time / next render).
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
            // PRODUCT DECISION (pinned, NOT a regression): an Appearance page could open with a LAYOUT
            // selector (Vertical Tabs / Tabs Top / Tabs Bottom). slopdesk is VERTICAL-TABS-ONLY by deliberate
            // decision — no horizontal tab bar, so no layout selector, and a reviewer must NOT read the missing
            // option as a gap to backfill. The "Auto Hide Tabs Panel" row and the WINDOW group below are both
            // BACKED — Auto Hide drives `SidebarAutoHidePolicy` (E19/A18, WI-2/WI-7), Window Size + steppers
            // feed `WindowSizeMath` via the macOS `NSWindow` glue (E19/A29, WI-1/WI-4). Not dead UI.
            slateFormSection("Tabs") {
                Picker("New tab position", selection: $newTabPosition) {
                    Text("Automatic").tag(NewTabPosition.auto)
                    Text("End").tag(NewTabPosition.end)
                    Text("After Current Tab").tag(NewTabPosition.afterCurrent)
                }
                // AUTO HIDE TABS PANEL (E19/A18 — `auto-hide-tabs-panel`, `tab-setting.png`): `.auto` collapses
                // the sidebar when the active session has one tab (WI-7 reads `SidebarAutoHidePolicy`);
                // `.default`/`.always` never auto-hide. Cross-platform.
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

            // WINDOW (E19/A29 — `window-size`, `tab-setting.png`). macOS-only: initial dimensions are an
            // `NSWindow` concept, so iOS omits it. Extracted to keep the `Form` closure under `closure_body_length`.
            #if os(macOS)
            windowSection
            #endif

            // THEME (E15 WI-6): the picker lists every built-in theme; picking one writes `theme`/`themeDark`.
            // With "Use separated theme for dark mode" ON the OS appearance selects the slot, so a Dark Theme
            // picker appears below the toggle (`dark-mode-theme.png`).
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

            // FONT (E15 WI-8): the Font-Family scope tabs, "Aa" specimen combobox, Auto-match, per-face
            // families, size, line-height, ligatures, and bold/italic/underline/blink/blending controls, bound
            // to `store.terminal` + `store.appearance.themeFonts`. Replaces the old family-TextField +
            // size-Stepper Section (`font-setting.png` / `font-setting-bold.png`). See `FontSettingsView`.
            FontSettingsView(store: store)

            // The FULL Cursor group (live preview + color / text-under / opacity / style / blink / animation)
            // lives under Appearance (`cursor-style.png`). macOS hosts the rich `CursorPreviewView` (its color
            // wells + preview caret are AppKit); the iOS sheet keeps the cross-platform Style + Blink controls
            // (`CursorPreviewView` is `#if os(macOS)`).
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

            // DOCK ICON (E14/K5/K8 — M2): under **Appearance** (terminal-features__progress-state.md).
            // macOS-only (no Dock on iOS — the group is `#if os(macOS)`). Both toggles actuate
            // ``DockProgressController`` via the pure ``DockTintPolicy`` (read fire-time through
            // `WorkspaceStore.dockTileModel`) — not dead UI.
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

    /// The shared picker options — the fixed built-in list (each tagged with its ``ThemeChoice`` so the SAME
    /// body serves both the light/primary slot and the dark slot).
    @ViewBuilder private var themeOptions: some View {
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

    /// Bridge the picker selection to one theme SLOT's model field (`theme` for the light/primary slot,
    /// `themeDark` for the dark slot). An unset slot reads as its default (unset light ⇒ `.system`, unset
    /// dark ⇒ Monokai Pro Classic). Writing always sets an explicit choice so the user's pick persists.
    private func themeSelectionBinding(forDarkSlot dark: Bool) -> Binding<ThemeChoice> {
        Binding(
            get: {
                let choice = dark ? store.appearance.themeDark : store.appearance.theme
                return choice ?? (dark ? .monokaiProClassic : .system)
            },
            set: { choice in
                // Mutate a local copy and assign ONCE so the store's `appearance` didSet (which re-applies the
                // theme) fires a single time.
                var appearance = store.appearance
                if dark {
                    appearance.themeDark = choice
                } else {
                    appearance.theme = choice
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

    /// The WINDOW group (`tab-setting.png`): the `window-size` policy picker + mode-specific steppers.
    /// `.remember` restores the autosaved frame (default); `.grid` sizes to `window-cols × window-rows`;
    /// `.frame` to `window-width-px × window-height-px`. Raw values are clamped by `WindowSizeMath` and applied
    /// ONCE per window open by the introspect glue (WI-4), so a later manual resize is never fought. macOS-only.
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

    /// A dropdown row (bold title + optional gray subtext, a `.menu` picker trailing) for Auto Hide Tabs Panel
    /// + Window Size. Binds DIRECTLY (plain `Defaults`, not libghostty config — no rebuild), mirroring
    /// `ControlsSettingsTab.pickerRow`.
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

// MARK: - Agents section

/// Agents: the CLAUDE CODE install-hooks card (E13 WI-2 — install/uninstall + status row, via the host
/// metadata channel), the host-side agent-detection flags (relocated from the old Video tab — host-read, so
/// reconnect), plus layout-auto-switch and clipboard-history fire-time toggles (LIVE). **Claude Code only**
/// (E13 directive 1): NO codex/opencode card — `MetadataCodec.AgentKind.codex` is documented-dead, never rendered.
private struct AgentsSettingsTab: View {
    @Bindable var store: PreferencesStore

    /// E13 WI-2: the install-hooks model, injected by the app scene (seams target the active connection's
    /// first-pane ``MetadataClient``). `nil` outside the app scene (previews / iOS sheet pre-wiring) → the card
    /// renders disabled ("Connect a session") rather than crashing.
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
                    "Add slopdesk hooks to ~/.claude/settings.json for real-time state updates",
                )
            }

            LabeledContent("Status") { statusBadge(state) }

            if state == .disconnected || state == .unknown {
                Text("Connect a session to manage hooks")
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
            }

            // Queue-safety (2026-07-02): installed-but-INACTIVE — hooks are in settings.json but the host
            // daemon's hook listener isn't bound, so every hook exits silently and no live agent states (or
            // prompt-queue turn signals) arrive. Show the exact fix, not a green check over a dead integration.
            if state == .installedInactive {
                Text(
                    "Hooks are installed but the host isn't listening. Restart the host daemon with "
                        + "SLOPDESK_AGENT_HOOKS=1 (or enable the “Claude Code hooks” toggle below and "
                        + "relaunch it), then open new panes.",
                )
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Status.warn)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Install/uninstall write the host file LIVE, but Claude re-reads settings.json only on next launch
            // — an agent-restart caveat, not a host-reconnect sidecar flag (hence a plain caption, not the
            // `.reconnect` chip, which would mislead).
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
                .foregroundStyle(Slate.Status.ok)
        case .installedInactive:
            Label("Installed — inactive", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Slate.Status.warn)
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
/// nil-controller fallbacks live, so the macOS scene and iOS ``SettingsSheet`` derive the card identically. A
/// `nil` controller (no injection — e.g. the iOS-sheet wiring this regression fixes) MUST fall back to
/// ``AgentHooksController/InstallState/disconnected`` + behaviour-disabled, NEVER a false live card. Pure +
/// cross-platform, unit-pinned headlessly (`AgentSettingsCardTests`).
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

/// The power-user raw `SLOPDESK_*` override box, folded LAST into the env overlay (so a typed raw key beats
/// the matching typed pref); a precedence note makes clear a REAL process env var still wins over the whole
/// overlay. The Video HOST flags (QP/FEC/pacer/sharpen) have no dedicated section, so they fold in here as a
/// "Video (host)" sub-section — real functionality, reconnect-tagged + symmetric-FEC-warned.
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
    /// the raw `SLOPDESK_*` editor is a HOST-side concern, so the compact iOS sheet (WI-5) omits it.
    @State private var text: String = ""
    #endif

    var body: some View {
        Form {
            privilegesSection

            // The raw `SLOPDESK_*` editor + Video HOST flags are macOS-host-relevant, so the iOS sheet (WI-5)
            // omits them; the cross-platform All-Settings list below still reaches iOS.
            #if os(macOS)
            slateFormSection("Raw overrides") {
                Text(
                    "One SLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
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

    // MARK: - Privileges (E14/K11-K12 — title gates + OSC-52 master + read/write tri-state)

    /// The privilege surface (Settings → Advanced, `terminal-features__notifications.md`): title gates + the
    /// OSC-52 master switch + read/write tri-state pickers. The pickers are DISABLED while the master is off
    /// (the whole OSC-52 path resolves to Deny). Title Report is a documented ceiling — it persists/surfaces
    /// but doesn't yet actuate (the libghostty fork owns XTWINOPS; docs/DECISIONS.md).
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
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Status.warn)
                timingFooter(.reconnect)
            }

            slateFormSection("Video · Pacer (host)") {
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
