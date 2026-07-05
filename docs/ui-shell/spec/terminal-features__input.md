# Input

## Summary

SlopDesk treats a shell prompt like a native macOS text field, so muscle memory from other Mac apps carries over. This page covers keyboard handling: native macOS editing chords, IME, the Kitty keyboard protocol, Secure Keyboard Entry (automatic and manual), the Composer multi-line editor, and the Prompt Queue batch runner. Everything is GUI-configured; every shortcut below is a factory default, re-bindable in Settings → Key Bindings.

---

## Behaviors

- **Click to focus**: clicking a pane hands it the keyboard and lights it up; clicking the already-focused pane keeps it. Optionally enable "Mouse Over to Focus" (see Cursor and Mouse) to follow the pointer instead.

- **Natural Text Editing**: standard macOS editing/navigation chords work at the shell prompt like a native text field. Caret/word/line-delete chords send the readline sequence the shell expects, so they work in every shell. Each is re-bindable/disableable under Settings → Key Bindings ▸ Text Editing.

- **Undo / Redo**: `⌘Z` undoes shell-prompt editing; `⌘⇧Z` (or `⌘Y`) redoes. Rapid typing coalesces into a single undo step. Applies to the current prompt line; unavailable inside full-screen programs (vim, less, editors), which manage their own undo.

- **Cut (`⌘X`)**: always copies the selection. If the selection is editable prompt-line text, slopdesk also deletes it; on read-only text (scrollback, output) it falls back to plain copy. Also at Edit ▸ Cut.

- **Input methods (IME)**: full Chinese/Japanese/Korean input plus dead keys for accents (é, ü…), identical to any macOS app. Marked text shows inline at the prompt with the candidate window tracking the cursor; committed text is sent to the shell on confirmation.

