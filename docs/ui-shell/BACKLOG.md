# UI-Shell Design — Implementation Backlog (Epics)

Gaps from `GAP-ANALYSIS.md` clustered into shippable epics, topologically ordered by dependency: foundational epics (keybinding routing, overlay host, theming/settings, host RPC) precede the leaf features that consume them. Each epic sizes to one focused pass.

- **Estimate**: S ≈ <0.5 day, M ≈ 1 day, L ≈ 2–3 days, XL ≈ 1 week.
- **Priority**: 1 (highest) … 5.
- **specRefs**: spec files implemented. **gapRefs** in prose map back to `GAP-ANALYSIS.md` rows.
- **Reuse first**: every epic notes the existing slopdesk seam to extend — do not rebuild working engines (the current-state maps catalog them).

| Order | Epic | Pri | Est | Depends on |
|---|---|---|---|---|
| 1 | E1 Default-keymap parity & routing completion | 1 | M | — |
| 2 | E2 Overlay host mount (palette · cheat-sheet · find · toasts · connect · remote-picker) | 1 | L | E1 |
| 3 | E3 Tree-path domain completion (reopen · cwd-inherit · new-tab-pos · pane-cycle) | 1 | M | E1 |
| 4 | E4 Host metadata RPC service (cwd · processes · ports · git · directory · sessions) | 1 | XL | — |
| 5 | E5 In-pane Find + Global Search | 2 | M | E2 |
| 6 | E6 Sidebar tab rows: badges · subtitle · number · search · grouping/sort | 2 | L | E1,E3,E4 |
| 7 | E7 Settings sections parity + iOS settings + import/export | 2 | L | E1 |
| 8 | E8 Terminal interaction parity (selection/copy/scroll/input toggles) | 2 | L | E2,E7 |
| 9 | E9 Details panel: Info(process/ports) · Outline · Git · Files | 2 | L | E2,E4 |
| 10 | E10 Path/link detection · Jump-To · status bar · hint mode | 3 | L | E2,E4 |
| 11 | E11 Open Quickly (`⌘⇧O`) filters + Actions popover | 3 | M | E2,E4 |
| 12 | E12 Composer + Prompt Queue | 2 | L | E2,E3 |
| 13 | E13 Agent integration UI (install card · behavior toggles · tab badges · Send-to-Chat · History · Resume/Fork) | 2 | XL | E2,E4,E6,E12 |
| 14 | E14 Progress state + notifications + privilege parity | 3 | M | E4,E7 |
| 15 | E15 Theming editor + custom/import themes + fonts parity | 3 | L | E7 |
| 16 | E16 Recipes + snippets (save/restore layouts, text expansion) | 3 | L | E3,E7,E11 |
| 17 | E17 Read-only mode + Vi-mode pill + secure input | 3 | M | E2,E7 |
| 18 | E18 External drag-drop zones + tab reorder + web pane | 3 | M | E3,E6 |
| 19 | E19 Window options (pin · size modes · multi-session UI · horizontal tab bar) | 4 | M | E3,E6 |
| 20 | E20 CLI parity (`slopdesk` subcommands) + watch + first-launch | 4 | L | E4,E13 |
| 21 | E21 Remote-window extension first-class through UI-shell surfaces | 2 | M | E2,E6,E10,E11 |

---

## E1 — Default-keymap parity & command routing completion
**Goal.** Fill the binding registry's default chords and register every action the UI shell needs, so later epics bind commands without touching routing. Reuse `WorkspaceBindingRegistry` (single source of truth), `WorkspaceBindingRouting.routeTree`, override pipeline (all done); fill the action/chord gaps + missing `routeTree` cases.
**specRefs.** `spec/customization__custom-keybindings.md`, `spec/reference__keybindings.md`, `spec/user-interface__window-tab-split.md`.
**Scope.** Register split-left/up (A7), sequential pane-cycle `⌘]`/`⌘[` (A10), scroll keys `⇧PageUp/Down`/`⇧Home/End` + command-jump `⌘PageUp/Down` (I12/I16), font-size `⌘+`/`⌘-`/`⌘0` (M8), `⌘⇧E`/`⌘⇧M`/`⌘⇧P`/`⌘⇧O`/`⌘⇧F`/`⌘⌃↩` action stubs; reconcile pane chords to the documented `⌘⌃`/`⌘⌃⇧` defaults (A8/A9/A11/A25); add `routeTree` cases for reopen-closed (→E3) and palette/cheat/find (→E2). Text/Sequence (`text:`/`csi:`/`esc:`) bindings (N4) + `unbind:`/param-action parse (N5). Optional: SwiftUI `.commands` menu-bar (N6).
**Est** M · **Pri** 1 · **dependsOn** —
**Acceptance:** ES-E1-1…ES-E1-6.

