# Selection

## Summary

Native text selection and clipboard copy. ⌘C copies the selection; "Copy on Select" drops every selection straight into the clipboard. Under mouse reporting, holding ⌥ (or the bound modifier) forces native selection instead of forwarding the mouse event. Behavior/settings-driven only — no screenshots.

## Behaviors

- **Word selection** — double-click selects the word under the pointer.
- **Line selection** — triple-click selects the full line.
- **Drag selection** — left-click + drag → character-grid selection.
- **Rectangular selection** — ⌥ + drag → column (rectangular) selection.
- **Extend selection** — ⇧ + click extends to the click position.
- **Extend by character/line** — ⇧← / ⇧→ extend by one character; ⇧↑ / ⇧↓ by one line; holding ⌥ makes the extension rectangular.
- **Vi-style keyboard selection** — Vi Mode drives selection with Vi motions (see Vi Mode page).
- **⌘ + arrows** — *caret* moves (line start/end, page up/down), NOT selection; still sent to the program. Distinct from ⇧ + arrows.
- **Copy** — ⌘C copies to clipboard. With "Copy on Select", copy happens automatically on every extension.
- **Force native selection under mouse reporting** — with mouse reporting active, hold ⌥ (or configured modifier) to bypass forwarding and produce a native selection.
- **Cut** — ⌘X deletes the selection regardless of "Backspace Deletes Selection".

### Shift+Arrow Select (on by default)

⇧ + arrow drives a native selection instead of sending an escape sequence: ⇧← / ⇧→ extend by one character, ⇧↑ / ⇧↓ by one line, ⌥ makes it rectangular. Anchor starts at the cursor. With "Copy on Select", each extension copies immediately. ⇧⌘ + arrow is untouched and still reaches the program. Turn off if the running TUI uses ⇧ + arrow itself (keys then forwarded as escape sequences).

### Clear Selection on Typing (on by default)

Drops the active selection the moment any key is sent to the program — input, Backspace, Tab, IME commits, anything. Disable to keep the highlight visible while typing.

### Clear Selection on Copy (off by default)

When on, an explicit copy (⌘C, Edit menu, right-click context menu, or Vi-mode yank) clears the selection highlight afterward. Deliberately does NOT apply when "Copy on Select" is enabled — that mode keeps the selection for continued extension. Default (off) keeps the highlight after copying.

### Backspace Deletes Selection (on by default)

With text selected on the editable prompt line, Backspace deletes the whole selection rather than one character — a convenience most terminals lack. When off, Backspace clears the highlight then erases one character at the cursor (standard behavior). ⌘X (cut) deletes the selection regardless.

## Keybindings

| Action | Keys |
|---|---|
| Copy selection | ⌘C |
| Cut selection | ⌘X |
| Word selection | double-click |
| Line selection | triple-click |
| Drag selection | left-click + drag |
| Rectangular selection | ⌥ + drag |
| Extend selection (click) | ⇧ + click |
| Extend selection by character | ⇧← / ⇧→ |
| Extend selection by line | ⇧↑ / ⇧↓ |
| Extend selection rectangularly | ⌥ + ⇧ + arrow |
| Force native selection (mouse-reporting programs) | ⌥ + drag (or bound modifier) |
| Vi-style keyboard selection | Enter Vi Mode |

Note: ⇧⌘ + arrow is NOT intercepted — still goes to the program (caret move).  
Note: ⌘ + arrows alone are caret moves (line start/end, page up/down), not selection.

## Config keys

| Key | Default | Effect |
|---|---|---|
| Shift+Arrow Select | on | ⇧+arrow drives a native selection (extend by char/line); when off, forwarded as an escape sequence to the program |
| Clear Selection on Typing | on | Drops the active selection when any key is sent to the program; off keeps the highlight while typing |
| Clear Selection on Copy | off | On: explicit copy (⌘C, menu, Vi yank) clears the highlight; does not apply when Copy on Select is also enabled |
| Backspace Deletes Selection | on | Backspace on the editable prompt with a selection deletes the whole selection; off clears the highlight and removes one character at the cursor |
| Copy on Select | off (implied — must be enabled in Settings) | Every selection (and every ⇧+arrow extension) copies to the clipboard automatically |

