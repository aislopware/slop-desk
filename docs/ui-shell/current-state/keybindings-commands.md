# Keybindings & Command Routing — Current State

Gap analysis against the documented default keymap. Assessed 2026-06-25.

---

## Overview

The keybinding and command-routing stack is **substantially complete** for the core dispatch pipeline, with one significant live wiring gap: the `WorkspaceKeyDispatcher` is built without `togglePalette`/`toggleCheatSheet` closures, making ⌘K (command palette) and ⌘/ (cheat sheet) **no-ops when triggered by keyboard** (the closures are `nil`, the `togglePalette?()` and `toggleCheatSheet?()` calls in `WorkspaceBindingRouting.routeTree` are silently skipped). The registry, prefix machine, override model, and editor are all done.

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| Binding registry — single source of truth | done | `WorkspaceBindingRegistry.swift:222` — `allBindings` array + `selectTabBindings`; referenced by menu, palette, cheat sheet, dispatcher, tests |
| Default keymap (full set) | done | 35+ actions registered: split/close/focus/tab/session/view/blocks; ⌘1…⌘9 select-tab generated; `WorkspaceBindingRegistry.swift:228–488` |
| NSEvent prefix monitor (tmux ⌃A-style) | done | `WorkspaceKeyDispatcher.swift:78` — `NSEvent.addLocalMonitorForEvents(matching:.keyDown)`; installed via `.task { keyDispatcher.install() }` at `SlopDeskClientApp.swift:234` |
| Prefix state machine (arm/resolve/timeout/disarm) | done | `PrefixStateMachine` in `CommandInterpreter.swift:369`; 6-state transitions (arm, resolve, passthrough, sendPrefixLiteral, disarmSwallow, expire); pinned by `PrefixStateMachineTests` |
| Configurable prefix chord | done | Default `KeyChord("a", [.control])` at `WorkspaceStore.swift:1848`; `WorkspaceKeyDispatcher` adopts `store.workspaceKeyPrefix`; `setPrefix()` for live change |
| Double-tap prefix → send literal | done | `WorkspaceKeyDispatcher.swift:126–134`; `KeyChordNormalizer.literalBytes(for:)` emits the C0 byte to the focused pane |
| Single-chord dispatch (⌘D/⌘T/…) | done | `WorkspaceKeyDispatcher.swift:113–116`; reads `resolvedChordTable` (override-aware) |
| Multi-key prefix sequence dispatch (⌃A→D) | done | `WorkspaceKeyDispatcher.swift:65–66`; `resolveSequenceAfterPrefix` closure over `resolvedSequenceTable`; `WorkspaceBindingOverrides.swift:85–98` |
| `route()` action → store op | done | `WorkspaceBindingRouting.routeTree()` at `WorkspaceBindingRouting.swift:47` — every `WorkspaceAction` case dispatches to the matching `WorkspaceStore` tree op; tested in `TreeCommandRoutingTests` |
| Binding registry wiring — live call-sites | done | `WorkspaceKeyDispatcher.dispatch()` calls `WorkspaceBindingRegistry.route()`; `TerminalKeyInterceptor` (per-surface fallback) also routes via `WorkspaceBindingRegistry.route()` at `WorkspaceStore+Keybinding.swift:20`; `ActionsPaletteSource` rows drive store ops directly |
| Per-surface terminal key interceptor | done | `TerminalKeyInterceptor.swift` — second-line interceptor for libghostty surfaces; wired in `WorkspaceStore.wireKeyInterceptor()` at `WorkspaceStore+Keybinding.swift:16`; reads same `resolvedChordTable` |
| User keybinding overrides (rebind) | done | `KeybindingPreferences.swift` (serialisable model); `WorkspaceBindingOverrides.swift` (registry extension: `resolvedChordTable`, `resolvedSequenceTable`); `PreferencesStore` publishes to `WorkspaceBindingRegistry.activeOverrides` |
| Keybindings settings editor UI | done | `KeybindingsEditorView.swift:26`; grouped by `WorkspaceAction.Category`, `NSEvent` capture monitor on macOS, read-only on iOS; wired in `SettingsView.swift:349` |
| Conflict detection | done | `KeybindingPreferences.conflicts()` surfaced via `store.keybindingConflicts()`; shown in `KeybindingsEditorView` conflict banner |
| ⌘K command palette — OverlayCoordinator | done | `OverlayCoordinator.swift:104`; `togglePalette()`, `openPalette()`, `closePalette()`; `SearchMixer` + `ActionsPaletteSource` + `TabsPaletteSource` + empty stubs for files/conversations/repos |
| ⌘K palette — keyboard dispatch wired | **partial** | `WorkspaceAction.commandPalette` is registered (registry id `"view.palette"`, chord ⌘K); `WorkspaceBindingRouting.routeTree:96` calls `togglePalette?()`; BUT `WorkspaceKeyDispatcher` is constructed at `SlopDeskClientApp.swift:195` with NO `togglePalette` closure. ⌘K from the keyboard is silently a no-op. The palette can be opened via the palette's own UI rows. |
| ⌘/ cheat sheet — OverlayCoordinator | done | `OverlayCoordinator.swift:256`; `cheatSheetVisible` flag + `toggleCheatSheet()`/`openCheatSheet()`/`closeCheatSheet()` |
| ⌘/ cheat sheet — keyboard dispatch wired | **partial** | Same gap as palette: `WorkspaceBindingRouting.routeTree:97` calls `toggleCheatSheet?()`; dispatcher built without that closure at `SlopDeskClientApp.swift:195`. ⌘/ from keyboard is a no-op. |
| Cheat sheet view | **partial** | `OverlayCoordinator.cheatSheetVisible` is defined; `WorkspaceBindingRegistry.groupedForDisplay` provides the data. No `KeyboardCheatSheetView.swift` file found in the tree — the view that renders `cheatSheetVisible` does not appear to exist yet. |
| SwiftUI `.commands` menu | **partial** | Referenced in docs (`WorkspaceCommands: Commands`), `WorkspaceBindingRegistry.swift:211` docstring mentions it. No `WorkspaceCommands.swift` found in the live source tree — the menu surface appears not yet ported to the rebuilt shell. Chords fire via the NSEvent monitor instead. |
| Palette — fuzzy match (fzf) | done | `FuzzyMatcher` (vendored fzf FuzzyMatchV2) used in `SearchMixer.ranked()` at `PaletteDataSource.swift:277`; bench = `slopdesk-fuzzybench` |
| Palette — scope filters (actions/tabs/files/…) | partial | `.actions` and `.tabs` are live; `.files`, `.conversations`, `.repos` are registered with empty stubs (`EmptyPaletteSource`) — TODO host directory/AI wire |
| Palette — recents | done | `OverlayCoordinator.recentPaletteItems()` maps `store.recentCommands` ring to catalog rows |
| ⌘1…⌘9 select-tab | done | `WorkspaceBindingRegistry.selectTabBindings` (9 entries); `selectTabRepresentative` for display; dispatch in `routeTree:121` via `store.selectTabNumber(n)` |
| iOS keybinding dispatch | na-remote | No `UIKeyCommand`/hardware-keyboard dispatch on iOS — the per-surface `TerminalKeyInterceptor` compiles `#if os(macOS)` only. The NSEvent monitor is also macOS-only. iOS hardware keyboards fall through untouched. |
| Binding conflict uniqueness pinned by tests | done | `TreeCommandRoutingTests` asserts all chords are ⌘/⌥-prefixed and unique; `KeySequenceRegistryTests` covers sequence table |
| Override-apply pipeline (settings → registry → dispatcher) | done | `PreferencesStore.keybindings.didSet` → `WorkspaceBindingRegistry.activeOverrides = …` → `resolvedChordTable`/`resolvedSequenceTable` rebuilt on each read (computed properties) |

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