## E2 — Overlay host mount
**Goal.** Mount the built `OverlayCoordinator` into the live scene, pass its toggle closures into `WorkspaceKeyDispatcher`, and build the three missing overlay views — unlocking palette/cheat-sheet/find/toasts/connect/remote-picker in one structural pass.
**specRefs.** `spec/user-interface__command-palette.md`, `spec/customization__custom-keybindings.md`, `spec/user-interface__find.md`.
**Scope.** Instantiate `OverlayCoordinator` in `SlopDeskClientApp`; call `overlayCoordinator(_:)` on the scene root; construct `WorkspaceKeyDispatcher` with `togglePalette`/`toggleCheatSheet`/`toggleFind`/`togglePeekReply`/connect/remote-picker closures. Build **PaletteView** (search field, section headers, keycap chips, ✓ toggle-state, selected-row fill, ⌘↩ chain, Esc), **KeyboardCheatSheetView** (from `groupedForDisplay`), and the **toast** host. Wire connect-to-host overlay + remote-window picker mounts. (Find bar view lands in E5; this epic exposes its toggle.)
**Est** L · **Pri** 1 · **dependsOn** E1
**Acceptance:** ES-E2-1…ES-E2-6.

## E3 — Tree-path domain completion
**Goal.** Fix the canvas-only dead seams and the missing tab/cwd policies on the live tree path.
**specRefs.** `spec/user-interface__window-tab-split.md`.
**Scope.** Tree-path **reopen-last-closed** LIFO stack (A4) populated on `closePaneTree`, restored via `routeTree` `.reopenClosedPane`. **Working-directory inheritance** (A26): pipe OSC 7 → `PaneSpec.lastKnownCwd`; `newTab`/`splitActivePane` read active pane cwd; add `working-directory` policy (inherit/home/path). **New-tab position** (A17): `newTabPosition` (auto/end/after-current). **Sequential pane cycle** ops (A10) in `WorkspaceTreeOps`. **Close-confirm policy** enum (A27: process/always/multiple_tabs) feeding the busy-shell guard.
**Est** M · **Pri** 1 · **dependsOn** E1
**Acceptance:** ES-E3-1…ES-E3-5.

## E4 — Host metadata RPC service
**Goal.** One shared host control-channel service listing per-pane processes, listening ports, cwd, git status/branch/diff, directory contents (lazy), and Claude session files — the backend every remote-dependent surface needs. Extend the existing control channel / `AgentControlListener` ctl-socket patterns; never reintroduce app-layer crypto (trusted mesh).
**specRefs.** `spec/user-interface__details-panel.md`, `spec/agents__history.md`, `spec/terminal-features__shell-integration.md`.
**Scope.** Wire messages / NDJSON verbs: `processes(pane)`, `ports(pane)`, `cwd(pane)` (or rely on OSC 7), `gitStatus(path)`/`gitBranch`/`gitDiff(file)`, `listDirectory(path)` (lazy per-expand), `listAgentSessions(project)` + `readAgentSession(id)`. Validate-then-drop on all inputs. Client-side caches + observable models. (Host-side shell-integration script injection L9 can ride here or follow up.)
**Est** XL · **Pri** 1 · **dependsOn** —
**Acceptance:** ES-E4-1…ES-E4-5.

## E5 — In-pane Find + Global Search
**Goal.** Surface the complete `TerminalSearchController` engine behind a real find bar and add cross-tab global search.
**specRefs.** `spec/user-interface__find.md`.
**Scope.** Build **TerminalFindBar** overlay (top-right of pane): query field, `Aa` case toggle, `.*` regex toggle, prev/next chevrons, `N of M`, Esc-close. Assign `terminalModel.onRequestFind` from the leaf view. Bind `⌘F`/`⌘G`/`⇧⌘G`/`Esc`. Reconcile in-buffer highlight (libghostty `start_search`) vs client count (document drift if needed). **Global Search `⇧⌘F`** over per-pane scrollback mirrors → a read-only results pane grouped by tab with jump-to-match.
**Est** M · **Pri** 2 · **dependsOn** E2
**Acceptance:** ES-E5-1…ES-E5-5.

