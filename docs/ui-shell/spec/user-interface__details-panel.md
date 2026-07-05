# Details Panel

## Summary

A right-side sidebar giving context about the focused pane without leaving the terminal: working directory, running processes, git status, content outline, and file tree. Always reflects the focused pane, updating on pane/tab switch. Docks right, mirroring the tabs panel on the left. Four tabs — Info, Outline, Git, Files — switched by click or bindable commands (unbound by default).

## Behaviors

- Toggled open/closed with ⌘⇧R, View → Toggle Details Panel, or the Toggle Details Panel title-bar button (visible on hover).
- Docks to the window's right edge as a sidebar, mirroring the left tabs panel.
- Always reflects the focused pane; switching panes/tabs updates all content immediately.
- Four header tabs: Info, Outline, Git, Files. Switch by clicking their label icons, or jump directly via the "Details: Info/Outline/Git/Files" commands (bindable under Keybindings; unbound by default).
- **Info tab:** working directory (path string), running processes (name, PID, uptime), listening ports ("No listening ports" if none), and open-in actions (Copy Path, Reveal in Finder, Open in VS Code, Open in Cursor, Open in Xcode, Open in Typora). Agent panes also show: Copy Session ID, View Session History, Fork in…
- **Outline tab:** structural map of pane content. Terminal/agent pane → command marks and agent prompts with timestamps and truncated text. File pane → table of contents (Markdown/HTML), changed-file list (diff), top-level keys (JSON/YAML/TOML), or transcript prompts (.jsonl).
- **Git tab:** repo summary — branch name, remote URL (GitHub), ahead/behind commit counts, a toolbar with Commit and Fork buttons, a list of unstaged changed files with checkboxes and hover actions, and an inline diff viewer shown as an overlay when a file is selected.
- **Files tab:** file tree rooted at the focused pane's working directory, with expand/collapse disclosure triangles and a Search/Find field. A quick file browser without opening a folder pane.
- Default Git client for the Git tab open-in action is set via Settings → Controls → Open With.

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
| Settings → Controls → Open With (Git client) | (system default) | Which Git client app opens files from the Git tab |

## Visual spec

### info-panel.png — Info Tab

