// AllSettingsListView — the Advanced → "All Settings" searchable list.
//
// A searchable, scrollable list of every client-side config key (driven by the headless
// `AllSettingsCatalog`), rendered into the Advanced `Form` as a `Group` of `Section`s. Matches the design
// spec `customization__advanced-settings.md` + `all-settings.png`:
//   • header "ALL SETTINGS" (uppercase, tertiary) with a trailing search field,
//   • a "Reset All Settings" / "Reset Advanced Only" button row, each behind a confirmation alert,
//   • rows: monospace key + gray description ("· Default: …"), then EITHER an inline control
//     (`.advancedOnly`, bound to its `Defaults.Key`) OR a value + ✎ jump-to-tab button (`.hasDedicatedTab`).
//
// The catalog is the single source of WHAT to show; this view owns the `Defaults.Key` bindings + the
// cross-tab jump (reported by section id). Cross-tab HIGHLIGHT of the target control is
// deferred (only the jump itself ships here).
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

/// The Advanced → All Settings panel. Returns a `Group` of `Section`s so it composes into the host
/// host `Form`. A ✎ jump reports the SECTION ID it wants shown; the navigator that owns the selection
/// decides what to do with it.
struct AllSettingsListView: View {
    @Bindable var store: PreferencesStore
    /// Where a ✎ jump on a `.hasDedicatedTab` row goes, by SECTION ID — the two halves navigate
    /// differently (a `List` selection here, an `NSTableView` row there) and neither owns the other's
    /// selection type, so what crosses is the id the catalog already carries.
    var onJump: (String) -> Void = { _ in }

    @State private var query = ""
    @State private var confirmResetAll = false
    @State private var confirmResetAdvanced = false

    /// The owner of the DEVICE-LOCAL preferences (docs/45 §7.3) — read so the shared-focus row shows its
    /// LIVE value beside the ✎ jump rather than a static default. Nil in a preview.
    @Environment(\.workspaceStore) private var workspaceStore

