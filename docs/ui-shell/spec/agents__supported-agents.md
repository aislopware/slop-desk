# Supported Code Agents

## Summary

SlopDesk integrates with three coding-agent CLIs: Claude Code (`claude`), Codex (`codex`), and OpenCode (`opencode`). The user runs these agents exactly as they would in any terminal; SlopDesk plugs into each via that agent's own hook/plugin mechanism and surfaces tab badges, notifications, session history, resume, and fork. The in-app experience is identical across all three. Integration is one-click: the first time SlopDesk needs the integration it asks permission and installs the hook or plugin — it does not touch other settings.

Any other coding-agent CLI runs fine as a plain terminal process in an SlopDesk tab; it just does not receive agent-aware features. Third-party agents can adopt the Terminal Resume Protocol (OSC 88) to gain resume support without a bespoke integration.

## Behaviors

### Generic (all three supported agents)

- **Tab badges** — the tab shows a live state badge reflecting the current agent turn state (processing, idle, awaiting input). This state is reported by the hook/plugin installed into the agent's own config.
- **Notifications** — desktop notifications fire on relevant agent events (e.g. turn complete, awaiting input).
- **History** — completed sessions are captured and searchable; SlopDesk can reload them.
- **Resume** — a past session can be reopened from within SlopDesk by invoking the agent's resume flag with the session id.
- **Fork** — a past session can be branched into a new independent session.
- **One-click install** — the first time SlopDesk needs the integration it prompts the user and installs the hook or plugin into the agent's own config directory. It does not touch any other settings.
- **One-click uninstall/re-enable** — the integration can be removed or re-enabled from within SlopDesk.

### Claude Code (agent-specific)

