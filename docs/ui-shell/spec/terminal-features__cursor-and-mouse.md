# Cursor and Mouse

## Summary

How slopdesk styles the text cursor and handles mouse / pointer input. Everything is configured in the GUI — no config file needed. Cursor styling covers shape, blink mode, smooth animation, color, and opacity. Mouse covers hover-to-focus, right-click action, hide-on-type, shift-bypass for captured mouse, click-to-move, and mouse-capture permission. Mouse reporting delegates events (clicks, drags, wheel, bare motion) to programs via DECSET modes with SGR coordinate encoding. OSC 22 allows programs to set the system pointer shape dynamically.

---

## Behaviors

### Cursor

- The text caret is configurable in **Settings → Appearance → Cursor** (displayed as a section header "CURSOR" in all-caps small caps inside the Appearance settings pane).
- A **live preview** of cursor color, style, opacity, and blink behavior is shown at the top of the Cursor section. The preview renders a fake terminal prompt line (`john@doe-pc$ git commit -m "|"`) with the current cursor shape and color applied in real time. The prompt uses green for `john`, gray-blue for `@doe-pc`, and monospace white-on-dark text for the rest.
- **Cursor Style**: dropdown with four options: Block, Block (hollow), Bar, Underline. The currently active style is previewed in the live-preview box.
- **Cursor Blink** (labeled "Cursor blink style" in the UI): dropdown with Default, On, Off. Subtext reads: "The `Default` option defers to DEC mode 12 to determine blinking state." Default defers to the program — most shells leave it blinking.
- **Cursor Animation**: dropdown with Off, Smooth. Subtext reads: "Smooth glides the caret on same-row moves and adds an overshoot on click/focus." Smooth mode animates lateral movement within the same row and adds a small elastic overshoot when focus enters.
- **Cursor color**: color swatch (round filled circle, defaults to near-black #1a1a1a / very dark). Clicking opens the native macOS color picker to set the cursor body color.
- **Text color under cursor**: separate color swatch (defaults to "Default" — shown as a lighter gray empty swatch). When left at Default, the glyph color under the cursor follows the foreground automatically.
- **Cursor opacity**: numeric value (shown as "1.00") with a round circular slider/swatch to the right (mid-gray circle). Allows fractional transparency of the cursor body.
- Programs can override the cursor style at runtime via **DECSCUSR** (`CSI <n> SP q`). A TUI that wants a bar caret in insert mode (Vim, Neovim) gets it regardless of the user default. This override is per-session and reverts when the program exits.
- Cursor color and text-under-cursor color are also accessible from **Settings → Appearance → Theme**: clicking the "Cursor" element sets the body color, and "Text color under cursor" sets the character color beneath it. Leaving either at Default follows foreground/background automatically.

### Mouse (Settings → Controls → Mouse)

The Settings panel shows a "MOUSE" section header (all-caps small caps) with the following settings rows, each with a bold label, a smaller gray subtext description, and a control (toggle or dropdown) right-aligned:

- **Mouse Over to Focus** (toggle, default OFF — toggle shown in gray/off state): Focus the pane under the mouse cursor automatically, without clicking. Subtext: "Focus the pane under the mouse cursor automatically."
- **Right-Click Action** (dropdown, default "Context Menu"): What right-click does in the terminal viewport. Options: Context Menu, Copy, Paste, Copy or Paste, Ignore. Subtext: "What right-click does in the terminal viewport (Ctrl+right-click always opens the menu)." Ctrl+right-click always opens the context menu regardless of this setting.
- **Hide Mouse When Typing** (toggle, default ON — green): Hide the pointer while the keyboard is in use; it reappears on the next mouse move. Subtext: "Hide the mouse cursor while the keyboard is in use."
- **Allow Shift with Mouse Click** (toggle, default ON — green): Hold Shift to select text even when the running app captures the mouse. This is the escape hatch for native selection inside mouse-capturing programs. Subtext: "Hold Shift to select text even when the running app captures the mouse."
- **Cursor Click-to-Move** (toggle, default ON — green): Click in the prompt to move the shell cursor there — slopdesk sends the right number of arrow keys, even across soft-wrapped rows. Subtext: "Click in the prompt to move the shell cursor — sends arrow keys across soft-wrapped rows."
- **Allow Mouse Capture** (toggle, default ON — green): Allow shell apps to capture mouse events (e.g. vim, tmux). Subtext: "Allow shell apps to capture mouse events (e.g. vim, tmux)."

### Mouse Reporting (program-side)

- When **Allow Mouse Capture** is on and a program enables reporting (vim, htop, tmux), clicks, drags, and scroll wheel are forwarded to the program instead of slopdesk's selection engine.
- Tracking modes are enabled via DECSET and are additive (each adds to the previous):
  - **Normal mode** (`?1000`): Press and release of left/middle/right buttons plus scroll wheel.
  - **Button-event mode** (`?1002`): Adds drag tracking — motion while a button is held (drag), one report per cell the pointer crosses.
  - **Any-event mode** (`?1003`): Adds bare motion with no button pressed.
- Every report carries live modifier state: Shift, Option (Meta), Control.
- Coordinates are encoded in **SGR form** (`?1006`, `CSI < b ; col ; row M/m`), so columns and rows beyond 223 are reported correctly.
- Drag and motion events are de-duplicated at cell boundaries, matching xterm / Ghostty behavior.
- To grab a native selection without leaving a mouse-capturing program: hold **⇧ Shift** while dragging — this bypasses mouse capture for that one selection gesture (requires Allow Shift with Mouse Click to be ON).

### Mouse Cursor Shape (OSC 22)

- Full-screen TUIs (yazi, btop, mc, ranger) can tell slopdesk what pointer shape to show over the pane via `OSC 22`.
- Examples: pointer over clickable buttons, crosshair over selectable cells, no-entry over read-only regions.
- SlopDesk maps standard CSS cursor names to the closest native macOS system pointer.
- Programs reset the shape with `\e]22;default\e\\` (or by simply exiting).

---

## Keybindings

| Action | Keys |
|--------|------|
| Force context menu (override right-click action) | ⌃ + Right-Click |
| Native text selection (bypass mouse capture) | ⇧ + Drag |

---

## Config keys

All settings are GUI-only (Settings panel). The equivalent config-file keys are listed below based on the settings labels.

| Key | Default | Effect |
|-----|---------|--------|
| `cursor.style` | `Block` | Shape of the text caret: `Block`, `Block (hollow)`, `Bar`, or `Underline`. Overridable at runtime by programs via DECSCUSR. |
| `cursor.blink` | `Default` | Blink mode: `Default` (defer to DEC mode 12 / program), `On`, or `Off`. |
| `cursor.animation` | `Off` | `Off` or `Smooth`. Smooth glides the caret on same-row moves and adds an overshoot on click/focus. |
| `cursor.color` | (theme default) | Body color of the cursor. Set in Settings → Appearance → Cursor or via Theme editor. Default follows foreground automatically. |
| `cursor.textColor` | `Default` | Color of the glyph rendered under the cursor. Default follows background automatically. |
| `cursor.opacity` | `1.00` | Fractional opacity of the cursor body (0.0–1.00). |
| `mouse.overToFocus` | `false` | Auto-focus the pane under the pointer on hover, without clicking. |
| `mouse.rightClickAction` | `Context Menu` | What right-click does: `Context Menu`, `Copy`, `Paste`, `Copy or Paste`, `Ignore`. ⌃+right-click always opens the menu regardless. |
| `mouse.hideWhenTyping` | `true` | Hide the system pointer while the keyboard is in use; restores on next mouse move. |
| `mouse.allowShiftClick` | `true` | Allow ⇧+drag to produce a native text selection even when a program has captured the mouse. |
| `mouse.clickToMove` | `true` | Clicking in the shell prompt sends arrow key sequences to reposition the shell cursor, including across soft-wrapped rows. |
| `mouse.allowCapture` | `true` | Allow programs (vim, tmux, htop) to receive raw mouse events via DECSET mouse tracking modes. |

---

## Visual spec

### cursor-style.png — Appearance → Cursor settings panel

**Overall layout:** macOS settings window with a two-column layout. Left sidebar (~310 px wide) has a search bar at the top (rounded gray pill, "Search" placeholder, magnifier icon), followed by a vertical nav list of icon+label rows at medium density. Right content area is white, wider, with grouped settings sections separated by all-caps section headers in light gray small caps (e.g. "CURSOR", "DOCK ICON").

**Left sidebar nav:** Items listed with small SF Symbol-style icons and medium-weight labels: General (circle-i icon), Shell (>_ icon), Controls (pointer/arrow icon), Editor (document icon), Agents (plug icon), **Appearance** (palette/circle icon — selected, shown with bold label and slightly darker background fill across the full row width), Recipes (book icon), Key Bindings (lightning icon), Advanced (wrench icon). Active item ("Appearance") uses bold text; the row does not have a distinct colored highlight pill — just subtle background shift and bolding.

**CURSOR section:**
- Section header "CURSOR" in light gray all-caps small-caps, ~12pt, flush left with content margin.
- **Live preview box**: a rounded-rect inset box (~640 px wide, ~60 px tall) with light gray border on white background. Renders a fake terminal prompt in monospace: `john` in green (#4d9375 or similar sage green), `@doe-pc` in muted blue-gray (#6b8cba range), `$` in default foreground, followed by ` git commit -m "` in near-black and a blinking bar cursor (thin vertical bar, ~2px, black). This preview updates instantly as settings change.
- **Cursor color** row: bold label left-aligned, large filled circle swatch right-aligned (~32px diameter, solid near-black #1a1a1a). Circle is a color-picker button.
- **Text color under cursor** row: bold label left-aligned, large circle swatch right-aligned in light gray (empty / default state, approximately #d0d0d0 fill), indicating "Default" — no custom color set.
- **Cursor opacity** row: bold label left-aligned, numeric value "1.00" in gray centered-right, and a gray circle swatch right-aligned (~32px). The circle is mid-gray (#888 range), acting as a slider/picker for opacity.
- **Cursor Style** row: bold label left-aligned. Right side shows a dropdown/picker control with a small vertical bar icon (bar cursor shape) followed by the text "Bar" and a chevron-up/down symbol (⌃⌄). The dropdown control has a light border, ~150px wide.
- **Cursor blink style** row: bold label, smaller gray subtext on the next line ("The `Default` option defers to DEC mode 12 to determine blinking state."), and a dropdown right-aligned showing "On" with chevron.
- **Cursor Animation** row: bold label, smaller gray subtext on next line ("Smooth glides the caret on same-row moves and adds an overshoot on click/focus."), and a dropdown right-aligned showing "Smooth" with chevron.
- Section ends, followed by "DOCK ICON" section header partially visible at bottom.

**Typography/Colors:** Background pure white. Section header text ~#999, small caps. Setting labels in near-black #1a1a1a, 14–15pt medium weight. Subtext in #888–#999, 12–13pt, regular weight. Controls (dropdowns) have 1px light gray border, 6px corner radius, ~13pt text. Spacing between rows ~20–24px vertical.

---

### mouse-option.png — Controls → Mouse settings panel

**Overall layout:** Same two-column macOS settings window. Left sidebar identical structure; **Controls** row is selected (bold, subtle background fill). Right pane shows "MOUSE" section header, then 6 settings rows, then "SECURE INPUT" section header + partial row.

**MOUSE section:**
- Section header "MOUSE" in light gray all-caps small-caps.
- **Mouse Over to Focus** row: bold label "Mouse Over to Focus", gray subtext "Focus the pane under the mouse cursor automatically". Toggle on far right — in **OFF state**: toggle pill is gray/silver (#c0c0c0 range, not green), circle thumb pushed left.
- **Right-Click Action** row: bold label "Right-Click Action", gray subtext "What right-click does in the terminal viewport (Ctrl+right-click always opens the menu)". Dropdown on right showing "Context Menu" with a chevron (▾), wider pill-style dropdown (~170px, rounded with 1px border). No icon in the dropdown.
- **Hide Mouse When Typing** row: bold label, gray subtext "Hide the mouse cursor while the keyboard is in use". Toggle on far right — **ON state**: vivid green (#34c759 iOS green), circle thumb pushed right.
- **Allow Shift with Mouse Click** row: bold label, gray subtext "Hold Shift to select text even when the running app captures the mouse". Toggle — **ON state**: green.
- **Cursor Click-to-Move** row: bold label, gray subtext "Click in the prompt to move the shell cursor — sends arrow keys across soft-wrapped rows". Toggle — **ON state**: green.
- **Allow Mouse Capture** row: bold label "Allow Mouse Capture", gray subtext "Allow shell apps to capture mouse events (e.g. vim, tmux)". Toggle — **ON state**: green.
- **SECURE INPUT** section header in light gray all-caps, followed by partially visible "Auto secure input" row with green toggle (ON).

**Toggle visual spec:** macOS-style toggle switch, ~44px wide × 24px tall, pill shape. OFF = gray (#c7c7cc), ON = green (#34c759). White circular thumb ~20px diameter, positioned left (OFF) or right (ON) with 2px inset. No label text inside toggle.

**Dropdown visual spec:** Rounded rect, ~1px #d0d0d0 border, ~6px corner radius, white fill. Text left-aligned in near-black, chevron (▾) right-aligned in gray. Font ~13pt.

---

### right-click-action.png — Context menu shown on right-click in terminal viewport

**Overall layout:** A terminal pane (dark background) showing a text file (LICENSE/credits table in monospace, columns separated by `|`) with a macOS context menu overlaid. The terminal content is dark — near-black background with white/light-gray monospace text. The menu appears at cursor position, floating above the terminal content.

**Context menu visual:** macOS native-style rounded-rect popup menu with shadow. White/light background (#f5f5f5 or system menu color). Menu items listed vertically at standard macOS menu density (~22px row height):

1. **Open Link** — regular weight
2. **Copy Link** — regular weight
3. **Open in SlopDesk** — regular weight (with right-pointing disclosure arrow ▶ indicating submenu)
4. — separator line (1px #e0e0e0) —
5. **Copy** — with ⌘C shortcut label right-aligned in gray
6. **Paste** — with ⌘V shortcut label right-aligned in gray
7. **Paste as** — with right-pointing disclosure arrow ▶
8. **Composer** — no shortcut
9. **Send to Chat...** — no shortcut
10. — separator line —
11. **Select All** — with ⌘A shortcut
12. **Search...** — with ⌘F shortcut shown as `⌘F [T]` (possible modifier hint)
13. — separator line —
14. **Split Pane** — with right-pointing disclosure arrow ▶
15. **Switch to View** — with right-pointing disclosure arrow ▶

**Title bar:** macOS window chrome at top — "user@hostname: ~/path/to/project" in center as window title (shell prompt cwd/hostname, forwarded from the host via OSC 7), traffic light buttons (red/yellow/green) at top-left.

**Typography:** Menu item text ~13pt, system font. Shortcuts in gray #888, ~12pt. Selected item (none highlighted in screenshot) would show blue highlight. Separator lines thin #e0e0e0. Corner radius of menu popup ~6–8px.

---

## Screenshots

- `cursor-style.png` — Settings → Appearance → Cursor panel showing live preview, cursor color/opacity/style/blink/animation controls
- `mouse-option.png` — Settings → Controls → Mouse panel showing all six mouse toggles/dropdowns with their default states
- `right-click-action.png` — Live terminal viewport with the context menu open showing all right-click menu items

---

## Implementation notes

### Straightforward

- **Cursor style (Block/Bar/Underline/hollow Block)**: libghostty exposes DECSCUSR and cursor style via `ghostty_config_t`. SlopDesk's `TerminalConfigBuilder` can pass these through; the client UI settings panel mirrors the four options.
- **Cursor blink / animation**: libghostty supports blink mode and can be configured at session init. "Smooth" animation (same-row glide + overshoot) would need to be layered in `TerminalRenderingView` as a SwiftUI/Core Animation interpolator since libghostty renders cells discretely — achievable client-side.
- **Cursor color and opacity**: `ghostty_config_t` has cursor color fields. Cursor opacity is a separate config key. Both flow through `TerminalConfigBuilder`.
- **Live preview in settings**: render a small embedded `TerminalSurface` with a fixed synthetic prompt, or approximate it with a styled `Text` view — no libghostty dependency required for the UI mock.
- **Hide Mouse When Typing**: pure client-side macOS behavior — `NSCursor.setHiddenUntilMouseMoves(true)` on any keyDown event in the window. Already standard practice.
- **Right-Click Action (Context Menu / Copy / Paste / Copy or Paste / Ignore)**: client-side gesture handler in `TerminalRenderingView`. All options are local; the "Composer" and "Send to Chat" items in the context menu are agent-integration features that route to slopdesk's agent control when present.
- **⌃+right-click always opens menu**: client-side modifier check on right-click gesture.
- **Cursor Click-to-Move**: the client detects a click position in the terminal grid (column/row), computes the delta from the current cursor position using libghostty's cursor state query, then synthesizes and injects the appropriate number of arrow key events into the PTY via the data channel. Must handle soft-wrapped rows (track line-wrap state from libghostty's screen model).
- **Mouse reporting modes (DECSET ?1000/?1002/?1003) + SGR encoding (?1006)**: libghostty implements these; slopdesk forwards the resulting input bytes from the client's pointer events via the terminal data channel. Already handled if the input path passes raw mouse events to libghostty for encoding.
- **Motion/drag de-duplication at cell boundaries**: libghostty handles this; slopdesk passes pointer position and libghostty decides whether to emit a report.
- **Modifier state on mouse reports (Shift/Option/Control)**: libghostty encodes these from the event's `modifierFlags`.
- **OSC 22 (pointer shape)**: libghostty parses OSC 22 and exposes a callback. The slopdesk client side responds by setting `NSCursor` to the nearest system cursor matching the CSS name. Standard mapping: `default` → arrow, `pointer` → pointingHand, `text` → iBeam, `crosshair` → crosshair, `not-allowed` → operationNotAllowed, `grab`/`grabbing` → openHand/closedHand, `wait` → spinning.

### Needs care

- **Mouse Over to Focus (hover-to-focus panes)**: SlopDesk supports multiple panes in a split view. Hover-to-focus works client-side via `NSTrackingArea` on each pane's view. The complication is that focus must be relayed to the correct pane's PTY channel on the host — the focus event triggers a `FOCUS_IN` terminal sequence sent to the active pane's PTY. Straightforward, but ensure focus change doesn't cause visible flicker in the title bar.
- **Allow Shift with Mouse Click (bypass mouse capture)**: When libghostty has handed mouse capture to the program, a ⇧+drag must be intercepted at the `TerminalRenderingView` level BEFORE passing to libghostty, so the client performs native text selection instead. Requires checking the current mouse-capture mode state from libghostty.
- **Allow Mouse Capture toggle**: This is a runtime-switchable gate. When turned off mid-session, slopdesk must send DECRST ?1000/?1002/?1003 to the program — or simply suppress forwarding. libghostty may handle this if the config key is hot-reloadable; otherwise inject disable sequences manually.

### Open design decisions

- **"Open in SlopDesk" context menu item (submenu)**: The right-click menu includes "Open in SlopDesk" with a submenu for opening a selected path or link in a new split/tab. Because slopdesk is a remote tool, a path on the remote host cannot be opened locally in a native viewer without a protocol extension (e.g., file fetch over the inspector path) — needs a design decision on how that submenu resolves.
- **"Composer" and "Send to Chat..." context menu items**: These are agent-integration items (feed selected text to an AI composer or chat). SlopDesk has its own agent-control channel (`SLOPDESK_AGENT_CONTROL`); wire these to agent pane send if applicable, or omit initially.
- **cwd/hostname badge in the title bar**: SlopDesk already receives OSC 7 (current working directory) from the host PTY via the data channel; the client can display `user@host: cwd` in the pane title bar. This works for the macOS client. For iOS, the title bar is more constrained — show an abbreviated form.
- **"Split Pane" and "Switch to View" context menu submenus**: SlopDesk has split-pane support (`WorkspaceStore`). These context menu items can open the pane chooser or create a new split. Implement as part of the right-click menu builder.
- **Cursor opacity**: libghostty may not expose a cursor opacity config independently of the terminal background alpha. Verify `ghostty_config_t` fields before exposing the setting; if unsupported, omit or gray out the control in the slopdesk settings panel.
- **iOS client**: Mouse hover-to-focus, right-click action, and hide-mouse-when-typing have no direct iOS equivalent (no physical mouse in the base case, though iPad with trackpad/mouse would need these). Implement under a `#if os(macOS)` guard for now; for iOS with pointer device, `UIHoverGestureRecognizer` covers hover and `UIPointerInteraction` covers cursor shape (OSC 22 mapping to `UIPointerStyle`).
