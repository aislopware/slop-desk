# Agent History

## Summary

Every agent conversation is captured and searchable: resume a thread days later or fork a new task off old context. SlopDesk recognizes three agents by session-file path and auto-opens matching files as rendered transcripts instead of raw JSONL.

## Behaviors

- **Auto-detection by path**: Session files under a known agent dir open as a rendered transcript; any `.jsonl` outside those paths opens as plain text (or syntax-highlighted JSONL).
  - Claude Code: `~/.claude/projects/<project>/*.jsonl`
  - Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
  - OpenCode: `~/.local/share/opencode/storage/session/<project>/*.json`
- **Transcript rendering**: Raw JSONL/JSON logs render as a readable conversation (speaker turns, code blocks, tool-call expansions), not raw JSON.
- **Open from Command Palette**.
- **Open from titlebar dropdown menu**: right-click tab → "View Session History" (primary discovery path in the screenshots).
- **Text selection + context menu**: select transcript text → "Copy" or "Send to Chat" (inserts into the active agent session's composer).
- **Resume button in toolbar**:
  - Session **still running** (live tab exists): jumps to that live tab.
  - Session **ended**: spawns a fresh agent tab via `--resume <session-id>`, continuing the conversation.
  - Resumed session keeps the original provider, model, and system prompt — only the conversation continues.
- **View toggle (raw ↔ transcript)**: right-click → View as → `<Agent> History` ⇄ `JSONL (Syntax Highlight)`.
- **Open Quickly — Agents tab**: the quick-open/fuzzy finder has an "Agents" tab searching sessions across all supported agents at once.
  - Grouped by agent (e.g. "CODEX SESSIONS", "CLAUDE CODE SESSIONS").
  - Each result shows session title/first message, working-dir path, relative timestamp (e.g. "43s ago", "3 min ago"), and an "Agent" badge on the right.
  - Typing filters fuzzy-matched across all agents.
  - Footer shortcuts: "Quick Select ⌘", "Resume ↩", "Actions ⌘K".
- **Agent-generic vs Claude-Code-specific**:
  - Agent-generic: transcript rendering, resume, view-toggle, Open Quickly Agents tab, Send to Chat, Copy.
  - Claude-Code-specific: session path `~/.claude/projects/<project>/*.jsonl`; `--resume` flag semantics are Claude Code's CLI.

## Keybindings

| Action | Keys |
|--------|------|
| Quick Select in Open Quickly panel | ⌘ (Cmd) |
| Resume session from Open Quickly panel | ↩ (Return) |
| Show Actions for selected item in Open Quickly panel | ⌘K |

> No keyboard shortcuts documented beyond the Open Quickly footer hints. The Command Palette (standard app shortcut) is the primary keyboard entry to the history viewer.

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none documented on this page)* | — | — |

> No user-configurable settings. Session file paths are hard-coded per agent convention (see Behaviors). The "Setup" page covers integration installation that enables session capture.

## Visual spec

### agent-history.png — Transcript Viewer

**Overall layout**: macOS window, traffic-light top-left. Centered title = session task name: "Fill in the TODOs in the workspace files-and-links doc". Top-right: two toolbar buttons, "Resume" (ghost/outlined) and "× Close" (plain text). No tab bar — viewer open in its own pane.