## E6 — Sidebar tab rows: badges, subtitle, number, search, grouping/sort
**Goal.** Bring `SlateTabRow` up to its full visual spec and make the sort hamburger real.
**specRefs.** `spec/user-interface__window-tab-split.md`, `spec/terminal-features__progress-state.md`, `spec/agents__parallel-tasks.md`.
**Scope.** Render `RailRow.status` dot on `SlateTabRow` (A20/O6) — spinner/check/dot/error/hand from `ClaudeStatus` + OSC-133 command state + caffeinate/sudo (via E4 processes). Show `#N` number badge + cwd subtitle + shell/process trailing label (A14). Add sidebar **tab search/filter** (call existing `RailRowsBuilder.filtered`). Implement **grouping** (None/By-Project via git-toplevel from E4/By-Date) and **sort** (Created/Updated/Manual) — make the hamburger mutate store order, not local `@State`.
**Est** L · **Pri** 2 · **dependsOn** E1, E3, E4
**Acceptance:** ES-E6-1…ES-E6-5.

## E7 — Settings sections parity + iOS settings + import/export surfacing
**Goal.** Expand the 5-tab settings to the full documented section taxonomy, add the missing toggles, surface workspace import/export, and add an iOS settings sheet.
**specRefs.** `spec/customization__{advanced-settings,import-export}.md`, `spec/getting-started__first-launch.md`, `spec/terminal-features__{cursor-and-mouse,scroll,copy-and-paste,input,notifications}.md`.
**Scope.** Reorganize into General / Shell / Controls / Editor / Appearance / Agents / Keybindings / Advanced (N9). Add the orphan `SettingsKey` toggles with no UI (`hideStatusBar`, `showBlockDividers`, `systemDialogPanes`, `autoSwitchLayouts`, `recordClipboardHistory`) + new Controls/Scroll/Copy toggles consumed by E8. Searchable **All Settings** list + Reset-Advanced (N10). Surface `WorkspaceTransfer` via `.fileExporter`/`.fileImporter` (N12). Add **iOS settings sheet** (N13). On-Launch setting (O1).
**Est** L · **Pri** 2 · **dependsOn** E1
**Acceptance:** ES-E7-1…ES-E7-5.

## E8 — Terminal interaction parity
**Goal.** Add the client-side selection/copy/scroll/input behaviors documented as Controls toggles, all gated by E7 settings.
**specRefs.** `spec/terminal-features__{selection,copy-and-paste,scroll,input,cursor-and-mouse}.md`.
**Scope.** Copy-on-Select (I4), trim-trailing (I5), clear-on-typing/on-copy (I6), backspace-deletes-selection w/ prompt-zone gate (I7), ⇧+arrow native select (I2). Paste Protection sheet (I9), Paste-as… submenu (I10), OSC-52 Ask/Allow/Deny (I11). Scroll-past-last/first overscroll (I15), smooth-scroll snap (I14). Mouse-over-to-focus (H6), right-click-action setting (H7/H8), hide-mouse-when-typing (H9), OSC-22 pointer shape (H14). Cursor color/opacity + live preview (H4/H5), cursor animation (H3, or document omit). Undo/redo at prompt (I18).
**Est** L · **Pri** 2 · **dependsOn** E2, E7
**Acceptance:** ES-E8-1…ES-E8-6.

## E9 — Details panel: Info / Outline / Git / Files
**Goal.** Fill the inspector's empty tabs from the E4 host service and add the Outline tab.
**specRefs.** `spec/user-interface__details-panel.md`, `spec/user-interface__outline.md`.
**Scope.** Info: render process list (name/PID/uptime) + listening ports from E4 (B3); keep Copy-Path; "open on host" where host is the Mac (B7). **Outline tab** (B4/G7): OSC-133 command marks + agent prompts with green/red/grey exit gutter + jump-to-scrollback + right-click copy. **Git tab** (B5): branch/remote/ahead-behind, changed-files list, read-only inline diff overlay. **Files tab** (B6): lazy directory tree + filter field. Register the four `Details: *` bindable jump actions (B2). iOS sheet form (B9).
**Est** L · **Pri** 2 · **dependsOn** E2, E4
**Acceptance:** ES-E9-1…ES-E9-5.