- **Kitty keyboard protocol** (Settings → Advanced, on by default): sends modern unambiguous CSI u key encodings, letting programs distinguish keys the legacy encoding collapses (Tab vs ⌃I, Esc vs ⌃[, modified keys, key-release). Programs opt in at launch; others fall back to classic encoding automatically. Disable only if a program misbehaves.

- **Option key behavior for word chords**: the word chords (⌥← ⌥→ ⌥⌫ ⌥⌦) work whether or not "Option as Alt" is enabled. To reach a TUI as raw Alt/Meta, unbind those chords under Settings → Key Bindings.

- **Secure Keyboard Entry — Automatic**: with "Auto Secure Input" on (Settings → Controls, on by default), slopdesk enables macOS Secure Keyboard Entry the moment the active session requests a hidden password (sudo, ssh, login) and releases it afterward.

- **Secure Keyboard Entry — Manual**: toggle from Edit ▸ Secure Keyboard Entry. A title-bar pill shows the state; hide it via "Secure Input Indicator" off (Settings → Controls).

- **Composer**: a roomy multi-line editor that slides up from the bottom of the focused pane — for building a long command, here-doc, or multi-line prompt before running. Open via Edit ▸ Composer (⌘⇧E), Command Palette, or right-click menu. Draft is preserved on cancel. Matches the terminal theme and can pop out into a floating always-on-top window. Can hand its lines directly to the Prompt Queue.

- **Prompt Queue**: fires several commands one at a time, each waiting for the previous to finish and a fresh prompt to appear. Open via Edit ▸ Prompt Queue… (⌘⇧M) or Command Palette; a card appears at the bottom of the pane. Type a line + ↵ to add; row buttons send immediately (arrow) or drop (trash). Dispatches the next item only when the shell is back at an idle, empty prompt, so it won't clobber mid-typing. Full-screen TUIs pause the queue; agent panes wait for the agent to go idle between turns.

- **Services**: when text is selected in a pane, slopdesk offers it to any macOS Service accepting text, from the Services menu.

- **Insert from device** (Edit ▸ Insert from): File Path…, Screenshot, and Import from iPhone or iPad. The last uses Continuity Camera (photo, document scan, or sketch on a nearby iPhone/iPad); slopdesk saves to a temp file and drops the shell-escaped path into the prompt.

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
| Option as Alt | Off | Treat Option as Alt/Meta so terminal apps see Esc-prefixed sequences (Emacs, Vim word-jumps, readline). Off keeps Option free for accents (¡, é, ©…). Appliable to both Option keys or left/right independently. |
| Shift+Arrow Select | On | ⇧+arrows drive native selection instead of sending arrow escapes. Off passes ⇧+arrows through to a TUI. |
| Allow VT100 Application Keypad Mode | On | Honor a program's DECKPAM request to put the numeric keypad into application mode, so vim/emacs/less keypad bindings work. Off makes keypad keys always type literal digits. |
| Auto Secure Input | On | Automatically enable macOS Secure Keyboard Entry when the active session requests a hidden password; release it afterward. |
| Secure Input Indicator | On | Show the "SECURE INPUT" pill in the title bar while Secure Keyboard Entry is active. Off hides the pill. |

### Settings → Advanced

| Key | Default | Effect |
|-----|---------|--------|
| Kitty Keyboard Protocol | On | Send modern unambiguous CSI u key encodings to programs that opt in; fall back to classic encoding otherwise. |

---

## Visual spec

### secure-input.png — Secure Keyboard Entry title-bar indicator

**Overall layout**: standard macOS terminal window at ~1/3 screen height, native rounded corners with drop shadow, light/white background. Three traffic-light buttons (red, yellow, green) upper-left at standard spacing (~8px from edges, ~20px diameter each).

**Title bar**: single-row, horizontally centered title "sudo ls" in medium-gray (~#888888), small SF Pro. No border/separator from content — seamless with the chrome.

**Secure Input pill** (upper-right, ~16px from right edge, vertically centered): solid rounded-rectangle badge, vivid blue fill (~#2D6FE8 / system accent blue). Contains:
- White padlock icon (filled, closed) on the left, ~14×14px
- Uppercase white "SECURE INPUT" in ~11–12pt bold/semibold SF Pro, tracking slightly wide
- Total ~140px wide, ~26–28px tall
- No border/stroke; fully pill-shaped (corner radius ~half height)

**Terminal content area**: off-white/very light gray (~#F8F8F8 or white). Two lines of monospace (~14pt) dark/near-black text, upper-left:
- Line 1: `~ ▶ sudo ls` — `~` in light teal/seafoam (~#5FC6B0), `▶` in muted green (#4CAF7A), `sudo ls` near-black
- Line 2: `Password:` with a blinking cursor (black vertical bar `|` immediately after the colon)

**Spacing**: content starts ~12–16px from top and left of the content area; standard line spacing (~20–22px).

**No other UI** — no sidebar, tab bar, status bar, or toolbar; minimal single-pane window demonstrating the secure input state.

---

## Screenshots

- `secure-input.png`

---

## Implementation notes

### Straightforward

- **Natural Text Editing chords**: slopdesk's client uses libghostty behind `TerminalSurface`; the macOS/iOS client intercepts `⌘←/→`, `⌥←/→`, `⌘⌫/⌦`, `⌥⌫/⌥⌦` and translates them to readline/VT sequences before sending over the wire. Purely client-side, maps directly.
- **⌘A / ⌘C / ⌘V / ⌘X**: client-side copy/paste. Paste sends bytes to the remote PTY; copy captures from the local terminal surface buffer. Maps 1:1.
- **Undo/Redo at prompt**: intercept `⌘Z`/`⌘⇧Z`, emit readline undo (`⌃_`). Coalescing is client-side. Maps 1:1.
- **Click to focus**: slopdesk's split-pane workspace (`WorkspaceStore`) already routes focus on click; "lights up" = pane-border highlight. Maps 1:1.
- **IME support**: libghostty handles IME natively on macOS/iOS via the platform text input system; composing text shows inline. Maps 1:1.
- **Kitty keyboard protocol**: slopdesk wire-forwards key events; if the remote program opts into KKP, the host PTY receives modern CSI u. Client must send the correct raw encoding. Maps 1:1 (wire-transparent).
- **Option as Alt / Shift+Arrow Select / Application Keypad Mode**: purely client-side input encoding before bytes go over the wire. Maps 1:1 as Settings options.
- **Find (⌘F/⌘G/⌘⇧G)**: operates on the local scrollback buffer rendered by libghostty. Maps 1:1.

### Requires adaptation

- **Secure Keyboard Entry (automatic)**: macOS API (`NSEvent.isEnabled(forSecureEventInput:)`, `EnableSecureEventInput()`). On the **macOS client**, implement identically — detect password prompts (via OSC 133 shell integration or PTY heuristics from the wire stream) and call `EnableSecureEventInput()`. **Cannot prevent the remote host from being observed** — it only protects the local client's keystroke path from local snoopers. On **iOS client**, the OS handles it when a `secureTextEntry` field is active; no explicit API equivalent, and detection needs the same wire-stream heuristic. The title-bar "SECURE INPUT" pill is client-side UI — trivial. Detection signal = the remote PTY switching to no-echo mode.
- **Composer**: local client feature — a multi-line `NSTextView`/`UITextView` overlay sliding up from the focused pane. Since panes are remote terminal views, the Composer buffers text locally and sends it as keystrokes (or a paste) over the wire on ⌘↵. Local-only UI overlay, no remote change.
- **Prompt Queue**: local client feature. Needs shell integration (OSC 133 prompt-start/end markers, already in the protocol) to detect an idle prompt before dispatching the next queued command; dispatches bytes over the wire. Depends on OSC 133 (already supported).
- **Mouse Over to Focus**: macOS client only (NSWindow/NSSplitView mouse tracking). On iOS, focus follows tap, not hover — not applicable.

### Open design decisions — flag for deferral or skip

- **Services menu**: macOS Services operate on locally selected text. On the macOS client this works — selection is mirrored locally in the libghostty surface, so the standard mechanism applies. On iOS there is no Services menu (replaced by Share Sheet) — UX differs.
- **Insert from device (Continuity Camera)**: macOS `NSMenuItem` + `UIImagePickerController` handoff writes a local temp file and inserts its path. But the file lands on the **client** while the shell runs on the **remote host**, so a local path is meaningless remotely. Proper mapping requires transferring the file to the host (e.g., scp/sftp over the existing transport) and inserting the **remote** path. Non-trivial; flag for deferral.
- **Insert from device — File Path…**: same issue if the file is client-local. If already accessible on the host (e.g., shared filesystem), inserting its remote path is trivial; purely client-local files need file-transfer.
- **Composer "pop out into floating window"**: requires a detached `NSPanel` on macOS. Straightforward on macOS; not applicable on iOS (no floating windows). macOS-only.
