// SettingsPages — the eight settings pages, in SwiftUI.
//
// One struct per section of the taxonomy, each of which asks `slopdesk_workspace::settings_layout`
// for its groups and renders them. The two things a page still decides for itself are the two the
// table cannot carry: a key → BINDING (`@Default` is a property wrapper, so a key can cross a
// language boundary and a binding cannot), and what a control KIND looks like in this framework.
// Everything else — which groups, in what order, under which header, with which timing, on which
// platform — comes back from the table.
//
// WHO RENDERS THIS. The phone: `SettingsSheet` presents ``SettingsSectionContent`` (in
// `SettingsTaxonomy.swift`) for the section a reader taps. The Mac draws its own page in AppKit
// (`SlopDeskMacUI/Settings`), from the SAME table, because a settings window with a mouse wants an
// `NSSwitch` and a source list where a sheet wants a `Toggle` and a pushed list — that difference is
// the whole reason the halves are separate (docs/56 §3). What neither half redraws is a
// `Control.bespoke` group: those are surfaces rather than control kinds, so both resolve them through
// ``SettingsBespokeSurface`` and each half hosts the result.
//
// WHY EIGHT STRUCTS AND NOT ONE TABLE-WALKER, which is what the Mac half is. The per-key `switch` in
// each page is not the page's knowledge of the taxonomy — it is a BINDING lookup, and `@Default` is a
// property wrapper whose whole point is that SwiftUI observes the read. A shared closure-based
// accessor (`MacSettingsBindings`, which is what the AppKit half builds its generic page on) is
// invisible to that tracking, so a page built over one would stop redrawing when a value changed
// under it. The duplication between the halves is therefore of the STORAGE MAPPING only; every word,
// every option list, every group and every platform gate is read from the one table. Measured
// 2026-08-19: the phone renders all 76 rows the table lists for it, so the hand-written half is not
// costing coverage either.
//
// WHERE EACH GROUP SITS. An 8-section taxonomy — General / Shell / Controls / Editor / Agents /
// Appearance / Key Bindings / Advanced — finer-grained than a flat tab strip so each group can sit
// where its screenshot proves it belongs. FONT (family + size) + CURSOR (style + blink) →
// **Appearance** (`font-setting.png` / `cursor-style.png`); SCROLLBACK → **Controls**
// (`spec/terminal-features__scroll.md`); theme → Appearance; agent host flags → Agents; Close
// Confirmation → **General** (`launch-option.png`). **Editor** is reserved for a built-in FILE-editor
// (Soft Wrap / Line Numbers / Tab Size — `editor-settings.png`) slopdesk lacks, so it states its own
// emptiness rather than being backfilled with terminal-render prefs. The VIDEO flags have no
// dedicated section, so they fold into Advanced as four described groups — quality, FEC, pacer and
// the client's own sharpen — rather than the one hand-drawn surface they used to be.
//
// DEFERRED vs LIVE-APPLY: each group carries an `ApplyTiming` chip (`.live` = immediate; `.reconnect`
// = a HOST-read sidecar flag, effective on the next host connection). Terminal + appearance +
// keybindings + the fire-time toggles are live; the video/agent HOST flags are reconnect-only;
// SYMMETRIC keys (FEC) also carry a "set on both ends" warning, which is a `Control.note` row in the
// table rather than a paragraph hand-placed in a body.
//
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskCLICore
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - The one door to the eight pages

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
        case .general: GeneralSettingsTab(store: store)
        case .shell: ShellSettingsTab(store: store)
        case .controls: ControlsSettingsTab(store: store)
        case .editor: EditorSettingsTab(store: store)
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
    /// Held only to hand to a bespoke surface — General edits no typed-model field of its own.
    let store: PreferencesStore
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

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.general.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
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
        if case let .bespoke(id) = row.control {
            SettingsBespokeSurface(id: id, store: store)
        }
    }
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
    /// Held only to hand to a bespoke surface — Shell edits no typed-model field of its own.
    let store: PreferencesStore
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
            SettingsBespokeSurface(id: id, store: store)
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
    let store: PreferencesStore

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.editor.rawValue, for: .current)) { group in
                settingsGroup(group) { row in
                    if case let .bespoke(id) = row.control {
                        SettingsBespokeSurface(id: id, store: store)
                    }
                }
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

    /// The custom line-height multiplier, seeded from the model on appear so the slider opens at the
    /// persisted value rather than snapping to its own default.
    @State private var customMultiplier: Double = 1.2

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.appearance.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if case let .custom(value) = store.terminal.lineHeight { customMultiplier = value }
        }
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
        case SettingsKey.windowColsKey: if windowSize == .grid { settingsStepper(row, $windowCols) }
        case SettingsKey.windowRowsKey: if windowSize == .grid { settingsStepper(row, $windowRows) }
        case SettingsKey.windowWidthPxKey: if windowSize == .frame { settingsStepper(row, $windowWidthPx) }
        case SettingsKey.windowHeightPxKey: if windowSize == .frame { settingsStepper(row, $windowHeightPx) }
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
        case AllSettingsCatalog.RenderKey.fontSize:
            settingsStepper(row, $store.terminal.fontSize)
        case AllSettingsCatalog.RenderKey.fontLineHeight:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.lineHeight, as: LineHeightChoice.self),
                selection: lineHeightChoice,
            )
            // Both rows below are conditioned on the VALUE above — dynamic, not layout — so the
            // table lists the choice and the page draws what picking `custom` opens.
            if lineHeightChoice.wrappedValue == .custom {
                LabeledContent("Multiplier") {
                    HStack(spacing: Slate.Metric.space2) {
                        Slider(value: lineHeightMultiplier, in: 0.8...2.0, step: 0.05)
                        Text(String(format: "%.2f×", customMultiplier))
                            .foregroundStyle(SettingsInk.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Changing line height re-measures the cell and reflows the terminal (a resize).")
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case AllSettingsCatalog.RenderKey.fontLigatures:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.fontLigatures),
                selection: $store.terminal.fontLigatures,
            )
        case AllSettingsCatalog.RenderKey.fontLigaturesAlphabet:
            SettingsGlyphToggleRow(
                glyph(row), row.label, row.subtitle,
                isOn: $store.terminal.fontLigaturesAlphabet,
            )
            .disabled(store.terminal.fontLigatures == .off)
        case AllSettingsCatalog.RenderKey.fontBold:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.fontStyleMode),
                selection: $store.terminal.fontBold,
            )
        case AllSettingsCatalog.RenderKey.fontItalic:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.fontStyleMode),
                selection: $store.terminal.fontItalic,
            )
        case AllSettingsCatalog.RenderKey.fontBlending:
            SettingsOptionMenuRow(
                row.label,
                subtitle: row.subtitle,
                options: SettingsCatalog.options(.fontBlending),
                selection: $store.terminal.fontBlending,
            )
        default:
            if case .note = row.control {
                settingsNote(row)
            } else {
                bespoke(row)
            }
        }
    }

    /// ``LineHeightMode`` carries a `Double` on `.custom`, so it cannot be a menu tag; the flat mirror
    /// is what the catalog's tokens rebuild. Picking `.custom` seeds from the live multiplier, and
    /// picking away from it leaves that seed alone so switching back restores what was set.
    private var lineHeightChoice: Binding<LineHeightChoice> {
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

    /// The custom multiplier slider — writes the local seed AND the model.
    private var lineHeightMultiplier: Binding<Double> {
        Binding(
            get: { customMultiplier },
            set: { value in
                customMultiplier = value
                store.terminal.lineHeight = .custom(value)
            },
        )
    }

    /// The groups this page draws itself rather than describing — see `SettingsLayout.Control.bespoke`.
    /// Both are whole surfaces with their own headers, which is why their groups carry no title.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control {
            SettingsBespokeSurface(id: id, store: store)
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

    // The badge toggles are fire-time `Defaults.Keys` and drive the GLOBAL `AgentBadgeGates` the
    // sidebar applies (a per-pane override lives on the tab context-menu). Prevent Sleep and Resume
    // on Recovery ride the `AgentPreferences` sidecar instead, which is why they are a group with a
    // `.reconnect` footer rather than three more rows above.
    @Default(.agentBadgeWhileProcessing) private var agentBadgeWhileProcessing
    @Default(.agentBadgeWhenComplete) private var agentBadgeWhenComplete
    @Default(.agentBadgeWhenAwaitingInput) private var agentBadgeWhenAwaitingInput

    /// The Agent-Behaviour groups are greyed out until at least one integration is installed —
    /// read off the install-card controller's state. `nil`/disconnected ⇒ not installed ⇒ greyed.
    /// A condition on the CONTROLLER's live state, not on another setting, so it stays here.
    private var behaviorEnabled: Bool { AgentSettingsCard.behaviourEnabled(agentHooks) }

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.agents.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
                    .disabled(group.title.hasPrefix("Agent Behaviour") && !behaviorEnabled)
            }
        }
        .formStyle(.grouped)
        // Re-probe the host install state on each open (per spec — not cached forever); `.task` re-fires when
        // the Agents tab re-appears and auto-cancels on disappear.
        .task { await agentHooks?.refresh() }
    }

    /// One row, by the setting it edits — see `GeneralSettingsTab.control(_:)` for why the binding is
    /// the half that cannot cross.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.agentBadgeWhileProcessing: toggle(row, $agentBadgeWhileProcessing)
        case SettingsKey.agentBadgeWhenComplete: toggle(row, $agentBadgeWhenComplete)
        case SettingsKey.agentBadgeWhenAwaitingInput: toggle(row, $agentBadgeWhenAwaitingInput)
        case SettingsKey.recordClipboardHistory: toggle(row, $recordClipboardHistory)
        case AllSettingsCatalog.RenderKey.agentPreventSleep:
            toggle(row, hostFlag($store.agent.preventSleep, AgentPreferences.preventSleepDefault))
        case AllSettingsCatalog.RenderKey.agentResumeOnRecovery:
            toggle(row, hostFlag($store.agent.resumeOnRecovery, AgentPreferences.resumeOnRecoveryDefault))
        default:
            if case .note = row.control {
                // The note explains the greying, so it appears only while the group is grey.
                if !behaviorEnabled {
                    Text(row.subtitle)
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.tertiary)
                }
            } else {
                bespoke(row)
            }
        }
    }

    /// The one group this page draws itself: the install-hooks card, which is a privileged write to
    /// the user's own `~/.claude/settings.json` plus a live status readout, not a list of settings.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control {
            SettingsBespokeSurface(id: id, store: store)
        }
    }

    private func toggle(_ row: SettingsLayout.Row, _ binding: Binding<Bool>) -> some View {
        SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: binding)
    }

    /// A sidecar flag as a plain switch. `nil` means "unset", and what the daemon then does differs
    /// per flag, so the row shows the DAEMON's answer rather than reading absence as off — and a
    /// deliberate flip writes an explicit value, so turning Resume on Recovery off can actually turn
    /// it off. It could not before: the old setter wrote `nil` for false, which is that flag's ON.
    private func hostFlag(_ binding: Binding<Bool?>, _ whenUnset: Bool) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? whenUnset },
            set: { binding.wrappedValue = $0 },
        )
    }
}

