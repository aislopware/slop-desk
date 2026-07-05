# SlopDesk UI-Shell — Acceptance User Stories (Self-Verification Checklist)

Flat list of every acceptance story across all epics in `BACKLOG.md`, tagged with epic id and verifiability:
- **unit-testable** — provable headlessly (`swift test`) against domain/engine code.
- **GUI-verifiable** — requires the real app (HW GUI per `scripts/check-macos.sh` / cua-driver), not headless (per CLAUDE.md hang-safety rules).
- **both** — unit-testable core + GUI surface.

---

## E1 — Default-keymap parity & routing completion
- **ES-E1-1** [E1] `⌘⌥D` / `⌘⌥⇧D` splits a pane left / up and focuses it. — both
- **ES-E1-2** [E1] `⌘]` / `⌘[` cycles focus to next / previous pane sequentially. — both
- **ES-E1-3** [E1] `⇧PageUp/Down`, `⇧Home/End`, `⌘PageUp/Down` page / jump / command-jump the scrollback. — both
- **ES-E1-4** [E1] `⌘+` / `⌘-` / `⌘0` grows / shrinks / resets terminal font without reflowing the PTY grid. — GUI-verifiable
- **ES-E1-5** [E1] (dev) Every UI-shell action (`commandPalette`, `cheatSheet`, `find`, `openQuickly`, `composer`, `promptQueue`, `sendToChat`, `reopenClosed`) is registered in the binding registry with a unique, override-resolvable chord and a `routeTree` case. — unit-testable
- **ES-E1-6** [E1] Binding `text:hi` / `csi:17~` / `esc:O` to a chord injects the literal bytes into the focused pane; `unbind:` disables a default. — both

## E2 — Overlay host mount
- **ES-E2-1** [E2] `⌘⇧P` (or `⌘K`) opens the command palette centered, search pre-focused, every action grouped by section with keycap chips. — GUI-verifiable
- **ES-E2-2** [E2] In the palette: type to fuzzy-filter, arrow to move highlight, `↩` runs, `⌘↩` runs-and-keeps-open, `Esc` dismisses. — both (filter/rank unit-testable; chords GUI)
- **ES-E2-3** [E2] A toggled action (e.g. Toggle Tabs Panel) shows a ✓ when on. — GUI-verifiable
- **ES-E2-4** [E2] `⌘/` opens the keyboard cheat sheet overlay (grouped key map); `Esc` dismisses. — GUI-verifiable
- **ES-E2-5** [E2] A transient toast appears for background events and auto-dismisses. — GUI-verifiable
- **ES-E2-6** [E2] Tapping the connection pill (or its give-up state) opens the connect-to-host overlay; the remote-window picker is reachable from the palette. — GUI-verifiable

## E3 — Tree-path domain completion
- **ES-E3-1** [E3] After closing a tab, `⇧⌘T` restores it (LIFO) on the live tree path. — unit-testable
- **ES-E3-2** [E3] With working-directory = inherit, a new tab or split starts in the active pane's last-known cwd (from OSC 7). — both
- **ES-E3-3** [E3] With new-tab-position = after-current, a new tab inserts right after the active tab; = end appends. — unit-testable
- **ES-E3-4** [E3] With close-confirmation = multiple_tabs, closing a window prompts only when it has >1 tab; = process prompts only when a child process runs. — unit-testable
- **ES-E3-5** [E3] (dev) `WorkspaceTreeOps` exposes a pure sequential pane-cycle op covered by tests. — unit-testable

## E4 — Host metadata RPC service
- **ES-E4-1** [E4] Client can request the process list (name/PID/uptime) and listening ports for a pane; they render in the inspector. — both (decode unit-testable; render GUI)
- **ES-E4-2** [E4] Client can request git branch, ahead/behind counts, changed-file list, and a file diff for a pane's repo. — both
- **ES-E4-3** [E4] Client can lazily list a host directory's contents on expand. — both
- **ES-E4-4** [E4] Client can list and read the host's Claude session JSONL files for the current project. — both
- **ES-E4-5** [E4] (dev) Every host RPC decoder validates declared counts/lengths before allocating and drops malformed datagrams without trapping. — unit-testable

