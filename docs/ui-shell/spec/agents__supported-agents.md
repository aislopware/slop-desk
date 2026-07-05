# Supported Code Agents

## Summary

SlopDesk integrates with three coding-agent CLIs: Claude Code (`claude`), Codex (`codex`), and OpenCode (`opencode`). Users run the agent as in any terminal; SlopDesk plugs in via each agent's own hook/plugin mechanism to surface tab badges, notifications, session history, resume, and fork. The in-app experience is identical across all three. Install is one-click: the first time it's needed, SlopDesk asks permission and installs the hook/plugin — touching no other settings.

Any other coding-agent CLI runs fine as a plain terminal process, minus the agent-aware features. Third-party agents can adopt the Terminal Resume Protocol (OSC 88) for resume support without a bespoke integration.

## Behaviors

### Generic (all three supported agents)

- **Tab badges** — a live badge reflects the current agent turn state (processing, idle, awaiting input), reported by the installed hook/plugin.
- **Notifications** — desktop notifications on relevant events (e.g. turn complete, awaiting input).
- **History** — completed sessions are captured, searchable, and reloadable.
- **Resume** — reopen a past session via the agent's resume flag with the session id.
- **Fork** — branch a past session into a new independent session.
- **One-click install** — first use prompts, then installs the hook/plugin into the agent's config dir; touches no other settings.
- **One-click uninstall/re-enable** — from within SlopDesk.

### Claude Code (agent-specific)

