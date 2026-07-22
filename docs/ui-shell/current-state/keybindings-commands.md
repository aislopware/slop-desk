# Keybindings & Command Routing — Current State

Gap analysis vs the documented default keymap. Assessed 2026-06-25.

> **2026-07-22 — PREFIX MODE REMOVED.** Every row/note below referencing the tmux-style prefix
> (`PrefixStateMachine`, `defaultPrefixChord`, `prefixKey`, sequence tables, send-prefix, the Settings
> Workspace-Prefix row) is HISTORICAL: the feature was deleted outright — see `docs/DECISIONS.md`
> ("Prefix mode is REMOVED", 2026-07-22). The ⌘ plane (single chords + `text:`/`unbind:` overrides) is
> the only workspace-chord surface; `TerminalKeyInterceptor` survives as a single-chord-only fallback.

---

## Overview

The keybinding/command-routing stack is **substantially complete** for the core dispatch pipeline. One live wiring gap: `WorkspaceKeyDispatcher` is built without `togglePalette`/`toggleCheatSheet` closures, so ⌘K (palette) and ⌘/ (cheat sheet) are **no-ops from the keyboard** — the closures are `nil`, so `togglePalette?()`/`toggleCheatSheet?()` in `WorkspaceBindingRouting.routeTree` silently skip. Registry, prefix machine, override model, and editor are done.

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| Binding registry — single source of truth | done | `WorkspaceBindingRegistry.swift:222` — `allBindings` + `selectTabBindings`; used by menu, palette, cheat sheet, dispatcher, tests |
| Default keymap (full set) | done | 35+ actions (split/close/focus/tab/session/view/blocks) + ⌘1…⌘9 select-tab generated; `WorkspaceBindingRegistry.swift:228–488` |
| NSEvent prefix monitor (tmux-style, default ⌃B) | done | `WorkspaceKeyDispatcher.swift:78` — `NSEvent.addLocalMonitorForEvents(matching:.keyDown)`; installed via `.task { keyDispatcher.install() }` at `SlopDeskClientApp.swift:234` |
| Prefix state machine (arm/resolve/timeout/disarm) | done | `PrefixStateMachine` in `CommandInterpreter.swift:369`; 6 states (arm, resolve, passthrough, sendPrefixLiteral, disarmSwallow, expire); pinned by `PrefixStateMachineTests` |
| Configurable prefix chord | done | Default ⌃B (`WorkspaceBindingRegistry.defaultPrefixChord`); user override = Settings ▸ Key Bindings ▸ Workspace Prefix (`KeybindingPreferences.prefixKey` → `resolvedPrefixChord`); live re-key via `PreferencesStore.onPrefixKeyApply` → `WorkspaceStore.applyWorkspaceKeyPrefix` + `WorkspaceKeyDispatcher.setPrefix` |
| Double-tap prefix → send literal | done | `WorkspaceKeyDispatcher.swift:126–134`; `KeyChordNormalizer.literalBytes(for:)` emits the C0 byte to the focused pane |
| Single-chord dispatch (⌘D/⌘T/…) | done | `WorkspaceKeyDispatcher.swift:113–116`; reads `resolvedChordTable` (override-aware) |
| Multi-key prefix sequence dispatch (⌃B→D) | done | `WorkspaceKeyDispatcher.swift:65–66`; `resolveSequenceAfterPrefix` over `resolvedSequenceTable`; `WorkspaceBindingOverrides.swift:85–98` |
| `route()` action → store op | done | `WorkspaceBindingRouting.routeTree()` at `WorkspaceBindingRouting.swift:47` — every `WorkspaceAction` case → matching `WorkspaceStore` tree op; tested in `TreeCommandRoutingTests` |
| Binding registry wiring — live call-sites | done | `WorkspaceKeyDispatcher.dispatch()` calls `WorkspaceBindingRegistry.route()`; `TerminalKeyInterceptor` (per-surface fallback) also routes via `route()` at `WorkspaceStore+Keybinding.swift:20`; `ActionsPaletteSource` rows drive store ops directly |
| Per-surface terminal key interceptor | done | `TerminalKeyInterceptor.swift` — second-line interceptor for libghostty surfaces; wired in `WorkspaceStore.wireKeyInterceptor()` at `WorkspaceStore+Keybinding.swift:16`; reads same `resolvedChordTable` |
| User keybinding overrides (rebind) | done | `KeybindingPreferences.swift` (serialisable model); `WorkspaceBindingOverrides.swift` (`resolvedChordTable`, `resolvedSequenceTable`); `PreferencesStore` publishes to `WorkspaceBindingRegistry.activeOverrides` |
| Keybindings settings editor UI | done | `KeybindingsEditorView.swift:26`; grouped by `WorkspaceAction.Category`, `NSEvent` capture monitor on macOS, read-only on iOS; wired in `SettingsView.swift:349` |
| Conflict detection | done | `KeybindingPreferences.conflicts()` via `store.keybindingConflicts()`; shown in `KeybindingsEditorView` conflict banner |
| ⌘K command palette — OverlayCoordinator | done | `OverlayCoordinator.swift:104`; `togglePalette()`/`openPalette()`/`closePalette()`; `SearchMixer` + `ActionsPaletteSource` + `TabsPaletteSource` + empty stubs for files/conversations/repos |
| ⌘K palette — keyboard dispatch wired | **partial** | `WorkspaceAction.commandPalette` registered (id `"view.palette"`, chord ⌘K); `WorkspaceBindingRouting.routeTree:96` calls `togglePalette?()`; BUT dispatcher constructed at `SlopDeskClientApp.swift:195` with NO `togglePalette` closure → ⌘K is silently a no-op. Palette still opens via its own UI rows. |
| ⌘/ cheat sheet — OverlayCoordinator | done | `OverlayCoordinator.swift:256`; `cheatSheetVisible` + `toggleCheatSheet()`/`openCheatSheet()`/`closeCheatSheet()` |
| ⌘/ cheat sheet — keyboard dispatch wired | **partial** | Same gap: `WorkspaceBindingRouting.routeTree:97` calls `toggleCheatSheet?()`; dispatcher built without that closure at `SlopDeskClientApp.swift:195` → ⌘/ is a no-op. |
| Cheat sheet view | **partial** | `OverlayCoordinator.cheatSheetVisible` defined; `WorkspaceBindingRegistry.groupedForDisplay` supplies data. No `KeyboardCheatSheetView.swift` in the tree — the view rendering `cheatSheetVisible` does not exist yet. |
| SwiftUI `.commands` menu | **partial** | Referenced in docs (`WorkspaceCommands: Commands`), `WorkspaceBindingRegistry.swift:211` docstring. No `WorkspaceCommands.swift` in live source — not yet ported to the rebuilt shell. Chords fire via the NSEvent monitor instead. |
| Palette — fuzzy match (fzf) | done | `FuzzyMatcher` (vendored fzf FuzzyMatchV2) in `SearchMixer.ranked()` at `PaletteDataSource.swift:277`; bench = `slopdesk-fuzzybench` |
| Palette — scope filters (actions/tabs/files/…) | partial | `.actions`/`.tabs` live; `.files`/`.conversations`/`.repos` registered with empty stubs (`EmptyPaletteSource`) — TODO host directory/AI wire |
| Palette — recents | done | `OverlayCoordinator.recentPaletteItems()` maps `store.recentCommands` ring to catalog rows |
| ⌘1…⌘9 select-tab | done | `WorkspaceBindingRegistry.selectTabBindings` (9 entries); `selectTabRepresentative` for display; dispatch in `routeTree:121` via `store.selectTabNumber(n)` |
| iOS keybinding dispatch | na-remote | No `UIKeyCommand`/hardware-keyboard dispatch on iOS — `TerminalKeyInterceptor` and the NSEvent monitor are macOS-only (`#if os(macOS)`). iOS hardware keyboards fall through untouched. |
| Binding conflict uniqueness pinned by tests | done | `TreeCommandRoutingTests` asserts all chords are ⌘/⌥-prefixed and unique; `KeySequenceRegistryTests` covers sequence table |
| Override-apply pipeline (settings → registry → dispatcher) | done | `PreferencesStore.keybindings.didSet` → `WorkspaceBindingRegistry.activeOverrides = …` → `resolvedChordTable`/`resolvedSequenceTable` rebuilt per read (computed properties) |

