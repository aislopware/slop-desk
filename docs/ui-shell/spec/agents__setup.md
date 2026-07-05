# Setup

## Summary

SlopDesk does NOT run agents — users keep using Claude Code, Codex, or OpenCode as normal. This one-time per-agent setup (one click) teaches each agent to report runtime state back to SlopDesk, enabling live tab badges, system notifications, session resume, and history.

The integration is hook-based: SlopDesk writes into the agent's own config (e.g. `~/.claude/settings.json` for Claude Code) and the agent calls those hooks at lifecycle events. SlopDesk never runs agents or intercepts their I/O — it only receives state signals.

---

## Behaviors

- **Settings entry point**: Settings (⌘,) → **Agents** tab in the sidebar.
- **Per-agent install card**: Each agent has its own card. Clicking **Install** / **Install Hooks** / **Install Plugin** (label varies by agent) writes SlopDesk's config into the agent's config file, touching only SlopDesk-specific entries.
- **Install button state transition**: After Install, the button becomes **Installed** (pill/outline, inactive/disabled), an **Uninstall** button appears alongside, and the Status row shows green "✓ Installed".
- **Not-yet-installed state**: Install button active; Status row shows "Not Installed" in neutral grey (no checkmark).
- **Uninstall**: Cleanly removes SlopDesk's entries, leaves the rest untouched; card reverts to the Install button.
- **Restart requirement**: Takes effect only after the agent restarts with the new config. An agent already running in a tab must be restarted.
  - **OpenCode**: send one message after restart so the plugin registers the session.
  - **Codex**: if SlopDesk or Codex was recently updated, approve the trust prompt on restart.
- **Agent Behavior toggles activate once ≥1 integration is installed**: The "Agent Behavior" section (top of Agents tab) is greyed out until at least one agent's hooks are installed, then becomes interactive.
- **Seven behavior toggles** (see Config Keys table below).
- **State signals power downstream features**: The hooks supply the state events driving tab badges, the Monitor Tasks dashboard, the History transcript with Resume, and branch/fork actions for spinning a new task off an existing context.

