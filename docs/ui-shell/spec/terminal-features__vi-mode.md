# Vi Mode

## Summary

Vi Mode turns the terminal pane into a read-only, vi-style navigator of scrollback history. While active, the terminal stops forwarding keys to the shell; instead every keystroke drives the vi cursor through the scrollback buffer. The user can move, select text in three visual modes (character, line, block), search forward/backward, and yank the selection to the clipboard. A dedicated pill UI element shows the current mode and any pending repeat count. Exiting returns the terminal to normal input mode.

> **Status:** Supported in terminal pane only. SlopDesk has no built-in code editor pane, so this is a terminal-only feature.

---

## Behaviors

- Entering Vi Mode suspends all key forwarding to the shell; keys exclusively drive the vi cursor through scrollback.
- The Enter Vi Mode binding is `⌃⇧Space` (Control-Shift-Space) by default, and is remappable via the **Vi Mode** command in Keybindings.
- A separate **Mark Mode** command (no default binding) enters the same mode with arrow-key + Shift-select emphasis, so the user can select without learning vi letters.
- Arrow keys mirror `h`/`j`/`k`/`l`, enabling Mark Mode navigation without vi knowledge.
- Any motion can be prefixed by a numeric repeat count (e.g. `5j` moves down five lines, `3w` jumps three words forward, `10k` up ten lines).
- The pending repeat count is displayed live inside the Vi Mode pill as the user types the digits.
- A key-hint bar can be toggled on/off with `⌘/` while in Vi Mode (**Vi Mode Key Hints** command in Keybindings).
- Vi Mode is exited by pressing `Esc`, `q`, or clicking the `×` control on the pill.
- Three visual selection modes are available: character-wise (`v`), line-wise (`V`), and block/rectangular (`⌃v`).
- Within a selection, `o` swaps the cursor to the opposite end of the selection (anchor swap).
- `y` yanks the selection to the system clipboard and exits Vi Mode.
- `Enter` copies the selection and exits Vi Mode.
- `/` opens the find bar and searches forward through the scrollback; `?` opens it searching backward.
- After typing a query and pressing `Esc`, focus returns to the scrollback buffer; `n` steps the vi cursor to the next match in the search direction, `N` steps against it.
- `f` enters Hint Mode for keyboard-driven clicking of on-screen links (complementary feature; see Hint Mode spec).
- Vi Mode has no config-file keys; the only customization surface is remapping commands in Keybindings.

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

This page contains no screenshots. The following UI description is derived from the textual description in the documentation.

### Vi Mode Pill

- A pill-shaped badge appears in the terminal pane while Vi Mode is active.
- The pill displays the current mode state (e.g. "Vi Mode", "VISUAL", "VISUAL LINE", "VISUAL BLOCK").
- While the user types a numeric repeat-count prefix, the pending digits are shown live inside the pill.
- The pill carries an `×` button that exits Vi Mode when clicked.
- The pill is persistent and visible throughout the Vi Mode session.

### Key-Hint Bar

- Toggled by `⌘/` (remappable as **Vi Mode Key Hints** command).
- A bar (position not specified — likely bottom of the pane or overlaid) showing available key bindings for quick reference.
- Toggle is per-session and off by default (the `⌘/` binding suggests it is shown on demand).

### Find Bar

- `/` and `?` open the pane's shared find bar.
- Pressing `Esc` closes the find bar and hands focus back to the scrollback buffer so vi cursor keys take effect again.

---

## Screenshots

No screenshots are present on this documentation page.

---

## Implementation notes

### Feasible directly

- **Scrollback navigation motions** (`h`/`j`/`k`/`l`, `w`/`b`/`e`, `0`/`$`/`^`, `H`/`M`/`L`, `g g`/`G`, `⌃u`/`⌃d`, `⌃b`/`⌃f`): libghostty's terminal model tracks scrollback; motion can be implemented by translating vi keys into scrollback position updates, identical to local behavior.
- **Numeric repeat-count prefix**: pure client-side state; count accumulates locally, then the resolved motion is applied. No host involvement.
- **Visual selection modes** (character, line, block): libghostty supports selection; slopdesk can extend it to support all three modes by driving libghostty's selection API client-side.
- **Yank to clipboard** (`y` / `Enter`): copying selected text from libghostty's buffer to the system clipboard is client-side on macOS and iOS (NSPasteboard / UIPasteboard). No host involvement.
- **Key-hint bar**: a pure client-side overlay UI; no host involvement.
- **Vi Mode pill**: a client-side SwiftUI overlay on the terminal pane.

### Requires adaptation

- **Find bar (`/` / `?`)**: SlopDesk must implement its own in-pane search against libghostty's scrollback content. The behavior (open, type query, `Esc` to buffer, `n`/`N` to step) is well-specified and implementable, but requires a search index over scrollback lines. This is fully client-side on the slopdesk client — no host involvement needed.
- **Hint Mode (`f`)**: a complementary feature that keyboard-annotates visible links for clicking. On slopdesk, link positions come from the libghostty render model. Clicking a link would inject a mouse-click event to the HOST via the slopdesk input path (not a local browser open), because the terminal session lives on the macOS host. This is an architectural consequence of the remote model: a purely local terminal can just open the URL locally, but slopdesk must decide whether to open the URL on the client (if OSC 8 hyperlink content is tunneled) or inject a click on the host. This needs an explicit decision on the URL-open side before it can be implemented.
- **Mark Mode (arrow-key + Shift-select emphasis)**: a variant entry point with no default binding. Fully implementable client-side; just a different key-input interpretation layer, once Keybindings support it.
- **iOS client**: all vi-cursor motion and selection modes must work via on-screen key overlays or external keyboard on iOS. The `⌃⇧Space` entry binding needs an alternative trigger for software-keyboard users. The pill and key-hint bar must adapt to the iOS HIG (smaller touch targets, no hover states).
- **Remote scrollback boundary**: slopdesk streams terminal output from the host; the full scrollback history depends on what has been received by the client. If the client reconnects mid-session, older scrollback may not be locally available. This is a structural gap relative to a purely local terminal, where scrollback is always complete. The `ReplayBuffer` (64 MiB ceiling) mitigates this but does not guarantee full history.
- **Key forwarding suspension**: in slopdesk, keys are normally forwarded over the network to the host PTY. In Vi Mode, the client must intercept keys BEFORE they are enqueued for host transmission. This is an interception point at the `SlopDeskClientUI` key-event layer — must ensure no keys leak to the transport while Vi Mode is active.
