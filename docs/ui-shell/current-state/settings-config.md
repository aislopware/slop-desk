# Settings UI & Configuration System — Current State

Surveyed 2026-06-25. All paths are absolute.

---

## Overview

Settings is built and wired end-to-end. Primary surfaces:

- **`SlopDeskSettingsScene`** — stock SwiftUI `Settings` scene (⌘,); separate system-chromed window on macOS. Hosts `SettingsView`, a `TabView` of five tabs: General, Terminal, Video, Keybindings, Advanced.
- **`PreferencesStore`** — single `@MainActor @Observable` source of truth, backed by `UserDefaults` + a `video-prefs.json` sidecar. In `SlopDeskWorkspaceCore` (headless-testable).
- **`SettingsKey` + `Defaults.Keys`** — typed `UserDefaults` key namespace for fire-time bool/enum flags, via the `sindresorhus/Defaults` product.
- **`EnvConfig` + `EnvBridge`** — precedence chain (`ProcessInfo env → overlay → compile-time default`); bridge maps typed prefs models onto `SLOPDESK_*` env keys.
- **`ThemeStore`** — runtime `@Observable` theme holder; crosses the AppKit `NSSplitViewController` boundary that SwiftUI environment cannot.
- **`WorkspaceTransfer`** — portable import/export codec for the whole workspace document (panes, snippets, presets, bookmarks). Store API (`exportWorkspaceData()` / `importWorkspace(_:mode:)`) complete; **UI file-picker hook missing**.

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| **Settings window** (macOS ⌘, / stock scene) | done | `SettingsView.swift:34–46` — `SlopDeskSettingsScene` wraps `SettingsView` in a SwiftUI `Settings` scene; wired in `SlopDeskClientApp.swift:293–295` |
| **Settings panels / tabs** (General, Terminal, Video, Keybindings, Advanced) | done | `SettingsView.swift:100–115` — `TabView` with five named tabs; all five tab structs in the same file |
| **iOS settings surface** | missing | `SettingsView.swift:32–33` comment: "macOS-only: the `Settings` scene is unavailable on iOS (the iOS settings surface lands as an in-app sheet later)". `SettingsView` is `#if canImport(SwiftUI)` cross-platform but no iOS host sheet yet |
| **Config keys + file (UserDefaults persistence)** | done | `PreferencesStore.swift:96–113` — `Key` enum with six versioned `UserDefaults` keys (`settings.terminal.v1`, `settings.video.v1`, etc.); encode/decode via `JSONEncoder`/`JSONDecoder` |
| **`video-prefs.json` sidecar (host daemon bridge)** | done | `EnvBridge.swift:66–140` — `VideoSidecar`, `writeSidecar`, `readSidecar`, `loadDefaultSidecarIntoEnvConfig`. Host path wired via `PreferencesStore.applyVideoAndAgent()` |
| **EnvConfig overlay (env → overlay → default precedence)** | done | `EnvConfig.swift:35–112` — `overlay: [String: String]`, `string(_:)`, `boolDefaultOn`, `boolDefaultOff`, `int`, `double`, `enumValue` |
| **Typed preferences models** | done | `VideoPreferences.swift`, `TerminalPreferences.swift`, `AgentPreferences.swift`, `AppearancePreferences.swift`, `KeybindingPreferences.swift` in `Sources/SlopDeskVideoProtocol/Settings/`; all `Codable + Sendable + Equatable` |
| **Themes — Monokai Pro 6-filter + Paper + Dark + System** | done | `AppearancePreferences.swift:31–42` — `ThemeChoice` enum, 9 cases; `ThemeStore.swift:44–66` — `apply(_:)` resolves to `SlateTheme`; wired in `SlopDeskClientApp.swift:65–67` |
| **Theme live-apply across NSSplitViewController boundary** | done | `ThemeStore.swift:33` — `didChangeNotification`; `SlopDeskSplitViewController.swift:118,194` — observes, re-pins window appearance + re-injects hosted columns |
| **Terminal color follow-theme (flat design)** | done | `PreferencesStore.swift:167–173` — `AppearanceApplier.resolveTerminalColors` closure reads `ThemeStore.shared.active`; `TerminalConfigBuilder.swift:50–71` — `backgroundOverride`/`foregroundOverride` params |
| **Terminal font settings (family, size, weight)** | done | `TerminalPreferences.swift:12–61` — `fontFamily`, `fontSize`, `fontWeight` (defaults SF Mono 13pt regular); UI in `SettingsView.swift:202–208` — `TextField` + `Stepper` |
| **Font picker (NSFontPanel / native picker)** | missing | Terminal tab uses a plain `TextField` for family name; no `NSFontPanel` or font browser |
| **Terminal cursor settings (style + blink)** | done | `SettingsView.swift:209–215` — `Picker` for `CursorStyle` enum + `Toggle` for blink |
| **Terminal scrollback setting** | done | `SettingsView.swift:216–222` — `Stepper` (1000–100,000 lines), mapped to bytes via `TerminalConfigBuilder.scrollbackLimitBytes` |
| **Terminal live-reload** | done | `PreferencesStore.swift:164–174` — `applyTerminal()` rebuilds `TerminalConfigBuilder.string(for:)` + bumps `TerminalConfigBroadcaster.shared.publish()` on every `terminal.didSet` |
| **Density setting (comfortable / compact)** | done | `SettingsView.swift:147–154` — segmented `Picker`; persisted via `SettingsKey.density` → `UserDefaults` on `appearance.didSet` |
| **Notifications settings (OSC 9/777 + long-command)** | done | `SettingsView.swift:158–162` — two `Toggle`s via `@Default(.oscNotifications)` / `@Default(.longCommandNotifications)` |
| **Privacy settings (redact secrets, default pane kind)** | done | `SettingsView.swift:164–171` — `Toggle` + `Picker` via `@Default(.redactSecrets)` / `@Default(.defaultPaneKind)` |
| **Fire-time bool keys via `Defaults.Keys`** | done | `SettingsKey.swift:84–93` — typed `Defaults.Keys` for `oscNotifications`, `longCommandNotifications`, `systemDialogPanes`, `autoSwitchLayouts`, `redactSecrets`, `recordClipboardHistory`, `hideStatusBar`, `showBlockDividers`, `defaultPaneKind` |
| **Video settings (QP, FEC, pacer, capture, sharpen)** | done | `SettingsView.swift:234–341` — `VideoSettingsTab`: optional-int steppers for QP/FEC, pacer picker, sharpen slider; symmetric-key warning; apply-on-reconnect labelling |
| **Agent detection settings** | done | `SettingsView.swift:273–277` — `optionalBoolToggle` for `agentDetect` and `agentHooks` in `VideoSettingsTab` |
| **Apply-timing labels (live vs reconnect)** | done | `SettingsView.swift:49–91` — `ApplyTiming` enum + `TimingChip` view; each section has a trailing chip |
| **Custom keybindings editor** | done | `KeybindingsEditorView.swift:26–305` — category-grouped list, click-to-record, Escape-to-cancel, conflict detection + banner, per-row reset-to-default; `KeyCaptureMonitor` swallows keystrokes during recording |
| **Keybinding overrides persistence** | done | `KeybindingPreferences.swift:16–211` — `overrides: [String: KeyChord]` + `sequenceOverrides: [String: KeySequence]`, versioned schema (v2), strict decode gate; persisted via `PreferencesStore.keybindings` → `UserDefaults` |
| **Keybinding overrides apply to registry** | done | `PreferencesStore.swift:203–205` — `applyKeybindings()` writes `WorkspaceBindingRegistry.activeOverrides = keybindings` on `didSet` |
| **Multi-key sequence (prefix + bare key) keybindings** | done | `KeybindingPreferences.swift:81–123` — `KeySequence` struct with `chords: [KeyChord]`; `sequenceOverrides` map; `WorkspaceKeyDispatcher` handles prefix dispatch |
| **Advanced settings (raw `SLOPDESK_*` overrides)** | done | `SettingsView.swift:353–412` — `AdvancedSettingsTab` with a `TextEditor` for `KEY=value` lines; commits into `store.rawOverrides`; folded LAST into overlay (typed prefs win over raw) |
| **Restore All Defaults button** | done | `SettingsView.swift:385–389` — `Button("Restore All Defaults", role: .destructive)` calls `store.resetAll()` |
| **Workspace import/export codec** | done | `WorkspaceTransfer.swift:17–79` — `export(_:)` (strips host connection, pretty-prints JSON), `decode(_:)` (magic check, version gate, hostile-input bounds, ID re-mint); `WorkspaceStore.exportWorkspaceData()` / `importWorkspace(_:mode:)` fully implemented |
| **Import/export UI (file picker in app menu or settings)** | missing | `exportWorkspaceData` / `importWorkspace` have zero call sites; no `.fileExporter` / `.fileImporter` in `SlopDeskClientUI`. Codec + store methods exist but unsurfaced |
| **Settings import/export (preferences backup)** | missing | `PreferencesStore` has no `export`/`import` for the settings models (only workspace documents export via `WorkspaceTransfer`) |
| **Snippet management UI (create/edit/delete)** | missing | `Snippet.swift` domain model exists; `WorkspaceStore` has `addSnippet`, `updateSnippet`, `deleteSnippet` (lines 1376–1409). No view in `SlopDeskClientUI` creates/edits snippets; `PaletteDataSource.swift` has no snippet entries |
| **Custom commands / text expansion UI** | missing | `SendKeysParser` + `SnippetExpander` fully implemented; snippets persisted on `Workspace.snippets`; but no Settings panel or palette integration to manage them |
| **Config file format (`~/.config/slopdesk/` or equivalent)** | na-remote | SlopDesk is a remote-coding tool; config stored in `UserDefaults` + the `video-prefs.json` sidecar (under `Application Support/SlopDesk/`). No dotfile reader/writer; the spec's config-file-format reference describes a future target |
| **Profiles (multiple named config sets)** | missing | `ClaudeCodeProfile.swift` survives only as a `Term` enum (`xterm-ghostty` vs `xterm-256color`); the broader named-profiles concept does not exist |
| **Connection settings UI (host/port/SSH)** | na-remote | Connection target managed via `AppConnection` / `ConnectionTarget` (Connect-to-Host editor in the workspace), not Settings. By design — the connection editor is a workspace-level control |

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