## E10 — Path/link detection · Jump-To · status bar · hint mode
**Goal.** Make paths and URLs in output interactive, add the bottom status bar, and add keyboard hint mode.
**specRefs.** `spec/user-interface__files-and-links.md`, `spec/user-interface__status-bar.md`, `spec/terminal-features__hint-mode.md`, `spec/user-interface__outline.md`.
**Scope.** Client path/URL detector over the cell grid (abs/tilde/rel/`:line:col`/url/`file://`) (D1); ⌘-hold underline highlight (D3); ⌘click open / ⌘⇧click reveal/copy / right-click path menu incl. "Change Directory Here" (D4); link config keys (D11/D12). **Status bar** strip (C1): cwd (OSC 7), last exit (OSC-133 D), pane kind, host; honour `hideStatusBar`; full-path hover preview (C2). **Jump-To `⌘J`** panel scanning current pane (D5/G6). **Hint Mode** `⌘⇧J`/`⌘⇧Y`/`⌘⇧R` 2-letter overlay (L5); open/reveal routed to host where the host is the Mac (L6); iOS tap-on-label fallback. **Command Navigator `⌃⌘O`** overlay (G8).
**Est** L · **Pri** 3 · **dependsOn** E2, E4
**Acceptance:** ES-E10-1…ES-E10-6.

## E11 — Open Quickly + Actions popover
**Goal.** Add the `⌘⇧O` quick-switcher with filter pills, reusing the palette infrastructure.
**specRefs.** `spec/user-interface__open-quickly.md`, `spec/user-interface__outline.md`.
**Scope.** `⌘⇧O` opens the palette pre-filtered to **Opened**; add filter pills All/Opened/Recent/Folders/SSH/Agents/Current/Recipes with `Tab`/`⇧Tab` cycling (G4). Wire Opened (`WorkspaceStore` panes), Recent (recently-closed), Current (OSC-133 block index), Agents (E4 sessions), SSH (`~/.ssh/config`, host-sourced on iOS), Folders (frecency store G11), Recipes (E16). Actions popover `⌘K` per item + `⌘1–9` quick-pick (G5).
**Est** M · **Pri** 3 · **dependsOn** E2, E4
**Acceptance:** ES-E11-1…ES-E11-4.

## E12 — Composer + Prompt Queue
**Goal.** Mount the built `InputBar`/`InputBoxModel` composer and add the prompt queue.
**specRefs.** `spec/agents__composer.md`, `spec/agents__prompt-queue.md`, `spec/terminal-features__input.md`.
**Scope.** Mount composer in `TerminalLeafView`; bind `⌘⇧E`; `⌘↩` send / `⇧↩` newline / `⎋` cancel-keep-draft; draft persistence per pane; rich paste → Markdown; **pin** (promote out of pane subtree) and **float panel** (non-activating `NSPanel`, macOS) (I23). **Prompt Queue** `⌘⇧M`: queue strip chips (reorder/edit/remove), enqueue from composer `⌥⌘↩`, OSC-133 idle dispatch via existing `InputBoxModel` `.commandFinished` seam (I24/O8). iOS: bottom-sheet composer (no float).
**Est** L · **Pri** 2 · **dependsOn** E2, E3
**Acceptance:** ES-E12-1…ES-E12-5.

