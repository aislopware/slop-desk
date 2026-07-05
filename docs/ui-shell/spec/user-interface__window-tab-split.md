# Window, Tab and Split

## Summary

SlopDesk's workspace is a three-level hierarchy: **Window → Tab → Pane**. Window = top-level macOS container; Tab = an independent terminal session in a window; Pane = the leaf content (terminal, file, folder, or URL). Panes split arbitrarily; tabs group/sort/name/badge; windows support pin-above, Picture-in-Picture, and persistent size/restore. Layouts save/restore as "Recipes."

---

## Behaviors

### Window
- Title bar shows the **active tab's name**, which by default tracks the running program via OSC 0 / OSC 2.
- Hovering the window title reveals a toggle for the **Details Panel** (current folder content, git status, processes, command history, or file outline). Also `⌘⇧R`.
- **View → Pin Window** floats the window above all other apps.
- **Picture in Picture** modes:
  - *Current Pane*: a selected pane floats regardless of focus.
  - *Follow Active Pane*: the floating window mirrors the currently active pane.
- Window sizing via `window-size`:
  - `remember` (default): restore previous size/position on reopen.
  - `grid`: exact cell count via `window-cols` × `window-rows` (default 80 × 24).
  - `frame`: literal pixels via `window-width-px` × `window-height-px` (default 1000 × 600).

### Tabs
- Default: **vertical sidebar on the left**. Horizontal bar (top or bottom) via Settings → Appearance → Layout.
- Grouping (vertical layout only): *No Grouping* (default, flat list), *By Project* (by git repo), *By Date* (by last active time).
- Sorting within groups: *Created Time* (default, oldest first), *Updated Time* (most recent first), *Manual* (drag).
- New tab position (`new-tab-position`): `auto` (default, context-aware), `end` (append), `after-current` (after active tab).
- Sidebar auto-hide `auto-hide-tabs-panel`: `default` (no auto-hide), `always` (shown by default), `auto` (hidden when only one tab).
- Horizontal bar auto-hide `auto-hide-tab-bar`: same three values.
- **Rename Tab**: right-click → *Rename Tab…* with two modes — *Name* (fixed name replaces auto title) or *Prefix* (string prepended to the OSC-derived title); reset button (↺) clears to automatic.
- **Tab Badges** — auto status icons on the right edge of each row:
  - Spinner (animated): session busy / command running.
  - Checkmark (green circle ✓): command just finished.
  - Accent dot (filled green circle): command exited 0 in an unattended/background tab.
  - Error triangle (red ⚠): non-zero exit.
  - Hand (🤚): agent waiting for input.
  - Coffee cup: `caffeinate` keeping system awake.
  - Shield: `sudo`/`su` session active.
  - Devices icon: remote SSH session.
- `slopdesk watch <COMMAND>` — wraps a command, driving spinner/checkmark/error badge from its exit status.
- Jump to unread/changed tab: `⌘⇧U`. Toggle tabs sidebar: `⌘⇧L`.

### Split Panes
- A tab splits into panes **side-by-side** or **stacked**.
- **Drag and drop**: drop a pane tab onto any edge of another pane to split above/below/left/right.
- **Resize**: drag the divider; keyboard `⌘⌃⇧` + arrows nudges it.
- **Equalize splits**: double-click the divider border or `⌘⌃=` auto-layouts all panes to similar size.
- **Focus navigation**: `⌘]` / `⌘[` cycle next/previous; `⌘⌃←/→/↑/↓` move focus directionally.

### Open and Close
- **Working directory** per context (New Window / New Tab / New Split Pane) via Settings → Shell → Working Directory:
  - `inherit` ("Same as Current Tab"): reuse current pane's cwd.
  - `home` ("Home"): `$HOME`.
  - Accepts absolute paths.
- **Close confirmation** (Settings → General), set independently for *Closing Tab* and *Closing Window*:
  - `process` ("Running Process"): prompt only when child processes running.
  - `always`: always prompt.
  - `multiple_tabs`: prompt only if the window has multiple tabs.
