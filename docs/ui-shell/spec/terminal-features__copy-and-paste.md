# Copy and Paste

> Section: terminal-features | Slug: copy-and-paste

## Summary

How slopdesk moves text between the terminal and the system clipboard, plus the safety net that catches risky pastes. Everything is configured in the GUI — no config file needed. Core actions are ⌘C (copy), ⌘V (paste), and ⌘X (cut). Bracketed paste is handled automatically. A paste-protection dialog warns before pasting potentially dangerous content. "Paste as…" provides several clipboard transformation variants. Terminal programs can access the clipboard via OSC 52, with per-direction (read/write) permission controls.

## Behaviors

### Copy

- Select text first (see the Selection page for how), then copy via ⌘C, Edit ▸ Copy, or the right-click menu.
- **Copy on Select** (off by default): when enabled, every selection immediately drops into the clipboard — no explicit ⌘C needed.
- **Clipboard Trim Trailing Spaces** (off by default): strips trailing spaces from each copied line at copy time.
- **Clear Selection on Copy** (off by default): drops the highlight after an explicit ⌘C (not triggered by Copy on Select). Documented on the Selection page.
- Cut (copy + delete in one step) is ⌘X — documented under Input.

### Paste

- Paste via ⌘V, Edit ▸ Paste, or the right-click menu.
- **Bracketed paste** is handled automatically: programs that advertise support (shell line editors, editors, REPLs) receive pasted text as a single inert block; newlines are NOT interpreted as Enter.
- A plain right-click can be configured to paste (or copy) directly instead of opening the context menu — see Right Click Action in Cursor and Mouse.

### Paste Protection

- **On by default** (Settings → Controls).
- When triggered, shows a confirmation dialog with a preview of the clipboard content and flags any of the following dangers:
  - **Multi-line text** — earlier lines would execute the moment they are pasted (i.e., newline = Enter in a shell).
  - **Trailing newline** — the command would run on paste, before the user can review it.
  - **`sudo` / `su`** — the paste may run with elevated privileges.
  - **Control characters** — possible terminal-escape injection hidden in the text.
- User can choose **Paste Anyway** or **Cancel**.
- Protection is **skipped** inside full-screen TUIs (vim, less, etc.) — those receive the paste inertly.
- Protection is also **skipped** when **Paste Bracketed Safe** (on by default) is enabled AND the program has advertised bracketed-paste support — since the app then sends the paste as an inert block anyway, the danger does not apply.

### Paste as…

Accessible via **Edit ▸ Paste as**. Each variant transforms the clipboard before it reaches the shell:

| Variant | What it sends |
|---|---|
| Paste Selection | Pastes the current text selection instead of the clipboard (the middle-click convention from X11 terminals). |
| Paste File Base64-Encoded… | Base64-encodes a chosen file so you can ferry binary content over a plain text session. |
| Paste Escaping Special Characters | Shell-escapes the text so spaces and special characters land as literals — ideal for a pasted file path. |
| Bracketed Paste | Forces bracketed-paste markers even if the program did not ask for them. |
| Paste and continue in Composer | Appends the clipboard to the Composer draft instead of sending it to the prompt. |

### Clipboard Access from Programs (OSC 52)

- Terminal programs can read and write the system clipboard through the **OSC 52** escape sequence (e.g., tmux, vim with a clipboard plugin, remote sessions over SSH).
- Controlled per-direction under **Settings → Advanced → All Settings**.
- **Clipboard Write** defaults to **Allow** — a program copying TO your clipboard.
- **Clipboard Read** defaults to **Ask** — a program reading FROM your clipboard. Defaults to Ask because letting a remote program silently read your clipboard is the riskier direction.
- Each direction can be set to **Allow**, **Ask** (prompt every time), or **Deny**.

## Keybindings

| Action | Keys |
|---|---|
| Copy selection | ⌘C |
| Cut (copy + delete) | ⌘X |
| Paste clipboard | ⌘V |
| Copy (menu) | Edit ▸ Copy |
| Paste (menu) | Edit ▸ Paste |
| Paste as… (submenu) | Edit ▸ Paste as |
| Copy (right-click) | Right-click menu |
| Paste (right-click) | Right-click menu (or bare right-click if Right Click Action is set) |

## Config Keys

All settings are GUI-only (Settings app); no config file keys documented for this page.