## E5 — In-pane Find + Global Search
- **ES-E5-1** [E5] `⌘F` shows a find bar at the top-right of the focused pane, query field pre-focused. — GUI-verifiable
- **ES-E5-2** [E5] Typing live-highlights all matches and shows an `N of M` counter. — both (engine unit-testable; highlight GUI)
- **ES-E5-3** [E5] `↩`/`⌘G` advances, `⇧↩`/`⇧⌘G` reverses, scrolling to keep the current match visible; `Esc` closes and clears. — both
- **ES-E5-4** [E5] The `Aa` toggle makes search case-sensitive; the `.*` toggle interprets the query as regex. — unit-testable
- **ES-E5-5** [E5] `⇧⌘F` global-searches every tab's scrollback, results grouped by tab with a `N results — M tabs` summary; clicking a result jumps to that tab and line. — both

## E6 — Sidebar tab rows
- **ES-E6-1** [E6] An agent pane shows the correct status dot on its sidebar row (spinner=working, green check/dot=done, red=error/needs-permission, hand=awaiting input). — both (state unit-testable; dot GUI)
- **ES-E6-2** [E6] Each tab row shows its `#N` shortcut number, a cwd subtitle, and the running shell/process name. — GUI-verifiable
- **ES-E6-3** [E6] Typing in the sidebar search filters the tab list. — both
- **ES-E6-4** [E6] Grouping = By Project groups tabs by git repo; By Date by last-active; the choice reorders rows in the store. — unit-testable
- **ES-E6-5** [E6] Sort = Updated orders rows by most-recent activity; Manual lets me drag to reorder. — both

## E7 — Settings sections + iOS + import/export
- **ES-E7-1** [E7] Settings shows General / Shell / Controls / Editor / Appearance / Agents / Keybindings / Advanced sections matching the documented taxonomy. — GUI-verifiable
- **ES-E7-2** [E7] The previously-orphan toggles (hide status bar, show block dividers, system-dialog panes, auto-switch layouts, record clipboard history) are now toggleable from a Settings tab. — both
- **ES-E7-3** [E7] The Advanced tab's searchable All-Settings list filters by key/label/description and offers Reset-All / Reset-Advanced with confirmation. — both
- **ES-E7-4** [E7] Export the workspace to a file and import it back via a file picker. — both (codec unit-testable; picker GUI)
- **ES-E7-5** [E7] iOS: an in-app settings sheet exposes the cross-platform settings. — GUI-verifiable

## E8 — Terminal interaction parity
- **ES-E8-1** [E8] With Copy-on-Select on, every selection drops into the clipboard with no `⌘C`; trim-trailing strips trailing spaces per line. — both
- **ES-E8-2** [E8] With the relevant toggles, selection clears on typing / after copy, and Backspace on a selected prompt deletes the whole selection (gated to the prompt zone). — both
- **ES-E8-3** [E8] Pasting multi-line / trailing-newline / sudo / control-char content triggers a paste-protection confirmation, skipped inside a full-screen TUI. — both
- **ES-E8-4** [E8] Paste-as… offers Selection / File-base64 / Escaped / Bracketed / →Composer transforms. — both
- **ES-E8-5** [E8] Scroll-past-last/first-line overscroll behaves per the chosen mode and is suppressed on the alternate screen. — both
- **ES-E8-6** [E8] Mouse-Over-to-Focus, configurable right-click action, hide-mouse-when-typing, and OSC-22 pointer shapes all work per their settings. — GUI-verifiable

## E9 — Details panel
- **ES-E9-1** [E9] The inspector Info tab lists the pane's running processes (name/PID/uptime) and listening ports (or "No listening ports"). — both
- **ES-E9-2** [E9] The Outline tab lists this pane's commands (and agent prompts) chronologically with a green/red/grey exit gutter; clicking jumps the scrollback. — both
- **ES-E9-3** [E9] The Git tab shows branch, remote, ahead/behind, the changed-file list, and a read-only inline diff when a file is selected. — both
- **ES-E9-4** [E9] The Files tab shows a lazy file tree rooted at the pane cwd with a filter field. — both
- **ES-E9-5** [E9] The four `Details: Info/Outline/Git/Files` jump commands switch the inspector tab. — both

## E10 — Links · Jump-To · status bar · hint mode
- **ES-E10-1** [E10] Holding `⌘` underlines detected paths and URLs; releasing removes the underline. — GUI-verifiable
- **ES-E10-2** [E10] `⌘click` opens a detected path/URL, `⌘⇧click` reveals/copies, right-click offers Copy-Path / Change-Directory-Here / Open-in. — both (detector unit-testable; gestures GUI)
- **ES-E10-3** [E10] The bottom status bar shows the truncated cwd, last command's exit code, pane kind, and host. — both
- **ES-E10-4** [E10] ⌘-hovering a detected path shows its full resolved path in the status area. — GUI-verifiable
- **ES-E10-5** [E10] `⌘J` opens a Jump-To panel of the current pane's paths, links, and commands, filterable by typing. — both
- **ES-E10-6** [E10] `⌘⇧J` overlays 2-letter labels on detected targets; typing a label opens it (host-routed where the host is the Mac); `Esc` cancels. — both

