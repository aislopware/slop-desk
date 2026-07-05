# Prompt Queue

## Summary

Line up several prompts while an agent is still working. SlopDesk queues them and feeds the next one when the current turn finishes.

Works in both agent panes (Claude Code, etc.) and normal terminal panes. For terminal panes it is like shell command-chaining (`build.sh && release.sh`) but retroactive — you can append a command after the previous one is already running.

## Behaviors

- `⌘⇧M` opens the queue input bar at the bottom of the focused pane.
- Type a command there and press `↩` to add it; repeat to stack more.
- Queued prompts dispatch automatically at the next idle prompt, in order, as each previous command finishes.
- Queue from the Composer (`⌘⇧E`): type a draft, press `⌥⌘↩` to enqueue instead of sending.
- In the Composer, `⌘↩` sends and runs the draft immediately; `⌥⌘↩` always enqueues (never sends).
- A **queue strip** appears just above the Composer when prompts are pending; hidden when the queue is empty.
- Each pending prompt renders as a **chip** (compact pill) in the strip.
- **Reorder**: drag a chip to a new position.
- **Edit**: click a chip to load it back into the Composer.
- **Remove**: click the chip's `✕` to delete it without running.
- In non-agent terminal panes, this appends a new command after the current one ends, as an alternative to `&&`.
- Classified under **Agents** in the docs nav, but the UI is present in normal terminal panes too.

### Agent-generic vs Claude-Code-specific

- **Agent-generic**: queue input bar (`⌘⇧M`), Composer enqueue (`⌥⌘↩`), chip management (reorder/edit/remove), and queue strip work with any supported agent.
- **Claude-Code-specific**: none called out. The dispatch trigger ("next idle prompt") maps to the agent's shell prompt appearing — an OSC 133 / shell-integration concept, which Claude Code uses.

## Keybindings

| Action | Keys |
|--------|------|
| Open queue input bar (in focused pane) | `⌘⇧M` |
| Add typed command to queue | `↩` (inside queue input bar) |
| Open Composer | `⌘⇧E` |
| Send prompt immediately (from Composer) | `⌘↩` |
| Enqueue prompt instead of sending (from Composer) | `⌥⌘↩` |

## Config keys

None. The queue is always available; no enable/disable toggle.

## Visual spec

### Screenshot: queue.png

**Overall layout** — macOS window, standard title bar (traffic-lights top-left, title "slopdesk" centered), split into two columns by a thin vertical divider:

