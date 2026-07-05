# First Launch

## Summary

Worth setting up the first time you open SlopDesk. All live in **Settings** (`⌘,`) — no config files:

1. Set Launch and New Tab / Window Options
2. Set as Default Terminal
3. Install the SlopDesk CLI (and skip the `slopdesk` prefix)
4. Change Theme
5. Install Agent Integration

---

## Behaviors

### 1. Launch and New Tab / Window Options

- **On Launch** (Settings → General): what happens when the app opens.
  - `Restore Last Session` (recommended) — restores scrollback history and resumes code agents (claude, codex) automatically on next launch.
  - `New Window` — fresh empty window.
- **Working Directory** (Settings → Shell → Working Directory): whether cwd is inherited when opening a new window, tab, or split view.

### 2. Set as Default Terminal

macOS has no single "default terminal"; two integration points must be configured:

- **System default** — registers SlopDesk as OS handler for `.command`/`.tool`/`.sh` double-clicks in Finder, `open script.sh` from CLI, and `man://`/`ssh://` URL opens. Settings → General → OS Integration → **Set as Default Terminal**.
- **Editors & git GUIs** — most editors (VS Code, Cursor, Windsurf, Sublime Text, etc.) and git GUIs hardcode Terminal.app/iTerm.app and ignore the system handler; SlopDesk rewrites their per-app config to launch itself. Settings → General → OS Integration → **Configure…** next to "Set as Default Terminal for Common Apps". Uninstalled apps skipped automatically; any override revertable from the same dialog.
- **Finder Integration** — adds "Open in SlopDesk" to Finder's right-click Services menu for folders. Enable/rebind in System Settings → Keyboard → Keyboard Shortcuts → Services. Button: **Open System Settings**.
- **Full Disk Access** — needed when commands run inside SlopDesk read/write protected files (mounting DMGs, reading `~/Library`, scripting Mail/Messages, etc.). SlopDesk itself works without it. Button: **Open System Settings**.

### 3. Install the SlopDesk CLI

The `slopdesk` command drives the app from any shell — open files in a pane, jump to recent folders, watch a long-running command, etc. Ships inside the app bundle but not on `PATH` until installed.

Settings → Shell → SlopDesk CLI:

- **Install CLI** — adds `/usr/local/bin/slopdesk`; requests admin privileges once.
- **Omit `slopdesk` Prefix** — ON exposes plain `edit`, `view`, `watch`, `jump`, `learn` as shell functions in SlopDesk-launched shells (type `edit foo.txt` instead of `slopdesk edit foo.txt`).
- **Allow Overwrite** — leave OFF unless you already have your own `edit`/`view`/etc. functions and want SlopDesk to replace them.

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

Two ways:

1. **Command Palette flow**: `⌘⇧P`, type `themes`, Enter → floating panel with search field. Arrow up/down switches themes with live preview; Enter applies.
2. **Settings flow**: Settings → Appearance → Theme — grid of thumbnails (light themes, then dark). Also edits theme colors, fonts, paddings, etc.

Available themes (screenshots):
- Light: April, Ayu Light, Floating Card, Glass Light, Newsprint, One Light, Paper, Pink, Solarized Light
- Dark: April Dark, Ayu Dark, Catppuccin M…, Dracula (and others)

### 5. Install Agent Integration

Supported agents: Claude Code, Codex, OpenCode.

Settings → Agents:

- Click **Install** in an agent's card to write its hook config (lets the agent stream live state back to SlopDesk):
  - Claude Code → `~/.claude/`
  - Codex → `~/.codex/`
  - OpenCode → `~/.config/opencode/plugins/`
- **Uninstall** from the same card cleanly reverts the config files.

Under **Agent Behavior** (Settings → Agents → Agent Behavior section):

- **Badge While Processing** (default ON) — tab badge while an agent runs a task.
- **Badge When Task Completes** (default ON) — tab badge when an agent finishes a task.
- **Badge When Awaiting Input** (default ON) — tab badge when an agent awaits approval/input.
- **Notify When Task Completes** (default ON) — macOS notification when an agent finishes a task.
- **Notify When Awaiting Input** (default ON) — macOS notification when an agent awaits approval/input.
- **Prevent Sleep While Processing** (default OFF) — keep macOS awake while an agent runs a task.
- **Resume Session on Recovery** (default ON) — auto-resume agent session when recovering a terminal.

