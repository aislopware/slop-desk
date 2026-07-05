# Window, Tab and Split

## Summary

SlopDesk structures its workspace as a three-level hierarchy: **Window → Tab → Pane**. A window is the top-level macOS container; a tab is an independent terminal session housed within a window; a pane is the leaf — the actual content you interact with (a terminal, file, folder, or URL). Panes can be split arbitrarily, tabs can be grouped/sorted/named/badged, and windows support pin-above, Picture-in-Picture, and persistent size/restore. Layouts can be saved and restored as "Recipes."

---

## Behaviors

### Window
- The window title bar shows the **active tab's name**, which by default dynamically tracks the running program via OSC 0 / OSC 2 sequences.
- Hovering over the window title reveals a toggle button that opens the **Details Panel** (shows current folder content, git status, processes, command history, or file outline). Toggled via `⌘⇧R`.
- **View → Pin Window** keeps the window floating above all other apps' windows.
- **Picture in Picture** modes:
  - *Current Pane*: shows a selected pane in a floating window regardless of focus.
  - *Follow Active Pane*: the floating window mirrors whichever pane is currently active.
- Window sizing is controlled by the `window-size` setting:
  - `remember` (default): restores the previous window's size and position on reopen.
  - `grid`: sizes the window to an exact cell count via `window-cols` × `window-rows` (defaults 80 × 24).
  - `frame`: uses literal pixel dimensions via `window-width-px` × `window-height-px` (defaults 1000 × 600).

### Tabs
- Default layout is a **vertical sidebar on the left** containing tab entries. Horizontal tab bar (top or bottom) is available via Settings → Appearance → Layout.
- Tabs can be grouped (vertical layout only):
  - *No Grouping* (default): one flat list.
  - *By Project*: grouped by git repository.
  - *By Date*: grouped by last active time.
- Sorting within groups:
  - *Created Time* (default): oldest-opened first.
  - *Updated Time*: most recently active first.
  - *Manual*: set by dragging tabs.
- New tab position (`new-tab-position`):
  - `auto` (default): context-aware placement.
  - `end`: always appends to the end of the tab list.
  - `after-current`: inserts immediately after the active tab.
- Sidebar auto-hide: `auto-hide-tabs-panel` — `default` (no auto-hide), `always` (shown by default), `auto` (hidden when only one tab).
- Horizontal bar auto-hide: `auto-hide-tab-bar` — same three values.
- **Rename Tab**: right-click a tab → *Rename Tab…* dialog with two modes:
  - *Name*: a fixed name that replaces the automatic title.
  - *Prefix*: a string prepended to the automatic (OSC-derived) title.
  - A reset button (↺) clears back to automatic.
- **Tab Badges** — automatic status icons shown on the right edge of each tab row:
  - Spinner (animated): session is busy / command running.
  - Checkmark (green circle ✓): command just finished.
  - Accent dot (filled green circle): command exited successfully (exit 0) in an unattended/background tab.
  - Error triangle (red ⚠): non-zero exit status.
  - Hand (🤚): agent waiting for input.
  - Coffee cup: `caffeinate` is keeping the system awake.
  - Shield: `sudo`/`su` session is active.
  - Devices icon: remote SSH session.
- `slopdesk watch <COMMAND>` — wraps a command and drives spinner/checkmark/error badge based on its exit status.
- Jump to unread/changed tab: `⌘⇧U`.
- Toggle the tabs sidebar panel: `⌘⇧L`.

### Split Panes
- A tab can be split into multiple panes **side-by-side** or **stacked** (above/below).
- **Drag and drop** rearranges panes: drop a pane tab onto any edge of another pane to split above/below/left/right.
- **Resize**: drag the divider between panes. Keyboard: `⌘⌃⇧` + arrow keys to nudge the divider.
- **Equalize splits**: double-click the divider border OR `⌘⌃=` auto-layouts all panes to similar size.
- **Focus navigation**:
  - `⌘]` / `⌘[`: cycle to next / previous pane.
  - `⌘⌃←/→/↑/↓`: move focus in the indicated direction.

### Open and Close
- **Working directory** for new views is controlled per context (New Window / New Tab / New Split Pane) via Settings → Shell → Working Directory:
  - `inherit` ("Same as Current Tab"): reuses the current pane's working directory.
  - `home` ("Home"): starts at `$HOME`.
  - Accepts absolute paths.