## E11 — Open Quickly + Actions popover
- **ES-E11-1** [E11] `⌘⇧O` opens the quick-switcher with filter pills (All/Opened/Recent/Folders/SSH/Agents/Current/Recipes), defaulting to All. — GUI-verifiable
- **ES-E11-2** [E11] `Tab`/`⇧Tab` cycle filters; the Opened filter lists every live pane with fuzzy filtering; `↩` switches to it. — both
- **ES-E11-3** [E11] `⌘K` opens an Actions popover for the highlighted item with context-appropriate actions; `⌘1–9` opens the Nth result directly. — both
- **ES-E11-4** [E11] The Folders filter ranks visited cwds by frecency; the Agents filter lists Claude sessions for the current project. — both

## E12 — Composer + Prompt Queue
- **ES-E12-1** [E12] `⌘⇧E` opens a multi-line composer at the bottom of the focused pane; `↩`/`⇧↩` insert newlines and only `⌘↩` sends. — both
- **ES-E12-2** [E12] `⎋` cancels the composer preserving the draft, restored on reopen; the draft survives tab switches. — both
- **ES-E12-3** [E12] `⌘V` in the composer pastes HTML/RTF/image clipboard content as Markdown; `⇧⌘V` pastes plain text. — both
- **ES-E12-4** [E12] Pinning keeps the composer visible across tab switches; float pops it into a non-activating panel (macOS); iOS uses a bottom sheet. — GUI-verifiable
- **ES-E12-5** [E12] `⌘⇧M` opens the prompt queue; `⌥⌘↩` enqueues a draft; chips can be reordered/edited/removed; each fires at the next idle prompt in order. — both

## E13 — Agent integration UI (Claude Code)
- **ES-E13-1** [E13] The Agents settings card installs/uninstalls Claude Code hooks into the host `~/.claude/settings.json` and shows "✓ Installed" / "Not Installed". — both
- **ES-E13-2** [E13] The seven Agent-Behavior toggles (badge×3, notify×2, prevent-sleep, resume-on-recovery) take effect; Prevent-Sleep holds a host power assertion only while the agent processes. — both
- **ES-E13-3** [E13] When an agent completes or awaits input off-screen, a macOS notification posts and the tab badge updates; focusing the tab (or Clear Badge) clears it. — both
- **ES-E13-4** [E13] The agent input footer renders with its notifications / rich-input / file-explorer chips. — GUI-verifiable
- **ES-E13-5** [E13] `⌘⌃↩` captures the selection (or last command output) into a Send-to-Chat dialog where I pick the target agent session, add a comment, and send; the workspace then switches to that agent pane. — both
- **ES-E13-6** [E13] Open a Claude session as a rendered transcript, toggle to raw JSONL, and Resume to jump to the live tab or spawn `claude --resume <id>`. — both
- **ES-E13-7** [E13] After the agent `/branch`es, slopdesk detects the new session and opens it in the split/tab I chose via the palette "Fork in…" entries. — both

## E14 — Progress + notifications + privilege
- **ES-E14-1** [E14] A program emitting OSC 9;4 progress drives a spinner/progress badge instead of being silently filtered; auto-progress wraps known slow commands. — both
- **ES-E14-2** [E14] OSC 9 / 777 / 99 notifications post macOS banners; BEL beeps; the Dock bounces when slopdesk is unfocused per the Notify-While-Foreground policy. — both
- **ES-E14-3** [E14] The Dock icon animates on progress and tints red on a failing session. — GUI-verifiable
- **ES-E14-4** [E14] Privilege toggles (title-report, OSC-52 read/write Ask/Allow/Deny) and the system-permission status row work per their settings. — both

## E15 — Theming + fonts
- **ES-E15-1** [E15] With "use separated dark theme" on, the light slot applies in light mode and the dark slot in dark mode, switching live with OS appearance. — both
- **ES-E15-2** [E15] Dropping a `.slopdesktheme` (or importing iTerm2/Kitty/Alacritty/Ghostty) adds it to the theme list to activate. — both
- **ES-E15-3** [E15] The theme editor edits palette/chrome swatches and Duplicate / Edit / Open-Folder. — GUI-verifiable
- **ES-E15-4** [E15] Set the font family from a picker with specimens, a fallback list, and per-scope (Global/Light/Dark/Fallback) overrides. — GUI-verifiable
- **ES-E15-5** [E15] Line-height modes, ligature levels, and bold/italic/underline/blink/blending settings apply to the rendered terminal. — both

