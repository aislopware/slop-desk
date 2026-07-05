# Settings UI & Configuration System — Current State

Surveyed 2026-06-25. All paths are absolute.

---

## Overview

The settings system is substantially built and wired end-to-end. The primary surfaces are:

- **`SlopDeskSettingsScene`** — a stock SwiftUI `Settings` scene (⌘,) that opens a separate system-chromed window on macOS. It hosts `SettingsView`, a `TabView` with five tabs: General, Terminal, Video, Keybindings, Advanced.
- **`PreferencesStore`** — the single `@MainActor @Observable` source of truth, backed by `UserDefaults` and a `video-prefs.json` sidecar. Lives in `SlopDeskWorkspaceCore` (headless-testable).
- **`SettingsKey` + `Defaults.Keys`** — the typed `UserDefaults` key namespace for fire-time boolean/enum flags, served by the `sindresorhus/Defaults` product.
- **`EnvConfig` + `EnvBridge`** — the precedence chain (`ProcessInfo env → overlay → compile-time default`) and the bridge that maps typed prefs models onto `SLOPDESK_*` env keys.
- **`ThemeStore`** — the runtime `@Observable` theme holder; defeats the AppKit `NSSplitViewController` boundary that SwiftUI environment cannot cross.
- **`WorkspaceTransfer`** — a fully-implemented portable import/export codec for the entire workspace document (panes, snippets, presets, bookmarks). The store-level API (`exportWorkspaceData()` / `importWorkspace(_:mode:)`) is complete; the **UI file-picker hook is missing**.

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| **Settings window** (macOS ⌘, / stock scene) | done | `SettingsView.swift:34–46` — `SlopDeskSettingsScene` wraps `SettingsView` in a SwiftUI `Settings` scene; wired in `SlopDeskClientApp.swift:293–295` |
| **Settings panels / tabs** (General, Terminal, Video, Keybindings, Advanced) | done | `SettingsView.swift:100–115` — `TabView` with five named tabs; all five tab structs implemented in the same file |
| **iOS settings surface** | missing | `SettingsView.swift:32–33` comment: "macOS-only: the `Settings` scene is unavailable on iOS (the iOS settings surface lands as an in-app sheet later)". `SettingsView` is `#if canImport(SwiftUI)` cross-platform but no iOS host sheet exists yet |
| **Config keys + file (UserDefaults persistence)** | done | `PreferencesStore.swift:96–113` — `Key` enum with six versioned `UserDefaults` keys (`settings.terminal.v1`, `settings.video.v1`, etc.); encode/decode via `JSONEncoder`/`JSONDecoder` |
| **`video-prefs.json` sidecar (host daemon bridge)** | done | `EnvBridge.swift:66–140` — `VideoSidecar`, `writeSidecar`, `readSidecar`, `loadDefaultSidecarIntoEnvConfig`. Host path is wired via `PreferencesStore.applyVideoAndAgent()` |
| **EnvConfig overlay (env → overlay → default precedence)** | done | `EnvConfig.swift:35–112` — `overlay: [String: String]`, `string(_:)`, `boolDefaultOn`, `boolDefaultOff`, `int`, `double`, `enumValue` |
| **Typed preferences models** | done | `VideoPreferences.swift`, `TerminalPreferences.swift`, `AgentPreferences.swift`, `AppearancePreferences.swift`, `KeybindingPreferences.swift` — all in `Sources/SlopDeskVideoProtocol/Settings/`; all `Codable + Sendable + Equatable` |
| **Themes — Monokai Pro 6-filter + Paper + Dark + System** | done | `AppearancePreferences.swift:31–42` — `ThemeChoice` enum with 9 cases; `ThemeStore.swift:44–66` — `apply(_:)` resolves to `SlateTheme`; wired in `SlopDeskClientApp.swift:65–67` |
| **Theme live-apply across NSSplitViewController boundary** | done | `ThemeStore.swift:33` — `didChangeNotification`; `SlopDeskSplitViewController.swift:118,194` — observes and re-pins window appearance + re-injects hosted columns |
| **Terminal color follow-theme (flat design)** | done | `PreferencesStore.swift:167–173` — `AppearanceApplier.resolveTerminalColors` closure reads `ThemeStore.shared.active`; `TerminalConfigBuilder.swift:50–71` — `backgroundOverride`/`foregroundOverride` params |
| **Terminal font settings (family, size, weight)** | done | `TerminalPreferences.swift:12–61` — `fontFamily`, `fontSize`, `fontWeight` fields with defaults (SF Mono 13pt regular); UI in `SettingsView.swift:202–208` — `TextField` + `Stepper` |
| **Font picker (NSFontPanel / native picker)** | missing | Terminal tab uses a plain `TextField` for family name; no `NSFontPanel` integration or font browser |
| **Terminal cursor settings (style + blink)** | done | `SettingsView.swift:209–215` — `Picker` for `CursorStyle` enum + `Toggle` for blink |
| **Terminal scrollback setting** | done | `SettingsView.swift:216–222` — `Stepper` (1000–100,000 lines), mapped to bytes via `TerminalConfigBuilder.scrollbackLimitBytes` |
| **Terminal live-reload** | done | `PreferencesStore.swift:164–174` — `applyTerminal()` rebuilds `TerminalConfigBuilder.string(for:)` + bumps `TerminalConfigBroadcaster.shared.publish()` on every `terminal.didSet` |
| **Density setting (comfortable / compact)** | done | `SettingsView.swift:147–154` — segmented `Picker`; persisted via `SettingsKey.density` → `UserDefaults` on `appearance.didSet` |
| **Notifications settings (OSC 9/777 + long-command)** | done | `SettingsView.swift:158–162` — two `Toggle`s bound via `@Default(.oscNotifications)` / `@Default(.longCommandNotifications)` |
| **Privacy settings (redact secrets, default pane kind)** | done | `SettingsView.swift:164–171` — `Toggle` + `Picker` bound via `@Default(.redactSecrets)` / `@Default(.defaultPaneKind)` |
| **Fire-time bool keys via `Defaults.Keys`** | done | `SettingsKey.swift:84–93` — typed `Defaults.Keys` for `oscNotifications`, `longCommandNotifications`, `systemDialogPanes`, `autoSwitchLayouts`, `redactSecrets`, `recordClipboardHistory`, `hideStatusBar`, `showBlockDividers`, `defaultPaneKind` |
| **Video settings (QP, FEC, pacer, capture, sharpen)** | done | `SettingsView.swift:234–341` — `VideoSettingsTab` with optional-int steppers for QP/FEC, pacer picker, sharpen slider; symmetric-key warning; apply-on-reconnect labelling |
| **Agent detection settings** | done | `SettingsView.swift:273–277` — `optionalBoolToggle` for `agentDetect` and `agentHooks` in `VideoSettingsTab` |
| **Apply-timing labels (live vs reconnect)** | done | `SettingsView.swift:49–91` — `ApplyTiming` enum + `TimingChip` view; each settings section has a trailing chip |
| **Custom keybindings editor** | done | `KeybindingsEditorView.swift:26–305` — full category-grouped list, click-to-record, Escape-to-cancel, conflict detection + banner, reset-to-default per row; `KeyCaptureMonitor` swallows keystrokes during recording |
| **Keybinding overrides persistence** | done | `KeybindingPreferences.swift:16–211` — `overrides: [String: KeyChord]` + `sequenceOverrides: [String: KeySequence]`, versioned schema (v2), strict decode gate; persisted via `PreferencesStore.keybindings` → `UserDefaults` |
| **Keybinding overrides apply to registry** | done | `PreferencesStore.swift:203–205` — `applyKeybindings()` writes `WorkspaceBindingRegistry.activeOverrides = keybindings` on `didSet` |
| **Multi-key sequence (prefix + bare key) keybindings** | done | `KeybindingPreferences.swift:81–123` — `KeySequence` struct with `chords: [KeyChord]`; `sequenceOverrides` map; `WorkspaceKeyDispatcher` handles prefix dispatch |
| **Advanced settings (raw `SLOPDESK_*` overrides)** | done | `SettingsView.swift:353–412` — `AdvancedSettingsTab` with a `TextEditor` for `KEY=value` lines; commits into `store.rawOverrides`; folded LAST into overlay (typed prefs win over raw) |
| **Restore All Defaults button** | done | `SettingsView.swift:385–389` — `Button("Restore All Defaults", role: .destructive)` calls `store.resetAll()` |
| **Workspace import/export codec** | done | `WorkspaceTransfer.swift:17–79` — `export(_:)` (strips host connection, pretty-prints JSON), `decode(_:)` (magic check, version gate, hostile-input bounds, ID re-mint); `WorkspaceStore.exportWorkspaceData()` / `importWorkspace(_:mode:)` fully implemented |
| **Import/export UI (file picker in app menu or settings)** | missing | `exportWorkspaceData` / `importWorkspace` have zero call sites in any view or `Commands` group; no `.fileExporter` / `.fileImporter` modifier anywhere in `SlopDeskClientUI`. The codec + store methods exist but are not surfaced |
| **Settings import/export (preferences backup)** | missing | `PreferencesStore` has no `export`/`import` path for the settings models themselves (only workspace documents are exported via `WorkspaceTransfer`) |
| **Snippet management UI (create/edit/delete)** | missing | `Snippet.swift` domain model exists; `WorkspaceStore` has `addSnippet`, `updateSnippet`, `deleteSnippet` methods (lines 1376–1409). No view in `SlopDeskClientUI` creates or edits snippets. `PaletteDataSource.swift` has no snippet entries. |
| **Custom commands / text expansion UI** | missing | `SendKeysParser` + `SnippetExpander` are fully implemented; snippets are persisted on `Workspace.snippets`; but there is no Settings panel or command palette integration to manage them from the UI |
| **Config file format (`~/.config/slopdesk/` or equivalent)** | na-remote | SlopDesk is a remote-coding tool; configuration is stored in `UserDefaults` + the `video-prefs.json` sidecar (under `Application Support/SlopDesk/`). There is no config-file reader/writer for a dotfile format. The spec's config-file-format reference describes a future target. |
| **Profiles (multiple named config sets)** | missing | `ClaudeCodeProfile.swift` survives only as a `Term` enum (`xterm-ghostty` vs `xterm-256color`); the broader profile concept (multiple named settings profiles) does not exist |
| **Connection settings UI (host/port/SSH)** | na-remote | Connection target is managed via the `AppConnection` / `ConnectionTarget` flow (Connect-to-Host editor in the workspace), not inside Settings. No settings tab for connection parameters. This is by design (the connection editor is a workspace-level control). |

