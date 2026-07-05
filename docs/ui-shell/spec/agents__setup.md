# Setup

## Summary

SlopDesk does NOT run agents itself — users continue using Claude Code, Codex, or OpenCode exactly as they normally would. The one-time setup described on this page teaches each agent to report its runtime state back to SlopDesk, so SlopDesk can show live tab badges, fire system notifications, resume sessions, and surface history. It is a single click per agent.

The integration is hook-based: SlopDesk writes into the agent's own config file (e.g. `~/.claude/settings.json` for Claude Code) and the agent calls those hooks at lifecycle events. SlopDesk never runs agents or intercepts their I/O; it only receives state signals.

---

## Behaviors

- **Settings entry point**: User opens Settings (⌘,) and navigates to the **Agents** tab in the sidebar.
- **Per-agent install card**: Each supported agent has its own card section. Clicking **Install** (or **Install Hooks** / **Install Plugin** depending on agent) writes SlopDesk's config into the agent's config file. Only the SlopDesk-specific entries are touched; the rest of the file is left untouched.
- **Install button state transition**: After clicking Install, the button label changes to **Installed** (pill/outline style, inactive/disabled appearance), and an **Uninstall** button appears alongside it. The Status row beneath shows a green checkmark label "✓ Installed".
- **Not-yet-installed state**: The Install button is present and active. The Status row shows "Not Installed" in a neutral/grey color (no checkmark).
- **Uninstall**: Clicking **Uninstall** cleanly removes SlopDesk's entries from the agent's config file and leaves the remainder untouched. The card reverts to the Install button.
- **Restart requirement**: The integration takes effect only after the agent restarts with the new config. If an agent was already running in a tab it must be restarted.
  - For **OpenCode**: send one message after restart so the plugin registers the session.
  - For **Codex**: if SlopDesk or Codex was recently updated, approve the trust prompt when it restarts.
- **Agent Behavior toggles activate when at least one integration is installed**: The "Agent Behavior" section at the top of the Agents tab is greyed out until at least one agent's hooks are installed. Once installed, the section becomes interactive.
- **Seven behavior toggles** (see Config Keys table below).
- **State signals power downstream features**: The hooks supply the state events that drive tab badges, the Monitor Tasks dashboard, the History transcript with Resume, and the branch/fork actions for spinning off a new task from an existing context.

