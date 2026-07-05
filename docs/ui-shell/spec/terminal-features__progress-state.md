# Progress State

## Summary

SlopDesk surfaces the live state of long-running commands and tasks visually — a spinner or badge on the tab, an animated Dock icon, and (on supported platforms) a taskbar-style progress bar. The state is driven by the **ConEmu `OSC 9;4` progress protocol**, fed by three mechanisms:

1. **Programs** emit `OSC 9;4` themselves (curl, package managers, ConEmu/Windows-Terminal-aware programs).
2. **Shell integration** auto-emits it for a configurable list of commands — no program changes needed.
3. **`slopdesk watch`** wraps any command to give it a spinner-to-finish badge.

System notifications (banners, sounds, Dock bounce) that fire when a task ends are covered separately in Privilege and Notifications.

## Behaviors

- A program emits `OSC 9;4;<state>[;<pct>]` to report progress. The four canonical states are: `0` = clear, `1;<pct>` = in-progress (0–100), `2[;<pct>]` = error, `3` = indeterminate/spinner. State `4` (paused/warning) is recognized by the spec but ignored by slopdesk. State `5` is an slopdesk extension: `OSC 9;4;5;<exit>[;watch]` = finished with exit code; the `watch` suffix routes to a separate notification toggle.
- Example sequences:
  - `printf '\e]9;4;1;40\a'` — determinate, 40%
  - `printf '\e]9;4;3\a'` — indeterminate spinner
  - `printf '\e]9;4;2;80\a'` — error, held at 80%
  - `printf '\e]9;4;0\a'` — clear the indicator
- `slopdesk features try progress` fires a live determinate bar for testing; `slopdesk features try error-state` fires the error variant.
- When shell integration is active, slopdesk auto-wraps a built-in list of slow commands to emit an indeterminate spinner while running and a finish/error badge on exit. The built-in list includes: `curl`, `wget`, `rsync`, `scp`, `git fetch/pull/push/clone`, `brew install/update/upgrade`, `npm/pnpm/yarn/bun install`, `pip install`, `cargo build/install/update`, `docker pull/push/build`, `apt`/`apt-get install/update/upgrade`, and more.
- Auto-progress commands are configurable under **Settings → Advanced → Auto Progress-Bar Commands**. Each entry is matched as a whitespace-delimited prefix (`git push` matches `git push origin main` but not `git status`). Clearing the field disables auto-progress entirely.
- `slopdesk watch <cmd>` wraps any command: shows an indeterminate spinner while it runs, then a success or error badge on exit, and posts a "Notify on Watch Finish" notification (unless `-q`/`--quiet`). Because it tags its finish with `watch`, the watch notification can be kept on while the noisier per-command finish notifications are off.
- Tab badges reflect the current progress state per tab. All badges use a small icon right-aligned on the tab row. The full badge set:
  - **Running** (spinner) — `OSC 9;4;1`/`3` in progress, or `slopdesk watch` running.
  - **Completed** (checkmark) — brief success flash, settles to Finished.
  - **Finished** (accent dot) — command exited 0 (unread-output marker).
  - **Error** (alert triangle) — command exited non-zero, or `OSC 9;4;2`.
  - **Awaiting input** (hand icon) — a code agent waiting for approval/input, or a plain command stopped at an interactive prompt (detected after ~1.5 s of cursor-at-prompt with no input; typing in the pane clears it).
  - **Caffeinate** / **Sudo** — sleep-blocking or privileged session (set automatically; not settable from CLI).
- Command-driven badges (Finished, Error, Awaiting Input) require shell integration (keyed off `OSC 133;D` exit marks). Three toggles under **Settings → Shell** control them, all on by default:
  - **Tab Badge — When Command Finishes** — accent dot after a successful command.
  - **Tab Badge — When Command Fails** — alert badge after non-zero exit.
  - **Tab Badge — When Command Awaits Input** — hand badge when a running command stops at `[y/n]`, password read, or "Press ENTER to continue" (detection waits ~1.5 s; typing clears it).
