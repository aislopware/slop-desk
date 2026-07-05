# Read-only Mode

## Summary

Locks a pane so nothing you type reaches the shell. Useful when a long-running process is producing important output and you don't want a stray keystroke to interrupt it — or when you hand the window to someone else for a quick look.

## Behaviors

- **Toggle is per-pane.** Splitting or opening a new tab gives you a fresh editable pane. The state does not propagate to siblings.
- **Three ways to toggle (terminal panes):**
  1. Menu bar: Shell → Read Only
  2. Command palette: type "read only" (also accepts `readonly`, `lock`, `freeze`, `view only`)
  3. Titlebar pill: click the `×` on the READ ONLY pill to disable
- **Titlebar pill:** When read-only is active, a pill labeled `🔒 READ ONLY ×` appears in the top-right corner of the pane's titlebar. The `×` button deactivates the mode. The pill is right-aligned, adjacent to (but distinct from) the window title centered in the bar.
- **Input blocking — every user-input path is gated:**
  - Keyboard input (including IME commit)
  - Paste (`⌘V`, middle-click, drag-drop text)
  - Click-to-move (cursor-position write that some shells do on mouse click)
  - Mouse reporting (for TUIs that consume mouse events)
  - Drag-and-drop of files/paths into the pane
- **Rejection feedback:** when any blocked input is attempted, the pane beeps once.
- **Output is unaffected:** text keeps streaming, scrollback keeps growing; the user can still scroll, select, copy, and search.
- **Vi Mode / Hint Mode interaction:** these modes temporarily hide the READ ONLY pill while active (their own keybindings drive selection/hinting, not the shell, so the lock is not needed during them). The lock remains on; the pill reappears when vi/hint mode is exited.
- **Sudo / Auto-Approve / Secure Input pills** are hidden while read-only is on, because none of those input paths can fire.
- **File panes — read-only applies too:**
  - A text/code pane locks editing.
  - A Markdown / SVG / HTML pane switches to its rendered Preview mode.
  - File panes have no titlebar pill; the pane simply switches to its read-only representation.
  - Toggle methods for file panes: menu bar (Shell → Read Only, applied to whichever pane is focused), command palette ("Read Only" / "Edit Mode", also `readonly`, `lock`, `view only` / `edit`, `editable`, `unlock`), workspace command palette (under View Mode → Make Read-Only / Make Editable), or the same custom keybinding set for Read Only.
  - While a text pane is read-only, `⌘S` / `⌘⇧S` are disabled — attempting either beeps.
  - The info panel Status row reads "Read-only" instead of "Saved" / "Unsaved changes".
  - Files opened in preview mode (PDF, images, diffs) are always read-only by nature and do not expose the toggle.

## Keybindings

| Action | Keys |
|--------|------|
| Toggle Read-only (no default shown; set via Keybindings settings) | *(user-configurable)* |
| Disable via titlebar pill | Click `×` on the READ ONLY pill |
| `⌘S` / `⌘⇧S` while text pane is read-only | Blocked (beeps) |

*There is no hard-coded default key chord for toggling read-only. The feature is reachable via menu bar (Shell → Read Only) and command palette.*

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none documented)* | — | Read-only mode is a runtime toggle only; there is no persistent config key to set a pane as read-only at launch. |

## Visual spec

### Screenshot: `readonly-mode.png`

**Overall layout:** A single macOS window (standard rounded-corner window chrome, light/white background) showing a full-bleed terminal pane. No sidebar, no tab bar — single-pane view.

**Titlebar (top bar):**
- Far left: standard macOS traffic-light buttons (red, yellow, green circles), positioned at the typical ~12 px inset from the top-left corner.
- Center: window/pane title rendered in a medium-weight sans-serif font in a dark gray/black color: `tail -f`.
- Far right: a READ ONLY pill — a compact rounded-rectangle badge containing a padlock icon (`🔒`) immediately followed by the label `READ ONLY` in small caps / uppercase, then a `×` close button. The pill sits flush-right in the title bar with a small margin from the window edge. The pill appears to use the same background tone as the titlebar (light, no strong fill color — it reads as a bordered or subtly filled chip rather than a brightly colored badge). The label text is in dark/black. The `×` is a standard close glyph, slightly lighter than the label.

**Terminal content area:**
- Monospaced font (appears to be a JetBrains Mono or similar programming font), white/off-white background, dark text.
- Content: multiple lines of log output from a `tail -f` run — timestamped debug lines (`11:52:57.723 [ColsScale] reapplyCellMetrics SKIP (dedup) view=ObjectIdentifier(...) viewScale=2.0 newScale=2.0 windowScale=2.0 engineCellW=15.6`, etc.). Lines wrap naturally within the pane width.
- No cursor visible (consistent with a tailing process, not interactive prompt).
- No special overlay or dimming of the content area — content renders normally even in read-only mode.
- No status bar visible at the bottom.

