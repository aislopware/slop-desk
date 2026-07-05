# Fork / Branch Session

## Summary

Fork copies a session's history up to a chosen point into a fresh session, letting you explore an alternative without disturbing the original. Each agent has its own command — `/branch` in Claude Code, `/fork` in Codex and OpenCode. The fork lands on a new tab or split view; both threads stay live, so directions can be chased **in parallel**.

## Behaviors

- **Session fork/branch:** The agent's fork command copies the current session's history up to the invocation point into a new session; the original is untouched.
- **Command by agent:** `/branch` in Claude Code (Claude-Code-specific); `/fork` in OpenCode / Codex (agent-generic).
- **Fork destination — tab or split:** The forked session lands in a **new tab** or a **split view** pane per the fork sub-command chosen. Both keep both threads live.
- **Parallel exploration:** Original and fork stay active concurrently; the user interacts with either independently, exploring divergent directions without serialising work.
- **Command palette integration:** Fork is surfaced via the palette (`ctrl+p`). Typing "fork" shows fork sub-commands as an inline autocomplete list:
  - **Open in Fork** — default fork view
  - **OpenCode: Fork in Split Right** — right split pane (selected in screenshot)
  - **OpenCode: Fork in Split Left** — left split pane
  - **OpenCode: Fork in Split Down** — bottom split pane
  - **OpenCode: Fork in Split Up** — top split pane
  - **OpenCode: Fork in New Tab** — new tab
  - **OpenCode: Fork in New Window** — new window
  - **OpenCode: Fork in...** — ellipsis / picker variant
- **Agent scope:** Initiated from inside the agent's own chat (`/branch`). The app detects the fork event and routes the new session to the chosen split/tab layout.
- **Session context sidebar:** A right-side panel shows the session's context: token count (e.g. "25,847 tokens"), percentage used, cost (e.g. "$0.12 spent"), and LSP status.
- **Status bar context:** Shows current file context (`fork-branch-session.md 25.8K (13%)`), cost (`$0.12`), palette hint (`ctrl+p commands`), working directory (e.g. `~/Workspace/<project>:<branch>`), and agent version (`OpenCode 1.16.2`).

## Keybindings

| Action | Keys |
|---|---|
| Open command palette (to initiate fork) | `ctrl+p` |

*No dedicated fork keybinding on this page. Fork is invoked via the agent's slash command (`/branch`, `/fork`) or the command palette.*

## Config keys

*None on this page. Fork destination (tab vs split) is chosen at invocation via the palette sub-command.*

## Visual spec

### fork-right.png

**Overall layout:** macOS window, light mode, native traffic-light titlebar (top-left). Title: "OC | Data sync feature consideration". Flat/flush panes, no pane-level border radius (Monokai Pro flat style).

