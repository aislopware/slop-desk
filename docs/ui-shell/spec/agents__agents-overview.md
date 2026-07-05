# Working with Code Agents

## Summary

SlopDesk integrates with coding agents (Claude Code, Codex, OpenCode) rather than replacing their CLIs, via a small hook/plugin that lets the agent report state (working / done / waiting). This unlocks live tab badges, system notifications, conversation history, prompt queuing, a multi-line Composer input, and Send-to-Chat context injection. The agent runs in a first-class pane; the client adds the supervisory UI on top.

## Behaviors

- **Live tab badges (vertical tab strip)**: Each tab shows current agent state (working / done / waiting on user) without switching to it.
- **System notifications**: Fire on task completion or when an agent waits for approval/input. App can keep the Mac awake so a long run doesn't stall on sleep.
- **Composer (multi-line input)**: Replaces the single-line prompt with a float-on-top multi-line panel supporting undo/redo and image paste.
- **Prompt Queue (⌘⇧M)**: Queue commands while an agent is busy; app dispatches each at the next idle prompt automatically.
- **Send to Chat**: Drops a terminal selection, last command's output, or a file-pane snippet into the agent conversation — no copy-paste.
- **History**: Every conversation is captured; sessions resume days later or search across all tabs.
- **Fork / Branch Session**: Fork/branch a conversation into a split or new tab to try a second approach without losing the original.
- **Built-in file viewer/editor**: Read files the agent changed beside the chat, no separate editor window.
- **Hook/plugin install**: On first agent run, app offers to install a small hook (Claude Code, Codex) or plugin (OpenCode) into that agent's config. Approve once. The hook lets the agent report start/finish/waiting state.
- **Restart prompt**: After hook install, app may prompt to restart the agent in that tab; once restarted, badges/notifications/history/fork activate automatically.
- **Agent detection is automatic after setup**: No ongoing configuration once the hook is installed.
- **Supported agents**: Claude Code (`claude`), Codex (`codex`), OpenCode (`opencode`) — run exactly as today.

