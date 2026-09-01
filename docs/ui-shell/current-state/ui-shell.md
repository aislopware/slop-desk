Originally surveyed 2026-06-25 against the single `SlopDeskClientUI` target. Re-verified against the
tree 2026-08-22. Every row below was re-checked at a named `file:line`; rows that changed verdict say
what removed them. Paths are repo-relative.

## Overview

The client shell is **two shells that share everything below the view layer** (`docs/56-client-ui-split.md`).
`SlopDeskClientUI` no longer exists: it split into `SlopDeskMacUI` (AppKit/macOS) and `SlopDeskPhoneUI`
(SwiftUI/iOS), over `SlopDeskClientCore` (overlay/palette/pane/rail/settings reducers),
`SlopDeskWorkspaceCore` (store, bindings, connection, terminal) and `SlopDeskWorkspaceModel` (the pure
domain + codec), with `SlopDeskSlate` as the one design ladder.

- **macOS** — `NSSplitViewController` (`SlopDeskSplitViewController`) with three columns: **navigator |
  content | code panel**. *There is no Details/inspector column* — the third column is the
  project-scoped embedded VS Code (`SlopDeskSplitViewController.swift:1-9,124-166`). The window runs
  `.hiddenTitleBar`; the chrome is the app's own `MacTitlebarBand` plus a window-corner sidebar toggle
  and agent rollup (`MacWorkspaceRootView.swift:157,164-166`). Every summoned surface is an `NSPanel`
  or a real sheet — **nothing SwiftUI floats over the split** (`MacWorkspaceRootView.swift:172-179`).
- **iOS/iPadOS** — a stock `NavigationSplitView` over `NavigatorColumn` + `ContentColumn`, with its own
  toolbar and an in-window overlay layer (`WorkspaceRootView.swift:101-134`). The code panel arrives as
  a full-screen cover instead of a third column (`WorkspaceRootView.swift:177-183`).

Domain model is unchanged in shape — `Session → Tab → SplitNode tree → Pane`
(`TreeWorkspace.swift`) — but the **codec and schema are owned by Rust now**: `currentSchemaVersion`
reads `slopdesk_ws_schema_version()` over FFI (`TreeWorkspace.swift:57`), whose value is
`rust/slopdesk-tree/src/workspace.rs:50` = **12** (the file's own prose still says 11; that comment is
stale, the constant is not).

Rows are marked **mac** / **phone** where the two diverge. The project rule is
`docs/56-client-ui-split.md:144-145`: *"Layout diverges; capability does not. A feature landing on one
platform is owed to the other, laid out for it. What is NOT owed is the same arrangement."*

---

## Capability matrix

