# SlopDesk UI-Shell — Acceptance User Stories (Self-Verification Checklist)

Flat list of every acceptance story across all epics in `BACKLOG.md`, tagged with epic id, **state**, and
verifiability.

**Verifiability** (unchanged — what it takes to prove a LIVE story):
- **unit-testable** — provable headlessly (`swift test`) against domain/engine code.
- **GUI-verifiable** — requires the real app (HW GUI per `scripts/check-macos.sh` / cua-driver), not headless.
- **both** — unit-testable core + GUI surface.

**State** (added 2026-08-22 after a tree audit found this file claiming shipped features that do not exist):
- no marker — **ships on both platforms**, macOS and iOS.
- **MAC ONLY** — present on macOS, absent on iOS. Per `docs/56-client-ui-split.md:99-102` and `:144-145`
  ("Layout diverges; capability does not. A feature landing on one platform is owed to the other"), every
  such row states either the platform fact that forces it or that it is an unclosed gap.
- **GONE** — built, then deleted. Each cites the commit and the `docs/DECISIONS.md` entry.
- **NEVER BUILT** — the spec page designs it; no code ever landed.
- **PARTLY** — the story is a compound claim and only some of it is true; the row says which half.

Why this file was wrong: it was written against the 2026-06-27→06-29 epic close-out. Three later waves
invalidated large parts of it and nobody re-ran the checklist — the **feature prune** (2026-07-02/03,
commits `c930f050` `6de70aae` `e483ec75` `65da3c0d` `d1d4398b` `92472b0a` `d63e1274` `231f1398`
`0166057c`), the **sidebar/remote-window re-scopes** (2026-07-10 / 2026-07-22), and **ONE APPEARANCE**
(2026-08-08). Deleted epics are kept below rather than dropped, so a future reader sees the state instead
of a gap in the numbering.

---

## E1 — Default-keymap parity & routing completion
- **ES-E1-1** [E1] `⌘⌥D` / `⌘⌥⇧D` splits a pane left / up and focuses it. — both
- **ES-E1-2** [E1] `⌘]` / `⌘[` cycles focus to next / previous pane sequentially. — both
- **ES-E1-3** [E1] `⇧PageUp/Down`, `⇧Home/End`, `⌘PageUp/Down` page / jump / command-jump the scrollback. — both
- **ES-E1-4** [E1] PARTLY — `⌘+` / `⌘-` / `⌘0` grow / shrink / reset the terminal font. The old "without
  reflowing the PTY grid" clause is WRONG and was corrected at the time: a font-SIZE change resizes the cell
  box, so the remote PTY reflows via SIGWINCH, and that is correct. Only font FAMILY/STYLE is
  grid-preserving. (`DECISIONS.md` §E15 fonts/prefs fidelity pass, item 4.) — GUI-verifiable
- **ES-E1-5** [E1] PARTLY (dev) — `commandPalette`, `cheatSheet`, `find`, `openQuickly`, `reopenClosed` are
  each registered in `WorkspaceBindingRegistry` with a unique, override-resolvable chord and a `routeTree`
  case. `composer`, `promptQueue` and `sendToChat` are GONE (2026-07-03, `92472b0a`) — no such
  `WorkspaceAction` cases exist, and `⌘⇧E` / `⌘⇧M` / `⌘⌃↩` are unbound. — unit-testable
- **ES-E1-6** [E1] MAC ONLY — binding `text:hi` / `csi:17~` / `esc:O` to a chord injects the literal bytes;
  `unbind:` disables a default. `WorkspaceBindingOverrides.textBinding(for:)` / `.isUnbound(_:)` are consulted
  only by `SlopDeskMacUI/Input/WorkspaceKeyDispatcher.swift:368,376`. iOS reads `isUnbound` for exactly one
  chord (⌃⇥, `SlopDeskWorkspaceCore/iOS/PhoneKey.swift:237`) and never reads `textBinding` at all.
  **No ruling records this split — it is an open capability gap.** — both

## E2 — Overlay host mount
- **ES-E2-1** [E2] `⌘⇧P` (or `⌘K`) opens the command palette centered, search pre-focused, every action grouped by section with keycap chips. — GUI-verifiable
- **ES-E2-2** [E2] In the palette: type to fuzzy-filter, arrow to move highlight, `↩` runs, `⌘↩` runs-and-keeps-open, `Esc` dismisses. — both (filter/rank unit-testable; chords GUI)
- **ES-E2-3** [E2] A toggled action (e.g. Toggle Tabs Panel) shows a ✓ when on. — GUI-verifiable
- **ES-E2-4** [E2] `⌘/` opens the keyboard cheat sheet overlay (grouped key map); `Esc` dismisses. — GUI-verifiable
- **ES-E2-5** [E2] A transient toast appears for background events and auto-dismisses. — GUI-verifiable
- **ES-E2-6** [E2] PARTLY — tapping the connection pill (or its give-up state) opens the connect-to-host
  overlay: LIVE, both platforms. The remote-window picker clause is GONE (2026-07-22,
  `DECISIONS.md` "Remote desktop is a DEDICATED OS WINDOW — remote-window mode is REMOVED"):
  `RemoteWindowPickerModal`/`View` and the palette's "New Remote Window Tab" row are deleted; the desktop
  stream opens as its own OS window via `action.newDesktopTab`. — GUI-verifiable

