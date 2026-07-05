# First Launch

## Summary

Four things worth setting up the first time you open SlopDesk. All of them live in **Settings** (`⌘,`) — no config files required:

1. Set Launch and New Tab / Window Options
2. Set as Default Terminal
3. Install the SlopDesk CLI (and skip the `slopdesk` prefix)
4. Change Theme
5. Install Agent Integration

---

## Behaviors

### 1. Launch and New Tab / Window Options

- **On Launch** setting (Settings → General) controls what happens when the app opens.
  - Recommended value: `Restore Last Session` — restores scrollback history and resumes code agents (claude, codex) automatically on next launch.
  - Alternative value: `New Window` — opens a fresh empty window.
- **Working Directory** setting (Settings → Shell → Working Directory) controls whether the cwd is inherited when opening a new window, tab, or split view.

### 2. Set as Default Terminal

macOS has no single "default terminal" setting; two separate integration points must be configured:

- **System default** — registers SlopDesk as the OS handler for `.command` / `.tool` / `.sh` file double-clicks in Finder, `open script.sh` from the command line, and `man://` / `ssh://` URL scheme opens.
  - Action: Settings → General → OS Integration → click **Set as Default Terminal**.
- **Editors & git GUIs** — most editors (VS Code, Cursor, Windsurf, Sublime Text, etc.) and git GUIs hardcode Terminal.app or iTerm.app and ignore the system handler. SlopDesk rewrites their per-app config to launch SlopDesk instead.
  - Action: Settings → General → OS Integration → click **Configure…** next to "Set as Default Terminal for Common Apps".
  - Apps not installed on the system are skipped automatically.
  - Any per-app override can be reverted from the same dialog.
- **Finder Integration** — adds "Open in SlopDesk" to Finder's right-click Services menu for folders. Enable or rebind in System Settings → Keyboard → Keyboard Shortcuts → Services. Button shown: **Open System Settings**.
- **Full Disk Access** — needed when commands run inside SlopDesk need to read/write protected files (mounting DMGs, reading `~/Library`, scripting Mail/Messages, etc.). SlopDesk itself works without it. Button shown: **Open System Settings**.

### 3. Install the SlopDesk CLI

The `slopdesk` command drives the app from any shell — open files in a pane, jump to recent folders, watch a long-running command, etc. It ships inside the app bundle but is not on `PATH` until installed.

Settings → Shell → SlopDesk CLI:

- **Install CLI** — adds `/usr/local/bin/slopdesk`; requests admin privileges once.
- **Omit `slopdesk` Prefix** — toggle ON causes shells launched by SlopDesk to get plain `edit`, `view`, `watch`, `jump`, and `learn` as shell functions, so you can type `edit foo.txt` instead of `slopdesk edit foo.txt`.
- **Allow Overwrite** — leave OFF unless you already have your own `edit`/`view`/etc. shell functions and want SlopDesk to replace them.

CLI quick usage:

```sh
slopdesk jump Workspace   # jump to folder, like Zoxide or autojump
slopdesk view readme.md   # view file directly in SlopDesk window
slopdesk watch build.sh   # run and watch script, show notification when done

# When "Omit `slopdesk` Prefix" is enabled:
jump Workspace
view readme.md
watch build.sh
```

### 4. Change Theme

Two ways to change theme:

1. **Command Palette flow**: Open Command Palette (`⌘⇧P`), type `themes`, press Enter → themes list appears as a floating panel with a search field. Use arrow up / arrow down to switch between themes with live preview. Press Enter to apply.
2. **Settings flow**: Settings → Appearance → Theme — shows a grid of theme thumbnails (light themes, then dark themes). Also allows editing theme colors, fonts, paddings, etc.

Available themes visible in screenshots:
- Light: April, Ayu Light, Floating Card, Glass Light, Newsprint, One Light, Paper, Pink, Solarized Light
- Dark: April Dark, Ayu Dark, Catppuccin M…, Dracula (and others)

### 5. Install Agent Integration

Supported agents: Claude Code, Codex, OpenCode.

Settings → Agents:

