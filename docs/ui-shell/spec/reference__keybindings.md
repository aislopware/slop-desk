# Keybindings Reference

## Summary

Default key map shipped with SlopDesk's terminal client. Every action is re-bindable via Settings → Key Bindings GUI or `~/.config/slopdesk/config.toml`. Many actions exist that ship without a default binding (unbound). The page documents all default bindings grouped by category, plus the notation legend and a "See also" pointer to the customization guide for rebinding.

Notation: ⌘ = Command, ⌃ = Control, ⌥ = Option, ⇧ = Shift, ↩ = Return, ⌫ = Delete, ⌦ = Forward Delete.

## Behaviors

- All keybindings are re-bindable; there is no hard-coded set — any action can be unbound or rebound via GUI or config.
- The Settings → Key Bindings GUI organizes actions into categories (General, Tabs, Pane, etc.) and shows current chords as chips; dashes indicate unbound actions.
- Search in the Key Bindings panel filters by action name or chord string (e.g. typing `cmd+t` reveals what uses that combination).
- Rebinding: click a row, press the desired key combination; conflict detection alerts on collision.
- Unbinding a key: press Backspace while editing a binding; Esc cancels.
- "Reset to Default" button appears after any binding change, clearing all customizations after confirmation.
- Custom bindings can send literal text (`text:` prefix), CSI sequences (`csi:` prefix), or ESC payloads (`esc:` prefix) — not just named actions.
- Multi-key chord sequences (prefix chords) use `>` in config: e.g. `cmd+b>cmd+v`.
- Tab jump bindings ⌘1…⌘9 go to the Nth tab by position.
- ⌘⇧U surfaces the next tab with unread activity.
- Pane focus commands (⌃⌘↑/↓/←/→) are directional — they move focus to the adjacent pane in the given direction.
- Divider move commands (⌃⌘⇧↑/↓/←/→) resize panes by moving the shared divider.
- Zoom/unzoom (⌘⇧↩) toggles a single pane to fill the tab; pressing again restores the split layout.
- Equalize splits (⌃⌘=) distributes all panes in the current tab equally.
- Text-editing bindings (⌘←/→, ⌥←/→, ⌥⌫, ⌥⌦, ⌘⌫, ⌘⌦) send readline-compatible byte sequences to the focused terminal — they are client-side interceptions, not OS text field actions.
- Rectangular selection is triggered by holding ⌥ while dragging.
- Double-click selects a word; triple-click selects the full line.
- Scroll half-page (⌃U / ⌃D) is only active while in Vi Mode.
- Page up/down scrollback uses ⌘PageUp / ⌘PageDown (also ⌘⌥PageUp/PageDown for a few lines at a time).
- Font size changes (⌘= / ⌘− / ⌘0) are per-window and reset to the configured default with ⌘0.
- Composer overlay (⌘⇧E) opens the agent Composer panel. Prompt queue addition (⌘⇧M) queues a prompt without immediately sending.
- Vi mode toggle (⌃⇧Space) switches the focused pane between insert and Vi modal navigation.
- Recipe save (⌘S) saves the current layout/command as a recipe; ⌘⇧S exports it as a `.slopdeskrecipe` file.
- Global search (⌘⇧F) searches across all panes/tabs, not just the current pane.

## Keybindings

### General

| Action | Keys |
|--------|------|
| Command Palette | ⌘⇧P |
| Open Quickly | ⌘⇧O |
| Jump to | ⌘J |
| Settings | ⌘, |

### Window

| Action | Keys |
|--------|------|
| New window | ⌘N |
| Close window | ⌘⇧W |
| Minimize | ⌘M |
| Toggle fullscreen | ⌃⌘F |

### Tab

| Action | Keys |
|--------|------|
| New tab | ⌘T |
| Close tab | ⌘W |
| Reopen last closed | ⌘⇧T |
| Previous tab | ⌘⇧[ |
| Next tab | ⌘⇧] |
| Jump to tab N | ⌘1 … ⌘9 |
| Toggle tabs panel | ⌘⇧L |
| Toggle details panel | ⌘⇧R |
| Show next unread tab | ⌘⇧U |

### Pane (splits)

