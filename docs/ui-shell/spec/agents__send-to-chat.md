# Send to Chat

## Summary

Pull terminal output, file-pane selections, or shell context straight into an agent conversation — without copy-pasting. "Send to Chat" attaches the source as context to the active (or a new) agent session.

The feature surfaces as:
1. A right-click context menu item "Send to Chat" in any terminal or file pane.
2. A keyboard shortcut `⌘⌃↩` from any focused pane.
3. A "Send to Chat" dialog (modal sheet) that appears after invoking the action.

## Behaviors

- **Source capture — text selection:** If text is selected in a terminal or file pane, that selection is captured as the context payload.
- **Source capture — last output (focus-only):** If no text is selected but the pane has focus, "last output" (the last command's output from shell integration) is used instead.
- **Source capture — file pane selection:** If items are selected in a file pane (folder/file browser), those selections become the context.
- **Invocation:** Right-click → "Send to Chat" context menu item, or press `⌘⌃↩` while the pane is focused.
- **Dialog presentation:** A centered modal dialog appears over the workspace, titled with the source location (e.g., `composer.md L3` — filename and line number). The dialog is NOT a floating panel; it is a sheet-style overlay with a white/light background and a rounded rectangle card, dimming the content behind it.
- **Dialog content — quoted context chip:** The top region of the dialog shows a read-only quoted preview of the captured text (a scrollable text box, shown verbatim, not editable).
- **Dialog field — "Send to":** A labeled dropdown/picker row showing the target agent session. The label reads "Send to:" on the left and a selector control on the right showing the current session name and its agent model badge (e.g., "OC | Writing composer docs   OpenCode"). When no session is open, a "New session" option is provided. When multiple sessions are running, a small picker lets the user choose.
- **Last-used session is the default:** The previously chosen session is pre-selected when the dialog opens.
- **Dialog field — "Comment:":** A free-text input field below "Send to" where the user types their question or comment to accompany the context. This field is focused and active when the dialog opens. It starts empty.
- **Dialog actions:** Three buttons at the bottom:
  - **"Copy Message"** (left-aligned, secondary/text button) — copies the context to clipboard without sending.
  - **"Cancel"** (right-side, secondary button) — dismisses the dialog without sending.
  - **"Send"** (right-side, primary blue button) — attaches the context chip to the target agent session's composer and sends (or queues).
- **Context delivery:** After Send, the content lands as a quoted context chip above the composer in the target agent session. The user reviews it, adds their question, and sends.
- **Session routing — no session open:** If no agent session is open, "Send to Chat" starts one automatically.
- **Session routing — multiple sessions:** A small picker within the "Send to" field lets the user choose which session receives the context.
- **Automatic tab switch:** After sending, the workspace switches to the target agent session tab (the final frame shows the agent session pane is now focused and the message appears in the agent's conversation).
- **Agent session result:** The agent session shows a "writing docs" message header, a "Thought: 264ms" reasoning indicator in amber/orange text, a prose response, and a tool-call line (`Build · GLM-5.1 · interrupted`). At the bottom of the agent pane the sent message appears as a quoted block (`/Users/abner/Workplace/slopdesk/docs/user/agents/composer.md#L3` followed by the quoted text, then the comment "rephrase it"). A status bar at the bottom shows `Build · GLM-5.1  OpenCode  Go` plus `tab agents  ctrl+p commands` hints.

## Keybindings

| Action | Keys |
|--------|------|
| Send to Chat (invoke from any focused pane) | `⌘⌃↩` (Command + Control + Return) |

## Config keys

No dedicated config keys are documented on this page. The feature relies on shell integration (see `/agents/setup`) to provide "last command output" as the context source when no text is selected.

## Visual spec

### Frame 00 — Initial state: file pane + editor pane (before selection)

The workspace shows a two-pane layout. Left sidebar: a narrow file tree panel (~180px wide) with a dark gray background (#1e1e1e or similar), headed by a "TABS" section label. Two file rows are listed: `CREDITS.md` and `composer.md`. Below those, a session row labeled `OC | Writing composer docs` with a small "4h" badge. The sidebar has a very thin right-border divider. The right pane (main content area): a markdown/document viewer with a white (#ffffff) background, macOS window chrome at top (traffic light buttons top-left, window title "composer.md" centered in the title bar, and a top-right Close button labeled "✓ Saved  ✕ Close"). Content shows the "Composer" heading in large bold text, followed by body paragraphs in a readable serif/sans-serif. The cursor (arrow pointer) is visible in the main content area.

### Frame 01 — Cursor positioned, no selection yet

Identical layout to Frame 00. The window title bar shows a small toggle switch (blue/enabled), a chat bubble icon, and a share-like icon in the toolbar area just below the window title. The `composer.md` file entry in the left sidebar is selected/highlighted (slightly lighter row). No text selected in the main pane yet.

### Frame 02 — Text selected in document pane

Same two-pane layout. In the main content area, the first paragraph of the document is highlighted/selected with a blue selection highlight: "The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top..." The selection spans two lines and is shown in a standard macOS blue selection color (#3478F6 or similar, slightly transparent overlay). The left sidebar's `composer.md` row remains highlighted as the active file.

### Frame 03 — "Send to Chat" dialog open

A centered modal dialog overlays the workspace. The workspace content behind is slightly dimmed. The dialog card has a white background, rounded corners (~8–10px radius), and a drop shadow. Dialog anatomy (top to bottom):

- **Title row:** `composer.md L3` — plain text, medium-weight, dark, left-aligned. No icon.
- **Quoted context preview:** A read-only scrollable text box showing the captured text in a monospaced or slightly smaller font, slightly inset, with a light gray background. The text shown: "The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top..."
- **"Send to:" row:** Label "Send to:" left, a dropdown/segmented selector right. The selector displays: "OC | Writing composer docs   OpenCode" — left part is the session name "OC | Writing composer docs", right part is a small badge label "OpenCode" in a pill/capsule shape (light gray or tinted background). A chevron-down or similar affordance may be present for dropdown.
- **"Comment:" row:** Label "Comment:" left, below which is a multi-line plain text input field. It has a light border or inset appearance. The text cursor is blinking in this field. In frame 03, partial input "rep" is typed (beginning of "rephrase it").
- **Bottom button row:** Three buttons aligned bottom:
  - Left: "Copy Message" — text-only or lightly styled secondary button (no fill, dark text).
  - Right pair: "Cancel" (no fill, dark text) and "Send" (filled blue background, white text, rounded pill shape, approximately the same height as Cancel).

### Frame 04 — Comment field filled

Same dialog as Frame 03, but the Comment field now reads "rephrase it" (fully typed). The "Send" button remains blue and active. Layout and styling unchanged.

### Frame 05 — Result: agent session after send

The workspace has switched to the agent session tab. The window title now reads "OC | Writing composer docs". The left sidebar shows three rows: `CREDITS.md`, `composer.md`, and `OC | Writing composer docs` (the last one is now highlighted/selected as the active tab, with a "4h" age badge visible). The main content pane shows a dark-background agent session view:

- **Message input header:** "writing docs" in white/light text at the top of the conversation area.
- **Thought indicator:** "Thought: 264ms" in amber/orange text (#F5A623 or similar), italicized or regular weight, indicating reasoning duration.
- **Agent prose response:** A paragraph of gray text below the thought indicator describing what the agent understood and plans to do.
- **Tool call line:** "■ Build · GLM-5.1 · interrupted" — a filled square icon (■) in orange/amber, followed by "Build · GLM-5.1 · interrupted" in muted text.
- **Quoted context block (bottom of conversation):** A file reference line `/Users/abner/Workplace/slopdesk/docs/user/agents/composer.md#L3` followed by the quoted captured text starting with "> The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top…" and below that the user's comment "rephrase it" in plain text.
- **Build status line:** "Build · GLM-5.1  OpenCode  Go" in muted text at the very bottom.
- **Status bar hints:** "tab agents  ctrl+p commands" — right-aligned small text in a bottom bar.
- **Color palette for agent pane:** Dark background (#1a1a1a or #1e1e1e), white/light text for user messages, amber for thought/tool indicators, muted gray for agent prose.

## Screenshots

- `send-to-chat-frame-00.png` — initial state, two-pane workspace, no selection
- `send-to-chat-frame-01.png` — cursor positioned in main content area
- `send-to-chat-frame-02.png` — text selected in document pane (blue highlight)
- `send-to-chat-frame-03.png` — Send to Chat dialog open, partial comment typed ("rep")
- `send-to-chat-frame-04.png` — Send to Chat dialog with full comment ("rephrase it")
- `send-to-chat-frame-05.png` — result: agent session after send, showing quoted context + agent response
- `send-to-chat.mp4` — source video (11.9s, 2096×1328px @2x)

## Implementation notes

### Architecture context
SlopDesk has a macOS host running the PTY/process, and macOS/iOS clients that render the UI via libghostty behind `TerminalSurface`. Panes are `PaneKind` types managed by `WorkspaceStore`. Agent sessions would be `PaneKind.remoteGUI` (or a new `.agentSession` kind). The currently supported agent is Claude Code only (initially).

### Direct implementation
- **Keyboard shortcut `⌘⌃↩`**: can be registered via `WorkspaceBindingRegistry` as a pane-level action. Fires from any focused terminal or file pane.
- **Right-click context menu "Send to Chat"**: can be added to `NSMenu` for the terminal surface view. The text selection payload is already available via libghostty's selection API.
- **Modal dialog**: maps straightforwardly to a `NSPanel` or SwiftUI `.sheet` overlay. The fields (quoted preview, Send to picker, Comment text field, Copy/Cancel/Send buttons) are all standard controls.
- **Session picker dropdown**: maps to the list of open `PaneKind.remoteGUI` panes whose session is an agent session. The "last-used" default is stored in a preferences key.
- **Copy Message action**: copies the context text (selection) to the pasteboard.
- **Context chip delivery**: the context text is sent as a message prefix or special OSC sequence to the agent session's input (Claude Code's composer accepts pasted/piped text).

### Platform / architecture constraints
- **"Last output" fallback (no selection, focus-only)**: requires shell integration (OSC 133 FTCS markers) on the host PTY to know the bounds of the last command's output. SlopDesk already has OSC-133 support (`Blocks/OSC-133` in WorkspaceStore). This CAN be mapped but requires reading the replay buffer or terminal scroll-back up to the last OSC 133 C/D boundary.
- **File pane selections**: SlopDesk does not currently expose a file-browser pane (no `PaneKind.fileTree` equivalent in the shipped UI). This source type cannot be mapped until a file browser pane exists.
- **"OC | Writing composer docs" session name format**: sessions are displayed as `<agent-prefix> | <session-description>`. For Claude Code, the session name would be derived from the working-directory name and the running command (e.g., `CC | my-project`). The description part would need to come from the Claude Code session title (OSC 2 window title or agent-control NDJSON).
- **Agent model badge (e.g., "OpenCode", "GLM-5.1")**: SlopDesk initially supports Claude Code only; the badge would show "Claude Code" or the model from `ClaudeStatus`. Multi-model badges are future work.
- **Automatic tab switch to agent session**: requires `WorkspaceStore.activePaneID` to be updated to the target agent pane after send. Currently no explicit "focus this pane" API is wired through the UI bindings layer — needs a `WorkspaceStore.focusPane(_:)` call triggered from the send action.
- **Thought/reasoning indicator ("Thought: 264ms")**: this is an agent-session-pane feature, not part of Send to Chat itself. Relevant for the agent pane spec, not this page.
- **Dark agent pane background**: the current Monokai Pro theme gives dark terminal backgrounds; the agent response view background matches the theme's `bg` token, not a hard-coded dark. The quoted context block rendering (with the file path prefix) needs a special OSC or block-output rendering in `BlockOutputView`.

### Claude Code specific notes
- The "Send to Chat" comment becomes the user turn in Claude Code's conversation. The quoted context (file content or terminal output) is prepended as a `<context>` block or pasted as the initial message text before the user comment.
- The `⌘⌃↩` shortcut is safe to bind globally in slopdesk as it does not conflict with any known Claude Code / macOS system binding.
- The "last command output" source requires OSC 133 D (command end) markers from the shell, which the slopdesk shell integration script already emits.
