# Monitor Tasks

> **URL slug:** `agents/parallel-tasks`, but the page title and feature name are "Monitor Tasks" (slug reflects an earlier "parallel tasks" draft).

## Summary

Per-tab, opt-in monitoring controls for agent tabs so background/long-running tasks surface state without babysitting. Controls live in each agent tab's **Notifications & Privileges** panel (from the Workspace Command panel and the menu bar); global defaults live in **Settings**. Being per-tab, a noisy background task can badge/notify while a watched tab stays quiet.

Four capabilities:
1. **Tab Badge** — icon overlay on the tab row indicating agent state
2. **Notification** — macOS system notification on off-screen state change
3. **Prevent Sleep While Processing** — IOKit/NSProcessInfo power assertion tied to agent activity
4. **Queue next command** — shell-integration-gated command queue dispatched at idle prompt

## Behaviors

### Agent-generic behaviors (apply to any shell-integrated agent)

- Each agent tab is independently configurable; toggles don't cross tabs.
- Global defaults in **Settings** apply to newly created agent tabs.
- Tab badges auto-clear on tab focus; also clearable manually via **Clear Badge**.
- Command queue is gated on shell integration: a queued command fires only when the prompt is detected empty (idle), so it never clobbers in-progress input.
- Queued commands execute FIFO — each line fires after the previous finishes and a fresh prompt appears.
- Prevent Sleep holds the assertion only while the agent is actively processing, releasing it the moment the agent goes idle — no permanent keep-awake. Per-tab: only tabs with a processing agent AND the toggle on hold it.
- Notifications respect macOS Focus/Do-Not-Disturb via standard Notification Center; clicking one returns to the correct tab.

### Claude-Code-specific behaviors

- "Awaiting Input" covers tool-use approvals and explicit blocking questions from Claude Code.
- "Task Completes" maps to Claude Code finishing its current turn (returning to idle prompt).
- Badge states — processing spinner, warning/error triangle, hand (awaiting input), green check (complete), green dot (plain active) — correspond to Claude Code states detected via shell integration + OSC 133 / progress protocol.

### Tab Badge specifics

- **Badge While Processing** — shown continuously while running. Off by default (noisy when watching the tab).
- **Badge When Task Completes** — appears when the agent finishes its turn. Useful for backgrounded tasks.
- **Badge When Awaiting Input** — appears when blocked on user approval or a question.
- Badge auto-clears on tab focus; **Clear Badge** dismisses it manually.

### Notification specifics

- **Notify When Task Completes** — on by default.
- **Notify When Awaiting Input** — opt-in.

### Keep macOS awake

- Toggle: **Prevent Sleep While Processing**. Off by default. Per-tab; a tab without an active processing agent holds no assertion.

### Queue next command

- Queue one or more commands, dispatched at the next idle shell prompt, in insertion order.
- Requires shell integration (prompt detection); won't fire into an active/non-idle prompt.
- See also: `/agents/prompt-queue` for queuing from the composer, reordering, and editing pending entries.

## Keybindings

No keybindings on this page. Badge/notification toggles are controlled via the Notifications & Privileges UI panel and Settings, not keyboard shortcuts.

| Action | Keys |
|--------|------|
| *(none documented)* | — |

## Config keys

All toggles are per-tab with global defaults in Settings. No TOML/JSON key names are given; the canonical names are the UI labels below.

| Key (UI label) | Default | Effect |
|----------------|---------|--------|
| Badge While Processing | Off | Badge the tab continuously while the agent works |
| Badge When Task Completes | — (not stated, implied off) | Badge when the agent finishes its current turn |
| Badge When Awaiting Input | — (not stated, implied off) | Badge when blocked on approval or question |
| Notify When Task Completes | **On** | Post a Notification Center notification when agent finishes |
| Notify When Awaiting Input | Off | Post a notification when agent awaits approval/input |
| Prevent Sleep While Processing | **Off** | Hold a macOS power assertion while agent is actively processing |

## Visual spec

### tab-badge.png — Tab sidebar with badge states

**Layout:** Standard macOS window (rounded frame, drop shadow, top-left traffic-light controls), split by a vertical divider:

- **Left — tab sidebar** (~30% width, ~260 px at 1x): light gray background (`~#F0EFED`, near system groupedBackground). "TABS" small-caps section label top-left, horizontal-ellipsis menu icon (≡) top-right; vertical list of tab rows.
- **Right — terminal pane** (~70% width): white/near-white; active terminal prompt.

**Tab sidebar rows (top to bottom):**

1. **full-release.sh** — gray circular spinner at right edge (processing/running). Label regular weight, dark gray.
2. **running build task** — red warning triangle badge (⚠, `~#E05252`) — error/warning needing attention.
3. **plan next move** — amber raised-hand emoji badge (🤚) — awaiting input / blocked.
4. **OpenCode** — green filled circle + white checkmark (✓, `~#34A853`) — task complete.
5. **abner@MacBook-AB:...** (non-selected, above selected) — small solid green dot (same green, no icon) — plain active/has-content variant.
6. **abner@MacBook-AB:...** (selected, bottom) — selected treatment: white rounded card/pill, slightly elevated; "zsh" shell label at right in gray monospace; no badge.