1. **Import/export UI not surfaced.** `WorkspaceStore.exportWorkspaceData()` / `importWorkspace(_:mode:)` are implemented and table-tested, but no `.fileExporter`/`.fileImporter` and no `Commands` menu item call them. `PreferencesStore.swift:1417` comment ("what the `.fileExporter` writes to disk") signals intent; plumbing is ready to wire.
2. **Snippet management UI absent.** Domain model, expander, send-keys parser, and CRUD store methods done. `PaletteDataSource.swift` has no snippet entries; `SlopDeskClientUI` has no snippet editor. Snippets can be neither created nor run from the UI.
3. **iOS Settings surface not started.** `SettingsView` is `#if canImport(SwiftUI)` and cross-platform by design, but the iOS host sheet does not exist yet; the macOS tab strip won't adapt automatically.
4. **Font picker is a plain TextField.** Terminal tab accepts a font family name as raw text; no `NSFontPanel`, font browser, or size preview. Functional but lower-fidelity than the target design.
5. **Settings not in an `OverlayCoordinator` in-window panel yet.** `SettingsView.swift:9–12` header notes the overlay host is "not yet mounted," so settings live in a separate system-chromed window. When the coordinator lands, the same tree can relocate.
6. **`blockBookmarks`, `notificationChipDismissed`, `notificationChipEnabled`** are persisted on `PreferencesStore` but surfaced in no Settings tab — fire-time state only.
7. **`hideStatusBar`, `showBlockDividers`, `systemDialogPanes`, `autoSwitchLayouts`, `recordClipboardHistory`** are declared in `SettingsKey` and `Defaults.Keys` but have no toggles in any tab; read at fire-time via `Defaults[.key]`, not toggleable from the GUI.

### Traps

- `SettingsKey.density` and `AppearancePreferences.density` both point at `"appearance.density"` — the same `UserDefaults` key. `PreferencesStore.applyAppearance()` writes `UserDefaults` directly; no conflict, but both paths must stay in sync.
- `KeybindingPreferences` has a strict schema-version gate (v2). Any old blob (v1 or missing version) decode-fails to the empty default — intentional no-backcompat, but a downgrade-then-upgrade loses keybind overrides.
- `EnvConfig.overlay` is `nonisolated(unsafe)` and documented write-once-at-launch, but IS mutated at runtime by `PreferencesStore.applyVideoAndAgent()` (every `video`/`agent`/`rawOverrides` `didSet`). Safe because mutation happens on `@MainActor` before concurrent pipeline reads; the "write-once" comment is aspirational, not enforced.
