# Details Panel

## Summary

The Details Panel is a right-side panel that gives context about the focused pane without leaving the terminal — its working directory, what is running, git status, an outline of the content, and a file tree. It always reflects the focused pane, updating as you switch panes or tabs. The panel docks on the right, mirroring the tabs panel on the left. It has four tabs: Info, Outline, Git, and Files. Tab navigation is by click or by bindable commands (unbound by default).

## Behaviors

- The panel is toggled open/closed with ⌘⇧R, View → Toggle Details Panel, or the Toggle Details Panel button in the window title bar (visible on hover).
- The panel docks to the right edge of the window, as a sidebar, mirroring the tabs panel on the left.
- It always reflects the currently focused pane; switching panes or tabs updates all panel content immediately.
- The panel has four tabs at the top: Info, Outline, Git, Files.
- Tabs can be switched by clicking their label icons in the panel header.
- Each tab can also be jumped to directly via the "Details: Info", "Details: Outline", "Details: Git", "Details: Files" commands (bindable under Keybindings; unbound by default).
- **Info tab:** Shows the pane's working directory (path string), a list of running processes (name, PID, uptime), any listening ports ("No listening ports" if none), and quick open-in actions (Copy Path, Reveal in Finder, Open in VS Code, Open in Cursor, Open in Xcode, Open in Typora). For agent panes, also shows agent-specific actions: Copy Session ID, View Session History, Fork in…
- **Outline tab:** A structural map of the focused pane's content. For a terminal or agent pane: lists command marks and agent prompts with timestamps and truncated text. For a file pane: shows table of contents (Markdown/HTML), changed-file list (diff), top-level keys (JSON/YAML/TOML), or transcript prompts (.jsonl).
- **Git tab:** Shows a summary of the pane's git repo: branch name, remote URL (GitHub), commit counts (ahead/behind), a toolbar with Commit and Fork buttons, a list of unstaged changed files with checkboxes and hover actions, and an inline diff viewer that appears as an overlay when a file is selected.
- **Files tab:** Shows a file tree rooted at the focused pane's working directory, with expand/collapse disclosure triangles. Has a Search/Find field at the top. Acts as a quick file browser without needing to open a folder pane.
- The default Git client for the Git tab open-in action is configured via Settings → Controls → Open With.

## Keybindings

| Action | Keys |
|---|---|
| Toggle Details Panel | ⌘⇧R |
| Details: Info | (unbound by default) |
| Details: Outline | (unbound by default) |
| Details: Git | (unbound by default) |
| Details: Files | (unbound by default) |

## Config keys

| Key | Default | Effect |
|---|---|---|
| Settings → Controls → Open With (Git client) | (system default) | Sets which Git client app is used when opening files from the Git tab |

## Visual spec

### info-panel.png — Info Tab

