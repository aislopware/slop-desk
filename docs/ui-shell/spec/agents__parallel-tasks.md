# Monitor Tasks

> **URL slug:** `agents/parallel-tasks` — the page title is "Monitor Tasks". The slug likely reflects an earlier draft name ("parallel tasks") while the shipped feature is called "Monitor Tasks". Treat the feature name as "Monitor Tasks".

## Summary

SlopDesk provides a suite of per-tab, opt-in monitoring controls for agent tabs so that long-running or background agent tasks surface their state without requiring the user to babysit a terminal tab. Controls live in each agent tab's **Notifications & Privileges** panel (accessible from the Workspace Command panel and the menu bar); their global defaults live in **Settings**. Because they are per-tab, a noisy background task can badge and notify while an actively-watched tab stays quiet.

The four monitoring capabilities are:
1. **Tab Badge** — icon overlay on the tab row entry indicating agent state
2. **Notification** — macOS system notification when state changes off-screen
3. **Prevent Sleep While Processing** — IOKit/NSProcessInfo power assertion tied to agent activity
4. **Queue next command** — shell-integration-gated command queue dispatched at idle prompt

## Behaviors

### Agent-generic behaviors (apply to any shell-integrated agent)

- Each agent tab is independently configurable; toggling a behavior on one tab does not affect other tabs.
- Global defaults for all toggles live in **Settings** and are applied to newly created agent tabs.
- Tab badges clear automatically when the user focuses (activates) the tab; they can also be cleared manually via **Clear Badge**.
- The command queue is gated on shell integration: a queued command only fires when the prompt is detected as empty (idle), so it never clobbers in-progress input.
- Queued commands execute in FIFO order — each line fires once the previous command finishes and a fresh prompt appears.
- Prevent Sleep holds a power assertion only while the agent is actively processing; the assertion is released the moment the agent goes idle — no permanent keep-awake.
- Prevent Sleep is per-tab: only tabs with a processing agent AND the toggle enabled hold the assertion; idle tabs or tabs with the toggle off do not.
- Notifications respect macOS Focus/Do-Not-Disturb and are delivered through standard Notification Center. Clicking a notification brings the user back to the correct tab.

### Claude-Code-specific behaviors

- "Awaiting Input" state covers both tool-use approvals and explicit questions from Claude Code that block further progress.
- "Task Completes" maps to Claude Code finishing its current turn (returning to idle prompt).
- The badge states — processing spinner, warning/error triangle, hand (awaiting input), green check (complete), green dot (plain active) — correspond directly to Claude Code agent states as detected by shell integration + OSC 133 / progress protocol.

### Tab Badge specifics

- **Badge While Processing** — badge is shown continuously while agent is running. Off by default (can be noisy when you are watching the tab).
- **Badge When Task Completes** — badge appears when agent finishes its turn. Useful for backgrounded tasks.
- **Badge When Awaiting Input** — badge appears when agent is blocked on user approval or a question.
- Badge auto-clears on tab focus.
- **Clear Badge** is a manual action to dismiss the badge.

### Notification specifics

- **Notify When Task Completes** — on by default.
- **Notify When Awaiting Input** — opt-in.

### Keep macOS awake

- Toggle name: **Prevent Sleep While Processing**
- Off by default.
- Scoped to each tab; a tab without an active processing agent does not hold the assertion.

### Queue next command

- User can queue one or more commands; they are dispatched at the next idle shell prompt.
- Queued commands fire in insertion order.
- Requires shell integration (prompt detection); will not fire into an active/non-idle prompt.
- See also: `/agents/prompt-queue` for queuing from the composer, reordering, and editing pending entries.

## Keybindings

No keybindings are documented on this page. Badge and notification toggles are controlled via the Notifications & Privileges UI panel and Settings, not keyboard shortcuts.

| Action | Keys |
|--------|------|
| *(none documented)* | — |

## Config keys

All toggles are per-tab with global defaults in Settings. No TOML/JSON key names are given on this page; the canonical names are the UI labels below.