    // The advanced-only rows bind directly to the global `Defaults.Keys` (the same channel the per-section
    // tabs use), so an inline edit applies live exactly like hand-editing the config.
    @Default(.onLaunch) private var onLaunch
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.redactSecrets) private var redactSecrets
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    @Default(.newTabPosition) private var newTabPosition
    @Default(.closeConfirmTab) private var closeConfirmTab
    @Default(.closeConfirmWindow) private var closeConfirmWindow
    @Default(.copyOnSelect) private var copyOnSelect
    @Default(.trimTrailingSpacesOnCopy) private var trimTrailingSpacesOnCopy
    @Default(.pasteProtection) private var pasteProtection
    @Default(.mouseHideWhileTyping) private var mouseHideWhileTyping
    @Default(.focusFollowsMouse) private var focusFollowsMouse
    @Default(.paneSwitcherPreview) private var paneSwitcherPreview
    @Default(.scrollMultiplier) private var scrollMultiplier
    @Default(.recordClipboardHistory) private var recordClipboardHistory
    // The remaining Controls / Mouse / Scroll knobs + the OSC-52 read/write access pickers (the
    // clipboard-read/write gates live under Advanced → All Settings — `copy-and-paste` spec). Mirror the
    // catalog rows here so every `.advancedOnly` entry has an inline editor instead of falling to plain text.
    @Default(.clearSelectionOnTyping) private var clearSelectionOnTyping
    @Default(.clearSelectionOnCopy) private var clearSelectionOnCopy
    @Default(.shiftArrowSelect) private var shiftArrowSelect
    @Default(.pasteBracketedSafe) private var pasteBracketedSafe
    @Default(.allowMouseCapture) private var allowMouseCapture
    @Default(.clickToMove) private var clickToMove
    @Default(.undoAtPrompt) private var undoAtPrompt
    @Default(.clipboardRead) private var clipboardRead
    @Default(.clipboardWrite) private var clipboardWrite
    @Default(.allowShiftClick) private var allowShiftClick
    @Default(.rightClickAction) private var rightClickAction
    @Default(.optionAsAlt) private var optionAsAlt
    // Path/link detection (Settings → Controls → Open With / Link Schemes). Client-side link
    // knobs, so no `refresh:` config rebuild on change.
    @Default(.linkDetection) private var linkDetection
    @Default(.linkCmdClick) private var linkCmdClick
    @Default(.linkCmdShiftClick) private var linkCmdShiftClick
    @Default(.autoDetectLinkSchemes) private var autoDetectLinkSchemes
    @Default(.customLinkSchemes) private var customLinkSchemes
    // Notification / sound / agent-notify keys (Shell → NOTIFICATION + SOUND groups). They have a richer
    // dedicated control on the Shell tab, but — exactly like `copyOnSelect` (Controls) and `oscNotifications`
    // (Shell) above — the All-Settings list mirrors them inline so every `.advancedOnly` row is editable here
    // rather than falling to a dead default-value label (the rows are kept in
    // `AllSettingsCatalog.inlineEditableKeys`).
    @Default(.notifyOnFinish) private var notifyOnFinish
    @Default(.notifyOnError) private var notifyOnError
    @Default(.notifyOnWatchFinish) private var notifyOnWatchFinish
    @Default(.notifyWhileForeground) private var notifyWhileForeground
    @Default(.bounceDockIcon) private var bounceDockIcon
    @Default(.soundShellControlled) private var soundShellControlled
    @Default(.soundOnErrorExit) private var soundOnErrorExit
    @Default(.agentNotifyTaskComplete) private var agentNotifyTaskComplete
    @Default(.agentNotifyAwaitInput) private var agentNotifyAwaitInput
    @Default(.agentSoundTaskComplete) private var agentSoundTaskComplete
    @Default(.agentSoundAwaitInput) private var agentSoundAwaitInput
    // The privilege surface (title gate + OSC-52 master) — the genuinely advanced-only keys
    // (Advanced → Privileges).
    @Default(.titleShellControlled) private var titleShellControlled
    @Default(.clipboardShellControlled) private var clipboardShellControlled

    private var filtered: [AllSettingsCatalog.SettingEntry] { AllSettingsCatalog.filter(query) }

    var body: some View {
        Group {
            Section {
                HStack(spacing: Slate.Metric.space2) {
                    Button("Reset All Settings") { confirmResetAll = true }
                    Button("Reset Advanced Only") { confirmResetAdvanced = true }
                    Spacer()
                }
                .buttonStyle(.bordered)

                if filtered.isEmpty {
                    Text("No settings match “\(query)”.")
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.tertiary)
                } else {
                    ForEach(filtered) { entry in row(for: entry) }
                }
            } header: {
                HStack {
                    Text("ALL SETTINGS")
                        .font(SettingsType.subtitle.weight(.medium))
                        .tracking(1)
                        .foregroundStyle(SettingsInk.tertiary)
                    Spacer()
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }
            }
        }
        .alert("Reset All Settings?", isPresented: $confirmResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All", role: .destructive) {
                // The affordance in full: `resetAll()` alone cannot reach `device-prefs.json`, and the
                // alert below promises "every setting" (`AllSettingsCatalog.deviceLocalKeys`).
                store.resetEverySetting(deviceLocal: workspaceStore)
            }
        } message: {
            Text("This restores every setting to its default — font, keybindings, and all expert "
                + "keys. This cannot be undone.")
        }
        .alert("Reset Advanced Settings?", isPresented: $confirmResetAdvanced) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Advanced", role: .destructive) {
                store.resetAdvancedOnly()
            }
        } message: {
            Text("This restores the advanced keys (video, agent, and raw overrides) to their defaults, "
                + "leaving your font and keybinding choices intact. This cannot be undone.")
        }
    }

    // MARK: - Row

    private func row(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.key)
                    .font(SettingsType.mono)
                    .foregroundStyle(SettingsInk.primary)
                Spacer(minLength: Slate.Metric.space2)
                control(for: entry)
            }
            Text("\(entry.description) · Default: \(entry.defaultText)")
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Slate.Metric.space1)
    }

    /// The trailing control: an inline editor for an `.advancedOnly` key, or a value + ✎ jump button for a
    /// `.hasDedicatedTab` key.
    @ViewBuilder
    private func control(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        switch entry.bucket {
        case .advancedOnly: inlineControl(for: entry)
        case .hasDedicatedTab: jumpButton(for: entry)
        }
    }

    /// A button showing the current value + ✎ that repoints the navigator at the owning page.
    private func jumpButton(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        Button {
            if let raw = entry.targetSection { onJump(raw) }
        } label: {
            HStack(spacing: Slate.Metric.space1) {
                Text(dedicatedValue(for: entry))
                    .foregroundStyle(SettingsInk.secondary)
                Image(systemSymbol: .pencil)
                    .foregroundStyle(SettingsInk.icon)
            }
            .font(SettingsType.subtitle)
        }
        .buttonStyle(.borderless)
    }

    /// The current value of a `.hasDedicatedTab` render-pref, read live from the store.
    private func dedicatedValue(for entry: AllSettingsCatalog.SettingEntry) -> String {
        switch entry.key {
        case "font-family": store.terminal.fontFamily
        case "font-size": "\(Int(store.terminal.fontSize))"
        case "scrollback-limit": "\(store.terminal.scrollbackLines)"
        case "cursor-style": store.terminal.cursorStyle.displayName
        case "cursor-style-blink": store.terminal.cursorBlink.rawValue.capitalized
        case SettingsKey.density: (store.appearance.density ?? SettingsCatalog.densityComfortable).capitalized
        // Device-local, so it is read from the `WorkspaceStore` rather than a typed prefs model.
        case SharedFocusSetting.catalogKey: SharedFocusSetting.valueText(workspaceStore)
        default: entry.defaultText
        }
    }

    // MARK: - Inline advanced-only controls (bound to the `Defaults.Keys`)

    /// The inline editor for an `.advancedOnly` key. Returns `AnyView` so the large key switch erases to one
    /// type (keeps the SwiftUI `ViewBuilder` type-checker cheap).
    private func inlineControl(for entry: AllSettingsCatalog.SettingEntry) -> AnyView {
        switch entry.key {
        case SettingsKey.oscNotifications: boolControl($oscNotifications)
        case SettingsKey.longCommandNotifications: boolControl($longCommandNotifications)
        case SettingsKey.redactSecrets: boolControl($redactSecrets)
        // Controls / Mouse / Scroll knobs that feed the libghostty config passthrough (`TerminalControls`)
        // refresh the live surface on change (`refresh: true`); the knobs the SURFACE reads live off
        // `Defaults` instead (right-click, focus-follows-mouse, undo-at-prompt) persist without a rebuild.
        case SettingsKey.copyOnSelect: boolControl($copyOnSelect, refresh: true)
        case SettingsKey.trimTrailingSpacesOnCopy: boolControl($trimTrailingSpacesOnCopy, refresh: true)
        case SettingsKey.clearSelectionOnTyping: boolControl($clearSelectionOnTyping, refresh: true)
        case SettingsKey.clearSelectionOnCopy: boolControl($clearSelectionOnCopy, refresh: true)
        case SettingsKey.pasteProtection: boolControl($pasteProtection, refresh: true)
        case SettingsKey.pasteBracketedSafe: boolControl($pasteBracketedSafe, refresh: true)
        case SettingsKey.mouseHideWhileTyping: boolControl($mouseHideWhileTyping, refresh: true)
        case SettingsKey.allowMouseCapture: boolControl($allowMouseCapture, refresh: true)
        case SettingsKey.clickToMove: boolControl($clickToMove, refresh: true)
        case SettingsKey.shiftArrowSelect: boolControl($shiftArrowSelect, refresh: true)
        case SettingsKey.focusFollowsMouse: boolControl($focusFollowsMouse)
        case SettingsKey.paneSwitcherPreview: boolControl($paneSwitcherPreview)
        case SettingsKey.undoAtPrompt: boolControl($undoAtPrompt)
        case SettingsKey.recordClipboardHistory: boolControl($recordClipboardHistory)
        // OSC-52 clipboard access gates (allow / deny / ask) — live under Advanced → All Settings; feed the
        // config passthrough, so refresh on change.
        case SettingsKey.clipboardReadKey:
            menuPicker($clipboardRead, refresh: true) { clipboardAccessOptions }
        case SettingsKey.clipboardWriteKey:
            menuPicker($clipboardWrite, refresh: true) { clipboardAccessOptions }
        case SettingsKey.allowShiftClickKey:
            // Exposed as an ON/OFF switch (`spec/cursor-and-mouse`): ON ⇒ `.enabled` (⇧ extends the
            // selection, the default), OFF ⇒ `.disabled` (⇧ forwarded to the program). The leaf enum retains
            // `.always`/`.never` for the token mapping, but the UI surfaces only the binary the spec shows.
            boolControl(
                Binding(
                    get: { allowShiftClick == .enabled },
                    set: { allowShiftClick = $0 ? .enabled : .disabled },
                ),
                refresh: true,
            )
        case SettingsKey.rightClickActionKey:
            menuPicker($rightClickAction) {
                Text("Context Menu").tag(RightClickAction.contextMenu)
                Text("Copy").tag(RightClickAction.copy)
                Text("Paste").tag(RightClickAction.paste)
                Text("Copy or Paste").tag(RightClickAction.copyOrPaste)
                Text("Ignore").tag(RightClickAction.ignore)
            }
        case SettingsKey.optionAsAltKey:
            menuPicker($optionAsAlt, refresh: true) {
                Text("Off").tag(OptionAsAlt.off)
                Text("Both Option Keys").tag(OptionAsAlt.both)
                Text("Left Option Only").tag(OptionAsAlt.left)
                Text("Right Option Only").tag(OptionAsAlt.right)
            }
        case SettingsKey.scrollMultiplier:
            AnyView(HStack(spacing: Slate.Metric.space1) {
                Text(String(format: "%.2f×", scrollMultiplier))
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
                    .monospacedDigit()
                Stepper("", value: store.refreshing($scrollMultiplier), in: 0.25...5, step: 0.25).labelsHidden()
            })
        case SettingsKey.onLaunchKey:
            menuPicker($onLaunch) {
                Text("Restore Last Session").tag(OnLaunchBehavior.restoreLastSession)
                Text("New Window").tag(OnLaunchBehavior.newWindow)
            }
        case SettingsKey.newTabPositionKey:
            menuPicker($newTabPosition) {
                Text("Automatic").tag(NewTabPosition.auto)
                Text("End").tag(NewTabPosition.end)
                Text("After Current").tag(NewTabPosition.afterCurrent)
            }
        case SettingsKey.closeConfirmTabKey: menuPicker($closeConfirmTab) { closeConfirmTabOptions }
        case SettingsKey.closeConfirmWindowKey: menuPicker($closeConfirmWindow) { closeConfirmOptions }
        case SettingsKey.workingDirectoryNewWindowKey: workingDirControl($workingDirNewWindow)
        case SettingsKey.workingDirectoryNewTabKey: workingDirControl($workingDirNewTab)
        case SettingsKey.workingDirectoryNewSplitKey: workingDirControl($workingDirNewSplit)
        // Link interaction — client-side knobs (no config rebuild on change).
        case SettingsKey.linkDetection: boolControl($linkDetection)
        case SettingsKey.linkCmdClickKey:
            menuPicker($linkCmdClick) {
                Text("Open").tag(LinkCmdClick.open)
                Text("Copy").tag(LinkCmdClick.copy)
                Text("Do Nothing").tag(LinkCmdClick.nothing)
            }
        case SettingsKey.linkCmdShiftClickKey:
            menuPicker($linkCmdShiftClick) {
                Text("Reveal in Finder").tag(LinkCmdShiftClick.revealFinder)
                Text("Open with System Default").tag(LinkCmdShiftClick.openSystemDefault)
            }
        case SettingsKey.autoDetectLinkSchemesKey:
            menuPicker($autoDetectLinkSchemes) {
                Text("All").tag(AutoDetectLinkSchemes.all)
                Text("Custom").tag(AutoDetectLinkSchemes.custom)
            }
        case SettingsKey.customLinkSchemes:
            // Read-only live summary here — the full editor lives on the Controls → Link Schemes section.
            AnyView(Text(customLinkSchemes.isEmpty ? "None" : customLinkSchemes.joined(separator: ", "))
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .lineLimit(1))
        // Notifications / sounds / agent-notify (Shell groups) — plain live toggles, no config rebuild.
        case SettingsKey.notifyOnFinish: boolControl($notifyOnFinish)
        case SettingsKey.notifyOnError: boolControl($notifyOnError)
        case SettingsKey.notifyOnWatchFinish: boolControl($notifyOnWatchFinish)
        case SettingsKey.notifyWhileForegroundKey:
            menuPicker($notifyWhileForeground) {
                ForEach(NotifyWhileForeground.allCases, id: \.self) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            }
        case SettingsKey.bounceDockIcon: boolControl($bounceDockIcon)
        case SettingsKey.soundShellControlled: boolControl($soundShellControlled)
        case SettingsKey.soundOnErrorExit: boolControl($soundOnErrorExit)
        case SettingsKey.agentNotifyTaskComplete: boolControl($agentNotifyTaskComplete)
        case SettingsKey.agentNotifyAwaitInput: boolControl($agentNotifyAwaitInput)
        case SettingsKey.agentSoundTaskComplete: boolControl($agentSoundTaskComplete)
        case SettingsKey.agentSoundAwaitInput: boolControl($agentSoundAwaitInput)
        // The privilege surface. `clipboardShellControlled` is the OSC-52 master gate that feeds the libghostty
        // clipboard-read/write tokens, so it refreshes the live config; the title gate is read fire-time
        // (no config rebuild).
        case SettingsKey.titleShellControlled: boolControl($titleShellControlled)
        case SettingsKey.clipboardShellControlled: boolControl($clipboardShellControlled, refresh: true)
        default:
            // No inline editor wired (should not happen for an `.advancedOnly` entry) — show the default.
            AnyView(Text(entry.defaultText)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.tertiary))
        }
    }

    private func boolControl(_ binding: Binding<Bool>, refresh: Bool = false) -> AnyView {
        AnyView(Toggle("", isOn: refresh ? store.refreshing(binding) : binding).labelsHidden())
    }

    private func menuPicker(
        _ binding: Binding<some Hashable>, refresh: Bool = false, @ViewBuilder _ content: () -> some View,
    ) -> AnyView {
        AnyView(Picker("", selection: refresh ? store.refreshing(binding) : binding, content: content)
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize())
    }

    /// The shared allow / deny / ask options for the OSC-52 clipboard-read and -write access pickers.
    @ViewBuilder private var clipboardAccessOptions: some View {
        Text("Allow").tag(ClipboardAccess.allow)
        Text("Deny").tag(ClipboardAccess.deny)
        Text("Ask").tag(ClipboardAccess.ask)
    }

    @ViewBuilder private var closeConfirmOptions: some View {
        closeConfirmTabOptions
        Text("Multiple Tabs").tag(CloseConfirmationPolicy.multipleTabs)
    }

    /// The TAB row's policies — the window set MINUS `multiple_tabs`, which can never fire for a tab (closing
    /// one tab loses exactly one tab). Composed INTO `closeConfirmOptions` so the shared rows stay identical.
    @ViewBuilder private var closeConfirmTabOptions: some View {
        Text("Running Process").tag(CloseConfirmationPolicy.process)
        Text("Always").tag(CloseConfirmationPolicy.always)
    }

    /// The two working-dir choices, bridged onto the `WorkingDirectoryPolicy.rawConfig` String key (any
    /// non-`inherit` policy reads as `home`, exactly as the Shell tab's picker).
    private func workingDirControl(_ raw: Binding<String>) -> AnyView {
        let bridged = Binding<WorkingDirChoice>(
            get: { WorkingDirectoryPolicy(rawConfig: raw.wrappedValue) == .inherit ? .inherit : .home },
            set: { raw.wrappedValue = ($0 == .inherit ? WorkingDirectoryPolicy.inherit : .home).rawConfig },
        )
        return menuPicker(bridged) {
            Text("Same as Current").tag(WorkingDirChoice.inherit)
            Text("Home").tag(WorkingDirChoice.home)
        }
    }

    private enum WorkingDirChoice: String, CaseIterable, Identifiable {
        case inherit
        case home
        var id: String { rawValue }
    }
}
#endif