The pane also has a **CLAUDE CODE** subsection at the bottom (partially visible) with **Install Hooks**.

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
| **On Launch** (Settings → General) | `New Window` (recommended: `Restore Last Session`) | Start fresh or restore last session with scrollback and agent state |
| **Quit When All Windows Closed** (Settings → General) | (value not shown) | Whether the app quits when the last window is closed |
| **Closing Tab** (Settings → General → Close Confirmation) | `Running Process` | When to prompt before closing a tab |
| **Closing Window** (Settings → General → Close Confirmation) | `Running Process` | When to prompt before closing a window |
| **Auto Update** (Settings → General → Update) | OFF | Check for new releases in background and prompt to install |
| **Working Directory** (Settings → Shell) | (inherited) | Whether new windows/tabs/splits inherit the current pane's cwd |
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

Light macOS window, rounded corners, drop shadow. Two-column: narrow left sidebar + wide right terminal, 1px hairline divider.

**Sidebar (~27% width):** macOS traffic lights (red/yellow/green, ~12px) at ~y=70px. Below: section label "TABS" small-caps light gray (~`#AAAAAA`) with hamburger/list icon (three horizontal lines, gray) far right of the row. Single tab row: "abner@MacBook-AB: ~" regular-weight dark text, flush left; right shows shortcut badge "⌘1" light gray. Tab row background slightly darker than sidebar (white card on light-gray sidebar, subtle rounded/inset highlight). No close button. Sidebar background: very light warm gray ~`#F2F1EF`.

**Terminal area (right):** background near-white ~`#F7F7F5` (warm off-white). Title bar centered "abner@MacBook-AB: ~" medium gray, ~13pt. Content top-left: prompt line — `~` green, green right-facing play triangle `▶`, blinking cursor bar `|` dark/black; fresh shell, no output. No status bar, no toolbar buttons.

**Typography:** System font (SF Pro), ~13pt. "TABS" uppercase small-caps ~10pt light gray. Tab label ~13pt regular.

**Spacing:** sidebar compact; tab row ~8px vertical padding; no borders beyond subtle background differentiation.

---

### launch-option.png — Settings → General showing On Launch dropdown

macOS Settings window. Left nav sidebar (~30%), right content (~70%). Light theme, rounded corners, drop shadow.

**Left sidebar:** traffic lights top-left (window unfocused → gray). Search bar top (rounded rect, magnifier, "Search", light gray). Nav items with icons:
- `⊙ General` — selected, gray fill (~`#E5E5E5`), heavier text
- `>_ Shell`, `▷ Controls`, `📄 Editor`, `⚡ Integrations`, `🎨 Appearance`, `📖 Recipes`, `⚡ Key Bindings`, `🔧 Advanced` — ~16px icon + regular label each.

**Right content:** header "GENERAL" small-caps gray ~11pt. Rows (label left, control right):
- **Language**: dropdown "English ↓".
- **Shell**: "System Default (zsh)" gray read-only.
- **On Launch**: dropdown "Restore Last Session ↓", currently OPEN — floating menu: "New Window" (unselected), "Restore Last Session" (selected, blue/darker highlight).
- **Quit When All Windows Closed**: label visible, control at bottom/off-screen.
- Section "CLOSE CONFIRMATION": **Closing Tab** "Running Process ↓"; **Closing Window** "Running Process ↓".
- Section "UPDATE": **Auto Update** — label + description ("Check for new releases in the background and prompt to install when one is available."), toggle OFF (gray).

**Typography:** section headers small-caps ~10pt gray; row labels ~13pt regular; values ~13pt darker gray/black. **Colors:** white content bg; gray selection; white standard macOS popup dropdown.

---

### first-launch-default-terminal.png — Settings → General → OS Integration section

Same Settings window (General selected), scrolled to OS INTEGRATION.