## E13 — Agent integration UI (Claude Code)
**Goal.** Surface the complete host detection stack as slopdesk's agent experience: install card, behavior toggles, tab badges, Send-to-Chat, History, Resume/Fork. Claude Code only.
**specRefs.** `spec/agents__{setup,supported-agents,agents-overview,send-to-chat,history,fork-branch-session,parallel-tasks}.md`, `spec/getting-started__first-launch.md`.
**Scope.** **Agents settings card**: Install/Uninstall hooks into host `~/.claude/settings.json` over the control channel + Status row (O4). **Behavior toggles** (badge×3, notify×2, prevent-sleep via `IOPMAssertion` on host, resume-on-recovery) (O5/O12) with per-pane overrides + Clear-Badge action. **Tab badges** already from E6. **AgentInputFooter** view mounted (notifications/rich-input/file-explorer chips). **Send to Chat `⌘⌃↩`** (O9): capture selection / last-output (OSC-133 D), modal dialog (quoted preview, Send-to session picker, comment, Copy/Cancel/Send), route to active agent pane, auto-focus. **History viewer** (O10): host RPC (E4) lists/reads `~/.claude/projects/*.jsonl`; client transcript renderer (reuse `MarkdownText`) + raw-toggle + **Resume** (`claude --resume <id>`, jump-if-live). **Fork** (O11): detect new session id from PTY, route to split/tab; palette "Fork in…". Peek-and-Reply overlay `⌘⇧J` (build the missing view over existing logic).
**Est** XL · **Pri** 2 · **dependsOn** E2, E4, E6, E12
**Acceptance:** ES-E13-1…ES-E13-7.

## E14 — Progress state + notifications + privilege parity
**Goal.** Surface OSC 9;4 progress and complete the notification/privilege surface.
**specRefs.** `spec/terminal-features__{progress-state,notifications}.md`.
**Scope.** Replace the OSC-9;4 filter with a wire message + client spinner/progress badge (K1); auto-progress prefix-list (K2); OSC-133-D command badges drive tab badges (K3, shares E6). Dock progress + red-on-error (K5), bounce dock (K8), Notify-While-Foreground policy (K9), Notify-on-Finish/Error/Watch (K10). OSC 99 parse (K6). Title-report + privilege toggles + system-permission status row (K11/K12). IPC guards mapped to host ctl-socket (K13).
**Est** M · **Pri** 3 · **dependsOn** E4, E7
**Acceptance:** ES-E14-1…ES-E14-4.

## E15 — Theming editor + custom/import themes + fonts parity
**Goal.** Add the theme editor, custom/imported themes, and the documented font settings.
**specRefs.** `spec/customization__{themes,fonts}.md`, `spec/terminal-features__unicode-and-text-styles.md`.
**Scope.** Dual-slot follow-OS toggle (M2); custom `~/.config/slopdesk/themes/*.toml` scan+parser (M3); import iTerm2/Kitty/Alacritty/Ghostty (M4); theme editor (swatch grid, chrome regions, Duplicate/Edit/Open-Folder) (M5); container tokens per theme (M6). Fonts: family picker w/ specimens (host-install caveat) (M9), fallback + scope tabs (M10/J5), line-height modes (M11), ligature/bold/italic/underline/blink/blending settings (J4/J6/M12). (`⌘+`/`⌘-`/`⌘0` already from E1; wire to config-builder rebuild without PTY reflow.)
**Est** L · **Pri** 3 · **dependsOn** E7
**Acceptance:** ES-E15-1…ES-E15-5.

## E16 — Recipes + snippets
**Goal.** Build the Recipes subsystem (save/restore layouts, command replay) and surface the existing snippet engine.
**specRefs.** `spec/customization__custom-commands.md`, `spec/user-interface__window-tab-split.md`.
**Scope.** Tree-path **Save Layout `⌘S`** (scope tab/window, content layout/commands) → `.slopdeskrecipe` TOML (A28/N7); Open Recipe restore via `reconcileTree`; portable-path vars; command-replay modes (Auto/Ask-Once/Manually/Skip) + trust-hash store; shell-handoff pause via OSC-133. **Snippets UI** (N8): editor (Name/Alias/Text + `{{clipboard}}`/`{{date}}`/`{{time}}`/`{{cursor}}`), alias expansion at prompt, palette entries — reuse `SnippetExpander`/`SendKeysParser`/CRUD store methods.
**Est** L · **Pri** 3 · **dependsOn** E3, E7, E11
**Acceptance:** ES-E16-1…ES-E16-4.