---

## Key Files

```
Sources/SlopDeskClientUI/Settings/SettingsView.swift
Sources/SlopDeskClientUI/Settings/KeybindingsEditorView.swift
Sources/SlopDeskClientUI/SlopDeskClientApp.swift           — scene wiring (SlopDeskSettingsScene)
Sources/SlopDeskClientUI/Footer/PreferencesEnvironment.swift — env slot for deep view injection
Sources/SlopDeskClientUI/DesignSystem/ThemeStore.swift

Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/AppearanceApplier.swift
Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceTransfer.swift
Sources/SlopDeskWorkspaceCore/Workspace/Domain/Snippet.swift

Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift
Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift
Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/AgentPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/AppearancePreferences.swift
Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift

Sources/SlopDeskHost/ClaudeCodeProfile.swift                 — only Term enum survives
```

---

## Notes

### Wiring gaps / dead seams

1. **Import/export UI not surfaced.** `WorkspaceStore.exportWorkspaceData()` and `importWorkspace(_:mode:)` are fully implemented and table-tested, but there is no `.fileExporter`/`.fileImporter` modifier and no `Commands` menu item calling them. The comment in `PreferencesStore.swift:1417` ("what the `.fileExporter` writes to disk") signals intent; the plumbing is ready to wire.

2. **Snippet management UI absent.** Domain model, expander, send-keys parser, and CRUD store methods are all done. `PaletteDataSource.swift` has no snippet entries, and `SlopDeskClientUI` has no snippet editor view. Snippets can be neither created nor run from the current UI.