**Left sidebar** (~180px, dark charcoal ~#1E1E1E / #252525): "TABS" small-caps header, then rows:
- "npm run dev" — timestamp badge (right-aligned monospace, e.g. "757")
- "localhost" — badge "757"
- "abner@MacBook-AB..." — green filled circle (online/active) + badge "707"
- "Fill in the TODOs in the..." — **selected row**, lighter bg ~#2E2E2E / accent tint; no timestamp (active history view)
- "OC | Reviewing todos" — badge "757"

**Main content area** (white/near-white ~#FFFFFF):

*Header block*:
- Bold heading "Fill in the TODOs in the workspace files-and-links doc" (~18–20px semibold)
- Session hash + path breadcrumb (small mono gray): `b2d476a8-1c3e-4a5b-9d7f-2e4c0a88d011.json`, `~/Workspace/slopdesk` / `main` / `v2.1.159`
- Turn metadata: "You · 19:30:21" (small gray)

*Tool-call / assistant turn block*:
- Gray italic path: `/Users/abner/Workplace/slopdesk/docs/user/workspace/files-and-links.md`
- User message: "fill in the TODO"
- Collapsed tool-call summary line: "▶ Claude · Agent, 0xBash, Edit, 6×Read · 553 chars" (disclosure triangle + agent + tool list + char count, muted gray)
- Markdown body with inline code spans:
  - Bold heading "Sources verified"
  - Bullet list with inline code (light green/teal pill bg ~#E6F4EA), monospace file paths, cross-refs like "WebSurface.swift:924,3484,5801"
  - Links (`https://`) in blue underline

**Typography**: SF Pro or similar, body ~14px, code mono ~13px. Content padding ~24px left.

**Toolbar buttons** (top-right): "Resume" (ghost/outlined, no fill); "× Close" (plain text, no border) immediately right.

**Color palette** (inferred): sidebar ~#1E2124, selected row ~#2D3139, main area #FFFFFF, green active badge #4CAF50, body text #1A1A1A, secondary #666666, code highlight ~#E8F5E9.

---

### open-code-agent-history.png — Opening History from Context Menu

**Overall layout**: full window, code-agent transcript in center, a **right-click context menu** overlaying it, triggered from tab "OC | Data sync feature consi...".

**Left sidebar** (same dark style): "OC | Consider data sync feature" (orange/amber circle = in-progress), "OC | Data sync feature con..." (selected, lighter), "abner@MacBook-Pro:~/...Wo".

**Context menu** (system macOS popover, white, ~200px wide, ~22px items, separators):

Working-directory group:
- Header "WORKING DIRECTORY"
- "~/Workspace/slopdesk" (mono path)
- "Copy Path"
- "Reveal in Finder"
- "Open in"
- Separator

Git group:
- "Git"
- "OpenCode"
- Separator

Tab actions group:
- "Copy Session ID"
- **"View Session History"** — **highlighted** (white on blue ~#007AFF)
- "Fork in Split Right"
- "Fork in Split Down"
- "Fork in New Tab"
- "Fork in New Window"
- Separator

Status/notifications group (✓ toggles):
- "✓ Badge While Processing"
- "✓ Badge When Task Completes"
- "✓ Badge When Awaiting Input"
- "✓ Notify When Task Completes"
- "✓ Notify When Awaiting Input"
- "Prevent Sleep While Processing"

**Nested menu** to the right shows more tab actions with shortcut column: "Find ⌘F", "Find in All Tabs ⌘⌥F", "Jump to ⌘J", "Command Palette ⌘⇧P".

**Menu typography**: SF ~13px, separators ~0.5px gray, selected item solid blue with white text.

---

### open-agents-quickly.png — Open Quickly Panel — Agents Tab

**Overall layout**: main window behind; a **modal spotlight-style panel** overlays the center — rounded (~12px) floating card, white bg, drop shadow.

**Panel structure**:

*Search field* (top): full-width input, magnifier icon left, "sync" typed (live-filtered), borderless.

*Tab bar*: "All" | "Opened" | "Recent" | "Folders" | "SSH" | **"Agents"** (selected, blue ~#007AFF) | "Current" | "Recipes". Unselected tabs gray.

*Results list* (scrollable):

"CODEX SESSIONS" header (~11px all-caps gray):
- Row 1 (**selected**, light blue ~#EBF2FF): Codex icon; title "consider data sync feature" (bold ~14px); right: "~/Workspace/slopdesk" (gray) · "43s ago" · "Agent" badge (gray-outline pill ~11px)

"CLAUDE CODE SESSIONS" header:
- Row 2: title "consider data sync feature" (same title, different agent); right: "~/Workspace/slopdesk" · "3 min ago" · "Agent" badge

Group header 3 (implied):
- Row 3: title "现在对于BSU|ESU|sync-update的处理，还有和..." (non-Latin = i18n support); right: "~/Workspace/slopdesk" · "46s ago" · "Agent" badge

*Footer bar* (subtle separator, ~11px gray): left "Quick Select ⌘", center-right "Resume ↩", far right "Actions ⌘K".

**Panel colors**: bg white/near-white, selected row ~#EBF2FF, group headers ~#888, badge border ~#CCCCCC, "Agents" tab ~#007AFF, title text ~#1A1A1A, secondary ~#666666.

**Panel sizing**: ~480px wide, ~4–6 results + search + tabs + footer, centered.

## Screenshots

- `agent-history.png` — Transcript viewer in a pane: rendered Claude Code session, toolbar Resume/Close, formatted markdown with code references.
- `open-code-agent-history.png` — Right-click tab context menu with "View Session History" highlighted as the entry point.
- `open-agents-quickly.png` — "Open Quickly" panel, "Agents" tab: fuzzy results grouped by agent (Codex / Claude Code Sessions) with timestamps, paths, Agent badges.

## Implementation notes

### Straightforward

- **Transcript rendering**: render JSONL/JSON session files as formatted transcripts in a terminal pane (like OSC-133 block output in `BlockOutputView`). No libghostty surface needed — it's a SwiftUI view pane, not a PTY pane.
- **Open from Command Palette**: reuse the existing command palette / Open Quickly mechanism (`WorkspaceBindingRegistry`); add an "Agents" tab following the same pattern.
- **Resume via `--resume`**: host spawns a new PTY pane passing `--resume <session-id>` to the agent CLI — a standard `makeSession` call, maps 1:1.
- **"Copy"**: standard pasteboard op.
- **View toggle (transcript ↔ raw JSONL)**: SwiftUI state toggle in the pane's view, switching a `MarkdownText`/structured renderer vs plain/syntax-highlighted view.
- **Fuzzy search across sessions**: the vendored `FuzzyMatcher` (FuzzyMatchV2) powers search over session file names and first-messages. Files live on the **host**, so the host daemon must enumerate and index them.
- **"Send to Chat"**: maps to the Composer — sends selected text to the active agent session's input; needs to know the live pane, via existing pane-routing.

### Constraints from the remote-host architecture

- **Session files are HOST-side**: all session files (`~/.claude/projects/...`, etc.) live on the remote macOS host, not the client. The client can't read them directly — `slopdesk-hostd` must expose session-enumeration and file-read APIs over the control channel or a new inspector channel. Largest architectural gap: the client must proxy files over the wire.
- **Live tab detection for Resume**: sessions run remotely, so the host daemon must report session liveness (which have an active PTY); the client queries this before jump-vs-spawn.
- **Auto-open by path**: pure path detection doesn't translate — the client doesn't browse the host filesystem. Trigger the viewer explicitly (Command Palette / context menu), not by file open/drag-and-drop.
- **iOS client**: the "View Session History" context menu becomes a long-press/swipe on the pane chooser / tab list; "Open Quickly" maps to the iOS pane chooser with an Agents filter; `--resume` spawn works the same (host-side PTY). No PiP/window-management issues.
- **"Notify When Task Completes" / "Badge While Processing"**: tab-level notification/badge settings, agent-generic across all agents. Remote-pane badge state is already tracked (`AgentControlListener`, `ClaudeStatus`); map onto the existing badge-while-processing infra with per-pane preference storage.
- **Remote SSH badge**: not applicable — all slopdesk sessions are remote by construction, so no extra "SSH" badge; the working-dir path shown is the host-side path (e.g. `~/Workspace/project`).
