// AllSettingsListView — the Advanced → "All Settings" searchable list, for the PHONE.
//
// A searchable, scrollable list of every client-side config key (driven by the headless
// `AllSettingsCatalog`), rendered into the Advanced `Form` as a `Group` of `Section`s. Matches the design
// spec `customization__advanced-settings.md` + `all-settings.png`:
//   • header "ALL SETTINGS" (uppercase, tertiary) with a trailing search field,
//   • a "Reset All Settings" / "Reset Advanced Only" button row, each behind a confirmation alert,
//   • rows: monospace key + gray description ("· Default: …"), then EITHER an inline control
//     (`.advancedOnly`, bound to its `Defaults.Key`) OR a value + ✎ jump-to-tab button (`.hasDedicatedTab`).
//
// EVERY OPTION LIST HERE USED TO BE TYPED IN THIS FILE, as `Text("…").tag(…)` children — thirteen of them,
// and by the time increment 49 measured it FOUR had drifted from `slopdesk_workspace::settings_catalog`,
// which has held the same lists all along: "Context Menu" against the catalog's "Context menu", "Copy or
// Paste" against "Copy or paste", "Home" against "Home Directory", and an On-Launch pair spelled a third
// way again in `FirstLaunchStepPresentation`. The scroll-multiplier row re-typed `0.25...5`, `step: 0.25`
// and `"%.2f×"` against `Ladder::ScrollMultiplier`, which owns all three. So this file no longer names a
// choice: ``SettingsIndexPresentation`` says which GROUP or LADDER a key draws from, the catalog says what
// the choices are called, and the Mac's ``SlopDeskMacUI/MacAllSettingsIndex`` reads exactly the same
// answers.
//
// The catalog is the single source of WHAT to show; this view owns the `Defaults.Key` bindings (a
// `@Default` is a property wrapper whose whole point is that SwiftUI observes the read, which is why the
// bindings are the one thing that cannot descend) + the cross-tab jump (reported by section id). Cross-tab
// HIGHLIGHT of the target control is deferred (only the jump itself ships here).
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if os(iOS)
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
    // The Dock bounce is absent from this list on purpose, and its binding with it: it wants a Dock,
    // so the Shell page draws it on the Mac alone and `AllSettingsCatalog` — which derives what it
    // advertises from that same page table — no longer hands this switch a row for it. A case kept
    // here would be a control nobody can reach; the toggle it used to draw wrote a value nothing on
    // this device reads. The two agent SOUNDS below stay: they decide ring-or-silent, which the
    // phone spends on the banner's default cue rather than on `NSSound`.
    @Default(.notifyOnFinish) private var notifyOnFinish
    @Default(.notifyOnError) private var notifyOnError
    @Default(.notifyOnWatchFinish) private var notifyOnWatchFinish
    @Default(.notifyWhileForeground) private var notifyWhileForeground
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

    /// The rows the live query leaves, computed ONCE per body pass.
    ///
    /// It was a computed `private var` read twice — `filtered.isEmpty` and then `ForEach(filtered)`
    /// — and `AllSettingsCatalog.filter` is a crossing per matched row plus two for the match
    /// itself, so an empty query cost 188 doors and the body paid it 376 times over before a single
    /// row was built. The `let` is not a cache; it is the second evaluation deleted.
    private var filtered: [AllSettingsCatalog.SettingEntry] { AllSettingsCatalog.filter(query) }

    var body: some View {
        let rows = filtered
        return Group {
            Section {
                HStack(spacing: Slate.Metric.space2) {
                    Button(SettingsIndexPresentation.resetAllTitle) { confirmResetAll = true }
                    Button(SettingsIndexPresentation.resetAdvancedTitle) { confirmResetAdvanced = true }
                    Spacer()
                }
                .buttonStyle(.bordered)

                if rows.isEmpty {
                    Text(SettingsIndexPresentation.noMatches(query))
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.tertiary)
                } else {
                    ForEach(rows) { entry in row(for: entry) }
                }
            } header: {
                HStack {
                    Text(SettingsIndexPresentation.header)
                        .font(SettingsType.subtitle.weight(.medium))
                        .tracking(1)
                        .foregroundStyle(SettingsInk.tertiary)
                    Spacer()
                    TextField(SettingsIndexPresentation.searchPlaceholder, text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }
            }
        }
        .alert(SettingsIndexPresentation.resetAllPrompt, isPresented: $confirmResetAll) {
            Button(SettingsIndexPresentation.cancelTitle, role: .cancel) {}
            Button(SettingsIndexPresentation.resetAllConfirm, role: .destructive) {
                // The affordance in full: `resetAll()` alone cannot reach `device-prefs.json`, and the
                // message promises "every setting" (`AllSettingsCatalog.deviceLocalKeys`).
                store.resetEverySetting(deviceLocal: workspaceStore)
            }
        } message: {
            Text(SettingsIndexPresentation.resetAllMessage)
        }
        .alert(SettingsIndexPresentation.resetAdvancedPrompt, isPresented: $confirmResetAdvanced) {
            Button(SettingsIndexPresentation.cancelTitle, role: .cancel) {}
            Button(SettingsIndexPresentation.resetAdvancedConfirm, role: .destructive) {
                store.resetAdvancedOnly()
            }
        } message: {
            Text(SettingsIndexPresentation.resetAdvancedMessage)
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
            Text(SettingsIndexPresentation.detail(entry))
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
                Text(SettingsIndexPresentation.dedicatedValue(entry, store: store, device: workspaceStore))
                    .foregroundStyle(SettingsInk.secondary)
                Image(systemSymbol: .pencil)
                    .foregroundStyle(SettingsInk.icon)
            }
            .font(SettingsType.subtitle)
        }
        .buttonStyle(.borderless)
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
        // OSC-52 clipboard access gates (allow / deny / ask) — live under Advanced → All Settings; feed the
        // config passthrough, so refresh on change.
        case SettingsKey.clipboardReadKey: tokenPicker(entry.key, $clipboardRead, refresh: true)
        case SettingsKey.clipboardWriteKey: tokenPicker(entry.key, $clipboardWrite, refresh: true)
        case SettingsKey.allowShiftClickKey:
            // Exposed as an ON/OFF switch (`spec/cursor-and-mouse`): ON ⇒ `.enabled` (⇧ extends the
            // selection, the default), OFF ⇒ `.disabled` (⇧ forwarded to the program). The leaf enum retains
            // `.always`/`.never` for the token mapping, but the UI surfaces only the binary the spec shows —
            // which is why this key has no option group: two states a switch already says.
            boolControl(
                Binding(
                    get: { allowShiftClick == .enabled },
                    set: { allowShiftClick = $0 ? .enabled : .disabled },
                ),
                refresh: true,
            )
        case SettingsKey.rightClickActionKey: tokenPicker(entry.key, $rightClickAction)
        case SettingsKey.optionAsAltKey: tokenPicker(entry.key, $optionAsAlt, refresh: true)
        case SettingsKey.scrollMultiplier: ladderStepper(entry.key, $scrollMultiplier)
        case SettingsKey.onLaunchKey: tokenPicker(entry.key, $onLaunch)
        case SettingsKey.newTabPositionKey: tokenPicker(entry.key, $newTabPosition)
        case SettingsKey.closeConfirmTabKey: tokenPicker(entry.key, $closeConfirmTab)
        case SettingsKey.closeConfirmWindowKey: tokenPicker(entry.key, $closeConfirmWindow)
        case SettingsKey.workingDirectoryNewWindowKey: rawTokenPicker(entry.key, $workingDirNewWindow)
        case SettingsKey.workingDirectoryNewTabKey: rawTokenPicker(entry.key, $workingDirNewTab)
        case SettingsKey.workingDirectoryNewSplitKey: rawTokenPicker(entry.key, $workingDirNewSplit)
        // Link interaction — client-side knobs (no config rebuild on change).
        case SettingsKey.linkDetection: boolControl($linkDetection)
        case SettingsKey.linkCmdClickKey: tokenPicker(entry.key, $linkCmdClick)
        case SettingsKey.linkCmdShiftClickKey: tokenPicker(entry.key, $linkCmdShiftClick)
        case SettingsKey.autoDetectLinkSchemesKey: tokenPicker(entry.key, $autoDetectLinkSchemes)
        case SettingsKey.customLinkSchemes:
            // Read-only live summary here — the full editor lives on the Controls → Link Schemes section,
            // and a second editor would be a second way to write a list whose separator rules live at the
            // first one (``SettingsIndexPresentation/isReadOnly(_:)`` says so for both halves).
            AnyView(Text(SettingsIndexPresentation.readOnlySummary(customLinkSchemes.joined(separator: ", ")))
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .lineLimit(1))
        case SettingsKey.notifyWhileForegroundKey: tokenPicker(entry.key, $notifyWhileForeground)
        // Notifications / sounds / agent-notify (Shell groups) — plain live toggles, no config rebuild.
        case SettingsKey.notifyOnFinish: boolControl($notifyOnFinish)
        case SettingsKey.notifyOnError: boolControl($notifyOnError)
        case SettingsKey.notifyOnWatchFinish: boolControl($notifyOnWatchFinish)
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

    /// A menu over the option group ``SettingsIndexPresentation/optionGroup(_:)`` names for `key`, bridged
    /// onto a typed `@Default` binding.
    ///
    /// The bridge is what lets the CHOICES come from the catalog while the STORAGE stays a typed enum: the
    /// picker selects a token, and a token no case parses is dropped rather than written — the same rule the
    /// boundary itself follows, and the reason it crosses tokens instead of case indices.
    ///
    /// A key with no group draws NOTHING. That is a real answer, not a hole to paper over: it means the list
    /// belongs in `settings_catalog.rs` and has not been added, which is exactly what a blank row should
    /// prompt.
    private func tokenPicker<Value: RawRepresentable & Hashable>(
        _ key: String, _ binding: Binding<Value>, refresh: Bool = false,
    ) -> AnyView where Value.RawValue == String {
        tokenPicker(
            key,
            Binding(
                get: { binding.wrappedValue.rawValue },
                set: { raw in
                    guard let value = Value(rawValue: raw) else { return }
                    binding.wrappedValue = value
                },
            ),
            refresh: refresh,
        )
    }

    /// The same menu over a key whose stored type IS the token — the three working-directory rows, which
    /// persist a bare `WorkingDirectoryPolicy.rawConfig` string.
    private func rawTokenPicker(_ key: String, _ binding: Binding<String>) -> AnyView {
        tokenPicker(key, binding)
    }

    /// The menu itself, over a token binding.
    ///
    /// Reading through ``SettingsIndexPresentation/selectedToken(_:_:)`` is what keeps a working-directory
    /// key holding a literal PATH from selecting nothing: the catalog offers two policies and a path reads
    /// as `home`, which is the Rust table's own ruling rather than this view's.
    private func tokenPicker(_ key: String, _ binding: Binding<String>, refresh: Bool = false) -> AnyView {
        guard let group = SettingsIndexPresentation.optionGroup(key) else { return AnyView(EmptyView()) }
        let selection = Binding(
            get: { SettingsIndexPresentation.selectedToken(key, binding.wrappedValue) },
            set: { binding.wrappedValue = $0 },
        )
        return AnyView(
            Picker("", selection: refresh ? store.refreshing(selection) : selection) {
                ForEach(SettingsCatalog.stringOptions(group)) { option in
                    Text(option.menuLabel).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize(),
        )
    }

    /// A stepper over the ladder ``SettingsIndexPresentation/ladder(_:)`` names for `key`, with the ladder's
    /// own readout beside it — range, step and format all read from `settings_catalog.rs` rather than typed
    /// at the control, which is where this row had drifted.
    private func ladderStepper(_ key: String, _ binding: Binding<Double>) -> AnyView {
        guard let ladder = SettingsIndexPresentation.ladder(key) else { return AnyView(EmptyView()) }
        return AnyView(HStack(spacing: Slate.Metric.space1) {
            Text(ladder.readout(binding.wrappedValue))
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .monospacedDigit()
            Stepper(
                "",
                value: store.refreshing(binding),
                in: ladder.range,
                step: ladder.step,
            )
            .labelsHidden()
        })
    }
}
#endif
