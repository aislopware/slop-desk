# Vi Mode

## Summary

Vi Mode makes the terminal pane a read-only, vi-style navigator of scrollback. While active, keystrokes drive the vi cursor instead of the shell: move, select in three visual modes (character, line, block), search forward/backward, and yank to clipboard. A pill UI shows the current mode and pending repeat count. Exiting restores normal input.

> **Status:** Terminal pane only. SlopDesk has no code-editor pane, so this is terminal-only.

---

## Behaviors

- Entering suspends all key forwarding to the shell; keys exclusively drive the vi cursor through scrollback (client intercepts before transport).
- Enter binding: `⌃⇧Space` by default, remappable via the **Vi Mode** command in Keybindings.
- **Mark Mode** command (no default binding) enters the same mode with arrow-key + Shift-select emphasis, so users can select without vi letters. Arrow keys mirror `h`/`j`/`k`/`l`.
- Any motion takes a numeric repeat-count prefix (`5j`, `3w`, `10k`); pending digits show live in the pill.
- Key-hint bar toggles with `⌘/` (**Vi Mode Key Hints** command).
- Exit with `Esc`, `q`, or the pill's `×`.
- Visual selection: character `v`, line `V`, block/rectangular `⌃v`. `o` swaps the cursor to the opposite selection end (anchor swap).
- `y` yanks to system clipboard and exits; `Enter` copies and exits.
- `/` opens the find bar searching forward; `?` searches backward. After a query, `Esc` returns focus to scrollback; `n` steps to the next match in the search direction, `N` against it.
- `f` enters Hint Mode for keyboard-driven link clicking (see Hint Mode spec).
- No config-file keys; only customization is remapping commands in Keybindings.

---

## Keybindings

### Entering / Leaving

| Action | Keys |
|--------|------|
| Enter Vi Mode | `⌃⇧Space` (Control-Shift-Space) |
| Show / hide the key-hint bar | `⌘/` |
| Leave Vi Mode | `Esc` or `q` (or click `×` on the pill) |

### Motion

| Action | Keys |
|--------|------|
| Left / down / up / right | `h` `j` `k` `l` |
| (same via arrow keys) | `←` `↓` `↑` `→` |
| Word forward / back / end | `w` `b` `e` |
| Line start / end | `0` `$` |
| First non-blank character | `^` |
| Top / middle / bottom of screen | `H` `M` `L` |
| Top of scrollback | `g g` |
| Bottom of scrollback | `G` |
| Half-page up / down | `⌃u` / `⌃d` |
| Full-page up / down | `⌃b` / `⌃f` |

### Selection

| Action | Keys |
|--------|------|
| Character-wise visual selection | `v` |
| Line-wise visual selection | `V` |
| Block (rectangular) visual selection | `⌃v` |
| Swap cursor to opposite end of selection | `o` |
| Yank selection to clipboard (exits Vi Mode) | `y` |
| Copy selection and exit | `Enter` |

### Search (within Vi Mode)

| Action | Keys |
|--------|------|
| Search forward (opens find bar) | `/` |
| Search backward (opens find bar) | `?` |
| Return focus to buffer from find bar | `Esc` |
| Next match in search direction | `n` |
| Previous match (against search direction) | `N` |
| Enter Hint Mode (keyboard link clicking) | `f` |

---

## Config keys

Vi Mode has no config-file keys.

| Key | Default | Effect |
|-----|---------|--------|
| (none) | — | All customization is via Keybindings remapping: commands **Vi Mode**, **Mark Mode**, and **Vi Mode Key Hints**. |

---

## Visual spec

No screenshots; description derived from the docs text.

### Vi Mode Pill

- Pill-shaped badge in the terminal pane while active; persistent throughout the session.
- Displays mode state ("Vi Mode", "VISUAL", "VISUAL LINE", "VISUAL BLOCK").
- Shows pending repeat-count digits live as typed.
- Carries an `×` button that exits on click.

### Key-Hint Bar

- Toggled by `⌘/` (remappable as **Vi Mode Key Hints**).
- A bar (position unspecified — likely bottom of pane or overlaid) listing available bindings.
- Per-session, off by default (on demand).

### Find Bar

- `/` and `?` open the pane's shared find bar.
- `Esc` closes it and returns focus to scrollback so vi cursor keys take effect.

---

## Screenshots

None on this page.

---

## Implementation notes

### Feasible directly

- **Scrollback navigation motions** (`h`/`j`/`k`/`l`, `w`/`b`/`e`, `0`/`$`/`^`, `H`/`M`/`L`, `g g`/`G`, `⌃u`/`⌃d`, `⌃b`/`⌃f`): libghostty tracks scrollback; translate vi keys into scrollback position updates, identical to local behavior.
- **Numeric repeat-count prefix**: pure client-side state; count accumulates locally, then resolved motion applies. No host involvement.
- **Visual selection modes** (character, line, block): libghostty supports selection; drive its selection API client-side for all three modes.
- **Yank to clipboard** (`y` / `Enter`): client-side on macOS and iOS (NSPasteboard / UIPasteboard). No host involvement.
- **Key-hint bar**: pure client-side overlay UI.
- **Vi Mode pill**: client-side SwiftUI overlay on the terminal pane.

### Requires adaptation

- **Find bar (`/` / `?`)**: SlopDesk implements its own in-pane search over libghostty scrollback content, requiring a search index over scrollback lines. Behavior (open, type, `Esc` to buffer, `n`/`N` step) is well-specified. Fully client-side — no host involvement.
- **Hint Mode (`f`)**: keyboard-annotates visible links for clicking. Link positions come from the libghostty render model. Because the session lives on the macOS host, clicking either injects a mouse-click to the HOST via the input path or opens the URL on the client (if OSC 8 hyperlink content is tunneled) — an architectural consequence of the remote model. **Needs an explicit URL-open-side decision before implementation.**
- **Mark Mode (arrow-key + Shift-select)**: variant entry point, no default binding. Fully client-side — a different key-input interpretation layer, once Keybindings support it.
- **iOS client**: all vi-cursor motion and selection must work via on-screen key overlays or external keyboard. `⌃⇧Space` needs an alternative trigger for software-keyboard users. Pill and key-hint bar must adapt to iOS HIG (smaller touch targets, no hover).
- **Remote scrollback boundary**: full history depends on what the client has received; after a mid-session reconnect, older scrollback may be locally unavailable — a structural gap vs a local terminal. The `ReplayBuffer` (64 MiB ceiling) mitigates but does not guarantee full history.
- **Key forwarding suspension**: keys normally forward over the network to the host PTY; in Vi Mode the client must intercept them BEFORE enqueue for host transmission, at the `SlopDeskClientUI` key-event layer — no keys may leak to the transport while active.
