# Otty → Aislopdesk Gap Analysis

Feature-by-feature matrix for cloning the Otty terminal 1:1 (UI + behavior) inside the aislopdesk client, then extending it (the user's own feature being **remote window**).

**Out of scope** (per directive): the Workflows section; non-Claude agents (Codex / OpenCode). Where Otty's spec mixes agent-generic and Claude-specific behavior, only the Claude Code path is in scope.

**Status legend**
- **done** — fully implemented & wired in aislopdesk today.
- **partial** — domain/engine/data exists but the view or a wiring step is missing (the most common state — aislopdesk has built most engines, the gap is the rendered surface + one mount).
- **missing** — no implementation.
- **na-remote** — Otty behavior cannot map 1:1 onto the remote-host architecture; the cell records the closest faithful equivalent to build instead, or notes why it is dropped.

**Sources.** Otty behavior cites the spec file under `docs/otty-clone/spec/`. Current state cites the capability map under `docs/otty-clone/current-state/` and the evidence symbols therein.

**Priority** 1 (highest) … 5 (lowest). P1 = foundational/blocking & high user value; P2 = core clone surface; P3 = secondary clone surface; P4 = polish / lower-value; P5 = nice-to-have or deep-host-dependency.

---

## A. Window, Tab & Split — `spec/user-interface__window-tab-split.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| A1 | Window → Tab → Pane hierarchy | **done** — `TreeWorkspace`/`Session`/`Tab`/`SplitNode` (`workspace-domain.md`) | none | — |
| A2 | New tab `⌘T` | **done** — `openChooserPane(.newTab)` (`ui-shell.md`) | none | — |
| A3 | Close focused pane→tab→window cascade `⌘W` | **done** — `closeActiveTab`/`closePaneTree` with cascade in `WorkspaceTreeOps` | confirm window-close terminal step on last tab | 3 |
| A4 | Reopen last closed tab `⇧⌘T` (LIFO stack) | **partial** — `reopenClosedPane()` is **canvas-only; dead on the tree path**; no `.reopenClosedPane` case in `routeTree` | build a tree-path reopen stack + routing case | 2 |
| A5 | Next/prev tab `⌘⇧]` / `⌘⇧[` | **done** — `cycleTab(by:)` | none | — |
| A6 | Go to tab 1–9 `⌘1`–`⌘9` | **done** — `selectTabNumber` + `selectTabBindings` | none | — |
| A7 | Split right/left/down/up `⌘D`/`⌘⌥D`/`⌘⇧D`/`⌘⌥⇧D` | **partial** — horizontal (`⌘D`) & vertical (`⌘⇧D`) done; **left/up variants** not registered | add split-left/split-up directional bindings | 3 |
| A8 | Resize divider (drag) + keyboard nudge `⌘⌃⇧arrow` | **done** — `PaneDivider` live-resize; `resizeActivePane` keyboard (aislopdesk uses `⌥⌘arrow`) | reconcile chord to otty's `⌘⌃⇧arrow` (or document divergence) | 4 |
| A9 | Equalize splits (dbl-click divider / `⌘⌃=`) | **done** — `balanceActivePaneSplits` (aislopdesk `⌥⌘=`) | reconcile chord to `⌘⌃=` | 4 |
| A10 | Focus next/prev pane `⌘]` / `⌘[` (sequential cycle) | **missing** — directional focus exists; no sequential cycle action | add `cyclePaneFocus(next/prev)` action + bindings | 2 |
| A11 | Directional focus `⌘⌃arrow` | **done** — `moveFocusTreeUsingReportedLayout` (aislopdesk `⌥⌘arrow`) | reconcile chord | 4 |
| A12 | Vertical sidebar tab list (default layout) | **done** — `NavigatorColumn` + `OttyTabRow` | none | — |
| A13 | Horizontal tab bar (top/bottom layout option) | **missing** — only vertical sidebar exists | add a horizontal tab-bar layout + `layout` setting | 4 |
| A14 | Active tab = white rounded card; `#N` shortcut badge; shell name | **partial** — white-card active row done; `#N` number & shell-name trailing label not shown | add number badge + process/shell trailing label to row | 3 |
| A15 | Tab grouping (None / By Project / By Date) | **missing** — sort hamburger is **presentational only** | implement grouping (git-toplevel for project, activity time for date) | 4 |
| A16 | Tab sort (Created / Updated / Manual drag) | **missing** — rows are in insertion order; hamburger no-op | add `createdAt`/`updatedAt` + sort modes + manual drag-reorder | 4 |
| A17 | New-tab position (`auto`/`end`/`after-current`) | **missing** — `newTab` always `tabs.append` | add `newTabPosition` setting + insert-after-active path | 3 |
| A18 | Sidebar auto-hide (`default`/`always`/`auto`) | **partial** — sidebar collapse `⌘⇧L` done; no single-tab auto-hide policy | add `auto-hide-tabs-panel` policy on tab-count change | 4 |
| A19 | Rename tab — Name vs Prefix mode + reset (↺) | **partial** — spec side-table supports `fixedName`; no rename dialog UI; OSC-0/2 title done | build rename popover (Name/Prefix segmented + reset) | 3 |
| A20 | Tab badges (spinner/check/dot/error/hand/coffee/shield/SSH) | **partial** — `RailRow.status: ClaudeStatus` computed but **never rendered**; agent states only | render badge dot on `OttyTabRow`; add command/caffeinate/sudo badge sources | 2 |
| A21 | Jump to unread/changed tab `⌘⇧U` | **done** — `jumpToOldestAttentionPane` (`claude-agent.md`) | none | — |
| A22 | Toggle tabs sidebar `⌘⇧L` | **done** — `WorkspaceChromeState` | none | — |
| A23 | Toggle details panel `⌘⇧R` | **done** — inspector collapse | none | — |
| A24 | Drag-drop pane rearrange (split/swap/dock zones) | **done** — `SplitContainer.resolveZone` swap/resplit/dock + `PaneMoveOverlay` | none | — |
| A25 | Zoom/maximize active pane `⌘⇧↩` | **done** — `toggleZoomActivePane` | reconcile chord (aislopdesk `⌥⌘↩`) | 4 |
| A26 | Working-directory inheritance for new window/tab/split | **missing** — `newTab`/`splitActivePane` never read active pane `lastKnownCwd`; OSC 7 not piped into `lastKnownCwd` | wire OSC 7 → `lastKnownCwd`; add `working-directory` (inherit/home/path) policy | 2 |
| A27 | Close confirmation (Closing Tab / Window: process/always/multiple_tabs) | **partial** — busy-shell close guard done; no per-target `process/always/multiple_tabs` policy or settings | add close-confirm policy enum + settings | 3 |
| A28 | Save layout as Recipe `⌘S` (scope/content levels) | **partial** — `saveLayoutPreset` is **canvas-only**; `SessionTemplate` is a different abstraction | build tree-path Recipe save/restore subsystem | 3 |
| A29 | Window size (`remember`/`grid`/`frame`, cols/rows/px) | **partial** — window restore behavior exists; no `window-size` mode setting | add `window-size` setting + grid/frame sizing | 4 |
| A30 | Pin window / always-on-top (View → Pin Window) | **missing** — no `NSWindow.level = .floating` path | add pin-window toggle (macOS) | 4 |
| A31 | Picture-in-Picture (Current Pane / Follow Active) | **na-remote** — pane is a UDP HEVC stream, not a PiP layer | substitute: always-on-top window for the active pane (P4); true PiP deferred | 5 |
| A32 | Multi-session UI (session list / switcher) | **partial** — `sessions: [Session]` + ops exist; `NavigatorColumn` renders only active session | add a session list / switcher in the sidebar | 3 |
| A33 | `otty watch <CMD>` badge driver | **missing** | host-side `aislopdesk watch` wrapper emitting OSC 9;4 + badge | 4 |

---

## B. Details Panel (Inspector) — `spec/user-interface__details-panel.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| B1 | Right docked panel, toggle `⌘⇧R`, hover titlebar button | **done** — inspector column + collapse | none | — |
| B2 | Four tabs: Info / Outline / Git / Files (click + bindable) | **partial** — 3-tab header Info/Git/Files done; **no Outline tab**; `Details: *` jump commands missing | add Outline tab; register 4 bindable `Details: *` actions | 3 |
| B3 | Info tab: cwd, process list (name/PID/uptime), ports, open-in actions | **partial** — cwd, agent, command history done; **process list, ports** missing (host data); open-in = Copy Path only | host control-channel RPC for processes + listening ports; client renders | 3 |
| B4 | Outline tab: command marks / agent prompts / file ToC | **missing** — no Outline view (`BlockHistoryView` is command-block only) | build Outline tab from OSC-133 marks + agent prompt blocks | 3 |
| B5 | Git tab: branch/remote/ahead-behind, changed files, inline diff | **partial** — Git tab renders empty state | host `git status/branch/log/diff` RPC; client diff renderer (read-only first) | 3 |
| B6 | Files tab: file tree rooted at cwd + search field | **partial** — Files tab renders empty state | host `listDirectory(path:)` lazy RPC; client tree + filter | 3 |
| B7 | Info: Reveal in Finder / Open in VS Code/Cursor/Xcode | **na-remote** — remote path; client Finder cannot reveal host path | substitute: Copy Path + "open on host" (`open -R` over PTY) where host is the Mac | 4 |
| B8 | Info (agent): Copy Session ID / View History / Fork in… | **partial** — agent metadata exists; history/fork unbuilt | wire to Claude session metadata + history viewer + fork routing (see G) | 4 |
| B9 | iOS: panel becomes modal sheet / drawer | **missing** — iOS inspector adaptation | add iOS sheet form of inspector | 4 |

---

## C. Status Bar — `spec/user-interface__status-bar.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| C1 | Persistent status strip (cwd / process / git / last exit) — *Otty itself unimplemented* | **missing** — no bottom status bar; `hideStatusBar` key exists with no UI | build a thin bottom strip: cwd (OSC 7), last exit (OSC 133 D), pane kind, host; honour `hideStatusBar` | 3 |
| C2 | Full-path hover preview in bottom-left status area | **missing** — paired with link detection (see D) | render resolved path in status strip on ⌘-hover | 3 |

---

## D. Files, Folders & Links — `spec/user-interface__files-and-links.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| D1 | Path/URL detection in output (abs/tilde/rel/`:line:col`/url/`file://`) | **missing** — no client path-scan overlay | build client-side path/URL detector over the cell grid | 2 |
| D2 | OSC 8 hyperlinks (always underlined, click-to-open) | **done** — libghostty owns hit-test; `GHOSTTY_ACTION_OPEN_URL` → open | none | — |
| D3 | ⌘-hold underline highlight of detected links | **missing** | render underline decoration overlay while ⌘ held | 3 |
| D4 | ⌘click open / ⌘⇧click reveal/copy / right-click menu | **partial** — right-click menu exists (copy/paste/split/find); no path-aware items | add path-aware ⌘click/⌘⇧click + "Change Directory Here"/"Open in" menu items | 3 |
| D5 | Jump To `⌘J` (paths/links/commands in current pane) | **missing** — no `⌘J` jump-to panel | build Jump-To panel (reuse FuzzyMatcher) scanning current pane | 3 |
| D6 | File pane / editor (syntect, ~120 grammars, save/reload, source⇄preview) | **na-remote** — no local file editor; remote files need a transfer sub-protocol | defer; a client-local file/markdown viewer pane is the closest faithful subset (P4) | 5 |
| D7 | Markdown/SVG/HTML live preview (`⌘E` toggle) | **na-remote** — depends on D6 | defer with D6; markdown preview is the cheapest subset | 5 |
| D8 | Folder pane (directory browser) | **na-remote** — host FS; needs `listDirectory` RPC (shares B6) | reuse B6 file-tree as a pane kind | 4 |
| D9 | Web browser pane (WKWebView) | **missing** — fully client-local, feasible | add `PaneKind.web` hosting WKWebView (non-persistent store) | 4 |
| D10 | Agent session history rendered as transcript | **missing** — see G6 | covered by History viewer epic | 3 |
| D11 | Open With / Link Schemes settings | **missing** | add Controls→Open With + Link Schemes settings | 4 |
| D12 | `link-cmd-click` / `link-cmd-shift-click` / `link-detection` config | **missing** | add link config keys to PreferencesStore | 4 |

---

## E. Drag and Drop — `spec/user-interface__drag-and-drop.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| E1 | Pane drag rearrange (split/swap/dock/tab/tear-off) | **done** (intra-window) — `SplitContainer` zones + `PaneMoveOverlay` | tear-off into NEW window deferred (single-window) | 3 |
| E2 | Tab reorder via drag (insertion-line indicator) | **missing** — no sidebar drag reorder | add manual tab reorder (ties to A16) | 4 |
| E3 | Double-click divider to equalize | **done** — `PaneDivider` dbl-click | none | — |
| E4 | External file/folder/URL drop → New Tab / Insert Path / Open In-Place / Split L/R zones | **missing** — no external drop overlay | add `NSDraggingDestination` overlay with circular zones; route Insert Path (PTY inject) + Split | 3 |
| E5 | Text snippet drop into terminal | **missing** | accept `NSStringPboardType` → PTY inject | 4 |
| E6 | "New tab rooted at dragged folder" (cwd=folder) | **na-remote** — cwd is host-side; client path may not exist on host | substitute: `cd <path>` injected; warn path is host-resolved | 4 |
| E7 | Cross-window drag / merge | **na-remote** — single-window store; deferred with E1 tear-off | defer | 5 |

---

## F. Find — `spec/user-interface__find.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| F1 | In-pane find bar `⌘F` (live highlight, N of M) | **partial** — `TerminalSearchController` engine + `onRequestFind` seam done; **no `TerminalFindBar` view**, callback never assigned | build `TerminalFindBar` overlay; assign `onRequestFind` from leaf view | 1 |
| F2 | Next/prev `↩`/`⌘G`, `⇧↩`/`⇧⌘G`; `Esc` close | **partial** — engine has next/prev/wrap; needs find-bar wiring | wire keys into find bar | 2 |
| F3 | `Aa` case + `.*` regex toggles | **done (engine)** — needs toggle UI in find bar | add toggles to find-bar view | 2 |
| F4 | In-buffer highlight sync (current vs others, amber) | **partial** — libghostty `start_search` highlights; client count from text mirror can drift | reconcile highlight source or accept documented drift | 3 |
| F5 | Global Search `⇧⌘F` across all tabs → results pane | **missing** | build global search over per-pane scrollback mirrors → results pane | 3 |

---

## G. Open Quickly / Command Palette / Outline / Jump-To — `spec/user-interface__{open-quickly,command-palette,outline}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| G1 | Command Palette `⌘⇧P` (sections, keycaps, ✓ toggle, ⌘↩ chain) | **partial** — `PaletteModel`/`SearchMixer`/`ActionsPaletteSource` done; **no PaletteView; OverlayCoordinator not mounted; ⌘K dispatch is nil no-op** | build PaletteView; mount OverlayCoordinator; pass `togglePalette` closure | 1 |
| G2 | Palette CWD context badge (folder + path) | **partial** — needs cwd from OSC 7 cache | render cwd badge from cached OSC 7 | 3 |
| G3 | Palette ✓ toggled-state + submenu `›` | **missing** — flat dispatch only | add toggle-state queries + submenu nav | 4 |
| G4 | Open Quickly `⌘⇧O` (All/Opened/Recent/Folders/SSH/Agents/Current/Recipes) | **missing** — no `⌘⇧O` binding; `TabsPaletteSource` covers Opened only | add `⌘⇧O` opening palette with filter pills (Opened first; SSH/Agents/Recipes incremental) | 2 |
| G5 | Open Quickly Actions popover `⌘K`; `⌘1–9` quick-pick | **missing** | add per-item actions popover + index quick-pick | 4 |
| G6 | Jump To `⌘J` / Open Quickly "Current" (commands/links/outline) | **missing** — block-navigator seam exists; no overlay | build Jump-To/Current filter from OSC-133 block index | 3 |
| G7 | Outline (per-pane command index, exit-status gutter) | **partial** — OSC-133 blocks parsed; no outline view (shares B4) | render outline rows w/ green/red/grey gutter | 3 |
| G8 | Command Navigator `⌃⌘O` (block search overlay) | **partial** — `onRequestBlockNavigator` seam never assigned; no overlay | build block-navigator overlay | 3 |
| G9 | Cheat Sheet `⌘/` | **partial** — `cheatSheetVisible` state + data exist; **no CheatSheetView; closure nil** | build CheatSheetView; pass `toggleCheatSheet` closure | 2 |
| G10 | SSH filter (parse `~/.ssh/config`) | **partial** — local parse on macOS; iOS must source from host | add SSH source; iOS reads host config over channel | 4 |
| G11 | Folders filter (frecency DB) | **missing** | add a frecency store of visited cwds | 4 |
| G12 | Outline for file panes (markdown ToC etc.) | **na-remote** — no file pane (D6) | defer with D6 | 5 |

---

## H. Cursor & Mouse — `spec/terminal-features__cursor-and-mouse.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| H1 | Cursor style (block/hollow/bar/underline), DECSCUSR override | **done** — `cursor-style` via `TerminalConfigBuilder` | confirm hollow-block option exposed | 4 |
| H2 | Cursor blink (Default/On/Off) | **done** — `cursor-style-blink` | none | — |
| H3 | Cursor animation (Off/Smooth glide+overshoot) | **missing** — no smooth-cursor interpolator | add client Core-Animation glide (or document as omitted) | 5 |
| H4 | Cursor color / text-under-cursor / opacity | **partial** — color via theme; opacity may not be exposed by libghostty | expose color settings; verify opacity field | 4 |
| H5 | Settings cursor live-preview | **missing** | add live-preview box in Appearance→Cursor settings | 4 |
| H6 | Mouse Over to Focus | **missing** — focus is click-only | add `NSTrackingArea` hover-to-focus + setting | 4 |
| H7 | Right-Click Action (Context Menu/Copy/Paste/Copy-or-Paste/Ignore) | **partial** — context menu done; no configurable action | add right-click-action setting | 4 |
| H8 | ⌃+right-click always opens menu | **partial** — needs modifier gate | add ⌃ override | 4 |
| H9 | Hide Mouse When Typing | **missing** | `NSCursor.setHiddenUntilMouseMoves(true)` on keyDown + setting | 4 |
| H10 | Allow Shift with Mouse Click (bypass capture) | **partial** — `mouseCaptured` gating exists; ⇧ bypass not explicit | add ⇧-drag bypass when captured | 4 |
| H11 | Cursor Click-to-Move | **missing** | synthesize arrow keys from click delta (cross-wrap) | 5 |
| H12 | Allow Mouse Capture toggle | **partial** — capture works; no runtime toggle | add toggle | 4 |
| H13 | Mouse reporting modes (1000/1002/1003/SGR 1006) | **done** — libghostty owns | none | — |
| H14 | OSC 22 pointer shape | **missing** — not mapped to `NSCursor` | map CSS cursor names → `NSCursor` | 4 |

---

## I. Selection / Copy-Paste / Scroll / Input — `spec/terminal-features__{selection,copy-and-paste,scroll,input}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| I1 | Word/line/drag/rect selection; ⇧-click extend | **done** — libghostty selection | none | — |
| I2 | ⇧+arrow native selection (extend char/line) | **partial** — not intercepted client-side | intercept ⇧+arrow before PTY (gated by setting) | 3 |
| I3 | Copy `⌘C` / Cut `⌘X` / Select-All | **done** — binding actions wired | none | — |
| I4 | Copy on Select | **missing** | hook selection-change → pasteboard (setting) | 3 |
| I5 | Clipboard Trim Trailing Spaces | **missing** | post-process copy string | 4 |
| I6 | Clear Selection on Typing / on Copy | **missing** | hook keyDown / post-copy clears (settings) | 4 |
| I7 | Backspace Deletes Selection | **missing** — needs OSC-133 prompt-zone detection | gate on prompt zone; delete selection | 4 |
| I8 | Paste (bracketed `?2004`) + Paste as Keystrokes | **done** — libghostty + `pasteAsKeystrokes` | none | — |
| I9 | Paste Protection (multi-line/newline/sudo/ctrl warning) | **missing** | inspect paste string → confirm sheet (setting) | 3 |
| I10 | Paste as… (Selection / File-base64 / Escaped / Bracketed / →Composer) | **missing** | add Paste-as submenu transforms | 4 |
| I11 | OSC 52 read/write + Ask/Allow/Deny policy | **partial** — read/write auto-approved; no Ask/Allow/Deny gate | add per-direction permission policy + Ask dialog | 3 |
| I12 | Scroll keys (`⇧PageUp/Down`, `⇧Home/End`) | **partial** — scroll-to-top/bottom actions exist; page/home/end keys not bound | bind page/home/end scroll keys | 3 |
| I13 | Auto-snap to bottom on output/typing | **done** — libghostty default | none | — |
| I14 | Smooth Scroll (pixel during gesture, snap on end) | **partial** — libghostty scroll; pixel-granular snap not explicit | verify/add pixel scroll + row snap (setting) | 4 |
| I15 | Scroll Past Last/First Line (overscroll modes) | **missing** | client scroll-position overscroll arithmetic; suppress on alt-screen | 4 |
| I16 | Command-jump scroll `⌘PageUp/Down` | **done (engine)** — OSC-133 prompt jump wired | bind `⌘PageUp/Down` to jump | 3 |
| I17 | Natural text-editing chords (⌘←/→, ⌥←/→, ⌘/⌥ delete, ⌘↑/↓) | **partial** — libghostty handles many; not all explicitly intercepted/rebindable | ensure full Text-Editing chord set + rebindable | 3 |
| I18 | Undo/Redo at prompt `⌘Z`/`⌘⇧Z` (coalesced) | **missing** | emit readline undo seq client-side | 4 |
| I19 | IME / CJK (macOS + iOS) | **done** | none | — |
| I20 | Kitty keyboard protocol | **done** | none | — |
| I21 | Option-as-Alt / Shift-Arrow-Select / App-Keypad settings | **partial** — input encoding exists; settings toggles missing | add Controls input toggles | 4 |
| I22 | Secure Keyboard Entry (auto on no-echo + manual + pill) | **missing** — no `EnableSecureEventInput`/pill | host signals no-echo; client `EnableSecureEventInput` + title pill | 3 |
| I23 | Composer `⌘⇧E` (multi-line, rich paste, draft, pin, float, queue) | **partial** — `InputBar`/`InputBarModel`/`InputBoxModel` exist but **not mounted**; no draft/pin/float/⌘⇧E binding | mount composer; add ⌘⇧E, draft persistence, pin, float panel | 2 |
| I24 | Prompt Queue `⌘⇧M` (queue strip chips, idle dispatch) | **missing** — OSC-133 idle seam exists; no `PromptQueueStore`/strip | build prompt queue (see G/agents) | 3 |
| I25 | Services menu / Insert from device (Continuity) | **na-remote** — file lands on client, shell is remote | defer (needs file-transfer sub-protocol) | 5 |

---

## J. Unicode / Box-Drawing / Images / Text-Styles — `spec/terminal-features__{unicode-and-text-styles,box-drawing,images}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| J1 | Full Unicode, combining, wide CJK, BiDi, emoji ZWJ/VS/skin-tone | **done** — libghostty | none | — |
| J2 | SGR styles (bold/italic/dim/underline×5/blink/strike/reverse) + SGR 58 underline color | **done** — libghostty | none | — |
| J3 | True/256/16-color | **done** | none | — |
| J4 | Programming ligatures (calt/dlig levels) | **partial** — libghostty supports; not exposed as setting | add `font-ligatures` setting via config builder | 4 |
| J5 | Nerd Font PUA glyphs + custom fallback | **partial** — libghostty embeds; fallback setting missing | add `font-family-fallback` setting | 4 |
| J6 | Synthetic bold/italic, underline/blink render modes | **partial** — libghostty supports; settings missing | add Appearance→Text mode settings | 4 |
| J7 | East-Asian-Ambiguous block width | **partial** — coarse libghostty option only | add coarse "widen ambiguous" toggle (document fidelity gap) | 5 |
| J8 | Box-drawing/block/braille/powerline analytical render | **done** — libghostty (Ghostty quality) | none | — |
| J9 | Arrow/triangle stem-join to box rules | **na-remote** — not a libghostty feature; would require ghostty patch | omit; settings stub default-on no-op (document) | 5 |
| J10 | Inline images (OSC 1337 / Kitty graphics) | **done** — libghostty renders host-emitted protocol; client is pixel consumer | none | — |
| J11 | Sixel (planned in Otty) | **done** — libghostty renders if emitted | none | — |

---

## K. Progress / Notifications / Privilege — `spec/terminal-features__{progress-state,notifications}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| K1 | OSC 9;4 progress state (clear/in-progress/error/indeterminate) | **missing (by design)** — `HostOutputSniffer` filters 9;4 | replace filter with a wire message + client consumer (spinner/badge) | 3 |
| K2 | Auto-progress for known slow commands (curl/git/npm…) | **missing** | host-side prefix-list auto-emit OSC 9;4 + setting | 4 |
| K3 | Command badges (finished/error/awaiting via OSC 133 D) | **partial** — exit code parsed; not rendered as tab badge | drive A20 badge from OSC-133 D + agent state | 2 |
| K4 | Caffeinate / Sudo badges | **missing** — needs host process inspection | host detects caffeinate/sudo child → badge | 4 |
| K5 | Dock icon animate-progress / red-on-error | **missing (macOS)** | `NSDockTile` progress + error tint | 4 |
| K6 | OSC 9 / 777 / 99 → macOS notification | **done (9/777)** — `HostOutputSniffer` → `UNUserNotificationCenter`; **OSC 99 not parsed** | add OSC 99 structured parse | 4 |
| K7 | BEL → beep; suppress visual bell | **done** — `WireMessage.bell` | client beep wiring confirm | 4 |
| K8 | Bounce Dock Icon on notification | **missing** | `requestUserAttention` | 4 |
| K9 | Notify While Foreground (off/always/tab-unfocused) | **missing** | client policy + setting | 4 |
| K10 | Notify on Finish/Error/Watch-Finish (OSC 133) | **partial** — long-command notif done; finish/error policy missing | add OSC-133-D-driven notify toggles | 4 |
| K11 | Title set OSC 0/2 / Title Report OSC 21 / privilege toggles | **partial** — OSC 0/2 done; Title Report + privilege toggles missing | add title-report + privilege settings | 4 |
| K12 | System-Permission status row + Open System Settings | **missing** | query `UNUserNotificationCenter` settings + deep-link | 5 |
| K13 | IPC Allow Send-Keys / Sensitive-Sessions | **na-remote** — different threat model; map to host agent-control guards | host-side ctl-socket guards + setting | 5 |

---

## L. Vi Mode / Hint Mode / Read-Only / Shell-Integration / $TERM — `spec/terminal-features__{vi-mode,hint-mode,read-only-mode,shell-integration,term-value}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| L1 | Copy-mode (vi-like scrollback nav) `⌃⇧Space` | **partial** — `isCopyMode` + motions done; entry chord/pill differ | add Vi-Mode pill + repeat-count + entry binding | 3 |
| L2 | Vi visual char/line/block selection + yank | **missing** — documented libghostty C-API ceiling (no programmatic set-selection) | line/block via existing selection; char-selection blocked (document) | 4 |
| L3 | Vi search `/`?`, `n`/`N` | **partial** — shares find engine | wire `/`/`?` into copy-mode → find bar | 4 |
| L4 | Vi Mode pill + key-hint bar `⌘/` | **missing** | build pill + hint bar overlay | 4 |
| L5 | Hint Mode (2-letter label overlay) `⌘⇧J`/`⌘⇧Y`/`⌘⇧R` | **missing** | build hint overlay scanning detected links (ties to D1) | 3 |
| L6 | Hint open file path / reveal-in-Finder | **na-remote** — host path; route over control channel | open/reveal via host command; iOS suppress reveal | 4 |
| L7 | Read-only mode (per-pane input gate + pill + beep) | **missing** — `GHOSTTY_READONLY` enum unused | client input gate (`isReadOnly`) + pill + beep | 3 |
| L8 | Shell integration OSC 133 A/B/C/D + OSC 7 | **done** — host sniffer + client tracker | wire OSC 7 → `lastKnownCwd` (see A26) | 2 |
| L9 | Shell-integration script injection (zsh ZDOTDIR / fish / bash / tmux) | **partial** — host spawns PTY; otty-style auto-inject scripts not shipped | host daemon ships integration scripts + injects env | 3 |
| L10 | SSH wrapper (terminfo forward) / `edit`/`view`/`jump`/`learn` wrappers | **na-remote / partial** — host-side; deferred | defer SSH wrapper; ctl wrappers low-pri | 5 |
| L11 | `$TERM`/`COLORTERM`/`TERM_PROGRAM`/`CW_TERM`; DA1/DA2/DSR | **done** — `HostEnvironment.curated` unconditionally sets `TERM_PROGRAM=aislopdesk` + `TERM_PROGRAM_VERSION` + `CW_TERM=aislopdesk` (no longer mirrors the launcher's `TERM_PROGRAM`); `TERM`/`COLORTERM` + DA1/DA2/DSR via libghostty | none | — |
| L12 | `term` setting (auto→xterm-256color w/ validation) | **partial** — TERM enum exists; no validated `term` setting | add `term` setting + host validation | 4 |

---

## M. Themes / Fonts — `spec/customization__{themes,fonts}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| M1 | Built-in themes + live switch (menu/palette/settings) | **done** — `ThemeStore` (Monokai Pro 6 + Paper + Dark + System), live-apply across NSSplitViewController | none | — |
| M2 | Light/dark slot (`theme`/`theme-dark`) follow OS | **partial** — `ThemeChoice` + System; explicit dual-slot follow-OS toggle | add "use separated dark theme" toggle | 4 |
| M3 | Custom `.ottytheme` TOML + user themes dir | **missing** | add `~/.config/aislopdesk/themes/` scan + parser | 4 |
| M4 | Import iTerm2/Kitty/Alacritty/Ghostty themes | **missing** | add theme import pipeline → ThemeStore | 4 |
| M5 | Theme editor (swatch grid, chrome regions, Duplicate/Edit/Open Folder) | **missing** | build theme editor UI | 4 |
| M6 | Theme container styling (radius/shadow/border/padding/margin) | **partial** — flat tokens exist; per-theme container config missing | thread container tokens into theme | 4 |
| M7 | Font family/size/weight (live) | **done** — `TerminalPreferences` + live reload | none | — |
| M8 | Font size shortcuts `⌘+`/`⌘-`/`⌘0` | **missing** — no font-size keybindings | add font-size in/out/reset bindings (no PTY reflow) | 3 |
| M9 | Font picker (native browser w/ specimens) | **missing** — plain TextField | add font picker (host-side install caveat) | 4 |
| M10 | Font fallback / scope tabs (Global/Light/Dark/Fallback) | **partial** — single family; no scope/fallback | add fallback + scope (ties J5) | 4 |
| M11 | Line height (Default/Compact/Loose/Custom) | **partial** — density setting exists; not the otty line-height modes | add line-height modes via config builder | 4 |
| M12 | Bold/Italic/Underline/Blink/blending modes | **partial** — libghostty supports; settings missing (blending only Default/macos-like) | add Appearance→Text settings; blending partial (document) | 4 |
| M13 | Font install (`~/.config/otty/fonts/`, CoreText register) | **na-remote** — render is host-side libghostty; fonts must be on host | client text-field only; host-side install note | 5 |

---

## N. Keybindings / Custom-Commands / Settings / Import-Export — `spec/customization__{custom-keybindings,custom-commands,config-file,advanced-settings,import-export}.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| N1 | Keybindings editor (search, keycaps, click-to-record, conflict, unbind, reset) | **done** — `KeybindingsEditorView` + overrides + conflicts | none | — |
| N2 | Default keymap full set | **partial** — 35+ actions; gaps = split-left/up, pane-cycle, scroll keys, font-size, ⌘⇧E/⌘⇧M/⌘⇧P/⌘⇧O | register the missing actions (see A7/A10/I12/M8/I23/I24/G1/G4) | 2 |
| N3 | Multi-key sequence chords (`cmd+b>cmd+v`) | **done** — `sequenceOverrides` + dispatcher | none | — |
| N4 | Text/Sequence bindings (`text:`/`csi:`/`esc:`) | **missing** | add literal-byte binding rows + dispatch | 4 |
| N5 | `unbind:` + parameterized actions (`goto_tab:N`) | **partial** — `selectTab` done; generic unbind/param-action | add unbind directive + param-action parse | 4 |
| N6 | SwiftUI `.commands` menu-bar surface | **missing** — no `WorkspaceCommands` in rebuilt shell | port menu bar with `.keyboardShortcut` items | 3 |
| N7 | Recipes (layouts/snippets/command-replay) | **partial** — snippet model + CRUD exist, **no UI**; no recipe file/replay | build Recipes/Snippets UI + `.ottyrecipe`-style save/restore (ties A28) | 3 |
| N8 | Text snippets (alias→text, placeholders `{{date}}` etc.) | **partial** — `SnippetExpander`/`SendKeysParser` done, **no UI** | add snippet editor + expansion trigger | 3 |
| N9 | Settings: General / Shell / Controls / Editor / Appearance / Agents / Advanced | **partial** — 5 tabs (General/Terminal/Video/Keybindings/Advanced); missing Controls/Editor/Agents/Shell-named sections + many toggles | expand settings tabs to otty's sections + missing toggles | 2 |
| N10 | Advanced "All Settings" searchable list + Reset All/Advanced | **partial** — Advanced raw-override box + Restore-All done; no searchable all-keys list | add searchable all-settings list + cross-tab jump | 4 |
| N11 | Config file (Open/Reload/path) | **na-remote** — UserDefaults + sidecar; no dotfile | substitute: show UserDefaults-backed config; optional export | 5 |
| N12 | Import/Export config (Ghostty/Kitty/Alacritty) | **missing** — workspace `WorkspaceTransfer` exists but no UI; no terminal-config import | add config import/export engine + UI; surface workspace import/export file picker | 4 |
| N13 | iOS settings surface | **missing** | add iOS in-app settings sheet | 4 |

---

## O. First-Launch / CLI / Agents (Claude Code) — `spec/getting-started__first-launch.md`, `spec/reference__cli.md`, `spec/agents__*.md`

| # | Otty behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| O1 | On-Launch (Restore Last Session) | **done** — `DetachedSessionStore` reattach; persistence | surface "On Launch" setting | 3 |
| O2 | Set-as-default-terminal / OS integration | **na-remote / partial** — local editors only; remote-host editors can't be rewritten | offer for local launches only (P4) | 5 |
| O3 | Install CLI (`/usr/local/bin/aislopdesk`) + omit-prefix | **partial** — `aislopdesk-ctl` exists; no installer/omit-prefix | add CLI installer flow | 4 |
| O4 | Agents tab: Install/Uninstall Claude Code hooks + Status | **partial** — host detection stack done; no install-card UI; hooks installed host-side | build Agents settings card writing host `~/.claude/settings.json` over channel | 2 |
| O5 | Agent Behavior toggles (badge×3, notify×2, prevent-sleep, resume-on-recovery) | **partial** — attention notifications live; per-toggle settings + prevent-sleep missing | add 7 toggles + `IOPMAssertion` prevent-sleep | 3 |
| O6 | Tab badges for agent state (processing/idle/awaiting) | **partial** — `ClaudeStatus` end-to-end; **dot not rendered on tab row** | render dot on `OttyTabRow` (ties A20) | 2 |
| O7 | Composer (agent + terminal panes) | **partial** — see I23 | mount composer | 2 |
| O8 | Prompt Queue `⌘⇧M` | **missing** — see I24 | build prompt queue | 3 |
| O9 | Send to Chat `⌘⌃↩` (capture dialog, session routing) | **missing** | build send-to-chat dialog + agent-pane routing | 3 |
| O10 | History viewer (JSONL transcript, Resume, Open-Quickly Agents) | **missing** — `BlockHistoryView` is command-block only; session files host-side | host RPC to list/read `~/.claude/projects/*.jsonl`; client transcript renderer + Resume | 3 |
| O11 | Fork / Branch (`/branch`) detect + route to split/tab | **na-remote / partial** — agent runs `/branch`; aislopdesk detects new session + routes | detect new session id, spawn `claude --resume <id>` pane; palette "Fork in…" | 4 |
| O12 | Monitor Tasks (per-tab badge/notify toggles, prevent-sleep, clear-badge) | **partial** — global attention only | add per-pane toggles + clear-badge action | 4 |
| O13 | Resume (`claude --resume <id>`) | **partial** — PTY spawn path exists; not wired to history/UI | wire Resume from history viewer / inspector | 4 |
| O14 | CLI parity (`open/view/edit/config/font/theme/keybind/pane/tab/watch/jump/learn/state/ipc`) | **partial** — `aislopdesk-ctl` covers send-keys/spawn/etc.; many subcommands missing | extend CLI to otty-parity subcommands (incremental) | 4 |
| O15 | Agent self-report state (`otty state:<agent>`) | **done** — `AgentControlListener.reportAgent` / hook listener | none | — |

---

## P. The User's Extension — Remote Window (already in aislopdesk; otty has no analog)

| # | Behavior | Aislopdesk status | Gap delta | Pri |
|---|---|---|---|---|
| P1 | Remote-GUI pane (UDP HEVC video of a host window) in the split tree | **done** — `.remoteGUI` pane kind; `GuiLeafView`; in-pane chooser Terminal/Remote | keep first-class as the clone's tabs/splits/palette/drag-drop land | 2 |
| P2 | Remote-window picker (over-wire discovery) | **partial** — `OverlayCoordinator` remote-picker state exists; mounted with the same OverlayCoordinator gap | mount remote picker when OverlayCoordinator is mounted | 2 |
| P3 | Connect-to-host overlay (host/port editor) | **partial** — `connectVisible`/`openConnect` exist; not mounted; pill `openConnect` is a TODO no-op | mount connect overlay (same OverlayCoordinator mount) | 2 |
| P4 | Remote-GUI surfaces in palette/drag-drop/zoom/float like terminal panes | **partial** — pane kind participates in split tree; floating render + cross-feature surfacing pending | ensure remote-GUI panes flow through every new clone surface | 3 |

---

## Cross-cutting "single mount unlocks many" findings

1. **OverlayCoordinator is fully built but never mounted** (`ui-shell.md`, `palette-search.md`, `keybindings-commands.md`). Mounting it + passing `togglePalette`/`toggleCheatSheet`/`toggleFind`/`togglePeekReply`/remote-picker/connect closures into `WorkspaceKeyDispatcher` unlocks **⌘K palette, ⌘/ cheat sheet, ⌘F find, toasts, connect-to-host, remote-window picker, peek-and-reply** in one structural change — pending the missing *views* (PaletteView, CheatSheetView, TerminalFindBar).

2. **Tree-path dead seams**: `⇧⌘T` reopen (A4), `⌘S` save-layout (A28), are wired only on the retiring canvas path. Each needs a tree-path implementation + a `routeTree` case.

3. **Engine-without-view pattern** recurs: find (F1), palette (G1), cheat-sheet (G9), block-navigator (G8), composer (I23), agent footer (O7), peek-and-reply, sidebar status dot (A20/O6). The cheapest wins are the views, not new engines.

4. **Host RPC gap**: Details Git/Files/processes/ports (B3/B5/B6), history JSONL (O10), folders frecency-over-host, listening ports — all need a host control-channel directory/git/process listing service. This is the largest genuinely-new backend surface and should land as one shared epic.

5. **Keybinding chord divergence**: aislopdesk currently uses `⌥⌘` for several pane ops where otty uses `⌘⌃`/`⌘⌃⇧`. For a 1:1 clone, reconcile the default keymap to otty's chords (or make them overridable defaults) — low-risk since the override pipeline already exists.