- For each agent you use, click **Install** in its card. This writes a small hook config:
  - Claude Code → `~/.claude/`
  - Codex → `~/.codex/`
  - OpenCode → `~/.config/opencode/plugins/`
  - The hook lets the agent stream its live state back to SlopDesk.
- Click **Uninstall** from the same card at any time; this cleanly reverts the config files.

Under **Agent Behavior** (Settings → Agents → Agent Behavior section):

- **Badge While Processing** (default ON) — show tab badge while an agent is running a task.
- **Badge When Task Completes** (default ON) — show tab badge when an agent finishes a task.
- **Badge When Awaiting Input** (default ON) — show tab badge when an agent is waiting for approval or input.
- **Notify When Task Completes** (default ON) — show a macOS notification when an agent finishes a task.
- **Notify When Awaiting Input** (default ON) — show a macOS notification when an agent is waiting for approval or input.
- **Prevent Sleep While Processing** (default OFF) — keep macOS awake while an agent is running a task.
- **Resume Session on Recovery** (default ON) — automatically resume agent session when recovering a terminal.

The Agents settings pane also has a **CLAUDE CODE** subsection at the bottom (partially visible), containing **Install Hooks**.

---

## Keybindings

| Action | Keys |
|---|---|
| Open Settings | `⌘,` |
| Open Command Palette | `⌘⇧P` (Command + Shift + P) |
| Navigate theme list up/down | `↑` / `↓` (arrow keys) |
| Apply selected theme | `Enter` |

---

## Config Keys

| Key / Setting | Default | Effect |
|---|---|---|
| **On Launch** (Settings → General) | `New Window` (recommended: `Restore Last Session`) | What SlopDesk does when the app opens: start fresh or restore last session with scrollback and agent state |
| **Quit When All Windows Closed** (Settings → General) | (visible in screenshot, value not shown) | Whether the app quits when the last window is closed |
| **Closing Tab** (Settings → General → Close Confirmation) | `Running Process` | When to prompt before closing a tab |
| **Closing Window** (Settings → General → Close Confirmation) | `Running Process` | When to prompt before closing a window |
| **Auto Update** (Settings → General → Update) | OFF | Check for new releases in background and prompt to install |
| **Working Directory** (Settings → Shell) | (inherited) | Whether new windows/tabs/splits inherit the cwd of the current pane |
| **Install CLI** (Settings → Shell → SlopDesk CLI) | Not installed | Adds `/usr/local/bin/slopdesk` to PATH; one-time admin prompt |
| **Omit `slopdesk` Prefix** (Settings → Shell → SlopDesk CLI) | OFF | Exposes `edit`, `view`, `watch`, `jump`, `learn` as bare shell functions in SlopDesk-launched shells |
| **Allow Overwrite** (Settings → Shell → SlopDesk CLI) | OFF | Whether prefix-less functions overwrite existing user-defined functions of the same name |
| **Default Terminal** (Settings → General → OS Integration) | Not set | Registers SlopDesk as the system URL/file handler for terminal launches |
| **Set as Default Terminal for Common Apps** (Settings → General → OS Integration) | Not configured | Rewrites per-app config for VS Code, Cursor, Windsurf, Sublime Text, etc. to open SlopDesk |
| **Finder Integration** (Settings → General → OS Integration) | Inactive | Adds "Open in SlopDesk" to Finder right-click Services menu |
| **Full Disk Access** (Settings → General → OS Integration) | Not granted | Grants SlopDesk permission to read/write protected system files |
| **Badge While Processing** (Settings → Agents → Agent Behavior) | ON | Show tab badge while agent is running |
| **Badge When Task Completes** (Settings → Agents → Agent Behavior) | ON | Show tab badge when agent task finishes |
| **Badge When Awaiting Input** (Settings → Agents → Agent Behavior) | ON | Show tab badge when agent awaits input/approval |
| **Notify When Task Completes** (Settings → Agents → Agent Behavior) | ON | macOS notification when agent finishes |
| **Notify When Awaiting Input** (Settings → Agents → Agent Behavior) | ON | macOS notification when agent awaits input |
| **Prevent Sleep While Processing** (Settings → Agents → Agent Behavior) | OFF | Prevents macOS sleep while agent is running |
| **Resume Session on Recovery** (Settings → Agents → Agent Behavior) | ON | Automatically resumes agent session after terminal recovery |

