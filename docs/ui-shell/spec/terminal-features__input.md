# Input

## Summary

SlopDesk treats a shell prompt like a native macOS text field wherever it can, so the muscle memory from any other Mac app carries over to the terminal. This page covers how the keyboard is handled: native macOS editing chords, international input (IME), the Kitty keyboard protocol, Secure Keyboard Entry (automatic and manual), the Composer multi-line editor, and the Prompt Queue batch-command runner. Everything is configured in the GUI; every shortcut below is a factory default re-bindable in Settings → Key Bindings.

---

## Behaviors

- **Click to focus**: clicking any pane hands it the keyboard; the clicked pane "lights up" and starts receiving input. Clicking the pane that already has focus simply keeps it. Optionally, enable "Mouse Over to Focus" (see Cursor and Mouse) to follow the pointer instead of the click.

- **Natural Text Editing**: standard macOS editing and navigation chords work at the shell prompt identically to a native text field. The caret/word/line-delete chords send the readline sequence the shell expects, so they work the same in every shell. Each is an ordinary keybinding re-bindable or disableable under Settings → Key Bindings ▸ Text Editing.

- **Undo / Redo**: `⌘Z` undoes shell-prompt editing; `⌘⇧Z` (or `⌘Y`) redoes it. Rapid typing coalesces into a single undo step so `⌘Z` does not crawl back character by character. Undo applies to the current prompt line; it is unavailable inside full-screen programs (vim, less, editors) which manage their own undo history.

- **Cut (`⌘X`)**: always copies the selection to the clipboard. If the selection is editable text on the prompt line, slopdesk also deletes it. On read-only text (scrollback, program output) it falls back to a plain copy. Also accessible at Edit ▸ Cut.

- **Input methods (IME)**: full support for Chinese, Japanese, Korean input plus dead keys for accented characters (é, ü, etc.), identical to any other macOS app. Composing (marked) text is shown inline at the prompt and the candidate window tracks the cursor; committed text is sent to the shell on confirmation.