- **`⌘W` cascades**: closes focused pane; when last pane, closes the tab; when last tab, closes the window.
- **Reopen closed**: `⌘⇧T` restores recently-closed tabs LIFO.

### Save and Restore Layouts (Recipes)
- `⌘S` (File → Save…) saves the layout as a **Recipe** with scope: Current Tab, Current Window, or Commands only.
- Content levels: *Layout Only* (pane tree + cwd), *Include Scrollback* (+ scrollback history), *Include Commands* (+ commands to replay on open).
- Restore via **File → Open Recipe…**

### Quick Navigation
- **Open Quickly** (`⌘⇧O`): fuzzy search across open tabs, panes, recent files, folders.
- **Command Palette** (`⌘⇧P`): all commands by name.

---

## Keybindings

| Action | Keys |
|--------|------|
| New window | `⌘N` |
| Close window | `⌘⇧W` |
| Minimize window | `⌘M` |
| Toggle full screen | `⌘⌃F` |
| New tab | `⌘T` |
| Close focused pane / tab / window (cascade) | `⌘W` |
| Reopen last closed tab | `⌘⇧T` |
| Next tab | `⌘⇧]` |
| Previous tab | `⌘⇧[` |
| Go to tab 1–9 | `⌘1` – `⌘9` |
| Jump to unread tab | `⌘⇧U` |
| Toggle tabs sidebar panel | `⌘⇧L` |
| Toggle details panel | `⌘⇧R` |
| Split right | `⌘D` |
| Split left | `⌘⌥D` |
| Split down | `⌘⇧D` |
| Split up | `⌘⌥⇧D` |
| Focus next pane | `⌘]` |
| Focus previous pane | `⌘[` |
| Focus pane left | `⌘⌃←` |
| Focus pane right | `⌘⌃→` |
| Focus pane up | `⌘⌃↑` |
| Focus pane down | `⌘⌃↓` |
| Move divider left | `⌘⌃⇧←` |
| Move divider right | `⌘⌃⇧→` |
| Move divider up | `⌘⌃⇧↑` |
| Move divider down | `⌘⌃⇧↓` |
| Equalize splits | `⌘⌃=` |
| Open Quickly | `⌘⇧O` |
| Command Palette | `⌘⇧P` |
| Save layout as Recipe | `⌘S` |

---

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `window-size` | `remember` | New-window dimensions. `remember` = restore last size/position; `grid` = exact cell count; `frame` = pixel dimensions. |
| `window-cols` | `80` | Column count when `window-size = grid`. |
| `window-rows` | `24` | Row count when `window-size = grid`. |
| `window-width-px` | `1000` | Width px when `window-size = frame`. |
| `window-height-px` | `600` | Height px when `window-size = frame`. |
| `new-tab-position` | `auto` | New-tab insertion. `auto` = context-aware; `end` = append; `after-current` = after active tab. |
| `auto-hide-tabs-panel` | `default` | Vertical sidebar visibility. `default` = always shown; `always` = shown by default (can hide); `auto` = hidden when only one tab. |
| `auto-hide-tab-bar` | `default` | Horizontal bar visibility. Same three values. |
| `working-directory` (new window) | `home` | `home`, `inherit`, or absolute path. |
| `working-directory` (new tab/split) | `inherit` | `inherit` (same as current pane) or absolute path. |

---

## Visual spec

### workspace-tabs.png — Vertical tab sidebar (default layout)