| Key (UI label) | Default | Effect |
|----------------|---------|--------|
| Badge While Processing | Off | Badge the tab continuously while the agent is working |
| Badge When Task Completes | — (not stated, implied off) | Badge the tab when the agent finishes its current turn |
| Badge When Awaiting Input | — (not stated, implied off) | Badge the tab when agent is blocked on approval or question |
| Notify When Task Completes | **On** | Post a macOS Notification Center notification when agent finishes |
| Notify When Awaiting Input | Off | Post a notification when agent awaits approval/input |
| Prevent Sleep While Processing | **Off** | Hold a macOS power assertion while agent is actively processing |

## Visual spec

### tab-badge.png — Tab sidebar with badge states

**Overall layout:** Standard macOS window shell with a rounded rectangle window frame, drop shadow, and the three traffic-light window controls (close/minimize/zoom) in the top-left. The window is divided into two regions by a vertical divider:

- **Left region — tab sidebar** (~30% width, ~260 px wide at 1x): light gray background (`#F0EFED` approximately, near system groupedBackground). Has a "TABS" section label in small caps at the top left, and a horizontal-ellipsis menu icon (≡) at the top right of the section header. Contains a vertical list of tab rows.
- **Right region — terminal pane** (~70% width): white/near-white background. Shows an active terminal prompt.

**Tab sidebar rows (top to bottom):**

1. **full-release.sh** — no special badge; instead has an animated spinner icon (circular spinner, gray) at the right edge — indicates "processing/running". Tab label text is regular weight, dark gray.

2. **running build task** — has a red warning triangle badge (⚠ icon, solid red/coral `#E05252` approx.) at the right edge — indicates an error or warning state requiring attention.

3. **plan next move** — has an amber/orange raised-hand emoji badge (🤚, hand icon) at the right edge — indicates "awaiting input" / blocked on user.

4. **OpenCode** — has a green filled circle with white checkmark badge (✓, solid green `#34A853` approx.) at the right edge — indicates "task complete".

5. **abner@MacBook-AB:...** (non-selected, above selected) — has a small solid green circle badge (dot, no icon, same green as checkmark) at the right edge — indicates a simpler "active/processing" or "has content" state (plain dot variant).

6. **abner@MacBook-AB:...** (currently selected tab, bottom) — shown in a distinct selected-tab treatment: white background card/pill with a subtle rounded rectangle, slightly elevated visually; "zsh" label appears at the right edge in gray monospace text (showing the shell name); no badge icon.

**Badge icon visual properties:**
- All badge icons are right-aligned within the tab row, at a consistent x-position flush to the right edge of the sidebar with a small right margin (~8 px).
- Badge icons are small (approximately 16–18 pt square).
- Spinner: monochrome gray circular spinner (system activity indicator style).
- Warning triangle: solid filled red/coral triangle with exclamation mark inside; color approximately `#E04B4B`.
- Hand (await input): orange-tinted hand emoji 🤚, approximately `#D4632A` tone.
- Green checkmark circle: filled green circle with white bold checkmark; color approximately `#3DA350`.
- Green dot: solid filled circle, same green, no inner icon; smaller than checkmark badge.

**Tab row typography:**
- Font: system sans-serif (SF Pro), regular weight.
- Tab label text color: dark gray (approximately `#3A3A3A`) for non-selected tabs.
- Selected tab label: same dark gray but slightly bolder; "zsh" shell label is gray and smaller/secondary.
- Row height: approximately 44 pt, with comfortable vertical padding.
- TABS header: small-caps uppercase `TABS` in a muted gray, approximately 11 pt.

**Terminal pane content (right side):**
- Title bar text: `abner@MacBook-AB: ~/Workplace/slopdesk` in gray centered text, standard macOS window title style.
- Prompt line: `~/Workplace/slopdesk (main ✗)` followed by two small colored icons — an orange/amber star-burst icon (representing dirty/stash state) and a green right-pointing triangle (play icon, likely representing a queued or running command indicator).
- The cyan/teal colored path `~/Workplace/slopdesk` and `(main ✗)` in a muted purple-gray demonstrate shell-integration-colored prompt segments.
- Terminal background is pure white or near-white.

**Color palette summary:**
- Window background (sidebar): `#F0EFED` (warm light gray)
- Window background (terminal): `#FFFFFF` or `#FAFAFA`
- Selected tab card: `#FFFFFF` with subtle shadow
- Badge red (warning): `~#E04B4B`
- Badge orange (await): `~#D4632A`
- Badge green (complete / dot): `~#3DA350`
- Badge spinner: gray (system default)
- TABS label: `~#9A9A9A`
- Tab label text: `~#3A3A3A`
- Shell name "zsh" secondary label: `~#8A8A8A`