**Spacing and density:** The titlebar has generous vertical padding (~10–12 px each side). Terminal content has standard terminal cell padding. The window has a light drop shadow. Overall style: clean, minimal — the only indicator of read-only mode is the titlebar pill.

**Color treatment:**
- Window chrome / titlebar background: approximately `#F5F5F5` (very light gray, macOS standard).
- Terminal background: white/near-white (`#FFFFFF` or `#FAFAFA`).
- Terminal text: dark charcoal/near-black (default dark terminal text on light theme).
- READ ONLY pill: appears as dark text on a light/transparent or lightly stroked background — no strong accent color; it blends with the titlebar rather than standing out aggressively.
- Padlock glyph: dark, same weight as label text.

## Screenshots

- `readonly-mode.png`

## SlopDesk mapping notes

### Architecture context
SlopDesk: macOS host (runs PTY/shell, libghostty render, SCStream capture) + macOS/iOS client (receives video frames, injects input). Read-only mode is a **client-side input gate** — it blocks the client from forwarding keystrokes/mouse events to the host, not a host-side PTY lock.

### Implementation mapping

| Spec'd behavior | SlopDesk implementation | Notes |
|---------------|----------------------|-------|
| Toggle per-pane via menu Shell → Read Only | `WorkspaceStore` per-pane `isReadOnly` bool; menu item in the macOS app's Shell menu | 1:1 on macOS client; iOS client can expose via context menu or command palette |
| Toggle via command palette | SlopDesk command palette (already exists) — add "Read Only" / "lock" / "freeze" search terms | 1:1 |
| Titlebar pill `🔒 READ ONLY ×` | Inject a pill/badge into the pane's `PaneHeaderView` / titlebar overlay; `×` button sets `isReadOnly = false` | 1:1 on macOS; iOS equivalent = a toolbar badge or header overlay chip |
| Keyboard input blocked | Client: suppress forwarding keystrokes through `InputEventRouter` when pane `isReadOnly` is true | 1:1 — blocking happens before bytes reach the host TCP channel |
| Paste blocked (`⌘V`, middle-click, drag-drop text) | Client: guard paste/drop handlers in `PaneView` | 1:1 |
| Click-to-move blocked | Client: suppress mouse-click events that would be forwarded as cursor-position writes | 1:1 |
| Mouse reporting for TUIs blocked | Client: suppress forwarding of mouse-report escape sequences | 1:1 |
| Drag-and-drop of files/paths blocked | Client: reject drop onto pane in `NSDraggingDestination` / SwiftUI `onDrop` | 1:1 |
| Beep on rejected input | Call libghostty `ghostty_surface_key` with BEL / use `NSSound.beep()` | 1:1 |
| Output unaffected (text keeps streaming) | Host side is unchanged; video frames continue to arrive and display | 1:1 — read-only only gates outbound input from client, never inbound video |
| Scroll / select / copy / search still work | These are already purely client-side in the slopdesk model (scroll = local scrollback, copy = local selection) | 1:1 |
| Vi Mode / Hint Mode hide the pill temporarily | Track `isViMode` / `isHintMode` per-pane; conditionally hide the READ ONLY pill in the header view | 1:1 |
| Sudo / Auto-Approve / Secure Input pills hidden | Already separate pill components; add `isReadOnly` guard to their visibility | 1:1 |
| File panes: lock editing / switch to preview | SlopDesk does not currently have a built-in file editor pane — **cannot map 1:1 today**. Future editor panes (if added) should implement the same `isReadOnly` gate. |
| File pane: `⌘S` blocked with beep | Same caveat — relevant only when/if file editor panes are implemented. |
| File pane: info panel Status row "Read-only" | Same caveat. |
| File pane: command palette "Edit Mode" / "Make Editable" | Same caveat. |
| No persistent config key | Consistent with slopdesk's per-session state model — no SLOPDESK_READ_ONLY launch flag needed initially. |

### Cannot map 1:1

1. **File pane read-only (text/code/Markdown/SVG/HTML editing):** SlopDesk has no built-in file editor; this feature is irrelevant until editor panes are added.
2. **Host-side enforcement:** Read-only is enforced only at the client input-gate layer; the lock is client-side only, not a PTY/shell-level lock. A sufficiently motivated remote agent on the host can still write to its own PTY. This is acceptable for the stated use case (preventing stray keystrokes from the viewer), but is not a security boundary.
3. **`tail -f` title display:** The titlebar is expected to auto-name from the running process (`tail -f`). SlopDesk must relay pane titles over the wire (OSC 0/2 or shell integration) for the client to display them — existing mechanism, just needs to be wired to the pane header.
