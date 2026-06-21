#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import SwiftUI
#if os(macOS)
import AppKit // KeyCaptureField (NSViewRepresentable key-capture) — macOS only.
#endif

// MARK: - Settings keys (one source of truth)

/// The `@AppStorage` keys the Settings scene owns, shared verbatim with the consumers (the canvas
/// snap toggles, the system-dialog gate, the notification posters). Centralised so a key can never
/// drift between where it is written (Settings) and where it is read.
public enum SettingsKey {
    // Canvas
    public static let snapPanes = "canvas.snapPanes"
    public static let snapGrid = "canvas.snapGrid"
    public static let showGrid = "canvas.showGrid"
    public static let nonOverlap = "canvas.nonOverlap"
    public static let defaultPaneKindKey = "canvas.defaultPaneKind" // PaneKind.rawValue
    // Notifications
    public static let oscNotifications = "notifications.osc"
    public static let longCommandNotifications = "notifications.longCommand"
    // Features / advanced
    public static let systemDialogPanes = "features.systemDialogPanes"
    public static let autoSwitchLayouts = "features.autoSwitchLayouts"
    public static let redactSecrets = "features.redactSecrets"
    public static let recordClipboardHistory = "features.recordClipboardHistory"
    // Appearance / chrome
    /// The active ``DSDensity`` tier rawValue. Mirrors ``DSDensity/storageKey`` (the SAME `UserDefaults`
    /// key ``DSThemeStore`` reads at init + on a Settings change) so the picker, persistence, and the live
    /// `DSScale`/height tokens all agree on one source.
    public static let density = "appearance.density"
    /// Whether the bottom ``PaneStatusBar`` is hidden (the chrome recedes toward pure terminal). Default OFF.
    public static let hideStatusBar = "appearance.hideStatusBar"
    /// Whether the per-block sticky command divider/header is shown over terminal panes. Default ON.
    public static let showBlockDividers = "terminal.showBlockDividers"

    /// Whether a layout with a trigger app auto-switches when that app launches on the host (default
    /// ON — assigning a trigger is itself the opt-in). Read at fire-time.
    public static var autoSwitchLayoutsEnabled: Bool {
        UserDefaults.standard.object(forKey: autoSwitchLayouts) as? Bool ?? true
    }

    /// Whether explicit OSC 9/777 notifications should post (default ON). Read at fire-time.
    public static var oscNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: oscNotifications) as? Bool ?? true
    }

    /// Whether the long-command completion notification should post (default ON). Read at fire-time.
    public static var longCommandNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: longCommandNotifications) as? Bool ?? true
    }

    /// Whether the system-dialog monitor should auto-spawn dialog panes (default ON). The
    /// `AISLOPDESK_SYSTEM_DIALOG_PANES` env var still overrides for tests (`0` off / `force` on).
    public static var systemDialogPanesEnabled: Bool {
        UserDefaults.standard.object(forKey: systemDialogPanes) as? Bool ?? true
    }

    /// Whether to mask likely secrets (access keys, bearer tokens, `PASSWORD=…`) out of window titles and
    /// notification bodies before they reach the sidebar/pill/Notification Center (default ON — security
    /// by default; the escape hatch is for someone who genuinely wants raw titles). Read at fire-time.
    public static var redactSecretsEnabled: Bool {
        UserDefaults.standard.object(forKey: redactSecrets) as? Bool ?? true
    }

    /// Whether copied text is archived into the clipboard-history ring that backs the pill's "Paste
    /// Recent" submenu (default ON). Turn it OFF to stop the monitor from retaining any copied string —
    /// the privacy escape hatch for someone who copies secrets to paste into sudo/SSH prompts. Read at
    /// fire-time so a settings change applies live; existing entries are cleared from the pill's "Clear
    /// History".
    public static var recordClipboardHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: recordClipboardHistory) as? Bool ?? true
    }

    /// Whether the bottom status bar is hidden (default OFF — the strip shows unless the user hides it).
    /// Read at fire-time so a Settings change applies on the next render.
    public static var hideStatusBarEnabled: Bool {
        UserDefaults.standard.object(forKey: hideStatusBar) as? Bool ?? false
    }

    /// Whether the per-block command divider/header is shown (default ON). Read at fire-time.
    public static var showBlockDividersEnabled: Bool {
        UserDefaults.standard.object(forKey: showBlockDividers) as? Bool ?? true
    }

    /// The default kind for a generic "New Pane" (toolbar primary action / empty state), default
    /// `.terminal`. The ⌥⌘N per-kind shortcut is unaffected. A stale persisted `"claudeCode"` value (the
    /// kind retired in W11) is not a valid raw value here → falls back to `.terminal`, exactly right.
    public static var defaultPaneKind: PaneKind {
        (UserDefaults.standard.string(forKey: defaultPaneKindKey)).flatMap(PaneKind.init(rawValue:)) ?? .terminal
    }
}

