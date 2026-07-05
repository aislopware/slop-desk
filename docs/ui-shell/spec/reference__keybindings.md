# Keybindings Reference

## Summary

Default key map for SlopDesk's terminal client. Every action is re-bindable via Settings → Key Bindings GUI or `~/.config/slopdesk/config.toml`; many actions ship unbound. This page lists all default bindings by category, the notation legend, and a "See also" pointer to the customization guide.

Notation: ⌘ = Command, ⌃ = Control, ⌥ = Option, ⇧ = Shift, ↩ = Return, ⌫ = Delete, ⌦ = Forward Delete.

## Behaviors

- All keybindings are re-bindable; no hard-coded set. Any action can be unbound/rebound via GUI or config.
- Settings → Key Bindings GUI groups actions by category (General, Tabs, Pane, …), shows chords as chips; dashes = unbound.
- Search filters by action name or chord string (e.g. `cmd+t` reveals what uses that combo).
- Rebind: click a row, press the combo; conflict detection alerts on collision.
- Unbind: Backspace while editing; Esc cancels.
- "Reset to Default" button appears after any change; clears all customizations after confirmation.
- Custom bindings can send literal text (`text:`), CSI (`csi:`), or ESC (`esc:`) payloads — not just named actions.
- Multi-key (prefix) chords use `>` in config, e.g. `cmd+b>cmd+v`.
- ⌘1…⌘9 = Nth tab by position; ⌘⇧U = next tab with unread activity.
- Pane focus (⌃⌘↑/↓/←/→) is directional — moves focus to the adjacent pane. Divider move (⌃⌘⇧↑/↓/←/→) resizes by moving the shared divider.
- Zoom/unzoom (⌘⇧↩) toggles a single pane to fill the tab; again restores the split. Equalize (⌃⌘=) distributes all panes in the tab equally.
- Text-editing bindings (⌘←/→, ⌥←/→, ⌥⌫, ⌥⌦, ⌘⌫, ⌘⌦) send readline byte sequences to the focused terminal — client-side interceptions, not OS text-field actions.
- Rectangular selection: hold ⌥ while dragging. Double-click = word; triple-click = full line.
- Scroll half-page (⌃U/⌃D) only in Vi Mode. Page up/down = ⌘PageUp/⌘PageDown (⌘⌥PageUp/PageDown = a few lines).
- Font size (⌘=/⌘−/⌘0) is per-window; ⌘0 resets to the configured default.
- Composer overlay (⌘⇧E). ⌘⇧M queues a prompt without sending. Vi mode toggle (⌃⇧Space) switches the focused pane insert↔Vi modal.
- ⌘S saves the current layout/command as a recipe; ⌘⇧S exports it as a `.slopdeskrecipe` file.
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

Custom keybindings in `~/.config/slopdesk/config.toml` (all defaults are built-in; no config default):

