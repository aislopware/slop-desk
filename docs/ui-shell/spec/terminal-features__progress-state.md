# Progress State

## Summary

SlopDesk surfaces live state of long-running commands visually — tab spinner/badge, animated Dock icon, and (where supported) a taskbar-style progress bar. Driven by the **ConEmu `OSC 9;4` progress protocol**, fed three ways:

1. **Programs** emit `OSC 9;4` themselves (curl, package managers, ConEmu/Windows-Terminal-aware programs).
2. **Shell integration** auto-emits it for a configurable command list — no program changes.
3. **`slopdesk watch`** wraps any command for a spinner-to-finish badge.

End-of-task system notifications (banners, sounds, Dock bounce) are covered in Privilege and Notifications.

## Behaviors

- `OSC 9;4;<state>[;<pct>]` reports progress. Canonical states: `0` = clear, `1;<pct>` = in-progress (0–100), `2[;<pct>]` = error, `3` = indeterminate/spinner. `4` (paused/warning) is recognized by the spec but ignored. `5` is a slopdesk extension: `OSC 9;4;5;<exit>[;watch]` = finished with exit code; the `watch` suffix routes to a separate notification toggle.
- Example sequences:
  - `printf '\e]9;4;1;40\a'` — determinate, 40%
  - `printf '\e]9;4;3\a'` — indeterminate spinner
  - `printf '\e]9;4;2;80\a'` — error, held at 80%
  - `printf '\e]9;4;0\a'` — clear
- `slopdesk features try progress` fires a live determinate bar; `slopdesk features try error-state` fires the error variant.
- With shell integration active, slopdesk auto-wraps a built-in list of slow commands to emit an indeterminate spinner while running and a finish/error badge on exit. Built-in list includes: `curl`, `wget`, `rsync`, `scp`, `git fetch/pull/push/clone`, `brew install/update/upgrade`, `npm/pnpm/yarn/bun install`, `pip install`, `cargo build/install/update`, `docker pull/push/build`, `apt`/`apt-get install/update/upgrade`, and more.
- Configurable under **Settings → Advanced → Auto Progress-Bar Commands**. Each entry matches as a whitespace-delimited prefix (`git push` matches `git push origin main`, not `git status`). Clearing the field disables auto-progress.
- `slopdesk watch <cmd>` wraps any command: indeterminate spinner while running, success/error badge on exit, and a "Notify on Watch Finish" notification (unless `-q`/`--quiet`). It tags its finish with `watch`, so the watch notification can stay on while noisier per-command finish notifications are off.
- Tab badges reflect per-tab progress state as a small right-aligned icon. Full set:
  - **Running** (spinner) — `OSC 9;4;1`/`3` in progress, or `slopdesk watch` running.
  - **Completed** (checkmark) — brief success flash, settles to Finished.
  - **Finished** (accent dot) — command exited 0 (unread-output marker).
  - **Error** (alert triangle) — command exited non-zero, or `OSC 9;4;2`.
  - **Awaiting input** (hand icon) — a code agent waiting for approval/input, or a plain command stopped at an interactive prompt (detected after ~1.5 s cursor-at-prompt with no input; typing clears it).
  - **Caffeinate** / **Sudo** — sleep-blocking or privileged session (set automatically; not CLI-settable).
- Command-driven badges (Finished, Error, Awaiting Input) require shell integration (keyed off `OSC 133;D` exit marks). Three **Settings → Shell** toggles control them, all on by default:
  - **Tab Badge — When Command Finishes** — accent dot after a successful command.
  - **Tab Badge — When Command Fails** — alert badge after non-zero exit.
  - **Tab Badge — When Command Awaits Input** — hand badge when a running command stops at `[y/n]`, password read, or "Press ENTER to continue" (waits ~1.5 s; typing clears it).
- Scripts can set a badge via CLI: `slopdesk tab badge --kind running` (kinds: running, completed, finished, unread, error, awaiting-input) or `slopdesk tab badge --clear`. Caffeinate/sudo badges are not CLI-settable.
- The Dock icon reflects aggregate progress across all tabs. Two **Settings → Appearance** settings:
  - **Animate Icon on Progress** (off by default) — rotates the icon's "eye" while any session has active `OSC 9;4` progress/indeterminate.
  - **Red Icon on Error** (on by default) — tints the icon red when any session reports non-zero exit or `OSC 9;4;2`; clicking the Dock icon jumps to the next failing tab and clears the tint.