## Screenshots

- `tab-badge.png` — Tab sidebar showing five badge states: spinner (processing), red warning triangle (error/alert), orange hand (awaiting input), green checkmark circle (complete), green dot (active), and the selected tab with "zsh" shell label.

## Implementation notes

### Direct implementation

- **Tab Badge / sidebar tab rows** — SlopDesk already has a sidebar pane list (`WorkspaceStore`, pane rows). Badge icons (spinner, warning, check, hand, dot) can be layered onto each pane's row using SwiftUI overlays or NSView badges. The visual treatment (right-aligned, small icon, per-pane state) maps cleanly onto the existing pane chooser row layout.
- **Agent state machine** — The badge states (processing, awaiting input, complete, error) map onto Claude Code's detectable states via OSC 133 shell integration markers (prompt = idle, command running = processing) plus `ClaudeStatus` / `ClaudePaneDetector` which already exist in slopdesk. Wire the detected state into a per-pane `AgentBadgeState` enum.
- **Notification (macOS)** — standard `UNUserNotificationCenter` call when pane transitions to `.complete` or `.awaitingInput` states. Already done for other macOS notifications in the codebase; same pattern applies.
- **Queue next command** — SlopDesk's PTY/shell-integration path (OSC 133 prompt detection) can gate a command queue. When a fresh prompt is detected (OSC 133 type A = prompt start, type B = command start not yet seen), pop the next queued line and send it as PTY input. Implementation sits in `SlopDeskTransport` or a new `CommandQueue` actor.

### Partial / constrained

- **"Prevent Sleep While Processing" power assertion** — on macOS host this is `IOPMAssertionCreateWithName` / `ProcessInfo.processInfo.beginActivity`. Maps cleanly for the macOS client. For the iOS client, the equivalent is `UIApplication.beginBackgroundTask` + `UIDevice.current.isBatteryMonitoringEnabled`; background execution is time-limited on iOS (30 s then system may suspend). Flag this limitation: iOS clients cannot guarantee the host won't sleep; the sleep prevention must run on the macOS HOST machine, not the iOS client.
- **Per-tab global defaults in Settings** — SlopDesk's `PreferencesStore` / `SettingsKey` (via `Defaults` product) can store global defaults. Expose them in the macOS Settings pane under an "Agents" or "Notifications" section.
- **"Clear Badge" manual action** — needs a tap/click target on the pane row. On iOS the natural affordance is a swipe action or long-press context menu; on macOS it is a right-click context menu item or a button that appears on hover.

### Platform / architecture constraints

- **Notification Center click → correct tab focus** — on macOS client this works via `UNUserNotificationCenterDelegate` `userNotificationCenter(_:didReceive:)` carrying a pane identifier in the notification's `userInfo`. On iOS, deep-linking from a notification into a specific pane requires the app to be in foreground or background (not suspended); if the app is terminated on iOS, the pane context must be re-established. This is solvable but requires extra lifecycle handling.
- **Shell integration prerequisite** — the command queue and prompt-based badge clearing require OSC 133 markers from the remote shell. If the remote shell (on the slopdesk host) is not configured with shell integration, the feature degrades: no prompt detection means queued commands cannot be safely dispatched. SlopDesk should surface a warning if OSC 133 is not detected within a timeout after connection.
- **"Badge While Processing" spinner** — the processing badge is an animated spinner (NSProgressIndicator / system activity indicator equivalent). SlopDesk's pane rows in SwiftUI can use `ProgressView()` (circular, indeterminate) for the same effect. Ensure the animation does not cause excessive re-render of the pane list on every frame — keep the spinner in a separate isolated View.
- **Remote host vs. local process** — the agent (Claude Code) runs on the REMOTE macOS host over SSH/TCP, not locally in the client app. The badge state must be detected from the remote PTY stream (OSC 133 + `ClaudePaneDetector` heuristics), not from a local process observer. The existing `ClaudeStatus` / `AgentControlListener` infrastructure already handles this; wire badge state updates from those signals.