| Key | Effect |
|-----|--------|
| `keybind = <chord>:<action>` | Bind a chord to an action, overriding/supplementing defaults |
| `keybind = unbind:<chord>` | Remove a default binding for the chord |
| `keybind = <chord>:text:<literal>` | Send literal text to the terminal |
| `keybind = <chord>:csi:<seq>` | Send ESC [ + seq (CSI escape) |
| `keybind = <chord>:esc:<payload>` | Send ESC + payload |

Modifier names: `cmd`, `ctrl`, `alt` (also `opt`), `shift`. Multi-key (prefix) chords use `>`, e.g. `cmd+b>cmd+v`.

Example bindings:
- `keybind = cmd+t:new_tab`
- `keybind = cmd+w:close_pane`
- `keybind = cmd+shift+t:reopen_closed`
- `keybind = cmd+1:goto_tab:1`
- `keybind = ctrl+shift+c:copy_to_clipboard`
- `keybind = unbind:cmd+q`

## Visual spec

### otty-icon.png — App icon

256×256 px rounded-square (squircle), light gray/white background. Body = a large dark circle (near-black ≈#2d2d2d) centered in the squircle. Three white glyphs in a terminal-prompt composition: `>_` upper-left (prompt chevron + underscore), `*` upper-right, and a short `-` below the `>_`, centered-left. Bold, slightly-rounded sans-serif. Minimal dark-on-light; no badge, shadow, or secondary color.

No in-page screenshots — pure text/table reference.

## Screenshots

- `otty-icon.png` — App icon (256×256 PNG), reference icon asset.

## Implementation notes

### Direct implementation

- **Tab management** (⌘T, ⌘W, ⌘⇧T, ⌘⇧[/], ⌘1-9, ⌘⇧L, ⌘⇧R, ⌘⇧U): map to `WorkspaceStore` tab ops (tab/pane model already exists). ⌘⇧L/⌘⇧R → existing sidebar/details panel toggles.
- **Pane splits** (⌘D, ⌘⌥D, ⌘⇧D, ⌘⌥⇧D): map to `WorkspaceStore` split ops — partially implemented.
- **Pane focus** (⌘]/⌘[, ⌃⌘↑/↓/←/→): client-side focus routing → existing pane-focus system.
- **Zoom/unzoom** (⌘⇧↩): WorkspaceStore state flag (hide other panes, fill tab).
- **Equalize splits** (⌃⌘=): NSSplitView equalization on the host side.
- **Divider move** (⌃⌘⇧↑/↓/←/→): existing live-resize divider system (`slopdesk-divider-live-resize`).
- **Clipboard** (⌘C/X/V/A/Z/⌘⇧Z): standard macOS, client-side; paste sends to PTY over the mux channel.
- **Rectangular select** (⌥+drag): needs libghostty block-selection support; check ghostty's selection API.
- **Find in pane** (⌘F/⌘G/⌘⇧G): libghostty search API; client UI wraps it.
- **Global search** (⌘⇧F): iterate all pane buffers; client-side.
- **Font size** (⌘=/⌘−/⌘0): client-side delta; ghostty re-renders at new size, triggers SIGWINCH to host.
- **Window ops** (⌘N/⌘⇧W/⌘M/⌃⌘F): standard NSWindow, client-side.
- **Vi mode** (⌃⇧Space): libghostty Vi mode; toggle sends the OSC/internal signal.
- **Scrolling** (⌘PageUp/Down, ⌘⌥↑/↓, ⌘Home/End): client-side ghostty scrollback, no round-trip.
- **Text editing readline** (⌘←/→, ⌥←/→, ⌥⌫/⌦, ⌘⌫/⌦): client-side interceptions sending byte sequences (⌘← → `\x01`, ⌘→ → `\x05`) over the PTY mux; handled by ghostty's input translation.
- **Command Palette** (⌘⇧P): client-side overlay.
- **Open Quickly** (⌘⇧O): client-side overlay (FuzzyMatcher, local pane/tab search).
- **Jump to** (⌘J): client-side outline/jump navigation.
- **Settings** (⌘,): client-side settings UI (PreferencesStore/ConfigStore).

### Partial / conditional

- **Composer overlay** (⌘⇧E): wraps the existing Composer panel/agent interface, client-side; partially implemented (agent-drive, ClaudeStatus).
- **Add to prompt queue** (⌘⇧M): maps to the PromptQueue system; client-side.
- **Recipes** (⌘S / ⌘⇧S): named layouts/commands. ⌘S is the system Save shortcut; intercepting needs a focus-context check (terminal pane vs other UI). `.slopdeskrecipe` is this spec's own format — slopdesk can define it as JSON/TOML named sessions.
- **Show next unread tab** (⌘⇧U): track per-tab unread (output since last focus) — buffer-side; ghostty tracks last-rendered vs current sequence.
- **Reopen last closed** (⌘⇧T): "recently closed tabs" stack in WorkspaceStore, retaining session state for a window of time (or until the session terminates).

### Platform / architecture constraints

- **Half-page scroll in Vi mode** (⌃U/⌃D): intercept at the client before the PTY. The PTY is remote, so Vi scroll must be implemented at the client (libghostty) and NEVER forwarded while Vi mode is active — else the host shell reads ⌃U as "kill line." Correctness trap: track Vi scroll state client-side with explicit interception.
- **Find in pane** (⌘F): ghostty search operates on the local buffer (a client-side replica of host PTY output). Works as long as scrollback is fully replicated via the ReplayBuffer; historical scrollback beyond the ReplayBuffer window (64 MiB) may be truncated.
- **Global search** (⌘⇧F): searches ALL pane buffers; each pane is a separate PTY over the mux with a local replica. Feasible but must query each pane's local ghostty buffer, never make a remote call.
- **SSH/Remote badge on tabs**: common in local terminals, but SlopDesk is always remote so the badge doesn't apply directly — could be repurposed (host name / connection status).
- **Prefix/chord sequences** (`cmd+b>cmd+v`): needs a client-side chord state machine that captures the first chord and waits for the second. The existing NSEvent monitor (prefix key system) supports it; multi-step chords need explicit timeout/cancel handling.
- **`text:` / `csi:` / `esc:` targets**: client sends raw bytes/sequences to the PTY mux instead of a named action. The mux channel (`SlopDeskTransport`) already forwards raw bytes; needs a dedicated dispatch path in the keybinding handler.