- Scripts can set a badge directly via the CLI: `slopdesk tab badge --kind running` (kinds: running, completed, finished, unread, error, awaiting-input) or `slopdesk tab badge --clear`. The caffeinate/sudo badges are intentionally not settable via CLI.
- The Dock icon reflects aggregate progress across all tabs. Two settings under **Settings → Appearance**:
  - **Animate Icon on Progress** (off by default) — rotates the icon's "eye" while any session has active `OSC 9;4` progress/indeterminate.
  - **Red Icon on Error** (on by default) — tints the icon red when any session reports non-zero exit or `OSC 9;4;2`; clicking the Dock icon jumps to the next failing tab and clears the tint.
- Coding agents (Claude Code, Codex, OpenCode) report state over IPC — *processing*, *idle*, *awaiting input* — driving agent-specific badges without requiring shell integration. Three toggles under **Settings → Shell** (all scoped to Claude Code; equivalent toggles exist for other agents):
  - **Claude Code — While Processing** (off by default) — spinner while the agent is thinking.
  - **Claude Code — When Task Completes** (on by default) — dot when the agent goes idle.
  - **Claude Code — When Awaiting Input** (on by default) — indicator when the agent needs approval or input.
- `slopdesk watch:<agent>` blocks a script until an agent session is idle: `slopdesk watch:claude <id>`, `slopdesk watch:codex <id> --timeout-secs 600`, `slopdesk watch:opencode <id> --interval-ms 2000 -v`. Exit codes: `0` = idle/closed, `4` = session ID never seen, `9` = timeout.

## Keybindings

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `progress-bar-commands` | built-in list (curl, wget, git fetch/pull/push/clone, brew, npm/pnpm/yarn/bun install, pip install, cargo build/install/update, docker, apt/apt-get…) | Whitespace-delimited prefix list of commands that auto-emit an indeterminate progress indicator when shell integration is on. Clear to disable auto-progress entirely. Editable under Settings → Advanced → Auto Progress-Bar Commands. |
| `dock-icon-animate-progress` | `off` | Rotates the Dock icon's eye graphic while any session has an active OSC 9;4 in-progress or indeterminate state. |
| `dock-icon-error-badge` | `on` | Tints the Dock icon red when any session reports a non-zero exit or OSC 9;4;2 error state; clicking the Dock icon jumps to the next failing tab and clears the tint. |
| `privilege-badge-*` | (see Privilege and Notifications page) | Controls the caffeinate / sudo tab badge behavior. |
| Tab Badge — When Command Finishes (Settings → Shell) | `on` | Shows an accent dot badge on the tab after a successful (exit 0) command. |
| Tab Badge — When Command Fails (Settings → Shell) | `on` | Shows an alert (triangle) badge on the tab after a non-zero exit. |
| Tab Badge — When Command Awaits Input (Settings → Shell) | `on` | Shows a hand badge on the tab when a running command stops at an interactive prompt for ~1.5 s; clears on typing. |
| Claude Code — While Processing (Settings → Shell) | `off` | Shows a spinner badge on the tab while the Claude Code agent is processing. |
| Claude Code — When Task Completes (Settings → Shell) | `on` | Shows a dot badge on the tab when the Claude Code agent goes idle. |
| Claude Code — When Awaiting Input (Settings → Shell) | `on` | Shows an indicator badge when the Claude Code agent needs approval or input. |

## Visual spec

### tab-badge.png

**Overall layout:** A macOS-style window with a rounded-rectangle border and a subtle drop-shadow on a white background. The window is divided into two vertical panels by a light gray hairline divider. The left panel (~30% width) is a sidebar containing a tab list; the right panel (~70%) is the active terminal pane.

**Window chrome:** Top-left has the standard macOS traffic-light buttons (close/minimize/zoom) rendered as small gray circles (no color fill visible, suggesting an inactive or non-hover state). The window title bar at the very top center reads "user@hostname: ~/path/to/project" (shell prompt cwd/hostname) in a small gray system font.