**Agent-generic vs Claude-Code-specific notes** (relevant for slopdesk's initial Claude Code scope):
- The install mechanism is identical in concept for all three agents; only the config file path and install action label differ.
- The seven behavior toggles are agent-generic — they apply uniformly to whichever agents are installed.
- "Resume Session on Recovery" is particularly relevant for Claude Code where session continuity across reconnects matters.
- The "branch / fork actions for spinning a new task off an existing context" mentioned as downstream behavior is Claude-Code-specific in practice (Claude Code has explicit session/context concepts).

---

## Keybindings

| Action | Keys |
|--------|------|
| Open Settings (to reach the Agents tab) | ⌘, |

No other keybindings are defined on this page.

---

## Config Keys

These are the seven toggles in the **Agent Behavior** section of the Agents tab. They become active once at least one agent integration is installed.

| Key | Default | Effect |
|-----|---------|--------|
| Badge While Processing | On | Marks the tab with a badge while the agent is actively working on a task. |
| Badge When Task Completes | On | Marks the tab with a badge when the agent finishes a task. |
| Badge When Awaiting Input | On | Marks the tab with a badge when the agent is waiting for approval or user input. |
| Notify When Task Completes | On | Sends a macOS system notification when the agent completes a task. |
| Notify When Awaiting Input | On | Sends a macOS system notification when the agent needs the user. |
| Prevent Sleep While Processing | Off | Keeps macOS awake (suppresses sleep) while a task is actively running. |
| Resume Session on Recovery | On | Reopens the agent session automatically when a recovered terminal comes back. |

---

## Visual Spec

### Screenshot: install-agent-integeration.png

**Overall layout**: A macOS sheet/panel window with standard traffic-light controls (red/yellow/grey) in the top-left. The window is white with a subtle drop-shadow and rounded corners (~12px radius). It is split into two regions:

**Left sidebar** (~30% width, light grey background #F2F2F2):
- A search field at the top (rounded pill shape, grey background, magnifying glass icon, placeholder text "Search").
- Below it, a vertical list of navigation items each with a small SF-Symbol-style icon to the left of the label:
  - ⊙ General
  - >_ Shell
  - ▷ Controls
  - ▣ Editor
  - **⏻ Agents** (currently selected — shown with a medium-grey rounded-rect highlight behind the row, bold label text)
  - ⊙ Appearance
  - □ Recipes
  - ⚡ Key Bindings
  - 🔧 Advanced
- Typography: ~13–14pt system font, medium weight for selected, regular for others. Icon color: dark grey (#555). Selected row highlight: rounded rect, grey (#DEDEDE approx).

**Right content area** (~70% width, white background):
- No scroll chrome visible; content fills the pane.
- Three agent sections stacked vertically, each section separated by ~24px vertical gap:

**CLAUDE CODE** section:
- Section header: all-caps small label "CLAUDE CODE" in a muted grey (#999), ~11pt, uppercase tracking. No separator line.
- A card row (white background, rounded border ~6px radius, subtle #E5E5E5 border) containing:
  - Left: bold label **"Install Hooks"** (~14pt, #1A1A1A), below it a description line in grey (#666, ~12pt): "Add SlopDesk hooks to ~/.claude/settings.json for real-time state updates"
  - Right: two pill buttons side-by-side:
    - **"Installed"** — pill outline button (rounded, white fill, #D0D0D0 border, label in black), appears inactive/dimmed (indicating already-installed state, not clickable / no hover effect implied)
    - **"Uninstall"** — identical pill outline button (rounded, white fill, #D0D0D0 border, black label), appears active/clickable
  - Below the card row, a "Status" row: label "Status" on the left in grey, value "✓ Installed" on the right in **green** (#34C759 approx — macOS system green), ~13pt.

**CODEX** section:
- Same visual treatment as Claude Code section.
- Section header: "CODEX" in all-caps muted grey.
- Card: bold **"Install Hooks"**, description "Add SlopDesk hooks to ~/.codex/hooks.json for real-time state updates".
- Two buttons: "Installed" + "Uninstall" (same styling as Claude Code section).
- Status: "✓ Installed" in green.

**OPENCODE** section:
- Section header: "OPENCODE" in all-caps muted grey.
- Card: bold **"Install Plugin"**, description "Add SlopDesk plugin to ~/.config/opencode/plugins/ for real-time state updates".
- One button: **"Install"** — single pill outline button (rounded, white fill, border, black label). Only one button (not yet installed so no Uninstall button).
- Status: "Not Installed" in neutral grey (#999), no checkmark.

**Typography summary**: System font (SF Pro Text). Section headers ~11pt all-caps grey. Card titles ~14pt semibold. Descriptions ~12pt grey #666. Buttons ~13pt regular, rounded pill ~28pt height. Status labels ~13pt; installed=green, not installed=grey.

**Spacing**: ~16px internal card padding. ~8px between card title and description. ~12px between buttons. ~16px between card and status row. ~24px between agent sections.

**Color palette observed**: White (#FFFFFF) main bg, light grey (#F2F2F2) sidebar, muted grey (#999 / #666) for section headers and descriptions, near-black (#1A1A1A) for titles and button labels, macOS green (#34C759) for installed status, light border (#D0D0D0 / #E5E5E5) for buttons and cards.

---

## Screenshots

- `install-agent-integeration.png` (note: filename has a typo in the original — "integeration" — preserved as-is)

---

## Implementation Notes

### Direct implementation

1. **Settings panel / Agents tab**: SlopDesk already has `ConfigStore` (EnvConfig + EnvBridge + PreferencesStore). An "Agents" settings section with per-agent install cards can be added as a new `SettingsSection.agents` view inside the existing macOS Settings sheet.

2. **Claude Code hook installation**: SlopDesk targets Claude Code as its primary agent. The install action writes `~/.claude/settings.json` hooks — this is pure local filesystem I/O on the **client Mac** (same machine where the terminal runs). This maps cleanly: the macOS client app can write the file directly.

3. **Badge While Processing / Badge When Task Completes / Badge When Awaiting Input**: These drive tab badges. SlopDesk's `WorkspaceStore` and `PaneModel` already carry per-pane state. A `ClaudeAgentState` enum (`.idle`, `.processing`, `.awaitingInput`, `.complete`) can be injected via `ClaudeStatus` / `ClaudePaneDetector` (already referenced in memory: `slopdesk-night-supervision-roadmap`). Tab badge rendering maps onto the existing tab bar UI.

4. **Notify When Task Completes / Notify When Awaiting Input**: Standard macOS `UNUserNotificationCenter` calls from the client app. Straightforward.

5. **Resume Session on Recovery**: SlopDesk already has `DetachedSessionStore` (`SLOPDESK_DETACH_ENABLED`) and detach/reattach logic. "Reopen the agent session when a recovered terminal comes back" maps to triggering a Claude Code session resume (re-sending the session ID or re-cd-ing and running `claude --resume`) after a reconnect event.

6. **Prevent Sleep While Processing**: `IOPMAssertion` on macOS. Trivial client-side implementation.

7. **Uninstall**: Reverse the hook write — parse `~/.claude/settings.json` and remove SlopDesk's hook entries, leaving the rest intact.

### Platform / architecture constraints

1. **"Status: ✓ Installed" verification**: Reading back the config file after writing to confirm install is straightforward on the local client. However, if the user's Claude Code config lives on the **remote host** (e.g. if the user SSHes into a dev box and runs Claude Code there), the `~/.claude/settings.json` being modified is on the remote machine — slopdesk's client app cannot directly write it. Mitigation: for now, slopdesk's agent integration is scoped to **local Claude Code sessions** (Claude Code running on the client Mac). Remote-host Claude Code sessions would need a host-side install helper (future work). Flag this with a UI note: "Install applies to local Claude Code sessions."

2. **Codex and OpenCode support**: SlopDesk's initial scope is Claude Code only. The settings panel should show only a Claude Code card (not Codex/OpenCode cards), or show the others as greyed-out / "coming soon."

3. **"Branch / fork actions for spinning a new task off an existing context"**: This downstream feature requires Claude Code's `--resume` / session branching CLI flags and the History panel. SlopDesk should mark this as a follow-on feature once the basic hook integration is working (History panel and Composer are not yet built).

4. **Hook mechanism on iOS client**: On iOS, the client cannot write to `~/.claude/settings.json` at all (sandboxed filesystem). If Claude Code runs on a remote macOS host, the install button in an iOS slopdesk session would need to send an install command over the existing slopdesk control channel to the host-side daemon (`slopdesk-hostd`). This is a non-trivial architectural addition; flag it as iOS-deferred.

5. **"Approve the trust prompt" (Codex)**: Codex-specific, not relevant to Claude Code scope.

6. **Agent Behavior toggles greyed out until install**: This UX gating is straightforward to implement — observe whether `~/.claude/settings.json` contains SlopDesk's hooks and conditionally enable the toggles. The check should be re-run each time the Settings panel opens (not cached forever).

### Implementation order recommendation

1. Add `AgentIntegrationStore` that reads/writes `~/.claude/settings.json` hooks.
2. Add Agents tab to Settings sheet with Claude Code card (Install / Uninstall / Status).
3. Wire `ClaudePaneDetector` state events into `AgentBehaviorSettings` toggles (badge + notify).
4. Implement tab badge rendering driven by agent state.
5. Implement `UNUserNotificationCenter` notifications.
6. Implement `IOPMAssertion` for Prevent Sleep.
7. Wire Resume Session on Recovery into `DetachedSessionStore` reconnect path.