---

## Key Files

- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` — single source of truth: all `WorkspaceAction` cases, `WorkspaceBinding` rows, `chordTable`, `sequenceTable`, `glyph()` helpers
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift` — W13 override layer: `resolvedChordTable`, `resolvedSequenceTable`, `resolvedChord(for:)`, `resolvedSequence(for:)`; `KeybindingPreferences.KeyChord/KeySequence → registry` mapping
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — `route()` dispatcher: action → `WorkspaceStore` tree op
- `Sources/SlopDeskClientUI/Input/WorkspaceKeyDispatcher.swift` — live NSEvent monitor + `PrefixStateMachine` wiring (macOS only)
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/CommandInterpreter.swift:369` — `PrefixStateMachine` + `PrefixIntent` enum (pure, AppKit-free)
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/TerminalKeyInterceptor.swift` — per-surface fallback interceptor (libghostty surface `keyDown`)
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Keybinding.swift` — `wireKeyInterceptor()` wiring point
- `Sources/SlopDeskClientUI/Overlays/OverlayCoordinator.swift` — overlay state machine (palette / cheat sheet / settings / connect / remote picker)
- `Sources/SlopDeskClientUI/Palette/PaletteDataSource.swift` — `ActionsPaletteSource.catalog`, `TabsPaletteSource`, `SearchMixer`, `EmptyPaletteSource`
- `Sources/SlopDeskClientUI/SlopDeskClientApp.swift:195,234` — dispatcher construction (missing toggle closures) + install
- `Sources/SlopDeskClientUI/Settings/KeybindingsEditorView.swift` — Settings > Keybindings UI
- `Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift` — serialisable override model
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/TreeCommandRoutingTests.swift` — routing correctness + chord-uniqueness pins
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/PrefixStateMachineTests.swift` — prefix machine unit tests
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/KeySequenceRegistryTests.swift` — sequence table tests