- **Close confirmation** (Settings → General → Close Confirmation), set independently for *Closing Tab* and *Closing Window*:
  - `process` ("Running Process"): prompt only when child processes are running.
  - `always`: always prompt before closing.
  - `multiple_tabs`: prompt only if the window has multiple tabs.
- **`⌘W` cascades**: closes the focused pane first; once that is the tab's last pane it closes the tab; once that is the window's last tab it closes the window.
- **Reopen closed**: `⌘⇧T` restores recently-closed tabs as a stack (LIFO).

### Save and Restore Layouts (Recipes)
- `⌘S` (File → Save…) saves the current layout as a **Recipe** with scope:
  - Current Tab
  - Current Window
  - Commands only
- Content levels:
  - *Layout Only*: pane tree and working directories.
  - *Include Scrollback*: layout plus scrollback history.
  - *Include Commands*: all of the above plus commands to replay on open.
- Restore via **File → Open Recipe…**

### Quick Navigation
- **Open Quickly** (`⌘⇧O`): fuzzy search across open tabs, panes, recent files, and folders.
- **Command Palette** (`⌘⇧P`): access all commands by name.

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
| `window-size` | `remember` | How new windows decide initial dimensions. `remember` = restore last size/position; `grid` = exact cell count; `frame` = pixel dimensions. |
| `window-cols` | `80` | Column count when `window-size = grid`. |
| `window-rows` | `24` | Row count when `window-size = grid`. |
| `window-width-px` | `1000` | Width in pixels when `window-size = frame`. |
| `window-height-px` | `600` | Height in pixels when `window-size = frame`. |
| `new-tab-position` | `auto` | Where newly opened tabs are inserted. `auto` = context-aware; `end` = append to list; `after-current` = after active tab. |
| `auto-hide-tabs-panel` | `default` | When to show the vertical sidebar tab panel. `default` = always shown; `always` = shown by default (can hide); `auto` = hidden when only one tab. |
| `auto-hide-tab-bar` | `default` | When to show the horizontal tab bar. Same three values as above. |
| `working-directory` (new window) | `home` | Working directory for new windows (`home`, `inherit`, or absolute path). |
| `working-directory` (new tab/split) | `inherit` | Working directory for new tabs and split panes (`inherit` = same as current pane, or absolute path). |

---

## Visual spec

### workspace-tabs.png — Vertical tab sidebar (default layout)