## E17 — Read-only mode + Vi-mode pill + secure input
**Goal.** Add the per-pane read-only gate, the Vi-mode pill/hints, and secure-keyboard-entry.
**specRefs.** `spec/terminal-features__{read-only-mode,vi-mode,input}.md`.
**Scope.** **Read-only** per-pane `isReadOnly` input gate (keys/paste/click-to-move/mouse-report/drop) + `🔒 READ ONLY ×` pill + beep-on-blocked + Shell→Read-Only menu/palette terms (L7). **Vi-mode pill** + repeat-count + key-hint bar `⌘/` over the existing copy-mode (L1/L4); `/`/`?` into find bar (L3); line/block selection (char-select documented as libghostty ceiling, L2). **Secure input** (I22): host signals canonical no-echo → client `EnableSecureEventInput` + SECURE-INPUT title pill + Auto/Indicator settings.
**Est** M · **Pri** 3 · **dependsOn** E2, E7
**Acceptance:** ES-E17-1…ES-E17-4.

## E18 — External drag-drop + tab reorder + web pane
**Goal.** Accept external file/folder/URL/text drops, add manual tab reorder, and add a local web pane.
**specRefs.** `spec/user-interface__drag-and-drop.md`, `spec/user-interface__files-and-links.md`.
**Scope.** `NSDraggingDestination` overlay with circular zones New-Tab/Insert-Path/Open-In-Place/Split-L/R (E4-drop, E5-drop): Insert-Path injects to PTY, folder→`cd` (host-resolved warning), text snippet inject. **Tab reorder** manual drag (E2/A16, shares E6 sort=Manual). **Web pane** `PaneKind.web` WKWebView non-persistent store (D9). Tear-off into new window deferred.
**Est** M · **Pri** 3 · **dependsOn** E3, E6
**Acceptance:** ES-E18-1…ES-E18-4.

## E19 — Window options (pin · size · multi-session · horizontal tab bar)
**Goal.** Add window-level parity options.
**specRefs.** `spec/user-interface__window-tab-split.md`.
**Scope.** Pin window / always-on-top (`NSWindow.level=.floating`) (A30); `window-size` modes remember/grid/frame + cols/rows/px (A29); **multi-session UI** — session list/switcher in the sidebar (A32); horizontal tab-bar layout option + `layout` setting + auto-hide-tab-bar (A13/A18). PiP substitute = always-on-top of active pane (A31, document true PiP deferred).
**Est** M · **Pri** 4 · **dependsOn** E3, E6
**Acceptance:** ES-E19-1…ES-E19-4.

## E20 — CLI parity + watch + first-launch
**Goal.** Extend the `slopdesk` CLI to full parity with the reference command set and add the first-launch flow.
**specRefs.** `spec/reference__cli.md`, `spec/terminal-features__progress-state.md`, `spec/getting-started__first-launch.md`.
**Scope.** Map the reference subcommands onto `slopdesk-ctl`/store ops: `open/view/edit`, `config get/set/reload`, `font/theme/keybind list`, `tab/pane/window` (`send-keys` already exists), `tab badge --kind`, `pane capture`, `watch <cmd>` (OSC 9;4 wrapper), `watch:claude <id>` (exit 0/4/9), `jump/learn/ignore` (frecency), `version`, `completions`, `state:`/`ipc` (done). Install-CLI flow + omit-prefix (O3). First-launch settings (On-Launch, default-terminal local-only, install hooks card) (O1/O2).
**Est** L · **Pri** 4 · **dependsOn** E4, E13
**Acceptance:** ES-E20-1…ES-E20-4.

## E21 — Remote-window extension first-class through UI-shell surfaces
**Goal.** Ensure the user's remote-window feature flows through every UI-shell surface as a first-class peer of terminal panes.
**specRefs.** (slopdesk-native extension, no external analog; design alongside `spec/user-interface__window-tab-split.md` and `spec/user-interface__open-quickly.md`.)
**Scope.** Mount the remote-window picker + connect-to-host overlay (rides E2's OverlayCoordinator mount) (P2/P3). Ensure `.remoteGUI` panes participate in: palette/Open-Quickly results, drag-drop zones (E18), zoom, floating render, sidebar rows + badges (E6), status bar (E10), read-only gate (E17). Floating-pane renderer in `SplitContainer` (covers the floating-pane gap that also blocks composer-pin/float). Per-host badge in pickers where multi-host lands.
**Est** M · **Pri** 2 · **dependsOn** E2, E6, E10, E11
**Acceptance:** ES-E21-1…ES-E21-4.