---

## Visual Spec

### first-launch.png — Initial SlopDesk window on first launch

**Overall layout:** A light macOS window with rounded corners and a drop shadow. Two-column layout: narrow left sidebar and wide right terminal area, separated by a 1px hairline divider.

**Sidebar (left column, ~27% width):**
- Top-left: standard macOS traffic-light buttons (red/yellow/green, ~12px circles) at approximately y=70px.
- Below traffic lights: a section label "TABS" in small-caps, light gray (`#AAAAAA` approx), with a hamburger/list icon on the far right of the same row (three horizontal lines, gray).
- Single tab row: label "abner@MacBook-AB: ~" in regular-weight dark text (not bold), flush left. Right side shows the keyboard shortcut badge "⌘1" in a lighter gray. The tab row has a slightly darker background than the sidebar (white card on light gray sidebar, with a subtle rounded rectangle or inset highlight). No close button visible on the tab — clean, minimal.
- Sidebar background: very light warm gray, approximately `#F2F1EF`.

**Terminal area (right column):**
- Background: near-white, approximately `#F7F7F5` (slightly off-white, warm).
- Window title bar centered: "abner@MacBook-AB: ~" in medium gray, system-font size ~13pt.
- Terminal content area: at top-left of the terminal, a small prompt line is visible — tilde `~` in green, followed by a green right-facing triangle play button icon `▶`, followed by a blinking cursor bar `|` in dark/black. Very sparse — this is a fresh shell with no prior output.
- No status bar visible at bottom.
- No toolbar buttons in terminal area.

**Typography:** System font (SF Pro or similar), ~13pt. Sidebar label "TABS" is uppercase small-caps, ~10pt, light gray. Tab label is ~13pt regular weight.

**Spacing:** Sidebar is compact; the tab row has ~8px vertical padding. No visible borders on the tab item other than the subtle background differentiation.

---

### launch-option.png — Settings → General showing On Launch dropdown

**Overall layout:** macOS Settings/Preferences window style. Left sidebar for navigation (~30% width), right content area (~70% width). Light theme. Rounded corners, drop shadow.

**Left sidebar:**
- Traffic-light buttons top-left (red active/colored, yellow and gray/inactive — window is NOT in focus, so they show as gray circles with the red being the close button).
- Search bar at top: rounded rectangle with magnifier icon, placeholder "Search", light gray background.
- Navigation items listed vertically with icons and labels:
  - `⊙ General` — currently selected, highlighted with a medium gray background fill on the row (~`#E5E5E5`), bold or slightly heavier weight text.
  - `>_ Shell`
  - `▷ Controls`
  - `📄 Editor`
  - `⚡ Integrations`
  - `🎨 Appearance`
  - `📖 Recipes`
  - `⚡ Key Bindings`
  - `🔧 Advanced`
  - Each row has a small icon on the left (~16px) and label text in regular weight.

**Right content area:**
- Section header "GENERAL" in small-caps gray, ~11pt, at top.
- Settings rows, each spanning full width with label on left and control on right:
  - **Language**: label left, dropdown control right showing "English ↓" (rounded rectangle button with chevron).
  - **Shell**: label left, value "System Default (zsh)" in gray on right (read-only text).
  - **On Launch**: label left, dropdown showing "Restore Last Session ↓" — and this dropdown is currently OPEN, showing two options in a floating menu:
    - "New Window" (not selected)
    - "Restore Last Session" (highlighted/selected — shown with blue or darker highlight). The dropdown floats just below the control.
  - **Quit When All Windows Closed**: label visible, control off-screen or at bottom.
- Section header "CLOSE CONFIRMATION":
  - **Closing Tab**: label left, dropdown "Running Process ↓" right.
  - **Closing Window**: label left, dropdown "Running Process ↓" right.
- Section header "UPDATE":
  - **Auto Update**: label left with description text ("Check for new releases in the background and prompt to install when one is available."), toggle OFF (gray) on the right.

**Typography:** Section headers in uppercase small-caps ~10pt gray. Row labels ~13pt regular. Control values ~13pt in darker gray or black.