The window has macOS traffic-light controls (red/yellow/green) in the top-left. The overall window uses a very light warm-gray/off-white background (#F5F4F2 approximate) with rounded corners and a subtle drop shadow; it looks borderless / native macOS.

**Left sidebar (tabs panel)** — approximately 155 px wide, same warm-gray background as the window:
- A small uppercase gray label "TABS" at the top-left, in a compact sans-serif, with a hamburger/filter menu icon (≡) at the right of that header row.
- Tab rows are full-width, each ~28 px tall, left-aligned label text in regular weight (~13 pt), medium gray (#666).
- The **active tab** is shown with a white rounded-rect card (white pill/row highlight) behind the label text, and the shell/process name (e.g. `zsh`) appears in a secondary gray at the far right of that row.
- Inactive tabs have no background highlight — just the label text in medium gray, with no badge visible in this screenshot.
- Tab labels use the OSC-set title or a path fragment (e.g. `~/Workplace/slopdesk`, `abner@MacBook-AB:...`, `CREDITS.md`).
- A small numeric badge (e.g. `#1`, `#2`, `#4`) appears at the right edge of each tab row, rendered in a small monospace font, very light gray — these appear to be shortcut number indicators.
- No border line between sidebar and terminal area; the two regions meet at a faint vertical separator.

**Terminal area (right)** — occupies the remainder of the window, dark background (#1A1A1A approximate, near-black) with a monospace terminal rendering (libghostty/Ghostty). The title bar shows the connected hostname (e.g. `abner@MacBook-AB: ~`) centered in the macOS title bar.

### workspace-tabs-horizontal.png — Horizontal tab bar

The window uses the same macOS frame with traffic-light controls. The **tab bar runs horizontally at the top** of the content area, below the native macOS title bar.

**Horizontal tab bar** — approximately 36 px tall, light warm-gray background (#EDECE9 approximate):
- Tab pills are separated by a thin vertical gray line divider.
- Each tab pill shows its label text (OSC-derived or set name) in regular weight, ~13 pt.
- The **active tab** pill has a white or slightly lighter background, bolder/darker label text, and displays a small process indicator (e.g. `[main ●]`) inline within the label — using a small colored dot before the shell info.
- A `+` add-tab button appears at the far right end of the tab bar.
- An overflow/ellipsis or scroll affordance may appear if tabs exceed width (not shown).
- The terminal content fills the entire area below the tab bar — dark terminal background.

### group-tabs.png — Tab grouping and context menu

Vertical sidebar layout with 5 tabs visible. A **right-click context menu** (or hamburger menu) is shown floating over the sidebar, with two labeled sections and one action section:

**GROUP section** (small uppercase gray label):
- "No Grouping" — selected (radio/checkmark implied by bold or checkmark state; checkmark visible)
- "By Project" — with a folder-like icon
- "By Date" — with a calendar-like icon

**ORDER section**:
- "Created Time" — with a clock icon (currently selected, indicated by a filled circle radio button)
- "Updated Time" — with a clock icon

**DIVIDER section**:
- "Insert Divider" — with a divider-line icon
- "Remove All Dividers"

The menu is a standard macOS-style popover/context menu with white/light background, rounded corners, subtle shadow. Each row is ~22 px tall with icon + label. The currently-active grouping has a visible checkmark or filled radio circle.

Behind the menu, the sidebar shows tab labels in the same compact style. The terminal area shows a two-column split: left column is a file browser / directory listing (Yazi), right shows a list of markdown files.

### tab-setting.png — Appearance settings panel

A macOS Settings/Preferences window (rounded corners, drop shadow, light background). Left sidebar shows categories with icons:
- General (clock icon)
- Shell (terminal prompt icon)
- Controls (cursor arrow icon)
- Editor (document icon)
- Integrations (plug icon)
- **Appearance** (selected, bold, paint palette icon, with a light rounded-rect highlight)
- Recipes (book icon)
- Key Bindings (lightning bolt icon)
- Advanced (wrench icon)

**Right content area** has three labeled sections separated by uppercase gray section headers:

**LAYOUT** section: three layout picker cards side by side, each ~120 px wide, with a diagram icon inside and a label below:
- *Vertical Tabs* — selected, shown with a **blue rounded-rect border** around the card. The icon shows a left vertical strip (sidebar) plus content area.
- *Tabs Top* — unselected, gray border implied. Icon shows a top horizontal bar + content.
- *Tabs Bottom* — unselected. Icon shows a bottom horizontal bar + content.

**TABS** section:
- "New Tab Position" row — label left, dropdown button "Auto" with chevron (↓) right-aligned.
- "Auto Hide Tabs Panel" row — label left (with subtitle "When to show the tabs panel in Sidebar layout" in small gray), dropdown "Default" with chevron right-aligned.

**WINDOW** section:
- "Window Size" row — label left (with subtitle "How new windows decide their initial dimensions."), dropdown "Remember last size" with chevron.

**THEME** section header visible at the bottom, content cut off.

All rows sit inside a white rounded-rect card with subtle border, inset from the section background.

### title-rename.png — Rename tab/window title dropdown

A context menu/popover appears over the titlebar area, showing:

**Top of popover** — two segmented tab buttons: "Name" | "Prefix" (pill-style toggle), with a reset/undo icon (↺) at the far right. "Name" tab appears selected.

**Text field** — below the toggle, a single-line text input pre-filled with the current name (e.g. "Workspace"), with the text selected/highlighted in blue.

**WORKING DIRECTORY** subsection — shows the current directory path (e.g. `~/Workplace/slopdesk/`).

**Action rows** below — the same dropdown also shows additional context menu items separated by dividers:
- Copy Path
- Reveal in Finder
- Open in → (submenu arrow)
- Git → (submenu arrow)
- Notifications & Privileges (with icons)
- Split View
- Find
- Find In All Tabs (`⌘F` or similar shortcut shown at right)
- Jump to (`⌘J`)
- Command Palette (`⌘⇧P`)

The popover has a white background, rounded corners, uses system font ~13 pt, keyboard shortcut labels right-aligned in a lighter gray.

### tab-badge.png — Tab badges

Vertical tab sidebar shown with 6 tabs, demonstrating different badge states. The sidebar background is a very light warm-gray/cream (#F5F4F2). Tab rows are ~44 px tall, label text ~14–15 pt regular weight:

From top to bottom:
1. **"full-release.sh"** — spinner badge (animated loading indicator, gray ring) at the right edge — *session busy*.
2. **"running build task"** — red error triangle ⚠ badge — *non-zero exit status*.
3. **"plan next move"** — orange/amber hand emoji (🤚) badge — *agent waiting for input*.
4. **"OpenCode"** — green filled circle with white checkmark ✓ badge — *command finished successfully (unattended)*.
5. **"abner@MacBook-AB:..."** — small filled dark green dot badge — *accent dot: command exited 0 in unattended tab* (subtler than the checkmark).
6. **"abner@MacBook-AB:..."** (bottom, **active/selected** tab) — white rounded-rect card behind the label, with "zsh" in small gray text at the far right — *active tab, idle, no badge*.

Badge icons are ~16 px, right-aligned to the sidebar edge with ~8 px right margin. The active tab card is white with a visible shadow/elevation. Inactive tab text is in medium gray (#888).

### details-panel.png — Details panel open

The full window is visible with the tabs sidebar on the left (~155 px), a wide main terminal pane in the center (dark background), and a **Details / Files panel on the right** (~220 px wide).

**Right Details panel** — light warm-gray background, same family as the sidebar:
- A "Files" label or icon button is shown in the top-right corner of the window (indicating this panel is toggled).
- A small search/filter input at the top of the panel.
- A collapsible file tree below — showing `dist/`, `node_modules/`, `src/` folder rows with expand triangles, and individual files (e.g. `package-lock.json`, `package.json`, `README.md`, `worker.js`, `wrangler.toml`).
- Folder rows have a disclosure triangle at left, folder name in medium gray.
- File rows are indented, filename in darker gray.
- The panel has no border line at its left edge — it blends with the window background.

The main terminal shows vitepress dev server output (colored text, timestamps, sync messages).

### open-option.png — Working Directory settings (Settings → Shell)

A settings sub-panel showing the "WORKING DIRECTORY" section with three rows in a white rounded-rect card:
- **New Window** — dropdown "Home" with chevron (↓).
- **New Tab** — dropdown "Same as Current Tab" with chevron.
- **New Split Pane** — dropdown "Same as Current Tab" with chevron.

The section header "WORKING DIRECTORY" is in uppercase small gray sans-serif above the card. Each row label is in bold (~14 pt) on the left; the dropdown button is on the right, ~180 px wide, white with a border, label + chevron. No icon on rows. Spacing is ~44 px per row, comfortable padding.

### close-confirm.png — Close Confirmation settings (Settings → General)

A settings sub-panel showing the "CLOSE CONFIRMATION" section with two rows in a white rounded-rect card:
- **Closing Tab** — dropdown "Running Process" with chevron (↓).
- **Closing Window** — dropdown "Running Process" with chevron.

Same visual treatment as open-option.png: uppercase section header in small gray, white card, bold row labels left, dropdown buttons right (~200 px wide).

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

- **Window→Tab→Pane hierarchy**: slopdesk already has a `Session → Tab → Pane` (`PaneKind`) tree in `WorkspaceStore`. The three levels map directly.
- **Tab keybindings** (`⌘T`, `⌘W`, `⌘D`, `⌘⇧D`, `⌘]`/`[`, etc.): slopdesk has a `WorkspaceBindingRegistry` + prefix key system. These bindings can be registered there.
- **Vertical sidebar tab list**: the current client design system already implements a left sidebar. The tab row visual (label + badge + optional card highlight for active) maps to the existing `TabRow` / `SidebarView` components.
- **Tab badges**: the badge types (spinner, checkmark, dot, error, hand, shield, SSH, coffee) map to detectable shell/process states slopdesk already tracks (OSC-133 command tracking, Claude agent state, `sudo` detection, SSH session detection via `SLOPDESK_SYSTEM_DIALOG_PANES`). Implemented as a `TabBadge` enum in `WorkspaceStore`.
- **Split panes**: `NSSplitView`-based live-resize already exists in slopdesk; equalize (`⌘⌃=`) and directional focus (`⌘⌃←/→/↑/↓`) need wiring.
- **Tab grouping (By Project / By Date)**: the git-repo grouping is straightforward since slopdesk tracks `cwd` per pane and can call `git rev-parse --show-toplevel` to derive a project key. Date grouping is trivial.
- **Rename tab (Name / Prefix modes)**: `WorkspaceStore` pane model can hold an optional `fixedName` and optional `titlePrefix`; the OSC 0/2 handler prepends prefix if set.
- **⌘W cascade**: current slopdesk `⌘W` already closes panes; extend to check `isLastPaneInTab` and `isLastTabInWindow` to cascade.
- **`⌘⇧T` reopen**: keep a `recentlyClosedTabStack` in `WorkspaceStore`, push on close, pop on `⌘⇧T`.
- **Open Quickly (`⌘⇧O`)**: slopdesk has a fzf-backed `SearchMixer`; wire it to tabs/panes/recent-files.
- **`auto-hide-tabs-panel`**: the sidebar `isVisible` toggle is already implemented; add a `single-tab = auto-hide` policy check on tab-count change.
- **Config keys** (`window-size`, `window-cols`, `window-rows`, etc.): backed by `PreferencesStore` / `Defaults`-backed `SettingsKey` values.
- **Close confirmation (Running Process / Always)**: slopdesk can query child process count via `TIOCGPGRP` / `ps` on the PTY.
- **`slopdesk watch <CMD>` badge driver**: implemented (`WatchProgress`, `HostOutputSniffer` → `ProgressOSCParser` → `ProgressState`, `WorkspaceStore+Progress`) — wraps a command and emits exit-status badge/notification via the OSC 9;4 progress protocol, consumed by slopdesk's existing OSC-133 / block-output detection.

### Partial — needs additional work

- **`new-tab-position`** (`after-current` / `end` / `auto`): `WorkspaceStore.reconcile()` currently appends tabs; insertion-after-current needs an index-aware insert path. Medium effort.
- **Tab sorting (Created / Updated / Manual drag)**: tabs are currently in insertion order. Adding `createdAt`/`updatedAt` timestamps and drag-reorder requires a `TabOrder` model. Medium effort.
- **Details Panel (git status, processes, file outline, command history)**: the file-tree view exists (Files panel). Git status and process list require per-pane async queries. The panel toggle `⌘⇧R` and the hover-reveal on titlebar are new UX surface. Medium-to-high effort.
- **Recipes (save/restore layouts)**: slopdesk has no layout persistence beyond `DetachedSessionStore`. Implementing full Recipe serialization (pane tree + cwd + optional scrollback/commands) is a new subsystem. High effort; design the schema in `DECISIONS.md` first.

### Architectural constraints / open design questions

- **Picture in Picture (PiP)**: macOS PiP is a system AVFoundation/PlayerLayer feature normally used for video. On slopdesk, the client sees a **decoded video stream** (HEVC from host), so true PiP for floating a terminal pane above other apps would need to pipe that stream into an `AVPictureInPictureController`. Possible in principle but requires careful integration with `SlopDeskVideoClient`'s decoder output. Flag as **not in scope for the initial implementation**; a simpler "always-on-top window" via `NSWindow.level = .floating` is a viable approximation for the Current Pane mode.
- **Host-side cwd detection**: reading a shell's `cwd` directly via `lsof`/`proc_pidvnodepathinfo` only works for a *local* process. SlopDesk's terminal runs on a **remote host**; `cwd` must be read via the existing `SLOPDESK_AGENT_CONTROL` NDJSON channel or an OSC 7 (`file://host/path`) sequence emitted by the shell. OSC 7 is the standard approach — add it to the shell integration shim.
- **SSH badge (remote session indicator)**: a local `ps` query for a child SSH process only makes sense on a local terminal. In slopdesk every session IS remote; the "remote" badge would need a different semantic — e.g., badge for a *nested* SSH from within the remote shell. Approach: detect `ssh` child of the PTY via the NDJSON control channel or OSC-133 command prefix.
- **Drag-and-drop pane rearrangement**: slopdesk panes are rendered as `NSSplitView` subviews with live video streams. Drag-to-reorder panes without tearing down and recreating the video session is the architectural constraint (memory note: "mount all tabs opacity-0, never tear down surface"). Reordering requires swapping `WorkspaceStore` pane positions and re-binding the `TerminalSurface` without destroying it — feasible but non-trivial. Medium-high effort.
- **Manual tab sort via drag**: same surface concern; the sidebar tab list drag must update `WorkspaceStore` order without triggering a session teardown.
