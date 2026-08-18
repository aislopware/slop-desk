// SettingsBespokeSurfaces — the groups a table cannot describe, and the one door onto them.
//
// `Control.bespoke(id)` is the layout table's admission that a group is not a list of settings: an
// override box that parses free text, a card that writes someone's `~/.claude/settings.json`, a page
// that states its own emptiness. The table still says WHERE each one goes and on which platform, which
// is the part that was worth crossing; what it cannot say is what the surface looks like.
//
// Both halves resolve a bespoke id through ``SettingsBespokeSurface``, and that is the point of this
// file. The AppKit page draws every DESCRIBED row itself — a switch is an `NSSwitch`, a menu is an
// `NSPopUpButton` — because that is where a mouse-driven settings window differs from a touch sheet.
// A bespoke surface is not a control kind, so there is nothing for the two halves to differ ABOUT:
// re-drawing a two-hundred-key searchable index twice would be two chances to get the same words wrong.
// So the Mac hosts these in an `NSHostingView` and the phone renders them inline.
//
// THE TWO EXCEPTIONS ARE NOT EXCEPTIONS. `os-integration` and `cli-install` are gated to
// `Platform::Mac` by the layout table and their whole content is LaunchServices and `/usr/local/bin` —
// there is no phone version of either to keep in step with, so the Mac draws them in AppKit
// (`SlopDeskMacUI/FirstLaunch`) and reuses them for the first-launch checklist, which is where they had
// been written a SECOND time until that move.
//
// Each surface owns whatever display-time state it needs (what is in the override buffer, which font
// scope is showing) rather than taking it from a host page, which is what lets one be dropped into
// either half with nothing but a store.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskCLICore
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - The door

/// A bespoke group, by the id the layout table carries.
///
/// An id with no arm renders NOTHING — the honest answer for a surface a build does not have, and the
/// same contract a key with no arm holds on the described side. Two ids have no arm ON PURPOSE:
/// `os-integration` and `cli-install` are groups the layout table gates to `Platform::Mac`, and what
/// they do is LaunchServices and `/usr/local/bin`, so the Mac draws them in AppKit and the phone never
/// asks. A surface is drawn once — but "once" means once per platform that HAS it.
///
/// `onJump` is how the All-Settings index repoints the navigator: a SECTION ID, because the two halves
/// navigate differently (a `List` selection here, an `NSTableView` row there) and neither owns the
/// other's selection type.
package struct SettingsBespokeSurface: View {
    private let id: String
    private let store: PreferencesStore
    private let onJump: (String) -> Void

    package init(id: String, store: PreferencesStore, onJump: @escaping (String) -> Void = { _ in }) {
        self.id = id
        self.store = store
        self.onJump = onJump
    }

    package var body: some View {
        switch id {
        case "notification-permission": NotificationPermissionRow()
        case "editor-empty": EditorEmptySurface()
        case "claude-hooks": ClaudeHooksSurface()
        // The Font-Family scope tabs over two different bodies — the primary family with its three
        // derived faces, or the ordered fallback list — and the "Aa" specimen combobox
        // (`font-setting.png`). Size, line height, ligatures and style are described rows above it.
        case "font-family": FontSettingsView(store: store)
        case "cursor-preview": CursorPreviewSurface(store: store)
        case "keybindings": KeybindingsEditorView(store: store)
        case "raw-overrides": RawOverridesSurface(store: store)
        case "video-host": VideoHostSettingsView(store: store)
        case "config-file": ConfigFileSurface(store: store)
        case "all-settings": AllSettingsListView(store: store, onJump: onJump)
        default: EmptyView()
        }
    }
}

// MARK: - Editor (reserved)

/// A RESERVED page states its own emptiness in the empty-state voice (MERIDIAN C3: muted symbol,
/// short title, one-line cause) rather than as a "File editor — Not available" row, which read like a
/// broken control. NOT a new `SlateEmptyState.Cause`: that enum's typed causes are the pane area's
/// connection states, with pinned copy per case.
struct EditorEmptySurface: View {
    var body: some View {
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

// MARK: - Agents → Claude Code

/// The CLAUDE CODE card (`install-agent-integeration.png`): a bold "Install Hooks" title + gray
/// description with trailing pill buttons (Install when not installed, "Installed" disabled +
/// Uninstall when installed) and a Status row. Disabled with a "Connect a session" note while no pane
/// backs the card. Claude-only.
struct ClaudeHooksSurface: View {
    @Environment(\.agentHooksController) private var agentHooks

    var body: some View {
        let state = AgentSettingsCard.installState(agentHooks)
        Group {
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
        .task { await agentHooks?.refresh() }
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
}

// MARK: - Appearance → the caret preview

/// The live caret preview with its colour wells and text-under toggle (`cursor-style.png`). AppKit,
/// hence the gate — which is one of the last in this directory and dies with the AppKit shell.
struct CursorPreviewSurface: View {
    let store: PreferencesStore

    var body: some View {
        #if os(macOS)
        CursorPreviewView(store: store)
        #endif
    }
}

// MARK: - Advanced → Raw overrides

/// The power-user raw `SLOPDESK_*` box, folded LAST into the env overlay so a typed raw key beats the
/// matching typed pref — with the note that a REAL process env var still wins over the lot.
///
/// The buffer is rendered FROM the store and re-rendered whenever the store's map changes, which is
/// what makes "Reset All Settings" clear the box: the reset writes the store, and the box follows.
/// It used to need a callback threaded from the All-Settings list two groups below, which only worked
/// while one page happened to own both.
struct RawOverridesSurface: View {
    @Bindable var store: PreferencesStore

    /// Local edit buffer of `key = value` lines; committed into `store.rawOverrides` on change.
    @State private var text: String = ""

    var body: some View {
        Group {
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
        .onAppear { text = Self.render(store.rawOverrides) }
        .onChange(of: store.rawOverrides) { _, new in
            // Only when the store says something the buffer does not: re-rendering on every commit
            // would re-order the reader's lines under their cursor as they typed.
            let rendered = Self.render(new)
            if Self.parse(text) != new { text = rendered }
        }
    }

    /// Parse the `key=value` lines and write them into `store.rawOverrides` (empty / malformed lines ignored).
    private func commit(_ raw: String) {
        let map = Self.parse(raw)
        if map != store.rawOverrides { store.rawOverrides = map }
    }

    private static func parse(_ raw: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    private static func render(_ map: [String: String]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Advanced → Config File

/// Settings → Advanced → CONFIG FILE: the resolved config path + "Open Config File" + "Reload Config".
/// macOS-only per the table — the config file lives under `~/.config`, inaccessible on iOS. "Open
/// Config File" creates the parent dir + the file (if absent) then opens it in the default editor, so
/// a fresh install lands usable. "Reload Config" mirrors the CLI `config reload`:
/// `reapplyLiveSettings()` + the config-reload broadcast.
struct ConfigFileSurface: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Group {
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
        }
    }
}
#endif
