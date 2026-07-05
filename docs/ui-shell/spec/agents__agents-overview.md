# Working with Code Agents

## Summary

SlopDesk integrates with coding agents (Claude Code, Codex, OpenCode) rather than replacing those CLIs, via a small hook or plugin that lets the agent report its state (working / done / waiting). This unlocks live tab badges, system notifications, conversation history, prompt queuing, a multi-line Composer input surface, and Send-to-Chat context injection. The agent runs in a first-class pane; the client handles the supervisory UI layer on top.

## Behaviors

- **Live tab badges on vertical tab strip**: Each tab carries a badge reflecting the current agent state without requiring the user to switch to it. States surfaced: still working, done, waiting on user.
- **System notifications**: Fire when a task completes or when an agent is waiting for approval/input. The app can also keep the Mac awake to prevent a long run stalling on sleep.
- **Composer (multi-line input surface)**: Replaces the bare single-line prompt with a float-on-top multi-line panel that supports undo/redo and image paste.
- **Prompt Queue (⌘⇧M)**: Queue commands while an agent is busy; the app dispatches each queued command at the next idle prompt automatically.
- **Send to Chat**: Drops a terminal selection, the last command's output, or a file-pane snippet directly into the agent conversation — no manual copy-paste.
- **History**: Every conversation is captured. Sessions can be resumed days later or searched across all tabs.
- **Fork / Branch Session**: Fork or branch a conversation to try a second approach in a split or a new tab, without losing the original thread.
- **Built-in file viewer/editor**: Open and read files the agent changed directly beside the chat, without a separate editor window.
- **Hook/plugin install**: On first agent run, the app offers to install a small hook (Claude Code, Codex) or plugin (OpenCode) into that agent's config. Approve once; nothing else changes. The hook lets the agent report start/finish/waiting state to the app.
- **Restart prompt**: After hook install, the app may prompt to restart the agent in that tab. Once restarted, tab badges, notifications, history, and fork activate automatically.
- **Agent detection is automatic after setup**: No ongoing configuration needed once the hook is installed.
- **Supported agents**: Claude Code (`claude`), Codex (`codex`), OpenCode (`opencode`) — run exactly as users do today.