> **Claude-Code-specific** — all details below apply only to `claude` (Anthropic's Claude Code CLI).

- SlopDesk adds hook entries to `~/.claude/settings.json` that report each turn's state: `processing`, `idle`, `awaiting input`.
- Resume reopens a past conversation with `claude --resume <id>`.
- Fork branches a session with `claude --resume <id> --fork-session`.
- Transcripts are stored as JSONL files under `~/.claude/projects/…`; the History feature searches and reloads from this directory.

### Codex (agent-specific)

> **Agent-generic pattern** — hooks model; details below are Codex-specific.

- SlopDesk installs hooks into `~/.codex/hooks.json`.
- Codex only runs hooks when the `hooks` feature flag is enabled in `~/.codex/config.toml`. SlopDesk sets `hooks = true` automatically when it installs the hooks.
- If the `hooks` feature is ever disabled, SlopDesk offers a one-click re-enable (user must then restart Codex in that tab).
- Resume uses `codex resume <id>`.
- Fork uses `codex fork <id>`.

### OpenCode (agent-specific)

> **Agent-generic pattern** — plugin model (not hooks); details below are OpenCode-specific.

- SlopDesk installs a small plugin into `~/.config/opencode/plugins` (not a hooks file).
- Resume uses `opencode --session <id>`.
- Fork uses `opencode --fork --session <id>`.
- **Quirk**: OpenCode does not announce a session when the user switches to it via `/sessions` inside the agent. SlopDesk only picks up the session once the user sends a message in that session. If a freshly-switched tab appears unlinked, typing something causes it to connect.

### Other/unsupported agents

- Any other coding-agent CLI runs as a plain terminal program in an SlopDesk tab — no tab badges, notifications, history, resume, or fork.
- Agents that implement the Terminal Resume Protocol (OSC 88) automatically receive resume support in SlopDesk without a bespoke integration.
- All other agent-aware features are "not implemented yet"; SlopDesk plans to open them over time, likely through extensions or a similar mechanism.

## Keybindings

No keybindings are documented on this page. Agent-specific keybindings (e.g. for triggering Resume or Fork from the UI) are documented on the Fork / Branch Session and History pages.

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

SlopDesk writes into the agent's own config; it does not expose its own config keys for this feature on this page.

| Key | Default | Effect |
|-----|---------|--------|
| `~/.claude/settings.json` hooks entries | Absent until SlopDesk installs | Reports Claude Code turn state (processing / idle / awaiting input) to SlopDesk |
| `~/.codex/hooks.json` hooks entries | Absent until SlopDesk installs | Reports Codex turn state to SlopDesk |
| `~/.codex/config.toml` → `hooks = true` | `false` (Codex default) | Must be `true` for Codex to run hooks; SlopDesk enables this on install |
| `~/.config/opencode/plugins` plugin | Absent until SlopDesk installs | Wires OpenCode session state and events to SlopDesk |

## Visual spec

### No screenshots on this page

The "Supported Code Agents" page is a purely textual reference page. It contains no inline screenshots. The only image asset present is a reference app-icon design kept under `screenshots/otty-icon.png`.

#### Reference app icon (`otty-icon.png`)

Rounded-square macOS-style app icon with a light off-white/gray background (#f0efed approximately). The icon face is a large near-black dark-charcoal circle (approximately #3a3a3a). On the circle, rendered in a muted off-white (#d8d5ce approximately), are three terminal-prompt glyphs arranged to resemble a stylized emoticon face:
- Top-left: `>` (greater-than, prompt chevron) — the "eye"
- Top-right: `*` (asterisk) — the other "eye"
- Bottom-center: `_` (underscore, cursor/prompt) — the "mouth"

The overall reading is "> _ *" laid out as a terminal prompt (`>_`) beside an asterisk, doubling as a winking face. The icon sits on a soft light-gray rounded square with subtle shadow, consistent with macOS Big Sur+ icon style. No text label on the icon itself.

## Screenshots

- `otty-icon.png` — reference app-icon design kept for internal reference; no page-specific screenshots exist for this page.

## Implementation notes

This page documents which agents SlopDesk supports and how it hooks into each. SlopDesk is implementing Claude Code support initially (as specified). Implementation considerations:

### Direct implementation

- **Tab badge / state indicator** — slopdesk already has a pane/tab model with `WorkspaceStore` and `PaneKind`. The three turn states (`processing`, `idle`, `awaiting_input`) from Claude Code hooks map directly onto existing `ClaudeStatus`-style detection already present in the codebase (`ClaudeStatus`, `ClaudePaneDetector`, `AgentControlListener` — from memory notes). The badge can be rendered in the pane titlebar or tab UI component.
- **History search** — Claude Code transcripts are JSONL at `~/.claude/projects/…` on the HOST machine (macOS). Since slopdesk's terminal sessions run on the macOS host via `slopdesk-hostd`, the hostd process has access to `~/.claude/projects/` on the host filesystem. The client (macOS or iOS) can request transcript listing/content via the existing control channel.
- **Fork and Resume** — these are CLI flags (`--resume <id>`, `--fork-session`) sent as a command to the PTY. The slopdesk pane/tab model can spawn a new pane with the appropriate `claude --resume <id> [--fork-session]` command. This works over the standard PTY path with no new wire protocol needed.
- **Notifications** — slopdesk already has a notifications path (OSC 9 / OSC 99 / privilege/notification terminal feature). Claude Code hook-reported state changes can trigger local notifications on the client side.

### Platform / architecture constraints

- **Hook installation into `~/.claude/settings.json`** — in slopdesk, the Claude Code process runs on the REMOTE macOS HOST, not on the client. Therefore the hook entries must be installed into the host's `~/.claude/settings.json`, not the client machine's. The slopdesk hostd (or a host-side setup step) must perform this installation. A purely local one-click install (writing to a config file on the same machine as the UI) isn't possible here; this is a host-side setup step, likely handled by the slopdesk-ctl or a setup flow.
- **JSONL transcript path** — transcripts are at `~/.claude/projects/…` on the HOST. The client cannot access this path directly; it requires a host-side file-listing/reading service. This could be implemented as a control-channel command or via the inspector path, but it is not trivially available to the iOS client.
- **Session ID discovery** — session IDs need to be read from local transcript files or from hook payloads. In slopdesk's remote architecture, the hostd must relay session IDs (from hook payloads received over the agent control socket `SLOPDESK_AGENT_CONTROL=1`) to the client so it can display and act on them.
- **OSC 88 (Terminal Resume Protocol)** — any agent emitting OSC 88 should get resume support without a bespoke integration. SlopDesk's terminal path (libghostty behind TerminalSurface seam) must pass OSC 88 through; whether libghostty parses it or it needs to be intercepted at the slopdesk layer needs verification. Mark as NEEDS INVESTIGATION.
- **iOS client** — on iOS, there is no local filesystem access to `~/.claude/`. All agent state (session IDs, turn state, transcript listing) must be proxied from the host via the control channel. The iOS pane UI can show badges and trigger resume/fork commands via PTY input, but the data source is always remote.
- **OpenCode `/sessions` switch quirk** — not relevant for our initial Claude Code scope, but note for future: the "type something to connect" workaround is a pure client-side UX concern (show a hint label in the pane when the session appears unlinked).
- **Codex `hooks = true` config.toml mutation** — not in initial scope; note that mutating remote agent config files requires host-side write access and a clear user prompt.

### Scope for initial implementation

Focus: **Claude Code only**. The minimum viable feature set is:
1. Host-side hook installed in `~/.claude/settings.json` that pushes turn-state events to `slopdesk-hostd` via the existing `AgentControlListener`/`SLOPDESK_AGENT_CONTROL` socket.
2. Turn-state badge in the pane tab (processing / idle / awaiting-input), rendered on the client from relayed events.
3. Resume: client can trigger `claude --resume <id>` in a new pane by sending the command string over the PTY.
4. Fork: client can trigger `claude --resume <id> --fork-session` in a new pane.
5. History: hostd exposes a listing of `~/.claude/projects/` JSONL sessions; client can request and display them.