- **Left column — tabs/sidebar** (~110 px wide): "TABS" in small uppercase grey at top. Two rows:
  - Row 1: "OC | Explore config…", badge "⌘1" right-aligned, faint monospace.
  - Row 2: "slopdesk" (selected/active, slightly bolder), badge "⌘2" right-aligned.
  Background light grey (~#F5F5F5); selected row has no strong highlight — relies on text weight or subtle underline.

- **Right column — pane content** (~550 px wide): white background, dark (~#1A1A1A) monospace file-tree listing:

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

**Agent prompt row** (below the terminal scroll area, above the queue strip): full-width, light grey (~#F0F0F0), left-padded with `▶` then a blinking block cursor and text `Implement {feature}` — the agent's current input line / "current turn" indicator. Below it a status row: `gpt-5.5 xhigh · ~/Workplace/slopdesk` in small monospace — `gpt-5.5` blue/teal, `xhigh` muted, path grey.

**Queue strip** (the feature): full-width, between the agent status row and the Composer, light background (~#F5F7FA). Contains one **chip**: rounded-rectangle pill labeled `explain more about conflict model`, light grey background (~#E8E8E8), ~4 px radius, dark-grey text ~12–13 px, no icon prefix, with a `🗑` delete button at the right edge in lighter grey. Left-aligned with comfortable horizontal padding.

**Composer / queue input bar** (bottommost): single-line, full-width, placeholder `Add to Prompt Queue…` in muted grey italic. Far right: a `Close` text button (muted grey) and a small circular settings/options glyph (`⚙`-like with a small arrow). White/near-white background, faint top border.

**Color palette observed**

- Window/terminal area: white (#FFFFFF)
- Sidebar/strip background: light grey (#F4F4F4–#F7F7F7)
- Primary text: near-black (#1A1A1A–#2A2A2A)
- Muted labels (TABS, badges, placeholder): light grey (#A0A0A0–#BBBBBB)
- Agent status accent (model name): blue/teal (~#3B82F6)
- Chip background: light grey (#E4E4E4)
- Chip delete icon: medium grey (#909090)
- Otherwise minimal, neutral — no strong accents.

**Spacing and density**

- Queue strip ~36–40 px tall for a single chip row.
- Composer/input bar ~32–36 px tall.
- Agent status row ~24 px tall.
- Typography: system sans-serif for UI chrome, monospace (SF Mono-like) for terminal content and chips.
- Overall density: medium — a productivity terminal app.

**States visible in screenshot**

- Queue strip: one item queued (chip visible).
- Chip: default/resting, no hover highlight.
- Chip delete icon: visible at rest.
- Composer bar: open, queue-input placeholder (`Add to Prompt Queue…`), `Close` and settings buttons at right.
- Agent: mid-turn (prompt row, `▶`, model+path status line).

## Screenshots

- `queue.png`

## Implementation notes

### Direct implementation

- **Queue input bar (`⌘⇧M`)**: a pane-local overlay input bar at the bottom of the focused pane. A slopdesk pane = a PTY session routed through the terminal mux. Register the keybinding in the macOS client's `WorkspaceBindingRegistry` / `NSEvent` monitor layer, opening a transient SwiftUI input field anchored to the bottom of the focused pane's `TerminalSurface`.
- **Queue strip (chip UI)**: a SwiftUI `HStack` of chip views above the Composer in the pane's bottom chrome. State in a `PromptQueueStore` scoped per `PaneID`. Panes stay mounted at opacity-0 when unfocused (per memory), so queue state persists across tab switches.
- **Enqueue from Composer (`⌥⌘↩`)**: the Composer (`⌘⇧E`) exists already. Add a second submission path that appends to `PromptQueueStore` instead of writing to the PTY immediately.
- **Auto-dispatch on idle**: trigger is the agent's shell prompt appearing — OSC 133 mark A/B/C/D. SlopDesk already uses OSC 133 (`SlopDeskWorkspaceCore` / `BlockOutputView`). Wire `promptQueue.dispatchNext()` into the OSC 133 prompt-start handler, guarded by `queue.isEmpty == false`.
- **Chip reorder**: SwiftUI drag-to-reorder (`List` or custom `DragGesture`), same on macOS and iOS.
- **Chip edit**: tap a chip → populate Composer text field → remove chip from queue.
- **Chip remove (`✕`)**: remove the item at that index from the queue array.

### Architecture notes

- Queue state is **client-local** — not transmitted to the host, which just receives PTY writes when each prompt dispatches. No wire-protocol changes.
- Dispatch writes go through the existing PTY write path (`SlopDeskTransport` data channel) with `TCP_NODELAY` set, so latency is minimal.
- "Idle" detection uses OSC 133 prompt markers already parsed by the shell-integration layer. Same path on iOS (libghostty parses OSC behind `TerminalSurface`).

### Platform / architecture constraints

- **`gpt-5.5 xhigh` status line**: shows active model + priority below the agent prompt row. SlopDesk does not yet expose agent metadata over the wire (host-side `ClaudeStatus`/`ClaudePaneDetector` exists but model name is not surfaced). Follow-on; the queue feature does not require it.
- **Normal terminal pane use**: same PTY mux, so queue dispatch (write on OSC 133 idle) works identically. No special case.
- **Drag-to-reorder on iOS**: SwiftUI `.onMove` / `DragGesture` works, but hit targets must be finger-sized. `List` with `.onMove` is the path of least resistance.

### See also

- **Composer** — how prompts get typed (the input surface `⌘⇧E` opens).
- **Monitor Tasks** — for concurrency instead of a serial queue (parallel agent sessions).
