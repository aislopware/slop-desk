# Palette / Search — Current Implementation State

Assessed: 2026-06-25

## Overview

The command-palette data layer and fuzzy-matching engine are fully built and tested. The
palette VIEW (the SwiftUI overlay that renders it) and the overlay coordinator mounting are
the missing link — both exist as dead code / un-mounted infrastructure. Find-in-terminal
(⌘F) has a complete pure engine and the callback seam wired in GhosttyTerminalView, but the
`TerminalFindBar` UI overlay is not yet written. Open-quickly / ⌘⇧O does not exist as a
separate surface; its role is partially served by the palette's "Tabs" filter chip. Outline /
jump-to (structural navigation) is na-remote by design.

---

## Capability matrix

| Feature | Status | Evidence file(s) / symbol(s) |
|---|---|---|
| **Command palette (⌘K) — data model** | done | `Palette/PaletteModel.swift` — `PaletteItem`, `QueryFilter`, `PaletteAction`; `Palette/PaletteDataSource.swift` — `ActionsPaletteSource`, `TabsPaletteSource`, `SearchMixer`; `Overlays/OverlayCoordinator.swift` — `openPalette`, `togglePalette`, `paletteResults`, `zeroStateResults`, recents ring |
| **Command palette — action catalog** | done | `PaletteDataSource.swift:52-139` — fixed catalog of 12+ workspace actions with registry-derived glyph hints (no drift possible); drives `WorkspaceAction` via `WorkspaceBindingRegistry.route` |
| **Command palette — tabs/pane jump source** | done | `PaletteDataSource.swift:162-213` — `TabsPaletteSource.snapshot(_:)` enumerates live panes; agent-status icon; focus-on-select via `store.focusPaneTree(_:)` |
| **Command palette — files / conversations / repos sources** | partial | `PaletteDataSource.swift:218-228` — `EmptyPaletteSource` stub: protocol slot exists, filter chips register, but `candidates` always returns `[]`; TODO comment: "host directory-listing wire — logic-api §5.4" |
| **Command palette — fuzzy matcher** | done | `Palette/FuzzyMatcher.swift` — vendored fzf `FuzzyMatchV2`, smart-case, produces scored `Match` + matched `Range<String.Index>` positions for highlight; verified faithful by `slopdesk-fuzzybench` (0/1387 inversions), goldens in `FuzzyMatcherTests` |
| **Command palette — keyboard chord (⌘K)** | done | `WorkspaceBindingRegistry.swift:412-415` — `view.palette` binding, chord `⌘K`; routes via `WorkspaceBindingRouting.swift:96` `case .commandPalette: togglePalette?()` |
| **Command palette — VIEW (SwiftUI overlay)** | missing | No `PaletteView.swift` or `CommandPaletteView.swift` exists in `Sources/SlopDeskClientUI/`. The old canvas `CommandPaletteView` was deleted in L0 and the rebuilt view is not yet written. |
| **Command palette — OverlayCoordinator mounted in scene** | missing | `SlopDeskClientApp.swift:195` — `WorkspaceKeyDispatcher(store: store)` with NO `togglePalette` closure; `overlayCoordinator(_:)` modifier is never called on the scene root; coordinator exists but is unreachable at runtime |
| **Command palette — zero-state / recents** | done (model) | `OverlayCoordinator.swift:143-164` — recents ring from `store.recentCommands`, matched back to catalog rows; zero-state shows recents then full catalog; all logic present, blocked by missing view |
| **Find-in-terminal (⌘F) — pure engine** | done | `Terminal/TerminalSearchController.swift` — literal + regex, case-toggle, overlapping matches, next/prev/wrap, "N of M" label; fully unit-tested by `TerminalSearchControllerTests.swift` |
| **Find-in-terminal (⌘F) — keyboard chord** | done | `WorkspaceBindingRegistry.swift:421-425` — `view.find` binding, chord `⌘F`; routes via `WorkspaceBindingRouting.swift:100` `case .find: store.requestFindInActivePane()` |
| **Find-in-terminal (⌘F) — callback seam** | done | `TerminalViewModel.swift:195` — `onRequestFind: (() -> Void)?`; `WorkspaceStore.swift:2770-2773` `requestFindInActivePane()` resolves the active live session's terminal model and fires the callback; `GhosttyTerminalView.swift:1169,1230` wires `find(_:)` responder and context-menu item to `model?.onRequestFind?()` |
| **Find-in-terminal (⌘F) — TerminalFindBar VIEW** | missing | No `TerminalFindBar.swift` exists anywhere. Referenced in comments at `TerminalSearchController.swift:8,12` and `docs/DECISIONS.md:136` as "the GUI overlay is a thin driver" — that overlay is not yet written. The `onRequestFind` callback fires into nothing at runtime (the closure on `TerminalViewModel` is never assigned by `TerminalLeafView` or any view in `SlopDeskClientUI/`) |
| **Fuzzy open-quickly / pane switcher (⌘⇧O)** | missing | No dedicated `⌘⇧O` binding in `WorkspaceBindingRegistry`. No `OpenQuickly` or `QuickSwitcher` symbol exists anywhere. The "Tabs" filter chip of the command palette covers fuzzy-pane-jump semantics but is unreachable (no palette view). |
| **Outline / jump-to-symbol** | na-remote | SlopDesk renders a remote terminal surface, not a local code editor. There is no local AST/LSP to drive an outline. Block navigation (`⌃⌘[`/`⌃⌘]`) covers OSC-133 shell-prompt jumping — the closest applicable analogue (done at the store level). |
| **Command Navigator (⌃⌘O) — block search overlay** | partial | `WorkspaceAction.commandNavigator` registered (⌃⌘O); routes to `store.requestBlockNavigatorInActivePane()` → `activeTerminalModel?.onRequestBlockNavigator?()`; `TerminalViewModel.swift:394` carries `onRequestBlockNavigator`; `TerminalBlockModel.swift` has `BlockNavigatorFilter`; but `onRequestBlockNavigator` is NEVER assigned by any view in `SlopDeskClientUI/` — the block-navigator UI overlay does not exist yet |
| **Cheat sheet (⌘/) overlay** | partial | `OverlayCoordinator.swift:256-258` — `cheatSheetVisible` flag + `openCheatSheet/closeCheatSheet/toggleCheatSheet`; `WorkspaceBindingRegistry.swift:416-419` `view.cheatSheet` binding; coordinator model present, but no `CheatSheetView.swift` in `SlopDeskClientUI/` and `toggleCheatSheet` closure is not passed to `WorkspaceKeyDispatcher` at app launch |