### Claude-Code-specific notes (agent-generic vs Claude-Code-specific)
- The **hook mechanism** is Claude-Code-specific (hooks into Claude Code's own config). Codex also uses a hook; OpenCode uses a plugin. The integration surface differs per agent but the UX outcome (badges, notifications, history) is identical.
- **Prompt Queue** (`⌘⇧M`) is agent-generic — dispatches at any idle shell prompt.
- **Send to Chat** is agent-generic — works against whichever agent is in the active pane.
- **History and Fork** are agent-generic at the app level; the conversation capture depends on the hook being installed.

## Keybindings

| Action | Keys |
|--------|------|
| Queue command (Prompt Queue) | `⌘⇧M` |

## Config keys

No config keys are documented on this overview page. Config details are covered in Setup (per-agent API keys, models) and the individual feature pages (Composer, Monitor Tasks, etc.).

| Key | Default | Effect |
|-----|---------|--------|
| _(none on this page)_ | — | — |

## Visual spec

### Screenshot: code-agents.png

**Overall layout and window chrome**
Standard macOS window with a light (near-white) background, rounded corners, traffic-light buttons (red/yellow/green) at top-left. The window title bar shows "OpenCode" center-aligned in the system font, no subtitle. The window has no custom chrome beyond the standard macOS title bar; no toolbar strip beneath it.

**Left sidebar — vertical tab strip**
Approximately 160–170 px wide, light gray background (slightly darker than the content area, ~#F2F2F2 on light theme). The strip is headed by a "TABS" label in small all-caps gray text (label+icon column for section header). Tabs are listed vertically, each row ~28–30 px tall, with left-padded text in a compact sans-serif font (~12–13 pt, semibold for active, regular for inactive).

Tab label examples visible (truncated with ellipsis):
- `# freerdp-rdp-udp-mu…`
- `# hardware decoder`
- `# investigate why scre…`
- `abner@MacBook-Pro…`
- _(blank separator gap)_
- `abner@MacBook-Pro…`
- _(blank separator gap)_
- `OC | Split terminal feat…`  — has an orange dot badge (right side of tab row)
- `OC | Debug OSC notifi…`  — has an orange dot badge
- `OC | Add agents-overv…`  — has a filled dark dot badge (solid black/dark = active/working)
- `code-review-todos.md`
- `OC | Fix opencode fini…`
- `OC | Review GUI user e…`
- **`OpenCode`** — currently selected tab, bold/highlighted with a darker background strip, no badge visible
- `~/Simplify`
- _(blank separator gap)_
- `build.sh`
- `abner@MacBook-Pro…`

**Badge design**: Small circular dots on the right edge of tab rows. Orange/amber fill = working or needs attention. Dark filled circle = likely active/current task. No badge = idle/done. Badges are ~6–8 px diameter. The badge sits at the trailing edge of the tab label row, right-aligned.

**Tab item prefix conventions**: Tabs running a named OpenCode session carry `OC | ` prefix before the task description. Raw shell tabs show `#` prefix or `username@hostname` form. The selected tab (`OpenCode`) has no prefix — it is a bare agent launch tab.

**Content area — main pane (right of sidebar)**
Full height/width remainder of the window. Shows the OpenCode TUI splash screen:
- Large wordmark "openCode" rendered in a chunky bold font, split coloring: "open" in dark/black, "Code" in a lighter gray-green, ~40 pt. Centered horizontally, positioned upper-center of the pane.
- Below the wordmark: a subtle input prompt area showing:
  - "Ask anything…" placeholder in gray, followed by `"Fix broken tests"` as an example prompt in a darker weight.
  - Second line: `Build · GLM-5.1 OpenCode Go` — a status/model indicator line in small gray text, showing current build target and model.
- Below that: a breadcrumb/context strip in small gray text:
  `agents-overview.md   tab   agents   ctrl+p   commands`
  This appears to be a file-context line showing the current file, current tab name, and a keybinding hint (`ctrl+p` for commands).
- At the bottom of the pane, a tip callout in a faint yellow/amber background pill:
  `● Tip   Enable scroll_acceleration in tui.json for smooth macOS-style scrolling`
  The tip prefix uses a small filled circle (yellow-orange dot), then bold "Tip" label, then the tip text in regular weight.

**Status bar — bottom of main pane**
Two items anchored to the bottom corners:
- Left: an example `~/Workspace/<project>:<branch>` — current working directory + git branch, in small gray monospace text.
- Right: `1.16.2` — version number, small gray text.

**Typography**
- Tab labels: system sans-serif (SF Pro or similar), ~12–13 pt, regular for inactive tabs, semibold for selected.
- Content area wordmark: custom thick display font.
- Status bar / breadcrumbs: monospace, ~11 pt, muted gray (~#999 on light theme).
- Sidebar background: ~#F0F0F0; active tab row: ~#E0E0E0 or slightly darker pill highlight.
- Badges: filled circles, orange ~#FF9500 (amber) for working/waiting, dark ~#1A1A1A for current/selected-task.

**Spacing density**
Compact: tabs are tightly stacked with minimal vertical padding (~4–6 px top/bottom per row). The sidebar has no section separators except blank tab rows (used as visual gaps between groups).

**No toolbar icons / buttons visible** in the sidebar beyond the tab labels and badges. No hamburger, no add-tab button, no gear icon in the screenshot.

## Screenshots

- `code-agents.png`

## SlopDesk mapping notes

### Maps well (1:1 or near-1:1)

- **Vertical tab strip with badges**: SlopDesk already has a tab/pane model (`WorkspaceStore`, `PaneKind`). The badge states (working / done / waiting) map to the existing `ClaudeStatus` / `ClaudePaneDetector` infrastructure. Badge rendering should be added to the sidebar tab rows using the same dot-style.
- **Live agent state detection**: `ClaudePaneDetector` and `AgentControlListener` already exist and detect Claude Code state. These cover the "working / done / waiting" badge states for Claude Code specifically.
- **Prompt Queue**: Maps cleanly onto the `slopdesk-ctl` / NDJSON agent-control socket. Queue entries can be dispatched as PTY writes at OSC-133 idle prompts.
- **Notification system**: macOS `UNUserNotificationCenter` can fire on state transitions detected by `ClaudePaneDetector`. iOS client can receive push notifications or local notifications from the host bridge.
- **Built-in file viewer**: SlopDesk has an editor pane / file pane concept in `WorkspaceStore`. File viewing beside the agent chat is achievable with the split-pane layout.
- **History / session capture**: The `ReplayBuffer` provides lossless reconnect but is not a conversation history. A separate OSC-133 transcript capture per pane would be needed for history search.

### Partial maps (requires adaptation)

- **Composer (float-on-top multi-line input)**: The current SlopDesk Composer equivalent would need to be a floating panel that writes to the active PTY. The "float on top" property works on macOS (NSPanel with `.floating` window level) but on iOS it would be a sheet or popover — behavior differs, not 1:1.
- **Send to Chat**: Requires a pane-selection action that injects text into a specific agent pane's PTY. The selection-to-PTY injection exists (OSC-52 clipboard + keystroke injection), but "drop into agent conversation" needs agent-aware targeting (knowing which pane is the active agent).
- **Fork / Branch Session**: On slopdesk the session is a remote PTY on the host Mac. Forking requires spawning a new PTY from the same working directory and shell state — achievable via `slopdesk-ctl` creating a new session with `cwd` inherited, but conversation state (Claude Code's in-process context) cannot be cloned; only the shell/cwd can be forked.

### Cannot map 1:1 (flag)

- **Hook install UX**: The design calls for installing a hook into Claude Code's config file (`.claude/settings.json` or similar) with a UI approval dialog inside the terminal. In slopdesk the host runs the agent; the client has no direct access to the host's Claude Code config files. Hook installation must happen on the host side, either via `slopdesk-ctl` or a pre-configured setup script. There is no in-app "approve once" flow from the iOS client.
- **Keep Mac awake during agent run**: `IOPMAssertionCreateWithName` (power assertion) must run on the macOS host, not the client. The host daemon (`slopdesk-hostd`) can hold the assertion when an agent session is active, but the client cannot control this directly.
- **Current working directory in status bar** (e.g. `~/Workspace/<project>:<branch>`): CWD comes from OSC-7 (shell integration) emitted by the host PTY. This is already supported via the OSC-7 seam in slopdesk's wire protocol, so the status bar display is achievable.
- **Git branch in status bar** (`:main` suffix): Requires OSC-7 or a separate shell-integration hook that emits branch info. Claude Code's shell already emits this on supported setups.
- **iOS client pane chooser for agent tabs**: The vertical tab strip with badge dots needs to render on the iOS client's pane chooser UI, but badge state must be forwarded from the host over the control channel — this is an additional wire message not currently defined.
