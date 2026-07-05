# Prompt Queue

## Summary

Line up several prompts while an agent is still working. SlopDesk holds them in a queue and feeds the next one the moment the current turn finishes — no need to babysit the session.

The queue works in both agent panes (Claude Code, etc.) and normal terminal panes. For terminal panes it is analogous to shell command-chaining (`build.sh && release.sh`) but works retroactively — you can append a command after the previous one is already running.

## Behaviors

- Press `⌘⇧M` to open the queue input bar at the bottom of the focused pane.
- Type a command in the queue input bar and press `↩` to add it to the queue; repeat to stack as many as you like.
- Each queued prompt dispatches automatically at the next idle prompt — in order, as the previous command finishes. No babysitting required.
- You can also queue from the Composer: open it with `⌘⇧E`, type your draft, and press `⌥⌘↩` to enqueue it instead of sending immediately.
- `⌘↩` (plain) in the Composer sends and runs the draft immediately. `⌥⌘↩` always enqueues (never sends immediately).
- A **queue strip** appears just above the Composer when one or more prompts are pending. It is not visible when the queue is empty.
- Each pending prompt is rendered as a **chip** (a compact pill/label) in the queue strip.
- **Reorder**: drag a chip to move it to a different position in the queue.
- **Edit**: click a chip to load it back into the Composer for editing.
- **Remove**: click the `✕` button on a chip to delete it from the queue without running it.
- In normal (non-agent) terminal panes, the feature lets you append a new command after the current one ends, as an alternative to shell-native chaining (`&&`).
- This feature is classified under **Agents** in the docs navigation but the UI is present in normal terminal panes too (the "use in normal terminal view" section).

### Agent-generic vs Claude-Code-specific

- **Agent-generic**: The queue input bar (`⌘⇧M`), Composer enqueue (`⌥⌘↩`), chip management (reorder/edit/remove), and queue strip are agent-generic — they work with any supported agent.
- **Claude-Code-specific**: No Claude-Code-specific behavior is called out on this page. The dispatch trigger ("next idle prompt") maps to the agent's shell prompt appearing, which is an OSC 133 / shell-integration concept — Claude Code uses this mechanism.

## Keybindings

| Action | Keys |
|--------|------|
| Open queue input bar (in focused pane) | `⌘⇧M` |
| Add typed command to queue | `↩` (inside queue input bar) |
| Open Composer | `⌘⇧E` |
| Send prompt immediately (from Composer) | `⌘↩` |
| Enqueue prompt instead of sending (from Composer) | `⌥⌘↩` |

## Config keys

No config keys are documented on this page. The queue is always available; there is no enable/disable toggle described.

## Visual spec

### Screenshot: queue.png

**Overall layout**

The screenshot shows a macOS window with a standard title bar (traffic-light buttons top-left, title "slopdesk" centered). The window is divided into two columns by a thin vertical divider:

- **Left column — tabs/sidebar** (narrow, ~110 px wide): labeled "TABS" in small uppercase grey text at the top. Below are two rows:
  - Row 1: "OC | Explore config…" with a badge "⌘1" right-aligned in a faint monospace style.
  - Row 2: "slopdesk" (selected/active tab, shown in slightly bolder text) with badge "⌘2" right-aligned.
  The background of the sidebar is a light grey (~#F5F5F5 or similar off-white); selected row has no strong highlight visible at this zoom — it relies on text weight or a subtle underline.

- **Right column — pane content** (~550 px wide): Fills most of the window. The terminal content area shows white background with monospace text in dark (~#1A1A1A) showing a file-tree listing:

  ```
  Local source of truth remains:

  ~/.config/slopdesk/
      config.toml
      themes/
      recipes/
      fonts/    # optional

  Sync bundle:

  <chosen-sync-folder>/SlopDesk/
      manifest.json
      config/config.toml
      themes/*.toml
      recipes/*.slopdeskrecipe
      fonts/*    # optional
      tombstones.json
      devices/<device-id>.json
  ```

**Agent prompt row** (sits below the terminal scroll area, above the queue strip):

A full-width row with light grey background (#F0F0F0 approx), left-padded with a right-pointing triangle (`▶`) followed by a blinking block cursor and the text `Implement {feature}` — this represents the agent's current input line / shell prompt area. This is the "current turn" indicator showing the agent is active.

Below it, a status row showing: `gpt-5.5 xhigh · ~/Workplace/slopdesk` in small monospace text with subtle color — `gpt-5.5` in blue/teal, `xhigh` in muted text, path in grey.

**Queue strip** (the feature being documented):

A full-width strip sits between the agent status row and the Composer bar. It has a light background (same off-white as sidebar, ~#F5F7FA). It contains:

- One **chip**: a rounded-rectangle pill labeled `explain more about conflict model`. The chip has:
  - Light grey background (#E8E8E8 approx), rounded corners (~4 px radius).
  - Text in dark grey, small-to-medium size (~12–13 px), no icon prefix.
  - A `🗑` (trash/delete) icon button at the right edge of the chip, in a slightly lighter grey.
- The chip is left-aligned within the strip with comfortable horizontal padding.

**Composer / queue input bar** (bottommost row):

A single-line input field spanning the full width, with placeholder text `Add to Prompt Queue…` in muted grey italic. To the far right of this input bar are two controls:
- A `Close` text button (muted grey).
- A small circular icon button (appears to be a settings/options glyph — `⚙` or similar with a small arrow).

The bottom bar has a white or near-white background, a faint top border separating it from the queue strip above.

**Color palette observed**

- Window background / terminal area: white (#FFFFFF)
- Sidebar / strip background: light grey (#F4F4F4–#F7F7F7)
- Primary text: near-black (#1A1A1A–#2A2A2A)
- Muted labels (TABS, badge numbers, placeholder): light grey (#A0A0A0–#BBBBBB)
- Agent status accent (model name): blue/teal (~#3B82F6 or similar)
- Chip background: light grey (#E4E4E4)
- Chip delete icon: medium grey (#909090)
- No strong color accents elsewhere; the palette is minimal and neutral.

**Spacing and density**

- The queue strip is compact — approximately 36–40 px tall for a single chip row.
- The Composer/input bar is approximately 32–36 px tall.
- The agent status row is approximately 24 px tall.
- Typography is system sans-serif for UI chrome, monospace (appears to be SF Mono or similar) for terminal content and chips.
- Overall density: medium — not cramped, but not spacious. Consistent with a productivity terminal app.

**States visible in screenshot**

- Queue strip: one item queued (chip visible).
- Chip: default/resting state — no hover highlight visible.
- Chip delete icon: visible at rest (not requiring hover to appear, or hover is implied since it's a static screenshot).
- Composer bar: open, showing queue-input placeholder (`Add to Prompt Queue…`), with `Close` and settings buttons at right.
- Agent: mid-turn (prompt row present, triangle icon, model+path status line).

## Screenshots

- `queue.png`

## Implementation notes

### Direct implementation

- **Queue input bar (`⌘⇧M`)**: Maps to a pane-local overlay input bar at the bottom of the focused pane. In slopdesk, a pane corresponds to a PTY session routed through the terminal mux. The keybinding should be registered in the macOS client's `WorkspaceBindingRegistry` / `NSEvent` monitor layer (prefix or direct), opening a transient SwiftUI input field anchored to the bottom of the focused pane's `TerminalSurface`.

- **Queue strip (chip UI)**: A SwiftUI `HStack` of chip views rendered above the Composer in the pane's bottom chrome area. State lives in a `PromptQueueStore` (or similar) scoped per `PaneID`. Since slopdesk panes are not torn down (they stay mounted at opacity-0 when not focused — per memory: "mount all tabs opacity-0"), the queue state persists across tab switches.

- **Enqueue from Composer (`⌥⌘↩`)**: The Composer (`⌘⇧E`) already exists in slopdesk. Add a second submission path that appends to the `PromptQueueStore` instead of writing to the PTY immediately.

- **Auto-dispatch on idle**: The dispatch trigger is "the agent's shell prompt appears" — i.e., OSC 133 mark A/B/C/D (shell integration). SlopDesk already uses OSC 133 (`SlopDeskWorkspaceCore` / `BlockOutputView`, per memory). Wire `promptQueue.dispatchNext()` into the OSC 133 prompt-start handler, guarded by `queue.isEmpty == false`.

- **Chip reorder**: SwiftUI drag-to-reorder on a `List` or custom `DragGesture`. Works the same on macOS and iOS clients.

- **Chip edit (load back into Composer)**: Tap a chip → populate Composer text field with the chip's text → remove chip from queue. Standard state mutation.

- **Chip remove (`✕`)**: Remove the item at that index from the queue array.

### Architecture notes

- Queue state should be **client-local** — it does not need to be transmitted to the host. The host simply receives PTY writes at the moment each prompt is dispatched. No wire-protocol changes required.
- The dispatch write should go through the existing PTY write path (`SlopDeskTransport` data channel) with `TCP_NODELAY` already set, so latency is minimal.
- The "idle" detection on the macOS client is via OSC 133 prompt markers already parsed by the shell-integration layer. On iOS the same OSC 133 path applies (libghostty handles the OSC parsing behind `TerminalSurface`).

### Platform / architecture constraints

- **`gpt-5.5 xhigh` model/priority status line**: the design shows the active agent model and a priority level (`xhigh`) below the agent prompt row. SlopDesk does not yet expose agent metadata over the wire (the host-side `ClaudeStatus`/`ClaudePaneDetector` exists per memory but model name is not surfaced). This is a follow-on; the queue feature does not require it.
- **Normal terminal pane use**: In slopdesk, normal terminal panes go through the same PTY mux — the queue dispatch (write on OSC 133 idle) works identically. No special case needed.
- **Drag-to-reorder on iOS**: SwiftUI `.onMove` / `DragGesture` works on iOS but the hit targets need to be large enough for finger use. Standard SwiftUI `List` with `.onMove` is the path of least resistance.

### See also

- **Composer** — how prompts get typed in the first place (the input surface `⌘⇧E` opens).
- **Monitor Tasks** — for concurrency instead of a serial queue (parallel agent sessions).