**Colors:** White background in content area. Sidebar items have gray background on selection. Dropdown appears white with standard macOS popup styling.

---

### first-launch-default-terminal.png — Settings → General → OS Integration section

**Overall layout:** Same Settings window as launch-option.png. Left sidebar identical (General selected). Right content area scrolled down to show OS INTEGRATION section.

**Right content area shows:**

Top (continuation from previous scroll position):
- **Auto Update** row: label + description "Check for new releases in the background and prompt to install when one is available." + toggle OFF (gray).
- **Check Update** row: label + sub-label "Current version: 1.0.0" + button **"Check Now"** (rounded rectangle, light gray background).

Section header "OS INTEGRATION" in uppercase small-caps gray.

Three feature rows in this section, each with label, description text, and a button on the right:

1. **Default Terminal**
   - Label: "Default Terminal" (bold)
   - No description text
   - Button right: **"Set as Default Terminal"** (rounded rectangle, light border)

2. **Set as Default Terminal for Common Apps**
   - Label: "Set as Default Terminal for Common Apps" (bold)
   - Description: "macOS has no real default-terminal concept — most editors and git GUIs hardcode Terminal.app. Rewrites each known third-party app's external-terminal setting so it opens SlopDesk instead."
   - Button right: **"Configure…"** (rounded rectangle, light border)

3. **Finder Integration**
   - Label: "Finder Integration" (bold)
   - Description: "Adds 'Open in SlopDesk' to Finder's right-click Services menu for folders. Enable or rebind in System Settings → Keyboard → Keyboard Shortcuts → Services."
   - Button right: **"Open System Settings"** (rounded rectangle, light border)

4. **Full Disk Access**
   - Label: "Full Disk Access" (bold)
   - Description: "Needed when commands run inside SlopDesk have to read or write protected files — mounting DMGs, reading `~/Library`, scripting Mail/Messages, etc. SlopDesk itself works without it."
   - Button right: **"Open System Settings"** (rounded rectangle, light border)

**Button styling:** All action buttons in this section use a consistent style — rounded rectangle, approximately 130-160px wide, white/light background with a 1px border (~`#D0D0D0`), dark text, no fill color (not destructive or primary). Standard macOS borderless button look.

**Row structure:** Each row in the OS Integration section is taller than General rows because it contains a multi-line description. Description text is ~11pt gray, subordinate to the bold label.

---

### theme-list.png — Theme picker floating panel (Command Palette flow)

**Overall layout:** A terminal window (dark theme — the full app is running in a dark theme) with a floating modal panel centered/overlaid. The terminal background shows an `eza -la` output with file listings.

**Floating theme picker panel:**
- Position: centered-ish, appearing as a rounded rectangle overlay over the terminal.
- Background: white/light, floating above the dark terminal content.
- Width: approximately 300-340px. Height: fits ~10 visible theme rows plus a search bar.
- Top: search field — placeholder text "Search themes…" with a magnifier icon.
- Below search: a scrollable list of theme rows. Each row contains:
  - Theme name label (left, ~13pt regular)
  - Three color dot swatches on the right (~8px filled circles) — showing representative colors from the theme's palette (e.g. blue, green, red dots).
  - Currently selected/highlighted row shows a subtle background highlight.
- Visible themes in order: April, Ayu Light, Floating Card, Glass Light, Newsprint, One Light, Paper, Pink, Solarized Light.
- All visible themes in this screenshot are LIGHT themes.

**Color swatches:** Each row's right side shows 3 small circles. Colors vary per theme and serve as quick visual identification (not a full preview).

**Background terminal (behind the panel):**
- Dark/moody theme active on the terminal itself.
- Left sidebar: tabs panel showing several tab items with partial names ("Debug sorting order is…", "Fix cursor state chang…", "abner@MacBook-AB: ~/…", "Fix OSC 4 DOR-index f…", "Implement tab navigati…", "abner@MacBook-AB: ~/…" — this last one appears active/selected with a slightly different background).
- Tab count badges visible on the right of tab rows (⌘1, ⌘2, etc.).
- Terminal content: `eza -la` directory listing with colored output.

