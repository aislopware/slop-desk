# Outline / Jump To

## Summary

Jump between user-run commands, prompts, and files in the scrollback, powered by the OSC 133 prompt marks the shell emits under Shell Integration. SlopDesk uses those marks to build a per-pane index of user commands with exit status, surfaced in two places: (1) the Jump To panel (⌘J / ⌘⇧O), a floating quick-switcher overlay with a "Current" filter tab, and (2) the Outline sidebar panel in the Details Panel (right sidebar).

## Behaviors

- **Per-pane command index**: Built by consuming OSC 133 marks; live — new commands appear as run.
- **Exit-status decoration in gutter**: Each indexed row shows an exit badge in the left gutter:
  - Green tick (✓) = exit 0 (success)
  - Red cross (✗) = non-zero exit (failure)
  - Grey dot (·) = still running (in-progress)
- **Jump To panel (⌘J)**: Floating searchable panel (like Open Quickly) over the terminal, showing current-pane commands under the "Current" tab. Type to filter; ↩ jumps scrollback to that command.
- **Open Quickly "Current" filter (⌘⇧O)**: Opens Open Quickly on the "Current" filter — every command in the focused pane, same filter/jump behavior. Tabs: All | Opened | Recent | Folders | SSH | Agents | **Current** | Recipes.
- **Outline in Details Panel (sidebar)**: A tab/section in the right sidebar; content varies by session type:
  - **Terminal session**: All entered commands, chronological, with timestamps and exit-status glyphs.
  - **Supported code agent session** (e.g. Claude Code): Also lists history prompts sent to the agent, plus shell commands.
  - **Markdown file preview session**: All headings (H1–H6) as a navigable table of contents.
- **Right-click context menu on outline rows**: At minimum, jump to that scrollback location and copy the row's text.
- **No prompt modification required**: Shell integration is injected via shell hooks; no PS1/PROMPT changes.
- **Scrollback jump behavior**: Selecting a command/prompt/heading (Jump To panel or Outline sidebar) scrolls the terminal to bring it into view.
- **Requirements**: A supported shell (bash/zsh/fish) with SlopDesk's shell integration hooks installed and Shell Integration activated in settings.

## Keybindings

| Action | Keys |
|--------|------|
| Open Jump To panel (command-indexed quick-jump) | ⌘J |
| Open Open Quickly with "Current" filter (command list for focused pane) | ⌘⇧O |
| Confirm / jump to selected entry (in Jump To / Open Quickly) | ↩ (Return) |

## Config keys

No dedicated config keys. Gated on Shell Integration (a global setting) — see the Shell Integration configuration page for the toggle.

| Key | Default | Effect |
|-----|---------|--------|
| *(Shell Integration enabled — see Shell Integration page)* | on (when hooks installed) | Enables OSC 133 mark emission, which drives the per-pane command index. Without it, the outline is empty. |

## Visual spec

### Screenshot 1: jump-to.png — Jump To panel (⌘J / ⌘⇧O "Current" tab)

**Overall layout**: Full macOS window (Monokai-style dark theme, traffic lights top-left, title bar). Split: left sidebar (~80px, session list), center terminal content, right sidebar (git/diff panel, ~220px). The Jump To / Open Quickly panel floats as a centered modal (~480×280px) over the center content — elevated card, dark background, rounded corners, shadow.