| Feature | Status | Evidence file(s) / symbol(s) |
|---------|--------|-------------------------------|
| **Window / shell** | | |
| 3-column shell (navigator \| content \| **code panel**) | done · mac | `SlopDeskSplitViewController.swift:124-166`; column floors `:63,66,70` |
| 3-column shell with a **Details/inspector** column | removed | `6de70aae` 2026-07-02 "remove the right sidebar (inspector / Details panel) — keyboard-centric". **No `DECISIONS.md` ruling of its own** — `docs/ui-shell/COVERAGE.md:64` records that absence. `SlopDeskSplitViewController.swift:6-9` states it in place |
| 2-column split (sidebar \| content) + full-screen panel | done · phone | `WorkspaceRootView.swift:101-109,177-183` |
| Hidden-titlebar + own chrome band | done · mac | `SlopDeskMacApp.swift:619` `.hiddenTitleBar`; `MacTitlebarBand.swift:1-25` (left = tab strip, right = connection island, centre deliberately empty) |
| iOS toolbar chrome (pill · agent glyph · palette · panel · + · gear) | done · phone | `WorkspaceRootView.swift:287-329` |
| Sidebar collapse (⌘⇧L) | done | chord `WorkspaceBindingRegistry.swift:784-786`; mac `SlopDeskSplitViewController.applyCollapse:298`; phone `SidebarColumnVisibility` via `WorkspaceRootView.swift:57-62` |
| Code-panel collapse (⌘⇧R) | done | chord `WorkspaceBindingRegistry.swift:796-798`; `WorkspaceChromeState.toggleCodeSidebar:89`; mac split item `SlopDeskSplitViewController.swift:155-162`, phone cover `WorkspaceRootView.swift:200-205` |
| Move keyboard into the editor and back (⌥⌘R) | done | `WorkspaceBindingRegistry.swift:810-813`; mac = a responder swap (`MacWorkspaceRootView.swift:257-263`), phone = a reveal (`WorkspaceRootView.swift:272`) — stated divergence, not a gap |
| Auto-hide the tabs panel by tab count | done | `WorkspaceChromePolicy.applyAutoHide`, driven from both roots (`MacWorkspaceRootView.swift:194-195`, `WorkspaceRootView.swift:159-160`) |
| Animated column collapse on the Slate motion token | done · mac | `SlopDeskSplitViewController.swift:318-327` (`Slate.Motion.columnSlide`) |
| Flat ground divider (ISA-swizzle `FlatDividerSplitView`) | done · mac | `SlopDeskSplitViewController.swift:113,342-360` |
| Hand-tracked code-panel divider (AppKit's own drag can't grow it) | done · mac | `SlopDeskSplitViewController.swift:362-432`; width persisted `Defaults[.codeSidebarWidth]` `:250-265,404-408` |
| Window appearance / ground pinned app-wide | done · mac | `SlopDeskSplitViewController.pinWindowAppearance:271`; `SlateAppearancePin` |
| Window title tracks the focused pane | done · mac | `MacWorkspaceRootView.swift:206` → `WorkspaceChromePolicy.windowTitle(for:)` |
| Pin window / always-on-top | **done · mac** (was "missing") | `WorkspaceChromeState.pinned:57`/`togglePin:85`; `SlopDeskMacApp.swift:638` `.windowLevel(chrome.pinned ? .floating : .normal)`; View-menu row `WorkspaceCommands.swift:154-157`; palette row `PaletteDataSource.swift:269-273`; action `WorkspaceBindingRegistry.swift:121` (chord-less by default). **Phone: inert by design** — "iOS has no resizable floating window, so the flag is inert there" (`WorkspaceChromeState.swift:56`), and the palette row says so. A stated platform fact (`COVERAGE.md:84`), not a gap |
| Dock progress / error tint / bounce | done · mac | `DockProgressController.swift:63-84`; wired `SlopDeskMacApp.swift:166-172,405-406,488-490`. Phone has no Dock — platform fact |
| Picture-in-Picture | n/a | Never built; there is no removal ruling because there was nothing to remove. The remote desktop is its own OS window, not a pane and not a PiP surface (`DECISIONS.md` §Remote desktop is a DEDICATED OS WINDOW) |
| **Tab / session model** | | |
| `Session → Tab → SplitNode → Pane` domain | done | `TreeWorkspace.swift`, `Session.swift`, `Tab.swift`, `SplitNode.swift` |
| Persisted schema | done — **v12, Rust-owned** | `TreeWorkspace.swift:57` → `rust/slopdesk-tree/src/workspace.rs:50`; codec `SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift` |
| Multiple sessions in the model | done | `TreeWorkspace.sessions: [Session]` `:29`; `WorkspaceStore.newSession:1635`, `selectSession:1685` |
| Multi-session **switcher UI** | removed | `d1d4398b` 2026-07-02; `DECISIONS.md` §Multi-session switcher UI REMOVED — "the workspace is effectively single-session at the UI. The `Session` domain type and the store's multi-session internals STAY." No session list exists in either navigator |
| Multiple tabs per session | done | `Session.tabs`; cycle `⌘⇧]`/`⌘⇧[` `WorkspaceBindingRegistry.swift:520-527` |
| Select pane by number (⌘1…⌘9) | done | `WorkspaceBindingRegistry.selectPaneBindings:967-972` — note the digits count **panes** in drawn order, not tabs (`:165`) |
| New tab | done | `WorkspaceStore.newTerminalPane(_:):3471-3476`. **mac**: ⌘T (`:502-504`) + menu + palette + the empty-canvas button (`MacContentCanvas.swift:82`) + a drag-to-`New Tab` drop slot (`MacNavigatorColumn.swift:658,684`). **phone**: toolbar `+` and sidebar `+` (`WorkspaceRootView.swift:318`, `NavigatorColumn.swift:181`). No `+` button on the mac sidebar — chord/menu carry it there |
| In-pane kind chooser (Terminal / Remote) | removed | Retired with the kind list: "The in-pane kind CHOOSER itself is retired (every new-pane gesture mints a terminal directly)" — `PaneChooser.swift:15-18`. `InPaneChooserView` / `openChooserPane` have zero hits in `Sources` or `Tests`. `PaneChooserOption` survives only as the kind→title/symbol registry |
| `PaneKind` cases | done — **two** | `PaneSpec.swift:38-45` = `.terminal`, `.desktop`. Retired discriminators `claudeCode`, `web`, `chooser`, `remoteGUI`, `systemDialog` decode-fold to `.terminal` (`:47-53`); Rust mirror `rust/slopdesk-tree/src/session.rs:29-36` |
| Web pane (`PaneKind.web`) | removed | `65da3c0d` 2026-07-02; `DECISIONS.md` §Web pane REMOVED. The WKWebView that *does* ship is the **code panel**, a different feature |
| Remote-window pane (`PaneKind.remoteGUI`) | removed | 2026-07-22; `DECISIONS.md` — full-desktop is the only remote-viewing mode and it opens as its own OS window; the wire types go dormant, not deleted |
| Break pane to its own tab (⌃⌘T) | done | `WorkspaceBindingRegistry.swift:413-415` |
| Detach pane into its own window (⌥⌘P) | **done · mac** (new) | `WorkspaceBindingRegistry.swift:421-423`; `SatellitePaneWindows.swift`, `MacSatellitePaneContent.swift`. Gated `#if canImport(AppKit)` in `PaneDragCoordinator.swift:22-35,316-425`. **Platform fact, ruled** — `WorkspaceBindingRegistry.swift:23-24`: "macOS only — a no-op routing on iOS (no NSWindow)". See Notes |
| Close tab / close window | done | `.closeTab` chord-less, `.closeWindow` ⌘⇧W (`WorkspaceBindingRegistry.swift:174-177`) |
| Close-confirm guard on a busy shell | done | `CloseConfirmationPolicy.swift`, `WorkspaceStore+CloseConfirmation.swift:1-40`, copy shared by `CloseConfirmationCopy.swift`; mac `NSAlert` (`MacCloseConfirmation.swift`), phone `.confirmationDialog` (`OverlayHostView.swift:137-262`). Ratcheted by `scripts/check-supervisor.sh` |
| Reopen closed (⌘⇧T) | **done** (was "dead chord") | `WorkspaceBindingRouting.swift:292` → `WorkspaceStore.reopenLastClosedPane():33` → `reopenClosedTab(at:):50`, a LIFO `closedTabRecords` ring restoring the whole tab (split tree, specs, original `PaneID`s) through the `reopenClosedTab` wire intent (`WorkspaceIntent.swift:36`). Tests: `ReopenClosedTabTreeTests.swift`. The old symbol `reopenClosedPane` is gone; the capability is not |
| Tab drag-reorder | removed | 2026-07-10; `DECISIONS.md` — "`.manual` drag-reorder … deleted". Ordering is fixed: By-Project sections A→Z, rows in creation order (`TabOrdering.swift:6-9`). `reorderTabs` (wire type 8) survives dormant |
| **Sidebar / navigator** | | |
| Pane rows grouped by project | done | mac `MacNavigatorColumn.swift:313`, phone `NavigatorColumn.swift:133-173`; shared builder `RailRowsBuilder`/`SidebarSections`, memoized by `RailRowsMemo` |
| Sort / group hamburger | removed | 2026-07-10; `DECISIONS.md` §Sidebar grouping — "The sidebar hamburger (`SlateSortMenuButton`), `TabGrouping`/`TabSort` … are deleted." Zero hits in `Sources`/`Tests` |
| Sidebar search / filter | **done** (was "missing") | Shared filter `RailRowsBuilder.filtered`; mac `SlateNativeSearchField` as the header row (`MacNavigatorColumn.swift:62,117-152`), phone `.searchable(text:prompt:"Search tabs")` (`NavigatorColumn.swift:178`) |
| Agent-status mark on the row | **done** (was "missing") | mac `MacSidebarRow.swift:48,284-287` → `MacStatusMark.swift:89-193`; phone `StatusDotView` (`NavigatorColumn.swift:399-404`). Both read `StatusPresentation` |
| Attention / lifecycle badge on the row | **done** (was "missing") | `TabBadgeKind.swift:19-113` (9 cases, fused by `TabBadgeResolver` over Rust `slopdesk_agent_tab_badge`, `TabBadge.swift:11-19`). Lifecycle states render as the status mark; privilege states (`.sudo`, `.caffeinate`) as a distinct glyph — mac `MacSidebarRow.swift:329-340`, phone `TabBadgeView.swift:1-9` |
| Git readout in the sidebar | **done** (new) | On the **project header**, not the row: `SidebarGitLine.swift:4,60-62` (dialect owned by Rust `slopdesk_workspace::git_line`); mac `MacSidebarHeader.swift:38,187-188`, phone `NavigatorColumn.swift:466-468` |
| Cwd subtitle on the row | partial — by design | `RailRow.subtitle` is populated only when a pane strayed from its section's project root (`RailRowsBuilder.swift:19-26`); an at-root row is single-line and carries its cwd as tooltip + hidden search key (`:42-45`) |
| Close a row | done | mac hover `×` cross-faded with the trailing cluster (`MacSidebarRow.swift:123-136,288-289`); phone trailing swipe action (`NavigatorColumn.swift:216-222`) — a stated layout divergence (`NavigatorColumn.swift:32-35`), same capability |
| Read-only lock / sync-input glyphs on the row | done | `RailRow.readOnly` (`RailRowsBuilder.swift:38-41`), rendered in the trailing cluster on both |
| Horizontal tab strip while the sidebar is hidden | **done · mac** (new) | `MacTabStrip.swift:1-19` — same model as the sidebar, strict subset per chip (title + status mark + bed; no git line, no subtitle, no receipt). **No phone equivalent**; the phone's tabs column is the `NavigationSplitView`'s own leading column, which is the layout answer, not a missing capability |
| Connection island at the sidebar foot | done | mac `MacNavigatorColumn.swift:227` (stacked) and `MacTitlebarBand.swift:53` (inline, collapsed-only) |
| **Content / pane grid** | | |
| Absolute-rect pane compositor (no nested `HSplitView`) | done | mac `MacSplitCanvasView.swift:40,283`, phone `SplitContainer.swift:55,132` — both from the one solver `SplitTreeRenderModel.layout(for:in:)`; every mounted tab stays alive at alpha 0 |
| Per-leaf container | done | mac `MacPaneContainer.swift:33`, phone `PaneContainer.swift:31` |
| Pane resize scrim | done | `PaneResizeScrimState.swift` (shared); mac `MacPaneScrims.swift:39,45`, phone `PaneResizeScrim.swift` + `PaneContainer.swift:139-144` |
| Pane unfocus dimming | removed | Tried and reverted on both: "the unfocused panes render at FULL opacity (no dim — it washed out live content)" `PaneContainer.swift:204-206`; "focus is a MARK ADDED to the subject (the corner triangle), never a dimming of its siblings" `MacPaneContainer.swift:13-16`. `unfocusedPaneOpacity` has no source hit |
| Recede veil under the ⌃⇥ switcher | done | `MacPaneScrims.swift:49` `.recede()`, `PaneRecedeScrim.swift` — transient, gated on `store.paneSwitcher` |
| Empty state (no session / link down / no tabs) | done | One copy table `PaneEmptyCause` (`PaneCanvasPolicy.swift:108-179`) behind two renderers: `MacSlateEmptyState.swift:21`, `SlateEmptyState.swift:20`. Four causes, each with its one next action |
| The island (moat · corner · glass · rim) | done | mac = three AppKit constraints + one CALayer on `MacContentColumn` (`MacContentColumn.swift:1-28`); phone paints its own ground (`ContentColumn.swift:44,62`) |
| Island chip stack (copy receipt · notice · collapsed-sidebar indicator) | done | mac `MacIslandChipStack.swift` via `MacContentCanvas.swift:42,61`; phone `IslandChipStack.swift` via `ContentColumn.swift:107-114` |
| **Pane splits + resize** | | |
| Split right / down / left / up | done | ⌘D · ⌘⇧D · ⌥⌘D · ⌥⌘⇧D (`WorkspaceBindingRegistry.swift:15-18,378-380`) |
| Live-resize divider (drag) | done | mac `MacPaneDivider.swift:230`, phone `PaneDivider.swift:85-97` |
| Double-click divider to equalize | done | mac `MacPaneDivider.swift:219-226`, phone `PaneDivider.swift:99` |
| Resize cursor / pointer on the divider | done | mac `MacPaneDivider.swift:177-215`, phone `PaneDivider.swift:84` — both through `PaneCanvasMetrics.resizePointer` |
| Keyboard equalize (⌃⌘=) | done | `WorkspaceBindingRegistry.swift:484-486` |
| Keyboard pane resize (⌃⌘⇧arrows) | done | `WorkspaceBindingRegistry.swift:34-37` |
| Move pane within the tree (⌥⌘⇧arrows) | done | `WorkspaceBindingRegistry.swift:28-31` |
| Algorithmic layout presets + cycle (⌃⌘L) | **done** (new) | `WorkspaceBindingRegistry.swift:43-44` (`.cycleLayout`, `.applyLayout(LayoutPreset)`) |
| Commit-on-release (defer the grid to the host) | done | `WorkspaceStore.setTerminalResizeSuspended:3104`; mac pane divider `MacSplitCanvasView.swift:374-376`, phone `SplitContainer.swift:223,238-240`; the column dividers do the same at `SlopDeskSplitViewController.swift:197,208,214,313` |
| Zoom / maximize active pane | done — **⌘⇧↩** | `WorkspaceBindingRegistry.swift:638-641` (the old survey said ⌥⌘↩); `WorkspaceBindingRouting.swift:145` → `WorkspaceStore.toggleZoomActivePane:3335`; `Tab.zoomedPane` is render-only (`Tab.swift:27-29`) |
| **Drag-drop drop zones** | | |
| Grab pill (drag to move) | done | mac `MacPaneMoveAffordance.swift`, phone `PaneMoveAffordance.swift`; vocabulary `PaneDragVocabulary.swift` |
| In-canvas zones: swap · re-split edge · dock gutter | done | `PaneDropZone` — `PaneDragVocabulary.swift:102-110`; geometry `PaneDropGeometry.swift:67`, `PaneDropZoneLayout.swift`; presentation `DropZonePresentation.swift` |
| Drop on a **sidebar row** (with spring-load reveal) | **done** (new) | `PaneDragDestination.sidebarRow` `PaneDragVocabulary.swift:94`; `PaneDragCoordinator.swift:14-15,126-141,204-224` |
| Drop on a **New Tab** slot | **done** (new) | `PaneDragDestination.newTab` `:96`; mac slot `MacNavigatorColumn.swift:658,684-701` |
| **Tear off** to a satellite window | **done · mac** (new) | `PaneDragDestination.tearOff` `:96`; `PaneDragCoordinator.swift:17`, `SatellitePaneWindows.swift`, drag chip `MacPaneDragChipPanel.swift`. Platform fact, ruled (it produces an `NSWindow`) — see Notes |
| Drag overlay (ghost chip + zone preview) | done | mac `MacPaneDropOverlay.swift`, phone `PaneDropOverlay.swift`, model `PaneDropOverlayModel.swift` |
| File / URL / text drop into a pane | **done** (new) | Classify `PaneDropGate.classify:175` + `PaneFileImportPolicy.swift:31` + `DropActionResolver.swift:58` (over Rust FFI); upload `FileUploadCoordinator.swift:27`. Receivers on both: `MacPaneDropReceiver.swift`, `PaneDropReceiver.swift`. Phone adds a document-picker door because a phone has no drag *source* (`PaneFileImporter.swift:1-27`) |
| **Pane focus + cycle** | | |
| Click / tap to focus | done | `PaneContainer` / `MacPaneContainer` |
| Directional focus (⌃⌘arrows) | done | `WorkspaceBindingRegistry.swift:602-620` |
| Sequential pane cycle | **done** (was "missing") | `.cyclePaneNext` ⌘] / `.cyclePanePrev` ⌘[ (`WorkspaceBindingRegistry.swift:51-52,625-633`) → `WorkspaceBindingRouting.swift:142-143` → `WorkspaceStore.cyclePaneFocusTree(forward:)` (`WorkspaceStore+PaneCycle.swift:14-16`, DFS pre-order, wraps) |
| MRU pane switcher (⌃⇥ press-and-hold) | **done** (new) | Deliberately chord-less in the table — each platform claims ⌃⇥ above it (`WorkspaceBindingRegistry.swift:166-173`); state `PaneSwitcher.swift` + `WorkspaceStore+PaneSwitcher.swift`; surfaces `MacPaneSwitcher.swift`, `PaneSwitcherOverlay.swift` |
| Focus a pane from a sidebar row | done | mac `MacSidebarRow`, phone `NavigatorColumn` selection → `store.focusPaneTree` |
| Focus follows the workspace across the code panel | done · mac | `MacWorkspaceRootView.honourFocusRegion:228` + `CodeSidebarFocusPolicy` — the region is per-tab |
| **Overlays / command surfaces** | | |
| `OverlayCoordinator` mounted | **done** (was "not mounted") | Built once in `ClientComposition.swift:200`. **phone**: `OverlayHostView` as a `.overlay` (`WorkspaceRootView.swift:119-124`). **mac**: an AppKit reconciler — `@State MacOverlayPanels` (`SlopDeskMacApp.swift:89`) driven by `.onChange(of: overlayCoordinator.*)` edges (`:523-604`), each flag diffed into an `NSPanel` or a real sheet (`MacOverlayPanels.swift`). 65 files reference it |
| Command palette (⌘⇧P) | **done** (was "not wired") | `PaletteModel.swift`, `PaletteDataSource.swift`, `PalettePresentation.swift`; mac `MacPalette.swift` via `MacOverlayPanels.setPalette:108-138`, phone `PaletteView.swift` via `OverlayHostView.swift:233-234` + a toolbar button (iPad has no app-level `NSEvent` monitor, `WorkspaceRootView.swift:307-314`). Chord `WorkspaceBindingRegistry.swift:646-649` — **⌘⇧P, not ⌘K** |
| Keyboard cheat sheet (⌘/) | **done** (was "not wired") | Shared rows `CheatSheetContent.swift`; mac `MacCheatSheetPanel.swift` via `MacOverlayPanels.setCheatSheet:74-98`, phone a native `.sheet` (`WorkspaceRootView.swift:167-169`). Chord `:651-654` |
| Toast notifications | **done** (was "not wired") | `Toast.swift` + `ToastPresentation.swift`; mac `MacToastStack.swift` via `syncToasts:268-279`, phone always-mounted `ToastStackView` (`WorkspaceRootView.swift:131-134`) |
| Connect-to-Host editor | **done** (was "not mounted") | Shared `ConnectPresentation.swift`; mac document sheet `MacConnectSheet.swift:35-42` via `setConnect:246-255`, phone `.sheet` over `ConnectHostView.swift` (`OverlayHostView.swift:133-135`). Opened from the status affordance on both and from the palette (`OverlayCoordinator.swift:591-593`) |
| Global Search (⇧⌘F) | **done** (new) | `GlobalSearchController.swift`, `GlobalSearchPresentation.swift`; `MacGlobalSearch.swift` / `GlobalSearchView.swift`. Chord `WorkspaceBindingRegistry.swift:676-678` |
| Open Quickly (⌘⇧O) / Jump To (⌘J) | **done** (new) | `OpenQuicklyModel.swift`, `OpenQuicklyPresentation.swift`, `OpenQuicklySources.swift`; `MacOpenQuickly.swift` / `OpenQuicklyView.swift`. Chords `:959-961`, `:842-844`. Its **Recent** rows are the index-addressed reopen path (`OpenQuicklyPresentation.swift:248,328`) |
| Peek & Reply to a blocked pane (⌘⌥J) | **done** (new) | `PeekReply.swift`, `PeekReplyPresentation.swift`; `MacPeekReply.swift` / `PeekReplyOverlay.swift`. Chord `:592` |
| Jump to pane needing attention (⌘⇧U) | **done** (new) | `WorkspaceBindingRegistry.swift:580`; `AttentionSupervision.swift`, `WorkspaceStore+Attention.swift` |
| Command navigator (⌃⌘O) | **done** (new) | **Pane-local, not coordinator-owned** — mounted inside one leaf so a card over one pane doesn't deafen the sidebar: `MacTerminalLeafView.swift:55`, `TerminalLeafView.swift:195`; model `CommandNavigatorModel.swift` |
| Clipboard / unsafe-paste confirmation | **done** (new) | Raised by the remote program, not summoned: phone in-window card `ClipboardConfirmCard.swift` (`WorkspaceRootView.swift:143`), mac `NSAlert` `PasteProtectionSheet.swift`; shared `ClipboardConfirmPresentation.swift` |
| Modal pointer shield (hover under a card) | done | mac `MacModalShield.swift` + `TerminalPointerShield` (`MacWorkspaceRootView.swift:284-286`), phone `.allowsHitTesting` on the column (`ContentColumn.swift:74`) |
| Context-menu model (`ContextMenuModel`) | removed | Zero live definitions. Menus are now built where they are shown — the sidebar tab context menu (`MacNavigatorColumn`, threaded `PreferencesStore` for the Prevent-Sleep row) and `TerminalContextMenu.swift` |
| **Status indicators** | | |
| Connection status surface (dot · host · label · ping) | done | mac `MacConnectionIsland.swift:252` (two mounts, stacked + inline), phone `ConnectionPill.swift:48,64,77`. Reading shared via `ConnectionReading.swift` / `ConnectionTelemetry.swift`. `ConnectionStatusPill` (the old symbol) is gone |
| Retry from the status surface | done | mac `MacConnectionIsland.swift:67,206,398-404`, phone `ConnectionPill.swift:128-129,198-210`, both gated on `ConnectionReading.showsRetry` |
| Aggregate agent rollup beside the sidebar toggle | **done · mac** (new) | `RailStatusRollup.swift` / `RailStatusRollupMount`, mounted `MacWorkspaceRootView.swift:164-166`; travels with the navigator's live width (`WorkspaceChromeState.navigatorWidth:40`) |
| Active-pane agent glyph | done · phone | `WorkspaceRootView.swift:301-306` via `StatusPresentation.agentReading` |
| Bottom status bar | removed | Never a bottom bar; the per-pane status strip was cut on a **user ruling recorded in code, not in `DECISIONS.md`**: `TerminalLeafView.swift:98-102` — "the user judged the terminal pane footer low-value and asked to drop it … host + connection status now live ONCE in the connection island" (`COVERAGE.md:72`) |
| **Right panel (code / devices)** | | |
| Embedded VS Code (code-server in a pooled WKWebView) | **done** (new) | mac third column `MacCodePanelColumn.swift` (plain split item so collapse never tears the webview down — `SlopDeskSplitViewController.swift:145-157`); phone full-screen cover `PhonePanelSheet.swift`. Shared `CodeSidebarModel.swift`, `CodeSidebarWebViewPool.swift` |
| Four panel surfaces (code · simulators · android · desktop) | done | `PanelSurface` `WorkspaceChromeState.swift:144-149`; mac strip/rail `MacPanelStrip.swift`, `MacPanelRail.swift`; phone a `Menu` with a `primaryAction` on the toolbar button (`WorkspaceRootView.swift:349-372`) — the explicit "a rail cannot be copied here, the capability is *open on a named surface in one gesture*" divergence |
| Per-project open gate (opening is an act, not a focus side effect) | done | `WorkspaceChromeState.openedCodeProjects:127`, `openCodeProject:132` (user-directed 2026-08-07) |
| **Settings** | | |
| Settings surface | done | mac `Settings` scene → `MacSettingsWindow.swift` + `MacSettingsNavigator.swift`; phone `.sheet` → `SettingsSheet.swift` (iOS has no `Settings` scene). Shared taxonomy `SettingsTaxonomy.swift`, `SettingsCatalog.swift`, `AllSettingsCatalog.swift` |
| Keybindings editor | done | `KeybindingsEditorModel.swift` + `KeybindingsEditorReading.swift`; `MacKeybindingsEditor.swift` / `KeybindingsEditorView.swift` |
| Theme picker / catalogue / light-dark slots / per-theme fonts | removed | 2026-08-08 user-directed; `DECISIONS.md` §"ONE appearance — the theme picker is deleted, not defaulted": *"A picker whose second setting can only degrade the design is not a choice, so it goes rather than acquiring a default."* `ThemeStore`, `ThemeChoice`, `ThemeCatalog`, `AppearancePreferences.theme/darkTheme/separateDarkTheme` all gone |
| Theme editor / import · workspace export-import | removed | `0166057c` 2026-07-03; `DECISIONS.md`. `WorkspaceTransfer` has no live definition |
| **Deleted verticals (do not re-file as gaps)** | | |
| Composer · Prompt Queue · Send-to-Chat · Fork-in · agent input footer | removed | `92472b0a` 2026-07-03; `DECISIONS.md` — they "duplicated typing straight into the terminal". `AgentInputFooter*` gone; `InputBarModel` kept |
| Recipes · Snippets | removed | `d63e1274` 2026-07-03; `DECISIONS.md`. `SnippetExpander`, `Snippet` gone; `SendKeysParser` kept (launch presets, templates, block re-run, drops, `pane send-keys`) |
| Floating panes | removed | `231f1398` 2026-07-03; `DECISIONS.md` — "the tiled split tree is the ONLY pane layout again". All that survives is a decode-ignore note for a stale persisted key (`Tab.swift:18-20`). The tear-off satellite window is a *different*, live feature |
| Details panel tabs (Info · Outline · Git · Files) | removed | With the column (`6de70aae`). `InspectorColumn`, `BlockHistoryView` have no live definitions; the block history lives on as the ⌃⌘O command navigator and Global Search |

---

## Key files

**macOS shell — `Sources/SlopDeskMacUI/`**

- `SlopDeskMacApp.swift` — the scene: window style, overlay-panel reconciler, menus, pin level
- `SlopDeskMacApp+Window.swift` — window geometry / traffic-light glue
- `App/MacWorkspaceRootView.swift` — window root + `WorkspaceSplitRepresentable`
- `App/SlopDeskSplitViewController.swift` — the 3-column AppKit shell (navigator \| content \| code panel)
- `App/DockProgressController.swift` — Dock tile progress / error tint / bounce
- `App/SatellitePaneWindows.swift`, `App/MacPaneDragChipPanel.swift` — detached-pane windows + drag chip
- `Chrome/MacTitlebarBand.swift`, `Chrome/MacTabStrip.swift`, `Chrome/MacConnectionIsland.swift`,
  `Chrome/MacWindowSidebarToggle.swift`, `Chrome/RailStatusRollup.swift` — the window chrome
- `Columns/MacNavigatorColumn.swift`, `Columns/MacSidebarRow.swift`, `Columns/MacSidebarHeader.swift`,
  `Columns/MacStatusMark.swift` — the sidebar
- `Columns/MacContentColumn.swift`, `Pane/MacContentCanvas.swift`, `Pane/MacSplitCanvasView.swift`,
  `Pane/MacPaneContainer.swift`, `Pane/MacPaneDivider.swift`, `Pane/MacPaneMoveAffordance.swift`,
  `Pane/MacPaneDropOverlay.swift`, `Pane/MacPaneScrims.swift` — the canvas
- `Overlays/MacOverlayPanels.swift` (the reconciler) + `MacPalette`, `MacCheatSheetPanel`,
  `MacToastStack`, `MacConnectSheet`, `MacCloseConfirmation`, `MacGlobalSearch`, `MacOpenQuickly`,
  `MacPaneSwitcher`, `MacPeekReply`
- `Panel/MacCodePanelColumn.swift`, `Panel/MacPanelStrip.swift`, `Panel/MacPanelRail.swift` — right panel
- `Input/WorkspaceKeyDispatcher.swift` — the app-level `NSEvent` chord monitor
- `Commands/WorkspaceCommands.swift` — the menu bar

**iOS shell — `Sources/SlopDeskPhoneUI/`**

- `PhoneAppDelegate.swift`, `PhoneSceneDelegate.swift`, `WorkspaceRootView.swift` — UIKit app +
  scene delegate, and the `NavigationSplitView` root they still host (docs/62 stage A/D)
- `Columns/NavigatorColumn.swift`, `Columns/ContentColumn.swift`
- `Chrome/ConnectionPill.swift`, `Chrome/TabBadgeView.swift`, `Chrome/SidebarColumnVisibility.swift`
- `Pane/SplitContainer.swift`, `Pane/PaneContainer.swift`, `Pane/PaneDivider.swift`,
  `Pane/PaneMoveAffordance.swift`, `Pane/PaneResizeScrim.swift`, `Pane/PaneFileImporter.swift`
- `Overlays/OverlayHostView.swift` (the single SwiftUI mount) + `PaletteView`,
  `KeyboardCheatSheetView`, `ToastStackView`, `ConnectHostView`, `GlobalSearchView`,
  `OpenQuicklyView`, `PaneSwitcherOverlay`, `PeekReplyOverlay`, `IslandChipStack`,
  `ClipboardConfirmCard`
- `Panel/PhonePanelSheet.swift` — the right panel as a full-screen cover
- `Settings/SettingsSheet.swift` — the in-app settings sheet

**Shared reducers — `Sources/SlopDeskClientCore/`**

- `App/ClientComposition.swift` — builds the store, connection, chrome, overlay once for both shells
- `App/WorkspaceChromeState.swift` — collapse flags, panel surface, pin flag, navigator width
- `App/WorkspaceChromePolicy.swift` — auto-hide + window title
- `Overlays/OverlayCoordinator.swift` — the one overlay reducer
- `Overlays/CheatSheetContent.swift`, `ConnectPresentation.swift`, `CloseConfirmationCopy.swift`,
  `Toast.swift`, `ToastPresentation.swift`
- `Palette/PaletteModel.swift`, `PaletteDataSource.swift`, `PalettePresentation.swift`, `FuzzyMatcher.swift`
- `Pane/PaneDragCoordinator.swift`, `PaneDragVocabulary.swift`, `PaneDragResolver.swift`,
  `PaneDropGeometry.swift`, `PaneDropGate.swift`, `PaneCanvasPolicy.swift`, `PaneResizeScrimState.swift`
- `Rail/RailRowsBuilder.swift`, `RailRowsMemo.swift`, `SidebarGitLine.swift`, `SidebarRowReading.swift`
- `Settings/SettingsTaxonomy.swift`, `SettingsCatalog.swift`
- `CodeSidebar/CodeSidebarModel.swift`, `CodeSidebarWebViewPool.swift`, `CodeSidebarFocusPolicy.swift`

**Shared store / domain**

- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift` (+ its `+…` extensions)
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — action → store-op dispatch
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift` — the one chord table
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/Tree/SplitTreeRenderModel.swift` — the layout solver
- `Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift`, `Session.swift`, `Tab.swift`, `SplitNode.swift`
- `Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift` — `PaneKind` and its retired-value fold
- `Sources/SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift` — the v12 file codec
- `Sources/SlopDeskSlate/` — `SlateDesign.swift`, `StatusPresentation.swift`, `SlateAppearancePin.swift`

---

## Notes (divergences, gaps, traps)

### The 2026-08-20 find-and-replace trap
Commit `25a6d342` ("fold the shared SwiftUI target into the iOS half") renamed `SlopDeskClientUI` →
`SlopDeskPhoneUI` across this doc mechanically. Every macOS AppKit file it then claimed lived under
`Sources/SlopDeskPhoneUI/` was wrong: `SlopDeskSplitViewController`, `WorkspaceKeyDispatcher`,
`SlateTitlebar` and the rest are `SlopDeskMacUI` or were deleted outright. Several entries also
carried a `/Users/dev/slop-desk/` prefix from another machine. Both are fixed above; a symbol named
here was read at the line cited.

### Where the two shells legitimately diverge
Per `docs/56-client-ui-split.md:144-145` — *layout diverges; capability does not*. These are layout
answers to the same capability, each stated in the code:

- **Summoned surfaces.** mac = `NSPanel`/sheet reconciled from the coordinator's flags; phone = one
  in-window SwiftUI card layer. The reason is in `MacWorkspaceRootView.swift:172-179`: an
  `NSHostingView` claims every hit inside its bounds, so an always-mounted SwiftUI layer over the
  split would make the window click-dead everywhere its ink is not.
- **Cheat sheet.** mac panel vs phone native `.sheet`; they meet at `CheatSheetContent`.
- **Right panel.** mac third column + rail; phone full-screen cover + a `Menu` with `primaryAction`
  that names the same four surfaces (`WorkspaceRootView.swift:331-348` argues this explicitly).
- **Row close.** mac hover `×`, phone trailing swipe (`NavigatorColumn.swift:32-35`).
- **Focus Code Panel.** mac toggles which side holds first responder; phone reveals — "there is no
  responder duel on iOS" (`WorkspaceRootView.swift:266-268`).
- **Pin Window · Dock progress · window-size modes.** Platform facts, recorded in place
  (`WorkspaceChromeState.swift:56`, `COVERAGE.md:83-85`).

### Detach-a-pane is macOS-only — and it IS ruled (correction)
⌥⌘P (`.detachPane`) and the drag-`tearOff` destination both dead-end on iOS: `PaneDragCoordinator`
puts the whole satellite path behind `#if canImport(AppKit)`, and `platformCursorLocation()` returns
`nil` on the `#else` arm so a detached drag never resolves
(`PaneDragCoordinator.swift:22-35,316-425`).

This is a **platform fact with a stated reason**, not an unexplained gap — the ruling is on the enum
case itself, at `WorkspaceBindingRegistry.swift:23-24`: "pop the active pane out into its OWN macOS
window … **macOS only — a no-op routing on iOS (no NSWindow)**." Same shape as Pin Window
(`:115-117`, "iOS has no window level (documented no-op)"). Nothing is owed here; the capability has
no iOS referent, because the thing it produces is an `NSWindow`.

### The chord table moved; several old chords in this doc were wrong
`WorkspaceBindingRegistry` is the single source of truth and disagreed with the old survey on four
rows: palette is **⌘⇧P** (not ⌘K), zoom is **⌘⇧↩** (not ⌥⌘↩), balance is **⌃⌘=** (not ⌥⌘=), pane
resize is **⌃⌘⇧arrows** (not ⌥⌘arrows). Tab cycling moved to ⌘⇧]/⌘⇧[ so ⌘]/⌘[ could take the new
sequential pane cycle (`WorkspaceBindingRegistry.swift:624-633`).

### ⌘⇧T is live, under a different name
The old survey called it a dead chord on the tree path. `WorkspaceBindingRouting.swift:292` routes
`.reopenClosed` to `WorkspaceStore.reopenLastClosedPane()`, which restores the whole closed tab —
split tree, specs, original `PaneID`s — from the `closedTabRecords` LIFO through the
`reopenClosedTab` wire intent. The symbol the old doc searched for, `reopenClosedPane`, simply does
not exist any more.

### The status mark and the badge are two things, fused
`TabBadgeResolver` fuses agent lifecycle and privilege state into one `TabBadgeKind`
(`TabBadge.swift:11-19`, decided in Rust). Lifecycle renders as the row's **status mark**; only
`.sudo` / `.caffeinate` render as a separate trailing glyph. The old "badge never rendered" note is
void — both halves are drawn on both platforms.

### Sidebar ordering is fixed and not a setting
By-Project sections A→Z, rows in creation order, no grouping menu, no sort menu, no drag-reorder
(`DECISIONS.md`, `TabOrdering.swift:6-9`). The `reorderTabs` wire verb survives dormant so the
golden vectors stay byte-identical — that is not an entry point.

### The schema is Rust's now
`TreeWorkspace.currentSchemaVersion` is an FFI read, not a Swift literal
(`TreeWorkspace.swift:57` → `rust/slopdesk-tree/src/workspace.rs:50` = 12). The prose comment at
`TreeWorkspace.swift:15` still says 11 and is stale; the constant is authoritative and there is no
migration behind the comparison — a file at any other version is set aside.