---

### change-theme.png — Settings → Appearance → Theme (grid view)

**Overall layout:** Settings window opened to the Appearance section, with the terminal visible behind it (dark theme active in the main app). The Settings window uses a light background.

**Left sidebar (Settings navigation):**
- Standard nav items visible, **Appearance** is selected (highlighted with gray background).

**Right content area — Theme grid:**
- Section label: "THEME" in uppercase small-caps gray at top.
- Below: a grid of theme thumbnail cards, 4 columns wide.
- Each card is a small rounded rectangle showing a miniature preview of the theme as it would look in a terminal window (mini screenshots showing color palette, text colors, background). Below each card is a label with the theme name.
- Visible light themes (top row): April, Ayu-Light, Floating Card, Glass Light
- Second row (light): Newsprint, One Light, Paper, Pink
- Third row (starts light, continues): Solarized Light, then dark themes begin
- Dark themes visible: April Dark, Ayu Dark, Catppuccin M…, Dracula
- The selected theme is indicated by a subtle visual state on one of the cards (possibly a checkmark or border — not clearly distinguishable in this screenshot scale).

**Theme card size:** approximately 80×60px each, with the miniature terminal preview inside.

**Spacing:** Cards have ~8px gap between them. The grid is left-aligned within the content area.

---

### first-launch-agents.png — Settings → Agents → Agent Behavior section

**Overall layout:** Same Settings window structure. Left sidebar with **Agents** selected. Right content area showing AGENT BEHAVIOR toggle list and CLAUDE CODE subsection.

**Left sidebar:** Standard nav items. "Agents" is selected — row has gray background highlight, icon is a plug/connector symbol.

**Right content area — Agent Behavior:**
- Section header "AGENT BEHAVIOR" in uppercase small-caps gray.
- Seven toggle rows, each with:
  - Bold label (left)
  - Description text below label (~11pt gray, subordinate)
  - Toggle switch on the far right (green = ON, gray = OFF)

Toggle rows and their states:

| Label | Description | State |
|---|---|---|
| Badge While Processing | Show tab badge while an agent is running a task | ON (green) |
| Badge When Task Completes | Show tab badge when an agent finishes a task | ON (green) |
| Badge When Awaiting Input | Show tab badge when an agent is waiting for approval or input | ON (green) |
| Notify When Task Completes | Show a notification when an agent finishes a task | ON (green) |
| Notify When Awaiting Input | Show a notification when an agent is waiting for approval or input | ON (green) |
| Prevent Sleep While Processing | Keep macOS awake while an agent is running a task | OFF (gray) |
| Resume Session on Recovery | Automatically resume agent session when recovering a terminal | ON (green) |

- Section header "CLAUDE CODE" visible at the very bottom of the visible area.
- Below it: "Install Hooks" label partially visible — this is the per-agent install card.

**Toggle styling:** iOS-style toggle switches. ON state: solid green (`#34C759` approx). OFF state: solid gray (~`#D1D1D6` approx). Toggle is ~51×31px, right-aligned.

**Row height:** Each toggle row is taller than a simple label row — approximately 60-70px — because it includes both label and description.

---

## Screenshots

- `first-launch.png` — SlopDesk main window on first launch (light theme, single tab, empty shell)
- `launch-option.png` — Settings → General with On Launch dropdown open showing two options
- `first-launch-default-terminal.png` — Settings → General → OS Integration section showing Default Terminal, Configure…, Finder Integration, Full Disk Access buttons
- `theme-list.png` — Theme picker floating panel over dark terminal (Command Palette flow)
- `change-theme.png` — Settings → Appearance → Theme grid with thumbnail cards
- `first-launch-agents.png` — Settings → Agents → Agent Behavior toggle list with Claude Code subsection

---

## SlopDesk Mapping Notes

### What maps 1:1