**Jump To / Open Quickly panel anatomy**:
- **Search bar** (top): magnifying-glass icon left, placeholder "Search commands, URLs, files…" in muted gray, full-width input, dark background (~#1e1e1e).
- **Filter tab bar** (below search): horizontal pill tabs "All | Opened | Recent | Folders | SSH | Agents | **Current** | Recipes". **"Current"** is active — white/light filled pill, dark text — vs muted text for the rest. This is the Outline/Jump-To view.
- **Results list**: each row a command entry. Columns:
  - Left: type icon (file/folder/command/URL; a "Cmd" tag for commands, "Prompt" tag for agent prompts).
  - Center: command text or path, left-aligned. Paths use `~/Workspace/...` shorthand; long text truncates with ellipsis.
  - Right: relative timestamp ("4 min ago", "11 min ago", "18 min ago", "33s ago") and type badge ("File", "Folder", "URL", "Cmd", "Prompt").
- A "RECENTS" gray all-caps section divider appears mid-list, separating older recents from current-session commands above.
- **Bottom bar**: "Quick Select ⌘" left; "Open ↗" and "Actions ⌘K" right.
- **Keyboard hint strip** (very bottom, outside scroll): "⌘ select" and "enter confirm" in muted text.

**Command/prompt row detail** (within "Current" tab):
- Command rows show a terminal/shell icon; agent-prompt rows a different icon.
- Last visible row ("现在 agent history viewer 的 font blending 其体是哪些代码实现的") is "Prompt" type, "33s ago" — a Chinese-language prompt, confirming CJK support.
- No gutter exit-status indicators in this overlay (those live in the sidebar Outline panel).

**Color palette (panel)**:
- Panel background: very dark gray, ~#252526 or #1e1e2e.
- Active tab pill: white (#ffffff), dark text.
- Inactive tab text: muted gray (~#888).
- Entry text: off-white (~#d4d4d4).
- Path/secondary text: dimmer (~#aaaaaa).
- Timestamp/badge text: muted gray, smaller.
- Section header ("RECENTS"): all-caps, small, muted gray (~#666).
- Search icon and placeholder: muted gray.

**Right sidebar (git panel)** — unrelated to Outline, confirms window layout: git branch "main", diff stats (+150 -403), repo URL "https://github.com/example-org/project", Staged (18) and Unstaged (8) file lists with relative paths and change indicators.

**Terminal content area (behind panel)**: dark terminal showing output "native color space + CoreGraphics smoothing bit + terminal atlas/Metal composition"; bottom shows prompt `> Explain this codebase` and output `gpt-5.5 xhigh -- ~/Workspace/project` (active agent session).

### Screenshot 2: outline-panel.png — Outline Panel (right sidebar, Details Panel)

**Overall layout**: Full macOS window, title bar "QC | Reviewing todos". Left sidebar absent/collapsed. Center is the terminal/agent output pane (dark). Right sidebar (~220px, ~#252526) shows the **Outline panel**.

**Outline sidebar panel anatomy**:
- **Tab bar** (top): multiple icon buttons; active tab is "**Outline**" (text or highlighted icon). Other Details Panel section icons flank it.
- **Session header row**: "~/Workspace/project" path and "4m ago" in small muted text.
- **Entry rows** (agent prompts in this code agent session):
  - Row 1: "opencode" — bare short entry (command or session name).
  - Row 2: "OpenCode _...iewing todos" — truncated, "7h ago".
  - Row 3: "<system-reminder>Note: The u..." — truncated system prompt.
  - Row 4: "give me more details about The..." — truncated user prompt.
- No gutter exit-status indicators (these are prompt-history rows, not shell commands).
- Row typography: primary off-white (~#d4d4d4); secondary/timestamp muted (~#888), smaller.
- Row height: compact ~36–40px with padding.
- Thin 1px vertical divider on the sidebar's left edge.
- **No scrollbar visible** but scrollable.

**Main terminal content area** (center, behind Outline panel):
- Code agent session ("QC | Reviewing todos" — likely OpenCode/Claude Code).
- Top: "Build · GLM-5.1 · 51.1s" status badge (orange/yellow).
- User prompt: "give me more details about Theme/view TODOs".
- Agent response: "Thought: 1.3s", then prose "The user wants more details about the two Theme/view TODOs from the code-review-todos doc. Let me re-read those sections and then look at the actual source files they reference."
- Tool call rows:
  - "→ Read docs/code-review-todos.md [offset=476, limit=32]"
  - "i Explore Task — Read three hex decode sites"
  - "∨ 2 toolcalls" (collapsed group)
- "ctrl×b down view subagents" — nav hint.
- Second "Build · GLM-5.1" badge row.
- **Permission required** dialog block (raised/bordered, slightly highlighted):
  - "◈ Access external directory ~/Workspace/project/packages/app-macos/Sources/Packages/OpenQuickly"
  - "Patterns": "~/Users/abner/Workspace/project/packages/app-macos/Sources/Packages/OpenQuickly/*"
  - Action bar: "**Allow once**" (filled primary, amber/orange), "Allow always", "Reject"; hints "ctrl+f fullscreen", "m select", "enter confirm".

**Color palette (outline sidebar)**:
- Sidebar background: ~#252526 (slightly lighter than terminal ~#1e1e1e).
- Divider line: 1px, ~#333.
- Active tab: highlighted "Outline" tab icon.
- Row text: off-white ~#d4d4d4.
- Timestamp/secondary: muted gray ~#888.
- Hover/selected row: not visible here.

**Permission dialog visual treatment**: raised/bordered panel within terminal content, neutral-dark border, distinct from output rows. "Allow once" is a filled button (amber/orange, matching agent theme); "Allow always" and "Reject" are plain text links.

## Screenshots

- `jump-to.png` — Jump To panel (⌘J), Open Quickly overlay with "Current" tab active, listing agent prompts and shell commands from the focused pane.
- `outline-panel.png` — Outline Panel, right sidebar Details Panel "Outline" tab with a code agent session's prompt history.

## SlopDesk mapping notes

### Direct mappings

- **OSC 133 marks**: SlopDesk already consumes OSC 133 for Blocks (`OSC-133`, `OSC_133`). Build the command index on the existing block/mark infra: `OSC 133 ; A` (prompt start) and `OSC 133 ; C/D` (command end + exit code) give the data.
- **Exit status decoration**: Exit code from `OSC 133 ; D ; <exit_code>` → green/red/grey glyph. Already partially tracked in Blocks.
- **Outline sidebar panel**: A tab in the Details Panel. A `BlockOutputView` or custom `OutlineView` SwiftUI component reads the pane's `BlockIndex` and renders rows with timestamps and exit badges.
- **Jump To panel**: A floating overlay sheet. Reuse the vendored fzf `FuzzyMatcher` (as of 2026-06-25) for filtering. "Current" shows only the focused pane's index; other tabs map to existing Open Quickly filters.
- **Keybinding ⌘J / ⌘⇧O**: Register via `WorkspaceBindingRegistry` / NSEvent monitor prefix. ⌘⇧O is already the Open Quickly keybinding.
- **Agent prompt history in Outline**: For code agent sessions, source history prompts from `BlockKind.prompt` entries in the agent block parser. Agent-generic, not Claude-Code-specific.
- **Markdown heading outline**: Parse headings for markdown preview panes (if/when supported). Not a priority — SlopDesk is a coding/remote tool, not a document viewer.
- **Right-click context menu**: Standard `contextMenu` modifier per row: "Jump to" and "Copy".
- **Scrollback jump**: On selection, scroll the libghostty surface to the selected block's scrollback offset (libghostty supports programmatic scroll positioning).
- **Truncation with ellipsis**: Compact rows (~36–40px) with ellipsis truncation, matching the visual.

### Cannot map 1:1 — caveats and gaps

- **Host-side CWD in outline rows**: A local-only design shows `~/Workspace/project` because it runs locally. In SlopDesk, CWD comes from OSC 7 (`OSC 7 ; file://host/path`) emitted by the remote shell; if the remote shell doesn't emit OSC 7, the session path label is absent or stale.
- **"Current" tab across remote sessions**: With multiple hosts open, "Current" must scope to the focused pane's pane-local index, not global history — natural if stored per-pane. No architectural blocker, but the per-pane index must be maintained client-side from the OSC 133 marks received over the wire.
- **Timestamp accuracy**: Relative timestamps ("4m ago") are local. A mark's arrival time at the client may differ from host shell-execution time by RTT — negligible for UX, but use client-receive-time as the timestamp, not a host clock.
- **Supported agent session detection**: Claude Code sessions are auto-detected via `ClaudeStatus`/`ClaudePaneDetector`. Check `PaneKind` to choose the prompt-history view vs the plain command list.
- **iOS client**: The Outline panel maps to a sheet/secondary panel (no persistent sidebar). ⌘J has no direct iOS shortcut — expose via toolbar button or gesture. Compact rows (36–40px) work, but touch targets should be ≥44pt.
- **Remote SSH badge on outline rows**: N/A — all SlopDesk sessions are remote; no local-vs-remote badge needed.
