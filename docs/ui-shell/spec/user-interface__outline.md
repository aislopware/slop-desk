# Outline / Jump To

## Summary

Jump between user-run commands, prompts, files (available in jump to panel) in the scrollback. Powered by the prompt marks your shell already emits.

When Shell Integration is active, the shell emits OSC 133 marks around each prompt and command. SlopDesk uses those marks to build a per-pane index of user commands with exit status. The Outline feature is surfaced in two places: (1) the Jump To panel (⌘J / ⌘⇧O), a floating quick-switcher overlay that also lists commands under a "Current" filter tab, and (2) the Outline sidebar panel shown in the Details Panel (right sidebar).

## Behaviors

- **Per-pane command index**: SlopDesk builds a per-pane index of all user-entered commands by consuming OSC 133 marks (shell integration). The index is live — new commands appear as they are run.
- **Exit-status decoration in gutter**: Each indexed command row displays an exit-status badge in the left gutter:
  - Green tick (✓) = exit code 0 (success)
  - Red cross (✗) = non-zero exit code (failure)
  - Grey dot (·) = command still running (in-progress)
- **Jump To panel (⌘J)**: Opens a floating searchable panel (similar to Open Quickly) over the terminal. Displays commands from the current pane under a "Current" filter tab. Typing a fragment filters the list; pressing ↩ jumps the scrollback to that command's location.
- **Open Quickly "Current" filter (⌘⇧O)**: Opens the Open Quickly panel and switches the filter to "Current," showing every command in the focused pane as a searchable list. Same filter/jump behavior as above. Displayed as one of multiple filter tabs: All | Opened | Recent | Folders | SSH | Agents | **Current** | Recipes.
- **Outline in Details Panel (sidebar)**: The outline panel appears as a tab/section in the right sidebar ("Details Panel"). Content varies by session type:
  - **Terminal session**: Lists all commands the user has entered, in chronological order with timestamps and exit-status glyphs.
  - **Supported code agent session** (e.g. Claude Code): Also lists history prompts (the prompts the user sent to the agent), in addition to shell commands.
  - **Markdown file preview session**: Shows all headings (H1–H6) found in the markdown file, as a navigable table of contents.
- **Right-click context menu on outline rows**: Right-clicking any row in the outline sidebar panel offers at minimum two actions: jump to that location in the scrollback, and copy the text content of that row.
- **No prompt modification required**: SlopDesk injects shell integration via shell hooks; users do not need to modify their PS1/PROMPT. Integration is done entirely through shell hook injection.
- **Scrollback jump behavior**: Selecting a command/prompt/heading in either the Jump To panel or the Outline sidebar scrolls the terminal's scrollback buffer to bring that entry into view.
- **Requirements**: A supported shell (bash/zsh/fish) with SlopDesk's shell integration hooks installed and Shell Integration activated in SlopDesk settings.

## Keybindings

| Action | Keys |
|--------|------|
| Open Jump To panel (command-indexed quick-jump) | ⌘J |
| Open Open Quickly with "Current" filter (command list for focused pane) | ⌘⇧O |
| Confirm / jump to selected entry (in Jump To / Open Quickly) | ↩ (Return) |

## Config keys

No dedicated config keys are documented for this feature. The Outline / Jump To feature is gated on Shell Integration being active (a global setting). Refer to the Shell Integration configuration page for the relevant toggle.

| Key | Default | Effect |
|-----|---------|--------|
| *(Shell Integration enabled — see Shell Integration page)* | on (when hooks installed) | Enables OSC 133 mark emission, which drives the per-pane command index for Outline / Jump To. Without this, the outline is empty. |

## Visual spec

### Screenshot 1: jump-to.png — Jump To panel (⌘J / ⌘⇧O "Current" tab)