1. **⌘K / ⌘/ keyboard dispatch is broken (no-op).** `WorkspaceKeyDispatcher` is constructed at `SlopDeskClientApp.swift:195` as `WorkspaceKeyDispatcher(store: store)` — without `togglePalette:` or `toggleCheatSheet:` closures. Both closures default to `nil`. `WorkspaceBindingRouting.routeTree` calls `togglePalette?()` and `toggleCheatSheet?()` which silently skip. Fix: pass closures capturing the live `OverlayCoordinator` into the dispatcher at construction time, OR wire the overlay coordinator into `route()` via a different mechanism (e.g. a `FocusedValue` seam as noted in `docs/29-NIGHT-HANDOFF.md:831`).

2. **Cheat sheet view missing.** `OverlayCoordinator.cheatSheetVisible` exists and `WorkspaceBindingRegistry.groupedForDisplay` supplies the data, but no `KeyboardCheatSheetView.swift` was found — the view that presents when `cheatSheetVisible == true` does not appear to exist yet.

3. **SwiftUI `.commands` menu not ported.** The old `WorkspaceCommands: Commands` struct (documented in `docs/22-workspace-architecture.md:406` and `docs/29-NIGHT-HANDOFF.md:272`) is not present in the rebuilt shell. The rebuilt shell dispatches exclusively through the NSEvent monitor. Menu items are exposed only through `ActionsPaletteSource`. Native macOS menu bar shortcuts (with system-registered `.keyboardShortcut` items for each `WorkspaceAction`) are absent.

4. **iOS hardware keyboard dispatch absent.** The `TerminalKeyInterceptor` and `WorkspaceKeyDispatcher` are both `#if os(macOS)`. iPad hardware keyboard users get no workspace keybinding intercept.

### Dead seams

- `WorkspaceBindingRouting.routeCanvas()` — the canvas (flat-canvas) routing path is retained-but-dead when `store.liveModel == .tree` (the live path). The tree path is the exclusive live mode.

### Traps

- `WorkspaceBindingRegistry.resolvedChordTable` is a computed property (rebuilt on every read). The dispatcher calls it per-keystroke; at ~35 bindings this is O(35) overhead per key event. Fine for now but worth noting for a future large binding set.
- The `activeOverrides` property is `nonisolated(unsafe)` — written by the main actor (`PreferencesStore`), read by the dispatcher on the main actor. Safe by convention; the flag must remain main-actor-write-only.