### Claude-Code-specific notes (agent-generic vs Claude-Code-specific)
- The **hook mechanism** is Claude-Code-specific (hooks into Claude Code's config). Codex also uses a hook; OpenCode uses a plugin. Integration surface differs per agent but the UX outcome (badges, notifications, history) is identical.
- **Prompt Queue** (`⌘⇧M`) is agent-generic — dispatches at any idle shell prompt.
- **Send to Chat** is agent-generic — works against whichever agent is in the active pane.
- **History and Fork** are agent-generic at the app level; conversation capture depends on the hook being installed.

## Keybindings

| Action | Keys |
|--------|------|
| Queue command (Prompt Queue) | `⌘⇧M` |

## Config keys

No config keys on this overview page. Config lives in Setup (per-agent API keys, models) and individual feature pages (Composer, Monitor Tasks, etc.).

| Key | Default | Effect |
|-----|---------|--------|
| _(none on this page)_ | — | — |

## Visual spec

### Screenshot: code-agents.png

**Overall layout and window chrome**
Standard macOS window, light (near-white) background, rounded corners, traffic-light buttons top-left. Title bar shows "OpenCode" center-aligned in system font, no subtitle. No custom chrome beyond the standard title bar; no toolbar strip.

**Left sidebar — vertical tab strip**
~160–170 px wide, light gray background (~#F2F2F2 light theme, slightly darker than content). Headed by a "TABS" label in small all-caps gray. Tabs listed vertically, each row ~28–30 px tall, left-padded compact sans-serif (~12–13 pt, semibold active / regular inactive).

Tab label examples (truncated with ellipsis):
- `# freerdp-rdp-udp-mu…`
- `# hardware decoder`
- `# investigate why scre…`
- `abner@MacBook-Pro…`
- _(blank separator gap)_
- `abner@MacBook-Pro…`
- _(blank separator gap)_
- `OC | Split terminal feat…` — orange dot badge (right side)
- `OC | Debug OSC notifi…` — orange dot badge
- `OC | Add agents-overv…` — filled dark dot badge (solid = active/working)
- `code-review-todos.md`
- `OC | Fix opencode fini…`
- `OC | Review GUI user e…`
- **`OpenCode`** — currently selected, bold/highlighted with darker background strip, no badge
- `~/Simplify`
- _(blank separator gap)_
- `build.sh`
- `abner@MacBook-Pro…`

**Badge design**: Small circular dots (~6–8 px) at the trailing edge of the tab row, right-aligned. Orange/amber fill = working or needs attention. Dark filled circle = likely active/current task. No badge = idle/done.

**Tab item prefix conventions**: Named OpenCode session tabs carry `OC | ` before the task description. Raw shell tabs show `#` prefix or `username@hostname`. The selected `OpenCode` tab has no prefix — a bare agent launch tab.

**Content area — main pane (right of sidebar)**
Fills the window remainder. Shows the OpenCode TUI splash screen:
- Large wordmark "openCode" in chunky bold font, split coloring: "open" dark/black, "Code" lighter gray-green, ~40 pt. Centered horizontally, upper-center.
- Below: input prompt area — "Ask anything…" placeholder in gray, followed by `"Fix broken tests"` as an example prompt in darker weight. Second line: `Build · GLM-5.1 OpenCode Go` — status/model indicator (build target + model) in small gray.
- Below that: breadcrumb/context strip in small gray: `agents-overview.md   tab   agents   ctrl+p   commands` (current file, tab name, `ctrl+p` commands hint).
- Bottom: tip callout in faint yellow/amber pill: `● Tip   Enable scroll_acceleration in tui.json for smooth macOS-style scrolling`. Prefix = small filled yellow-orange dot, bold "Tip", then regular text.

**Status bar — bottom of main pane**
Two items anchored to bottom corners:
- Left: `~/Workspace/<project>:<branch>` — cwd + git branch, small gray monospace.
- Right: `1.16.2` — version, small gray.

**Typography**
- Tab labels: system sans-serif (SF Pro or similar), ~12–13 pt, regular inactive / semibold selected.
- Content wordmark: custom thick display font.
- Status bar / breadcrumbs: monospace, ~11 pt, muted gray (~#999 light theme).
- Sidebar background ~#F0F0F0; active tab row ~#E0E0E0 or slightly darker pill.
- Badges: filled circles, orange ~#FF9500 (amber) for working/waiting, dark ~#1A1A1A for current/selected-task.

**Spacing density**
Compact: tightly stacked tabs, ~4–6 px top/bottom per row. No section separators except blank tab rows as visual gaps.

**No toolbar icons/buttons** in the sidebar beyond labels and badges. No hamburger, add-tab, or gear icon in the screenshot.

## Screenshots

- `code-agents.png`

## SlopDesk mapping notes

### Maps well (1:1 or near-1:1)

- **Vertical tab strip with badges**: SlopDesk already has a tab/pane model (`WorkspaceStore`, `PaneKind`). Badge states (working / done / waiting) map to existing `ClaudeStatus` / `ClaudePaneDetector`. Add badge rendering to sidebar tab rows in the same dot-style.
- **Live agent state detection**: `ClaudePaneDetector` and `AgentControlListener` already detect Claude Code state, covering the working/done/waiting badges for Claude Code.
- **Prompt Queue**: Maps onto the `slopdesk-ctl` / NDJSON agent-control socket. Queue entries dispatch as PTY writes at OSC-133 idle prompts.
- **Notification system**: macOS `UNUserNotificationCenter` fires on `ClaudePaneDetector` state transitions. iOS client receives push or local notifications from the host bridge.
- **Built-in file viewer**: SlopDesk has an editor/file pane concept in `WorkspaceStore`; file viewing beside chat works with the split-pane layout.
- **History / session capture**: `ReplayBuffer` gives lossless reconnect but is not conversation history. A separate OSC-133 transcript capture per pane is needed for history search.

### Partial maps (requires adaptation)

- **Composer (float-on-top multi-line input)**: Needs a floating panel writing to the active PTY. "Float on top" works on macOS (NSPanel `.floating` window level) but on iOS becomes a sheet/popover — not 1:1.
- **Send to Chat**: Needs a pane-selection action injecting text into a specific agent pane's PTY. Selection-to-PTY injection exists (OSC-52 clipboard + keystroke injection), but "drop into agent conversation" needs agent-aware targeting (which pane is the active agent).
- **Fork / Branch Session**: The session is a remote PTY on the host Mac. Forking spawns a new PTY from the same cwd/shell state — achievable via `slopdesk-ctl` creating a session with inherited `cwd` — but conversation state (Claude Code's in-process context) can't be cloned; only shell/cwd forks.

### Cannot map 1:1 (flag)

- **Hook install UX**: Design installs a hook into Claude Code's config (`.claude/settings.json` or similar) with an in-terminal approval dialog. In SlopDesk the host runs the agent; the client can't access the host's config files. Hook install must happen host-side via `slopdesk-ctl` or a pre-configured setup script. No in-app "approve once" flow from the iOS client.
- **Keep Mac awake during agent run**: `IOPMAssertionCreateWithName` (power assertion) must run on the macOS host, not the client. Host daemon (`slopdesk-hostd`) can hold the assertion during an active agent session; the client can't control this directly.
- **Cwd in status bar** (e.g. `~/Workspace/<project>:<branch>`): Cwd comes from OSC-7 (shell integration) emitted by the host PTY — already supported via the OSC-7 seam in SlopDesk's wire protocol, so the display is achievable.
- **Git branch in status bar** (`:main` suffix): Requires OSC-7 or a separate shell-integration hook emitting branch info. Claude Code's shell already emits this on supported setups.
- **iOS client pane chooser for agent tabs**: The badged tab strip must render on the iOS pane chooser, but badge state must be forwarded from the host over the control channel — an additional wire message not currently defined.