Window with macOS traffic-light controls top-left; light warm-gray/off-white background (~#F5F4F2), rounded corners, subtle drop shadow, borderless/native look.

**Left sidebar (tabs panel)** — ~155 px wide, same warm-gray:
- Uppercase gray "TABS" label top-left in compact sans-serif; hamburger/filter icon (≡) at the right of the header row.
- Tab rows full-width, ~28 px tall, left-aligned label ~13 pt regular, medium gray (#666).
- **Active tab**: white rounded-rect card behind the label; shell/process name (e.g. `zsh`) in secondary gray at far right.
- Inactive tabs: label only, no highlight, no badge shown.
- Labels use OSC title or path fragment (e.g. `~/Workplace/slopdesk`, `abner@MacBook-AB:...`, `CREDITS.md`).
- Small numeric badge (`#1`, `#2`, `#4`) at right edge in light-gray monospace — shortcut number indicators.
- No border between sidebar and terminal; faint vertical separator.

**Terminal area (right)** — dark background (~#1A1A1A) with monospace rendering (libghostty/Ghostty). Title bar shows the hostname (e.g. `abner@MacBook-AB: ~`) centered.

### workspace-tabs-horizontal.png — Horizontal tab bar

Same macOS frame; **tab bar runs horizontally at the top** of the content area, below the native title bar.

**Horizontal tab bar** — ~36 px tall, light warm-gray (~#EDECE9):
- Tab pills separated by thin vertical gray dividers.
- Each pill shows its label (OSC-derived or set name) ~13 pt regular.
- **Active pill**: white/lighter background, bolder/darker label, inline process indicator (e.g. `[main ●]`) with a colored dot before shell info.
- `+` add-tab button at far right.
- Overflow/scroll affordance may appear if tabs exceed width (not shown).
- Terminal content fills below the bar (dark).

### group-tabs.png — Tab grouping and context menu

Vertical sidebar with 5 tabs; a **right-click context menu** floats over the sidebar with two labeled sections plus an action section:

**GROUP**: "No Grouping" (selected, checkmark); "By Project" (folder icon); "By Date" (calendar icon).
**ORDER**: "Created Time" (clock icon, selected filled-radio); "Updated Time" (clock icon).
**DIVIDER**: "Insert Divider" (divider-line icon); "Remove All Dividers".

Standard macOS popover — white/light, rounded, subtle shadow; rows ~22 px with icon + label; active grouping shows checkmark/filled radio. Terminal area behind shows a two-column split: left = Yazi file browser, right = markdown file list.

### tab-setting.png — Appearance settings panel

macOS Settings window (rounded, drop shadow, light). Left sidebar categories with icons: General (clock), Shell (prompt), Controls (cursor), Editor (document), Integrations (plug), **Appearance** (selected/bold, palette icon, rounded highlight), Recipes (book), Key Bindings (lightning), Advanced (wrench).

Right area, three sections under uppercase gray headers:

**LAYOUT** — three picker cards side by side (~120 px), diagram icon + label:
- *Vertical Tabs* — selected, **blue rounded-rect border**; icon = left strip + content.
- *Tabs Top* — unselected; icon = top bar + content.
- *Tabs Bottom* — unselected; icon = bottom bar + content.

**TABS**:
- "New Tab Position" — label left, dropdown "Auto" (chevron) right.
- "Auto Hide Tabs Panel" — label + subtitle "When to show the tabs panel in Sidebar layout", dropdown "Default" right.

**WINDOW**:
- "Window Size" — label + subtitle "How new windows decide their initial dimensions.", dropdown "Remember last size".

**THEME** header visible at bottom, content cut off.

Rows sit in white rounded-rect cards, inset from the section background.

### title-rename.png — Rename tab/window title dropdown

Context popover over the titlebar:

**Top** — segmented toggle "Name" | "Prefix" (pill-style), reset/undo icon (↺) far right; "Name" selected.
**Text field** — single-line input pre-filled with current name (e.g. "Workspace"), text selected/highlighted blue.
**WORKING DIRECTORY** — current path (e.g. `~/Workplace/slopdesk/`).
**Action rows** (divider-separated): Copy Path; Reveal in Finder; Open in → ; Git → ; Notifications & Privileges (icons); Split View; Find; Find In All Tabs (`⌘F`); Jump to (`⌘J`); Command Palette (`⌘⇧P`).

White background, rounded, system font ~13 pt, shortcut labels right-aligned in lighter gray.

### tab-badge.png — Tab badges

Vertical sidebar, 6 tabs, badge states. Background very light warm-gray/cream (#F5F4F2); rows ~44 px, label ~14–15 pt regular. Top to bottom:
1. **"full-release.sh"** — spinner (gray ring) — *session busy*.
2. **"running build task"** — red error triangle ⚠ — *non-zero exit*.
3. **"plan next move"** — amber hand 🤚 — *agent waiting for input*.
4. **"OpenCode"** — green circle white checkmark ✓ — *command finished successfully (unattended)*.
5. **"abner@MacBook-AB:..."** — small dark-green dot — *accent dot: exit 0 in unattended tab* (subtler than checkmark).
6. **"abner@MacBook-AB:..."** (bottom, **active**) — white rounded-rect card, "zsh" in small gray at far right — *active, idle, no badge*.

Badge icons ~16 px, right-aligned with ~8 px margin. Active card white with shadow/elevation. Inactive text medium gray (#888).

### details-panel.png — Details panel open

Full window: tabs sidebar left (~155 px), wide dark terminal pane center, **Details/Files panel right** (~220 px).

**Right Details panel** — light warm-gray (same family as sidebar):
- "Files" label/icon button top-right of the window (indicates panel toggled).
- Search/filter input at top.
- Collapsible file tree: `dist/`, `node_modules/`, `src/` folder rows with expand triangles; files (e.g. `package-lock.json`, `package.json`, `README.md`, `worker.js`, `wrangler.toml`).
- Folder rows: disclosure triangle left, name medium gray. File rows indented, filename darker gray.
- No left border; blends with window background.

Main terminal shows vitepress dev server output (colored text, timestamps, sync messages).

### open-option.png — Working Directory settings (Settings → Shell)

"WORKING DIRECTORY" section, three rows in a white rounded-rect card:
- **New Window** — dropdown "Home" (chevron).
- **New Tab** — dropdown "Same as Current Tab".
- **New Split Pane** — dropdown "Same as Current Tab".

Uppercase gray section header above card; bold row labels (~14 pt) left; dropdown right (~180 px, white, bordered, label + chevron); no row icons; ~44 px per row.

### close-confirm.png — Close Confirmation settings (Settings → General)

"CLOSE CONFIRMATION" section, two rows in a white rounded-rect card:
- **Closing Tab** — dropdown "Running Process" (chevron).
- **Closing Window** — dropdown "Running Process".

Same treatment as open-option.png: uppercase header, white card, bold labels left, dropdowns right (~200 px).

---

## Screenshots

- `workspace-tabs.png`
- `workspace-tabs-horizontal.png`
- `group-tabs.png`
- `tab-setting.png`
- `title-rename.png`
- `tab-badge.png`
- `details-panel.png`
- `open-option.png`
- `close-confirm.png`

---

## Implementation notes

### Already implemented or straightforward

- **Window→Tab→Pane hierarchy**: slopdesk already has a `Session → Tab → Pane` (`PaneKind`) tree in `WorkspaceStore`; three levels map directly.
- **Tab keybindings** (`⌘T`, `⌘W`, `⌘D`, `⌘⇧D`, `⌘]`/`[`, etc.): register in the existing `WorkspaceBindingRegistry` + prefix key system.
- **Vertical sidebar tab list**: existing left sidebar; tab row (label + badge + active card) maps to existing `TabRow` / `SidebarView`.
- **Tab badges**: spinner/checkmark/dot/error/hand/shield/SSH/coffee map to states slopdesk tracks (OSC-133 command tracking, Claude agent state, `sudo` detection, SSH detection via `SLOPDESK_SYSTEM_DIALOG_PANES`). Implement as a `TabBadge` enum in `WorkspaceStore`.
- **Split panes**: `NSSplitView` live-resize exists; equalize (`⌘⌃=`) and directional focus (`⌘⌃←/→/↑/↓`) need wiring.
- **Tab grouping (By Project / By Date)**: git grouping via per-pane `cwd` + `git rev-parse --show-toplevel` for a project key. Date grouping trivial.
- **Rename tab (Name / Prefix)**: `WorkspaceStore` pane model holds optional `fixedName` and `titlePrefix`; OSC 0/2 handler prepends prefix if set.
- **⌘W cascade**: extend existing pane-close to check `isLastPaneInTab` and `isLastTabInWindow`.
- **`⌘⇧T` reopen**: `recentlyClosedTabStack` in `WorkspaceStore`; push on close, pop on `⌘⇧T`.
- **Open Quickly (`⌘⇧O`)**: wire the existing fzf-backed `SearchMixer` to tabs/panes/recent-files.
- **`auto-hide-tabs-panel`**: sidebar `isVisible` toggle exists; add a single-tab auto-hide policy check on tab-count change.
- **Config keys**: backed by `PreferencesStore` / `Defaults`-backed `SettingsKey`.
- **Close confirmation (Running Process / Always)**: query child process count via `TIOCGPGRP` / `ps` on the PTY.
- **`slopdesk watch <CMD>` badge driver**: implemented (`WatchProgress`, `HostOutputSniffer` → `ProgressOSCParser` → `ProgressState`, `WorkspaceStore+Progress`) — emits exit-status badge/notification via OSC 9;4, consumed by existing OSC-133 / block-output detection.

### Partial — needs additional work

- **`new-tab-position`** (`after-current` / `end` / `auto`): `WorkspaceStore.reconcile()` currently appends; insertion-after-current needs an index-aware insert. Medium.
- **Tab sorting (Created / Updated / Manual drag)**: tabs are in insertion order; add `createdAt`/`updatedAt` + drag-reorder via a `TabOrder` model. Medium.
- **Details Panel (git status, processes, file outline, command history)**: file-tree exists; git status and process list need per-pane async queries; the `⌘⇧R` toggle + titlebar hover-reveal are new UX. Medium-to-high.
- **Recipes (save/restore layouts)**: no layout persistence beyond `DetachedSessionStore`; full Recipe serialization (pane tree + cwd + optional scrollback/commands) is a new subsystem. High effort; design the schema in `DECISIONS.md` first.

### Architectural constraints / open design questions

- **Picture in Picture (PiP)**: macOS PiP is a system AVFoundation/PlayerLayer video feature. The slopdesk client sees a **decoded HEVC stream** from host, so true PiP for a terminal pane would pipe that stream into an `AVPictureInPictureController` — possible but needs careful `SlopDeskVideoClient` decoder-output integration. **Not in scope for initial implementation**; a simpler always-on-top window via `NSWindow.level = .floating` approximates the Current Pane mode.
- **Host-side cwd detection**: `lsof`/`proc_pidvnodepathinfo` only read a *local* process cwd, but slopdesk terminals are **remote**; read cwd via the existing `SLOPDESK_AGENT_CONTROL` NDJSON channel or an OSC 7 (`file://host/path`) sequence from the shell. OSC 7 is standard — add it to the shell integration shim.
- **SSH badge**: a local `ps` for a child ssh only makes sense on a local terminal, but every slopdesk session is remote; the badge would mean a *nested* SSH from within the remote shell. Detect an `ssh` child of the PTY via the NDJSON control channel or an OSC-133 command prefix.
- **Drag-and-drop pane rearrangement**: panes render as `NSSplitView` subviews with live video streams. Reorder must swap `WorkspaceStore` positions and re-bind `TerminalSurface` **without** tearing down the video session (memory note: "mount all tabs opacity-0, never tear down surface"). Feasible but non-trivial. Medium-high.
- **Manual tab sort via drag**: same surface concern — sidebar drag must update `WorkspaceStore` order without a session teardown.