**Layout:** macOS chrome (traffic lights top-left, title "OpenCode" centered); terminal pane left ~75%, Details Panel right ~25% as a vertical sidebar. Sidebar background light gray/off-white (~#F2F2F2/near-white), separated from the terminal by a 1px divider.

**Panel header:** four icon-buttons spanning full width, left to right:
1. "Info" tab — active: label "Info" in small caps beside a circled-i icon, muted teal/sage accent (~#5A9B8F); active tab accents both icon and label.
2. Outline icon (list/lines) — inactive, dark gray.
3. Rotate/refresh icon — inactive, dark gray.
4. Folder/files icon — inactive, dark gray.
5. Rightmost: sidebar-collapse toggle (vertical bar + arrow), dark gray.

**Working Directory section:**
- Label "Working Directory" — all-caps, medium gray, ~10–11pt.
- Path "~/Workplace/project" — regular dark text, ~13pt.
- Action rows (small ~14pt monochrome dark icon + label, no resting background, ~13pt dark gray text): Copy → "Copy Path", Folder-open → "Reveal in Finder", Square-with-arrow → "Open in VS Code" / "Open in Cursor" / "Open in Xcode" / "Open in Typora".

**OpenCode section** (agent-specific; below directory actions when the focused pane is an agent pane):
- Label "OpenCode" — all-caps, medium gray.
- Rows: Copy → "Copy Session ID", Clock/history → "View Session History", Fork/branch → "Fork in…".

**Process section:**
- Label "Process" — all-caps, medium gray.
- Each row: filled green ~6px dot, process name (bold/medium, e.g. "-zsh"), PID (lighter gray, e.g. "64628"), elapsed time right-aligned (e.g. "34s"). Green dot = running.
- Two rows: "-zsh 64628  34s" and "opencode 64742  29s".

**Ports section:**
- Label "Ports" — all-caps, medium gray.
- Value "No listening ports" in regular gray when empty.

**Spacing/typography:** section labels uppercase-tracked, ~10pt, muted gray (~#999). Content ~13pt, dark (~#1A1A1A). Section spacing ~16–20px. Panel horizontal padding ~12–16px.

**Status bar** (bottom of terminal pane, not sidebar): "~/Workplace/project:main" left, "1.15.13" right — small gray text on a slightly darker bar.

---

### outline-panel.png — Outline Tab

**Layout:** same chrome; title "QC | Reviewing todos". Terminal pane left (~65%) shows an OpenCode agent session with a permission dialog ("Permission required / Access external directory…"). Details Panel right (~35%).

**Panel header:** "Outline" tab active — list/lines icon highlighted muted teal/green (same active style as Info). Others gray/inactive.

**Content** (flat chronological list of command marks and prompts, no section headers):
- "~/Workplace/myproject / 4m ago" — path + relative timestamp, small gray; below it "opencode" (pane/process name), regular dark.
- "OpenCode — ...iewing todos / 7s ago" — truncated session context + timestamp.
- "<system-reminder>Note: The u..." — truncated command mark/prompt, dark.
- "give me more details about The..." — truncated agent prompt.
- Each row: text flush-left, timestamp right-aligned gray, stacked with ~1px separators or spacing. Selected/active entry may have a subtle highlight. Text ~12–13pt; timestamps ~11pt gray.

---

### git-panel.png — Git Tab

**Layout:** same chrome; title "QC | Reviewing todos". Terminal pane with agent conversation. Details Panel notably wider (~40% of window) to fit a file diff overlay floating above the panel content.

**Panel header:** Git tab icon (branch/fork) active, muted teal accent.

**Top section:**
- Branch "main" — bold/medium dark, ~15pt.
- Remote URL "https://github.com/example-org/project" — small gray below branch.
- Commit delta "+418 -322" — small gray (ahead/behind or changed lines).
- Toolbar: "Commit" button (rounded rect, medium weight); "Fork" button (rounded rect + fork icon).

**Unstaged/changed files list:**
- Label "Unstaged (38)" — small uppercase gray.
- Each row: unchecked checkbox, filename (dark), path (smaller gray). Compact ~22–24px rows, ~11–12pt text. Examples: `_SCREENSHOT_TESTING.md`, `_CLI_SPEC.md`, `.ttng-started/first-launch.md`, `.user/getting-started/tour.md`, `docs/user/index.md`, `docs/hots/first-launch-agents.png`, `features/read-only-mode.md`, `docs/user/vt/osc/osc-0-2.md`, `docs/user/vt/osc/osc-7.md`, `docs/workflows/cli-usage.md`, `.kflows/command-palette.md`, `docs/workflows/outline.md`, `.workspace/drag-and-drop.md`, `.user/workspace/file-pane.md`, `.user/workspace/open-quickly.md`, `reference/files-and-links.md`, `.workspace/folder-pane.md`, `.user/workspace/panes.md`, `.user/workspace/splits.md`, `docs/user/workspace/tabs.md`. Hover actions described in doc, not visible in screenshot.

**Inline diff viewer (overlay):** floating card/popover layered over the panel and partially over the terminal; white/very-light background, rounded corners, subtle drop shadow. Standard unified diff for `docs/spec/CLI_SPEC.md`:
- File header `diff --git a/docs/spec/CLI_SPEC.md b/docs/spec/CLI_SPEC.md` etc., small monospace.
- Removed lines (`-`) light red/pink tint, added lines (`+`) light green tint.
- Hunk header `@@ -968,9 +968,9 @@` gray/blue.
- Content (tab badge behavior) in monospace ~11–12pt.

---

### file-panel.png — Files Tab

**Layout:** same chrome; title "QC | Reviewing todos". Terminal pane left shows an agent session with a TODO review table. Details Panel right (~35%).

**Panel header:** Files tab icon (folder) active, muted teal accent.

**Content:**
- **Search field (top):** full-width input, placeholder "Find", search icon left, two small icon buttons right (likely filter/sort/refresh and collapse-all).
- **File tree:** rooted at the pane's working directory, disclosure triangles (▶/▼):
  - `> bin`, `> build`, `> docs`, `> packages`, `> resources` (collapsed)
  - `▼ scripts` (expanded): `gen-dmg-v64.dmgCanvas`, `gen-dmg.dmgCanvas`, `bench-startup.sh`, `build-settings-ui.sh`, `build-windows.sh`, `diagnose-unicode-paste.sh`, `full-release.sh`, `release.sh`, `run.cmd`, `run.ps1`, `run.sh`, `run.sh` (duplicate shown?), `test-panetree.sh`, `test-statedb.sh`, `verify-links.sh`
  - `▼ skills` (expanded): `update-alacritty`, (more cut off)
- **Styling:** ~22px rows, ~8px disclosure triangle. Each row has a leading **type glyph** — accent/green outline **folder** icon for directories, muted **doc** icon for files (visible in `file-panel.png`; an earlier draft mis-read them as absent). Indentation ~16px/level. Active/selected rows show a subtle blue highlight. Text ~12–13pt dark.
- **No "Open" button** — clicking a file presumably opens or reveals it.

## Screenshots

- `info-panel.png` — Info tab: working directory, process list, ports, open-in actions, agent actions
- `outline-panel.png` — Outline tab: chronological command-mark and agent-prompt list
- `git-panel.png` — Git tab: branch/remote summary, changed-file list, inline diff overlay
- `file-panel.png` — Files tab: search field + expandable file tree

## SlopDesk mapping notes

### What maps 1:1

- **Panel toggle (⌘⇧R):** bind in the existing `WorkspaceBindingRegistry` / keybindings system. Panel lives in the macOS client window chrome, no host involvement.
- **Four tabs (Info / Outline / Git / Files):** pure client-side UI reading from the host connection's metadata. Click + bindable-command switching maps directly to SlopDesk's keybindings.
- **Process list (Info tab):** `slopdesk-hostd` already has PTY/process awareness; surface via a control-channel message streaming child-process list + uptime. PID host-side, display client-side.
- **Outline tab — command marks:** OSC 133 shell integration already planned/implemented (`OSC-133`). Command marks from the host PTY stream can be indexed client-side to populate the list.
- **Files tab:** populate by asking the host for a directory listing rooted at cwd. Precedented by the remote-window picker (VideoControl types 7/8). Needs a new control-channel RPC `listDirectory(path:)`.
- **Ports section (Info tab):** host emits listening-port info per pane, sourced from `lsof -i` or `ss`, sent over the control channel.
- **Git tab — branch/status:** host runs `git status --porcelain`, `git branch`, `git log --oneline origin..HEAD` in the pane's cwd and streams results. Pure host-side query, client-side rendering.

### What cannot map 1:1 and why

- **Working directory (Info tab):** cwd is HOST-side (remote shell via OSC 7 or ptrace/proc-fs). SlopDesk already tracks OSC 7. Works, but the path is always the host's filesystem path, not the client's — must display clearly as a remote path.
- **"Reveal in Finder":** N/A for a remote host (can't open macOS Finder remotely). Replace with "Copy Path" only, or a "Show in Remote Files" action opening the path in slopdesk's own file panel.
- **"Open in VS Code / Cursor / Xcode / Typora":** open local CLIENT apps pointing at a REMOTE path. Needs either (a) a remote-open protocol (VS Code Remote / SSH extension), (b) mounting the remote FS via SSHFS first, or (c) omitting until remote-FS support exists. P2.
- **"Copy Session ID / View Session History / Fork in…" (agent, Info tab):** agent-pane-specific (OpenCode/Claude Code). SlopDesk's `ClaudeStatus`/`ClaudePaneDetector` already exist; wire to the agent's session metadata from the host. "Fork in…" needs the remote agent's fork API.
- **Git "Commit" / "Fork" (Git tab):** commit requires running a command on the HOST; "Fork" opens a native Git client (Settings → Controls → Open With). For slopdesk, Commit must either (a) send a PTY command to the host terminal, or (b) be omitted (read-only git status view initially). P2 (needs host-side command execution beyond PTY).
- **Git inline diff viewer (Git tab):** retrieve `git diff` from the host over the control channel, render client-side. Overlay positioning (floating over the panel) is a client-side layout concern. Maps with effort.
- **Hover actions on file rows (Git tab):** purely client-side UI — fully implementable.
- **Files tab — file tree:** directory listing is host-side. Each expand/collapse needs an RPC for subdirectory contents, or a full-tree snapshot up to N levels. Implement as lazy loading per expand. Fully feasible over the control channel.
- **Files tab — file search ("Find"):** client-side filtering of the fetched tree, or a host-side `find`/`fd` query. Start with client-side filter; upgrade to host-side search for large trees.
- **iOS client:** the sidebar becomes a modal sheet or bottom drawer that slides up, since the narrow screen cannot fit a persistent right-side panel alongside the terminal.