> Note: "Copy on Select" is a Settings toggle users must explicitly enable; not a per-section key but referenced throughout as an interaction modifier.

## Visual spec

No screenshots on this page — feature is prose + keybinding/behavior table only. Closest visual reference comes from general terminal window rendering (Window, Tab and Split, Cursor and Mouse, Vi Mode pages). Selection highlighting follows the active theme's selection color token.

## Screenshots

(none — this page contains no content screenshots)

## SlopDesk mapping notes

SlopDesk runs libghostty behind a `TerminalSurface` seam on the **client** side; the client renders the terminal locally, so selection is client-side and needs no host round-trip for the gestures.

### Maps 1:1

- **Double-click / triple-click / drag selection** — libghostty supports word, line, and drag selection natively; wire up via `ghosttySelectWord`, `ghosttySelectLine`, `ghosttyExtendSelection` equivalents in `TerminalSurface`. On macOS client, NSView mouse events drive this directly.
- **⌥ + drag rectangular selection** — ghostty supports it; pass the `rect` flag on drag begin.
- **⇧ + click extend** — standard extension, supported by ghostty's selection model.
- **⇧ + arrow extend** — intercept ⇧+arrow in the `SlopDeskClientUI` key handler BEFORE forwarding to the pty; call ghostty's selection extension API. Gate behind "Shift+Arrow Select" (default on); when off, forward as escape sequence.
- **⌘C copy** — read ghostty's current selection, write to `NSPasteboard` / `UIPasteboard`. Partially done via OSC 52 support (CLAUDE.md).
- **⌘X cut** — copy selection then send Delete/Backspace for the selected range on the editable line.
- **Copy on Select** — hook ghostty's selection-change callback; copy to pasteboard on each change if enabled.
- **Clear Selection on Typing** — hook the key-down path in `TerminalSurface`; clear selection before forwarding keystrokes if on (default on).
- **Clear Selection on Copy** — after the ⌘C handler, clear selection if on (default off).
- **⌘ + arrows as caret moves** — must NOT intercept; pass through to the pty.
- **⇧⌘ + arrow passthrough** — must NOT intercept; forward to pty.

### Requires care / partial mapping

- **Backspace Deletes Selection** — requires knowing whether the cursor is on the editable prompt line (shell prompt vs. running program), which relies on Shell Integration (OSC 133) marks. SlopDesk has OSC 133 support (`Blocks/OSC-133`). When marks are present and the cursor is in the prompt zone, intercept Backspace to delete the whole selection; otherwise fall back to standard behavior. iOS client works the same via `UITextInput` / custom key handling.
- **Force native selection under mouse reporting** — when the remote program has mouse reporting enabled (tracked in ghostty's terminal state), ⌥+drag must bypass forwarding and start a native selection. Mouse-reporting passthrough is in `SlopDeskTransport`; add a modifier check before deciding to send the mouse event over the wire vs. handle it locally.

### Cannot map 1:1 (iOS-specific)

- **Drag / rectangular selection** — iOS lacks arbitrary drag-to-select on a custom view at macOS fidelity. The iOS client needs long-press-then-drag (UITextInteraction or custom gesture) and may not support rectangular selection. Mark these macOS-only initially.
- **⇧ + arrow from a hardware keyboard on iOS** — should work if the iOS key handler is wired the same; test with a Bluetooth keyboard. Software keyboard has no Shift+arrow.
- **⌘C / ⌘X on iOS** — hardware keyboard ⌘C/X should work; software keyboard requires a UIMenuController / UIEditMenuInteraction entry for Copy/Cut reading the ghostty selection.

### Remote-host considerations

No selection behavior requires host-side logic — selection, copy, and the preferences are entirely client-side; slopdesk-hostd need not know the user's selection. OSC 52 clipboard manipulation (a remote program SETTING the clipboard) is tracked separately in the OSC 52 reference.