- Coding agents (Claude Code, Codex, OpenCode) report state over IPC — *processing*, *idle*, *awaiting input* — driving agent-specific badges without shell integration. Three **Settings → Shell** toggles (shown for Claude Code; equivalents exist for other agents):
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
| `progress-bar-commands` | built-in list (curl, wget, git fetch/pull/push/clone, brew, npm/pnpm/yarn/bun install, pip install, cargo build/install/update, docker, apt/apt-get…) | Whitespace-delimited prefix list of commands that auto-emit an indeterminate indicator when shell integration is on. Clear to disable. Editable under Settings → Advanced → Auto Progress-Bar Commands. |
| `dock-icon-animate-progress` | `off` | Rotates the Dock icon's eye graphic while any session has an active OSC 9;4 in-progress or indeterminate state. |
| `dock-icon-error-badge` | `on` | Tints the Dock icon red when any session reports a non-zero exit or OSC 9;4;2; clicking the Dock icon jumps to the next failing tab and clears the tint. |
| `privilege-badge-*` | (see Privilege and Notifications page) | Controls the caffeinate / sudo tab badge behavior. |
| Tab Badge — When Command Finishes (Settings → Shell) | `on` | Accent dot badge on the tab after a successful (exit 0) command. |
| Tab Badge — When Command Fails (Settings → Shell) | `on` | Alert (triangle) badge on the tab after a non-zero exit. |
| Tab Badge — When Command Awaits Input (Settings → Shell) | `on` | Hand badge when a running command stops at an interactive prompt for ~1.5 s; clears on typing. |
| Claude Code — While Processing (Settings → Shell) | `off` | Spinner badge while the Claude Code agent is processing. |
| Claude Code — When Task Completes (Settings → Shell) | `on` | Dot badge when the Claude Code agent goes idle. |
| Claude Code — When Awaiting Input (Settings → Shell) | `on` | Indicator badge when the Claude Code agent needs approval or input. |

## Visual spec

### tab-badge.png

**Overall layout:** macOS-style window, rounded-rectangle border, subtle drop-shadow on white. Two vertical panels split by a light gray hairline: left sidebar (~30% width) = tab list; right panel (~70%) = active terminal pane.

**Window chrome:** Top-left macOS traffic-light buttons as small gray circles (no color fill — inactive/non-hover). Title bar center reads "user@hostname: ~/path/to/project" (cwd/hostname) in small gray system font.