3. **iOS Settings surface not started.** `SettingsView` is `#if canImport(SwiftUI)` and is designed to be cross-platform, but the iOS host sheet does not exist yet. The tab strip that works on macOS won't adapt automatically.

4. **Font picker is a plain TextField.** The Terminal settings tab accepts a font family name as raw text; there is no `NSFontPanel` integration, font browser, or font-size preview. This is functional but lower-fidelity than the documented target design.

5. **Settings are NOT in an `OverlayCoordinator` in-window panel yet.** The file header of `SettingsView.swift:9–12` explicitly notes this: the overlay host is "not yet mounted," so settings live in a separate system-chromed window. When the coordinator lands the same tree can relocate.

6. **`blockBookmarks`, `notificationChipDismissed`, `notificationChipEnabled` are persisted on `PreferencesStore` but not surfaced in any Settings tab** — they are fire-time state only.

7. **`hideStatusBar`, `showBlockDividers`, `systemDialogPanes`, `autoSwitchLayouts`, `recordClipboardHistory` are declared in `SettingsKey` and `Defaults.Keys`** but have no corresponding toggles in any Settings tab. They are read at fire-time via `Defaults[.key]` but cannot be toggled from the GUI.

### Traps

- The `SettingsKey.density` and `AppearancePreferences.density` both point at `"appearance.density"` — the same `UserDefaults` key. Changes to density in `PreferencesStore.applyAppearance()` write `UserDefaults` directly; there is no conflict, but both paths must remain in sync.
- `KeybindingPreferences` has a strict schema-version gate (v2). Any old persisted blob (v1 or missing version) decode-fails to the empty default — intentional no-backcompat, but means a user who downgrades and upgrades loses their keybind overrides.
- `EnvConfig.overlay` is `nonisolated(unsafe)` and documented as write-once-at-launch. It IS mutated at runtime by `PreferencesStore.applyVideoAndAgent()` (on every `video`/`agent`/`rawOverrides` `didSet`). This is safe because the mutation happens on `@MainActor` before any concurrent pipeline reads, but the "write-once" documentation comment is aspirational, not enforced.
