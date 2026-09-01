# Palette / Search — Current Implementation State

Assessed: 2026-06-25. Re-verified row by row against the tree on **2026-08-22** — every "missing" verdict
below was re-checked, and all of them had closed.

## Overview

Everything the 2026-06-25 survey called missing now exists. The palette VIEW is built twice (an `NSPanel`
on the Mac, a SwiftUI card on the phone) over one `PalettePresentation`; `OverlayCoordinator` **is**
mounted (`WorkspaceRootView.swift:113` injects it into the environment; `MacOverlayPanels.swift` hosts the
Mac's panels); the find bar, the command navigator, global search and the Open-Quickly picker all have
real surfaces on both halves.

Four structural changes post-date the survey and reshape the whole page:

- **The palette chord is ⌘⇧P, not ⌘K.** `docs/DECISIONS.md` re-bound `view.palette` to the reference
  default and freed ⌘K. ⌘K is now a PICKER-LOCAL chord *inside* Open-Quickly (the per-row Actions
  popover) and is never registered in `WorkspaceBindingRegistry` (`docs/DECISIONS.md`).
- **Open-Quickly shipped, and Jump-To folded into it.** ⌘⇧O opens the picker at the merged `.all` pill,
  ⌘J at `.current` (`docs/DECISIONS.md`). `JumpToView.swift` was deleted in that fold;
  `JumpToModel` survives verbatim as the `.current` data source.
- **The `files` / `conversations` / `repos` empty stubs were DELETED, not filled.** `EmptyPaletteSource`
  no longer exists anywhere in `Sources/`. The multi-source jump-to moved to `OpenQuicklyFilter`; the
  three `QueryFilter` cases are retained as the documented Warp taxonomy but no source answers them
  (`PaletteModel.swift:18-23`).
- **The palette now derives ~45 rows from the binding registry.** `docs/client-ui-split/inc-58-72.md` (increments 63–64)
  ("the palette listed 33 of 77, and only a phone could tell"): `ActionsPaletteSource` hand-writes 33
  rows and `registryRows` derives every remaining binding, so a phone with no hardware keyboard can still
  say every verb. Twenty-four hand-written rows became `.binding(_)` in the same change, and six
  `PaletteAction` cases were deleted for re-implementing a `route` arm.

---

## Capability matrix

| Feature | Status | Evidence file(s) / symbol(s) |
|---|---|---|
| **Command palette (⌘⇧P) — data model** | done | `Palette/PaletteModel.swift` — `PaletteItem` (:133), `QueryFilter` (:24), `PaletteCategory` (:56), `PaletteAction` (:98), `RankedRow` (:230); `Palette/PaletteDataSource.swift` — `ActionsPaletteSource`, `CategoryActionsSource`, `MovePaneToTabSource`, `TabsPaletteSource`, `SearchMixer`; `Overlays/OverlayCoordinator.swift` — `openPalette` (:276), `togglePalette` (:289), `rebuildMixer` (:307), `paletteResults` (:416), `rankedResults` (:423). All in `SlopDeskClientCore`, not the old ClientUI target |
| **Command palette — hand-written action catalog** | done | `PaletteDataSource.swift:60–287` — 33 declared rows, filtered to the running half by `PaletteRowPlatform.lists` (:55). Glyph hints are never hardcoded: each row derives from `WorkspaceBindingRegistry.glyph(for:)` (:393) |
| **Command palette — registry-derived rows** | done (new since the survey) | `PaletteDataSource.swift:323` — `registryRows` maps every `WorkspaceBindingRegistry.bindings` row the catalog does not already carry. `coveredActions` (:295) is read off the catalog's own rows; the only exclusions are `.commandPalette` and `.selectPane` (`isUnlistable`, :306). `allRows` (:336) is the union. Pinned by `PaletteReachesEveryBindingTests` (`Tests/SlopDeskClientCoreTests/PaletteContentAndReachTests.swift:224`) and by `check-supervisor.sh` (the derivation shape + "no seventh `PaletteAction` case") |
| **Command palette — panes jump source** | done | `PaletteDataSource.swift:534` — `TabsPaletteSource.snapshot(_:)` (:563) enumerates every pane of every tab via `tab.allPaneIDs()`, titles them through `PaneSwitcherRowsBuilder.identity` (the same chain the ⌃⇥ card and the sidebar use), and accepts into `store.jumpToPaneTree`. Registered per palette open by `OverlayCoordinator.rebuildMixer` (:323). Ruling: `docs/DECISIONS.md` ("The command palette learns the panes") |
| **Command palette — move-pane-to-tab source** | done (new since the survey) | `PaletteDataSource.swift:466` — one dynamic row per other tab of the active session, resolved by stable `TabID` at run time |
| **Command palette — files / conversations / repos sources** | **REMOVED — never reachable** | `EmptyPaletteSource` is gone from the tree (grep: zero hits in `Sources/`). `PaletteDataSource.swift:9-12` and `PaletteModel.swift:18-23` record why: the richer multi-source jump-to became Open-Quickly's own surface, so the three stub filters were deleted rather than wired. The `QueryFilter` cases stay as the documented taxonomy |
| **Command palette — fuzzy matcher** | done, **now Rust** | `Palette/FuzzyMatcher.swift:27` is a marshaller over `slopdesk_fuzzy_score` / `slopdesk_fuzzy_rank`; the ~300-line vendored Swift `FuzzyMatchV2` was deleted under the one-implementation rule. The algorithm lives in `rust/slopdesk-fuzzy`, the tiering in `rust/slopdesk-workspace/src/search_rank.rs`. Only the scalar-offset → `Range<String.Index>` merge stays in Swift. Parity checked by `fuzzybench` (`rust/slopdesk-instruments`); scores pinned by `FuzzyMatcherTests` |
| **Command palette — three-tier field ranking** | done (new since the survey) | `SearchMixer.ranked` (`PaletteDataSource.swift:628`) offers title, subtitle, then the HIDDEN `keywords` in priority order; the first field that matches decides both score and tier, so `lock` finds the row *called* "Read Only" above one that merely mentions locking. Rule: `search_rank.rs` |
| **Command palette — keyboard chord** | done | `WorkspaceBindingRegistry.swift:645–649` — `view.palette`, chord **⌘⇧P**; routed at `WorkspaceBindingRouting.swift:146` (`case .commandPalette: toggles.palette?()`). The survey's `⌘K` is stale by one day (`docs/DECISIONS.md`) |
| **Command palette — VIEW** | done (was **missing**) | Two views, one presentation: `SlopDeskMacUI/Overlays/MacPalette.swift` (`MacPaletteView`, hosted by `MacOverlayPanels.swift:120`) and `SlopDeskPhoneUI/Overlays/PaletteView.swift` (mounted by `OverlayHostView.swift`). `check-supervisor.sh` fails if either half stops reading `PalettePresentation`/`PaletteMetrics`, or if the shared host draws the Mac's palette a second time |
| **Command palette — OverlayCoordinator mounted in scene** | done (was **missing**) | `SlopDeskPhoneUI/WorkspaceRootView.swift:113` — `.overlayCoordinator(overlay)`; the Mac hosts its panels off the same coordinator (`SlopDeskMacApp.swift:243` threads `overlay.togglePalette()` into the dispatcher). `Tests/SlopDeskClientCoreTests/OverlayCoordinatorMountTests.swift` pins the mount |
| **Command palette — zero-state / recents** | done | `OverlayCoordinator.zeroStateResults()` (:432): PANES lead, then WORKING DIRECTORY, then the MRU Recents block (`recentPaletteItems()`, :474, re-`id`'d into the `recent.` namespace), then the catalog by category, then the dynamic Move-Pane rows. Every accepted verb is a recent now — the five hand-picked `recordRecentCommand` calls went with the `.binding` conversion (`docs/56-client-ui-split.md`, increment 64) |
| **Command palette — one memoized ranking pass** | done (new since the survey) | `OverlayCoordinator.swift:367–412` — `ResultsKey` (generation, query, filter, recents) memoizes `rankedResults` / `paletteResults` / `selectableResults`, which used to cost 2–3 full fzf passes per ↑/↓ |
| **Palette row platform filter** | done (new since the survey) | `Palette/PaletteRowPlatform.swift` over `rust/slopdesk-workspace/src/palette_rows.rs` (`ROWS`, 33 entries). Five are `Platform::Mac` — `action.detachPane`, `action.reattachAllPanes`, `action.secureKeyboardEntry`, `action.closeWindow`, `action.pinWindow` (:73,74,85,99,106) — the same five features `bindings.rs` gates. `registryRows` needs no gate of its own: it reads the already-filtered `bindings` |
| **Find-in-terminal (⌘F) — engine** | done — it is the SURFACE's, not a Swift one | `slopdesk_term_surface_find(needle, caseSensitive, wholeWord, regex)` → `rust/slopdesk-vterm/src/search.rs` (literal + regex, case + whole-word toggles, overlapping matches, cell-addressed), with `_find_position` answering "N of M" and `navigate_search:` stepping the cursor. `TerminalFindBarModel` holds no match list; `ScrollbackMatcherTests` covers the ⇧⌘F scan that remains in Swift. |
| **Find-in-terminal (⌘F) — keyboard chords** | done | `WorkspaceBindingRegistry.swift:655–672` — `view.find` ⌘F, `view.findNext` ⌘G, `view.findPrev` ⇧⌘G (the last two are new since the survey and OPEN the bar when closed). Routed at `WorkspaceBindingRouting.swift:158,162,163` |
| **Find-in-terminal — callback seam** | done | `TerminalViewModel.swift:269,277,278,588` — `onRequestFind`, `onRequestFindNext`, `onRequestFindPrev`, `onRequestFindBackward`; `WorkspaceStore.requestFindInActivePane()` (`WorkspaceStore.swift:1891`), `requestFindNextInActivePane()` (:3209), `requestFindPrevInActivePane()` (:3217) |
| **Find-in-terminal — find bar VIEW** | done (was **missing**) | `SlopDeskClientCore/Pane/FindBarPresentation.swift` (shared model), `SlopDeskMacUI/Pane/MacTerminalFindBar.swift`, `SlopDeskPhoneUI/Pane/TerminalFindBar.swift`. The seam is ASSIGNED now: `SlopDeskClientCore/Pane/TerminalPaneWiring.swift:222` — `model.onRequestFind = { bar.open() }` (and `= nil` on teardown, :242). Tests: `FindBarPresentationTests`, `TerminalFindBarModelTests`, `TerminalFindBarKeysTests` |
| **Global Search (⇧⌘F)** | done (did not exist at the survey) | Engine `SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift`; binding `view.globalSearch` (`WorkspaceBindingRegistry.swift:675–679`) → `toggles.globalSearch?()` (`WorkspaceBindingRouting.swift:166`); coordinator state `OverlayCoordinator.swift:88,645,670`; views `MacGlobalSearch.swift` / `GlobalSearchView.swift` over `GlobalSearchPresentation.swift`. Tests: `GlobalSearchStoreTests`, `GlobalSearchPresentationTests` |
| **Open Quickly (⌘⇧O) — the multi-source picker** | done (was **missing**) | Binding `view.openQuickly` (`WorkspaceBindingRegistry.swift:958–962`) → `toggles.openQuickly?()` (`WorkspaceBindingRouting.swift:263`). Model `SlopDeskWorkspaceCore/Workspace/Domain/OpenQuicklyModel.swift` (`OpenQuicklyFilter`: all / opened / recent / folders / agents / current, :16–36); sources `SlopDeskClientCore/Overlays/OpenQuicklySources.swift`; presentation `OpenQuicklyPresentation.swift`; views `MacOpenQuickly.swift` / `OpenQuicklyView.swift`. Ruling: `docs/DECISIONS.md`. Tests: `OpenQuicklyModelTests`, `OpenQuicklyPresentationTests` |
| **Jump-To (⌘J)** | done, FOLDED into Open-Quickly | Binding `view.jumpTo` (`WorkspaceBindingRegistry.swift:841–846`) → `toggles.jumpTo?()` (`WorkspaceBindingRouting.swift:169`), which both apps bind to `overlay.toggleOpenQuickly(filter: .current)` (`SlopDeskMacApp.swift:252`). `JumpToModel.swift` is reused verbatim as that pill's data source; `JumpToView.swift` was deleted in the fold (`docs/DECISIONS.md`). Tests: `JumpToModelTests` |
| **Picker-local chords are NOT registry rows** | done (design ruling) | `docs/DECISIONS.md` — only ⌘⇧O (`.all`) and ⌘J (`.current`) are GLOBAL. The pill chords ⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J, ⌘1–9 quick-pick, Tab/⇧Tab cycling and **⌘K** (the per-row Actions popover) live in `OpenQuicklyView.onKeyPress` (:129,428) and are never registered. The Mac's dispatcher yields the whole keyboard while the picker is up (`WorkspaceKeyDispatcher.swift:323`) so those chords survive the monitor's preemption |
| **Outline / jump-to-symbol** | na-remote | Unchanged verdict: a remote terminal surface has no local AST/LSP. OSC-133 block navigation (⌃⌘[ / ⌃⌘]) plus the Command Navigator and Open-Quickly's `.current` pill are the analogues |
| **Command Navigator (⌃⌘O) — block search overlay** | done (was **partial**) | Binding `view.commandNavigator` (`WorkspaceBindingRegistry.swift:831–835`) → `store.requestBlockNavigatorInActivePane()` (`WorkspaceBindingRouting.swift:236`, `WorkspaceStore+Blocks.swift:191`). The seam is ASSIGNED: `TerminalPaneWiring.swift:318` — `model.onRequestBlockNavigator = { chrome.isVisible.toggle() }`. Model `CommandNavigatorModel.swift`; presentation `CommandNavigatorPresentation.swift`; views `MacCommandNavigator.swift` / `CommandNavigatorView.swift`. Tests: `CommandNavigatorModelTests` |
| **Cheat sheet (⌘/) overlay** | done (was **partial**) | Coordinator `OverlayCoordinator.swift:78,633–635`; rows + column deal `SlopDeskClientCore/Overlays/CheatSheetContent.swift:53` over `slopdesk_cheat_sheet_columns`; views `MacCheatSheetPanel.swift` (NSPanel) and `KeyboardCheatSheetView.swift` (`.sheet`, mounted at `WorkspaceRootView.swift:168` — deliberately NOT in the shared host). `check-supervisor.sh` fails if a half stops reading `CheatSheetContent`, reaches past it to the registry, or lets the shared host draw it twice. `⌘/` is contextual: in vi mode it toggles the pane's key-hint bar instead (`WorkspaceBindingRouting.swift:150`) |
| **Result cap** | done | `SearchMixer.maxResults` (`PaletteDataSource.swift:611`) asks `wsMaxSearchResults` (`WorkspaceSolverBridge.swift:382` → `slopdesk_ws_max_search_results`) rather than transcribing a number, so no two surfaces disagree about where the list stops |

---

## Key files

Paths are repo-relative. (The 2026-06-25 revision of this page listed them under a `/Users/dev/slop-desk/`
prefix that has never existed in this checkout.)

- `Sources/SlopDeskClientCore/Palette/PaletteModel.swift` — `PaletteItem`, `QueryFilter`,
  `PaletteCategory`, `PaletteAction`, `RankedRow`
- `Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift` — `ActionsPaletteSource` (+ `registryRows`),
  `CategoryActionsSource`, `MovePaneToTabSource`, `TabsPaletteSource`, `SearchMixer`
- `Sources/SlopDeskClientCore/Palette/PaletteRowPlatform.swift` — which half lists which catalog row
- `Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift` — the marshaller over `rust/slopdesk-fuzzy`
- `Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift` — palette / cheat sheet / connect /
  global search / open-quickly / peek-reply / toast state, the memoized ranking, and `routeBinding`
- `Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift` — the ⌘/ rows and column deal
- `Sources/SlopDeskClientCore/Overlays/OpenQuicklySources.swift`,
  `Sources/SlopDeskClientCore/Overlays/OpenQuicklyPresentation.swift` — the picker's rows and dressing
- `Sources/SlopDeskClientCore/Overlays/GlobalSearchPresentation.swift`,
  `Sources/SlopDeskClientCore/Overlays/CommandNavigatorPresentation.swift`
- `Sources/SlopDeskClientCore/Pane/FindBarPresentation.swift`,
  `Sources/SlopDeskClientCore/Pane/TerminalPaneWiring.swift` — the find / navigator seam ASSIGNMENTS
- the coordinator reaches a surface as an `init` PARAMETER — `PhoneSceneDelegate` hands it to
  `WorkspaceRootView`, which hands it down the canvas to every pane. The `\.overlayCoordinator`
  `@Entry` key it used to ride is deleted (docs/62 stage B): a `UIViewController` inherits no
  environment, and neither does a `.sheet`, which is why the key had to be re-injected at every
  presentation anyway
- `Sources/SlopDeskPhoneUI/Overlays/` — `PaletteView.swift`, `OpenQuicklyView.swift`,
  `GlobalSearchView.swift`, `CommandNavigatorView.swift`, `KeyboardCheatSheetView.swift`,
  `OverlayHostView.swift`
- `Sources/SlopDeskMacUI/Overlays/` — `MacPalette.swift`, `MacOpenQuickly.swift`, `MacGlobalSearch.swift`,
  `MacCheatSheetPanel.swift`, `MacOverlayPanels.swift`
- `Sources/SlopDeskMacUI/Pane/MacCommandNavigator.swift`, `Sources/SlopDeskMacUI/Pane/MacTerminalFindBar.swift`
- `Sources/SlopDeskWorkspaceCore/Terminal/ScrollbackMatcher.swift` — the pure ⇧⌘F cross-tab scan (NOT ⌘F, which asks the surface)
- `Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift` — the ⇧⌘F engine
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/OpenQuicklyModel.swift`,
  `Sources/SlopDeskWorkspaceCore/Workspace/Domain/JumpToModel.swift`,
  `Sources/SlopDeskWorkspaceCore/Workspace/Domain/CommandNavigatorModel.swift`
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` — the verb table the
  palette derives from
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — `route(…)` with the
  `RouteToggles` bundle
- `rust/slopdesk-fuzzy/` — fzf `FuzzyMatchV2`; `rust/slopdesk-workspace/src/search_rank.rs` — the field
  tiering; `rust/slopdesk-workspace/src/palette_rows.rs` — the per-half catalog gate
- `rust/slopdesk-instruments/src/bin/fuzzybench.rs` — the ranking-parity bench against real `fzf --filter`
- `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — the production renderer's
  `find(_:)` responder and context-menu item (line numbers from the 2026-06-25 survey are long stale;
  the file was ~4000 lines by the end). DELETED with the fork by `docs/68-terminal-surface-in-rust.md`;
  the responder and the menu item are event plumbing and stay Swift on the new surface view (`docs/68`
  §10), so what this row names moved file, not layer

---

## Notes (wiring gaps, dead seams, traps)

### The central gap is closed: OverlayCoordinator is mounted

All four sub-claims of the 2026-06-25 "never mounted" finding are now false:

1. It is instantiated and attached on both halves (`WorkspaceRootView.swift:113` on iOS; the Mac threads
   the same instance into the dispatcher at `SlopDeskMacApp.swift:243` and hosts its panels from
   `MacOverlayPanels.swift`).
2. `overlayCoordinator(_:)` IS called on the phone's scene root, so `\.overlayCoordinator` resolves.
3. The dispatcher is constructed WITH `togglePalette` / `toggleCheatSheet` (and seven more closures).
4. Palette views exist on both halves.

`OverlayCoordinatorMountTests` (`Tests/SlopDeskClientCoreTests/`) pins the mount and asserts
`paletteResults` equals `rankedResults.map(\.item)` row for row.

### Find-in-terminal: the chain terminates in a view now

the surface view's `find(_:)` (`GhosttyTerminalView.find(_:)` when this was written) → `model.onRequestFind?()` → the bar, because
`TerminalPaneWiring.swift:222` assigns the closure when a pane mounts and clears it at :242.
`WorkspaceStore.requestFindInActivePane()` fires the same callback for the menu/chord path. The
`TODO(L3)` placeholder in `TerminalLeafView` is gone.

### Command Navigator: same shape, also closed

`TerminalPaneWiring.swift:318` assigns `onRequestBlockNavigator`; the overlay is
`MacCommandNavigator.swift` / `CommandNavigatorView.swift` over `CommandNavigatorPresentation`.

### Files / conversations / repos

Deleted, not deferred. The "host directory-listing wire — logic-api §5.4" TODO the stubs carried is gone
with them; the folder/agent/file domains the note was reaching for are served by Open-Quickly's
`.folders` / `.agents` pills, which read `FolderFrecencyStore` and the agent-session probe rather than a
new host protocol. Only the `QueryFilter` enum cases remain, documented as retained taxonomy.

### Open-quickly / ⌘⇧O

Built, and the survey's suggested minimal path was not the one taken: it is a distinct multi-source
surface with its own pill taxonomy (`OpenQuicklyFilter`), not the ⌘⇧P palette pre-filtered to `.tabs`.
The two taxonomies are deliberately separate — `PaletteModel.swift:18` spells that out. ⌘⇧P *also*
searches panes now (`TabsPaletteSource`), so the muscle memory works either way
(`docs/DECISIONS.md`).

### macOS vs iOS

`docs/56-client-ui-split.md:99-102,144-145`: layout diverges, capability does not. Every palette and
overlay surface on this page exists on both halves — the Mac draws panels, the phone draws sheets and
cards, and the shared `*Presentation` types are what `check-supervisor.sh` pins so the two cannot drift.
The only asymmetry in the palette catalog is the five `Platform::Mac` rows in `palette_rows.rs`
(detach / reattach-all / secure keyboard entry / close window / pin window), each naming an AppKit
capability iOS does not have — the same five `bindings.rs` drops, by design rather than by omission.

### Traps

- **Section order beats score across sections.** A `.pane` row matching "new tab" would shadow the exact
  "New Tab" verb, which is why `action.movePaneToNewTab` is filed under `.tab`
  (`PaletteDataSource.swift:126-137`). Verbs are registered before panes for the same reason
  (`OverlayCoordinator.swift:321-325`).
- **A Recents row must be re-`id`'d.** The same catalog row can appear under both "Recents" and its
  category; without `namespacedForRecents()` the two collide in SwiftUI's `ForEach`/`.id`
  (`PaletteModel.swift:204-222`), and `catalogID` (:188) is what strips the prefix back off so re-running
  a recent records the right id.
- **Do not add a seventh `PaletteAction` case for a registry verb.** Six were deleted for
  re-implementing a `route` arm; `PaletteModel.swift:118-123` says so and `check-supervisor.sh` enforces
  it. If a row names a registry verb, it IS that verb — `.binding(_)`.
- **`registryRows` and `coveredActions` must stay DERIVED.** `check-supervisor.sh` pins that
  `registryRows` reads `WorkspaceBindingRegistry.bindings` and `coveredActions` reads `declared`; a
  transcribed list would go stale silently. The reach test asserts a SHAPE, not a count.
- **`FuzzyMatcher.rank` and `.score` must agree bit-for-bit.** They are the same matcher with fzf's
  phase 4 skipped, pinned in `rust/slopdesk-fuzzy`; `.rank` exists to avoid a backtrace per candidate per
  keystroke, not to be a second answer.
- **The palette's ranking is memoized on four inputs.** If a new input starts affecting the result list,
  it must join `ResultsKey` (`OverlayCoordinator.swift:367`) or the list will silently go stale — the
  recents ride whole rather than behind a counter precisely so reading the key registers the Observation
  dependency.
