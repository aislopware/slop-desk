# Read-only Mode

## Summary

Locks a pane so nothing you type reaches the shell — protects important output from a stray keystroke, or hands the window to someone else for a look.

## Behaviors

- **Per-pane toggle.** Splitting or opening a new tab yields a fresh editable pane; state does not propagate to siblings.
- **Three toggle paths (terminal panes):**
  1. Menu bar: Shell → Read Only
  2. Command palette: "read only" (also `readonly`, `lock`, `freeze`, `view only`)
  3. Titlebar pill: click the `×` on the READ ONLY pill to disable
- **Titlebar pill:** when active, a `🔒 READ ONLY ×` pill appears top-right in the pane titlebar, right-aligned near the window edge, distinct from the centered window title. The `×` deactivates.
- **Input blocking — every user-input path is gated:**
  - Keyboard input (including IME commit)
  - Paste (`⌘V`, middle-click, drag-drop text)
  - Click-to-move (cursor-position write some shells do on mouse click)
  - Mouse reporting (for TUIs that consume mouse events)
  - Drag-and-drop of files/paths into the pane
- **Rejection feedback:** blocked input beeps once.
- **Output unaffected:** text keeps streaming, scrollback keeps growing; scroll, select, copy, search still work.
- **Vi Mode / Hint Mode:** temporarily hide the pill while active (their keybindings drive selection/hinting, not the shell, so the lock isn't needed). The lock stays on; the pill reappears on exit.
- **Sudo / Auto-Approve / Secure Input pills** hidden while read-only is on — none of those input paths can fire.
- **File panes — read-only applies too:**
  - Text/code pane locks editing.
  - Markdown / SVG / HTML pane switches to rendered Preview mode.
  - No titlebar pill; the pane switches to its read-only representation.
  - Toggle methods: menu bar (Shell → Read Only, applied to the focused pane), command palette ("Read Only" / "Edit Mode", also `readonly`, `lock`, `view only` / `edit`, `editable`, `unlock`), workspace command palette (View Mode → Make Read-Only / Make Editable), or the same custom Read Only keybinding.
  - While read-only, `⌘S` / `⌘⇧S` are disabled — attempting either beeps.
  - Info panel Status row reads "Read-only" instead of "Saved" / "Unsaved changes".
  - Preview-mode files (PDF, images, diffs) are always read-only and do not expose the toggle.

## Keybindings

| Action | Keys |
|--------|------|
| Toggle Read-only (no default shown; set via Keybindings settings) | *(user-configurable)* |
| Disable via titlebar pill | Click `×` on the READ ONLY pill |
| `⌘S` / `⌘⇧S` while text pane is read-only | Blocked (beeps) |

No hard-coded default chord for toggling. Reachable via menu bar (Shell → Read Only) and command palette.

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none documented)* | — | Runtime toggle only; no persistent config key to set a pane read-only at launch. |

## Visual spec

### Screenshot: `readonly-mode.png`

**Layout:** single macOS window (rounded chrome, light background), full-bleed terminal pane. No sidebar, no tab bar.

**Titlebar:**
- Far left: standard traffic-light buttons, ~12 px inset from top-left.
- Center: window/pane title in medium-weight sans-serif, dark gray/black: `tail -f`.
- Far right: READ ONLY pill — compact rounded-rect badge, padlock (`🔒`) + `READ ONLY` label (small caps/uppercase) + `×` close button, flush-right with small edge margin. Same light tone as the titlebar (no strong fill — reads as a bordered/subtly-filled chip, not a bright badge). Label dark/black; `×` a standard close glyph, slightly lighter than the label.

**Terminal content:**
- Monospaced font (JetBrains Mono-like), white/off-white background, dark text.
- `tail -f` log output — timestamped debug lines (`11:52:57.723 [ColsScale] reapplyCellMetrics SKIP (dedup) view=ObjectIdentifier(...) viewScale=2.0 newScale=2.0 windowScale=2.0 engineCellW=15.6`, etc.). Lines wrap naturally within pane width.
- No cursor visible (tailing process, not interactive prompt).
- No overlay or dimming — content renders normally in read-only mode.
- No bottom status bar.