| Key / Setting Name | Default | Effect |
|---|---|---|
| Copy on Select | Off | Every selection immediately goes to clipboard; no ⌘C required. |
| Clipboard Trim Trailing Spaces | Off | Strip trailing spaces from each copied line at copy time. |
| Clear Selection on Copy | Off | Drop the text highlight after an explicit copy (⌘C). Does not apply when Copy on Select fires. |
| Paste Protection | On | Show confirmation dialog before pasting potentially dangerous content (multi-line, trailing newline, sudo/su, control characters). |
| Paste Bracketed Safe | On | Skip paste-protection dialog when the receiving program has advertised bracketed-paste support (safe because the paste is received inertly). |
| Clipboard Write (OSC 52) | Allow | Permission for a terminal program to copy TO the system clipboard. Options: Allow / Ask / Deny. |
| Clipboard Read (OSC 52) | Ask | Permission for a terminal program to read FROM the system clipboard. Options: Allow / Ask / Deny. |

**Setting locations:**
- Copy on Select, Clipboard Trim Trailing Spaces, Clear Selection on Copy, Paste Protection, Paste Bracketed Safe → **Settings → Controls**
- Clipboard Write, Clipboard Read → **Settings → Advanced → All Settings**

## Visual Spec

No content screenshots are present for this page. The page is purely prose + tables — no annotated UI images.

## Screenshots

*(No content screenshots on this page.)*

## Implementation Notes

### Straightforward

- **⌘C / ⌘V / ⌘X keybindings** — standard macOS; wire through to the NSView / libghostty surface as-is. libghostty already handles copy and paste events via its `ghostty_app_action` / key binding layer.
- **Bracketed paste** — libghostty handles the DEC `?2004h`/`?2004l` enable/disable tracking and injects `\e[200~…\e[201~` wrapping automatically on paste. No extra work needed.
- **Copy on Select** — implement as a `SelectionStore` observer: when the selection range becomes non-empty, write to `NSPasteboard.general`. Toggle in Preferences.
- **Clipboard Trim Trailing Spaces** — post-process the copied string in the copy action: split on `\n`, `trimmingCharacters(.whitespaces)` each line, rejoin.
- **Clear Selection on Copy** — after explicit ⌘C, call `surface.clearSelection()` if this pref is on.
- **Paste Protection dialog** — implement as a SwiftUI sheet / `NSAlert` shown before forwarding the paste string to libghostty. Inspect the clipboard string for: `\n` count > 1, trailing `\n`, `/sudo /` or `/su /` tokens, presence of ASCII control codes (bytes < 0x20 excluding `\t\n\r`). Skip the check when the surface is in full-screen TUI mode (track via OSC 133 / shell integration state or the `?2004h` advertised flag) OR when Paste Bracketed Safe is on and `?2004h` is active.
- **Paste as… variants** — all are client-side transformations before calling the paste action:
  - *Paste Selection*: read `surface.selectedText` (the X11 primary-selection convention) instead of `NSPasteboard.general`.
  - *Paste File Base64-Encoded…*: show `NSOpenPanel`, base64-encode the file bytes, inject.
  - *Paste Escaping Special Characters*: shell-escape via `shlex`-style escaping in Swift.
  - *Bracketed Paste*: force-wrap with `\e[200~…\e[201~` regardless of program state.
  - *Paste and continue in Composer*: append to the local Composer text buffer instead of sending to the PTY.

### Requires special handling

- **OSC 52 Clipboard Write/Read over a remote session**: In slopdesk, the terminal PTY runs on the macOS HOST, but the clipboard lives on the CLIENT. OSC 52 sequences emitted by a remote program (e.g. vim over SSH inside the hosted slopdesk terminal) reach the HOST-side libghostty. The host must forward OSC 52 write payloads over the slopdesk wire to the CLIENT to write to the client's `NSPasteboard.general`. Similarly, OSC 52 read requests must be forwarded to the client, which returns the clipboard content over the wire to the host for injection into the PTY. This is a non-trivial wire extension — define a new `ClipboardWrite` / `ClipboardRead` control-channel message pair. The Ask/Allow/Deny permission gate must live on the CLIENT (where the user sits), not the host.
- **Right Click Action (paste-on-right-click)**: The right-click context menu is a CLIENT-side `NSMenu`. Implementing bare-right-click-to-paste is a client gesture recogniser change (`TerminalSurface` / `TerminalRendererFactory` view), not a host change. No wire needed.
- **Paste as… → Paste and continue in Composer**: The Composer is a CLIENT-side UI element (`WorkspaceStore` / Composer pane). This is pure client state — no wire involvement.
- **Full-screen TUI detection for paste-protection skip**: libghostty tracks the alternate screen (`?1049h`) which is a reliable proxy for "full-screen TUI active." Read this state from the libghostty surface config before deciding whether to show the protection dialog.
- **iOS client**: On iOS, the system clipboard API is `UIPasteboard.general`. OSC 52 forwarding requires the same wire extension as macOS client. The right-click menu becomes a long-press context menu. The Paste as… submenu maps to a share-sheet / action sheet.
