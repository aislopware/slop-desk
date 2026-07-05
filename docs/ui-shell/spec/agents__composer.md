# Composer

## Summary

The primary input affordance for agent (code-agent) sessions in slopdesk: a multi-line text editor floating at the bottom of the agent pane, with cursor operations, undo/redo, rich paste, pinning (stay visible across tab switches), a floating Spotlight-style detached panel mode, and prompt-queue routing. Also available in ordinary terminal panes as a GUI-quality input overlay. Core principle: Return alone never sends — accidental sends are impossible by design.

## Behaviors

- **Multi-line by default.** Both `↩` and `⇧↩` insert newlines; the only send gesture is `⌘↩`, so a half-written message can't fire accidentally.
- **Grows to a configurable max height,** then scrolls internally above that threshold.
- **Send clears and closes.** `⌘↩` delivers the draft to the agent, closes the composer, and clears the draft.
- **Cancel preserves draft.** `⎋` dismisses without sending; the draft is stashed and restored on reopen.
- **Rich paste by default.** `⌘V` converts HTML, RTF, or clipboard images into Markdown inline. `⇧⌘V` pastes plain text.
- **Draft persistence across tab switches.** The composer lives in its pane; switching away stashes the draft automatically, returning restores it.
- **Pin mode.** The pin button (① in `composer.png`) keeps the composer visible across ALL tab switches — it rides along regardless of active tab. Pinned state is persisted as a user preference; click again to unpin.
- **Float panel mode.** The pop-out button (② in `composer.png`) detaches the composer into a floating, Spotlight-style window that stays on top of all app windows without activating the app or claiming the menu bar. Draft text and inline attachments move with it. Sending or closing docks it back into the pane.
- **Prompt Queue routing.** `⌥⌘↩` (or the queue button, ③ in `composer.png`) routes the draft into the pane's Prompt Queue instead of sending immediately. Each non-blank line becomes a separate queued command that auto-fires at the next idle prompt — multi-step queuing while the agent is busy.
- **Available in normal terminal panes.** `⌘⇧E` (also via Edit > Composer, Command Palette, or terminal context menu) opens the composer in any non-agent terminal pane for multi-line editing, cursor movement, and undo/redo of shell input. `⌘↩` pastes the composed text into the originating terminal line. Re-triggering `⌘⇧E` closes it.
- **Agent-generic vs Claude-Code-specific:** All behaviors above are agent-generic. Nothing here is exclusively Claude-Code-specific, though the page is documented in the context of slopdesk's code-agent integration (OpenCode shown in the reference screenshots).

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

| Key | Default | Effect |
|---|---|---|
| Composer max height | (configurable, value not specified on page) | The composer grows to this height before switching to internal scrolling |

## Visual spec

### composer.png — Composer in an agent pane

**Overall layout:** macOS window titled "OC | Data sync feature consideration" (traffic-light controls top-left). Split layout: upper ~60% terminal/agent output, lower ~40% composer, separated by a thin horizontal rule.