Top (continuation): **Auto Update** label + description + toggle OFF. **Check Update** label + "Current version: 1.0.0" + **"Check Now"** button (rounded rect, light gray).

Section "OS INTEGRATION" small-caps gray. Feature rows (bold label, description, right button):

1. **Default Terminal** — no description — **"Set as Default Terminal"**.
2. **Set as Default Terminal for Common Apps** — "macOS has no real default-terminal concept — most editors and git GUIs hardcode Terminal.app. Rewrites each known third-party app's external-terminal setting so it opens SlopDesk instead." — **"Configure…"**.
3. **Finder Integration** — "Adds 'Open in SlopDesk' to Finder's right-click Services menu for folders. Enable or rebind in System Settings → Keyboard → Keyboard Shortcuts → Services." — **"Open System Settings"**.
4. **Full Disk Access** — "Needed when commands run inside SlopDesk have to read or write protected files — mounting DMGs, reading `~/Library`, scripting Mail/Messages, etc. SlopDesk itself works without it." — **"Open System Settings"**.

**Button styling:** consistent — rounded rect ~130-160px wide, white/light bg, 1px border (~`#D0D0D0`), dark text, no fill (borderless macOS). **Rows:** taller than General rows (multi-line description ~11pt gray, subordinate to bold label).

---

### theme-list.png — Theme picker floating panel (Command Palette flow)

Terminal window (dark theme) with a floating modal panel overlaid; terminal shows `eza -la` output.

**Panel:** centered rounded-rect overlay, white/light, floating above the dark terminal. ~300-340px wide; height fits ~10 theme rows + search bar. Top: search field "Search themes…" + magnifier. Below: scrollable list; each row = theme name (left, ~13pt regular) + three ~8px color-dot swatches (right; representative palette colors, e.g. blue/green/red — quick ID, not full preview); selected row has subtle background highlight. Order (all LIGHT themes): April, Ayu Light, Floating Card, Glass Light, Newsprint, One Light, Paper, Pink, Solarized Light.

**Background terminal:** dark theme active. Left sidebar tabs with partial names ("Debug sorting order is…", "Fix cursor state chang…", "abner@MacBook-AB: ~/…", "Fix OSC 4 DOR-index f…", "Implement tab navigati…", "abner@MacBook-AB: ~/…" — last appears active). Tab badges (⌘1, ⌘2, …). Content: `eza -la` colored directory listing.

---

### change-theme.png — Settings → Appearance → Theme (grid view)

Settings window (light bg) open to Appearance, dark-theme terminal behind.

**Left sidebar:** **Appearance** selected (gray highlight).

**Right — Theme grid:** label "THEME" small-caps gray. Grid of theme thumbnail cards, 4 columns; each a small rounded rect miniature terminal preview (palette, text colors, bg) with theme-name label below. Selected card indicated by a subtle state (checkmark/border — unclear at this scale).
- Row 1 (light): April, Ayu-Light, Floating Card, Glass Light
- Row 2 (light): Newsprint, One Light, Paper, Pink
- Row 3: Solarized Light, then dark themes begin
- Dark: April Dark, Ayu Dark, Catppuccin M…, Dracula

**Card size:** ~80×60px. **Spacing:** ~8px gap; grid left-aligned.

---

### first-launch-agents.png — Settings → Agents → Agent Behavior section

Same Settings window, **Agents** selected (gray highlight, plug/connector icon).

**Right — Agent Behavior:** header "AGENT BEHAVIOR" small-caps gray. Seven toggle rows (bold label; ~11pt gray description; toggle right, green=ON/gray=OFF):

| Label | Description | State |
|---|---|---|
| Badge While Processing | Show tab badge while an agent is running a task | ON (green) |
| Badge When Task Completes | Show tab badge when an agent finishes a task | ON (green) |
| Badge When Awaiting Input | Show tab badge when an agent is waiting for approval or input | ON (green) |
| Notify When Task Completes | Show a notification when an agent finishes a task | ON (green) |
| Notify When Awaiting Input | Show a notification when an agent is waiting for approval or input | ON (green) |
| Prevent Sleep While Processing | Keep macOS awake while an agent is running a task | OFF (gray) |
| Resume Session on Recovery | Automatically resume agent session when recovering a terminal | ON (green) |

