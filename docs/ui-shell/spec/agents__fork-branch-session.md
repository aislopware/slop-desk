# Fork / Branch Session

## Summary

Split a conversation in two. Forking copies a session's history up to a chosen point into a fresh session, so you can explore an alternative without disturbing the original thread.

It's each agent's own command — `/branch` in Claude Code, `/fork` in Codex and OpenCode. The key difference is that the fork lands on a new tab, or split view — both threads stay live, so you can chase different directions **in parallel**.

## Behaviors

- **Session fork/branch:** Invoking the agent's fork command copies the current session's conversation history up to the invocation point into a brand-new session. The original session is not disturbed.
- **Claude Code (agent-specific):** The command is `/branch`. This is the Claude-Code-specific variant; other agents use `/fork`.
- **OpenCode / Codex (agent-generic):** The command is `/fork`.
- **Fork destination — tab or split:** The forked session lands in a **new tab** or in a **split view** pane, depending on the fork sub-command chosen. Both destinations keep both threads simultaneously live.
- **Parallel exploration:** After forking, both the original and the forked session remain active concurrently. The user can interact with either independently. This enables divergent directions to be explored in parallel without serialising work.
- **Command palette integration:** The fork action is surfaced via the command palette (triggered by `ctrl+p` or equivalent). Typing "fork" in the palette shows a list of fork sub-commands as an inline dropdown/autocomplete list:
  - **Open in Fork** — opens the fork in the default fork view
  - **OpenCode: Fork in Split Right** — places the forked session in a right split pane (highlighted/selected entry in the screenshot)
  - **OpenCode: Fork in Split Left** — places the forked session in a left split pane
  - **OpenCode: Fork in Split Down** — places the forked session in a bottom split pane
  - **OpenCode: Fork in Split Up** — places the forked session in a top split pane
  - **OpenCode: Fork in New Tab** — opens the fork in a new tab
  - **OpenCode: Fork in New Window** — opens the fork in a new window
  - **OpenCode: Fork in...** — ellipsis entry, likely a more/picker variant
- **Agent scope note:** The fork/branch command is initiated from inside the agent's own chat interface (Claude Code's `/branch` slash-command). The app detects the fork event and routes the new session to the chosen split/tab layout.
- **Session context shown in sidebar:** A details panel on the right side of the window shows the current session's context: token count (e.g. "25,847 tokens"), percentage used, and cost spent (e.g. "$0.12 spent"), plus LSP status.
- **Status bar context:** The bottom status bar shows the current file context (`fork-branch-session.md 25.8K (13%)`), cost (`$0.12`), the palette shortcut hint (`ctrl+p commands`), working directory (e.g. `~/Workspace/<project>:<branch>`), and agent version (`OpenCode 1.16.2`).

## Keybindings

| Action | Keys |
|---|---|
| Open command palette (to initiate fork) | `ctrl+p` |

*Note: No dedicated fork keybinding is defined on this page. Fork is invoked via the agent's own slash command (`/branch` in Claude Code, `/fork` in OpenCode/Codex) or via the command palette.*

## Config keys

*No config keys are defined on this page. Fork behavior (tab vs split destination) is chosen at invocation time via the command palette sub-command.*

## Visual spec

### fork-right.png

**Overall layout:** A macOS window in light mode with a native traffic-light titlebar (red/yellow/green dots, top-left). The window title reads "OC | Data sync feature consideration". The window has no visible outer border radius at the pane level (flat/flush panes consistent with Monokai Pro flat style elsewhere in the codebase).