| Action | Keys |
|--------|------|
| Split right | ⌘D |
| Split left | ⌘⌥D |
| Split down | ⌘⇧D |
| Split up | ⌘⌥⇧D |
| Zoom / unzoom split | ⌘⇧↩ |
| Equalize splits | ⌃⌘= |
| Focus next pane | ⌘] |
| Focus previous pane | ⌘[ |
| Focus pane up | ⌃⌘↑ |
| Focus pane down | ⌃⌘↓ |
| Focus pane left | ⌃⌘← |
| Focus pane right | ⌃⌘→ |
| Move divider up | ⌃⌘⇧↑ |
| Move divider down | ⌃⌘⇧↓ |
| Move divider left | ⌃⌘⇧← |
| Move divider right | ⌃⌘⇧→ |

### Clipboard and selection

| Action | Keys |
|--------|------|
| Copy | ⌘C |
| Cut | ⌘X |
| Paste | ⌘V |
| Select all | ⌘A |
| Undo | ⌘Z |
| Redo | ⌘⇧Z (also ⌘Y) |
| Select word | double-click |
| Select line | triple-click |
| Rectangular select | ⌥ + drag |

### Find and search

| Action | Keys |
|--------|------|
| Find in pane | ⌘F |
| Find next | ⌘G |
| Find previous | ⌘⇧G |
| Global search | ⌘⇧F |

### Scrolling

| Action | Keys |
|--------|------|
| Page up | ⌘PageUp |
| Page down | ⌘PageDown |
| Scroll up (a few lines) | ⌘⌥↑ (also ⌘⌥PageUp) |
| Scroll down (a few lines) | ⌘⌥↓ (also ⌘⌥PageDown) |
| Top of buffer | ⌘Home |
| Bottom of buffer | ⌘End |
| Half page up (Vi Mode only) | ⌃U |
| Half page down (Vi Mode only) | ⌃D |

### Text editing (readline byte sequences)

| Action | Keys |
|--------|------|
| Cursor to line start | ⌘← |
| Cursor to line end | ⌘→ |
| Cursor one word left | ⌥← |
| Cursor one word right | ⌥→ |
| Delete word left | ⌥⌫ |
| Delete word right | ⌥⌦ |
| Delete to line start | ⌘⌫ |
| Delete to line end | ⌘⌦ |

### View

| Action | Keys |
|--------|------|
| Increase font size | ⌘= |
| Decrease font size | ⌘− |
| Reset font size | ⌘0 |

### Composer and Vi mode

| Action | Keys |
|--------|------|
| Open Composer overlay | ⌘⇧E |
| Add to prompt queue | ⌘⇧M |
| Toggle Vi mode | ⌃⇧Space |

### Recipes

| Action | Keys |
|--------|------|
| Save recipe | ⌘S |
| Export .slopdeskrecipe | ⌘⇧S |

## Config keys

Custom keybindings in `~/.config/slopdesk/config.toml`:

| Key | Default | Effect |
|-----|---------|--------|
| `keybind = <chord>:<action>` | (none — all defaults are built-in) | Bind a chord to an action, overriding or supplementing defaults |
| `keybind = unbind:<chord>` | (none) | Removes a default binding for the given chord |
| `keybind = <chord>:text:<literal>` | (none) | Sends literal text string to the terminal on the chord |
| `keybind = <chord>:csi:<seq>` | (none) | Sends ESC [ + seq to the terminal (CSI escape sequence) |
| `keybind = <chord>:esc:<payload>` | (none) | Sends ESC + payload to the terminal |

Modifier names: `cmd`, `ctrl`, `alt` (also `opt`), `shift`. Multi-key (prefix) chords use `>` separator, e.g. `cmd+b>cmd+v`.

Example bindings from docs:
- `keybind = cmd+t:new_tab`
- `keybind = cmd+w:close_pane`
- `keybind = cmd+shift+t:reopen_closed`
- `keybind = cmd+1:goto_tab:1`
- `keybind = ctrl+shift+c:copy_to_clipboard`
- `keybind = unbind:cmd+q`

## Visual spec

### otty-icon.png — App icon

The app icon is a 256×256 px rounded-square (squircle) with a light gray/white background. The icon body is a large dark circle (near-black, approximately #2d2d2d) centered in the squircle. On the dark circle, three white glyphs are arranged in a terminal-prompt composition: `>_` on the upper-left (standard prompt chevron + underscore), and `*` (asterisk) in the upper-right. A short horizontal dash (`-`) sits below the `>_`, centered-left. The glyphs are in a bold, slightly rounded sans-serif weight. The overall aesthetic is minimal, icon-kit dark-on-light, instantly recognizable as a terminal app. No badge, shadow, or secondary color is used.

There are no in-page screenshots for this reference page — it is a pure text/table reference page with no UI screenshots embedded.

## Screenshots

- `otty-icon.png` — App icon (256×256 PNG), this design's reference icon asset.

## Implementation notes

### Direct implementation

- **Tab management** (⌘T, ⌘W, ⌘⇧T, ⌘⇧[/], ⌘1-9, ⌘⇧L, ⌘⇧R, ⌘⇧U): SlopDesk already has a tab/pane model with WorkspaceStore. These map directly to `WorkspaceStore` tab operations. ⌘⇧L / ⌘⇧R map to sidebar/details panel toggles already present in the UI.
- **Pane splits** (⌘D, ⌘⌥D, ⌘⇧D, ⌘⌥⇧D): Direct map to `WorkspaceStore` split operations — already partially implemented.
- **Pane focus** (⌘]/⌘[, ⌃⌘↑/↓/←/→): Focus routing is client-side; maps to the existing pane-focus system.
- **Zoom/unzoom** (⌘⇧↩): A "zoom" mode for the focused pane (hide other panes, fill the tab) — straightforward WorkspaceStore state flag.
- **Equalize splits** (⌃⌘=): Distribute pane sizes equally — call into NSSplitView equalization on the host side.
- **Divider move** (⌃⌘⇧↑/↓/←/→): Maps to the existing live-resize divider system (already implemented with `slopdesk-divider-live-resize`).
- **Clipboard** (⌘C/X/V/A/Z/⌘⇧Z): Standard macOS clipboard — all client-side, no remote involvement needed for copy. Paste sends to PTY over the mux channel.
- **Rectangular select** (⌥+drag): Requires libghostty support for block selection; check ghostty's selection API.
- **Find in pane** (⌘F, ⌘G, ⌘⇧G): In-buffer search — implemented in libghostty/ghostty's search API. Client UI wraps it.
- **Global search** (⌘⇧F): Cross-pane search — requires iterating all pane buffers; can be implemented client-side.
- **Font size** (⌘=, ⌘−, ⌘0): Client-side font size delta; ghostty terminal re-renders at new size, triggers SIGWINCH to host. Already tracked.
- **Window ops** (⌘N, ⌘⇧W, ⌘M, ⌃⌘F): Standard macOS NSWindow operations, entirely client-side.
- **Vi mode** (⌃⇧Space): libghostty has Vi mode; the toggle sends the appropriate OSC or internal signal.
- **Scrolling** (⌘PageUp/Down, ⌘⌥↑/↓, ⌘Home/End): Scrollback buffer navigation — client-side ghostty scrollback, no round-trip.
- **Text editing readline sequences** (⌘←/→, ⌥←/→, ⌥⌫/⌦, ⌘⌫/⌦): These are client-side interceptions that send specific byte sequences (e.g. ⌘← → `\x01`, ⌘→ → `\x05`) over the PTY mux to the host. Already handled by ghostty's input translation layer.
- **Command Palette** (⌘⇧P): Entirely client-side overlay UI.
- **Open Quickly** (⌘⇧O): Client-side overlay (uses FuzzyMatcher for local pane/tab search).
- **Jump to** (⌘J): Client-side outline/jump navigation.
- **Settings** (⌘,): Opens client-side settings UI (PreferencesStore / ConfigStore).

### Partial / conditional

- **Composer overlay** (⌘⇧E): Opens the existing Composer panel in slopdesk. Fully client-side UI wrapping the agent interface. Already partially implemented per the agent-drive and ClaudeStatus work.
- **Add to prompt queue** (⌘⇧M): Maps to the PromptQueue system. Client-side.
- **Recipes** (⌘S / ⌘⇧S): Recipes store named layouts/commands. ⌘S is currently the system Save shortcut; intercepting it requires checking focus context (terminal pane vs. other UI). The `.slopdeskrecipe` export format is this spec's own format — slopdesk can define it as JSON/TOML named sessions.
- **Show next unread tab** (⌘⇧U): Requires tracking per-tab "unread" state — a tab has unread activity if it has produced output since it was last focused. This is a buffer-side concern; ghostty can track last-rendered sequence vs. current sequence.
- **Reopen last closed tab** (⌘⇧T): Requires a "recently closed tabs" stack in WorkspaceStore, retaining the session state for some window of time (or until the session naturally terminates).

### Platform / architecture constraints

- **Half-page scroll in Vi mode** (⌃U/⌃D): When Vi mode is active, these are intercepted at the client before being forwarded to the PTY. In slopdesk's architecture the PTY is remote; Vi mode scroll must be implemented at the client terminal (libghostty) level and NEVER forwarded to the host PTY while Vi mode is active — otherwise the host shell interprets ⌃U as "kill line." This is a correctness trap: Vi mode scroll state must be tracked client-side with explicit interception.
- **Find in pane** (⌘F): ghostty's search API operates on the local terminal buffer. Over a remote session, the buffer is a client-side replica of the host's PTY output. Search works correctly as long as the scrollback buffer is fully replicated — which it is via the ReplayBuffer. No issue for forward search; historical scrollback beyond the ReplayBuffer window (64 MiB) may be truncated.
- **Global search** (⌘⇧F): Searches across ALL pane buffers simultaneously. In slopdesk each pane is a separate PTY session over the mux; all buffers are local replicas on the client. Global search is fully feasible but must query each pane's local ghostty buffer, not make any remote call.
- **SSH/Remote badge on tabs**: A remote-session badge on tabs connected over SSH is a common pattern in local terminal apps. SlopDesk IS always remote, so the badge convention could be repurposed (e.g. show host name or connection status) but doesn't apply directly — all sessions are remote by definition.
- **Prefix/chord sequences** (`cmd+b>cmd+v` style): Requires a client-side key chord state machine that captures the first chord and waits for the second before dispatching. The NSEvent monitor already in place (for the prefix key system) supports this, but multi-step chords need explicit timeout/cancel handling.
- **`text:`, `csi:`, `esc:` custom binding targets**: These require the client to send raw bytes/sequences directly to the PTY mux rather than dispatching a named action. The mux channel (`SlopDeskTransport`) already supports raw byte forwarding, so these are implementable but need a dedicated dispatch path in the keybinding handler.