**Left sidebar — Tab list:**
- A section label "TABS" in small uppercase gray text (approx 10px, tracking-wide, color ~#999) sits at the top-left of the sidebar, with a three-line hamburger/menu icon right-aligned on the same row (~#999).
- Each tab occupies a full-width row with ~40px height. Tab labels are in a medium-weight sans-serif (appears to be SF Pro or similar system font), left-aligned, color ~#333 (dark gray) for non-selected tabs and black bold for the selected tab.
- Badges are right-aligned on each tab row, sized approximately 20×20px:
  1. **"full-release.sh"** — badge: animated spinner (multi-spoke radial lines in dark gray ~#555, indicating an in-progress/running state).
  2. **"running build task"** — badge: red alert triangle with a white exclamation mark (error/failure state), color ~#D32F2F (Material red).
  3. **"plan next move"** — badge: orange hand/stop icon (awaiting input state), color approximately ~#E07020 (warm orange-brown).
  4. **"OpenCode"** — badge: green filled circle with white checkmark (completed/success state), color ~#2E7D32 or #43A047 (mid-green).
  5. **"abner@MacBook-AB:..."** (truncated with ellipsis) — badge: solid dark green/teal filled circle (accent dot — Finished/unread-output state), color approximately ~#2E7D32 (same green family as checkmark but smaller solid dot, no checkmark).
  6. **"abner@MacBook-AB:..."** (bottom row, selected) — this tab is selected; it has a white card/box background with slightly rounded corners and a thin border, distinguishing it from the others. Label text is bold. A secondary label "zsh" appears right-aligned within the card in small gray text (~#999), indicating the current shell process. No badge visible on the active tab.
- The selected tab card has approximately 4px corner radius, a white fill, and a very light gray border (~1px, ~#E0E0E0). All non-selected tabs have no background fill (transparent against the sidebar's light gray background ~#F0EFED or similar warm-tinted light gray).
- Sidebar background: warm off-white / light gray (~#EEEDE9 or similar).
- No vertical scrollbar visible; tabs fit within the visible area.

**Right pane — Terminal area:**
- Background is near-white / very light gray (~#F8F8F8 or pure white).
- The shell prompt line is visible at the top of the content area: `~/path/to/project (main ✗)` followed by two small colored icons — a red/orange asterisk-like asterisk glyph and a green right-triangle play icon. This is a zsh prompt with git status indicators and likely an slopdesk-specific run/watch indicator.
  - `~/path/to/project` — rendered in cyan/teal monospace.
  - `(main ✗)` — rendered in magenta/pink monospace, indicating a dirty git branch.
  - The asterisk/splat: orange-red color (~#CC3300), possibly indicating modified files.
  - The triangle play button: green (~#2E7D32), possibly an slopdesk watch or agent indicator.
- The cursor is not visible (or blinking). The pane is otherwise empty (no command output shown).

**Typography:** Monospace font in the terminal pane (appears to be a standard terminal font, approximately 13–14px at 1x). The tab labels use a proportional sans-serif at approximately 13px.

**Spacing:** Tab rows have ~12px top+bottom padding. Badge icons are vertically centered in each row. The sidebar-to-terminal divider is a 1px hairline.

**Key visual takeaways for implementation:**
- Badges are right-edge-aligned small icons, not text labels.
- Each badge type has a distinct icon AND a distinct color: spinner=dark gray, error=red triangle, awaiting=orange hand, completed=green check circle, finished=solid green dot.
- The selected tab is visually distinct via a white card background with thin border (not just text color change).
- The "zsh" secondary label on the active tab shows the shell process name in subdued gray.
- Sidebar has a warm off-white background that contrasts with the whiter terminal pane.

## Screenshots

- `tab-badge.png`

## Implementation notes

**Architecture context:** SlopDesk is a macOS host (running slopdesk-hostd) + macOS/iOS client app. The terminal is rendered by libghostty behind a `TerminalSurface` seam. The host runs actual shell sessions; the client displays them.

### Straightforward

- **OSC 9;4 protocol parsing (host side):** The hostd already processes PTY output streams. It can parse `OSC 9;4;*` sequences out of the byte stream (before or alongside forwarding to the client) and emit progress-state events over the control channel to the client. This is a clean mapping.
- **Tab badges on the client:** SlopDesk's client UI has a pane/tab model (`WorkspaceStore`, `PaneKind`). Badge state (running, error, finished, awaiting-input) can be stored per-pane and rendered as overlay icons on tab/pane headers. The visual design (right-aligned small icons per the screenshot) maps directly onto the existing sidebar tab rows.
- **Spinner badge for in-progress:** A simple animated spinner view can be placed right-aligned on each pane row when state == running/indeterminate.
- **Auto-progress for known commands (host side):** Shell integration on the host (`OSC 133;D` exit marks) is already a planned feature. Auto-wrapping known slow commands to emit `OSC 9;4` is a host-side concern and fully mappable.
- **`slopdesk watch`:** Implemented as a host-side CLI wrapper that emits `OSC 9;4` sequences into the PTY. Not blocked by remote architecture.
- **Agent IPC badges (Claude Code specifically):** SlopDesk already has `ClaudeStatus`/`ClaudePaneDetector`/`AgentControlListener` (per MEMORY.md). The processing/idle/awaiting-input states from the agent IPC can drive the same badge types described above. Direct implementation.
- **`slopdesk watch:<agent>` blocking:** Can be implemented as a host-side CLI tool that polls the agent control socket and exits with the same codes (0/4/9).

### Needs care / caveats

- **Dock icon animation and red-icon-on-error (macOS Dock):** This is a macOS-only feature that requires the client app to be a first-class macOS app with a Dock presence. SlopDesk's macOS client app can implement this (NSDockTile + animated icon). The iOS client has no Dock equivalent — this feature is macOS-only and should be conditioned on `#if os(macOS)`.
- **Taskbar-style progress bar (macOS/Windows taskbar):** SlopDesk surfaces a taskbar-style progress bar on supported platforms. On macOS this would be the Dock tile progress indicator (`NSDockTile.badgeLabel` or custom drawing). This is implementable on macOS only; iOS has no equivalent.
- **"Awaiting input" detection (~1.5 s cursor-at-prompt heuristic):** This heuristic requires the host to observe PTY output quiescence at a cursor position. Since the host has direct PTY access, it can implement this detection and forward the state to the client. However, the 1.5 s timer and the "typing clears it" behavior must be coordinated host-side (the host sees keystrokes and PTY output). This maps, but requires care in the host's PTY observer to not fire spuriously on long-running silent commands.
- **Remote host-side shell integration:** Shell integration (`OSC 133`) must be installed in the remote shell on the host machine. Since slopdesk manages its own PTY (slopdesk-hostd), it can inject the integration shim into the shell environment. Already planned per MEMORY; no fundamental blocker.
- **`slopdesk tab badge` direct CLI badge override:** In slopdesk the "client" and "host" are separate processes. A CLI command running on the host would need to communicate badge state to the client over the control channel. This requires a small host→client control message for "set badge on pane X". Mappable but requires a new wire message type (or reuse of the agent control IPC path).
- **Caffeinate / Sudo badges:** These require the host to detect `caffeinate` processes or `sudo` sessions in the PTY, which requires process inspection on the host (e.g. polling for child processes with `kinfo_proc`). Mappable on macOS host; more complex but feasible.
- **Settings UI location:** These settings live under "Settings → Advanced / Appearance / Shell". SlopDesk uses `PreferencesStore` + `EnvConfig`. The config keys should be added to `PreferencesStore` with the defaults documented above. The Settings UI pane in the client needs sections for these toggles.
- **iOS client specifics:** iOS has no Dock, no taskbar. Badge indicators on tabs/panes are fully applicable on iOS. Agent badges and command badges all map. Only Dock/taskbar features are macOS-only.