**Agent-generic vs Claude-Code-specific** (for SlopDesk's initial Claude Code scope):
- Install mechanism is identical across all three agents; only the config file path and action label differ.
- The seven behavior toggles are agent-generic — they apply uniformly to whichever agents are installed.
- "Resume Session on Recovery" is especially relevant for Claude Code (session continuity across reconnects).
- "Branch / fork actions" is Claude-Code-specific in practice (Claude Code has explicit session/context concepts).

---

## Keybindings

| Action | Keys |
|--------|------|
| Open Settings (to reach the Agents tab) | ⌘, |

No other keybindings on this page.

---

## Config Keys

The seven toggles in the **Agent Behavior** section, active once ≥1 agent integration is installed.

| Key | Default | Effect |
|-----|---------|--------|
| Badge While Processing | On | Badges the tab while the agent is actively working. |
| Badge When Task Completes | On | Badges the tab when the agent finishes a task. |
| Badge When Awaiting Input | On | Badges the tab when the agent awaits approval or input. |
| Notify When Task Completes | On | macOS system notification when the agent completes a task. |
| Notify When Awaiting Input | On | macOS system notification when the agent needs the user. |
| Prevent Sleep While Processing | Off | Suppresses macOS sleep while a task is running. |
| Resume Session on Recovery | On | Reopens the agent session when a recovered terminal comes back. |

---

## Visual Spec

### Screenshot: install-agent-integeration.png

**Overall layout**: macOS sheet/panel with traffic-light controls (red/yellow/grey) top-left. White window, subtle drop-shadow, rounded corners (~12px). Split into two regions.

**Left sidebar** (~30% width, light grey #F2F2F2):
- Search field at top (rounded pill, grey, magnifying-glass icon, placeholder "Search").
- Vertical nav list, each item an SF-Symbol-style icon left of its label:
  - ⊙ General
  - >_ Shell
  - ▷ Controls
  - ▣ Editor
  - **⏻ Agents** (selected — medium-grey rounded-rect highlight, bold label)
  - ⊙ Appearance
  - □ Recipes
  - ⚡ Key Bindings
  - 🔧 Advanced
- Typography: ~13–14pt system font, medium weight selected / regular others. Icons dark grey (#555). Selected highlight: rounded rect grey (~#DEDEDE).

**Right content area** (~70% width, white):
- No scroll chrome; content fills the pane.
- Three agent sections stacked vertically, ~24px gap between sections.

**CLAUDE CODE** section:
- Header: all-caps "CLAUDE CODE", muted grey (#999), ~11pt, uppercase tracking. No separator line.
- Card row (white, rounded border ~6px, #E5E5E5 border):
  - Left: bold **"Install Hooks"** (~14pt, #1A1A1A); below, grey description (#666, ~12pt): "Add SlopDesk hooks to ~/.claude/settings.json for real-time state updates".
  - Right: two side-by-side pill buttons (rounded, white fill, #D0D0D0 border, black label):
    - **"Installed"** — appears inactive/dimmed (already-installed, not clickable).
    - **"Uninstall"** — appears active/clickable.
  - Below: "Status" row — label "Status" left in grey, value "✓ Installed" right in **green** (~#34C759 macOS system green), ~13pt.

**CODEX** section:
- Same visual treatment as Claude Code. Header "CODEX".
- Card: bold **"Install Hooks"**, description "Add SlopDesk hooks to ~/.codex/hooks.json for real-time state updates".
- Two buttons "Installed" + "Uninstall". Status "✓ Installed" in green.

**OPENCODE** section:
- Header "OPENCODE".
- Card: bold **"Install Plugin"**, description "Add SlopDesk plugin to ~/.config/opencode/plugins/ for real-time state updates".
- One button **"Install"** (pill outline; not yet installed, so no Uninstall). Status "Not Installed" in neutral grey (#999), no checkmark.

**Typography summary**: SF Pro Text. Section headers ~11pt all-caps grey. Card titles ~14pt semibold. Descriptions ~12pt grey #666. Buttons ~13pt regular, rounded pill ~28pt height. Status labels ~13pt; installed=green, not installed=grey.

**Spacing**: ~16px card padding; ~8px title→description; ~12px between buttons; ~16px card→status row; ~24px between sections.

**Color palette**: White (#FFFFFF) main bg, light grey (#F2F2F2) sidebar, muted grey (#999/#666) headers/descriptions, near-black (#1A1A1A) titles/button labels, macOS green (#34C759) installed status, light border (#D0D0D0/#E5E5E5) buttons/cards.

---

## Screenshots

- `install-agent-integeration.png` (filename typo "integeration" preserved as-is from the original)

---

## Implementation Notes

### Direct implementation

1. **Settings panel / Agents tab**: SlopDesk already has `ConfigStore` (EnvConfig + EnvBridge + PreferencesStore). Add per-agent install cards as a new `SettingsSection.agents` view in the existing macOS Settings sheet.

2. **Claude Code hook installation**: Primary agent. Install writes `~/.claude/settings.json` hooks — pure local filesystem I/O on the **client Mac** (same machine as the terminal), which the macOS client can write directly.

3. **Badge While Processing / When Task Completes / When Awaiting Input**: Drive tab badges. `WorkspaceStore` + `PaneModel` already carry per-pane state. Inject a `ClaudeAgentState` enum (`.idle`, `.processing`, `.awaitingInput`, `.complete`) via `ClaudeStatus` / `ClaudePaneDetector` (see memory `slopdesk-night-supervision-roadmap`). Badge rendering maps onto the existing tab bar.

4. **Notify When Task Completes / When Awaiting Input**: Standard `UNUserNotificationCenter` calls from the client app.

5. **Resume Session on Recovery**: SlopDesk has `DetachedSessionStore` (`SLOPDESK_DETACH_ENABLED`) + detach/reattach. Maps to triggering a Claude Code resume (re-send session ID or re-cd + `claude --resume`) after a reconnect.

6. **Prevent Sleep While Processing**: `IOPMAssertion`. Trivial client-side.

7. **Uninstall**: Reverse the write — parse `~/.claude/settings.json`, remove SlopDesk's hook entries, leave the rest intact.

### Platform / architecture constraints

1. **"Status: ✓ Installed" verification**: Read back the config after writing — straightforward locally. But if Claude Code config lives on the **remote host** (user SSHes into a dev box), `~/.claude/settings.json` is on the remote machine and the client can't write it. Mitigation: scope agent integration to **local Claude Code sessions** (running on the client Mac); remote-host sessions need a host-side install helper (future). UI note: "Install applies to local Claude Code sessions."

2. **Codex and OpenCode support**: Initial scope is Claude Code only. Show only the Claude Code card, or show others greyed-out / "coming soon."

3. **"Branch / fork actions"**: Requires Claude Code's `--resume` / session-branching CLI flags and the History panel. Follow-on feature once basic hook integration works (History panel and Composer not yet built).

4. **Hook mechanism on iOS client**: iOS cannot write `~/.claude/settings.json` (sandboxed). If Claude Code runs on a remote macOS host, the iOS install button must send an install command over the existing SlopDesk control channel to `slopdesk-hostd`. Non-trivial; iOS-deferred.

5. **"Approve the trust prompt" (Codex)**: Codex-specific, not relevant to Claude Code scope.

6. **Agent Behavior toggles greyed out until install**: Observe whether `~/.claude/settings.json` contains SlopDesk's hooks and conditionally enable the toggles. Re-run the check each time the Settings panel opens (don't cache forever).

### Implementation order recommendation

1. Add `AgentIntegrationStore` reading/writing `~/.claude/settings.json` hooks.
2. Add Agents tab to Settings sheet with Claude Code card (Install / Uninstall / Status).
3. Wire `ClaudePaneDetector` state events into `AgentBehaviorSettings` toggles (badge + notify).
4. Implement tab badge rendering driven by agent state.
5. Implement `UNUserNotificationCenter` notifications.
6. Implement `IOPMAssertion` for Prevent Sleep.
7. Wire Resume Session on Recovery into `DetachedSessionStore` reconnect path.