**Terminal output region (upper):**
- Dark background (near-black, ~#1a1a1a charcoal).
- Monospace white/light-gray text. Markdown content: numbered lists, bold headings (e.g. "Privacy —"), dash bullets, a build status line ("Build · GLM-5.1 · 4m 7s").
- Small solid teal/green square badge left of the build line (build tool call).
- Text colors: white body, yellow/amber bold headings, terminal green/teal badges.
- Faint vertical scrollbar on the right edge.

**Status bar / info line (between output and composer):** One line of muted-gray metadata, ~12px: `history.md  15.6K (8%)  ·  $0.04  ctrl+p commands` — active file, size/percentage, token cost, keyboard hint.

**Composer region (lower ~35%):**
- Same dark background as terminal.
- Multi-line text field, no visible border — blends into background. Content: several bullet-point lines continuing the draft about "macOS-first terminal emulator" approaches.
- White on dark, same monospace/near-monospace font as output. No placeholder (content present).

**Composer toolbar (bottom bar, ~32px tall, slightly differentiated background with subtle separator above):**
- **Left cluster:** `⌘↩ Send`, `⌘↩/ Queue`, `□ Cancel` — plain muted text labels, not pill buttons, low visual weight.
- **Right cluster (three right-aligned icon buttons, same ~16×16pt size, ~8pt apart, muted gray/white, no fills):**
  - **① Pin** — pin/thumbtack SF Symbol, monochrome.
  - **② Pop-out/Float** — "open in new window" / expand-outward icon (two-arrows or square-with-arrow).
  - **③ Queue** — list/queue icon (stacked lines).
- Red-filled-circle numeral callouts overlay ①②③ (added by the docs, not native UI).

**Typography:** Monospace throughout (matches terminal). Toolbar labels use smaller muted-gray sans-serif.

**Divider:** Thin 1px horizontal rule separating output from status bar/composer; very subtle on dark.

---

### composer-float.png — Float panel mode

**Overall context:** Background = a browser showing this design's docs site. Foreground = the app window (partially visible, darker, scaled back) plus the **floating Composer panel** top-right.

**Floating Composer panel:**
- Title bar: "SlopDesk Composer — OpenCode", standard macOS title-bar style with traffic-light buttons left. Standard macOS floating-panel appearance — minimal chrome/footprint.
- **Window size:** ~340×160pt. Compact, Spotlight-like (wider than tall, command-palette proportions).
- **Content area:** Dark background matching app theme. Two body lines: a muted quoted/prefilled context line ("> The composer is the input affordance for agent sessions — multi-line, cursor operations, undo / redo, float on top...") followed by the active draft "Rephrase this|" with a blinking text cursor.
- **Bottom toolbar:** Same as composer.png — `⌘↩ Send`, `⌘↩/ Queue`, `□ Cancel` left; pin and pop-in icons right (pop-out icon becomes a "dock back"/collapse icon in float mode).
- **Positioning:** Sits above and right of the underlying terminal window, freely positioned over other app content. No shadow bleed — a distinct system-level floating window.
- **Font/colors:** Identical dark theme; title-bar text is standard macOS dark-mode title color.

**Background (docs site, context only):** The docs page shows the Composer heading, a highlighted blue intro paragraph, and the composer-in-pane screenshot embedded — demonstrating the docs-in-browser + float-panel-in-use workflow.

## Screenshots

- `composer.png` — composer embedded in an agent pane, showing multi-line draft and the three toolbar buttons (Pin ①, Float ②, Queue ③)
- `composer-float.png` — floating Composer panel detached over another app (docs browser), titled "SlopDesk Composer — OpenCode"

## SlopDesk mapping notes

**Architecture context:** SlopDesk is a remote-coding tool where the macOS host runs `slopdesk-hostd` and the macOS/iOS client renders via libghostty behind a `TerminalSurface` seam. The composer is a CLIENT-side UI overlay — it does not touch the host or wire protocol directly; composed text is injected as terminal input once sent.

### Mappings that work 1:1

- **Multi-line text field at pane bottom:** SwiftUI/AppKit text view overlaid at the bottom of `TerminalRenderingView`. No host involvement.
- **Send via `⌘↩`:** Injects composed text as PTY input (like keyboard input), via the existing `SlopDeskTransport` input channel.
- **Cancel / `⎋`:** Pure client state; draft stored in the pane's view model.
- **Rich paste (`⌘V` → Markdown):** Client-only NSPasteboard read + conversion. No host feature needed.
- **Draft persistence across tab switches:** Draft in the pane's `WorkspaceStore` / view-model, which already holds per-pane state.
- **Prompt Queue routing:** Pure client-side queue; each line injects separately at idle-prompt detection (OSC 133 shell integration already present).
- **Use in normal terminal pane (`⌘⇧E`):** Composer overlay for any `PaneKind` pane; inject via PTY on send.
- **Keybindings:** All map onto the existing `WorkspaceBindingRegistry` / keybinding infrastructure.

### Mappings that are non-trivial or cannot be 1:1

- **Float panel (macOS):** Needs an `NSPanel` at `.floating` level that does NOT activate the app or steal the menu bar → `NSPanel` with `becomesKeyOnlyIfNeeded` and `.nonactivatingPanel` style mask. Feasible on the macOS client, but the panel must stay associated with the originating pane session so `⌘↩` injects into the correct host's PTY; panel identity must survive window-level changes.
- **Float panel (iOS):** iOS has no floating windows over other apps (OS sandboxing). Closest equivalent is a sheet or persistent input toolbar surviving navigation — recommend a bottom-sheet or slide-up overlay within the slopdesk app, scoped to the current pane.
- **"Stays on top without activating the app":** Non-activating NSPanel is a macOS-only Cocoa feature; achievable on macOS, no iOS equivalent.
- **Pin across tab switches:** `WorkspaceStore` / tab model needs a per-pane "pinned composer" flag that mounts the composer view at window level (above the tab/pane switcher) rather than inside the pane subtree — architecturally non-trivial, as the overlay must be promoted out of the pane's SwiftUI hierarchy.
- **Float panel title ("SlopDesk Composer — OpenCode"):** Agent name comes from the agent integration layer. SlopDesk currently integrates Claude Code, so a Claude session's title reads "SlopDesk Composer — Claude Code". Agent name must be tracked per-pane in `WorkspaceStore`.
- **Status bar line (`history.md  15.6K (8%)  ·  $0.04  ctrl+p commands`):** Agent-provided context (likely via OSC sequences or a Claude Code-specific protocol); the `$0.04` cost token implies the agent reports spend over the wire. Surface whatever cost/context data Claude Code emits via OSC 133 or similar; if it emits none, omit cost and show only session metadata.
- **Rich HTML/RTF → Markdown paste:** Needs a client Markdown converter. Feasible on macOS (NSAttributedString + custom converter). On iOS, RTF is rare but Safari HTML paste is realistic — needs a lightweight pure-Swift HTML-to-Markdown converter.
- **Composer max height (configurable):** Maps to a `SettingsKey` in `PreferencesStore`. Default unspecified by docs; suggest ~40% of pane height.
