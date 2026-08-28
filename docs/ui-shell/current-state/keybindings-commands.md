# Keybindings & Command Routing — Current State

Gap analysis vs the documented default keymap. Originally assessed 2026-06-25; re-verified row by row
against the tree on **2026-08-22**. Every claim below carries a `file:line` for what is present or a
named ruling for what is gone.

> **2026-07-22 — PREFIX MODE REMOVED.** The tmux-style prefix (`PrefixStateMachine`,
> `defaultPrefixChord`, `prefixKey`, the sequence table, send-prefix, the Settings Workspace-Prefix row)
> was deleted outright — `docs/DECISIONS.md:1404` ("Prefix mode is REMOVED — the ⌘ plane is the only
> workspace-chord surface"). Nothing named in that sentence survives anywhere in `Sources/`
> (greps for `PrefixStateMachine`, `defaultPrefixChord`, `sequenceTable`, `CommandInterpreter` return
> zero hits; `KeybindingPreferences.swift:133` records that the schema stayed at v3 because fields were
> only removed). The ⌘ plane (single chords + `text:`/`csi:`/`esc:`/`unbind:` overrides) is the only
> workspace-chord surface; `TerminalKeyInterceptor` survives as the per-pane single-chord resolver and
> is now the *primary* path on iOS, not a fallback.

> **2026-08-17 — THE CLIENT-UI SPLIT.** `SlopDeskClientUI` became `SlopDeskMacUI` (AppKit) +
> `SlopDeskPhoneUI` (SwiftUI) over shared `SlopDeskClientCore` / `SlopDeskWorkspaceCore` /
> `SlopDeskWorkspaceModel` (`docs/56-client-ui-split.md`). The dispatcher, the palette data layer and the
> overlay coordinator each moved to a different target — the paths in the Key Files section below are the
> ones that exist today.

---

## Overview

The keybinding/command-routing stack is **complete on both halves**. The 2026-06-25 survey's one
headline gap ("⌘K and ⌘/ are no-ops from the keyboard — the dispatcher is built without the toggle
closures") is fixed and no longer describes anything: the palette chord is **⌘⇧P**, not ⌘K
(`docs/DECISIONS.md:236` re-bound it), and `SlopDeskMacApp.swift:241` constructs the dispatcher with
every overlay closure supplied. Both overlay views exist and are mounted on both halves.

Two structural additions post-date the survey and shape every row below:

- **A platform row filter.** `WorkspaceBindingRegistry.bindings` is `declared.filter { BindingRowPlatform.lists($0.id) }`
  (`WorkspaceBindingRegistry.swift:364`). The rule is `rust/slopdesk-workspace/src/binding_rows.rs`
  (`ROWS`, 77 ids). A row the running half cannot execute is dropped *before* the chord table is built,
  so its chord falls through to the terminal rather than being stolen to do nothing.
- **iOS dispatches chords.** Two rungs — the focused pane's `TerminalInputHost` and the responder
  chain's tail `PhoneAppDelegate` — resolve the same override-aware table the Mac's NSEvent monitor
  does, through the same `WorkspaceBindingRegistry.route`.

---

## Capability Matrix

| Feature | Status | Evidence |
|---|---|---|
| Binding registry — single source of truth | done | `WorkspaceBindingRegistry.swift:355` — `declared` (76 `WorkspaceBinding` rows, :375–963) → `bindings` (platform-filtered, :364) → `allBindings` (:985, plus the nine `selectPaneBindings` at :967). Read by the menu, the palette, the cheat sheet, both dispatchers and the tests |
| Default keymap (full set) | done | 76 declared rows + ⌘1…⌘9 generated; `WorkspaceBindingRegistry.swift:375–963`. The `allBindings` `let` is load-bearing and pinned by `scripts/check-supervisor.sh` (:979–985 explains the 210 µs/keystroke it cost as a `var`) |
| Per-platform row filter | done (new since the survey) | `BindingRowPlatform.lists(_:)` at `BindingRowPlatform.swift:40`, over `slopdesk_binding_row_shown`. Five rows are `Platform::Mac` — `pane.detach`, `pane.reattachAll`, `window.close`, `view.secureKeyboardEntry`, `view.pinWindow` (`binding_rows.rs:77,78,101,129,141`). Everything else is `Both`. `BindingRowPlatformTests` + `check-supervisor.sh` pin the two id sets equal |
| NSEvent prefix monitor (tmux-style, default ⌃B) | **REMOVED by ruling** | Shipped 2026-07-14 (`docs/DECISIONS.md:804`), deleted 2026-07-22 (`docs/DECISIONS.md:1404`). The `.keyDown` monitor survives without it — `WorkspaceKeyDispatcher.swift:221` |
| Prefix state machine (arm/resolve/timeout/disarm) | **REMOVED by ruling** | `CommandInterpreter.swift` and `PrefixStateMachineTests.swift` are both gone from the tree (same ruling) |
| Configurable prefix chord | **REMOVED by ruling** | `KeybindingPreferences` carries no `prefixKey`; :129–136 records that the schema deliberately stayed at v3 because only fields were removed, so a stale blob still decodes and the retired keys are simply never read |
| Double-tap prefix → send literal | **REMOVED by ruling** | Same ruling. Literal bytes reach a pane only via a user `text:`/`csi:`/`esc:` binding now |
| Multi-key prefix sequence dispatch (⌃B→D) | **REMOVED by ruling** | `resolvedSequenceTable` / `KeySequenceRegistryTests` are gone; `WorkspaceBindingOverrides.swift` carries only the single-chord table |
| Single-chord dispatch — macOS | done | `WorkspaceKeyDispatcher.swift:379` reads the override-aware `resolvedChordTable`; installed at `SlopDeskMacApp.swift:381` (`.task { keyDispatcher.install() }`) |
| Single-chord dispatch — iOS, focused pane | done | `TerminalInputHost.swift:359–369` (`swallowsAsWorkspaceChord`) resolves through the pane's `TerminalKeyInterceptor`; the chord is swallowed and never repeats |
| Single-chord dispatch — iOS, root rung | done | `PhoneAppDelegate.swift:251` (`pressesBegan` on the app delegate — the responder chain's tail) → :297 `swallowsAsWorkspaceChord`. So ⌘⇧P / ⌘T / ⌘D / ⌘1–9 / ⌘⇧O resolve over a video pane, with no pane focused, and under the code-panel cover |
| ⌃⇥ pane switcher (press-and-hold MRU) | done, both halves | Deliberately CHORD-LESS in the table (`WorkspaceBindingRegistry.swift:541`, id `pane.switcher`) — the gesture is responder-owned. macOS: `WorkspaceKeyDispatcher.consumePaneSwitcher` (:396). iOS: `PhoneKey.paneSwitcherKey(_:isOpen:)` (:226) spent by `WorkspaceStore.takePaneSwitcherKey` (:418). Both honour `unbind: ctrl+tab` (:418 / :237) |
| `route()` action → store op | done | `WorkspaceBindingRouting.swift:59` (`route`) → :90 (`routeTree`) — every `WorkspaceAction` case → a `WorkspaceStore` op or a passed-in overlay closure. View-owned toggles are bundled in `RouteToggles` (:13, twelve closures). Tested by `TreeCommandRoutingTests`, `WorkspaceBindingRoutingTests`, `E1KeymapParityTests` |
| Three callers, one dispatch | done | `WorkspaceKeyDispatcher.dispatch` (`:450`, macOS NSEvent), `WorkspaceStore.routeInterceptedKey` (`WorkspaceStore+Keybinding.swift:60`, the iOS interceptor path) and `OverlayCoordinator.routeBinding` (`OverlayCoordinator.swift:494`, the palette) all funnel into `WorkspaceBindingRegistry.route` |
| Per-surface terminal key interceptor | done | `TerminalKeyInterceptor.swift`; minted by `WorkspaceStore.makeKeyInterceptor` (`WorkspaceStore+Keybinding.swift:99`) and hung on the pane by `wireKeyInterceptor` (:81, called from `WorkspaceStore.swift:2600`). The same factory serves the phone's root rung (`PhoneAppDelegate.swift:173`) with an `allowing:` filter |
| User keybinding overrides (rebind) | done | `KeybindingPreferences.swift` (serialisable model, schema v3); `WorkspaceBindingOverrides.swift:59` (`resolvedChordTable`), :39 (`resolvedChord(for:)`); published by `PreferencesStore.swift:277` into `WorkspaceBindingRegistry.activeOverrides` |
| `text:` / `csi:` / `esc:` literal-byte bindings | done, **both halves** | macOS: `WorkspaceKeyDispatcher.swift:368` resolves `textBinding(for:)` *before* the action table and swallows. iOS: `TerminalInputHost.swift:361` does the same on the PANE's rung (the root rung deliberately does not — literal bytes are terminal input). Resolution: `WorkspaceBindingOverrides.swift:102`. Pinned by `TextBindingResolutionTests` + `DispatcherTextBindingTests` |
| `unbind:` suppression | done, **both halves** | macOS: `WorkspaceKeyDispatcher.swift:376`. iOS + the Mac's pane surface: `WorkspaceStore.makeKeyInterceptor`'s `resolveChord` closure checks `isUnbound` first (`WorkspaceStore+Keybinding.swift:111`) — its own comment records that the interceptor *used* to skip this, so one config file produced two behaviours. Plus the ⌃⇥ escape hatch on both (`WorkspaceKeyDispatcher.swift:418` / `PhoneKey.swift:237`) |
| Keybindings settings editor UI | done, two views over one model | Logic: `KeybindingsEditorModel.swift` + `KeybindingsEditorReading.swift`. macOS: `MacKeybindingsEditor.swift` (mounted at `MacSettingsRows.swift:148`). iOS: `KeybindingsEditorView.swift` + `KeybindingCaptureHost.swift` (mounted at `SettingsBespokeSurfaces.swift:75`). The iOS recorder is live, not read-only — `PhoneKey.captureOutcome` (`PhoneKey.swift:264`) answers the same four verdicts as the Mac's `KeybindingCapture` |
| Conflict detection | done | `KeybindingPreferences.conflicts()` (:212) — folds `textBindings` and `unbinds` in under synthetic `text:`/`unbind:` ids so every contender on a chord is listed. Surfaced via `PreferencesStore.keybindingConflicts()` (:471), read by `MacKeybindingsEditor.swift:135,164` and `KeybindingsEditorView.swift:46` |
| ⌘⇧P command palette — chord | done | `view.palette` at `WorkspaceBindingRegistry.swift:645`, chord ⌘⇧P. **It is no longer ⌘K** — `docs/DECISIONS.md:236` re-bound it to the reference default and freed ⌘K, which is now a PICKER-LOCAL chord inside Open-Quickly. Routed at `WorkspaceBindingRouting.swift:146` |
| ⌘⇧P palette — keyboard dispatch wired | done (was **partial**) | macOS: `SlopDeskMacApp.swift:243` passes `togglePalette:` at construction. iOS: `WorkspaceRootView.swift:242` installs `store.overlayKeyToggles`, whose `palette` member `routeInterceptedKey` threads into `route` (`WorkspaceStore+Keybinding.swift:63`) |
| ⌘/ cheat sheet — coordinator + view | done (was **partial**) | State: `OverlayCoordinator.swift:78,633–635`. Rows: `CheatSheetContent.swift:53` over `slopdesk_cheat_sheet_columns`. Views: `MacCheatSheetPanel.swift` (NSPanel) and `KeyboardCheatSheetView.swift` (`.sheet`, mounted at `WorkspaceRootView.swift:168`). `check-supervisor.sh` fails if either half stops reading `CheatSheetContent` or reaches past it to the registry |
| ⌘/ is CONTEXTUAL | done (new since the survey) | `WorkspaceBindingRouting.swift:150` — in vi/copy-mode ⌘/ toggles the pane's vi key-hint bar; otherwise the global cheat sheet. One chord, no collision. Pinned by `ViKeyHintsRoutingTests` |
| SwiftUI `.commands` menu | done (was **partial**) | `Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift`, attached at `SlopDeskMacApp.swift:645,663`. Renders `groupedForDisplay`; the load-bearing rule is **NO `.keyboardShortcut` on any item** (the monitor owns chords) — the glyph rides a trailing hint `Text`. The one exception is ⌘, (`.appSettings`), which is the app menu's, not the workspace's |
| ⌘1…⌘9 select **PANE** (not tab) | done | `selectPaneBindings` at `WorkspaceBindingRegistry.swift:967`; `case let .selectPane(n): store.selectPaneNumber(n)` at `WorkspaceBindingRouting.swift:275`. The survey called this "select-tab"; `docs/DECISIONS.md:5902` ("The switcher's unit is the PANE, and so is the ⌘-digit") is the ruling. The nine chords collapse to one display row, `selectPaneRepresentative` (:1125) |
| Alias chords (no display row) | done | `aliasChords` at `WorkspaceBindingRegistry.swift:1024` — ⌘⇧`+` and keypad `+` → increase font, ⌃⇧Space → Vi Mode. Folded into `chordTable`/`resolvedChordTable` but deliberately outside `allBindings`, so the uniqueness guard does not see them |
| Modal yield — Open-Quickly picker | done (new since the survey) | `WorkspaceKeyDispatcher.swift:323` — the monitor preempts the responder chain, so without this ⌘1–9 would switch the tab *behind* the picker and ⌘W would destroy the pane behind it. Pinned by `DispatcherOverlayYieldTests` |
| Modal yield — code panel webview | done (new since the survey) | `WorkspaceKeyDispatcher.swift:350` — while the embedded VS Code holds first responder every chord passes through except `survivesCodePanelYield` (:173, ⌘⇧R and ⌥⌘R). ⌃\` / ⌘\` become panel-local "take me to the terminal" (:192, `docs/DECISIONS.md:6929`). iOS twin: `CodePanelKeyYield.survives` via `PhoneAppDelegate.swift:174` |
| Key-window gate | done (new since the survey) | `WorkspaceKeyDispatcher.swift:302` — an app-wide monitor would otherwise resolve chords typed into the Settings window against the hidden workspace tree (and starve the keybindings recorder). Pinned by `DispatcherKeyWindowGateTests` |
| ⌘-hold sidebar number hints | done, **macOS only** | `WorkspaceKeyDispatcher.swift:253` (`updateShortcutHint`) off `.flagsChanged`, with a stuck-hint self-heal at :291. iOS has no bare-modifier press to observe (`PhoneKey.swift:424` states the same limitation for the ⌃⇥ commit), so this is a platform capability gap with a stated physical cause, not an unexplained one |
| Binding conflict uniqueness pinned by tests | done | `TreeCommandRoutingTests` (chord uniqueness + the ⌘/⌥-prefix rule with the named-key exemption for ⇧PageUp/⇧Home/⇧End), `E1KeymapParityTests` (the documented defaults, chord-less rows, the ⌘+ alias) |
| Override-apply pipeline (settings → registry → dispatcher) | done | `PreferencesStore.swift:277` writes `activeOverrides`; its `didSet` invalidates the memo (`WorkspaceBindingOverrides.swift:24`); `resolvedChordTable` (:59) rebuilds once and is then read per keystroke. Pinned by `KeybindingsEditorLogicTests`, `PreferencesStoreApplyTests` |
| Details panel ⌘⇧R (`.toggleDetailsPanel`) | **REMOVED — shipped, then deleted** | Assigned ⌘⇧R on 2026-06-26 (`docs/DECISIONS.md:236`), deleted with the panel itself in `6de70aae` ("remove the right sidebar (inspector / Details panel) — keyboard-centric"). No `view.toggleDetails` row exists. The chord was deliberately re-taken for **Toggle Code Panel** on 2026-08-02 (`docs/DECISIONS.md:770`); `focus.codePanel` took ⌥⌘R beside it |

---

## Key Files

- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` — the `WorkspaceAction`
  enum, the `WorkspaceBinding` table, `chordTable`, `aliasChords`, `groupedForDisplay`, `glyph()`
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/BindingRowPlatform.swift` — the per-half row filter over
  `rust/slopdesk-workspace/src/binding_rows.rs`
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift` — the override layer:
  `resolvedChordTable`, `resolvedChord(for:)`, `textBinding(for:)`, `isUnbound(_:)`, the
  `KeyChord ⇄ KeybindingPreferences.KeyChord` bridges
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeyChord.swift` — the framework-neutral chord type
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — `route()` / `routeTree()`
  and the `RouteToggles` bundle
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/TerminalKeyInterceptor.swift` — the pure per-surface
  single-chord resolver
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Keybinding.swift` — `makeKeyInterceptor`,
  `wireKeyInterceptor`, `routeInterceptedKey`, `WorkspaceOverlayKeyToggles`
- `Sources/SlopDeskWorkspaceCore/iOS/PhoneKey.swift` — the phone's key vocabulary (route/encode/chord/
  modal/pane-switcher/capture), deliberately NOT `#if os(iOS)` so the macOS runner tests it
- `Sources/SlopDeskClientCore/Input/KeyChordNormalizer.swift` — `NSEvent` → `KeyChord`, AppKit-free
- `Sources/SlopDeskMacUI/Input/WorkspaceKeyDispatcher.swift` — the live `.keyDown` / `.flagsChanged`
  monitor, the three yields, the ⌃⇥ gesture, the ⌘-hold hint
- `Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift` — the shortcut-less macOS menu bar
- `Sources/SlopDeskMacUI/SlopDeskMacApp.swift:241,381` — dispatcher construction (every closure supplied)
  and install
- `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift` — the phone's FOCUSED-PANE rung
- `Sources/SlopDeskPhoneUI/PhoneAppDelegate.swift` — the phone's responder-chain TAIL rung, which is
  the app delegate itself (docs/62 stage A folded the separate responder into it)
- `Sources/SlopDeskPhoneUI/WorkspaceRootView.swift:242` — `store.overlayKeyToggles` installation
- `Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift` — the overlay state machine (palette /
  cheat sheet / connect / global search / open-quickly / peek-reply / toasts) and `routeBinding`
- `Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift` — the ⌘/ rows + column deal, spelled once
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeybindingsEditorModel.swift` +
  `Sources/SlopDeskClientCore/Settings/KeybindingsEditorReading.swift` — the editor's logic
- `Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift`,
  `Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift`,
  `Sources/SlopDeskPhoneUI/Settings/KeybindingCaptureHost.swift` — the two editors
- `Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift` — the serialisable override model
  (v3: `overrides` + `textBindings` + `unbinds`)
- `rust/slopdesk-workspace/src/binding_rows.rs` — which half lists which row
- `rust/slopdesk-workspace/src/keybind.rs` — the chord grammar / canonical spellings
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/TreeCommandRoutingTests.swift` — routing + chord uniqueness
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/E1KeymapParityTests.swift` — the documented default keymap
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/BindingRowPlatformTests.swift` — the two id sets
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/TextBindingResolutionTests.swift`,
  `Tests/SlopDeskMacUITests/DispatcherTextBindingTests.swift` — `text:` / `unbind:`
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/PhoneKeyChordTests.swift`,
  `Tests/SlopDeskWorkspaceCoreTests/PhoneModalKeyTests.swift` — the phone's chord + modal tables
- `Tests/SlopDeskMacUITests/Dispatcher*.swift` — the yields, the key-window gate, the ⌃⇥ gesture, the hint

---

## Notes

### Closed since the 2026-06-25 survey

1. **⌘K / ⌘/ keyboard dispatch.** Fixed, and the premise moved: the palette chord is ⌘⇧P
   (`docs/DECISIONS.md:236`), and `SlopDeskMacApp.swift:241` builds the dispatcher with `togglePalette`,
   `toggleCheatSheet`, `togglePeekReply`, `toggleGlobalSearch`, `toggleJumpTo`, `toggleOpenQuickly` and
   both key-capture predicates. The chrome closures that need a `WorkspaceChromeState` are installed late
   (`setToggleSidebar` / `setToggleCodeSidebar` / `setFocusCodePanel` / `setTogglePinWindow` /
   `setCloseWindow` at `SlopDeskMacApp.swift:300–305,446`) — every one of them defaults to a graceful
   fallback, never a dead chord.
2. **Cheat sheet view.** Both halves have one; see the matrix.
3. **SwiftUI `.commands` menu.** Ported and live.
4. **iOS hardware keyboard dispatch.** Two rungs, both live. The old `na-remote` verdict is void.

### Where macOS and iOS genuinely differ

`docs/56-client-ui-split.md:99-102,144-145` is binding: **layout diverges; capability does not.** Every
divergence below has a stated cause.

- **Five Mac-only binding rows** — `pane.detach`, `pane.reattachAll`, `window.close`,
  `view.secureKeyboardEntry`, `view.pinWindow` (`binding_rows.rs:77,78,101,129,141`). The module's own
  doc names the reason: an own-window satellite, a window level, the AppKit secure-input call and a
  window close are things iOS does not have. Dropping the ROW rather than emptying the run arm is the
  design — the chord goes back to the terminal instead of being bound to nothing. `PaletteRowPlatform`
  drops the same five verbs one surface further in.
- **The ⌘-hold sidebar number hint** is macOS-only, because UIKit reports no press for a bare modifier.
  The same physical fact is why the phone's ⌃⇥ walk is always UNARMED (`PhoneKey.swift:424`).
- **Where a chord is resolved** differs by construction: the Mac PREEMPTS the responder chain with one
  NSEvent monitor and pays for it with a hand-written yield per surface it would otherwise steal from;
  the phone sits at the chain's TAIL and yields to everything by being last
  (`PhoneAppDelegate.swift:36-44`). That is a layout difference, not a capability one.

**No unexplained gap remains in this area.** The one this document previously flagged — `text:` bindings
honoured only on macOS — is closed: `TerminalInputHost.swift:361` resolves `textBinding(for:)` on the
phone's pane rung, and its own docstring records the defect it fixed ("the config file is shared between
the two shells, so `keybind = cmd+shift+h=text:hello` … was one line producing two behaviours"). General
`unbind:` is likewise honoured on both, through `makeKeyInterceptor`'s `resolveChord`
(`WorkspaceStore+Keybinding.swift:111`), whose comment records the same class of defect.

### Dead seams

None in this area. The `routeCanvas()` flat-canvas path the survey listed is gone — the canvas model was
deleted (`WorkspaceStore.swift:225` records the removal), and `WorkspaceBindingRouting.swift` has a single
`routeTree`.

### Traps

- **`resolvedChordTable` is memoized, not recomputed.** The survey's "computed property, rebuilt every
  read, O(35) per key event" note is stale in both directions: the table is now cached behind
  `liveChordTable` and invalidated by `activeOverrides`' setter (`WorkspaceBindingOverrides.swift:24,34`),
  and the table is 85 rows on macOS (76 bindings + 9 digits), not 35. The `let` on `allBindings` is part
  of the same fix and is pinned by `check-supervisor.sh` — a `var` there costs 210 µs per keystroke and
  no test can see it (`WorkspaceBindingRegistry.swift:979-984`).
- **`activeOverrides` is `nonisolated(unsafe)`** — written by the main actor (`PreferencesStore`), read by
  both dispatchers on the main actor. Safe by convention; must stay main-actor-write-only.
- **A menu item must never carry `.keyboardShortcut`.** `WorkspaceCommands.swift:13` states it; a
  shortcut there would double-fire alongside the monitor.
- **Registering ⌃⇥ as a table row would break it.** The gesture means open/step/commit depending on
  state, and `unbind: ctrl+tab` only gives the gesture back while the gesture lives *above* the table
  (`WorkspaceBindingRegistry.swift:533-540`).
- **`glyph(_:)` retries.** The FFI door leaves the buffer untouched on overflow, so reading
  `out.prefix(written)` after a short write yields an empty string in the one place a chord is shown to
  the user. The retry at `WorkspaceBindingRegistry.swift:1075` is the fix, not ceremony.