- **Kitty keyboard protocol** (Settings → Advanced, on by default): sends modern unambiguous CSI u key encodings. Lets programs distinguish keys the legacy encoding collapses together (Tab vs ⌃I, Esc vs ⌃[, modified keys, key-release events). Programs opt in when they launch; anything that does not request it falls back to classic encoding automatically. Disable only if a specific program misbehaves.

- **Option key behavior for word chords**: the word chords (⌥← ⌥→ ⌥⌫ ⌥⌦) work whether or not "Option as Alt" is enabled. If you want Option to reach a TUI as raw Alt/Meta, unbind those chords under Settings → Key Bindings.

- **Secure Keyboard Entry — Automatic**: with "Auto Secure Input" on (Settings → Controls, on by default), slopdesk enables macOS Secure Keyboard Entry the moment the active session requests a hidden password (sudo, ssh, login prompts) and releases it afterward.

- **Secure Keyboard Entry — Manual**: toggle at any time from Edit ▸ Secure Keyboard Entry. While active, a title-bar pill shows the state. Hide the pill by turning off "Secure Input Indicator" (Settings → Controls).

- **Composer**: a roomy multi-line editor that slides up from the bottom of the focused pane. Useful for building a long command, a here-doc, or a multi-line prompt before running. Open via Edit ▸ Composer (⌘⇧E), Command Palette, or the terminal's right-click menu. Draft is preserved on cancel. The Composer matches the terminal theme and can be popped out into a floating window that stays on top while you work elsewhere.

- **Prompt Queue**: lines up several commands and fires them one at a time, each waiting for the previous command to finish and a fresh prompt to appear — no babysitting needed. Open via Edit ▸ Prompt Queue… (⌘⇧M) or Command Palette. A small card appears at the bottom of the pane. Type a line and press ↵ to add it; use the arrow button on a row to send it immediately, or the trash button to drop it. SlopDesk dispatches the next item only when the shell is back at an idle, empty prompt, so it won't clobber mid-typing. Full-screen TUIs pause the queue; for agent panes it waits for the agent to go idle between turns. The Composer can hand its lines directly to the Prompt Queue.

- **Services**: when text is selected in a pane, slopdesk offers it to any macOS Service that accepts text, piping the selection into another app from the Services menu.

- **Insert from device** (Edit ▸ Insert from): provides File Path…, Screenshot, and Import from iPhone or iPad. The last uses Continuity Camera (photo, document scan, or sketch on a nearby iPhone/iPad); slopdesk saves the result to a temp file and drops the shell-escaped path into the prompt.

---

## Keybindings

### Natural Text Editing (Settings → Key Bindings ▸ Text Editing)

| Action | Keys |
|--------|------|
| Select all | `⌘A` |
| Copy | `⌘C` |
| Cut | `⌘X` |
| Paste | `⌘V` |
| Undo | `⌘Z` |
| Redo | `⌘⇧Z` or `⌘Y` |
| Find | `⌘F` |
| Find Next | `⌘G` |
| Find Previous | `⌘⇧G` |
| Move to start of line | `⌘←` |
| Move to end of line | `⌘→` |
| Move one word left | `⌥←` |
| Move one word right | `⌥→` |
| Delete to start of line | `⌘⌫` |
| Delete to end of line | `⌘⌦` |
| Delete word to the left | `⌥⌫` |
| Delete word to the right | `⌥⌦` |
| Page Up | `⌘↑` |
| Page Down | `⌘↓` |
| Extend selection | `⇧` + arrows |

### Composer

| Action | Keys |
|--------|------|
| Send (paste draft to terminal and close) | `⌘↵` |
| Insert newline (keep editing) | `⇧↵` |
| Cancel (close without sending; draft preserved) | `⎋` |
| Toggle Composer open/closed | `⌘⇧E` |

### Prompt Queue

| Action | Keys |
|--------|------|
| Open Prompt Queue | `⌘⇧M` |
| Add line to queue | `↵` (in queue input field) |

---

## Config keys

### Settings → Controls

| Key | Default | Effect |
|-----|---------|--------|
| Option as Alt | Off | Treat macOS Option key as Alt/Meta so terminal apps see Esc-prefixed sequences (Emacs, Vim word-jumps, readline). Off keeps Option free for accented characters (¡, é, ©…). Can be applied to both Option keys or just left/right independently. |
| Shift+Arrow Select | On | ⇧+arrows drive native selection instead of sending arrow escapes to the terminal. Turn off to pass ⇧+arrows through to a TUI. |
| Allow VT100 Application Keypad Mode | On | Honor a program's DECKPAM request to put the numeric keypad into application mode, so vim/emacs/less keypad bindings work. Off makes keypad keys always type literal digits. |
| Auto Secure Input | On | Automatically enable macOS Secure Keyboard Entry when the active session requests a hidden password, release it afterward. |
| Secure Input Indicator | On | Show the "SECURE INPUT" pill in the title bar whenever Secure Keyboard Entry is active. Turn off to hide the pill. |

### Settings → Advanced

| Key | Default | Effect |
|-----|---------|--------|
| Kitty Keyboard Protocol | On | Send modern unambiguous CSI u key encodings to programs that opt in; fall back to classic encoding for programs that do not request it. |

---

## Visual spec

### secure-input.png — Secure Keyboard Entry title-bar indicator

**Overall layout**: a standard macOS terminal window shown at roughly 1/3 screen height. The window uses native rounded corners with a drop shadow, light/white background. Three traffic-light window control buttons (red, yellow, green) appear in the upper-left at standard macOS spacing (~8px from edges, ~20px diameter each).

**Title bar**: single-row, horizontally centered title text reads "sudo ls" in medium-gray (~#888888), system default small caps or regular weight SF Pro. The title bar has no visible border or separator line from the content — seamless with the window chrome.

**Secure Input pill** (upper-right of title bar, ~16px from right edge, vertically centered in title bar): a solid-filled rounded-rectangle badge/pill. Fill color is a vivid blue (~#2D6FE8 / system accent blue). Badge contains:
- A white padlock icon (filled, closed-lock shape) on the left, ~14×14px
- Uppercase white text "SECURE INPUT" in a small (~11–12pt), bold or semibold sans-serif (SF Pro), tracking slightly wider than default
- Total badge width ~140px, height ~26–28px
- The pill has no border/stroke; the rounded corners match approximately half the height radius (fully pill-shaped)

**Terminal content area**: off-white/very light gray background (~#F8F8F8 or pure white). Two lines of terminal text visible in the upper-left of the content area, monospace font (approximately 14pt), dark/near-black text:
- Line 1: `~ ▶ sudo ls` — the tilde (`~`) is in a light teal/seafoam color (~#5FC6B0 or similar muted green), the `▶` play-triangle is in a muted green (#4CAF7A or similar), the command text `sudo ls` is in near-black
- Line 2: `Password:` with a blinking cursor (block-style or bar, visible as a black vertical bar `|` immediately after the colon) in dark text

**Spacing**: terminal content starts ~12–16px from the top of the content area and ~12–16px from the left edge. Lines are at standard terminal line spacing (~20–22px).

**No other UI elements** are visible — no sidebar, no tab bar, no status bar, no toolbar — this is a minimal single-pane terminal window demonstrating the secure input state.

---

## Screenshots

- `secure-input.png`

---

## Implementation notes

### Straightforward

- **Natural Text Editing chords**: slopdesk's client uses libghostty behind `TerminalSurface`; the macOS/iOS client intercepts `⌘←/→`, `⌥←/→`, `⌘⌫/⌦`, `⌥⌫/⌥⌦` and translates them to the appropriate readline/VT sequences before sending over the wire. This is purely client-side input translation — maps directly.
- **⌘A / ⌘C / ⌘V / ⌘X**: client-side copy/paste. Paste sends bytes over the wire to the remote PTY; copy captures from the local terminal surface buffer. Maps 1:1.
- **Undo/Redo at prompt**: slopdesk can intercept `⌘Z`/`⌘⇧Z` and emit the corresponding readline undo sequences (`⌃_` for undo). Coalescing is a client-side concern. Maps 1:1.
- **Click to focus**: in slopdesk's split-pane workspace (`WorkspaceStore`), clicking a pane already triggers focus routing. The "lights up" visual state is a pane-border highlight on the focused pane. Maps 1:1.
- **IME support**: libghostty handles IME on macOS and iOS natively through the platform text input system. Composing text is shown inline. Maps 1:1.
- **Kitty keyboard protocol**: slopdesk wire-forwards key events; if the remote shell/program opts into Kitty KKP, the host's PTY receives modern CSI u sequences. The client needs to send the correct raw encoding. Maps 1:1 (wire-transparent).
- **Option as Alt / Shift+Arrow Select / Application Keypad Mode**: purely client-side input encoding decisions before bytes are sent over the wire. Maps 1:1 as slopdesk Settings options.
- **Find (⌘F/⌘G/⌘⇧G)**: find/search operates on the local terminal scrollback buffer rendered by libghostty. Maps 1:1.

### Requires adaptation

- **Secure Keyboard Entry (automatic)**: Secure Keyboard Entry is a macOS API (`NSEvent.isEnabled(forSecureEventInput:)`, `EnableSecureEventInput()`). On the **macOS client**, this can be implemented identically — detect password prompts (via OSC 133 shell integration or PTY heuristics from the wire stream) and call `EnableSecureEventInput()`. **Cannot prevent the remote host from being observed** — it only protects the local client's keystroke path from local snoopers. On **iOS client**, Secure Keyboard Entry is handled by the OS when a `secureTextEntry` field is active; there is no explicit API equivalent, and detection of a password prompt would need the same wire-stream heuristic. Flag: the title-bar "SECURE INPUT" pill is a client-side UI element — trivially implementable. Wire-stream heuristic (e.g., the remote PTY switching to no-echo mode) is the detection signal.
- **Composer**: the Composer is a local client feature — a multi-line `NSTextView`/`UITextView` overlay that slides up from the bottom of the focused pane. Since slopdesk panes are remote terminal views, the Composer simply buffers text locally and sends it as keystrokes (or a paste) over the wire on ⌘↵. Maps with a local-only UI overlay — no remote-side change needed.
- **Prompt Queue**: local client feature. SlopDesk needs shell integration (OSC 133 prompt-start/end markers, already part of the protocol) to detect when the remote shell is back at an idle prompt before dispatching the next queued command. The queue dispatches bytes over the wire. Maps with shell-integration dependency (OSC 133 already supported in slopdesk).
- **Mouse Over to Focus**: available for macOS client (NSWindow/NSSplitView mouse tracking). On iOS, focus follows tap, not hover — this option is not applicable on iOS.

### Open design decisions — flag for deferral or skip

- **Services menu**: macOS Services operate on locally selected text. Since slopdesk renders a remote terminal, selected text must be brought to the client before it can be offered to Services. On macOS client this works: selection is mirrored locally in the libghostty surface, so the standard Services mechanism applies. On iOS there is no Services menu (replaced by Share Sheet) — the mapping differs in UX.
- **Insert from device (Continuity Camera)**: this is a macOS feature that uses `NSMenuItem` with `UIImagePickerController` handoff. It writes to a local temp file and inserts the path into the prompt. For slopdesk: the file lands on the **client** machine, but the running shell is on the **remote host**. The path is local-client-only and meaningless on the remote. To map this properly, slopdesk would need to transfer the file to the host (e.g., scp/sftp over the existing transport) and then insert the **remote** path. This is a non-trivial feature; flag for deferral.
- **Insert from device — File Path…**: same issue as above if the file is on the client. If the file is already accessible on the host (e.g., via a shared filesystem), inserting its remote path is trivial. For purely client-local files, file-transfer is required.
- **Composer "pop out into floating window"**: requires a detached `NSPanel` on macOS. Straightforward on macOS client; not applicable on iOS (no floating windows). macOS-only feature.