// MARK: - SettingsView (the ⌘, scene)

/// The app Settings window (macOS ⌘,) — the complete GUI Settings system (W13). A `TabView` of panels,
/// each bound to the single ``PreferencesStore`` (the live source of truth for the four W12 models) or,
/// for the legacy client gates, the `@AppStorage` ``SettingsKey``s.
///
/// TWO bridges (decision #6 / #10):
///   • LIVE client/terminal prefs apply immediately (the terminal reloads its libghostty config; the
///     client-readable env folds into ``EnvConfig/overlay``);
///   • the ~80 video/host flags write the `video-prefs.json` SIDECAR and are marked **"applies on
///     reconnect."**
///
/// The store is owned here as `@State` so the whole Settings scene shares ONE instance; every control
/// binds to it via `$store.<model>.<field>` (a typed binding into the `Codable` model, whose `didSet`
/// persists + re-applies). macOS renders the panels as a tab strip; iOS gets the same panels in a
/// responsive form (no macOS-only control leaks — they are `#if os(macOS)`-guarded individually).
public struct SettingsView: View {
    @State private var store: PreferencesStore

    /// Builds the Settings scene over a SHARED ``PreferencesStore`` (the app passes its launch-time
    /// instance so an in-app edit and the launch-time apply agree). The no-arg initializer builds a
    /// fresh store (previews / standalone).
    public init(store: PreferencesStore? = nil) {
        _store = State(initialValue: store ?? PreferencesStore())
    }

    public var body: some View {
        TabView {
            GeneralSettingsPanel()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsPanel(store: store)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AppearanceSettingsPanel()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            VideoQualitySettingsPanel(store: store)
                .tabItem { Label("Video & Quality", systemImage: "video") }
            NetworkFECSettingsPanel(store: store)
                .tabItem { Label("Network & FEC", systemImage: "network") }
            AgentSettingsPanel(store: store)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            KeybindingSettingsPanel(store: store)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            SessionsPresetsSettingsPanel()
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
            AdvancedSettingsPanel(store: store)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        #if os(macOS)
        .frame(width: 540, height: 460)
        #endif
    }
}

// MARK: - General

/// General client behaviour: the default new-pane kind + the system-dialog gate (the legacy
/// `@AppStorage` ``SettingsKey`` consumers — still live). Canvas snap/grid toggles are RETIRED with
/// the canvas (W5).
private struct GeneralSettingsPanel: View {
    @AppStorage(SettingsKey.defaultPaneKindKey) private var defaultKind = PaneKind.terminal.rawValue
    @AppStorage(SettingsKey.systemDialogPanes) private var systemDialogPanes = true
    @AppStorage(SettingsKey.autoSwitchLayouts) private var autoSwitchLayouts = true