**Spacing:** titlebar ~10–12 px vertical padding each side; standard terminal cell padding; light drop shadow. Clean, minimal — the pill is the only read-only indicator.

**Color:**
- Titlebar background: ~`#F5F5F5` (very light gray, macOS standard).
- Terminal background: white/near-white (`#FFFFFF` or `#FAFAFA`).
- Terminal text: dark charcoal/near-black (default dark text on light theme).
- READ ONLY pill: dark text on light/transparent or lightly stroked background — no accent color; blends with the titlebar.
- Padlock glyph: dark, same weight as label.

## Screenshots

- `readonly-mode.png`

## SlopDesk mapping notes

### Architecture context
SlopDesk: macOS host (PTY/shell, libghostty render, SCStream capture) + macOS/iOS client (receives video frames, injects input). Read-only mode is a **client-side input gate** — it blocks the client from forwarding keystrokes/mouse events to the host, not a host-side PTY lock.

### Implementation mapping

| Spec'd behavior | SlopDesk implementation | Notes |
|---------------|----------------------|-------|
| Toggle per-pane via menu Shell → Read Only | `WorkspaceStore` per-pane `isReadOnly` bool; Shell menu item in the macOS app | 1:1 on macOS; iOS via context menu or command palette |
| Toggle via command palette | Existing command palette — add "Read Only" / "lock" / "freeze" search terms | 1:1 |
| Titlebar pill `🔒 READ ONLY ×` | Inject pill into pane `PaneHeaderView` / titlebar overlay; `×` sets `isReadOnly = false` | 1:1 on macOS; iOS = toolbar badge or header overlay chip |
| Keyboard input blocked | Client: suppress keystroke forwarding through `InputEventRouter` when `isReadOnly` | 1:1 — blocked before bytes reach the host TCP channel |
| Paste blocked (`⌘V`, middle-click, drag-drop text) | Client: guard paste/drop handlers in `PaneView` | 1:1 |
| Click-to-move blocked | Client: suppress mouse-click events forwarded as cursor-position writes | 1:1 |
| Mouse reporting for TUIs blocked | Client: suppress forwarding of mouse-report escape sequences | 1:1 |
| Drag-and-drop of files/paths blocked | Client: reject drop in `NSDraggingDestination` / SwiftUI `onDrop` | 1:1 |
| Beep on rejected input | libghostty `ghostty_surface_key` with BEL, or `NSSound.beep()` | 1:1 |
| Output unaffected | Host unchanged; video frames keep arriving and displaying | 1:1 — gates only outbound input, never inbound video |
| Scroll / select / copy / search | Already purely client-side (scroll = local scrollback, copy = local selection) | 1:1 |
| Vi/Hint Mode hide the pill | Track `isViMode` / `isHintMode` per-pane; conditionally hide the pill in the header | 1:1 |
| Sudo / Auto-Approve / Secure Input pills hidden | Already separate pill components; add `isReadOnly` visibility guard | 1:1 |
| File panes: lock editing / switch to preview | No built-in file editor pane — **cannot map 1:1 today**. Future editor panes should implement the same `isReadOnly` gate. |
| File pane: `⌘S` blocked with beep | Same caveat — only when/if file editor panes exist. |
| File pane: info panel Status row "Read-only" | Same caveat. |
| File pane: command palette "Edit Mode" / "Make Editable" | Same caveat. |
| No persistent config key | Consistent with per-session state model — no SLOPDESK_READ_ONLY launch flag needed initially. |

### Cannot map 1:1

1. **File pane read-only (text/code/Markdown/SVG/HTML editing):** SlopDesk has no built-in file editor; irrelevant until editor panes are added.
2. **Host-side enforcement:** enforced only at the client input-gate layer, not a PTY/shell-level lock. A motivated remote agent on the host can still write to its own PTY. Acceptable for the stated use case (blocking stray viewer keystrokes), but not a security boundary.
3. **`tail -f` title display:** titlebar auto-names from the running process. SlopDesk must relay pane titles over the wire (OSC 0/2 or shell integration) — existing mechanism, just needs wiring to the pane header.
