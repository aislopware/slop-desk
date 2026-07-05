# Selection

## Summary

How SlopDesk handles native text selection and copying to the clipboard.
Selected text is copied with ⌘C. A "Copy on Select" setting causes every selection to drop straight into the clipboard automatically. When a program enables mouse reporting, holding ⌥ (or the user's bound modifier) forces native selection instead of forwarding the mouse event to the program.

There are no screenshots on this page; the feature is entirely behavior/settings-driven.

## Behaviors

- **Word selection** — double-click selects the word under the pointer.
- **Line selection** — triple-click selects the full line.
- **Drag selection** — left-click and drag produces a character-grid selection.
- **Rectangular selection** — ⌥ + drag produces a column (rectangular) selection.
- **Extend selection** — ⇧ + click extends the current selection to the click position.
- **Extend by character/line** — ⇧← / ⇧→ extend by one character; ⇧↑ / ⇧↓ extend by one line. Holding ⌥ simultaneously makes the extension rectangular.
- **Vi-style keyboard selection** — enter Vi Mode to drive selection with Vi motions (covered in the Vi Mode page).
- **⌘ + arrows** — these are *caret* moves (line start/end and page up/down), NOT selection; they still go to the program. This is distinct from ⇧ + arrows.
- **Copy** — ⌘C copies selected text to the clipboard. With "Copy on Select" enabled, copying happens automatically on every selection extension.
- **Force native selection under mouse reporting** — when a program has mouse reporting active, hold ⌥ (or the configured modifier) to bypass mouse-event forwarding and produce a native selection.
- **Cut** — ⌘X deletes the selection regardless of the "Backspace Deletes Selection" setting.

### Shift+Arrow Select (on by default)

When enabled, ⇧ + arrow keys drive a native selection rather than sending an escape sequence to the running program. ⇧← / ⇧→ extend by one character; ⇧↑ / ⇧↓ extend by one line. Holding ⌥ simultaneously makes the selection rectangular. The anchor starts at the current cursor position. With "Copy on Select" also enabled, each incremental extension copies immediately. ⇧⌘ + arrow is left untouched and still reaches the program. Turn this off if the running TUI uses ⇧ + arrow for its own purposes (the keys will then be forwarded as escape sequences).

### Clear Selection on Typing (on by default)

The active selection is dropped the moment any key is sent to the program — ordinary input, Backspace, Tab, IME commits, or anything else that goes to the program. Disable to keep the highlight visible while typing.

### Clear Selection on Copy (off by default)

When enabled, an explicit copy (⌘C, the Edit menu, the right-click context menu, or a Vi-mode yank) clears the selection highlight afterward. This setting deliberately does NOT apply when "Copy on Select" is enabled — that mode keeps the selection so the user can continue extending it. When disabled (the default), the selection stays highlighted after copying.

### Backspace Deletes Selection (on by default)

When text is selected on the editable prompt line and Backspace is pressed, the whole selection is deleted rather than a single character at the cursor. This is a convenience not offered by most terminals. When disabled, Backspace clears the highlight and then erases one character at the cursor (standard terminal behavior). ⌘X (cut) deletes the selection regardless of this setting.

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

Note: ⇧⌘ + arrow is NOT intercepted — it still goes to the program (caret move).  
Note: ⌘ + arrows alone are caret moves (line start/end, page up/down), not selection.

## Config keys

| Key | Default | Effect |
|---|---|---|
| Shift+Arrow Select | on | ⇧+arrow drives a native selection (extend by char/line); when off, ⇧+arrow is forwarded as an escape sequence to the running program |
| Clear Selection on Typing | on | Drops the active selection the moment any key is sent to the program; turn off to keep the highlight visible while typing |
| Clear Selection on Copy | off | When on, an explicit copy (⌘C, menu, Vi yank) clears the selection highlight; does not apply when Copy on Select is also enabled |
| Backspace Deletes Selection | on | Backspace on the editable prompt with a selection deletes the whole selection; when off, Backspace clears the highlight and removes one character at the cursor |
| Copy on Select | off (implied — must be enabled in Settings) | Every selection (and every ⇧+arrow extension) copies to the clipboard automatically |

> Note: "Copy on Select" is described as a Settings toggle that users must explicitly enable; it is not listed as a per-section key but is referenced throughout this page as an interaction modifier for other behaviors.

## Visual spec

No screenshots exist on this documentation page. The entire feature is described via prose and a keybinding/behavior table. There is no dedicated visual UI to reference from this specific page.

The closest visual reference will come from the general terminal window rendering (covered in the Window, Tab and Split, Cursor and Mouse, and Vi Mode pages). Selection highlighting should follow the active theme's selection color token.

## Screenshots

(none — this page contains no content screenshots)

## SlopDesk mapping notes

SlopDesk runs libghostty behind a `TerminalSurface` seam on the **client** side. The client renders the terminal locally; selection is a client-side concern and does not need a host round-trip for the gestures themselves. Mapping notes:

### Maps 1:1

- **Double-click / triple-click / drag selection** — libghostty (ghostty terminal emulator) supports word, line, and drag selection natively. Wire up via `ghosttySelectWord`, `ghosttySelectLine`, `ghosttyExtendSelection` equivalents in `TerminalSurface`. On macOS client, NSView mouse events drive this directly.
- **⌥ + drag rectangular selection** — ghostty supports rectangular selection; pass the `rect` flag on drag begin.
- **⇧ + click extend** — standard selection extension; supported by ghostty's selection model.
- **⇧ + arrow extend** — intercept ⇧+arrow in the `SlopDeskClientUI` key handler BEFORE forwarding to the pty; call ghostty's selection extension API. Gate behind the "Shift+Arrow Select" preference key (default on). When off, forward as escape sequence as normal.
- **⌘C copy** — read the current selection from ghostty's surface and write to `NSPasteboard` / `UIPasteboard`. Already partially done via OSC 52 support noted in CLAUDE.md.
- **⌘X cut** — copy selection then send Delete/Backspace sequence for the selected range on the editable line.
- **Copy on Select** — hook into ghostty's selection-change callback; on each change, copy to pasteboard if the preference is enabled.
- **Clear Selection on Typing** — hook into the key-down path in `TerminalSurface`; clear selection before forwarding keystrokes if preference is on (default on).
- **Clear Selection on Copy** — after ⌘C handler runs, clear selection if preference is on (default off).
- **⌘ + arrows as caret moves** — must NOT intercept ⌘+arrow for selection; ensure those pass through to the pty.
- **⇧⌘ + arrow passthrough** — must NOT intercept ⇧⌘+arrow; must forward to pty.

### Requires care / partial mapping

- **Backspace Deletes Selection** — this requires knowing whether the cursor is on the "editable prompt line" (i.e., shell prompt, not inside a running program). This relies on Shell Integration (OSC 133) marks to distinguish prompt vs. program context. SlopDesk already has OSC 133 support listed in CLAUDE.md (`Blocks/OSC-133`). When OSC 133 marks are present and the cursor is in the prompt zone, intercept Backspace to delete the whole selection; otherwise fall back to standard behavior. On iOS client, this works the same way via `UITextInput` / custom key handling.
- **Force native selection under mouse reporting** — when the remote program has mouse reporting enabled (tracked in ghostty's terminal state), ⌥+drag must bypass mouse-event forwarding and instead start a native selection. SlopDesk's mouse reporting passthrough is in `SlopDeskTransport`; add a modifier check before deciding whether to send the mouse event over the wire or handle it locally as a selection.

### Cannot map 1:1 (iOS-specific)

- **Drag selection / rectangular selection** — iOS does not expose arbitrary drag-to-select on a custom view with the same fidelity as macOS. The iOS client will need to use long-press-then-drag (UITextInteraction or custom gesture) and may not support rectangular selection. Mark these as macOS-only features in the iOS client initially.
- **⇧ + arrow from a hardware keyboard on iOS** — should work if the iOS key handler is wired up the same way; test with a Bluetooth keyboard. Software keyboard has no arrow keys with Shift.
- **⌘C / ⌘X on iOS** — hardware keyboard ⌘C/X should work; software keyboard requires a UIMenuController / UIEditMenuInteraction entry for Copy/Cut that reads from the ghostty selection.

### Remote-host considerations

None of the selection behaviors require host-side logic. Selection, copy, and the associated preferences are entirely client-side. The host (slopdesk-hostd) does not need to know about the user's selection. OSC 52 clipboard manipulation (which lets a remote program SET the clipboard) is already tracked separately in the OSC 52 reference.