> **Claude-Code-specific** — applies only to `claude` (Anthropic's Claude Code CLI).

- Adds hook entries to `~/.claude/settings.json` reporting turn state: `processing`, `idle`, `awaiting input`.
- Resume: `claude --resume <id>`.
- Fork: `claude --resume <id> --fork-session`.
- Transcripts are JSONL under `~/.claude/projects/…`; History searches/reloads from there.

### Codex (agent-specific)

> **Agent-generic pattern** — hooks model; details below are Codex-specific.

- Installs hooks into `~/.codex/hooks.json`.
- Codex only runs hooks when the `hooks` feature flag is enabled in `~/.codex/config.toml`; SlopDesk sets `hooks = true` on install.
- If `hooks` is later disabled, SlopDesk offers one-click re-enable (user must then restart Codex in that tab).
- Resume: `codex resume <id>`. Fork: `codex fork <id>`.

### OpenCode (agent-specific)

> **Agent-generic pattern** — plugin model (not hooks); details below are OpenCode-specific.

- Installs a small plugin into `~/.config/opencode/plugins` (not a hooks file).
- Resume: `opencode --session <id>`. Fork: `opencode --fork --session <id>`.
- **Quirk**: OpenCode doesn't announce a session switched to via `/sessions` inside the agent. SlopDesk picks it up only once the user sends a message; if a freshly-switched tab appears unlinked, typing connects it.

### Other/unsupported agents

- Any other CLI runs as a plain terminal program — no tab badges, notifications, history, resume, or fork.
- Agents implementing the Terminal Resume Protocol (OSC 88) get resume support automatically, no bespoke integration.
- Other agent-aware features are "not implemented yet"; planned over time, likely via extensions or similar.

## Keybindings

No keybindings on this page. Agent-specific keybindings (e.g. Resume/Fork) live on the Fork / Branch Session and History pages.

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

SlopDesk writes into the agent's own config; it exposes no config keys of its own here.

| Key | Default | Effect |
|-----|---------|--------|
| `~/.claude/settings.json` hooks entries | Absent until SlopDesk installs | Reports Claude Code turn state (processing / idle / awaiting input) to SlopDesk |
| `~/.codex/hooks.json` hooks entries | Absent until SlopDesk installs | Reports Codex turn state to SlopDesk |
| `~/.codex/config.toml` → `hooks = true` | `false` (Codex default) | Must be `true` for Codex to run hooks; SlopDesk enables on install |
| `~/.config/opencode/plugins` plugin | Absent until SlopDesk installs | Wires OpenCode session state and events to SlopDesk |

## Visual spec

### No screenshots on this page

A purely textual reference page — no inline screenshots. The only image asset is a reference app-icon design at `screenshots/otty-icon.png`.

#### Reference app icon (`otty-icon.png`)

Rounded-square macOS-style app icon on a light off-white/gray background (~#f0efed). The face is a large near-black dark-charcoal circle (~#3a3a3a). On it, in muted off-white (~#d8d5ce), three terminal-prompt glyphs form a stylized emoticon face:
- Top-left: `>` (prompt chevron) — an "eye"
- Top-right: `*` (asterisk) — the other "eye"
- Bottom-center: `_` (cursor/prompt) — the "mouth"

Reads as "> _ *" — a terminal prompt (`>_`) beside an asterisk, doubling as a winking face. Soft light-gray rounded square with subtle shadow, macOS Big Sur+ style. No text label.

## Screenshots

- `otty-icon.png` — reference app-icon design; no page-specific screenshots exist.

## Implementation notes

Documents which agents SlopDesk supports and how it hooks into each. Claude Code support ships first.

### Direct implementation

- **Tab badge / state indicator** — reuses the existing pane/tab model (`WorkspaceStore`, `PaneKind`). The three states (`processing`, `idle`, `awaiting_input`) map onto existing `ClaudeStatus`-style detection (`ClaudeStatus`, `ClaudePaneDetector`, `AgentControlListener`). Render the badge in the pane titlebar or tab UI.
- **History search** — Claude Code transcripts are JSONL at `~/.claude/projects/…` on the HOST (macOS). Terminal sessions run on the host via `slopdesk-hostd`, so hostd has filesystem access; the client (macOS/iOS) requests listing/content over the existing control channel.
- **Fork and Resume** — CLI flags (`--resume <id>`, `--fork-session`) sent as a command to the PTY. Spawn a new pane with `claude --resume <id> [--fork-session]` over the standard PTY path — no new wire protocol.
- **Notifications** — reuse the existing notifications path (OSC 9 / OSC 99 / notification terminal feature). Hook-reported state changes trigger client-side local notifications.

### Platform / architecture constraints

- **Hook installation into `~/.claude/settings.json`** — Claude Code runs on the REMOTE host, so hook entries must be installed into the host's `~/.claude/settings.json`, not the client's. hostd (or a host-side setup step) performs this; a purely local one-click install isn't possible. Likely handled by slopdesk-ctl or a setup flow.
- **JSONL transcript path** — transcripts are at `~/.claude/projects/…` on the HOST; the client can't reach them directly and needs a host-side file-listing/reading service (control-channel command or inspector path). Not trivially available to the iOS client.
- **Session ID discovery** — session IDs come from local transcript files or hook payloads. In the remote architecture, hostd must relay session IDs (from hook payloads on the agent control socket `SLOPDESK_AGENT_CONTROL=1`) to the client.
- **OSC 88 (Terminal Resume Protocol)** — any agent emitting OSC 88 should get resume support without a bespoke integration. The terminal path (libghostty behind the TerminalSurface seam) must pass OSC 88 through; whether libghostty parses it or SlopDesk must intercept it is NEEDS INVESTIGATION.
- **iOS client** — no local access to `~/.claude/`. All agent state (session IDs, turn state, transcript listing) must be proxied from the host via the control channel. The iOS pane can show badges and trigger resume/fork via PTY input, but the data source is always remote.
- **OpenCode `/sessions` switch quirk** — not in initial Claude Code scope, but note: the "type something to connect" workaround is a pure client-side UX concern (show a hint label when the session appears unlinked).
- **Codex `hooks = true` config.toml mutation** — not in initial scope; mutating remote agent config requires host-side write access and a clear user prompt.

### Scope for initial implementation

Focus: **Claude Code only**. Minimum viable set:
1. Host-side hook in `~/.claude/settings.json` pushing turn-state events to `slopdesk-hostd` via `AgentControlListener`/`SLOPDESK_AGENT_CONTROL`.
2. Turn-state badge in the pane tab (processing / idle / awaiting-input), rendered client-side from relayed events.
3. Resume: client triggers `claude --resume <id>` in a new pane via PTY command string.
4. Fork: client triggers `claude --resume <id> --fork-session` in a new pane.
5. History: hostd lists `~/.claude/projects/` JSONL sessions; client requests and displays them.