// MARK: - Keybindings section

private struct KeybindingsSettingsTab: View {
    @Bindable var store: PreferencesStore
    var body: some View {
        ForEach(SettingsLayout.groups(SettingsSection.keybindings.rawValue, for: .current)) { group in
            settingsGroup(group) { row in
                if case let .bespoke(id) = row.control {
                    SettingsBespokeSurface(id: id, store: store)
                }
            }
        }
    }
}

// MARK: - Advanced section (raw overrides + the folded-in video flags)

/// The power-user raw `SLOPDESK_*` override box, folded LAST into the env overlay (so a typed raw key beats
/// the matching typed pref); a precedence note makes clear a REAL process env var still wins over the whole
/// overlay. The VIDEO flags have no dedicated section, so they fold in here as four described groups —
/// quality, FEC, pacer, client render — reconnect-tagged and symmetric-FEC-warned by the table.
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

    var body: some View {
        Form {
            ForEach(SettingsLayout.groups(SettingsSection.advanced.rawValue, for: .current)) { group in
                settingsGroup(group) { row in control(row) }
            }
        }
        .formStyle(.grouped)
    }

    /// One row, by the setting it edits — see `GeneralSettingsTab.control(_:)` for why the binding is
    /// the half that cannot cross.
    @ViewBuilder
    private func control(_ row: SettingsLayout.Row) -> some View {
        switch row.key {
        case SettingsKey.titleShellControlled:
            SettingsGlyphToggleRow(glyph(row), row.label, row.subtitle, isOn: $titleShellControlled)
        case SettingsKey.clipboardShellControlled:
            SettingsGlyphToggleRow(
                glyph(row), row.label, row.subtitle, isOn: store.refreshing($clipboardShellControlled),
            )
        case SettingsKey.clipboardReadKey: clipboardPicker(row, $clipboardRead)
        case SettingsKey.clipboardWriteKey: clipboardPicker(row, $clipboardWrite)
        // The video flags. Each optional field reads its unset state through the named default on
        // `VideoPreferences`, which is the half of an optional a table cannot state: the row says
        // what the control IS, the binding says what the absent value MEANS.
        case AllSettingsCatalog.RenderKey.videoQpSharp:
            settingsStepper(row, count(\.qpSharp, default: VideoPreferences.qpSharpDefault))
        case AllSettingsCatalog.RenderKey.videoQpCoarse:
            settingsStepper(row, count(\.qpCoarse, default: VideoPreferences.qpCoarseDefault))
        case AllSettingsCatalog.RenderKey.videoFecM:
            settingsStepper(row, count(\.fecM, default: VideoPreferences.fecMDefault))
        case AllSettingsCatalog.RenderKey.videoFecK:
            settingsStepper(row, count(\.fecK, default: VideoPreferences.fecKDefault))
        case AllSettingsCatalog.RenderKey.videoPacer: pacerPicker(row)
        case AllSettingsCatalog.RenderKey.videoSharpen:
            SettingsSliderRow(
                row.label,
                subtitle: row.subtitle,
                value: Binding(
                    get: { store.video.sharpen ?? VideoPreferences.sharpenDefault },
                    set: { store.video.sharpen = $0 },
                ),
                range: SettingsCatalog.Ladder.videoSharpen.range,
                step: SettingsCatalog.Ladder.videoSharpen.step,
                presets: SettingsCatalog.Ladder.videoSharpen.presets,
                readout: SettingsCatalog.Ladder.videoSharpen.readout,
            )
        default:
            if case .note = row.control { settingsNote(row) } else { bespoke(row) }
        }
    }

    // MARK: - Video (the sidecar's optional fields, read through their named defaults)

    /// One optional whole-number ``VideoPreferences`` field as a non-optional binding: absent reads
    /// as the default the daemon would have used, and a write makes it explicit.
    private func count(
        _ field: WritableKeyPath<VideoPreferences, Int?>, default unset: Int,
    ) -> Binding<Int> {
        Binding(
            get: { store.video[keyPath: field] ?? unset },
            set: { store.video[keyPath: field] = $0 },
        )
    }

    /// The pacer menu. Unset already presents on arrival, so the two REAL modes are the whole list —
    /// a third "Default" item would be a second way to pick `arrival` that nothing distinguishes.
    private func pacerPicker(_ row: SettingsLayout.Row) -> some View {
        SettingsOptionMenuRow(
            row.label,
            subtitle: row.subtitle,
            options: SettingsCatalog.options(.videoPacer, as: VideoPreferences.Pacer.self),
            selection: Binding(
                get: { store.video.pacer ?? VideoPreferences.pacerDefault },
                set: { store.video.pacer = $0 },
            ),
        )
    }

    /// The four groups this page draws itself. Three are surfaces rather than lists of settings — a
    /// free-text override box, the video host flags, a file path with two buttons — and the fourth is
    /// the searchable index of every setting there is. A ✎ jump in that index reports the SECTION it
    /// wants shown, and the navigator this page hangs under is what repoints.
    @ViewBuilder
    private func bespoke(_ row: SettingsLayout.Row) -> some View {
        if case let .bespoke(id) = row.control {
            SettingsBespokeSurface(id: id, store: store) { target in
                if let section = SettingsSection(rawValue: target) { selectedSection = section }
            }
        }
    }

    // MARK: - Privileges (title gates + OSC-52 master + read/write tri-state)

    /// A tri-state OSC-52 access picker, disabled while the master switch is off — a condition on
    /// another setting's VALUE, so it is the renderer's rather than the table's. The change re-applies
    /// the live libghostty config (the clipboard tokens feed `clipboard-read/write`).
    private func clipboardPicker(
        _ row: SettingsLayout.Row, _ selection: Binding<ClipboardAccess>,
    ) -> some View {
        SettingsOptionMenuRow(
            row.label,
            subtitle: row.subtitle,
            options: SettingsCatalog.options(.clipboardAccess),
            selection: store.refreshing(selection),
        )
        .disabled(!clipboardShellControlled)
    }
}

#endif
