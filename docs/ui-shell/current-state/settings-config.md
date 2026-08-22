# Settings UI & Configuration System — Current State

First surveyed 2026-06-25. **Re-verified against the tree 2026-08-22** — the 06-25 survey had gone
wrong in every direction at once, so every row below was re-established from a symbol at a
`file:line` or from a search that came back empty. All paths are repo-relative.

### Why the 06-25 survey no longer described anything

Four waves landed on top of it and nobody re-ran the audit:

1. **The feature prune, 2026-07-03.** `WorkspaceTransfer` and the workspace export/import codec went
   in `0166057c`; `Snippet` + `SnippetExpander` went in `d63e1274`
   (`docs/DECISIONS.md` §"Recipes + Snippets REMOVED", §"Theme editor/import + workspace export/import
   REMOVED"). The old matrix listed all four as built-and-waiting-for-a-file-picker. They are deleted.
2. **ONE APPEARANCE, 2026-08-08 (user-directed).** The theme picker, the nine-case `ThemeChoice`
   catalogue, `ThemeStore`, the dual light/dark slots and the per-theme font map are deleted, not
   deprecated — `Sources/SlopDeskVideoProtocol/Settings/AppearancePreferences.swift:9-13` states it in
   the type, and `docs/DECISIONS.md:7393` is the ruling. `AppearancePreferences` has exactly one
   surviving field, `density`.
3. **The Rust lift.** What Settings OFFERS — the sections, every option group, the scalar ladders, the
   per-row copy and the per-platform gates — left Swift for `rust/slopdesk-settings/src/`
   (`settings_catalog.rs`, `settings_layout.rs`, `settings_rows.rs`) and is read back through
   `SettingsCatalog` / `SettingsLayout` / `AllSettingsCatalog`. A platform gate is a `Platform` field
   in a table now, not an `#if os(...)` in a view body.
4. **The client-UI split, 2026-08-17 (`docs/56-client-ui-split.md`).** `SlopDeskClientUI` became
   `SlopDeskMacUI` (AppKit) + `SlopDeskPhoneUI` (SwiftUI) over shared `SlopDeskClientCore`. The old
   file's "Key Files" list had been put through a blind `SlopDeskClientUI` → `SlopDeskPhoneUI`
   find-and-replace, so it named macOS AppKit files under the phone target and named three files that
   no longer exist at all.

---

## Overview

Settings is built and wired end-to-end, on **both** halves. Primary surfaces:

- **`MacSettingsWindow`** — the macOS window, in AppKit: an `NSSplitViewController` with a real
  `.sidebar` navigator beside a page. It asks the layout table for `Half.mac` and draws what comes
  back; it spells no group header, row label or option list of its own
  (`Sources/SlopDeskMacUI/Settings/MacSettingsWindow.swift:1-18`).
- **`SettingsSheet`** — the iOS host: a `NavigationStack` + `List`-of-sections presented from the
  phone root's toolbar gear, because iOS has no `Settings` scene and a two-column navigator does not
  map to compact width. It lists **all eight** sections, the same eight the Mac's navigator does
  (`Sources/SlopDeskPhoneUI/Settings/SettingsSheet.swift:1-20`).
- **`SettingsSection`** — the taxonomy, as a dispatch key only:
  `general, shell, controls, editor, agents, appearance, keybindings, advanced`
  (`Sources/SlopDeskClientCore/Settings/SettingsTaxonomy.swift:33-41`). Title, glyph and order come
  from Rust, so the two halves read one table.
- **`PreferencesStore`** — the single `@MainActor @Observable` source of truth, owning the five
  `Codable` models and persisting to `UserDefaults` plus the `video-prefs.json` sidecar. Headless, in
  `SlopDeskWorkspaceCore` (`Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore.swift:29-38`).
- **`SettingsKey` + `Defaults.Keys`** — the typed `UserDefaults` key namespace for fire-time flags,
  via the `sindresorhus/Defaults` product. It is far larger than the nine keys the old survey listed.
- **`EnvConfig` + `EnvBridge`** — the `ProcessInfo env → overlay → compile-time default` precedence
  chain; the bridge maps typed prefs onto `SLOPDESK_*` env keys.
- **A real config file.** `~/.config/slopdesk/config.toml` (XDG, with a `SLOPDESK_CONFIG_FILE`
  override) is read by the app and written by the `slopdesk config` CLI —
  `Sources/SlopDeskCLICore/CLIConfig.swift:29,50,77`. The 06-25 survey called this "a future target".

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| **Settings window (macOS)** | done | `MacSettingsWindow` — AppKit `NSSplitViewController`, `.sidebar` navigator, Esc via `cancelOperation(_:)` with the meaning owned by `SettingsEscapePolicy` |
| **Settings surface (iOS)** | done | `Sources/SlopDeskPhoneUI/Settings/SettingsSheet.swift` — in-app sheet, `NavigationStack` + `List`. The old "missing / lands later" row is stale |
| **Section set** | done, 8 sections both halves | `SettingsTaxonomy.swift:33-41` — `general, shell, controls, editor, agents, appearance, keybindings, advanced`. **Not** the old five tabs (General / Terminal / Video / Keybindings / Advanced) |
| **Editor section** | reserved, empty **on purpose** | `rust/slopdesk-settings/src/settings_catalog.rs:451,830-843` — "RESERVED. slopdesk has no file editor, so this page has no settings and says so." Present in the taxonomy so the navigator is not ragged |
| **Section titles / glyphs / order** | done, in Rust | `settings_catalog.rs`; read through `SettingsCatalog.section(_:)`. Neither renderer names a section |
| **Page shape (which groups, in what order, per platform)** | done, in Rust | `rust/slopdesk-settings/src/settings_layout.rs`, read by `Sources/SlopDeskClientCore/Settings/SettingsLayout.swift`. A platform gate is a `Platform` VALUE; the thirty-seven `#if os(macOS)` directives in the old 2100-line `body` are gone |
| **Option groups (choices, labels, captions)** | done, in Rust | `settings_catalog.rs`; near side `SettingsCatalog.swift`. The token crossing the boundary is the value the store PERSISTS, pinned by `SettingsOptionCatalogTests` against each Swift enum's `allCases` |
| **Searchable all-settings index** | done | `Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift` over `rust/slopdesk-settings/src/settings_rows.rs`; rendered by `MacAllSettingsIndex.swift` / `AllSettingsListView.swift`. Filtered per half — a Mac-only key is absent from the phone's index, deliberately (`SettingsSheet.swift:22-26`) |
| **`PreferencesStore` (single owner, headless)** | done | `PreferencesStore.swift:29-38`; five models at `:41-82` (`terminal`, `video`, `agent`, `keybindings`, `appearance`) plus `rawOverrides` |
| **Four apply paths (live prefs / sidecar / terminal reload / registry overrides)** | done | `PreferencesStore.swift:14-27` documents all four; `applyTerminal()` at `:163`, sidecar at `:270`, overlay fold at `:260` |
| **`video-prefs.json` sidecar (host daemon bridge)** | done | `EnvBridge.VideoSidecar`; written from `PreferencesStore.applyVideoAndAgent()` |
| **`device-prefs.json` (device-local keys)** | done | `AllSettingsCatalog.swift:84`, `AllSettingsCatalog.deviceLocalKeys`; docs/45 §7.3 / §8.2 |
| **EnvConfig overlay precedence** | done | `EnvConfig.swift:14,38-41` — `env → overlay → default`; a real env var always wins |
| **Typed preferences models** | done | `Sources/SlopDeskVideoProtocol/Settings/{Terminal,Video,Agent,Appearance,Keybinding}Preferences.swift` — all `Codable + Sendable + Equatable` |
| **Config file (`~/.config/slopdesk/config.toml`)** | done | `Sources/SlopDeskCLICore/CLIConfig.swift:6,29,50,77` — XDG path with a `SLOPDESK_CONFIG_FILE` override; `KeybindConfigLoader` reads the `keybind = <chord>:<action>` lines, every other key routes through the store |
| **Live `config get/set/unset/show` bridge** | done | `Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore+ConfigBridge.swift:1-12` — `WorkspaceControlBackend.configGet/Set/Unset/Show` route documented render keys through the typed model, so a `config set` genuinely reflows live. A key with no live binding returns an honest error rather than a silent success |
| **Settings ▸ Advanced ▸ Config File (path + Open + Reload)** | done, **macOS only, ruled** | `Sources/SlopDeskClientCore/Settings/SettingsConfigFile.swift` (path, `prepared()`, `reload(_:)`); rendered at `Sources/SlopDeskMacUI/Settings/MacAdvancedSurfaces.swift:140,155,158`. Gated `Platform::Mac` by the layout table with the reason stated at `SettingsConfigFile.swift:4-5` — "`~/.config` is a path iOS has none of" |
| **Advanced raw `SLOPDESK_*` overrides editor** | done, **macOS only, ruled** | `MacAdvancedSurfaces.swift:54,93-101` — a `KEY=value` text editor committing into `store.rawOverrides`, folded LAST into the overlay so typed prefs win. Gated `Platform::Mac` as data; the reason is recorded at `SettingsSheet.swift:22-24` (a raw editor over flags the device never reads) |
| **Theme picker / theme catalogue / dual light-dark slots / per-theme fonts** | **REMOVED 2026-08-08** | `AppearancePreferences.swift:9-13` — "`ThemeChoice` … deleted, not deprecated"; `docs/DECISIONS.md:7393`. `ThemeStore` survives only as a deletion note at `Sources/SlopDeskSlate/SlateAppearancePin.swift:3`. The app ships ONE appearance |
| **Density (comfortable / compact)** | done | `AppearancePreferences.swift:18` (the only surviving field); bound at `MacSettingsBindings.swift:215` and `SettingsPages.swift:788` |
| **Font family picker with live specimens + scope tabs + fallback list** | done, both halves | `Sources/SlopDeskMacUI/Settings/MacFontFamilySurface.swift` (an `NSMenu` whose `attributedTitle` renders each family in its own face) and `Sources/SlopDeskPhoneUI/Settings/FontSettingsView.swift` (a search popover, because a SwiftUI `Menu` flattens a custom font). Words + parse rules from `SettingsFontSurface` / `SettingsFontFallbackList` / `InstalledFontFamilies` in `SlopDeskClientCore`. The old "plain TextField, no font browser" row is stale |
| **Per-scope Light/Dark font overrides** | **REMOVED 2026-08-08** | `FontSettingsView.swift:12-14` — "The Computed / Light Theme / Dark Theme tabs went with the theme picker … with one appearance there is one font slot" |
| **Terminal font size / line-height / ligatures / style + rendering** | done | `FontSettingsView.swift:5-9`; binds `store.terminal` so a change flows `terminal` `didSet` → `applyTerminal()` → `TerminalConfigBroadcaster` and re-applies live |
| **Terminal live-reload** | done | `PreferencesStore.swift:163` — rebuilds the libghostty config string via `TerminalConfigBuilder` and bumps `TerminalConfigBroadcaster` |
| **Cursor settings + live preview** | done | `Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift`, `Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift`, `Sources/SlopDeskClientCore/Settings/CursorColorHex.swift` |
| **Notifications settings** | done | `SettingsKey.swift:145-177` — far past the old two toggles: `onFinish`, `onError`, `onWatchFinish`, `whileForeground`, `bounceDockIcon`, `soundShellControlled`, `soundOnErrorExit`, and four agent-specific notify/sound keys |
| **Agent badge settings** | done | `SettingsKey.swift:185-189` — `agentBadgeWhileProcessing`, `agentBadgeWhenComplete`, `agentBadgeWhenAwaitingInput`; tab-badge keys at `:196-208` |
| **Controls / privileges (copy-on-select, paste protection, mouse, links, secure input, shell-controlled title + clipboard)** | done | `SettingsKey.swift:215-315` — ~30 keys |
| **Custom link schemes + hint patterns** | done | `SettingsKey.swift:306-315`; `Sources/SlopDeskClientCore/Settings/CustomLinkSchemes.swift` |
| **Keybindings editor** | done, **both halves** | `Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift` (AppKit) and `Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift` (SwiftUI) render the SAME registry list. The layout table calls the group `Platform::Both` and says why: a phone with a hardware keyboard runs the same bindings. Key Bindings was the one section the phone used to drop; it does not any more (docs/56 increment 30) |
| **Chord capture / record / cancel / unbind** | done | `KeybindingCapture` over `slopdesk_video::key_naming` — the same table the dispatcher builds chords from, so a chord recorded is the chord that fires (`MacKeybindingsEditor.swift:8-11`). Phone capture host: `Sources/SlopDeskPhoneUI/Settings/KeybindingCaptureHost.swift` |
| **Keybinding overrides persistence** | done | `KeybindingPreferences.swift:139,177-185` — `overrides: [String: KeyChord]`, schema v3, strict decode gate |
| **Multi-key sequence (prefix + bare key) bindings** | **REMOVED** | `KeybindingPreferences.swift:132-134` records `prefixKey` / `sequenceOverrides` as REMOVED fields a v3 blob may still carry and which are "simply not read". The old row claiming a live `KeySequence` map is stale; ⌃B prefix mode is a deleted feature |
| **Overrides apply to the registry** | done | `PreferencesStore` publishes `KeybindingPreferences` to `WorkspaceBindingRegistry.activeOverrides`; the registry stays the single binding table |
| **Restore All Defaults** | done, with a correction | `PreferencesStore.resetAll()` at `:319`, `resetAdvancedOnly()` at `:369`, and `resetEverySetting(deviceLocal:)` at `:351`. The button must call the last of the three — `resetAll()` cannot reach `device-prefs.json`, and the confirmation promises EVERY setting (`MacAllSettingsIndex.swift:159-160`) |
| **Settings import/export (preferences backup)** | never built | No `.fileExporter` / `.fileImporter` over `PreferencesStore` anywhere. The only `fileImporter` in the tree is `Sources/SlopDeskPhoneUI/Pane/PaneFileImporter.swift`, which imports a file into a PANE, not settings |
| **Workspace import/export codec + UI** | **REMOVED 2026-07-03** | `0166057c`; `docs/DECISIONS.md` §"Theme editor/import + workspace export/import REMOVED". `WorkspaceTransfer`, `exportWorkspaceData()` and `importWorkspace(_:mode:)` have zero occurrences in `Sources`, `Tests` or `rust/slopdesk-*/src`. The old matrix's "codec done, file-picker missing" pair is now two rows about deleted code |
| **Snippet management UI** | **REMOVED 2026-07-03** | `d63e1274`; `docs/DECISIONS.md` §"Recipes + Snippets REMOVED". `Snippet` and `SnippetExpander` have zero occurrences. `SendKeysParser` was kept and moved to `Domain/SendKeysParser.swift` |
| **Custom commands / text expansion UI** | **REMOVED 2026-07-03** | same commit. The old row's premise ("expander fully implemented, only the panel is missing") no longer holds — the expander is gone |
| **Profiles (multiple named config sets)** | never built | `ClaudeCodeProfile` survives only as a `Term` enum (`Sources/SlopDeskHost/ClaudeCodeProfile.swift`, consumed by `Sources/SlopDeskHost/TerminfoResolver.swift:25-48`). The broader named-profiles concept does not exist and nothing plans it |
| **Connection settings UI (host/port/SSH)** | na-remote | Managed via `AppConnection` / `ConnectionTarget` in the workspace, not Settings — by design, the connection editor is a workspace-level control. SSH itself is a stated scope cut (`docs/DECISIONS.md` §E11) |

---

## Key Files

```
Sources/SlopDeskMacUI/Settings/MacSettingsWindow.swift        — the macOS window (AppKit split + navigator)
Sources/SlopDeskMacUI/Settings/MacSettingsNavigator.swift     — source-list navigator
Sources/SlopDeskMacUI/Settings/MacSettingsPage.swift          — generic page built from settings_layout
Sources/SlopDeskMacUI/Settings/MacSettingsRows.swift          — row renderers
Sources/SlopDeskMacUI/Settings/MacSettingsBindings.swift      — key → binding switch (Mac half)
Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift     — chord editor, AppKit
Sources/SlopDeskMacUI/Settings/MacFontFamilySurface.swift     — font family + fallback, AppKit
Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift  — cursor preview, AppKit
Sources/SlopDeskMacUI/Settings/MacAdvancedSurfaces.swift      — raw SLOPDESK_* editor + Config File group
Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift      — searchable index + reset affordance

Sources/SlopDeskPhoneUI/Settings/SettingsSheet.swift          — the iOS host sheet
Sources/SlopDeskPhoneUI/Settings/SettingsPages.swift          — section → body dispatch (eight private pages)
Sources/SlopDeskPhoneUI/Settings/AllSettingsListView.swift    — searchable index, phone half
Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift  — chord editor, SwiftUI
Sources/SlopDeskPhoneUI/Settings/KeybindingCaptureHost.swift  — phone chord capture
Sources/SlopDeskPhoneUI/Settings/FontSettingsView.swift       — font family + fallback, SwiftUI
Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift      — cursor preview, SwiftUI
Sources/SlopDeskPhoneUI/PreferencesEnvironment.swift          — env slot for deep view injection

Sources/SlopDeskClientCore/Settings/SettingsTaxonomy.swift    — the eight-case dispatch key
Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift     — near side of what Settings OFFERS
Sources/SlopDeskClientCore/Settings/SettingsLayout.swift      — near side of a page's SHAPE + Platform gate
Sources/SlopDeskClientCore/Settings/SettingsConfigFile.swift  — resolved config path + Open/Reload verbs
Sources/SlopDeskClientCore/Settings/SettingsEscapePolicy.swift— what Esc means in Settings
Sources/SlopDeskClientCore/Settings/CustomLinkSchemes.swift
Sources/SlopDeskClientCore/Settings/CursorColorHex.swift
Sources/SlopDeskClientCore/Settings/LineHeightMultiplier.swift

Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore+ConfigBridge.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift
Sources/SlopDeskWorkspaceCore/Workspace/Store/AppearanceApplier.swift

Sources/SlopDeskCLICore/CLIConfig.swift                       — the config file path + XDG resolution

Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift
Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift
Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/AgentPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/AppearancePreferences.swift
Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift
Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift

rust/slopdesk-settings/src/settings_catalog.rs — sections, option groups, scalar ladders
rust/slopdesk-settings/src/settings_layout.rs  — which groups a page shows, and for which Platform
rust/slopdesk-settings/src/settings_rows.rs    — every row's key, label, description, default, keywords
```

---

## Notes

### Platform splits (macOS only — each one ruled, not accidental)

Under `docs/56-client-ui-split.md:99-102,144-145` the rule is **layout diverges; capability does
not**, so a macOS-only group needs a stated reason. Both of the ones that exist have one, recorded
next to the code:

1. **Advanced ▸ Config File** — `Platform::Mac` because "`~/.config` is a path iOS has none of"
   (`SettingsConfigFile.swift:4-5`).
2. **Advanced ▸ raw `SLOPDESK_*` editor** and the **Video host-flag group** — `Platform::Mac`,
   because they edit flags the device the phone runs on never reads (`SettingsSheet.swift:22-24`).

Consequence worth stating plainly: `AllSettingsCatalog.entries(mac:)` filters the index by half, so a
Mac-only key is absent from the phone's SEARCH as well as from its pages. That is deliberate — a row
the phone can never write is a row it must not offer — not an oversight.

### Wiring gaps / dead seams

1. **`blockBookmarks` is store-only.** Persisted on `PreferencesStore`
   (`WorkspaceStore+Blocks.swift`, `PreferencesStoreBlockBookmarksTests.swift`) and surfaced in no
   Settings section. Fire-time state only.
2. **The Editor section is empty on purpose**, not unwired — `settings_catalog.rs:830-843` renders a
   bespoke `editor-empty` body that states its own emptiness, so the reserved page cannot be mistaken
   for a page that failed to load.
3. **Reset has three verbs and only one is right for the button.** `resetAll()` misses
   `device-prefs.json`; `resetEverySetting(deviceLocal:)` is what matches the confirmation's wording
   (`PreferencesStore.swift:342-351`, `MacAllSettingsIndex.swift:159-160`).

**Resolved since 06-25 — do not re-file these as gaps.** The old note 7 listed five keys as declared
but untoggleable: `hideStatusBar`, `showBlockDividers`, `systemDialogPanes`, `autoSwitchLayouts` and
`recordClipboardHistory`. Four of those five keys have **zero occurrences anywhere in the tree** —
they went with the panes and status bar they gated. The fifth, `recordClipboardHistory`, now has a
real row (`settings_layout.rs`, `settings_rows.rs`, both UI halves). The old note 6 listed
`notificationChipDismissed` and `notificationChipEnabled` the same way; both are also gone. Only
`blockBookmarks` from those two notes survives, as note 1 above.

### Traps

- `SettingsKey.density` and `AppearancePreferences.density` still point at the same `UserDefaults`
  key, `"appearance.density"` (`SettingsKey.swift:329`). Both paths must stay in sync; the config
  bridge writes the model (`PreferencesStore+ConfigBridge.swift:28,58,76`) and the store mirrors it at
  `PreferencesStore.swift:288`.
- `KeybindingPreferences` has a strict schema-version gate, now **v3**, not v2
  (`KeybindingPreferences.swift:129-134,177-183`). Any blob at another version decode-fails to the
  empty default. The v2→v3 step only REMOVED fields, so a v3 blob still carrying `prefixKey` /
  `sequenceOverrides` decodes fine — those keys are simply not read.
- `EnvConfig.overlay` is `nonisolated(unsafe)` and documented write-once-at-launch
  (`EnvConfig.swift:29,38`), but IS mutated at runtime by `PreferencesStore.applyVideoAndAgent()` on
  every `video` / `agent` / `rawOverrides` `didSet`. Safe because mutation happens on `@MainActor`
  before concurrent pipeline reads; the "write-once" comment is aspirational, not enforced.
- The config bridge deliberately refuses keys with no live binding rather than reporting a silent
  success (`PreferencesStore+ConfigBridge.swift:10-12`). If a `config set` starts succeeding for a key
  nothing reads, that rule has been broken, not extended.
