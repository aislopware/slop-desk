# Composer

## Summary

The Composer is the primary input affordance for agent (code-agent) sessions in slopdesk. It is a multi-line text editor that floats at the bottom of the agent pane, providing cursor operations, undo/redo, rich paste, pinning (stay visible across tab switches), a floating Spotlight-style detached panel mode, and prompt-queue routing. It is also available in ordinary terminal panes as a GUI-quality input overlay. The key design principle is that Return alone never sends — accidental sends are impossible by design.

## Behaviors

- **Multi-line by default.** Both `↩` and `⇧↩` insert newlines; the only send gesture is `⌘↩`. A user cannot accidentally fire a half-written message.
- **Grows to a configurable max height.** Below that threshold the composer box expands as content grows; above it the content scrolls internally.
- **Send clears and closes.** `⌘↩` delivers the draft to the agent, closes the composer, and clears the draft text.
- **Cancel preserves draft.** `⎋` dismisses the composer without sending; the draft text is stashed and restored on reopen — accidental dismissal loses nothing.
- **Rich paste by default.** `⌘V` converts HTML, RTF, or clipboard images into Markdown inline. `⇧⌘V` pastes as plain text.
- **Draft persistence across tab switches.** The composer lives in its pane; switching away from that tab stashes the draft automatically. Returning restores it.
- **Pin mode.** Clicking the pin button (labeled ① in `composer.png`) keeps the composer visible across ALL tab switches — it rides along regardless of which tab is active. Pinned state is persisted as a user preference. Click again to unpin.
- **Float panel mode.** Clicking the pop-out button (labeled ② in `composer.png`) detaches the composer into a floating, Spotlight-style window that stays on top of all other app windows without activating the app or claiming the menu bar. Draft text and inline attachments move with it. Sending or closing the float docks it back into the pane.
- **Prompt Queue routing.** `⌥⌘↩` (or clicking the queue button, labeled ③ in `composer.png`) routes the draft into the pane's Prompt Queue instead of sending immediately. Each non-blank line becomes a separate queued command that auto-fires at the next idle prompt, enabling multi-step queuing while the agent is busy.
- **Available in normal terminal panes.** `⌘⇧E` (also reachable via Edit > Composer, Command Palette, or terminal context menu) opens the composer in any non-agent terminal pane, providing comfortable multi-line editing, cursor movement, and undo/redo for shell input. `⌘↩` pastes the composed text into the originating terminal line. Re-triggering `⌘⇧E` closes it.
- **Agent-generic vs Claude-Code-specific:** All behaviors above are agent-generic (described for any code agent). No behavior on this page is exclusively Claude-Code-specific, though the page is documented in the context of slopdesk's code-agent integration (OpenCode shown in the reference screenshots).

## Keybindings

| Action | Keys |
|---|---|
| Send draft (deliver + close + clear) | `⌘↩` |
| Insert newline (default Return behavior) | `↩` |
| Insert newline (explicit) | `⇧↩` |
| Cancel / dismiss (preserves draft) | `⎋` |
| Paste rich (HTML/RTF/image → Markdown) | `⌘V` |
| Paste as plain text | `⇧⌘V` |
| Add draft to Prompt Queue | `⌥⌘↩` |
| Open composer in any terminal pane / close | `⌘⇧E` |

## Config keys

No config keys are explicitly documented on this page beyond one general note:

| Key | Default | Effect |
|---|---|---|
| Composer max height | (configurable, value not specified on page) | The composer grows to this height before switching to internal scrolling |

## Visual spec

### composer.png — Composer in an agent pane

**Overall layout:**
A macOS window titled "OC | Data sync feature consideration" (traffic-light controls visible top-left: red/yellow/green dots). The window shows a split layout: the upper ~60% is the terminal/agent output area; the lower ~40% is the composer region separated by a thin horizontal rule.