**Overall layout:** The window shows the macOS chrome (traffic lights top-left, title "OpenCode" centered) with a terminal pane taking the left ~75% and the Details Panel occupying the right ~25% as a vertical sidebar. The sidebar has a light gray/off-white background (approximately #F2F2F2 or near-white), clearly separated from the terminal by a thin 1px divider.

**Panel header (top of sidebar):** A row of four icon-buttons spanning the full panel width. From left to right:
1. "Info" tab — active state: label "Info" in small caps next to a circled-i icon, colored in a muted teal/sage accent (approximately #5A9B8F or similar green-teal); the active tab has this accent coloring on both icon and label text.
2. Outline icon (list/lines icon) — inactive, dark gray.
3. Rotate/refresh icon — inactive, dark gray.
4. Folder/files icon — inactive, dark gray.
5. Rightmost: a sidebar-collapse toggle icon (vertical bar + arrow), dark gray.

**Working Directory section:**
- Section label: "Working Directory" in all-caps small text, medium gray, approximately 10–11pt, above the path.
- Path value: "~/Workplace/project" in regular weight dark text (~13pt).
- Below the path: a vertical stack of action rows, each with a small icon (monochrome, ~14pt) on the left and a label on the right:
  - Copy icon + "Copy Path"
  - Folder-open icon + "Reveal in Finder"
  - Square-with-arrow icon + "Open in VS Code"
  - Square-with-arrow icon + "Open in Cursor"
  - Square-with-arrow icon + "Open in Xcode"
  - Square-with-arrow icon + "Open in Typora"
- Action rows use standard text size (~13pt), dark gray text, no background in resting state. Icons are monochrome dark.

**OpenCode section** (agent-specific, appears below the directory actions when the focused pane is an agent pane):
- Section label: "OpenCode" in all-caps small text, medium gray.
- Action rows:
  - Copy icon + "Copy Session ID"
  - Clock/history icon + "View Session History"
  - Fork/branch icon + "Fork in…"

**Process section:**
- Section label: "Process" in all-caps small text, medium gray.
- Each process row: a filled green circle (~6px) dot, process name in bold or medium weight (e.g. "-zsh"), PID number in lighter gray (e.g. "64628"), and elapsed time right-aligned (e.g. "34s").
- Two processes shown: "-zsh 64628  34s" and "opencode 64742  29s". Green dot indicates running/active.

**Ports section:**
- Section label: "Ports" in all-caps small text, medium gray.
- Value: "No listening ports" in regular gray text when empty.

**Spacing and typography:** All section labels use uppercase tracking, ~10pt, muted gray (#999 or similar). Content text is ~13pt, dark (#1A1A1A or similar). Vertical spacing between sections is approximately 16–20px. The panel has ~12–16px horizontal padding on both sides.

**Status bar (bottom of terminal pane, not part of sidebar):** Shows "~/Workplace/project:main" on the left and "1.15.13" on the right in small gray text on a slightly darker bar.

---

### outline-panel.png — Outline Tab

**Overall layout:** Same window chrome. Title bar shows "QC | Reviewing todos". Terminal pane on left (~65% width) shows an agent (OpenCode) session with a conversation turn including a permission dialog ("Permission required / Access external directory…"). Details Panel on the right (~35% width).

**Panel header:** Four tab icons at top. "Outline" tab is active — the list/lines icon is highlighted with a muted teal/green accent color, same style as Info tab active state. Other tabs are gray/inactive.

**Outline tab content:**
- Top entry: "~/Workplace/myproject / 4m ago" — path and relative timestamp in small gray text. Below it: "opencode" in regular dark text (the pane/process name).
- Second entry: "OpenCode — ...iewing todos / 7s ago" — truncated session context with timestamp.
- Third entry: "<system-reminder>Note: The u..." — truncated command mark/prompt text in dark text.
- Fourth entry: "give me more details about The..." — truncated agent prompt text.
- Each entry is a row with the text flush-left and the timestamp right-aligned in gray, stacked vertically with ~1px separator lines or just spacing.
- Selected/active entry may have a subtle highlight background.
- Font size ~12–13pt; timestamps ~11pt gray.

**No section headers** in the Outline tab — it is a flat chronological list of command marks and prompts.

---

### git-panel.png — Git Tab

**Overall layout:** Same window chrome. Title "QC | Reviewing todos". Terminal pane with agent conversation. Details Panel on right is notably wider than in other screenshots (~40% of window width), accommodating a file diff overlay that appears as a floating popover/overlay anchored above the panel content.

**Panel header:** Git tab icon (branch/fork icon) is active, highlighted in muted teal accent.

**Git tab top section:**
- Branch name: "main" in bold/medium dark text, large (~15pt).
- Remote URL: "https://github.com/example-org/project" in small gray text below the branch name.
- Commit delta: "+418 -322" in small gray text, showing ahead/behind or changed lines.
- Toolbar row (right-aligned or full-width below the branch info):
  - "Commit" button: a rounded rectangle button with label "Commit", medium weight.
  - "Fork" button (with a fork icon): another rounded rectangle button.

**Unstaged/changed files list:**
- Section label: "Unstaged (38)" in small uppercase gray label.
- Each file row: checkbox (unchecked square) on the left, filename in dark text, path in smaller gray text. Files appear in a compact list:
  - Examples shown: `_SCREENSHOT_TESTING.md`, `_CLI_SPEC.md`, `.ttng-started/first-launch.md`, `.user/getting-started/tour.md`, `docs/user/index.md`, `docs/hots/first-launch-agents.png`, `features/read-only-mode.md`, `docs/user/vt/osc/osc-0-2.md`, `docs/user/vt/osc/osc-7.md`, `docs/workflows/cli-usage.md`, `.kflows/command-palette.md`, `docs/workflows/outline.md`, `.workspace/drag-and-drop.md`, `.user/workspace/file-pane.md`, `.user/workspace/open-quickly.md`, `reference/files-and-links.md`, `.workspace/folder-pane.md`, `.user/workspace/panes.md`, `.user/workspace/splits.md`, `docs/user/workspace/tabs.md`
  - File rows are compact (~22–24px row height), with small ~11–12pt text.
  - Hover actions (implied by doc: not directly visible in screenshot but described).

**Inline diff viewer (overlay):**
- Appears as a floating card/popover layered over the panel and partially over the terminal.
- Shows a standard unified diff for `docs/spec/CLI_SPEC.md`:
  - File header: `diff --git a/docs/spec/CLI_SPEC.md b/docs/spec/CLI_SPEC.md` etc. in small monospace.
  - Diff lines: removed lines (prefixed `-`) in a light red/pink tint, added lines (prefixed `+`) in light green tint.
  - Hunk header `@@ -968,9 +968,9 @@` in gray/blue.
  - Diff content shows tab badge behavior description in monospace font (~11–12pt).
- The overlay has a white or very light background, rounded corners, subtle drop shadow.

---

### file-panel.png — Files Tab

**Overall layout:** Same window chrome. Title "QC | Reviewing todos". Terminal pane on left showing agent session with a TODO review table. Details Panel on right (~35% width).

**Panel header:** Files tab icon (folder icon) is active, highlighted with muted teal accent.

**Files tab content:**
- **Search field at top:** Full-width input field with placeholder "Find", a small search icon on the left, and two small icon buttons on the right (likely filter/sort/refresh and collapse-all).
- **File tree:** Directory tree rooted at the pane's working directory, using disclosure triangles (▶/▼) for expand/collapse:
  - `> bin` (collapsed)
  - `> build` (collapsed)
  - `> docs` (collapsed)
  - `> packages` (collapsed)
  - `> resources` (collapsed)
  - `▼ scripts` (expanded, showing children):
    - `gen-dmg-v64.dmgCanvas`
    - `gen-dmg.dmgCanvas`
    - `bench-startup.sh`
    - `build-settings-ui.sh`
    - `build-windows.sh`
    - `diagnose-unicode-paste.sh`
    - `full-release.sh`
    - `release.sh`
    - `run.cmd`
    - `run.ps1`
    - `run.sh`
    - `run.sh` (duplicate shown?)
    - `test-panetree.sh`
    - `test-statedb.sh`
    - `verify-links.sh`
  - `▼ skills` (expanded):
    - `update-alacritty`
    - (more items cut off)
- **Tree styling:** Each row is ~22px tall, disclosure triangle is ~8px. Each row carries a leading **type glyph** — an accent/green outline **folder** icon for directories and a muted **doc** icon for files (visible in `file-panel.png`; an earlier draft of this note mis-read them as absent). Indentation ~16px per level. Active/selected rows would show a subtle blue highlight. Text ~12–13pt dark.
- **No "Open" button** — clicking a file presumably opens it or reveals it.

## Screenshots

- `info-panel.png` — Info tab: working directory, process list, ports, open-in actions, agent actions
- `outline-panel.png` — Outline tab: chronological command-mark and agent-prompt list
- `git-panel.png` — Git tab: branch/remote summary, changed-file list, inline diff overlay
- `file-panel.png` — Files tab: search field + expandable file tree

## SlopDesk mapping notes

### What maps 1:1

- **Panel toggle (⌘⇧R):** Can be bound in the existing `WorkspaceBindingRegistry` / keybindings system. The panel lives in the macOS client window chrome, no host involvement.
- **Four tabs (Info / Outline / Git / Files):** Pure client-side UI; all read from the host connection's metadata. Tab switching via click and bindable commands maps directly to SlopDesk's keybindings system.
- **Process list (Info tab):** The host's `slopdesk-hostd` already has PTY/process awareness; surface via an existing or new control-channel message that streams child-process list + uptime. PID is host-side but display is client-side.
- **Outline tab — command marks:** OSC 133 shell integration is already planned/implemented (`OSC-133` in the CLAUDE.md). Command marks from the host PTY stream can be indexed client-side to populate the outline list.
- **Files tab:** Can be populated by asking the host for a directory listing rooted at the current working directory. Already precedented by the remote-window picker pattern (VideoControl types 7/8). Requires a new control-channel RPC: `listDirectory(path:)`.
- **Ports section (Info tab):** Requires the host to emit listening-port information per pane. Can be sourced from `lsof -i` or `ss` on the host and sent over the control channel.
- **Git tab — branch/status:** Requires the host to run `git status --porcelain`, `git branch`, and `git log --oneline origin..HEAD` in the pane's working directory and stream results. This is a pure host-side query with client-side rendering.

### What cannot map 1:1 and why

- **Working directory (Info tab):** The working directory is HOST-side (reported by the remote shell via OSC 7 or by ptrace/proc-fs). SlopDesk already tracks OSC 7 (`OSC 7 — Current Working Directory` in the VT reference). This works, but the PATH shown is always the host's filesystem path, not the client's — must display it clearly as a remote path.
- **"Reveal in Finder" action:** Not applicable for a remote host. Should be replaced with "Copy Path" only, or a "Show in Remote Files" action that opens the path in slopdesk's own file panel. Cannot open macOS Finder on a remote machine.
- **"Open in VS Code / Cursor / Xcode / Typora" actions:** These open local applications on the CLIENT machine, pointing at a REMOTE path. Requires either: (a) a remote-open protocol (VS Code Remote / SSH extension), (b) mounting the remote filesystem via SSHFS first, or (c) omitting these actions until remote-FS support exists. Flag as P2.
- **"Copy Session ID / View Session History / Fork in…" (agent actions, Info tab):** These are agent-pane-specific (OpenCode/Claude Code integration). SlopDesk's `ClaudeStatus`/`ClaudePaneDetector` already exists per memory; wire these to the agent's session metadata from the host. "Fork in…" requires knowing the remote agent's fork API.
- **Git "Commit" / "Fork" toolbar buttons (Git tab):** Executing git commit requires running a command on the HOST. "Fork" opens a native Git client (configured in Settings → Controls → Open With). For slopdesk, the Commit action must either: (a) send a PTY command to the host's terminal, or (b) be omitted (read-only git status view only initially). Flag as P2 (requires host-side command execution beyond PTY).
- **Git inline diff viewer (Git tab):** `git diff` output can be retrieved from the host over the control channel and rendered client-side as a diff view. The diff viewer overlay positioning (floating over the panel) is a client-side layout concern. Maps with effort.
- **Hover actions on file rows (Git tab):** These are purely client-side UI interactions — fully implementable.
- **Files tab — file tree:** Directory listing is a host-side query. Each expand/collapse requires a new RPC call to the host for subdirectory contents, or a full-tree snapshot up to N levels. Implement as lazy loading per directory expand. Fully feasible over the control channel.
- **Files tab — file search ("Find" field):** Requires either client-side filtering of already-fetched tree, or a host-side `find`/`fd` query. Start with client-side filter of fetched subtree; upgrade to host-side search for large trees.
- **iOS client:** The Details Panel is a sidebar; on iOS it should become a modal sheet or a bottom drawer that slides up, since the narrow screen cannot accommodate a persistent right-side panel alongside the terminal.