    var body: some View {
        Form {
            Section("New panes") {
                Picker("Default new pane", selection: $defaultKind) {
                    Text("Terminal").tag(PaneKind.terminal.rawValue)
                    Text("Remote Window").tag(PaneKind.remoteGUI.rawValue)
                }
                Text(
                    """
                    Used by ⌘N and the toolbar + button. ⌥⌘N always makes a Remote Window pane. \
                    Run `claude` in any terminal — it is auto-detected (no dedicated pane).
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("System dialogs") {
                Toggle("Show system password dialogs in their own pane", isOn: $systemDialogPanes)
                Text(
                    """
                    A SecurityAgent / sudo prompt on the host auto-spawns an ephemeral pane \
                    (and an attention beacon if it lands off-screen). Type into it with Paste as Keystrokes.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layouts") {
                Toggle("Auto-switch layout on host app launch", isOn: $autoSwitchLayouts)
                Text(
                    """
                    A saved layout with a trigger app switches in automatically when that app first opens a window \
                    on the host (set the trigger when you save a layout).
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Terminal (W13 — TerminalPreferences, live-apply)

/// Terminal-render preferences (font / theme / cursor / scrollback) → ``TerminalPreferences`` (a W12
/// model owned by the ``PreferencesStore``). A change persists + rebuilds the libghostty config string
/// and re-applies it LIVE (the Xcode-app `GhosttyTerminalView` reads ``TerminalConfigBroadcaster``).
private struct TerminalSettingsPanel: View {
    @Bindable var store: PreferencesStore
    @AppStorage(SettingsKey.showBlockDividers) private var showBlockDividers = true

    var body: some View {
        Form {
            Section("Blocks") {
                Toggle("Show command block dividers", isOn: $showBlockDividers)
                Text(
                    """
                    Draws the slim per-command header/divider over each pane (Warp-style block chrome). \
                    Turn off for chrome-less panes — the block list stays reachable via ⌃⌘O.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Font") {
                TextField("Family", text: $store.terminal.fontFamily)
                Stepper(
                    "Size: \(Int(store.terminal.fontSize)) pt",
                    value: $store.terminal.fontSize, in: 8...48, step: 1,
                )
                Picker("Weight", selection: $store.terminal.fontWeight) {
                    Text("Regular").tag("regular")
                    Text("Medium").tag("medium")
                    Text("Bold").tag("bold")
                }
            }
            Section("Theme") {
                TextField("Theme", text: $store.terminal.theme)
                Text("A named libghostty theme (e.g. “Aislopdesk Dark”). Applies live on change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Picker("Style", selection: $store.terminal.cursorStyle) {
                    Text("Block").tag(TerminalPreferences.CursorStyle.block)
                    Text("Bar").tag(TerminalPreferences.CursorStyle.bar)
                    Text("Underline").tag(TerminalPreferences.CursorStyle.underline)
                }
                Toggle("Blink", isOn: $store.terminal.cursorBlink)
            }
            Section("Scrollback") {
                Stepper(
                    "Lines: \(store.terminal.scrollbackLines)",
                    value: $store.terminal.scrollbackLines, in: 1000...200_000, step: 1000,
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Appearance

/// Client-side appearance + privacy: the ``DSDensity`` interface-density tier (P5 — drives both the DS font/
/// space multiplier AND the chrome row/tab/status-bar heights), the disappearing-chrome toggle (hide the
/// status bar), and the redaction + clipboard-history privacy gates (the legacy `@AppStorage`
/// ``SettingsKey`` consumers).
private struct AppearanceSettingsPanel: View {
    @AppStorage(SettingsKey.redactSecrets) private var redactSecrets = true
    @AppStorage(SettingsKey.recordClipboardHistory) private var recordClipboard = true
    @AppStorage(SettingsKey.hideStatusBar) private var hideStatusBar = false

    /// The shared `@Observable` density/accent store, held as `@Bindable` so the panel TRACKS it (a `$theme.
    /// density` binding both writes the live setter AND re-renders the picker if the tier ever changes from
    /// another writer). The Settings scene is a SEPARATE window outside the `WorkspaceRootView` injection
    /// scope, so this binds the process-wide singleton directly rather than reading `@Environment` (which
    /// would be nil here). Its setter's `didSet` re-sets ``DSScale``'s LIVE multiplier AND persists the choice
    /// to ``SettingsKey/density`` — ONE source of truth, no separate @AppStorage String to drift from it.
    @Bindable private var theme = DSThemeStore.shared

    var body: some View {
        Form {
            Section("Interface density") {
                Picker("Density", selection: $theme.density) {
                    ForEach(DSDensity.allCases, id: \.self) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                Text(
                    """
                    Reflows the whole chrome — tab/sidebar/status-bar fonts, padding AND row heights — from \
                    one tier. Compact suits a dense coding session; Comfortable eases the spacing.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chrome") {
                Toggle("Hide status bar", isOn: $hideStatusBar)
                Text(
                    """
                    Hides the bottom status strip so the workspace recedes toward pure terminal output. \
                    The focused pane's RTT / agent state is still in the tab + sidebar.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Redact secrets in titles, notifications & clipboard previews", isOn: $redactSecrets)
                Text(
                    """
                    Masks likely access keys, bearer tokens and `PASSWORD=…` out of window titles, \
                    notification banners, and the “Paste Recent” menu previews before they’re shown.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Record clipboard history (for Paste Recent)", isOn: $recordClipboard)
                Text(
                    """
                    Keeps a short ring of recently-copied text for the pill’s “Paste Recent”. \
                    Turn off to stop retaining any copied string; clear existing entries from that menu’s “Clear History”.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(SettingsKey.oscNotifications) private var osc = true
    @AppStorage(SettingsKey.longCommandNotifications) private var longCommand = true

    var body: some View {
        Form {
            Section("Desktop notifications") {
                Toggle("Explicit notifications (OSC 9 / 777)", isOn: $osc)
                Text(
                    """
                    A remote command can post a notification on demand, e.g. \
                    `printf '\\e]9;done\\e\\\\'`. Click it to jump to the pane.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Long-running command finished (~10s+)", isOn: $longCommand)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Video & Quality (W13 — VideoPreferences, applies on reconnect)

/// The user-facing subset of the ~80 video flags → ``VideoPreferences`` (sidecar-backed). Every knob is
/// OPTIONAL (a `nil` field emits NO env override ⇒ behaviour-preserving default) and marked **"applies
/// on reconnect"** — the host reads these at `static let` init and cannot live-reload.
private struct VideoQualitySettingsPanel: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section {
                Text("These tune the GUI-window video encoder on the HOST. They apply on the next reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quality (QP)") {
                OptionalIntStepper("Sharpest QP", value: $store.video.qpSharp, range: 1...51, fallback: 26)
                OptionalIntStepper("Coarsest QP", value: $store.video.qpCoarse, range: 1...51, fallback: 40)
                OptionalToggle("Decouple Min/Max QP (keep static UI crisp)", value: $store.video.qpDecouple)
            }
            Section("Capture") {
                OptionalToggle("HiDPI 2× virtual display", value: $store.video.virtualDisplay, defaultOn: true)
                EnumPicker(
                    "Display capture", value: $store.video.displayCapture,
                    cases: VideoPreferences.DisplayCapture.allCases,
                    label: { $0.rawValue.capitalized },
                )
            }
            Section("Client render") {
                OptionalDoubleField("Sharpen (luma unsharp, 0 = off)", value: $store.video.sharpen)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Network & FEC (W13 — symmetric keys)

/// Network / pacer / FEC knobs → ``VideoPreferences``. The FEC `m`/`k` keys are SYMMETRIC
/// (``EnvBridge/symmetricKeys``) — they MUST be set identically on host AND client, surfaced with a
/// "set on both ends" warning.
private struct NetworkFECSettingsPanel: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section("FEC (Reed–Solomon)") {
                OptionalIntStepper("Parity m", value: $store.video.fecM, range: 1...8, fallback: 1)
                OptionalIntStepper("Group size k", value: $store.video.fecK, range: 1...32, fallback: 8)
                Label(
                    "Set FEC m and k IDENTICALLY on host and client, or the two ends disagree.",
                    systemImage: "exclamationmark.triangle",
                )
                .font(.caption).foregroundStyle(.orange)
            }
            Section("Pacer") {
                EnumPicker(
                    "Presentation pacer", value: $store.video.pacer,
                    cases: VideoPreferences.Pacer.allCases, label: { $0.rawValue.capitalized },
                )
                OptionalDoubleField("Playout buffer (ms)", value: $store.video.playoutMs)
            }
            Section { remindReconnect }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var remindReconnect: some View {
        Text("Network / FEC changes apply on the next reconnect.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Agents (W13 — AgentPreferences + the W10 Claude-hook installer)

/// Claude / agent detection gates → ``AgentPreferences`` (sidecar-backed, host-read) + the "Install
/// Claude hooks" action that runs the W10 `aislopdesk integration install claude` on the LOCAL host
/// daemon (the common dev case where host + client share a Mac).
private struct AgentSettingsPanel: View {
    @Bindable var store: PreferencesStore
    @State private var installResult: String?

    var body: some View {
        Form {
            Section("Detection") {
                OptionalToggle("Foreground-process watch (auto-detect `claude`)", value: $store.agent.agentDetect)
                OptionalToggle("Claude Code hooks (richer status)", value: $store.agent.agentHooks)
                Text("Detection gates apply on the next host reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code hooks") {
                Button("Install Claude Hooks…") { runInstaller(.install) }
                Button("Uninstall Claude Hooks", role: .destructive) { runInstaller(.uninstall) }
                if let installResult {
                    Text(installResult).font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    """
                    Writes ~/.claude/hooks/aislopdesk-agent.sh and patches ~/.claude/settings.json on \
                    THIS Mac via the aislopdesk host daemon. Run aislopdesk-hostd with \
                    AISLOPDESK_AGENT_HOOKS=1 to bind the listener.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func runInstaller(_ action: ClaudeHookInstaller.Action) {
        installResult = ClaudeHookInstaller.run(action).message
    }
}

// MARK: - Keyboard Shortcuts (W13 — KeybindingPreferences over the W6 registry)

/// Lists the W6 ``WorkspaceBindingRegistry`` bindings, shows each binding's RESOLVED chord (override or
/// default), and lets the user rebind → a ``KeybindingPreferences`` override on the store. Conflicts
/// (two ids → the same override chord) are highlighted via ``KeybindingPreferences/conflicts()``.
private struct KeybindingSettingsPanel: View {
    @Bindable var store: PreferencesStore

    private var conflicts: Set<String> {
        // The set of binding ids that participate in any override conflict (for the row highlight).
        Set(store.keybindingConflicts().values.flatMap(\.self))
    }

    var body: some View {
        Form {
            Section {
                Text("Click a shortcut to rebind it. Conflicts are highlighted; defaults need no override.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(WorkspaceAction.Category.allCases, id: \.self) { category in
                let rows = WorkspaceBindingRegistry.bindings.filter { $0.category == category }
                if !rows.isEmpty {
                    Section(category.rawValue) {
                        ForEach(rows, id: \.id) { binding in
                            KeybindingRow(
                                binding: binding,
                                override: store.keybindings.chord(for: binding.id),
                                isConflicted: conflicts.contains(binding.id),
                                onRebind: { setOverride(binding.id, $0) },
                                onReset: { clearOverride(binding.id) },
                            )
                        }
                    }
                }
            }
            Section {
                Button("Reset All Shortcuts") { store.keybindings = KeybindingPreferences() }
                    .disabled(store.keybindings.overrides.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setOverride(_ id: String, _ chord: KeybindingPreferences.KeyChord) {
        var prefs = store.keybindings
        prefs.overrides[id] = chord
        store.keybindings = prefs
    }

    private func clearOverride(_ id: String) {
        var prefs = store.keybindings
        prefs.overrides[id] = nil
        store.keybindings = prefs
    }
}

/// One rebindable shortcut row. Shows the resolved glyph; a captured key chord on macOS rebinds; the
/// reset removes the override (falls back to the registry default).
private struct KeybindingRow: View {
    let binding: WorkspaceBinding
    let override: KeybindingPreferences.KeyChord?
    let isConflicted: Bool
    let onRebind: (KeybindingPreferences.KeyChord) -> Void
    let onReset: () -> Void

    private var glyph: String {
        // The RESOLVED chord glyph — the override (if any) else the registry default.
        if let override, let mapped = override.asRegistryChord {
            return WorkspaceBindingRegistry.glyph(mapped)
        }
        return binding.chord.map(WorkspaceBindingRegistry.glyph) ?? "—"
    }

    var body: some View {
        HStack {
            Image(systemName: binding.symbol).frame(width: 20)
            Text(binding.title)
            if isConflicted {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Text(glyph)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(override != nil ? .primary : .secondary)
            #if os(macOS)
            KeyCaptureField(onCapture: onRebind)
            #endif
            if override != nil {
                Button { onReset() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to default")
            }
        }
    }
}

// MARK: - Sessions / Presets / Snippets

/// Sessions / layout-presets / snippets management entry point. The detailed editors live in the
/// workspace command palette + the sidebar; this panel surfaces the toggles + a pointer there.
private struct SessionsPresetsSettingsPanel: View {
    var body: some View {
        Form {
            Section("Sessions & layouts") {
                Text(
                    """
                    Sessions, tabs and split layouts are managed live in the workspace (the sidebar + the \
                    ⌘K command palette). Save the current layout as a preset from the Pane menu; snippets are \
                    edited from the command palette’s “Snippets” section.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Advanced (W13 — raw AISLOPDESK_* override editor)

/// The power-user escape hatch: a raw `AISLOPDESK_*` override editor → the ``PreferencesStore``'s
/// `rawOverrides`, folded LAST into ``EnvConfig/overlay`` (so a hand-typed key wins over the typed
/// prefs). Empty by default ⇒ contributes nothing (behaviour-preserving).
private struct AdvancedSettingsPanel: View {
    @Bindable var store: PreferencesStore
    @State private var newKey = ""
    @State private var newValue = ""

    private var sortedKeys: [String] { store.rawOverrides.keys.sorted() }

    var body: some View {
        Form {
            Section("Raw AISLOPDESK_* overrides") {
                Text("For power users. A raw override wins over the matching typed setting. Applies on reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sortedKeys, id: \.self) { key in
                    HStack {
                        Text(key).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(store.rawOverrides[key] ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button { removeKey(key) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Add override") {
                TextField("AISLOPDESK_KEY", text: $newKey)
                    .font(.system(.body, design: .monospaced))
                TextField("value", text: $newValue)
                Button("Add") { addOverride() }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !store.rawOverrides.isEmpty {
                Section {
                    Button("Clear All Overrides", role: .destructive) { store.rawOverrides = [:] }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addOverride() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        var overrides = store.rawOverrides
        overrides[key] = newValue
        store.rawOverrides = overrides
        newKey = ""
        newValue = ""
    }

    private func removeKey(_ key: String) {
        var overrides = store.rawOverrides
        overrides[key] = nil
        store.rawOverrides = overrides
    }
}

// MARK: - Reusable optional-binding controls

/// A `Toggle` over an `Optional<Bool>`: an unset pref reads as `defaultOn` and the toggle's `false`
/// SETS the field (so the user can deliberately turn a default-ON flag off and have it persist). Once
/// the user interacts, the field is no longer `nil` (so the env override emits).
private struct OptionalToggle: View {
    let title: String
    @Binding var value: Bool?
    var defaultOn = false

    init(_ title: String, value: Binding<Bool?>, defaultOn: Bool = false) {
        self.title = title
        _value = value
        self.defaultOn = defaultOn
    }

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { value ?? defaultOn },
            set: { value = $0 },
        ))
    }
}

/// A `Stepper` over an `Optional<Int>`: a "Set" checkbox arms the override (nil → fallback), then the
/// stepper edits it; unchecking returns the field to `nil` (no override emitted).
private struct OptionalIntStepper: View {
    let title: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    let fallback: Int

    init(_ title: String, value: Binding<Int?>, range: ClosedRange<Int>, fallback: Int) {
        self.title = title
        _value = value
        self.range = range
        self.fallback = fallback
    }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? fallback : nil })) {
                Text(title)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            Spacer()
            if value != nil {
                Stepper(
                    "\(value ?? fallback)",
                    value: Binding(get: { value ?? fallback }, set: { value = $0 }),
                    in: range,
                )
                .labelsHidden()
                Text("\(value ?? fallback)").monospacedDigit()
            } else {
                Text("default").foregroundStyle(.secondary)
            }
        }
    }
}

/// A numeric `TextField` over an `Optional<Double>`: empty text ⇒ `nil` (no override). A non-numeric
/// entry is dropped (validate-then-default), leaving the field unset.
private struct OptionalDoubleField: View {
    let title: String
    @Binding var value: Double?

    init(_ title: String, value: Binding<Double?>) {
        self.title = title
        _value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("default", text: Binding(
                get: { value.map { String($0) } ?? "" },
                set: { value = $0.isEmpty ? nil : Double($0) },
            ))
            .multilineTextAlignment(.trailing)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
                .frame(maxWidth: 120)
        }
    }
}

/// A `Picker` over an `Optional<RawRepresentable enum>` with a leading "Default" tag (nil). The cases
/// are passed explicitly so the picker stays headless-pure (no reflection).
private struct EnumPicker<T: Hashable>: View {
    let title: String
    @Binding var value: T?
    let cases: [T]
    let label: (T) -> String

    init(_ title: String, value: Binding<T?>, cases: [T], label: @escaping (T) -> String) {
        self.title = title
        _value = value
        self.cases = cases
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $value) {
            Text("Default").tag(T?.none)
            ForEach(cases, id: \.self) { c in
                Text(label(c)).tag(T?.some(c))
            }
        }
    }
}

#if os(macOS)
/// A tiny macOS key-capture affordance: focus it and the next key chord (with ⌘/⌥/⌃/⇧) becomes a
/// ``KeybindingPreferences/KeyChord`` override. Compile-only AppKit; never instantiated in a headless
/// test (the pure rebind LOGIC is the `KeybindingPreferences` model + the registry mapper, both tested).
private struct KeyCaptureField: NSViewRepresentable {
    let onCapture: (KeybindingPreferences.KeyChord) -> Void

    func makeNSView(context _: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureView, context _: Context) { nsView.onCapture = onCapture }

    final class CaptureView: NSView {
        var onCapture: ((KeybindingPreferences.KeyChord) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 18) }

        override func draw(_: NSRect) {
            (window?.firstResponder === self ? NSColor.controlAccentColor : NSColor.separatorColor)
                .setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            path.stroke()
        }

        override func mouseDown(with _: NSEvent) { window?.makeFirstResponder(self) }

        override func keyDown(with event: NSEvent) {
            guard let chord = KeyCaptureField.chord(from: event) else { super.keyDown(with: event)
                return
            }
            onCapture?(chord)
            window?.makeFirstResponder(nil)
            needsDisplay = true
        }
    }

    /// Map an `NSEvent` key-down to a serialisable ``KeybindingPreferences/KeyChord`` — modifier flags +
    /// the unmodified base key. Returns `nil` for a bare key (no modifier) so a plain key can't shadow
    /// the terminal (the §5 conflict rule); named keys map to their canonical tokens.
    static func chord(from event: NSEvent) -> KeybindingPreferences.KeyChord? {
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)
        guard command || option || control else { return nil } // require a ⌘/⌥/⌃ prefix
        guard let key = baseKey(for: event) else { return nil }
        return KeybindingPreferences.KeyChord(
            key: key, command: command, shift: shift, option: option, control: control,
        )
    }

    private static func baseKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            guard let chars = event.charactersIgnoringModifiers, let c = chars.first else { return nil }
            return String(c).lowercased()
        }
    }
}
#endif

// MARK: - Claude hook installer (client-side action over the local host daemon)

/// W13: the "Install Claude hooks" action, run from the client GUI against the LOCAL host daemon. The
/// client UI cannot import `AislopdeskHost` (the host layer) — so it SHELLS OUT to the
/// `aislopdesk-hostd integration install|uninstall claude` one-shot subcommand (W10). The pure parts
/// (the binary search + the result mapping) are testable; the `Process` launch is macOS-only.
enum ClaudeHookInstaller {
    enum Action { case install, uninstall

        var argument: String { self == .install ? "install" : "uninstall" }
    }

    struct Result: Equatable { let ok: Bool
        let message: String
    }

    /// Candidate locations for the `aislopdesk-hostd` binary, in order: next to the running app, on
    /// PATH (`/usr/local/bin`, `/opt/homebrew/bin`), then the dev build dir. Pure — returns the search
    /// list so a test can assert the policy without touching disk.
    static func candidatePaths(
        bundlePath: String? = Bundle.main.executablePath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String] {
        var paths: [String] = []
        if let bundlePath {
            let dir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            paths.append(dir.appendingPathComponent("aislopdesk-hostd").path)
        }
        if let explicit = environment["AISLOPDESK_HOSTD_PATH"], !explicit.isEmpty {
            paths.insert(explicit, at: 0)
        }
        paths.append(contentsOf: [
            "/usr/local/bin/aislopdesk-hostd",
            "/opt/homebrew/bin/aislopdesk-hostd",
        ])
        return paths
    }

    /// Run the installer. On macOS it locates `aislopdesk-hostd` and runs the one-shot subcommand; on
    /// iOS (no local host) it returns a clear "host-only" message.
    static func run(_ action: Action) -> Result {
        #if os(macOS)
        let fm = FileManager.default
        guard let binary = candidatePaths().first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return Result(
                ok: false,
                message: "Couldn't find aislopdesk-hostd. Run `aislopdesk-hostd integration "
                    + "\(action.argument) claude` on the host manually.",
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["integration", action.argument, "claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = process.terminationStatus == 0
            return Result(
                ok: ok,
                message: ok
                    ? (action == .install ? "Installed Claude hooks." : "Removed Claude hooks.")
                    : "Failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))",
            )
        } catch {
            return Result(ok: false, message: "Failed to launch installer: \(error.localizedDescription)")
        }
        #else
        return Result(ok: false, message: "Claude hook install runs on the macOS host.")
        #endif
    }
}
#endif