**Terminal output region (upper):**
- Dark background (near-black, ~#1a1a1a or similar dark charcoal).
- Monospace text in white/light gray. Markdown-style content visible: numbered list items, bold headings (e.g. "Privacy —"), bullet lists with dash markers, and a build status line ("Build · GLM-5.1 · 4m 7s").
- A colored square badge on the left of the build line (small solid square, teal/green color indicating a build tool call).
- Text colors: white for body text, yellow/amber for bold headings, standard terminal green/teal for badges.
- A faint vertical scrollbar on the right edge.

**Status bar / info line (between output and composer):**
A single line of small metadata text in muted gray: `history.md  15.6K (8%)  ·  $0.04  ctrl+p commands`. This shows the active file, size/percentage, token cost, and a keyboard hint. Very compact, ~12px equivalent font size.

**Composer region (lower ~35% of window):**
- Same dark background as the terminal.
- Multi-line text field with no visible border/stroke — it blends into the background. Content visible: several lines of text with bullet points, continuing the draft response about "macOS-first terminal emulator" approaches.
- The text is white on dark, same monospace or near-monospace font as the terminal output.
- No placeholder text visible (content is present).

**Composer toolbar (bottom bar of the window):**
A single row of controls pinned to the very bottom, ~32px tall, slightly differentiated background (marginally lighter dark, or same dark with subtle separator line above):
- **Left cluster:** `⌘↩ Send` label in small muted text. Then `⌘↩/ Queue` (small text). Then `□ Cancel` (small text). All appear as plain text labels, not pill buttons — low visual weight.
- **Right cluster (three icon buttons, right-aligned):**
  - **① Pin button** — a pin/thumbtack icon; standard SF Symbol style, monochrome on dark background.
  - **② Pop-out/Float button** — an icon representing "open in new window" or "expand outward" (two-arrows or square-with-arrow style).
  - **③ Queue button** — an icon representing a list/queue (stacked lines or similar).
  - All three icons are the same small size (~16×16pt), spaced ~8pt apart, in a muted gray/white color without background fills.
- Number callout overlays ①②③ appear as red filled circles with white numerals (added by the documentation, not native app UI).

**Typography:** Monospace throughout (matches terminal font). Toolbar labels use a smaller sans-serif in muted gray.

**Divider:** A thin 1px horizontal rule separates the terminal output from the status bar/composer. Very subtle, near-invisible on dark background.

---

### composer-float.png — Float panel mode

**Overall context:**
A browser window showing this design's documentation site is in the background. In the foreground is the app window (partially visible, showing the composer-in-pane view, darker, slightly scaled back). In the top-right foreground is the **floating Composer panel**.

**Floating Composer panel:**
- Title bar: "SlopDesk Composer — OpenCode" in standard macOS window title bar style. Traffic-light buttons (red/yellow/green) on the left of the title bar. The window has the standard macOS floating panel appearance — no full window chrome, minimal footprint.
- **Window size:** Approximately 340×160pt. Compact, Spotlight-like proportions — wider than tall, like a command palette.
- **Content area:** Dark background matching the main app theme. Two lines of body text visible in the input area: "> The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top..." (appears as a quoted/prefilled context line in lighter/muted style), followed by "Rephrase this|" with a text cursor (blinking bar), indicating the user's active draft.
- **Bottom toolbar:** Same layout as composer.png — `⌘↩ Send`, `⌘↩/ Queue`, `□ Cancel` labels on the left; pin and pop-in icon buttons on the right (the pop-out icon would now be a "dock back" / collapse icon in float mode).
- **Positioning:** The float panel sits above and to the right of the underlying terminal window, demonstrating that it can be freely positioned over other app content. No shadow from underlying windows bleeds into it — it is a distinct system-level floating window.
- **Font/colors:** Identical dark theme to main window. Title bar text is standard macOS dark-mode title color.

**Background (docs site, for context only):**
The documentation page shows the Composer heading, a highlighted blue intro paragraph, and the composer-in-pane screenshot embedded in the page — demonstrating the documentation-in-browser + float-panel-in-use workflow.

## Screenshots

- `composer.png` — composer embedded in an agent pane, showing multi-line draft and the three toolbar buttons (Pin ①, Float ②, Queue ③)
- `composer-float.png` — floating Composer panel detached over another app (docs browser), titled "SlopDesk Composer — OpenCode"

## SlopDesk mapping notes

**Architecture context:** SlopDesk is a remote-coding tool where the macOS host runs `slopdesk-hostd` and the macOS/iOS client renders via libghostty behind a `TerminalSurface` seam. The composer is a CLIENT-side UI overlay — it does not involve the host or the wire protocol directly; composed text is injected as terminal input once sent.

### Mappings that work 1:1

- **Multi-line text field at pane bottom:** Implemented as a SwiftUI/AppKit text view overlaid at the bottom of the `TerminalRenderingView`. No host involvement needed.
- **Send via `⌘↩`:** Injects the composed text as PTY input (same as keyboard input). Maps cleanly via existing `SlopDeskTransport` input channel.
- **Cancel / `⎋`:** Pure client state. Draft stored in pane's view model.
- **Rich paste (`⌘V` → Markdown conversion):** Client-only; NSPasteboard read + conversion logic. No special host feature needed.
- **Draft persistence across tab switches:** Draft stored in the pane's `WorkspaceStore` / pane view-model. Already has per-pane state.
- **Prompt Queue routing:** Pure client-side queue; each line fires as a separate input inject at idle-prompt detection (OSC 133 shell integration already present).
- **Use in normal terminal pane (`⌘⇧E`):** Open a composer overlay for any `PaneKind` pane; inject via PTY on send.
- **Keybindings:** All map onto the existing `WorkspaceBindingRegistry` / keybinding infrastructure.

### Mappings that are non-trivial or cannot be 1:1

- **Float panel (macOS):** The design calls for a float panel via `NSPanel` with `.floating` window level that does NOT activate the app or steal the menu bar — this requires `NSPanel` with `becomesKeyOnlyIfNeeded` and `.nonactivatingPanel` style mask. On the slopdesk macOS client this is feasible but needs care: the panel must remain associated with the originating pane session so that `⌘↩` injects into the correct host's PTY. Panel identity must survive window-level changes.
- **Float panel (iOS):** iOS has no concept of floating windows above other apps. The closest equivalent is a sheet or a persistent input toolbar that survives navigation — a full floating-over-other-apps experience is NOT possible on iOS due to OS sandboxing. Recommend implementing a bottom-sheet or slide-up overlay within the slopdesk app instead, clearly scoped to the current pane.
- **"Stays on top without activating the app":** The non-activating NSPanel behavior is macOS-only and is a specific Cocoa feature. On slopdesk macOS this is achievable. On iOS there is no equivalent.
- **Pin across tab switches:** The `WorkspaceStore` / tab model needs to support a per-pane "pinned composer" flag that causes the composer view to be mounted at the window level (above the tab/pane switcher) rather than inside the pane's subtree. This is architecturally non-trivial — the composer overlay must be promoted out of the pane's SwiftUI view hierarchy.
- **Float panel title ("SlopDesk Composer — OpenCode"):** The agent name ("OpenCode" in the reference screenshot) comes from the agent integration layer. SlopDesk currently integrates Claude Code; the float panel title reads "SlopDesk Composer — Claude Code" for a Claude session. The agent name must be tracked per-pane in `WorkspaceStore`.
- **Status bar line (`history.md  15.6K (8%)  ·  $0.04  ctrl+p commands`):** The file/cost/token metadata shown in the status bar between output and composer is agent-provided context (likely via OSC sequences or a Claude Code-specific protocol). The `$0.04` cost token implies the agent reports spend over the wire. SlopDesk should surface whatever cost/context data Claude Code emits via OSC 133 or similar; if Claude Code does not emit this, the status bar can omit cost and show only session metadata.
- **Rich HTML/RTF → Markdown paste:** Requires a Markdown conversion library on the client. Feasible on macOS (NSAttributedString + custom converter). On iOS, RTF is less common but HTML paste from Safari is realistic — a lightweight HTML-to-Markdown converter (e.g. a pure Swift implementation) is needed.
- **Composer max height (configurable):** Maps to a `SettingsKey` in `PreferencesStore`. Default value not specified by docs; suggest defaulting to ~40% of pane height.
