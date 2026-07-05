# Cursor and Mouse

## Summary

How slopdesk styles the text cursor and handles mouse/pointer input. All GUI-configured — no config file. Cursor: shape, blink, smooth animation, color, opacity. Mouse: hover-to-focus, right-click action, hide-on-type, shift-bypass for captured mouse, click-to-move, mouse-capture permission. Mouse reporting delegates events (clicks, drags, wheel, bare motion) to programs via DECSET modes with SGR coordinate encoding. OSC 22 lets programs set the system pointer shape dynamically.

---

## Behaviors

### Cursor

- Configured in **Settings → Appearance → Cursor** (section header "CURSOR", all-caps small caps).
- **Live preview** at the top of the section renders a fake prompt line (`john@doe-pc$ git commit -m "|"`) with current color/style/opacity/blink applied in real time (`john` green, `@doe-pc` gray-blue, rest white-on-dark).
- **Cursor Style**: dropdown — Block, Block (hollow), Bar, Underline. Active style shown in preview.
- **Cursor Blink** (UI label "Cursor blink style"): dropdown — Default, On, Off. Subtext: "The `Default` option defers to DEC mode 12 to determine blinking state." Default defers to the program (most shells leave it blinking).
- **Cursor Animation**: dropdown — Off, Smooth. Subtext: "Smooth glides the caret on same-row moves and adds an overshoot on click/focus." Smooth animates same-row lateral movement + small elastic overshoot when focus enters.
- **Cursor color**: round filled swatch (default near-black #1a1a1a). Click opens native macOS color picker for the cursor body color.
- **Text color under cursor**: separate swatch (default "Default", lighter gray empty). At Default, the glyph under the cursor follows foreground.
- **Cursor opacity**: numeric value ("1.00") + round mid-gray slider/swatch. Allows fractional cursor-body transparency.
- Programs override the style at runtime via **DECSCUSR** (`CSI <n> SP q`) — e.g. Vim/Neovim get a bar caret in insert mode regardless of the user default. Per-session; reverts on program exit.
- Cursor color and text-under-cursor color also settable from **Settings → Appearance → Theme** ("Cursor" element = body color, "Text color under cursor" = glyph color). Either at Default follows foreground/background.

### Mouse (Settings → Controls → Mouse)

"MOUSE" section header (all-caps small caps); each row = bold label + gray subtext + right-aligned control:

- **Mouse Over to Focus** (toggle, default OFF): Focus the pane under the pointer without clicking. Subtext: "Focus the pane under the mouse cursor automatically."
- **Right-Click Action** (dropdown, default "Context Menu"): options Context Menu, Copy, Paste, Copy or Paste, Ignore. Subtext: "What right-click does in the terminal viewport (Ctrl+right-click always opens the menu)." Ctrl+right-click always opens the menu.
- **Hide Mouse When Typing** (toggle, default ON): Hide the pointer while typing; reappears on next mouse move. Subtext: "Hide the mouse cursor while the keyboard is in use."
- **Allow Shift with Mouse Click** (toggle, default ON): Hold Shift to select text even when the app captures the mouse — the escape hatch for native selection inside mouse-capturing programs. Subtext: "Hold Shift to select text even when the running app captures the mouse."
- **Cursor Click-to-Move** (toggle, default ON): Click in the prompt to move the shell cursor there — slopdesk sends the right number of arrow keys, even across soft-wrapped rows. Subtext: "Click in the prompt to move the shell cursor — sends arrow keys across soft-wrapped rows."
- **Allow Mouse Capture** (toggle, default ON): Allow shell apps to capture mouse events (e.g. vim, tmux). Subtext: "Allow shell apps to capture mouse events (e.g. vim, tmux)."

### Mouse Reporting (program-side)

- When **Allow Mouse Capture** is on and a program enables reporting (vim, htop, tmux), clicks/drags/wheel forward to the program instead of slopdesk's selection engine.
- Tracking modes enabled via DECSET, additive (each adds to the previous):
  - **Normal** (`?1000`): press/release of left/middle/right buttons + scroll wheel.
  - **Button-event** (`?1002`): adds drag tracking — motion while a button is held, one report per cell crossed.
  - **Any-event** (`?1003`): adds bare motion with no button pressed.
- Every report carries live modifier state: Shift, Option (Meta), Control.
- Coordinates encoded in **SGR form** (`?1006`, `CSI < b ; col ; row M/m`), so columns/rows beyond 223 report correctly.
- Drag/motion events de-duplicated at cell boundaries, matching xterm/Ghostty.
- To grab a native selection without leaving a mouse-capturing program: hold **⇧ Shift** while dragging — bypasses capture for that one gesture (requires Allow Shift with Mouse Click ON).

### Mouse Cursor Shape (OSC 22)

- Full-screen TUIs (yazi, btop, mc, ranger) tell slopdesk the pointer shape to show over the pane via `OSC 22` — e.g. pointer over clickable buttons, crosshair over selectable cells, no-entry over read-only regions.
- SlopDesk maps standard CSS cursor names to the closest native macOS pointer.
- Programs reset the shape with `\e]22;default\e\\` (or by exiting).

---

## Keybindings

| Action | Keys |
|--------|------|
| Force context menu (override right-click action) | ⌃ + Right-Click |
| Native text selection (bypass mouse capture) | ⇧ + Drag |

---

## Config keys

All settings are GUI-only (Settings panel). Equivalent config-file keys below, based on the settings labels.

| Key | Default | Effect |
|-----|---------|--------|
| `cursor.style` | `Block` | Caret shape: `Block`, `Block (hollow)`, `Bar`, `Underline`. Overridable at runtime via DECSCUSR. |
| `cursor.blink` | `Default` | Blink: `Default` (defer to DEC mode 12 / program), `On`, `Off`. |
| `cursor.animation` | `Off` | `Off` or `Smooth`. Smooth glides the caret on same-row moves + overshoot on click/focus. |
| `cursor.color` | (theme default) | Cursor body color. Set in Settings → Appearance → Cursor or Theme editor. Default follows foreground. |
| `cursor.textColor` | `Default` | Glyph color under the cursor. Default follows background. |
| `cursor.opacity` | `1.00` | Fractional cursor-body opacity (0.0–1.00). |
| `mouse.overToFocus` | `false` | Auto-focus the pane under the pointer on hover, without clicking. |
| `mouse.rightClickAction` | `Context Menu` | Right-click: `Context Menu`, `Copy`, `Paste`, `Copy or Paste`, `Ignore`. ⌃+right-click always opens the menu. |
| `mouse.hideWhenTyping` | `true` | Hide the pointer while typing; restores on next mouse move. |
| `mouse.allowShiftClick` | `true` | ⇧+drag produces native text selection even when a program has captured the mouse. |
| `mouse.clickToMove` | `true` | Clicking the prompt sends arrow-key sequences to reposition the shell cursor, incl. across soft-wrapped rows. |
| `mouse.allowCapture` | `true` | Allow programs (vim, tmux, htop) to receive raw mouse events via DECSET tracking modes. |

---

## Visual spec

### cursor-style.png — Appearance → Cursor settings panel

**Layout:** macOS settings window, two columns. Left sidebar (~310px) = search pill ("Search", magnifier) atop a vertical icon+label nav list. Right area white, wider, grouped sections separated by all-caps light-gray small-caps headers (e.g. "CURSOR", "DOCK ICON").

**Left nav:** General (circle-i), Shell (>_), Controls (pointer), Editor (document), Agents (plug), **Appearance** (palette — selected: bold label + subtle darker full-row fill, no colored pill), Recipes (book), Key Bindings (lightning), Advanced (wrench).

**CURSOR section:**
- Header "CURSOR", light gray all-caps small-caps, ~12pt, flush to content margin.
- **Live preview box**: rounded-rect inset (~640×60px), light gray border, white bg. Monospace fake prompt: `john` sage green (#4d9375-ish), `@doe-pc` muted blue-gray (#6b8cba range), `$` default fg, ` git commit -m "` near-black + blinking bar cursor (~2px vertical, black). Updates instantly.
- **Cursor color** row: bold label left, ~32px solid near-black (#1a1a1a) circle swatch right (color-picker button).
- **Text color under cursor** row: bold label left, ~32px light-gray (~#d0d0d0) circle swatch right (empty/Default — no custom color).
- **Cursor opacity** row: bold label left, "1.00" gray centered-right, ~32px mid-gray (#888 range) circle swatch right (slider/picker).
- **Cursor Style** row: bold label left; dropdown right (~150px, light border) showing bar-cursor icon + "Bar" + chevrons (⌃⌄).
- **Cursor blink style** row: bold label + gray subtext ("The `Default` option defers to DEC mode 12 to determine blinking state."), dropdown right showing "On" + chevron.
- **Cursor Animation** row: bold label + gray subtext ("Smooth glides the caret on same-row moves and adds an overshoot on click/focus."), dropdown right showing "Smooth" + chevron.
- Ends with "DOCK ICON" header partially visible at bottom.

**Typography/Colors:** Pure white bg. Header text ~#999 small caps. Labels near-black #1a1a1a, 14–15pt medium. Subtext #888–#999, 12–13pt regular. Dropdowns: 1px light-gray border, 6px radius, ~13pt. Row spacing ~20–24px.

---

### mouse-option.png — Controls → Mouse settings panel

**Layout:** Same two-column window; **Controls** row selected (bold + subtle fill). Right pane: "MOUSE" header, 6 rows, then "SECURE INPUT" header + partial row.

**MOUSE section:**
- Header "MOUSE", light gray all-caps small-caps.
- **Mouse Over to Focus**: subtext "Focus the pane under the mouse cursor automatically". Toggle **OFF** — gray/silver (~#c0c0c0), thumb left.
- **Right-Click Action**: subtext "What right-click does in the terminal viewport (Ctrl+right-click always opens the menu)". Dropdown right "Context Menu" + chevron (▾), pill-style (~170px, 1px border, no icon).
- **Hide Mouse When Typing**: subtext "Hide the mouse cursor while the keyboard is in use". Toggle **ON** — vivid green (#34c759), thumb right.
- **Allow Shift with Mouse Click**: subtext "Hold Shift to select text even when the running app captures the mouse". Toggle **ON** — green.
- **Cursor Click-to-Move**: subtext "Click in the prompt to move the shell cursor — sends arrow keys across soft-wrapped rows". Toggle **ON** — green.
- **Allow Mouse Capture**: subtext "Allow shell apps to capture mouse events (e.g. vim, tmux)". Toggle **ON** — green.
- **SECURE INPUT** header, then partially visible "Auto secure input" row with green (ON) toggle.

**Toggle spec:** macOS pill ~44×24px. OFF = gray (#c7c7cc), ON = green (#34c759). White thumb ~20px, left (OFF) / right (ON), 2px inset. No inner label.

**Dropdown spec:** Rounded rect, ~1px #d0d0d0 border, ~6px radius, white fill. Text left near-black, chevron (▾) right gray. ~13pt.

---

### right-click-action.png — Context menu on right-click in terminal viewport

**Layout:** Dark terminal pane (near-black bg, white/light-gray monospace) showing a text file (LICENSE/credits table, `|`-separated columns) with a macOS context menu floating at the cursor.

**Context menu:** native rounded-rect popup with shadow, white/light bg (#f5f5f5 / system menu color), ~22px rows:

1. **Open Link** — regular
2. **Copy Link** — regular
3. **Open in SlopDesk** — regular, submenu arrow ▶
4. — separator (1px #e0e0e0) —
5. **Copy** — ⌘C right-aligned gray
6. **Paste** — ⌘V right-aligned gray
7. **Paste as** — submenu arrow ▶
8. **Composer** — no shortcut
9. **Send to Chat...** — no shortcut
10. — separator —
11. **Select All** — ⌘A
12. **Search...** — `⌘F [T]` (possible modifier hint)
13. — separator —
14. **Split Pane** — submenu arrow ▶
15. **Switch to View** — submenu arrow ▶

**Title bar:** macOS chrome — "user@hostname: ~/path/to/project" centered as window title (shell cwd/hostname, forwarded from host via OSC 7), traffic lights top-left.

**Typography:** menu items ~13pt system font; shortcuts gray #888 ~12pt; selected item (none in shot) would be blue; separators thin #e0e0e0; popup radius ~6–8px.

---

## Screenshots

- `cursor-style.png` — Settings → Appearance → Cursor: live preview, cursor color/opacity/style/blink/animation controls.
- `mouse-option.png` — Settings → Controls → Mouse: all six mouse toggles/dropdowns at default states.
- `right-click-action.png` — Live terminal viewport with the right-click context menu open.

---

## Implementation notes

### Straightforward

- **Cursor style (Block/Bar/Underline/hollow Block)**: libghostty exposes DECSCUSR + cursor style via `ghostty_config_t`; `TerminalConfigBuilder` passes them through; the settings panel mirrors the four options.
- **Cursor blink / animation**: libghostty supports blink mode, configured at session init. "Smooth" (same-row glide + overshoot) must be layered in `TerminalRenderingView` as a SwiftUI/Core Animation interpolator (libghostty renders cells discretely) — achievable client-side.
- **Cursor color and opacity**: `ghostty_config_t` has cursor color fields; opacity is a separate key. Both flow through `TerminalConfigBuilder`.
- **Live preview**: render a small embedded `TerminalSurface` with a fixed synthetic prompt, or approximate with a styled `Text` view — no libghostty needed for the mock.
- **Hide Mouse When Typing**: pure client-side — `NSCursor.setHiddenUntilMouseMoves(true)` on any keyDown in the window. Standard practice.
- **Right-Click Action**: client-side gesture handler in `TerminalRenderingView`. All options local; "Composer"/"Send to Chat" route to slopdesk's agent control when present.
- **⌃+right-click always opens menu**: client-side modifier check on the right-click gesture.
- **Cursor Click-to-Move**: client detects click column/row, computes delta from current cursor (libghostty cursor-state query), synthesizes + injects the arrow-key events into the PTY via the data channel. Must handle soft-wrapped rows (track line-wrap from libghostty's screen model).
- **Mouse reporting (DECSET ?1000/?1002/?1003) + SGR (?1006)**: libghostty implements these; slopdesk forwards the resulting input bytes from client pointer events via the terminal data channel. Already handled if the input path passes raw mouse events to libghostty for encoding.
- **Motion/drag de-duplication at cell boundaries**: libghostty handles it; slopdesk passes pointer position and libghostty decides whether to emit.
- **Modifier state on mouse reports (Shift/Option/Control)**: libghostty encodes from the event's `modifierFlags`.
- **OSC 22 (pointer shape)**: libghostty parses OSC 22 and exposes a callback; the client sets `NSCursor` to the nearest system cursor for the CSS name. Mapping: `default` → arrow, `pointer` → pointingHand, `text` → iBeam, `crosshair` → crosshair, `not-allowed` → operationNotAllowed, `grab`/`grabbing` → openHand/closedHand, `wait` → spinning.

### Needs care

- **Mouse Over to Focus**: hover-to-focus works client-side via `NSTrackingArea` per pane view. Complication: focus must relay to the correct pane's PTY channel on the host (the event triggers a `FOCUS_IN` sequence to the active pane's PTY). Ensure the focus change doesn't flicker the title bar.
- **Allow Shift with Mouse Click (bypass capture)**: once libghostty has handed capture to the program, a ⇧+drag must be intercepted at `TerminalRenderingView` BEFORE libghostty so the client does native selection instead. Requires checking the current mouse-capture mode from libghostty.
- **Allow Mouse Capture toggle**: runtime-switchable gate. When turned off mid-session, send DECRST ?1000/?1002/?1003 to the program — or suppress forwarding. libghostty may handle this if the key is hot-reloadable; otherwise inject disable sequences manually.

### Open design decisions

- **"Open in SlopDesk" submenu**: opens a selected path/link in a new split/tab. Because slopdesk is remote, a path on the remote host can't be opened locally without a protocol extension (e.g. file fetch over the inspector path) — needs a decision on how the submenu resolves.
- **"Composer" / "Send to Chat..."**: agent-integration items (feed selected text to an AI composer/chat). SlopDesk has its own agent-control channel (`SLOPDESK_AGENT_CONTROL`); wire to agent-pane send if applicable, or omit initially.
- **cwd/hostname badge in title bar**: slopdesk already receives OSC 7 (cwd) from the host PTY via the data channel; the client can show `user@host: cwd` in the pane title bar (macOS). iOS title bar is more constrained — show an abbreviated form.
- **"Split Pane" / "Switch to View" submenus**: slopdesk has split-pane support (`WorkspaceStore`); these items open the pane chooser or create a new split. Implement in the right-click menu builder.
- **Cursor opacity**: libghostty may not expose cursor opacity independent of terminal background alpha. Verify `ghostty_config_t` fields; if unsupported, omit or gray out the control.
- **iOS client**: hover-to-focus, right-click action, and hide-mouse-when-typing have no direct iOS equivalent (no physical mouse in the base case; iPad trackpad/mouse would need them). Guard under `#if os(macOS)` for now; for iOS with a pointer device, `UIHoverGestureRecognizer` covers hover and `UIPointerInteraction` covers cursor shape (OSC 22 → `UIPointerStyle`).