**Left pane — terminal / agent chat (~65% width):**
- Background: off-white / very light gray (~#F5F5F5).
- Markdown table near top: columns "Maint cost", "Low", "Medium", "None", "Very High", "High"; rows "Offline", "Real-time" with "Yes"/"No"/"Varies" cells. Subtle column dividers, no heavy borders.
- Below table: prose with a bold blue inline link ("data-sync.md") in a "Recommendation" section; heading "Recommendation" rendered blue/link, bold.
- Numbered list items (1, 2, 3) with truncated prose — partially visible Claude Code output.
- Bottom of left pane: status/input line "Build · GLM-5.1 · 6m 48s" (faint), last build command + elapsed time.

**Command palette overlay (center-left of left pane):**
- Floating rounded-rect panel.
- Search field top: text "fork" in gray, magnifier icon (🔍), subtle rounded border.
- Vertical list of one-line action items:
  - "Open in Fork" — unselected
  - "OpenCode: Fork in Split Right" — **selected/highlighted**, blue accent background (~#0066CC), white text
  - "OpenCode: Fork in Split Left" — unselected, dark on white
  - "OpenCode: Fork in Split Down" — unselected
  - "OpenCode: Fork in Split Up" — unselected
  - "OpenCode: Fork in New Tab" — unselected
  - "OpenCode: Fork in New Window" — unselected
  - "OpenCode: Fork in..." — unselected, ellipsis variant
- Subtle drop shadow, rounded corners (~8px), list items ~12–14px vertical padding, compact.

**Right pane — session details sidebar (~35% width):**
- Background: same light off-white or slightly distinct panel.
- Title (dark bold): "Data sync feature consideration" (session/task name).
- "Context" label (muted gray):
  - "25,847 tokens" — dark numeric
  - "13% used" — muted secondary
  - "$0.12 spent" — muted secondary
- "LSP" label (muted gray):
  - "LSPs are disabled" — muted body
- No section borders; tight spacing (~8–12px).

**Bottom status bar (full width):**
- Dark/muted background strip.
- Left: "Build · GLM-5.1 OpenCode Go" (agent/model, muted)
- Center-left: "fork-branch-session.md 25.8K (13%)" — file and size
- Center-right: "$0.12" — session cost
- Right: "ctrl+p commands" (palette hint), `~/Workspace/<project>:<branch>` (cwd+branch), "· OpenCode 1.16.2" (version)
- Typography: small (~11–12px), monospace or system-ui, muted (#888).

**Typography & color summary:**
- Body text: system sans-serif, ~13–14px, near-black (~#1a1a1a)
- Muted/secondary: ~#888 or #999
- Accent/selection: macOS blue ~#0066CC
- Link/heading accent: blue (~#0070C9)
- Background: ~#F7F7F7 light neutral
- Density: compact but not cramped; macOS native standards.

## Screenshots

- `fork-right.png` — Command palette open with "fork" typed, "OpenCode: Fork in Split Right" selected; right panel shows session context (token count, cost, LSP status).

## SlopDesk mapping notes

### Agent-generic vs Claude-Code-specific

| Behavior | Agent scope |
|---|---|
| `/branch` command | **Claude Code-specific** — the only agent we support initially |
| `/fork` command | Agent-generic (Codex, OpenCode) — not our initial target |
| Fork detected by terminal, new session routed to split/tab | Agent-generic — app detects the agent's own command output |

### Mapping to slopdesk remote architecture

1. **Fork command initiation:** `/branch` is typed into the Claude Code CLI on the **remote macOS host**. SlopDesk's terminal (PTY path, TCP transport) carries keystrokes to the host and agent output back. No host-side special handling needed for the command itself.

2. **Fork detection:** Detect the fork event from agent output (likely OSC-133 shell-integration marks or a proprietary VT sequence emitted when a fork completes and a new session ID is advertised). In slopdesk this detection happens on the **client** by parsing PTY output through the `TerminalSurface` seam. Non-trivial: must define the watched signal (e.g. a specific OSC sequence or a known `claude --resume <new-session-id>` output pattern).

3. **New session routing (tab vs split):** On fork detection, a new tab/split pane opens for the forked session — maps to adding a `Pane` to `WorkspaceStore` with `PaneKind.terminal` pointed at a new PTY/SSH session launched via `claude --resume <forked-session-id>` (or equivalent). `WorkspaceStore.reconcile()` already supports multi-pane layouts.

4. **Command palette fork sub-commands:** "Fork in Split Right/Left/Up/Down/Tab/Window" are **pure client UI** — they position the new pane. SlopDesk's existing pane-split/tab machinery implements these directly; split direction is orthogonal to the remote host.

5. **Session context sidebar (tokens, cost, LSP):** Surfaced from the agent's own output or API. In slopdesk requires parsing Claude Code structured output (JSON progress events, OSC-9;4 progress sequences, or a sidecar protocol). **Not a 1:1 map** — no existing token/cost parsing; must be added to `BlockOutputView`/`ClaudeStatus`.

6. **Status bar (cwd, branch, agent version):** cwd (`~/Workspace/<project>:<branch>`) comes from OSC-7 (Current Working Directory) emitted by the remote shell; slopdesk already routes OSC-7. Git branch suffix and agent version must be parsed from the agent's prompt/output. **Partial map** — cwd handled, branch+version require added parsing.

7. **"Both threads stay live" (parallel sessions):** SlopDesk already supports multiple live panes/sessions concurrently (`WorkspaceStore`, multiple PTY channels over the mux). Maps cleanly; no architectural gap.

8. **iOS client:** `/branch` works identically on iOS — just text typed into the terminal. Split-view fork may be constrained on iPhone (no multi-pane) — fall back to "Fork in New Tab"; iPad supports split view natively.

9. **Cannot map 1:1:**
   - Token/cost/LSP sidebar data: requires structured agent-output parsing not yet in slopdesk.
   - Automatic fork detection from PTY output: requires defining/implementing a detection protocol (OSC or pattern match).
   - "OpenCode: Fork in New Window" — slopdesk on iOS has no multi-window concept; suppress or remap.