## E3 — Tree-path domain completion
- **ES-E3-1** [E3] After closing a tab, `⇧⌘T` restores it (LIFO) on the live tree path. — unit-testable
- **ES-E3-2** [E3] With working-directory = inherit, a new tab or split starts in the active pane's last-known cwd (from OSC 7). — both
- **ES-E3-3** [E3] With new-tab-position = after-current, a new tab inserts right after the active tab; = end appends. The op is Rust (`rust/slopdesk-tree/src/session.rs`, `new_tab_index`). — unit-testable
- **ES-E3-4** [E3] With close-confirmation = multiple_tabs, closing a window prompts only when it has >1 tab;
  = process prompts only when a child process runs. (`multiple_tabs` is window-scope only now — the tab row
  no longer offers it; the persisted value stays decodable but inert.) — unit-testable
- **ES-E3-5** [E3] (dev) `WorkspaceTreeOps.cyclePaneTarget(forward:in:)` is a pure sequential pane-cycle op covered by tests. — unit-testable

## E4 — Host metadata RPC service
> The four RPC verbs below are all LIVE and tested end to end (wire verb → host responder → `MetadataClient`
> → codec). What is GONE is every renderer they were built for: the Details/Inspector panel was removed
> whole on 2026-07-02 (`6de70aae`, "remove the right sidebar (inspector / Details panel) — keyboard-centric";
> the removal is referenced retroactively at `DECISIONS.md` §Host Windows rail, "the chord the removed
> Details panel freed", but never got its own decision entry). So each story below is split.

- **ES-E4-1** [E4] PARTLY — the process-list / listening-ports RPC ships (`MetadataVerb.processes`/`.ports`,
  `MetadataResponseBuilder`, `MetadataClient`). "They render in the inspector" is GONE: there is no
  inspector. `SlopDeskMacUI/App/SlopDeskSplitViewController.swift:6` — "There is no Details column".
  Zero UI callers. — both (decode unit-testable; render GONE)
- **ES-E4-2** [E4] PARTLY — `gitStatus` / `gitDiff` RPCs ship. What renders is ONE sidebar line (branch +
  ahead/behind + change count, `SlopDeskClientCore/Rail/SidebarGitLine.swift`). The changed-file list and
  the inline diff are GONE with the Git tab (2026-07-02, `c930f050` "remove the Git window"); `gitDiff` has
  no non-test caller. — both
- **ES-E4-3** [E4] PARTLY — `MetadataVerb.listDirectory` + `MetadataClient.listDirectory` ship and are
  unit-tested. Nothing calls them: the Files tab went with the Details panel. — unit-testable
- **ES-E4-4** [E4] PARTLY — `listAgentSessions` ships and IS consumed, by Open Quickly's Agents pill
  (`OpenQuicklyModel.agentItems(from:)`). `readAgentSession` has no UI caller — the transcript viewer it fed
  is GONE (see ES-E13-6). — both
- **ES-E4-5** [E4] (dev) Every host RPC decoder validates declared counts/lengths before allocating and drops
  malformed datagrams without trapping (`checked_count`, `rust/slopdesk-wire/src/metadata/codec.rs`). — unit-testable

## E5 — In-pane Find + Global Search
- **ES-E5-1** [E5] `⌘F` shows a find bar at the top-right of the focused pane, query field pre-focused. — GUI-verifiable
- **ES-E5-2** [E5] Typing live-highlights all matches and shows an `N of M` counter. — both (engine unit-testable; highlight GUI)
- **ES-E5-3** [E5] `↩`/`⌘G` advances, `⇧↩`/`⇧⌘G` reverses, scrolling to keep the current match visible; `Esc` closes and clears. — both
- **ES-E5-4** [E5] The `Aa` toggle makes search case-sensitive; the `.*` toggle interprets the query as regex. — unit-testable
- **ES-E5-5** [E5] `⇧⌘F` global-searches every tab's scrollback, results grouped by tab with a `N results — M tabs` summary; clicking a result jumps to that tab and line. — both

## E6 — Sidebar tab rows
- **ES-E6-1** [E6] An agent pane shows the correct status dot on its sidebar row (spinner=working, green check/dot=done, red=error/needs-permission, hand=awaiting input). — both (state unit-testable; dot GUI)
- **ES-E6-2** [E6] PARTLY — the running shell/process name ships on both rows. The `#N` shortcut number is
  MAC ONLY *and* only while ⌘ is held (`SidebarRowReading.shortcutHint`, read by `MacSidebarRow` and by no
  iOS row) — an open gap. The "cwd subtitle" was never a subtitle: the row is deliberately one line
  (`MacSidebarRow.swift:3-4`, "a title on one 32pt line and ONE trailing slot") and the cwd reaches only the
  hover tooltip / iOS accessibility hint. — GUI-verifiable
- **ES-E6-3** [E6] Typing in the sidebar search filters the tab list. — both
- **ES-E6-4** [E6] GONE (2026-07-10, `DECISIONS.md` "Sidebar grouping: host-computed By-Project key,
  group/sort options REMOVED") — grouping is ALWAYS By-Project; `TabGrouping`, `.byDate` bucketing and the
  sort hamburger are deleted. `TabOrdering.swift:6-9` states the absence. Sections sort A→Z
  (2026-08-10). — unit-testable
- **ES-E6-5** [E6] GONE (same commit) — no `.updated` recency sort, no `tabLastActiveAt` stamps, no manual
  drag-reorder. Rows follow creation order. The `reorderTabs` wire intent (type 8) survives as a dormant
  verb with no UI driving it. — both

## E7 — Settings sections + iOS + import/export
- **ES-E7-1** [E7] Settings shows eight sections on BOTH platforms —
  **General / Shell / Controls / Editor / Agents / Appearance / Keybindings / Advanced**
  (`SettingsTaxonomy.swift:33-41`, ordered by `rust/slopdesk-settings/src/settings_catalog.rs`). The story's
  old order swapped Appearance and Agents. Editor is present but reserved/empty
  (`settings_catalog.rs:451`, "Editor — reserved, deferred"). — GUI-verifiable
- **ES-E7-2** [E7] MOSTLY NEVER BUILT — of the five named orphan toggles only **record clipboard history**
  exists (`SettingsKey.recordClipboardHistory`, both platforms). `hideStatusBar`, `showBlockDividers`,
  `systemDialogPanes` and `autoSwitchLayouts` have zero occurrences in `Sources/` — the keys are not in
  `SettingsKey.swift` at all. (Hide-status-bar could not exist: there is no status bar — see ES-E10-3.) — both
- **ES-E7-3** [E7] The Advanced tab's searchable All-Settings list filters by key/label/description and offers Reset-All / Reset-Advanced with confirmation. — both
- **ES-E7-4** [E7] GONE (2026-07-03, `0166057c`; `DECISIONS.md` "Theme editor/import + workspace export/import
  REMOVED") — `WorkspaceTransferDocument`, `exportWorkspaceData()`, `importWorkspace(_:mode:)`, the
  `.slopdeskworkspace` envelope and the File-menu items are deleted end-to-end. Only the load-bound cap
  survives, as `WorkspacePersistence.maxItems`. — both
- **ES-E7-5** [E7] iOS: an in-app settings sheet exposes the cross-platform settings — and now every section,
  including Key Bindings (`SlopDeskPhoneUI/Settings/SettingsSheet.swift`). — GUI-verifiable

## E8 — Terminal interaction parity
> The embedder Swift for this epic lives under `ThirdParty/ghostty/integration/GhosttySurface/`, not
> `Sources/` — a `Sources/`-only search calls this whole cluster dead.

- **ES-E8-1** [E8] With Copy-on-Select on, every selection drops into the clipboard with no `⌘C`; trim-trailing strips trailing spaces per line. — both
- **ES-E8-2** [E8] PARTLY — `clearSelectionOnTyping` / `clearSelectionOnCopy` ship on both. **Backspace on a
  selected prompt deletes the whole selection does NOT exist**: there is no `backspaceDeletesSelection` key
  anywhere in the tree. This was documented as a "surface-but-don't-actuate" ceiling; the surface is gone
  too, so the row is now simply false. It was **superseded rather than dropped** — Cut (⌘X) is the shipped
  verb for "remove the selection" (`Sources/SlopDeskWorkspaceCore/Terminal/CutSelectionPolicy.swift`). — both
- **ES-E8-3** [E8] Pasting multi-line / trailing-newline / sudo / control-char content triggers a paste-protection confirmation, skipped inside a full-screen TUI. — both
- **ES-E8-4** [E8] PARTLY — Paste-as… offers **Selection / File-base64 / Escaped / Bracketed**
  (`TerminalContextMenu.Item`, four cases). The fifth, **→Composer**, is GONE with the Composer
  (2026-07-03, `92472b0a`: `Item.pasteToComposer` + `Context.hasComposer` + `onPasteToComposer` deleted). — both
- **ES-E8-5** [E8] GONE — the Scroll-Past-First/Last-Line settings (and Smooth Scroll with them) were
  **removed 2026-07-30**, having shipped ahead of a renderer that could actuate them. The removal is
  recorded where the code was, in the embedder:
  `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift:2161-2165` — "the fork exposes
  no row-snap hook and no overscroll-margin API, so `smoothScroll` OFF rendered exactly like ON and the
  scroll-past anchors (`ScrollPastPolicy`, now deleted with them) computed a float nothing could draw.
  Add the settings back with the viewport hook that actuates them, not before." Nothing persists now.
  ⚠️ *This row read NEVER BUILT until 2026-08-22: a `Sources/` + `rust/` grep found nothing because the
  evidence lives under `ThirdParty/`. That is the trap, in one row.* — both
- **ES-E8-6** [E8] Focus-follows-mouse (`SettingsKey.focusFollowsMouse`), hide-mouse-while-typing
  (`mouseHideWhileTyping`), the configurable right-click action (`rightClickAction`) and OSC-22 pointer
  shapes (`PointerShapeMapping`) all work per their settings. The cursor half is macOS by physics — iOS has
  no pointer. — GUI-verifiable

## E9 — Details panel — GONE, WHOLE
> Removed 2026-07-02 in `6de70aae`, "feat(shell): remove the right sidebar (inspector / Details panel) —
> keyboard-centric", after two intermediate merges the same day: Outline → Info ▸ Commands (`e483ec75`,
> `DECISIONS.md` §Outline-jump correctness) and Git → a summary row + popup (`c930f050`,
> `DECISIONS.md` §Git tab merged into Info). Pinned negatively:
> `Tests/SlopDeskClientCoreTests/OverlayCoordinatorMountTests.swift:337-344` asserts `action.detailsInfo`,
> `action.toggleInspector` and `action.gitStatus` are gone. The right-hand slot was later re-taken by the
> CODE panel (2026-08-02), which is a different feature.

- **ES-E9-1** [E9] GONE — no Info tab. The RPC survives; see ES-E4-1. — both
- **ES-E9-2** [E9] GONE — `OutlineView.swift`, `DetailsPanelTab.outline`, `view.detailsOutline` and
  `action.detailsOutline` all deleted. — both
- **ES-E9-3** [E9] GONE — `DetailsPanelTab.git`, `GitStatusView`, `GitDetailsSheet` deleted. What survives is
  the one-line sidebar git readout; see ES-E4-2. — both
- **ES-E9-4** [E9] GONE — no Files tab, no lazy file tree. — both
- **ES-E9-5** [E9] GONE — no `view.toggleDetails` binding row; `⌘⇧R` was re-taken by the CODE panel. — both

## E10 — Links · Jump-To · status bar · hint mode
- **ES-E10-1** [E10] MAC ONLY — `TerminalViewModel.linkHighlightActive` is "always FALSE on iOS: no ⌘
  modifier … the iOS affordance is tap-on-label / long-press, not ⌘-hold" (`TerminalViewModel.swift:1514-1532`).
  A stated platform-input fact, not an unclosed gap. — GUI-verifiable
- **ES-E10-2** [E10] `⌘click` opens a detected path/URL, `⌘⇧click` reveals/copies, right-click offers Copy-Path / Change-Directory-Here / Open-in; both platforms route through `LinkActionPolicy`. — both (detector unit-testable; gestures GUI)
- **ES-E10-3** [E10] GONE — there is no per-pane status bar on either platform. The removal is a recorded
  USER ruling, carried in the code rather than in `DECISIONS.md`:
  `SlopDeskPhoneUI/Pane/TerminalLeafView.swift:98-102` — "NO per-pane status strip on a TERMINAL pane
  (issue: the user judged the terminal pane footer low-value and asked to drop it) … host + connection status
  now live ONCE in the connection island". Mirrored at `SlopDeskMacUI/Pane/MacTerminalLeafView.swift:6`. The
  exit-code cue moved to the sidebar row's receipt. — both
- **ES-E10-4** [E10] GONE with it — `TerminalViewModel.swift:1543-1545` marks the hover-path seam DORMANT:
  "its only consumer was the per-pane status bar's full-path preview, removed with the status strip". — GUI-verifiable
- **ES-E10-5** [E10] `⌘J` opens the Jump-To surface over the current pane's paths, links and commands,
  filterable by typing — folded into the unified Open-Quickly picker as its `.current` pill, reusing
  `JumpToModel` verbatim. — both
- **ES-E10-6** [E10] `⌘⇧J` overlays 2-letter labels on detected targets; typing a label opens it (host-routed where the host is the Mac); `Esc` cancels. `⌘⇧Y` is the copy variant. — both

## E11 — Open Quickly + Actions popover
- **ES-E11-1** [E11] PARTLY — `⌘⇧O` opens the quick-switcher, defaulting to All. The ring is **six** pills,
  not eight: **All / Opened / Recent / Folders / Agents / Current** (`OpenQuicklyFilter.pickerPills`).
  **SSH** is a deliberate product cut (`DECISIONS.md` §E11 SCOPE CUT, user reduction 2026-06-26) —
  no `~/.ssh/config` parse, no `⌘S` chord, no SSH Actions row. **Recipes** was deferred to E16 and then
  deleted with E16 (2026-07-03, `d63e1274`). `OpenQuicklyModel.swift:12-15` states both structurally:
  "no `ssh` / `recipes` case exists on this enum, so nothing can route to either". — GUI-verifiable
- **ES-E11-2** [E11] `Tab`/`⇧Tab` cycle filters; the Opened filter lists every live pane with fuzzy filtering; `↩` switches to it. — both
- **ES-E11-3** [E11] `⌘K` opens an Actions popover for the highlighted item with context-appropriate actions; `⌘1–9` opens the Nth result directly. iOS reaches the same actions through a trailing ellipsis button per row. — both
- **ES-E11-4** [E11] The Folders filter ranks visited cwds by frecency; the Agents filter lists Claude sessions for the current project (Claude-only). — both

## E12 — Composer + Prompt Queue — GONE, WHOLE
> Removed 2026-07-03 in `92472b0a`, "refactor(prune): agent input surfaces". `DECISIONS.md` §Agent input
> surfaces REMOVED gives the reason: these surfaces "duplicated typing straight into the terminal, which is
> what the user actually does". **KEPT:** `InputBarModel` / `InputBoxModel` / `InputDedupRing` — the per-pane
> ordered-OUT funnel and B1 echo-dedup that every keystroke and Peek & Reply still ride. Agent SUPERVISION is
> untouched: status badges, attention jump (`⌘⇧U`), Peek & Reply (`⌘⌥J`) and its reply delivery all work.

- **ES-E12-1** [E12] GONE — `ComposerModel`, `ComposerBar`, `ComposerTextView`, `requestComposerInActivePane`
  deleted; `⌘⇧E` unbound. — both
- **ES-E12-2** [E12] GONE — no composer, so no draft to preserve; the per-pane pin persistence
  (`SettingsKey.composerMaxHeight` / `composerPinnedPaneIDs`) is deleted. — both
- **ES-E12-3** [E12] GONE — `ComposerPasteboard` / `ComposerPasteHandler` / `RichPasteMarkdown` deleted
  (`RichPasteMarkdown` was composer-paste-only). The `DECISIONS.md` reversal about hosting a real
  `NSTextView` to intercept `⌘V` is now history about a deleted view. — both
- **ES-E12-4** [E12] GONE twice over — the composer went in `92472b0a`, and floating panes went the same day
  in `231f1398` (`DECISIONS.md` §Floating panes REMOVED); the tiled split tree is the only pane layout. — GUI-verifiable
- **ES-E12-5** [E12] GONE — `PromptQueueModel`, `PromptQueueStrip`, `requestPromptQueueInActivePane` deleted;
  `⌘⇧M` and `⌥⌘↩` unbound. The per-TARGET dispatch contract `DECISIONS.md` records for it describes deleted
  code. — both

## E13 — Agent integration UI (Claude Code)
- **ES-E13-1** [E13] The Agents settings card installs/uninstalls Claude Code hooks into the host
  `~/.claude/settings.json` and shows Installed / Not Installed. Both platforms
  (`SettingsBespokePresentation`, `SlopDeskPhoneUI/Settings/AgentSettingsCard.swift`,
  `SlopDeskMacUI/Settings/MacSettingsRows.swift`; the writer is `rust/slopdesk-hook/src/install.rs`). The card
  distinguishes a third state the story did not name — **inactive**: written to `settings.json` with the
  host's listener unbound. — both
- **ES-E13-2** [E13] PARTLY — **two** Agent-Behaviour toggles exist, not seven: Prevent-Sleep and
  Resume-on-Recovery (`AgentPreferences.preventSleep` / `.resumeOnRecovery`, sidecar-borne, applied on
  reconnect). Prevent-Sleep does hold a host `IOPMAssertion` only while an agent processes
  (`PreventSleepAssertion` driven by the `.working` aggregate). The three badge and two notify toggles do not
  exist as preferences. — both
- **ES-E13-3** [E13] When an agent completes or awaits input off-screen a local notification posts and the tab
  badge updates; focusing the tab clears it (`WorkspaceStore.selectTab` clears every pane's agent badge in the
  newly-active tab, and `revealPaneTree` routes through it). — both
- **ES-E13-4** [E13] GONE (2026-07-03, `92472b0a`) — `AgentInputFooterView`/`Coordinator`/`Action` and
  `FileExplorerModel` deleted with their `TerminalLeafView` mount. `InputBarModel.richMode` survives for the
  retained input bar. — GUI-verifiable
- **ES-E13-5** [E13] GONE (same commit) — `SendToChatModel`/`Dialog`, the capture and delivery
  (`captureSendToChatContext`, `sendChatMessage`), the context-menu row and the `action.sendToChat` palette
  row are deleted; `⌘⌃↩` is unbound. — both
- **ES-E13-6** [E13] GONE (2026-07-02, `6de70aae`) — `AgentSessionHistoryView` went with the Details panel;
  there is no transcript renderer, no raw-JSONL toggle and no Resume button. `readAgentSession` is a live RPC
  with no caller. Open Quickly's Agents pill keeps its own direct `claude --resume` injection, which is the
  only surviving piece of the Resume idea. — both
- **ES-E13-7** [E13] GONE (2026-07-03, `92472b0a`) — `ForkSessionDetector`, the fork/branch observation on
  `LivePaneSession`, the three `WorkspaceAction.forkIn*` cases and their palette rows are deleted, as is the
  `AgentResumeRouter` plumbing only they consumed. — both

## E14 — Progress + notifications + privilege
- **ES-E14-1** [E14] A program emitting OSC 9;4 progress drives a spinner/progress badge (wire type 32) instead of being silently filtered; auto-progress wraps known slow commands (host-side, `rust/slopdesk-superd`). — both
- **ES-E14-2** [E14] OSC 9 / 777 / 99 notifications post banners (wire type 25 → `CommandCompletionNotifier`); BEL beeps; the Dock bounces when slopdesk is unfocused per the Notify-While-Foreground policy. — both
- **ES-E14-3** [E14] MAC ONLY — `DockProgressController` is `SlopDeskMacUI`-only and the two keys are marked
  "macOS-only; inert on iOS" (`SettingsKey.swift:592,596`). iOS has no Dock; a platform fact, not a gap. — GUI-verifiable
- **ES-E14-4** [E14] PARTLY — the privilege toggles ship on both (`titleShellControlled`,
  `clipboardShellControlled`, the OSC-52 Ask/Allow/Deny `clipboardAccess` group) and so does the
  system-permission status row. But the toggle is **title-shell-controlled** (may the shell SET the title),
  not the **title-REPORT** / XTWINOPS toggle the story names — that one does not exist in any form. — both

## E15 — Theming + fonts
> The theme system was removed in two steps. 2026-07-03 (`0166057c`) deleted the custom-theme FILE vertical —
> editor, importers, folder scan, TOML parser, `theme import` — leaving built-ins and the Appearance picker.
> 2026-08-08 deleted the rest: `DECISIONS.md` §"ONE appearance — the theme picker is deleted, not defaulted
> (user-directed)". The app now ships exactly one appearance, a cream ground carrying a dark glass, and
> `AppearancePreferences.swift:9-13` states it in the type: "THEME IS GONE (user-directed 2026-08-08) …
> The dual-slot model (`theme` / `themeDark` / `useSeparateDarkTheme` / `themeFonts`) and its `ThemeChoice`
> enum are deleted, not deprecated." Fonts survive; the per-theme font SCOPES did not.

- **ES-E15-1** [E15] GONE (2026-08-08) — `ThemeResolution`, the light/dark slots and the follow-OS resolution
  are deleted. `SlateAppearancePin` pins one appearance instead. — both
- **ES-E15-2** [E15] GONE (2026-07-03, then moot) — `ThemeDocument`, `ThemeTOMLParser`, `ThemeImporters`,
  `ThemeLibrary`, the `~/.config/slopdesk/themes/` scan and the five importers are deleted. There is no
  theme list to add to. — both
- **ES-E15-3** [E15] GONE (2026-07-03) — `ThemeEditorView` (swatch grid, Duplicate / Edit / Open-Folder) and
  `SlateTheme(document:)` deleted. — GUI-verifiable
- **ES-E15-4** [E15] PARTLY — the font-family picker with specimens and the fallback list ship on both
  (`MacFontFamilySurface`, `SlopDeskPhoneUI/Settings/FontSettingsView.swift`, `InstalledFontFamilies`,
  `SettingsFontFallbackList`). The **per-scope Global/Light/Dark overrides are GONE** (2026-08-08:
  `FontScopeResolver` and `TerminalConfigBuilder.fontFamilyOverride` deleted with the theme slots) — one
  global family, plus the Bold/Italic/Bold-Italic family fields, is the whole model. — GUI-verifiable
- **ES-E15-5** [E15] PARTLY — line-height modes, ligature levels, bold/italic style modes and the blending
  modes are all live `TerminalPreferences` fields and reach the libghostty config builder. **Underline and
  blink are not settings**: the only `underline` in the type is a cursor SILHOUETTE case, and the only blink
  key is `cursorBlink`. The old "SGR-blink / underline-off toggle, persisted but not emitted" ceiling no
  longer describes anything in the tree. — both

## E16 — Recipes + snippets — GONE, WHOLE
> Removed 2026-07-03 in `d63e1274`, "refactor(prune): recipes + snippets". `DECISIONS.md` §Recipes + Snippets
> REMOVED lists it: `Recipe`, `RecipeBuilder`, `RecipeTOMLCodec`, `RecipeTrust`, `RecipeReplayMachine`,
> `RecipeLibrary`, the save/open/trust sheets, the replay HUD, `Snippet`, `SnippetAliasExpander`,
> `SnippetEditorSheet`, the `open-recipe` control verb, the `slopdesk open` subcommand and Settings ▸ Recipes
> (taxonomy 9 → 8 sections). `⌘S` and `⌥⌘R` are unbound. **KEPT: `SendKeysParser`** — the tmux-style
> `<Token>` → bytes primitive lived in `Snippet.swift` and backs launch presets, session templates, block
> re-run, drops and the CLI `pane send-keys`; it moved verbatim to `Domain/SendKeysParser.swift`.

- **ES-E16-1** [E16] GONE — no `.slopdeskrecipe` writer, no ⌘S save chord. — both
- **ES-E16-2** [E16] GONE — no restore, no replay modes, no shell-handoff pause (`TerminalViewModel.onPromptReturn`, whose only consumer this was, is deleted too). — both
- **ES-E16-3** [E16] GONE — no trust store, no Always-Trust / Run-Once / Cancel prompt. — both
- **ES-E16-4** [E16] GONE — no snippet model, no alias expansion at the prompt; the ghostty surface's
  bare-Tab/Space expansion branch was unwound with it. — both

## E17 — Read-only + Vi-mode + secure input
- **ES-E17-1** [E17] Toggling Read-Only on a pane shows the `🔒 READ ONLY ×` pill and blocks all input paths (keys/paste/click-to-move/mouse-report/drop) with a beep; output keeps streaming. — both
- **ES-E17-2** [E17] Entering Vi/copy mode shows a pill with the mode and live repeat-count; `⌘/` toggles a key-hint bar. — GUI-verifiable
- **ES-E17-3** [E17] PARTLY — `/` and `?` in Vi mode open the find bar and `n`/`N` step matches; line/block
  selection and yank work. The old char-selection ceiling was LIFTED on 2026-07-14 (`DECISIONS.md`
  §"Copy-mode ceiling LIFTED") once the pinned fork exposed `ghostty_surface_set_selection`.
  The key table is `TerminalViewModel.handleCopyModeKey(_:)`
  (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:769-885`) and it is exactly:
  count digits, `h j k l`, `0 ^ $`, `w b e`, `⌃d ⌃u`, `⌃f ⌃b`, `g G`, `[ ]`, `v V ⌃v o`, `f`, `/ ?`, `n N`,
  `y Y`, `q`. **`H` / `M` / `L` (screen top/middle/bottom) and Mark Mode DO NOT EXIST** — neither is a case
  in that switch, and the hint bar (`SlopDeskClientCore/Pane/ViKeyHintPresentation.swift:91-118`) lists the
  same set, so the two agree. — both
- **ES-E17-4** [E17] MAC ONLY — the host-side hidden-password DETECTION is cross-platform (wire type 31
  `inputEcho`), but the client actuator is macOS by physics: "secure event input is a macOS-only concept, so
  the whole type compiles for iOS and simply never engages there"
  (`SecureKeyboardEntryController.swift:16-19`). The SECURE-INPUT pill therefore never lights on iOS. — both

## E18 — Drag-drop + tab reorder + web pane
- **ES-E18-1** [E18] Dragging a file over a pane shows New-Tab / Insert-Path / Open-In-Place / Split-Left / Split-Right zones; the hovered zone highlights. Both platforms (`MacPaneDropOverlay` / `PaneDropOverlay` over the shared `PaneDropZoneLayout`). — GUI-verifiable
- **ES-E18-2** [E18] Dropping on Insert-Path injects the path into the terminal; dropping a folder on New-Tab
  `cd`s to it (`DropAction.newTabCd`, actuated by `PaneDropActuator`) with a host-resolved-path toast. Note a
  narrowing: a dragged **URL** now only pastes — `DropAction.openWeb`/`.splitWeb` went with the web pane. — both
- **ES-E18-3** [E18] GONE (2026-07-10, with the grouping/sort machinery) — sidebar rows are not
  drag-reorderable; `TabOrdering.swift:6-9` names "manual drag-reorder" among the deleted things, and rows
  follow creation order. What survives on macOS is `PaneDragCoordinator`, which drags a PANE to another tab
  or out to a satellite window — a different verb, and macOS-only by its own note ("a platform with one
  window and no cursor leaves this nil"). — both
- **ES-E18-4** [E18] GONE (2026-07-02, `65da3c0d`; `DECISIONS.md` §Web pane REMOVED) — `PaneKind.web`,
  `PaneSpec.webURL`, `WebLeafView`, the whole `WebPaneSeam`, `WebURLNormalizer` and the WebKit link in both
  xcodegen specs are deleted; a persisted `"web"` kind decodes to `.terminal`. (The embedded WKWebView that
  DOES ship is the CODE panel, 2026-08-02 — a different feature with a different lifecycle.) — GUI-verifiable

## E19 — Window options
- **ES-E19-1** [E19] MAC ONLY — View → Pin Window keeps the window floating above other apps
  (`WorkspaceChromeState.pinned` → `NSWindow.level = .floating`). Chord-less by default. The registry states
  the reason in place: "iOS has no window level (documented no-op)"
  (`WorkspaceBindingRegistry.swift:115-118`). A platform fact, not a gap. — GUI-verifiable
- **ES-E19-2** [E19] MAC ONLY — window-size = grid / frame / remember all work
  (`SlopDeskMacApp+Window.swift`, `SettingsKey.windowSize`/`.windowCols`). iOS has no resizable app window;
  the keys round-trip there and do nothing. — both
- **ES-E19-3** [E19] GONE (2026-07-02, `d1d4398b`; `DECISIONS.md` §Multi-session switcher UI REMOVED) —
  `SessionSwitcherView` and `SessionRowModel` deleted, both mounts removed, `WorkspaceAction.newSession`
  (⌃⌘N) and the whole `Category.sessions` menu section gone. The workspace is single-session at the UI.
  **KEPT:** the `Session` domain type and the store's multi-session internals, which the control backend,
  session templates and persistence restore still use. — both
- **ES-E19-4** [E19] PARTLY, MAC ONLY — there is no user-choosable top/bottom tab-bar LAYOUT. What exists is
  `MacTabStrip`: the tabs laid horizontally in the titlebar band, shown when the sidebar is collapsed, from
  the same rows and sectioning as the sidebar. `auto-hide-tabs-panel`
  (`SettingsKey.autoHideTabsPanel`, `default`/`always`/`auto`) is real and cross-platform, but it hides the
  vertical SIDEBAR, not a horizontal bar. iOS has no tab strip. — GUI-verifiable

## E20 — CLI parity + watch + first-launch
> Verified against `rust/slopdesk-cli/src/vocabulary.rs`. Ready verbs: `version, completions, sidecars, help,
> window(s), tab(s), pane(s), config, font, keybind, jump, learn, ignore, watch:claude, view, edit, watch`.
> Planned verbs — NOT YET IMPLEMENTED (7, never completion-offered): `open, import, export, features,
> state:claude, ipc, theme`. Each parses and exits 2; none is offered in completions.

- **ES-E20-1** [E20] PARTLY — `slopdesk view/edit/config/font/keybind/tab/pane/window` drive the running app.
  `--json` is accepted position-independently (`rust/slopdesk-cli/src/args.rs:43,192-197`), but "produces
  structured output" is only true of the ROW-producing verbs: one shared `render()`
  (`rust/slopdesk-cli/src/formatting.rs:113-125`) serves exactly six formatters — `windows`, `tabs`,
  `panes`, `font list`, `keybind list`, `config show`. Action verbs emit no rows, so there is nothing for
  `--json` to format and it is inert on them. Trap: after `-e` or `--`, option parsing has stopped and a
  trailing `--json` is captured as a payload argument, not honoured (`args.rs:375-380,395`). — both
- **ES-E20-2** [E20] `slopdesk watch <cmd>` shows a spinner during execution and a success/error badge on exit (exit codes 0/4/9 for `watch:claude`). — both
- **ES-E20-3** [E20] `slopdesk tab badge --kind <kind>`, `pane capture`, `jump/learn/ignore`, `version`, and `completions <shell>` behave per the CLI reference. — both
- **ES-E20-4** [E20] first-run: set On-Launch behavior, install the CLI, and install Claude Code hooks from a
  first-launch flow. `FirstLaunchStep` = `onLaunch` · `defaultTerminal` (macOS-only) · `installCLI`
  (macOS-only) · `installClaudeHooks`; iOS keeps the two cross-platform steps, which is correct — there is no
  CLI to install on iOS. — GUI-verifiable
- **ES-E20-5** [E20] NOT YET IMPLEMENTED — `open`, `import`, `export`, `features`, `state:claude`, `ipc` are
  `Availability::Planned`: `--help` lists them under "Designed, NOT yet implemented", no shell completes them,
  and typing one exits 2 as planned-not-misspelled. (`open` is planned in the table but the recipe it opened
  was deleted in E16 — the row is now a design placeholder, not a pending port.) — both
- **ES-E20-6** [E20] PARTLY — `theme list` / `theme import` ARE `Availability::Planned` like their six
  siblings, and that half is correct: the verb was absent from the table until 2026-08-22, which made it the
  one designed verb the CLI called a typo. **The rest of the row is false.** It claimed switching the active
  theme "ships today under the theme key" of the settings verb; the `theme` config key and the built-in
  catalogue were deleted on 2026-08-08 with the theme picker, so `config set theme <name>` has nothing to
  set. Switching the active theme is therefore NOT YET IMPLEMENTED, and cannot be until a theme surface
  exists to switch. The same false claim used to be repeated inside `vocabulary.rs` (the comment at the
  `theme` entry, and "Already ships in the app" on both `import` forms); all three were corrected on
  2026-08-22, so the code and this row now agree. The row also cited
  ES-E20-2 for the settings verb; `config` is ES-E20-1. — both

## E21 — Remote-window extension — GONE, WHOLE
> Removed 2026-07-22. `DECISIONS.md` §"Remote desktop is a DEDICATED OS WINDOW — remote-window mode is
> REMOVED" reverses the 2026-07-14 "per-window streaming survives as a SECONDARY path" ruling and deletes
> `PaneKind.remoteGUI` outright. Full-desktop is the only remote-viewing mode, and it always opens as its own
> OS window, never as a pane or tab inside the workspace. `PaneKind` now has exactly two cases, `.terminal`
> and `.desktop`; a persisted `"remoteGUI"` leaf folds to `.terminal`. The WIRE is untouched — the
> window-shaped types (`resizeAck`, `listWindows`/`windowList`, `displayMax`, the geometry datagrams) go
> DORMANT rather than deleted, so the golden corpus is byte-identical.

- **ES-E21-1** [E21] GONE — `RemoteWindowPickerModal`/`View`, `newRemoteWindowTab`, `openRemoteWindow` deleted; the connect-to-host overlay survives on its own (see ES-E2-6). — GUI-verifiable
- **ES-E21-2** [E21] GONE — no `.remoteGUI` case to appear in palette/Open-Quickly/sidebar/status-bar results; Open Quickly's Host rows are deleted (their only action was opening a window pane). — both
- **ES-E21-3** [E21] GONE twice — floating panes went 2026-07-03, and the desktop stream is now a satellite OS window that is never in the tree. — GUI-verifiable
- **ES-E21-4** [E21] (dev) GONE — the peer-status invariant and its `RemoteGUIFirstClassPeerTests` describe a
  `PaneKind` case that no longer exists. — unit-testable