## E16 — Recipes + snippets
- **ES-E16-1** [E16] `⌘S` saves the current tab/window layout as a recipe (layout-only or include-commands) to a `.slopdeskrecipe` file. — both
- **ES-E16-2** [E16] Opening a recipe restores its pane tree and working directories, replaying commands per the chosen mode (Auto/Ask-Once/Manually/Skip), pausing on shell handoffs. — both
- **ES-E16-3** [E16] An unfamiliar recipe file shows its commands before execution with Always-Trust / Run-Once / Cancel; editing it re-prompts. — both
- **ES-E16-4** [E16] Create a text snippet (Name/Alias/Text with `{{date}}`/`{{time}}`/`{{clipboard}}`/`{{cursor}}`); typing its alias at the prompt expands it. — both

## E17 — Read-only + Vi-mode + secure input
- **ES-E17-1** [E17] Toggling Read-Only on a pane shows the `🔒 READ ONLY ×` pill and blocks all input paths (keys/paste/click-to-move/mouse-report/drop) with a beep; output keeps streaming. — both
- **ES-E17-2** [E17] Entering Vi/copy mode shows a pill with the mode and live repeat-count; `⌘/` toggles a key-hint bar. — GUI-verifiable
- **ES-E17-3** [E17] `/` and `?` in Vi mode open the find bar and `n`/`N` step matches; line/block selection and yank work (char-selection documented as a library ceiling). — both
- **ES-E17-4** [E17] When the remote shell enters a hidden-password prompt, Secure Keyboard Entry engages and a SECURE-INPUT title pill appears (per Auto/Indicator settings). — both

## E18 — Drag-drop + tab reorder + web pane
- **ES-E18-1** [E18] Dragging a file over a pane shows New-Tab / Insert-Path / Open-In-Place / Split-Left / Split-Right zones; the hovered zone highlights. — GUI-verifiable
- **ES-E18-2** [E18] Dropping on Insert-Path injects the path into the terminal; dropping a folder on New-Tab `cd`s to it (with a host-resolved-path note). — both
- **ES-E18-3** [E18] Drag a sidebar tab to reorder it with an insertion-line indicator. — both
- **ES-E18-4** [E18] Open a URL in a built-in web pane (WKWebView, non-persistent store, no autoplay). — GUI-verifiable

## E19 — Window options
- **ES-E19-1** [E19] View → Pin Window keeps the window floating above other apps. — GUI-verifiable
- **ES-E19-2** [E19] Window-size = grid opens new windows at `window-cols × window-rows`; = frame uses the pixel dimensions; = remember restores last size. — both
- **ES-E19-3** [E19] The sidebar shows a session list/switcher for switching between multiple sessions. — both
- **ES-E19-4** [E19] Switch to a horizontal (top/bottom) tab-bar layout with auto-hide-tab-bar. — GUI-verifiable

## E20 — CLI parity + watch + first-launch
- **ES-E20-1** [E20] `slopdesk open/view/edit/config/font/theme/keybind/tab/pane/window` drive the running app; `--json` produces structured output. — both
- **ES-E20-2** [E20] `slopdesk watch <cmd>` shows a spinner during execution and a success/error badge on exit (exit codes 0/4/9 for `watch:claude`). — both
- **ES-E20-3** [E20] `slopdesk tab badge --kind <kind>`, `pane capture`, `jump/learn/ignore`, `version`, and `completions <shell>` behave per the CLI reference. — both
- **ES-E20-4** [E20] first-run: set On-Launch behavior, install the CLI, and install Claude Code hooks from a first-launch flow. — GUI-verifiable

## E21 — Remote-window extension first-class
- **ES-E21-1** [E21] The remote-window picker and connect-to-host overlay open from the workspace and create `.remoteGUI` panes. — GUI-verifiable
- **ES-E21-2** [E21] A remote-window pane appears in palette/Open-Quickly results, the sidebar (with status), the status bar, and accepts drag-drop, zoom, and read-only like a terminal pane. — both
- **ES-E21-3** [E21] A remote-window pane can be made floating and renders as a draggable/resizable card in the split container. — GUI-verifiable
- **ES-E21-4** [E21] (dev) Every UI-shell surface treats `.remoteGUI` panes as first-class peers of terminal panes (no special-casing that drops them). — unit-testable