**Left pane — terminal / agent chat (approximately 65% of window width):**
- Background: off-white / very light gray (~#F5F5F5 or similar light neutral)
- A markdown-rendered table near the top with columns: "Maint cost", "Low", "Medium", "None", "Very High", "High"; rows: "Offline", "Real-time" with "Yes"/"No"/"Varies" cell values. Table has subtle column dividers, no heavy borders.
- Below the table: prose text with a bold blue hyperlink-style inline link ("data-sync.md") in a "Recommendation" section. The heading "Recommendation" is rendered in blue/link color, bold.
- Numbered list items (1, 2, 3) with truncated prose, indicating a Claude Code agent output that is partially visible.
- At the very bottom of the left pane: a status/input line showing "Build · GLM-5.1 · 6m 48s" in a faint/muted style, indicating the last build command and elapsed time.

**Command palette overlay (center of left pane):**
- A floating rounded-rect overlay panel appears in the center-left area of the terminal pane.
- Search field at the top: contains the text "fork" in gray, prefixed by a magnifier/search icon (🔍). The search field has a subtle rounded border.
- Below the search field: a vertical list of autocomplete/action items. Each item is one line of text.
  - "Open in Fork" — plain white/unselected row
  - "OpenCode: Fork in Split Right" — **selected/highlighted** row, shown with a blue accent background (~#0066CC or similar macOS selection blue). White text on blue.
  - "OpenCode: Fork in Split Left" — unselected, dark text on white
  - "OpenCode: Fork in Split Down" — unselected
  - "OpenCode: Fork in Split Up" — unselected
  - "OpenCode: Fork in New Tab" — unselected
  - "OpenCode: Fork in New Window" — unselected
  - "OpenCode: Fork in..." — unselected, ellipsis variant
- The palette has a subtle drop shadow and rounded corners (~8px radius). The list items have ~12–14px vertical padding, compact density.

**Right pane — session details sidebar (approximately 35% of window width):**
- Background: same light off-white as the left pane or a slightly distinct panel background.
- Title at top in dark bold text: "Data sync feature consideration" (the session/task name).
- "Context" section label in muted gray, below which:
  - "25,847 tokens" — dark text, numeric
  - "13% used" — muted gray secondary text
  - "$0.12 spent" — muted gray secondary text
- "LSP" section label in muted gray, below which:
  - "LSPs are disabled" — muted gray body text
- No borders between sidebar sections; spacing is tight (~8–12px between items).

**Bottom status bar (full window width):**
- Dark or muted background strip.
- Left side: "Build · GLM-5.1 OpenCode Go" (agent/model indicator, muted)
- Center-left: "fork-branch-session.md 25.8K (13%)" — current file and size
- Center-right: "$0.12" — session cost
- Right side: "ctrl+p commands" (palette hint), an example `~/Workspace/<project>:<branch>` (cwd+branch), "· OpenCode 1.16.2" (agent version)
- Typography: small (~11–12px), monospace or system-ui, muted (#888 or similar).

**Typography & color summary:**
- Body text: system sans-serif, ~13–14px, near-black (~#1a1a1a)
- Muted/secondary text: ~#888 or #999
- Accent/selection: macOS blue ~#0066CC
- Link/heading accent: blue (~#0070C9 or similar)
- Background: ~#F7F7F7 light neutral
- The overall density is compact but not cramped; consistent with macOS native design standards.

## Screenshots

- `fork-right.png` — Shows the command palette open with "fork" typed, highlighting "OpenCode: Fork in Split Right" as the selected action. The right panel displays session context (token count, cost, LSP status).

## SlopDesk mapping notes

### Agent-generic vs Claude-Code-specific

| Behavior | Agent scope |
|---|---|
| `/branch` command | **Claude Code-specific** — this is the only agent we support initially |
| `/fork` command | Agent-generic (Codex, OpenCode) — not our initial target |
| Fork detected by terminal, new session routed to split/tab | Agent-generic — the app detects the agent's own command output |

### Mapping to slopdesk remote architecture

1. **Fork command initiation:** The `/branch` command is typed into the Claude Code CLI running on the **remote macOS host**. SlopDesk's terminal (PTY path, TCP transport) carries the user's keystrokes to the host and the agent output back. No host-side special handling is needed for the command itself.

2. **Fork detection:** The design calls for detecting the fork event from the agent's output (likely via OSC-133 shell integration marks or a proprietary VT sequence emitted when a fork/branch completes and a new session ID is advertised). In slopdesk, this detection must happen on the **client** by parsing PTY output through the `TerminalSurface` seam. This is a non-trivial mapping: we need to define what signal the client watches for (e.g. a specific OSC sequence or a known output pattern from `claude --resume <new-session-id>`).

3. **New session routing (tab vs split):** When a fork is detected, a new tab or split pane opens for the forked session. In slopdesk, this maps to adding a new `Pane` to the `WorkspaceStore` with `PaneKind.terminal` pointed at a new PTY/SSH session launched with `claude --resume <forked-session-id>` (or equivalent). The `WorkspaceStore.reconcile()` machinery already supports multi-pane layouts.

4. **Command palette fork sub-commands:** The "Fork in Split Right/Left/Up/Down/Tab/Window" palette entries are **pure client UI** — they determine how the new pane is positioned. SlopDesk's existing pane-split and tab machinery can implement these directly. The chosen split direction is orthogonal to the remote host.

5. **Session context sidebar (tokens, cost, LSP):** This data is surfaced from the agent's own output or API. In slopdesk, this would require parsing Claude Code's structured output (e.g. JSON progress events, OSC-9;4 progress sequences, or a sidecar protocol). This is **not a 1:1 map** — slopdesk has no existing token/cost parsing; this would need to be added to `BlockOutputView`/`ClaudeStatus` machinery.

6. **Status bar (cwd, branch, agent version):** The cwd (e.g. `~/Workspace/<project>:<branch>`) displayed in the status bar comes from OSC-7 (Current Working Directory) emitted by the remote shell. SlopDesk already supports OSC-7 routing. The git branch suffix and agent version string would need to be parsed from the agent's prompt or output. Flagged as **partial map** — cwd is handled, branch+version require additional parsing.

7. **"Both threads stay live" (parallel sessions):** SlopDesk already supports multiple live panes/sessions concurrently (`WorkspaceStore`, multiple PTY channels over the mux). This maps cleanly; no architectural gap.

8. **iOS client:** Fork initiation via `/branch` works identically on iOS since it's just text typed into the terminal. The split-view fork destination may be constrained on iPhone (no multi-pane) — on iPhone, fall back to "Fork in New Tab". iPad supports split view natively.

9. **Cannot map 1:1:**
   - Token/cost/LSP sidebar data: requires structured agent output parsing not yet in slopdesk.
   - Automatic fork detection from PTY output: requires defining and implementing a detection protocol (OSC or pattern match).
   - "OpenCode: Fork in New Window" — slopdesk on iOS has no multi-window concept; would need to be suppressed or remapped.