---

## Key files

- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Palette/PaletteModel.swift` — `PaletteItem`, `QueryFilter`, `PaletteAction`, `RankedRow`
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Palette/PaletteDataSource.swift` — `ActionsPaletteSource`, `TabsPaletteSource`, `EmptyPaletteSource`, `SearchMixer`
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Palette/FuzzyMatcher.swift` — vendored fzf FuzzyMatchV2
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Overlays/OverlayCoordinator.swift` — palette/settings/toast/cheat-sheet/remote-picker state machine (all unmounted)
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Overlays/OverlayEnvironment.swift` — `\.overlayCoordinator` environment key (never injected at runtime)
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift` — pure ⌘F engine
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` — `WorkspaceAction` enum, `WorkspaceBinding` table, glyph renderer
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — `route(_:to:togglePalette:toggleFind:...)` dispatch
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/Input/WorkspaceKeyDispatcher.swift` — app-level `NSEvent` monitor (wired with NO overlay closures)
- `/Users/dev/slop-desk/Sources/SlopDeskClientUI/SlopDeskClientApp.swift` — scene root; `WorkspaceKeyDispatcher(store: store)` at line 195 (missing togglePalette/toggleCheatSheet/toggleFind)
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift:1169,1230` — `onRequestFind` wired from production renderer

---

## Notes (wiring gaps, dead seams, traps)

### The central gap: OverlayCoordinator is never mounted

`OverlayCoordinator` is a complete `@MainActor @Observable` object with palette, settings,
toast, cheat-sheet, connect, and remote-picker state — but:
1. It is never instantiated in `SlopDeskClientApp.swift`.
2. `overlayCoordinator(_:)` is never called on the scene root, so `\.overlayCoordinator` is
   `nil` everywhere in the SwiftUI tree.
3. `WorkspaceKeyDispatcher` is constructed with no `togglePalette` / `toggleCheatSheet`
   closures (`SlopDeskClientApp.swift:195`), so ⌘K and ⌘/ both resolve to `togglePalette?()` / `toggleCheatSheet?()` which are `nil` → silent no-ops.
4. There is no palette SwiftUI view to mount even if the coordinator were live — the view
   layer (`PaletteView`/`CommandPaletteView`) was deleted with L0 and not yet rebuilt.

### Find-in-terminal: callback chain exists, view does not

- `GhosttyTerminalView.find(_:)` → `model?.onRequestFind?()` → `TerminalViewModel.onRequestFind`
  is wired in the production renderer.
- `WorkspaceStore.requestFindInActivePane()` fires the same callback.
- But nothing in `SlopDeskClientUI/` ever sets `terminalModel.onRequestFind = { ... }`.
- `TerminalLeafView` has a `TODO(L3)` placeholder comment but does not mount a find overlay.
- `TerminalFindBar` (the SwiftUI overlay that would show the search field, next/prev buttons,
  and wire `TerminalSearchController`) does not exist as a file.

### Command Navigator: same pattern as find

`onRequestBlockNavigator` on `TerminalViewModel` is never assigned; no block-navigator overlay
view exists in `SlopDeskClientUI/`. The store routing + ViewModel callback seam are present.

### Files / conversations / repos palette sources

`EmptyPaletteSource` stubs these three filters so they appear as chips, but always return
zero results. The TODO points at a "host directory-listing wire" (logic-api §5.4) — there
is no host-side directory/file protocol yet.

### Open-quickly / ⌘⇧O

Not modelled as a separate binding. The `TabsPaletteSource` in the command palette covers
fuzzy pane-switching, but there is no dedicated "open quickly" entry point. Adding a
`WorkspaceAction.openQuickly` binding that opens the palette pre-filtered to `.tabs` would
be the minimal implementation path.

### Cheat sheet

`OverlayCoordinator.cheatSheetVisible` and the `WorkspaceAction.cheatSheet` → ⌘/ binding
exist. No `CheatSheetView.swift` is present; the coordinator closure is not passed to the
key dispatcher. Same missing-view + missing-mount pattern as the palette.