- **Tab bar with agent state badges** — SlopDesk already has `ClaudeStatus`/`ClaudePaneDetector`/`AgentControlListener` (per MEMORY.md). The badge states (running/awaiting input/task complete) map directly onto existing infrastructure; wire them to tab badge rendering in the tab bar.
- **On Launch: Restore Last Session** — SlopDesk has `DetachedSessionStore` (`SLOPDESK_DETACH_ENABLED`) and scrollback; "restore last session" behavior is achievable via detach/reattach on app launch.
- **Working Directory inheritance** — for local panes this is straightforward; for remote panes it requires the host-side cwd (host knows cwd via `OSC 7` or direct PTY inquiry). Cwd is observable from the host side — no fundamental blocker, but it's host-driven, not client-side.
- **Command Palette** — SlopDesk has a Command Palette already. The theme-list-in-palette flow (type "themes", navigate with arrows, preview live, enter to apply) can be implemented using the existing palette + `ThemeStore`.
- **Theme grid in Settings / Appearance** — SlopDesk already has `ThemeStore` with Monokai Pro and other themes. A grid thumbnail view in Settings is achievable.
- **Agent hook installation for Claude Code** — the hook writes to `~/.claude/`; this is a local-machine concern. Since SlopDesk runs on the user's local Mac (client), the Settings → Agents → Install Hooks action writes config to the local `~/.claude/` and is fully applicable.

### What requires adaptation (remote architecture)

- **Default Terminal (OS-level handler)** — SlopDesk can register itself as the system default for `.command`/`.sh`/`man://`/`ssh://` for local shell launches, but the remote session aspect means some of these (e.g., `ssh://` links) may open a remote connection rather than a local one. Flag for product decision: should clicking an `ssh://` link open a remote pane into that host via SlopDesk's transport, or fall back to local Terminal?
- **"Set as Default Terminal for Common Apps"** — rewrites config files for VS Code, Cursor, etc. to launch SlopDesk instead of Terminal.app. This makes sense for local editors (client-side Mac). However, if the user's editor is running on the remote host, the config rewrite must happen on the remote host — not the local client. This cannot map 1:1 without a host-side agent or SSH-mediated rewrite. For MVP: only offer this for local editors.
- **Finder Integration ("Open in SlopDesk")** — adds a Services menu item. Fully achievable for client-local Finder. The opened folder would need to map to either a local pane or a remote SSH pane; the routing decision is SlopDesk-specific.
- **Full Disk Access** — client-local macOS TCC permission. Applicable as-is since the SlopDesk client runs on the user's Mac. The remote host side has its own permission model (SSH credentials, sudo) which is separate.
- **Prevent Sleep While Processing** — `NSProcessInfo.processInfo.beginActivity(...)` call; straightforward on the macOS client. No remote-side involvement.
- **Resume Session on Recovery** — maps to `DetachedSessionStore` + `SLOPDESK_DETACH_ENABLED`. Already exists; expose toggle in Settings → Agents.
- **Notify When Task Completes / Awaiting Input** — macOS `UserNotifications` framework on the client. Achievable but the agent state must be streamed from the remote host through SlopDesk's transport (OSC or control channel). `AgentControlListener` already handles this path.
- **Install CLI (`/usr/local/bin/slopdesk` equivalent)** — SlopDesk has `slopdesk-ctl` and related CLIs. A "Install CLI" button in Settings that symlinks `/usr/local/bin/slopdesk` is directly applicable.
- **Omit prefix / shell functions** — injecting shell functions (`edit`, `view`, `watch`, `jump`) into shells launched by SlopDesk applies only to the LOCAL client shell (or the remote shell via the host's shell init). For remote shells, the functions must be injected on the host side via the PTY session's shell rc/profile. Medium complexity.

### Cannot map 1:1 (flag for product decision)

- **"Restore Last Session" with remote agent auto-resume** — Because the agent (claude, codex) process runs on the remote host, not locally, "auto-resume" on launch means reconnecting the remote PTY and re-attaching to the detached session where the agent was running — not restarting a local process. This is architecturally different from a local resume: the agent never paused — it kept running on the host. The UX of "auto-resume" is actually just "reconnect to the still-running detached session." This is possible via `DetachedSessionStore`, but the framing/UX should make clear the agent was NEVER paused.
- **Codex / OpenCode hook installation** — writes to `~/.codex/` and `~/.config/opencode/plugins/`. For slopdesk-initial scope (Claude Code only), skip these. Mark as future work.