**Left sidebar — Tab list:**
- Section label "TABS" in small uppercase gray (~10px, tracking-wide, ~#999) top-left, with a three-line hamburger icon right-aligned on the same row (~#999).
- Each tab is a full-width ~40px row. Labels in medium-weight sans-serif (SF Pro-like), left-aligned, ~#333 for non-selected, black bold for selected.
- Badges right-aligned, ~20×20px:
  1. **"full-release.sh"** — animated spinner (multi-spoke radial lines, dark gray ~#555; in-progress/running).
  2. **"running build task"** — red alert triangle with white exclamation (error), ~#D32F2F (Material red).
  3. **"plan next move"** — orange hand/stop icon (awaiting input), ~#E07020 (warm orange-brown).
  4. **"OpenCode"** — green filled circle with white checkmark (completed/success), ~#2E7D32 or #43A047 (mid-green).
  5. **"abner@MacBook-AB:..."** (truncated) — solid dark green/teal filled circle (accent dot — Finished/unread), ~#2E7D32 (same green family, smaller solid dot, no checkmark).
  6. **"abner@MacBook-AB:..."** (bottom, selected) — white card/box background, slightly rounded corners, thin border; label bold; a secondary "zsh" label right-aligned in small gray (~#999) shows the current shell process. No badge on the active tab.
- Selected tab card: ~4px radius, white fill, ~1px light gray border (~#E0E0E0). Non-selected tabs have no fill (transparent over the sidebar's warm-tinted light gray ~#F0EFED).
- Sidebar background: warm off-white / light gray (~#EEEDE9).
- No vertical scrollbar; tabs fit the visible area.

**Right pane — Terminal area:**
- Background near-white / very light gray (~#F8F8F8 or pure white).
- Shell prompt line at top: `~/path/to/project (main ✗)` followed by two small colored icons — a red/orange asterisk glyph and a green right-triangle play icon (zsh prompt with git status + likely a slopdesk-specific run/watch indicator):
  - `~/path/to/project` — cyan/teal monospace.
  - `(main ✗)` — magenta/pink monospace (dirty git branch).
  - asterisk/splat: orange-red (~#CC3300), possibly modified files.
  - triangle play: green (~#2E7D32), possibly a slopdesk watch or agent indicator.
- Cursor not visible; pane otherwise empty (no output).

**Typography:** Monospace in the terminal pane (~13–14px at 1x). Tab labels proportional sans-serif ~13px.

**Spacing:** Tab rows ~12px top+bottom padding; badges vertically centered; sidebar-to-terminal divider is a 1px hairline.

**Key takeaways for implementation:**
- Badges are right-edge-aligned small icons, not text labels.
- Each badge type has a distinct icon AND color: spinner=dark gray, error=red triangle, awaiting=orange hand, completed=green check circle, finished=solid green dot.
- Selected tab is distinguished by a white card background with thin border, not just text color.
- "zsh" secondary label on the active tab shows the shell process name in subdued gray.
- Sidebar's warm off-white contrasts with the whiter terminal pane.

## Screenshots

- `tab-badge.png`

## Implementation notes

**Architecture context:** SlopDesk is a macOS host (slopdesk-hostd) + macOS/iOS client app. The terminal renders via libghostty behind a `TerminalSurface` seam. The host runs the shell sessions; the client displays them.

### Straightforward

- **OSC 9;4 parsing (host side):** hostd already processes PTY output; it can parse `OSC 9;4;*` out of the byte stream and emit progress-state events over the control channel to the client. Clean mapping.
- **Tab badges (client):** The client UI has a pane/tab model (`WorkspaceStore`, `PaneKind`). Per-pane badge state (running, error, finished, awaiting-input) renders as overlay icons on tab/pane headers, mapping directly onto the existing sidebar tab rows.
- **Spinner badge:** A simple animated spinner view, right-aligned per row when state == running/indeterminate.
- **Auto-progress for known commands (host):** Shell integration (`OSC 133;D` exit marks) is already planned; auto-wrapping known slow commands to emit `OSC 9;4` is a fully mappable host-side concern.
- **`slopdesk watch`:** Host-side CLI wrapper emitting `OSC 9;4` into the PTY. Not blocked by remote architecture.
- **Agent IPC badges (Claude Code):** Existing `ClaudeStatus`/`ClaudePaneDetector`/`AgentControlListener` (per MEMORY.md) — processing/idle/awaiting-input states drive the same badge types. Direct.
- **`slopdesk watch:<agent>` blocking:** Host-side CLI polling the agent control socket, exiting with codes 0/4/9.

### Needs care / caveats

- **Dock icon animation and red-icon-on-error:** macOS-only; requires the client to be a first-class macOS app with Dock presence (NSDockTile + animated icon). iOS has no Dock — condition on `#if os(macOS)`.
- **Taskbar-style progress bar:** On macOS this is the Dock tile progress indicator (`NSDockTile.badgeLabel` or custom drawing). macOS only; iOS has no equivalent.
- **"Awaiting input" detection (~1.5 s cursor-at-prompt heuristic):** Requires the host to observe PTY output quiescence at a cursor position. The host has direct PTY access, so it detects and forwards state; the 1.5 s timer and "typing clears it" are coordinated host-side (it sees keystrokes and PTY output). Take care not to fire spuriously on long-running silent commands.
- **Remote host-side shell integration:** `OSC 133` must be installed in the remote shell. Since slopdesk-hostd manages its own PTY, it can inject the shim into the shell environment. Already planned; no blocker.
- **`slopdesk tab badge` CLI override:** Client and host are separate processes; a host CLI command must communicate badge state to the client over the control channel — needs a new host→client "set badge on pane X" wire message (or reuse of the agent control IPC path).
- **Caffeinate / Sudo badges:** Require the host to detect `caffeinate` processes or `sudo` sessions via process inspection (e.g. polling child processes with `kinfo_proc`). Mappable on macOS host; more complex but feasible.
- **Settings UI location:** Settings live under Advanced / Appearance / Shell. SlopDesk uses `PreferencesStore` + `EnvConfig`; add the config keys to `PreferencesStore` with the defaults above, and add Settings UI sections for these toggles.
- **iOS client:** No Dock, no taskbar. Tab/pane badge indicators, agent badges, and command badges all apply on iOS; only Dock/taskbar features are macOS-only.