**Overall layout**: Full macOS app window (Monokai-style dark-ish theme, traffic-light buttons top-left, title bar). The window is split: left sidebar (narrow, ~80px wide, dark background, session list), center terminal content area (dark background, white/colored terminal text), and right sidebar (file diff / git panel, ~220px wide). The Jump To / Open Quickly panel floats as a centered modal overlay on top of the center content area, roughly 480×280px, with a slightly elevated card appearance (dark background, subtle rounded corners, shadow).

**Jump To / Open Quickly panel anatomy**:
- **Search bar** at top: magnifying glass icon on the left, placeholder text "Search commands, URLs, files…" in muted gray, full-width input field, dark background (~#1e1e1e or similar).
- **Filter tab bar** immediately below the search bar: horizontal pill-style tabs reading "All | Opened | Recent | Folders | SSH | Agents | **Current** | Recipes". The **"Current"** tab is selected/active — displayed with a white/light filled pill background and dark text, distinguishing it from the other tabs (which appear as muted text on the dark background). This is the Outline/Jump-To–specific view.
- **Results list** below the tab bar: each row is a command entry. Columns visible:
  - Left: small icon indicating entry type (file icon for files, folder icon for folders, command/shell icon for commands, URL icon for URLs, a "Cmd" tag for command entries, "Prompt" tag for agent prompt entries).
  - Center: the command text or file path, left-aligned. Paths use `~/Workspace/...` shorthand. Command text is shown in full, truncated with ellipsis if very long.
  - Right: relative timestamp ("4 min ago", "11 min ago", "18 min ago", "33s ago") and a type badge ("File", "Folder", "URL", "Cmd", "Prompt").
- A "RECENTS" section header appears mid-list as a gray all-caps section divider label, separating older recent commands from current-session commands above.
- **Bottom bar** of the panel: "Quick Select ⌘" label on the left; "Open ↗" and "Actions ⌘K" affordances on the right.
- **Keyboard hint strip** at very bottom of panel (outside scroll area): shows "⌘ select" and "enter confirm" mnemonics in muted text.

**Command/prompt row detail** (within "Current" tab):
- Rows for commands show a terminal/shell icon; rows for agent prompts show a different icon.
- The last visible row ("现在 agent history viewer 的 font blending 其体是哪些代码实现的") is labeled "Prompt" type with "33s ago" — this is a Chinese-language agent prompt, confirming the outline works with CJK text.
- No gutter exit-status indicators are visible in this overlay view (those appear in the sidebar Outline panel instead).

**Color palette (panel)**:
- Panel background: very dark gray, approximately #252526 or #1e1e2e.
- Active tab pill: white (#ffffff) background, dark text.
- Inactive tab text: muted medium gray (~#888).
- Entry text: off-white (~#d4d4d4).
- Path/secondary text: slightly dimmer (~#aaaaaa).
- Timestamp/badge text: muted gray, smaller font size.
- Section header ("RECENTS"): all-caps, small font, muted gray (~#666).
- Search icon and placeholder: muted gray.

**Right sidebar (git panel)**:
- Shows git branch "main", diff stats (+150 -403), repo URL "https://github.com/example-org/project".
- Staged (18) and Unstaged (8) file lists with relative paths and change indicators.
- This panel is unrelated to Outline but confirms the overall window layout and sidebar coexistence.

**Terminal content area (behind the panel)**:
- Dark terminal, showing a command output with "native color space + CoreGraphics smoothing bit + terminal atlas/Metal composition".
- Bottom: a shell prompt `> Explain this codebase` and output `gpt-5.5 xhigh -- ~/Workspace/project`, suggesting an active agent session.

### Screenshot 2: outline-panel.png — Outline Panel (right sidebar, Details Panel)

**Overall layout**: Full macOS app window, title bar reads "QC | Reviewing todos". Left sidebar is absent or collapsed. Center area is the main terminal/agent output pane (dark background). Right sidebar (~220px wide, medium-dark background ~#252526) shows the **Outline panel**.

**Outline sidebar panel anatomy**:
- **Tab bar** at top of right sidebar: multiple icon buttons visible. The active tab is labeled "**Outline**" in text (or via an icon that is currently selected/highlighted). Other tab icons are visible to its left and right (unspecified icon buttons for other Details Panel sections).
- **Session header row**: shows "~/Workspace/project" path and "4m ago" timestamp in small muted text.
- **Entry rows** (agent prompt entries in this code agent session):
  - Row 1: "opencode" — a bare short entry, likely a command or session name.
  - Row 2 (indented or same level): "OpenCode _...iewing todos" — truncated with ellipsis, labeled "7h ago".
  - Row 3 (prompt text, wrapping): "<system-reminder>Note: The u..." — truncated, showing the beginning of a system prompt content.
  - Row 4 (prompt text): "give me more details about The..." — truncated user prompt.
- Rows have no visible gutter exit-status indicators (those are for shell commands; these are agent prompt history rows).
- Row typography: primary text is off-white/light (~#d4d4d4), secondary/timestamp text is muted (~#888), smaller font.
- Row height: compact, approximately 36–40px per row including padding.
- The sidebar has a thin vertical divider line on its left edge separating it from the terminal content area.
- **No scrollbar visible** but the panel is scrollable.

**Main terminal content area** (center, behind the Outline panel):
- Shows a code agent session ("QC | Reviewing todos" — likely an OpenCode/Claude Code agent session).
- Top: "Build · GLM-5.1 · 51.1s" status/badge row (orange/yellow badge with build info).
- User prompt row: "give me more details about Theme/view TODOs" (light text on dark background).
- Agent response block: "Thought: 1.3s" timestamp, then indented prose: "The user wants more details about the two Theme/view TODOs from the code-review-todos doc. Let me re-read those sections and then look at the actual source files they reference."
- Tool call rows:
  - "→ Read docs/code-review-todos.md [offset=476, limit=32]"
  - "i Explore Task — Read three hex decode sites"
  - "∨ 2 toolcalls" (collapsed group)
- "ctrl×b down view subagents" — keyboard hint for navigation.
- Second "Build · GLM-5.1" badge row.
- **Permission required** dialog block (distinct visual treatment, slightly highlighted background):
  - "◈ Access external directory ~/Workspace/project/packages/app-macos/Sources/Packages/OpenQuickly"
  - "Patterns" section listing: "~/Users/abner/Workspace/project/packages/app-macos/Sources/Packages/OpenQuickly/*"
  - Bottom action bar: "**Allow once**" (filled/primary button, orange or amber background), "Allow always", "Reject" — and keyboard hints "ctrl+f fullscreen", "m select", "enter confirm".

**Color palette (outline sidebar)**:
- Sidebar background: dark gray ~#252526 (slightly lighter than the terminal background ~#1e1e1e).
- Divider line: 1px, very dark (~#333 or similar).
- Active tab indicator: visible selection state on "Outline" tab icon (highlighted).
- Row text: off-white ~#d4d4d4.
- Timestamp/secondary: muted gray ~#888.
- Hover/selected row: not visible in this screenshot.

**Permission dialog visual treatment**:
- The permission block uses a slightly raised/bordered panel within the terminal content, with a neutral-dark border, distinct from regular terminal output rows.
- Action buttons: "Allow once" has a filled button appearance (possibly amber/orange fill matching the agent session theme), while "Allow always" and "Reject" are plain text links.

## Screenshots

- `jump-to.png` — Jump To panel (⌘J), showing Open Quickly overlay with "Current" tab active, listing agent prompts and shell commands from the focused pane.
- `outline-panel.png` — Outline Panel, showing the right sidebar Details Panel "Outline" tab with a code agent session's prompt history entries.

## SlopDesk mapping notes

### Direct mappings

- **OSC 133 marks**: SlopDesk already consumes OSC 133 (shell integration) for the Blocks system (`OSC-133`, `OSC_133` references in the codebase). The per-pane command index for Outline can be built on top of the existing block/mark infrastructure. Each `OSC 133 ; A` (prompt start) and `OSC 133 ; C/D` (command end + exit code) marker gives the data needed.
- **Exit status decoration**: The exit code is available from `OSC 133 ; D ; <exit_code>` — map to green/red/grey glyph in the Outline sidebar row. Already partially tracked in the Blocks system.
- **Outline sidebar panel**: Maps to a tab in the Details Panel (right sidebar in the macOS client UI). Implementation: a `BlockOutputView` or custom `OutlineView` SwiftUI component that reads the current pane's `BlockIndex` and renders command rows with timestamps and exit-status badges.
- **Jump To panel**: Maps to a floating overlay sheet/panel in the macOS client UI. Can reuse the existing fzf `FuzzyMatcher` (vendored as of 2026-06-25) for filtering. The "Current" filter tab shows only commands from the focused pane's index; other tabs (All, Recent, etc.) map to existing Open Quickly filters.
- **Keybinding ⌘J / ⌘⇧O**: Register via the existing `WorkspaceBindingRegistry` / NSEvent monitor prefix system. ⌘⇧O is already noted as the Open Quickly keybinding in the codebase.
- **Agent prompt history in Outline**: For code agent sessions (Claude Code), the outline should also list history prompts. These can be sourced from the `BlockKind.prompt` entries already tracked in the agent block parser. This is agent-generic (any supported agent), not Claude-Code-specific.
- **Markdown heading outline**: For markdown file preview panes (if/when SlopDesk supports them), parse headings. Currently not a priority — SlopDesk is a coding/remote tool, not a document viewer.
- **Right-click context menu on outline rows**: Standard `contextMenu` SwiftUI modifier on each outline row, offering "Jump to" and "Copy".
- **Scrollback jump**: On selection, scroll the terminal's libghostty surface to the row corresponding to the selected block's scrollback offset. libghostty supports programmatic scroll positioning.
- **Truncation with ellipsis**: Rows in the sidebar are compact (~36–40px height) with ellipsis truncation for long commands/prompts, matching the visual.

### Cannot map 1:1 — caveats and gaps

- **Host-side CWD in outline rows**: A local-only design could show `~/Workspace/project` as the session path because it runs locally. In SlopDesk, the CWD comes from OSC 7 (`OSC 7 ; file://host/path`) emitted by the remote shell. The remote path is available over the wire but requires the remote shell to emit OSC 7; if it does not, the session path label will be absent or stale.
- **"Current" tab in Open Quickly across remote sessions**: When multiple remote sessions from different hosts are open, "Current" must scope to the focused pane's pane-local index (not a global command history), which is the natural behavior if the index is stored per-pane. No architectural blocker, but the per-pane index must be maintained in the client (built from the stream of OSC 133 marks received over the wire).
- **Timestamp accuracy**: Relative timestamps ("4m ago") are shown per command. These timestamps are local. In SlopDesk, the timestamp of a command's mark arriving at the client may differ from the actual shell execution time on the host by RTT. This is negligible for the UX but worth noting: use client-receive-time as the timestamp, not a host-provided clock.
- **Supported agent session detection**: The design lists "history prompts" for "supported code agent sessions." In SlopDesk, Claude Code agent sessions are auto-detected via `ClaudeStatus`/`ClaudePaneDetector`. The outline should check `PaneKind` to decide whether to show the "prompt history" view vs the plain command list view.
- **iOS client**: The Outline sidebar panel maps to a sheet or secondary panel on iOS (no persistent sidebar). The Jump To panel (⌘J) has no direct iOS keyboard shortcut equivalent — expose via a toolbar button or gesture. The compact row layout (36–40px) works on iOS but touch targets should be at least 44pt.
- **Remote SSH badge on outline rows**: Not applicable for SlopDesk (all sessions are remote by definition); no extra badge needed to distinguish local vs remote.
