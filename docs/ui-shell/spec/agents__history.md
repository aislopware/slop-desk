# Agent History

## Summary

Every agent conversation is captured and searchable. Users can resume a thread days later or fork a new task off an old context. Coding-agent session logs render as a readable transcript instead of raw JSON. SlopDesk recognizes three agents by their session file paths and auto-opens matching files as rendered transcripts rather than plain JSONL.

## Behaviors

- **Auto-detection by path**: Session files under a known agent directory are automatically opened as a rendered transcript. Any `.jsonl` file outside those paths opens as plain text (or syntax-highlighted JSONL).
  - Claude Code: `~/.claude/projects/<project>/*.jsonl`
  - Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
  - OpenCode: `~/.local/share/opencode/storage/session/<project>/*.json`
- **Transcript rendering**: Raw JSONL/JSON session logs are rendered as a human-readable conversation transcript (speaker turns, code blocks, tool-call expansions), not as raw JSON.
- **Open from Command Palette**: The history viewer can be opened via the Command Palette.
- **Open from titlebar dropdown menu**: The history viewer can also be opened from the titlebar dropdown/context menu on a tab (right-click → "View Session History"). This is the primary discovery path shown in the screenshots.
- **Text selection + context menu**: Users can select any text in the transcript and use a context menu to either "Copy" the selection or "Send to Chat" (inserts it into the composer of the current/active agent session).
- **Resume button in toolbar**: A "Resume" button appears in the transcript viewer toolbar. Behavior:
  - If the session is **still running** (live tab exists): jumps to that live tab.
  - If the session has **ended**: spawns a fresh agent tab using the agent's `--resume <session-id>` flag, continuing from where the conversation left off.
  - The resumed session keeps the original provider, model, and system prompt — only the conversation continues.
- **View toggle (raw ↔ transcript)**: Right-click → View as → `<Agent> History` ⇄ `JSONL (Syntax Highlight)` toggles between the rendered transcript and the raw syntax-highlighted log.
- **Open Quickly — Agents tab**: The "Open Quickly" panel (quick-open / fuzzy finder) has an "Agents" tab that searches sessions across all supported code agents simultaneously.
  - Sessions appear grouped by agent (e.g. "CODEX SESSIONS", "CLAUDE CODE SESSIONS").
  - Each result shows the session title/first message, working directory path, and relative timestamp (e.g. "43s ago", "3 min ago").
  - An "Agent" badge appears on the right of each result row.
  - Typing filters results fuzzy-matched across all agents at once.
  - Footer of the panel shows keyboard shortcuts: "Quick Select ⌘" and "Resume ↩" and "Actions ⌘K".
- **Agent-generic vs Claude-Code-specific**:
  - Agent-generic: transcript rendering, resume, view-toggle, Open Quickly Agents tab, Send to Chat, Copy.
  - Claude-Code-specific: session path `~/.claude/projects/<project>/*.jsonl`; `--resume` flag behavior is Claude Code's CLI flag semantics.

## Keybindings

| Action | Keys |
|--------|------|
| Quick Select in Open Quickly panel | ⌘ (Cmd) |
| Resume session from Open Quickly panel | ↩ (Return) |
| Show Actions for selected item in Open Quickly panel | ⌘K |

> Note: No additional explicit keyboard shortcuts are documented on this page beyond the Open Quickly footer hints. The Command Palette (standard app shortcut) is the primary keyboard entry point to the history viewer.

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none documented on this page)* | — | — |

> The history page documents no user-configurable settings. Session file paths are hard-coded per agent convention (see Behaviors). The "Setup" page covers integration installation that enables session capture.

## Visual spec

### agent-history.png — Transcript Viewer

**Overall layout**: A standard macOS app window with three-button traffic light (close/minimize/zoom) at top-left. Window title bar centered text reads the session task name: "Fill in the TODOs in the workspace files-and-links doc". Top-right corner has two toolbar buttons: "Resume" (outlined/ghost style) and "× Close" (plain text with × prefix). No tab bar visible — this is the viewer open in its own pane.