**Badge icon properties:**
- Right-aligned within the row, flush to the sidebar right edge with ~8 px margin; ~16–18 pt square.
- Spinner: monochrome gray circular (system activity indicator).
- Warning triangle: solid red/coral with exclamation, `~#E04B4B`.
- Hand (await input): orange-tinted 🤚, `~#D4632A`.
- Green checkmark circle: filled green + white bold check, `~#3DA350`.
- Green dot: solid filled circle, same green, no inner icon; smaller than checkmark.

**Tab row typography:**
- SF Pro regular. Label color `~#3A3A3A` non-selected; selected slightly bolder; "zsh" label gray, smaller/secondary.
- Row height ~44 pt with comfortable vertical padding. TABS header: small-caps uppercase, muted gray, ~11 pt.

**Terminal pane (right):**
- Title bar: `abner@MacBook-AB: ~/Workplace/slopdesk`, gray centered, standard macOS title style.
- Prompt line: `~/Workplace/slopdesk (main ✗)` + orange/amber star-burst icon (dirty/stash state) + green right-pointing triangle (play, likely queued/running indicator).
- Cyan/teal path `~/Workplace/slopdesk` and muted purple-gray `(main ✗)` show shell-integration-colored prompt segments.
- Background pure/near white.

**Color palette:**
- Sidebar bg: `#F0EFED` (warm light gray)
- Terminal bg: `#FFFFFF` or `#FAFAFA`
- Selected tab card: `#FFFFFF` + subtle shadow
- Badge red (warning): `~#E04B4B`
- Badge orange (await): `~#D4632A`
- Badge green (complete / dot): `~#3DA350`
- Badge spinner: gray (system default)
- TABS label: `~#9A9A9A`
- Tab label text: `~#3A3A3A`
- "zsh" secondary label: `~#8A8A8A`

## Screenshots

- `tab-badge.png` — Tab sidebar showing five badge states: spinner (processing), red warning triangle (error/alert), orange hand (awaiting input), green checkmark circle (complete), green dot (active), plus the selected tab with "zsh" shell label.

## Implementation notes

### Direct implementation

- **Tab Badge / sidebar rows** — SlopDesk already has a sidebar pane list (`WorkspaceStore`, pane rows). Layer badge icons (spinner, warning, check, hand, dot) onto each pane row via SwiftUI overlays or NSView badges; right-aligned per-pane state maps cleanly onto the existing pane chooser row layout.
- **Agent state machine** — Map badge states (processing, awaiting input, complete, error) onto Claude Code states via OSC 133 markers (prompt = idle, command running = processing) plus existing `ClaudeStatus` / `ClaudePaneDetector`. Wire detected state into a per-pane `AgentBadgeState` enum.
- **Notification (macOS)** — standard `UNUserNotificationCenter` call on pane transition to `.complete` / `.awaitingInput`; same pattern already used for other macOS notifications.
- **Queue next command** — Gate a command queue on the PTY/shell-integration path (OSC 133 prompt detection): on a fresh prompt (type A = prompt start, type B = command start not yet seen), pop the next queued line and send it as PTY input. Sits in `SlopDeskTransport` or a new `CommandQueue` actor.

### Partial / constrained

- **Prevent Sleep power assertion** — macOS host: `IOPMAssertionCreateWithName` / `ProcessInfo.processInfo.beginActivity`, maps cleanly for the macOS client. iOS equivalent: `UIApplication.beginBackgroundTask` + `UIDevice.current.isBatteryMonitoringEnabled`, but background execution is time-limited (~30 s then system may suspend). iOS clients cannot guarantee the host won't sleep — sleep prevention must run on the macOS HOST, not the iOS client.
- **Per-tab global defaults in Settings** — store via `PreferencesStore` / `SettingsKey` (`Defaults` product); expose in the macOS Settings pane under an "Agents"/"Notifications" section.
- **"Clear Badge" manual action** — needs a tap target on the pane row: iOS swipe action or long-press context menu; macOS right-click context menu item or hover button.

### Platform / architecture constraints

- **Notification click → correct tab focus** — macOS: `UNUserNotificationCenterDelegate` `userNotificationCenter(_:didReceive:)` carrying a pane identifier in `userInfo`. iOS: deep-linking into a pane requires the app foreground/background (not suspended); if terminated, pane context must be re-established — solvable but needs extra lifecycle handling.
- **Shell integration prerequisite** — command queue and prompt-based badge clearing require OSC 133 markers from the remote shell. Without them (host shell lacking shell integration), the feature degrades: no prompt detection means queued commands can't be safely dispatched. Surface a warning if OSC 133 isn't detected within a timeout after connection.
- **"Badge While Processing" spinner** — animated spinner (NSProgressIndicator / system activity indicator equivalent); use SwiftUI `ProgressView()` (circular, indeterminate). Keep it in a separate isolated View so per-frame animation doesn't re-render the pane list.
- **Remote host vs. local process** — the agent (Claude Code) runs on the REMOTE macOS host over SSH/TCP, not locally. Badge state must be detected from the remote PTY stream (OSC 133 + `ClaudePaneDetector` heuristics), not a local process observer. Existing `ClaudeStatus` / `AgentControlListener` infrastructure already handles this — wire badge updates from those signals.
