# Send to Chat

## Summary

Pull terminal output, file-pane selections, or shell context into an agent conversation without copy-pasting. "Send to Chat" attaches the source as context to the active (or a new) agent session.

Surfaces as:
1. Right-click context-menu item "Send to Chat" in any terminal or file pane.
2. Keyboard shortcut `⌘⌃↩` from any focused pane.
3. A "Send to Chat" modal sheet shown after invoking the action.

## Behaviors

- **Source capture (priority):** selected text in a terminal/file pane → captured as the payload; else, if the pane has focus, "last output" (last command's output via shell integration); file-pane item selections become the context.
- **Invocation:** right-click → "Send to Chat", or `⌘⌃↩` while the pane is focused.
- **Dialog presentation:** a centered sheet-style modal overlay (not a floating panel) over the workspace — white/light background, rounded-rectangle card, dims content behind. Titled with the source location (e.g., `composer.md L3` — filename and line number).
- **Quoted context chip:** top region shows a read-only, verbatim, scrollable preview of the captured text (not editable).
- **"Send to:" field:** labeled row; label left, selector right showing the current session name + agent model badge (e.g., "OC | Writing composer docs   OpenCode"). Defaults to the last-used session. "New session" option when none is open; a picker when multiple sessions run.
- **"Comment:" field:** free-text input below "Send to" for the user's question/comment; focused and empty when the dialog opens.
- **Actions (bottom row):**
  - **"Copy Message"** (left, secondary) — copies context to clipboard without sending.
  - **"Cancel"** (right, secondary) — dismisses without sending.
  - **"Send"** (right, primary blue) — attaches the context chip to the target session's composer and sends (or queues).
- **Context delivery:** after Send, content lands as a quoted context chip above the composer in the target session; the user reviews, adds their question, sends.
- **Session routing:** no session open → one starts automatically. Multiple sessions → the "Send to" picker selects the target.
- **Automatic tab switch:** after sending, the workspace switches to the target agent session tab (now focused, message visible in the conversation).
- **Agent session result:** shows a "writing docs" message header, a "Thought: 264ms" reasoning indicator (amber/orange), a prose response, and a tool-call line (`Build · GLM-5.1 · interrupted`). At the pane bottom the sent message appears as a quoted block (`/Users/abner/Workplace/slopdesk/docs/user/agents/composer.md#L3` + quoted text + comment "rephrase it"). A status bar shows `Build · GLM-5.1  OpenCode  Go` plus `tab agents  ctrl+p commands` hints.

## Keybindings

| Action | Keys |
|--------|------|
| Send to Chat (invoke from any focused pane) | `⌘⌃↩` (Command + Control + Return) |

## Config keys

None on this page. The feature relies on shell integration (see `/agents/setup`) to provide "last command output" as the context source when no text is selected.

## Visual spec

### Frame 00 — Initial state: file pane + editor pane (before selection)

Two-pane layout. Left sidebar: narrow file-tree panel (~180px), dark gray background (#1e1e1e or similar), "TABS" section label. File rows `CREDITS.md` and `composer.md`; below, a session row `OC | Writing composer docs` with a "4h" badge; a thin right-border divider. Right pane: markdown/document viewer, white (#ffffff) background, macOS window chrome at top (traffic lights top-left, title "composer.md" centered, top-right "✓ Saved  ✕ Close"). Content shows the "Composer" heading (large bold) + body paragraphs. Arrow pointer visible in the content area.

### Frame 01 — Cursor positioned, no selection yet

Same as Frame 00. Title bar shows a small toggle (blue/enabled), a chat-bubble icon, and a share-like icon in the toolbar below the title. The `composer.md` sidebar row is selected/highlighted. No text selected yet.

### Frame 02 — Text selected in document pane

Same layout. First paragraph selected with a blue highlight (#3478F6 or similar, slightly transparent), spanning two lines: "The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top..." Sidebar `composer.md` row stays highlighted as active.

### Frame 03 — "Send to Chat" dialog open

Centered modal over the (dimmed) workspace. White card, rounded corners (~8–10px), drop shadow. Anatomy (top→bottom):

- **Title row:** `composer.md L3` — plain, medium-weight, dark, left-aligned, no icon.
- **Quoted context preview:** read-only scrollable box, monospaced/smaller font, inset, light gray background. Text: "The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top..."
- **"Send to:" row:** label left; selector right showing "OC | Writing composer docs   OpenCode" — session name + a small "OpenCode" pill badge (light gray/tinted); possible chevron-down affordance.
- **"Comment:" row:** label left; multi-line plain text input below with light border/inset; text cursor blinking; partial input "rep" typed.
- **Bottom button row:** left "Copy Message" (text/secondary, no fill, dark text); right pair "Cancel" (no fill, dark text) and "Send" (filled blue, white text, rounded pill, ~same height as Cancel).

### Frame 04 — Comment field filled

Same as Frame 03; Comment now reads "rephrase it" (fully typed). "Send" stays blue/active. Layout/styling unchanged.

### Frame 05 — Result: agent session after send

Workspace switched to the agent session tab; window title "OC | Writing composer docs". Sidebar shows `CREDITS.md`, `composer.md`, and `OC | Writing composer docs` (last one highlighted/active, "4h" age badge). Main pane is a dark-background agent session view:

- **Message input header:** "writing docs" in white/light text.
- **Thought indicator:** "Thought: 264ms" in amber/orange (#F5A623 or similar).
- **Agent prose response:** gray-text paragraph describing what the agent understood/plans.
- **Tool call line:** "■ Build · GLM-5.1 · interrupted" — filled square (■) orange/amber + muted text.
- **Quoted context block (bottom):** file reference `/Users/abner/Workplace/slopdesk/docs/user/agents/composer.md#L3`, then quoted text "> The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top…", then user comment "rephrase it" in plain text.
- **Build status line:** "Build · GLM-5.1  OpenCode  Go" (muted, very bottom).
- **Status bar hints:** "tab agents  ctrl+p commands" — right-aligned small text.
- **Palette:** dark background (#1a1a1a or #1e1e1e), white/light user text, amber for thought/tool indicators, muted gray for agent prose.

## Screenshots

- `send-to-chat-frame-00.png` — initial state, two-pane workspace, no selection
- `send-to-chat-frame-01.png` — cursor positioned in main content area
- `send-to-chat-frame-02.png` — text selected in document pane (blue highlight)
- `send-to-chat-frame-03.png` — dialog open, partial comment ("rep")
- `send-to-chat-frame-04.png` — dialog with full comment ("rephrase it")
- `send-to-chat-frame-05.png` — result: agent session after send, quoted context + agent response
- `send-to-chat.mp4` — source video (11.9s, 2096×1328px @2x)

## Implementation notes

### Architecture context
SlopDesk has a macOS host running the PTY/process; macOS/iOS clients render the UI via libghostty behind `TerminalSurface`. Panes are `PaneKind` types managed by `WorkspaceStore`. Agent sessions would be `PaneKind.remoteGUI` (or a new `.agentSession` kind). Supported agent: Claude Code only (initially).

### Direct implementation
- **`⌘⌃↩`:** register via `WorkspaceBindingRegistry` as a pane-level action; fires from any focused terminal/file pane.
- **Right-click "Send to Chat":** add to the terminal surface view's `NSMenu`; text-selection payload is available via libghostty's selection API.
- **Modal dialog:** maps to `NSPanel` or SwiftUI `.sheet`; all fields (quoted preview, picker, Comment field, Copy/Cancel/Send) are standard controls.
- **Session picker:** the list of open `PaneKind.remoteGUI` panes whose session is an agent session; "last-used" default stored in a preferences key.
- **Copy Message:** copies the context selection to the pasteboard.
- **Context chip delivery:** context text sent as a message prefix or special OSC sequence to the agent session's input (Claude Code's composer accepts pasted/piped text).

### Platform / architecture constraints
- **"Last output" fallback (no selection, focus-only):** requires shell integration (OSC 133 FTCS markers) on the host PTY to bound the last command's output. SlopDesk already has OSC-133 support (`Blocks/OSC-133` in `WorkspaceStore`); mappable, but requires reading the replay buffer or scroll-back up to the last OSC 133 C/D boundary.
- **File pane selections:** SlopDesk ships no file-browser pane (no `PaneKind.fileTree`); this source can't be mapped until one exists.
- **"OC | Writing composer docs" name format:** sessions display as `<agent-prefix> | <session-description>`. For Claude Code, the name derives from working-directory name + running command (e.g., `CC | my-project`); the description would come from the Claude Code session title (OSC 2 window title or agent-control NDJSON).
- **Agent model badge ("OpenCode", "GLM-5.1"):** Claude Code only initially, so the badge shows "Claude Code" or the model from `ClaudeStatus`. Multi-model badges are future work.
- **Automatic tab switch:** requires `WorkspaceStore.activePaneID` updated to the target agent pane after send. No "focus this pane" API is wired through the UI bindings layer — needs a `WorkspaceStore.focusPane(_:)` call from the send action.
- **Thought indicator ("Thought: 264ms"):** an agent-session-pane feature, not part of Send to Chat; belongs to the agent pane spec.
- **Dark agent pane background:** the agent response view background matches the current Monokai Pro theme's `bg` token, not a hard-coded dark. The quoted context block (file-path prefix) needs special OSC or block-output rendering in `BlockOutputView`.

### Claude Code specific notes
- The comment becomes the user turn in Claude Code's conversation; the quoted context (file content or terminal output) is prepended as a `<context>` block or pasted as the initial message text before the comment.
- `⌘⌃↩` is safe to bind globally — no known Claude Code / macOS conflict.
- The "last command output" source requires OSC 133 D (command-end) markers, which the slopdesk shell integration script already emits.