Header "CLAUDE CODE" at the bottom; "Install Hooks" label partially visible (the per-agent install card).

**Toggle styling:** iOS-style; ON solid green (~`#34C759`), OFF solid gray (~`#D1D1D6`); ~51×31px, right-aligned. **Row height:** ~60-70px (label + description).

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

- **Tab bar with agent state badges** — SlopDesk has `ClaudeStatus`/`ClaudePaneDetector`/`AgentControlListener` (per MEMORY.md); badge states (running/awaiting input/task complete) map directly onto existing infra; wire them to tab badge rendering.
- **On Launch: Restore Last Session** — via `DetachedSessionStore` (`SLOPDESK_DETACH_ENABLED`) + scrollback: detach/reattach on app launch.
- **Working Directory inheritance** — straightforward for local panes; remote panes need host-side cwd (host knows via `OSC 7` or direct PTY inquiry). Host-driven, not client-side, but no fundamental blocker.
- **Command Palette** — already exists; the theme-list-in-palette flow (type "themes", arrow-navigate, live preview, Enter) via existing palette + `ThemeStore`.
- **Theme grid in Settings / Appearance** — `ThemeStore` (Monokai Pro + others) exists; grid thumbnail view achievable.
- **Agent hook installation for Claude Code** — hook writes to local `~/.claude/`; SlopDesk runs on the user's local Mac (client), so Install Hooks is fully applicable.

### What requires adaptation (remote architecture)

- **Default Terminal (OS-level handler)** — can register for `.command`/`.sh`/`man://`/`ssh://` local launches, but `ssh://` links may open a remote connection. Product decision: `ssh://` → remote pane via SlopDesk transport, or local Terminal fallback?
- **"Set as Default Terminal for Common Apps"** — rewrites config for VS Code, Cursor, etc.; fine for local editors, but if the editor runs on the remote host the rewrite must happen host-side — can't map 1:1 without a host-side agent or SSH-mediated rewrite. MVP: local editors only.
- **Finder Integration ("Open in SlopDesk")** — Services item, achievable for client-local Finder; opened folder routes to a local or remote SSH pane (SlopDesk-specific routing).
- **Full Disk Access** — client-local macOS TCC permission; applicable as-is (client on user's Mac). Remote host has its own model (SSH creds, sudo), separate.
- **Prevent Sleep While Processing** — `NSProcessInfo.processInfo.beginActivity(...)` on the macOS client; no remote involvement.
- **Resume Session on Recovery** — maps to `DetachedSessionStore` + `SLOPDESK_DETACH_ENABLED`; already exists; expose toggle in Settings → Agents.
- **Notify When Task Completes / Awaiting Input** — macOS `UserNotifications` on the client; agent state must stream from the remote host via SlopDesk transport (OSC/control channel). `AgentControlListener` handles this.
- **Install CLI (`/usr/local/bin/slopdesk` equivalent)** — SlopDesk has `slopdesk-ctl` and related CLIs; an Install CLI button symlinking `/usr/local/bin/slopdesk` applies directly.
- **Omit prefix / shell functions** — injecting `edit`/`view`/`watch`/`jump` applies only to the LOCAL client shell (or the remote shell via the host's shell init); for remote shells, inject host-side via the PTY session's shell rc/profile. Medium complexity.

### Cannot map 1:1 (flag for product decision)

- **"Restore Last Session" with remote agent auto-resume** — the agent (claude, codex) runs on the remote host, not locally; "auto-resume" on launch = reconnect the remote PTY and re-attach to the detached session, not restart a local process. The agent never paused — it kept running on the host. Possible via `DetachedSessionStore`, but framing/UX must make clear the agent was NEVER paused.
- **Codex / OpenCode hook installation** — writes to `~/.codex/` and `~/.config/opencode/plugins/`; for slopdesk-initial scope (Claude Code only), skip. Mark as future work.