**Left sidebar** (narrow, ~180px, dark charcoal background approximately #1E1E1E / #252525): Shows a tab list with labels — "TABS" section header in small caps, followed by rows:
- "npm run dev" — with a timestamp badge (right-aligned, small monospace number e.g. "757")
- "localhost" — with timestamp badge "757"
- "abner@MacBook-AB..." — with a green filled circle badge (online/active indicator) and timestamp "707"
- "Fill in the TODOs in the..." — **selected row**, highlighted with a slightly lighter background ~#2E2E2E or accent tint; no timestamp (this is the active history view)
- "OC | Reviewing todos" — with timestamp "757"

**Main content area** (light/white background, ~#FFFFFF or very light gray):

*Header block* (top of content):
- Large bold heading: "Fill in the TODOs in the workspace files-and-links doc" (dark, ~18-20px, semibold)
- Below heading: commit/session hash in small monospace gray text: `b2d476a8-1c3e-4a5b-9d7f-2e4c0a88d011.json` and path `~/Workspace/slopdesk` / `main` / `v2.1.159` (breadcrumb style, gray, small)
- Below that: agent turn metadata: bullet "You · 19:30:21" in small gray text

*Tool-call / assistant turn block*:
- Gray italic path: `/Users/abner/Workplace/slopdesk/docs/user/workspace/files-and-links.md`
- User message in plain text: "fill in the TODO"
- Collapsible/indented block starting with "▶ Claude · Agent, 0xBash, Edit, 6×Read · 553 chars" — this is a collapsed tool-call summary line (disclosure triangle + agent name + tool list + char count), rendered in subdued gray/muted style.
- Body text below the tool summary, rendered as markdown with inline code spans in colored/highlighted style (greenish `#` prefixed links, standard body text ~14px):
  - Heading "Sources verified" as bold text
  - Bullet list with inline code (highlighted in light green/teal background `#E6F4EA` approx), file paths in monospace, and cross-references like "WebSurface.swift:924,3484,5801"
  - Inline `code` spans use a light background pill/chip style
  - Links (e.g. `https://`) shown in blue underline

**Typography**: System font (SF Pro or similar), body ~14px, code monospace ~13px. Background of main area is white/near-white. Content padding ~24px left, comfortable line spacing.

**Toolbar buttons** (top-right):
- "Resume" button: outlined rectangular button, light border, text "Resume", no fill (ghost/secondary style). Located at top-right of content area.
- "× Close" button: plain text "× Close" immediately right of Resume, no border.

**Color palette** (inferred): Dark sidebar ~#1E2124, selected row ~#2D3139, white main area #FFFFFF, green active badge #4CAF50, body text #1A1A1A, secondary text #666666, code highlight background ~#E8F5E9.

---

### open-code-agent-history.png — Opening History from Context Menu

**Overall layout**: Full app window showing a session in progress (code agent transcript visible in center). A **right-click context menu** is open, overlaying the content. The menu appears triggered from a tab in the tab list (the tab "OC | Data sync feature consi..." is right-clicked).

**Left sidebar** (same dark style as above): Two tabs visible — "OC | Consider data sync feature" (with orange/amber circular badge indicating in-progress) and "OC | Data sync feature con..." (selected, lighter background). "abner@MacBook-Pro:~/...Wo" tab below.

**Context menu** (system-style macOS popover, white background with standard macOS menu styling, ~200px wide, items ~22px tall, separator lines between groups):

Top section (working-directory group):
- Section header label: "WORKING DIRECTORY" in small all-caps gray
- "~/Workspace/slopdesk" — monospace path text
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
- **"View Session History"** — **this item is highlighted** (blue/accent selection state, white text on blue ~#007AFF background)
- "Fork in Split Right"
- "Fork in Split Down"
- "Fork in New Tab"
- "Fork in New Window"
- Separator

Status/notifications group (with toggle checkmarks ✓):
- "✓ Badge While Processing"
- "✓ Badge When Task Completes"
- "✓ Badge When Awaiting Input"
- "✓ Notify When Task Completes"
- "✓ Notify When Awaiting Input"
- "Prevent Sleep While Processing"

**Keyboard shortcut column** visible for some items (e.g. "Find ⌘F", "Find in All Tabs ⌘⌥F", "Jump to ⌘J", "Command Palette ⌘⇧P") in a secondary panel to the right — appears there's a cascading/nested menu structure showing more standard tab actions to the right of the main context menu.

**Menu typography**: SF system font ~13px, separator lines ~0.5px gray, selected item is solid blue rectangle with white text.

---

### open-agents-quickly.png — Open Quickly Panel — Agents Tab

**Overall layout**: The main app window is visible in the background (dark sidebar, tab list). A **modal spotlight-style panel** overlays the center of the window. The panel is a rounded-rectangle (~12px radius) floating card, light/white background, with a drop shadow.

**Panel structure**:

*Search field* (top): Full-width text input with search icon (magnifying glass) on left, text "sync" typed in (showing a live filtered result), no border — integrated into panel top.

*Tab bar* below search: Horizontal tab strip with labels: "All" | "Opened" | "Recent" | "Folders" | "SSH" | **"Agents"** (selected, blue text ~#007AFF with subtle underline or highlight) | "Current" | "Recipes". Each tab is a small pill/text tab, unselected tabs in gray.

*Results list* (scrollable):

Group header 1: "CODEX SESSIONS" — small all-caps gray label, ~11px.
- Row 1 (selected/highlighted, light blue tint background ~#EBF2FF):
  - Left icon: small circular icon or agent logo (Codex)
  - Title: "consider data sync feature" (bold ~14px dark)
  - Right side: path "~/Workspace/slopdesk" in gray small text, then "43s ago" in muted gray, then "Agent" badge (small rounded rectangle, gray outline, gray text "Agent", ~11px)
  - Selection highlight: entire row is tinted blue

Group header 2: "CLAUDE CODE SESSIONS" — same small all-caps gray label.
- Row 2:
  - Title: "consider data sync feature" (same title, different agent)
  - Right: "~/Workspace/slopdesk" · "3 min ago" · "Agent" badge

Group header 3 (implied "CLAUDE CODE" or another): 
- Row 3:
  - Title: "现在对于BSU|ESU|sync-update的处理，还有和..." (non-Latin session title, showing internationalization support)
  - Right: "~/Workspace/slopdesk" · "46s ago" · "Agent" badge

*Footer bar* (bottom of panel, very subtle separator): 
- Left: "Quick Select ⌘" (small gray text + keyboard icon)
- Center-right: "Resume ↩" 
- Far right: "Actions ⌘K"
- All in small ~11px gray muted text

**Panel colors**: Background white/near-white, selected row ~#EBF2FF (light blue), group headers gray ~#888, badge pill border ~#CCCCCC, "Agents" tab selected ~#007AFF, result title text ~#1A1A1A, secondary text ~#666666.

**Panel sizing**: Approximately 480px wide, tall enough to show ~4-6 results + search + tabs + footer. Centered in window.

## Screenshots

- `agent-history.png` — Transcript viewer open in a pane, showing a rendered Claude Code session with toolbar Resume/Close buttons and formatted markdown output with code references.
- `open-code-agent-history.png` — Right-click context menu on a tab, with "View Session History" highlighted as the entry point to open the history viewer.
- `open-agents-quickly.png` — "Open Quickly" panel with "Agents" tab selected, showing fuzzy search results grouped by agent (Codex Sessions / Claude Code Sessions) with timestamps, paths, and Agent badges.

## Implementation notes

### Straightforward

- **Transcript rendering**: SlopDesk can render JSONL/JSON session files as formatted transcripts inside a terminal pane (similar to how it renders OSC-133 block output in `BlockOutputView`). The libghostty surface is not needed for this — it is a SwiftUI view pane, not a PTY pane.
- **Open from Command Palette**: SlopDesk already has a command palette / Open Quickly mechanism (`WorkspaceBindingRegistry`). An "Agents" tab can be added there following the same pattern.
- **Resume via `--resume` flag**: On the macOS host side, slopdesk spawns a new PTY pane and passes `--resume <session-id>` to the agent CLI. This is a standard `makeSession` call — maps 1:1.
- **"Copy" from context menu**: Standard pasteboard operation — no mapping issues.
- **View toggle (transcript ↔ raw JSONL)**: Implementable as a SwiftUI state toggle within the pane's view, switching between a `MarkdownText`/structured transcript renderer and a plain text/syntax-highlighted view.
- **Fuzzy search across agent sessions**: The vendored `FuzzyMatcher` (FuzzyMatchV2) already in slopdesk can power search across session file names and first-messages. Session files live on the **host** filesystem, so the host daemon must enumerate and index them.
- **"Send to Chat"**: Maps to the slopdesk Composer feature — sends selected text to the active agent session's input. Requires knowing which pane is the live session; maps onto the existing pane-routing infrastructure.

### Constraints from the remote-host architecture

- **Session file path is HOST-side**: All session files (`~/.claude/projects/...`, etc.) are on the **remote macOS host**, not the local client. The slopdesk client cannot directly read them. The host daemon (`slopdesk-hostd`) must expose a session-enumeration and session-file-read API over the existing control channel or a new inspector channel. This is the largest architectural gap: session files live on the host, so the client must proxy them over the wire rather than reading them from local disk.
- **Live tab detection for Resume**: Because sessions run on the remote host, the host daemon must report session liveness (which sessions have an active PTY). The client must query this before deciding whether to jump to an existing pane vs. spawn a new one.
- **Auto-open by path**: Detecting session files purely by filesystem path (as when opening a `.jsonl` file) doesn't translate to slopdesk's remote context — the client doesn't browse the host filesystem directly. The history viewer must be triggered explicitly (via Command Palette / context menu) rather than by "open file" drag-and-drop.
- **iOS client**: On iOS, the context menu ("View Session History" from tab right-click) becomes a long-press or swipe action on the pane chooser / tab list. The "Open Quickly" panel maps to the iOS pane chooser with an Agents filter tab. The `--resume` spawn flow works the same (host-side PTY creation). No OS-level PiP or window management issues apply here.
- **"Notify When Task Completes" / "Badge While Processing"** (visible in the context menu screenshot): These are tab-level notification/badge settings that are agent-generic across all supported agents. Badge state for remote panes is already tracked via the existing pane status/badge system (`AgentControlListener`, `ClaudeStatus`). These toggle behaviors should map onto the existing badge-while-processing infrastructure with per-pane preference storage.
- **Remote SSH badge** on session results: Not applicable — slopdesk's sessions ARE remote by construction; all sessions are implicitly remote. No extra "SSH" badge needed on results, but the working directory path shown in results would be the host-side path (e.g. `~/Workspace/project` on the host).