---

## Notes

### Wiring gaps

1. **⌘K / ⌘/ keyboard dispatch broken (no-op).** `WorkspaceKeyDispatcher` is constructed at `SlopDeskClientApp.swift:195` as `WorkspaceKeyDispatcher(store: store)` — without `togglePalette:`/`toggleCheatSheet:`; both default to `nil`, so `routeTree`'s `togglePalette?()`/`toggleCheatSheet?()` skip. Fix: pass closures capturing the live `OverlayCoordinator` at construction, OR wire the coordinator into `route()` another way (e.g. a `FocusedValue` seam per `docs/29-NIGHT-HANDOFF.md:831`).

2. **Cheat sheet view missing.** `OverlayCoordinator.cheatSheetVisible` exists and `WorkspaceBindingRegistry.groupedForDisplay` supplies data, but no `KeyboardCheatSheetView.swift` — the view for `cheatSheetVisible == true` does not exist yet.

3. **SwiftUI `.commands` menu not ported.** The old `WorkspaceCommands: Commands` struct (`docs/22-workspace-architecture.md:406`, `docs/29-NIGHT-HANDOFF.md:272`) is absent from the rebuilt shell, which dispatches exclusively through the NSEvent monitor. Menu items are exposed only via `ActionsPaletteSource`; native macOS menu-bar shortcuts (system-registered `.keyboardShortcut` per `WorkspaceAction`) are absent.

4. **iOS hardware keyboard dispatch absent.** `TerminalKeyInterceptor` and `WorkspaceKeyDispatcher` are both `#if os(macOS)`; iPad hardware-keyboard users get no workspace keybinding intercept.

### Dead seams

- `WorkspaceBindingRouting.routeCanvas()` — the flat-canvas routing path is retained-but-dead when `store.liveModel == .tree` (the exclusive live mode).

### Traps

- `WorkspaceBindingRegistry.resolvedChordTable` is a computed property (rebuilt every read). The dispatcher calls it per-keystroke: O(35) per key event at ~35 bindings. Fine now, but note for a future large binding set.
- `activeOverrides` is `nonisolated(unsafe)` — written by the main actor (`PreferencesStore`), read by the dispatcher on the main actor. Safe by convention; must remain main-actor-write-only.
